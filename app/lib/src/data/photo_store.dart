import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'photo_metadata.dart';

/// A photo that could not be read as an image, so it was not stored (it might have held metadata Ply
/// could not remove).
class PhotoNotReadableException implements Exception {
  const PhotoNotReadableException();

  String get message => 'This photo could not be read, so it was not added.';

  @override
  String toString() => message;
}

/// On-device storage for a pattern's PROJECT PHOTOS: `<documents>/<subdir>/<id>.photos/*.jpg`, kept
/// beside the pattern's sidecar. Craft-agnostic — the editor passes its craft [subdir] (e.g. 'knits')
/// and the pattern [id]. Photos NEVER leave the device. Pure `dart:io`; tests set [docsOverride] to
/// avoid `path_provider` (mirrors the repositories' `dirOverride`).
class PhotoStore {
  PhotoStore({required this.subdir, required this.id, this.docsOverride});

  final String subdir;
  final String id;

  /// Tests point this at a temp dir to stand in for the app documents directory.
  final Directory? docsOverride;

  static const Uuid _uuid = Uuid();

  Future<Directory> _dir() async {
    final docs = docsOverride ?? await getApplicationDocumentsDirectory();
    final d = Directory(p.join(docs.path, subdir, '$id.photos'));
    await d.create(recursive: true);
    return d;
  }

  static bool _isImage(String path) {
    const exts = {'.jpg', '.jpeg', '.png', '.heic', '.webp'};
    return exts.contains(p.extension(path).toLowerCase());
  }

  /// The stored photos, newest first (by file modified time).
  Future<List<File>> list() async {
    final dir = await _dir();
    if (!await dir.exists()) return const [];
    final stamped = <(File, DateTime)>[];
    await for (final e in dir.list()) {
      if (e is File && _isImage(e.path)) {
        stamped.add((e, (await e.stat()).modified));
      }
    }
    stamped.sort((a, b) => b.$2.compareTo(a.$2));
    return [for (final s in stamped) s.$1];
  }

  /// Copy [source] (a freshly captured / picked image) into the store, returning the stored file.
  /// Keeps the source extension (defaults to `.jpg`).
  ///
  /// The photo's metadata is removed first ([cleanPhoto], ADR 0016): a JPEG loses its EXIF (GPS
  /// position, device, time), XMP, IPTC and comments but keeps its orientation, and a PNG its text,
  /// EXIF and time chunks; a WebP or HEIC is kept as it is. A JPEG or PNG that cannot be read is not
  /// stored ([PhotoNotReadableException]). Photos already in the store are never touched.
  ///
  /// Atomic: the bytes go to `<name>.tmp` (not an image extension, so [list] never shows it), are
  /// flushed to disk, and only then renamed to the final name. A failed or interrupted copy therefore
  /// never leaves a truncated photo in the store; a failed copy also removes its temp file.
  Future<File> add(File source) async {
    final dir = await _dir();
    final ext = p.extension(source.path).toLowerCase();
    final dest = File(p.join(dir.path, '${_uuid.v4()}${ext.isEmpty ? '.jpg' : ext}'));
    final tmp = File('${dest.path}.tmp');
    try {
      final cleaned = cleanPhoto(await source.readAsBytes());
      if (cleaned == null) throw const PhotoNotReadableException();
      await tmp.writeAsBytes(cleaned.bytes, flush: true);
      return await tmp.rename(dest.path);
    } catch (_) {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {/* best effort; a stray .tmp is never listed and goes with the folder */}
      rethrow;
    }
  }

  /// Delete one stored photo. Tolerant of an already-missing file.
  Future<void> delete(File photo) async {
    if (await photo.exists()) {
      try {
        await photo.delete();
      } catch (_) {/* tolerate races */}
    }
  }
}
