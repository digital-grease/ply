import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:ply/src/data/library_backup.dart';
import 'package:ply/src/data/progress_repository.dart';
import 'package:ply/src/data/ustar.dart';
import 'package:ply/src/models/progress.dart';
import 'package:ply/src/screens/restore_preview_screen.dart';
import 'package:ply/src/state/backup_providers.dart';

import 'backup_test_support.dart';

// Progress records in backups (ADR 0023 section 9) over temp directories: a full backup and a
// single-project export carry each project's `<id>.plyprogress` (never its temp file or a record set
// aside), byte for byte, before the sidecar; a restore brings it with a new project or a copy, under
// the new id; a project whose only difference is its place is already in the library, which keeps
// its own; a newer record is carried as it is; and a record the restore cannot vouch for (unreadable,
// too large, too many values, too deep, a number too large for a double, another craft's) is left
// out while its project restores, never refusing the project or the backup. Every craft's records
// are read this way: weaving, knitting, nalbinding and tablet weaving.

final t0 = DateTime.utc(2026, 11, 18, 10);

List<int> weavingRecord(int pick) => utf8.encode(Progress(
      craft: ProgressCraft.weaving,
      place: PickPlace(pick),
      basis: PlaceBasis(units: 96, prefix: pick.toRadixString(16).padLeft(16, '0')),
      started: t0,
      updated: t0,
    ).withNote(PickPlace(pick), 'Second shuttle', now: t0).encodeFitted().text);

List<int> knittingRecord(int unit) => utf8.encode(const Progress(craft: ProgressCraft.knitting)
    .moved(
        from: const KnitPlace(0, sectionId: 'section-1', stepId: 'step-1'),
        to: KnitPlace(unit, sectionId: 'section-1', stepId: 'step-2'),
        basis: const PlaceBasis(units: 9, prefix: '0123456789abcdef'),
        kind: LogKind.worked,
        now: t0)
    .encodeFitted()
    .text);

List<int> tabletRecord(int pick, {int repeat = 1}) => utf8.encode(Progress(
      craft: ProgressCraft.tabletWeaving,
      place: PickPlace(pick, repeat: repeat),
      basis: PlaceBasis(units: 24, prefix: pick.toRadixString(16).padLeft(16, '0')),
      started: t0,
      updated: t0,
    ).withNote(PickPlace(pick, repeat: repeat), 'Released the twist', now: t0).encodeFitted().text);

List<int> nalbindRecord(int unit, String step) =>
    utf8.encode(const Progress(craft: ProgressCraft.nalbinding)
        .moved(
            from: const NalbindPlace(0, stepId: 'segment-1'),
            to: NalbindPlace(unit, stepId: step),
            basis: const PlaceBasis(units: 4, prefix: '0123456789abcdef'),
            kind: LogKind.worked,
            now: t0)
        .encodeFitted()
        .text);

/// A tablet weaving band from the fixtures.
List<int> bandBytes() =>
    File(p.join('..', 'fixtures', 'tablet', 'documents', 'band-1-threaded-in.plytab'))
        .readAsBytesSync();

Map<String, Object?> manifestFor(List<(String, List<int>)> files) => {
      'format': 'ply.backup',
      'schema_version': 1,
      'created_at': '2026-11-18T10:30:00.000Z',
      'app_version': 'crafted',
      'files': [
        for (final (path, data) in files)
          {
            'path': path,
            'size': data.length,
            'sha256': sha256.convert(data).toString(),
            'craft': classifyLibraryPath(path)!.craft.manifestName,
            'project': classifyLibraryPath(path)!.projectId,
          },
      ],
    };

