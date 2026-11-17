import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:ply/src/data/library_backup.dart';
import 'package:ply/src/data/materials_repository.dart';
import 'package:ply/src/models/app_settings.dart';
import 'package:ply/src/models/material_record.dart';

import 'backup_test_support.dart';
import 'library_backup_test.dart' show archiveFile, entry, goodDraft, manifestEntry;
import 'materials_test_support.dart';

// Materials and swatches in a library backup (ADR 0016): a full backup carries materials.json
// verbatim and every swatch's photos, a single-project export never does; a restore adds new
// records (with their photos), skips the same ones, offers different ones as copies, points the
// projects it restores (and the swatches it adds) at the copies, never changes an existing record,
// puts everything back on failure, and an older backup without materials restores as before.

LibraryBackup materialService({
  Directory? into,
  AppSettings? settings,
  Future<void> Function(AppSettings)? applySettings,
  Future<bool> Function(MaterialLibrary merged)? fits,
}) =>
    LibraryBackup(
      documentsDir: () async => into ?? docs,
      currentKnitSchemaVersion: () async => knitVersion,
      appVersion: '9.9.9-test',
      clock: () => DateTime.utc(2026, 11, 16, 10, 30),
      materials: materialHooks(DartCodecMaterialsRepository(into ?? docs), fits: fits),
      currentSettings: settings == null ? null : () async => settings,
      applySettings: applySettings,
    );

Future<void> writeRecords(Directory dir,
        {List<MaterialRecord> materials = const [], List<SwatchRecord> swatches = const []}) =>
    DartCodecMaterialsRepository(dir)
        .saveAll(MaterialLibrary(materials: materials, swatches: swatches));

Future<MaterialLibrary> readRecords(Directory dir) async =>
    (await DartCodecMaterialsRepository(dir).load()).library;

const String photoPath = 'swatches/sw-knit.photos/aaa.jpg';

/// A knitting project linking the wool and the knitting swatch.
Future<void> putLinkedProject(Directory root) async {
  await put(root, 'knits/k9.plyknit', knitFile(name: 'Socks'));
  await put(
      root,
      'knits/k9.json',
      sidecar('Socks', 'Knitting', extra: {
        'materials': {
          'yarns': [
            {'materialId': 'grey-wool', 'materialName': 'Grey wool', 'role': 'main'}
          ],
          'swatches': [
            {'swatchId': 'sw-knit', 'swatchName': 'Grey wool stockinette'}
          ],
        },
      }));
}

Map<String, dynamic> sidecarOf(Directory root, String rel) =>
    jsonDecode(File(p.joinAll([root.path, ...rel.split('/')])).readAsStringSync())
        as Map<String, dynamic>;

