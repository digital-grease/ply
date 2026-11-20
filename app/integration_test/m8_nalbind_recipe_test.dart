// M8-04 device proof: a structured nalbinding RECIPE through the real engine and the real
// filesystem (ADR 0017). A cuff-up mitten is built in the project screen's recipe editor (the kind
// sheet and the per-kind forms): a foundation chain joined into a ring, the hand rounds, the thumb
// opening, the top decreases, a closed tip, then the thumb picked up around the opening and closed.
// A step is moved with Move up, the project is saved as a schema version 3 `.plynal`, and the
// engine's own written instructions and stitch counts show under each step. The project is
// reopened through a fresh repository (a relaunch) with the same steps in the same order, followed
// one step at a time, and a step is ticked done; the tick is written to the file at once, and a
// second reopen opens the follow view at the next step.
//
//   flutter test integration_test/m8_nalbind_recipe_test.dart -d emulator-5554

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:ply/src/data/library_backup.dart' show BackupCraft;
import 'package:ply/src/data/nalbind_repository.dart';
import 'package:ply/src/data/progress_repository.dart';
import 'package:ply/src/models/nalbind_project.dart';
import 'package:ply/src/models/nalbind_recipe.dart';
import 'package:ply/src/models/progress.dart';
import 'package:ply/src/rust/frb_generated.dart';
import 'package:ply/src/screens/nalbind_follow_screen.dart';
import 'package:ply/src/screens/nalbind_project_screen.dart';
import 'package:ply/src/screens/nalbind_recipe_screen.dart';
import 'package:ply/src/state/nalbind_providers.dart';
import 'package:ply/src/state/progress_controller.dart';

Finder _key(String k) => find.byKey(ValueKey(k));

