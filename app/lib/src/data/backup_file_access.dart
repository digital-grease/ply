import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import 'library_backup.dart';

/// How a backup leaves the app and comes back: the system save dialog and file picker, fully
/// offline. Screens use this through `backupFileAccessProvider`, so tests can replace it.
abstract class BackupFileAccess {
  /// Let the user save [bytes] as [fileName] where they choose. False when they cancelled.
  Future<bool> save(String fileName, Uint8List bytes);

  /// Let the user pick a backup file. Null when they cancelled.
  Future<File?> pick();

  /// Remove the temporary copy the picker may have made of a picked file (best-effort).
  Future<void> discardPicked();
}

/// [BackupFileAccess] over `file_picker`.
///
/// - Android and iOS: `saveFile` takes the bytes and the system dialog (Android's document creator,
///   iOS's export picker) writes them where the user chooses. `pickFiles` copies the picked file into
///   the app's cache and returns that path; [discardPicked] clears the copy.
/// - Desktop (Linux, macOS, Windows): `saveFile` only returns the chosen path (macOS refuses bytes,
///   Linux and Windows ignore them), so the file is written here. A picked file is the original.
class PickerBackupFileAccess implements BackupFileAccess {
  const PickerBackupFileAccess();

  static bool get _mobile => Platform.isAndroid || Platform.isIOS;

  @override
  Future<bool> save(String fileName, Uint8List bytes) async {
    if (_mobile) {
      final saved = await FilePicker.platform.saveFile(fileName: fileName, bytes: bytes);
      return saved != null;
    }
    final path = await FilePicker.platform.saveFile(dialogTitle: 'Save backup', fileName: fileName);
    if (path == null) return false;
    await File(path).writeAsBytes(bytes, flush: true);
    return true;
  }

  @override
  Future<File?> pick() async {
    // A `.plybackup` has no MIME type, so an extension filter would fail on Android: pick any file
    // and let the restore decide from its content.
    final result = await FilePicker.platform.pickFiles(type: FileType.any, allowMultiple: false);
    if (result == null || result.files.isEmpty) return null;
    final path = result.files.single.path;
    if (path == null) {
      throw const BackupException(BackupProblem.unreadable, detail: 'the picker gave no path');
    }
    return File(path);
  }

  @override
  Future<void> discardPicked() async {
    if (!_mobile) return;
    try {
      await FilePicker.platform.clearTemporaryFiles();
    } catch (_) {/* best-effort: the cache is app-private and the OS clears it too */}
  }
}
