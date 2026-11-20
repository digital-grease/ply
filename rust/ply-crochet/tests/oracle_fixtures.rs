//! The oracle pieces of ADR 0022 sections 17 to 19, counted by hand there, as exact table tests
//! (the positive fixtures of section 23 that M11-01 can check: every item's identity and anchors,
//! every base position's use, every count, the facing, and every diagnostic). The expected values
//! are transcribed from the ADR's tables in its own notation; where a table states a rule for a run
//! ("item 2.(2j+1) is `b0` into 1.j"), the rule is written out the same way here.
//!
//! The written lines of the oracles (rules W1 to W21) and the document round trip are M11-02's;
//! only the count phrase of rule W17 is asserted, in both label sets.
//!
//! Each fixture is original to Ply (ADR 0022); `practitioner_crochet_check = "pending"` for all of
//! them until a crocheter signs them off (section 24).
//!
//! Run: `cargo test -p ply-crochet --test oracle_fixtures`

mod common;

use common::*;
use ply_crochet::*;

fn diags(p: &CrochetPattern) -> Vec<Diagnostic> {
    validate(p)
}

// ---------------------------------------------------------------------------------------------
// Section 17: oracle swatch 1.

fn swatch_row1() -> (LayerKind, Option<StatedCount>) {
    (
        row(vec![
            Instr::start_from_foundation(1, CountsAs::Nothing),
            Instr::to_end(vec![st(B0, nch())]),
        ]),
        stitches(9),
    )
}

fn swatch_row2() -> (LayerKind, Option<StatedCount>) {
    (
        row(vec![ch_as(3, B1), Instr::to_end(vec![st(B1, ns())])]),
        stitches(9),
    )
}

fn swatch_row3(to_end: bool) -> (LayerKind, Option<StatedCount>) {
    let body = vec![ch(1), sk(1), st(B0, ns())];
    (
        row(vec![
            ch_none(1),
            st(B0, ns()),
            if to_end {
                Instr::to_end(body)
            } else {
                Instr::times(4, body)
            },
        ]),
        Some(StatedCount::stitches(5).with_spaces(4)),
    )
}

fn swatch(to_end_row3: bool) -> CrochetPattern {
    let mut p = piece(
        PieceStart::FoundationChain(10),
        vec![
            swatch_row1(),
            swatch_row2(),
            swatch_row3(to_end_row3),
            (
                row(vec![
                    ch_none(1),
                    st(B0, ns()),
                    Instr::to_end(vec![st(B0, nsp()), st(B0, ns())]),
                ]),
                stitches(9),
            ),
            (
                row(vec![
                    ch_none(1),
                    st(B0, ns()),
                    Instr::times(3, vec![st(B0, Target::next_stitch_in(Part::BackLoop))]),
                    Instr::times(3, vec![st(B0, Target::next_stitch_in(Part::FrontLoop))]),
                    Instr::times(2, vec![st(B0, ns())]),
                ]),
                stitches(9),
            ),
            (
                row(vec![
                    ch_none(1),
                    sts(B0, ns(), 2),
                    Instr::times(6, vec![st(B0, ns())]),
                    Instr::tog(B0, vec![ns(), ns()]),
                ]),
                stitches(9),
            ),
        ],
    );
    p.name = "Oracle swatch 1".into();
    p.first_side = FirstSide::Rs;
    p
}

