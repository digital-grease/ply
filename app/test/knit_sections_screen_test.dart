import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/knit_repository.dart';
import 'package:ply/src/models/draft_meta.dart';
import 'package:ply/src/models/knit_sections.dart';
import 'package:ply/src/rust/knit_dto.dart';
import 'package:ply/src/screens/knit_editor_screen.dart';
import 'package:ply/src/screens/knit_sections_screen.dart';
import 'package:ply/src/state/knit_editor_providers.dart';

import 'knit_sections_test_support.dart';

// Host coverage for the Sections screen: the explanation when a pattern has none, adding and
// editing sections and steps through the real forms (edits land in the knit editor's state and
// undo history), each step showing the engine ledger's words and count with its problems beneath,
// and the knit editor's More menu reaching the screen. The engine is stood in for by a fake that
// returns a fixture's hand-derived construction.

class FakeSectionsRepo extends KnitRepository {
  FakeSectionsRepo({this.canned});

  /// What the engine would return; null = nothing worked out yet (an empty construction).
  KnitConstructionDto? canned;
  int calls = 0;

  @override
  Future<KnitConstructionDto> construction(KnitPatternDto pattern) async {
    calls++;
    return canned ?? const KnitConstructionDto(lines: [], issues: []);
  }

  @override
  Future<List<KnitIssueDto>> validate(KnitPatternDto pattern) async => const [];

  @override
  Future<KnitPatternDto> blank() async =>
      patternFromPlyknit(sectionFixtureText('shoulder-short-rows-flat', 'plyknit'));

  @override
  Future<ui.Image> render(KnitPatternDto pattern, {required int cellPx}) {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(Uint8List.fromList(const [0, 0, 0, 255]), 1, 1,
        ui.PixelFormat.rgba8888, completer.complete);
    return completer.future;
  }
}

class _SavingRepo extends FakeSectionsRepo {
  KnitPatternDto? saved;

  @override
  Future<String> saveKnit({
    required KnitPatternDto pattern,
    required DraftMeta meta,
    String? id,
  }) async {
    saved = pattern;
    return id ?? 'new-id';
  }
}

Future<ProviderContainer> _pump(WidgetTester tester, KnitPatternDto pattern,
    {KnitConstructionDto? construction}) async {
  final repo = FakeSectionsRepo(canned: construction);
  final container = ProviderContainer(overrides: [knitRepositoryProvider.overrideWithValue(repo)]);
  addTearDown(container.dispose);
  container.read(knitEditorProvider.notifier).load(pattern);
  await tester.binding.setSurfaceSize(const Size(500, 5000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: const MaterialApp(home: KnitSectionsScreen()),
  ));
  await tester.pumpAndSettle();
  return container;
}

KnitPatternDto _noSections() {
  final p = patternFromPlyknit(sectionFixtureText('shoulder-short-rows-flat', 'plyknit'));
  return KnitPatternDto(
    name: p.name,
    construction: p.construction,
    firstRowSide: p.firstRowSide,
    castOn: p.castOn,
    gauge: p.gauge,
    palette: p.palette,
    legend: p.legend,
    chart: p.chart,
    notes: p.notes,
    sections: const [],
  );
}

