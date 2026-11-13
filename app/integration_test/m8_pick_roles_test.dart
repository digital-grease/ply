// M8-06 device proof: pick roles against the REAL engine and filesystem. A generated overshot carries
// its pattern/tabby roles (also on a sinking-shed loom), they survive save and reopen in Ply's WIF
// private section, a role edit saves and reopens, the engine resize and liftplan convert keep them
// aligned, and a plain third-party WIF reopens with every role unknown.
//
//   flutter test integration_test/m8_pick_roles_test.dart -d emulator-5554

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:ply/src/data/draft_repository.dart';
import 'package:ply/src/models/draft_doc.dart';
import 'package:ply/src/models/draft_meta.dart';
import 'package:ply/src/models/editor_state.dart';
import 'package:ply/src/models/use_tabby.dart';
import 'package:ply/src/rust/dto.dart' show StructureFamily, ThreadingKind;
import 'package:ply/src/rust/frb_generated.dart';

/// A third-party 2/2 twill with no Ply private data.
const String kPlainWif = '''[WIF]
Version=1.1
Source Program=Elsewhere
[WEAVING]
Shafts=4
Treadles=4
Rising Shed=true
[WARP]
Threads=4
[WEFT]
Threads=4
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
''';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  testWidgets('pick roles survive generate, save, reopen, edit, resize, and convert',
      (tester) async {
    final repo = DraftRepository();
    final meta = DraftMeta(name: 'roles', savedAt: DateTime.now(), lastOpened: DateTime.now());
    Future<DraftDoc> overshot(Shed shed) => repo.generateStructureDoc(
          DraftDoc.blank().copyWith(shed: shed),
          family: StructureFamily.overshot,
          threading: ThreadingKind.straight,
          shafts: 4,
          over: 2,
          under: 2,
          counter: 2,
          ends: 16,
          picks: 8,
        );

    final doc = await overshot(Shed.rising);
    expect(doc.pickRoles, [
      for (var p = 0; p < 8; p++) p.isEven ? PickRole.pattern : PickRole.tabby,
    ]);
    expect(readUseTabby(doc), isA<UseTabbyBook>());
    final sinking = await overshot(Shed.sinking);
    expect(sinking.pickRoles, doc.pickRoles, reason: 'kept through the sinking-shed conversion');
    expect(readUseTabby(sinking), isA<UseTabbyBook>(), reason: 'tabby sheds read raised shafts');

    // Save (re-serialized: a generated draft has no source WIF) and reopen from disk.
    final id = await repo.saveDto(doc, meta: meta);
    addTearDown(() => repo.delete(id));
    final wif = await repo.readWif(id);
    expect(wif, contains('[PRIVATE PLY PICK ROLES]'));
    expect(wif, contains('PRIVATE PLY PICK ROLES=true'));
    final reopened = await repo.parseDoc(wif);
    expect(reopened.pickRoles, doc.pickRoles);

    // A role edit saves and reopens too.
    final edited = EditorState(draft: reopened).withPickRoles(0, 1, PickRole.topLayer).draft;
    final id2 = await repo.saveDto(edited, meta: meta);
    addTearDown(() => repo.delete(id2));
    expect((await repo.parseDoc(await repo.readWif(id2))).pickRoles, edited.pickRoles);

    // Engine edits keep the roles aligned with the picks.
    final grown = await repo.resizeDoc(doc, ends: 16, picks: 10, shafts: 4, treadles: 4);
    expect(grown.pickRoles, [...doc.pickRoles, PickRole.unknown, PickRole.unknown]);
    final lift = await repo.toLiftplanDoc(doc);
    expect(lift.pickRoles, doc.pickRoles);
    expect(readUseTabby(lift), isA<UseTabbyBook>());

    // A third-party WIF without Ply's private data opens with every role unknown.
    expect((await repo.parseDoc(kPlainWif)).pickRoles, isEmpty);
  });
}
