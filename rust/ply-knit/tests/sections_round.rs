//! The stitch ledger for work in the round, parts worked flat, needle groups, pick-ups, shaping and
//! closing (M9-01, second slice): the cases the sock fixtures (`fixtures/knitting/sections/`) do
//! not reach, each worked out by hand.
//!
//! Run: `cargo test -p ply-knit --test sections_round`

use ply_common::{Color, Unit};
use ply_knit::pattern::*;
use ply_knit::sections::*;
use ply_knit::{to_written, validate, Severity};

/// A pattern casting on `cast_on`, with one chart row of `width` knit stitches (no chart when
/// `width` is 0), and `sections`.
fn pat(round: bool, cast_on: Option<u32>, width: usize, sections: Vec<Section>) -> KnitPattern {
    KnitPattern {
        name: "t".into(),
        construction: if round {
            Construction::InTheRound
        } else {
            Construction::Flat
        },
        first_row_side: Side::Rs,
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
            rows: if width == 0 {
                Vec::new()
            } else {
                vec![Row::plain(vec![Cell::of(builtin::KNIT); width])]
            },
        },
        notes: String::new(),
        sections,
        pieces: Vec::new(),
    }
}

fn section(name: &str, steps: Vec<StepAction>) -> Section {
    Section {
        id: format!("s-{name}"),
        name: name.into(),
        notes: String::new(),
        construction: None,
        piece: None,
        steps: steps
            .into_iter()
            .enumerate()
            .map(|(i, action)| Step {
                id: format!("{name}-{}", i + 1),
                action,
            })
            .collect(),
    }
}

fn lines(p: &KnitPattern) -> Vec<String> {
    ledger(p).lines.iter().map(LedgerLine::written).collect()
}

fn problems(p: &KnitPattern) -> Vec<(Severity, String)> {
    ledger(p)
        .issues
        .into_iter()
        .map(|i| (i.severity, i.message))
        .collect()
}

fn work(stitch: WorkStitch, to: WorkTo) -> StepAction {
    StepAction::Work {
        stitch,
        to,
        resolve_turns: false,
    }
}

fn groups(g: &[(&str, u32)]) -> StepAction {
    StepAction::Groups {
        groups: g
            .iter()
            .map(|&(name, count)| NeedleGroup {
                name: name.into(),
                count,
                notes: String::new(),
            })
            .collect(),
    }
}

fn flat(count: u32) -> StepAction {
    StepAction::WorkFlat {
        count,
        name: "heel".into(),
        slip_edges: false,
    }
}

use WorkStitch::{Knit, Purl};

#[test]
fn a_cast_on_step_in_a_round_pattern_is_joined_into_the_round() {
    let p = pat(
        true,
        None,
        0,
        vec![section(
            "Cuff",
            vec![
                StepAction::CastOn { count: 64 },
                work(Knit, WorkTo::End),
                StepAction::CastOn { count: 2 },
            ],
        )],
    );
    assert_eq!(
        lines(&p),
        vec![
            "Cast on 64 sts and join to work in the round, being careful not to twist. (64 sts on the needle)",
            "Next rnd: knit to end. (64 sts on the needle)",
            "Cast on 2 sts at the start of the rnd. (66 sts on the needle)",
        ]
    );
    assert!(problems(&p).is_empty(), "{:?}", problems(&p));
}

#[test]
fn chart_rounds_are_refused_in_flat_work_and_partway_through_a_round() {
    let p = pat(
        true,
        Some(8),
        8,
        vec![section(
            "Heel",
            vec![
                work(Knit, WorkTo::Count(3)),
                StepAction::ChartRows { first: 1, last: 1 },
                work(Knit, WorkTo::End),
                flat(4),
                StepAction::ChartRows { first: 1, last: 1 },
            ],
        )],
    );
    let l = ledger(&p);
    assert_eq!(l.lines[1].count, LineCount::NotCounted);
    assert_eq!(l.lines[4].count, LineCount::NotCounted);
    assert_eq!(
        problems(&p),
        vec![
            (
                Severity::Error,
                "Heel, step 2, chart row 1: a chart round has to start at the beginning of a \
                 round, but this round is already started (5 stitches still to work in it)"
                    .to_string()
            ),
            (
                Severity::Error,
                "Heel, step 5, chart row 1: the chart is for working in the round, but the work \
                 is flat here; use knit, purl or row steps for the part worked flat"
                    .to_string()
            ),
            (
                Severity::Warning,
                "Heel, step 4: 4 stitches are still resting on the needle at the end of the \
                 pattern; no step joins them back into the round"
                    .to_string()
            ),
        ]
    );
}

