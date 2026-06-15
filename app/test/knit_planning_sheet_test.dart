import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/knit_repository.dart';
import 'package:ply/src/rust/dto.dart' show UnitKind;
import 'package:ply/src/rust/knit_dto.dart';
import 'package:ply/src/state/knit_editor_providers.dart';
import 'package:ply/src/widgets/knit_planning_sheet.dart';

// Host coverage for the knit planning calculator: Apply-gauge writes onto the pattern, the cast-on
// and yardage calculators surface the repo's results (+ a 10% buffer line), and seeding from a yarn
// weight fills the gauge fields. A fake repo returns deterministic numbers (no FFI).

class FakeCalcRepo extends KnitRepository {
  @override
  Future<GaugeDto> seedGauge(YarnWeightKind weight) async =>
      const GaugeDto(sts: 20, rows: 28, unit: UnitKind.inches);

  @override
  Future<int> castOn(double width, double ease, GaugeDto gauge, int repeat) async => 100;

  @override
  Future<double> estimateYards(double width, double length, GaugeDto gauge) async => 250;
}

Future<ProviderContainer> pumpSheet(WidgetTester tester) async {
  final c = ProviderContainer(
    overrides: [knitRepositoryProvider.overrideWithValue(FakeCalcRepo())],
  );
  addTearDown(c.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: const MaterialApp(home: Scaffold(body: KnitPlanningSheet())),
    ),
  );
  await tester.pumpAndSettle();
  return c;
}

void main() {
  testWidgets('Apply gauge writes the edited gauge onto the pattern', (tester) async {
    final c = await pumpSheet(tester);
    await tester.enterText(find.widgetWithText(TextFormField, 'Stitches'), '22');
    final apply = find.widgetWithText(FilledButton, 'Apply gauge');
    await tester.ensureVisible(apply);
    await tester.tap(apply);
    await tester.pumpAndSettle();
    expect(c.read(knitEditorProvider).pattern.gauge.sts, 22);
    expect(find.text('Saved to the pattern'), findsOneWidget);
  });

  testWidgets('the cast-on calculator surfaces the stitch count', (tester) async {
    await pumpSheet(tester);
    await tester.enterText(find.widgetWithText(TextFormField, 'Finished width (in)'), '20');
    final calc = find.widgetWithText(FilledButton, 'Calculate cast-on');
    await tester.ensureVisible(calc);
    await tester.tap(calc);
    await tester.pumpAndSettle();
    expect(find.text('Cast on 100 stitches'), findsOneWidget);
  });

  testWidgets('the yardage estimate shows the figure plus a 10% buffer', (tester) async {
    await pumpSheet(tester);
    await tester.enterText(find.widgetWithText(TextFormField, 'Width (in)'), '20');
    await tester.enterText(find.widgetWithText(TextFormField, 'Length (in)'), '30');
    final est = find.widgetWithText(FilledButton, 'Estimate yardage');
    await tester.ensureVisible(est);
    await tester.tap(est);
    await tester.pumpAndSettle();
    expect(find.text('Estimate: 250 yards'), findsOneWidget);
    expect(find.text('With 10% buffer: 275 yards'), findsOneWidget);
  });

  testWidgets('seeding from a yarn weight fills the gauge fields', (tester) async {
    await pumpSheet(tester);
    await tester.tap(find.text('Seed from a yarn weight'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Medium / worsted (4)').last);
    await tester.pumpAndSettle();
    expect(find.text('20'), findsWidgets); // the Stitches field now reads the seeded 20
  });
}
