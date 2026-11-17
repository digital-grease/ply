import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/library_backup.dart';
import 'package:ply/src/models/material_record.dart';
import 'package:ply/src/screens/calculators_screen.dart';
import 'package:ply/src/screens/restore_preview_screen.dart';
import 'package:ply/src/state/backup_providers.dart';
import 'package:ply/src/state/draft_editor_notifier.dart';
import 'package:ply/src/state/editor_providers.dart';
import 'package:ply/src/state/loom_providers.dart';
import 'package:ply/src/state/material_providers.dart';
import 'package:ply/src/widgets/planning_sheet.dart';

import 'backup_test_support.dart';
import 'library_backup_materials_test.dart' show materialService, putLinkedProject, writeRecords;
import 'library_backup_looms_test.dart' show loomA, loomC, loomService, writeLooms;
import 'loom_test_support.dart';
import 'materials_test_support.dart';
import 'planning_sheet_test.dart' show FakePlanningRepo, fourEnds;

// The weaving planning calculator and the Calculators tab using a swatch (ADR 0016), and the
// restore preview's materials section. The engine is a stand-in.

Future<ProviderContainer> pumpWith(WidgetTester t, Widget home, FakeMaterialsRepository repo,
    {List<Override> more = const []}) async {
  t.view.physicalSize = const Size(900, 4000);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  final c = ProviderContainer(overrides: [
    materialsRepositoryProvider.overrideWithValue(repo),
    projectLinksRepositoryProvider.overrideWithValue(FakeProjectLinks()),
    ...more,
  ]);
  addTearDown(c.dispose);
  await t.pumpWidget(UncontrolledProviderScope(container: c, child: MaterialApp(home: home)));
  await t.pumpAndSettle();
  return c;
}

String fieldText(WidgetTester t, String label) =>
    t.widget<TextField>(find.widgetWithText(TextField, label).first).controller!.text;

