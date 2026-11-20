//! Property tests of working a band pick by pick (ADR 0023, `ply_tablet::progress`). Over generated
//! valid bands (flips, releases, idles and `?` turns included):
//!
//! * every time through, from the first to the thirteenth and a far one, is exactly the band written
//!   out that many times and simulated in full (the cards before the window and at every pick), so
//!   the shortcut for later times through is held to the long way round;
//! * a pick's fingerprint is the same on every time through from the second on (the first has its
//!   own), and the window's agrees with [`prefix`];
//! * a window resumed from a work state of an earlier window of the same time is the window worked
//!   out afresh; a state of another time through (before the window, so only its time can refuse
//!   it) and a state edited with a plain checksum recomputed are refused, with the same result;
//! * a fingerprint changes exactly when something at or before its pick changes: a changed turn
//!   changes every prefix from its first pick on and none before it, and picks added at the end
//!   change none;
//! * windows and resumes never panic and are deterministic.
//!
//! Run: `cargo test -p ply-tablet --test progress_proptest`

use ply_common::progress::Basis;
use ply_common::Color;
use ply_tablet::progress::{prefix, resume, window};
use ply_tablet::{
    state_after, try_simulate, CardId, CardPick, CardPosition, HoleThreads, PickSpec, Segment,
    Tablet, TabletBand, TabletLimits, ThreadingDirection, TurnSequence,
};
use proptest::prelude::*;

const L: TabletLimits = TabletLimits::DEFAULT;

fn id(i: usize) -> CardId {
    CardId(format!("c{i}"))
}

/// A valid band of 1 to 3 cards and 1 to 3 segments (each 1 to 4 picks, worked 1 to 3 times).
fn arb_band() -> impl Strategy<Value = TabletBand> {
    (1usize..4).prop_flat_map(|n| {
        let pick = (
            prop::collection::vec(prop::sample::select(vec!['F', 'F', 'B', 'I', '?']), n),
            prop::collection::vec(prop::bool::weighted(0.2), n),
            prop::collection::vec(prop::bool::weighted(0.15), n),
        );
        (
            prop::collection::vec(
                (
                    prop_oneof![Just(ThreadingDirection::S), Just(ThreadingDirection::Z)],
                    prop::sample::select(CardPosition::all().to_vec()),
                    prop::collection::vec(prop::option::weighted(0.9, 0u32..3), 4),
                ),
                n,
            ),
            prop::collection::vec((1u32..4, prop::collection::vec(pick, 1..5)), 1..4),
        )
            .prop_map(move |(cards, segments)| TabletBand {
                palette: vec![Color::BLACK, Color::WHITE, Color::rgb(200, 0, 0)],
                cards: cards
                    .into_iter()
                    .enumerate()
                    .map(|(i, (threading, start, t))| {
                        Tablet::new(
                            format!("c{i}"),
                            HoleThreads {
                                a: t[0],
                                b: t[1],
                                c: t[2],
                                d: t[3],
                            },
                            threading,
                            start,
                        )
                    })
                    .collect(),
                turning: TurnSequence::new(
                    segments
                        .into_iter()
                        .map(|(repeat, picks)| {
                            Segment::new(
                                repeat,
                                picks
                                    .into_iter()
                                    .map(|(turns, flip, release)| {
                                        let unsupported = turns
                                            .iter()
                                            .enumerate()
                                            .filter(|(_, &c)| c == '?')
                                            .map(|(i, _)| (id(i), "half turn".to_string()))
                                            .collect();
                                        PickSpec {
                                            turns: turns.into_iter().collect(),
                                            release_twist: (0..n)
                                                .filter(|&i| release[i])
                                                .map(id)
                                                .collect(),
                                            flip: (0..n).filter(|&i| flip[i]).map(id).collect(),
                                            unsupported,
                                            note: None,
                                            weft: None,
                                        }
                                    })
                                    .collect(),
                            )
                        })
                        .collect(),
                ),
                ..TabletBand::default()
            })
    })
}

fn picks(b: &TabletBand) -> u32 {
    ply_tablet::expanded_picks(&b.turning, &L).unwrap()
}

/// The band written out `times` times in a row.
fn worked(b: &TabletBand, times: u32) -> TabletBand {
    let mut long = b.clone();
    long.turning.segments = (0..times)
        .flat_map(|_| b.turning.segments.iter().cloned())
        .collect();
    long
}

