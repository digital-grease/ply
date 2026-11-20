import 'dart:ui' as ui;
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/draft_repository.dart';
import 'package:ply/src/models/draft_doc.dart';
import 'package:ply/src/models/draft_issue.dart';
import 'package:ply/src/models/draft_meta.dart';
import 'package:ply/src/models/loom_type.dart';
import 'package:ply/src/screens/editor_screen.dart';
import 'package:ply/src/screens/library_screen.dart';
import 'package:ply/src/state/draft_editor_notifier.dart';
import 'package:ply/src/state/editor_providers.dart';

// Host coverage for the Phase 5.2 Library changes: the two-FAB layout (distinct hero tags), the
// empty-state call to action, and the New-draft FAB pushing the editor on a fresh blank doc.

/// A repository stub: `list()` is controllable, and the editor-facing methods are stubbed so the
/// EditorScreen the New-draft FAB pushes can build host-side (it reads `repositoryProvider`).
class FakeLibraryRepo extends DraftRepository {
  FakeLibraryRepo(this.entries);
  final List<DraftEntry> entries;

  @override
  Future<List<DraftEntry>> list() async => entries;

  @override
  Future<List<DraftIssue>> validateDto(DraftDoc doc) async => const [];

  @override
  Future<ui.Image> renderDto(
    DraftDoc doc, {
    required int cellPx,
    bool gridlines = false,
    int floatThreshold = 0,
    bool threadTexture = false,
  }) {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      Uint8List.fromList(const [0, 0, 0, 255]),
      1,
      1,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    return completer.future;
  }
}

DraftEntry _entry(String id) => DraftEntry(
      id: id,
      wifPath: '/tmp/$id.wif',
      meta: DraftMeta(
        name: 'Pattern $id',
        savedAt: DateTime.utc(2020),
        lastOpened: DateTime.utc(2020),
      ),
    );

/// A library whose first save of a new draft waits on [gate], then lists the draft.
class SlowSaveLibraryRepo extends FakeLibraryRepo {
  SlowSaveLibraryRepo(super.entries);

  final Completer<void> gate = Completer<void>();
  int saves = 0;

  @override
  Future<String> saveDto(
    DraftDoc doc, {
    required DraftMeta meta,
    String? id,
    String? sourceWif,
  }) async {
    saves++;
    await gate.future;
    entries.add(DraftEntry(id: 'new', wifPath: '/tmp/new.wif', meta: meta));
    return 'new';
  }
}

Future<ProviderContainer> pumpLibrary(WidgetTester tester, FakeLibraryRepo repo) async {
  final container = ProviderContainer(
    overrides: [repositoryProvider.overrideWithValue(repo)],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: LibraryScreen(repository: repo)),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

/// Pump a bounded number of frames (the editor's loading spinner never settles).
Future<void> pumpFrames(WidgetTester tester) async {
  await tester.pump();
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 30));
  }
}

