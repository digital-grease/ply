// Portable backup and restore of the whole on-device library (roadmap M7-07; see the backup ADR).
//
// A backup is one `.plybackup` file: an UNCOMPRESSED POSIX ustar archive (see `ustar.dart`) whose
// first entry is `manifest.json`, followed by every project's files copied VERBATIM from the library:
//
//   drafts/<id>.wif + drafts/<id>.json
//   knits/<id>.plyknit + knits/<id>.json + knits/<id>.plyknit.v<n>.bak (format-upgrade backups)
//   nalbinds/<id>.plynal + nalbinds/<id>.json + nalbinds/<id>.photos/<name>.<ext>
//
// Thumbnails (`<id>.png`) are rebuildable caches and are left out; a restore rebuilds them. App
// settings are not part of a backup (version 1).
//
// A restore treats the file as hostile until every check has passed: hard limits on size, entry
// count, entry size and path length; only regular files at paths of the layout above (no absolute
// paths, `..`, backslashes, duplicates, links or devices); every entry listed in the manifest with
// its size and SHA-256, and every SHA-256 verified; no newer backup schema; and each project's files
// checked with the existing format probes (a project newer than this build is refused, with the
// reason). Only then is a preview built, and nothing in the library is written until the user
// confirms it. The commit stages every file inside the documents directory, then moves each project
// into place with its sidecar LAST (the library lists sidecars), and on any failure removes what it
// placed, so the library is left exactly as it was. Existing projects are never overwritten: one
// with the same id and different content is restored as a copy under a new id.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../diagnostics/log_buffer.dart';
import '../models/draft_meta.dart';
import '../models/nalbind_project.dart';
import '../models/native_format.dart';
import 'ustar.dart';

const int _mib = 1024 * 1024;

/// The three craft libraries a backup holds, with their folder and native file extension.
enum BackupCraft {
  weaving('weaving', 'drafts', 'wif', 'Weaving'),
  knitting('knitting', 'knits', 'plyknit', 'Knitting'),
  nalbinding('nalbinding', 'nalbinds', 'plynal', 'Nalbinding');

  const BackupCraft(this.manifestName, this.directory, this.nativeExtension, this.label);

  /// The `craft` value in a manifest entry.
  final String manifestName;

  /// The library folder under the documents directory (and the archive's top-level folder).
  final String directory;

  /// The extension of the project's native file.
  final String nativeExtension;

  /// The craft's name in the UI.
  final String label;

  static BackupCraft? byManifestName(String name) =>
      values.firstWhereOrNull((c) => c.manifestName == name);

  static BackupCraft? byDirectory(String dir) => values.firstWhereOrNull((c) => c.directory == dir);
}

/// What one file is to its project.
enum BackupFileRole {
  /// The project's own document (`.wif`, `.plyknit`, `.plynal`).
  native,

  /// The `<id>.json` sidecar the library lists. Always placed LAST on restore.
  sidecar,

  /// A knit format-upgrade backup, `<id>.plyknit.v<n>.bak`.
  upgradeBackup,

  /// A nalbinding project photo, `<id>.photos/<name>.<ext>`.
  photo,
}

/// A path of the library layout, classified.
class LibraryPath {
  const LibraryPath._(this.craft, this.projectId, this.role, {this.version, this.photoName});

  final BackupCraft craft;
  final String projectId;
  final BackupFileRole role;

  /// The schema version in an upgrade backup's name.
  final int? version;

  /// A photo's file name inside its project's photo folder.
  final String? photoName;

  /// This file's '/'-separated path (relative to the documents directory and inside an archive)
  /// for the project stored under [id].
  String pathFor(String id) {
    final dir = craft.directory;
    return switch (role) {
      BackupFileRole.native => '$dir/$id.${craft.nativeExtension}',
      BackupFileRole.sidecar => '$dir/$id.json',
      BackupFileRole.upgradeBackup => '$dir/$id.plyknit.v$version.bak',
      BackupFileRole.photo => '$dir/$id.photos/$photoName',
    };
  }
}

/// The name of the manifest, the first entry of every backup.
const String backupManifestPath = 'manifest.json';

/// A project id as Ply writes it (a uuid), and as a backup may name it: ASCII letters, digits, '-'
/// and '_', at most 64 characters, starting with a letter or digit. No '.', so a file name splits
/// into id and extension unambiguously.
final RegExp _idPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$');

final RegExp _upgradeBackupPattern = RegExp(r'^plyknit\.v([1-9][0-9]{0,3})\.bak$');

final RegExp _photoPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,63}\.([A-Za-z]{3,4})$');

/// The photo extensions `PhotoStore` lists (compared in lowercase).
const Set<String> _photoExtensions = {'jpg', 'jpeg', 'png', 'heic', 'webp'};

/// Whether [id] is a project id a backup can carry.
bool isBackupProjectId(String id) => _idPattern.hasMatch(id);

