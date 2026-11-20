import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../diagnostics/log_buffer.dart';
import '../models/draft_meta.dart';
import '../models/native_format.dart';
import '../models/tablet_band.dart';
import '../rust/api.dart';
import '../rust/tablet_dto.dart';
import 'progress_repository.dart';
import 'sidecar_read.dart' show readListedSidecars;
import 'sidecar_writes.dart';

/// The sidecar `craft` of a tablet weaving band: the serde name of `ply_common::CraftKind`'s arm.
const String kTabletCraft = 'TabletWeaving';

/// An in-memory pairing of a saved band's sidecar with its files (built by
/// [TabletRepository.listBands]).
class TabletEntry {
  const TabletEntry({
    required this.id,
    required this.meta,
    required this.bandPath,
    this.thumbPath,
  });

  /// The uuid stem shared by `<id>.plytab`, `<id>.json` and `<id>.png`.
  final String id;

  /// The sidecar (`meta.craft == 'TabletWeaving'`).
  final DraftMeta meta;

  /// The `<id>.plytab` document (always present: the list skips a sidecar without one).
  final String bandPath;

  /// The `<id>.png` thumbnail, or null when there is none (a save or a restore writes it).
  final String? thumbPath;
}

/// The one place the app touches the generated bridge symbols for `ply-tablet` (M10-02, ADR 0018),
/// the tablet analog of `KnitRepository`. Screens and editor state depend on this, never on
/// `api.dart` directly.
///
/// It owns the engine calls (validation, windows of picks, the band face and turning chart as RGBA,
/// the state after a pick, checkpoints, working instructions), the native `.plytab` parse and
/// write, and on-device persistence: `<documents>/tablets/<id>.{plytab,json,png}`, the native
/// document first and the sidecar LAST, every write atomic, a newer or unreadable file never
/// replaced, and a one-time `<id>.plytab.v<n>.bak` of the original kept before a later format
/// version upgrades it (ADR 0002). Thumbnails are caches, never backed up.
class TabletRepository {
  TabletRepository();

  // --- the engine ---------------------------------------------------------------------------------

  /// Parse a `.plytab` file into a document. A file this build must not open (saved by a newer Ply,
  /// another format, unreadable or too large) throws a [NativeFormatException]. A band with
  /// structural errors opens (validation lists them).
  Future<TabletDocumentDto> parse(String text) async {
    try {
      return await tabletParse(text: text);
    } on TabletFormatFailure catch (f) {
      throw nativeFormatExceptionFromTablet(f);
    }
  }

  /// The document as a current-version `.plytab` envelope. Throws (a sentence) for a band past the
  /// sizes Ply opens: the band stays unsaved in the editor.
  Future<String> write(TabletDocumentDto doc) => tabletWrite(doc: doc);

  /// The `.plytab` schema version this build writes.
  Future<int> schemaVersion() => tabletSchemaVersion();

  /// The schema version a `.plytab` file's text says it has, read by the engine from the envelope
  /// alone (nothing else in the file is decoded, however large); null when it is not a `.plytab`
  /// envelope. A newer version is returned as found. Never decode a file in Dart to learn this.
  Future<int?> documentVersion(String text) => tabletDocumentVersion(text: text);

  /// Whether the tablet rules still await a tablet weaver's review (every computed face, chart and
  /// thumbnail says so while they do).
  Future<bool> reviewPending() => tabletReviewPending();

  /// Every diagnostic of the band, with typed locations, and the counts by severity.
  Future<TabletReportDto> validate(TabletDocumentDto doc) => tabletValidate(doc: doc);

  /// The band's checkpoints (for paging through a long band). Throws a [TabletRunFailure] for a band
  /// with structural errors.
  Future<List<TabletCheckpointDto>> checkpoints(TabletDocumentDto doc) =>
      tabletCheckpoints(doc: doc);

