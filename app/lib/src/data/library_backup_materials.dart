// Materials and swatches in a library backup (roadmap M8-01, ADR 0016): a full backup carries
// `materials.json` (verbatim, at the archive root, like `looms.json`) and every swatch's photos under
// `swatches/<swatch id>.photos/<name>.<ext>`. A single-project export carries neither: a project's
// sidecar keeps each linked record's name.
//
// A restore reads `materials.json` as untrusted input with the engine and compares each record with
// the library by id: new (added under its id), the same (skipped), or different (offered as a copy
// named "<name> (restored)" under an id derived from the record, so a repeated restore recognizes
// it). A swatch is the same only when its record and every photo the backup has for it already are.
// Projects restored in the same restore that link a record restored as a copy are pointed at the
// copy (their sidecar's links rewritten, every other key kept), and so are the yarns of swatches it
// adds. An existing record is never changed.

part of 'library_backup.dart';

/// The materials and swatches a full backup carries, at the archive root.
const String backupMaterialsPath = 'materials.json';

/// The archive (and documents) folder of swatch photos.
const String backupSwatchDir = 'swatches';

/// A swatch photo's place in the layout: `swatches/<swatch id>.photos/<name>.<ext>`.
class SwatchPhotoPath {
  const SwatchPhotoPath(this.swatchId, this.photoName);

  final String swatchId;
  final String photoName;

  String pathFor(String id) => '$backupSwatchDir/$id.photos/$photoName';
}

