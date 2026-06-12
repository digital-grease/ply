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
