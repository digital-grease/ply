//! The rules M11-01 settled where ADR 0022 leaves a choice to the engine (recorded in the ADR's
//! amendment of 2026-11-18), each pinned by a small piece worked by hand.
//!
//! Run: `cargo test -p ply-crochet --test engine_rules`

mod common;

use common::*;
use ply_crochet::*;

/// Row 1 of 5 `b0`, then a row 2 of `b0`, ch-3, `b0`: row 3 meets 2.3, sp 2.2 (3 chains), 2.1.
fn mesh3() -> CrochetPattern {
    piece(
        PieceStart::FoundationChain(6),
        vec![
            (
                row(vec![
                    Instr::start_from_foundation(1, CountsAs::Nothing),
                    Instr::to_end(vec![st(B0, nch())]),
                ]),
                None,
            ),
            (
                row(vec![
                    ch_none(1),
                    st(B0, ns()),
                    ch(3),
                    Instr::skip(3, PosKind::Stitch),
                    st(B0, ns()),
                ]),
                None,
            ),
        ],
    )
}

#[test]
fn a_space_worked_chain_by_chain_names_each_chain_and_passes_the_rest() {
    let mut p = mesh3();
    // sc in first st, sc in next ch (the first chain met of the ch-3), then sc in next st: the two
    // chains still to come in that space are passed over.
    p.push(
        row(vec![ch_none(1), st(B0, ns()), st(B0, nch()), st(B0, ns())]),
        None,
    );
    let w = resolve_all(&p);
    let r3 = &w.layers[2];
    // Met after a turn, the run's chains come last-made first: chain 3 of 2.2 is met first.
    assert_eq!(
        items(r3),
        vec![
            it(0, "ch1=none", ""),
            it(1, "b0", "2.3"),
            it(2, "b0", "2.2#3"),
            it(3, "b0", "2.1"),
        ]
    );
    let slot = &r3.base_slots()[1];
    assert_eq!(slot.used, BaseUse::ByChain);
    assert_eq!(
        slot.chains,
        Some(ChainUses {
            visited: vec![BaseUse::Worked],
            rest: BaseUse::Passed,
            rest_count: 2
        })
    );
    let ds = validate(&p);
    assert_eq!(codes(&ds), ["crochet.passed_over"]);
    match &ds[0].detail {
        Detail::Positions { listed, total } => {
            assert_eq!(refs(listed), ["2.2#2", "2.2#1"]);
            assert_eq!(*total, 2);
        }
        other => panic!("{other:?}"),
    }
}

#[test]
fn chain_parts_are_kept_on_foundation_and_run_chains() {
    let p = piece(
        PieceStart::FoundationChain(4),
        vec![(
            row(vec![
                Instr::start_from_foundation(1, CountsAs::Nothing),
                Instr::to_end(vec![st(B0, Target::next_chain_in(ChainPart::BackBump))]),
            ]),
            None,
        )],
    );
    let w = resolve_all(&p);
    assert_eq!(anchors(&w.layers[0].made[1]), "F3/back_bump");
    assert!(validate(&p).is_empty());
}

#[test]
fn same_after_a_skip_works_the_skipped_position() {
    let mut p = mesh3();
    p.push(
        row(vec![
            ch_none(1),
            sk(1),
            st(B0, same()),
            Instr::to_end(vec![st(B0, Target::NEXT_ANY)]),
        ]),
        None,
    );
    let w = resolve_all(&p);
    let r3 = &w.layers[2];
    assert_eq!(items(r3)[1], it(1, "b0", "2.3"));
    assert_eq!(base(r3)[0].1, BaseUse::Worked, "worked wins over skipped");
    assert!(validate(&p).is_empty());
}

#[test]
fn travelling_slip_stitches_mid_row_work_a_position_and_make_none() {
    let mut p = mesh3();
    p.push(
        row(vec![
            ch_none(1),
            st(B0, ns()),
            Instr::travel(nsp()),
            st(B0, ns()),
        ]),
        None,
    );
    let w = resolve_all(&p);
    let r3 = &w.layers[2];
    assert_eq!(moves(r3), vec![(SlipRole::Travel, "sp 2.2".to_string(), 2)]);
    assert_eq!(items(r3).len(), 3, "the travel stitch is no item");
    assert_eq!(count_texts(r3).0, "(2 sc)");
    assert!(validate(&p).is_empty());
}

