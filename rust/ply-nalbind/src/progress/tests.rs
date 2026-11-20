//! Unit tests of working a recipe step by step: fingerprints and where a saved place resumes.

use super::*;
use crate::recipe::{SegmentStitch, MAX_SEGMENTS};

fn seg(id: &str, work: Work) -> Segment {
    Segment {
        id: id.to_string(),
        title: String::new(),
        work,
        stitch: None,
        target: None,
        notes: String::new(),
        caution: String::new(),
    }
}

fn rounds(n: u32) -> Work {
    Work::Rounds {
        worked: Some(RoundJoin::Spiral),
        extent: Some(Extent::Rounds { count: n }),
    }
}

/// A mitten in four steps: a ring chain, rounds, a decrease, a closed tip.
fn mitten() -> Recipe {
    Recipe {
        segments: vec![
            seg(
                "segment-1",
                Work::FoundationChain {
                    stitches: Some(40),
                    join: Some(ChainJoin::Ring),
                },
            ),
            seg("segment-2", rounds(12)),
            seg(
                "segment-3",
                Work::Decrease {
                    per_round: Some(4),
                    method: Some(DecreaseMethod::TwoLoopsAtOnce),
                    extent: Some(Extent::UntilStitches { count: 8 }),
                },
            ),
            seg(
                "segment-4",
                Work::Finish {
                    method: Some(FinishMethod::CloseTip),
                },
            ),
        ],
        last_segment_number: 4,
        ..Recipe::default()
    }
}

const OSLO: &str = "UO/UOO F1";

fn plan(r: &Recipe) -> WorkPlan {
    work_plan(r, OSLO, "Oslo")
}

fn saved(plan: &WorkPlan, unit: usize) -> SavedPlace {
    SavedPlace {
        unit: unit as u64,
        step_id: Some(plan.steps[unit].id.clone()),
        basis: Some(Basis {
            units: plan.steps.len() as u64,
            prefix: plan.steps[unit].prefix,
        }),
    }
}

#[test]
fn every_step_has_its_id_and_a_prefix_of_its_own() {
    let p = plan(&mitten());
    assert_eq!(
        p.steps.iter().map(|s| s.id.as_str()).collect::<Vec<_>>(),
        ["segment-1", "segment-2", "segment-3", "segment-4"]
    );
    let all: std::collections::HashSet<u64> = p.steps.iter().map(|s| s.prefix).collect();
    assert_eq!(all.len(), 4);
    assert!(!p.stopped);
    assert_eq!(plan(&Recipe::default()), WorkPlan::default());
}

