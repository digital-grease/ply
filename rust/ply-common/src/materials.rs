//! Materials and swatch records (roadmap M8-01, ADR 0016): reusable references a crafter can link to
//! any number of projects, not an inventory they must keep.
//!
//! A [`Material`] describes a yarn (or any other thread): its fibers, weight category, structure,
//! length per mass, wraps per inch, color and dye lot, how much is on hand, and notes. A [`Swatch`]
//! records a measured sample: the craft, the technique, the yarns, the tools and (for weaving) the
//! loom setup, the measurements at each stage (on the loom, before finishing, after finishing) with
//! the conditions they were taken in, the finishing, the swatch's mass, tension notes, date and
//! provenance. Photos are kept by the app, beside the record, never in it.
//!
//! **Every field may be missing**, and unknown is never zero: a value the crafter did not give is
//! `None` (or empty text), and a figure that needs it is simply not worked out. Every stored number
//! carries its [`Source`] (measured or entered; a record never holds one of Ply's defaults).
//!
//! **Derived figures are computed, never stored** ([`Material::figures`], [`Swatch::figures`]): a
//! shrinkage percentage, a gauge per 10 cm or yards per 100 g are worked out from the measurements
//! each time they are shown, so an original measurement is never replaced by an inferred number.
//!
//! **Diagnostics** ([`Material::diagnostics`], [`Swatch::diagnostics`]) have stable codes. An
//! [`Severity::Error`] is a value that cannot be true (a size of zero or less, not a number, a fiber
//! blend over 100%, an impossible date): the record cannot be saved with it, and the file reader
//! refuses it. A [`Severity::Warning`] is a value worth checking (a swatch that grew by half after
//! finishing, cloth wider than the reed): it is saved as given.

use serde::{Deserialize, Serialize};

use crate::provenance::{Recorded, Source};
use crate::quantity::{
    number, percent, positive_problem, CountOver, Length, LengthPerMass, LengthUnit, Mass,
    MassUnit, QuantityProblem,
};
use crate::{CraftKind, YarnWeight};

/// The longest id, in bytes (ids are ASCII; the app uses a uuid).
pub const MAX_ID_LEN: usize = 64;
/// The longest name, in characters (Unicode code points).
pub const MAX_NAME_CHARS: usize = 100;
/// The longest short text field (maker, structure, color, technique, tools, ...), in characters.
pub const MAX_SHORT_TEXT_CHARS: usize = 200;
/// The longest notes or conditions field, in characters.
pub const MAX_NOTES_CHARS: usize = 4_000;
/// The most fibers one blend may list.
pub const MAX_FIBERS: usize = 8;
/// The most yarns one swatch may list.
pub const MAX_SWATCH_YARNS: usize = 8;

/// Ply's plausibility check (not a craft fact): a later measurement more than this fraction LARGER
/// than an earlier one is worth checking (a swatch rarely grows by half when finished).
pub const GROWTH_WARNING: f64 = 0.5;
/// Ply's plausibility check: a later measurement more than this fraction SMALLER than an earlier one
/// is worth checking (heavy fulling can do it, a typing slip more often does).
pub const SHRINK_WARNING: f64 = 0.6;
/// Cloth more than this fraction wider than the warp in the reed is worth checking.
pub const REED_WIDTH_TOLERANCE: f64 = 0.05;
/// A blend whose percentages are all given is worth checking when they total more than this far
/// from 100.
pub const FIBER_TOTAL_TOLERANCE: f64 = 0.5;

// --- records ---------------------------------------------------------------------------------------

/// One fiber of a blend: "wool 80%". The percentage (by weight, as labels give it) may be unknown.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct FiberPart {
    pub fiber: String,
    pub percent: Option<f64>,
}

/// A material: a yarn or thread the crafter has or has used.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Material {
    /// Stable id `[A-Za-z0-9][A-Za-z0-9_-]{0,63}`. Projects and swatches refer to it.
    pub id: String,
    /// What the crafter calls it ("Grey wool", "8/2 cotton, natural").
    #[serde(default)]
    pub name: String,
    /// The maker, mill or brand, and the yarn's own name.
    #[serde(default)]
    pub maker: String,
    /// The fiber blend, in the label's order. Empty = not recorded.
    #[serde(default)]
    pub fibers: Vec<FiberPart>,
    /// The Craft Yarn Council weight category, when known.
    #[serde(default, with = "weight_opt")]
    pub weight: Option<YarnWeight>,
    /// Plies, spin and count in the crafter's words ("3-ply worsted-spun", "8/2").
    #[serde(default)]
    pub structure: String,
    /// Length per mass: from the label (entered) or weighed from a measured length (measured).
    pub length_per_mass: Option<Recorded<LengthPerMass>>,
    /// Wraps per inch (or over any span).
    pub wpi: Option<Recorded<CountOver>>,
    /// Color name or colorway.
    #[serde(default)]
    pub color: String,
    /// Dye lot.
    #[serde(default)]
    pub dye_lot: String,
    /// How much is on hand, by mass.
    pub available_mass: Option<Recorded<Mass>>,
    /// How much is on hand, by length.
    pub available_length: Option<Recorded<Length>>,
    /// Purchase and reference notes.
    #[serde(default)]
    pub notes: String,
}

impl Material {
    /// A material with nothing recorded but its id and name.
    pub fn new(id: impl Into<String>, name: impl Into<String>) -> Material {
        Material {
            id: id.into(),
            name: name.into(),
            maker: String::new(),
            fibers: Vec::new(),
            weight: None,
            structure: String::new(),
            length_per_mass: None,
            wpi: None,
            color: String::new(),
            dye_lot: String::new(),
            available_mass: None,
            available_length: None,
            notes: String::new(),
        }
    }

    /// The name for sentences: the trimmed name, or "unnamed material".
    pub fn display_name(&self) -> String {
        display(&self.name, "unnamed material")
    }
}

/// What a yarn is for in a swatch or a project.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum YarnRole {
    Main,
    Contrast,
    Warp,
    Weft,
}

impl YarnRole {
    pub fn label(self) -> &'static str {
        match self {
            YarnRole::Main => "main yarn",
            YarnRole::Contrast => "contrast",
            YarnRole::Warp => "warp",
            YarnRole::Weft => "weft",
        }
    }
}

/// A yarn used in a swatch: a material from the library (with its name as it was then), or a name
/// alone for a yarn the crafter did not record.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SwatchYarn {
    pub material_id: Option<String>,
    #[serde(default)]
    pub name: String,
    pub role: Option<YarnRole>,
}

/// Which stage of a swatch a measurement belongs to.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum StageKind {
    /// Weaving only: measured on the loom, under tension.
    OnLoom,
    /// Before finishing (weaving: off the loom, relaxed, before wet finishing).
    Before,
    /// After finishing (washing, blocking, pressing, wet finishing, fulling).
    After,
}

