import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../models/draft_meta.dart';
import '../models/knit_entry.dart';
import '../rust/api.dart';
import '../rust/knit_dto.dart';

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
    final preview = await renderKnitPreview(dto: pattern, cellPx: cellPx);
    return _decodePreview(preview);
  }

  /// Structural + full stitch-count validation of the chart; empty list = clean.
  Future<List<KnitIssueDto>> validate(KnitPatternDto pattern) =>
      validateKnit(dto: pattern);

  /// Parse native `.plyknit` JSON into an editor [KnitPatternDto].
  Future<KnitPatternDto> parse(String json) => parseKnit(json: json);

  /// Serialize an editor [KnitPatternDto] to native `.plyknit` JSON.
  Future<String> write(KnitPatternDto pattern) => writeKnit(dto: pattern);

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
  /// WS left-to-right, run-length collapsed ("k3, p1"). One string per row/round, cast-on edge first.
  Future<List<String>> written(KnitPatternDto pattern) => knitWritten(dto: pattern);

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

  static const int _thumbCellPx = 6;
  static const Uuid _uuid = Uuid();
  Directory? _knitsDirCache;

  Future<Directory> _knitsDir() async {
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

  /// Save a pattern as the `<id>.{plyknit,json,png}` triplet, returning its id. Atomic + ordered:
  /// the native JSON first, the sidecar LAST (so [listKnits] never sees a `.json` without its
  /// `.plyknit`); the thumbnail is best-effort.
  Future<String> saveKnit({
    required KnitPatternDto pattern,
    required DraftMeta meta,
    String? id,
  }) async {
    final dir = await _knitsDir();
    final knitId = id ?? _uuid.v4();
    try {
      final json = await write(pattern); // engine re-serialize (rejects a non-finite gauge)
      await _atomicWriteString(File(_patternPath(dir, knitId)), json);
      await _writeThumb(dir, knitId, pattern);
      await _writeSidecar(dir, knitId, meta);
      return knitId;
    } on FileSystemException catch (e) {
      throw Exception('Could not save the pattern: ${e.message}');
    }
  }

  /// List every complete saved pattern, newest-opened first. Skips a sidecar whose `.plyknit` is
  /// gone and a malformed sidecar (one bad file never breaks the whole list).
  Future<List<KnitEntry>> listKnits() async {
    final dir = await _knitsDir();
    if (!await dir.exists()) return const [];
    final entries = <KnitEntry>[];
    await for (final ent in dir.list()) {
      if (ent is! File || p.extension(ent.path) != '.json') continue;
      final id = p.basenameWithoutExtension(ent.path);
      try {
        final patternFile = File(_patternPath(dir, id));
        if (!await patternFile.exists()) continue;
        final meta =
            DraftMeta.fromJson(jsonDecode(await ent.readAsString()) as Map<String, dynamic>);
        final pngFile = File(_pngPath(dir, id));
        entries.add(KnitEntry(
          id: id,
          meta: meta,
          patternPath: patternFile.path,
          thumbPath: await pngFile.exists() ? pngFile.path : null,
        ));
      } catch (_) {
        continue;
      }
    }
    entries.sort((a, b) => b.meta.lastOpened.compareTo(a.meta.lastOpened));
    return entries;
  }

  /// Read + parse a saved pattern's native `.plyknit` into a [KnitPatternDto].
  Future<KnitPatternDto> readPattern(String id) async {
    final dir = await _knitsDir();
    try {
      return await parse(await File(_patternPath(dir, id)).readAsString());
    } on FileSystemException catch (e) {
      throw Exception('Could not open the pattern file: ${e.message}');
    }
  }

  /// Mark a pattern opened (bumps `lastOpened`, rewrites the sidecar) and return the refreshed entry.
  Future<KnitEntry> openKnit(String id) async {
    final dir = await _knitsDir();
    final meta = await _readSidecar(dir, id);
    final bumped = meta.copyWith(lastOpened: DateTime.now());
    await _writeSidecar(dir, id, bumped);
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
    final meta = await _readSidecar(dir, id);
    await _writeSidecar(dir, id, meta.copyWith(name: newName));
  }

  /// Delete a pattern's whole triplet (sidecar FIRST so [listKnits] drops it atomically). Tolerates
  /// already-missing files.
  Future<void> deleteKnit(String id) async {
    final dir = await _knitsDir();
    for (final path in [_jsonPath(dir, id), _patternPath(dir, id), _pngPath(dir, id)]) {
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

  Future<void> _writeThumb(Directory dir, String id, KnitPatternDto pattern) async {
    ui.Image? img;
    try {
      img = await render(pattern, cellPx: _thumbCellPx);
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
