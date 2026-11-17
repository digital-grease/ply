//! Unit tests of the recipe checks, the stitch count, the written form and the JSON shape.

use super::*;

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

fn titled(mut s: Segment, title: &str) -> Segment {
    s.title = title.to_string();
    s
}

fn own(mut s: Segment, notation: &str, reading: Reading) -> Segment {
    s.stitch = Some(SegmentStitch {
        notation: notation.to_string(),
        name: String::new(),
        reading,
    });
    s
}

fn recipe(segments: Vec<Segment>) -> Recipe {
    Recipe {
        segments,
        ..Recipe::default()
    }
}

fn cm(label: &str, value: f64) -> Measurement {
    Measurement {
        label: label.to_string(),
        value: Some(value),
        unit: Some(LengthUnit::Centimetres),
    }
}

fn chain(n: u32) -> Work {
    Work::FoundationChain {
        stitches: Some(n),
        join: Some(ChainJoin::Ring),
    }
}

fn centre(n: u32) -> Work {
    Work::CentreStart { stitches: Some(n) }
}

fn rounds(n: u32) -> Work {
    Work::Rounds {
        worked: Some(RoundJoin::Spiral),
        extent: Some(Extent::Rounds { count: n }),
    }
}

fn increase(per: u32, n: u32) -> Work {
    Work::Increase {
        per_round: Some(per),
        method: Some(IncreaseMethod::SameLoopTwice),
        extent: Some(Extent::Rounds { count: n }),
    }
}

fn decrease(per: u32, extent: Extent) -> Work {
    Work::Decrease {
        per_round: Some(per),
        method: Some(DecreaseMethod::TwoLoopsAtOnce),
        extent: Some(extent),
    }
}

fn finish() -> Work {
    Work::Finish {
        method: Some(FinishMethod::CloseTip),
    }
}

fn codes(r: &RecipeReport) -> Vec<&'static str> {
    r.issues.iter().map(|i| i.code.as_str()).collect()
}

fn counts(r: &RecipeReport) -> Vec<Count> {
    r.segments.iter().map(|s| s.count).collect()
}

const OSLO: &str = "UO/UOO F1";

#[test]
fn a_clean_hat_has_no_issues_and_counts_from_its_own_numbers() {
    let r = check(
        &recipe(vec![
            seg("segment-1", centre(6)),
            seg("segment-2", increase(6, 5)),
            seg("segment-3", rounds(20)),
            seg(
                "segment-4",
                Work::Finish {
                    method: Some(FinishMethod::TaperEdge),
                },
            ),
        ]),
        OSLO,
    );
    assert!(r.issues.is_empty(), "{:?}", r.issues);
    assert_eq!(
        counts(&r),
        vec![
            Count::Known(6),
            Count::Known(36),
            Count::Known(36),
            Count::Known(36)
        ]
    );
    assert!(r.segments.iter().all(|s| s.part == Some(1) && s.checked));
    assert_eq!(
        r.segments[1].written,
        "Increase 6 stitches in each round, working two stitches into the same loop of the \
         previous round, for 5 rounds."
    );
    assert_eq!(r.segments[2].stitch, Some(StitchUse::Project));
    let project = r
        .project_stitch
        .as_ref()
        .expect("read once, for the whole recipe");
    assert_eq!(project.notation, OSLO);
    assert!(project.read.as_ref().unwrap().is_exact());
    assert!(
        r.segments[3].stitch.is_none(),
        "a finish is not worked in a stitch"
    );
}

#[test]
fn an_empty_recipe_says_so() {
    let r = check(&Recipe::default(), "");
    assert_eq!(codes(&r), ["empty-recipe"]);
    assert_eq!(r.issues[0].text, "The recipe has no steps yet.");
    assert_eq!(r.issues[0].severity, RecipeSeverity::Warning);
}

#[test]
fn body_before_any_start_is_an_error_and_is_not_counted() {
    let r = check(
        &recipe(vec![
            seg("segment-1", rounds(3)),
            seg("segment-2", finish()),
        ]),
        OSLO,
    );
    assert_eq!(codes(&r), ["before-start", "before-start"]);
    assert!(r.issues[0]
        .text
        .starts_with("Step 1: comes before any start"));
    assert_eq!(counts(&r), vec![Count::NotApplicable, Count::NotApplicable]);
    assert_eq!(r.segments[0].part, None);
}

