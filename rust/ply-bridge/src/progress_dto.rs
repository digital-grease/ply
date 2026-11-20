//! Working a pattern unit by unit and resuming a saved place (ADR 0023): the DTOs and the work
//! behind `api::weave_work_window`, `api::weave_resume`, `api::knit_work`, `api::knit_resume`,
//! `api::tablet_work_window`, `api::tablet_resume`, `api::nalbind_work` and `api::nalbind_resume`.
//! Flat enums only (no freezed rebuild). Fingerprints cross as 16 hexadecimal digits, the way the
//! progress file stores them; counts cross as `u32` (saturating).
//!
//! The app owns the progress file (the place, its log, notes and undo); the engines own what a unit
//! is, what to do at it, and whether a saved place still means the same.

use ply_common::progress::{parse_hex, to_hex, Basis, ResumeStatus};
use ply_weave::Draft;

use crate::dto::{ColorDto, DraftDto, PickRoleKind};
use crate::knit_dto::KnitPatternDto;
use crate::nalbind_recipe_dto::RecipeDto;
use crate::tablet_dto::{
    card_pick_out, card_state_out, document, note_kind_out, run_failure, TabletCardPickDto,
    TabletCardStateDto, TabletDocumentDto, TabletNoteKind, TabletRunFailure,
};

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

/// A saved weaving place: the pick and the time through the draft (both from 1), and what it was
/// saved against.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WeavePlaceDto {
    pub pick: u32,
    /// The time through the draft (from 1; 0 reads as 1). From the second time on the whole draft is
    /// before the place, so its fingerprint is that time's (`WeaveWorkPickDto::prefix` of a window
    /// of that time).
    pub repeat: u32,
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
    /// The prefix fingerprint at this pick on the window's time through (one set for the first
    /// time, one for every later time).
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
        place.repeat as usize,
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
    /// The prefix fingerprint at this unit on the first time through.
    pub prefix: String,
    /// The prefix fingerprint at this unit on a later time through a chart (the whole chart is then
    /// before every row); a sections line's is its `prefix`.
    pub later_prefix: String,
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
    /// The time through the chart (from 1; 0 reads as 1); a sections place is on the first.
    pub repeat: u32,
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
                    later_prefix: to_hex(u.later_prefix),
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
        repeat: u64::from(place.repeat),
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

// --- tablet weaving --------------------------------------------------------------------------------

/// A saved tablet weaving place: the pick of the expanded band and the time through the band
/// (both from 1), and what it was saved against.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TabletPlaceDto {
    pub pick: u32,
    /// The time through the band (from 1; 0 reads as 1). From the second time on the whole band is
    /// before the place.
    pub repeat: u32,
    /// The band's picks when the place was saved.
    pub picks: u32,
    /// The prefix fingerprint at the pick (16 hexadecimal digits; anything else reads as none).
    pub prefix: String,
}

/// The pattern's own words for some `?` cards of a pick, in full.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TabletWorkWordsDto {
    /// `card 3`, `cards 3 to 5`.
    pub cards: String,
    pub text: String,
}

/// One pick of the band, as the weaver works it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TabletWorkPickDto {
    /// The pick of the expanded band, from 1.
    pub pick: u32,
    /// Where it is written (from 1): the segment, the written pick, which time through the SEGMENT
    /// (not the band's time through, `TabletWorkDto::time`), and how many times the segment is
    /// worked.
    pub segment: u32,
    pub step: u32,
    pub segment_repeat: u32,
    pub segment_repeats: u32,
    /// What to do, in words (the events before the pick, every card's turn, any note and weft; a
    /// note and the words for a `?` turn quoted in short).
    pub text: String,
    /// No card turns.
    pub all_idle: bool,
    /// The pick's weft, or the band's (a palette index).
    pub weft: Option<u32>,
    /// The pick's note in full, and its kind.
    pub note_kind: Option<TabletNoteKind>,
    pub note_text: Option<String>,
    /// The words for the `?` cards in full, cards with the same words together.
    pub words: Vec<TabletWorkWordsDto>,
    /// The full note and words were left out to keep the window small (a window starting at this
    /// pick holds them).
    pub text_left_out: bool,
    /// The prefix fingerprint at this pick on the window's time through.
    pub prefix: String,
}

