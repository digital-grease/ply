// M9-01 (third slice, ADR 0020) device proof: a knitting pattern made in several PIECES through the
// real engine and the real filesystem. A child's mitten is built with the editor's own state edits
// (the hand, its thumb stitches held and cast on over, the top grafted, then the thumb as a second
// piece from the held stitches and stitches picked up along the opening), saved as a `.plyknit`
// (schema version 6), reopened unchanged, and its written instructions, stitch ledger and piece
// summaries come back from the engine exactly as worked out by hand. The Sections screen shows the
// pieces with how each ends and each section's piece. A version-5 file (one piece) still opens as
// one piece, and saving it keeps a one-time `.v5.bak`.
//
//   flutter test integration_test/m9_knit_pieces_test.dart -d emulator-5554

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:ply/src/data/knit_repository.dart';
import 'package:ply/src/models/draft_meta.dart';
import 'package:ply/src/models/native_format.dart';
import 'package:ply/src/rust/frb_generated.dart';
import 'package:ply/src/rust/knit_dto.dart';
import 'package:ply/src/screens/knit_sections_screen.dart';
import 'package:ply/src/state/knit_editor_providers.dart';
import 'package:ply/src/state/knit_editor_state.dart';

/// The written instructions of the mitten below, worked out by hand: 24 sts, 10 rounds of rib and 8
/// plain; knit 1, put 4 on hold (20 on the needle, 19 still to work) and cast 4 on over the gap (24
/// again); 12 more rounds; the top divided into the palm and the back (12 each) and decreased 4 a
/// round (24 - 8 = 16, 4 rounds) to 4 and 4, grafted (8 grafted, the 4 thumb sts still on hold).
/// The thumb: its 4 held sts knitted onto a new needle, 6 picked up along the cast-on edge of the
/// opening (10), joined in the round, 8 rounds, all 10 bound off. Each piece's lines count its own
/// stitches grafted and bound off.
const List<String> _written = [
  'Made in 2 pieces: Hand and Thumb. The cast-on below is for Hand.',
  'Cast on 24 sts. Join to work in the round, being careful not to twist.',
  'Section 1: Hand',
  'Next 10 rnds: k2, p2 rib. (24 sts on the needle)',
  'Next 8 rnds: knit. (24 sts on the needle)',
  'Next rnd: knit 1 st. (24 sts on the needle, 23 still to work in this rnd)',
  'Place the next 4 sts on a holder (thumb). (20 sts on the needle, 19 still to work in this rnd; '
      '4 on hold)',
  'Cast on 4 sts onto the right needle, over the gap left by the stitches on hold (thumb). (24 sts '
      'on the needle, 19 still to work in this rnd; 4 on hold)',
  'Knit to end. (24 sts on the needle; 4 on hold)',
  'Next 12 rnds: knit. (24 sts on the needle; 4 on hold)',
  'Section 2: Top (Hand)',
  'Divide the 24 sts into needle groups, starting at the beginning of the rnd: 12 palm, 12 back. '
      '(24 sts on the needle: 12 palm, 12 back; 4 on hold)',
  'Next 4 rnds: decrease 2 sts on each of the palm and the back in every rnd until 8 sts remain (4 '
      'decrease rnds). (8 sts on the needle: 4 palm, 4 back; 4 on hold)',
  'Graft the 4 palm sts to the 4 back sts with Kitchener stitch. (0 sts on the needle; 4 on hold; 8 '
      'grafted)',
  'Section 3: Thumb',
  'With the RS facing, join the yarn and knit the 4 sts on hold (thumb). (4 sts on the needle)',
  'Pick up and knit 6 sts along the cast-on edge of the thumb opening. (10 sts on the needle)',
  'Join to work in the round, being careful not to twist. (10 sts on the needle)',
  'Next 8 rnds: knit. (10 sts on the needle)',
  'Next rnd: bind off all sts. (0 sts on the needle; 10 bound off)',
];

const KnitStepActionDto _knitToEnd =
    KnitStepActionDto.work(stitch: WorkStitchKind.knit, to: WorkToDto.end(), resolveTurns: false);

