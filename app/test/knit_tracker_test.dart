import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/library_backup.dart' show BackupCraft;
import 'package:ply/src/data/progress_repository.dart';
import 'package:ply/src/models/progress.dart';
import 'package:ply/src/rust/dto.dart' show UnitKind;
import 'package:ply/src/rust/knit_dto.dart';
import 'package:ply/src/rust/progress_dto.dart';
import 'package:ply/src/screens/knit_tracker_screen.dart';

import 'progress_test_support.dart';

// Knitting row by row (ADR 0023) on the host, with the engine's work calls stood in: a pattern with
// sections is worked step by step with a row counter inside a step that works several rows (and its
// shaping rows named), each change kept at once with the step's ids and resumed in a new session; a
// chart-only pattern is worked again and again, counting the times; a step that moved is offered,
// never applied; and the last step says so. Every change of place writes the tracker's words with
// the place, as the label a library tile shows (ADR 0023, follow-up 6).

const id = '3c9e5a7b-1111-4222-8333-944455556666';

/// When a record written for a test last changed.
final saved = DateTime.utc(2026, 11, 18, 9);

const pattern = KnitPatternDto(
  name: 'Sock',
  construction: ConstructionKind.flat,
  firstRowSide: SideKind.rs,
  gauge: GaugeDto(sts: 18, rows: 24, unit: UnitKind.inches),
  palette: [],
  legend: StitchLegendDto(stitches: []),
  chart: ChartDto(width: 0, rows: []),
  notes: '',
  sections: [],
  pieces: [],
);

KnitWorkUnitDto line(int i,
        {required int section,
        required int step,
        String? label,
        required String text,
        int rows = 1,
        int? every,
        String? stepId}) =>
    KnitWorkUnitDto(
      section: section,
      step: step,
      sectionId: 'section-${section + 1}',
      stepId: stepId ?? 'step-${i + 1}',
      label: label,
      text: text,
      count: '20 sts',
      rows: rows,
      every: every,
      opaque: false,
      prefix: fakePrefix(i + 1),
      laterPrefix: fakePrefix(i + 1),
    );

KnitWorkDto sections({bool inserted = false, List<String>? headings}) {
  final units = [
    line(0, section: 0, step: 0, text: 'Cast on 20 sts.', stepId: 'step-1'),
    if (inserted) line(9, section: 0, step: 1, text: 'Try it on.', stepId: 'step-9'),
    line(1,
        section: 0,
        step: inserted ? 2 : 1,
        label: 'Next 6 rows (first row RS)',
        text: 'k2, p2 rib.',
        rows: 6,
        stepId: 'step-2'),
    line(2,
        section: 0,
        step: inserted ? 3 : 2,
        label: 'Next 12 rows (first row RS)',
        text: 'decrease 2 sts on the first row and then every 4 rows, 3 times.',
        rows: 12,
        every: 4,
        stepId: 'step-3'),
    line(3, section: 1, step: 0, text: 'Bind off all sts.', stepId: 'step-4'),
  ];
  return KnitWorkDto(
    mode: KnitWorkModeKind.sections,
    round: false,
    castOn: null,
    headings: headings ?? const ['Section 1: Cuff', 'Section 2: Finish'],
    sectionNotes: const ['Notes: Change to the smaller needles.', null],
    pieces: 'Made in 2 pieces: leg and foot.',
    units: units,
    stopped: false,
  );
}

KnitWorkDto chart({bool round = false, int rows = 3}) => KnitWorkDto(
      mode: KnitWorkModeKind.chart,
      round: round,
      castOn: 'Cast on 4 sts.',
      headings: const [],
      sectionNotes: const [],
      units: [
        for (var r = 0; r < rows; r++)
          KnitWorkUnitDto(
            chartRow: r + 1,
            label: 'Row ${r + 1} (${r.isEven ? 'RS' : 'WS'})',
            text: r.isEven ? 'k4' : 'p4',
            count: '4 sts',
            rows: 1,
            opaque: false,
            // The same row read from the other side, as the engine gives it.
            otherLabel: 'Row ${r + 1} (${r.isEven ? 'WS' : 'RS'})',
            otherText: r.isEven ? 'p4' : 'k4',
            prefix: fakePrefix(r + 1),
            laterPrefix: fakeLaterPrefix(r + 1),
          ),
      ],
      stopped: false,
      repeatNote: 'This chart has an odd number of rows, so this time through each row is worked '
          'from the other side than the chart marks it.',
    );

