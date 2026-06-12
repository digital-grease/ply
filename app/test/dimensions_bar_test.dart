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
}
