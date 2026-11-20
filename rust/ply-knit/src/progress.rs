//! Working a pattern row by row (roadmap M8-05, ADR 0023): the pattern's WORK UNITS in working
//! order, each with what to knit in a knitter's words, and where a knitter who saved their place
//! resumes.
//!
//! - A chart-only pattern's unit is a chart row, from row 1 at the bottom, with the written
//!   instructions' own line for it ([`crate::to_written`]) and the stitch count after it from the
//!   stitch flow. Such a chart is worked as many times as needed; the tracker counts the times.
//! - A pattern with sections works through the stitch ledger: each LINE (a step, or one chart row of
//!   a chart-rows step) is a unit, with its section heading, label, instruction and count exactly as
//!   the written instructions give them. A line that works several whole rows or rounds (`Work 10
//!   rows`, a shaping step) has a row counter inside it ([`WorkUnit::rows`]).
//!
//! A flat chart with an odd number of rows changes sides every second time through: its row 1 is then
//! worked from the other side, so the plan gives each row's words for that side too
//! ([`WorkUnit::other_side`]).
//!
//! A unit's IDENTITY is everything the knitter is told at it: its kind, its section and step ids, its
//! chart row, its section's heading and notes, its label, instruction and count, how many rows it
//! works and how often it shapes; the pattern's opening lines (the cast-on and the pieces) come before
//! the first unit. A place's fingerprint is the hash of the opening lines and every unit's identity
//! up to and including it. See [`ply_common::progress`] for how a saved place is compared with the
//! pattern as it is now.

use crate::flow::stitch_flow;
use crate::pattern::Side;
use crate::pattern::{Construction, KnitPattern};
use crate::sections::{heading, ledger, pieces_line, StepAction};
use crate::written::{cast_on_line, chart_row_text, color_labels};
use ply_common::progress::{reconcile, Basis, Fingerprint, Resume, ResumeStatus};

/// How a pattern is worked through.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WorkMode {
    /// Chart rows, bottom to top, as many times through as needed.
    Chart,
    /// The sections' ledger lines, start to end, once.
    Sections,
}

/// What a unit is in the pattern.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UnitKind {
    /// A chart row (0-based, bottom row = 0) of a chart-only pattern.
    ChartRow { row: usize },
    /// A ledger line: section and step indices, and the chart row (0-based) for a chart-rows step.
    Line {
        section: usize,
        step: usize,
        chart_row: Option<usize>,
    },
}

/// One unit of work.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkUnit {
    pub kind: UnitKind,
    /// The section's and step's stable ids (sections only).
    pub section_id: Option<String>,
    pub step_id: Option<String>,
    /// `Row 3 (RS)`, `Round 3`, `Next 32 rows (first row RS)`, `Short row 2 (WS)`, or none.
    pub label: Option<String>,
    /// What to knit, as the written instructions give it.
    pub text: String,
    /// The stitch count after the unit, in words (`24 sts`, `stitch count unknown`, or the ledger's
    /// count with its groups and holds).
    pub count: String,
    /// The whole rows or rounds the unit works: 1, or more for a step that works several.
    pub rows: u64,
    /// For a shaping step: it shapes on its first row and then every `every` rows.
    pub every: Option<u32>,
    /// A step in the pattern's own words that Ply does not check.
    pub opaque: bool,
    /// For a chart row worked from the other side on every second time through (a flat chart with an
    /// odd number of rows): its label and stitches as they are worked then.
    pub other_side: Option<(String, String)>,
    /// The prefix fingerprint at this unit (see the module docs).
    pub prefix: u64,
    /// The prefix fingerprint at this unit on a later time through the chart (from the second time
    /// on the whole chart is before every row); the same as `prefix` for a sections line, which is
    /// worked once.
    pub later_prefix: u64,
    /// The fingerprint the first tracker build saved at this unit on any time through (it counted a
    /// chart row's other-side words on the first time too): a place saved with it is recognized
    /// rather than taken for a change.
    pub earlier_prefix: u64,
}

