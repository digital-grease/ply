// M7-07 follow-ups on a device (ADR 0007, amendment of 2026-11-18): a backup made and restored with
// the real engine checks, over temp directories (the app's own library is never touched).
//
// - A nalbinding project whose sidecar still holds an earlier build's copy of its notes, over the
//   sidecar's 1 MB limit, is backed up without that copy and restores with its notes intact.
// - A current-version knitting pattern is checked by the engine in its own types: one carrying three
//   million values under a key Ply does not know is checked and restored without decoding them.
// - A manifest stuffed with a million empty objects is refused before it is decoded.
//
//   flutter test integration_test/m7_backup_limits_test.dart -d emulator-5554

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

import 'package:ply/src/data/json_count.dart';
import 'package:ply/src/data/knit_repository.dart';
import 'package:ply/src/data/library_backup.dart';
import 'package:ply/src/data/nalbind_repository.dart';
import 'package:ply/src/data/ustar.dart';
import 'package:ply/src/diagnostics/crash_reporter.dart' show kPlyAppVersion;
import 'package:ply/src/models/nalbind_project.dart';
import 'package:ply/src/rust/frb_generated.dart';

/// A backup service over [docs], with the engine's version probes, value guards and pattern check,
/// as production wires them.
LibraryBackup _service(Directory docs, KnitRepository knits, NalbindRepository nalbinds) =>
    LibraryBackup(
      documentsDir: () async => docs,
      currentKnitSchemaVersion: knits.schemaVersion,
      appVersion: kPlyAppVersion,
      limits: BackupLimits.forThisDevice(),
      checks: NativeFileChecks(
        knit: knits.check,
        knitVersion: knits.documentVersion,
        knitGuard: knits.withinValueLimit,
        nalbindVersion: nalbinds.documentVersion,
        nalbindGuard: nalbinds.withinValueLimit,
      ),
    );

Future<void> _put(Directory root, String rel, List<int> bytes) async {
  final f = File(p.joinAll([root.path, ...rel.split('/')]));
  await f.parent.create(recursive: true);
  await f.writeAsBytes(bytes);
}

