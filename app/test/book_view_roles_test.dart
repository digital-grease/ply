import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/models/draft_doc.dart';
import 'package:ply/src/models/use_tabby.dart';
import 'package:ply/src/state/draft_editor_notifier.dart';
import 'package:ply/src/widgets/book_view_sheet.dart';

import 'pick_roles_support.dart';

// Host coverage for pick roles in the Book view (M8-06, M8-08): the Use tabby shorthand when the
// roles make it exact (and the switch back to every pick), edits in it that keep book and full mode
// the same or are refused with a reason, setting the role of a row or of one pick, and the "Mark tabby
// picks" proposal that changes nothing until the weaver confirms.

Future<ProviderContainer> pumpBook(WidgetTester tester, DraftDoc doc) async {
  tester.view.physicalSize = const Size(900, 2400);
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
List<int> treadles(ProviderContainer c) => [for (final r in draft(c).drive.rows) r.single];

SwitchListTile useTabbySwitch(WidgetTester tester) =>
    tester.widget<SwitchListTile>(find.widgetWithText(SwitchListTile, kBookViewUseTabby));

void main() {
  testWidgets('a generated overshot opens in Use tabby shorthand', (tester) async {
    await pumpBook(tester, generatedOvershot());
    expect(useTabbySwitch(tester).value, isTrue);
    expect(find.text(kBookViewUseTabbyOn), findsOneWidget);
    expect(find.text('8 picks: 4 pattern picks in 2 rows and 4 tabby picks'), findsOneWidget);
    expect(find.text('Use tabby'), findsOneWidget);
    expect(find.textContaining('starting with tabby a.'), findsOneWidget);
    // Pattern rows only: treadle 1 twice (picks 1 to 3), treadle 2 twice (picks 5 to 7).
    expect(find.text('Treadle 1'), findsOneWidget);
    expect(find.text('Treadle 2'), findsOneWidget);
    expect(find.text('Treadle 3'), findsNothing, reason: 'tabby picks are in the instruction');
    expect(find.text('Picks 1 to 3'), findsOneWidget);
    expect(find.text('Picks 5 to 7'), findsOneWidget);
    expect(find.text('×2'), findsNWidgets(4),
        reason: 'each row: two pattern picks, and its two-pick stretch of the pattern weft');
    expect(find.byKey(const ValueKey('pattern-0-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('pattern-2-2')), findsOneWidget);
    expect(find.byKey(const ValueKey('tabby-weft')), findsOneWidget);
  });

  testWidgets('switching Use tabby off lists every pick with its role', (tester) async {
    await pumpBook(tester, generatedOvershot());
    await tester.tap(find.text(kBookViewUseTabby));
    await tester.pump();
    expect(useTabbySwitch(tester).value, isFalse);
    expect(find.text('8 picks in 8 rows'), findsOneWidget);
    expect(find.text('Role: pattern'), findsNWidgets(4));
    expect(find.text('Role: tabby'), findsNWidgets(4));
    expect(find.text('Treadle 3'), findsNWidgets(2));
  });

  testWidgets('a broken alternation falls back to every pick and says which picks', (tester) async {
    final doc = generatedOvershot();
    await pumpBook(tester, doc.copyWith(pickRoles: [...doc.pickRoles]..[2] = PickRole.tabby));
    expect(useTabbySwitch(tester).value, isFalse);
    expect(useTabbySwitch(tester).onChanged, isNull);
    expect(
        find.text('Use tabby shorthand needs pattern and tabby picks to alternate. Picks 2 and 3 '
            'are both tabby picks.'),
        findsOneWidget);
    expect(find.text('8 picks in 8 rows'), findsOneWidget);
  });

  testWidgets('a Use tabby count edit commits exactly the expanded picks, as one undo entry',
      (tester) async {
    final c = await pumpBook(tester, generatedOvershot());
    await tester.tap(find.text('Picks 1 to 3'));
    await tester.pump();
    expect(find.text('Editing row 1, picks 1 to 3'), findsOneWidget);
    expect(find.text(kUseTabbyCountNote), findsOneWidget);
    await tester.tap(find.byTooltip('More pattern picks in this row'));
    await tester.pump();
    expect(treadles(c), [1, 3, 1, 4, 1, 3, 2, 4, 2, 3]);
    expect(draft(c).pickRoles.length, 10);
    expect(find.text('10 picks: 5 pattern picks in 2 rows and 5 tabby picks'), findsOneWidget);
    expect(find.text('Editing row 1, picks 1 to 5'), findsOneWidget, reason: 'selection follows');
    // Book and full mode agree: the shorthand read back from the stored picks is what was edited.
    final b = readUseTabby(draft(c)) as UseTabbyBook;
    expect(b.expand().matches(draft(c)), isTrue);
    expect(c.read(draftEditorProvider).undo.length, 1);
    c.read(draftEditorProvider.notifier).undo();
    await tester.pump();
    expect(draft(c), generatedOvershot());
  });

  testWidgets('a Use tabby edit that cannot stay exact is refused with its reason', (tester) async {
    final c = await pumpBook(tester, generatedOvershot(picks: 4)); // one pattern row
    await tester.tap(find.text('Picks 1 to 3'));
    await tester.pump();
    await tester.tap(find.text('Delete these pattern picks'));
    await tester.pump();
    expect(find.text(kUseTabbyLastRow), findsOneWidget, reason: 'shown under the row');
    expect(find.byKey(const ValueKey('use-tabby-refusal')), findsOneWidget);
    expect(draft(c), generatedOvershot(picks: 4), reason: 'nothing changed');
    expect(c.read(draftEditorProvider).undo, isEmpty);
  });

  testWidgets('a Use tabby treadle change applies to every pattern pick of the row', (tester) async {
    final c = await pumpBook(tester, generatedOvershot());
    await tester.tap(find.text('Picks 5 to 7'));
    await tester.pump();
    await tester.tap(find.byTooltip('Previous treadle')); // 2 -> 1: the rows merge
    await tester.pump();
    expect(treadles(c), [1, 3, 1, 4, 1, 3, 1, 4]);
    expect(find.text('8 picks: 4 pattern picks in 1 row and 4 tabby picks'), findsOneWidget);
  });

  testWidgets('set the role of a whole row, then of one pick in it', (tester) async {
    final doc = generatedOvershot(roles: false).copyWith(
      drive: DraftTreadled(tieup: kOvershotTieup, treadling: const [
        [1],
        [1],
        [1],
        [3],
      ]),
      weftColors: const [1, 1, 1, 0],
    );
    final c = await pumpBook(tester, doc);
    await tester.tap(find.text('Picks 1 to 3'));
    await tester.pump();
    expect(find.text('Role of all 3 picks'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('row-role-pattern')));
    await tester.pump();
    expect(draft(c).pickRoles,
        const [PickRole.pattern, PickRole.pattern, PickRole.pattern, PickRole.unknown]);
    expect(find.text('Role: pattern'), findsOneWidget);
    // One pick: step to pick 2 and mark it tabby.
    expect(find.text('Role of pick 1'), findsOneWidget);
    await tester.tap(find.byTooltip('Next pick in this row'));
    await tester.pump();
    expect(find.text('Role of pick 2'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('pick-role-tabby')));
    await tester.pump();
    expect(draft(c).pickRoles,
        const [PickRole.pattern, PickRole.tabby, PickRole.pattern, PickRole.unknown]);
    expect(find.text('Roles: pattern, tabby, pattern'), findsOneWidget);
    expect(c.read(draftEditorProvider).undo.length, 2, reason: 'one undo entry per role edit');
  });

  testWidgets('Mark tabby picks proposes, changes nothing on Cancel, and applies on confirm',
      (tester) async {
    final c = await pumpBook(tester, generatedOvershot(roles: false));
    expect(useTabbySwitch(tester).onChanged, isNull, reason: 'no roles yet');
    await tester.tap(find.text(kMarkTabbyPicks));
    await tester.pumpAndSettle();
    expect(
        find.text('Picks 2, 4, 6 and 8 use a plain-weave (tabby) shed (treadle 3 or treadle 4) and '
            'will be marked tabby.'),
        findsOneWidget);
    expect(find.text('Also mark the other picks with no role as pattern'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(draft(c).pickRoles, isEmpty, reason: 'a proposal never runs silently');

    await tester.tap(find.text(kMarkTabbyPicks));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Also mark the other picks with no role as pattern'));
    await tester.pump();
    await tester.tap(find.text('Mark picks'));
    await tester.pumpAndSettle();
    expect(draft(c), generatedOvershot(), reason: 'exactly the generator roles');
    expect(c.read(draftEditorProvider).undo.length, 1);
    // The shorthand is now available and shown.
    expect(useTabbySwitch(tester).value, isTrue);
    expect(find.text('Use tabby'), findsOneWidget);
  });

  testWidgets('Mark tabby picks on a draft with no tabby shed says so', (tester) async {
    final twill = generatedOvershot(roles: false).copyWith(
      threading: [
        for (var i = 0; i < 8; i++) [i % 4 + 1],
      ],
      drive: DraftTreadled(tieup: const [
        [1, 2],
        [2, 3],
        [3, 4],
        [4, 1],
      ], treadling: [
        for (var p = 0; p < 8; p++) [p % 4 + 1],
      ]),
    );
    final c = await pumpBook(tester, twill);
    await tester.tap(find.text(kMarkTabbyPicks));
    await tester.pump();
    expect(find.text(kMarkTabbyNone), findsOneWidget);
    expect(find.byKey(const ValueKey('mark-tabby-notice')), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(draft(c).pickRoles, isEmpty);
  });
}