Widget tracker() => const KnitTrackerScreen(projectId: id, pattern: pattern, name: 'Sock');

void main() {
  late Directory docs;
  // Real file I/O runs outside the test's fake clock.
  Future<Progress> stored(WidgetTester tester) async => (await tester
          .runAsync(() => ProgressRepository(docsOverride: docs).load(BackupCraft.knitting, id)))!
      .progress!;
  Future<void> writeRecord(WidgetTester tester, KnitPlace place,
          {String? prefix, int units = 4, String? label}) =>
      tester.runAsync(() => ProgressRepository(docsOverride: docs).save(
          BackupCraft.knitting,
          id,
          Progress(
            craft: ProgressCraft.knitting,
            place: place,
            basis: PlaceBasis(units: units, prefix: prefix ?? fakePrefix(place.unit + 1)),
            updated: saved,
            label: label == null ? null : PlaceLabel(text: label, place: place, updated: saved),
          )));
  Future<String?> storedLabel(WidgetTester tester) async {
    final p = await stored(tester);
    // A record this build writes holds a label only for its own place and last change.
    if (p.label != null) expect(p.label!.isFor(p.place, p.updated), isTrue);
    return p.label?.text;
  }

  Finder place(String text) => find.descendant(
      of: find.byKey(const ValueKey('tracker-place')), matching: find.text(text), matchRoot: true);
  Future<void> next(WidgetTester tester) =>
      tapAndSettle(tester, find.byKey(const ValueKey('tracker-next')));

  setUp(() async => docs = await projectFolder(BackupCraft.knitting, id));
  tearDown(() => docs.delete(recursive: true));

  testWidgets(
      'steps are worked in order, with a row counter and the shaping rows named; a new '
      'session resumes at the row', (tester) async {
    await pumpTracker(tester, tracker(), trackerOverrides(docs, FakeWork(knit: sections())));
    expect(find.text('Section 1: Cuff'), findsOneWidget);
    expect(place('Step 1'), findsOneWidget);
    expect(find.text('Cast on 20 sts.'), findsOneWidget);
    await next(tester);
    expect(place('Row 1 of 6'), findsOneWidget);
    for (var i = 0; i < 5; i++) {
      await next(tester);
    }
    expect(place('Row 6 of 6'), findsOneWidget);
    await next(tester);
    expect(place('Row 1 of 12'), findsOneWidget);
    expect(find.text('A shaping row: work the shaping.'), findsOneWidget);
    await next(tester);
    expect(find.text('No shaping on this row.'), findsOneWidget);
    final p = await stored(tester);
    expect(p.place, const KnitPlace(2, row: 2, sectionId: 'section-1', stepId: 'step-3'));
    expect(p.log.single.count, 8);

    await tester.pumpWidget(const SizedBox());
    await pumpTracker(tester, tracker(), trackerOverrides(docs, FakeWork(knit: sections())));
    expect(place('Row 2 of 12'), findsOneWidget);
    expect(find.byKey(const ValueKey('tracker-banner')), findsNothing);
  });

  testWidgets('the last step has no next, and says so', (tester) async {
    await writeRecord(tester, const KnitPlace(3, sectionId: 'section-2', stepId: 'step-4'));
    await pumpTracker(tester, tracker(), trackerOverrides(docs, FakeWork(knit: sections())));
    expect(find.text('Section 2: Finish'), findsOneWidget);
    expect(find.text('This is the last step of the pattern.'), findsOneWidget);
    final nextButton =
        tester.widget<FilledButton>(find.byKey(const ValueKey('tracker-next')).first);
    expect(nextButton.onPressed, isNull);
  });

  testWidgets('a chart is worked again and again, from the other side every second time',
      (tester) async {
    await writeRecord(tester, const KnitPlace(2), units: 3);
    await pumpTracker(tester, tracker(), trackerOverrides(docs, FakeWork(knit: chart())));
    expect(place('Row 3 (RS)'), findsOneWidget);
    expect(find.textContaining('odd number of rows'), findsNothing, reason: 'time 1: as drawn');
    await next(tester);
    // Time 2: row 1 is a wrong-side row, and its stitches are read from that side.
    expect(place('Row 1 (WS)'), findsOneWidget);
    expect(find.text('p4'), findsWidgets);
    expect(find.text('of 3 rows, time 2 through the chart'), findsOneWidget);
    expect(find.textContaining('odd number of rows'), findsOneWidget);
    expect(find.textContaining('Before you start'), findsNothing,
        reason: 'only before row 1, once');
    expect((await stored(tester)).place, const KnitPlace(0, repeat: 2));
    expect(await storedLabel(tester), 'Row 1 of 3, time 2');
    // On time 2 the whole chart is before the place: it is kept with that time's fingerprint, and
    // a new session resumes there with nothing to check.
    expect((await stored(tester)).basis!.prefix, fakeLaterPrefix(1));
    await tester.pumpWidget(const SizedBox());
    await pumpTracker(tester, tracker(), trackerOverrides(docs, FakeWork(knit: chart())));
    expect(place('Row 1 (WS)'), findsOneWidget);
    expect(find.byKey(const ValueKey('tracker-banner')), findsNothing);
    // Time 3: as drawn again, with no note.
    for (var i = 0; i < 3; i++) {
      await next(tester);
    }
    expect(place('Row 1 (RS)'), findsOneWidget);
    expect(find.text('of 3 rows, time 3 through the chart'), findsOneWidget);
    expect(find.textContaining('odd number of rows'), findsNothing);
  });

  testWidgets('the pieces line, the cast-on and each section\'s notes are shown', (tester) async {
    await pumpTracker(tester, tracker(), trackerOverrides(docs, FakeWork(knit: sections())));
    expect(find.byKey(const ValueKey('tracker-pieces')), findsOneWidget);
    expect(find.text('Notes: Change to the smaller needles.'), findsOneWidget);
    await writeRecord(tester, const KnitPlace(3, sectionId: 'section-2', stepId: 'step-4'));
    await tester.pumpWidget(const SizedBox());
    await pumpTracker(tester, tracker(), trackerOverrides(docs, FakeWork(knit: sections())));
    expect(find.text('Section 2: Finish'), findsOneWidget);
    expect(find.byKey(const ValueKey('tracker-section-notes')), findsNothing);
    expect(find.byKey(const ValueKey('tracker-pieces')), findsNothing, reason: 'only at the start');
  });

  testWidgets('a row past a step that now works fewer rows is shown at its last row to check',
      (tester) async {
    await writeRecord(tester, const KnitPlace(1, row: 8, sectionId: 'section-1', stepId: 'step-2'));
    await pumpTracker(tester, tracker(), trackerOverrides(docs, FakeWork(knit: sections())));
    expect(place('Row 6 of 6'), findsOneWidget);
    expect(find.textContaining('It is shown at row 6'), findsOneWidget);
    await tapAndSettle(tester, find.byKey(const ValueKey('tracker-right')));
    final p = await stored(tester);
    expect(p.place, const KnitPlace(1, row: 6, sectionId: 'section-1', stepId: 'step-2'));
    expect(p.log.single.kind, LogKind.fix);
    expect(p.label?.text, 'Section 1: Cuff, step 2, row 6',
        reason: 'the words of the place moved to');
  });

  testWidgets('Undo of an accepted place puts it back to be checked again', (tester) async {
    await writeRecord(tester, const KnitPlace(9, sectionId: 'section-9', stepId: 'step-99'));
    await pumpTracker(tester, tracker(), trackerOverrides(docs, FakeWork(knit: sections())));
    expect(find.text('Bind off all sts.'), findsWidgets, reason: 'shown at the last step');
    await tapAndSettle(tester, find.byKey(const ValueKey('tracker-right')));
    expect(find.byKey(const ValueKey('tracker-banner')), findsNothing);
    expect(await storedLabel(tester), 'Section 2: Finish, step 1');
    await tapAndSettle(tester, find.byKey(const ValueKey('tracker-undo')));
    expect(find.byKey(const ValueKey('tracker-right')), findsOneWidget, reason: 'to check again');
    expect(find.text('Bind off all sts.'), findsWidgets);
    expect(find.textContaining('no longer in the pattern'), findsNothing);
    expect((await stored(tester)).place,
        const KnitPlace(9, sectionId: 'section-9', stepId: 'step-99'));
    expect(await storedLabel(tester), isNull,
        reason: 'a step no longer in the pattern has no words');
  });

  testWidgets('a note follows its step when a step is inserted before it', (tester) async {
    final docsRepo = ProgressRepository(docsOverride: docs);
    const at = KnitPlace(1, row: 3, sectionId: 'section-1', stepId: 'step-2');
    await tester.runAsync(() => docsRepo.save(
        BackupCraft.knitting,
        id,
        const Progress(
          craft: ProgressCraft.knitting,
          place: at,
          basis: PlaceBasis(units: 4, prefix: 'deadbeefdeadbeef'),
        ).withNote(at, 'Second ball', now: DateTime.utc(2026, 11, 18))));
    await pumpTracker(
        tester, tracker(), trackerOverrides(docs, FakeWork(knit: sections(inserted: true))));
    expect(find.text('Second ball'), findsNothing, reason: 'unit 1 is now another step');
    await tapAndSettle(tester, find.byKey(const ValueKey('tracker-suggestion')));
    expect(find.text('Second ball'), findsOneWidget, reason: 'the note is on step-2, now unit 2');
    final words = KnitPlaceWords(sections(inserted: true));
    expect(words(at), 'Section 1: Cuff, step 3, row 3');
    expect(words(const KnitPlace(1, sectionId: 'section-1', stepId: 'step-77')),
        'a step no longer in the pattern');
  });

  testWidgets('a step that moved is offered, never applied', (tester) async {
    await writeRecord(tester, const KnitPlace(1, row: 3, sectionId: 'section-1', stepId: 'step-2'),
        prefix: 'deadbeefdeadbeef');
    await pumpTracker(
        tester, tracker(), trackerOverrides(docs, FakeWork(knit: sections(inserted: true))));
    expect(find.text('Try it on.'), findsOneWidget, reason: 'shown at the same number');
    expect(find.textContaining('changed at or before this step'), findsOneWidget);
    expect((await stored(tester)).log, isEmpty);
    await tapAndSettle(tester, find.byKey(const ValueKey('tracker-suggestion')));
    expect(place('Row 3 of 6'), findsOneWidget);
    final p = await stored(tester);
    expect(p.place, const KnitPlace(2, row: 3, sectionId: 'section-1', stepId: 'step-2'));
    expect(p.log.single.kind, LogKind.jump);
  });

  testWidgets('Previous corrects a mistap and Undo reverses a jump', (tester) async {
    await writeRecord(tester, const KnitPlace(1, row: 2, sectionId: 'section-1', stepId: 'step-2'));
    await pumpTracker(tester, tracker(), trackerOverrides(docs, FakeWork(knit: sections())));
    await tapAndSettle(tester, find.byKey(const ValueKey('tracker-previous')));
    expect(place('Row 1 of 6'), findsOneWidget);
    await tapAndSettle(tester, find.byKey(const ValueKey('tracker-goto')));
    await tapAndSettle(tester, find.byKey(const ValueKey('tracker-goto-unit-3')));
    expect(find.text('Bind off all sts.'), findsOneWidget);
    await tapAndSettle(tester, find.byKey(const ValueKey('tracker-undo')));
    expect(place('Row 1 of 6'), findsOneWidget);
    expect((await stored(tester)).log.single.kind, LogKind.back);
  });

  testWidgets('every change of place writes the tracker\'s words with it; Clear leaves none',
      (tester) async {
    await pumpTracker(tester, tracker(), trackerOverrides(docs, FakeWork(knit: sections())));
    await next(tester);
    expect(await storedLabel(tester), 'Section 1: Cuff, step 2, row 1');
    await next(tester);
    expect(await storedLabel(tester), 'Section 1: Cuff, step 2, row 2');
    await tapAndSettle(tester, find.byKey(const ValueKey('tracker-previous')));
    expect(await storedLabel(tester), 'Section 1: Cuff, step 2, row 1');
    await tapAndSettle(tester, find.byKey(const ValueKey('tracker-goto')));
    await tapAndSettle(tester, find.byKey(const ValueKey('tracker-goto-unit-3')));
    expect(await storedLabel(tester), 'Section 2: Finish, step 1');
    await tapAndSettle(tester, find.byKey(const ValueKey('tracker-undo')));
    expect(await storedLabel(tester), 'Section 1: Cuff, step 2, row 1');
    // A note does not move the place: the words stay.
    await tapAndSettle(tester, find.byKey(const ValueKey('tracker-add-note')));
    await tester.enterText(find.byKey(const ValueKey('tracker-note-field')), 'Second ball');
    await tapAndSettle(tester, find.byKey(const ValueKey('tracker-note-save')));
    expect(await storedLabel(tester), 'Section 1: Cuff, step 2, row 1');
    // Clear removes the record; the next move writes its words again.
    await tapAndSettle(tester, find.byTooltip('More'));
    await tapAndSettle(tester, find.text('Clear my place'));
    await tapAndSettle(tester, find.byKey(const ValueKey('tracker-clear-confirm')));
    expect(File('${docs.path}/knits/$id.plyprogress').existsSync(), isFalse);
    await next(tester);
    expect(await storedLabel(tester), 'Section 1: Cuff, step 2, row 1');
  });

  testWidgets('a place accepted after the pattern changed is written with the pattern\'s words now',
      (tester) async {
    // Saved with the words of an earlier pattern, and a fingerprint the pattern no longer has.
    const at = KnitPlace(1, row: 3, sectionId: 'section-1', stepId: 'step-2');
    await writeRecord(tester, at,
        prefix: 'deadbeefdeadbeef', label: 'Section 1: Ribbing, step 2, row 3');
    await pumpTracker(tester, tracker(), trackerOverrides(docs, FakeWork(knit: sections())));
    expect(find.textContaining('changed at or before this step'), findsOneWidget);
    expect(await storedLabel(tester), 'Section 1: Ribbing, step 2, row 3',
        reason: 'nothing is written until the knitter acts');
    await tapAndSettle(tester, find.byKey(const ValueKey('tracker-right')));
    final p = await stored(tester);
    expect(p.place, at);
    expect(p.log, isEmpty, reason: 'accepted where it was: not logged');
    expect(p.label?.text, 'Section 1: Cuff, step 2, row 3');
  });

  testWidgets('a chart\'s "of" is the basis stored with the place, after Undo too', (tester) async {
    // Row 2 of 3 saved; rows were added at the end since (nothing to check on the first time).
    await writeRecord(tester, const KnitPlace(1), units: 3);
    await pumpTracker(tester, tracker(), trackerOverrides(docs, FakeWork(knit: chart(rows: 5))));
    expect(find.byKey(const ValueKey('tracker-right')), findsNothing);
    await next(tester);
    expect(await storedLabel(tester), 'Row 3 of 5');
    await tapAndSettle(tester, find.byKey(const ValueKey('tracker-undo')));
    final p = await stored(tester);
    expect(p.basis?.units, 3, reason: 'Undo puts back the basis it was saved with');
    expect(await storedLabel(tester), 'Row 2 of 3', reason: 'and the "of" with it');
  });

  test('place words, and the words a tile keeps', () {
    final w = KnitPlaceWords(sections());
    expect(w(const KnitPlace(2, row: 5)), 'Section 1: Cuff, step 3, row 5');
    expect(w.units(4), '4 rows and steps');
    expect(w.label(const KnitPlace(2, row: 5)), 'Section 1: Cuff, step 3, row 5');
    expect(w.label(const KnitPlace(0, sectionId: 'section-1', stepId: 'step-1')),
        'Section 1: Cuff, step 1');
    expect(w.label(const KnitPlace(1, sectionId: 'section-1', stepId: 'step-77')), isNull,
        reason: 'a step no longer in the pattern');
    expect(w.label(const KnitPlace(9)), isNull, reason: 'past the end');
    final c = KnitPlaceWords(chart());
    expect(c(const KnitPlace(1, repeat: 2)), 'row 2, time 2');
    expect(c.units(1), '1 row');
    expect(c.label(const KnitPlace(1), units: 3), 'Row 2 of 3');
    expect(c.label(const KnitPlace(1, repeat: 2), units: 3), 'Row 2 of 3, time 2');
    expect(c.label(const KnitPlace(1), units: 24), 'Row 2 of 24', reason: 'the basis, as stored');
    expect(c.label(const KnitPlace(2)), 'Row 3', reason: 'no basis, no "of"');
    expect(c.label(const KnitPlace(2), units: 2), 'Row 3', reason: 'past the basis, no "of"');
    expect(KnitPlaceWords(chart(round: true)).label(const KnitPlace(2, repeat: 4), units: 3),
        'Round 3 of 3, time 4');
    // A section's name is the knitter's own and may be long: the heading is shortened, never the
    // step and row.
    final headings = ['Section 1: ${'Long name ' * 40}', 'Section 2'];
    final long = KnitPlaceWords(sections(headings: headings)).label(const KnitPlace(2, row: 5))!;
    expect(long.length, lessThanOrEqualTo(ProgressLimits.maxLabelChars));
    expect(long, startsWith('Section 1: Long name'));
    expect(long, endsWith('\u2026, step 3, row 5'));
    // A heading with nothing readable left once shortened is left out.
    final brackets = KnitPlaceWords(sections(headings: ['(' * 300, 'Section 2']));
    expect(brackets.label(const KnitPlace(2, row: 5)), 'Step 3, row 5');
  });
}
