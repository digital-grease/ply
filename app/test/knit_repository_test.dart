import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/knit_repository.dart';

// The knit library's file-only persistence paths over a temp dir (no FFI, no path_provider): delete
// removes the whole <id>.{plyknit,json,png} triplet plus any interrupted-save .tmp leftovers, and
// tolerates missing files. Saving goes through the engine serializer, so these tests lay the files
// down by hand.

void main() {
  late Directory dir;
  late KnitRepository repo;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ply_knit_repo_test');
    repo = KnitRepository()..dirOverride = dir;
  });
  tearDown(() => dir.delete(recursive: true));

  const sidecar = '{"name":"Hat","craft":"Knitting","savedAt":"2020-01-01T00:00:00.000Z",'
      '"lastOpened":"2020-01-01T00:00:00.000Z"}';

  List<File> layDown(String id, {bool tmps = false}) {
    final files = [
      File('${dir.path}/$id.plyknit')..writeAsStringSync('{}'),
      File('${dir.path}/$id.json')..writeAsStringSync(sidecar),
      File('${dir.path}/$id.png')..writeAsBytesSync(const [0x89, 0x50, 0x4E, 0x47]),
    ];
    if (tmps) {
      for (final ext in ['plyknit', 'json', 'png']) {
        files.add(File('${dir.path}/$id.$ext.tmp')..writeAsStringSync('half-written'));
      }
    }
    return files;
  }

  test('a laid-down pattern is listed (sanity check for the fixture)', () async {
    layDown('k1');
    final list = await repo.listKnits();
    expect(list.single.id, 'k1');
    expect(list.single.meta.name, 'Hat');
  });

  test('delete removes the triplet and any .tmp leftovers of an interrupted save', () async {
    final files = layDown('k1', tmps: true);
    await repo.deleteKnit('k1');
    for (final f in files) {
      expect(f.existsSync(), isFalse, reason: '${f.path} must not survive a delete');
    }
    expect(await repo.listKnits(), isEmpty);
  });

  test('delete tolerates missing files and leaves other patterns alone', () async {
    File('${dir.path}/half.json').writeAsStringSync(sidecar); // no .plyknit / .png
    final kept = layDown('kept');
    await repo.deleteKnit('half');
    await repo.deleteKnit('never-existed');
    expect(File('${dir.path}/half.json').existsSync(), isFalse);
    for (final f in kept) {
      expect(f.existsSync(), isTrue);
    }
    expect((await repo.listKnits()).single.id, 'kept');
  });
}
