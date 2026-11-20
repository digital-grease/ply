//! Property tests of working a recipe step by step (ADR 0023, `ply_nalbind::progress`). Over
//! generated recipes:
//!
//! * a step's fingerprint changes exactly when it or a step before it changes: an edit at step `i`
//!   changes every prefix from `i` on and none before it, and a step added at the end changes none;
//! * a saved place resumes on its step by id wherever the step is moved, and is never moved without
//!   being shown for checking;
//! * resume never panics and always shows a step of the recipe.
//!
//! Run: `cargo test -p ply-nalbind --test progress_proptest`

use ply_common::progress::Basis;
use ply_nalbind::progress::{resume, work_plan, SavedPlace};
use ply_nalbind::recipe::{Extent, Recipe, RoundJoin, Segment, Work};
use proptest::prelude::*;

fn arb_work() -> impl Strategy<Value = Work> {
    prop_oneof![
        (prop::option::of(1u32..50)).prop_map(|stitches| Work::CentreStart { stitches }),
        (prop::option::of(1u32..30)).prop_map(|n| Work::Rounds {
            worked: Some(RoundJoin::Spiral),
            extent: n.map(|count| Extent::Rounds { count }),
        }),
        (prop::option::of(1u32..9), prop::option::of(1u32..9))
            .prop_map(|(skip, stitches)| Work::Opening { skip, stitches }),
        Just(Work::Finish { method: None }),
    ]
}

fn arb_recipe() -> impl Strategy<Value = Recipe> {
    prop::collection::vec((arb_work(), "[a-z ]{0,6}", "[a-z]{0,4}"), 1..8).prop_map(|steps| {
        Recipe {
            segments: steps
                .into_iter()
                .enumerate()
                .map(|(i, (work, title, notes))| Segment {
                    id: format!("segment-{}", i + 1),
                    title,
                    work,
                    stitch: None,
                    target: None,
                    notes,
                    caution: String::new(),
                })
                .collect(),
            last_segment_number: 8,
            ..Recipe::default()
        }
    })
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(256))]

    #[test]
    fn a_fingerprint_changes_exactly_from_the_step_a_change_reaches(
        recipe in arb_recipe(),
        at in 0usize..8,
        caution in "[A-Z]{1,5}",
    ) {
        let i = at % recipe.segments.len();
        let mut edited = recipe.clone();
        edited.segments[i].caution = caution;
        let (a, b) = (work_plan(&recipe, "UO/UOO F1", ""), work_plan(&edited, "UO/UOO F1", ""));
        for k in 0..a.steps.len() {
            if k < i {
                prop_assert_eq!(a.steps[k].prefix, b.steps[k].prefix);
            } else {
                prop_assert_ne!(a.steps[k].prefix, b.steps[k].prefix);
            }
        }
        let mut longer = recipe.clone();
        longer.segments.push(Segment { id: "segment-99".into(), ..recipe.segments[0].clone() });
        let l = work_plan(&longer, "UO/UOO F1", "");
        for k in 0..a.steps.len() {
            prop_assert_eq!(a.steps[k].prefix, l.steps[k].prefix);
        }
    }

    #[test]
    fn a_place_stays_on_its_step_and_is_checked_whenever_it_moved(
        recipe in arb_recipe(),
        at in 0usize..8,
        to in 0usize..8,
    ) {
        let i = at % recipe.segments.len();
        let plan = work_plan(&recipe, "", "");
        let saved = SavedPlace {
            unit: i as u64,
            step_id: Some(plan.steps[i].id.clone()),
            basis: Some(Basis { units: plan.steps.len() as u64, prefix: plan.steps[i].prefix }),
        };
        let mut moved = recipe.clone();
        let s = moved.segments.remove(i);
        let j = to % recipe.segments.len();
        moved.segments.insert(j, s);
        let r = resume(&work_plan(&moved, "", ""), &saved);
        prop_assert_eq!(r.resume.unit, j as u64, "the step, by its id");
        if moved != recipe {
            let first_change = recipe
                .segments
                .iter()
                .zip(&moved.segments)
                .position(|(a, b)| a != b)
                .unwrap();
            prop_assert_eq!(r.resume.status.needs_a_look(), first_change <= j);
        }
    }

    #[test]
    fn resume_never_panics(
        recipe in arb_recipe(),
        unit in 0u64..20,
        id in prop::option::of("segment-[0-9]{1,2}"),
        units in 0u64..20,
        prefix in any::<u64>(),
        truncate in 0usize..8,
    ) {
        let mut r = recipe;
        r.segments.truncate(truncate);
        let plan = work_plan(&r, "", "");
        let out = resume(&plan, &SavedPlace { unit, step_id: id, basis: Some(Basis { units, prefix }) });
        prop_assert!(out.message.is_some() || !out.resume.status.needs_a_look());
        if plan.steps.is_empty() {
            prop_assert_eq!(out.resume.unit, 0);
        } else {
            prop_assert!((out.resume.unit as usize) < plan.steps.len());
        }
    }
}