impl StageKind {
    /// The stage in words for `craft`: "on the loom", "off the loom", "after wet finishing",
    /// "before finishing", "after finishing".
    pub fn phrase(self, craft: Option<CraftKind>) -> &'static str {
        let weaving = craft == Some(CraftKind::Weaving);
        match self {
            StageKind::OnLoom => "on the loom",
            StageKind::Before if weaving => "off the loom",
            StageKind::Before => "before finishing",
            StageKind::After if weaving => "after wet finishing",
            StageKind::After => "after finishing",
        }
    }

    /// The field path prefix ("on_loom", "before", "after").
    pub fn key(self) -> &'static str {
        match self {
            StageKind::OnLoom => "on_loom",
            StageKind::Before => "before",
            StageKind::After => "after",
        }
    }
}

/// What was measured at one stage. Every value may be missing.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Stage {
    /// The whole swatch's width.
    pub width: Option<Recorded<Length>>,
    /// The whole swatch's length.
    pub length: Option<Recorded<Length>>,
    /// Counted across the width: stitches (knitting, nalbinding) or ends (weaving), over a span.
    pub across: Option<Recorded<CountOver>>,
    /// Counted along the length: rows or rounds (knitting, nalbinding) or picks (weaving).
    pub along: Option<Recorded<CountOver>>,
    /// How it was measured: relaxed or pinned, flat, after resting, who measured.
    #[serde(default)]
    pub conditions: String,
}

impl Stage {
    /// Whether nothing was recorded at this stage.
    pub fn is_empty(&self) -> bool {
        self.width.is_none()
            && self.length.is_none()
            && self.across.is_none()
            && self.along.is_none()
            && self.conditions.trim().is_empty()
    }
}

/// A measured sample.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Swatch {
    /// Stable id `[A-Za-z0-9][A-Za-z0-9_-]{0,63}`. Projects refer to it; its photos are kept under it.
    pub id: String,
    #[serde(default)]
    pub name: String,
    /// The craft, when recorded.
    #[serde(default, with = "craft_opt")]
    pub craft: Option<CraftKind>,
    /// The stitch pattern, weave structure, or nalbinding stitch and connection.
    #[serde(default)]
    pub technique: String,
    /// When it was made or measured, `YYYY-MM-DD`.
    pub date: Option<String>,
    /// The yarns used.
    #[serde(default)]
    pub yarns: Vec<SwatchYarn>,
    /// Needles, hook or nalbinding needle; for weaving the loom and reed.
    #[serde(default)]
    pub tools: String,
    /// Weaving: the sett in the reed (ends over a span).
    pub sett: Option<Recorded<CountOver>>,
    /// Weaving: the warp's width in the reed.
    pub width_in_reed: Option<Recorded<Length>>,
    /// Weaving: measured on the loom under tension.
    #[serde(default)]
    pub on_loom: Stage,
    /// Before finishing (weaving: off the loom).
    #[serde(default)]
    pub before: Stage,
    /// After finishing.
    #[serde(default)]
    pub after: Stage,
    /// How it was finished (washed, blocked, pressed, fulled; water, drying).
    #[serde(default)]
    pub finishing: String,
    /// The swatch's mass, for the weighed-swatch yardage estimate.
    pub mass: Option<Recorded<Mass>>,
    /// Tension notes (how firmly it was worked or beaten).
    #[serde(default)]
    pub tension: String,
    /// Who made and measured it, or where the numbers came from.
    #[serde(default)]
    pub provenance: String,
    #[serde(default)]
    pub notes: String,
}

impl Swatch {
    /// A swatch with nothing recorded but its id and name.
    pub fn new(id: impl Into<String>, name: impl Into<String>) -> Swatch {
        Swatch {
            id: id.into(),
            name: name.into(),
            craft: None,
            technique: String::new(),
            date: None,
            yarns: Vec::new(),
            tools: String::new(),
            sett: None,
            width_in_reed: None,
            on_loom: Stage::default(),
            before: Stage::default(),
            after: Stage::default(),
            finishing: String::new(),
            mass: None,
            tension: String::new(),
            provenance: String::new(),
            notes: String::new(),
        }
    }

    pub fn display_name(&self) -> String {
        display(&self.name, "unnamed swatch")
    }

    /// The swatch as an estimate cites it: "swatch Grey wool 2026-11-10".
    pub fn citation(&self) -> String {
        match &self.date {
            Some(d) if !d.trim().is_empty() => {
                format!("swatch {} {}", self.display_name(), d.trim())
            }
            _ => format!("swatch {}", self.display_name()),
        }
    }

    pub fn stage(&self, kind: StageKind) -> &Stage {
        match kind {
            StageKind::OnLoom => &self.on_loom,
            StageKind::Before => &self.before,
            StageKind::After => &self.after,
        }
    }

    /// The stages in the order they happen.
    fn stages(&self) -> [(StageKind, &Stage); 3] {
        [
            (StageKind::OnLoom, &self.on_loom),
            (StageKind::Before, &self.before),
            (StageKind::After, &self.after),
        ]
    }

    /// "stitches" / "ends" for counts across the width.
    pub fn across_noun(&self) -> &'static str {
        if self.craft == Some(CraftKind::Weaving) {
            "ends"
        } else {
            "sts"
        }
    }

    /// "rows" / "picks" for counts along the length.
    pub fn along_noun(&self) -> &'static str {
        if self.craft == Some(CraftKind::Weaving) {
            "picks"
        } else {
            "rows"
        }
    }

    /// The count across the width a plan should use, and the stage it was measured at: after
    /// finishing when recorded there, else before finishing. (The fabric a project is sized by is
    /// the finished fabric, so a before-finishing count is used only when it is all there is, and the
    /// estimate says so.)
    pub fn planning_across(&self) -> Option<(Recorded<CountOver>, StageKind)> {
        if let Some(c) = self.after.across {
            return Some((c, StageKind::After));
        }
        self.before.across.map(|c| (c, StageKind::Before))
    }

    /// How a value measured at `stage` is cited: "measured after finishing (washed, dried flat),
    /// swatch Grey wool 2026-11-10". `source` is the value's own source.
    pub fn basis(&self, source: Source, stage: Option<StageKind>) -> String {
        let how = match source {
            Source::Measured => "measured",
            Source::Entered => "entered",
            Source::Default => "assumed",
        };
        let mut s = match stage {
            Some(k) => format!("{how} {}", k.phrase(self.craft)),
            None => how.to_string(),
        };
        if stage == Some(StageKind::After) {
            let f = clip(self.finishing.trim(), 40);
            if !f.is_empty() {
                s.push_str(&format!(" ({f})"));
            }
        }
        format!("{s}, {}", self.citation())
    }
}

/// The text for sentences: trimmed, or `fallback` when empty.
fn display(name: &str, fallback: &str) -> String {
    let n = name.trim();
    if n.is_empty() {
        fallback.to_string()
    } else {
        n.to_string()
    }
}

/// At most `max` characters of `s`, with "..." when cut.
fn clip(s: &str, max: usize) -> String {
    if s.chars().count() <= max {
        s.to_string()
    } else {
        let mut out: String = s.chars().take(max).collect();
        out.push_str("...");
        out
    }
}

// --- diagnostics -----------------------------------------------------------------------------------

