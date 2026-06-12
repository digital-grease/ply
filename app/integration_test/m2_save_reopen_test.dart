// M2 Phase-2.5 device proof: the dual-path save round-trip on a real device + filesystem.
//
// Verifies both halves of the dual-path save: a cosmetically-clean draft saves BYTE-IDENTICAL to
// its imported WIF, and a structurally-edited draft re-serializes such that reopening it from
// disk renders the EDITED cloth.
//
//   flutter test integration_test/m2_save_reopen_test.dart -d emulator-5554

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:ply/src/data/draft_repository.dart';
import 'package:ply/src/models/draft_doc.dart';
import 'package:ply/src/models/draft_meta.dart';
import 'package:ply/src/models/editor_state.dart';
import 'package:ply/src/rust/frb_generated.dart';

/// A 4x4, 2/2 twill: toggling a tie that a treadle uses changes the cloth.
const String kTwillWif = '''[WIF]
Version=1.1
[WEAVING]
Shafts=4
Treadles=4
Rising Shed=true
[WARP]
Threads=4
Units=Inches
[WEFT]
Threads=4
[COLOR TABLE]
1=0,0,0
2=255,255,255
[THREADING]
1=1
2=2
3=3
4=4
[TIEUP]
1=1,2
2=2,3
3=3,4
4=1,4
[TREADLING]
1=1
2=2
3=3
4=4
[WARP COLORS]
1=1
2=1
3=1
4=1
[WEFT COLORS]
1=2
2=2
3=2
4=2
''';

Future<Uint8List> rawBytes(ui.Image image) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  return data!.buffer.asUint8List();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  testWidgets('clean save is byte-identical; an edited save reopens as the new cloth',
      (tester) async {
    final repo = DraftRepository();
    final meta = DraftMeta(
      name: 'roundtrip',
      savedAt: DateTime.now(),
      lastOpened: DateTime.now(),
    );

    final doc = await repo.parseDoc(kTwillWif);

    // CLEAN save: pass the original WIF verbatim -> persisted byte-for-byte.
    final cleanId = await repo.saveDto(doc, meta: meta, sourceWif: kTwillWif);
    addTearDown(() => repo.delete(cleanId));
    expect(await repo.readWif(cleanId), equals(kTwillWif),
        reason: 'an unedited save stays byte-identical to the source WIF');

    // EDIT one tie-up cell (untie shaft 1 from treadle 1), then DIRTY save (re-serialize).
    final edited = EditorState(draft: doc).toggleTieupCell(1, 1).draft;
    final dirtyId = await repo.saveDto(edited, meta: meta, sourceWif: null);
    addTearDown(() => repo.delete(dirtyId));

    // REOPEN from disk: the persisted file parses back to the EDITED draft. Constrain the WHOLE
    // round-trippable structure (not just the edited cell), so a regression that drops or
    // corrupts an UNTOUCHED section would fail here. (name/notes are not asserted: per
    // WIF_MAPPING they are not round-tripped through write/parse yet.)
    final reopened = await repo.parseDoc(await repo.readWif(dirtyId));
    final reDrive = reopened.drive as DraftTreadled;
    final edDrive = edited.drive as DraftTreadled;
    expect(reopened.shafts, equals(edited.shafts));
    expect(reopened.treadles, equals(edited.treadles));
    expect(reopened.shed, equals(edited.shed));
    expect(reopened.threading, equals(edited.threading));
    expect(reDrive.tieup, equals(edDrive.tieup));
    expect(reDrive.treadling, equals(edDrive.treadling));
    expect(reopened.warpColors, equals(edited.warpColors));
    expect(reopened.weftColors, equals(edited.weftColors));
    expect(reopened.palette, equals(edited.palette));
    expect(reDrive.tieup[0], isNot(contains(1)), reason: 'the edit itself specifically persisted');

    final originalImg = await repo.renderDto(doc, cellPx: 8);
    final reopenedImg = await repo.renderDto(reopened, cellPx: 8);
    expect(await rawBytes(reopenedImg), isNot(equals(await rawBytes(originalImg))),
        reason: 'the reopened edited draft renders a different cloth than the original');
  });
}
