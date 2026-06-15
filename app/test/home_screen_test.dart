import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/draft_repository.dart';
import 'package:ply/src/data/knit_repository.dart';
import 'package:ply/src/models/draft_meta.dart';
import 'package:ply/src/models/knit_entry.dart';
import 'package:ply/src/screens/home_screen.dart';
import 'package:ply/src/state/editor_providers.dart';
import 'package:ply/src/state/knit_editor_providers.dart';

// Host coverage for the unified home: one library with a tab per craft. Both tabs' libraries are
// empty (fakes), so switching tabs swaps between the weave and knit empty-state call to actions.

class FakeDraftRepo extends DraftRepository {
  @override
  Future<List<DraftEntry>> list() async => const [];
}

class FakeKnitRepo extends KnitRepository {
  @override
  Future<List<KnitEntry>> listKnits() async => const [];
}

void main() {
  testWidgets('shows both craft tabs and switches between the two libraries', (tester) async {
    final draft = FakeDraftRepo();
    final c = ProviderContainer(overrides: [
      repositoryProvider.overrideWithValue(draft),
      knitRepositoryProvider.overrideWithValue(FakeKnitRepo()),
    ]);
    addTearDown(c.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(home: HomeScreen(repository: draft)),
      ),
    );
    await tester.pumpAndSettle();

    // Both tabs present; the Weaving tab is active first -> the weave empty state shows.
    expect(find.text('Weaving'), findsOneWidget);
    expect(find.text('Knitting'), findsOneWidget);
    expect(find.textContaining('No patterns yet'), findsOneWidget);

    // Switch to the Knitting tab -> the knit empty state shows.
    await tester.tap(find.text('Knitting'));
    await tester.pumpAndSettle();
    expect(find.textContaining('No knitting patterns yet'), findsOneWidget);
  });
}
