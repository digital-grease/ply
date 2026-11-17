//! The warp, weft and finishing worksheet (roadmap M8-03, ADR 0019): from a finished size, through
//! take-up, shrinkage, draw-in and loom waste, to the warp ends, the width in the reed and the
//! denting, the warp length, the weft, and the yarn against what is on hand.
//!
//! A [`WeavePlan`] is the weaver's choices for one draft: the finished size and allowances, the
//! structure that picks Ply's starting estimates, the swatch and yarns it uses, and the assumptions
//! the weaver overrode. [`work_out`] reads the plan with the records it names and returns the whole
//! [`Worksheet`] in one call: every input with its source (measured, entered, Ply's starting
//! estimate) and its basis in words, every figure with its working and the inputs it used, the
//! denting, the loom checks, the supply, and typed issues for whatever could not be worked out.
//!
//! Every loss is a share of the EARLIER, larger measurement (take-up of the length on the loom,
//! shrinkage of the size off the loom, draw-in of the width in the reed), and planning goes
//! backwards by dividing by `1 - loss` (the ratio method): adding the percentage instead falls short.
//! A swatch or material is only ever read; overriding one assumption changes the plan alone.
//!
//! Inputs come from a sidecar and across FFI, so they are untrusted: nothing here panics, and a
//! value that is not a number, not above zero, out of range or too large is a [`PlanIssue`], never
//! NaN in a figure.

use crate::calc::Structure;
use crate::feasibility::{
    best_sleying, LoomSeverity, Sett, MAX_EVEN_PER_DENT, MAX_SETT_PER_INCH, MIN_SETT_PER_INCH,
};
use crate::loom::{DentUnit, LoomProfile, Reed};
use ply_common::materials::{loss, Material, StageKind, Swatch};
use ply_common::provenance::{Recorded, Source, TracedInput};
use ply_common::quantity::{
    number, percent, CountOver, Length, LengthUnit, Mass, MassUnit, MAX_QUANTITY_VALUE,
};
use ply_common::{CraftKind, Unit};
use serde::{Deserialize, Serialize};

/// The plan record's version. A plan with a higher one was written by a newer Ply.
pub const PLAN_VERSION: u32 = 1;

/// The most items, warp ends, extra ends or ends in a repeat a plan takes.
pub const MAX_PLAN_COUNT: u32 = crate::plan::MAX_PLAN_COUNT;

/// The smallest loss a plan takes: a cloth that grew by half.
pub const MIN_LOSS: f64 = -0.5;

/// The largest loss a plan takes. A loss of 100% or more cannot be true.
pub const MAX_LOSS: f64 = 0.9;

/// The largest weft allowance (200% more weft than the width in the reed).
pub const MAX_WEFT_ALLOWANCE: f64 = 2.0;

/// The most picks a plan works out.
pub const MAX_PICKS: f64 = 1_000_000_000.0;

/// The longest warp a plan works out, in its long unit (yards or metres).
pub const MAX_WARP_LENGTH: f64 = MAX_QUANTITY_VALUE;

/// The most warp or weft yarn a plan works out, in its long unit (yards or metres).
pub const MAX_YARN_LENGTH: f64 = 1_000_000_000.0;

/// The most strands one pick may carry on average.
pub const MAX_MEAN_STRANDS: f64 = 100.0;

/// How far apart two setts may be (as a share) before a note says so.
const SETT_DIFFERENCE: f64 = 0.02;

// --- the plan record -----------------------------------------------------------------------------

/// The structure the starting estimates are chosen for.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PlanStructure {
    #[default]
    Plain,
    Twill,
    Satin,
    /// Any other structure (overshot, double weave, a block weave): the general rules of thumb.
    Other,
}

impl PlanStructure {
    pub const ALL: [PlanStructure; 4] = [
        PlanStructure::Plain,
        PlanStructure::Twill,
        PlanStructure::Satin,
        PlanStructure::Other,
    ];

    /// "plain weave", "twill", "satin", "another structure".
    pub fn phrase(self) -> &'static str {
        match self {
            PlanStructure::Plain => "plain weave",
            PlanStructure::Twill => "twill",
            PlanStructure::Satin => "satin",
            PlanStructure::Other => "another structure",
        }
    }

    /// Ply's starting estimates for this structure (ADR 0019 section 4). Starting points, not
    /// measurements: a sample woven and finished like the project replaces them.
    pub fn estimates(self) -> StartingEstimates {
        let (take_up, draw_in, sett_fraction) = match self {
            PlanStructure::Plain | PlanStructure::Other => {
                (0.10, 0.10, f64::from(Structure::Plain.sett_fraction()))
            }
            PlanStructure::Twill => (0.08, 0.08, f64::from(Structure::Twill.sett_fraction())),
            PlanStructure::Satin => (0.06, 0.06, f64::from(Structure::Satin.sett_fraction())),
        };
        StartingEstimates {
            take_up,
            draw_in,
            length_shrinkage: 0.10,
            width_shrinkage: 0.10,
            weft_allowance: 0.10,
            // The calculator's f32 presets, read back to the decimal they were written as.
            sett_fraction: (sett_fraction * 100.0).round() / 100.0,
        }
    }
}

/// Ply's starting estimates for one structure: fractions (0.1 = 10%).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct StartingEstimates {
    pub take_up: f64,
    pub draw_in: f64,
    pub length_shrinkage: f64,
    pub width_shrinkage: f64,
    pub weft_allowance: f64,
    /// The share of the wraps per inch used as a starting sett (the calculator's preset).
    pub sett_fraction: f64,
}

/// The loom waste Ply starts from: 24 in, or 60 cm in a metric plan.
pub fn starting_loom_waste(metric: bool) -> Length {
    if metric {
        Length::cm(60.0)
    } else {
        Length::inches(24.0)
    }
}

/// The weaver's own values for the assumptions. A field that is `None` is the swatch's (when the
/// chosen swatch measured it), else Ply's starting estimate.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlanOverrides {
    /// Take-up, a share of the length on the loom.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub take_up: Option<f64>,
    /// Length shrinkage in finishing, a share of the length off the loom.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub length_shrinkage: Option<f64>,
    /// Draw-in, a share of the width in the reed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub draw_in: Option<f64>,
    /// Width shrinkage in finishing, a share of the width off the loom.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub width_shrinkage: Option<f64>,
    /// Extra weft in each pick, a share of the width in the reed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub weft_allowance: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub loom_waste: Option<Length>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sett: Option<CountOver>,
    /// Wraps per inch (or over any span), for a starting sett.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub wpi: Option<CountOver>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ppi: Option<CountOver>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ends: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reed: Option<Reed>,
}

/// One draft's plan, as the sidecar's `weavePlan` key holds it (the sidecar is Dart-owned; this
/// reads the same shape for the fixtures and for tools).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WeavePlan {
    pub version: u32,
    #[serde(default)]
    pub structure: PlanStructure,
    #[serde(default = "one")]
    pub items: u32,
    /// One item's width after wet finishing.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub finished_width: Option<Length>,
    /// One item's length after wet finishing.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub finished_length: Option<Length>,
    /// The finished cloth one item folds into its hems, both ends together (woven).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hems: Option<Length>,
    /// The unwoven warp one item keeps for its fringe, both ends together.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fringe: Option<Length>,
    /// A length woven at the start of the warp to sample, measured on the loom.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sampling: Option<Length>,
    /// Round the ends worked out from the width to a multiple of this (the threading repeat).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub end_multiple: Option<u32>,
    /// Ends added after rounding (floating selvedges, an end to balance a twill).
    #[serde(default, skip_serializing_if = "is_zero")]
    pub extra_ends: u32,
    /// The swatch, warp yarn and weft yarn the plan names. The caller resolves them and passes the
    /// records in the [`WorksheetRequest`].
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub swatch_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub warp_material_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub weft_material_id: Option<String>,
    /// The records' names when they were chosen, so a record that is gone is still named ("not in
    /// your materials"), as a project's links are (ADR 0016).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub swatch_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub warp_material_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub weft_material_name: Option<String>,
    #[serde(default)]
    pub overrides: PlanOverrides,
}

fn one() -> u32 {
    1
}

fn is_zero(n: &u32) -> bool {
    *n == 0
}

impl Default for WeavePlan {
    fn default() -> Self {
        WeavePlan {
            version: PLAN_VERSION,
            structure: PlanStructure::Plain,
            items: 1,
            finished_width: None,
            finished_length: None,
            hems: None,
            fringe: None,
            sampling: None,
            end_multiple: None,
            extra_ends: 0,
            swatch_id: None,
            warp_material_id: None,
            weft_material_id: None,
            swatch_name: None,
            warp_material_name: None,
            weft_material_name: None,
            overrides: PlanOverrides::default(),
        }
    }
}

// --- the request ---------------------------------------------------------------------------------

/// What the planner reads from the open draft.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct DraftFacts {
    /// The draft's warp ends (0 for a blank draft).
    pub ends: usize,
    /// The draft's average strands per pick (1 when it records none).
    pub mean_strands: f64,
    /// The sett the draft's file gives (`1 / [WARP] Spacing`), if any.
    pub file_sett: Option<Sett>,
}

impl Default for DraftFacts {
    fn default() -> Self {
        DraftFacts {
            ends: 0,
            mean_strands: 1.0,
            file_sett: None,
        }
    }
}

/// A plan with the records it uses.
#[derive(Debug, Clone, Copy)]
pub struct WorksheetRequest<'a> {
    pub plan: &'a WeavePlan,
    pub swatch: Option<&'a Swatch>,
    pub warp: Option<&'a Material>,
    pub weft: Option<&'a Material>,
    /// The loom the draft is planned for (Loom for this draft).
    pub loom: Option<&'a LoomProfile>,
    /// The sett entered in Loom for this draft.
    pub loom_sett: Option<Sett>,
    pub draft: DraftFacts,
    /// The app's units, used when the plan has no finished size to take its units from.
    pub metric: bool,
}

// --- the worksheet -------------------------------------------------------------------------------

/// Whether an issue is a value that cannot be used or an input not given yet.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum IssueKind {
    /// The value cannot be used (not a number, out of range, impossible).
    Invalid,
    /// An input the figure needs is not given yet.
    Needed,
}

/// Why part of the worksheet could not be worked out.
#[derive(Debug, Clone, PartialEq)]
pub struct PlanIssue {
    /// Stable code: `quantity.not_finite`, `quantity.not_positive`, `quantity.too_large`,
    /// `plan.negative`, `plan.out_of_range`, `plan.swatch_not_weaving`, `plan.swatch_out_of_range`,
    /// `plan.result_too_large`, `plan.needs_input`, `plan.needs_sett`, `plan.needs_width`.
    pub code: &'static str,
    pub kind: IssueKind,
    /// The input key it concerns ("take_up", "finished_width").
    pub field: String,
    pub message: String,
}

/// The unit of a figure's value.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FigureUnit {
    /// A count (ends, picks).
    Count,
    Length(LengthUnit),
}

/// One figure of the worksheet.
#[derive(Debug, Clone, PartialEq)]
pub struct PlanFigure {
    /// Stable key: `width_in_reed_target`, `warp_ends`, `width_in_reed`, `finished_width`,
    /// `woven_length`, `warp_length`, `warp_yarn`, `weft_picks`, `weft_per_pick`, `weft_yarn`.
    pub key: &'static str,
    pub label: String,
    pub value: f64,
    pub unit: FigureUnit,
    /// The figure as shown, with the other unit family in brackets ("20.58 in (52.28 cm)").
    pub text: String,
    /// The arithmetic in words, one step per line.
    pub working: Vec<String>,
    /// The keys of the inputs it used.
    pub uses: Vec<String>,
    /// Whether any of those inputs is one of Ply's starting estimates.
    pub assumed: bool,
}

/// How to sley the reed for the plan's ends.
#[derive(Debug, Clone, PartialEq)]
pub struct DentingPlan {
    pub reed: Reed,
    /// Ends in each dent of the repeating order, most first.
    pub order: Vec<u32>,
    /// The sett the reed gives this way, in ends per inch.
    pub achieved_per_inch: f64,
    /// Whether that is the plan's sett (within 0.1%).
    pub exact: bool,
    /// The dents the ends fill.
    pub dents: u32,
    /// The width those dents span, in the plan's short unit.
    pub width: Length,
    pub text: String,
    pub working: Vec<String>,
    pub uses: Vec<String>,
}

/// A loom check of the plan (the loom check's severities, ADR 0014).
#[derive(Debug, Clone, PartialEq)]
pub struct PlanCheck {
    /// `plan.loom_width_fits`, `plan.loom_width_exceeded`, `plan.loom_width_unknown`,
    /// `plan.reed_fits`, `plan.reed_irregular`, `plan.reed_none_fits`, `plan.reed_unknown`.
    pub code: &'static str,
    pub severity: LoomSeverity,
    pub message: String,
}

/// What a supply line is for.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SupplyRole {
    Warp,
    Weft,
    /// One material for warp and weft.
    WarpAndWeft,
}

impl SupplyRole {
    fn key(self) -> &'static str {
        match self {
            SupplyRole::Warp => "warp",
            SupplyRole::Weft => "weft",
            SupplyRole::WarpAndWeft => "yarn",
        }
    }

    fn noun(self) -> &'static str {
        match self {
            SupplyRole::Warp => "warp",
            SupplyRole::Weft => "weft",
            SupplyRole::WarpAndWeft => "warp and weft",
        }
    }
}

