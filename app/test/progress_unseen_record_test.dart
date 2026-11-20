import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:ply/src/data/draft_repository.dart';
import 'package:ply/src/data/library_backup.dart' show BackupCraft;
import 'package:ply/src/data/library_places.dart' show LibraryPlace;
import 'package:ply/src/data/progress_repository.dart';
import 'package:ply/src/models/nalbind_project.dart';
import 'package:ply/src/models/progress.dart';
import 'package:ply/src/screens/nalbind_project_screen.dart';
import 'package:ply/src/screens/nalbind_reference_screen.dart';
import 'package:ply/src/screens/weave_tracker_screen.dart';
import 'package:ply/src/state/nalbind_providers.dart';

import 'nalbind_recipe_test_support.dart';
import 'pick_roles_support.dart';
import 'progress_test_support.dart';

// A record the device cannot show (ADR 0023, amendment of 2026-11-19, review rounds): a folder that
// cannot be searched is a failed read, never "no record", so a tracker never starts a new record
// over one it could not see; a tracker that did start from no record never writes over one that
// appears; a record that can never be read can be put aside once trying again has failed too, and
// a set-aside the device refuses says so; a save that cannot check the record says so in its own
// words. Real files under a temp folder; permissions changed with chmod.

const id = '9b0e1a2b-1111-4222-8333-944455556677';

Progress _record(int pick, {String? note}) {
  var p = Progress(
    craft: ProgressCraft.weaving,
    place: PickPlace(pick),
    basis: PlaceBasis(units: 6, prefix: fakePrefix(pick)),
  );
  if (note != null) p = p.withNote(PickPlace(pick), note, now: DateTime.utc(2026, 11, 18));
  return p;
}

/// Change [path]'s permissions to [mode], and back to [back] after the test.
void _chmod(String path, String mode, {required String back}) {
  Process.runSync('chmod', [mode, path]);
  addTearDown(() => Process.runSync('chmod', [back, path]));
}

/// Whether this process is kept out of [f] (false for a process that reads any file).
bool _keptOut(File f) {
  try {
    f.readAsBytesSync();
    return false;
  } on FileSystemException {
    return true;
  }
}

Finder _trackerPlace(String text) => find.descendant(
    of: find.byKey(const ValueKey('tracker-place')), matching: find.text(text), matchRoot: true);

Widget _tracker() => WeaveTrackerScreen(
    projectId: id, draft: DraftRepository().toDto(generatedOvershot(picks: 6)), name: 'Towel');

