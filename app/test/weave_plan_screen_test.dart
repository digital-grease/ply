import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/library_backup.dart' show BackupCraft;
import 'package:ply/src/data/project_links_repository.dart';
import 'package:ply/src/data/weave_plan_repository.dart';
import 'package:ply/src/models/draft_doc.dart';
import 'package:ply/src/models/loom_check.dart';
import 'package:ply/src/models/loom_profile.dart';
import 'package:ply/src/models/loom_type.dart';
import 'package:ply/src/models/material_record.dart';
import 'package:ply/src/models/project_materials.dart';
import 'package:ply/src/models/weave_plan.dart';
import 'package:ply/src/screens/weave_plan_screen.dart';
import 'package:ply/src/state/draft_editor_notifier.dart';
import 'package:ply/src/state/loom_providers.dart';
import 'package:ply/src/state/material_providers.dart';
import 'package:ply/src/state/weave_plan_providers.dart';

import 'loom_test_support.dart';
import 'materials_test_support.dart';
import 'planning_sheet_test.dart' show fourEnds;

// The warp and weft plan screen (ADR 0019) over the towel acceptance fixture: every assumption is
// shown with its source and its denominator, every figure with its working, the denting, the loom
// checks and the yarn against what is on hand; one assumption is overridden and set back without
// touching the swatch. Host tests have no engine, so the worksheet is the fixture's own oracle
// (fixtures/weaving/plans/towel.expect.json, the numbers the Rust tests hold the engine to).

const String dir = '../fixtures/weaving/plans';

Map<String, dynamic> readJson(String path) =>
    jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;

final Map<String, dynamic> towelInput = readJson('$dir/towel.plan.json');
final Map<String, dynamic> towelExpect = readJson('$dir/towel.expect.json');

WeavePlan towelPlan(String name) => WeavePlan.fromJson((towelInput['cases'] as List)
    .cast<Map<String, dynamic>>()
    .firstWhere((c) => c['name'] == name)['plan'])!;

LengthUnit? unitOf(Object? s) => s == 'count' ? null : LengthUnit.bySymbol(s);

Length lengthOf(Map m) => Length((m['value'] as num).toDouble(), LengthUnit.bySymbol(m['unit'])!);

/// The fixture's oracle for [name] as the worksheet the engine returns.
PlanWorksheet towelSheet(String name) {
  final c = (towelExpect['cases'] as Map)[name] as Map<String, dynamic>;
  final d = c['denting'] as Map?;
  return PlanWorksheet(
    inputs: [
      for (final i in (c['inputs'] as List).cast<Map>())
        TracedInput(
          key: i['key'] as String,
          label: i['label'] as String,
          value: i['value'] as String,
          source: ValueSource.bySerialName(i['source'])!,
          basis: i['basis'] as String,
        ),
    ],
    figures: [
      for (final f in (c['figures'] as List).cast<Map>())
        PlanFigure(
          key: f['key'] as String,
          label: f['label'] as String,
          value: (f['value'] as num).toDouble(),
          lengthUnit: unitOf(f['unit']),
          text: f['text'] as String,
          working: ['Working for ${f['key']}.'],
          uses: const ['finished_width'],
          assumed: f['assumed'] as bool,
        ),
    ],
    denting: d == null
        ? null
        : DentingPlan(
            reed: Reed((d['reed']['dents'] as num).toDouble(),
                d['reed']['per'] == 'inch' ? DentUnit.perInch : DentUnit.per10cm),
            order: (d['order'] as List).cast<int>(),
            dents: d['dents'] as int,
            width: lengthOf(d['width'] as Map),
            exact: true,
            text: d['text'] as String,
          ),
    checks: [
      for (final k in (c['checks'] as List).cast<Map>())
        PlanCheck(
          code: k['code'] as String,
          severity: switch (k['severity']) {
            'fits' => LoomSeverity.fits,
            'advice' => LoomSeverity.advice,
            'not_checked' => LoomSeverity.notChecked,
            _ => LoomSeverity.notFeasible,
          },
          message: k['message'] as String,
        ),
    ],
    supply: [
      for (final s in (c['supply'] as List).cast<Map>())
        SupplyLine(
          role: s['role'] == 'warp' ? SupplyRole.warp : SupplyRole.weft,
          materialId: s['material_id'] as String,
          materialName: '',
          need: lengthOf(s['need'] as Map),
          remaining: lengthOf(s['remaining'] as Map),
          text: s['text'] as String,
          assumed: s['assumed'] as bool,
        ),
    ],
    issues: [
      for (final i in (c['issues'] as List).cast<Map>())
        PlanIssue(
          code: i['code'] as String,
          kind: i['kind'] == 'invalid' ? PlanIssueKind.invalid : PlanIssueKind.needed,
          field: i['field'] as String,
          message: i['message'] as String,
        ),
    ],
    inputNotes: [
      for (final n in (c['input_notes'] as List).cast<Map>())
        PlanInputNote(n['key'] as String, n['text'] as String),
    ],
    notes: (c['notes'] as List).cast<String>(),
  );
}

