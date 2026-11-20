// A project's progress record on the device (ADR 0023): `<documents>/<craft folder>/<id>.plyprogress`,
// next to the project's other files and apart from them. Nothing here reads or writes the pattern or
// its sidecar; a write only checks, under the sidecar's lock, that the project still exists.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/progress.dart';
import 'json_count.dart';
import 'library_backup.dart' show BackupCraft, backupProgressExtension, isBackupProjectId;
import 'sidecar_writes.dart';

/// What reading a project's progress found.
enum ProgressStatus {
  /// No record yet: the tracker starts at the first unit.
  none,

  /// Read: [ProgressLoad.progress] holds it.
  ok,

  /// Saved by a newer version of Ply: not read, never replaced.
  newer,

  /// Not readable (or past the file bound): not replaced; Start again moves it aside first.
  unreadable,

  /// The device could not read the file just now (a file system error): nothing is known about the
  /// record, so it is not shown, not replaced and never moved aside; reading it again may work.
  failed,
}

/// What a tracker knows about the record it saves over, checked where the save writes (one save at a
/// time per record), so it holds for every save in turn however quickly they follow each other.
class ProgressSaveGuard {
  ProgressSaveGuard({required this.expectNoRecord});

  /// The tracker found no record when it opened and has written none since: a record on the device
  /// now is one it never read (the device could not show it then, or another screen wrote it), and is
  /// never written over ([ProgressProblem.foundAgain]). Cleared by the first save that writes.
  bool expectNoRecord;
}

/// A read of a project's progress.
class ProgressLoad {
  const ProgressLoad(this.status, [this.progress]);

  final ProgressStatus status;
  final Progress? progress;
}

/// Reads and writes progress records. Writes to one record run one at a time, atomically, and never
/// replace a newer or unreadable file.
class ProgressRepository {
  ProgressRepository({@visibleForTesting Directory? docsOverride}) : _docsOverride = docsOverride;

  final Directory? _docsOverride;

  /// The file extension (lower case, no dot).
  static const String extension = backupProgressExtension;

  /// The most records of one project kept aside (`.corrupt`, `.corrupt.2`, ...).
  static const int maxSetAside = 100;

  /// Whether [name] is one of the files [id]'s progress may leave in its craft folder: the record, a
  /// write's temp file, or a record moved aside (`.corrupt`, `.corrupt.2`, ...).
  static bool isProgressFile(String id, String name) {
    final base = '$id.$extension';
    if (name == base || name == '$base.tmp' || name == '$base.corrupt') return true;
    final n = name.startsWith('$base.corrupt.') ? name.substring('$base.corrupt.'.length) : null;
    return n != null && RegExp(r'^[1-9][0-9]{0,3}$').hasMatch(n);
  }

  /// Remove every progress file of [id] in the craft folder [dir] (a project's delete calls it after
  /// removing the sidecar). Tolerates missing files and a folder it cannot list.
  static Future<void> deleteFilesIn(String dir, String id) async {
    final folder = Directory(dir);
    final found = <File>[];
    try {
      await for (final ent in folder.list(followLinks: false)) {
        if (ent is File && isProgressFile(id, p.basename(ent.path))) found.add(ent);
      }
    } on FileSystemException {
      // Cannot list: still try the files whose names are known.
      found.addAll([
        for (final n in ['$id.$extension', '$id.$extension.tmp', '$id.$extension.corrupt'])
          File(p.join(dir, n)),
      ]);
    }
    for (final f in found) {
      try {
        if (await f.exists()) await f.delete();
      } on FileSystemException {
        // A leftover file holds a place and notes, no pattern; harmless.
      }
    }
  }

  /// The progress record kind of a craft folder (every craft Ply has is tracked).
  static ProgressCraft? craftOf(BackupCraft craft) => switch (craft) {
        BackupCraft.weaving => ProgressCraft.weaving,
        BackupCraft.knitting => ProgressCraft.knitting,
        BackupCraft.nalbinding => ProgressCraft.nalbinding,
        BackupCraft.tabletWeaving => ProgressCraft.tabletWeaving,
      };

  Future<Directory> _docs() async => _docsOverride ?? await getApplicationDocumentsDirectory();

  Future<String> _dir(BackupCraft craft) async => p.join((await _docs()).path, craft.directory);

  /// The record's path, or a [ProgressFileException] for an id that names no saved project.
  Future<File> file(BackupCraft craft, String id) async {
    if (!isBackupProjectId(id)) {
      throw const ProgressFileException(ProgressProblem.projectGone, detail: 'not a project id');
    }
    return File(p.join(await _dir(craft), '$id.$extension'));
  }

  static ProgressCraft _progressCraft(BackupCraft craft) =>
      craftOf(craft) ?? (throw ArgumentError('progress is not tracked for ${craft.label} yet'));

