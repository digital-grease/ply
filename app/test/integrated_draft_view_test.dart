import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/draft_repository.dart';
import 'package:ply/src/models/draft_doc.dart';
import 'package:ply/src/state/draft_editor_notifier.dart';
import 'package:ply/src/state/editor_providers.dart';
import 'package:ply/src/widgets/dimensions_bar.dart';
import 'package:ply/src/widgets/draft_grids.dart';
import 'package:ply/src/widgets/draft_layout.dart';
import 'package:ply/src/widgets/editor_view_controls.dart';
import 'package:ply/src/widgets/integrated_draft_view.dart';

// Host widget tests for the integrated view's INTERACTION: a tap/drag routes through the real
// content-space Listener + DraftLayout.hitTest to the right cell, the stroke driver coalesces a
// drag into one undo entry, and HAND mode does not paint. The drawdown render is faked (the grids
// and gestures don't depend on it), so these run on the host VM with no native lib.

class FakeRepo extends DraftRepository {
  @override
  Future<ui.Image> renderDto(
    DraftDoc doc, {
    required int cellPx,
    bool gridlines = false,
    int floatThreshold = 0,
    bool threadTexture = false,
  }) =>
      _stubImage();

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

/// The same 4x4 shape as [fixture], but treadle 1 thrown 3x then treadle 2 (a run of identical
/// picks the structural grid must keep one row per pick).
DraftDoc runsFixture() => fixture().copyWith(
      drive: DraftTreadled(
        tieup: const [
          [1],
          [2],
        ],
        treadling: const [
          [1],
          [1],
          [1],
          [2],
        ],
      ),
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
  // These interaction tests compute tap coordinates from kLayout (a FIXED pitch), so opt out of the
  // open-time auto-fit by marking the zoom user-set.
  c.read(zoomUserSetProvider.notifier).state = true;
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
  c.read(zoomUserSetProvider.notifier).state = true; // opt out of auto-fit; tap math uses kLayout pitch
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
Offset weftMarkerC(WidgetTester t, int entry) =>
    _origin(t) + kLayout.weftMarkerRect.topLeft + kLayout.weftMarker.rectFor(1, entry).center;

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

  testWidgets('tapping a weft-MARKER cell paints THAT pick, even inside a run of identical picks',
      (tester) async {
    final c = await pumpView(tester);
    // Treadle 1 thrown 3x, then treadle 2: the marker beside the treadling is one row per pick, so a
    // tap on row 1 colors pick 1 only (not the whole run).
    c.read(draftEditorProvider.notifier).load(runsFixture());
    await tester.pump();
    c.read(activePaletteColorProvider.notifier).state = 0; // brush = white (index 0)
    await tester.pump();
    await tester.tapAt(weftMarkerC(tester, 1));
    await tester.pump();
    expect(c.read(draftEditorProvider).draft.weftColors, [1, 0, 1, 1], reason: 'only pick 1 painted');
    expect(c.read(draftEditorProvider).undo.length, 1, reason: 'one undo entry');
  });

  testWidgets('tapping a treadling cell inside a run sets THAT pick only', (tester) async {
    final c = await pumpView(tester);
    c.read(draftEditorProvider.notifier).load(runsFixture());
    await tester.pump();
    await tester.tapAt(rightC(tester, 2, 1)); // pick 1 -> treadle 2
    await tester.pump();
    expect((c.read(draftEditorProvider).draft.drive as DraftTreadled).treadling, [
      [1],
      [2],
      [1],
      [2],
    ]);
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

  testWidgets('a SECOND finger seals the stroke and starts navigate (no paint corruption)',
      (tester) async {
    final c = await pumpView(tester);
    final f1 = await tester.startGesture(threadingC(tester, 1, 2), pointer: 1); // paints end 1
    await tester.pump();
    // A second finger lands: two fingers = navigate (any tool), so it must SEAL the one-cell stroke
    // and take over as a gesture rather than extend or split the paint.
    final f2 = await tester.startGesture(threadingC(tester, 4, 2), pointer: 2);
    await tester.pump();
    await f1.moveTo(threadingC(tester, 2, 2)); // now part of the 2-finger gesture -> no paint
    await tester.pump();
    await f1.up();
    await f2.up();
    await tester.pump();

    final th = c.read(draftEditorProvider).draft.threading;
    expect(th[0], equals([2]), reason: 'end 1 was painted before the 2nd finger landed');
    expect(th[1], equals([1]), reason: 'end 2 NOT painted — the 2nd finger started navigate');
    expect(th[3], equals([1]), reason: 'the 2nd finger never painted end 4');
    expect(c.read(draftEditorProvider).undo.length, 1, reason: 'one sealed stroke -> one undo entry');
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
    // Widen the surface so the DimensionsBar's scrollable chips + steppers are all on-screen (the
    // row gained a Structure chip), keeping 'More Ends'/'More Picks' tappable at a fixed offset.
    tester.view.physicalSize = const Size(1600, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = ProviderContainer(overrides: [repositoryProvider.overrideWithValue(FakeRepo())]);
    addTearDown(c.dispose);
    c.read(zoomCellProvider.notifier).state = kCell;
    c.read(zoomUserSetProvider.notifier).state = true; // opt out of auto-fit (grids appear at kCell)
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

    // M4 a11y: the formerly-silent grids + drawdown carry descriptive Semantics summaries.
    final handle = tester.ensureSemantics();
    expect(find.bySemanticsLabel(RegExp('Threading:')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('Tie-up:')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('Treadling:|Liftplan:')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('Drawdown, ')), findsOneWidget);
    handle.dispose();
  });

  // Auto-fit: a freshly-opened draft sizes its pitch to fill the viewport (until the user zooms).
  group('open-time auto-fit', () {
    // A LOOSE-constrained Scaffold body at a fixed 800x600 viewport — the PRODUCTION shape, where the
    // view's scroll axes are unbounded by the parent so its own context.size shrink-wraps to content.
    // This is what distinguishes the LayoutBuilder viewport (correct) from a content-pinned read (the
    // bug that made auto-fit a silent no-op): a buggy read would leave the pitch at 16, the fix -> 48.
    Future<ProviderContainer> pumpAutoFit(
      WidgetTester tester, {
      required bool userSet,
      int startCell = 16,
    }) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final c = ProviderContainer(
        overrides: [repositoryProvider.overrideWithValue(FakeRepo())],
      );
      addTearDown(c.dispose);
      c.read(zoomCellProvider.notifier).state = startCell;
      c.read(zoomUserSetProvider.notifier).state = userSet;
      c.read(draftEditorProvider.notifier).load(fixture()); // 7 cells wide x 7 tall
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: const MaterialApp(home: Scaffold(body: IntegratedDraftView())),
        ),
      );
      await tester.pump(); // run the post-frame auto-fit
      await tester.pump(); // settle the resulting provider write
      return c;
    }

    testWidgets('fills the viewport with the largest fitting level on open', (tester) async {
      // 7-cell axes in an 800x600 viewport: pitch 48 -> 336px fits both; it is the largest level.
      final c = await pumpAutoFit(tester, userSet: false);
      expect(c.read(zoomCellProvider), 48);
      expect(c.read(zoomUserSetProvider), isTrue, reason: 'auto-fit claims the guard (one-shot)');
    });

    testWidgets('a manual zoom (user-set) is never overridden by auto-fit', (tester) async {
      final c = await pumpAutoFit(tester, userSet: true, startCell: 8);
      expect(c.read(zoomCellProvider), 8, reason: 'auto-fit must not stomp the user pitch');
    });
  });

  group('stepZoomLevel (pure)', () {
    test('steps up/down through the levels', () {
      expect(stepZoomLevel(16, 1), 24);
      expect(stepZoomLevel(16, -1), 12);
    });
    test('an off-level pitch (e.g. left by a pinch) snaps to the nearest level in the step direction',
        () {
      expect(stepZoomLevel(40, 1), 48, reason: 'next level above 40');
      expect(stepZoomLevel(40, -1), 32, reason: 'next level below 40');
    });
    test('saturates at the pinch bounds past the ends of the level list', () {
      expect(stepZoomLevel(48, 1), maxCellPx, reason: 'no level above 48 -> max');
      expect(stepZoomLevel(8, -1), minCellPx, reason: 'no level below 8 -> min');
      expect(stepZoomLevel(maxCellPx, 1), maxCellPx);
      expect(stepZoomLevel(minCellPx, -1), minCellPx);
    });
  });

  group('view controls (now in the dimensions bar)', () {
    Future<ProviderContainer> pumpControls(WidgetTester tester) async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(zoomCellProvider.notifier).state = 16;
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(home: Scaffold(body: Center(child: EditorViewControls()))),
      ));
      await tester.pump();
      return c;
    }

