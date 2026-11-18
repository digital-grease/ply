//! Transparently-mirrored DTOs for nalbinding RECIPES (M8-04, ADR 0017). The app owns the `.plynal`
//! document (Dart `NalbindProject`); it sends the recipe here as a [`RecipeDto`] and gets back the
//! engine's [`RecipeReportDto`]: one report per segment (what the notation reader made of its own
//! stitch, its count, its written instruction), the project's stitch read once, and every issue
//! with its stable code. A stitch crosses as a small [`RecipeStitchReadingDto`] (never the reader's
//! per-character diagnostics: its problems are the segment's issues), so the report stays bounded.
//!
//! Only flat enums and structs cross (a segment is one struct with the optional fields of every
//! kind; the engine conversion reads the ones its kind uses), so no freezed classes are generated.

use ply_nalbind::recipe::{
    self, ChainJoin, Count, DecreaseMethod, Extent, FinishMethod, IncreaseMethod, LengthUnit,
    Measurement, Phase, Reading, Recipe, RecipeIssue, RecipeReport, RecipeSeverity, RoundJoin,
    Segment, SegmentKind, SegmentReport, SegmentStitch, StitchReading, StitchUse, Work,
};

// --- enums (flat; frb mirrors them as plain Dart enums) --------------------------------------------

/// The kind of a recipe segment.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RecipeKindDto {
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

