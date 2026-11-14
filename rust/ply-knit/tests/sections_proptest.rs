//! Property-based hardening of the knitting section ledger (`ply_knit::sections`). Over generated,
//! deliberately adversarial constructions (counts past what is on the needle, references to steps
//! that do not exist or are not holds, holds returned twice, chart ranges outside the chart,
//! unchecked steps with and without a stitch change):
//!
//! 1. the ledger, validation and the written instructions never panic;
//! 2. the ledger never loses or invents a stitch: between two counted lines, the stitches on the
//!    needle plus those on hold plus those bound off change by exactly what the step adds (a cast-on,
//!    an unchecked step's stated change, or a chart row's production less its consumption), a step
//!    that is not applied changes nothing, and nothing ever goes past the cap (`MAX_LIVE_STITCHES`),
//!    however large the counts in the file (`i64` and `u32` extremes are generated);
//! 3. every step that is not applied is an error at that step, and every bind-off or hold of more
//!    stitches than are left in the row is one of them (nothing goes negative silently);
//! 4. sections survive `.plyknit` save and load exactly, and a step kind this build does not know
//!    makes the file unreadable instead of being dropped.
//!
//! Run: `cargo test -p ply-knit --test sections_proptest`

use ply_common::{Color, Unit};
use ply_knit::pattern::*;
use ply_knit::sections::*;
use ply_knit::{native, to_written, validate, KnitError, Severity};
use proptest::prelude::*;

fn arb_side() -> impl Strategy<Value = Side> {
    prop_oneof![Just(Side::Rs), Just(Side::Ws)]
}

fn arb_stitch() -> impl Strategy<Value = WorkStitch> {
    prop_oneof![
        Just(WorkStitch::Knit),
        Just(WorkStitch::Purl),
        Just(WorkStitch::InPattern)
    ]
}

fn arb_method() -> impl Strategy<Value = TurnMethod> {
    prop_oneof![
        Just(TurnMethod::WrapAndTurn),
        Just(TurnMethod::German),
        Just(TurnMethod::Unspecified)
    ]
}

/// Small counts so they often fit and often do not.
fn count() -> impl Strategy<Value = u32> {
    0u32..14
}

/// A reference to one of the first few step ids (which may or may not be holds), or a missing one.
fn arb_ref() -> impl Strategy<Value = String> {
    prop_oneof![
        (0usize..12).prop_map(|i| format!("step-{i}")),
        Just("missing".to_string())
    ]
}

/// Any step kind except chart rows (whose stitch change depends on the chart).
fn arb_plain_action() -> impl Strategy<Value = StepAction> {
    prop_oneof![
        (
            arb_stitch(),
            prop_oneof![
                Just(WorkTo::End),
                count().prop_map(WorkTo::Last),
                count().prop_map(WorkTo::Count)
            ],
            any::<bool>()
        )
            .prop_map(|(stitch, to, resolve_turns)| StepAction::Work {
                stitch,
                to,
                resolve_turns
            }),
        (
            arb_stitch(),
            prop_oneof![
                count().prop_map(TurnAt::Last),
                count().prop_map(TurnAt::Count)
            ],
            arb_method(),
            any::<bool>()
        )
            .prop_map(|(stitch, to, method, resolve_turns)| StepAction::ShortRow {
                stitch,
                to,
                method,
                resolve_turns
            }),
        prop_oneof![count(), Just(u32::MAX), Just(1_000_000)]
            .prop_map(|count| StepAction::CastOn { count }),
        (prop::option::of(count()), any::<bool>()).prop_map(|(count, resolve_turns)| {
            StepAction::BindOff {
                count,
                resolve_turns,
            }
        }),
        (prop::option::of(count()), "[a-c]{0,2}")
            .prop_map(|(count, name)| StepAction::Hold { count, name }),
        (arb_ref(), prop::option::of(arb_side()))
            .prop_map(|(hold, facing)| StepAction::Resume { hold, facing }),
        prop::option::of(prop_oneof![
            -12i64..12,
            Just(i64::MAX),
            Just(i64::MIN),
            Just(i64::MAX - 1),
            Just(1_000_000)
        ])
        .prop_map(|stitch_change| StepAction::Opaque {
            text: "unchecked".into(),
            stitch_change
        }),
    ]
}

fn arb_action() -> impl Strategy<Value = StepAction> {
    prop_oneof![
        8 => arb_plain_action(),
        1 => (0u32..5, 0u32..5).prop_map(|(first, last)| StepAction::ChartRows { first, last }),
    ]
}

/// Sections whose steps are numbered `step-0`, `step-1`, ... across the pattern.
fn sections_of(groups: Vec<Vec<StepAction>>) -> Vec<Section> {
    let mut n = 0;
    groups
        .into_iter()
        .enumerate()
        .map(|(i, actions)| Section {
            id: format!("section-{i}"),
            name: if i % 2 == 0 {
                format!("Part {i}")
            } else {
                String::new()
            },
            notes: String::new(),
            steps: actions
                .into_iter()
                .map(|action| {
                    let id = format!("step-{n}");
                    n += 1;
                    Step { id, action }
                })
                .collect(),
        })
        .collect()
}

fn pattern(
    cast_on: Option<u32>,
    first: Side,
    round: bool,
    width: usize,
    sections: Vec<Section>,
) -> KnitPattern {
    KnitPattern {
        name: "p".into(),
        construction: if round {
            Construction::InTheRound
        } else {
            Construction::Flat
        },
        first_row_side: first,
        cast_on,
        gauge: Gauge {
            sts: 20.0,
            rows: 28.0,
            unit: Unit::Inches,
        },
        palette: vec![Color::WHITE],
        legend: StitchLegend::builtin(),
        chart: Chart {
            width,
            rows: (0..3)
                .map(|r| {
                    let mut cells = vec![Cell::of(builtin::KNIT); width];
                    if r == 1 && width > 1 {
                        cells[0] = Cell::of(builtin::K2TOG);
                    }
                    Row::plain(cells)
                })
                .collect(),
        },
        notes: String::new(),
        sections,
    }
}

