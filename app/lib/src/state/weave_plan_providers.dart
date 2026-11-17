// The open draft's warp, weft and finishing plan (ADR 0019) and its worksheet. The plan is session
// state of the weaving editor, seeded from the sidecar when the editor opens and saved with the
// draft (like the loom choice); the worksheet is worked out by the engine from the plan and the
// records it names each time any of them changes, latest wins.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/weave_plan_repository.dart';
import '../models/draft_doc.dart' show MeasureUnit;
import '../models/loom_check.dart' show Sett;
import '../models/weave_plan.dart';
import '../models/weft_work.dart' show meanStrands;
import 'draft_editor_notifier.dart';
import 'loom_providers.dart';
import 'material_providers.dart';
import 'theme_providers.dart' show appSettingsProvider;

final weavePlanRepositoryProvider = Provider<WeavePlanRepository>((_) => WeavePlanRepository());

/// The open draft's plan in this editor session (null = none yet). Seeded from the sidecar when the
/// editor opens and saved with the draft.
final draftWeavePlanProvider = StateProvider<WeavePlan?>((ref) => null);

/// True when the open draft's sidecar holds a plan this build cannot read (a newer version): the
/// worksheet then shows it is there and does not offer to replace it.
final draftWeavePlanLockedProvider = StateProvider<bool>((ref) => false);

/// What the worksheet reads from the open draft (its ends, strands per pick and file sett), worked
/// out once per draft change, so a plan call never carries the whole draft across the boundary.
final weavePlanDraftFactsProvider = FutureProvider.autoDispose<PlanDraftFacts>((ref) async {
  final draft = ref.watch(draftEditorProvider.select((s) => s.draft));
  Sett? fileSett;
  try {
    fileSett = await ref.read(loomRepositoryProvider).fileSett(draft);
  } catch (_) {/* the file's sett is optional */}
  return PlanDraftFacts(ends: draft.ends, meanStrands: meanStrands(draft), fileSett: fileSett);
});

/// The worksheet for [plan] with the records it names, the planned loom and the open draft's facts.
/// Each plan is its own family member, so the screen always shows the worksheet of the plan it
/// shows.
final weavePlanWorksheetProvider =
    FutureProvider.autoDispose.family<PlanWorksheet, WeavePlan>((ref, plan) async {
  final library = ref.watch(materialLibraryProvider).valueOrNull;
  final looms = ref.watch(loomLibraryProvider).valueOrNull;
  final loomPlan = ref.watch(draftLoomPlanProvider);
  final draft = await ref.watch(weavePlanDraftFactsProvider.future);
  final metric = ref.watch(appSettingsProvider.select((s) => s.unit == MeasureUnit.centimeters));
  final swatch = plan.swatchId == null ? null : library?.swatch(plan.swatchId!);
  final warp = plan.warpMaterialId == null ? null : library?.material(plan.warpMaterialId!);
  final weft = plan.weftMaterialId == null ? null : library?.material(plan.weftMaterialId!);
  final loom = loomPlan == null ? null : looms?.byId(loomPlan.loomId);
  return ref.read(weavePlanRepositoryProvider).workOut(
        plan: plan,
        swatch: swatch,
        warp: warp,
        weft: weft,
        loom: loom,
        loomSett: loomPlan?.sett,
        draft: draft,
        metric: metric,
      );
});