  /// Simulated picks [first] to [last] (at most 50,000 cells), resumed from [checkpoint] when it
  /// belongs to this band.
  Future<TabletWindowDto> window(TabletDocumentDto doc, int first, int last,
          {TabletCheckpointDto? checkpoint}) =>
      tabletSimulateWindow(doc: doc, first: first, last: last, checkpoint: checkpoint);

  /// Every card's state after [pick] picks.
  Future<TabletBandStateDto> stateAfter(TabletDocumentDto doc, int pick,
          {TabletCheckpointDto? checkpoint}) =>
      tabletStateAfter(doc: doc, pick: pick, checkpoint: checkpoint);

  /// One face of picks [first] to [last] as RGBA, pick 1 at the bottom.
  Future<TabletRasterDto> renderFace(
    TabletDocumentDto doc,
    int first,
    int last, {
    required TabletFaceKind face,
    required int cellPx,
    bool letters = false,
    TabletCheckpointDto? checkpoint,
  }) =>
      tabletRenderFace(
        doc: doc,
        first: first,
        last: last,
        face: face,
        cellPx: cellPx,
        letters: letters,
        checkpoint: checkpoint,
      );

  /// The turning chart of picks [first] to [last] as RGBA, pick 1 at the bottom.
  Future<TabletRasterDto> renderTurning(TabletDocumentDto doc, int first, int last,
          {required int cellPx, TabletCheckpointDto? checkpoint}) =>
      tabletRenderTurning(
          doc: doc, first: first, last: last, cellPx: cellPx, checkpoint: checkpoint);

  /// The written working instructions, at most [maxLines] lines.
  Future<TabletInstructionsDto> instructions(TabletDocumentDto doc, {int maxLines = 2000}) =>
      tabletInstructions(doc: doc, maxLines: maxLines);

  /// A new band to start from (no FFI).
  TabletDocumentDto blank({int cards = 8, TabletPreset preset = kFirstTabletPreset}) =>
      blankTabletDocument(cards: cards, preset: preset);

