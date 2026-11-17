//! Property-based hardening of the tablet engine (ADR 0018). Over generated bands:
//!
//! * arbitrary bands (illegal starts, junk turn letters, unknown and repeated ids, out-of-range
//!   colours, huge or zero repeats, tight limits): `validate`, `try_simulate` and `state_after` never
//!   panic, and are deterministic;
//! * the card algebra: four quarter turns either way return any arrangement to itself, forward then
//!   backward cancels, a flip is its own inverse, and flipping turns forward into backward;
//! * on valid bands: every pick agrees with a replay through an independent, table-driven reference
//!   model of the card (arrangement, faces by the crossing rule, twining, reversal, twist and woven);
//!   a window is the same rows as the whole band; `state_after` agrees with the rows;
//! * F^k then B^k returns a card to its start with twist 0 and exactly one reversal; F^k, a flip,
//!   then F^k untwists it to 0 (the twist ledger of section 6).
//!
//! Run: `cargo test -p ply-tablet --test tablet_proptest`

use ply_common::Color;
use ply_tablet::{
    state_after, try_simulate, try_simulate_all, validate, validate_with, Arrangement, CardId,
    CardPosition, FaceThread, Hole, HoleThreads, Pack, PickNote, PickSpec, Segment, Tablet,
    TabletBand, TabletLimits, ThreadingDirection, Turn, TurnSequence, Twining,
};
use proptest::prelude::*;
use std::collections::BTreeMap;

/// The reference model of one card, written from ADR 0018 sections 2 to 4 as tables (not from the
/// engine): the hole (0 = A .. 3 = D) at each corner, in the order NT, FT, FB, NB.
type Corners = [usize; 4];
const NT: usize = 0;
const FT: usize = 1;
const FB: usize = 2;
const NB: usize = 3;
/// For each corner, the corner its hole moves to. Forward: NT to FT, FT to FB, FB to NB, NB to NT.
const FORWARD: [usize; 4] = [FT, FB, NB, NT];
/// Backward: NT to NB, FT to NT, FB to FT, NB to FB.
const BACKWARD: [usize; 4] = [NB, NT, FT, FB];
/// A flip: NT and FT swap, FB and NB swap.
const FLIP: [usize; 4] = [FT, NT, NB, FB];
/// Whether the twining is Z, by [threading S, Z][turn forward, backward] (section 6).
const TWINES_Z: [[bool; 2]; 2] = [[true, false], [false, true]];

fn apply(c: Corners, moves: [usize; 4]) -> Corners {
    let mut out = [0; 4];
    for (corner, &to) in moves.iter().enumerate() {
        out[to] = c[corner];
    }
    out
}

fn corners(p: CardPosition) -> Corners {
    p.holes().map(|h| h.index())
}

fn arb_hole() -> impl Strategy<Value = Hole> {
    prop::sample::select(Hole::ALL.to_vec())
}

fn arb_threading() -> impl Strategy<Value = ThreadingDirection> {
    prop_oneof![Just(ThreadingDirection::S), Just(ThreadingDirection::Z)]
}

fn arb_position() -> impl Strategy<Value = CardPosition> {
    prop::sample::select(CardPosition::all().to_vec())
}

const IDS: [&str; 7] = ["c0", "c1", "c2", "c3", "c4", "", "nope"];

fn arb_id() -> impl Strategy<Value = CardId> {
    prop::sample::select(IDS.to_vec()).prop_map(CardId::from)
}

fn arb_color() -> impl Strategy<Value = Option<u32>> {
    prop_oneof![Just(None), (0u32..5).prop_map(Some), Just(Some(u32::MAX))]
}

fn arb_card() -> impl Strategy<Value = Tablet> {
    (
        prop_oneof![4 => (0usize..5).prop_map(|i| format!("c{i}")), 1 => Just(String::new())],
        [arb_color(), arb_color(), arb_color(), arb_color()],
        arb_threading(),
        (arb_hole(), arb_hole(), arb_hole(), arb_hole()),
    )
        .prop_map(|(id, [a, b, c, d], threading, (nt, ft, fb, nb))| Tablet {
            id: CardId(id),
            threads: HoleThreads { a, b, c, d },
            threading,
            start: Arrangement::new(nt, ft, fb, nb),
        })
}

