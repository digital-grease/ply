import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/loom_repository.dart' show LoomFileStatus;
import 'package:ply/src/models/draft_doc.dart' show MeasureUnit;
import 'package:ply/src/models/draft_meta.dart';
import 'package:ply/src/models/loom_check.dart';
import 'package:ply/src/screens/editor_screen.dart';
import 'package:ply/src/state/editor_providers.dart';
import 'package:ply/src/state/loom_providers.dart';
import 'package:ply/src/widgets/loom_check_panel.dart';

import 'editor_screen_test.dart' show FakeRepo, letAsyncSettle;
import 'loom_test_support.dart';

// The weaving editor's loom group (ADR 0014): its own band under the structural validation, only
// when the draft names a loom; the choice is made in "Loom for this draft" and saved in the sidecar;
// it never gates saving; with no looms and no choice the editor is unchanged.

DraftMeta metaWith({LoomPlan? plan}) => DraftMeta(
      name: 'Twill',
      savedAt: DateTime.utc(2026),
      lastOpened: DateTime.utc(2026),
      loomPlan: plan,
    );

Future<void> pumpEditorWithLooms(
  WidgetTester tester, {
  required FakeRepo drafts,
  required FakeLoomRepository looms,
  DraftMeta? meta,
}) async {
  // A tall phone: the stacked layout, with room for every row of the expanded loom group.
  tester.view.physicalSize = const Size(420, 1800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    overrides: [
      repositoryProvider.overrideWithValue(drafts),
      loomRepositoryProvider.overrideWithValue(looms),
    ],
    child: MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => Navigator.push<bool>(
                context,
                MaterialPageRoute<bool>(
                  builder: (_) => EditorScreen(
                      wifText: 'WIF', title: 'Twill', id: 'd1', meta: meta ?? metaWith()),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await letAsyncSettle(tester);
}

Future<void> openMenu(WidgetTester tester) async {
  await tester.tap(find.byTooltip('More actions'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('with no looms and no choice the editor looks as it did', (tester) async {
    await pumpEditorWithLooms(tester, drafts: FakeRepo(), looms: FakeLoomRepository());
    expect(find.byKey(const ValueKey('loom-check-panel')), findsNothing);
    await openMenu(tester);
    expect(find.textContaining('Loom for this draft'), findsNothing);
  });

  testWidgets('a draft planned for a loom shows its own loom group, apart from validation',
      (tester) async {
    final looms = FakeLoomRepository(looms: [floorLoom], report: notFeasibleReport);
    await pumpEditorWithLooms(tester,
        drafts: FakeRepo(),
        looms: looms,
        meta: metaWith(plan: LoomPlan(loomId: floorLoom.id, loomName: 'Floor loom')));
    expect(find.text('On Floor loom: not feasible, needs 8 shafts, has 4'), findsOneWidget);
    expect(looms.lastChecked, floorLoom);
    // Collapsed: the sentences are not listed yet.
    expect(find.text('This draft threads 8 shafts; Floor loom has 4.'), findsNothing);
    await tester.tap(find.text('On Floor loom: not feasible, needs 8 shafts, has 4'));
    await tester.pumpAndSettle();
    final blocked = find.text('This draft threads 8 shafts; Floor loom has 4.');
    expect(blocked, findsOneWidget);
    expect(find.text('Weave it on a loom with at least 8 shafts, or choose a draft for 4 shafts.'),
        findsOneWidget);
    // Not feasible first, fits last.
    final fits = find.textContaining('Floor loom weaves up to 24 in.');
    expect(tester.getTopLeft(blocked).dy, lessThan(tester.getTopLeft(fits).dy));
    // Each row says its severity in words, not color alone.
    expect(find.bySemanticsLabel(RegExp(r'^Not feasible: This draft threads 8 shafts')),
        findsOneWidget);
    expect(loomSeverityWord(LoomSeverity.notChecked), 'Not checked');
  });

  testWidgets('not feasible never gates saving', (tester) async {
    final drafts = FakeRepo();
    final plan = LoomPlan(loomId: floorLoom.id, loomName: 'Floor loom');
    await pumpEditorWithLooms(tester,
        drafts: drafts,
        looms: FakeLoomRepository(looms: [floorLoom], report: notFeasibleReport),
        meta: metaWith(plan: plan));
    await tester.tap(find.byIcon(Icons.save_outlined));
    await letAsyncSettle(tester);
    expect(drafts.sawSave, isTrue);
    expect(find.text('Save with problems?'), findsNothing);
    expect(drafts.capturedMeta!.loomPlan, plan, reason: 'an untouched choice is kept as it was');
  });

  testWidgets('choosing a loom and a sett is saved with the draft', (tester) async {
    final drafts = FakeRepo();
    final looms = FakeLoomRepository(looms: [floorLoom, borrowedLoom], report: notFeasibleReport);
    await pumpEditorWithLooms(tester, drafts: drafts, looms: looms);
    await openMenu(tester);
    await tester.tap(find.text('Loom for this draft…'));
    await tester.pumpAndSettle();
    expect(find.text('No loom'), findsOneWidget);
    expect(find.text('Borrowed loom'), findsOneWidget);
    await tester.tap(find.text('Floor loom'));
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('loom-plan-sett')), '24');
    await tester.tap(find.text('Done'));
    await letAsyncSettle(tester);

    expect(find.text('On Floor loom: not feasible, needs 8 shafts, has 4'), findsOneWidget);
    expect(looms.lastSett, const Sett(24, MeasureUnit.inches));

    // A changed choice is unsaved work: leaving asks first.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Leave without saving?'), findsOneWidget);
    await tester.tap(find.text('Keep editing'));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.save_outlined));
    await letAsyncSettle(tester);
    final saved = drafts.capturedMeta!;
    expect(saved.loomPlan!.loomId, floorLoom.id);
    expect(saved.loomPlan!.loomName, 'Floor loom');
    expect(saved.loomPlan!.sett, const Sett(24, MeasureUnit.inches));
    expect(drafts.capturedSourceWif, 'WIF', reason: 'the WIF itself is saved verbatim');
  });

  testWidgets('choosing No loom clears it from the sidecar', (tester) async {
    final drafts = FakeRepo();
    await pumpEditorWithLooms(tester,
        drafts: drafts,
        looms: FakeLoomRepository(looms: [floorLoom], report: notFeasibleReport),
        meta: metaWith(plan: LoomPlan(loomId: floorLoom.id, loomName: 'Floor loom')));
    await tester.tap(find.byTooltip('Change the loom'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('No loom'));
    await tester.pump();
    await tester.tap(find.text('Done'));
    await letAsyncSettle(tester);
    expect(find.byKey(const ValueKey('loom-check-panel')), findsNothing);
    await tester.tap(find.byIcon(Icons.save_outlined));
    await letAsyncSettle(tester);
    expect(drafts.capturedMeta!.loomPlan, isNull);
    expect(drafts.capturedMeta!.toJson().containsKey('loomPlan'), isFalse);
  });

  testWidgets('a loom that is no longer in My looms is named, not checked', (tester) async {
    final looms = FakeLoomRepository(looms: [floorLoom]);
    await pumpEditorWithLooms(tester,
        drafts: FakeRepo(),
        looms: looms,
        meta: metaWith(plan: LoomPlan(loomId: 'gone', loomName: 'Old loom')));
    expect(find.text('Planned for Old loom, which is not in My looms.'), findsOneWidget);
    expect(looms.checks, 0);
    // The menu still offers the choice, so it can be changed or cleared.
    await openMenu(tester);
    expect(find.text('Loom for this draft…'), findsOneWidget);
  });

  testWidgets('on a wide screen the expanded loom group scrolls inside the side rail',
      (tester) async {
    await pumpEditorWithLooms(tester,
        drafts: FakeRepo(),
        looms: FakeLoomRepository(looms: [floorLoom], report: notFeasibleReport),
        meta: metaWith(plan: LoomPlan(loomId: floorLoom.id, loomName: 'Floor loom')));
    tester.view.physicalSize = const Size(1200, 560);
    await tester.pumpAndSettle();
    await tester.tap(find.text('On Floor loom: not feasible, needs 8 shafts, has 4'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: 'no overflow in the rail');
    expect(find.text('This draft threads 8 shafts; Floor loom has 4.'), findsOneWidget);
  });

  testWidgets('a stored sett is shown exactly, and Done with no change leaves nothing unsaved',
      (tester) async {
    final drafts = FakeRepo();
    final plan = LoomPlan(
        loomId: floorLoom.id, loomName: 'Floor loom', sett: const Sett(12.25, MeasureUnit.inches));
    await pumpEditorWithLooms(tester,
        drafts: drafts,
        looms: FakeLoomRepository(looms: [floorLoom], report: notFeasibleReport),
        meta: metaWith(plan: plan));
    await tester.tap(find.byTooltip('Change the loom'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, '12.25'), findsOneWidget);
    await tester.tap(find.text('Done'));
    await letAsyncSettle(tester);
    // Nothing changed: back leaves without asking.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Leave without saving?'), findsNothing);
  });

  testWidgets('a My looms from a newer Ply leaves the draft\'s loom not checked, not missing',
      (tester) async {
    final looms = FakeLoomRepository(status: LoomFileStatus.newer);
    await pumpEditorWithLooms(tester,
        drafts: FakeRepo(),
        looms: looms,
        meta: metaWith(plan: LoomPlan(loomId: floorLoom.id, loomName: 'Floor loom')));
    expect(
        find.text('Planned for Floor loom, not checked: My looms was saved by a newer version of '
            'Ply and cannot be used until Ply is updated.'),
        findsOneWidget);
    expect(find.textContaining('not in My looms'), findsNothing);
    expect(looms.checks, 0);
    await tester.tap(find.byTooltip('Change the loom'));
    await tester.pumpAndSettle();
    expect(
        find.text('My looms was saved by a newer version of Ply and cannot be used until Ply is '
            'updated.'),
        findsOneWidget);
    expect(find.text('You have no looms yet. Add them in Settings, under My looms.'), findsNothing);
    expect(find.text('Not checked: My looms cannot be used now'), findsOneWidget);
  });
}