#[test]
fn work_after_a_finish_needs_a_new_start() {
    let r = check(
        &recipe(vec![
            seg("segment-1", centre(8)),
            seg("segment-2", finish()),
            seg("segment-3", rounds(2)),
        ]),
        OSLO,
    );
    assert_eq!(codes(&r), ["before-start"]);
    assert_eq!(
        r.issues[0].text,
        "Step 3: comes after Part 1 was finished in step 2: begin the next part with a start (a \
         foundation chain, a centre start, or loops picked up from earlier work)"
    );
}

#[test]
fn a_part_without_a_finish_is_reported_at_its_last_step() {
    let r = check(
        &recipe(vec![
            seg("segment-1", centre(8)),
            seg("segment-2", rounds(4)),
            seg("segment-3", centre(6)),
        ]),
        OSLO,
    );
    assert_eq!(codes(&r), ["part-not-finished", "part-not-finished"]);
    assert_eq!(r.issues[0].segment, Some(1));
    assert_eq!(
        r.issues[0].text,
        "Step 2: Part 1 ends here without a finish: add a finish step after this one"
    );
    assert_eq!(r.issues[1].segment, Some(2));
    assert_eq!(r.segments[2].part, Some(2));
    assert_eq!(
        r.segments[2].count,
        Count::Known(6),
        "a new part counts anew"
    );
}

#[test]
fn a_decrease_cannot_remove_more_than_the_round_has_and_is_not_applied() {
    let r = check(
        &recipe(vec![
            seg("segment-1", chain(20)),
            seg("segment-2", decrease(6, Extent::Rounds { count: 4 })),
            seg("segment-3", decrease(4, Extent::Rounds { count: 2 })),
            seg("segment-4", finish()),
        ]),
        OSLO,
    );
    assert_eq!(codes(&r), ["decrease-too-many"]);
    assert_eq!(
        r.issues[0].message,
        "removes 24 stitches (6 in each of 4 rounds), but the round has only 20"
    );
    assert_eq!(
        counts(&r),
        vec![
            Count::Known(20),
            Count::Refused,
            Count::Known(12),
            Count::Known(12)
        ],
        "the refused step leaves the count where it was"
    );
}

#[test]
fn until_a_stitch_count_sets_the_count_and_is_checked_against_it() {
    let r = check(
        &recipe(vec![
            seg("segment-1", chain(40)),
            seg("segment-2", decrease(4, Extent::UntilStitches { count: 8 })),
            seg(
                "segment-3",
                Work::Increase {
                    per_round: None,
                    method: None,
                    extent: Some(Extent::UntilStitches { count: 8 }),
                },
            ),
            seg("segment-4", decrease(2, Extent::UntilStitches { count: 9 })),
            seg("segment-5", finish()),
        ]),
        OSLO,
    );
    assert_eq!(codes(&r), ["increase-to-fewer", "decrease-to-more"]);
    assert_eq!(
        r.issues[0].message,
        "increases until there are 8 stitches, but the round already has 8"
    );
    assert_eq!(
        r.issues[1].message,
        "decreases until there are 9 stitches, but the round has only 8"
    );
    assert_eq!(r.segments[1].count, Count::Known(8));
    assert_eq!(r.segments[1].written, "Decrease 4 stitches in each round, connecting through two loops of the previous round at once, until 8 stitches remain.");
}

#[test]
fn a_count_that_becomes_unknown_says_so_once_and_until_stitches_re_anchors_it() {
    let r = check(
        &recipe(vec![
            seg("segment-1", centre(6)),
            seg(
                "segment-2",
                Work::Increase {
                    per_round: None,
                    method: Some(IncreaseMethod::SameLoopTwice),
                    extent: Some(Extent::Until {
                        measure: Measurement {
                            label: "it lies flat".into(),
                            value: None,
                            unit: None,
                        },
                    }),
                },
            ),
            seg("segment-3", rounds(10)),
            seg("segment-4", decrease(6, Extent::UntilStitches { count: 6 })),
            seg("segment-5", finish()),
        ]),
        OSLO,
    );
    assert_eq!(codes(&r), ["count-unknown"]);
    assert_eq!(r.issues[0].severity, RecipeSeverity::Info);
    assert_eq!(
        counts(&r),
        vec![
            Count::Known(6),
            Count::Unknown,
            Count::Unknown,
            Count::Known(6),
            Count::Known(6)
        ]
    );
    assert_eq!(
        r.segments[1].written,
        "Increase, working two stitches into the same loop of the previous round, until it lies \
         flat."
    );
}

