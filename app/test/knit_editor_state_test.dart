import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/models/knit_stitches.dart';
import 'package:ply/src/rust/dto.dart' show ColorDto, UnitKind;
import 'package:ply/src/rust/knit_dto.dart';
import 'package:ply/src/state/knit_editor_state.dart';

// Pure-VM tests for the knit editor state: paint/resize/undo over the immutable KnitPatternDto, with
// no FFI (the DTO reconstruction edits are pure).

KnitPatternDto pattern(int width, int rows) => KnitPatternDto(
      name: 't',
      construction: ConstructionKind.flat,
      firstRowSide: SideKind.rs,
      gauge: const GaugeDto(sts: 18, rows: 24, unit: UnitKind.inches),
      palette: const [ColorDto(r: 255, g: 255, b: 255)],
      legend: const StitchLegendDto(stitches: []),
      chart: ChartDto(
        width: width,
        rows: List.generate(
          rows,
          (_) => RowDto(
            cells: List.generate(width, (_) => const CellDto(stitch: KnitStitch.knit)),
            repeats: const [],
          ),
        ),
      ),
      notes: '',
    );

void main() {
  test('paintCell sets the cell and records one undo', () {
    final s = KnitEditorState(pattern: pattern(2, 2)).paintCell(0, 1, KnitStitch.purl, null);
    expect(s.pattern.chart.rows[0].cells[1].stitch, KnitStitch.purl);
    expect(s.undo.length, 1);
    expect(s.canUndo, isTrue);
  });

  test('a colorwork paint carries an in-palette color index', () {
    final s = KnitEditorState(pattern: pattern(2, 2))
        .addPaletteColor(const ColorDto(r: 0, g: 0, b: 0))
        .addPaletteColor(const ColorDto(r: 1, g: 1, b: 1))
        .addPaletteColor(const ColorDto(r: 2, g: 2, b: 2)) // palette now length 4; index 3 valid
        .paintCell(1, 0, KnitStitch.knit, 3);
    expect(s.pattern.chart.rows[1].cells[0].color, 3);
  });

  test('an out-of-range or no-change paint is a no-op (no undo, same instance)', () {
    final s = KnitEditorState(pattern: pattern(2, 2));
    expect(identical(s.paintCell(9, 9, KnitStitch.purl, null), s), isTrue, reason: 'out of range');
    expect(identical(s.paintCell(0, 0, KnitStitch.knit, null), s), isTrue, reason: 'no change');
  });

  test('resizeChart grows with knit padding and keeps existing cells', () {
    var s = KnitEditorState(pattern: pattern(2, 2)).paintCell(0, 0, KnitStitch.purl, null);
    final grown = s.resizeChart(3, 3);
    expect((grown.pattern.chart.width, grown.pattern.chart.rows.length), (3, 3));
    expect(grown.pattern.chart.rows[0].cells[0].stitch, KnitStitch.purl, reason: 'existing kept');
    expect(grown.pattern.chart.rows[0].cells[2].stitch, KnitStitch.knit, reason: 'new col is knit');
    expect(grown.pattern.chart.rows[2].cells.length, 3, reason: 'a new row is full width');
  });

  test('resizeChart shrinks by truncating', () {
    final s = KnitEditorState(pattern: pattern(4, 4)).resizeChart(2, 2);
    expect((s.pattern.chart.width, s.pattern.chart.rows.length), (2, 2));
    expect(s.pattern.chart.rows[0].cells.length, 2);
  });

  test('undo and redo round-trip a paint', () {
    final painted = KnitEditorState(pattern: pattern(2, 2)).paintCell(0, 0, KnitStitch.yo, null);
    final undone = painted.undoEdit();
    expect(undone.pattern.chart.rows[0].cells[0].stitch, KnitStitch.knit, reason: 'undo reverts');
    expect(undone.canRedo, isTrue);
    final redone = undone.redoEdit();
    expect(redone.pattern.chart.rows[0].cells[0].stitch, KnitStitch.yo, reason: 'redo re-applies');
  });

  test('a fresh paint clears the redo stack', () {
    final base = KnitEditorState(pattern: pattern(2, 2)).paintCell(0, 0, KnitStitch.yo, null);
    final undone = base.undoEdit(); // redo now non-empty
    final repainted = undone.paintCell(0, 1, KnitStitch.purl, null);
    expect(repainted.canRedo, isFalse, reason: 'a new edit discards the redo branch');
  });

  test('addPaletteColor appends a colorwork color and records undo', () {
    final s = KnitEditorState(pattern: pattern(2, 2))
        .addPaletteColor(const ColorDto(r: 10, g: 20, b: 30));
    expect(s.pattern.palette.length, 2, reason: 'started with one (white)');
    expect(s.pattern.palette[1], const ColorDto(r: 10, g: 20, b: 30));
    expect(s.canUndo, isTrue);
  });

  test('setPaletteColor replaces a color; out-of-range or no-change is a no-op', () {
    final s = KnitEditorState(pattern: pattern(2, 2));
    expect(s.setPaletteColor(0, const ColorDto(r: 1, g: 2, b: 3)).pattern.palette[0],
        const ColorDto(r: 1, g: 2, b: 3));
    expect(identical(s.setPaletteColor(9, const ColorDto(r: 1, g: 2, b: 3)), s), isTrue,
        reason: 'out of range');
    expect(identical(s.setPaletteColor(0, const ColorDto(r: 255, g: 255, b: 255)), s), isTrue,
        reason: 'already white');
  });

  test('paintCell drops a color index past the palette (no dangling reference)', () {
    // palette has 1 color (index 0); painting with color 5 must store null (symbol-only).
    final s = KnitEditorState(pattern: pattern(2, 2)).paintCell(0, 0, KnitStitch.purl, 5);
    expect(s.pattern.chart.rows[0].cells[0].color, isNull, reason: 'out-of-range color dropped');
    expect(s.pattern.chart.rows[0].cells[0].stitch, KnitStitch.purl);
  });

  test('resizeChart shrink drops a repeat span that no longer fits the width', () {
    final withRepeat = KnitPatternDto(
      name: 't',
      construction: ConstructionKind.flat,
      firstRowSide: SideKind.rs,
      gauge: const GaugeDto(sts: 18, rows: 24, unit: UnitKind.inches),
      palette: const [ColorDto(r: 255, g: 255, b: 255)],
      legend: const StitchLegendDto(stitches: []),
      chart: ChartDto(
        width: 4,
        rows: [
          RowDto(
            cells: List.generate(4, (_) => const CellDto(stitch: KnitStitch.knit)),
            repeats: [const RepeatSpanDto(start: 1, end: 4, count: RepeatDto.toEnd())],
          ),
        ],
      ),
      notes: '',
    );
    final shrunk = KnitEditorState(pattern: withRepeat).resizeChart(2, 1);
    expect(shrunk.pattern.chart.rows[0].repeats, isEmpty,
        reason: 'a span ending at col 4 cannot survive a shrink to width 2');
  });

  test('setConstruction switches flat<->round, keeps the chart, and records undo', () {
    final s = KnitEditorState(pattern: pattern(2, 2)).setConstruction(ConstructionKind.inTheRound);
    expect(s.pattern.construction, ConstructionKind.inTheRound);
    expect((s.pattern.chart.width, s.pattern.chart.rows.length), (2, 2), reason: 'chart preserved');
    expect(s.canUndo, isTrue);
    expect(identical(s.setConstruction(ConstructionKind.inTheRound), s), isTrue, reason: 'no-op');
  });

  test('setFirstRowSide toggles RS/WS', () {
    final s = KnitEditorState(pattern: pattern(2, 2)).setFirstRowSide(SideKind.ws);
    expect(s.pattern.firstRowSide, SideKind.ws);
    expect(identical(s.setFirstRowSide(SideKind.ws), s), isTrue, reason: 'no-op');
  });

  test('setNotes replaces notes and keeps the chart; no-change is a no-op', () {
    final s = KnitEditorState(pattern: pattern(2, 2)).setNotes('worsted, US7');
    expect(s.pattern.notes, 'worsted, US7');
    expect(s.pattern.chart.rows.length, 2, reason: 'chart preserved');
    expect(identical(s.setNotes('worsted, US7'), s), isTrue);
  });

  // --- cables -------------------------------------------------------------------------------------

  // A legend that reserves id 0 = no-stitch and id 1 = knit (as the real builtin legend does), so
  // fillers/knits are never mistaken for a cable; addCable then lands the cable at id 2+.
  KnitPatternDto cablePattern(int width) => KnitPatternDto(
        name: 't',
        construction: ConstructionKind.flat,
        firstRowSide: SideKind.rs,
        gauge: const GaugeDto(sts: 18, rows: 24, unit: UnitKind.inches),
        palette: const [ColorDto(r: 255, g: 255, b: 255)],
        legend: const StitchLegendDto(stitches: [
          StitchDefDto(symbol: 'no', consumes: 0, produces: 0, macroRows: 1),
          StitchDefDto(symbol: 'k', consumes: 1, produces: 1, macroRows: 1),
        ]),
        chart: ChartDto(
          width: width,
          rows: [
            RowDto(
              cells: List.generate(width, (_) => const CellDto(stitch: KnitStitch.knit)),
              repeats: const [],
            ),
          ],
        ),
        notes: '',
      );

  const cable22 =
      CableDefDto(front: 2, back: 2, direction: CrossKind.right, frontPurl: false, backPurl: false);

  test('addCable appends a count-neutral cable brush to the legend', () {
    final s = KnitEditorState(pattern: cablePattern(6)).addCable(cable22, '2/2RC');
    expect(s.pattern.legend.stitches.length, 3, reason: 'was 2 (no-stitch + knit)');
    final def = s.pattern.legend.stitches[2];
    expect(def.symbol, '2/2RC');
    expect((def.consumes, def.produces), (4, 4), reason: 'span = front + back, count-neutral');
    expect(def.cable?.front, 2);
  });

  test('placing a cable lays the anchor plus span-1 no-stitch fillers', () {
    final s = KnitEditorState(pattern: cablePattern(6)).addCable(cable22, '2/2RC'); // cable id 2
    final cells = s.paintCell(0, 0, 2, null).pattern.chart.rows[0].cells;
    expect(cells[0].stitch, 2, reason: 'anchor');
    expect(cells[1].stitch, KnitStitch.noStitch);
    expect(cells[2].stitch, KnitStitch.noStitch);
    expect(cells[3].stitch, KnitStitch.noStitch);
    expect(cells[4].stitch, KnitStitch.knit, reason: 'past the span, untouched');
  });

  test('a cable that would run off the row edge is a no-op', () {
    final s = KnitEditorState(pattern: cablePattern(6)).addCable(cable22, '2/2RC');
    // span 4 anchored at col 4 -> 4 + 4 = 8 > width 6.
    expect(identical(s.paintCell(0, 4, 2, null), s), isTrue);
  });

  test('a cable that fits exactly to the right edge is placed', () {
    final s = KnitEditorState(pattern: cablePattern(6)).addCable(cable22, '2/2RC'); // span 4
    // col 2 + span 4 = 6 == width -> fits exactly, no overflow.
    final cells = s.paintCell(0, 2, 2, null).pattern.chart.rows[0].cells;
    expect(cells[2].stitch, 2, reason: 'anchor at the last fitting column');
    expect(cells[5].stitch, KnitStitch.noStitch, reason: 'last filler lands on the final column');
  });

  test('painting a regular stitch onto a cable clears the whole group', () {
    var s = KnitEditorState(pattern: cablePattern(6)).addCable(cable22, '2/2RC');
    s = s.paintCell(0, 1, 2, null); // cable occupies cols 1..4
    final cells = s.paintCell(0, 3, KnitStitch.knit, null).pattern.chart.rows[0].cells;
    expect(cells[1].stitch, KnitStitch.knit, reason: 'anchor cleared');
    expect(cells[2].stitch, KnitStitch.knit, reason: 'filler cleared');
    expect(cells[3].stitch, KnitStitch.knit, reason: 'painted (and cleared)');
    expect(cells[4].stitch, KnitStitch.knit, reason: 'filler cleared');
  });

  test('placing a cable over an existing cable clears the old one', () {
    var s = KnitEditorState(pattern: cablePattern(6)).addCable(cable22, '2/2RC'); // id 2, span 4
    s = s.paintCell(0, 0, 2, null); // cable A at cols 0..3
    const cable11 =
        CableDefDto(front: 1, back: 1, direction: CrossKind.left, frontPurl: false, backPurl: false);
    s = s.addCable(cable11, '1/1LC'); // id 3, span 2
    final cells = s.paintCell(0, 2, 3, null).pattern.chart.rows[0].cells; // cable B at 2..3
    expect(cells[0].stitch, KnitStitch.knit, reason: 'old cable A anchor cleared');
    expect(cells[1].stitch, KnitStitch.knit, reason: 'old cable A filler cleared');
    expect(cells[2].stitch, 3, reason: 'new cable B anchor');
    expect(cells[3].stitch, KnitStitch.noStitch, reason: 'new cable B filler');
  });
}