/// Classify an archive (or library-relative) path against the layout, or null when it is not part
/// of it. Rejects absolute paths, backslashes, empty, `.` and `..` segments, and any name outside the
/// grammar above, so a path that classifies can only ever name a file inside a craft folder.
LibraryPath? classifyLibraryPath(String path) {
  if (path.isEmpty || path.startsWith('/') || path.contains(r'\') || path.contains('\u0000')) {
    return null;
  }
  final segments = path.split('/');
  if (segments.any((s) => s.isEmpty || s == '.' || s == '..')) return null;
  final craft = BackupCraft.byDirectory(segments.first);
  if (craft == null) return null;

  if (segments.length == 2) {
    final file = segments[1];
    final dot = file.indexOf('.');
    if (dot <= 0) return null;
    final id = file.substring(0, dot);
    if (!_idPattern.hasMatch(id)) return null;
    final rest = file.substring(dot + 1);
    if (rest == 'json') return LibraryPath._(craft, id, BackupFileRole.sidecar);
    if (rest == craft.nativeExtension) return LibraryPath._(craft, id, BackupFileRole.native);
    if (craft == BackupCraft.knitting) {
      final m = _upgradeBackupPattern.firstMatch(rest);
      if (m != null) {
        return LibraryPath._(craft, id, BackupFileRole.upgradeBackup,
            version: int.parse(m.group(1)!));
      }
    }
    return null;
  }

  if (segments.length == 3 && craft == BackupCraft.nalbinding) {
    final folder = segments[1];
    if (!folder.endsWith('.photos')) return null;
    final id = folder.substring(0, folder.length - '.photos'.length);
    if (!_idPattern.hasMatch(id)) return null;
    final m = _photoPattern.firstMatch(segments[2]);
    if (m == null || !_photoExtensions.contains(m.group(1)!.toLowerCase())) return null;
    return LibraryPath._(craft, id, BackupFileRole.photo, photoName: segments[2]);
  }
  return null;
}

/// The hard limits a backup must fit, chosen for a phone. A backup this build makes always fits
/// them: export refuses a library that does not, so it never hands out a file it would refuse.
class BackupLimits {
  const BackupLimits({
    this.maxArchiveBytes = 512 * _mib,
    this.maxExportBytes = 512 * _mib,
    this.maxEntries = 10000,
    this.maxPathLength = 200,
    this.maxManifestBytes = 4 * _mib,
    this.maxSidecarBytes = _mib,
    this.maxFileBytes = 64 * _mib,
  });

  /// The limits for the device this runs on: a phone saves a backup through the system save dialog,
  /// which takes the whole file in memory at once, so it makes backups of at most 128 MB.
  factory BackupLimits.forThisDevice() => BackupLimits(
        maxExportBytes: (Platform.isAndroid || Platform.isIOS) ? 128 * _mib : 512 * _mib,
      );

  /// The largest backup file a restore opens. It is read from disk a block at a time, never whole.
  final int maxArchiveBytes;

  /// The largest backup file this device makes (held in memory while it is saved).
  final int maxExportBytes;

  /// The most archive entries (the manifest plus one per file).
  final int maxEntries;

  /// The longest archive path. The layout's longest real path (a photo) is 150 characters.
  final int maxPathLength;

  /// The largest manifest.
  final int maxManifestBytes;

  /// The largest sidecar.
  final int maxSidecarBytes;

  /// The largest native file, upgrade backup or photo.
  final int maxFileBytes;

  int maxBytesFor(BackupFileRole role) =>
      role == BackupFileRole.sidecar ? maxSidecarBytes : maxFileBytes;
}

/// What stopped a backup or a restore. [message] is the user-facing sentence; [detail] is for logs.
enum BackupProblem {
  // Making a backup.
  noProjects,
  libraryTooLarge,
  libraryTooManyFiles,
  fileTooLarge,
  libraryChanged,
  // Checking a backup before a restore.
  backupTooLarge,
  backupTooManyFiles,
  notABackup,
  newerBackup,
  damaged,
  unsafe,
  unreadable,
  // Writing a restore.
  restoreFailed,
}

class BackupException implements Exception {
  const BackupException(this.problem, {this.detail, this.projectName, this.limit});

  final BackupProblem problem;

  /// Diagnostic only, never the main message.
  final String? detail;

  /// The project a [BackupProblem.fileTooLarge] is about.
  final String? projectName;

  /// The limit (bytes, or files) that was exceeded.
  final int? limit;

  String get message => switch (problem) {
        BackupProblem.noProjects => 'There are no projects to back up.',
        BackupProblem.libraryTooLarge =>
          'Your library is too large for one backup file on this device (over ${formatBytes(limit ?? 0)}).',
        BackupProblem.libraryTooManyFiles =>
          'Your library has too many files for one backup (over ${limit ?? 0}).',
        BackupProblem.fileTooLarge =>
          'A file in "${projectName ?? ''}" is too large to back up (over ${formatBytes(limit ?? 0)}).',
        BackupProblem.libraryChanged =>
          'Your library changed while the backup was being made. Try again.',
        BackupProblem.backupTooLarge =>
          'This backup is too large to restore (over ${formatBytes(limit ?? 0)}).',
        BackupProblem.backupTooManyFiles =>
          'This backup has too many files to restore (over ${limit ?? 0}).',
        BackupProblem.notABackup => 'This file is not a Ply backup.',
        BackupProblem.newerBackup =>
          'This backup was made by a newer version of Ply. Update the app to restore it.',
        BackupProblem.damaged => 'This backup is damaged and cannot be restored.',
        BackupProblem.unsafe => 'This backup contains files Ply cannot restore safely.',
        BackupProblem.unreadable => 'The backup file could not be read.',
        BackupProblem.restoreFailed => 'The restore did not finish. Your library was not changed.',
      };

  @override
  String toString() => detail == null ? message : '$message ($detail)';
}

/// A byte count for the UI: "820 KB", "4.2 MB".
String formatBytes(int bytes) {
  if (bytes < _mib) return '${(bytes / 1024).ceil()} KB';
  final mb = bytes / _mib;
  return mb == mb.roundToDouble() ? '${mb.round()} MB' : '${mb.toStringAsFixed(1)} MB';
}

/// One file entry of a manifest.
class BackupManifestFile {
  const BackupManifestFile({
    required this.path,
    required this.size,
    required this.sha256,
    required this.craft,
    required this.projectId,
  });

  final String path;
  final int size;

  /// Lowercase hex.
  final String sha256;
  final BackupCraft craft;
  final String projectId;

  Map<String, Object?> toJson() => {
        'path': path,
        'size': size,
        'sha256': sha256,
        'craft': craft.manifestName,
        'project': projectId,
      };
}

/// The `manifest.json` that opens every backup.
class BackupManifest {
  const BackupManifest({required this.createdAt, required this.appVersion, required this.files});

  /// The `format` value of every backup manifest.
  static const String format = 'ply.backup';

  /// The manifest schema this build writes, and the newest it reads.
  static const int currentSchemaVersion = 1;

  final DateTime createdAt;
  final String appVersion;
  final List<BackupManifestFile> files;

  Map<String, Object?> toJson() => {
        'format': format,
        'schema_version': currentSchemaVersion,
        'created_at': createdAt.toUtc().toIso8601String(),
        'app_version': appVersion,
        'files': [for (final f in files) f.toJson()],
      };

  Uint8List encode() =>
      Uint8List.fromList(utf8.encode(const JsonEncoder.withIndent(' ').convert(toJson())));

  /// Parse and check a manifest. Throws a [BackupException]: [BackupProblem.notABackup] when it is
  /// not a Ply backup manifest at all, [BackupProblem.newerBackup] for a newer schema (checked before
  /// anything else is read), [BackupProblem.unsafe] for a path outside the library layout or a
  /// duplicate, and [BackupProblem.damaged] for any other malformed field.
  static BackupManifest parse(Uint8List bytes, BackupLimits limits) {
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(bytes));
    } on FormatException catch (e) {
      throw BackupException(BackupProblem.notABackup, detail: 'manifest: $e');
    }
    if (json is! Map<String, dynamic> || json['format'] != format) {
      throw const BackupException(BackupProblem.notABackup, detail: 'manifest format');
    }
    BackupException damaged(String why) => BackupException(BackupProblem.damaged, detail: why);
    final version = json['schema_version'];
    if (version is! int || version < 1) throw damaged('schema_version $version');
    if (version > currentSchemaVersion) {
      throw BackupException(BackupProblem.newerBackup, detail: 'schema_version $version');
    }
    final created = json['created_at'];
    final createdAt = created is String ? DateTime.tryParse(created) : null;
    if (createdAt == null) throw damaged('created_at');
    final appVersion = json['app_version'];
    if (appVersion is! String || appVersion.length > 100) throw damaged('app_version');
    final rawFiles = json['files'];
    if (rawFiles is! List) throw damaged('files');
    if (rawFiles.length + 1 > limits.maxEntries) {
      throw BackupException(BackupProblem.backupTooManyFiles, limit: limits.maxEntries);
    }
    final sha = RegExp(r'^[0-9a-f]{64}$');
    final seen = <String>{};
    final files = <BackupManifestFile>[];
    for (final raw in rawFiles) {
      if (raw is! Map<String, dynamic>) throw damaged('a file entry');
      final path = raw['path'];
      final size = raw['size'];
      final digest = raw['sha256'];
      final craftName = raw['craft'];
      final project = raw['project'];
      if (path is! String || size is! int || size < 0 || digest is! String || !sha.hasMatch(digest)) {
        throw damaged('a file entry');
      }
      if (path.length > limits.maxPathLength) {
        throw const BackupException(BackupProblem.unsafe, detail: 'a long path');
      }
      final classified = classifyLibraryPath(path);
      if (classified == null) {
        throw BackupException(BackupProblem.unsafe, detail: 'manifest path $path');
      }
      // Case-insensitively unique: on a case-insensitive file system two such paths are one file.
      if (!seen.add(path.toLowerCase())) {
        throw BackupException(BackupProblem.unsafe, detail: 'duplicate manifest path $path');
      }
      if (craftName != classified.craft.manifestName || project != classified.projectId) {
        throw damaged('craft or project of $path');
      }
      if (size > limits.maxBytesFor(classified.role)) {
        throw BackupException(BackupProblem.unsafe, detail: '$path is $size bytes');
      }
      files.add(BackupManifestFile(
        path: path,
        size: size,
        sha256: digest,
        craft: classified.craft,
        projectId: classified.projectId,
      ));
    }
    return BackupManifest(createdAt: createdAt, appVersion: appVersion, files: files);
  }
}

