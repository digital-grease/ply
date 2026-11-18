// Portable backup and restore of the on-device library (roadmap M7-07; see the backup ADR).
//
// A backup is one `.plybackup` file: an UNCOMPRESSED POSIX ustar archive (see `ustar.dart`) whose
// first entry is `manifest.json`, followed by every project's files copied VERBATIM from the
// library (but for the old copy of a nalbinding project's notes in its sidecar, left out):
//
//   drafts/<id>.wif + drafts/<id>.json
//   knits/<id>.plyknit + knits/<id>.json + knits/<id>.plyknit.v<n>.bak (format-upgrade backups)
//   nalbinds/<id>.plynal + nalbinds/<id>.json + nalbinds/<id>.photos/<name>.<ext>
//   tablets/<id>.plytab + tablets/<id>.json (tablet weaving bands; ADR 0018)
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
// checked (a project newer than this build is refused, with the reason), as are the app settings
// (offered only when they parse as the settings model). The manifest and each sidecar, which are
// decoded here, first have their JSON values counted (`json_count.dart`) against a limit far above
// what Ply writes: many tiny values decode to far more memory than their text. The version a
// pattern, project or band (or a pattern's upgrade backup) states is read by the engine from the
// file's version keys alone, never by decoding the file here, so a newer file is refused before any
// of it is decoded. A pattern or nalbinding project whose version this build reads then has its
// JSON values counted by the engine, also without decoding it, and one with more values than any
// the app can make is refused as too complex to check: a guard against files crafted to blow up in
// memory when decoded, which bounds that memory only roughly (measured: about 144 MiB for a pattern
// at the current version, which the engine decodes into its own types, 900 MiB for an older one,
// which it decodes into a generic tree for the migrations, and 65 MiB for a project). Then the file
// is read in full: by the engine, or for a nalbinding project (whose document is the app's) by the
// Dart reader on a background isolate. A preview is built only once every check has passed,
// and nothing in the library is written until the user confirms it. The commit stages every file
// inside the documents directory, then moves each project into place with its sidecar LAST (the
// library lists sidecars), applies the app settings only if the user ticked them, and on any failure
// removes what it placed, so the library is left exactly as it was. Existing projects are never
// overwritten: one with the same id and different content is restored as a copy under a new id, and
// the copy's name is the only thing rewritten (in its sidecar, and for nalbinding also in its
// `.plynal`, which carries the name the project screen shows; that rewrite also runs on a background
// isolate).

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
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
import '../models/weave_plan.dart' show WeavePlan;
import 'app_settings_repository.dart';
import 'json_count.dart';
import 'loom_repository.dart' show LoomFileException, LoomFileProblem;
import 'materials_repository.dart'
    show MaterialLibrary, MaterialsFileException, MaterialsFileProblem;
import 'ustar.dart';

part 'library_backup_materials.dart';

const int _mib = 1024 * 1024;

/// The craft libraries a backup holds, with their folder and native file extension.
enum BackupCraft {
  weaving('weaving', 'drafts', 'wif', 'Weaving'),
  knitting('knitting', 'knits', 'plyknit', 'Knitting'),
  nalbinding('nalbinding', 'nalbinds', 'plynal', 'Nalbinding'),

  /// Tablet weaving bands (ADR 0018). Added within manifest schema version 1: a build from before
  /// it refuses a backup holding a band as containing files it cannot restore safely (fails closed).
  tabletWeaving('tablet_weaving', 'tablets', 'plytab', 'Tablet weaving');

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
  /// The project's own document (`.wif`, `.plyknit`, `.plynal`, `.plytab`).
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
    this.maxManifestValues = 250000,
    this.maxSidecarBytes = _mib,
    this.maxSidecarValues = 200000,
    this.maxSidecarDepth = 64,
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

  /// The most JSON values a manifest may have ([countJsonValues]), counted before it is decoded:
  /// many tiny values decode to far more memory than their text (4 MB of `{}` to over 330 MB).
  /// Ply writes 13 plus 11 a file (7 for the settings, looms, materials and swatch photos), so at
  /// most 110,002 at [maxEntries]; this leaves room for 24 a file, six more keys a file than Ply
  /// writes. At the limit the costliest manifest (empty objects) decodes to about 64 MB.
  final int maxManifestValues;

  /// The largest sidecar.
  final int maxSidecarBytes;

  /// The most JSON values a sidecar may have, counted before it is decoded (see
  /// [maxManifestValues]). The largest sidecar Ply writes has about 7,200 (every material and
  /// swatch linked, a warp and weft plan, a loom plan): this is over 25 times that, for keys a
  /// later build adds. Ply's sidecars average about 11 bytes a value, and any whose values average
  /// over 5.3 meets [maxSidecarBytes] first; only a file of tiny values (`{}`, `0`) meets this. At
  /// the limit the costliest sidecar decodes to about 64 MB (a 1 MB one of empty objects to about
  /// 100 MB), the same budget as the value guard of a nalbinding project; one with more than
  /// [LibraryBackup.inlineSidecarValues] is decoded on a background isolate. A backup refuses to
  /// carry a sidecar past it, and a restore refuses that project alone.
  final int maxSidecarValues;

