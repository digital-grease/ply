import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/knit_repository.dart';
import 'package:ply/src/models/draft_meta.dart';
import 'package:ply/src/models/native_format.dart';
import 'package:ply/src/rust/dto.dart' show UnitKind;
import 'package:ply/src/rust/knit_dto.dart';

// The knit library's file persistence over a temp dir (no FFI, no path_provider): delete removes the
// whole <id>.{plyknit,json,png} triplet plus any interrupted-save .tmp leftovers and format-upgrade
// backups, and tolerates missing files. Saving over an existing file keeps a one-time backup before a
// format upgrade, refuses to replace a newer or unreadable file, and merges into the existing
// sidecar. The engine serializer is stood in for by a canned current-version envelope (the real one
// is covered by the Rust tests); legacy files are the real released bytes from `fixtures/`.

/// What the engine writes for any pattern here: a current-version (5) envelope.
final String _current = jsonEncode({
  'format': 'ply.knit',
  'schema_version': 5,
  'document': {'name': 'saved now', 'cast_on': null, 'sections': []},
});

class DiskOnlyKnitRepo extends KnitRepository {
  int writes = 0;

  @override
  Future<String> write(KnitPatternDto pattern) async {
    writes++;
    return _current;
  }

  @override
  Future<KnitPatternDto> parse(String json) async => _pattern;

  /// No native lib on the host: the thumbnail is best-effort and skipped.
  @override
  Future<ui.Image> render(KnitPatternDto pattern, {required int cellPx}) =>
      Future<ui.Image>.error(StateError('no FFI in host tests'));
}

const _pattern = KnitPatternDto(
  name: 'p',
  construction: ConstructionKind.flat,
  firstRowSide: SideKind.rs,
  gauge: GaugeDto(sts: 18, rows: 24, unit: UnitKind.inches),
  palette: [],
  legend: StitchLegendDto(stitches: []),
  chart: ChartDto(width: 0, rows: []),
  notes: '',
  sections: [],
);

List<int> fixtureBytes(String rel) => File('../fixtures/migrations/$rel').readAsBytesSync();

