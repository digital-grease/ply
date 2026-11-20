import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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

  group('the engine alone reads the file', () {
    // decodeBytes decodes no JSON of its own (ADR 0007, amendment of 2026-11-18, later): a crafted
    // file of a megabyte once cost about 80 MiB in Dart before the engine saw it. The engine's
    // verdict, newer version included, is the only one.
    late _ScriptedLoomRepository scripted;
    Future<List<LoomProfile>> Function(String text) answer = (_) async => const [];
    setUp(() => scripted = _ScriptedLoomRepository(dir, (text) => answer(text)));
    Matcher refused(LoomFileProblem problem) =>
        throwsA(isA<LoomFileException>().having((e) => e.problem, 'problem', problem));

    test('within the limit, the text goes to the engine once, as it is', () async {
      final newer = loomsText([borrowedLoom], version: 2);
      answer = (_) async => [borrowedLoom];
      expect((await scripted.decodeBytes(utf8.encode(newer))).single.id, borrowedLoom.id,
          reason: 'the version a text states is the engine\'s to read, not the app\'s');
      expect(scripted.asked, [newer]);

      answer = (_) async => throw const LoomFileException(LoomFileProblem.newerVersion);
      await expectLater(
          scripted.decodeBytes(utf8.encode('{}')), refused(LoomFileProblem.newerVersion));
      answer = (_) async => throw const LoomFileException(LoomFileProblem.unreadable);
      await expectLater(
          scripted.decodeBytes(utf8.encode(newer)), refused(LoomFileProblem.unreadable));
      answer = (_) async => throw const LoomFileException(LoomFileProblem.tooLarge);
      await expectLater(
          scripted.decodeBytes(utf8.encode(newer)), refused(LoomFileProblem.tooLarge));
      expect(scripted.asked, hasLength(4));
    });

    test('a file that is not UTF-8 is unreadable, or too large past the limit, unasked', () async {
      await expectLater(scripted.decodeBytes([0xff, 0xfe]), refused(LoomFileProblem.unreadable));
      final big = List.filled(LoomRepository.maxFileBytes + 1, 0x20)..[0] = 0xff;
      await expectLater(scripted.decodeBytes(big), refused(LoomFileProblem.tooLarge));
      expect(scripted.asked, isEmpty);
    });

    test('over the limit, only the engine\'s newer version changes "too large"', () async {
      final big = utf8.encode(' ' * (LoomRepository.maxFileBytes + 1));
      answer = (_) async => throw const LoomFileException(LoomFileProblem.newerVersion);
      await expectLater(scripted.decodeBytes(big), refused(LoomFileProblem.newerVersion));
      for (final other in <Future<List<LoomProfile>> Function(String)>[
        (_) async => [borrowedLoom],
        (_) async => throw const LoomFileException(LoomFileProblem.unreadable),
        (_) async => throw const LoomFileException(LoomFileProblem.tooLarge),
        (_) async => throw StateError('the engine failed'),
      ]) {
        answer = other;
        await expectLater(scripted.decodeBytes(big), refused(LoomFileProblem.tooLarge));
      }
      expect(scripted.asked, hasLength(5));
      expect(scripted.asked.first.length, big.length, reason: 'the whole text, for its envelope');
    });

    test('past the largest file whose version is looked at, the engine is not asked', () async {
      final huge = Uint8List(LoomRepository.maxProbedFileBytes + 1);
      answer = (_) async => throw const LoomFileException(LoomFileProblem.newerVersion);
      await expectLater(scripted.decodeBytes(huge), refused(LoomFileProblem.tooLarge));
      expect(scripted.asked, isEmpty);
    });

    test('the stand-in engine reports a newer or too large file as the engine does', () async {
      final newer = utf8.encode(loomsText([borrowedLoom], version: 2));
      await expectLater(repo.decodeBytes(newer), refused(LoomFileProblem.newerVersion));
      final pad = 'x' * (LoomRepository.maxFileBytes + 10);
      final big = '{"format":"ply.looms","schema_version":1,"looms":[],"pad":"$pad"}';
      await expectLater(repo.decodeBytes(utf8.encode(big)), refused(LoomFileProblem.tooLarge));
      await expectLater(repo.decode(big), refused(LoomFileProblem.tooLarge));
      await expectLater(
          repo.decode(big.replaceFirst('"schema_version":1', '"schema_version":2')),
          refused(LoomFileProblem.newerVersion));
      expect(repo.decodes, 4);
    });
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

/// The loom repository with the engine's reader scripted by the test, recording every text it is
/// asked to read.
class _ScriptedLoomRepository extends LoomRepository {
  _ScriptedLoomRepository(Directory dir, this.answer) : super(dirOverride: dir);

  final Future<List<LoomProfile>> Function(String text) answer;
  final List<String> asked = [];

  @override
  Future<List<LoomProfile>> decode(String text) {
    asked.add(text);
    return answer(text);
  }
}
