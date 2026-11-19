// M8-05 device proof (ADR 0023): a weaver's and a knitter's place survive a restart, through the
// real engine, the editors' menus and the device's file system, fully offline.
//
// Weaving: the editor's menu asks to save an unsaved draft first; a saved twill opened from the menu
// is woven pick by pick; a fresh tracker (new provider scope, new repositories: what an app restart
// reads) resumes at the same pick with what to press for it, and Undo after the restart steps back;
// picks removed under the place show it at the last pick for checking, nothing written until the
// weaver says; a sinking-shed edit not yet saved is followed (and said) with the counterbalance
// words; deleting the draft deletes its progress.
// Knitting: the editor's menu asks to save an unsaved pattern first; a saved pattern with a section
// (its notes, the cast-on, a run of rows and a bind-off) is knitted row by row through the real
// engine, resumes after a restart, follows an unsaved edit and says so; deleting the pattern deletes
// its progress. A chart-only pattern is knitted into its second time through and resumes there.
//
//   flutter test integration_test/m8_progress_test.dart -d emulator-5554

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
import 'package:ply/src/data/progress_repository.dart';
import 'package:ply/src/models/draft_doc.dart';
import 'package:ply/src/models/draft_meta.dart';
import 'package:ply/src/models/knit_stitches.dart';
import 'package:ply/src/models/progress.dart';
import 'package:ply/src/rust/frb_generated.dart';
import 'package:ply/src/rust/knit_dto.dart';
import 'package:ply/src/screens/editor_screen.dart';
import 'package:ply/src/screens/knit_editor_screen.dart';
import 'package:ply/src/screens/knit_tracker_screen.dart';
import 'package:ply/src/screens/weave_tracker_screen.dart';
import 'package:ply/src/state/editor_providers.dart';
import 'package:ply/src/state/knit_editor_providers.dart';
import 'package:ply/src/state/knit_editor_state.dart';

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

Future<void> tapKey(WidgetTester tester, String key) async {
  await tester.tap(find.byKey(ValueKey(key)));
  await settle(tester);
}

/// Pump frames until [finder] finds something, for at most [seconds]. A screen's actions appear only
/// once its pattern has loaded, which takes longer on the first test after a cold start.
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

