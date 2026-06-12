import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/models/draft_doc.dart';
import 'package:ply/src/models/draft_region.dart';
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

/// A treadled draft WITH ends and picks (blank has neither), so threading/treadling/tie-up cells
/// are paintable. threading [[1],[2],[3],[4]], treadling [[1],[2],[3],[4]], tieup straight.
DraftDoc paintableTreadled() => DraftDoc(
      name: 'p',
      shafts: 4,
      treadles: 4,
      shed: Shed.rising,
      unit: MeasureUnit.inches,
      threading: const [
        [1],
        [2],
        [3],
        [4],
      ],
      drive: DraftTreadled(
        tieup: const [
          [1],
          [2],
          [3],
          [4],
        ],
        treadling: const [
          [1],
          [2],
          [3],
          [4],
        ],
      ),
      palette: const [DraftColor(r: 255, g: 255, b: 255), DraftColor(r: 0, g: 0, b: 0)],
      warpColors: const [0, 0, 0, 0],
      weftColors: const [1, 1, 1, 1],
      notes: '',
    );

/// A liftplan draft with ends and picks for right-band paint tests.
DraftDoc paintableLiftplan() => DraftDoc(
      name: 'lp',
      shafts: 4,
      treadles: 0,
      shed: Shed.rising,
      unit: MeasureUnit.inches,
      threading: const [
        [1],
        [2],
        [3],
        [4],
      ],
      drive: DraftLiftplan(liftplan: const [
        [1],
        [2],
        [3],
        [4],
      ]),
      palette: const [DraftColor(r: 0, g: 0, b: 0)],
      warpColors: const [0, 0, 0, 0],
      weftColors: const [0, 0, 0, 0],
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

  group('EditorState drag-paint strokes', () {
    test('a multi-cell stroke commits as exactly ONE undo entry', () {
      final s0 = EditorState(draft: paintableTreadled());
      var s = s0.beginStroke();
      s = s.paintCell(const DraftHit(DraftRegion.threading, 1, 2), on: true); // end1 -> shaft2
      s = s.paintCell(const DraftHit(DraftRegion.threading, 2, 2), on: true); // end2 -> shaft2
      s = s.paintCell(const DraftHit(DraftRegion.threading, 1, 2), on: true); // re-enter, idempotent
      s = s.endStroke();
      expect(s.undo.length, 1, reason: 'one entry for the whole stroke');
      expect(s.undo.last, equals(s0.draft), reason: 'the pre-stroke doc');
      expect(s.redo, isEmpty);
      expect(s.strokeBase, isNull);
      expect(s.dirtyStructural, isTrue);
      expect(s.draft.threading[0], equals([2]));
      expect(s.draft.threading[1], equals([2]));
      expect(s.draft.threading[2], equals([3]), reason: 'untouched end unchanged');
    });

    test('a tap (begin + one paint + end) is one undo entry; tie-up adds (multi)', () {
      final s0 = EditorState(draft: paintableTreadled());
      final s = s0
          .beginStroke()
          .paintCell(const DraftHit(DraftRegion.tieup, 1, 2), on: true)
          .endStroke();
      expect(s.undo.length, 1);
      expect((s.draft.drive as DraftTreadled).tieup[0], equals([1, 2]),
          reason: 'tie-up ADDS a shaft (multi), unlike threading/treadling replace');
    });

    test('a stroke whose cells were already at the painted value pushes NOTHING', () {
      final s0 = EditorState(draft: paintableTreadled());
      // end1 is already on shaft1; painting it ON shaft1 changes nothing.
      final s = s0
          .beginStroke()
          .paintCell(const DraftHit(DraftRegion.threading, 1, 1), on: true)
          .endStroke();
      expect(s.undo, isEmpty, reason: 'net no-op -> no undo entry');
      expect(s.strokeBase, isNull);
      expect(s.draft, equals(s0.draft));
    });

    test('beginStroke clears redo (a fresh edit invalidates the redo future)', () {
      final s0 = EditorState(draft: paintableTreadled());
      final edited = s0
          .beginStroke()
          .paintCell(const DraftHit(DraftRegion.threading, 1, 2), on: true)
          .endStroke();
      final undone = edited.undoEdit();
      expect(undone.redo.length, 1);
      expect(undone.beginStroke().redo, isEmpty);
    });

    test('multiple strokes undo and redo in LIFO order', () {
      var s = EditorState(draft: paintableTreadled());
      final base = s.draft;
      s = s
          .beginStroke()
          .paintCell(const DraftHit(DraftRegion.threading, 1, 2), on: true)
          .endStroke();
      final afterA = s.draft;
      s = s
          .beginStroke()
          .paintCell(const DraftHit(DraftRegion.threading, 2, 1), on: true)
          .endStroke();
      final afterB = s.draft;
      expect(s.undo.length, 2);
      s = s.undoEdit();
      expect(s.draft, equals(afterA));
      s = s.undoEdit();
      expect(s.draft, equals(base));
      s = s.redoEdit();
      expect(s.draft, equals(afterA));
      s = s.redoEdit();
      expect(s.draft, equals(afterB));
    });

    test('an interrupted (never-ended) stroke is auto-sealed by the next beginStroke', () {
      final s0 = EditorState(draft: paintableTreadled());
      final open = s0
          .beginStroke()
          .paintCell(const DraftHit(DraftRegion.threading, 1, 2), on: true);
      expect(open.strokeBase, isNotNull);
      final next = open.beginStroke();
      expect(next.undo.length, 1, reason: 'the stale stroke was committed');
      expect(next.undo.last, equals(s0.draft));
      expect(next.strokeBase, equals(next.draft), reason: 'a fresh stroke is open on the current doc');
    });

    test('a liftplan right-band stroke edits the liftplan (col=shaft, row=pick)', () {
      final s0 = EditorState(draft: paintableLiftplan());
      final s = s0
          .beginStroke()
          .paintCell(const DraftHit(DraftRegion.right, 2, 0), on: true)
          .endStroke();
      expect(s.undo.length, 1);
      expect((s.draft.drive as DraftLiftplan).liftplan[0], equals([2]));
    });

    test('a treadled right-band stroke edits the treadling (col=treadle, row=pick)', () {
      final s0 = EditorState(draft: paintableTreadled());
      final s = s0
          .beginStroke()
          .paintCell(const DraftHit(DraftRegion.right, 3, 0), on: true)
          .endStroke();
      expect((s.draft.drive as DraftTreadled).treadling[0], equals([3]));
    });

    test('strokeBase is EXCLUDED from == and hashCode', () {
      final a = EditorState(draft: paintableTreadled());
      final b = a.copyWith(strokeBase: a.draft);
      expect(b.strokeBase, isNotNull);
      expect(a, equals(b), reason: 'an in-flight stroke must not change document equality');
      expect(a.hashCode, equals(b.hashCode));
    });

    test('copyWith keeps strokeBase by default, clears it with explicit null', () {
      final a = EditorState(draft: paintableTreadled())
          .copyWith(strokeBase: paintableTreadled());
      expect(a.strokeBase, isNotNull);
      expect(a.copyWith(dirtyStructural: true).strokeBase, isNotNull,
          reason: 'default _keep sentinel preserves it');
      expect(a.copyWith(strokeBase: null).strokeBase, isNull,
          reason: 'explicit null clears it (the bug ?? this.x would hide)');
    });
  });

  group('EditorState.commitEdit', () {
    test('replaces the draft as ONE undo entry; undo restores', () {
      final s0 = EditorState(draft: paintableTreadled());
      final next = paintableTreadled().copyWith(shafts: 8); // an externally-computed resize result
      final s1 = s0.commitEdit(next);
      expect(s1.draft, equals(next));
      expect(s1.undo.length, 1);
      expect(s1.undo.last, equals(s0.draft));
      expect(s1.redo, isEmpty);
      expect(s1.dirtyStructural, isTrue);
      expect(s1.undoEdit().draft, equals(s0.draft), reason: 'one undo reverts the resize');
    });

    test('is a no-op (same identity) when the draft is unchanged', () {
      final s0 = EditorState(draft: paintableTreadled());
      expect(identical(s0.commitEdit(s0.draft), s0), isTrue);
    });
  });

  group('palette reducers', () {
    // paintableTreadled has a 2-color palette (white, black) with warp[0,0,0,0]/weft[1,1,1,1]
    // referencing both, so the "never shifts an index" claim is observable.
    test('setPaletteColor edits in place, leaves warp/weft UNTOUCHED, one undo entry', () {
      final s0 = EditorState(draft: paintableTreadled());
      final warp0 = s0.draft.warpColors;
      final weft0 = s0.draft.weftColors;
      final s1 = s0.setPaletteColor(1, const DraftColor(r: 10, g: 20, b: 30));
      expect(s1.draft.palette[1], const DraftColor(r: 10, g: 20, b: 30));
      expect(s1.draft.warpColors, warp0, reason: 'editing a swatch never shifts an index');
      expect(s1.draft.weftColors, weft0);
      expect(s1.undo.length, 1);
      expect(s1.redo, isEmpty);
      expect(s1.dirtyStructural, isTrue);
      expect(s1.undoEdit().draft, equals(s0.draft), reason: 'one undo reverts the color');
    });

    test('setPaletteColor to the current RGB is a no-op (same identity)', () {
      final s0 = EditorState(draft: paintableTreadled());
      expect(identical(s0.setPaletteColor(0, const DraftColor(r: 255, g: 255, b: 255)), s0), isTrue);
    });

    test('setPaletteColor throws on an out-of-range index', () {
      final s0 = EditorState(draft: paintableTreadled());
      expect(() => s0.setPaletteColor(2, const DraftColor(r: 1, g: 1, b: 1)), throwsRangeError);
      expect(() => s0.setPaletteColor(-1, const DraftColor(r: 1, g: 1, b: 1)), throwsRangeError);
    });

    test('addPaletteColor appends, leaves warp/weft untouched, one undo entry; undo shrinks it', () {
      final s0 = EditorState(draft: paintableTreadled());
      final s1 = s0.addPaletteColor(const DraftColor(r: 1, g: 2, b: 3));
      expect(s1.draft.palette.length, 3);
      expect(s1.draft.palette.last, const DraftColor(r: 1, g: 2, b: 3));
      expect(s1.draft.warpColors, s0.draft.warpColors, reason: 'appending never shifts an index');
      expect(s1.draft.weftColors, s0.draft.weftColors);
      expect(s1.undo.length, 1);
      expect(s1.undoEdit().draft.palette.length, 2, reason: 'undo restores the shorter palette');
    });
  });
}
