import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/draft_repository.dart';
import 'package:ply/src/models/draft_doc.dart';
import 'package:ply/src/models/shadow_weave_params.dart';
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
    bool applyThreading,
    bool applyTieup,
    bool applyTreadling,
    int endStart,
    int pickStart,
    LayerConstruction construction,
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
    LayerConstruction construction = LayerConstruction.twoLayers,
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
      applyThreading: applyThreading,
      applyTieup: applyTieup,
      applyTreadling: applyTreadling,
      endStart: endStart,
      pickStart: pickStart,
      construction: construction,
    );
    return returnDoc;
  }

  ShadowWeaveParams? shadowArgs;

  @override
  Future<DraftDoc> generateShadowWeaveDoc(DraftDoc base, ShadowWeaveParams params) async {
    shadowArgs = params;
    return returnDoc;
  }
}

/// Switch the open sheet's structure dropdown (currently showing [from]) to Shadow weave.
Future<void> chooseShadowWeave(WidgetTester t, {String from = 'Twill'}) async {
  await t.tap(find.text(from));
  await t.pumpAndSettle();
  await t.tap(find.text('Shadow weave').last);
  await t.pumpAndSettle();
}

String shadowSize(WidgetTester t) =>
    t.widget<Text>(find.byKey(const Key('shadow-weave-size'))).data!;

