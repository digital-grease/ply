//! The roadmap's engine cases for M10 (four forward turns, four backward turns, mixed card groups,
//! twist reversal, nonstandard starting positions, invalid rotations, large sequence bounds), and
//! the parts of ADR 0018 sections 5 to 7 and 10 the oracle bands do not reach: actions Ply does not
//! model, empty holes, an idle after a flip, all-idle picks, twist warnings, notes and capped lists.
//! Every expected value below is worked out by hand from the rules, in the comments beside it.
//!
//! Run: `cargo test -p ply-tablet --test engine_cases` (the full-size stress test:
//! `cargo test -p ply-tablet --release --test engine_cases -- --ignored`)

use ply_common::Color;
use ply_tablet::{
    state_after, try_simulate, try_simulate_all, validate, validate_with, Arrangement, CardPick,
    CardPosition, CardSet, Face, FaceThread, Hole, HoleThreads, NoteKind, Pack, PickNote, PickSpec,
    RunEnd, Segment, Severity, Tablet, TabletBand, TabletCode, TabletLimits, TabletLocation,
    ThreadingDirection, Turn, TurnSequence, Twining,
};
use Hole::*;
use ThreadingDirection::{S, Z};

const LIMITS: TabletLimits = TabletLimits::DEFAULT;

/// A band whose cards hold one colour per hole (A 0, B 1, C 2, D 3), so a face names its hole.
fn band(cards: &[(ThreadingDirection, CardPosition)], picks: &[&str]) -> TabletBand {
    TabletBand {
        palette: vec![
            Color::BLACK,
            Color::WHITE,
            Color { r: 200, g: 0, b: 0 },
            Color { r: 0, g: 0, b: 200 },
        ],
        cards: cards
            .iter()
            .enumerate()
            .map(|(i, &(t, p))| {
                Tablet::new(
                    format!("card-{}", i + 1),
                    HoleThreads::new(0, 1, 2, 3),
                    t,
                    p,
                )
            })
            .collect(),
        turning: TurnSequence::new(vec![Segment::new(
            1,
            picks.iter().map(|&p| PickSpec::new(p)).collect(),
        )]),
        ..TabletBand::default()
    }
}

fn rows(b: &TabletBand) -> Vec<Vec<CardPick>> {
    let w = try_simulate_all(b, &LIMITS).unwrap();
    (w.first_pick..=w.last_pick)
        .map(|p| w.row(p).unwrap().to_vec())
        .collect()
}

fn tops(rows: &[Vec<CardPick>], card: usize) -> Vec<FaceThread> {
    rows.iter().map(|r| r[card].top).collect()
}

fn codes(b: &TabletBand) -> Vec<TabletCode> {
    validate(b).iter().map(|d| d.code).collect()
}

#[test]
fn four_forward_turns_from_every_start() {
    for start in CardPosition::all() {
        for t in [S, Z] {
            let b = band(&[(t, start)], &["F", "F", "F", "F"]);
            let r = rows(&b);
            // Forward: the hole at NT crosses the top, so the top face reads the holes that come to
            // NT in turn: NT, then NB, then FB, then FT of the start.
            let want = [
                start.hole_at(ply_tablet::Position::NearTop),
                start.hole_at(ply_tablet::Position::NearBottom),
                start.hole_at(ply_tablet::Position::FarBottom),
                start.hole_at(ply_tablet::Position::FarTop),
            ];
            assert_eq!(
                tops(&r, 0),
                want.map(FaceThread::Thread),
                "{}",
                start.chart()
            );
            // The back reads the hole that comes to FB: FB, FT, NT, NB of the start.
            let back: Vec<FaceThread> = r.iter().map(|x| x[0].back).collect();
            assert_eq!(
                back,
                [
                    start.hole_at(ply_tablet::Position::FarBottom),
                    start.hole_at(ply_tablet::Position::FarTop),
                    start.hole_at(ply_tablet::Position::NearTop),
                    start.hole_at(ply_tablet::Position::NearBottom),
                ]
                .map(FaceThread::Thread)
            );
            // Back where it started; a full turn of twining, Z on an S card and S on a Z card.
            assert_eq!(r[3][0].position, Some(start));
            let sign = if t == S { 1 } else { -1 };
            for (i, x) in r.iter().enumerate() {
                assert_eq!(x[0].twist.twist, Some(sign * (i as i32 + 1)));
                assert_eq!(
                    x[0].twining,
                    Some(if t == S { Twining::Z } else { Twining::S })
                );
                assert!(!x[0].reversal);
            }
        }
    }
}

