import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:ply/src/data/library_backup.dart' show BackupCraft;
import 'package:ply/src/data/progress_repository.dart';
import 'package:ply/src/models/progress.dart';
import 'package:ply/src/rust/progress_dto.dart' show TabletWorkDto;
import 'package:ply/src/rust/tablet_dto.dart' show TabletDocumentDto;
import 'package:ply/src/screens/tablet_editor_screen.dart';
import 'package:ply/src/screens/tablet_tracker_screen.dart';
import 'package:ply/src/state/progress_controller.dart';
import 'package:ply/src/state/tablet_editor_providers.dart';
import 'package:ply/src/widgets/tablet_band_view.dart' show TabletCardTile;

import 'progress_test_support.dart';
import 'tablet_test_support.dart';

// Tablet weaving pick by pick (ADR 0023, ADR 0018 section 15) on the host, with the engine's work
// calls stood in: the tracker starts at pick 1, says what to turn and shows every card before the
// pick (to check them) and after it, keeps each pick at once in the band's own record, resumes there,
// works out each time through the band for that time (the cards start where the last time ended),
// shows a place the band changed under for checking without writing anything, says so plainly for a
// band with errors, and the editor's menu opens it for a saved band while its stepper shows the
// place and goes to it.

const id = '5d0e1a2b-1111-4222-8333-944455556666';

