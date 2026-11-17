//! Property-based hardening of the nalbinding recipe checks (ADR 0017). Over generated recipes:
//!
//! * `check` never panics, is deterministic, and reports exactly one segment report per segment, in
//!   order, with every issue placed at a segment that exists (and its id);
//! * a known count never passes the cap, and a step outside a part is never counted;
//! * an increase or decrease of `p` a round for `r` rounds from a known `n` gives exactly `n + p*r`
//!   (within the cap) or `n - p*r`, and a decrease of more than `n` is always refused with
//!   `decrease-too-many`, leaving the next step counted from `n`;
//! * a free-text note (role other) changes no count;
//! * the JSON form round-trips.
//!
//! Run: `cargo test -p ply-nalbind --test recipe_proptest`

use ply_nalbind::recipe::{
    check, ChainJoin, Count, DecreaseMethod, Extent, FinishMethod, IncreaseMethod, LengthUnit,
    Measurement, Phase, Reading, Recipe, RoundJoin, Segment, SegmentStitch, Work, MAX_STITCHES,
};
use proptest::prelude::*;

fn arb_count() -> impl Strategy<Value = Option<u32>> {
    prop_oneof![
        Just(None),
        (0u32..60).prop_map(Some),
        Just(Some(MAX_STITCHES)),
        Just(Some(u32::MAX)),
    ]
}

fn arb_measure() -> impl Strategy<Value = Measurement> {
    (
        prop_oneof![Just(String::new()), "[a-z ]{1,12}"],
        prop_oneof![
            Just(None),
            // Typed decimals, as the app's fields produce them.
            (-50i32..400).prop_map(|t| Some(f64::from(t) / 10.0)),
            Just(Some(0.0)),
            Just(Some(f64::NAN)),
        ],
        prop_oneof![
            Just(None),
            Just(Some(LengthUnit::Millimetres)),
            Just(Some(LengthUnit::Centimetres)),
            Just(Some(LengthUnit::Inches)),
        ],
    )
        .prop_map(|(label, value, unit)| Measurement { label, value, unit })
}

fn arb_extent() -> impl Strategy<Value = Option<Extent>> {
    prop_oneof![
        Just(None),
        (0u32..30).prop_map(|count| Some(Extent::Rounds { count })),
        (0u32..80).prop_map(|count| Some(Extent::UntilStitches { count })),
        arb_measure().prop_map(|measure| Some(Extent::Until { measure })),
    ]
}

fn arb_ref() -> impl Strategy<Value = Option<String>> {
    prop_oneof![
        Just(None),
        (0usize..12).prop_map(|n| Some(format!("segment-{n}"))),
        Just(Some(String::new())),
    ]
}

fn arb_phase() -> impl Strategy<Value = Phase> {
    prop_oneof![
        Just(Phase::Start),
        Just(Phase::Body),
        Just(Phase::Shaping),
        Just(Phase::Finish),
        Just(Phase::Other),
    ]
}

fn arb_work() -> impl Strategy<Value = Work> {
    prop_oneof![
        (
            arb_count(),
            prop_oneof![
                Just(None),
                Just(Some(ChainJoin::Ring)),
                Just(Some(ChainJoin::Flat))
            ]
        )
            .prop_map(|(stitches, join)| Work::FoundationChain { stitches, join }),
        arb_count().prop_map(|stitches| Work::CentreStart { stitches }),
        (arb_ref(), arb_count()).prop_map(|(from, stitches)| Work::PickUp { from, stitches }),
        (
            prop_oneof![
                Just(None),
                Just(Some(RoundJoin::Spiral)),
                Just(Some(RoundJoin::Joined))
            ],
            arb_extent()
        )
            .prop_map(|(worked, extent)| Work::Rounds { worked, extent }),
        arb_extent().prop_map(|extent| Work::Rows { extent }),
        (arb_count(), arb_extent()).prop_map(|(per_round, extent)| Work::Increase {
            per_round,
            method: Some(IncreaseMethod::SameLoopTwice),
            extent,
        }),
        (arb_count(), arb_extent()).prop_map(|(per_round, extent)| Work::Decrease {
            per_round,
            method: Some(DecreaseMethod::SkipALoop),
            extent,
        }),
        arb_extent().prop_map(|extent| Work::ShortRows { extent }),
        (arb_count(), arb_count()).prop_map(|(skip, stitches)| Work::Opening { skip, stitches }),
        arb_ref().prop_map(|closes| Work::Join { closes }),
        prop_oneof![
            Just(None),
            Just(Some(FinishMethod::CloseTip)),
            Just(Some(FinishMethod::TaperEdge))
        ]
        .prop_map(|method| Work::Finish { method }),
        (arb_phase(), "[a-z ]{0,10}").prop_map(|(role, text)| Work::Freeform { role, text }),
    ]
}