#[test]
fn four_backward_turns_from_every_start() {
    for start in CardPosition::all() {
        for t in [S, Z] {
            let b = band(&[(t, start)], &["B", "B", "B", "B"]);
            let r = rows(&b);
            // Backward: the hole at FT crosses the top: FT, FB, NB, NT of the start in turn.
            assert_eq!(
                tops(&r, 0),
                [
                    start.hole_at(ply_tablet::Position::FarTop),
                    start.hole_at(ply_tablet::Position::FarBottom),
                    start.hole_at(ply_tablet::Position::NearBottom),
                    start.hole_at(ply_tablet::Position::NearTop),
                ]
                .map(FaceThread::Thread)
            );
            assert_eq!(r[3][0].position, Some(start));
            let sign = if t == S { -1 } else { 1 };
            assert_eq!(r[3][0].twist.twist, Some(4 * sign));
        }
    }
}

#[test]
fn twist_reversal_undoes_turn_by_turn_and_never_resets() {
    // S card at home: F F F (Z, +1 each: 1, 2, 3), then B B B (S: 2, 1, 0).
    let b = band(
        &[(S, CardPosition::ply_home())],
        &["F", "F", "F", "B", "B", "B"],
    );
    let r = rows(&b);
    let twist: Vec<i32> = r.iter().map(|x| x[0].twist.twist.unwrap()).collect();
    assert_eq!(twist, [1, 2, 3, 2, 1, 0]);
    let woven: Vec<i32> = r.iter().map(|x| x[0].twist.woven.unwrap()).collect();
    assert_eq!(woven, twist);
    // The reversal is at pick 4 only; the thread that crossed the top on pick 3 (C: home A D C B,
    // forward three times shows A, B, C) crosses it again on pick 4 (the doubled colour).
    let rev: Vec<bool> = r.iter().map(|x| x[0].reversal).collect();
    assert_eq!(rev, [false, false, false, true, false, false]);
    assert_eq!(tops(&r, 0), [A, B, C, C, B, A].map(FaceThread::Thread));
    // C reaches NT on pick 2, crosses the top on pick 3 (to FT) and back on pick 4 (to NT): three
    // picks in the upper layer, where continuous turning gives two.
    assert_eq!(r[3][0].top_run, Some(3));
    assert_eq!(r[5][0].position, Some(CardPosition::ply_home()));
    let diags = validate(&b);
    assert_eq!(diags.len(), 1);
    assert_eq!(diags[0].code, TabletCode::Reversal);
    assert_eq!(diags[0].message, "Reversal at pick 4, card 1.");
}

#[test]
fn mixed_card_groups_turn_independently() {
    // R9-style grouped turns: cards 1 and 2 forward, 3 and 4 backward, then the other way, with a
    // selvedge card 5 turned forward throughout. Every card at home, all S.
    let home = CardPosition::ply_home();
    let b = band(
        &[(S, home), (S, home), (S, home), (S, home), (S, home)],
        &["FFBBF", "FFBBF", "BBFFF", "BBFFF"],
    );
    let r = rows(&b);
    // Cards 1 and 2: F F B B: twist 1, 2, 1, 0; top A, B, B, A; reversal at pick 3.
    // Cards 3 and 4: B B F F: twist -1, -2, -1, 0; top D, C, C, D; reversal at pick 3.
    // Card 5: F F F F: twist 1..4; top A, B, C, D; no reversal.
    for c in 0..5 {
        let twist: Vec<i32> = r.iter().map(|x| x[c].twist.twist.unwrap()).collect();
        let (want_twist, want_top, rev3) = match c {
            0 | 1 => ([1, 2, 1, 0], [A, B, B, A], true),
            2 | 3 => ([-1, -2, -1, 0], [D, C, C, D], true),
            _ => ([1, 2, 3, 4], [A, B, C, D], false),
        };
        assert_eq!(twist, want_twist, "card {}", c + 1);
        assert_eq!(
            tops(&r, c),
            want_top.map(FaceThread::Thread),
            "card {}",
            c + 1
        );
        assert_eq!(r[2][c].reversal, rev3, "card {}", c + 1);
    }
    // One aggregated reversal note: "Reversal at pick 3, cards 1 to 4".
    let diags = validate(&b);
    assert_eq!(diags.len(), 1);
    assert_eq!(
        diags[0].location,
        TabletLocation::Pick {
            pick: 3,
            cards: CardSet::from_sorted(&[1, 2, 3, 4]),
            face: None
        }
    );
    assert_eq!(diags[0].message, "Reversal at pick 3, cards 1 to 4.");
    // Packs add nothing: the same band with packs simulates identically.
    let mut packed = b.clone();
    packed.packs = vec![
        Pack {
            id: "p1".into(),
            name: "Left".into(),
            cards: vec!["card-1".into(), "card-2".into()],
        },
        Pack {
            id: "p2".into(),
            name: "Right".into(),
            cards: vec!["card-3".into(), "card-4".into()],
        },
    ];
    assert_eq!(rows(&packed), r);
}