/// A window of picks on one time through the band.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TabletWorkDto {
    /// The band's picks.
    pub picks: u32,
    pub cards: u32,
    /// The time through the band the window is for (from 1).
    pub time: u32,
    /// Every card before the window's first pick, as it should be when the weaver comes to it.
    pub before: Vec<TabletCardStateDto>,
    pub steps: Vec<TabletWorkPickDto>,
    /// Every card at each pick, after its events and turn: `cards` cells per pick, pick-major.
    pub cells: Vec<TabletCardPickDto>,
    /// The sentence to show when the cards do not start this time through as they were set up.
    pub start_note: Option<String>,
    /// The tablet rules still await a tablet weaver's review (ADR 0018 section 17).
    pub review_pending: bool,
    /// Opaque work states to give back with later windows of this time through (`from`, best the
    /// latest before the window asked for), by pick: the start of the time through (when this window
    /// had to work it out), 32 picks before the window, the pick before it, and its last pick. Sealed
    /// for this run of the app: keep them in memory only, never save or export one.
    pub states: Vec<TabletWorkStateDto>,
}

/// A work state: every card after pick `done` of a time through (0: at its start), as opaque bytes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TabletWorkStateDto {
    pub done: u32,
    pub bytes: Vec<u8>,
}

pub(crate) fn tablet_window(
    dto: TabletDocumentDto,
    first: u32,
    last: u32,
    time: u32,
    from: Option<Vec<u8>>,
) -> Result<TabletWorkDto, TabletRunFailure> {
    let doc = document(dto)?;
    let band = &doc.band;
    let w = ply_tablet::progress::window(
        band,
        first,
        last,
        time,
        from.as_deref(),
        &ply_tablet::TabletLimits::DEFAULT,
    )
    .map_err(run_failure)?;
    let cards = w.cards.max(1);
    Ok(TabletWorkDto {
        picks: w.picks,
        cards: sat(w.cards as u64),
        time: w.time,
        before: w.before.iter().map(card_state_out).collect(),
        steps: w
            .rows
            .into_iter()
            .map(|r| TabletWorkPickDto {
                pick: r.pick,
                segment: r.segment,
                step: r.step,
                segment_repeat: r.segment_repeat,
                segment_repeats: r.segment_repeats,
                text: r.text,
                all_idle: r.all_idle,
                weft: r.weft,
                note_kind: r.note.as_ref().map(|n| note_kind_out(n.kind)),
                note_text: r.note.map(|n| n.text),
                words: r
                    .words
                    .into_iter()
                    .map(|w| TabletWorkWordsDto {
                        cards: w.cards,
                        text: w.text,
                    })
                    .collect(),
                text_left_out: r.text_left_out,
                prefix: to_hex(r.prefix),
            })
            .collect(),
        cells: w
            .cells
            .iter()
            .enumerate()
            .map(|(i, cp)| card_pick_out(band, i % cards, cp))
            .collect(),
        start_note: w.start_note,
        review_pending: ply_tablet::PRACTITIONER_REVIEW_PENDING,
        states: w
            .states
            .into_iter()
            .map(|s| TabletWorkStateDto {
                done: s.done,
                bytes: s.bytes,
            })
            .collect(),
    })
}

