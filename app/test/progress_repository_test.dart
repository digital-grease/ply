import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:ply/src/data/draft_repository.dart';
import 'package:ply/src/data/knit_repository.dart';
import 'package:ply/src/data/library_backup.dart' show BackupCraft;
import 'package:ply/src/data/nalbind_repository.dart';
import 'package:ply/src/data/progress_repository.dart';
import 'package:ply/src/data/tablet_repository.dart';
import 'package:ply/src/models/progress.dart';
import 'package:ply/src/state/progress_controller.dart';

// A project's progress record on disk (ADR 0023): `<craft folder>/<id>.plyprogress`, written
// atomically, read back, never written over a newer or unreadable record, never written for a project
// that is gone, moved aside on Start again, and removed with the project. The pattern and its sidecar
// are never touched.

const id = '0b6f3c1e-1111-4222-8333-944455556666';
const sidecarText = '{"name":"Towel","craft":"Weaving","savedAt":"2026-11-18T10:00:00.000Z",'
    '"lastOpened":"2026-11-18T10:00:00.000Z"}';
final t0 = DateTime.utc(2026, 11, 18, 10);

Progress woven(int picks) {
  var p = const Progress(craft: ProgressCraft.weaving);
  for (var k = 1; k <= picks; k++) {
    p = p.moved(
      from: PickPlace(k),
      to: PickPlace(k + 1),
      basis: PlaceBasis(units: 96, prefix: k.toRadixString(16).padLeft(16, '0')),
      kind: LogKind.worked,
      now: t0.add(Duration(minutes: k)),
    );
  }
  return p;
}

