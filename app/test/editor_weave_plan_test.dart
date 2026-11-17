import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/models/draft_meta.dart';
import 'package:ply/src/models/material_record.dart';
import 'package:ply/src/models/weave_plan.dart';
import 'package:ply/src/screens/editor_screen.dart';
import 'package:ply/src/screens/weave_plan_screen.dart';
import 'package:ply/src/state/editor_providers.dart';
import 'package:ply/src/state/loom_providers.dart';
import 'package:ply/src/state/material_providers.dart';
import 'package:ply/src/state/weave_plan_providers.dart';

import 'editor_screen_test.dart' show FakeRepo, letAsyncSettle;
import 'loom_test_support.dart';
import 'materials_test_support.dart';
import 'weave_plan_screen_test.dart' show FakeWeavePlanRepository, towelPlan;

// The warp and weft plan in the weaving editor (ADR 0019): offered from the More menu, saved with
// the draft like the loom choice (an untouched plan kept as it was, a changed one is unsaved work,
// a removed one leaves the sidecar), and a plan from a newer Ply kept in the sidecar as it is.

DraftMeta metaWith({WeavePlan? plan, Map<String, Object?> extra = const {}}) => DraftMeta(
      name: 'Towels',
      savedAt: DateTime.utc(2026),
      lastOpened: DateTime.utc(2026),
      weavePlan: plan,
      extra: extra,
    );

Future<void> pumpEditorWithPlan(WidgetTester tester,
    {required FakeRepo drafts, required DraftMeta meta}) async {
  tester.view.physicalSize = const Size(420, 1800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    overrides: [
      repositoryProvider.overrideWithValue(drafts),
      loomRepositoryProvider.overrideWithValue(FakeLoomRepository()),
      weavePlanRepositoryProvider.overrideWithValue(FakeWeavePlanRepository()),
      materialsRepositoryProvider.overrideWithValue(FakeMaterialsRepository()),
      projectLinksRepositoryProvider.overrideWithValue(FakeProjectLinks()),
    ],
    child: MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => Navigator.push<bool>(
                context,
                MaterialPageRoute<bool>(
                  builder: (_) =>
                      EditorScreen(wifText: 'WIF', title: 'Towels', id: 'd1', meta: meta),
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

ProviderContainer containerOf(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(EditorScreen)));

void main() {
  testWidgets('the plan is offered from the menu and an untouched plan is kept on save',
      (tester) async {
    final drafts = FakeRepo();
    final plan = towelPlan('from_swatch');
    await pumpEditorWithPlan(tester, drafts: drafts, meta: metaWith(plan: plan));
    expect(containerOf(tester).read(draftWeavePlanProvider), plan,
        reason: 'seeded from the sidecar');
    await tester.tap(find.byTooltip('More actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('$kWeavePlanTitle…'));
    await tester.pumpAndSettle();
    expect(find.byType(WeavePlanScreen), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.save_outlined));
    await letAsyncSettle(tester);
    expect(drafts.capturedMeta!.weavePlan, plan);
    expect(drafts.capturedSourceWif, 'WIF', reason: 'the WIF is saved verbatim, never with a plan');
  });

  testWidgets('a changed plan is unsaved work, and Save writes it', (tester) async {
    final drafts = FakeRepo();
    await pumpEditorWithPlan(tester, drafts: drafts, meta: metaWith());
    final c = containerOf(tester);
    expect(c.read(draftWeavePlanProvider), isNull);
    final plan = WeavePlan(finishedWidth: const Length(25, LengthUnit.centimeter));
    c.read(draftWeavePlanProvider.notifier).state = plan;
    await tester.pump();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Leave without saving?'), findsOneWidget);
    await tester.tap(find.text('Keep editing'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.save_outlined));
    await letAsyncSettle(tester);
    expect(drafts.capturedMeta!.weavePlan, plan);
    expect(drafts.capturedMeta!.toJson()[WeavePlan.key], plan.toJson());
  });

  testWidgets('a removed plan leaves the sidecar', (tester) async {
    final drafts = FakeRepo();
    await pumpEditorWithPlan(tester,
        drafts: drafts, meta: metaWith(plan: towelPlan('from_swatch')));
    containerOf(tester).read(draftWeavePlanProvider.notifier).state = null;
    await tester.pump();
    await tester.tap(find.byIcon(Icons.save_outlined));
    await letAsyncSettle(tester);
    expect(drafts.capturedMeta!.weavePlan, isNull);
    expect(drafts.capturedMeta!.toJson().containsKey(WeavePlan.key), isFalse);
  });

  testWidgets('a plan from a newer Ply stays in the sidecar through a save', (tester) async {
    final drafts = FakeRepo();
    final newer = {'version': 2, 'fromLater': true};
    await pumpEditorWithPlan(tester, drafts: drafts, meta: metaWith(extra: {WeavePlan.key: newer}));
    expect(containerOf(tester).read(draftWeavePlanLockedProvider), isTrue);
    await tester.tap(find.byIcon(Icons.save_outlined));
    await letAsyncSettle(tester);
    expect(drafts.capturedMeta!.toJson()[WeavePlan.key], newer);
  });
}
