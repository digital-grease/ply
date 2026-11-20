import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:ply/src/data/draft_repository.dart';
import 'package:ply/src/data/knit_repository.dart';
import 'package:ply/src/data/library_backup.dart';
import 'package:ply/src/data/nalbind_repository.dart';
import 'package:ply/src/data/sidecar_read.dart';
import 'package:ply/src/data/tablet_repository.dart';
import 'package:ply/src/models/draft_meta.dart';
import 'package:ply/src/screens/library_screen.dart';
import 'package:ply/src/state/editor_providers.dart';

// Every craft's library listing reads its sidecars with the bounds a restore checks a backup's
// sidecar with (ADR 0007, amendment of 2026-11-18, later): the values are counted and the nesting
// measured before anything is decoded; a sidecar Ply writes is decoded where it is read, as before;
// a large one (more than 10,000 values, or over 1 MB) on a background isolate, coming back with what
// the listing shows; one past the bounds is not decoded but still lists, by the name at its head or
// its id, when it starts as a JSON object and is UTF-8, whether or not the rest is JSON (telling
// would take the decode the bounds avoid). Within the bounds, a file that is not a sidecar is left
// out, as before, and so is one past them that does not start with `{` or is not UTF-8. Listing
// changes nothing on disk.

const _savedAt = '"savedAt":"2026-01-01T00:00:00.000Z"';

/// A sidecar of [craft] named [name], last opened on day [day] of January 2026, with [more] JSON
/// text after its keys (`"key":value` pairs) and [notes].
String sidecarText(String craft, String name, int day, {String more = '', String notes = 'n'}) =>
    '{"name":${jsonEncode(name)},"craft":"$craft","notes":${jsonEncode(notes)},$_savedAt,'
    '"lastOpened":"2026-01-0${day}T00:00:00.000Z","schemaVersion":1,"kept":true'
    '${more.isEmpty ? '' : ',$more'}}';

/// `"later":[0,0,...]` with [n] zeros: n + 2 values.
String zeros(int n) => '"later":[${List.filled(n, '0').join(',')}]';

/// The listing cases, by the id each file has: what lists (and how), and what is left out.
class Library {
  Library(this.dir, this.craft, this.native);

  final Directory dir;
  final String craft;

  /// The extension of the craft's document (the listing pairs each sidecar with it).
  final String native;

  final DateTime stamp = DateTime(2020, 5, 6, 7, 8, 9);

  void put(String id, List<int> sidecar) {
    File(p.join(dir.path, '$id.json')).writeAsBytesSync(sidecar);
    File(p.join(dir.path, '$id.$native')).writeAsStringSync('document');
  }

  void seed() {
    put('plain', utf8.encode(sidecarText(craft, 'Plain', 5)));
    // More values than a sidecar decoded where it is read may have, within the bounds.
    put('many', utf8.encode(sidecarText(craft, 'Many values', 4, more: zeros(50000))));
    // Few values, but over 1 MB (an earlier build's long notes).
    put('long', utf8.encode(sidecarText(craft, 'Long notes', 3, notes: 'x' * (1100 * 1000))));
    // Past the bounds: the values, the nesting, a number too large for a double.
    put('values', utf8.encode(sidecarText(craft, 'Past the values', 6, more: zeros(250000))));
    put('deep', utf8.encode(sidecarText(craft, 'Deep', 7, more: '"later":${'[' * 70}${']' * 70}')));
    put('infinite', utf8.encode(sidecarText(craft, 'Infinite', 8, more: '"later":1e400')));
    // Past the bounds with no name at its head: listed by its id.
    put('nameless', utf8.encode('{"craft":"$craft",${zeros(250000)}}'));
    // Over the largest sidecar a listing reads: only its head is read (a sparse file).
    final huge = File(p.join(dir.path, 'huge.json'));
    huge.writeAsStringSync('{"name":"Huge","craft":"$craft","notes":"');
    final raf = huge.openSync(mode: FileMode.append);
    raf.truncateSync(kMaxListedSidecarBytes + 1);
    raf.closeSync();
    File(p.join(dir.path, 'huge.$native')).writeAsStringSync('document');
    // Left out: a small file that is not a sidecar, and files past the bounds that do not start as
    // an object or are not UTF-8. (One past the bounds that starts as an object lists even when it
    // is not JSON: see the group "past the bounds, JSON or not".)
    put('broken', utf8.encode('{ not json'));
    put('list', utf8.encode('[${List.filled(250000, '0').join(',')}]'));
    put('words', utf8.encode('not json ${List.filled(250000, 'x').join(' ')}'));
    put('latin1', [...utf8.encode('{${zeros(250000)}'), 0xff, 0x7d]);
    put('latin1small', [...utf8.encode('{"name":"x"'), 0xff, 0x7d]);
    // A sidecar without its document is not listed (as before).
    File(p.join(dir.path, 'alone.json')).writeAsStringSync(sidecarText(craft, 'Alone', 9));
    for (final id in ['values', 'deep', 'infinite', 'nameless', 'huge']) {
      File(p.join(dir.path, '$id.json')).setLastModifiedSync(stamp);
    }
  }