/// The engine stand-in: answers each plan with the fixture case it matches, and records what it was
/// asked.
class FakeWeavePlanRepository extends WeavePlanRepository {
  final List<
      ({
        WeavePlan plan,
        SwatchRecord? swatch,
        MaterialRecord? warp,
        MaterialRecord? weft,
        PlanDraftFacts? draft
      })> asked = [];

  @override
  Future<PlanWorksheet> workOut({
    required WeavePlan plan,
    SwatchRecord? swatch,
    MaterialRecord? warp,
    MaterialRecord? weft,
    LoomProfile? loom,
    Sett? loomSett,
    PlanDraftFacts? draft,
    required bool metric,
  }) async {
    asked.add((plan: plan, swatch: swatch, warp: warp, weft: weft, draft: draft));
    final takeUp = plan.overrides.value<double>(PlanAssumption.takeUp);
    return towelSheet(takeUp == null
        ? 'from_swatch'
        : takeUp >= 1
            ? 'take_up_impossible'
            : 'take_up_overridden');
  }
}

/// Links that take a while to read, as the sidecar read on a device does.
class SlowLinks extends FakeProjectLinks {
  SlowLinks(super.sidecars);

  @override
  Future<ProjectMaterials> read(BackupCraft craft, String id) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return super.read(craft, id);
  }
}

final Map<String, dynamic> records = towelInput['materials'] as Map<String, dynamic>;
final List<MaterialRecord> towelMaterials = [
  for (final m in (records['materials'] as List).cast<Map>()) materialFromMap(m),
];
final List<SwatchRecord> towelSwatches = [
  for (final s in (records['swatches'] as List).cast<Map>()) swatchFromMap(s),
];
const LoomProfile jack = LoomProfile(
  id: 'fixture-four-shaft-jack',
  name: 'Four-shaft jack loom',
  type: LoomType.jack,
  shafts: 4,
  treadles: 6,
  weavingWidth: LoomLength(24, MeasureUnit.inches),
  reeds: [Reed(12, DentUnit.perInch), Reed(10, DentUnit.perInch)],
  treadlesAtOnce: 2,
);

Future<(ProviderContainer, FakeWeavePlanRepository, FakeMaterialsRepository)> pumpPlan(
    WidgetTester t,
    {WeavePlan? plan,
    bool locked = false,
    ProjectLinksRepository? links,
    List<SwatchRecord>? swatches,
    Size size = const Size(420, 6000)}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  final engine = FakeWeavePlanRepository();
  final materials =
      FakeMaterialsRepository(materials: towelMaterials, swatches: swatches ?? towelSwatches);
  final c = ProviderContainer(overrides: [
    weavePlanRepositoryProvider.overrideWithValue(engine),
    materialsRepositoryProvider.overrideWithValue(materials),
    projectLinksRepositoryProvider.overrideWithValue(links ?? FakeProjectLinks()),
    loomRepositoryProvider.overrideWithValue(FakeLoomRepository(looms: [jack])),
  ]);
  addTearDown(c.dispose);
  c.read(draftEditorProvider.notifier).load(fourEnds());
  c.read(draftLoomPlanProvider.notifier).state = LoomPlan(loomId: jack.id, loomName: jack.name);
  c.read(draftWeavePlanProvider.notifier).state = plan;
  c.read(draftWeavePlanLockedProvider.notifier).state = locked;
  await t.pumpWidget(UncontrolledProviderScope(
      container: c, child: const MaterialApp(home: WeavePlanScreen(projectId: 'd1'))));
  await t.pumpAndSettle();
  return (c, engine, materials);
}

