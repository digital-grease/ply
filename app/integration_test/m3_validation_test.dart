// M2 Phase-3.4 device proof: inline validation + Save error-gating against the REAL engine.
//
// Proves the plan's claim end to end with real FFI: a dangling shaft is surfaced as an Error inline
// (red) and warns at Save; a warp/weft count mismatch is a Warning (amber) that does NOT gate; a
// clean draft shows nothing. The severities come from the actual ply-weave validate(), not a fake.
//
//   flutter test integration_test/m3_validation_test.dart -d emulator-5554

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:ply/src/data/draft_repository.dart';
import 'package:ply/src/models/draft_doc.dart';
import 'package:ply/src/screens/editor_screen.dart';
import 'package:ply/src/state/draft_editor_notifier.dart';
import 'package:ply/src/state/editor_providers.dart';
import 'package:ply/src/widgets/validation_panel.dart';
import 'package:ply/src/rust/frb_generated.dart';

/// A clean rising plain weave (2 shafts, 4 ends/picks).
DraftDoc plainWeave() => DraftDoc(
      name: 'plain',
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
      palette: const [
        DraftColor(r: 255, g: 255, b: 255),
        DraftColor(r: 0, g: 0, b: 0),
      ],
      warpColors: const [0, 0, 0, 0],
      weftColors: const [1, 1, 1, 1],
      notes: '',
    );

/// A tie-up that ties shaft 5 on a 2-shaft draft: the engine renders it white silently, so validate
/// surfaces it as an ERROR ("treadle 1 ties shaft 5 outside 1..=2").
DraftDoc danglingTieup() => plainWeave().copyWith(
      drive: DraftTreadled(
        tieup: const [
          [5],
          [2],
        ],
        treadling: const [
          [1],
          [2],
          [1],
          [2],
        ],
      ),
    );

/// 5 warp colors against 4 warp ends: a count mismatch, which validate flags as a WARNING.
DraftDoc countMismatch() => plainWeave().copyWith(warpColors: const [0, 0, 0, 0, 0]);

/// Pump just the ValidationPanel fed by the real validationProvider (real FFI validate), with [doc]
/// loaded into the editor. No Save side effects.
Future<ProviderContainer> pumpPanel(WidgetTester tester, DraftDoc doc) async {
  final container = ProviderContainer(
    overrides: [repositoryProvider.overrideWithValue(DraftRepository())],
  );
  addTearDown(container.dispose);
  container.read(draftEditorProvider.notifier).load(doc);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: ValidationPanel())),
    ),
  );
  // Pump (don't await validationProvider.future, which a superseded build leaves never-resolving)
  // until the real FFI validate lands in the panel.
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 30));
  }
  return container;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  testWidgets('CLEAN draft: validate is empty and the panel shows nothing', (tester) async {
    final repo = DraftRepository();
    expect(await repo.validateDto(plainWeave()), isEmpty, reason: 'a clean draft has no issues');

    await pumpPanel(tester, plainWeave());
    expect(find.byIcon(Icons.error), findsNothing);
    expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);
  });

  testWidgets('COUNT MISMATCH: a Warning is shown inline (amber), no Error', (tester) async {
    final repo = DraftRepository();
    final issues = await repo.validateDto(countMismatch());
    expect(issues.any((i) => !i.isError && i.message.contains('warp color count')), isTrue,
        reason: 'a warp/weft count mismatch is a Warning');
    expect(issues.any((i) => i.isError), isFalse, reason: 'no Error for a count mismatch');

    await pumpPanel(tester, countMismatch());
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    expect(find.byIcon(Icons.error), findsNothing);
  });

  testWidgets('DANGLING SHAFT: Error inline (red) AND Save warns (real FFI gate)', (tester) async {
    final repo = DraftRepository();
    final issues = await repo.validateDto(danglingTieup());
    expect(issues.any((i) => i.isError && i.message.contains('treadle 1 ties shaft 5')), isTrue,
        reason: 'a dangling tie-up shaft is an Error');

    // Pump the full EditorScreen as a PUSHED route (so a pop is valid), load the dangling draft
    // directly, and drive Save through the real engine gate.
    final wif = await repo.resolveSaveWif(plainWeave(), null); // a valid WIF to open the editor
    final container = ProviderContainer(
      overrides: [
        repositoryProvider.overrideWithValue(repo),
        zoomCellProvider.overrideWith((ref) => 16),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Builder(
            builder: (ctx) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => Navigator.push(
                    ctx,
                    MaterialPageRoute(builder: (_) => EditorScreen(wifText: wif, title: 'T')),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 30));
    }
    // Swap in the dangling draft (bypassing WIF round-trip, which could normalize the error away).
    container.read(draftEditorProvider.notifier).load(danglingTieup());
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 30));
    }
    expect(find.byIcon(Icons.error), findsWidgets, reason: 'the Error is shown inline');

    // Tap Save: the gate re-validates via the real engine and warns. We STOP at the dialog (never
    // confirm), so nothing is written to the device.
    await tester.tap(find.byIcon(Icons.save_outlined));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 30));
    }
    expect(find.text('Save with problems?'), findsOneWidget,
        reason: 'saving a draft with an Error warns first');
  });
}