/// The stage of the work a segment belongs to.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RecipePhaseKind {
    Start,
    Body,
    Shaping,
    Finish,
    Other,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RecipeChainJoinKind {
    Ring,
    Flat,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RecipeRoundJoinKind {
    Spiral,
    Joined,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RecipeIncreaseKind {
    SameLoopTwice,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RecipeDecreaseKind {
    TwoLoopsAtOnce,
    SkipALoop,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RecipeFinishKind {
    CloseTip,
    TaperEdge,
}

/// How far a segment goes (a segment with no extent leaves it unstated).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RecipeExtentKind {
    /// `count` rounds (rows for rows and short rows).
    Rounds,
    /// Until the round has `count` stitches.
    UntilStitches,
    /// Until `measure` (a landmark, a length, or both).
    Until,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RecipeLengthUnitKind {
    Millimetres,
    Centimetres,
    Inches,
}

/// How a segment's own notation is read.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RecipeReadingKind {
    /// Written for this recipe: every problem is an error.
    Strict,
    /// Copied from a source in another dialect: each problem at its own severity.
    Lenient,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum RecipeSeverityKind {
    Info,
    Warning,
    Error,
}

/// What a segment's count says.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RecipeCountKind {
    /// `count` stitches, from the recipe's own numbers.
    Known,
    /// The recipe does not say enough to count.
    Unknown,
    /// Its numbers cannot be worked: not counted, see its problems.
    Refused,
    /// Not a step of a part (a note, or a step outside any part).
    NotApplicable,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RecipeStitchSourceKind {
    Project,
    Own,
}

// --- structs ---------------------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq)]
pub struct RecipeMeasurementDto {
    pub label: String,
    pub value: Option<f64>,
    pub unit: Option<RecipeLengthUnitKind>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct RecipeExtentDto {
    pub kind: RecipeExtentKind,
    /// For `Rounds` and `UntilStitches`.
    pub count: Option<u32>,
    /// For `Until`.
    pub measure: Option<RecipeMeasurementDto>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RecipeStitchDto {
    pub notation: String,
    pub name: String,
    pub reading: RecipeReadingKind,
}

/// One segment, with the optional fields of every kind (the conversion reads only its kind's).
#[derive(Debug, Clone, PartialEq)]
pub struct RecipeSegmentDto {
    pub id: String,
    pub title: String,
    pub kind: RecipeKindDto,
    /// `None` = the project's stitch.
    pub stitch: Option<RecipeStitchDto>,
    /// Foundation chain, centre start and pick-up: stitches (loops) to start with; opening: the
    /// stitches worked across the gap.
    pub stitches: Option<u32>,
    /// Opening: loops of the previous round skipped.
    pub skip: Option<u32>,
    pub chain_join: Option<RecipeChainJoinKind>,
    pub round_join: Option<RecipeRoundJoinKind>,
    pub per_round: Option<u32>,
    pub increase_method: Option<RecipeIncreaseKind>,
    pub decrease_method: Option<RecipeDecreaseKind>,
    pub finish_method: Option<RecipeFinishKind>,
    pub extent: Option<RecipeExtentDto>,
    /// Pick-up: the opening it starts from; join: the opening it closes (a segment id).
    pub reference: Option<String>,
    /// Free text: where it belongs in the work.
    pub role: Option<RecipePhaseKind>,
    /// Free text: the maker's words.
    pub text: String,
    pub target: Option<RecipeMeasurementDto>,
    pub notes: String,
    pub caution: String,
}

#[derive(Debug, Clone, PartialEq)]
pub struct RecipeDto {
    pub fit: Vec<RecipeMeasurementDto>,
    pub segments: Vec<RecipeSegmentDto>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RecipeIssueDto {
    /// The engine's stable kebab-case code (e.g. `opening-not-used`); safe to key on.
    pub code: String,
    pub severity: RecipeSeverityKind,
    /// The segment's position (0-based), when the issue is about one.
    pub segment: Option<u32>,
    pub segment_id: Option<String>,
    /// The fit measurement's position (0-based), when the issue is about one.
    pub fit: Option<u32>,
    /// Without its place.
    pub message: String,
    /// With its place (`Step 3 (Cuff): ...`).
    pub text: String,
}

/// A stitch as written and what the notation reader made of it, in a few fields.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RecipeStitchReadingDto {
    /// Exactly as written.
    pub notation: String,
    /// Its display name (empty for the project's, whose name the app holds).
    pub name: String,
    pub reading: RecipeReadingKind,
    /// False when the notation is too long for Ply to read (the other fields are then empty).
    pub read: bool,
    /// Accepted in its mode (only formatting notes remain).
    pub accepted: bool,
    /// Accepted and not lossy: the stitch is what the text says.
    pub exact: bool,
    /// The canonical print of the best-effort stitch.
    pub normalized: String,
    /// Its connections into the previous round in canonical form (`F1`, `B1 F1`), or empty.
    pub connection: String,
    /// How many problems the reader found.
    pub problems: u32,
}

pub struct RecipeSegmentReportDto {
    pub index: u32,
    pub id: String,
    pub kind: RecipeKindDto,
    pub phase: RecipePhaseKind,
    /// 1-based part number, or `None` outside a part.
    pub part_number: Option<u32>,
    /// Where its stitch comes from, or `None` when it has none. For the project's stitch the
    /// reading is [`RecipeReportDto::project_stitch`].
    pub stitch_source: Option<RecipeStitchSourceKind>,
    /// Its own stitch as read, when it has one.
    pub stitch: Option<RecipeStitchReadingDto>,
    pub count_kind: RecipeCountKind,
    pub count: Option<u32>,
    pub written: String,
    pub target: Option<String>,
    /// False for free text, which Ply never reads.
    pub checked: bool,
}

pub struct RecipeReportDto {
    pub segments: Vec<RecipeSegmentReportDto>,
    pub issues: Vec<RecipeIssueDto>,
    /// The fit measurements as written.
    pub fit: Vec<String>,
    /// The project's stitch as read, once for every segment worked in it (`None`: no stitch).
    pub project_stitch: Option<RecipeStitchReadingDto>,
    /// True when the recipe was past the limits: nothing was checked and `segments` is empty.
    pub too_large: bool,
}

// --- conversions -----------------------------------------------------------------------------------

impl From<RecipeLengthUnitKind> for LengthUnit {
    fn from(u: RecipeLengthUnitKind) -> Self {
        match u {
            RecipeLengthUnitKind::Millimetres => LengthUnit::Millimetres,
            RecipeLengthUnitKind::Centimetres => LengthUnit::Centimetres,
            RecipeLengthUnitKind::Inches => LengthUnit::Inches,
        }
    }
}

impl From<LengthUnit> for RecipeLengthUnitKind {
    fn from(u: LengthUnit) -> Self {
        match u {
            LengthUnit::Millimetres => RecipeLengthUnitKind::Millimetres,
            LengthUnit::Centimetres => RecipeLengthUnitKind::Centimetres,
            LengthUnit::Inches => RecipeLengthUnitKind::Inches,
        }
    }
}

impl From<RecipeMeasurementDto> for Measurement {
    fn from(m: RecipeMeasurementDto) -> Self {
        Measurement {
            label: m.label,
            value: m.value,
            unit: m.unit.map(Into::into),
        }
    }
}

impl From<RecipePhaseKind> for Phase {
    fn from(p: RecipePhaseKind) -> Self {
        match p {
            RecipePhaseKind::Start => Phase::Start,
            RecipePhaseKind::Body => Phase::Body,
            RecipePhaseKind::Shaping => Phase::Shaping,
            RecipePhaseKind::Finish => Phase::Finish,
            RecipePhaseKind::Other => Phase::Other,
        }
    }
}

impl From<Phase> for RecipePhaseKind {
    fn from(p: Phase) -> Self {
        match p {
            Phase::Start => RecipePhaseKind::Start,
            Phase::Body => RecipePhaseKind::Body,
            Phase::Shaping => RecipePhaseKind::Shaping,
            Phase::Finish => RecipePhaseKind::Finish,
            Phase::Other => RecipePhaseKind::Other,
        }
    }
}

impl From<SegmentKind> for RecipeKindDto {
    fn from(k: SegmentKind) -> Self {
        match k {
            SegmentKind::FoundationChain => RecipeKindDto::FoundationChain,
            SegmentKind::CentreStart => RecipeKindDto::CentreStart,
            SegmentKind::PickUp => RecipeKindDto::PickUp,
            SegmentKind::Rounds => RecipeKindDto::Rounds,
            SegmentKind::Rows => RecipeKindDto::Rows,
            SegmentKind::Increase => RecipeKindDto::Increase,
            SegmentKind::Decrease => RecipeKindDto::Decrease,
            SegmentKind::ShortRows => RecipeKindDto::ShortRows,
            SegmentKind::Opening => RecipeKindDto::Opening,
            SegmentKind::Join => RecipeKindDto::Join,
            SegmentKind::Finish => RecipeKindDto::Finish,
            SegmentKind::Freeform => RecipeKindDto::Freeform,
        }
    }
}

impl From<RecipeExtentDto> for Extent {
    /// A missing count reads as 0 (which the checks report); a missing measure as an empty one.
    fn from(e: RecipeExtentDto) -> Self {
        match e.kind {
            RecipeExtentKind::Rounds => Extent::Rounds {
                count: e.count.unwrap_or(0),
            },
            RecipeExtentKind::UntilStitches => Extent::UntilStitches {
                count: e.count.unwrap_or(0),
            },
            RecipeExtentKind::Until => Extent::Until {
                measure: e.measure.map(Into::into).unwrap_or(Measurement {
                    label: String::new(),
                    value: None,
                    unit: None,
                }),
            },
        }
    }
}

impl From<RecipeSegmentDto> for Segment {
    fn from(s: RecipeSegmentDto) -> Self {
        let extent = s.extent.map(Extent::from);
        let work = match s.kind {
            RecipeKindDto::FoundationChain => Work::FoundationChain {
                stitches: s.stitches,
                join: s.chain_join.map(|j| match j {
                    RecipeChainJoinKind::Ring => ChainJoin::Ring,
                    RecipeChainJoinKind::Flat => ChainJoin::Flat,
                }),
            },
            RecipeKindDto::CentreStart => Work::CentreStart {
                stitches: s.stitches,
            },
            RecipeKindDto::PickUp => Work::PickUp {
                from: s.reference,
                stitches: s.stitches,
            },
            RecipeKindDto::Rounds => Work::Rounds {
                worked: s.round_join.map(|j| match j {
                    RecipeRoundJoinKind::Spiral => RoundJoin::Spiral,
                    RecipeRoundJoinKind::Joined => RoundJoin::Joined,
                }),
                extent,
            },
            RecipeKindDto::Rows => Work::Rows { extent },
            RecipeKindDto::Increase => Work::Increase {
                per_round: s.per_round,
                method: s.increase_method.map(|m| match m {
                    RecipeIncreaseKind::SameLoopTwice => IncreaseMethod::SameLoopTwice,
                }),
                extent,
            },
            RecipeKindDto::Decrease => Work::Decrease {
                per_round: s.per_round,
                method: s.decrease_method.map(|m| match m {
                    RecipeDecreaseKind::TwoLoopsAtOnce => DecreaseMethod::TwoLoopsAtOnce,
                    RecipeDecreaseKind::SkipALoop => DecreaseMethod::SkipALoop,
                }),
                extent,
            },
            RecipeKindDto::ShortRows => Work::ShortRows { extent },
            RecipeKindDto::Opening => Work::Opening {
                skip: s.skip,
                stitches: s.stitches,
            },
            RecipeKindDto::Join => Work::Join {
                closes: s.reference,
            },
            RecipeKindDto::Finish => Work::Finish {
                method: s.finish_method.map(|m| match m {
                    RecipeFinishKind::CloseTip => FinishMethod::CloseTip,
                    RecipeFinishKind::TaperEdge => FinishMethod::TaperEdge,
                }),
            },
            RecipeKindDto::Freeform => Work::Freeform {
                role: s.role.map_or(Phase::Other, Phase::from),
                text: s.text,
            },
        };
        Segment {
            id: s.id,
            title: s.title,
            work,
            stitch: s.stitch.map(|st| SegmentStitch {
                notation: st.notation,
                name: st.name,
                reading: match st.reading {
                    RecipeReadingKind::Strict => Reading::Strict,
                    RecipeReadingKind::Lenient => Reading::Lenient,
                },
            }),
            target: s.target.map(Into::into),
            notes: s.notes,
            caution: s.caution,
        }
    }
}

impl From<RecipeDto> for Recipe {
    fn from(r: RecipeDto) -> Self {
        Recipe {
            fit: r.fit.into_iter().map(Into::into).collect(),
            segments: r.segments.into_iter().map(Into::into).collect(),
            ..Recipe::default()
        }
    }
}

fn index(i: usize) -> u32 {
    u32::try_from(i).unwrap_or(u32::MAX)
}

impl From<RecipeIssue> for RecipeIssueDto {
    fn from(i: RecipeIssue) -> Self {
        RecipeIssueDto {
            code: i.code.as_str().to_string(),
            severity: match i.severity {
                RecipeSeverity::Info => RecipeSeverityKind::Info,
                RecipeSeverity::Warning => RecipeSeverityKind::Warning,
                RecipeSeverity::Error => RecipeSeverityKind::Error,
            },
            segment: i.segment.map(index),
            segment_id: i.segment_id,
            fit: i.fit.map(index),
            message: i.message,
            text: i.text,
        }
    }
}

impl From<StitchReading> for RecipeStitchReadingDto {
    /// From the engine's summary of its one reading (the notation is not read again here).
    fn from(r: StitchReading) -> Self {
        let reading = match r.reading {
            Reading::Strict => RecipeReadingKind::Strict,
            Reading::Lenient => RecipeReadingKind::Lenient,
        };
        match r.read {
            Some(read) => RecipeStitchReadingDto {
                exact: read.is_exact(),
                connection: ply_nalbind::notation::print(&[], &read.connections),
                notation: r.notation,
                name: r.name,
                reading,
                read: true,
                accepted: read.accepted,
                normalized: read.normalized,
                problems: u32::try_from(read.problems).unwrap_or(u32::MAX),
            },
            None => RecipeStitchReadingDto {
                notation: r.notation,
                name: r.name,
                reading,
                read: false,
                accepted: false,
                exact: false,
                normalized: String::new(),
                connection: String::new(),
                problems: 0,
            },
        }
    }
}

impl From<SegmentReport> for RecipeSegmentReportDto {
    fn from(s: SegmentReport) -> Self {
        let (count_kind, count) = match s.count {
            Count::Known(n) => (RecipeCountKind::Known, Some(n)),
            Count::Unknown => (RecipeCountKind::Unknown, None),
            Count::Refused => (RecipeCountKind::Refused, None),
            Count::NotApplicable => (RecipeCountKind::NotApplicable, None),
        };
        let (stitch_source, stitch) = match s.stitch {
            Some(StitchUse::Project) => (Some(RecipeStitchSourceKind::Project), None),
            Some(StitchUse::Own(r)) => (Some(RecipeStitchSourceKind::Own), Some(r.into())),
            None => (None, None),
        };
        RecipeSegmentReportDto {
            index: index(s.index),
            id: s.id,
            kind: s.kind.into(),
            phase: s.phase.into(),
            part_number: s.part,
            stitch_source,
            stitch,
            count_kind,
            count,
            written: s.written,
            target: s.target,
            checked: s.checked,
        }
    }
}

impl From<RecipeReport> for RecipeReportDto {
    fn from(r: RecipeReport) -> Self {
        RecipeReportDto {
            too_large: r.too_large(),
            segments: r.segments.into_iter().map(Into::into).collect(),
            issues: r.issues.into_iter().map(Into::into).collect(),
            fit: r.fit,
            project_stitch: r.project_stitch.map(Into::into),
        }
    }
}

/// Check `dto` against the project's stitch `project_notation`.
pub(crate) fn check(dto: RecipeDto, project_notation: &str) -> RecipeReportDto {
    recipe::check(&Recipe::from(dto), project_notation).into()
}

/// The schema version a `.plynal` file says it has, read from its two version keys alone (nothing
/// else in the file is built, however large it is): 1 for a legacy file, `None` when it is not a
/// `.plynal` at all; any other version as found (at most `u32::MAX`). Which versions this build
/// opens is the app's (`NalbindProject.currentSchemaVersion`).
pub(crate) fn document_version(text: &str) -> Option<u32> {
    ply_nalbind::native::schema_version(text)
        .ok()
        .map(|v| u32::try_from(v).unwrap_or(u32::MAX))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_version_of_a_project_file_comes_from_its_keys() {
        let mut text = String::from(r#"{"format":"ply.nalbind","schemaVersion":3,"notes":["#);
        while text.len() < 20 * 1024 * 1024 {
            text.push_str("{},");
        }
        text.push_str("{}]}");
        assert_eq!(document_version(&text), Some(3));
        let newer = text.replacen("\"schemaVersion\":3", "\"schemaVersion\":4", 1);
        assert_eq!(document_version(&newer), Some(4));
        let huge = text.replacen("\"schemaVersion\":3", "\"schemaVersion\":9000000000", 1);
        assert_eq!(document_version(&huge), Some(u32::MAX));
        drop((text, newer, huge));
        assert_eq!(document_version(r#"{"name":"Mitten","notes":""}"#), Some(1));
        for not_nalbind in [
            "{nope",
            "[]",
            r#"{"format":"ply.knit","schema_version":6,"document":{}}"#,
            r#"{"format":"ply.nalbind","schemaVersion":0}"#,
            r#"{"format":"ply.nalbind","schemaVersion":"3"}"#,
        ] {
            assert_eq!(document_version(not_nalbind), None, "{not_nalbind}");
        }
    }

    fn segment(id: &str, kind: RecipeKindDto) -> RecipeSegmentDto {
        RecipeSegmentDto {
            id: id.to_string(),
            title: String::new(),
            kind,
            stitch: None,
            stitches: None,
            skip: None,
            chain_join: None,
            round_join: None,
            per_round: None,
            increase_method: None,
            decrease_method: None,
            finish_method: None,
            extent: None,
            reference: None,
            role: None,
            text: String::new(),
            target: None,
            notes: String::new(),
            caution: String::new(),
        }
    }

    #[test]
    fn a_recipe_crosses_and_comes_back_checked() {
        let mut chain = segment("segment-1", RecipeKindDto::FoundationChain);
        chain.stitches = Some(36);
        chain.chain_join = Some(RecipeChainJoinKind::Ring);
        chain.stitch = Some(RecipeStitchDto {
            notation: "uo/uoo f2".into(),
            name: "Oslo".into(),
            reading: RecipeReadingKind::Strict,
        });
        let mut opening = segment("segment-2", RecipeKindDto::Opening);
        opening.skip = Some(7);
        opening.stitches = Some(9);
        let mut finish = segment("segment-3", RecipeKindDto::Finish);
        finish.finish_method = Some(RecipeFinishKind::CloseTip);
        let mut thumb = segment("segment-4", RecipeKindDto::PickUp);
        thumb.reference = Some("segment-2".into());
        thumb.stitches = Some(18);
        let mut rounds = segment("segment-5", RecipeKindDto::Rounds);
        rounds.extent = Some(RecipeExtentDto {
            kind: RecipeExtentKind::Until,
            count: None,
            measure: Some(RecipeMeasurementDto {
                label: "from the pick-up".into(),
                value: Some(5.5),
                unit: Some(RecipeLengthUnitKind::Centimetres),
            }),
        });
        let dto = RecipeDto {
            fit: vec![RecipeMeasurementDto {
                label: "Hand around".into(),
                value: Some(19.0),
                unit: Some(RecipeLengthUnitKind::Centimetres),
            }],
            segments: vec![chain, opening, finish, thumb, rounds],
        };
        let r = check(dto, "UO/UOO F1");
        let codes: Vec<&str> = r.issues.iter().map(|i| i.code.as_str()).collect();
        assert_eq!(codes, ["part-not-finished"]);
        assert_eq!(r.issues[0].segment, Some(4));
        assert_eq!(r.fit, ["Hand around: 19 cm"]);
        let first = &r.segments[0];
        assert_eq!(first.stitch_source, Some(RecipeStitchSourceKind::Own));
        let own = first.stitch.as_ref().unwrap();
        assert_eq!(own.name, "Oslo");
        assert_eq!(own.notation, "uo/uoo f2", "the notation crosses verbatim");
        assert!(own.accepted && own.exact && own.read);
        assert_eq!(own.normalized, "UO/UOO F2");
        assert_eq!(own.connection, "F2");
        let project = r.project_stitch.as_ref().expect("read once");
        assert_eq!(
            (project.notation.as_str(), project.connection.as_str()),
            ("UO/UOO F1", "F1")
        );
        assert!(!r.too_large);
        assert_eq!(
            (first.count_kind, first.count),
            (RecipeCountKind::Known, Some(36))
        );
        assert_eq!(
            r.segments[1].stitch_source,
            Some(RecipeStitchSourceKind::Project)
        );
        assert!(
            r.segments[1].stitch.is_none(),
            "the project's stitch is not copied per step"
        );
        assert_eq!(r.segments[1].count, Some(38));
        assert_eq!(r.segments[2].stitch_source, None);
        assert_eq!(r.segments[3].part_number, Some(2));
        assert_eq!(
            r.segments[4].written,
            "Work in rounds until it measures 5.5 cm (from the pick-up)."
        );
        assert!(r.segments.iter().all(|s| s.checked));
    }

    #[test]
    fn a_free_text_segment_is_not_checked_and_defaults_to_a_note() {
        let mut free = segment("segment-1", RecipeKindDto::Freeform);
        free.text = "Felt lightly.".into();
        let r = check(
            RecipeDto {
                fit: vec![],
                segments: vec![free],
            },
            "",
        );
        assert!(r.issues.is_empty());
        assert!(!r.segments[0].checked);
        assert_eq!(r.segments[0].phase, RecipePhaseKind::Other);
        assert_eq!(r.segments[0].count_kind, RecipeCountKind::NotApplicable);
        assert_eq!(r.segments[0].written, "Felt lightly.");
    }

    #[test]
    fn a_missing_extent_count_reads_as_zero_and_is_reported() {
        let mut start = segment("segment-1", RecipeKindDto::CentreStart);
        start.stitches = Some(6);
        let mut rounds = segment("segment-2", RecipeKindDto::Rounds);
        rounds.extent = Some(RecipeExtentDto {
            kind: RecipeExtentKind::Rounds,
            count: None,
            measure: None,
        });
        let mut finish = segment("segment-3", RecipeKindDto::Finish);
        finish.finish_method = None;
        let r = check(
            RecipeDto {
                fit: vec![],
                segments: vec![start, rounds, finish],
            },
            "UO/UOO F1",
        );
        let codes: Vec<&str> = r.issues.iter().map(|i| i.code.as_str()).collect();
        assert_eq!(codes, ["count-not-positive"]);
    }

    #[test]
    fn a_report_at_the_caps_stays_small() {
        // A thousand steps, each with a notation as wrong as Ply reads and as long as the total
        // text cap allows, and a project stitch as long as Ply reads.
        let per = recipe::MAX_TOTAL_TEXT / recipe::MAX_SEGMENTS - "segment-1000".len();
        let bad = "(".repeat(per.min(recipe::MAX_NOTATION));
        let segments = (0..recipe::MAX_SEGMENTS)
            .map(|i| {
                let mut s = segment(&format!("segment-{i}"), RecipeKindDto::Rounds);
                s.stitch = Some(RecipeStitchDto {
                    notation: bad.clone(),
                    name: String::new(),
                    reading: RecipeReadingKind::Strict,
                });
                s
            })
            .collect();
        let r = check(
            RecipeDto {
                fit: vec![],
                segments,
            },
            &"(".repeat(recipe::MAX_NOTATION),
        );
        assert!(!r.too_large);
        let text: usize = r
            .issues
            .iter()
            .map(|i| i.text.len() + i.message.len())
            .sum::<usize>()
            + r.segments
                .iter()
                .map(|s| {
                    s.written.len()
                        + s.stitch
                            .as_ref()
                            .map_or(0, |st| st.notation.len() + st.normalized.len())
                })
                .sum::<usize>();
        assert!(text < 20_000_000, "{text} bytes of text");
        assert!(r.issues.len() <= recipe::MAX_SEGMENTS * (recipe::MAX_NOTATION_ISSUES + 4));
    }

    #[test]
    fn a_too_large_recipe_says_so_and_where() {
        let mut s = segment("segment-1", RecipeKindDto::Rounds);
        s.notes = "x".repeat(recipe::MAX_TEXT + 1);
        let r = check(
            RecipeDto {
                fit: vec![],
                segments: vec![s],
            },
            "UO/UOO F1",
        );
        assert!(r.too_large);
        assert!(r.segments.is_empty());
        assert_eq!(r.issues[0].segment, Some(0));
        assert_eq!(r.project_stitch, None);
    }
}
