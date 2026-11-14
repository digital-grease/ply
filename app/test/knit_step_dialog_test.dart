import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/models/knit_sections.dart';
import 'package:ply/src/rust/knit_dto.dart';
import 'package:ply/src/widgets/knit_step_dialog.dart';

import 'knit_sections_test_support.dart';

// The section step forms: each kind returns exactly the action it describes, a number that is not
// a whole number in range is refused with a plain message (never saved as a guess), a group on hold
// needs a name, and a form that has nothing to work with (no chart rows, no held stitches) cannot be
// saved. Whether the step fits the needle is the engine's call, not the form's.

/// Open the form for [kind] over [pattern] (optionally editing [initial]); the action it returns
/// lands in the returned list.
Future<List<KnitStepActionDto?>> _open(WidgetTester tester, KnitStepKind kind,
    {KnitPatternDto? pattern, KnitStepActionDto? initial}) async {
  final p = pattern ?? patternFromPlyknit(sectionFixtureText('neckline-hold-flat', 'plyknit'));
  final results = <KnitStepActionDto?>[];
  await tester.binding.setSurfaceSize(const Size(600, 1600));
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

void main() {
  testWidgets('cast on: a count from 1 up, refused otherwise', (tester) async {
    final r = await _open(tester, KnitStepKind.castOn);
    await tester.enterText(find.byKey(const Key('knit-step-count')), '0');
    await _save(tester);
    expect(find.text(_range), findsOneWidget);
    expect(r, isEmpty, reason: 'not saved');
    await tester.enterText(find.byKey(const Key('knit-step-count')), '24');
    await _save(tester);
    expect(r, [const KnitStepActionDto.castOn(count: 24)]);
  });

  testWidgets('work across: to the end, to the last stitches, or a count, and resolving',
      (tester) async {
    var r = await _open(tester, KnitStepKind.work);
    expect(find.byKey(const Key('knit-step-count')), findsNothing, reason: 'to the end');
    await tester.tap(find.text('Purl'));
    await tester.tap(find.byKey(const Key('knit-step-resolve')));
    await tester.pump();
    await _save(tester);
    expect(
        r.single,
        const KnitStepActionDto.work(
            stitch: WorkStitchKind.purl, to: WorkToDto.end(), resolveTurns: true));

    r = await _open(tester, KnitStepKind.work);
    await tester.tap(find.text('A number of stitches'));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('knit-step-count')), '9');
    await _save(tester);
    expect(
        r.single,
        const KnitStepActionDto.work(
            stitch: WorkStitchKind.knit, to: WorkToDto.count(count: 9), resolveTurns: false));
  });

  testWidgets('short row: where to turn and how', (tester) async {
    final r = await _open(tester, KnitStepKind.shortRow);
    await tester.tap(find.text('Turn after this many stitches'));
    await tester.tap(find.text('Just turn (method not stated)'));
    await tester.enterText(find.byKey(const Key('knit-step-count')), '10');
    await tester.pump();
    await _save(tester);
    expect(
        r.single,
        const KnitStepActionDto.shortRow(
            stitch: WorkStitchKind.knit,
            to: TurnAtDto.count(count: 10),
            method: TurnMethodKind.unspecified,
            resolveTurns: false));
  });

  testWidgets('bind off and hold: the rest of the row, or a count; a group needs a name',
      (tester) async {
    var r = await _open(tester, KnitStepKind.bindOff);
    await _save(tester);
    expect(r.single, const KnitStepActionDto.bindOff(resolveTurns: false));

    r = await _open(tester, KnitStepKind.bindOff);
    await tester.tap(find.byKey(const Key('knit-step-rest')));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('knit-step-count')), '5');
    await _save(tester);
    expect(r.single, const KnitStepActionDto.bindOff(count: 5, resolveTurns: false));

    r = await _open(tester, KnitStepKind.hold);
    await tester.tap(find.byKey(const Key('knit-step-rest')));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('knit-step-count')), '12');
    await _save(tester);
    expect(find.text('Give the group a name, so the step that returns it can say which.'),
        findsOneWidget);
    await tester.enterText(find.byKey(const Key('knit-step-name')), ' center neck ');
    await _save(tester);
    expect(r.single, const KnitStepActionDto.hold(count: 12, name: 'center neck'));
  });

  testWidgets('return held stitches: choose the group and the side facing you', (tester) async {
    final r = await _open(tester, KnitStepKind.resume);
    // Starts on the latest group; pick the other one and say the WS faces you.
    await tester.tap(find.byKey(const Key('knit-step-hold')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('center neck (Divide for the neck, step 2)').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Wrong side (WS)'));
    await tester.pump();
    await _save(tester);
    expect(r.single, const KnitStepActionDto.resume(hold: 'step-3', facing: SideKind.ws));
  });

  testWidgets('a form with nothing to work with cannot be saved', (tester) async {
    final shoulder = patternFromPlyknit(sectionFixtureText('shoulder-short-rows-flat', 'plyknit'));
    final noHolds = KnitPatternDto(
      name: shoulder.name,
      construction: shoulder.construction,
      firstRowSide: shoulder.firstRowSide,
      castOn: shoulder.castOn,
      gauge: shoulder.gauge,
      palette: shoulder.palette,
      legend: shoulder.legend,
      chart: const ChartDto(width: 0, rows: []),
      notes: '',
      sections: const [],
    );
    await _open(tester, KnitStepKind.resume, pattern: noHolds);
    expect(find.text('No step puts stitches on hold yet. Add one first.'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const Key('knit-step-save'))).onPressed, isNull);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    await _open(tester, KnitStepKind.chartRows, pattern: noHolds);
    expect(find.text('The chart has no rows yet. Add rows in the chart first.'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const Key('knit-step-save'))).onPressed, isNull);
  });

  testWidgets('chart rows: within the chart, lower row first', (tester) async {
    final r = await _open(tester, KnitStepKind.chartRows);
    expect(find.text('The chart has 2 rows.'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('knit-step-first')), '2');
    await tester.enterText(find.byKey(const Key('knit-step-last')), '1');
    await _save(tester);
    expect(find.text('The last row must not come before the first.'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('knit-step-last')), '3');
    await _save(tester);
    expect(find.text('Enter a whole number from 1 to 2.'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('knit-step-last')), '2');
    await _save(tester);
    expect(r.single, const KnitStepActionDto.chartRows(first: 2, last: 2));
  });

  testWidgets('a written step: blank change is "not stated", a number is kept, other text refused',
      (tester) async {
    var r = await _open(tester, KnitStepKind.unchecked);
    await tester.enterText(find.byKey(const Key('knit-step-text')), 'Work 2 in even.');
    await _save(tester);
    expect(r.single, const KnitStepActionDto.opaque(text: 'Work 2 in even.'));

    r = await _open(tester, KnitStepKind.unchecked,
        initial: const KnitStepActionDto.opaque(text: 'Dec 2.', stitchChange: -2));
    expect(find.text('Edit step: Written step (not checked)'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('knit-step-change')), 'two');
    await _save(tester);
    expect(
        find.text('Enter a whole number, such as 0, 4 or -2, or leave it blank.'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('knit-step-change')), '-4');
    await _save(tester);
    expect(r.single, const KnitStepActionDto.opaque(text: 'Dec 2.', stitchChange: -4));
  });
}