#[test]
fn nonstandard_starts_and_cards_out_of_step() {
    // R3's 1122 phases: cards 1 and 2 at home, 3 and 4 one quarter turn forward of home. Forward
    // turns then show cards 3 and 4 a pick ahead: home shows A, B, C, D; one quarter on (B A D C)
    // shows B, C, D, A.
    let home = CardPosition::ply_home();
    let on = home.forward();
    let b = band(
        &[(S, home), (S, home), (S, on), (S, on)],
        &["FFFF", "FFFF", "FFFF", "FFFF"],
    );
    let r = rows(&b);
    assert_eq!(tops(&r, 0), [A, B, C, D].map(FaceThread::Thread));
    assert_eq!(tops(&r, 3), [B, C, D, A].map(FaceThread::Thread));
    // The printed-face-right preset (D at NT) brings D, C, B, A across the top.
    let b = band(
        &[(S, CardPosition::PRINTED_FACE_RIGHT)],
        &["F", "F", "F", "F"],
    );
    assert_eq!(tops(&rows(&b), 0), [D, C, B, A].map(FaceThread::Thread));
    // Any legal arrangement may start a band; an arrangement read from a file is kept as given.
    let start = Arrangement::new(C, D, A, B);
    let mut b = band(&[(Z, home)], &["B"]);
    b.cards[0].start = start;
    let r = rows(&b);
    // Backward from C D A B: D (at FT) crosses the top, B (at NB) the bottom; Z backward twines Z.
    assert_eq!(r[0][0].top, FaceThread::Thread(D));
    assert_eq!(r[0][0].back, FaceThread::Thread(B));
    assert_eq!(r[0][0].twining, Some(Twining::Z));
    assert_eq!(r[0][0].position.unwrap().chart(), "D A B C");
}

#[test]
fn invalid_rotations_are_refused_with_the_card_named() {
    // Every one of the 16 orders with two diagonal holes on an edge, and a repeated letter.
    let mut refused = 0;
    for a in Hole::ALL {
        for b in Hole::ALL {
            for c in Hole::ALL {
                for d in Hole::ALL {
                    let arr = Arrangement::new(a, b, c, d);
                    if CardPosition::try_from_arrangement(arr).is_ok() {
                        continue;
                    }
                    let mut band = band(
                        &[(S, CardPosition::ply_home()), (S, CardPosition::ply_home())],
                        &["FF"],
                    );
                    band.cards[1].start = arr;
                    let diags = validate(&band);
                    assert_eq!(diags.len(), 1, "{arr:?}");
                    assert_eq!(diags[0].code, TabletCode::StartIllegal);
                    assert_eq!(diags[0].location, TabletLocation::Card { card: 2 });
                    refused += 1;
                }
            }
        }
    }
    assert_eq!(refused, 256 - 8);
    // An illegal arrangement cannot even be read as a card position.
    assert!(serde_json::from_str::<CardPosition>(
        r#"{"near_top":"A","far_top":"C","far_bottom":"B","near_bottom":"D"}"#
    )
    .is_err());
    // Turns other than F, B, I and ? are refused (lower case and slashes included).
    for bad in ["f", "/", "\\", "2", "H", "é"] {
        let b = band(&[(S, CardPosition::ply_home())], &[bad]);
        assert_eq!(codes(&b), [TabletCode::TurnLetter], "{bad:?}");
    }
}

#[test]
fn a_flip_then_the_same_turns_untwists() {
    // S card at home: F F (twist 2), flip (now Z), F F: S twining, twist 1 then 0. The flip itself
    // leaves twist and woven alone and shows as a reversal on the next turn.
    let mut b = band(&[(S, CardPosition::ply_home())], &["F", "F", "F", "F"]);
    b.turning.segments[0].picks[2] = PickSpec::new("F").with_flip(&["card-1"]);
    let r = rows(&b);
    let twist: Vec<i32> = r.iter().map(|x| x[0].twist.twist.unwrap()).collect();
    assert_eq!(twist, [1, 2, 1, 0]);
    assert!(r[2][0].flipped && r[2][0].reversal);
    assert_eq!(r[2][0].threading, Some(Z));
    // After pick 2 the card is C B A D; the flip makes it B C D A; forward shows B again (the
    // thread that crossed the top on pick 2): the doubling comes from the flip. Pick 3 leaves
    // A B C D, so pick 4 shows A.
    assert_eq!(tops(&r, 0), [A, B, B, A].map(FaceThread::Thread));
    let codes: Vec<TabletCode> = validate(&b).iter().map(|d| d.code).collect();
    assert_eq!(codes, [TabletCode::Reversal, TabletCode::Flip]);
}

