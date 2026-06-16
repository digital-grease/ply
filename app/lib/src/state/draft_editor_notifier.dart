// The editor's Riverpod entry point: a paper-thin [Notifier] over the PURE reducers on
// [EditorState]. All the logic (and all the tests) live on EditorState; this class only owns
// the `state` cell and forwards. It deliberately touches NO FFI and NO repository: rendering
// and validation are derived providers (Phase 2.4) that `ref.watch` this notifier's `draft`,
// so editing stays instant and synchronous while the expensive FFI work is recomputed off to
// the side. Reducers return `this` on a no-op, so assigning an identical state does not wake
// listeners.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/draft_doc.dart';
import '../models/draft_region.dart';
import '../models/editor_state.dart';
import 'editor_providers.dart';

/// The single source of truth for the open draft and its undo history.
final draftEditorProvider =
    NotifierProvider<DraftEditorNotifier, EditorState>(DraftEditorNotifier.new);

class DraftEditorNotifier extends Notifier<EditorState> {
  /// Until a draft is loaded the editor holds a blank one, so the UI never has to handle a
  /// null draft. The UI calls [load] right after navigating in.
  @override
  EditorState build() => EditorState(draft: DraftDoc.blank());

  /// Open [draft] for editing, resetting the undo history. [sourceWif] is the original WIF text
  /// for an imported draft (enables the verbatim save path), or null for a from-scratch draft.
  void load(DraftDoc draft, {String? sourceWif}) {
    _clearStroke(); // a load mid-drag must not leave the transient stroke scratch dangling
    state = EditorState(draft: draft, sourceWif: sourceWif);
    // Reset the brush so a previous draft's selection can't dangle past this (possibly smaller)
    // palette. (Clamp-on-read defends the rest; this is the tidy default.)
    ref.read(activePaletteColorProvider.notifier).state = 0;
  }

  /// Toggle one tie-up cell (1-based treadle/shaft). See [EditorState.toggleTieupCell].
  void toggleTieupCell(int treadle, int shaft) {
    state = state.toggleTieupCell(treadle, shaft);
  }

  /// Replace palette entry [idx]'s RGB. See [EditorState.setPaletteColor]. Pure; no FFI.
  void setPaletteColor(int idx, DraftColor color) {
    state = state.setPaletteColor(idx, color);
  }

  /// Append a palette color. See [EditorState.addPaletteColor]. Pure; no FFI.
  void addPaletteColor(DraftColor color) {
    state = state.addPaletteColor(color);
  }

  /// Tile [sequence] across the warp band as ONE undo entry. Seals any open stroke first (like
  /// [commitEdit]). See [EditorState.fillWarpStripe].
  void fillWarpStripe(List<int> sequence) {
    _sealOpenStroke();
    state = state.fillWarpStripe(sequence);
  }

  /// Tile [sequence] across the weft band as ONE undo entry. See [EditorState.fillWeftStripe].
  void fillWeftStripe(List<int> sequence) {
    _sealOpenStroke();
    state = state.fillWeftStripe(sequence);
  }

  /// Set the loom's shed direction (rising vs sinking), committed as ONE undo entry (no-op when
  /// unchanged). Sinking inverts which shafts a treadle raises — the engine's `raised_shafts` handles
  /// the complement — so the cloth re-renders; no FFI is needed here because renderDto/validateDto/
  /// saveDto already carry `shed` through the DTO.
  void setShed(Shed shed) => commitEdit(state.draft.copyWith(shed: shed));

  /// Restore the most recent pre-edit snapshot.
  void undo() => state = state.undoEdit();

  /// Re-apply the most recently undone snapshot.
  void redo() => state = state.redoEdit();

  /// Commit an externally-computed draft (an engine resize / drive switch) as one undo entry.
  ///
  /// Seals any OPEN drag-paint stroke first (a resize can arrive mid-stroke via a second finger on
  /// the dimensions bar): committing the in-flight stroke as its own undo entry keeps the history
  /// chronological, instead of leaving `strokeBase` to push a stale pre-resize snapshot on the
  /// later pointer-up. (`load()` defends the same way; this is its twin.)
  void commitEdit(DraftDoc next) {
    _sealOpenStroke();
    state = state.commitEdit(next);
  }

  // --- Drag-paint stroke driver (Phase 3.1) ----------------------------------
  // Transient gesture scratch kept off the immutable EditorState. A stroke paints a CONSTANT
  // value (decided by inverting the first cell) across cells in its START region only; the whole
  // stroke commits as one undo entry.

  DraftRegion? _strokeRegion;
  int? _paintValue; // 1 = fill, 0 = erase (on/off regions only)
  int? _brushIndex; // the constant palette index for a COLOR-region stroke (null for on/off)
  DraftHit? _lastCell;

  static bool _isColorRegion(DraftRegion r) =>
      r == DraftRegion.warpColor || r == DraftRegion.weftColor;

  /// The active brush index clamped into the live palette (reads [state] directly — the notifier
  /// must NOT ref.read its own provider). Defends a dangling brush after a palette shrink.
  int _brush() => clampBrush(ref.read(activePaletteColorProvider), state.draft.palette.length);

  /// Begin a drag-paint stroke at [hit]. For an ON/OFF region the value is the INVERSE of the first
  /// cell (drag from a filled cell erases). For a COLOR region the value is the active brush index,
  /// captured (clamped) ONCE so the whole drag paints one color.
  void beginStroke(DraftHit hit) {
    state = state.beginStroke();
    _strokeRegion = hit.region;
    _lastCell = hit;
    if (_isColorRegion(hit.region)) {
      _brushIndex = _brush();
      _paintValue = null;
      state = _paintColorCell(hit, _brushIndex!);
    } else {
      final on = !state.isCellOn(hit);
      _paintValue = on ? 1 : 0;
      _brushIndex = null;
      state = state.paintCell(hit, on: on);
    }
  }

  /// Continue the stroke at [hit]. Ignores moves outside the start region and repeats of the last
  /// cell (so a wiggle inside one cell does nothing).
  void paintAt(DraftHit hit) {
    if (_strokeRegion == null || hit.region != _strokeRegion || hit == _lastCell) return;
    _lastCell = hit;
    state = _isColorRegion(hit.region)
        ? _paintColorCell(hit, _brushIndex!)
        : state.paintCell(hit, on: _paintValue == 1);
  }

  /// Apply the brush [idx] to a color cell, routing by region to the color value-setters. A no-op
  /// when the palette is empty (nothing to paint with), so the setters' idx-range guard never throws
  /// on a degenerate draft.
  EditorState _paintColorCell(DraftHit hit, int idx) {
    if (state.draft.palette.isEmpty) return state;
    return switch (hit.region) {
      DraftRegion.warpColor => state.withWarpColorForEnd(hit.col, idx),
      DraftRegion.weftColor => state.withWeftColorForPick(hit.row, idx),
      _ => state,
    };
  }

  /// End the stroke, committing it as one undo entry (or nothing if it was a net no-op).
  void endStroke() {
    _clearStroke();
    state = state.endStroke();
  }

  /// Seal an open stroke as its own undo entry before a discrete commit (stripe fill, etc.).
  void _sealOpenStroke() {
    if (state.strokeBase != null) {
      _clearStroke();
      state = state.endStroke();
    }
  }

  void _clearStroke() {
    _strokeRegion = null;
    _paintValue = null;
    _brushIndex = null;
    _lastCell = null;
  }
}
