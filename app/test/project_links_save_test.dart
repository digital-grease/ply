import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:ply/src/data/draft_repository.dart';
import 'package:ply/src/data/knit_repository.dart';
import 'package:ply/src/data/library_backup.dart' show BackupCraft;
import 'package:ply/src/data/project_links_repository.dart';
import 'package:ply/src/data/sidecar_writes.dart';
import 'package:ply/src/models/draft_meta.dart';
import 'package:ply/src/models/material_record.dart';
import 'package:ply/src/models/project_materials.dart';

// A project's links are written by the materials sheet as they change (ADR 0016), so a save must
// never undo them: the weaving editor rebuilds its sidecar from the meta it opened with, and the
// draft repository carries the links on disk forward. (Knitting and nalbinding saves merge into the
// sidecar on disk, so they keep the key by construction.)

void main() {
  late Directory docs;
  setUp(() async => docs = await Directory.systemTemp.createTemp('links_save'));
  tearDown(() => docs.delete(recursive: true));

  test('a weaving save keeps the links written while the editor was open', () async {
    final drafts = Directory(p.join(docs.path, 'drafts'))..createSync();
    final repo = DraftRepository(draftsDirOverride: drafts);
    final opened = DraftMeta(
        name: 'Towel', savedAt: DateTime.utc(2026, 11, 1), lastOpened: DateTime.utc(2026, 11, 1));
    const wif = '[WIF]\nVersion=1.1\n';
    final id = await repo.save(wifText: wif, meta: opened);
    // The sheet links a swatch while the editor is open...
    final links = ProjectLinksRepository(docsOverride: docs);
    await links.write(BackupCraft.weaving, id,
        ProjectMaterials(swatches: [SwatchLink(swatchId: 'sw-towel', swatchName: 'Towel sample')]));
    // ...then the editor saves with the meta it opened with (no links in it).
    await repo.save(wifText: wif, meta: opened.copyWith(name: 'Towel, washed'), id: id);
    final json = jsonDecode(File(p.join(drafts.path, '$id.json')).readAsStringSync()) as Map;
    expect(json['name'], 'Towel, washed');
    expect(json['materials'], {
      'yarns': [],
      'swatches': [
        {'swatchId': 'sw-towel', 'swatchName': 'Towel sample'}
      ],
    });
    // Unlinking in the sheet is kept too: the meta's stale links never come back.
    await links.write(BackupCraft.weaving, id, ProjectMaterials.none);
    final stale = DraftMeta.fromJson({
      ...opened.toJson(),
      'materials': {
        'yarns': [
          {'materialId': 'old', 'materialName': 'Old yarn', 'role': YarnRole.warp.serialName}
        ],
      },
    });
    await repo.save(wifText: wif, meta: stale, id: id);
    final after = jsonDecode(File(p.join(drafts.path, '$id.json')).readAsStringSync()) as Map;
    expect(after.containsKey('materials'), isFalse);
  });

  test('a new draft saves with no links and no key', () async {
    final drafts = Directory(p.join(docs.path, 'drafts'))..createSync();
    final repo = DraftRepository(draftsDirOverride: drafts);
    final id = await repo.save(
        wifText: '[WIF]\n',
        meta: DraftMeta(name: 'New', savedAt: DateTime.utc(2026), lastOpened: DateTime.utc(2026)));
    final json = jsonDecode(File(p.join(drafts.path, '$id.json')).readAsStringSync()) as Map;
    expect(json.containsKey('materials'), isFalse);
    expect(await ProjectLinksRepository(docsOverride: docs).read(BackupCraft.weaving, id),
        ProjectMaterials.none);
  });

  test('a save and a link written at the same time both keep their change', () async {
    final drafts = Directory(p.join(docs.path, 'drafts'))..createSync();
    final repo = DraftRepository(draftsDirOverride: drafts);
    final opened =
        DraftMeta(name: 'Towel', savedAt: DateTime.utc(2026), lastOpened: DateTime.utc(2026));
    const wif = '[WIF]\n';
    final id = await repo.save(wifText: wif, meta: opened);
    final links = ProjectLinksRepository(docsOverride: docs);
    final linked =
        ProjectMaterials(swatches: [SwatchLink(swatchId: 'sw-towel', swatchName: 'Towel sample')]);
    // Neither awaited before the other starts.
    await Future.wait([
      repo.save(wifText: wif, meta: opened.copyWith(name: 'Renamed'), id: id),
      links.write(BackupCraft.weaving, id, linked),
    ]);
    final json = jsonDecode(File(p.join(drafts.path, '$id.json')).readAsStringSync()) as Map;
    expect(json['name'], 'Renamed');
    expect(json['materials'], linked.toJson());
    expect(
        drafts.listSync().map((e) => p.basename(e.path)).where((n) => n.endsWith('.tmp')), isEmpty);
  });

  test('writes to one sidecar run one at a time, in order', () async {
    final events = <String>[];
    final gate = Completer<void>();
    final first = SidecarWrites.run('/x/a.json', () async {
      events.add('first starts');
      await gate.future;
      events.add('first ends');
    });
    final second = SidecarWrites.run('/x/../x/a.json', () async => events.add('second'));
    final other = SidecarWrites.run('/x/b.json', () async => events.add('other sidecar'));
    await other;
    expect(events, ['first starts', 'other sidecar']);
    gate.complete();
    await Future.wait([first, second]);
    expect(events, ['first starts', 'other sidecar', 'first ends', 'second']);
    // A failed write does not block the next.
    await expectLater(
        SidecarWrites.run('/x/a.json', () async => throw StateError('no')), throwsStateError);
    expect(await SidecarWrites.run('/x/a.json', () async => 7), 7);
  });

  test('an open or a rename at the same time as a link keeps both (weaving and knitting)',
      () async {
    final drafts = Directory(p.join(docs.path, 'drafts'))..createSync();
    final knits = Directory(p.join(docs.path, 'knits'))..createSync();
    final weave = DraftRepository(draftsDirOverride: drafts);
    final knit = KnitRepository()..dirOverride = knits;
    final links = ProjectLinksRepository(docsOverride: docs);
    final linked = ProjectMaterials(swatches: [SwatchLink(swatchId: 'sw', swatchName: 'Sample')]);
    final d = await weave.save(
        wifText: '[WIF]\n',
        meta:
            DraftMeta(name: 'Towel', savedAt: DateTime.utc(2026), lastOpened: DateTime.utc(2026)));
    // A knitting pattern's files, as its save writes them (the save itself needs the engine).
    File(p.join(knits.path, 'k1.plyknit')).writeAsStringSync('{}');
    File(p.join(knits.path, 'k1.json')).writeAsStringSync(jsonEncode(
        DraftMeta(name: 'Hat', savedAt: DateTime.utc(2026), lastOpened: DateTime.utc(2026))
            .toJson()));
    await Future.wait([
      weave.rename(d, 'Towel, washed'),
      links.write(BackupCraft.weaving, d, linked),
      weave.open(d),
      knit.renameKnit('k1', 'Hat, ribbed'),
      links.write(BackupCraft.knitting, 'k1', linked),
      knit.openKnit('k1'),
    ]).timeout(const Duration(seconds: 10));
    final w = jsonDecode(File(p.join(drafts.path, '$d.json')).readAsStringSync()) as Map;
    final k = jsonDecode(File(p.join(knits.path, 'k1.json')).readAsStringSync()) as Map;
    expect(w['name'], 'Towel, washed');
    expect(w['materials'], linked.toJson());
    expect(k['name'], 'Hat, ribbed');
    expect(k['materials'], linked.toJson());
  });

  test('a deleted project\'s sidecar is not brought back by a link written at the same time',
      () async {
    final drafts = Directory(p.join(docs.path, 'drafts'))..createSync();
    final weave = DraftRepository(draftsDirOverride: drafts);
    final links = ProjectLinksRepository(docsOverride: docs);
    final d = await weave.save(
        wifText: '[WIF]\n',
        meta: DraftMeta(name: 'Gone', savedAt: DateTime.utc(2026), lastOpened: DateTime.utc(2026)));
    await Future.wait([
      links
          .write(BackupCraft.weaving, d,
              ProjectMaterials(swatches: [SwatchLink(swatchId: 's', swatchName: 'S')]))
          .catchError((Object _) {}),
      weave.delete(d),
    ]).timeout(const Duration(seconds: 10));
    expect(drafts.listSync().map((e) => p.basename(e.path)).where((n) => n.startsWith(d)), isEmpty);
  });
}
