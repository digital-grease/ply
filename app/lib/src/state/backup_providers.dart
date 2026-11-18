import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/backup_file_access.dart';
import '../data/knit_repository.dart';
import '../data/library_backup.dart';
import '../data/materials_repository.dart' show MaterialLibrary;
import '../diagnostics/crash_reporter.dart' show kPlyAppVersion;
import 'editor_providers.dart';
import 'knit_editor_providers.dart';
import 'loom_providers.dart';
import 'material_providers.dart';
import 'nalbind_providers.dart' show nalbindRepositoryProvider;
import 'tablet_editor_providers.dart' show tabletRepositoryProvider;
import 'theme_providers.dart';

/// The system save dialog and file picker for backups. Tests override it.
final backupFileAccessProvider =
    Provider<BackupFileAccess>((_) => const PickerBackupFileAccess());

/// The library backup service, wired to the app documents directory and the engine: the current
/// `.plyknit` version is the one the engine writes (so a knit format bump needs no change here),
/// WIF and knit files are also parsed by the engine before a restore, and restored projects get
/// their thumbnails rebuilt. A full backup offers the app settings in effect; restored settings go
/// through the settings notifier (saved first, then applied). A full backup carries My looms
/// (`looms.json`, read by the engine), and a restore adds a backup's looms in one write that a later
/// failure undoes (ADR 0014), and the materials and swatches likewise (`materials.json` with the
/// swatches' photos; ADR 0016). Knitting patterns, nalbinding projects and tablet weaving bands are
/// checked alike: the version each file states, read by the engine from its version keys alone,
/// against the newest this build reads; for a pattern or project, the engine's count of its JSON
/// values (a guard against files crafted to blow up when decoded); then the full read (the engine's
/// parser, which sends nothing back for a pattern; for a nalbinding project, the app's own reader
/// on a background isolate). Tests override it with a service over a temp directory.
final libraryBackupProvider = Provider<LibraryBackup>((ref) {
  final drafts = ref.watch(repositoryProvider);
  final knits = ref.watch(knitRepositoryProvider);
  final nalbinds = ref.watch(nalbindRepositoryProvider);
  final tablets = ref.watch(tabletRepositoryProvider);
  final looms = ref.watch(loomRepositoryProvider);
  final materials = ref.watch(materialsRepositoryProvider);
  return LibraryBackup(
    documentsDir: getApplicationDocumentsDirectory,
    currentKnitSchemaVersion: knits.schemaVersion,
    currentTabletSchemaVersion: tablets.schemaVersion,
    appVersion: kPlyAppVersion,
    limits: BackupLimits.forThisDevice(),
    checks: NativeFileChecks(
      wif: (text) async => drafts.parseDoc(text),
      knit: knits.check,
      knitVersion: knits.documentVersion,
      knitGuard: knits.withinValueLimit,
      nalbindVersion: nalbinds.documentVersion,
      nalbindGuard: nalbinds.withinValueLimit,
      tablet: (text) async => tablets.parse(text),
      tabletVersion: tablets.documentVersion,
    ),
    rebuildThumbnail: (craft, id) async {
      switch (craft) {
        case BackupCraft.weaving:
          await drafts.rebuildThumbnail(id);
        case BackupCraft.knitting:
          final docs = await getApplicationDocumentsDirectory();
          await rebuildKnitThumbnail(knits, id,
              knitsDir: Directory(p.join(docs.path, BackupCraft.knitting.directory)));
        case BackupCraft.nalbinding:
          break; // no thumbnails
        case BackupCraft.tabletWeaving:
          await tablets.rebuildThumbnail(id);
      }
    },
    currentSettings: () async => ref.read(appSettingsProvider),
    applySettings: (settings) => ref.read(appSettingsProvider.notifier).restore(settings),
    looms: LoomBackupHooks(
      currentFile: looms.currentBytes,
      decode: looms.decodeBytes,
      currentLooms: () async {
        final bytes = await looms.currentBytes();
        return bytes == null ? const [] : await looms.decodeBytes(bytes);
      },
      add: looms.addLooms,
    ),
    materials: MaterialBackupHooks(
      currentFile: materials.currentBytes,
      decode: materials.decodeBytes,
      current: () async {
        final bytes = await materials.currentBytes();
        return bytes == null ? MaterialLibrary.empty : await materials.decodeBytes(bytes);
      },
      add: materials.addRecords,
      fits: materials.fits,
    ),
  );
});

/// Bumped after a restore so the home screen rebuilds the library tabs (each reloads its list).
final libraryRevisionProvider = StateProvider<int>((_) => 0);

/// Rebuild the thumbnail `<knitsDir>/<id>.png` of a saved knitting pattern from its `.plyknit`, the
/// way a save writes it (atomically, at [KnitRepository.thumbnailCellPx]). Throws when the pattern
/// cannot be read or drawn; the caller treats the thumbnail as best-effort.
Future<void> rebuildKnitThumbnail(KnitRepository repo, String id,
    {required Directory knitsDir}) async {
  final pattern = await repo.readPattern(id);
  final image = await repo.render(pattern, cellPx: KnitRepository.thumbnailCellPx);
  try {
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    if (png == null) return;
    final target = File(p.join(knitsDir.path, '$id.png'));
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsBytes(png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
        flush: true);
    await tmp.rename(target.path);
  } finally {
    image.dispose();
  }
}