/// A valid backup of exactly [files].
Future<File> craft(List<(String, List<int>)> files) async {
  final b = BytesBuilder();
  void add(String path, List<int> data) {
    b
      ..add(UstarHeader.file(path, data.length).encode())
      ..add(data)
      ..add(Uint8List(ustarPadding(data.length)));
  }

  add(backupManifestPath, utf8.encode(jsonEncode(manifestFor(files))));
  for (final (path, data) in files) {
    add(path, data);
  }
  b.add(Uint8List(ustarEndLength));
  final f = File(p.join(work.path, 'crafted.plybackup'));
  await f.writeAsBytes(b.takeBytes());
  return f;
}

/// A weaving draft `a` with [progress] as its record.
List<(String, List<int>)> draftWith(List<int> progress) => [
      ('drafts/a.wif', wifBytes),
      ('drafts/a.plyprogress', progress),
      ('drafts/a.json', sidecar('A', 'Weaving')),
    ];

RestoreProject only(RestorePlan plan, String id) => plan.projects.singleWhere((p) => p.id == id);

File inDocs(Directory root, String rel) => File(p.joinAll([root.path, ...rel.split('/')]));

void main() {
  setUp(() async {
    docs = await Directory.systemTemp.createTemp('backup_docs');
    work = await Directory.systemTemp.createTemp('backup_work');
  });
  tearDown(() async {
    await docs.delete(recursive: true);
    await work.delete(recursive: true);
  });

  test('the layout names a progress record, never its temp file or a record set aside', () {
    final rec = classifyLibraryPath('drafts/a.plyprogress')!;
    expect(
        (rec.craft, rec.projectId, rec.role), (BackupCraft.weaving, 'a', BackupFileRole.progress));
    expect(rec.pathFor('b'), 'drafts/b.plyprogress');
    expect(classifyLibraryPath('knits/k.plyprogress')!.role, BackupFileRole.progress);
    for (final bad in [
      'drafts/a.plyprogress.tmp',
      'drafts/a.plyprogress.corrupt',
      'drafts/a.plyprogress.corrupt.2',
      'drafts/a.PLYPROGRESS',
    ]) {
      expect(classifyLibraryPath(bad), isNull, reason: bad);
    }
    expect(ProgressRepository.extension, backupProgressExtension);
    expect(const BackupLimits().maxProgressBytes, ProgressLimits.maxFileBytes);
  });

  group('making a backup', () {
    test(
        'a full backup carries each record byte for byte, before its sidecar, never the temp or '
        'set-aside files', () async {
      await seedLibrary(docs);
      await put(docs, 'drafts/d1.plyprogress', weavingRecord(49));
      await put(docs, 'knits/k1.plyprogress', knittingRecord(3));
      await put(docs, 'drafts/d1.plyprogress.tmp', [1]);
      await put(docs, 'drafts/d1.plyprogress.corrupt', [2]);
      await put(docs, 'drafts/d1.plyprogress.corrupt.2', [3]);
      final entries = await entriesOf(await backUp(service()));
      final paths = [for (final (path, _) in entries) path];
      expect(paths, containsAll(['drafts/d1.plyprogress', 'knits/k1.plyprogress']));
      expect(paths.where((x) => x.contains('.plyprogress.')), isEmpty);
      expect(paths.indexOf('drafts/d1.plyprogress'), lessThan(paths.indexOf('drafts/d1.json')));
      expect(paths.indexOf('knits/k1.plyprogress'), lessThan(paths.indexOf('knits/k1.json')));
      final carried = entries.firstWhere((e) => e.$1 == 'drafts/d1.plyprogress').$2;
      expect(carried, weavingRecord(49));
      final manifest = jsonDecode(utf8.decode(entries.first.$2)) as Map<String, dynamic>;
      final listed = (manifest['files'] as List)
          .cast<Map<String, dynamic>>()
          .firstWhere((f) => f['path'] == 'knits/k1.plyprogress');
      expect((listed['craft'], listed['project']), ('knitting', 'k1'));
    });

    test('a single-project export carries its record', () async {
      await seedLibrary(docs);
      await put(docs, 'drafts/d1.plyprogress', weavingRecord(7));
      await put(docs, 'drafts/d2.plyprogress', weavingRecord(8));
      final paths = [
        for (final (path, _)
            in await entriesOf(await exportOne(service(), BackupCraft.weaving, 'd1')))
          path
      ];
      expect(paths, contains('drafts/d1.plyprogress'));
      expect(paths, isNot(contains('drafts/d2.plyprogress')));
    });

    test('a record past its bound is left out and the backup is made', () async {
      await seedLibrary(docs);
      await put(docs, 'drafts/d1.plyprogress', List.filled(ProgressLimits.maxFileBytes + 1, 32));
      final paths = [for (final (path, _) in await entriesOf(await backUp(service()))) path];
      expect(paths, isNot(contains('drafts/d1.plyprogress')));
      expect(paths, contains('drafts/d1.wif'));
    });

    test('a record that changes after the backup was planned stops it', () async {
      await seedLibrary(docs);
      await put(docs, 'drafts/d1.plyprogress', weavingRecord(10));
      final s = service();
      final plan = await s.planBackup();
      await put(docs, 'drafts/d1.plyprogress', weavingRecord(11));
      await expectLater(
          s.buildBackup(plan),
          throwsA(isA<BackupException>()
              .having((e) => e.problem, 'problem', BackupProblem.libraryChanged)));
    });
  });

  group('restoring', () {
    test('a full backup restores every record with its project, for weaving and knitting',
        () async {
      await seedLibrary(docs);
      await put(docs, 'drafts/d1.plyprogress', weavingRecord(49));
      await put(docs, 'knits/k1.plyprogress', knittingRecord(3));
      final archive = await backUp(service());
      final fresh = await Directory.systemTemp.createTemp('backup_fresh');
      addTearDown(() => fresh.delete(recursive: true));
      final s = service(into: fresh);
      final plan = await s.inspectBackup(archive);
      expect(only(plan, 'd1').status, RestoreStatus.add);
      expect(only(plan, 'd1').carriesProgress, isTrue);
      expect(only(plan, 'd1').progressLeftOut, isFalse);
      await s.restore(plan);
      expect(inDocs(fresh, 'drafts/d1.plyprogress').readAsBytesSync(), weavingRecord(49));
      expect(inDocs(fresh, 'knits/k1.plyprogress').readAsBytesSync(), knittingRecord(3));
      expect(inDocs(fresh, 'drafts/d2.plyprogress').existsSync(), isFalse);
      final read = await ProgressRepository(docsOverride: fresh).load(BackupCraft.knitting, 'k1');
      expect(read.status, ProgressStatus.ok);
      expect(read.progress!.place, const KnitPlace(3, sectionId: 'section-1', stepId: 'step-2'));
    });

    test('a project that differs only in its place is already in the library, which keeps its own',
        () async {
      await seedLibrary(docs);
      await put(docs, 'drafts/d1.plyprogress', weavingRecord(49));
      final archive = await backUp(service());
      // The weaver goes on; and another draft gets a place the backup does not have.
      await put(docs, 'drafts/d1.plyprogress', weavingRecord(80));
      await put(docs, 'drafts/d2.plyprogress', weavingRecord(3));
      final before = await snapshot(docs);
      final plan = await service().inspectBackup(archive);
      expect(only(plan, 'd1').status, RestoreStatus.alreadyPresent);
      expect(only(plan, 'd2').status, RestoreStatus.alreadyPresent);
      await service().restore(plan);
      expect(await snapshot(docs), before);
      expect(inDocs(docs, 'drafts/d1.plyprogress').readAsBytesSync(), weavingRecord(80));
      // The library without a record of its own: still the same project, and nothing is added.
      inDocs(docs, 'drafts/d1.plyprogress').deleteSync();
      final again = await service().inspectBackup(archive);
      expect(only(again, 'd1').status, RestoreStatus.alreadyPresent);
    });

    test('a copy brings its record under the copy\'s id, and a repeated restore knows the copy',
        () async {
      await put(docs, 'drafts/a.wif', wifBytes);
      await put(docs, 'drafts/a.json', sidecar('Mine', 'Weaving'));
      final archive = await craft(draftWith(weavingRecord(12)));
      final plan = await service().inspectBackup(archive);
      final a = only(plan, 'a');
      expect(a.status, RestoreStatus.conflict);
      await service().restore(plan);
      final copy = a.targetId!;
      expect(inDocs(docs, 'drafts/$copy.plyprogress').readAsBytesSync(), weavingRecord(12));
      expect(inDocs(docs, 'drafts/a.plyprogress').existsSync(), isFalse, reason: 'mine untouched');
      // Restoring the same backup again finds the copy it made (its place aside).
      await put(docs, 'drafts/$copy.plyprogress', weavingRecord(13));
      expect(
          only(await service().inspectBackup(archive), 'a').status, RestoreStatus.alreadyPresent);
    });

    test('a record from a newer Ply is carried as it is', () async {
      final newer = utf8.encode('{"format":"ply.progress","schemaVersion":7,"craft":"weaving",'
          '"later":{"shape":"unknown"}}');
      final plan = await service().inspectBackup(await craft(draftWith(newer)));
      expect(only(plan, 'a').carriesProgress, isTrue);
      await service().restore(plan);
      expect(inDocs(docs, 'drafts/a.plyprogress').readAsBytesSync(), newer);
      expect((await ProgressRepository(docsOverride: docs).load(BackupCraft.weaving, 'a')).status,
          ProgressStatus.newer);
      // Its version keys need not come first to be recognized as newer.
      final reordered =
          utf8.encode('{"craft":"weaving","format":"ply.progress","schemaVersion":7}');
      final plan2 = await service().inspectBackup(await craft([
        ('drafts/b.wif', wifBytes),
        ('drafts/b.plyprogress', reordered),
        ('drafts/b.json', sidecar('B', 'Weaving')),
      ]));
      expect(only(plan2, 'b').carriesProgress, isTrue);
    });

    test('a record the restore cannot vouch for is left out and its project restores', () async {
      String deep(int levels) => '${'[' * levels}${']' * levels}';
      final valid = utf8.decode(weavingRecord(5));
      final cases = <String, List<int>>{
        'not JSON': utf8.encode('{ not json'),
        'not UTF-8': [0xff, 0xfe, 0x7b],
        'not a progress record': utf8.encode('{"format":"ply.knit","schemaVersion":1}'),
        'another craft\'s': knittingRecord(1),
        'a bad place': utf8.encode(valid.replaceFirst('"pick":5', '"pick":-5')),
        'nested too deep': utf8.encode('{"format":"ply.progress","schemaVersion":1,'
            '"craft":"weaving","later":${deep(70)},"log":[],"logDropped":0,"notes":[],'
            '"lastNoteNumber":0,"undo":[]}'),
        'a number too large for a double':
            utf8.encode(valid.replaceFirst('"logDropped":0', '"logDropped":0,"later":1e400')),
        'too large': utf8.encode('{"format":"ply.progress","schemaVersion":1,"pad":"'
            '${'x' * ProgressLimits.maxFileBytes}"}'),
        'too many values': utf8.encode(valid.replaceFirst(
            '"logDropped":0', '"logDropped":0,"later":[${List.filled(100001, '0').join(',')}]')),
      };
      for (final MapEntry(:key, :value) in cases.entries) {
        final before = await snapshot(docs);
        final plan = await service().inspectBackup(await craft(draftWith(value)));
        final a = only(plan, 'a');
        expect(a.status, RestoreStatus.add, reason: key);
        expect(a.progressLeftOut, isTrue, reason: key);
        expect(a.carriesProgress, isFalse, reason: key);
        await service().restore(plan);
        expect(inDocs(docs, 'drafts/a.wif').existsSync(), isTrue, reason: key);
        expect(inDocs(docs, 'drafts/a.json').existsSync(), isTrue, reason: key);
        expect(inDocs(docs, 'drafts/a.plyprogress').existsSync(), isFalse, reason: key);
        // Back to the library as it was (the restore made the craft folder), for the next case.
        await Directory(p.join(docs.path, 'drafts')).delete(recursive: true);
        expect(await snapshot(docs), before, reason: key);
      }
      expect(RestoreProject.progressLeftOutText, 'Your place in it could not be restored.');
    });

    test('a nalbinding record is read with the tracker\'s own reader', () async {
      final nal = nalbindRecord(2, 'segment-3');
      final plan = await service().inspectBackup(await craft([
        ('nalbinds/n.plynal', nalFile('Mitten')),
        ('nalbinds/n.plyprogress', nal),
        ('nalbinds/n.json', sidecar('Mitten', 'Nalbinding')),
      ]));
      expect(only(plan, 'n').carriesProgress, isTrue);
      await service().restore(plan);
      expect(inDocs(docs, 'nalbinds/n.plyprogress').readAsBytesSync(), nal);
      final read = await ProgressRepository(docsOverride: docs).load(BackupCraft.nalbinding, 'n');
      expect(read.progress!.place, const NalbindPlace(2, stepId: 'segment-3'));
      // Left out: another craft's record, and a bare envelope (what a build that did not track
      // nalbinding yet kept for a later one: no Ply ever wrote it, and it is no record this build
      // reads). Neither refuses the project.
      for (final (id, record) in [
        ('m', utf8.encode('{"format":"ply.progress","schemaVersion":1,"craft":"weaving"}')),
        (
          'o',
          utf8.encode('{"format":"ply.progress","schemaVersion":1,"craft":"nalbinding",'
              '"place":{"step":"segment-3"}}')
        ),
        ('q', weavingRecord(4)),
      ]) {
        final plan2 = await service().inspectBackup(await craft([
          ('nalbinds/$id.plynal', nalFile('Hat')),
          ('nalbinds/$id.plyprogress', record),
          ('nalbinds/$id.json', sidecar('Hat', 'Nalbinding')),
        ]));
        expect(only(plan2, id).progressLeftOut, isTrue, reason: id);
        expect(only(plan2, id).status, RestoreStatus.add, reason: id);
      }
      // A newer one is carried as it is.
      final newer = utf8.encode('{"format":"ply.progress","schemaVersion":4,"craft":"nalbinding"}');
      final plan3 = await service().inspectBackup(await craft([
        ('nalbinds/r.plynal', nalFile('Sock')),
        ('nalbinds/r.plyprogress', newer),
        ('nalbinds/r.json', sidecar('Sock', 'Nalbinding')),
      ]));
      expect(only(plan3, 'r').carriesProgress, isTrue);
    });

    test('tablet weaving and nalbinding records go with their projects, both ways', () async {
      await seedLibrary(docs);
      await put(docs, 'tablets/t1.plytab', bandBytes());
      await put(docs, 'tablets/t1.json', sidecar('Band', 'TabletWeaving'));
      await put(docs, 'tablets/t1.plyprogress', tabletRecord(9, repeat: 3));
      await put(docs, 'nalbinds/n1.plyprogress', nalbindRecord(1, 'segment-2'));
      final entries = await entriesOf(await backUp(service()));
      final paths = [for (final (path, _) in entries) path];
      expect(paths.indexOf('tablets/t1.plyprogress'), lessThan(paths.indexOf('tablets/t1.json')));
      expect(paths.indexOf('nalbinds/n1.plyprogress'), lessThan(paths.indexOf('nalbinds/n1.json')));
      final manifest = jsonDecode(utf8.decode(entries.first.$2)) as Map<String, dynamic>;
      final listed = (manifest['files'] as List)
          .cast<Map<String, dynamic>>()
          .firstWhere((f) => f['path'] == 'tablets/t1.plyprogress');
      expect((listed['craft'], listed['project']), ('tablet_weaving', 't1'));
      final single = [
        for (final (path, _)
            in await entriesOf(await exportOne(service(), BackupCraft.tabletWeaving, 't1')))
          path
      ];
      expect(single, contains('tablets/t1.plyprogress'));

      final archive = await backUp(service());
      final fresh = await Directory.systemTemp.createTemp('backup_fresh');
      addTearDown(() => fresh.delete(recursive: true));
      final s = service(into: fresh);
      final plan = await s.inspectBackup(archive);
      expect(only(plan, 't1').carriesProgress, isTrue);
      expect(only(plan, 'n1').carriesProgress, isTrue);
      await s.restore(plan);
      expect(inDocs(fresh, 'tablets/t1.plyprogress').readAsBytesSync(), tabletRecord(9, repeat: 3));
      expect(inDocs(fresh, 'nalbinds/n1.plyprogress').readAsBytesSync(),
          nalbindRecord(1, 'segment-2'));
      final read =
          await ProgressRepository(docsOverride: fresh).load(BackupCraft.tabletWeaving, 't1');
      expect(read.progress!.place, const PickPlace(9, repeat: 3));

      // Back in the library they came from, a band and a project that differ only in their place
      // are already there, and keep their own.
      await put(docs, 'tablets/t1.plyprogress', tabletRecord(10, repeat: 3));
      await put(docs, 'nalbinds/n1.plyprogress', nalbindRecord(3, 'segment-4'));
      final before = await snapshot(docs);
      final again = await service().inspectBackup(archive);
      expect(only(again, 't1').status, RestoreStatus.alreadyPresent);
      expect(only(again, 'n1').status, RestoreStatus.alreadyPresent);
      await service().restore(again);
      expect(await snapshot(docs), before);
    });

    test('lower limits leave a record out the same way', () async {
      final plan = await service(limits: const BackupLimits(maxProgressValues: 10))
          .inspectBackup(await craft(draftWith(weavingRecord(5))));
      expect(only(plan, 'a').progressLeftOut, isTrue);
      final plan2 = await service(limits: const BackupLimits(maxProgressBytes: 64))
          .inspectBackup(await craft(draftWith(weavingRecord(5))));
      expect(only(plan2, 'a').progressLeftOut, isTrue);
      expect(only(plan2, 'a').status, RestoreStatus.add);
    });
  });

  group('after review', () {
    test('a record that states a newer version but decodes to another is left out', () async {
      final valid = utf8.decode(weavingRecord(5));
      final body = valid.substring('{"format":"ply.progress","schemaVersion":1,'.length);
      String twoVersions(String extra) => '{"format":"ply.progress","schemaVersion":2,$body'
          .replaceFirst(RegExp(r'}$'), ',"later":$extra,"schemaVersion":1}');
      String deep(int levels) => '${'[' * levels}${']' * levels}';
      for (final MapEntry(:key, :value) in {
        'two versions': twoVersions('0'),
        'two versions and a number too large for a double': twoVersions('1e400'),
        'two versions and deep nesting': twoVersions(deep(260000)),
      }.entries) {
        expect(utf8.encode(value).length, lessThan(ProgressLimits.maxFileBytes), reason: key);
        final plan = await service().inspectBackup(await craft(draftWith(utf8.encode(value))));
        expect(only(plan, 'a').progressLeftOut, isTrue, reason: key);
        expect(only(plan, 'a').carriesProgress, isFalse, reason: key);
        expect(only(plan, 'a').status, RestoreStatus.add, reason: key);
      }
    });

    test('a record set aside or unreadable while the backup is planned is left out', () async {
      await seedLibrary(docs);
      final record = inDocs(docs, 'drafts/d1.plyprogress');
      await put(docs, 'drafts/d1.plyprogress', weavingRecord(4));
      await Process.run('chmod', ['000', record.path]);
      addTearDown(() => Process.run('chmod', ['644', record.path]));
      bool readable;
      try {
        record.readAsBytesSync();
        readable = true;
      } on FileSystemException {
        readable = false;
      }
      final paths = [for (final (path, _) in await entriesOf(await backUp(service()))) path];
      expect(paths, contains('drafts/d1.wif'), reason: 'the backup is made');
      if (!readable) {
        expect(paths, isNot(contains('drafts/d1.plyprogress')));
      }
      // One that changes after planning still stops the build (see "making a backup").
    });

    test('a progress record with nothing else of its project lists no project', () async {
      final plan = await service().inspectBackup(await craft([
        ...draftWith(weavingRecord(2)),
        ('drafts/z.plyprogress', weavingRecord(3)),
      ]));
      expect(plan.projects.map((p) => p.id), ['a']);
    });

    test('a failed restore takes its placed record back with the rest', () async {
      final before = await snapshot(docs);
      final s = service(beforePlace: (target) async {
        if (target.endsWith('a.json')) throw StateError('the disk filled up');
      });
      final plan = await s.inspectBackup(await craft(draftWith(weavingRecord(9))));
      await expectLater(
          s.restore(plan),
          throwsA(isA<BackupException>()
              .having((e) => e.problem, 'problem', BackupProblem.restoreFailed)));
      expect(await snapshot(docs), before);
    });

    test('a record of many values is read on a background isolate and carried', () async {
      final valid = utf8.decode(weavingRecord(6));
      final many =
          valid.replaceFirst(RegExp(r'}$'), ',"later":[${List.filled(15000, '0').join(',')}]}');
      final plan = await service().inspectBackup(await craft(draftWith(utf8.encode(many))));
      expect(only(plan, 'a').carriesProgress, isTrue);
    });

    test('a tablet weaving record is read with the tracker\'s own reader', () async {
      List<(String, List<int>)> withRecord(List<int> record) => [
            ('tablets/t.plytab', bandBytes()),
            ('tablets/t.plyprogress', record),
            ('tablets/t.json', sidecar('Band', 'TabletWeaving')),
          ];
      final plan = await service().inspectBackup(await craft(withRecord(tabletRecord(5))));
      expect(only(plan, 't').carriesProgress, isTrue);
      for (final record in [
        weavingRecord(5),
        utf8.encode('{"format":"ply.progress","schemaVersion":1,"craft":"tablet_weaving"}'),
        utf8.encode(utf8.decode(tabletRecord(5)).replaceFirst('"pick":5', '"pick":0')),
      ]) {
        final other = await service().inspectBackup(await craft(withRecord(record)));
        expect(only(other, 't').progressLeftOut, isTrue);
        expect(only(other, 't').status, RestoreStatus.add);
      }
    });

    testWidgets('the preview says when a project\'s place could not be restored', (t) async {
      t.view.physicalSize = const Size(1000, 2400);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      late RestorePlan plan;
      await t.runAsync(() async {
        await put(docs, 'drafts/mine.wif', wifBytes);
        await put(docs, 'drafts/mine.json', sidecar('Mine', 'Weaving'));
        plan = await service().inspectBackup(await craft([
          ...draftWith(utf8.encode('{ not json')),
          ('drafts/mine.wif', wifBytes),
          ('drafts/mine.plyprogress', [0xff]),
          ('drafts/mine.json', sidecar('Changed', 'Weaving')),
        ]));
      });
      expect(only(plan, 'a').status, RestoreStatus.add);
      expect(only(plan, 'mine').status, RestoreStatus.conflict);
      await t.pumpWidget(ProviderScope(
        overrides: [libraryBackupProvider.overrideWithValue(FakeBackup()..inspected = plan)],
        child: MaterialApp(home: RestorePreviewScreen(plan: plan)),
      ));
      await t.pumpAndSettle();
      expect(find.textContaining(RestoreProject.progressLeftOutText), findsNWidgets(2));
      expect(find.text('Restore as "Changed (restored)"\n${RestoreProject.progressLeftOutText}'),
          findsOneWidget);
    });
  });
}
