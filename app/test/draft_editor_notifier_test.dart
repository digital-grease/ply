import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/models/draft_doc.dart';
import 'package:ply/src/models/editor_state.dart';
import 'package:ply/src/state/draft_editor_notifier.dart';

// Host tests for the Riverpod glue: the notifier is a thin forwarder, but load() (constructor
// reset of undo/redo + set-or-CLEAR sourceWif) and the three reducer forwards are exactly the
// notifier-only logic the pure EditorState tests do not cover. No FFI, no widgets.

DraftDoc treadledDraft() => DraftDoc.blank(shafts: 4, treadles: 4);

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
}
