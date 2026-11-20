use super::*;
use crate::band::{HoleThreads, Pack, PickNote, PickSpec, Segment, Tablet, TurnSequence};
use crate::card::CardPosition;
use crate::simulate::{state_after, try_simulate};
use crate::validate::check;
use ply_common::Color;

const L: TabletLimits = TabletLimits::DEFAULT;

fn card(i: usize, threading: ThreadingDirection) -> Tablet {
    Tablet::new(
        format!("card-{}", i + 1),
        HoleThreads::new(0, 1, 0, 1),
        threading,
        CardPosition::ply_home(),
    )
}

/// `cards` S-threaded cards at Ply home, one segment worked `repeat` times.
fn band(cards: usize, picks: &[&str], repeat: u32) -> TabletBand {
    TabletBand {
        palette: vec![Color::BLACK, Color::WHITE],
        cards: (0..cards).map(|i| card(i, ThreadingDirection::S)).collect(),
        turning: TurnSequence::new(vec![Segment::new(
            repeat,
            picks.iter().map(|t| PickSpec::new(*t)).collect(),
        )]),
        ..TabletBand::default()
    }
}

/// The band with its turning written out `times` times in a row: what a weaver works on `times`
/// times through, as one long band.
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

#[test]
fn a_window_says_what_to_do_and_how_every_card_is() {
    let b = band(4, &["FFFF", "BBFF", "IIII"], 1);
    let w = window(&b, 1, 3, 1, None, &L).unwrap();
    assert_eq!((w.picks, w.cards, w.time), (3, 4, 1));
    assert_eq!(
        w.rows.iter().map(|r| r.pick).collect::<Vec<_>>(),
        vec![1, 2, 3]
    );
    assert_eq!(w.rows[0].text, "Every card forward.");
    assert_eq!(
        w.rows[1].text,
        "Cards 1 and 2 backward; cards 3 and 4 forward."
    );
    assert_eq!(w.rows[2].text, "No card turns (every card idles).");
    assert!(w.rows[2].all_idle && !w.rows[0].all_idle);
    assert_eq!(
        (
            w.rows[0].segment,
            w.rows[0].step,
            w.rows[0].segment_repeat,
            w.rows[0].segment_repeats
        ),
        (1, 1, 1, 1)
    );
    // Before pick 1: every card as set up, no twist.
    for s in &w.before {
        assert_eq!(s.position, Some(CardPosition::ply_home()));
        assert_eq!(s.threading, Some(ThreadingDirection::S));
        assert_eq!(s.twist.twist, Some(0));
    }
    // The cells are the band's own simulation, without the float runs.
    let sim = try_simulate(&b, 1..=3, &L).unwrap();
    assert_eq!(w.cells, no_runs(&sim.cells));
    assert_eq!(w.row(2).unwrap(), &w.cells[4..8]);
    assert_eq!(w.start_note, None);
}

#[test]
fn the_cards_before_a_window_are_those_after_the_pick_before_it() {
    let b = band(2, &["FF", "FB", "BB", "FF"], 1);
    let w = window(&b, 3, 4, 1, None, &L).unwrap();
    let after2 = state_after(&b, 2, &L).unwrap();
    assert_eq!(w.before, after2.cards);
    assert_eq!(w.rows[0].pick, 3);
}

#[test]
fn events_and_notes_are_said_before_the_turns() {
    let mut b = band(2, &["FF", "FF"], 1);
    b.packs = vec![Pack {
        id: "left".into(),
        name: "Left".into(),
        cards: vec!["card-1".into()],
    }];
    b.turning.segments[0].picks[1] = PickSpec::new("FF")
        .with_flip(&["card-2"])
        .with_release(&["card-1"]);
    b.turning.segments[0].picks[1].note = Some(PickNote {
        kind: NoteKind::Brocade,
        text: "gold".into(),
    });
    b.turning.segments[0].picks[1].weft = Some(1);
    let w = window(&b, 2, 2, 1, None, &L).unwrap();
    assert_eq!(
        w.rows[0].text,
        "Before the pick: release the twist behind card 1; flip card 2 (it becomes Z-threaded). \
         Every card forward. The pattern adds a brocade weft here that the band chart does not \
         show: \"gold\". Weft: colour 2."
    );
    assert_eq!(w.rows[0].weft, Some(1));
}