/// Choose [entry] in the screen's overflow menu ([tooltip] names its button).
Future<void> fromMenu(WidgetTester tester, String tooltip, String entry) async {
  await pumpUntil(tester, find.byTooltip(tooltip));
  await tester.tap(find.byTooltip(tooltip));
  await settle(tester);
  await pumpUntil(tester, find.text(entry));
  await tester.tap(find.text(entry));
  await settle(tester, frames: 40);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
    // A tap that would land on another widget fails where it happens instead of later.
    WidgetController.hitTestWarningShouldBeFatal = true;
  });
  tearDownAll(() => WidgetController.hitTestWarningShouldBeFatal = false);

  testWidgets('the weaving editor asks to save an unsaved draft first', (tester) async {
    // The app provides the draft repository at its root; a test that opens the editor must too.
    await openFresh(tester, const EditorScreen(wifText: kTwillWif, title: 'Not saved'),
        overrides: [repositoryProvider.overrideWithValue(DraftRepository())]);
    await fromMenu(tester, 'More actions', '$kWeaveTrackerTitle…');
    expect(find.text('Save the draft first to keep your place.'), findsOneWidget);
    expect(find.byType(WeaveTrackerScreen), findsNothing);
  });

  testWidgets('a weaver resumes at the same pick after a restart', (tester) async {
    final drafts = DraftRepository();
    final now = DateTime.now();
    final meta = DraftMeta(name: 'progress twill', savedAt: now, lastOpened: now);
    final doc = await drafts.parseDoc(kTwillWif);
    final id = await drafts.saveDto(doc, meta: meta, sourceWif: kTwillWif);
    addTearDown(() => drafts.delete(id));
    final docs = await getApplicationDocumentsDirectory();
    final record = File(p.join(docs.path, 'drafts', '$id.plyprogress'));
    final overrides = [repositoryProvider.overrideWithValue(drafts)];

    // From the editor's menu, on the saved draft.
    await openFresh(
        tester, EditorScreen(wifText: kTwillWif, title: 'progress twill', id: id, meta: meta),
        overrides: overrides);
    await fromMenu(tester, 'More actions', '$kWeaveTrackerTitle…');
    expect(find.byType(WeaveTrackerScreen), findsOneWidget);
    expect(find.textContaining('unsaved changes'), findsNothing);
    expect(placeText('Pick 1'), findsOneWidget);
    expect(find.text('Press treadle 1: shafts 1 and 2 rise.'), findsOneWidget);
    await tapKey(tester, 'tracker-next');
    await tapKey(tester, 'tracker-next');
    expect(placeText('Pick 3'), findsOneWidget);
    expect(find.text('Press treadle 3: shafts 3 and 4 rise.'), findsOneWidget);
    expect(record.existsSync(), isTrue);

    // Restart: a new scope reads the record from disk and resumes at pick 3; Undo still works.
    Widget tracker() =>
        WeaveTrackerScreen(projectId: id, draft: drafts.toDto(doc), name: 'progress twill');
    await openFresh(tester, tracker());
    expect(placeText('Pick 3'), findsOneWidget);
    expect(find.byKey(const ValueKey('tracker-banner')), findsNothing);
    await tapKey(tester, 'tracker-undo');
    expect(placeText('Pick 2'), findsOneWidget);
    expect((await ProgressRepository().load(BackupCraft.weaving, id)).progress!.place,
        const PickPlace(2));

    // Weave on to pick 4, then remove two picks from the draft: the place is shown at pick 2 for
    // checking, and the record keeps pick 4 until the weaver says.
    await tapKey(tester, 'tracker-next');
    await tapKey(tester, 'tracker-next');
    expect(placeText('Pick 4'), findsOneWidget);
    final drive = doc.drive as DraftTreadled;
    final shorter = drafts.toDto(doc.copyWith(
      drive: DraftTreadled(tieup: drive.tieup, treadling: drive.treadling.sublist(0, 2)),
      weftColors: doc.weftColors.sublist(0, 2),
    ));
    await openFresh(
        tester, WeaveTrackerScreen(projectId: id, draft: shorter, name: 'progress twill'));
    expect(placeText('Pick 2'), findsOneWidget);
    expect(find.textContaining('Your place was pick 4, but the draft now has 2 picks'),
        findsOneWidget);
    final before = await ProgressRepository().load(BackupCraft.weaving, id);
    expect(before.progress!.place, const PickPlace(4));
    await tapKey(tester, 'tracker-right');
    final after = await ProgressRepository().load(BackupCraft.weaving, id);
    expect(after.progress!.place, const PickPlace(2));
    expect(after.progress!.log.last.kind, LogKind.fix);

    // An unsaved edit in the editor (the loom switched to a sinking shed) is followed and said.
    await openFresh(
        tester, EditorScreen(wifText: kTwillWif, title: 'progress twill', id: id, meta: meta),
        overrides: overrides);
    await pumpUntil(tester, find.byTooltip('More actions'));
    await tester.tap(find.byTooltip('More actions'));
    await settle(tester);
    // Tap the menu item itself: its label alone is not what receives the tap.
    await tester.tap(find.ancestor(
        of: find.text('Sinking shed'),
        matching: find.byWidgetPredicate((w) => w is CheckedPopupMenuItem)));
    await settle(tester);
    await fromMenu(tester, 'More actions', '$kWeaveTrackerTitle…');
    expect(find.textContaining('unsaved changes to this draft'), findsOneWidget);
    await tapKey(tester, 'tracker-goto');
    await tester.enterText(find.byKey(const ValueKey('tracker-goto-pick')), '1');
    await tapKey(tester, 'tracker-goto-confirm');
    expect(find.text('Press treadle 1: shafts 1 and 2 go down, so shafts 3 and 4 are up.'),
        findsOneWidget);

    // Deleting the draft deletes its progress.
    await tester.pumpWidget(const SizedBox());
    await settle(tester, frames: 4);
    await drafts.delete(id);
    expect(record.existsSync(), isFalse);
  });

  testWidgets('the knitting editor asks to save an unsaved pattern first', (tester) async {
    await openFresh(tester, const KnitEditorScreen());
    await fromMenu(tester, 'More', '$kKnitTrackerTitle…');
    expect(find.text('Save the pattern first to keep your place.'), findsOneWidget);
    expect(find.byType(KnitTrackerScreen), findsNothing);
  });

  testWidgets('a knitter works a section row by row and resumes after a restart', (tester) async {
    final knits = KnitRepository();
    final blank = await knits.blank();
    final chart = KnitEditorState(pattern: blank).resizeChart(4, 2).pattern;
    final pattern = KnitPatternDto(
      name: 'progress cuff',
      construction: blank.construction,
      firstRowSide: blank.firstRowSide,
      castOn: 20,
      gauge: blank.gauge,
      palette: blank.palette,
      legend: blank.legend,
      chart: chart.chart,
      notes: '',
      sections: const [
        KnitSectionDto(
          id: 'section-1',
          name: 'Cuff',
          notes: 'Change to the smaller needles.',
          steps: [
            KnitStepDto(id: 'step-1', action: KnitStepActionDto.rows(count: 6, text: 'k2, p2 rib')),
            KnitStepDto(id: 'step-2', action: KnitStepActionDto.bindOff(resolveTurns: false)),
          ],
        ),
      ],
      pieces: const [],
    );
    final now = DateTime.now();
    final id = await knits.saveKnit(
      pattern: pattern,
      meta: DraftMeta(name: 'progress cuff', craft: 'Knitting', savedAt: now, lastOpened: now),
    );
    addTearDown(() => knits.deleteKnit(id));
    final docs = await getApplicationDocumentsDirectory();
    final record = File(p.join(docs.path, 'knits', '$id.plyprogress'));

    // From the editor's menu, through the real engine's work and ledger.
    await openFresh(tester, KnitEditorScreen(openId: id));
    await fromMenu(tester, 'More', '$kKnitTrackerTitle…');
    expect(find.byType(KnitTrackerScreen), findsOneWidget);
    expect(find.text('Section 1: Cuff'), findsOneWidget);
    expect(find.text('Notes: Change to the smaller needles.'), findsOneWidget);
    expect(find.text('Before you start: Cast on 20 sts.'), findsOneWidget);
    expect(placeText('Row 1 of 6'), findsOneWidget);
    await tapKey(tester, 'tracker-next');
    await tapKey(tester, 'tracker-next');
    expect(placeText('Row 3 of 6'), findsOneWidget);

    // Restart, then Undo after it.
    Widget tracker() => KnitTrackerScreen(projectId: id, pattern: pattern, name: 'progress cuff');
    await openFresh(tester, tracker());
    expect(placeText('Row 3 of 6'), findsOneWidget);
    await tapKey(tester, 'tracker-undo');
    expect(placeText('Row 2 of 6'), findsOneWidget);
    final read = await ProgressRepository().load(BackupCraft.knitting, id);
    expect(
        read.progress!.place, const KnitPlace(0, row: 2, sectionId: 'section-1', stepId: 'step-1'));

    // An unsaved edit in the editor is followed and said.
    await openFresh(tester, KnitEditorScreen(openId: id));
    final container = ProviderScope.containerOf(tester.element(find.byType(KnitEditorScreen)));
    container.read(knitEditorProvider.notifier).paintCell(0, 0, KnitStitch.purl, null);
    await settle(tester);
    await fromMenu(tester, 'More', '$kKnitTrackerTitle…');
    expect(find.textContaining('unsaved changes to this pattern'), findsOneWidget);

    // Deleting the pattern deletes its progress.
    await tester.pumpWidget(const SizedBox());
    await settle(tester, frames: 4);
    expect(record.existsSync(), isTrue);
    await knits.deleteKnit(id);
    expect(record.existsSync(), isFalse);
  });

  testWidgets('a knitter resumes at the same row and time through the chart after a restart',
      (tester) async {
    final knits = KnitRepository();
    final blank = await knits.blank();
    final pattern = KnitEditorState(pattern: blank).resizeChart(4, 2).pattern;
    final now = DateTime.now();
    final id = await knits.saveKnit(
      pattern: pattern,
      meta: DraftMeta(name: 'progress swatch', craft: 'Knitting', savedAt: now, lastOpened: now),
    );
    addTearDown(() => knits.deleteKnit(id));

    Widget tracker() => KnitTrackerScreen(projectId: id, pattern: pattern, name: 'progress swatch');

    await openFresh(tester, tracker());
    expect(placeText('Row 1 (RS)'), findsOneWidget);
    await tapKey(tester, 'tracker-next');
    await tapKey(tester, 'tracker-next');
    expect(placeText('Row 1 (RS)'), findsOneWidget, reason: 'two rows: the sides do not change');
    expect(find.text('of 2 rows, time 2 through the chart'), findsOneWidget);

    await openFresh(tester, tracker());
    expect(placeText('Row 1 (RS)'), findsOneWidget);
    expect(find.text('of 2 rows, time 2 through the chart'), findsOneWidget);
    final read = await ProgressRepository().load(BackupCraft.knitting, id);
    expect(read.progress!.place, const KnitPlace(0, repeat: 2));
    expect(read.progress!.log.single.count, 2);
  });
}