  /// Read [id]'s progress. Never writes. Waits for every write to the record this app has queued,
  /// so a tracker opened again at once reads the place the last one wrote (and can never write an
  /// older place over it).
  Future<ProgressLoad> load(BackupCraft craft, String id) async {
    final f = await file(craft, id);
    final pc = _progressCraft(craft);
    return _serial(f.path, () => _read(f, pc));
  }

  /// [id]'s record file, once every write to it this app has queued has finished, for a reader that
  /// reads the file itself (a library listing reads large records on a background isolate): it then
  /// reads the place the last write left, as [load] does. Never writes.
  Future<File> settled(BackupCraft craft, String id) async {
    final f = await file(craft, id);
    await _serial(f.path, () async {});
    return f;
  }

  // Reading a record, in the steps every reader takes in the same order (the tracker's [load] here,
  // and a library listing's background isolate through [readFileSync]): a file past the bound is
  // not decoded, and its first bytes say whether a newer Ply wrote it; any other is measured before
  // it is decoded; then the record's own decode. Only the file system calls differ (asynchronous
  // here, synchronous on a background isolate); what the bytes are found to be is decided once, in
  // [readBytes] and [readHead]. Only a file that is not there is [ProgressStatus.none]: `exists()` is
  // never asked, since it answers false for any error (a folder that cannot be searched, a storage
  // error) as well, and a tracker would then start a new record over one it could not see. Any other
  // file system error is [ProgressStatus.failed], never unreadable.

  Future<ProgressLoad> _read(File f, ProgressCraft craft) async {
    try {
      if (await f.length() > ProgressLimits.maxFileBytes) {
        final raf = await f.open();
        try {
          return readHead(await raf.read(ProgressLimits.versionProbeBytes));
        } finally {
          await raf.close();
        }
      }
      return readBytes(await f.readAsBytes(), craft);
    } on PathNotFoundException {
      return const ProgressLoad(ProgressStatus.none);
    } on FileSystemException {
      return const ProgressLoad(ProgressStatus.failed);
    }
  }

  /// [load]'s read of the record at [path] (a project of [craft]), with synchronous file calls, for a
  /// background isolate. Never writes; never throws.
  static ProgressLoad readFileSync(String path, ProgressCraft craft) {
    final f = File(path);
    try {
      if (f.lengthSync() > ProgressLimits.maxFileBytes) {
        final raf = f.openSync();
        try {
          return readHead(raf.readSync(ProgressLimits.versionProbeBytes));
        } finally {
          raf.closeSync();
        }
      }
      return readBytes(f.readAsBytesSync(), craft);
    } on PathNotFoundException {
      return const ProgressLoad(ProgressStatus.none);
    } on FileSystemException {
      return const ProgressLoad(ProgressStatus.failed);
    }
  }

  /// What a record too large to decode is, from its first bytes [head] (see [Progress.probeVersion]):
  /// newer when they name a later schema version, else unreadable.
  static ProgressLoad readHead(List<int> head) {
    final v = Progress.probeVersion(String.fromCharCodes(head));
    return ProgressLoad(v != null && v > kProgressSchemaVersion
        ? ProgressStatus.newer
        : ProgressStatus.unreadable);
  }

  /// What [bytes], a whole record within the file bound, are for a project of [craft].
  static ProgressLoad readBytes(List<int> bytes, ProgressCraft craft) {
    try {
      // Measured before it is decoded: a record nested too deep or holding a number too large for
      // a double could never be written again, so it would wedge every later save.
      final shape = measureJson(bytes, stop: ProgressLimits.maxValues);
      if (shape.values > ProgressLimits.maxValues ||
          shape.depth > ProgressLimits.maxDepth ||
          shape.nonFinite) {
        return const ProgressLoad(ProgressStatus.unreadable);
      }
      final text = utf8.decode(bytes);
      return ProgressLoad(ProgressStatus.ok, Progress.decode(text, craft: craft));
    } on ProgressFileException catch (e) {
      return ProgressLoad(e.problem == ProgressProblem.newerVersion
          ? ProgressStatus.newer
          : ProgressStatus.unreadable);
    } on FormatException {
      // Not UTF-8.
      return const ProgressLoad(ProgressStatus.unreadable);
    }
  }

  static final Map<String, int> _writes = {};

  /// How many writes this app has made to the record at [path] (saves, deletes and records set
  /// aside, failed ones included), so a reader that keeps what it read can tell a record rewritten
  /// within the same instant, at the same size, from one left alone.
  static int writeCount(String path) => _writes[p.normalize(p.absolute(path))] ?? 0;

  static void _wrote(String path) {
    final key = p.normalize(p.absolute(path));
    _writes[key] = (_writes[key] ?? 0) + 1;
  }

  static final Map<String, Future<void>> _tails = {};

  /// Run [write] once every earlier write to [path] in this app has finished.
  static Future<T> _serial<T>(String path, Future<T> Function() write) {
    final key = p.normalize(p.absolute(path));
    final before = _tails[key] ?? Future<void>.value();
    final run = before.then((_) => write());
    final tail = run.then((_) {}, onError: (Object _) {});
    _tails[key] = tail;
    tail.then((_) {
      if (identical(_tails[key], tail)) _tails.remove(key);
    });
    return run;
  }

