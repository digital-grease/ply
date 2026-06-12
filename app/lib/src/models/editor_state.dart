// The editor's whole in-memory state: the live [DraftDoc] plus the undo/redo history and the
// book-keeping the Save path needs. Like [DraftDoc] it is IMMUTABLE and mutated only through
// PURE reducers (toggleTieupCell, undoEdit, redoEdit) that each return a new [EditorState].
// Keeping the reducers pure (no FFI, no I/O) is what lets them be unit-tested directly and
// lets the Riverpod notifier be a paper-thin wrapper (see draft_editor_notifier.dart).
//
// UNDO MODEL. `undo` and `redo` are whole-[DraftDoc] snapshot stacks, most-recent LAST. Cheap
// because a DraftDoc is immutable and structurally shares its unchanged sealed lists with the
// snapshot it was copyWith'd from. A structural reducer pushes the PRE-edit doc onto `undo`,
// clears `redo` (a new edit invalidates the redo future), and never pushes a no-op.
//
// DIRTY TRACKING. `dirtyStructural` is sticky: once a structural edit happens it stays true
// until the next save, even across undo. Precisely recomputing "are we back to the saved
// state" would require re-parsing `sourceWif` (an FFI call), which would make these reducers
// impure; the conservative sticky flag is enough for the dual-path save (Phase 2.5) and the
// dirty-on-exit guard (Phase 5.3). `sourceWif` is the ORIGINAL imported WIF text, kept verbatim
// so a cosmetically-clean draft can be saved byte-identical instead of through lossy re-write.

import 'package:collection/collection.dart';

import 'draft_doc.dart';
import 'draft_region.dart';

/// Compares undo/redo snapshot stacks element-wise using each [DraftDoc]'s own deep `==`.
const ListEquality<DraftDoc> _stackEq = ListEquality<DraftDoc>();

class EditorState {
  const EditorState({
    required this.draft,
    this.undo = const [],
    this.redo = const [],
    this.dirtyStructural = false,
    this.sourceWif,
    this.strokeBase,
  });

  /// The live document currently shown and edited.
  final DraftDoc draft;

  /// Past snapshots, most-recent LAST. `undo.last` is the doc to restore on the next undo.
  final List<DraftDoc> undo;

  /// Snapshots undone away, most-recent LAST. Cleared by any fresh edit.
  final List<DraftDoc> redo;

  /// True once any structural edit has happened since the last save (sticky; see file header).
  final bool dirtyStructural;

  /// The original imported WIF text, or null for a from-scratch draft. Enables the verbatim
  /// (lossless) save path while the draft is structurally unchanged.
  final String? sourceWif;

  /// Transient: while a drag-paint stroke is OPEN, the document as it was at pointer-down (so the
  /// whole stroke commits as ONE undo entry). Null when no stroke is in flight. This is UI
  /// scaffolding, NOT document content: it is EXCLUDED from `==`/`hashCode` (so an in-flight
  /// stroke never poisons preview-dedup or undo-snapshot equality) and the preview watches
  /// `draft`, never this.
  final DraftDoc? strokeBase;

  bool get canUndo => undo.isNotEmpty;
  bool get canRedo => redo.isNotEmpty;

  /// "Leave unchanged" sentinel for [copyWith]'s nullable [strokeBase] (distinct from null, which
  /// must mean "clear it"). The other fields keep the `?? this.x` idiom because they are never
  /// legitimately set back to null.
  static const Object _keep = Object();

  EditorState copyWith({
    DraftDoc? draft,
    List<DraftDoc>? undo,
    List<DraftDoc>? redo,
    bool? dirtyStructural,
    String? sourceWif,
    Object? strokeBase = _keep,
  }) {
    return EditorState(
      draft: draft ?? this.draft,
      undo: undo ?? this.undo,
      redo: redo ?? this.redo,
      dirtyStructural: dirtyStructural ?? this.dirtyStructural,
      // sourceWif is carried forward by every reducer; it is only (re)set via the constructor
      // on a fresh load, so the `?? this` "cannot clear" limitation never bites here.
      sourceWif: sourceWif ?? this.sourceWif,
      // strokeBase CAN be cleared (endStroke passes null), so it uses the explicit sentinel.
      strokeBase: identical(strokeBase, _keep) ? this.strokeBase : strokeBase as DraftDoc?,
    );
  }

