import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../diagnostics/log_buffer.dart';
import '../models/draft_meta.dart';
import '../models/knit_entry.dart';
import '../models/native_format.dart';
import '../rust/api.dart';
import '../rust/knit_dto.dart';
import 'progress_repository.dart' show ProgressRepository;
import 'sidecar_read.dart' show readListedSidecars;
import 'sidecar_writes.dart';

/// The one place the knitting app touches the generated bridge symbols for `ply-knit` — the analog of
/// [DraftRepository] for weaving. Screens and editor state depend on this, never on `api.dart`
/// directly.
///
/// It owns the render path (a [KnitPatternDto] -> a decoded [ui.Image]), validation, the native
/// `.plyknit` JSON parse/write, and on-device persistence (a `<documents>/knits/<id>.{plyknit,json,
/// png}` triplet mirroring `DraftRepository`). The editor speaks the transparent [KnitPatternDto]
/// end to end (no opaque, single-use handle), so a pattern can be rendered/validated/written
/// repeatedly.
class KnitRepository {
  KnitRepository();

  /// Render a knitting chart to a decoded [ui.Image] at [cellPx] pixels per cell (symbols +
  /// colorwork + cable spans, bottom-to-top). The live editor calls this on every edit.
  Future<ui.Image> render(KnitPatternDto pattern, {required int cellPx}) async {
    final preview = await renderPixels(pattern, cellPx: cellPx);
    final rows = pattern.chart.rows.length, cols = pattern.chart.width;
    if ((preview.width == 0 || preview.height == 0) && rows > 0 && cols > 0) {
      // The engine draws nothing for a chart past its raster budget: say so, never "empty".
      throw KnitChartNotDrawn('it is too large to draw at this zoom ($cols stitches by $rows '
          'rows at $cellPx pixels each); zoom out to see it');
    }
    return _decodePreview(preview);
  }

  /// The chart's raw RGBA raster at [cellPx] pixels per cell, undecoded (a printed chart is
  /// embedded in a PDF from these pixels, so it never round-trips through a [ui.Image]). An empty
  /// chart is a 0x0 raster.
  Future<PreviewImage> renderPixels(KnitPatternDto pattern, {required int cellPx}) =>
      renderKnitPreview(dto: pattern, cellPx: cellPx);

  /// Structural + full stitch-count validation of the chart; empty list = clean.
  Future<List<KnitIssueDto>> validate(KnitPatternDto pattern) => validateKnit(dto: pattern);

  /// Parse a native `.plyknit` file (any supported schema version; a legacy one is migrated in
  /// memory, never rewritten) into an editor [KnitPatternDto]. A file this build must not open (saved
  /// by a newer Ply, another format, unreadable) throws a [NativeFormatException].
  Future<KnitPatternDto> parse(String json) async {
    try {
      return await parseKnit(json: json);
    } on KnitFormatFailure catch (f) {
      throw nativeFormatExceptionFromKnit(f);
    }
  }

  /// Check that a native `.plyknit` file opens, exactly as [parse] would, without the pattern being
  /// sent back (a backup restore checks a file it then copies byte for byte). Throws the same
  /// [NativeFormatException] as [parse].
  Future<void> check(String json) async {
    try {
      await knitCheck(json: json);
    } on KnitFormatFailure catch (f) {
      throw nativeFormatExceptionFromKnit(f);
    }
  }

  /// Serialize an editor [KnitPatternDto] as a current-version native `.plyknit` envelope.
  Future<String> write(KnitPatternDto pattern) => writeKnit(dto: pattern);

  /// The `.plyknit` schema version this build writes (and the newest it reads).
  Future<int> schemaVersion() => knitSchemaVersion();

  /// The schema version a `.plyknit` file's text says it has, read by the engine from the envelope
  /// alone (1 for a legacy file; nothing else in the file is decoded, however large); null when it
  /// is not a `.plyknit`. A newer version is returned as found. Never decode a file in Dart to learn
  /// this.
  Future<int?> documentVersion(String text) => knitDocumentVersion(text: text);

