import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:ply/src/data/backup_file_access.dart';
import 'package:ply/src/data/library_backup.dart';
import 'package:ply/src/data/ustar.dart';
import 'package:ply/src/models/app_settings.dart';
import 'package:ply/src/models/nalbind_project.dart';
import 'package:ply/src/models/native_format.dart';

// Shared helpers for the library backup tests: a seeded library over a temp directory, a backup
// service wired to it without FFI or path_provider, and byte-level snapshots of a directory.

/// The `.plyknit` version the stand-in engine writes in these tests. A test parameter only: the real
/// build asks the engine.
const int knitVersion = 2;

/// Stands in for the engine's envelope-only `.plytab` version reader in host tests (no FFI). The
/// fixture files are small, so reading them whole here is fine; the app never does this.
Future<int?> testTabletVersion(String text) async => plytabSchemaVersion(text);

/// Stands in for the engine's envelope-only `.plyknit` version reader, as [testTabletVersion] does.
Future<int?> testKnitVersion(String text) async => plyknitSchemaVersion(text);

/// Stands in for the engine's `.plynal` version reader, as [testTabletVersion] does: the rule of
/// `NalbindProject.schemaVersionOf` (no `format` key is legacy version 1), a newer version as found.
Future<int?> testNalbindVersion(String text) async {
  final Object? json;
  try {
    json = jsonDecode(text);
  } on FormatException {
    return null;
  }
  if (json is! Map<String, dynamic>) return null;
  if (!json.containsKey('format')) return 1;
  if (json['format'] != NalbindProject.formatId) return null;
  final version = json['schemaVersion'];
  return version is int && version >= 1 ? version : null;
}

/// Stands in for the engine's value guard in host tests: the files here are small.
Future<bool> testValueGuard(String text) async => true;

/// The checks a host-test backup service runs: the stand-in version readers and value guards, no
/// engine parsers.
const NativeFileChecks testChecks = NativeFileChecks(
  knitVersion: testKnitVersion,
  knitGuard: testValueGuard,
  nalbindVersion: testNalbindVersion,
  nalbindGuard: testValueGuard,
  tabletVersion: testTabletVersion,
);

late Directory docs;
late Directory work;

/// A backup service over [into] (default [docs]). [settings], when given, are the app settings in
/// effect that a full backup offers; [applySettings] receives restored settings (and may throw).
LibraryBackup service({
  Directory? into,
  BackupLimits limits = const BackupLimits(),
  NativeFileChecks checks = testChecks,
  Future<void> Function(String target)? beforePlace,
  List<(BackupCraft, String)>? thumbnails,
  AppSettings? settings,
  Future<void> Function(AppSettings settings)? applySettings,
}) =>
    LibraryBackup(
      documentsDir: () async => into ?? docs,
      currentKnitSchemaVersion: () async => knitVersion,
      appVersion: '9.9.9-test',
      limits: limits,
      checks: checks,
      rebuildThumbnail: (craft, id) async => thumbnails?.add((craft, id)),
      currentSettings: settings == null ? null : () async => settings,
      applySettings: applySettings,
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

Future<File> backUp(LibraryBackup s,
    {String name = 'library.plybackup', bool includeSettings = true}) async {
  final plan = await s.planBackup();
  final f = File(p.join(work.path, name));
  await f.writeAsBytes(await s.buildBackup(plan.withSettings(includeSettings)));
  return f;
}

/// A single-project export of [id] of [craft] from [s]'s library.
Future<File> exportOne(LibraryBackup s, BackupCraft craft, String id,
    {String name = 'project.plybackup'}) async {
  final plan = await s.planProjectBackup(craft, id);
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


/// A stand-in for the system save dialog and file picker.
class FakeFiles implements BackupFileAccess {
  final saved = <(String, Uint8List)>[];
  bool saveResult = true;
  Object? saveError;
  File? toPick;
  int discards = 0;

  @override
  Future<bool> save(String fileName, Uint8List bytes, {String dialogTitle = 'Save backup'}) async {
    if (saveError != null) throw saveError!;
    saved.add((fileName, bytes));
    return saveResult;
  }

  @override
  Future<File?> pick() async => toPick;

  @override
  Future<void> discardPicked() async => discards++;
}

/// A stand-in backup service for the UI: canned plans and results, and a record of what was asked.
class FakeBackup extends LibraryBackup {
  FakeBackup()
      : super(
          documentsDir: () async => Directory.systemTemp,
          currentKnitSchemaVersion: () async => knitVersion,
          appVersion: 'test',
        );

  BackupPlan? plan;
  Object? planError;
  BackupPlan? projectPlan;
  Object? projectPlanError;
  final Uint8List built = Uint8List.fromList([1, 2, 3]);
  RestorePlan? inspected;
  Object? inspectError;
  Object? restoreError;

  /// What the UI asked for.
  (BackupCraft, String)? projectAsked;
  BackupPlan? builtFrom;
  Set<String>? skipped;
  bool? restoredSettings;
  Set<String>? skippedLooms;
  Set<String>? skippedRecords;

  @override
  Future<BackupPlan> planBackup() async {
    if (planError != null) throw planError!;
    return plan!;
  }

  @override
  Future<BackupPlan> planProjectBackup(BackupCraft craft, String id) async {
    projectAsked = (craft, id);
    if (projectPlanError != null) throw projectPlanError!;
    return projectPlan!;
  }

  @override
  Future<Uint8List> buildBackup(BackupPlan plan) async {
    builtFrom = plan;
    return built;
  }

  @override
  Future<RestorePlan> inspectBackup(File archive) async {
    if (inspectError != null) throw inspectError!;
    return inspected!;
  }

  @override
  Future<RestoreResult> restore(RestorePlan plan,
      {Set<String> skippedConflicts = const {},
      bool restoreSettings = false,
      Set<String> skippedLoomConflicts = const {},
      Set<String> skippedMaterialConflicts = const {}}) async {
    skipped = skippedConflicts;
    restoredSettings = restoreSettings;
    skippedLooms = skippedLoomConflicts;
    skippedRecords = skippedMaterialConflicts;
    if (restoreError != null) throw restoreError!;
    return RestoreResult([
      for (final p in plan.projects)
        if (p.status == RestoreStatus.add ||
            (p.status == RestoreStatus.conflict && !skippedConflicts.contains(p.key)))
          (craft: p.craft, id: p.targetId!),
    ],
        settingsRestored: restoreSettings && plan.settings?.settings != null,
        loomsRestored: plan.looms?.selected(skippedLoomConflicts).length ?? 0,
        materialsRestored:
            plan.materials?.selected(skippedMaterialConflicts).materials.length ?? 0,
        swatchesRestored: plan.materials?.selected(skippedMaterialConflicts).swatches.length ?? 0);
  }
}
