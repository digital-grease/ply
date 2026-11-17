import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/models/draft_doc.dart' show MeasureUnit;
import 'package:ply/src/models/nalbind_project.dart';
import 'package:ply/src/models/nalbind_recipe_view.dart';
import 'package:ply/src/print/nalbind_print.dart';
import 'package:ply/src/print/pdf_builder.dart';
import 'package:ply/src/print/print_document.dart';
import 'package:ply/src/print/print_layout.dart';
import 'package:ply/src/rust/nalbind_recipe_dto.dart';
import 'package:ply/src/screens/nalbind_follow_screen.dart';
import 'package:ply/src/screens/nalbind_recipe_screen.dart';
import 'package:ply/src/state/nalbind_providers.dart';

import 'nalbind_recipe_test_support.dart';
import 'print/print_test_support.dart';

// The nalbinding recipe acceptance fixtures (fixtures/nalbinding/recipes/, shared with the Rust
// tests) as the app shows and prints them, with each fixture's hand-derived oracle standing in for
// the engine: the PDF prints the recipe in working order (each step's written instruction, stitch,
// count, target, notes, caution and whether Ply checked it) and then every finding in its place;
// the recipe screen lists every finding; the follow view opens at the first step not done.

/// Stands in for the engine with fixture [name]'s oracle.
class OracleRecipeRepo extends RecipeFakeRepo {
  OracleRecipeRepo(this.name) {
    report = (_, __) => oracleReport(name);
  }
  final String name;
}

Future<PrintDocument> _document(String name, {bool box = true}) async {
  final project = recipeFixture(name);
  final source = await gatherNalbindPrint(OracleRecipeRepo(name),
      project: project, now: DateTime(2026, 11, 16));
  return buildNalbindPrintDocument(source, withProblemsBox: box);
}

PrintSection? _section(PrintDocument d, String heading) =>
    d.sections.where((s) => s.heading == heading).firstOrNull;

Future<void> _pump(WidgetTester tester, RecipeFakeRepo repo, Widget screen) async {
  tester.view.physicalSize = const Size(1200, 12000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    overrides: [nalbindRepositoryProvider.overrideWithValue(repo)],
    child: MaterialApp(home: screen),
  ));
  await tester.pumpAndSettle();
}

