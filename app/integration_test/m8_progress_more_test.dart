// M8-05 device proof, second slice (ADR 0023 section 10): a tablet weaver's and a nalbinder's place
// survive a restart, through the real engines, the editors' menus and the device's file system,
// fully offline.
//
// Tablet weaving: the band editor's menu asks to save an unsaved band first; a saved band of three
// forward picks (one time through does not bring the cards home) is woven pick by pick from the
// menu into its second time through, where the engine says the cards start where the first time
// ended and every card holds three quarter turns of twist; back in the editor the stepper is at the
// place; a fresh tracker (a new provider scope: what an app restart reads) resumes there; an unsaved
// edit before the place shows it for checking, nothing written until the weaver says; deleting the
// band deletes its progress.
// Nalbinding: a project without a recipe says it has nothing to follow; a saved mitten recipe is
// worked step by step from the project's menu, the Done ticks left alone; after a restart Follow
// opens at the place; a step inserted before it keeps the place on its step, for checking; deleting
// the project deletes its progress.
//
//   flutter test integration_test/m8_progress_more_test.dart -d emulator-5554

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:ply/src/data/library_backup.dart' show BackupCraft;
import 'package:ply/src/data/nalbind_repository.dart';
import 'package:ply/src/data/progress_repository.dart';
import 'package:ply/src/data/tablet_repository.dart';
import 'package:ply/src/models/draft_meta.dart';
import 'package:ply/src/models/nalbind_project.dart';
import 'package:ply/src/models/nalbind_recipe.dart';
import 'package:ply/src/models/progress.dart';
import 'package:ply/src/models/tablet_band.dart';
import 'package:ply/src/rust/frb_generated.dart';
import 'package:ply/src/rust/tablet_dto.dart';
import 'package:ply/src/screens/nalbind_follow_screen.dart';
import 'package:ply/src/screens/nalbind_project_screen.dart';
import 'package:ply/src/screens/tablet_editor_screen.dart';
import 'package:ply/src/screens/tablet_tracker_screen.dart';
import 'package:ply/src/state/nalbind_providers.dart';
import 'package:ply/src/state/tablet_editor_providers.dart';

Finder placeText(String text) => find.descendant(
    of: find.byKey(const ValueKey('tracker-place')), matching: find.text(text), matchRoot: true);

