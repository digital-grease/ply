// M2 Phase-5.2 device proof: a from-scratch draft (the "New draft" path) survives the real-FFI
// save->reopen round-trip and renders the cloth it was built into.
//
//   flutter test integration_test/m5_newdraft_test.dart -d emulator-5554

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:ply/src/data/draft_repository.dart';
import 'package:ply/src/models/draft_doc.dart';
import 'package:ply/src/models/draft_meta.dart';
import 'package:ply/src/rust/frb_generated.dart';

/// A plain-weave draft, as a weaver would build it in a New-draft session: threading + tie-up +
/// treadling on a blank-started document.
DraftDoc constructed() => DraftDoc(
      name: 'My scarf',
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

  testWidgets('a from-scratch draft survives Save (write_wif) -> reopen (parse) -> render',
      (tester) async {
    final repo = DraftRepository();
    final doc = constructed();
    const px = 12;

    final before = await rawBytes(await repo.renderDto(doc, cellPx: px));

    // The from-scratch Save path: no source WIF, so it re-serializes via write_wif.
    final wif = await repo.resolveSaveWif(doc, null);
    // Reopen from the library (parse the persisted WIF back to a draft).
    final reopened = await repo.parseDoc(wif);

    final after = await rawBytes(await repo.renderDto(reopened, cellPx: px));
    expect(after, equals(before), reason: 'the constructed cloth survives the WIF round-trip');
    expect((await repo.validateDto(reopened)).where((i) => i.isError), isEmpty,
        reason: 'a reopened from-scratch draft validates clean');
    expect(reopened.name, 'My scarf',
        reason: 'the name (typed at the save prompt) round-trips via the WIF [TEXT] Title');
  });

  testWidgets('saving a still-blank 0x0 draft via the full saveDto completes (no thumbnail hang)',
      (tester) async {
    // The editor blocks this at GATE 0, but the repo decode guard is the backstop: a 0-area
    // drawdown must not hang the thumbnail decode. A timeout turns a regression (the old infinite
    // Completer) into a failure instead of a hung suite.
    final repo = DraftRepository();
    final blank = DraftDoc.blank(); // 0 ends / 0 picks
    final meta = DraftMeta(
      name: 'Empty',
      savedAt: DateTime.utc(2020),
      lastOpened: DateTime.utc(2020),
    );
    final id = await repo
        .saveDto(blank, meta: meta)
        .timeout(const Duration(seconds: 10), onTimeout: () {
      fail('saveDto hung on the 0x0 thumbnail decode');
    });
    expect(id, isNotEmpty);
    addTearDown(() => repo.delete(id)); // don't leave the empty entry behind
  });

  testWidgets('DraftDoc.blank grown one end/pick at a time round-trips (the new-draft start)',
      (tester) async {
    final repo = DraftRepository();
    // Start blank, grow to a 1x1 plain cell (the smallest renderable new draft), threaded + tied.
    final grown = DraftDoc.blank(shafts: 1, treadles: 1).copyWith(
      threading: const [
        [1],
      ],
      drive: DraftTreadled(tieup: const [
        [1],
      ], treadling: const [
        [1],
      ]),
      warpColors: const [0],
      weftColors: const [1],
    );
    final wif = await repo.resolveSaveWif(grown, null);
    final reopened = await repo.parseDoc(wif);
    expect(reopened.ends, 1);
    expect(reopened.picks, 1);
    expect((await repo.validateDto(reopened)).where((i) => i.isError), isEmpty);
  });
}
