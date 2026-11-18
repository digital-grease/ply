//! Working a pattern unit by unit and resuming a saved place (ADR 0023): the DTOs and the work
//! behind `api::weave_work_window`, `api::weave_resume`, `api::knit_work` and `api::knit_resume`.
//! Flat enums only (no freezed rebuild). Fingerprints cross as 16 hexadecimal digits, the way the
//! progress file stores them; counts cross as `u32` (saturating).
//!
//! The app owns the progress file (the place, its log, notes and undo); the engines own what a unit
//! is, what to do at it, and whether a saved place still means the same.

use ply_common::progress::{parse_hex, to_hex, Basis, ResumeStatus};
use ply_weave::Draft;

use crate::dto::{ColorDto, DraftDto, PickRoleKind};
use crate::knit_dto::KnitPatternDto;

fn sat(v: u64) -> u32 {
    u32::try_from(v).unwrap_or(u32::MAX)
}

/// How a saved place compares with the pattern as it is now (mirrors
/// `ply_common::progress::ResumeStatus`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WorkResumeKind {
    /// Resume at the place.
    Same,
    /// The pattern changed after the place; the place is unchanged.
    LengthChanged,
    /// Something at or before the place changed: shown at the same unit, to check.
    Changed,
    /// The place is past the end now: shown at the last unit, to check.
    Clamped,
    /// Nothing to work.
    Empty,
}

/// Where to resume.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkResumeDto {
    pub status: WorkResumeKind,
    /// The unit to show, from 0 (weaving: the pick minus 1).
    pub unit: u32,
    /// The row inside the unit to show, from 1 (always 1 for weaving).
    pub row: u32,
    /// How many units the pattern has now.
    pub units: u32,
    /// Only when the place needs a look: a unit (from 0) where the saved unit is found now, to offer.
    pub suggested_unit: Option<u32>,
    /// The sentence to show with it, when there is something to say.
    pub message: Option<String>,
}

fn status_kind(s: ResumeStatus) -> WorkResumeKind {
    match s {
        ResumeStatus::Same => WorkResumeKind::Same,
        ResumeStatus::LengthChanged { .. } => WorkResumeKind::LengthChanged,
        ResumeStatus::Changed => WorkResumeKind::Changed,
        ResumeStatus::Clamped { .. } => WorkResumeKind::Clamped,
        ResumeStatus::Empty => WorkResumeKind::Empty,
    }
}

/// The basis a place was saved against; an unreadable fingerprint is no basis (the place is then
/// shown for checking).
fn basis(units: u32, prefix: &str) -> Option<Basis> {
    parse_hex(prefix).map(|prefix| Basis {
        units: u64::from(units),
        prefix,
    })
}

// --- weaving ---------------------------------------------------------------------------------------

/// A saved weaving place: the pick (from 1) and what it was saved against.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WeavePlaceDto {
    pub pick: u32,
    /// The draft's picks when the place was saved.
    pub picks: u32,
    /// The prefix fingerprint at the pick (16 hexadecimal digits; anything else reads as none).
    pub prefix: String,
}

/// One pick, as the weaver works it. (No derives: `ColorDto` has none.)
pub struct WeaveWorkPickDto {
    /// The pick, from 1.
    pub pick: u32,
    /// The treadles pressed (empty for a lift plan).
    pub treadles: Vec<u16>,
    /// The shafts up.
    pub raised: Vec<u16>,
    /// What to press or lift, as one sentence.
    pub action: String,
    /// The weft colour's palette index, and the colour when the palette has it.
    pub weft_index: Option<u32>,
    pub weft: Option<ColorDto>,
    pub role: PickRoleKind,
    /// The working notes in words (role, shuttle and side, strands, shot group, same shed).
    pub notes: Vec<String>,
    /// The prefix fingerprint at this pick.
    pub prefix: String,
}

/// A window of picks.
pub struct WeaveWorkDto {
    /// The draft's picks.
    pub picks: u32,
    /// The draft is treadled (else a lift plan).
    pub treadled: bool,
    pub steps: Vec<WeaveWorkPickDto>,
}