#[test]
fn everything_the_maker_is_told_is_in_the_fingerprint() {
    let base = plan(&mitten()).steps[2].prefix;
    let at = |r: &Recipe| plan(r).steps[2].prefix;
    let changed = |f: &dyn Fn(&mut Recipe), what: &str| {
        let mut r = mitten();
        f(&mut r);
        assert_ne!(at(&r), base, "{what}");
    };
    let same = |f: &dyn Fn(&mut Recipe), what: &str| {
        let mut r = mitten();
        f(&mut r);
        assert_eq!(at(&r), base, "{what}");
    };
    changed(
        &|r| r.segments[1].title = "Hand".into(),
        "a label before the place",
    );
    changed(&|r| r.segments[2].work = rounds(3), "the kind at the place");
    changed(
        &|r| r.segments[1].work = rounds(13),
        "a count before the place",
    );
    changed(
        &|r| {
            r.segments[2].work = Work::Decrease {
                per_round: Some(4),
                method: Some(DecreaseMethod::SkipALoop),
                extent: Some(Extent::UntilStitches { count: 8 }),
            }
        },
        "a method",
    );
    changed(
        &|r| {
            r.segments[0].work = Work::FoundationChain {
                stitches: Some(40),
                join: Some(ChainJoin::Flat),
            }
        },
        "a choice",
    );
    changed(&|r| r.segments[2].notes = "Evenly spaced.".into(), "notes");
    changed(
        &|r| r.segments[2].caution = "Count twice.".into(),
        "a caution",
    );
    changed(
        &|r| {
            r.segments[2].target = Some(Measurement {
                label: "Tip".into(),
                value: Some(2.5),
                unit: Some(LengthUnit::Centimetres),
            })
        },
        "a target",
    );
    changed(
        &|r| {
            r.segments[1].stitch = Some(SegmentStitch {
                notation: "UOO/UUOO F2".into(),
                name: "Finnish".into(),
                reading: Reading::Strict,
            })
        },
        "a step's own stitch",
    );
    changed(
        &|r| r.segments[1].id = "segment-9".into(),
        "another step in its place",
    );
    changed(
        &|r| r.segments.swap(0, 1),
        "steps reordered before the place",
    );
    changed(
        &|r| r.segments.insert(1, seg("segment-5", rounds(1))),
        "a step inserted before",
    );
    // The project's stitch, which every step but the finish is worked in.
    assert_ne!(
        work_plan(&mitten(), "UO/UOO F2", "Oslo").steps[2].prefix,
        base,
        "the project's stitch"
    );
    assert_ne!(
        work_plan(&mitten(), OSLO, "Oslo stitch").steps[2].prefix,
        base,
        "the project's stitch name"
    );
    // What is after the place, or never told, does not count.
    same(
        &|r| r.segments[3].notes = "Weave in the end.".into(),
        "a later step",
    );
    same(
        &|r| r.segments.push(seg("segment-5", rounds(1))),
        "a step added after",
    );
    same(&|r| r.done = vec!["segment-1".into()], "a Done tick");
    same(&|r| r.last_segment_number = 99, "the id counter");
    same(
        &|r| {
            r.fit.push(Measurement {
                label: "Hand".into(),
                value: Some(20.0),
                unit: Some(LengthUnit::Centimetres),
            })
        },
        "the fit",
    );
    // A step not worked in a stitch is not told the project's stitch.
    let fin = |n: &str| {
        let r = Recipe {
            segments: vec![seg("segment-1", Work::Finish { method: None })],
            ..Recipe::default()
        };
        work_plan(&r, n, "").steps[0].prefix
    };
    assert_eq!(fin(OSLO), fin("UO/UOO F2"));
}

#[test]
fn resuming_the_same_recipe_needs_nothing() {
    let p = plan(&mitten());
    let r = resume(&p, &saved(&p, 2));
    assert_eq!(r.resume.status, ResumeStatus::Same);
    assert_eq!((r.resume.unit, r.message), (2, None));
}

#[test]
fn steps_added_after_the_place_are_said_but_change_nothing() {
    let p = plan(&mitten());
    let mut longer = mitten();
    longer.segments.push(seg("segment-5", rounds(2)));
    let r = resume(&plan(&longer), &saved(&p, 2));
    assert_eq!(r.resume.status, ResumeStatus::LengthChanged { was: 4 });
    assert_eq!(r.resume.unit, 2);
    assert_eq!(
        r.message.unwrap(),
        "The recipe has changed after your place: it now has 5 steps (it had 4). Your place is \
         unchanged."
    );
}

#[test]
fn a_step_inserted_before_the_place_keeps_the_place_on_its_step_for_checking() {
    let p = plan(&mitten());
    let mut edited = mitten();
    edited.segments.insert(0, seg("segment-5", rounds(1)));
    let r = resume(&plan(&edited), &saved(&p, 2));
    assert_eq!(r.resume.status, ResumeStatus::Changed);
    assert_eq!(r.resume.unit, 3, "the same step, by its id");
    assert_eq!(
        r.message.unwrap(),
        "The recipe has changed since you saved your place: the step you were on is now step 4 \
         (it was step 3). Check that it is where you are."
    );
    // An edit before the place without moving it: the same number, for checking.
    let mut notes = mitten();
    notes.segments[0].notes = "Loose.".into();
    let r = resume(&plan(&notes), &saved(&p, 2));
    assert_eq!(r.resume.status, ResumeStatus::Changed);
    assert_eq!(r.resume.unit, 2);
    assert_eq!(
        r.message.unwrap(),
        "The recipe has changed at or before step 3 since you saved your place. Check that step 3 \
         is where you are."
    );
}