/// Frames with real time between them (the engine and the files answer on their own time).
Future<void> settle(WidgetTester tester, {int frames = 20}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// A fresh app: the old one is taken down, and a new provider scope means every repository is new
/// and reads from disk.
Future<void> openFresh(WidgetTester tester, Widget screen,
    {List<Override> overrides = const []}) async {
  await tester.pumpWidget(const SizedBox());
  await settle(tester, frames: 4);
  await tester.pumpWidget(ProviderScope(overrides: overrides, child: MaterialApp(home: screen)));
  await settle(tester, frames: 40);
}

/// Pump frames until [finder] finds something, for at most [seconds].
Future<void> pumpUntil(WidgetTester tester, Finder finder, {int seconds = 30}) async {
  for (var i = 0; i < seconds * 20 && finder.evaluate().isEmpty; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  if (finder.evaluate().isEmpty) {
    final shown = find
        .byType(Text)
        .evaluate()
        .map((e) => (e.widget as Text).data)
        .whereType<String>()
        .take(30)
        .join(' | ');
    fail('$finder still missing after $seconds s; on screen: $shown');
  }
}

Future<void> tapKey(WidgetTester tester, String key) async {
  final f = find.byKey(ValueKey(key));
  await pumpUntil(tester, f);
  await tester.ensureVisible(f);
  await settle(tester, frames: 4);
  await tester.tap(f);
  await settle(tester);
}

/// Choose [entry] in the screen's overflow menu ([tooltip] names its button).
Future<void> fromMenu(WidgetTester tester, String tooltip, String entry) async {
  await pumpUntil(tester, find.byTooltip(tooltip));
  await tester.tap(find.byTooltip(tooltip).first);
  await settle(tester);
  await pumpUntil(tester, find.text(entry));
  await tester.tap(find.text(entry));
  await settle(tester, frames: 40);
}

/// Four cards turned forward three picks: one time through leaves every card a quarter turn short
/// of home, with three quarter turns of twist.
TabletDocumentDto threeForward() => copyDoc(blankTabletDocument(cards: 4), turning: [
      TabletSegmentDto(repeat: 3, picks: [uniformPick(4, 'F')]),
    ]);

const _mitten = NalbindRecipe(segments: [
  RecipeSegment(id: 'segment-1', kind: SegmentKind.centreStart, title: 'Tip', stitches: 8),
  RecipeSegment(
      id: 'segment-2', kind: SegmentKind.rounds, title: 'Hand', extent: Extent.rounds(12)),
  RecipeSegment(
      id: 'segment-3',
      kind: SegmentKind.finish,
      title: 'Cuff edge',
      finishMethod: FinishMethod.taperEdge),
], lastSegmentNumber: 3);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
    WidgetController.hitTestWarningShouldBeFatal = true;
  });
  tearDownAll(() => WidgetController.hitTestWarningShouldBeFatal = false);

  testWidgets('the band editor asks to save an unsaved band first', (tester) async {
    await openFresh(tester, TabletEditorScreen(initialDoc: threeForward()),
        overrides: [tabletRepositoryProvider.overrideWithValue(TabletRepository())]);
    await fromMenu(tester, 'More', '$kTabletTrackerTitle…');
    expect(find.text('Save the band first to keep your place.'), findsOneWidget);
    expect(find.byType(TabletTrackerScreen), findsNothing);
  });

  testWidgets('a tablet weaver works into the second time through and resumes after a restart',
      (tester) async {
    // The cards before a pick are read through their spoken labels.
    final semantics = tester.ensureSemantics();
    final bands = TabletRepository();
    final now = DateTime.now();
    final band = threeForward();
    final id = await bands.saveBand(
        doc: band,
        meta: DraftMeta(name: 'progress band', craft: kTabletCraft, savedAt: now, lastOpened: now));
    addTearDown(() => bands.deleteBand(id));
    final docs = await getApplicationDocumentsDirectory();
    final record = File(p.join(docs.path, 'tablets', '$id.plyprogress'));
    final overrides = [tabletRepositoryProvider.overrideWithValue(bands)];

    // From the editor's menu, on the saved band.
    final container = ProviderContainer(overrides: overrides);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
        container: container, child: MaterialApp(home: TabletEditorScreen(openId: id))));
    await settle(tester, frames: 40);
    await fromMenu(tester, 'More', '$kTabletTrackerTitle…');
    expect(find.byType(TabletTrackerScreen), findsOneWidget);
    await pumpUntil(tester, placeText('Pick 1'));
    expect(find.text('Every card forward.'), findsOneWidget);
    expect(find.byKey(const ValueKey('tablet-review-note')), findsOneWidget);
    expect(
        find.bySemanticsLabel(RegExp(r'^Card 1 now: A at the near top.*Twist 0')), findsOneWidget);
    for (var i = 0; i < 3; i++) {
      await tapKey(tester, 'tracker-next');
    }
    expect(placeText('Pick 1'), findsOneWidget);
    expect(find.text('of 3, time 2 through the band'), findsOneWidget);
    expect(find.byKey(const ValueKey('tracker-start-note')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'^Card 1 now: .*Twist \+3')), findsOneWidget);
    semantics.dispose();
    expect(record.existsSync(), isTrue);
    expect((await ProgressRepository().load(BackupCraft.tabletWeaving, id)).progress!.place,
        const PickPlace(1, repeat: 2));
    await tapKey(tester, 'tracker-next');

    // Back in the editor, the stepper is at the place.
    await tester.pageBack();
    await settle(tester, frames: 40);
    expect(container.read(tabletSavedPlaceProvider), const PickPlace(2, repeat: 2));
    expect(container.read(tabletPickProvider), 2);

    // Restart: a new scope reads the record and resumes at pick 2 of time 2.
    final saved = await bands.readBand(id);
    await openFresh(tester, TabletTrackerScreen(projectId: id, band: saved, name: 'progress band'));
    await pumpUntil(tester, placeText('Pick 2'));
    expect(find.text('of 3, time 2 through the band'), findsOneWidget);
    expect(find.byKey(const ValueKey('tracker-banner')), findsNothing);

    // An unsaved edit to the band (the written pick turned backward), which on time 2 is all
    // before the place: shown for checking, nothing written until the weaver says it is right.
    final edited = setTurns(saved, 0, 0, [0, 1, 2, 3], 'B');
    final before = record.readAsStringSync();
    await openFresh(
        tester,
        TabletTrackerScreen(
            projectId: id, band: edited, name: 'progress band', unsavedEdits: true));
    await pumpUntil(tester, find.byKey(const ValueKey('tracker-banner')));
    expect(placeText('Pick 2'), findsOneWidget, reason: 'never moved');
    // On time 2 the whole band was woven before the place.
    expect(find.textContaining('on time 2 through all of it was woven before your place'),
        findsOneWidget);
    expect(find.textContaining('unsaved changes to this band'), findsOneWidget);
    expect(record.readAsStringSync(), before);
    await tapKey(tester, 'tracker-right');
    expect(find.byKey(const ValueKey('tracker-banner')), findsNothing);

    // Deleting the band deletes its progress.
    await tester.pumpWidget(const SizedBox());
    await settle(tester, frames: 4);
    await bands.deleteBand(id);
    expect(record.existsSync(), isFalse);
  });

  testWidgets('a nalbinder works a recipe step by step and resumes after a restart',
      (tester) async {
    final projects = NalbindRepository();
    final overrides = [nalbindRepositoryProvider.overrideWithValue(projects)];
    final docs = await getApplicationDocumentsDirectory();

    // A project without a recipe has nothing to follow.
    final plain = await projects.saveProject(
        const NalbindProject(name: 'progress plain', notation: 'UO/UOO F1', notes: ''));
    addTearDown(() => projects.deleteProject(plain));
    await openFresh(tester, NalbindProjectScreen(openId: plain), overrides: overrides);
    await fromMenu(tester, 'More', '$kNalbindTrackerTitle…');
    expect(find.text(kNalbindNothingToTrack), findsOneWidget);
    expect(find.byType(NalbindFollowScreen), findsNothing);

    final id = await projects.saveProject(const NalbindProject(
        name: 'progress mitten',
        notation: 'UO/UOO F1',
        stitchName: 'Oslo',
        notes: '',
        recipe: _mitten));
    addTearDown(() => projects.deleteProject(id));
    final record = File(p.join(docs.path, 'nalbinds', '$id.plyprogress'));
    await openFresh(tester, NalbindProjectScreen(openId: id), overrides: overrides);
    await fromMenu(tester, 'More', '$kNalbindTrackerTitle…');
    expect(find.byType(NalbindFollowScreen), findsOneWidget);
    await pumpUntil(tester, find.text('Worked, next step'));
    expect(find.text('Centre start: Tip'), findsOneWidget);
    await tapKey(tester, 'follow-next');
    expect(find.text('Rounds: Hand'), findsOneWidget);
    expect(record.existsSync(), isTrue);
    expect((await ProgressRepository().load(BackupCraft.nalbinding, id)).progress!.place,
        const NalbindPlace(1, stepId: 'segment-2'));
    expect((await projects.readProject(id)).recipe!.done, isEmpty,
        reason: 'the place never ticks a step');

    // Restart: Follow opens at the place, not at the first step not done.
    await openFresh(tester, NalbindProjectScreen(openId: id), overrides: overrides);
    await tapKey(tester, 'project-follow');
    await pumpUntil(tester, find.text('Worked, next step'));
    expect(find.text('Rounds: Hand'), findsOneWidget);
    expect(find.byKey(const ValueKey('tracker-banner')), findsNothing);

    // A step inserted before the place: the place stays on its step, for checking.
    final saved = await projects.readProject(id);
    await projects.saveProject(
        saved.withRecipe(saved.recipe!.copyWith(segments: [
          const RecipeSegment(id: 'segment-4', kind: SegmentKind.centreStart, title: 'Thumb'),
          ...saved.recipe!.segments,
        ], lastSegmentNumber: 4)),
        id: id);
    await openFresh(tester, NalbindProjectScreen(openId: id), overrides: overrides);
    await tapKey(tester, 'project-follow');
    await pumpUntil(tester, find.byKey(const ValueKey('tracker-banner')));
    expect(find.text('Rounds: Hand'), findsOneWidget);
    expect(find.textContaining('now step 3 (it was step 2)'), findsOneWidget);
    await tapKey(tester, 'tracker-right');
    final p2 = (await ProgressRepository().load(BackupCraft.nalbinding, id)).progress!;
    expect(p2.place, const NalbindPlace(2, stepId: 'segment-2'));
    expect(p2.log.last.kind, LogKind.fix);

    // Deleting the project deletes its progress.
    await tester.pumpWidget(const SizedBox());
    await settle(tester, frames: 4);
    await projects.deleteProject(id);
    expect(record.existsSync(), isFalse);
  });
}
