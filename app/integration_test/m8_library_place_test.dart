// ADR 0023 follow-up 3 device proof: each library tile shows the place its project's progress record
// keeps, and opens the project straight into its tracker, through the real engines, the libraries,
// the editors and the device's file system, fully offline.
//
// Weaving: a saved twill's tile has no place; its menu opens Weave pick by pick through the editor;
// two picks woven, back is the editor and back again the library, whose tile now says Pick 3 of 4,
// updated today; after a restart (a new provider scope) the tile says so again and its place opens
// the tracker at pick 3; a rename keeps the place; a record that cannot be read says so on the tile
// and is left as it is; deleting the draft deletes its progress and its tile.
// Knitting, tablet weaving and nalbinding: a saved pattern, band and recipe are each opened from
// their tile's menu into Knit row by row, Weave pick by pick and Nalbind step by step, worked one
// unit, and their tiles then show Chart row 2 of 2, Pick 2 of 3 and Step 2 of 3; the tablet band's
// stepper is at the place when the tracker closes; each place opens the tracker again.
//
//   flutter test integration_test/m8_library_place_test.dart -d emulator-5554

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:ply/src/data/draft_repository.dart';
import 'package:ply/src/data/knit_repository.dart';
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
import 'package:ply/src/screens/editor_screen.dart';
import 'package:ply/src/screens/knit_editor_screen.dart';
import 'package:ply/src/screens/knit_library_screen.dart';
import 'package:ply/src/screens/knit_tracker_screen.dart';
import 'package:ply/src/screens/library_screen.dart';
import 'package:ply/src/screens/nalbind_follow_screen.dart';
import 'package:ply/src/screens/nalbind_project_screen.dart';
import 'package:ply/src/screens/nalbind_reference_screen.dart';
import 'package:ply/src/screens/tablet_editor_screen.dart';
import 'package:ply/src/screens/tablet_library_screen.dart';
import 'package:ply/src/screens/tablet_tracker_screen.dart';
import 'package:ply/src/screens/weave_tracker_screen.dart';
import 'package:ply/src/state/editor_providers.dart';
import 'package:ply/src/state/knit_editor_providers.dart';
import 'package:ply/src/state/knit_editor_state.dart';
import 'package:ply/src/state/nalbind_providers.dart';
import 'package:ply/src/state/tablet_editor_providers.dart';
import 'package:ply/src/widgets/library_place.dart';

const String kTwillWif = '''[WIF]
Version=1.1
[WEAVING]
Shafts=4
Treadles=4
Rising Shed=true
[WARP]
Threads=4
Units=Inches
[WEFT]
Threads=4
[COLOR TABLE]
1=0,0,0
2=255,255,255
[THREADING]
1=1
2=2
3=3
4=4
[TIEUP]
1=1,2
2=2,3
3=3,4
4=1,4
[TREADLING]
1=1
2=2
3=3
4=4
[WARP COLORS]
1=1
2=1
3=1
4=1
[WEFT COLORS]
1=2
2=2
3=2
4=2
''';

Finder placeText(String text) => find.descendant(
    of: find.byKey(const ValueKey('tracker-place')), matching: find.text(text), matchRoot: true);

/// A tile's saved place, and a line of it.
Finder placeLine(String id) => find.byKey(ValueKey('library-place-$id'));
Finder placeSays(String id, String text) =>
    find.descendant(of: placeLine(id), matching: find.text(text));

/// The tile (a card) that shows [name].
Finder tileOf(String name) => find.ancestor(of: find.text(name), matching: find.byType(Card)).first;

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

Future<void> tapOn(WidgetTester tester, Finder f) async {
  await pumpUntil(tester, f);
  await tester.ensureVisible(f);
  await settle(tester, frames: 4);
  await tester.tap(f);
  await settle(tester, frames: 40);
}

Future<void> tapKey(WidgetTester tester, String key) => tapOn(tester, find.byKey(ValueKey(key)));

/// Choose [entry] in the menu of the tile showing [name] ([tooltip] names its button).
Future<void> fromTileMenu(WidgetTester tester, String name, String tooltip, String entry) async {
  await pumpUntil(tester, find.text(name));
  await tapOn(tester, find.descendant(of: tileOf(name), matching: find.byTooltip(tooltip)));
  await tapOn(tester, find.text(entry).last);
}