fn arb_spec() -> impl Strategy<Value = PickSpec> {
    (
        "[FBI?X2fé/]{0,7}",
        prop::collection::vec(arb_id(), 0..3),
        prop::collection::vec(arb_id(), 0..3),
        prop::collection::btree_map(
            arb_id(),
            prop::sample::select(vec!["", " ", "half turn"]),
            0..3,
        ),
        prop::option::of((any::<bool>(), "[a-z ]{0,8}")),
        prop::option::of(prop_oneof![Just(0u32), Just(9u32)]),
    )
        .prop_map(|(turns, release, flip, words, note, weft)| PickSpec {
            turns,
            release_twist: release,
            flip,
            unsupported: words.into_iter().map(|(k, v)| (k, v.to_string())).collect(),
            note: note.map(|(brocade, text)| PickNote {
                kind: if brocade {
                    ply_tablet::NoteKind::Brocade
                } else {
                    ply_tablet::NoteKind::Other
                },
                text,
            }),
            weft,
        })
}

fn arb_band() -> impl Strategy<Value = TabletBand> {
    (
        prop::collection::vec(Just(Color::BLACK), 0..4),
        prop::collection::vec(arb_card(), 0..6),
        prop::collection::vec(
            (prop::collection::vec(arb_id(), 0..4), "[a-zA-Z]{0,5}"),
            0..3,
        ),
        prop::collection::vec(
            (
                prop_oneof![
                    Just(0u32),
                    Just(1),
                    Just(2),
                    Just(3),
                    Just(70),
                    Just(u32::MAX)
                ],
                prop::collection::vec(arb_spec(), 0..4),
            ),
            0..4,
        ),
        (0u32..40, 0u32..6),
        prop::option::of(0u32..6),
    )
        .prop_map(|(palette, cards, packs, segments, (twist, float), weft)| {
            let mut b = TabletBand {
                palette,
                weft,
                cards,
                packs: packs
                    .into_iter()
                    .enumerate()
                    .map(|(i, (cards, name))| Pack {
                        id: format!("p{}", i % 2),
                        name,
                        cards,
                    })
                    .collect(),
                turning: TurnSequence::new(
                    segments
                        .into_iter()
                        .map(|(repeat, picks)| Segment::new(repeat, picks))
                        .collect(),
                ),
                ..TabletBand::default()
            };
            b.settings.twist_warning_quarters = twist;
            b.settings.float_warning_picks = float;
            b
        })
}

const TIGHT: TabletLimits = TabletLimits {
    max_cards: 4,
    max_picks: 40,
    max_segments: 3,
    max_packs: 2,
    max_window_cells: 60,
    max_text_bytes: 6,
    max_palette: 3,
    max_diagnostics_per_code: 3,
};

proptest! {
    #![proptest_config(ProptestConfig::with_cases(512))]

    #[test]
    fn arbitrary_bands_never_panic_and_are_deterministic(band in arb_band(), at in 0u32..300) {
        for limits in [TabletLimits::DEFAULT, TIGHT] {
            let d1 = validate_with(&band, &limits);
            let d2 = validate_with(&band, &limits);
            prop_assert_eq!(&d1, &d2);
            for d in &d1 {
                prop_assert_eq!(d.severity, d.code.severity());
                prop_assert!(!d.message.is_empty());
            }
            let w1 = try_simulate_all(&band, &limits);
            let w2 = try_simulate_all(&band, &limits);
            prop_assert_eq!(&w1, &w2);
            let has_errors = d1.iter().any(|d| d.severity == ply_tablet::Severity::Error);
            if has_errors {
                prop_assert!(w1.is_err());
            }
            if let Ok(w) = &w1 {
                prop_assert_eq!(w.cells.len(), w.cards * w.picks() as usize);
                prop_assert_eq!(w.rows.len(), w.picks() as usize);
            }
            let _ = state_after(&band, at, &limits);
            let _ = try_simulate(&band, at..=at.saturating_add(3), &limits);
            let _ = try_simulate(&band, at..=0, &limits);
        }
    }

    #[test]
    fn four_quarter_turns_return_every_arrangement(p in arb_position()) {
        let f4 = p.forward().forward().forward().forward();
        let b4 = p.backward().backward().backward().backward();
        prop_assert_eq!(f4, p);
        prop_assert_eq!(b4, p);
        prop_assert_eq!(p.forward().backward(), p);
        prop_assert_eq!(p.backward().forward(), p);
        prop_assert_eq!(p.flipped().flipped(), p);
        // Flipping mirrors the card, so forward after a flip is backward before it.
        prop_assert_eq!(p.flipped().forward(), p.backward().flipped());
        // The engine's turns and flip agree with the reference tables.
        prop_assert_eq!(corners(p.forward()), apply(corners(p), FORWARD));
        prop_assert_eq!(corners(p.backward()), apply(corners(p), BACKWARD));
        prop_assert_eq!(corners(p.flipped()), apply(corners(p), FLIP));
        for (t, s_row) in [(ThreadingDirection::S, 0), (ThreadingDirection::Z, 1)] {
            prop_assert_eq!(Twining::of(t, true) == Twining::Z, TWINES_Z[s_row][0]);
            prop_assert_eq!(Twining::of(t, false) == Twining::Z, TWINES_Z[s_row][1]);
        }
        // Turning and flipping keep the arrangement legal.
        for q in [p.forward(), p.backward(), p.flipped()] {
            prop_assert!(CardPosition::try_from_arrangement(q.arrangement()).is_ok());
        }
    }
}