pub(crate) fn weave_window(
    dto: DraftDto,
    first: u32,
    last: u32,
    time: u32,
) -> Result<WeaveWorkDto, String> {
    let draft = Draft::try_from(dto)?;
    let steps = ply_weave::progress::window(&draft, first as usize, last as usize, time as usize)
        .map_err(|e| e.to_string())?;
    Ok(WeaveWorkDto {
        picks: sat(draft.picks() as u64),
        treadled: matches!(draft.drive, ply_weave::Drive::Treadled { .. }),
        steps: steps
            .into_iter()
            .map(|p| WeaveWorkPickDto {
                pick: sat(p.pick as u64),
                treadles: p.treadles,
                raised: p.raised,
                action: p.action,
                weft_index: p.weft_index.map(|i| sat(i as u64)),
                weft: p.weft.map(|c| ColorDto {
                    r: c.r,
                    g: c.g,
                    b: c.b,
                }),
                role: p.role.into(),
                notes: p.notes,
                prefix: to_hex(p.prefix),
            })
            .collect(),
    })
}

pub(crate) fn weave_resume(dto: DraftDto, place: WeavePlaceDto) -> Result<WorkResumeDto, String> {
    let draft = Draft::try_from(dto)?;
    let r = ply_weave::progress::resume(
        &draft,
        place.pick as usize,
        basis(place.picks, &place.prefix),
    );
    Ok(WorkResumeDto {
        status: status_kind(r.resume.status),
        unit: sat(r.pick as u64 - 1),
        row: 1,
        units: sat(draft.picks() as u64),
        suggested_unit: r.resume.suggested.map(sat),
        message: r.message,
    })
}

// --- knitting --------------------------------------------------------------------------------------

/// How a knitting pattern is worked through (mirrors `ply_knit::progress::WorkMode`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KnitWorkModeKind {
    /// Chart rows, bottom to top, as many times through as needed.
    Chart,
    /// The sections' steps, start to end.
    Sections,
}

/// One unit of knitting work.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KnitWorkUnitDto {
    /// The section and step (indices, from 0) of a ledger line; `None` for a chart row.
    pub section: Option<u32>,
    pub step: Option<u32>,
    /// The chart row, from 1: of a chart-only pattern's unit, or of a chart-rows step's line.
    pub chart_row: Option<u32>,
    pub section_id: Option<String>,
    pub step_id: Option<String>,
    /// `Row 3 (RS)`, `Next 32 rows (first row RS)`, or none.
    pub label: Option<String>,
    /// What to knit.
    pub text: String,
    /// The stitch count after it, in words.
    pub count: String,
    /// The whole rows or rounds it works (1, or more for a step that works several).
    pub rows: u32,
    /// A shaping step: it shapes on its first row and then every `every` rows.
    pub every: Option<u32>,
    /// In the pattern's own words; Ply does not check it.
    pub opaque: bool,
    /// For a chart row worked from the other side every second time through (a flat chart with an
    /// odd number of rows): its label and stitches as they are worked then.
    pub other_label: Option<String>,
    pub other_text: Option<String>,
    /// The prefix fingerprint at this unit.
    pub prefix: String,
}

/// A knitting pattern's work, in order.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KnitWorkDto {
    pub mode: KnitWorkModeKind,
    /// The chart is worked in the round (chart mode).
    pub round: bool,
    pub cast_on: Option<String>,
    /// Each section's heading, by section index.
    pub headings: Vec<String>,
    /// Each section's notes line (`Notes: ...`), by section index; `None` without notes.
    pub section_notes: Vec<Option<String>>,
    /// The pieces line (`Made in 3 pieces: ...`), when the pattern has pieces.
    pub pieces: Option<String>,
    pub units: Vec<KnitWorkUnitDto>,
    /// The construction is too long to count: the units stop where the ledger stopped.
    pub stopped: bool,
    /// The sentence to show on a time through whose rows are worked from the other side than the
    /// chart marks them (every even time, when the chart has `other_label`s).
    pub repeat_note: Option<String>,
}

/// A saved knitting place: the unit (from 0), the row inside it (from 1) and what it was saved
/// against.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KnitPlaceDto {
    pub unit: u32,
    pub row: u32,
    /// The pattern's units when the place was saved.
    pub units: u32,
    /// The prefix fingerprint at the unit (16 hexadecimal digits; anything else reads as none).
    pub prefix: String,
    pub section_id: Option<String>,
    pub step_id: Option<String>,
    /// The chart row of a chart-rows line, from 1.
    pub chart_row: Option<u32>,
}