#[test]
fn swatch_1_flat_rows() {
    let p = swatch(false);
    let w = resolve_all(&p);
    assert_eq!(w.layers.len(), 6);
    use BaseUse::*;

    // Row 1: form (a); F10 taken, not counted; base F9 to F1.
    let r1 = &w.layers[0];
    let mut want = vec![it(0, "ch1=none@F10-F10", "")];
    for k in 1..=9 {
        want.push(it(k, "b0", &format!("F{}", 10 - k)));
    }
    assert_eq!(items(r1), want);
    let want_base: Vec<_> = (1..=9).rev().map(|i| (format!("F{i}"), Worked)).collect();
    assert_eq!(base(r1), want_base);

    // Row 2: a counted ch 3 standing on 1.9; 2.1 to 2.8 into 1.8 to 1.1.
    let r2 = &w.layers[1];
    let mut want = vec![it(0, "ch3=b1", "1.9")];
    for k in 1..=8 {
        want.push(it(k, "b1", &format!("1.{}", 9 - k)));
    }
    assert_eq!(items(r2), want);
    let want_base: Vec<_> = (1..=9).rev().map(|i| (format!("1.{i}"), Worked)).collect();
    assert_eq!(base(r2), want_base);

    // Row 3: base 2.8 ... 2.1, 2.0^; chain runs, skips; the last b0 into 2.0^.
    let r3 = &w.layers[2];
    assert_eq!(
        items(r3),
        vec![
            it(0, "ch1=none", ""),
            it(1, "b0", "2.8"),
            it(2, "ch1", ""),
            it(3, "b0", "2.6"),
            it(4, "ch1", ""),
            it(5, "b0", "2.4"),
            it(6, "ch1", ""),
            it(7, "b0", "2.2"),
            it(8, "ch1", ""),
            it(9, "b0", "2.0^"),
        ]
    );
    let bases: Vec<_> = base(r3);
    assert_eq!(
        bases,
        vec![
            ("2.8".to_string(), Worked),
            ("2.7".to_string(), Skipped),
            ("2.6".to_string(), Worked),
            ("2.5".to_string(), Skipped),
            ("2.4".to_string(), Worked),
            ("2.3".to_string(), Skipped),
            ("2.2".to_string(), Worked),
            ("2.1".to_string(), Skipped),
            ("2.0^".to_string(), Worked),
        ]
    );
    // The repeat makes items 3.2 to 3.9 in four repetitions.
    let reps: Vec<_> = r3.made[2..].iter().map(|m| m.repetition.clone()).collect();
    assert_eq!(
        reps,
        vec![
            vec![1],
            vec![1],
            vec![2],
            vec![2],
            vec![3],
            vec![3],
            vec![4],
            vec![4]
        ]
    );

    // Row 4: spaces anchored as spaces, never chains; nothing passed.
    let r4 = &w.layers[3];
    assert_eq!(
        items(r4),
        vec![
            it(0, "ch1=none", ""),
            it(1, "b0", "3.9"),
            it(2, "b0", "sp 3.8"),
            it(3, "b0", "3.7"),
            it(4, "b0", "sp 3.6"),
            it(5, "b0", "3.5"),
            it(6, "b0", "sp 3.4"),
            it(7, "b0", "3.3"),
            it(8, "b0", "sp 3.2"),
            it(9, "b0", "3.1"),
        ]
    );
    assert_eq!(
        base_order(r4),
        ["3.9", "sp 3.8", "3.7", "sp 3.6", "3.5", "sp 3.4", "3.3", "sp 3.2", "3.1"]
    );
    assert!(base(r4).iter().all(|(_, u)| *u == Worked));

    // Row 5: back and front loop as worked.
    let r5 = &w.layers[4];
    assert_eq!(
        items(r5),
        vec![
            it(0, "ch1=none", ""),
            it(1, "b0", "4.9"),
            it(2, "b0", "4.8/BL"),
            it(3, "b0", "4.7/BL"),
            it(4, "b0", "4.6/BL"),
            it(5, "b0", "4.5/FL"),
            it(6, "b0", "4.4/FL"),
            it(7, "b0", "4.3/FL"),
            it(8, "b0", "4.2"),
            it(9, "b0", "4.1"),
        ]
    );

    // Row 6: an increase at the start and a decrease at the end.
    let r6 = &w.layers[5];
    let mut want = vec![
        it(0, "ch1=none", ""),
        it(1, "b0", "5.9"),
        it(2, "b0", "5.9"),
    ];
    for (k, t) in (3..=8).zip((3..=8).rev()) {
        want.push(it(k, "b0", &format!("5.{t}")));
    }
    want.push(it(9, "tog(b0x2)", "5.2, 5.1"));
    assert_eq!(items(r6), want);

    // Counts 9, 9, 5 and 4 spaces, 9, 9, 9, in both label sets; every stated count met.
    let texts: Vec<_> = w.layers.iter().map(count_texts).collect();
    let us: Vec<_> = texts.iter().map(|t| t.0.as_str()).collect();
    let uk: Vec<_> = texts.iter().map(|t| t.1.as_str()).collect();
    assert_eq!(
        us,
        [
            "(9 sc)",
            "(9 dc)",
            "(5 sc, 4 ch-1 sps)",
            "(9 sc)",
            "(9 sc)",
            "(9 sc)"
        ]
    );
    assert_eq!(
        uk,
        [
            "(9 dc)",
            "(9 tr)",
            "(5 dc, 4 ch-1 sps)",
            "(9 dc)",
            "(9 dc)",
            "(9 dc)"
        ]
    );
    assert!(w.layers.iter().all(|l| l.stated == Some(StatedCheck::Met)));

    // Rows 1, 3, 5 face side A; 2, 4, 6 side B.
    let facing: Vec<_> = w.layers.iter().map(|l| l.facing).collect();
    use Side::{A, B};
    assert_eq!(
        facing,
        [Some(A), Some(B), Some(A), Some(B), Some(A), Some(B)]
    );

    // No warnings; the only information is row 5's two ridges.
    let ds = diags(&p);
    assert_eq!(
        keys(&ds),
        vec![
            ("crochet.unworked_loops", Some(5), None),
            ("crochet.unworked_loops", Some(5), None)
        ]
    );
    let ridge = |d: &Diagnostic| match &d.detail {
        Detail::Ridge { side, items, total } => (
            *side,
            items.iter().map(|i| i.to_string()).collect::<Vec<_>>(),
            *total,
        ),
        other => panic!("{other:?}"),
    };
    assert_eq!(
        ridge(&ds[0]),
        (Some(A), vec!["5.2".into(), "5.3".into(), "5.4".into()], 3)
    );
    assert_eq!(
        ridge(&ds[1]),
        (Some(B), vec!["5.5".into(), "5.6".into(), "5.7".into()], 3)
    );
}

#[test]
fn swatch_1_row_3_resolves_the_same_with_times_4_and_to_end() {
    let a = resolve_all(&swatch(false));
    let b = resolve_all(&swatch(true));
    assert_eq!(a, b, "times(4) and to_end resolve to the same rows");
    assert_eq!(validate(&swatch(false)), validate(&swatch(true)));
}