/// A band that is usually valid but exercises everything the simulation reports: empty holes,
/// `?` turns (usually with words), idles, flips, releases, notes and tight thresholds.
fn arb_mostly_valid_band() -> impl Strategy<Value = TabletBand> {
    (0usize..5).prop_flat_map(|n| {
        (
            prop::collection::vec(
                (
                    arb_threading(),
                    prop_oneof![9 => arb_position().prop_map(|p| p.arrangement()), 1 => (arb_hole(), arb_hole(), arb_hole(), arb_hole()).prop_map(|(a, b, c, d)| Arrangement::new(a, b, c, d))],
                    [arb_color(), arb_color(), arb_color(), arb_color()],
                ),
                n,
            ),
            prop::collection::vec(
                (
                    prop_oneof![9 => prop::collection::vec(prop::sample::select(vec!['F', 'B', 'I', '?']), n).prop_map(|v| v.into_iter().collect::<String>()), 1 => "[FBI?X]{0,6}"],
                    any::<bool>(),
                    prop::collection::vec(prop::bool::weighted(0.15), n),
                    prop::collection::vec(prop::bool::weighted(0.1), n),
                    prop::option::of(any::<bool>()),
                ),
                0..12,
            ),
            prop_oneof![Just(1u32), Just(2), Just(9)],
            (0u32..6, 0u32..5),
        )
            .prop_map(move |(cards, picks, repeat, (twist, float))| {
                let id = |i: usize| CardId(format!("c{i}"));
                let mut band = TabletBand {
                    palette: vec![Color::BLACK, Color::WHITE, Color { r: 9, g: 9, b: 9 }],
                    cards: cards
                        .into_iter()
                        .enumerate()
                        .map(|(i, (threading, start, [a, b, c, d]))| Tablet {
                            id: id(i),
                            threads: HoleThreads { a, b, c, d },
                            threading,
                            start,
                        })
                        .collect(),
                    turning: TurnSequence::new(vec![Segment::new(
                        repeat,
                        picks
                            .into_iter()
                            .map(|(turns, words, flip, release, note)| {
                                let unsupported = turns
                                    .chars()
                                    .enumerate()
                                    .filter(|&(i, ch)| ch == '?' && i < n && words)
                                    .map(|(i, _)| (id(i), "half turn".to_string()))
                                    .collect();
                                PickSpec {
                                    turns,
                                    release_twist: (0..n).filter(|&i| release[i]).map(id).collect(),
                                    flip: (0..n).filter(|&i| flip[i]).map(id).collect(),
                                    unsupported,
                                    note: note.map(|b| PickNote {
                                        kind: if b { ply_tablet::NoteKind::Brocade } else { ply_tablet::NoteKind::Other },
                                        text: "beads".into(),
                                    }),
                                    weft: None,
                                }
                            })
                            .collect(),
                    )]),
                    ..TabletBand::default()
                };
                band.settings.twist_warning_quarters = twist;
                band.settings.float_warning_picks = float;
                band
            })
    })
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(512))]

    #[test]
    fn mostly_valid_bands_simulate_whenever_they_validate(band in arb_mostly_valid_band()) {
        for limits in [TabletLimits::DEFAULT, TIGHT] {
            let diags = validate_with(&band, &limits);
            prop_assert_eq!(&diags, &validate_with(&band, &limits));
            let errors = diags.iter().any(|d| d.severity == ply_tablet::Severity::Error);
            let sim = try_simulate_all(&band, &limits);
            match &sim {
                Ok(w) => {
                    prop_assert!(!errors);
                    // Every diagnostic points inside the band.
                    for d in &diags {
                        match &d.location {
                            ply_tablet::TabletLocation::Pick { pick, cards, .. } => {
                                prop_assert!(*pick >= 1 && *pick <= w.last_pick);
                                prop_assert!(cards.cards.iter().all(|&c| c >= 1 && c as usize <= w.cards));
                            }
                            ply_tablet::TabletLocation::Run { card, first_pick, last_pick, .. } => {
                                prop_assert!(*card >= 1 && *card as usize <= w.cards);
                                prop_assert!(1 <= *first_pick && first_pick <= last_pick && *last_pick <= w.last_pick);
                            }
                            _ => {}
                        }
                    }
                    // Once a card is unknown it stays unknown: arrangement, threading, faces, twining
                    // and woven. Only a release makes `twist` known, until the next turn.
                    for c in 0..w.cards {
                        let mut unknown = false;
                        for p in 1..=w.last_pick {
                            let cp = w.card_pick(p, c).unwrap();
                            if cp.turn == Turn::Unsupported { unknown = true; }
                            prop_assert_eq!(cp.position.is_none(), unknown);
                            prop_assert_eq!(cp.threading.is_none(), unknown);
                            if unknown {
                                prop_assert_eq!(cp.top, FaceThread::Unknown);
                                prop_assert_eq!(cp.twining, None);
                                prop_assert!(!cp.reversal);
                                prop_assert_eq!(cp.twist.woven, None);
                                if cp.twist.twist.is_some() {
                                    prop_assert_eq!(cp.twist.twist, Some(0));
                                }
                            }
                        }
                    }
                }
                Err(ply_tablet::TabletError::Invalid(e)) => {
                    prop_assert!(errors);
                    // Errors, and the count of any error code past the cap.
                    let error_or_its_count = |d: &ply_tablet::Diagnostic| match d.location {
                        ply_tablet::TabletLocation::Omitted { code, .. } => {
                            code.severity() == ply_tablet::Severity::Error
                        }
                        _ => d.severity == ply_tablet::Severity::Error,
                    };
                    prop_assert!(e.iter().all(error_or_its_count));
                }
                Err(_) => {} // a window past a tight limit
            }
        }
    }
}

