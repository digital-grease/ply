import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/knit_repository.dart';
import 'package:ply/src/models/draft_meta.dart';
import 'package:ply/src/models/knit_entry.dart';
import 'package:ply/src/models/knit_stitches.dart';
import 'package:ply/src/models/native_format.dart';
import 'package:ply/src/rust/dto.dart' show SeverityKind, ColorDto, UnitKind;
import 'package:ply/src/rust/knit_dto.dart';
import 'package:ply/src/screens/knit_editor_screen.dart';
import 'package:ply/src/state/knit_editor_providers.dart';
import 'package:ply/src/state/knit_editor_state.dart';

// Host coverage for the knit editor's inline validation band: it collapses to a worst-severity
// summary, expands on tap to the full Errors-first list, and shows zero chrome when clean. A fake
// repo stubs blank/render/validate so the screen builds without FFI. Also the dirty-on-exit guard
// (Save / Discard / Keep editing on a back with unsaved edits), via a fake that stubs the save.

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
      sections: const [],
    );

/// [FakeEditorRepo] plus the persistence calls the leave guard drives (no disk, no FFI).
class FakeSavingRepo extends FakeEditorRepo {
  int saveCount = 0;
  KnitPatternDto? savedPattern;
  DraftMeta? savedMeta;
  String? savedId;

  /// When set, saveKnit suspends on this until completed (holds one save in flight).
  Completer<void>? saveGate;

  /// When true, saveKnit throws (a failed write).
  bool saveError = false;

  /// When set, the NEXT saveKnit throws it (the repository refusing to replace the file on disk).
  NativeFormatException? refuseNextSave;

  /// When set, readPattern throws it (a file that cannot be opened).
  Object? readError;

  int openCount = 0;

  @override
  Future<String> saveKnit({
    required KnitPatternDto pattern,
    required DraftMeta meta,
    String? id,
  }) async {
    saveCount++;
    if (saveGate != null) await saveGate!.future;
    if (saveError) throw Exception('disk full');
    final refusal = refuseNextSave;
    if (refusal != null) {
      refuseNextSave = null;
      throw refusal;
    }
    savedPattern = pattern;
    savedMeta = meta;
    savedId = id;
    return id ?? 'new-id';
  }

  @override
  Future<KnitPatternDto> readPattern(String id) async {
    final error = readError;
    if (error != null) throw error;
    return _fourByFour();
  }

  @override
  Future<KnitEntry> openKnit(String id) async {
    openCount++;
    return KnitEntry(
      id: id,
      meta: DraftMeta(
        name: 'Saved hat',
        craft: 'Knitting',
        savedAt: DateTime.utc(2020),
        lastOpened: DateTime.utc(2020),
      ),
      patternPath: '/tmp/$id.plyknit',
    );
  }
}

/// Pumps a host that PUSHES the editor (so a back has somewhere to go), mirroring the library's
/// `push<void>`. [openId] opens a saved pattern (no naming step on save); null starts a new one.
Future<ProviderContainer> pumpHostedEditor(WidgetTester tester, FakeSavingRepo repo,
    {String? openId}) async {
  final c = ProviderContainer(overrides: [knitRepositoryProvider.overrideWithValue(repo)]);
  addTearDown(c.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => KnitEditorScreen(openId: openId)),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  expect(find.byType(KnitEditorScreen), findsOneWidget);
  return c;
}

/// Paint one cell (a real edit: a new pattern instance on the undo stack).
void editChart(ProviderContainer c, {int row = 0, int col = 0}) =>
    c.read(knitEditorProvider.notifier).paintCell(row, col, KnitStitch.purl, null);

/// Bounded pumps for when a save is held in flight (its spinner never settles).
Future<void> pumpFrames(WidgetTester tester) async {
  await tester.pump();
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 30));
  }
}

