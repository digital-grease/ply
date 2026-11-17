import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:ply/src/data/tablet_repository.dart';
import 'package:ply/src/models/draft_meta.dart';
import 'package:ply/src/models/native_format.dart';
import 'package:ply/src/models/tablet_band.dart';
import 'package:ply/src/rust/tablet_dto.dart';

import 'tablet_test_support.dart';

// The tablet library's persistence over a temp dir (no FFI, no path_provider): a save writes
// `<id>.plytab` then `<id>.json` (atomically, sidecar last), the document takes the sidecar's name,
// a newer or unreadable file on disk is never replaced, an older one is kept once as
// `<id>.plytab.v<n>.bak` before the upgrade, the sidecar is merged (keys this build does not know,
// such as materials links, survive), and delete removes every file of the band. The engine writer is
// stood in for by the real fixture bytes (its own output is covered by the Rust tests).

class DiskOnlyTabletRepo extends TabletRepository {
  DiskOnlyTabletRepo({this.writes = 1});

  /// The schema version of what the stand-in writer writes.
  final int writes;
  final List<TabletDocumentDto> written = [];

  @override
  Future<String> write(TabletDocumentDto doc) async {
    written.add(doc);
    final env = jsonDecode(fixtureText('documents/band-1-threaded-in.plytab')) as Map;
    env['schema_version'] = writes;
    (env['document'] as Map)['name'] = doc.name;
    return const JsonEncoder.withIndent('  ').convert(env);
  }

  @override
  Future<TabletDocumentDto> parse(String text) async => documentFromPlytab(text);

  @override
  Future<int> schemaVersion() async => writes;

  /// The engine's envelope reader, stood in for on these small files.
  int versionReads = 0;
  int? Function(String text)? versionOverride;
  @override
  Future<int?> documentVersion(String text) async {
    versionReads++;
    return (versionOverride ?? plytabSchemaVersion)(text);
  }

  /// No native lib on the host: the thumbnail is best-effort and skipped.
  @override
  Future<TabletRasterDto> renderFace(TabletDocumentDto doc, int first, int last,
          {required TabletFaceKind face,
          required int cellPx,
          bool letters = false,
          TabletCheckpointDto? checkpoint}) =>
      Future.error(StateError('no FFI in host tests'));

  @override
  Future<ui.Image> decode(TabletRasterDto r) => Future.error(StateError('no FFI'));
}

