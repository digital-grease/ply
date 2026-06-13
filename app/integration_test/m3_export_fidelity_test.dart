// M3 Phase-2 device proof: WIF export fidelity through the real engine + filesystem.
//
// An imported draft's [NOTES] and a non-default [COLOR PALETTE] Range both survive the app's
// structural-dirty save path (write_wif) and a reopen from disk — closing two of the gaps the M2
// dual-path save warned about. (The notes ride the DTO, so they survive a structural edit; the
// palette is normalized into the model's 0..255 on import.)
//
//   flutter test integration_test/m3_export_fidelity_test.dart -d emulator-5554

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:ply/src/data/draft_repository.dart';
import 'package:ply/src/models/draft_doc.dart';
import 'package:ply/src/models/draft_meta.dart';
import 'package:ply/src/models/editor_state.dart';
import 'package:ply/src/rust/frb_generated.dart';

const String kWifWithNotes = '''[WIF]
Version=1.1
[WEAVING]
Shafts=2
Treadles=2
Rising Shed=true
[WARP]
Threads=2
Units=Inches
[WEFT]
Threads=2
[COLOR PALETTE]
Range=999
Form=RGB
[COLOR TABLE]
1=999,0,0
2=0,0,999
[THREADING]
1=1
2=2
[TIEUP]
1=1
2=2
[TREADLING]
1=1
2=2
[WARP COLORS]
1=1
2=1
[WEFT COLORS]
1=2
2=2
[NOTES]
1=A sample note, with a comma.
2=Second line.
''';

const String kWifWithRetained = '''[WIF]
Version=1.1
[WEAVING]
Shafts=2
Treadles=2
Rising Shed=true
[WARP]
Threads=2
Units=Inches
[WEFT]
Threads=2
[COLOR TABLE]
1=0,0,0
2=255,255,255
[THREADING]
1=1
2=2
[TIEUP]
1=1
2=2
[TREADLING]
1=1
2=2
[WARP COLORS]
1=1
2=1
[WEFT COLORS]
1=2
2=2
[WARP THICKNESS]
1=10
2=10
[ACME VENDOR]
Foo=Bar
''';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  testWidgets('notes + a non-255 palette range survive import -> re-serialize -> reopen',
      (tester) async {
    final repo = DraftRepository();
    final doc = await repo.parseDoc(kWifWithNotes);
    // Range=999 components scaled into the model's 0..=255 (999 -> 255), and multi-line notes read.
    expect(doc.notes, 'A sample note, with a comma.\nSecond line.');
    expect(doc.palette[0], const DraftColor(r: 255, g: 0, b: 0));
    expect(doc.palette[1], const DraftColor(r: 0, g: 0, b: 255));

    // Re-serialize via write_wif (the structural-dirty path, sourceWif null) and reopen from disk.
    final meta = DraftMeta(name: 'n', savedAt: DateTime.now(), lastOpened: DateTime.now());
    final id = await repo.saveDto(doc, meta: meta, sourceWif: null);
    addTearDown(() => repo.delete(id));
    final fresh = DraftRepository();
    final reopened = await fresh.parseDoc(await fresh.readWif(id));
    expect(reopened.notes, doc.notes, reason: 'notes round-trip through write_wif (no longer dropped)');
    expect(reopened.palette, doc.palette, reason: 'the normalized 0..255 palette survives');
  });

  testWidgets('retained sections survive a STRUCTURAL edit; a resize drops stale per-thread',
      (tester) async {
    final repo = DraftRepository();
    final doc = await repo.parseDoc(kWifWithRetained);
    expect(doc.retained.map((s) => s.name), containsAll(['WARP THICKNESS', 'ACME VENDOR']),
        reason: 'unmodeled sections are retained on import');

    // STRUCTURAL edit (toggle a tie-up cell — ends/picks unchanged) then re-serialize via write_wif:
    // the retained sections ride the DTO through the edit and are re-emitted (the cross-FFI win).
    final edited = EditorState(draft: doc).toggleTieupCell(1, 1).draft;
    final meta = DraftMeta(name: 'r', savedAt: DateTime.now(), lastOpened: DateTime.now());
    final id = await repo.saveDto(edited, meta: meta, sourceWif: null);
    addTearDown(() => repo.delete(id));
    final reopened = await DraftRepository().parseDoc(await repo.readWif(id));
    expect(reopened.retained.map((s) => s.name), containsAll(['WARP THICKNESS', 'ACME VENDOR']),
        reason: 'a structural-edit re-serialize keeps the retained sections');

    // RESIZE the warp 2 -> 3 ends: the per-thread [WARP THICKNESS] is now stale and is dropped; the
    // global vendor section is kept.
    final resized = await repo.resizeDoc(doc,
        ends: 3, picks: doc.picks, shafts: doc.shafts, treadles: doc.treadles);
    final names = resized.retained.map((s) => s.name).toList();
    expect(names, isNot(contains('WARP THICKNESS')), reason: 'stale per-thread section dropped');
    expect(names, contains('ACME VENDOR'), reason: 'global vendor section kept');
  });
}
