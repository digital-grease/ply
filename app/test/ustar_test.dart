import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/ustar.dart';

// The in-house ustar writer and reader behind library backups: a round trip of names at the ustar
// limits and of binary content, and every structural problem the reader must refuse rather than
// guess about. Archives are built in the test through the same header encoder (no binary fixtures).

/// An archive of [entries] (header + data, padded), ending with the two zero blocks unless [end] is
/// false, plus [tail] bytes after it.
Uint8List archiveOf(List<(UstarHeader, List<int>)> entries, {bool end = true, List<int> tail = const []}) {
  final b = BytesBuilder();
  for (final (header, data) in entries) {
    b.add(header.encode());
    b.add(data);
    b.add(Uint8List(ustarPadding(data.length)));
  }
  if (end) b.add(Uint8List(ustarEndLength));
  b.add(tail);
  return b.takeBytes();
}

late Directory tmp;

/// Read every entry of [bytes] (through a real file, as the restore does): (path, data) pairs.
Future<List<(String, Uint8List)>> readAll(Uint8List bytes) async {
  final f = File('${tmp.path}/a.tar');
  await f.writeAsBytes(bytes);
  final raf = await f.open();
  try {
    final reader = UstarReader(raf, bytes.length);
    final out = <(String, Uint8List)>[];
    while (true) {
      final e = await reader.next();
      if (e == null) break;
      out.add((e.path, Uint8List.sublistView(bytes, e.dataOffset, e.dataOffset + e.size)));
    }
    return out;
  } finally {
    await raf.close();
  }
}

Future<UstarProblem> problemOf(Uint8List bytes) async {
  try {
    await readAll(bytes);
  } on UstarFormatException catch (e) {
    return e.problem;
  }
  fail('the archive was accepted');
}