#[test]
fn an_opaque_layer_with_a_stated_count_gives_unverified_positions() {
    let mut p = mesh3();
    p.push(
        LayerKind::Opaque {
            text: "work 4 rows in Tunisian simple stitch".into(),
        },
        stitches(4),
    );
    p.push(
        row(vec![ch_none(1), Instr::to_end(vec![st(B0, ns())])]),
        stitches(4),
    );
    let w = resolve_all(&p);
    let o = &w.layers[2];
    assert!(o.base_slots().iter().all(|s| s.used == BaseUse::Unverified));
    assert_eq!(count_texts(o).0, "(4 not checked)");
    assert_eq!(o.stated, Some(StatedCheck::CannotBeChecked));
    assert_eq!(o.facing, None);
    let r4 = &w.layers[3];
    assert!(r4.made[1..].iter().all(|m| m.unverified));
    assert_eq!(r4.facing, None, "facing is unknown after an opaque layer");
    assert_eq!(r4.stated, Some(StatedCheck::Met));
    assert_eq!(codes(&validate(&p)), ["crochet.unsupported_layer"]);
}

#[test]
fn an_opaque_layer_without_a_count_leaves_itself_and_later_layers_unknown() {
    let mut p = mesh3();
    p.push(
        LayerKind::Opaque {
            text: "rep rows 1 and 2 until 20 cm".into(),
        },
        None,
    );
    p.push(
        row(vec![ch_none(1), Instr::to_end(vec![st(B0, ns())])]),
        stitches(4),
    );
    let w = resolve_all(&p);
    assert!(w.layers[2].count.is_none() && w.layers[3].count.is_none());
    assert_eq!(w.layers[3].stated, Some(StatedCheck::CannotBeChecked));
    let ds = validate(&p);
    assert_eq!(
        codes(&ds),
        ["crochet.count_unknown", "crochet.unsupported_layer"]
    );
    assert_eq!(ds[0].detail, Detail::Layers { first: 3, last: 4 });
}

#[test]
fn a_turned_round_after_an_opaque_layer_is_accepted() {
    let p = piece(
        PieceStart::MagicRing,
        vec![
            (
                LayerKind::Opaque {
                    text: "a round of puff stitches".into(),
                },
                stitches(8),
            ),
            (
                joined_turned(vec![
                    ch_none(1),
                    Instr::to_end(vec![st(B0, ns())]),
                    Instr::join(),
                ]),
                stitches(8),
            ),
        ],
    );
    let w = resolve_all(&p);
    assert_eq!(count_texts(&w.layers[1]).0, "(8 sc)");
    assert_eq!(codes(&validate(&p)), ["crochet.unsupported_layer"]);
}

#[test]
fn a_ring_is_worked_into_with_ring_never_walked() {
    let p = piece(
        PieceStart::MagicRing,
        vec![(joined(vec![ch_none(1), st(B0, ns()), Instr::join()]), None)],
    );
    let ds = validate(&p);
    assert!(
        codes(&ds).contains(&"crochet.anchor_kind"),
        "{:?}",
        codes(&ds)
    );
    // A round 1 that never works into the ring leaves it not reached.
    assert!(codes(&ds).contains(&"crochet.base_unfinished"));
}

#[test]
fn a_join_with_nothing_to_join_into() {
    let p = piece(
        PieceStart::MagicRing,
        vec![(joined(vec![ch_none(1), ch(3), Instr::join()]), None)],
    );
    let ds = validate(&p);
    let d = ds
        .iter()
        .find(|d| d.code == CrochetCode::JoinTarget)
        .unwrap();
    assert_eq!(
        (d.location.layer, d.location.path.clone()),
        (Some(1), vec![2])
    );
}

#[test]
fn a_marker_placed_by_every_repetition_is_a_duplicate() {
    let p = piece(
        PieceStart::MagicRing,
        vec![(
            joined(vec![
                ch_none(1),
                Instr::times(2, vec![sts(B0, Target::Ring, 3).marked("A")]),
                Instr::join_marker("A"),
            ]),
            None,
        )],
    );
    let ds = validate(&p);
    let d = ds
        .iter()
        .find(|d| d.code == CrochetCode::MarkerDuplicate)
        .unwrap();
    assert_eq!(
        (d.location.repetition.clone(), d.location.item),
        (vec![2], Some(4))
    );
    // The join goes into the first placement.
    let w = resolve_all(&p);
    assert_eq!(
        moves(&w.layers[0]),
        vec![(SlipRole::Join, "1.1".to_string(), 7)]
    );
}