/// Bring [f] on screen and tap it. The screens are lazy lists, which build only what is near the
/// screen: on a phone the project's recipe buttons sit below the loop diagram, the Add a step
/// button below the steps, and a step's menu can be scrolled far above. So when [f] is not on
/// screen, [list] (the page's list unless given) is scrolled from its top until it is.
Future<void> _tap(WidgetTester tester, Finder f, {Finder? list}) async {
  if (f.evaluate().isEmpty) {
    final scrollable = list ?? find.byType(Scrollable).first;
    (tester.state(scrollable) as ScrollableState).position.jumpTo(0);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(f, 200, scrollable: scrollable);
  }
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

/// The list in the sheet of step kinds.
final _kindSheet =
    find.descendant(of: find.byType(DraggableScrollableSheet), matching: find.byType(Scrollable));

Future<void> _pick(WidgetTester tester, String key, String item) async {
  await _tap(tester, _key(key));
  await tester.tap(find.text(item).last);
  await tester.pumpAndSettle();
}

/// Add a step through the sheet and its form: [picks] are dropdowns by key, [fields] text fields.
Future<void> _addStep(
  WidgetTester tester,
  SegmentKind kind, {
  String? title,
  Map<String, String> picks = const {},
  Map<String, String> fields = const {},
}) async {
  await _tap(tester, _key('recipe-add-step'));
  await _tap(tester, _key('segment-kind-${kind.json}'), list: _kindSheet.first);
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

Future<void> _back(WidgetTester tester) async {
  await tester.tap(find.byType(BackButton).last);
  await tester.pumpAndSettle();
}

/// The progress records of the projects in the test's library folder (the follow view keeps the
/// maker's place there, ADR 0023).
late ProgressRepository _progress;

/// The host page that pushes the project screen (so a back has somewhere to go).
Future<void> _open(WidgetTester tester, NalbindRepository repo, {String? openId}) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pumpAndSettle();
  await tester.pumpWidget(ProviderScope(
    overrides: [
      nalbindRepositoryProvider.overrideWithValue(repo),
      progressRepositoryProvider.overrideWithValue(_progress),
    ],
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
  expect(find.byType(NalbindProjectScreen), findsOneWidget);
}

/// Scroll the screen's list from the top until [text] is on screen, and expect it once.
Future<void> _see(WidgetTester tester, String text) async {
  final list = find.byType(Scrollable).first;
  (tester.state(list) as ScrollableState).position.jumpTo(0);
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(find.text(text), 200, scrollable: list);
  expect(find.text(text), findsOneWidget, reason: text);
}

const _headings = [
  'Step 1 of 7: Start, Foundation chain (Cuff start)',
  'Step 2 of 7: Body, Rounds (Hand)',
  'Step 3 of 7: Shaping, Opening (Thumb opening)',
  'Step 4 of 7: Shaping, Decrease (Top)',
  'Step 5 of 7: Finish, Finish (Close the top)',
  'Step 6 of 7: Start, Pick up loops (Thumb)',
  'Step 7 of 7: Finish, Finish (Close the thumb)',
];

/// The engine's written instructions for the mitten, worked out by hand from ADR 0017.
const _written = [
  'Make a foundation chain of 36 stitches and join it into a ring.',
  'Work in a spiral until it reaches the base of the thumb.',
  'Leave an opening: skip 7 loops of the previous round and work 9 stitches across the gap '
      'without connecting them.',
  'Decrease 4 stitches in each round, connecting through two loops of the previous round at '
      'once, until 10 stitches remain.',
  'Finish by drawing the last loops together to close the tip.',
  'Pick up 18 loops around the opening in step 3 (Thumb opening) to start this part.',
  'Finish by drawing the last loops together to close the tip.',
];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  testWidgets('build, reorder, save, reopen, follow and tick a mitten recipe', (tester) async {
    // A library folder like the app's: projects in `nalbinds/`, which the place is kept beside.
    final root = await Directory.systemTemp.createTemp('ply_m8_recipe');
    addTearDown(() => root.delete(recursive: true));
    final dir = Directory('${root.path}/nalbinds')..createSync();
    _progress = ProgressRepository(docsOverride: root);
    final repo = NalbindRepository()..dirOverride = dir;

    // --- Build ------------------------------------------------------------------------------
    await _open(tester, repo);
    await tester.enterText(find.widgetWithText(TextField, 'Project name'), 'Device mittens');
    await tester.enterText(find.widgetWithText(TextField, 'Hansen notation'), 'UO/UOO F1');
    await tester.pumpAndSettle();
    await _tap(tester, _key('project-recipe'));
    expect(find.byType(NalbindRecipeScreen), findsOneWidget);

    await _addStep(tester, SegmentKind.foundationChain,
        title: 'Cuff start',
        picks: {'segment-chain-join': ChainJoin.ring.label},
        fields: {'segment-stitches': '36'});
    await _addStep(tester, SegmentKind.opening,
        title: 'Thumb opening', fields: {'segment-skip': '7', 'segment-stitches': '9'});
    // Added after the opening by mistake; moved above it below.
    await _addStep(tester, SegmentKind.rounds, title: 'Hand', picks: {
      'segment-round-join': RoundJoin.spiral.label,
      'segment-reach': 'Until it measures or reaches something',
    }, fields: {
      'segment-until-label': 'it reaches the base of the thumb'
    });
    await _addStep(tester, SegmentKind.decrease, title: 'Top', picks: {
      'segment-method': DecreaseMethod.twoLoopsAtOnce.label,
      'segment-reach': 'Until this many stitches remain',
    }, fields: {
      'segment-per-round': '4',
      'segment-reach-count': '10'
    });
    await _addStep(tester, SegmentKind.finish,
        title: 'Close the top', picks: {'segment-method': FinishMethod.closeTip.label});
    await _addStep(tester, SegmentKind.pickUp,
        title: 'Thumb',
        picks: {'segment-reference': 'Step 2: Thumb opening'},
        fields: {'segment-stitches': '18'});
    await _addStep(tester, SegmentKind.finish,
        title: 'Close the thumb', picks: {'segment-method': FinishMethod.closeTip.label});

    // --- Reorder: the hand rounds go before the opening ------------------------------------
    await _tap(tester, _key('recipe-step-menu-2'));
    await tester.tap(find.text('Move up').last);
    await tester.pumpAndSettle();
    // Each heading carries its position, so finding every one proves the order.
    for (final h in _headings) {
      await _see(tester, h);
    }
    // The engine's words and counts on screen.
    for (final t in [
      _written[0],
      _written[2],
      _written[5],
      "Stitches: 38 stitches (from the recipe's numbers)",
    ]) {
      await _see(tester, t);
    }

    // --- Save -----------------------------------------------------------------------------------
    await tester.tap(_key('recipe-save'));
    await tester.pumpAndSettle();
    final id = (await repo.listProjects()).single.id;
    final onDisk = File('${dir.path}/$id.plynal').readAsStringSync();
    final json = jsonDecode(onDisk) as Map<String, dynamic>;
    expect(json['schemaVersion'], 3);
    final saved = NalbindProject.decode(onDisk);
    expect(saved.recipe!.segments.map((s) => s.title), [
      'Cuff start',
      'Hand',
      'Thumb opening',
      'Top',
      'Close the top',
      'Thumb',
      'Close the thumb',
    ]);
    final opening = saved.recipe!.segments[2];
    expect(saved.recipe!.segments[5].reference, opening.id, reason: 'the thumb names the opening');
    // The real engine, on what was saved: every written line, the counts, no problems.
    final report = await repo.checkRecipe(saved.recipe!, projectNotation: saved.notation);
    expect(report.issues.map((i) => i.text), isEmpty);
    expect(report.segments.map((r) => r.written), _written);
    expect(report.segments.map((r) => r.count), [36, 36, 38, 10, 10, 18, 18]);
    expect(report.segments.map((r) => r.partNumber), [1, 1, 1, 1, 1, 2, 2]);
    await _back(tester); // recipe screen
    await _back(tester); // project screen

    // --- Reopen (a relaunch) -------------------------------------------------------------------
    final relaunched = NalbindRepository()..dirOverride = dir;
    await _open(tester, relaunched, openId: id);
    expect(find.text('7 steps, 0 done.'), findsOneWidget);
    await _tap(tester, _key('project-recipe'));
    for (final h in _headings) {
      await _see(tester, h);
    }
    await _back(tester);

    // --- Follow and tick ------------------------------------------------------------------------
    await _tap(tester, _key('project-follow'));
    expect(find.byType(NalbindFollowScreen), findsOneWidget);
    expect(find.text('Step 1 of 7, Part 1, Start'), findsOneWidget);
    expect(find.text('Make a foundation chain of 36 stitches and join it into a ring.'),
        findsOneWidget);
    await _tap(tester, _key('follow-done'));
    expect(find.text('1 of 7 steps done'), findsOneWidget);
    final ticked = NalbindProject.decode(File('${dir.path}/$id.plynal').readAsStringSync());
    expect(ticked.recipe!.doneInOrder, [ticked.recipe!.segments.first.id],
        reason: 'the tick is on disk at once');
    await _tap(tester, _key('follow-next'));
    expect(find.text('Step 2 of 7, Part 1, Body'), findsOneWidget);
    expect(find.byKey(const ValueKey('tracker-save-error')), findsNothing);
    // The place is kept, by the step's id, and the tick is the only change to the project.
    final kept = await _progress.load(BackupCraft.nalbinding, id);
    expect(kept.progress!.place, NalbindPlace(1, stepId: ticked.recipe!.segments[1].id));
    await _back(tester); // follow
    await _back(tester); // project: a tick is not an unsaved change
    expect(find.text('Leave without saving?'), findsNothing);

    // --- Reopen again: the tick is kept, and the follow view opens at the next step -------------
    await _open(tester, NalbindRepository()..dirOverride = dir, openId: id);
    expect(find.text('7 steps, 1 done.'), findsOneWidget);
    await _tap(tester, _key('project-follow'));
    expect(find.text('Step 2 of 7, Part 1, Body'), findsOneWidget, reason: 'the place kept');
    expect(find.text('Work in a spiral until it reaches the base of the thumb.'), findsOneWidget);
    expect(find.byKey(const ValueKey('tracker-banner')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}
