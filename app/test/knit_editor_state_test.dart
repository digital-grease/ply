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

  test('paintCell keepColor preserves the cell color (a symbol over a colored square)', () {
    final colored = KnitEditorState(pattern: pattern(2, 2))
        .addPaletteColor(const ColorDto(r: 200, g: 0, b: 0)) // palette index 1
        .paintCell(0, 0, KnitStitch.knit, 1); // (knit, red)
    expect(colored.pattern.chart.rows[0].cells[0].color, 1);

    final withSymbol = colored.paintCell(0, 0, KnitStitch.purl, null, keepColor: true);
    expect(withSymbol.pattern.chart.rows[0].cells[0].stitch, KnitStitch.purl, reason: 'symbol added');
    expect(withSymbol.pattern.chart.rows[0].cells[0].color, 1, reason: 'colorwork kept');
  });

  test('paintCell without keepColor sets the brush color, clearing colorwork on a null brush', () {
    final colored = KnitEditorState(pattern: pattern(2, 2))
        .addPaletteColor(const ColorDto(r: 200, g: 0, b: 0))
        .paintCell(0, 0, KnitStitch.knit, 1);
    final cleared = colored.paintCell(0, 0, KnitStitch.purl, null); // keepColor defaults false
    expect(cleared.pattern.chart.rows[0].cells[0].color, isNull, reason: 'color cleared');
  });

  test('paintCell keepStitch sets only the color, leaving the symbol (color under a symbol)', () {
    final s = KnitEditorState(pattern: pattern(2, 2))
        .paintCell(0, 0, KnitStitch.k2tog, null) // (k2tog, no color)
        .addPaletteColor(const ColorDto(r: 0, g: 200, b: 0)); // palette index 1
    final colored = s.paintCell(0, 0, KnitStitch.knit, 1, keepStitch: true); // stitch arg ignored
    expect(colored.pattern.chart.rows[0].cells[0].stitch, KnitStitch.k2tog, reason: 'symbol kept');
    expect(colored.pattern.chart.rows[0].cells[0].color, 1, reason: 'color applied');
  });

  test('fillRegion keepStitch colors a region without changing the symbols', () {
    final s = KnitEditorState(pattern: pattern(3, 2))
        .paintCell(0, 0, KnitStitch.purl, null) // (purl, no color) at 0,0
        .addPaletteColor(const ColorDto(r: 0, g: 0, b: 200)); // index 1
    final filled = s.fillRegion(0, 0, 1, 2, KnitStitch.knit, 1, keepStitch: true);
    expect(filled.pattern.chart.rows[0].cells[0].stitch, KnitStitch.purl, reason: 'symbol kept');
    expect(filled.pattern.chart.rows[0].cells[0].color, 1, reason: 'color applied');
    expect(filled.pattern.chart.rows[0].cells[1].stitch, KnitStitch.knit, reason: 'others keep knit');
    expect(filled.pattern.chart.rows[0].cells[1].color, 1);
  });

  test('fillRegion keepColor leaves each cell color in place', () {
    final s = KnitEditorState(pattern: pattern(3, 3))
        .addPaletteColor(const ColorDto(r: 0, g: 0, b: 200)) // index 1
        .paintCell(0, 0, KnitStitch.knit, 1); // (knit, blue) at 0,0
    final filled = s.fillRegion(0, 0, 1, 1, KnitStitch.purl, null, keepColor: true);
    expect(filled.pattern.chart.rows[0].cells[0].stitch, KnitStitch.purl);
    expect(filled.pattern.chart.rows[0].cells[0].color, 1, reason: 'the colored cell keeps its color');
    expect(filled.pattern.chart.rows[1].cells[1].color, isNull, reason: 'an uncolored cell stays so');
  });

  test('fillRegion fills a rectangle as one undo entry; cells outside are untouched', () {
    final s = KnitEditorState(pattern: pattern(4, 4)).fillRegion(1, 1, 2, 2, KnitStitch.purl, null);
    for (final r in [1, 2]) {
      for (final c in [1, 2]) {
        expect(s.pattern.chart.rows[r].cells[c].stitch, KnitStitch.purl, reason: 'cell $r,$c filled');
      }
    }
    expect(s.pattern.chart.rows[0].cells[0].stitch, KnitStitch.knit, reason: 'outside the rect');
    expect(s.pattern.chart.rows[3].cells[3].stitch, KnitStitch.knit);
    expect(s.undo.length, 1, reason: 'one undo entry for the whole fill');
  });

  test('fillRegion normalizes corner order and clamps to the chart', () {
    // Corners given bottom-right -> top-left, and a column past the right edge.
    final s = KnitEditorState(pattern: pattern(3, 3)).fillRegion(2, 9, 0, 1, KnitStitch.purl, null);
    expect(s.pattern.chart.rows[0].cells[1].stitch, KnitStitch.purl);
    expect(s.pattern.chart.rows[2].cells[2].stitch, KnitStitch.purl, reason: 'col 9 clamped to 2');
    expect(s.pattern.chart.rows[0].cells[0].stitch, KnitStitch.knit, reason: 'col 0 outside the rect');
  });

  test('fillRegion with a cable brush is a no-op (cables span columns)', () {
    final p = pattern(3, 3);
    final withCable = KnitPatternDto(
      name: p.name,
      construction: p.construction,
      firstRowSide: p.firstRowSide,
      gauge: p.gauge,
      palette: p.palette,
      legend: const StitchLegendDto(stitches: [
        StitchDefDto(
          symbol: '1/1',
          consumes: 2,
          produces: 2,
          cable: CableDefDto(
              front: 1, back: 1, direction: CrossKind.right, frontPurl: false, backPurl: false),
          macroRows: 1,
        ),
      ]),
      chart: p.chart,
      notes: p.notes,
    );
    final base = KnitEditorState(pattern: withCable);
    expect(identical(base.fillRegion(0, 0, 1, 1, 0, null), base), isTrue,
        reason: 'cable id 0 is not a regular fill -> no-op');
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

  /// A pattern whose rows carry [repeats] (the same spans on every row).
  KnitPatternDto withRepeats(int width, int rows, List<RepeatSpanDto> repeats) {
    final base = pattern(width, rows);
    return KnitPatternDto(
      name: base.name,
      construction: base.construction,
      firstRowSide: base.firstRowSide,
      gauge: base.gauge,
      palette: base.palette,
      legend: base.legend,
      chart: ChartDto(
        width: width,
        rows: [for (final r in base.chart.rows) RowDto(cells: r.cells, repeats: repeats)],
      ),
      notes: base.notes,
    );
  }

  group('repeats on resize (clipped, never silently dropped)', () {
    test('a shrink clips a repeat that still starts inside the chart, and says so', () {
      final p = withRepeats(4, 1, const [RepeatSpanDto(start: 1, end: 4, count: RepeatDto.toEnd())]);
      expect(repeatCutsMessage(repeatCutsOnResize(p, 2, 1)),
          '1 repeat was shortened to fit the chart. Undo to restore.');
      final shrunk = KnitEditorState(pattern: p).resizeChart(2, 1);
      expect(shrunk.pattern.chart.rows[0].repeats,
          const [RepeatSpanDto(start: 1, end: 2, count: RepeatDto.toEnd())]);
      expect(shrunk.undoEdit().pattern.chart.rows[0].repeats,
          const [RepeatSpanDto(start: 1, end: 4, count: RepeatDto.toEnd())],
          reason: 'undo restores the repeat as authored');
    });

    test('a repeat wholly past the new edge is removed, with a notice', () {
      final p = withRepeats(6, 1, const [RepeatSpanDto(start: 4, end: 6, count: RepeatDto.times(count: 2))]);
      final cuts = repeatCutsOnResize(p, 3, 1);
      expect((cuts.clipped, cuts.removed), (0, 1));
      expect(repeatCutsMessage(cuts),
          '1 repeat was removed with the stitches it covered. Undo to restore.');
      expect(KnitEditorState(pattern: p).resizeChart(3, 1).pattern.chart.rows[0].repeats, isEmpty);
    });

    test('removing rows removes their repeats, and both kinds of change are reported together', () {
      final p = withRepeats(6, 3, const [
        RepeatSpanDto(start: 0, end: 2, count: RepeatDto.times(count: 3)),
        RepeatSpanDto(start: 3, end: 6, count: RepeatDto.toEnd()),
      ]);
      // 3 rows -> 2 removes the top row's 2 repeats; width 6 -> 5 clips the 3..6 repeat on the rest.
      final cuts = repeatCutsOnResize(p, 5, 2);
      expect((cuts.clipped, cuts.removed), (2, 2));
      expect(repeatCutsMessage(cuts),
          '2 repeats were shortened and 2 removed to fit the chart. Undo to restore.');
      final rows = KnitEditorState(pattern: p).resizeChart(5, 2).pattern.chart.rows;
      expect(rows, hasLength(2));
      expect(rows[1].repeats, const [
        RepeatSpanDto(start: 0, end: 2, count: RepeatDto.times(count: 3)),
        RepeatSpanDto(start: 3, end: 5, count: RepeatDto.toEnd()),
      ]);
    });

    test('a resize that leaves every repeat whole says nothing and keeps them', () {
      final p = withRepeats(4, 2, const [RepeatSpanDto(start: 0, end: 2, count: RepeatDto.times(count: 2))]);
      expect(repeatCutsOnResize(p, 6, 3).isEmpty, isTrue);
      expect(repeatCutsMessage(repeatCutsOnResize(p, 2, 2)), isNull, reason: 'ends exactly at the edge');
      final grown = KnitEditorState(pattern: p).resizeChart(6, 3).pattern.chart.rows;
      expect(grown[0].repeats, p.chart.rows[0].repeats);
      expect(grown[2].repeats, isEmpty, reason: 'a new row has no repeat');
    });
  });

  group('marking and clearing repeats', () {
    test('markRepeat marks the selected columns on every selected row as one undo entry', () {
      final s = KnitEditorState(pattern: pattern(6, 3))
          .markRepeat(0, 4, 1, 1, const RepeatDto.times(count: 3)); // corners in any order
      const span = RepeatSpanDto(start: 1, end: 5, count: RepeatDto.times(count: 3));
      expect(s.pattern.chart.rows[0].repeats, const [span]);
      expect(s.pattern.chart.rows[1].repeats, const [span]);
      expect(s.pattern.chart.rows[2].repeats, isEmpty, reason: 'outside the selection');
      expect(s.pattern.chart.rows[0].cells, pattern(6, 3).chart.rows[0].cells,
          reason: 'the drawn cells are never duplicated or changed');
      expect(s.undo, hasLength(1));
      expect(s.undoEdit().pattern.chart.rows[0].repeats, isEmpty);
    });

    test('a new repeat replaces any it overlaps and keeps the row sorted by column', () {
      final s = KnitEditorState(pattern: pattern(8, 1))
          .markRepeat(0, 5, 0, 7, const RepeatDto.times(count: 2))
          .markRepeat(0, 0, 0, 1, const RepeatDto.toEnd())
          .markRepeat(0, 4, 0, 6, const RepeatDto.times(count: 4)); // overlaps 5..8
      expect(s.pattern.chart.rows[0].repeats, const [
        RepeatSpanDto(start: 0, end: 2, count: RepeatDto.toEnd()),
        RepeatSpanDto(start: 4, end: 7, count: RepeatDto.times(count: 4)),
      ]);
    });

    test('marking the same repeat again, or a count below 1, is a no-op', () {
      final once = KnitEditorState(pattern: pattern(4, 1)).markRepeat(0, 0, 0, 1, const RepeatDto.toEnd());
      expect(identical(once.markRepeat(0, 0, 0, 1, const RepeatDto.toEnd()), once), isTrue);
      expect(identical(once.markRepeat(0, 2, 0, 3, const RepeatDto.times(count: 0)), once), isTrue,
          reason: 'a repeat worked 0 times is never created by the editor');
    });

    test('clearRepeats removes only the repeats the region overlaps', () {
      final s = KnitEditorState(pattern: pattern(8, 2))
          .markRepeat(0, 0, 1, 1, const RepeatDto.times(count: 2))
          .markRepeat(0, 4, 1, 6, const RepeatDto.toEnd());
      expect(s.hasRepeatIn(0, 5, 0, 5), isTrue);
      expect(s.hasRepeatIn(0, 2, 1, 3), isFalse);
      final cleared = s.clearRepeats(1, 5, 1, 5);
      expect(cleared.pattern.chart.rows[1].repeats,
          const [RepeatSpanDto(start: 0, end: 2, count: RepeatDto.times(count: 2))]);
      expect(cleared.pattern.chart.rows[0].repeats, hasLength(2), reason: 'row 0 was not selected');
      expect(cleared.undo.length, s.undo.length + 1);
      expect(identical(cleared.clearRepeats(1, 5, 1, 5), cleared), isTrue, reason: 'nothing left to clear');
    });

    test('painting keeps a row\'s repeats', () {
      final s = KnitEditorState(pattern: pattern(4, 1))
          .markRepeat(0, 0, 0, 3, const RepeatDto.toEnd())
          .paintCell(0, 1, KnitStitch.purl, null);
      expect(s.pattern.chart.rows[0].repeats,
          const [RepeatSpanDto(start: 0, end: 4, count: RepeatDto.toEnd())]);
    });
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
  group('isDirty (the dirty-on-exit baseline)', () {
    test('no baseline (nothing loaded yet) is never dirty', () {
      final s = KnitEditorState(pattern: pattern(2, 2)).paintCell(0, 0, KnitStitch.purl, null);
      expect(s.isDirty, isFalse);
    });

    test('a freshly loaded pattern is clean; an edit is dirty; a no-op edit stays clean', () {
      final p = pattern(2, 2);
      final loaded = KnitEditorState(pattern: p, saved: p);
      expect(loaded.isDirty, isFalse);
      expect(loaded.paintCell(0, 0, KnitStitch.knit, null).isDirty, isFalse, reason: 'no change');
      expect(loaded.paintCell(0, 0, KnitStitch.purl, null).isDirty, isTrue);
      expect(loaded.setNotes('cast on loosely').isDirty, isTrue);
    });

    test('undo back to the saved pattern reads clean; redo reads dirty again', () {
      final p = pattern(2, 2);
      final edited = KnitEditorState(pattern: p, saved: p)
          .paintCell(0, 0, KnitStitch.purl, null)
          .paintCell(1, 1, KnitStitch.purl, null);
      final undone = edited.undoEdit().undoEdit();
      expect(undone.isDirty, isFalse, reason: 'undo restores the exact saved instance');
      expect(undone.redoEdit().isDirty, isTrue);
    });

    test('a hand-reverted edit reads dirty (the safe direction)', () {
      final p = pattern(2, 2);
      final s = KnitEditorState(pattern: p, saved: p)
          .paintCell(0, 0, KnitStitch.purl, null)
          .paintCell(0, 0, KnitStitch.knit, null);
      expect(s.isDirty, isTrue);
    });

    test('markSaved moves the baseline to the persisted instance, keeping history', () {
      final p = pattern(2, 2);
      final edited = KnitEditorState(pattern: p, saved: p).paintCell(0, 0, KnitStitch.purl, null);
      final saved = edited.markSaved(edited.pattern);
      expect(saved.isDirty, isFalse);
      expect(saved.undo.length, 1, reason: 'history untouched');
      expect(saved.undoEdit().isDirty, isTrue, reason: 'the pre-save pattern is now unsaved');
      // An edit that landed while the write was in flight: the baseline is the WRITTEN instance.
      final later = edited.paintCell(1, 1, KnitStitch.purl, null);
      expect(later.markSaved(edited.pattern).isDirty, isTrue);
    });
  });
}
