// M9-01 device proof: knitting patterns with SECTIONS through the real engine and the real
// filesystem. Each pattern is built with the editor's own state edits, saved as a `.plyknit` (schema
// version 6), listed, reopened unchanged, and its written instructions and stitch ledger come back
// from the engine exactly as worked out by hand. A flat shoulder: the short rows count the stitches
// waiting past each turn, the resolving row works every wrap, and the held stitches are counted on
// hold. A sock in the round: the heel flap over the sole stitches while the instep rests, the heel
// turned with short rows that decrease at the gap, the gusset picked up along both sides of the flap
// and decreased, the toe decreased on both needle groups and grafted. The Sections screen shows the
// same words and counts. A version-3 file (no sections) still opens, with no sections, and saving it
// keeps a one-time `.v3.bak`.
//
//   flutter test integration_test/m9_knit_sections_test.dart -d emulator-5554

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:ply/src/data/knit_repository.dart';
import 'package:ply/src/models/draft_meta.dart';
import 'package:ply/src/models/native_format.dart';
import 'package:ply/src/rust/dto.dart' show SeverityKind;
import 'package:ply/src/rust/frb_generated.dart';
import 'package:ply/src/rust/knit_dto.dart';
import 'package:ply/src/screens/knit_sections_screen.dart';
import 'package:ply/src/state/knit_editor_providers.dart';
import 'package:ply/src/state/knit_editor_state.dart';

KnitStepActionDto _wrapTurn(int last) => KnitStepActionDto.shortRow(
      stitch: WorkStitchKind.knit,
      to: TurnAtDto.last(count: last),
      method: TurnMethodKind.wrapAndTurn,
      resolveTurns: false,
    );

const KnitStepActionDto _purlToEnd =
    KnitStepActionDto.work(stitch: WorkStitchKind.purl, to: WorkToDto.end(), resolveTurns: false);

/// The written instructions of the shoulder below, worked out by hand (the same construction as
/// fixtures/knitting/sections/shoulder-short-rows-flat, without its unchecked length step).
const List<String> _expectedWritten = [
  'Cast on 24 sts.',
  'Section 1: Body',
  'Row 1 (RS): k24 (24 sts on the needle)',
  'Row 2 (WS): p24 (24 sts on the needle)',
  'Section 2: Shoulder',
  'Short row 1 (RS): knit to last 6 sts, wrap and turn. (24 sts on the needle, 6 waiting past a turn)',
  'Short row 2 (WS): purl to end. (24 sts on the needle, 6 waiting past a turn)',
  'Short row 3 (RS): knit to last 12 sts, wrap and turn. (24 sts on the needle, 12 waiting past a turn)',
  'Short row 4 (WS): purl to end. (24 sts on the needle, 12 waiting past a turn)',
  'Short row 5 (RS): knit to last 18 sts, wrap and turn. (24 sts on the needle, 18 waiting past a turn)',
  'Short row 6 (WS): purl to end. (24 sts on the needle, 18 waiting past a turn)',
  'Next row (RS): knit to end, working each wrap together with its stitch. (24 sts on the needle)',
  'Place all 24 sts on a holder (shoulder). (0 sts on the needle; 24 on hold)',
];