  /// The deepest nesting of lists and objects a sidecar may have on restore ([measureJson]); past
  /// it, or with a number too large for a double, the project is refused as too complex, alone.
  /// The deepest sidecar Ply writes nests 4 levels (a warp and weft plan's override, a material
  /// link); decoding takes any depth, but comparing and rewriting a sidecar encodes it again, which
  /// recurses and refuses infinity (`jsonEncode` overflows the stack at a few thousand levels).
  final int maxSidecarDepth;

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

  /// A sidecar with more JSON values than a restore checks ([BackupLimits.maxSidecarValues]).
  fileTooComplex,

  /// A sidecar that could not be read from the device (permissions, a disk error).
  fileUnreadable,
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

  /// The project a [BackupProblem.fileTooLarge], [BackupProblem.fileTooComplex] or
  /// [BackupProblem.fileUnreadable] is about.
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
        BackupProblem.fileTooComplex =>
          'A file in "${projectName ?? ''}" is too complex to back up.',
        BackupProblem.fileUnreadable =>
          'A file in "${projectName ?? ''}" could not be read, so it cannot be backed up.',
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
  /// not a Ply backup manifest at all (or has more JSON values than
  /// [BackupLimits.maxManifestValues], counted before anything is decoded),
  /// [BackupProblem.newerBackup] for a newer schema (checked before any other field is read),
  /// [BackupProblem.unsafe] for a path outside the library layout or a duplicate, and
  /// [BackupProblem.damaged] for any other malformed field.
  static BackupManifest parse(Uint8List bytes, BackupLimits limits) {
    if (!jsonValuesWithin(bytes, limits.maxManifestValues)) {
      throw const BackupException(BackupProblem.notABackup, detail: 'manifest has too many values');
    }
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
    this.bytes,
    this.sourceSize,
    this.sourceSha256,
  }) : assert((bytes == null) == (sourceSha256 == null) && (bytes == null) == (sourceSize == null));

  final String archivePath;
  final String sourcePath;
  final int size;
  final String sha256;
  final BackupCraft craft;
  final String projectId;

  /// What the backup carries for this file when it is not the file's bytes on disk: a nalbinding
  /// sidecar without the old copy of the project's notes (see [LibraryBackup.sidecarNotesIgnored]).
  /// Its file is still read again when the backup is written and must be [sourceSize] bytes with
  /// [sourceSha256], as planned, or the backup stops (the library changed). Null (every other
  /// file): the file itself is read again and checked against [sha256].
  final Uint8List? bytes;

  /// The size and SHA-256 (lowercase hex) of the file on disk when [bytes] stands in for it.
  final int? sourceSize;
  final String? sourceSha256;
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
  incomplete('Part of this project is missing from the backup.'),
  tooComplex('A file in this project is too complex for Ply to check, so it was not restored.');

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

/// The checks of a project's native file: the version probes, then a full read (production passes
/// the engine's probes and parsers; host tests have no native library and pass stand-ins). Each
/// check throws when it cannot read the text.
///
/// A version probe reads the schema version a file states from its version keys alone, in the
/// engine (nothing else in the file is decoded, however large it is), and returns null when the file
/// is not of its kind. It is never a decode of the whole file in Dart: a backup entry can be tens of
/// megabytes. Without its probe (or, for a pattern or project, its value guard), a pattern, project
/// or band cannot be checked and is refused as unreadable (fails closed).
class NativeFileChecks {
  const NativeFileChecks({
    this.wif,
    this.knit,
    this.knitVersion,
    this.knitGuard,
    this.nalbind = checkPlynalInBackground,
    this.nalbindVersion,
    this.nalbindGuard,
    this.tablet,
    this.tabletVersion,
  });

  final Future<void> Function(String text)? wif;

  /// Throws a [NativeFormatException] (or anything else) when the engine cannot read the pattern.
  final Future<void> Function(String text)? knit;

  /// The schema version a `.plyknit` states (1 for a legacy file; a newer one as found), read by
  /// the engine from the envelope alone (`KnitRepository.documentVersion`). Also checks a
  /// `.plyknit.v<n>.bak` upgrade backup.
  final Future<int?> Function(String text)? knitVersion;

  /// Whether a `.plyknit` has few enough JSON values to check safely, counted by the engine without
  /// decoding it (`KnitRepository.withinValueLimit`). A pattern past it is refused as too complex
  /// ([RestoreRefusal.tooComplex]) before [knit] reads it. Without it, a pattern cannot be checked
  /// and is refused as unreadable (fails closed, like the version probes).
  final Future<bool> Function(String text)? knitGuard;

