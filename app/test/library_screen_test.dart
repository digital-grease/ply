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
import 'package:ply/src/screens/editor_screen.dart';
import 'package:ply/src/screens/library_screen.dart';
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
  Future<ui.Image> renderDto(DraftDoc doc, {required int cellPx}) {
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

Future<void> pumpLibrary(WidgetTester tester, FakeLibraryRepo repo) async {
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
}

void main() {
  testWidgets('a NON-empty library shows both FABs with distinct hero tags (no Hero clash)',
      (tester) async {
    await pumpLibrary(tester, FakeLibraryRepo([_entry('a'), _entry('b')]));
    expect(tester.takeException(), isNull, reason: 'two FABs must not share a hero tag');
    expect(find.widgetWithText(FloatingActionButton, 'Import'), findsOneWidget);
    expect(find.widgetWithText(FloatingActionButton, 'New draft'), findsOneWidget);
  });

  testWidgets('a tile is one labelled (button) semantics node (M4 a11y)', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpLibrary(tester, FakeLibraryRepo([_entry('a')])); // name 'Pattern a'
    // The tile is wrapped in Semantics(button: true, label: 'Pattern <name>'); finding the label
    // proves the wrapper applied (the thumbnail + inner name Text are ExcludeSemantics'd, so the
    // node is the single tile button rather than image + duplicate name).
    expect(find.bySemanticsLabel('Pattern Pattern a'), findsOneWidget);
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
    await tester.pump(); // start the push
    await tester.pump(const Duration(milliseconds: 30));

    final editor = tester.widget<EditorScreen>(find.byType(EditorScreen));
    expect(editor.initialDoc, isNotNull, reason: 'a from-scratch doc, not a WIF parse');
    expect(editor.wifText, isNull);
    expect(editor.meta, isNull, reason: 'no meta -> the editor prompts on first save');
    expect(editor.id, isNull, reason: 'a new draft mints its id at save');
  });

  testWidgets('the empty-state New-draft button also pushes the editor', (tester) async {
    await pumpLibrary(tester, FakeLibraryRepo(const []));
    await tester.tap(find.widgetWithText(FilledButton, 'New draft'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));
    expect(find.byType(EditorScreen), findsOneWidget);
  });
}
