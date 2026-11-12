import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/models/draft_doc.dart';
import 'package:ply/src/models/treadling_entries.dart';
import 'package:ply/src/state/draft_editor_notifier.dart';
import 'package:ply/src/state/editor_providers.dart';
import 'package:ply/src/widgets/book_view_sheet.dart';

// Host coverage for the separate Book view (M7-09): the treadling grouped into runs of identical
// picks, each row with its count, pick range, and EVERY weft color in it; an honest label (not "Use
// Tabby" shorthand); and editing operations that are explicit per-pick changes which the re-derived
// rows show back exactly. It never reshapes the editor grid (that is covered by the grid/layout tests).

const _white = DraftColor(r: 255, g: 255, b: 255);
const _black = DraftColor(r: 0, g: 0, b: 0);
const _red = DraftColor(r: 200, g: 0, b: 0);

/// Treadle 1 x3 (weft black, red, black: one shed in two yarns), treadle 2 x1, treadles 3+4 x1,
/// treadle 1 x1. Four Book view rows over six picks.
DraftDoc fixture() => DraftDoc(
      name: 'book',
      shafts: 4,
      treadles: 4,
      shed: Shed.rising,
      unit: MeasureUnit.inches,
      threading: const [
        [1],
        [2],
        [3],
        [4],
      ],
      drive: DraftTreadled(
        tieup: const [
          [1],
          [2],
          [3],
          [4],
        ],
        treadling: const [
          [1],
          [1],
          [1],
          [2],
          [3, 4],
          [1],
        ],
      ),
      palette: const [_white, _black, _red],
      warpColors: const [0, 0, 0, 0],
      weftColors: const [1, 2, 1, 0, 0, 0],
      notes: '',
    );

