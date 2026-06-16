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
    int block,
    bool twill,
    bool applyThreading,
    bool applyTieup,
    bool applyTreadling,
    int endStart,
    int pickStart,
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
    int block = 4,
    bool twill = false,
    bool applyThreading = true,
    bool applyTieup = true,
    bool applyTreadling = true,
    int endStart = 0,
    int pickStart = 0,
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
      block: block,
      twill: twill,
      applyThreading: applyThreading,
      applyTieup: applyTieup,
      applyTreadling: applyTreadling,
      endStart: endStart,
      pickStart: pickStart,
    );
    return returnDoc;
  }
}

Future<ProviderContainer> openSheet(WidgetTester t, FakeStructureRepo repo) async {
  // A tall viewport so the composable sheet (family params + Apply chips + offsets) fits without the
  // Generate button scrolling off the test's default 600px height.
  t.view.physicalSize = const Size(800, 1600);
  t.view.devicePixelRatio = 1.0;
  addTearDown(() {
    t.view.resetPhysicalSize();
    t.view.resetDevicePixelRatio();
  });
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

  testWidgets('Overshot shows Block width, hides the tie-up/threading controls, passes block', (t) async {
    final repo = FakeStructureRepo();
    await openSheet(t, repo);
    await t.tap(find.text('Twill')); // open the structure dropdown
    await t.pumpAndSettle();
    await t.tap(find.text('Overshot').last);
    await t.pumpAndSettle();
    expect(find.widgetWithText(TextFormField, 'Block width'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Over'), findsNothing);
    expect(find.text('Threading'), findsNothing,
        reason: 'whole-draft structures fix their own threading');
    await t.enterText(find.widgetWithText(TextFormField, 'Block width'), '6');
    await t.tap(find.text('Generate'));
    await t.pumpAndSettle();
    expect(repo.args!.family, StructureFamily.overshot);
    expect(repo.args!.block, 6);
  });

  testWidgets('Shadow weave toggles a twill ground and passes twill + default block', (t) async {
    final repo = FakeStructureRepo();
    await openSheet(t, repo);
    await t.tap(find.text('Twill'));
    await t.pumpAndSettle();
    await t.tap(find.text('Shadow weave').last);
    await t.pumpAndSettle();
    expect(find.text('Twill ground'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Color block'), findsOneWidget);
    await t.tap(find.text('Twill ground')); // flip the switch on
    await t.pumpAndSettle();
    await t.tap(find.text('Generate'));
    await t.pumpAndSettle();
    expect(repo.args!.family, StructureFamily.shadowWeave);
    expect(repo.args!.twill, isTrue);
    expect(repo.args!.block, 4, reason: 'the default color block');
  });

  testWidgets('Double weave hides the family knobs and generates from ends x picks only', (t) async {
    final repo = FakeStructureRepo();
    await openSheet(t, repo);
    await t.tap(find.text('Twill'));
    await t.pumpAndSettle();
    await t.tap(find.text('Double weave').last);
    await t.pumpAndSettle();
    expect(find.widgetWithText(TextFormField, 'Over'), findsNothing);
    expect(find.widgetWithText(TextFormField, 'Block width'), findsNothing);
    expect(find.widgetWithText(TextFormField, 'Color block'), findsNothing);
    expect(find.widgetWithText(TextFormField, 'Start at end'), findsNothing,
        reason: 'whole-draft structures apply wholesale, no component/range controls');
    expect(find.widgetWithText(TextFormField, 'Warp ends'), findsOneWidget);
    await t.tap(find.text('Generate'));
    await t.pumpAndSettle();
    expect(repo.args!.family, StructureFamily.doubleWeave);
  });

  testWidgets('deselecting a component passes its apply flag false, others true', (t) async {
    final repo = FakeStructureRepo();
    await openSheet(t, repo); // Twill (basic) — all three components selected by default
    await t.tap(find.widgetWithText(FilterChip, 'Tie-up'));
    await t.pumpAndSettle();
    await t.tap(find.text('Generate'));
    await t.pumpAndSettle();
    expect(repo.args!.applyTieup, isFalse);
    expect(repo.args!.applyThreading, isTrue);
    expect(repo.args!.applyTreadling, isTrue);
  });

  testWidgets('Start-at-end / Start-at-pick offsets are passed through', (t) async {
    final repo = FakeStructureRepo();
    await openSheet(t, repo);
    await t.enterText(find.widgetWithText(TextFormField, 'Start at end'), '4');
    await t.enterText(find.widgetWithText(TextFormField, 'Start at pick'), '8');
    await t.tap(find.text('Generate'));
    await t.pumpAndSettle();
    expect(repo.args!.endStart, 4);
    expect(repo.args!.pickStart, 8);
  });

  testWidgets('deselecting all components blocks generation with a hint', (t) async {
    final repo = FakeStructureRepo();
    await openSheet(t, repo);
    for (final c in ['Threading', 'Tie-up', 'Treadling']) {
      await t.tap(find.widgetWithText(FilterChip, c));
      await t.pumpAndSettle();
    }
    await t.tap(find.text('Generate'));
    await t.pumpAndSettle();
    expect(repo.args, isNull, reason: 'nothing selected -> no generate');
    expect(find.text('Pick at least one component to apply.'), findsOneWidget);
  });

  testWidgets('remembers the last family + component choice on reopen', (t) async {
    final repo = FakeStructureRepo();
    await openSheet(t, repo);
    await t.tap(find.text('Twill'));
    await t.pumpAndSettle();
    await t.tap(find.text('Satin').last); // _onFamily seeds shafts 5 / counter 2 (valid)
    await t.pumpAndSettle();
    await t.tap(find.widgetWithText(FilterChip, 'Treadling')); // deselect
    await t.pumpAndSettle();
    await t.tap(find.text('Generate'));
    await t.pumpAndSettle();
    expect(repo.args!.family, StructureFamily.satin);
    expect(repo.args!.applyTreadling, isFalse);

    // Reopen (same container) — the sheet should restore Satin + the deselected Treadling.
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    expect(find.text('Satin'), findsOneWidget, reason: 'family restored');
    await t.tap(find.text('Generate'));
    await t.pumpAndSettle();
    expect(repo.args!.applyTreadling, isFalse, reason: 'component choice restored');
  });
}
