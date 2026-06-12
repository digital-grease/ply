import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/draft_repository.dart';
import 'package:ply/src/models/draft_doc.dart';
import 'package:ply/src/state/draft_editor_notifier.dart';
import 'package:ply/src/state/editor_providers.dart';
import 'package:ply/src/widgets/dimensions_bar.dart';
import 'package:ply/src/widgets/draft_grids.dart';
import 'package:ply/src/widgets/draft_layout.dart';
import 'package:ply/src/widgets/integrated_draft_view.dart';

// Host widget tests for the integrated view's INTERACTION: a tap/drag routes through the real
// content-space Listener + DraftLayout.hitTest to the right cell, the stroke driver coalesces a
// drag into one undo entry, and HAND mode does not paint. The drawdown render is faked (the grids
// and gestures don't depend on it), so these run on the host VM with no native lib.

class FakeRepo extends DraftRepository {
  @override
  Future<ui.Image> renderDto(DraftDoc doc, {required int cellPx}) => _stubImage();

  /// Builds a real grown/shrunk doc at the requested dims (empty cells) so a grow makes the
  /// integrated grids appear. The engine's prune/pad is cargo-tested; here we only need the
  /// dims to drive the placeholder<->grids transition.
  @override
  Future<DraftDoc> resizeDoc(
    DraftDoc doc, {
    required int ends,
    required int picks,
    required int shafts,
    required int treadles,
  }) async {
    return DraftDoc(
      name: doc.name,
      shafts: shafts,
      treadles: treadles,
      shed: doc.shed,
      unit: doc.unit,
      threading: List.generate(ends, (_) => const <int>[]),
      drive: DraftTreadled(
        tieup: List.generate(treadles, (_) => const <int>[]),
        treadling: List.generate(picks, (_) => const <int>[]),
      ),
      palette: doc.palette,
      warpColors: List.filled(ends, 0),
      weftColors: List.filled(picks, 0),
      notes: doc.notes,
    );
  }
}

Future<ui.Image> _stubImage() {
  final c = Completer<ui.Image>();
  ui.decodeImageFromPixels(
      Uint8List.fromList(const [0, 0, 0, 255]), 1, 1, ui.PixelFormat.rgba8888, c.complete);
  return c.future;
}

/// ends 4, picks 4, shafts 2, treadles 2; threading all on shaft 1 so a paint to shaft 2 shows.
DraftDoc fixture() => DraftDoc(
      name: 'f',
      shafts: 2,
      treadles: 2,
      shed: Shed.rising,
      unit: MeasureUnit.inches,
      threading: const [
        [1],
        [1],
        [1],
        [1],
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
      palette: const [DraftColor(r: 255, g: 255, b: 255), DraftColor(r: 0, g: 0, b: 0)],
      warpColors: const [0, 0, 0, 0],
      weftColors: const [1, 1, 1, 1],
      notes: '',
    );

const int kCell = 16;
final DraftLayout kLayout = DraftLayout(
    ends: 4, picks: 4, shafts: 2, treadles: 2, hasTieup: true, cell: kCell.toDouble());

Future<ProviderContainer> pumpView(
  WidgetTester tester, {
  EditorTool tool = EditorTool.pencil,
}) async {
  final c = ProviderContainer(
    overrides: [repositoryProvider.overrideWithValue(FakeRepo())],
  );
  addTearDown(c.dispose);
  c.read(zoomCellProvider.notifier).state = kCell;
  c.read(editorToolProvider.notifier).state = tool;
  c.read(draftEditorProvider.notifier).load(fixture());
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: const MaterialApp(home: Scaffold(body: IntegratedDraftView())),
    ),
  );
  await tester.pump();
  return c;
}

/// A liftplan draft (no tie-up; right band is shafts-wide).
DraftDoc liftplanFixture() => DraftDoc(
      name: 'lp',
      shafts: 2,
      treadles: 0,
      shed: Shed.rising,
      unit: MeasureUnit.inches,
      threading: const [
        [1],
        [1],
        [1],
        [1],
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

Future<ProviderContainer> pumpLiftplan(WidgetTester tester) async {
  final c = ProviderContainer(overrides: [repositoryProvider.overrideWithValue(FakeRepo())]);
  addTearDown(c.dispose);
  c.read(zoomCellProvider.notifier).state = kCell;
  c.read(draftEditorProvider.notifier).load(liftplanFixture());
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: const MaterialApp(home: Scaffold(body: IntegratedDraftView())),
    ),
  );
  await tester.pump();
  return c;
}

Offset _origin(WidgetTester t) => t.getTopLeft(find.byType(IntegratedDraftView));
Offset threadingC(WidgetTester t, int end, int shaft) =>
    _origin(t) + kLayout.threadingRect.topLeft + kLayout.threading.rectFor(end, shaft).center;
Offset tieupC(WidgetTester t, int treadle, int shaft) =>
    _origin(t) + kLayout.tieupRect.topLeft + kLayout.tieup.rectFor(treadle, shaft).center;