/// One yarn's need against what is on hand.
#[derive(Debug, Clone, PartialEq)]
pub struct SupplyLine {
    pub role: SupplyRole,
    pub material_id: String,
    pub material_name: String,
    /// What the plan needs, in the plan's long unit.
    pub need: Length,
    /// The same as a mass, when the yarn's length per mass is known (in its mass unit).
    pub need_mass: Option<Mass>,
    /// What is on hand, in the plan's long unit, when recorded.
    pub on_hand: Option<Length>,
    /// Whether the amount on hand was worked out from its mass ("about").
    pub on_hand_about: bool,
    /// On hand minus the need: below zero when short.
    pub remaining: Option<Length>,
    pub text: String,
    pub working: Vec<String>,
    pub uses: Vec<String>,
    /// Whether any of those inputs is one of Ply's starting estimates.
    pub assumed: bool,
}

/// A note that explains one input, shown next to it ("Of that, the swatch measured ...").
#[derive(Debug, Clone, PartialEq)]
pub struct InputNote {
    /// The input key it explains.
    pub key: String,
    pub text: String,
}

/// The whole worksheet.
#[derive(Debug, Clone, PartialEq)]
pub struct Worksheet {
    /// Whether the plan works in centimetres and metres (else inches and yards).
    pub metric: bool,
    pub inputs: Vec<TracedInput>,
    pub figures: Vec<PlanFigure>,
    pub denting: Option<DentingPlan>,
    pub checks: Vec<PlanCheck>,
    pub supply: Vec<SupplyLine>,
    pub issues: Vec<PlanIssue>,
    /// Notes about one input each, in the order they were made.
    pub input_notes: Vec<InputNote>,
    /// Notes about the plan as a whole.
    pub notes: Vec<String>,
}

impl Worksheet {
    pub fn figure(&self, key: &str) -> Option<&PlanFigure> {
        self.figures.iter().find(|f| f.key == key)
    }

    pub fn input(&self, key: &str) -> Option<&TracedInput> {
        self.inputs.iter().find(|i| i.key == key)
    }

    /// The issue codes, in order.
    pub fn issue_codes(&self) -> Vec<&'static str> {
        self.issues.iter().map(|i| i.code).collect()
    }

    /// The check codes, in order.
    pub fn check_codes(&self) -> Vec<&'static str> {
        self.checks.iter().map(|c| c.code).collect()
    }
}

// --- the planner ---------------------------------------------------------------------------------

/// Work out the whole worksheet for `req`. Never panics; whatever cannot be worked out is an issue.
pub fn work_out(req: &WorksheetRequest) -> Worksheet {
    let mut w = Work::new(req);
    let targets = w.targets();
    let length = w.direction(&LENGTH);
    let width_factor = w.direction(&WIDTH);
    let weft_allowance = w.weft_allowance();
    let waste = w.loom_waste();
    let sett = w.sett();
    let ppi = w.ppi(sett.as_ref());
    let strands = w.strands();
    let width = w.width_section(&targets, sett.as_ref(), width_factor.as_ref());
    if let (Some(width), Some(sett)) = (&width, &sett) {
        w.denting(width, sett);
        w.loom_width(width);
    }
    let woven = w.length_section(&targets, length.as_ref(), waste);
    let warp_need = match (&width, &woven) {
        (Some(width), Some(woven)) => w.warp_yarn(width, woven),
        _ => None,
    };
    let weft_need = match (&width, &woven, &ppi, weft_allowance, strands) {
        (Some(width), Some(woven), Some(ppi), Some(allowance), Some(strands)) => {
            w.weft(width, woven, ppi, allowance, strands)
        }
        _ => None,
    };
    w.supply(warp_need, weft_need);
    w.notes(sett.as_ref(), width.as_ref(), &targets);
    w.finish()
}

/// A value read from the plan: missing, unusable (an issue was raised), or usable.
enum Read<T> {
    Missing,
    Bad,
    Ok(T),
}

/// The plan's targets and allowances, in the plan's short unit.
struct Targets {
    items: Option<u32>,
    finished_width: Read<Length>,
    finished_length: Read<Length>,
    /// Hems, fringe and sampling in the short unit (0 when not given); `None` when unusable.
    hems: Option<f64>,
    fringe: Option<f64>,
    sampling: Option<f64>,
    end_multiple: Option<u32>,
    extra_ends: Option<u32>,
}

/// A direction's losses, resolved: `factor` is finished over first (width in the reed, or length on
/// the loom).
struct Factor {
    factor: f64,
    /// The losses in the order they happen, with the input keys.
    losses: Vec<f64>,
    keys: Vec<String>,
}

impl Factor {
    /// "/ (1 - 10%) / (1 - 10%)"; a gain reads "/ (1 + 8.3%)".
    fn divided(&self) -> String {
        self.losses
            .iter()
            .map(|l| format!("/ {}", one_less(*l)))
            .collect::<Vec<_>>()
            .join(" ")
    }

    /// "x (1 - 10%) x (1 - 10%)".
    fn multiplied(&self) -> String {
        self.losses
            .iter()
            .map(|l| format!("x {}", one_less(*l)))
            .collect::<Vec<_>>()
            .join(" ")
    }
}

/// The width section: the ends and the width in the reed, in the short unit.
struct WidthResult {
    ends: u32,
    reed_width: f64,
    /// The keys behind the ends and the width.
    keys: Vec<String>,
    /// Whether the ends were worked out from the finished width with a repeat or extra ends.
    rounded: bool,
}

/// The length section: the length woven per item and the warp length, in the short unit.
struct WovenResult {
    items: u32,
    per_item: f64,
    sampling: f64,
    warp_length: f64,
    /// The keys behind the cloth woven (what the picks depend on).
    woven_keys: Vec<String>,
    /// The keys behind the warp length (the cloth woven, the fringe and the loom waste).
    warp_keys: Vec<String>,
}

/// A sett, as the plan uses it, with the keys behind it.
struct SettUsed {
    sett: CountOver,
    keys: Vec<String>,
    /// Where it came from, for the notes.
    from: SettFrom,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum SettFrom {
    Entered,
    Wpi,
    Loom,
    Swatch,
    File,
    Yarn,
}

/// One direction's two losses: take-up then length shrinkage, or draw-in then width shrinkage.
struct DirectionSpec {
    first: PartSpec,
    second: PartSpec,
    combined_key: &'static str,
    combined_label: &'static str,
    combined_denominator: &'static str,
    /// The measurements at each end of the whole loss, for the basis ("on the loom", "in the reed").
    first_phrase: &'static str,
    width: bool,
}

struct PartSpec {
    key: &'static str,
    label: &'static str,
    /// "of the length on the loom".
    denominator: &'static str,
    /// The earlier and later measurement phrases.
    from_phrase: &'static str,
    to_phrase: &'static str,
}

const LENGTH: DirectionSpec = DirectionSpec {
    first: PartSpec {
        key: "take_up",
        label: "Take-up",
        denominator: "of the length on the loom",
        from_phrase: "on the loom",
        to_phrase: "off the loom",
    },
    second: PartSpec {
        key: "length_shrinkage",
        label: "Length shrinkage",
        denominator: "of the length off the loom",
        from_phrase: "off the loom",
        to_phrase: "after wet finishing",
    },
    combined_key: "length_loss",
    combined_label: "Take-up and shrinkage",
    combined_denominator: "of the length on the loom, from the loom to finished",
    first_phrase: "on the loom",
    width: false,
};

const WIDTH: DirectionSpec = DirectionSpec {
    first: PartSpec {
        key: "draw_in",
        label: "Draw-in",
        denominator: "of the width in the reed",
        from_phrase: "in the reed",
        to_phrase: "on the loom",
    },
    second: PartSpec {
        key: "width_shrinkage",
        label: "Width shrinkage",
        denominator: "of the width off the loom",
        from_phrase: "off the loom",
        to_phrase: "after wet finishing",
    },
    combined_key: "width_loss",
    combined_label: "Draw-in and shrinkage",
    combined_denominator: "of the width in the reed, from the reed to finished",
    first_phrase: "in the reed",
    width: true,
};

struct Work<'a> {
    req: &'a WorksheetRequest<'a>,
    plan: &'a WeavePlan,
    /// The chosen swatch, when it is a weaving swatch (or records no craft).
    swatch: Option<&'a Swatch>,
    metric: bool,
    short: LengthUnit,
    long: LengthUnit,
    est: StartingEstimates,
    inputs: Vec<TracedInput>,
    figures: Vec<PlanFigure>,
    denting: Option<DentingPlan>,
    checks: Vec<PlanCheck>,
    supply: Vec<SupplyLine>,
    issues: Vec<PlanIssue>,
    input_notes: Vec<InputNote>,
    notes: Vec<String>,
}