#[test]
fn picking_up_or_shaping_past_the_stitch_cap_is_refused() {
    let p = pat(
        true,
        Some(999_990),
        0,
        vec![section(
            "Big",
            vec![
                StepAction::PickUp {
                    count: 11,
                    along: PickUpAlong::Edge("the edge".into()),
                    group: None,
                },
                StepAction::Shape {
                    change: 1,
                    every: 1,
                    until: ShapeUntil::Times(11),
                    groups: Vec::new(),
                    text: String::new(),
                },
                StepAction::Shape {
                    change: 1,
                    every: 1,
                    until: ShapeUntil::Times(10),
                    groups: Vec::new(),
                    text: String::new(),
                },
            ],
        )],
    );
    let l = ledger(&p);
    assert_eq!(l.lines[0].count, LineCount::NotCounted);
    assert_eq!(l.lines[1].count, LineCount::NotCounted);
    assert_eq!(
        l.lines[2].count.counted().unwrap().on_needle,
        1_000_000,
        "up to the cap is fine"
    );
    let texts: Vec<&str> = l.issues.iter().map(|i| i.text.as_str()).collect();
    assert_eq!(
        texts,
        vec![
            "has too many stitches to count",
            "has too many stitches to count"
        ]
    );
}

#[test]
fn joining_flat_work_whose_right_side_rows_travel_the_other_way_keeps_its_wraps() {
    // First row WS: right-side rows travel toward stitch 1. A wrap-and-turn on a RS row leaves a
    // wrap on the first stitch past the turn; after the join the first full round works it.
    let mut p = pat(
        false,
        Some(10),
        0,
        vec![section(
            "Hem",
            vec![
                work(Purl, WorkTo::End),
                StepAction::ShortRow {
                    stitch: Knit,
                    to: TurnAt::Last(4),
                    method: TurnMethod::WrapAndTurn,
                    resolve_turns: false,
                    decrease: None,
                },
                work(Purl, WorkTo::End),
                StepAction::JoinRound {},
                StepAction::Work {
                    stitch: Knit,
                    to: WorkTo::End,
                    resolve_turns: true,
                },
            ],
        )],
    );
    p.first_row_side = Side::Ws;
    assert_eq!(
        lines(&p),
        vec![
            "Next row (WS): purl to end. (10 sts on the needle)",
            "Short row 1 (RS): knit to last 4 sts, wrap and turn. (10 sts on the needle, 4 waiting past a turn)",
            "Short row 2 (WS): purl to end. (10 sts on the needle, 4 waiting past a turn)",
            "Join to work in the round, being careful not to twist. (10 sts on the needle)",
            "Next rnd: knit to end, working each wrap together with its stitch. (10 sts on the needle)",
        ]
    );
    assert!(problems(&p).is_empty(), "{:?}", problems(&p));
    let l = ledger(&p);
    assert_eq!(l.lines[3].count.counted().unwrap().pending_turns, 1);
    assert_eq!(l.lines[4].count.counted().unwrap().pending_turns, 0);
}

#[test]
fn shaping_flat_rows_ends_on_the_side_its_row_count_says() {
    let shape = |every, times| StepAction::Shape {
        change: -1,
        every,
        until: ShapeUntil::Times(times),
        groups: Vec::new(),
        text: "k1, ssk, knit to end".into(),
    };
    let p = pat(
        false,
        Some(20),
        0,
        vec![section("Front", vec![shape(1, 3), shape(4, 2)])],
    );
    assert_eq!(
        lines(&p),
        vec![
            "Next 3 rows (first row RS): decrease 1 st in every row, 3 times in all; each \
             decrease row: k1, ssk, knit to end. (17 sts on the needle)",
            "Next 8 rows (first row WS): decrease 1 st in the first row and then every 4th row, \
             2 times in all; each decrease row: k1, ssk, knit to end. (15 sts on the needle)",
        ]
    );
    let l = ledger(&p);
    assert_eq!(l.lines[0].count.counted().unwrap().side, Some(Side::Ws));
    assert_eq!(l.lines[1].count.counted().unwrap().side, Some(Side::Ws));
}