  // ---------------------------------------------------------------------------
  // Reducers (pure: no FFI, no I/O). Each returns a NEW EditorState, or `this`
  // unchanged (same identity) when the edit is a no-op so listeners are not woken.
  // ---------------------------------------------------------------------------

  /// Toggle shaft [shaft] in treadle [treadle]'s tie-up column (both 1-based, matching the
  /// grid and WIF). If the shaft is tied to that treadle it is removed, otherwise it is added
  /// (kept in ascending order for a canonical tie-up). Pushes the pre-edit doc to [undo],
  /// clears [redo], and marks the draft structurally dirty.
  ///
  /// Requires a treadled drive (a liftplan has no tie-up); throws [StateError] otherwise so a
  /// mis-wired UI fails loudly rather than silently. A short tie-up is padded with empty rows
  /// up to the declared treadle count, so every grid column is editable even on an imported
  /// draft whose tie-up under-fills its header. An OVER-length tie-up (more rows than the
  /// header declares, which a non-standard WIF can produce) is preserved in full: a cell edit
  /// must never drop rows it is not touching.
  EditorState toggleTieupCell(int treadle, int shaft) {
    final drive = draft.drive;
    if (drive is! DraftTreadled) {
      throw StateError(
        'toggleTieupCell requires a treadled drive, got ${drive.runtimeType}',
      );
    }
    if (treadle < 1 || treadle > draft.treadles) {
      throw RangeError.range(treadle, 1, draft.treadles, 'treadle');
    }
    if (shaft < 1 || shaft > draft.shafts) {
      throw RangeError.range(shaft, 1, draft.shafts, 'shaft');
    }

    // A fresh, deeply-mutable copy of the tie-up to edit. Sized to cover BOTH the declared
    // treadle count (padding a short tie-up so every grid column is editable) AND any existing
    // over-length rows (preserving them, so this edit never destroys data it does not touch).
    final rowCount =
        draft.treadles > drive.tieup.length ? draft.treadles : drive.tieup.length;
    final tieup = <List<int>>[
      for (var t = 0; t < rowCount; t++)
        List<int>.of(t < drive.tieup.length ? drive.tieup[t] : const <int>[]),
    ];
    final row = tieup[treadle - 1];
    if (row.contains(shaft)) {
      row.remove(shaft);
    } else {
      row
        ..add(shaft)
        ..sort();
    }

    final next = draft.copyWith(drive: drive.copyWith(tieup: tieup));
    // A real toggle always changes the cell, but never push a no-op snapshot defensively.
    if (next == draft) return this;
    return copyWith(
      draft: next,
      undo: [...undo, draft],
      redo: const [],
      dirtyStructural: true,
    );
  }

  /// Replace palette entry [idx]'s RGB with [color], as ONE undo entry (pushes the pre-edit doc,
  /// clears redo, marks dirty). A pure edit-in-place: it does NOT touch warpColors/weftColors, so no
  /// index can dangle and validate() stays clean with no engine call. No-op (same identity) when the
  /// swatch is already [color] (DraftColor has value `==`). Throws on an out-of-range [idx].
  EditorState setPaletteColor(int idx, DraftColor color) {
    if (idx < 0 || idx >= draft.palette.length) {
      throw RangeError.range(idx, 0, draft.palette.length - 1, 'palette index');
    }
    final palette = List<DraftColor>.of(draft.palette)..[idx] = color;
    final next = draft.copyWith(palette: palette);
    if (next == draft) return this;
    return copyWith(draft: next, undo: [...undo, draft], redo: const [], dirtyStructural: true);
  }

