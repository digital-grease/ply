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
//! 4. sections survive `.plyknit` save and load exactly (decoded into their types, to the same
//!    pattern as through a generic tree), and a step kind this build does not know makes the file
//!    unreadable instead of being dropped;
//! 5. working in the round, parts worked flat, needle groups, pick-ups, shaping and closing keep the
//!    same accounting: a pick-up adds exactly its stitches, a short row's decrease takes exactly
//!    one, a shaping step reaches exactly its count by whole repeats, a close moves every stitch to
//!    grafted or bound off, and the needle groups always hold exactly the stitches on the needle;
//! 6. several pieces (ADR 0020) keep it too: sections work generated pieces (some missing), joins
//!    take generated pieces and holds, and on the needle, on hold, set aside on the other pieces,
//!    bound off and grafted still change by exactly what each step adds (a join adds nothing; it
//!    moves stitches), per piece where a step's check needs the row it works.
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
                count().prop_map(TurnAt::Count),
                (0u32..4).prop_map(TurnAt::BeforeGap),
                (0u32..4).prop_map(TurnAt::PastGap),
            ],
            arb_method(),
            any::<bool>(),
            prop::option::of((
                prop_oneof![
                    Just(Decrease::K2tog),
                    Just(Decrease::Ssk),
                    Just(Decrease::P2tog),
                    Just(Decrease::Ssp)
                ],
                0u32..3
            ))
        )
            .prop_map(
                |(stitch, to, method, resolve_turns, dec)| StepAction::ShortRow {
                    stitch,
                    to,
                    method,
                    resolve_turns,
                    decrease: dec.map(|(kind, after)| TurnDecrease { kind, after }),
                }
            ),
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

/// The version-5 step kinds: rounds, parts worked flat, rows, shaping, pick-ups, groups, closing.
fn arb_round_action() -> impl Strategy<Value = StepAction> {
    let group = || {
        prop_oneof![
            Just("sole".to_string()),
            Just("instep".to_string()),
            Just("x".to_string())
        ]
    };
    prop_oneof![
        Just(StepAction::JoinRound {}),
        Just(StepAction::RoundStart {}),
        (count(), any::<bool>()).prop_map(|(count, slip_edges)| StepAction::WorkFlat {
            count,
            name: "heel".into(),
            slip_edges
        }),
        prop_oneof![0u32..5, Just(u32::MAX)].prop_map(|count| StepAction::Rows {
            count,
            text: "knit".into()
        }),
        (
            prop_oneof![-3i64..3, Just(1_000_000), Just(-1_000_000)],
            0u32..4,
            prop_oneof![
                prop_oneof![0u32..6, Just(u32::MAX)].prop_map(ShapeUntil::Times),
                (0u32..20).prop_map(ShapeUntil::Remain)
            ],
            prop::collection::vec(group(), 0..3)
        )
            .prop_map(|(change, every, until, groups)| StepAction::Shape {
                change,
                every,
                until,
                groups,
                text: String::new()
            }),
        (
            prop_oneof![count(), Just(u32::MAX)],
            prop_oneof![
                arb_ref().prop_map(PickUpAlong::Piece),
                Just(PickUpAlong::Edge("the edge".into()))
            ],
            prop::option::of(group())
        )
            .prop_map(|(count, along, group)| StepAction::PickUp {
                count,
                along,
                group
            }),
        prop::collection::vec((group(), 0u32..10), 0..3).prop_map(|g| StepAction::Groups {
            groups: g
                .into_iter()
                .map(|(name, count)| NeedleGroup {
                    name,
                    count,
                    notes: String::new()
                })
                .collect()
        }),
        (
            prop_oneof![
                Just(CloseMethod::Graft),
                Just(CloseMethod::ThreeNeedleBindOff)
            ],
            prop_oneof![
                3 => Just(Vec::new()),
                2 => (arb_ref(), arb_ref()).prop_map(|(a, b)| vec![a, b]),
                1 => prop::collection::vec(arb_ref(), 0..4),
            ]
        )
            .prop_map(|(method, holds)| StepAction::Close { method, holds }),
    ]
}

/// The version-6 join: another piece (one of the first few, or a missing one) or a hold.
fn arb_join_action() -> impl Strategy<Value = StepAction> {
    (
        prop_oneof![
            prop_oneof![
                (0usize..4).prop_map(|i| format!("p{i}")),
                Just("gone".to_string())
            ]
            .prop_map(JoinSource::Piece),
            arb_ref().prop_map(JoinSource::Held),
        ],
        arb_stitch(),
        any::<bool>(),
    )
        .prop_map(|(source, stitch, resolve_turns)| StepAction::Join {
            source,
            stitch,
            resolve_turns,
        })
}

