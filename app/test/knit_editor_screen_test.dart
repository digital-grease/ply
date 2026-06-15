import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/knit_repository.dart';
import 'package:ply/src/rust/dto.dart' show SeverityKind;
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
    // Widen the viewport so the whole horizontal brush row (builtins + the +cable chip) builds.
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final c = await pumpEditor(tester, FakeEditorRepo());
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
}
