import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/models/draft_doc.dart';
import 'package:ply/src/models/editor_state.dart';

// Pure-Dart tests for the editor's reducers. No FFI, no Riverpod container: the reducers live
// on EditorState as pure functions, so they are tested directly (the notifier is a thin
// forwarder over exactly these calls).

/// A blank treadled draft (4 shafts, 4 treadles, 4 empty tie-up rows) to toggle against.
DraftDoc treadledDraft() => DraftDoc.blank(shafts: 4, treadles: 4);

/// A liftplan draft, which has no tie-up to toggle.
DraftDoc liftplanDraft() => DraftDoc(
      name: 'lp',
      shafts: 2,
      treadles: 0,
      shed: Shed.rising,
      unit: MeasureUnit.inches,
      threading: const [
        [1],
        [2],
      ],
      drive: DraftLiftplan(liftplan: const [
        [1],
        [2],
      ]),
      palette: const [DraftColor(r: 0, g: 0, b: 0)],
      warpColors: const [0, 0],
      weftColors: const [0, 0],
      notes: '',
    );

/// A treadled draft whose tie-up UNDER-fills its declared treadle count (1 row, 3 treadles).
DraftDoc shortTieupDraft() => DraftDoc(
      name: 'short',
      shafts: 3,
      treadles: 3,
      shed: Shed.rising,
      unit: MeasureUnit.inches,
      threading: const <List<int>>[],
      drive: DraftTreadled(
        tieup: const [
          [1],
        ],
        treadling: const <List<int>>[],
      ),
      palette: const [DraftColor(r: 0, g: 0, b: 0)],
      warpColors: const <int>[],
      weftColors: const <int>[],
      notes: '',
    );

/// A treadled draft whose tie-up OVER-fills its declared treadle count (4 rows, 2 treadles),
/// which a non-standard WIF can produce (a [TIEUP] key beyond the Treadles header).
DraftDoc overLengthTieupDraft() => DraftDoc(
      name: 'over',
      shafts: 4,
      treadles: 2,
      shed: Shed.rising,
      unit: MeasureUnit.inches,
      threading: const <List<int>>[],
      drive: DraftTreadled(
        tieup: const [
          [1],
          [2],
          [3],
          [4],
        ],
        treadling: const <List<int>>[],
      ),
      palette: const [DraftColor(r: 0, g: 0, b: 0)],
      warpColors: const <int>[],
      weftColors: const <int>[],
      notes: '',
    );