impl<'a> Work<'a> {
    fn new(req: &'a WorksheetRequest<'a>) -> Work<'a> {
        let plan = req.plan;
        let metric = plan
            .finished_length
            .or(plan.finished_width)
            .map(|l| l.unit.is_metric())
            .unwrap_or(req.metric);
        let mut w = Work {
            req,
            plan,
            swatch: None,
            metric,
            short: if metric {
                LengthUnit::Centimeter
            } else {
                LengthUnit::Inch
            },
            long: if metric {
                LengthUnit::Meter
            } else {
                LengthUnit::Yard
            },
            est: plan.structure.estimates(),
            inputs: Vec::new(),
            figures: Vec::new(),
            denting: None,
            checks: Vec::new(),
            supply: Vec::new(),
            issues: Vec::new(),
            input_notes: Vec::new(),
            notes: Vec::new(),
        };
        match req.swatch {
            Some(s)
                if matches!(
                    s.craft,
                    Some(CraftKind::Knitting | CraftKind::Nalbinding | CraftKind::TabletWeaving)
                ) =>
            {
                w.issue(
                    "plan.swatch_not_weaving",
                    IssueKind::Invalid,
                    "swatch",
                    format!(
                        "{} is not a weaving swatch, so the plan does not use it.",
                        capitalize(&s.citation())
                    ),
                );
            }
            other => w.swatch = other,
        }
        w
    }

    fn finish(self) -> Worksheet {
        Worksheet {
            metric: self.metric,
            inputs: self.inputs,
            figures: self.figures,
            denting: self.denting,
            checks: self.checks,
            supply: self.supply,
            issues: self.issues,
            input_notes: self.input_notes,
            notes: self.notes,
        }
    }

    fn issue(&mut self, code: &'static str, kind: IssueKind, field: &str, message: String) {
        self.issues.push(PlanIssue {
            code,
            kind,
            field: field.to_string(),
            message,
        });
    }

    fn input_note(&mut self, key: &str, text: String) {
        self.input_notes.push(InputNote {
            key: key.to_string(),
            text,
        });
    }

    fn entered(&mut self, key: &str, label: &str, value: String) {
        self.inputs.push(TracedInput::entered(key, label, value));
    }

    fn push_input(&mut self, input: TracedInput) {
        self.inputs.push(input);
    }

    /// A Ply starting estimate.
    fn estimate(&mut self, key: &str, label: &str, value: String, why: Option<String>) {
        let mut basis = format!(
            "Ply's starting estimate for {}",
            self.plan.structure.phrase()
        );
        if let Some(why) = why {
            basis.push_str(&format!(" ({why})"));
        }
        self.inputs.push(TracedInput {
            key: key.to_string(),
            label: label.to_string(),
            value,
            source: Source::Default,
            basis,
            swatch_id: None,
            material_id: None,
        });
    }

    fn assumed(&self, keys: &[String]) -> bool {
        self.inputs
            .iter()
            .any(|i| i.source == Source::Default && keys.iter().any(|k| k == &i.key))
    }

    #[allow(clippy::too_many_arguments)]
    fn figure(
        &mut self,
        key: &'static str,
        label: &str,
        value: f64,
        unit: FigureUnit,
        text: String,
        working: Vec<String>,
        mut uses: Vec<String>,
    ) {
        dedup(&mut uses);
        let assumed = self.assumed(&uses);
        self.figures.push(PlanFigure {
            key,
            label: label.to_string(),
            value,
            unit,
            text,
            working,
            uses,
            assumed,
        });
    }

    /// "20.58 in (52.28 cm)" for a length in the short unit; "4.95 yd (4.52 m)" in the long.
    fn both(&self, value: f64, unit: LengthUnit) -> String {
        let other = match unit {
            LengthUnit::Inch => LengthUnit::Centimeter,
            LengthUnit::Centimeter => LengthUnit::Inch,
            LengthUnit::Yard => LengthUnit::Meter,
            LengthUnit::Meter => LengthUnit::Yard,
            LengthUnit::Millimeter => LengthUnit::Inch,
        };
        let l = Length::new(value, unit);
        format!("{} ({})", l.describe(), l.converted(other).describe())
    }

    fn short_text(&self, v: f64) -> String {
        Length::new(v, self.short).describe()
    }

    // --- targets ---------------------------------------------------------------------------------

    fn targets(&mut self) -> Targets {
        let p = self.plan;
        let finished_width = self.positive_length(
            "finished_width",
            "Finished width",
            "finished width",
            p.finished_width,
            "",
        );
        let finished_length = self.positive_length(
            "finished_length",
            "Finished length",
            "finished length",
            p.finished_length,
            "",
        );
        let items = if (1..=MAX_PLAN_COUNT).contains(&p.items) {
            self.entered("items", "Items", p.items.to_string());
            Some(p.items)
        } else {
            self.issue(
                "plan.out_of_range",
                IssueKind::Invalid,
                "items",
                format!("The number of items must be a whole number from 1 to {MAX_PLAN_COUNT}."),
            );
            None
        };
        let hems = self.allowance(
            "hems",
            "Hems",
            "hems",
            p.hems,
            " of finished cloth for each item, both ends",
        );
        let fringe = self.allowance(
            "fringe",
            "Fringe",
            "fringe",
            p.fringe,
            " of unwoven warp for each item, both ends",
        );
        let sampling = self.allowance(
            "sampling",
            "Sampling",
            "sampling",
            p.sampling,
            " woven on the loom for a sample",
        );
        let end_multiple = match p.end_multiple {
            None => Some(1),
            // Listed as an input only where it is applied (ends worked out from the width).
            Some(m) if (1..=MAX_PLAN_COUNT).contains(&m) => Some(m),
            Some(_) => {
                self.issue(
                    "plan.out_of_range",
                    IssueKind::Invalid,
                    "end_multiple",
                    format!(
                        "The ends in a repeat must be a whole number from 1 to {MAX_PLAN_COUNT}."
                    ),
                );
                None
            }
        };
        let extra_ends = if p.extra_ends <= MAX_PLAN_COUNT {
            Some(p.extra_ends)
        } else {
            self.issue(
                "plan.out_of_range",
                IssueKind::Invalid,
                "extra_ends",
                format!("The extra ends must be a whole number from 0 to {MAX_PLAN_COUNT}."),
            );
            None
        };
        Targets {
            items,
            finished_width,
            finished_length,
            hems,
            fringe,
            sampling,
            end_multiple,
            extra_ends,
        }
    }

    /// A length that must be above zero; an entered input when usable.
    fn positive_length(
        &mut self,
        key: &str,
        label: &str,
        what: &str,
        l: Option<Length>,
        suffix: &str,
    ) -> Read<Length> {
        let Some(l) = l else {
            return Read::Missing;
        };
        match l.problem() {
            Some(p) => {
                self.issue(
                    p.code(),
                    IssueKind::Invalid,
                    key,
                    format!("The {what} {}.", p.phrase()),
                );
                Read::Bad
            }
            None => {
                self.entered(key, label, format!("{}{suffix}", l.describe()));
                Read::Ok(l)
            }
        }
    }

    /// A length that may be 0, in the short unit: 0 when not given, `None` when unusable.
    fn allowance(
        &mut self,
        key: &str,
        label: &str,
        what: &str,
        l: Option<Length>,
        suffix: &str,
    ) -> Option<f64> {
        let Some(l) = l else {
            return Some(0.0);
        };
        if let Some(message) = nonnegative_problem(what, l) {
            self.issue(message.0, IssueKind::Invalid, key, message.1);
            return None;
        }
        self.entered(key, label, format!("{}{suffix}", l.describe()));
        Some(l.to(self.short))
    }

    // --- losses ----------------------------------------------------------------------------------

    /// Check an entered or measured loss; an issue when it is not usable.
    fn loss_usable(&mut self, key: &str, label: &str, denominator: &str, v: f64) -> bool {
        if !v.is_finite() {
            self.issue(
                "quantity.not_finite",
                IssueKind::Invalid,
                key,
                format!("The {} is not a number.", label.to_lowercase()),
            );
            return false;
        }
        if !(MIN_LOSS..=MAX_LOSS).contains(&v) {
            self.issue(
                "plan.out_of_range",
                IssueKind::Invalid,
                key,
                format!(
                    "The {} must be from {} to {} {denominator}.",
                    label.to_lowercase(),
                    percent(MIN_LOSS),
                    percent(MAX_LOSS)
                ),
            );
            return false;
        }
        true
    }

    /// The swatch's loss between two of its measurements, when both are recorded and usable.
    fn swatch_loss(
        &self,
        from: Option<Recorded<Length>>,
        to: Option<Recorded<Length>>,
    ) -> Option<SwatchLoss> {
        let a = from.filter(|r| r.value.problem().is_none())?;
        let b = to.filter(|r| r.value.problem().is_none())?;
        let l = loss(a.value, b.value);
        l.is_finite().then_some(SwatchLoss {
            loss: l,
            from: a.value,
            to: b.value,
            source: if a.source == Source::Measured && b.source == Source::Measured {
                Source::Measured
            } else {
                Source::Entered
            },
        })
    }

    /// Whether every measurement in `measures` that the swatch recorded can be used. A recorded
    /// one that cannot (zero, negative, not a number) is an issue on `key`, never a quiet fall back
    /// to the estimate. `what` is what the weaver can enter instead.
    fn measures_usable(
        &mut self,
        key: &str,
        dir: &DirectionSpec,
        what: &str,
        measures: &[(Option<Recorded<Length>>, &str)],
    ) -> bool {
        let Some(s) = self.swatch else {
            return true;
        };
        let mut ok = true;
        for (m, phrase) in measures {
            if let Some(r) = m {
                if let Some(p) = r.value.problem() {
                    self.issue(
                        "plan.swatch_out_of_range",
                        IssueKind::Invalid,
                        key,
                        format!(
                            "{} records its {} {phrase} as {}, which {}. Check its measurements, \
                             or enter your own {what}.",
                            capitalize(&s.citation()),
                            if dir.width { "width" } else { "length" },
                            r.value.describe(),
                            p.phrase()
                        ),
                    );
                    ok = false;
                }
            }
        }
        ok
    }

    /// The four measurements of a direction on the swatch: the whole loss runs first to last; the
    /// first part first to `first_to`, the second part `second_from` to last.
    #[allow(clippy::type_complexity)]
    fn swatch_stages(
        &self,
        spec: &DirectionSpec,
    ) -> Option<(
        Option<Recorded<Length>>,
        Option<Recorded<Length>>,
        Option<Recorded<Length>>,
        Option<Recorded<Length>>,
    )> {
        let s = self.swatch?;
        Some(if spec.width {
            (
                s.width_in_reed,
                s.on_loom.width,
                s.before.width,
                s.after.width,
            )
        } else {
            (
                s.on_loom.length,
                s.before.length,
                s.before.length,
                s.after.length,
            )
        })
    }

    /// The finished over first factor of one direction, with its inputs.
    fn direction(&mut self, spec: &DirectionSpec) -> Option<Factor> {
        let o = &self.plan.overrides;
        let (o1, o2) = if spec.width {
            (o.draw_in, o.width_shrinkage)
        } else {
            (o.take_up, o.length_shrinkage)
        };
        let stages = self.swatch_stages(spec);
        let both = format!(
            "{} and {}",
            spec.first.label.to_lowercase(),
            spec.second.label.to_lowercase()
        );
        // Both from the swatch: its own loss from first to last.
        if let (None, None, Some((first, _, _, last))) = (o1, o2, stages) {
            if !self.measures_usable(
                spec.combined_key,
                spec,
                &both,
                &[
                    (first, spec.first.from_phrase),
                    (last, spec.second.to_phrase),
                ],
            ) {
                return None;
            }
            if let Some(whole) = self.swatch_loss(first, last) {
                return self.combined(spec, whole);
            }
        }
        let (a1, a2) = match stages {
            Some((first, first_to, second_from, last)) => {
                let first_ok = o1.is_some()
                    || self.measures_usable(
                        spec.first.key,
                        spec,
                        &spec.first.label.to_lowercase(),
                        &[
                            (first, spec.first.from_phrase),
                            (first_to, spec.first.to_phrase),
                        ],
                    );
                let second_ok = o2.is_some()
                    || self.measures_usable(
                        spec.second.key,
                        spec,
                        &spec.second.label.to_lowercase(),
                        &[
                            (second_from, spec.second.from_phrase),
                            (last, spec.second.to_phrase),
                        ],
                    );
                if !(first_ok && second_ok) {
                    return None;
                }
                (
                    self.swatch_loss(first, first_to),
                    self.swatch_loss(second_from, last),
                )
            }
            None => (None, None),
        };
        let first = self.part(&spec.first, o1, a1, true, spec);
        let second = self.part(&spec.second, o2, a2, false, spec);
        // The swatch's change between the loom and off it is not counted when its width parts are
        // mixed with an entered one: said next to the part still read from the swatch.
        if spec.width && (o1.is_some() != o2.is_some()) {
            if let (Some(s), Some((_, Some(on), Some(off), _))) = (self.swatch, stages) {
                if on.value.problem().is_none() && off.value.problem().is_none() {
                    let change = loss(on.value, off.value);
                    if change.abs() > 0.01 {
                        let key = if o1.is_some() {
                            spec.second.key
                        } else {
                            spec.first.key
                        };
                        self.input_note(
                            key,
                            format!(
                                "{} changed width from {} on the loom to {} off it. With draw-in \
                                 and width shrinkage taken separately, that change is not counted.",
                                capitalize(&s.citation()),
                                on.value.describe(),
                                off.value.describe()
                            ),
                        );
                    }
                }
            }
        }
        let (l1, k1) = first?;
        let (l2, k2) = second?;
        Some(Factor {
            factor: (1.0 - l1) * (1.0 - l2),
            losses: vec![l1, l2],
            keys: vec![k1, k2],
        })
    }

    /// Both losses of a direction taken together from the swatch.
    fn combined(&mut self, spec: &DirectionSpec, whole: SwatchLoss) -> Option<Factor> {
        let s = self.swatch?;
        if !(MIN_LOSS..=MAX_LOSS).contains(&whole.loss) {
            self.issue(
                "plan.swatch_out_of_range",
                IssueKind::Invalid,
                spec.combined_key,
                format!(
                    "{} {} from {} {} to {} after wet finishing, outside the {} to {} a plan \
                     takes. Check its measurements, or enter your own {} and {}.",
                    capitalize(&s.citation()),
                    changes(whole.loss),
                    whole.from.describe(),
                    spec.first_phrase,
                    whole.to.describe(),
                    percent(MIN_LOSS),
                    percent(MAX_LOSS),
                    spec.first.label.to_lowercase(),
                    spec.second.label.to_lowercase()
                ),
            );
            return None;
        }
        self.push_input(TracedInput {
            key: spec.combined_key.to_string(),
            label: spec.combined_label.to_string(),
            value: loss_value(whole.loss, spec.combined_denominator),
            source: whole.source,
            basis: format!(
                "from {} {} and {} after wet finishing ({}), {}",
                whole.from.describe(),
                spec.first_phrase,
                whole.to.describe(),
                whole.source.as_str(),
                s.citation()
            ),
            swatch_id: Some(s.id.clone()),
            material_id: None,
        });
        if whole.loss < 0.0 {
            let text = if spec.width {
                format!(
                    "{} finished wider than it was in the reed, as weft-faced cloth can, so the warp \
                     is planned narrower than the finished width.",
                    capitalize(&s.citation())
                )
            } else {
                format!(
                    "{} came out longer after finishing than on the loom, so the warp is planned \
                     shorter than the finished length. Check the measurements.",
                    capitalize(&s.citation())
                )
            };
            self.input_note(spec.combined_key, text);
        }
        // The parts, when the swatch has them, for information, next to the input.
        if let Some((first, first_to, second_from, last)) = self.swatch_stages(spec) {
            if let (Some(a), Some(b)) = (
                self.swatch_loss(first, first_to),
                self.swatch_loss(second_from, last),
            ) {
                let mut note = format!(
                    "Of that, {} measured {} {} ({} to {}) and {} {} ({} to {}).",
                    s.citation(),
                    spec.first.label.to_lowercase(),
                    loss_value(a.loss, spec.first.denominator),
                    a.from.describe(),
                    a.to.describe(),
                    spec.second.label.to_lowercase(),
                    loss_value(b.loss, spec.second.denominator),
                    b.from.describe(),
                    b.to.describe()
                );
                // The width parts leave a gap (on the loom to off it) that the total counts.
                if spec.width && loss(a.to, b.from).abs() > 0.005 {
                    note.push_str(&format!(
                        " The total also counts its change from {} on the loom to {} off it.",
                        a.to.describe(),
                        b.from.describe()
                    ));
                }
                self.input_note(spec.combined_key, note);
            }
        }
        Some(Factor {
            factor: 1.0 - whole.loss,
            losses: vec![whole.loss],
            keys: vec![spec.combined_key.to_string()],
        })
    }

    /// One loss: the override, else the swatch's, else the starting estimate.
    fn part(
        &mut self,
        spec: &PartSpec,
        over: Option<f64>,
        from_swatch: Option<SwatchLoss>,
        first: bool,
        dir: &DirectionSpec,
    ) -> Option<(f64, String)> {
        let key = spec.key.to_string();
        if let Some(v) = over {
            if !self.loss_usable(spec.key, spec.label, spec.denominator, v) {
                return None;
            }
            self.entered(spec.key, spec.label, loss_value(v, spec.denominator));
            return Some((v, key));
        }
        if let (Some(s), Some(m)) = (self.swatch, from_swatch) {
            if !(MIN_LOSS..=MAX_LOSS).contains(&m.loss) {
                self.issue(
                    "plan.swatch_out_of_range",
                    IssueKind::Invalid,
                    spec.key,
                    format!(
                        "{} gives a {} of {} ({} {} to {} {}), outside the {} to {} a plan takes. \
                         Check its measurements, or enter your own.",
                        capitalize(&s.citation()),
                        spec.label.to_lowercase(),
                        loss_value(m.loss, spec.denominator),
                        m.from.describe(),
                        spec.from_phrase,
                        m.to.describe(),
                        spec.to_phrase,
                        percent(MIN_LOSS),
                        percent(MAX_LOSS)
                    ),
                );
                return None;
            }
            self.push_input(TracedInput {
                key: key.clone(),
                label: spec.label.to_string(),
                value: loss_value(m.loss, spec.denominator),
                source: m.source,
                basis: format!(
                    "from {} {} and {} {} ({}), {}",
                    m.from.describe(),
                    spec.from_phrase,
                    m.to.describe(),
                    spec.to_phrase,
                    m.source.as_str(),
                    s.citation()
                ),
                swatch_id: Some(s.id.clone()),
                material_id: None,
            });
            return Some((m.loss, key));
        }
        let v = match (dir.width, first) {
            (false, true) => self.est.take_up,
            (false, false) => self.est.length_shrinkage,
            (true, true) => self.est.draw_in,
            (true, false) => self.est.width_shrinkage,
        };
        // A chosen swatch that lacks one of the two measurements says so (a recorded one it cannot
        // use was an issue above).
        let why = self.swatch.map(|s| {
            format!(
                "{} does not record the {} {} and {}",
                s.citation(),
                if dir.width { "width" } else { "length" },
                spec.from_phrase,
                spec.to_phrase
            )
        });
        self.estimate(spec.key, spec.label, loss_value(v, spec.denominator), why);
        Some((v, key))
    }

    // --- the other assumptions -------------------------------------------------------------------

    fn weft_allowance(&mut self) -> Option<f64> {
        const DENOMINATOR: &str = "of the width in the reed, added to each pick";
        match self.plan.overrides.weft_allowance {
            Some(v) => {
                if !v.is_finite() {
                    self.issue(
                        "quantity.not_finite",
                        IssueKind::Invalid,
                        "weft_allowance",
                        "The weft allowance is not a number.".into(),
                    );
                    return None;
                }
                if !(0.0..=MAX_WEFT_ALLOWANCE).contains(&v) {
                    self.issue(
                        "plan.out_of_range",
                        IssueKind::Invalid,
                        "weft_allowance",
                        format!(
                            "The weft allowance must be from 0% to {} {DENOMINATOR}.",
                            percent(MAX_WEFT_ALLOWANCE)
                        ),
                    );
                    return None;
                }
                self.entered(
                    "weft_allowance",
                    "Weft allowance",
                    format!("{} {DENOMINATOR}", percent(v)),
                );
                Some(v)
            }
            None => {
                let v = self.est.weft_allowance;
                self.estimate(
                    "weft_allowance",
                    "Weft allowance",
                    format!("{} {DENOMINATOR}", percent(v)),
                    Some("for the weft's crimp and the turns at the selvedges".into()),
                );
                Some(v)
            }
        }
    }

    /// The loom waste in the short unit.
    fn loom_waste(&mut self) -> Option<f64> {
        match self.plan.overrides.loom_waste {
            Some(l) => {
                if let Some((code, message)) = nonnegative_problem("loom waste", l) {
                    self.issue(code, IssueKind::Invalid, "loom_waste", message);
                    return None;
                }
                self.entered(
                    "loom_waste",
                    "Loom waste",
                    format!("{} for the whole warp", l.describe()),
                );
                Some(l.to(self.short))
            }
            None => {
                let l = starting_loom_waste(self.metric);
                self.inputs.push(TracedInput {
                    key: "loom_waste".into(),
                    label: "Loom waste".into(),
                    value: format!("{} for the whole warp", l.describe()),
                    source: Source::Default,
                    basis: "Ply's starting estimate; your own loom's waste is better".into(),
                    swatch_id: None,
                    material_id: None,
                });
                Some(l.to(self.short))
            }
        }
    }

    /// A sett or picks count that is usable: positive, and 0.01 to 1000 per inch.
    fn density_usable(&mut self, key: &str, what: &str, c: CountOver) -> bool {
        if let Some(p) = c.problem() {
            self.issue(
                p.code(),
                IssueKind::Invalid,
                key,
                format!(
                    "The {what} {}: give a count above 0 over a span above 0.",
                    p.phrase()
                ),
            );
            return false;
        }
        let per_inch = c.per_unit(LengthUnit::Inch);
        if !(MIN_SETT_PER_INCH..=MAX_SETT_PER_INCH).contains(&per_inch) {
            self.issue(
                "plan.out_of_range",
                IssueKind::Invalid,
                key,
                format!(
                    "The {what} must be from {} to {} per inch.",
                    number(MIN_SETT_PER_INCH),
                    number(MAX_SETT_PER_INCH)
                ),
            );
            return false;
        }
        true
    }

    /// A sett or picks count the swatch recorded: usable as [`Self::density_usable`] asks, else an
    /// issue naming the swatch (never a quiet fall back to another source).
    fn swatch_density_usable(
        &mut self,
        key: &str,
        what: &str,
        instead: &str,
        c: CountOver,
    ) -> bool {
        let Some(s) = self.swatch else {
            return false;
        };
        let reason = match c.problem() {
            Some(p) => Some(p.phrase().to_string()),
            None => {
                let per_inch = c.per_unit(LengthUnit::Inch);
                (!(MIN_SETT_PER_INCH..=MAX_SETT_PER_INCH).contains(&per_inch)).then(|| {
                    format!(
                        "is outside the {} to {} per inch a plan takes",
                        number(MIN_SETT_PER_INCH),
                        number(MAX_SETT_PER_INCH)
                    )
                })
            }
        };
        match reason {
            None => true,
            Some(reason) => {
                self.issue(
                    "plan.swatch_out_of_range",
                    IssueKind::Invalid,
                    key,
                    format!(
                        "{} records its {what} as {}, which {reason}. Check its measurements, or \
                         enter {instead} of your own.",
                        capitalize(&s.citation()),
                        c.describe(if key == "sett" { "ends" } else { "picks" })
                    ),
                );
                false
            }
        }
    }

    /// The starting sett from wraps: the structure's share of the wraps, rounded to a whole end per
    /// inch (or a tenth per cm when the wraps were counted per cm).
    fn sett_from_wraps(&self, wraps: CountOver) -> CountOver {
        let f = self.est.sett_fraction;
        if wraps.over.unit.is_metric() {
            let per_cm = (wraps.per_unit(LengthUnit::Centimeter) * f * 10.0).round() / 10.0;
            CountOver::new(per_cm, Length::cm(1.0))
        } else {
            let per_in = (wraps.per_unit(LengthUnit::Inch) * f).round();
            CountOver::new(per_in, Length::inches(1.0))
        }
    }

    fn sett_input(&mut self, sett: CountOver, source: Source, basis: String, swatch: bool) {
        self.push_input(TracedInput {
            key: "sett".into(),
            label: "Sett".into(),
            value: sett.describe("ends"),
            source,
            basis,
            swatch_id: if swatch {
                self.swatch.map(|s| s.id.clone())
            } else {
                None
            },
            material_id: None,
        });
    }

    /// A starting sett from `wraps` (already listed as the "wpi" input).
    fn preset_sett(&mut self, wraps: CountOver, from: SettFrom) -> Option<SettUsed> {
        let sett = self.sett_from_wraps(wraps);
        if !self.density_usable("wpi", "sett from the wraps per inch", sett) {
            return None;
        }
        let f = self.est.sett_fraction;
        self.sett_input(
            sett,
            Source::Default,
            format!(
                "Ply's starting approximation for {}: {} of {}",
                self.plan.structure.phrase(),
                number(f),
                wraps.describe("wraps")
            ),
            false,
        );
        Some(SettUsed {
            sett,
            keys: vec!["wpi".into(), "sett".into()],
            from,
        })
    }

    fn sett(&mut self) -> Option<SettUsed> {
        let o = &self.plan.overrides;
        if let Some(sett) = o.sett {
            if !self.density_usable("sett", "sett", sett) {
                return None;
            }
            self.entered("sett", "Sett", sett.describe("ends"));
            return Some(SettUsed {
                sett,
                keys: vec!["sett".into()],
                from: SettFrom::Entered,
            });
        }
        if let Some(wraps) = o.wpi {
            if !self.density_usable("wpi", "wraps per inch", wraps) {
                return None;
            }
            self.entered("wpi", "Wraps per inch", wraps.describe("wraps"));
            return self.preset_sett(wraps, SettFrom::Wpi);
        }
        if let Some(s) = self.req.loom_sett.filter(|s| s.is_valid()) {
            let sett = sett_count(s);
            self.sett_input(
                sett,
                Source::Entered,
                "from Loom for this draft".into(),
                false,
            );
            return Some(SettUsed {
                sett,
                keys: vec!["sett".into()],
                from: SettFrom::Loom,
            });
        }
        if let Some(s) = self.swatch {
            if let Some(r) = s.sett {
                if !self.swatch_density_usable("sett", "sett in the reed", "a sett", r.value) {
                    return None;
                }
                self.sett_input(
                    r.value,
                    r.source,
                    format!(
                        "the sett in the reed, {}, {}",
                        r.source.as_str(),
                        s.citation()
                    ),
                    true,
                );
                return Some(SettUsed {
                    sett: r.value,
                    keys: vec!["sett".into()],
                    from: SettFrom::Swatch,
                });
            }
        }
        if let Some(s) = self.req.draft.file_sett.filter(|s| s.is_valid()) {
            let sett = sett_count(s);
            self.sett_input(
                sett,
                Source::Entered,
                "from this draft's file".into(),
                false,
            );
            return Some(SettUsed {
                sett,
                keys: vec!["sett".into()],
                from: SettFrom::File,
            });
        }
        if let Some(m) = self.req.warp {
            if let Some(r) = m.wpi.filter(|r| r.value.problem().is_none()) {
                self.push_input(TracedInput {
                    key: "wpi".into(),
                    label: "Wraps per inch".into(),
                    value: r.value.describe("wraps"),
                    source: r.source,
                    basis: format!("{}, material {}", r.source.as_str(), m.display_name()),
                    swatch_id: None,
                    material_id: Some(m.id.clone()),
                });
                return self.preset_sett(r.value, SettFrom::Yarn);
            }
        }
        self.issue(
            "plan.needs_sett",
            IssueKind::Needed,
            "sett",
            "Enter a sett, or the wraps per inch of the warp yarn, to work out the ends and the width \
             in the reed."
                .into(),
        );
        None
    }

    /// Picks over a span: the override, the swatch's count on the loom, else the sett.
    fn ppi(&mut self, sett: Option<&SettUsed>) -> Option<(CountOver, Vec<String>)> {
        if let Some(c) = self.plan.overrides.ppi {
            if !self.density_usable("ppi", "picks", c) {
                return None;
            }
            self.entered("ppi", "Picks", c.describe("picks"));
            return Some((c, vec!["ppi".into()]));
        }
        if let Some(s) = self.swatch {
            if s.on_loom.along.is_none() && (s.before.along.is_some() || s.after.along.is_some()) {
                self.input_note(
                    "ppi",
                    format!(
                        "{} counted picks only off the loom. They sit closer there than under \
                         tension, and the weft is worked out from the length woven on the loom, \
                         so the plan does not use them. Count the picks on the loom, or enter your \
                         own.",
                        capitalize(&s.citation())
                    ),
                );
            }
            if let Some(r) = s.on_loom.along {
                if self.swatch_density_usable(
                    "ppi",
                    "picks counted on the loom",
                    "the picks",
                    r.value,
                ) {
                    self.push_input(TracedInput {
                        key: "ppi".into(),
                        label: "Picks".into(),
                        value: r.value.describe("picks"),
                        source: r.source,
                        basis: s.basis(r.source, Some(StageKind::OnLoom)),
                        swatch_id: Some(s.id.clone()),
                        material_id: None,
                    });
                    return Some((r.value, vec!["ppi".into()]));
                }
                return None;
            }
        }
        let sett = sett?;
        let c = sett.sett;
        self.push_input(TracedInput {
            key: "ppi".into(),
            label: "Picks".into(),
            value: c.describe("picks"),
            source: Source::Default,
            basis: "Ply's starting estimate: as many picks as ends, a balanced weave".into(),
            swatch_id: None,
            material_id: None,
        });
        let mut keys = vec!["ppi".to_string()];
        keys.extend(sett.keys.iter().cloned());
        Some((c, keys))
    }

    fn strands(&mut self) -> Option<f64> {
        let s = self.req.draft.mean_strands;
        if !s.is_finite() || !(1.0..=MAX_MEAN_STRANDS).contains(&s) {
            self.issue(
                "plan.out_of_range",
                IssueKind::Invalid,
                "strands",
                "The draft's strands per pick must be 1 or more.".into(),
            );
            return None;
        }
        if s != 1.0 {
            self.push_input(TracedInput {
                key: "strands".into(),
                label: "Strands per pick".into(),
                value: format!("{} on average", number(s)),
                source: Source::Entered,
                basis: "from this draft".into(),
                swatch_id: None,
                material_id: None,
            });
        }
        Some(s)
    }

    // --- width -----------------------------------------------------------------------------------

    fn width_section(
        &mut self,
        t: &Targets,
        sett: Option<&SettUsed>,
        factor: Option<&Factor>,
    ) -> Option<WidthResult> {
        let sett = sett?;
        let per = sett.sett.per_unit(self.short);
        let sett_text = CountOver::new(per, Length::new(1.0, self.short)).describe("ends");
        let sym = self.short.symbol();
        let mut keys: Vec<String> = sett.keys.clone();
        let ends: u32;
        let mut working = Vec::new();
        let mut rounded = false;
        // The repeat and the extra ends apply only to ends worked out from the finished width.
        let unapplied = |w: &mut Self| {
            if w.plan.end_multiple.is_some() || w.plan.extra_ends > 0 {
                w.input_note(
                    "ends",
                    "The ends in a repeat and the extra ends apply only to ends worked out from \
                     the finished width, so they are not used here."
                        .into(),
                );
            }
        };
        if let Some(e) = self.plan.overrides.ends {
            if !(1..=MAX_PLAN_COUNT).contains(&e) {
                self.issue(
                    "plan.out_of_range",
                    IssueKind::Invalid,
                    "ends",
                    format!("The warp ends must be a whole number from 1 to {MAX_PLAN_COUNT}."),
                );
                return None;
            }
            self.entered("ends", "Warp ends", e.to_string());
            unapplied(self);
            ends = e;
            keys.push("ends".into());
            working.push(format!("You entered {e} ends."));
        } else {
            match (&t.finished_width, factor) {
                (Read::Ok(w), Some(f)) => {
                    let (Some(multiple), Some(extra)) = (t.end_multiple, t.extra_ends) else {
                        return None;
                    };
                    let target = w.to(self.short) / f.factor;
                    let mut tkeys = vec!["finished_width".to_string()];
                    tkeys.extend(f.keys.iter().cloned());
                    self.figure(
                        "width_in_reed_target",
                        "Width in the reed for the finished width",
                        target,
                        FigureUnit::Length(self.short),
                        self.both(target, self.short),
                        vec![format!(
                            "{} finished {} = {} {sym} in the reed.",
                            w.converted(self.short).describe(),
                            f.divided(),
                            number(target)
                        )],
                        tkeys.clone(),
                    );
                    let raw = target * per;
                    let m = f64::from(multiple);
                    let base = ((raw / m).round() * m).max(m);
                    let total = base + f64::from(extra);
                    if !total.is_finite() || total > f64::from(MAX_PLAN_COUNT) {
                        self.issue(
                            "plan.result_too_large",
                            IssueKind::Invalid,
                            "finished_width",
                            format!(
                                "{} at {sett_text} needs {} ends, more than the {MAX_PLAN_COUNT} a \
                                 plan takes.",
                                self.short_text(target),
                                number(total)
                            ),
                        );
                        return None;
                    }
                    ends = total as u32;
                    let mut step = format!(
                        "{} {sym} x {sett_text} = {} ends",
                        number(target),
                        number(raw)
                    );
                    if self.plan.end_multiple.is_some() {
                        self.entered("end_multiple", "Ends in a repeat", multiple.to_string());
                        keys.push("end_multiple".into());
                    }
                    if multiple > 1 {
                        step.push_str(&format!(
                            ", rounded to {} (a multiple of {multiple})",
                            number(base)
                        ));
                    } else {
                        step.push_str(&format!(", rounded to {}", number(base)));
                    }
                    if extra > 0 {
                        self.entered("extra_ends", "Extra ends", extra.to_string());
                        step.push_str(&format!(", plus {extra} = {ends} ends"));
                        keys.push("extra_ends".into());
                    }
                    rounded = multiple > 1 || extra > 0;
                    step.push('.');
                    working.push(step);
                    keys.extend(tkeys);
                }
                (Read::Ok(_), None) | (Read::Bad, _) => return None,
                (Read::Missing, _) => {
                    let draft = self.req.draft.ends;
                    if draft == 0 || draft > MAX_PLAN_COUNT as usize {
                        self.issue(
                            "plan.needs_width",
                            IssueKind::Needed,
                            "finished_width",
                            "Enter a finished width, or the warp ends, to work out the width in \
                             the reed."
                                .into(),
                        );
                        return None;
                    }
                    ends = draft as u32;
                    self.push_input(TracedInput {
                        key: "ends".into(),
                        label: "Warp ends".into(),
                        value: ends.to_string(),
                        source: Source::Entered,
                        basis: "from this draft's ends".into(),
                        swatch_id: None,
                        material_id: None,
                    });
                    unapplied(self);
                    keys.push("ends".into());
                    working.push(format!("This draft threads {ends} ends."));
                }
            }
        }
        self.figure(
            "warp_ends",
            "Warp ends",
            f64::from(ends),
            FigureUnit::Count,
            format!("{ends} ends"),
            working,
            keys.clone(),
        );
        let reed_width = f64::from(ends) / per;
        self.figure(
            "width_in_reed",
            "Width in the reed",
            reed_width,
            FigureUnit::Length(self.short),
            self.both(reed_width, self.short),
            vec![format!(
                "{ends} ends / {sett_text} = {} {sym} in the reed.",
                number(reed_width)
            )],
            keys.clone(),
        );
        if let Some(f) = factor {
            let expected = reed_width * f.factor;
            let mut ukeys = keys.clone();
            ukeys.extend(f.keys.iter().cloned());
            self.figure(
                "finished_width",
                "Finished width, expected",
                expected,
                FigureUnit::Length(self.short),
                self.both(expected, self.short),
                vec![format!(
                    "{} {sym} {} = {} {sym} after wet finishing.",
                    number(reed_width),
                    f.multiplied(),
                    number(expected)
                )],
                ukeys,
            );
        }
        Some(WidthResult {
            ends,
            reed_width,
            keys,
            rounded,
        })
    }

    fn denting(&mut self, width: &WidthResult, sett: &SettUsed) {
        let loom = self.req.loom;
        let (reeds, from_loom) = match self.plan.overrides.reed {
            Some(r) => {
                if !(r.dents.is_finite() && r.dents > 0.0 && r.dents <= crate::loom::MAX_REED_DENTS)
                {
                    self.issue(
                        "plan.out_of_range",
                        IssueKind::Invalid,
                        "reed",
                        format!(
                            "The reed must have from more than 0 to {} dents per inch or per 10 cm.",
                            number(crate::loom::MAX_REED_DENTS)
                        ),
                    );
                    return;
                }
                (vec![r], false)
            }
            None => match loom {
                Some(l) if !l.reeds.is_empty() => (l.reeds.clone(), true),
                Some(l) => {
                    self.checks.push(PlanCheck {
                        code: "plan.reed_unknown",
                        severity: LoomSeverity::NotChecked,
                        message: format!(
                            "{} has no reeds recorded, so no denting was worked out. Add its reeds \
                             in My looms, or enter a reed here.",
                            l.display_name()
                        ),
                    });
                    return;
                }
                None => {
                    self.checks.push(PlanCheck {
                        code: "plan.reed_unknown",
                        severity: LoomSeverity::NotChecked,
                        message: "No loom is chosen for this draft, so no reed was chosen. Choose \
                                  one in Loom for this draft, or enter a reed here."
                            .into(),
                    });
                    return;
                }
            },
        };
        let per_inch = sett.sett.per_unit(LengthUnit::Inch);
        let want = Sett {
            ends: per_inch,
            per: Unit::Inches,
        };
        let wanted = sett.sett.describe("ends");
        let Some(s) = best_sleying(&reeds, want) else {
            let needs: Vec<String> = reeds
                .iter()
                .take(3)
                .map(|r| {
                    format!(
                        "{} would need {} per dent",
                        r.describe(),
                        number(per_inch / r.dents_per_inch())
                    )
                })
                .collect();
            self.checks.push(PlanCheck {
                code: "plan.reed_none_fits",
                severity: LoomSeverity::Advice,
                message: format!(
                    "No reed gives {wanted} with a regular sleying: {}. Sley it unevenly, or use \
                     another reed.",
                    needs.join(", ")
                ),
            });
            return;
        };
        let reed_name = s.reed.describe();
        let mut uses = width.keys.clone();
        if from_loom {
            let l = loom.map(|l| l.display_name()).unwrap_or_default();
            self.push_input(TracedInput {
                key: "reed".into(),
                label: "Reed".into(),
                value: reed_label(s.reed),
                source: Source::Entered,
                basis: format!("the best of {l}'s reeds for the sett (Loom for this draft)"),
                swatch_id: None,
                material_id: None,
            });
        } else {
            self.entered("reed", "Reed", reed_label(s.reed));
        }
        uses.push("reed".into());
        let order_text = s
            .pattern
            .iter()
            .map(|n| n.to_string())
            .collect::<Vec<_>>()
            .join(", ");
        let dents = dents_for(width.ends, &s.pattern);
        let dpi = s.reed.dents_per_inch();
        let span = Length::inches(f64::from(dents) / dpi).to(self.short);
        let regular = s.pattern.len() == 1 && s.pattern[0] <= MAX_EVEN_PER_DENT;
        let how = if s.pattern.len() == 1 {
            format!("{} per dent", s.pattern[0])
        } else {
            format!("{order_text}, repeated")
        };
        let gives = if s.exact {
            format!("for {wanted}")
        } else {
            let unit = if self.metric {
                Unit::Centimeters
            } else {
                Unit::Inches
            };
            format!("for {}, close to {wanted}", s.achieved(unit))
        };
        let text = format!(
            "Sley {reed_name} {how} {gives}: {} ends fill {dents} dents, about {}.",
            width.ends,
            self.both(span, self.short)
        );
        let sum: u32 = s.pattern.iter().sum();
        let working = vec![
            format!(
                "{} ends over {sum} ends in every {} of {reed_name} ({order_text}) fill {dents} \
                 dents.",
                width.ends,
                plural(s.pattern.len(), "dent")
            ),
            format!(
                "{dents} dents / {} dents per inch = {} {}.",
                number(dpi),
                number(span),
                self.short.symbol()
            ),
        ];
        self.checks.push(if regular {
            PlanCheck {
                code: "plan.reed_fits",
                severity: LoomSeverity::Fits,
                message: format!("Sley {reed_name} {how} {gives}."),
            }
        } else {
            PlanCheck {
                code: "plan.reed_irregular",
                severity: LoomSeverity::Advice,
                message: if s.pattern.len() == 1 {
                    format!(
                        "Sley {reed_name} {how} {gives}; that many ends in one dent can mark the \
                         cloth, so a finer reed would be better."
                    )
                } else {
                    format!(
                        "No reed gives {wanted} with the same number of ends in every dent. Sley \
                         {reed_name} {order_text}, repeated across the warp, {gives}."
                    )
                },
            }
        });
        self.denting = Some(DentingPlan {
            reed: s.reed,
            order: s.pattern.clone(),
            achieved_per_inch: s.achieved_per_inch,
            exact: s.exact,
            dents,
            width: Length::new(span, self.short),
            text,
            working,
            uses,
        });
    }

    fn loom_width(&mut self, width: &WidthResult) {
        let Some(loom) = self.req.loom else {
            return;
        };
        let name = loom.display_name();
        let reed = self.both(width.reed_width, self.short);
        match loom.weaving_width {
            Some(w) if w.value.is_finite() && w.value > 0.0 => {
                let loom_in = w.inches();
                let reed_in = Length::new(width.reed_width, self.short).to(LengthUnit::Inch);
                let loom_text = match w.unit {
                    Unit::Inches => format!("{} in", number(w.value)),
                    Unit::Centimeters => format!("{} cm", number(w.value)),
                };
                self.checks.push(if reed_in <= loom_in * (1.0 + 1e-9) {
                    PlanCheck {
                        code: "plan.loom_width_fits",
                        severity: LoomSeverity::Fits,
                        message: format!(
                            "{reed} in the reed fits {name}'s {loom_text} weaving width."
                        ),
                    }
                } else {
                    PlanCheck {
                        code: "plan.loom_width_exceeded",
                        severity: LoomSeverity::NotFeasible,
                        message: format!(
                            "{reed} in the reed is wider than {name}'s {loom_text} weaving width. \
                             Plan fewer ends or a narrower cloth, or weave it on a wider loom."
                        ),
                    }
                });
            }
            _ => self.checks.push(PlanCheck {
                code: "plan.loom_width_unknown",
                severity: LoomSeverity::NotChecked,
                message: format!(
                    "{name}'s weaving width is not recorded, so the width in the reed was not \
                     checked."
                ),
            }),
        }
    }

    // --- length ----------------------------------------------------------------------------------

    fn length_section(
        &mut self,
        t: &Targets,
        factor: Option<&Factor>,
        waste: Option<f64>,
    ) -> Option<WovenResult> {
        let finished = match &t.finished_length {
            Read::Ok(l) => *l,
            Read::Missing => {
                self.issue(
                    "plan.needs_input",
                    IssueKind::Needed,
                    "finished_length",
                    "Enter the finished length to work out the warp and the weft.".into(),
                );
                return None;
            }
            Read::Bad => return None,
        };
        let (Some(f), Some(items), Some(hems), Some(fringe), Some(sampling), Some(waste)) =
            (factor, t.items, t.hems, t.fringe, t.sampling, waste)
        else {
            return None;
        };
        let sym = self.short.symbol();
        let fin = finished.to(self.short);
        let per_item = (fin + hems) / f.factor;
        let mut keys = vec!["finished_length".to_string()];
        if hems > 0.0 {
            keys.push("hems".into());
        }
        keys.extend(f.keys.iter().cloned());
        let woven_step = if hems > 0.0 {
            format!(
                "({} {sym} + {} {sym} hems) {} = {} {sym} woven on the loom for each item.",
                number(fin),
                number(hems),
                f.divided(),
                number(per_item)
            )
        } else {
            format!(
                "{} {sym} {} = {} {sym} woven on the loom for each item.",
                number(fin),
                f.divided(),
                number(per_item)
            )
        };
        self.figure(
            "woven_length",
            "Woven on the loom, each item",
            per_item,
            FigureUnit::Length(self.short),
            self.both(per_item, self.short),
            vec![woven_step],
            keys.clone(),
        );
        let warp = f64::from(items) * (per_item + fringe) + sampling + waste;
        let mut terms = vec![format!("{items} x {} {sym} woven", number(per_item))];
        keys.push("items".into());
        if sampling > 0.0 {
            keys.push("sampling".into());
        }
        let woven_keys = keys.clone();
        if fringe > 0.0 {
            terms.push(format!("{items} x {} {sym} fringe", number(fringe)));
            keys.push("fringe".into());
        }
        if sampling > 0.0 {
            terms.push(format!("{} {sym} sampling", number(sampling)));
        }
        terms.push(format!("{} {sym} loom waste", number(waste)));
        keys.push("loom_waste".into());
        let long = Length::new(warp, self.short).to(self.long);
        if !long.is_finite() || long > MAX_WARP_LENGTH {
            self.issue(
                "plan.result_too_large",
                IssueKind::Invalid,
                "finished_length",
                format!(
                    "The plan comes to {} of warp, more than the {} it works out.",
                    Length::new(long, self.long).describe(),
                    Length::new(MAX_WARP_LENGTH, self.long).describe()
                ),
            );
            return None;
        }
        self.figure(
            "warp_length",
            "Warp length",
            long,
            FigureUnit::Length(self.long),
            self.both(long, self.long),
            vec![format!(
                "{} = {} {sym} = {} {} of warp to wind.",
                terms.join(" + "),
                number(warp),
                number(long),
                self.long.symbol()
            )],
            keys.clone(),
        );
        Some(WovenResult {
            items,
            per_item,
            sampling,
            warp_length: warp,
            woven_keys,
            warp_keys: keys,
        })
    }

    /// The warp yarn in the long unit.
    fn warp_yarn(
        &mut self,
        width: &WidthResult,
        woven: &WovenResult,
    ) -> Option<(f64, Vec<String>)> {
        let long = Length::new(woven.warp_length, self.short).to(self.long);
        let total = long * f64::from(width.ends);
        if !total.is_finite() || total > MAX_YARN_LENGTH {
            self.issue(
                "plan.result_too_large",
                IssueKind::Invalid,
                "ends",
                format!(
                    "The plan comes to {} of warp yarn, more than the {} it works out.",
                    Length::new(total, self.long).describe(),
                    Length::new(MAX_YARN_LENGTH, self.long).describe()
                ),
            );
            return None;
        }
        let mut keys = woven.warp_keys.clone();
        keys.extend(width.keys.iter().cloned());
        dedup(&mut keys);
        let lsym = self.long.symbol();
        self.figure(
            "warp_yarn",
            "Warp yarn",
            total,
            FigureUnit::Length(self.long),
            self.both(total, self.long),
            vec![format!(
                "{} {lsym} x {} ends = {} {lsym} of warp yarn.",
                number(long),
                width.ends,
                number(total)
            )],
            keys.clone(),
        );
        Some((total, keys))
    }

    /// The weft yarn in the long unit.
    fn weft(
        &mut self,
        width: &WidthResult,
        woven: &WovenResult,
        ppi: &(CountOver, Vec<String>),
        allowance: f64,
        strands: f64,
    ) -> Option<(f64, Vec<String>)> {
        let sym = self.short.symbol();
        let per = ppi.0.per_unit(self.short);
        let per_text = CountOver::new(per, Length::new(1.0, self.short)).describe("picks");
        let item_raw = per * woven.per_item;
        let item_picks = item_raw.round();
        let sample_raw = per * woven.sampling;
        let sample_picks = sample_raw.round();
        let picks = f64::from(woven.items) * item_picks + sample_picks;
        if !picks.is_finite() || picks > MAX_PICKS {
            self.issue(
                "plan.result_too_large",
                IssueKind::Invalid,
                "ppi",
                format!(
                    "The plan comes to {} picks, more than the {} it works out.",
                    number(picks),
                    number(MAX_PICKS)
                ),
            );
            return None;
        }
        let mut keys = ppi.1.clone();
        keys.extend(woven.woven_keys.iter().cloned());
        let mut step = format!(
            "{per_text} x {} {sym} = {}, so {} picks for each item; x {} = {} picks",
            number(woven.per_item),
            number(item_raw),
            number(item_picks),
            woven.items,
            number(f64::from(woven.items) * item_picks)
        );
        if woven.sampling > 0.0 {
            step.push_str(&format!(
                ", plus {per_text} x {} {sym} sampling = {}: {} picks",
                number(woven.sampling),
                number(sample_picks),
                number(picks)
            ));
        }
        step.push('.');
        dedup(&mut keys);
        self.figure(
            "weft_picks",
            "Picks",
            picks,
            FigureUnit::Count,
            format!("{} picks", number(picks)),
            vec![step],
            keys.clone(),
        );
        let per_pick = width.reed_width * (1.0 + allowance);
        let mut pick_keys = width.keys.clone();
        pick_keys.push("weft_allowance".into());
        dedup(&mut pick_keys);
        self.figure(
            "weft_per_pick",
            "Weft in each pick",
            per_pick,
            FigureUnit::Length(self.short),
            self.both(per_pick, self.short),
            vec![format!(
                "{} {sym} in the reed x (1 + {}) = {} {sym} of weft in each pick.",
                number(width.reed_width),
                percent(allowance),
                number(per_pick)
            )],
            pick_keys.clone(),
        );
        let short_total = picks * per_pick * strands;
        let total = Length::new(short_total, self.short).to(self.long);
        if !total.is_finite() || total > MAX_YARN_LENGTH {
            self.issue(
                "plan.result_too_large",
                IssueKind::Invalid,
                "ends",
                format!(
                    "The plan comes to {} of weft, more than the {} it works out.",
                    Length::new(total, self.long).describe(),
                    Length::new(MAX_YARN_LENGTH, self.long).describe()
                ),
            );
            return None;
        }
        let lsym = self.long.symbol();
        let mut working = vec![format!(
            "{} picks x {} {sym} = {} {sym} = {} {lsym} of weft.",
            number(picks),
            number(per_pick),
            number(picks * per_pick),
            number(Length::new(picks * per_pick, self.short).to(self.long))
        )];
        keys.extend(pick_keys);
        if strands != 1.0 {
            working.push(format!(
                "x {} strands per pick on average = {} {lsym}.",
                number(strands),
                number(total)
            ));
            keys.push("strands".into());
        }
        dedup(&mut keys);
        self.figure(
            "weft_yarn",
            "Weft yarn",
            total,
            FigureUnit::Length(self.long),
            self.both(total, self.long),
            working,
            keys.clone(),
        );
        Some((total, keys))
    }

    // --- supply ----------------------------------------------------------------------------------

    fn supply(&mut self, warp: Option<(f64, Vec<String>)>, weft: Option<(f64, Vec<String>)>) {
        let (wm, fm) = (self.req.warp, self.req.weft);
        match (wm, fm) {
            (Some(a), Some(b)) if a.id == b.id => match (warp, weft) {
                (Some((wn, wk)), Some((fnd, fk))) => {
                    let mut keys = wk;
                    keys.extend(fk);
                    dedup(&mut keys);
                    let lsym = self.long.symbol();
                    let step = format!(
                        "{} {lsym} of warp + {} {lsym} of weft = {} {lsym}.",
                        number(wn),
                        number(fnd),
                        number(wn + fnd)
                    );
                    self.line(a, SupplyRole::WarpAndWeft, wn + fnd, keys, Some(step), None);
                }
                // One yarn for both, one of them not worked out: the line says so and claims no
                // leftover.
                (Some((n, k)), None) => self.line(a, SupplyRole::Warp, n, k, None, Some("weft")),
                (None, Some((n, k))) => self.line(a, SupplyRole::Weft, n, k, None, Some("warp")),
                (None, None) => {}
            },
            _ => {
                if let (Some(m), Some((n, k))) = (wm, warp) {
                    self.line(m, SupplyRole::Warp, n, k, None, None);
                }
                if let (Some(m), Some((n, k))) = (fm, weft) {
                    self.line(m, SupplyRole::Weft, n, k, None, None);
                }
            }
        }
    }

    /// One yarn's line. `missing` names the other use of the same yarn when it is not worked out
    /// yet: the need is then only part of it, and nothing is said to be left over.
    fn line(
        &mut self,
        m: &Material,
        role: SupplyRole,
        need: f64,
        mut uses: Vec<String>,
        first_step: Option<String>,
        missing: Option<&str>,
    ) {
        let lsym = self.long.symbol();
        let name = m.display_name();
        let rk = role.key();
        let lpm = m.length_per_mass.filter(|r| r.value.problem().is_none());
        let mut working: Vec<String> = first_step.into_iter().collect();
        let need_mass = lpm.map(|r| {
            let unit = r.value.mass.unit;
            Mass::new(r.value.mass_for(Length::new(need, self.long), unit), unit)
        });
        if let (Some(r), Some(nm)) = (lpm, need_mass) {
            self.push_input(TracedInput {
                key: format!("{rk}_length_per_mass"),
                label: format!("{} length per mass", capitalize(role.noun())),
                value: r.value.describe(),
                source: r.source,
                basis: format!("{}, material {name}", r.source.as_str()),
                swatch_id: None,
                material_id: Some(m.id.clone()),
            });
            uses.push(format!("{rk}_length_per_mass"));
            working.push(format!(
                "{} {lsym} at {} = {} {}.",
                number(need),
                r.value.describe(),
                number(nm.value),
                nm.unit.symbol()
            ));
        }
        let on_hand_key = format!("{rk}_on_hand");
        let on_hand_label = format!("{} on hand", capitalize(role.noun()));
        // A mass on hand with no length per mass is named, but cannot be compared.
        let mut mass_only = None;
        let on_hand = match (
            m.available_length.filter(|r| r.value.problem().is_none()),
            m.available_mass.filter(|r| r.value.problem().is_none()),
            lpm,
        ) {
            (Some(r), _, _) => {
                self.push_input(TracedInput {
                    key: on_hand_key.clone(),
                    label: on_hand_label,
                    value: r.value.describe(),
                    source: r.source,
                    basis: format!("{}, material {name}", r.source.as_str()),
                    swatch_id: None,
                    material_id: Some(m.id.clone()),
                });
                Some((r.value.to(self.long), false))
            }
            (None, Some(mass), Some(lpm)) => {
                let len = lpm.value.length_for(mass.value, self.long);
                self.push_input(TracedInput {
                    key: on_hand_key.clone(),
                    label: on_hand_label,
                    value: format!("{} (about {} {lsym})", mass.value.describe(), number(len)),
                    source: mass.source,
                    basis: format!(
                        "{}, at {} ({}), material {name}",
                        mass.source.as_str(),
                        lpm.value.describe(),
                        lpm.source.as_str()
                    ),
                    swatch_id: None,
                    material_id: Some(m.id.clone()),
                });
                Some((len, true))
            }
            (None, Some(mass), None) => {
                self.push_input(TracedInput {
                    key: on_hand_key.clone(),
                    label: on_hand_label,
                    value: mass.value.describe(),
                    source: mass.source,
                    basis: format!(
                        "{}, material {name}, which has no length per mass",
                        mass.source.as_str()
                    ),
                    swatch_id: None,
                    material_id: Some(m.id.clone()),
                });
                uses.push(on_hand_key.clone());
                mass_only = Some(mass.value);
                None
            }
            _ => None,
        };
        let mass_text = need_mass
            .map(|nm| format!(" ({})", mass_both(nm)))
            .unwrap_or_default();
        let mut text = format!(
            "{} for {}: needs about {}{mass_text}.",
            capitalize(&name),
            role.noun(),
            Length::new(need, self.long).describe()
        );
        let remaining = match (on_hand, missing) {
            (Some((have, about)), None) => {
                uses.push(on_hand_key.clone());
                let left = have - need;
                working.push(format!(
                    "{}{} {lsym} on hand - {} {lsym} = {} {lsym}.",
                    if about { "about " } else { "" },
                    number(have),
                    number(need),
                    number(left)
                ));
                if left >= 0.0 {
                    text.push_str(&format!(
                        " About {} left over.",
                        Length::new(left, self.long).describe()
                    ));
                } else {
                    text.push_str(&format!(
                        " About {} short.",
                        Length::new(-left, self.long).describe()
                    ));
                }
                Some(Length::new(left, self.long))
            }
            (have, Some(other)) => {
                if let Some((have, about)) = have {
                    uses.push(on_hand_key.clone());
                    text.push_str(&format!(
                        " {}{} on hand.",
                        if about { "About " } else { "" },
                        Length::new(have, self.long).describe()
                    ));
                }
                text.push_str(&format!(
                    " It is the {other} too, which is not worked out yet, so what will be left is \
                     not shown."
                ));
                None
            }
            (None, None) => {
                match mass_only {
                    Some(mass) => text.push_str(&format!(
                        " {} on hand; add the yarn's length per mass to compare.",
                        mass.describe()
                    )),
                    None => text.push_str(" How much is on hand is not recorded."),
                }
                None
            }
        };
        dedup(&mut uses);
        let assumed = self.assumed(&uses);
        self.supply.push(SupplyLine {
            role,
            material_id: m.id.clone(),
            material_name: name,
            need: Length::new(need, self.long),
            need_mass,
            on_hand: on_hand.map(|(l, _)| Length::new(l, self.long)),
            on_hand_about: on_hand.is_some_and(|(_, a)| a),
            remaining,
            text,
            working,
            uses,
            assumed,
        });
    }

    // --- notes -----------------------------------------------------------------------------------

    fn notes(&mut self, sett: Option<&SettUsed>, width: Option<&WidthResult>, t: &Targets) {
        if let Some(sett) = sett {
            let plan_in = sett.sett.per_unit(LengthUnit::Inch);
            if let (Some(s), true) = (self.swatch, sett.from != SettFrom::Swatch) {
                if let Some(r) = s.sett.filter(|r| r.value.problem().is_none()) {
                    let sw_in = r.value.per_unit(LengthUnit::Inch);
                    if ((sw_in - plan_in) / plan_in).abs() > SETT_DIFFERENCE {
                        self.input_note(
                            "sett",
                            format!(
                                "{} was woven at {}; this plan uses {}, so its take-up and \
                                 shrinkage may not carry over.",
                                capitalize(&s.citation()),
                                r.value.describe("ends"),
                                sett.sett.describe("ends")
                            ),
                        );
                    }
                }
            }
            if let (Some(ls), true) = (
                self.req.loom_sett.filter(|s| s.is_valid()),
                sett.from != SettFrom::Loom,
            ) {
                if ((ls.per_inch() - plan_in) / plan_in).abs() > 0.001 {
                    self.input_note(
                        "sett",
                        format!(
                            "The loom check uses {} (Loom for this draft); this plan uses {}.",
                            ls.describe(),
                            sett.sett.describe("ends")
                        ),
                    );
                }
            }
        }
        if let Some(width) = width {
            let draft = self.req.draft.ends;
            let from_draft = self
                .input("ends")
                .is_some_and(|i| i.basis == "from this draft's ends");
            if draft > 0 && !from_draft && draft != width.ends as usize {
                self.notes.push(format!(
                    "This draft threads {draft} ends; the plan needs {}. The plan does not change \
                     the draft.",
                    width.ends
                ));
            }
            // The ends finish well off the width entered: ends entered, or rounded to repeats.
            if let Read::Ok(target) = &t.finished_width {
                let expected = self
                    .figures
                    .iter()
                    .find(|f| f.key == "finished_width")
                    .map(|f| f.value);
                let target_v = target.to(self.short);
                if let Some(expected) = expected {
                    if ((expected - target_v) / target_v).abs() > SETT_DIFFERENCE {
                        if self.plan.overrides.ends.is_some() {
                            self.notes.push(format!(
                                "With {} ends the cloth finishes about {} wide; the finished \
                                 width you entered is {}.",
                                width.ends,
                                self.short_text(expected),
                                target.describe()
                            ));
                        } else if width.rounded {
                            self.notes.push(format!(
                                "Rounded to whole repeats and the extra ends, the {} ends finish \
                                 about {} wide; the finished width you entered is {}.",
                                width.ends,
                                self.short_text(expected),
                                target.describe()
                            ));
                        }
                    }
                }
            }
        }
        if self.inputs.iter().any(|i| i.source == Source::Default) {
            self.notes.push(
                "Inputs marked as Ply's starting estimates are rules of thumb, not measurements. A \
                 sample woven and finished like the project gives better numbers."
                    .into(),
            );
        }
    }

    fn input(&self, key: &str) -> Option<&TracedInput> {
        self.inputs.iter().find(|i| i.key == key)
    }
}