#[test]
fn an_idle_right_after_a_flip_is_ambiguous() {
    let mut b = band(&[(S, CardPosition::ply_home())], &["F", "I", "I"]);
    b.turning.segments[0].picks[2] = PickSpec::new("I").with_flip(&["card-1"]);
    let r = rows(&b);
    // Pick 2 idles after a turn: A carries on. Pick 3 idles right after a flip of B A D C, which
    // gives A B C D: either A (NT) or B (FT) may show; back C (FB) or D (NB).
    assert_eq!(r[1][0].top, FaceThread::Continued(A));
    assert_eq!(r[1][0].back, FaceThread::Continued(C));
    assert_eq!(r[2][0].top, FaceThread::Ambiguous(A, B));
    assert_eq!(r[2][0].back, FaceThread::Ambiguous(C, D));
    let diags = validate(&b);
    let amb: Vec<&ply_tablet::Diagnostic> = diags
        .iter()
        .filter(|d| d.code == TabletCode::FaceAmbiguous)
        .collect();
    assert_eq!(amb.len(), 1);
    assert!(matches!(
        amb[0].location,
        TabletLocation::Pick { pick: 3, .. }
    ));
}

#[test]
fn an_unsupported_action_makes_the_card_unknown_until_recorded_otherwise() {
    // Card 1: F, then a half turn (?), F, a release before an idle, then a flip before F. ADR 0018
    // sections 4 and 10: the card's state is unknown from the `?`, its threading included (the
    // words could hide a flip), so the twining of every later turn is unknown too.
    let mut b = band(
        &[(S, CardPosition::ply_home()), (S, CardPosition::ply_home())],
        &["FF", "?F", "FF", "IF", "FF"],
    );
    b.turning.segments[0].picks[1]
        .unsupported
        .insert("card-1".into(), "half turn forward".into());
    b.turning.segments[0].picks[3].release_twist = vec!["card-1".into()];
    b.turning.segments[0].picks[4].flip = vec!["card-1".into()];
    let r = rows(&b);
    let c: Vec<&CardPick> = r.iter().map(|x| &x[0]).collect();
    assert_eq!(c[0].threading, Some(S));
    assert_eq!(c[1].turn, Turn::Unsupported);
    for p in &c[1..] {
        assert_eq!(p.position, None);
        assert_eq!(p.threading, None);
        assert_eq!(p.top, FaceThread::Unknown);
        assert_eq!(p.back, FaceThread::Unknown);
        assert_eq!(p.twining, None);
        assert!(!p.reversal);
        assert_eq!(p.twist.woven, None);
    }
    assert_eq!(c[2].twist.twist, None);
    // A recorded release makes `twist` known (0), and an idle keeps it; the next turn, of unknown
    // twining, makes it unknown again. A flip does not make the threading known.
    assert_eq!(c[3].twist.twist, Some(0));
    assert!(c[4].flipped);
    assert_eq!(c[4].twist.twist, None);
    // Card 2 is untouched.
    assert_eq!(r[4][1].twist.twist, Some(5));
    assert_eq!(r[4][1].threading, Some(S));
    let diags = validate(&b);
    let unsupported: Vec<&ply_tablet::Diagnostic> = diags
        .iter()
        .filter(|d| d.severity == Severity::Unsupported)
        .collect();
    assert_eq!(unsupported.len(), 1);
    assert_eq!(unsupported[0].code, TabletCode::UnsupportedTurn);
    assert!(unsupported[0].message.contains("half turn forward"));
    let released = diags
        .iter()
        .find(|d| d.code == TabletCode::TwistReleased)
        .unwrap();
    assert!(
        released.message.contains("some amounts unknown"),
        "{}",
        released.message
    );
    let flip = diags.iter().find(|d| d.code == TabletCode::Flip).unwrap();
    assert!(
        flip.message.contains("threading is unknown"),
        "{}",
        flip.message
    );
    // The band still simulates: a `?` is not an error.
    assert!(diags.iter().all(|d| d.severity != Severity::Error));
    // The resume state says the same.
    let s = state_after(&b, 5, &LIMITS).unwrap();
    assert_eq!((s.cards[0].position, s.cards[0].threading), (None, None));
}

