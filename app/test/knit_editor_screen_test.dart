import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/knit_repository.dart';
import 'package:ply/src/models/knit_stitches.dart';
import 'package:ply/src/rust/dto.dart' show SeverityKind, ColorDto, UnitKind;
import 'package:ply/src/rust/knit_dto.dart';
import 'package:ply/src/screens/knit_editor_screen.dart';
import 'package:ply/src/state/knit_editor_providers.dart';
import 'package:ply/src/state/knit_editor_state.dart';

// Host coverage for the knit editor's inline validation band: it collapses to a worst-severity
// summary, expands on tap to the full Errors-first list, and shows zero chrome when clean. A fake
// repo stubs blank/render/validate so the screen builds without FFI.

class FakeEditorRepo extends KnitRepository {
  FakeEditorRepo({this.issues = const []});
  List<KnitIssueDto> issues;

  @override
  Future<KnitPatternDto> blank() async => KnitEditorState.placeholder;

  @override
  Future<ui.Image> render(KnitPatternDto pattern, {required int cellPx}) {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      Uint8List.fromList(const [0, 0, 0, 255]),
      1,
      1,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    return completer.future;
  }

  @override
  Future<List<KnitIssueDto>> validate(KnitPatternDto pattern) async => issues;
}

/// A 4×4 all-knit pattern to load over the blank placeholder so the chart + fill have cells.
KnitPatternDto _fourByFour() => KnitPatternDto(
      name: 'x',
      construction: ConstructionKind.flat,
      firstRowSide: SideKind.rs,
      gauge: const GaugeDto(sts: 18, rows: 24, unit: UnitKind.inches),
      palette: const [ColorDto(r: 255, g: 255, b: 255)],
      legend: const StitchLegendDto(stitches: []),
      chart: ChartDto(
        width: 4,
        rows: List.generate(
          4,
          (_) => RowDto(
            cells: List.generate(4, (_) => const CellDto(stitch: KnitStitch.knit)),
            repeats: const [],
          ),
        ),
      ),
      notes: '',
    );

Future<ProviderContainer> pumpEditor(WidgetTester tester, FakeEditorRepo repo) async {
  final c = ProviderContainer(overrides: [knitRepositoryProvider.overrideWithValue(repo)]);
  addTearDown(c.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: const MaterialApp(home: KnitEditorScreen()),
    ),
  );
  await tester.pumpAndSettle();
  return c;
}