  /// Decode a raster into a [ui.Image]. A 0 by 0 raster (an empty window) has no pixels and
  /// `decodeImageFromPixels` would never call back, so it fails fast instead.
  Future<ui.Image> decode(TabletRasterDto r) {
    if (r.width == 0 || r.height == 0) {
      return Future<ui.Image>.error(StateError('cannot decode an empty band chart'));
    }
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
        r.rgba, r.width, r.height, ui.PixelFormat.rgba8888, completer.complete);
    return completer.future;
  }

  // --- persistence: <documents>/tablets/<id>.{plytab,json,png} -------------------------------------

  /// The library folder name under the documents directory.
  static const String folder = 'tablets';

  /// Pixels per cell of a thumbnail, and the most picks it shows (from pick 1).
  static const int thumbnailCellPx = 4;
  static const int thumbnailPicks = 96;

  static const Uuid _uuid = Uuid();
  Directory? _dirCache;

  /// Tests point this at a temp dir so the file paths run without `path_provider`. Null in
  /// production.
  Directory? dirOverride;

  Future<Directory> _dir() async {
    final override = dirOverride;
    if (override != null) {
      await override.create(recursive: true);
      return override;
    }
    final cached = _dirCache;
    if (cached != null) return cached;
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, folder));
    await dir.create(recursive: true);
    _dirCache = dir;
    return dir;
  }

  String _bandPath(Directory d, String id) => p.join(d.path, '$id.plytab');
  String _jsonPath(Directory d, String id) => p.join(d.path, '$id.json');
  String _pngPath(Directory d, String id) => p.join(d.path, '$id.png');

  /// The one-time backup of a band's original bytes, kept before a save upgrades it from schema
  /// [version] to the current one.
  static String backupPath(String bandPath, int version) => '$bandPath.v$version.bak';

  /// Save a band as `<id>.{plytab,json,png}`, returning its id. The document's name is the
  /// sidecar's. The `.plytab` is written first and the sidecar last (the list never sees a sidecar
  /// without its band); the thumbnail is best-effort.
  ///
  /// Over an existing `.plytab`: an OLDER schema version is first copied to `<id>.plytab.v<old>.bak`
  /// (once); a NEWER or unreadable file is never replaced (a [NativeFormatException], `whileSaving`).
  /// The sidecar is merged: an existing one keeps its savedAt, notes and every key this build does
  /// not know (the materials links among them); only [meta]'s name, craft and lastOpened apply.
  Future<String> saveBand({
    required TabletDocumentDto doc,
    required DraftMeta meta,
    String? id,
  }) async {
    final dir = await _dir();
    final bandId = id ?? _uuid.v4();
    try {
      final named = copyDoc(doc, name: meta.name);
      final text = await write(named);
      final target = File(_bandPath(dir, bandId));
      await _guardExisting(target, text);
      await _atomicWriteString(target, text);
      await _writeThumb(dir, bandId, named);
      await SidecarWrites.run(_jsonPath(dir, bandId),
          () async => _writeSidecar(dir, bandId, await _mergedSidecar(dir, bandId, meta)));
      return bandId;
    } on FileSystemException catch (e) {
      throw Exception('Could not save the band: ${e.message}');
    }
  }

  /// Before [text] (what the engine just wrote, at [schemaVersion]) replaces [target]: refuse if the
  /// file on disk is newer than, or unreadable to, this build; keep a one-time backup if it is older.
  /// The file's version is read by the engine from its envelope alone.
  Future<void> _guardExisting(File target, String text) async {
    if (!await target.exists()) return;
    final original = await target.readAsBytes();
    final onDisk = await documentVersion(utf8.decode(original, allowMalformed: true));
    final writing = await schemaVersion();
    if (onDisk == null || onDisk > writing) {
      throw NativeFormatException(
        onDisk == null ? NativeFormatProblem.unreadable : NativeFormatProblem.newerVersion,
        document: NativeDocument.tabletBand,
        whileSaving: true,
        detail: 'on disk: version $onDisk, writing: version $writing',
      );
    }
    if (onDisk == writing) return;
    final backup = File(backupPath(target.path, onDisk));
    if (await backup.exists()) return; // the first backup holds the true original
    await _atomicWriteBytes(backup, original);
    PlyLog.instance.info('Upgrading ${p.basename(target.path)} from format version $onDisk to '
        '$writing; the original is kept as ${p.basename(backup.path)}.');
  }

  Future<DraftMeta> _mergedSidecar(Directory dir, String id, DraftMeta meta) async {
    if (!await File(_jsonPath(dir, id)).exists()) return meta;
    try {
      final existing = await _readSidecar(dir, id);
      return existing.copyWith(name: meta.name, craft: meta.craft, lastOpened: meta.lastOpened);
    } catch (_) {
      return meta; // unreadable: it could not be listed anyway
    }
  }

  /// Every saved band, newest-opened first. A sidecar without its `.plytab`, or one that cannot be
  /// read, is skipped (one bad file never breaks the list). The sidecars are read with the
  /// restore's bounds ([readListedSidecars]: one past them is not decoded, so it lists whenever it
  /// starts as a JSON object); nothing on disk is changed.
  Future<List<TabletEntry>> listBands() async {
    final dir = await _dir();
    if (!await dir.exists()) return const [];
    if (!_swept) {
      _swept = true;
      try {
        await sweepOrphanedBackups();
      } catch (_) {/* best-effort; the next run retries */}
    }
    final found = <({String id, File sidecar, File band})>[];
    await for (final ent in dir.list()) {
      if (ent is! File || p.extension(ent.path) != '.json') continue;
      final id = p.basenameWithoutExtension(ent.path);
      try {
        final band = File(_bandPath(dir, id));
        if (!await band.exists()) continue;
        found.add((id: id, sidecar: ent, band: band));
      } catch (_) {
        continue;
      }
    }
    final metas =
        await readListedSidecars([for (final f in found) f.sidecar], craft: kTabletCraft);
    final entries = <TabletEntry>[];
    for (var i = 0; i < found.length; i++) {
      final meta = metas[i];
      if (meta == null) continue;
      try {
        final png = File(_pngPath(dir, found[i].id));
        entries.add(TabletEntry(
          id: found[i].id,
          meta: meta,
          bandPath: found[i].band.path,
          thumbPath: await png.exists() ? png.path : null,
        ));
      } catch (_) {
        continue;
      }
    }
    entries.sort((a, b) => b.meta.lastOpened.compareTo(a.meta.lastOpened));
    return entries;
  }

  /// Read a saved band. Throws a [NativeFormatException] for a file this build must not open.
  Future<TabletDocumentDto> readBand(String id) async {
    final dir = await _dir();
    final String text;
    try {
      text = await File(_bandPath(dir, id)).readAsString();
    } on FileSystemException catch (e) {
      throw Exception('Could not open the band file: ${e.message}');
    }
    return parse(text);
  }

  /// Mark a band opened (bumps `lastOpened`) and return its entry.
  Future<TabletEntry> openBand(String id) async {
    final dir = await _dir();
    final bumped = await SidecarWrites.run(_jsonPath(dir, id), () async {
      final meta = await _readSidecar(dir, id);
      final next = meta.copyWith(lastOpened: DateTime.now());
      await _writeSidecar(dir, id, next);
      return next;
    });
    final png = File(_pngPath(dir, id));
    return TabletEntry(
      id: id,
      meta: bumped,
      bandPath: _bandPath(dir, id),
      thumbPath: await png.exists() ? png.path : null,
    );
  }

  /// Rename a band (its sidecar name; the document takes the name at its next save).
  Future<void> renameBand(String id, String newName) async {
    final dir = await _dir();
    await SidecarWrites.run(_jsonPath(dir, id), () async {
      final meta = await _readSidecar(dir, id);
      await _writeSidecar(dir, id, meta.copyWith(name: newName));
    });
  }

  /// Delete a band's files (sidecar first), any `.tmp` an interrupted save left, every
  /// format-upgrade backup, and its progress record (ADR 0023). Tolerates missing files.
  Future<void> deleteBand(String id) async {
    final dir = await _dir();
    final files = [_jsonPath(dir, id), _bandPath(dir, id), _pngPath(dir, id)];
    final backups = <String>[];
    final prefix = '$id.plytab.v';
    try {
      await for (final ent in dir.list(followLinks: false)) {
        final name = p.basename(ent.path);
        if (ent is File &&
            name.startsWith(prefix) &&
            (name.endsWith('.bak') || name.endsWith('.bak.tmp'))) {
          backups.add(ent.path);
        }
      }
    } catch (_) {/* can't list: still remove the known files */}
    Future<void> remove(Iterable<String> paths) async {
      for (final path in paths) {
        final f = File(path);
        if (await f.exists()) {
          try {
            await f.delete();
          } catch (_) {/* a leftover file is harmless */}
        }
      }
    }

    final json = files.first;
    await SidecarWrites.run(json, () => remove([json, '$json.tmp', '$json.links.tmp']));
    await remove([
      for (final f in files.skip(1)) ...[f, '$f.tmp'],
      ...backups,
    ]);
    // The progress record (ADR 0023), after the sidecar: a progress write checks the sidecar under
    // its lock, so none can land after this.
    await ProgressRepository.deleteFilesIn(dir.path, id);
  }

  bool _swept = false;

  /// Remove format-upgrade backups whose band is gone (neither `<id>.plytab` nor `<id>.json`).
  Future<void> sweepOrphanedBackups() async {
    final dir = await _dir();
    if (!await dir.exists()) return;
    final backup = RegExp(r'^(.+)\.plytab\.v\d+\.bak(\.tmp)?$');
    final orphans = <File>[];
    await for (final ent in dir.list(followLinks: false)) {
      if (ent is! File) continue;
      final id = backup.firstMatch(p.basename(ent.path))?.group(1);
      if (id == null) continue;
      try {
        if (await File(_bandPath(dir, id)).exists()) continue;
        if (await File(_jsonPath(dir, id)).exists()) continue;
      } catch (_) {
        continue;
      }
      orphans.add(ent);
    }
    for (final f in orphans) {
      try {
        await f.delete();
      } catch (_) {/* the next run retries */}
    }
  }

  /// Rebuild the thumbnail of saved band [id] from its `.plytab` (after a restore, or for a tile
  /// without one). A band with nothing to draw (no cards or no picks) gets no thumbnail and any old
  /// one is removed; this is not a failure. Throws when the band cannot be read or drawn (a band with
  /// structural errors, say); callers treat it as best-effort.
  Future<void> rebuildThumbnail(String id) async {
    final dir = await _dir();
    final doc = await readBand(id);
    final png = await _thumbPng(doc);
    final target = File(_pngPath(dir, id));
    if (png == null) {
      if (await target.exists()) await target.delete();
      return;
    }
    await _atomicWriteBytes(target, png);
  }

  /// Whether saved band [id] has anything to draw (at least one card and one pick); null when it
  /// cannot be read. A band with nothing to draw keeps the library's plain placeholder; one that
  /// has something but could not be drawn says so (ADR 0021).
  Future<bool?> hasSomethingToDraw(String id) async {
    try {
      final doc = await readBand(id);
      return doc.cards.isNotEmpty && expandedPicks(doc) > 0;
    } catch (_) {
      return null;
    }
  }

  /// The band's top face from pick 1 as PNG bytes, or null when there is nothing to draw.
  Future<List<int>?> _thumbPng(TabletDocumentDto doc) async {
    final picks = expandedPicks(doc);
    if (doc.cards.isEmpty || picks == 0 || picks > kMaxTabletPicks) return null;
    final last = picks < thumbnailPicks ? picks : thumbnailPicks;
    final raster =
        await renderFace(doc, 1, last, face: TabletFaceKind.top, cellPx: thumbnailCellPx);
    final img = await decode(raster);
    try {
      final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
      return bytes?.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);
    } finally {
      img.dispose();
    }
  }

  /// Write the thumbnail of [doc], or remove the old one when [doc] cannot be drawn (no picks yet,
  /// or structural errors): a thumbnail never shows a band as it no longer is. Best-effort: a save
  /// never fails over a thumbnail.
  Future<void> _writeThumb(Directory dir, String id, TabletDocumentDto doc) async {
    final target = File(_pngPath(dir, id));
    List<int>? png;
    try {
      png = await _thumbPng(doc);
    } catch (_) {
      png = null; // a band with errors cannot be drawn
    }
    try {
      if (png == null) {
        if (await target.exists()) await target.delete();
        return;
      }
      await _atomicWriteBytes(target, png);
    } catch (_) {/* best effort */}
  }

  Future<DraftMeta> _readSidecar(Directory dir, String id) async => DraftMeta.fromJson(
        jsonDecode(await File(_jsonPath(dir, id)).readAsString()) as Map<String, dynamic>,
      );

  Future<void> _writeSidecar(Directory dir, String id, DraftMeta meta) =>
      _atomicWriteString(File(_jsonPath(dir, id)), jsonEncode(meta.toJson()));

  Future<void> _atomicWriteString(File target, String contents) async {
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsString(contents, flush: true);
    await tmp.rename(target.path);
  }

  Future<void> _atomicWriteBytes(File target, List<int> bytes) async {
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(target.path);
  }
}

/// The app-side form of a `.plytab` [TabletFormatFailure], so screens handle one exception type for
/// every craft's format problems.
NativeFormatException nativeFormatExceptionFromTablet(TabletFormatFailure f) =>
    NativeFormatException(
      switch (f.kind) {
        TabletFormatFailureKind.newerVersion => NativeFormatProblem.newerVersion,
        TabletFormatFailureKind.wrongFormat => NativeFormatProblem.wrongFormat,
        TabletFormatFailureKind.unreadable => NativeFormatProblem.unreadable,
      },
      document: NativeDocument.tabletBand,
      detail: f.message,
    );
