import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/draft_repository.dart';
import 'package:ply/src/models/draft_doc.dart';
import 'package:ply/src/state/draft_editor_notifier.dart';
import 'package:ply/src/state/editor_providers.dart';
import 'package:ply/src/widgets/dimensions_bar.dart';

// The DimensionsBar's steppers compute the new dimensions and call repo.resizeDoc (the engine does
// the actual prune/pad, cargo-tested). Here we verify the stepper arithmetic + that the result is
// committed, with a fake repo capturing the requested dims (no FFI).

class FakeResizeRepo extends DraftRepository {
  int? ends, picks, shafts, treadles;

  /// How many times resizeDoc has been entered. Pins the serialize guard: a second stepper tap
  /// during an in-flight resize must NOT call the engine again.
  int callCount = 0;

  /// When set, resizeDoc parks on this gate before returning, so a test can hold one resize
  /// "in flight" and prove a second tap is dropped.
  Completer<void>? gate;

  @override
  Future<DraftDoc> resizeDoc(
    DraftDoc doc, {
    required int ends,
    required int picks,
    required int shafts,
    required int treadles,
  }) async {
    callCount++;
    this.ends = ends;
    this.picks = picks;
    this.shafts = shafts;
    this.treadles = treadles;
    if (gate != null) await gate!.future;
    // Return a DISTINCT doc so commitEdit applies (and the undo stack grows).
    return doc.copyWith(name: 'r-$ends-$picks-$shafts-$treadles');
  }
}

/// ends 4, picks 4, shafts 4, treadles 4.
DraftDoc fixture() => DraftDoc(
      name: 'f',
      shafts: 4,
      treadles: 4,
      shed: Shed.rising,
      unit: MeasureUnit.inches,
      threading: const [
        [1],
        [2],
        [3],
        [4],
      ],
      drive: DraftTreadled(
        tieup: const [
          [1],
          [2],
          [3],
          [4],
        ],
        treadling: const [
          [1],
          [2],
          [3],
          [4],
        ],
      ),
      palette: const [DraftColor(r: 0, g: 0, b: 0)],
      warpColors: const [0, 0, 0, 0],
      weftColors: const [0, 0, 0, 0],
      notes: '',
    );

Future<(ProviderContainer, FakeResizeRepo)> pumpBar(WidgetTester tester) async {
  // The bar's action chips + 4 steppers scroll horizontally in production; widen the test surface
  // so every stepper is on-screen and tappable at a fixed offset (the row gained a Structure chip).
  tester.view.physicalSize = const Size(1600, 600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final fake = FakeResizeRepo();
  final c = ProviderContainer(overrides: [repositoryProvider.overrideWithValue(fake)]);
  addTearDown(c.dispose);
  c.read(draftEditorProvider.notifier).load(fixture());
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: const MaterialApp(home: Scaffold(body: DimensionsBar())),
    ),
  );
  await tester.pump();
  return (c, fake);
}

