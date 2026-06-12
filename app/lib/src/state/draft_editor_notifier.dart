// The editor's Riverpod entry point: a paper-thin [Notifier] over the PURE reducers on
// [EditorState]. All the logic (and all the tests) live on EditorState; this class only owns
// the `state` cell and forwards. It deliberately touches NO FFI and NO repository: rendering
// and validation are derived providers (Phase 2.4) that `ref.watch` this notifier's `draft`,
// so editing stays instant and synchronous while the expensive FFI work is recomputed off to
// the side. Reducers return `this` on a no-op, so assigning an identical state does not wake
// listeners.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/draft_doc.dart';
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
}