#[test]
fn the_window_carries_each_picks_prefix() {
    let b = band(3, &["FFF", "BBB", "FBI", "III"], 2);
    let w = window(&b, 2, 8, 1, None, &L).unwrap();
    for r in &w.rows {
        assert_eq!(r.prefix, prefix(&b, r.pick, 1, &L).unwrap());
    }
    let all: std::collections::HashSet<u64> = w.rows.iter().map(|r| r.prefix).collect();
    assert_eq!(all.len(), w.rows.len(), "every pick's prefix differs");
    // On a later time through the whole band is before the place: other fingerprints, the same on
    // every later time.
    let prefixes = |t: u32| -> Vec<u64> {
        window(&b, 2, 8, t, None, &L)
            .unwrap()
            .rows
            .iter()
            .map(|r| r.prefix)
            .collect()
    };
    assert_ne!(prefixes(1), prefixes(2));
    assert_eq!(prefixes(2), prefixes(7));
    for r in &window(&b, 2, 8, 7, None, &L).unwrap().rows {
        assert_eq!(r.prefix, prefix(&b, r.pick, 7, &L).unwrap());
    }
}

/// The review probes: on time 2 every pick of the band was woven before the place, so an edit
/// after the place on the first time through, or a pick added at the end, changes how the cards
/// stand, and is shown for checking.
#[test]
fn on_a_later_time_any_edit_to_the_band_is_before_the_place() {
    let b = band(1, &["F", "F", "F", "F"], 1);
    let at = |b: &TabletBand| Basis {
        units: 4,
        prefix: prefix(b, 2, 2, &L).unwrap(),
    };
    let before = |b: &TabletBand| window(b, 2, 2, 2, None, &L).unwrap().before[0];
    assert_eq!(
        resume(&b, 2, 2, Some(at(&b)), &L).unwrap().resume.status,
        ResumeStatus::Same
    );
    // Probe A: pick 4 turned backward.
    let mut edited = b.clone();
    edited.turning.segments[0].picks[3].turns = "B".into();
    assert_ne!(before(&edited), before(&b), "the cards stand otherwise");
    let r = resume(&edited, 2, 2, Some(at(&b)), &L).unwrap();
    assert_eq!(r.resume.status, ResumeStatus::Changed);
    assert_eq!(r.pick, 2, "never moved");
    assert_eq!(
        r.message.unwrap(),
        "The band has changed since you saved your place, and on time 2 through all of it was \
         woven before your place. Check that pick 2 is where you are and that your cards are as \
         shown."
    );
    // The same edit on the first time through is after the place.
    let first = Basis {
        units: 4,
        prefix: prefix(&b, 2, 1, &L).unwrap(),
    };
    assert_eq!(
        resume(&edited, 2, 1, Some(first), &L)
            .unwrap()
            .resume
            .status,
        ResumeStatus::Same
    );
    // Probe B: a fifth pick added at the end.
    let longer = band(1, &["F", "F", "F", "F", "F"], 1);
    assert_ne!(before(&longer), before(&b));
    let r = resume(&longer, 2, 2, Some(at(&b)), &L).unwrap();
    assert_eq!(
        r.resume.status,
        ResumeStatus::Changed,
        "not just a length change"
    );
    assert_eq!(
        resume(&longer, 2, 1, Some(first), &L)
            .unwrap()
            .resume
            .status,
        ResumeStatus::LengthChanged { was: 4 }
    );
}

/// The work state of `w` at its start of the time through, when it worked one out.
fn start(w: &WorkWindow) -> Option<&Vec<u8>> {
    w.states.iter().find(|s| s.done == 0).map(|s| &s.bytes)
}