/// Back one screen.
Future<void> back(WidgetTester tester) async {
  await tester.pageBack();
  await settle(tester, frames: 40);
}

/// Four cards turned forward three picks.
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
    // A tap that would land on another widget fails where it happens instead of later.
    WidgetController.hitTestWarningShouldBeFatal = true;
  });
  tearDownAll(() => WidgetController.hitTestWarningShouldBeFatal = false);

  testWidgets('a weaving tile shows the place and opens the tracker at it', (tester) async {
    final drafts = DraftRepository();
    final now = DateTime.now();
    const name = 'library place twill';
    final meta = DraftMeta(name: name, savedAt: now, lastOpened: now);
    final id =
        await drafts.saveDto(await drafts.parseDoc(kTwillWif), meta: meta, sourceWif: kTwillWif);
    addTearDown(() => drafts.delete(id));
    final docs = await getApplicationDocumentsDirectory();
    final record = File(p.join(docs.path, 'drafts', '$id.plyprogress'));
    final overrides = [repositoryProvider.overrideWithValue(drafts)];
    Widget library() => LibraryScreen(repository: drafts);

    // No record yet: no place on the tile. Its menu opens the tracker through the editor.
    await openFresh(tester, library(), overrides: overrides);
    await pumpUntil(tester, find.text(name));
    expect(placeLine(id), findsNothing);
    await fromTileMenu(tester, name, 'Pattern actions', kWeaveTrackerTitle);
    await pumpUntil(tester, placeText('Pick 1'));
    expect(find.byType(WeaveTrackerScreen), findsOneWidget);
    expect(find.textContaining('unsaved changes'), findsNothing);
    await tapKey(tester, 'tracker-next');
    await tapKey(tester, 'tracker-next');
    expect(placeText('Pick 3'), findsOneWidget);

    // Back is the editor, and back again the library, whose tile reads the place again.
    await back(tester);
    expect(find.byType(WeaveTrackerScreen), findsNothing);
    expect(find.byType(EditorScreen), findsOneWidget);
    await back(tester);
    await pumpUntil(tester, placeSays(id, 'Pick 3 of 4'));
    expect(placeSays(id, 'Updated today'), findsOneWidget);

    // After a restart the tile reads it from disk; the place opens the tracker there.
    await openFresh(tester, library(), overrides: overrides);
    await pumpUntil(tester, placeSays(id, 'Pick 3 of 4'));
    await tapOn(tester, placeLine(id));
    await pumpUntil(tester, placeText('Pick 3'));
    await back(tester);
    await back(tester);

    // A rename keeps the place.
    await fromTileMenu(tester, name, 'Pattern actions', 'Rename');
    await tester.enterText(find.byType(TextField), 'library place towel');
    await tapOn(tester, find.widgetWithText(FilledButton, 'Rename'));
    await pumpUntil(tester, find.text('library place towel'));
    await pumpUntil(tester, placeSays(id, 'Pick 3 of 4'));

    // A record that cannot be read says so, and is left as it is.
    record.writeAsStringSync('{"format":"ply.progress"');
    await openFresh(tester, library(), overrides: overrides);
    await pumpUntil(tester, placeSays(id, kLibraryPlaceUnreadable));
    expect(record.readAsStringSync(), '{"format":"ply.progress"');

    // Deleting the draft deletes its progress and its tile.
    await fromTileMenu(tester, 'library place towel', 'Pattern actions', 'Delete');
    await tapOn(tester, find.widgetWithText(FilledButton, 'Delete'));
    expect(find.text('library place towel'), findsNothing);
    expect(record.existsSync(), isFalse);
  });

  testWidgets('a knitting tile opens Knit row by row and then shows the place', (tester) async {
    final knits = KnitRepository();
    final blank = await knits.blank();
    final pattern = KnitEditorState(pattern: blank).resizeChart(4, 2).pattern;
    final now = DateTime.now();
    const name = 'library place swatch';
    final id = await knits.saveKnit(
      pattern: pattern,
      meta: DraftMeta(name: name, craft: 'Knitting', savedAt: now, lastOpened: now),
    );
    addTearDown(() => knits.deleteKnit(id));
    final overrides = [knitRepositoryProvider.overrideWithValue(knits)];

    await openFresh(tester, const KnitLibraryScreen(), overrides: overrides);
    await fromTileMenu(tester, name, 'Pattern actions', kKnitTrackerTitle);
    await pumpUntil(tester, find.byType(KnitTrackerScreen));
    expect(find.byType(KnitEditorScreen, skipOffstage: false), findsOneWidget,
        reason: 'opened through the editor, which is under the tracker');
    await tapKey(tester, 'tracker-next');
    await back(tester);
    expect(find.byType(KnitTrackerScreen), findsNothing);
    await back(tester);
    await pumpUntil(tester, placeSays(id, 'Chart row 2 of 2'));
    expect(placeSays(id, 'Updated today'), findsOneWidget);

    await tapOn(tester, placeLine(id));
    await pumpUntil(tester, find.byType(KnitTrackerScreen));
    expect((await ProgressRepository().load(BackupCraft.knitting, id)).progress!.place,
        isA<KnitPlace>().having((k) => k.unit, 'unit', 1));
    await back(tester);
    await back(tester);
  });

  testWidgets('a tablet weaving tile opens the tracker; back, the stepper is at the place',
      (tester) async {
    final bands = TabletRepository();
    final now = DateTime.now();
    const name = 'library place band';
    final id = await bands.saveBand(
        doc: threeForward(),
        meta: DraftMeta(name: name, craft: kTabletCraft, savedAt: now, lastOpened: now));
    addTearDown(() => bands.deleteBand(id));
    final container =
        ProviderContainer(overrides: [tabletRepositoryProvider.overrideWithValue(bands)]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
        container: container, child: const MaterialApp(home: TabletLibraryScreen())));
    await settle(tester, frames: 40);

    await fromTileMenu(tester, name, 'Band actions', kTabletTrackerTitle);
    await pumpUntil(tester, placeText('Pick 1'));
    expect(find.byType(TabletEditorScreen, skipOffstage: false), findsOneWidget,
        reason: 'opened through the editor, which is under the tracker');
    await tapKey(tester, 'tracker-next');
    await back(tester);
    expect(find.byType(TabletTrackerScreen), findsNothing);
    expect(container.read(tabletPickProvider), 2);
    await back(tester);
    await pumpUntil(tester, placeSays(id, 'Pick 2 of 3'));

    await tapOn(tester, placeLine(id));
    await pumpUntil(tester, placeText('Pick 2'));
    await back(tester);
    await back(tester);
  });

  testWidgets('a nalbinding project opens Nalbind step by step and then shows the place',
      (tester) async {
    final projects = NalbindRepository();
    const name = 'library place mitten';
    final id = await projects.saveProject(const NalbindProject(
        name: name, notation: 'UO/UOO F1', stitchName: 'Oslo', notes: '', recipe: _mitten));
    addTearDown(() => projects.deleteProject(id));
    final overrides = [nalbindRepositoryProvider.overrideWithValue(projects)];

    await openFresh(tester, const Scaffold(body: NalbindReferenceScreen()), overrides: overrides);
    await fromTileMenu(tester, name, 'Project actions', kNalbindTrackerTitle);
    await pumpUntil(tester, find.text('Worked, next step'));
    expect(find.byType(NalbindFollowScreen), findsOneWidget);
    expect(find.byType(NalbindProjectScreen, skipOffstage: false), findsOneWidget,
        reason: 'opened through the project, which is under the tracker');
    await tapKey(tester, 'follow-next');
    expect(find.text('Rounds: Hand'), findsOneWidget);
    await back(tester);
    expect(find.byType(NalbindFollowScreen), findsNothing);
    await back(tester);
    await pumpUntil(tester, placeSays(id, 'Step 2 of 3'));

    await tapOn(tester, placeLine(id));
    await pumpUntil(tester, find.text('Rounds: Hand'));
    await back(tester);
    await back(tester);
  });
}