  /// Append [color] to the palette, as ONE undo entry. Appending a HIGHER index never shifts an
  /// existing warp/weft reference, so nothing dangles and validate() stays clean with no engine call.
  EditorState addPaletteColor(DraftColor color) {
    final palette = List<DraftColor>.of(draft.palette)..add(color);
    final next = draft.copyWith(palette: palette); // a longer palette never equals the old one
    if (next == draft) return this; // kept for symmetry with the other reducers
    return copyWith(draft: next, undo: [...undo, draft], redo: const [], dirtyStructural: true);
  }

  /// Set warp end [end]'s color (1-based) as ONE undo entry (the committing single-cell twin of the
  /// stroke setter [withWarpColorForEnd]). No-op when already that color.
  EditorState setWarpColor(int end, int idx) {
    final next = withWarpColorForEnd(end, idx);
    if (identical(next, this)) return this;
    return copyWith(
        draft: next.draft, undo: [...undo, draft], redo: const [], dirtyStructural: true);
  }

  /// Set pick [pick]'s color (0-based) as ONE undo entry.
  EditorState setWeftColor(int pick, int idx) {
    final next = withWeftColorForPick(pick, idx);
    if (identical(next, this)) return this;
    return copyWith(
        draft: next.draft, undo: [...undo, draft], redo: const [], dirtyStructural: true);
  }

  /// Tile [sequence] (palette indices) across ALL warp ends from end 1, wrapping:
  /// `warpColors[e] = sequence[e % sequence.length]`. Rebuilds the band to EXACTLY [DraftDoc.ends],
  /// so `warpColors.length == ends` holds by construction (this is also the repair path for an
  /// imported list of the wrong length). Empty [sequence] is a no-op; every index is range-checked.
  /// Commits as ONE undo entry.
  EditorState fillWarpStripe(List<int> sequence) {
    if (sequence.isEmpty) return this;
    _checkPaletteRange(sequence);
    final n = draft.ends;
    final filled = [for (var e = 0; e < n; e++) sequence[e % sequence.length]];
    final next = draft.copyWith(warpColors: filled);
    if (next == draft) return this;
    return copyWith(draft: next, undo: [...undo, draft], redo: const [], dirtyStructural: true);
  }

  /// Tile [sequence] across ALL picks (rebuilds to exactly [DraftDoc.picks]). See [fillWarpStripe].
  EditorState fillWeftStripe(List<int> sequence) {
    if (sequence.isEmpty) return this;
    _checkPaletteRange(sequence);
    final n = draft.picks;
    final filled = [for (var p = 0; p < n; p++) sequence[p % sequence.length]];
    final next = draft.copyWith(weftColors: filled);
    if (next == draft) return this;
    return copyWith(draft: next, undo: [...undo, draft], redo: const [], dirtyStructural: true);
  }

  void _checkPaletteRange(List<int> indices) {
    for (final idx in indices) {
      if (idx < 0 || idx >= draft.palette.length) {
        throw RangeError.range(idx, 0, draft.palette.length - 1, 'palette index');
      }
    }
  }

  /// Restore the most recent pre-edit snapshot, moving the current doc onto [redo]. No-op (same
  /// identity) when there is nothing to undo.
  EditorState undoEdit() {
    if (undo.isEmpty) return this;
    final previous = undo.last;
    return copyWith(
      draft: previous,
      undo: undo.sublist(0, undo.length - 1),
      redo: [...redo, draft],
    );
  }

  /// Re-apply the most recently undone snapshot, moving the current doc back onto [undo]. No-op
  /// (same identity) when there is nothing to redo.
  EditorState redoEdit() {
    if (redo.isEmpty) return this;
    final next = redo.last;
    return copyWith(
      draft: next,
      undo: [...undo, draft],
      redo: redo.sublist(0, redo.length - 1),
    );
  }