/// The written instructions of the sock below, worked out by hand: a 32-stitch child's sock with a
/// 16-row heel flap (8 slipped edge stitches on each side), a heel turn from 16 to 10 stitches, 8
/// stitches picked up along each side (42), the start of the round moved to the center of the heel,
/// gusset decreases back to 32 ((42 - 32) / 2 = 5), and a
/// toe decreased 4 stitches a round to 16 (4 times, every other round) and to 8 (2 times), grafted.
const List<String> _sockWritten = [
  'Cast on 32 sts. Join to work in the round, being careful not to twist.',
  'Section 1: Leg (worked in the round)',
  'Next 20 rnds: knit. (32 sts on the needle)',
  'Divide the 32 sts into needle groups, starting at the beginning of the rnd: 16 sole, 16 instep. '
      '(32 sts on the needle: 16 sole, 16 instep)',
  'Section 2: Heel flap (worked flat)',
  'Work back and forth over the next 16 sts for the heel flap, slipping the first st of every row; '
      'the other 16 sts rest on the needle. (32 sts on the needle: 16 sole, 16 instep; 16 worked '
      'flat, 16 resting)',
  'Next 16 rows (first row RS): on RS rows, *sl 1, k1; rep from * to end; on WS rows, sl 1, p to '
      'end. (32 sts on the needle: 16 sole, 16 instep; 16 worked flat, 16 resting)',
  'Section 3: Heel turn (worked flat)',
  'Short row 1 (RS): knit 9 sts, ssk, k1, turn. (31 sts on the needle: 15 sole, 16 instep; 15 '
      'worked flat, 16 resting; 4 waiting past a turn)',
  'Short row 2 (WS): purl 4 sts, p2tog, p1, turn. (30 sts on the needle: 14 sole, 16 instep; 14 '
      'worked flat, 16 resting; 8 waiting past a turn)',
  'Short row 3 (RS): knit to 1 st before the gap, ssk, k1, turn. (29 sts on the needle: 13 sole, '
      '16 instep; 13 worked flat, 16 resting; 6 waiting past a turn)',
  'Short row 4 (WS): purl to 1 st before the gap, p2tog, p1, turn. (28 sts on the needle: 12 sole, '
      '16 instep; 12 worked flat, 16 resting; 4 waiting past a turn)',
  'Short row 5 (RS): knit to 1 st before the gap, ssk, k1, turn. (27 sts on the needle: 11 sole, '
      '16 instep; 11 worked flat, 16 resting; 2 waiting past a turn)',
  'Short row 6 (WS): purl to 1 st before the gap, p2tog, p1, turn. (26 sts on the needle: 10 sole, '
      '16 instep; 10 worked flat, 16 resting)',
  'Section 4: Gusset',
  'Next row (RS): knit to end. (26 sts on the needle: 10 sole, 16 instep; 10 worked flat, 16 '
      'resting)',
  'Pick up and knit 8 sts along the left side of the heel flap (it has 8 slipped edge sts on this '
      'side), adding them to the sole. (34 sts on the needle: 18 sole, 16 instep; 18 worked flat, 16 '
      'resting)',
  'Join to work in the round again over all 34 sts. (34 sts on the needle: 18 sole, 16 instep; 16 '
      'still to work in this rnd)',
  'Knit to end. (34 sts on the needle: 18 sole, 16 instep)',
  'Pick up and knit 8 sts along the right side of the heel flap (it has 8 slipped edge sts on this '
      'side), adding them to the sole. (42 sts on the needle: 26 sole, 16 instep)',
  'Next rnd: knit 5 sts. (42 sts on the needle: 26 sole, 16 instep; 37 still to work in this rnd)',
  'The rnd now starts here (move the marker for the start of the rnd). (42 sts on the needle: 26 '
      'sole, 16 instep)',
  'Next 10 rnds: decrease 2 sts on the sole in the first rnd and then every other rnd until 32 sts '
      'remain (5 decrease rnds). (32 sts on the needle: 16 sole, 16 instep)',
  'Section 5: Toe (worked in the round)',
  'Next 8 rnds: decrease 2 sts on each of the sole and the instep in the first rnd and then every '
      'other rnd until 16 sts remain (4 decrease rnds). (16 sts on the needle: 8 sole, 8 instep)',
  'Next 2 rnds: decrease 2 sts on each of the sole and the instep in every rnd until 8 sts remain '
      '(2 decrease rnds). (8 sts on the needle: 4 sole, 4 instep)',
  'Graft the 4 sole sts to the 4 instep sts with Kitchener stitch. (0 sts on the needle; 8 '
      'grafted)',
];

const _ssk1 = TurnDecreaseDto(kind: DecreaseKind.ssk, after: 1);
const _p2tog1 = TurnDecreaseDto(kind: DecreaseKind.p2Tog, after: 1);

KnitStepActionDto _turnRow(WorkStitchKind stitch, TurnAtDto to, TurnDecreaseDto dec) =>
    KnitStepActionDto.shortRow(
        stitch: stitch,
        to: to,
        method: TurnMethodKind.unspecified,
        resolveTurns: false,
        decrease: dec);

KnitStepActionDto _toe(int every, int remain) => KnitStepActionDto.shape(
    change: -2,
    every: every,
    until: ShapeUntilDto.remain(count: remain),
    groups: const ['sole', 'instep'],
    text: '');