/// How serious a record diagnostic is.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Severity {
    /// The value cannot be true; the record cannot be saved with it.
    Error,
    /// The value is unusual and worth checking; it is saved as given.
    Warning,
}

/// One finding about a record. `code` is stable; `field` is the value's path in the record
/// (`after.width`, `fibers[1].percent`); `message` is for people.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct RecordDiagnostic {
    pub code: String,
    pub severity: Severity,
    pub field: String,
    pub message: String,
}

impl RecordDiagnostic {
    fn error(code: &str, field: impl Into<String>, message: impl Into<String>) -> Self {
        RecordDiagnostic {
            code: code.to_string(),
            severity: Severity::Error,
            field: field.into(),
            message: message.into(),
        }
    }

    fn warning(code: &str, field: impl Into<String>, message: impl Into<String>) -> Self {
        RecordDiagnostic {
            code: code.to_string(),
            severity: Severity::Warning,
            field: field.into(),
            message: message.into(),
        }
    }
}

/// Whether `id` matches `[A-Za-z0-9][A-Za-z0-9_-]{0,63}`.
pub fn is_valid_id(id: &str) -> bool {
    let b = id.as_bytes();
    !b.is_empty()
        && b.len() <= MAX_ID_LEN
        && b[0].is_ascii_alphanumeric()
        && b.iter()
            .all(|c| c.is_ascii_alphanumeric() || *c == b'_' || *c == b'-')
}

/// Whether `date` is a real calendar date written `YYYY-MM-DD` (years 1000 to 9999).
pub fn is_valid_date(date: &str) -> bool {
    let b = date.as_bytes();
    if b.len() != 10 || b[4] != b'-' || b[7] != b'-' {
        return false;
    }
    let digits = |r: std::ops::Range<usize>| -> Option<u32> {
        let mut v = 0u32;
        for &c in &b[r] {
            if !c.is_ascii_digit() {
                return None;
            }
            v = v * 10 + u32::from(c - b'0');
        }
        Some(v)
    };
    let (Some(y), Some(m), Some(d)) = (digits(0..4), digits(5..7), digits(8..10)) else {
        return false;
    };
    if !(1000..=9999).contains(&y) || !(1..=12).contains(&m) || d == 0 {
        return false;
    }
    let leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
    let days = match m {
        2 if leap => 29,
        2 => 28,
        4 | 6 | 9 | 11 => 30,
        _ => 31,
    };
    d <= days
}

/// Collects diagnostics while a record is checked.
struct Checker {
    out: Vec<RecordDiagnostic>,
}

impl Checker {
    fn id(&mut self, id: &str, what: &str) {
        if !is_valid_id(id) {
            let shown: String = id.chars().take(40).collect();
            self.out.push(RecordDiagnostic::error(
                "record.id_invalid",
                "id",
                format!("The {what} id {shown:?} is not a valid id."),
            ));
        }
    }

    fn text(&mut self, field: &str, label: &str, text: &str, max: usize) {
        if text.chars().count() > max {
            self.out.push(RecordDiagnostic::error(
                "record.text_too_long",
                field,
                format!("{label} is longer than {max} characters."),
            ));
        }
    }

    fn source(&mut self, field: &str, label: &str, source: Source) {
        if source == Source::Default {
            self.out.push(RecordDiagnostic::error(
                "record.default_source",
                field,
                format!(
                    "{label} is marked as one of Ply's defaults. A record keeps only what was \
                     measured or entered."
                ),
            ));
        }
    }

    fn quantity(&mut self, field: &str, label: &str, problem: Option<QuantityProblem>) -> bool {
        match problem {
            Some(p) => {
                self.out.push(RecordDiagnostic::error(
                    p.code(),
                    field,
                    format!("{label} {}.", p.phrase()),
                ));
                false
            }
            None => true,
        }
    }

    fn length(&mut self, field: &str, label: &str, v: &Option<Recorded<Length>>) {
        if let Some(r) = v {
            self.source(field, label, r.source);
            self.quantity(field, label, r.value.problem());
        }
    }

    fn mass(&mut self, field: &str, label: &str, v: &Option<Recorded<Mass>>) {
        if let Some(r) = v {
            self.source(field, label, r.source);
            self.quantity(field, label, r.value.problem());
        }
    }

    fn count(&mut self, field: &str, label: &str, v: &Option<Recorded<CountOver>>) {
        if let Some(r) = v {
            self.source(field, label, r.source);
            self.quantity(
                &format!("{field}.count"),
                &format!("The count of {}", lower_first(label)),
                positive_problem(r.value.count),
            );
            self.quantity(
                &format!("{field}.over"),
                &format!("The span of {}", lower_first(label)),
                r.value.over.problem(),
            );
        }
    }
}

fn lower_first(s: &str) -> String {
    let mut c = s.chars();
    match c.next() {
        Some(f) => f.to_lowercase().collect::<String>() + c.as_str(),
        None => String::new(),
    }
}

/// A usable length (no problem), in cm.
fn usable_cm(v: &Option<Recorded<Length>>) -> Option<(Length, f64)> {
    let r = v.as_ref()?;
    if r.value.problem().is_some() {
        return None;
    }
    Some((r.value, r.value.to(LengthUnit::Centimeter)))
}