#[test]
fn zero_counts_are_errors() {
    let r = check(
        &recipe(vec![
            seg("segment-1", chain(0)),
            seg("segment-2", rounds(0)),
            seg("segment-3", increase(0, 2)),
            seg("segment-4", finish()),
        ]),
        OSLO,
    );
    assert_eq!(
        codes(&r),
        [
            "count-not-positive",
            "count-not-positive",
            "count-not-positive"
        ]
    );
    assert_eq!(
        r.issues[0].message,
        "makes a foundation chain of 0 stitches: a count must be at least 1"
    );
    assert_eq!(
        r.issues[1].message,
        "works 0 rounds: a count must be at least 1"
    );
    assert_eq!(r.segments[2].count, Count::Refused);
}

#[test]
fn counts_past_the_cap_are_refused_never_wrapped() {
    let r = check(
        &recipe(vec![
            seg("segment-1", chain(MAX_STITCHES)),
            seg("segment-2", increase(u32::MAX, u32::MAX)),
            seg("segment-3", increase(1, 1)),
            seg("segment-4", finish()),
        ]),
        OSLO,
    );
    assert_eq!(codes(&r), ["count-too-large", "count-too-large"]);
    assert_eq!(
        r.issues[0].message,
        "increases by 4,294,967,295 stitches, more than Ply counts (1,000,000)"
    );
    assert_eq!(
        r.issues[1].message,
        "would have 1,000,001 stitches, more than Ply counts (1,000,000)"
    );
}

#[test]
fn an_opening_changes_the_count_by_what_it_skips_and_works_across() {
    let r = check(
        &recipe(vec![
            seg("segment-1", chain(36)),
            titled(
                seg(
                    "segment-2",
                    Work::Opening {
                        skip: Some(8),
                        stitches: Some(10),
                    },
                ),
                "Thumb opening",
            ),
            seg("segment-3", finish()),
            seg(
                "segment-4",
                Work::PickUp {
                    from: Some("segment-2".into()),
                    stitches: Some(18),
                },
            ),
            seg("segment-5", finish()),
        ]),
        OSLO,
    );
    assert!(r.issues.is_empty(), "{:?}", r.issues);
    assert_eq!(r.segments[1].count, Count::Known(38));
    assert_eq!(
        r.segments[1].written,
        "Leave an opening: skip 8 loops of the previous round and work 10 stitches across the gap \
         without connecting them."
    );
    assert_eq!(
        r.segments[3].written,
        "Pick up 18 loops around the opening in step 2 (Thumb opening) to start this part."
    );
    assert_eq!(r.segments[3].part, Some(2));
}

#[test]
fn an_opening_must_leave_part_of_the_round_connected() {
    let r = check(
        &recipe(vec![
            seg("segment-1", centre(8)),
            seg(
                "segment-2",
                Work::Opening {
                    skip: Some(8),
                    stitches: Some(8),
                },
            ),
            seg(
                "segment-3",
                Work::Join {
                    closes: Some("segment-2".into()),
                },
            ),
            seg("segment-4", finish()),
        ]),
        OSLO,
    );
    assert_eq!(codes(&r), ["opening-too-wide"]);
    assert_eq!(r.segments[1].count, Count::Refused);
    assert_eq!(r.segments[2].count, Count::Known(8));
}

#[test]
fn references_name_an_earlier_unused_opening() {
    let r = check(
        &recipe(vec![
            seg("segment-1", centre(20)),
            seg(
                "segment-2",
                Work::Join {
                    closes: Some("segment-4".into()),
                },
            ),
            seg(
                "segment-3",
                Work::Join {
                    closes: Some("segment-1".into()),
                },
            ),
            seg(
                "segment-4",
                Work::Opening {
                    skip: Some(4),
                    stitches: Some(4),
                },
            ),
            seg(
                "segment-5",
                Work::Join {
                    closes: Some("segment-4".into()),
                },
            ),
            seg(
                "segment-6",
                Work::Join {
                    closes: Some("segment-4".into()),
                },
            ),
            seg(
                "segment-7",
                Work::Join {
                    closes: Some("nowhere".into()),
                },
            ),
            seg("segment-8", finish()),
        ]),
        OSLO,
    );
    assert_eq!(
        codes(&r),
        [
            "opening-later",
            "not-an-opening",
            "opening-already-used",
            "unknown-step"
        ]
    );
    assert_eq!(
        r.issues[2].message,
        "closes the opening in step 4, but step 5 already closed it"
    );
    assert_eq!(
        r.issues[3].message,
        "closes a step that is not in the recipe (nowhere)"
    );
}

