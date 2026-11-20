//! Working a recipe step by step (roadmap M8-05, ADR 0023): each step's fingerprint, and where a
//! maker who saved their place resumes.
//!
//! The work unit is one recipe step (a segment, ADR 0017), worked once, start to end. A place names
//! its step by the step's id, which never changes and is never given twice, so a place stays with
//! its step when steps are moved, inserted or deleted around it; the step's number is kept too, for
//! a step that is gone. What to do at a step (its written instruction, stitch, count, target, notes
//! and caution) is the recipe check's ([`crate::recipe::check`]); the maker's Done ticks are a record
//! of the steps worked, which the app shows beside the place and this module never reads or writes.
//!
//! A step's IDENTITY is everything the maker is told at it: its id, its label, its kind and every
//! number and choice of that kind, its stitch (the notation as written, its name and how it is read,
//! or the project's stitch, with its notation and name, for a step worked in it), its target, notes
//! and caution. What the check derives from those (the written line, the count after it, the part)
//! depends only on the step and the steps before it, so it adds nothing. A place's fingerprint is the
//! hash of every step's identity up to and including it. See [`ply_common::progress`] for how a saved
//! place is compared with the recipe as it is now.

use crate::recipe::{
    ChainJoin, DecreaseMethod, Extent, FinishMethod, IncreaseMethod, LengthUnit, Measurement,
    Phase, Reading, Recipe, RoundJoin, Segment, Work, MAX_SEGMENTS,
};
use ply_common::progress::{reconcile, Basis, Fingerprint, Resume, ResumeStatus};

/// One step of work: its id and the prefix fingerprint at it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StepWork {
    pub id: String,
    pub prefix: u64,
}

/// A recipe's steps in working order, at most [`MAX_SEGMENTS`] (a recipe longer than Ply checks
/// stops there, `stopped`).
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct WorkPlan {
    pub steps: Vec<StepWork>,
    pub stopped: bool,
}

fn opt(fp: &mut Fingerprint, v: Option<u32>) {
    fp.number(v.map_or(0, |v| 1 + u64::from(v)));
}

fn measure(fp: &mut Fingerprint, m: Option<&Measurement>) {
    let Some(m) = m else {
        fp.number(0);
        return;
    };
    fp.number(1);
    fp.text(&m.label);
    match m.value {
        // The exact bits: 7 and 7.0 are one value, 7 and 7.000001 are two.
        Some(v) => {
            fp.number(1);
            fp.number(v.to_bits());
        }
        None => fp.number(0),
    }
    fp.number(match m.unit {
        None => 0,
        Some(LengthUnit::Millimetres) => 1,
        Some(LengthUnit::Centimetres) => 2,
        Some(LengthUnit::Inches) => 3,
    });
}

fn extent(fp: &mut Fingerprint, e: Option<&Extent>) {
    match e {
        None => fp.number(0),
        Some(Extent::Rounds { count }) => {
            fp.number(1);
            fp.number(u64::from(*count));
        }
        Some(Extent::UntilStitches { count }) => {
            fp.number(2);
            fp.number(u64::from(*count));
        }
        Some(Extent::Until { measure: m }) => {
            fp.number(3);
            measure(fp, Some(m));
        }
    }
}

fn id_ref(fp: &mut Fingerprint, id: Option<&String>) {
    match id {
        None => fp.number(0),
        Some(id) => {
            fp.number(1);
            fp.text(id);
        }
    }
}

/// A step's kind and every number and choice of it.
fn work(fp: &mut Fingerprint, w: &Work) {
    match w {
        Work::FoundationChain { stitches, join } => {
            fp.number(1);
            opt(fp, *stitches);
            fp.number(match join {
                None => 0,
                Some(ChainJoin::Ring) => 1,
                Some(ChainJoin::Flat) => 2,
            });
        }
        Work::CentreStart { stitches } => {
            fp.number(2);
            opt(fp, *stitches);
        }
        Work::PickUp { from, stitches } => {
            fp.number(3);
            id_ref(fp, from.as_ref());
            opt(fp, *stitches);
        }
        Work::Rounds { worked, extent: e } => {
            fp.number(4);
            fp.number(match worked {
                None => 0,
                Some(RoundJoin::Spiral) => 1,
                Some(RoundJoin::Joined) => 2,
            });
            extent(fp, e.as_ref());
        }
        Work::Rows { extent: e } => {
            fp.number(5);
            extent(fp, e.as_ref());
        }
        Work::Increase {
            per_round,
            method,
            extent: e,
        } => {
            fp.number(6);
            opt(fp, *per_round);
            fp.number(match method {
                None => 0,
                Some(IncreaseMethod::SameLoopTwice) => 1,
            });
            extent(fp, e.as_ref());
        }
        Work::Decrease {
            per_round,
            method,
            extent: e,
        } => {
            fp.number(7);
            opt(fp, *per_round);
            fp.number(match method {
                None => 0,
                Some(DecreaseMethod::TwoLoopsAtOnce) => 1,
                Some(DecreaseMethod::SkipALoop) => 2,
            });
            extent(fp, e.as_ref());
        }
        Work::ShortRows { extent: e } => {
            fp.number(8);
            extent(fp, e.as_ref());
        }
        Work::Opening { skip, stitches } => {
            fp.number(9);
            opt(fp, *skip);
            opt(fp, *stitches);
        }
        Work::Join { closes } => {
            fp.number(10);
            id_ref(fp, closes.as_ref());
        }
        Work::Finish { method } => {
            fp.number(11);
            fp.number(match method {
                None => 0,
                Some(FinishMethod::CloseTip) => 1,
                Some(FinishMethod::TaperEdge) => 2,
            });
        }
        Work::Freeform { role, text } => {
            fp.number(12);
            fp.number(match role {
                Phase::Start => 1,
                Phase::Body => 2,
                Phase::Shaping => 3,
                Phase::Finish => 4,
                Phase::Other => 5,
            });
            fp.text(text);
        }
    }
}