impl Material {
    /// Every finding about this material, in field order (empty = nothing to say).
    pub fn diagnostics(&self) -> Vec<RecordDiagnostic> {
        let mut c = Checker { out: Vec::new() };
        c.id(&self.id, "material");
        c.text("name", "The name", &self.name, MAX_NAME_CHARS);
        c.text("maker", "The maker", &self.maker, MAX_SHORT_TEXT_CHARS);
        if self.fibers.len() > MAX_FIBERS {
            c.out.push(RecordDiagnostic::error(
                "record.too_many",
                "fibers",
                format!("A blend can list up to {MAX_FIBERS} fibers."),
            ));
        }
        let mut total = 0.0;
        let mut all_known = !self.fibers.is_empty();
        let mut usable = true;
        for (i, f) in self.fibers.iter().enumerate() {
            c.text(
                &format!("fibers[{i}].fiber"),
                "A fiber name",
                &f.fiber,
                MAX_SHORT_TEXT_CHARS,
            );
            match f.percent {
                None => all_known = false,
                Some(p) if !p.is_finite() || p <= 0.0 || p > 100.0 => {
                    usable = false;
                    c.out.push(RecordDiagnostic::error(
                        "material.fiber_percent_out_of_range",
                        format!("fibers[{i}].percent"),
                        format!(
                            "The share of {} must be more than 0% and at most 100%.",
                            display(&f.fiber, "a fiber")
                        ),
                    ));
                }
                Some(p) => total += p,
            }
        }
        if usable && total > 100.0 + 1e-9 {
            c.out.push(RecordDiagnostic::error(
                "material.fiber_percents_over_100",
                "fibers",
                format!(
                    "The fiber shares add up to {}%, more than 100%.",
                    number(total)
                ),
            ));
        } else if usable && all_known && (total - 100.0).abs() > FIBER_TOTAL_TOLERANCE {
            c.out.push(RecordDiagnostic::warning(
                "material.fiber_percents_not_100",
                "fibers",
                format!("The fiber shares add up to {}%, not 100%.", number(total)),
            ));
        }
        c.text(
            "structure",
            "The structure",
            &self.structure,
            MAX_SHORT_TEXT_CHARS,
        );
        if let Some(r) = &self.length_per_mass {
            c.source("length_per_mass", "The length per mass", r.source);
            c.quantity(
                "length_per_mass.length",
                "The length of the length per mass",
                r.value.length.problem(),
            );
            c.quantity(
                "length_per_mass.mass",
                "The mass of the length per mass",
                r.value.mass.problem(),
            );
        }
        c.count("wpi", "Wraps per inch", &self.wpi);
        c.text("color", "The color", &self.color, MAX_SHORT_TEXT_CHARS);
        c.text(
            "dye_lot",
            "The dye lot",
            &self.dye_lot,
            MAX_SHORT_TEXT_CHARS,
        );
        c.mass("available_mass", "The amount on hand", &self.available_mass);
        c.length(
            "available_length",
            "The length on hand",
            &self.available_length,
        );
        c.text("notes", "The notes", &self.notes, MAX_NOTES_CHARS);
        // Both amounts and a length per mass: say when they disagree by more than a tenth.
        if let (Some(m), Some(l), Some(lpm)) = (
            self.available_mass,
            self.available_length,
            self.length_per_mass,
        ) {
            if m.value.problem().is_none()
                && l.value.problem().is_none()
                && lpm.value.problem().is_none()
            {
                let from_mass = lpm.value.length_for(m.value, l.value.unit);
                if (from_mass - l.value.value).abs() > 0.1 * l.value.value.max(from_mass) {
                    c.out.push(RecordDiagnostic::warning(
                        "material.available_mismatch",
                        "available_length",
                        format!(
                            "{} at {} is about {} {}, but the length on hand says {}.",
                            m.value.describe(),
                            lpm.value.describe(),
                            number(from_mass),
                            l.value.unit.symbol(),
                            l.value.describe()
                        ),
                    ));
                }
            }
        }
        c.out
    }
}

impl Swatch {
    /// Every finding about this swatch, in field order (empty = nothing to say).
    pub fn diagnostics(&self) -> Vec<RecordDiagnostic> {
        let mut c = Checker { out: Vec::new() };
        c.id(&self.id, "swatch");
        c.text("name", "The name", &self.name, MAX_NAME_CHARS);
        c.text(
            "technique",
            "The technique",
            &self.technique,
            MAX_SHORT_TEXT_CHARS,
        );
        if let Some(d) = &self.date {
            if !is_valid_date(d) {
                let shown: String = d.chars().take(20).collect();
                c.out.push(RecordDiagnostic::error(
                    "swatch.date_invalid",
                    "date",
                    format!("The date {shown:?} is not a calendar date written YYYY-MM-DD."),
                ));
            }
        }
        if self.yarns.len() > MAX_SWATCH_YARNS {
            c.out.push(RecordDiagnostic::error(
                "record.too_many",
                "yarns",
                format!("A swatch can list up to {MAX_SWATCH_YARNS} yarns."),
            ));
        }
        for (i, y) in self.yarns.iter().enumerate() {
            if let Some(id) = &y.material_id {
                if !is_valid_id(id) {
                    c.out.push(RecordDiagnostic::error(
                        "record.id_invalid",
                        format!("yarns[{i}].material_id"),
                        "A yarn refers to a material by an id that is not valid.",
                    ));
                }
            }
            c.text(
                &format!("yarns[{i}].name"),
                "A yarn name",
                &y.name,
                MAX_NAME_CHARS,
            );
        }
        c.text("tools", "The tools", &self.tools, MAX_SHORT_TEXT_CHARS);
        c.count("sett", "The sett in the reed", &self.sett);
        c.length(
            "width_in_reed",
            "The width in the reed",
            &self.width_in_reed,
        );
        for (kind, stage) in self.stages() {
            let k = kind.key();
            let at = kind.phrase(self.craft);
            c.length(
                &format!("{k}.width"),
                &format!("The width {at}"),
                &stage.width,
            );
            c.length(
                &format!("{k}.length"),
                &format!("The length {at}"),
                &stage.length,
            );
            c.count(
                &format!("{k}.across"),
                &format!("The {} counted {at}", self.across_noun()),
                &stage.across,
            );
            c.count(
                &format!("{k}.along"),
                &format!("The {} counted {at}", self.along_noun()),
                &stage.along,
            );
            c.text(
                &format!("{k}.conditions"),
                &format!("How it was measured {at}"),
                &stage.conditions,
                MAX_NOTES_CHARS,
            );
        }
        c.text(
            "finishing",
            "The finishing",
            &self.finishing,
            MAX_NOTES_CHARS,
        );
        c.mass("mass", "The swatch's mass", &self.mass);
        c.text(
            "tension",
            "The tension notes",
            &self.tension,
            MAX_NOTES_CHARS,
        );
        c.text(
            "provenance",
            "The provenance",
            &self.provenance,
            MAX_SHORT_TEXT_CHARS,
        );
        c.text("notes", "The notes", &self.notes, MAX_NOTES_CHARS);
        if c.out.iter().all(|d| d.severity != Severity::Error) {
            self.plausibility(&mut c.out);
        }
        c.out
    }