Finder input(String key) => find.byKey(ValueKey('input-$key'));

String inputText(WidgetTester t, String key) => t.widget<Text>(input(key)).data!;

void main() {
  testWidgets('every assumption shows its source and denominator, every figure its value',
      (t) async {
    final (_, engine, _) = await pumpPlan(t, plan: towelPlan('from_swatch'));
    expect(find.text(kWeavePlanTitle), findsOneWidget);
    // The engine got the plan with the records it names, read from the library.
    final ask = engine.asked.last;
    expect(ask.swatch?.id, 'sw-towel-plan');
    expect(ask.warp?.id, 'cotton-natural');
    expect(ask.weft?.id, 'cotton-blue');
    expect(
        inputText(t, 'length_loss'),
        'Take-up and shrinkage: 10% of the length on the loom, from the loom to finished, from 20 '
        'in on the loom and 18 in after wet finishing (measured), swatch Towel sample 2026-11-03');
    expect(inputText(t, 'width_loss'), contains('12.5% of the width in the reed'));
    expect(inputText(t, 'weft_allowance'), contains("Ply's starting estimate for twill"));
    // The source badges say where each came from.
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('assumption-length_loss')),
            matching: find.text('Measured')),
        findsOneWidget);
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('assumption-weft_allowance')),
            matching: find.text('Ply default')),
        findsOneWidget);
    // Combined from the swatch: each part can still be overridden on its own.
    expect(find.byKey(const ValueKey('change-takeUp')), findsOneWidget);
    expect(find.byKey(const ValueKey('change-lengthShrinkage')), findsOneWidget);
    expect(find.text('Warp ends: 494 ends'), findsOneWidget);
    expect(find.text('Width in the reed: 20.58 in (52.28 cm)'), findsOneWidget);
    expect(find.text('Warp yarn: 2444.08 yd (2234.87 m)'), findsOneWidget);
    expect(find.text('Weft yarn: 2281.78 yd (2086.46 m)'), findsOneWidget);
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('figure-weft_yarn')),
            matching: find.text("Uses Ply's starting estimates")),
        findsOneWidget);
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('figure-warp_yarn')),
            matching: find.text("Uses Ply's starting estimates")),
        findsNothing);
    expect(find.textContaining('494 ends fill 247 dents'), findsOneWidget);
    expect(find.text('Sley the 12-dent reed 2 per dent for 24 ends per in.'), findsOneWidget);
    expect(find.byKey(const ValueKey('check-plan.loom_width_fits')), findsOneWidget);
    expect(find.textContaining('8/2 cotton, natural for warp: needs about 2444.08 yd'),
        findsOneWidget);
    expect(find.textContaining('This draft threads 8 ends'), findsOneWidget);
    // The swatch's parts are explained next to the input they explain.
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('assumption-length_loss')),
            matching:
                find.textContaining('Of that, swatch Towel sample 2026-11-03 measured take-up')),
        findsOneWidget);
    // The weft line rests on Ply's weft allowance and says so; the warp line does not.
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('supply-cotton-blue')),
            matching: find.text("Uses Ply's starting estimates")),
        findsOneWidget);
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('supply-cotton-natural')),
            matching: find.text("Uses Ply's starting estimates")),
        findsNothing);
    // Each action is offered once.
    for (final key in ['change-reed', 'change-ends', 'change-takeUp', 'change-loomWaste']) {
      expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
    }
    // A figure opens to its working.
    await t.tap(find.text('Warp ends: 494 ends'));
    await t.pumpAndSettle();
    expect(find.text('Working for warp_ends.'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('one assumption is overridden and set back, and the swatch is never changed',
      (t) async {
    final (c, engine, materials) = await pumpPlan(t, plan: towelPlan('from_swatch'));
    final swatchBefore = c.read(materialLibraryProvider).value!.swatch('sw-towel-plan');
    await t.tap(find.byKey(const ValueKey('change-takeUp')));
    await t.pumpAndSettle();
    // The dialog says what the figure is a share of.
    expect(find.textContaining('as a share of the length on the loom'), findsOneWidget);
    // An impossible take-up is refused in the dialog.
    await t.enterText(find.byKey(const ValueKey('override-value')), '100');
    await t.tap(find.text('Use this value'));
    await t.pumpAndSettle();
    expect(find.text('Enter a number from -50 to 90.'), findsOneWidget);
    expect(c.read(draftWeavePlanProvider)!.overrides.has(PlanAssumption.takeUp), isFalse);
    await t.enterText(find.byKey(const ValueKey('override-value')), '12');
    await t.tap(find.text('Use this value'));
    await t.pumpAndSettle();
    final plan = c.read(draftWeavePlanProvider)!;
    expect(plan.overrides.value<double>(PlanAssumption.takeUp), 0.12);
    // Only that one changed: the rest of the plan is as it was.
    expect(plan.copyWith(overrides: plan.overrides.set(PlanAssumption.takeUp, null)),
        towelPlan('from_swatch'));
    expect(engine.asked.last.plan, plan);
    expect(inputText(t, 'take_up'), 'Take-up: 12% of the length on the loom, you entered it');
    expect(inputText(t, 'length_shrinkage'), contains('measured'));
    expect(find.text('Warp yarn: 2609.02 yd (2385.69 m)'), findsOneWidget);
    // The swatch is read, never written.
    expect(materials.saves, 0);
    expect(c.read(materialLibraryProvider).value!.swatch('sw-towel-plan'), swatchBefore);
    expect(engine.asked.last.swatch, swatchBefore);
    // The way back to the swatch.
    await t.tap(find.byKey(const ValueKey('reset-takeUp')));
    await t.pumpAndSettle();
    expect(c.read(draftWeavePlanProvider), towelPlan('from_swatch'));
    expect(input('length_loss'), findsOneWidget);
    expect(find.text('Warp yarn: 2444.08 yd (2234.87 m)'), findsOneWidget);
    expect(materials.saves, 0);
  });

  testWidgets('an override that cannot be used has a way back from its issue', (t) async {
    final (c, _, _) = await pumpPlan(t, plan: towelPlan('take_up_impossible'));
    final issue = find.byKey(const ValueKey('issue-plan.out_of_range-take_up'));
    expect(find.descendant(of: issue, matching: find.byKey(const ValueKey('change-takeUp'))),
        findsOneWidget);
    final reset = find.descendant(of: issue, matching: find.byKey(const ValueKey('reset-takeUp')));
    expect(reset, findsOneWidget);
    expect(find.descendant(of: reset, matching: find.text('Use the swatch')), findsOneWidget);
    await t.tap(reset);
    await t.pumpAndSettle();
    expect(c.read(draftWeavePlanProvider), towelPlan('from_swatch'));
    expect(find.byKey(const ValueKey('issue-plan.out_of_range-take_up')), findsNothing);
    expect(find.text('Warp yarn: 2444.08 yd (2234.87 m)'), findsOneWidget);
  });

  testWidgets('a reset says Ply\'s estimate when the swatch is not there to fall back to',
      (t) async {
    // The plan names the towel sample, but this library has no swatches.
    await pumpPlan(t, plan: towelPlan('take_up_overridden'), swatches: const []);
    final reset = find.byKey(const ValueKey('reset-takeUp'));
    expect(find.descendant(of: reset, matching: find.text("Use Ply's estimate")), findsOneWidget);
  });

  testWidgets('a new plan starts from the draft\'s links once they have loaded', (t) async {
    final links = SlowLinks({
      'drafts/d1': {
        'name': 'Towels',
        ProjectMaterials.key: {
          'yarns': [
            {'materialId': 'cotton-natural', 'materialName': '8/2 cotton, natural', 'role': 'warp'},
            {'materialId': 'cotton-blue', 'materialName': '8/2 cotton, blue', 'role': 'weft'},
          ],
          'swatches': [
            {'swatchId': 'sw-towel-plan', 'swatchName': 'Towel sample'}
          ],
        },
      },
    });
    final (c, engine, _) = await pumpPlan(t, links: links);
    final ask = engine.asked.last;
    expect(ask.swatch?.id, 'sw-towel-plan');
    expect(ask.warp?.id, 'cotton-natural');
    expect(ask.weft?.id, 'cotton-blue');
    expect(ask.draft?.ends, 4, reason: "the draft's facts, not the draft");
    expect(find.text('Towel sample (2026-11-03), linked'), findsOneWidget);
    // Seeding stores nothing: the draft is unchanged until the weaver edits.
    expect(c.read(draftWeavePlanProvider), isNull);
  });

  testWidgets('an issue names the field, and the figures that need it are left out', (t) async {
    final plan = towelPlan('take_up_impossible');
    await pumpPlan(t, plan: plan);
    expect(find.byKey(const ValueKey('issue-plan.out_of_range-take_up')), findsOneWidget);
    expect(find.text('The take-up must be from -50% to 90% of the length on the loom.'),
        findsOneWidget);
    expect(find.textContaining('Warp ends: 494 ends'), findsOneWidget);
    expect(find.textContaining('Warp yarn:'), findsNothing);
  });

  testWidgets('the finished size and the choices change the plan', (t) async {
    final (c, _, _) = await pumpPlan(t);
    // No plan yet: nothing is stored until the weaver changes something.
    expect(c.read(draftWeavePlanProvider), isNull);
    await t.enterText(find.byKey(const ValueKey('plan-finished-width')), '18');
    await t.pump();
    expect(c.read(draftWeavePlanProvider)!.finishedWidth, const Length(18, LengthUnit.inch));
    await t.enterText(find.byKey(const ValueKey('plan-finished-width')), '');
    await t.pump();
    expect(c.read(draftWeavePlanProvider)!.finishedWidth, isNull);
    await t.tap(find.byKey(const ValueKey('plan-swatch')));
    await t.pumpAndSettle();
    await t.tap(find.text('Towel sample (2026-11-03)').last);
    await t.pumpAndSettle();
    final p = c.read(draftWeavePlanProvider)!;
    expect(p.swatchId, 'sw-towel-plan');
    expect(p.swatchName, 'Towel sample');
    await t.tap(find.byKey(const ValueKey('plan-structure')));
    await t.pumpAndSettle();
    await t.tap(find.text('Twill').last);
    await t.pumpAndSettle();
    expect(c.read(draftWeavePlanProvider)!.structure, PlanStructure.twill);
  });

  testWidgets('removing the plan asks first and takes the key out', (t) async {
    final (c, _, _) = await pumpPlan(t, plan: towelPlan('from_swatch'));
    await t.tap(find.byTooltip('Remove this plan'));
    await t.pumpAndSettle();
    expect(find.textContaining('Your swatches and materials are not changed'), findsOneWidget);
    await t.tap(find.text('Remove'));
    await t.pumpAndSettle();
    expect(c.read(draftWeavePlanProvider), isNull);
  });

  testWidgets('a plan from a newer Ply is kept and not offered for replacing', (t) async {
    await pumpPlan(t, locked: true);
    expect(find.byKey(const ValueKey('plan-locked')), findsOneWidget);
    expect(find.byKey(const ValueKey('plan-finished-width')), findsNothing);
  });

  testWidgets('a record that is gone is named, not dropped', (t) async {
    final plan = towelPlan('from_swatch')
        .copyWith(swatchId: 'deleted', swatchName: 'Old sample', warpMaterialId: 'gone');
    await pumpPlan(t, plan: plan);
    expect(find.textContaining('"Old sample", is not in your materials'), findsOneWidget);
    expect(find.textContaining('The warp yarn this plan names'), findsOneWidget);
  });

  testWidgets('works at phone width', (t) async {
    await pumpPlan(t, plan: towelPlan('from_swatch'), size: const Size(320, 8000));
    expect(t.takeException(), isNull);
    expect(find.text('Warp ends: 494 ends'), findsOneWidget);
  });
}
