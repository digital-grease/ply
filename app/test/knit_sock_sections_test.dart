import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/models/draft_doc.dart' show MeasureUnit;
import 'package:ply/src/models/draft_meta.dart';
import 'package:ply/src/models/knit_sections.dart';
import 'package:ply/src/print/knit_print.dart';
import 'package:ply/src/print/pdf_builder.dart';
import 'package:ply/src/print/print_document.dart';
import 'package:ply/src/print/print_layout.dart';
import 'package:ply/src/rust/knit_dto.dart';
import 'package:ply/src/screens/knit_sections_screen.dart';
import 'package:ply/src/screens/knit_written_screen.dart';
import 'package:ply/src/state/knit_editor_providers.dart';
import 'package:ply/src/state/knit_editor_state.dart';
import 'package:ply/src/widgets/knit_step_dialog.dart';
import 'package:ply/src/widgets/name_input_dialog.dart';

import 'knit_editor_screen_test.dart' show FakeSavingRepo, editChart, pumpHostedEditor;
import 'knit_sections_fixture_test.dart' show OracleRepo;
import 'knit_sections_screen_test.dart' show FakeSectionsRepo;
import 'knit_sections_test_support.dart';
import 'print/print_test_support.dart';

// Host coverage for the second slice of knitting sections (socks and work in the round): the new
// step kinds' forms return exactly the action they describe and refuse numbers out of range; a
// section can say whether it is worked flat or in the round (one undo entry, shown on the card and
// in the heading); the helpers that list the parts worked flat and the needle groups; and the sock
// fixtures' hand-derived ledger reaches the Sections screen, the written instructions and the PDF
// with round labels, needle-group counts and the grafted toe. The engine is stood in for by the
// fixtures' oracles.

KnitPatternDto _sock() => patternFromPlyknit(sectionFixtureText('sock-heel-flap-round', 'plyknit'));