pub(crate) fn tablet_resume(
    dto: TabletDocumentDto,
    place: TabletPlaceDto,
) -> Result<WorkResumeDto, TabletRunFailure> {
    let doc = document(dto)?;
    let r = ply_tablet::progress::resume(
        &doc.band,
        place.pick,
        place.repeat,
        basis(place.picks, &place.prefix),
        &ply_tablet::TabletLimits::DEFAULT,
    )
    .map_err(run_failure)?;
    Ok(WorkResumeDto {
        status: status_kind(r.resume.status),
        unit: r.pick.saturating_sub(1),
        row: 1,
        units: r.picks,
        suggested_unit: r.resume.suggested.map(sat),
        message: r.message,
    })
}

// --- nalbinding ------------------------------------------------------------------------------------

/// One recipe step's id and the prefix fingerprint at it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NalbindWorkStepDto {
    pub id: String,
    pub prefix: String,
}

/// A recipe's steps in working order (at most the engine's 1,000; `stopped` past it).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NalbindWorkDto {
    pub steps: Vec<NalbindWorkStepDto>,
    pub stopped: bool,
}

/// A saved nalbinding place: the step's number when saved (from 0), its id when the place names
/// one, and what it was saved against.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NalbindPlaceDto {
    pub unit: u32,
    pub step_id: Option<String>,
    /// The recipe's steps when the place was saved.
    pub units: u32,
    /// The prefix fingerprint at the step (16 hexadecimal digits; anything else reads as none).
    pub prefix: String,
}

pub(crate) fn nalbind_work(recipe: RecipeDto, notation: &str, name: &str) -> NalbindWorkDto {
    let plan = ply_nalbind::progress::work_plan(
        &ply_nalbind::recipe::Recipe::from(recipe),
        notation,
        name,
    );
    NalbindWorkDto {
        steps: plan
            .steps
            .into_iter()
            .map(|s| NalbindWorkStepDto {
                id: s.id,
                prefix: to_hex(s.prefix),
            })
            .collect(),
        stopped: plan.stopped,
    }
}

