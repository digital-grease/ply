// Portable backup and restore of the on-device library (roadmap M7-07; see the backup ADR).
//
// A backup is one `.plybackup` file: an UNCOMPRESSED POSIX ustar archive (see `ustar.dart`) whose
// first entry is `manifest.json`, followed by every project's files copied VERBATIM from the library:
//
//   drafts/<id>.wif + drafts/<id>.json
//   knits/<id>.plyknit + knits/<id>.json + knits/<id>.plyknit.v<n>.bak (format-upgrade backups)
//   nalbinds/<id>.plynal + nalbinds/<id>.json + nalbinds/<id>.photos/<name>.<ext>
//
// A full backup may also carry `app_settings.json` (opt-in, the settings in effect), `looms.json`
// (the weaver's loom profiles, whenever there are any; ADR 0014) and `materials.json` with every
// swatch's photos under `swatches/<id>.photos/` (the materials and swatches, whenever there are any;
// ADR 0016, see `library_backup_materials.dart`); a single-project export is the same format holding
// one project and never the settings, the looms or the materials. Thumbnails (`<id>.png`) are
// rebuildable caches and are left out; a restore rebuilds them.
//
// A restore treats the file as hostile until every check has passed: hard limits on size, entry
// count, entry size and path length; only regular files at paths of the layout above (no absolute
// paths, `..`, backslashes, duplicates, links or devices); every entry listed in the manifest with
// its size and SHA-256, and every SHA-256 verified; no newer backup schema; and each project's files
// checked with the existing format probes (a project newer than this build is refused, with the
// reason), as are the app settings (offered only when they parse as the settings model). Only then
// is a preview built, and nothing in the library is written until the user confirms it. The commit
// stages every file inside the documents directory, then moves each project into place with its
// sidecar LAST (the library lists sidecars), applies the app settings only if the user ticked them,
// and on any failure removes what it placed, so the library is left exactly as it was. Existing
// projects are never overwritten: one with the same id and different content is restored as a copy
// under a new id, and the copy's name is the only thing rewritten (in its sidecar, and for
// nalbinding also in its `.plynal`, which carries the name the project screen shows).

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../diagnostics/log_buffer.dart';
import '../models/app_settings.dart';
import '../models/draft_meta.dart';
import '../models/loom_profile.dart';
import '../models/material_record.dart';
import '../models/nalbind_project.dart';
import '../models/native_format.dart';
import '../models/project_materials.dart';
import 'app_settings_repository.dart';
import 'loom_repository.dart' show LoomFileException, LoomFileProblem;
import 'materials_repository.dart'
    show MaterialLibrary, MaterialsFileException, MaterialsFileProblem;
import 'ustar.dart';

part 'library_backup_materials.dart';

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

/// The app settings entry a full backup may carry, at the archive root (the same name the settings
/// file has in the documents directory). It is the only path outside a craft folder a backup holds.
const String backupSettingsPath = 'app_settings.json';

/// The loom profiles a full backup carries, at the archive root (the same name as the file beside
/// the craft folders; ADR 0014).
const String backupLoomsPath = 'looms.json';

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
    this.maxSettingsBytes = 64 * 1024,
    this.maxLoomsBytes = _mib,
    this.maxMaterialsBytes = 2 * _mib,
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

  /// The largest app settings entry. The file Ply writes is about a hundred bytes.
  final int maxSettingsBytes;

  /// The largest `looms.json` entry (the engine reads at most 1 MB).
  final int maxLoomsBytes;

  /// The largest `materials.json` entry (the engine reads at most 2 MB).
  final int maxMaterialsBytes;

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
  // Exporting one project.
  projectNotFound,
  projectTooLarge,
  projectTooManyFiles,
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
        BackupProblem.projectNotFound => 'This project is no longer in your library.',
        BackupProblem.projectTooLarge =>
          'This project is too large for one file on this device (over ${formatBytes(limit ?? 0)}).',
        BackupProblem.projectTooManyFiles =>
          'This project has too many files for one export (over ${limit ?? 0}).',
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

  /// The [backupSettingsPath] entry, which belongs to no project.
  const BackupManifestFile.settings({required this.size, required this.sha256})
      : path = backupSettingsPath,
        craft = null,
        projectId = null;

  /// The [backupLoomsPath] entry, which belongs to no project.
  const BackupManifestFile.looms({required this.size, required this.sha256})
      : path = backupLoomsPath,
        craft = null,
        projectId = null;

  /// The [backupMaterialsPath] entry, or a swatch photo at [path]: no project either.
  const BackupManifestFile.library({required this.path, required this.size, required this.sha256})
      : craft = null,
        projectId = null;

  final String path;
  final int size;

  /// Lowercase hex.
  final String sha256;

  /// The project's craft and id; both null for the app settings entry (which has neither key).
  final BackupCraft? craft;
  final String? projectId;

  Map<String, Object?> toJson() => {
        'path': path,
        'size': size,
        'sha256': sha256,
        if (craft != null) 'craft': craft!.manifestName,
        if (projectId != null) 'project': projectId,
      };
}

/// What a backup file holds, recorded in the manifest's optional `contents` key ("library" or
/// "project"). Informational only: a restore never reads it (a single-project export restores
/// exactly like a full backup), so adding it kept the manifest at schema version 1.
enum BackupContents {
  /// A full backup from Settings: every project, and the app settings if the user chose.
  library,

  /// A single-project export from a library's project actions.
  project,
}

/// The `manifest.json` that opens every backup.
class BackupManifest {
  const BackupManifest({
    required this.createdAt,
    required this.appVersion,
    required this.files,
    this.contents,
  });

  /// The `format` value of every backup manifest.
  static const String format = 'ply.backup';

  /// The manifest schema this build writes, and the newest it reads.
  static const int currentSchemaVersion = 1;

  final DateTime createdAt;
  final String appVersion;
  final List<BackupManifestFile> files;

  /// Written by an export; [parse] leaves it null (a restore ignores the key).
  final BackupContents? contents;

  Map<String, Object?> toJson() => {
        'format': format,
        'schema_version': currentSchemaVersion,
        'created_at': createdAt.toUtc().toIso8601String(),
        'app_version': appVersion,
        if (contents != null) 'contents': contents!.name,
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
      final isSettings = path == backupSettingsPath;
      final isLooms = path == backupLoomsPath;
      final isMaterials = path == backupMaterialsPath;
      final swatchPhoto = classifySwatchPhotoPath(path);
      final classified = (isSettings || isLooms || isMaterials || swatchPhoto != null)
          ? null
          : classifyLibraryPath(path);
      if (!isSettings && !isLooms && !isMaterials && swatchPhoto == null && classified == null) {
        throw BackupException(BackupProblem.unsafe, detail: 'manifest path $path');
      }
      // Case-insensitively unique: on a case-insensitive file system two such paths are one file.
      if (!seen.add(path.toLowerCase())) {
        throw BackupException(BackupProblem.unsafe, detail: 'duplicate manifest path $path');
      }
      if (classified == null) {
        // The app settings, the looms, the materials or a swatch photo: no project, and a limit of
        // their own.
        if (craftName != null || project != null) throw damaged('craft or project of $path');
        final max = isLooms
            ? limits.maxLoomsBytes
            : isMaterials
                ? limits.maxMaterialsBytes
                : swatchPhoto != null
                    ? limits.maxFileBytes
                    : limits.maxSettingsBytes;
        if (size > max) {
          throw BackupException(BackupProblem.unsafe, detail: '$path is $size bytes');
        }
        files.add(isLooms
            ? BackupManifestFile.looms(size: size, sha256: digest)
            : (isMaterials || swatchPhoto != null)
                ? BackupManifestFile.library(path: path, size: size, sha256: digest)
                : BackupManifestFile.settings(size: size, sha256: digest));
        continue;
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

/// The app settings a full backup can carry: the `app_settings.json` it writes, encoded the way
/// `AppSettingsRepository.save` writes the file.
class BackupSettingsFile {
  factory BackupSettingsFile.of(AppSettings settings) {
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(settings.toJson())));
    return BackupSettingsFile._(bytes, _hexSha256(bytes));
  }

  const BackupSettingsFile._(this.bytes, this.sha256);

  final Uint8List bytes;

  /// Lowercase hex.
  final String sha256;
}

/// The loom profiles a full backup carries: the `looms.json` bytes, verbatim, and how many looms
/// they hold (for the summary).
class BackupLoomsFile {
  BackupLoomsFile(this.bytes, this.count) : sha256 = _hexSha256(bytes);