void main() {
  for (final name in kRecipeFixtures) {
    test('$name: the PDF prints every step in order and every finding in its place', () async {
      final oracle = recipeOracle(name);
      final project = recipeFixture(name);
      final d = await _document(name);
      final recipe = _section(d, 'Recipe')!;
      final all = recipe.blocks.expand((b) => b.allText).join('\n');
      expect(all, contains('does not simulate the fabric'));
      for (final f in oracle['fit'] as List) {
        expect(all, contains(f as String), reason: 'fit');
      }
      final lines = recipe.blocks.whereType<PrintLines>().expand((b) => b.lines).toList();
      final steps = lines.where((l) => l.label?.startsWith('Step ') ?? false).toList();
      final segments = (oracle['segments'] as List).cast<Map<String, dynamic>>();
      expect(steps.length, segments.length, reason: 'one printed step per segment, in order');
      final report = oracleReport(name);
      for (final (i, e) in segments.indexed) {
        expect(steps[i].text, e['written'], reason: '$name step ${i + 1}');
        expect(steps[i].label, recipeStepLabel(project.recipe!.segments[i], i, segments.length));
        expect(steps[i].flagged,
            report.issuesAt(i).any((x) => x.severity == RecipeSeverityKind.error));
      }
      final facts = recipe.blocks.whereType<PrintFacts>().toList();
      expect(facts.length, segments.length);
      for (final (i, f) in facts.indexed) {
        final byLabel = {for (final x in f.facts) x.label: x.value};
        expect(byLabel['Checked'], recipeStatusText(report, i));
        final seg = project.recipe!.segments[i];
        if (seg.notes.trim().isNotEmpty) expect(byLabel['Notes'], seg.notes.trim());
        if (seg.caution.trim().isNotEmpty) expect(byLabel['Watch out for'], seg.caution.trim());
        final target = segments[i]['target'] as String?;
        expect(byLabel['Aim for'], target);
        final count = recipeCountText(report.segments[i]);
        expect(byLabel['Stitches after'], count);
        expect(byLabel['Done'], project.recipe!.done.contains(seg.id) ? 'Ticked done' : null);
      }

      final findings = _section(d, 'Recipe findings')!.blocks.single as PrintIssues;
      final issues = (oracle['issues'] as List).cast<Map<String, dynamic>>();
      expect(findings.issues.length, issues.length);
      if (issues.isEmpty) expect(findings.emptyText, 'Ply found no problems in the recipe.');
      for (final i in issues) {
        final text = i['text'] as String;
        expect(findings.issues.any((p) => text == '${p.where}: ${p.message}' || text == p.message),
            isTrue,
            reason: 'printed in its place: $text');
      }
    });
  }

  test('the mitten prints in two parts, named by their starts, with no problems box', () async {
    final d = await _document('mitten-cuff-up');
    expect(d.problemsBox, isNull);
    final parts = _section(d, 'Recipe')!
        .blocks
        .whereType<PrintParagraph>()
        .where((p) => p.style == PrintTextStyle.strong)
        .map((p) => p.text);
    expect(parts, ['Part 1: Cuff start', 'Part 2: Thumb']);
  });

  test('recipe errors join the problems box', () async {
    final d = await _document('recipe-problems');
    final box = d.problemsBox!;
    final errors = (recipeOracle('recipe-problems')['issues'] as List)
        .cast<Map<String, dynamic>>()
        .where((i) => i['severity'] == 'error')
        .toList();
    expect(
        box.intro,
        'Ply found ${errors.length} errors in the recipe, so some steps may not be '
        'what you meant.');
    expect(box.lines, [for (final e in errors) 'Recipe, ${e['text']}']);
    expect((await _document('recipe-problems', box: false)).problemsBox, isNull);
  });

  test('a recipe too large to check prints every step as not checked, and says why', () async {
    final project = recipeFixture('mitten-cuff-up');
    const why = 'The recipe is too large to check.';
    final repo = RecipeFakeRepo()..report = (_, __) => tooLargeReport(text: why);
    final d = buildNalbindPrintDocument(
        await gatherNalbindPrint(repo, project: project, now: DateTime(2026, 11, 16)),
        withProblemsBox: true);
    final recipe = _section(d, 'Recipe')!;
    final steps = recipe.blocks
        .whereType<PrintLines>()
        .expand((b) => b.lines)
        .where((l) => l.label?.startsWith('Step ') ?? false)
        .toList();
    expect(steps.length, project.recipe!.segments.length);
    expect(steps.every((l) => l.text == kRecipeTooLargeStep), isTrue, reason: 'never empty');
    final facts = recipe.blocks.whereType<PrintFacts>().first.facts;
    expect(facts.firstWhere((f) => f.label == 'Checked').value,
        'Not checked: the recipe is too large to check (see the problem at the top)');
    final findings = _section(d, 'Recipe findings')!.blocks.single as PrintIssues;
    expect(findings.issues.single.message, why);
    expect(d.problemsBox!.lines, ['Recipe, $why']);
  });

  testWidgets('the follow view shows what is wrong with the recipe as a whole', (tester) async {
    final project = recipeFixture('recipe-problems');
    await _pump(
      tester,
      OracleRecipeRepo('recipe-problems'),
      NalbindFollowScreen(
        recipe: project.recipe!,
        projectNotation: project.notation,
        projectStitchName: project.stitchName,
        onTick: (_, __) async => null,
      ),
    );
    expect(find.byKey(const ValueKey('follow-recipe-issues')), findsOneWidget);
    expect(
        find.text('Problem: The project\'s stitch notation has 1 problem, and steps 1 and 8 are '
            'worked in it: see the project\'s Stitch field.'),
        findsOneWidget);
  });

  test('a note-only project prints exactly as before: no recipe sections', () async {
    final note = recipeFixture('mitten-cuff-up').withRecipe(null);
    final repo = OracleRecipeRepo('mitten-cuff-up');
    final d = buildNalbindPrintDocument(
        await gatherNalbindPrint(repo, project: note, now: DateTime(2026, 11, 16)),
        withProblemsBox: true);
    expect(d.sections.map((s) => s.heading), ['Stitch', 'Notation findings', 'Notes', 'Photos']);
    expect(repo.checked, isEmpty, reason: 'nothing to check');
  });

  test('the whole mitten PDF renders, with no em dashes', () async {
    final pdf = PdfReadBack(await buildPrintPdf(
      await _document('mitten-cuff-up'),
      page: PrintPageSetup.forUnit(MeasureUnit.centimeters),
      fonts: testFonts(),
      compress: false,
    ));
    for (final t in [
      'Cuff-up mittens',
      'Recipe',
      'Part 2: Thumb',
      'Pick up 18 loops around the opening in step 4 (Thumb opening) to start this part.',
      'Checked by Ply: no problems found',
      'Do not twist the chain when you join it.',
      'Hand around the knuckles: 19 cm',
      'Ply found no problems in the recipe.',
    ]) {
      expect(pdf.text, contains(t));
    }
    expect(pdf.text, isNot(contains('\u2014')));
  });

  testWidgets('the recipe screen lists every finding of the problems fixture', (tester) async {
    final project = recipeFixture('recipe-problems');
    final report = oracleReport('recipe-problems');
    await _pump(
      tester,
      OracleRecipeRepo('recipe-problems'),
      NalbindRecipeScreen(
        initial: project.recipe!,
        projectNotation: project.notation,
        projectStitchName: project.stitchName,
        onChanged: (_) {},
        onTick: (_, __) async => null,
      ),
    );
    for (final i in report.issues) {
      final word = switch (i.severity) {
        RecipeSeverityKind.error => 'Problem',
        RecipeSeverityKind.warning => 'Warning',
        RecipeSeverityKind.info => 'Note',
      };
      final shown = i.segment == null && i.fit == null ? i.text : i.message;
      final f = find.text('$word: $shown', skipOffstage: false);
      expect(f, findsWidgets, reason: shown);
    }
    expect(find.text('Hand around: not measured yet', skipOffstage: false), findsOneWidget);
  });

  testWidgets('the follow view opens the hat at its first step not done', (tester) async {
    final project = recipeFixture('hat-centre-start');
    await _pump(
      tester,
      OracleRecipeRepo('hat-centre-start'),
      NalbindFollowScreen(
        recipe: project.recipe!,
        projectNotation: project.notation,
        projectStitchName: project.stitchName,
        onTick: (_, __) async => null,
      ),
    );
    expect(find.text('2 of 7 steps done'), findsOneWidget);
    expect(find.text('Step 3 of 7, Part 1, Shaping'), findsOneWidget);
    expect(
        find.text('Increase 4 stitches in each round, working two stitches into the same loop of '
            'the previous round, until it measures 17 cm (across the crown).'),
        findsOneWidget);
    expect(find.text("Mammen, UOO/UUOO F2 (the project's stitch)"), findsOneWidget);
    expect(find.text('Not stated in the recipe'), findsOneWidget);
    expect(find.textContaining('If the edge ruffles'), findsOneWidget);
    expect(find.textContaining('this step does not say how many stitches it adds'), findsOneWidget);
    // The care note is free text: not checked, and not a step of the work.
    await tester.tap(find.byKey(const ValueKey('follow-go-to')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Step 7: Care').last);
    await tester.pumpAndSettle();
    expect(find.text('Free text: Ply does not read or check it'), findsOneWidget);
    expect(find.text('Step 7 of 7, Note'), findsOneWidget);
  });

  test('every fixture reads back as the project the oracle was derived from', () {
    for (final name in kRecipeFixtures) {
      final p = recipeFixture(name);
      expect(p.notation, recipeOracle(name)['project_notation'], reason: name);
      expect(p, NalbindProject.decode(recipeFixtureText(name, 'plynal')));
    }
  });
}
