import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:ply/src/data/loom_repository.dart';
import 'package:ply/src/models/loom_profile.dart';

import 'loom_test_support.dart';

// looms.json on disk (ADR 0014): atomic writes, a newer file never read or replaced, an unreadable
// file moved aside (never over an older copy), and the restore helper's exact undo. The engine's
// codec is stood in for by a small Dart one (see loom_test_support.dart).

void main() {
  late Directory dir;
  late DartCodecLoomRepository repo;
  File looms() => File(p.join(dir.path, LoomRepository.fileName));

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ply-looms-');
    repo = DartCodecLoomRepository(dir);
  });
  tearDown(() => dir.delete(recursive: true));

  test('no file yet is an empty, writable library', () async {
    final load = await repo.load();
    expect(load.looms, isEmpty);
    expect(load.status, LoomFileStatus.ok);
  });

  test('save then load round-trips, atomically', () async {
    await repo.saveAll([borrowedLoom, const LoomProfile(id: 'b', name: 'Second')]);
    final load = await repo.load();
    expect([for (final l in load.looms) l.id], ['loom-borrowed', 'b']);
    expect(load.looms.first.shafts, 8);
    expect(load.looms.first.treadles, isNull, reason: 'unknown stays unknown');
    expect(dir.listSync().map((e) => p.basename(e.path)), [LoomRepository.fileName],
        reason: 'no temp file left behind');
  });

  test('a newer file is left alone, read only, and never replaced', () async {
    final newer = loomsText([borrowedLoom], version: 2);
    await looms().writeAsString(newer);
    final load = await repo.load();
    expect(load.status, LoomFileStatus.newer);
    expect(load.looms, isEmpty);
    await expectLater(
      repo.saveAll([const LoomProfile(id: 'x')]),
      throwsA(isA<LoomFileException>()
          .having((e) => e.problem, 'problem', LoomFileProblem.newerVersion)
          .having((e) => e.whileSaving, 'whileSaving', isTrue)),
    );
    expect(await looms().readAsString(), newer, reason: 'the newer file is untouched');
    expect(const LoomFileException(LoomFileProblem.newerVersion).message,
        'Your looms were saved by a newer version of Ply. Update the app to change them.');
  });

  test('an unreadable file is moved aside, never over an older copy', () async {
    await looms().writeAsString('{ not json');
    final first = await repo.load();
    expect(first.status, LoomFileStatus.setAside);
    expect(first.setAsidePath, '${looms().path}.corrupt');
    expect(await File('${looms().path}.corrupt').readAsString(), '{ not json');
    expect(looms().existsSync(), isFalse);

    await looms().writeAsString('also broken');
    final second = await repo.load();
    expect(second.setAsidePath, '${looms().path}.corrupt.2');
    expect(await File('${looms().path}.corrupt').readAsString(), '{ not json',
        reason: 'the older copy is kept');
    expect(await File('${looms().path}.corrupt.2').readAsString(), 'also broken');

    // A file that is not UTF-8 is unreadable too.
    await looms().writeAsBytes([0xff, 0xfe, 0x00]);
    expect((await repo.load()).status, LoomFileStatus.setAside);
  });

  test('a file over the size limit is not read', () async {
    await expectLater(
        repo.decodeBytes(List.filled(LoomRepository.maxFileBytes + 1, 0x20)),
        throwsA(isA<LoomFileException>()
            .having((e) => e.problem, 'problem', LoomFileProblem.tooLarge)));
  });

  test('a file too large to open is never moved aside: it stays, read only', () async {
    // Big but otherwise a current file: too large, left exactly where it is.
    final pad = 'x' * (LoomRepository.maxFileBytes + 10);
    final big = '{"format":"ply.looms","schema_version":1,"looms":[],"pad":"$pad"}';
    await looms().writeAsString(big);
    final load = await repo.load();
    expect(load.status, LoomFileStatus.tooLarge);
    expect(await looms().readAsString(), big, reason: 'not moved, not changed');
    expect(File('${looms().path}.corrupt').existsSync(), isFalse);
    await expectLater(
        repo.saveAll([borrowedLoom]),
        throwsA(isA<LoomFileException>()
            .having((e) => e.problem, 'problem', LoomFileProblem.tooLarge)
            .having((e) => e.whileSaving, 'whileSaving', isTrue)));
    expect(await looms().readAsString(), big);

    // Big and from a newer Ply: newer, so it is left alone for that reason.
    await looms().writeAsString(big.replaceFirst('"schema_version":1', '"schema_version":2'));
    expect((await repo.load()).status, LoomFileStatus.newer);
  });

  test('saving refuses to replace a file that became unreadable', () async {
    await looms().writeAsString('garbage');
    await expectLater(repo.saveAll([borrowedLoom]),
        throwsA(isA<LoomFileException>().having((e) => e.whileSaving, 'whileSaving', isTrue)));
    expect(await looms().readAsString(), 'garbage');
  });

  test('adding restored looms writes once, and the undo puts the bytes back exactly', () async {
    // No file before: the undo removes it.
    final undoNew = await repo.addLooms([borrowedLoom]);
    expect((await repo.load()).looms.single.id, 'loom-borrowed');
    await undoNew();
    expect(looms().existsSync(), isFalse);

    // A file before: the undo restores its bytes.
    final before = utf8.encode(loomsText([const LoomProfile(id: 'mine', name: 'Mine')]));
    await looms().writeAsBytes(before);
    final undo = await repo.addLooms([borrowedLoom]);
    expect([for (final l in (await repo.load()).looms) l.id], ['mine', 'loom-borrowed']);
    await undo();
    expect(await looms().readAsBytes(), before);
  });
}