  /// Replace the live draft with an externally-computed [next] (e.g. an engine resize or
  /// Treadled->Liftplan switch produced via FFI) as a SINGLE undo entry: pushes the pre-edit doc
  /// to [undo], clears [redo], marks dirty. No-op (same identity) when [next] equals the current
  /// draft. The FFI happens in the caller; this is the pure undo-bookkeeping half.
  EditorState commitEdit(DraftDoc next) {
    if (next == draft) return this;
    return copyWith(
      draft: next,
      undo: [...undo, draft],
      redo: const [],
      dirtyStructural: true,
      // Belt-and-suspenders: clear any in-flight stroke base so a later endStroke can't push a
      // stale pre-commit snapshot (the notifier also seals an open stroke before calling this).
      strokeBase: null,
    );
  }

  // ---------------------------------------------------------------------------
  // Drag-paint value-setters + stroke coalescing (Phase 3.1).
  //
  // A drag-paint stroke (pointer-down..moves..pointer-up) paints many cells but commits as EXACTLY
  // ONE undo entry. [beginStroke] captures the pre-edit doc into [strokeBase] and clears redo ONCE;
  // each painted cell calls a PURE value-setter that mutates `draft` but NOT undo; [endStroke]
  // pushes `strokeBase` as the single undo entry (or nothing if the net change is zero). The
  // setters return `this` on a no-op (same identity), so re-entering a cell at the same value is
  // free and an idempotent drag stays cheap. A plain TAP is begin -> one paint -> end = one entry.
  // ---------------------------------------------------------------------------

  /// Is the cell named by [hit] currently "on" (filled)? Used to decide a stroke's paint value
  /// (a drag starting on a filled cell ERASES; on an empty cell FILLS).
  bool isCellOn(DraftHit hit) {
    final drive = draft.drive;
    switch (hit.region) {
      case DraftRegion.threading:
        final end = hit.col;
        return end >= 1 &&
            end <= draft.threading.length &&
            draft.threading[end - 1].contains(hit.row);
      case DraftRegion.tieup:
        if (drive is! DraftTreadled) return false;
        final t = hit.col;
        return t >= 1 && t <= drive.tieup.length && drive.tieup[t - 1].contains(hit.row);
      case DraftRegion.right:
        final pick = hit.row;
        if (drive is DraftTreadled) {
          return pick >= 0 &&
              pick < drive.treadling.length &&
              drive.treadling[pick].contains(hit.col);
        }
        if (drive is DraftLiftplan) {
          return pick >= 0 &&
              pick < drive.liftplan.length &&
              drive.liftplan[pick].contains(hit.col);
        }
        return false;
      case DraftRegion.warpColor:
      case DraftRegion.weftColor:
        // Color cells have no on/off state; the driver routes them by region, never via isCellOn.
        return false;
      case DraftRegion.drawdown:
        return false;
    }
  }

  /// Set warp [end]'s threading (1-based) to [shafts] (canonicalized ascending). Pads a short
  /// threading. Pure draft-mutation: does NOT touch undo (the stroke owns that).
  EditorState withThreadForEnd(int end, List<int> shafts) {
    if (end < 1) throw RangeError.range(end, 1, null, 'end');
    final len = draft.threading.length;
    final rowCount = end > len ? end : len;
    final threading = <List<int>>[
      for (var e = 0; e < rowCount; e++)
        if (e == end - 1)
          (List<int>.of(shafts)..sort())
        else
          List<int>.of(e < len ? draft.threading[e] : const <int>[]),
    ];
    final next = draft.copyWith(threading: threading);
    return next == draft ? this : copyWith(draft: next);
  }

