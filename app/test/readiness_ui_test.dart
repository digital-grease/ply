import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/draft_repository.dart';
import 'package:ply/src/data/knit_repository.dart';
import 'package:ply/src/data/readiness_repository.dart';
import 'package:ply/src/models/draft_doc.dart';
import 'package:ply/src/models/draft_issue.dart';
import 'package:ply/src/models/knit_stitches.dart';
import 'package:ply/src/models/readiness.dart';
import 'package:ply/src/rust/dto.dart';
import 'package:ply/src/rust/knit_dto.dart';
import 'package:ply/src/rust/readiness_dto.dart';
import 'package:ply/src/rust/api.dart' show PreviewImage;
import 'package:ply/src/screens/knit_editor_screen.dart';
import 'package:ply/src/screens/knit_sections_screen.dart';
import 'package:ply/src/state/editor_providers.dart';
import 'package:ply/src/state/knit_editor_providers.dart';
import 'package:ply/src/widgets/draft_layout.dart';
import 'package:ply/src/widgets/integrated_draft_view.dart' show draftPlaceRect;
import 'package:ply/src/widgets/knit_chart_view.dart' show KnitChartView;
import 'package:ply/src/widgets/validation_panel.dart';

import 'editor_screen_test.dart' show FakeRepo, letAsyncSettle, pumpEditor;
import 'knit_sections_test_support.dart' show patternFromPlyknit;

// Where a finding is (ADR 0021): the engine's typed places reach the app intact, the editors show
// them in words, and Show goes there (the weaving draft scrolls to and outlines the cell, the
// knitting chart selects it); and the knitting chart says why it could not be drawn instead of
// going blank.

class _Drafts extends DraftRepository {
  _Drafts(this.issues);
  final List<DraftIssue> issues;

  @override
  Future<List<DraftIssue>> validateDto(DraftDoc doc) async => issues;
}

class _Knits extends KnitRepository {
  _Knits({this.issues = const [], this.failRender = false, this.empty = false});
  final List<KnitIssueDto> issues;
  final bool failRender;

  /// The engine drew nothing (a chart past its raster budget).
  final bool empty;

  @override
  Future<PreviewImage> renderPixels(KnitPatternDto pattern, {required int cellPx}) async =>
      PreviewImage(width: 0, height: 0, rgba: Uint8List(0));

  @override
  Future<KnitConstructionDto> construction(KnitPatternDto pattern) async =>
      const KnitConstructionDto(lines: [], issues: [], pieces: [], holds: [], groupNames: []);

  @override
  Future<KnitPatternDto> blank() async => _pattern();

  @override
  Future<ui.Image> render(KnitPatternDto pattern, {required int cellPx}) {
    if (failRender) return Future.error(StateError('the chart is too large to draw'));
    if (empty) return super.render(pattern, cellPx: cellPx);
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(Uint8List.fromList(const [0, 0, 0, 255]), 1, 1,
        ui.PixelFormat.rgba8888, completer.complete);
    return completer.future;
  }

  @override
  Future<List<KnitIssueDto>> validate(KnitPatternDto pattern) async => issues;
}

KnitPatternDto _pattern({int rows = 3}) => KnitPatternDto(
      name: 'x',
      construction: ConstructionKind.flat,
      firstRowSide: SideKind.rs,
      gauge: const GaugeDto(sts: 18, rows: 24, unit: UnitKind.inches),
      palette: const [ColorDto(r: 255, g: 255, b: 255)],
      legend: const StitchLegendDto(stitches: []),
      chart: ChartDto(
        width: 4,
        rows: List.generate(
          rows,
          (_) => RowDto(
            cells: List.generate(4, (_) => const CellDto(stitch: KnitStitch.knit)),
            repeats: const [],
          ),
        ),
      ),
      notes: '',
      sections: const [],
      pieces: const [],
    );

