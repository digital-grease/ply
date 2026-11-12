import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/nalbind_repository.dart';
import 'package:ply/src/data/photo_store.dart';
import 'package:ply/src/models/nalbind_project.dart';

// The nalbind PROJECT model + persistence: JSON round-trip, and the on-device <id>.{plynal,json}
// save/list/read/rename(via re-save)/delete cycle over a temp dir (no FFI, no path_provider). Also
// the privacy cleanup: delete removes the project's <id>.photos/ folder, and the orphan sweep removes
// photo folders left behind by earlier deletes without ever touching a live project's photos.

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
  group('NalbindRepository photo cleanup', () {
    late Directory docs; // stands in for the app documents dir
    late Directory nalbinds; // <docs>/nalbinds, the repo's dir AND PhotoStore's subdir
    late NalbindRepository repo;

    setUp(() async {
      docs = await Directory.systemTemp.createTemp('ply_nalbind_photos_test');
      nalbinds = Directory('${docs.path}/nalbinds');
      repo = NalbindRepository()..dirOverride = nalbinds;
    });
    tearDown(() => docs.delete(recursive: true));

    /// A real photo attached through PhotoStore (so the test also pins that the repo and the store
    /// agree on where a project's photos live).
    Future<File> attachPhoto(String id) async {
      final src = File('${docs.path}/src.jpg')..writeAsBytesSync(const [0xFF, 0xD8, 0xFF]);
      return PhotoStore(subdir: 'nalbinds', id: id, docsOverride: docs).add(src);
    }

    Directory photosDir(String id) => Directory('${nalbinds.path}/$id.photos');

    /// A photo folder written by hand, for ids that have no project files (or only one of them).
    Future<Directory> strayPhotos(String id) async {
      final d = await photosDir(id).create(recursive: true);
      File('${d.path}/p.jpg').writeAsBytesSync(const [1, 2, 3]);
      return d;
    }

    test('delete removes the photo folder and every photo in it', () async {
      final id = await repo.saveProject(const NalbindProject(name: 'Socks'));
      final photo = await attachPhoto(id);
      expect(photo.existsSync(), isTrue);
      expect(photo.parent.path, photosDir(id).path, reason: 'PhotoStore writes <id>.photos/');

      await repo.deleteProject(id);

      expect(photosDir(id).existsSync(), isFalse, reason: 'no photo survives a delete');
      expect(File('${nalbinds.path}/$id.json').existsSync(), isFalse);
      expect(File('${nalbinds.path}/$id.plynal').existsSync(), isFalse);
      expect(await repo.listProjects(), isEmpty);
    });

    test('delete tolerates a project that never had photos', () async {
      final id = await repo.saveProject(const NalbindProject(name: 'No photos'));
      expect(photosDir(id).existsSync(), isFalse);
      await repo.deleteProject(id); // must not throw
      expect(await repo.listProjects(), isEmpty);
    });

    test('delete tolerates an id with nothing on disk at all', () async {
      await repo.deleteProject('never-existed'); // must not throw
    });

    test('delete also removes .tmp leftovers of an interrupted save', () async {
      final id = await repo.saveProject(const NalbindProject(name: 'T'));
      final tmps = [
        File('${nalbinds.path}/$id.plynal.tmp'),
        File('${nalbinds.path}/$id.json.tmp'),
      ];
      for (final f in tmps) {
        f.writeAsStringSync('{"name":"half-written"}');
      }
      await repo.deleteProject(id);
      for (final f in tmps) {
        expect(f.existsSync(), isFalse, reason: '${f.path} holds project content too');
      }
    });

    test("delete leaves OTHER projects' photos alone", () async {
      final gone = await repo.saveProject(const NalbindProject(name: 'Gone'));
      final kept = await repo.saveProject(const NalbindProject(name: 'Kept'));
      await attachPhoto(gone);
      final keptPhoto = await attachPhoto(kept);

      await repo.deleteProject(gone);

      expect(photosDir(gone).existsSync(), isFalse);
      expect(keptPhoto.existsSync(), isTrue);
      expect((await repo.listProjects()).single.id, kept);
    });

    test('the sweep removes a true orphan and never touches a live project', () async {
      // A complete project with photos.
      final live = await repo.saveProject(const NalbindProject(name: 'Live'));
      final livePhoto = await attachPhoto(live);
      // Only the sidecar left (e.g. the body was lost): its photos must stay.
      await strayPhotos('sidecar-only');
      File('${nalbinds.path}/sidecar-only.json').writeAsStringSync('{"name":"s"}');
      // Only the body left (e.g. the sidecar was deleted first and the delete stopped there).
      await strayPhotos('plynal-only');
      File('${nalbinds.path}/plynal-only.plynal').writeAsStringSync('{}');
      // Neither file: what a pre-fix delete left behind.
      await strayPhotos('orphan');

      await repo.sweepOrphanedPhotos();

      expect(photosDir('orphan').existsSync(), isFalse, reason: 'a true orphan is removed');
      expect(livePhoto.existsSync(), isTrue, reason: 'a complete project keeps its photos');
      expect(photosDir('sidecar-only').existsSync(), isTrue, reason: 'sidecar exists -> untouched');
      expect(photosDir('plynal-only').existsSync(), isTrue, reason: 'body exists -> untouched');
      expect(File('${photosDir('sidecar-only').path}/p.jpg').existsSync(), isTrue);
      expect(File('${photosDir('plynal-only').path}/p.jpg').existsSync(), isTrue);
    });

    test('the sweep only considers <id>.photos folders', () async {
      final otherDir = await Directory('${nalbinds.path}/not-photos').create(recursive: true);
      final photosNamedFile = File('${nalbinds.path}/stray.photos')..writeAsStringSync('x');
      await repo.sweepOrphanedPhotos();
      expect(otherDir.existsSync(), isTrue);
      expect(photosNamedFile.existsSync(), isTrue, reason: 'a FILE named .photos is not a folder');
    });

    test('the sweep is a no-op on a clean library and on a missing directory', () async {
      await repo.sweepOrphanedPhotos(); // empty dir
      final missing = NalbindRepository()..dirOverride = Directory('${docs.path}/nope/nalbinds');
      await missing.sweepOrphanedPhotos(); // created on demand, nothing to do
    });

    test('the first listing of a run sweeps orphans once', () async {
      final live = await repo.saveProject(const NalbindProject(name: 'Live'));
      await attachPhoto(live);
      await strayPhotos('old-orphan');

      final list = await repo.listProjects();

      expect(list.single.id, live, reason: 'the listing itself is unaffected');
      expect(photosDir('old-orphan').existsSync(), isFalse, reason: 'swept on the first listing');
      expect(photosDir(live).existsSync(), isTrue);

      // Once per repository instance (one per app run): later listings stay a plain scan.
      await strayPhotos('later-orphan');
      await repo.listProjects();
      expect(photosDir('later-orphan').existsSync(), isTrue, reason: 'no repeat sweep this run');
      // A new run (a fresh repository) sweeps again.
      await (NalbindRepository()..dirOverride = nalbinds).listProjects();
      expect(photosDir('later-orphan').existsSync(), isFalse);
    });
  });
}