    /// The warnings about values that are possible but worth checking. Only run once every value is
    /// usable.
    fn plausibility(&self, out: &mut Vec<RecordDiagnostic>) {
        let weaving = self.craft == Some(CraftKind::Weaving);
        // A count taken over a span longer than the swatch itself.
        for (kind, stage) in self.stages() {
            let at = kind.phrase(self.craft);
            let pairs = [
                (
                    &stage.across,
                    &stage.width,
                    "across",
                    "width",
                    self.across_noun(),
                ),
                (
                    &stage.along,
                    &stage.length,
                    "along",
                    "length",
                    self.along_noun(),
                ),
            ];
            for (count, size, ckey, skey, noun) in pairs {
                if let (Some(n), Some((size_len, size_cm))) = (count, usable_cm(size)) {
                    let span_cm = n.value.over.to(LengthUnit::Centimeter);
                    if span_cm > size_cm * (1.0 + 1e-9) {
                        out.push(RecordDiagnostic::warning(
                            "swatch.count_span_exceeds_swatch",
                            format!("{}.{ckey}", kind.key()),
                            format!(
                                "The {noun} {at} were counted over {}, but the swatch is only {} \
                                 in {skey}.",
                                n.value.over.describe(),
                                size_len.describe()
                            ),
                        ));
                    }
                }
            }
        }
        // Growth or loss between stages, earlier to later.
        let order: &[StageKind] = if weaving {
            &[StageKind::OnLoom, StageKind::Before, StageKind::After]
        } else {
            &[StageKind::Before, StageKind::After]
        };
        for dim in ["width", "length"] {
            let get = |k: StageKind| {
                let s = self.stage(k);
                if dim == "width" {
                    usable_cm(&s.width)
                } else {
                    usable_cm(&s.length)
                }
            };
            // Each stage against the latest earlier stage that has the dimension.
            let mut earlier: Option<(StageKind, Length, f64)> = None;
            for &k in order {
                let Some((len, cm)) = get(k) else { continue };
                if let Some((ek, elen, ecm)) = earlier {
                    let change = (cm - ecm) / ecm;
                    if change > GROWTH_WARNING {
                        out.push(RecordDiagnostic::warning(
                            "swatch.grew_implausibly",
                            format!("{}.{dim}", k.key()),
                            format!(
                                "The {dim} {} ({}) is {} more than {} ({}). Check the measurement.",
                                k.phrase(self.craft),
                                len.describe(),
                                percent(change),
                                ek.phrase(self.craft),
                                elen.describe()
                            ),
                        ));
                    } else if -change > SHRINK_WARNING {
                        out.push(RecordDiagnostic::warning(
                            "swatch.shrank_implausibly",
                            format!("{}.{dim}", k.key()),
                            format!(
                                "The {dim} {} ({}) is {} less than {} ({}). Heavy fulling can do \
                                 this; otherwise check the measurement.",
                                k.phrase(self.craft),
                                len.describe(),
                                percent(-change),
                                ek.phrase(self.craft),
                                elen.describe()
                            ),
                        ));
                    }
                }
                earlier = Some((k, len, cm));
            }
        }
        // Cloth wider than the warp in the reed.
        if let Some((reed, reed_cm)) = usable_cm(&self.width_in_reed) {
            for (kind, stage) in self.stages() {
                if let Some((w, cm)) = usable_cm(&stage.width) {
                    if cm > reed_cm * (1.0 + REED_WIDTH_TOLERANCE) {
                        out.push(RecordDiagnostic::warning(
                            "swatch.wider_than_reed",
                            format!("{}.width", kind.key()),
                            format!(
                                "The cloth {} ({}) is wider than the warp in the reed ({}). \
                                 Weft-faced cloth can spread; otherwise check the measurement.",
                                kind.phrase(self.craft),
                                w.describe(),
                                reed.describe()
                            ),
                        ));
                    }
                }
            }
        }
        // Loom setup recorded for a swatch of another craft.
        let other_craft = matches!(
            self.craft,
            Some(CraftKind::Knitting) | Some(CraftKind::Nalbinding)
        );
        if other_craft
            && (self.sett.is_some() || self.width_in_reed.is_some() || !self.on_loom.is_empty())
        {
            out.push(RecordDiagnostic::warning(
                "swatch.loom_setup_not_weaving",
                "sett",
                "This swatch records a loom setup or measurements on the loom, but it is not a \
                 weaving swatch.",
            ));
        }
    }
}

// --- derived figures -------------------------------------------------------------------------------

/// One figure Ply works out from a record. Never stored: computed each time from the measurements.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Figure {
    /// Stable code ("swatch.after.across_per_10cm", "swatch.take_up", "material.yards_per_100g").
    pub code: String,
    /// What it is ("Take-up").
    pub label: String,
    /// The number: a count, a length, or a FRACTION for percentages (0.1 = 10%).
    pub value: f64,
    /// The figure as shown ("8.3%", "20 sts per 10 cm").
    pub text: String,
    /// What it was worked out from, in words.
    pub from: String,
}

fn figure(code: &str, label: &str, value: f64, text: String, from: String) -> Option<Figure> {
    value.is_finite().then(|| Figure {
        code: code.to_string(),
        label: label.to_string(),
        value,
        text,
        from,
    })
}

/// "200 m per 100 g (entered)".
fn with_source(text: String, source: Source) -> String {
    format!("{text} ({})", source.as_str())
}

impl Material {
    /// Every figure that can be worked out from what is recorded (none when nothing is).
    pub fn figures(&self) -> Vec<Figure> {
        let mut out = Vec::new();
        if let Some(r) = self.length_per_mass.filter(|r| r.value.problem().is_none()) {
            let from = format!("from {}", with_source(r.value.describe(), r.source));
            out.extend(figure(
                "material.meters_per_100g",
                "Metres per 100 g",
                r.value.meters_per_100g(),
                format!("{} m per 100 g", number(r.value.meters_per_100g())),
                from.clone(),
            ));
            out.extend(figure(
                "material.yards_per_100g",
                "Yards per 100 g",
                r.value.yards_per_100g(),
                format!("{} yd per 100 g", number(r.value.yards_per_100g())),
                from.clone(),
            ));
            out.extend(figure(
                "material.yards_per_pound",
                "Yards per pound",
                r.value.yards_per_pound(),
                format!("{} yd per lb", number(r.value.yards_per_pound())),
                from,
            ));
        }
        if let Some(r) = self.wpi.filter(|r| r.value.problem().is_none()) {
            let from = format!("from {}", with_source(r.value.describe("wraps"), r.source));
            let per_in = r.value.per_unit(LengthUnit::Inch);
            let per_cm = r.value.per_unit(LengthUnit::Centimeter);
            out.extend(figure(
                "material.wraps_per_inch",
                "Wraps per inch",
                per_in,
                format!("{} wraps per in", number(per_in)),
                from.clone(),
            ));
            out.extend(figure(
                "material.wraps_per_cm",
                "Wraps per cm",
                per_cm,
                format!("{} wraps per cm", number(per_cm)),
                from,
            ));
        }
        let lpm = self.length_per_mass.filter(|r| r.value.problem().is_none());
        if let (Some(m), Some(lpm), None) = (
            self.available_mass.filter(|r| r.value.problem().is_none()),
            lpm,
            self.available_length,
        ) {
            let unit = lpm.value.length.unit;
            let len = lpm.value.length_for(m.value, unit);
            out.extend(figure(
                "material.available_length",
                "Length on hand",
                len,
                format!("about {} {}", number(len), unit.symbol()),
                format!(
                    "from {} on hand at {}",
                    with_source(m.value.describe(), m.source),
                    with_source(lpm.value.describe(), lpm.source)
                ),
            ));
        }
        if let (Some(l), Some(lpm), None) = (
            self.available_length
                .filter(|r| r.value.problem().is_none()),
            lpm,
            self.available_mass,
        ) {
            let unit = lpm.value.mass.unit;
            let mass = lpm.value.mass_for(l.value, unit);
            out.extend(figure(
                "material.available_mass",
                "Mass on hand",
                mass,
                format!("about {} {}", number(mass), unit.symbol()),
                format!(
                    "from {} on hand at {}",
                    with_source(l.value.describe(), l.source),
                    with_source(lpm.value.describe(), lpm.source)
                ),
            ));
        }
        out
    }
}

/// The loss from `earlier` to `later` as a fraction of `earlier`: positive when the later
/// measurement is smaller (shrank, drew in), negative when it grew.
pub fn loss(earlier: Length, later: Length) -> f64 {
    let e = earlier.to(LengthUnit::Centimeter);
    (e - later.to(LengthUnit::Centimeter)) / e
}

