import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/draft_repository.dart';
import 'package:ply/src/models/draft_doc.dart';
import 'package:ply/src/rust/dto.dart' show StructureFamily, ThreadingKind;
import 'package:ply/src/state/draft_editor_notifier.dart';
import 'package:ply/src/state/editor_providers.dart';
import 'package:ply/src/widgets/structure_sheet.dart';

// The structure sheet's UI logic: family-specific fields, parsing the params, calling the repo
// generator (faked), and committing the result as one undo entry. The engine generators are
// cargo-tested + device-verified separately.

class FakeStructureRepo extends DraftRepository {
  ({
    StructureFamily family,
    ThreadingKind threading,
    int shafts,
    int over,
    int under,
    int counter,
    int ends,
    int picks,
  })? args;

  DraftDoc returnDoc =
      DraftDoc.blank(shafts: 4, treadles: 4).copyWith(name: 'generated');

  @override
  Future<DraftDoc> generateStructureDoc(
    DraftDoc base, {
    required StructureFamily family,
    required ThreadingKind threading,
    required int shafts,
    required int over,
    required int under,
    required int counter,
    required int ends,
    required int picks,
  }) async {
    args = (
      family: family,
      threading: threading,
      shafts: shafts,
      over: over,
      under: under,
      counter: counter,
      ends: ends,
      picks: picks,
    );
    return returnDoc;
  }
}

Future<ProviderContainer> openSheet(WidgetTester t, FakeStructureRepo repo) async {
  final c = ProviderContainer(overrides: [repositoryProvider.overrideWithValue(repo)]);
  addTearDown(c.dispose);
  c.read(draftEditorProvider.notifier).load(DraftDoc.blank(shafts: 4, treadles: 4));
  await t.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: ElevatedButton(
                onPressed: () => showStructureSheet(ctx),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await t.tap(find.text('open'));
  await t.pumpAndSettle();
  return c;
}

void main() {
  testWidgets('generating a twill passes the default params and commits the result', (t) async {
    final repo = FakeStructureRepo();
    final c = await openSheet(t, repo); // defaults: Twill, over 2 / under 2, straight, 16 x 16
    await t.tap(find.text('Generate'));
    await t.pumpAndSettle();
    expect(repo.args, isNotNull);
    expect(repo.args!.family, StructureFamily.twill);
    expect(repo.args!.over, 2);
    expect(repo.args!.under, 2);
    expect(repo.args!.threading, ThreadingKind.straight);
    expect(repo.args!.ends, 16);
    expect(repo.args!.picks, 16);
    // The generated doc was committed (one undo entry, dirty).
    expect(c.read(draftEditorProvider).draft.name, 'generated');
    expect(c.read(draftEditorProvider).dirtyStructural, isTrue);
    expect(c.read(draftEditorProvider).canUndo, isTrue);
  });

  testWidgets('switching to Satin shows shafts + counter and passes them', (t) async {
    final repo = FakeStructureRepo();
    await openSheet(t, repo);
    // Twill default shows Over/Under, not Shafts.
    expect(find.widgetWithText(TextFormField, 'Shafts'), findsNothing);
    await t.tap(find.text('Twill')); // open the structure dropdown
    await t.pumpAndSettle();
    await t.tap(find.text('Satin').last);
    await t.pumpAndSettle();
    expect(find.widgetWithText(TextFormField, 'Shafts'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Counter (satin move)'), findsOneWidget);
    await t.enterText(find.widgetWithText(TextFormField, 'Shafts'), '5');
    await t.enterText(find.widgetWithText(TextFormField, 'Counter (satin move)'), '2');
    await t.tap(find.text('Generate'));
    await t.pumpAndSettle();
    expect(repo.args!.family, StructureFamily.satin);
    expect(repo.args!.shafts, 5);
    expect(repo.args!.counter, 2);
  });

  testWidgets('an empty parameter blocks generation', (t) async {
    final repo = FakeStructureRepo();
    await openSheet(t, repo);
    await t.enterText(find.widgetWithText(TextFormField, 'Over'), '');
    await t.tap(find.text('Generate'));
    await t.pumpAndSettle();
    expect(repo.args, isNull, reason: 'no FFI/commit on an invalid parameter');
    expect(find.text('At least 1'), findsWidgets);
  });

  testWidgets('a non-coprime satin counter is rejected (would leave never-raised shafts)', (t) async {
    final repo = FakeStructureRepo();
    await openSheet(t, repo);
    await t.tap(find.text('Twill'));
    await t.pumpAndSettle();
    await t.tap(find.text('Satin').last); // _onFamily seeds shafts=5, counter=2 (valid)
    await t.pumpAndSettle();
    await t.enterText(find.widgetWithText(TextFormField, 'Shafts'), '6'); // satin(6,2): gcd 2
    await t.tap(find.text('Generate'));
    await t.pumpAndSettle();
    expect(repo.args, isNull, reason: 'a degenerate satin must not generate');
    expect(find.textContaining('sharing no factor'), findsOneWidget);
  });

  testWidgets('clearing a field then switching family does NOT crash on Generate', (t) async {
    // Regression: _generate used int.parse on every controller, throwing FormatException when a
    // field hidden by the new family held a cleared value.
    final repo = FakeStructureRepo();
    await openSheet(t, repo);
    await t.enterText(find.widgetWithText(TextFormField, 'Over'), ''); // clear a Twill-only field
    await t.tap(find.text('Twill'));
    await t.pumpAndSettle();
    await t.tap(find.text('Plain weave').last); // Over is now hidden
    await t.pumpAndSettle();
    await t.tap(find.text('Generate'));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull, reason: 'no FormatException on a hidden cleared field');
    expect(repo.args, isNotNull, reason: 'plain generates using a tolerant fallback for hidden Over');
    expect(repo.args!.family, StructureFamily.plain);
  });
}
