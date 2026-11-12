import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/knit_repository.dart';
import 'package:ply/src/models/knit_stitches.dart';
import 'package:ply/src/rust/dto.dart' show ColorDto, UnitKind;
import 'package:ply/src/rust/knit_dto.dart';
import 'package:ply/src/screens/new_knit_setup_screen.dart';
import 'package:ply/src/state/knit_editor_providers.dart';

// The PURE chart-fill of the New-knit setup screen (the FFI parts — blank pattern + gauge seed — are
// engine-tested separately). Confirms each starting stitch pattern paints the right cells and the
// re-paint preserves width, per-row repeats, and cell colors. Then the screen itself, over a fake
// repository (no FFI): the typed stitch count becomes the cast-on unless the knitter turns that off.

/// The two FFI calls the setup screen makes, stood in for (no native library on the host).
class FakeSetupRepo extends KnitRepository {
  @override
  Future<KnitPatternDto> blank() async => const KnitPatternDto(
        name: '',
        construction: ConstructionKind.flat,
        firstRowSide: SideKind.rs,
        gauge: GaugeDto(sts: 18, rows: 24, unit: UnitKind.inches),
        palette: [ColorDto(r: 255, g: 255, b: 255)],
        legend: StitchLegendDto(stitches: []),
        chart: ChartDto(width: 0, rows: []),
        notes: '',
      );

  @override
  Future<GaugeDto> seedGauge(YarnWeightKind weight) async =>
      const GaugeDto(sts: 18, rows: 24, unit: UnitKind.inches);
}

