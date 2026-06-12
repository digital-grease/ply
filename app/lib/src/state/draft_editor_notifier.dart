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
  }

  /// Toggle one tie-up cell (1-based treadle/shaft). See [EditorState.toggleTieupCell].
  void toggleTieupCell(int treadle, int shaft) {
    state = state.toggleTieupCell(treadle, shaft);
  }

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
    if (state.strokeBase != null) {
      _clearStroke();
      state = state.endStroke();
    }
    state = state.commitEdit(next);
  }

  // --- Drag-paint stroke driver (Phase 3.1) ----------------------------------
  // Transient gesture scratch kept off the immutable EditorState. A stroke paints a CONSTANT
  // value (decided by inverting the first cell) across cells in its START region only; the whole
  // stroke commits as one undo entry.

  DraftRegion? _strokeRegion;
  int? _paintValue; // 1 = fill, 0 = erase
  DraftHit? _lastCell;

  /// Begin a drag-paint stroke at [hit]. The paint value is the INVERSE of the first cell's state
  /// (drag from a filled cell erases, from an empty cell fills), applied constant for the stroke.
  void beginStroke(DraftHit hit) {
    state = state.beginStroke();
    _strokeRegion = hit.region;
    final on = !state.isCellOn(hit);
    _paintValue = on ? 1 : 0;
    _lastCell = hit;
    state = state.paintCell(hit, on: on);
  }

  /// Continue the stroke at [hit]. Ignores moves outside the start region and repeats of the last
  /// cell (so a wiggle inside one cell does nothing).
  void paintAt(DraftHit hit) {
    if (_strokeRegion == null || hit.region != _strokeRegion || hit == _lastCell) return;
    _lastCell = hit;
    state = state.paintCell(hit, on: _paintValue == 1);
  }

  /// End the stroke, committing it as one undo entry (or nothing if it was a net no-op).
  void endStroke() {
    _clearStroke();
    state = state.endStroke();
  }

  void _clearStroke() {
    _strokeRegion = null;
    _paintValue = null;
    _lastCell = null;
  }
}
