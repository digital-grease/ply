import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/knit_repository.dart';
import 'package:ply/src/data/library_backup.dart' show BackupCraft;
import 'package:ply/src/data/materials_repository.dart';
import 'package:ply/src/models/material_record.dart';
import 'package:ply/src/rust/dto.dart' show UnitKind;
import 'package:ply/src/rust/knit_dto.dart';
import 'package:ply/src/screens/materials_screen.dart';
import 'package:ply/src/state/knit_editor_providers.dart';
import 'package:ply/src/state/material_providers.dart';
import 'package:ply/src/widgets/knit_planning_sheet.dart';
import 'package:ply/src/widgets/project_materials_sheet.dart';

import 'materials_test_support.dart';

// The materials UI (ADR 0016): the Materials list and forms, the per-project sheet, and the knitting
// calculator using a swatch and saying where each input came from. The engine is a stand-in.

late FakeProjectLinks links;

Future<void> putSidecar(String folder, String id, Map<String, dynamic> json) async =>
    links.sidecars['$folder/$id'] = json;

Map<String, dynamic> sidecarJson(String folder, String id) => links.sidecars['$folder/$id']!;

Future<ProviderContainer> pump(WidgetTester t, Widget home, FakeMaterialsRepository repo,
    {List<Override> more = const []}) async {
  if (t.view.physicalSize.height < 2400) t.view.physicalSize = const Size(900, 2400);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  final c = ProviderContainer(overrides: [
    materialsRepositoryProvider.overrideWithValue(repo),
    projectLinksRepositoryProvider.overrideWithValue(links),
    ...more,
  ]);
  addTearDown(c.dispose);
  await t.pumpWidget(UncontrolledProviderScope(container: c, child: MaterialApp(home: home)));
  await t.pumpAndSettle();
  return c;
}

class _FakeKnits extends KnitRepository {
  @override
  Future<int> castOn(double width, double ease, GaugeDto gauge, int repeat) async => 100;

  @override
  Future<double> estimateYards(double width, double length, GaugeDto gauge) async => 250;
}

