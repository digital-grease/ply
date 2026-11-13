// M8-06 device proof: pick roles against the REAL engine and filesystem. A generated overshot carries
// its pattern/tabby roles (also on a sinking-shed loom), they survive save and reopen in Ply's WIF
// private section, a role edit saves and reopens, the engine resize and liftplan convert keep them
// aligned, and a plain third-party WIF reopens with every role unknown. Shot groups, shuttles with
// their starting sides, and strands per pick (ADR 0009) save and reopen in the same section, stay
// aligned through the engine resize, and the engine validation reports the double-shot advice.
//
//   flutter test integration_test/m8_pick_roles_test.dart -d emulator-5554

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:ply/src/data/draft_repository.dart';
import 'package:ply/src/models/draft_doc.dart';
import 'package:ply/src/models/draft_issue.dart';
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
    expect(wif, contains('[PRIVATE PLY PICKS]'));
    expect(wif, contains('PRIVATE PLY PICKS=true'));
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

  testWidgets('shot groups, shuttles, and strands survive save, reopen, and resize',
      (tester) async {
    final repo = DraftRepository();
    final meta = DraftMeta(name: 'shots', savedAt: DateTime.now(), lastOpened: DateTime.now());
    final plain = await repo.parseDoc(kPlainWif);
    // Treadle 1 twice (a double shot on shuttle 1, from the right) then treadles 2 and 3 on
    // shuttle 2 (from the left), the double shot carrying two strands.
    // kPlainWif has no color table, so give the draft a palette: otherwise every end and pick is a
    // "color outside palette" error unrelated to the weft work this test checks.
    final doc = plain.copyWith(
      palette: const [DraftColor(r: 0, g: 0, b: 0), DraftColor(r: 255, g: 255, b: 255)],
      drive: DraftTreadled(tieup: const [
        [1, 2],
        [2, 3],
        [3, 4],
        [1, 4],
      ], treadling: const [
        [1],
        [1],
        [2],
        [3],
      ]),
      pickShuttles: const [1, 1, 2, 2],
      pickStrands: const [2, 2, 1, 1],
      shotGroups: const [ShotGroup(0, 2)],
      shuttleStarts: const {1: ShuttleSide.right, 2: ShuttleSide.left},
    );
    final id = await repo.saveDto(doc, meta: meta);
    addTearDown(() => repo.delete(id));
    final wif = await repo.readWif(id);
    expect(wif, contains('[PRIVATE PLY PICKS]'));
    expect(wif, contains('Shot 1=2'));
    expect(wif, contains('Shuttle 1 Start=right'));
    final reopened = await repo.parseDoc(wif);
    expect(reopened.shotGroups, doc.shotGroups);
    expect(reopened.pickShuttles, doc.pickShuttles);
    expect(reopened.pickStrands, doc.pickStrands);
    expect(reopened.shuttleStarts, doc.shuttleStarts);

    // The engine resize cuts through the double shot: it dissolves, and the per-pick lists follow.
    final cut = await repo.resizeDoc(reopened, ends: 4, picks: 1, shafts: 4, treadles: 4);
    expect(cut.shotGroups, isEmpty);
    expect(cut.pickShuttles, const [1]);
    expect(cut.pickStrands, const [2]);

    // Validation: the grouped return pass is a note; ungrouped, the same picks are a warning.
    final issues = await repo.validateDto(reopened);
    expect(issues.where((i) => i.severity == IssueSeverity.info), hasLength(1));
    expect(issues.where((i) => i.isError), isEmpty);
    final ungrouped = await repo.validateDto(reopened.copyWith(shotGroups: const []));
    expect(
        ungrouped.where((i) =>
            i.severity == IssueSeverity.warning && i.message.contains('will not catch the selvedge')),
        hasLength(1));

    // The weft estimate counts the strands (1.5 strands per pick on average).
    final (_, single) = await repo.estimateWeftPlan(
        picksPerUnit: 10, width: 10, wovenLength: 10, items: 1, takeupPercent: 0);
    final (_, counted) = await repo.estimateWeftPlan(
        picksPerUnit: 10, width: 10, wovenLength: 10, items: 1, takeupPercent: 0, draft: doc);
    expect(counted, closeTo(single * 1.5, 1e-3));
  });
}
