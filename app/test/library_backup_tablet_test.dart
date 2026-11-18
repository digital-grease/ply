import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:ply/src/data/app_settings_repository.dart';
import 'package:ply/src/data/library_backup.dart';
import 'package:ply/src/data/materials_repository.dart';
import 'package:ply/src/data/project_links_repository.dart';
import 'package:ply/src/data/tablet_repository.dart' show TabletRepository, kTabletCraft;
import 'package:ply/src/data/ustar.dart';
import 'package:ply/src/models/app_settings.dart';
import 'package:ply/src/models/material_record.dart';
import 'package:ply/src/models/native_format.dart';
import 'package:ply/src/models/project_materials.dart';
import 'package:ply/src/screens/restore_preview_screen.dart';
import 'package:ply/src/screens/settings_screen.dart';
import 'package:ply/src/state/backup_providers.dart';
import 'package:ply/src/state/loom_providers.dart';
import 'package:ply/src/state/theme_providers.dart';

import 'backup_test_support.dart';
import 'loom_test_support.dart' show FakeLoomRepository;
import 'materials_test_support.dart';

// Tablet weaving bands in a library backup, a single-project export and a restore (ADR 0018 section
// 15, on the ADR 0007 rules): the archive grammar carries `tablets/<id>.plytab` and its sidecar and
// never the thumbnail; a restore checks a `.plytab` by its envelope version (against the version
// this build writes) and then with the engine's parser, refusing a newer or unreadable band with
// the reason before anything is written; a conflict is restored as a copy with only its sidecar
// renamed; a band's materials links are pointed at restored copies like any project's; and a craft
// folder a build does not know refuses the whole backup, which is how a build from before this
// change treats `tablets/`. Host only: the engine is a stand-in, the bands are the real fixtures.

final String _fixtureDir = p.join('..', 'fixtures', 'tablet', 'documents');

/// The bytes of a `.plytab` fixture, relative to `fixtures/tablet/documents/`.
List<int> fixture(String name) =>
    File(p.joinAll([_fixtureDir, ...name.split('/')])).readAsBytesSync();

final List<int> band1 = fixture('band-1-threaded-in.plytab');
final List<int> sampler2 = fixture('sampler-2-starts-idles-flip.plytab');
final List<int> sampler3 = fixture('sampler-3-flip-then-opposite.plytab');

List<int> bandSidecar(String name, {Map<String, Object?> extra = const {}}) =>
    sidecar(name, kTabletCraft, extra: extra);

/// Two saved bands, a thumbnail of one, and (with [leftovers]) the files a backup leaves out.
Future<void> seedBands(Directory root, {bool leftovers = false}) async {
  await put(root, 'tablets/t1.plytab', band1);
  await put(
      root,
      'tablets/t1.json',
      bandSidecar('Diagonals', extra: {
        'futureKey': {'kept': true}
      }));
  await put(root, 'tablets/t1.png', [1, 2, 3]); // a cache, rebuilt after a restore
  await put(root, 'tablets/t2.plytab', sampler2);
  await put(root, 'tablets/t2.json', bandSidecar('Sampler'));
  if (!leftovers) return;
  await put(root, 'tablets/t1.plytab.tmp', [0]);
  await put(root, 'tablets/t1.json.tmp', [0]);
  // Schema version 1 is the first, so no upgrade backup exists yet and the grammar has none.
  await put(root, 'tablets/t1.plytab.v1.bak', band1);
  await put(root, 'tablets/orphan.plytab', band1); // no sidecar: not listed by the library
  await put(root, 'tablets/lonely.json', bandSidecar('Lonely')); // no band
}

/// A backup holding exactly [files], each with its manifest entry; a path outside the grammar is
/// listed under the craft named by its first folder.
Future<File> crafted(List<(String, List<int>)> files) async {
  final manifest = utf8.encode(jsonEncode({
    'format': 'ply.backup',
    'schema_version': 1,
    'created_at': '2026-11-17T10:30:00.000Z',
    'app_version': 'crafted',
    'files': [
      for (final (path, data) in files)
        {
          'path': path,
          'size': data.length,
          'sha256': sha256.convert(data).toString(),
          'craft': classifyLibraryPath(path)?.craft.manifestName ?? path.split('/').first,
          'project': classifyLibraryPath(path)?.projectId ?? 'x',
        },
    ],
  }));
  final b = BytesBuilder();
  void add(String path, List<int> data) => b
    ..add(UstarHeader.file(path, data.length).encode())
    ..add(data)
    ..add(Uint8List(ustarPadding(data.length)));
  add(backupManifestPath, manifest);
  for (final (path, data) in files) {
    add(path, data);
  }
  b.add(Uint8List(ustarEndLength));
  final f = File(p.join(work.path, 'crafted.plybackup'));
  await f.writeAsBytes(b.takeBytes());
  return f;
}

