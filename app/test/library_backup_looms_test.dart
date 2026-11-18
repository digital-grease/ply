import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:ply/src/data/library_backup.dart';
import 'package:ply/src/data/loom_repository.dart';
import 'package:ply/src/models/app_settings.dart';
import 'package:ply/src/models/loom_profile.dart';

import 'backup_test_support.dart';
import 'library_backup_test.dart' show archiveFile, entry, goodDraft, manifestEntry;
import 'loom_test_support.dart';

// My looms in a library backup (ADR 0014, amending ADR 0007): a full backup carries looms.json
// verbatim, a single-project export never does; a restore adds new looms, skips the same ones,
// offers different ones as copies, never changes an existing loom, puts looms.json back exactly on
// failure, and an older backup without looms restores as before.

const LoomProfile loomA = LoomProfile(id: 'loom-a', name: 'Alpha', shafts: 4);
const LoomProfile loomB = LoomProfile(id: 'loom-b', name: 'Beta', shafts: 8);
const LoomProfile loomC = LoomProfile(id: 'loom-c', name: 'Gamma', treadles: 10);

/// A backup service over [into] (default [docs]) whose My looms is the looms.json in that folder.
LibraryBackup loomService({Directory? into, Future<void> Function(AppSettings)? applySettings}) =>
    LibraryBackup(
      documentsDir: () async => into ?? docs,
      currentKnitSchemaVersion: () async => knitVersion,
      appVersion: '9.9.9-test',
      checks: testChecks,
      clock: () => DateTime.utc(2026, 11, 15, 10, 30),
      looms: loomHooks(DartCodecLoomRepository(into ?? docs)),
      applySettings: applySettings,
    );

File loomsFile(Directory dir) => File(p.join(dir.path, LoomRepository.fileName));

Future<void> writeLooms(Directory dir, List<LoomProfile> looms) =>
    DartCodecLoomRepository(dir).saveAll(looms);

Future<List<LoomProfile>> readLooms(Directory dir) async =>
    (await DartCodecLoomRepository(dir).load()).looms;