  /// Whether a `.plyknit` text has at most the engine's limit of JSON values, counted without
  /// decoding it (`ply_knit::native::MAX_VALUES`). The backup restore asks before it checks a
  /// pattern; opening and saving never ask.
  Future<bool> withinValueLimit(String text) => knitWithinValueLimit(text: text);

  /// A blank starter pattern to begin editing (builtin stitch legend, a worsted seed gauge, a
  /// one-color palette, an empty chart the editor grows).
  Future<KnitPatternDto> blank() => knitBlankPattern();

  /// Cast-on stitch count for a target finished [width] + [ease] at [gauge], rounded to a stitch and
  /// then the nearest [repeat] multiple.
  Future<int> castOn(double width, double ease, GaugeDto gauge, int repeat) =>
      knitCastOn(width: width, ease: ease, gauge: gauge, repeat: repeat);

  /// Estimate yards of yarn for a stockinette [width] x [length] rectangle (rough; add a buffer).
  Future<double> estimateYards(double width, double length, GaugeDto gauge) =>
      knitEstimateYards(width: width, length: length, gauge: gauge);

  /// A default stockinette gauge seeded from a yarn weight (CYC table); an editable starting point.
  Future<GaugeDto> seedGauge(YarnWeightKind weight) => knitSeedGauge(weight: weight);

  /// The chart rendered as human-readable, row-by-row written instructions — RS read right-to-left,
  /// WS left-to-right, run-length collapsed ("k3, p1"). One string per row/round, cast-on edge first,
  /// after a "Cast on N sts." line when the pattern states a cast-on. A pattern with sections is
  /// written section by section ("Section 1: Back" headings), each step followed by its count.
  Future<List<String>> written(KnitPatternDto pattern) => knitWritten(dto: pattern);

  /// The pattern's worked construction (its sections): every step's text in a knitter's words with
  /// the stitch count after it, and every problem with the section and step it is about. Empty for a
  /// chart-only pattern.
  Future<KnitConstructionDto> construction(KnitPatternDto pattern) =>
      knitConstruction(dto: pattern);

  /// Decode an FFI [PreviewImage] RGBA buffer into a [ui.Image]. A zero-area image (an empty chart)
  /// has no pixels and `decodeImageFromPixels` would never call back — fail fast instead of hanging
  /// (the same trap the weaving repo guards).
  Future<ui.Image> _decodePreview(PreviewImage preview) {
    if (preview.width == 0 || preview.height == 0) {
      return Future<ui.Image>.error(
        StateError('cannot decode a ${preview.width}x${preview.height} (empty) chart'),
      );
    }
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      preview.rgba,
      preview.width,
      preview.height,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    return completer.future;
  }

  // ---------------------------------------------------------------------------
  // Persistence: <documents>/knits/<id>.{plyknit,json,png} (mirrors DraftRepository). The sidecar
  // reuses the craft-agnostic DraftMeta (craft = 'Knitting').
  // ---------------------------------------------------------------------------

  /// Pixels per cell of a saved pattern's thumbnail, for a save and for a rebuild of a missing one
  /// (`rebuildKnitThumbnail`) alike. Small: tiles are ~180px wide.
  static const int thumbnailCellPx = 6;
  static const Uuid _uuid = Uuid();
  Directory? _knitsDirCache;

  /// Tests point this at a temp dir so the file-only persistence paths (list / rename / delete) run
  /// without `path_provider` (mirrors `NalbindRepository.dirOverride`). Null in production.
  Directory? dirOverride;