// ---------------------------------------------------------------------------------------------
// Making a backup
// ---------------------------------------------------------------------------------------------

/// One library file going into a backup.
class BackupFile {
  const BackupFile({
    required this.archivePath,
    required this.sourcePath,
    required this.size,
    required this.sha256,
    required this.craft,
    required this.projectId,
  });

  final String archivePath;
  final String sourcePath;
  final int size;
  final String sha256;
  final BackupCraft craft;
  final String projectId;
}

/// A backup ready to be written: every file hashed and the manifest built. [archiveSize] is the
/// exact size of the file [LibraryBackup.buildBackup] makes from it.
class BackupPlan {
  const BackupPlan({
    required this.createdAt,
    required this.files,
    required this.manifestBytes,
    required this.projectCounts,
    required this.photoCount,
  });

  final DateTime createdAt;
  final List<BackupFile> files;
  final Uint8List manifestBytes;
  final Map<BackupCraft, int> projectCounts;
  final int photoCount;

  int get projectCount => projectCounts.values.sum;

  int get archiveSize =>
      ustarEntryLength(manifestBytes.length) +
      files.fold<int>(0, (sum, f) => sum + ustarEntryLength(f.size)) +
      ustarEndLength;

  /// The suggested file name: `ply-library-<yyyy-mm-dd>.plybackup` (local date).
  String get fileName {
    final d = createdAt.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return 'ply-library-${d.year}-${two(d.month)}-${two(d.day)}.plybackup';
  }
}

// ---------------------------------------------------------------------------------------------
// Restoring a backup
// ---------------------------------------------------------------------------------------------

/// What a restore will do with one project of a backup.
enum RestoreStatus {
  /// Not in the library: restored under its own id.
  add,

  /// Already in the library with the same content (ignoring when it was last opened): skipped.
  alreadyPresent,

  /// The library has a different project under this id: restored as a copy under a new id, named
  /// "<name> (restored)", unless the user unticks it. The existing project is never touched.
  conflict,

  /// Cannot be restored by this build; see [RestoreProject.refusal].
  refused,
}

/// Why a project of a backup cannot be restored.
enum RestoreRefusal {
  newerVersion('Made by a newer version of Ply. Update the app to restore it.'),
  unreadable('A file in this project could not be read.'),
  incomplete('Part of this project is missing from the backup.');

  const RestoreRefusal(this.message);

  /// The user-facing reason.
  final String message;
}

/// One archived file of a project: where it is in the archive and its verified digest.
class _ArchivedFile {
  const _ArchivedFile(this.layout, this.size, this.dataOffset, this.sha256);

  final LibraryPath layout;
  final int size;
  final int dataOffset;
  final String sha256;
}

/// One project of a backup, as the restore preview shows it.
class RestoreProject {
  RestoreProject._({
    required this.craft,
    required this.id,
    required this.name,
    required this.status,
    required List<_ArchivedFile> files,
    this.refusal,
    this.targetId,
    this.targetName,
  }) : _files = files;

  final BackupCraft craft;

  /// The project's id in the backup.
  final String id;

  /// Its name in the backup.
  final String name;
  final RestoreStatus status;
  final RestoreRefusal? refusal;

  /// The id it will have in the library: [id] for [RestoreStatus.add], a new id for a conflict.
  final String? targetId;

  /// Its name in the library: [name], or "<name> (restored)" for a conflict.
  final String? targetName;

  final List<_ArchivedFile> _files;

  /// A key unique within a backup.
  String get key => '${craft.manifestName}/$id';

  int get photoCount => _files.where((f) => f.layout.role == BackupFileRole.photo).length;
}

/// A checked backup, ready to preview and restore. Nothing has been written yet.
class RestorePlan {
  const RestorePlan({
    required this.archive,
    required this.createdAt,
    required this.appVersion,
    required this.projects,
  });