fn no_runs(cells: &[CardPick]) -> Vec<CardPick> {
    cells
        .iter()
        .map(|c| CardPick {
            top_run: None,
            back_run: None,
            ..*c
        })
        .collect()
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(256))]

    #[test]
    fn every_time_through_is_the_band_worked_out_in_full(band in arb_band()) {
        let n = picks(&band);
        let mut prefixes: Option<Vec<u64>> = None;
        let mut other_time: Option<(u32, Vec<u8>)> = None;
        for t in [1u32, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13] {
            let w = window(&band, 1, n, t, None, &L).unwrap();
            prop_assert_eq!(w.rows.len() as u32, n);
            let long = worked(&band, t);
            let first = (t - 1) * n + 1;
            let sim = try_simulate(&long, first..=first + n - 1, &L).unwrap();
            prop_assert_eq!(&w.cells, &no_runs(&sim.cells), "time {}", t);
            prop_assert_eq!(&w.before, &state_after(&long, first - 1, &L).unwrap().cards);
            let p: Vec<u64> = w.rows.iter().map(|r| r.prefix).collect();
            for (k, r) in w.rows.iter().enumerate() {
                prop_assert_eq!(r.prefix, prefix(&band, k as u32 + 1, t, &L).unwrap());
            }
            if t >= 2 {
                match &prefixes {
                    None => prefixes = Some(p),
                    Some(q) => prop_assert_eq!(q, &p, "the same fingerprints every later time"),
                }
            }
            // A window anywhere in the time through agrees with the whole time through, worked
            // out afresh or resumed from the work state of a window before it.
            let mid = n.div_ceil(2);
            let part = window(&band, mid, n, t, None, &L).unwrap();
            prop_assert_eq!(&part.cells[..], &w.cells[(mid as usize - 1) * band.cards.len()..]);
            let head = window(&band, 1, mid - 1, t, None, &L);
            let mut froms: Vec<Vec<u8>> = w.states.iter().filter(|s| s.done == 0).map(|s| s.bytes.clone()).collect();
            if let Ok(h) = &head {
                froms.extend(h.states.iter().map(|s| s.bytes.clone()));
            }
            for from in &froms {
                let resumed = window(&band, mid, n, t, Some(from), &L).unwrap();
                prop_assert_eq!(&resumed.cells, &part.cells);
                prop_assert_eq!(&resumed.rows, &part.rows);
                prop_assert_eq!(&resumed.before, &part.before);
                prop_assert_eq!(&resumed.start_note, &part.start_note);
            }
            // The state of another time through, after a pick before the window (so that only its
            // time can refuse it), is never taken for this one's.
            if let Some((tt, bytes)) = &other_time {
                let other = window(&band, mid, n, t, Some(bytes), &L).unwrap();
                prop_assert_eq!(&other.cells, &part.cells, "a state of time {}", tt);
                prop_assert_eq!(&other.before, &part.before);
            }
            other_time = part.states.iter().find(|s| s.done + 1 == mid && s.done > 0).map(|s| (t, s.bytes.clone()));
        }
    }

    #[test]
    fn a_far_time_through_repeats_every_four_with_the_twist_moved_on(
        band in arb_band(),
        k in 1u32..1000,
        r in 0u32..4,
    ) {
        // Time 6 + r and time 6 + r + 4k: the same arrangements, the twist moved on by k times the
        // change over four times through.
        let n = picks(&band);
        let near = window(&band, 1, n, 6 + r, None, &L).unwrap();
        let far = window(&band, 1, n, 6 + r + 4 * k, None, &L).unwrap();
        let next = window(&band, 1, n, 10 + r, None, &L).unwrap();
        for ((a, b), c) in near.cells.iter().zip(&far.cells).zip(&next.cells) {
            prop_assert_eq!(a.position, b.position);
            prop_assert_eq!(a.threading, b.threading);
            prop_assert_eq!(a.top, b.top);
            prop_assert_eq!(a.back, b.back);
            prop_assert_eq!(a.reversal, b.reversal);
            let moved = |x: Option<i32>, y: Option<i32>, z: Option<i32>| -> Option<i64> {
                Some(i64::from(x?) + i64::from(k) * (i64::from(y?) - i64::from(x?)) - i64::from(z?))
            };
            if let Some(d) = moved(a.twist.twist, c.twist.twist, b.twist.twist) {
                prop_assert_eq!(d, 0);
            }
        }
    }

    #[test]
    fn a_fingerprint_changes_exactly_from_the_first_pick_a_change_reaches(
        band in arb_band(),
        seg in 0usize..3,
        step in 0usize..4,
        card in 0usize..3,
    ) {
        let n = picks(&band);
        let s = seg % band.turning.segments.len();
        let k = step % band.turning.segments[s].picks.len();
        let c = card % band.cards.len();
        let mut edited = band.clone();
        let spec = &mut edited.turning.segments[s].picks[k];
        let mut letters: Vec<char> = spec.turns.chars().collect();
        letters[c] = match letters[c] { 'F' => 'B', 'B' => 'I', _ => 'F' };
        spec.turns = letters.into_iter().collect();
        spec.unsupported.retain(|cid, _| *cid != id(c));
        // The expanded pick (from 1) where the edited written pick is first worked.
        let before: u32 = band.turning.segments[..s]
            .iter()
            .map(|g| g.picks.len() as u32 * g.repeat)
            .sum();
        let first = before + k as u32 + 1;
        for p in 1..=n {
            let a = prefix(&band, p, 1, &L).unwrap();
            let b = prefix(&edited, p, 1, &L).unwrap();
            if p < first {
                prop_assert_eq!(a, b, "pick {} is before the change", p);
            } else {
                prop_assert_ne!(a, b, "pick {} is at or after the change", p);
            }
            // On a later time through the whole band is before every pick.
            prop_assert_ne!(prefix(&band, p, 2, &L).unwrap(), prefix(&edited, p, 2, &L).unwrap());
        }
        // Picks added at the end change no earlier prefix on the first time through (resume says
        // the length changed), and every prefix on a later one (shown for checking).
        let mut longer = band.clone();
        longer.turning.segments.push(Segment::new(1, vec![PickSpec::new("I".repeat(band.cards.len()))]));
        for p in 1..=n {
            prop_assert_eq!(prefix(&band, p, 1, &L).unwrap(), prefix(&longer, p, 1, &L).unwrap());
        }
        let basis = Basis { units: u64::from(n), prefix: prefix(&band, n, 1, &L).unwrap() };
        let r = resume(&longer, n, 1, Some(basis), &L).unwrap();
        prop_assert!(!r.resume.status.needs_a_look());
        prop_assert_eq!(r.pick, n);
        let r = resume(&edited, n, 1, Some(basis), &L).unwrap();
        prop_assert!(r.resume.status.needs_a_look());
        prop_assert_eq!(r.pick, n, "never moved");
        let later = Basis { units: u64::from(n), prefix: prefix(&band, 1, 3, &L).unwrap() };
        prop_assert!(!resume(&band, 1, 3, Some(later), &L).unwrap().resume.status.needs_a_look());
        prop_assert!(resume(&longer, 1, 3, Some(later), &L).unwrap().resume.status.needs_a_look());
    }

    #[test]
    fn windows_and_resumes_never_panic(
        band in arb_band(),
        first in 0u32..40,
        len in 0u32..40,
        time in prop_oneof![Just(0u32), 1u32..20, Just(u32::MAX)],
        pick in 0u32..50,
        units in 0u64..50,
        fp in any::<u64>(),
    ) {
        let a = window(&band, first, first.saturating_add(len), time, None, &L);
        prop_assert_eq!(&a, &window(&band, first, first.saturating_add(len), time, None, &L));
        if let Ok(w) = &a {
            prop_assert_eq!(w.rows.first().map(|r| r.pick), Some(first));
            prop_assert_eq!(w.cells.len(), w.rows.len() * band.cards.len());
            // Any bytes given as a work state: no panic, and the same window. An edit of any value
            // with a plain checksum recomputed (anything but this run's own seal) is refused.
            for state in &w.states {
                let mut junk = state.bytes.clone();
                let n = junk.len() - 8;
                let at = fp as usize % n.max(1);
                junk[at] ^= (fp >> 8) as u8 | 1;
                let mut resummed = junk.clone();
                let sum = resummed[..n].iter().fold(0xcbf2_9ce4_8422_2325u64, |h, &x| {
                    (h ^ u64::from(x)).wrapping_mul(0x0000_0100_0000_01b3)
                });
                resummed[n..].copy_from_slice(&sum.to_le_bytes());
                for from in [&junk, &resummed, &state.bytes] {
                    let again = window(&band, first, first.saturating_add(len), time, Some(from), &L);
                    prop_assert_eq!(again.map(|x| x.cells), Ok(w.cells.clone()));
                }
            }
        }
        let r = resume(&band, pick, time, Some(Basis { units, prefix: fp }), &L).unwrap();
        prop_assert!(r.pick >= 1 && r.pick <= picks(&band).max(1));
    }
}