#[test]
fn an_opening_never_worked_or_closed_warns() {
    let r = check(
        &recipe(vec![
            seg("segment-1", centre(20)),
            seg(
                "segment-2",
                Work::Opening {
                    skip: None,
                    stitches: None,
                },
            ),
            seg("segment-3", finish()),
        ]),
        OSLO,
    );
    assert_eq!(codes(&r), ["count-unknown", "opening-not-used"]);
    assert_eq!(r.issues[1].segment, Some(1));
}

#[test]
fn ids_must_be_present_and_unique() {
    let r = check(
        &recipe(vec![
            seg("segment-1", centre(8)),
            seg("", rounds(2)),
            seg("segment-1", finish()),
        ]),
        OSLO,
    );
    assert_eq!(codes(&r), ["missing-id", "duplicate-id"]);
    assert_eq!(
        r.issues[1].message,
        "has the same id (segment-1) as step 1, so a step that names it is ambiguous"
    );
}

#[test]
fn own_notation_is_kept_verbatim_and_read_in_its_mode() {
    let r = check(
        &recipe(vec![
            own(seg("segment-1", chain(30)), "uo/uoo f2", Reading::Strict),
            own(seg("segment-2", rounds(3)), "UO/UOO F1+1", Reading::Strict),
            own(seg("segment-3", rounds(3)), "UO/UOO F1+1", Reading::Lenient),
            own(seg("segment-4", rounds(3)), "UO/UOO", Reading::Strict),
            seg("segment-5", finish()),
        ]),
        "",
    );
    assert_eq!(
        codes(&r),
        ["notation-problem", "notation-problem", "no-connection"]
    );
    assert_eq!(r.issues[0].severity, RecipeSeverity::Error);
    assert_eq!(r.issues[0].segment, Some(1));
    assert_eq!(r.issues[1].severity, RecipeSeverity::Warning);
    assert_eq!(r.issues[1].segment, Some(2));
    let Some(StitchUse::Own(first)) = &r.segments[0].stitch else {
        panic!("an own stitch")
    };
    assert_eq!(first.notation, "uo/uoo f2", "never rewritten");
    let read = first.read.as_ref().unwrap();
    assert!(read.accepted, "case is only a formatting note");
    assert_eq!(read.normalized, "UO/UOO F2");
    assert_eq!(r.project_stitch, None, "the project has no stitch");
}

#[test]
fn a_missing_stitch_is_reported_where_one_is_needed() {
    let r = check(
        &recipe(vec![
            seg("segment-1", centre(8)),
            own(seg("segment-2", rounds(2)), "  ", Reading::Strict),
            seg("segment-3", finish()),
        ]),
        "",
    );
    assert_eq!(codes(&r), ["no-stitch", "no-stitch"]);
    assert_eq!(
        r.issues[0].message,
        "does not say which stitch it is worked in: choose the project's stitch or give this step \
         its own"
    );
    assert_eq!(
        r.issues[1].message,
        "is set to its own stitch, but no notation is given"
    );
}

#[test]
fn the_projects_stitch_problems_are_reported_once() {
    let r = check(
        &recipe(vec![
            seg("segment-1", centre(8)),
            seg("segment-2", rounds(2)),
            seg("segment-3", rounds(2)),
            seg("segment-4", finish()),
        ]),
        "UO/XYZ",
    );
    assert_eq!(codes(&r), ["project-notation-problem"]);
    assert_eq!(
        r.issues[0].text,
        "The project's stitch notation has 2 problems, and steps 1, 2 and 3 are worked in it: see \
         the project's Stitch field."
    );
    let r = check(
        &recipe(vec![
            seg("segment-1", centre(8)),
            seg("segment-2", rounds(2)),
            seg("segment-3", finish()),
        ]),
        "UO/UOO",
    );
    assert_eq!(codes(&r), ["no-connection"]);
    assert_eq!(
        r.issues[0].text,
        "The project's stitch has no connection to the previous round (such as F1 or B1), and \
         step 2 works into the round before, so the recipe does not say how."
    );
}