Future<KnitPatternDto> _sock(KnitRepository repo) async {
  var s = KnitEditorState(pattern: await repo.blank())
      .setConstruction(ConstructionKind.inTheRound)
      .setCastOn(32);
  for (final name in ['Leg', 'Heel flap', 'Heel turn', 'Gusset', 'Toe']) {
    s = s.addSection(name);
  }
  s = s
      .setSectionConstructionAt(0, ConstructionKind.inTheRound)
      .setSectionConstructionAt(1, ConstructionKind.flat)
      .setSectionConstructionAt(2, ConstructionKind.flat)
      .setSectionConstructionAt(4, ConstructionKind.inTheRound)
      .addStep('section-1', const KnitStepActionDto.rows(count: 20, text: 'knit'))
      .addStep(
          'section-1',
          const KnitStepActionDto.groups(groups: [
            NeedleGroupDto(name: 'sole', count: 16, notes: ''),
            NeedleGroupDto(name: 'instep', count: 16, notes: ''),
          ]))
      .addStep('section-2',
          const KnitStepActionDto.workFlat(count: 16, name: 'heel flap', slipEdges: true))
      .addStep(
          'section-2',
          const KnitStepActionDto.rows(
              count: 16,
              text: 'on RS rows, *sl 1, k1; rep from * to end; on WS rows, sl 1, p to end'))
      .addStep('section-3', _turnRow(WorkStitchKind.knit, const TurnAtDto.count(count: 9), _ssk1))
      .addStep(
          'section-3', _turnRow(WorkStitchKind.purl, const TurnAtDto.count(count: 4), _p2tog1));
  for (var i = 0; i < 2; i++) {
    s = s
        .addStep(
            'section-3', _turnRow(WorkStitchKind.knit, const TurnAtDto.beforeGap(count: 1), _ssk1))
        .addStep('section-3',
            _turnRow(WorkStitchKind.purl, const TurnAtDto.beforeGap(count: 1), _p2tog1));
  }
  final flap = s.pattern.sections[1].steps.first.id;
  final pickUp =
      KnitStepActionDto.pickUp(count: 8, along: PickUpAlongDto.piece(step: flap), group: 'sole');
  s = s
      .addStep(
          'section-4',
          const KnitStepActionDto.work(
              stitch: WorkStitchKind.knit, to: WorkToDto.end(), resolveTurns: false))
      .addStep('section-4', pickUp)
      .addStep('section-4', const KnitStepActionDto.joinRound())
      .addStep(
          'section-4',
          const KnitStepActionDto.work(
              stitch: WorkStitchKind.knit, to: WorkToDto.end(), resolveTurns: false))
      .addStep('section-4', pickUp)
      // To the center of the heel (10 heel sts): the round starts there from now on.
      .addStep(
          'section-4',
          const KnitStepActionDto.work(
              stitch: WorkStitchKind.knit, to: WorkToDto.count(count: 5), resolveTurns: false))
      .addStep('section-4', const KnitStepActionDto.roundStart())
      .addStep(
          'section-4',
          const KnitStepActionDto.shape(
              change: -2,
              every: 2,
              until: ShapeUntilDto.remain(count: 32),
              groups: ['sole'],
              text: ''))
      .addStep('section-5', _toe(2, 16))
      .addStep('section-5', _toe(1, 8))
      .addStep(
          'section-5', const KnitStepActionDto.close(method: CloseMethodKind.graft, holds: []));
  return s.pattern;
}