#[test]
fn the_first_turn_after_an_unsupported_action_is_not_a_reversal() {
    // F, ?, B: the B might or might not reverse the cord (the `?` could have been anything), so
    // its twining is unknown and it is not marked.
    let mut b = band(&[(S, CardPosition::ply_home())], &["F", "?", "B", "F"]);
    b.turning.segments[0].picks[1]
        .unsupported
        .insert("card-1".into(), "turned twice".into());
    let r = rows(&b);
    assert!(!r[0][0].reversal);
    for p in &r[1..] {
        assert_eq!(p[0].twining, None);
        assert!(!p[0].reversal);
        assert_eq!(p[0].twist.twist, None);
    }
    assert!(validate(&b).iter().all(|d| d.code != TabletCode::Reversal));
}

#[test]
fn a_float_carries_on_through_a_flip() {
    // Home S card: F, I, then a flip before an idle, I, F. A flip swaps NT with FT and NB with FB,
    // so the upper threads stay upper. After pick 1 the card is B A D C (upper B, A; lower D, C);
    // the flip before pick 3 gives A B C D (upper A, B; lower C, D); pick 5 forward gives D A B C
    // (upper D, A; lower B, C). So A is upper on picks 1 to 5 and B on picks 1 to 4; C is lower on
    // picks 1 to 5 and D on 1 to 4.
    let mut b = band(&[(S, CardPosition::ply_home())], &["F", "I", "I", "I", "F"]);
    b.turning.segments[0].picks[2] = PickSpec::new("I").with_flip(&["card-1"]);
    let floats: Vec<TabletLocation> = validate(&b)
        .into_iter()
        .filter(|d| d.code == TabletCode::LongFloat)
        .map(|d| d.location)
        .collect();
    let run = |hole, face, last_pick, end| TabletLocation::Run {
        card: 1,
        hole,
        face,
        first_pick: 1,
        last_pick,
        end,
    };
    assert_eq!(
        floats,
        [
            run(A, Face::Top, 5, RunEnd::BandEnd),
            run(B, Face::Top, 4, RunEnd::Ended),
            run(C, Face::Back, 5, RunEnd::BandEnd),
            run(D, Face::Back, 4, RunEnd::Ended),
        ]
    );
    // The idles after the flip are ambiguous, and pick 5 (a Z card now, turned forward: S twining
    // after Z) is a reversal.
    let r = rows(&b);
    assert_eq!(r[2][0].top, FaceThread::Ambiguous(A, B));
    assert_eq!(r[3][0].top, FaceThread::Ambiguous(A, B));
    assert!(r[4][0].reversal);
}

#[test]
fn an_idle_carrying_on_an_empty_crossing_stays_not_modelled() {
    // Hole C empty. Home, F F F, then I: pick 1 shows C on the back (empty), pick 3 shows C on top
    // (empty), and the idle on pick 4 carries that empty crossing on: still not modelled.
    let mut b = band(&[(S, CardPosition::ply_home())], &["F", "F", "F", "I"]);
    b.cards[0].threads.c = None;
    let r = rows(&b);
    assert_eq!(r[2][0].top, FaceThread::Empty(C));
    assert_eq!(r[3][0].top, FaceThread::Empty(C));
    assert_eq!(r[3][0].back, FaceThread::Continued(A));
    let empty: Vec<TabletLocation> = validate(&b)
        .into_iter()
        .filter(|d| d.code == TabletCode::EmptyHoleFace)
        .map(|d| d.location)
        .collect();
    let at = |pick, face| TabletLocation::Pick {
        pick,
        cards: CardSet::one(1),
        face: Some(face),
    };
    assert_eq!(
        empty,
        [at(1, Face::Back), at(3, Face::Top), at(4, Face::Top)]
    );
}

#[test]
fn an_ambiguous_idle_that_could_show_an_empty_hole_is_not_modelled() {
    // An idle on pick 1 at home: top A or D, back C or B. With D empty the top could show nothing.
    let mut b = band(&[(S, CardPosition::ply_home())], &["I", "F"]);
    b.cards[0].threads.d = None;
    let w = try_simulate_all(&b, &LIMITS).unwrap();
    assert_eq!(
        w.face_row(&b, 1, Face::Top).unwrap()[0].color,
        ply_tablet::FaceColor::Either(Some(0), None)
    );
    let empty: Vec<TabletLocation> = validate(&b)
        .into_iter()
        .filter(|d| d.code == TabletCode::EmptyHoleFace)
        .map(|d| d.location)
        .collect();
    assert_eq!(
        empty,
        [TabletLocation::Pick {
            pick: 1,
            cards: CardSet::one(1),
            face: Some(Face::Top)
        }]
    );
}