/// A loss the swatch measured.
#[derive(Debug, Clone, Copy)]
struct SwatchLoss {
    loss: f64,
    from: Length,
    to: Length,
    source: Source,
}

/// "(1 - 10%)" for a loss; "(1 + 8.3%)" for a gain (the cloth grew).
fn one_less(l: f64) -> String {
    if l < 0.0 {
        format!("(1 + {})", percent(-l))
    } else {
        format!("(1 - {})", percent(l))
    }
}

/// A loss as a share of `denominator` ("10% of the length on the loom"); a gain reads as a gain
/// ("a gain of 8.3% of the length on the loom").
fn loss_value(l: f64, denominator: &str) -> String {
    if l < 0.0 {
        format!("a gain of {} {denominator}", percent(-l))
    } else {
        format!("{} {denominator}", percent(l))
    }
}

/// "loses 12%" or "gains 60%".
fn changes(l: f64) -> String {
    if l < 0.0 {
        format!("gains {}", percent(-l))
    } else {
        format!("loses {}", percent(l))
    }
}

/// The problem with a length that may be 0: (code, message).
fn nonnegative_problem(what: &str, l: Length) -> Option<(&'static str, String)> {
    if !l.value.is_finite() {
        Some((
            "quantity.not_finite",
            format!("The {what} is not a number."),
        ))
    } else if l.value < 0.0 {
        Some(("plan.negative", format!("The {what} must be 0 or more.")))
    } else if l.value > MAX_QUANTITY_VALUE {
        Some(("quantity.too_large", format!("The {what} is too large.")))
    } else {
        None
    }
}