  final Uint8List bytes;
  final int count;

  /// Lowercase hex.
  final String sha256;
}

/// Lowercase hex SHA-256 of a small byte list (files are hashed in chunks instead).
String _hexSha256(List<int> bytes) => sha256.convert(bytes).toString();

/// A backup ready to be written: every file hashed and the manifest built. [archiveSize] is the
/// exact size of the file [LibraryBackup.buildBackup] makes from it.
class BackupPlan {
  BackupPlan({
    required this.createdAt,
    required this.appVersion,
    required this.files,
    required this.projectCounts,
    required this.photoCount,
    this.contents = BackupContents.library,
    this.projectName,
    this.settings,
    this.includeSettings = false,
    this.looms,
    this.loomsLeftOut,
    this.materials,
    this.swatchPhotos = const [],
    this.materialsLeftOut,
    this.setAsideLeftOut = const [],
  });

  final DateTime createdAt;
  final String appVersion;
  final List<BackupFile> files;
  final Map<BackupCraft, int> projectCounts;
  final int photoCount;
  final BackupContents contents;

  /// The project of a single-project export (names its file).
  final String? projectName;

  /// The app settings this backup can carry (a full backup only), and whether it does.
  final BackupSettingsFile? settings;
  final bool includeSettings;

  /// Whether the file made from this plan holds `app_settings.json`.
  bool get carriesSettings => includeSettings && settings != null;

  /// The loom profiles this backup carries (a full backup, when the weaver has any).
  final BackupLoomsFile? looms;

  /// Why My looms is not in this backup although the weaver has a looms file (one of the sentences
  /// below), or null. The backup summary shows it.
  final String? loomsLeftOut;

  static const String loomsNewer = 'My looms was saved by a newer version of Ply, so it is not in '
      'this backup.';
  static const String loomsUnreadable = 'My looms could not be read, so it is not in this backup.';
  static const String loomsTooLarge = 'My looms is too large to back up, so it is not in this '
      'backup.';

  /// The materials and swatches this backup carries (a full backup, when there are any), and the
  /// swatches' photos.
  final BackupMaterialsFile? materials;
  final List<BackupSwatchPhoto> swatchPhotos;

  /// Why the materials are not in this backup although there is a materials file, or null.
  final String? materialsLeftOut;

  /// The unreadable copies of `looms.json` and `materials.json` an earlier load moved aside
  /// (`.corrupt`), which a backup never carries (a restore could not read them), in sentences for the
  /// summary.
  final List<String> setAsideLeftOut;

  static const String materialsNewer = 'Your materials were saved by a newer version of Ply, so '
      'they are not in this backup.';
  static const String materialsUnreadable =
      'Your materials could not be read, so they are not in this backup.';
  static const String materialsTooLarge =
      'Your materials are too large to back up, so they are not in this backup.';

  /// This plan with the app settings in or out (the backup summary's checkbox).
  BackupPlan withSettings(bool include) => BackupPlan(
        createdAt: createdAt,
        appVersion: appVersion,
        files: files,
        projectCounts: projectCounts,
        photoCount: photoCount,
        contents: contents,
        projectName: projectName,
        settings: settings,
        includeSettings: include,
        looms: looms,
        loomsLeftOut: loomsLeftOut,
        materials: materials,
        swatchPhotos: swatchPhotos,
        materialsLeftOut: materialsLeftOut,
        setAsideLeftOut: setAsideLeftOut,
      );

  int get projectCount => projectCounts.values.sum;

  BackupManifest get manifest => BackupManifest(
        createdAt: createdAt,
        appVersion: appVersion,
        contents: contents,
        files: [
          if (carriesSettings)
            BackupManifestFile.settings(size: settings!.bytes.length, sha256: settings!.sha256),
          if (looms != null)
            BackupManifestFile.looms(size: looms!.bytes.length, sha256: looms!.sha256),
          if (materials != null)
            BackupManifestFile.library(
                path: backupMaterialsPath,
                size: materials!.bytes.length,
                sha256: materials!.sha256),
          for (final f in swatchPhotos)
            BackupManifestFile.library(path: f.archivePath, size: f.size, sha256: f.sha256),
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

  late final Uint8List manifestBytes = manifest.encode();

  int get archiveSize =>
      ustarEntryLength(manifestBytes.length) +
      (carriesSettings ? ustarEntryLength(settings!.bytes.length) : 0) +
      (looms != null ? ustarEntryLength(looms!.bytes.length) : 0) +
      (materials != null ? ustarEntryLength(materials!.bytes.length) : 0) +
      swatchPhotos.fold<int>(0, (sum, f) => sum + ustarEntryLength(f.size)) +
      files.fold<int>(0, (sum, f) => sum + ustarEntryLength(f.size)) +
      ustarEndLength;

  /// The suggested file name (local date): `ply-library-<yyyy-mm-dd>.plybackup` for a full backup,
  /// `<project name> <yyyy-mm-dd>.plybackup` for a single-project export.
  String get fileName {
    final d = createdAt.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    final date = '${d.year}-${two(d.month)}-${two(d.day)}';
    return contents == BackupContents.project
        ? '${safeFileStem(projectName ?? '')} $date.plybackup'
        : 'ply-library-$date.plybackup';
  }

  /// [name] as a file name every platform accepts: path separators, reserved and control characters
  /// become '-', runs of white space one space, no leading or trailing dots or spaces, at most 60
  /// characters; "project" when nothing is left.
  @visibleForTesting
  static String safeFileStem(String name) {
    var s = name
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F\x7F]'), '-')
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r'^[\s.]+|[\s.]+$'), '');
    if (s.runes.length > 60) {
      s = String.fromCharCodes(s.runes.take(60)).replaceAll(RegExp(r'[\s.]+$'), '');
    }
    return s.isEmpty ? 'project' : s;
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
    this.loomPlanId,
    this.linkedMaterials = const {},
    this.linkedSwatches = const {},
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

  /// For a weaving draft planned for a loom, that loom's id in the backup (its sidecar's
  /// `loomPlan.loomId`): when the restore adds that loom as a copy, the draft is pointed at the copy.
  final String? loomPlanId;

  /// The material and swatch ids the project's sidecar links (ADR 0016): when the restore adds one
  /// as a copy, the project is pointed at the copy.
  final Set<String> linkedMaterials;
  final Set<String> linkedSwatches;