/// The latest work state of `w` before pick `first`, as the app chooses one.
fn before(w: &WorkWindow, first: u32) -> Option<&Vec<u8>> {
    w.states
        .iter()
        .filter(|s| s.done < first)
        .max_by_key(|s| s.done)
        .map(|s| &s.bytes)
}

#[test]
fn a_window_resumed_from_a_work_state_is_the_same_window() {
    let mut b = band(3, &["FFF", "BFI", "FBB"], 30);
    b.turning.segments[0].picks[1] = PickSpec::new("BFI").with_flip(&["card-2"]);
    for time in [1, 2, 6, 1_000_003] {
        let full = window(&b, 1, 90, time, None, &L).unwrap();
        assert_eq!(start(&full).is_some(), time > 1, "time {time}");
        let fresh = |first: u32| window(&b, first, 90, time, None, &L).unwrap();
        // Next as the app does it: windows of 31 picks, the next asked for 5 picks before the end,
        // from the latest state before it; and Previous at a window's first pick.
        let head = window(&b, 40, 70, time, None, &L).unwrap();
        assert_eq!(
            head.states.iter().map(|s| s.done).collect::<Vec<_>>(),
            [&[0][..(time > 1) as usize], &[7, 39, 70]].concat(),
            "the start, the stretches folded through before the window, the pick before, the last"
        );
        for first in [66, 39, 45, 71] {
            let from = before(&head, first).unwrap();
            let w = window(&b, first, 90, time, Some(from), &L).unwrap();
            assert!(start(&w).is_none(), "nothing to work out again");
            let f = fresh(first);
            assert_eq!(
                (&w.cells, &w.rows, &w.before),
                (&f.cells, &f.rows, &f.before)
            );
            assert_eq!(w.start_note, full.start_note);
        }
        // A state at or after the window, of another time or band, damaged, or an edit with a
        // plain checksum recomputed, is not used.
        let mut damaged = head.states[1].bytes.clone();
        damaged[20] ^= 1;
        let mut edited = head.states[1].bytes.clone();
        let n = edited.len() - 8;
        // Card 1's twist (after a 41-byte header, its arrangement, threading and flags): an edit
        // the range checks allow, and that would change the window.
        edited[41 + 3] ^= 1;
        let sum = edited[..n].iter().fold(0xcbf2_9ce4_8422_2325u64, |h, &x| {
            (h ^ u64::from(x)).wrapping_mul(0x0000_0100_0000_01b3)
        });
        edited[n..].copy_from_slice(&sum.to_le_bytes());
        let mut other = b.clone();
        other.cards[0].threading = ThreadingDirection::Z;
        let foreign = window(&other, 40, 70, time, None, &L).unwrap();
        let elsewhere = window(&b, 40, 70, time + 1, None, &L).unwrap();
        for from in [
            head.states.last().map(|s| &s.bytes).unwrap(),
            &damaged,
            &edited,
            before(&foreign, 45).unwrap(),
            before(&elsewhere, 45).unwrap(),
            &vec![1, 2, 3],
        ] {
            let w = window(&b, 45, 90, time, Some(from), &L).unwrap();
            assert_eq!(w.cells, fresh(45).cells);
            assert_eq!(start(&w).is_some(), time > 1, "worked out again");
        }
    }
}

#[test]
fn a_state_edited_past_its_seal_never_panics() {
    // Bytes this run sealed again after an edit (which only the run's own key can do) are still
    // range-checked: any edit gives a window, or the state is refused; never a panic.
    let b = band(2, &["F?", "BI"], 6);
    let mut b = b;
    b.turning.segments[0].picks[0]
        .unsupported
        .insert("card-2".into(), "half turn".into());
    let w = window(&b, 5, 8, 2, None, &L).unwrap();
    let state = before(&w, 9).unwrap().clone();
    let n = state.len() - 8;
    for at in 0..n {
        for flip in [1u8, 0x80, 0xFF] {
            let mut e = state.clone();
            e[at] ^= flip;
            let sum = crate::checkpoint::seal(&e[..n]);
            e[n..].copy_from_slice(&sum.to_le_bytes());
            let r = window(&b, 9, 12, 2, Some(&e), &L).unwrap();
            assert_eq!(r.rows.len(), 4);
            assert_eq!(r.cells.len(), 8);
        }
    }
}

