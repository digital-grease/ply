//! The written form of a recipe: one plain instruction per segment, from its structured fields only
//! (the maker's notes and cautions are printed beside it, verbatim), and measurements as written.

use std::collections::HashMap;

use super::check::{count_of, extent_of, shorten};
use super::{
    ChainJoin, DecreaseMethod, Extent, FinishMethod, IncreaseMethod, Measurement, Recipe,
    RoundJoin, Work,
};

/// A number as a person writes it: `20`, `12.5`.
pub(super) fn number(v: f64) -> String {
    format!("{v}")
}

/// A measurement's length (`18 cm`, or just `18` when it has no unit), if it has a value.
pub(super) fn length(m: &Measurement) -> Option<String> {
    let v = m.value?;
    Some(match m.unit {
        Some(u) => format!("{} {}", number(v), u.symbol()),
        None => number(v),
    })
}

/// A measurement as written: `Hand around the knuckles: 20 cm`, `20 cm`, or `... not measured yet`.
pub(super) fn measurement(m: &Measurement) -> String {
    let label = m.label.trim();
    let len = match (m.value, m.unit) {
        (Some(_), None) => length(m).map(|l| format!("{l} (no unit)")),
        _ => length(m),
    };
    match (label.is_empty(), len) {
        (false, Some(l)) => format!("{label}: {l}"),
        (false, None) => format!("{label}: not measured yet"),
        (true, Some(l)) => l,
        (true, None) => "Not measured yet".to_string(),
    }
}

/// `step 4 (Thumb opening)`, with the title shortened.
pub(super) fn step_ref(recipe: &Recipe, i: usize) -> String {
    let title = recipe.segments[i].title.trim();
    if title.is_empty() {
        format!("step {}", i + 1)
    } else {
        format!("step {} ({})", i + 1, shorten(title))
    }
}

/// The earlier opening `id` names, as seen from segment `i`, if it is one.
fn opening(
    recipe: &Recipe,
    i: usize,
    id: &Option<String>,
    ids: &HashMap<&str, usize>,
) -> Option<usize> {
    let t = *ids.get(id.as_deref()?)?;
    (t < i && matches!(recipe.segments[t].work, Work::Opening { .. })).then_some(t)
}

/// How far a step goes, as the end of a sentence (`for 8 rounds`, `until 8 stitches remain`,
/// `until it measures 7 cm (from the cuff edge)`).
fn extent_phrase(extent: &Extent, rows: bool, decrease: bool) -> String {
    match extent {
        Extent::Rounds { count } => {
            let (one, many) = if rows {
                ("row", "rows")
            } else {
                ("round", "rounds")
            };
            format!("for {}", count_of(u64::from(*count), one, many))
        }
        Extent::UntilStitches { count } if decrease => format!(
            "until {} {}",
            count_of(u64::from(*count), "stitch", "stitches"),
            if *count == 1 { "remains" } else { "remain" }
        ),
        Extent::UntilStitches { count } => format!(
            "until there are {}",
            count_of(u64::from(*count), "stitch", "stitches")
        ),
        Extent::Until { measure } => {
            let label = measure.label.trim();
            match (length(measure), label.is_empty()) {
                (Some(l), true) => format!("until it measures {l}"),
                (Some(l), false) => format!("until it measures {l} ({label})"),
                (None, false) => format!("until {label}"),
                (None, true) => "until a point the recipe does not state".to_string(),
            }
        }
    }
}