#[test]
fn closing_without_groups_divides_the_stitches_in_half_or_binds_them_off() {
    let p = pat(
        true,
        Some(16),
        0,
        vec![section(
            "Toe",
            vec![StepAction::Close {
                method: CloseMethod::Graft,
                holds: Vec::new(),
            }],
        )],
    );
    assert_eq!(
        lines(&p),
        vec![
            "Divide the 16 sts evenly onto two needles (8 on each) and graft them together with \
             Kitchener stitch. (0 sts on the needle; 16 grafted)"
        ]
    );
    let p = pat(
        false,
        Some(12),
        0,
        vec![section(
            "Shoulders",
            vec![
                groups(&[("left", 6), ("right", 6)]),
                StepAction::Close {
                    method: CloseMethod::ThreeNeedleBindOff,
                    holds: Vec::new(),
                },
            ],
        )],
    );
    assert_eq!(
        lines(&p)[1],
        "With the right sides together, bind off the 6 left sts and the 6 right sts together \
         with a three-needle bind-off. (0 sts on the needle; 12 bound off)"
    );
}

#[test]
fn a_turn_to_the_gap_names_the_wrapped_stitch() {
    let p = pat(
        false,
        Some(12),
        0,
        vec![section(
            "Heel",
            vec![
                StepAction::ShortRow {
                    stitch: Knit,
                    to: TurnAt::Last(3),
                    method: TurnMethod::WrapAndTurn,
                    resolve_turns: false,
                    decrease: None,
                },
                StepAction::ShortRow {
                    stitch: Purl,
                    to: TurnAt::Last(3),
                    method: TurnMethod::WrapAndTurn,
                    resolve_turns: false,
                    decrease: None,
                },
                StepAction::ShortRow {
                    stitch: Knit,
                    to: TurnAt::BeforeGap(0),
                    method: TurnMethod::Unspecified,
                    resolve_turns: false,
                    decrease: None,
                },
            ],
        )],
    );
    assert_eq!(
        lines(&p)[2],
        "Short row 3 (RS): knit to the wrapped stitch, turn. (12 sts on the needle, 6 waiting \
         past a turn)",
        "the wrap is on the first stitch past the gap; the row stops before it"
    );
}

#[test]
fn held_stitches_go_back_into_their_needle_groups() {
    let p = pat(
        true,
        Some(20),
        0,
        vec![section(
            "Thumb",
            vec![
                groups(&[("palm", 12), ("back", 8)]),
                work(Knit, WorkTo::Count(2)),
                StepAction::Hold {
                    count: Some(4),
                    name: "thumb".into(),
                },
                StepAction::CastOn { count: 4 },
                work(Knit, WorkTo::End),
                StepAction::Resume {
                    hold: "Thumb-3".into(),
                    facing: None,
                },
            ],
        )],
    );
    let l = lines(&p);
    assert_eq!(
        l[2],
        "Place the next 4 sts on a holder (thumb). (16 sts on the needle: 8 palm, 8 back; 14 \
         still to work in this rnd; 4 on hold)"
    );
    assert_eq!(
        l[3],
        "Cast on 4 sts onto the right needle, over the gap left by the stitches on hold \
         (thumb). (20 sts on the needle: 12 palm, 8 back; 14 still to work in this rnd; 4 on \
         hold)"
    );
    assert_eq!(
        l[5],
        "Return the 4 sts on hold (thumb) to the left needle. (24 sts on the needle: 16 palm, 8 \
         back)",
        "they were palm stitches, so they go back into the palm"
    );
}

#[test]
fn sections_say_how_they_are_worked_in_the_written_instructions() {
    let mut p = pat(
        true,
        Some(8),
        0,
        vec![
            section("Leg", vec![work(Knit, WorkTo::End)]),
            section("", vec![flat(4)]),
        ],
    );
    p.sections[0].construction = Some(Construction::InTheRound);
    p.sections[1].construction = Some(Construction::Flat);
    let w = to_written(&p);
    assert_eq!(w[1], "Section 1: Leg (worked in the round)");
    assert_eq!(w[3], "Section 2 (worked flat)");
}

