import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/knit_repository.dart';
import 'package:ply/src/models/knit_stitches.dart';
import 'package:ply/src/rust/dto.dart' show ColorDto, UnitKind;
import 'package:ply/src/rust/knit_dto.dart';
import 'package:ply/src/state/knit_editor_providers.dart';
import 'package:ply/src/widgets/knit_chart_view.dart';

// The chart view's tap-to-paint: a tap maps to the right cell, with row 0 at the BOTTOM. The render
// is faked (a 1x1 stub) — the gesture math doesn't depend on the bitmap, so this runs on the host VM.

class FakeKnitRepo extends KnitRepository {
  @override
  Future<ui.Image> render(KnitPatternDto pattern, {required int cellPx}) => _stub();
  @override
  Future<List<KnitIssueDto>> validate(KnitPatternDto pattern) async => const [];
}

Future<ui.Image> _stub() {
  final c = Completer<ui.Image>();
  ui.decodeImageFromPixels(
      Uint8List.fromList(const [0, 0, 0, 255]), 1, 1, ui.PixelFormat.rgba8888, c.complete);
  return c.future;
}

KnitPatternDto grid(int w, int h) => KnitPatternDto(
      name: 't',
      construction: ConstructionKind.flat,
      firstRowSide: SideKind.rs,
      gauge: const GaugeDto(sts: 18, rows: 24, unit: UnitKind.inches),
      palette: const [ColorDto(r: 255, g: 255, b: 255)],
      legend: const StitchLegendDto(stitches: []),
      chart: ChartDto(
        width: w,
        rows: List.generate(
          h,
          (_) => RowDto(
            cells: List.generate(w, (_) => const CellDto(stitch: KnitStitch.knit)),
            repeats: const [],
          ),
        ),
      ),
      notes: '',
    );

Future<ProviderContainer> pump(WidgetTester tester, {int cell = 20}) async {
  final c = ProviderContainer(
    overrides: [knitRepositoryProvider.overrideWithValue(FakeKnitRepo())],
  );
  addTearDown(c.dispose);
  c.read(knitEditorProvider.notifier).load(grid(8, 8)); // 8x8 cells
  c.read(knitZoomProvider.notifier).state = cell; // 8*20 = 160px, fits the 800x600 test viewport
  c.read(activeKnitStitchProvider.notifier).state = KnitStitch.purl;
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: const MaterialApp(home: Scaffold(body: KnitChartView())),
    ),
  );
  await tester.pump();
  return c;
}

void main() {
  testWidgets('tapping near the BOTTOM paints chart row 0', (tester) async {
    final c = await pump(tester);
    final origin = tester.getTopLeft(find.byType(KnitChartView));
    // local (10, 150): col = 10~/20 = 0; rowFromTop = 150~/20 = 7; row = 8-1-7 = 0.
    await tester.tapAt(origin + const Offset(10, 150));
    await tester.pump();
    expect(c.read(knitEditorProvider).pattern.chart.rows[0].cells[0].stitch, KnitStitch.purl);
  });

  testWidgets('tapping near the TOP paints the top chart row', (tester) async {
    final c = await pump(tester);
    final origin = tester.getTopLeft(find.byType(KnitChartView));
    // local (30, 10): col = 1; rowFromTop = 0; row = 8-1-0 = 7 (the top row).
    await tester.tapAt(origin + const Offset(30, 10));
    await tester.pump();
    expect(c.read(knitEditorProvider).pattern.chart.rows[7].cells[1].stitch, KnitStitch.purl);
    expect(c.read(knitEditorProvider).pattern.chart.rows[0].cells[1].stitch, KnitStitch.knit,
        reason: 'the bottom row is untouched');
  });
}
