import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/models/draft_doc.dart';
import 'package:ply/src/state/draft_editor_notifier.dart';
import 'package:ply/src/widgets/draft_grids.dart';
import 'package:ply/src/widgets/draft_layout.dart';

// Pins the grids' data-slice -> (col,row) cell mapping (1-based offsets, bounds filters, and the
// treadled/liftplan branch), which the deleted tieup_grid_test no longer covers. (The bottom-
// origin flip itself lives in RegionGeom and is covered by draft_layout_test.)

DraftDoc treadled() => DraftDoc(
      name: 't',
      shafts: 2,
      treadles: 2,
      shed: Shed.rising,
      unit: MeasureUnit.inches,
      threading: const [
        [1],
        [2],
        [1],
        [2],
      ],
      drive: DraftTreadled(
        tieup: const [
          [1],
          [2],
        ],
        treadling: const [
          [1],
          [2],
          [1],
          [2],
        ],
      ),
      palette: const [DraftColor(r: 0, g: 0, b: 0)],
      warpColors: const [0, 0, 0, 0],
      weftColors: const [0, 0, 0, 0],
      notes: '',
    );

DraftDoc liftplan() => DraftDoc(
      name: 'lp',
      shafts: 2,
      treadles: 0,
      shed: Shed.rising,
      unit: MeasureUnit.inches,
      threading: const [
        [1],
        [2],
        [1],
        [2],
      ],
      drive: DraftLiftplan(liftplan: const [
        [1],
        [2],
        [1],
        [2],
      ]),
      palette: const [DraftColor(r: 0, g: 0, b: 0)],
      warpColors: const [0, 0, 0, 0],
      weftColors: const [0, 0, 0, 0],
      notes: '',
    );

const RegionGeom threadingGeom = RegionGeom(
    cols: 4, rows: 2, cell: 10, colBase: 1, rowBase: 1, bottomOrigin: true);
const RegionGeom tieupGeom =
    RegionGeom(cols: 2, rows: 2, cell: 10, colBase: 1, rowBase: 1, bottomOrigin: true);
const RegionGeom rightGeom =
    RegionGeom(cols: 2, rows: 4, cell: 10, colBase: 1, rowBase: 0, bottomOrigin: true);

Future<ProviderContainer> pumpGrid(WidgetTester t, DraftDoc doc, Widget grid) async {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  c.read(draftEditorProvider.notifier).load(doc);
  await t.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(home: Scaffold(body: Center(child: grid))),
    ),
  );
  await t.pump();
  return c;
}

List<(int, int)> cellsOf(WidgetTester t, Finder gridFinder) {
  final cp = t.widget<CustomPaint>(
      find.descendant(of: gridFinder, matching: find.byType(CustomPaint)));
  return (cp.painter! as CellGridPainter).cells;
}