/// A pattern's work, in order.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkPlan {
    pub mode: WorkMode,
    /// The chart is worked in the round (chart mode); sections say it per line.
    pub round: bool,
    /// The cast-on line, when the pattern states one.
    pub cast_on: Option<String>,
    /// Each section's heading line, by section index (sections mode; empty for a chart).
    pub headings: Vec<String>,
    /// Each section's notes line (`Notes: change to the smaller needles`), by section index, as the
    /// written instructions give it; `None` for a section without notes.
    pub section_notes: Vec<Option<String>>,
    /// The pattern's pieces line (`Made in 3 pieces: ...`), when it has pieces.
    pub pieces: Option<String>,
    pub units: Vec<WorkUnit>,
    /// The ledger stopped counting (the construction is too long): the units stop where it did.
    pub stopped: bool,
    /// A sentence to show on a time through the chart whose rows are worked from the other side than
    /// the chart marks them (every second time, for an odd number of rows worked flat).
    pub repeat_note: Option<String>,
}

impl WorkPlan {
    /// True when the `time`-th time through (from 1) works each chart row from the other side.
    pub fn flipped(&self, time: u64) -> bool {
        self.mode == WorkMode::Chart && self.repeat_note.is_some() && time.is_multiple_of(2)
    }
}

fn sts(n: u64) -> String {
    format!("{n} {}", if n == 1 { "st" } else { "sts" })
}

fn opt(fp: &mut Fingerprint, s: Option<&str>) {
    match s {
        Some(s) => {
            fp.number(1);
            fp.text(s);
        }
        None => fp.number(0),
    }
}

/// Feed a unit's identity (everything the knitter is told at it) into `fp`. `other_side`: the time
/// through shows a chart row's other-side words (a later time; the first never does, so its
/// fingerprint leaves them out, as if there were none).
fn feed(fp: &mut Fingerprint, plan: &WorkPlan, u: &WorkUnit, other_side: bool) {
    match u.kind {
        UnitKind::ChartRow { row } => {
            fp.text("chart");
            fp.number(row as u64);
        }
        UnitKind::Line {
            section, chart_row, ..
        } => {
            fp.text("line");
            fp.text(u.section_id.as_deref().unwrap_or(""));
            fp.text(u.step_id.as_deref().unwrap_or(""));
            fp.number(chart_row.map_or(0, |r| r as u64 + 1));
            opt(fp, plan.headings.get(section).map(String::as_str));
            opt(
                fp,
                plan.section_notes.get(section).and_then(|n| n.as_deref()),
            );
        }
    }
    opt(fp, u.label.as_deref());
    fp.text(&u.text);
    fp.text(&u.count);
    fp.number(u.rows);
    fp.number(u.every.map_or(0, |e| 1 + u64::from(e)));
    fp.number(u64::from(u.opaque));
    match &u.other_side {
        Some((label, text)) if other_side => {
            fp.number(1);
            fp.text(label);
            fp.text(text);
        }
        _ => fp.number(0),
    }
}

/// The pattern's work units, in working order, each with its prefix fingerprint.
pub fn work_plan(pattern: &KnitPattern) -> WorkPlan {
    let mut plan = if pattern.sections.is_empty() {
        chart_plan(pattern)
    } else {
        sections_plan(pattern)
    };
    // The opening lines are told before the first unit.
    let mut opening = Fingerprint::new();
    opt(&mut opening, plan.cast_on.as_deref());
    opt(&mut opening, plan.pieces.as_deref());
    let mut fp = opening;
    let mut prefixes = Vec::with_capacity(plan.units.len());
    for u in &plan.units {
        feed(&mut fp, &plan, u, false);
        prefixes.push(fp.value());
    }
    // The other side's words fed for every row, as the first tracker build did on every time
    // through; then, from the second time on, the whole chart (whose number of rows decides the side
    // each row is worked from) is before every row.
    let mut fp = opening;
    let mut earlier = Vec::with_capacity(plan.units.len());
    for u in &plan.units {
        feed(&mut fp, &plan, u, true);
        earlier.push(fp.value());
    }
    let mut later = Vec::with_capacity(plan.units.len());
    if plan.mode == WorkMode::Chart {
        fp.text("then again");
        for u in &plan.units {
            feed(&mut fp, &plan, u, true);
            later.push(fp.value());
        }
    } else {
        later.clone_from(&prefixes);
    }
    for (((u, p), e), l) in plan.units.iter_mut().zip(prefixes).zip(earlier).zip(later) {
        u.prefix = p;
        u.earlier_prefix = e;
        u.later_prefix = l;
    }
    plan
}