String _sidecar(String name, String craft, {String notes = ''}) => jsonEncode({
      'name': name,
      'craft': craft,
      'notes': notes,
      'savedAt': '2026-11-18T00:00:00.000Z',
      'lastOpened': '2026-11-18T00:00:00.000Z',
      'schemaVersion': 1,
    });

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  late Directory source;
  late Directory target;
  late Directory work;
  setUp(() async {
    source = await Directory.systemTemp.createTemp('m7_backup_source');
    target = await Directory.systemTemp.createTemp('m7_backup_target');
    work = await Directory.systemTemp.createTemp('m7_backup_work');
  });
  tearDown(() async {
    for (final d in [source, target, work]) {
      if (await d.exists()) await d.delete(recursive: true);
    }
  });

  Future<File> backUp(LibraryBackup s) async {
    final plan = await s.planBackup();
    final f = File(p.join(work.path, plan.fileName));
    await f.writeAsBytes(await s.buildBackup(plan));
    return f;
  }

  testWidgets('an earlier build\'s copy of long nalbinding notes no longer blocks a backup',
      (tester) async {
    final knits = KnitRepository();
    final notes = 'Round ${'and round ' * 120000}';
    expect(notes.length, greaterThan(1024 * 1024));
    final sourceRepo = NalbindRepository()
      ..dirOverride = Directory(p.join(source.path, 'nalbinds'));
    final id = await sourceRepo
        .saveProject(NalbindProject(name: 'Long notes', notation: 'UO/UOO F1', notes: notes));
    // As an earlier build left it: the notes copied into the sidecar too.
    final sidecarFile = File(p.join(source.path, 'nalbinds', '$id.json'));
    final sidecar = jsonDecode(await sidecarFile.readAsString()) as Map<String, dynamic>;
    await sidecarFile.writeAsString(jsonEncode({...sidecar, 'notes': notes}));
    expect(await sidecarFile.length(), greaterThan(1024 * 1024));

    final archive = await backUp(_service(source, knits, sourceRepo));
    final targetRepo = NalbindRepository()
      ..dirOverride = Directory(p.join(target.path, 'nalbinds'));
    final restoring = _service(target, knits, targetRepo);
    final plan = await restoring.inspectBackup(archive);
    expect(plan.projects.single.status, RestoreStatus.add);
    await restoring.restore(plan);

    expect((await targetRepo.readProject(id)).notes, notes);
    final restoredSidecar =
        jsonDecode(await File(p.join(target.path, 'nalbinds', '$id.json')).readAsString()) as Map;
    expect(restoredSidecar['notes'], '');
    expect((await targetRepo.listProjects()).single.name, 'Long notes');
    // The same backup on the library it came from: already there.
    final again = await _service(source, knits, sourceRepo).inspectBackup(archive);
    expect(again.projects.single.status, RestoreStatus.alreadyPresent);
  });

  testWidgets('a current pattern is checked in its own types, however many values it skips',
      (tester) async {
    final knits = KnitRepository();
    final nalbinds = NalbindRepository();
    final written = await knits.write(await knits.blank());
    expect(await knits.documentVersion(written), await knits.schemaVersion());
    // Three million values (just within the engine's limit) under a key the pattern does not have:
    // objects of one member nested in each other, which took about 900 MB as a generic tree.
    const limit = 3000000;
    final nested = '${'{"a":' * 100}0${'}' * 100}';
    // The envelope without its closing brace, then the document without its own.
    final envelope = written.substring(0, written.lastIndexOf('}'));
    final document = envelope.substring(0, envelope.lastIndexOf('}'));
    final base = countJsonValues(utf8.encode(written));
    final perItem = countJsonValues(utf8.encode(nested));
    final n = (limit - base - 2) ~/ perItem; // the key and the list are two more
    final stuffed = '$document,"later":[${List.filled(n, nested).join(',')}]}}';
    expect(countJsonValues(utf8.encode(stuffed)), lessThanOrEqualTo(limit));
    expect(await knits.withinValueLimit(stuffed), isTrue);

    await _put(source, 'knits/k1.plyknit', utf8.encode(written));
    await _put(source, 'knits/k1.json', utf8.encode(_sidecar('Plain', 'Knitting')));
    await _put(source, 'knits/k2.plyknit', utf8.encode(stuffed));
    await _put(source, 'knits/k2.json', utf8.encode(_sidecar('Stuffed', 'Knitting')));
    final archive = await backUp(_service(source, knits, nalbinds));

    final restoring = _service(target, knits, nalbinds);
    final rssBefore = ProcessInfo.maxRss;
    final plan = await restoring.inspectBackup(archive);
    final rssGrowth = ProcessInfo.maxRss - rssBefore;
    expect({for (final project in plan.projects) project.id: project.status},
        {'k1': RestoreStatus.add, 'k2': RestoreStatus.add});
    expect(rssGrowth, lessThan(300 * 1024 * 1024),
        reason: 'the skipped values are never built (they took about 900 MB as a tree)');
    await restoring.restore(plan);
    final restored = await File(p.join(target.path, 'knits', 'k2.plyknit')).readAsString();
    expect(restored, stuffed, reason: 'restored byte for byte');
    await knits.check(restored);
  });

  testWidgets('a manifest stuffed with empty objects is refused before it is decoded',
      (tester) async {
    final manifest = utf8.encode('{"padding":[${List.filled(1300000, '{}').join(',')}],'
        '"format":"ply.backup","schema_version":1,"created_at":"2026-11-18T00:00:00.000Z",'
        '"app_version":"x","files":[]}');
    expect(manifest.length, lessThan(4 * 1024 * 1024));
    final archive = BytesBuilder()
      ..add(UstarHeader.file(backupManifestPath, manifest.length).encode())
      ..add(manifest)
      ..add(Uint8List(ustarPadding(manifest.length)))
      ..add(Uint8List(ustarEndLength));
    final f = File(p.join(work.path, 'stuffed.plybackup'));
    await f.writeAsBytes(archive.takeBytes());
    await expectLater(
        _service(target, KnitRepository(), NalbindRepository()).inspectBackup(f),
        throwsA(
            isA<BackupException>().having((e) => e.problem, 'problem', BackupProblem.notABackup)));
  });
}
