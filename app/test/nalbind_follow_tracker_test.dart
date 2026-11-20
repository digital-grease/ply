import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/library_backup.dart' show BackupCraft;
import 'package:ply/src/data/progress_repository.dart' show ProgressLoad, ProgressStatus;
import 'package:ply/src/data/work_repository.dart';
import 'package:ply/src/models/nalbind_project.dart';
import 'package:ply/src/models/nalbind_recipe.dart';
import 'package:ply/src/models/progress.dart';
import 'package:ply/src/screens/nalbind_follow_screen.dart';
import 'package:ply/src/screens/nalbind_project_screen.dart';
import 'package:ply/src/state/nalbind_providers.dart';
import 'package:ply/src/state/progress_controller.dart';
import 'package:ply/src/widgets/progress_panels.dart' show logEntryText;

import 'nalbind_recipe_test_support.dart';
import 'progress_test_support.dart';

// Nalbinding step by step (ADR 0023 section 10) on the host: the recipe's follow view is the
// tracker. For a saved project the step on screen is the maker's place, kept at once in the
// project's own record (in memory here; the file is the shared repository's, tested on its own),
// resumed on its step by id, shown for checking when the recipe changed before it, with notes, the
// log, Undo and Clear. The Done ticks stay the maker's own: moving the place never writes one. A
// project not saved yet walks the steps without keeping a place, and a project without a recipe
// says it has nothing to follow.

const _recipe = NalbindRecipe(segments: [
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
], lastSegmentNumber: 3);

NalbindProject _hat(NalbindRecipe? recipe) => NalbindProject(
    name: 'Hat', notation: 'UO/UOO F1', stitchName: 'Oslo', notes: 'Grey wool.', recipe: recipe);

Finder _key(String k) => find.byKey(ValueKey(k));