/// Classify [path] as a swatch photo, or null. The same grammar as a project photo, so a path that
/// classifies can only name a file inside the swatch photo folder.
SwatchPhotoPath? classifySwatchPhotoPath(String path) {
  if (path.isEmpty || path.startsWith('/') || path.contains(r'\') || path.contains('\u0000')) {
    return null;
  }
  final segments = path.split('/');
  if (segments.length != 3 || segments.first != backupSwatchDir) return null;
  final folder = segments[1];
  if (!folder.endsWith('.photos')) return null;
  final id = folder.substring(0, folder.length - '.photos'.length);
  if (!_idPattern.hasMatch(id)) return null;
  final m = _photoPattern.firstMatch(segments[2]);
  if (m == null || !_photoExtensions.contains(m.group(1)!.toLowerCase())) return null;
  return SwatchPhotoPath(id, segments[2]);
}

/// The materials file a full backup carries: the bytes, verbatim, and what they hold.
class BackupMaterialsFile {
  BackupMaterialsFile(this.bytes, {required this.materials, required this.swatches})
      : sha256 = _hexSha256(bytes);

  final Uint8List bytes;
  final int materials;
  final int swatches;
  final String sha256;
}

/// One swatch photo going into a backup.
class BackupSwatchPhoto {
  const BackupSwatchPhoto({
    required this.path,
    required this.sourcePath,
    required this.size,
    required this.sha256,
  });

  final SwatchPhotoPath path;
  final String sourcePath;
  final int size;
  final String sha256;

  String get archivePath => path.pathFor(path.swatchId);
}

/// What a backup needs from the materials library (ADR 0016). Production wires the materials
/// repository and the engine's reader; host tests pass stand-ins.
class MaterialBackupHooks {
  const MaterialBackupHooks({
    required this.currentFile,
    required this.decode,
    required this.current,
    required this.add,
    this.fits,
  });

  /// The `materials.json` bytes to back up, verbatim, or null when there is none.
  final Future<Uint8List?> Function() currentFile;

  /// The records in `materials.json` bytes (untrusted). Throws (a [MaterialsFileException] says why).
  final Future<MaterialLibrary> Function(Uint8List bytes) decode;

  /// The library's records now. Throws when they cannot be read.
  final Future<MaterialLibrary> Function() current;

  /// Add records in one write and return how to undo it exactly.
  final Future<Future<void> Function()> Function(
      List<MaterialRecord> materials, List<SwatchRecord> swatches) add;

  /// Whether a library this large could be written (the engine refuses a file over its size limit).
  /// Null: not checked.
  final Future<bool> Function(MaterialLibrary merged)? fits;
}

/// One record of a backup's materials, as the restore preview shows it.
class RestoreRecord {
  const RestoreRecord._({
    required this.isSwatch,
    required this.id,
    required this.name,
    required this.summary,
    required this.status,
    this.material,
    this.swatch,
    this.copyId,
    this.copyName,
    this.photos = const [],
    this.projects = 0,
    this.localName,
    this.swatchesNaming = 0,
  });

  /// A swatch (else a material).
  final bool isSwatch;

  /// The record's id in the backup.
  final String id;
  final String name;
  final String summary;

  /// [RestoreStatus.add], [RestoreStatus.alreadyPresent] or [RestoreStatus.conflict].
  final RestoreStatus status;

  /// The record as the backup has it.
  final MaterialRecord? material;
  final SwatchRecord? swatch;

  /// The id and name of the copy that stands for this record (a conflict's copy, or the copy an
  /// earlier restore of this backup made).
  final String? copyId;
  final String? copyName;

  /// The swatch's photos in the archive.
  final List<ArchivedSwatchPhoto> photos;

  /// How many projects restored from this backup link this record.
  final int projects;

  /// For a conflict: the name of the different record the library holds under this id, or null when
  /// it holds none (the id is taken by a photo folder alone). Unticking the copy leaves the restored
  /// projects (and swatches) naming that record.
  final String? localName;

  /// For a material: how many swatches this restore adds name it.
  final int swatchesNaming;

  /// Unique within a backup: `material/<id>` or `swatch/<id>`.
  String get key => '${isSwatch ? 'swatch' : 'material'}/$id';

  int get photoCount => photos.length;

  /// The id this record has in the library once restored: its own for a new one, the copy's for a
  /// conflict.
  String? get targetId => switch (status) {
        RestoreStatus.add => id,
        RestoreStatus.conflict => copyId,
        _ => null,
      };

  RestoreRecord _with({int? projects, int? swatchesNaming}) => RestoreRecord._(
        isSwatch: isSwatch,
        id: id,
        name: name,
        summary: summary,
        status: status,
        material: material,
        swatch: swatch,
        copyId: copyId,
        copyName: copyName,
        photos: photos,
        projects: projects ?? this.projects,
        localName: localName,
        swatchesNaming: swatchesNaming ?? this.swatchesNaming,
      );
}

/// A swatch photo in the archive: where it is, its size and its verified digest.
class ArchivedSwatchPhoto {
  const ArchivedSwatchPhoto(this.path, this.size, this.dataOffset, this.sha256);

  final SwatchPhotoPath path;
  final int size;
  final int dataOffset;
  final String sha256;
}

/// A backup's materials and swatches: [items] when they can be restored, otherwise [refusal].
class RestoreMaterials {
  const RestoreMaterials.available(this.items, {this.localMaterials = 0, this.localSwatches = 0})
      : refusal = null;
  const RestoreMaterials.refused(String this.refusal)
      : items = const [],
        localMaterials = 0,
        localSwatches = 0;

  final List<RestoreRecord> items;
  final String? refusal;

  /// How many records the library holds now (the limits count what is added to them).
  final int localMaterials;
  final int localSwatches;

  /// Why the records selected with [skipped] left out cannot be added (they would pass a record
  /// limit), or null when they fit. Only what will be added counts. When this is not null, a restore
  /// adds no material or swatch and restores the projects without them.
  String? limitProblem(Set<String> skipped) {
    final sel = selected(skipped);
    return localMaterials + sel.materials.length > MaterialLimits.maxMaterials ||
            localSwatches + sel.swatches.length > MaterialLimits.maxSwatches
        ? tooMany
        : null;
  }

  List<RestoreRecord> withStatus(RestoreStatus status, {required bool swatches}) => [
        for (final i in items)
          if (i.status == status && i.isSwatch == swatches) i
      ];

  /// The copies links must point at when [skipped] conflicts are left out: backup id to the copy's
  /// id and name, for materials and for swatches.
  ({Map<String, (String, String)> materials, Map<String, (String, String)> swatches}) relinks(
      Set<String> skipped) {
    final materials = <String, (String, String)>{};
    final swatches = <String, (String, String)>{};
    for (final i in items) {
      if (i.copyId == null) continue;
      final used = i.status == RestoreStatus.alreadyPresent ||
          (i.status == RestoreStatus.conflict && !skipped.contains(i.key));
      if (!used) continue;
      (i.isSwatch ? swatches : materials)[i.id] = (i.copyId!, i.copyName!);
    }
    return (materials: materials, swatches: swatches);
  }

  /// The records a restore adds (new ones, and the conflicts not in [skipped] as their copies), the
  /// swatches' yarns pointed at the materials restored as copies.
  ({List<MaterialRecord> materials, List<SwatchRecord> swatches}) selected(Set<String> skipped) {
    final copies = relinks(skipped).materials;
    final materials = <MaterialRecord>[];
    final swatches = <SwatchRecord>[];
    for (final i in items) {
      final adds = i.status == RestoreStatus.add ||
          (i.status == RestoreStatus.conflict && !skipped.contains(i.key));
      if (!adds) continue;
      if (i.isSwatch) {
        final s = i.status == RestoreStatus.add
            ? i.swatch!
            : i.swatch!.copyWith(id: i.copyId, name: i.copyName);
        swatches.add(LibraryBackup.swatchWithMaterialCopies(s, copies));
      } else {
        materials.add(i.status == RestoreStatus.add
            ? i.material!
            : i.material!.copyWith(id: i.copyId, name: i.copyName));
      }
    }
    return (materials: materials, swatches: swatches);
  }

  static const String unreadable = 'The materials in this backup could not be read.';
  static const String newer = 'The materials in this backup were saved by a newer version of Ply. '
      'Update the app to restore them.';
  static const String localUnreadable = 'Your materials on this device could not be read, so the '
      'materials in this backup cannot be added.';
  static const String tooMany = 'Adding these would pass ${MaterialLimits.maxMaterials} materials '
      'or ${MaterialLimits.maxSwatches} swatches. Untick some copies, or the projects are restored '
      'without the materials and swatches.';
  static const String tooLarge = 'Adding these would make your materials file larger than Ply can '
      'open, so the materials and swatches in this backup are not restored. The projects are.';
  static const String unsupported = 'This version of Ply cannot restore materials.';
}

extension _MaterialsBackup on LibraryBackup {
  /// The materials file a full backup carries (verbatim) and its swatches' photos, or null when
  /// there are no records. When the file cannot be read, is newer, or is over its limit, the backup
  /// is made without it (and without the photos) and the second value says why.
  Future<(BackupMaterialsFile?, List<BackupSwatchPhoto>, String?)> _materialsFile(
      Directory docs) async {
    final hooks = materials;
    if (hooks == null) return (null, const <BackupSwatchPhoto>[], null);
    final MaterialLibrary lib;
    final Uint8List bytes;
    try {
      final read = await hooks.currentFile();
      if (read == null) return (null, const <BackupSwatchPhoto>[], null);
      bytes = read;
      if (bytes.length > limits.maxMaterialsBytes) {
        PlyLog.instance.warn('Backup: materials.json left out (${bytes.length} bytes).');
        return (null, const <BackupSwatchPhoto>[], BackupPlan.materialsTooLarge);
      }
      lib = await hooks.decode(bytes);
    } on MaterialsFileException catch (e) {
      PlyLog.instance.warn('Backup: materials left out ($e).');
      return (
        null,
        const <BackupSwatchPhoto>[],
        switch (e.problem) {
          MaterialsFileProblem.newerVersion => BackupPlan.materialsNewer,
          MaterialsFileProblem.tooLarge => BackupPlan.materialsTooLarge,
          MaterialsFileProblem.unreadable => BackupPlan.materialsUnreadable,
        },
      );
    } catch (e) {
      PlyLog.instance.warn('Backup: materials left out ($e).');
      return (null, const <BackupSwatchPhoto>[], BackupPlan.materialsUnreadable);
    }
    if (lib.isEmpty) return (null, const <BackupSwatchPhoto>[], null);
    final photos = <BackupSwatchPhoto>[];
    for (final s in lib.swatches) {
      if (!isBackupProjectId(s.id)) continue;
      final dir = Directory(p.join(docs.path, backupSwatchDir, '${s.id}.photos'));
      if (await FileSystemEntity.type(dir.path, followLinks: false) !=
          FileSystemEntityType.directory) {
        continue;
      }
      final found = <File>[];
      await for (final ent in dir.list(followLinks: false)) {
        if (ent is! File) continue;
        final m = _photoPattern.firstMatch(p.basename(ent.path));
        if (m != null && _photoExtensions.contains(m.group(1)!.toLowerCase())) found.add(ent);
      }
      found.sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
      for (final f in found) {
        final max = limits.maxFileBytes;
        if (await f.length() > max) {
          throw BackupException(BackupProblem.fileTooLarge, projectName: s.displayName, limit: max);
        }
        final (digest, size) = await LibraryBackup._hashFile(f, max);
        if (size > max) {
          throw BackupException(BackupProblem.fileTooLarge, projectName: s.displayName, limit: max);
        }
        photos.add(BackupSwatchPhoto(
          path: SwatchPhotoPath(s.id, p.basename(f.path)),
          sourcePath: f.path,
          size: size,
          sha256: digest,
        ));
      }
    }
    return (
      BackupMaterialsFile(bytes, materials: lib.materials.length, swatches: lib.swatches.length),
      photos,
      null,
    );
  }

  /// The backup's materials as untrusted input, compared with the library (see the file header).
  Future<RestoreMaterials?> _classifyMaterials(
      Uint8List bytes, Map<String, List<ArchivedSwatchPhoto>> photos, Directory docs) async {
    final hooks = materials;
    if (hooks == null) return const RestoreMaterials.refused(RestoreMaterials.unsupported);
    final MaterialLibrary backed;
    try {
      backed = await hooks.decode(bytes);
    } on MaterialsFileException catch (e) {
      return RestoreMaterials.refused(e.problem == MaterialsFileProblem.newerVersion
          ? RestoreMaterials.newer
          : RestoreMaterials.unreadable);
    } catch (_) {
      return const RestoreMaterials.refused(RestoreMaterials.unreadable);
    }
    if (backed.isEmpty) return null;
    final MaterialLibrary local;
    try {
      local = await hooks.current();
    } catch (_) {
      return const RestoreMaterials.refused(RestoreMaterials.localUnreadable);
    }
    final items = <RestoreRecord>[];
    // Materials first: a swatch copy's yarns point at the materials restored as copies.
    final localMaterials = {for (final m in local.materials) m.id: m};
    final takenMaterials = {...localMaterials.keys};
    for (final m in backed.materials) {
      final mine = localMaterials[m.id];
      if (mine == null && takenMaterials.add(m.id)) {
        items.add(RestoreRecord._(
            isSwatch: false,
            id: m.id,
            name: m.displayName,
            summary: m.summary,
            status: RestoreStatus.add,
            material: m));
        continue;
      }
      if (mine == m) {
        items.add(RestoreRecord._(
            isSwatch: false,
            id: m.id,
            name: m.displayName,
            summary: m.summary,
            status: RestoreStatus.alreadyPresent,
            material: m));
        continue;
      }
      final name = LibraryBackup.recordCopyName(m.name, 'Unnamed material');
      var copyId = LibraryBackup._derivedId('ply.materials restored material', m.canonicalKey);
      if (localMaterials[copyId] == m.copyWith(id: copyId, name: name)) {
        items.add(RestoreRecord._(
            isSwatch: false,
            id: m.id,
            name: m.displayName,
            summary: m.summary,
            status: RestoreStatus.alreadyPresent,
            material: m,
            copyId: copyId,
            copyName: name));
        continue;
      }
      while (takenMaterials.contains(copyId)) {
        copyId = LibraryBackup._uuid.v4();
      }
      takenMaterials.add(copyId);
      items.add(RestoreRecord._(
          isSwatch: false,
          id: m.id,
          name: m.displayName,
          summary: m.summary,
          status: RestoreStatus.conflict,
          material: m,
          copyId: copyId,
          copyName: name,
          localName: mine?.displayName));
    }
    final materialCopies = RestoreMaterials.available(items).relinks(const {}).materials;
    final localSwatches = {for (final s in local.swatches) s.id: s};
    // An id is taken by a swatch on the device, or by a photo folder left under it, compared without
    // case: on a case-insensitive file system two ids that differ only in case are one folder.
    final takenSwatches = {
      for (final id in localSwatches.keys) id.toLowerCase(),
      ...await _photoFolderIds(docs),
    };
    for (final s in backed.swatches) {
      final mine = localSwatches[s.id];
      final shots = photos[s.id] ?? const <ArchivedSwatchPhoto>[];
      if (mine == null && takenSwatches.add(s.id.toLowerCase())) {
        items.add(_swatchItem(s, RestoreStatus.add, shots));
        continue;
      }
      // The same record (as backed up, or with its yarns already pointed at material copies) with
      // every photo of the backup already on the device.
      bool same(SwatchRecord? local, SwatchRecord expect) =>
          local != null &&
          (local == expect ||
              local == LibraryBackup.swatchWithMaterialCopies(expect, materialCopies));
      if (same(mine, s) && await _photosPresent(docs, s.id, shots)) {
        items.add(_swatchItem(s, RestoreStatus.alreadyPresent, shots));
        continue;
      }
      final name = LibraryBackup.recordCopyName(s.name, 'Unnamed swatch');
      var copyId = LibraryBackup._derivedId('ply.materials restored swatch',
          [s.canonicalKey, for (final f in shots) '${f.path.photoName} ${f.sha256}'].join('\n'));
      final copy = s.copyWith(id: copyId, name: name);
      if (same(localSwatches[copyId], copy) && await _photosPresent(docs, copyId, shots)) {
        items.add(
            _swatchItem(s, RestoreStatus.alreadyPresent, shots, copyId: copyId, copyName: name));
        continue;
      }
      while (takenSwatches.contains(copyId.toLowerCase())) {
        copyId = LibraryBackup._uuid.v4();
      }
      takenSwatches.add(copyId.toLowerCase());
      items.add(_swatchItem(s, RestoreStatus.conflict, shots,
          copyId: copyId, copyName: name, localName: mine?.displayName));
    }
    // How many of the swatches this restore adds name each material.
    final naming = <String, int>{};
    for (final i in items) {
      if (!i.isSwatch || i.status == RestoreStatus.alreadyPresent) continue;
      for (final id in {for (final y in i.swatch!.yarns) y.materialId}.whereType<String>()) {
        naming[id] = (naming[id] ?? 0) + 1;
      }
    }
    final plan = RestoreMaterials.available(
        List.unmodifiable([
          for (final i in items) i.isSwatch ? i : i._with(swatchesNaming: naming[i.id] ?? 0),
        ]),
        localMaterials: local.materials.length,
        localSwatches: local.swatches.length);
    // The record limits depend on which copies are kept, so the preview and the restore check them
    // for the selection (RestoreMaterials.limitProblem). The size of the merged file is checked here
    // for the largest selection: when even that cannot be written the materials are not offered, and
    // the projects restore without them.
    final fits = hooks.fits;
    if (fits != null) {
      final all = plan.selected(const {});
      final merged = MaterialLibrary(
        materials: [...local.materials, ...all.materials],
        swatches: [...local.swatches, ...all.swatches],
      );
      bool ok;
      try {
        ok = await fits(merged);
      } catch (_) {
        ok = false;
      }
      if (!ok) return const RestoreMaterials.refused(RestoreMaterials.tooLarge);
    }
    return plan;
  }

  RestoreRecord _swatchItem(SwatchRecord s, RestoreStatus status, List<ArchivedSwatchPhoto> shots,
          {String? copyId, String? copyName, String? localName}) =>
      RestoreRecord._(
        isSwatch: true,
        id: s.id,
        name: s.displayName,
        summary: s.summary,
        status: status,
        swatch: s,
        copyId: copyId,
        copyName: copyName,
        photos: List.unmodifiable(shots),
        localName: localName,
      );

  /// The lowercase ids of the photo folders under `<docs>/swatches`.
  Future<Set<String>> _photoFolderIds(Directory docs) async {
    final dir = Directory(p.join(docs.path, backupSwatchDir));
    final ids = <String>{};
    if (!await dir.exists()) return ids;
    await for (final ent in dir.list(followLinks: false)) {
      final name = p.basename(ent.path);
      if (name.endsWith('.photos')) ids.add(name.substring(0, name.length - 7).toLowerCase());
    }
    return ids;
  }

  /// Whether every photo of [shots] is in `<docs>/swatches/<id>.photos/` with the same bytes.
  Future<bool> _photosPresent(Directory docs, String id, List<ArchivedSwatchPhoto> shots) async {
    try {
      for (final f in shots) {
        final local = File(p.join(docs.path, backupSwatchDir, '$id.photos', f.path.photoName));
        if (await FileSystemEntity.type(local.path, followLinks: false) !=
            FileSystemEntityType.file) {
          return false;
        }
        if (await local.length() != f.size) return false;
        final (digest, _) = await LibraryBackup._hashFile(local, f.size);
        if (digest != f.sha256) return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// [m] with, for each record, how many of the projects a restore would add link it.
  static RestoreMaterials _withProjectCounts(RestoreMaterials m, List<RestoreProject> projects) {
    if (m.refusal != null) return m;
    final mats = <String, int>{};
    final sws = <String, int>{};
    for (final p in projects) {
      if (p.status != RestoreStatus.add && p.status != RestoreStatus.conflict) continue;
      for (final id in p.linkedMaterials) {
        mats[id] = (mats[id] ?? 0) + 1;
      }
      for (final id in p.linkedSwatches) {
        sws[id] = (sws[id] ?? 0) + 1;
      }
    }
    return RestoreMaterials.available(
        List.unmodifiable([
          for (final i in m.items) i._with(projects: (i.isSwatch ? sws : mats)[i.id] ?? 0),
        ]),
        localMaterials: m.localMaterials,
        localSwatches: m.localSwatches);
  }

  /// Copy each selected swatch's photos out of the archive into [staging] under its target id, the
  /// digests checked again. Returns the swatch folders staged, as `swatches/<id>.photos`.
  Future<List<String>> _stageSwatchPhotos(
      RandomAccessFile raf, Directory staging, List<RestoreRecord> swatches) async {
    final folders = <String>[];
    for (final s in swatches) {
      final id = s.targetId;
      if (id == null || s.photos.isEmpty) continue;
      for (final f in s.photos) {
        final dest = File(p.join(staging.path, backupSwatchDir, '$id.photos', f.path.photoName));
        await dest.parent.create(recursive: true);
        final out = await dest.open(mode: FileMode.writeOnly);
        try {
          final (digest, _) =
              await LibraryBackup._hashSlice(raf, f.dataOffset, f.size, copyTo: out);
          if (digest != f.sha256) throw StateError('${f.path.pathFor(s.id)} changed');
          await out.flush();
        } finally {
          await out.close();
        }
      }
      folders.add('$backupSwatchDir/$id.photos');
    }
    return folders;
  }
}

/// The material and swatch copies links must point at: backup id to the copy's id and name.
typedef _MaterialRelinks = ({
  Map<String, (String, String)> materials,
  Map<String, (String, String)> swatches,
});

const _MaterialRelinks _noMaterialRelinks = (
  materials: <String, (String, String)>{},
  swatches: <String, (String, String)>{},
);