#[test]
fn unsupported_cards_are_not_idle() {
    // A `?` card may have turned, so a pick with `?` and idles is not all idle; once every card is
    // `I` it is, even if one of them is unknown.
    let mut b = band(
        &[(S, CardPosition::ply_home()), (S, CardPosition::ply_home())],
        &["?I", "??", "II"],
    );
    let p = &mut b.turning.segments[0].picks;
    p[0].unsupported.insert("card-1".into(), "half turn".into());
    p[1].unsupported.insert("card-1".into(), "half turn".into());
    p[1].unsupported.insert("card-2".into(), "half turn".into());
    let idle: Vec<u32> = validate(&b)
        .iter()
        .filter(|d| d.code == TabletCode::AllIdle)
        .map(|d| match d.location {
            TabletLocation::Pick { pick, .. } => pick,
            _ => 0,
        })
        .collect();
    assert_eq!(idle, [3]);
}

#[test]
fn a_card_listed_twice_in_one_pack_overlaps() {
    let mut b = band(
        &[(S, CardPosition::ply_home()), (S, CardPosition::ply_home())],
        &["FF"],
    );
    b.packs = vec![Pack {
        id: "p1".into(),
        name: "Left".into(),
        cards: vec!["card-1".into(), "card-2".into(), "card-1".into()],
    }];
    let diags = validate(&b);
    assert_eq!(diags.len(), 1);
    assert_eq!(diags[0].code, TabletCode::PackOverlap);
    assert_eq!(
        diags[0].location,
        TabletLocation::PackCard {
            card: 1,
            packs: ply_tablet::PackSet {
                packs: vec![1],
                total: 1
            },
            listings: 2
        }
    );
    // The band still simulates.
    assert!(try_simulate_all(&b, &LIMITS).is_ok());
}

#[test]
fn messages_count_in_the_singular_when_there_is_one() {
    // Threshold 0: every run is a long float, including one of a single pick. Home F then F: A is
    // upper on pick 1 only.
    let mut b = band(&[(S, CardPosition::ply_home())], &["F", "F"]);
    b.settings.float_warning_picks = 0;
    let one = validate(&b)
        .into_iter()
        .find(|d| {
            matches!(
                d.location,
                TabletLocation::Run {
                    hole: A,
                    face: Face::Top,
                    ..
                }
            )
        })
        .unwrap();
    assert!(
        one.message.contains("for 1 pick (pick 1)"),
        "{}",
        one.message
    );
    // A release of one quarter turn.
    let mut b = band(&[(S, CardPosition::ply_home())], &["F", "F"]);
    b.turning.segments[0].picks[1].release_twist = vec!["card-1".into()];
    let released = validate(&b)
        .into_iter()
        .find(|d| d.code == TabletCode::TwistReleased)
        .unwrap();
    assert!(
        released.message.contains("(1 quarter turn)"),
        "{}",
        released.message
    );
    // One turn for a band of one card is fine; two letters for one card are counted.
    let b = band(&[(S, CardPosition::ply_home())], &["FF"]);
    let d = validate(&b);
    assert!(
        d[0].message.contains("gives 2 turns for a band of 1 card"),
        "{}",
        d[0].message
    );
}

#[test]
fn runs_cut_by_an_unknown_action_say_so() {
    // Idle four picks after one turn, then a `?`: A has been upper since pick 1 (it crossed the
    // top), so its run is picks 1 to 5 and then the card's state is unknown.
    let mut b = band(
        &[(S, CardPosition::ply_home())],
        &["F", "I", "I", "I", "I", "?"],
    );
    b.turning.segments[0].picks[5]
        .unsupported
        .insert("card-1".into(), "turned twice".into());
    let floats: Vec<TabletLocation> = validate(&b)
        .into_iter()
        .filter(|d| d.code == TabletCode::LongFloat)
        .map(|d| d.location)
        .collect();
    // After pick 1 the card is B A D C: upper B (NT) and A (FT), lower D (FB) and C (NB), each for
    // picks 1 to 5.
    let run = |hole, face| TabletLocation::Run {
        card: 1,
        hole,
        face,
        first_pick: 1,
        last_pick: 5,
        end: RunEnd::StateUnknown,
    };
    assert_eq!(
        floats,
        [
            run(A, Face::Top),
            run(B, Face::Top),
            run(C, Face::Back),
            run(D, Face::Back)
        ]
    );
}