  /// The backup file. It must stay in place until [LibraryBackup.restore] returns.
  final File archive;
  final DateTime createdAt;
  final String appVersion;
  final List<RestoreProject> projects;

  List<RestoreProject> forCraft(BackupCraft craft, RestoreStatus status) =>
      [for (final p in projects) if (p.craft == craft && p.status == status) p];
}

/// What a restore wrote.
class RestoreResult {
  const RestoreResult(this.restored);

  /// The projects now in the library, with their final ids.
  final List<({BackupCraft craft, String id})> restored;

  int get count => restored.length;
}

/// Engine checks of a native file, beyond the version probes (production passes the engine parsers;
/// host tests have no native library). Each throws when the engine cannot read the text.
class NativeFileChecks {
  const NativeFileChecks({this.wif, this.knit});

  final Future<void> Function(String text)? wif;

  /// Throws a [NativeFormatException] (or anything else) when the engine cannot read the pattern.
  final Future<void> Function(String text)? knit;
}

/// The library backup service: [planBackup] and [buildBackup] make a backup, [inspectBackup] checks
/// one and builds the restore preview, and [restore] writes it.
class LibraryBackup {
  LibraryBackup({
    required this.documentsDir,
    required this.currentKnitSchemaVersion,
    required this.appVersion,
    this.limits = const BackupLimits(),
    this.checks = const NativeFileChecks(),
    this.rebuildThumbnail,
    DateTime Function()? clock,
    @visibleForTesting this.beforePlace,
  }) : _clock = clock ?? DateTime.now;

  /// The app documents directory, which holds the three craft folders.
  final Future<Directory> Function() documentsDir;

  /// The `.plyknit` schema version this build writes (and the newest it reads). Production asks the
  /// engine, so a format bump never needs a change here.
  final Future<int> Function() currentKnitSchemaVersion;

  /// Recorded in the manifest.
  final String appVersion;
  final BackupLimits limits;
  final NativeFileChecks checks;

  /// Rebuilds the thumbnail of a restored weaving or knitting project (best-effort).
  final Future<void> Function(BackupCraft craft, String id)? rebuildThumbnail;
  final DateTime Function() _clock;

  /// Test seam: called before each file or folder is moved into the library on restore. Throwing
  /// from it simulates a failure part-way through the commit.
  final Future<void> Function(String targetPath)? beforePlace;

  static const Uuid _uuid = Uuid();
  static const int _chunk = 64 * 1024;

  /// Staging folders live in the documents directory (so the final moves are renames on one file
  /// system) under this prefix. A dot keeps them out of any listing.
  static const String stagingPrefix = '.ply-restore-';

  // --- Making a backup -----------------------------------------------------------------------

  /// Find and hash every project in the library. Throws a [BackupException] for an empty library
  /// and for one over the limits (naming the project of an oversized file).
  Future<BackupPlan> planBackup() async {
    final docs = await documentsDir();
    final files = <BackupFile>[];
    final counts = {for (final c in BackupCraft.values) c: 0};
    var photos = 0;
    for (final craft in BackupCraft.values) {
      final dir = Directory(p.join(docs.path, craft.directory));
      if (!await dir.exists()) continue;
      final names = <String, FileSystemEntity>{};
      await for (final ent in dir.list(followLinks: false)) {
        names[p.basename(ent.path)] = ent;
      }
      final ids = [
        for (final e in names.entries)
          if (e.value is File && e.key.endsWith('.json')) e.key.substring(0, e.key.length - 5),
      ]..sort();
      for (final id in ids) {
        if (!isBackupProjectId(id)) {
          PlyLog.instance.warn('Backup: skipped ${craft.directory}/$id.json (not a Ply id).');
          continue;
        }
        final native = names['$id.${craft.nativeExtension}'];
        if (native is! File) continue; // the library does not list it either
        final sidecar = names['$id.json'] as File;
        final String name;
        try {
          if (await sidecar.length() > limits.maxSidecarBytes) {
            throw BackupException(BackupProblem.fileTooLarge,
                projectName: id, limit: limits.maxSidecarBytes);
          }
          final json = jsonDecode(await sidecar.readAsString());
          name = DraftMeta.fromJson(json as Map<String, dynamic>).name;
        } on BackupException {
          rethrow;
        } catch (_) {
          continue; // an unreadable sidecar: the library does not list it either
        }
        final layoutFiles = <(LibraryPath, File)>[
          (LibraryPath._(craft, id, BackupFileRole.native), native),
        ];
        if (craft == BackupCraft.knitting) {
          final backups = <(int, File)>[];
          for (final e in names.entries) {
            if (e.value is! File || !e.key.startsWith('$id.')) continue;
            final m = _upgradeBackupPattern.firstMatch(e.key.substring(id.length + 1));
            if (m != null) backups.add((int.parse(m.group(1)!), e.value as File));
          }
          backups.sort((a, b) => a.$1.compareTo(b.$1));
          for (final (v, f) in backups) {
            layoutFiles.add((LibraryPath._(craft, id, BackupFileRole.upgradeBackup, version: v), f));
          }
        }
        if (craft == BackupCraft.nalbinding && names['$id.photos'] is Directory) {
          final found = <File>[];
          await for (final ent in (names['$id.photos'] as Directory).list(followLinks: false)) {
            if (ent is! File) continue;
            final m = _photoPattern.firstMatch(p.basename(ent.path));
            if (m != null && _photoExtensions.contains(m.group(1)!.toLowerCase())) found.add(ent);
          }
          found.sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
          for (final f in found) {
            layoutFiles.add((
              LibraryPath._(craft, id, BackupFileRole.photo, photoName: p.basename(f.path)),
              f,
            ));
          }
          photos += found.length;
        }
        layoutFiles.add((LibraryPath._(craft, id, BackupFileRole.sidecar), sidecar));

        for (final (layout, file) in layoutFiles) {
          final max = limits.maxBytesFor(layout.role);
          if (await file.length() > max) {
            throw BackupException(BackupProblem.fileTooLarge, projectName: name, limit: max);
          }
          final (digest, size) = await _hashFile(file, max);
          if (size > max) {
            throw BackupException(BackupProblem.fileTooLarge, projectName: name, limit: max);
          }
          files.add(BackupFile(
            archivePath: layout.pathFor(id),
            sourcePath: file.path,
            size: size,
            sha256: digest,
            craft: craft,
            projectId: id,
          ));
        }
        counts[craft] = counts[craft]! + 1;
        if (files.length + 1 > limits.maxEntries) {
          throw BackupException(BackupProblem.libraryTooManyFiles, limit: limits.maxEntries);
        }
      }
    }
    if (files.isEmpty) throw const BackupException(BackupProblem.noProjects);
    final createdAt = _clock();
    final manifest = BackupManifest(
      createdAt: createdAt,
      appVersion: appVersion,
      files: [
        for (final f in files)
          BackupManifestFile(
            path: f.archivePath,
            size: f.size,
            sha256: f.sha256,
            craft: f.craft,
            projectId: f.projectId,
          ),
      ],
    );
    final plan = BackupPlan(
      createdAt: createdAt,
      files: files,
      manifestBytes: manifest.encode(),
      projectCounts: counts,
      photoCount: photos,
    );
    if (plan.manifestBytes.length > limits.maxManifestBytes ||
        plan.archiveSize > limits.maxExportBytes) {
      throw BackupException(BackupProblem.libraryTooLarge, limit: limits.maxExportBytes);
    }
    return plan;
  }

