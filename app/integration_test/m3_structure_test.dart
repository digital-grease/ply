// M3 Phase-3 device proof: the "Generate structure" path against the REAL engine — the generated
// tie-up/threading match the cargo generators, the draft validates clean, and it renders.
//
//   flutter test integration_test/m3_structure_test.dart -d emulator-5554

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:ply/src/data/draft_repository.dart';
import 'package:ply/src/models/draft_doc.dart';
import 'package:ply/src/models/draft_meta.dart';
import 'package:ply/src/models/shadow_weave_params.dart';
import 'package:ply/src/rust/api.dart' show renderPreviewDto;
import 'package:ply/src/rust/dto.dart' show StructureFamily, ThreadingKind;
import 'package:ply/src/rust/frb_generated.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  // Every generator assumes a rising shed. Generated onto a SINKING-shed draft (counterbalance or
  // countermarch), the tie-up must name the sinking shafts so the loom weaves the SAME cloth: the
  // rendered drawdown is pixel-identical to the rising-shed generation.
  testWidgets('generated structures weave the same cloth on a sinking-shed draft', (tester) async {
    final repo = DraftRepository();
    Future<DraftDoc> gen(Shed shed, StructureFamily family) => repo.generateStructureDoc(
          DraftDoc.blank().copyWith(shed: shed),
          family: family,
          threading: ThreadingKind.straight,
          shafts: 4,
          over: 2,
          under: 2,
          counter: 2,
          ends: 16,
          picks: 16,
        );
    for (final family in [StructureFamily.twill, StructureFamily.overshot, StructureFamily.doubleWeave]) {
      final rising = await gen(Shed.rising, family);
      final sinking = await gen(Shed.sinking, family);
      expect(sinking.shed, Shed.sinking, reason: '$family keeps the draft\'s sinking shed');
      final a = await renderPreviewDto(dto: repo.toDto(rising), cellPx: 2);
      final b = await renderPreviewDto(dto: repo.toDto(sinking), cellPx: 2);
      expect(b.rgba, equals(a.rgba), reason: '$family: same cloth on a sinking shed');
    }
    final twill = await gen(Shed.sinking, StructureFamily.twill);
    expect((twill.drive as DraftTreadled).tieup, equals([[3, 4], [1, 4], [1, 2], [2, 3]]),
        reason: 'the 2/2 twill tie-up names the two shafts each treadle sinks');

    // Shadow weave goes through its own call, with the same sinking-shed conversion.
    const shadow = ShadowWeaveParams();
    final rising = await repo.generateShadowWeaveDoc(DraftDoc.blank(), shadow);
    final sinking =
        await repo.generateShadowWeaveDoc(DraftDoc.blank().copyWith(shed: Shed.sinking), shadow);
    expect(sinking.shed, Shed.sinking);
    expect((sinking.drive as DraftTreadled).tieup.first, equals([3, 4]),
        reason: 'treadle 1 sinks the shafts it does not raise');
    final a = await renderPreviewDto(dto: repo.toDto(rising), cellPx: 2);
    final b = await renderPreviewDto(dto: repo.toDto(sinking), cellPx: 2);
    expect(b.rgba, equals(a.rgba), reason: 'shadow weave: same cloth on a sinking shed');
  });

  // Authentic shadow weave against the real engine: the default design (Atwater, 4 shafts, a point of
  // A2 B2 C2 D2, 2 x 2 repeats, balanced) comes back at its stated size, treadled as drawn in, validates
  // clean, and its Powell form weaves the identical cloth.
  testWidgets('the default shadow weave generates at its stated size and matches its Powell form',
      (tester) async {
    final repo = DraftRepository();
    const params = ShadowWeaveParams();
    final doc = await repo.generateShadowWeaveDoc(DraftDoc.blank(), params);
    expect((doc.ends, doc.picks), (params.ends, params.picks));
    expect((doc.ends, doc.picks), (61, 61));
    expect(doc.shafts, 4);
    final drive = doc.drive as DraftTreadled;
    expect(drive.tieup, equals([[1, 2], [2, 3], [3, 4], [1, 4]]),
        reason: 'the Atwater 2/2 twill tie-up');
    expect([for (final t in drive.treadling) t.first], equals([for (final s in doc.threading) s.first]),
        reason: 'treadled as drawn in');
    expect((await repo.validateDto(doc)).where((i) => i.isError), isEmpty);

    final powell =
        await repo.generateShadowWeaveDoc(DraftDoc.blank(), params.copyWith(system: ShadowSystem.powell));
    expect((powell.drive as DraftTreadled).tieup, equals([[1, 3], [2, 4], [2, 3], [1, 4]]));
    final a = await renderPreviewDto(dto: repo.toDto(doc), cellPx: 2);
    final b = await renderPreviewDto(dto: repo.toDto(powell), cellPx: 2);
    expect(b.rgba, equals(a.rgba), reason: 'Atwater and Powell weave the same cloth');

    // A parameter the engine refuses surfaces as an error, never a silently different draft.
    await expectLater(
        repo.generateShadowWeaveDoc(DraftDoc.blank(), params.copyWith(shafts: 6)), throwsA(anything));
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