/// A valid band: legal starts, every hole threaded, letters F, B and I only, flips and releases of
/// known cards.
fn arb_valid_band() -> impl Strategy<Value = TabletBand> {
    (1usize..5).prop_flat_map(|n| {
        (
            prop::collection::vec(
                (
                    arb_threading(),
                    arb_position(),
                    [0u32..3, 0u32..3, 0u32..3, 0u32..3],
                ),
                n,
            ),
            prop::collection::vec(
                (
                    prop::collection::vec(prop::sample::select(vec!['F', 'B', 'I']), n),
                    prop::collection::vec(any::<bool>(), n),
                    prop::collection::vec(prop::bool::weighted(0.1), n),
                ),
                1..30,
            ),
            1u32..3,
        )
            .prop_map(move |(cards, picks, repeat)| TabletBand {
                palette: vec![Color::BLACK, Color::WHITE, Color { r: 9, g: 9, b: 9 }],
                cards: cards
                    .into_iter()
                    .enumerate()
                    .map(|(i, (t, p, [a, b, c, d]))| {
                        Tablet::new(format!("c{i}"), HoleThreads::new(a, b, c, d), t, p)
                    })
                    .collect(),
                turning: TurnSequence::new(vec![Segment::new(
                    repeat,
                    picks
                        .into_iter()
                        .map(|(letters, release, flip)| PickSpec {
                            turns: letters.into_iter().collect(),
                            release_twist: (0..n)
                                .filter(|&i| release[i] && i % 2 == 0)
                                .map(|i| CardId(format!("c{i}")))
                                .collect(),
                            flip: (0..n)
                                .filter(|&i| flip[i])
                                .map(|i| CardId(format!("c{i}")))
                                .collect(),
                            unsupported: BTreeMap::new(),
                            note: None,
                            weft: None,
                        })
                        .collect(),
                )]),
                ..TabletBand::default()
            })
    })
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(256))]

    #[test]
    fn valid_bands_follow_the_rules_pick_by_pick(band in arb_valid_band()) {
        let limits = TabletLimits::DEFAULT;
        prop_assert!(validate(&band).iter().all(|d| d.severity != ply_tablet::Severity::Error));
        let w = try_simulate_all(&band, &limits).unwrap();
        // Replay every card through the reference model (tables, not the engine's card algebra).
        let letter = |h: usize| ["A", "B", "C", "D"][h];
        let hole = |h: usize| Hole::ALL[h];
        for (c, card) in band.cards.iter().enumerate() {
            let a = card.start;
            let mut pos: Corners = [a.near_top, a.far_top, a.far_bottom, a.near_bottom].map(|h| h.index());
            let mut s_threaded = card.threading == ThreadingDirection::S;
            let (mut twist, mut woven) = (0i32, 0i32);
            let mut last_z: Option<bool> = None;
            let mut last_cross: Option<(usize, usize)> = None;
            let mut pick = 0u32;
            for seg in &band.turning.segments {
                for _ in 0..seg.repeat {
                    for spec in &seg.picks {
                        pick += 1;
                        let id = &card.id;
                        if spec.release_twist.contains(id) { twist = 0; }
                        if spec.flip.contains(id) {
                            pos = apply(pos, FLIP);
                            s_threaded = !s_threaded;
                            last_cross = None;
                        }
                        let turn = spec.turn(c).unwrap();
                        let cp = w.card_pick(pick, c).unwrap();
                        prop_assert_eq!(cp.turn, turn);
                        match turn {
                            Turn::Forward | Turn::Backward => {
                                let fwd = turn == Turn::Forward;
                                let z = TWINES_Z[usize::from(!s_threaded)][usize::from(!fwd)];
                                prop_assert_eq!(cp.reversal, last_z.is_some_and(|l| l != z));
                                last_z = Some(z);
                                let q = if z { 1 } else { -1 };
                                twist += q;
                                woven += q;
                                // The crossing rule, from the corners before the turn.
                                let (over, under) = if fwd { (pos[NT], pos[FB]) } else { (pos[FT], pos[NB]) };
                                prop_assert_eq!(cp.top, FaceThread::Thread(hole(over)));
                                prop_assert_eq!(cp.back, FaceThread::Thread(hole(under)));
                                last_cross = Some((over, under));
                                pos = apply(pos, if fwd { FORWARD } else { BACKWARD });
                                prop_assert_eq!(cp.twining, Some(if z { Twining::Z } else { Twining::S }));
                            }
                            Turn::Idle => {
                                prop_assert!(!cp.reversal);
                                prop_assert_eq!(cp.twining, None);
                                match last_cross {
                                    Some((o, u)) => {
                                        prop_assert_eq!(cp.top, FaceThread::Continued(hole(o)));
                                        prop_assert_eq!(cp.back, FaceThread::Continued(hole(u)));
                                    }
                                    None => {
                                        prop_assert_eq!(cp.top, FaceThread::Ambiguous(hole(pos[NT]), hole(pos[FT])));
                                        prop_assert_eq!(cp.back, FaceThread::Ambiguous(hole(pos[FB]), hole(pos[NB])));
                                    }
                                }
                            }
                            Turn::Unsupported => unreachable!(),
                        }
                        let chart = pos.map(letter).join(" ");
                        prop_assert_eq!(cp.position.map(|p| p.chart()), Some(chart));
                        let t = if s_threaded { ThreadingDirection::S } else { ThreadingDirection::Z };
                        prop_assert_eq!(cp.threading, Some(t));
                        prop_assert_eq!(cp.twist.twist, Some(twist));
                        prop_assert_eq!(cp.twist.woven, Some(woven));
                        prop_assert!(twist.unsigned_abs() <= pick && woven.unsigned_abs() <= pick);
                    }
                }
            }
        }
        // Any window is the same rows; the state after its last pick agrees.
        let total = w.picks();
        let first = 1 + total / 3;
        let last = total - total / 4;
        let part = try_simulate(&band, first..=last, &limits).unwrap();
        for p in first..=last {
            prop_assert_eq!(part.row(p), w.row(p));
            prop_assert_eq!(part.info(p), w.info(p));
        }
        let s = state_after(&band, last, &limits).unwrap();
        for (c, st) in s.cards.iter().enumerate() {
            let cp = w.card_pick(last, c).unwrap();
            prop_assert_eq!((st.position, st.threading, st.twist), (cp.position, cp.threading, cp.twist));
        }
    }

    #[test]
    fn forward_then_backward_cancels_position_and_twist(
        start in arb_position(),
        threading in arb_threading(),
        k in 1usize..12,
    ) {
        let mut picks: Vec<PickSpec> = vec![PickSpec::new("F"); k];
        picks.extend(vec![PickSpec::new("B"); k]);
        let band = TabletBand {
            palette: vec![Color::BLACK],
            cards: vec![Tablet::new("c", HoleThreads::all(0), threading, start)],
            turning: TurnSequence::new(vec![Segment::new(1, picks)]),
            ..TabletBand::default()
        };
        let w = try_simulate_all(&band, &TabletLimits::DEFAULT).unwrap();
        let sign = if threading == ThreadingDirection::S { 1 } else { -1 };
        let peak = w.card_pick(k as u32, 0).unwrap();
        prop_assert_eq!(peak.twist.twist, Some(sign * k as i32));
        let end = w.card_pick(2 * k as u32, 0).unwrap();
        prop_assert_eq!(end.position, Some(start));
        prop_assert_eq!(end.twist.twist, Some(0));
        prop_assert_eq!(end.twist.woven, Some(0));
        // Exactly one reversal, on the first backward pick, which shows the same thread again.
        let reversals: Vec<u32> = (1..=2 * k as u32).filter(|&p| w.card_pick(p, 0).unwrap().reversal).collect();
        prop_assert_eq!(reversals, vec![k as u32 + 1]);
        prop_assert_eq!(w.card_pick(k as u32 + 1, 0).unwrap().top, peak.top);
    }

    #[test]
    fn a_flip_then_the_same_turns_untwists(
        start in arb_position(),
        threading in arb_threading(),
        k in 1usize..12,
        backward in any::<bool>(),
    ) {
        let letter = if backward { "B" } else { "F" };
        let mut picks: Vec<PickSpec> = vec![PickSpec::new(letter); 2 * k];
        picks[k] = PickSpec::new(letter).with_flip(&["c"]);
        let band = TabletBand {
            palette: vec![Color::BLACK],
            cards: vec![Tablet::new("c", HoleThreads::all(0), threading, start)],
            turning: TurnSequence::new(vec![Segment::new(1, picks)]),
            ..TabletBand::default()
        };
        let w = try_simulate_all(&band, &TabletLimits::DEFAULT).unwrap();
        let before = w.card_pick(k as u32, 0).unwrap().twist.twist.unwrap();
        prop_assert_eq!(before.unsigned_abs() as usize, k);
        let flipped = w.card_pick(k as u32 + 1, 0).unwrap();
        prop_assert!(flipped.flipped && flipped.reversal);
        prop_assert_eq!(flipped.threading, Some(threading.flipped()));
        let end = w.card_pick(2 * k as u32, 0).unwrap();
        prop_assert_eq!(end.twist.twist, Some(0));
        prop_assert_eq!(end.twist.woven, Some(0));
    }
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(96))]

    /// Checkpoints (M10-02): a window resumed from the nearest checkpoint before it, directly or
    /// after a trip through bytes, is exactly the window folded from pick 1, and so is the state
    /// after any pick. A band with structural errors gets no checkpoints, as it gets no simulation.
    #[test]
    fn windows_resumed_from_checkpoints_equal_the_whole_fold(
        band in arb_mostly_valid_band(),
        every in 1u32..9,
        at in 0u32..400,
        len in 0u32..30,
    ) {
        use ply_tablet::{checkpoints, nearest_before, state_after_from, try_simulate_from, Checkpoint};
        let limits = TabletLimits::DEFAULT;
        let cps = match checkpoints(&band, every, &limits) {
            Ok(cps) => cps,
            Err(_) => {
                prop_assert!(try_simulate_all(&band, &limits).is_err());
                return Ok(());
            }
        };
        let total = try_simulate_all(&band, &limits).unwrap().last_pick;
        if total == 0 {
            prop_assert!(cps.is_empty());
            return Ok(());
        }
        prop_assert_eq!(cps.len() as u32, (total - 1) / every);
        let first = 1 + at % total;
        let last = (first + len).min(total);
        let want = try_simulate(&band, first..=last, &limits).unwrap();
        let from = nearest_before(&cps, &band, first);
        prop_assert_eq!(&try_simulate_from(&band, from, first..=last, &limits).unwrap(), &want);
        if let Some(cp) = from {
            prop_assert!(cp.pick() < first);
            let back = Checkpoint::decode(&cp.encode(), &band).unwrap();
            prop_assert_eq!(&back, cp);
            prop_assert_eq!(&try_simulate_from(&band, Some(&back), first..=last, &limits).unwrap(), &want);
            prop_assert_eq!(back.state(), state_after(&band, cp.pick(), &limits).unwrap());
        }
        prop_assert_eq!(
            state_after_from(&band, from, last, &limits).unwrap(),
            state_after(&band, last, &limits).unwrap()
        );
    }
}

