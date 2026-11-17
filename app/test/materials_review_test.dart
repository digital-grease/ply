import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/knit_repository.dart';
import 'package:ply/src/models/material_record.dart';
import 'package:ply/src/rust/knit_dto.dart';
import 'package:ply/src/screens/calculators_screen.dart';
import 'package:ply/src/screens/materials_screen.dart';
import 'package:ply/src/state/draft_editor_notifier.dart';
import 'package:ply/src/state/editor_providers.dart';
import 'package:ply/src/state/knit_editor_providers.dart';
import 'package:ply/src/state/material_providers.dart';
import 'package:ply/src/widgets/knit_planning_sheet.dart';
import 'package:ply/src/widgets/planning_sheet.dart';

import 'materials_test_support.dart';
import 'planning_sheet_test.dart' show FakePlanningRepo, fourEnds;

// Fixes from the review of the materials work (ADR 0016): a calculator follows the swatch as the
// library holds it now (edited, deleted), works the estimates out again when its gauge changes in
// code, keeps each estimate's error to itself; the weaving sheet takes a sample that grew; "Use N
// warp ends" counts from the swatch's exact sett; deleting a record waits for the usage scan and
// names the swatches that use a material; and changes to the library run one at a time.

late FakeProjectLinks links;

class _Knits extends KnitRepository {
  @override
  Future<int> castOn(double width, double ease, GaugeDto gauge, int repeat) async => 100;

  @override
  Future<double> estimateYards(double width, double length, GaugeDto gauge) async => 250;
}

Future<ProviderContainer> pumpWith(WidgetTester t, Widget home, FakeMaterialsRepository repo,
    {List<Override> more = const [], void Function(ProviderContainer c)? before}) async {
  t.view.physicalSize = const Size(900, 4000);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  final c = ProviderContainer(overrides: [
    materialsRepositoryProvider.overrideWithValue(repo),
    projectLinksRepositoryProvider.overrideWithValue(links),
    ...more,
  ]);
  addTearDown(c.dispose);
  before?.call(c);
  await t.pumpWidget(UncontrolledProviderScope(container: c, child: MaterialApp(home: home)));
  await t.pumpAndSettle();
  return c;
}

String fieldText(WidgetTester t, String label) =>
    t.widget<TextField>(find.widgetWithText(TextField, label).first).controller!.text;

TracedEstimate<int> castOn(int n) => TracedEstimate(value: n, inputs: [
      tracedInput('stitch_gauge', 'Stitch gauge', 'gauge', ValueSource.measured, 'from the swatch'),
    ]);

TracedEstimate<YarnAmount> yarn() => TracedEstimate(
    value: const YarnAmount(
        weighed: false, yards: 500, meters: 457.2, bufferedYards: 550, bufferedMeters: 502.92),
    inputs: [tracedInput('method', 'Method', 'rule', ValueSource.plyDefault, "Ply's default")]);

Future<void> chooseSwatch(WidgetTester t, String label) async {
  await t.tap(find.byKey(const ValueKey('use-swatch')));
  await t.pumpAndSettle();
  await t.tap(find.text(label).last);
  await t.pumpAndSettle();
}