void main() {
  testWidgets('the Colors chip reflects the palette length and updates live', (tester) async {
    final (c, _) = await pumpBar(tester); // fixture has a 1-color palette
    expect(find.text('Colors 1'), findsOneWidget);
    c.read(draftEditorProvider.notifier).addPaletteColor(const DraftColor(r: 1, g: 2, b: 3));
    await tester.pump();
    expect(find.text('Colors 2'), findsOneWidget, reason: 'the chip count tracks the palette');
  });

  testWidgets('the Calculator chip opens the planning sheet', (tester) async {
    await pumpBar(tester);
    await tester.tap(find.widgetWithText(ActionChip, 'Calculator'));
    await tester.pumpAndSettle();
    expect(find.text('Planning calculator'), findsOneWidget);
  });

  testWidgets('selecting a treadling row reveals its count stepper, which grows the run', (tester) async {
    final (c, _) = await pumpBar(tester); // treadling [1],[2],[3],[4] -> 4 single-pick rows
    expect(find.byTooltip('More Row ×'), findsNothing, reason: 'no per-row controls until selected');
    // Select entry 0 (treadle 1, x1).
    c.read(selectedTreadlingEntryProvider.notifier).state = 0;
    await tester.pump();
    expect(find.text('Row × 1'), findsOneWidget);
    // Grow it to x2: inserts a pick via the pure reducer (no engine resize).
    await tester.tap(find.byTooltip('More Row ×'));
    await tester.pump();
    final t = c.read(draftEditorProvider).draft.drive as DraftTreadled;
    expect(t.treadling, [
      [1],
      [1],
      [2],
      [3],
      [4],
    ]);
    expect(c.read(draftEditorProvider).draft.picks, 5);
    expect(find.text('Row × 2'), findsOneWidget);
  });

  testWidgets('Add row appends a blank treadling row and selects it', (tester) async {
    final (c, _) = await pumpBar(tester);
    c.read(selectedTreadlingEntryProvider.notifier).state = 0;
    await tester.pump();
    await tester.tap(find.widgetWithText(ActionChip, 'Row'));
    await tester.pump();
    final t = c.read(draftEditorProvider).draft.drive as DraftTreadled;
    expect(t.treadling.last, isEmpty, reason: 'a blank pick is appended');
    expect(c.read(selectedTreadlingEntryProvider), 4, reason: 'the new last row is selected');
  });

  testWidgets('the Colors chip dot shows the active brush color', (tester) async {
    Color dotColor(WidgetTester t) {
      final dot = t
          .widgetList<Container>(find.byType(Container))
          .firstWhere((c) => (c.decoration as BoxDecoration?)?.shape == BoxShape.circle);
      return (dot.decoration as BoxDecoration).color!;
    }

    final (c, _) = await pumpBar(tester); // fixture palette [black]
    expect(dotColor(tester), const Color(0xFF000000), reason: 'brush 0 = black');
    c.read(draftEditorProvider.notifier).addPaletteColor(const DraftColor(r: 255, g: 0, b: 0));
    c.read(activePaletteColorProvider.notifier).state = 1;
    await tester.pump();
    expect(dotColor(tester), const Color(0xFFFF0000), reason: 'brush 1 = red');

    // A dangling brush index clamps to the last swatch (no crash).
    c.read(activePaletteColorProvider.notifier).state = 5;
    await tester.pump();
    expect(dotColor(tester), const Color(0xFFFF0000), reason: 'clamped to the last swatch (red)');
  });

  testWidgets('More Ends resizes with ends+1, others unchanged, and commits', (tester) async {
    final (c, fake) = await pumpBar(tester);
    await tester.tap(find.byTooltip('More Ends'));
    await tester.pump();
    expect(fake.ends, 5);
    expect(fake.picks, 4);
    expect(fake.shafts, 4);
    expect(fake.treadles, 4);
    expect(c.read(draftEditorProvider).undo.length, 1, reason: 'the resize is one undo entry');
  });

  testWidgets('Fewer Shafts resizes with shafts-1', (tester) async {
    final (_, fake) = await pumpBar(tester);
    await tester.tap(find.byTooltip('Fewer Shafts'));
    await tester.pump();
    expect(fake.shafts, 3);
    expect(fake.ends, 4);
  });

  testWidgets('Shafts cannot be stepped below 1 (the minus is disabled at 1)', (tester) async {
    final fake = FakeResizeRepo();
    final c = ProviderContainer(overrides: [repositoryProvider.overrideWithValue(fake)]);
    addTearDown(c.dispose);
    // A 1-shaft draft: the "Fewer Shafts" button must be disabled.
    c.read(draftEditorProvider.notifier).load(fixture().copyWith(shafts: 1));
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: const MaterialApp(home: Scaffold(body: DimensionsBar())),
    ));
    await tester.pump();
    final minus = tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.remove).at(2));
    expect(minus.onPressed, isNull, reason: 'Shafts (min 1) cannot shrink below 1');
  });

  testWidgets('a second stepper tap during an in-flight resize is dropped (serialized)',
      (tester) async {
    // Two fast taps that each read the SAME pre-resize draft would race across the async FFI hop
    // and lose one axis's update. The bar serializes: it disables the steppers while a resize is
    // in flight, so the second tap never reaches the engine.
    final gate = Completer<void>();
    final fake = FakeResizeRepo()..gate = gate;
    final c = ProviderContainer(overrides: [repositoryProvider.overrideWithValue(fake)]);
    addTearDown(c.dispose);
    c.read(draftEditorProvider.notifier).load(fixture());
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: const MaterialApp(home: Scaffold(body: DimensionsBar())),
    ));
    await tester.pump();

    await tester.tap(find.byTooltip('More Ends')); // starts a resize (ends:5), parks on the gate
    await tester.pump();
    expect(fake.callCount, 1);
    expect(fake.ends, 5);

    // A second tap on a DIFFERENT axis while the first is still in flight must be dropped.
    await tester.tap(find.byTooltip('More Picks'));
    await tester.pump();
    expect(fake.callCount, 1, reason: 'the in-flight resize serializes the second tap away');
    expect(fake.picks, 4, reason: 'the dropped pick tap never requested picks:5');

    gate.complete(); // let the first resize land
    await tester.pumpAndSettle();
    expect(fake.callCount, 1, reason: 'nothing was queued, so no second resize fires afterwards');
    expect(c.read(draftEditorProvider).undo.length, 1, reason: 'exactly one resize committed');
  });

  testWidgets('an edit landing during the resize FFI hop is preserved (stale resize dropped)',
      (tester) async {
    // The resize twin of the convert latest-wins guard: _resizing only disables the steppers, so an
    // AppBar undo/redo or a paint can still land during the FFI hop. A resize derived from the
    // pre-edit draft must be dropped, not committed over that edit.
    final gate = Completer<void>();
    final fake = FakeResizeRepo()..gate = gate;
    final c = ProviderContainer(overrides: [repositoryProvider.overrideWithValue(fake)]);
    addTearDown(c.dispose);
    c.read(draftEditorProvider.notifier).load(fixture());
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: const MaterialApp(home: Scaffold(body: DimensionsBar())),
    ));
    await tester.pump();

    await tester.tap(find.byTooltip('More Ends')); // resize parks on the gate
    await tester.pump();
    expect(fake.callCount, 1);

    // A concurrent edit lands while the resize is in flight.
    c.read(draftEditorProvider.notifier).toggleTieupCell(1, 1);
    await tester.pump();
    final afterEdit = c.read(draftEditorProvider).draft;

    gate.complete(); // the resize resolves with a result derived from the now-stale pre-edit draft
    await tester.pumpAndSettle();
    expect(c.read(draftEditorProvider).draft, equals(afterEdit),
        reason: 'the stale resize was dropped; the concurrent edit survives');
  });

  testWidgets('the Treadles stepper is hidden on a liftplan draft, shown on a treadled one',
      (tester) async {
    final (c, _) = await pumpBar(tester); // treadled fixture (ends/picks/shafts/treadles all 4)
    expect(find.text('Treadles 4'), findsOneWidget, reason: 'a treadled draft has a treadle axis');
    expect(find.text('Ends 4'), findsOneWidget);

    // A liftplan has no treadle axis, so the stepper disappears; the other three stay.
    c.read(draftEditorProvider.notifier).load(
        fixture().copyWith(drive: DraftLiftplan(liftplan: const [[1], [2], [3], [4]]), treadles: 0));
    await tester.pump();
    expect(find.textContaining('Treadles'), findsNothing, reason: 'liftplan -> no treadle stepper');
    expect(find.text('Ends 4'), findsOneWidget, reason: 'Ends/Picks/Shafts remain');
    expect(find.text('Shafts 4'), findsOneWidget);
  });
}