/// A long band paged through its checkpoints: 100 cards by 20,000 picks, every card turning, with
/// flips and releases in a repeated block. Windows anywhere in it, resumed from the nearest
/// checkpoint, equal the same rows folded from pick 1.
#[test]
fn a_long_band_pages_through_its_checkpoints() {
    use ply_tablet::{checkpoint_interval, checkpoints, nearest_before, try_simulate_from};
    let cards = 100;
    let band = TabletBand {
        palette: vec![Color::BLACK, Color::WHITE],
        cards: (0..cards)
            .map(|i| Tablet {
                id: CardId::new(format!("c{i}")),
                threads: HoleThreads::new(0, 1, 0, 1),
                threading: if i % 3 == 0 {
                    ThreadingDirection::Z
                } else {
                    ThreadingDirection::S
                },
                start: CardPosition::all()[i % 8].arrangement(),
            })
            .collect(),
        turning: TurnSequence::new(vec![
            Segment::new(
                2_000,
                vec![
                    PickSpec::all(Turn::Forward, cards),
                    PickSpec::all(Turn::Forward, cards),
                    PickSpec::new("FBI".repeat(34)[..cards].to_string()).with_flip(&["c5", "c50"]),
                    PickSpec::all(Turn::Backward, cards).with_release(&["c7"]),
                ],
            ),
            Segment::new(
                2_000,
                vec![
                    PickSpec::all(Turn::Idle, cards),
                    PickSpec::all(Turn::Forward, cards),
                ],
            ),
            Segment::new(8_000, vec![PickSpec::all(Turn::Backward, cards)]),
        ]),
        ..TabletBand::default()
    };
    let limits = TabletLimits::DEFAULT;
    let total = 20_000;
    let every = checkpoint_interval(cards, total);
    let cps = checkpoints(&band, 0, &limits).unwrap();
    assert_eq!(cps.len() as u32, (total - 1) / every);
    for first in [
        1, 255, 256, 257, 7_999, 8_000, 8_001, 11_999, 12_000, 19_950, 20_000,
    ] {
        let last = (first + 49).min(total);
        let want = try_simulate(&band, first..=last, &limits).unwrap();
        let from = nearest_before(&cps, &band, first);
        assert_eq!(
            from.map(|c| c.pick()),
            (first > every).then(|| (first - 1) / every * every)
        );
        assert_eq!(
            try_simulate_from(&band, from, first..=last, &limits).unwrap(),
            want,
            "{first}"
        );
    }
}