#[test]
fn swatch_1_variant_times_8_with_an_uncounted_chain() {
    // Row 2 as "dc in next 8 sts" with its chain uncounted.
    let p = piece(
        PieceStart::FoundationChain(10),
        vec![
            swatch_row1(),
            (
                row(vec![ch_none(3), Instr::times(8, vec![st(B1, ns())])]),
                stitches(9),
            ),
        ],
    );
    let w = resolve_all(&p);
    let r2 = &w.layers[1];
    let mut want = vec![it(0, "ch3=none", "")];
    for k in 1..=8 {
        want.push(it(k, "b1", &format!("1.{}", 10 - k)));
    }
    assert_eq!(items(r2), want, "the 8 stitches go into 1.9 to 1.2");
    assert_eq!(
        base(r2).last(),
        Some(&("1.1".to_string(), BaseUse::NotReached))
    );
    let ds = diags(&p);
    assert_eq!(
        keys(&ds),
        vec![
            ("crochet.count_mismatch", Some(2), None),
            ("crochet.base_unfinished", Some(2), None),
        ],
        "nothing else"
    );
    assert_eq!(
        ds[0].detail,
        Detail::Counts(vec![CountDiff {
            what: CountWhat::Stitches,
            stated: 9,
            derived: 8
        }])
    );
    assert_eq!(
        ds[1].detail,
        Detail::Positions {
            listed: vec![PosRef::Top(ItemId::new(1, 1))],
            total: 1
        }
    );
    // Section 17's reason the variant stops after row 2: row 3 kept as times(4) runs out at 3.9.
    let mut p3 = p.clone();
    let (kind, stated) = swatch_row3(false);
    p3.push(kind, stated);
    let ds = diags(&p3);
    assert!(
        ds.iter().any(|d| d.code == CrochetCode::AnchorPastEnd
            && d.location.layer == Some(3)
            && d.location.item == Some(9)),
        "{:?}",
        keys(&ds)
    );
}

#[test]
fn swatch_1_variant_to_end_with_an_uncounted_chain() {
    let p = piece(
        PieceStart::FoundationChain(10),
        vec![
            swatch_row1(),
            (
                row(vec![ch_none(3), Instr::to_end(vec![st(B1, ns())])]),
                stitches(9),
            ),
            swatch_row3(false),
        ],
    );
    let w = resolve_all(&p);
    let r2 = &w.layers[1];
    let mut want = vec![it(0, "ch3=none", "")];
    for k in 1..=9 {
        want.push(it(k, "b1", &format!("1.{}", 10 - k)));
    }
    assert_eq!(items(r2), want, "9 b1, items 2.1 to 2.9 into 1.9 to 1.1");
    assert_eq!(count_texts(r2).0, "(9 dc)");
    let r3 = &w.layers[2];
    assert_eq!(
        base_order(r3),
        ["2.9", "2.8", "2.7", "2.6", "2.5", "2.4", "2.3", "2.2", "2.1"]
    );
    let last = r3.made.last().unwrap();
    assert_eq!(
        (last.id.item, anchors(last)),
        (9, "2.1".to_string()),
        "row 3's last stitch goes into the new 2.1, not the top of a turning chain"
    );
    assert!(diags(&p).is_empty(), "{:?}", keys(&diags(&p)));
}

// ---------------------------------------------------------------------------------------------
// Section 18: oracle motif 2.

fn motif() -> CrochetPattern {
    let mut p = piece(
        PieceStart::MagicRing,
        vec![
            (
                joined(vec![ch_as(3, B1), sts(B1, Target::Ring, 11), Instr::join()]),
                stitches(12),
            ),
            (
                joined(vec![
                    ch_none(1),
                    st(B0, ns()),
                    ch(2),
                    Instr::times(11, vec![st(B0, ns()), ch(2)]),
                    Instr::join(),
                ]),
                Some(StatedCount::stitches(12).with_spaces(12)),
            ),
            (
                joined(vec![
                    Instr::travel(nsp()),
                    ch_as(3, B1),
                    sts(B1, same(), 2),
                    st(B0, nsp()),
                    Instr::times(5, vec![sts(B1, nsp(), 3), st(B0, nsp())]),
                    Instr::join(),
                ]),
                Some(
                    StatedCount::default()
                        .with_identity(Counted::Basic(B1), 18)
                        .with_identity(Counted::Basic(B0), 6),
                ),
            ),
        ],
    );
    p.name = "Oracle motif 2".into();
    p
}