void main() {
  testWidgets('ThreadingGrid maps threading[end-1] to (end, shaft) cells', (t) async {
    await pumpGrid(t, treadled(), const ThreadingGrid(geom: threadingGeom));
    final cells = cellsOf(t, find.byType(ThreadingGrid));
    expect(cells.toSet(), {(1, 1), (2, 2), (3, 1), (4, 2)});
  });

  testWidgets('TieupGrid maps tieup[treadle-1] to (treadle, shaft) cells', (t) async {
    await pumpGrid(t, treadled(), const TieupGrid(geom: tieupGeom));
    expect(cellsOf(t, find.byType(TieupGrid)).toSet(), {(1, 1), (2, 2)});
  });

  testWidgets('RightGrid (treadled) maps treadling[pick] to (treadle, pick)', (t) async {
    await pumpGrid(t, treadled(), const RightGrid(geom: rightGeom));
    expect(cellsOf(t, find.byType(RightGrid)).toSet(), {(1, 0), (2, 1), (1, 2), (2, 3)});
  });

  testWidgets('RightGrid (liftplan) maps liftplan[pick] to (shaft, pick) — the OTHER branch',
      (t) async {
    await pumpGrid(t, liftplan(), const RightGrid(geom: rightGeom));
    expect(cellsOf(t, find.byType(RightGrid)).toSet(), {(1, 0), (2, 1), (1, 2), (2, 3)});
  });

  testWidgets('an out-of-range shaft is filtered out of the cell list', (t) async {
    // threading end 1 references shaft 5, which the 2-shaft geom must drop (not crash).
    final doc = treadled().copyWith(threading: const [
      [5],
      [2],
      [1],
      [2],
    ]);
    await pumpGrid(t, doc, const ThreadingGrid(geom: threadingGeom));
    final cells = cellsOf(t, find.byType(ThreadingGrid));
    expect(cells.contains((1, 5)), isFalse, reason: 'shaft 5 is outside the 2-shaft grid');
    expect(cells.toSet(), {(2, 2), (3, 1), (4, 2)});
  });

  // --- color bands (Phase 4.2) ---
  const RegionGeom warpBandGeom =
      RegionGeom(cols: 3, rows: 1, cell: 10, colBase: 1, rowBase: 0, bottomOrigin: false);
  const RegionGeom weftBandGeom =
      RegionGeom(cols: 1, rows: 4, cell: 10, colBase: 1, rowBase: 0, bottomOrigin: true);

  DraftDoc colored() => treadled().copyWith(
        threading: const [
          [1],
          [2],
          [1],
        ],
        palette: const [
          DraftColor(r: 0, g: 0, b: 0), // 0 black
          DraftColor(r: 255, g: 0, b: 0), // 1 red
          DraftColor(r: 0, g: 255, b: 0), // 2 green
        ],
        warpColors: const [1, 2, 0],
        weftColors: const [0, 1, 2, 0],
      );

  List<Color> colorsOf(WidgetTester t, Finder f) {
    final cp = t.widget<CustomPaint>(find.descendant(of: f, matching: find.byType(CustomPaint)));
    return (cp.painter! as ColorBandPainter).colors;
  }

  testWidgets('WarpColorBand paints one palette color per end (warpColors order)', (t) async {
    await pumpGrid(t, colored(), const WarpColorBand(geom: warpBandGeom));
    expect(colorsOf(t, find.byType(WarpColorBand)),
        const [Color(0xFFFF0000), Color(0xFF00FF00), Color(0xFF000000)]); // red, green, black
  });

  testWidgets('WeftColorBand paints one palette color per pick', (t) async {
    await pumpGrid(t, colored(), const WeftColorBand(geom: weftBandGeom));
    expect(colorsOf(t, find.byType(WeftColorBand)),
        const [Color(0xFF000000), Color(0xFFFF0000), Color(0xFF00FF00), Color(0xFF000000)]);
  });

  testWidgets('a SHORT warpColors falls back to palette[0]', (t) async {
    final doc = colored().copyWith(warpColors: const [1]); // 1 entry over 3 ends
    await pumpGrid(t, doc, const WarpColorBand(geom: warpBandGeom));
    expect(colorsOf(t, find.byType(WarpColorBand)),
        const [Color(0xFFFF0000), Color(0xFF000000), Color(0xFF000000)]); // red, black, black
  });

  testWidgets('a dangling color index renders WHITE (matching the engine), not a crash', (t) async {
    final doc = colored().copyWith(warpColors: const [9, 0, 0]); // 9 dangles (palette len 3)
    await pumpGrid(t, doc, const WarpColorBand(geom: warpBandGeom));
    expect(colorsOf(t, find.byType(WarpColorBand)).first, const Color(0xFFFFFFFF),
        reason: 'out-of-range index renders white, exactly as render_rgba does');
  });

  testWidgets('the color bands expose a Semantics label (a11y)', (t) async {
    final handle = t.ensureSemantics();
    await pumpGrid(t, colored(), const WarpColorBand(geom: warpBandGeom));
    expect(find.bySemanticsLabel('Warp colors'), findsOneWidget);
    handle.dispose();
  });

  test('ColorBandPainter.shouldRepaint flips when the colors list changes', () {
    ColorBandPainter make(List<Color> colors) => ColorBandPainter(
        colors: colors,
        cells: const [(1, 0), (2, 0), (3, 0)],
        geom: warpBandGeom,
        line: const Color(0xFF000000),
        background: const Color(0xFFFFFFFF));
    final a = make(const [Color(0xFFFF0000), Color(0xFF00FF00), Color(0xFF000000)]);
    expect(a.shouldRepaint(make(const [Color(0xFFFF0000), Color(0xFF00FF00), Color(0xFF000000)])),
        isFalse);
    expect(a.shouldRepaint(make(const [Color(0xFF0000FF), Color(0xFF00FF00), Color(0xFF000000)])),
        isTrue, reason: 'a color changed');
  });

  test('CellGridPainter.shouldRepaint reflects cell/geom changes', () {
    CellGridPainter make(List<(int, int)> cells, RegionGeom geom) => CellGridPainter(
        cells: cells,
        geom: geom,
        fill: const Color(0xFF000000),
        line: const Color(0xFF000000),
        background: const Color(0xFFFFFFFF));
    final a = make([(1, 1)], threadingGeom);
    expect(a.shouldRepaint(make([(1, 1)], threadingGeom)), isFalse);
    expect(a.shouldRepaint(make([(1, 2)], threadingGeom)), isTrue, reason: 'cells changed');
    expect(a.shouldRepaint(make([(1, 1)], tieupGeom)), isTrue, reason: 'geom changed');
  });
}