Future<ProviderContainer> pumpBook(WidgetTester tester, DraftDoc doc) async {
  tester.view.physicalSize = const Size(900, 1800);
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

List<List<int>> treadling(ProviderContainer c) =>
    (c.read(draftEditorProvider).draft.drive as DraftTreadled).treadling;

/// The swatch color of the weft stretch starting at [pick] inside the row starting at [rowStart].
Color swatchColor(WidgetTester tester, int rowStart, int pick) {
  final box = tester.widget<Container>(find.descendant(
      of: find.byKey(ValueKey('weft-$rowStart-$pick')), matching: find.byType(Container)));
  return (box.decoration! as BoxDecoration).color!;
}

Future<void> tapRow(WidgetTester tester, String pickRange) async {
  await tester.tap(find.text(pickRange));
  await tester.pump();
}

void main() {
  testWidgets('lists one row per run with its shed, count, and pick range', (tester) async {
    await pumpBook(tester, fixture());
    expect(find.text('Book view'), findsOneWidget);
    expect(find.text('6 picks in 4 rows'), findsOneWidget);
    expect(find.text('Treadle 1'), findsNWidgets(2), reason: 'rows 1 and 4');
    expect(find.text('Treadle 2'), findsOneWidget);
    expect(find.text('Treadles 3 + 4'), findsOneWidget);
    expect(find.text('Picks 1 to 3'), findsOneWidget);
    expect(find.text('Pick 4'), findsOneWidget);
    expect(find.text('Pick 5'), findsOneWidget);
    expect(find.text('Pick 6'), findsOneWidget);
    expect(find.text('×3'), findsOneWidget, reason: 'row 1 covers three picks');
    expect(find.text('×1'), findsNWidgets(3));
    for (final n in ['1', '2', '3', '4']) {
      expect(find.text(n), findsOneWidget, reason: 'row number $n');
    }
  });

  testWidgets('labels itself honestly: groups runs, not "Use Tabby" shorthand', (tester) async {
    await pumpBook(tester, fixture());
    expect(find.text(kBookViewExplainer), findsOneWidget);
    expect(find.text(kBookViewNotTabby), findsOneWidget);
    expect(find.text(kBookViewKeepsPicks), findsOneWidget);
    expect(kBookViewNotTabby, contains('not "Use Tabby" shorthand'));
  });

  testWidgets('a row shows EVERY weft color in its run, in pick order (no first-pick masking)',
      (tester) async {
    final handle = tester.ensureSemantics();
    await pumpBook(tester, fixture());
    // Row 1 is one shed thrown 3x in black, red, black: three swatches, not one.
    expect(swatchColor(tester, 0, 0), const Color(0xFF000000));
    expect(swatchColor(tester, 0, 1), const Color(0xFFC80000));
    expect(swatchColor(tester, 0, 2), const Color(0xFF000000));
    expect(find.bySemanticsLabel(RegExp(
            'Row 1: Treadle 1, 3 picks, picks 1 to 3, weft color 2 for 1 pick, then color 3 for 1 '
            'pick, then color 2 for 1 pick')),
        findsOneWidget);
    handle.dispose();
  });

  testWidgets('a stretch of one weft color shows its pick count beside the swatch', (tester) async {
    final doc = fixture().copyWith(weftColors: const [2, 2, 1, 0, 0, 0]);
    await pumpBook(tester, doc);
    expect(find.byKey(const ValueKey('weft-0-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('weft-0-2')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('weft-0-0')), matching: find.text('×2')),
        findsOneWidget);
  });

  testWidgets('a generated-overshot-style draft (tabby between pattern picks) groups nothing',
      (tester) async {
    // Pattern A, tabby a, pattern A, tabby b, ...: no two neighbours share a shed, so every pick is
    // its own row. The view must not pretend this is "Use Tabby" shorthand.
    final doc = fixture().copyWith(
      drive: DraftTreadled(tieup: const [
        [1],
        [2],
        [3],
        [4],
      ], treadling: const [
        [1],
        [3],
        [1],
        [4],
        [2],
        [3],
      ]),
    );
    await pumpBook(tester, doc);
    expect(find.text('6 picks in 6 rows'), findsOneWidget);
    expect(find.text(kBookViewNotTabby), findsOneWidget);
  });

  testWidgets('Count adds a copy of the row\'s LAST pick and removes from the end; +1 then -1 '
      'round-trips to the original picks', (tester) async {
    final c = await pumpBook(tester, fixture());
    final original = c.read(draftEditorProvider).draft;
    await tapRow(tester, 'Picks 1 to 3');
    expect(find.text('Count 3'), findsOneWidget);

    await tester.tap(find.byTooltip('More picks in this row'));
    await tester.pump();
    expect(treadling(c), [
      [1],
      [1],
      [1],
      [1],
      [2],
      [3, 4],
      [1],
    ]);
    // The added pick copies pick 3 (black, color index 1), the run's LAST pick.
    expect(c.read(draftEditorProvider).draft.weftColors, [1, 2, 1, 1, 0, 0, 0]);
    expect(c.read(draftEditorProvider).undo.length, 1, reason: 'one undo entry per step');
    expect(find.text('Picks 1 to 4'), findsOneWidget, reason: 'the row re-derives from the picks');
    expect(find.text('Count 4'), findsOneWidget);
    // The rows still expand to exactly the draft's picks.
    final entries = treadlingEntries(treadling(c));
    expect([for (final e in entries) for (var k = 0; k < e.count; k++) e.shed], treadling(c));

    await tester.tap(find.byTooltip('Fewer picks in this row'));
    await tester.pump();
    expect(c.read(draftEditorProvider).draft, original, reason: '+1 then -1 is the original draft');
  });

  testWidgets('Treadle sets every pick of the row; joining the row above keeps the selection on its '
      'picks', (tester) async {
    final c = await pumpBook(tester, fixture());
    await tapRow(tester, 'Pick 4'); // row 2: treadle 2
    expect(find.text('Editing row 2, pick 4'), findsOneWidget);
    await tester.tap(find.byTooltip('Previous treadle')); // 2 -> 1: the same shed as row 1
    await tester.pump();
    expect(treadling(c)[3], [1]);
    expect(c.read(draftEditorProvider).draft.weftColors, [1, 2, 1, 0, 0, 0],
        reason: 'a shed edit never touches weft colors');
    // Rows 1 and 2 now group as one (picks 1 to 4); the selection follows pick 4 into it.
    expect(find.text('6 picks in 3 rows'), findsOneWidget);
    expect(find.text('Editing row 1, picks 1 to 4'), findsOneWidget);
  });

  testWidgets('Treadle down from 1 clears the row to no treadle', (tester) async {
    final c = await pumpBook(tester, fixture());
    await tapRow(tester, 'Pick 6'); // row 4: treadle 1
    await tester.tap(find.byTooltip('Previous treadle'));
    await tester.pump();
    expect(treadling(c)[5], isEmpty);
    expect(find.text('No treadle'), findsOneWidget);
  });

  testWidgets('a multi-treadle row offers no single-treadle stepper, and says where to edit it',
      (tester) async {
    await pumpBook(tester, fixture());
    await tapRow(tester, 'Pick 5'); // treadles 3 + 4
    expect(find.byTooltip('Next treadle'), findsNothing);
    expect(find.byTooltip('Previous treadle'), findsNothing);
    expect(find.textContaining('more than one treadle'), findsOneWidget);
    expect(find.byTooltip('More picks in this row'), findsOneWidget, reason: 'Count still applies');
  });

  testWidgets('Delete removes exactly the row\'s picks', (tester) async {
    final c = await pumpBook(tester, fixture());
    await tapRow(tester, 'Pick 4');
    await tester.tap(find.text('Delete these picks'));
    await tester.pump();
    expect(treadling(c), [
      [1],
      [1],
      [1],
      [3, 4],
      [1],
    ]);
    expect(c.read(draftEditorProvider).draft.weftColors, [1, 2, 1, 0, 0]);
    expect(find.textContaining('Editing row'), findsNothing, reason: 'the selection is cleared');
  });

  testWidgets('tapping the selected row again deselects it', (tester) async {
    await pumpBook(tester, fixture());
    await tapRow(tester, 'Pick 4');
    expect(find.textContaining('Editing row'), findsOneWidget);
    await tapRow(tester, 'Pick 4');
    expect(find.textContaining('Editing row'), findsNothing);
  });

  testWidgets('the pin switch sets the persisted Book view flag', (tester) async {
    final c = await pumpBook(tester, fixture());
    expect(c.read(overshotTreadlingProvider), isFalse);
    await tester.tap(find.text('Book view button in the editor'));
    await tester.pump();
    expect(c.read(overshotTreadlingProvider), isTrue);
  });

  testWidgets('a liftplan lists shaft sheds and offers Count but no treadle stepper', (tester) async {
    final doc = fixture().copyWith(
      treadles: 0,
      drive: DraftLiftplan(liftplan: const [
        [1, 2],
        [2, 1],
        [3],
        [],
      ]),
      weftColors: const [0, 1, 0, 0],
    );
    await pumpBook(tester, doc);
    expect(find.text('Shafts 1 + 2'), findsOneWidget);
    expect(find.text('Shaft 3'), findsOneWidget);
    expect(find.text('No shafts raised'), findsOneWidget);
    await tapRow(tester, 'Picks 1 to 2');
    expect(find.byTooltip('Next treadle'), findsNothing);
    expect(find.byTooltip('More picks in this row'), findsOneWidget);
    expect(find.textContaining('more than one treadle'), findsNothing);
  });

  testWidgets('an empty draft says it has no picks', (tester) async {
    await pumpBook(tester, DraftDoc.blank());
    expect(find.text('This draft has no picks yet.'), findsOneWidget);
  });

  testWidgets('opens as a bottom sheet on a phone and scrolls a long list without overflow',
      (tester) async {
    // 360x640 phone (below the wide breakpoint, so the real bottom-sheet path), 120 picks alternating
    // two treadles (120 rows: the lazy, non-shrink-wrapped list), the last row selected for editing.
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final doc = fixture().copyWith(
      drive: DraftTreadled(tieup: const [
        [1],
        [2],
        [3],
        [4],
      ], treadling: [
        for (var p = 0; p < 120; p++) [p.isEven ? 1 : 2],
      ]),
      weftColors: [for (var p = 0; p < 120; p++) p % 3],
    );
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.read(draftEditorProvider.notifier).load(doc);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
                onPressed: () => showBookViewSheet(context), child: const Text('open')),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.text('120 picks in 120 rows'), findsOneWidget);
    await tester.tap(find.text('Pick 1'));
    await tester.pump();
    expect(find.text('Editing row 1, pick 1'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Pick 120'), 600,
        scrollable: find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)));
    await tester.pumpAndSettle();
    expect(find.text('Pick 120'), findsOneWidget, reason: 'the list scrolls to its last row');
    expect(tester.takeException(), isNull, reason: 'no layout overflow at phone width');
  });

  test('label helpers', () {
    expect(bookShedLabel(const [], treadled: true), 'No treadle');
    expect(bookShedLabel(const [4, 2], treadled: true), 'Treadles 2 + 4');
    expect(bookShedLabel(const [3], treadled: false), 'Shaft 3');
    expect(bookPickRangeLabel(0, 1), 'Pick 1');
    expect(bookPickRangeLabel(4, 9), 'Picks 5 to 9');
  });
}