impl Swatch {
    /// Every figure that can be worked out from the measurements (none when nothing is measured).
    pub fn figures(&self) -> Vec<Figure> {
        let mut out = Vec::new();
        let weaving = self.craft == Some(CraftKind::Weaving);
        // Counts per stage, normalized.
        for (kind, stage) in self.stages() {
            let at = kind.phrase(self.craft);
            for (count, key, noun) in [
                (&stage.across, "across", self.across_noun()),
                (&stage.along, "along", self.along_noun()),
            ] {
                let Some(r) = count.filter(|r| r.value.problem().is_none()) else {
                    continue;
                };
                let from = format!(
                    "from {} {at}",
                    with_source(r.value.describe(noun), r.source)
                );
                let label = format!("{} {at}", capitalize(noun));
                if weaving {
                    let per_in = r.value.per_unit(LengthUnit::Inch);
                    let per_cm = r.value.per_unit(LengthUnit::Centimeter);
                    out.extend(figure(
                        &format!("swatch.{}.{key}_per_inch", kind.key()),
                        &label,
                        per_in,
                        format!("{} {noun} per in", number(per_in)),
                        from.clone(),
                    ));
                    out.extend(figure(
                        &format!("swatch.{}.{key}_per_cm", kind.key()),
                        &label,
                        per_cm,
                        format!("{} {noun} per cm", number(per_cm)),
                        from,
                    ));
                } else {
                    let p10 = r.value.per_10cm();
                    let p4 = r.value.per_4in();
                    out.extend(figure(
                        &format!("swatch.{}.{key}_per_10cm", kind.key()),
                        &label,
                        p10,
                        format!("{} {noun} per 10 cm", number(p10)),
                        from.clone(),
                    ));
                    out.extend(figure(
                        &format!("swatch.{}.{key}_per_4in", kind.key()),
                        &label,
                        p4,
                        format!("{} {noun} per 4 in", number(p4)),
                        from,
                    ));
                }
            }
        }
        // Changes between stages.
        let mut change = |code: &str,
                          label: &str,
                          a: (&str, &Option<Recorded<Length>>),
                          b: (&str, &Option<Recorded<Length>>)| {
            if let (Some((ea, _)), Some((eb, _))) = (usable_cm(a.1), usable_cm(b.1)) {
                let l = loss(ea, eb);
                let ra = a.1.as_ref().map(|r| r.source).unwrap_or(Source::Measured);
                let rb = b.1.as_ref().map(|r| r.source).unwrap_or(Source::Measured);
                let text = if l >= 0.0 {
                    format!("{} smaller", percent(l))
                } else {
                    format!("{} larger", percent(-l))
                };
                out.extend(figure(
                    code,
                    label,
                    l,
                    text,
                    format!(
                        "from {} {} to {} {}",
                        with_source(ea.describe(), ra),
                        a.0,
                        with_source(eb.describe(), rb),
                        b.0
                    ),
                ));
            }
        };
        if weaving {
            change(
                "swatch.draw_in",
                "Draw-in",
                ("in the reed", &self.width_in_reed),
                ("on the loom", &self.on_loom.width),
            );
            change(
                "swatch.take_up",
                "Take-up",
                ("on the loom", &self.on_loom.length),
                ("off the loom", &self.before.length),
            );
            change(
                "swatch.width_shrinkage",
                "Width shrinkage in finishing",
                ("off the loom", &self.before.width),
                ("after wet finishing", &self.after.width),
            );
            change(
                "swatch.length_shrinkage",
                "Length shrinkage in finishing",
                ("off the loom", &self.before.length),
                ("after wet finishing", &self.after.length),
            );
            change(
                "swatch.total_width_loss",
                "Width lost, reed to finished",
                ("in the reed", &self.width_in_reed),
                ("after wet finishing", &self.after.width),
            );
            change(
                "swatch.total_length_loss",
                "Length lost, loom to finished",
                ("on the loom", &self.on_loom.length),
                ("after wet finishing", &self.after.length),
            );
        } else {
            change(
                "swatch.width_change",
                "Width change in finishing",
                ("before finishing", &self.before.width),
                ("after finishing", &self.after.width),
            );
            change(
                "swatch.length_change",
                "Length change in finishing",
                ("before finishing", &self.before.length),
                ("after finishing", &self.after.length),
            );
        }
        if weaving {
            if let Some(a) = self.length_allowance() {
                out.extend(figure(
                    "swatch.length_allowance",
                    "Length to add for take-up and shrinkage",
                    a.fraction,
                    format!("{} of the finished length", percent(a.fraction)),
                    format!(
                        "from {} on the loom and {} after wet finishing ({} on the loom for each {} \
                         finished)",
                        with_source(a.on_loom.describe(), a.on_loom_source),
                        with_source(a.finished.describe(), a.finished_source),
                        a.on_loom.describe(),
                        a.finished.converted(a.on_loom.unit).describe()
                    ),
                ));
            }
            if let (Some((reed, _)), Some((fin, _))) =
                (usable_cm(&self.width_in_reed), usable_cm(&self.after.width))
            {
                let fraction =
                    reed.to(LengthUnit::Centimeter) / fin.to(LengthUnit::Centimeter) - 1.0;
                out.extend(figure(
                    "swatch.width_allowance",
                    "Width to add in the reed",
                    fraction,
                    format!("{} of the finished width", percent(fraction)),
                    format!(
                        "from {} in the reed and {} after wet finishing",
                        reed.describe(),
                        fin.describe()
                    ),
                ));
            }
        }
        // Mass per area, at the stage the area is known (after finishing first).
        if let Some(m) = self.mass.filter(|r| r.value.problem().is_none()) {
            if let Some((kind, area_cm2)) = self.area_cm2() {
                let g = m.value.to(MassUnit::Gram);
                let per = g / area_cm2 * 100.0;
                out.extend(figure(
                    "swatch.grams_per_100cm2",
                    "Mass per 100 square cm",
                    per,
                    format!("{} g per 100 sq cm", number(per)),
                    format!(
                        "from {} over {} sq cm {}",
                        with_source(m.value.describe(), m.source),
                        number(area_cm2),
                        kind.phrase(self.craft)
                    ),
                ));
            }
        }
        out
    }

    /// The swatch's area in square cm, at the stage it was last measured whole: after finishing,
    /// else before finishing.
    pub fn area_cm2(&self) -> Option<(StageKind, f64)> {
        for kind in [StageKind::After, StageKind::Before] {
            let s = self.stage(kind);
            if let (Some((_, w)), Some((_, l))) = (usable_cm(&s.width), usable_cm(&s.length)) {
                return Some((kind, w * l));
            }
        }
        None
    }

    /// Weaving: the length to add to a finished length for take-up and shrinkage together, from the
    /// length on the loom and the length after wet finishing: `on_loom / finished - 1`, so that
    /// `finished * (1 + fraction)` is exactly the length to weave. `None` without both lengths.
    pub fn length_allowance(&self) -> Option<LengthAllowance> {
        let a = self.on_loom.length?;
        let b = self.after.length?;
        if a.value.problem().is_some() || b.value.problem().is_some() {
            return None;
        }
        let fraction =
            a.value.to(LengthUnit::Centimeter) / b.value.to(LengthUnit::Centimeter) - 1.0;
        fraction.is_finite().then_some(LengthAllowance {
            fraction,
            loss: loss(a.value, b.value),
            on_loom: a.value,
            on_loom_source: a.source,
            finished: b.value,
            finished_source: b.source,
        })
    }
}