Future<KnitPatternDto> _shoulder(KnitRepository repo) async {
  var s = KnitEditorState(pattern: await repo.blank()).resizeChart(24, 2).setCastOn(24);
  s = s.addSection('Body').addSection('Shoulder');
  s = s.addStep('section-1', const KnitStepActionDto.chartRows(first: 1, last: 2));
  for (final last in [6, 12, 18]) {
    s = s.addStep('section-2', _wrapTurn(last)).addStep('section-2', _purlToEnd);
  }
  s = s
      .addStep(
          'section-2',
          const KnitStepActionDto.work(
              stitch: WorkStitchKind.knit, to: WorkToDto.end(), resolveTurns: true))
      .addStep('section-2', const KnitStepActionDto.hold(name: 'shoulder'));
  return s.pattern;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  testWidgets('a pattern with short rows and held stitches saves, reopens and counts as worked',
      (tester) async {
    final repo = KnitRepository();
    final pattern = await _shoulder(repo);
    final now = DateTime.now();
    final meta = DraftMeta(name: 'knit-sections', craft: 'Knitting', savedAt: now, lastOpened: now);
    final id = await repo.saveKnit(pattern: pattern, meta: meta);
    addTearDown(() => repo.deleteKnit(id));

    expect((await repo.listKnits()).map((e) => e.id), contains(id));
    final path = (await repo.openKnit(id)).patternPath;
    final onDisk = File(path).readAsStringSync();
    expect(plyknitSchemaVersion(onDisk), 6);
    final doc = (jsonDecode(onDisk) as Map<String, dynamic>)['document'] as Map<String, dynamic>;
    expect([for (final s in doc['sections'] as List) s['name']], ['Body', 'Shoulder']);

    // Reopened unchanged: the same sections, step ids and actions (compared as the engine writes
    // them, which covers every field).
    final reopened = await repo.readPattern(id);
    expect([for (final s in reopened.sections) s.id], ['section-1', 'section-2']);
    expect([for (final st in reopened.sections[1].steps) st.id].first, 'step-2');
    expect(reopened.sections[1].steps.last.action, const KnitStepActionDto.hold(name: 'shoulder'));
    expect(await repo.write(reopened), await repo.write(pattern));

    // The written instructions and the ledger, through the real engine.
    expect(await repo.written(reopened), _expectedWritten);
    final c = await repo.construction(reopened);
    expect(
        [for (final l in c.lines) l.written],
        _expectedWritten.where((l) {
          return !l.startsWith('Cast on') && !l.startsWith('Section ');
        }).toList());
    final third = c.lines[4].count!; // short row 3
    expect((third.onNeedle, third.toWork, third.pastTurns, third.pendingTurns), (24, 12, 12, 2));
    expect(third.side, SideKind.ws, reason: 'the row after the turn is a WS row');
    final last = c.lines.last.count!;
    expect((last.onNeedle, c.holds[last.held.single.holdIndex].name, last.held.single.count),
        (0, 'shoulder', 24));
    expect(c.issues, hasLength(1));
    expect(c.issues.single.severity, SeverityKind.warning);
    expect((c.issues.single.sectionIndex, c.issues.single.stepIndex),
        (1, reopened.sections[1].steps.length - 1));
    expect(
        c.issues.single.text,
        '24 stitches are still on hold (shoulder) at the end of the pattern; no step returns them '
        'to the needle');
    final issues = await repo.validate(reopened);
    expect(issues.map((i) => i.message), [c.issues.single.message],
        reason: 'the validation band shows the same problem');

    // An impossible step is named in plain words and changes nothing.
    final broken = KnitEditorState(pattern: reopened)
        .addStep('section-2', const KnitStepActionDto.bindOff(count: 30, resolveTurns: false))
        .pattern;
    final bc = await repo.construction(broken);
    expect(bc.lines.last.countKind, KnitLineCountKind.notCounted);
    expect(
        bc.issues.map((i) => i.text),
        contains('there are no stitches on the needle; cast on first (in the pattern settings or '
            'with a cast-on step)'));

    // The Sections screen shows the engine's words and counts.
    final container =
        ProviderContainer(overrides: [knitRepositoryProvider.overrideWithValue(repo)]);
    addTearDown(container.dispose);
    container.read(knitEditorProvider.notifier).load(reopened);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: KnitSectionsScreen()),
    ));
    await tester.pumpAndSettle();
    expect(find.text('1. Body'), findsOneWidget);
    expect(find.text('Short row 1 (RS): knit to last 6 sts, wrap and turn.'), findsOneWidget);
    expect(find.text('24 sts on the needle, 6 waiting past a turn'), findsWidgets);
  });

  testWidgets('a sock with a heel flap, gusset and grafted toe saves, reopens and counts as worked',
      (tester) async {
    final repo = KnitRepository();
    final pattern = await _sock(repo);
    final now = DateTime.now();
    final meta = DraftMeta(name: 'knit-sock', craft: 'Knitting', savedAt: now, lastOpened: now);
    final id = await repo.saveKnit(pattern: pattern, meta: meta);
    addTearDown(() => repo.deleteKnit(id));

    final path = (await repo.openKnit(id)).patternPath;
    final onDisk = File(path).readAsStringSync();
    expect(plyknitSchemaVersion(onDisk), 6);
    final doc = (jsonDecode(onDisk) as Map<String, dynamic>)['document'] as Map<String, dynamic>;
    expect([for (final s in doc['sections'] as List) s['construction']],
        ['InTheRound', 'Flat', 'Flat', null, 'InTheRound']);

    final reopened = await repo.readPattern(id);
    expect(await repo.write(reopened), await repo.write(pattern), reason: 'reopened unchanged');
    expect(await repo.written(reopened), _sockWritten);

    final c = await repo.construction(reopened);
    expect(c.issues, isEmpty);
    expect([for (final l in c.lines) l.written],
        _sockWritten.where((l) => !l.startsWith('Cast on') && !l.startsWith('Section ')).toList());
    final flapRows = c.lines[3].count!;
    expect((flapRows.onNeedle, flapRows.flat, flapRows.inRound), (32, 16, false));
    final joined = c.lines.firstWhere((l) => l.text.startsWith('Join to work')).count!;
    expect((joined.inRound, joined.toWork, joined.midRow), (true, 16, true));
    final gusset = c.lines[14].count!; // after both pick-ups
    expect([for (final g in gusset.groups) (c.groupNames[g.nameIndex], g.count)],
        [('sole', 26), ('instep', 16)]);
    final last = c.lines.last.count!;
    expect((last.onNeedle, last.grafted), (0, 8));
    expect(await repo.validate(reopened), isEmpty);

    // A shaping step that cannot reach its count in whole repeats is named and changes nothing.
    final broken = KnitEditorState(pattern: reopened)
        .addStep(
            'section-4',
            const KnitStepActionDto.shape(
                change: -2,
                every: 2,
                until: ShapeUntilDto.remain(count: 31),
                groups: ['sole'],
                text: ''))
        .pattern;
    final bc = await repo.construction(broken);
    expect(
        bc.issues.map((i) => i.text),
        contains(
            'decreases 2 stitches at a time, which cannot reach 31 from 32: it goes from 32 to 30'));

    // The Sections screen shows the engine's words and counts.
    final container =
        ProviderContainer(overrides: [knitRepositoryProvider.overrideWithValue(repo)]);
    addTearDown(container.dispose);
    container.read(knitEditorProvider.notifier).load(reopened);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: KnitSectionsScreen()),
    ));
    await tester.pumpAndSettle();
    expect(find.text('1. Leg'), findsOneWidget);
    // The count shows on two steps (after the second pick-up and after the start of the round
    // moves), so scroll the lazily built list until it is built at all, rather than to one match.
    final count = find.text('42 sts on the needle: 26 sole, 16 instep');
    for (var i = 0; i < 60 && count.evaluate().isEmpty; i++) {
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -300));
      await tester.pumpAndSettle();
    }
    expect(count, findsWidgets,
        reason: 'after the second pick-up (and after the start of the round moves)');
  });

  testWidgets('a version-3 pattern opens with no sections and saves as the current version',
      (tester) async {
    final repo = KnitRepository();
    final pattern = KnitEditorState(pattern: await repo.blank()).resizeChart(4, 2).pattern;
    final now = DateTime.now();
    final meta = DraftMeta(name: 'knit-v3', craft: 'Knitting', savedAt: now, lastOpened: now);
    final id = await repo.saveKnit(pattern: pattern, meta: meta);
    addTearDown(() => repo.deleteKnit(id));
    final path = (await repo.openKnit(id)).patternPath;

    // The same pattern as the version-3 writer stored it: no sections key.
    final envelope = jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
    (envelope['document'] as Map<String, dynamic>).remove('sections');
    envelope['schema_version'] = 3;
    final v3 = const JsonEncoder.withIndent('  ').convert(envelope);
    File(path).writeAsStringSync(v3);

    final opened = await repo.readPattern(id);
    expect(opened.sections, isEmpty, reason: 'the migration never invents sections');
    expect(File(path).readAsStringSync(), v3, reason: 'opening never rewrites the file');
    expect((await repo.written(opened)).first, 'Row 1 (RS): k4',
        reason: 'a chart-only pattern is written row by row, as before');

    final edited = KnitEditorState(pattern: opened).addSection('Body').pattern;
    await repo.saveKnit(pattern: edited, meta: meta, id: id);
    expect(plyknitSchemaVersion(File(path).readAsStringSync()), 6);
    expect(File(KnitRepository.backupPath(path, 3)).readAsStringSync(), v3,
        reason: 'the version-3 original is kept once');
    expect((await repo.readPattern(id)).sections.single.name, 'Body');
  });
}