fn chart_plan(pattern: &KnitPattern) -> WorkPlan {
    let labels = color_labels(pattern);
    let flow = stitch_flow(pattern);
    let rows = pattern.chart.rows.len();
    let round = pattern.construction == Construction::InTheRound;
    // Worked flat with an odd number of rows, every second time through starts on the other side:
    // the same chart read from that side.
    let flips = !round && rows % 2 == 1;
    let other = flips.then(|| {
        let mut p = pattern.clone();
        p.first_row_side = match pattern.first_row_side {
            Side::Rs => Side::Ws,
            Side::Ws => Side::Rs,
        };
        p
    });
    let units = (0..rows)
        .map(|r| {
            let (label, text) = chart_row_text(pattern, r, labels.as_ref());
            let other_side = other
                .as_ref()
                .map(|p| chart_row_text(p, r, labels.as_ref()));
            let count = flow
                .get(r)
                .and_then(|f| f.count)
                .map_or_else(|| "stitch count unknown".to_string(), |c| sts(c.produced));
            WorkUnit {
                kind: UnitKind::ChartRow { row: r },
                section_id: None,
                step_id: None,
                label: Some(label),
                text,
                count,
                rows: 1,
                every: None,
                opaque: false,
                other_side,
                prefix: 0,
                later_prefix: 0,
                earlier_prefix: 0,
            }
        })
        .collect();
    WorkPlan {
        mode: WorkMode::Chart,
        round,
        cast_on: pattern
            .cast_on
            .map(|n| cast_on_line(pattern.construction, n)),
        headings: Vec::new(),
        section_notes: Vec::new(),
        pieces: pieces_line(pattern),
        units,
        stopped: false,
        repeat_note: flips.then(|| {
            "This chart has an odd number of rows, so this time through each row is worked from \
             the other side than the chart marks it."
                .to_string()
        }),
    }
}

fn sections_plan(pattern: &KnitPattern) -> WorkPlan {
    let led = ledger(pattern);
    let headings = (0..pattern.sections.len())
        .map(|s| heading(pattern, s))
        .collect();
    let units = led
        .lines
        .iter()
        .map(|l| {
            let section = pattern.sections.get(l.section);
            let step = section.and_then(|s| s.steps.get(l.step));
            let every = match step.map(|s| &s.action) {
                Some(StepAction::Shape { every, .. }) if l.rows.is_some() => Some(*every),
                _ => None,
            };
            WorkUnit {
                kind: UnitKind::Line {
                    section: l.section,
                    step: l.step,
                    chart_row: l.chart_row,
                },
                section_id: section.map(|s| s.id.clone()),
                step_id: step.map(|s| s.id.clone()),
                label: l.label.clone(),
                text: l.text.clone(),
                count: l.count.text(),
                rows: l.rows.unwrap_or(1).max(1),
                every,
                opaque: l.opaque,
                other_side: None,
                prefix: 0,
                later_prefix: 0,
                earlier_prefix: 0,
            }
        })
        .collect();
    // The notes line the written instructions give under each heading.
    let section_notes = pattern
        .sections
        .iter()
        .map(|s| {
            let n = s.notes.trim();
            (!n.is_empty()).then(|| format!("Notes: {n}"))
        })
        .collect();
    WorkPlan {
        mode: WorkMode::Sections,
        round: false,
        cast_on: pattern
            .cast_on
            .map(|n| cast_on_line(pattern.construction, n)),
        headings,
        section_notes,
        pieces: pieces_line(pattern),
        units,
        stopped: led.stopped,
        repeat_note: None,
    }
}

/// A saved place, as the progress file holds it.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct SavedPlace {
    /// The unit, from 0.
    pub unit: u64,
    /// The row inside the unit, from 1 (0 reads as 1).
    pub row: u64,
    pub basis: Option<Basis>,
    pub section_id: Option<String>,
    pub step_id: Option<String>,
    /// The chart row of a chart-rows line, from 1.
    pub chart_row: Option<u64>,
    /// The time through the chart, from 1 (0 reads as 1); a sections place is always on the first.
    pub repeat: u64,
}

/// Where a knitter resumes: how their place compares, the unit (from 0) and the row inside it (from
/// 1) to show, and the sentence to show with it (`None` when there is nothing to say).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KnitResume {
    pub resume: Resume,
    pub row: u64,
    pub message: Option<String>,
}

