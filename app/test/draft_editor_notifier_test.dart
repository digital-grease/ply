import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/models/draft_doc.dart';
import 'package:ply/src/models/draft_region.dart';
import 'package:ply/src/models/editor_state.dart';
import 'package:ply/src/state/draft_editor_notifier.dart';

// Host tests for the Riverpod glue: the notifier is a thin forwarder, but load() (constructor
// reset of undo/redo + set-or-CLEAR sourceWif), the three reducer forwards, and the drag-paint
// stroke driver (invert-first-cell + region-confine + dedup) are the notifier-only logic the pure
// EditorState tests do not cover. No FFI, no widgets.

DraftDoc treadledDraft() => DraftDoc.blank(shafts: 4, treadles: 4);

/// A treadled draft with ends + picks (paintable threading/tie-up/treadling).
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

void main() {
  late ProviderContainer container;
  setUp(() => container = ProviderContainer());
  tearDown(() => container.dispose());

  DraftEditorNotifier notifier() => container.read(draftEditorProvider.notifier);
  EditorState read() => container.read(draftEditorProvider);

  test('build() seeds a blank draft with empty history and no sourceWif', () {
    expect(read().draft, equals(DraftDoc.blank()));
    expect(read().canUndo, isFalse);
    expect(read().canRedo, isFalse);
    expect(read().sourceWif, isNull);
  });

  test('load() opens a draft and RESETS undo/redo while setting sourceWif', () {
    notifier().toggleTieupCell(1, 1); // grow the undo history first
    expect(read().canUndo, isTrue);

    final other = treadledDraft();
    notifier().load(other, sourceWif: 'WIF;...');
    expect(read().draft, equals(other));
    expect(read().undo, isEmpty);
    expect(read().redo, isEmpty);
    expect(read().canUndo, isFalse);
    expect(read().sourceWif, equals('WIF;...'));
  });

  test('load() with no sourceWif CLEARS it (constructor reset, not copyWith merge)', () {
    notifier().load(treadledDraft(), sourceWif: 'WIF;...');
    expect(read().sourceWif, equals('WIF;...'));
    notifier().load(treadledDraft()); // a from-scratch load
    expect(read().sourceWif, isNull,
        reason: 'load resets via the constructor, so sourceWif is cleared (not carried over)');
  });

  test('toggle/undo/redo forward to the reducers and update state + history', () {
    notifier().load(treadledDraft());
    notifier().toggleTieupCell(1, 1);
    expect(read().canUndo, isTrue);
    expect((read().draft.drive as DraftTreadled).tieup[0], equals([1]));

    notifier().undo();
    expect(read().canRedo, isTrue);
    expect((read().draft.drive as DraftTreadled).tieup[0], isEmpty);

    notifier().redo();
    expect((read().draft.drive as DraftTreadled).tieup[0], equals([1]));
  });

  test('a drag-paint stroke commits ONE undo entry and confines to its start region', () {
    notifier().load(paintableTreadled());
    final n = notifier();
    // Begin on threading end1/shaft2 (off -> fills); drag onto end2/shaft2.
    n.beginStroke(const DraftHit(DraftRegion.threading, 1, 2));
    n.paintAt(const DraftHit(DraftRegion.threading, 2, 2));
    n.paintAt(const DraftHit(DraftRegion.tieup, 1, 1)); // out of region -> ignored
    n.paintAt(const DraftHit(DraftRegion.threading, 2, 2)); // duplicate cell -> ignored
    n.endStroke();

    expect(read().undo.length, 1, reason: 'the whole drag is one undo entry');
    expect(read().draft.threading[0], equals([2]));
    expect(read().draft.threading[1], equals([2]));
    expect((read().draft.drive as DraftTreadled).tieup[0], equals([1]),
        reason: 'the out-of-region move was ignored');
    expect(read().canUndo, isTrue);
  });

  test('a stroke beginning on a FILLED cell erases (invert-first-cell)', () {
    notifier().load(paintableTreadled());
    final n = notifier();
    // tie-up (treadle 1, shaft 1) is filled -> begin erases it.
    n.beginStroke(const DraftHit(DraftRegion.tieup, 1, 1));
    n.endStroke();
    expect((read().draft.drive as DraftTreadled).tieup[0], isEmpty);
  });

  test('undo restores the whole stroke at once', () {
    notifier().load(paintableTreadled());
    final n = notifier();
    final before = read().draft;
    n.beginStroke(const DraftHit(DraftRegion.threading, 1, 2));
    n.paintAt(const DraftHit(DraftRegion.threading, 2, 2));
    n.endStroke();
    n.undo();
    expect(read().draft, equals(before), reason: 'one undo reverts the entire drag');
  });
}