#[test]
fn a_named_stitch_marks_the_first_stitch_it_makes() {
    let mut p = piece(
        PieceStart::MagicRing,
        vec![(
            joined(vec![
                ch_none(1),
                Instr::named("vst", Some(Target::Ring)).marked("A"),
                sts(B0, Target::Ring, 4),
                Instr::join_marker("A"),
            ]),
            None,
        )],
    );
    p.legend.push(LegendEntry {
        id: LegendId::new("vst"),
        name: "V-stitch".into(),
        abbreviation: "V-st".into(),
        body: vec![st(B1, Target::UseSite), ch(1), st(B1, same())],
    });
    let w = resolve_all(&p);
    let r = &w.layers[0];
    assert_eq!(
        items(r)[..4],
        [
            it(0, "ch1=none", ""),
            it(1, "b1", "ring"),
            it(2, "ch1", ""),
            it(3, "b1", "ring")
        ]
    );
    assert_eq!(r.made[1].mark.as_deref(), Some("A"));
    assert_eq!(moves(r), vec![(SlipRole::Join, "1.1".to_string(), 8)]);
    assert!(validate(&p).is_empty(), "{:?}", keys(&validate(&p)));
}

#[test]
fn validation_reads_no_label_set_and_no_source_terms() {
    let mut a = mesh3();
    a.push(row(vec![ch_none(1), st(B0, nsp())]), stitches(9));
    let mut b = a.clone();
    let mut c = a.clone();
    a.source_terms = Terms::Us;
    b.source_terms = Terms::Uk;
    c.source_terms = Terms::Unstated;
    assert_eq!(validate(&a), validate(&b));
    assert_eq!(validate(&a), validate(&c));
    assert_eq!(
        try_resolve_all(&a, &CrochetLimits::DEFAULT),
        try_resolve_all(&b, &CrochetLimits::DEFAULT)
    );
    // No stitch name in any message: a view adds them in the viewer's set.
    for d in validate(&a) {
        for word in [" sc", " dc", " tr", " hdc"] {
            assert!(!d.message.contains(word), "{}", d.message);
        }
    }
}

#[test]
fn windows_outside_the_piece_are_refused() {
    let p = mesh3();
    for (a, b) in [(0, 1), (2, 1), (1, 3)] {
        assert_eq!(
            try_resolve(&p, a..=b, &CrochetLimits::DEFAULT),
            Err(CrochetError::InvalidWindow {
                first: a,
                last: b,
                layers: 2
            })
        );
    }
    let empty = CrochetPattern::new(PieceStart::MagicRing);
    let w = try_resolve_all(&empty, &CrochetLimits::DEFAULT).unwrap();
    assert_eq!((w.first, w.last, w.layers.len()), (1, 0, 0));
}

#[test]
fn limits_that_cannot_be_used_are_refused() {
    let limits = CrochetLimits {
        max_repeat_depth: 100,
        ..CrochetLimits::DEFAULT
    };
    assert_eq!(
        codes(&validate_with(&mesh3(), &limits)),
        ["crochet.too_large"]
    );
}

#[test]
fn stated_counts_by_identity_compare_exactly() {
    let p = piece(
        PieceStart::FoundationChain(6),
        vec![(
            row(vec![
                Instr::start_from_foundation(1, CountsAs::Nothing),
                Instr::to_end(vec![st(B0, nch())]),
            ]),
            Some(StatedCount::default().with_identity(Counted::Basic(B1), 5)),
        )],
    );
    let ds = validate(&p);
    assert_eq!(codes(&ds), ["crochet.count_mismatch"]);
    assert_eq!(
        ds[0].detail,
        Detail::Counts(vec![
            CountDiff {
                what: CountWhat::Identity(Counted::Basic(B0)),
                stated: 0,
                derived: 5
            },
            CountDiff {
                what: CountWhat::Identity(Counted::Basic(B1)),
                stated: 5,
                derived: 0
            },
        ])
    );
}

