import '../models/tablet_band.dart';
import '../rust/tablet_dto.dart';

/// The most memory the undo history may hold, by [tabletDocBytes]. An edit that changes the cards
/// (inserting one, removing one, removing a colour) rebuilds every pick, so a long band's history
/// would otherwise grow by the whole band per edit.
const int kTabletUndoBytes = 64 * 1024 * 1024;

final Expando<int> _sizes = Expando('tablet document bytes');

/// An estimate of the memory a document holds (its text and its objects), worked out once per
/// document instance. Documents share the parts an edit did not touch, so this over-counts, which
/// keeps the history's budget on the safe side.
int tabletDocBytes(TabletDocumentDto d) => _sizes[d] ??= _measure(d);

int _measure(TabletDocumentDto d) {
  var n = 256 + d.name.length + d.notes.length + d.palette.length * 32;
  for (final c in d.cards) {
    n += 96 + c.id.length;
  }
  for (final p in d.packs) {
    n += 64 + p.id.length + p.name.length;
    for (final c in p.cards) {
      n += 16 + c.length;
    }
  }
  for (final s in d.turning) {
    n += 48 + s.picks.length * 8;
    for (final p in s.picks) {
      n += 96 + p.turns.length + (p.note?.text.length ?? 0);
      for (final c in p.releaseTwist) {
        n += 16 + c.length;
      }
      for (final c in p.flip) {
        n += 16 + c.length;
      }
      for (final w in p.unsupported) {
        n += 48 + w.card.length + w.text.length;
      }
    }
  }
  return n;
}

/// Immutable tablet editor state: the open band [doc], a bounded undo/redo history, and the [saved]
/// baseline the dirty check compares against. Every edit is a pure function of `tablet_band.dart`
/// that returns a NEW document (or the same instance for a no-op), so all the logic is
/// host-testable; the notifier only swaps the state.
///
/// The history is bounded twice: at most [maxUndo] entries, and at most [maxBytes] of documents by
/// [tabletDocBytes] (the oldest entries go first; the latest one is always kept).
class TabletEditorState {
  const TabletEditorState({
    required this.doc,
    this.undo = const [],
    this.redo = const [],
    this.saved,
    this.maxBytes = kTabletUndoBytes,
  });

  final TabletDocumentDto doc;
  final List<TabletDocumentDto> undo;
  final List<TabletDocumentDto> redo;

  /// The document exactly as last loaded or saved, or null before anything loaded.
  final TabletDocumentDto? saved;

  /// The memory budget of the undo and redo history together.
  final int maxBytes;

  static const int maxUndo = 100;

  /// Shown behind a spinner until the real band loads; never edited.
  static final TabletDocumentDto placeholder = blankTabletDocument(cards: 1);

  bool get canUndo => undo.isNotEmpty;
  bool get canRedo => redo.isNotEmpty;

  /// The history's memory by [tabletDocBytes].
  int get historyBytes =>
      [...undo, ...redo].fold(0, (n, d) => n + tabletDocBytes(d));

  /// Whether [doc] has unsaved edits. IDENTITY, not deep equality: every real edit builds a new
  /// instance (a no-op returns the same one), and undo and redo restore the exact instances they
  /// stacked, so undoing back to the saved band reads clean again.
  bool get isDirty => saved != null && !identical(doc, saved);

  TabletEditorState _with({
    required TabletDocumentDto doc,
    required List<TabletDocumentDto> undo,
    required List<TabletDocumentDto> redo,
    TabletDocumentDto? saved,
  }) =>
      TabletEditorState(
          doc: doc, undo: undo, redo: redo, saved: saved ?? this.saved, maxBytes: maxBytes);

  /// Record [persisted] (the exact instance a save wrote) as the saved baseline.
  TabletEditorState markSaved(TabletDocumentDto persisted) => identical(persisted, saved)
      ? this
      : _with(doc: doc, undo: undo, redo: redo, saved: persisted);

  /// Apply an edit: one undo entry, the redo history dropped, the oldest entries dropped past the
  /// count and memory budgets. A no-op edit changes nothing.
  TabletEditorState apply(TabletDocumentDto Function(TabletDocumentDto) edit) {
    final next = edit(doc);
    if (identical(next, doc)) return this;
    return _with(doc: next, undo: _bounded([...undo, doc]), redo: const []);
  }

  /// The newest entries of [stack] that fit [maxUndo] and [maxBytes] (always the latest one).
  List<TabletDocumentDto> _bounded(List<TabletDocumentDto> stack) {
    var keep = 0;
    var bytes = 0;
    for (var i = stack.length - 1; i >= 0 && keep < maxUndo; i--) {
      final b = tabletDocBytes(stack[i]);
      if (keep > 0 && bytes + b > maxBytes) break;
      bytes += b;
      keep++;
    }
    return keep == stack.length ? stack : stack.sublist(stack.length - keep);
  }

  TabletEditorState undone() {
    if (undo.isEmpty) return this;
    return _with(doc: undo.last, undo: undo.sublist(0, undo.length - 1), redo: [...redo, doc]);
  }

  TabletEditorState redone() {
    if (redo.isEmpty) return this;
    return _with(doc: redo.last, undo: [...undo, doc], redo: redo.sublist(0, redo.length - 1));
  }
}