  /// Force shaft [shaft] of treadle [treadle]'s tie-up (both 1-based) on/off (unlike
  /// [toggleTieupCell], which toggles). Pads short tie-ups and preserves over-length rows like
  /// [toggleTieupCell]. Pure draft-mutation; treadled drafts only.
  EditorState withTieupCell(int treadle, int shaft, bool on) {
    final drive = draft.drive;
    if (drive is! DraftTreadled) {
      throw StateError('withTieupCell requires a treadled drive, got ${drive.runtimeType}');
    }
    if (treadle < 1 || treadle > draft.treadles) {
      throw RangeError.range(treadle, 1, draft.treadles, 'treadle');
    }
    if (shaft < 1 || shaft > draft.shafts) {
      throw RangeError.range(shaft, 1, draft.shafts, 'shaft');
    }
    final rowCount =
        draft.treadles > drive.tieup.length ? draft.treadles : drive.tieup.length;
    final tieup = <List<int>>[
      for (var t = 0; t < rowCount; t++)
        List<int>.of(t < drive.tieup.length ? drive.tieup[t] : const <int>[]),
    ];
    final row = tieup[treadle - 1];
    final has = row.contains(shaft);
    if (on && !has) {
      row
        ..add(shaft)
        ..sort();
    } else if (!on && has) {
      row.remove(shaft);
    } else {
      return this; // already at the requested value
    }
    final next = draft.copyWith(drive: drive.copyWith(tieup: tieup));
    return next == draft ? this : copyWith(draft: next);
  }

  /// Set [pick] (0-based) to press [treadles] (treadled drafts). Pads a short treadling. Pure.
  EditorState withTreadleForPick(int pick, List<int> treadles) {
    final drive = draft.drive;
    if (drive is! DraftTreadled) {
      throw StateError('withTreadleForPick requires a treadled drive, got ${drive.runtimeType}');
    }
    if (pick < 0) throw RangeError.range(pick, 0, null, 'pick');
    final newTreadling = _setRow(drive.treadling, pick, treadles);
    final next = draft.copyWith(drive: drive.copyWith(treadling: newTreadling));
    return next == draft ? this : copyWith(draft: next);
  }

  /// Set [pick] (0-based) to raise [shafts] (liftplan drafts). Pads a short liftplan. Pure.
  EditorState withLiftForPick(int pick, List<int> shafts) {
    final drive = draft.drive;
    if (drive is! DraftLiftplan) {
      throw StateError('withLiftForPick requires a liftplan drive, got ${drive.runtimeType}');
    }
    if (pick < 0) throw RangeError.range(pick, 0, null, 'pick');
    final newLift = _setRow(drive.liftplan, pick, shafts);
    final next = draft.copyWith(drive: DraftLiftplan(liftplan: newLift));
    return next == draft ? this : copyWith(draft: next);
  }

  /// A fresh copy of [rows] with row [index] set to a canonical (ascending) copy of [value],
  /// padding with empty rows up to [index] when the source is short.
  static List<List<int>> _setRow(List<List<int>> rows, int index, List<int> value) {
    final rowCount = index >= rows.length ? index + 1 : rows.length;
    return [
      for (var p = 0; p < rowCount; p++)
        if (p == index)
          (List<int>.of(value)..sort())
        else
          List<int>.of(p < rows.length ? rows[p] : const <int>[]),
    ];
  }

  /// A fresh copy of [xs] with element [i] (0-based) set to [idx], padding with 0 up to [i] when
  /// short (the SAME pad the engine resize uses for warp/weft, so a grow stays consistent).
  static List<int> _setIndex(List<int> xs, int i, int idx) {
    final n = i >= xs.length ? i + 1 : xs.length;
    return [for (var k = 0; k < n; k++) k == i ? idx : (k < xs.length ? xs[k] : 0)];
  }

  /// Set warp end [end]'s (1-based) color to palette index [idx]. Pure draft-mutation (does NOT
  /// touch undo; the stroke owns that), padding a short warpColors with 0. Returns `this` on a
  /// no-op. Throws on a bad [end] or an out-of-range [idx].
  EditorState withWarpColorForEnd(int end, int idx) {
    // Bound to the warp axis so the band can never grow PAST ends and leave a dangling tail until
    // the next resize (the engine keeps warpColors.length == ends; this setter must not break it).
    if (end < 1 || end > draft.ends) throw RangeError.range(end, 1, draft.ends, 'end');
    if (idx < 0 || idx >= draft.palette.length) {
      throw RangeError.range(idx, 0, draft.palette.length - 1, 'palette index');
    }
    final next = draft.copyWith(warpColors: _setIndex(draft.warpColors, end - 1, idx));
    return next == draft ? this : copyWith(draft: next);
  }