pub(crate) fn knit_work(dto: KnitPatternDto) -> KnitWorkDto {
    use ply_knit::progress::{UnitKind, WorkMode};
    let plan = ply_knit::progress::work_plan(&ply_knit::KnitPattern::from(dto));
    KnitWorkDto {
        mode: match plan.mode {
            WorkMode::Chart => KnitWorkModeKind::Chart,
            WorkMode::Sections => KnitWorkModeKind::Sections,
        },
        round: plan.round,
        cast_on: plan.cast_on,
        headings: plan.headings,
        section_notes: plan.section_notes,
        pieces: plan.pieces,
        stopped: plan.stopped,
        repeat_note: plan.repeat_note,
        units: plan
            .units
            .into_iter()
            .map(|u| {
                let (section, step, chart_row) = match u.kind {
                    UnitKind::ChartRow { row } => (None, None, Some(sat(row as u64 + 1))),
                    UnitKind::Line {
                        section,
                        step,
                        chart_row,
                    } => (
                        Some(sat(section as u64)),
                        Some(sat(step as u64)),
                        chart_row.map(|r| sat(r as u64 + 1)),
                    ),
                };
                KnitWorkUnitDto {
                    section,
                    step,
                    chart_row,
                    section_id: u.section_id,
                    step_id: u.step_id,
                    label: u.label,
                    text: u.text,
                    count: u.count,
                    rows: sat(u.rows),
                    every: u.every,
                    opaque: u.opaque,
                    other_label: u.other_side.as_ref().map(|(l, _)| l.clone()),
                    other_text: u.other_side.map(|(_, t)| t),
                    prefix: to_hex(u.prefix),
                }
            })
            .collect(),
    }
}

pub(crate) fn knit_resume(dto: KnitPatternDto, place: KnitPlaceDto) -> WorkResumeDto {
    let plan = ply_knit::progress::work_plan(&ply_knit::KnitPattern::from(dto));
    let saved = ply_knit::progress::SavedPlace {
        unit: u64::from(place.unit),
        row: u64::from(place.row),
        basis: basis(place.units, &place.prefix),
        section_id: place.section_id,
        step_id: place.step_id,
        chart_row: place.chart_row.map(u64::from),
    };
    let r = ply_knit::progress::resume(&plan, &saved);
    WorkResumeDto {
        status: status_kind(r.resume.status),
        unit: sat(r.resume.unit),
        row: sat(r.row),
        units: sat(plan.units.len() as u64),
        suggested_unit: r.resume.suggested.map(sat),
        message: r.message,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn twill() -> DraftDto {
        DraftDto::from(&ply_weave::structure::plain_weave(4, 6))
    }

    #[test]
    fn a_window_and_its_resume_agree_on_the_fingerprint() {
        let w = weave_window(twill(), 1, 100, 1).unwrap();
        assert_eq!(w.picks, 6);
        assert_eq!(w.steps.len(), 6);
        assert!(w.treadled);
        let third = &w.steps[2];
        assert_eq!(third.prefix.len(), 16);
        let r = weave_resume(
            twill(),
            WeavePlaceDto {
                pick: 3,
                picks: 6,
                prefix: third.prefix.clone(),
            },
        )
        .unwrap();
        assert_eq!(r.status, WorkResumeKind::Same);
        assert_eq!((r.unit, r.row, r.units, r.message), (2, 1, 6, None));
    }

    #[test]
    fn a_place_without_a_readable_fingerprint_is_shown_for_checking() {
        let r = weave_resume(
            twill(),
            WeavePlaceDto {
                pick: 2,
                picks: 6,
                prefix: "not a fingerprint".into(),
            },
        )
        .unwrap();
        assert_eq!(r.status, WorkResumeKind::Changed);
        assert_eq!(r.unit, 1);
    }

    #[test]
    fn a_window_outside_the_draft_is_an_error() {
        assert!(weave_window(twill(), 7, 9, 1).is_err());
        assert!(weave_window(twill(), 0, 2, 1).is_err());
    }

    #[test]
    fn knitting_work_and_resume_round_trip() {
        let pattern = || {
            let mut p = ply_knit::KnitPattern::from(crate::api::knit_blank_pattern());
            p.chart = ply_knit::Chart {
                width: 2,
                rows: vec![
                    ply_knit::Row::plain(vec![
                        ply_knit::Cell::of(ply_knit::builtin::KNIT);
                        2
                    ]);
                    3
                ],
            };
            KnitPatternDto::from(&p)
        };
        let work = knit_work(pattern());
        assert_eq!(work.mode, KnitWorkModeKind::Chart);
        assert_eq!(work.units.len(), 3);
        assert_eq!(work.units[1].chart_row, Some(2));
        let r = knit_resume(
            pattern(),
            KnitPlaceDto {
                unit: 1,
                row: 1,
                units: 3,
                prefix: work.units[1].prefix.clone(),
                section_id: None,
                step_id: None,
                chart_row: None,
            },
        );
        assert_eq!(r.status, WorkResumeKind::Same);
        assert_eq!((r.unit, r.row, r.units), (1, 1, 3));
    }
}