void main() {
  late Directory docs;
  late Directory drafts;
  late File record;
  late ProgressRepository repo;
  late FakeWork work;
  setUp(() async {
    docs = await projectFolder(BackupCraft.weaving, id);
    drafts = Directory(p.join(docs.path, 'drafts'));
    record = File(p.join(drafts.path, '$id.plyprogress'));
    repo = ProgressRepository(docsOverride: docs);
    work = FakeWork(picks: 6);
  });
  tearDown(() async {
    Process.runSync('chmod', ['-R', 'u+rwx', docs.path]);
    await docs.delete(recursive: true);
  });

  test('a folder that cannot be searched is a failed read, never no record', () async {
    await repo.save(BackupCraft.weaving, id, _record(40, note: 'Started the second ball.'));
    _chmod(drafts.path, '000', back: '755');
    if (!_keptOut(record)) {
      markTestSkipped('this process can read any file');
      return;
    }
    expect((await repo.load(BackupCraft.weaving, id)).status, ProgressStatus.failed);
    expect(ProgressRepository.readFileSync(record.path, ProgressCraft.weaving).status,
        ProgressStatus.failed);
    // A save made then is refused, in its own words, and writes nothing.
    await expectLater(
        repo.save(BackupCraft.weaving, id, _record(1)),
        throwsA(isA<ProgressFileException>()
            .having((e) => e.problem, 'problem', ProgressProblem.saveCheckFailed)));
    Process.runSync('chmod', ['755', drafts.path]);
    final back = (await repo.load(BackupCraft.weaving, id)).progress!;
    expect(back.place, const PickPlace(40));
    expect(back.notes, hasLength(1));
    // A file that is not there is no record.
    expect((await repo.load(BackupCraft.weaving, 'aa000000-1111-4222-8333-944455550000')).status,
        ProgressStatus.none);
  });

  test('a tracker that found no record never writes over one that appears', () async {
    final guard = ProgressSaveGuard(expectNoRecord: true);
    // Another screen writes a record after this one found none.
    await repo.save(BackupCraft.weaving, id, _record(40, note: 'Mended an end.'));
    final before = record.readAsStringSync();
    await expectLater(
        repo.save(BackupCraft.weaving, id, _record(2), guard: guard),
        throwsA(isA<ProgressFileException>()
            .having((e) => e.problem, 'problem', ProgressProblem.foundAgain)));
    expect(record.readAsStringSync(), before);
    expect(guard.expectNoRecord, isTrue);

    // With no record there, the first save writes; every save after it, however soon, goes on.
    await repo.delete(BackupCraft.weaving, id);
    final fresh = ProgressSaveGuard(expectNoRecord: true);
    await Future.wait([
      repo.save(BackupCraft.weaving, id, _record(2), guard: fresh),
      repo.save(BackupCraft.weaving, id, _record(3), guard: fresh),
    ]);
    expect(fresh.expectNoRecord, isFalse);
    expect((await repo.load(BackupCraft.weaving, id)).progress!.place, const PickPlace(3));
  });

  testWidgets(
      'the tracker, opened while the folder could not be searched, says so and keeps the '
      'record', (tester) async {
    await tester.runAsync(
        () => repo.save(BackupCraft.weaving, id, _record(4, note: 'Started the second ball.')));
    _chmod(drafts.path, '000', back: '755');
    if (!_keptOut(record)) {
      markTestSkipped('this process can read any file');
      return;
    }
    await pumpTracker(tester, _tracker(), trackerOverrides(docs, work));
    expect(
        find.text(const ProgressFileException(ProgressProblem.ioFailed).message), findsOneWidget);
    expect(find.byKey(const ValueKey('tracker-next')), findsNothing, reason: 'no new record');
    Process.runSync('chmod', ['755', drafts.path]);
    await tapAndSettle(tester, find.byKey(const ValueKey('tracker-try-again')));
    expect(_trackerPlace('Pick 4'), findsOneWidget);
    final kept = (await tester.runAsync(() => repo.load(BackupCraft.weaving, id)))!.progress!;
    expect(kept.notes, hasLength(1), reason: 'the note is still there');
  });

  testWidgets('a record that appears after the tracker found none is shown, never written over',
      (tester) async {
    await pumpTracker(tester, _tracker(), trackerOverrides(docs, work));
    expect(_trackerPlace('Pick 1'), findsOneWidget);
    // Another screen keeps a place meanwhile.
    await tester.runAsync(
        () => ProgressRepository(docsOverride: docs).save(BackupCraft.weaving, id, _record(4)));
    final before = record.readAsStringSync();
    await tapAndSettle(tester, find.byKey(const ValueKey('tracker-next')));
    expect(record.readAsStringSync(), before, reason: 'never written over');
    expect(
        find.text(const ProgressFileException(ProgressProblem.foundAgain).message), findsOneWidget);
    expect(_trackerPlace('Pick 4'), findsOneWidget, reason: 'the record found is shown');
    // From it, the tracker goes on as usual.
    await tapAndSettle(tester, find.byKey(const ValueKey('tracker-next')));
    expect((await tester.runAsync(() => repo.load(BackupCraft.weaving, id)))!.progress!.place,
        const PickPlace(5));
  });

  testWidgets(
      'a record that can never be read: Start again once Try again fails, and a refused '
      'move said plainly', (tester) async {
    await tester.runAsync(() => repo.save(BackupCraft.weaving, id, _record(4)));
    final bytes = record.readAsBytesSync();
    _chmod(record.path, '000', back: '644');
    if (!_keptOut(record)) {
      markTestSkipped('this process can read any file');
      return;
    }
    await pumpTracker(tester, _tracker(), trackerOverrides(docs, work));
    final startAgain = find.byKey(const ValueKey('tracker-start-again'));
    expect(find.byKey(const ValueKey('tracker-try-again')), findsOneWidget);
    expect(startAgain, findsNothing, reason: 'not before trying again');
    await tapAndSettle(tester, find.byKey(const ValueKey('tracker-try-again')));
    expect(startAgain, findsOneWidget, reason: 'trying again failed too');
    expect(find.text('Start again keeps the old record aside and starts from the beginning.'),
        findsOneWidget);

    // The folder does not let the file be moved: said plainly, nothing changed.
    _chmod(drafts.path, '555', back: '755');
    await tapAndSettle(tester, startAgain);
    expect(find.text(const ProgressFileException(ProgressProblem.setAsideFailed).message),
        findsOneWidget);
    expect(record.existsSync(), isTrue);

    Process.runSync('chmod', ['755', drafts.path]);
    await tapAndSettle(tester, startAgain);
    final aside = File('${record.path}.corrupt');
    expect(record.existsSync(), isFalse);
    expect(aside.existsSync(), isTrue);
    Process.runSync('chmod', ['644', aside.path]);
    expect(aside.readAsBytesSync(), bytes, reason: 'moved aside unread, every byte kept');
    expect(_trackerPlace('Pick 1'), findsOneWidget, reason: 'a new record from the beginning');
  });

  testWidgets('a save that cannot check the record says so in its own words', (tester) async {
    await pumpTracker(tester, _tracker(), trackerOverrides(docs, work));
    await tapAndSettle(tester, find.byKey(const ValueKey('tracker-next')));
    _chmod(record.path, '000', back: '644');
    if (!_keptOut(record)) {
      markTestSkipped('this process can read any file');
      return;
    }
    await tapAndSettle(tester, find.byKey(const ValueKey('tracker-next')));
    expect(find.text(const ProgressFileException(ProgressProblem.saveCheckFailed).message),
        findsOneWidget);
    expect(find.text(const ProgressFileException(ProgressProblem.ioFailed).message), findsNothing);
  });

  testWidgets('the nalbinding tab\'s open guard belongs to the tab', (tester) async {
    final repo = _Listing();
    Future<void> pumpTab() async {
      await tester.pumpWidget(ProviderScope(
        overrides: [nalbindRepositoryProvider.overrideWithValue(repo)],
        child: const MaterialApp(home: Scaffold(body: NalbindReferenceScreen())),
      ));
      await tester.pumpAndSettle();
    }

    await pumpTab();
    // Two opens at once open one project.
    final open = tester.widget<FloatingActionButton>(find.byType(FloatingActionButton)).onPressed!;
    open();
    open();
    await tester.pumpAndSettle();
    expect(find.byType(NalbindProjectScreen), findsOneWidget);
    // The app goes away with the project open (its route never comes back); a new tab still opens.
    await tester.pumpWidget(const SizedBox());
    await pumpTab();
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    expect(find.byType(NalbindProjectScreen), findsOneWidget);
  });

  test('a library place reads nothing into a folder it cannot search', () async {
    await repo.save(BackupCraft.weaving, id, _record(4));
    _chmod(drafts.path, '000', back: '755');
    if (!_keptOut(record)) {
      markTestSkipped('this process can read any file');
      return;
    }
    // A failure no record explains: no line (ADR 0023).
    final status = (await repo.load(BackupCraft.weaving, id)).status;
    expect(status, ProgressStatus.failed);
    expect(LibraryPlace.fromLoad(ProgressLoad(status)), isNull);
  });
}

/// A nalbinding library with no projects yet.
class _Listing extends RecipeFakeRepo {
  @override
  Future<List<NalbindProjectEntry>> listProjects() async => const [];
}
