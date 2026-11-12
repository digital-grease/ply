import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:ply/src/data/library_backup.dart';
import 'package:ply/src/data/ustar.dart';
import 'package:ply/src/models/nalbind_project.dart';
import 'package:ply/src/models/native_format.dart';

import 'backup_test_support.dart';

// Library backup and restore over temp directories (no FFI, no path_provider): the export layout
// and manifest, every rule a restore uses to refuse a hostile or damaged archive (each archive built
// here, never a checked-in binary), the per-project format checks, the preview's classification, and
// the transactional commit (sidecar last, copies for conflicts, byte-identical library on failure).

// --- Crafted archives ---------------------------------------------------------------------------

Map<String, Object?> manifestFor(List<(String, List<int>)> files, {int schemaVersion = 1}) => {
      'format': 'ply.backup',
      'schema_version': schemaVersion,
      'created_at': '2026-11-12T10:30:00.000Z',
      'app_version': 'crafted',
      'files': [
        for (final (path, data) in files)
          {
            'path': path,
            'size': data.length,
            'sha256': sha256.convert(data).toString(),
            'craft': classifyLibraryPath(path)?.craft.manifestName ?? 'weaving',
            'project': classifyLibraryPath(path)?.projectId ?? 'x',
          },
      ],
    };

(UstarHeader, List<int>) entry(String path, List<int> data, {String typeflag = '0'}) =>
    (UstarHeader(name: path, size: data.length, typeflag: typeflag), data);

(UstarHeader, List<int>) manifestEntry(Object? json) {
  final b = utf8.encode(jsonEncode(json));
  return (UstarHeader.file(backupManifestPath, b.length), b);
}

Future<File> archiveFile(List<(UstarHeader, List<int>)> entries, {List<int> tail = const []}) async {
  final b = BytesBuilder();
  for (final (h, d) in entries) {
    b
      ..add(h.encode())
      ..add(d)
      ..add(Uint8List(ustarPadding(d.length)));
  }
  b
    ..add(Uint8List(ustarEndLength))
    ..add(tail);
  final f = File(p.join(work.path, 'crafted.plybackup'));
  await f.writeAsBytes(b.takeBytes());
  return f;
}

/// A valid backup of [files] (manifest listing exactly them), plus [extra] raw entries after them.
Future<File> craft(List<(String, List<int>)> files,
        {List<(UstarHeader, List<int>)> extra = const [], Map<String, Object?>? manifest}) =>
    archiveFile([
      manifestEntry(manifest ?? manifestFor(files)),
      for (final (path, data) in files) entry(path, data),
      ...extra,
    ]);

final List<(String, List<int>)> goodDraft = [
  ('drafts/a.wif', wifBytes),
  ('drafts/a.json', sidecar('A', 'Weaving')),
];

Matcher throwsBackup(BackupProblem problem) =>
    throwsA(isA<BackupException>().having((e) => e.problem, 'problem', problem));

/// [archive] is refused as a whole with [problem], and the library is untouched.
Future<void> expectRefused(File archive, BackupProblem problem,
    {BackupLimits limits = const BackupLimits()}) async {
  final before = await snapshot(docs);
  await expectLater(service(limits: limits).inspectBackup(archive), throwsBackup(problem));
  expect(await snapshot(docs), before);
}

RestoreProject only(RestorePlan plan, String id) => plan.projects.singleWhere((p) => p.id == id);