RestoreProject only(RestorePlan plan, String id) => plan.projects.singleWhere((p) => p.id == id);

Matcher throwsBackup(BackupProblem problem) =>
    throwsA(isA<BackupException>().having((e) => e.problem, 'problem', problem));

/// The manifest of a backup file, decoded.
Future<Map<String, dynamic>> manifestOf(File archive) async =>
    jsonDecode(utf8.decode((await entriesOf(archive)).first.$2)) as Map<String, dynamic>;

/// A backup service that also carries the materials and swatches (over a Dart stand-in codec).
LibraryBackup materialService({Directory? into}) => LibraryBackup(
      documentsDir: () async => into ?? docs,
      currentKnitSchemaVersion: () async => knitVersion,
      checks: testChecks,
      appVersion: '9.9.9-test',
      clock: () => DateTime.utc(2026, 11, 12, 10, 30),
      materials: materialHooks(DartCodecMaterialsRepository(into ?? docs)),
    );

Future<void> writeRecords(Directory dir,
        {List<MaterialRecord> materials = const [], List<SwatchRecord> swatches = const []}) =>
    DartCodecMaterialsRepository(dir)
        .saveAll(MaterialLibrary(materials: materials, swatches: swatches));

Future<MaterialLibrary> readRecords(Directory dir) async =>
    (await DartCodecMaterialsRepository(dir).load()).library;

Map<String, dynamic> jsonAt(Directory root, String rel) =>
    jsonDecode(File(p.joinAll([root.path, ...rel.split('/')])).readAsStringSync())
        as Map<String, dynamic>;

class _Settings extends AppSettingsRepository {
  @override
  Future<AppSettings> load() async => const AppSettings();
  @override
  Future<void> save(AppSettings settings) async {}
}