void main() {
  testWidgets('opening with an initialPattern (the New flow) loads without a build-phase provider error',
      (tester) async {
    final c =
        ProviderContainer(overrides: [knitRepositoryProvider.overrideWithValue(FakeEditorRepo())]);
    addTearDown(c.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        // The New pattern setup screen hands the editor a freshly-built pattern via initialPattern;
        // this branch must defer its provider write off the build frame (Riverpod forbids mutating
        // during initState/build).
        child: const MaterialApp(home: KnitEditorScreen(initialPattern: KnitEditorState.placeholder)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Could not open the knitting pattern'), findsNothing,
        reason: 'no modify-a-provider-while-building crash on the New flow');
    expect(find.widgetWithText(ChoiceChip, 'Keep'), findsOneWidget,
        reason: 'the editor loaded its brush toolbar');
    expect(c.read(knitEditorProvider).pattern, KnitEditorState.placeholder);
  });

  testWidgets('the validation band summarizes worst-severity and expands to the full list',
      (tester) async {
    await pumpEditor(
      tester,
      FakeEditorRepo(issues: const [
        KnitIssueDto(severity: SeverityKind.error, message: 'row 1 is too short'),
        KnitIssueDto(severity: SeverityKind.warning, message: 'odd repeat span'),
      ]),
    );

    // Collapsed: a worst-severity summary, not the individual messages.
    expect(find.text('1 error, 1 warning'), findsOneWidget);
    expect(find.text('row 1 is too short'), findsNothing);

    // Tap to expand -> both messages show, Errors first.
    await tester.tap(find.text('1 error, 1 warning'));
    await tester.pumpAndSettle();
    expect(find.text('row 1 is too short'), findsOneWidget);
    expect(find.text('odd repeat span'), findsOneWidget);
  });

  testWidgets('a single issue shows its message inline (no count summary)', (tester) async {
    await pumpEditor(
      tester,
      FakeEditorRepo(issues: const [
        KnitIssueDto(severity: SeverityKind.error, message: 'cable span runs off the edge'),
      ]),
    );
    expect(find.text('cable span runs off the edge'), findsOneWidget);
  });

  testWidgets('a clean chart shows no validation band', (tester) async {
    await pumpEditor(tester, FakeEditorRepo());
    expect(find.byIcon(Icons.error_outline), findsNothing);
    expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);
  });

  testWidgets('select mode + Fill applies the active stitch to the selection, then clears it',
      (tester) async {
    final c = await pumpEditor(tester, FakeEditorRepo());
    c.read(knitEditorProvider.notifier).load(_fourByFour());
    c.read(activeKnitStitchProvider.notifier).state = KnitStitch.purl;
    c.read(knitToolProvider.notifier).state = KnitTool.select;
    c.read(knitSelectionProvider.notifier).state = const KnitSelection(0, 0, 1, 1);
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Fill selection'));
    await tester.pumpAndSettle();

    final chart = c.read(knitEditorProvider).pattern.chart;
    expect(chart.rows[0].cells[0].stitch, KnitStitch.purl);
    expect(chart.rows[1].cells[1].stitch, KnitStitch.purl);
    expect(chart.rows[2].cells[2].stitch, KnitStitch.knit, reason: 'outside the selection');
    expect(c.read(knitSelectionProvider), isNull, reason: 'the selection clears after filling');
    expect(c.read(knitEditorProvider).undo.length, 1, reason: 'one undo entry for the fill');
  });

  testWidgets('the overflow Zoom in action steps the chart zoom', (tester) async {
    final c = await pumpEditor(tester, FakeEditorRepo());
    final before = c.read(knitZoomProvider);
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Zoom in'));
    await tester.pumpAndSettle();
    expect(c.read(knitZoomProvider), before + kKnitZoomStep);
  });

  testWidgets('the +cable action adds a cable to the legend and makes it the active brush',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final c = await pumpEditor(tester, FakeEditorRepo());
    // Cables are their own brush section now — open it, then add a cable from that section.
    await tester.tap(find.widgetWithText(ChoiceChip, 'Cables'));
    await tester.pumpAndSettle();
    final cableChip = find.widgetWithText(ActionChip, 'Cable');
    await tester.ensureVisible(cableChip);
    await tester.tap(cableChip);
    await tester.pumpAndSettle();
    expect(find.text('New cable'), findsOneWidget); // the builder dialog
    await tester.tap(find.text('Add cable'));
    await tester.pumpAndSettle();

    final stitches = c.read(knitEditorProvider).pattern.legend.stitches;
    expect(stitches.where((s) => s.cable != null).length, 1, reason: 'one cable added');
    expect(c.read(activeKnitStitchProvider), stitches.length - 1,
        reason: 'the new cable is the active brush');
  });

  testWidgets('the brush picker filters stitches by the selected section', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await pumpEditor(tester, FakeEditorRepo());
    // Default section = Basic: the knit chip shows; a decrease (k2tog) is hidden in its own section.
    expect(find.widgetWithText(ChoiceChip, 'k'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, 'k2tog'), findsNothing);

    // Open Decreases: k2tog now shows and the basic knit chip is gone.
    await tester.tap(find.widgetWithText(ChoiceChip, 'Decreases'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ChoiceChip, 'k2tog'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, 'k'), findsNothing);

    // Open Increases: a make-one increase shows.
    await tester.tap(find.widgetWithText(ChoiceChip, 'Increases'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ChoiceChip, 'yo'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, 'k2tog'), findsNothing);
  });

  testWidgets('selecting a color drops the stitch brush to Keep (so color paints OVER a symbol)',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final c = await pumpEditor(tester, FakeEditorRepo());
    // Start on a real stitch brush; choosing a color layer must flip the stitch to Keep so the next
    // tap only adds color and leaves the existing symbol in place.
    c.read(activeKnitStitchProvider.notifier).state = KnitStitch.purl;
    final noColor = find.byTooltip('No color (clear the cell colorwork)');
    await tester.ensureVisible(noColor);
    await tester.tap(noColor);
    await tester.pump();
    expect(c.read(activeKnitColorProvider), knitColorNone);
    expect(c.read(activeKnitStitchProvider), knitStitchKeep);
  });

  testWidgets('selecting a stitch drops the color brush to Keep (so a symbol never wipes color)',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final c = await pumpEditor(tester, FakeEditorRepo());
    c.read(activeKnitColorProvider.notifier).state = 0; // a real palette color
    final purl = find.byTooltip('Purl');
    await tester.ensureVisible(purl);
    await tester.tap(purl);
    await tester.pump();
    expect(c.read(activeKnitStitchProvider), KnitStitch.purl);
    expect(c.read(activeKnitColorProvider), knitColorKeep);
  });
}