Future<KnitPatternDto> _mitten(KnitRepository repo) async {
  var s = KnitEditorState(pattern: await repo.blank())
      .setConstruction(ConstructionKind.inTheRound)
      .setCastOn(24)
      .addSection('Hand')
      .addPiece('Thumb')
      .renamePieceAt(0, 'Hand')
      .addSection('Top')
      .addSection('Thumb');
  s = s
      .setSectionPieceAt(2, s.pattern.pieces[1].id)
      .addStep('section-1', const KnitStepActionDto.rows(count: 10, text: 'k2, p2 rib'))
      .addStep('section-1', const KnitStepActionDto.rows(count: 8, text: 'knit'))
      .addStep(
          'section-1',
          const KnitStepActionDto.work(
              stitch: WorkStitchKind.knit, to: WorkToDto.count(count: 1), resolveTurns: false))
      .addStep('section-1', const KnitStepActionDto.hold(count: 4, name: 'thumb'))
      .addStep('section-1', const KnitStepActionDto.castOn(count: 4))
      .addStep('section-1', _knitToEnd)
      .addStep('section-1', const KnitStepActionDto.rows(count: 12, text: 'knit'))
      .addStep(
          'section-2',
          const KnitStepActionDto.groups(groups: [
            NeedleGroupDto(name: 'palm', count: 12, notes: ''),
            NeedleGroupDto(name: 'back', count: 12, notes: ''),
          ]))
      .addStep(
          'section-2',
          const KnitStepActionDto.shape(
              change: -2,
              every: 1,
              until: ShapeUntilDto.remain(count: 8),
              groups: ['palm', 'back'],
              text: ''))
      .addStep(
          'section-2', const KnitStepActionDto.close(method: CloseMethodKind.graft, holds: []));
  final hold = s.pattern.sections[0].steps[3].id;
  s = s
      .addStep(
          'section-3',
          KnitStepActionDto.join(
              source: JoinSourceDto.held(hold: hold),
              stitch: WorkStitchKind.knit,
              resolveTurns: false))
      .addStep(
          'section-3',
          const KnitStepActionDto.pickUp(
              count: 6, along: PickUpAlongDto.edge(text: 'the cast-on edge of the thumb opening')))
      .addStep('section-3', const KnitStepActionDto.joinRound())
      .addStep('section-3', const KnitStepActionDto.rows(count: 8, text: 'knit'))
      .addStep('section-3', const KnitStepActionDto.bindOff(resolveTurns: false));
  return s.pattern;
}