void main() {
  setUp(() async => tmp = await Directory.systemTemp.createTemp('ustar_test'));
  tearDown(() async => tmp.delete(recursive: true));

  group('round trip', () {
    test('names at the ustar limits and binary content survive byte for byte', () async {
      final rng = Random(7);
      final name100 = 'a' * 100; // fills the name field exactly: no NUL terminator
      final path101 = '${'d' * 50}/${'n' * 50}'; // 101 bytes: needs the prefix field
      final path256 = '${'p' * 155}/${'n' * 100}'; // the longest a header can carry
      final everyByte = Uint8List.fromList(List.generate(256, (i) => i));
      final random = Uint8List.fromList(List.generate(70000, (_) => rng.nextInt(256)));
      final files = <(String, Uint8List)>[
        (name100, everyByte),
        (path101, random),
        (path256, Uint8List(0)), // an empty file
        ('b/511', Uint8List.fromList(List.filled(511, 1))),
        ('b/512', Uint8List.fromList(List.filled(512, 2))),
        ('b/513', Uint8List.fromList(List.filled(513, 3))),
      ];
      final bytes = archiveOf([for (final (p, d) in files) (UstarHeader.file(p, d.length), d)]);
      expect(bytes.length % ustarBlockSize, 0);
      final read = await readAll(bytes);
      expect([for (final (p, _) in read) p], [for (final (p, _) in files) p]);
      for (var i = 0; i < files.length; i++) {
        expect(read[i].$2, files[i].$2, reason: files[i].$1);
      }
    });

    test('a 101 to 256 byte path is split at a slash into prefix and name', () {
      expect(ustarSplitPath('x' * 100), ('', 'x' * 100));
      expect(ustarSplitPath('${'d' * 155}/${'n' * 100}'), ('d' * 155, 'n' * 100));
      expect(ustarSplitPath('a/b/${'n' * 99}'), ('a/b', 'n' * 99));
    });

    test('paths a header cannot carry are refused by the writer', () {
      expect(() => UstarHeader.file('', 0), throwsArgumentError);
      expect(() => UstarHeader.file('n' * 101, 0), throwsArgumentError); // no slash to split at
      expect(() => UstarHeader.file('${'d' * 156}/n', 0), throwsArgumentError); // prefix too long
      expect(() => UstarHeader.file('d/${'n' * 101}', 0), throwsArgumentError); // name too long
      expect(() => UstarHeader.file('${'p' * 155}/${'n' * 101}', 0), throwsArgumentError); // 257
      expect(() => UstarHeader.file('café', 0), throwsArgumentError); // not ASCII
      expect(() => UstarHeader.file('a\nb', 0), throwsArgumentError); // control character
      expect(() => UstarHeader.file('a', -1), throwsArgumentError);
    });

    test('the pre-POSIX NUL typeflag is a regular file; zero padding after the end is allowed',
        () async {
      final bytes = archiveOf([
        (const UstarHeader(name: 'old', size: 1, typeflag: '\u0000'), [9]),
      ], tail: Uint8List(ustarBlockSize * 18));
      expect((await readAll(bytes)).single.$1, 'old');
    });
  });

  group('the reader refuses', () {
    test('links, devices, directories, FIFOs and extension headers', () async {
      for (final type in ['1', '2', '3', '4', '5', '6', '7', 'x', 'g', 'L', 'K']) {
        final bytes = archiveOf([(UstarHeader(name: 'drafts/a.wif', size: 0, typeflag: type), [])]);
        expect(await problemOf(bytes), UstarProblem.notRegularFile, reason: 'typeflag $type');
      }
    });

    test('a header with a bad checksum', () async {
      final bytes = archiveOf([(UstarHeader.file('a', 1), [1])]);
      bytes[10] ^= 0x01; // a name byte changes after the checksum was computed
      expect(await problemOf(bytes), UstarProblem.damaged);
    });

    test('a header that is not POSIX ustar (old GNU magic, wrong version)', () async {
      expect(
          await problemOf(archiveOf([(const UstarHeader(name: 'a', size: 0, magic: 'ustar '), [])])),
          UstarProblem.damaged);
      expect(
          await problemOf(archiveOf([(const UstarHeader(name: 'a', size: 0, version: ' \u0000'), [])])),
          UstarProblem.damaged);
    });

    test('a size in base-256 or with stray characters', () async {
      final bytes = archiveOf([(UstarHeader.file('a', 0), [])]);
      bytes[124] = 0x80; // base-256 marker
      _fixChecksum(bytes, 0);
      expect(await problemOf(bytes), UstarProblem.damaged);
      final bytes2 = archiveOf([(UstarHeader.file('a', 0), [])]);
      bytes2[130] = 0x38; // an '8' is not octal
      _fixChecksum(bytes2, 0);
      expect(await problemOf(bytes2), UstarProblem.damaged);
    });

    test('a path with a non-printable byte or bytes after its terminator', () async {
      final bytes = archiveOf([(UstarHeader.file('ab', 0), [])]);
      bytes[1] = 0x01;
      _fixChecksum(bytes, 0);
      expect(await problemOf(bytes), UstarProblem.badPath);
      final bytes2 = archiveOf([(UstarHeader.file('ab', 0), [])]);
      bytes2[5] = 0x41; // "ab\0\0\0A": a hidden second string
      _fixChecksum(bytes2, 0);
      expect(await problemOf(bytes2), UstarProblem.badPath);
      final bytes3 = archiveOf([(UstarHeader.file('ab', 0), [])]);
      bytes3[0] = 0xC3; // a non-ASCII byte
      _fixChecksum(bytes3, 0);
      expect(await problemOf(bytes3), UstarProblem.badPath);
    });

    test('an entry with an empty name', () async {
      expect(await problemOf(archiveOf([(const UstarHeader(name: '', size: 0), [])])),
          UstarProblem.badPath);
    });

    test('an archive cut short (inside data, inside a header, or before the end marker)', () async {
      final whole = archiveOf([(UstarHeader.file('a', 1000), Uint8List(1000))]);
      expect(await problemOf(Uint8List.sublistView(whole, 0, 700)), UstarProblem.truncated);
      expect(await problemOf(Uint8List.sublistView(whole, 0, 300)), UstarProblem.truncated);
      expect(await problemOf(archiveOf([(UstarHeader.file('a', 1), [1])], end: false)),
          UstarProblem.truncated);
      expect(await problemOf(Uint8List(0)), UstarProblem.truncated);
    });

    test('a lone zero block followed by data, and data after the end marker', () async {
      final lone = BytesBuilder()
        ..add(Uint8List(ustarBlockSize))
        ..add(UstarHeader.file('a', 0).encode())
        ..add(Uint8List(ustarEndLength));
      expect(await problemOf(lone.takeBytes()), UstarProblem.damaged);
      final trailing = archiveOf([(UstarHeader.file('a', 0), [])], tail: [0, 0, 7]);
      expect(await problemOf(trailing), UstarProblem.damaged);
    });
  });
}

/// Recompute the checksum of the header at [offset] after a test edited it.
void _fixChecksum(Uint8List bytes, int offset) {
  for (var i = 148; i < 156; i++) {
    bytes[offset + i] = 0x20;
  }
  var sum = 0;
  for (var i = 0; i < ustarBlockSize; i++) {
    sum += bytes[offset + i];
  }
  final field = '${sum.toRadixString(8).padLeft(6, '0')}\u0000 '.codeUnits;
  bytes.setRange(offset + 148, offset + 156, field);
}