  /// Write the backup file for [plan] into memory: the manifest, then every file, read again and
  /// checked against the digest the manifest records. Throws [BackupProblem.libraryChanged] when a
  /// file changed since [planBackup].
  Future<Uint8List> buildBackup(BackupPlan plan) async {
    final out = Uint8List(plan.archiveSize);
    final mtime = plan.createdAt.millisecondsSinceEpoch ~/ 1000;
    var offset = 0;
    void header(String path, int size) {
      out.setRange(offset, offset + ustarBlockSize,
          UstarHeader.file(path, size, modified: mtime).encode());
      offset += ustarBlockSize;
    }

    header(backupManifestPath, plan.manifestBytes.length);
    out.setRange(offset, offset + plan.manifestBytes.length, plan.manifestBytes);
    offset += plan.manifestBytes.length + ustarPadding(plan.manifestBytes.length);

    for (final f in plan.files) {
      header(f.archivePath, f.size);
      RandomAccessFile? raf;
      try {
        raf = await File(f.sourcePath).open();
        if (await raf.length() != f.size) {
          throw BackupException(BackupProblem.libraryChanged, detail: f.archivePath);
        }
        var read = 0;
        while (read < f.size) {
          final n = await raf.readInto(out, offset + read, offset + f.size);
          if (n <= 0) throw BackupException(BackupProblem.libraryChanged, detail: f.archivePath);
          read += n;
        }
      } on FileSystemException catch (e) {
        throw BackupException(BackupProblem.libraryChanged, detail: '${f.archivePath}: $e');
      } finally {
        await raf?.close();
      }
      final digest = await _hashBytes(Uint8List.sublistView(out, offset, offset + f.size));
      if (digest != f.sha256) {
        throw BackupException(BackupProblem.libraryChanged, detail: f.archivePath);
      }
      offset += f.size + ustarPadding(f.size);
    }
    // The two end blocks are already zero.
    assert(offset + ustarEndLength == out.length);
    return out;
  }

  // --- Checking a backup ---------------------------------------------------------------------

  /// Check [archive] completely and build the restore preview. Writes nothing to the library.
  /// Throws a [BackupException] when the whole backup must be refused; a project this build cannot
  /// restore is returned as [RestoreStatus.refused] with its reason instead.
  Future<RestorePlan> inspectBackup(File archive) async {
    final docs = await documentsDir();
    await _sweepStaging(docs);
    final int length;
    final RandomAccessFile raf;
    try {
      length = await archive.length();
      if (length > limits.maxArchiveBytes) {
        throw BackupException(BackupProblem.backupTooLarge, limit: limits.maxArchiveBytes);
      }
      raf = await archive.open();
    } on FileSystemException catch (e) {
      throw BackupException(BackupProblem.unreadable, detail: '$e');
    }
    try {
      final (manifest, accumulators) = await _readArchive(raf, length);
      final projects = <RestoreProject>[];
      for (final craft in BackupCraft.values) {
        final dir = Directory(p.join(docs.path, craft.directory));
        final stems = await _stems(dir);
        final ofCraft = accumulators.values.where((a) => a.craft == craft).toList()
          ..sort((a, b) => a.id.compareTo(b.id));
        for (final acc in ofCraft) {
          projects.add(await _classify(acc, dir, stems));
        }
      }
      return RestorePlan(
        archive: archive,
        createdAt: manifest.createdAt,
        appVersion: manifest.appVersion,
        projects: projects,
      );
    } on FileSystemException catch (e) {
      throw BackupException(BackupProblem.unreadable, detail: '$e');
    } finally {
      await raf.close();
    }
  }

  /// Read every entry: the manifest first, then each file, checked against it and hashed. A file
  /// that must be inspected (native file, upgrade backup, sidecar) is read into memory, within the
  /// per-entry limits, checked with the format probes right away, and dropped: only the verdict and
  /// a few digests are kept per project. Photos are only hashed.
  Future<(BackupManifest, Map<String, _ProjectAccumulator>)> _readArchive(
      RandomAccessFile raf, int length) async {
    final reader = UstarReader(raf, length);
    final BackupManifest manifest;
    try {
      final first = await reader.next();
      if (first == null || first.path != backupManifestPath) {
        throw const BackupException(BackupProblem.notABackup, detail: 'no manifest first');
      }
      if (first.size > limits.maxManifestBytes) {
        throw const BackupException(BackupProblem.notABackup, detail: 'manifest too large');
      }
      final bytes = await _readSlice(raf, first.dataOffset, first.size);
      manifest = BackupManifest.parse(bytes, limits);
    } on UstarFormatException catch (e) {
      throw BackupException(BackupProblem.notABackup, detail: '$e');
    }

    final expected = {for (final f in manifest.files) f.path: f};
    final seen = <String>{};
    final accumulators = <String, _ProjectAccumulator>{};
    int? knitVersion;
    Future<int> knit() async => knitVersion ??= await currentKnitSchemaVersion();
    var entries = 1;
    try {
      while (true) {
        final entry = await reader.next();
        if (entry == null) break;
        if (++entries > limits.maxEntries) {
          throw BackupException(BackupProblem.backupTooManyFiles, limit: limits.maxEntries);
        }
        final path = entry.path;
        if (path.length > limits.maxPathLength) {
          throw const BackupException(BackupProblem.unsafe, detail: 'a long path');
        }
        final layout = classifyLibraryPath(path);
        if (layout == null) throw BackupException(BackupProblem.unsafe, detail: 'path $path');
        if (!seen.add(path.toLowerCase())) {
          throw BackupException(BackupProblem.unsafe, detail: 'duplicate path $path');
        }
        final record = expected[path];
        if (record == null) {
          throw BackupException(BackupProblem.damaged, detail: '$path is not in the manifest');
        }
        if (record.size != entry.size) {
          throw BackupException(BackupProblem.damaged, detail: '$path size');
        }
        if (entry.size > limits.maxBytesFor(layout.role)) {
          throw BackupException(BackupProblem.unsafe, detail: '$path is ${entry.size} bytes');
        }
        final (digest, content) = await _hashSlice(raf, entry.dataOffset, entry.size,
            keep: layout.role != BackupFileRole.photo);
        if (digest != record.sha256) {
          throw BackupException(BackupProblem.damaged, detail: '$path checksum');
        }
        final acc = accumulators.putIfAbsent(
            '${layout.craft.manifestName}/${layout.projectId}',
            () => _ProjectAccumulator(layout.craft, layout.projectId));
        acc.files.add(_ArchivedFile(layout, entry.size, entry.dataOffset, digest));
        if (content != null) await _inspect(acc, layout, content, knit);
      }
    } on UstarFormatException catch (e) {
      throw BackupException(
        e.problem == UstarProblem.notRegularFile || e.problem == UstarProblem.badPath
            ? BackupProblem.unsafe
            : BackupProblem.damaged,
        detail: '$e',
      );
    }
    if (seen.length != expected.length) {
      throw const BackupException(BackupProblem.damaged, detail: 'a manifest file is missing');
    }
    return (manifest, accumulators);
  }