fn arb_stitch() -> impl Strategy<Value = Option<SegmentStitch>> {
    prop_oneof![
        Just(None),
        (
            prop_oneof![
                Just("UO/UOO F1".to_string()),
                Just("UO/UOO".to_string()),
                Just("UO/UOO F1+1".to_string()),
                Just(String::new()),
                "[UOFB/:() 0-9x]{0,10}",
            ],
            prop_oneof![Just(Reading::Strict), Just(Reading::Lenient)],
        )
            .prop_map(|(notation, reading)| Some(SegmentStitch {
                notation,
                name: String::new(),
                reading,
            })),
    ]
}

fn arb_segment() -> impl Strategy<Value = Segment> {
    (
        prop_oneof![
            (0usize..12).prop_map(|n| format!("segment-{n}")),
            Just(String::new())
        ],
        "[A-Za-z ]{0,8}",
        arb_work(),
        arb_stitch(),
        prop_oneof![Just(None), arb_measure().prop_map(Some)],
    )
        .prop_map(|(id, title, work, stitch, target)| Segment {
            id,
            title,
            work,
            stitch,
            target,
            notes: String::new(),
            caution: String::new(),
        })
}

fn arb_recipe() -> impl Strategy<Value = Recipe> {
    (
        prop::collection::vec(arb_measure(), 0..3),
        prop::collection::vec(arb_segment(), 0..14),
    )
        .prop_map(|(fit, segments)| Recipe {
            fit,
            segments,
            ..Recipe::default()
        })
}

fn arb_project_notation() -> impl Strategy<Value = String> {
    prop_oneof![
        Just(String::new()),
        Just("UO/UOO F1".to_string()),
        Just("UO/UOO".to_string()),
        Just("UO/XYZ".to_string()),
    ]
}