  /// Every file's bytes (the length of the huge one) and last change, to show nothing changed.
  Map<String, (Object, DateTime)> snapshot() => {
        for (final f in dir.listSync().whereType<File>())
          p.basename(f.path): (
            p.basename(f.path) == 'huge.json' ? f.lengthSync() : base64.encode(f.readAsBytesSync()),
            f.lastModifiedSync(),
          ),
      };

  /// The names the listing shows, in its order (newest opened first).
  static const List<String> listed = [
    'Plain',
    'Many values',
    'Long notes',
    // Not decoded: dated by the file's last change, the same for all five, so in any order.
  ];
  static const Set<String> notDecoded = {
    'Past the values',
    'Deep',
    'Infinite',
    'nameless',
    'Huge'
  };
}

void main() {
  group('the bounds', () {
    test('a sidecar Ply writes is decoded where it is read', () {
      expect(sidecarFit(utf8.encode(sidecarText('Weaving', 'Plain', 1))), SidecarFit.inline);
      final most = utf8.encode('[${List.filled(kInlineSidecarValues - 1, '0').join(',')}]');
      expect(sidecarFit(most), SidecarFit.inline, reason: 'the list and its values');
    });

    test('more values, within the restore\'s limit, are decoded on a background isolate', () {
      final more = utf8.encode('[${List.filled(kInlineSidecarValues, '0').join(',')}]');
      expect(sidecarFit(more), SidecarFit.background);
      final most = utf8.encode('[${List.filled(kMaxSidecarValues - 1, '0').join(',')}]');
      expect(sidecarFit(most), SidecarFit.background);
    });

    test('past the values, the nesting or a double\'s range, nothing is decoded', () {
      expect(sidecarFit(utf8.encode('[${List.filled(kMaxSidecarValues, '0').join(',')}]')),
          SidecarFit.tooComplex);
      expect(sidecarFit(utf8.encode('${'[' * kMaxSidecarDepth}${']' * kMaxSidecarDepth}')),
          SidecarFit.inline);
      expect(sidecarFit(utf8.encode('${'[' * (kMaxSidecarDepth + 1)}${']' * 65}')),
          SidecarFit.tooComplex);
      expect(sidecarFit(utf8.encode('{"a":1e400}')), SidecarFit.tooComplex);
      expect(sidecarFit(utf8.encode('{"a":"1e400"}')), SidecarFit.inline);
    });

    test('the restore\'s limits are the same numbers', () {
      const limits = BackupLimits();
      expect(limits.maxSidecarValues, kMaxSidecarValues);
      expect(limits.maxSidecarDepth, kMaxSidecarDepth);
      expect(LibraryBackup.inlineSidecarValues, kInlineSidecarValues);
      expect(limits.maxSidecarBytes, kInlineSidecarBytes);
      expect(limits.maxFileBytes, kMaxListedSidecarBytes);
    });

    test('the name at the head of a sidecar', () {
      List<int> b(String s) => utf8.encode(s);
      expect(sidecarNameAtHead(b('{"name":"Towel","craft":"Weaving"')), 'Towel');
      expect(sidecarNameAtHead(b('{"name" : "A \\"quoted\\" name"')), 'A "quoted" name');
      expect(sidecarNameAtHead(b('{"name":"\\u00e9t\\u00e9"}')), 'été');
      expect(sidecarNameAtHead(b('{"name":"   "}')), isNull, reason: 'only spaces');
      expect(sidecarNameAtHead(b('{"name":"cut off')), isNull, reason: 'not all in the head');
      expect(sidecarNameAtHead(b('{"craft":"Weaving"}')), isNull);
      expect(sidecarNameAtHead([0xff, 0xfe]), isNull);
    });

    test('only a top-level name counts', () {
      List<int> b(String s) => utf8.encode(s);
      // A loom plan's (or any value's) name is not the project's.
      expect(sidecarNameAtHead(b('{"loomPlan":{"name":"Loom A"},"name":"Real"}')), 'Real');
      expect(sidecarNameAtHead(b('{"loomPlan":{"name":"Loom A"},"craft":"Weaving"}')), isNull);
      expect(sidecarNameAtHead(b('{"later":[{"name":"In a list"}],"name":"Real"}')), 'Real');
      expect(sidecarNameAtHead(b('{"later":[["name"],{"a":{"name":"x"}}],"name":"Real"')), 'Real');
      // A name written inside a string, or as a value, is no key.
      expect(sidecarNameAtHead(b('{"notes":"\\"name\\":\\"Fake\\"","name":"Real"}')), 'Real');
      expect(sidecarNameAtHead(b('{"title":"name","name":"Real"}')), 'Real');
      expect(sidecarNameAtHead(b('{"a":"x\\\\","name":"Real"}')), 'Real',
          reason: 'an escaped backslash ends no string early');
      // A name that is not text is passed over; the first one that is counts.
      expect(sidecarNameAtHead(b('{"name":5,"name":"Real"}')), 'Real');
      expect(sidecarNameAtHead(b('{"name":"First","name":"Second"}')), 'First');
      // Not an object, or the object ends before a name.
      expect(sidecarNameAtHead(b('["name","x"]')), isNull);
      expect(sidecarNameAtHead(b('{"a":1} {"name":"After"}')), isNull);
      expect(sidecarNameAtHead(b('  {"name":"Spaced"}')), 'Spaced');
    });
  });

  for (final (craft, native) in [
    ('Weaving', 'wif'),
    ('Knitting', 'plyknit'),
    ('TabletWeaving', 'plytab'),
    ('Nalbinding', 'plynal'),
  ]) {
    group('the $craft listing', () {
      late Directory dir;
      late Library library;
      setUp(() async {
        dir = await Directory.systemTemp.createTemp('listing_bounds');
        library = Library(dir, craft, native)..seed();
      });
      tearDown(() => dir.delete(recursive: true));

      /// The names and last-opened dates the craft's listing gives.
      Future<List<(String, DateTime)>> listing() async => switch (craft) {
            'Weaving' => [
                for (final e in await DraftRepository(draftsDirOverride: dir).list())
                  (e.meta.name, e.meta.lastOpened),
              ],
            'Knitting' => [
                for (final e in await (KnitRepository()..dirOverride = dir).listKnits())
                  (e.meta.name, e.meta.lastOpened),
              ],
            'TabletWeaving' => [
                for (final e in await (TabletRepository()..dirOverride = dir).listBands())
                  (e.meta.name, e.meta.lastOpened),
              ],
            _ => [
                for (final e in await (NalbindRepository()..dirOverride = dir).listProjects())
                  (e.name, e.lastOpened),
              ],
          };

      test('lists every project, large or past the bounds, and leaves out what is no sidecar',
          () async {
        final before = library.snapshot();
        final listed = await listing();
        final names = [for (final (name, _) in listed) name];
        expect(names.take(3), Library.listed);
        expect(names.skip(3).toSet(), Library.notDecoded);
        expect(names, hasLength(Library.listed.length + Library.notDecoded.length));
        expect(listed[0].$2, DateTime.utc(2026, 1, 5));
        expect(listed[1].$2, DateTime.utc(2026, 1, 4), reason: 'decoded off the calling isolate');
        expect(listed[2].$2, DateTime.utc(2026, 1, 3));
        for (final (_, date) in listed.skip(3)) {
          expect(date, library.stamp.toUtc(), reason: 'dated by the file\'s last change');
        }
        expect(library.snapshot(), before, reason: 'listing changes nothing on disk');
      });
    });
  }

  group('what a listing holds', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('listing_meta'));
    tearDown(() => dir.delete(recursive: true));

    File put(String id, String text) =>
        File(p.join(dir.path, '$id.json'))..writeAsStringSync(text);

    test('a small sidecar in full; a large one without its notes, plans and unknown keys',
        () async {
      final small = put('small', sidecarText('Weaving', 'Small', 1, notes: 'Sett 24.'));
      final many = put('many', sidecarText('Weaving', 'Many', 2, more: zeros(20000)));
      final long = put('long', sidecarText('Weaving', 'Long', 3, notes: 'y' * (1 << 20)));
      final metas = await readListedSidecars([small, many, long], craft: 'Weaving');
      expect(metas[0], DraftMeta.fromJson(jsonDecode(small.readAsStringSync())));
      expect(metas[0]!.notes, 'Sett 24.');
      expect(metas[0]!.extra, {'kept': true});
      for (final (meta, name, day) in [(metas[1]!, 'Many', 2), (metas[2]!, 'Long', 3)]) {
        expect(meta.name, name);
        expect(meta.craft, 'Weaving');
        expect(meta.lastOpened, DateTime.utc(2026, 1, day));
        expect(meta.savedAt, DateTime.utc(2026, 1, 1));
        expect(meta.notes, '', reason: 'left on disk');
        expect(meta.extra, isEmpty, reason: 'left on disk');
      }
    });

    test('a sidecar that cannot be read is left out', () async {
      final gone = File(p.join(dir.path, 'gone.json'));
      final ok = put('ok', sidecarText('Knitting', 'Ok', 1));
      final big = put('big', sidecarText('Knitting', 'Big', 2, more: zeros(20000)));
      final bigGone = File(p.join(dir.path, 'big-gone.json'));
      final metas = await readListedSidecars([gone, ok, bigGone, big], craft: 'Knitting');
      expect([for (final m in metas) m?.name], [null, 'Ok', null, 'Big']);
    });
  });

  group('past the bounds, JSON or not', () {
    // Past the bounds a sidecar is not decoded, so the listing cannot tell whether it is JSON: one
    // that starts as an object and is UTF-8 lists, under the top-level name at its head or its id.
    // Opening or renaming one that is not JSON then fails as it always did, writing nothing, and
    // deleting it works.
    late Directory dir;
    late DraftRepository repo;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('listing_not_json');
      repo = DraftRepository(draftsDirOverride: dir);
      void put(String id, String text) {
        File(p.join(dir.path, '$id.json')).writeAsStringSync(text);
        File(p.join(dir.path, '$id.wif')).writeAsStringSync('[WIF]');
      }

      // Never closed.
      put('truncated',
          '{"name":"Truncated","craft":"Weaving",${zeros(250000).replaceFirst(']', '')}');
      // Not JSON after its first character.
      put('garbage', '{ not json ${List.filled(250000, 'x').join(' ')}');
      // Its only name at the head is a loom plan's: listed by its id.
      put('nested', '{"loomPlan":{"name":"Loom A"},"craft":"Weaving",${zeros(250000)}}');
      put('named', '{"loomPlan":{"name":"Loom A"},"name":"Real",${zeros(250000)}}');
    });
    tearDown(() => dir.delete(recursive: true));

    Map<String, String> onDisk() => {
          for (final f in dir.listSync().whereType<File>())
            p.basename(f.path): base64.encode(f.readAsBytesSync()),
        };

    test('lists, cannot be opened or renamed, writes nothing, and can be deleted', () async {
      final before = onDisk();
      final listed = {for (final e in await repo.list()) e.id: e.meta.name};
      expect(listed, {
        'truncated': 'Truncated',
        'garbage': 'garbage',
        'nested': 'nested',
        'named': 'Real',
      });
      for (final id in ['truncated', 'garbage']) {
        await expectLater(repo.open(id), throwsA(isA<FormatException>()), reason: id);
        await expectLater(repo.rename(id, 'New'), throwsA(isA<FormatException>()), reason: id);
      }
      expect(onDisk(), before, reason: 'listing, and the failed open and rename, wrote nothing');
      await repo.delete('garbage');
      expect({for (final e in await repo.list()) e.id}, {'truncated', 'nested', 'named'});
      expect(File(p.join(dir.path, 'garbage.json')).existsSync(), isFalse);
      expect(File(p.join(dir.path, 'garbage.wif')).existsSync(), isFalse);
    });
  });

  testWidgets('the weaving library shows large sidecars and ones past the bounds', (tester) async {
    late Directory dir;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('listing_screen');
      Library(dir, 'Weaving', 'wif').seed();
    });
    addTearDown(() => dir.deleteSync(recursive: true));
    final repo = _NoThumbnails(dir);
    await tester.pumpWidget(ProviderScope(
      overrides: [repositoryProvider.overrideWithValue(repo)],
      child: MaterialApp(home: LibraryScreen(repository: repo)),
    ));
    // The listing reads the files, and the large sidecars on a background isolate, in real time:
    // each step of it needs a turn of real time and a pump.
    for (var i = 0; i < 1000 && find.text('Many values').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump();
    }
    for (final name in [...Library.listed, ...Library.notDecoded]) {
      await tester.scrollUntilVisible(find.text(name), 200,
          scrollable: find.byType(Scrollable).first);
      expect(find.text(name), findsOneWidget, reason: name);
    }
  });
}

/// The weaving repository over [dir], with nothing to draw: the library's missing thumbnails are
/// not rebuilt (no engine on the host).
class _NoThumbnails extends DraftRepository {
  _NoThumbnails(Directory dir) : super(draftsDirOverride: dir);

  @override
  Future<void> rebuildThumbnail(String id) async {}

  @override
  Future<bool?> hasCloth(String id) async => false;
}