/// A weaving swatch's length allowance, with what it came from.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct LengthAllowance {
    /// What to add to the finished length: `on_loom / finished - 1`.
    pub fraction: f64,
    /// The loss from the loom to finished, as a fraction of the length on the loom.
    pub loss: f64,
    pub on_loom: Length,
    pub on_loom_source: Source,
    pub finished: Length,
    pub finished_source: Source,
}

fn capitalize(s: &str) -> String {
    let mut c = s.chars();
    match c.next() {
        Some(f) => f.to_uppercase().collect::<String>() + c.as_str(),
        None => String::new(),
    }
}

// --- serde helpers ---------------------------------------------------------------------------------

/// `Option<YarnWeight>` in the file as `"lace"`, `"super_fine"`, ... `"jumbo"` (or null).
mod weight_opt {
    use crate::YarnWeight;
    use serde::{Deserialize, Deserializer, Serializer};

    pub const NAMES: [(YarnWeight, &str); 8] = [
        (YarnWeight::Lace, "lace"),
        (YarnWeight::SuperFine, "super_fine"),
        (YarnWeight::Fine, "fine"),
        (YarnWeight::Light, "light"),
        (YarnWeight::Medium, "medium"),
        (YarnWeight::Bulky, "bulky"),
        (YarnWeight::SuperBulky, "super_bulky"),
        (YarnWeight::Jumbo, "jumbo"),
    ];

    pub fn serialize<S: Serializer>(v: &Option<YarnWeight>, s: S) -> Result<S::Ok, S::Error> {
        match v {
            None => s.serialize_none(),
            Some(w) => s.serialize_some(
                NAMES
                    .iter()
                    .find(|(k, _)| k == w)
                    .map(|(_, n)| *n)
                    .unwrap_or("medium"),
            ),
        }
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Option<YarnWeight>, D::Error> {
        let raw: Option<String> = Option::deserialize(d)?;
        match raw {
            None => Ok(None),
            Some(s) => NAMES
                .iter()
                .find(|(_, n)| *n == s)
                .map(|(w, _)| Some(*w))
                .ok_or_else(|| serde::de::Error::custom(format!("unknown yarn weight {s:?}"))),
        }
    }
}

/// `Option<CraftKind>` in the file as `"weaving"`, `"knitting"`, `"nalbinding"` (or null).
mod craft_opt {
    use crate::CraftKind;
    use serde::{Deserialize, Deserializer, Serializer};

