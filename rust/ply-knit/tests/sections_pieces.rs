//! The stitch ledger across several pieces (M9-01, third slice, ADR 0020): the cases the garment
//! fixtures (`fixtures/knitting/sections/`) do not reach, each worked out by hand.
//!
//! Run: `cargo test -p ply-knit --test sections_pieces`

use ply_common::{Color, Unit};
use ply_knit::pattern::*;
use ply_knit::sections::*;
use ply_knit::{to_written, Severity};

/// A pattern casting on `cast_on` for its first piece, with no chart, the pieces `names` (ids
/// `p1`, `p2`, ...) and `sections`.
fn pat(
    round: bool,
    first: Side,
    cast_on: Option<u32>,
    names: &[&str],
    sections: Vec<Section>,
) -> KnitPattern {
    KnitPattern {
        name: "t".into(),
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
            width: 0,
            rows: Vec::new(),
        },
        notes: String::new(),
        sections,
        pieces: names
            .iter()
            .enumerate()
            .map(|(i, n)| Piece {
                id: format!("p{}", i + 1),
                name: n.to_string(),
            })
            .collect(),
    }
}

/// A section working piece `piece` (`None`: the first), its steps numbered `<name>-1`, ...
fn section(name: &str, piece: Option<&str>, steps: Vec<StepAction>) -> Section {
    Section {
        id: format!("s-{name}"),
        name: name.into(),
        notes: String::new(),
        construction: None,
        piece: piece.map(str::to_string),
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

fn cast_on(count: u32) -> StepAction {
    StepAction::CastOn { count }
}

fn join_piece(id: &str) -> StepAction {
    StepAction::Join {
        source: JoinSource::Piece(id.into()),
        stitch: WorkStitch::Knit,
        resolve_turns: false,
    }
}

fn join_held(id: &str, resolve_turns: bool) -> StepAction {
    StepAction::Join {
        source: JoinSource::Held(id.into()),
        stitch: WorkStitch::Knit,
        resolve_turns,
    }
}

fn hold_rest(name: &str) -> StepAction {
    StepAction::Hold {
        count: None,
        name: name.into(),
    }
}

use WorkStitch::{Knit, Purl};

#[test]
fn a_join_at_the_start_of_a_round_ends_that_round() {
    // The sleeve's 6 sts follow the body's last stitch: the next round starts with the body's.
    let p = pat(
        true,
        Side::Rs,
        None,
        &["Body", "Sleeve"],
        vec![
            section("Body", None, vec![cast_on(10)]),
            section("Sleeve", Some("p2"), vec![cast_on(6)]),
            section(
                "Yoke",
                Some("p1"),
                vec![join_piece("p2"), work(Knit, WorkTo::Count(10))],
            ),
        ],
    );
    assert_eq!(
        lines(&p),
        [
            "Cast on 10 sts and join to work in the round, being careful not to twist. (10 sts on \
             the needle)",
            "Cast on 6 sts and join to work in the round, being careful not to twist. (6 sts on the \
             needle; set aside: Body 10)",
            "Knit across the 6 sts of Sleeve, joining it to Body, before the marker for the start of the \
             rnd (the rnd now starts after them). (16 sts on the needle)",
            "Next rnd: knit 10 sts. (16 sts on the needle, 6 still to work in this rnd)",
        ]
    );
    assert_eq!(
        problems(&p),
        [(
            Severity::Warning,
            "Yoke: ends part way through a round, with 6 stitches still to work in it".into()
        )]
    );
    let l = ledger(&p);
    assert_eq!(l.pieces[1].joined, Some((0, 2, 0)));
    assert_eq!(l.pieces[1].text, "joined to Body at Yoke, step 1");
    assert_eq!(l.pieces[0].text, "16 sts left on the needle at the end");
    assert_eq!(l.lines[2].piece, Some(0));
}

#[test]
fn a_join_at_the_start_of_a_right_side_row_starts_the_row() {
    let p = pat(
        false,
        Side::Rs,
        Some(8),
        &["Body", "Strap"],
        vec![
            section("Strap", Some("p2"), vec![cast_on(4)]),
            section(
                "Body",
                None,
                vec![join_piece("p2"), work(Knit, WorkTo::End)],
            ),
        ],
    );
    assert_eq!(
        lines(&p),
        [
            "Cast on 4 sts. (4 sts on the needle; set aside: Body 8)",
            "Next row (RS): knit across the 4 sts of Strap, joining it to Body. (12 sts on \
             the needle, 8 still to work in this row)",
            "Knit to end. (12 sts on the needle)",
        ]
    );
    assert!(problems(&p).is_empty(), "{:?}", problems(&p));
}

#[test]
fn a_flat_piece_is_joined_partway_through_a_right_side_row() {
    let p = pat(
        false,
        Side::Rs,
        Some(10),
        &["Body", "Pocket"],
        vec![
            section("Pocket", Some("p2"), vec![cast_on(3)]),
            section(
                "Body",
                None,
                vec![
                    work(Knit, WorkTo::Count(5)),
                    join_piece("p2"),
                    work(Knit, WorkTo::End),
                ],
            ),
        ],
    );
    assert_eq!(
        lines(&p),
        [
            "Cast on 3 sts. (3 sts on the needle; set aside: Body 10)",
            "Next row (RS): knit 5 sts. (10 sts on the needle, 5 still to work in this row; set \
             aside: Pocket 3)",
            "Knit across the 3 sts of Pocket, joining it to Body. (13 sts on the needle, 5 still to \
             work in this row)",
            "Knit to end. (13 sts on the needle)",
        ]
    );
}

#[test]
fn a_piece_with_part_worked_flat_cannot_be_joined() {
    let p = pat(
        true,
        Side::Rs,
        None,
        &["Body", "Sleeve"],
        vec![
            section(
                "Sleeve",
                Some("p2"),
                vec![
                    cast_on(8),
                    StepAction::WorkFlat {
                        count: 4,
                        name: "gusset".into(),
                        slip_edges: false,
                    },
                ],
            ),
            section("Body", None, vec![cast_on(10), join_piece("p2")]),
        ],
    );
    let l = ledger(&p);
    assert_eq!(l.lines[3].count, LineCount::NotCounted);
    assert!(problems(&p).contains(&(
        Severity::Error,
        "Body, step 2: part of Sleeve is still worked flat; join it back into the round in its \
         own section first"
            .into()
    )));
}

#[test]
fn held_stitches_join_with_their_needle_groups_in_right_side_order() {
    // First row WS: rows from stitch 1 toward stitch 6 are wrong-side rows, so knitting the held
    // stitches from the right side meets the groups the other way round.
    let groups = StepAction::Groups {
        groups: ["left", "mid", "right"]
            .iter()
            .map(|n| NeedleGroup {
                name: n.to_string(),
                count: 2,
                notes: String::new(),
            })
            .collect(),
    };
    let p = pat(
        false,
        Side::Ws,
        Some(6),
        &["Body", "Band"],
        vec![
            section(
                "Body",
                None,
                vec![groups, work(Purl, WorkTo::End), hold_rest("top")],
            ),
            section("Band", Some("p2"), vec![join_held("Body-3", false)]),
        ],
    );
    let got = lines(&p);
    assert_eq!(
        got[3],
        "With the RS facing, join the yarn and knit the 6 sts on hold (top). (6 sts on the needle: \
         2 right, 2 mid, 2 left)"
    );
    assert!(problems(&p).is_empty(), "{:?}", problems(&p));
}

#[test]
fn a_join_works_the_wraps_among_the_stitches_when_it_says_so() {
    let build = |resolve: bool| {
        pat(
            false,
            Side::Rs,
            Some(10),
            &["Body", "Collar"],
            vec![
                section(
                    "Body",
                    None,
                    vec![
                        StepAction::ShortRow {
                            stitch: Knit,
                            to: TurnAt::Last(3),
                            method: TurnMethod::WrapAndTurn,
                            resolve_turns: false,
                            decrease: None,
                        },
                        work(Purl, WorkTo::End),
                        hold_rest("neck"),
                    ],
                ),
                section("Collar", Some("p2"), vec![join_held("Body-3", resolve)]),
            ],
        )
    };
    let p = build(false);
    assert_eq!(
        lines(&p)[3],
        "With the RS facing, join the yarn and knit the 10 sts on hold (neck). (10 sts on the \
         needle)"
    );
    assert!(problems(&p).contains(&(
        Severity::Warning,
        "Collar, step 1: works past 1 wrapped stitch without working the wrap together with its \
         stitch; say to work them in this step"
            .into()
    )));
    let p = build(true);
    assert_eq!(
        lines(&p)[3],
        "With the RS facing, join the yarn and knit the 10 sts on hold (neck), working each wrap \
         together with its stitch. (10 sts on the needle)"
    );
    assert!(problems(&p).is_empty(), "{:?}", problems(&p));
}

#[test]
fn an_unknown_count_in_one_piece_leaves_the_others_counted() {
    let p = pat(
        true,
        Side::Rs,
        None,
        &["Hand", "Thumb"],
        vec![
            section(
                "Hand",
                None,
                vec![
                    cast_on(40),
                    StepAction::Opaque {
                        text: "Work the hand.".into(),
                        stitch_change: None,
                    },
                ],
            ),
            section("Thumb", Some("p2"), vec![cast_on(10)]),
        ],
    );
    let l = ledger(&p);
    assert_eq!(l.lines[1].count, LineCount::Unknown);
    assert_eq!(
        l.lines[2].written(),
        "Cast on 10 sts and join to work in the round, being careful not to twist. (10 sts on the \
         needle; set aside: Hand (count unknown))"
    );
    assert_eq!(l.pieces[0].text, "stitch count unknown at the end");
    let c = l.lines[2].count.counted().unwrap();
    assert_eq!(c.set_aside_total(), None);
}

#[test]
fn more_than_three_pieces_set_aside_are_summed() {
    let names = ["a", "b", "c", "d", "e"];
    let sections = names
        .iter()
        .enumerate()
        .map(|(i, n)| section(n, Some(&format!("p{}", i + 1)), vec![cast_on(i as u32 + 1)]))
        .collect();
    let p = pat(false, Side::Rs, None, &names, sections);
    let got = lines(&p);
    assert_eq!(
        got[3],
        "Cast on 4 sts. (4 sts on the needle; set aside: a 1, b 2, c 3)"
    );
    assert_eq!(
        got[4],
        "Cast on 5 sts. (5 sts on the needle; set aside in 4 other pieces: 10 sts)"
    );
    // Every piece but the last worked is left set aside, with a warning at its section.
    let warnings: Vec<String> = problems(&p).into_iter().map(|(_, m)| m).collect();
    assert_eq!(
        warnings,
        [
            "a: 1 stitch of a is still set aside at the end of the pattern; no step joins it to \
             another piece or finishes it",
            "b: 2 stitches of b are still set aside at the end of the pattern; no step joins \
             them to another piece or finishes them",
            "c: 3 stitches of c are still set aside at the end of the pattern; no step joins \
             them to another piece or finishes them",
            "d: 4 stitches of d are still set aside at the end of the pattern; no step joins \
             them to another piece or finishes them",
        ]
    );
}

#[test]
fn a_section_naming_the_first_piece_works_the_same_needle_as_one_naming_none() {
    let p = pat(
        false,
        Side::Rs,
        Some(10),
        &["Body", "Sleeve"],
        vec![
            section("Start", None, vec![work(Knit, WorkTo::Count(4))]),
            section("Go on", Some("p1"), vec![work(Knit, WorkTo::End)]),
        ],
    );
    assert_eq!(
        lines(&p),
        [
            "Next row (RS): knit 4 sts. (10 sts on the needle, 6 still to work in this row)",
            "Knit to end. (10 sts on the needle)",
        ]
    );
    let l = ledger(&p);
    assert_eq!(l.pieces[0].sections, vec![0, 1]);
    assert_eq!(l.pieces[1].text, "no section works this piece");
}

#[test]
fn the_stitch_cap_counts_every_piece() {
    let p = pat(
        false,
        Side::Rs,
        None,
        &["a", "b"],
        vec![
            section("A", None, vec![cast_on(600_000)]),
            section("B", Some("p2"), vec![cast_on(500_000)]),
        ],
    );
    let l = ledger(&p);
    assert_eq!(l.lines[1].count, LineCount::NotCounted);
    assert!(problems(&p).contains(&(
        Severity::Error,
        "B, step 1: has too many stitches to count".into()
    )));
}

#[test]
fn a_join_onto_an_unknown_count_still_takes_the_piece() {
    let p = pat(
        true,
        Side::Rs,
        None,
        &["Body", "Sleeve"],
        vec![
            section("Sleeve", Some("p2"), vec![cast_on(6)]),
            section(
                "Body",
                None,
                vec![
                    cast_on(10),
                    StepAction::Opaque {
                        text: "Work the body.".into(),
                        stitch_change: None,
                    },
                    join_piece("p2"),
                ],
            ),
            section("Sleeve again", Some("p2"), vec![cast_on(2)]),
        ],
    );
    let l = ledger(&p);
    assert_eq!(
        l.lines[3].written(),
        "Knit across the sts of Sleeve. (stitch count unknown)"
    );
    assert_eq!(l.pieces[1].text, "joined to Body at Body, step 3");
    // A piece joined to another cannot be worked again: its steps are refused.
    assert_eq!(l.lines[4].count, LineCount::NotCounted);
    assert!(problems(&p).contains(&(
        Severity::Error,
        "Sleeve again, step 1: Sleeve was joined to Body at Body, step 3, so it cannot be worked \
         again; start a new piece instead"
            .into()
    )));
}

#[test]
fn headings_and_the_first_line_name_the_pieces() {
    let mut cuff = section("Cuff", Some("p2"), vec![cast_on(4)]);
    cuff.construction = Some(Construction::InTheRound);
    let p = pat(
        true,
        Side::Rs,
        Some(8),
        &["Body", ""],
        vec![section("Body", None, vec![]), cuff],
    );
    let written = to_written(&p);
    assert_eq!(
        written[0],
        "Made in 2 pieces: Body and piece 2. The cast-on below is for Body."
    );
    assert_eq!(written[2], "Section 1: Body");
    assert_eq!(written[4], "Section 2: Cuff (piece 2, worked in the round)");
    assert_eq!(heading(&p, 0), "Section 1: Body");
    assert_eq!(
        pieces_line(&pat(false, Side::Rs, None, &["Body"], vec![])).unwrap(),
        "Made in 1 piece: Body."
    );
    assert_eq!(pieces_line(&pat(false, Side::Rs, None, &[], vec![])), None);
}

#[test]
fn files_past_the_piece_limits_are_named() {
    let names: Vec<String> = (0..=MAX_PIECES).map(|i| format!("p{i}")).collect();
    let refs: Vec<&str> = names.iter().map(String::as_str).collect();
    let p = pat(false, Side::Rs, None, &refs, vec![]);
    assert!(check_limits(&p).unwrap_err().to_string().contains("pieces"));
    let long = "x".repeat(MAX_PIECE_NAME_BYTES + 1);
    let p = pat(false, Side::Rs, None, &[&long], vec![]);
    assert!(check_limits(&p)
        .unwrap_err()
        .to_string()
        .contains("piece's name"));
    let ok = "x".repeat(MAX_PIECE_NAME_BYTES);
    assert!(check_limits(&pat(false, Side::Rs, None, &[&ok], vec![])).is_ok());
    let mut s = section(
        "S",
        None,
        vec![join_held(&"y".repeat(MAX_TEXT_BYTES + 1), false)],
    );
    assert!(check_limits(&pat(false, Side::Rs, None, &[], vec![s.clone()])).is_err());
    s.steps.clear();
    s.piece = Some("z".repeat(MAX_TEXT_BYTES + 1));
    assert!(check_limits(&pat(false, Side::Rs, None, &[], vec![s])).is_err());
}

#[test]
fn a_section_naming_a_piece_in_a_pattern_of_one_piece_is_not_counted() {
    let p = pat(
        false,
        Side::Rs,
        Some(10),
        &[],
        vec![
            section("A", None, vec![work(Knit, WorkTo::Count(2))]),
            section("B", Some("p9"), vec![work(Knit, WorkTo::End)]),
            section("C", None, vec![work(Knit, WorkTo::End)]),
        ],
    );
    let l = ledger(&p);
    assert_eq!(l.lines[1].count, LineCount::Unknown);
    // The one piece is untouched by the section that was not counted: the row goes on.
    assert_eq!(l.lines[2].written(), "Knit to end. (10 sts on the needle)");
    assert!(problems(&p).contains(&(
        Severity::Error,
        "B: works a piece the pattern does not have (it may have been deleted), so its steps are \
         not counted; choose one of the pattern's pieces"
            .into()
    )));
}

// --- review fixes (ADR 0020 review) ---------------------------------------------------------------

fn rows(count: u32) -> StepAction {
    StepAction::Rows {
        count,
        text: "knit".into(),
    }
}

fn close_held(a: &str, b: &str) -> StepAction {
    StepAction::Close {
        method: CloseMethod::ThreeNeedleBindOff,
        holds: vec![a.into(), b.into()],
    }
}

#[test]
fn a_piece_joined_to_another_cannot_be_worked_again_and_no_stitch_vanishes() {
    // A has 40; B casts on 20; A joins B (60); B casts on 10 and joins A (both refused: B was
    // joined); A casts on 6 more (66).
    let p = pat(
        true,
        Side::Rs,
        Some(40),
        &["A", "B"],
        vec![
            section("A1", None, vec![]),
            section("B1", Some("p2"), vec![cast_on(20)]),
            section("A2", Some("p1"), vec![join_piece("p2")]),
            section("B2", Some("p2"), vec![cast_on(10), join_piece("p1")]),
            section("A3", Some("p1"), vec![cast_on(6)]),
        ],
    );
    let l = ledger(&p);
    let refused = "was joined to A at A2, step 1, so it cannot be worked again; start a new piece \
                   instead";
    for (step, line) in [(1, 2), (2, 3)] {
        assert_eq!(l.lines[line].count, LineCount::NotCounted);
        assert!(problems(&p).contains(&(Severity::Error, format!("B2, step {step}: B {refused}"))));
    }
    assert_eq!(
        l.lines[4].written(),
        "Cast on 6 sts at the start of the rnd. (66 sts on the needle)"
    );
    let ends: Vec<(Option<u64>, &str)> =
        l.pieces.iter().map(|x| (x.live, x.text.as_str())).collect();
    assert_eq!(
        ends,
        [
            (Some(66), "66 sts left on the needle at the end"),
            (Some(0), "joined to A at A2, step 1")
        ]
    );
}

#[test]
fn a_join_cycle_is_refused_at_its_second_join() {
    // A joins B, then B (joined) tries to join A back.
    let p = pat(
        false,
        Side::Rs,
        Some(10),
        &["A", "B"],
        vec![
            section("B", Some("p2"), vec![cast_on(4)]),
            section("A", None, vec![join_piece("p2")]),
            section("B again", Some("p2"), vec![join_piece("p1")]),
        ],
    );
    let l = ledger(&p);
    assert_eq!(l.lines[2].count, LineCount::NotCounted);
    assert_eq!(
        l.lines[2].written(),
        "Knit across the sts of A. (not counted: see the problems)"
    );
    assert_eq!(l.pieces[0].live, Some(14));
    assert_eq!(l.pieces[1].text, "joined to A at A, step 1");
}

#[test]
fn a_hold_at_either_end_of_a_round_leaves_a_gap_there() {
    // 80 sts: knit 60, hold the last 20, then work 2 rounds: they cross the gap.
    let p = pat(
        true,
        Side::Rs,
        Some(80),
        &[],
        vec![section(
            "Body",
            None,
            vec![
                work(Knit, WorkTo::Count(60)),
                StepAction::Hold {
                    count: Some(20),
                    name: "sleeve".into(),
                },
                rows(2),
            ],
        )],
    );
    assert!(problems(&p).contains(&(
        Severity::Warning,
        "Body, step 3: works across the gap left by the stitches put on hold (sleeve), which joins \
         the two sides with a strand of yarn; cast on over the gap, or put one side on hold to work \
         the sides separately"
            .into()
    )));
    // At the start of the round, likewise.
    let p = pat(
        true,
        Side::Rs,
        Some(80),
        &[],
        vec![section(
            "Body",
            None,
            vec![
                StepAction::Hold {
                    count: Some(20),
                    name: "sleeve".into(),
                },
                rows(1),
            ],
        )],
    );
    assert!(problems(&p).iter().any(
        |(s, m)| *s == Severity::Warning && m.starts_with("Body, step 2: works across the gap")
    ));
}

#[test]
fn a_cast_on_over_a_gap_at_the_start_of_the_round_closes_it() {
    // The repro: k60, hold 52, cast on 8, k60, hold the last 52, cast on 8, then a round.
    let hold = |name: &str| StepAction::Hold {
        count: Some(52),
        name: name.into(),
    };
    let p = pat(
        true,
        Side::Rs,
        Some(224),
        &[],
        vec![section(
            "Split",
            None,
            vec![
                work(Knit, WorkTo::Count(60)),
                hold("left sleeve"),
                cast_on(8),
                work(Knit, WorkTo::Count(60)),
                hold("right sleeve"),
                cast_on(8),
                rows(1),
            ],
        )],
    );
    let got = lines(&p);
    assert_eq!(
        got[4],
        "Place the next 52 sts on a holder (right sleeve). (128 sts on the needle; on hold: left \
         sleeve 52, right sleeve 52)"
    );
    assert_eq!(
        got[5],
        "Cast on 8 sts onto the right needle, over the gap left by the stitches on hold (right \
         sleeve). (136 sts on the needle; on hold: left sleeve 52, right sleeve 52)"
    );
    assert!(
        !problems(&p)
            .iter()
            .any(|(_, m)| m.contains("across the gap")),
        "both gaps closed: {:?}",
        problems(&p)
    );
}

#[test]
fn a_join_at_the_start_of_a_round_closes_a_gap_there() {
    let p = pat(
        true,
        Side::Rs,
        Some(40),
        &["Body", "Sleeve"],
        vec![
            section("Sleeve", Some("p2"), vec![cast_on(12)]),
            section(
                "Body",
                None,
                vec![
                    work(Knit, WorkTo::Count(30)),
                    StepAction::Hold {
                        count: None,
                        name: "underarm".into(),
                    },
                    join_piece("p2"),
                    rows(1),
                ],
            ),
        ],
    );
    assert_eq!(
        lines(&p)[3],
        "Knit across the 12 sts of Sleeve, joining it to Body, before the marker for the start of \
         the rnd (the rnd now starts after them), over the gap left by the stitches on hold \
         (underarm). (42 sts on the needle; 10 on hold)"
    );
    assert!(
        !problems(&p)
            .iter()
            .any(|(_, m)| m.contains("works across the gap")),
        "{:?}",
        problems(&p)
    );
}

#[test]
fn two_groups_on_hold_close_against_each_other() {
    // A body and a sleeve each hold 6 underarm sts, then close them with a three-needle bind-off.
    let underarm = |name: &str| StepAction::Hold {
        count: Some(6),
        name: name.into(),
    };
    let p = pat(
        true,
        Side::Rs,
        Some(40),
        &["Body", "Sleeve"],
        vec![
            section("Body", None, vec![underarm("body underarm")]),
            section(
                "Sleeve",
                Some("p2"),
                vec![cast_on(20), underarm("sleeve underarm")],
            ),
            section(
                "Underarm",
                None,
                vec![
                    close_held("Body-1", "Sleeve-2"),
                    close_held("Body-1", "Sleeve-2"),
                ],
            ),
        ],
    );
    let l = ledger(&p);
    assert_eq!(
        l.lines[3].written(),
        "Place the 6 sts on hold (body underarm) and the 6 sts on hold (sleeve underarm) on two \
         needles and, with the right sides together, bind them off together with a three-needle \
         bind-off. (34 sts on the needle; set aside: Sleeve 14; 12 bound off)"
    );
    let c = l.lines[3].count.counted().unwrap();
    assert_eq!(
        (c.bound_off, c.bound_off_total, c.held_total()),
        (12, 12, 0)
    );
    assert_eq!(l.lines[4].count, LineCount::NotCounted, "taken already");
    assert!(problems(&p).contains(&(
        Severity::Error,
        "Underarm, step 2: closes the stitches on hold (body underarm), but Underarm, step 1 \
         already took them off the holder"
            .into()
    )));
}

#[test]
fn closing_held_groups_is_refused_when_they_do_not_pair() {
    let p = pat(
        false,
        Side::Rs,
        Some(10),
        &[],
        vec![section(
            "S",
            None,
            vec![
                StepAction::Hold {
                    count: Some(4),
                    name: "a".into(),
                },
                StepAction::Hold {
                    count: None,
                    name: "b".into(),
                },
                StepAction::Close {
                    method: CloseMethod::Graft,
                    holds: vec!["S-1".into()],
                },
                close_held("S-1", "S-1"),
                close_held("S-1", "S-2"),
                close_held("S-1", "gone"),
            ],
        )],
    );
    let issues: Vec<String> = problems(&p)
        .into_iter()
        .filter(|(s, _)| *s == Severity::Error)
        .map(|(_, m)| m)
        .collect();
    assert_eq!(
        issues,
        [
            "S, step 3: closes 1 group on hold; name two groups, one for each needle",
            "S, step 4: names the same stitches on hold twice; name the two groups to close together",
            "S, step 5: a three-needle bind-off joins two groups of the same size, but the stitches \
             on hold (a) are 4 stitches and the stitches on hold (b) are 6 stitches",
            "S, step 6: closes held stitches, but the step that put them on hold is gone (it may \
             have been deleted)",
        ]
    );
}

#[test]
fn a_join_onto_an_empty_needle_says_when_it_cannot_order_the_groups() {
    // The groups are held from a needle whose side was never stated, then joined onto a new piece.
    let groups = StepAction::Groups {
        groups: ["a", "b"]
            .iter()
            .map(|n| NeedleGroup {
                name: n.to_string(),
                count: 3,
                notes: String::new(),
            })
            .collect(),
    };
    let p = pat(
        false,
        Side::Rs,
        Some(6),
        &["Body", "Band"],
        vec![
            section(
                "Body",
                None,
                vec![
                    groups,
                    hold_rest("x"),
                    StepAction::Resume {
                        hold: "Body-2".into(),
                        facing: None,
                    },
                    hold_rest("y"),
                ],
            ),
            section("Band", Some("p2"), vec![join_held("Body-4", false)]),
        ],
    );
    assert!(problems(&p).contains(&(
        Severity::Warning,
        "Band, step 1: Ply cannot tell which way round the needle groups of the stitches on hold \
         (y) (a, b) go, so it does not count needle groups on this piece; divide the stitches into \
         groups again to count them"
            .into()
    )));
    let l = ledger(&p);
    assert!(l
        .lines
        .last()
        .unwrap()
        .count
        .counted()
        .unwrap()
        .groups
        .is_empty());
}

#[test]
fn piece_ids_and_the_references_to_them_follow_the_short_id_grammar() {
    let mut p = pat(false, Side::Rs, None, &["Body"], vec![]);
    assert!(check_limits(&p).is_ok());
    for bad in ["", "a b", "-x", &"x".repeat(65)] {
        p.pieces[0].id = bad.to_string();
        assert!(
            matches!(check_limits(&p), Err(LimitError::BadPieceId(_))),
            "{bad:?}"
        );
    }
    p.pieces[0].id = "piece-1".into();
    p.sections = vec![section("S", Some("piece/2"), vec![])];
    assert!(matches!(check_limits(&p), Err(LimitError::BadPieceId(_))));
    p.sections = vec![section("S", None, vec![join_piece("x y")])];
    assert!(matches!(check_limits(&p), Err(LimitError::BadPieceId(_))));
    p.sections = vec![section("S", Some("piece_2"), vec![join_piece("Z-9")])];
    assert!(check_limits(&p).is_ok());
}

/// The bytes of text a ledger keeps: its lines' words, its problems, its pieces' ends and its
/// table of names (counts hold indices into the table).
fn ledger_bytes(l: &Ledger) -> usize {
    let lines: usize = l
        .lines
        .iter()
        .map(|x| x.text.len() + x.label.as_ref().map_or(0, String::len))
        .sum();
    let issues: usize = l
        .issues
        .iter()
        .map(|i| i.text.len() + i.message.len())
        .sum();
    let pieces: usize = l.pieces.iter().map(|x| x.text.len()).sum();
    let names = l
        .names
        .holds
        .iter()
        .map(|h| h.hold.len() + h.name.len())
        .sum::<usize>()
        + l.names.groups.iter().map(String::len).sum::<usize>()
        + l.names.pieces.iter().map(String::len).sum::<usize>();
    lines + issues + pieces + names
}

#[test]
fn a_ledger_does_not_grow_with_name_length_times_lines() {
    // 50 one-stitch holds with long ids and names, 6 needle groups with long names, then 1,000
    // rows: every count lists the holds and the groups, by index.
    let build = |len: usize| {
        let long = |i: usize, c: char| format!("{i}{}", c.to_string().repeat(len));
        let groups = StepAction::Groups {
            groups: (0..6)
                .map(|i| NeedleGroup {
                    name: long(i, 'g'),
                    count: 20,
                    notes: String::new(),
                })
                .collect(),
        };
        let mut steps = vec![(String::from("g"), groups)];
        for i in 0..50 {
            steps.push((
                long(i, 'h'),
                StepAction::Hold {
                    count: Some(1),
                    name: long(i, 'n'),
                },
            ));
        }
        for i in 0..1000 {
            steps.push((format!("r{i}"), rows(1)));
        }
        let mut s = section("Body", None, vec![]);
        s.steps = steps
            .into_iter()
            .map(|(id, action)| Step { id, action })
            .collect();
        pat(true, Side::Rs, Some(120), &[], vec![s])
    };
    let (small, big) = (build(10), build(5_000));
    let (ls, lb) = (ledger(&small), ledger(&big));
    let grown = ledger_bytes(&lb) - ledger_bytes(&ls);
    // The names are 56 entries of about 5,000 more bytes, kept once in the table and once in their
    // own step's words; the 1,000 rows add nothing for them.
    assert!(grown < 4 * 56 * 5_000, "{grown} bytes more");
    // And no line's written count repeats them: it names at most a few, shortened.
    let longest = lb.lines.iter().map(|l| l.written().len()).max().unwrap();
    assert!(longest < 6_000, "{longest}");
    let row = lb.lines.last().unwrap().written();
    assert!(row.contains("on hold in 50 groups"), "{row}");
    assert!(row.len() < 500, "{row}");
}