#[test]
fn an_unknown_count_leaves_every_new_step_unknown() {
    let p = pat(
        true,
        Some(8),
        0,
        vec![section(
            "Foot",
            vec![
                StepAction::Opaque {
                    text: "Work the pattern.".into(),
                    stitch_change: None,
                },
                StepAction::JoinRound {},
                flat(4),
                StepAction::Rows {
                    count: 4,
                    text: "knit".into(),
                },
                StepAction::Shape {
                    change: -2,
                    every: 2,
                    until: ShapeUntil::Remain(4),
                    groups: vec!["sole".into()],
                    text: String::new(),
                },
                StepAction::PickUp {
                    count: 3,
                    along: PickUpAlong::Edge("the edge".into()),
                    group: None,
                },
                groups(&[("a", 4)]),
                StepAction::Close {
                    method: CloseMethod::Graft,
                    holds: Vec::new(),
                },
            ],
        )],
    );
    let l = ledger(&p);
    assert!(l.lines[1..]
        .iter()
        .all(|line| line.count == LineCount::Unknown && line.label.is_none()));
    assert_eq!(l.issues.len(), 1, "one warning, nothing checked after it");
    assert_eq!(
        l.lines[3].written(),
        "Work 4 rnds: knit. (stitch count unknown)"
    );
}

#[test]
fn a_part_worked_flat_that_runs_out_of_stitches_says_so_and_can_rejoin() {
    let p = pat(
        true,
        Some(10),
        0,
        vec![section(
            "Heel",
            vec![
                flat(4),
                StepAction::BindOff {
                    count: None,
                    resolve_turns: false,
                },
                work(Knit, WorkTo::End),
                StepAction::JoinRound {},
            ],
        )],
    );
    let l = ledger(&p);
    assert_eq!(
        l.lines[1].written(),
        "Next row (RS): bind off all sts. (6 sts on the needle; 0 worked flat, 6 resting; 4 \
         bound off)"
    );
    assert_eq!(
        l.issues[0].text,
        "there are no stitches left in the part worked flat; join the work back into the round \
         to work the 6 stitches resting there"
    );
    assert_eq!(
        l.lines[3].written(),
        "Join to work in the round again over all 6 sts. (6 sts on the needle; 4 bound off)"
    );
}

#[test]
fn files_past_the_new_size_limits_are_named() {
    let mut p = pat(true, Some(8), 4, vec![section("S", vec![])]);
    p.sections[0].steps.push(Step {
        id: "x".into(),
        action: StepAction::Shape {
            change: -(MAX_LIVE_STITCHES as i64) - 1,
            every: 1,
            until: ShapeUntil::Times(1),
            groups: Vec::new(),
            text: String::new(),
        },
    });
    assert!(check_limits(&p)
        .unwrap_err()
        .to_string()
        .starts_with("a shaping step changes the stitch count by"));
    p.sections[0].steps[0].action = StepAction::Rows {
        count: 1,
        text: "t".repeat(MAX_TEXT_BYTES + 1),
    };
    assert!(check_limits(&p)
        .unwrap_err()
        .to_string()
        .contains("longer than"));
    p.sections[0].steps[0].action = StepAction::Groups {
        groups: (0..=MAX_GROUPS)
            .map(|i| NeedleGroup {
                name: format!("g{i}"),
                count: 1,
                notes: String::new(),
            })
            .collect(),
    };
    assert!(check_limits(&p)
        .unwrap_err()
        .to_string()
        .contains("needle groups"));
    p.sections[0].steps[0].action = StepAction::PickUp {
        count: 1,
        along: PickUpAlong::Edge("e".repeat(MAX_TEXT_BYTES + 1)),
        group: None,
    };
    assert!(check_limits(&p).is_err());
}

