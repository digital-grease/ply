//! The warp, weft and finishing worksheet DTOs (M8-03, ADR 0019), mirrored transparently for the
//! Dart app.
//!
//! The plan (`ply_weave::worksheet::WeavePlan`, without its record ids: the app resolves those and
//! sends the records) and the whole worked-out worksheet cross the boundary as these plain structs
//! and FLAT enums only (no data-carrying enum, so no freezed rebuild is needed). Conversions live
//! here and nowhere else. Everything from Dart is untrusted: the planner checks every value, and a
//! loom profile outside the engine's limits is refused before it is used.

use ply_weave::feasibility::{LoomSeverity, Sett};
use ply_weave::loom::{DentUnit, LoomProfile, Reed};
use ply_weave::worksheet::{
    self, DentingPlan, DraftFacts, FigureUnit, InputNote, IssueKind, PlanCheck, PlanFigure,
    PlanIssue, PlanOverrides, PlanStructure, SupplyLine, SupplyRole, WeavePlan, Worksheet,
};

use crate::loom_dto::{DentUnitKind, LoomProfileDto, LoomSeverityKind, ReedDto, SettDto};
use crate::materials_dto::{
    traced_inputs, CountOverDto, MaterialDto, QuantityLengthDto, QuantityLengthUnit,
    QuantityMassDto, SwatchDto, TracedInputDto,
};

/// Mirrors `worksheet::PlanStructure`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PlanStructureKind {
    Plain,
    Twill,
    Satin,
    Other,
}

/// The weaver's own values for the assumptions; `None` = the swatch's, else Ply's starting
/// estimate.
#[derive(Debug, Clone, PartialEq)]
pub struct PlanOverridesDto {
    pub take_up: Option<f64>,
    pub length_shrinkage: Option<f64>,
    pub draw_in: Option<f64>,
    pub width_shrinkage: Option<f64>,
    pub weft_allowance: Option<f64>,
    pub loom_waste: Option<QuantityLengthDto>,
    pub sett: Option<CountOverDto>,
    pub wpi: Option<CountOverDto>,
    pub ppi: Option<CountOverDto>,
    pub ends: Option<u32>,
    pub reed: Option<ReedDto>,
}

/// One draft's plan (its record ids stay in the app, which sends the records instead).
#[derive(Debug, Clone, PartialEq)]
pub struct WeavePlanDto {
    pub structure: PlanStructureKind,
    pub items: u32,
    pub finished_width: Option<QuantityLengthDto>,
    pub finished_length: Option<QuantityLengthDto>,
    pub hems: Option<QuantityLengthDto>,
    pub fringe: Option<QuantityLengthDto>,
    pub sampling: Option<QuantityLengthDto>,
    pub end_multiple: Option<u32>,
    pub extra_ends: u32,
    pub overrides: PlanOverridesDto,
}

/// What the planner reads from the open draft, worked out by the app once per draft change, so a
/// plan call never carries the whole draft.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct PlanDraftFactsDto {
    /// The draft's warp ends.
    pub ends: u32,
    /// The draft's average strands per pick (1 when it records none).
    pub mean_strands: f64,
    /// The sett the draft's file gives, if any.
    pub file_sett: Option<SettDto>,
}

/// A plan with the records it uses, for one call.
#[derive(Debug, Clone, PartialEq)]
pub struct WeavePlanRequestDto {
    pub plan: WeavePlanDto,
    pub swatch: Option<SwatchDto>,
    pub warp: Option<MaterialDto>,
    pub weft: Option<MaterialDto>,
    /// The loom the draft is planned for (Loom for this draft).
    pub loom: Option<LoomProfileDto>,
    /// The sett entered in Loom for this draft.
    pub loom_sett: Option<SettDto>,
    /// The open draft's ends, strands per pick and file sett.
    pub draft: Option<PlanDraftFactsDto>,
    /// The app's units, used when the plan has no finished size.
    pub metric: bool,
}

/// Mirrors `worksheet::IssueKind`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PlanIssueKind {
    Invalid,
    Needed,
}

#[derive(Debug, Clone, PartialEq)]
pub struct PlanIssueDto {
    pub code: String,
    pub kind: PlanIssueKind,
    pub field: String,
    pub message: String,
}

/// What a figure's value counts.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PlanFigureUnitKind {
    Count,
    Length,
}