void main() {
  group('the weaving planning calculator', () {
    Future<void> pumpSheet(WidgetTester t, FakeMaterialsRepository repo) async {
      final c = await pumpWith(t, const Scaffold(body: PlanningSheet()), repo,
          more: [repositoryProvider.overrideWithValue(FakePlanningRepo())]);
      c.read(draftEditorProvider.notifier).load(fourEnds());
      await t.pumpAndSettle();
    }

    testWidgets('a swatch fills the sett, the take-up and the picks; estimates cite it', (t) async {
      final repo = FakeMaterialsRepository(swatches: [towelSwatch, knitSwatch])
        ..warp = TracedEstimate(
            value: const WarpAmount(
                ends: 240,
                warpLength: Length(5.19, LengthUnit.yard),
                total: Length(1246.67, LengthUnit.yard)),
            inputs: [
              tracedInput(
                  'length_allowance',
                  'Take-up and shrinkage',
                  '11.1% of the finished length',
                  ValueSource.measured,
                  'from 20 in on the loom and 18 in after wet finishing (measured), swatch Towel sample 2026-11-02'),
            ])
        ..weft = TracedEstimate(
            value: const WeftAmount(picks: 3564, total: Length(47044.8, LengthUnit.inch)),
            inputs: [
              tracedInput('ppi', 'Picks', '22 picks per in', ValueSource.measured,
                  'measured on the loom, swatch Towel sample 2026-11-02'),
            ]);
      await pumpSheet(t, repo);
      await t.tap(find.byKey(const ValueKey('use-swatch')));
      await t.pumpAndSettle();
      expect(find.text('Grey wool stockinette (2026-11-10)'), findsNothing,
          reason: 'only weaving swatches are offered');
      await t.tap(find.text('Towel sample (2026-11-02)').last);
      await t.pumpAndSettle();
      expect(fieldText(t, 'Sett (ends/in)'), '24');
      expect(fieldText(t, 'Take-up + shrinkage (%)'), '11.11');
      expect(fieldText(t, 'Picks per in'), '22');
      // Ends from the swatch's sett across a cloth width.
      await t.enterText(find.widgetWithText(TextFormField, 'Cloth width (in)'), '10');
      await t.pump();
      await t.tap(find.text('Use 240 warp ends'));
      await t.pump();
      await t.enterText(find.widgetWithText(TextFormField, 'Finished length (yd)'), '2');
      await t.tap(find.text('Estimate warp'));
      await t.pumpAndSettle();
      final warp = repo.asked.last;
      expect(warp['ends'], InputOrigin.swatch);
      expect(warp['allowance'], InputOrigin.swatch);
      expect(warp['loomWaste'], InputOrigin.plyDefault, reason: 'the 0 it starts at is assumed');
      expect(find.text('Warp length: 5.19 yd'), findsOneWidget);
      expect(find.textContaining('Take-up and shrinkage: 11.1% of the finished length, from 20 in'),
          findsOneWidget);
      await t.enterText(find.widgetWithText(TextFormField, 'Woven width (in)'), '12');
      await t.enterText(find.widgetWithText(TextFormField, 'Woven length (yd)'), '2.25');
      await t.tap(find.text('Estimate weft'));
      await t.pumpAndSettle();
      expect(repo.asked.last['ppi'], InputOrigin.swatch);
      expect(repo.asked.last['takeup'], InputOrigin.plyDefault);
      expect(find.text('Total picks: 3564'), findsOneWidget);
      expect(
          find.text('Picks: 22 picks per in, measured on the loom, swatch Towel sample 2026-11-02'),
          findsOneWidget);
      // A value typed over the swatch's is the weaver's own.
      await t.enterText(find.widgetWithText(TextFormField, 'Picks per in'), '20');
      await t.tap(find.text('Estimate weft'));
      await t.pumpAndSettle();
      expect(repo.asked.last['ppi'], InputOrigin.entered);
    });

    testWidgets('a swatch missing a measurement says so and leaves that field', (t) async {
      const partial = SwatchRecord(id: 'p', name: 'Partial', craft: SwatchCraft.weaving);
      await pumpSheet(t, FakeMaterialsRepository(swatches: [partial]));
      await t.tap(find.byKey(const ValueKey('use-swatch')));
      await t.pumpAndSettle();
      await t.tap(find.text('Partial').last);
      await t.pumpAndSettle();
      expect(find.textContaining('This swatch records no sett in the reed'), findsOneWidget);
      expect(fieldText(t, 'Take-up + shrinkage (%)'), '10');
    });

    testWidgets('without swatches it looks as it did', (t) async {
      await pumpSheet(t, FakeMaterialsRepository(materials: [wool]));
      expect(find.byKey(const ValueKey('use-swatch')), findsNothing);
    });
  });

  testWidgets('the Calculators tab takes a swatch and cites it', (t) async {
    final repo = FakeMaterialsRepository(materials: [wool], swatches: [knitSwatch])
      ..castOn = TracedEstimate(value: 111, inputs: [
        tracedInput('stitch_gauge', 'Stitch gauge', '20 sts per 10 cm', ValueSource.measured,
            'measured after finishing, swatch Grey wool stockinette 2026-11-10'),
      ])
      ..yardage = TracedEstimate(
          value: const YarnAmount(
              weighed: false,
              yards: 500,
              meters: 457.2,
              bufferedYards: 550,
              bufferedMeters: 502.92),
          inputs: [
            tracedInput('method', 'Method', 'stockinette rule of thumb', ValueSource.plyDefault,
                "Ply's default"),
          ]);
    await pumpWith(t, const Scaffold(body: CalculatorsScreen()), repo);
    await t.tap(find.byKey(const ValueKey('use-swatch')));
    await t.pumpAndSettle();
    await t.tap(find.text('Grey wool stockinette (2026-11-10)').last);
    await t.pumpAndSettle();
    expect(fieldText(t, 'Stitches per 4 in'), '20.32', reason: 'the swatch, per the tab\'s 4 in');
    expect(find.text('Cast on 111 stitches'), findsOneWidget);
    expect(find.textContaining('Stitch gauge: 20 sts per 10 cm, measured after finishing'),
        findsOneWidget);
    expect(find.text('~550 yards'), findsOneWidget);
    expect(repo.asked.where((a) => a['gauge'] == InputOrigin.swatch), isNotEmpty);
  });

  testWidgets('the restore preview lists materials and swatches and restores the ticked ones',
      (t) async {
    t.view.physicalSize = const Size(1200, 4000);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    late RestorePlan plan;
    await t.runAsync(() async {
      docs = await Directory.systemTemp.createTemp('ui_docs');
      work = await Directory.systemTemp.createTemp('ui_work');
      final source = await Directory.systemTemp.createTemp('ui_src');
      addTearDown(() async {
        await docs.delete(recursive: true);
        await work.delete(recursive: true);
        await source.delete(recursive: true);
      });
      await putLinkedProject(source);
      await writeRecords(source, materials: [wool, cotton], swatches: [knitSwatch]);
      await put(source, 'swatches/sw-knit.photos/aaa.jpg', photo1);
      final archive = await backUp(materialService(into: source));
      await writeRecords(docs, materials: [wool.copyWith(name: 'Mine'), cotton]);
      plan = await materialService().inspectBackup(archive);
    });
    final backup = FakeBackup()..inspected = plan;
    String? closing;
    await t.pumpWidget(ProviderScope(
      overrides: [
        libraryBackupProvider.overrideWithValue(backup),
        materialsRepositoryProvider.overrideWithValue(FakeMaterialsRepository()),
        projectLinksRepositoryProvider.overrideWithValue(FakeProjectLinks()),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  final r = await Navigator.of(context).push<RestoreResult>(
                      MaterialPageRoute(builder: (_) => RestorePreviewScreen(plan: plan)));
                  if (r != null) closing = restoredMessage(r);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    expect(find.text('Materials and swatches'), findsOneWidget);
    expect(find.text('Different from yours (1 material)'), findsOneWidget);
    expect(find.textContaining('Add as "Grey wool (restored)"'), findsOneWidget);
    expect(find.textContaining('The project from this backup that uses it will use the copy.'),
        findsOneWidget);
    expect(find.text('Already in your materials (1 material)'), findsOneWidget);
    expect(find.text('New swatches (1)'), findsOneWidget);
    expect(find.textContaining('1 photo'), findsOneWidget);
    expect(find.text('Restore 1 project, 1 material and 1 swatch'), findsOneWidget);
    // Untick the copy: the restored project (and swatch) keep naming the crafter's own record.
    await t.tap(find.byType(CheckboxListTile).first);
    await t.pump();
    expect(
        find.text('Not added. The project from this backup that uses it will use your own "Mine". '
            'The swatch from this backup that names it will name your own "Mine".'),
        findsOneWidget);
    expect(find.text('Restore 1 project and 1 swatch'), findsOneWidget);
    await t.tap(find.text('Restore 1 project and 1 swatch'));
    await t.pumpAndSettle();
    expect(backup.skippedRecords, {'material/grey-wool'});
    expect(closing, 'Restored 1 project and 1 swatch.');
  });

  testWidgets('an unticked loom copy says the drafts will be planned for the weaver\'s own loom',
      (t) async {
    t.view.physicalSize = const Size(1200, 4000);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    late RestorePlan plan;
    await t.runAsync(() async {
      docs = await Directory.systemTemp.createTemp('ui_docs');
      work = await Directory.systemTemp.createTemp('ui_work');
      final source = await Directory.systemTemp.createTemp('ui_src');
      addTearDown(() async {
        await docs.delete(recursive: true);
        await work.delete(recursive: true);
        await source.delete(recursive: true);
      });
      await seedLibrary(source);
      await put(
          source,
          'drafts/d1.json',
          sidecar('Twill', 'Weaving', extra: {
            'loomPlan': {'loomId': 'loom-c', 'loomName': 'Gamma'},
          }));
      await writeLooms(source, [loomA, loomC]);
      final archive = await backUp(loomService(into: source));
      await writeLooms(docs, [loomC.copyWith(notes: 'edited here')]);
      plan = await loomService().inspectBackup(archive);
    });
    await t.pumpWidget(ProviderScope(
      overrides: [
        libraryBackupProvider.overrideWithValue(FakeBackup()..inspected = plan),
        loomRepositoryProvider.overrideWithValue(FakeLoomRepository()),
        materialsRepositoryProvider.overrideWithValue(FakeMaterialsRepository()),
        projectLinksRepositoryProvider.overrideWithValue(FakeProjectLinks()),
      ],
      child: MaterialApp(home: RestorePreviewScreen(plan: plan)),
    ));
    await t.pumpAndSettle();
    await t.tap(find.widgetWithText(CheckboxListTile, 'Gamma'));
    await t.pumpAndSettle();
    expect(
        find.text('Not added. The draft from this backup planned for it will be planned for your '
            'own "Gamma".'),
        findsOneWidget);
  });
}