/// Open the form for [kind] over [pattern] (optionally editing [initial]); the action it returns
/// lands in the returned list.
Future<List<KnitStepActionDto?>> _open(WidgetTester tester, KnitStepKind kind,
    {KnitPatternDto? pattern, KnitStepActionDto? initial}) async {
  final p = pattern ?? _sock();
  final results = <KnitStepActionDto?>[];
  await tester.binding.setSurfaceSize(const Size(600, 2400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => TextButton(
        onPressed: () async => results
            .add(await showKnitStepDialog(context, kind: kind, pattern: p, initial: initial)),
        child: const Text('open'),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return results;
}

Future<void> _save(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('knit-step-save')));
  await tester.pumpAndSettle();
}

const _range = 'Enter a whole number from 1 to 100000.';

PrintSection _section(PrintDocument d, String heading) =>
    d.sections.firstWhere((s) => s.heading == heading);

void main() {
  reviewTests();
  group('helpers', () {
    test('the parts worked flat and the needle groups a pattern names', () {
      final p = _sock();
      final parts = knitFlatParts(p);
      expect([for (final h in parts) (h.stepId, h.label)],
          [('step-5', 'heel flap (Heel flap, step 1)')]);
      expect(knitGroupNames(p), ['sole', 'instep']);
    });

    test('a new step id skips every id a pick-up step still names', () {
      var s = KnitEditorState(pattern: _sock());
      // Delete the heel flap's work-flat step: the pick-ups still name step-5, and so does a new id
      // never become step-5 again (it is past the largest id in use anyway, step-32).
      s = s.removeStepAt(2, 0);
      expect(nextStepId(s.pattern), 'step-33');
      final p = KnitEditorState(pattern: _noSteps()).addSection('Heel').pattern;
      final orphan = KnitEditorState(pattern: p)
          .addStepAt(0,
              const KnitStepActionDto.pickUp(count: 2, along: PickUpAlongDto.piece(step: 'step-7')))
          .pattern;
      expect(nextStepId(orphan), 'step-8', reason: 'step-7 is named by the pick-up');
    });

    test('section headings with how they are worked are headings', () {
      expect(isKnitSectionHeading('Section 3: Heel flap (worked flat)'), isTrue);
      expect(isKnitSectionHeading('Section 2 (worked in the round)'), isTrue);
      expect(isKnitSectionHeading('Section 2 (anything else)'), isFalse);
      expect(isKnitSectionHeading('Next 18 rnds: knit.'), isFalse);
    });

    test('saying how a section is worked is one undo entry, and Undo takes it back', () {
      var s = KnitEditorState(pattern: _sock());
      s = s.setSectionConstructionAt(4, ConstructionKind.inTheRound);
      expect(s.pattern.sections[4].construction, ConstructionKind.inTheRound);
      expect(s.pattern.sections[4].steps.length, 8);
      final again = s.setSectionConstructionAt(4, ConstructionKind.inTheRound);
      expect(identical(again, s), isTrue, reason: 'no change, no undo entry');
      s = s.setSectionConstructionAt(4, null);
      expect(s.pattern.sections[4].construction, isNull);
      s = s.undoEdit();
      expect(s.pattern.sections[4].construction, ConstructionKind.inTheRound);
    });
  });

  group('forms', () {
    testWidgets('join in the round has nothing to fill in', (tester) async {
      final r = await _open(tester, KnitStepKind.joinRound);
      expect(find.textContaining('the stitches join into a round'), findsOneWidget);
      await _save(tester);
      expect(r, [const KnitStepActionDto.joinRound()]);
    });

    testWidgets('work part of the round flat: a count, a name and slipped edges', (tester) async {
      final r = await _open(tester, KnitStepKind.workFlat);
      await tester.enterText(find.byKey(const Key('knit-step-count')), '0');
      await _save(tester);
      expect(find.text(_range), findsOneWidget);
      expect(r, isEmpty);
      await tester.enterText(find.byKey(const Key('knit-step-count')), '32');
      await tester.tap(find.byKey(const Key('knit-step-slip')));
      await tester.pump();
      await _save(tester);
      expect(r, [const KnitStepActionDto.workFlat(count: 32, name: 'heel flap', slipEdges: false)]);
    });

    testWidgets('rows or rounds: a count and the pattern\'s words', (tester) async {
      final r = await _open(tester, KnitStepKind.rows);
      await tester.enterText(find.byKey(const Key('knit-step-count')), '50');
      await tester.enterText(find.byKey(const Key('knit-step-text')), '  knit ');
      await _save(tester);
      expect(r, [const KnitStepActionDto.rows(count: 50, text: 'knit')]);
    });

    testWidgets('short row: a turn at the gap with a decrease before it', (tester) async {
      final r = await _open(tester, KnitStepKind.shortRow);
      await tester.tap(find.text('Turn this many stitches before the gap'));
      await tester.pump();
      await tester.enterText(find.byKey(const Key('knit-step-count')), '1');
      await tester.tap(find.byKey(const Key('knit-step-decrease')));
      await tester.pump();
      await tester.tap(find.text('p2tog'));
      await tester.enterText(find.byKey(const Key('knit-step-after')), '1');
      await tester.tap(find.text('Purl'));
      await tester.tap(find.text('Just turn (method not stated)'));
      await tester.pump();
      await _save(tester);
      expect(
          r.single,
          const KnitStepActionDto.shortRow(
            stitch: WorkStitchKind.purl,
            to: TurnAtDto.beforeGap(count: 1),
            method: TurnMethodKind.unspecified,
            resolveTurns: false,
            decrease: TurnDecreaseDto(kind: DecreaseKind.p2Tog, after: 1),
          ));
    });

    testWidgets('short row: 0 is allowed at the gap but not from the end', (tester) async {
      var r = await _open(tester, KnitStepKind.shortRow);
      await tester.enterText(find.byKey(const Key('knit-step-count')), '0');
      await _save(tester);
      expect(find.text(_range), findsOneWidget, reason: 'to the last 0 sts is no short row');
      expect(r, isEmpty);
      await tester.tap(find.text('Turn this many stitches past the gap'));
      await tester.pump();
      await _save(tester);
      expect((r.single! as KnitStepActionDto_ShortRow).to, const TurnAtDto.pastGap(count: 0));
      r = await _open(tester, KnitStepKind.shortRow,
          initial: const KnitStepActionDto.shortRow(
              stitch: WorkStitchKind.knit,
              to: TurnAtDto.beforeGap(count: 1),
              method: TurnMethodKind.unspecified,
              resolveTurns: false,
              decrease: TurnDecreaseDto(kind: DecreaseKind.ssk, after: 1)));
      await _save(tester);
      expect((r.single! as KnitStepActionDto_ShortRow).decrease,
          const TurnDecreaseDto(kind: DecreaseKind.ssk, after: 1),
          reason: 'an edit keeps what it opened with');
    });

    testWidgets('shaping: decrease on chosen needle groups until a count remains', (tester) async {
      final r = await _open(tester, KnitStepKind.shape);
      await tester.enterText(find.byKey(const Key('knit-step-count')), '2');
      await tester.enterText(find.byKey(const Key('knit-step-every')), '0');
      await tester.enterText(find.byKey(const Key('knit-step-target')), '64');
      await _save(tester);
      expect(find.text(_range), findsOneWidget, reason: 'every 0 rows is refused');
      expect(r, isEmpty);
      await tester.enterText(find.byKey(const Key('knit-step-every')), '2');
      await tester.tap(find.text('Until this many stitches remain'));
      await tester.tap(find.byKey(const Key('knit-step-shape-group-sole')));
      await tester.pump();
      await tester.enterText(find.byKey(const Key('knit-step-text')), 'k1, ssk');
      await _save(tester);
      expect(
          r.single,
          const KnitStepActionDto.shape(
              change: -2,
              every: 2,
              until: ShapeUntilDto.remain(count: 64),
              groups: ['sole'],
              text: 'k1, ssk'));
    });

    testWidgets('shaping: an increase a number of times on the whole needle', (tester) async {
      final r = await _open(tester, KnitStepKind.shape, pattern: _noSteps());
      expect(
          find.text('No needle groups yet: the shaping is on the whole needle.'), findsOneWidget);
      await tester.tap(find.text('Increase'));
      await tester.enterText(find.byKey(const Key('knit-step-count')), '1');
      await tester.enterText(find.byKey(const Key('knit-step-every')), '4');
      await tester.enterText(find.byKey(const Key('knit-step-target')), '6');
      await _save(tester);
      expect(
          r.single,
          const KnitStepActionDto.shape(
              change: 1, every: 4, until: ShapeUntilDto.times(count: 6), groups: [], text: ''));
    });

    testWidgets('pick up and knit: along a part worked flat, onto a needle group', (tester) async {
      final r = await _open(tester, KnitStepKind.pickUp);
      expect(find.text('A side of heel flap (Heel flap, step 1)'), findsOneWidget,
          reason: 'the last part worked flat is chosen to start with');
      await tester.enterText(find.byKey(const Key('knit-step-count')), '16');
      await tester.tap(find.byKey(const Key('knit-step-group')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('sole').last);
      await tester.pumpAndSettle();
      await _save(tester);
      expect(
          r.single,
          const KnitStepActionDto.pickUp(
              count: 16, along: PickUpAlongDto.piece(step: 'step-5'), group: 'sole'));
    });

    testWidgets('pick up and knit: another edge needs its words', (tester) async {
      final r = await _open(tester, KnitStepKind.pickUp, pattern: _noSteps());
      await tester.enterText(find.byKey(const Key('knit-step-count')), '60');
      await _save(tester);
      expect(find.text('Say which edge, such as "the cast-on edge".'), findsOneWidget);
      expect(r, isEmpty);
      await tester.enterText(find.byKey(const Key('knit-step-edge')), 'the neck edge');
      await _save(tester);
      expect(
          r.single,
          const KnitStepActionDto.pickUp(
              count: 60, along: PickUpAlongDto.edge(text: 'the neck edge')));
    });

    testWidgets('needle groups: names and counts, more or fewer groups', (tester) async {
      final r = await _open(tester, KnitStepKind.groups);
      expect(find.byKey(const Key('knit-step-group-name-1')), findsOneWidget,
          reason: 'a new step starts with two groups');
      await _save(tester);
      expect(find.text('Give the group a name.'), findsNWidgets(2));
      expect(r, isEmpty);
      await tester.enterText(find.byKey(const Key('knit-step-group-name-0')), 'sole');
      await tester.enterText(find.byKey(const Key('knit-step-group-count-0')), '32');
      await tester.enterText(find.byKey(const Key('knit-step-group-notes-0')), 'needles 1 and 2');
      await tester.enterText(find.byKey(const Key('knit-step-group-name-1')), 'instep');
      await tester.enterText(find.byKey(const Key('knit-step-group-count-1')), '32');
      await tester.tap(find.byKey(const Key('knit-step-group-add')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('knit-step-group-remove-2')));
      await tester.pump();
      await _save(tester);
      expect(
          r.single,
          const KnitStepActionDto.groups(groups: [
            NeedleGroupDto(name: 'sole', count: 32, notes: 'needles 1 and 2'),
            NeedleGroupDto(name: 'instep', count: 32, notes: ''),
          ]));
    });

    testWidgets('graft or close: the method', (tester) async {
      final r = await _open(tester, KnitStepKind.close);
      await tester.tap(find.text('Three-needle bind-off'));
      await tester.pump();
      await _save(tester);
      expect(r, [const KnitStepActionDto.close(method: CloseMethodKind.threeNeedleBindOff)]);
    });
  });

  group('the sock fixtures', () {
    testWidgets('the Sections screen shows rounds, needle groups and how each section is worked',
        (tester) async {
      final p = _sock();
      final repo =
          FakeSectionsRepo(canned: oracleConstruction(p, sectionOracle('sock-heel-flap-round')));
      final container =
          ProviderContainer(overrides: [knitRepositoryProvider.overrideWithValue(repo)]);
      addTearDown(container.dispose);
      container.read(knitEditorProvider.notifier).load(p);
      await tester.binding.setSurfaceSize(const Size(500, 9000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: KnitSectionsScreen()),
      ));
      await tester.pumpAndSettle();

      expect(find.text('3. Heel flap'), findsOneWidget);
      expect(find.textContaining('Worked flat\n'), findsOneWidget, reason: 'with its notes below');
      expect(find.text('Worked in the round'), findsNWidgets(4));
      expect(find.text('Next 50 rnds: knit.'), findsOneWidget);
      expect(find.text('64 sts on the needle: 32 sole, 32 instep; 32 worked flat, 32 resting'),
          findsNWidgets(2));
      expect(
          find.text('Pick up and knit 16 sts along the left side of the heel flap (it has 16 '
              'slipped edge sts on this side), adding them to the sole.'),
          findsOneWidget);
      expect(find.text('0 sts on the needle; 16 grafted'), findsOneWidget);

      // The gusset says nothing; say it is worked in the round, from the section's menu.
      final gusset = find.byKey(const Key('knit-section-4-section-5'));
      await tester.tap(find.descendant(of: gusset, matching: find.byTooltip('Section actions')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Flat or in the round'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('knit-section-construction-inTheRound')));
      await tester.pumpAndSettle();
      expect(container.read(knitEditorProvider).pattern.sections[4].construction,
          ConstructionKind.inTheRound);
      expect(find.textContaining('Worked in the round'), findsNWidgets(5));
      expect(container.read(knitEditorProvider).canUndo, isTrue);
    });

    testWidgets('the add sheet offers the new kinds', (tester) async {
      final repo = FakeSectionsRepo();
      final container =
          ProviderContainer(overrides: [knitRepositoryProvider.overrideWithValue(repo)]);
      addTearDown(container.dispose);
      container.read(knitEditorProvider.notifier).load(_sock());
      await tester.binding.setSurfaceSize(const Size(500, 9000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: KnitSectionsScreen()),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('knit-add-step-6-section-7')));
      await tester.pumpAndSettle();
      for (final k in [
        KnitStepKind.rows,
        KnitStepKind.joinRound,
        KnitStepKind.workFlat,
        KnitStepKind.pickUp,
        KnitStepKind.groups,
        KnitStepKind.shape,
        KnitStepKind.close,
      ]) {
        expect(find.byKey(Key('knit-step-kind-${k.name}')), findsOneWidget, reason: k.name);
      }
      await tester.tap(find.byKey(const Key('knit-step-kind-joinRound')));
      await tester.pumpAndSettle();
      await _save(tester);
      expect(container.read(knitEditorProvider).pattern.sections[6].steps.last.action,
          const KnitStepActionDto.joinRound());
    });

    for (final name in ['sock-heel-flap-round', 'sock-short-row-heel-round']) {
      test('$name prints round labels, needle groups and the grafted toe', () async {
        final repo = OracleRepo(name);
        final source = await gatherKnitPrint(repo,
            name: repo.pattern.name, pattern: repo.pattern, now: DateTime(2026, 11, 15));
        final d = buildKnitPrintDocument(source, withProblemsBox: true);
        final blocks = _section(d, 'Written instructions').blocks;
        final intro = (blocks.first as PrintParagraph).text;
        expect(intro, contains('a rnd is a round'));
        expect(intro, contains('needle groups'));
        final headings = [
          for (final b in blocks)
            if (b case PrintParagraph(:final text, style: PrintTextStyle.strong)) text,
        ];
        expect(headings, contains(contains('(worked in the round)')));
        final labels = [
          for (final b in blocks)
            if (b case PrintLines(:final lines))
              for (final l in lines) l.label,
        ];
        expect(
            labels.whereType<String>().any((l) => RegExp(r'^Next \d+ rnds$').hasMatch(l)), isTrue,
            reason: 'rounds are labelled as rounds');
        final lines = [
          for (final b in blocks)
            if (b case PrintLines(:final lines))
              for (final l in lines) l,
        ];
        expect(lines.any((l) => l.flagged), isFalse, reason: 'every step is counted');
        expect(lines.last.text, endsWith('grafted)'));
      });
    }

    test('the heel flap sock prints as a real PDF', () async {
      final repo = OracleRepo('sock-heel-flap-round');
      final source = await gatherKnitPrint(repo,
          name: repo.pattern.name, pattern: repo.pattern, now: DateTime(2026, 11, 15));
      final pdf = PdfReadBack(await buildPrintPdf(
        buildKnitPrintDocument(source, withProblemsBox: true),
        page: PrintPageSetup.forUnit(MeasureUnit.inches),
        fonts: testFonts(),
        compress: false,
      ));
      for (final s in [
        'Section 3: Heel flap (worked flat)',
        'Next 32 rows (first row RS)',
        'Short row 3 (RS): knit to 1 st before the gap, ssk, k1, turn.',
        'Next 18 rnds: decrease 2 sts on the sole',
        'Graft the 8 sole sts to the 8 instep sts with Kitchener stitch.',
      ]) {
        expect(pdf.text, contains(s));
      }
      expect(pdf.text, isNot(contains('\u2014')), reason: 'no em dashes');
    });

    testWidgets('the written-instructions screen sets apart headings that say how they are worked',
        (tester) async {
      final repo = OracleRepo('sock-short-row-heel-round');
      final container =
          ProviderContainer(overrides: [knitRepositoryProvider.overrideWithValue(repo)]);
      addTearDown(container.dispose);
      container.read(knitEditorProvider.notifier).load(repo.pattern);
      await tester.binding.setSurfaceSize(const Size(600, 6000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: KnitWrittenScreen()),
      ));
      await tester.pumpAndSettle();
      for (final h in ['Section 1: Cuff (worked in the round)', 'Section 3: Heel']) {
        expect(tester.getSemantics(find.text(h)).flagsCollection.isHeader, isTrue, reason: h);
      }
      handle.dispose();
    });
  });
}

/// What the bridge's `write_knit` says when a pattern's sections are too large to save, as the
/// repository passes it on (`ply_bridge::api::write_knit`, tested in Rust).
const _tooLargeToSave = 'a section is too large to save: a step names 101 needle groups; Ply opens '
    'at most 100. Your changes are still here; shorten it and save again';

/// A repository whose engine refuses to write the pattern (sections too large to open again).
class _RefusingRepo extends FakeSavingRepo {
  @override
  Future<String> saveKnit({
    required KnitPatternDto pattern,
    required DraftMeta meta,
    String? id,
  }) async {
    saveCount++;
    throw _tooLargeToSave; // frb throws the Rust `Err(String)` as a String
  }
}

void reviewTests() {
  group('review fixes', () {
    testWidgets('shaping keeps a needle group that no group step sets any more', (tester) async {
      final r = await _open(tester, KnitStepKind.shape,
          initial: const KnitStepActionDto.shape(
              change: -2,
              every: 2,
              until: ShapeUntilDto.remain(count: 64),
              groups: ['gusset', 'sole'],
              text: ''));
      expect(find.text('gusset (not found)'), findsOneWidget);
      await _save(tester);
      expect((r.single! as KnitStepActionDto_Shape).groups, ['gusset', 'sole'],
          reason: 'kept, in the order the step named them');
      final r2 = await _open(tester, KnitStepKind.shape,
          initial: const KnitStepActionDto.shape(
              change: -2,
              every: 2,
              until: ShapeUntilDto.remain(count: 64),
              groups: ['gusset'],
              text: ''));
      await tester.tap(find.text('gusset (not found)'));
      await tester.pump();
      await _save(tester);
      expect((r2.single! as KnitStepActionDto_Shape).groups, isEmpty,
          reason: 'gone only when unticked');
    });

    testWidgets('a pick-up keeps a group and a part worked flat that are no longer there',
        (tester) async {
      final r = await _open(tester, KnitStepKind.pickUp,
          initial: const KnitStepActionDto.pickUp(
              count: 8, along: PickUpAlongDto.piece(step: 'step-99'), group: 'gusset'));
      expect(find.text('gusset (not found)'), findsOneWidget);
      expect(find.text('A part worked flat (not found)'), findsOneWidget);
      expect(find.byKey(const Key('knit-step-edge')), findsNothing);
      await _save(tester);
      expect(
          r.single,
          const KnitStepActionDto.pickUp(
              count: 8, along: PickUpAlongDto.piece(step: 'step-99'), group: 'gusset'));
    });

    testWidgets('removing a group in the middle keeps the others with their own text',
        (tester) async {
      final r = await _open(tester, KnitStepKind.groups);
      await tester.tap(find.byKey(const Key('knit-step-group-add')));
      await tester.pump();
      for (final (i, name, count) in [(0, 'sole', '30'), (1, 'heel', '4'), (2, 'instep', '30')]) {
        await tester.enterText(find.byKey(Key('knit-step-group-name-$i')), name);
        await tester.enterText(find.byKey(Key('knit-step-group-count-$i')), count);
      }
      await tester.tap(find.byKey(const Key('knit-step-group-remove-1')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'no field shows a let-go controller');
      expect(find.byKey(const Key('knit-step-group-name-2')), findsNothing);
      expect(
          tester
              .widget<TextField>(find.byKey(const Key('knit-step-group-name-1')))
              .controller!
              .text,
          'instep');
      await _save(tester);
      expect(
          r.single,
          const KnitStepActionDto.groups(groups: [
            NeedleGroupDto(name: 'sole', count: 30, notes: ''),
            NeedleGroupDto(name: 'instep', count: 30, notes: ''),
          ]));
    });

    testWidgets('texts longer than a pattern file may hold are refused with a plain message',
        (tester) async {
      final r = await _open(tester, KnitStepKind.rows);
      await tester.enterText(find.byKey(const Key('knit-step-count')), '2');
      // 5,001 two-byte letters: 10,002 bytes, as the engine measures, though 5,001 characters.
      await tester.enterText(find.byKey(const Key('knit-step-text')), '\u00e9' * 5001);
      await tester.pump();
      expect(find.text(kKnitTextTooLong), findsOneWidget);
      await _save(tester);
      expect(r, isEmpty, reason: 'not saved, and the text is still there to shorten');
      await tester.enterText(find.byKey(const Key('knit-step-text')), '\u00e9' * 5000);
      await _save(tester);
      expect((r.single! as KnitStepActionDto_Rows).text.length, 5000);
    });

    testWidgets('a groups step stops at 100 groups', (tester) async {
      await _open(tester, KnitStepKind.groups);
      final add = find.byKey(const Key('knit-step-group-add'));
      // The button scrolls out of view as groups are added; press it as the form would.
      for (var i = 2; i < kMaxNeedleGroups; i++) {
        tester.widget<TextButton>(add).onPressed!();
        await tester.pump();
      }
      expect(tester.widget<TextButton>(add).onPressed, isNull);
      expect(find.text('Ply keeps at most 100 needle groups in one step.'), findsOneWidget);
    });

    testWidgets('section notes and names longer than a pattern file may hold stay in the dialog',
        (tester) async {
      String? notes = 'unset';
      String? name = 'unset';
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Column(children: [
            TextButton(
              onPressed: () async =>
                  notes = await showKnitTextDialog(context, title: 'Notes', label: 'Notes'),
              child: const Text('notes'),
            ),
            TextButton(
              onPressed: () async => name = await promptForName(context,
                  title: 'Name',
                  confirmLabel: 'Add',
                  validator: (n) => knitTextTooLong(n) ? kKnitTextTooLong : null),
              child: const Text('name'),
            ),
          ]),
        ),
      ));
      await tester.tap(find.text('notes'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('knit-text-dialog-field')), 'n' * 10001);
      await tester.pump();
      expect(find.text(kKnitTextTooLong), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byKey(const Key('knit-text-dialog-save'))).onPressed,
          isNull);
      await tester.enterText(find.byKey(const Key('knit-text-dialog-field')), 'n' * 10000);
      await tester.pump();
      await tester.tap(find.byKey(const Key('knit-text-dialog-save')));
      await tester.pumpAndSettle();
      expect(notes!.length, 10000);

      await tester.tap(find.text('name'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'n' * 10001);
      await tester.pump();
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      expect(find.text(kKnitTextTooLong), findsOneWidget, reason: 'still open, text kept');
      expect(name, 'unset');
    });

    testWidgets('a save the engine refuses keeps the pattern unsaved and says why', (tester) async {
      final repo = _RefusingRepo();
      final c = await pumpHostedEditor(tester, repo, openId: 'k1');
      editChart(c);
      await tester.pump();
      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();
      expect(repo.saveCount, 1);
      expect(find.textContaining('Your changes are still here; shorten it and save again'),
          findsOneWidget);
      expect(c.read(knitEditorProvider).isDirty, isTrue, reason: 'nothing marked saved');
    });

    testWidgets('moving the start of the round has a form with only an explanation',
        (tester) async {
      final r = await _open(tester, KnitStepKind.roundStart);
      expect(find.textContaining('the round then starts there'), findsOneWidget);
      await _save(tester);
      expect(r, [const KnitStepActionDto.roundStart()]);
    });
  });
}

/// The sock fixture's pattern with no sections.
KnitPatternDto _noSteps() {
  final p = _sock();
  return KnitPatternDto(
    name: p.name,
    construction: p.construction,
    firstRowSide: p.firstRowSide,
    castOn: p.castOn,
    gauge: p.gauge,
    palette: p.palette,
    legend: p.legend,
    chart: p.chart,
    notes: p.notes,
    sections: const [],
  );
}
