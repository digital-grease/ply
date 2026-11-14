// M9-01 device proof: a knitting pattern with SECTIONS (flat short rows and held stitches) through
// the real engine and the real filesystem. The pattern is built with the editor's own state edits,
// saved as a `.plyknit` (schema version 4), listed, reopened unchanged, and its written instructions
// and stitch ledger come back from the engine exactly as worked out by hand: the short rows count
// the stitches waiting past each turn, the resolving row works every wrap, and the held stitches
// are counted on hold. The Sections screen shows the same words and counts. A version-3 file (no
// sections) still opens, with no sections, and saving it keeps a one-time `.v3.bak`.
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
    expect(plyknitSchemaVersion(onDisk), 4);
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
    expect((last.onNeedle, last.held.single.name, last.held.single.count), (0, 'shoulder', 24));
    expect(c.issues, hasLength(1));
    expect(c.issues.single.severity, SeverityKind.warning);
    expect(c.issues.single.stepId, reopened.sections[1].steps.last.id);
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

  testWidgets('a version-3 pattern opens with no sections and saves as version 4', (tester) async {
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
    expect(plyknitSchemaVersion(File(path).readAsStringSync()), 4);
    expect(File(KnitRepository.backupPath(path, 3)).readAsStringSync(), v3,
        reason: 'the version-3 original is kept once');
    expect((await repo.readPattern(id)).sections.single.name, 'Body');
  });
}