void main() {
  late Directory docs;
  late FakeWork work;
  late Oracle band1;
  setUpAll(() => band1 = Oracle('band-1-threaded-in'));
  File record() => File(p.join(docs.path, 'tablets', '$id.plyprogress'));
  Future<Progress> stored(WidgetTester tester) async => (await tester.runAsync(
          () => ProgressRepository(docsOverride: docs).load(BackupCraft.tabletWeaving, id)))!
      .progress!;
  Future<void> writeRecord(WidgetTester tester, Progress p) => tester.runAsync(
      () => ProgressRepository(docsOverride: docs).save(BackupCraft.tabletWeaving, id, p));
  Progress at(int pick, {int repeat = 1, String? prefix, int units = 6}) => Progress(
        craft: ProgressCraft.tabletWeaving,
        place: PickPlace(pick, repeat: repeat),
        basis: PlaceBasis(units: units, prefix: prefix ?? fakePrefix(pick)),
      );
  Finder place(String text) => find.descendant(
      of: find.byKey(const ValueKey('tracker-place')), matching: find.text(text), matchRoot: true);

  /// Scroll the tracker until [finder] is built and on screen (the card strips are tall).
  Future<void> reach(WidgetTester tester, Finder finder) => tester.scrollUntilVisible(finder, 200,
      scrollable: find
          .descendant(
              of: find.byKey(const ValueKey('tracker-body')), matching: find.byType(Scrollable))
          .first);
  Widget tracker({bool unsaved = false}) =>
      TabletTrackerScreen(projectId: id, band: band1.doc, name: 'Belt', unsavedEdits: unsaved);

  setUp(() async {
    docs = await projectFolder(BackupCraft.tabletWeaving, id);
    work = FakeWork();
  });
  tearDown(() => docs.delete(recursive: true));

  testWidgets('starts at pick 1 with what to turn and every card before and after it',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpTracker(tester, tracker(), trackerOverrides(docs, work));
    expect(
        find.bySemanticsLabel(RegExp(r'^Card 1 now: A at the near top.*Twist 0')), findsOneWidget);
    semantics.dispose();
    expect(place('Pick 1'), findsOneWidget);
    expect(find.text('of 6'), findsOneWidget);
    expect(find.text(fakeTurns(1)), findsOneWidget);
    expect(find.text('Segment 1, written pick 1, time 1 of 3'), findsOneWidget);
    expect(find.text('Check your cards before you turn'), findsOneWidget);
    expect(find.byKey(const ValueKey('tracker-card-before-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('tracker-card-before-1')), findsOneWidget);
    expect(find.byType(TabletCardTile), findsNWidgets(2), reason: 'every card after the pick');
    expect(find.byKey(const ValueKey('tablet-review-note')), findsOneWidget);
    expect(find.textContaining('Weft: colour 2'), findsOneWidget);
    expect(record().existsSync(), isFalse, reason: 'nothing written before the first pick');

    await tapAndSettle(tester, find.byKey(const ValueKey('tracker-next')));
    await tapAndSettle(tester, find.byKey(const ValueKey('tracker-next')));
    expect(place('Pick 3'), findsOneWidget);
    final p = await stored(tester);
    expect(p.craft, ProgressCraft.tabletWeaving);
    expect(p.place, const PickPlace(3));
    expect(p.basis, PlaceBasis(units: 6, prefix: fakePrefix(3)));
    expect(p.log.single.count, 2);
    await reach(tester, find.text('Pick 4: ${fakeTurns(4)}'));
    expect(find.text('Pick 4: ${fakeTurns(4)}'), findsOneWidget, reason: 'coming up');

    await tester.pumpWidget(const SizedBox());
    await pumpTracker(tester, tracker(), trackerOverrides(docs, work));
    expect(place('Pick 3'), findsOneWidget, reason: 'a new session resumes there');
  });

  testWidgets('the last pick leads to pick 1 of the next time through, worked out for that time',
      (tester) async {
    await writeRecord(tester, at(6));
    await pumpTracker(tester, tracker(), trackerOverrides(docs, work));
    await reach(tester, find.text('Then start again at pick 1.'));
    expect(find.text('Then start again at pick 1.'), findsOneWidget);
    expect(find.byKey(const ValueKey('tracker-start-note')), findsNothing);
    await tapAndSettle(tester, find.byKey(const ValueKey('tracker-next')));
    expect(place('Pick 1'), findsOneWidget);
    expect(find.text('of 6, time 2 through the band'), findsOneWidget);
    expect(work.tabletTimes.last, 2);
    expect(find.byKey(const ValueKey('tracker-start-note')), findsOneWidget);
    expect(find.byKey(const ValueKey('tracker-card-before-0')), findsOneWidget);
    expect((await stored(tester)).place, const PickPlace(1, repeat: 2));
    await tapAndSettle(tester, find.byKey(const ValueKey('tracker-previous')));
    expect(place('Pick 6'), findsOneWidget);
    expect(work.tabletTimes.last, 1);
  });

  testWidgets('Go to asks for the time through the band, and Undo puts the place back',
      (tester) async {
    await writeRecord(tester, at(2));
    await pumpTracker(tester, tracker(), trackerOverrides(docs, work));
    await tapAndSettle(tester, find.byKey(const ValueKey('tracker-goto')));
    expect(find.text('Time through the band'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('tracker-goto-pick')), '5');
    await tester.enterText(find.byKey(const ValueKey('tracker-goto-time')), '4');
    await tapAndSettle(tester, find.byKey(const ValueKey('tracker-goto-confirm')));
    expect(place('Pick 5'), findsOneWidget);
    expect(find.text('of 6, time 4 through the band'), findsOneWidget);
    expect((await stored(tester)).place, const PickPlace(5, repeat: 4));
    await tapAndSettle(tester, find.byKey(const ValueKey('tracker-undo')));
    expect(place('Pick 2'), findsOneWidget);
    expect((await stored(tester)).log, isEmpty);
  });

  testWidgets('a band changed before the place is shown for checking, nothing written until then',
      (tester) async {
    await writeRecord(tester, at(4, prefix: 'deadbeefdeadbeef'));
    final before = record().readAsStringSync();
    await pumpTracker(tester, tracker(), trackerOverrides(docs, work));
    expect(place('Pick 4'), findsOneWidget, reason: 'never moved');
    expect(find.textContaining('that your cards are as shown'), findsOneWidget);
    expect(record().readAsStringSync(), before);
    await tapAndSettle(tester, find.byKey(const ValueKey('tracker-right')));
    expect((await stored(tester)).basis!.prefix, fakePrefix(4));
  });

  testWidgets('a band with errors says so and keeps the place as it is', (tester) async {
    await writeRecord(tester, at(3));
    final before = record().readAsStringSync();
    work.tabletErrors = true;
    await pumpTracker(tester, tracker(), trackerOverrides(docs, work));
    expect(find.text(kTabletTrackerHasErrors), findsOneWidget);
    expect(find.byKey(const ValueKey('tracker-next')), findsNothing);
    expect(find.byKey(const ValueKey('tracker-start-again')), findsNothing);
    expect(record().readAsStringSync(), before);
  });

  testWidgets('a band with no picks says so; unsaved edits are said', (tester) async {
    work.tabletPicks = 0;
    await pumpTracker(tester, tracker(unsaved: true), trackerOverrides(docs, work));
    expect(find.text('This band has no picks to weave.'), findsOneWidget);
    work.tabletPicks = 6;
    await tester.pumpWidget(const SizedBox());
    await pumpTracker(tester, tracker(unsaved: true), trackerOverrides(docs, work));
    expect(
        find.text('You have unsaved changes to this band. Your place follows the band as it is '
            'on screen.'),
        findsOneWidget);
  });

  testWidgets('later windows of a time through are resumed from the engine\'s work states',
      (tester) async {
    work.tabletPicks = 80;
    await pumpTracker(tester, tracker(), trackerOverrides(docs, work));
    expect(work.tabletResumedFrom.single, isNull, reason: 'the first window works everything out');
    Future<void> goTo(int pick, int time) async {
      await tapAndSettle(tester, find.byKey(const ValueKey('tracker-goto')));
      await tester.enterText(find.byKey(const ValueKey('tracker-goto-pick')), '$pick');
      await tester.enterText(find.byKey(const ValueKey('tracker-goto-time')), '$time');
      await tapAndSettle(tester, find.byKey(const ValueKey('tracker-goto-confirm')));
    }

    await goTo(50, 1);
    expect(work.tabletResumedFrom.last, 31, reason: 'after the window before it');
    await goTo(1, 2);
    expect(work.tabletResumedFrom.last, isNull, reason: 'time 2 is worked out once');
    await goTo(60, 2);
    expect(work.tabletResumedFrom.last, 31);
    await goTo(2, 2);
    expect(work.tabletResumedFrom.last, 0, reason: 'back to the start of time 2, kept');
    expect(place('Pick 2'), findsOneWidget);
  });

  testWidgets('Next and Previous across windows resume from a state near the place, every time',
      (tester) async {
    // The review probe: 60 Nexts through an 80-pick band, on time 1 and on time 2, and back.
    work.tabletPicks = 80;
    await pumpTracker(tester, tracker(), trackerOverrides(docs, work));
    // One tap, and frames until the place has moved there.
    Future<void> step(String key, int pick, int time) async {
      bool ready() =>
          (tester.widget(find.byKey(ValueKey(key))) as ButtonStyleButton).onPressed != null;
      for (var i = 0; i < 40 && !ready(); i++) {
        await settle(tester, rounds: 1);
      }
      await tester.tap(find.byKey(ValueKey(key)));
      final there = find.text(time > 1 ? 'of 80, time $time through the band' : 'of 80');
      for (var i = 0;
          i < 40 && (place('Pick $pick').evaluate().isEmpty || there.evaluate().isEmpty);
          i++) {
        await settle(tester, rounds: 1);
      }
      expect(place('Pick $pick'), findsOneWidget);
    }

    for (var k = 2; k <= 80; k++) {
      await step('tracker-next', k, 1);
    }
    for (var k = 1; k <= 61; k++) {
      await step('tracker-next', k, 2);
    }
    final times = work.tabletTimes;
    final from = work.tabletResumedFrom;
    expect(times.where((t) => t == 1).length, greaterThan(2), reason: 'several windows a time');
    // Every window after the first of its time resumes from a state at most a window before it
    // (near the start of time 1 there is none to keep: the fold from the start is as short).
    final firsts = work.tabletFirsts;
    for (var i = 1; i < times.length; i++) {
      if (times[i] == times[i - 1] && firsts[i] > 33) {
        expect(from[i], isNotNull, reason: 'window $i (time ${times[i]}) resumed near the place');
        expect(firsts[i] - from[i]!, lessThanOrEqualTo(34), reason: 'a few dozen picks folded');
      }
    }
    expect(from[times.indexOf(2)], isNull, reason: 'the start of time 2 is worked out once');
    // Previous across a window's first pick, back into time 1.
    final asked = times.length;
    for (var k = 60; k >= 1; k--) {
      await step('tracker-previous', k, 2);
    }
    await step('tracker-previous', 80, 1);
    await step('tracker-previous', 79, 1);
    for (var i = asked; i < times.length; i++) {
      if (times[i] == 2 && firsts[i] > 33) {
        expect(from[i], isNotNull, reason: 'Previous resumed near the place');
        expect(firsts[i] - from[i]!, lessThanOrEqualTo(34));
      }
    }
  });

  testWidgets('Clear waits while a move is working out its window', (tester) async {
    final held = _HeldWork()..tabletPicks = 80;
    await pumpTracker(tester, tracker(), trackerOverrides(docs, held));
    held.hold = Completer<void>();
    await tester.tap(find.byKey(const ValueKey('tracker-goto')));
    await settle(tester);
    await tester.enterText(find.byKey(const ValueKey('tracker-goto-pick')), '60');
    await tester.tap(find.byKey(const ValueKey('tracker-goto-confirm')));
    await settle(tester);
    await tester.tap(find.byTooltip('More'));
    await settle(tester);
    final clear = tester.widget<PopupMenuItem<String>>(find.ancestor(
        of: find.text('Clear my place'), matching: find.byType(PopupMenuItem<String>)));
    expect(clear.enabled, isFalse, reason: 'not while the move is under way');
    await tester.tapAt(const Offset(10, 10));
    await settle(tester);
    held.hold!.complete();
    await settle(tester);
    expect(place('Pick 60'), findsOneWidget);
    expect((await stored(tester)).basis!.prefix, fakePrefix(60), reason: 'its own time\'s basis');
  });

  testWidgets('a long note is shown in full at its pick', (tester) async {
    work
      ..tabletNotePick = 2
      ..tabletNote = 'Lay in the gold brocade weft. ${'x' * 150} End.';
    await pumpTracker(tester, tracker(), trackerOverrides(docs, work));
    await tapAndSettle(tester, find.byKey(const ValueKey('tracker-next')));
    expect(place('Pick 2'), findsOneWidget);
    await tapAndSettle(tester, find.byKey(const ValueKey('tracker-full-words')));
    expect(work.tabletTimes, hasLength(2), reason: 'a window starting at the pick');
    await tapAndSettle(tester, find.text('The pattern\'s own words, in full'));
    expect(find.text(work.tabletNote), findsOneWidget);
  });

  testWidgets('an engine failure is said in words', (tester) async {
    work.tabletPicks = 80;
    await pumpTracker(tester, tracker(), trackerOverrides(docs, work));
    work.tabletErrors = true;
    await tapAndSettle(tester, find.byKey(const ValueKey('tracker-goto')));
    await tester.enterText(find.byKey(const ValueKey('tracker-goto-pick')), '70');
    await tapAndSettle(tester, find.byKey(const ValueKey('tracker-goto-confirm')));
    expect(find.text('Could not move to pick 70: $kTabletTrackerHasErrors'), findsOneWidget);
    expect(find.textContaining('Instance of'), findsNothing);
  });

  testWidgets('a note, the log and Clear', (tester) async {
    await pumpTracker(tester, tracker(), trackerOverrides(docs, work));
    await reach(tester, find.byKey(const ValueKey('tracker-add-note')));
    await tapAndSettle(tester, find.byKey(const ValueKey('tracker-add-note')));
    await tester.enterText(find.byKey(const ValueKey('tracker-note-field')), 'Untwisted the warp');
    await tapAndSettle(tester, find.byKey(const ValueKey('tracker-note-save')));
    expect((await stored(tester)).notes.single.place, const PickPlace(1));
    await tapAndSettle(tester, find.byKey(const ValueKey('tracker-next')));
    await tapAndSettle(tester, find.byTooltip('More'));
    await tapAndSettle(tester, find.text('Log'));
    expect(find.text('Worked 1 pick: pick 1 to pick 2'), findsOneWidget);
    await tester.tapAt(const Offset(20, 20));
    await settle(tester);
    await tapAndSettle(tester, find.byTooltip('More'));
    await tapAndSettle(tester, find.text('Clear my place'));
    await tapAndSettle(tester, find.byKey(const ValueKey('tracker-clear-confirm')));
    expect(record().existsSync(), isFalse);
    expect(find.text('Your place and notes for this band were cleared.'), findsOneWidget);
  });

  group('in the band editor', () {
    Future<ProviderContainer> pumpEditor(WidgetTester tester, FakeTabletRepo repo,
        {String? openId = id, List<Override> extra = const []}) async {
      tester.view.physicalSize = const Size(1200, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final c = ProviderContainer(overrides: [
        tabletRepositoryProvider.overrideWithValue(repo),
        ...extra,
      ]);
      addTearDown(c.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: MaterialApp(home: TabletEditorScreen(openId: openId, initialDoc: band1.doc)),
      ));
      await settle(tester);
      return c;
    }

    testWidgets('the menu opens the tracker on a saved band, and the stepper goes to the place',
        (tester) async {
      final repo = FakeTabletRepo(oracle: band1, stored: band1.doc);
      final memory = MemoryProgressRepository()
        ..records[(BackupCraft.tabletWeaving, id)] = at(4, repeat: 2);
      final c = await pumpEditor(tester, repo, extra: [
        progressRepositoryProvider.overrideWithValue(memory),
        ...trackerOverrides(docs, work).skip(1),
      ]);
      expect(c.read(tabletSavedPlaceProvider), const PickPlace(4, repeat: 2));
      // The Band tab: the place, and Show steps to it.
      await tester.tap(find.text('Band'));
      await settle(tester);
      expect(
          find.text('Your place: pick 4, time 2 through the band. The stepper shows the first time '
              'through.'),
          findsOneWidget);
      expect(c.read(tabletPickProvider), 1);
      await tapAndSettle(tester, find.byKey(const ValueKey('tablet-show-place')));
      expect(c.read(tabletPickProvider), 4);
      expect(c.read(tabletEditorProvider).isDirty, isFalse, reason: 'showing is not an edit');

      // The menu entry opens the tracker at the place; back in the editor the stepper is there.
      c.read(tabletPickProvider.notifier).state = 1;
      await tapAndSettle(tester, find.byTooltip('More'));
      await tapAndSettle(tester, find.text('$kTabletTrackerTitle…'));
      expect(find.byType(TabletTrackerScreen), findsOneWidget);
      expect(place('Pick 4'), findsOneWidget);
      await tapAndSettle(tester, find.byKey(const ValueKey('tracker-next')));
      expect(memory.records[(BackupCraft.tabletWeaving, id)]!.place, const PickPlace(5, repeat: 2));
      await tester.pageBack();
      await settle(tester);
      expect(c.read(tabletSavedPlaceProvider), const PickPlace(5, repeat: 2));
      expect(c.read(tabletPickProvider), 5);
      expect(c.read(tabletEditorProvider).isDirty, isFalse, reason: 'weaving is not an edit');
      expect(find.text('Leave without saving?'), findsNothing);
    });

    testWidgets('a place past the end of a shortened band says where Show goes', (tester) async {
      final repo = FakeTabletRepo(oracle: band1, stored: band1.doc);
      final memory = MemoryProgressRepository()
        ..records[(BackupCraft.tabletWeaving, id)] = at(40, units: 40);
      final c = await pumpEditor(tester, repo,
          extra: [progressRepositoryProvider.overrideWithValue(memory)]);
      await tester.tap(find.text('Band'));
      await settle(tester);
      final total = band1.picks;
      expect(
          find.text('Your place: pick 40. The band now has $total picks: Show goes to pick '
              '$total, and Weave pick by pick asks you to check your place.'),
          findsOneWidget);
      await tapAndSettle(tester, find.byKey(const ValueKey('tablet-show-place')));
      expect(c.read(tabletPickProvider), total);
    });

    testWidgets('an unsaved band is asked to be saved first', (tester) async {
      final repo = FakeTabletRepo(oracle: band1);
      await pumpEditor(tester, repo, openId: null, extra: [
        progressRepositoryProvider.overrideWithValue(MemoryProgressRepository()),
      ]);
      await tapAndSettle(tester, find.byTooltip('More'));
      await tapAndSettle(tester, find.text('$kTabletTrackerTitle…'));
      expect(find.byType(TabletTrackerScreen), findsNothing);
      expect(find.text('Save the band first to keep your place.'), findsOneWidget);
    });
  });

  test('place words and the file it keeps', () {
    expect(tabletPlaceWords(const PickPlace(9, repeat: 3)), 'pick 9, time 3');
    final json = jsonDecode(at(2).encodeFitted().text) as Map<String, dynamic>;
    expect(json['craft'], 'tablet_weaving');
  });
}

/// The work stand-in, holding a tablet window back until [hold] completes.
class _HeldWork extends FakeWork {
  Completer<void>? hold;

  @override
  Future<TabletWorkDto> tabletWindow(TabletDocumentDto band, int first, int last, int time,
      {Uint8List? from}) async {
    await hold?.future;
    return super.tabletWindow(band, first, last, time, from: from);
  }
}