/// A crafted backup of [goodDraft] plus a `looms.json` entry holding [bytes].
Future<File> withLoomsEntry(List<int> bytes) {
  String sha(List<int> d) => sha256.convert(d).toString();
  return archiveFile([
    manifestEntry({
      'format': 'ply.backup',
      'schema_version': 1,
      'created_at': '2026-11-15T10:30:00.000Z',
      'app_version': 'crafted',
      'files': [
        {'path': backupLoomsPath, 'size': bytes.length, 'sha256': sha(bytes)},
        for (final (path, data) in goodDraft)
          {
            'path': path,
            'size': data.length,
            'sha256': sha(data),
            'craft': 'weaving',
            'project': 'a',
          },
      ],
    }),
    entry(backupLoomsPath, bytes),
    for (final (path, data) in goodDraft) entry(path, data),
  ]);
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

  test('a full backup carries looms.json verbatim and counts the looms', () async {
    await seedLibrary(docs);
    await writeLooms(docs, [loomA, loomB]);
    final s = loomService();
    final plan = await s.planBackup();
    expect(plan.looms!.count, 2);
    final file = File(p.join(work.path, 'b.plybackup'))
      ..writeAsBytesSync(await s.buildBackup(plan));
    expect(file.lengthSync(), plan.archiveSize);
    final entries = await entriesOf(file);
    expect(entries[1].$1, backupLoomsPath, reason: 'at the root, right after the manifest');
    expect(entries[1].$2, await loomsFile(docs).readAsBytes());
    final manifest = jsonDecode(utf8.decode(entries.first.$2)) as Map<String, dynamic>;
    expect(manifest['schema_version'], 1);
    final listed = (manifest['files'] as List).cast<Map<String, dynamic>>();
    expect(listed.first.keys, unorderedEquals(['path', 'size', 'sha256']),
        reason: 'no craft or project, like the settings entry');
  });

  test('with no looms (or no loom support) a backup is what it was; an export never has them',
      () async {
    await seedLibrary(docs);
    final plan = await loomService().planBackup();
    expect(plan.looms, isNull);
    expect((await service().planBackup()).archiveSize, plan.archiveSize);
    await writeLooms(docs, [loomA]);
    final export = await loomService().planProjectBackup(BackupCraft.weaving, 'd1');
    expect(export.looms, isNull);
    expect(export.manifest.files.map((f) => f.path), isNot(contains(backupLoomsPath)));
  });

  test('a restore adds new looms, skips the same, copies a different one, and changes nothing',
      () async {
    final source = await Directory.systemTemp.createTemp('backup_src');
    addTearDown(() => source.delete(recursive: true));
    await seedLibrary(source);
    await writeLooms(source, [loomA, loomB, loomC]);
    final archive = await backUp(loomService(into: source));

    final changedC = loomC.copyWith(name: 'Gamma, rethreaded', treadles: 12);
    await writeLooms(docs, [loomB, changedC]);
    final s = loomService();
    final plan = await s.inspectBackup(archive);
    final items = {for (final i in plan.looms!.items) i.key: i};
    expect(items['loom-a']!.status, RestoreStatus.add);
    expect(items['loom-b']!.status, RestoreStatus.alreadyPresent);
    expect(items['loom-c']!.status, RestoreStatus.conflict);
    expect(items['loom-c']!.target!.name, 'Gamma (restored)');
    expect(items['loom-c']!.target!.id, isNot('loom-c'));

    final result = await s.restore(plan);
    expect(result.loomsRestored, 2);
    final after = await readLooms(docs);
    expect([for (final l in after) l.name],
        ['Beta', 'Gamma, rethreaded', 'Alpha', 'Gamma (restored)']);
    expect(after[1], changedC, reason: 'the existing loom is never changed');

    // Restoring the same backup again recognizes everything, including the copy it made.
    final again = await s.inspectBackup(archive);
    expect(again.looms!.items.map((i) => i.status).toSet(), {RestoreStatus.alreadyPresent});
    expect((await s.restore(again)).loomsRestored, 0);
    expect(await readLooms(docs), after);
  });

  test('an unticked loom conflict is skipped', () async {
    final source = await Directory.systemTemp.createTemp('backup_src');
    addTearDown(() => source.delete(recursive: true));
    await seedLibrary(source);
    await writeLooms(source, [loomC]);
    final archive = await backUp(loomService(into: source));
    await writeLooms(docs, [loomC.copyWith(notes: 'changed here')]);
    final s = loomService();
    final plan = await s.inspectBackup(archive);
    final result = await s.restore(plan, skippedLoomConflicts: {'loom-c'});
    expect(result.loomsRestored, 0);
    expect((await readLooms(docs)).single.notes, 'changed here');
  });

  test('an older backup without looms restores exactly as before', () async {
    final source = await Directory.systemTemp.createTemp('backup_src');
    addTearDown(() => source.delete(recursive: true));
    await seedLibrary(source);
    final archive = await backUp(service(into: source)); // a build without loom support
    final s = loomService();
    final plan = await s.inspectBackup(archive);
    expect(plan.looms, isNull);
    final result = await s.restore(plan);
    expect(result.count, 4);
    expect(result.loomsRestored, 0);
    expect(loomsFile(docs).existsSync(), isFalse, reason: 'no looms.json is created');
  });

  test('a failed restore puts looms.json back byte for byte, with the projects', () async {
    final source = await Directory.systemTemp.createTemp('backup_src');
    addTearDown(() => source.delete(recursive: true));
    await seedLibrary(source);
    await writeLooms(source, [loomA]);
    final archive = await backUp(
        LibraryBackup(
          documentsDir: () async => source,
          currentKnitSchemaVersion: () async => knitVersion,
          appVersion: 't',
          currentSettings: () async => const AppSettings(),
          looms: loomHooks(DartCodecLoomRepository(source)),
        ),
        includeSettings: true);
    await writeLooms(docs, [loomB]);
    final before = await snapshot(docs);
    final s = loomService(applySettings: (_) async => throw StateError('disk full'));
    final plan = await s.inspectBackup(archive);
    expect(plan.looms!.selected(const {}), hasLength(1));
    await expectLater(
        s.restore(plan, restoreSettings: true),
        throwsA(isA<BackupException>()
            .having((e) => e.problem, 'problem', BackupProblem.restoreFailed)));
    expect(await snapshot(docs), before, reason: 'projects removed and looms.json put back');
  });

  test('looms that cannot be read, or are newer, are refused while the projects restore', () async {
    for (final (bytes, reason) in [
      (utf8.encode('garbage'), RestoreLooms.unreadable),
      (utf8.encode(loomsText([loomA], version: 2)), RestoreLooms.newer),
    ]) {
      final plan = await loomService().inspectBackup(await withLoomsEntry(bytes));
      expect(plan.looms!.refusal, reason);
      expect(plan.looms!.selected(const {}), isEmpty);
      expect(plan.projects.single.status, RestoreStatus.add);
    }
    // My looms itself cannot be read here: the backup's looms are not added.
    await loomsFile(docs).writeAsString('broken');
    final plan =
        await loomService().inspectBackup(await withLoomsEntry(utf8.encode(loomsText([loomA]))));
    expect(plan.looms!.refusal, RestoreLooms.localUnreadable);
    expect(await loomsFile(docs).readAsString(), 'broken', reason: 'inspecting writes nothing');
  });

  test('a looms.json entry is checked like any file: over its limit the backup is refused',
      () async {
    final bytes = utf8.encode(loomsText([loomA]));
    final archive = await withLoomsEntry(bytes);
    expect((await loomService().inspectBackup(archive)).looms!.items, hasLength(1));
    final strict = LibraryBackup(
      documentsDir: () async => docs,
      currentKnitSchemaVersion: () async => knitVersion,
      appVersion: 't',
      limits: BackupLimits(maxLoomsBytes: bytes.length - 1),
      looms: loomHooks(DartCodecLoomRepository(docs)),
    );
    await expectLater(strict.inspectBackup(archive),
        throwsA(isA<BackupException>().having((e) => e.problem, 'problem', BackupProblem.unsafe)));
  });

  test('a copy keeps within the loom name limit', () {
    expect(LibraryBackup.loomCopyName('Floor loom'), 'Floor loom (restored)');
    expect(LibraryBackup.loomCopyName(''), 'Unnamed loom (restored)');
    expect(LibraryBackup.loomCopyName('x' * 100).length, LoomLimits.maxNameChars);
  });

  group('drafts planned for a loom restored as a copy', () {
    late Directory source;
    late File archive;
    final changedC = loomC.copyWith(name: 'Gamma, rethreaded', treadles: 12);
    const plan = {
      'loomId': 'loom-c',
      'loomName': 'Gamma',
      'sett': {'ends': 24, 'per': 'inch'},
    };
    Map<String, dynamic> sidecarOf(String rel) =>
        jsonDecode(File(p.join(docs.path, rel)).readAsStringSync()) as Map<String, dynamic>;

    setUp(() async {
      source = await Directory.systemTemp.createTemp('backup_src');
      await seedLibrary(source);
      await put(source, 'drafts/d1.json', sidecar('Twill', 'Weaving', extra: {'loomPlan': plan}));
      await writeLooms(source, [loomC]);
      archive = await backUp(loomService(into: source));
      // The device: a different loom under the same id, and its own draft planned for it.
      await writeLooms(docs, [changedC]);
      await put(docs, 'drafts/mine.wif', wifBytes);
      await put(docs, 'drafts/mine.json', sidecar('Mine', 'Weaving', extra: {'loomPlan': plan}));
    });
    tearDown(() => source.delete(recursive: true));

    test('are pointed at the copy; drafts already on the device are left alone', () async {
      final s = loomService();
      final restorePlan = await s.inspectBackup(archive);
      final c = restorePlan.looms!.items.single;
      expect(c.status, RestoreStatus.conflict);
      expect(c.drafts, 1, reason: 'one draft from the backup is planned for it');
      final result = await s.restore(restorePlan);
      expect(result.draftsRelinked, 1);
      expect(sidecarOf('drafts/d1.json')['loomPlan'], {
        'loomId': c.target!.id,
        'loomName': 'Gamma (restored)',
        'sett': {'ends': 24, 'per': 'inch'},
      });
      expect(sidecarOf('drafts/mine.json')['loomPlan'], plan, reason: 'the device\'s own draft');
      expect(sidecarOf('drafts/d1.json')['name'], 'Twill', reason: 'only the plan changed');

      // Restoring again recognizes the pointed draft and the copy: nothing more is added.
      final again = await s.inspectBackup(archive);
      expect(again.projects.map((p) => p.status).toSet(), {RestoreStatus.alreadyPresent});
      expect(again.looms!.items.single.status, RestoreStatus.alreadyPresent);
      expect((await s.restore(again)).count, 0);
    });

    test('a large sidecar, read off the calling isolate, is pointed and recognized alike',
        () async {
      final big = List.filled(LibraryBackup.inlineSidecarValues * 2, 0);
      await put(source, 'drafts/d1.json',
          sidecar('Twill', 'Weaving', extra: {'loomPlan': plan, 'futureKey': big}));
      final bigArchive = await backUp(loomService(into: source), name: 'big.plybackup');
      final s = loomService();
      final restorePlan = await s.inspectBackup(bigArchive);
      final c = restorePlan.looms!.items.single;
      expect(c.drafts, 1);
      expect((await s.restore(restorePlan)).draftsRelinked, 1);
      expect(sidecarOf('drafts/d1.json')['loomPlan'], {...plan, 'loomId': c.target!.id,
          'loomName': 'Gamma (restored)'});
      expect(sidecarOf('drafts/d1.json')['futureKey'], big);
      final again = await s.inspectBackup(bigArchive);
      expect(again.projects.map((p) => p.status).toSet(), {RestoreStatus.alreadyPresent});
    });

    test('stay as they were when the copy is not restored', () async {
      final s = loomService();
      final result =
          await s.restore(await s.inspectBackup(archive), skippedLoomConflicts: {'loom-c'});
      expect(result.draftsRelinked, 0);
      expect(sidecarOf('drafts/d1.json')['loomPlan'], plan);
    });
  });

  test('a full backup says when My looms was left out, and why', () async {
    await seedLibrary(docs);
    await loomsFile(docs).writeAsString('broken');
    expect((await loomService().planBackup()).loomsLeftOut, BackupPlan.loomsUnreadable);
    await loomsFile(docs).writeAsString(loomsText([loomA], version: 2));
    final plan = await loomService().planBackup();
    expect(plan.loomsLeftOut, BackupPlan.loomsNewer);
    expect(plan.looms, isNull);
    expect(plan.withSettings(false).loomsLeftOut, BackupPlan.loomsNewer);
    await loomsFile(docs).delete();
    expect((await loomService().planBackup()).loomsLeftOut, isNull,
        reason: 'no looms, nothing left out');
  });
}