#[test]
fn a_count_too_large_for_another_time_through_is_unknown_from_time_2() {
    // A start whose twist could pass `i32` during the time through is never folded from: the start
    // of every later time is bounded, and a work state holding such a count is refused.
    let b = band(1, &["F", "F"], 1);
    let c = check(&b, &L).unwrap();
    let mut sims = Fold::new(&c).sims;
    sims[0].twist.twist = Some(i32::MAX - 1);
    sims[0].twist.woven = Some(-(i32::MAX - 1));
    let out = bounded(&c, sims.clone());
    assert_eq!((out[0].twist.twist, out[0].twist.woven), (None, None));
    let state = encode_state(band_fingerprint(&b), 2, true, Place::default(), &sims);
    let w = window(&b, 1, 2, 2, Some(&state), &L).unwrap();
    assert!(start(&w).is_some(), "the state was refused");
    assert_eq!(
        w.before[0].twist.twist,
        Some(2),
        "worked out, not taken from the state"
    );
    for t in 2..=5 {
        for s in start_of(&c, t) {
            for v in [s.twist.twist, s.twist.woven].into_iter().flatten() {
                assert!(i64::from(v).abs() <= count_limit(&c));
            }
        }
    }
}

#[test]
fn notes_and_words_are_given_in_full_within_the_window_budget() {
    let mut b = band(3, &["F?F", "FFF"], 1);
    let long = "a".repeat(200) + "!";
    b.turning.segments[0].picks[0]
        .unsupported
        .insert("card-2".into(), long.clone());
    b.turning.segments[0].picks[1].note = Some(PickNote {
        kind: NoteKind::Brocade,
        text: long.clone(),
    });
    let w = window(&b, 1, 2, 1, None, &L).unwrap();
    assert!(w.rows[0].text.contains("..."), "{}", w.rows[0].text);
    assert_eq!(
        w.rows[0].words,
        vec![PickWords {
            cards: "card 2".into(),
            text: long.clone()
        }]
    );
    assert_eq!(w.rows[1].note.as_ref().unwrap().text, long);
    assert!(!w.rows[0].text_left_out && !w.rows[1].text_left_out);
    // Past the budget the rest are left out, never the first pick's.
    let note = PickNote {
        kind: NoteKind::Other,
        text: "n".repeat(10_000),
    };
    let mut many = band(1, &["F"], 1);
    many.turning.segments[0].picks = (0..150)
        .map(|_| PickSpec {
            note: Some(note.clone()),
            ..PickSpec::new("F")
        })
        .collect();
    let w = window(&many, 1, 150, 1, None, &L).unwrap();
    let kept = w.rows.iter().filter(|r| r.note.is_some()).count();
    assert_eq!(kept, MAX_WORK_TEXT_BYTES / 10_000);
    assert!(w.rows[kept].text_left_out && w.rows[kept].note.is_none());
    let w = window(&many, 120, 150, 1, None, &L).unwrap();
    assert!(w.rows[0].note.is_some(), "a window starting at it holds it");
}

#[test]
fn many_cards_with_their_own_words_are_grouped_in_linear_time() {
    // 1,000 `?` cards, each with its own 1,000-byte words (cards are compared by a number, never
    // word by word).
    let n = 1000;
    let mut b = band(n, &[&"?".repeat(n)], 3);
    for i in 0..n {
        b.turning.segments[0].picks[0].unsupported.insert(
            format!("card-{}", i + 1).as_str().into(),
            format!("{i:04}").repeat(250),
        );
    }
    let w = window(&b, 1, 3, 1, None, &L).unwrap();
    assert_eq!(w.rows[0].words.len(), n);
    assert!(w.rows[0].text.contains("and 988 more groups of cards"));
}

