//! Structured nalbinding RECIPES (roadmap M8-04, ADR 0017): an optional, ordered list of segments
//! that says how a worked object is made, from its start (a foundation chain, a centre start, loops
//! picked up around an opening) through its body (rounds or rows) and shaping (increases, decreases,
//! short rows, an opening left for a thumb, a join) to its finish. A FREEFORM segment keeps any
//! technique the kinds cannot express as the maker's own words, and Ply never interprets it.
//!
//! # What Ply checks and what it only records
//!
//! [`check`] reads the recipe's STRUCTURE: every stitch notation (with the existing strict or lenient
//! reader, text kept verbatim, every problem listed), the order of the parts (a start before any
//! rounds, a finish at the end of each part), the references between steps (an opening is later
//! worked or closed, a pick-up names an earlier opening), that counts are positive, that a
//! measurement has a value and a unit, and the stitch count the recipe's own numbers give (an
//! increase of 6 a round for 5 rounds from 6 stitches makes 36; a decrease cannot remove more
//! stitches than the round has). It never simulates the fabric: whether the piece lies flat, fits a
//! hand or closes neatly is the maker's judgement, so notes, cautions, fit targets and the methods
//! chosen are recorded and printed, not verified.
//!
//! # Ownership
//!
//! The `.plynal` document is written and read by the app (Dart `NalbindProject`, schema version 3).
//! These types mirror its `recipe` object field for field (serde camelCase) so the engine's tests
//! read the same fixture files the app does; the app sends a recipe to the engine through the
//! bridge DTOs for [`check`]. A change to the shape bumps the `.plynal` schema version (ADR 0002).

mod check;
mod written;

#[cfg(test)]
mod tests;

use serde::{Deserialize, Serialize};

/// A step's place in words, `Step 3 (Cuff)` (readiness names unchecked steps the way issues do).
pub(crate) use check::place_of;
pub use check::{
    check, Count, NotationSummary, RecipeCode, RecipeIssue, RecipeReport, RecipeSeverity,
    SegmentReport, StitchReading, StitchUse,
};

/// Most segments a recipe may hold (a mitten needs a dozen; the cap stops a hostile file).
pub const MAX_SEGMENTS: usize = 1_000;
/// Most fit measurements a recipe may hold.
pub const MAX_FIT: usize = 100;
/// Longest text field, in UTF-16 code units (what the app's text fields count).
pub const MAX_TEXT: usize = 10_000;
/// Most text a recipe may hold in all, in UTF-16 code units: every label, note, warning, free text,
/// notation and the rest together. Bounds the report as well as the work.
pub const MAX_TOTAL_TEXT: usize = 200_000;
/// Longest notation Ply reads, in UTF-16 code units (Hansen codes are a few dozen characters).
pub const MAX_NOTATION: usize = 200;
/// Most notation problems reported for one stitch; the rest are counted in one more issue.
pub const MAX_NOTATION_ISSUES: usize = 10;
/// Highest stitch count Ply counts to; a recipe's numbers past it are refused, never wrapped.
pub const MAX_STITCHES: u32 = 1_000_000;

/// A recipe: the fit it aims for, its segments in working order, which segments the maker has
/// ticked done in the follow view (ids, in segment order), and the highest segment number ever
/// given, so an id is never given twice (a deleted step's id is not reused).
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Recipe {
    #[serde(default)]
    pub fit: Vec<Measurement>,
    #[serde(default)]
    pub segments: Vec<Segment>,
    /// Working progress, not instructions: ignored by [`check`].
    #[serde(default)]
    pub done: Vec<String>,
    /// The app's id counter (`segment-N`); ignored by [`check`].
    #[serde(default)]
    pub last_segment_number: u32,
}

/// One step of a recipe. `id` is stable (`segment-N` from the editor): it never changes on edit,
/// rename or move, so a pick-up or join can name an opening by it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Segment {
    #[serde(default)]
    pub id: String,
    /// The maker's own label ("Cuff", "Thumb"); display text only.
    #[serde(default)]
    pub title: String,
    pub work: Work,
    /// The stitch this segment is worked in. `None` means the project's stitch (for the kinds that
    /// use one). The notation is kept exactly as written.
    #[serde(default)]
    pub stitch: Option<SegmentStitch>,
    /// What the segment aims for ("Width across the crown", 18 cm). Recorded, not verified.
    #[serde(default)]
    pub target: Option<Measurement>,
    /// Construction notes, printed under the step.
    #[serde(default)]
    pub notes: String,
    /// The author's own warning to the maker ("keep the chain loose"). Recorded, not verified.
    #[serde(default)]
    pub caution: String,
}