void main() {
  setUp(() async {
    docs = await Directory.systemTemp.createTemp('backup_docs');
    work = await Directory.systemTemp.createTemp('backup_work');
  });
  tearDown(() async {
    await docs.delete(recursive: true);
    await work.delete(recursive: true);
  });

  group('library layout', () {
    test('accepts exactly the files a backup carries', () {
      for (final path in [
        'drafts/d1.wif',
        'drafts/d1.json',
        'knits/0b7e6a50-1f2c-4d3e-8a9b-0c1d2e3f4a5b.plyknit',
        'knits/k_1.plyknit.v12.bak',
        'nalbinds/n-1.plynal',
        'nalbinds/n1.photos/aaa.jpg',
        'nalbinds/n1.photos/aaa.JPEG',
        'nalbinds/n1.photos/b.heic',
        'nalbinds/n1.photos/c.webp',
      ]) {
        expect(classifyLibraryPath(path), isNotNull, reason: path);
      }
      final bak = classifyLibraryPath('knits/k.plyknit.v3.bak')!;
      expect((bak.craft, bak.projectId, bak.role, bak.version),
          (BackupCraft.knitting, 'k', BackupFileRole.upgradeBackup, 3));
      expect(bak.pathFor('new'), 'knits/new.plyknit.v3.bak');
      final photo = classifyLibraryPath('nalbinds/n.photos/x.png')!;
      expect(photo.pathFor('m'), 'nalbinds/m.photos/x.png');
    });

    test('rejects anything else', () {
      for (final path in [
        '',
        '/drafts/a.wif',
        'drafts/../drafts/a.wif',
        '../a.wif',
        'drafts/./a.wif',
        'drafts//a.wif',
        r'drafts\a.wif',
        'drafts/a.wif/',
        'drafts/a.png', // thumbnails are rebuildable, never carried
        'drafts/a.plyknit', // the wrong craft's document
        'drafts/a.wif.tmp',
        'drafts/a.b.wif', // ids have no dots
        'drafts/.json',
        'drafts/-a.wif',
        'drafts/${'x' * 65}.wif',
        'knits/a.plyknit.v0.bak',
        'knits/a.plyknit.v1.bak.tmp',
        'drafts/a.plyknit.v1.bak',
        'nalbinds/a.photos/x.gif',
        'nalbinds/a.photos/x.jpg.tmp',
        'nalbinds/a.photos/sub/x.jpg',
        'knits/a.photos/x.jpg',
        'nalbinds/a.photos',
        'app_settings.json',
        'manifest.json',
        'other/a.wif',
      ]) {
        expect(classifyLibraryPath(path), isNull, reason: path);
      }
    });
  });

  group('making a backup', () {
    test('carries every project file verbatim, manifest first, thumbnails and leftovers left out',
        () async {
      await seedLibrary(docs);
      final s = service();
      final plan = await s.planBackup();
      expect(plan.projectCounts,
          {BackupCraft.weaving: 2, BackupCraft.knitting: 1, BackupCraft.nalbinding: 1});
      expect(plan.photoCount, 2);
      expect(plan.fileName, 'ply-library-2026-11-12.plybackup');
      final bytes = await s.buildBackup(plan);
      expect(bytes.length, plan.archiveSize);

      final f = File(p.join(work.path, 'b.plybackup'));
      await f.writeAsBytes(bytes);
      final entries = await entriesOf(f);
      expect(entries.first.$1, backupManifestPath);
      expect([for (final (path, _) in entries.skip(1)) path], [
        'drafts/d1.wif',
        'drafts/d1.json',
        'drafts/d2.wif',
        'drafts/d2.json',
        'knits/k1.plyknit',
        'knits/k1.plyknit.v1.bak',
        'knits/k1.json',
        'nalbinds/n1.plynal',
        'nalbinds/n1.photos/aaa.jpg',
        'nalbinds/n1.photos/bbb.png',
        'nalbinds/n1.json',
      ]);
      for (final (path, data) in entries.skip(1)) {
        expect(data, await File(p.join(docs.path, path)).readAsBytes(), reason: path);
      }

      final manifest = jsonDecode(utf8.decode(entries.first.$2)) as Map<String, dynamic>;
      expect(manifest['format'], 'ply.backup');
      expect(manifest['schema_version'], 1);
      expect(manifest['created_at'], '2026-11-12T10:30:00.000Z');
      expect(manifest['app_version'], '9.9.9-test');
      final files = manifest['files'] as List;
      expect(files, hasLength(11));
      final photo = files.firstWhere((f) => f['path'] == 'nalbinds/n1.photos/aaa.jpg');
      expect(photo, {
        'path': 'nalbinds/n1.photos/aaa.jpg',
        'size': photo1.length,
        'sha256': sha256.convert(photo1).toString(),
        'craft': 'nalbinding',
        'project': 'n1',
      });
    });

    test('an empty library has nothing to back up', () async {
      await put(docs, 'app_settings.json', [1]);
      await expectLater(service().planBackup(), throwsBackup(BackupProblem.noProjects));
    });

    test('a library over the limits is refused before anything is saved', () async {
      await seedLibrary(docs);
      await expectLater(
          service(limits: const BackupLimits(maxFileBytes: 1000)).planBackup(),
          throwsA(isA<BackupException>()
              .having((e) => e.problem, 'problem', BackupProblem.fileTooLarge)
              .having((e) => e.projectName, 'project', 'Mitten')));
      await expectLater(service(limits: const BackupLimits(maxExportBytes: 10000)).planBackup(),
          throwsBackup(BackupProblem.libraryTooLarge));
      await expectLater(service(limits: const BackupLimits(maxEntries: 5)).planBackup(),
          throwsBackup(BackupProblem.libraryTooManyFiles));
    });

    test('a file that changes between planning and writing aborts the backup', () async {
      await seedLibrary(docs);
      final s = service();
      final plan = await s.planBackup();
      await put(docs, 'drafts/d2.wif', utf8.encode('[WEAVING]\nShafts=8\n')); // same length
      await expectLater(s.buildBackup(plan), throwsBackup(BackupProblem.libraryChanged));
      await put(docs, 'drafts/d2.wif', utf8.encode('[WEAVING]\nShafts=4\n'));
      await File(p.join(docs.path, 'nalbinds', 'n1.photos', 'bbb.png')).delete(); // deleted
      await expectLater(s.buildBackup(plan), throwsBackup(BackupProblem.libraryChanged));
    });

    test('symbolic links in the library are not followed', () async {
      await seedLibrary(docs);
      final outside = File(p.join(work.path, 'secret.jpg'))..writeAsBytesSync([1, 2]);
      await Link(p.join(docs.path, 'nalbinds', 'n1.photos', 'zzz.jpg')).create(outside.path);
      await Link(p.join(docs.path, 'drafts', 'link.json')).create(outside.path);
      final plan = await service().planBackup();
      expect(plan.files.map((f) => f.archivePath), isNot(contains('nalbinds/n1.photos/zzz.jpg')));
      expect(plan.files.map((f) => f.archivePath), isNot(contains('drafts/link.json')));
    });
  });

  group('a restore refuses the whole backup', () {
    test('when it is not a Ply backup', () async {
      final junk = File(p.join(work.path, 'photo.jpg'))..writeAsBytesSync(photo1);
      await expectRefused(junk, BackupProblem.notABackup);
      await expectRefused(File(p.join(work.path, 'empty'))..writeAsBytesSync([]),
          BackupProblem.notABackup);
      await expectRefused(await archiveFile([...goodDraft.map((f) => entry(f.$1, f.$2))]),
          BackupProblem.notABackup); // no manifest first
      await expectRefused(
          await archiveFile([manifestEntry({'format': 'other', 'schema_version': 1})]),
          BackupProblem.notABackup);
      await expectRefused(
          await archiveFile([(UstarHeader.file(backupManifestPath, 3), utf8.encode('{x}'))]),
          BackupProblem.notABackup);
    });

    test('when the manifest is from a newer backup schema, before reading anything else',
        () async {
      await expectRefused(await craft(goodDraft, manifest: manifestFor(goodDraft, schemaVersion: 2)),
          BackupProblem.newerBackup);
      await expectRefused(
          await archiveFile([
            manifestEntry({'format': 'ply.backup', 'schema_version': 99, 'files': 'unknown'}),
          ]),
          BackupProblem.newerBackup);
    });

    test('for an absolute path, "..", a backslash, or any path outside the layout', () async {
      for (final path in [
        '/drafts/b.wif',
        'drafts/../drafts/b.wif',
        '../b.wif',
        'drafts/./b.wif',
        r'drafts\b.wif',
        'app_settings.json',
        'drafts/b.png',
        'knits/b.wif',
        'nalbinds/b.photos/sub/c.jpg',
        backupManifestPath, // a second manifest
      ]) {
        // Listed in the manifest (caught there) ...
        final listed = [...goodDraft, (path, wifBytes)];
        await expectRefused(await craft(listed), BackupProblem.unsafe);
        // ... or only present in the archive (caught on the entry).
        await expectRefused(await craft(goodDraft, extra: [entry(path, wifBytes)]),
            BackupProblem.unsafe);
      }
    });

    test('for links, devices, directories and other non-regular entries', () async {
      for (final type in ['1', '2', '3', '4', '5', '6']) {
        await expectRefused(
            await craft(goodDraft, extra: [
              (UstarHeader(name: 'drafts/b.wif', size: 0, typeflag: type, linkname: '/etc/passwd'),
                  []),
            ]),
            BackupProblem.unsafe);
      }
    });

    test('for a duplicate path, also one differing only in case', () async {
      await expectRefused(await craft(goodDraft, extra: [entry('drafts/a.wif', wifBytes)]),
          BackupProblem.unsafe);
      await expectRefused(await craft([...goodDraft, ('drafts/A.wif', wifBytes)]),
          BackupProblem.unsafe);
      final twice = manifestFor(goodDraft);
      (twice['files'] as List).add((twice['files'] as List).first);
      await expectRefused(await craft(goodDraft, manifest: twice), BackupProblem.unsafe);
    });

    test('over the hard limits: archive size, entry count, entry size, path length', () async {
      final ok = await craft(goodDraft);
      await expectRefused(ok, BackupProblem.backupTooLarge,
          limits: const BackupLimits(maxArchiveBytes: 2048));
      await expectRefused(ok, BackupProblem.backupTooManyFiles,
          limits: const BackupLimits(maxEntries: 2));
      // More entries than the manifest lists also hits the count before anything else.
      await expectRefused(await craft(goodDraft, extra: [entry('drafts/b.wif', wifBytes)]),
          BackupProblem.backupTooManyFiles,
          limits: const BackupLimits(maxEntries: 3));
      await expectRefused(ok, BackupProblem.unsafe, limits: const BackupLimits(maxFileBytes: 10));
      await expectRefused(ok, BackupProblem.unsafe,
          limits: const BackupLimits(maxSidecarBytes: 10));
      await expectRefused(ok, BackupProblem.unsafe, limits: const BackupLimits(maxPathLength: 10));
      await expectRefused(ok, BackupProblem.notABackup,
          limits: const BackupLimits(maxManifestBytes: 10));
    });

    test('when a checksum does not match, before anything is written', () async {
      await seedLibrary(docs);
      final m = manifestFor(goodDraft);
      ((m['files'] as List).first as Map)['sha256'] = sha256.convert([0]).toString();
      await expectRefused(await craft(goodDraft, manifest: m), BackupProblem.damaged);
      // A flipped byte in a photo's data, in a real backup.
      final source = await Directory.systemTemp.createTemp('backup_src');
      addTearDown(() => source.delete(recursive: true));
      await seedLibrary(source);
      final archive = await backUp(service(into: source));
      final bytes = await archive.readAsBytes();
      final at = _indexOf(bytes, photo1);
      bytes[at + 100] ^= 0xFF;
      await archive.writeAsBytes(bytes);
      await expectRefused(archive, BackupProblem.damaged);
    });

    test('when sizes, the file list, or the manifest fields do not agree', () async {
      final size = manifestFor(goodDraft);
      ((size['files'] as List).first as Map)['size'] = 1;
      await expectRefused(await craft(goodDraft, manifest: size), BackupProblem.damaged);
      // An entry the manifest does not list.
      await expectRefused(await craft(goodDraft, extra: [entry('drafts/b.wif', wifBytes)]),
          BackupProblem.damaged);
      // A listed file that is missing.
      await expectRefused(
          await craft([goodDraft.first], manifest: manifestFor(goodDraft)), BackupProblem.damaged);
      // A craft or project that does not match the path.
      final wrong = manifestFor(goodDraft);
      ((wrong['files'] as List).first as Map)['project'] = 'b';
      await expectRefused(await craft(goodDraft, manifest: wrong), BackupProblem.damaged);
      final noFiles = manifestFor(goodDraft)..remove('files');
      await expectRefused(await craft(goodDraft, manifest: noFiles), BackupProblem.damaged);
      final noDate = manifestFor(goodDraft)..['created_at'] = 'yesterday';
      await expectRefused(await craft(goodDraft, manifest: noDate), BackupProblem.damaged);
    });

    test('when the archive is cut short or has data after its end', () async {
      final whole = await (await craft(goodDraft)).readAsBytes();
      final cut = File(p.join(work.path, 'cut'))
        ..writeAsBytesSync(Uint8List.sublistView(whole, 0, whole.length - 700));
      await expectRefused(cut, BackupProblem.damaged);
      await expectRefused(await archiveFile([
        manifestEntry(manifestFor(goodDraft)),
        for (final (path, data) in goodDraft) entry(path, data),
      ], tail: [1]), BackupProblem.damaged);
    });
  });

  group('a restore checks each project with the format probes', () {
    test('and refuses, with the reason, a project newer than this build or unreadable', () async {
      final files = [
        ...goodDraft,
        ('knits/new.plyknit', knitFile(version: knitVersion + 1)),
        ('knits/new.json', sidecar('From the future', 'Knitting')),
        ('knits/junk.plyknit', utf8.encode('not json')),
        ('knits/junk.json', sidecar('Junk', 'Knitting')),
        ('knits/bak.plyknit', knitFile()),
        ('knits/bak.plyknit.v1.bak', knitFile()), // its content is not version 1
        ('knits/bak.json', sidecar('Odd backup', 'Knitting')),
        ('knits/nbak.plyknit', knitFile()),
        ('knits/nbak.plyknit.v${knitVersion + 1}.bak', knitFile(version: knitVersion + 1)),
        ('knits/nbak.json', sidecar('Newer backup', 'Knitting')),
        ('nalbinds/nn.plynal', utf8.encode(jsonEncode({
          'format': 'ply.nalbind',
          'schemaVersion': NalbindProject.currentSchemaVersion + 1,
          'name': 'x',
        }))),
        ('nalbinds/nn.json', sidecar('Newer nalbind', 'Nalbinding')),
        ('drafts/side.wif', wifBytes),
        ('drafts/side.json', sidecar('Newer sidecar', 'Weaving', extra: {'schemaVersion': 2})),
        ('drafts/bin.wif', [0xFF, 0xFE, 0x00]),
        ('drafts/bin.json', sidecar('Not text', 'Weaving')),
        ('drafts/alone.wif', wifBytes), // no sidecar
        ('nalbinds/nosc.json', sidecar('No document', 'Nalbinding')),
        ('knits/legacy.plyknit', legacyKnit), // version 1: fine
        ('knits/legacy.json', sidecar('Legacy', 'Knitting')),
      ];
      final plan = await service().inspectBackup(await craft(files));
      String? reason(String id) => only(plan, id).refusal?.message;
      expect(only(plan, 'a').status, RestoreStatus.add);
      expect(only(plan, 'legacy').status, RestoreStatus.add);
      const newer = 'Made by a newer version of Ply. Update the app to restore it.';
      const unreadable = 'A file in this project could not be read.';
      const missing = 'Part of this project is missing from the backup.';
      expect(reason('new'), newer);
      expect(only(plan, 'new').name, 'From the future');
      expect(reason('junk'), unreadable);
      expect(reason('bak'), unreadable);
      expect(reason('nbak'), newer);
      expect(reason('nn'), newer);
      expect(reason('side'), newer);
      expect(reason('bin'), unreadable);
      expect(reason('alone'), missing);
      expect(only(plan, 'alone').name, 'Untitled');
      expect(reason('nosc'), missing);
      for (final p in plan.projects.where((p) => p.status == RestoreStatus.refused)) {
        expect(p.targetId, isNull);
      }

      // The rest restores; the refused projects are not written.
      final result = await service().restore(plan);
      expect(result.restored.map((r) => r.id), unorderedEquals(['a', 'legacy']));
      expect(File(p.join(docs.path, 'knits', 'new.plyknit')).existsSync(), isFalse);
    });

    test('and also asks the engine when it can (production passes the parsers)', () async {
      final files = [
        ...goodDraft,
        ('knits/k.plyknit', knitFile()),
        ('knits/k.json', sidecar('K', 'Knitting')),
      ];
      final plan = await service(
        checks: NativeFileChecks(
          wif: (_) async => throw const FormatException('no WEAVING'),
          knit: (_) async => throw const NativeFormatException(NativeFormatProblem.newerVersion,
              document: NativeDocument.knitPattern),
        ),
      ).inspectBackup(await craft(files));
      expect(only(plan, 'a').refusal, RestoreRefusal.unreadable);
      expect(only(plan, 'k').refusal, RestoreRefusal.newerVersion);
    });
  });

  group('restoring', () {
    test('into an empty library brings back every project, photos and upgrade backups included',
        () async {
      final source = await Directory.systemTemp.createTemp('backup_src');
      addTearDown(() => source.delete(recursive: true));
      await seedLibrary(source);
      final archive = await backUp(service(into: source));

      final thumbs = <(BackupCraft, String)>[];
      final s = service(thumbnails: thumbs);
      final plan = await s.inspectBackup(archive);
      expect(plan.appVersion, '9.9.9-test');
      expect(plan.createdAt, DateTime.utc(2026, 11, 12, 10, 30));
      expect(plan.projects.every((p) => p.status == RestoreStatus.add), isTrue);
      expect(only(plan, 'n1').photoCount, 2);
      final result = await s.restore(plan);
      expect(result.count, 4);

      // Byte-identical to the source library, minus what a backup leaves out.
      final expected = await snapshot(source)
        ..removeWhere((path, _) =>
            path.endsWith('.png') && !path.contains('.photos/') ||
            path.endsWith('.tmp') ||
            path.contains('orphan') ||
            path.contains('lonely') ||
            path == 'app_settings.json');
      expect(await snapshot(docs), expected);
      // Thumbnails are rebuilt for the crafts that have them.
      expect(thumbs, unorderedEquals([
        (BackupCraft.weaving, 'd1'),
        (BackupCraft.weaving, 'd2'),
        (BackupCraft.knitting, 'k1'),
      ]));
    });

    test('skips projects already in the library, even when opened since the backup', () async {
      await seedLibrary(docs);
      final archive = await backUp(service());
      // Opened since (lastOpened bumped) and rewritten with another key order: still the same.
      final reordered = jsonDecode(utf8.decode(sidecar('Twill', 'Weaving',
          extra: {'futureKey': {'kept': true}, 'lastOpened': '2026-11-01T00:00:00.000Z'})))
          as Map<String, dynamic>;
      await put(docs, 'drafts/d1.json',
          utf8.encode(jsonEncode(Map.fromEntries(reordered.entries.toList().reversed))));
      final before = await snapshot(docs);
      final plan = await service().inspectBackup(archive);
      expect(plan.projects.map((p) => p.status).toSet(), {RestoreStatus.alreadyPresent});
      final result = await service().restore(plan);
      expect(result.count, 0);
      expect(await snapshot(docs), before);
    });

    test('keeps both on a conflict: the copy gets a new id and name, the original is untouched',
        () async {
      await seedLibrary(docs);
      final archive = await backUp(service());
      // Edited since the backup: a draft, a pattern's name, a project's photo.
      await put(docs, 'drafts/d1.wif', utf8.encode('[WEAVING]\nShafts=8\n'));
      await put(docs, 'knits/k1.json', sidecar('Hat v2', 'Knitting'));
      await put(docs, 'nalbinds/n1.photos/aaa.jpg', [9, 9, 9]);
      final before = await snapshot(docs);

      final thumbs = <(BackupCraft, String)>[];
      final plan = await service(thumbnails: thumbs).inspectBackup(archive);
      expect(only(plan, 'd2').status, RestoreStatus.alreadyPresent);
      for (final id in ['d1', 'k1', 'n1']) {
        final c = only(plan, id);
        expect(c.status, RestoreStatus.conflict, reason: id);
        expect(c.targetId, isNot(id));
        expect(isBackupProjectId(c.targetId!), isTrue);
      }
      expect(only(plan, 'd1').targetName, 'Twill (restored)');
      expect(only(plan, 'k1').targetName, 'Hat (restored)');

      final result = await service(thumbnails: thumbs).restore(plan);
      expect(result.count, 3);
      final after = await snapshot(docs);
      // Every original file is exactly as it was.
      for (final e in before.entries) {
        expect(after[e.key], e.value, reason: e.key);
      }
      // The copies: documents, upgrade backups and photos byte for byte; only the sidecar name
      // changed, unknown keys kept.
      final d1 = only(plan, 'd1').targetId!;
      expect(after['drafts/$d1.wif'], wifBytes);
      final copySidecar = jsonDecode(utf8.decode(after['drafts/$d1.json']!)) as Map;
      final originalSidecar =
          jsonDecode(utf8.decode(sidecar('Twill', 'Weaving', extra: {'futureKey': {'kept': true}})))
              as Map;
      expect(copySidecar, {...originalSidecar, 'name': 'Twill (restored)'});
      final k1 = only(plan, 'k1').targetId!;
      expect(after['knits/$k1.plyknit.v1.bak'], legacyKnit);
      final n1 = only(plan, 'n1').targetId!;
      expect(after['nalbinds/$n1.photos/aaa.jpg'], photo1);
      expect(after['nalbinds/$n1.photos/bbb.png'], photo2);
      expect(after.keys.where((k) => !before.containsKey(k)).toSet(), {
        'drafts/$d1.wif',
        'drafts/$d1.json',
        'knits/$k1.plyknit',
        'knits/$k1.plyknit.v1.bak',
        'knits/$k1.json',
        'nalbinds/$n1.plynal',
        'nalbinds/$n1.json',
        'nalbinds/$n1.photos/',
        'nalbinds/$n1.photos/aaa.jpg',
        'nalbinds/$n1.photos/bbb.png',
      });
      expect(thumbs, unorderedEquals([(BackupCraft.weaving, d1), (BackupCraft.knitting, k1)]));

      // Restoring the same backup again finds the copies (the copy id is deterministic).
      final again = await service().inspectBackup(archive);
      expect(again.projects.map((p) => p.status).toSet(), {RestoreStatus.alreadyPresent});
    });

    test('an unticked conflict is not restored', () async {
      await seedLibrary(docs);
      final archive = await backUp(service());
      await put(docs, 'drafts/d1.wif', utf8.encode('[WEAVING]\nShafts=8\n'));
      await put(docs, 'drafts/d2.wif', utf8.encode('[WEAVING]\nShafts=6\n'));
      final plan = await service().inspectBackup(archive);
      final result =
          await service().restore(plan, skippedConflicts: {only(plan, 'd1').key});
      expect(result.restored.single.id, only(plan, 'd2').targetId);
    });

    test('any leftover file of an id (here a thumbnail) makes it a conflict', () async {
      await put(docs, 'drafts/a.png', [1]);
      final plan = await service().inspectBackup(await craft(goodDraft));
      expect(only(plan, 'a').status, RestoreStatus.conflict);
    });

    test('moves each project into place with its sidecar last', () async {
      final source = await Directory.systemTemp.createTemp('backup_src');
      addTearDown(() => source.delete(recursive: true));
      await seedLibrary(source);
      final archive = await backUp(service(into: source));
      final order = <String>[];
      final s = service(beforePlace: (t) async => order.add(p.relative(t, from: docs.path)));
      await s.restore(await s.inspectBackup(archive));
      expect(order, [
        p.join('drafts', 'd1.wif'),
        p.join('drafts', 'd1.json'),
        p.join('drafts', 'd2.wif'),
        p.join('drafts', 'd2.json'),
        p.join('knits', 'k1.plyknit'),
        p.join('knits', 'k1.plyknit.v1.bak'),
        p.join('knits', 'k1.json'),
        p.join('nalbinds', 'n1.plynal'),
        p.join('nalbinds', 'n1.photos'),
        p.join('nalbinds', 'n1.json'),
      ]);
    });

    test('a failure part-way leaves the library byte-identical', () async {
      await seedLibrary(docs);
      final source = await Directory.systemTemp.createTemp('backup_src');
      addTearDown(() => source.delete(recursive: true));
      await seedLibrary(source);
      // Different content under the same ids, plus a project the library lacks.
      await put(source, 'drafts/d1.wif', utf8.encode('[WEAVING]\nShafts=3\n'));
      await put(source, 'nalbinds/n1.photos/aaa.jpg', [7]);
      await put(source, 'knits/k9.plyknit', knitFile());
      await put(source, 'knits/k9.json', sidecar('New', 'Knitting'));
      final archive = await backUp(service(into: source));
      final before = await snapshot(docs);

      // Seven moves: the d1 copy (document, sidecar), the n1 copy (document, photo folder,
      // sidecar) and the new k9 (document, sidecar); d2 and k1 are already present. Fail at each.
      for (var failAt = 0; failAt < 7; failAt++) {
        var n = 0;
        final s = service(beforePlace: (_) async {
          if (n++ == failAt) throw const FileSystemException('disk full');
        });
        final plan = await s.inspectBackup(archive);
        expect(plan.projects.where((p) => p.status != RestoreStatus.alreadyPresent), hasLength(3));
        await expectLater(s.restore(plan), throwsBackup(BackupProblem.restoreFailed));
        expect(await snapshot(docs), before, reason: 'failed at move $failAt');
      }
    });

    test('a failure into an empty library also removes the folders it created', () async {
      final source = await Directory.systemTemp.createTemp('backup_src');
      addTearDown(() => source.delete(recursive: true));
      await seedLibrary(source);
      final archive = await backUp(service(into: source));
      var n = 0;
      final s = service(beforePlace: (_) async {
        if (n++ == 6) throw StateError('injected');
      });
      await expectLater(s.restore(await s.inspectBackup(archive)),
          throwsBackup(BackupProblem.restoreFailed));
      expect(await snapshot(docs), isEmpty);
    });

    test('a backup that changes after it was checked is not restored', () async {
      final source = await Directory.systemTemp.createTemp('backup_src');
      addTearDown(() => source.delete(recursive: true));
      await seedLibrary(source);
      final archive = await backUp(service(into: source));
      await seedLibrary(docs);
      await put(docs, 'nalbinds/n1.photos/aaa.jpg', [1]); // so n1 is restored as a copy
      final s = service();
      final plan = await s.inspectBackup(archive);
      final bytes = await archive.readAsBytes();
      bytes[_indexOf(bytes, photo1) + 10] ^= 0xFF;
      await archive.writeAsBytes(bytes);
      final before = await snapshot(docs);
      await expectLater(s.restore(plan), throwsBackup(BackupProblem.restoreFailed));
      expect(await snapshot(docs), before);
    });

    test('a target that appears in the library after the preview stops the restore', () async {
      final plan = await service().inspectBackup(await craft(goodDraft));
      await put(docs, 'drafts/a.json', sidecar('Made meanwhile', 'Weaving'));
      final before = await snapshot(docs);
      await expectLater(service().restore(plan), throwsBackup(BackupProblem.restoreFailed));
      expect(await snapshot(docs), before);
    });

    test('a staging folder left by a crash is swept on the next check', () async {
      await put(docs, '${LibraryBackup.stagingPrefix}old/drafts/x.wif', wifBytes);
      await service().inspectBackup(await craft(goodDraft));
      expect(await snapshot(docs), isEmpty);
    });
  });

  test('sidecar digests ignore lastOpened and key order, and can rename', () {
    final a = {'name': 'A', 'lastOpened': '1', 'x': {'b': 1, 'a': 2}};
    final b = {'x': {'a': 2, 'b': 1}, 'lastOpened': '2', 'name': 'A'};
    expect(LibraryBackup.sidecarDigest(a), LibraryBackup.sidecarDigest(b));
    expect(LibraryBackup.sidecarDigest(a, name: 'B'),
        LibraryBackup.sidecarDigest({...b, 'name': 'B'}));
    expect(LibraryBackup.sidecarDigest(a), isNot(LibraryBackup.sidecarDigest({...a, 'x': 1})));
  });

  test('user-facing sentences', () {
    expect(formatBytes(1), '1 KB');
    expect(formatBytes(820 * 1024), '820 KB');
    expect(formatBytes(4 * 1024 * 1024 + 200 * 1024), '4.2 MB');
    expect(formatBytes(128 * 1024 * 1024), '128 MB');
    expect(const BackupException(BackupProblem.backupTooLarge, limit: 512 * 1024 * 1024).message,
        'This backup is too large to restore (over 512 MB).');
  });
}

int _indexOf(Uint8List haystack, List<int> needle) {
  outer:
  for (var i = 0; i <= haystack.length - needle.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  throw StateError('not found');
}