  /// Write [progress] as [id]'s record, atomically (temp file, flush, rename). Refuses, without
  /// writing, when the record on disk is newer or unreadable, or cannot be checked just now, when the
  /// project is no longer in the library (its sidecar is gone), when [guard] says the tracker expects
  /// no record and there is one, or when the record cannot be kept within the file bound. Returns the
  /// record as written (its oldest log entries dropped if the bound required it).
  Future<Progress> save(BackupCraft craft, String id, Progress progress,
      {ProgressSaveGuard? guard}) async {
    final f = await file(craft, id);
    final pc = _progressCraft(craft);
    if (progress.craft != pc) throw ArgumentError('a ${progress.craft.key} record for $craft');
    final sidecar = p.join(p.dirname(f.path), '$id.json');
    return _serial(
        f.path,
        // The sidecar lock (ADR 0016) while checking the project exists and writing: a delete removes
        // the sidecar under it and this record after it, so a write racing a delete never leaves a
        // record for a deleted project behind.
        () => SidecarWrites.run(sidecar, () async {
              try {
                await File(sidecar).length();
              } on PathNotFoundException {
                throw const ProgressFileException(ProgressProblem.projectGone);
              } on FileSystemException {
                throw const ProgressFileException(ProgressProblem.saveCheckFailed);
              }
              final onDisk = await _read(f, pc);
              switch (onDisk.status) {
                case ProgressStatus.newer:
                  throw const ProgressFileException(ProgressProblem.newerVersion);
                case ProgressStatus.unreadable:
                  throw const ProgressFileException(ProgressProblem.unreadable);
                case ProgressStatus.failed:
                  // What is on disk is not known: never written over.
                  throw const ProgressFileException(ProgressProblem.saveCheckFailed);
                case ProgressStatus.ok:
                  if (guard?.expectNoRecord ?? false) {
                    throw const ProgressFileException(ProgressProblem.foundAgain);
                  }
                case ProgressStatus.none:
                  break;
              }
              final fitted = progress.encodeFitted();
              final tmp = File('${f.path}.tmp');
              try {
                await tmp.writeAsString(fitted.text, flush: true);
                await tmp.rename(f.path);
              } finally {
                _wrote(f.path);
              }
              guard?.expectNoRecord = false;
              return fitted.progress;
            }));
  }

  /// Move an unreadable record aside, so a new record can start: to `<id>.plyprogress.corrupt`, or
  /// `.corrupt.2`, `.corrupt.3` and so on when earlier ones are there (none is ever replaced). Refuses
  /// a newer record (never moved or replaced), and one the device could not read just now (it may be
  /// a good record: [ProgressProblem.ioFailed]) unless [evenIfNotRead], which the crafter asks for
  /// once reading it again has failed too (a rename does not read the file, and keeps its bytes).
  /// Refuses past [maxSetAside] kept aside, says plainly when the device cannot move it
  /// ([ProgressProblem.setAsideFailed]), and does nothing when the record reads.
  Future<void> setAside(BackupCraft craft, String id, {bool evenIfNotRead = false}) async {
    final f = await file(craft, id);
    final pc = _progressCraft(craft);
    await _serial(f.path, () async {
      final onDisk = await _read(f, pc);
      if (onDisk.status == ProgressStatus.newer) {
        throw const ProgressFileException(ProgressProblem.newerVersion);
      }
      if (onDisk.status == ProgressStatus.failed && !evenIfNotRead) {
        throw const ProgressFileException(ProgressProblem.ioFailed);
      }
      if (onDisk.status != ProgressStatus.unreadable && onDisk.status != ProgressStatus.failed) {
        return;
      }
      for (var n = 1; n <= maxSetAside; n++) {
        final aside = File(n == 1 ? '${f.path}.corrupt' : '${f.path}.corrupt.$n');
        // Taken, free, or not known: a name that cannot be checked is never renamed onto (a rename
        // would replace a record kept aside before).
        try {
          await aside.length();
          continue;
        } on PathNotFoundException {
          // Free.
        } on FileSystemException catch (e) {
          throw ProgressFileException(ProgressProblem.setAsideFailed, detail: e.message);
        }
        try {
          await f.rename(aside.path);
        } on FileSystemException catch (e) {
          throw ProgressFileException(ProgressProblem.setAsideFailed, detail: e.message);
        } finally {
          _wrote(f.path);
        }
        return;
      }
      throw const ProgressFileException(ProgressProblem.unreadable,
          detail: 'too many records kept aside');
    });
  }

  /// Remove [id]'s progress (the record, its temp file and every record moved aside). The place, log
  /// and notes go together. Tolerates missing files.
  Future<void> delete(BackupCraft craft, String id) async {
    final f = await file(craft, id);
    await _serial(f.path, () async {
      try {
        await deleteFilesIn(p.dirname(f.path), id);
      } finally {
        _wrote(f.path);
      }
    });
  }
}