  final List<_ArchivedFile> _files;

  /// A key unique within a backup.
  String get key => '${craft.manifestName}/$id';

  int get photoCount => _files.where((f) => f.layout.role == BackupFileRole.photo).length;
}

/// The app settings of a backup, as the restore preview offers them: [settings] when they can be
/// restored, otherwise the [refusal] sentence. They are applied only when the user ticks them.
class RestoreSettings {
  const RestoreSettings.available(AppSettings this.settings) : refusal = null;
  const RestoreSettings.refused(String this.refusal) : settings = null;

  final AppSettings? settings;
  final String? refusal;

  /// The reason for settings that are not a settings model (not UTF-8, not a JSON object, or a
  /// field of the wrong type).
  static const String unreadable = 'The app settings in this backup could not be read.';
}

/// One loom of a backup, as the restore preview shows it (ADR 0014).
class RestoreLoom {
  const RestoreLoom(this.loom, this.status, this.target,
      {this.copyId, this.drafts = 0, this.localName});

  /// The loom as the backup has it.
  final LoomProfile loom;

  /// [RestoreStatus.add] (not in My looms), [RestoreStatus.alreadyPresent] (the same loom, field for
  /// field) or [RestoreStatus.conflict] (a different loom with its id: added as a copy).
  final RestoreStatus status;

  /// What a restore adds: the loom itself, or for a conflict a copy under a new id named
  /// "<name> (restored)"; null when nothing is added.
  final LoomProfile? target;

  /// The id of the copy that stands for this loom in My looms: the copy a conflict adds, or the copy
  /// an earlier restore of this backup made (then the loom is already present). Drafts restored from
  /// this backup that name the loom are pointed at it. Null when no copy is involved.
  final String? copyId;

  /// How many drafts restored from this backup name this loom (and so use the copy, when one is
  /// added).
  final int drafts;

  /// For a conflict: the name of the different loom My looms holds under this id (null when none).
  /// Unticking the copy leaves the restored drafts planned for that loom, and the preview says so.
  final String? localName;

  /// A key unique within a backup (the loom's id there).
  String get key => loom.id;

  RestoreLoom _withDrafts(int n) =>
      RestoreLoom(loom, status, target, copyId: copyId, drafts: n, localName: localName);
}

/// The looms of a backup: [items] when they can be restored, otherwise the [refusal] sentence.
class RestoreLooms {
  const RestoreLooms.available(this.items) : refusal = null;
  const RestoreLooms.refused(String this.refusal) : items = const [];

  final List<RestoreLoom> items;
  final String? refusal;

  List<RestoreLoom> withStatus(RestoreStatus status) =>
      [for (final i in items) if (i.status == status) i];

  /// The copies drafts must point at when [skipped] conflicts are left out: the backup's loom id to
  /// the copy's id and name, for every copy that is (or already was) in My looms.
  Map<String, (String, String)> relinks(Set<String> skipped) => {
        for (final i in items)
          if (i.copyId != null &&
              (i.status == RestoreStatus.alreadyPresent ||
                  (i.status == RestoreStatus.conflict && !skipped.contains(i.key))))
            i.key: (i.copyId!, i.target?.name ?? LibraryBackup.loomCopyName(i.loom.name)),
      };

  /// The looms a restore adds: every new one, and every conflict whose key is not in [skipped].
  List<LoomProfile> selected(Set<String> skipped) => [
        for (final i in items)
          if (i.target != null &&
              (i.status == RestoreStatus.add ||
                  (i.status == RestoreStatus.conflict && !skipped.contains(i.key))))
            i.target!,
      ];

  static const String unreadable = 'The looms in this backup could not be read.';
  static const String newer = 'The looms in this backup were saved by a newer version of Ply. '
      'Update the app to restore them.';
  static const String localUnreadable =
      'Your looms on this device could not be read, so the looms in this backup cannot be added.';
  static const String tooMany =
      'Adding these looms would pass ${LoomLimits.maxLooms} looms, so they cannot be restored.';
  static const String unsupported = 'This version of Ply cannot restore looms.';
}

/// A checked backup, ready to preview and restore. Nothing has been written yet.
class RestorePlan {
  const RestorePlan({
    required this.archive,
    required this.createdAt,
    required this.appVersion,
    required this.projects,
    this.settings,
    this.looms,
    this.materials,
  });

  /// The backup file. It must stay in place until [LibraryBackup.restore] returns.
  final File archive;
  final DateTime createdAt;
  final String appVersion;
  final List<RestoreProject> projects;

  /// The backup's app settings; null when it has none.
  final RestoreSettings? settings;

  /// The backup's loom profiles; null when it has none.
  final RestoreLooms? looms;

  /// The backup's materials and swatches; null when it has none.
  final RestoreMaterials? materials;

  List<RestoreProject> forCraft(BackupCraft craft, RestoreStatus status) =>
      [for (final p in projects) if (p.craft == craft && p.status == status) p];
}

/// What a restore wrote.
class RestoreResult {
  const RestoreResult(this.restored,
      {this.settingsRestored = false,
      this.loomsRestored = 0,
      this.draftsRelinked = 0,
      this.materialsRestored = 0,
      this.swatchesRestored = 0,
      this.projectsRelinkedToMaterials = 0});

  /// The projects now in the library, with their final ids.
  final List<({BackupCraft craft, String id})> restored;

  /// Whether the backup's app settings were applied.
  final bool settingsRestored;

  /// How many looms were added to My looms.
  final int loomsRestored;

  /// How many restored drafts were pointed at the restored copy of their loom.
  final int draftsRelinked;

  /// How many materials and swatches were added.
  final int materialsRestored;
  final int swatchesRestored;

  /// How many restored projects were pointed at a restored copy of a material or swatch.
  final int projectsRelinkedToMaterials;

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

/// What a backup needs from My looms (ADR 0014). Production wires the loom repository and the
/// engine's `looms.json` reader; host tests pass stand-ins.
class LoomBackupHooks {
  const LoomBackupHooks({
    required this.currentFile,
    required this.decode,
    required this.currentLooms,
    required this.add,
  });

  /// The `looms.json` bytes to back up, verbatim, or null when there is none.
  final Future<Uint8List?> Function() currentFile;

  /// The looms in `looms.json` bytes (untrusted). Throws (a [LoomFileException] says why).
  final Future<List<LoomProfile>> Function(Uint8List bytes) decode;

  /// The looms in My looms now. Throws when My looms cannot be read.
  final Future<List<LoomProfile>> Function() currentLooms;

  /// Add looms to My looms in one write and return how to undo it exactly.
  final Future<Future<void> Function()> Function(List<LoomProfile> looms) add;
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
    this.currentSettings,
    this.applySettings,
    this.looms,
    this.materials,
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

  /// The app settings in effect, offered for a full backup. Null: backups never carry settings.
  final Future<AppSettings> Function()? currentSettings;

  /// Applies restored app settings (production persists them first, then updates the app). Throwing
  /// rolls the whole restore back. Null: settings cannot be restored.
  final Future<void> Function(AppSettings settings)? applySettings;

  /// My looms, which a full backup carries and a restore adds to. Null: backups carry no looms, and
  /// a backup with looms restores its projects only.
  final LoomBackupHooks? looms;

  /// The materials and swatches, which a full backup carries (with the swatches' photos) and a
  /// restore adds to (ADR 0016). Null: backups carry none, and a backup with them restores the rest.
  final MaterialBackupHooks? materials;
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