fn plain(id: &str, work: Work) -> Segment {
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

proptest! {
    #![proptest_config(ProptestConfig::with_cases(400))]

    #[test]
    fn check_is_total_and_well_placed(recipe in arb_recipe(), notation in arb_project_notation()) {
        let report = check(&recipe, &notation);
        prop_assert_eq!(&report, &check(&recipe, &notation), "deterministic");
        prop_assert_eq!(report.segments.len(), recipe.segments.len());
        prop_assert_eq!(report.fit.len(), recipe.fit.len());
        for (i, s) in report.segments.iter().enumerate() {
            prop_assert_eq!(s.index, i);
            prop_assert_eq!(&s.id, &recipe.segments[i].id);
            if let Count::Known(n) = s.count {
                prop_assert!(n <= MAX_STITCHES, "segment {} counts {}", i, n);
            }
            if s.part.is_none() {
                prop_assert_eq!(s.count, Count::NotApplicable, "segment {} is outside a part", i);
            }
            if let Some(ply_nalbind::recipe::StitchUse::Own(st)) = &s.stitch {
                let own = recipe.segments[i].stitch.as_ref().expect("an own stitch was given");
                prop_assert_eq!(&st.notation, &own.notation, "kept verbatim");
            }
        }
        for issue in &report.issues {
            if let Some(s) = issue.segment {
                prop_assert!(s < recipe.segments.len());
                prop_assert_eq!(issue.segment_id.as_deref(), Some(recipe.segments[s].id.as_str()));
                prop_assert!(issue.text.ends_with(&issue.message));
            }
            if let Some(f) = issue.fit {
                prop_assert!(f < recipe.fit.len());
            }
        }
    }

    #[test]
    fn shaping_arithmetic_is_exact_and_impossible_decreases_are_refused(
        n in 1u32..200, p in 1u32..20, r in 1u32..20, increase in any::<bool>()
    ) {
        let shaping = if increase {
            Work::Increase { per_round: Some(p), method: None, extent: Some(Extent::Rounds { count: r }) }
        } else {
            Work::Decrease { per_round: Some(p), method: None, extent: Some(Extent::Rounds { count: r }) }
        };
        let recipe = Recipe {
            fit: vec![],
            segments: vec![
                plain("segment-1", Work::CentreStart { stitches: Some(n) }),
                plain("segment-2", shaping),
                plain("segment-3", Work::Rounds { worked: None, extent: Some(Extent::Rounds { count: 1 }) }),
                plain("segment-4", Work::Finish { method: None }),
            ],
            ..Recipe::default()
        };
        let report = check(&recipe, "UO/UOO F1");
        let change = p * r;
        if increase {
            prop_assert_eq!(report.segments[1].count, Count::Known(n + change));
            prop_assert!(report.issues.is_empty());
        } else if change >= n {
            // Removing every stitch, or more, cannot be worked.
            prop_assert_eq!(report.segments[1].count, Count::Refused);
            prop_assert_eq!(report.issues.len(), 1);
            prop_assert_eq!(report.issues[0].code.as_str(), "decrease-too-many");
            prop_assert_eq!(report.segments[2].count, Count::Known(n), "not applied");
        } else {
            prop_assert_eq!(report.segments[1].count, Count::Known(n - change));
            prop_assert!(report.issues.is_empty());
        }
    }

    #[test]
    fn a_note_changes_no_count(recipe in arb_recipe(), at in 0usize..15) {
        let at = at.min(recipe.segments.len());
        let before = check(&recipe, "UO/UOO F1");
        let mut noted = recipe.clone();
        noted.segments.insert(at, plain("note", Work::Freeform { role: Phase::Other, text: "A note.".into() }));
        let after = check(&noted, "UO/UOO F1");
        let counts_before: Vec<Count> = before.segments.iter().map(|s| s.count).collect();
        let mut counts_after: Vec<Count> = after.segments.iter().map(|s| s.count).collect();
        prop_assert_eq!(counts_after.remove(at), Count::NotApplicable);
        prop_assert_eq!(counts_before, counts_after);
    }

    #[test]
    fn the_json_form_round_trips(recipe in arb_recipe()) {
        // NaN is not JSON; the app never writes it (a typed value is always finite).
        let mut recipe = recipe;
        let finite = |m: &mut Measurement| if m.value.is_some_and(|v| !v.is_finite()) { m.value = None };
        recipe.fit.iter_mut().for_each(finite);
        for s in &mut recipe.segments {
            if let Some(t) = &mut s.target { finite(t); }
            match &mut s.work {
                Work::Rounds { extent: Some(Extent::Until { measure }), .. }
                | Work::Rows { extent: Some(Extent::Until { measure }) }
                | Work::Increase { extent: Some(Extent::Until { measure }), .. }
                | Work::Decrease { extent: Some(Extent::Until { measure }), .. }
                | Work::ShortRows { extent: Some(Extent::Until { measure }) } => finite(measure),
                _ => {}
            }
        }
        let text = serde_json::to_string(&recipe).unwrap();
        prop_assert_eq!(Recipe::from_json(&text).unwrap(), recipe);
    }
}