pub(crate) fn nalbind_resume(
    recipe: RecipeDto,
    notation: &str,
    name: &str,
    place: NalbindPlaceDto,
) -> WorkResumeDto {
    let plan = ply_nalbind::progress::work_plan(
        &ply_nalbind::recipe::Recipe::from(recipe),
        notation,
        name,
    );
    let r = ply_nalbind::progress::resume(
        &plan,
        &ply_nalbind::progress::SavedPlace {
            unit: u64::from(place.unit),
            step_id: place.step_id,
            basis: basis(place.units, &place.prefix),
        },
    );
    WorkResumeDto {
        status: status_kind(r.resume.status),
        unit: sat(r.resume.unit),
        row: 1,
        units: sat(plan.steps.len() as u64),
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
                repeat: 1,
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
                repeat: 1,
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

    fn band() -> TabletDocumentDto {
        let text = std::fs::read_to_string(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../fixtures/tablet/documents/band-1-threaded-in.plytab"
        ))
        .unwrap();
        crate::tablet_dto::parse(&text).unwrap()
    }

    #[test]
    fn a_tablet_window_and_its_resume_agree_on_the_fingerprint() {
        let w = tablet_window(band(), 1, 100, 1, None).unwrap();
        assert!(w.picks > 2);
        assert_eq!(w.cells.len(), w.steps.len() * w.cards as usize);
        assert_eq!(w.before.len(), w.cards as usize);
        assert!(w.review_pending);
        let second = &w.steps[1];
        assert_eq!(second.prefix.len(), 16);
        assert!(!second.text.is_empty());
        let r = tablet_resume(
            band(),
            TabletPlaceDto {
                pick: 2,
                repeat: 1,
                picks: w.picks,
                prefix: second.prefix.clone(),
            },
        )
        .unwrap();
        assert_eq!(r.status, WorkResumeKind::Same);
        assert_eq!((r.unit, r.row, r.units, r.message), (1, 1, w.picks, None));
        // A later time through: its own fingerprints, its place resumed with them, and a work state
        // that makes the next window the same as one worked out afresh.
        let later = tablet_window(band(), 1, 2, 5, None).unwrap();
        assert_ne!(later.steps[1].prefix, second.prefix);
        assert_eq!(later.time, 5);
        assert_eq!(
            later.states.first().map(|s| s.done),
            Some(0),
            "the start of time 5"
        );
        let r = tablet_resume(
            band(),
            TabletPlaceDto {
                pick: 2,
                repeat: 5,
                picks: w.picks,
                prefix: later.steps[1].prefix.clone(),
            },
        )
        .unwrap();
        assert_eq!(r.status, WorkResumeKind::Same);
        let end = later.states.last().unwrap().bytes.clone();
        let next = tablet_window(band(), 3, 4, 5, Some(end)).unwrap();
        assert!(
            next.states.iter().all(|s| s.done > 0),
            "nothing worked out again"
        );
        assert_eq!(
            next.cells,
            tablet_window(band(), 3, 4, 5, None).unwrap().cells
        );
    }

    #[test]
    fn a_tablet_window_outside_the_band_or_of_a_band_with_errors_is_a_failure() {
        use crate::tablet_dto::TabletRunFailureKind;
        let picks = tablet_window(band(), 1, 1, 1, None).unwrap().picks;
        for (first, time) in [(0, 1), (picks + 1, 1), (1, 0)] {
            let e = tablet_window(band(), first, first, time, None)
                .err()
                .unwrap();
            assert_eq!(
                e.kind,
                TabletRunFailureKind::InvalidWindow,
                "{first} {time}"
            );
        }
        let mut bad = band();
        bad.turning[0].picks[0].turns.push('F');
        let e = tablet_window(bad.clone(), 1, 1, 1, None).err().unwrap();
        assert_eq!(e.kind, TabletRunFailureKind::HasErrors);
        let e = tablet_resume(
            bad,
            TabletPlaceDto {
                pick: 1,
                repeat: 1,
                picks: 1,
                prefix: String::new(),
            },
        )
        .err()
        .unwrap();
        assert_eq!(e.kind, TabletRunFailureKind::HasErrors);
    }

    #[test]
    fn nalbinding_work_and_resume_round_trip() {
        use crate::nalbind_recipe_dto::{RecipeKindDto, RecipeSegmentDto};
        let step = |id: &str, kind: RecipeKindDto| RecipeSegmentDto {
            id: id.into(),
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
        };
        let recipe = || RecipeDto {
            fit: vec![],
            segments: vec![
                step("segment-1", RecipeKindDto::CentreStart),
                step("segment-2", RecipeKindDto::Rounds),
                step("segment-3", RecipeKindDto::Finish),
            ],
        };
        let work = nalbind_work(recipe(), "UO/UOO F1", "Oslo");
        assert_eq!(work.steps.len(), 3);
        assert_eq!(work.steps[1].id, "segment-2");
        assert!(!work.stopped);
        let place = |unit: u32, id: &str| NalbindPlaceDto {
            unit,
            step_id: Some(id.into()),
            units: 3,
            prefix: work.steps[1].prefix.clone(),
        };
        let r = nalbind_resume(recipe(), "UO/UOO F1", "Oslo", place(1, "segment-2"));
        assert_eq!(r.status, WorkResumeKind::Same);
        assert_eq!((r.unit, r.row, r.units), (1, 1, 3));
        // Another stitch for the project: told at the step, so it is checked.
        let r = nalbind_resume(recipe(), "UOO/UUOO F2", "Finnish", place(1, "segment-2"));
        assert_eq!(r.status, WorkResumeKind::Changed);
        let gone = nalbind_resume(recipe(), "", "", place(1, "segment-7"));
        assert_eq!(gone.status, WorkResumeKind::Changed);
        assert!(gone.message.unwrap().contains("no longer in the recipe"));
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
                repeat: 1,
            },
        );
        assert_eq!(r.status, WorkResumeKind::Same);
        assert_eq!((r.unit, r.row, r.units), (1, 1, 3));
    }
}