#[test]
fn everything_the_weaver_is_told_is_in_the_fingerprint() {
    let b = band(2, &["FF", "BF", "FF", "BB"], 1);
    let base = |b: &TabletBand| prefix(b, 3, 1, &L).unwrap();
    let at = base(&b);
    let changed = |f: &dyn Fn(&mut TabletBand), what: &str| {
        let mut e = b.clone();
        f(&mut e);
        assert_ne!(base(&e), at, "{what}");
    };
    let same = |f: &dyn Fn(&mut TabletBand), what: &str| {
        let mut e = b.clone();
        f(&mut e);
        assert_eq!(base(&e), at, "{what}");
    };
    changed(
        &|e| e.turning.segments[0].picks[1].turns = "BB".into(),
        "a turn before the place",
    );
    changed(
        &|e| e.turning.segments[0].picks[2].turns = "FI".into(),
        "a turn at the place",
    );
    changed(
        &|e| e.turning.segments[0].picks[0] = PickSpec::new("FF").with_flip(&["card-1"]),
        "a flip",
    );
    changed(
        &|e| e.turning.segments[0].picks[0] = PickSpec::new("FF").with_release(&["card-2"]),
        "a release",
    );
    changed(
        &|e| {
            e.turning.segments[0].picks[1].note = Some(PickNote {
                kind: NoteKind::Other,
                text: "beads".into(),
            })
        },
        "a note",
    );
    changed(
        &|e| e.turning.segments[0].picks[0].weft = Some(1),
        "a pick's weft",
    );
    changed(&|e| e.weft = Some(0), "the band's weft");
    changed(
        &|e| e.cards[1].threads.set(Hole::C, Some(1)),
        "a thread's colour",
    );
    changed(&|e| e.cards[1].threads.set(Hole::C, None), "an empty hole");
    changed(
        &|e| e.palette[0] = Color::rgb(200, 0, 0),
        "the yarn of a colour",
    );
    changed(
        &|e| e.cards[0].threading = ThreadingDirection::Z,
        "a card's threading",
    );
    changed(
        &|e| e.cards[0].start = CardPosition::ply_home().forward().arrangement(),
        "a card's start",
    );
    changed(
        &|e| {
            e.cards.push(card(2, ThreadingDirection::S));
            for p in &mut e.turning.segments[0].picks {
                p.turns.push('I');
            }
        },
        "another card",
    );
    changed(
        &|e| e.turning.segments[0].picks.insert(0, PickSpec::new("II")),
        "a pick inserted before",
    );
    {
        let mut q = b.clone();
        q.turning.segments[0].picks[1].turns = "?F".into();
        q.turning.segments[0].picks[1]
            .unsupported
            .insert("card-1".into(), "half turn".into());
        let mut r = q.clone();
        r.turning.segments[0].picks[1]
            .unsupported
            .insert("card-1".into(), "a whole turn".into());
        assert_ne!(base(&q), base(&r), "the pattern's own words");
    }
    // What is after the place, or never told, does not count.
    same(
        &|e| e.turning.segments[0].picks[3].turns = "FF".into(),
        "a turn after the place",
    );
    same(&|e| e.cards[0].id = "renamed".into(), "a card id");
    same(
        &|e| {
            e.packs = vec![Pack {
                id: "p".into(),
                name: "Left".into(),
                cards: vec!["card-1".into()],
            }]
        },
        "a pack",
    );
    same(
        &|e| e.settings.twist_warning_quarters = 3,
        "a warning threshold",
    );
    same(&|e| e.palette.push(Color::rgb(1, 2, 3)), "an unused colour");
    // The same picks written as two segments are the same work.
    let mut split = b.clone();
    let rest = split.turning.segments[0].picks.split_off(2);
    split.turning.segments.push(Segment::new(1, rest));
    assert_eq!(base(&split), at, "a segment split in two");
}

