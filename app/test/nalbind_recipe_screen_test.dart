import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/models/nalbind_project.dart';
import 'package:ply/src/models/nalbind_recipe.dart';
import 'package:ply/src/models/nalbind_recipe_view.dart' show kRecipeTooLargeStep;
import 'package:ply/src/rust/nalbind_recipe_dto.dart';
import 'package:ply/src/screens/nalbind_follow_screen.dart';
import 'package:ply/src/screens/nalbind_project_screen.dart';
import 'package:ply/src/screens/nalbind_recipe_screen.dart';
import 'package:ply/src/state/nalbind_providers.dart';
import 'package:ply/src/widgets/nalbind_segment_editor.dart';

import 'nalbind_recipe_test_support.dart';

// Host coverage for the nalbinding RECIPE in the app (ADR 0017): a note-only project looks and
// saves exactly as before; a recipe is built from the kind sheet and the small per-kind forms,
// edited, reordered, duplicated and deleted with Undo; the engine's report (a stand-in here) shows
// under each step; the project saves and reopens with it; the follow view walks it one step at a
// time and its ticks are written alone and never make the project unsaved.

const _leaveTitle = 'Leave without saving?';

Future<void> pumpProject(WidgetTester tester, RecipeFakeRepo repo, {String? openId}) async {
  tester.view.physicalSize = const Size(1200, 2600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  // A fresh tree each time (a second call in one test starts over, routes and all).
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(milliseconds: 10));
  final c = ProviderContainer(overrides: [nalbindRepositoryProvider.overrideWithValue(repo)]);
  addTearDown(c.dispose);
  await tester.pumpWidget(UncontrolledProviderScope(
    container: c,
    child: MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => NalbindProjectScreen(openId: openId)),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Finder _key(String k) => find.byKey(ValueKey(k));

/// Unmount the app and let auto-disposed providers finish, so no timer outlives the test.
Future<void> _end(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(milliseconds: 10));
}

Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

Future<void> _pick(WidgetTester tester, String key, String item) async {
  await _tap(tester, _key(key));
  await tester.tap(find.text(item).last);
  await tester.pumpAndSettle();
}

/// Add a step of [kind] through the sheet and its form: [fields] are text fields by key, [picks]
/// dropdowns by key (the item text to choose), applied in order.
Future<void> _addStep(
  WidgetTester tester,
  SegmentKind kind, {
  String? title,
  Map<String, String> picks = const {},
  Map<String, String> fields = const {},
}) async {
  await _tap(tester, _key('recipe-add-step'));
  await _tap(tester, _key('segment-kind-${kind.json}'));
  if (title != null) await tester.enterText(_key('segment-title'), title);
  for (final p in picks.entries) {
    await _pick(tester, p.key, p.value);
  }
  for (final f in fields.entries) {
    await tester.ensureVisible(_key(f.key));
    await tester.enterText(_key(f.key), f.value);
  }
  await tester.pump();
  await tester.tap(_key('segment-done'));
  await tester.pumpAndSettle();
}

Future<void> _stepMenu(WidgetTester tester, int index, String action) async {
  await _tap(tester, _key('recipe-step-menu-$index'));
  await tester.tap(find.text(action).last);
  await tester.pumpAndSettle();
}

Future<void> _back(WidgetTester tester) async {
  await tester.tap(find.byType(BackButton).last);
  await tester.pumpAndSettle();
}

List<String> _ids(RecipeFakeRepo repo, String id) =>
    [for (final s in repo.projects[id]!.recipe!.segments) s.id];

const _three = NalbindRecipe(segments: [
  RecipeSegment(id: 'segment-1', kind: SegmentKind.centreStart, title: 'Crown', stitches: 8),
  RecipeSegment(
      id: 'segment-2',
      kind: SegmentKind.rounds,
      title: 'Sides',
      extent: Extent.rounds(10),
      notes: 'Try it on.'),
  RecipeSegment(
      id: 'segment-3',
      kind: SegmentKind.finish,
      title: 'Brim edge',
      finishMethod: FinishMethod.taperEdge,
      caution: 'Taper slowly.'),
]);

const _hat = NalbindProject(
  name: 'Hat',
  notation: 'UO/UOO F1',
  stitchName: 'Oslo',
  notes: 'Grey wool.',
  recipe: _three,
);

void main() {
  testWidgets('a version 2 note-only project opens unchanged and saves without a recipe',
      (tester) async {
    final v2 = NalbindProject.decode(plynalMigration('schema-v2/mitten-notes.plynal'));
    final repo = RecipeFakeRepo(projects: {'p1': v2});
    await pumpProject(tester, repo, openId: 'p1');

    expect(find.widgetWithText(TextField, 'Grey mittens'), findsOneWidget);
    expect(find.text(v2.notes), findsOneWidget);
    expect(find.text('Add a recipe'), findsOneWidget);
    expect(find.text('Follow'), findsNothing);
    expect(repo.checked, isEmpty, reason: 'nothing is checked for a note-only project');

    // "Add a recipe" and straight back: still note-only, still clean.
    await _tap(tester, _key('project-recipe'));
    expect(find.byType(NalbindRecipeScreen), findsOneWidget);
    expect(find.textContaining('No steps yet.'), findsOneWidget);
    await _back(tester);
    expect(find.text('Add a recipe'), findsOneWidget);

    await tester.tap(find.byTooltip('Save'));
    await tester.pumpAndSettle();
    expect(repo.projects['p1'], v2, reason: 'saved exactly as it was');
    expect(repo.projects['p1']!.toJson().containsKey('recipe'), isFalse);

    await _back(tester);
    expect(find.text(_leaveTitle), findsNothing, reason: 'nothing unsaved');
    await _end(tester);
  });

  testWidgets('build a recipe from the kind sheet and forms, then save and reopen it',
      (tester) async {
    final repo = RecipeFakeRepo();
    await pumpProject(tester, repo);
    await tester.enterText(find.widgetWithText(TextField, 'Project name'), 'Mittens');
    await tester.enterText(find.widgetWithText(TextField, 'Hansen notation'), 'UO/UOO F1');
    await tester.pumpAndSettle();

    await _tap(tester, _key('project-recipe'));
    await _addStep(tester, SegmentKind.foundationChain,
        title: 'Cuff start',
        picks: {'segment-chain-join': ChainJoin.ring.label},
        fields: {'segment-stitches': '36'});
    expect(find.text('Written: Foundation chain (Cuff start)'), findsOneWidget);
    expect(find.text('Step 1 of 1: Start, Foundation chain (Cuff start)'), findsOneWidget);

    await _addStep(tester, SegmentKind.rounds, title: 'Hand', picks: {
      'segment-round-join': RoundJoin.spiral.label,
      'segment-reach': 'A number of rounds',
    }, fields: {
      'segment-reach-count': '12'
    });
    await _addStep(tester, SegmentKind.finish,
        title: 'Top', picks: {'segment-method': FinishMethod.closeTip.label});
    expect(find.text('Step 3 of 3: Finish, Finish (Top)'), findsOneWidget);
    expect(find.text('Checked by Ply: no problems found'), findsNWidgets(3));
    expect(find.text("Stitch: UO/UOO F1 (the project's stitch)"), findsNWidgets(2),
        reason: 'the chain and the rounds; a finish has no stitch');

    // The project's own Save, from the recipe screen.
    await tester.tap(_key('recipe-save'));
    await tester.pumpAndSettle();
    expect(repo.saves, 1);
    final saved = repo.projects['p1']!;
    final r = saved.recipe!;
    expect(r.segments.map((s) => s.id), ['segment-1', 'segment-2', 'segment-3']);
    expect(r.segments[0].stitches, 36);
    expect(r.segments[0].chainJoin, ChainJoin.ring);
    expect(r.segments[1].extent, const Extent.rounds(12));
    expect(r.segments[1].roundJoin, RoundJoin.spiral);
    expect(r.segments[2].finishMethod, FinishMethod.closeTip);

    await _back(tester); // recipe screen
    expect(find.text('3 steps, 0 done.'), findsOneWidget);
    await _back(tester); // project screen: saved, so no prompt
    expect(find.text(_leaveTitle), findsNothing);

    // Reopen: the same steps, in the same order.
    await pumpProject(tester, repo, openId: 'p1');
    expect(find.text('3 steps, 0 done.'), findsOneWidget);
    await _tap(tester, _key('project-recipe'));
    expect(find.text('Step 1 of 3: Start, Foundation chain (Cuff start)'), findsOneWidget);
    expect(find.text('Step 2 of 3: Body, Rounds (Hand)'), findsOneWidget);
    expect(find.text('Step 3 of 3: Finish, Finish (Top)'), findsOneWidget);
    await _end(tester);
  });

  testWidgets('reorder, duplicate, edit and delete with Undo', (tester) async {
    final repo = RecipeFakeRepo(projects: {'p1': _hat});
    await pumpProject(tester, repo, openId: 'p1');
    await _tap(tester, _key('project-recipe'));

    await _stepMenu(tester, 0, 'Move down');
    expect(find.text('Step 1 of 3: Body, Rounds (Sides)'), findsOneWidget);
    expect(find.text('Step 2 of 3: Start, Centre start (Crown)'), findsOneWidget);
    await _stepMenu(tester, 1, 'Move up');
    expect(find.text('Step 1 of 3: Start, Centre start (Crown)'), findsOneWidget);

    await _stepMenu(tester, 1, 'Duplicate');
    expect(find.text('Step 3 of 4: Body, Rounds (Sides)'), findsOneWidget);

    await _stepMenu(tester, 2, 'Delete');
    expect(find.text('Step 3 of 3: Finish, Finish (Brim edge)'), findsOneWidget);
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(find.text('Step 4 of 4: Finish, Finish (Brim edge)'), findsOneWidget);

    // Edit by tapping the card: the form opens filled in.
    await _tap(tester, find.text('Written: Centre start (Crown)'));
    expect(find.widgetWithText(TextFormField, '8'), findsOneWidget);
    await tester.enterText(_key('segment-stitches'), '10');
    await tester.tap(_key('segment-done'));
    await tester.pumpAndSettle();

    await tester.tap(_key('recipe-save'));
    await tester.pumpAndSettle();
    expect(_ids(repo, 'p1'), ['segment-1', 'segment-2', 'segment-4', 'segment-3']);
    expect(repo.projects['p1']!.recipe!.segments.first.stitches, 10);
    expect(repo.projects['p1']!.recipe!.segments[2].withId('segment-2'),
        repo.projects['p1']!.recipe!.segments[1],
        reason: 'the duplicate copies everything');
    expect(repo.projects['p1']!.notes, 'Grey wool.', reason: 'the notes are untouched');
    await _end(tester);
  });

  testWidgets('a drag reorders a step', (tester) async {
    final repo = RecipeFakeRepo(projects: {'p1': _hat});
    await pumpProject(tester, repo, openId: 'p1');
    await _tap(tester, _key('project-recipe'));
    final handle = find.byIcon(Icons.drag_handle).first;
    final from = tester.getCenter(handle);
    final gesture = await tester.startGesture(from);
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.moveBy(const Offset(0, 300), timeStamp: const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.moveBy(const Offset(0, 100), timeStamp: const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.text('Step 1 of 3: Start, Centre start (Crown)'), findsNothing,
        reason: 'the start moved down');
    await _end(tester);
  });

  testWidgets("each step shows the engine's findings and whether Ply checked it", (tester) async {
    final repo = RecipeFakeRepo(projects: {
      'p1': _hat.withRecipe(_three.copyWith(segments: [
        ..._three.segments,
        const RecipeSegment(
            id: 'segment-4',
            kind: SegmentKind.freeform,
            role: RecipePhase.other,
            text: 'Wash and dry flat.'),
      ])),
    })
      ..report = (r, n) => standInReport(r,
          projectNotation: n,
          problems: {'segment-2': 'comes after Part 1 was finished'},
          warnings: {'segment-1': 'has no connection'});
    await pumpProject(tester, repo, openId: 'p1');
    await _tap(tester, _key('project-recipe'));

    expect(find.text('Problem: comes after Part 1 was finished'), findsOneWidget);
    expect(find.text('Warning: has no connection'), findsOneWidget);
    expect(find.text('Checked by Ply: has problems'), findsOneWidget);
    expect(find.text('Checked by Ply: has warnings'), findsOneWidget);
    expect(find.text('Free text: Ply does not read or check it'), findsOneWidget);
    expect(find.text('Wash and dry flat.'), findsOneWidget);
    expect(find.textContaining('does not simulate the fabric'), findsOneWidget);
    await _end(tester);
  });

  testWidgets('the form checks whole numbers and asks for a unit, never guessing one',
      (tester) async {
    final repo = RecipeFakeRepo(projects: {'p1': _hat});
    await pumpProject(tester, repo, openId: 'p1');
    await _tap(tester, _key('project-recipe'));
    await _tap(tester, _key('recipe-add-step'));
    await _tap(tester, _key('segment-kind-${SegmentKind.opening.json}'));
    await tester.enterText(_key('segment-skip'), 'seven');
    await tester.enterText(_key('segment-target-value'), '4');
    await tester.tap(_key('segment-done'));
    await tester.pumpAndSettle();
    expect(find.text('Enter a whole number'), findsOneWidget);
    expect(find.text('Choose a unit'), findsOneWidget);
    expect(find.byType(NalbindSegmentEditor), findsOneWidget, reason: 'the form stays open');

    await tester.enterText(_key('segment-skip'), '7');
    await _pick(tester, 'segment-target-unit', 'cm');
    await tester.tap(_key('segment-done'));
    await tester.pumpAndSettle();
    expect(find.text('Step 4 of 4: Shaping, Opening'), findsOneWidget);
    await _end(tester);
  });

  testWidgets('a pick-up names an earlier opening by its id', (tester) async {
    final repo = RecipeFakeRepo(projects: {
      'p1': _hat.withRecipe(const NalbindRecipe(segments: [
        RecipeSegment(id: 'segment-1', kind: SegmentKind.centreStart, stitches: 30),
        RecipeSegment(id: 'segment-2', kind: SegmentKind.opening, title: 'Thumb opening', skip: 7),
        RecipeSegment(id: 'segment-3', kind: SegmentKind.finish),
      ])),
    });
    await pumpProject(tester, repo, openId: 'p1');
    await _tap(tester, _key('project-recipe'));
    await _addStep(tester, SegmentKind.pickUp,
        title: 'Thumb',
        picks: {'segment-reference': 'Step 2: Thumb opening'},
        fields: {'segment-stitches': '18'});
    await tester.tap(_key('recipe-save'));
    await tester.pumpAndSettle();
    final thumb = repo.projects['p1']!.recipe!.segments.last;
    expect(thumb.kind, SegmentKind.pickUp);
    expect(thumb.reference, 'segment-2');
    expect(thumb.stitches, 18);
    await _end(tester);
  });

  testWidgets('the fit takes measurements with their units', (tester) async {
    final repo = RecipeFakeRepo(projects: {'p1': _hat});
    await pumpProject(tester, repo, openId: 'p1');
    await _tap(tester, _key('project-recipe'));
    await _tap(tester, _key('recipe-add-fit'));
    await tester.enterText(_key('fit-label'), 'Head around the forehead');
    await tester.enterText(_key('fit-value'), '56');
    await _pick(tester, 'fit-unit', 'cm');
    await tester.tap(_key('fit-done'));
    await tester.pumpAndSettle();
    expect(find.text('Head around the forehead'), findsOneWidget);
    await tester.tap(_key('recipe-save'));
    await tester.pumpAndSettle();
    expect(repo.projects['p1']!.recipe!.fit,
        [const Measurement(label: 'Head around the forehead', value: 56, unit: LengthUnit.cm)]);
    await _end(tester);
  });

  testWidgets('removing the recipe makes the project note-only again', (tester) async {
    final repo = RecipeFakeRepo(projects: {'p1': _hat});
    await pumpProject(tester, repo, openId: 'p1');
    await _tap(tester, _key('project-recipe'));
    await _tap(tester, find.byTooltip('More'));
    await tester.tap(find.text('Remove the recipe'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    expect(find.text('Add a recipe'), findsOneWidget);
    await tester.tap(find.byTooltip('Save'));
    await tester.pumpAndSettle();
    expect(repo.projects['p1']!.recipe, isNull);
    expect(repo.projects['p1']!.notes, 'Grey wool.');
    await _end(tester);
  });

  testWidgets('follow walks the steps, ticks are written alone and never unsaved', (tester) async {
    final repo = RecipeFakeRepo(projects: {
      'p1': _hat.withRecipe(_three.copyWith(done: {'segment-1'})),
    });
    await pumpProject(tester, repo, openId: 'p1');
    expect(find.text('3 steps, 1 done.'), findsOneWidget);
    // An unsaved edit elsewhere, which a tick must not save.
    await tester.enterText(find.widgetWithText(TextField, 'Grey wool.'), 'Grey wool, 60 g.');
    await tester.pumpAndSettle();

    await _tap(tester, _key('project-follow'));
    expect(find.byType(NalbindFollowScreen), findsOneWidget);
    // Opens at the first step not yet done.
    expect(find.text('Step 2 of 3, Part 1, Body'), findsOneWidget);
    expect(find.text('Rounds: Sides'), findsOneWidget);
    expect(find.text('Written: Rounds (Sides)'), findsOneWidget);
    expect(find.text('Try it on.'), findsOneWidget);
    expect(find.text('1 of 3 steps done'), findsOneWidget);

    await _tap(tester, _key('follow-done'));
    expect(find.text('2 of 3 steps done'), findsOneWidget);
    expect(repo.ticks, [('p1', 'segment-2', true)]);
    expect(repo.projects['p1']!.recipe!.done, {'segment-1', 'segment-2'});
    expect(repo.projects['p1']!.notes, 'Grey wool.', reason: 'only the tick was written');

    await _tap(tester, _key('follow-next'));
    expect(find.text('Finish: Brim edge'), findsOneWidget);
    expect(find.text('Taper slowly.'), findsOneWidget);
    await _tap(tester, _key('follow-previous'));
    await _tap(tester, _key('follow-done')); // untick
    expect(repo.projects['p1']!.recipe!.done, {'segment-1'});
    await _tap(tester, _key('follow-done'));

    await _back(tester); // follow
    expect(find.text('3 steps, 2 done.'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Grey wool, 60 g.'), 'Grey wool.');
    await tester.pumpAndSettle();
    await _back(tester); // project: the ticks are not unsaved changes
    expect(find.text(_leaveTitle), findsNothing);
    await _end(tester);
  });

  testWidgets('a tick that cannot be written is taken back and says so', (tester) async {
    final repo = RecipeFakeRepo(projects: {'p1': _hat})..tickError = true;
    await pumpProject(tester, repo, openId: 'p1');
    await _tap(tester, _key('project-follow'));
    await _tap(tester, _key('follow-done'));
    expect(find.textContaining('Could not save the tick'), findsOneWidget);
    expect(tester.widget<CheckboxListTile>(_key('follow-done')).value, isFalse);
    expect(find.text('0 of 3 steps done'), findsOneWidget);
    await _back(tester);
    expect(find.text('3 steps, 0 done.'), findsOneWidget, reason: 'the project took it back too');
    await _back(tester);
    expect(find.text(_leaveTitle), findsNothing);
    await _end(tester);
  });

  testWidgets('ticks on an unsaved project or step say how to keep them', (tester) async {
    final repo = RecipeFakeRepo(projects: {'p1': _hat});
    await pumpProject(tester, repo, openId: 'p1');
    await _tap(tester, _key('project-recipe'));
    await _addStep(tester, SegmentKind.freeform,
        picks: {'segment-role': 'A note, not a step of the work'},
        fields: {'segment-text': 'Felt lightly.'});
    await _tap(tester, _key('recipe-follow'));
    await _tap(tester, _key('follow-go-to'));
    await tester.tap(find.text('Step 4: Free text').last);
    await tester.pumpAndSettle();
    await _tap(tester, _key('follow-done'));
    expect(find.text('This step is not saved yet: its tick will be saved with the project.'),
        findsOneWidget);
    expect(repo.projects['p1']!.recipe!.done, isEmpty);

    final fresh = RecipeFakeRepo();
    await pumpProject(tester, fresh);
    await _tap(tester, _key('project-recipe'));
    await _addStep(tester, SegmentKind.centreStart, fields: {'segment-stitches': '6'});
    await _tap(tester, _key('recipe-follow'));
    await _tap(tester, _key('follow-done'));
    expect(find.text('Save the project to keep your ticks.'), findsOneWidget);
    expect(fresh.ticks, isEmpty);
    await _end(tester);
  });

  group('review fixes', () {
    testWidgets('Undo puts only the deleted step back, into the recipe as it is now',
        (tester) async {
      final repo = RecipeFakeRepo(projects: {'p1': _hat});
      await pumpProject(tester, repo, openId: 'p1');
      await _tap(tester, _key('project-recipe'));
      await _stepMenu(tester, 2, 'Delete');
      expect(find.text('Undo'), findsOneWidget);
      // A tick in the follow view after the delete (not an edit of the steps).
      await _tap(tester, _key('recipe-follow'));
      await _tap(tester, _key('follow-done'));
      await _back(tester);
      expect(find.text('Undo'), findsOneWidget);
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(find.text('Step 3 of 3: Finish, Finish (Brim edge)'), findsOneWidget);
      expect(find.text('Done'), findsOneWidget, reason: 'the later tick stays');
      await tester.tap(_key('recipe-save'));
      await tester.pumpAndSettle();
      expect(_ids(repo, 'p1'), ['segment-1', 'segment-2', 'segment-3']);
      expect(repo.projects['p1']!.recipe!.done, {'segment-1'});
      await _end(tester);
    });

    testWidgets('any later edit ends the Undo', (tester) async {
      final repo = RecipeFakeRepo(projects: {'p1': _hat});
      await pumpProject(tester, repo, openId: 'p1');
      await _tap(tester, _key('project-recipe'));
      await _stepMenu(tester, 2, 'Delete');
      expect(find.text('Undo'), findsOneWidget);
      await _stepMenu(tester, 0, 'Move down');
      expect(find.text('Undo'), findsNothing);
      expect(find.text('Step 1 of 2: Body, Rounds (Sides)'), findsOneWidget);
      await _end(tester);
    });

    testWidgets("a deleted step's id is never given again, so a tick cannot land on it",
        (tester) async {
      final repo = RecipeFakeRepo(projects: {'p1': _hat});
      await pumpProject(tester, repo, openId: 'p1');
      await _tap(tester, _key('project-recipe'));
      await _stepMenu(tester, 2, 'Delete');
      await _addStep(tester, SegmentKind.finish, title: 'New end');
      await _tap(tester, _key('recipe-follow'));
      await _tap(tester, _key('follow-go-to'));
      await tester.tap(find.text('Step 3: New end').last);
      await tester.pumpAndSettle();
      await _tap(tester, _key('follow-done'));
      expect(find.text('This step is not saved yet: its tick will be saved with the project.'),
          findsOneWidget);
      expect(repo.ticks, isEmpty, reason: 'nothing written over the deleted segment-3');
      expect(repo.projects['p1']!.recipe!.done, isEmpty);
      await _back(tester);
      await tester.tap(_key('recipe-save'));
      await tester.pumpAndSettle();
      expect(_ids(repo, 'p1'), ['segment-1', 'segment-2', 'segment-4']);
      expect(repo.projects['p1']!.recipe!.done, {'segment-4'});
      expect(repo.projects['p1']!.recipe!.lastSegmentNumber, 4);
      await _end(tester);
    });

    testWidgets('a step changed since the last save is ticked with the project, not alone',
        (tester) async {
      final repo = RecipeFakeRepo(projects: {'p1': _hat});
      await pumpProject(tester, repo, openId: 'p1');
      await _tap(tester, _key('project-recipe'));
      await _tap(tester, find.text('Written: Rounds (Sides)'));
      await tester.enterText(_key('segment-title'), 'Straight sides');
      await tester.tap(_key('segment-done'));
      await tester.pumpAndSettle();
      await _tap(tester, _key('recipe-follow'));
      await _tap(tester, _key('follow-next'));
      await _tap(tester, _key('follow-done'));
      expect(
          find.text(
              'This step has changed since the last save: its tick will be saved with the project.'),
          findsOneWidget);
      expect(repo.ticks, isEmpty);
      await _back(tester);
      await tester.tap(_key('recipe-save'));
      await tester.pumpAndSettle();
      expect(repo.projects['p1']!.recipe!.done, {'segment-2'});
      expect(repo.projects['p1']!.recipe!.segments[1].title, 'Straight sides');
      await _end(tester);
    });

    testWidgets('a recipe too large to check says so at the top, on each step and when followed',
        (tester) async {
      const why = 'Step 2 (Sides): its notes are longer than 10,000 characters, so Ply does not '
          'check the recipe.';
      final repo = RecipeFakeRepo(projects: {'p1': _hat})
        ..report = (_, __) => tooLargeReport(segment: 1, text: why);
      await pumpProject(tester, repo, openId: 'p1');
      await _tap(tester, _key('project-recipe'));
      expect(find.text('Problem: $why'), findsWidgets);
      expect(find.text(kRecipeTooLargeStep), findsNWidgets(3));
      expect(
          find.text('Not checked: the recipe is too large to check (see the problem at the top)'),
          findsNWidgets(3));
      expect(find.text('Checking…'), findsNothing);
      await _tap(tester, _key('recipe-follow'));
      expect(find.byKey(const ValueKey('follow-recipe-issues')), findsOneWidget);
      expect(find.text('Problem: $why'), findsOneWidget);
      expect(find.text(kRecipeTooLargeStep), findsOneWidget);
      await _end(tester);
    });

    testWidgets('the form measures text as the engine does, and says so plainly', (tester) async {
      final repo = RecipeFakeRepo(projects: {'p1': _hat});
      await pumpProject(tester, repo, openId: 'p1');
      await _tap(tester, _key('project-recipe'));
      await _tap(tester, _key('recipe-add-step'));
      await _tap(tester, _key('segment-kind-${SegmentKind.rounds.json}'));
      await _tap(tester, _key('segment-own-stitch'));
      await tester.enterText(_key('segment-notation'), 'UO' * 101);
      // 6,000 balls of yarn: 6,000 characters on screen, 12,000 units to the engine.
      await tester.enterText(_key('segment-notes'), '\u{1F9F6}' * 6000);
      await tester.tap(_key('segment-done'));
      await tester.pumpAndSettle();
      expect(
          find.text('Too long for Ply to check: at most 10,000 characters, and this is 12,000 '
              '(some symbols, such as emoji, count as two).'),
          findsOneWidget);
      expect(
          find.text('Too long for Ply to check: at most 200 characters, and this is 202 (some '
              'symbols, such as emoji, count as two).'),
          findsOneWidget);
      expect(find.byType(NalbindSegmentEditor), findsOneWidget);
      await _end(tester);
    });

    testWidgets('values a file can hold open in the form and are kept', (tester) async {
      final repo = RecipeFakeRepo(projects: {
        'p1': _hat.withRecipe(const NalbindRecipe(segments: [
          RecipeSegment(id: 'segment-1', kind: SegmentKind.centreStart, stitches: 2000000),
          RecipeSegment(
            id: 'segment-2',
            kind: SegmentKind.rows,
            extent: Extent.untilStitches(10),
            target: Measurement(label: 'Wide', value: 1e19, unit: LengthUnit.cm),
          ),
          RecipeSegment(id: 'segment-3', kind: SegmentKind.finish),
        ])),
      });
      await pumpProject(tester, repo, openId: 'p1');
      await _tap(tester, _key('project-recipe'));
      // A count past what Ply counts: the form takes it (the engine says it is too large).
      await _tap(tester, find.text('Written: Centre start'));
      expect(find.widgetWithText(TextFormField, '2000000'), findsOneWidget);
      await tester.tap(_key('segment-done'));
      await tester.pumpAndSettle();
      expect(find.byType(NalbindSegmentEditor), findsNothing);
      // Rows "until a stitch count" (from a file) and a huge length: shown as they are.
      await _tap(tester, find.text('Written: Rows'));
      expect(find.text('Until there are this many stitches (only shaping changes it)'),
          findsOneWidget);
      expect(find.widgetWithText(TextFormField, '10000000000000000000'), findsOneWidget);
      await tester.tap(_key('segment-done'));
      await tester.pumpAndSettle();
      await tester.tap(_key('recipe-save'));
      await tester.pumpAndSettle();
      final saved = repo.projects['p1']!.recipe!.segments;
      expect(saved[0].stitches, 2000000);
      expect(saved[1].extent, const Extent.untilStitches(10));
      expect(saved[1].target!.value, 1e19);
      await _end(tester);
    });

    testWidgets('keys a newer Ply wrote are kept through an edit in the form', (tester) async {
      final withExtras = NalbindProject.decode(jsonEncode({
        ..._hat.withRecipe(null).toJson(),
        'recipe': {
          'fit': <Object>[],
          'segments': [
            {
              'id': 'segment-1',
              'title': 'Crown',
              'work': {'kind': 'centreStart', 'stitches': 8, 'futureWork': 1},
              'stitch': {
                'notation': 'UO/UOO F2',
                'name': '',
                'reading': 'strict',
                'futureStitch': 2,
              },
              'target': {'label': 'Across', 'value': 9.0, 'unit': 'cm', 'futureTarget': 3},
              'notes': '',
              'caution': '',
              'futureSegment': [4],
            },
          ],
          'done': <Object>[],
          'lastSegmentNumber': 1,
          'futureRecipe': 5,
        },
      }));
      final repo = RecipeFakeRepo(projects: {'p1': withExtras});
      await pumpProject(tester, repo, openId: 'p1');
      await _tap(tester, _key('project-recipe'));
      await _tap(tester, find.text('Written: Centre start (Crown)'));
      await tester.enterText(_key('segment-title'), 'Crown ring');
      await tester.tap(_key('segment-done'));
      await tester.pumpAndSettle();
      await tester.tap(_key('recipe-save'));
      await tester.pumpAndSettle();
      final json = repo.projects['p1']!.toJson()['recipe'] as Map<String, dynamic>;
      final seg = (json['segments'] as List).single as Map<String, dynamic>;
      expect(seg['title'], 'Crown ring');
      expect(seg['futureSegment'], [4]);
      expect((seg['work'] as Map)['futureWork'], 1);
      expect((seg['stitch'] as Map)['futureStitch'], 2);
      expect((seg['target'] as Map)['futureTarget'], 3);
      expect(json['futureRecipe'], 5);
      await _end(tester);
    });

    testWidgets('free text with problems in its place says so, and long lists are cut short',
        (tester) async {
      final repo = RecipeFakeRepo(projects: {
        'p1': _hat.withRecipe(_three.copyWith(segments: [
          const RecipeSegment(
              id: 'segment-0', kind: SegmentKind.freeform, role: RecipePhase.body, text: 'Early.'),
          ..._three.segments,
        ])),
      })
        ..report = (r, n) {
          final base = standInReport(r,
              projectNotation: n, problems: {'segment-0': 'comes before any start'});
          return RecipeReportDto(
            segments: base.segments,
            issues: [
              ...base.issues,
              for (var k = 0; k < 20; k++)
                RecipeIssueDto(
                  code: 'notation-problem',
                  severity: RecipeSeverityKind.warning,
                  segment: 2,
                  segmentId: 'segment-2',
                  message: 'problem $k',
                  text: 'Step 3: problem $k',
                ),
            ],
            fit: base.fit,
            projectStitch: base.projectStitch,
            tooLarge: false,
          );
        };
      await pumpProject(tester, repo, openId: 'p1');
      await _tap(tester, _key('project-recipe'));
      expect(find.text('Free text, not read by Ply: its place in the recipe has problems'),
          findsOneWidget);
      expect(find.text('Problem: comes before any start'), findsOneWidget);
      expect(find.text('Warning: problem 11'), findsOneWidget);
      expect(find.text('Warning: problem 12'), findsNothing);
      expect(find.text('and 8 more findings (the PDF lists them all)'), findsOneWidget);
      await _end(tester);
    });
  });
}
