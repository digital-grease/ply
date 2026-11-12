import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:ply/src/data/library_backup.dart';
import 'package:ply/src/data/ustar.dart';
import 'package:ply/src/models/nalbind_project.dart';
import 'package:ply/src/models/native_format.dart';

// Shared helpers for the library backup tests: a seeded library over a temp directory, a backup
// service wired to it without FFI or path_provider, and byte-level snapshots of a directory.

/// The `.plyknit` version the stand-in engine writes in these tests. A test parameter only: the real
/// build asks the engine.
const int knitVersion = 2;

late Directory docs;
late Directory work;

LibraryBackup service({
  Directory? into,
  BackupLimits limits = const BackupLimits(),
  NativeFileChecks checks = const NativeFileChecks(),
  Future<void> Function(String target)? beforePlace,
  List<(BackupCraft, String)>? thumbnails,
}) =>
    LibraryBackup(
      documentsDir: () async => into ?? docs,
      currentKnitSchemaVersion: () async => knitVersion,
      appVersion: '9.9.9-test',
      limits: limits,
      checks: checks,
      rebuildThumbnail: (craft, id) async => thumbnails?.add((craft, id)),
      clock: () => DateTime.utc(2026, 11, 12, 10, 30),
      beforePlace: beforePlace,
    );

Future<void> put(Directory root, String rel, List<int> bytes) async {
  final f = File(p.joinAll([root.path, ...rel.split('/')]));
  await f.parent.create(recursive: true);
  await f.writeAsBytes(bytes);
}

List<int> sidecar(String name, String craft, {Map<String, Object?> extra = const {}}) =>
    utf8.encode(jsonEncode({
      'name': name,
      'craft': craft,
      'notes': '',
      'savedAt': '2026-01-01T00:00:00.000Z',
      'lastOpened': '2026-01-02T00:00:00.000Z',
      'schemaVersion': 1,
      ...extra,
    }));

final List<int> wifBytes = utf8.encode('[WEAVING]\nShafts=2\nTreadles=2\n[THREADING]\n1=1\n');
List<int> knitFile({int version = knitVersion, String name = 'k'}) => utf8.encode(jsonEncode(
    {'format': kPlyknitFormat, 'schema_version': version, 'document': {'name': name}}));
final List<int> legacyKnit = utf8.encode(jsonEncode({'name': 'old', 'legend': []}));
List<int> nalFile(String name) =>
    utf8.encode(jsonEncode(NalbindProject(name: name, notation: 'UO/UOO', notes: 'n').toJson()));
final Uint8List photo1 = _randomBytes(5000);
Uint8List _randomBytes(int n) {
  final rng = Random(1);
  return Uint8List.fromList(List.generate(n, (_) => rng.nextInt(256)));
}
final Uint8List photo2 = Uint8List.fromList(List.generate(256, (i) => 255 - i));

/// A library of every craft, with the things a backup must leave out (thumbnails, temp files,
/// incomplete projects, app settings).
Future<void> seedLibrary(Directory root) async {
  await put(root, 'drafts/d1.wif', wifBytes);
  await put(root, 'drafts/d1.json',
      sidecar('Twill', 'Weaving', extra: {'futureKey': {'kept': true}}));
  await put(root, 'drafts/d1.png', [1, 2, 3]);
  await put(root, 'drafts/d2.wif', utf8.encode('[WEAVING]\nShafts=4\n'));
  await put(root, 'drafts/d2.json', sidecar('Plain', 'Weaving'));
  await put(root, 'knits/k1.plyknit', knitFile(name: 'Hat'));
  await put(root, 'knits/k1.plyknit.v1.bak', legacyKnit);
  await put(root, 'knits/k1.json', sidecar('Hat', 'Knitting'));
  await put(root, 'knits/k1.png', [4, 5, 6]);
  await put(root, 'nalbinds/n1.plynal', nalFile('Mitten'));
  await put(root, 'nalbinds/n1.json', sidecar('Mitten', 'Nalbinding'));
  await put(root, 'nalbinds/n1.photos/aaa.jpg', photo1);
  await put(root, 'nalbinds/n1.photos/bbb.png', photo2);
  // Left out of every backup:
  await put(root, 'nalbinds/n1.photos/ccc.jpg.tmp', [0]);
  await put(root, 'drafts/orphan.wif', wifBytes); // no sidecar: not listed by the library
  await put(root, 'drafts/lonely.json', sidecar('Lonely', 'Weaving')); // no .wif
  await put(root, 'drafts/d1.json.tmp', [0]);
  await put(root, 'app_settings.json', utf8.encode('{}'));
}

/// Every file (bytes) and folder (empty marker, path ending in '/') under [root], by relative path.
Future<Map<String, List<int>>> snapshot(Directory root) async {
  final out = SplayTreeMap<String, List<int>>();
  if (!await root.exists()) return out;
  await for (final ent in root.list(recursive: true, followLinks: false)) {
    final rel = p.relative(ent.path, from: root.path).replaceAll(r'\', '/');
    if (ent is File) out[rel] = await ent.readAsBytes();
    if (ent is Directory) out['$rel/'] = const [];
  }
  return out;
}

Future<File> backUp(LibraryBackup s, {String name = 'library.plybackup'}) async {
  final plan = await s.planBackup();
  final f = File(p.join(work.path, name));
  await f.writeAsBytes(await s.buildBackup(plan));
  return f;
}

/// Every entry of an archive file, in order.
Future<List<(String, Uint8List)>> entriesOf(File f) async {
  final bytes = await f.readAsBytes();
  final raf = await f.open();
  try {
    final reader = UstarReader(raf, bytes.length);
    final out = <(String, Uint8List)>[];
    for (var e = await reader.next(); e != null; e = await reader.next()) {
      out.add((e.path, Uint8List.sublistView(bytes, e.dataOffset, e.dataOffset + e.size)));
    }
    return out;
  } finally {
    await raf.close();
  }
}