#[test]
fn motif_2_joined_rounds_and_chain_space_anchors() {
    let p = motif();
    let w = resolve_all(&p);
    use BaseUse::*;

    // Round 1: a counted ch 3 in the ring, 11 b1 in the ring, join into 1.0^.
    let r1 = &w.layers[0];
    let mut want = vec![it(0, "ch3=b1", "ring")];
    for k in 1..=11 {
        want.push(it(k, "b1", "ring"));
    }
    assert_eq!(items(r1), want);
    assert_eq!(moves(r1), vec![(SlipRole::Join, "1.0^".to_string(), 12)]);
    assert_eq!(base(r1), vec![("ring".to_string(), Worked)]);

    // Round 2: base begins with the join's target; "in same st as join" is `next stitch`.
    let r2 = &w.layers[1];
    let mut want_base = vec!["1.0^".to_string()];
    want_base.extend((1..=11).map(|k| format!("1.{k}")));
    assert_eq!(base_order(r2), want_base);
    assert!(base(r2).iter().all(|(_, u)| *u == Worked));
    let mut want = vec![it(0, "ch1=none", "")];
    for j in 0..=11u32 {
        let target = if j == 0 {
            "1.0^".to_string()
        } else {
            format!("1.{j}")
        };
        want.push(it(2 * j + 1, "b0", &target));
        want.push(it(2 * j + 2, "ch2", ""));
    }
    assert_eq!(items(r2), want);
    assert_eq!(moves(r2), vec![(SlipRole::Join, "2.1".to_string(), 25)]);

    // Round 3: a travelling slip stitch into sp 2.2, a counted ch 3 standing there, `same`, and
    // every other stitch passed by `next space`.
    let r3 = &w.layers[2];
    let mut want_base = Vec::new();
    for j in 0..12u32 {
        want_base.push((format!("2.{}", 2 * j + 1), Passed));
        want_base.push((format!("sp 2.{}", 2 * j + 2), Worked));
    }
    assert_eq!(base(r3), want_base);
    let mut want = vec![
        it(0, "ch3=b1", "sp 2.2"),
        it(1, "b1", "sp 2.2"),
        it(2, "b1", "sp 2.2"),
        it(3, "b0", "sp 2.4"),
    ];
    for f in 0..5u32 {
        for k in 0..3 {
            want.push(it(4 + 4 * f + k, "b1", &format!("sp 2.{}", 6 + 4 * f)));
        }
        want.push(it(7 + 4 * f, "b0", &format!("sp 2.{}", 8 + 4 * f)));
    }
    assert_eq!(items(r3), want);
    assert_eq!(
        moves(r3),
        vec![
            (SlipRole::Travel, "sp 2.2".to_string(), 0),
            (SlipRole::Join, "3.0^".to_string(), 24)
        ]
    );

    // Counts 12, 12 and 12 spaces, 24 (18 and 6); every stated count met.
    let texts: Vec<_> = w.layers.iter().map(count_texts).collect();
    assert_eq!(
        texts,
        vec![
            ("(12 dc)".to_string(), "(12 tr)".to_string()),
            ("(12 sc, 12 ch-2 sps)".into(), "(12 dc, 12 ch-2 sps)".into()),
            ("(18 dc, 6 sc)".into(), "(18 tr, 6 dc)".into()),
        ]
    );
    assert_eq!(w.layers[2].count.as_ref().unwrap().total_stitches(), 24);
    assert!(w.layers.iter().all(|l| l.stated == Some(StatedCheck::Met)));
    assert!(w.layers.iter().all(|l| l.facing == Some(Side::A)));

    // The only diagnostic: the 12 passed stitches of round 3.
    let ds = diags(&p);
    assert_eq!(keys(&ds), vec![("crochet.passed_over", Some(3), None)]);
    let want_passed: Vec<String> = (0..12).map(|j| format!("2.{}", 2 * j + 1)).collect();
    match &ds[0].detail {
        Detail::Positions { listed, total } => {
            assert_eq!(refs(listed), want_passed);
            assert_eq!(*total, 12);
        }
        other => panic!("{other:?}"),
    }
}

// ---------------------------------------------------------------------------------------------
// Section 19.1: disc 3, spiral rounds.

#[test]
fn disc_3_spiral_rounds() {
    let p = piece(
        PieceStart::MagicRing,
        vec![
            (
                spiral(vec![ch_none(1), sts(B0, Target::Ring, 6)]),
                stitches(6),
            ),
            (
                spiral(vec![Instr::to_end(vec![sts(B0, ns(), 2)])]),
                stitches(12),
            ),
            (
                spiral(vec![Instr::to_end(vec![st(B0, ns()), sts(B0, ns(), 2)])]),
                stitches(18),
            ),
            (
                spiral(vec![Instr::to_end(vec![
                    st(B0, ns()),
                    Instr::tog(B0, vec![ns(), ns()]),
                ])]),
                stitches(12),
            ),
        ],
    );
    let w = resolve_all(&p);

    let mut want = vec![it(0, "ch1=none", "")];
    for k in 1..=6 {
        want.push(it(k, "b0", "ring"));
    }
    assert_eq!(items(&w.layers[0]), want);

    let mut want = Vec::new();
    for i in 0..6u32 {
        want.push(it(2 * i + 1, "b0", &format!("1.{}", i + 1)));
        want.push(it(2 * i + 2, "b0", &format!("1.{}", i + 1)));
    }
    assert_eq!(items(&w.layers[1]), want);

    let mut want = Vec::new();
    for i in 0..6u32 {
        want.push(it(3 * i + 1, "b0", &format!("2.{}", 2 * i + 1)));
        want.push(it(3 * i + 2, "b0", &format!("2.{}", 2 * i + 2)));
        want.push(it(3 * i + 3, "b0", &format!("2.{}", 2 * i + 2)));
    }
    assert_eq!(items(&w.layers[2]), want);

    let mut want = Vec::new();
    for i in 0..6u32 {
        want.push(it(2 * i + 1, "b0", &format!("3.{}", 3 * i + 1)));
        want.push(it(
            2 * i + 2,
            "tog(b0x2)",
            &format!("3.{}, 3.{}", 3 * i + 2, 3 * i + 3),
        ));
    }
    assert_eq!(items(&w.layers[3]), want);

    // Each round's base: the previous round in work order from its first stitch, all worked.
    for (r, n) in [(2usize, 6u32), (3, 12), (4, 18)] {
        let want: Vec<String> = (1..=n).map(|k| format!("{}.{k}", r - 1)).collect();
        assert_eq!(base_order(&w.layers[r - 1]), want, "round {r}");
        assert!(base(&w.layers[r - 1])
            .iter()
            .all(|(_, u)| *u == BaseUse::Worked));
    }
    // Derived markers in 1.1, 2.1, 3.1, 4.1; no joins.
    let markers: Vec<_> = w
        .layers
        .iter()
        .map(|l| l.spiral_marker.map(|m| m.to_string()))
        .collect();
    assert_eq!(
        markers,
        [
            Some("1.1".to_string()),
            Some("2.1".into()),
            Some("3.1".into()),
            Some("4.1".into())
        ]
    );
    assert!(w.layers.iter().all(|l| l.moves.is_empty()));
    let counts: Vec<_> = w.layers.iter().map(|l| count_texts(l).0).collect();
    assert_eq!(counts, ["(6 sc)", "(12 sc)", "(18 sc)", "(12 sc)"]);
    assert!(validate(&p).is_empty(), "{:?}", keys(&validate(&p)));
}

