// The engine's warp, weft and finishing worksheet (ADR 0019): maps a draft's plan, the records it
// names and the planned loom to the bridge's DTOs, calls `weave_plan_worksheet` once, and maps the
// whole worksheet back. The only place in the app that touches the generated plan symbols.
//
// Nothing here reads or writes files: the plan lives in the draft's sidecar (saved with the draft),
// and the swatch and materials are read from the library as they are now and never written.

import '../models/loom_check.dart';
import '../models/loom_profile.dart';
import '../models/material_record.dart';
import '../models/weave_plan.dart';
import '../rust/api.dart' as api;
import '../rust/loom_dto.dart' as loom_wire;
import '../rust/materials_dto.dart' as mat_wire;
import '../rust/weave_plan_dto.dart' as wire;
import 'loom_repository.dart';
import 'materials_repository.dart';

/// The worksheet could not be worked out at all (a loom profile outside the engine's limits). Every
/// unusable number is a [PlanIssue] in the worksheet instead.
class WorksheetException implements Exception {
  const WorksheetException(this.message);

  final String message;

  @override
  String toString() => message;
}

class WeavePlanRepository {
  /// Work out the whole worksheet for [plan] with the records it uses and the open draft's [draft]
  /// facts (never the whole draft: those are worked out once per draft change). Throws a
  /// [WorksheetException] only when the request cannot be converted.
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
    try {
      final w = await api.weavePlanWorksheet(
        req: wire.WeavePlanRequestDto(
          plan: planToDto(plan),
          swatch: swatch == null ? null : MaterialsRepository.swatchToDto(swatch),
          warp: warp == null ? null : MaterialsRepository.materialToDto(warp),
          weft: weft == null ? null : MaterialsRepository.materialToDto(weft),
          loom: loom == null ? null : LoomRepository.loomToDto(loom),
          loomSett: loomSett == null ? null : LoomRepository.settToDto(loomSett),
          draft: draft == null
              ? null
              : wire.PlanDraftFactsDto(
                  ends: draft.ends.clamp(0, 0xFFFFFFFF),
                  meanStrands: draft.meanStrands,
                  fileSett:
                      draft.fileSett == null ? null : LoomRepository.settToDto(draft.fileSett!)),
          metric: metric,
        ),
      );
      return worksheetFromDto(w);
    } on String catch (e) {
      throw WorksheetException(e);
    }
  }

  /// The plan as the bridge takes it. A count the engine does not take (negative, or past its limit)
  /// goes as one past the limit, so the engine reports it as out of range instead of a clamped value
  /// being used.
  static wire.WeavePlanDto planToDto(WeavePlan p) {
    int count(int v) => v < 0 || v > WeavePlan.maxCount ? WeavePlan.maxCount + 1 : v;
    mat_wire.QuantityLengthDto? len(Length? l) =>
        l == null ? null : MaterialsRepository.lengthToDto(l);
    mat_wire.CountOverDto? cnt(CountOver? c) =>
        c == null ? null : MaterialsRepository.countToDto(c);
    final o = p.overrides;
    final reed = o.value<Reed>(PlanAssumption.reed);
    final ends = o.value<int>(PlanAssumption.ends);
    return wire.WeavePlanDto(
      structure: switch (p.structure) {
        PlanStructure.plain => wire.PlanStructureKind.plain,
        PlanStructure.twill => wire.PlanStructureKind.twill,
        PlanStructure.satin => wire.PlanStructureKind.satin,
        PlanStructure.other => wire.PlanStructureKind.other,
      },
      items: count(p.items),
      finishedWidth: len(p.finishedWidth),
      finishedLength: len(p.finishedLength),
      hems: len(p.hems),
      fringe: len(p.fringe),
      sampling: len(p.sampling),
      endMultiple: p.endMultiple == null ? null : count(p.endMultiple!),
      extraEnds: count(p.extraEnds),
      overrides: wire.PlanOverridesDto(
        takeUp: o.value<double>(PlanAssumption.takeUp),
        lengthShrinkage: o.value<double>(PlanAssumption.lengthShrinkage),
        drawIn: o.value<double>(PlanAssumption.drawIn),
        widthShrinkage: o.value<double>(PlanAssumption.widthShrinkage),
        weftAllowance: o.value<double>(PlanAssumption.weftAllowance),
        loomWaste: len(o.value<Length>(PlanAssumption.loomWaste)),
        sett: cnt(o.value<CountOver>(PlanAssumption.sett)),
        wpi: cnt(o.value<CountOver>(PlanAssumption.wpi)),
        ppi: cnt(o.value<CountOver>(PlanAssumption.ppi)),
        ends: ends == null ? null : count(ends),
        reed: reed == null
            ? null
            : loom_wire.ReedDto(
                dents: reed.dents,
                per: reed.per == DentUnit.perInch
                    ? loom_wire.DentUnitKind.perInch
                    : loom_wire.DentUnitKind.per10Cm),
      ),
    );
  }

  static LoomSeverity _severity(loom_wire.LoomSeverityKind k) => switch (k) {
        loom_wire.LoomSeverityKind.notFeasible => LoomSeverity.notFeasible,
        loom_wire.LoomSeverityKind.advice => LoomSeverity.advice,
        loom_wire.LoomSeverityKind.notChecked => LoomSeverity.notChecked,
        loom_wire.LoomSeverityKind.fits => LoomSeverity.fits,
      };

  static PlanWorksheet worksheetFromDto(wire.WorksheetDto w) => PlanWorksheet(
        metric: w.metric,
        inputs: [
          for (final i in w.inputs)
            TracedInput(
              key: i.key,
              label: i.label,
              value: i.value,
              source: MaterialsRepository.sourceFromKind(i.source),
              basis: i.basis,
              swatchId: i.swatchId,
              materialId: i.materialId,
            ),
        ],
        figures: [
          for (final f in w.figures)
            PlanFigure(
              key: f.key,
              label: f.label,
              value: f.value,
              lengthUnit: f.lengthUnit == null
                  ? null
                  : MaterialsRepository.lengthUnitFromKind(f.lengthUnit!),
              text: f.text,
              working: f.working,
              uses: f.uses,
              assumed: f.assumed,
            ),
        ],
        denting: w.denting == null
            ? null
            : DentingPlan(
                reed: Reed(
                    w.denting!.reed.dents,
                    w.denting!.reed.per == loom_wire.DentUnitKind.perInch
                        ? DentUnit.perInch
                        : DentUnit.per10cm),
                order: List<int>.unmodifiable(w.denting!.order),
                dents: w.denting!.dents,
                width: MaterialsRepository.lengthFromDto(w.denting!.width),
                exact: w.denting!.exact,
                text: w.denting!.text,
                working: w.denting!.working,
                uses: w.denting!.uses,
              ),
        checks: [
          for (final c in w.checks)
            PlanCheck(code: c.code, severity: _severity(c.severity), message: c.message),
        ],
        supply: [
          for (final s in w.supply)
            SupplyLine(
              role: switch (s.role) {
                wire.SupplyRoleKind.warp => SupplyRole.warp,
                wire.SupplyRoleKind.weft => SupplyRole.weft,
                wire.SupplyRoleKind.warpAndWeft => SupplyRole.warpAndWeft,
              },
              materialId: s.materialId,
              materialName: s.materialName,
              need: MaterialsRepository.lengthFromDto(s.need),
              needMass: s.needMass == null ? null : MaterialsRepository.massFromDto(s.needMass!),
              onHand: s.onHand == null ? null : MaterialsRepository.lengthFromDto(s.onHand!),
              onHandAbout: s.onHandAbout,
              remaining:
                  s.remaining == null ? null : MaterialsRepository.lengthFromDto(s.remaining!),
              text: s.text,
              working: s.working,
              uses: s.uses,
              assumed: s.assumed,
            ),
        ],
        issues: [
          for (final i in w.issues)
            PlanIssue(
              code: i.code,
              kind: i.kind == wire.PlanIssueKind.invalid
                  ? PlanIssueKind.invalid
                  : PlanIssueKind.needed,
              field: i.field,
              message: i.message,
            ),
        ],
        inputNotes: [for (final n in w.inputNotes) PlanInputNote(n.key, n.text)],
        notes: w.notes,
      );
}