  /// Check one file of a project with the format probes and record the verdict on [acc].
  Future<void> _inspect(_ProjectAccumulator acc, LibraryPath layout, Uint8List bytes,
      Future<int> Function() knitVersion) async {
    final String text;
    try {
      text = utf8.decode(bytes);
    } on FormatException {
      acc.unreadable = true;
      return;
    }
    final verdict = switch (layout.role) {
      BackupFileRole.sidecar => _checkSidecar(acc, text),
      BackupFileRole.native => await _checkNative(acc.craft, text, knitVersion),
      BackupFileRole.upgradeBackup =>
        _checkUpgradeBackup(layout.version!, text, await knitVersion()),
      BackupFileRole.photo => null,
    };
    if (layout.role == BackupFileRole.native) acc.hasNative = true;
    if (layout.role == BackupFileRole.sidecar) acc.hasSidecar = true;
    if (verdict == RestoreRefusal.newerVersion) acc.newer = true;
    if (verdict == RestoreRefusal.unreadable) acc.unreadable = true;
  }

  RestoreRefusal? _checkSidecar(_ProjectAccumulator acc, String text) {
    final Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException {
      return RestoreRefusal.unreadable;
    }
    if (json is! Map<String, dynamic>) return RestoreRefusal.unreadable;
    final DraftMeta meta;
    try {
      meta = DraftMeta.fromJson(json);
    } catch (_) {
      return RestoreRefusal.unreadable;
    }
    acc.name = meta.name;
    acc.sidecarDigest = sidecarDigest(json);
    acc.copySidecarDigest = sidecarDigest(json, name: copyNameFor(meta.name));
    final version = json['schemaVersion'];
    if (version is int && version > DraftMeta.currentSchemaVersion) {
      return RestoreRefusal.newerVersion;
    }
    return null;
  }

  Future<RestoreRefusal?> _checkNative(
      BackupCraft craft, String text, Future<int> Function() knitVersion) async {
    switch (craft) {
      case BackupCraft.weaving:
        try {
          await checks.wif?.call(text);
        } catch (_) {
          return RestoreRefusal.unreadable;
        }
        return null;
      case BackupCraft.knitting:
        final version = plyknitSchemaVersion(text);
        if (version == null) return RestoreRefusal.unreadable;
        if (version > await knitVersion()) return RestoreRefusal.newerVersion;
        try {
          await checks.knit?.call(text);
        } on NativeFormatException catch (e) {
          return e.problem == NativeFormatProblem.newerVersion
              ? RestoreRefusal.newerVersion
              : RestoreRefusal.unreadable;
        } catch (_) {
          return RestoreRefusal.unreadable;
        }
        return null;
      case BackupCraft.nalbinding:
        try {
          NalbindProject.decode(text);
        } on NativeFormatException catch (e) {
          return e.problem == NativeFormatProblem.newerVersion
              ? RestoreRefusal.newerVersion
              : RestoreRefusal.unreadable;
        }
        return null;
    }
  }

  /// An upgrade backup holds the original file at the version its name records.
  RestoreRefusal? _checkUpgradeBackup(int version, String text, int knitVersion) {
    if (version > knitVersion) return RestoreRefusal.newerVersion;
    return plyknitSchemaVersion(text) == version ? null : RestoreRefusal.unreadable;
  }

  /// Decide what a restore does with one checked project: refuse it, add it, skip it as already
  /// present, or restore it as a copy.
  Future<RestoreProject> _classify(
      _ProjectAccumulator acc, Directory dir, Set<String> stems) async {
    final RestoreRefusal? refusal = acc.newer
        ? RestoreRefusal.newerVersion
        : acc.unreadable
            ? RestoreRefusal.unreadable
            : (!acc.hasNative || !acc.hasSidecar)
                ? RestoreRefusal.incomplete
                : null;
    final name = acc.name ?? 'Untitled';
    RestoreProject make(RestoreStatus status, {String? targetId, String? targetName}) =>
        RestoreProject._(
          craft: acc.craft,
          id: acc.id,
          name: name,
          status: status,
          files: List.unmodifiable(acc.files),
          refusal: status == RestoreStatus.refused ? refusal : null,
          targetId: targetId,
          targetName: targetName,
        );
    if (refusal != null) return make(RestoreStatus.refused);

    if (!stems.contains(acc.id.toLowerCase())) {
      return make(RestoreStatus.add, targetId: acc.id, targetName: name);
    }
    if (await _sameAsLibrary(dir, acc.id, acc.files, acc.sidecarDigest!)) {
      return make(RestoreStatus.alreadyPresent);
    }
    // A copy: a deterministic id, so restoring the same backup again finds the copy it made.
    var copyId = _copyId(acc);
    if (stems.contains(copyId)) {
      if (await _sameAsLibrary(dir, copyId, acc.files, acc.copySidecarDigest!)) {
        return make(RestoreStatus.alreadyPresent);
      }
      do {
        copyId = _uuid.v4();
      } while (stems.contains(copyId));
    }
    return make(RestoreStatus.conflict, targetId: copyId, targetName: copyNameFor(name));
  }