  Future<Directory> _knitsDir() async {
    final override = dirOverride;
    if (override != null) {
      await override.create(recursive: true);
      return override;
    }
    final cached = _knitsDirCache;
    if (cached != null) return cached;
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'knits'));
    await dir.create(recursive: true);
    _knitsDirCache = dir;
    return dir;
  }

  String _patternPath(Directory d, String id) => p.join(d.path, '$id.plyknit');
  String _jsonPath(Directory d, String id) => p.join(d.path, '$id.json');
  String _pngPath(Directory d, String id) => p.join(d.path, '$id.png');

  /// The one-time backup of a pattern's original bytes, kept before a save upgrades the file from
  /// schema [version] to the current one.
  static String backupPath(String patternPath, int version) => '$patternPath.v$version.bak';

  /// Save a pattern as the `<id>.{plyknit,json,png}` triplet, returning its id. Atomic + ordered:
  /// the native JSON first, the sidecar LAST (so [listKnits] never sees a `.json` without its
  /// `.plyknit`); the thumbnail is best-effort.
  ///
  /// Saving over an existing `.plyknit`:
  /// - written at an OLDER schema version: its original bytes are first copied to
  ///   `<id>.plyknit.v<old>.bak` (once; an existing backup is never replaced), then it is upgraded;
  /// - written by a NEWER Ply, or not readable at all: nothing is written and a
  ///   [NativeFormatException] (`whileSaving`) is thrown.
  ///
  /// The sidecar is MERGED, not rebuilt: an existing sidecar keeps its savedAt, author, notes and
  /// every key this build does not know; only [meta]'s name, craft and lastOpened are applied. With no
  /// existing sidecar, [meta] is written as given.
  Future<String> saveKnit({
    required KnitPatternDto pattern,
    required DraftMeta meta,
    String? id,
  }) async {
    final dir = await _knitsDir();
    final knitId = id ?? _uuid.v4();
    try {
      final json = await write(pattern); // engine re-serialize (rejects a non-finite gauge)
      final target = File(_patternPath(dir, knitId));
      await _guardExisting(target);
      await _atomicWriteString(target, json);
      await _writeThumb(dir, knitId, pattern);
      // One write at a time to the sidecar (the materials sheet may be writing its links).
      await SidecarWrites.run(_jsonPath(dir, knitId),
          () async => _writeSidecar(dir, knitId, await _mergedSidecar(dir, knitId, meta)));
      return knitId;
    } on FileSystemException catch (e) {
      throw Exception('Could not save the pattern: ${e.message}');
    }
  }

  /// Before what the engine just wrote (at [schemaVersion]) replaces [target]: refuse if the file on
  /// disk is newer than, or unreadable to, this build; keep a one-time backup if it is older (a
  /// format upgrade). A missing target needs nothing. The file's version is read by the engine from
  /// its envelope alone.
  Future<void> _guardExisting(File target) async {
    if (!await target.exists()) return;
    final original = await target.readAsBytes();
    final onDisk = await documentVersion(utf8.decode(original, allowMalformed: true));
    final writing = await schemaVersion();
    if (onDisk == null || onDisk > writing) {
      throw NativeFormatException(
        onDisk == null ? NativeFormatProblem.unreadable : NativeFormatProblem.newerVersion,
        document: NativeDocument.knitPattern,
        whileSaving: true,
        detail: 'on disk: version $onDisk, writing: version $writing',
      );
    }
    if (onDisk == writing) return;
    final backup = File(backupPath(target.path, onDisk));
    if (await backup.exists()) return; // the first backup holds the true original; keep it
    await _atomicWriteBytes(backup, original);
    PlyLog.instance.info('Upgrading ${p.basename(target.path)} from format version $onDisk to '
        '$writing; the original is kept as ${p.basename(backup.path)}.');
  }

  /// The sidecar to write for [id]: the existing one with [meta]'s name, craft and lastOpened applied,
  /// or [meta] itself when there is no readable sidecar yet.
  Future<DraftMeta> _mergedSidecar(Directory dir, String id, DraftMeta meta) async {
    if (!await File(_jsonPath(dir, id)).exists()) return meta;
    try {
      final existing = await _readSidecar(dir, id);
      return existing.copyWith(name: meta.name, craft: meta.craft, lastOpened: meta.lastOpened);
    } catch (_) {
      return meta; // unreadable: it could not be listed anyway, so a fresh sidecar replaces it
    }
  }

  /// List every complete saved pattern, newest-opened first. Skips a sidecar whose `.plyknit` is
  /// gone and a malformed sidecar (one bad file never breaks the whole list). The sidecars are read
  /// with the restore's bounds ([readListedSidecars]: one past them is not decoded, so it lists
  /// whenever it starts as a JSON object); nothing on disk is changed.
  Future<List<KnitEntry>> listKnits() async {
    final dir = await _knitsDir();
    if (!await dir.exists()) return const [];
    if (!_sweptOrphanedBackups) {
      _sweptOrphanedBackups = true;
      try {
        await sweepOrphanedBackups();
      } catch (_) {/* best-effort: a failed sweep never breaks the list; next run retries */}
    }
    final found = <({String id, File sidecar, File pattern})>[];
    await for (final ent in dir.list()) {
      if (ent is! File || p.extension(ent.path) != '.json') continue;
      final id = p.basenameWithoutExtension(ent.path);
      try {
        final patternFile = File(_patternPath(dir, id));
        if (!await patternFile.exists()) continue;
        found.add((id: id, sidecar: ent, pattern: patternFile));
      } catch (_) {
        continue;
      }
    }
    final metas = await readListedSidecars([for (final f in found) f.sidecar], craft: 'Knitting');
    final entries = <KnitEntry>[];
    for (var i = 0; i < found.length; i++) {
      final meta = metas[i];
      if (meta == null) continue;
      try {
        final pngFile = File(_pngPath(dir, found[i].id));
        entries.add(KnitEntry(
          id: found[i].id,
          meta: meta,
          patternPath: found[i].pattern.path,
          thumbPath: await pngFile.exists() ? pngFile.path : null,
        ));
      } catch (_) {
        continue;
      }
    }
    entries.sort((a, b) => b.meta.lastOpened.compareTo(a.meta.lastOpened));
    return entries;
  }

  /// Read + parse a saved pattern's native `.plyknit` into a [KnitPatternDto]. Read-only: an older
  /// file is migrated in memory and stays as it is on disk until the user saves. Throws a
  /// [NativeFormatException] for a file this build must not open (see [parse]).
  Future<KnitPatternDto> readPattern(String id) async {
    final dir = await _knitsDir();
    final String text;
    try {
      text = await File(_patternPath(dir, id)).readAsString();
    } on FileSystemException catch (e) {
      throw Exception('Could not open the pattern file: ${e.message}');
    }
    return parse(text);
  }

  /// Mark a pattern opened (bumps `lastOpened`, rewrites the sidecar) and return the refreshed entry.
  Future<KnitEntry> openKnit(String id) async {
    final dir = await _knitsDir();
    // Under the sidecar lock (ADR 0016), so a link written at the same moment is not lost.
    final bumped = await SidecarWrites.run(_jsonPath(dir, id), () async {
      final meta = await _readSidecar(dir, id);
      final bumped = meta.copyWith(lastOpened: DateTime.now());
      await _writeSidecar(dir, id, bumped);
      return bumped;
    });
    final pngFile = File(_pngPath(dir, id));
    return KnitEntry(
      id: id,
      meta: bumped,
      patternPath: _patternPath(dir, id),
      thumbPath: await pngFile.exists() ? pngFile.path : null,
    );
  }

  /// Rename a pattern (display name only; the uuid filename never changes).
  Future<void> renameKnit(String id, String newName) async {
    final dir = await _knitsDir();
    await SidecarWrites.run(_jsonPath(dir, id), () async {
      final meta = await _readSidecar(dir, id);
      await _writeSidecar(dir, id, meta.copyWith(name: newName));
    });
  }

  /// Delete a pattern's whole triplet (sidecar FIRST so [listKnits] drops it atomically), plus any
  /// `.tmp` a save interrupted mid-write left behind and every format-upgrade backup
  /// (`<id>.plyknit.v<n>.bak`): they hold pattern content too, and the delete promises the pattern is
  /// permanently removed. Tolerates already-missing files.
  Future<void> deleteKnit(String id) async {
    final dir = await _knitsDir();
    final files = [_jsonPath(dir, id), _patternPath(dir, id), _pngPath(dir, id)];
    final backups = <String>[];
    final backupPrefix = '$id.plyknit.v';
    try {
      await for (final ent in dir.list(followLinks: false)) {
        final name = p.basename(ent.path);
        if (ent is File &&
            name.startsWith(backupPrefix) &&
            (name.endsWith('.bak') || name.endsWith('.bak.tmp'))) {
          backups.add(ent.path);
        }
      }
    } catch (_) {/* can't list: still remove the known files below */}
    Future<void> remove(Iterable<String> paths) async {
      for (final path in paths) {
        final f = File(path);
        if (await f.exists()) {
          try {
            await f.delete();
          } catch (_) {
            // Tolerate races / permission quirks; a leftover file is harmless.
          }
        }
      }
    }

    // The sidecar first, under the sidecar lock (ADR 0016), so a link being written cannot bring
    // it back; with it the temp file a links write may have left.
    final json = files.first;
    await SidecarWrites.run(json, () => remove([json, '$json.tmp', '$json.links.tmp']));
    await remove([
      for (final f in files.skip(1)) ...[f, '$f.tmp'],
      ...backups
    ]);
    // The progress record (ADR 0023), after the sidecar: a progress write checks the sidecar under
    // its lock, so none can land after this.
    await ProgressRepository.deleteFilesIn(dir.path, id);
  }

  /// Whether this repository instance (one per app run) has already swept orphaned backups.
  bool _sweptOrphanedBackups = false;

  /// Remove format-upgrade backups (`<id>.plyknit.v<n>.bak`, and their `.tmp`) whose pattern is gone,
  /// i.e. for which NEITHER `<id>.plyknit` NOR `<id>.json` exists. [deleteKnit] removes backups with
  /// their pattern, but an OLDER app version deletes only the files it knows about, so a pattern
  /// upgraded here and later deleted there leaves its backup behind. Runs once per app run from the
  /// first [listKnits]; never touches a backup whose pattern or sidecar still exists.
  Future<void> sweepOrphanedBackups() async {
    final dir = await _knitsDir();
    if (!await dir.exists()) return;
    final backup = RegExp(r'^(.+)\.plyknit\.v\d+\.bak(\.tmp)?$');
    final orphans = <File>[];
    await for (final ent in dir.list(followLinks: false)) {
      if (ent is! File) continue;
      final id = backup.firstMatch(p.basename(ent.path))?.group(1);
      if (id == null) continue;
      try {
        if (await File(_patternPath(dir, id)).exists()) continue;
        if (await File(_jsonPath(dir, id)).exists()) continue;
      } catch (_) {
        continue; // can't tell, so leave it alone
      }
      orphans.add(ent);
    }
    for (final f in orphans) {
      try {
        await f.delete();
      } catch (_) {/* tolerate races / permission quirks; the next run retries */}
    }
  }

  Future<void> _writeThumb(Directory dir, String id, KnitPatternDto pattern) async {
    if (pattern.chart.width == 0 || pattern.chart.rows.isEmpty) {
      // Nothing to draw (a pattern of sections only): remove an older thumbnail rather than keep
      // showing a chart the pattern no longer has. The library shows its placeholder instead.
      try {
        final old = File(_pngPath(dir, id));
        if (await old.exists()) await old.delete();
      } catch (_) {/* best effort, like the thumbnail itself */}
      return;
    }
    ui.Image? img;
    try {
      img = await render(pattern, cellPx: thumbnailCellPx);
      final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) return;
      await _atomicWriteBytes(
        File(_pngPath(dir, id)),
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      );
    } catch (_) {
      // Never fail a save over a thumbnail (an empty chart can't render — that's fine).
    } finally {
      img?.dispose();
    }
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

/// The app-side form of a `.plyknit` [KnitFormatFailure] from the engine, so screens handle one
/// exception type for every craft's format problems.
NativeFormatException nativeFormatExceptionFromKnit(KnitFormatFailure failure) =>
    NativeFormatException(
      switch (failure.kind) {
        KnitFormatFailureKind.newerVersion => NativeFormatProblem.newerVersion,
        KnitFormatFailureKind.wrongFormat => NativeFormatProblem.wrongFormat,
        KnitFormatFailureKind.unreadable => NativeFormatProblem.unreadable,
      },
      document: NativeDocument.knitPattern,
      detail: failure.message,
    );

/// The chart could not be drawn, and why in words (ADR 0021: a chart is never left blank silently).
class KnitChartNotDrawn implements Exception {
  const KnitChartNotDrawn(this.reason);
  final String reason;

  @override
  String toString() => reason;
}