/// Feed the identity of one step into `fp` (see the module docs).
fn feed(fp: &mut Fingerprint, s: &Segment, project_notation: &str, project_name: &str) {
    fp.text(&s.id);
    fp.text(&s.title);
    work(fp, &s.work);
    match &s.stitch {
        Some(st) => {
            fp.number(1);
            fp.text(&st.notation);
            fp.text(&st.name);
            fp.number(match st.reading {
                Reading::Strict => 0,
                Reading::Lenient => 1,
            });
        }
        // Worked in the project's stitch: the maker is told that stitch.
        None if s.work.kind().uses_stitch() => {
            fp.number(2);
            fp.text(project_notation);
            fp.text(project_name);
        }
        None => fp.number(0),
    }
    measure(fp, s.target.as_ref());
    fp.text(&s.notes);
    fp.text(&s.caution);
}

/// The steps of `recipe` in working order with their fingerprints. `project_notation` and
/// `project_name` are the project's stitch, which a step without its own is worked in.
pub fn work_plan(recipe: &Recipe, project_notation: &str, project_name: &str) -> WorkPlan {
    let mut fp = Fingerprint::new();
    let steps = recipe
        .segments
        .iter()
        .take(MAX_SEGMENTS)
        .map(|s| {
            feed(&mut fp, s, project_notation, project_name);
            StepWork {
                id: s.id.clone(),
                prefix: fp.value(),
            }
        })
        .collect();
    WorkPlan {
        steps,
        stopped: recipe.segments.len() > MAX_SEGMENTS,
    }
}

/// A saved place: the step's id when the place names one, its number (from 0) when it was saved,
/// and what it was saved against.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SavedPlace {
    pub unit: u64,
    pub step_id: Option<String>,
    pub basis: Option<Basis>,
}

/// Where a maker resumes: how their saved place compares (`resume.unit` is the step to show, from
/// 0), and the sentence to show with it (`None` when there is nothing to say).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StepResume {
    pub resume: Resume,
    pub message: Option<String>,
}

fn steps(n: u64) -> String {
    if n == 1 {
        "1 step".to_string()
    } else {
        format!("{n} steps")
    }
}

/// Compare a saved place with the recipe as it is now. The place is the step its id names, wherever
/// that step is now; a step that is gone is shown at the place's old number (or the last step) for
/// checking. Never moves a place on its own: see [`ply_common::progress::reconcile`].
pub fn resume(plan: &WorkPlan, saved: &SavedPlace) -> StepResume {
    let n = plan.steps.len() as u64;
    let by_id = saved.step_id.as_ref().map(|id| {
        plan.steps
            .iter()
            .position(|s| &s.id == id)
            .map(|i| i as u64)
    });
    let prefix_now = |u: u64| plan.steps[u as usize].prefix;
    let (r, message) = match by_id {
        // The step is still in the recipe: its place is that step, wherever it is now.
        Some(Some(unit)) => {
            let r = reconcile(unit, saved.basis, n, prefix_now, || None);
            let shown = r.unit + 1;
            let was = saved.unit.saturating_add(1);
            let message = match r.status {
                ResumeStatus::Same => None,
                ResumeStatus::LengthChanged { was } => Some(format!(
                    "The recipe has changed after your place: it now has {} (it had {was}). Your \
                     place is unchanged.",
                    steps(n)
                )),
                _ if was != shown => Some(format!(
                    "The recipe has changed since you saved your place: the step you were on is \
                     now step {shown} (it was step {was}). Check that it is where you are."
                )),
                _ => Some(format!(
                    "The recipe has changed at or before step {shown} since you saved your place. \
                     Check that step {shown} is where you are."
                )),
            };
            (r, message)
        }
        // The step is gone: shown at its old number, for checking.
        Some(None) => {
            let r = reconcile(saved.unit, None, n, prefix_now, || None);
            let message = match r.status {
                ResumeStatus::Empty => None,
                _ => Some(format!(
                    "The step you were on is no longer in the recipe. Your place is shown at step \
                     {}: check where you are.",
                    r.unit + 1
                )),
            };
            (r, message)
        }
        // A place without an id rests on its number.
        None => {
            let r = reconcile(saved.unit, saved.basis, n, prefix_now, || None);
            let shown = r.unit + 1;
            let message = match r.status {
                ResumeStatus::Same => None,
                ResumeStatus::LengthChanged { was } => Some(format!(
                    "The recipe has changed after your place: it now has {} (it had {was}). Your \
                     place is unchanged.",
                    steps(n)
                )),
                ResumeStatus::Clamped { was } => Some(format!(
                    "Your place was step {}, but the recipe now has {}. It is shown at step \
                     {shown}: check where you are.",
                    was + 1,
                    steps(n)
                )),
                _ => Some(format!(
                    "The recipe has changed at or before step {shown} since you saved your place. \
                     Check that step {shown} is where you are."
                )),
            };
            (r, message)
        }
    };
    let message = if r.status == ResumeStatus::Empty {
        Some("This recipe has no steps to work.".to_string())
    } else {
        message
    };
    StepResume { resume: r, message }
}

#[cfg(test)]
mod tests;
