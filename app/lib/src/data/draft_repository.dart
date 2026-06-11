import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../models/draft_meta.dart';
import '../rust/api.dart';

/// The one place the app touches `dart:io` and the generated bridge symbols.
///
/// Screens depend on this repository, never on `api.dart` directly. It owns:
///   - the render path (WIF text -> decoded [ui.Image]) including the no-flip
///     orientation contract,
///   - on-device persistence as a `<documents>/drafts/<id>.{wif,json,png}` triplet,
///   - the filesystem-as-index `list()` (no separate index.json).
///
/// CONSTRAINT: the bridge `Draft` is an opaque, move-by-value, SINGLE-USE handle —
/// the first call that takes it (here, `renderPreview`) consumes and frees it.
/// So we never store or reuse a `Draft`; we carry the WIF *text* everywhere and
/// `parseWif` fresh on every render. `parseWif` is microseconds.
class DraftRepository {
  DraftRepository();

  /// Pixels-per-intersection for saved thumbnails. Small: tiles are ~180px wide.
  static const int _thumbCellPx = 4;

  static const Uuid _uuid = Uuid();

  Directory? _draftsDirCache;

  /// `<applicationDocumentsDirectory>/drafts`, created once and memoized.
  /// On Android this resolves to `…/app_flutter/drafts` (app-private storage).
  Future<Directory> _draftsDir() async {
    final cached = _draftsDirCache;
    if (cached != null) return cached;
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'drafts'));
    await dir.create(recursive: true);
    _draftsDirCache = dir;
    return dir;
  }

  String _wifPath(Directory d, String id) => p.join(d.path, '$id.wif');
  String _jsonPath(Directory d, String id) => p.join(d.path, '$id.json');
  String _pngPath(Directory d, String id) => p.join(d.path, '$id.png');

  // ---------------------------------------------------------------------------
  // Rendering
  // ---------------------------------------------------------------------------

  /// Parse [wifText] and render it to a decoded [ui.Image] at [cellPx] pixels per
  /// intersection.
  ///
  /// ORIENTATION CONTRACT (the single place it lives): `PreviewImage.rgba` is
  /// RGBA8, row-major, TOP-TO-BOTTOM — `render_rgba` (ply-weave) already applied
  /// the vertical flip so pick 0 is the bottom row. So decode width x height as-is
  /// and do NOT flip; alpha is always 255.
  ///
  /// Exactly ONE `parseWif` per call (the Draft is consumed by `renderPreview`).
  /// Errors (UTF-8/parse/engine) propagate to the caller, which renders them as a
  /// friendly SnackBar.
  Future<ui.Image> renderDrawdown(String wifText, {required int cellPx}) async {
    final draft = await parseWif(text: wifText);
    final preview = await renderPreview(draft: draft, cellPx: cellPx);
    final completer = Completer<ui.Image>();
    // frb maps the Rust `Vec<u8>` to a Dart Uint8List, exactly what this wants.
    // Tightly packed (stride = width*4); no rowBytes, no flip.
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
  // Persistence
  // ---------------------------------------------------------------------------

  /// Save a draft as the `<id>.{wif,json,png}` triplet and return its id.
  ///
  /// Writes are atomic (tmp -> rename) and ordered: `.wif` first, sidecar last, so
  /// `list()` never observes a `.json` without its `.wif`. The thumbnail is
  /// best-effort — a failure there never fails the save.
  ///
  /// M1 persists the *original imported* WIF text verbatim (lossless, and it sidesteps
  /// the single-use-handle problem); `writeWif` is reserved for the M2 editor.
  Future<String> save({
    required String wifText,
    required DraftMeta meta,
    String? id,
  }) async {
    final dir = await _draftsDir();
    final draftId = id ?? _uuid.v4();
    try {
      // 1. Source of truth first.
      await _atomicWriteString(File(_wifPath(dir, draftId)), wifText);
      // 2. Best-effort thumbnail (non-fatal).
      await _writeThumbnail(dir, draftId, wifText);
      // 3. Sidecar last — its presence signals "this draft is complete".
      await _writeSidecar(dir, draftId, meta);
      return draftId;
    } on FileSystemException catch (e) {
      throw Exception('Could not save the draft: ${e.message}');
    }
  }

  /// Render a small PNG thumbnail next to the draft. Best-effort: a null PNG encode
  /// or any render error is swallowed (the Library re-renders lazily if it's missing).
  Future<void> _writeThumbnail(Directory dir, String id, String wifText) async {
    ui.Image? img;
    try {
      img = await renderDrawdown(wifText, cellPx: _thumbCellPx);
      final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) return; // encode failed; render lazily later
      await _atomicWriteBytes(
        File(_pngPath(dir, id)),
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      );
    } catch (_) {
      // Never fail a save over a thumbnail.
    } finally {
      img?.dispose();
    }
  }

  /// List every complete draft, newest-opened first. Scans `*.json` sidecars and
  /// pairs each with its sibling `.wif` (skipping any sidecar whose `.wif` is gone)
  /// and optional `.png`. Malformed sidecars are skipped, not fatal.
  Future<List<DraftEntry>> list() async {
    final dir = await _draftsDir();
    if (!await dir.exists()) return const [];
    final entries = <DraftEntry>[];
    await for (final ent in dir.list()) {
      if (ent is! File || p.extension(ent.path) != '.json') continue;
      final id = p.basenameWithoutExtension(ent.path);
      try {
        final wifFile = File(_wifPath(dir, id));
        if (!await wifFile.exists()) continue; // sidecar without its .wif: skip
        final meta = DraftMeta.fromJson(
          jsonDecode(await ent.readAsString()) as Map<String, dynamic>,
        );
        final pngFile = File(_pngPath(dir, id));
        entries.add(DraftEntry(
          id: id,
          meta: meta,
          wifPath: wifFile.path,
          thumbPath: await pngFile.exists() ? pngFile.path : null,
        ));
      } catch (_) {
        continue; // one bad sidecar must not break the whole Library
      }
    }
    entries.sort((a, b) => b.meta.lastOpened.compareTo(a.meta.lastOpened));
    return entries;
  }

  /// Read the raw WIF text for a saved draft (re-parsed by the caller on demand).
  Future<String> readWif(String id) async {
    final dir = await _draftsDir();
    try {
      return await File(_wifPath(dir, id)).readAsString();
    } on FileSystemException catch (e) {
      throw Exception('Could not open the draft file: ${e.message}');
    }
  }

  /// Mark a draft opened (bumps `lastOpened`, rewrites the sidecar) and return the
  /// refreshed entry. Used when navigating into a saved draft.
  Future<DraftEntry> open(String id) async {
    final dir = await _draftsDir();
    final meta = await _readSidecar(dir, id);
    final bumped = meta.copyWith(lastOpened: DateTime.now());
    await _writeSidecar(dir, id, bumped);
    final pngFile = File(_pngPath(dir, id));
    return DraftEntry(
      id: id,
      meta: bumped,
      wifPath: _wifPath(dir, id),
      thumbPath: await pngFile.exists() ? pngFile.path : null,
    );
  }

  /// Rename a draft (display name only; the uuid filename never changes).
  Future<void> rename(String id, String newName) async {
    final dir = await _draftsDir();
    final meta = await _readSidecar(dir, id);
    await _writeSidecar(dir, id, meta.copyWith(name: newName));
  }

  /// Delete a draft's whole triplet. Tolerates already-missing files.
  ///
  /// Sidecar first: removing the `.json` drops the draft from the filesystem index
  /// atomically (`list()` keys off `*.json`), mirroring save()'s sidecar-last ordering
  /// so a concurrent scan never sees a half-deleted draft as present.
  Future<void> delete(String id) async {
    final dir = await _draftsDir();
    for (final path in [_jsonPath(dir, id), _wifPath(dir, id), _pngPath(dir, id)]) {
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

  // ---------------------------------------------------------------------------
  // Sidecar I/O + atomic write helpers
  // ---------------------------------------------------------------------------

  Future<DraftMeta> _readSidecar(Directory dir, String id) async {
    final jsonFile = File(_jsonPath(dir, id));
    return DraftMeta.fromJson(
      jsonDecode(await jsonFile.readAsString()) as Map<String, dynamic>,
    );
  }

  Future<void> _writeSidecar(Directory dir, String id, DraftMeta meta) async {
    await _atomicWriteString(File(_jsonPath(dir, id)), jsonEncode(meta.toJson()));
  }

  /// Write [contents] durably and atomically: flush to `<path>.tmp`, then rename
  /// over the target (rename is atomic on the same filesystem). A crash mid-write
  /// leaves only the `.tmp`, which `list()` ignores (it isn't a `.json`/`.wif`).
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