void main() {
  testWidgets('a pattern without sections explains them, and a first section can be added',
      (tester) async {
    final c = await _pump(tester, _noSections());
    expect(find.text('Build the pattern in sections'), findsOneWidget);
    expect(find.textContaining('You do not need sections.'), findsOneWidget);

    await tester.tap(find.byKey(const Key('knit-add-first-section')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Back');
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    final sections = c.read(knitEditorProvider).pattern.sections;
    expect([for (final s in sections) (s.id, s.name)], [('section-1', 'Back')]);
    expect(find.text('1. Back'), findsOneWidget);
    expect(find.text('No steps yet.'), findsOneWidget);
    expect(c.read(knitEditorProvider).canUndo, isTrue, reason: 'one undo entry');
  });

  testWidgets('every step shows the ledger words and count, with its problems beneath',
      (tester) async {
    final p = patternFromPlyknit(sectionFixtureText('shoulder-short-rows-flat', 'plyknit'));
    final construction = oracleConstruction(p, sectionOracle('shoulder-short-rows-flat'));
    await _pump(tester, p, construction: construction);

    expect(find.text('1. Body'), findsOneWidget);
    expect(find.text('2. Shoulder'), findsOneWidget);
    expect(
        find.text('The stitches left at the end of each right-side row become the low end of '
            'the slope.'),
        findsOneWidget,
        reason: 'the section notes');
    expect(find.text('Row 1 (RS): k24'), findsOneWidget, reason: 'a chart row line');
    expect(find.text('Short row 1 (RS): knit to last 6 sts, wrap and turn.'), findsOneWidget);
    expect(find.text('24 sts on the needle, 6 waiting past a turn'), findsNWidgets(2));
    expect(find.text('Next row (RS): knit to end, working each wrap together with its stitch.'),
        findsOneWidget);
    expect(find.text('Place all 24 sts on a holder (shoulder).'), findsOneWidget);
    expect(find.text('0 sts on the needle; 24 on hold'), findsOneWidget);
    // The hold step's problem sits under it, without the place it is already shown at.
    final holdTile = find.byKey(const Key('knit-step-1-7-step-10'));
    expect(
        find.descendant(
            of: holdTile,
            matching: find.text('24 stitches are still on hold (shoulder) at the end of the '
                'pattern; no step returns them to the needle')),
        findsOneWidget);
  });

  testWidgets('steps that cannot be counted say so, and pattern-wide problems come first',
      (tester) async {
    final p = patternFromPlyknit(sectionFixtureText('ledger-problems-flat', 'plyknit'));
    final construction = oracleConstruction(p, sectionOracle('ledger-problems-flat'));
    await _pump(tester, p, construction: construction);
    expect(find.text('not counted: see the problems'), findsNWidgets(9));
    expect(find.text('stitch count unknown'), findsNWidgets(2));
    expect(find.text('Binds off 30 stitches, but only 16 stitches are left to work in this row'),
        findsOneWidget);
    expect(
        find.text('Chart row 1: works over 20 stitches, but 16 are on the needle, so this row '
            'and the rest of the step are not counted'),
        findsOneWidget);
    expect(
        find.text('Ends with short rows not yet worked across: 5 stitches are still waiting past '
            'a turn, and 1 wrap is not yet worked together with its stitch'),
        findsOneWidget,
        reason: 'a section problem under its heading');
    final general = find.text('Chart rows 2 to 3 are not worked in any section, so the written '
        'instructions leave them out');
    expect(general, findsOneWidget);
    expect(tester.getTopLeft(general).dy, lessThan(tester.getTopLeft(find.text('1. Problems')).dy));
  });

  testWidgets('adding, editing and deleting steps goes through the forms and the undo history',
      (tester) async {
    final c = await _pump(tester, _noSections());
    c.read(knitEditorProvider.notifier).addSection('Shoulder');
    await tester.pumpAndSettle();

    // Add a short row: the kind sheet, then its form with the defaults (wrap and turn, last 4).
    await tester.tap(find.byKey(const Key('knit-add-step-0-section-1')));
    await tester.pumpAndSettle();
    expect(find.text('Short row'), findsOneWidget);
    await tester.tap(find.byKey(const Key('knit-step-kind-shortRow')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('knit-step-count')), '6');
    await tester.tap(find.byKey(const Key('knit-step-save')));
    await tester.pumpAndSettle();
    var steps = c.read(knitEditorProvider).pattern.sections.single.steps;
    expect(
        steps.single.action,
        const KnitStepActionDto.shortRow(
            stitch: WorkStitchKind.knit,
            to: TurnAtDto.last(count: 6),
            method: TurnMethodKind.wrapAndTurn,
            resolveTurns: false));

    // Hold the rest of the row.
    await tester.tap(find.byKey(const Key('knit-add-step-0-section-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('knit-step-kind-hold')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('knit-step-save')));
    await tester.pump();
    expect(find.text('Give the group a name, so the step that returns it can say which.'),
        findsOneWidget,
        reason: 'a group needs a name');
    await tester.enterText(find.byKey(const Key('knit-step-name')), 'shoulder');
    await tester.tap(find.byKey(const Key('knit-step-save')));
    await tester.pumpAndSettle();
    steps = c.read(knitEditorProvider).pattern.sections.single.steps;
    expect(steps.map((s) => s.id), ['step-1', 'step-2']);
    expect(steps.last.action, const KnitStepActionDto.hold(name: 'shoulder'));

    // Edit the short row: the form opens on what it does.
    await tester.tap(find.descendant(
        of: find.byKey(const Key('knit-step-0-0-step-1')),
        matching: find.byTooltip('Step actions')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    expect(find.text('Edit step: Short row'), findsOneWidget);
    expect(
        tester.widget<TextField>(find.byKey(const Key('knit-step-count'))).controller!.text, '6');
    await tester.tap(find.text('German short row'));
    await tester.tap(find.byKey(const Key('knit-step-save')));
    await tester.pumpAndSettle();
    final edited = c.read(knitEditorProvider).pattern.sections.single.steps.first;
    expect(edited.id, 'step-1');
    expect((edited.action as KnitStepActionDto_ShortRow).method, TurnMethodKind.german);

    // Move the hold up, then delete the section and undo it from the snack bar.
    await tester.tap(find.descendant(
        of: find.byKey(const Key('knit-step-0-1-step-2')),
        matching: find.byTooltip('Step actions')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Move up'));
    await tester.pumpAndSettle();
    expect(c.read(knitEditorProvider).pattern.sections.single.steps.map((s) => s.id),
        ['step-2', 'step-1']);
    await tester.tap(find.byTooltip('Section actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete section'));
    await tester.pumpAndSettle();
    expect(c.read(knitEditorProvider).pattern.sections, isEmpty);
    expect(find.text('Deleted Shoulder.'), findsOneWidget);
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(c.read(knitEditorProvider).pattern.sections.single.steps, hasLength(2));
  });

  testWidgets('a file with repeated ids shows every step and edits the one chosen', (tester) async {
    const step = KnitStepDto(id: 'dup', action: KnitStepActionDto.castOn(count: 4));
    final p = _noSections();
    final dup = KnitPatternDto(
      name: p.name,
      construction: p.construction,
      firstRowSide: p.firstRowSide,
      castOn: p.castOn,
      gauge: p.gauge,
      palette: p.palette,
      legend: p.legend,
      chart: p.chart,
      notes: p.notes,
      sections: const [
        KnitSectionDto(id: 'x', name: 'A', notes: '', steps: [step, step]),
        KnitSectionDto(id: 'x', name: 'B', notes: '', steps: [step]),
      ],
    );
    final c = await _pump(tester, dup); // repeated keys would fail here in debug
    expect(find.text('1. A'), findsOneWidget);
    expect(find.text('2. B'), findsOneWidget);
    await tester.tap(find.descendant(
        of: find.byKey(const Key('knit-step-1-0-dup')), matching: find.byTooltip('Step actions')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete step'));
    await tester.pumpAndSettle();
    final sections = c.read(knitEditorProvider).pattern.sections;
    expect([for (final s in sections) s.steps.length], [2, 0],
        reason: 'B lost its step, A kept both');
  });

  testWidgets('Undo on the delete notice does nothing once something else has changed',
      (tester) async {
    final c = await _pump(tester, _noSections());
    final notifier = c.read(knitEditorProvider.notifier)
      ..addSection('A')
      ..addSection('B');
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Section actions').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete section'));
    await tester.pumpAndSettle();
    notifier.renameSectionAt(0, 'B2'); // a later edit
    await tester.pumpAndSettle();
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect([for (final s in c.read(knitEditorProvider).pattern.sections) s.name], ['B2'],
        reason: 'the rename was not undone, and A stays deleted');
  });

  testWidgets('a pattern with sections but no chart can still be saved', (tester) async {
    final repo = _SavingRepo();
    final p = patternFromPlyknit(sectionFixtureText('shoulder-short-rows-flat', 'plyknit'));
    final sectionsOnly = KnitPatternDto(
      name: p.name,
      construction: p.construction,
      firstRowSide: p.firstRowSide,
      castOn: p.castOn,
      gauge: p.gauge,
      palette: p.palette,
      legend: p.legend,
      chart: const ChartDto(width: 0, rows: []),
      notes: p.notes,
      sections: [p.sections[1]],
    );
    await tester.binding.setSurfaceSize(const Size(500, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ProviderScope(
      overrides: [knitRepositoryProvider.overrideWithValue(repo)],
      child: MaterialApp(home: KnitEditorScreen(initialPattern: sectionsOnly)),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Save'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Shoulder');
    await tester.tap(find.text('Save').last);
    await tester.pumpAndSettle();
    expect(repo.saved?.sections.single.name, 'Shoulder');
    expect(find.text('Add some rows and stitches before saving.'), findsNothing);
  });

  testWidgets('the knit editor opens the Sections screen from its More menu', (tester) async {
    final repo = FakeSectionsRepo();
    await tester.binding.setSurfaceSize(const Size(500, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ProviderScope(
      overrides: [knitRepositoryProvider.overrideWithValue(repo)],
      child: const MaterialApp(home: KnitEditorScreen()),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sections'));
    await tester.pumpAndSettle();
    expect(find.byType(KnitSectionsScreen), findsOneWidget);
    expect(find.text('1. Body'), findsOneWidget, reason: 'the editor pattern, with its sections');
    expect(repo.calls, greaterThan(0), reason: 'the ledger comes from the engine');
    expect(
        knitSectionTitle(
            patternFromPlyknit(sectionFixtureText('neckline-hold-flat', 'plyknit')), 1),
        'Divide for the neck');
  });
}