#[test]
fn a_repeat_and_the_picks_it_stands_for_are_the_same_work() {
    let repeated = band(2, &["FF", "BB"], 3);
    let written = band(2, &["FF", "BB", "FF", "BB", "FF", "BB"], 1);
    for p in 1..=6 {
        assert_eq!(prefix(&repeated, p, 1, &L), prefix(&written, p, 1, &L));
    }
}

#[test]
fn resuming_the_same_band_needs_nothing() {
    let b = band(2, &["FF", "BB", "FB"], 1);
    let basis = Basis {
        units: 3,
        prefix: prefix(&b, 2, 1, &L).unwrap(),
    };
    let r = resume(&b, 2, 1, Some(basis), &L).unwrap();
    assert_eq!(r.resume.status, ResumeStatus::Same);
    assert_eq!((r.pick, r.picks, r.message), (2, 3, None));
}

#[test]
fn an_edit_before_the_place_is_shown_for_checking_at_the_same_number() {
    let b = band(2, &["FF", "BB", "FB"], 1);
    let basis = Basis {
        units: 3,
        prefix: prefix(&b, 3, 1, &L).unwrap(),
    };
    let mut edited = b.clone();
    edited.turning.segments[0]
        .picks
        .insert(0, PickSpec::new("II"));
    let r = resume(&edited, 3, 1, Some(basis), &L).unwrap();
    assert_eq!(r.resume.status, ResumeStatus::Changed);
    assert_eq!(r.pick, 3, "never moved");
    assert_eq!(
        r.message.unwrap(),
        "The band has changed at or before pick 3 since you saved your place. Check that pick 3 \
         is where you are and that your cards are as shown."
    );
    // A setup change is one too: every card shows something else.
    let mut threads = b.clone();
    threads.cards[0].threading = ThreadingDirection::Z;
    let r = resume(&threads, 3, 1, Some(basis), &L).unwrap();
    assert_eq!(r.resume.status, ResumeStatus::Changed);
}

#[test]
fn picks_added_after_the_place_are_said_and_picks_removed_under_it_clamp_it() {
    let b = band(2, &["FF", "BB", "FB"], 1);
    let basis = Basis {
        units: 3,
        prefix: prefix(&b, 2, 1, &L).unwrap(),
    };
    let longer = band(2, &["FF", "BB", "FB", "II"], 1);
    let r = resume(&longer, 2, 1, Some(basis), &L).unwrap();
    assert_eq!(r.resume.status, ResumeStatus::LengthChanged { was: 3 });
    assert_eq!(
        r.message.unwrap(),
        "The band has changed after your place: it now has 4 picks (it had 3). Your place is \
         unchanged."
    );
    let at3 = Basis {
        units: 3,
        prefix: prefix(&b, 3, 1, &L).unwrap(),
    };
    let shorter = band(2, &["FF", "BB"], 1);
    let r = resume(&shorter, 3, 1, Some(at3), &L).unwrap();
    assert_eq!(r.resume.status, ResumeStatus::Clamped { was: 2 });
    assert_eq!(r.pick, 2);
    assert_eq!(
        r.message.unwrap(),
        "Your place was pick 3, but the band now has 2 picks. It is shown at pick 2: check where \
         you are."
    );
    // A place without a basis is shown for checking.
    let r = resume(&b, 2, 1, None, &L).unwrap();
    assert_eq!(r.resume.status, ResumeStatus::Changed);
}

#[test]
fn a_band_with_no_picks_has_nothing_to_weave() {
    let b = TabletBand {
        palette: vec![Color::BLACK, Color::WHITE],
        cards: vec![card(0, ThreadingDirection::S)],
        ..TabletBand::default()
    };
    let r = resume(&b, 9, 1, None, &L).unwrap();
    assert_eq!(r.resume.status, ResumeStatus::Empty);
    assert_eq!(r.pick, 1);
    assert_eq!(r.message.unwrap(), "This band has no picks to weave.");
    let w = window(&b, 1, 10, 1, None, &L).unwrap();
    assert!(w.rows.is_empty() && w.cells.is_empty());
    assert_eq!(w.before.len(), 1);
    assert!(window(&b, 2, 10, 1, None, &L).is_err());
    assert!(
        window(&b, 0, 10, 1, None, &L).is_err(),
        "picks are counted from 1"
    );
}

