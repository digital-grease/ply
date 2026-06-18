import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../models/draft_doc.dart';
import '../models/draft_issue.dart';
import '../models/draft_meta.dart';
import '../rust/api.dart';
import '../rust/dto.dart';

/// The one place the app touches `dart:io` and the generated bridge symbols.
///
/// Screens and editor state depend on this repository, never on `api.dart`/`dto.dart`
/// directly. It owns:
///   - the render path (WIF text or [DraftDoc] -> decoded [ui.Image]) including the
///     orientation contract (the engine emits the final end-1-right / pick-1-top bitmap),
///   - the ONLY mapping between the domain [DraftDoc] and the wire `DraftDto` (so the
///     generated symbols never leak into the model/UI/state layers),
///   - on-device persistence as a `<documents>/drafts/<id>.{wif,json,png}` triplet,
///   - the filesystem-as-index `list()` (no separate index.json).
///
/// Since Phase 2.3 the editor speaks the transparent `DraftDto` end to end (no opaque,
/// single-use `Draft` handle): a [DraftDoc] can be rendered, validated, and written
/// repeatedly with no use-after-free.
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
  /// intersection. Used by the Library/import path (which carries raw WIF text).
  ///
  /// Errors (UTF-8/parse/engine) propagate to the caller, which renders them as a
  /// friendly SnackBar.
  Future<ui.Image> renderDrawdown(String wifText, {required int cellPx}) async {
    final dto = await parseWifDto(text: wifText);
    final preview = await renderPreviewDto(dto: dto, cellPx: cellPx);
    return _decodePreview(preview);
  }

  /// Render an editor [DraftDoc] to a decoded [ui.Image] at [cellPx] pixels per
  /// intersection. The live editor calls this on every edit; recompute is microseconds.
  ///
  /// [gridlines] draws cell-boundary seams; [floatThreshold] (> 0) tints floats of that length or
  /// more. Both default OFF — a plain cloth, byte-identical to the pre-overlay render — so the
  /// thumbnail path keeps a clean preview while the live editor toggles overlays per view.
  Future<ui.Image> renderDto(
    DraftDoc doc, {
    required int cellPx,
    bool gridlines = false,
    int floatThreshold = 0,
  }) async {
    final options = (gridlines || floatThreshold > 0)
        ? RenderOptionsDto(gridlines: gridlines, floatThreshold: floatThreshold)
        : null;
    final preview =
        await renderPreviewDto(dto: toDto(doc), cellPx: cellPx, options: options);
    return _decodePreview(preview);
  }

  /// Parse WIF text straight into an editor [DraftDoc] (parse to the wire DTO, then map to the
  /// domain). The editor's entry point when opening a draft to edit.
  Future<DraftDoc> parseDoc(String wifText) async =>
      fromDto(await parseWifDto(text: wifText));

  /// Resize [doc] to the given dimensions via the engine (prunes stale shaft/treadle refs on a
  /// shrink, pads blanks on a grow, keeps warp/weft coupled). The result never carries a dangling
  /// reference. (Named `resizeDoc` to avoid colliding with the generated `resizeDto`.)
  Future<DraftDoc> resizeDoc(
    DraftDoc doc, {
    required int ends,
    required int picks,
    required int shafts,
    required int treadles,
  }) async =>
      fromDto(await resizeDto(
        dto: toDto(doc),
        ends: ends,
        picks: picks,
        shafts: shafts,
        treadles: treadles,
      ));

  /// Convert [doc] from a treadled drive to a canonical liftplan-driven copy via the engine
  /// (per-pick raised shafts baked in honoring the source shed, the tie-up + treadling dropped,
  /// shed -> Rising, treadles -> 0). The rendered cloth is UNCHANGED: a sinking-shed tie-up is
  /// already complemented into the liftplan. One-way -- factoring a liftplan back into a tie-up is
  /// deferred (CLAUDE.md). (Named `toLiftplanDoc` to avoid colliding with the generated
  /// `toLiftplanDto`, exactly as `resizeDoc` avoids `resizeDto`.) Throws if the DTO can't convert
  /// back to a `Draft` (the engine's `Err`, surfaced by frb as a thrown exception).
  Future<DraftDoc> toLiftplanDoc(DraftDoc doc) async =>
      fromDto(await toLiftplanDto(dto: toDto(doc)));

  /// Remove palette color [idx] via the engine, SAFELY remapping every warp/weft reference so none
  /// dangles (a thread using the removed color falls back to color 0; threads past it renumber down
  /// by one). The result `validate()`s clean. Throws (the engine `Err`, surfaced by frb) if [idx] is
  /// out of range or the palette has only one color. (Named `removeColorDoc` to avoid colliding with
  /// the generated `removePaletteColorDto`, as `resizeDoc`/`toLiftplanDoc` do.)
  Future<DraftDoc> removeColorDoc(DraftDoc doc, int idx) async =>
      fromDto(await removePaletteColorDto(dto: toDto(doc), index: idx));

  /// Generate a complete draft for a weave structure (Phase 3): the engine builds the tie-up
  /// ([family] + [over]/[under]/[counter]) and threading ([threading]) sized to [ends] x [picks],
  /// and we lay a STRAIGHT treadling over them (pick i presses treadle `(i % treadles) + 1`) so a
  /// twill shows its diagonal. The result is derived from [base] so its palette/unit/name carry over;
  /// warp/weft colors are reset to fit (warp -> color 0, weft -> color 1 when the palette has one).
  /// Twill's shaft count is `over + under`; Plain/Satin use [shafts]. The editor commits the result
  /// as one undo entry.
  Future<DraftDoc> generateStructureDoc(
    DraftDoc base, {
    required StructureFamily family,
    required ThreadingKind threading,
    required int shafts,
    required int over,
    required int under,
    required int counter,
    required int ends,
    required int picks,
    int block = 4,
    bool twill = false,
    // Composable application (basic families only): write only the chosen components, optionally at an
    // end/pick offset, OVER the existing draft (non-destructive). Defaults reproduce a whole-cloth
    // generate from a blank draft.
    bool applyThreading = true,
    bool applyTieup = true,
    bool applyTreadling = true,
    int endStart = 0,
    int pickStart = 0,
  }) async {
    // Whole-draft structures (overshot / shadow weave / double weave) are interdependent, so the
    // engine builds them complete and returns a ready `DraftDto`. Keep the user's draft IDENTITY
    // (name, notes) and display prefs (unit, shed); take the structure + its colors from the
    // generator. (Plain/Twill/Satin fall through to the Dart tie-up + threading composition below.)
    const wholeDraft = {
      StructureFamily.overshot,
      StructureFamily.shadowWeave,
      StructureFamily.doubleWeave,
    };
    if (wholeDraft.contains(family)) {
      for (final (name, v) in [('ends', ends), ('picks', picks), ('block', block)]) {
        if (v < 0 || v > 0xFFFFFFFF) throw RangeError.range(v, 0, 0xFFFFFFFF, name);
      }
      final gen = fromDto(await generateStructureDto(
        family: family,
        ends: ends,
        picks: picks,
        block: block,
        twill: twill,
      ));
      return gen.copyWith(
        name: base.name,
        notes: base.notes,
        unit: base.unit,
        shed: base.shed,
      );
    }

    // --- Basic families (plain / twill / satin): COMPOSABLE, NON-DESTRUCTIVE application. Write only
    // the chosen components, optionally at an end/pick offset, OVER the existing draft — so a structure
    // can be laid into a band (mix) or one component swapped (modify) without wiping colors, thickness,
    // or the untouched regions. All components + offset 0 onto a blank draft == the old whole-cloth.
    final effShafts = family == StructureFamily.twill ? over + under : shafts;
    // Guard the wire fields (u16 shafts/over/under/counter, u32 ends/picks/offsets) against silent
    // truncation, the same THROW-don't-truncate policy the other wrappers use.
    for (final (name, v) in [
      ('shafts', effShafts),
      ('over', over),
      ('under', under),
      ('counter', counter),
    ]) {
      if (v < 0 || v > 0xFFFF) throw RangeError.range(v, 0, 0xFFFF, name);
    }
    for (final (name, v) in [
      ('ends', ends),
      ('picks', picks),
      ('endStart', endStart),
      ('pickStart', pickStart),
    ]) {
      if (v < 0 || v > 0xFFFFFFFF) throw RangeError.range(v, 0, 0xFFFFFFFF, name);
    }

    final genTieup = await generateTieupDto(
      family: family,
      shafts: effShafts,
      over: over,
      under: under,
      counter: counter,
    );
    final genThreading = applyThreading
        ? [
            for (final r
                in await generateThreadingDto(kind: threading, ends: ends, shafts: effShafts))
              r.toList()
          ]
        : null;
    return applyBasicStructure(
      base: base,
      effShafts: effShafts,
      genThreading: genThreading,
      genTieup: applyTieup ? [for (final r in genTieup) r.toList()] : null,
      applyTreadling: applyTreadling,
      effTreadles: genTieup.length,
      picks: picks,
      endStart: endStart,
      pickStart: pickStart,
    );
  }

  /// The PURE overlay step of [generateStructureDoc] for basic families, split out so it is
  /// host-unit-testable without the FFI threading/tie-up generators. Overlays the (already generated)
  /// [genThreading] patch at [endStart] (null = leave threading), [genTieup] (null = leave the tie-up),
  /// and/or a straight treadling of [picks] picks (one treadle per pick, wrapping [effTreadles]) at
  /// [pickStart], OVER [base] — preserving the base's colors/thickness (resized to the new dimensions)
  /// and any untouched regions. A liftplan base is converted to treadled iff the drive is touched.
  static DraftDoc applyBasicStructure({
    required DraftDoc base,
    required int effShafts,
    List<List<int>>? genThreading,
    List<List<int>>? genTieup,
    bool applyTreadling = false,
    int effTreadles = 0,
    int picks = 0,
    int endStart = 0,
    int pickStart = 0,
  }) {
    // THREADING: overlay the generated draw at [endStart, endStart + len).
    final threadingRows = [for (final r in base.threading) r.toList()];
    if (genThreading != null) {
      final need = endStart + genThreading.length;
      while (threadingRows.length < need) {
        threadingRows.add(<int>[1]); // grow with a default shaft-1 end
      }
      for (var i = 0; i < genThreading.length; i++) {
        threadingRows[endStart + i] = genThreading[i].toList();
      }
    }

    // DRIVE: touching the tie-up or treadling yields a treadled drive (a liftplan base is converted).
    final baseDrive = base.drive;
    var tieupRows =
        baseDrive is DraftTreadled ? [for (final r in baseDrive.tieup) r.toList()] : <List<int>>[];
    var treadlingRows = baseDrive is DraftTreadled
        ? [for (final r in baseDrive.treadling) r.toList()]
        : <List<int>>[];
    final touchesDrive = genTieup != null || applyTreadling;
    if (genTieup != null) {
      tieupRows = [for (final r in genTieup) r.toList()];
    }
    if (applyTreadling) {
      final need = pickStart + picks;
      while (treadlingRows.length < need) {
        treadlingRows.add(<int>[1]);
      }
      for (var i = 0; i < picks; i++) {
        treadlingRows[pickStart + i] = [effTreadles == 0 ? 0 : (i % effTreadles) + 1];
      }
    }

    final newEnds = threadingRows.length;
    final DraftDrive newDrive =
        touchesDrive ? DraftTreadled(tieup: tieupRows, treadling: treadlingRows) : base.drive;
    final newPicks = touchesDrive ? treadlingRows.length : base.picks;
    final newShafts = (genThreading != null || genTieup != null) ? effShafts : base.shafts;
    final newTreadles =
        touchesDrive ? (tieupRows.isNotEmpty ? tieupRows.length : base.treadles) : base.treadles;

    // Colors + thickness: PRESERVE the base, resized to the new dimensions. A fresh cloth (no weft
    // colors yet) seeds its weft with the contrasting palette index 1 so the drawdown reads; an
    // existing cloth keeps its colors and pads any new threads with 0.
    List<int> resizeInts(List<int> src, int len, int pad) => src.length == len
        ? src.toList()
        : (src.length > len
            ? src.sublist(0, len)
            : [...src, ...List<int>.filled(len - src.length, pad)]);
    List<double> resizeDbls(List<double> src, int len) => src.isEmpty
        ? const <double>[] // empty == "all 1.0"; keep it uniform rather than materialize
        : (src.length == len
            ? src.toList()
            : (src.length > len
                ? src.sublist(0, len)
                : [...src, ...List<double>.filled(len - src.length, 1.0)]));
    final weftPad = base.weftColors.isEmpty ? (base.palette.length > 1 ? 1 : 0) : 0;

    return base.copyWith(
      shafts: newShafts,
      treadles: newTreadles,
      threading: threadingRows,
      drive: newDrive,
      warpColors: resizeInts(base.warpColors, newEnds, 0),
      weftColors: resizeInts(base.weftColors, newPicks, weftPad),
      warpThickness: resizeDbls(base.warpThickness, newEnds),
      weftThickness: resizeDbls(base.weftThickness, newPicks),
      // Per-thread retained WARP/WEFT sections desync if a dimension changed; drop them then, else
      // keep (passing null leaves base.retained untouched).
      retained: (newEnds != base.ends || newPicks != base.picks) ? const <RetainedSection>[] : null,
    );
  }

  // ---------------------------------------------------------------------------
  // Planning calculators (Phase 5.1) — pure engine math, no draft mutation.
  // ---------------------------------------------------------------------------

  /// Suggest a sett (ends per inch) from wraps-per-inch and a [structure] name
  /// ("plain" | "twill" | "satin"). Thin pass-through to the engine; the result is already rounded.
  /// (Named `suggestSettCalc` to avoid colliding with the generated `suggestSett`.)
  Future<double> suggestSettCalc(double wpi, String structure) =>
      suggestSett(wpi: wpi, structure: structure);

  /// Estimate warp length + total warp yarn for a plan. [takeupPercent] is entered as a PERCENT
  /// (10 = 10%) and converted to the engine's fraction here. Returns `(warpLength, totalWarp)` in the
  /// draft's unit. (Named `estimateWarpPlan` to avoid colliding with the generated `estimateWarpDto`.)
  Future<(double warpLength, double totalWarp)> estimateWarpPlan({
    required double finishedLength,
    required int items,
    required int ends,
    required double loomWaste,
    required double takeupPercent,
  }) async {
    // Guard the u32 wire fields against silent mod-2^32 truncation (the same THROW-don't-truncate
    // policy `_checkU16`/`_indicesToU32` enforce for ids/indices). The UI validators cap far below
    // this; this is the backstop for any direct caller.
    for (final (name, v) in [('items', items), ('ends', ends)]) {
      if (v < 0 || v > 0xFFFFFFFF) throw RangeError.range(v, 0, 0xFFFFFFFF, name);
    }
    final est = await estimateWarpDto(
      plan: WarpPlanDto(
        finishedLength: finishedLength,
        items: items,
        ends: ends,
        loomWaste: loomWaste,
        takeupShrinkage: takeupPercent / 100.0,
      ),
    );
    return (est.warpLength, est.totalWarp);
  }

  /// Estimate weft picks + total weft yarn for a plan. [takeupPercent] is entered as a PERCENT
  /// (10 = 10%, width-direction weft take-up + selvedge allowance) and converted to the engine's
  /// fraction here. Returns `(picks, totalWeft)` — `picks` is a count, `totalWeft` is in the draft's
  /// unit. (Named `estimateWeftPlan` to avoid colliding with the generated `estimateWeftDto`.)
  Future<(int picks, double totalWeft)> estimateWeftPlan({
    required double picksPerUnit,
    required double width,
    required double wovenLength,
    required int items,
    required double takeupPercent,
  }) async {
    // Guard the u32 wire field against silent mod-2^32 truncation (THROW-don't-truncate, as the warp
    // wrapper and `_indicesToU32` do). The UI validators cap far below; this is the backstop.
    if (items < 0 || items > 0xFFFFFFFF) throw RangeError.range(items, 0, 0xFFFFFFFF, 'items');
    final est = await estimateWeftDto(
      plan: WeftPlanDto(
        picksPerUnit: picksPerUnit,
        width: width,
        wovenLength: wovenLength,
        items: items,
        takeup: takeupPercent / 100.0,
      ),
    );
    return (est.picks, est.totalWeft);
  }

  /// Decode an engine [PreviewImage] into a [ui.Image].
  ///
  /// ORIENTATION CONTRACT (the single place it lives): `PreviewImage.rgba` is RGBA8,
  /// row-major, TOP-TO-BOTTOM — `render_rgba` (ply-weave) already emits the conventional
  /// weaving orientation (end 1 at the right, pick 1 at the top) via a final 180° flip. So
  /// decode width x height as-is and do NOT flip again; alpha is always 255. frb maps the Rust
  /// `Vec<u8>` to a tightly-packed `Uint8List` (stride = width*4), exactly what
  /// `decodeImageFromPixels` wants (no rowBytes).
  Future<ui.Image> _decodePreview(PreviewImage preview) {
    // A zero-area bitmap (a 0-end or 0-pick draft, e.g. an ungrown blank) has an empty
    // pixel buffer; `decodeImageFromPixels` never invokes its callback for it, so a bare
    // Completer would HANG forever (the same trap IntegratedDraftView guards the live
    // preview against). Fail fast instead — callers (the thumbnail) swallow it.
    if (preview.width == 0 || preview.height == 0) {
      return Future<ui.Image>.error(
        StateError('cannot decode a ${preview.width}x${preview.height} (zero-area) preview'),
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

  /// Validate an editor [DraftDoc], returning structured [DraftIssue]s (empty = clean) the
  /// editor can color and gate Save on. Runs through the engine validator over the wire DTO.
  Future<List<DraftIssue>> validateDto(DraftDoc doc) async {
    final issues = await validateDraft(dto: toDto(doc));
    return issues.map(_issueFromDto).toList();
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

  /// Save an editor [DraftDoc] as the `<id>.{wif,json,png}` triplet, dual-path.
  ///
  /// If [sourceWif] is non-null the draft is persisted BYTE-IDENTICAL to it: the path the editor
  /// takes while the draft is only cosmetically changed (it also preserves source comments and
  /// exact formatting). Otherwise the doc is re-serialized via `write_wif`, which normalizes
  /// formatting and drops source COMMENTS but preserves the data: modeled sections, per-thread
  /// thickness (M4), and unrecognized sections kept verbatim in `retained` (M3) all round-trip (see
  /// docs/WIF_MAPPING.md). The editor chooses the verbatim path while its `dirtyStructural` flag is
  /// false. Returns the saved draft id.
  Future<String> saveDto(
    DraftDoc doc, {
    required DraftMeta meta,
    String? id,
    String? sourceWif,
  }) async {
    return save(wifText: await resolveSaveWif(doc, sourceWif), meta: meta, id: id);
  }

  /// Resolve the WIF text [saveDto] will persist: the original [sourceWif] VERBATIM when present
  /// (the lossless path), otherwise a fresh `write_wif(toDto(doc))` re-serialization (lossy at
  /// the WIF header). Extracted so this load-bearing dual-path branch is host-testable: the
  /// verbatim arm short-circuits the FFI `writeWif`, so it runs with no native lib.
  @visibleForTesting
  Future<String> resolveSaveWif(DraftDoc doc, String? sourceWif) async =>
      sourceWif ?? await writeWif(dto: toDto(doc));

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

  // ---------------------------------------------------------------------------
  // DTO mapping — the ONLY DraftDoc <-> DraftDto bridge.
  //
  // Pure type-shape translation (no FFI, no I/O): the 1-based id <-> 0-based and the u16/u32
  // BASE conversions already happen inside the Rust bridge (dto.rs From/TryFrom), so HERE both
  // sides carry 1-based plain ints. The two real jobs are (1) the typed-list <-> plain-list
  // shape change, and (2) WIRE-RANGE reconciliation in [toDto], because DraftDoc holds 64-bit
  // ints with no range invariant while the wire narrows to u8/u16/u32 and the FFI encoder would
  // otherwise SILENTLY truncate (mod 2^bits) before the value reaches Rust. Two policies, by
  // value kind: color channels CLAMP to 0..255 (a near-boundary slider value is plausible), but
  // ids and palette indices THROW outside u16/u32 (a truncated id is a wrong id, never a
  // near-boundary value). In-range-but-dangling ids/indices pass through and are caught by the
  // engine's validate() instead.
  // ---------------------------------------------------------------------------

  /// Map a domain [DraftDoc] to the wire `DraftDto`. Color channels are clamped to 0..255.
  DraftDto toDto(DraftDoc doc) {
    return DraftDto(
      name: doc.name,
      shafts: doc.shafts,
      treadles: doc.treadles,
      shed: switch (doc.shed) {
        Shed.rising => ShedKind.rising,
        Shed.sinking => ShedKind.sinking,
      },
      unit: switch (doc.unit) {
        MeasureUnit.inches => UnitKind.inches,
        MeasureUnit.centimeters => UnitKind.centimeters,
      },
      threading: _rowsToU16(doc.threading),
      drive: switch (doc.drive) {
        DraftTreadled(:final tieup, :final treadling) => DriveDto.treadled(
            tieup: _rowsToU16(tieup),
            treadling: _rowsToU16(treadling),
          ),
        DraftLiftplan(:final liftplan) => DriveDto.liftplan(
            liftplan: _rowsToU16(liftplan),
          ),
      },
      palette: [
        for (final c in doc.palette)
          ColorDto(r: _clampChannel(c.r), g: _clampChannel(c.g), b: _clampChannel(c.b)),
      ],
      warpColors: _indicesToU32(doc.warpColors),
      weftColors: _indicesToU32(doc.weftColors),
      // Thickness is a relative f32 with no narrowing hazard (unlike ids/indices), so it maps
      // straight across as a Float32List. Empty stays empty (the engine's "uniform grid" case).
      warpThickness: Float32List.fromList(doc.warpThickness),
      weftThickness: Float32List.fromList(doc.weftThickness),
      notes: doc.notes,
      retained: [
        for (final s in doc.retained)
          RetainedSectionDto(
            name: s.name,
            entries: [
              for (final e in s.entries) RetainedEntryDto(key: e.key, value: e.value),
            ],
          ),
      ],
    );
  }

  /// Map a wire `DraftDto` back to a domain [DraftDoc].
  DraftDoc fromDto(DraftDto dto) {
    return DraftDoc(
      name: dto.name,
      shafts: dto.shafts,
      treadles: dto.treadles,
      shed: switch (dto.shed) {
        ShedKind.rising => Shed.rising,
        ShedKind.sinking => Shed.sinking,
      },
      unit: switch (dto.unit) {
        UnitKind.inches => MeasureUnit.inches,
        UnitKind.centimeters => MeasureUnit.centimeters,
      },
      threading: _rowsFromU16(dto.threading),
      drive: switch (dto.drive) {
        DriveDto_Treadled(:final tieup, :final treadling) => DraftTreadled(
            tieup: _rowsFromU16(tieup),
            treadling: _rowsFromU16(treadling),
          ),
        DriveDto_Liftplan(:final liftplan) => DraftLiftplan(
            liftplan: _rowsFromU16(liftplan),
          ),
      },
      palette: [
        for (final c in dto.palette) DraftColor(r: c.r, g: c.g, b: c.b),
      ],
      warpColors: List<int>.of(dto.warpColors),
      weftColors: List<int>.of(dto.weftColors),
      warpThickness: List<double>.of(dto.warpThickness),
      weftThickness: List<double>.of(dto.weftThickness),
      notes: dto.notes,
      retained: [
        for (final s in dto.retained)
          RetainedSection(
            s.name,
            [for (final e in s.entries) RetainedEntry(e.key, e.value)],
          ),
      ],
    );
  }

  DraftIssue _issueFromDto(ValidationIssueDto issue) => DraftIssue(
        severity: switch (issue.severity) {
          SeverityKind.error => IssueSeverity.error,
          SeverityKind.warning => IssueSeverity.warning,
        },
        message: issue.message,
      );

  /// Clamp a color channel to the wire's 0..255 (u8) range (see the mapping note above).
  /// Channels CLAMP (not throw) because an out-of-range channel is a plausible near-boundary
  /// editor value (a slider overshoot) where clamping is the right behavior.
  static int _clampChannel(int v) => v < 0 ? 0 : (v > 255 ? 255 : v);

  /// Plain `List<List<int>>` -> wire `List<Uint16List>` (one row per entry), guarding each id
  /// against the u16 range. Ids THROW (not clamp): a shaft/treadle id outside 0..65535 is not a
  /// near-boundary value but corruption, and `Uint16List.fromList` would otherwise silently
  /// truncate it mod 65536 into a different, valid-looking id. (An in-range but semantically
  /// dangling id, e.g. shaft 5 of a 2-shaft draft, is NOT caught here on purpose; it stays a
  /// clean u16 and the engine's `validate()` reports it as an Error.)
  static List<Uint16List> _rowsToU16(List<List<int>> rows) =>
      [for (final r in rows) Uint16List.fromList([for (final v in r) _checkU16(v)])];

  static int _checkU16(int v) {
    if (v < 0 || v > 0xFFFF) {
      throw RangeError.range(v, 0, 0xFFFF, 'shaft/treadle id');
    }
    return v;
  }

  /// Plain `List<int>` of palette indices -> wire `Uint32List`, guarding each against the u32
  /// range for the same reason ids throw (a negative index would wrap to a huge positive). An
  /// in-range index past the palette end stays valid here and is flagged by `validate()`.
  static Uint32List _indicesToU32(List<int> indices) {
    for (final v in indices) {
      if (v < 0 || v > 0xFFFFFFFF) {
        throw RangeError.range(v, 0, 0xFFFFFFFF, 'color index');
      }
    }
    return Uint32List.fromList(indices);
  }

  /// Wire `List<Uint16List>` -> plain growable `List<List<int>>`.
  static List<List<int>> _rowsFromU16(List<Uint16List> rows) =>
      [for (final r in rows) List<int>.of(r)];
}