void main() {
  group('EditorState.toggleTieupCell', () {
    test('toggling the same cell twice returns a value-equal draft (the verify case)', () {
      final s0 = EditorState(draft: treadledDraft());
      final s1 = s0.toggleTieupCell(1, 2);
      final s2 = s1.toggleTieupCell(1, 2);
      expect(s1.draft == s0.draft, isFalse, reason: 'the first toggle must change the draft');
      expect(s2.draft, equals(s0.draft), reason: 'toggling back restores the original cloth');
    });

    test('adds an absent shaft, keeps the tie-up sorted, removes a present one', () {
      var s = EditorState(draft: treadledDraft());
      s = s.toggleTieupCell(2, 3); // add 3 to treadle 2
      expect((s.draft.drive as DraftTreadled).tieup[1], equals([3]));
      s = s.toggleTieupCell(2, 1); // add 1 -> canonical ascending [1, 3]
      expect((s.draft.drive as DraftTreadled).tieup[1], equals([1, 3]));
      s = s.toggleTieupCell(2, 3); // remove 3 -> [1]
      expect((s.draft.drive as DraftTreadled).tieup[1], equals([1]));
      // The OTHER treadle columns are untouched.
      expect((s.draft.drive as DraftTreadled).tieup[0], isEmpty);
    });

    test('pushes the pre-edit doc to undo, clears redo, marks dirtyStructural', () {
      final s0 = EditorState(draft: treadledDraft());
      final s1 = s0.toggleTieupCell(1, 1);
      expect(s1.undo.length, equals(1));
      expect(s1.undo.last, equals(s0.draft));
      expect(s1.redo, isEmpty);
      expect(s1.dirtyStructural, isTrue);
      expect(s1.canUndo, isTrue);
      expect(s1.canRedo, isFalse);
      // The original state object is untouched (immutability).
      expect(s0.dirtyStructural, isFalse);
      expect(s0.undo, isEmpty);
    });

    test('pads a short tie-up so a high treadle column is editable', () {
      final s0 = EditorState(draft: shortTieupDraft()); // 3 treadles, only 1 tie-up row
      final s1 = s0.toggleTieupCell(3, 2); // treadle 3 has no row yet
      final t = s1.draft.drive as DraftTreadled;
      expect(t.tieup.length, equals(3), reason: 'padded up to the declared treadle count');
      expect(t.tieup[0], equals([1]), reason: 'the existing row is preserved');
      expect(t.tieup[1], isEmpty);
      expect(t.tieup[2], equals([2]));
    });

    test('preserves over-length tie-up rows it is not editing (no silent data loss)', () {
      final s0 = EditorState(draft: overLengthTieupDraft()); // 2 treadles, 4 tie-up rows
      final s1 = s0.toggleTieupCell(1, 2); // edit an in-range cell
      final t = s1.draft.drive as DraftTreadled;
      expect(t.tieup.length, equals(4), reason: 'rows beyond the header must not be dropped');
      expect(t.tieup[0], equals([1, 2]), reason: 'the edited row');
      expect(t.tieup[1], equals([2]));
      expect(t.tieup[2], equals([3]), reason: 'over-length rows survive');
      expect(t.tieup[3], equals([4]));
    });

    test('throws StateError on a liftplan draft (no tie-up exists)', () {
      final s0 = EditorState(draft: liftplanDraft());
      expect(() => s0.toggleTieupCell(1, 1), throwsStateError);
    });

    test('throws RangeError for an out-of-range treadle or shaft', () {
      final s0 = EditorState(draft: treadledDraft()); // 4 shafts, 4 treadles
      expect(() => s0.toggleTieupCell(0, 1), throwsRangeError);
      expect(() => s0.toggleTieupCell(5, 1), throwsRangeError);
      expect(() => s0.toggleTieupCell(1, 0), throwsRangeError);
      expect(() => s0.toggleTieupCell(1, 5), throwsRangeError);
    });
  });

  group('EditorState undo/redo', () {
    test('undo restores the previous draft and fills redo', () {
      final s0 = EditorState(draft: treadledDraft());
      final s1 = s0.toggleTieupCell(1, 1);
      final s2 = s1.undoEdit();
      expect(s2.draft, equals(s0.draft));
      expect(s2.undo, isEmpty);
      expect(s2.redo.length, equals(1));
      expect(s2.canRedo, isTrue);
    });

    test('redo re-applies the most recently undone edit', () {
      final s0 = EditorState(draft: treadledDraft());
      final s1 = s0.toggleTieupCell(1, 1);
      final s3 = s1.undoEdit().redoEdit();
      expect(s3.draft, equals(s1.draft));
      expect(s3.redo, isEmpty);
      expect(s3.undo.length, equals(1));
    });

    test('a fresh edit clears the redo stack', () {
      final s0 = EditorState(draft: treadledDraft());
      final s1 = s0.toggleTieupCell(1, 1);
      final s2 = s1.undoEdit(); // redo now holds s1.draft
      final s3 = s2.toggleTieupCell(2, 2);
      expect(s3.redo, isEmpty, reason: 'a new edit invalidates the redo future');
    });

    test('undo/redo on empty stacks are no-ops with the SAME identity', () {
      final s0 = EditorState(draft: treadledDraft());
      expect(identical(s0.undoEdit(), s0), isTrue);
      expect(identical(s0.redoEdit(), s0), isTrue);
    });

    test('dirtyStructural is sticky through undo and redo', () {
      final s0 = EditorState(draft: treadledDraft());
      final s1 = s0.toggleTieupCell(1, 1);
      expect(s1.undoEdit().dirtyStructural, isTrue);
      expect(s1.undoEdit().redoEdit().dirtyStructural, isTrue);
    });

    test('dirtyStructural stays true after fully undoing back to the original cloth', () {
      // The visible draft can match the original while the state is still structurally dirty:
      // precise dirty (clearing on return to the saved state) is deferred to Phase 5.3.
      final s0 = EditorState(draft: treadledDraft());
      final undoneToStart =
          s0.toggleTieupCell(1, 1).toggleTieupCell(2, 2).undoEdit().undoEdit();
      expect(undoneToStart.draft, equals(s0.draft));
      expect(undoneToStart.dirtyStructural, isTrue);
    });

    test('a three-edit history undoes and redoes in LIFO order', () {
      final s0 = EditorState(draft: treadledDraft());
      final a = s0.toggleTieupCell(1, 1);
      final b = a.toggleTieupCell(2, 2);
      final c = b.toggleTieupCell(3, 3);
      expect(c.undo.length, equals(3));
      final u1 = c.undoEdit();
      expect(u1.draft, equals(b.draft));
      final u2 = u1.undoEdit();
      expect(u2.draft, equals(a.draft));
      final u3 = u2.undoEdit();
      expect(u3.draft, equals(s0.draft));
      expect(u3.canUndo, isFalse);
    });
  });

  group('EditorState value semantics', () {
    test('sourceWif is carried through reducers', () {
      final s0 = EditorState(draft: treadledDraft(), sourceWif: 'WIF;...');
      final s1 = s0.toggleTieupCell(1, 1);
      expect(s1.sourceWif, equals('WIF;...'));
      expect(s1.undoEdit().sourceWif, equals('WIF;...'));
    });

    test('equal states (deep) compare == with equal hashCode', () {
      final a = EditorState(draft: treadledDraft()).toggleTieupCell(1, 1);
      final b = EditorState(draft: treadledDraft()).toggleTieupCell(1, 1);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });
  });
}