// ---------------------------------------------------------------------------------------------
// Section 19.2: strip 4.

fn strip_4() -> CrochetPattern {
    let mut p = piece(
        PieceStart::FoundationChain(11),
        vec![
            (
                row(vec![
                    Instr::start_from_foundation(3, CountsAs::Stitch(B1)),
                    Instr::to_end(vec![st(B1, nch())]),
                ]),
                stitches(9),
            ),
            (
                row(vec![
                    Instr::start(
                        4,
                        CountsAs::StitchAndSpace {
                            stitch: B1,
                            chains: 1,
                        },
                    ),
                    sk(1),
                    st(B1, ns()),
                    Instr::to_end(vec![ch(1), sk(1), st(B1, ns())]),
                ]),
                Some(StatedCount::stitches(5).with_spaces(4)),
            ),
            (
                row(vec![
                    ch_none(1),
                    st(B0, ns()),
                    Instr::to_end(vec![st(B0, nsp()), st(B0, ns())]),
                ]),
                stitches(9),
            ),
            (
                row(vec![
                    ch_none(1),
                    Instr::to_last(2, vec![st(B0, ns())]),
                    Instr::LeaveUnworked,
                ]),
                stitches(7),
            ),
            (
                row(vec![
                    ch_none(1),
                    Instr::named("inc", Some(ns())),
                    Instr::to_end(vec![st(B0, ns())]),
                ]),
                stitches(8),
            ),
        ],
    );
    p.legend.push(LegendEntry {
        id: LegendId::new("inc"),
        name: "increase".into(),
        abbreviation: "inc".into(),
        body: vec![sts(B0, Target::UseSite, 2)],
    });
    p
}

#[test]
fn strip_4_counted_form_a_stitch_and_space_to_last_and_a_named_stitch() {
    let p = strip_4();
    let w = resolve_all(&p);
    use BaseUse::*;

    // Row 1: F9 to F11 taken, counting as b1, standing on nothing; 1.1 to 1.8 into F8 to F1.
    let r1 = &w.layers[0];
    let mut want = vec![it(0, "ch3=b1@F9-F11", "")];
    for k in 1..=8 {
        want.push(it(k, "b1", &format!("F{}", 9 - k)));
    }
    assert_eq!(items(r1), want);
    let want_base: Vec<_> = (1..=8).rev().map(|i| format!("F{i}")).collect();
    assert_eq!(base_order(r1), want_base, "the cursor starts before F8");

    // Row 2.
    let r2 = &w.layers[1];
    assert_eq!(
        items(r2),
        vec![
            it(0, "ch4=b1+sp1", "1.8"),
            it(1, "b1", "1.6"),
            it(2, "ch1", ""),
            it(3, "b1", "1.4"),
            it(4, "ch1", ""),
            it(5, "b1", "1.2"),
            it(6, "ch1", ""),
            it(7, "b1", "1.0^"),
        ]
    );
    assert_eq!(
        base(r2),
        vec![
            ("1.8".to_string(), Worked),
            ("1.7".to_string(), Skipped),
            ("1.6".to_string(), Worked),
            ("1.5".to_string(), Skipped),
            ("1.4".to_string(), Worked),
            ("1.3".to_string(), Skipped),
            ("1.2".to_string(), Worked),
            ("1.1".to_string(), Skipped),
            ("1.0^".to_string(), Worked),
        ]
    );

    // Row 3: the ch-1 space of 2.0 is met after 2.1 and before 2.0^.
    let r3 = &w.layers[2];
    assert_eq!(
        base_order(r3),
        ["2.7", "sp 2.6", "2.5", "sp 2.4", "2.3", "sp 2.2", "2.1", "sp 2.0", "2.0^"]
    );
    assert_eq!(
        items(r3),
        vec![
            it(0, "ch1=none", ""),
            it(1, "b0", "2.7"),
            it(2, "b0", "sp 2.6"),
            it(3, "b0", "2.5"),
            it(4, "b0", "sp 2.4"),
            it(5, "b0", "2.3"),
            it(6, "b0", "sp 2.2"),
            it(7, "b0", "2.1"),
            it(8, "b0", "sp 2.0"),
            it(9, "b0", "2.0^"),
        ]
    );

    // Row 4: to_last(2), 7 repetitions; 3.2 and 3.1 left on purpose.
    let r4 = &w.layers[3];
    let mut want = vec![it(0, "ch1=none", "")];
    for k in 1..=7 {
        want.push(it(k, "b0", &format!("3.{}", 10 - k)));
    }
    assert_eq!(items(r4), want);
    let uses: Vec<_> = base(r4).into_iter().map(|(_, u)| u).collect();
    let mut want_uses = vec![Worked; 7];
    want_uses.extend([LeftUnworked, LeftUnworked]);
    assert_eq!(uses, want_uses);

    // Row 5: `inc` into 4.7 expands into two items.
    let r5 = &w.layers[4];
    let mut want = vec![
        it(0, "ch1=none", ""),
        it(1, "b0", "4.7"),
        it(2, "b0", "4.7"),
    ];
    for k in 3..=8 {
        want.push(it(k, "b0", &format!("4.{}", 9 - k)));
    }
    assert_eq!(items(r5), want);
    assert_eq!(r5.made[1].named, Some(0));
    assert_eq!(r5.made[2].named, Some(0));
    assert_eq!(r5.made[3].named, None);

    let counts: Vec<_> = w.layers.iter().map(|l| count_texts(l).0).collect();
    assert_eq!(
        counts,
        ["(9 dc)", "(5 dc, 4 ch-1 sps)", "(9 sc)", "(7 sc)", "(8 sc)"]
    );
    let facing: Vec<_> = w.layers.iter().map(|l| l.facing).collect();
    use Side::{A, B};
    assert_eq!(facing, [Some(A), Some(B), Some(A), Some(B), Some(A)]);
    assert!(validate(&p).is_empty(), "{:?}", keys(&validate(&p)));
}