void main() {
  group('the wire carries the place and the location', () {
    test('a weaving finding becomes a DraftIssue with its code, words and cell', () {
      final i = DraftRepository.issueFromDto(const ValidationIssueDto(
        code: 'weave.treadle_untied',
        severity: SeverityKind.error,
        message: 'pick 5 presses treadle 9 which has no tie-up',
        place: 'Pick 5, treadle 9',
        location:
            WeaveLocationDto(kind: WeaveLocationKind.treadling, pick: 5, lastPick: 5, treadle: 9),
      ));
      expect(i.code, 'weave.treadle_untied');
      expect(i.place, 'Pick 5, treadle 9');
      expect(i.location,
          const DraftPlace(kind: DraftPlaceKind.treadling, pick: 5, lastPick: 5, treadle: 9));
      expect(i.isError, isTrue);
      final whole = DraftRepository.issueFromDto(const ValidationIssueDto(
          code: 'weave.weft_color_count', severity: SeverityKind.unsupported, message: 'x'));
      expect(
          (whole.place, whole.location, whole.severity), (null, null, IssueSeverity.unsupported));
    });

    test('a readiness report keeps every check, level, place and sentence', () {
      final r = ReadinessRepository.fromDto(const ReadinessDto(
        verdict: ReadinessVerdictKind.notReady,
        checked: [ReadinessCheckKind.draft, ReadinessCheckKind.loom],
        items: [
          ReadinessItemDto(
              check: ReadinessCheckKind.draft,
              code: 'weave.treadle_untied',
              severity: SeverityKind.error,
              place: 'Pick 5, treadle 9',
              message: 'Pick 5 presses treadle 9 which has no tie-up',
              omitted: 0),
          ReadinessItemDto(
              check: ReadinessCheckKind.loom,
              code: 'loom.reed_no_sett',
              severity: SeverityKind.unsupported,
              message: 'The sett is not known, so no reed was chosen.',
              remediation: 'Enter a sett for this draft in Loom for this draft.',
              omitted: 0),
          ReadinessItemDto(
              check: ReadinessCheckKind.draft,
              code: 'weave.treadle_untied',
              severity: SeverityKind.error,
              message: '300 more like this are not listed: Ply lists the first 200 of each kind.',
              omitted: 300),
        ],
      ));
      expect(r.verdict, ReadinessVerdict.notReady);
      expect(r.checked, [ReadinessCheck.draft, ReadinessCheck.loom]);
      expect(r.checkedWords, 'the draft and the loom chosen for it');
      expect(
          r.errors.first.text, 'Pick 5, treadle 9: Pick 5 presses treadle 9 which has no tie-up');
      expect(r.unsupported.single.text, 'The sett is not known, so no reed was chosen.');
      expect(r.unsupported.single.remediation, startsWith('Enter a sett'));
      expect(r.errorCount, 301, reason: 'the listed error and the 300 counted');
      for (final k in SeverityKind.values) {
        expect(ReadinessRepository.level(k).name, k.name, reason: 'one vocabulary');
      }
    });
  });

  group('a weaving place on the draft', () {
    final layout = DraftLayout(ends: 8, picks: 6, shafts: 4, treadles: 4, hasTieup: true, cell: 10);
    Rect at(Rect region, RegionGeom g, int col, int row) =>
        g.rectFor(col, row).shift(region.topLeft);

    test('each cell kind is its cell; a number past the grid is clamped to its edge', () {
      expect(
          draftPlaceRect(
              layout, const DraftPlace(kind: DraftPlaceKind.threading, end: 3, shaft: 2)),
          at(layout.threadingRect, layout.threading, 3, 2));
      expect(
          draftPlaceRect(
              layout, const DraftPlace(kind: DraftPlaceKind.threading, end: 3, shaft: 9)),
          at(layout.threadingRect, layout.threading, 3, 4),
          reason: 'a dangling shaft shows the top row of its end');
      expect(
          draftPlaceRect(
              layout, const DraftPlace(kind: DraftPlaceKind.tieUp, treadle: 1, shaft: 5)),
          at(layout.tieupRect, layout.tieup, 1, 4));
      expect(
          draftPlaceRect(
              layout, const DraftPlace(kind: DraftPlaceKind.treadling, pick: 3, treadle: 9)),
          at(layout.rightRect, layout.right, 4, 2),
          reason: 'pick 3 is right-band row 2 (0-based); treadle 9 clamps to the last column');
      expect(
          draftPlaceRect(
              layout, const DraftPlace(kind: DraftPlaceKind.warpColor, end: 8, color: 5)),
          at(layout.warpColorRect, layout.warpColor, 8, 0));
      expect(
          draftPlaceRect(
              layout, const DraftPlace(kind: DraftPlaceKind.weftColor, pick: 6, color: 4)),
          at(layout.weftColorRect, layout.weftColor, 1, 5));
    });

    test('picks are their rows across the treadling; a shaft is its threading row', () {
      final picks = draftPlaceRect(
          layout, const DraftPlace(kind: DraftPlaceKind.picks, pick: 2, lastPick: 4))!;
      expect(
          picks,
          at(layout.rightRect, layout.right, 1, 1)
              .expandToInclude(at(layout.rightRect, layout.right, 4, 3)));
      final shaft = draftPlaceRect(layout, const DraftPlace(kind: DraftPlaceKind.shaft, shaft: 2))!;
      expect(shaft.width, layout.threadingRect.width);
      expect(shaft.height, 10);
      expect(draftPlaceRect(layout, const DraftPlace(kind: DraftPlaceKind.shuttle, shuttle: 12)),
          isNull,
          reason: 'a shuttle has no cell');
      final liftplan =
          DraftLayout(ends: 8, picks: 6, shafts: 4, treadles: 0, hasTieup: false, cell: 10);
      expect(
          draftPlaceRect(
              liftplan, const DraftPlace(kind: DraftPlaceKind.tieUp, treadle: 1, shaft: 1)),
          isNull,
          reason: 'a lift plan has no tie-up');
    });
  });

  group('the weaving problem list', () {
    Future<ProviderContainer> pump(WidgetTester tester, List<DraftIssue> issues) async {
      final c =
          ProviderContainer(overrides: [repositoryProvider.overrideWithValue(_Drafts(issues))]);
      addTearDown(c.dispose);
      c.read(editorIssuesExpandedProvider.notifier).state = true;
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(home: Scaffold(body: Column(children: [ValidationPanel()]))),
      ));
      await tester.pump();
      await tester.pump();
      return c;
    }

    testWidgets('each finding says where it is, and Show asks the draft to go there',
        (tester) async {
      const place = DraftPlace(kind: DraftPlaceKind.treadling, pick: 5, lastPick: 5, treadle: 9);
      final c = await pump(tester, const [
        DraftIssue(
            severity: IssueSeverity.error,
            code: 'weave.treadle_untied',
            message: 'pick 5 presses treadle 9 which has no tie-up',
            place: 'Pick 5, treadle 9',
            location: place),
        DraftIssue(
            severity: IssueSeverity.error,
            code: 'weave.shuttle_start_range',
            message: 'shuttle 12 has a starting side but shuttles are numbered 1..=8',
            place: 'Shuttle 12',
            location: DraftPlace(kind: DraftPlaceKind.shuttle, shuttle: 12)),
        DraftIssue(severity: IssueSeverity.warning, message: 'a whole-draft warning'),
      ]);
      expect(find.text('Pick 5, treadle 9'), findsOneWidget);
      expect(find.text('Shuttle 12'), findsOneWidget);
      expect(find.text('Show'), findsOneWidget, reason: 'a shuttle has no cell to show');
      expect(
          find.bySemanticsLabel('Error, Pick 5, treadle 9: pick 5 presses treadle 9 which has no '
              'tie-up'),
          findsOneWidget);
      await tester.tap(find.text('Show'));
      await tester.pump();
      expect(c.read(draftFocusProvider)!.place, place);
      final first = c.read(draftFocusProvider)!.serial;
      await tester.tap(find.text('Show'));
      await tester.pump();
      expect(c.read(draftFocusProvider)!.serial, first + 1, reason: 'asking twice shows twice');
    });
  });

  testWidgets('the weaving draft outlines a shown place until the next touch', (tester) async {
    final c = await pumpEditor(tester, FakeRepo());
    expect(find.byKey(const ValueKey('draft-focus')), findsNothing);
    c.read(draftFocusProvider.notifier).state =
        const DraftFocus(DraftPlace(kind: DraftPlaceKind.threading, end: 1, shaft: 1), 1);
    await letAsyncSettle(tester);
    expect(find.byKey(const ValueKey('draft-focus')), findsOneWidget);
    // A place the view cannot show outlines nothing.
    c.read(draftFocusProvider.notifier).state =
        const DraftFocus(DraftPlace(kind: DraftPlaceKind.shuttle, shuttle: 3), 2);
    await letAsyncSettle(tester);
    expect(find.byKey(const ValueKey('draft-focus')), findsNothing);
  });

  group('the knitting problem list and chart', () {
    Future<ProviderContainer> pump(WidgetTester tester, _Knits repo) async {
      final c = ProviderContainer(overrides: [knitRepositoryProvider.overrideWithValue(repo)]);
      addTearDown(c.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: MaterialApp(home: KnitEditorScreen(initialPattern: _pattern())),
      ));
      await tester.pumpAndSettle();
      return c;
    }

    testWidgets('Show selects the cell or the row in the chart', (tester) async {
      final c = await pump(
        tester,
        _Knits(issues: const [
          KnitIssueDto(
            code: 'unknown-stitch',
            severity: SeverityKind.error,
            message: 'row 2 col 3 references stitch #99 which is not in the legend',
            place: 'Row 2, column 3',
            location: KnitLocationDto(kind: KnitLocationKind.cell, row: 1, column: 1),
          ),
          KnitIssueDto(
            code: 'stitch-count-mismatch',
            severity: SeverityKind.warning,
            message: 'row 3 consumes 4 stitches but row 2 produced 5',
            place: 'Row 3',
            location: KnitLocationDto(kind: KnitLocationKind.row, row: 2),
          ),
        ]),
      );
      await tester.tap(find.text('1 error, 1 warning'));
      await tester.pumpAndSettle();
      expect(find.text('Row 2, column 3'), findsOneWidget);
      expect(find.text('Row 3'), findsOneWidget);
      await tester.tap(find.text('Show').first);
      await tester.pumpAndSettle();
      expect(c.read(knitToolProvider), KnitTool.paint, reason: 'the tool is left as it was');
      expect(c.read(knitSelectionProvider), const KnitSelection(1, 1, 1, 1));
      expect(c.read(knitRevealProvider)!.row, 1, reason: 'and the chart is asked to show it');
      await tester.tap(find.text('Show').last);
      await tester.pumpAndSettle();
      expect(c.read(knitSelectionProvider), const KnitSelection(2, 0, 2, 3),
          reason: 'the whole row');
    });

    testWidgets('a chart that cannot be drawn says so, with the reason', (tester) async {
      await pump(tester, _Knits(failRender: true));
      expect(
          find.textContaining('The chart could not be drawn: Bad state: the chart is too large to '
              'draw.'),
          findsOneWidget);
    });
  });

  group('the knitting chart and sections go to the place', () {
    Future<ProviderContainer> pump(WidgetTester tester, _Knits repo, KnitPatternDto p) async {
      final c = ProviderContainer(overrides: [knitRepositoryProvider.overrideWithValue(repo)]);
      addTearDown(c.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: MaterialApp(home: KnitEditorScreen(initialPattern: p)),
      ));
      await tester.pumpAndSettle();
      return c;
    }

    testWidgets('Show brings a far row into view and the chart still scrolls', (tester) async {
      final c = await pump(
        tester,
        _Knits(issues: const [
          KnitIssueDto(
            code: 'unknown-stitch',
            severity: SeverityKind.error,
            message: 'row 6 col 2 references stitch #99 which is not in the legend',
            place: 'Row 6, chart column 3',
            location: KnitLocationDto(kind: KnitLocationKind.cell, row: 5, column: 1),
          ),
        ]),
        _pattern(rows: 120),
      );
      final chart = find.byType(KnitChartView);
      final vertical = tester.state<ScrollableState>(
          find.descendant(of: chart, matching: find.byType(Scrollable)).first);
      expect(vertical.position.pixels, 0, reason: 'opens at the top: the highest rows');
      await tester.tap(find.text('row 6 col 2 references stitch #99 which is not in the legend'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Show'));
      await tester.pumpAndSettle();
      expect(c.read(knitToolProvider), KnitTool.paint, reason: 'the tool is left as it was');
      final view = tester.getRect(chart);
      final cellRect = tester.getRect(find.byKey(const ValueKey('knit-selection')));
      expect(view.contains(cellRect.center), isTrue,
          reason: 'row 6 is on screen: $cellRect in $view');
      // The chart was not frozen: a drag still scrolls it.
      final at = vertical.position.pixels;
      expect(at, greaterThan(0));
      await tester.drag(chart, const Offset(0, 200));
      await tester.pumpAndSettle();
      expect(vertical.position.pixels, lessThan(at));
    });

    testWidgets('Show on a section finding opens the Sections screen at its step, outlined',
        (tester) async {
      final p = patternFromPlyknit(
          File('../fixtures/knitting/readiness/mixed-problems.plyknit').readAsStringSync());
      await pump(
        tester,
        _Knits(issues: const [
          KnitIssueDto(
            code: 'section-step',
            severity: SeverityKind.error,
            message: 'Brim, step 3: binds off 30 stitches, but only 22 stitches are left',
            place: 'Brim, step 3',
            location: KnitLocationDto(kind: KnitLocationKind.step, section: 0, step: 2),
          ),
        ]),
        p,
      );
      await tester.tap(find.text('Brim, step 3: binds off 30 stitches, but only 22 stitches are '
          'left'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Show'));
      await tester.pumpAndSettle();
      expect(find.byType(KnitSectionsScreen), findsOneWidget);
      final step = find.byKey(const Key('knit-step-0-2-step-3'));
      expect(step, findsOneWidget);
      final outline = find.ancestor(of: step, matching: find.byType(DecoratedBox)).first;
      final box = tester.widget<DecoratedBox>(outline).decoration as BoxDecoration;
      expect(box.border, isNotNull, reason: 'the step is outlined');
      expect(find.byKey(const Key('knit-step-0-1-step-2')), findsOneWidget);
      final other = find.ancestor(
          of: find.byKey(const Key('knit-step-0-1-step-2')), matching: find.byType(DecoratedBox));
      expect(
          tester.widgetList<DecoratedBox>(other).any((d) =>
              d.decoration is BoxDecoration && (d.decoration as BoxDecoration).border != null),
          isFalse,
          reason: 'only the finding\'s step');
    });

    testWidgets('a chart the engine cannot draw says it is too large', (tester) async {
      await pump(tester, _Knits(empty: true), _pattern());
      expect(
          find.textContaining('The chart could not be drawn: it is too large to draw at this '
              'zoom'),
          findsOneWidget);
      expect(find.textContaining('..'), findsNothing, reason: 'no doubled full stop');
    });
  });

  testWidgets('the weaving outline follows a zoom', (tester) async {
    final c = await pumpEditor(tester, FakeRepo());
    c.read(draftFocusProvider.notifier).state =
        const DraftFocus(DraftPlace(kind: DraftPlaceKind.threading, end: 1, shaft: 1), 1);
    await letAsyncSettle(tester);
    final before = tester.getSize(find.byKey(const ValueKey('draft-focus')));
    c.read(zoomUserSetProvider.notifier).state = true;
    c.read(zoomCellProvider.notifier).state = c.read(zoomCellProvider) * 2;
    await letAsyncSettle(tester);
    final after = tester.getSize(find.byKey(const ValueKey('draft-focus')));
    expect(after.width, greaterThan(before.width), reason: 'drawn over the same cell, now larger');
  });

  group('the report counts and the library placeholder', () {
    test('counts include what is counted but not listed; app items merge by severity', () {
      const engine = ReadinessReport(checked: [
        ReadinessCheck.draft
      ], items: [
        ReadinessItem(
            check: ReadinessCheck.draft, code: 'a', level: ReadinessLevel.error, message: 'one'),
        ReadinessItem(
            check: ReadinessCheck.draft,
            code: 'a',
            level: ReadinessLevel.error,
            message: '9 more like this are not listed',
            omitted: 9),
        ReadinessItem(
            check: ReadinessCheck.draft, code: 'n', level: ReadinessLevel.info, message: 'note'),
      ]);
      expect(engine.errorCount, 10);
      final merged = engine.withItems(const [
        ReadinessItem(
            check: ReadinessCheck.loom,
            code: 'loom.not_available',
            level: ReadinessLevel.unsupported,
            message: 'gone'),
      ], checks: const [
        ReadinessCheck.loom
      ]);
      expect([for (final i in merged.items) i.code], ['a', 'a', 'loom.not_available', 'n']);
      expect(merged.checked, [ReadinessCheck.draft, ReadinessCheck.loom]);
      expect(merged.verdict, ReadinessVerdict.notReady);
    });

    test('a draft with no ends or no picks has nothing to draw', () {
      const head = '[WEAVING]\nShafts=4\nTreadles=4\n';
      expect(DraftRepository.wifHasCloth('$head[THREADING]\n1=1\n[TREADLING]\n1=1\n'), isTrue);
      expect(DraftRepository.wifHasCloth('$head[THREADING]\n1=1\n'), isFalse, reason: 'no picks');
      expect(DraftRepository.wifHasCloth('$head[TREADLING]\n1=1\n'), isFalse, reason: 'no ends');
      expect(
          DraftRepository.wifHasCloth(
              '$head[WARP]\nThreads=2\n[WEFT]\nThreads=3\n[THREADING]\n[TREADLING]\n'),
          isTrue,
          reason: 'sized by Threads');
      expect(DraftRepository.wifHasCloth('$head[THREADING]\n1=1\n[TREADLING]\n[LIFTPLAN]\n2=1\n'),
          isTrue,
          reason: 'a lift plan when the treadling has none');
    });
  });
}