void main() {
  setUp(() => links = FakeProjectLinks());

  group('the Materials screen', () {
    testWidgets('empty, it says what records are for; a material is added through the form',
        (t) async {
      final repo = FakeMaterialsRepository();
      await pump(t, const MaterialsScreen(), repo);
      expect(find.textContaining('No materials yet'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('add-material')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const ValueKey('material-name')), 'Grey wool');
      await t.enterText(find.byKey(const ValueKey('material-lpm-length')), '200');
      await t.enterText(find.byKey(const ValueKey('material-lpm-mass')), '100');
      await t.pump();
      await t.tap(find.byKey(const ValueKey('material-save')));
      await t.pumpAndSettle();
      expect(repo.saves, 1);
      final m = repo.library.materials.single;
      expect(m.name, 'Grey wool');
      expect(m.lengthPerMass!.source, ValueSource.entered, reason: 'a label figure is entered');
      expect(m.lengthPerMass!.value.length.unit, LengthUnit.yard,
          reason: "a yarn length starts in the app's units (imperial unless chosen otherwise)");
      expect(m.wpi, isNull, reason: 'a blank field stays unknown');
      expect(find.text('Grey wool'), findsOneWidget);
    });

    testWidgets('a field that cannot be right is not saved', (t) async {
      final repo = FakeMaterialsRepository();
      await pump(t, const MaterialsScreen(), repo);
      await t.tap(find.byKey(const ValueKey('add-material')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const ValueKey('material-wpi')), '0');
      await t.pump();
      expect(find.textContaining('Enter a number above 0'), findsWidgets);
      await t.tap(find.byKey(const ValueKey('material-save')));
      await t.pumpAndSettle();
      expect(repo.saves, 0);
      // The engine's errors stop a save too.
      await t.enterText(find.byKey(const ValueKey('material-wpi')), '');
      repo.report = const RecordReport(diagnostics: [
        RecordDiagnostic(
            code: 'material.fiber_percents_over_100',
            isError: true,
            field: 'fibers',
            message: 'The fiber shares add up to 110%, more than 100%.'),
      ]);
      await t.tap(find.byKey(const ValueKey('material-save')));
      await t.pumpAndSettle();
      expect(repo.saves, 0);
      expect(find.text('The fiber shares add up to 110%, more than 100%.'), findsOneWidget);
    });

    testWidgets('deleting a record says how many projects use it, and asks first', (t) async {
      await putSidecar('knits', 'k1', {
        'name': 'Hat',
        'materials': {
          'yarns': [
            {'materialId': 'grey-wool', 'materialName': 'Grey wool'}
          ],
        },
      });
      await putSidecar('drafts', 'd1', {
        'name': 'Scarf',
        'materials': {
          'yarns': [
            {'materialId': 'grey-wool', 'materialName': 'Grey wool'}
          ],
        },
      });
      final repo = FakeMaterialsRepository(materials: [wool, cotton]);
      await pump(t, const MaterialsScreen(), repo);
      expect(find.textContaining('Used by 2 projects'), findsOneWidget);
      await t.tap(find.byTooltip('Material actions').first);
      await t.pumpAndSettle();
      await t.tap(find.text('Delete'));
      await t.pumpAndSettle();
      expect(find.textContaining('2 projects use this material: Hat, Scarf'), findsOneWidget);
      await t.tap(find.text('Cancel'));
      await t.pumpAndSettle();
      expect(repo.library.materials, hasLength(2), reason: 'nothing deleted without asking');
      await t.tap(find.byTooltip('Material actions').first);
      await t.pumpAndSettle();
      await t.tap(find.text('Delete'));
      await t.pumpAndSettle();
      await t.tap(find.widgetWithText(FilledButton, 'Delete'));
      await t.pumpAndSettle();
      expect(repo.library.materials.map((m) => m.id), ['cotton-8-2']);
    });

    testWidgets('a newer materials file is read only and says why', (t) async {
      await pump(
          t, const MaterialsScreen(), FakeMaterialsRepository(status: MaterialsFileStatus.newer));
      expect(find.textContaining('newer version of Ply'), findsOneWidget);
      expect(find.byType(FloatingActionButton), findsNothing);
    });

    testWidgets('a new swatch saves in place, then takes photos; figures show below', (t) async {
      t.view.physicalSize = const Size(900, 9000); // the whole form at once
      final repo = FakeMaterialsRepository();
      repo.report = const RecordReport(figures: [
        Figure(
            code: 'swatch.width_change',
            label: 'Width change in finishing',
            value: -0.1,
            text: '10% larger',
            from: 'from 13.5 cm (measured) before finishing to 15 cm (measured) after finishing'),
      ]);
      await pump(t, const MaterialsScreen(initialTab: 1), repo);
      await t.tap(find.byKey(const ValueKey('add-swatch')));
      await t.pumpAndSettle();
      expect(find.textContaining('Save the swatch to add photos'), findsOneWidget);
      await t.enterText(find.byKey(const ValueKey('swatch-name')), 'Grey wool stockinette');
      await t.tap(find.byKey(const ValueKey('swatch-craft-knitting')));
      await t.pump();
      await t.enterText(find.byKey(const ValueKey('swatch-after-across')), '20');
      await t.enterText(find.byKey(const ValueKey('swatch-date')), '2026-11-10');
      await t.pumpAndSettle();
      expect(find.text('Width change in finishing: 10% larger'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('swatch-save')));
      await t.pumpAndSettle();
      final s = repo.library.swatches.single;
      expect(s.craft, SwatchCraft.knitting);
      expect(s.after.across!.value.label('sts'), '20 sts per 4 in',
          reason: "the span starts at the usual 4 in (the app's units are imperial here)");
      expect(s.after.across!.source, ValueSource.measured);
      expect(s.before.across, isNull);
      expect(find.textContaining('Save the swatch to add photos'), findsNothing);
      expect(find.text('Add'), findsOneWidget, reason: 'the photo strip is there');
    });
  });

  group('the project sheet', () {
    testWidgets('links show their record, or "not in your materials"; linking is saved at once',
        (t) async {
      await putSidecar('knits', 'k1', {
        'name': 'Hat',
        'futureKey': 1,
        'materials': {
          'yarns': [
            {'materialId': 'gone', 'materialName': 'Old merino'}
          ],
        },
      });
      final repo = FakeMaterialsRepository(materials: [wool], swatches: [knitSwatch]);
      await pump(t,
          const Scaffold(body: ProjectMaterialsSheet(craft: BackupCraft.knitting, id: 'k1')), repo);
      expect(find.text('Old merino'), findsOneWidget);
      expect(find.textContaining('not in your materials'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('link-material')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('link-material-confirm')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('link-swatch')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('link-swatch-sw-knit')));
      await t.pumpAndSettle();
      final json = sidecarJson('knits', 'k1');
      expect(json['futureKey'], 1);
      expect(
          (json['materials']['yarns'] as List).map((y) => y['materialId']), ['gone', 'grey-wool']);
      expect(json['materials']['swatches'][0]['swatchId'], 'sw-knit');
      // Unlink the missing one.
      await t.tap(find.descendant(
          of: find.byKey(const ValueKey('linked-material-gone')),
          matching: find.byTooltip('Unlink')));
      await t.pumpAndSettle();
      expect((sidecarJson('knits', 'k1')['materials']['yarns'] as List).single['materialId'],
          'grey-wool');
    });

    testWidgets('an unsaved project is asked to save first', (t) async {
      await pump(
          t,
          const Scaffold(body: ProjectMaterialsSheet(craft: BackupCraft.weaving, id: null)),
          FakeMaterialsRepository(materials: [wool]));
      expect(find.text('Save the project first to link materials and swatches.'), findsOneWidget);
      expect(find.byKey(const ValueKey('link-material')), findsNothing);
    });

    const action = Scaffold(body: ProjectMaterialsAction(craft: BackupCraft.nalbinding, id: 'n1'));

    testWidgets('the editor action is hidden with no records and no links', (t) async {
      await putSidecar('nalbinds', 'n1', {'name': 'Mitten'});
      await pump(t, action, FakeMaterialsRepository());
      expect(find.byKey(const ValueKey('project-materials-action')), findsNothing,
          reason: 'with no materials the screen looks as it did');
    });

    testWidgets('the editor action shows once there is a record', (t) async {
      await putSidecar('nalbinds', 'n1', {'name': 'Mitten'});
      await pump(t, action, FakeMaterialsRepository(materials: [wool]));
      expect(find.byKey(const ValueKey('project-materials-action')), findsOneWidget);
    });

    testWidgets('the editor action shows for a project that links a record', (t) async {
      await putSidecar('nalbinds', 'n1', {
        'name': 'Mitten',
        'materials': {
          'swatches': [
            {'swatchId': 'x', 'swatchName': 'Old'}
          ],
        },
      });
      await pump(t, action, FakeMaterialsRepository());
      expect(find.byKey(const ValueKey('project-materials-action')), findsOneWidget,
          reason: 'a project that links a record still offers it');
    });
  });

  group('the knitting calculator with a swatch', () {
    TracedEstimate<int> castOn() => TracedEstimate(value: 112, inputs: [
          tracedInput('stitch_gauge', 'Stitch gauge', '20 sts per 10 cm', ValueSource.measured,
              'measured after finishing (washed in cool water, dried flat), swatch Grey wool stockinette 2026-11-10'),
          tracedInput('width', 'Finished width', '50 cm', ValueSource.entered, 'you entered it'),
        ], working: [
          '(50 cm + 5 cm) x 2 sts per cm = 110 sts, rounded to 110 sts.'
        ]);

    Future<ProviderContainer> pumpSheet(WidgetTester t, FakeMaterialsRepository repo) =>
        pump(t, const Scaffold(body: KnitPlanningSheet()), repo,
            more: [knitRepositoryProvider.overrideWithValue(_FakeKnits())]);

    testWidgets('without swatches it looks as it did', (t) async {
      await pumpSheet(t, FakeMaterialsRepository());
      expect(find.byKey(const ValueKey('use-swatch')), findsNothing);
    });

    testWidgets('a swatch fills the gauge, and the estimate cites it', (t) async {
      final repo = FakeMaterialsRepository(materials: [wool], swatches: [knitSwatch, towelSwatch])
        ..castOn = castOn();
      await pumpSheet(t, repo);
      await t.tap(find.byKey(const ValueKey('use-swatch')));
      await t.pumpAndSettle();
      expect(find.text('Towel sample (2026-11-02)'), findsNothing,
          reason: 'only knitting swatches are offered');
      await t.tap(find.text('Grey wool stockinette (2026-11-10)').last);
      await t.pumpAndSettle();
      final sts = t.widget<TextFormField>(find.widgetWithText(TextFormField, 'Stitches'));
      expect(sts.controller!.text, '20');
      expect(find.text('Gauge (per 10 cm)'), findsOneWidget);
      await t.enterText(find.widgetWithText(TextFormField, 'Finished width (cm)'), '50');
      await t.enterText(find.widgetWithText(TextFormField, 'Ease (+/- cm)'), '5');
      final calc = find.widgetWithText(FilledButton, 'Calculate cast-on');
      await t.ensureVisible(calc);
      await t.tap(calc);
      await t.pumpAndSettle();
      expect(repo.asked.last['gauge'], InputOrigin.swatch,
          reason: 'the gauge comes from the swatch');
      expect(repo.asked.last['swatch'], 'sw-knit');
      expect(find.text('Cast on 112 stitches'), findsOneWidget);
      expect(
          find.text(
              'Stitch gauge: 20 sts per 10 cm, measured after finishing (washed in cool water, '
              'dried flat), swatch Grey wool stockinette 2026-11-10'),
          findsOneWidget);
      // Changing the gauge makes it the knitter's own.
      await t.enterText(find.widgetWithText(TextFormField, 'Stitches'), '21');
      await t.tap(calc);
      await t.pumpAndSettle();
      expect(repo.asked.last['gauge'], InputOrigin.entered);
    });

    testWidgets('the yarn estimate passes the swatch\'s one yarn for the weighed method',
        (t) async {
      final repo = FakeMaterialsRepository(materials: [wool], swatches: [knitSwatch])
        ..yardage = TracedEstimate(
            value: const YarnAmount(
                weighed: true,
                yards: 262.47,
                meters: 240,
                bufferedYards: 288.71,
                bufferedMeters: 264),
            inputs: [
              tracedInput('swatch_mass', 'Swatch mass', '9 g', ValueSource.measured,
                  'measured, swatch Grey wool stockinette 2026-11-10'),
              tracedInput('buffer', 'Buffer', '10%', ValueSource.plyDefault, "Ply's default"),
            ]);
      await pumpSheet(t, repo);
      await t.tap(find.byKey(const ValueKey('use-swatch')));
      await t.pumpAndSettle();
      await t.tap(find.text('Grey wool stockinette (2026-11-10)').last);
      await t.pumpAndSettle();
      await t.enterText(find.widgetWithText(TextFormField, 'Width (cm)'), '50');
      await t.enterText(find.widgetWithText(TextFormField, 'Length (cm)'), '60');
      final est = find.widgetWithText(FilledButton, 'Estimate yardage');
      await t.ensureVisible(est);
      await t.tap(est);
      await t.pumpAndSettle();
      expect(repo.asked.last['yarn'], 'grey-wool');
      expect(find.text('With 10% buffer: 288.71 yards'), findsOneWidget);
      expect(find.text("Buffer: 10%, Ply's default"), findsOneWidget);
      expect(find.text('Inputs marked Ply default are assumed, not measured.'), findsOneWidget);
    });

    testWidgets('a swatch the engine cannot use says why', (t) async {
      final repo = FakeMaterialsRepository(swatches: [knitSwatch])
        ..planError =
            'Swatch Grey wool stockinette has no stitch count, so it cannot give a gauge.';
      await pumpSheet(t, repo);
      await t.tap(find.byKey(const ValueKey('use-swatch')));
      await t.pumpAndSettle();
      await t.tap(find.text('Grey wool stockinette (2026-11-10)').last);
      await t.pumpAndSettle();
      await t.enterText(find.widgetWithText(TextFormField, 'Finished width (cm)'), '50');
      final calc = find.widgetWithText(FilledButton, 'Calculate cast-on');
      await t.ensureVisible(calc);
      await t.tap(calc);
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('plan-error')), findsOneWidget);
    });
  });

  test('a GaugeDto seed still works without materials', () {
    expect(const GaugeDto(sts: 20, rows: 28, unit: UnitKind.inches).sts, 20);
  });
}