  /// The library name of a project restored as a copy.
  static String copyNameFor(String name) => '$name (restored)';

  /// A digest of a sidecar's content that ignores `lastOpened` (bumped by every open) and key order,
  /// with the name replaced by [name] when given (to compare against a restored copy).
  @visibleForTesting
  static String sidecarDigest(Map<String, dynamic> json, {String? name}) {
    final core = Map<String, dynamic>.of(json)..remove('lastOpened');
    if (name != null) core['name'] = name;
    return sha256.convert(utf8.encode(jsonEncode(_canonical(core)))).toString();
  }

  /// [value] with every map's keys sorted, so equal JSON encodes equally.
  static Object? _canonical(Object? value) {
    if (value is Map) {
      final keys = value.keys.map((k) => '$k').toList()..sort();
      return {for (final k in keys) k: _canonical(value[k])};
    }
    if (value is List) return [for (final v in value) _canonical(v)];
    return value;
  }

  /// Whether the library already holds everything the backup has for this project, under [id]:
  /// the same native file, a sidecar with [sidecarDigest] (see [LibraryBackup.sidecarDigest]), and
  /// every upgrade backup and photo of the backup with the same bytes.
  Future<bool> _sameAsLibrary(
      Directory dir, String id, List<_ArchivedFile> files, String sidecarDigest) async {
    try {
      for (final f in files) {
        final local = File(p.joinAll([dir.path, ...f.layout.pathFor(id).split('/').skip(1)]));
        if (await FileSystemEntity.type(local.path, followLinks: false) !=
            FileSystemEntityType.file) {
          return false;
        }
        if (f.layout.role == BackupFileRole.sidecar) {
          if (await local.length() > limits.maxSidecarBytes) return false;
          final mine = jsonDecode(await local.readAsString());
          if (mine is! Map<String, dynamic>) return false;
          if (LibraryBackup.sidecarDigest(mine) != sidecarDigest) return false;
          continue;
        }
        if (await local.length() != f.size) return false;
        final (digest, _) = await _hashFile(local, f.size);
        if (digest != f.sha256) return false;
      }
      return true;
    } catch (_) {
      return false; // unreadable: not provably the same, so keep both
    }
  }