#[test]
fn strip_4_row_1_chain_stands_on_no_position_not_on_f8() {
    // Section 19.2's check: "Had the counted chain stood on the first remaining chain F8, next chain
    // would start at F7 and give 1 + 7 = 8 against a correct pattern's 9, which is why section 6
    // stands a form (a) chain on no position."
    let w = resolve_all(&strip_4());
    let r1 = &w.layers[0];
    let chain = &r1.made[0];
    assert!(chain.anchors.is_empty(), "the ch 3 stands on no position");
    assert_eq!(
        what(&chain.made),
        "ch3=b1@F9-F11",
        "it is made of F9 to F11"
    );
    // So F8 is still to be worked, and the first `next chain` works it: F8 is under 1.1.
    assert_eq!(base(r1)[0], ("F8".to_string(), BaseUse::Worked));
    assert_eq!(anchors(&r1.made[1]), "F8");
    assert!(base(r1)
        .iter()
        .all(|(p, _)| !["F9", "F10", "F11"].contains(&p.as_str())));
    assert_eq!(count_texts(r1).0, "(9 dc)");

    // The counterfactual reading on the same base (F8 to F1): the chain standing on F8, the cursor
    // on it, the first `next chain` F7. The engine expresses "a counted chain standing on the first
    // position" only for a chain of new chains, so the same base is given by a foundation of 8.
    let stood = piece(
        PieceStart::FoundationChain(8),
        vec![(
            row(vec![ch_as(3, B1), Instr::to_end(vec![st(B1, nch())])]),
            stitches(9),
        )],
    );
    let c = resolve_all(&stood);
    let c1 = &c.layers[0];
    assert_eq!(base_order(c1), base_order(r1), "the same base, F8 to F1");
    assert_eq!(anchors(&c1.made[0]), "F8", "standing on F8");
    assert_eq!(anchors(&c1.made[1]), "F7", "next chain is F7");
    assert_eq!(count_texts(c1).0, "(8 dc)", "1 + 7 = 8");
    assert_eq!(codes(&validate(&stood)), ["crochet.count_mismatch"]);
}

// ---------------------------------------------------------------------------------------------
// Section 19.3: strip 5, a standing chain on the foundation (form b).

#[test]
fn strip_5_form_b() {
    let p = piece(
        PieceStart::FoundationChain(9),
        vec![
            (
                row(vec![ch_as(3, B1), Instr::to_end(vec![st(B1, nch())])]),
                stitches(9),
            ),
            (
                row(vec![ch_none(1), Instr::to_end(vec![st(B0, ns())])]),
                stitches(9),
            ),
        ],
    );
    let w = resolve_all(&p);
    let r1 = &w.layers[0];
    let mut want = vec![it(0, "ch3=b1", "F9")];
    for k in 1..=8 {
        want.push(it(k, "b1", &format!("F{}", 9 - k)));
    }
    assert_eq!(items(r1), want, "stands on F9; the first next chain is F8");
    let r2 = &w.layers[1];
    let mut want_base: Vec<String> = (1..=8).rev().map(|k| format!("1.{k}")).collect();
    want_base.push("1.0^".into());
    assert_eq!(base_order(r2), want_base);
    let mut want = vec![it(0, "ch1=none", "")];
    for k in 1..=8 {
        want.push(it(k, "b0", &format!("1.{}", 9 - k)));
    }
    want.push(it(9, "b0", "1.0^"));
    assert_eq!(items(r2), want, "row 2's last anchor is 1.0^");
    // 9 foundation chains and 3 standing chains: 12 chains for 9 stitches.
    let standing = match r1.made[0].made {
        Made::StartChain { chains, .. } => chains,
        _ => 0,
    };
    assert_eq!(9 + standing, 12);
    let counts: Vec<_> = w.layers.iter().map(|l| count_texts(l).0).collect();
    assert_eq!(counts, ["(9 dc)", "(9 sc)"]);
    assert!(validate(&p).is_empty(), "{:?}", keys(&validate(&p)));
}

// ---------------------------------------------------------------------------------------------
// Section 19.4: strip 6, foundation stitches as layer 1.