void main() {
  late Directory dir;
  late DiskOnlyKnitRepo repo;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ply_knit_repo_test');
    repo = DiskOnlyKnitRepo()..dirOverride = dir;
  });
  tearDown(() => dir.delete(recursive: true));

  const sidecar = '{"name":"Hat","craft":"Knitting","savedAt":"2020-01-01T00:00:00.000Z",'
      '"lastOpened":"2020-01-01T00:00:00.000Z"}';

  File f(String name) => File('${dir.path}/$name');

  DraftMeta meta(String name) {
    final now = DateTime.now();
    return DraftMeta(name: name, craft: 'Knitting', savedAt: now, lastOpened: now);
  }

  List<String> namesIn(Directory d) =>
      d.listSync().map((e) => e.uri.pathSegments.last).toList()..sort();

  List<File> layDown(String id, {bool tmps = false}) {
    final files = [
      f('$id.plyknit')..writeAsStringSync('{}'),
      f('$id.json')..writeAsStringSync(sidecar),
      f('$id.png')..writeAsBytesSync(const [0x89, 0x50, 0x4E, 0x47]),
    ];
    if (tmps) {
      for (final ext in ['plyknit', 'json', 'png']) {
        files.add(f('$id.$ext.tmp')..writeAsStringSync('half-written'));
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
    f('half.json').writeAsStringSync(sidecar); // no .plyknit / .png
    final kept = layDown('kept');
    await repo.deleteKnit('half');
    await repo.deleteKnit('never-existed');
    expect(f('half.json').existsSync(), isFalse);
    for (final f in kept) {
      expect(f.existsSync(), isTrue);
    }
    expect((await repo.listKnits()).single.id, 'kept');
  });

  group('format upgrades on save', () {
    test('saving over a released file backs up its original bytes exactly once', () async {
      final original = fixtureBytes('plyknit/v0.1.5/sampler.plyknit');
      f('k1.plyknit').writeAsBytesSync(original);
      f('k1.json').writeAsBytesSync(fixtureBytes('sidecar/v0.1.7/knit.json'));

      await repo.saveKnit(pattern: _pattern, meta: meta('Sampler'), id: 'k1');
      final backup = f('k1.plyknit.v1.bak');
      expect(backup.readAsBytesSync(), original, reason: 'the released bytes, untouched');
      expect(f('k1.plyknit').readAsStringSync(), _current,
          reason: 'upgraded to the current format');
      expect(plyknitSchemaVersion(f('k1.plyknit').readAsStringSync()), 5);

      // The file is current now: later saves neither add nor replace a backup.
      await repo.saveKnit(pattern: _pattern, meta: meta('Sampler'), id: 'k1');
      await repo.saveKnit(pattern: _pattern, meta: meta('Sampler'), id: 'k1');
      expect(backup.readAsBytesSync(), original);
      expect(namesIn(dir), ['k1.json', 'k1.plyknit', 'k1.plyknit.v1.bak'],
          reason: 'one backup, no temp files left behind');
    });

    for (final name in ['rib-edges-flat', 'rib-cast-on-unknown-flat', 'cable-repeat-round']) {
      test('saving over schema-version-2 $name keeps its bytes as a one-time .v2.bak', () async {
        // Real v2 bytes (written by the engine before v3). Opening one migrates it in memory
        // (engine, covered by the Rust tests: cast-on not set, nothing else changed); the first save
        // upgrades the file to v3 and keeps the original next to it, exactly once.
        final original = fixtureBytes('plyknit/schema-v2/$name.plyknit');
        expect(plyknitSchemaVersion(utf8.decode(original)), 2);
        f('k2.plyknit').writeAsBytesSync(original);
        f('k2.json').writeAsBytesSync(fixtureBytes('sidecar/v0.1.7/knit.json'));

        await repo.saveKnit(pattern: _pattern, meta: meta('Rib'), id: 'k2');
        final backup = f('k2.plyknit.v2.bak');
        expect(backup.readAsBytesSync(), original, reason: 'the v2 bytes, untouched');
        expect(plyknitSchemaVersion(f('k2.plyknit').readAsStringSync()), 5);

        await repo.saveKnit(pattern: _pattern, meta: meta('Rib'), id: 'k2');
        expect(backup.readAsBytesSync(), original, reason: 'a later save never replaces it');
        expect(namesIn(dir), ['k2.json', 'k2.plyknit', 'k2.plyknit.v2.bak']);

        // Deleting the pattern removes the backup with it.
        await repo.deleteKnit('k2');
        expect(namesIn(dir), isEmpty);
      });
    }

    for (final name in ['rib-cast-on-flat', 'seed-stitch-round', 'cable-repeat-round']) {
      test('saving over schema-version-3 $name keeps its bytes as a one-time .v3.bak', () async {
        // Real v3 bytes (written by the engine before v4). Opening one migrates it in memory
        // (engine, covered by the Rust tests: no sections, nothing else changed); the first save
        // upgrades the file to the current version and keeps the original next to it, once.
        final original = fixtureBytes('plyknit/schema-v3/$name.plyknit');
        expect(plyknitSchemaVersion(utf8.decode(original)), 3);
        f('k3.plyknit').writeAsBytesSync(original);
        f('k3.json').writeAsBytesSync(fixtureBytes('sidecar/v0.1.7/knit.json'));

        await repo.saveKnit(pattern: _pattern, meta: meta('Rib'), id: 'k3');
        final backup = f('k3.plyknit.v3.bak');
        expect(backup.readAsBytesSync(), original, reason: 'the v3 bytes, untouched');
        expect(plyknitSchemaVersion(f('k3.plyknit').readAsStringSync()), 5);

        await repo.saveKnit(pattern: _pattern, meta: meta('Rib'), id: 'k3');
        expect(backup.readAsBytesSync(), original, reason: 'a later save never replaces it');
        expect(namesIn(dir), ['k3.json', 'k3.plyknit', 'k3.plyknit.v3.bak']);

        await repo.deleteKnit('k3');
        expect(namesIn(dir), isEmpty);
      });
    }

    for (final name in [
      'shoulder-short-rows-flat',
      'neckline-hold-flat',
      'ledger-problems-flat',
      'eyelet-lace-round',
    ]) {
      test('saving over schema-version-4 $name keeps its bytes as a one-time .v4.bak', () async {
        // Real v4 bytes (written by the engine before v5). Opening one migrates it in memory
        // (engine, covered by the Rust tests: sections not stated, no short-row decreases, nothing
        // else changed); the first save upgrades the file and keeps the original next to it, once.
        final original = fixtureBytes('plyknit/schema-v4/$name.plyknit');
        expect(plyknitSchemaVersion(utf8.decode(original)), 4);
        f('k4.plyknit').writeAsBytesSync(original);
        f('k4.json').writeAsBytesSync(fixtureBytes('sidecar/v0.1.7/knit.json'));

        await repo.saveKnit(pattern: _pattern, meta: meta('Shoulder'), id: 'k4');
        final backup = f('k4.plyknit.v4.bak');
        expect(backup.readAsBytesSync(), original, reason: 'the v4 bytes, untouched');
        expect(plyknitSchemaVersion(f('k4.plyknit').readAsStringSync()), 5);

        await repo.saveKnit(pattern: _pattern, meta: meta('Shoulder'), id: 'k4');
        expect(backup.readAsBytesSync(), original, reason: 'a later save never replaces it');
        expect(namesIn(dir), ['k4.json', 'k4.plyknit', 'k4.plyknit.v4.bak']);

        await repo.deleteKnit('k4');
        expect(namesIn(dir), isEmpty);
      });
    }

    test('an existing backup is never replaced (it holds the true original)', () async {
      f('k1.plyknit').writeAsBytesSync(fixtureBytes('plyknit/v0.1.6/sampler.plyknit'));
      f('k1.plyknit.v1.bak').writeAsStringSync('the very first original');
      await repo.saveKnit(pattern: _pattern, meta: meta('S'), id: 'k1');
      expect(f('k1.plyknit.v1.bak').readAsStringSync(), 'the very first original');
      expect(f('k1.plyknit').readAsStringSync(), _current);
    });

    test('a current-version file is replaced without a backup', () async {
      f('k1.plyknit').writeAsStringSync(_current.replaceAll('saved now', 'older edit'));
      await repo.saveKnit(pattern: _pattern, meta: meta('S'), id: 'k1');
      expect(f('k1.plyknit').readAsStringSync(), _current);
      expect(namesIn(dir).where((n) => n.contains('.bak')), isEmpty);
    });

    test('saving a pattern with no chart cells removes an older thumbnail', () async {
      f('k1.png').writeAsBytesSync([1, 2, 3]);
      await repo.saveKnit(pattern: _pattern, meta: meta('Sections only'), id: 'k1');
      expect(f('k1.png').existsSync(), isFalse,
          reason: 'the chart it showed is gone; the library shows its placeholder');
    });

    test('a new pattern is written with its meta as given and no backup', () async {
      final id = await repo.saveKnit(pattern: _pattern, meta: meta('Fresh'));
      expect(namesIn(dir), ['$id.json', '$id.plyknit']);
      final saved =
          DraftMeta.fromJson(jsonDecode(f('$id.json').readAsStringSync()) as Map<String, dynamic>);
      expect(saved.name, 'Fresh');
      expect(saved.craft, 'Knitting');
    });

    for (final (label, onDisk, problem) in [
      (
        'a file saved by a newer Ply',
        '{"format":"ply.knit","schema_version":6,"document":{"future":true}}',
        NativeFormatProblem.newerVersion,
      ),
      ('an unreadable file', '{half a pattern', NativeFormatProblem.unreadable),
      (
        'another format',
        '{"format":"ply.nalbind","schemaVersion":2,"name":"x"}',
        NativeFormatProblem.unreadable,
      ),
    ]) {
      test('$label is never overwritten', () async {
        f('k1.plyknit').writeAsStringSync(onDisk);
        f('k1.json').writeAsStringSync(sidecar);
        await expectLater(
          repo.saveKnit(pattern: _pattern, meta: meta('Mine'), id: 'k1'),
          throwsA(isA<NativeFormatException>()
              .having((e) => e.problem, 'problem', problem)
              .having((e) => e.whileSaving, 'whileSaving', isTrue)),
        );
        expect(f('k1.plyknit').readAsStringSync(), onDisk, reason: 'bytes untouched');
        expect(f('k1.json').readAsStringSync(), sidecar, reason: 'sidecar untouched');
        expect(namesIn(dir), ['k1.json', 'k1.plyknit'], reason: 'no backup, no temp file');
      });
    }

    test('delete removes the pattern\'s backups and leaves other patterns\' alone', () async {
      layDown('k1');
      f('k1.plyknit.v1.bak').writeAsStringSync('original');
      f('k1.plyknit.v1.bak.tmp').writeAsStringSync('half a backup');
      f('k10.plyknit.v1.bak').writeAsStringSync('another pattern'); // id prefix "k1" must not match
      await repo.deleteKnit('k1');
      expect(namesIn(dir), ['k10.plyknit.v1.bak']);
    });
  });

  group('orphaned backup sweep', () {
    test('removes backups whose pattern AND sidecar are gone, keeps every other file', () async {
      layDown('alive');
      f('alive.plyknit.v1.bak').writeAsStringSync('original of a live pattern');
      f('gone.plyknit.v1.bak').writeAsStringSync('left behind by an older app');
      f('gone.plyknit.v1.bak.tmp').writeAsStringSync('half a backup');
      f('half.json').writeAsStringSync('{}'); // sidecar survives: not an orphan
      f('half.plyknit.v1.bak').writeAsStringSync('kept');
      f('notes.txt').writeAsStringSync('unrelated');
      await repo.sweepOrphanedBackups();
      final names = namesIn(dir);
      expect(names, isNot(contains('gone.plyknit.v1.bak')));
      expect(names, isNot(contains('gone.plyknit.v1.bak.tmp')));
      expect(names, containsAll(['alive.plyknit.v1.bak', 'half.plyknit.v1.bak', 'notes.txt']));
    });

    test('runs once per repository from the first listing', () async {
      f('gone.plyknit.v1.bak').writeAsStringSync('left behind');
      await repo.listKnits();
      expect(namesIn(dir), isNot(contains('gone.plyknit.v1.bak')));
      f('later.plyknit.v1.bak').writeAsStringSync('appears after the sweep');
      await repo.listKnits();
      expect(namesIn(dir), contains('later.plyknit.v1.bak'), reason: 'swept once per app run');
    });
  });

  group('sidecar preservation', () {
    const rich = '{"name":"Old name","craft":"Knitting","author":"Ada","notes":"gift for M",'
        '"savedAt":"2020-01-01T00:00:00.000Z","lastOpened":"2020-01-02T00:00:00.000Z",'
        '"schemaVersion":1,"futureKey":{"from":"a newer build"},"loomType":"RigidHeddle"}';

    Map<String, dynamic> sidecarJson(String id) =>
        jsonDecode(f('$id.json').readAsStringSync()) as Map<String, dynamic>;

    test('a save merges into the existing sidecar instead of rebuilding it', () async {
      f('k1.plyknit').writeAsStringSync(_current);
      f('k1.json').writeAsStringSync(rich);
      await repo.saveKnit(pattern: _pattern, meta: meta('New name'), id: 'k1');
      final j = sidecarJson('k1');
      expect(j['name'], 'New name');
      expect(j['author'], 'Ada');
      expect(j['notes'], 'gift for M');
      expect(j['savedAt'], '2020-01-01T00:00:00.000Z', reason: 'first-save date kept');
      expect(DateTime.parse(j['lastOpened'] as String).isAfter(DateTime.utc(2021)), isTrue);
      expect(j['futureKey'], {'from': 'a newer build'});
      expect(j['loomType'], 'RigidHeddle', reason: 'a value this build cannot read is kept');
    });

    test('opening and renaming keep keys this build does not know', () async {
      f('k1.plyknit').writeAsStringSync(_current);
      f('k1.json').writeAsStringSync(rich);
      await repo.readPattern('k1');
      final entry = await repo.openKnit('k1');
      expect(entry.meta.lastOpened.isAfter(DateTime.utc(2021)), isTrue);
      await repo.renameKnit('k1', 'Renamed');
      final j = sidecarJson('k1');
      expect(j['name'], 'Renamed');
      expect(j['futureKey'], {'from': 'a newer build'});
      expect(j['loomType'], 'RigidHeddle');
      expect(j['author'], 'Ada');
      expect(f('k1.plyknit').readAsStringSync(), _current, reason: 'opening never writes the file');
    });
  });
}