#[test]
fn measurements_need_a_positive_value_and_a_unit() {
    let mut rec = recipe(vec![
        seg("segment-1", centre(8)),
        seg(
            "segment-2",
            Work::Rounds {
                worked: None,
                extent: Some(Extent::Until {
                    measure: Measurement {
                        label: String::new(),
                        value: None,
                        unit: None,
                    },
                }),
            },
        ),
        seg(
            "segment-3",
            Work::Rows {
                extent: Some(Extent::Until {
                    measure: Measurement {
                        label: "from the start".into(),
                        value: Some(7.0),
                        unit: None,
                    },
                }),
            },
        ),
        seg("segment-4", finish()),
    ]);
    rec.segments[0].target = Some(cm("Width across", 0.0));
    rec.fit = vec![
        cm("Hand around the knuckles", 20.0),
        Measurement {
            label: "Length".into(),
            value: None,
            unit: Some(LengthUnit::Inches),
        },
    ];
    let r = check(&rec, OSLO);
    assert_eq!(
        codes(&r),
        [
            "measurement-not-positive",
            "until-not-stated",
            "measurement-no-unit",
            "measurement-no-value"
        ]
    );
    assert_eq!(
        r.issues[0].message,
        "the target measurement is 0 cm, but a length must be more than 0"
    );
    assert_eq!(
        r.issues[2].message,
        "the measurement it works until gives 7 with no unit: choose mm, cm or in"
    );
    assert_eq!(
        r.issues[3].text,
        "Fit 2 (Length): this measurement has no value yet"
    );
    assert_eq!(
        r.fit,
        [
            "Hand around the knuckles: 20 cm",
            "Length: not measured yet"
        ]
    );
    assert_eq!(r.segments[0].target.as_deref(), Some("Width across: 0 cm"));
    assert_eq!(
        r.segments[2].written,
        "Work back and forth in rows until it measures 7 (from the start)."
    );
    assert_eq!(
        r.segments[1].written,
        "Work in rounds until a point the recipe does not state."
    );
}

#[test]
fn until_stitches_only_fits_shaping() {
    let r = check(
        &recipe(vec![
            seg("segment-1", centre(8)),
            seg(
                "segment-2",
                Work::Rounds {
                    worked: Some(RoundJoin::Joined),
                    extent: Some(Extent::UntilStitches { count: 4 }),
                },
            ),
            seg("segment-3", finish()),
        ]),
        OSLO,
    );
    assert_eq!(codes(&r), ["extent-not-for-kind"]);
    assert_eq!(r.segments[1].count, Count::Known(8));
}

#[test]
fn free_text_is_never_read_but_its_role_places_it() {
    let r = check(
        &recipe(vec![
            seg(
                "segment-1",
                Work::Freeform {
                    role: Phase::Start,
                    text: "Start on a twined ring as the old finds do.".into(),
                },
            ),
            seg("segment-2", rounds(4)),
            seg(
                "segment-3",
                Work::Freeform {
                    role: Phase::Other,
                    text: "Try it on.".into(),
                },
            ),
            seg(
                "segment-4",
                Work::Freeform {
                    role: Phase::Finish,
                    text: String::new(),
                },
            ),
        ]),
        OSLO,
    );
    assert_eq!(codes(&r), ["empty-freeform"]);
    assert!(!r.segments[0].checked);
    assert_eq!(
        r.segments[0].written,
        "Start on a twined ring as the old finds do."
    );
    assert_eq!(r.segments[0].stitch, None, "free text has no stitch");
    assert_eq!(r.segments[2].count, Count::NotApplicable);
    assert_eq!(r.segments[2].part, Some(1));
    assert_eq!(r.segments[3].part, Some(1));
}

#[test]
fn free_text_body_loses_a_known_count() {
    let r = check(
        &recipe(vec![
            seg("segment-1", centre(8)),
            seg(
                "segment-2",
                Work::Freeform {
                    role: Phase::Shaping,
                    text: "Shape by eye.".into(),
                },
            ),
            seg("segment-3", finish()),
        ]),
        OSLO,
    );
    assert_eq!(codes(&r), ["count-unknown"]);
    assert_eq!(
        r.issues[0].message,
        "Ply does not read free text, so the stitches after it cannot be counted; later counts \
         are not checked"
    );
}