fn arb_action() -> impl Strategy<Value = StepAction> {
    prop_oneof![
        8 => arb_plain_action(),
        4 => arb_round_action(),
        3 => arb_join_action(),
        1 => (0u32..5, 0u32..5).prop_map(|(first, last)| StepAction::ChartRows { first, last }),
    ]
}

/// Sections whose steps are numbered `step-0`, `step-1`, ... across the pattern, each working the
/// piece `pieces[i]` (`None`: the first; ids `p0`, `p1`, ...; some may be missing).
fn sections_on(groups: Vec<Vec<StepAction>>, pieces: &[Option<usize>]) -> Vec<Section> {
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
            construction: None,
            piece: pieces.get(i).copied().flatten().map(|k| format!("p{k}")),
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
        pieces: Vec::new(),
    }
}

fn arb_pattern(actions: BoxedStrategy<StepAction>) -> impl Strategy<Value = KnitPattern> {
    (
        prop::option::of(prop_oneof![8 => 0u32..16, 1 => Just(u32::MAX)]),
        arb_side(),
        prop::bool::weighted(0.4),
        0usize..10,
        prop::collection::vec(prop::collection::vec(actions, 0..8), 1..6),
        // The pattern's pieces (0: one piece, as before), and each section's (one past the last is
        // a piece the pattern does not have).
        prop_oneof![2 => Just(0usize), 3 => 1usize..4],
        prop::collection::vec(prop::option::of(0usize..5), 6),
    )
        .prop_map(|(cast_on, first, round, width, groups, pieces, on)| {
            let on: Vec<Option<usize>> = if pieces == 0 {
                Vec::new()
            } else {
                on.into_iter().map(|k| k.map(|k| k.min(pieces))).collect()
            };
            let mut p = pattern(cast_on, first, round, width, sections_on(groups, &on));
            p.pieces = (0..pieces)
                .map(|i| Piece {
                    id: format!("p{i}"),
                    name: if i == 2 {
                        String::new()
                    } else {
                        format!("piece {i}")
                    },
                })
                .collect();
            p
        })
}

/// Every live stitch and every stitch closed off, when each piece's count is known.
fn total(c: &NeedleCount) -> Option<u64> {
    Some(c.on_needle + c.held_total() + c.bound_off_total + c.grafted_total + c.set_aside_total()?)
}