void main() {
  late MemoryProgressRepository memory;
  late FakeWork work;
  setUp(() {
    memory = MemoryProgressRepository();
    work = FakeWork();
  });

  Future<void> pumpProject(WidgetTester tester, RecipeFakeRepo repo, {String? openId}) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const SizedBox());
    var minutes = 0;
    final c = ProviderContainer(overrides: [
      nalbindRepositoryProvider.overrideWithValue(repo),
      progressRepositoryProvider.overrideWithValue(memory),
      workRepositoryProvider.overrideWithValue(work),
      progressClockProvider.overrideWithValue(
          () => DateTime.utc(2026, 11, 18, 10).add(Duration(minutes: minutes++))),
    ]);
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(home: NalbindProjectScreen(openId: openId)),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, Finder f) async {
    await tester.ensureVisible(f);
    await tester.pumpAndSettle();
    await tester.tap(f);
    await tester.pumpAndSettle();
  }

  Future<void> back(WidgetTester tester) async {
    await tester.pageBack();
    await tester.pumpAndSettle();
  }

  Progress? stored(String id) => memory.records[(BackupCraft.nalbinding, id)];

  Progress savedAt(int unit, String step, {NalbindRecipe recipe = _recipe}) => Progress(
        craft: ProgressCraft.nalbinding,
        place: NalbindPlace(unit, stepId: step),
        basis: PlaceBasis(units: recipe.segments.length, prefix: fakeStepPrefix(recipe, unit)),
      );

  testWidgets('a saved project keeps its place step by step; the ticks stay the maker\'s',
      (tester) async {
    final repo = RecipeFakeRepo(projects: {
      'p1': _hat(_recipe.copyWith(done: {'segment-1'}))
    });
    await pumpProject(tester, repo, openId: 'p1');
    await tap(tester, _key('project-follow'));
    expect(find.byType(NalbindFollowScreen), findsOneWidget);
    expect(find.text(kNalbindTrackerTitle), findsOneWidget);
    // Without a place yet: the first step not done, and nothing written.
    expect(find.text('Step 2 of 3, Part 1, Body'), findsOneWidget);
    expect(memory.saves, 0);
    expect(find.text('Worked, next step'), findsOneWidget);

    await tap(tester, _key('follow-next'));
    expect(find.text('Finish: Brim edge'), findsOneWidget);
    final p = stored('p1')!;
    expect(p.place, const NalbindPlace(2, stepId: 'segment-3'));
    expect(p.basis, PlaceBasis(units: 3, prefix: fakeStepPrefix(_recipe, 2)));
    expect(p.log.single.kind, LogKind.worked);
    expect(repo.ticks, isEmpty, reason: 'moving the place never ticks a step');
    expect(repo.projects['p1']!.recipe!.done, {'segment-1'});

    // A tick is still the maker's, and still written alone.
    await tap(tester, _key('follow-done'));
    expect(repo.ticks, [('p1', 'segment-3', true)]);
    expect(stored('p1')!.place, const NalbindPlace(2, stepId: 'segment-3'), reason: 'unmoved');

    // Back and in again: the place, not the first step not done.
    await back(tester);
    await tap(tester, _key('project-follow'));
    expect(find.text('Finish: Brim edge'), findsOneWidget);
    expect(find.byKey(const ValueKey('tracker-banner')), findsNothing);
    // Previous corrects a mistap; Go to jumps.
    await tap(tester, _key('follow-previous'));
    expect(stored('p1')!.log.last.kind, LogKind.back);
    await tap(tester, _key('follow-go-to'));
    await tester.tap(find.text('Done: Step 1: Crown').last);
    await tester.pumpAndSettle();
    expect(stored('p1')!.place, const NalbindPlace(0, stepId: 'segment-1'));
    expect(stored('p1')!.log.last.kind, LogKind.jump);
  });

  testWidgets('a step inserted before the place keeps the place on its step, for checking',
      (tester) async {
    memory.records[(BackupCraft.nalbinding, 'p1')] = savedAt(2, 'segment-3');
    final edited = _recipe.copyWith(segments: [
      const RecipeSegment(id: 'segment-4', kind: SegmentKind.centreStart, title: 'Tip'),
      ..._recipe.segments,
    ]);
    final repo = RecipeFakeRepo(projects: {'p1': _hat(edited)});
    await pumpProject(tester, repo, openId: 'p1');
    await tap(tester, _key('project-follow'));
    expect(find.text('Finish: Brim edge'), findsOneWidget, reason: 'the same step, by its id');
    expect(find.textContaining('Step 4 of 4'), findsOneWidget);
    expect(find.textContaining('now step 4 (it was step 3)'), findsOneWidget);
    expect(tester.widget<IconButton>(_key('tracker-undo')).onPressed, isNull);
    expect(memory.saves, 0, reason: 'nothing written yet');

    await tap(tester, _key('tracker-right'));
    final p = stored('p1')!;
    expect(p.place, const NalbindPlace(3, stepId: 'segment-3'));
    expect(p.log.single.kind, LogKind.fix);
    final words = NalbindPlaceWords(edited);
    expect(logEntryText(p.log.single, words.call, NalbindPlaceWords.units),
        'Place checked at step 4 (Brim edge) after the pattern changed');
    // Undo returns to the stored place, which is checked against the recipe again.
    await tap(tester, _key('tracker-undo'));
    expect(stored('p1')!.place, const NalbindPlace(2, stepId: 'segment-3'));
    expect(_key('tracker-right'), findsOneWidget);
  });

  testWidgets('a step that is gone is shown at its number for checking', (tester) async {
    memory.records[(BackupCraft.nalbinding, 'p1')] = savedAt(1, 'segment-2');
    final edited = _recipe.copyWith(segments: [_recipe.segments[0], _recipe.segments[2]]);
    final repo = RecipeFakeRepo(projects: {'p1': _hat(edited)});
    await pumpProject(tester, repo, openId: 'p1');
    await tap(tester, _key('project-follow'));
    expect(find.textContaining('Step 2 of 2'), findsOneWidget);
    expect(find.textContaining('The step you were on is no longer in the recipe'), findsOneWidget);
    // Going to the step offered from the banner records it.
    await tap(tester, find.text('Go to…'));
    await tap(tester, find.text('Step 1: Crown'));
    expect(stored('p1')!.place, const NalbindPlace(0, stepId: 'segment-1'));
    expect(
        logEntryText(
            stored('p1')!.log.single, NalbindPlaceWords(edited).call, NalbindPlaceWords.units),
        'Went to step 1 (Crown) (from step 2 (Brim edge))',
        reason: 'from the step shown for checking');
  });

  testWidgets('a note is pinned to its step; Clear removes place, log and notes', (tester) async {
    final repo = RecipeFakeRepo(projects: {'p1': _hat(_recipe)});
    await pumpProject(tester, repo, openId: 'p1');
    await tap(tester, _key('project-follow'));
    await tap(tester, _key('tracker-add-note'));
    await tester.enterText(_key('tracker-note-field'), 'Loose start');
    await tap(tester, _key('tracker-note-save'));
    expect(find.text('Loose start'), findsOneWidget);
    expect(stored('p1')!.notes.single.place, const NalbindPlace(0, stepId: 'segment-1'));
    await tap(tester, _key('follow-next'));
    expect(find.text('Loose start'), findsNothing);
    await tap(tester, find.byTooltip('More'));
    await tap(tester, find.text('Notes').last);
    expect(find.textContaining('step 1 (Crown)'), findsOneWidget);
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
    await tap(tester, find.byTooltip('More'));
    await tap(tester, find.text('Clear my place'));
    await tap(tester, _key('tracker-clear-confirm'));
    expect(stored('p1'), isNull);
    expect(find.textContaining('Step 1 of 3'), findsOneWidget);
  });

  testWidgets('a project not saved yet walks the steps without keeping a place', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        nalbindRepositoryProvider.overrideWithValue(RecipeFakeRepo()),
        progressRepositoryProvider.overrideWithValue(memory),
        workRepositoryProvider.overrideWithValue(work),
      ],
      child: MaterialApp(
        home: NalbindFollowScreen(
          recipe: _recipe,
          projectNotation: 'UO/UOO F1',
          projectStitchName: 'Oslo',
          onTick: (_, __) async => 'Save the project to keep your ticks.',
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(_key('follow-unsaved'), findsOneWidget);
    expect(find.text('Save the project to keep your place.'), findsOneWidget);
    expect(find.text('Next'), findsOneWidget);
    await tap(tester, _key('follow-next'));
    expect(find.text('Rounds: Sides'), findsOneWidget);
    expect(memory.saves, 0);
    expect(_key('tracker-undo'), findsNothing);
    expect(work.nalbindResumes, isEmpty);
  });

  testWidgets('a newer or unreadable record is left alone and the steps can still be followed',
      (tester) async {
    memory.problems[(BackupCraft.nalbinding, 'p1')] = ProgressStatus.newer;
    final repo = RecipeFakeRepo(projects: {'p1': _hat(_recipe)});
    await pumpProject(tester, repo, openId: 'p1');
    await tap(tester, _key('project-follow'));
    expect(find.textContaining('saved by a newer version of Ply'), findsOneWidget);
    expect(_key('tracker-start-again'), findsNothing);
    await tap(tester, _key('follow-next'));
    expect(find.text('Rounds: Sides'), findsOneWidget);
    expect(memory.saves, 0);
    await back(tester);

    memory.problems[(BackupCraft.nalbinding, 'p1')] = ProgressStatus.unreadable;
    await tap(tester, _key('project-follow'));
    expect(find.text('Your place in this project could not be read.'), findsOneWidget);
    await tap(tester, _key('tracker-start-again'));
    expect(_key('tracker-record-problem'), findsNothing);
    await tap(tester, _key('follow-next'));
    expect(stored('p1')!.place, const NalbindPlace(1, stepId: 'segment-2'));
  });

  testWidgets('the More menu: nothing to follow without a recipe, and save first', (tester) async {
    final repo = RecipeFakeRepo(projects: {'p1': _hat(null)});
    await pumpProject(tester, repo, openId: 'p1');
    await tap(tester, _key('project-more'));
    await tap(tester, find.text('$kNalbindTrackerTitle…'));
    expect(find.text(kNalbindNothingToTrack), findsOneWidget);
    expect(find.byType(NalbindFollowScreen), findsNothing);

    final fresh = RecipeFakeRepo(projects: {'p1': _hat(_recipe)});
    await pumpProject(tester, fresh, openId: 'p1');
    await tap(tester, _key('project-more'));
    await tap(tester, find.text('$kNalbindTrackerTitle…'));
    expect(find.byType(NalbindFollowScreen), findsOneWidget);
  });

  testWidgets('the More menu asks to save a new project first; the recipe\'s button is named so',
      (tester) async {
    final repo = RecipeFakeRepo();
    await pumpProject(tester, repo);
    await tap(tester, _key('project-recipe'));
    await tap(tester, _key('recipe-add-step'));
    await tap(tester, _key('segment-kind-${SegmentKind.centreStart.json}'));
    await tester.tap(_key('segment-done'));
    await tester.pumpAndSettle();
    await back(tester);
    expect(find.widgetWithText(OutlinedButton, kNalbindTrackerTitle), findsOneWidget);
    await tap(tester, _key('project-more'));
    await tap(tester, find.text('$kNalbindTrackerTitle…'));
    expect(find.text('Save the project first to keep your place.'), findsOneWidget);
    expect(find.byType(NalbindFollowScreen), findsNothing);
  });

  testWidgets('a move waits until the place is read, so it is never taken back', (tester) async {
    final slow = _SlowProgress();
    final repo = RecipeFakeRepo(projects: {'p1': _hat(_recipe)});
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        nalbindRepositoryProvider.overrideWithValue(repo),
        progressRepositoryProvider.overrideWithValue(slow),
        workRepositoryProvider.overrideWithValue(work),
      ],
      child: MaterialApp(
        home: NalbindFollowScreen(
          recipe: _recipe,
          projectNotation: 'UO/UOO F1',
          projectStitchName: 'Oslo',
          onTick: (_, __) async => null,
          projectId: 'p1',
        ),
      ),
    ));
    await tester.pump();
    FilledButton next() => tester.widget<FilledButton>(_key('follow-next'));
    expect(next().onPressed, isNull, reason: 'not until the place is read');
    expect(tester.widget<PopupMenuButton<int>>(_key('follow-go-to')).enabled, isFalse);
    slow.reading.complete(ProgressLoad(ProgressStatus.ok, savedAt(1, 'segment-2')));
    await tester.pumpAndSettle();
    expect(find.text('Rounds: Sides'), findsOneWidget, reason: 'resumed at the place');
    expect(next().onPressed, isNotNull);
    await tap(tester, _key('follow-next'));
    expect(slow.records[(BackupCraft.nalbinding, 'p1')]!.place,
        const NalbindPlace(2, stepId: 'segment-3'));
  });

  test('place words', () {
    const words = NalbindPlaceWords(_recipe);
    expect(words(const NalbindPlace(5, stepId: 'segment-2')), 'step 2 (Sides)');
    expect(words(const NalbindPlace(0)), 'step 1 (Crown)');
    expect(words(const NalbindPlace(0, stepId: 'segment-9')), 'a step no longer in the recipe');
    expect(NalbindPlaceWords.units(1), '1 step');
    expect(NalbindPlaceWords.units(3), '3 steps');
  });
}

/// A record that is read only when the test says.
class _SlowProgress extends MemoryProgressRepository {
  final reading = Completer<ProgressLoad>();

  @override
  Future<ProgressLoad> load(BackupCraft craft, String id) => reading.future;
}
