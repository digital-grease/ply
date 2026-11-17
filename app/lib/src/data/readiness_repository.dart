// "Ready to make or share" (ADR 0021): one engine call per craft, mapped to the app's
// [ReadinessReport]. The only place in the app that touches the generated readiness symbols. Tests
// override [readinessRepositoryProvider] with canned reports (host tests have no native library).
//
// A new craft adds one method here (its bridge call, mapped through [ReadinessRepository.fromDto])
// and passes the report to `PdfExportJob(readiness: ...)`; the dialogs, the draft-copy marking and
// the file name come from the shared print flow.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/loom_check.dart' show Sett;
import '../models/loom_profile.dart';
import '../models/nalbind_recipe.dart';
import '../models/nalbind_recipe_view.dart' show recipeToDto;
import '../models/readiness.dart';
import '../rust/api.dart' as api;
import '../rust/dto.dart' show DraftDto, SeverityKind;
import '../rust/knit_dto.dart' show KnitPatternDto;
import '../rust/readiness_dto.dart' as wire;
import '../rust/weave_plan_dto.dart' show WeavePlanRequestDto;
import 'loom_repository.dart';

class ReadinessRepository {
  const ReadinessRepository();

  /// A weaving draft: its structure, the loom chosen for it (with the weaver's [sett]) and its warp
  /// and weft [plan] request, when it has one. Throws the engine's reason when the draft cannot be
  /// converted.
  Future<ReadinessReport> weave(
    DraftDto draft, {
    LoomProfile? loom,
    Sett? sett,
    WeavePlanRequestDto? plan,
  }) async =>
      fromDto(await api.weaveReadiness(
        draft: draft,
        loom: loom == null ? null : LoomRepository.loomToDto(loom),
        sett: sett == null ? null : LoomRepository.settToDto(sett),
        plan: plan,
      ));

  /// A knitting pattern: its chart, its sections and their stitch ledger.
  Future<ReadinessReport> knit(KnitPatternDto pattern) async =>
      fromDto(await api.knitReadiness(pattern: pattern));

  /// A nalbinding project: its [notation] (read strictly) and its [recipe].
  Future<ReadinessReport> nalbind(String notation, NalbindRecipe? recipe) async =>
      fromDto(await api.nalbindReadiness(
        notation: notation,
        recipe: recipe == null ? null : recipeToDto(recipe),
      ));

  static ReadinessLevel level(SeverityKind k) => switch (k) {
        SeverityKind.error => ReadinessLevel.error,
        SeverityKind.warning => ReadinessLevel.warning,
        SeverityKind.unsupported => ReadinessLevel.unsupported,
        SeverityKind.info => ReadinessLevel.info,
      };

  static ReadinessCheck check(wire.ReadinessCheckKind k) => switch (k) {
        wire.ReadinessCheckKind.draft => ReadinessCheck.draft,
        wire.ReadinessCheckKind.loom => ReadinessCheck.loom,
        wire.ReadinessCheckKind.plan => ReadinessCheck.plan,
        wire.ReadinessCheckKind.chart => ReadinessCheck.chart,
        wire.ReadinessCheckKind.sections => ReadinessCheck.sections,
        wire.ReadinessCheckKind.notation => ReadinessCheck.notation,
        wire.ReadinessCheckKind.stitch => ReadinessCheck.stitch,
        wire.ReadinessCheckKind.recipe => ReadinessCheck.recipe,
        wire.ReadinessCheckKind.band => ReadinessCheck.band,
      };

  static ReadinessReport fromDto(wire.ReadinessDto dto) => ReadinessReport(
        checked: [for (final c in dto.checked) check(c)],
        items: [
          for (final i in dto.items)
            ReadinessItem(
              check: check(i.check),
              code: i.code,
              level: level(i.severity),
              place: i.place,
              message: i.message,
              remediation: i.remediation,
              omitted: i.omitted,
            ),
        ],
      );
}

final readinessRepositoryProvider =
    Provider<ReadinessRepository>((_) => const ReadinessRepository());