void main() {
  setUp(() async {
    docs = await Directory.systemTemp.createTemp('backup_docs');
    work = await Directory.systemTemp.createTemp('backup_work');
  });
  tearDown(() async {
    await docs.delete(recursive: true);
    await work.delete(recursive: true);
  });

  test('swatch photo paths classify only inside the photo folder', () {
    expect(classifySwatchPhotoPath(photoPath)!.swatchId, 'sw-knit');
    for (final bad in [
      'swatches/sw-knit.photos/../x.jpg',
      'swatches/sw-knit.photos/a.exe',
      'swatches/../materials.json',
      'swatches/sw.knit.photos/a.jpg',
      '/swatches/a.photos/b.jpg',
      'swatches/a.photos/b/c.jpg',
    ]) {
      expect(classifySwatchPhotoPath(bad), isNull, reason: bad);
    }
  });

  test('a full backup carries materials.json verbatim and the swatches\' photos', () async {
    await seedLibrary(docs);
    await writeRecords(docs, materials: [wool], swatches: [knitSwatch]);
    await put(docs, photoPath, photo1);
    await put(docs, 'swatches/sw-knit.photos/bbb.jpg.tmp', [0]); // never a photo
    await put(docs, 'swatches/gone.photos/ccc.jpg', photo2); // no such swatch
    final s = materialService();
    final plan = await s.planBackup();
    expect(plan.materials!.materials, 1);
    expect(plan.materials!.swatches, 1);
    expect(plan.swatchPhotos.map((f) => f.archivePath), [photoPath]);
    final file = File(p.join(work.path, 'b.plybackup'))
      ..writeAsBytesSync(await s.buildBackup(plan));
    expect(file.lengthSync(), plan.archiveSize);
    final entries = {for (final (path, bytes) in await entriesOf(file)) path: bytes};
    expect(entries[backupMaterialsPath],
        File(p.join(docs.path, MaterialsRepository.fileName)).readAsBytesSync());
    expect(entries[photoPath], photo1);
    expect(entries.keys.where((k) => k.startsWith('swatches/')), [photoPath]);
    final manifest =
        jsonDecode(utf8.decode((await entriesOf(file)).first.$2)) as Map<String, dynamic>;
    final listed = [
      for (final f in (manifest['files'] as List).cast<Map<String, dynamic>>())
        if (f['path'] == backupMaterialsPath || f['path'] == photoPath) f
    ];
    expect(listed, hasLength(2));
    expect(listed.every((f) => !f.containsKey('craft') && !f.containsKey('project')), isTrue);
  });

  test('a library of materials alone can be backed up; an export never carries them', () async {
    await writeRecords(docs, materials: [wool]);
    final plan = await materialService().planBackup();
    expect(plan.projectCount, 0);
    expect(plan.materials, isNotNull);
    await seedLibrary(docs);
    final export = await materialService().planProjectBackup(BackupCraft.weaving, 'd1');
    expect(export.materials, isNull);
    expect(export.swatchPhotos, isEmpty);
    expect(export.manifest.files.map((f) => f.path), isNot(contains(backupMaterialsPath)));
  });

  test('a restore adds, skips, copies, points projects and swatches at copies, and repeats cleanly',
      () async {
    final source = await Directory.systemTemp.createTemp('backup_src');
    addTearDown(() => source.delete(recursive: true));
    await putLinkedProject(source);
    await writeRecords(source, materials: [wool, cotton], swatches: [knitSwatch]);
    await put(source, photoPath, photo1);
    final archive = await backUp(materialService(into: source));

    final darker = wool.copyWith(name: 'Grey wool, darker');
    await writeRecords(docs, materials: [darker, cotton]);
    final before = await readRecords(docs);

    final plan = await materialService().inspectBackup(archive);
    final m = plan.materials!;
    expect(m.refusal, isNull);
    final byKey = {for (final i in m.items) i.key: i};
    expect(byKey['material/grey-wool']!.status, RestoreStatus.conflict);
    expect(byKey['material/grey-wool']!.copyName, 'Grey wool (restored)');
    expect(byKey['material/grey-wool']!.projects, 1);
    expect(byKey['material/cotton-8-2']!.status, RestoreStatus.alreadyPresent);
    expect(byKey['swatch/sw-knit']!.status, RestoreStatus.add);
    expect(byKey['swatch/sw-knit']!.photoCount, 1);

    final result = await materialService().restore(plan);
    expect(result.materialsRestored, 1);
    expect(result.swatchesRestored, 1);
    expect(result.projectsRelinkedToMaterials, 1);
    final after = await readRecords(docs);
    expect(after.materials.take(2), before.materials, reason: 'existing records never change');
    final copy = after.materials.last;
    expect(copy.name, 'Grey wool (restored)');
    expect(copy.copyWith(id: wool.id, name: wool.name), wool);
    final sw = after.swatches.single;
    expect(sw.id, 'sw-knit');
    expect(sw.yarns.single.materialId, copy.id, reason: 'its yarn points at the copy');
    expect(sw.yarns.single.name, 'Grey wool (restored)');
    expect(File(p.join(docs.path, photoPath)).readAsBytesSync(), photo1);
    // The restored project links the copy, and keeps every other key.
    final links = sidecarOf(docs, 'knits/k9.json')['materials'] as Map;
    expect(links['yarns'][0],
        {'materialId': copy.id, 'materialName': 'Grey wool (restored)', 'role': 'main'});
    expect(links['swatches'][0], {'swatchId': 'sw-knit', 'swatchName': 'Grey wool stockinette'});

    // The same backup again: everything is already here.
    final again = await materialService().inspectBackup(archive);
    expect(again.materials!.items.map((i) => i.status).toSet(), {RestoreStatus.alreadyPresent});
    expect(again.projects.where((p) => p.id == 'k9').single.status, RestoreStatus.alreadyPresent);
    final snap = await snapshot(docs);
    await materialService().restore(again);
    expect(await snapshot(docs), snap);
  });

  test('an unticked copy is not added, and restored projects keep the link they had', () async {
    final source = await Directory.systemTemp.createTemp('backup_src');
    addTearDown(() => source.delete(recursive: true));
    await putLinkedProject(source);
    await writeRecords(source, materials: [wool]);
    final archive = await backUp(materialService(into: source));
    await writeRecords(docs, materials: [wool.copyWith(name: 'Mine')]);
    final plan = await materialService().inspectBackup(archive);
    final result =
        await materialService().restore(plan, skippedMaterialConflicts: {'material/grey-wool'});
    expect(result.materialsRestored, 0);
    expect(result.projectsRelinkedToMaterials, 0);
    expect((await readRecords(docs)).materials.single.name, 'Mine');
    expect((sidecarOf(docs, 'knits/k9.json')['materials'] as Map)['yarns'][0]['materialId'],
        'grey-wool');
  });

  test('a swatch whose photos are not all here is added as a copy with its photos', () async {
    final source = await Directory.systemTemp.createTemp('backup_src');
    addTearDown(() => source.delete(recursive: true));
    await writeRecords(source, swatches: [knitSwatch]);
    await put(source, photoPath, photo1);
    final archive = await backUp(materialService(into: source));
    await writeRecords(docs, swatches: [knitSwatch]); // the record, but no photo
    final plan = await materialService().inspectBackup(archive);
    final item = plan.materials!.items.single;
    expect(item.status, RestoreStatus.conflict);
    await materialService().restore(plan);
    final copyId = item.copyId!;
    expect(
        File(p.join(docs.path, 'swatches', '$copyId.photos', 'aaa.jpg')).readAsBytesSync(), photo1);
    expect((await readRecords(docs)).swatches.map((s) => s.id), ['sw-knit', copyId]);
  });

  test('a failure late in the restore puts materials.json back and removes the photos', () async {
    final source = await Directory.systemTemp.createTemp('backup_src');
    addTearDown(() => source.delete(recursive: true));
    await seedLibrary(source);
    await writeRecords(source, materials: [wool], swatches: [knitSwatch]);
    await put(source, photoPath, photo1);
    final archive = await backUp(materialService(into: source, settings: const AppSettings()));
    await writeRecords(docs, materials: [cotton]);
    final snap = await snapshot(docs);
    final failing = materialService(applySettings: (_) async => throw StateError('no settings'));
    final plan = await failing.inspectBackup(archive);
    await expectLater(
        failing.restore(plan, restoreSettings: true), throwsA(isA<BackupException>()));
    expect(await snapshot(docs), snap);
  });

  test('an older backup without materials restores exactly as before', () async {
    final source = await Directory.systemTemp.createTemp('backup_src');
    addTearDown(() => source.delete(recursive: true));
    await seedLibrary(source);
    final archive = await backUp(service(into: source));
    final plan = await materialService().inspectBackup(archive);
    expect(plan.materials, isNull);
    final result = await materialService().restore(plan);
    expect(result.count, plan.projects.where((p) => p.status == RestoreStatus.add).length);
    expect(File(p.join(docs.path, MaterialsRepository.fileName)).existsSync(), isFalse);
  });

  test('materials this build cannot use are refused with the reason; the projects restore',
      () async {
    final newer = utf8.encode(jsonEncode({'format': kMaterialsFormat, 'schema_version': 9}));
    String sha(List<int> d) => sha256.convert(d).toString();
    final archive = await archiveFile([
      manifestEntry({
        'format': 'ply.backup',
        'schema_version': 1,
        'created_at': '2026-11-16T10:30:00.000Z',
        'app_version': 'crafted',
        'files': [
          {'path': backupMaterialsPath, 'size': newer.length, 'sha256': sha(newer)},
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
      entry(backupMaterialsPath, newer),
      for (final (path, data) in goodDraft) entry(path, data),
    ]);
    final plan = await materialService().inspectBackup(archive);
    expect(plan.materials!.refusal, RestoreMaterials.newer);
    expect(plan.projects.single.status, RestoreStatus.add);
    // A build without materials support says so, and still restores the projects.
    final without = await service().inspectBackup(archive);
    expect(without.materials!.refusal, RestoreMaterials.unsupported);
    final result = await service().restore(without);
    expect(result.count, 1);
  });

  test('a photo outside the layout makes the backup unsafe', () async {
    final bytes = [1, 2, 3];
    String sha(List<int> d) => sha256.convert(d).toString();
    const bad = 'swatches/x.photos/../../escape.jpg';
    final archive = await archiveFile([
      manifestEntry({
        'format': 'ply.backup',
        'schema_version': 1,
        'created_at': '2026-11-16T10:30:00.000Z',
        'app_version': 'crafted',
        'files': [
          {'path': bad, 'size': bytes.length, 'sha256': sha(bytes)},
        ],
      }),
      entry(bad, bytes),
    ]);
    await expectLater(materialService().inspectBackup(archive),
        throwsA(isA<BackupException>().having((e) => e.problem, 'problem', BackupProblem.unsafe)));
  });

  group('review fixes', () {
    Future<File> sourceBackup(
        {List<MaterialRecord> materials = const [], List<SwatchRecord> swatches = const []}) async {
      final source = await Directory.systemTemp.createTemp('backup_src');
      addTearDown(() => source.delete(recursive: true));
      await putLinkedProject(source);
      await writeRecords(source, materials: materials, swatches: swatches);
      return backUp(materialService(into: source));
    }

    test('materials that would make the merged file too large are left out; projects restore',
        () async {
      final archive = await sourceBackup(materials: [wool]);
      await writeRecords(docs, materials: [cotton]);
      final before = File(p.join(docs.path, MaterialsRepository.fileName)).readAsBytesSync();
      final s = materialService(fits: (_) async => false);
      final plan = await s.inspectBackup(archive);
      expect(plan.materials!.refusal, RestoreMaterials.tooLarge);
      final result = await s.restore(plan);
      expect(result.count, 1, reason: 'the project is restored');
      expect(result.materialsRestored, 0);
      expect(File(p.join(docs.path, MaterialsRepository.fileName)).readAsBytesSync(), before);
    });

    test('the record limits count only what will be added', () async {
      final archive = await sourceBackup(materials: [wool, cotton.copyWith(name: 'Theirs')]);
      // 499 of the crafter's own, one of them under the cotton's id: adding both would pass 500.
      await writeRecords(docs,
          materials: [
            cotton,
            for (var i = 0; i < MaterialLimits.maxMaterials - 1; i++)
              MaterialRecord(id: 'm$i', name: 'Mine $i'),
          ].take(MaterialLimits.maxMaterials - 1).toList());
      final s = materialService();
      final plan = await s.inspectBackup(archive);
      final m = plan.materials!;
      expect(m.refusal, isNull, reason: 'not refused before the crafter chooses');
      expect(m.limitProblem(const {}), RestoreMaterials.tooMany);
      const skip = {'material/cotton-8-2'};
      expect(m.limitProblem(skip), isNull, reason: 'without the copy it fits');
      final result = await s.restore(plan, skippedMaterialConflicts: skip);
      expect(result.materialsRestored, 1);
      expect((await readRecords(docs)).materials, hasLength(MaterialLimits.maxMaterials));
      // With every copy kept the materials are left out and the project still restores.
      final again = await sourceBackup(materials: [cotton.copyWith(name: 'Other')]);
      final full = await s.inspectBackup(again);
      expect(full.materials!.limitProblem(const {}), RestoreMaterials.tooMany);
      final r = await s.restore(full);
      expect(r.materialsRestored, 0);
      expect((await readRecords(docs)).materials, hasLength(MaterialLimits.maxMaterials));
    });

    test('an unticked copy leaves the restored links on the crafter\'s own record, named',
        () async {
      final archive = await sourceBackup(materials: [wool], swatches: [knitSwatch]);
      await writeRecords(docs, materials: [wool.copyWith(name: 'My own grey')]);
      final plan = await materialService().inspectBackup(archive);
      final item = plan.materials!.items.firstWhere((i) => i.key == 'material/grey-wool');
      expect(item.localName, 'My own grey');
      expect(item.projects, 1);
      expect(item.swatchesNaming, 1, reason: 'the swatch this restore adds names it');
      await materialService().restore(plan, skippedMaterialConflicts: {item.key});
      final link = (sidecarOf(docs, 'knits/k9.json')['materials'] as Map)['yarns'][0] as Map;
      expect(link['materialId'], 'grey-wool', reason: 'the id of the crafter\'s own record');
      final sw = (await readRecords(docs)).swatches.single;
      expect(sw.yarns.single.materialId, 'grey-wool');
    });

    test('swatch ids are taken without regard to case', () async {
      const mixed = SwatchRecord(id: 'Sw-Knit', name: 'Mixed case', craft: SwatchCraft.knitting);
      final source = await Directory.systemTemp.createTemp('backup_src');
      addTearDown(() => source.delete(recursive: true));
      await writeRecords(source, swatches: [mixed]);
      await put(source, 'swatches/Sw-Knit.photos/aaa.jpg', photo1);
      final archive = await backUp(materialService(into: source));
      await put(docs, 'swatches/sw-knit.photos/old.jpg', photo2); // a folder left under sw-knit
      final plan = await materialService().inspectBackup(archive);
      final item = plan.materials!.items.single;
      expect(item.status, RestoreStatus.conflict, reason: 'one folder on a case-insensitive disk');
      final result = await materialService().restore(plan);
      expect(result.swatchesRestored, 1);
      expect(File(p.join(docs.path, 'swatches', '${item.copyId}.photos', 'aaa.jpg')).existsSync(),
          isTrue);
      expect(File(p.join(docs.path, 'swatches/sw-knit.photos/old.jpg')).readAsBytesSync(), photo2);
    });

    test('set-aside .corrupt copies are not backed up, and the summary says so', () async {
      await seedLibrary(docs);
      await writeRecords(docs, materials: [wool]);
      await put(docs, 'materials.json.corrupt', [1, 2, 3]);
      await put(docs, 'looms.json.corrupt', [4]);
      await put(docs, 'looms.json.corrupt.2', [5]);
      final plan = await materialService().planBackup();
      expect(plan.setAsideLeftOut, [
        '2 unreadable copies of My looms, kept as looms.json.corrupt, are not in this backup.',
        'An unreadable copy of your materials, kept as materials.json.corrupt, is not in this '
            'backup.',
      ]);
      expect(plan.manifest.files.map((f) => f.path).where((x) => x.contains('corrupt')), isEmpty);
      expect(
          (await materialService().planBackup()).withSettings(false).setAsideLeftOut, hasLength(2));
    });
  });
}
