import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:ply/src/data/library_backup.dart' show BackupCraft;
import 'package:ply/src/data/nalbind_repository.dart';
import 'package:ply/src/data/project_links_repository.dart';
import 'package:ply/src/models/nalbind_project.dart';
import 'package:ply/src/models/project_materials.dart';

// The nalbinding repository's sidecar writes take the app-wide sidecar lock (ADR 0016) inside its own
// per-project lock, so a link the materials sheet writes at the same moment as a save, a touch or a
// delete is never lost or brought back, and the two locks never wait on each other.

void main() {
  late Directory docs;
  late NalbindRepository repo;
  late ProjectLinksRepository links;
  final linked =
      ProjectMaterials(swatches: [SwatchLink(swatchId: 'sw-oslo', swatchName: 'Oslo sample')]);

  setUp(() async {
    docs = await Directory.systemTemp.createTemp('nal_lock');
    repo = NalbindRepository()..dirOverride = Directory(p.join(docs.path, 'nalbinds'));
    links = ProjectLinksRepository(docsOverride: docs);
  });
  tearDown(() => docs.delete(recursive: true));

  Map<String, dynamic> sidecar(String id) =>
      jsonDecode(File(p.join(docs.path, 'nalbinds', '$id.json')).readAsStringSync())
          as Map<String, dynamic>;

  NalbindProject project(String name) =>
      NalbindProject(name: name, notation: 'UO/UOO F1', notes: 'n');

  test('a save and a link written at the same time both keep their change', () async {
    final id = await repo.saveProject(project('Mitten'));
    await Future.wait([
      repo.saveProject(project('Mitten, lined'), id: id),
      links.write(BackupCraft.nalbinding, id, linked),
    ]).timeout(const Duration(seconds: 10));
    final json = sidecar(id);
    expect(json['name'], 'Mitten, lined');
    expect(json['materials'], linked.toJson());
  });

  test('a touch and a link at the same time keep both', () async {
    final id = await repo.saveProject(project('Hat'));
    final before = DateTime.parse(sidecar(id)['lastOpened'] as String);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await Future.wait([
      links.write(BackupCraft.nalbinding, id, linked),
      repo.touchOpened(id),
    ]).timeout(const Duration(seconds: 10));
    final json = sidecar(id);
    expect(json['materials'], linked.toJson());
    expect(DateTime.parse(json['lastOpened'] as String).isAfter(before), isTrue);
  });

  test('a link cannot bring a deleted project back, and nothing waits forever', () async {
    final id = await repo.saveProject(project('Sock'));
    final writes = [
      repo.saveProject(project('Sock 2'), id: id),
      links.write(BackupCraft.nalbinding, id, linked).catchError((Object _) {}),
      repo.touchOpened(id),
      repo.deleteProject(id),
      links.write(BackupCraft.nalbinding, id, ProjectMaterials.none).catchError((Object _) {}),
    ];
    await Future.wait(writes).timeout(const Duration(seconds: 10));
    final dir = Directory(p.join(docs.path, 'nalbinds'));
    final left = dir.listSync().map((e) => p.basename(e.path)).toList();
    expect(left, isEmpty, reason: 'no sidecar, body or temp file of a deleted project: $left');
  });
}