const _leaveTitle = 'Leave without saving?';

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
  testWidgets(
      'opening with an initialPattern (the New flow) loads without a build-phase provider error',
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
        child:
            const MaterialApp(home: KnitEditorScreen(initialPattern: KnitEditorState.placeholder)),
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

  group('repeats', () {
    /// Load a 4x4 chart, switch to SELECT and select [sel], ready for the Mark repeat action.
    Future<ProviderContainer> selectFor(WidgetTester tester, KnitSelection sel) async {
      final c = await pumpEditor(tester, FakeEditorRepo());
      c.read(knitEditorProvider.notifier).load(_fourByFour());
      c.read(knitToolProvider.notifier).state = KnitTool.select;
      c.read(knitSelectionProvider.notifier).state = sel;
      await tester.pumpAndSettle();
      return c;
    }

    testWidgets('Mark repeat marks the selection a number of times, as one undo entry',
        (tester) async {
      final c = await selectFor(tester, const KnitSelection(0, 1, 1, 2));
      expect(find.byTooltip('Mark repeat'), findsOneWidget);
      await tester.tap(find.byTooltip('Mark repeat'));
      await tester.pumpAndSettle();
      expect(find.text('Repeat stitches'), findsOneWidget);
      expect(find.text('Stitches 2 to 3, rows 1 to 2'), findsOneWidget,
          reason: 'numbered like the chart axis (right to left)');
      expect(find.text('Remove repeat'), findsNothing, reason: 'nothing to remove yet');
      await tester.tap(find.byTooltip('More times'));
      await tester.pump();
      expect(find.text('Worked 3 times in all.'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Mark repeat'));
      await tester.pumpAndSettle();

      final rows = c.read(knitEditorProvider).pattern.chart.rows;
      const span = RepeatSpanDto(start: 1, end: 3, count: RepeatDto.times(count: 3));
      expect(rows[0].repeats, const [span]);
      expect(rows[1].repeats, const [span]);
      expect(rows[2].repeats, isEmpty);
      expect(c.read(knitEditorProvider).undo, hasLength(1));
      expect(c.read(knitSelectionProvider), isNull, reason: 'the selection clears');
      expect(
          find.bySemanticsLabel('Repeats: stitches 2 to 3, rows 1 to 2, 3 times'), findsOneWidget,
          reason: 'the chart shows the bracket');
    });

    testWidgets('To end marks a repeat worked to the end of the row', (tester) async {
      final c = await selectFor(tester, const KnitSelection(2, 0, 2, 3));
      await tester.tap(find.byTooltip('Mark repeat'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('To end'));
      await tester.pumpAndSettle();
      expect(find.text('Number of times'), findsNothing);
      expect(find.text('Repeated across the row as many times as the stitches allow.'),
          findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Mark repeat'));
      await tester.pumpAndSettle();
      expect(c.read(knitEditorProvider).pattern.chart.rows[2].repeats,
          const [RepeatSpanDto(start: 0, end: 4, count: RepeatDto.toEnd())]);
    });

    testWidgets('Remove repeat clears the repeats the selection overlaps; Cancel changes nothing',
        (tester) async {
      final c = await selectFor(tester, const KnitSelection(0, 0, 0, 3));
      c.read(knitEditorProvider.notifier).markRepeat(0, 1, 0, 2, const RepeatDto.times(count: 2));
      await tester.pumpAndSettle();
      final before = c.read(knitEditorProvider).pattern;

      await tester.tap(find.byTooltip('Mark repeat'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(identical(c.read(knitEditorProvider).pattern, before), isTrue);

      await tester.tap(find.byTooltip('Mark repeat'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove repeat'));
      await tester.pumpAndSettle();
      expect(c.read(knitEditorProvider).pattern.chart.rows[0].repeats, isEmpty);
      expect(find.bySemanticsLabel(RegExp('^Repeats:')), findsNothing,
          reason: 'the bracket is gone');
    });

    testWidgets('selecting an existing repeat preselects its count', (tester) async {
      final c = await selectFor(tester, const KnitSelection(3, 0, 3, 1));
      c.read(knitEditorProvider.notifier).markRepeat(3, 0, 3, 1, const RepeatDto.times(count: 5));
      c.read(knitSelectionProvider.notifier).state = const KnitSelection(3, 0, 3, 1);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Mark repeat'));
      await tester.pumpAndSettle();
      expect(find.text('Worked 5 times in all.'), findsOneWidget);
      expect(find.text('Remove repeat'), findsOneWidget);
    });

    testWidgets('shrinking the chart clips a repeat and says so (never silently)', (tester) async {
      final c = await pumpEditor(tester, FakeEditorRepo());
      c.read(knitEditorProvider.notifier).load(_fourByFour());
      c.read(knitEditorProvider.notifier).markRepeat(0, 2, 0, 3, const RepeatDto.toEnd());
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Fewer Sts'));
      await tester.pump();
      expect(
          find.text('1 repeat was shortened to fit the chart. Undo to restore.'), findsOneWidget);
      expect(c.read(knitEditorProvider).pattern.chart.rows[0].repeats,
          const [RepeatSpanDto(start: 2, end: 3, count: RepeatDto.toEnd())]);

      // A resize that touches no repeat says nothing (once the first notice has timed out).
      await tester.pump(const Duration(seconds: 1)); // entrance done: the display timer starts
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(find.textContaining('Undo to restore'), findsNothing);
      await tester.tap(find.byTooltip('More Rows'));
      await tester.pump();
      expect(find.textContaining('Undo to restore'), findsNothing);
    });

    testWidgets('with a selection, the app bar fits Fill and Mark repeat at phone width',
        (tester) async {
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await selectFor(tester, const KnitSelection(0, 0, 0, 1));
      expect(tester.takeException(), isNull, reason: 'no layout overflow');
      expect(find.byTooltip('Fill selection'), findsOneWidget);
      expect(find.byTooltip('Mark repeat'), findsOneWidget);
      await tester.tap(find.byTooltip('Mark repeat'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'the dialog fits a phone');
      expect(find.widgetWithText(FilledButton, 'Mark repeat'), findsOneWidget);
    });

    testWidgets('repeat problems from the engine appear in the validation band', (tester) async {
      await pumpEditor(
        tester,
        FakeEditorRepo(issues: const [
          KnitIssueDto(
            severity: SeverityKind.error,
            message:
                'row 2: the repeat over cols 2-5 cannot be worked to the end: row 1 produced 7 '
                'stitches, the rest of the row uses 2, and the 5 left are not a multiple of 4',
          ),
          KnitIssueDto(
            severity: SeverityKind.warning,
            message:
                'row 1: the repeat over cols 2-5 is worked to the end of the row, but the pattern '
                'has no cast-on count, so Ply cannot count this row (it needs a multiple of 4 '
                'stitches plus 2); set the cast-on in the pattern settings',
          ),
        ]),
      );
      expect(find.text('1 error, 1 warning'), findsOneWidget);
      await tester.tap(find.text('1 error, 1 warning'));
      await tester.pumpAndSettle();
      expect(find.textContaining('are not a multiple of 4'), findsOneWidget);
      expect(find.textContaining('has no cast-on count'), findsOneWidget);
    });
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
  group('dirty-on-exit guard', () {
    testWidgets('an untouched NEW pattern pops straight back with no prompt', (tester) async {
      final repo = FakeSavingRepo();
      await pumpHostedEditor(tester, repo);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text(_leaveTitle), findsNothing);
      expect(find.byType(KnitEditorScreen), findsNothing, reason: 'a clean back exits immediately');
      expect(repo.saveCount, 0);
    });

    testWidgets('an opened pattern left untouched pops with no prompt', (tester) async {
      final repo = FakeSavingRepo();
      await pumpHostedEditor(tester, repo, openId: 'k1');
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text(_leaveTitle), findsNothing);
      expect(find.byType(KnitEditorScreen), findsNothing);
    });

    testWidgets('undoing every edit back to the saved state reads clean', (tester) async {
      final repo = FakeSavingRepo();
      final c = await pumpHostedEditor(tester, repo, openId: 'k1');
      editChart(c);
      editChart(c, row: 1, col: 1);
      await tester.pump();
      await tester.tap(find.byTooltip('Undo'));
      await tester.tap(find.byTooltip('Undo'));
      await tester.pumpAndSettle();
      expect(c.read(knitEditorProvider).isDirty, isFalse);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text(_leaveTitle), findsNothing);
      expect(find.byType(KnitEditorScreen), findsNothing);
    });

    testWidgets('back with edits prompts; Keep editing stays with the edit intact', (tester) async {
      final repo = FakeSavingRepo();
      final c = await pumpHostedEditor(tester, repo);
      editChart(c);
      await tester.pump();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text(_leaveTitle), findsOneWidget);
      expect(find.textContaining("this pattern haven't been saved"), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'Keep editing'));
      await tester.pumpAndSettle();
      expect(find.byType(KnitEditorScreen), findsOneWidget, reason: 'still editing');
      expect(c.read(knitEditorProvider).pattern.chart.rows[0].cells[0].stitch, KnitStitch.purl);
      expect(repo.saveCount, 0);
    });

    testWidgets('Discard leaves without saving', (tester) async {
      final repo = FakeSavingRepo();
      final c = await pumpHostedEditor(tester, repo, openId: 'k1');
      editChart(c);
      await tester.pump();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Discard'));
      await tester.pumpAndSettle();
      expect(find.byType(KnitEditorScreen), findsNothing, reason: 'discard exits');
      expect(find.text('open'), findsOneWidget, reason: 'exactly one pop: the host survives');
      expect(repo.saveCount, 0, reason: 'nothing persisted on discard');
    });

    testWidgets('Save on a NEW pattern runs the naming step, saves, then leaves', (tester) async {
      final repo = FakeSavingRepo();
      final c = await pumpHostedEditor(tester, repo);
      editChart(c);
      await tester.pump();
      final edited = c.read(knitEditorProvider).pattern;
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(find.text('Name this pattern'), findsOneWidget,
          reason: 'the normal save flow names it');
      await tester.enterText(find.widgetWithText(TextField, 'Pattern name'), 'Cabled hat');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(repo.saveCount, 1);
      expect(repo.savedMeta!.name, 'Cabled hat');
      expect(identical(repo.savedPattern, edited), isTrue,
          reason: 'the edited chart is what saved');
      expect(find.byType(KnitEditorScreen), findsNothing, reason: 'a successful save exits');
      expect(find.text('open'), findsOneWidget);
    });

    testWidgets('cancelling the naming step from the leave prompt stays (nothing saved)',
        (tester) async {
      final repo = FakeSavingRepo();
      final c = await pumpHostedEditor(tester, repo);
      editChart(c);
      await tester.pump();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(find.byType(KnitEditorScreen), findsOneWidget);
      expect(repo.saveCount, 0);
      expect(c.read(knitEditorProvider).isDirty, isTrue, reason: 'the edit is still there');
    });

    testWidgets('Save on an opened pattern saves in place (no naming), then leaves',
        (tester) async {
      final repo = FakeSavingRepo();
      final c = await pumpHostedEditor(tester, repo, openId: 'k1');
      editChart(c);
      await tester.pump();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(find.text('Name this pattern'), findsNothing);
      expect(repo.saveCount, 1);
      expect(repo.savedId, 'k1', reason: 'overwrites the opened pattern');
      expect(repo.savedMeta!.name, 'Saved hat');
      expect(find.byType(KnitEditorScreen), findsNothing);
    });

    testWidgets('a failed save stays on screen, keeps the edits, and still guards the back',
        (tester) async {
      final repo = FakeSavingRepo()..saveError = true;
      final c = await pumpHostedEditor(tester, repo, openId: 'k1');
      editChart(c);
      await tester.pump();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(repo.saveCount, 1);
      expect(find.byType(KnitEditorScreen), findsOneWidget, reason: 'a failed save never leaves');
      expect(find.textContaining('Could not save'), findsOneWidget);
      expect(c.read(knitEditorProvider).isDirty, isTrue);

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text(_leaveTitle), findsOneWidget, reason: 'still unsaved, so still guarded');
    });

    testWidgets('an empty chart refused by Save keeps the editor open', (tester) async {
      final repo = FakeSavingRepo();
      final c = await pumpHostedEditor(tester, repo, openId: 'k1');
      c.read(knitEditorProvider.notifier).resizeChart(0, 0); // dirty, but unsaveable
      await tester.pump();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Add some rows and stitches'), findsOneWidget);
      expect(find.byType(KnitEditorScreen), findsOneWidget);
      expect(repo.saveCount, 0);
    });

    testWidgets('an AppBar Save makes the editor clean; a later edit guards again', (tester) async {
      final repo = FakeSavingRepo();
      final c = await pumpHostedEditor(tester, repo, openId: 'k1');
      editChart(c);
      await tester.pump();
      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();
      expect(repo.saveCount, 1);
      expect(find.byType(KnitEditorScreen), findsOneWidget,
          reason: 'the knit editor saves in place');
      expect(c.read(knitEditorProvider).isDirty, isFalse);

      editChart(c, row: 2, col: 2);
      await tester.pump();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text(_leaveTitle), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Keep editing'));
      await tester.pumpAndSettle();

      // Undo the post-save edit: back at the SAVED pattern, which reads clean.
      c.read(knitEditorProvider.notifier).undo();
      await tester.pump();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text(_leaveTitle), findsNothing);
      expect(find.byType(KnitEditorScreen), findsNothing);
    });

    testWidgets('AppBar Save in flight + back -> Discard pops exactly once', (tester) async {
      final repo = FakeSavingRepo();
      final c = await pumpHostedEditor(tester, repo, openId: 'k1');
      editChart(c);
      await tester.pump();

      repo.saveGate = Completer<void>(); // park the write
      await tester.tap(find.byTooltip('Save'));
      await tester.pump();
      expect(repo.saveCount, 1);

      await tester.tap(find.byType(BackButton));
      await pumpFrames(tester);
      expect(find.text(_leaveTitle), findsOneWidget,
          reason: 'a back mid-save still offers the choice');

      await tester.tap(find.widgetWithText(TextButton, 'Discard'));
      await tester.pump(); // the discard pop begins its exit transition
      repo.saveGate!.complete(); // the parked save resumes mid-transition
      await tester.pumpAndSettle();

      expect(find.byType(KnitEditorScreen), findsNothing, reason: 'discarded');
      expect(find.text('open'), findsOneWidget, reason: 'the host route survives (no second pop)');
      expect(repo.saveCount, 1, reason: 'the save the user had already started is not repeated');
      expect(tester.takeException(), isNull);
    });

    testWidgets('AppBar Save in flight + back -> Save joins that save (one write), then leaves',
        (tester) async {
      final repo = FakeSavingRepo();
      final c = await pumpHostedEditor(tester, repo, openId: 'k1');
      editChart(c);
      await tester.pump();

      repo.saveGate = Completer<void>();
      await tester.tap(find.byTooltip('Save'));
      await tester.pump();
      await tester.tap(find.byType(BackButton));
      await pumpFrames(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await pumpFrames(tester);
      expect(find.byType(KnitEditorScreen), findsOneWidget, reason: 'waits for the save to land');

      repo.saveGate!.complete();
      await tester.pumpAndSettle();
      expect(repo.saveCount, 1, reason: 'joined the in-flight save, no second write');
      expect(find.byType(KnitEditorScreen), findsNothing, reason: 'left once the save succeeded');
      expect(find.text('open'), findsOneWidget);
    });

    testWidgets("a second back during the leave prompt's own save is dropped", (tester) async {
      final repo = FakeSavingRepo();
      final c = await pumpHostedEditor(tester, repo, openId: 'k1');
      editChart(c);
      await tester.pump();

      repo.saveGate = Completer<void>();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await pumpFrames(tester); // the write is parked; no dialog is on screen now
      await tester.tap(find.byType(BackButton));
      await pumpFrames(tester);
      expect(find.text(_leaveTitle), findsNothing, reason: 'no second prompt stacked');

      repo.saveGate!.complete();
      await tester.pumpAndSettle();
      expect(repo.saveCount, 1);
      expect(find.byType(KnitEditorScreen), findsNothing);
      expect(find.text('open'), findsOneWidget, reason: 'one pop only');
    });

    testWidgets("an edit landing during the leave prompt's save keeps the editor open",
        (tester) async {
      final repo = FakeSavingRepo();
      final c = await pumpHostedEditor(tester, repo, openId: 'k1');
      editChart(c);
      await tester.pump();

      repo.saveGate = Completer<void>();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await pumpFrames(tester);
      editChart(c, row: 3, col: 3); // lands while the write is in flight
      repo.saveGate!.complete();
      await tester.pumpAndSettle();

      expect(repo.saveCount, 1);
      expect(find.byType(KnitEditorScreen), findsOneWidget,
          reason: 'the newer edit was not in that save, so leaving would drop it');
      expect(c.read(knitEditorProvider).isDirty, isTrue);
    });
  });

  group('format safety', () {
    IconButton saveButton(WidgetTester tester) =>
        tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.save_outlined));

    testWidgets(
        'a pattern saved by a newer Ply opens to a plain message and can never be saved over',
        (tester) async {
      final repo = FakeSavingRepo()
        ..readError = const NativeFormatException(NativeFormatProblem.newerVersion,
            document: NativeDocument.knitPattern, detail: 'schema 3');
      await pumpHostedEditor(tester, repo, openId: 'k1');

      expect(
        find.text('This pattern was saved by a newer version of Ply. Update the app to open it.'),
        findsOneWidget,
      );
      expect(repo.openCount, 0, reason: 'the sidecar is not even touched');
      expect(saveButton(tester).onPressed, isNull, reason: 'nothing to save after a failed open');
      await tester.tap(find.widgetWithIcon(IconButton, Icons.save_outlined));
      await tester.pumpAndSettle();
      expect(repo.saveCount, 0);

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text(_leaveTitle), findsNothing);
      expect(find.byType(KnitEditorScreen), findsNothing, reason: 'leaves with no prompt');
    });

    testWidgets('any other open failure also disables Save', (tester) async {
      final repo = FakeSavingRepo()..readError = Exception('disk gone');
      await pumpHostedEditor(tester, repo, openId: 'k1');
      expect(find.textContaining('Could not open the knitting pattern'), findsOneWidget);
      expect(saveButton(tester).onPressed, isNull);
    });

    testWidgets('a save the repository refuses forgets the file; the next save makes a new pattern',
        (tester) async {
      final repo = FakeSavingRepo()
        ..refuseNextSave = const NativeFormatException(NativeFormatProblem.newerVersion,
            document: NativeDocument.knitPattern, whileSaving: true);
      final c = await pumpHostedEditor(tester, repo, openId: 'k1');
      editChart(c);
      await tester.pump();

      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();
      expect(repo.saveCount, 1);
      expect(find.textContaining('from a newer version of Ply, so it was not replaced'),
          findsOneWidget);
      expect(
          find.textContaining('Save again to keep your changes as a new pattern'), findsOneWidget);
      expect(c.read(knitEditorProvider).isDirty, isTrue, reason: 'the edits are kept');

      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();
      expect(find.text('Name this pattern'), findsOneWidget, reason: 'a new pattern needs a name');
      await tester.enterText(find.widgetWithText(TextField, 'Pattern name'), 'Rescued hat');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(repo.saveCount, 2);
      expect(repo.savedId, isNull, reason: 'saved as a NEW pattern, never over k1');
      expect(repo.savedMeta!.name, 'Rescued hat');
    });
  });
}