void main() {
  late Directory dir;
  late DiskOnlyTabletRepo repo;
  final doc = oracleDocument('band-1-threaded-in');
  DraftMeta meta(String name) => DraftMeta(
        name: name,
        craft: kTabletCraft,
        savedAt: DateTime.utc(2026, 11, 16),
        lastOpened: DateTime.utc(2026, 11, 16, 12),
      );

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ply_tablets_');
    repo = DiskOnlyTabletRepo()..dirOverride = dir;
  });
  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  File file(String name) => File(p.join(dir.path, name));

  test('a save writes the band and its sidecar, and the band lists and reads back', () async {
    final id = await repo.saveBand(doc: doc, meta: meta('Diagonals'));
    expect(file('$id.plytab').existsSync(), isTrue);
    final sidecar = jsonDecode(file('$id.json').readAsStringSync()) as Map<String, dynamic>;
    expect(sidecar['name'], 'Diagonals');
    expect(sidecar['craft'], 'TabletWeaving');
    // The document carries the sidecar's name.
    expect(repo.written.single.name, 'Diagonals');
    expect(plytabSchemaVersion(file('$id.plytab').readAsStringSync()), 1);
    // No temp file is left behind, and no thumbnail without the engine.
    expect(dir.listSync().map((e) => p.basename(e.path)).toSet(), {'$id.plytab', '$id.json'});
    final list = await repo.listBands();
    expect(list.single.id, id);
    expect(list.single.meta.name, 'Diagonals');
    expect(list.single.thumbPath, isNull);
    final back = await repo.readBand(id);
    expect(back.cards.length, 8);
    expect(back.name, 'Diagonals');
  });

  test('the list skips a sidecar without its band and one that cannot be read', () async {
    final id = await repo.saveBand(doc: doc, meta: meta('Kept'));
    file('orphan.json').writeAsStringSync(jsonEncode(meta('Orphan').toJson()));
    file('broken.plytab').writeAsStringSync(fixtureText('documents/band-1-threaded-in.plytab'));
    file('broken.json').writeAsStringSync('{not json');
    expect([for (final e in await repo.listBands()) e.id], [id]);
  });

  test('a newer or unreadable band on disk is never replaced', () async {
    final id = await repo.saveBand(doc: doc, meta: meta('Mine'));
    final newer = fixtureText('documents/invalid/newer-version.plytab');
    file('$id.plytab').writeAsStringSync(newer);
    await expectLater(
      repo.saveBand(doc: doc, meta: meta('Mine'), id: id),
      throwsA(isA<NativeFormatException>()
          .having((e) => e.problem, 'problem', NativeFormatProblem.newerVersion)
          .having((e) => e.whileSaving, 'whileSaving', isTrue)
          .having((e) => e.document, 'document', NativeDocument.tabletBand)),
    );
    expect(file('$id.plytab').readAsStringSync(), newer);
    file('$id.plytab').writeAsStringSync('not a band');
    await expectLater(
      repo.saveBand(doc: doc, meta: meta('Mine'), id: id),
      throwsA(isA<NativeFormatException>()
          .having((e) => e.problem, 'problem', NativeFormatProblem.unreadable)),
    );
    expect(file('$id.plytab').readAsStringSync(), 'not a band');
  });

  test('the guard reads the file\'s version through the engine\'s envelope reader', () async {
    final id = await repo.saveBand(doc: doc, meta: meta('Mine'));
    expect(repo.versionReads, 0, reason: 'nothing on disk to guard the first time');
    // The file says version 1; the reader says 9: the save is refused as over a newer file.
    repo.versionOverride = (_) => 9;
    await expectLater(
      repo.saveBand(doc: doc, meta: meta('Mine'), id: id),
      throwsA(isA<NativeFormatException>()
          .having((e) => e.problem, 'problem', NativeFormatProblem.newerVersion)),
    );
    expect(repo.versionReads, 1);
  });

  test('the Dart version probe decodes small texts only', () {
    final small = fixtureText('documents/band-1-threaded-in.plytab');
    expect(plytabSchemaVersion(small), 1);
    // Past a megabyte it never decodes: a large file's version comes from the engine.
    final large = small.replaceFirst('"notes": "', '"notes": "${'x' * kPlytabProbeMaxBytes}');
    expect(plytabSchemaVersion(large), isNull);
  });

  test('a later format version keeps the original once before upgrading it', () async {
    final id = await repo.saveBand(doc: doc, meta: meta('Old'));
    final original = file('$id.plytab').readAsStringSync();
    final later = DiskOnlyTabletRepo(writes: 2)..dirOverride = dir;
    await later.saveBand(doc: doc, meta: meta('Old'), id: id);
    final backup = file('$id.plytab.v1.bak');
    expect(backup.readAsStringSync(), original);
    expect(plytabSchemaVersion(file('$id.plytab').readAsStringSync()), 2);
    // A second save at the new version keeps the first backup as it was.
    await later.saveBand(doc: doc, meta: meta('Old'), id: id);
    expect(backup.readAsStringSync(), original);
  });

  test('the sidecar is merged: keys this build does not know survive a save', () async {
    final id = await repo.saveBand(doc: doc, meta: meta('Linked'));
    final sidecar = jsonDecode(file('$id.json').readAsStringSync()) as Map<String, dynamic>;
    sidecar['materials'] = {
      'yarns': [
        {'material': 'grey-wool'}
      ]
    };
    file('$id.json').writeAsStringSync(jsonEncode(sidecar));
    await repo.saveBand(doc: doc, meta: meta('Linked again'), id: id);
    final after = jsonDecode(file('$id.json').readAsStringSync()) as Map<String, dynamic>;
    expect(after['materials'], sidecar['materials']);
    expect(after['name'], 'Linked again');
    expect(after['savedAt'], sidecar['savedAt']);
  });

  test('a band that can no longer be drawn loses its old thumbnail', () async {
    final id = await repo.saveBand(doc: doc, meta: meta('Drawn once'));
    file('$id.png').writeAsBytesSync([1, 2, 3]); // as an earlier save drew it
    // This save cannot draw it (here: no engine; on a device: the band now has errors).
    await repo.saveBand(doc: doc, meta: meta('Drawn once'), id: id);
    expect(file('$id.png').existsSync(), isFalse);
  });

  test('an empty band has nothing to draw: no thumbnail, and no failure', () async {
    final id = await repo.saveBand(doc: doc, meta: meta('Drawn'));
    expect(await repo.hasSomethingToDraw(id), isTrue);
    // The same band with no picks (as a file the library lists).
    final empty = copyDoc(doc, turning: const []);
    final emptyRepo = _ReadsBack(empty)..dirOverride = dir;
    file('$id.png').writeAsBytesSync([1, 2, 3]);
    await emptyRepo.rebuildThumbnail(id); // no throw: nothing to draw is not a failure
    expect(file('$id.png').existsSync(), isFalse);
    expect(await emptyRepo.hasSomethingToDraw(id), isFalse);
    // A band whose file is gone cannot be read: unknown.
    expect(await repo.hasSomethingToDraw('missing'), isNull);
    // A band with picks that cannot be drawn (here: no engine) throws, for the library to say so.
    await expectLater(repo.rebuildThumbnail(id), throwsA(anything));
  });

  test('rename changes the sidecar; delete removes every file of the band', () async {
    final id = await repo.saveBand(doc: doc, meta: meta('Before'));
    await repo.renameBand(id, 'After');
    expect((await repo.listBands()).single.meta.name, 'After');
    final opened = await repo.openBand(id);
    expect(opened.meta.name, 'After');
    file('$id.png').writeAsBytesSync([1, 2, 3]);
    file('$id.plytab.v1.bak').writeAsStringSync('old');
    file('$id.plytab.tmp').writeAsStringSync('partial');
    await repo.deleteBand(id);
    expect(dir.listSync(), isEmpty);
    await repo.deleteBand(id); // already gone: tolerated
  });

  test('an upgrade backup whose band is gone is swept on the first list', () async {
    file('gone.plytab.v1.bak').writeAsStringSync('old');
    final id = await repo.saveBand(doc: doc, meta: meta('Here'));
    file('$id.plytab.v1.bak').writeAsStringSync('mine');
    await repo.listBands();
    expect(file('gone.plytab.v1.bak').existsSync(), isFalse);
    expect(file('$id.plytab.v1.bak').existsSync(), isTrue);
  });

  test('a format failure from the engine becomes the app\'s format exception', () {
    final e = nativeFormatExceptionFromTablet(const TabletFormatFailure(
        kind: TabletFormatFailureKind.newerVersion, message: 'schema version 2'));
    expect(e.problem, NativeFormatProblem.newerVersion);
    expect(e.message, 'This band was saved by a newer version of Ply. Update the app to open it.');
    final w = nativeFormatExceptionFromTablet(
        const TabletFormatFailure(kind: TabletFormatFailureKind.wrongFormat, message: 'ply.knit'));
    expect(w.message, 'This file is not a Ply tablet weaving band.');
  });
}

/// Reads every band as [doc] (no FFI).
class _ReadsBack extends DiskOnlyTabletRepo {
  _ReadsBack(this.doc);
  final TabletDocumentDto doc;

  @override
  Future<TabletDocumentDto> readBand(String id) async => doc;
}