/// Drag the list until [finder] is on screen (a text shown twice defeats `scrollUntilVisible`).
Future<void> _dragTo(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 40 && finder.evaluate().isEmpty; i++) {
    await tester.drag(find.byType(ListView).first, const Offset(0, -300));
    await tester.pumpAndSettle();
  }
  expect(finder, findsWidgets);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  testWidgets('a mitten and its thumb in two pieces save, reopen and count as worked',
      (tester) async {
    final repo = KnitRepository();
    final pattern = await _mitten(repo);
    final now = DateTime.now();
    final meta = DraftMeta(name: 'knit-pieces', craft: 'Knitting', savedAt: now, lastOpened: now);
    final id = await repo.saveKnit(pattern: pattern, meta: meta);
    addTearDown(() => repo.deleteKnit(id));

    final path = (await repo.openKnit(id)).patternPath;
    final onDisk = File(path).readAsStringSync();
    expect(plyknitSchemaVersion(onDisk), 6);
    final doc = (jsonDecode(onDisk) as Map<String, dynamic>)['document'] as Map<String, dynamic>;
    expect([for (final x in doc['pieces'] as List) x['name']], ['Hand', 'Thumb']);
    expect([for (final s in doc['sections'] as List) s['piece']], [null, null, 'piece-2']);

    final reopened = await repo.readPattern(id);
    expect(await repo.write(reopened), await repo.write(pattern), reason: 'reopened unchanged');
    expect(await repo.written(reopened), _written);

    final c = await repo.construction(reopened);
    expect(c.issues, isEmpty);
    expect(
        [for (final l in c.lines) l.written],
        _written
            .where((l) =>
                !l.startsWith('Made in') &&
                !l.startsWith('Cast on 24') &&
                !l.startsWith('Section '))
            .toList());
    // 7 lines of the hand, 3 of its top, then 5 of the thumb.
    expect([for (final l in c.lines) l.pieceIndex], [for (var i = 0; i < 15; i++) i < 10 ? 0 : 1]);
    final graft = c.lines[9].count!;
    expect((graft.onNeedle, graft.grafted, graft.held.single.count), (0, 8, 4));
    expect(c.holds[graft.held.single.holdIndex].name, 'thumb');
    final thumb = c.lines[10].count!;
    expect(thumb.onNeedle, 4);
    expect(thumb.held, isEmpty, reason: 'the join took the held stitches');
    expect(thumb.setAside, isEmpty, reason: 'the hand has no stitches left');
    expect((thumb.grafted, thumb.graftedTotal), (0, 8), reason: 'the hand grafted them');
    expect([for (final x in c.pieces) x.text],
        ['no stitches left at the end', 'no stitches left at the end']);
    expect([
      for (final x in c.pieces) x.sectionIndices.toList()
    ], [
      [0, 1],
      [2]
    ]);

    // A join that asks for the held stitches again is refused and changes nothing.
    final twice = KnitEditorState(pattern: reopened)
        .addStep(
            'section-3',
            KnitStepActionDto.join(
                source: JoinSourceDto.held(hold: reopened.sections[0].steps[3].id),
                stitch: WorkStitchKind.knit,
                resolveTurns: false))
        .pattern;
    final tc = await repo.construction(twice);
    expect(tc.lines.last.countKind, KnitLineCountKind.notCounted);
    expect(
        tc.issues.map((i) => i.text),
        contains('joins the stitches on hold (thumb), but Thumb, step 1 already took them off the '
            'holder'));

    // The Sections screen: the pieces with how each ends, and each section's piece.
    final container =
        ProviderContainer(overrides: [knitRepositoryProvider.overrideWithValue(repo)]);
    addTearDown(container.dispose);
    container.read(knitEditorProvider.notifier).load(reopened);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: KnitSectionsScreen()),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Pieces'), findsOneWidget);
    expect(find.text('Hand'), findsWidgets);
    expect(find.textContaining('No stitches left at the end'), findsWidgets);
    await _dragTo(tester, find.text('3. Thumb'));
    expect(find.textContaining('Piece: Thumb'), findsOneWidget);
    await _dragTo(
        tester, find.text('With the RS facing, join the yarn and knit the 4 sts on hold (thumb).'));
    expect(find.text('4 sts on the needle'), findsWidgets);
  });

  testWidgets('a version-5 pattern opens as one piece and saves as version 6 with a backup',
      (tester) async {
    final repo = KnitRepository();
    final pattern = KnitEditorState(pattern: await repo.blank())
        .setCastOn(6)
        .addSection('Front')
        .addStep('section-1', _knitToEnd)
        .pattern;
    final now = DateTime.now();
    final meta = DraftMeta(name: 'knit-v5', craft: 'Knitting', savedAt: now, lastOpened: now);
    final id = await repo.saveKnit(pattern: pattern, meta: meta);
    addTearDown(() => repo.deleteKnit(id));
    final path = (await repo.openKnit(id)).patternPath;

    // The same pattern as the version-5 writer stored it: no pieces, no piece on any section.
    final envelope = jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
    final doc = envelope['document'] as Map<String, dynamic>;
    doc.remove('pieces');
    for (final s in doc['sections'] as List) {
      (s as Map<String, dynamic>).remove('piece');
    }
    envelope['schema_version'] = 5;
    final v5 = const JsonEncoder.withIndent('  ').convert(envelope);
    File(path).writeAsStringSync(v5);

    final opened = await repo.readPattern(id);
    expect(opened.pieces, isEmpty, reason: 'one piece, as it was');
    expect(opened.sections.single.piece, isNull);
    expect(File(path).readAsStringSync(), v5, reason: 'opening never rewrites the file');
    expect(await repo.written(opened), [
      'Cast on 6 sts.',
      'Section 1: Front',
      'Next row (RS): knit to end. (6 sts on the needle)',
    ]);

    await repo.saveKnit(pattern: opened, meta: meta, id: id);
    expect(plyknitSchemaVersion(File(path).readAsStringSync()), 6);
    expect(File(KnitRepository.backupPath(path, 5)).readAsStringSync(), v5,
        reason: 'the version-5 original is kept once');
  });
}