/// A stitch given on a segment: the Hansen notation verbatim, an optional display name, and how
/// the notation is read.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SegmentStitch {
    #[serde(default)]
    pub notation: String,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub reading: Reading,
}

/// How a segment's notation is read: [`Reading::Strict`] for notation written for this recipe
/// (every problem is an error), [`Reading::Lenient`] for a code copied from a source in another
/// dialect (kept verbatim; each problem at its own severity).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Reading {
    #[default]
    Strict,
    Lenient,
}

/// Which stage of the work a segment belongs to.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Phase {
    /// Begins a part: a foundation chain, a centre start, loops picked up from earlier work.
    Start,
    /// Rounds or rows worked without shaping.
    Body,
    /// Increases, decreases, short rows, an opening, a join.
    Shaping,
    /// Ends a part.
    Finish,
    /// A note that is not a step of the work (free text only).
    Other,
}

/// What a segment does, with the data its kind needs. Every number is optional, because a recipe
/// may be partial or say "until it fits"; unknown stays unknown.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(
    tag = "kind",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
pub enum Work {
    /// A chain of stitches worked with no previous round, then joined into a ring (a cuff or brim)
    /// or left open for rows.
    FoundationChain {
        #[serde(default)]
        stitches: Option<u32>,
        #[serde(default)]
        join: Option<ChainJoin>,
    },
    /// A small ring of stitches at the centre (a hat crown, a mitten tip, a sock toe).
    CentreStart {
        #[serde(default)]
        stitches: Option<u32>,
    },
    /// A new part started from loops of earlier work, such as a thumb from the loops around a thumb
    /// opening. `from` names the opening segment by id, when there is one.
    PickUp {
        #[serde(default)]
        from: Option<String>,
        #[serde(default)]
        stitches: Option<u32>,
    },
    /// Rounds without shaping, in a spiral or joined.
    Rounds {
        #[serde(default)]
        worked: Option<RoundJoin>,
        #[serde(default)]
        extent: Option<Extent>,
    },
    /// Rows worked back and forth (a flat panel).
    Rows {
        #[serde(default)]
        extent: Option<Extent>,
    },
    /// Stitches added each round.
    Increase {
        #[serde(default)]
        per_round: Option<u32>,
        #[serde(default)]
        method: Option<IncreaseMethod>,
        #[serde(default)]
        extent: Option<Extent>,
    },
    /// Stitches taken away each round.
    Decrease {
        #[serde(default)]
        per_round: Option<u32>,
        #[serde(default)]
        method: Option<DecreaseMethod>,
        #[serde(default)]
        extent: Option<Extent>,
    },
    /// Partial rows worked back and forth over part of the round (a heel, a raised back).
    ShortRows {
        #[serde(default)]
        extent: Option<Extent>,
    },
    /// A gap left in the round (a thumb opening): `skip` loops of the previous round are left
    /// unconnected and `stitches` new stitches are worked across the gap. Later worked (a pick-up
    /// that starts from it) or closed (a join).
    Opening {
        #[serde(default)]
        skip: Option<u32>,
        #[serde(default)]
        stitches: Option<u32>,
    },
    /// Join edges, or close an opening (`closes` names it by id).
    Join {
        #[serde(default)]
        closes: Option<String>,
    },
    /// Ends the part.
    Finish {
        #[serde(default)]
        method: Option<FinishMethod>,
    },
    /// The maker's own words, never interpreted. `role` places it in the work, so the order checks
    /// still see a free-text start or finish.
    Freeform {
        role: Phase,
        #[serde(default)]
        text: String,
    },
}

/// What a foundation chain becomes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ChainJoin {
    /// Joined into a ring and worked in the round.
    Ring,
    /// Left open and worked in rows.
    Flat,
}

/// How rounds climb.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum RoundJoin {
    /// A continuous spiral (the usual way; it leaves a step where the rounds meet).
    Spiral,
    /// Each round joined before the next begins.
    Joined,
}

/// How an increase is worked.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum IncreaseMethod {
    /// Two stitches connected into the same loop of the previous round.
    SameLoopTwice,
}

/// How a decrease is worked.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum DecreaseMethod {
    /// One stitch connected through two loops of the previous round at once.
    TwoLoopsAtOnce,
    /// A loop of the previous round skipped.
    SkipALoop,
}