#[test]
fn validation_reports_the_round_ledger() {
    let p = pat(
        true,
        Some(8),
        4,
        vec![section("Toe", vec![StepAction::JoinRound {}])],
    );
    let issues: Vec<String> = validate(&p).into_iter().map(|i| i.message).collect();
    assert_eq!(
        issues,
        vec![
            "Toe, step 1: the work is already in the round",
            "no section works any of the chart's rows, so the written instructions leave the \
             chart out",
        ]
    );
}

#[test]
fn shaping_a_part_worked_flat_keeps_its_one_group_and_the_resting_ones() {
    let p = pat(
        true,
        Some(20),
        0,
        vec![section(
            "Heel",
            vec![
                groups(&[("sole", 10), ("instep", 10)]),
                flat(10),
                StepAction::Shape {
                    change: -1,
                    every: 2,
                    until: ShapeUntil::Times(2),
                    groups: Vec::new(),
                    text: String::new(),
                },
                StepAction::Opaque {
                    text: "Increase 1 st.".into(),
                    stitch_change: Some(1),
                },
            ],
        )],
    );
    assert_eq!(
        lines(&p)[2..],
        [
            "Next 4 rows (first row RS): decrease 1 st in the first row and then every other \
             row, 2 times in all. (18 sts on the needle: 8 sole, 10 instep; 8 worked flat, 10 \
             resting)",
            "Not checked by Ply: Increase 1 st. (19 sts on the needle: 9 sole, 10 instep; 9 \
             worked flat, 10 resting)",
        ],
        "the flat part is all sole, so the change is the sole's"
    );
    let warnings = problems(&p);
    assert_eq!(warnings.len(), 1, "{warnings:?}");
    assert!(warnings[0].1.contains("still resting on the needle"));
}

// --- review fixes -------------------------------------------------------------------------------

fn round_start() -> StepAction {
    StepAction::RoundStart {}
}

fn hold_n(count: u32, name: &str) -> StepAction {
    StepAction::Hold {
        count: Some(count),
        name: name.into(),
    }
}

fn shape_on(group: &str, times: u32) -> StepAction {
    StepAction::Shape {
        change: -1,
        every: 1,
        until: ShapeUntil::Times(times),
        groups: vec![group.into()],
        text: String::new(),
    }
}

#[test]
fn a_flat_part_over_every_stitch_keeps_its_groups_when_it_rejoins() {
    let p = pat(
        true,
        Some(8),
        0,
        vec![section(
            "Tube",
            vec![
                groups(&[("front", 4), ("back", 4)]),
                flat(8),
                StepAction::Rows {
                    count: 2,
                    text: "knit".into(),
                },
                StepAction::JoinRound {},
                shape_on("front", 1),
            ],
        )],
    );
    let l = lines(&p);
    assert_eq!(
        l[3],
        "Join to work in the round again over all 8 sts. (8 sts on the needle: 4 front, 4 back)"
    );
    assert_eq!(
        l[4],
        "Next rnd: decrease 1 st on the front (7 sts). (7 sts on the needle: 3 front, 4 back)"
    );
    assert!(problems(&p).is_empty(), "{:?}", problems(&p));
}

#[test]
fn a_cast_on_over_a_gap_takes_the_place_of_the_held_stitches_in_their_group() {
    let p = pat(
        true,
        Some(32),
        0,
        vec![section(
            "Thumb",
            vec![
                groups(&[("back", 16), ("palm", 16)]),
                work(Knit, WorkTo::Count(16)),
                hold_n(6, "thumb"),
                StepAction::CastOn { count: 6 },
            ],
        )],
    );
    assert_eq!(
        lines(&p)[3],
        "Cast on 6 sts onto the right needle, over the gap left by the stitches on hold (thumb). \
         (32 sts on the needle: 16 back, 16 palm; 10 still to work in this rnd; 6 on hold)",
        "the gap is between the back and the palm, but the held stitches were palm stitches"
    );
    // Held from both groups at once: Ply cannot tell which group the new stitches are in.
    let p = pat(
        true,
        Some(32),
        0,
        vec![section(
            "Thumb",
            vec![
                groups(&[("back", 16), ("palm", 16)]),
                work(Knit, WorkTo::Count(14)),
                hold_n(4, "thumb"),
                StepAction::CastOn { count: 4 },
            ],
        )],
    );
    assert_eq!(
        lines(&p)[3],
        "Cast on 4 sts onto the right needle, over the gap left by the stitches on hold (thumb). \
         (32 sts on the needle, 14 still to work in this rnd; 4 on hold)"
    );
    assert_eq!(
        problems(&p)[0].1,
        "Thumb, step 4: this step casts on over a gap left by stitches from more than one needle \
         group, so Ply cannot tell how the change falls between the needle groups (back, palm); it \
         stops counting the groups here (divide the stitches into groups again to count them)"
    );
}

