import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/nalbind_repository.dart';
import 'package:ply/src/models/nalbind_project.dart';

// The nalbind PROJECT model + persistence: JSON round-trip, and the on-device <id>.{plynal,json}
// save/list/read/rename(via re-save)/delete cycle over a temp dir (no FFI, no path_provider).

void main() {
  test('NalbindProject JSON round-trips', () {
    const p = NalbindProject(
      name: 'Winter socks',
      notation: 'UO/UOO F1',
      stitchName: 'Oslo',
      notes: 'Cast on 8 over the thumb, increase 1 each round to 24.',
    );
    expect(NalbindProject.fromJson(p.toJson()), p);
  });

  test('NalbindProject.fromJson tolerates a partial/empty map', () {
    expect(NalbindProject.fromJson(const {}), const NalbindProject());
    expect(NalbindProject.fromJson(const {'name': 'X'}), const NalbindProject(name: 'X'));
  });

  group('NalbindRepository persistence', () {
    late Directory dir;
    late NalbindRepository repo;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('ply_nalbind_test');
      repo = NalbindRepository()..dirOverride = dir;
    });
    tearDown(() => dir.delete(recursive: true));

    test('save -> list -> read a project', () async {
      const project = NalbindProject(
        name: 'Mittens',
        notation: 'UOO/UUOO F2',
        stitchName: 'Mammen',
        notes: 'thumb gusset at round 6',
      );
      final id = await repo.saveProject(project);

      final list = await repo.listProjects();
      expect(list, hasLength(1));
      expect(list.single.id, id);
      expect(list.single.name, 'Mittens');

      final read = await repo.readProject(id);
      expect(read, project);
    });

    test('re-saving with the same id renames in place (one entry, new name)', () async {
      final id = await repo.saveProject(const NalbindProject(name: 'Draft', notes: 'a'));
      await repo.saveProject(const NalbindProject(name: 'Final', notes: 'a, b'), id: id);
      final list = await repo.listProjects();
      expect(list, hasLength(1), reason: 'still one project');
      expect(list.single.name, 'Final');
      expect((await repo.readProject(id)).notes, 'a, b');
    });

    test('an empty name persists as Untitled', () async {
      final id = await repo.saveProject(const NalbindProject(notes: 'x'));
      expect((await repo.listProjects()).single.name, 'Untitled');
      expect((await repo.readProject(id)).name, '', reason: 'the body keeps the empty name verbatim');
    });

    test('delete removes the project from the list', () async {
      final id = await repo.saveProject(const NalbindProject(name: 'Temp'));
      await repo.deleteProject(id);
      expect(await repo.listProjects(), isEmpty);
    });

    test('newest-opened sorts first', () async {
      final a = await repo.saveProject(const NalbindProject(name: 'A'));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final b = await repo.saveProject(const NalbindProject(name: 'B'));
      // B saved last -> highest lastOpened -> first.
      expect((await repo.listProjects()).map((e) => e.id).toList(), [b, a]);
    });

    test('a sidecar without its .plynal body is skipped (atomic save invariant)', () async {
      // Write a stray .json with no matching .plynal — listProjects must ignore it.
      await File('${dir.path}/orphan.json').writeAsString('{"name":"orphan","craft":"Nalbinding"}');
      await repo.saveProject(const NalbindProject(name: 'real'));
      final list = await repo.listProjects();
      expect(list, hasLength(1));
      expect(list.single.name, 'real');
    });
  });
}