    pub fn serialize<S: Serializer>(v: &Option<CraftKind>, s: S) -> Result<S::Ok, S::Error> {
        match v {
            None => s.serialize_none(),
            Some(CraftKind::Weaving) => s.serialize_some("weaving"),
            Some(CraftKind::Knitting) => s.serialize_some("knitting"),
            Some(CraftKind::Nalbinding) => s.serialize_some("nalbinding"),
        }
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Option<CraftKind>, D::Error> {
        let raw: Option<String> = Option::deserialize(d)?;
        match raw.as_deref() {
            None => Ok(None),
            Some("weaving") => Ok(Some(CraftKind::Weaving)),
            Some("knitting") => Ok(Some(CraftKind::Knitting)),
            Some("nalbinding") => Ok(Some(CraftKind::Nalbinding)),
            Some(other) => Err(serde::de::Error::custom(format!("unknown craft {other:?}"))),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn wool() -> Material {
        Material {
            id: "grey-wool".into(),
            name: "Grey wool".into(),
            maker: "Invented mill, Fell yarn".into(),
            fibers: vec![
                FiberPart {
                    fiber: "wool".into(),
                    percent: Some(80.0),
                },
                FiberPart {
                    fiber: "nylon".into(),
                    percent: Some(20.0),
                },
            ],
            weight: Some(YarnWeight::Light),
            structure: "4-ply, worsted-spun".into(),
            length_per_mass: Some(Recorded::entered(LengthPerMass::new(
                Length::new(200.0, LengthUnit::Meter),
                Mass::grams(100.0),
            ))),
            wpi: Some(Recorded::measured(CountOver::new(
                11.0,
                Length::inches(1.0),
            ))),
            color: "Heather grey".into(),
            dye_lot: "A12".into(),
            available_mass: Some(Recorded::measured(Mass::grams(450.0))),
            available_length: None,
            notes: String::new(),
        }
    }

    fn knit_swatch() -> Swatch {
        let mut s = Swatch::new("sw-1", "Grey wool");
        s.craft = Some(CraftKind::Knitting);
        s.date = Some("2026-11-10".into());
        s.before = Stage {
            width: Some(Recorded::measured(Length::cm(15.0))),
            length: Some(Recorded::measured(Length::cm(16.0))),
            across: Some(Recorded::measured(CountOver::new(22.0, Length::cm(10.0)))),
            along: Some(Recorded::measured(CountOver::new(30.0, Length::cm(10.0)))),
            conditions: String::new(),
        };
        s.after = Stage {
            width: Some(Recorded::measured(Length::cm(16.5))),
            length: Some(Recorded::measured(Length::cm(15.2))),
            across: Some(Recorded::measured(CountOver::new(20.0, Length::cm(10.0)))),
            along: Some(Recorded::measured(CountOver::new(32.0, Length::cm(10.0)))),
            conditions: "flat, unpinned, after a day".into(),
        };
        s.finishing = "washed, dried flat".into();
        s
    }

    fn code_list(d: &[RecordDiagnostic]) -> Vec<&str> {
        d.iter().map(|x| x.code.as_str()).collect()
    }

    #[test]
    fn a_full_and_an_empty_record_are_clean() {
        assert!(
            wool().diagnostics().is_empty(),
            "{:?}",
            wool().diagnostics()
        );
        assert!(Material::new("m", "").diagnostics().is_empty());
        assert!(
            knit_swatch().diagnostics().is_empty(),
            "{:?}",
            knit_swatch().diagnostics()
        );
        assert!(Swatch::new("s", "").diagnostics().is_empty());
        assert!(Material::new("m", "").figures().is_empty());
        assert!(Swatch::new("s", "").figures().is_empty());
    }

    #[test]
    fn material_figures_are_worked_out_not_stored() {
        let m = wool();
        let f = m.figures();
        let by = |code: &str| f.iter().find(|x| x.code == code).unwrap().clone();
        assert_eq!(by("material.meters_per_100g").value, 200.0);
        assert!((by("material.yards_per_100g").value - 218.7226).abs() < 1e-3);
        assert_eq!(by("material.wraps_per_inch").value, 11.0);
        assert_eq!(by("material.available_length").value, 900.0);
        assert_eq!(by("material.available_length").text, "about 900 m");
        assert!(by("material.available_length")
            .from
            .contains("450 g (measured)"));
        // The record is unchanged by working out its figures.
        assert_eq!(m, wool());
    }

    #[test]
    fn swatch_figures_compare_stages() {
        let s = knit_swatch();
        let f = s.figures();
        let by = |code: &str| f.iter().find(|x| x.code == code).cloned();
        assert_eq!(by("swatch.after.across_per_10cm").unwrap().value, 20.0);
        assert_eq!(
            by("swatch.before.across_per_10cm").unwrap().text,
            "22 sts per 10 cm"
        );
        let w = by("swatch.width_change").unwrap();
        assert!((w.value - (-0.1)).abs() < 1e-12, "grew 10%: {}", w.value);
        assert_eq!(w.text, "10% larger");
        let l = by("swatch.length_change").unwrap();
        assert!((l.value - 0.05).abs() < 1e-12);
        assert_eq!(l.text, "5% smaller");
        assert!(by("swatch.take_up").is_none(), "not a weaving swatch");
    }

    #[test]
    fn weaving_figures_follow_the_weaver() {
        let mut s = Swatch::new("towel", "Towel sample");
        s.craft = Some(CraftKind::Weaving);
        s.sett = Some(Recorded::entered(CountOver::new(24.0, Length::inches(1.0))));
        s.width_in_reed = Some(Recorded::entered(Length::inches(12.0)));
        s.on_loom.width = Some(Recorded::measured(Length::inches(11.0)));
        s.on_loom.length = Some(Recorded::measured(Length::inches(20.0)));
        s.on_loom.along = Some(Recorded::measured(CountOver::new(
            22.0,
            Length::inches(1.0),
        )));
        s.before.width = Some(Recorded::measured(Length::inches(10.5)));
        s.before.length = Some(Recorded::measured(Length::inches(19.0)));
        s.after.width = Some(Recorded::measured(Length::inches(10.0)));
        s.after.length = Some(Recorded::measured(Length::inches(18.0)));
        assert!(s.diagnostics().is_empty(), "{:?}", s.diagnostics());
        let f = s.figures();
        let v = |code: &str| f.iter().find(|x| x.code == code).unwrap().value;
        assert!((v("swatch.draw_in") - 1.0 / 12.0).abs() < 1e-12);
        assert!((v("swatch.take_up") - 0.05).abs() < 1e-12);
        assert!((v("swatch.length_shrinkage") - 1.0 / 19.0).abs() < 1e-12);
        assert!((v("swatch.total_length_loss") - 0.1).abs() < 1e-12);
        assert!((v("swatch.length_allowance") - 1.0 / 9.0).abs() < 1e-12);
        assert!((v("swatch.width_allowance") - 0.2).abs() < 1e-12);
        assert_eq!(v("swatch.on_loom.along_per_inch"), 22.0);
        let a = s.length_allowance().unwrap();
        assert!(
            (18.0 * (1.0 + a.fraction) - 20.0).abs() < 1e-12,
            "finished x allowance = on loom"
        );
    }

    #[test]
    fn impossible_values_are_errors_with_stable_codes() {
        let mut m = wool();
        m.length_per_mass = Some(Recorded::entered(LengthPerMass::new(
            Length::new(0.0, LengthUnit::Meter),
            Mass::grams(f64::NAN),
        )));
        m.fibers[0].percent = Some(90.0);
        m.available_mass = Some(Recorded {
            value: Mass::grams(10.0),
            source: Source::Default,
        });
        let d = m.diagnostics();
        assert_eq!(
            code_list(&d),
            vec![
                "material.fiber_percents_over_100",
                "quantity.not_positive",
                "quantity.not_finite",
                "record.default_source"
            ]
        );
        assert!(d.iter().all(|x| x.severity == Severity::Error));
        let mut s = knit_swatch();
        s.date = Some("2026-02-30".into());
        s.after.width = Some(Recorded::measured(Length::cm(-1.0)));
        s.before.across = Some(Recorded::measured(CountOver::new(
            f64::INFINITY,
            Length::cm(10.0),
        )));
        let d = s.diagnostics();
        assert_eq!(
            code_list(&d),
            vec![
                "swatch.date_invalid",
                "quantity.not_finite",
                "quantity.not_positive"
            ]
        );
        assert_eq!(d[1].field, "before.across.count");
        assert_eq!(d[2].field, "after.width");
    }

    #[test]
    fn unusual_values_are_warnings() {
        let mut s = knit_swatch();
        s.after.width = Some(Recorded::measured(Length::cm(30.0))); // doubled
        s.after.across = Some(Recorded::measured(CountOver::new(20.0, Length::cm(40.0))));
        let d = s.diagnostics();
        assert_eq!(
            code_list(&d),
            vec![
                "swatch.count_span_exceeds_swatch",
                "swatch.grew_implausibly"
            ]
        );
        assert!(d.iter().all(|x| x.severity == Severity::Warning));
        assert!(d[1].message.contains("100% more"), "{}", d[1].message);
        let mut w = Swatch::new("w", "");
        w.craft = Some(CraftKind::Weaving);
        w.width_in_reed = Some(Recorded::entered(Length::cm(30.0)));
        w.after.width = Some(Recorded::measured(Length::cm(33.0)));
        assert_eq!(code_list(&w.diagnostics()), vec!["swatch.wider_than_reed"]);
        let mut k = knit_swatch();
        k.sett = Some(Recorded::entered(CountOver::new(12.0, Length::inches(1.0))));
        assert_eq!(
            code_list(&k.diagnostics()),
            vec!["swatch.loom_setup_not_weaving"]
        );
        let mut m = wool();
        m.fibers[1].percent = Some(10.0);
        m.available_length = Some(Recorded::entered(Length::new(600.0, LengthUnit::Meter)));
        assert_eq!(
            code_list(&m.diagnostics()),
            vec![
                "material.fiber_percents_not_100",
                "material.available_mismatch"
            ]
        );
    }

    #[test]
    fn dates_and_ids() {
        assert!(is_valid_date("2024-02-29"));
        assert!(!is_valid_date("2023-02-29"));
        assert!(!is_valid_date("2026-13-01"));
        assert!(!is_valid_date("26-11-10"));
        assert!(!is_valid_date("2026-1-10x"));
        assert!(!is_valid_date("２０２６-11-10"));
        assert!(is_valid_id("3f1c9a2e-0d4b-4c8e-9f00-123456789abc"));
        assert!(!is_valid_id("../x"));
    }

    #[test]
    fn citations_name_the_stage_and_the_finishing() {
        let s = knit_swatch();
        assert_eq!(
            s.basis(Source::Measured, Some(StageKind::After)),
            "measured after finishing (washed, dried flat), swatch Grey wool 2026-11-10"
        );
        assert_eq!(
            s.basis(Source::Measured, Some(StageKind::Before)),
            "measured before finishing, swatch Grey wool 2026-11-10"
        );
        assert_eq!(Swatch::new("x", " ").citation(), "swatch unnamed swatch");
        assert_eq!(s.planning_across().unwrap().1, StageKind::After);
    }
}
