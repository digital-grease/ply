import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/knit_repository.dart';
import 'package:ply/src/models/draft_meta.dart';
import 'package:ply/src/models/knit_entry.dart';
import 'package:ply/src/screens/knit_library_screen.dart';
import 'package:ply/src/state/knit_editor_providers.dart';

// Host coverage for the M5 knit library: the empty-state call to action, the populated grid + New
// FAB, and the rename/delete tile actions routing to the repository. No FFI: a fake repo stubs
// listKnits/renameKnit/deleteKnit (these tests never navigate into the editor, which would need the
// render/validate FFI).

class FakeKnitLibraryRepo extends KnitRepository {
  FakeKnitLibraryRepo(this.entries);
  List<KnitEntry> entries;
  final List<String> deleted = [];
  final Map<String, String> renamed = {};

  @override
  Future<List<KnitEntry>> listKnits() async => entries;

  @override
  Future<void> renameKnit(String id, String newName) async => renamed[id] = newName;

  @override
  Future<void> deleteKnit(String id) async {
    deleted.add(id);
    entries = entries.where((e) => e.id != id).toList();
  }
}

KnitEntry _entry(String id, String name) => KnitEntry(
      id: id,
      patternPath: '/tmp/$id.plyknit',
      meta: DraftMeta(
        name: name,
        craft: 'Knitting',
        savedAt: DateTime.utc(2020),
        lastOpened: DateTime.utc(2020),
      ),
    );

Future<void> pumpLibrary(WidgetTester tester, FakeKnitLibraryRepo repo) async {
  final container = ProviderContainer(
    overrides: [knitRepositoryProvider.overrideWithValue(repo)],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: KnitLibraryScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('empty library shows the call to action and no FAB', (tester) async {
    await pumpLibrary(tester, FakeKnitLibraryRepo([]));
    expect(find.text('No knitting patterns yet.\nStart a new chart to begin.'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'New pattern'), findsOneWidget);
    expect(find.byType(FloatingActionButton), findsNothing,
        reason: 'the empty state offers New once; the FAB returns only once a pattern exists');
  });

  testWidgets('a populated library renders a tile per pattern plus the New FAB', (tester) async {
    await pumpLibrary(tester, FakeKnitLibraryRepo([_entry('a', 'Scarf'), _entry('b', 'Mittens')]));
    expect(find.text('Scarf'), findsOneWidget);
    expect(find.text('Mittens'), findsOneWidget);
    expect(find.byType(FloatingActionButton), findsOneWidget);
  });

  testWidgets('delete routes through a confirm dialog to the repository', (tester) async {
    final repo = FakeKnitLibraryRepo([_entry('a', 'Scarf')]);
    await pumpLibrary(tester, repo);

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete')); // the popup-menu item
    await tester.pumpAndSettle();
    expect(find.text('Delete pattern?'), findsOneWidget, reason: 'a confirm dialog gates the delete');
    await tester.tap(find.widgetWithText(FilledButton, 'Delete')); // the dialog's confirm
    await tester.pumpAndSettle();

    expect(repo.deleted, ['a']);
    expect(find.text('Scarf'), findsNothing, reason: 'the grid refreshed without the deleted tile');
  });

  testWidgets('rename routes the new name to the repository', (tester) async {
    final repo = FakeKnitLibraryRepo([_entry('a', 'Scarf')]);
    await pumpLibrary(tester, repo);

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Cowl');
    await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
    await tester.pumpAndSettle();

    expect(repo.renamed, {'a': 'Cowl'});
  });
}
