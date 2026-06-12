// M2 Phase-2.4 device proof: the first interactive editing loop on a real device.
//
// Drives the actual widgets (TieupGrid + the live preview provider, real FFI render) and proves
// the load-bearing claim: tapping a tie-up cell toggles it AND the live drawdown re-renders to a
// DIFFERENT cloth. Also exercises the latest-wins preview path by editing twice in a row.
//
//   flutter test integration_test/m2_editor_test.dart -d emulator-5554

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:ply/src/data/draft_repository.dart';
import 'package:ply/src/models/draft_doc.dart';
import 'package:ply/src/state/draft_editor_notifier.dart';
import 'package:ply/src/state/editor_providers.dart';
import 'package:ply/src/widgets/drawdown_view.dart';
import 'package:ply/src/widgets/tieup_grid.dart';
import 'package:ply/src/rust/frb_generated.dart';

/// A plain-weave-ish treadled draft whose tie-up actually shapes the cloth, so toggling a tie
/// changes the rendered drawdown.
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

  testWidgets('tapping a tie-up cell re-renders the live drawdown to a different cloth',
      (tester) async {
    final repo = DraftRepository();
    final container = ProviderContainer(
      overrides: [repositoryProvider.overrideWithValue(repo)],
    );
    addTearDown(container.dispose);
    container.read(draftEditorProvider.notifier).load(plainWeave());

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                Expanded(
                  child: Consumer(
                    builder: (context, ref, _) {
                      final preview = ref.watch(previewProvider);
                      return preview.when(
                        skipLoadingOnReload: true,
                        data: (img) => DrawdownView(img),
                        loading: () => const SizedBox.shrink(),
                        error: (e, _) => Text('$e'),
                      );
                    },
                  ),
                ),
                const SizedBox(width: 120, height: 120, child: TieupGrid()),
              ],
            ),
          ),
        ),
      ),
    );

    // Read the FRESH frame for whatever draft is current. The preview keeps the previous frame
    // on screen during a re-render (skipLoadingOnReload), so we must await the new render future
    // rather than trust pumpAndSettle, or we would read the stale (still-shown) frame.
    Future<Uint8List> freshFrame() async {
      await tester.pump(); // let the draft change schedule the rebuild
      await container.read(previewProvider.future); // await the new render specifically
      return rawBytes(container.read(previewProvider).requireValue);
    }

    final before = await freshFrame();

    // Tap the top-left tie-up cell (treadle 1, shaft 1). 2x2 grid in a 120x120 box => 60px
    // cells, so (30,30) lands in cell (1,1). This unties shaft 1 from treadle 1.
    final gridTopLeft = tester.getTopLeft(find.byType(TieupGrid));
    await tester.tapAt(gridTopLeft + const Offset(30, 30));
    final after = await freshFrame();

    // The edit landed in the model AND the live render changed.
    final drive = container.read(draftEditorProvider).draft.drive as DraftTreadled;
    expect(drive.tieup[0], isEmpty, reason: 'treadle 1 untied from shaft 1');
    expect(after, isNot(equals(before)),
        reason: 'the drawdown must re-render to a different cloth after the tie-up edit');

    // A second edit also re-renders.
    await tester.tapAt(gridTopLeft + const Offset(90, 90)); // cell (2, 2): untie shaft 2 / treadle 2
    final after2 = await freshFrame();
    expect(after2, isNot(equals(after)), reason: 'the second edit also updates the drawdown');

    // Undo restores the first edited cloth: same draft -> deterministic engine -> same bytes.
    container.read(draftEditorProvider.notifier).undo();
    final undone = await freshFrame();
    expect(undone, equals(after), reason: 'undo brings back the previous drawdown');
  });
}