#[test]
fn a_round_1_on_a_foundation_chain() {
    // "Ch 2, 6 sc in 2nd ch from hook" (ADR 0022 section 6): F2 taken, not counted; 6 b0 into F1.
    let p = piece(
        PieceStart::FoundationChain(2),
        vec![
            (
                joined(vec![
                    Instr::start_from_foundation(1, CountsAs::Nothing),
                    st(B0, nch()),
                    sts(B0, same(), 5),
                    Instr::join(),
                ]),
                stitches(6),
            ),
            (
                joined(vec![
                    ch_none(1),
                    Instr::to_end(vec![sts(B0, ns(), 2)]),
                    Instr::join(),
                ]),
                stitches(12),
            ),
        ],
    );
    let w = resolve_all(&p);
    let want: Vec<_> = std::iter::once(it(0, "ch1=none@F2-F2", ""))
        .chain((1..=6).map(|k| it(k, "b0", "F1")))
        .collect();
    assert_eq!(items(&w.layers[0]), want);
    assert_eq!(count_texts(&w.layers[1]).0, "(12 sc)");
    assert!(validate(&p).is_empty(), "{:?}", keys(&validate(&p)));
}

fn five_sc() -> CrochetPattern {
    piece(
        PieceStart::FoundationChain(6),
        vec![(
            row(vec![
                Instr::start_from_foundation(1, CountsAs::Nothing),
                Instr::to_end(vec![st(B0, nch())]),
            ]),
            None,
        )],
    )
}

#[test]
fn a_named_stitch_whose_body_is_opaque_is_opaque_as_a_whole() {
    // ADR 0022 section 9: "A body that uses anything opaque makes the named stitch opaque".
    let mut p = five_sc();
    p.legend.push(LegendEntry {
        id: LegendId::new("pc"),
        name: "popcorn shell".into(),
        abbreviation: "pc-shell".into(),
        body: vec![
            sts(B1, Target::UseSite, 2),
            Instr::opaque("popcorn", Some(0), Some(1)),
            sts(B1, same(), 2),
        ],
    });
    p.push(
        row(vec![
            ch_none(1),
            Instr::named("pc", Some(ns())),
            Instr::to_end(vec![st(B0, ns())]),
        ]),
        None,
    );
    p.push(
        row(vec![ch_none(1), Instr::to_end(vec![st(B0, ns())])]),
        None,
    );
    let w = resolve_all(&p);
    let r2 = &w.layers[1];
    let mut want = vec![it(0, "ch1=none", "")];
    want.extend((1..=5).map(|k| it(k, "opaque", "unmodelled")));
    want.extend((6..=9).map(|k| it(k, "b0", &format!("1.{}", 10 - k))));
    assert_eq!(items(r2), want, "none of its stitches is a checked b1");
    assert!(r2.made[1..=5]
        .iter()
        .all(|m| m.unverified && m.named == Some(0)));
    assert_eq!(base(r2)[0], ("1.5".to_string(), BaseUse::Unverified));
    assert_eq!(count_texts(r2).0, "(4 sc, 5 not checked)");
    // The next row works into its positions as unverified ones.
    let r3 = &w.layers[2];
    let unverified: Vec<u32> = r3
        .made
        .iter()
        .filter(|m| m.unverified)
        .map(|m| m.id.item)
        .collect();
    assert_eq!(unverified, [5, 6, 7, 8, 9]);
    assert_eq!(
        keys(&validate(&p)),
        vec![("crochet.unsupported_op", Some(2), Some(1))],
        "one unsupported item, at the use site"
    );
}

#[test]
fn an_opaque_named_stitch_keeps_its_chain_runs_as_spaces() {
    let mut p = five_sc();
    p.legend.push(LegendEntry {
        id: LegendId::new("pv"),
        name: "puff V".into(),
        abbreviation: "pV".into(),
        body: vec![
            st(B1, Target::UseSite),
            ch(1),
            Instr::opaque("puff", Some(0), Some(1)),
        ],
    });
    p.push(
        row(vec![
            ch_none(1),
            Instr::named("pv", Some(ns())),
            Instr::to_end(vec![st(B0, ns())]),
        ]),
        None,
    );
    p.push(
        row(vec![
            ch_none(1),
            Instr::to_end(vec![st(B0, Target::NEXT_ANY)]),
        ]),
        None,
    );
    let w = resolve_all(&p);
    let r2 = &w.layers[1];
    assert_eq!(
        items(r2)[1..4],
        [
            it(1, "opaque", "unmodelled"),
            it(2, "ch1", ""),
            it(3, "opaque", "unmodelled")
        ]
    );
    assert!(r2.made[2].unverified);
    assert_eq!(count_texts(r2).0, "(4 sc, 1 ch-1 sp, 2 not checked)");
    let r3 = &w.layers[2];
    let into_space = r3
        .made
        .iter()
        .find(|m| anchors(m) == "sp 2.2")
        .expect("the space is still a space");
    assert!(into_space.unverified);
}