#[test]
fn strip_6_foundation_stitches() {
    let p = piece(
        PieceStart::FoundationStitches,
        vec![
            (
                LayerKind::Foundation {
                    stitch: B0,
                    stitches: 9,
                },
                stitches(9),
            ),
            (
                row(vec![ch_as(3, B1), Instr::to_end(vec![st(B1, ns())])]),
                stitches(9),
            ),
        ],
    );
    let w = resolve_all(&p);
    let l1 = &w.layers[0];
    let want: Vec<_> = (1..=9).map(|k| it(k, "fb0", "")).collect();
    assert_eq!(items(l1), want, "items 1.1 to 1.9, no item 0");
    assert_eq!(l1.base, ResolvedBase::None);
    assert_eq!(l1.facing, Some(Side::A));
    let l2 = &w.layers[1];
    let want_base: Vec<String> = (1..=9).rev().map(|k| format!("1.{k}")).collect();
    assert_eq!(base_order(l2), want_base);
    let mut want = vec![it(0, "ch3=b1", "1.9")];
    for k in 1..=8 {
        want.push(it(k, "b1", &format!("1.{}", 9 - k)));
    }
    assert_eq!(items(l2), want);
    assert_eq!(l2.facing, Some(Side::B));
    let counts: Vec<_> = w.layers.iter().map(|l| count_texts(l).0).collect();
    assert_eq!(counts, ["(9 sc)", "(9 dc)"]);
    assert!(validate(&p).is_empty(), "{:?}", keys(&validate(&p)));
}

// ---------------------------------------------------------------------------------------------
// Section 19.5: ring 7, a chain ring, a turned round and a marker.

#[test]
fn ring_7_chain_ring_turned_round_and_marker() {
    let p = piece(
        PieceStart::ChainRing(4),
        vec![
            (
                joined(vec![ch_none(1), sts(B0, Target::Ring, 8), Instr::join()]),
                stitches(8),
            ),
            (
                joined_turned(vec![
                    ch_none(1),
                    sts(B0, ns(), 2).marked("A"),
                    Instr::to_end(vec![sts(B0, ns(), 2)]),
                    Instr::join_marker("A"),
                ]),
                stitches(16),
            ),
        ],
    );
    let w = resolve_all(&p);
    let r1 = &w.layers[0];
    let mut want = vec![it(0, "ch1=none", "")];
    for k in 1..=8 {
        want.push(it(k, "b0", "ring"));
    }
    assert_eq!(items(r1), want);
    assert_eq!(
        base_order(r1),
        ["ring"],
        "the chain ring's chains are not positions"
    );
    assert_eq!(moves(r1), vec![(SlipRole::Join, "1.1".to_string(), 9)]);

    let r2 = &w.layers[1];
    let mut want_base = vec!["1.1".to_string()];
    want_base.extend((2..=8).rev().map(|k| format!("1.{k}")));
    assert_eq!(
        base_order(r2),
        want_base,
        "the join's target, then the rest reversed"
    );
    assert_eq!(r2.facing, Some(Side::B));
    let mut want = vec![
        it(0, "ch1=none", ""),
        it(1, "b0", "1.1"),
        it(2, "b0", "1.1"),
    ];
    for k in 1..=7u32 {
        let t = format!("1.{}", 9 - k);
        want.push(it(2 * k + 1, "b0", &t));
        want.push(it(2 * k + 2, "b0", &t));
    }
    assert_eq!(items(r2), want);
    assert_eq!(r2.made[1].mark.as_deref(), Some("A"));
    assert_eq!(moves(r2), vec![(SlipRole::Join, "2.1".to_string(), 17)]);
    let counts: Vec<_> = w.layers.iter().map(|l| count_texts(l).0).collect();
    assert_eq!(counts, ["(8 sc)", "(16 sc)"]);
    assert!(validate(&p).is_empty(), "{:?}", keys(&validate(&p)));
}

// ---------------------------------------------------------------------------------------------
// Section 19.6: strip 8, opaque items.

fn strip_8(popcorn: Instr) -> CrochetPattern {
    piece(
        PieceStart::FoundationChain(6),
        vec![
            (
                row(vec![
                    Instr::start_from_foundation(1, CountsAs::Nothing),
                    Instr::to_end(vec![st(B0, nch())]),
                ]),
                stitches(5),
            ),
            (
                row(vec![
                    ch_none(1),
                    st(B0, ns()),
                    popcorn,
                    st(
                        B1,
                        Target::unmodelled("around the post of next st, from the front", 1),
                    ),
                    Instr::times(2, vec![st(B0, ns())]),
                ]),
                stitches(5),
            ),
            (
                row(vec![ch_none(1), Instr::to_end(vec![st(B0, ns())])]),
                stitches(5),
            ),
        ],
    )
}

