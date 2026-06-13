// M2 Phase-3.3 device proof: the Treadled->Liftplan DRIVE SWITCH on a real device.
//
// The load-bearing claim is CLOTH PRESERVATION: converting a treadled draft to a liftplan (the
// engine bakes the per-pick raised shafts in, honoring the source shed) renders the SAME cloth —
// byte-identical drawdown — most importantly for a SINKING-shed source, where the tie-up names the
// shafts that SINK so `raised_shafts` must complement them. Two repo-direct cases (sinking + a
// rising control) pin the engine path; a third drives the real EditorScreen convert button end to
// end (tap -> confirm -> the cloth is unchanged, the drive flips, undo brings the tie-up back).
//
//   flutter test integration_test/m3_drive_switch_test.dart -d emulator-5554

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:ply/src/data/draft_repository.dart';
import 'package:ply/src/models/draft_doc.dart';
import 'package:ply/src/screens/editor_screen.dart';
import 'package:ply/src/state/draft_editor_notifier.dart';
import 'package:ply/src/state/editor_providers.dart';
import 'package:ply/src/rust/frb_generated.dart';

/// The Dart twin of the engine's `to_liftplan_draft_preserves_raised_shafts` fixture
/// (ply-weave draft.rs): a SINKING-shed treadled draft whose tie-up [[1,2],[3]] names sinking
/// shafts, so the raised set per pick is the COMPLEMENT — the case that genuinely exercises
/// inversion-baking, making the byte-identity assertion a real guard, not a vacuous pass.
DraftDoc sinkingTwill() => DraftDoc(
      name: 't',
      shafts: 4,
      treadles: 2,
      shed: Shed.sinking,
      unit: MeasureUnit.inches,
      threading: const [
        [1],
        [2],
      ],
      drive: DraftTreadled(
        tieup: const [
          [1, 2],
          [3],
        ],
        treadling: const [
          [1],
          [2],
          [],
        ],
      ),
      palette: const [
        DraftColor(r: 255, g: 255, b: 255),
        DraftColor(r: 0, g: 0, b: 0),
      ],
      warpColors: const [0, 1],
      weftColors: const [1, 0, 1],
      notes: '',
    );

/// A RISING-shed treadled control (plain weave): the raised set equals the tied set, so this
/// distinguishes a regression that breaks only the sinking complement from one that breaks every
/// conversion.
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

Future<Uint8List> rawBytes(ui.Image image) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  return data!.buffer.asUint8List();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  testWidgets('Treadled->Liftplan preserves the rendered cloth (SINKING shed)', (tester) async {
    final repo = DraftRepository();
    final src = sinkingTwill();

    final before = await rawBytes(await repo.renderDto(src, cellPx: 16));
    final lp = await repo.toLiftplanDoc(src);

    // The canonical liftplan shape: tie-up-free, treadle-free, Rising — but the SAME cloth.
    expect(lp.drive, isA<DraftLiftplan>());
    expect(lp.treadles, 0);
    expect(lp.shed, Shed.rising);

    final after = await rawBytes(await repo.renderDto(lp, cellPx: 16));
    expect(after, equals(before),
        reason: 'a sinking-shed Treadled->Liftplan must render byte-identical cloth');

    // The conversion never leaves a dangling-reference Error to hand-fix.
    expect((await repo.validateDto(lp)).where((i) => i.isError), isEmpty);
  });

  testWidgets('Treadled->Liftplan preserves the rendered cloth (RISING control)', (tester) async {
    final repo = DraftRepository();
    final src = plainWeave();

    final before = await rawBytes(await repo.renderDto(src, cellPx: 16));
    final lp = await repo.toLiftplanDoc(src);
    expect(lp.drive, isA<DraftLiftplan>());

    final after = await rawBytes(await repo.renderDto(lp, cellPx: 16));
    expect(after, equals(before), reason: 'a rising Treadled->Liftplan is also byte-identical');
  });

  testWidgets('the EditorScreen convert button flips the drive without changing the cloth, and undo reverts',
      (tester) async {
    final repo = DraftRepository();
    // Round-trip the fixture through WIF so we drive the REAL editor entry point (it loads wifText).
    // Both frames below come from the loaded draft + its conversion, so write_wif's header lossiness
    // is irrelevant to the equality.
    final wif = await repo.resolveSaveWif(sinkingTwill(), null);

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
          home: EditorScreen(wifText: wif, title: 'Sinking twill'),
        ),
      ),
    );

    // Let the load + first render settle (bounded pumps; the loading state is a spinner, so we
    // can't pumpAndSettle while it's up).
    Future<Uint8List> freshFrame() async {
      await tester.pump();
      await container.read(previewProvider.future);
      return rawBytes(container.read(previewProvider).requireValue);
    }

    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 30));
    }
    final before = await freshFrame();
    expect(container.read(draftEditorProvider).draft.drive, isA<DraftTreadled>(),
        reason: 'the loaded draft is treadled');

    // Convert moved into the AppBar overflow (⋮) in M4; open it then pick Convert, confirm the dialog.
    await tester.tap(find.byTooltip('More actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Convert to liftplan'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 30));
    }
    expect(find.text('Convert to liftplan?'), findsOneWidget);
    await tester.tap(find.text('Convert'));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 30));
    }

    final after = await freshFrame();
    expect(container.read(draftEditorProvider).draft.drive, isA<DraftLiftplan>(),
        reason: 'the convert button flipped the drive to liftplan');
    expect(after, equals(before), reason: 'the on-screen cloth is unchanged by the conversion');

    // Undo brings the tie-up back and restores the original cloth.
    container.read(draftEditorProvider.notifier).undo();
    final undone = await freshFrame();
    expect(container.read(draftEditorProvider).draft.drive, isA<DraftTreadled>(),
        reason: 'undo restores the treadled drive');
    expect(undone, equals(before), reason: 'undo restores the original cloth');
  });
}