#[test]
fn empty_holes_are_not_modelled_but_still_turn_and_twist() {
    // A two-hole threading: only A and B threaded. Forward from home shows A, B, then C and D (empty).
    let mut b = band(&[(S, CardPosition::ply_home())], &["F", "F", "F", "F"]);
    b.cards[0].threads = HoleThreads {
        a: Some(0),
        b: Some(1),
        c: None,
        d: None,
    };
    let r = rows(&b);
    assert_eq!(
        tops(&r, 0),
        [
            FaceThread::Thread(A),
            FaceThread::Thread(B),
            FaceThread::Empty(C),
            FaceThread::Empty(D)
        ]
    );
    assert_eq!(r[3][0].twist.twist, Some(4));
    assert_eq!(r[3][0].position, Some(CardPosition::ply_home()));
    let w = try_simulate_all(&b, &LIMITS).unwrap();
    assert_eq!(
        w.face_row(&b, 3, Face::Top).unwrap()[0].color,
        ply_tablet::FaceColor::NotModelled
    );
    // The back shows C, D (empty) then A, B.
    let empty: Vec<TabletLocation> = validate(&b)
        .into_iter()
        .filter(|d| d.code == TabletCode::EmptyHoleFace)
        .map(|d| d.location)
        .collect();
    let at = |pick, face| TabletLocation::Pick {
        pick,
        cards: CardSet::one(1),
        face: Some(face),
    };
    assert_eq!(
        empty,
        [
            at(1, Face::Back),
            at(2, Face::Back),
            at(3, Face::Top),
            at(4, Face::Top)
        ]
    );
}

#[test]
fn all_idle_picks_and_notes_are_reported() {
    let mut b = band(
        &[(S, CardPosition::ply_home()), (Z, CardPosition::ply_home())],
        &["II", "FF", "II"],
    );
    b.turning.segments[0].picks[1].note = Some(PickNote {
        kind: NoteKind::Brocade,
        text: "gold weft over cards 1 and 2".into(),
    });
    let diags = validate(&b);
    let idle: Vec<u32> = diags
        .iter()
        .filter(|d| d.code == TabletCode::AllIdle)
        .map(|d| match d.location {
            TabletLocation::Pick { pick, .. } => pick,
            _ => 0,
        })
        .collect();
    assert_eq!(idle, [1, 3]);
    let note = diags
        .iter()
        .find(|d| d.code == TabletCode::NoteNotDrawn)
        .unwrap();
    assert_eq!(note.severity, Severity::Unsupported);
    assert!(note.message.contains("brocade weft"));
    let w = try_simulate_all(&b, &LIMITS).unwrap();
    assert!(w.info(1).unwrap().all_idle && !w.info(2).unwrap().all_idle);
    assert_eq!(w.info(2).unwrap().note, Some(NoteKind::Brocade));
}

#[test]
fn twist_warnings_fire_each_time_the_threshold_is_passed() {
    // 40 forward picks on an S and a Z card: |twist| passes 32 on pick 33 (33 quarter turns).
    let mut b = band(
        &[(S, CardPosition::ply_home()), (Z, CardPosition::ply_home())],
        &[],
    );
    b.turning = TurnSequence::new(vec![
        Segment::new(40, vec![PickSpec::new("FF")]),
        // Release card 1 only, then 40 more: card 1 passes again on pick 73; card 2 is already past.
        Segment::new(1, vec![PickSpec::new("FF").with_release(&["card-1"])]),
        Segment::new(39, vec![PickSpec::new("FF")]),
    ]);
    let high: Vec<TabletLocation> = validate(&b)
        .into_iter()
        .filter(|d| d.code == TabletCode::TwistHigh)
        .map(|d| d.location)
        .collect();
    assert_eq!(
        high,
        [
            TabletLocation::Pick {
                pick: 33,
                cards: CardSet::from_sorted(&[1, 2]),
                face: None
            },
            TabletLocation::Pick {
                pick: 73,
                cards: CardSet::one(1),
                face: None
            },
        ]
    );
    let s = state_after(&b, 80, &LIMITS).unwrap();
    assert_eq!(s.cards[0].twist.twist, Some(40));
    assert_eq!(s.cards[0].twist.woven, Some(80));
    assert_eq!(s.cards[1].twist.twist, Some(-80));
    // A lower threshold of the band's own.
    b.settings.twist_warning_quarters = 3;
    let first = validate(&b)
        .into_iter()
        .find(|d| d.code == TabletCode::TwistHigh)
        .unwrap();
    assert!(matches!(
        first.location,
        TabletLocation::Pick { pick: 4, .. }
    ));
    assert!(
        first.message.contains("more than 3 quarter turns"),
        "{}",
        first.message
    );
}

