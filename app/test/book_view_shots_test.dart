import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/models/draft_doc.dart';
import 'package:ply/src/models/use_tabby.dart';
import 'package:ply/src/state/draft_editor_notifier.dart';
import 'package:ply/src/state/editor_providers.dart';
import 'package:ply/src/widgets/book_view_sheet.dart';

import 'pick_roles_support.dart';

// Host coverage for shot groups, shuttles, and strands in the Book view (M8-06, ADR 0009): grouping
// and ungrouping a run of identical sheds, a group shown distinctly from separate same-shed picks,
// setting shuttles (a row or one pick) and each shuttle's starting side, the derived direction
// arrows, strands per pick, Use tabby falling back when a draft has a shot group, and the notice when
// an edit splits a group as a side effect.

Future<ProviderContainer> pumpBook(WidgetTester tester, DraftDoc doc) async {
  tester.view.physicalSize = const Size(900, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final c = ProviderContainer();
  addTearDown(c.dispose);
  c.read(draftEditorProvider.notifier).load(doc);
  await tester.pumpWidget(UncontrolledProviderScope(
    container: c,
    child: const MaterialApp(home: Scaffold(body: BookViewSheet())),
  ));
  await tester.pump();
  return c;
}

DraftDoc draft(ProviderContainer c) => c.read(draftEditorProvider).draft;

/// Treadle 1 three times, then treadle 2: rows "Picks 1 to 3" (one shed, separate picks) and
/// "Pick 4".
DraftDoc runOfThree({List<ShotGroup> groups = const []}) =>
    generatedOvershot(roles: false).copyWith(
      drive: DraftTreadled(tieup: kOvershotTieup, treadling: const [
        [1],
        [1],
        [1],
        [2],
      ]),
      weftColors: const [1, 1, 1, 0],
      shotGroups: groups,
    );

Future<void> tapRow(WidgetTester tester, String range) async {
  await tester.tap(find.text(range));
  await tester.pump();
}

void main() {
  testWidgets('group the first picks of a run as a double shot, then ungroup', (tester) async {
    final c = await pumpBook(tester, runOfThree());
    expect(find.textContaining('Double shot'), findsNothing,
        reason: 'same-shed picks without a group are separate picks');
    await tapRow(tester, 'Picks 1 to 3');
    expect(find.text(kShotGroupTitle), findsOneWidget);
    expect(find.text(kShotGroupExplainer), findsOneWidget);
    expect(find.text('Passes 3'), findsOneWidget);
    expect(find.text('Group as a triple shot'), findsOneWidget);
    await tester.tap(find.byTooltip('Fewer passes in the group'));
    await tester.pump();
    expect(find.text('This groups the first 2 picks of this row.'), findsOneWidget);
    await tester.tap(find.text('Group as a double shot'));
    await tester.pump();
    expect(draft(c).shotGroups, const [ShotGroup(0, 2)]);
    expect(c.read(draftEditorProvider).undo.length, 1, reason: 'one undo entry');
    // The group is its own row, shown distinctly; pick 3 stays a separate pick in the same shed.
    expect(find.byKey(const ValueKey('shot-0')), findsOneWidget);
    expect(find.text('Double shot (2 passes in one shed)'), findsOneWidget);
    expect(find.text('Picks 1 to 2'), findsWidgets);
    expect(find.text('Pick 3'), findsOneWidget);
    // The selection follows pick 1, so the group row is the one being edited: ungroup it.
    expect(find.text('Editing row 1, picks 1 to 2'), findsOneWidget);
    expect(find.text('$kShotGroupTitle: Double shot (2 passes in one shed)'), findsOneWidget);
    expect(find.text(kShotGroupCatch), findsOneWidget);
    await tester.tap(find.text(kUngroup));
    await tester.pump();
    expect(draft(c).shotGroups, isEmpty);
    expect(find.text('Picks 1 to 3'), findsOneWidget, reason: 'one run of separate picks again');
  });

  testWidgets('a count change on a group row adds or removes passes of the group', (tester) async {
    final c = await pumpBook(tester, runOfThree(groups: const [ShotGroup(0, 2)]));
    await tester.tap(find.text('Double shot (2 passes in one shed)'));
    await tester.pump();
    expect(
        find.text('Count adds or removes passes at the end of this shot group. An added pass copies '
            'the last one, weft color, role, shuttle, and strands included.'),
        findsOneWidget);
    await tester.tap(find.byTooltip('More picks in this row'));
    await tester.pump();
    expect(draft(c).shotGroups, const [ShotGroup(0, 3)]);
    expect(find.text('Triple shot (3 passes in one shed)'), findsOneWidget);
    await tester.tap(find.byTooltip('Fewer picks in this row'));
    await tester.pump();
    await tester.tap(find.byTooltip('Fewer picks in this row'));
    await tester.pump();
    expect(draft(c).shotGroups, isEmpty, reason: 'one pass is not a shot group');
  });

  testWidgets('set shuttles and starting sides; directions are derived arrows', (tester) async {
    final c = await pumpBook(tester, runOfThree());
    expect(find.text(kShuttlesNone), findsOneWidget, reason: 'the collapsed panel summary');
    await tapRow(tester, 'Picks 1 to 3');
    expect(find.text('Shuttle of all 3 picks'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('row-shuttle-1')));
    await tester.pump();
    expect(draft(c).pickShuttles, const [1, 1, 1, null]);
    // The panel opens once a pick has a shuttle; shuttle 1 has no starting side yet.
    expect(find.text('Shuttle 1 starts from'), findsOneWidget);
    expect(find.text('Shuttle 1 has no starting side'), findsOneWidget);
    expect(find.text('Shuttle 1 has no starting side, so its picks show no direction.'),
        findsOneWidget);
    expect(
        find.text('Pick 4 has no shuttle, so Ply cannot tell its direction.'), findsOneWidget);
    expect(find.text('Shuttle 1'), findsOneWidget, reason: 'the row names its shuttle, no arrows');
    await tester.tap(find.text('Right'));
    await tester.pump();
    expect(draft(c).shuttleStarts, const {1: ShuttleSide.right});
    expect(find.text('Shuttle 1 starts from the right'), findsOneWidget);
    // Three passes of one shuttle: right to left, back, and across again.
    expect(find.text('Shuttle 1: ← → ←'), findsOneWidget);
    // One pick of the row on shuttle 2.
    await tester.tap(find.byTooltip('Next pick in this row'));
    await tester.pump();
    expect(find.text('Shuttle of pick 2'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('pick-shuttle-2')));
    await tester.pump();
    expect(draft(c).pickShuttles, const [1, 2, 1, null]);
    expect(find.text('Shuttles: 1 ←, 2, 1 →'), findsOneWidget,
        reason: 'shuttle 1 counts only its own passes; shuttle 2 has no side');
    // A screen reader hears every pass in words.
    final handle = tester.ensureSemantics();
    expect(
        find.bySemanticsLabel(RegExp('shuttle 1 right to left, then shuttle 2, direction unknown, '
            'then shuttle 1 left to right')),
        findsOneWidget);
    handle.dispose();
    expect(c.read(draftEditorProvider).undo.length, 3);
  });

  testWidgets('strands per pick: a whole row, then one pick', (tester) async {
    final c = await pumpBook(tester, runOfThree());
    await tapRow(tester, 'Picks 1 to 3');
    expect(find.text(kStrandsExplainer), findsOneWidget);
    expect(find.text('Strands in each pick: 1'), findsOneWidget);
    await tester.tap(find.byTooltip('More strands in every pick of this row'));
    await tester.pump();
    expect(draft(c).pickStrands, const [2, 2, 2, 1]);
    expect(find.text('2 strands carried together in each pass'), findsOneWidget);
    await tester.tap(find.byTooltip('Next pick in this row'));
    await tester.pump();
    await tester.tap(find.byTooltip('More strands in this pick'));
    await tester.pump();
    expect(draft(c).pickStrands, const [2, 3, 2, 1]);
    expect(find.text('Strands carried together: 2, 3, 2'), findsOneWidget);
    expect(find.text('Strands in each pick: mixed'), findsOneWidget);
    // On mixed counts, Fewer makes every pick the smallest.
    await tester.tap(find.byTooltip('Fewer strands in every pick of this row'));
    await tester.pump();
    expect(draft(c).pickStrands, const [2, 2, 2, 1]);
  });

  testWidgets('Use tabby falls back with its reason when the draft has a shot group',
      (tester) async {
    final doc = generatedOvershot().copyWith(
        drive: DraftTreadled(tieup: kOvershotTieup, treadling: const [
          [1],
          [3],
          [1],
          [1],
          [2],
          [4],
          [2],
          [3],
        ]),
        shotGroups: const [ShotGroup(2, 2)]);
    await pumpBook(tester, doc);
    const reason =
        'Use tabby shorthand needs one pass in each shed, but picks 3 to 4 are grouped as a double '
        'shot.';
    expect(find.text(reason), findsOneWidget);
    expect(
        tester.widget<SwitchListTile>(find.widgetWithText(SwitchListTile, kBookViewUseTabby)).value,
        isFalse);
    expect(find.text('Double shot (2 passes in one shed)'), findsOneWidget);
  });

  testWidgets('Use tabby rows show the pattern shuttle and the tabby shuttle', (tester) async {
    final doc = generatedOvershot().copyWith(
      pickShuttles: [for (var p = 0; p < 8; p++) p.isEven ? 1 : 2],
      shuttleStarts: const {1: ShuttleSide.right, 2: ShuttleSide.left},
    );
    await pumpBook(tester, doc);
    expect(find.text('Tabby on shuttle 2'), findsOneWidget);
    // Pattern picks 1 and 3: shuttle 1 from the right, then back.
    expect(find.byKey(const ValueKey('pattern-shuttle-0')), findsOneWidget);
    expect(find.text('Shuttle 1: ← →'), findsNWidgets(2));
    expect(readUseTabby(doc), isA<UseTabbyBook>());
  });

  test('a shed paint that splits a group raises a notice; explicit edits do not', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final n = c.read(draftEditorProvider.notifier);
    n.load(runOfThree(groups: const [ShotGroup(0, 3)]));
    final d = draft(c);
    // Repaint pick 3's shed (as the draft grid would) and commit.
    n.commitEdit(d.copyWith(
        drive: DraftTreadled(tieup: kOvershotTieup, treadling: const [
      [1],
      [1],
      [2],
      [2],
    ])));
    expect(draft(c).shotGroups, const [ShotGroup(0, 2)]);
    expect(c.read(shotGroupNoticeProvider),
        'The triple shot at picks 1 to 3 now groups only picks 1 to 2, because the other picks are '
        'in a different shed now. Every pass of a shot group uses the same shed.');
    c.read(shotGroupNoticeProvider.notifier).state = null;
    n.ungroupShot(0);
    expect(draft(c).shotGroups, isEmpty);
    expect(c.read(shotGroupNoticeProvider), isNull, reason: 'an explicit ungroup says nothing');
    n.undo();
    expect(draft(c).shotGroups, const [ShotGroup(0, 2)], reason: 'undo restores the group');
  });
}
