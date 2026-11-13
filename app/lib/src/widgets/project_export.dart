import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/library_backup.dart';
import '../diagnostics/log_buffer.dart';
import '../state/backup_providers.dart';
import 'progress_dialog.dart';

/// Export one project ([id] of [craft], shown as [name]) to a `.plybackup` file through the system
/// save dialog: the backup format and limits, holding just this project (see
/// [LibraryBackup.planProjectBackup]). Importing it needs nothing else: "Restore from backup" in
/// Settings adds it like any backup, as a copy when the library has a different version. The
/// outcome is a snackbar; cancelling the save dialog says nothing.
Future<void> exportProject(
  BuildContext context,
  WidgetRef ref, {
  required BackupCraft craft,
  required String id,
  required String name,
}) async {
  // Everything that needs the widget is read before the first gap.
  final backup = ref.read(libraryBackupProvider);
  final files = ref.read(backupFileAccessProvider);
  final messenger = ScaffoldMessenger.of(context);
  void snack(String message) => messenger.showSnackBar(SnackBar(content: Text(message)));
  try {
    final (fileName, bytes) = await showProgressWhile(context, 'Exporting...', () async {
      final plan = await backup.planProjectBackup(craft, id);
      return (plan.fileName, await backup.buildBackup(plan));
    });
    if (await files.save(fileName, bytes)) snack('Exported "$name".');
  } on BackupException catch (e) {
    PlyLog.instance.warn('Export refused: $e');
    snack(e.message);
  } catch (e) {
    PlyLog.instance.error('Export failed: $e');
    snack('Could not save the export.');
  }
}