  /// Throws a [NativeFormatException] (or anything else) when the nalbinding project (a `.plynal`)
  /// cannot be read the way the project screen opens it. The document is the app's, so it is decoded
  /// in Dart, on a background isolate ([checkPlynalInBackground]). It runs only after
  /// [nalbindVersion] has accepted the file's version and [nalbindGuard] its number of values.
  final Future<void> Function(String text) nalbind;

  /// Whether a `.plynal` has few enough JSON values to decode safely, counted by the engine on this
  /// isolate without decoding it (`NalbindRepository.withinValueLimit`). A project past it is
  /// refused as too complex ([RestoreRefusal.tooComplex]) before [nalbind] decodes it. Without it, a
  /// project cannot be checked and is refused as unreadable (fails closed, like the version
  /// probes).
  final Future<bool> Function(String text)? nalbindGuard;


  /// The schema version a `.plynal` states (1 for a legacy file; a newer one as found), read by the
  /// engine from its `format` and `schemaVersion` keys alone (`NalbindRepository.documentVersion`).
  final Future<int?> Function(String text)? nalbindVersion;

  /// Throws a [NativeFormatException] (or anything else) when the engine cannot read the tablet
  /// weaving band (a `.plytab`; ADR 0018).
  final Future<void> Function(String text)? tablet;

