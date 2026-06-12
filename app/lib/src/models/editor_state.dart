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

/// Compares undo/redo snapshot stacks element-wise using each [DraftDoc]'s own deep `==`.
const ListEquality<DraftDoc> _stackEq = ListEquality<DraftDoc>();

class EditorState {
  const EditorState({
    required this.draft,
    this.undo = const [],
    this.redo = const [],
    this.dirtyStructural = false,
    this.sourceWif,
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

  bool get canUndo => undo.isNotEmpty;
  bool get canRedo => redo.isNotEmpty;

  EditorState copyWith({
    DraftDoc? draft,
    List<DraftDoc>? undo,
    List<DraftDoc>? redo,
    bool? dirtyStructural,
    String? sourceWif,
  }) {
    return EditorState(
      draft: draft ?? this.draft,
      undo: undo ?? this.undo,
      redo: redo ?? this.redo,
      dirtyStructural: dirtyStructural ?? this.dirtyStructural,
      // sourceWif is carried forward by every reducer; it is only (re)set via the constructor
      // on a fresh load, so the `?? this` "cannot clear" limitation never bites here.
      sourceWif: sourceWif ?? this.sourceWif,
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