/// The instruction for segment `i`.
pub(super) fn segment(recipe: &Recipe, i: usize, ids: &HashMap<&str, usize>) -> String {
    let s = &recipe.segments[i];
    let stitches = |n: u32| count_of(u64::from(n), "stitch", "stitches");
    let loops = |n: u32| count_of(u64::from(n), "loop", "loops");
    match &s.work {
        Work::FoundationChain { stitches: n, join } => {
            let base = match n {
                Some(n) => format!("Make a foundation chain of {}", stitches(*n)),
                None => "Make a foundation chain".to_string(),
            };
            let join = match join {
                Some(ChainJoin::Ring) => " and join it into a ring",
                Some(ChainJoin::Flat) => " and leave it open to work in rows",
                None => "",
            };
            format!("{base}{join}.")
        }
        Work::CentreStart { stitches: n } => match n {
            Some(n) => format!("Start in the round at the centre with {}.", stitches(*n)),
            None => "Start in the round at the centre.".to_string(),
        },
        Work::PickUp { from, stitches: n } => {
            let origin = match (from, opening(recipe, i, from, ids)) {
                (_, Some(t)) => format!("around the opening in {}", step_ref(recipe, t)),
                (Some(_), None) => "around an opening".to_string(),
                (None, None) => "from earlier work".to_string(),
            };
            match n {
                Some(n) => format!("Pick up {} {origin} to start this part.", loops(*n)),
                None => format!("Pick up loops {origin} to start this part."),
            }
        }
        Work::Rounds { worked, .. } => {
            let base = match worked {
                Some(RoundJoin::Spiral) => "Work in a spiral",
                Some(RoundJoin::Joined) => "Work in joined rounds",
                None => "Work in rounds",
            };
            sentence(base, None, extent_of(&s.work), false, false)
        }
        Work::Rows { .. } => sentence(
            "Work back and forth in rows",
            None,
            extent_of(&s.work),
            true,
            false,
        ),
        Work::Increase {
            per_round, method, ..
        } => {
            let base = match per_round {
                Some(p) => format!("Increase {} in each round", stitches(*p)),
                None => "Increase".to_string(),
            };
            let method = method.map(|m| match m {
                IncreaseMethod::SameLoopTwice => {
                    "working two stitches into the same loop of the previous round"
                }
            });
            sentence(&base, method, extent_of(&s.work), false, false)
        }
        Work::Decrease {
            per_round, method, ..
        } => {
            let base = match per_round {
                Some(p) => format!("Decrease {} in each round", stitches(*p)),
                None => "Decrease".to_string(),
            };
            let method = method.map(|m| match m {
                DecreaseMethod::TwoLoopsAtOnce => {
                    "connecting through two loops of the previous round at once"
                }
                DecreaseMethod::SkipALoop => "skipping a loop of the previous round",
            });
            sentence(&base, method, extent_of(&s.work), false, true)
        }
        Work::ShortRows { extent } => match extent {
            Some(Extent::Rounds { count }) => format!(
                "Work {} back and forth over part of the round.",
                count_of(u64::from(*count), "short row", "short rows")
            ),
            other => sentence(
                "Work short rows back and forth over part of the round",
                None,
                other.as_ref(),
                true,
                false,
            ),
        },
        Work::Opening { skip, stitches: n } => match (skip, n) {
            (Some(k), Some(n)) => format!(
                "Leave an opening: skip {} of the previous round and work {} across the gap \
                 without connecting them.",
                loops(*k),
                stitches(*n)
            ),
            (Some(k), None) => {
                format!(
                    "Leave an opening: skip {} of the previous round.",
                    loops(*k)
                )
            }
            (None, Some(n)) => format!(
                "Leave an opening: work {} across the gap without connecting them to the \
                 previous round.",
                stitches(*n)
            ),
            (None, None) => "Leave an opening.".to_string(),
        },
        Work::Join { closes } => match (closes, opening(recipe, i, closes, ids)) {
            (_, Some(t)) => format!(
                "Join the edges of the opening in {} to close it.",
                step_ref(recipe, t)
            ),
            (Some(_), None) => "Join the edges of an opening to close it.".to_string(),
            (None, None) => "Join.".to_string(),
        },
        Work::Finish { method } => match method {
            Some(FinishMethod::CloseTip) => {
                "Finish by drawing the last loops together to close the tip.".to_string()
            }
            Some(FinishMethod::TaperEdge) => {
                "Finish at the open edge, tapering the last stitches to smooth the step."
                    .to_string()
            }
            None => "Finish.".to_string(),
        },
        Work::Freeform { text, .. } => text.clone(),
    }
}

/// `base[, method][ extent].`, with a comma before the extent when a method sits between them.
fn sentence(
    base: &str,
    method: Option<&str>,
    extent: Option<&Extent>,
    rows: bool,
    decrease: bool,
) -> String {
    let ext = extent.map(|e| extent_phrase(e, rows, decrease));
    match (method, ext) {
        (Some(m), Some(e)) => format!("{base}, {m}, {e}."),
        (Some(m), None) => format!("{base}, {m}."),
        (None, Some(e)) => format!("{base} {e}."),
        (None, None) => format!("{base}."),
    }
}