#[test]
fn the_window_is_cut_to_the_band_and_refuses_what_is_not_there() {
    let b = band(2, &["FF", "BB", "FB"], 1);
    assert_eq!(window(&b, 2, 1000, 1, None, &L).unwrap().rows.len(), 2);
    assert_eq!(window(&b, 1, 3, 0, None, &L), Err(TabletError::InvalidTime));
    assert_eq!(
        TabletError::InvalidTime.to_string(),
        "there is no time 0 through the band: times through are counted from 1"
    );
    for (first, last, time) in [(0, 2, 1), (4, 5, 1), (3, 2, 1)] {
        assert!(
            matches!(
                window(&b, first, last, time, None, &L),
                Err(TabletError::InvalidWindow { .. })
            ),
            "{first} {last} {time}"
        );
    }
    // A band with errors is refused, as simulation refuses it.
    let mut bad = b.clone();
    bad.turning.segments[0].picks[0].turns = "F".into();
    assert!(matches!(
        window(&bad, 1, 1, 1, None, &L),
        Err(TabletError::Invalid(_))
    ));
    assert!(matches!(
        resume(&bad, 1, 1, None, &L),
        Err(TabletError::Invalid(_))
    ));
    assert!(prefix(&bad, 1, 1, &L).is_err());
}

#[test]
fn a_window_holds_at_most_its_picks_and_cells_and_always_the_first() {
    let long = band(1, &["F"], 2000);
    let w = window(&long, 1, 2000, 1, None, &L).unwrap();
    assert_eq!(w.rows.len(), MAX_WORK_WINDOW as usize);
    let w = window(&long, 1999, 2000, 1, None, &L).unwrap();
    assert_eq!(
        w.rows.iter().map(|r| r.pick).collect::<Vec<_>>(),
        vec![1999, 2000],
        "the last picks of the band"
    );
    let wide = band(1000, &[&"F".repeat(1000)], 200);
    let w = window(&wide, 1, 200, 1, None, &L).unwrap();
    assert_eq!(w.rows.len(), MAX_WORK_CELLS / 1000);
    assert_eq!(w.cells.len(), MAX_WORK_CELLS);
    let w = window(&wide, 200, 200, 3, None, &L).unwrap();
    assert_eq!(w.rows[0].pick, 200);
    assert_eq!(w.cells.len(), 1000);
}

#[test]
fn a_later_time_through_starts_where_the_last_one_ended() {
    // Three forward picks do not bring a card home: time 2 starts a quarter turn back from home,
    // with three quarter turns of twist.
    let b = band(2, &["FF", "FF", "FF"], 1);
    for time in 1..=9 {
        let w = window(&b, 1, 3, time, None, &L).unwrap();
        let long = worked(&b, time);
        let first = (time - 1) * 3 + 1;
        let sim = try_simulate(&long, first..=first + 2, &L).unwrap();
        assert_eq!(w.cells, no_runs(&sim.cells), "time {time}");
        assert_eq!(w.before, state_after(&long, first - 1, &L).unwrap().cards);
        assert_eq!(w.before[0].twist.twist, Some(3 * (time as i32 - 1)));
        assert_eq!(w.start_note.is_some(), time % 4 != 1, "time {time}");
    }
    let w = window(&b, 1, 1, 2, None, &L).unwrap();
    assert_eq!(
        w.start_note.unwrap(),
        "On time 2 through the band your cards do not start as they were set up: they start \
         where time 1 ended, so what they show here differs from the band chart."
    );
    // Four forward picks bring every card home: nothing to say, but the twist builds up.
    let home = band(2, &["FF", "FF", "FF", "FF"], 1);
    let w = window(&home, 1, 1, 3, None, &L).unwrap();
    assert_eq!(w.start_note, None);
    assert_eq!(w.before[0].twist.twist, Some(8));
}