#[test]
fn written_forms_of_every_kind() {
    let rec = recipe(vec![
        seg(
            "a",
            Work::FoundationChain {
                stitches: None,
                join: Some(ChainJoin::Flat),
            },
        ),
        seg("b", Work::CentreStart { stitches: None }),
        seg(
            "c",
            Work::PickUp {
                from: None,
                stitches: None,
            },
        ),
        seg(
            "d",
            Work::ShortRows {
                extent: Some(Extent::Rounds { count: 1 }),
            },
        ),
        seg("e", Work::ShortRows { extent: None }),
        seg(
            "f",
            Work::Opening {
                skip: None,
                stitches: Some(1),
            },
        ),
        seg("g", Work::Join { closes: None }),
        seg("h", Work::Finish { method: None }),
        seg(
            "i",
            Work::Decrease {
                per_round: None,
                method: Some(DecreaseMethod::SkipALoop),
                extent: Some(Extent::UntilStitches { count: 1 }),
            },
        ),
        seg(
            "j",
            Work::Rounds {
                worked: Some(RoundJoin::Joined),
                extent: Some(Extent::Until {
                    measure: cm("", 12.5),
                }),
            },
        ),
    ]);
    let r = check(&rec, OSLO);
    let written: Vec<&str> = r.segments.iter().map(|s| s.written.as_str()).collect();
    assert_eq!(
        written,
        [
            "Make a foundation chain and leave it open to work in rows.",
            "Start in the round at the centre.",
            "Pick up loops from earlier work to start this part.",
            "Work 1 short row back and forth over part of the round.",
            "Work short rows back and forth over part of the round.",
            "Leave an opening: work 1 stitch across the gap without connecting them to the \
             previous round.",
            "Join.",
            "Finish.",
            "Decrease, skipping a loop of the previous round, until 1 stitch remains.",
            "Work in joined rounds until it measures 12.5 cm.",
        ]
    );
}

#[test]
fn every_code_string_is_unique_and_kebab_case() {
    let mut seen = std::collections::HashSet::new();
    for code in RecipeCode::ALL {
        let s = code.as_str();
        assert!(seen.insert(s), "{s} repeats");
        assert!(s.chars().all(|c| c.is_ascii_lowercase() || c == '-'), "{s}");
        let json = serde_json::to_string(&code).unwrap();
        assert_eq!(json, format!("\"{s}\""), "serde and as_str agree");
    }
}

#[test]
fn a_recipe_past_the_limits_is_one_error() {
    let mut rec = recipe(vec![seg("segment-1", centre(8)); MAX_SEGMENTS + 1]);
    let r = check(&rec, OSLO);
    assert_eq!(codes(&r), ["too-large"]);
    assert!(r.segments.is_empty());
    assert!(r.too_large());
    rec.segments.truncate(2);
    rec.segments[1].title = "Cuff".into();
    rec.segments[1].notes = "x".repeat(MAX_TEXT + 1);
    let r = check(&rec, OSLO);
    assert_eq!(codes(&r), ["too-large"]);
    assert_eq!(
        r.issues[0].segment,
        Some(1),
        "placed where the long text is"
    );
    assert_eq!(
        r.issues[0].text,
        "Step 2 (Cuff): its notes are longer than 10,000 characters, so Ply does not check the \
         recipe."
    );
    rec.segments[1].notes = "x".repeat(MAX_TEXT);
    assert!(!codes(&check(&rec, OSLO)).contains(&"too-large"));
    // UTF-16 units, as the app counts them: an emoji is two.
    rec.segments[1].notes = "\u{1F9F6}".repeat(MAX_TEXT / 2 + 1);
    assert_eq!(codes(&check(&rec, OSLO)), ["too-large"]);
    rec.segments[1].notes = String::new();
    rec.fit = vec![Measurement {
        label: "y".repeat(MAX_TEXT + 1),
        value: None,
        unit: None,
    }];
    let r = check(&rec, OSLO);
    assert_eq!((r.issues[0].fit, r.issues[0].segment), (Some(0), None));
    assert!(r.issues[0].text.starts_with("Fit 1: its label is longer"));
}