#[test]
fn stitches_added_between_two_groups_stop_the_group_counts_instead_of_guessing() {
    // At the start of the round the last stitch is a palm stitch and the first a back one.
    let p = pat(
        true,
        Some(8),
        0,
        vec![section(
            "Cuff",
            vec![
                groups(&[("back", 4), ("palm", 4)]),
                StepAction::CastOn { count: 2 },
            ],
        )],
    );
    assert_eq!(
        lines(&p)[1],
        "Cast on 2 sts at the start of the rnd. (10 sts on the needle)"
    );
    assert!(problems(&p)[0]
        .1
        .starts_with("Cuff, step 2: this step casts on stitches between two needle groups"));
    // At the edge of flat work there is one neighbour, so its group is the one.
    let p = pat(
        false,
        Some(8),
        0,
        vec![section(
            "Edge",
            vec![
                groups(&[("left", 4), ("right", 4)]),
                StepAction::CastOn { count: 2 },
            ],
        )],
    );
    assert_eq!(
        lines(&p)[1],
        "Cast on 2 sts at the start of the row. (10 sts on the needle: 6 left, 4 right)"
    );
    assert!(problems(&p).is_empty());
}

#[test]
fn stitches_held_before_the_groups_were_set_are_not_guessed_into_one() {
    let p = pat(
        true,
        Some(10),
        0,
        vec![section(
            "Thumb",
            vec![
                hold_n(2, "thumb"),
                work(Knit, WorkTo::End),
                groups(&[("a", 4), ("b", 4)]),
                StepAction::Resume {
                    hold: "Thumb-1".into(),
                    facing: None,
                },
            ],
        )],
    );
    assert_eq!(
        lines(&p)[3],
        "Return the 2 sts on hold (thumb) to the left needle. (10 sts on the needle)"
    );
    // Holding the first stitches of a round leaves a gap at the start of the round, which the
    // rest of the round crosses (ADR 0020 review).
    assert_eq!(
        problems(&p)[0],
        (
            Severity::Warning,
            "Thumb, step 2: works across the gap left by the stitches put on hold (thumb), which \
             joins the two sides with a strand of yarn; cast on over the gap, or put one side on \
             hold to work the sides separately"
                .to_string()
        )
    );
    assert_eq!(
        problems(&p)[1..],
        vec![(
            Severity::Warning,
            "Thumb, step 4: these stitches were put on hold before the stitches were divided into \
             needle groups, so Ply cannot tell how the change falls between the needle groups (a, \
             b); it stops counting the groups here (divide the stitches into groups again to count \
             them)"
                .to_string()
        )]
    );
}

#[test]
fn a_german_turn_right_after_a_decrease_must_leave_two_stitches() {
    let german = |last, after| StepAction::ShortRow {
        stitch: Knit,
        to: TurnAt::Last(last),
        method: TurnMethod::German,
        resolve_turns: false,
        decrease: Some(TurnDecrease {
            kind: Decrease::Ssk,
            after,
        }),
    };
    // The reviewer's case: knit to last 6 of 6, ssk, turn leaves the next row only the double
    // stitch.
    let p = pat(false, Some(6), 0, vec![section("S", vec![german(6, 0)])]);
    assert_eq!(ledger(&p).lines[0].count, LineCount::NotCounted);
    assert!(problems(&p)[0]
        .1
        .contains("turns too soon for a German short row"));
    let p = pat(false, Some(8), 0, vec![section("S", vec![german(4, 1)])]);
    assert_eq!(
        lines(&p)[0],
        "Short row 1 (RS): knit to last 4 sts, ssk, k1, turn, then make a double stitch. (7 sts \
         on the needle, 1 waiting past a turn)",
        "4 knit, the ssk and the k1 leave 6 stitches for the next row"
    );
}

