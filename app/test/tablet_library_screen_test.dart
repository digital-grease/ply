import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/draft_repository.dart';
import 'package:ply/src/data/knit_repository.dart';
import 'package:ply/src/data/tablet_repository.dart';
import 'package:ply/src/models/draft_meta.dart';
import 'package:ply/src/models/knit_entry.dart';
import 'package:ply/src/models/tablet_band.dart';
import 'package:ply/src/rust/tablet_dto.dart';
import 'package:ply/src/screens/home_screen.dart';
import 'package:ply/src/screens/tablet_library_screen.dart';
import 'package:ply/src/state/editor_providers.dart';
import 'package:ply/src/state/knit_editor_providers.dart';
import 'package:ply/src/state/tablet_editor_providers.dart';

import 'tablet_test_support.dart';

// Host coverage for the Tablet weaving tab of the library (M10-02): the tab in the unified home, the
// empty state, the band tiles (one screen-reader node each), and the New band dialog, which offers
// both start presets with Ply home first and says that order is provisional.

class ListingTabletRepo extends FakeTabletRepo {
  ListingTabletRepo(this.entries) : super(oracle: Oracle('band-1-threaded-in'));
  final List<TabletEntry> entries;

  @override
  Future<List<TabletEntry>> listBands() async => entries;
}

class _NoDrafts extends DraftRepository {
  @override
  Future<List<DraftEntry>> list() async => const [];
}

class _NoKnits extends KnitRepository {
  @override
  Future<List<KnitEntry>> listKnits() async => const [];
}

TabletEntry entry(String id, String name) => TabletEntry(
      id: id,
      meta: DraftMeta(
          name: name,
          craft: kTabletCraft,
          savedAt: DateTime.utc(2026, 11, 16),
          lastOpened: DateTime.utc(2026, 11, 16)),
      bandPath: '/nowhere/$id.plytab',
    );

Future<void> pumpLibrary(WidgetTester tester, TabletRepository repo) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [tabletRepositoryProvider.overrideWithValue(repo)],
    child: const MaterialApp(home: TabletLibraryScreen()),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the home has a Tablet weaving tab that shows the tablet library', (tester) async {
    final drafts = _NoDrafts();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        repositoryProvider.overrideWithValue(drafts),
        knitRepositoryProvider.overrideWithValue(_NoKnits()),
        tabletRepositoryProvider.overrideWithValue(ListingTabletRepo(const [])),
      ],
      child: MaterialApp(home: HomeScreen(repository: drafts)),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Tablet weaving'), findsOneWidget);
    await tester.tap(find.text('Tablet weaving'));
    await tester.pumpAndSettle();
    expect(find.textContaining('No tablet weaving bands yet'), findsOneWidget);
  });

  testWidgets('saved bands are tiles, each one node for a screen reader', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpLibrary(tester, ListingTabletRepo([entry('a', 'Diagonals'), entry('b', 'Sampler')]));
    expect(find.text('Diagonals'), findsOneWidget);
    expect(find.text('Sampler'), findsOneWidget);
    expect(find.bySemanticsLabel('Band Diagonals'), findsOneWidget);
    expect(find.text('New band'), findsOneWidget);
    // The thumbnails show computed faces: the review note is above them.
    expect(find.byKey(const ValueKey('tablet-review-note')), findsOneWidget);
    handle.dispose();
  });

  testWidgets('a band that cannot be drawn says so; an empty band keeps the plain placeholder',
      (tester) async {
    final repo = _DrawingTabletRepo([entry('broken', 'Has errors'), entry('empty', 'No picks')]);
    await pumpLibrary(tester, repo);
    // The rebuilds run in the background, one at a time; let them finish.
    await tester.pumpAndSettle();
    expect(repo.rebuilt, ['broken', 'empty']);
    // The band with something to draw that could not be drawn: the shared "no preview" mark.
    expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
    expect(find.byTooltip('No preview: Ply could not draw this project. Open it to see why.'),
        findsOneWidget);
    // The band with no picks has nothing to draw: the plain placeholder, not a failure.
    expect(find.byIcon(Icons.view_week_outlined), findsOneWidget);
  });

  testWidgets('the New band dialog offers both presets, Ply home first and provisional',
      (tester) async {
    await pumpLibrary(tester, ListingTabletRepo(const []));
    await tester.tap(find.widgetWithText(FilledButton, 'New band'));
    await tester.pumpAndSettle();
    final home = find.byKey(const ValueKey('new-band-plyHome'));
    final printed = find.byKey(const ValueKey('new-band-printedFaceRight'));
    expect(tester.getTopLeft(home).dy, lessThan(tester.getTopLeft(printed).dy));
    expect(find.text(kFirstPresetNote), findsOneWidget);
    expect(find.text('8'), findsOneWidget);
    await tester.tap(find.byTooltip('More cards'));
    await tester.pump();
    expect(find.text('9'), findsOneWidget);
    // Cancel makes nothing.
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('the dialog returns a band with the chosen cards and start', (tester) async {
    TabletDocumentDto? got;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () async => got = await showNewBandDialog(context),
          child: const Text('go'),
        ),
      ),
    ));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Fewer cards'));
    await tester.tap(find.byKey(const ValueKey('new-band-printedFaceRight')));
    await tester.pump();
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    final doc = got!;
    expect(doc.cards.length, 7);
    expect(doc.cards.every((c) => sameArrangement(c.start, kPrintedFaceRight)), isTrue);
    // Left half S, right half Z.
    expect(doc.cards.map((c) => threadingLetter(c.threading)).join(), 'SSSSZZZ');
  });
}

/// Rebuilding fails for "broken" (it has picks but cannot be drawn, as a band with errors) and draws
/// nothing for "empty" (no picks), as the repository does.
class _DrawingTabletRepo extends ListingTabletRepo {
  _DrawingTabletRepo(super.entries);
  final List<String> rebuilt = [];

  @override
  Future<void> rebuildThumbnail(String id) async {
    rebuilt.add(id);
    if (id == 'broken') throw StateError('the band has structural errors');
  }

  @override
  Future<bool?> hasSomethingToDraw(String id) async => id == 'broken';
}