/// A loom-check sett as a count over one inch or one cm.
fn sett_count(s: Sett) -> CountOver {
    match s.per {
        Unit::Inches => CountOver::new(s.ends, Length::inches(1.0)),
        Unit::Centimeters => CountOver::new(s.ends, Length::cm(1.0)),
    }
}

/// "12 dents per inch", "40 dents per 10 cm".
fn reed_label(r: Reed) -> String {
    match r.per {
        DentUnit::PerInch => format!("{} dents per inch", number(r.dents)),
        DentUnit::Per10Cm => format!("{} dents per 10 cm", number(r.dents)),
    }
}

/// The dents `ends` fill when sleyed in `order` (most first, repeated across the warp): whole
/// repeats, then the dents of the order the rest needs, so a last part repeat is not rounded up.
fn dents_for(ends: u32, order: &[u32]) -> u32 {
    let sum: u32 = order.iter().sum();
    if sum == 0 || order.is_empty() {
        return 0;
    }
    let full = ends / sum;
    let mut rest = ends % sum;
    let mut dents = full.saturating_mul(order.len() as u32);
    if rest == 0 {
        // The order is most first, so any skipped dents come last: the last repeat ends at its
        // last filled dent.
        let skipped = order.iter().rev().take_while(|&&n| n == 0).count() as u32;
        return dents.saturating_sub(skipped);
    }
    for &n in order {
        if rest == 0 {
            break;
        }
        dents = dents.saturating_add(1);
        rest = rest.saturating_sub(n);
    }
    dents
}