#[test]
fn a_far_time_through_is_worked_out_without_folding_every_time() {
    let b = band(1, &["F", "F", "F"], 1);
    let t = 500_000_001u32;
    let w = window(&b, 1, 1, t, None, &L).unwrap();
    // Each time through turns a card three quarter turns forward.
    let quarters = 3 * (t - 1);
    let expected = (0..quarters % 4).fold(CardPosition::ply_home(), |p, _| p.forward());
    assert_eq!(w.before[0].position, Some(expected));
    assert_eq!(
        w.before[0].twist.twist,
        Some(i32::try_from(quarters).unwrap())
    );
    assert_eq!(w.before[0].twist.woven, w.before[0].twist.twist);
    // Past what a count can hold: unknown, never wrapped or a panic.
    let w = window(&b, 1, 3, u32::MAX, None, &L).unwrap();
    assert_eq!(w.before[0].twist.twist, None);
    assert_eq!(w.cells[2].twist.twist, None);
    assert!(
        w.before[0].position.is_some(),
        "the arrangement is still known"
    );
}

#[test]
fn a_released_twist_stays_released_every_time_through() {
    let mut b = band(1, &["F", "F", "F"], 1);
    b.turning.segments[0].picks[2] = PickSpec::new("F").with_release(&["card-1"]);
    for t in [2, 3, 6, 7, 1_000_003] {
        let w = window(&b, 1, 1, t, None, &L).unwrap();
        assert_eq!(w.before[0].twist.twist, Some(1), "time {t}");
        assert_eq!(
            w.before[0].twist.woven,
            Some(i32::try_from(3 * (t - 1)).unwrap()),
            "woven is never reset"
        );
    }
}

#[test]
fn a_flip_each_time_through_is_worded_for_the_time_through() {
    let mut b = band(1, &["F", "F"], 1);
    b.turning.segments[0].picks[0] = PickSpec::new("F").with_flip(&["card-1"]);
    let text = |t: u32| window(&b, 1, 1, t, None, &L).unwrap().rows[0].text.clone();
    assert!(
        text(1).contains("flip card 1 (it becomes Z-threaded)"),
        "{}",
        text(1)
    );
    assert!(
        text(2).contains("flip card 1 (it becomes S-threaded)"),
        "{}",
        text(2)
    );
    assert!(text(1_000_001).contains("(it becomes Z-threaded)"));
    // Twist: F on a Z card is S twining (-1), so each time through untwists the last.
    let tw = |t: u32| window(&b, 1, 1, t, None, &L).unwrap().before[0].twist.twist;
    assert_eq!(
        (tw(1), tw(2), tw(3), tw(4)),
        (Some(0), Some(-2), Some(0), Some(-2))
    );
    assert_eq!(tw(1_000_002), Some(-2));
}

#[test]
fn an_action_ply_does_not_model_makes_later_times_unknown() {
    let mut b = band(1, &["F", "?"], 1);
    b.turning.segments[0].picks[1]
        .unsupported
        .insert("card-1".into(), "half turn".into());
    for t in [2, 9, 4_000_000_000] {
        let w = window(&b, 1, 1, t, None, &L).unwrap();
        assert_eq!(w.before[0].position, None, "time {t}");
        assert_eq!(w.before[0].twist.twist, None);
    }
}

#[test]
fn a_band_at_the_limits_is_worked_out_in_bounded_windows() {
    // 1,000 cards of 200 picks each: every call stays within its cells.
    let wide = band(1000, &[&"FB".repeat(500)], 200);
    let w = window(&wide, 150, 400, 6, None, &L).unwrap();
    assert_eq!(w.rows.first().map(|r| r.pick), Some(150));
    assert!(w.cells.len() <= MAX_WORK_CELLS);
    assert_eq!(w.before.len(), 1000);
}