#[test]
fn the_recipe_text_in_all_is_capped_and_a_long_project_stitch_is_not_the_recipe() {
    // Each text within its own limit, but too much together.
    let mut rec = recipe(Vec::new());
    for i in 0..(MAX_TOTAL_TEXT / MAX_TEXT + 1) {
        let mut s = seg(&format!("segment-{i}"), rounds(1));
        s.notes = "n".repeat(MAX_TEXT);
        rec.segments.push(s);
    }
    let r = check(&rec, OSLO);
    assert_eq!(codes(&r), ["too-large"]);
    assert_eq!(r.issues[0].segment, None);
    assert!(r.issues[0].text.contains("texts together"));
    // A project stitch too long to read is said once, as the project's, and not as too large.
    let long = "UO".repeat(MAX_NOTATION / 2 + 1);
    let r = check(
        &recipe(vec![
            seg("segment-1", centre(8)),
            seg("segment-2", rounds(2)),
            seg("segment-3", finish()),
        ]),
        &long,
    );
    assert_eq!(codes(&r), ["notation-too-long"]);
    assert_eq!(
        r.issues[0].text,
        "The project's stitch notation is longer than 200 characters, so Ply does not read it, \
         and steps 1 and 2 are worked in it: see the project's Stitch field."
    );
    assert_eq!(r.project_stitch.as_ref().unwrap().read, None);
    assert_eq!(
        r.project_stitch.as_ref().unwrap().notation,
        long,
        "kept verbatim"
    );
}

#[test]
fn an_own_stitch_too_long_to_read_is_one_error_and_is_kept() {
    let long = format!("{}/UOO F1", "UO".repeat(MAX_NOTATION / 2));
    let r = check(
        &recipe(vec![
            own(seg("segment-1", centre(8)), &long, Reading::Strict),
            seg("segment-2", finish()),
        ]),
        OSLO,
    );
    assert_eq!(codes(&r), ["notation-too-long"]);
    let Some(StitchUse::Own(st)) = &r.segments[0].stitch else {
        panic!("own")
    };
    assert_eq!((st.notation.as_str(), &st.read), (long.as_str(), &None));
}

#[test]
fn notation_problems_are_capped_per_stitch_with_a_count_of_the_rest() {
    let bad = "(".repeat(MAX_NOTATION);
    let r = check(
        &recipe(vec![
            own(seg("segment-1", centre(8)), &bad, Reading::Strict),
            seg("segment-2", finish()),
        ]),
        OSLO,
    );
    let problems: Vec<&RecipeIssue> = r
        .issues
        .iter()
        .filter(|i| i.code == RecipeCode::NotationProblem)
        .collect();
    assert_eq!(problems.len(), MAX_NOTATION_ISSUES + 1);
    let last = problems.last().unwrap();
    assert!(
        last.message.starts_with("the stitch notation has ")
            && last
                .message
                .ends_with(" more problems; fix the ones above first"),
        "{}",
        last.message
    );
}

#[test]
fn a_file_at_the_caps_gives_a_bounded_report() {
    // Every segment's notation as long and as wrong as Ply reads, and the total text at its cap.
    let titles = "t".repeat(40);
    let per = (MAX_TOTAL_TEXT / MAX_SEGMENTS) - 40 - "segment-1000".len() - 1;
    let bad = "(".repeat(per.min(MAX_NOTATION));
    let segments = (0..MAX_SEGMENTS)
        .map(|i| {
            let mut s = own(
                seg(&format!("segment-{i}"), rounds(1)),
                &bad,
                Reading::Strict,
            );
            s.title = titles.clone();
            s
        })
        .collect();
    let rec = recipe(segments);
    let started = std::time::Instant::now();
    let r = check(&rec, &"(".repeat(MAX_NOTATION));
    assert!(started.elapsed().as_secs() < 30, "bounded time");
    assert!(!r.too_large(), "at, not past, the caps");
    assert!(
        r.issues.len() <= MAX_SEGMENTS * (MAX_NOTATION_ISSUES + 4),
        "{} issues",
        r.issues.len()
    );
    let size = serde_json::to_string(&r).unwrap().len();
    assert!(size < 20_000_000, "the report is {size} bytes");
}