#[test]
fn a_step_that_is_gone_is_shown_at_its_number_for_checking() {
    let p = plan(&mitten());
    let mut edited = mitten();
    edited.segments.remove(2);
    let r = resume(&plan(&edited), &saved(&p, 2));
    assert_eq!(r.resume.status, ResumeStatus::Changed);
    assert_eq!(r.resume.unit, 2);
    assert_eq!(
        r.message.unwrap(),
        "The step you were on is no longer in the recipe. Your place is shown at step 3: check \
         where you are."
    );
    // The last step gone: shown at the last step there is.
    let mut shorter = mitten();
    shorter.segments.truncate(2);
    let r = resume(&plan(&shorter), &saved(&p, 3));
    assert!(r.resume.status.needs_a_look());
    assert_eq!(r.resume.unit, 1);
    assert!(r.message.unwrap().contains("shown at step 2"));
}

#[test]
fn a_place_without_an_id_rests_on_its_number() {
    let p = plan(&mitten());
    let mut s = saved(&p, 1);
    s.step_id = None;
    assert_eq!(resume(&p, &s).resume.status, ResumeStatus::Same);
    s.unit = 9;
    let r = resume(&p, &s);
    assert_eq!(r.resume.status, ResumeStatus::Clamped { was: 9 });
    assert_eq!(r.resume.unit, 3);
    assert_eq!(
        r.message.unwrap(),
        "Your place was step 10, but the recipe now has 4 steps. It is shown at step 4: check \
         where you are."
    );
    s.basis = None;
    s.unit = 0;
    assert_eq!(resume(&p, &s).resume.status, ResumeStatus::Changed);
}

#[test]
fn a_recipe_with_no_steps_has_nothing_to_work() {
    let empty = plan(&Recipe::default());
    for step_id in [None, Some("segment-1".to_string())] {
        let r = resume(
            &empty,
            &SavedPlace {
                unit: 3,
                step_id,
                basis: None,
            },
        );
        assert_eq!(r.resume.status, ResumeStatus::Empty);
        assert_eq!(r.message.unwrap(), "This recipe has no steps to work.");
    }
}

#[test]
fn a_recipe_past_the_step_limit_stops_there() {
    let r = Recipe {
        segments: (0..MAX_SEGMENTS + 3)
            .map(|i| seg(&format!("segment-{i}"), rounds(1)))
            .collect(),
        ..Recipe::default()
    };
    let p = plan(&r);
    assert_eq!(p.steps.len(), MAX_SEGMENTS);
    assert!(p.stopped);
    // A place on a step past the limit is shown at the last step tracked.
    let s = SavedPlace {
        unit: (MAX_SEGMENTS + 1) as u64,
        step_id: Some(format!("segment-{}", MAX_SEGMENTS + 1)),
        basis: None,
    };
    assert_eq!(resume(&p, &s).resume.unit, (MAX_SEGMENTS - 1) as u64);
}

#[test]
fn a_length_is_told_to_its_exact_value() {
    let with = |v: f64| {
        let mut r = mitten();
        r.segments[1].work = Work::Rounds {
            worked: None,
            extent: Some(Extent::Until {
                measure: Measurement {
                    label: "Thumb".into(),
                    value: Some(v),
                    unit: Some(LengthUnit::Centimetres),
                },
            }),
        };
        plan(&r).steps[1].prefix
    };
    assert_eq!(with(7.0), with(7.0));
    assert_ne!(with(7.0), with(7.5));
}