  /// Find and hash every project in the library, and offer the app settings in effect. Throws a
  /// [BackupException] for an empty library and for one over the limits (naming the project of an
  /// oversized file). The plan includes the settings when there are any; the summary may leave them
  /// out with [BackupPlan.withSettings].
  Future<BackupPlan> planBackup() async {
    final docs = await documentsDir();
    final files = <BackupFile>[];
    final counts = {for (final c in BackupCraft.values) c: 0};
    var photos = 0;
    for (final craft in BackupCraft.values) {
      final names = await _listing(Directory(p.join(docs.path, craft.directory)));
      final ids = [
        for (final e in names.entries)
          if (e.value is File && e.key.endsWith('.json')) e.key.substring(0, e.key.length - 5),
      ]..sort();
      for (final id in ids) {
        if (!isBackupProjectId(id)) {
          PlyLog.instance.warn('Backup: skipped ${craft.directory}/$id.json (not a Ply id).');
          continue;
        }
        final project = await _collectProject(craft, id, names);
        if (project == null) continue; // the library does not list it either
        files.addAll(project.files);
        photos += project.photos;
        counts[craft] = counts[craft]! + 1;
        if (files.length + 1 > limits.maxEntries) {
          throw BackupException(BackupProblem.libraryTooManyFiles, limit: limits.maxEntries);
        }
      }
    }
    final (loomsFile, loomsLeftOut) = await _loomsFile();
    final (materialsFile, swatchPhotos, materialsLeftOut) = await _materialsFile(docs);
    if (files.isEmpty && loomsFile == null && materialsFile == null) {
      throw const BackupException(BackupProblem.noProjects);
    }
    if (files.length + swatchPhotos.length + 4 > limits.maxEntries) {
      throw BackupException(BackupProblem.libraryTooManyFiles, limit: limits.maxEntries);
    }
    final settings = await _settingsFile();
    return _checked(BackupPlan(
      createdAt: _clock(),
      appVersion: appVersion,
      files: files,
      projectCounts: counts,
      photoCount: photos,
      settings: settings,
      includeSettings: settings != null,
      looms: loomsFile,
      loomsLeftOut: loomsLeftOut,
      materials: materialsFile,
      swatchPhotos: swatchPhotos,
      materialsLeftOut: materialsLeftOut,
      setAsideLeftOut: await _setAsideCopies(docs),
    ));
  }

  /// The summary's sentences for the `.corrupt` copies of `looms.json` and `materials.json` in [docs]
  /// (ADR 0014 and 0016: never backed up, since a restore could not read them; kept on the device).
  Future<List<String>> _setAsideCopies(Directory docs) async {
    var looms = 0;
    var materialFiles = 0;
    try {
      await for (final ent in docs.list(followLinks: false)) {
        if (ent is! File) continue;
        final name = p.basename(ent.path);
        if (name.startsWith('$backupLoomsPath.corrupt')) looms++;
        if (name.startsWith('$backupMaterialsPath.corrupt')) materialFiles++;
      }
    } catch (_) {/* best effort: the summary just says nothing */}
    String sentence(int n, String what, String file) => n == 1
        ? 'An unreadable copy of $what, kept as $file.corrupt, is not in this backup.'
        : '$n unreadable copies of $what, kept as $file.corrupt, are not in this backup.';
    return [
      if (looms > 0) sentence(looms, 'My looms', backupLoomsPath),
      if (materialFiles > 0) sentence(materialFiles, 'your materials', backupMaterialsPath),
    ];
  }

  /// Plan a single-project export: the same format, layout and limits as a full backup, holding just
  /// the project [id] of [craft] (never the app settings). "Restore from backup" imports it like any
  /// backup. Throws [BackupProblem.projectNotFound] when the library does not list that project.
  Future<BackupPlan> planProjectBackup(BackupCraft craft, String id) async {
    if (!isBackupProjectId(id)) throw const BackupException(BackupProblem.projectNotFound);
    final docs = await documentsDir();
    final names = await _listing(Directory(p.join(docs.path, craft.directory)));
    if (names['$id.json'] is! File) throw const BackupException(BackupProblem.projectNotFound);
    final project = await _collectProject(craft, id, names);
    if (project == null) throw const BackupException(BackupProblem.projectNotFound);
    if (project.files.length + 1 > limits.maxEntries) {
      throw BackupException(BackupProblem.projectTooManyFiles, limit: limits.maxEntries);
    }
    return _checked(BackupPlan(
      createdAt: _clock(),
      appVersion: appVersion,
      files: project.files,
      projectCounts: {for (final c in BackupCraft.values) c: c == craft ? 1 : 0},
      photoCount: project.photos,
      contents: BackupContents.project,
      projectName: project.name,
    ));
  }

  /// Every entry of a craft folder by file name (links are listed, never followed); empty when the
  /// folder does not exist.
  static Future<Map<String, FileSystemEntity>> _listing(Directory dir) async {
    final names = <String, FileSystemEntity>{};
    if (!await dir.exists()) return names;
    await for (final ent in dir.list(followLinks: false)) {
      names[p.basename(ent.path)] = ent;
    }
    return names;
  }

  /// The files of project [id] of [craft] (from its folder's [names]), hashed, sidecar last, or null
  /// when the library would not list it (no native file, or a sidecar it cannot read). Throws
  /// [BackupProblem.fileTooLarge] for a file over its limit.
  Future<({List<BackupFile> files, int photos, String name})?> _collectProject(
      BackupCraft craft, String id, Map<String, FileSystemEntity> names) async {
    final native = names['$id.${craft.nativeExtension}'];
    final sidecar = names['$id.json'];
    if (native is! File || sidecar is! File) return null;
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
      return null; // an unreadable sidecar: the library does not list it either
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
    var photos = 0;
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
      photos = found.length;
    }
    layoutFiles.add((LibraryPath._(craft, id, BackupFileRole.sidecar), sidecar));

    final files = <BackupFile>[];
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
    return (files: files, photos: photos, name: name);
  }

  /// The app settings in effect as the `app_settings.json` a backup writes, or null when there is no
  /// settings source or they could not be read (the backup is then made without them).
  Future<BackupSettingsFile?> _settingsFile() async {
    final read = currentSettings;
    if (read == null) return null;
    try {
      final file = BackupSettingsFile.of(await read());
      return file.bytes.length <= limits.maxSettingsBytes ? file : null;
    } catch (e) {
      PlyLog.instance.warn('Backup: app settings left out ($e).');
      return null;
    }
  }

  /// My looms as the `looms.json` a full backup carries (verbatim), or null when there are none.
  /// When the file cannot be read, is newer, or is over its limit, the backup is made without it (a
  /// restore would refuse it anyway) and the second value says why, for the backup summary.
  Future<(BackupLoomsFile?, String?)> _loomsFile() async {
    final hooks = looms;
    if (hooks == null) return (null, null);
    try {
      final bytes = await hooks.currentFile();
      if (bytes == null) return (null, null);
      if (bytes.length > limits.maxLoomsBytes) {
        PlyLog.instance.warn('Backup: looms.json left out (${bytes.length} bytes).');
        return (null, BackupPlan.loomsTooLarge);
      }
      final count = (await hooks.decode(bytes)).length;
      return (count == 0 ? null : BackupLoomsFile(bytes, count), null);
    } on LoomFileException catch (e) {
      PlyLog.instance.warn('Backup: looms left out ($e).');
      return (
        null,
        switch (e.problem) {
          LoomFileProblem.newerVersion => BackupPlan.loomsNewer,
          LoomFileProblem.tooLarge => BackupPlan.loomsTooLarge,
          LoomFileProblem.unreadable => BackupPlan.loomsUnreadable,
        },
      );
    } catch (e) {
      PlyLog.instance.warn('Backup: looms left out ($e).');
      return (null, BackupPlan.loomsUnreadable);
    }
  }

