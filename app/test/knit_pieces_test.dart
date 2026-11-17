import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/models/draft_doc.dart' show MeasureUnit;
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

import 'knit_sections_fixture_test.dart' show OracleRepo;
import 'knit_sections_screen_test.dart' show FakeSectionsRepo;
import 'knit_sections_test_support.dart';
import 'print/print_test_support.dart';

// Host coverage for the third slice of knitting sections (ADR 0020: a garment in several pieces):
// adding, renaming, moving and deleting pieces and choosing a section's piece are each one undo
// entry; new ids never take one a section or join still names; the join form returns exactly the
// action it describes; and the mitten and yoke fixtures' hand-derived ledger reaches the Sections
// screen (each piece with how it ends, each section with its piece), the written instructions and
// the PDF. The engine is stood in for by the fixtures' oracles.

KnitPatternDto _fixture(String name) => patternFromPlyknit(sectionFixtureText(name, 'plyknit'));

/// The shoulder fixture (one piece) as a starting point.
KnitPatternDto _onePiece() => _fixture('shoulder-short-rows-flat');

Future<List<KnitStepActionDto?>> _open(WidgetTester tester,
    {required KnitPatternDto pattern,
    KnitStepActionDto? initial,
    int? sectionIndex,
    KnitStepKind kind = KnitStepKind.join}) async {
  final results = <KnitStepActionDto?>[];
  await tester.binding.setSurfaceSize(const Size(400, 2400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => TextButton(
        onPressed: () async => results.add(await showKnitStepDialog(context,
            kind: kind, pattern: pattern, initial: initial, sectionIndex: sectionIndex)),
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

Future<ProviderContainer> _pumpScreen(WidgetTester tester, String fixture) async {
  final p = _fixture(fixture);
  final repo = FakeSectionsRepo(canned: oracleConstruction(p, sectionOracle(fixture)));
  final container = ProviderContainer(overrides: [knitRepositoryProvider.overrideWithValue(repo)]);
  addTearDown(container.dispose);
  container.read(knitEditorProvider.notifier).load(p);
  // Phone width: every card and menu fits in 360 logical pixels.
  await tester.binding.setSurfaceSize(const Size(360, 9000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: const MaterialApp(home: KnitSectionsScreen()),
  ));
  await tester.pumpAndSettle();
  return container;
}

void main() {
  group('state', () {
    test('the first piece added comes with the main piece, which keeps every section', () {
      var s = KnitEditorState(pattern: _onePiece());
      s = s.addPiece('  sleeve ');
      expect([for (final x in s.pattern.pieces) (x.id, x.name)],
          [('piece-1', 'Main piece'), ('piece-2', 'sleeve')]);
      expect(s.pattern.sections.every((x) => x.piece == null), isTrue,
          reason: 'no section names a piece: they work the first');
      expect(s.canUndo, isTrue);
      expect(s.undoEdit().pattern.pieces, isEmpty, reason: 'one undo entry for both');
      s = s.addPiece('collar');
      expect([for (final x in s.pattern.pieces) x.id], ['piece-1', 'piece-2', 'piece-3']);
      expect(identical(s.addPiece('   ').pattern, s.pattern), isTrue, reason: 'no empty names');
    });

    test('rename, move and delete pieces, each one undo entry', () {
      var s = KnitEditorState(pattern: _onePiece()).addPiece('sleeve').addPiece('collar');
      s = s.renamePieceAt(0, 'body');
      expect(s.pattern.pieces.first.name, 'body');
      expect(identical(s.renamePieceAt(0, 'body').pattern, s.pattern), isTrue);
      s = s.movePieceAt(2, -1);
      expect([for (final x in s.pattern.pieces) x.name], ['body', 'collar', 'sleeve']);
      expect(identical(s.movePieceAt(0, -1).pattern, s.pattern), isTrue);
      final before = s.pattern;
      s = s.removePieceAt(1);
      expect([for (final x in s.pattern.pieces) x.name], ['body', 'sleeve']);
      expect(identical(s.undoEdit().pattern, before), isTrue);
    });

    test('a section works a chosen piece, and a new section works the one before it', () {
      var s = KnitEditorState(pattern: _onePiece()).addPiece('sleeve');
      s = s.setSectionPieceAt(1, 'piece-2');
      expect(s.pattern.sections[1].piece, 'piece-2');
      expect(knitSectionPieceIndex(s.pattern, 1), 1);
      expect(knitSectionPieceIndex(s.pattern, 0), 0, reason: 'none named: the first piece');
      expect(identical(s.setSectionPieceAt(1, 'piece-2').pattern, s.pattern), isTrue);
      s = s.addSection('Cuff');
      expect(s.pattern.sections.last.piece, 'piece-2');
      s = s.setSectionPieceAt(0, null);
      expect(s.pattern.sections[0].piece, isNull);
      // A piece the pattern no longer has: the section says so.
      s = s.removePieceAt(1);
      expect(knitSectionPieceIndex(s.pattern, 1), isNull);
    });

    test('new ids skip every id a section or a join still names', () {
      var s = KnitEditorState(pattern: _onePiece()).addPiece('sleeve').addPiece('thumb');
      s = s.setSectionPieceAt(1, 'piece-3');
      s = s.addStepAt(
          0,
          const KnitStepActionDto.join(
              source: JoinSourceDto.piece(piece: 'piece-2'),
              stitch: WorkStitchKind.knit,
              resolveTurns: false));
      s = s.removePieceAt(2).removePieceAt(1);
      expect(nextPieceId(s.pattern), 'piece-4', reason: 'piece-2 and piece-3 are still named');
      s = s.addStepAt(
          0,
          const KnitStepActionDto.join(
              source: JoinSourceDto.held(hold: 'step-40'),
              stitch: WorkStitchKind.knit,
              resolveTurns: false));
      expect(nextStepId(s.pattern), 'step-41', reason: 'step-40 is named by the join');
    });

    test('deleting the first piece keeps its sections on it, so the ledger reports them', () {
      // The mitten: the cuff names no piece, so it works the first piece, Hand.
      final p = _fixture('mitten-thumb-round');
      expect(p.sections[0].piece, isNull);
      var s = KnitEditorState(pattern: p).removePieceAt(0);
      expect([for (final x in s.pattern.pieces) x.name], ['Thumb']);
      expect(s.pattern.sections[0].piece, 'piece-1',
          reason: 'the cuff still names Hand, which is gone: an error, not a quiet move to Thumb');
      expect(knitSectionPieceIndex(s.pattern, 0), isNull);
      expect(s.pattern.sections[3].piece, 'piece-2', reason: 'the thumb is untouched');
      expect(identical(s.undoEdit().pattern, p), isTrue, reason: 'one undo entry');
      // Deleting another piece leaves sections that name none alone.
      s = KnitEditorState(pattern: p).removePieceAt(1);
      expect(s.pattern.sections[0].piece, isNull);
    });

    test('moving another piece to the front keeps the sections on the piece they worked', () {
      final p = _fixture('mitten-thumb-round');
      final s = KnitEditorState(pattern: p).movePieceAt(1, -1);
      expect([for (final x in s.pattern.pieces) x.name], ['Thumb', 'Hand']);
      expect(s.pattern.sections[0].piece, 'piece-1');
      expect(knitSectionPieceIndex(s.pattern, 0), 1, reason: 'still Hand');
      // A move that keeps the first piece first changes no section.
      final y = _fixture('yoke-sweater-round');
      final m = KnitEditorState(pattern: y).movePieceAt(2, -1);
      expect(m.pattern.sections[0].piece, isNull);
    });

    test('a new join starts from another piece than the section works, never itself', () {
      final y = _fixture('yoke-sweater-round');
      // Section 2 works Left sleeve: the first other piece is Body.
      expect(
          defaultKnitStepAction(KnitStepKind.join, y, sectionIndex: 1),
          const KnitStepActionDto.join(
              source: JoinSourceDto.piece(piece: 'piece-1'),
              stitch: WorkStitchKind.knit,
              resolveTurns: false));
      // Section 4 works Body: Left sleeve.
      expect(
          defaultKnitStepAction(KnitStepKind.join, y, sectionIndex: 3),
          const KnitStepActionDto.join(
              source: JoinSourceDto.piece(piece: 'piece-2'),
              stitch: WorkStitchKind.knit,
              resolveTurns: false));
    });

    test('a pattern stops at the piece limit', () {
      var s = KnitEditorState(pattern: _onePiece());
      for (var i = 0; i < kMaxKnitPieces + 5; i++) {
        s = s.addPiece('p$i');
      }
      expect(s.pattern.pieces, hasLength(kMaxKnitPieces));
      expect(knitPieceNameProblem('x' * 200), isNull);
      expect(knitPieceNameProblem('x' * 201), isNotNull);
    });

    test('piece titles, the pieces line and headings with pieces', () {
      final p = _fixture('yoke-sweater-round');
      expect(knitPieceTitle(p, 1), 'Left sleeve');
      expect(knitCapitalized(knitPieceTitle(p, 1)), 'Left sleeve');
      final unnamed = KnitEditorState(pattern: p).renamePieceAt(1, 'x').pattern;
      expect(knitPieceTitle(unnamed, 1), 'x');
      expect(isKnitPiecesLine('Made in 3 pieces: body, left sleeve and right sleeve.'), isTrue);
      expect(isKnitPiecesLine('Made in 1 piece: body.'), isTrue);
      expect(isKnitPiecesLine('Cast on 200 sts.'), isFalse);
      expect(isKnitSectionHeading('Section 4: Joining round and yoke (body, worked in the round)'),
          isTrue);
      expect(knitStepKind(p.sections[3].steps[2].action), KnitStepKind.join);
    });
  });

  group('the join form', () {
    testWidgets('another piece: chosen from the pattern, with the stitch and the turns',
        (tester) async {
      final results = await _open(tester, pattern: _fixture('yoke-sweater-round'), sectionIndex: 1);
      expect(find.text('Join a piece or held stitches'), findsOneWidget);
      await tester.tap(find.byKey(const Key('knit-step-join-piece')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Right sleeve').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('In pattern'));
      await tester.tap(find.byKey(const Key('knit-step-resolve')));
      await tester.pumpAndSettle();
      await _save(tester);
      expect(
          results.single,
          const KnitStepActionDto.join(
              source: JoinSourceDto.piece(piece: 'piece-3'),
              stitch: WorkStitchKind.inPattern,
              resolveTurns: true));
    });

    testWidgets('held stitches: chosen from the hold steps', (tester) async {
      final results = await _open(tester, pattern: _fixture('mitten-thumb-round'));
      await tester.tap(find.text('Held stitches'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('knit-step-join-hold')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('thumb (Hand, step 3)').last);
      await tester.pumpAndSettle();
      await _save(tester);
      expect(
          results.single,
          const KnitStepActionDto.join(
              source: JoinSourceDto.held(hold: 'step-5'),
              stitch: WorkStitchKind.knit,
              resolveTurns: false));
    });

    testWidgets('editing keeps a piece the pattern no longer has until another is chosen',
        (tester) async {
      const gone = KnitStepActionDto.join(
          source: JoinSourceDto.piece(piece: 'piece-9'),
          stitch: WorkStitchKind.purl,
          resolveTurns: false);
      final results = await _open(tester, pattern: _fixture('yoke-sweater-round'), initial: gone);
      expect(find.text('Edit step: Join a piece or held stitches'), findsOneWidget);
      expect(find.text('A piece (not found)'), findsOneWidget);
      await _save(tester);
      expect(results.single, gone);
    });

    testWidgets('the form leaves out the piece the section works', (tester) async {
      await _open(tester, pattern: _fixture('yoke-sweater-round'), sectionIndex: 3);
      await tester.tap(find.byKey(const Key('knit-step-join-piece')));
      await tester.pumpAndSettle();
      expect(find.text('Body'), findsNothing, reason: 'section 4 works Body');
      expect(find.text('Left sleeve'), findsWidgets);
      expect(find.text('Right sleeve'), findsWidgets);
    });

    testWidgets('closing two groups on hold: both chosen, never the same twice', (tester) async {
      final results =
          await _open(tester, pattern: _fixture('yoke-sweater-round'), kind: KnitStepKind.close);
      await tester.tap(find.text('Three-needle bind-off'));
      await tester.tap(find.byKey(const Key('knit-step-close-held')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('knit-step-close-a')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('body left underarm (Joining round and yoke, step 2)').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('knit-step-close-b')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('body left underarm (Joining round and yoke, step 2)').last);
      await tester.pumpAndSettle();
      await _save(tester);
      expect(results, isEmpty, reason: 'the same group twice is not saved');
      expect(find.text('Choose two different groups.'), findsOneWidget);
      await tester.tap(find.byKey(const Key('knit-step-close-b')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('left sleeve underarm (Left sleeve, step 8)').last);
      await tester.pumpAndSettle();
      await _save(tester);
      expect(
          results.single,
          const KnitStepActionDto.close(
              method: CloseMethodKind.threeNeedleBindOff, holds: ['step-21', 'step-11']));
    });

    testWidgets('a pattern of one piece with no holds has nothing to join', (tester) async {
      await _open(tester, pattern: _noHolds(_onePiece()));
      expect(find.text('No step puts stitches on hold yet. Add one first.'), findsOneWidget);
      var save = tester.widget<FilledButton>(find.byKey(const Key('knit-step-save')));
      expect(save.onPressed, isNull);
      await tester.tap(find.text('Another piece'));
      await tester.pumpAndSettle();
      expect(find.textContaining('This pattern is one piece.'), findsOneWidget);
      save = tester.widget<FilledButton>(find.byKey(const Key('knit-step-save')));
      expect(save.onPressed, isNull);
    });
  });

  group('the Sections screen', () {
    testWidgets('a pattern of one piece offers to add one', (tester) async {
      final p = _onePiece();
      final repo = FakeSectionsRepo();
      final c = ProviderContainer(overrides: [knitRepositoryProvider.overrideWithValue(repo)]);
      addTearDown(c.dispose);
      c.read(knitEditorProvider.notifier).load(p);
      await tester.binding.setSurfaceSize(const Size(360, 6000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(UncontrolledProviderScope(
          container: c, child: const MaterialApp(home: KnitSectionsScreen())));
      await tester.pumpAndSettle();
      expect(find.textContaining('Every section works one piece.'), findsOneWidget);
      await tester.tap(find.byKey(const Key('knit-add-piece')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'sleeve');
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      expect([for (final x in c.read(knitEditorProvider).pattern.pieces) x.name],
          ['Main piece', 'sleeve']);
      expect(find.text('Main piece'), findsOneWidget);
      expect(find.text('Sleeve'), findsOneWidget);
      expect(find.textContaining('Piece: Main piece'), findsNWidgets(p.sections.length));
    });

    testWidgets('the yoke: each piece says how it ends, each section names its piece',
        (tester) async {
      await _pumpScreen(tester, 'yoke-sweater-round');
      final card = find.byKey(const Key('knit-pieces'));
      expect(find.descendant(of: card, matching: find.text('Body')), findsOneWidget);
      expect(
          find.descendant(
              of: card,
              matching: find.text('No stitches left at the end\nSections 1, 4, 5 and 6\n'
                  'The cast-on is for this piece')),
          findsOneWidget);
      expect(
          find.descendant(
              of: card,
              matching: find.text('Joined to Body at Joining round and yoke, step 3\n'
                  'Section 2')),
          findsOneWidget);
      expect(find.textContaining('Piece: Left sleeve'), findsOneWidget);
      expect(find.text('Piece: Body\nWorked in the round\nThe round starts at the center back.'),
          findsOneWidget);
      // The join's line and its count, with the pieces set aside.
      expect(
          find.text('Knit across the 54 sts of Left sleeve, joining it to Body, over the gap left '
              'by the stitches on hold (body left underarm).'),
          findsOneWidget);
      expect(
          find.text('244 sts on the needle, 145 still to work in this rnd; on hold: left sleeve '
              'underarm 10, right sleeve underarm 10, body left underarm 10; set aside: Right '
              'sleeve 54'),
          findsOneWidget);
    });

    testWidgets('a section menu chooses its piece; deleting a piece can be undone', (tester) async {
      final c = await _pumpScreen(tester, 'mitten-thumb-round');
      final thumbSection = find.byKey(const Key('knit-section-3-section-4'));
      await tester.tap(
          find.descendant(of: thumbSection, matching: find.byTooltip('Section actions')).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Piece').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('knit-section-piece-0')));
      await tester.pumpAndSettle();
      expect(c.read(knitEditorProvider).pattern.sections[3].piece, 'piece-1');

      final thumbPiece = find.byKey(const Key('knit-piece-1-piece-2'));
      await tester
          .tap(find.descendant(of: thumbPiece, matching: find.byTooltip('Piece actions: Thumb')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete piece'));
      await tester.pumpAndSettle();
      expect(c.read(knitEditorProvider).pattern.pieces, hasLength(1));
      expect(find.text('Deleted the piece Thumb.'), findsOneWidget);
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(c.read(knitEditorProvider).pattern.pieces, hasLength(2));
    });
  });

  testWidgets('the piece chooser tells screen readers which piece is chosen', (tester) async {
    final handle = tester.ensureSemantics();
    await _pumpScreen(tester, 'mitten-thumb-round');
    final thumbSection = find.byKey(const Key('knit-section-3-section-4'));
    await tester
        .tap(find.descendant(of: thumbSection, matching: find.byTooltip('Section actions')).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Piece').last);
    await tester.pumpAndSettle();
    expect(
        tester.getSemantics(find.byKey(const Key('knit-section-piece-1'))),
        matchesSemantics(
            hasSelectedState: true,
            isSelected: true,
            isButton: true,
            isInMutuallyExclusiveGroup: true,
            hasTapAction: true,
            hasFocusAction: true,
            isFocusable: true,
            label: 'Thumb'));
    expect(
        tester.getSemantics(find.byKey(const Key('knit-section-piece-0'))),
        matchesSemantics(
            hasSelectedState: true,
            isButton: true,
            isInMutuallyExclusiveGroup: true,
            hasTapAction: true,
            hasFocusAction: true,
            isFocusable: true,
            label: 'Hand'));
    handle.dispose();
  });

  group('written instructions and the PDF', () {
    testWidgets('the written-instructions screen sets each piece heading apart', (tester) async {
      final repo = OracleRepo('mitten-thumb-round');
      final c = ProviderContainer(overrides: [knitRepositoryProvider.overrideWithValue(repo)]);
      addTearDown(c.dispose);
      c.read(knitEditorProvider.notifier).load(repo.pattern);
      await tester.binding.setSurfaceSize(const Size(360, 9000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(UncontrolledProviderScope(
          container: c, child: const MaterialApp(home: KnitWrittenScreen())));
      await tester.pumpAndSettle();
      expect(find.text('Made in 2 pieces: Hand and Thumb. The cast-on below is for Hand.'),
          findsOneWidget);
      final heading = find.text('Section 1: Cuff (Hand, worked in the round)');
      expect(heading, findsOneWidget);
      expect(
          find.ancestor(
              of: heading,
              matching:
                  find.byWidgetPredicate((w) => w is Semantics && (w.properties.header ?? false))),
          findsWidgets);
    });

    test('the yoke prints its pieces, the set-aside counts and the joins', () async {
      final repo = OracleRepo('yoke-sweater-round');
      final source = await gatherKnitPrint(repo,
          name: repo.pattern.name, pattern: repo.pattern, now: DateTime(2026, 11, 16));
      final d = buildKnitPrintDocument(source, withProblemsBox: true);
      final facts = d.sections
          .firstWhere((s) => s.heading == 'Materials and gauge')
          .blocks
          .whereType<PrintFacts>()
          .single
          .facts;
      expect(
          facts.firstWhere((f) => f.label == 'Pieces').value,
          'Body (the cast-on): no stitches left at the end; Left sleeve: joined to Body at '
          'Joining round and yoke, step 3; Right sleeve: joined to Body at Joining round and '
          'yoke, step 6');
      final intro = (d.sections.firstWhere((s) => s.heading == 'Written instructions').blocks.first
              as PrintParagraph)
          .text;
      expect(intro, contains('"set aside" counts the stitches of the other pieces'));
      final pdf = PdfReadBack(await buildPrintPdf(d,
          page: PrintPageSetup.forUnit(MeasureUnit.inches), fonts: testFonts(), compress: false));
      for (final s in [
        'Made in 3 pieces: Body, Left sleeve and Right sleeve.',
        'Section 4: Joining round and yoke (Body, worked in the round)',
        'Knit across the 54 sts of Left sleeve, joining it to Body',
        'set aside: Body 200',
      ]) {
        expect(pdf.text, contains(s));
      }
      expect(pdf.text, isNot(contains('\u2014')), reason: 'no em dashes');
    });
  });
}

/// [p] without its hold steps (a pattern with nothing on hold).
KnitPatternDto _noHolds(KnitPatternDto p) {
  var s = KnitEditorState(pattern: p);
  for (var si = s.pattern.sections.length - 1; si >= 0; si--) {
    for (var ti = s.pattern.sections[si].steps.length - 1; ti >= 0; ti--) {
      if (s.pattern.sections[si].steps[ti].action is KnitStepActionDto_Hold) {
        s = s.removeStepAt(si, ti);
      }
    }
  }
  return s.pattern;
}
