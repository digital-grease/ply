import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:ply/src/data/library_backup.dart';
import 'package:ply/src/data/ustar.dart';
import 'package:ply/src/models/app_settings.dart';
import 'package:ply/src/models/draft_doc.dart' show MeasureUnit;
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
            // The app settings entry belongs to no project.
            if (path != backupSettingsPath) ...{
              'craft': classifyLibraryPath(path)?.craft.manifestName ?? 'weaving',
              'project': classifyLibraryPath(path)?.projectId ?? 'x',
            },
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
        'App_Settings.json', // the settings entry is matched exactly
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

  group('a single-project export', () {
    test('holds exactly that project, in the backup format, and never the app settings', () async {
      await seedLibrary(docs);
      final s = service(settings: const AppSettings(themeMode: ThemeMode.dark));
      for (final (craft, id, name, paths) in [
        (BackupCraft.weaving, 'd1', 'Twill', ['drafts/d1.wif', 'drafts/d1.json']),
        (
          BackupCraft.knitting,
          'k1',
          'Hat',
          ['knits/k1.plyknit', 'knits/k1.plyknit.v1.bak', 'knits/k1.json'],
        ),
        (
          BackupCraft.nalbinding,
          'n1',
          'Mitten',
          [
            'nalbinds/n1.plynal',
            'nalbinds/n1.photos/aaa.jpg',
            'nalbinds/n1.photos/bbb.png',
            'nalbinds/n1.json',
          ],
        ),
      ]) {
        final plan = await s.planProjectBackup(craft, id);
        expect(plan.contents, BackupContents.project);
        expect(plan.projectCount, 1);
        expect(plan.projectCounts[craft], 1);
        expect(plan.settings, isNull, reason: 'only a full backup carries the app settings');
        expect(plan.fileName, '$name 2026-11-12.plybackup');
        final bytes = await s.buildBackup(plan);
        expect(bytes.length, plan.archiveSize);
        final f = File(p.join(work.path, '$id.plybackup'))..writeAsBytesSync(bytes);
        final entries = await entriesOf(f);
        expect(entries.first.$1, backupManifestPath);
        expect([for (final (path, _) in entries.skip(1)) path], paths, reason: id);
        for (final (path, data) in entries.skip(1)) {
          expect(data, await File(p.join(docs.path, path)).readAsBytes(), reason: path);
        }
        final manifest = jsonDecode(utf8.decode(entries.first.$2)) as Map<String, dynamic>;
        expect(manifest['schema_version'], 1);
        expect(manifest['contents'], 'project');
        expect([for (final f in manifest['files'] as List) f['path']], paths);
      }
    });

    test('restores through the normal flow: new, already present, and a conflict', () async {
      await seedLibrary(docs);
      final archive = await exportOne(service(), BackupCraft.nalbinding, 'n1');

      // Into another, empty library: added under its own id, byte for byte.
      final other = await Directory.systemTemp.createTemp('backup_other');
      addTearDown(() => other.delete(recursive: true));
      final into = service(into: other);
      final plan = await into.inspectBackup(archive);
      expect(plan.settings, isNull);
      expect(plan.projects.single.status, RestoreStatus.add);
      expect(plan.projects.single.name, 'Mitten');
      expect((await into.restore(plan)).restored.single, (craft: BackupCraft.nalbinding, id: 'n1'));
      final restored = await snapshot(other);
      final original = await snapshot(docs);
      expect(restored.keys.toSet(), {
        'nalbinds/',
        'nalbinds/n1.plynal',
        'nalbinds/n1.json',
        'nalbinds/n1.photos/',
        'nalbinds/n1.photos/aaa.jpg',
        'nalbinds/n1.photos/bbb.png',
      });
      for (final e in restored.entries) {
        expect(e.value, original[e.key], reason: e.key);
      }

      // Back into the library it came from: already there, nothing written.
      final before = await snapshot(docs);
      final again = await service().inspectBackup(archive);
      expect(again.projects.single.status, RestoreStatus.alreadyPresent);
      expect((await service().restore(again)).count, 0);
      expect(await snapshot(docs), before);

      // After the project changed: restored as a copy, the original untouched.
      await put(docs, 'nalbinds/n1.photos/aaa.jpg', [9, 9, 9]);
      final changed = await snapshot(docs);
      final conflict = await service().inspectBackup(archive);
      final copy = conflict.projects.single;
      expect(copy.status, RestoreStatus.conflict);
      expect(copy.targetName, 'Mitten (restored)');
      expect((await service().restore(conflict)).restored.single.id, copy.targetId);
      final after = await snapshot(docs);
      for (final e in changed.entries) {
        expect(after[e.key], e.value, reason: e.key);
      }
      expect(after['nalbinds/${copy.targetId}.photos/aaa.jpg'], photo1);
    });

    test('a weaving export restores into an empty library', () async {
      await seedLibrary(docs);
      final archive = await exportOne(service(), BackupCraft.weaving, 'd1');
      final other = await Directory.systemTemp.createTemp('backup_other');
      addTearDown(() => other.delete(recursive: true));
      final thumbs = <(BackupCraft, String)>[];
      final into = service(into: other, thumbnails: thumbs);
      await into.restore(await into.inspectBackup(archive));
      expect(await snapshot(other), {
        'drafts/': const <int>[],
        'drafts/d1.wif': wifBytes,
        'drafts/d1.json': await File(p.join(docs.path, 'drafts', 'd1.json')).readAsBytes(),
      });
      expect(thumbs, [(BackupCraft.weaving, 'd1')]);
    });

    test('a project the library does not list cannot be exported', () async {
      await seedLibrary(docs);
      await put(docs, 'knits/bad.plyknit', knitFile());
      await put(docs, 'knits/bad.json', utf8.encode('not json'));
      for (final (craft, id) in [
        (BackupCraft.weaving, 'nope'),
        (BackupCraft.weaving, 'orphan'), // a document without a sidecar
        (BackupCraft.weaving, 'lonely'), // a sidecar without a document
        (BackupCraft.knitting, 'bad'), // an unreadable sidecar
        (BackupCraft.knitting, 'd1'), // the wrong craft
        (BackupCraft.weaving, '../drafts/d1'), // not an id
      ]) {
        await expectLater(service().planProjectBackup(craft, id),
            throwsBackup(BackupProblem.projectNotFound),
            reason: '$craft $id');
      }
      await expectLater(
          service(into: Directory(p.join(work.path, 'none')))
              .planProjectBackup(BackupCraft.weaving, 'd1'),
          throwsBackup(BackupProblem.projectNotFound));
    });

    test('has the same limits as a full backup, worded for one project', () async {
      await seedLibrary(docs);
      await expectLater(
          service(limits: const BackupLimits(maxFileBytes: 1000))
              .planProjectBackup(BackupCraft.nalbinding, 'n1'),
          throwsA(isA<BackupException>()
              .having((e) => e.problem, 'problem', BackupProblem.fileTooLarge)
              .having((e) => e.projectName, 'project', 'Mitten')));
      await expectLater(
          service(limits: const BackupLimits(maxExportBytes: 8000))
              .planProjectBackup(BackupCraft.nalbinding, 'n1'),
          throwsBackup(BackupProblem.projectTooLarge));
      await expectLater(
          service(limits: const BackupLimits(maxEntries: 4))
              .planProjectBackup(BackupCraft.nalbinding, 'n1'),
          throwsBackup(BackupProblem.projectTooManyFiles));
      expect(const BackupException(BackupProblem.projectTooLarge, limit: 128 * 1024 * 1024).message,
          'This project is too large for one file on this device (over 128 MB).');
      expect(const BackupException(BackupProblem.projectTooManyFiles, limit: 10000).message,
          'This project has too many files for one export (over 10000).');
      expect(const BackupException(BackupProblem.projectNotFound).message,
          'This project is no longer in your library.');
    });

    test('names its file after the project, safely', () {
      expect(BackupPlan.safeFileStem('Twill 2/2'), 'Twill 2-2');
      expect(BackupPlan.safeFileStem(r'a\b:c*d?e"f<g>h|i'), 'a-b-c-d-e-f-g-h-i');
      expect(BackupPlan.safeFileStem('  ..hidden.  '), 'hidden');
      expect(BackupPlan.safeFileStem('tab\tand\nnewline'), 'tab-and-newline');
      expect(BackupPlan.safeFileStem('many    spaces'), 'many spaces');
      expect(BackupPlan.safeFileStem(''), 'project');
      expect(BackupPlan.safeFileStem('...'), 'project');
      expect(BackupPlan.safeFileStem('Vante på norsk'), 'Vante på norsk');
      expect(BackupPlan.safeFileStem('x' * 80), 'x' * 60);
    });
  });

  group('app settings in a backup', () {
    const mine = AppSettings(
      themeMode: ThemeMode.dark,
      accentSeed: 0xFF00696E,
      useDynamicColor: false,
      unit: MeasureUnit.centimeters,
    );

    test('a full backup carries the settings in effect unless they are left out', () async {
      await seedLibrary(docs);
      final s = service(settings: mine);
      final plan = await s.planBackup();
      expect(plan.settings, isNotNull);
      expect(plan.includeSettings, isTrue, reason: 'offered, and in by default');
      final expected = utf8.encode(jsonEncode(mine.toJson()));

      final withSettings = File(p.join(work.path, 'with.plybackup'))
        ..writeAsBytesSync(await s.buildBackup(plan));
      expect(withSettings.lengthSync(), plan.archiveSize);
      final entries = await entriesOf(withSettings);
      expect(entries[1].$1, backupSettingsPath);
      expect(entries[1].$2, expected);
      final manifest = jsonDecode(utf8.decode(entries.first.$2)) as Map<String, dynamic>;
      expect(manifest['schema_version'], 1);
      expect(manifest['contents'], 'library');
      expect((manifest['files'] as List).first, {
        'path': backupSettingsPath,
        'size': expected.length,
        'sha256': sha256.convert(expected).toString(),
      });

      final without = plan.withSettings(false);
      final withoutFile = File(p.join(work.path, 'without.plybackup'))
        ..writeAsBytesSync(await s.buildBackup(without));
      expect(withoutFile.lengthSync(), without.archiveSize);
      expect(without.archiveSize, lessThan(plan.archiveSize));
      expect((await entriesOf(withoutFile)).map((e) => e.$1), isNot(contains(backupSettingsPath)));

      // No settings source: nothing offered.
      expect((await service().planBackup()).settings, isNull);
    });

    test('the preview offers them, and a restore applies them only when asked', () async {
      final source = await Directory.systemTemp.createTemp('backup_src');
      addTearDown(() => source.delete(recursive: true));
      await seedLibrary(source);
      final archive = await backUp(service(into: source, settings: mine));
      final applied = <AppSettings>[];
      final s = service(applySettings: (v) async => applied.add(v));

      final plan = await s.inspectBackup(archive);
      expect(plan.settings!.settings, mine);
      expect(plan.settings!.refusal, isNull);
      final result = await s.restore(plan);
      expect(result.count, 4);
      expect(result.settingsRestored, isFalse);
      expect(applied, isEmpty, reason: 'unticked by default');

      // Everything else already present: the settings alone can be restored.
      final before = await snapshot(docs);
      final again = await s.inspectBackup(archive);
      expect(again.projects.map((p) => p.status).toSet(), {RestoreStatus.alreadyPresent});
      final settingsOnly = await s.restore(again, restoreSettings: true);
      expect(settingsOnly.count, 0);
      expect(settingsOnly.settingsRestored, isTrue);
      expect(applied, [mine]);
      expect(await snapshot(docs), before);

      // A backup without settings has nothing to offer, even when asked.
      final plain = await service().inspectBackup(await backUp(service(into: source)));
      expect(plain.settings, isNull);
      expect((await s.restore(plain, restoreSettings: true)).settingsRestored, isFalse);
      expect(applied, [mine]);
    });

    test('they are read like the settings file: unknown keys and values fall back', () async {
      final json = utf8.encode(jsonEncode({
        'themeMode': 'dark',
        'unit': 'furlongs',
        'futureKey': {'nested': true},
      }));
      final plan =
          await service().inspectBackup(await craft([...goodDraft, (backupSettingsPath, json)]));
      expect(plan.settings!.settings, const AppSettings(themeMode: ThemeMode.dark));
    });

    test('settings that are not a settings model are refused with the reason', () async {
      for (final bad in <List<int>>[
        utf8.encode('not json'),
        utf8.encode('[1, 2]'),
        utf8.encode('"dark"'),
        utf8.encode(jsonEncode({'accentSeed': 'red'})),
        utf8.encode(jsonEncode({'useDynamicColor': 'yes'})),
        [0xFF, 0xFE, 0x00],
      ]) {
        final applied = <AppSettings>[];
        final s = service(applySettings: (v) async => applied.add(v));
        final plan = await s.inspectBackup(await craft([...goodDraft, (backupSettingsPath, bad)]));
        expect(plan.settings!.settings, isNull);
        expect(plan.settings!.refusal, 'The app settings in this backup could not be read.');
        // The projects still restore; the settings are never applied.
        final result = await s.restore(plan, restoreSettings: true);
        expect(result.count, 1);
        expect(result.settingsRestored, isFalse);
        expect(applied, isEmpty);
        await File(p.join(docs.path, 'drafts', 'a.json')).delete();
        await File(p.join(docs.path, 'drafts', 'a.wif')).delete();
      }
    });

    test('a settings entry outside the rules refuses the whole backup', () async {
      final ok = utf8.encode(jsonEncode(mine.toJson()));
      // Over its own limit, in the manifest or only in the archive.
      await expectRefused(await craft([...goodDraft, (backupSettingsPath, ok)]),
          BackupProblem.unsafe,
          limits: const BackupLimits(maxSettingsBytes: 10));
      // Claiming a project.
      final claimed = manifestFor([...goodDraft, (backupSettingsPath, ok)]);
      final settingsEntry = (claimed['files'] as List).last as Map;
      settingsEntry['craft'] = 'weaving';
      settingsEntry['project'] = 'a';
      await expectRefused(
          await craft([...goodDraft, (backupSettingsPath, ok)], manifest: claimed),
          BackupProblem.damaged);
      // Not listed, listed twice, or with the wrong checksum.
      await expectRefused(await craft(goodDraft, extra: [entry(backupSettingsPath, ok)]),
          BackupProblem.damaged);
      await expectRefused(
          await craft([...goodDraft, (backupSettingsPath, ok)],
              extra: [entry(backupSettingsPath, ok)]),
          BackupProblem.unsafe);
      final wrongSum = manifestFor([...goodDraft, (backupSettingsPath, ok)]);
      ((wrongSum['files'] as List).last as Map)['sha256'] = sha256.convert([0]).toString();
      await expectRefused(
          await craft([...goodDraft, (backupSettingsPath, ok)], manifest: wrongSum),
          BackupProblem.damaged);
      // Anywhere but the archive root (inside a craft folder it would be a project's sidecar).
      await expectRefused(await craft([...goodDraft, ('settings/$backupSettingsPath', ok)]),
          BackupProblem.unsafe);
    });

    test('settings that cannot be saved roll the whole restore back', () async {
      await seedLibrary(docs);
      final source = await Directory.systemTemp.createTemp('backup_src');
      addTearDown(() => source.delete(recursive: true));
      await seedLibrary(source);
      await put(source, 'knits/k9.plyknit', knitFile());
      await put(source, 'knits/k9.json', sidecar('New', 'Knitting'));
      final archive = await backUp(service(into: source, settings: mine));
      final before = await snapshot(docs);
      final s = service(applySettings: (_) async => throw const FileSystemException('disk full'));
      final plan = await s.inspectBackup(archive);
      await expectLater(s.restore(plan, restoreSettings: true),
          throwsBackup(BackupProblem.restoreFailed));
      expect(await snapshot(docs), before);
      // Unticked, the same restore succeeds.
      expect((await s.restore(plan)).restored.single.id, 'k9');
    });
  });

  group('a nalbinding copy keeps its new name', () {
    /// A `.plynal` with every field, a key this build does not know, and the version keys.
    List<int> richNal(String name) => utf8.encode(jsonEncode({
          'format': 'ply.nalbind',
          'schemaVersion': 2,
          'name': name,
          'notation': 'UO/UOO F1',
          'stitchName': 'Oslo',
          'notes': 'cast on 40',
          'futureKey': {'kept': true},
        }));

    test('in its .plynal, with every other key kept in place', () async {
      await put(docs, 'nalbinds/n1.plynal', richNal('Mitten'));
      await put(docs, 'nalbinds/n1.json', sidecar('Mitten', 'Nalbinding'));
      final archive = await backUp(service());
      await put(docs, 'nalbinds/n1.json', sidecar('Mitten', 'Nalbinding', extra: {'notes': 'x'}));
      final before = await snapshot(docs);

      final plan = await service().inspectBackup(archive);
      final copy = only(plan, 'n1');
      expect(copy.status, RestoreStatus.conflict);
      await service().restore(plan);
      final after = await snapshot(docs);
      for (final e in before.entries) {
        expect(after[e.key], e.value, reason: e.key);
      }
      final restored =
          jsonDecode(utf8.decode(after['nalbinds/${copy.targetId}.plynal']!)) as Map<String, dynamic>;
      final original = jsonDecode(utf8.decode(richNal('Mitten'))) as Map<String, dynamic>;
      expect(restored, {...original, 'name': 'Mitten (restored)'});
      expect(restored.keys.toList(), original.keys.toList(), reason: 'key order is kept');
      expect(NalbindProject.decode(utf8.decode(after['nalbinds/${copy.targetId}.plynal']!)).name,
          'Mitten (restored)');
      final copySidecar =
          jsonDecode(utf8.decode(after['nalbinds/${copy.targetId}.json']!)) as Map<String, dynamic>;
      expect(copySidecar['name'], 'Mitten (restored)');

      // Restoring the same backup again recognises the copy it made.
      final again = await service().inspectBackup(archive);
      expect(only(again, 'n1').status, RestoreStatus.alreadyPresent);
    });

    test('a legacy .plynal gains no version keys', () async {
      final legacy = utf8.encode(jsonEncode({'name': 'Old', 'notation': 'UO/UOO', 'notes': ''}));
      await put(docs, 'nalbinds/n1.plynal', legacy);
      await put(docs, 'nalbinds/n1.json', sidecar('Old', 'Nalbinding'));
      final archive = await backUp(service());
      await put(docs, 'nalbinds/n1.plynal', nalFile('Changed'));
      final plan = await service().inspectBackup(archive);
      await service().restore(plan);
      final id = only(plan, 'n1').targetId!;
      final restored = jsonDecode(
          await File(p.join(docs.path, 'nalbinds', '$id.plynal')).readAsString()) as Map;
      expect(restored, {'name': 'Old (restored)', 'notation': 'UO/UOO', 'notes': ''});
    });

    test('a project restored under its own id stays byte for byte', () async {
      // Formatted unlike Ply writes it, so any re-encoding would show.
      final spaced = utf8.encode(const JsonEncoder.withIndent('    ').convert(
          jsonDecode(utf8.decode(richNal('Mitten')))));
      final source = await Directory.systemTemp.createTemp('backup_src');
      addTearDown(() => source.delete(recursive: true));
      await put(source, 'nalbinds/n1.plynal', spaced);
      await put(source, 'nalbinds/n1.json', sidecar('Mitten', 'Nalbinding'));
      final archive = await backUp(service(into: source));
      await service().restore(await service().inspectBackup(archive));
      expect(await snapshot(docs), await snapshot(source));
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