#[test]
fn strip_8_opaque_items() {
    let p = strip_8(Instr::opaque("5-dc popcorn in next st", Some(1), Some(1)));
    let w = resolve_all(&p);
    use BaseUse::*;
    let r1 = &w.layers[0];
    let want: Vec<_> = std::iter::once(it(0, "ch1=none@F6-F6", ""))
        .chain((1..=5).map(|k| it(k, "b0", &format!("F{}", 6 - k))))
        .collect();
    assert_eq!(items(r1), want);

    let r2 = &w.layers[1];
    assert_eq!(
        items(r2),
        vec![
            it(0, "ch1=none", ""),
            it(1, "b0", "1.5"),
            it(2, "opaque", "unmodelled"),
            it(3, "b1", "unmodelled"),
            it(4, "b0", "1.2"),
            it(5, "b0", "1.1"),
        ]
    );
    assert_eq!(
        base(r2),
        vec![
            ("1.5".to_string(), Worked),
            ("1.4".to_string(), Unverified),
            ("1.3".to_string(), Unverified),
            ("1.2".to_string(), Worked),
            ("1.1".to_string(), Worked),
        ]
    );
    assert!(r2.made[2].unverified && r2.made[3].unverified && !r2.made[1].unverified);
    assert_eq!(
        count_texts(r2),
        (
            "(3 sc, 1 dc, 1 not checked)".to_string(),
            "(3 dc, 1 tr, 1 not checked)".to_string()
        )
    );
    assert_eq!(r2.stated, Some(StatedCheck::Met), "5 positions");

    let r3 = &w.layers[2];
    assert_eq!(base_order(r3), ["2.5", "2.4", "2.3", "2.2", "2.1"]);
    let want: Vec<_> = std::iter::once(it(0, "ch1=none", ""))
        .chain((1..=5).map(|k| it(k, "b0", &format!("2.{}", 6 - k))))
        .collect();
    assert_eq!(items(r3), want);
    let into_unverified: Vec<_> = r3
        .made
        .iter()
        .filter(|m| m.unverified)
        .map(|m| m.id.item)
        .collect();
    assert_eq!(into_unverified, [4], "3.4 works into the unverified 2.2");
    assert_eq!(count_texts(r3).0, "(5 sc)");

    let ds = validate(&p);
    assert_eq!(
        keys(&ds),
        vec![
            ("crochet.unsupported_op", Some(2), Some(2)),
            ("crochet.unsupported_target", Some(2), Some(3)),
        ],
        "row 3 adds nothing"
    );
    assert_eq!(
        p.source_terms,
        Terms::Us,
        "the author's words keep the author's terms"
    );
}

#[test]
fn strip_8b_an_opaque_item_without_counts() {
    let p = strip_8(Instr::opaque("5-dc popcorn in next st", None, None));
    let w = resolve_all(&p);
    let r2 = &w.layers[1];
    assert_eq!(
        items(r2),
        vec![it(0, "ch1=none", ""), it(1, "b0", "1.5")],
        "nothing after 2.1 has an item number"
    );
    assert_eq!(r2.count, None);
    assert_eq!(r2.unknown_from, Some(vec![2]));
    let r3 = &w.layers[2];
    assert_eq!(r3.base, ResolvedBase::Unknown);
    assert!(r3.made.is_empty());
    for l in [r2, r3] {
        assert_eq!(count_texts(l).0, "(count unknown)");
        assert_eq!(l.stated, Some(StatedCheck::CannotBeChecked));
    }
    let ds = validate(&p);
    let located: Vec<_> = ds
        .iter()
        .map(|d| {
            (
                d.code.as_str(),
                d.location.layer,
                d.location.path.clone(),
                d.location.item,
            )
        })
        .collect();
    assert_eq!(
        located,
        vec![
            ("crochet.count_unknown", Some(2), vec![2], None),
            ("crochet.unsupported_op", Some(2), vec![2], None),
            ("crochet.unsupported_target", Some(2), vec![3], None),
        ],
        "no anchor error, base_unfinished or count_mismatch after it"
    );
    let unknown = ds
        .iter()
        .find(|d| d.code == CrochetCode::CountUnknown)
        .unwrap();
    assert_eq!(unknown.detail, Detail::Layers { first: 2, last: 3 });
}

// ---------------------------------------------------------------------------------------------
// Section 23's warnings, one small piece each.

fn five_sc_row() -> (LayerKind, Option<StatedCount>) {
    (
        row(vec![
            Instr::start_from_foundation(1, CountsAs::Nothing),
            Instr::to_end(vec![st(B0, nch())]),
        ]),
        None,
    )
}

#[test]
fn warning_base_unfinished_with_two_positions() {
    let p = piece(
        PieceStart::FoundationChain(6),
        vec![
            five_sc_row(),
            (
                row(vec![ch_none(1), Instr::times(3, vec![st(B0, ns())])]),
                None,
            ),
        ],
    );
    let ds = validate(&p);
    assert_eq!(keys(&ds), vec![("crochet.base_unfinished", Some(2), None)]);
    assert_eq!(
        ds[0].detail,
        Detail::Positions {
            listed: vec![
                PosRef::Top(ItemId::new(1, 2)),
                PosRef::Top(ItemId::new(1, 1))
            ],
            total: 2
        }
    );
}

#[test]
fn warning_leave_unworked_with_nothing_left() {
    let p = piece(
        PieceStart::FoundationChain(6),
        vec![
            five_sc_row(),
            (
                row(vec![
                    ch_none(1),
                    Instr::to_end(vec![st(B0, ns())]),
                    Instr::LeaveUnworked,
                ]),
                None,
            ),
        ],
    );
    let ds = validate(&p);
    assert_eq!(
        keys(&ds),
        vec![("crochet.leave_unworked_empty", Some(2), None)]
    );
    assert_eq!(ds[0].location.path, vec![2]);
}

#[test]
fn warning_a_starting_chain_in_spiral_round_2() {
    let p = piece(
        PieceStart::MagicRing,
        vec![
            (spiral(vec![ch_none(1), sts(B0, Target::Ring, 6)]), None),
            (
                spiral(vec![ch_none(1), Instr::to_end(vec![sts(B0, ns(), 2)])]),
                None,
            ),
        ],
    );
    let ds = validate(&p);
    assert_eq!(
        keys(&ds),
        vec![("crochet.spiral_start_chain", Some(2), None)]
    );
    assert_eq!(ds[0].location.path, vec![0]);
    // Still resolved: a warning, not an error.
    assert_eq!(count_texts(&resolve_all(&p).layers[1]).0, "(12 sc)");
}