/// The stitches being worked: the part worked flat, or the whole needle.
fn working(c: &NeedleCount) -> u64 {
    c.flat.unwrap_or(c.on_needle)
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(512))]

    #[test]
    fn the_ledger_validation_and_written_never_panic(p in arb_pattern(arb_action().boxed())) {
        let l = ledger(&p);
        let _ = validate(&p);
        prop_assert_eq!(l.pieces.len(), p.pieces.len());
        let written = to_written(&p);
        prop_assert!(written.len() >= p.sections.len());
        for line in &l.lines {
            // Every line is on the piece its section works.
            prop_assert_eq!(line.piece, section_piece(&p, line.section));
            if let LineCount::Counted(c) = &line.count {
                prop_assert!(c.to_work <= c.on_needle);
                prop_assert!(c.set_aside.iter().all(|a| Some(a.piece) != line.piece));
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
        // The pattern's cast-on is on the first piece's needle at the start, flat or joined into a
        // round; every other piece starts empty.
        let start = p.cast_on.map_or(0, u64::from);
        let mut prev = Some(start);
        // For each piece (by the line's piece; `None` for a pattern of one piece): what was left to
        // work in its row before the line (for a chart row's consumption) and the stitches being
        // worked (for a shaping step's target), as its last line left them.
        let mut state: std::collections::HashMap<Option<usize>, (Option<u64>, Option<u64>)> =
            std::collections::HashMap::new();
        for line in &l.lines {
            let step = &p.sections[line.section].steps[line.step];
            let first = matches!(line.piece, None | Some(0));
            let init = Some(if first { start } else { 0 });
            let (to_work, worked) = *state.entry(line.piece).or_insert((init, init));
            match &line.count {
                LineCount::Counted(c) => {
                    prop_assert!(
                        c.on_needle + c.held_total() + c.set_aside_total().unwrap_or(0)
                            <= MAX_LIVE_STITCHES
                    );
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
                        (StepAction::PickUp { count, .. }, None) => i64::from(*count),
                        (StepAction::ShortRow { decrease: Some(_), .. }, None) => -1,
                        (StepAction::Shape { change, until, groups, .. }, None) => {
                            let per = change * groups.len().max(1) as i64;
                            let before = worked.expect("a counted shaping step works a counted needle");
                            let after = working(c);
                            let d = after as i64 - before as i64;
                            prop_assert!(d % per == 0, "whole repeats: {d} by {per}");
                            match until {
                                ShapeUntil::Times(t) => prop_assert_eq!(d, per * i64::from(*t)),
                                ShapeUntil::Remain(t) => prop_assert_eq!(after, u64::from(*t)),
                            }
                            d
                        }
                        _ => 0,
                    };
                    if let (Some(before), Some(now)) = (prev, total(c)) {
                        prop_assert_eq!(
                            now as i64 - before as i64,
                            added,
                            "{:?} at {}/{}", step.action, line.section, line.step
                        );
                    }
                    // A piece set aside with an unknown count: the next line starts afresh.
                    prev = total(c);
                    state.insert(line.piece, (Some(c.to_work), Some(working(c))));
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
                    state.insert(line.piece, (None, None));
                }
            }
        }
    }

    #[test]
    fn a_piece_s_own_counts_never_pass_the_pattern_s(p in arb_pattern(arb_action().boxed())) {
        for line in &ledger(&p).lines {
            if let LineCount::Counted(c) = &line.count {
                prop_assert!(c.bound_off <= c.bound_off_total);
                prop_assert!(c.grafted <= c.grafted_total);
                if p.pieces.is_empty() {
                    prop_assert_eq!(c.bound_off, c.bound_off_total);
                    prop_assert_eq!(c.grafted, c.grafted_total);
                }
                // Every index a count holds is in its table.
                prop_assert!(c.held.iter().all(|h| h.hold < c.names.holds.len()));
                prop_assert!(c.groups.iter().all(|g| g.name < c.names.groups.len()));
                prop_assert!(c.set_aside.iter().all(|x| x.piece < c.names.pieces.len()));
            }
        }
    }

    #[test]
    fn counts_stay_consistent_with_groups_rounds_and_flat_parts(
        p in arb_pattern(arb_action().boxed())
    ) {
        let l = ledger(&p);
        for line in &l.lines {
            if let LineCount::Counted(c) = &line.count {
                let groups: u64 = c.groups.iter().map(|g| g.count).sum();
                prop_assert!(c.groups.is_empty() || groups == c.on_needle, "{:?}", c);
                prop_assert!(c.groups.iter().all(|g| g.count > 0));
                if let Some(f) = c.flat {
                    prop_assert!(f <= c.on_needle);
                    prop_assert!(!c.in_round, "never both in the round and worked flat");
                }
                prop_assert!(c.to_work <= working(c));
                prop_assert!(c.past_turns <= working(c));
                if c.in_round {
                    prop_assert_eq!(c.past_turns, 0, "no short-row waiting in the round");
                    prop_assert_eq!(c.side, Some(Side::Rs));
                }
            }
        }
    }

    #[test]
    fn removing_more_than_is_left_is_always_an_error(
        p in arb_pattern(arb_plain_action().boxed())
    ) {
        let l = ledger(&p);
        // The last counted line of each piece.
        let mut last: std::collections::HashMap<Option<usize>, Option<NeedleCount>> =
            std::collections::HashMap::new();
        for line in &l.lines {
            let before = last.get(&line.piece).cloned().flatten();
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
                LineCount::Counted(c) => {
                    last.insert(line.piece, Some(c.clone()));
                }
                LineCount::NotCounted => {}
                LineCount::Unknown => {
                    last.insert(line.piece, None);
                }
            }
        }
    }

    #[test]
    fn sections_round_trip_through_the_file(p in arb_pattern(arb_action().boxed())) {
        let text = native::write(&p).unwrap();
        let back = native::read(&text).unwrap();
        prop_assert_eq!(&back.pattern, &p);
        // A current file is decoded into its types without a generic tree, and reads to the same
        // pattern as it does through one.
        let mut tree: serde_json::Value = serde_json::from_str(&text).unwrap();
        let through_tree: KnitPattern = serde_json::from_value(tree["document"].take()).unwrap();
        prop_assert_eq!(&back.pattern, &through_tree);
        prop_assert_eq!(native::write(&back.pattern).unwrap(), text);
    }

    #[test]
    fn an_unknown_step_kind_is_never_dropped(kind in "[A-Z][a-z]{2,10}") {
        prop_assume!(!matches!(
            kind.as_str(),
            "Work" | "Hold" | "Resume" | "Opaque" | "CastOn" | "BindOff" | "ShortRow" | "ChartRows"
                | "JoinRound" | "WorkFlat" | "Rows" | "Shape" | "PickUp" | "Groups" | "Close"
                | "RoundStart" | "Join"
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