  /// [plan], once it is within the export limits with the app settings included (the larger
  /// variant), so Ply never hands out a file it would refuse to restore.
  BackupPlan _checked(BackupPlan plan) {
    final largest = plan.withSettings(true);
    if (largest.manifestBytes.length > limits.maxManifestBytes ||
        largest.archiveSize > limits.maxExportBytes) {
      throw BackupException(
        plan.contents == BackupContents.project
            ? BackupProblem.projectTooLarge
            : BackupProblem.libraryTooLarge,
        limit: limits.maxExportBytes,
      );
    }
    return plan;
  }

  /// Write the backup file for [plan] into memory: the manifest, the app settings when the plan
  /// carries them, then every file, read again and checked against the digest the manifest records.
  /// Throws [BackupProblem.libraryChanged] when a file changed since it was planned.
  Future<Uint8List> buildBackup(BackupPlan plan) async {
    final out = Uint8List(plan.archiveSize);
    final mtime = plan.createdAt.millisecondsSinceEpoch ~/ 1000;
    var offset = 0;
    void header(String path, int size) {
      out.setRange(offset, offset + ustarBlockSize,
          UstarHeader.file(path, size, modified: mtime).encode());
      offset += ustarBlockSize;
    }

    void data(Uint8List bytes) {
      out.setRange(offset, offset + bytes.length, bytes);
      offset += bytes.length + ustarPadding(bytes.length);
    }

    header(backupManifestPath, plan.manifestBytes.length);
    data(plan.manifestBytes);
    if (plan.carriesSettings) {
      final settings = plan.settings!.bytes;
      header(backupSettingsPath, settings.length);
      data(settings);
    }
    final loomsFile = plan.looms;
    if (loomsFile != null) {
      header(backupLoomsPath, loomsFile.bytes.length);
      data(loomsFile.bytes);
    }
    final materialsFile = plan.materials;
    if (materialsFile != null) {
      header(backupMaterialsPath, materialsFile.bytes.length);
      data(materialsFile.bytes);
    }

    for (final f in [
      ...plan.swatchPhotos.map((s) => (archivePath: s.archivePath, sourcePath: s.sourcePath,
          size: s.size, sha256: s.sha256)),
      ...plan.files.map((f) => (archivePath: f.archivePath, sourcePath: f.sourcePath,
          size: f.size, sha256: f.sha256)),
    ]) {
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
  /// restore is returned as [RestoreStatus.refused] with its reason instead, and app settings that
  /// are not a settings model as [RestoreSettings.refused]. A single-project export is checked and
  /// previewed exactly like a full backup.
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
      final (manifest, accumulators, settings, loomBytes, materialBytes, swatchPhotos) =
          await _readArchive(raf, length);
      // The looms and the materials first: a project that names a record restored as a copy is
      // compared with the library as it would be once pointed at the copy.
      final loomPlan = loomBytes == null ? null : await _classifyLooms(loomBytes);
      final relinks = loomPlan?.relinks(const {}) ?? const <String, (String, String)>{};
      final materialPlan = materialBytes == null
          ? null
          : await _classifyMaterials(materialBytes, swatchPhotos, docs);
      final materialRelinks = materialPlan?.relinks(const {}) ??
          _noMaterialRelinks;
      final projects = <RestoreProject>[];
      for (final craft in BackupCraft.values) {
        final dir = Directory(p.join(docs.path, craft.directory));
        final stems = await _stems(dir);
        final ofCraft = accumulators.values.where((a) => a.craft == craft).toList()
          ..sort((a, b) => a.id.compareTo(b.id));
        for (final acc in ofCraft) {
          projects.add(await _classify(raf, acc, dir, stems, relinks, materialRelinks));
        }
      }
      return RestorePlan(
        archive: archive,
        createdAt: manifest.createdAt,
        appVersion: manifest.appVersion,
        projects: projects,
        settings: settings,
        looms: loomPlan == null ? null : _withDraftCounts(loomPlan, projects),
        materials: materialPlan == null
            ? null
            : _MaterialsBackup._withProjectCounts(materialPlan, projects),
      );
    } on FileSystemException catch (e) {
      throw BackupException(BackupProblem.unreadable, detail: '$e');
    } finally {
      await raf.close();
    }
  }

