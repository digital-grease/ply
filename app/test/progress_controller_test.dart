import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/library_backup.dart' show BackupCraft;
import 'package:ply/src/data/progress_repository.dart';
import 'package:ply/src/models/progress.dart';
import 'package:ply/src/state/progress_controller.dart';

import 'progress_test_support.dart';

// One tracking session (ADR 0023): a place shown for checking is accepted by Next (the move is
// logged first as a fix, so the log says why the place changed) or replaced by a jump, Undo is not
// offered while a place waits to be checked, and every change is written at once. Every change of
// place writes the tracker's words as the record's label, or, for a tracker without words, none.

const id = '5d1f3a2b-1111-4222-8333-944455556666';

void main() {
  late Directory docs;
  late ProgressRepository repo;
  var minutes = 0;
  DateTime clock() => DateTime.utc(2026, 11, 18, 10).add(Duration(minutes: minutes++));
  PlaceBasis basis(int pick) => PlaceBasis(units: 6, prefix: fakePrefix(pick));

  setUp(() async {
    docs = await projectFolder(BackupCraft.weaving, id);
    repo = ProgressRepository(docsOverride: docs);
  });
  tearDown(() => docs.delete(recursive: true));

  ProgressController shownForChecking() => ProgressController(
        repository: repo,
        craft: BackupCraft.weaving,
        id: id,
        // Stored at pick 10; the draft now has 6 picks, so pick 6 is on screen.
        progress:
            Progress(craft: ProgressCraft.weaving, place: const PickPlace(10), basis: basis(9)),
        place: const PickPlace(6),
        basis: basis(6),
        pendingCheck: true,
        clock: clock,
      );

  test('Next from a place shown for checking logs the fix, then the pick', () async {
    final c = shownForChecking();
    expect(c.canUndo, isFalse, reason: 'nothing to undo while the place waits');
    await c.moveTo(const PickPlace(1, repeat: 2), basis(1), LogKind.worked);
    expect(c.pendingCheck, isFalse);
    final p = (await repo.load(BackupCraft.weaving, id)).progress!;
    expect(p.place, const PickPlace(1, repeat: 2));
    expect(p.log.map((e) => e.kind), [LogKind.fix, LogKind.worked]);
    expect(p.log.first.from, const PickPlace(10));
    expect(p.log.first.to, const PickPlace(6));
    // Undo twice: back to the stored place exactly.
    await c.undo(start: const PickPlace(1));
    await c.undo(start: const PickPlace(1));
    expect(c.place, const PickPlace(10));
    expect((await repo.load(BackupCraft.weaving, id)).progress!.log, isEmpty);
  });

  test('a jump replaces a place shown for checking without a fix', () async {
    final c = shownForChecking();
    await c.moveTo(const PickPlace(3), basis(3), LogKind.jump);
    final p = (await repo.load(BackupCraft.weaving, id)).progress!;
    expect(p.log.single.kind, LogKind.jump);
    expect(p.log.single.from, const PickPlace(6));
    await c.undo(start: const PickPlace(1));
    expect(c.place, const PickPlace(10), reason: 'undo returns to the stored place');
  });

  test('accepting a place whose step is gone logs the move to the step now shown', () async {
    // Stored at step 2 "Sides" (segment-2), which was deleted: the step shown for checking at the
    // same number is another one ("Brim edge", segment-3).
    final nal = await projectFolder(BackupCraft.nalbinding, id);
    addTearDown(() => nal.delete(recursive: true));
    final r = ProgressRepository(docsOverride: nal);
    const stored = NalbindPlace(1, stepId: 'segment-2');
    final c = ProgressController(
      repository: r,
      craft: BackupCraft.nalbinding,
      id: id,
      progress: Progress(craft: ProgressCraft.nalbinding, place: stored, basis: basis(1)),
      place: const NalbindPlace(1, stepId: 'segment-3'),
      basis: basis(2),
      pendingCheck: true,
      clock: clock,
    );
    await c.accept();
    final p = (await r.load(BackupCraft.nalbinding, id)).progress!;
    expect(p.place, const NalbindPlace(1, stepId: 'segment-3'));
    expect(p.log.single.kind, LogKind.fix);
    expect(p.log.single.from, stored);
    // The same step at the same number is only rebased, not logged.
    final same = ProgressController(
      repository: r,
      craft: BackupCraft.nalbinding,
      id: id,
      progress: p,
      place: const NalbindPlace(1, stepId: 'segment-3'),
      basis: basis(3),
      pendingCheck: true,
      clock: clock,
    );
    await same.accept();
    expect((await r.load(BackupCraft.nalbinding, id)).progress!.log, hasLength(1));
  });

  test('every change of place writes the tracker\'s words, or leaves no label without them',
      () async {
    Future<PlaceLabel?> label() async => (await repo.load(BackupCraft.weaving, id)).progress?.label;
    Future<String?> text() async => (await label())?.text;
    String? words(WorkPlace w, int? units) => w is PickPlace ? 'At pick ${w.pick} of $units' : null;
    // A record holding a label (a later build's): a tracker without words drops it as it moves.
    final stamp = DateTime.utc(2026, 11, 18, 9);
    final labelled = Progress(
        craft: ProgressCraft.weaving,
        place: const PickPlace(3),
        basis: basis(3),
        updated: stamp,
        label: PlaceLabel(
            text: 'Pick 3, the blue stripe', place: const PickPlace(3), updated: stamp));
    await repo.save(BackupCraft.weaving, id, labelled);
    expect((await label())?.text, 'Pick 3, the blue stripe');
    final plain = ProgressController(
        repository: repo,
        craft: BackupCraft.weaving,
        id: id,
        progress: labelled,
        place: const PickPlace(3),
        basis: basis(3),
        clock: clock);
    await plain.moveTo(const PickPlace(4), basis(4), LogKind.worked);
    expect(await label(), isNull);
    // With words: a move, and an undo, write them for the place stored.
    final worded = ProgressController(
        repository: repo,
        craft: BackupCraft.weaving,
        id: id,
        progress: (await repo.load(BackupCraft.weaving, id)).progress!,
        place: const PickPlace(4),
        basis: basis(4),
        clock: clock,
        labelOf: words);
    await worded.moveTo(const PickPlace(5), basis(5), LogKind.worked);
    expect(await text(), 'At pick 5 of 6');
    expect((await label())!.place, const PickPlace(5));
    await worded.undo(start: const PickPlace(1));
    expect(await text(), 'At pick 4 of 6');
    expect((await label())!.place, const PickPlace(4));
    // A place shown for checking, accepted where it is shown (a fix) or where it was (a rebase).
    for (final stored in [const PickPlace(10), const PickPlace(6)]) {
      final checking = ProgressController(
          repository: repo,
          craft: BackupCraft.weaving,
          id: id,
          progress: Progress(craft: ProgressCraft.weaving, place: stored, basis: basis(9)),
          place: const PickPlace(6),
          basis: basis(6),
          pendingCheck: true,
          clock: clock,
          labelOf: words);
      await checking.accept();
      expect(await text(), 'At pick 6 of 6', reason: 'stored at $stored');
      expect((await label())!.place, const PickPlace(6));
    }
    // Clear: no record, so no label; the next move writes the words again.
    await worded.clear(start: const PickPlace(1), basis: basis(1));
    expect((await repo.load(BackupCraft.weaving, id)).status, ProgressStatus.none);
    await worded.moveTo(const PickPlace(2), basis(2), LogKind.worked);
    final after = (await repo.load(BackupCraft.weaving, id)).progress!;
    expect((after.place, after.label?.text), (const PickPlace(2), 'At pick 2 of 6'));
    expect(after.label!.isFor(after.place, after.updated), isTrue);
  });

  test('a note limit is refused before anything is written', () async {
    final c = ProgressController(
      repository: repo,
      craft: BackupCraft.weaving,
      id: id,
      progress: const Progress(craft: ProgressCraft.weaving),
      place: const PickPlace(1),
      basis: basis(1),
      clock: clock,
    );
    expect(() => c.addNote(' '), throwsA(isA<ProgressLimitException>()));
    expect((await repo.load(BackupCraft.weaving, id)).status, ProgressStatus.none);
    await c.addNote('Started');
    expect((await repo.load(BackupCraft.weaving, id)).progress!.notes.single.text, 'Started');
    expect(c.notesHere, hasLength(1));
  });
}