void main() {
  setUp(() async {
    docs = await Directory.systemTemp.createTemp('backup_docs');
    work = await Directory.systemTemp.createTemp('backup_work');
  });
  tearDown(() async {
    await docs.delete(recursive: true);
    await work.delete(recursive: true);
  });

  group('the archive grammar', () {
    test('names the tablet weaving library as the tablet repository stores it', () {
      const c = BackupCraft.tabletWeaving;
      expect((c.manifestName, c.directory, c.nativeExtension, c.label),
          ('tablet_weaving', 'tablets', 'plytab', 'Tablet weaving'));
      expect(c.directory, TabletRepository.folder);
      expect(BackupCraft.byManifestName('tablet_weaving'), c);
      expect(BackupCraft.byDirectory('tablets'), c);
    });

    test('accepts a band and its sidecar', () {
      final band = classifyLibraryPath('tablets/0b7e6a50-1f2c-4d3e-8a9b-0c1d2e3f4a5b.plytab')!;
      expect((band.craft, band.role), (BackupCraft.tabletWeaving, BackupFileRole.native));
      expect(band.projectId, '0b7e6a50-1f2c-4d3e-8a9b-0c1d2e3f4a5b');
      expect(band.pathFor('new'), 'tablets/new.plytab');
      final side = classifyLibraryPath('tablets/t_1.json')!;
      expect((side.craft, side.projectId, side.role),
          (BackupCraft.tabletWeaving, 't_1', BackupFileRole.sidecar));
      expect(side.pathFor('new'), 'tablets/new.json');
    });

    test('rejects the thumbnail, upgrade backups and anything outside the grammar', () {
      for (final path in [
        'tablets/t1.png', // a cache, never carried
        'tablets/t1.plytab.v1.bak', // no tablet upgrade backups in the grammar yet
        'tablets/t1.plytab.v2.bak',
        'tablets/t1.plytab.tmp',
        'tablets/t1.json.tmp',
        'tablets/t1.wif', // another craft's document
        'tablets/t1.plyknit',
        'drafts/t1.plytab', // a band outside its folder
        'knits/t1.plytab',
        'tablets/t1.photos/a.jpg', // bands have no photos
        'tablets/t.1.plytab', // ids have no dots
        'tablets/-t.plytab',
        'tablets/.json',
        'tablets/t1.plytab/',
        'tablets/sub/t1.plytab',
        'Tablets/t1.plytab', // folders are matched exactly
        'tablet/t1.plytab',
        '/tablets/t1.plytab',
        '../tablets/t1.plytab',
        'tablets/../drafts/d1.wif',
        r'tablets\t1.plytab',
      ]) {
        expect(classifyLibraryPath(path), isNull, reason: path);
      }
    });
  });

  group('making a backup', () {
    test('a full backup carries every band and its sidecar verbatim, never the thumbnail',
        () async {
      await seedLibrary(docs);
      await seedBands(docs, leftovers: true);
      final s = service();
      final plan = await s.planBackup();
      expect(plan.projectCounts[BackupCraft.tabletWeaving], 2);
      expect(plan.projectCount, 6);
      final f = File(p.join(work.path, 'b.plybackup'))..writeAsBytesSync(await s.buildBackup(plan));
      expect(f.lengthSync(), plan.archiveSize);
      final entries = await entriesOf(f);
      final paths = [for (final (path, _) in entries.skip(1)) path];
      // The bands follow the other crafts, each sidecar after its band.
      expect(paths.where((x) => x.startsWith('tablets/')),
          ['tablets/t1.plytab', 'tablets/t1.json', 'tablets/t2.plytab', 'tablets/t2.json']);
      expect(paths, hasLength(15));
      expect(paths.sublist(11), paths.where((x) => x.startsWith('tablets/')).toList());
      for (final (path, data) in entries.skip(1)) {
        expect(data, await File(p.join(docs.path, path)).readAsBytes(), reason: path);
      }
      expect(entries.firstWhere((e) => e.$1 == 'tablets/t1.plytab').$2, band1);

      final manifest = jsonDecode(utf8.decode(entries.first.$2)) as Map<String, dynamic>;
      expect(manifest['schema_version'], 1, reason: 'tablet weaving is additive within version 1');
      expect(manifest['contents'], 'library');
      final listed = [
        for (final e in (manifest['files'] as List).cast<Map<String, dynamic>>())
          if ((e['path'] as String).startsWith('tablets/')) e,
      ];
      expect(listed.map((e) => e['path']), paths.sublist(11));
      expect(listed.first, {
        'path': 'tablets/t1.plytab',
        'size': band1.length,
        'sha256': sha256.convert(band1).toString(),
        'craft': 'tablet_weaving',
        'project': 't1',
      });
      expect(listed.every((e) => e['craft'] == 'tablet_weaving'), isTrue);
    });

    test('a library of bands alone can be backed up', () async {
      await seedBands(docs);
      final plan = await service().planBackup();
      expect(plan.projectCounts, {
        BackupCraft.weaving: 0,
        BackupCraft.knitting: 0,
        BackupCraft.nalbinding: 0,
        BackupCraft.tabletWeaving: 2,
      });
    });

    test('a single-project export of a band holds exactly that band', () async {
      await seedBands(docs, leftovers: true);
      final s = service(settings: const AppSettings(themeMode: ThemeMode.dark));
      final plan = await s.planProjectBackup(BackupCraft.tabletWeaving, 't1');
      expect(plan.contents, BackupContents.project);
      expect(plan.projectCount, 1);
      expect(plan.projectCounts[BackupCraft.tabletWeaving], 1);
      expect(plan.settings, isNull);
      expect(plan.fileName, 'Diagonals 2026-11-12.plybackup');
      final f = File(p.join(work.path, 't1.plybackup'))
        ..writeAsBytesSync(await s.buildBackup(plan));
      final entries = await entriesOf(f);
      expect([for (final (path, _) in entries.skip(1)) path],
          ['tablets/t1.plytab', 'tablets/t1.json']);
      expect(entries[1].$2, band1);
      expect(entries[2].$2, await File(p.join(docs.path, 'tablets', 't1.json')).readAsBytes());
      final manifest = await manifestOf(f);
      expect(manifest['contents'], 'project');
      expect([for (final e in manifest['files'] as List) e['craft']],
          ['tablet_weaving', 'tablet_weaving']);
    });

    test('a band the library does not list cannot be exported', () async {
      await seedBands(docs, leftovers: true);
      for (final (craft, id) in [
        (BackupCraft.tabletWeaving, 'nope'),
        (BackupCraft.tabletWeaving, 'orphan'), // a band without a sidecar
        (BackupCraft.tabletWeaving, 'lonely'), // a sidecar without a band
        (BackupCraft.knitting, 't1'), // the wrong craft
      ]) {
        await expectLater(
            service().planProjectBackup(craft, id), throwsBackup(BackupProblem.projectNotFound),
            reason: '$craft $id');
      }
    });
  });

  group('restoring', () {
    test('adds every band, sidecar last, asks for its thumbnail, and refuses nothing else',
        () async {
      final source = await Directory.systemTemp.createTemp('backup_src');
      addTearDown(() => source.delete(recursive: true));
      await seedLibrary(source);
      await seedBands(source, leftovers: true);
      final archive = await backUp(service(into: source));

      final thumbs = <(BackupCraft, String)>[];
      final order = <String>[];
      final s = service(
          thumbnails: thumbs, beforePlace: (t) async => order.add(p.relative(t, from: docs.path)));
      final plan = await s.inspectBackup(archive);
      expect(plan.projects.where((x) => x.status != RestoreStatus.add), isEmpty);
      expect(plan.forCraft(BackupCraft.tabletWeaving, RestoreStatus.add).map((x) => x.name),
          ['Diagonals', 'Sampler']);
      final result = await s.restore(plan);
      expect(result.count, 6);
      expect(result.restored.where((r) => r.craft == BackupCraft.tabletWeaving).map((r) => r.id),
          ['t1', 't2']);

      // Byte-identical to the source library, minus what a backup leaves out.
      final expected = await snapshot(source)
        ..removeWhere((path, _) =>
            path.endsWith('.png') && !path.contains('.photos/') ||
            path.endsWith('.tmp') ||
            path.startsWith('tablets/') && path.endsWith('.bak') ||
            path.contains('orphan') ||
            path.contains('lonely') ||
            path == 'app_settings.json');
      expect(await snapshot(docs), expected);
      expect(order.where((x) => x.startsWith('tablets')), [
        p.join('tablets', 't1.plytab'),
        p.join('tablets', 't1.json'),
        p.join('tablets', 't2.plytab'),
        p.join('tablets', 't2.json'),
      ]);
      // Thumbnails are requested for the bands too (the tablet repository rebuilds them).
      expect(
          thumbs,
          unorderedEquals([
            (BackupCraft.weaving, 'd1'),
            (BackupCraft.weaving, 'd2'),
            (BackupCraft.knitting, 'k1'),
            (BackupCraft.tabletWeaving, 't1'),
            (BackupCraft.tabletWeaving, 't2'),
          ]));

      // The same backup again: everything is already here, nothing is written.
      final before = await snapshot(docs);
      final again = await service().inspectBackup(archive);
      expect(again.projects.map((x) => x.status).toSet(), {RestoreStatus.alreadyPresent});
      expect((await service().restore(again)).count, 0);
      expect(await snapshot(docs), before);
    });

    test('a single-project export of a band restores through the normal flow', () async {
      await seedBands(docs);
      final archive = await exportOne(service(), BackupCraft.tabletWeaving, 't1');
      final other = await Directory.systemTemp.createTemp('backup_other');
      addTearDown(() => other.delete(recursive: true));
      final thumbs = <(BackupCraft, String)>[];
      final into = service(into: other, thumbnails: thumbs);
      final plan = await into.inspectBackup(archive);
      expect(plan.projects.single.status, RestoreStatus.add);
      expect(plan.projects.single.name, 'Diagonals');
      expect(
          (await into.restore(plan)).restored.single, (craft: BackupCraft.tabletWeaving, id: 't1'));
      expect(await snapshot(other), {
        'tablets/': const <int>[],
        'tablets/t1.json': await File(p.join(docs.path, 'tablets', 't1.json')).readAsBytes(),
        'tablets/t1.plytab': band1,
      });
      expect(thumbs, [(BackupCraft.tabletWeaving, 't1')]);
      // Back into the library it came from: already there.
      expect((await service().inspectBackup(archive)).projects.single.status,
          RestoreStatus.alreadyPresent);
    });

    test('a band that differs is restored as a copy: new id, renamed sidecar, band as it was',
        () async {
      await seedBands(docs);
      final archive = await backUp(service());
      await put(docs, 'tablets/t1.plytab', sampler3); // edited since the backup
      final before = await snapshot(docs);

      final thumbs = <(BackupCraft, String)>[];
      final plan = await service(thumbnails: thumbs).inspectBackup(archive);
      expect(only(plan, 't2').status, RestoreStatus.alreadyPresent);
      final copy = only(plan, 't1');
      expect(copy.status, RestoreStatus.conflict);
      expect(copy.targetId, isNot('t1'));
      expect(isBackupProjectId(copy.targetId!), isTrue);
      expect(copy.targetName, 'Diagonals (restored)');

      final result = await service(thumbnails: thumbs).restore(plan);
      expect(result.restored.single, (craft: BackupCraft.tabletWeaving, id: copy.targetId!));
      final after = await snapshot(docs);
      for (final e in before.entries) {
        expect(after[e.key], e.value, reason: e.key);
      }
      final id = copy.targetId!;
      expect(after.keys.where((k) => !before.containsKey(k)).toSet(),
          {'tablets/$id.plytab', 'tablets/$id.json'});
      // As for knitting: the document byte for byte, only the sidecar's name changed (unknown keys
      // kept); the band takes the sidecar's name at its next save.
      expect(after['tablets/$id.plytab'], band1);
      final original = jsonDecode(utf8.decode(bandSidecar('Diagonals', extra: {
        'futureKey': {'kept': true}
      }))) as Map<String, dynamic>;
      expect(jsonAt(docs, 'tablets/$id.json'), {...original, 'name': 'Diagonals (restored)'});
      expect(thumbs, [(BackupCraft.tabletWeaving, id)]);

      // Restoring the same backup again finds the copy it made.
      final again = await service().inspectBackup(archive);
      expect(again.projects.map((x) => x.status).toSet(), {RestoreStatus.alreadyPresent});
    });

    test('any file left under a band\'s id (here a thumbnail) makes it a conflict', () async {
      await put(docs, 'tablets/t.png', [1]);
      final plan = await service().inspectBackup(
          await crafted([('tablets/t.plytab', band1), ('tablets/t.json', bandSidecar('T'))]));
      expect(only(plan, 't').status, RestoreStatus.conflict);
    });
  });

  group('a restore checks each band', () {
    test('and refuses, with the reason, a band newer than this build or unreadable', () async {
      await seedLibrary(docs);
      final files = [
        ('drafts/a.wif', wifBytes),
        ('drafts/a.json', sidecar('A', 'Weaving')),
        ('tablets/ok.plytab', band1),
        ('tablets/ok.json', bandSidecar('Fine')),
        ('tablets/new.plytab', fixture('invalid/newer-version.plytab')),
        ('tablets/new.json', bandSidecar('From the future')),
        ('tablets/far.plytab', fixture('invalid/much-newer-version.plytab')),
        ('tablets/far.json', bandSidecar('From the far future')),
        ('tablets/junk.plytab', fixture('invalid/not-json.plytab')),
        ('tablets/junk.json', bandSidecar('Not JSON')),
        ('tablets/knit.plytab', fixture('invalid/wrong-format-knit.plytab')),
        ('tablets/knit.json', bandSidecar('A pattern in disguise')),
        ('tablets/bare.plytab', fixture('invalid/bare-band.plytab')),
        ('tablets/bare.json', bandSidecar('No envelope')),
        ('tablets/zero.plytab', fixture('invalid/version-zero.plytab')),
        ('tablets/zero.json', bandSidecar('Version zero')),
        ('tablets/bin.plytab', [0xFF, 0xFE, 0x00]),
        ('tablets/bin.json', bandSidecar('Not text')),
        ('tablets/side.plytab', band1),
        ('tablets/side.json', bandSidecar('Newer sidecar', extra: {'schemaVersion': 2})),
        ('tablets/alone.plytab', band1), // no sidecar
        ('tablets/nosc.json', bandSidecar('No band')),
      ];
      final archive = await crafted(files);
      final before = await snapshot(docs);
      final thumbs = <(BackupCraft, String)>[];
      final s = service(thumbnails: thumbs);
      final plan = await s.inspectBackup(archive);
      expect(await snapshot(docs), before, reason: 'checking writes nothing');
      String? reason(String id) => only(plan, id).refusal?.message;
      const newer = 'Made by a newer version of Ply. Update the app to restore it.';
      const unreadable = 'A file in this project could not be read.';
      const missing = 'Part of this project is missing from the backup.';
      expect(only(plan, 'ok').status, RestoreStatus.add);
      expect(reason('new'), newer);
      expect(only(plan, 'new').name, 'From the future');
      expect(reason('far'), newer,
          reason: 'refused from the envelope, though its document is junk');
      expect(reason('junk'), unreadable);
      expect(reason('knit'), unreadable);
      expect(reason('bare'), unreadable);
      expect(reason('zero'), unreadable);
      expect(reason('bin'), unreadable);
      expect(reason('side'), newer);
      expect(reason('alone'), missing);
      expect(reason('nosc'), missing);
      for (final x in plan.projects.where((x) => x.status == RestoreStatus.refused)) {
        expect(x.targetId, isNull);
        expect(x.craft == BackupCraft.tabletWeaving, isTrue);
      }

      // The rest restores; no refused band is written, and only the restored one is redrawn.
      final result = await s.restore(plan);
      expect(result.restored.map((r) => r.id), unorderedEquals(['a', 'ok']));
      final placed = (await snapshot(docs)).keys.where((k) => k.startsWith('tablets/')).toSet();
      expect(placed, {'tablets/', 'tablets/ok.plytab', 'tablets/ok.json'});
      expect(
          thumbs, unorderedEquals([(BackupCraft.weaving, 'a'), (BackupCraft.tabletWeaving, 'ok')]));
    });

    test('and asks the engine when it can, mapping its newer-version failure to newer', () async {
      final unknownCard = fixture('invalid/unknown-card-field.plytab');
      final newer = fixture('invalid/newer-version.plytab');
      final asked = <String>[];
      final s = service(
        checks: NativeFileChecks(
            tabletVersion: testTabletVersion,
            tablet: (text) async {
              asked.add(text);
              if (text == utf8.decode(band1)) {
                throw const NativeFormatException(NativeFormatProblem.newerVersion,
                    document: NativeDocument.tabletBand);
              }
              if (text == utf8.decode(unknownCard)) {
                throw const NativeFormatException(NativeFormatProblem.unreadable,
                    document: NativeDocument.tabletBand);
              }
              if (text == utf8.decode(sampler2)) throw StateError('the engine failed');
            }),
      );
      final plan = await s.inspectBackup(await crafted([
        ('tablets/e.plytab', band1),
        ('tablets/e.json', bandSidecar('The engine says newer')),
        ('tablets/u.plytab', unknownCard),
        ('tablets/u.json', bandSidecar('A card key this version does not write')),
        ('tablets/x.plytab', sampler2),
        ('tablets/x.json', bandSidecar('The engine failed')),
        ('tablets/n.plytab', newer),
        ('tablets/n.json', bandSidecar('Newer envelope')),
        ('tablets/ok.plytab', sampler3),
        ('tablets/ok.json', bandSidecar('Fine')),
      ]));
      expect(only(plan, 'e').refusal, RestoreRefusal.newerVersion);
      expect(only(plan, 'u').refusal, RestoreRefusal.unreadable);
      expect(only(plan, 'x').refusal, RestoreRefusal.unreadable);
      expect(only(plan, 'n').refusal, RestoreRefusal.newerVersion);
      expect(only(plan, 'ok').status, RestoreStatus.add);
      // A newer envelope is refused before the engine reads its document.
      expect(asked, hasLength(4));
      expect(asked, isNot(contains(utf8.decode(newer))));
      expect(asked, contains(utf8.decode(sampler3)));
    });

    test('the version comes from the engine\'s envelope reader, and without it a band is refused',
        () async {
      final archive = await crafted([
        ('tablets/a.plytab', band1),
        ('tablets/a.json', bandSidecar('Version 1')),
      ]);
      // The reader is asked (the file says 1; this reader says 9): the band is newer. Nothing in
      // Dart decodes the file to learn its version.
      final asked = <int>[];
      final said9 = await service(
        checks: NativeFileChecks(tabletVersion: (text) async {
          asked.add(text.length);
          return 9;
        }),
      ).inspectBackup(archive);
      expect(asked, [band1.length]);
      expect(only(said9, 'a').refusal, RestoreRefusal.newerVersion);
      // A reader that fails, or none at all: refused as unreadable (fails closed).
      final failed = await service(
        checks: NativeFileChecks(tabletVersion: (text) async => throw StateError('no engine')),
      ).inspectBackup(archive);
      expect(only(failed, 'a').refusal, RestoreRefusal.unreadable);
      final none = await service(checks: const NativeFileChecks()).inspectBackup(archive);
      expect(only(none, 'a').refusal, RestoreRefusal.unreadable);
    });

    test('newer means newer than the .plytab version this build writes, asked once', () async {
      final archive = await crafted([
        ('tablets/a.plytab', band1),
        ('tablets/a.json', bandSidecar('Version 1')),
        ('tablets/n.plytab', fixture('invalid/newer-version.plytab')),
        ('tablets/n.json', bandSidecar('Version 2')),
        ('tablets/far.plytab', fixture('invalid/much-newer-version.plytab')),
        ('tablets/far.json', bandSidecar('Version 37')),
      ]);
      var asks = 0;
      LibraryBackup writing(int? version) => LibraryBackup(
            documentsDir: () async => docs,
            currentKnitSchemaVersion: () async => knitVersion,
            checks: testChecks,
            currentTabletSchemaVersion: version == null
                ? null
                : () async {
                    asks++;
                    return version;
                  },
            appVersion: 'test',
          );
      // Not given (host tests have no engine): version 1, the first.
      final first = await writing(null).inspectBackup(archive);
      expect(only(first, 'a').status, RestoreStatus.add);
      expect(only(first, 'n').refusal, RestoreRefusal.newerVersion);
      // A build that writes version 2 takes the version 2 envelope on to its engine check (none
      // here); version 37 is still newer.
      final second = await writing(2).inspectBackup(archive);
      expect(asks, 1, reason: 'asked once per restore');
      expect(only(second, 'n').status, RestoreStatus.add);
      expect(only(second, 'far').refusal, RestoreRefusal.newerVersion);
      // A backup without bands never asks.
      asks = 0;
      await writing(1).inspectBackup(
          await crafted([('drafts/a.wif', wifBytes), ('drafts/a.json', sidecar('A', 'Weaving'))]));
      expect(asks, 0);
    });

    test(
        'a craft folder this build does not know refuses the whole backup, before anything is '
        'written (how a build from before tablet weaving treats tablets/)', () async {
      await seedBands(docs);
      final before = await snapshot(docs);
      final archive = await crafted([
        ('tablets/ok.plytab', band1),
        ('tablets/ok.json', bandSidecar('Fine')),
        ('crochet/c1.plycro', [1, 2, 3]),
        ('crochet/c1.json', sidecar('Granny square', 'Crochet')),
      ]);
      await expectLater(
          service().inspectBackup(archive),
          throwsA(isA<BackupException>()
              .having((e) => e.problem, 'problem', BackupProblem.unsafe)
              .having((e) => e.message, 'message',
                  'This backup contains files Ply cannot restore safely.')));
      expect(await snapshot(docs), before);
    });
  });

  group('materials links', () {
    test('a band\'s links travel in its sidecar and point at the copies a restore adds', () async {
      final source = await Directory.systemTemp.createTemp('backup_src');
      addTearDown(() => source.delete(recursive: true));
      final links = {
        'yarns': [
          {'materialId': 'grey-wool', 'materialName': 'Grey wool', 'role': 'main'},
        ],
        'swatches': [
          {'swatchId': 'sw-knit', 'swatchName': 'Grey wool stockinette'},
        ],
      };
      await put(source, 'tablets/t9.plytab', band1);
      await put(source, 'tablets/t9.json', bandSidecar('Linked band', extra: {'materials': links}));
      await writeRecords(source, materials: [wool], swatches: [knitSwatch]);

      // A single-project export carries the links (in the sidecar, verbatim), never the records.
      final export =
          await materialService(into: source).planProjectBackup(BackupCraft.tabletWeaving, 't9');
      expect(export.materials, isNull);
      final exported = File(p.join(work.path, 't9.plybackup'))
        ..writeAsBytesSync(await materialService(into: source).buildBackup(export));
      final sidecarEntry = (await entriesOf(exported)).firstWhere((e) => e.$1 == 'tablets/t9.json');
      expect(sidecarEntry.$2, File(p.join(source.path, 'tablets', 't9.json')).readAsBytesSync());
      expect((jsonDecode(utf8.decode(sidecarEntry.$2)) as Map)['materials'], links);

      // A full backup into a library whose grey wool differs: the wool comes back as a copy, the
      // swatch as itself, and the band is pointed at the copy.
      final archive = await backUp(materialService(into: source));
      await writeRecords(docs, materials: [wool.copyWith(name: 'Grey wool, darker')]);
      final plan = await materialService().inspectBackup(archive);
      final band = only(plan, 't9');
      expect(band.status, RestoreStatus.add);
      expect(band.linkedMaterials, {'grey-wool'});
      expect(band.linkedSwatches, {'sw-knit'});
      final byKey = {for (final i in plan.materials!.items) i.key: i};
      expect(byKey['material/grey-wool']!.status, RestoreStatus.conflict);
      expect(byKey['material/grey-wool']!.projects, 1, reason: 'the band uses it');
      expect(byKey['swatch/sw-knit']!.status, RestoreStatus.add);

      final result = await materialService().restore(plan);
      expect(result.projectsRelinkedToMaterials, 1);
      final copy = (await readRecords(docs)).materials.last;
      expect(copy.name, 'Grey wool (restored)');
      final restored = jsonAt(docs, 'tablets/t9.json');
      expect(restored['materials'], {
        'yarns': [
          {'materialId': copy.id, 'materialName': 'Grey wool (restored)', 'role': 'main'},
        ],
        'swatches': [
          {'swatchId': 'sw-knit', 'swatchName': 'Grey wool stockinette'},
        ],
      });
      expect(restored['name'], 'Linked band');
      expect(restored['craft'], kTabletCraft);
      expect(File(p.join(docs.path, 'tablets', 't9.plytab')).readAsBytesSync(), band1);

      // The links repository reads the restored band like any project.
      final repo = ProjectLinksRepository(docsOverride: docs);
      final read = await repo.read(BackupCraft.tabletWeaving, 't9');
      expect(read.linksMaterial(copy.id), isTrue);
      expect(read.linksSwatch('sw-knit'), isTrue);
      expect((await repo.usage()).ofMaterial(copy.id),
          [const ProjectRef(BackupCraft.tabletWeaving, 't9')]);
      expect(ProjectMaterials.idsIn(restored).materials, {copy.id});

      // The same backup again: the relinked band is recognized as already here.
      final again = await materialService().inspectBackup(archive);
      expect(only(again, 't9').status, RestoreStatus.alreadyPresent);
      final snap = await snapshot(docs);
      await materialService().restore(again);
      expect(await snapshot(docs), snap);
    });
  });

  group('the backup screens', () {
    testWidgets('the restore preview lists bands under Tablet weaving', (t) async {
      t.view.physicalSize = const Size(1200, 3000);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      late RestorePlan plan;
      await t.runAsync(() async {
        final source = await Directory.systemTemp.createTemp('ui_src');
        addTearDown(() => source.delete(recursive: true));
        await seedBands(source);
        final archive = await backUp(service(into: source));
        await put(docs, 'tablets/t1.plytab', sampler3);
        await put(docs, 'tablets/t1.json', bandSidecar('Diagonals'));
        plan = await service().inspectBackup(archive);
      });
      final backup = FakeBackup()..inspected = plan;
      String? closing;
      await t.pumpWidget(ProviderScope(
        overrides: [
          libraryBackupProvider.overrideWithValue(backup),
          loomRepositoryProvider.overrideWithValue(FakeLoomRepository()),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () async {
                    final r = await Navigator.of(context).push<RestoreResult>(
                        MaterialPageRoute(builder: (_) => RestorePreviewScreen(plan: plan)));
                    if (r != null) closing = restoredMessage(r);
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();

      expect(find.text('Tablet weaving'), findsOneWidget);
      expect(find.text('New (1)'), findsOneWidget);
      expect(find.text('Sampler'), findsOneWidget);
      expect(find.text('Different from your library (1)'), findsOneWidget);
      expect(find.text('Restore as "Diagonals (restored)"'), findsOneWidget);
      await t.tap(find.text('Restore 2 projects'));
      await t.pumpAndSettle();
      expect(backup.skipped, isEmpty);
      expect(closing, 'Restored 2 projects.');
    });

    testWidgets('the backup summary counts the bands', (t) async {
      final backup = FakeBackup()
        ..plan = BackupPlan(
          createdAt: DateTime(2026, 11, 17),
          appVersion: 'test',
          files: const [],
          projectCounts: const {
            BackupCraft.weaving: 1,
            BackupCraft.knitting: 0,
            BackupCraft.nalbinding: 0,
            BackupCraft.tabletWeaving: 2,
          },
          photoCount: 0,
        );
      t.view.physicalSize = const Size(1200, 3000);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      await t.pumpWidget(ProviderScope(
        overrides: [
          appSettingsRepositoryProvider.overrideWithValue(_Settings()),
          libraryBackupProvider.overrideWithValue(backup),
          loomRepositoryProvider.overrideWithValue(FakeLoomRepository()),
        ],
        child: const MaterialApp(home: SettingsScreen()),
      ));
      await t.pumpAndSettle();
      await t.tap(find.text('Back up library'));
      await t.pumpAndSettle();
      expect(find.text('Weaving: 1 project'), findsOneWidget);
      expect(find.text('Tablet weaving: 2 projects'), findsOneWidget);
    });
  });
}