Offset rightC(WidgetTester t, int col, int pick) =>
    _origin(t) + kLayout.rightRect.topLeft + kLayout.right.rectFor(col, pick).center;
Offset warpC(WidgetTester t, int end) =>
    _origin(t) + kLayout.warpColorRect.topLeft + kLayout.warpColor.rectFor(end, 0).center;
Offset weftC(WidgetTester t, int pick) =>
    _origin(t) + kLayout.weftColorRect.topLeft + kLayout.weftColor.rectFor(1, pick).center;

void main() {
  testWidgets('tapping a warp-color cell paints the active brush onto that end', (tester) async {
    final c = await pumpView(tester); // fixture warpColors [0,0,0,0]
    c.read(activePaletteColorProvider.notifier).state = 1; // brush = black (index 1)
    await tester.pump();
    await tester.tapAt(warpC(tester, 2));
    await tester.pump();
    expect(c.read(draftEditorProvider).draft.warpColors[1], 1, reason: 'end 2 painted brush 1');
    expect(c.read(draftEditorProvider).undo.length, 1, reason: 'one undo entry');
  });

  testWidgets('tapping a weft-color cell paints the active brush onto that pick', (tester) async {
    final c = await pumpView(tester); // fixture weftColors [1,1,1,1]
    c.read(activePaletteColorProvider.notifier).state = 0; // brush = white (index 0)
    await tester.pump();
    await tester.tapAt(weftC(tester, 0)); // pick 0
    await tester.pump();
    expect(c.read(draftEditorProvider).draft.weftColors[0], 0, reason: 'pick 0 painted brush 0');
  });

  testWidgets('tapping a threading cell sets that end\'s shaft', (tester) async {
    final c = await pumpView(tester);
    await tester.tapAt(threadingC(tester, 1, 2));
    await tester.pump();
    expect(c.read(draftEditorProvider).draft.threading[0], equals([2]));
    expect(c.read(draftEditorProvider).undo.length, 1);
  });

  testWidgets('a drag across threading paints a run as ONE undo entry', (tester) async {
    final c = await pumpView(tester);
    final g = await tester.startGesture(threadingC(tester, 1, 2));
    await tester.pump();
    await g.moveTo(threadingC(tester, 2, 2));
    await tester.pump();
    await g.moveTo(threadingC(tester, 3, 2));
    await tester.pump();
    await g.up();
    await tester.pump();

    final th = c.read(draftEditorProvider).draft.threading;
    expect(th[0], equals([2]));
    expect(th[1], equals([2]));
    expect(th[2], equals([2]));
    expect(th[3], equals([1]), reason: 'end 4 was not in the drag -> untouched');
    expect(c.read(draftEditorProvider).undo.length, 1, reason: 'one undo entry for the whole drag');
  });

  testWidgets('tapping a tie-up cell erases a filled tie', (tester) async {
    final c = await pumpView(tester);
    await tester.tapAt(tieupC(tester, 1, 1)); // tieup[0]=[1] is filled -> erase
    await tester.pump();
    expect((c.read(draftEditorProvider).draft.drive as DraftTreadled).tieup[0], isEmpty);
  });

  testWidgets('tapping a right-band cell sets that pick\'s treadle', (tester) async {
    final c = await pumpView(tester);
    await tester.tapAt(rightC(tester, 2, 0)); // pick 0, treadle 2
    await tester.pump();
    expect((c.read(draftEditorProvider).draft.drive as DraftTreadled).treadling[0], equals([2]));
  });

  testWidgets('in HAND mode a tap does NOT paint (it scrolls)', (tester) async {
    final c = await pumpView(tester, tool: EditorTool.hand);
    await tester.tapAt(tieupC(tester, 1, 1));
    await tester.pump();
    expect(c.read(draftEditorProvider).undo, isEmpty, reason: 'hand mode never paints');
    expect((c.read(draftEditorProvider).draft.drive as DraftTreadled).tieup[0], equals([1]),
        reason: 'the cell is unchanged');
  });

  testWidgets('a SECOND finger does not corrupt or split the single stroke', (tester) async {
    final c = await pumpView(tester);
    final f1 = await tester.startGesture(threadingC(tester, 1, 2), pointer: 1);
    await tester.pump();
    // A second finger lands on a different cell mid-stroke; it must be ignored.
    final f2 = await tester.startGesture(threadingC(tester, 4, 2), pointer: 2);
    await tester.pump();
    await f1.moveTo(threadingC(tester, 2, 2));
    await tester.pump();
    await f1.up();
    await f2.up();
    await tester.pump();

    final th = c.read(draftEditorProvider).draft.threading;
    expect(th[0], equals([2]), reason: 'finger 1 painted end 1');
    expect(th[1], equals([2]), reason: 'finger 1 painted end 2');
    expect(th[3], equals([1]), reason: 'the second finger (end 4) was ignored');
    expect(c.read(draftEditorProvider).undo.length, 1, reason: 'one stroke -> one undo entry');
  });

  testWidgets('an ERASE drag holds the erase value across a mixed run (no per-cell re-invert)',
      (tester) async {
    final c = await pumpView(tester);
    // First make end 2 / shaft 1 empty so the erase drag crosses a mixed (on, off, on) run.
    await tester.tapAt(threadingC(tester, 2, 1));
    await tester.pump();
    expect(c.read(draftEditorProvider).draft.threading[1], isEmpty);

    // Drag across shaft-1 from end1 (on -> erase) over end2 (already off) to end3 (on).
    final g = await tester.startGesture(threadingC(tester, 1, 1));
    await tester.pump();
    await g.moveTo(threadingC(tester, 2, 1));
    await tester.pump();
    await g.moveTo(threadingC(tester, 3, 1));
    await tester.pump();
    await g.up();
    await tester.pump();

    final th = c.read(draftEditorProvider).draft.threading;
    expect(th[0], isEmpty, reason: 'end 1 erased');
    expect(th[1], isEmpty, reason: 'end 2 stays OFF (held erase; per-cell re-invert would FILL it)');
    expect(th[2], isEmpty, reason: 'end 3 erased');
  });

  testWidgets('a LIFTPLAN draft routes right-band taps (col=shaft) and builds no tie-up region',
      (tester) async {
    final c = await pumpLiftplan(tester);
    // No tie-up region for a liftplan, so the layout's right band is shafts-wide at the same x.
    final layout = DraftLayout(
        ends: 4, picks: 4, shafts: 2, treadles: 0, hasTieup: false, cell: kCell.toDouble());
    final origin = _origin(tester);
    final tap = origin + layout.rightRect.topLeft + layout.right.rectFor(2, 0).center; // shaft2, pick0
    await tester.tapAt(tap);
    await tester.pump();
    expect((c.read(draftEditorProvider).draft.drive as DraftLiftplan).liftplan[0], equals([2]),
        reason: 'pick 0 raises shaft 2 (col=shaft semantics)');
  });

  testWidgets('PENCIL freezes scroll physics; HAND leaves the draft scrollable', (tester) async {
    // Pin the scroll-vs-paint conditional directly: pencil -> NeverScrollableScrollPhysics (the
    // Listener owns drags), hand -> default physics (the scroll views pan). Both scroll views get
    // the same physics, so checking the outer (vertical) one is enough. Toggle within ONE
    // container (re-pumping a second container would orphan an autoDispose timer).
    ScrollPhysics? physics() => tester
        .widget<SingleChildScrollView>(find.byType(SingleChildScrollView).first)
        .physics;

    final c = await pumpView(tester); // default pencil
    expect(physics(), isA<NeverScrollableScrollPhysics>(),
        reason: 'PENCIL freezes scroll so a drag paints instead of scrolling');

    c.read(editorToolProvider.notifier).state = EditorTool.hand;
    await tester.pump();
    expect(physics(), isNull, reason: 'HAND leaves the default physics so the draft pans');
  });

  testWidgets('blank draft shows the placeholder; growing BOTH axes reveals the editable grids',
      (tester) async {
    // The from-scratch flow: a blank draft (0 ends, 0 picks) can't render a zero-area drawdown, so
    // the view shows a placeholder until BOTH axes are grown via the steppers. Pump the view above
    // a real DimensionsBar (like the editor screen) and drive the transition with stepper taps.
    final c = ProviderContainer(overrides: [repositoryProvider.overrideWithValue(FakeRepo())]);
    addTearDown(c.dispose);
    c.read(zoomCellProvider.notifier).state = kCell;
    c.read(draftEditorProvider.notifier).load(DraftDoc.blank()); // 0 ends, 0 picks
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: const MaterialApp(
        home: Scaffold(
          body: Column(children: [Expanded(child: IntegratedDraftView()), DimensionsBar()]),
        ),
      ),
    ));
    await tester.pump();

    // Blank: placeholder up, no grids.
    expect(find.textContaining('no warp ends or picks'), findsOneWidget);
    expect(find.byType(ThreadingGrid), findsNothing);

    // Grow ends only -> ends>0 but picks==0 is still empty: the placeholder stays (no preview hang).
    await tester.tap(find.byTooltip('More Ends'));
    await tester.pumpAndSettle();
    expect(find.textContaining('no warp ends or picks'), findsOneWidget,
        reason: 'one empty axis still shows the placeholder');
    expect(find.byType(ThreadingGrid), findsNothing);

    // Grow picks -> both axes > 0 -> the grids appear and the placeholder is gone.
    await tester.tap(find.byTooltip('More Picks'));
    await tester.pumpAndSettle();
    expect(find.textContaining('no warp ends or picks'), findsNothing);
    expect(find.byType(ThreadingGrid), findsOneWidget, reason: 'the threading grid is now editable');
    expect(find.byType(RightGrid), findsOneWidget);
  });
}