    testWidgets('Zoom in / Zoom out step the pitch', (tester) async {
      final c = await pumpControls(tester);
      await tester.tap(find.byTooltip('Zoom in'));
      await tester.pump();
      expect(c.read(zoomCellProvider), 24);
      await tester.tap(find.byTooltip('Zoom out'));
      await tester.pump();
      expect(c.read(zoomCellProvider), 16);
    });

    testWidgets('Fit to view re-arms the auto-fit guard', (tester) async {
      final c = await pumpControls(tester);
      c.read(zoomUserSetProvider.notifier).state = true;
      await tester.tap(find.byTooltip('Fit to view'));
      await tester.pump();
      expect(c.read(zoomUserSetProvider), isFalse,
          reason: 'Fit clears the guard so the draft view re-fits on its next build');
    });

    testWidgets('the pan/draw toggle flips the editor tool', (tester) async {
      final c = await pumpControls(tester);
      await tester.tap(find.byTooltip('Pan the draft'));
      await tester.pump();
      expect(c.read(editorToolProvider), EditorTool.hand);
      await tester.tap(find.byTooltip('Draw on the draft'));
      await tester.pump();
      expect(c.read(editorToolProvider), EditorTool.pencil);
    });
  });

  group('two-finger navigate (pinch-zoom, any tool, via the raw Listener)', () {
    // Two pointers in the read-only drawdown area so a single-finger PENCIL touch never paints; the
    // navigate uses only the DISTANCE between pointers, so the canvas origin offset is irrelevant.
    Offset a(WidgetTester t) => _origin(t) + const Offset(20, 70);
    Offset b(WidgetTester t) => _origin(t) + const Offset(40, 70); // 20px from a

    testWidgets('a two-finger spread zooms in (HAND)', (tester) async {
      final c = await pumpView(tester, tool: EditorTool.hand);
      expect(c.read(zoomCellProvider), kCell);
      final f1 = await tester.startGesture(a(tester), pointer: 1);
      final f2 = await tester.startGesture(b(tester), pointer: 2); // dist 20
      await tester.pump();
      await f2.moveTo(_origin(tester) + const Offset(60, 70)); // dist 40 -> 2x
      await tester.pump();
      expect(c.read(zoomCellProvider), greaterThan(kCell), reason: 'spreading fingers zooms in');
      await f1.up();
      await f2.up();
      await tester.pump();
    });

    testWidgets('pinching fingers together zooms out (HAND)', (tester) async {
      final c = await pumpView(tester, tool: EditorTool.hand);
      final f1 = await tester.startGesture(a(tester), pointer: 1);
      final f2 = await tester.startGesture(
          _origin(tester) + const Offset(60, 70), pointer: 2); // dist 40
      await tester.pump();
      await f2.moveTo(b(tester)); // dist 20 -> 0.5x
      await tester.pump();
      expect(c.read(zoomCellProvider), lessThan(kCell), reason: 'closing fingers zooms out');
      await f1.up();
      await f2.up();
      await tester.pump();
    });

    testWidgets('a two-finger spread ALSO zooms in PENCIL mode (direct gesture, any tool)',
        (tester) async {
      final c = await pumpView(tester); // pencil: one finger draws, two fingers navigate
      final f1 = await tester.startGesture(a(tester), pointer: 1);
      final f2 = await tester.startGesture(b(tester), pointer: 2); // dist 20
      await tester.pump();
      await f2.moveTo(_origin(tester) + const Offset(80, 70)); // dist 60 -> 3x
      await tester.pump();
      expect(c.read(zoomCellProvider), greaterThan(kCell),
          reason: 'two fingers navigate even in pencil mode');
      await f1.up();
      await f2.up();
      await tester.pump();
    });
  });

  // --- M7-09: the structural draft. Pixel-level proof that drawdown cell k sits exactly under
  // threading column k and beside treadling row k, for a draft with NONUNIFORM yarn thickness and a
  // run of identical picks, at several zooms and device pixel ratios. ---
  group('structural alignment (thickness ignored, one treadling row per pick)', () {
    // Warp thickness [1,2,3,1] is the audit's R-12 case (stretched, its column edges fell at 0.57,
    // 1.71, 3.43 cells); weft [2,1,1,3] does the same to the rows. Treadle 1 x3 then treadle 2.
    DraftDoc thickRuns() => runsFixture().copyWith(
          warpThickness: const [1.0, 2.0, 3.0, 1.0],
          weftThickness: const [2.0, 1.0, 1.0, 3.0],
        );

    for (final cell in [8, 13, 16]) {
      for (final dpr in [1.0, 2.0, 3.0]) {
        testWidgets('pitch $cell at ${dpr}x: drawdown (end, pick) lies under threading end and '
            'beside treadling pick', (tester) async {
          // Pre-decode (outside the fake-async zone) the bitmap the engine would return for the
          // structural draft AND for the thickness-bearing draft, so the fake below can answer like
          // the engine for whichever doc the editor asks it to render.
          final doc = thickRuns();
          final images = await tester.runAsync(() async => {
                _thicknessKey(structuralDraft(doc)): await encodeCells(structuralDraft(doc), previewCellPx),
                _thicknessKey(doc): await encodeCells(doc, previewCellPx),
              });
          final thick = images![_thicknessKey(doc)]!;
          expect(thick.width, isNot(4 * previewCellPx),
              reason: 'fixture sanity: a thickness-aware bitmap really has nonuniform columns');
          final repo = GeometryRepo(images);

          tester.view.physicalSize = Size(500 * dpr, 500 * dpr);
          tester.view.devicePixelRatio = dpr;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final c = ProviderContainer(overrides: [repositoryProvider.overrideWithValue(repo)]);
          addTearDown(c.dispose);
          c.read(zoomCellProvider.notifier).state = cell;
          c.read(zoomUserSetProvider.notifier).state = true; // keep this exact pitch
          c.read(draftEditorProvider.notifier).load(doc);
          const boundaryKey = Key('canvas');
          await tester.pumpWidget(UncontrolledProviderScope(
            container: c,
            child: const MaterialApp(
              home: Scaffold(
                body: Align(
                  alignment: Alignment.topLeft,
                  child: RepaintBoundary(key: boundaryKey, child: IntegratedDraftView()),
                ),
              ),
            ),
          ));
          await tester.pump();
          await tester.pump();

          // The editor rendered the STRUCTURAL draft only, and kept the thickness in the document.
          expect(repo.rendered, isNotEmpty);
          for (final d in repo.rendered) {
            expect(d.warpThickness, isEmpty, reason: 'editor render ignores warp thickness');
            expect(d.weftThickness, isEmpty, reason: 'editor render ignores weft thickness');
          }
          expect(c.read(draftEditorProvider).draft.warpThickness, [1.0, 2.0, 3.0, 1.0]);
          expect(c.read(draftEditorProvider).draft.weftThickness, [2.0, 1.0, 1.0, 3.0]);

          final origin = tester.getTopLeft(find.byKey(boundaryKey));
          final threadingGeom = tester.widget<ThreadingGrid>(find.byType(ThreadingGrid)).geom;
          final rightGeom = tester.widget<RightGrid>(find.byType(RightGrid)).geom;
          final threadingAt = tester.getTopLeft(find.byType(ThreadingGrid));
          final rightAt = tester.getTopLeft(find.byType(RightGrid));
          expect(rightGeom.rows, 4, reason: 'one treadling row per pick, the run is not grouped');
          expect(tester.getSize(find.byType(RightGrid)).height,
              tester.getSize(find.byType(RawImage)).height,
              reason: 'treadling band and drawdown are the same height');

          final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(boundaryKey));
          final pixels = await tester.runAsync(() async {
            final shot = await boundary.toImage(pixelRatio: dpr);
            final data = await shot.toByteData(format: ui.ImageByteFormat.rawRgba);
            final out = (shot.width, data!.buffer.asUint8List());
            shot.dispose();
            return out;
          });
          final (shotWidth, bytes) = pixels!;
          Color sample(Offset global) {
            final local = (global - origin) * dpr;
            final i = (local.dy.floor() * shotWidth + local.dx.floor()) * 4;
            return Color.fromARGB(bytes[i + 3], bytes[i], bytes[i + 1], bytes[i + 2]);
          }

          final primary = Theme.of(tester.element(find.byType(RightGrid))).colorScheme.primary;
          const treadleOf = [1, 1, 1, 2];
          for (var pick = 0; pick < 4; pick++) {
            final y = rightAt.dy + rightGeom.rectFor(1, pick).center.dy;
            for (var end = 1; end <= 4; end++) {
              final x = threadingAt.dx + threadingGeom.rectFor(end, 1).center.dx;
              expect(sample(Offset(x, y)), cellColor(end, pick),
                  reason: 'drawdown under threading end $end, beside treadling pick $pick');
            }
            // Treadling row `pick` is that pick's own row: its treadle cell is filled, the other
            // treadle's cell is not.
            final pressed = treadleOf[pick];
            final other = pressed == 1 ? 2 : 1;
            expect(sample(rightAt + rightGeom.rectFor(pressed, pick).center), primary,
                reason: 'pick $pick presses treadle $pressed on ITS row');
            expect(sample(rightAt + rightGeom.rectFor(other, pick).center), isNot(primary),
                reason: 'pick $pick does not press treadle $other');
          }
        });
      }
    }
  });
}