#[test]
fn the_start_of_the_round_moves_and_a_side_is_found_partway_through_a_round() {
    let pick = |count| StepAction::PickUp {
        count,
        along: PickUpAlong::Piece("Heel-1".into()),
        group: None,
    };
    let p = pat(
        true,
        Some(16),
        0,
        vec![section(
            "Heel",
            vec![
                StepAction::WorkFlat {
                    count: 8,
                    name: "heel flap".into(),
                    slip_edges: true,
                },
                StepAction::Rows {
                    count: 4,
                    text: "sl 1, k to end".into(),
                },
                work(Knit, WorkTo::End),
                StepAction::JoinRound {},
                work(Knit, WorkTo::End),
                work(Knit, WorkTo::Count(4)),
                round_start(),
                work(Knit, WorkTo::Count(4)),
                pick(2),
                work(Knit, WorkTo::Count(8)),
                pick(3),
                work(Knit, WorkTo::End),
            ],
        )],
    );
    let l = lines(&p);
    assert_eq!(
        l[6],
        "The rnd now starts here (move the marker for the start of the rnd). (16 sts on the \
         needle)"
    );
    // The flap's left side (after its last stitch) was 4 sts into the moved round; its right
    // side 12 sts in, then 14 once 2 sts are picked up before it. Five whole rows were worked
    // (the 4, then knit to end): 3 started at the right edge, 2 at the left.
    assert_eq!(
        l[8],
        "Pick up and knit 2 sts along the left side of the heel flap (it has 2 slipped edge sts \
         on this side). (18 sts on the needle, 12 still to work in this rnd)"
    );
    assert_eq!(
        l[10],
        "Pick up and knit 3 sts along the right side of the heel flap (it has 3 slipped edge sts \
         on this side). (21 sts on the needle, 4 still to work in this rnd)"
    );
    assert!(problems(&p).is_empty(), "{:?}", problems(&p));
}

#[test]
fn moving_the_start_of_the_round_is_refused_in_flat_work_and_where_it_already_is() {
    let p = pat(true, Some(8), 0, vec![section("R", vec![round_start()])]);
    assert_eq!(
        problems(&p)[0].1,
        "R, step 1: moves the start of the round to where it already is; work to where the new \
         start should be first"
    );
    let p = pat(
        false,
        Some(8),
        0,
        vec![section(
            "F",
            vec![work(Knit, WorkTo::Count(2)), round_start()],
        )],
    );
    assert_eq!(
        problems(&p)[0].1,
        "F, step 2: moves the start of the round, but the work is flat; only a round has a start"
    );
    // Moving it keeps the needle groups and their stitches.
    let p = pat(
        true,
        Some(8),
        0,
        vec![section(
            "R",
            vec![
                groups(&[("a", 4), ("b", 4)]),
                work(Knit, WorkTo::Count(2)),
                round_start(),
            ],
        )],
    );
    assert_eq!(
        lines(&p)[2],
        "The rnd now starts here (move the marker for the start of the rnd). (8 sts on the \
         needle: 4 a, 4 b)",
        "the 2 a stitches before the new start now end the round; the group is still 4"
    );
    let c = ledger(&p).lines[2].count.counted().unwrap().clone();
    assert_eq!(
        c.groups
            .iter()
            .map(|g| (c.group_name(g), g.count))
            .collect::<Vec<_>>(),
        vec![("a", 4), ("b", 4)]
    );
}

#[test]
fn a_flat_part_turned_from_a_wrong_side_first_pattern_still_rejoins() {
    for refill in [
        vec![StepAction::CastOn { count: 4 }],
        vec![
            StepAction::Hold {
                count: None,
                name: "flap".into(),
            },
            StepAction::Resume {
                hold: "Heel-2".into(),
                facing: Some(Side::Rs),
            },
        ],
    ] {
        let mut steps = vec![flat(4), work(Knit, WorkTo::Count(1))];
        // Empty the flat part, then fill it again (cast on, or return held stitches).
        if matches!(refill[0], StepAction::CastOn { .. }) {
            steps[1] = StepAction::BindOff {
                count: None,
                resolve_turns: false,
            };
        } else {
            steps.pop();
        }
        steps.extend(refill);
        steps.push(StepAction::Rows {
            count: 2,
            text: "knit".into(),
        });
        steps.push(StepAction::JoinRound {});
        let mut p = pat(true, Some(8), 0, vec![section("Heel", steps)]);
        p.first_row_side = Side::Ws;
        let l = ledger(&p);
        assert!(
            l.issues.iter().all(|i| i.severity == Severity::Warning),
            "{:?}",
            l.issues
        );
        let last = l.lines.last().unwrap();
        assert!(
            last.text.starts_with("Join to work in the round again"),
            "{last:?}"
        );
        assert!(last.count.counted().unwrap().in_round);
    }
}

