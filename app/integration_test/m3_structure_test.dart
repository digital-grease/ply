// M3 Phase-3 device proof: the "Generate structure" path against the REAL engine — the generated
// tie-up/threading match the cargo generators, the draft validates clean, and it renders.
//
//   flutter test integration_test/m3_structure_test.dart -d emulator-5554

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:ply/src/data/draft_repository.dart';
import 'package:ply/src/models/draft_doc.dart';
import 'package:ply/src/models/draft_meta.dart';
import 'package:ply/src/rust/dto.dart' show StructureFamily, ThreadingKind;
import 'package:ply/src/rust/frb_generated.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  testWidgets('a 2/2 twill generates the canonical tie-up, validates clean, and renders',
      (tester) async {
    final repo = DraftRepository();
    final doc = await repo.generateStructureDoc(
      DraftDoc.blank(), // white/black palette carries over
      family: StructureFamily.twill,
      threading: ThreadingKind.straight,
      shafts: 4,
      over: 2,
      under: 2,
      counter: 2,
      ends: 8,
      picks: 8,
    );
    expect(doc.shafts, 4);
    expect(doc.treadles, 4);
    expect(doc.ends, 8);
    expect(doc.picks, 8);
    expect((doc.drive as DraftTreadled).tieup,
        equals([[1, 2], [2, 3], [3, 4], [4, 1]]),
        reason: 'the engine 2/2 twill tie-up');
    expect((await repo.validateDto(doc)).where((i) => i.isError), isEmpty,
        reason: 'a generated structure is validate-clean');
    final img = await repo.renderDto(doc, cellPx: 8);
    expect(img.width, greaterThan(0), reason: 'it renders to a real bitmap');
  });

  testWidgets('a point-threaded satin generates its stepped tie-up and validates clean',
      (tester) async {
    final repo = DraftRepository();
    final doc = await repo.generateStructureDoc(
      DraftDoc.blank(),
      family: StructureFamily.satin,
      threading: ThreadingKind.point,
      shafts: 5,
      over: 2,
      under: 2,
      counter: 2,
      ends: 10,
      picks: 10,
    );
    expect(doc.shafts, 5);
    expect((doc.drive as DraftTreadled).tieup,
        equals([[1], [3], [5], [2], [4]]),
        reason: 'the engine 5-shaft satin (counter 2) tie-up');
    expect((await repo.validateDto(doc)).where((i) => i.isError), isEmpty);
  });

  testWidgets('a generated structure survives save -> reopen (tie-up persists, validate clean)',
      (tester) async {
    final repo = DraftRepository();
    final doc = await repo.generateStructureDoc(
      DraftDoc.blank(),
      family: StructureFamily.twill,
      threading: ThreadingKind.straight,
      shafts: 4,
      over: 2,
      under: 2,
      counter: 2,
      ends: 6,
      picks: 6,
    );
    final meta = DraftMeta(name: 'gen', savedAt: DateTime.now(), lastOpened: DateTime.now());
    final id = await repo.saveDto(doc, meta: meta, sourceWif: null);
    addTearDown(() => repo.delete(id));
    final reopened = await DraftRepository().parseDoc(await repo.readWif(id));
    expect((reopened.drive as DraftTreadled).tieup, equals([[1, 2], [2, 3], [3, 4], [4, 1]]),
        reason: 'the generated twill tie-up persists through write_wif');
    expect(reopened.ends, 6);
    expect((await repo.validateDto(reopened)).where((i) => i.isError), isEmpty);
  });
}