#[test]
fn long_lists_are_capped_with_a_count() {
    // 4F 4B for 400 picks reverses on 99 picks; list at most 10 of them.
    let mut b = band(&[(S, CardPosition::ply_home())], &[]);
    b.turning = TurnSequence::new(vec![Segment::new(
        50,
        ["F", "F", "F", "F", "B", "B", "B", "B"]
            .map(PickSpec::new)
            .to_vec(),
    )]);
    let limits = TabletLimits {
        max_diagnostics_per_code: 10,
        ..LIMITS
    };
    let diags = validate_with(&b, &limits);
    assert_eq!(
        diags
            .iter()
            .filter(|d| d.code == TabletCode::Reversal)
            .count(),
        10
    );
    let capped = diags.last().unwrap();
    assert_eq!(capped.code, TabletCode::ListCapped);
    assert!(capped.message.contains("89 more"), "{}", capped.message);
}

#[test]
fn windows_match_the_whole_band() {
    let b = band(
        &[
            (S, CardPosition::ply_home()),
            (Z, CardPosition::PRINTED_FACE_RIGHT),
        ],
        &["FB", "FB", "IF", "BF", "FI", "BB", "FF"],
    );
    let all = try_simulate_all(&b, &LIMITS).unwrap();
    for first in 1..=7 {
        for last in first..=7 {
            let w = try_simulate(&b, first..=last, &LIMITS).unwrap();
            for p in first..=last {
                assert_eq!(w.row(p), all.row(p), "window {first}..={last}, pick {p}");
                assert_eq!(w.info(p), all.info(p));
            }
            assert_eq!(w.row(last + 1), None);
            let s = state_after(&b, last, &LIMITS).unwrap();
            for (c, st) in s.cards.iter().enumerate() {
                let cp = all.card_pick(last, c).unwrap();
                assert_eq!(
                    (st.position, st.threading, st.twist),
                    (cp.position, cp.threading, cp.twist)
                );
            }
        }
    }
}

#[test]
fn a_window_cell_is_small() {
    // The window budget (1,000,000 cells, about 48 MB) assumes a cell of 48 bytes.
    assert!(
        std::mem::size_of::<CardPick>() <= 48,
        "{}",
        std::mem::size_of::<CardPick>()
    );
}

/// A band of `cards` cards (odd S, even Z) all turned forward for `picks` picks.
fn forward_band(cards: usize, picks: u32) -> TabletBand {
    TabletBand {
        palette: vec![Color::BLACK],
        cards: (0..cards)
            .map(|i| {
                Tablet::new(
                    format!("c{i}"),
                    HoleThreads::all(0),
                    if i % 2 == 0 { S } else { Z },
                    CardPosition::ply_home(),
                )
            })
            .collect(),
        turning: TurnSequence::new(vec![Segment::new(
            picks,
            vec![PickSpec::all(Turn::Forward, cards)],
        )]),
        ..TabletBand::default()
    }
}

fn stress(cards: usize, picks: u32, window: u32) {
    let b = forward_band(cards, picks);
    let end = state_after(&b, picks, &LIMITS).unwrap();
    let n = i32::try_from(picks).unwrap();
    for (i, c) in end.cards.iter().enumerate() {
        let want = if i % 2 == 0 { n } else { -n };
        assert_eq!(c.twist.twist, Some(want));
        assert_eq!(c.twist.woven, Some(want));
        // picks forward quarter turns from home.
        let mut p = CardPosition::ply_home();
        for _ in 0..picks % 4 {
            p = p.forward();
        }
        assert_eq!(c.position, Some(p));
    }
    // The last window equals the same rows of a run computed in two chunks, and repeats exactly.
    let last = picks - window + 1..=picks;
    let direct = try_simulate(&b, last.clone(), &LIMITS).unwrap();
    let half = window / 2;
    let a = try_simulate(&b, picks - window + 1..=picks - half, &LIMITS).unwrap();
    let z = try_simulate(&b, picks - half + 1..=picks, &LIMITS).unwrap();
    for p in last {
        let chunk = if p <= picks - half { &a } else { &z };
        assert_eq!(direct.row(p), chunk.row(p), "pick {p}");
    }
    assert_eq!(
        try_simulate(&b, picks - window + 1..=picks, &LIMITS).unwrap(),
        direct
    );
    // Validation runs to the end: only the twist warning (pick 33 for every card).
    let diags = validate(&b);
    assert_eq!(diags.len(), 1, "{diags:#?}");
    assert_eq!(diags[0].code, TabletCode::TwistHigh);
}

#[test]
fn large_sequence_bounds_default_size() {
    // 100 cards by 20,000 forward picks, windows of 2,000 picks.
    stress(100, 20_000, 2_000);
}

#[test]
#[ignore = "full-size stress at the caps; run in release mode"]
fn large_sequence_bounds_at_the_caps() {
    // 1,000 cards by 200,000 forward picks: twist reaches exactly 200,000 with no overflow.
    stress(ply_tablet::MAX_CARDS, ply_tablet::MAX_PICKS, 1_000);
}
