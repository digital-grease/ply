// A project's progress record on the device (ADR 0023): `<documents>/<craft folder>/<id>.plyprogress`,
// next to the project's other files and apart from them. Nothing here reads or writes the pattern or
// its sidecar; a write only checks, under the sidecar's lock, that the project still exists.

import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/progress.dart';
import 'library_backup.dart' show BackupCraft, isBackupProjectId;
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
  static const String extension = 'plyprogress';

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

  static ProgressCraft? craftOf(BackupCraft craft) => switch (craft) {
        BackupCraft.weaving => ProgressCraft.weaving,
        BackupCraft.knitting => ProgressCraft.knitting,
        _ => null,
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

  /// Read [id]'s progress. Never writes.
  Future<ProgressLoad> load(BackupCraft craft, String id) async {
    final f = await file(craft, id);
    return _read(f, _progressCraft(craft));
  }

  Future<ProgressLoad> _read(File f, ProgressCraft craft) async {
    if (!await f.exists()) return const ProgressLoad(ProgressStatus.none);
    try {
      if (await f.length() > ProgressLimits.maxFileBytes) {
        // Too large to decode: its first bytes still say whether a newer Ply wrote it.
        return ProgressLoad(await _newerHead(f) ? ProgressStatus.newer : ProgressStatus.unreadable);
      }
      final text = await f.readAsString();
      return ProgressLoad(ProgressStatus.ok, Progress.decode(text, craft: craft));
    } on ProgressFileException catch (e) {
      return ProgressLoad(e.problem == ProgressProblem.newerVersion
          ? ProgressStatus.newer
          : ProgressStatus.unreadable);
    } on FileSystemException {
      return const ProgressLoad(ProgressStatus.unreadable);
    } on FormatException {
      // Not UTF-8.
      return const ProgressLoad(ProgressStatus.unreadable);
    }
  }

  /// Whether the first bytes of [f] name a newer schema version (see [Progress.probeVersion]).
  static Future<bool> _newerHead(File f) async {
    final raf = await f.open();
    try {
      final head = await raf.read(ProgressLimits.versionProbeBytes);
      final v = Progress.probeVersion(String.fromCharCodes(head));
      return v != null && v > kProgressSchemaVersion;
    } finally {
      await raf.close();
    }
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
  /// writing, when the record on disk is newer or unreadable, when the project is no longer in the
  /// library (its sidecar is gone), or when the record cannot be kept within the file bound. Returns
  /// the record as written (its oldest log entries dropped if the bound required it).
  Future<Progress> save(BackupCraft craft, String id, Progress progress) async {
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
              if (!await File(sidecar).exists()) {
                throw const ProgressFileException(ProgressProblem.projectGone);
              }
              final onDisk = await _read(f, pc);
              switch (onDisk.status) {
                case ProgressStatus.newer:
                  throw const ProgressFileException(ProgressProblem.newerVersion);
                case ProgressStatus.unreadable:
                  throw const ProgressFileException(ProgressProblem.unreadable);
                case ProgressStatus.none:
                case ProgressStatus.ok:
                  break;
              }
              final fitted = progress.encodeFitted();
              final tmp = File('${f.path}.tmp');
              await tmp.writeAsString(fitted.text, flush: true);
              await tmp.rename(f.path);
              return fitted.progress;
            }));
  }

  /// Move an unreadable record aside, so a new record can start: to `<id>.plyprogress.corrupt`, or
  /// `.corrupt.2`, `.corrupt.3` and so on when earlier ones are there (none is ever replaced). Refuses
  /// a newer record (never moved or replaced), refuses past [maxSetAside] kept aside, and does
  /// nothing when the record reads.
  Future<void> setAside(BackupCraft craft, String id) async {
    final f = await file(craft, id);
    final pc = _progressCraft(craft);
    await _serial(f.path, () async {
      final onDisk = await _read(f, pc);
      if (onDisk.status == ProgressStatus.newer) {
        throw const ProgressFileException(ProgressProblem.newerVersion);
      }
      if (onDisk.status != ProgressStatus.unreadable) return;
      for (var n = 1; n <= maxSetAside; n++) {
        final aside = File(n == 1 ? '${f.path}.corrupt' : '${f.path}.corrupt.$n');
        if (await aside.exists()) continue;
        await f.rename(aside.path);
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
    await _serial(f.path, () => deleteFilesIn(p.dirname(f.path), id));
  }
}