  /// The schema version a `.plytab`'s envelope states, read by the engine from the envelope alone
  /// (null when it is not a `.plytab` envelope).
  final Future<int?> Function(String text)? tabletVersion;
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
    Future<int> Function()? currentTabletSchemaVersion,
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
  })  : _clock = clock ?? DateTime.now,
        currentTabletSchemaVersion = currentTabletSchemaVersion ?? _firstTabletSchemaVersion;

  /// The app documents directory, which holds the craft folders.
  final Future<Directory> Function() documentsDir;

  /// The `.plyknit` schema version this build writes (and the newest it reads). Production asks the
  /// engine, so a format bump never needs a change here.
  final Future<int> Function() currentKnitSchemaVersion;

  /// The `.plytab` schema version this build writes (and the newest it reads; ADR 0018). Production
  /// asks the engine (`TabletRepository.schemaVersion`); when it is not given (host tests, which
  /// have no native library) it is version 1, the first `.plytab` version.
  final Future<int> Function() currentTabletSchemaVersion;

  static Future<int> _firstTabletSchemaVersion() async => 1;

  /// Recorded in the manifest.
  final String appVersion;
  final BackupLimits limits;
  final NativeFileChecks checks;

  /// Rebuilds the thumbnail of a restored weaving, knitting or tablet weaving project
  /// (best-effort).
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
  /// when the library would not list it (no native file, or a sidecar file that is not a sidecar).
  /// Throws [BackupProblem.fileTooLarge] or [BackupProblem.fileTooComplex] for a file over its
  /// limit, and [BackupProblem.fileUnreadable] for a sidecar that cannot be read (see
  /// [_sidecarForBackup]).
  Future<({List<BackupFile> files, int photos, String name})?> _collectProject(
      BackupCraft craft, String id, Map<String, FileSystemEntity> names) async {
    final native = names['$id.${craft.nativeExtension}'];
    final sidecar = names['$id.json'];
    if (native is! File || sidecar is! File) return null;
    final carried = await _sidecarForBackup(craft, id, sidecar);
    if (carried == null) return null; // not a sidecar: the library does not list it either
    final name = carried.name;
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
    // The sidecar last, as the bytes already read (and checked) for its name.
    final rewritten = carried.source != null;
    files.add(BackupFile(
      archivePath: LibraryPath._(craft, id, BackupFileRole.sidecar).pathFor(id),
      sourcePath: sidecar.path,
      size: carried.bytes.length,
      sha256: _hexSha256(carried.bytes),
      craft: craft,
      projectId: id,
      bytes: rewritten ? carried.bytes : null,
      sourceSize: carried.source?.size,
      sourceSha256: carried.source?.sha256,
    ));
    return (files: files, photos: photos, name: name);
  }

  /// The sidecar of project [id] of [craft] as a backup carries it, with the project's name and,
  /// when it is carried rewritten, the size and SHA-256 of the file on disk ([source]). Null when
  /// the file is not a sidecar (not UTF-8, not JSON, not an object): the library does not list it
  /// either. Throws [BackupProblem.fileTooLarge] or [BackupProblem.fileTooComplex] for one a
  /// restore would refuse, and [BackupProblem.fileUnreadable] (naming the project) when the device
  /// cannot read it. Anything else (no memory, an isolate that cannot start) is thrown as it is:
  /// the backup fails rather than leave the project out.
  ///
  /// It is carried byte for byte, except a nalbinding sidecar holding a copy of the project's notes
  /// (see [sidecarNotesIgnored]): earlier builds wrote that copy on every save, so notes of about a
  /// megabyte made the sidecar too large for any backup. It is carried with `notes` empty, as a
  /// save now writes it (every other key kept, with its value and in its place), and is read up to
  /// the size of a document for that, on a background isolate when it is over the sidecar limit.
  Future<({String name, Uint8List bytes, ({int size, String sha256})? source})?>
      _sidecarForBackup(BackupCraft craft, String id, File sidecar) async {
    final dropNotes = sidecarNotesIgnored(craft);
    final readLimit = dropNotes ? limits.maxFileBytes : limits.maxSidecarBytes;
    final Uint8List bytes;
    try {
      if (await sidecar.length() > readLimit) {
        throw BackupException(BackupProblem.fileTooLarge,
            projectName: await _nameAtHead(sidecar) ?? id, limit: limits.maxSidecarBytes);
      }
      bytes = await sidecar.readAsBytes();
    } on FileSystemException catch (e) {
      throw BackupException(BackupProblem.fileUnreadable,
          projectName: await _nameAtHead(sidecar) ?? id, detail: '${sidecar.path}: $e');
    }
    final read = bytes.length > limits.maxSidecarBytes
        ? await _prepareSidecarInBackground(bytes, dropNotes)
        : _prepareSidecar(bytes, dropNotes);
    if (read == null) return null;
    final carried = read.rewritten ?? bytes;
    if (carried.length > limits.maxSidecarBytes) {
      throw BackupException(BackupProblem.fileTooLarge,
          projectName: read.name, limit: limits.maxSidecarBytes);
    }
    if (!jsonValuesWithin(carried, limits.maxSidecarValues)) {
      throw BackupException(BackupProblem.fileTooComplex, projectName: read.name);
    }
    return (
      name: read.name,
      bytes: carried,
      source: read.rewritten == null
          ? null
          : (size: bytes.length, sha256: await _hashBytes(bytes)),
    );
  }

  /// The project name at the head of a sidecar too large to read, for the message that refuses it:
  /// Ply writes `name` first, so the first 4 KB hold it. Null when they do not.
  static Future<String?> _nameAtHead(File sidecar) async {
    try {
      final head = BytesBuilder(copy: false);
      await for (final chunk in sidecar.openRead(0, 4096)) {
        head.add(chunk);
      }
      final text = utf8.decode(head.takeBytes(), allowMalformed: true);
      final m = RegExp(r'"name"\s*:\s*("(?:[^"\\]|\\.)*")').firstMatch(text);
      final name = m == null ? null : jsonDecode(m.group(1)!);
      return name is String && name.trim().isNotEmpty ? name : null;
    } catch (_) {
      return null; // only the message is at stake: it names the id instead
    }
  }

  /// [_prepareSidecar] on a background isolate.
  static Future<({String name, Uint8List? rewritten})?> _prepareSidecarInBackground(
          Uint8List bytes, bool dropNotes) =>
      Isolate.run(() => _prepareSidecar(bytes, dropNotes), debugName: 'sidecar notes');

  /// The name in a sidecar's [bytes], and, with [dropNotes], the sidecar with a non-empty `notes`
  /// set to empty (null when there is nothing to drop). Null when [bytes] is not a sidecar (not
  /// UTF-8 or JSON: a [FormatException]; not an object: a [TypeError]), the files the library
  /// listing skips too.
  static ({String name, Uint8List? rewritten})? _prepareSidecar(Uint8List bytes, bool dropNotes) {
    final Map<String, dynamic> json;
    final String name;
    try {
      json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      name = DraftMeta.fromJson(json).name;
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
    if (!dropNotes || !json.containsKey('notes') || json['notes'] == '') {
      return (name: name, rewritten: null);
    }
    json['notes'] = '';
    try {
      return (name: name, rewritten: Uint8List.fromList(utf8.encode(jsonEncode(json))));
    } on JsonUnsupportedObjectError {
      // A number too large for a double (decoded as infinity) cannot be written again: no Ply
      // build wrote one. Carried as it is, within the sidecar's limit; past it, refused by name.
      return (name: name, rewritten: null);
    } on StackOverflowError {
      // Nesting thousands of levels deep, which no Ply build wrote: the same.
      return (name: name, rewritten: null);
    }
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
    // Within the entry limit the manifest is always within its value limit (see
    // [BackupLimits.maxManifestValues]); checked anyway, as a restore checks it.
    if (!jsonValuesWithin(largest.manifestBytes, limits.maxManifestValues)) {
      throw BackupException(
        plan.contents == BackupContents.project
            ? BackupProblem.projectTooManyFiles
            : BackupProblem.libraryTooManyFiles,
        limit: limits.maxEntries,
      );
    }
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

    for (final f in <({String archivePath, String sourcePath, int size, String sha256,
        BackupFile? planned})>[
      ...plan.swatchPhotos.map((s) => (archivePath: s.archivePath, sourcePath: s.sourcePath,
          size: s.size, sha256: s.sha256, planned: null)),
      ...plan.files.map((f) => (archivePath: f.archivePath, sourcePath: f.sourcePath,
          size: f.size, sha256: f.sha256, planned: f)),
    ]) {
      header(f.archivePath, f.size);
      final carried = f.planned?.bytes;
      if (carried != null) {
        // A sidecar carried rewritten (see [BackupFile.bytes]): its file must still be the one
        // planned, as every other file must; then the planned bytes are written.
        final planned = f.planned!;
        final (String, int) onDisk;
        try {
          onDisk = await _hashFile(File(f.sourcePath), planned.sourceSize!);
        } on FileSystemException catch (e) {
          throw BackupException(BackupProblem.libraryChanged, detail: '${f.archivePath}: $e');
        }
        if (onDisk.$2 != planned.sourceSize || onDisk.$1 != planned.sourceSha256) {
          throw BackupException(BackupProblem.libraryChanged, detail: f.archivePath);
        }
        data(carried);
        continue;
      }
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
      manifest = await _parseManifestInBackground(bytes, limits);
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
    int? tabletVersion;
    Future<int> tablet() async => tabletVersion ??= await currentTabletSchemaVersion();
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
        if (content != null) await _inspect(acc, layout, content, knit, tablet);
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

  /// [BackupManifest.parse] (up to 4 MB of JSON, its values counted before it is decoded) on a
  /// background isolate, so the decode never holds up the UI.
  static Future<BackupManifest> _parseManifestInBackground(Uint8List bytes, BackupLimits limits) =>
      Isolate.run(() => BackupManifest.parse(bytes, limits), debugName: 'backup manifest');

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
      Future<int> Function() knitVersion, Future<int> Function() tabletVersion) async {
    final String text;
    try {
      text = utf8.decode(bytes);
    } on FormatException {
      acc.unreadable = true;
      return;
    }
    final verdict = switch (layout.role) {
      BackupFileRole.sidecar => await _checkSidecar(acc, bytes, text),
      BackupFileRole.native => await _checkNative(acc.craft, text, knitVersion, tabletVersion),
      BackupFileRole.upgradeBackup =>
        await _checkUpgradeBackup(layout.version!, text, knitVersion),
      BackupFileRole.photo => null,
    };
    if (layout.role == BackupFileRole.native) acc.hasNative = true;
    if (layout.role == BackupFileRole.sidecar) acc.hasSidecar = true;
    if (verdict == RestoreRefusal.newerVersion) acc.newer = true;
    if (verdict == RestoreRefusal.unreadable) acc.unreadable = true;
    if (verdict == RestoreRefusal.tooComplex) acc.tooComplex = true;
  }

  /// A sidecar from a backup, as untrusted input: its JSON values are counted before it is decoded,
  /// and one past [BackupLimits.maxSidecarValues], nested past [BackupLimits.maxSidecarDepth] or
  /// holding a number too large for a double refuses its project as too complex, alone. One with
  /// more than [inlineSidecarValues] values is decoded on a background isolate.
  Future<RestoreRefusal?> _checkSidecar(
      _ProjectAccumulator acc, Uint8List bytes, String text) async {
    final shape = measureJson(bytes, stop: limits.maxSidecarValues);
    if (shape.values > limits.maxSidecarValues ||
        shape.depth > limits.maxSidecarDepth ||
        shape.nonFinite) {
      return RestoreRefusal.tooComplex;
    }
    final read =
        await _readBackupSidecar(text, acc.craft, inline: shape.values <= inlineSidecarValues);
    if (read == null) return RestoreRefusal.unreadable;
    acc.name = read.name;
    acc.sidecarDigest = read.digest;
    acc.copySidecarDigest = read.copyDigest;
    acc.loomPlanId = read.loomPlanId;
    acc.linkedMaterials = read.materials;
    acc.linkedSwatches = read.swatches;
    return read.newer ? RestoreRefusal.newerVersion : null;
  }

  /// [_backupSidecarFacts] of [text], on this isolate when [inline], else on a background isolate.
  static Future<_SidecarFacts?> _readBackupSidecar(String text, BackupCraft craft,
      {required bool inline}) async {
    if (inline) return _backupSidecarFacts(text, craft);
    return Isolate.run(() => _backupSidecarFacts(text, craft), debugName: 'sidecar check');
  }

  /// What a restore needs from a backup's sidecar of [craft], or null when it is not a sidecar
  /// this build reads (not JSON, not an object, not a sidecar model).
  static _SidecarFacts? _backupSidecarFacts(String text, BackupCraft craft) {
    final Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException {
      return null;
    }
    if (json is! Map<String, dynamic>) return null;
    final DraftMeta meta;
    try {
      meta = DraftMeta.fromJson(json);
    } catch (_) {
      return null;
    }
    final ignoreNotes = sidecarNotesIgnored(craft);
    final plan = json['loomPlan'];
    final links = ProjectMaterials.idsIn(json);
    // A weaving draft's plan names records too (ADR 0019): they count as records it uses, so a
    // restore that adds one as a copy points the plan at the copy, as it does the links.
    final planned = craft == BackupCraft.weaving
        ? WeavePlan.idsIn(json)
        : (materials: const <String>{}, swatches: const <String>{});
    final version = json['schemaVersion'];
    return (
      name: meta.name,
      digest: sidecarDigest(json, ignoreNotes: ignoreNotes),
      copyDigest: sidecarDigest(json, name: copyNameFor(meta.name), ignoreNotes: ignoreNotes),
      loomPlanId: craft == BackupCraft.weaving && plan is Map && plan['loomId'] is String
          ? plan['loomId'] as String
          : null,
      materials: {...links.materials, ...planned.materials},
      swatches: {...links.swatches, ...planned.swatches},
      newer: version is int && version > DraftMeta.currentSchemaVersion,
    );
  }

  Future<RestoreRefusal?> _checkNative(BackupCraft craft, String text,
      Future<int> Function() knitVersion, Future<int> Function() tabletVersion) async {
    switch (craft) {
      case BackupCraft.weaving:
        try {
          await checks.wif?.call(text);
        } catch (_) {
          return RestoreRefusal.unreadable;
        }
        return null;
      // Knitting, nalbinding and tablet weaving alike (ADR 0002, ADR 0018): the version the file
      // states decides first, read by the engine from its version keys alone (never by decoding
      // the file here), so a newer file is refused before any of it is decoded; then the full read.
      case BackupCraft.knitting:
        return _checkVersioned(
            text, checks.knitVersion, knitVersion, checks.knitGuard, checks.knit);
      case BackupCraft.nalbinding:
        // The `.plynal` document is the app's, so its full read is a Dart decode, on a background
        // isolate (see [NativeFileChecks.nalbind]); the engine counts its values first, here.
        return _checkVersioned(text, checks.nalbindVersion,
            () async => NalbindProject.currentSchemaVersion, checks.nalbindGuard, checks.nalbind);
      case BackupCraft.tabletWeaving:
        // The engine reads a band into its own types, never a generic tree: no values to count.
        return _checkVersioned(
            text, checks.tabletVersion, tabletVersion, _nothingToCount, checks.tablet);
    }
  }

  static Future<bool> _nothingToCount(String text) async => true;

  /// A versioned native file: [probe] reads the version [text] states (null: not this kind of file),
  /// which must not be newer than [current]; then [guard] must find few enough values in it to read
  /// it safely (refused as too complex otherwise); then [read] must accept the whole file. Without a
  /// probe or a guard the file cannot be checked, so it is refused as unreadable (fails closed).
  Future<RestoreRefusal?> _checkVersioned(
      String text,
      Future<int?> Function(String text)? probe,
      Future<int> Function() current,
      Future<bool> Function(String text)? guard,
      Future<void> Function(String text)? read) async {
    if (probe == null) return RestoreRefusal.unreadable;
    final int? version;
    try {
      version = await probe(text);
    } catch (_) {
      return RestoreRefusal.unreadable;
    }
    if (version == null) return RestoreRefusal.unreadable;
    if (version > await current()) return RestoreRefusal.newerVersion;
    if (guard == null) return RestoreRefusal.unreadable;
    try {
      if (!await guard(text)) return RestoreRefusal.tooComplex;
    } catch (_) {
      return RestoreRefusal.unreadable;
    }
    try {
      await read?.call(text);
    } on NativeFormatException catch (e) {
      return e.problem == NativeFormatProblem.newerVersion
          ? RestoreRefusal.newerVersion
          : RestoreRefusal.unreadable;
    } catch (_) {
      return RestoreRefusal.unreadable;
    }
    return null;
  }

  /// An upgrade backup holds the original file at the version its name records: that version must
  /// not be newer than this build, and the engine's envelope reader must find it in the file.
  Future<RestoreRefusal?> _checkUpgradeBackup(
      int version, String text, Future<int> Function() knitVersion) async {
    if (version > await knitVersion()) return RestoreRefusal.newerVersion;
    final probe = checks.knitVersion;
    if (probe == null) return RestoreRefusal.unreadable;
    try {
      return await probe(text) == version ? null : RestoreRefusal.unreadable;
    } catch (_) {
      return RestoreRefusal.unreadable;
    }
  }

  /// Decide what a restore does with one checked project: refuse it, add it, skip it as already
  /// present, or restore it as a copy. [raf] is the open archive (a nalbinding copy's renamed
  /// `.plynal` is derived from it when an earlier copy may already be in the library).
  Future<RestoreProject> _classify(RandomAccessFile raf, _ProjectAccumulator acc, Directory dir,
      Set<String> stems, Map<String, (String, String)> relinks,
      _MaterialRelinks materialRelinks) async {
    final RestoreRefusal? refusal = acc.newer
        ? RestoreRefusal.newerVersion
        : acc.tooComplex
            ? RestoreRefusal.tooComplex
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
        : await _relinkedSidecar(raf, acc, relink, materialRelinks, copyNameFor(name));
    if (await _sameAsLibrary(dir, acc.id, acc.files, acc.sidecarDigest!) ||
        (relinked != null && await _sameAsLibrary(dir, acc.id, acc.files, relinked.digest))) {
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
              await _sameAsLibrary(dir, copyId, acc.files, relinked.copyDigest,
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

  /// The [sidecarDigest]s of the project's sidecar once pointed at the loom copy [relink] (id,
  /// name) and the material and swatch copies of [materialRelinks], as is and renamed [copyName]
  /// for a copy. The sidecar is read again from the archive and checked against its recorded
  /// digest, and decoded off the calling isolate when it is large ([inlineSidecarValues]).
  Future<({String digest, String copyDigest})> _relinkedSidecar(RandomAccessFile raf,
      _ProjectAccumulator acc, (String, String)? relink, _MaterialRelinks materialRelinks,
      String copyName) async {
    final f = acc.files.firstWhere((f) => f.layout.role == BackupFileRole.sidecar);
    final (digest, bytes) = await _hashSlice(raf, f.dataOffset, f.size, keep: true);
    if (digest != f.sha256) {
      throw BackupException(BackupProblem.damaged, detail: '${f.layout.pathFor(acc.id)} changed');
    }
    return _relinkedDigests(
        bytes!, relink, materialRelinks, copyName, sidecarNotesIgnored(acc.craft));
  }

  static Future<({String digest, String copyDigest})> _relinkedDigests(Uint8List bytes,
      (String, String)? relink, _MaterialRelinks materialRelinks, String copyName,
      bool ignoreNotes) async {
    ({String digest, String copyDigest}) work() {
      final json = _rewrittenSidecar(
          jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>, relink, materialRelinks);
      return (
        digest: sidecarDigest(json, ignoreNotes: ignoreNotes),
        copyDigest: sidecarDigest(json, name: copyName, ignoreNotes: ignoreNotes),
      );
    }

    if (_decodesInline(bytes)) return work();
    return Isolate.run(work, debugName: 'sidecar relink');
  }

  /// A backup sidecar with at most this many JSON values is decoded on the calling isolate, which
  /// takes a few milliseconds at most (every sidecar Ply writes has fewer: about 7,200 at the
  /// most); one with more, up to [BackupLimits.maxSidecarValues], is decoded on a background
  /// isolate, so a backup crafted with hundreds of sidecars at the limit cannot hold up the UI
  /// while it is checked or restored.
  static const int inlineSidecarValues = 10000;

  /// Whether a sidecar's [bytes] are decoded on the calling isolate ([inlineSidecarValues]).
  static bool _decodesInline(List<int> bytes) =>
      countJsonValues(bytes, stop: inlineSidecarValues) <= inlineSidecarValues;

  /// [json] (a sidecar) pointed at the loom copy [relink] and at the material and swatch copies of
  /// [materialRelinks]; every other key kept.
  static Map<String, dynamic> _rewrittenSidecar(Map<String, dynamic> json,
      (String, String)? relink, _MaterialRelinks materialRelinks) {
    final looms = relink == null ? json : _relinked(json, relink.$1, relink.$2);
    final linked =
        ProjectMaterials.relinked(looms, materialRelinks.materials, materialRelinks.swatches);
    return WeavePlan.relinked(linked, materialRelinks.materials, materialRelinks.swatches);
  }

  /// Whether a project linking [materialIds] and [swatchIds] links a record restored as a copy.
  static bool _linksCopy(
          Set<String> materialIds, Set<String> swatchIds, _MaterialRelinks materialRelinks) =>
      materialIds.any(materialRelinks.materials.containsKey) ||
      swatchIds.any(materialRelinks.swatches.containsKey);

  /// A digest of a sidecar's content that ignores `lastOpened` (bumped by every open) and key order,
  /// with the name replaced by [name] when given (to compare against a restored copy). With
  /// [ignoreNotes] (a nalbinding sidecar, see [sidecarNotesIgnored]) it ignores `notes` too.
  @visibleForTesting
  static String sidecarDigest(Map<String, dynamic> json, {String? name, bool ignoreNotes = false}) {
    final core = Map<String, dynamic>.of(json)..remove('lastOpened');
    if (ignoreNotes) core.remove('notes');
    if (name != null) core['name'] = name;
    return sha256.convert(utf8.encode(jsonEncode(_canonical(core)))).toString();
  }

  /// Whether a sidecar of [craft] is compared without its `notes`: in a nalbinding sidecar they are
  /// only a copy of the project's notes (the `.plynal` holds them, and nothing reads the copy),
  /// which earlier builds wrote on every save and this one leaves empty. A project is the same
  /// whether its sidecar still has the old copy or not.
  static bool sidecarNotesIgnored(BackupCraft craft) => craft == BackupCraft.nalbinding;

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
          // A nalbinding sidecar may still hold an earlier build's copy of the notes, which does
          // not count: it is read up to the size of a document, as a backup reads it.
          final ignoreNotes = sidecarNotesIgnored(f.layout.craft);
          final length = await local.length();
          if (length > (ignoreNotes ? limits.maxFileBytes : limits.maxSidecarBytes)) return false;
          final bytes = await local.readAsBytes();
          final mine = length <= limits.maxSidecarBytes && _decodesInline(bytes)
              ? _localSidecarDigest(bytes, ignoreNotes)
              : await _localSidecarDigestInBackground(bytes, ignoreNotes);
          if (mine != sidecarDigest) return false;
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

  /// [sidecarDigest] of a library sidecar's [bytes], or null when it is not a JSON object. Throws
  /// when it is not JSON.
  static String? _localSidecarDigest(Uint8List bytes, bool ignoreNotes) {
    final json = jsonDecode(utf8.decode(bytes));
    return json is Map<String, dynamic> ? sidecarDigest(json, ignoreNotes: ignoreNotes) : null;
  }

  /// [_localSidecarDigest] on a background isolate.
  static Future<String?> _localSidecarDigestInBackground(Uint8List bytes, bool ignoreNotes) =>
      Isolate.run(() => _localSidecarDigest(bytes, ignoreNotes), debugName: 'sidecar digest');

  /// The size and digest of a nalbinding project's `.plynal` as a restored copy named [name] has it
  /// (see [_withName]), read again from the archive and checked against its recorded digest.
  Future<({int size, String sha256})> _renamedNative(
      RandomAccessFile raf, _ProjectAccumulator acc, String name) async {
    final f = acc.files.firstWhere((f) => f.layout.role == BackupFileRole.native);
    final (digest, bytes) = await _hashSlice(raf, f.dataOffset, f.size, keep: true);
    if (digest != f.sha256) {
      throw BackupException(BackupProblem.damaged, detail: '${f.layout.pathFor(acc.id)} changed');
    }
    final renamed = await _plynalWithName(bytes!, name);
    return (size: renamed.length, sha256: _hexSha256(renamed));
  }

  /// [_withName] of a `.plynal` (up to the per-file limit, unlike a sidecar), on a background
  /// isolate so the decode never holds up the UI.
  static Future<Uint8List> _plynalWithName(Uint8List json, String name) =>
      Isolate.run(() => _withName(json, name), debugName: 'plynal rename');

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
        await dest.writeAsBytes(
            await _stagedSidecar(bytes!, relink, materialRelinks ?? _noMaterialRelinks,
                rename ? project.targetName! : null),
            flush: true);
        continue;
      }
      if (rename &&
          (f.layout.role == BackupFileRole.sidecar ||
              (f.layout.role == BackupFileRole.native &&
                  project.craft == BackupCraft.nalbinding))) {
        final (digest, bytes) = await _hashSlice(raf, f.dataOffset, f.size, keep: true);
        if (digest != f.sha256) throw StateError('${f.layout.pathFor(project.id)} changed');
        final renamed = f.layout.role == BackupFileRole.native
            ? await _plynalWithName(bytes!, project.targetName!)
            : await _sidecarWithName(bytes!, project.targetName!);
        await dest.writeAsBytes(renamed, flush: true);
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

  /// A backup sidecar's [bytes] pointed at the loom copy [relink] and the material and swatch
  /// copies of [materialRelinks], and renamed [name] when given (a copy), every other key kept;
  /// decoded off the calling isolate when large ([inlineSidecarValues]).
  static Future<Uint8List> _stagedSidecar(Uint8List bytes, (String, String)? relink,
      _MaterialRelinks materialRelinks, String? name) async {
    Uint8List work() {
      final json = _rewrittenSidecar(
          jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>, relink, materialRelinks);
      if (name != null) json['name'] = name;
      return Uint8List.fromList(utf8.encode(jsonEncode(json)));
    }

    if (_decodesInline(bytes)) return work();
    return Isolate.run(work, debugName: 'sidecar relink');
  }

  /// [_withName] of a backup sidecar, off the calling isolate when large ([inlineSidecarValues]).
  static Future<Uint8List> _sidecarWithName(Uint8List bytes, String name) async {
    if (_decodesInline(bytes)) return _withName(bytes, name);
    return Isolate.run(() => _withName(bytes, name), debugName: 'sidecar rename');
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

/// What a restore learns from a project's sidecar (`LibraryBackup._backupSidecarFacts`): its name,
/// its digests as is and renamed for a copy, the loom and the records it names, and whether its
/// schema is newer than this build's.
typedef _SidecarFacts = ({
  String name,
  String digest,
  String copyDigest,
  String? loomPlanId,
  Set<String> materials,
  Set<String> swatches,
  bool newer,
});

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
  bool tooComplex = false;
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