#[test]
fn a_gap_among_the_resting_stitches_is_still_there_when_they_rejoin() {
    // Flat: a short row turns, then stitches go on hold at the turn, leaving a gap behind the
    // yarn; the work is joined in the round and part of it worked flat. Working across the gap
    // after the part rejoins is warned about, as it would be without the flat part.
    let p = pat(
        false,
        Some(10),
        0,
        vec![section(
            "Neck",
            vec![
                StepAction::ShortRow {
                    stitch: Knit,
                    to: TurnAt::Last(4),
                    method: TurnMethod::Unspecified,
                    resolve_turns: false,
                    decrease: None,
                },
                hold_n(2, "neck"),
                work(Purl, WorkTo::End),
                StepAction::JoinRound {},
                flat(2),
                StepAction::Rows {
                    count: 2,
                    text: "knit".into(),
                },
                StepAction::JoinRound {},
                work(Knit, WorkTo::End),
            ],
        )],
    );
    let warned: Vec<String> = problems(&p).into_iter().map(|(_, m)| m).collect();
    assert!(
        warned.iter().any(|m| m.starts_with(
            "Neck, step 8: works across the gap left by the stitches put on hold (neck)"
        )),
        "{warned:?}"
    );
}

#[test]
fn closing_at_a_short_row_turn_is_refused() {
    let p = pat(
        false,
        Some(8),
        0,
        vec![section(
            "Toe",
            vec![
                StepAction::ShortRow {
                    stitch: Knit,
                    to: TurnAt::Last(2),
                    method: TurnMethod::Unspecified,
                    resolve_turns: false,
                    decrease: None,
                },
                StepAction::Close {
                    method: CloseMethod::Graft,
                    holds: Vec::new(),
                },
            ],
        )],
    );
    assert_eq!(ledger(&p).lines[1].count, LineCount::NotCounted);
    assert_eq!(
        problems(&p)[0].1,
        "Toe, step 2: closes the stitches at a short-row turn, with 2 stitches still waiting past \
         a turn; work to the end of the row first"
    );
}

#[test]
fn a_side_with_no_whole_rows_has_no_slipped_edge_stitch_note() {
    let p = pat(
        true,
        Some(8),
        0,
        vec![section(
            "Heel",
            vec![
                StepAction::WorkFlat {
                    count: 4,
                    name: "heel flap".into(),
                    slip_edges: true,
                },
                work(Knit, WorkTo::End),
                StepAction::PickUp {
                    count: 2,
                    along: PickUpAlong::Piece("Heel-1".into()),
                    group: None,
                },
            ],
        )],
    );
    assert_eq!(
        lines(&p)[2],
        "Pick up and knit 2 sts along the left side of the heel flap. (10 sts on the needle; 6 \
         worked flat, 4 resting)",
        "one right-side row: 1 slipped stitch on the right side, none on the left"
    );
}

#[test]
fn a_chart_row_in_a_flat_part_counts_the_resting_stitches_against_the_cap() {
    let mut p = pat(
        false,
        Some(1_000_000),
        2,
        vec![section(
            "Big",
            vec![
                StepAction::JoinRound {},
                flat(2),
                StepAction::ChartRows { first: 1, last: 1 },
            ],
        )],
    );
    p.chart.rows[0] = Row::plain(vec![Cell::of(builtin::KFB); 2]);
    let l = ledger(&p);
    assert_eq!(l.lines[2].count, LineCount::NotCounted);
    assert!(l
        .issues
        .iter()
        .any(|i| i.text == "has too many stitches to count"));
}