#[derive(Debug, Clone, PartialEq)]
pub struct PlanFigureDto {
    pub key: String,
    pub label: String,
    pub value: f64,
    pub kind: PlanFigureUnitKind,
    /// The unit of a length figure.
    pub length_unit: Option<QuantityLengthUnit>,
    pub text: String,
    pub working: Vec<String>,
    pub uses: Vec<String>,
    pub assumed: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub struct DentingPlanDto {
    pub reed: ReedDto,
    pub order: Vec<u32>,
    pub achieved_per_inch: f64,
    pub exact: bool,
    pub dents: u32,
    pub width: QuantityLengthDto,
    pub text: String,
    pub working: Vec<String>,
    pub uses: Vec<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct PlanCheckDto {
    pub code: String,
    pub severity: LoomSeverityKind,
    pub message: String,
}

/// Mirrors `worksheet::SupplyRole`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SupplyRoleKind {
    Warp,
    Weft,
    WarpAndWeft,
}

#[derive(Debug, Clone, PartialEq)]
pub struct SupplyLineDto {
    pub role: SupplyRoleKind,
    pub material_id: String,
    pub material_name: String,
    pub need: QuantityLengthDto,
    pub need_mass: Option<QuantityMassDto>,
    pub on_hand: Option<QuantityLengthDto>,
    pub on_hand_about: bool,
    /// On hand minus the need: below zero when short.
    pub remaining: Option<QuantityLengthDto>,
    pub text: String,
    pub working: Vec<String>,
    pub uses: Vec<String>,
    /// Whether any of those inputs is one of Ply's starting estimates.
    pub assumed: bool,
}

/// A note that explains one input, shown next to it.
#[derive(Debug, Clone, PartialEq)]
pub struct InputNoteDto {
    pub key: String,
    pub text: String,
}

/// The whole worksheet.
#[derive(Debug, Clone, PartialEq)]
pub struct WorksheetDto {
    pub metric: bool,
    pub inputs: Vec<TracedInputDto>,
    pub figures: Vec<PlanFigureDto>,
    pub denting: Option<DentingPlanDto>,
    pub checks: Vec<PlanCheckDto>,
    pub supply: Vec<SupplyLineDto>,
    pub issues: Vec<PlanIssueDto>,
    pub input_notes: Vec<InputNoteDto>,
    pub notes: Vec<String>,
}

// --- conversions -----------------------------------------------------------------------------------

impl From<PlanStructureKind> for PlanStructure {
    fn from(k: PlanStructureKind) -> Self {
        match k {
            PlanStructureKind::Plain => PlanStructure::Plain,
            PlanStructureKind::Twill => PlanStructure::Twill,
            PlanStructureKind::Satin => PlanStructure::Satin,
            PlanStructureKind::Other => PlanStructure::Other,
        }
    }
}

impl From<PlanStructure> for PlanStructureKind {
    fn from(s: PlanStructure) -> Self {
        match s {
            PlanStructure::Plain => PlanStructureKind::Plain,
            PlanStructure::Twill => PlanStructureKind::Twill,
            PlanStructure::Satin => PlanStructureKind::Satin,
            PlanStructure::Other => PlanStructureKind::Other,
        }
    }
}

fn reed(r: ReedDto) -> Reed {
    Reed {
        dents: r.dents,
        per: match r.per {
            DentUnitKind::PerInch => DentUnit::PerInch,
            DentUnitKind::Per10Cm => DentUnit::Per10Cm,
        },
    }
}

fn reed_dto(r: Reed) -> ReedDto {
    ReedDto {
        dents: r.dents,
        per: match r.per {
            DentUnit::PerInch => DentUnitKind::PerInch,
            DentUnit::Per10Cm => DentUnitKind::Per10Cm,
        },
    }
}

impl From<WeavePlanDto> for WeavePlan {
    fn from(d: WeavePlanDto) -> Self {
        let o = d.overrides;
        WeavePlan {
            version: worksheet::PLAN_VERSION,
            structure: d.structure.into(),
            items: d.items,
            finished_width: d.finished_width.map(Into::into),
            finished_length: d.finished_length.map(Into::into),
            hems: d.hems.map(Into::into),
            fringe: d.fringe.map(Into::into),
            sampling: d.sampling.map(Into::into),
            end_multiple: d.end_multiple,
            extra_ends: d.extra_ends,
            swatch_id: None,
            warp_material_id: None,
            weft_material_id: None,
            swatch_name: None,
            warp_material_name: None,
            weft_material_name: None,
            overrides: PlanOverrides {
                take_up: o.take_up,
                length_shrinkage: o.length_shrinkage,
                draw_in: o.draw_in,
                width_shrinkage: o.width_shrinkage,
                weft_allowance: o.weft_allowance,
                loom_waste: o.loom_waste.map(Into::into),
                sett: o.sett.map(Into::into),
                wpi: o.wpi.map(Into::into),
                ppi: o.ppi.map(Into::into),
                ends: o.ends,
                reed: o.reed.map(reed),
            },
        }
    }
}

fn severity(s: LoomSeverity) -> LoomSeverityKind {
    match s {
        LoomSeverity::NotFeasible => LoomSeverityKind::NotFeasible,
        LoomSeverity::Advice => LoomSeverityKind::Advice,
        LoomSeverity::NotChecked => LoomSeverityKind::NotChecked,
        LoomSeverity::Fits => LoomSeverityKind::Fits,
    }
}

impl From<&PlanIssue> for PlanIssueDto {
    fn from(i: &PlanIssue) -> Self {
        PlanIssueDto {
            code: i.code.to_string(),
            kind: match i.kind {
                IssueKind::Invalid => PlanIssueKind::Invalid,
                IssueKind::Needed => PlanIssueKind::Needed,
            },
            field: i.field.clone(),
            message: i.message.clone(),
        }
    }
}

impl From<&PlanFigure> for PlanFigureDto {
    fn from(f: &PlanFigure) -> Self {
        let (kind, length_unit) = match f.unit {
            FigureUnit::Count => (PlanFigureUnitKind::Count, None),
            FigureUnit::Length(u) => (PlanFigureUnitKind::Length, Some(u.into())),
        };
        PlanFigureDto {
            key: f.key.to_string(),
            label: f.label.clone(),
            value: f.value,
            kind,
            length_unit,
            text: f.text.clone(),
            working: f.working.clone(),
            uses: f.uses.clone(),
            assumed: f.assumed,
        }
    }
}

impl From<&DentingPlan> for DentingPlanDto {
    fn from(d: &DentingPlan) -> Self {
        DentingPlanDto {
            reed: reed_dto(d.reed),
            order: d.order.clone(),
            achieved_per_inch: d.achieved_per_inch,
            exact: d.exact,
            dents: d.dents,
            width: d.width.into(),
            text: d.text.clone(),
            working: d.working.clone(),
            uses: d.uses.clone(),
        }
    }
}

impl From<&PlanCheck> for PlanCheckDto {
    fn from(c: &PlanCheck) -> Self {
        PlanCheckDto {
            code: c.code.to_string(),
            severity: severity(c.severity),
            message: c.message.clone(),
        }
    }
}

impl From<&SupplyLine> for SupplyLineDto {
    fn from(s: &SupplyLine) -> Self {
        SupplyLineDto {
            role: match s.role {
                SupplyRole::Warp => SupplyRoleKind::Warp,
                SupplyRole::Weft => SupplyRoleKind::Weft,
                SupplyRole::WarpAndWeft => SupplyRoleKind::WarpAndWeft,
            },
            material_id: s.material_id.clone(),
            material_name: s.material_name.clone(),
            need: s.need.into(),
            need_mass: s.need_mass.map(Into::into),
            on_hand: s.on_hand.map(Into::into),
            on_hand_about: s.on_hand_about,
            remaining: s.remaining.map(Into::into),
            text: s.text.clone(),
            working: s.working.clone(),
            uses: s.uses.clone(),
            assumed: s.assumed,
        }
    }
}

impl From<&InputNote> for InputNoteDto {
    fn from(n: &InputNote) -> Self {
        InputNoteDto {
            key: n.key.clone(),
            text: n.text.clone(),
        }
    }
}

impl From<&Worksheet> for WorksheetDto {
    fn from(w: &Worksheet) -> Self {
        WorksheetDto {
            metric: w.metric,
            inputs: traced_inputs(&w.inputs),
            figures: w.figures.iter().map(Into::into).collect(),
            denting: w.denting.as_ref().map(Into::into),
            checks: w.checks.iter().map(Into::into).collect(),
            supply: w.supply.iter().map(Into::into).collect(),
            issues: w.issues.iter().map(Into::into).collect(),
            input_notes: w.input_notes.iter().map(Into::into).collect(),
            notes: w.notes.clone(),
        }
    }
}

/// Work out the whole worksheet for `req`. `Err` only when the loom profile is outside the
/// engine's limits; every unusable number is an issue instead.
pub fn worksheet(req: WeavePlanRequestDto) -> Result<WorksheetDto, String> {
    let plan = WeavePlan::from(req.plan);
    let swatch = req.swatch.map(ply_common::materials::Swatch::from);
    let warp = req.warp.map(ply_common::materials::Material::from);
    let weft = req.weft.map(ply_common::materials::Material::from);
    let loom = match req.loom {
        Some(dto) => {
            let loom = LoomProfile::from(dto);
            if let Some(problem) = loom.problems().into_iter().next() {
                return Err(format!(
                    "the loom profile cannot be planned with: {problem}"
                ));
            }
            Some(loom)
        }
        None => None,
    };
    let draft = match req.draft {
        Some(d) => DraftFacts {
            ends: d.ends as usize,
            mean_strands: d.mean_strands,
            file_sett: d.file_sett.map(Sett::from),
        },
        None => DraftFacts::default(),
    };
    let w = worksheet::work_out(&worksheet::WorksheetRequest {
        plan: &plan,
        swatch: swatch.as_ref(),
        warp: warp.as_ref(),
        weft: weft.as_ref(),
        loom: loom.as_ref(),
        loom_sett: req.loom_sett.map(Sett::from),
        draft,
        metric: req.metric,
    });
    Ok(WorksheetDto::from(&w))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::materials_dto::{InputOriginKind, QuantityLengthUnit, SourceKind};

    fn len(value: f64, unit: QuantityLengthUnit) -> QuantityLengthDto {
        QuantityLengthDto { value, unit }
    }

    fn no_overrides() -> PlanOverridesDto {
        PlanOverridesDto {
            take_up: None,
            length_shrinkage: None,
            draw_in: None,
            width_shrinkage: None,
            weft_allowance: None,
            loom_waste: None,
            sett: None,
            wpi: None,
            ppi: None,
            ends: None,
            reed: None,
        }
    }

    fn request(plan: WeavePlanDto) -> WeavePlanRequestDto {
        WeavePlanRequestDto {
            plan,
            swatch: None,
            warp: None,
            weft: None,
            loom: None,
            loom_sett: None,
            draft: None,
            metric: false,
        }
    }

    fn scarf() -> WeavePlanDto {
        WeavePlanDto {
            structure: PlanStructureKind::Plain,
            items: 1,
            finished_width: Some(len(25.0, QuantityLengthUnit::Centimeter)),
            finished_length: Some(len(180.0, QuantityLengthUnit::Centimeter)),
            hems: None,
            fringe: Some(len(24.0, QuantityLengthUnit::Centimeter)),
            sampling: None,
            end_multiple: None,
            extra_ends: 0,
            overrides: PlanOverridesDto {
                sett: Some(CountOverDto {
                    count: 6.0,
                    over: len(1.0, QuantityLengthUnit::Centimeter),
                }),
                ..no_overrides()
            },
        }
    }

    #[test]
    fn one_call_returns_the_whole_worksheet() {
        let w = worksheet(request(scarf())).unwrap();
        assert!(w.metric, "a plan in cm works in cm and m");
        let ends = w.figures.iter().find(|f| f.key == "warp_ends").unwrap();
        assert_eq!(ends.kind, PlanFigureUnitKind::Count);
        assert_eq!(ends.value, 185.0);
        let warp = w.figures.iter().find(|f| f.key == "warp_length").unwrap();
        assert_eq!(warp.length_unit, Some(QuantityLengthUnit::Meter));
        assert!(w
            .inputs
            .iter()
            .any(|i| i.key == "take_up" && i.source == SourceKind::Default));
        assert!(w.issues.is_empty());
        // The plan's version is the engine's, whatever Dart sends.
        assert_eq!(WeavePlan::from(scarf()).version, worksheet::PLAN_VERSION);
        let _ = InputOriginKind::Entered; // the materials DTOs stay in use alongside
    }

    #[test]
    fn the_draft_s_facts_reach_the_planner_without_the_draft() {
        let mut p = scarf();
        p.overrides.sett = None;
        p.finished_width = None;
        let mut req = request(p);
        req.draft = Some(PlanDraftFactsDto {
            ends: 120,
            mean_strands: 1.5,
            file_sett: Some(SettDto {
                ends: 8.0,
                per: crate::dto::UnitKind::Centimeters,
            }),
        });
        let w = worksheet(req).unwrap();
        let sett = w.inputs.iter().find(|i| i.key == "sett").unwrap();
        assert_eq!(sett.basis, "from this draft's file");
        let ends = w.figures.iter().find(|f| f.key == "warp_ends").unwrap();
        assert_eq!(
            ends.value, 120.0,
            "the draft's ends, with no finished width"
        );
        assert!(w.inputs.iter().any(|i| i.key == "strands"));
    }

    #[test]
    fn unusable_numbers_are_issues_and_a_bad_loom_is_refused() {
        let mut p = scarf();
        p.overrides.take_up = Some(f64::NAN);
        p.items = 0;
        let w = worksheet(request(p)).unwrap();
        let codes: Vec<_> = w.issues.iter().map(|i| i.code.as_str()).collect();
        assert_eq!(codes, vec!["plan.out_of_range", "quantity.not_finite"]);
        assert_eq!(w.issues[1].kind, PlanIssueKind::Invalid);
        let mut req = request(scarf());
        req.loom = Some(LoomProfileDto {
            id: "bad id!".into(),
            name: String::new(),
            kind: crate::loom_dto::LoomTypeKind::Unknown,
            shafts: Some(0),
            treadles: None,
            weaving_width: None,
            reeds: vec![],
            treadles_at_once: None,
            notes: String::new(),
        });
        assert!(worksheet(req).is_err());
    }
}