fn arb_pattern(actions: BoxedStrategy<StepAction>) -> impl Strategy<Value = KnitPattern> {
    (
        prop::option::of(prop_oneof![8 => 0u32..16, 1 => Just(u32::MAX)]),
        arb_side(),
        prop::bool::weighted(0.1),
        0usize..10,
        prop::collection::vec(prop::collection::vec(actions, 0..8), 1..4),
    )
        .prop_map(|(cast_on, first, round, width, groups)| {
            pattern(cast_on, first, round, width, sections_of(groups))
        })
}

fn total(c: &NeedleCount) -> u64 {
    c.on_needle + c.held_total() + c.bound_off
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(512))]

    #[test]
    fn the_ledger_validation_and_written_never_panic(p in arb_pattern(arb_action().boxed())) {
        let l = ledger(&p);
        let _ = validate(&p);
        let written = to_written(&p);
        prop_assert!(written.len() >= p.sections.len());
        for line in &l.lines {
            if let LineCount::Counted(c) = &line.count {
                prop_assert!(c.to_work <= c.on_needle);
                prop_assert!(c.past_turns <= c.on_needle);
                prop_assert!(c.pending_turns <= c.on_needle);
            }
        }
    }

    #[test]
    fn the_ledger_never_loses_or_invents_a_stitch(
        p in arb_pattern(arb_action().boxed())
    ) {
        let l = ledger(&p);
        let start = match (p.construction, p.cast_on) {
            (Construction::Flat, Some(n)) => u64::from(n),
            _ => 0,
        };
        let mut prev = Some(start);
        // What was left to work in the row before the line (for a chart row's consumption).
        let mut to_work: Option<u64> = Some(start);
        for line in &l.lines {
            let step = &p.sections[line.section].steps[line.step];
            match &line.count {
                LineCount::Counted(c) => {
                    prop_assert!(c.on_needle + c.held_total() <= MAX_LIVE_STITCHES);
                    let added: i64 = match (&step.action, line.chart_row) {
                        (_, Some(r)) => {
                            let waiting = to_work.expect("a chart row works a counted needle");
                            let (_, count, _) =
                                ply_knit::flow::chart_row_count(&p, r, Some(waiting));
                            let count = count.expect("a counted chart row has a count");
                            prop_assert_eq!(count.consumed, waiting, "it took what was waiting");
                            count.produced as i64 - count.consumed as i64
                        }
                        (StepAction::CastOn { count }, None) => i64::from(*count),
                        (StepAction::Opaque { stitch_change: Some(d), .. }, None) => *d,
                        _ => 0,
                    };
                    if let Some(before) = prev {
                        prop_assert_eq!(
                            total(c) as i64 - before as i64,
                            added,
                            "{:?} at {}/{}", step.action, line.section, line.step
                        );
                    }
                    prev = Some(total(c));
                    to_work = Some(c.to_work);
                }
                LineCount::NotCounted => {
                    // Not applied: the next counted line continues from the same total.
                    prop_assert!(
                        l.issues.iter().any(|i| i.severity == Severity::Error
                            && i.section == Some(line.section)
                            && i.step == Some(line.step)),
                        "a step that is not applied is an error at that step: {:?}",
                        step.action
                    );
                }
                LineCount::Unknown => {
                    prev = None;
                    to_work = None;
                }
            }
        }
    }

    #[test]
    fn removing_more_than_is_left_is_always_an_error(
        p in arb_pattern(arb_plain_action().boxed())
    ) {
        let l = ledger(&p);
        let mut before: Option<NeedleCount> = None;
        for line in &l.lines {
            let step = &p.sections[line.section].steps[line.step];
            let asked = match step.action {
                StepAction::BindOff { count: Some(k), .. } | StepAction::Hold { count: Some(k), .. } => {
                    Some(u64::from(k))
                }
                _ => None,
            };
            if let (Some(k), Some(b)) = (asked, &before) {
                if k > b.to_work || b.on_needle == 0 {
                    prop_assert_eq!(&line.count, &LineCount::NotCounted, "{:?}", step.action);
                }
            }
            match &line.count {
                LineCount::Counted(c) => before = Some(c.clone()),
                LineCount::NotCounted => {}
                LineCount::Unknown => before = None,
            }
        }
    }

    #[test]
    fn sections_round_trip_through_the_file(p in arb_pattern(arb_action().boxed())) {
        let text = native::write(&p).unwrap();
        let back = native::read(&text).unwrap();
        prop_assert_eq!(&back.pattern, &p);
        prop_assert_eq!(native::write(&back.pattern).unwrap(), text);
    }

    #[test]
    fn an_unknown_step_kind_is_never_dropped(kind in "[A-Z][a-z]{2,10}") {
        prop_assume!(!matches!(
            kind.as_str(),
            "Work" | "Hold" | "Resume" | "Opaque" | "CastOn" | "BindOff" | "ShortRow" | "ChartRows"
        ));
        let p = pattern(Some(4), Side::Rs, false, 4, Vec::new());
        let mut v: serde_json::Value = serde_json::from_str(&native::write(&p).unwrap()).unwrap();
        v["document"]["sections"] = serde_json::json!([{
            "id": "s", "name": "", "notes": "",
            "steps": [{"id": "a", "action": {kind: {"count": 1}}}]
        }]);
        prop_assert!(matches!(native::read(&v.to_string()), Err(KnitError::Json(_))));
    }
}
