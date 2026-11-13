import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/backup_file_access.dart';
import '../data/knit_repository.dart';
import '../data/library_backup.dart';
import '../diagnostics/crash_reporter.dart' show kPlyAppVersion;
import '../models/native_format.dart';
import 'editor_providers.dart';
import 'knit_editor_providers.dart';
import 'theme_providers.dart';

/// The system save dialog and file picker for backups. Tests override it.
final backupFileAccessProvider =
    Provider<BackupFileAccess>((_) => const PickerBackupFileAccess());

/// The library backup service, wired to the app documents directory and the engine: the current
/// `.plyknit` version comes from what the engine writes (so a knit format bump needs no change
/// here), WIF and knit files are also parsed by the engine before a restore, and restored projects
/// get their thumbnails rebuilt. A full backup offers the app settings in effect; restored settings
/// go through the settings notifier (saved first, then applied). Tests override it with a service
/// over a temp directory.
final libraryBackupProvider = Provider<LibraryBackup>((ref) {
  final drafts = ref.watch(repositoryProvider);
  final knits = ref.watch(knitRepositoryProvider);
  return LibraryBackup(
    documentsDir: getApplicationDocumentsDirectory,
    currentKnitSchemaVersion: () async {
      final version = plyknitSchemaVersion(await knits.write(await knits.blank()));
      if (version == null) throw StateError('the engine wrote an unrecognized .plyknit');
      return version;
    },
    appVersion: kPlyAppVersion,
    limits: BackupLimits.forThisDevice(),
    checks: NativeFileChecks(
      wif: (text) async => drafts.parseDoc(text),
      knit: (text) async => knits.parse(text),
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
      }
    },
    currentSettings: () async => ref.read(appSettingsProvider),
    applySettings: (settings) => ref.read(appSettingsProvider.notifier).restore(settings),
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
