import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:ply/src/data/draft_repository.dart';
import 'package:ply/src/data/library_backup.dart' show BackupCraft;
import 'package:ply/src/data/progress_repository.dart';
import 'package:ply/src/models/progress.dart';
import 'package:ply/src/rust/dto.dart';
import 'package:ply/src/screens/weave_tracker_screen.dart';

import 'pick_roles_support.dart';
import 'progress_test_support.dart';

// Weaving pick by pick (ADR 0023) on the host, with the engine's work calls stood in: the tracker
// starts at pick 1, keeps each pick at once in the project's own record, resumes there in a new
// session (an app restart), wraps to the next time through the draft, corrects with Previous, sets
// the place with Go to and puts it back with Undo, shows a place the draft changed under for checking
// without writing anything until the weaver says, never replaces a newer record, starts again over an
// unreadable one, and keeps notes and clears.

const id = '7a0c2d4e-1111-4222-8333-944455556666';

DraftDto draft() => DraftRepository().toDto(generatedOvershot(picks: 6));

Widget tracker() => WeaveTrackerScreen(projectId: id, draft: draft(), name: 'Towel');

void main() {
  late Directory docs;
  late FakeWork work;
  File record() => File(p.join(docs.path, 'drafts', '$id.plyprogress'));
  // Real file I/O runs outside the test's fake clock.
  Future<Progress> stored(WidgetTester tester) async => (await tester
          .runAsync(() => ProgressRepository(docsOverride: docs).load(BackupCraft.weaving, id)))!
      .progress!;
  Future<void> writeRecord(WidgetTester tester, Progress p) => tester
      .runAsync(() => ProgressRepository(docsOverride: docs).save(BackupCraft.weaving, id, p));
  Progress at(int pick, {String? prefix, int units = 6}) => Progress(
        craft: ProgressCraft.weaving,
        place: PickPlace(pick),
        basis: PlaceBasis(units: units, prefix: prefix ?? fakePrefix(pick)),
      );
  Finder place(String text) => find.descendant(
      of: find.byKey(const ValueKey('tracker-place')), matching: find.text(text), matchRoot: true);

  setUp(() async {
    docs = await projectFolder(BackupCraft.weaving, id);
    work = FakeWork(picks: 6);
  });
  tearDown(() => docs.delete(recursive: true));

  testWidgets('starts at pick 1 and keeps each pick at once; a new session resumes there',
      (tester) async {
    await pumpTracker(tester, tracker(), trackerOverrides(docs, work));
    expect(place('Pick 1'), findsOneWidget);
    expect(find.text(FakeWork.actionOf(1)), findsOneWidget);
    expect(find.text('Coming up'), findsOneWidget);
    expect(record().existsSync(), isFalse, reason: 'nothing written before the first pick');

    await tapAndSettle(tester, find.byKey(const ValueKey('tracker-next')));
    await tapAndSettle(tester, find.byKey(const ValueKey('tracker-next')));
    expect(place('Pick 3'), findsOneWidget);
    expect(find.text(FakeWork.actionOf(3)), findsOneWidget);
    final p = await stored(tester);
    expect(p.place, const PickPlace(3));
    expect(p.basis, PlaceBasis(units: 6, prefix: fakePrefix(3)));
    expect(p.log.single.kind, LogKind.worked);
    expect(p.log.single.count, 2);

    // The app is closed and opened again: a new screen reads the record from disk.
    await tester.pumpWidget(const SizedBox());
    await pumpTracker(tester, tracker(), trackerOverrides(docs, work));
    expect(place('Pick 3'), findsOneWidget);
    expect(find.byKey(const ValueKey('tracker-banner')), findsNothing);
  });

  testWidgets('the last pick leads to pick 1 of the next time through, and back again',
      (tester) async {
    await writeRecord(tester, at(6));
    await pumpTracker(tester, tracker(), trackerOverrides(docs, work));
    expect(place('Pick 6'), findsOneWidget);
    expect(find.text('Then start again at pick 1.'), findsOneWidget);
    await tapAndSettle(tester, find.byKey(const ValueKey('tracker-next')));
    expect(place('Pick 1'), findsOneWidget);
    expect(find.text('of 6, time 2 through the draft'), findsOneWidget);
    expect((await stored(tester)).place, const PickPlace(1, repeat: 2));
    await tapAndSettle(tester, find.byKey(const ValueKey('tracker-previous')));
    expect(place('Pick 6'), findsOneWidget);
    final p = await stored(tester);
    expect(p.place, const PickPlace(6));
    expect(p.log.last.kind, LogKind.back);
  });

  testWidgets('Go to sets the place and Undo puts it back', (tester) async {
    await writeRecord(tester, at(2));
    await pumpTracker(tester, tracker(), trackerOverrides(docs, work));
    await tapAndSettle(tester, find.byKey(const ValueKey('tracker-goto')));
    await tester.enterText(find.byKey(const ValueKey('tracker-goto-pick')), '5');
    await tapAndSettle(tester, find.byKey(const ValueKey('tracker-goto-confirm')));
    expect(place('Pick 5'), findsOneWidget);
    expect((await stored(tester)).log.last.kind, LogKind.jump);

    await tapAndSettle(tester, find.byKey(const ValueKey('tracker-undo')));
    expect(place('Pick 2'), findsOneWidget);
    final p = await stored(tester);
    expect(p.place, const PickPlace(2));
    expect(p.log, isEmpty);
  });

  testWidgets('Go to refuses a pick the draft does not have', (tester) async {
    await pumpTracker(tester, tracker(), trackerOverrides(docs, work));
    await tapAndSettle(tester, find.byKey(const ValueKey('tracker-goto')));
    await tester.enterText(find.byKey(const ValueKey('tracker-goto-pick')), '9');
    await tapAndSettle(tester, find.byKey(const ValueKey('tracker-goto-confirm')));
    expect(find.text('Give a pick from 1 to 6.'), findsOneWidget);
  });

  testWidgets(
      'a draft changed before the place is shown for checking; nothing is written until '
      'the weaver says it is right', (tester) async {
    await writeRecord(tester, at(4, prefix: 'deadbeefdeadbeef'));
    final before = record().readAsStringSync();
    await pumpTracker(tester, tracker(), trackerOverrides(docs, work));
    expect(place('Pick 4'), findsOneWidget, reason: 'never moved');
    expect(find.textContaining('changed at or before pick 4'), findsOneWidget);
    expect(tester.widget<IconButton>(find.byKey(const ValueKey('tracker-undo'))).onPressed, isNull,
        reason: 'nothing to undo while the place waits to be checked');
    expect(record().readAsStringSync(), before, reason: 'nothing written yet');

    await tapAndSettle(tester, find.byKey(const ValueKey('tracker-right')));
    expect(find.byKey(const ValueKey('tracker-banner')), findsNothing);
    final p = await stored(tester);
    expect(p.place, const PickPlace(4));
    expect(p.basis!.prefix, fakePrefix(4));
    expect(p.log, isEmpty, reason: 'a place that did not move is not logged');
  });

  testWidgets('a place past the end is shown at the last pick and the move is logged',
      (tester) async {
    await writeRecord(tester, at(10));
    await pumpTracker(tester, tracker(), trackerOverrides(docs, work));
    expect(place('Pick 6'), findsOneWidget);
    expect(find.textContaining('Your place was pick 10'), findsOneWidget);
    expect((await stored(tester)).place, const PickPlace(10), reason: 'not written until checked');
    await tapAndSettle(tester, find.byKey(const ValueKey('tracker-right')));
    final p = await stored(tester);
    expect(p.place, const PickPlace(6));
    expect(p.log.single.kind, LogKind.fix);
    expect(p.log.single.from, const PickPlace(10));
    // Undo brings back the place as it was stored.
    await tapAndSettle(tester, find.byKey(const ValueKey('tracker-undo')));
    expect((await stored(tester)).place, const PickPlace(10));
  });

  testWidgets('Undo of an accepted moved place shows it for checking again', (tester) async {
    await writeRecord(tester, at(10));
    await pumpTracker(tester, tracker(), trackerOverrides(docs, work));
    await tapAndSettle(tester, find.byKey(const ValueKey('tracker-right')));
    expect((await stored(tester)).place, const PickPlace(6));
    await tapAndSettle(tester, find.byKey(const ValueKey('tracker-undo')));
    // Stored at pick 10 again, shown at pick 6 with the question, as on opening.
    expect((await stored(tester)).place, const PickPlace(10));
    expect(place('Pick 6'), findsOneWidget);
    expect(find.byKey(const ValueKey('tracker-right')), findsOneWidget);
    expect(find.textContaining('Your place was pick 10'), findsOneWidget);
    // Previous from it accepts it first, then steps back from pick 6 (never from pick 10).
    await tapAndSettle(tester, find.byKey(const ValueKey('tracker-previous')));
    expect(place('Pick 5'), findsOneWidget);
    final p = await stored(tester);
    expect(p.log.map((e) => e.kind), [LogKind.fix, LogKind.back]);
    expect(p.log.last.from, const PickPlace(6));
  });

  testWidgets('each time through the draft is worked out for that time', (tester) async {
    await writeRecord(tester, at(6));
    await pumpTracker(tester, tracker(), trackerOverrides(docs, work));
    await tapAndSettle(tester, find.byKey(const ValueKey('tracker-next')));
    expect(place('Pick 1'), findsOneWidget);
    expect(work.windowTimes.last, 2);
    expect(find.text('Shuttle 1, from the right.'), findsOneWidget);
    await tapAndSettle(tester, find.byKey(const ValueKey('tracker-previous')));
    await tapAndSettle(tester, find.byKey(const ValueKey('tracker-next')));
    expect(work.windowTimes.last, 2);
  });

  testWidgets('picks added after the place are said and change nothing', (tester) async {
    await writeRecord(tester, at(3, units: 5));
    await pumpTracker(tester, tracker(), trackerOverrides(docs, work));
    expect(place('Pick 3'), findsOneWidget);
    expect(find.textContaining('it now has 6 picks (it had 5)'), findsOneWidget);
    expect(find.byKey(const ValueKey('tracker-right')), findsNothing);
  });

  testWidgets('a newer record is left alone', (tester) async {
    final newer = jsonEncode({'format': kProgressFormat, 'schemaVersion': 9});
    record().writeAsStringSync(newer);
    await pumpTracker(tester, tracker(), trackerOverrides(docs, work));
    expect(find.textContaining('saved by a newer version of Ply'), findsOneWidget);
    expect(find.byKey(const ValueKey('tracker-next')), findsNothing);
    expect(find.byKey(const ValueKey('tracker-start-again')), findsNothing);
    expect(record().readAsStringSync(), newer);
  });

  testWidgets('an unreadable record is set aside on Start again', (tester) async {
    record().writeAsStringSync('{ not json');
    await pumpTracker(tester, tracker(), trackerOverrides(docs, work));
    expect(find.text('Your place in this project could not be read.'), findsOneWidget);
    await tapAndSettle(tester, find.byKey(const ValueKey('tracker-start-again')));
    expect(place('Pick 1'), findsOneWidget);
    expect(File('${record().path}.corrupt').readAsStringSync(), '{ not json');
  });

  testWidgets('a note is pinned to the pick, and Clear removes place, log and notes',
      (tester) async {
    await writeRecord(tester, at(2));
    await pumpTracker(tester, tracker(), trackerOverrides(docs, work));
    expect(find.text('A tabby pick.'), findsOneWidget, reason: 'the engine\'s working notes');
    await tapAndSettle(tester, find.byKey(const ValueKey('tracker-add-note')));
    await tester.enterText(find.byKey(const ValueKey('tracker-note-field')), 'Second shuttle');
    await tapAndSettle(tester, find.byKey(const ValueKey('tracker-note-save')));
    expect(find.text('Second shuttle'), findsOneWidget);
    expect((await stored(tester)).notes.single.place, const PickPlace(2));
    await tapAndSettle(tester, find.byKey(const ValueKey('tracker-next')));
    expect(find.text('Second shuttle'), findsNothing, reason: 'pinned to pick 2');

    await tapAndSettle(tester, find.byTooltip('More'));
    await tapAndSettle(tester, find.text('Clear my place'));
    await tapAndSettle(tester, find.byKey(const ValueKey('tracker-clear-confirm')));
    expect(record().existsSync(), isFalse);
    expect(place('Pick 1'), findsOneWidget);
  });

  testWidgets('a draft with no picks says so', (tester) async {
    work.picks = 0;
    await pumpTracker(tester, tracker(), trackerOverrides(docs, work));
    expect(find.text('This draft has no picks to weave.'), findsOneWidget);
    expect(find.byKey(const ValueKey('tracker-next')), findsNothing);
  });

  testWidgets('a write that fails says so and the place stays on screen', (tester) async {
    await pumpTracker(tester, tracker(), trackerOverrides(docs, work));
    File(p.join(docs.path, 'drafts', '$id.json')).deleteSync();
    await tapAndSettle(tester, find.byKey(const ValueKey('tracker-next')));
    expect(place('Pick 2'), findsOneWidget);
    expect(find.byKey(const ValueKey('tracker-save-error')), findsOneWidget);
    expect(find.textContaining('no longer in your library'), findsOneWidget);
    expect(record().existsSync(), isFalse);
  });

  test('place words', () {
    expect(weavePlaceWords(const PickPlace(12)), 'pick 12');
    expect(weavePlaceWords(const PickPlace(12, repeat: 3)), 'pick 12, time 3');
  });
}