void main() {
  late Directory docs;
  late ProgressRepository repo;
  File inDrafts(String name) => File(p.join(docs.path, 'drafts', name));
  File record() => inDrafts('$id.plyprogress');

  setUp(() async {
    docs = await Directory.systemTemp.createTemp('ply_progress');
    await Directory(p.join(docs.path, 'drafts')).create();
    await Directory(p.join(docs.path, 'knits')).create();
    inDrafts('$id.json').writeAsStringSync(sidecarText);
    inDrafts('$id.wif').writeAsStringSync('[WIF]\nVersion=1.1\n');
    repo = ProgressRepository(docsOverride: docs);
  });
  tearDown(() => docs.delete(recursive: true));

  test('no record reads as none; a save writes it atomically and it reads back', () async {
    expect((await repo.load(BackupCraft.weaving, id)).status, ProgressStatus.none);
    final written = await repo.save(BackupCraft.weaving, id, woven(5));
    expect(record().existsSync(), isTrue);
    expect(File('${record().path}.tmp').existsSync(), isFalse);
    final load = await repo.load(BackupCraft.weaving, id);
    expect(load.status, ProgressStatus.ok);
    expect(load.progress!.place, const PickPlace(6));
    expect(load.progress!.log, written.log);
    // The pattern and its sidecar are untouched.
    expect(inDrafts('$id.json').readAsStringSync(), sidecarText);
    expect(inDrafts('$id.wif').readAsStringSync(), '[WIF]\nVersion=1.1\n');
  });

  test('writes run one at a time and the last one wins', () async {
    await Future.wait([for (var n = 1; n <= 12; n++) repo.save(BackupCraft.weaving, id, woven(n))]);
    final back = (await repo.load(BackupCraft.weaving, id)).progress!;
    expect(back.place, const PickPlace(13));
  });

  test('a newer record is never read or replaced', () async {
    final newer = jsonEncode({'format': kProgressFormat, 'schemaVersion': 2, 'whatever': 1});
    record().writeAsStringSync(newer);
    expect((await repo.load(BackupCraft.weaving, id)).status, ProgressStatus.newer);
    await expectLater(
        repo.save(BackupCraft.weaving, id, woven(1)),
        throwsA(isA<ProgressFileException>()
            .having((e) => e.problem, 'problem', ProgressProblem.newerVersion)));
    await expectLater(
        repo.setAside(BackupCraft.weaving, id), throwsA(isA<ProgressFileException>()));
    expect(record().readAsStringSync(), newer);
  });

  test('an unreadable record is not replaced until Start again moves it aside', () async {
    record().writeAsStringSync('{"format": "ply.progress", "schemaVersion": 1, "craft": 7}');
    expect((await repo.load(BackupCraft.weaving, id)).status, ProgressStatus.unreadable);
    await expectLater(
        repo.save(BackupCraft.weaving, id, woven(1)),
        throwsA(isA<ProgressFileException>()
            .having((e) => e.problem, 'problem', ProgressProblem.unreadable)));
    await repo.setAside(BackupCraft.weaving, id);
    expect(record().existsSync(), isFalse);
    expect(File('${record().path}.corrupt').readAsStringSync(), contains('"craft": 7'));
    await repo.save(BackupCraft.weaving, id, woven(2));
    expect((await repo.load(BackupCraft.weaving, id)).status, ProgressStatus.ok);
  });

  test('a second Start again never replaces the first record set aside', () async {
    record().writeAsStringSync('first');
    await repo.setAside(BackupCraft.weaving, id);
    record().writeAsStringSync('second');
    await repo.setAside(BackupCraft.weaving, id);
    expect(File('${record().path}.corrupt').readAsStringSync(), 'first');
    expect(File('${record().path}.corrupt.2').readAsStringSync(), 'second');
    await repo.delete(BackupCraft.weaving, id);
    expect(File('${record().path}.corrupt').existsSync(), isFalse);
    expect(File('${record().path}.corrupt.2').existsSync(), isFalse);
  });

  test('a record past the file bound is unreadable without being decoded, unless it is newer',
      () async {
    record().writeAsStringSync(' ' * (ProgressLimits.maxFileBytes + 1));
    expect((await repo.load(BackupCraft.weaving, id)).status, ProgressStatus.unreadable);
    record().writeAsBytesSync([0xff, 0xfe, 0x00]);
    expect((await repo.load(BackupCraft.weaving, id)).status, ProgressStatus.unreadable);
    // A newer Ply's record that is larger than this build reads: newer, never moved aside.
    final newer =
        '{"format":"ply.progress","schemaVersion":2,"pad":"${'x' * ProgressLimits.maxFileBytes}"}';
    record().writeAsStringSync(newer);
    expect((await repo.load(BackupCraft.weaving, id)).status, ProgressStatus.newer);
    await expectLater(
        repo.setAside(BackupCraft.weaving, id), throwsA(isA<ProgressFileException>()));
    expect(record().readAsStringSync(), newer);
    expect(File('${record().path}.corrupt').existsSync(), isFalse);
    // A large one this build's version names is unreadable.
    record().writeAsStringSync(newer.replaceFirst('"schemaVersion":2', '"schemaVersion":1'));
    expect((await repo.load(BackupCraft.weaving, id)).status, ProgressStatus.unreadable);
  });

  test('a write racing a delete never leaves a record for the deleted project', () async {
    final drafts = DraftRepository(draftsDirOverride: Directory(p.join(docs.path, 'drafts')));
    for (var round = 0; round < 20; round++) {
      inDrafts('$id.json').writeAsStringSync(sidecarText);
      final save = repo
          .save(BackupCraft.weaving, id, woven(round + 1))
          .then<Object?>((_) => null, onError: (Object e) => e);
      final delete = round.isEven
          ? drafts.delete(id)
          : Future<void>.delayed(Duration.zero).then((_) => drafts.delete(id));
      final results = await Future.wait<Object?>([save, delete]);
      expect(record().existsSync(), isFalse, reason: 'round $round');
      final error = results.first;
      expect(
          error == null ||
              (error is ProgressFileException && error.problem == ProgressProblem.projectGone),
          isTrue,
          reason: 'round $round: $error');
    }
  });

  test('a record that could never be written again is unreadable, measured before it is decoded',
      () async {
    final valid = utf8.decode(utf8.encode(woven(2).encodeFitted().text));
    final body = valid.substring('{"format":"ply.progress","schemaVersion":1,'.length);
    String withLater(String later, {int head = 1}) =>
        '{"format":"ply.progress","schemaVersion":$head,'
        '${body.replaceFirst(RegExp(r'}$'), ',"later":$later,"schemaVersion":1}')}';
    for (final MapEntry(:key, :value) in {
      'a number too large for a double': withLater('1e400'),
      'nested 260,000 deep': withLater('${'[' * 260000}${']' * 260000}'),
      'two versions': withLater('0', head: 2),
    }.entries) {
      expect(utf8.encode(value).length, lessThan(ProgressLimits.maxFileBytes), reason: key);
      record().writeAsStringSync(value);
      expect((await repo.load(BackupCraft.weaving, id)).status, ProgressStatus.unreadable,
          reason: key);
      await expectLater(
          repo.save(BackupCraft.weaving, id, woven(3)), throwsA(isA<ProgressFileException>()),
          reason: key);
      // Start again moves it aside, and tracking goes on.
      await repo.setAside(BackupCraft.weaving, id);
      await repo.save(BackupCraft.weaving, id, woven(3));
      expect((await repo.load(BackupCraft.weaving, id)).status, ProgressStatus.ok, reason: key);
      await repo.delete(BackupCraft.weaving, id);
    }
  });

  test('a project that is gone gets no record', () async {
    inDrafts('$id.json').deleteSync();
    await expectLater(
        repo.save(BackupCraft.weaving, id, woven(1)),
        throwsA(isA<ProgressFileException>()
            .having((e) => e.problem, 'problem', ProgressProblem.projectGone)));
    expect(record().existsSync(), isFalse);
    await expectLater(
        repo.load(BackupCraft.weaving, '../escape'), throwsA(isA<ProgressFileException>()));
  });

  test('a read waits for the writes queued before it, so a reopened tracker sees the last place',
      () async {
    // A tracker closed with a write in flight, and opened again at once: the read must not see the
    // older record (it would then write an older place over the newer one).
    await repo.save(BackupCraft.weaving, id, woven(2));
    final writing = repo.save(BackupCraft.weaving, id, woven(7));
    final read = await repo.load(BackupCraft.weaving, id);
    expect(read.progress!.place, const PickPlace(8));
    await writing;
    // Through a tracking session: a move not waited for, then a read.
    final c = ProgressController(
      repository: repo,
      craft: BackupCraft.weaving,
      id: id,
      progress: read.progress!,
      place: const PickPlace(8),
      clock: () => t0,
    );
    final moving = c.moveTo(const PickPlace(9),
        const PlaceBasis(units: 96, prefix: '0000000000000009'), LogKind.worked);
    expect((await repo.load(BackupCraft.weaving, id)).progress!.place, const PickPlace(9));
    await moving;
  });

  test('another craft\'s record is unreadable here', () async {
    final knit =
        const Progress(craft: ProgressCraft.knitting).withNote(const KnitPlace(0), 'x', now: t0);
    record().writeAsStringSync(knit.encodeFitted().text);
    expect((await repo.load(BackupCraft.weaving, id)).status, ProgressStatus.unreadable);
  });

  test('clearing removes the record, its temp file and a record moved aside', () async {
    await repo.save(BackupCraft.weaving, id, woven(3));
    File('${record().path}.tmp').writeAsStringSync('x');
    File('${record().path}.corrupt').writeAsStringSync('x');
    await repo.delete(BackupCraft.weaving, id);
    for (final n in ['$id.plyprogress', '$id.plyprogress.tmp', '$id.plyprogress.corrupt']) {
      expect(inDrafts(n).existsSync(), isFalse, reason: n);
    }
    expect(inDrafts('$id.json').existsSync(), isTrue, reason: 'the project stays');
  });

  test('deleting a weaving draft deletes its progress', () async {
    await repo.save(BackupCraft.weaving, id, woven(3));
    File('${record().path}.corrupt').writeAsStringSync('x');
    await DraftRepository(draftsDirOverride: Directory(p.join(docs.path, 'drafts'))).delete(id);
    for (final n in ['$id.plyprogress', '$id.plyprogress.tmp', '$id.plyprogress.corrupt']) {
      expect(inDrafts(n).existsSync(), isFalse, reason: n);
    }
  });

  test('every craft folder keeps its own records', () async {
    for (final craft in BackupCraft.values) {
      expect(ProgressRepository.craftOf(craft)!.key, craft.manifestName, reason: craft.label);
    }
    for (final (craft, progress) in [
      (BackupCraft.tabletWeaving, const Progress(craft: ProgressCraft.tabletWeaving)),
      (BackupCraft.nalbinding, const Progress(craft: ProgressCraft.nalbinding)),
    ]) {
      final dir = Directory(p.join(docs.path, craft.directory))..createSync();
      File(p.join(dir.path, '$id.json')).writeAsStringSync(sidecarText);
      final note = progress.withNote(
          craft == BackupCraft.nalbinding
              ? const NalbindPlace(1, stepId: 'segment-2')
              : const PickPlace(3, repeat: 2),
          'Second ball',
          now: t0);
      await repo.save(craft, id, note);
      expect(File(p.join(dir.path, '$id.plyprogress')).existsSync(), isTrue);
      final back = await repo.load(craft, id);
      expect(back.status, ProgressStatus.ok);
      expect(back.progress!.notes.single.text, 'Second ball');
      // Another craft's folder does not read it.
      File(p.join(docs.path, 'drafts', '$id.plyprogress'))
          .writeAsStringSync(note.encodeFitted().text);
      expect((await repo.load(BackupCraft.weaving, id)).status, ProgressStatus.unreadable);
      File(p.join(docs.path, 'drafts', '$id.plyprogress')).deleteSync();
    }
  });

  test('deleting a tablet weaving band deletes its progress', () async {
    final tablets = Directory(p.join(docs.path, 'tablets'))..createSync();
    File(p.join(tablets.path, '$id.json')).writeAsStringSync(sidecarText);
    File(p.join(tablets.path, '$id.plytab')).writeAsStringSync('{}');
    await repo.save(
        BackupCraft.tabletWeaving,
        id,
        const Progress(craft: ProgressCraft.tabletWeaving)
            .withNote(const PickPlace(1), 'x', now: t0));
    File(p.join(tablets.path, '$id.plyprogress.corrupt.2')).writeAsStringSync('x');
    await (TabletRepository()..dirOverride = tablets).deleteBand(id);
    for (final n in ['$id.plyprogress', '$id.plyprogress.corrupt.2', '$id.json', '$id.plytab']) {
      expect(File(p.join(tablets.path, n)).existsSync(), isFalse, reason: n);
    }
  });

  test('deleting a nalbinding project deletes its progress', () async {
    final nalbinds = Directory(p.join(docs.path, 'nalbinds'))..createSync();
    File(p.join(nalbinds.path, '$id.json')).writeAsStringSync(sidecarText);
    File(p.join(nalbinds.path, '$id.plynal')).writeAsStringSync('{}');
    await repo.save(
        BackupCraft.nalbinding,
        id,
        const Progress(craft: ProgressCraft.nalbinding)
            .withNote(const NalbindPlace(0), 'x', now: t0));
    File(p.join(nalbinds.path, '$id.plyprogress.tmp')).writeAsStringSync('x');
    await (NalbindRepository()..dirOverride = nalbinds).deleteProject(id);
    for (final n in ['$id.plyprogress', '$id.plyprogress.tmp', '$id.json', '$id.plynal']) {
      expect(File(p.join(nalbinds.path, n)).existsSync(), isFalse, reason: n);
    }
  });

  test('deleting a knitting pattern deletes its progress', () async {
    final knits = Directory(p.join(docs.path, 'knits'));
    File(p.join(knits.path, '$id.json')).writeAsStringSync(sidecarText);
    var progress = const Progress(craft: ProgressCraft.knitting);
    progress = progress.moved(
        from: const KnitPlace(0),
        to: const KnitPlace(1),
        basis: const PlaceBasis(units: 4, prefix: '0123456789abcdef'),
        kind: LogKind.worked,
        now: t0);
    await repo.save(BackupCraft.knitting, id, progress);
    expect(File(p.join(knits.path, '$id.plyprogress')).existsSync(), isTrue);
    await (KnitRepository()..dirOverride = knits).deleteKnit(id);
    for (final n in ['$id.plyprogress', '$id.plyprogress.tmp', '$id.plyprogress.corrupt']) {
      expect(File(p.join(knits.path, n)).existsSync(), isFalse, reason: n);
    }
  });
}