void main() {
  testWidgets('a NON-empty library shows both FABs with distinct hero tags (no Hero clash)',
      (tester) async {
    await pumpLibrary(tester, FakeLibraryRepo([_entry('a'), _entry('b')]));
    expect(tester.takeException(), isNull, reason: 'two FABs must not share a hero tag');
    expect(find.widgetWithText(FloatingActionButton, 'Import'), findsOneWidget);
    expect(find.widgetWithText(FloatingActionButton, 'New draft'), findsOneWidget);
  });

  testWidgets('a tile is one labelled (button) semantics node WITH the tap action (M4 a11y)',
      (tester) async {
    final handle = tester.ensureSemantics();
    await pumpLibrary(tester, FakeLibraryRepo([_entry('a')])); // name 'Pattern a'
    // The tile is wrapped in Semantics(button: true, label: 'Pattern <name>'); finding the label
    // proves the wrapper applied (the thumbnail + inner name Text are ExcludeSemantics'd, so the
    // node is the single tile button rather than image + duplicate name).
    expect(find.bySemanticsLabel('Pattern Pattern a'), findsOneWidget);
    // Regression: the label and the tap/long-press ACTIONS must live on the SAME node. They used to
    // split (label on the outer Semantics, action on the inner InkWell), which detaches the label
    // from the actionable node and drops the onTapHint. The actions now sit on the labelled node.
    final data =
        tester.getSemantics(find.bySemanticsLabel('Pattern Pattern a')).getSemanticsData();
    expect(data.label, 'Pattern Pattern a');
    expect(data.hasAction(ui.SemanticsAction.tap), isTrue,
        reason: 'the labelled tile node is itself tappable (open)');
    expect(data.hasAction(ui.SemanticsAction.longPress), isTrue,
        reason: 'and long-pressable (actions)');
    handle.dispose();
  });

  testWidgets('an EMPTY library hides the FABs and shows the centered call to action',
      (tester) async {
    await pumpLibrary(tester, FakeLibraryRepo(const []));
    expect(find.byType(FloatingActionButton), findsNothing,
        reason: 'FABs are suppressed so they do not duplicate the centered buttons');
    expect(find.widgetWithText(FilledButton, 'New draft'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Import pattern'), findsOneWidget);
  });

  testWidgets('the New-draft FAB pushes the editor on a fresh blank doc (no meta)', (tester) async {
    await pumpLibrary(tester, FakeLibraryRepo([_entry('a')]));
    await tester.tap(find.widgetWithText(FloatingActionButton, 'New draft'));
    await tester.pumpAndSettle(); // the loom-type picker
    await tester.tap(find.text('Jack (floor loom)'));
    await tester.pump(); // start the push
    await tester.pump(const Duration(milliseconds: 30));

    final editor = tester.widget<EditorScreen>(find.byType(EditorScreen));
    expect(editor.initialDoc, isNotNull, reason: 'a from-scratch doc, not a WIF parse');
    expect(editor.wifText, isNull);
    expect(editor.meta, isNull, reason: 'no meta -> the editor prompts on first save');
    expect(editor.id, isNull, reason: 'a new draft mints its id at save');
    expect(editor.initialLoomType, LoomType.jack, reason: 'the chosen loom flows into the editor');
  });

  testWidgets('the empty-state New-draft button also pushes the editor', (tester) async {
    await pumpLibrary(tester, FakeLibraryRepo(const []));
    await tester.tap(find.widgetWithText(FilledButton, 'New draft'));
    await tester.pumpAndSettle(); // the loom-type picker
    await tester.tap(find.text('Table loom'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));
    expect(find.byType(EditorScreen), findsOneWidget);
  });

  testWidgets('a new draft whose write lands after a Discard is still listed', (tester) async {
    // Discard chosen while the first save's write is under way pops the editor without `true`,
    // but the write still lands; the library must list the draft once it does.
    final repo = SlowSaveLibraryRepo([_entry('a')]);
    final container = await pumpLibrary(tester, repo);
    await tester.tap(find.widgetWithText(FloatingActionButton, 'New draft'));
    await tester.pumpAndSettle(); // the loom-type picker
    await tester.tap(find.text('Jack (floor loom)'));
    await pumpFrames(tester);
    // Grow the blank draft to one cell and edit it, so it is saveable and has unsaved work.
    final grown = DraftDoc.blank(shafts: 4, treadles: 4).copyWith(
      threading: const [
        [1],
      ],
      drive: DraftTreadled(tieup: const [
        [1],
      ], treadling: const [
        [1],
      ]),
      warpColors: const [0],
      weftColors: const [0],
    );
    container.read(draftEditorProvider.notifier).load(grown);
    container.read(draftEditorProvider.notifier).toggleTieupCell(1, 2);
    await pumpFrames(tester);

    await tester.tap(find.byIcon(Icons.save_outlined));
    await pumpFrames(tester);
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Late scarf');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await pumpFrames(tester); // the write parks on the gate
    expect(repo.saves, 1);

    await tester.tap(find.byType(BackButton));
    await pumpFrames(tester);
    await tester.tap(find.widgetWithText(TextButton, 'Discard'));
    await tester.pumpAndSettle();
    expect(find.byType(EditorScreen), findsNothing, reason: 'Discard left the editor at once');
    expect(find.text('Late scarf'), findsNothing, reason: 'the write has not landed yet');

    repo.gate.complete();
    await tester.pumpAndSettle();
    expect(find.text('Late scarf'), findsOneWidget, reason: 'listed once the write lands');
    expect(find.text('Pattern a'), findsOneWidget);
  });

  testWidgets('rename: a name saved before the limit opens as it is and must be shortened',
      (tester) async {
    final long = 'L' * 300;
    final repo = _RenamingRepo([
      DraftEntry(
        id: 'a',
        wifPath: '/tmp/a.wif',
        meta: DraftMeta(name: long, savedAt: DateTime.utc(2020), lastOpened: DateTime.utc(2020)),
      ),
    ]);
    await pumpLibrary(tester, repo);
    await tester.tap(find.byTooltip('Pattern actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    expect(find.text('Rename pattern'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, long);
    const said = 'Names can be at most 200 characters (this one has 300).';
    expect(find.text(said), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
    await tester.pumpAndSettle();
    expect(repo.renamed, isEmpty, reason: 'nothing written while it is too long');
    expect(find.text(said), findsOneWidget, reason: 'the dialog stays open');

    await tester.enterText(find.byType(TextField), 'Towel');
    await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
    await tester.pumpAndSettle();
    expect(repo.renamed, {'a': 'Towel'});
  });
}

/// A library that records each rename.
class _RenamingRepo extends FakeLibraryRepo {
  _RenamingRepo(super.entries);

  final Map<String, String> renamed = {};

  @override
  Future<void> rename(String id, String newName) async => renamed[id] = newName;
}