/// Compare a saved place with the pattern's work as it is now. Never moves the place: a place past
/// the end is shown at the last unit, and a step found elsewhere is only suggested.
pub fn resume(plan: &WorkPlan, saved: &SavedPlace) -> KnitResume {
    let n = plan.units.len() as u64;
    let find = || {
        let (Some(sec), Some(step)) = (&saved.section_id, &saved.step_id) else {
            return None;
        };
        plan.units
            .iter()
            .position(|u| {
                let chart_row = match u.kind {
                    UnitKind::Line { chart_row, .. } => chart_row.map(|r| r as u64 + 1),
                    UnitKind::ChartRow { .. } => None,
                };
                u.section_id.as_ref() == Some(sec)
                    && u.step_id.as_ref() == Some(step)
                    && chart_row == saved.chart_row
            })
            .map(|i| i as u64)
    };
    let chart = plan.mode == WorkMode::Chart;
    let time = saved.repeat.max(1);
    let later = chart && time > 1;
    let earlier = |b: &Basis| {
        plan.units
            .get(saved.unit as usize)
            .is_some_and(|u| u.earlier_prefix == b.prefix && u.earlier_prefix != u.prefix)
    };
    // A first-time place the first tracker build saved (it counted words the first time does not
    // show, so its fingerprint covers more): the same work when it matches, so it is taken as this
    // build's own.
    let basis = match saved.basis {
        Some(b) if !later && earlier(&b) => Some(Basis {
            prefix: plan.units[saved.unit as usize].prefix,
            ..b
        }),
        other => other,
    };
    // A later-time place it saved covered only the rows up to it: shown for checking, in its own
    // words.
    let earlier_build = later
        && saved.basis.as_ref().is_some_and(|b| {
            plan.units
                .get(saved.unit as usize)
                .is_some_and(|u| u.earlier_prefix == b.prefix)
        });
    let mut r = reconcile(
        saved.unit,
        basis,
        n,
        |u| {
            let unit = &plan.units[u as usize];
            if later {
                unit.later_prefix
            } else {
                unit.prefix
            }
        },
        find,
    );
    let (one, many) = match (chart, plan.round) {
        (true, true) => ("round", "rounds"),
        (true, false) => ("row", "rows"),
        (false, _) => ("step", "steps"),
    };
    if r.status == ResumeStatus::Empty {
        return KnitResume {
            resume: r,
            row: 1,
            message: Some("This pattern has no rows or steps to knit yet.".to_string()),
        };
    }
    let rows_here = plan.units[r.unit as usize].rows;
    // A row past the step's rows (a step that now works fewer): its last row, for checking.
    let mut row_note = None;
    let mut escalated = false;
    let row = match r.status {
        ResumeStatus::Clamped { .. } => rows_here,
        _ if saved.row > rows_here => {
            row_note = Some(format!(
                "Your place was row {} of this step, but the step now works {rows_here} {}. It is \
                 shown at row {rows_here}: check where you are.",
                saved.row,
                if rows_here == 1 { "row" } else { "rows" }
            ));
            if !r.status.needs_a_look() {
                r.status = ResumeStatus::Changed;
                escalated = true;
            }
            rows_here
        }
        _ => saved.row.max(1),
    };
    let shown = r.unit + 1;
    let message = match r.status {
        ResumeStatus::Same => None,
        ResumeStatus::LengthChanged { .. } => {
            Some("The pattern has changed after your place. Your place is unchanged.".to_string())
        }
        ResumeStatus::Changed if earlier_build => Some(format!(
            "Your place on time {time} through was saved by an earlier version of Ply, which kept \
             too little about the chart to tell whether it has changed. Check that {one} {shown} \
             is where you are."
        )),
        ResumeStatus::Changed if later => Some(format!(
            "The chart has changed since you saved your place, and on time {time} through all of \
             it was knitted before your place. Check that {one} {shown} is where you are."
        )),
        ResumeStatus::Changed if chart => Some(format!(
            "The chart has changed at or before {one} {shown} since you saved your place. Check \
             that {one} {shown} is where you are."
        )),
        ResumeStatus::Changed => {
            let mut m = "The pattern has changed at or before this step since you saved your \
                         place. Check that this is where you are."
                .to_string();
            if r.suggested.is_some() {
                m.push_str(" The step you were on is somewhere else in the pattern now.");
            }
            Some(m)
        }
        ResumeStatus::Clamped { was } if chart => Some(format!(
            "Your place was {one} {}, but the chart now has {n} {}. It is shown at {one} \
             {shown}: check where you are.",
            was + 1,
            if n == 1 { one } else { many }
        )),
        ResumeStatus::Clamped { .. } => Some(
            "Your place was past the end of the pattern as it is now. It is shown at the last \
             step: check where you are."
                .to_string(),
        ),
        ResumeStatus::Empty => None,
    };
    let message = match (message, row_note) {
        (_, Some(n)) if escalated => Some(n),
        (Some(m), Some(n)) => Some(format!("{m} {n}")),
        (m, n) => m.or(n),
    };
    KnitResume {
        resume: r,
        row,
        message,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::builtin;
    use crate::pattern::{Cell, Chart, Row, Side, StitchLegend};
    use crate::sections::{Section, ShapeUntil, Step};

    fn chart(rows: usize, width: usize) -> KnitPattern {
        KnitPattern {
            name: "test".into(),
            construction: Construction::Flat,
            first_row_side: Side::Rs,
            cast_on: Some(width as u32),
            gauge: crate::calc::seed_gauge(ply_common::YarnWeight::Medium),
            palette: vec![ply_common::Color::WHITE],
            legend: StitchLegend::builtin(),
            chart: Chart {
                width,
                rows: (0..rows)
                    .map(|r| {
                        let st = if r % 2 == 0 {
                            builtin::KNIT
                        } else {
                            builtin::PURL
                        };
                        Row::plain(vec![Cell::of(st); width])
                    })
                    .collect(),
            },
            notes: String::new(),
            sections: Vec::new(),
            pieces: Vec::new(),
        }
    }

    fn step(id: &str, action: StepAction) -> Step {
        Step {
            id: id.into(),
            action,
        }
    }

    fn sock_cuff() -> KnitPattern {
        let mut p = chart(2, 4);
        p.cast_on = Some(20);
        p.sections = vec![Section {
            id: "section-1".into(),
            name: "Cuff".into(),
            notes: String::new(),
            construction: None,
            piece: None,
            steps: vec![
                step(
                    "step-1",
                    StepAction::Rows {
                        count: 6,
                        text: "k2, p2 rib".into(),
                    },
                ),
                step(
                    "step-2",
                    StepAction::Shape {
                        change: -2,
                        every: 4,
                        until: ShapeUntil::Times(3),
                        groups: Vec::new(),
                        text: "k1, k2tog, knit to last 3 sts, ssk, k1".into(),
                    },
                ),
                step(
                    "step-3",
                    StepAction::BindOff {
                        count: None,
                        resolve_turns: false,
                    },
                ),
            ],
        }];
        p
    }

    #[test]
    fn a_chart_is_worked_row_by_row_with_its_written_line_and_count() {
        let p = chart(3, 4);
        let plan = work_plan(&p);
        assert_eq!(plan.mode, WorkMode::Chart);
        assert_eq!(plan.units.len(), 3);
        let written = crate::to_written(&p);
        assert_eq!(plan.cast_on.as_deref(), Some(written[0].as_str()));
        for (i, u) in plan.units.iter().enumerate() {
            assert_eq!(
                format!("{}: {}", u.label.as_deref().unwrap(), u.text),
                written[i + 1]
            );
            assert_eq!(u.count, "4 sts");
            assert_eq!(u.rows, 1);
        }
        assert_eq!(plan.units[1].label.as_deref(), Some("Row 2 (WS)"));
        assert!(plan.repeat_note.is_some(), "three rows worked flat");
        assert!(work_plan(&chart(4, 4)).repeat_note.is_none());
    }

    #[test]
    fn sections_are_worked_line_by_line_with_a_row_counter() {
        let p = sock_cuff();
        let plan = work_plan(&p);
        assert_eq!(plan.mode, WorkMode::Sections);
        assert_eq!(plan.headings, vec!["Section 1: Cuff".to_string()]);
        assert_eq!(plan.units.len(), 3);
        assert_eq!(plan.units[0].rows, 6);
        assert_eq!(plan.units[0].every, None);
        assert_eq!(plan.units[1].rows, 12, "3 times every 4 rows");
        assert_eq!(plan.units[1].every, Some(4));
        assert_eq!(plan.units[2].rows, 1);
        assert_eq!(plan.units[1].step_id.as_deref(), Some("step-2"));
        assert_eq!(plan.units[2].count, crate::ledger(&p).lines[2].count.text());
        let written = crate::to_written(&p);
        for u in &plan.units {
            let line = match &u.label {
                Some(l) => format!("{l}: {} ({})", u.text, u.count),
                None => format!("{} ({})", u.text, u.count),
            };
            assert!(written.contains(&line), "{line}");
        }
    }

    #[test]
    fn prefixes_follow_the_work_up_to_each_unit() {
        let p = sock_cuff();
        let plan = work_plan(&p);
        let mut q = p.clone();
        q.sections[0].steps[2] = step(
            "step-3",
            StepAction::Opaque {
                text: "Weave in the ends".into(),
                stitch_change: None,
            },
        );
        let other = work_plan(&q);
        assert_eq!(
            plan.units[1].prefix, other.units[1].prefix,
            "unchanged before"
        );
        assert_ne!(plan.units[2].prefix, other.units[2].prefix, "changed here");
    }

    #[test]
    fn an_odd_chart_worked_flat_gives_each_rows_other_side() {
        let p = chart(3, 4);
        let plan = work_plan(&p);
        assert!(!plan.flipped(1) && plan.flipped(2) && !plan.flipped(3));
        let (label, text) = plan.units[0].other_side.clone().unwrap();
        assert_eq!(plan.units[0].label.as_deref(), Some("Row 1 (RS)"));
        assert_eq!(label, "Row 1 (WS)");
        // The knit row read from the wrong side is purled.
        assert_eq!(plan.units[0].text, "k4");
        assert_eq!(text, "p4");
        assert!(plan.repeat_note.unwrap().contains("this time through"));
        let even = work_plan(&chart(4, 4));
        assert!(even.units.iter().all(|u| u.other_side.is_none()));
        assert!(!even.flipped(2));
        let mut round = chart(3, 4);
        round.construction = Construction::InTheRound;
        assert!(!work_plan(&round).flipped(2));
    }

    #[test]
    fn section_notes_and_the_pieces_line_are_told_as_written() {
        let mut p = sock_cuff();
        p.sections[0].notes = "  Change to the smaller needles. ".into();
        p.pieces = vec![
            crate::sections::Piece {
                id: "piece-1".into(),
                name: "Leg".into(),
            },
            crate::sections::Piece {
                id: "piece-2".into(),
                name: "Foot".into(),
            },
        ];
        let plan = work_plan(&p);
        let written = crate::to_written(&p);
        let notes = plan.section_notes[0].clone().unwrap();
        assert_eq!(notes, "Notes: Change to the smaller needles.");
        assert!(written.contains(&notes));
        let pieces = plan.pieces.clone().unwrap();
        assert!(pieces.starts_with("Made in 2 pieces: Leg and Foot."));
        assert!(written.contains(&pieces));
        assert!(work_plan(&sock_cuff()).section_notes[0].is_none());
    }

    #[test]
    fn everything_the_knitter_is_told_is_in_the_fingerprint() {
        let p = sock_cuff();
        let base = work_plan(&p);
        let changed = |q: &KnitPattern| work_plan(q).units[1].prefix != base.units[1].prefix;
        let mut cast = p.clone();
        cast.cast_on = Some(24);
        assert!(changed(&cast), "the cast-on (and every count after it)");
        let mut notes = p.clone();
        notes.sections[0].notes = "Use the small needle.".into();
        assert!(changed(&notes), "the section's notes");
        let mut name = p.clone();
        name.sections[0].name = "Leg".into();
        assert!(changed(&name), "the section's heading");
        let mut rows = p.clone();
        rows.sections[0].steps[0] = step(
            "step-1",
            StepAction::Rows {
                count: 8,
                text: "k2, p2 rib".into(),
            },
        );
        assert!(changed(&rows), "how many rows");
        // A later step does not count.
        let mut later = p.clone();
        later.sections[0].steps[2] = step(
            "step-3",
            StepAction::Opaque {
                text: "Weave in the ends".into(),
                stitch_change: None,
            },
        );
        assert!(!changed(&later));
    }

    fn saved(plan: &WorkPlan, unit: usize, row: u64) -> SavedPlace {
        let u = &plan.units[unit];
        SavedPlace {
            unit: unit as u64,
            row,
            basis: Some(Basis {
                units: plan.units.len() as u64,
                prefix: u.prefix,
            }),
            section_id: u.section_id.clone(),
            step_id: u.step_id.clone(),
            chart_row: match u.kind {
                UnitKind::Line { chart_row, .. } => chart_row.map(|r| r as u64 + 1),
                UnitKind::ChartRow { .. } => None,
            },
            repeat: 1,
        }
    }

    /// The first time through a flat chart reads every row as drawn, so its fingerprint leaves the
    /// other side's words out: a row added at the end of a chart of 3 is only a length change for a
    /// first-time place. A place the first tracker build saved (its fingerprint counted those words)
    /// is recognized on the first time, and shown for checking in its own words on a later one.
    #[test]
    fn the_first_time_counts_only_what_it_shows() {
        let plan = work_plan(&chart(3, 4));
        let longer = work_plan(&chart(4, 4));
        let at = |prefix: u64, time: u64| SavedPlace {
            repeat: time,
            basis: Some(Basis { units: 3, prefix }),
            ..saved(&plan, 0, 1)
        };
        assert!(matches!(
            resume(&longer, &at(plan.units[0].prefix, 1)).resume.status,
            ResumeStatus::LengthChanged { was: 3 }
        ));
        assert_ne!(plan.units[0].earlier_prefix, plan.units[0].prefix);
        assert_eq!(
            resume(&plan, &at(plan.units[0].earlier_prefix, 1))
                .resume
                .status,
            ResumeStatus::Same,
            "an earlier build's first-time place of the same chart"
        );
        let r = resume(&plan, &at(plan.units[0].earlier_prefix, 2));
        assert_eq!(r.resume.status, ResumeStatus::Changed);
        assert_eq!(
            r.message.unwrap(),
            "Your place on time 2 through was saved by an earlier version of Ply, which kept too \
             little about the chart to tell whether it has changed. Check that row 1 is where you \
             are."
        );
        // A chart in the round has no other side: nothing to tell apart.
        let mut round = chart(3, 4);
        round.construction = Construction::InTheRound;
        let r = work_plan(&round);
        assert_eq!(r.units[0].earlier_prefix, r.units[0].prefix);
    }

    /// The review probe: a flat chart of 3 rows is read from the other side every second time
    /// through, so on time 2 the whole chart is before the place. A row added at the end makes the
    /// count even (every time on the same side) and is caught there; a row added at the end of a
    /// chart worked in the round is only a length change on time 1, a change on time 2.
    #[test]
    fn on_a_later_time_any_edit_to_the_chart_is_before_the_place() {
        let plan = work_plan(&chart(3, 4));
        let at = |time: u64| SavedPlace {
            repeat: time,
            basis: Some(Basis {
                units: 3,
                prefix: if time > 1 {
                    plan.units[0].later_prefix
                } else {
                    plan.units[0].prefix
                },
            }),
            ..saved(&plan, 0, 1)
        };
        assert_eq!(resume(&plan, &at(2)).resume.status, ResumeStatus::Same);
        assert_ne!(plan.units[0].prefix, plan.units[0].later_prefix);
        let longer = work_plan(&chart(4, 4));
        assert!(
            plan.flipped(2) && !longer.flipped(2),
            "the side of row 1 on time 2 changed"
        );
        let r = resume(&longer, &at(2));
        assert_eq!(r.resume.status, ResumeStatus::Changed);
        assert_eq!(r.resume.unit, 0, "never moved");
        assert_eq!(
            r.message.unwrap(),
            "The chart has changed since you saved your place, and on time 2 through all of it \
             was knitted before your place. Check that row 1 is where you are."
        );
        let round = |rows: usize| {
            let mut p = chart(rows, 4);
            p.construction = Construction::InTheRound;
            work_plan(&p)
        };
        let (short, long) = (round(3), round(4));
        let place = |time: u64| SavedPlace {
            repeat: time,
            basis: Some(Basis {
                units: 3,
                prefix: if time > 1 {
                    short.units[0].later_prefix
                } else {
                    short.units[0].prefix
                },
            }),
            ..saved(&short, 0, 1)
        };
        assert!(matches!(
            resume(&long, &place(1)).resume.status,
            ResumeStatus::LengthChanged { .. }
        ));
        assert_eq!(
            resume(&long, &place(2)).resume.status,
            ResumeStatus::Changed
        );
    }

    #[test]
    fn the_same_pattern_resumes_at_the_row_inside_the_step() {
        let plan = work_plan(&sock_cuff());
        let r = resume(&plan, &saved(&plan, 1, 7));
        assert_eq!(r.resume.status, ResumeStatus::Same);
        assert_eq!((r.resume.unit, r.row, r.message), (1, 7, None));
    }

    #[test]
    fn a_step_inserted_before_the_place_is_offered_never_applied() {
        let p = sock_cuff();
        let plan = work_plan(&p);
        let place = saved(&plan, 1, 3);
        let mut q = p.clone();
        q.sections[0].steps.insert(
            0,
            step(
                "step-9",
                StepAction::Opaque {
                    text: "Try it on".into(),
                    stitch_change: Some(0),
                },
            ),
        );
        let now = work_plan(&q);
        let r = resume(&now, &place);
        assert_eq!(r.resume.status, ResumeStatus::Changed);
        assert_eq!(r.resume.unit, 1, "shown at the same number");
        assert_eq!(
            r.resume.suggested,
            Some(2),
            "the step it was on, now one later"
        );
        assert_eq!(r.row, 3);
        assert!(r
            .message
            .unwrap()
            .contains("somewhere else in the pattern now"));
    }

    #[test]
    fn a_shorter_step_shows_its_last_row_for_checking() {
        let p = sock_cuff();
        let plan = work_plan(&p);
        let place = saved(&plan, 0, 6);
        let mut q = p.clone();
        q.sections[0].steps[0] = step(
            "step-1",
            StepAction::Rows {
                count: 4,
                text: "k2, p2 rib".into(),
            },
        );
        let r = resume(&work_plan(&q), &place);
        assert_eq!(r.resume.status, ResumeStatus::Changed);
        assert_eq!(r.row, 4);
        assert!(r
            .message
            .unwrap()
            .contains("It is shown at row 4: check where you are."));
    }

    #[test]
    fn a_shorter_chart_clamps_the_place_and_says_so() {
        let plan = work_plan(&chart(6, 4));
        let place = saved(&plan, 5, 1);
        let r = resume(&work_plan(&chart(4, 4)), &place);
        assert_eq!(r.resume.status, ResumeStatus::Clamped { was: 5 });
        assert_eq!(r.resume.unit, 3);
        assert_eq!(
            r.message.unwrap(),
            "Your place was row 6, but the chart now has 4 rows. It is shown at row 4: check \
             where you are."
        );
    }

    #[test]
    fn a_longer_chart_keeps_the_place() {
        let plan = work_plan(&chart(4, 4));
        let r = resume(&work_plan(&chart(6, 4)), &saved(&plan, 2, 1));
        assert_eq!(r.resume.status, ResumeStatus::LengthChanged { was: 4 });
        assert_eq!(r.resume.unit, 2);
    }

    #[test]
    fn an_empty_pattern_has_nothing_to_knit() {
        let r = resume(&work_plan(&chart(0, 0)), &SavedPlace::default());
        assert_eq!(r.resume.status, ResumeStatus::Empty);
        assert_eq!(
            r.message.unwrap(),
            "This pattern has no rows or steps to knit yet."
        );
    }

    #[test]
    fn a_round_chart_counts_rounds() {
        let mut p = chart(3, 4);
        p.construction = Construction::InTheRound;
        let plan = work_plan(&p);
        assert!(plan.round);
        assert!(
            plan.repeat_note.is_none(),
            "rounds are all worked from the right side"
        );
        assert_eq!(plan.units[0].label.as_deref(), Some("Round 1"));
        let mut short = chart(1, 4);
        short.construction = Construction::InTheRound;
        let r = resume(&work_plan(&short), &saved(&plan, 2, 1));
        assert_eq!(
            r.message.unwrap(),
            "Your place was round 3, but the chart now has 1 round. It is shown at round 1: \
             check where you are."
        );
    }
}