  /// Read every entry: the manifest first, then each file, checked against it and hashed. A file
  /// that must be inspected (native file, upgrade backup, sidecar, app settings) is read into
  /// memory, within the per-entry limits, checked right away, and dropped: only the verdict and a
  /// few digests are kept per project (and the parsed settings). Photos are only hashed.
  Future<
      (
        BackupManifest,
        Map<String, _ProjectAccumulator>,
        RestoreSettings?,
        Uint8List?,
        Uint8List?,
        Map<String, List<ArchivedSwatchPhoto>>,
      )> _readArchive(RandomAccessFile raf, int length) async {
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
    RestoreSettings? settings;
    Uint8List? loomBytes;
    Uint8List? materialBytes;
    final swatchPhotos = <String, List<ArchivedSwatchPhoto>>{};
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
        final isSettings = path == backupSettingsPath;
        final isLooms = path == backupLoomsPath;
        final isMaterials = path == backupMaterialsPath;
        final swatchPhoto = classifySwatchPhotoPath(path);
        final layout = (isSettings || isLooms || isMaterials || swatchPhoto != null)
            ? null
            : classifyLibraryPath(path);
        if (!isSettings && !isLooms && !isMaterials && swatchPhoto == null && layout == null) {
          throw BackupException(BackupProblem.unsafe, detail: 'path $path');
        }
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
        final max = layout != null
            ? limits.maxBytesFor(layout.role)
            : isLooms
                ? limits.maxLoomsBytes
                : isMaterials
                    ? limits.maxMaterialsBytes
                    : swatchPhoto != null
                        ? limits.maxFileBytes
                        : limits.maxSettingsBytes;
        if (entry.size > max) {
          throw BackupException(BackupProblem.unsafe, detail: '$path is ${entry.size} bytes');
        }
        final (digest, content) = await _hashSlice(raf, entry.dataOffset, entry.size,
            keep: layout?.role != BackupFileRole.photo && swatchPhoto == null);
        if (digest != record.sha256) {
          throw BackupException(BackupProblem.damaged, detail: '$path checksum');
        }
        if (isLooms) {
          loomBytes = content; // read as untrusted input once the archive has checked out
          continue;
        }
        if (isMaterials) {
          materialBytes = content; // read as untrusted input once the archive has checked out
          continue;
        }
        if (swatchPhoto != null) {
          (swatchPhotos[swatchPhoto.swatchId] ??= [])
              .add(ArchivedSwatchPhoto(swatchPhoto, entry.size, entry.dataOffset, digest));
          continue;
        }
        if (layout == null) {
          settings = _checkSettings(content!);
          continue;
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
    return (manifest, accumulators, settings, loomBytes, materialBytes, swatchPhotos);
  }

  /// The looms of a backup, as untrusted input, compared with My looms by id: new (added under
  /// their id), the same field for field (skipped), or different (offered as a copy named
  /// "<name> (restored)" under an id derived from the loom, so a repeated restore recognizes the copy
  /// it made). Refused, with the reason, when they cannot be read, are newer, My looms cannot be
  /// read, or adding them would pass the loom limit. An existing loom is never changed.
  Future<RestoreLooms?> _classifyLooms(Uint8List bytes) async {
    final hooks = looms;
    if (hooks == null) return const RestoreLooms.refused(RestoreLooms.unsupported);
    final List<LoomProfile> backed;
    try {
      backed = await hooks.decode(bytes);
    } on LoomFileException catch (e) {
      return RestoreLooms.refused(e.problem == LoomFileProblem.newerVersion
          ? RestoreLooms.newer
          : RestoreLooms.unreadable);
    } catch (_) {
      return const RestoreLooms.refused(RestoreLooms.unreadable);
    }
    if (backed.isEmpty) return null;
    final List<LoomProfile> local;
    try {
      local = await hooks.currentLooms();
    } catch (_) {
      return const RestoreLooms.refused(RestoreLooms.localUnreadable);
    }
    final byId = {for (final l in local) l.id: l};
    final taken = {...byId.keys};
    final items = <RestoreLoom>[];
    for (final loom in backed) {
      final mine = byId[loom.id];
      if (mine == null && taken.add(loom.id)) {
        items.add(RestoreLoom(loom, RestoreStatus.add, loom));
        continue;
      }
      if (mine == loom) {
        items.add(RestoreLoom(loom, RestoreStatus.alreadyPresent, null));
        continue;
      }
      final name = loomCopyName(loom.name);
      var copyId = _loomCopyId(loom);
      if (byId[copyId] == loom.copyWith(id: copyId, name: name)) {
        // The copy an earlier restore of this backup made.
        items.add(RestoreLoom(loom, RestoreStatus.alreadyPresent, null, copyId: copyId));
        continue;
      }
      while (taken.contains(copyId)) {
        copyId = _uuid.v4();
      }
      taken.add(copyId);
      items.add(RestoreLoom(loom, RestoreStatus.conflict, loom.copyWith(id: copyId, name: name),
          copyId: copyId, localName: mine?.displayName));
    }
    final adding = items.where((i) => i.target != null).length;
    if (local.length + adding > LoomLimits.maxLooms) {
      return const RestoreLooms.refused(RestoreLooms.tooMany);
    }
    return RestoreLooms.available(List.unmodifiable(items));
  }

  /// [looms] with, for each loom, how many of the drafts a restore would add (new or as a copy) name
  /// it.
  static RestoreLooms _withDraftCounts(RestoreLooms looms, List<RestoreProject> projects) {
    if (looms.refusal != null) return looms;
    final counts = <String, int>{};
    for (final p in projects) {
      final id = p.loomPlanId;
      if (id == null) continue;
      if (p.status == RestoreStatus.add || p.status == RestoreStatus.conflict) {
        counts[id] = (counts[id] ?? 0) + 1;
      }
    }
    return RestoreLooms.available(
        List.unmodifiable([for (final i in looms.items) i._withDrafts(counts[i.key] ?? 0)]));
  }

  /// [json] (a sidecar) with its `loomPlan` pointed at the loom [loomId] named [loomName]; every
  /// other key, of the plan too, kept with its value and in its place.
  static Map<String, dynamic> _relinked(
      Map<String, dynamic> json, String loomId, String loomName) {
    final out = Map<String, dynamic>.of(json);
    final plan = out['loomPlan'];
    if (plan is Map) out['loomPlan'] = {...plan, 'loomId': loomId, 'loomName': loomName};
    return out;
  }

  /// The name of a material or swatch restored as a copy: "<name> (restored)", within the name
  /// limit.
  static String recordCopyName(String name, String fallback) {
    const suffix = ' (restored)';
    final base = name.trim().isEmpty ? fallback : name.trim();
    return '${clipRunes(base, MaterialLimits.maxNameChars - suffix.length)}$suffix';
  }

  /// [s] with its yarns pointed at the materials restored as copies ([copies]: backup id to the
  /// copy's id and name).
  static SwatchRecord swatchWithMaterialCopies(
      SwatchRecord s, Map<String, (String, String)> copies) {
    if (copies.isEmpty || !s.yarns.any((y) => copies.containsKey(y.materialId))) return s;
    return SwatchRecord(
      id: s.id,
      name: s.name,
      craft: s.craft,
      technique: s.technique,
      date: s.date,
      yarns: [
        for (final y in s.yarns)
          switch (copies[y.materialId]) {
            null => y,
            final c => SwatchYarn(materialId: c.$1, name: c.$2, role: y.role),
          },
      ],
      tools: s.tools,
      sett: s.sett,
      widthInReed: s.widthInReed,
      onLoom: s.onLoom,
      before: s.before,
      after: s.after,
      finishing: s.finishing,
      mass: s.mass,
      tension: s.tension,
      provenance: s.provenance,
      notes: s.notes,
    );
  }

  /// A version-8 (custom) UUID derived from [key] under [purpose].
  static String _derivedId(String purpose, String key) {
    final digest = sha256.convert(utf8.encode('$purpose\n$key'));
    final b = digest.bytes.sublist(0, 16);
    b[6] = (b[6] & 0x0F) | 0x80;
    b[8] = (b[8] & 0x3F) | 0x80;
    final hex = b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
        '${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  /// The name of a loom restored as a copy: "<name> (restored)", the name shortened to keep within
  /// the loom name limit.
  static String loomCopyName(String name) {
    const suffix = ' (restored)';
    final base = name.trim().isEmpty ? 'Unnamed loom' : name.trim();
    return '${clipToRunes(base, LoomLimits.maxNameChars - suffix.length)}$suffix';
  }

  /// A version-8 (custom) UUID derived from the loom's content.
  static String _loomCopyId(LoomProfile loom) {
    final digest = sha256.convert(utf8.encode('ply.looms restored copy\n${loom.canonicalKey}'));
    final b = digest.bytes.sublist(0, 16);
    b[6] = (b[6] & 0x0F) | 0x80;
    b[8] = (b[8] & 0x3F) | 0x80;
    final hex = b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
        '${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  /// App settings from a backup, as untrusted input: offered only when they parse as the settings
  /// model the way the settings repository reads its own file (unknown keys ignored, an unknown
  /// value back to its default); anything else is refused with the reason. The size limit was
  /// checked before the bytes were read.
  static RestoreSettings _checkSettings(Uint8List bytes) {
    final settings = AppSettingsRepository.decode(bytes);
    return settings == null
        ? const RestoreSettings.refused(RestoreSettings.unreadable)
        : RestoreSettings.available(settings);
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
    final plan = json['loomPlan'];
    if (acc.craft == BackupCraft.weaving && plan is Map && plan['loomId'] is String) {
      acc.loomPlanId = plan['loomId'] as String;
    }
    final links = ProjectMaterials.idsIn(json);
    acc.linkedMaterials = links.materials;
    acc.linkedSwatches = links.swatches;
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
  /// present, or restore it as a copy. [raf] is the open archive (a nalbinding copy's renamed
  /// `.plynal` is derived from it when an earlier copy may already be in the library).
  Future<RestoreProject> _classify(RandomAccessFile raf, _ProjectAccumulator acc, Directory dir,
      Set<String> stems, Map<String, (String, String)> relinks,
      _MaterialRelinks materialRelinks) async {
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
          loomPlanId: acc.loomPlanId,
          linkedMaterials: acc.linkedMaterials,
          linkedSwatches: acc.linkedSwatches,
        );
    if (refusal != null) return make(RestoreStatus.refused);

    if (!stems.contains(acc.id.toLowerCase())) {
      return make(RestoreStatus.add, targetId: acc.id, targetName: name);
    }
    // A draft that names a loom restored as a copy is also the same as the library once pointed at
    // the copy (what an earlier restore of this backup wrote).
    final relink = relinks[acc.loomPlanId];
    final linksCopy = _linksCopy(acc.linkedMaterials, acc.linkedSwatches, materialRelinks);
    final relinked = (relink == null && !linksCopy)
        ? null
        : await _relinkedSidecar(raf, acc, relink, materialRelinks);
    if (await _sameAsLibrary(dir, acc.id, acc.files, acc.sidecarDigest!) ||
        (relinked != null &&
            await _sameAsLibrary(dir, acc.id, acc.files, sidecarDigest(relinked)))) {
      return make(RestoreStatus.alreadyPresent);
    }
    // A copy: a deterministic id, so restoring the same backup again finds the copy it made.
    var copyId = _copyId(acc);
    if (stems.contains(copyId)) {
      // A nalbinding copy's `.plynal` carries the copy's name, so compare against that version.
      final renamedNative = acc.craft == BackupCraft.nalbinding
          ? await _renamedNative(raf, acc, copyNameFor(name))
          : null;
      if (await _sameAsLibrary(dir, copyId, acc.files, acc.copySidecarDigest!,
              native: renamedNative) ||
          (relinked != null &&
              await _sameAsLibrary(
                  dir, copyId, acc.files, sidecarDigest(relinked, name: copyNameFor(name)),
                  native: renamedNative))) {
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

  /// The project's sidecar as it is once pointed at the loom copy [relink] (id, name) and the
  /// material and swatch copies of [materialRelinks], read again from the archive and checked
  /// against its recorded digest.
  Future<Map<String, dynamic>> _relinkedSidecar(RandomAccessFile raf, _ProjectAccumulator acc,
      (String, String)? relink, _MaterialRelinks materialRelinks) async {
    final f = acc.files.firstWhere((f) => f.layout.role == BackupFileRole.sidecar);
    final (digest, bytes) = await _hashSlice(raf, f.dataOffset, f.size, keep: true);
    if (digest != f.sha256) {
      throw BackupException(BackupProblem.damaged, detail: '${f.layout.pathFor(acc.id)} changed');
    }
    return _rewrittenSidecar(
        jsonDecode(utf8.decode(bytes!)) as Map<String, dynamic>, relink, materialRelinks);
  }

  /// [json] (a sidecar) pointed at the loom copy [relink] and at the material and swatch copies of
  /// [materialRelinks]; every other key kept.
  static Map<String, dynamic> _rewrittenSidecar(Map<String, dynamic> json,
      (String, String)? relink, _MaterialRelinks materialRelinks) {
    final looms = relink == null ? json : _relinked(json, relink.$1, relink.$2);
    return ProjectMaterials.relinked(looms, materialRelinks.materials, materialRelinks.swatches);
  }

  /// Whether a project linking [materialIds] and [swatchIds] links a record restored as a copy.
  static bool _linksCopy(
          Set<String> materialIds, Set<String> swatchIds, _MaterialRelinks materialRelinks) =>
      materialIds.any(materialRelinks.materials.containsKey) ||
      swatchIds.any(materialRelinks.swatches.containsKey);

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
  /// the same native file (or, when given, the [native] size and digest instead of the backup's),
  /// a sidecar with [sidecarDigest] (see [LibraryBackup.sidecarDigest]), and every upgrade backup
  /// and photo of the backup with the same bytes.
  Future<bool> _sameAsLibrary(
      Directory dir, String id, List<_ArchivedFile> files, String sidecarDigest,
      {({int size, String sha256})? native}) async {
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
        final want = f.layout.role == BackupFileRole.native && native != null
            ? native
            : (size: f.size, sha256: f.sha256);
        if (await local.length() != want.size) return false;
        final (digest, _) = await _hashFile(local, want.size);
        if (digest != want.sha256) return false;
      }
      return true;
    } catch (_) {
      return false; // unreadable: not provably the same, so keep both
    }
  }

  /// The size and digest of a nalbinding project's `.plynal` as a restored copy named [name] has it
  /// (see [_withName]), read again from the archive and checked against its recorded digest.
  Future<({int size, String sha256})> _renamedNative(
      RandomAccessFile raf, _ProjectAccumulator acc, String name) async {
    final f = acc.files.firstWhere((f) => f.layout.role == BackupFileRole.native);
    final (digest, bytes) = await _hashSlice(raf, f.dataOffset, f.size, keep: true);
    if (digest != f.sha256) {
      throw BackupException(BackupProblem.damaged, detail: '${f.layout.pathFor(acc.id)} changed');
    }
    final renamed = _withName(bytes!, name);
    return (size: renamed.length, sha256: _hexSha256(renamed));
  }

  /// [json] (the bytes of a JSON object: a sidecar or a `.plynal`) with its `name` set to [name].
  /// Every other key, known or not, keeps its value and its place (the format and version keys of a
  /// `.plynal` included); a missing `name` is added. Deterministic, so a repeated restore can tell
  /// the copy it made before.
  static Uint8List _withName(Uint8List json, String name) {
    final map = jsonDecode(utf8.decode(json)) as Map<String, dynamic>;
    map['name'] = name;
    return Uint8List.fromList(utf8.encode(jsonEncode(map)));
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
  /// [skippedConflicts] (as a copy), and the backup's app settings when [restoreSettings] is true and
  /// they could be read. Files are copied from the archive into a staging folder (their digests
  /// checked again), then each project is moved into the library, sidecar last, and then the
  /// settings are applied. On any failure (the settings' included) everything placed so far is
  /// removed and a [BackupProblem.restoreFailed] is thrown: the library and the settings are exactly
  /// as they were. Afterwards thumbnails are rebuilt (best-effort).
  Future<RestoreResult> restore(RestorePlan plan,
      {Set<String> skippedConflicts = const {},
      bool restoreSettings = false,
      Set<String> skippedLoomConflicts = const {},
      Set<String> skippedMaterialConflicts = const {}}) async {
    final selected = [
      for (final project in plan.projects)
        if (project.status == RestoreStatus.add ||
            (project.status == RestoreStatus.conflict && !skippedConflicts.contains(project.key)))
          project,
    ];
    final settings = restoreSettings ? plan.settings?.settings : null;
    final loomsToAdd = plan.looms?.selected(skippedLoomConflicts) ?? const <LoomProfile>[];
    // Drafts of this restore planned for a loom that is restored as a copy point at the copy.
    final relinks =
        plan.looms?.relinks(skippedLoomConflicts) ?? const <String, (String, String)>{};
    (String, String)? relinkFor(RestoreProject p) =>
        p.craft == BackupCraft.weaving ? relinks[p.loomPlanId] : null;
    // Materials and swatches (ADR 0016): the records added, the copies projects point at, and the
    // swatches whose photos are placed. A selection that would pass a record limit adds none of them
    // (the preview said so), and the projects restore without them.
    final materialPlan = plan.materials?.limitProblem(skippedMaterialConflicts) == null
        ? plan.materials
        : null;
    final recordsToAdd = materialPlan?.selected(skippedMaterialConflicts) ??
        (materials: const <MaterialRecord>[], swatches: const <SwatchRecord>[]);
    final materialRelinks = materialPlan?.relinks(skippedMaterialConflicts) ?? _noMaterialRelinks;
    final swatchesWithPhotos = [
      for (final i in materialPlan?.items ?? const <RestoreRecord>[])
        if (i.isSwatch &&
            i.photos.isNotEmpty &&
            (i.status == RestoreStatus.add ||
                (i.status == RestoreStatus.conflict && !skippedMaterialConflicts.contains(i.key))))
          i,
    ];
    final addsRecords = recordsToAdd.materials.isNotEmpty || recordsToAdd.swatches.isNotEmpty;
    if (selected.isEmpty && settings == null && loomsToAdd.isEmpty && !addsRecords) {
      return const RestoreResult([]);
    }
    final docs = await documentsDir();
    await _sweepStaging(docs);
    final staging = Directory(p.join(docs.path, '$stagingPrefix${_uuid.v4()}'));
    final placed = <FileSystemEntity>[];
    final createdDirs = <Directory>[];
    Future<void> Function()? undoLooms;
    Future<void> Function()? undoMaterials;
    var photoFolders = const <String>[];
    try {
      if (selected.isNotEmpty || swatchesWithPhotos.isNotEmpty) {
        await staging.create();
        final raf = await plan.archive.open();
        try {
          for (final project in selected) {
            await _stage(raf, staging, project,
                relink: relinkFor(project), materialRelinks: materialRelinks);
          }
          photoFolders = await _stageSwatchPhotos(raf, staging, swatchesWithPhotos);
        } finally {
          await raf.close();
        }
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
      // Then the looms, in one write of looms.json, so a later failure can put it back exactly.
      if (loomsToAdd.isNotEmpty) {
        final hooks = looms;
        if (hooks == null) throw StateError('this build cannot restore looms');
        undoLooms = await hooks.add(loomsToAdd);
      }
      // Then the swatches' photo folders (each moved whole), and the materials and swatches in one
      // write of materials.json.
      if (photoFolders.isNotEmpty) {
        final dir = Directory(p.join(docs.path, backupSwatchDir));
        if (!await dir.exists()) {
          await dir.create(recursive: true);
          createdDirs.add(dir);
        }
        for (final rel in photoFolders) {
          final from = p.joinAll([staging.path, ...rel.split('/')]);
          final to = p.joinAll([docs.path, ...rel.split('/')]);
          await beforePlace?.call(to);
          if (await FileSystemEntity.type(to, followLinks: false) !=
              FileSystemEntityType.notFound) {
            throw StateError('$rel appeared in the library during the restore');
          }
          placed.add(await Directory(from).rename(to));
        }
      }
      if (addsRecords) {
        final hooks = materials;
        if (hooks == null) throw StateError('this build cannot restore materials');
        undoMaterials = await hooks.add(recordsToAdd.materials, recordsToAdd.swatches);
      }
      // Last: a failure to apply the settings still rolls every project (and the looms) back.
      if (settings != null) {
        final apply = applySettings;
        if (apply == null) throw StateError('this build cannot apply app settings');
        await apply(settings);
      }
    } catch (e) {
      if (undoMaterials != null) {
        try {
          await undoMaterials();
        } catch (undoError) {
          PlyLog.instance.error('Restore rollback could not put materials.json back: $undoError');
        }
      }
      if (undoLooms != null) {
        try {
          await undoLooms();
        } catch (undoError) {
          PlyLog.instance.error('Restore rollback could not put looms.json back: $undoError');
        }
      }
      await _rollback(placed, createdDirs);
      await _deleteQuietly(staging);
      PlyLog.instance.error('Restore failed and was rolled back: $e');
      throw BackupException(BackupProblem.restoreFailed, detail: '$e');
    }
    await _deleteQuietly(staging);

    final restored = [for (final s in selected) (craft: s.craft, id: s.targetId!)];
    PlyLog.instance.info('Restored ${restored.length} projects'
        '${loomsToAdd.isNotEmpty ? ', ${loomsToAdd.length} looms' : ''}'
        '${addsRecords ? ', ${recordsToAdd.materials.length} materials, '
            '${recordsToAdd.swatches.length} swatches' : ''}'
        '${settings != null ? ' and the app settings' : ''} from a backup.');
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
    return RestoreResult(restored,
        settingsRestored: settings != null,
        loomsRestored: loomsToAdd.length,
        draftsRelinked: selected.where((p) => relinkFor(p) != null).length,
        materialsRestored: recordsToAdd.materials.length,
        swatchesRestored: recordsToAdd.swatches.length,
        projectsRelinkedToMaterials: selected
            .where((p) => _linksCopy(p.linkedMaterials, p.linkedSwatches, materialRelinks))
            .length);
  }

  /// Copy [project]'s files out of the archive into [staging], under its target id. Each digest is
  /// checked again (the archive could have changed since it was inspected). A copy gets its new name
  /// in its sidecar and, for nalbinding, in its `.plynal` too (the project screen shows and saves the
  /// name the `.plynal` carries): a JSON edit of the `name` key alone, the one deliberate exception
  /// to copying a document byte for byte. A project restored under its own id, and every other file
  /// of a copy, is written byte for byte.
  Future<void> _stage(RandomAccessFile raf, Directory staging, RestoreProject project,
      {(String, String)? relink, _MaterialRelinks? materialRelinks}) async {
    final id = project.targetId!;
    final rename = project.status == RestoreStatus.conflict;
    final relinksMaterials = materialRelinks != null &&
        _linksCopy(project.linkedMaterials, project.linkedSwatches, materialRelinks);
    for (final f in project._files) {
      final dest = File(p.joinAll([staging.path, ...f.layout.pathFor(id).split('/')]));
      await dest.parent.create(recursive: true);
      if ((relink != null || relinksMaterials) && f.layout.role == BackupFileRole.sidecar) {
        // A draft planned for a loom this restore adds as a copy (or that an earlier restore of
        // this backup added), or a project linking a material or swatch restored as a copy: its
        // sidecar names the copy, and the copy's name too when renamed.
        final (digest, bytes) = await _hashSlice(raf, f.dataOffset, f.size, keep: true);
        if (digest != f.sha256) throw StateError('${f.layout.pathFor(project.id)} changed');
        final json = _rewrittenSidecar(jsonDecode(utf8.decode(bytes!)) as Map<String, dynamic>,
            relink, materialRelinks ?? _noMaterialRelinks);
        if (rename) json['name'] = project.targetName!;
        await dest.writeAsBytes(utf8.encode(jsonEncode(json)), flush: true);
        continue;
      }
      if (rename &&
          (f.layout.role == BackupFileRole.sidecar ||
              (f.layout.role == BackupFileRole.native &&
                  project.craft == BackupCraft.nalbinding))) {
        final (digest, bytes) = await _hashSlice(raf, f.dataOffset, f.size, keep: true);
        if (digest != f.sha256) throw StateError('${f.layout.pathFor(project.id)} changed');
        await dest.writeAsBytes(_withName(bytes!, project.targetName!), flush: true);
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

  /// A weaving draft's `loomPlan.loomId`, when it names a loom.
  String? loomPlanId;

  /// The material and swatch ids the sidecar links.
  Set<String> linkedMaterials = const {};
  Set<String> linkedSwatches = const {};
}

class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