Finder blockField(String letter) => find.widgetWithText(TextFormField, letter);

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

  testWidgets('plain weave on an odd shaft count needs a point draw', (t) async {
    final repo = FakeStructureRepo();
    await openSheet(t, repo);
    await t.tap(find.text('Twill'));
    await t.pumpAndSettle();
    await t.tap(find.text('Plain weave').last);
    await t.pumpAndSettle();
    await t.enterText(find.widgetWithText(TextFormField, 'Shafts'), '3');
    await t.tap(find.text('Generate'));
    await t.pumpAndSettle();
    expect(find.text('Use an even number, or a point draw'), findsOneWidget);
    expect(repo.args, isNull, reason: 'a straight draw on 3 shafts is not plain weave');

    await t.tap(find.text('Straight draw'));
    await t.pumpAndSettle();
    await t.tap(find.text('Point draw').last);
    await t.pumpAndSettle();
    await t.tap(find.text('Generate'));
    await t.pumpAndSettle();
    expect(repo.args!.family, StructureFamily.plain);
    expect(repo.args!.shafts, 3);
    expect(repo.args!.threading, ThreadingKind.point);
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

  testWidgets('Shadow weave shows its own controls and generates the default design', (t) async {
    final repo = FakeStructureRepo();
    final c = await openSheet(t, repo);
    await chooseShadowWeave(t);
    for (final label in [
      'System',
      'Atwater',
      'Powell',
      'Shafts',
      'Layout',
      'Point',
      'Straight repeat',
      'Block widths',
      'Reverse the tie-up twill',
      'Block edges',
      'Smooth',
      'Feathery',
      'Balance the edges',
    ]) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(find.text('Partner shafts 1 & 3, 2 & 4. Both systems weave the same cloth.'),
        findsOneWidget);
    expect(find.text('Blocks run A to D, then back again.'), findsOneWidget);
    // One width field per block, A to D, each naming its dark & light shafts (Atwater).
    for (final (letter, shafts) in [('A', '1 & 3'), ('B', '2 & 4'), ('C', '3 & 1'), ('D', '4 & 2')]) {
      expect(blockField(letter), findsOneWidget, reason: letter);
      expect(find.text(shafts), findsOneWidget, reason: '$letter shows $shafts');
    }
    expect(blockField('E'), findsNothing, reason: 'four shafts give four blocks');
    expect(find.widgetWithText(TextFormField, 'Warp repeats'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Weft repeats'), findsOneWidget);
    // Sized in whole repeats, not by typed ends x picks; no log-cabin knobs.
    expect(find.widgetWithText(TextFormField, 'Warp ends'), findsNothing);
    expect(find.widgetWithText(TextFormField, 'Picks'), findsNothing);
    expect(find.text('Twill ground'), findsNothing);
    expect(find.widgetWithText(TextFormField, 'Color block'), findsNothing);
    // Point of A2 B2 C2 D2: 30 threads per repeat, 2 repeats + the balancing end and pick.
    expect(shadowSize(t), 'Resulting size: 61 ends x 61 picks');

    await t.ensureVisible(find.text('Generate'));
    await t.tap(find.text('Generate'));
    await t.pumpAndSettle();
    expect(repo.shadowArgs, const ShadowWeaveParams());
    expect(repo.args, isNull, reason: 'shadow weave never goes through generateStructureDoc');
    expect(c.read(draftEditorProvider).draft.name, 'generated');
    expect(c.read(draftEditorProvider).canUndo, isTrue);
  });

  testWidgets('Powell, 8 shafts, a straight repeat, reversed twill and feathery edges pass through',
      (t) async {
    final repo = FakeStructureRepo();
    await openSheet(t, repo);
    await chooseShadowWeave(t);
    await t.tap(find.text('Powell'));
    await t.pumpAndSettle();
    expect(find.text('Partner shafts 1 & 2, 3 & 4. Both systems weave the same cloth.'),
        findsOneWidget);
    // Powell's own letters: C is dark 2 / light 1.
    expect(find.text('2 & 1'), findsOneWidget);
    await t.tap(find.text('8'));
    await t.pumpAndSettle();
    expect(find.text('Partner shafts 1 & 2, 3 & 4, 5 & 6, 7 & 8. Both systems weave the same cloth.'),
        findsOneWidget);
    for (final letter in ['E', 'F', 'G', 'H']) {
      expect(blockField(letter), findsOneWidget, reason: '8 shafts give blocks A to H');
    }
    // Point of eight blocks of 2: 64 - 2 = 62 per repeat, x 2 + 1.
    expect(shadowSize(t), 'Resulting size: 125 ends x 125 picks');
    await t.tap(find.text('Straight repeat'));
    await t.pumpAndSettle();
    expect(find.text('Blocks run A to H, then start over.'), findsOneWidget);
    expect(shadowSize(t), 'Resulting size: 65 ends x 65 picks');
    await t.enterText(blockField('A'), '3');
    await t.enterText(blockField('H'), '1');
    await t.enterText(find.widgetWithText(TextFormField, 'Weft repeats'), '1');
    await t.pumpAndSettle();
    // 16 units -> 32 per repeat: 2 x 32 + 1 ends, 1 x 32 + 1 picks.
    expect(shadowSize(t), 'Resulting size: 65 ends x 33 picks');
    await t.tap(find.text('Reverse the tie-up twill'));
    await t.tap(find.text('Feathery'));
    await t.tap(find.text('Balance the edges'));
    await t.pumpAndSettle();
    expect(shadowSize(t), 'Resulting size: 64 ends x 32 picks');

    await t.ensureVisible(find.text('Generate'));
    await t.tap(find.text('Generate'));
    await t.pumpAndSettle();
    expect(
      repo.shadowArgs,
      const ShadowWeaveParams(
        system: ShadowSystem.powell,
        shafts: 8,
        layout: ShadowLayout.repeat,
        blockUnits: [3, 2, 2, 2, 2, 2, 2, 1],
        reverseTwill: true,
        featheryEdges: true,
        warpRepeats: 2,
        weftRepeats: 1,
        balanced: false,
      ),
    );
  });

  testWidgets('shadow-weave widths and repeats are validated before anything is generated',
      (t) async {
    final repo = FakeStructureRepo();
    await openSheet(t, repo);
    await chooseShadowWeave(t);
    Future<void> generate() async {
      await t.ensureVisible(find.text('Generate'));
      await t.tap(find.text('Generate'));
      await t.pumpAndSettle();
    }

    await t.enterText(blockField('B'), '0');
    await t.pumpAndSettle();
    expect(shadowSize(t), 'Resulting size: enter every block width and repeat');
    await generate();
    expect(find.text('At least 1'), findsOneWidget);
    expect(repo.shadowArgs, isNull, reason: 'a block needs at least one unit');

    await t.enterText(blockField('B'), '65');
    await generate();
    expect(find.text('At most ${ShadowWeaveParams.maxUnits}'), findsOneWidget);
    expect(repo.shadowArgs, isNull);

    // 40 units in a point: 158 threads a repeat; 13 repeats is 2055 ends, over the cap.
    for (final letter in ['A', 'B', 'C', 'D']) {
      await t.enterText(blockField(letter), '10');
    }
    await t.enterText(find.widgetWithText(TextFormField, 'Warp repeats'), '13');
    await t.pumpAndSettle();
    expect(shadowSize(t), 'Resulting size: 2055 ends x 317 picks');
    await generate();
    expect(find.text('Gives 2055 ends; at most $kMaxGeneratedThreads'), findsOneWidget);
    expect(repo.shadowArgs, isNull, reason: 'an over-budget size never reaches the engine');

    await t.enterText(find.widgetWithText(TextFormField, 'Warp repeats'), '');
    await generate();
    expect(find.text('At least 1'), findsOneWidget);
    expect(repo.shadowArgs, isNull);

    await t.enterText(find.widgetWithText(TextFormField, 'Warp repeats'), '12');
    await generate();
    expect(repo.shadowArgs?.ends, 1897, reason: '12 x 158 + 1 fits');
  });

  testWidgets('the shadow-weave design is remembered on reopen', (t) async {
    final repo = FakeStructureRepo();
    await openSheet(t, repo);
    await chooseShadowWeave(t);
    await t.tap(find.text('Powell'));
    await t.tap(find.text('Straight repeat'));
    await t.pumpAndSettle();
    await t.enterText(blockField('C'), '4');
    await t.ensureVisible(find.text('Generate'));
    await t.tap(find.text('Generate'));
    await t.pumpAndSettle();
    final first = repo.shadowArgs;
    expect(first?.blockUnits, [2, 2, 4, 2]);

    repo.shadowArgs = null;
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    expect(find.text('Shadow weave'), findsOneWidget, reason: 'family restored');
    expect(shadowSize(t), 'Resulting size: 41 ends x 41 picks');
    await t.ensureVisible(find.text('Generate'));
    await t.tap(find.text('Generate'));
    await t.pumpAndSettle();
    expect(repo.shadowArgs, first, reason: 'system, layout and widths restored');
  });

  testWidgets('generated cloth is capped at the preview budget per axis', (t) async {
    final repo = FakeStructureRepo();
    await openSheet(t, repo);
    await t.enterText(find.widgetWithText(TextFormField, 'Warp ends'), '${kMaxGeneratedThreads + 1}');
    await t.tap(find.text('Generate'));
    await t.pumpAndSettle();
    expect(find.text('At most $kMaxGeneratedThreads'), findsOneWidget);
    expect(repo.args, isNull, reason: 'an over-budget size never reaches the engine');

    await t.enterText(find.widgetWithText(TextFormField, 'Warp ends'), '$kMaxGeneratedThreads');
    await t.tap(find.text('Generate'));
    await t.pumpAndSettle();
    expect(repo.args, isNotNull);
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
    expect(find.widgetWithText(TextFormField, 'Warp repeats'), findsNothing,
        reason: 'the shadow-weave controls belong to shadow weave only');
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

  group('double weave construction (M8-09)', () {
    Future<void> chooseDoubleWeave(WidgetTester t) async {
      await t.tap(find.text('Twill'));
      await t.pumpAndSettle();
      await t.tap(find.text('Double weave').last);
      await t.pumpAndSettle();
    }

    String help(WidgetTester t) =>
        t.widget<Text>(find.byKey(const Key('double-weave-construction-help'))).data!;

    testWidgets('two independent layers is the default and passes through', (t) async {
      final repo = FakeStructureRepo();
      await openSheet(t, repo);
      await chooseDoubleWeave(t);
      expect(find.text('Construction'), findsOneWidget);
      expect(find.text('Fold'), findsNothing, reason: 'the fold side belongs to double width only');
      expect(
          help(t),
          'Two shuttles, one for each layer, both starting from the right. Top and bottom picks '
          'alternate; each layer has its own selvedges.');
      await t.tap(find.text('Generate'));
      await t.pumpAndSettle();
      expect(repo.args!.family, StructureFamily.doubleWeave);
      expect(repo.args!.construction, LayerConstruction.twoLayers);
    });

    testWidgets('a tube says it needs an odd number of ends and passes tube', (t) async {
      final repo = FakeStructureRepo();
      await openSheet(t, repo);
      await chooseDoubleWeave(t);
      await t.tap(find.text('Tube'));
      await t.pumpAndSettle();
      expect(
          help(t),
          'One shuttle starting from the left. Top and bottom picks alternate, so the layers join at '
          'both edges. A tube needs an odd number of warp ends to weave without a fault at an edge.');
      expect(find.text('This tube will have 15 warp ends.'), findsOneWidget, reason: '16 requested');
      await t.enterText(find.widgetWithText(TextFormField, 'Warp ends'), '21');
      await t.pump();
      expect(find.byKey(const Key('double-weave-tube-ends')), findsNothing, reason: 'already odd');
      await t.tap(find.text('Generate'));
      await t.pumpAndSettle();
      expect(repo.args!.construction, LayerConstruction.tube);
      expect(repo.args!.ends, 21);
    });

    testWidgets('double width chooses its fold side, and the choice is remembered', (t) async {
      final repo = FakeStructureRepo();
      await openSheet(t, repo);
      await chooseDoubleWeave(t);
      await t.tap(find.text('Double width'));
      await t.pumpAndSettle();
      expect(find.text('Fold'), findsOneWidget);
      expect(
          help(t),
          'One shuttle: top, bottom, bottom, top, starting from the left. The layers join at the fold '
          'on the right; the left edge has the two open selvedges.');
      await t.tap(find.text('Left'));
      await t.pumpAndSettle();
      expect(
          help(t),
          'One shuttle: top, bottom, bottom, top, starting from the right. The layers join at the '
          'fold on the left; the right edge has the two open selvedges.');
      await t.tap(find.text('Generate'));
      await t.pumpAndSettle();
      expect(repo.args!.construction, LayerConstruction.doubleWidthFoldLeft);

      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      expect(find.text('Fold'), findsOneWidget, reason: 'double width restored');
      await t.tap(find.text('Generate'));
      await t.pumpAndSettle();
      expect(repo.args!.construction, LayerConstruction.doubleWidthFoldLeft);
    });
  });
}