/// How a part is finished.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum FinishMethod {
    /// The last loops drawn together to close a tip (a mitten top, a thumb, a hat crown worked up).
    CloseTip,
    /// Ended at an open edge (a cuff, a brim), the last stitches tapered to smooth the step.
    TaperEdge,
}

/// How far a segment goes. `None` on a segment means the recipe does not say.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(
    tag = "type",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
pub enum Extent {
    /// A number of rounds (rows for rows and short rows).
    Rounds { count: u32 },
    /// Until the round has this many stitches (increases and decreases only).
    UntilStitches { count: u32 },
    /// Until a landmark ("it reaches the base of the thumb") or a measurement.
    Until { measure: Measurement },
}

/// A length with its unit, and what it measures. A value without a unit is a problem, never
/// guessed; a missing value is allowed (a landmark, or a partial recipe).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Measurement {
    #[serde(default)]
    pub label: String,
    #[serde(default)]
    pub value: Option<f64>,
    #[serde(default)]
    pub unit: Option<LengthUnit>,
}

/// A length unit.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum LengthUnit {
    #[serde(rename = "mm")]
    Millimetres,
    #[serde(rename = "cm")]
    Centimetres,
    #[serde(rename = "in")]
    Inches,
}

impl LengthUnit {
    /// The unit as written after a number.
    pub fn symbol(self) -> &'static str {
        match self {
            LengthUnit::Millimetres => "mm",
            LengthUnit::Centimetres => "cm",
            LengthUnit::Inches => "in",
        }
    }
}

/// The kind of a segment without its data (for labels and the bridge).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SegmentKind {
    FoundationChain,
    CentreStart,
    PickUp,
    Rounds,
    Rows,
    Increase,
    Decrease,
    ShortRows,
    Opening,
    Join,
    Finish,
    Freeform,
}

impl Work {
    /// The kind of this work.
    pub fn kind(&self) -> SegmentKind {
        match self {
            Work::FoundationChain { .. } => SegmentKind::FoundationChain,
            Work::CentreStart { .. } => SegmentKind::CentreStart,
            Work::PickUp { .. } => SegmentKind::PickUp,
            Work::Rounds { .. } => SegmentKind::Rounds,
            Work::Rows { .. } => SegmentKind::Rows,
            Work::Increase { .. } => SegmentKind::Increase,
            Work::Decrease { .. } => SegmentKind::Decrease,
            Work::ShortRows { .. } => SegmentKind::ShortRows,
            Work::Opening { .. } => SegmentKind::Opening,
            Work::Join { .. } => SegmentKind::Join,
            Work::Finish { .. } => SegmentKind::Finish,
            Work::Freeform { .. } => SegmentKind::Freeform,
        }
    }

    /// The stage of the work this belongs to (a free-text segment's is the maker's choice).
    pub fn phase(&self) -> Phase {
        match self {
            Work::FoundationChain { .. } | Work::CentreStart { .. } | Work::PickUp { .. } => {
                Phase::Start
            }
            Work::Rounds { .. } | Work::Rows { .. } => Phase::Body,
            Work::Increase { .. }
            | Work::Decrease { .. }
            | Work::ShortRows { .. }
            | Work::Opening { .. }
            | Work::Join { .. } => Phase::Shaping,
            Work::Finish { .. } => Phase::Finish,
            Work::Freeform { role, .. } => *role,
        }
    }
}

impl SegmentKind {
    /// Whether a segment of this kind is worked in a stitch (so a missing one is reported and
    /// `stitch: None` means the project's stitch). Joins, finishes and free text are not.
    pub fn uses_stitch(self) -> bool {
        !matches!(
            self,
            SegmentKind::Join | SegmentKind::Finish | SegmentKind::Freeform
        )
    }

    /// Whether this kind works into the loops of a previous round or row, so its stitch needs a
    /// connection (such as `F1`). Starts make the first loops; joins and finishes are not worked in
    /// a stitch; an opening's stitches are deliberately left unconnected.
    pub fn connects_to_previous_round(self) -> bool {
        matches!(
            self,
            SegmentKind::Rounds
                | SegmentKind::Rows
                | SegmentKind::Increase
                | SegmentKind::Decrease
                | SegmentKind::ShortRows
        )
    }
}

impl Recipe {
    /// Parse a recipe object from JSON (the `recipe` value of a `.plynal` document).
    pub fn from_json(text: &str) -> Result<Recipe, crate::NalbindError> {
        Ok(serde_json::from_str(text)?)
    }
}