  /// Set pick [pick]'s (0-based) color to palette index [idx]. Pure draft-mutation; pads weftColors
  /// with 0. Returns `this` on a no-op.
  EditorState withWeftColorForPick(int pick, int idx) {
    if (pick < 0 || pick >= draft.picks) throw RangeError.range(pick, 0, draft.picks - 1, 'pick');
    if (idx < 0 || idx >= draft.palette.length) {
      throw RangeError.range(idx, 0, draft.palette.length - 1, 'palette index');
    }
    final next = draft.copyWith(weftColors: _setIndex(draft.weftColors, pick, idx));
    return next == draft ? this : copyWith(draft: next);
  }

  /// Apply a paint to the cell named by [hit], forcing it [on] or off, routing to the right
  /// region's value-setter so tap and drag share identical semantics.
  EditorState paintCell(DraftHit hit, {required bool on}) {
    switch (hit.region) {
      case DraftRegion.threading:
        return withThreadForEnd(hit.col, on ? [hit.row] : const <int>[]);
      case DraftRegion.tieup:
        return withTieupCell(hit.col, hit.row, on);
      case DraftRegion.right:
        return draft.drive is DraftTreadled
            ? withTreadleForPick(hit.row, on ? [hit.col] : const <int>[])
            : withLiftForPick(hit.row, on ? [hit.col] : const <int>[]);
      case DraftRegion.warpColor:
      case DraftRegion.weftColor:
        // Color regions set a palette INDEX, not an on/off bool: a mis-route here is a bug, so fail
        // loudly instead of writing a boolean into a color band. The driver paints them via
        // withWarpColorForEnd / withWeftColorForPick.
        throw StateError('color regions are painted via the color value-setters, not paintCell');
      case DraftRegion.drawdown:
        return this; // display-only
    }
  }

  /// Open a stroke: capture the pre-edit doc into [strokeBase]. Auto-seals a stale open stroke first
  /// (so a widget torn down mid-drag cannot freeze the next capture). The redo future is cleared at
  /// COMMIT (in [endStroke]), NOT here: a stroke that begins and ends with zero net change (e.g.
  /// painting a color cell the color it already has) must leave redo intact, just like every other
  /// reducer that returns `this` on a no-op.
  EditorState beginStroke() {
    final base = strokeBase == null ? this : endStroke();
    return base.copyWith(strokeBase: base.draft);
  }

  /// Close a stroke: push [strokeBase] as the SINGLE undo entry for the whole stroke AND clear redo
  /// (a real edit invalidates the redo future), clear [strokeBase], mark dirty. A net-no-op stroke
  /// (base == draft) pushes NOTHING and PRESERVES redo. No-op when no stroke is open.
  EditorState endStroke() {
    final base = strokeBase;
    if (base == null) return this;
    if (base == draft) {
      return copyWith(strokeBase: null); // wander-out-and-back drag: push NOTHING, keep redo
    }
    return copyWith(
        undo: [...undo, base], redo: const [], strokeBase: null, dirtyStructural: true);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EditorState &&
          runtimeType == other.runtimeType &&
          draft == other.draft &&
          dirtyStructural == other.dirtyStructural &&
          sourceWif == other.sourceWif &&
          _stackEq.equals(undo, other.undo) &&
          _stackEq.equals(redo, other.redo);

  @override
  int get hashCode => Object.hash(
        draft,
        dirtyStructural,
        sourceWif,
        _stackEq.hash(undo),
        _stackEq.hash(redo),
      );

  @override
  String toString() =>
      'EditorState(draft: $draft, undo: ${undo.length}, redo: ${redo.length}, '
      'dirty: $dirtyStructural)';
}