void main() {
  setUp(() => links = FakeProjectLinks());

  group('the Calculators tab', () {
    testWidgets('follows an edited swatch and lets go of a deleted one', (t) async {
      final repo = FakeMaterialsRepository(swatches: [knitSwatch])
        ..castOn = castOn(111)
        ..yardage = yarn();
      final c = await pumpWith(t, const Scaffold(body: CalculatorsScreen()), repo);
      await chooseSwatch(t, 'Grey wool stockinette (2026-11-10)');
      expect(fieldText(t, 'Stitches per 4 in'), '20.32');
      // Edited elsewhere (the tab stays mounted under the Materials screen): 25 sts per 10 cm.
      const edited = SwatchRecord(
        id: 'sw-knit',
        name: 'Grey wool stockinette',
        craft: SwatchCraft.knitting,
        date: '2026-11-10',
        after: SwatchStage(
            across: Recorded.measured(CountOver(25, Length(10, LengthUnit.centimeter)))),
      );
      await c.read(materialLibraryProvider.notifier).upsertSwatch(edited);
      await t.pumpAndSettle();
      expect(fieldText(t, 'Stitches per 4 in'), '25.4', reason: 'filled again from the record');
      expect(repo.asked.last['swatchRecord'], edited,
          reason: 'the engine gets the record as it is');
      // Deleted elsewhere: the choice clears, and the engine is not asked about it again.
      await c.read(materialLibraryProvider.notifier).deleteSwatch('sw-knit');
      await t.pumpAndSettle();
      final asks = repo.asked.length;
      expect(find.byKey(const ValueKey('use-swatch')), findsNothing, reason: 'no swatch left');
      expect(find.byKey(const ValueKey('estimate-trace')), findsNothing);
      await t.enterText(find.widgetWithText(TextField, 'Stitches per 4 in'), '21');
      await t.pumpAndSettle();
      expect(repo.asked.length, asks);
    });

    testWidgets('the WPI seed changes the gauge and works the estimates out again', (t) async {
      final repo = FakeMaterialsRepository(swatches: [knitSwatch])
        ..castOn = castOn(111)
        ..yardage = yarn();
      await pumpWith(t, const Scaffold(body: CalculatorsScreen()), repo);
      await chooseSwatch(t, 'Grey wool stockinette (2026-11-10)');
      expect(repo.asked.last['gauge'], InputOrigin.swatch);
      repo.castOn = castOn(99);
      await t.enterText(find.widgetWithText(TextField, 'Wraps per inch (WPI)'), '11');
      await t.pumpAndSettle();
      await t.tap(find.textContaining('Use 22 sts'));
      await t.pumpAndSettle();
      final ask = repo.asked.lastWhere((a) => a['kind'] == 'castOn');
      expect(ask['gauge'], InputOrigin.entered, reason: 'the seeded gauge is not the swatch\'s');
      expect(find.text('Cast on 99 stitches'), findsOneWidget, reason: 'never the stale 111');
    });

    testWidgets('a cast-on that cannot be worked out leaves the yarn estimate alone', (t) async {
      final repo = FakeMaterialsRepository(swatches: [knitSwatch])
        ..castOnError = 'The finished width must be more than 0.'
        ..yardage = yarn();
      await pumpWith(t, const Scaffold(body: CalculatorsScreen()), repo);
      await chooseSwatch(t, 'Grey wool stockinette (2026-11-10)');
      expect(find.byKey(const ValueKey('cast-on-error')), findsOneWidget);
      expect(find.text('The finished width must be more than 0.'), findsOneWidget);
      expect(find.byKey(const ValueKey('yarn-error')), findsNothing);
      expect(find.text('~550 yards'), findsOneWidget,
          reason: 'the yarn estimate still from the engine');
      expect(find.text("Method: rule, Ply's default"), findsOneWidget);
    });
  });

  testWidgets('the knitting sheet drops a swatch result once the WPI seed changes the gauge',
      (t) async {
    final repo = FakeMaterialsRepository(swatches: [knitSwatch])..castOn = castOn(112);
    await pumpWith(t, const Scaffold(body: KnitPlanningSheet()), repo,
        more: [knitRepositoryProvider.overrideWithValue(_Knits())]);
    await chooseSwatch(t, 'Grey wool stockinette (2026-11-10)');
    await t.enterText(find.widgetWithText(TextFormField, 'Finished width (cm)'), '50');
    final calc = find.widgetWithText(FilledButton, 'Calculate cast-on');
    await t.ensureVisible(calc);
    await t.tap(calc);
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('estimate-trace')), findsOneWidget);
    await t.enterText(find.widgetWithText(TextField, 'Wraps per inch'), '11');
    await t.pumpAndSettle();
    await t.tap(find.textContaining('Use 22 sts'));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('estimate-trace')), findsNothing, reason: 'it was stale');
    expect(find.text('Cast on 112 stitches'), findsNothing);
  });

  group('the weaving planning calculator', () {
    Future<FakePlanningRepo> pumpSheet(WidgetTester t, FakeMaterialsRepository repo) async {
      final planning = FakePlanningRepo();
      await pumpWith(t, const Scaffold(body: PlanningSheet()), repo,
          more: [repositoryProvider.overrideWithValue(planning)],
          before: (c) => c.read(draftEditorProvider.notifier).load(fourEnds()));
      return planning;
    }

    testWidgets('a sample that grew in finishing gives a take-up below 0, and it is used',
        (t) async {
      const grew = SwatchRecord(
        id: 'grew',
        name: 'Grew',
        craft: SwatchCraft.weaving,
        onLoom: SwatchStage(length: Recorded.measured(Length(100, LengthUnit.centimeter))),
        after: SwatchStage(length: Recorded.measured(Length(105, LengthUnit.centimeter))),
      );
      final repo = FakeMaterialsRepository(swatches: [grew])
        ..warp = const TracedEstimate(
            value: WarpAmount(
                ends: 4, warpLength: Length(1, LengthUnit.yard), total: Length(4, LengthUnit.yard)),
            inputs: [],
            notes: ['Swatch Grew came out longer after finishing than on the loom.']);
      await pumpSheet(t, repo);
      await chooseSwatch(t, 'Grew');
      expect(fieldText(t, 'Take-up + shrinkage (%)'), '-4.76');
      await t.enterText(find.widgetWithText(TextFormField, 'Finished length (yd)'), '2');
      await t.tap(find.text('Estimate warp'));
      await t.pumpAndSettle();
      expect(find.text('Enter 0 or more'), findsNothing);
      expect(repo.asked.last['allowance'], InputOrigin.swatch);
      expect(find.textContaining('came out longer after finishing'), findsOneWidget,
          reason: "the engine's note is shown");
    });

    testWidgets('a typed take-up below 0 is accepted within the engine\'s range', (t) async {
      final planning = await pumpSheet(t, FakeMaterialsRepository());
      await t.enterText(find.widgetWithText(TextFormField, 'Finished length (yd)'), '2');
      await t.enterText(find.widgetWithText(TextFormField, 'Take-up + shrinkage (%)'), '-5');
      await t.tap(find.text('Estimate warp'));
      await t.pumpAndSettle();
      expect(planning.warpArgs!.takeupPercent, -5);
      await t.enterText(find.widgetWithText(TextFormField, 'Take-up + shrinkage (%)'), '-95');
      await t.tap(find.text('Estimate warp'));
      await t.pumpAndSettle();
      expect(find.text('Enter a percentage from -90 to 1000'), findsOneWidget);
    });

    testWidgets('"Use N warp ends" counts from the swatch\'s exact sett', (t) async {
      const fine = SwatchRecord(
        id: 'fine',
        name: 'Fine sett',
        craft: SwatchCraft.weaving,
        sett: Recorded.entered(CountOver(12.345, Length(1, LengthUnit.inch))),
      );
      final repo = FakeMaterialsRepository(swatches: [fine]);
      await pumpSheet(t, repo);
      await chooseSwatch(t, 'Fine sett');
      expect(fieldText(t, 'Sett (ends/in)'), '12.35', reason: 'shown rounded');
      await t.enterText(find.widgetWithText(TextFormField, 'Cloth width (in)'), '200');
      await t.pump();
      // 12.345 x 200 = 2469 (the engine's count); the rounded 12.35 would give 2470.
      expect(find.text('Use 2469 warp ends'), findsOneWidget);
    });
  });

  group('deleting a record', () {
    testWidgets('waits for the usage scan, then names projects and swatches', (t) async {
      final gate = Completer<void>();
      links
        ..usageGate = gate.future
        ..sidecars['knits/k1'] = {
          'name': 'Hat',
          'materials': {
            'yarns': [
              {'materialId': 'grey-wool', 'materialName': 'Grey wool'}
            ],
          },
        };
      await pumpWith(t, const MaterialsScreen(),
          FakeMaterialsRepository(materials: [wool], swatches: [knitSwatch]));
      await t.tap(find.byTooltip('Material actions'));
      await t.pumpAndSettle();
      await t.tap(find.text('Delete'));
      await t.pump();
      expect(find.textContaining('Checking which projects use this material'), findsOneWidget);
      final button = find.byKey(const ValueKey('confirm-delete'));
      expect(t.widget<FilledButton>(button).onPressed, isNull, reason: 'not until it is known');
      gate.complete();
      await t.pumpAndSettle();
      final text = t.widget<Text>(find.byKey(const ValueKey('delete-usage'))).data!;
      expect(text, contains('1 project uses this material: Hat'));
      expect(text, contains('1 swatch names it: Grey wool stockinette'));
      expect(text, contains('can no longer use its length per mass'));
      expect(t.widget<FilledButton>(button).onPressed, isNotNull);
    });

    testWidgets('says when it could not check', (t) async {
      links.usageError = StateError('disk');
      await pumpWith(t, const MaterialsScreen(), FakeMaterialsRepository(materials: [cotton]));
      await t.tap(find.byTooltip('Material actions'));
      await t.pumpAndSettle();
      await t.tap(find.text('Delete'));
      await t.pumpAndSettle();
      expect(find.textContaining('Ply could not check which projects use this material'),
          findsOneWidget);
      expect(find.textContaining('No project uses'), findsNothing);
    });
  });

  test('changes to the library run one at a time', () async {
    final gate = Completer<void>();
    final repo = FakeMaterialsRepository(swatches: [knitSwatch])..saveGate = gate.future;
    final c = ProviderContainer(overrides: [materialsRepositoryProvider.overrideWithValue(repo)]);
    addTearDown(c.dispose);
    await c.read(materialLibraryProvider.future);
    final notifier = c.read(materialLibraryProvider.notifier);
    // A delete and a duplicate at once: the duplicate runs on what the delete left.
    final deleted = notifier.deleteSwatch('sw-knit');
    final copied = notifier.duplicateSwatch('sw-knit');
    gate.complete();
    await deleted;
    expect(await copied, isNull, reason: 'the swatch was gone by then');
    expect(repo.library.swatches, isEmpty, reason: 'never brought back');
    expect(c.read(materialLibraryProvider).value!.swatches, isEmpty);
  });
}