#[test]
fn same_after_an_opaque_target_or_item_is_unverified() {
    // A post stitch, then "dc in same st": the second stitch goes where the first did, which Ply
    // does not model, never silently into the top of 1.5.
    let mut p = five_sc();
    p.push(
        row(vec![
            ch_none(1),
            st(B1, Target::unmodelled("around the post of next st", 1)),
            st(B1, same()),
            Instr::to_end(vec![st(B0, ns())]),
        ]),
        None,
    );
    let w = resolve_all(&p);
    let r2 = &w.layers[1];
    assert_eq!(
        items(r2),
        vec![
            it(0, "ch1=none", ""),
            it(1, "b1", "unmodelled"),
            it(2, "b1", "unmodelled"),
            it(3, "b0", "1.4"),
            it(4, "b0", "1.3"),
            it(5, "b0", "1.2"),
            it(6, "b0", "1.1"),
        ]
    );
    assert!(r2.made[1].unverified && r2.made[2].unverified && !r2.made[3].unverified);
    assert_eq!(
        count_texts(r2).0,
        "(2 dc, 4 sc)",
        "it is still counted as the stitch it is"
    );
    assert_eq!(
        keys(&validate(&p)),
        vec![("crochet.unsupported_target", Some(2), Some(1))]
    );
    // After an opaque instruction too.
    let mut p = five_sc();
    p.push(
        row(vec![
            ch_none(1),
            Instr::opaque("popcorn in next st", Some(1), Some(1)),
            st(B0, same()),
        ]),
        None,
    );
    let w = resolve_all(&p);
    assert_eq!(items(&w.layers[1])[2], it(2, "b0", "unmodelled"));
    assert!(w.layers[1].made[2].unverified);
}

#[test]
fn default_parts_are_stored_as_no_part() {
    assert_eq!(Target::next_stitch_in(Part::Both), Target::NEXT_STITCH);
    assert_eq!(
        Target::next_chain_in(ChainPart::Unspecified),
        Target::NEXT_CHAIN
    );
    let both = Target::Same {
        part: Some(PartSpec::Top(Part::Both)),
    };
    assert_ne!(both, Target::SAME, "the enum can still hold the default");
    assert_eq!(both.normalized(), Target::SAME);
    assert_eq!(
        Target::next_stitch_in(Part::BackLoop).normalized(),
        Target::next_stitch_in(Part::BackLoop)
    );
    // Both forms resolve alike.
    let mut a = five_sc();
    let mut b = five_sc();
    a.push(
        row(vec![
            ch_none(1),
            Instr::to_end(vec![st(B0, Target::next_stitch_in(Part::Both))]),
        ]),
        None,
    );
    b.push(
        row(vec![
            ch_none(1),
            Instr::to_end(vec![st(
                B0,
                Target::Next {
                    kind: PosKind::Stitch,
                    part: Some(PartSpec::Top(Part::Both)),
                },
            )]),
        ]),
        None,
    );
    assert_eq!(resolve_all(&a), resolve_all(&b));
}

#[test]
fn a_new_pattern_is_in_us_terms() {
    assert_eq!(
        CrochetPattern::new(PieceStart::MagicRing).source_terms,
        Terms::Us
    );
}

#[test]
fn items_are_found_by_number() {
    let w = resolve_all(&mesh3());
    for l in &w.layers {
        for m in &l.made {
            assert_eq!(l.item(m.id.item), Some(m));
        }
        assert_eq!(l.item(9_999), None);
    }
    let p = piece(
        PieceStart::FoundationStitches,
        vec![(
            LayerKind::Foundation {
                stitch: B0,
                stitches: 4,
            },
            None,
        )],
    );
    let w = resolve_all(&p);
    assert_eq!(
        w.layers[0].item(0),
        None,
        "a foundation layer has no item 0"
    );
    assert_eq!(w.layers[0].item(4).map(|m| m.id.item), Some(4));
}