/// "329.94 g (11.64 oz)", "0.73 lb (329.94 g)".
fn mass_both(m: Mass) -> String {
    let other = match m.unit {
        MassUnit::Gram | MassUnit::Kilogram => MassUnit::Ounce,
        MassUnit::Ounce | MassUnit::Pound => MassUnit::Gram,
    };
    format!("{}, {}", m.describe(), m.converted(other).describe())
}

fn plural(n: usize, noun: &str) -> String {
    if n == 1 {
        noun.to_string()
    } else {
        format!("{n} {noun}s")
    }
}

fn dedup(keys: &mut Vec<String>) {
    let mut seen = std::collections::HashSet::new();
    keys.retain(|k| seen.insert(k.clone()));
}

fn capitalize(s: &str) -> String {
    let mut c = s.chars();
    match c.next() {
        Some(f) => f.to_uppercase().collect::<String>() + c.as_str(),
        None => String::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ply_common::quantity::LengthPerMass;

    fn towel_swatch() -> Swatch {
        let mut s = Swatch::new("sw", "Towel sample");
        s.craft = Some(CraftKind::Weaving);
        s.date = Some("2026-11-03".into());
        s.sett = Some(Recorded::entered(CountOver::new(24.0, Length::inches(1.0))));
        s.width_in_reed = Some(Recorded::entered(Length::inches(12.0)));
        s.on_loom.width = Some(Recorded::measured(Length::inches(11.4)));
        s.on_loom.length = Some(Recorded::measured(Length::inches(20.0)));
        s.on_loom.along = Some(Recorded::measured(CountOver::new(
            24.0,
            Length::inches(1.0),
        )));
        s.before.width = Some(Recorded::measured(Length::inches(11.0)));
        s.before.length = Some(Recorded::measured(Length::inches(19.0)));
        s.after.width = Some(Recorded::measured(Length::inches(10.5)));
        s.after.length = Some(Recorded::measured(Length::inches(18.0)));
        s
    }

    fn towel_plan() -> WeavePlan {
        WeavePlan {
            structure: PlanStructure::Twill,
            items: 4,
            finished_width: Some(Length::inches(18.0)),
            finished_length: Some(Length::inches(30.0)),
            hems: Some(Length::inches(4.0)),
            end_multiple: Some(4),
            extra_ends: 2,
            overrides: PlanOverrides {
                loom_waste: Some(Length::inches(27.0)),
                ..Default::default()
            },
            ..Default::default()
        }
    }

    fn request<'a>(plan: &'a WeavePlan, swatch: Option<&'a Swatch>) -> WorksheetRequest<'a> {
        WorksheetRequest {
            plan,
            swatch,
            warp: None,
            weft: None,
            loom: None,
            loom_sett: None,
            draft: DraftFacts::default(),
            metric: false,
        }
    }

    fn close(a: f64, b: f64) -> bool {
        (a - b).abs() <= 1e-6 * b.abs().max(1.0)
    }

    #[test]
    fn a_towel_from_its_swatch() {
        let s = towel_swatch();
        let plan = towel_plan();
        let w = work_out(&request(&plan, Some(&s)));
        assert!(w.issues.is_empty(), "{:?}", w.issues);
        // Width: 18 / (10.5 / 12) = 20.571 in; x 24 = 493.71, to 492 (4s), + 2 = 494.
        assert!(close(
            w.figure("width_in_reed_target").unwrap().value,
            18.0 * 12.0 / 10.5
        ));
        assert_eq!(w.figure("warp_ends").unwrap().value, 494.0);
        assert!(close(
            w.figure("width_in_reed").unwrap().value,
            494.0 / 24.0
        ));
        // Length: (30 + 4) / 0.9 per towel; 4 of them + 27 in.
        assert!(close(w.figure("woven_length").unwrap().value, 34.0 / 0.9));
        let warp_in = 4.0 * 34.0 / 0.9 + 27.0;
        assert!(close(
            w.figure("warp_length").unwrap().value,
            warp_in / 36.0
        ));
        assert!(close(
            w.figure("warp_yarn").unwrap().value,
            warp_in / 36.0 * 494.0
        ));
        // Weft: round(24 x 37.78) = 907 per towel, 3628 picks; x 20.58 x 1.1.
        assert_eq!(w.figure("weft_picks").unwrap().value, 3628.0);
        let per_pick = 494.0 / 24.0 * 1.1;
        assert!(close(
            w.figure("weft_yarn").unwrap().value,
            3628.0 * per_pick / 36.0
        ));
        let combined = w.input("length_loss").unwrap();
        assert_eq!(combined.source, Source::Measured);
        assert_eq!(
            combined.sentence(),
            "10% of the length on the loom, from the loom to finished, from 20 in on the loom and \
             18 in after wet finishing (measured), swatch Towel sample 2026-11-03"
        );
        let width = w.input("width_loss").unwrap();
        assert_eq!(width.source, Source::Entered, "the reed width was entered");
        assert_eq!(w.input("weft_allowance").unwrap().source, Source::Default);
        assert!(w.figure("weft_yarn").unwrap().assumed);
        assert!(!w.figure("warp_yarn").unwrap().assumed);
        // The parts are explained next to the combined input, not in the plan's notes.
        assert!(w
            .input_notes
            .iter()
            .any(|n| n.key == "length_loss" && n.text.starts_with("Of that, swatch Towel sample")));
        assert!(!w.notes.iter().any(|n| n.starts_with("Of that")));
        // The repeat and the extra ends are applied, so they are listed.
        assert!(w.input("end_multiple").is_some() && w.input("extra_ends").is_some());
        // Every figure names each input it used once.
        for f in &w.figures {
            let mut u = f.uses.clone();
            dedup(&mut u);
            assert_eq!(u, f.uses, "{}", f.key);
        }
    }

    #[test]
    fn overriding_take_up_uses_the_swatchs_shrinkage_and_leaves_the_swatch_alone() {
        let s = towel_swatch();
        let before = s.clone();
        let mut plan = towel_plan();
        plan.overrides.take_up = Some(0.12);
        let w = work_out(&request(&plan, Some(&s)));
        assert_eq!(s, before);
        assert!(w.input("length_loss").is_none());
        assert_eq!(w.input("take_up").unwrap().source, Source::Entered);
        let shrink = w.input("length_shrinkage").unwrap();
        assert_eq!(shrink.source, Source::Measured);
        assert!(shrink.value.starts_with("5.3% of the length off the loom"));
        let f = 0.88 * (18.0 / 19.0);
        assert!(close(w.figure("woven_length").unwrap().value, 34.0 / f));
        // The width is unchanged by a length assumption.
        assert_eq!(w.figure("warp_ends").unwrap().value, 494.0);
    }

    #[test]
    fn starting_estimates_by_structure() {
        let plain = PlanStructure::Plain.estimates();
        assert_eq!(plain.take_up, 0.10);
        assert_eq!(plain.sett_fraction, 0.5);
        let twill = PlanStructure::Twill.estimates();
        assert_eq!(twill.take_up, 0.08);
        assert_eq!(twill.sett_fraction, 0.66);
        assert_eq!(PlanStructure::Satin.estimates().sett_fraction, 0.75);
        assert_eq!(PlanStructure::Other.estimates(), plain);
        let mut plan = towel_plan();
        plan.overrides.sett = Some(CountOver::new(24.0, Length::inches(1.0)));
        let w = work_out(&request(&plan, None));
        let take_up = w.input("take_up").unwrap();
        assert_eq!(
            take_up.sentence(),
            "8% of the length on the loom, Ply's starting estimate for twill"
        );
        assert!(w.figure("warp_length").unwrap().assumed);
        assert!(w.notes.last().unwrap().contains("rules of thumb"));
    }

    #[test]
    fn issues_name_the_field_and_figures_that_need_it_are_left_out() {
        let mut plan = towel_plan();
        plan.overrides.take_up = Some(1.0);
        plan.overrides.sett = Some(CountOver::new(24.0, Length::inches(1.0)));
        let w = work_out(&request(&plan, None));
        assert_eq!(w.issue_codes(), vec!["plan.out_of_range"]);
        assert_eq!(w.issues[0].field, "take_up");
        assert!(w.figure("warp_length").is_none());
        assert!(
            w.figure("warp_ends").is_some(),
            "the width does not need the take-up"
        );
        plan.overrides.take_up = Some(f64::NAN);
        assert_eq!(
            work_out(&request(&plan, None)).issue_codes(),
            vec!["quantity.not_finite"]
        );
        plan.overrides.take_up = None;
        plan.finished_width = Some(Length::inches(0.0));
        plan.hems = Some(Length::inches(-1.0));
        let w = work_out(&request(&plan, None));
        assert_eq!(
            w.issue_codes(),
            vec!["quantity.not_positive", "plan.negative"]
        );
        let blank = WeavePlan::default();
        let w = work_out(&request(&blank, None));
        assert_eq!(
            w.issue_codes(),
            vec!["plan.needs_sett", "plan.needs_input"],
            "{:?}",
            w.issues
        );
        assert!(w.issues.iter().all(|i| i.kind == IssueKind::Needed));
    }

    #[test]
    fn a_swatch_figure_out_of_range_is_an_issue_not_an_estimate() {
        let mut s = towel_swatch();
        s.after.length = Some(Recorded::measured(Length::inches(1.0)));
        let plan = towel_plan();
        let w = work_out(&request(&plan, Some(&s)));
        assert_eq!(w.issue_codes(), vec!["plan.swatch_out_of_range"]);
        assert_eq!(w.issues[0].field, "length_loss");
        assert!(w.figure("warp_length").is_none());
    }

    #[test]
    fn a_knitting_swatch_is_not_used() {
        let mut s = towel_swatch();
        s.craft = Some(CraftKind::Knitting);
        let plan = towel_plan();
        let w = work_out(&request(&plan, Some(&s)));
        assert_eq!(w.issue_codes()[0], "plan.swatch_not_weaving");
        assert!(w.input("take_up").unwrap().source == Source::Default);
    }

    #[test]
    fn the_sett_comes_from_loom_for_this_draft_before_the_swatch() {
        let s = towel_swatch();
        let plan = towel_plan();
        let mut req = request(&plan, Some(&s));
        req.loom_sett = Some(Sett {
            ends: 20.0,
            per: Unit::Inches,
        });
        let w = work_out(&req);
        assert_eq!(
            w.input("sett").unwrap().sentence(),
            "20 ends per in, from Loom for this draft"
        );
        assert!(w
            .input_notes
            .iter()
            .any(|n| n.key == "sett" && n.text.contains("was woven at 24 ends per in")));
    }

    fn cotton() -> Material {
        let mut m = Material::new("cotton", "8/2 cotton");
        m.length_per_mass = Some(Recorded::entered(LengthPerMass::new(
            Length::new(3360.0, LengthUnit::Yard),
            Mass::new(1.0, MassUnit::Pound),
        )));
        m
    }

    #[test]
    fn a_mass_on_hand_without_a_length_per_mass_is_named_not_called_unrecorded() {
        let s = towel_swatch();
        let plan = towel_plan();
        let mut m = Material::new("wool", "Wool");
        m.available_mass = Some(Recorded::measured(Mass::grams(500.0)));
        let mut req = request(&plan, Some(&s));
        req.warp = Some(&m);
        let w = work_out(&req);
        let line = &w.supply[0];
        assert!(line.on_hand.is_none() && line.remaining.is_none());
        assert!(
            line.text
                .ends_with("500 g on hand; add the yarn's length per mass to compare."),
            "{}",
            line.text
        );
        assert!(!line.text.contains("not recorded"));
        assert_eq!(w.input("warp_on_hand").unwrap().value, "500 g");
    }

    #[test]
    fn one_yarn_for_both_with_the_weft_not_worked_out_claims_no_leftover() {
        let s = towel_swatch();
        let mut plan = towel_plan();
        plan.overrides.weft_allowance = Some(5.0);
        let mut m = cotton();
        m.available_length = Some(Recorded::entered(Length::new(4000.0, LengthUnit::Yard)));
        let mut req = request(&plan, Some(&s));
        req.warp = Some(&m);
        req.weft = Some(&m);
        let w = work_out(&req);
        assert!(w.figure("weft_yarn").is_none());
        let line = &w.supply[0];
        assert_eq!(line.role, SupplyRole::Warp);
        assert!(line.remaining.is_none());
        assert!(line.text.contains("4000 yd on hand"), "{}", line.text);
        assert!(
            line.text
                .ends_with("It is the weft too, which is not worked out yet, so what will be left is not shown."),
            "{}",
            line.text
        );
        assert!(!line.text.contains("left over"));
    }

    #[test]
    fn supply_lines_say_when_they_rest_on_estimates() {
        let s = towel_swatch();
        let plan = towel_plan();
        let (warp, weft) = (cotton(), {
            let mut m = cotton();
            m.id = "blue".into();
            m
        });
        let mut req = request(&plan, Some(&s));
        req.warp = Some(&warp);
        req.weft = Some(&weft);
        let w = work_out(&req);
        assert!(!w.supply[0].assumed, "the warp uses no estimate here");
        assert!(w.supply[1].assumed, "the weft uses Ply's weft allowance");
    }

    #[test]
    fn a_recorded_swatch_measurement_that_cannot_be_used_is_an_issue() {
        // A finished width of 0: never a quiet fall back to the estimate.
        let mut s = towel_swatch();
        s.after.width = Some(Recorded::measured(Length::inches(0.0)));
        let plan = towel_plan();
        let w = work_out(&request(&plan, Some(&s)));
        assert_eq!(w.issue_codes(), vec!["plan.swatch_out_of_range"]);
        assert_eq!(w.issues[0].field, "width_loss");
        assert!(w.issues[0]
            .message
            .contains("records its width after wet finishing as 0 in"));
        assert!(w.input("draw_in").is_none() && w.input("width_shrinkage").is_none());
        // With draw-in overridden, the shrinkage still needs that measurement.
        let mut over = towel_plan();
        over.overrides.draw_in = Some(0.05);
        let w = work_out(&request(&over, Some(&s)));
        assert_eq!(w.issues[0].field, "width_shrinkage");
        // A sett or picks it cannot use are issues too.
        let mut s = towel_swatch();
        s.sett = Some(Recorded::entered(CountOver::new(0.0, Length::inches(1.0))));
        s.on_loom.along = Some(Recorded::measured(CountOver::new(
            f64::NAN,
            Length::inches(1.0),
        )));
        let w = work_out(&request(&plan, Some(&s)));
        let fields: Vec<_> = w
            .issues
            .iter()
            .map(|i| (i.code, i.field.as_str()))
            .collect();
        assert!(
            fields.contains(&("plan.swatch_out_of_range", "sett")),
            "{fields:?}"
        );
        assert!(
            fields.contains(&("plan.swatch_out_of_range", "ppi")),
            "{fields:?}"
        );
    }

    #[test]
    fn picks_counted_only_off_the_loom_are_not_used_and_the_plan_says_why() {
        let mut s = towel_swatch();
        s.on_loom.along = None;
        s.after.along = Some(Recorded::measured(CountOver::new(
            26.0,
            Length::inches(1.0),
        )));
        let plan = towel_plan();
        let w = work_out(&request(&plan, Some(&s)));
        assert_eq!(w.input("ppi").unwrap().source, Source::Default);
        assert!(w
            .input_notes
            .iter()
            .any(|n| n.key == "ppi" && n.text.contains("counted picks only off the loom")));
    }

    #[test]
    fn results_too_large_are_issues() {
        let mut plan = towel_plan();
        plan.overrides.sett = Some(CountOver::new(24.0, Length::inches(1.0)));
        plan.overrides.ends = Some(MAX_PLAN_COUNT);
        plan.finished_length = Some(Length::new(500_000.0, LengthUnit::Yard));
        plan.items = 1;
        let w = work_out(&request(&plan, None));
        assert!(w.figure("warp_length").is_some());
        assert!(
            w.figure("warp_yarn").is_none(),
            "{:?}",
            w.figure("warp_yarn")
        );
        assert!(w.issue_codes().contains(&"plan.result_too_large"));
        plan.items = MAX_PLAN_COUNT;
        let w = work_out(&request(&plan, None));
        assert!(w.figure("warp_length").is_none());
        assert_eq!(
            w.issues
                .iter()
                .find(|i| i.code == "plan.result_too_large")
                .unwrap()
                .field,
            "finished_length"
        );
    }

    #[test]
    fn a_gain_reads_as_a_gain() {
        let mut plan = towel_plan();
        plan.overrides.sett = Some(CountOver::new(24.0, Length::inches(1.0)));
        plan.overrides.length_shrinkage = Some(-0.05);
        let w = work_out(&request(&plan, None));
        assert_eq!(
            w.input("length_shrinkage").unwrap().value,
            "a gain of 5% of the length off the loom"
        );
        let step = &w.figure("woven_length").unwrap().working[0];
        assert!(step.contains("/ (1 + 5%)"), "{step}");
        assert!(!step.contains("- -"), "{step}");
    }

    #[test]
    fn the_repeat_and_extra_ends_are_listed_only_where_applied() {
        let mut plan = towel_plan();
        plan.overrides.sett = Some(CountOver::new(24.0, Length::inches(1.0)));
        plan.overrides.ends = Some(400);
        let w = work_out(&request(&plan, None));
        assert!(w.input("end_multiple").is_none() && w.input("extra_ends").is_none());
        assert!(w
            .input_notes
            .iter()
            .any(|n| n.key == "ends" && n.text.contains("not used here")));
        // 400 ends finish well off the 18 in entered.
        assert!(w.notes.iter().any(|n| n.starts_with("With 400 ends")));
    }

    #[test]
    fn a_large_repeat_that_moves_the_width_is_noted() {
        let mut plan = towel_plan();
        plan.overrides.sett = Some(CountOver::new(24.0, Length::inches(1.0)));
        plan.end_multiple = Some(100);
        let w = work_out(&request(&plan, None));
        assert!(
            w.notes
                .iter()
                .any(|n| n.starts_with("Rounded to whole repeats and the extra ends")),
            "{:?}",
            w.notes
        );
    }

    #[test]
    fn the_sett_from_wraps_is_a_starting_approximation() {
        let mut m = Material::new("wool", "Wool");
        m.wpi = Some(Recorded::measured(CountOver::new(12.0, Length::cm(1.0))));
        let mut plan = towel_plan();
        plan.structure = PlanStructure::Plain;
        let mut req = request(&plan, None);
        req.warp = Some(&m);
        let w = work_out(&req);
        let sett = w.input("sett").unwrap();
        assert_eq!(sett.source, Source::Default);
        assert_eq!(sett.value, "6 ends per cm");
        assert_eq!(
            sett.basis,
            "Ply's starting approximation for plain weave: 0.5 of 12 wraps per cm"
        );
        assert_eq!(w.input("wpi").unwrap().source, Source::Measured);
        assert!(w.figure("warp_ends").unwrap().assumed);
    }

    #[test]
    fn denting_walks_the_order_and_checks_the_loom() {
        assert_eq!(dents_for(185, &[2, 1]), 123);
        assert_eq!(dents_for(179, &[2, 1]), 119);
        assert_eq!(dents_for(494, &[2]), 247);
        assert_eq!(dents_for(7, &[1, 0]), 13);
        assert_eq!(dents_for(5, &[]), 0);
        let s = towel_swatch();
        let plan = towel_plan();
        let mut loom = LoomProfile::new("l", "Floor loom");
        loom.reeds = vec![Reed {
            dents: 12.0,
            per: DentUnit::PerInch,
        }];
        loom.weaving_width = Some(crate::loom::Length {
            value: 20.0,
            unit: Unit::Inches,
        });
        let mut req = request(&plan, Some(&s));
        req.loom = Some(&loom);
        let w = work_out(&req);
        let d = w.denting.as_ref().unwrap();
        assert_eq!(d.order, vec![2]);
        assert_eq!(d.dents, 247);
        assert_eq!(
            w.check_codes(),
            vec!["plan.reed_fits", "plan.loom_width_exceeded"]
        );
    }

    #[test]
    fn the_same_yarn_for_warp_and_weft_is_one_supply_line() {
        let s = towel_swatch();
        let plan = towel_plan();
        let mut m = Material::new("cotton", "8/2 cotton");
        m.length_per_mass = Some(Recorded::entered(LengthPerMass::new(
            Length::new(3360.0, LengthUnit::Yard),
            Mass::new(1.0, MassUnit::Pound),
        )));
        m.available_mass = Some(Recorded::measured(Mass::new(1.0, MassUnit::Pound)));
        let mut req = request(&plan, Some(&s));
        req.warp = Some(&m);
        req.weft = Some(&m);
        let w = work_out(&req);
        assert_eq!(w.supply.len(), 1);
        let line = &w.supply[0];
        assert_eq!(line.role, SupplyRole::WarpAndWeft);
        let need = w.figure("warp_yarn").unwrap().value + w.figure("weft_yarn").unwrap().value;
        assert!(close(line.need.value, need));
        assert!(line.on_hand_about);
        assert!(close(line.remaining.unwrap().value, 3360.0 - need));
        assert!(line.text.contains("short"), "{}", line.text);
    }
}
