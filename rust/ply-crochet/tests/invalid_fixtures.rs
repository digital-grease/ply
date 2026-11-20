//! The invalid fixtures of ADR 0022 section 23: one small piece per case. Each asserts the exact list
//! of diagnostics the piece gives, with every code's typed location (layer, instruction path, item),
//! worked out by hand from the ADR's rules: the case's own code, and whatever its rules make follow
//! from it (a stitch with an impossible anchor leaves the cursor where it was, so the rest of the
//! base is not reached; a structural error refuses resolution, so it comes alone). The last row of
//! that table (a newer `schema_version`, an unknown field) belongs to the native document of M11-02.
//!
//! Run: `cargo test -p ply-crochet --test invalid_fixtures`

mod common;

use common::*;
use ply_crochet::*;

type Located = (&'static str, Option<u32>, Vec<u32>, Option<u32>);

/// Every diagnostic as (code, layer, path, item), in the order listed.
fn located(p: &CrochetPattern) -> Vec<Located> {
    validate(p)
        .iter()
        .map(|d| {
            (
                d.code.as_str(),
                d.location.layer,
                d.location.path.clone(),
                d.location.item,
            )
        })
        .collect()
}

fn at(code: &'static str, layer: u32, path: &[u32], item: Option<u32>) -> Located {
    (code, Some(layer), path.to_vec(), item)
}

fn legend_at(p: &CrochetPattern) -> Vec<(&'static str, Option<u32>)> {
    validate(p)
        .iter()
        .map(|d| (d.code.as_str(), d.location.legend))
        .collect()
}

fn detail(p: &CrochetPattern, code: CrochetCode) -> Detail {
    validate(p)
        .into_iter()
        .find(|d| d.code == code)
        .map(|d| d.detail)
        .unwrap_or_else(|| panic!("no {}", code.as_str()))
}

/// Row 1: `b0` in each foundation chain but the one nearest the hook.
fn first_row() -> Vec<(LayerKind, Option<StatedCount>)> {
    vec![(
        row(vec![
            Instr::start_from_foundation(1, CountsAs::Nothing),
            Instr::to_end(vec![st(B0, nch())]),
        ]),
        None,
    )]
}

/// A foundation chain of `n + 1`, row 1 of n `b0` (items 1.1 to 1.n), then `more`.
fn rows(n: u32, more: Vec<(LayerKind, Option<StatedCount>)>) -> CrochetPattern {
    let mut layers = first_row();
    layers.extend(more);
    piece(PieceStart::FoundationChain(n + 1), layers)
}

/// Row 2 makes 2.1, sp 2.2 (ch 3), 2.3, sp 2.4 (ch 3), 2.5, so row 3 meets 2.5, sp 2.4, 2.3,
/// sp 2.2, 2.1.
fn mesh() -> CrochetPattern {
    rows(
        5,
        vec![(
            row(vec![
                ch_none(1),
                st(B0, ns()),
                ch(3),
                sk(1),
                st(B0, ns()),
                ch(3),
                sk(1),
                st(B0, ns()),
            ]),
            None,
        )],
    )
}

fn ring_round(work: Vec<Instr>) -> CrochetPattern {
    piece(PieceStart::MagicRing, vec![(joined(work), None)])
}

const UNFINISHED: &str = "crochet.base_unfinished";

#[test]
fn next_past_the_end_of_a_row() {
    let p = piece(
        PieceStart::FoundationChain(4),
        vec![(
            row(vec![
                Instr::start_from_foundation(1, CountsAs::Nothing),
                Instr::times(4, vec![st(B0, nch())]),
            ]),
            None,
        )],
    );
    // F3, F2, F1, then nothing: the fourth stitch's anchor is impossible.
    assert_eq!(
        located(&p),
        vec![at("crochet.anchor_past_end", 1, &[1, 0], Some(4))]
    );
    assert_eq!(validate(&p)[0].location.repetition, vec![4]);
    let w = resolve_all(&p);
    assert_eq!(items(&w.layers[0]).last(), Some(&it(4, "b0", "impossible")));
}

#[test]
fn next_of_a_kind_that_is_not_left() {
    // No space in a base of stitches; the cursor stays, so all 5 positions are not reached.
    let p = rows(5, vec![(row(vec![ch_none(1), st(B0, nsp())]), None)]);
    assert_eq!(
        located(&p),
        vec![
            at("crochet.anchor_kind", 2, &[1], Some(1)),
            at(UNFINISHED, 2, &[], None)
        ]
    );
    // `next chain` meeting a stitch.
    let p = rows(5, vec![(row(vec![ch_none(1), st(B0, nch())]), None)]);
    assert_eq!(
        located(&p),
        vec![
            at("crochet.anchor_kind", 2, &[1], Some(1)),
            at(UNFINISHED, 2, &[], None)
        ]
    );
}

#[test]
fn same_at_a_layer_start() {
    let p = rows(5, vec![(row(vec![ch_none(1), st(B0, same())]), None)]);
    assert_eq!(
        located(&p),
        vec![
            at("crochet.same_without_position", 2, &[1], Some(1)),
            at(UNFINISHED, 2, &[], None)
        ]
    );
}

#[test]
fn a_part_that_does_not_fit() {
    // A back loop of a space: sp 2.4; the cursor moves onto it, so 2.3, sp 2.2, 2.1 are left.
    let mut p = mesh();
    p.push(
        row(vec![
            ch_none(1),
            st(B0, ns()),
            st(
                B0,
                Target::Next {
                    kind: PosKind::Space,
                    part: Some(PartSpec::Top(Part::BackLoop)),
                },
            ),
        ]),
        None,
    );
    assert_eq!(
        located(&p),
        vec![
            at("crochet.part_invalid", 3, &[2], Some(2)),
            at(UNFINISHED, 3, &[], None)
        ]
    );
    let d = validate(&p).remove(0);
    assert_eq!(d.location.position, Some(PosRef::Space(ItemId::new(2, 4))));
    // A back bump of a stitch top.
    let p = rows(
        5,
        vec![(
            row(vec![
                ch_none(1),
                st(
                    B0,
                    Target::Next {
                        kind: PosKind::Stitch,
                        part: Some(PartSpec::Chain(ChainPart::BackBump)),
                    },
                ),
            ]),
            None,
        )],
    );
    assert_eq!(
        located(&p),
        vec![
            at("crochet.part_invalid", 2, &[1], Some(1)),
            at(UNFINISHED, 2, &[], None)
        ]
    );
    assert_eq!(
        detail(&p, CrochetCode::BaseUnfinished),
        Detail::Positions {
            listed: (1..=4)
                .rev()
                .map(|k| PosRef::Top(ItemId::new(1, k)))
                .collect(),
            total: 4
        },
        "the cursor moved onto 1.5"
    );
    let w = resolve_all(&p);
    assert_eq!(items(&w.layers[1])[1], it(1, "b0", "impossible"));
    assert_eq!(base(&w.layers[1])[0].1, BaseUse::Worked);
}

#[test]
fn a_space_entered_whole_after_one_of_its_chains() {
    // sc in 2.5, sc in the first chain met of sp 2.4, then `next space`: sp 2.4 is the current
    // position. Left: its 2 other chains, 2.3, sp 2.2, 2.1.
    let mut p = mesh();
    p.push(
        row(vec![ch_none(1), st(B0, ns()), st(B0, nch()), st(B0, nsp())]),
        None,
    );
    assert_eq!(
        located(&p),
        vec![
            at("crochet.space_opened", 3, &[3], Some(3)),
            at(UNFINISHED, 3, &[], None)
        ]
    );
    match detail(&p, CrochetCode::BaseUnfinished) {
        Detail::Positions { total, .. } => assert_eq!(total, 5),
        other => panic!("{other:?}"),
    }
    // And the other way round: whole, then a chain of it.
    let mut p = mesh();
    p.push(
        row(vec![ch_none(1), st(B0, ns()), st(B0, nsp()), st(B0, nch())]),
        None,
    );
    assert_eq!(
        located(&p),
        vec![
            at("crochet.space_opened", 3, &[3], Some(3)),
            at(UNFINISHED, 3, &[], None)
        ]
    );
}

#[test]
fn ring_in_a_piece_started_with_a_foundation_chain() {
    let p = rows(5, vec![(row(vec![ch_none(1), st(B0, Target::Ring)]), None)]);
    assert_eq!(
        located(&p),
        vec![
            at("crochet.ring_missing", 2, &[1], Some(1)),
            at(UNFINISHED, 2, &[], None)
        ]
    );
}

#[test]
fn markers_unknown_and_duplicated() {
    let p = ring_round(vec![
        ch_none(1),
        sts(B0, Target::Ring, 6),
        Instr::join_marker("Z"),
    ]);
    assert_eq!(
        located(&p),
        vec![at("crochet.marker_unknown", 1, &[2], None)]
    );
    let p = ring_round(vec![
        ch_none(1),
        sts(B0, Target::Ring, 3).marked("A"),
        sts(B0, Target::Ring, 3).marked("A"),
        Instr::join_marker("A"),
    ]);
    assert_eq!(
        located(&p),
        vec![at("crochet.marker_duplicate", 1, &[2], None)]
    );
}

#[test]
fn markers_out_of_scope() {
    // A join into a marker of another layer.
    let p = piece(
        PieceStart::MagicRing,
        vec![
            (
                joined(vec![
                    ch_none(1),
                    sts(B0, Target::Ring, 6).marked("A"),
                    Instr::join(),
                ]),
                None,
            ),
            (
                joined(vec![
                    ch_none(1),
                    Instr::to_end(vec![st(B0, ns())]),
                    Instr::join_marker("A"),
                ]),
                None,
            ),
        ],
    );
    assert_eq!(located(&p), vec![at("crochet.marker_scope", 2, &[2], None)]);
    // A stitch worked into a marker of its own layer.
    let p = ring_round(vec![
        ch_none(1),
        sts(B0, Target::Ring, 6).marked("A"),
        st(B0, Target::marker("A")),
        Instr::join(),
    ]);
    assert_eq!(located(&p), vec![at("crochet.marker_scope", 1, &[2], None)]);
    // A leg worked into a marker.
    let p = ring_round(vec![
        ch_none(1),
        sts(B0, Target::Ring, 6).marked("A"),
        Instr::tog(B0, vec![Target::marker("A"), Target::Ring]),
        Instr::join(),
    ]);
    assert_eq!(located(&p), vec![at("crochet.marker_scope", 1, &[2], None)]);
}

#[test]
fn marks_on_what_makes_no_stitch() {
    let p = ring_round(vec![
        ch_none(1),
        sts(B0, Target::Ring, 6),
        ch(2).marked("A"),
        Instr::join(),
    ]);
    assert_eq!(located(&p), vec![at("crochet.mark_invalid", 1, &[2], None)]);
    let p = ring_round(vec![
        ch_none(1),
        sts(B0, Target::Ring, 6),
        Instr::slip(Target::Ring).marked("A"),
        Instr::join(),
    ]);
    assert_eq!(located(&p), vec![at("crochet.mark_invalid", 1, &[2], None)]);
}

#[test]
fn joins_into_the_wrong_place() {
    // A join into another round's stitch.
    let p = piece(
        PieceStart::MagicRing,
        vec![
            (
                joined(vec![ch_none(1), sts(B0, Target::Ring, 6), Instr::join()]),
                None,
            ),
            (
                joined(vec![
                    ch_none(1),
                    Instr::times(5, vec![st(B0, ns())]),
                    Instr::op(Op::Slip {
                        role: SlipRole::Join,
                        into: ns(),
                    }),
                ]),
                None,
            ),
        ],
    );
    assert_eq!(located(&p), vec![at("crochet.join_target", 2, &[2], None)]);
    // A join in a row.
    let p = rows(
        5,
        vec![(
            row(vec![
                ch_none(1),
                Instr::to_end(vec![st(B0, ns())]),
                Instr::join(),
            ]),
            None,
        )],
    );
    assert_eq!(located(&p), vec![at("crochet.join_target", 2, &[2], None)]);
}

#[test]
fn a_joined_round_without_a_join() {
    let p = ring_round(vec![ch_none(1), sts(B0, Target::Ring, 6)]);
    assert_eq!(located(&p), vec![at("crochet.join_missing", 1, &[], None)]);
}

#[test]
fn turns_that_cannot_be() {
    // A spiral round with `turn`.
    let p = piece(
        PieceStart::MagicRing,
        vec![
            (spiral(vec![ch_none(1), sts(B0, Target::Ring, 6)]), None),
            (
                LayerKind::Round {
                    close: Close::Spiral,
                    turn: true,
                    work: vec![Instr::to_end(vec![st(B0, ns())])],
                },
                None,
            ),
        ],
    );
    assert_eq!(located(&p), vec![at("crochet.spiral_turn", 2, &[], None)]);
    // A joined round with `turn` after a spiral round.
    let p = piece(
        PieceStart::MagicRing,
        vec![
            (spiral(vec![ch_none(1), sts(B0, Target::Ring, 6)]), None),
            (
                joined_turned(vec![
                    ch_none(1),
                    Instr::to_end(vec![st(B0, ns())]),
                    Instr::join(),
                ]),
                None,
            ),
        ],
    );
    assert_eq!(located(&p), vec![at("crochet.spiral_turn", 2, &[], None)]);
    // `turn` on round 1.
    let p = piece(
        PieceStart::MagicRing,
        vec![(
            joined_turned(vec![ch_none(1), sts(B0, Target::Ring, 6), Instr::join()]),
            None,
        )],
    );
    assert_eq!(located(&p), vec![at("crochet.turn_invalid", 1, &[], None)]);
}

#[test]
fn rows_and_rounds_do_not_mix() {
    let round2 = || {
        joined(vec![
            ch_none(1),
            Instr::to_end(vec![st(B0, ns())]),
            Instr::join(),
        ])
    };
    let sequence = vec![at("crochet.layer_sequence", 2, &[], None)];
    // A round after a row.
    assert_eq!(located(&rows(5, vec![(round2(), None)])), sequence);
    // A round after a foundation layer.
    let p = piece(
        PieceStart::FoundationStitches,
        vec![
            (
                LayerKind::Foundation {
                    stitch: B0,
                    stitches: 6,
                },
                None,
            ),
            (round2(), None),
        ],
    );
    assert_eq!(located(&p), sequence);
    // A row after a round.
    let p = piece(
        PieceStart::MagicRing,
        vec![
            (
                joined(vec![ch_none(1), sts(B0, Target::Ring, 6), Instr::join()]),
                None,
            ),
            (
                row(vec![ch_none(1), Instr::to_end(vec![st(B0, ns())])]),
                None,
            ),
        ],
    );
    assert_eq!(located(&p), sequence);
    // A row after an opaque round 1 in a ring: a piece started in a ring is worked in rounds.
    let p = piece(
        PieceStart::MagicRing,
        vec![
            (
                LayerKind::Opaque {
                    text: "a round of puffs".into(),
                },
                stitches(8),
            ),
            (
                row(vec![ch_none(1), Instr::to_end(vec![st(B0, ns())])]),
                None,
            ),
        ],
    );
    assert_eq!(located(&p), sequence);
    // A row as layer 1 in a ring.
    let p = piece(
        PieceStart::MagicRing,
        vec![(row(vec![ch_none(1), sts(B0, Target::Ring, 6)]), None)],
    );
    assert_eq!(
        located(&p),
        vec![at("crochet.layer_sequence", 1, &[], None)]
    );
    // But a foundation chain, an opaque round 1 and rounds are a piece of rounds (section 16).
    let p = piece(
        PieceStart::FoundationChain(60),
        vec![
            (
                LayerKind::Opaque {
                    text: "join; sc in each ch around".into(),
                },
                stitches(60),
            ),
            (round2(), stitches(60)),
        ],
    );
    assert_eq!(
        located(&p),
        vec![("crochet.unsupported_layer", Some(1), vec![], None)]
    );
}

#[test]
fn leave_unworked_misplaced() {
    let p = rows(
        5,
        vec![(
            row(vec![
                ch_none(1),
                Instr::times(2, vec![st(B0, ns()), Instr::LeaveUnworked]),
            ]),
            None,
        )],
    );
    assert_eq!(
        located(&p),
        vec![at("crochet.leave_misplaced", 2, &[1, 1], None)]
    );
    let p = rows(
        5,
        vec![(
            row(vec![
                ch_none(1),
                st(B0, ns()),
                Instr::LeaveUnworked,
                st(B0, ns()),
            ]),
            None,
        )],
    );
    assert_eq!(
        located(&p),
        vec![at("crochet.leave_misplaced", 2, &[2], None)]
    );
}

#[test]
fn starting_chains_misplaced() {
    let p = rows(
        5,
        vec![(
            row(vec![
                ch_none(1),
                ch_none(1),
                Instr::to_end(vec![st(B0, ns())]),
            ]),
            None,
        )],
    );
    assert_eq!(
        located(&p),
        vec![at("crochet.start_misplaced", 2, &[1], None)]
    );
    let p = rows(5, vec![(row(vec![st(B0, ns()), ch_none(1)]), None)]);
    assert_eq!(
        located(&p),
        vec![at("crochet.start_misplaced", 2, &[1], None)]
    );
}

#[test]
fn starts_that_cannot_be() {
    const INVALID: &str = "crochet.start_invalid";
    // `from_foundation` in layer 2.
    let p = rows(
        5,
        vec![(
            row(vec![
                Instr::start_from_foundation(1, CountsAs::Nothing),
                Instr::to_end(vec![st(B0, ns())]),
            ]),
            None,
        )],
    );
    assert_eq!(located(&p), vec![at(INVALID, 2, &[0], None)]);
    // A `from_foundation` chain counting as a stitch and a space.
    let p = piece(
        PieceStart::FoundationChain(12),
        vec![(
            row(vec![
                Instr::start_from_foundation(
                    5,
                    CountsAs::StitchAndSpace {
                        stitch: B1,
                        chains: 1,
                    },
                ),
                Instr::to_end(vec![st(B1, nch())]),
            ]),
            None,
        )],
    );
    assert_eq!(located(&p), vec![at(INVALID, 1, &[0], None)]);
    // A chain of 0.
    let p = rows(
        5,
        vec![(
            row(vec![ch_none(0), Instr::to_end(vec![st(B0, ns())])]),
            None,
        )],
    );
    assert_eq!(located(&p), vec![at(INVALID, 2, &[0], None)]);
    // Taking 11 chains from a foundation of 10.
    let p = piece(
        PieceStart::FoundationChain(10),
        vec![(
            row(vec![
                Instr::start_from_foundation(11, CountsAs::Stitch(B1)),
                Instr::to_end(vec![st(B1, nch())]),
            ]),
            None,
        )],
    );
    assert_eq!(located(&p), vec![at(INVALID, 1, &[0], None)]);
    // A foundation layer as layer 2.
    let p = rows(
        5,
        vec![(
            LayerKind::Foundation {
                stitch: B0,
                stitches: 5,
            },
            None,
        )],
    );
    assert_eq!(located(&p), vec![at(INVALID, 2, &[], None)]);
    // A foundation layer 1 after a foundation chain.
    let p = piece(
        PieceStart::FoundationChain(10),
        vec![(
            LayerKind::Foundation {
                stitch: B0,
                stitches: 5,
            },
            None,
        )],
    );
    assert_eq!(located(&p), vec![at(INVALID, 1, &[], None)]);
}

#[test]
fn zero_counts() {
    let p = rows(
        5,
        vec![(
            row(vec![ch_none(1), Instr::times(0, vec![st(B0, ns())])]),
            None,
        )],
    );
    assert_eq!(located(&p), vec![at("crochet.repeat_zero", 2, &[1], None)]);
    let p = rows(
        5,
        vec![(row(vec![ch_none(1), Instr::skip(0, PosKind::Stitch)]), None)],
    );
    assert_eq!(located(&p), vec![at("crochet.repeat_zero", 2, &[1], None)]);
}

fn leftover(p: &CrochetPattern) -> (Vec<String>, u64) {
    match detail(p, CrochetCode::RepeatDoesNotFit) {
        Detail::Positions { listed, total } => (refs(&listed), total),
        other => panic!("{other:?}"),
    }
}

const UNFIT: &str = "crochet.repeat_does_not_fit";

#[test]
fn repeats_that_do_not_fit() {
    // A body of 2 over 9 positions: 4 repetitions, 1 position left of the body's kind (and not
    // reported again as not reached).
    let p = rows(
        9,
        vec![(
            row(vec![
                ch_none(1),
                Instr::to_end(vec![st(B0, ns()), st(B0, ns())]),
            ]),
            None,
        )],
    );
    assert_eq!(located(&p), vec![at(UNFIT, 2, &[1], None)]);
    assert_eq!(leftover(&p), (vec!["1.1".to_string()], 1));
    // A body `next space` over sp, st, sp, st: the last try finds no space; one stitch left. Row 2
    // makes 2.1, sp 2.2, 2.3, sp 2.4 and leaves 1.1 (not reached); row 3 meets sp 2.4, 2.3, sp 2.2,
    // 2.1 and passes 2.3.
    let mut p = rows(
        4,
        vec![(
            row(vec![
                ch_none(1),
                st(B0, ns()),
                ch(1),
                sk(1),
                st(B0, ns()),
                ch(1),
            ]),
            None,
        )],
    );
    p.push(
        row(vec![ch_none(1), Instr::to_end(vec![st(B0, nsp())])]),
        None,
    );
    assert_eq!(
        located(&p),
        vec![
            at(UNFIT, 3, &[1], None),
            at(UNFINISHED, 2, &[], None),
            at("crochet.passed_over", 3, &[], None),
        ]
    );
    assert_eq!(leftover(&p), (vec!["2.1".to_string()], 1));
    // A body that uses no position.
    let p = rows(
        5,
        vec![(row(vec![ch_none(1), Instr::to_end(vec![ch(1)])]), None)],
    );
    assert_eq!(located(&p), vec![at(UNFIT, 2, &[1], None)]);
    assert_eq!(leftover(&p).1, 5);
    // A body whose only leg-bearing step is a tog with all legs `same`.
    let p = rows(
        5,
        vec![(
            row(vec![
                ch_none(1),
                st(B0, ns()),
                Instr::to_end(vec![Instr::tog(B0, vec![same(), same()])]),
            ]),
            None,
        )],
    );
    assert_eq!(located(&p), vec![at(UNFIT, 2, &[2], None)]);
    assert_eq!(
        leftover(&p),
        (
            vec!["1.4".into(), "1.3".into(), "1.2".into(), "1.1".into()],
            4
        )
    );
    // Over a ring: the round then makes nothing, so its join has nothing to go into.
    let p = ring_round(vec![
        ch_none(1),
        Instr::to_end(vec![st(B0, Target::Ring)]),
        Instr::join(),
    ]);
    assert_eq!(
        located(&p),
        vec![
            at("crochet.join_target", 1, &[2], None),
            at(UNFIT, 1, &[1], None)
        ]
    );
    assert_eq!(leftover(&p), (vec!["ring".into()], 1));
    // to_last(5) over 3 positions.
    let p = rows(
        3,
        vec![(
            row(vec![ch_none(1), Instr::to_last(5, vec![st(B0, ns())])]),
            None,
        )],
    );
    assert_eq!(located(&p), vec![at(UNFIT, 2, &[1], None)]);
    assert_eq!(
        leftover(&p),
        (vec!["1.3".into(), "1.2".into(), "1.1".into()], 3)
    );
}

#[test]
fn togs_with_too_few_or_too_many_legs() {
    let p = rows(
        9,
        vec![(row(vec![ch_none(1), Instr::tog(B0, vec![ns()])]), None)],
    );
    assert_eq!(
        located(&p),
        vec![at("crochet.together_legs", 2, &[1], None)]
    );
    let p = rows(
        9,
        vec![(row(vec![ch_none(1), Instr::tog(B0, vec![ns(); 9])]), None)],
    );
    assert_eq!(
        located(&p),
        vec![at("crochet.together_legs", 2, &[1], None)]
    );
}

#[test]
fn a_stated_count_that_differs() {
    let p = rows(
        5,
        vec![(
            row(vec![ch_none(1), Instr::to_end(vec![st(B0, ns())])]),
            stitches(6),
        )],
    );
    assert_eq!(
        located(&p),
        vec![at("crochet.count_mismatch", 2, &[], None)]
    );
    assert_eq!(
        detail(&p, CrochetCode::CountMismatch),
        Detail::Counts(vec![CountDiff {
            what: CountWhat::Stitches,
            stated: 6,
            derived: 5
        }])
    );
}

fn with_legend(entry: LegendEntry, terms: Terms) -> CrochetPattern {
    let mut p = rows(
        5,
        vec![(
            row(vec![ch_none(1), Instr::to_end(vec![st(B0, ns())])]),
            None,
        )],
    );
    p.source_terms = terms;
    p.legend.push(entry);
    p
}

fn entry(id: &str, name: &str, abbreviation: &str, body: Vec<Instr>) -> LegendEntry {
    LegendEntry {
        id: LegendId::new(id),
        name: name.into(),
        abbreviation: abbreviation.into(),
        body,
    }
}

#[test]
fn a_legend_body_that_uses_itself() {
    let p = with_legend(
        entry(
            "loop",
            "loop",
            "loop",
            vec![Instr::named("loop", Some(Target::UseSite))],
        ),
        Terms::Us,
    );
    assert_eq!(legend_at(&p), vec![("crochet.legend_cycle", Some(0))]);
}

#[test]
fn legend_words_that_collide() {
    let inc = || vec![sts(B0, Target::UseSite, 2)];
    let collision = vec![("crochet.legend_collision", Some(0))];
    for terms in [Terms::Us, Terms::Uk, Terms::Unstated] {
        let p = with_legend(entry("x", "x", "dc", inc()), terms);
        assert_eq!(legend_at(&p), collision);
    }
    let p = with_legend(entry("x", "x", "Dc", inc()), Terms::Us);
    assert_eq!(legend_at(&p), collision);
    let p = with_legend(entry("x", "double crochet", "x", inc()), Terms::Us);
    assert_eq!(legend_at(&p), collision);
    // Ids are compared with the identity words whole, ignoring case and outer white space.
    for id in ["b0", "B0", "B1H", "Slip", " b0", "TOG"] {
        let p = with_legend(entry(id, "x", "x", inc()), Terms::Us);
        assert_eq!(legend_at(&p), collision, "{id:?}");
    }
    // "V-st" does not collide ("st" is only part of it).
    let p = with_legend(entry("vst", "V-stitch", "V-st", inc()), Terms::Us);
    assert!(validate(&p).is_empty(), "{:?}", keys(&validate(&p)));
    // Two entries sharing a word: reported once, at the second.
    let mut p = with_legend(entry("a", "increase", "inc", inc()), Terms::Us);
    p.legend.push(entry("b", "Increase", "inc2", inc()));
    assert_eq!(legend_at(&p), vec![("crochet.legend_collision", Some(1))]);
}

#[test]
fn a_display_name_is_never_an_identity() {
    let p = rows(
        5,
        vec![(
            row(vec![
                ch_none(1),
                Instr::to_end(vec![Instr::named("sc", Some(ns()))]),
            ]),
            None,
        )],
    );
    assert_eq!(
        located(&p),
        vec![at("crochet.legend_unknown", 2, &[1, 0], None)]
    );
    assert!(matches!(
        try_resolve_all(&p, &CrochetLimits::DEFAULT),
        Err(CrochetError::Invalid(_))
    ));
}

#[test]
fn a_duplicate_layer_id() {
    let mut p = rows(
        5,
        vec![(
            row(vec![ch_none(1), Instr::to_end(vec![st(B0, ns())])]),
            None,
        )],
    );
    p.layers[1].id = p.layers[0].id.clone();
    assert_eq!(located(&p), vec![at("crochet.duplicate_id", 2, &[], None)]);
}

#[test]
fn repeat_products_past_the_caps_refuse_before_allocating() {
    let p = rows(
        5,
        vec![(
            row(vec![
                ch_none(1),
                Instr::times(u32::MAX, vec![Instr::times(u32::MAX, vec![ch(1)])]),
            ]),
            None,
        )],
    );
    assert_eq!(located(&p), vec![at("crochet.too_large", 2, &[], None)]);
    match try_resolve_all(&p, &CrochetLimits::DEFAULT) {
        Err(CrochetError::Invalid(ds)) => assert_eq!(codes(&ds), ["crochet.too_large"]),
        other => panic!("{other:?}"),
    }
    // Just past the per-layer cap.
    let p = rows(
        5,
        vec![(
            row(vec![ch_none(1), Instr::times(100_000, vec![ch(1)])]),
            None,
        )],
    );
    assert_eq!(located(&p), vec![at("crochet.too_large", 2, &[], None)]);
    // At the cap (the chain and 99,999 runs): it resolves, and leaves row 1 not reached.
    let p = rows(
        5,
        vec![(
            row(vec![ch_none(1), Instr::times(99_999, vec![ch(1)])]),
            None,
        )],
    );
    assert_eq!(located(&p), vec![at(UNFINISHED, 2, &[], None)]);
}

#[test]
fn named_stitch_targets_must_match_the_body() {
    let walk = entry(
        "invdec",
        "invisible decrease",
        "invdec",
        vec![Instr::tog(
            B0,
            vec![
                Target::next_stitch_in(Part::FrontLoop),
                Target::next_stitch_in(Part::FrontLoop),
            ],
        )],
    );
    let mut p = with_legend(walk.clone(), Terms::Us);
    p.push(
        row(vec![ch_none(1), Instr::named("invdec", Some(ns()))]),
        None,
    );
    assert_eq!(located(&p), vec![at("crochet.named_target", 3, &[1], None)]);
    // Without a target it walks the base itself: 2.5 and 2.4, 2.3 and 2.2, then 2.1 is left over.
    let mut p = with_legend(walk, Terms::Us);
    p.push(
        row(vec![
            ch_none(1),
            Instr::to_end(vec![Instr::named("invdec", None)]),
        ]),
        None,
    );
    let w = resolve_all(&p);
    let r3 = &w.layers[2];
    assert_eq!(items(r3)[1], it(1, "tog(b0x2)", "2.5/FL, 2.4/FL"));
    assert_eq!(
        located(&p),
        vec![
            at(UNFIT, 3, &[1], None),
            at("crochet.unworked_loops", 3, &[], None)
        ]
    );
    // The target word outside a legend body.
    let p = rows(
        5,
        vec![(row(vec![ch_none(1), st(B0, Target::UseSite)]), None)],
    );
    assert_eq!(located(&p), vec![at("crochet.named_target", 2, &[1], None)]);
}