#[test]
fn long_titles_and_ids_are_shortened_in_places_and_references() {
    let title = "A very long title for the thumb opening, much longer than forty characters";
    let mut opening = seg(
        "segment-2",
        Work::Opening {
            skip: Some(2),
            stitches: Some(2),
        },
    );
    opening.title = title.into();
    let r = check(
        &recipe(vec![
            seg("segment-1", centre(10)),
            opening,
            seg(
                "segment-3",
                Work::Join {
                    closes: Some("segment-2".into()),
                },
            ),
            seg(
                "segment-4",
                Work::Join {
                    closes: Some("x".repeat(500)),
                },
            ),
            seg("segment-5", finish()),
        ]),
        OSLO,
    );
    assert_eq!(
        r.segments[2].written,
        "Join the edges of the opening in step 2 (A very long title for the thumb opening…) \
         to close it."
    );
    assert_eq!(r.issues[0].code.as_str(), "unknown-step");
    assert!(r.issues[0].text.len() < 200, "{}", r.issues[0].text);
}

#[test]
fn a_decrease_that_removes_every_stitch_is_refused() {
    let r = check(
        &recipe(vec![
            seg("segment-1", centre(6)),
            seg("segment-2", decrease(6, Extent::Rounds { count: 1 })),
            seg("segment-3", rounds(2)),
            seg("segment-4", finish()),
        ]),
        OSLO,
    );
    assert_eq!(codes(&r), ["decrease-too-many"]);
    assert_eq!(
        r.issues[0].message,
        "removes all 6 stitches of the round (6 in each of 1 round): a decrease must leave some"
    );
    assert_eq!(
        counts(&r),
        vec![
            Count::Known(6),
            Count::Refused,
            Count::Known(6),
            Count::Known(6)
        ]
    );
}

#[test]
fn the_json_shape_is_the_apps() {
    let text = r#"{"fit":[{"label":"Head around","value":56.0,"unit":"cm"}],"segments":[
        {"id":"segment-1","title":"Crown","work":{"kind":"centreStart","stitches":6},"stitch":null,"target":null,"notes":"","caution":""},
        {"id":"segment-2","title":"","work":{"kind":"increase","perRound":6,"method":"sameLoopTwice","extent":{"type":"rounds","count":5}},"stitch":{"notation":"UO/UOO F2","name":"Oslo","reading":"strict"},"target":{"label":"Across","value":18.0,"unit":"cm"},"notes":"n","caution":"c"},
        {"id":"segment-3","title":"","work":{"kind":"opening","skip":4,"stitches":6},"stitch":null,"target":null,"notes":"","caution":""},
        {"id":"segment-4","title":"","work":{"kind":"freeform","role":"other","text":"t"},"stitch":null,"target":null,"notes":"","caution":""},
        {"id":"segment-5","title":"","work":{"kind":"pickUp","from":"segment-3","stitches":null},"stitch":null,"target":null,"notes":"","caution":""},
        {"id":"segment-6","title":"","work":{"kind":"rounds","worked":"spiral","extent":{"type":"until","measure":{"label":"it fits","value":null,"unit":null}}},"stitch":null,"target":null,"notes":"","caution":""}
    ],"done":["segment-1"]}"#;
    let rec = Recipe::from_json(text).unwrap();
    assert_eq!(rec.segments.len(), 6);
    assert_eq!(
        rec.segments[1].work,
        Work::Increase {
            per_round: Some(6),
            method: Some(IncreaseMethod::SameLoopTwice),
            extent: Some(Extent::Rounds { count: 5 }),
        }
    );
    assert_eq!(rec.fit[0].unit, Some(LengthUnit::Centimetres));
    assert_eq!(rec.done, ["segment-1"]);
    let back = Recipe::from_json(&serde_json::to_string(&rec).unwrap()).unwrap();
    assert_eq!(back, rec, "the engine's own form round-trips");
}

#[test]
fn an_unknown_kind_or_value_is_refused_not_dropped() {
    let segment = |work: &str| {
        format!(
            r#"{{"segments":[{{"id":"segment-1","title":"","work":{work},"notes":"","caution":""}}]}}"#
        )
    };
    assert!(Recipe::from_json(&segment(r#"{"kind":"weaveIn"}"#)).is_err());
    assert!(Recipe::from_json(&segment(r#"{"kind":"finish","method":"felt"}"#)).is_err());
    assert!(
        Recipe::from_json(&segment(r#"{"kind":"rounds","extent":{"type":"forever"}}"#)).is_err()
    );
    assert!(Recipe::from_json(&segment(r#"{"kind":"centreStart","stitches":-1}"#)).is_err());
    assert!(Recipe::from_json(&segment(r#"{"kind":"centreStart","stitches":6}"#)).is_ok());
}