/// Open the setup screen, let [configure] fill it in, tap Create, and return the popped pattern.
Future<KnitPatternDto?> createPattern(
    WidgetTester tester, Future<void> Function() configure) async {
  KnitPatternDto? created;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [knitRepositoryProvider.overrideWithValue(FakeSetupRepo())],
      child: MaterialApp(
        home: Builder(
          builder: (ctx) => TextButton(
            onPressed: () async => created = await Navigator.of(ctx).push<KnitPatternDto>(
              MaterialPageRoute(builder: (_) => const NewKnitSetupScreen()),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  await configure();
  // The form is a lazy ListView: scroll until the button at its end is built.
  final create = find.widgetWithText(FilledButton, 'Create pattern');
  await tester.scrollUntilVisible(create, 200, scrollable: find.byType(Scrollable).first);
  await tester.tap(create);
  await tester.pumpAndSettle();
  return created;
}

ChartDto allKnit(int w, int h) => ChartDto(
      width: w,
      rows: [
        for (var r = 0; r < h; r++)
          RowDto(
            cells: [for (var c = 0; c < w; c++) const CellDto(stitch: KnitStitch.knit)],
            repeats: const <RepeatSpanDto>[],
          ),
      ],
    );

void main() {
  test('starterStitchAt places knit/purl per pattern', () {
    // Stockinette: knit everywhere.
    expect(starterStitchAt(KnitStarter.stockinette, 2, 3), KnitStitch.knit);
    // Garter: odd ROWS purl (horizontal ridges).
    expect(starterStitchAt(KnitStarter.garter, 0, 5), KnitStitch.knit);
    expect(starterStitchAt(KnitStarter.garter, 1, 0), KnitStitch.purl);
    // 1x1 ribbing: odd COLUMNS purl (vertical ribs).
    expect(starterStitchAt(KnitStarter.ribbing, 3, 0), KnitStitch.knit);
    expect(starterStitchAt(KnitStarter.ribbing, 3, 1), KnitStitch.purl);
    // Seed: (row+col) odd purl (checkerboard).
    expect(starterStitchAt(KnitStarter.seed, 0, 0), KnitStitch.knit);
    expect(starterStitchAt(KnitStarter.seed, 0, 1), KnitStitch.purl);
    expect(starterStitchAt(KnitStarter.seed, 1, 1), KnitStitch.knit);
  });

  test('starterChart fills cells and preserves shape + repeats', () {
    final base = allKnit(4, 3);

    final seed = starterChart(base, KnitStarter.seed);
    expect(seed.width, 4);
    expect(seed.rows.length, 3);
    expect(seed.rows[0].cells[0].stitch, KnitStitch.knit);
    expect(seed.rows[0].cells[1].stitch, KnitStitch.purl);
    expect(seed.rows[1].cells[0].stitch, KnitStitch.purl);
    expect(seed.rows[0].repeats, isEmpty, reason: 'per-row repeat info is carried through');

    final ribbing = starterChart(base, KnitStarter.ribbing);
    expect(ribbing.rows.every((row) => row.cells[0].stitch == KnitStitch.knit), isTrue);
    expect(ribbing.rows.every((row) => row.cells[1].stitch == KnitStitch.purl), isTrue);

    final stock = starterChart(base, KnitStarter.stockinette);
    expect(stock.rows.every((row) => row.cells.every((c) => c.stitch == KnitStitch.knit)), isTrue);
  });

  test('ribbing honors a custom knit×purl ratio (1×2)', () {
    // 1×2 rib across the columns: K P P  K P P ...
    int at(int c) => starterStitchAt(KnitStarter.ribbing, 0, c, knitRun: 1, purlRun: 2);
    expect(at(0), KnitStitch.knit);
    expect(at(1), KnitStitch.purl);
    expect(at(2), KnitStitch.purl);
    expect(at(3), KnitStitch.knit, reason: 'the 1×2 pattern repeats every 3 columns');
  });

  test('starterChart passes the rib ratio through (2×2)', () {
    final rib = starterChart(allKnit(6, 1), KnitStarter.ribbing, knitRun: 2, purlRun: 2);
    expect(rib.rows[0].cells.map((c) => c.stitch).toList(), const [
      KnitStitch.knit,
      KnitStitch.knit,
      KnitStitch.purl,
      KnitStitch.purl,
      KnitStitch.knit,
      KnitStitch.knit,
    ]);
  });

  test('a starter band limits the pattern to the first N rows, then stockinette', () {
    final cuff = starterChart(allKnit(4, 4), KnitStarter.ribbing, bandRows: 2);
    expect(cuff.rows[0].cells[1].stitch, KnitStitch.purl, reason: 'row 0 is in the band');
    expect(cuff.rows[1].cells[1].stitch, KnitStitch.purl, reason: 'row 1 is in the band');
    expect(cuff.rows[2].cells.every((c) => c.stitch == KnitStitch.knit), isTrue,
        reason: 'beyond the band -> stockinette');
    expect(cuff.rows[3].cells.every((c) => c.stitch == KnitStitch.knit), isTrue);
  });

  group('cast-on from the typed size', () {
    final stitches = find.widgetWithText(TextFormField, 'Stitches');
    final castOnSwitch = find.byKey(const Key('knit-setup-cast-on'));

    testWidgets('by default the typed stitch count becomes the cast-on', (tester) async {
      final p = await createPattern(tester, () async {
        expect(find.text('Cast on 20 stitches'), findsOneWidget, reason: 'the default size');
        await tester.enterText(stitches, '26');
        await tester.pump();
        expect(find.text('Cast on 26 stitches'), findsOneWidget, reason: 'it names the typed count');
        expect(tester.widget<SwitchListTile>(castOnSwitch).value, isTrue);
      });
      expect(p, isNotNull);
      expect(p!.chart.width, 26);
      expect(p.castOn, 26, reason: 'row 1 works exactly the typed count');
    });

    testWidgets('turning it off leaves the cast-on unset', (tester) async {
      final p = await createPattern(tester, () async {
        await tester.enterText(stitches, '8');
        await tester.tap(castOnSwitch);
        await tester.pump();
        expect(tester.widget<SwitchListTile>(castOnSwitch).value, isFalse);
      });
      expect(p!.chart.width, 8);
      expect(p.castOn, isNull);
    });

    testWidgets('one stitch reads in the singular', (tester) async {
      await createPattern(tester, () async {
        await tester.enterText(stitches, '1');
        await tester.pump();
        expect(find.text('Cast on 1 stitch'), findsOneWidget);
      });
    });
  });
}