/// The doc's thickness as a lookup key (the only field the fake engine sizes the bitmap by).
String _thicknessKey(DraftDoc d) => '${d.warpThickness}|${d.weftThickness}';

/// The color [GeometryRepo] paints cell (end 1-based, pick 0-based), unique per cell.
Color cellColor(int end, int pick) => Color.fromARGB(255, end * 40, pick * 40 + 20, 90);

/// The engine's per-thread pixel extents (mirrors ply-weave `thread_extents`): the thinnest positive
/// thread is [base] px, thicker ones scale up (ratio clamped to 6), and no thickness is uniform.
List<int> engineExtents(List<double> thickness, int n, int base) {
  final positive = thickness.take(n).where((t) => t.isFinite && t > 0);
  if (positive.isEmpty) return List.filled(n, base);
  final min = positive.reduce((a, b) => a < b ? a : b);
  return [
    for (var i = 0; i < n; i++)
      (() {
        final t = i < thickness.length && thickness[i].isFinite && thickness[i] > 0 ? thickness[i] : min;
        final r = (base * (t / min).clamp(1.0, 6.0)).round();
        return r < 1 ? 1 : r;
      })(),
  ];
}

/// Rasterize [doc] the way the engine LAYS OUT its drawdown (variable extents from thickness, end 1
/// at the RIGHT, pick 0 at the TOP), filling each (end, pick) cell with [cellColor]. Must run in real
/// async (decodeImageFromPixels).
Future<ui.Image> encodeCells(DraftDoc doc, int cellPx) {
  final colW = engineExtents(doc.warpThickness, doc.ends, cellPx);
  final rowH = engineExtents(doc.weftThickness, doc.picks, cellPx);
  final width = colW.fold(0, (a, b) => a + b);
  final height = rowH.fold(0, (a, b) => a + b);
  final rgba = Uint8List(width * height * 4);
  var y = 0;
  for (var pick = 0; pick < doc.picks; pick++) {
    for (var dy = 0; dy < rowH[pick]; dy++, y++) {
      var x = 0;
      // Left to right on screen is end N down to end 1 (end 1 at the right).
      for (var end = doc.ends; end >= 1; end--) {
        final color = cellColor(end, pick);
        for (var dx = 0; dx < colW[end - 1]; dx++, x++) {
          final i = (y * width + x) * 4;
          rgba[i] = (color.r * 255).round();
          rgba[i + 1] = (color.g * 255).round();
          rgba[i + 2] = (color.b * 255).round();
          rgba[i + 3] = 255;
        }
      }
    }
  }
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(rgba, width, height, ui.PixelFormat.rgba8888, completer.complete);
  return completer.future;
}

/// A repository that answers renderDto with the pre-decoded bitmap matching the requested doc's
/// thickness, and records every doc it was asked to render.
class GeometryRepo extends DraftRepository {
  GeometryRepo(this.images);

  final Map<String, ui.Image> images;
  final List<DraftDoc> rendered = [];

  @override
  Future<ui.Image> renderDto(
    DraftDoc doc, {
    required int cellPx,
    bool gridlines = false,
    int floatThreshold = 0,
    bool threadTexture = false,
  }) {
    rendered.add(doc);
    final img = images[_thicknessKey(doc)];
    if (img == null) return Future<ui.Image>.error(StateError('no bitmap for ${_thicknessKey(doc)}'));
    // A fresh handle each call: the preview provider may dispose a superseded frame.
    return Future<ui.Image>.value(img.clone());
  }
}