  /// A version-8 (custom) UUID derived from the project's craft, id and file digests.
  static String _copyId(_ProjectAccumulator acc) {
    final listing = [for (final f in acc.files) '${f.layout.pathFor(acc.id)} ${f.sha256}']..sort();
    final digest = sha256.convert(utf8.encode(
        'ply.backup restored copy\n${acc.craft.manifestName}\n${acc.id}\n${listing.join('\n')}'));
    final b = digest.bytes.sublist(0, 16);
    b[6] = (b[6] & 0x0F) | 0x80;
    b[8] = (b[8] & 0x3F) | 0x80;
    final hex = b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
        '${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  /// The lowercase id stems (file name up to the first '.') of everything in [dir]: any file or
  /// folder there whose stem is an id (sidecar, document, thumbnail, photo folder, upgrade backup,
  /// leftover temp file) makes that id taken.
  static Future<Set<String>> _stems(Directory dir) async {
    if (!await dir.exists()) return <String>{};
    final stems = <String>{};
    await for (final ent in dir.list(followLinks: false)) {
      final name = p.basename(ent.path).toLowerCase();
      final dot = name.indexOf('.');
      stems.add(dot < 0 ? name : name.substring(0, dot));
    }
    return stems;
  }

  // --- Writing a restore ---------------------------------------------------------------------

  /// Restore [plan]: every [RestoreStatus.add] project, and every conflict whose key is not in
  /// [skippedConflicts] (as a copy). Files are copied from the archive into a staging folder (their
  /// digests checked again), then each project is moved into the library, sidecar last. On any
  /// failure everything placed so far is removed and a [BackupProblem.restoreFailed] is thrown: the
  /// library is exactly as it was. Afterwards thumbnails are rebuilt (best-effort).
  Future<RestoreResult> restore(RestorePlan plan, {Set<String> skippedConflicts = const {}}) async {
    final selected = [
      for (final project in plan.projects)
        if (project.status == RestoreStatus.add ||
            (project.status == RestoreStatus.conflict && !skippedConflicts.contains(project.key)))
          project,
    ];
    if (selected.isEmpty) return const RestoreResult([]);
    final docs = await documentsDir();
    await _sweepStaging(docs);
    final staging = Directory(p.join(docs.path, '$stagingPrefix${_uuid.v4()}'));
    final placed = <FileSystemEntity>[];
    final createdDirs = <Directory>[];
    try {
      await staging.create();
      final raf = await plan.archive.open();
      try {
        for (final project in selected) {
          await _stage(raf, staging, project);
        }
      } finally {
        await raf.close();
      }

      final stems = <BackupCraft, Set<String>>{};
      for (final project in selected) {
        final craft = project.craft;
        final dir = Directory(p.join(docs.path, craft.directory));
        if (!await dir.exists()) {
          await dir.create(recursive: true);
          createdDirs.add(dir);
        }
        final taken = stems[craft] ??= await _stems(dir);
        final id = project.targetId!;
        if (!taken.add(id.toLowerCase())) {
          throw StateError('${craft.directory}/$id appeared in the library during the restore');
        }
        // Document, upgrade backups, the photo folder (moved whole), and the sidecar LAST.
        final order = [
          ...project._files.where((f) => f.layout.role == BackupFileRole.native),
          ...project._files.where((f) => f.layout.role == BackupFileRole.upgradeBackup),
        ].map((f) => f.layout.pathFor(id)).toList();
        if (project.photoCount > 0) order.add('${craft.directory}/$id.photos');
        order.add('${craft.directory}/$id.json');
        for (final rel in order) {
          final from = p.joinAll([staging.path, ...rel.split('/')]);
          final to = p.joinAll([docs.path, ...rel.split('/')]);
          await beforePlace?.call(to);
          if (await FileSystemEntity.type(to, followLinks: false) !=
              FileSystemEntityType.notFound) {
            throw StateError('$rel appeared in the library during the restore');
          }
          final isFolder = rel.endsWith('.photos');
          placed.add(isFolder
              ? await Directory(from).rename(to)
              : await File(from).rename(to));
        }
      }
    } catch (e) {
      await _rollback(placed, createdDirs);
      await _deleteQuietly(staging);
      PlyLog.instance.error('Restore failed and was rolled back: $e');
      throw BackupException(BackupProblem.restoreFailed, detail: '$e');
    }
    await _deleteQuietly(staging);

    final restored = [for (final s in selected) (craft: s.craft, id: s.targetId!)];
    PlyLog.instance.info('Restored ${restored.length} projects from a backup.');
    final rebuild = rebuildThumbnail;
    if (rebuild != null) {
      for (final r in restored) {
        if (r.craft == BackupCraft.nalbinding) continue; // nalbinding has no thumbnail
        try {
          await rebuild(r.craft, r.id);
        } catch (e) {
          PlyLog.instance.warn('Could not rebuild the thumbnail of ${r.id}: $e');
        }
      }
    }
    return RestoreResult(restored);
  }

  /// Copy [project]'s files out of the archive into [staging], under its target id. Each digest is
  /// checked again (the archive could have changed since it was inspected). A copy's sidecar gets
  /// its new name; every other file is written byte for byte.
  Future<void> _stage(RandomAccessFile raf, Directory staging, RestoreProject project) async {
    final id = project.targetId!;
    final rename = project.status == RestoreStatus.conflict;
    for (final f in project._files) {
      final dest = File(p.joinAll([staging.path, ...f.layout.pathFor(id).split('/')]));
      await dest.parent.create(recursive: true);
      if (rename && f.layout.role == BackupFileRole.sidecar) {
        final (digest, bytes) = await _hashSlice(raf, f.dataOffset, f.size, keep: true);
        if (digest != f.sha256) throw StateError('${f.layout.pathFor(project.id)} changed');
        final json = jsonDecode(utf8.decode(bytes!)) as Map<String, dynamic>;
        json['name'] = project.targetName;
        await dest.writeAsString(jsonEncode(json), flush: true);
        continue;
      }
      final out = await dest.open(mode: FileMode.writeOnly);
      try {
        final (digest, _) = await _hashSlice(raf, f.dataOffset, f.size, copyTo: out);
        if (digest != f.sha256) throw StateError('${f.layout.pathFor(project.id)} changed');
        await out.flush();
      } finally {
        await out.close();
      }
    }
  }

  /// Remove what a failed restore placed, newest first, and the craft folders it created (when
  /// empty). Everything placed was at a path that did not exist before, so removing it restores the
  /// library exactly.
  Future<void> _rollback(List<FileSystemEntity> placed, List<Directory> createdDirs) async {
    for (final ent in placed.reversed) {
      try {
        await ent.delete(recursive: ent is Directory);
      } catch (e) {
        PlyLog.instance.error('Restore rollback could not remove ${ent.path}: $e');
      }
    }
    for (final dir in createdDirs.reversed) {
      try {
        if (await dir.list().isEmpty) await dir.delete();
      } catch (_) {/* best-effort: an empty craft folder is harmless */}
    }
  }

  /// Remove staging folders a crashed restore left behind (they hold nothing the library lists).
  Future<void> _sweepStaging(Directory docs) async {
    try {
      if (!await docs.exists()) return;
      await for (final ent in docs.list(followLinks: false)) {
        if (ent is Directory && p.basename(ent.path).startsWith(stagingPrefix)) {
          await _deleteQuietly(ent);
        }
      }
    } catch (_) {/* best-effort */}
  }

  static Future<void> _deleteQuietly(Directory dir) async {
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (e) {
      PlyLog.instance.warn('Could not remove ${dir.path}: $e');
    }
  }

  // --- Hashing -------------------------------------------------------------------------------

  /// SHA-256 (lowercase hex) and length of [file], reading at most [max] + 1 bytes so an oversized
  /// file is noticed without reading it all.
  static Future<(String, int)> _hashFile(File file, int max) async {
    final sink = _DigestSink();
    final input = sha256.startChunkedConversion(sink);
    var total = 0;
    await for (final chunk in file.openRead(0, max + 1)) {
      input.add(chunk);
      total += chunk.length;
    }
    input.close();
    return (sink.value!.toString(), total);
  }

  /// SHA-256 (lowercase hex) of [bytes], a megabyte at a time with a yield in between, so a large
  /// photo does not stall the UI (the progress indicator keeps moving).
  static Future<String> _hashBytes(Uint8List bytes) async {
    final sink = _DigestSink();
    final input = sha256.startChunkedConversion(sink);
    for (var start = 0; start < bytes.length; start += _mib) {
      if (start > 0) await Future<void>.delayed(Duration.zero);
      final end = start + _mib < bytes.length ? start + _mib : bytes.length;
      input.add(Uint8List.sublistView(bytes, start, end));
    }
    input.close();
    return sink.value!.toString();
  }

  /// SHA-256 of [size] bytes at [offset] of [raf], optionally copied to [copyTo] and/or kept.
  static Future<(String, Uint8List?)> _hashSlice(RandomAccessFile raf, int offset, int size,
      {RandomAccessFile? copyTo, bool keep = false}) async {
    final sink = _DigestSink();
    final input = sha256.startChunkedConversion(sink);
    final kept = keep ? BytesBuilder(copy: false) : null;
    var position = offset;
    var remaining = size;
    while (remaining > 0) {
      await raf.setPosition(position);
      final chunk = await raf.read(remaining < _chunk ? remaining : _chunk);
      if (chunk.isEmpty) {
        throw const UstarFormatException(UstarProblem.truncated, 'the archive ends early');
      }
      input.add(chunk);
      await copyTo?.writeFrom(chunk);
      kept?.add(chunk);
      position += chunk.length;
      remaining -= chunk.length;
    }
    input.close();
    return (sink.value!.toString(), kept?.takeBytes());
  }

  static Future<Uint8List> _readSlice(RandomAccessFile raf, int offset, int size) async {
    final (_, bytes) = await _hashSlice(raf, offset, size, keep: true);
    return bytes!;
  }
}

/// Everything read for one project while checking an archive.
class _ProjectAccumulator {
  _ProjectAccumulator(this.craft, this.id);

  final BackupCraft craft;
  final String id;
  final List<_ArchivedFile> files = [];
  bool hasNative = false;
  bool hasSidecar = false;
  bool newer = false;
  bool unreadable = false;
  String? name;

  /// [LibraryBackup.sidecarDigest] of the sidecar, as is and renamed for a copy.
  String? sidecarDigest;
  String? copySidecarDigest;
}

class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
