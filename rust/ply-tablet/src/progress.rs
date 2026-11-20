//! Working a band pick by pick (roadmap M8-05, ADR 0023): what to do at each pick of the expanded
//! band, in a weaver's words, every card as it should be before and after the pick, and where a
//! weaver who saved their place resumes.
//!
//! The work unit is one pick of the expanded band (ADR 0018 section 7), numbered from 1, and a band's
//! turning is woven as many times through as the band needs. What to do at a pick is the same every
//! time through (the written turns, flips and releases); what the cards show is not, when one time
//! through does not bring every card back to where it started: time 2 starts where time 1 ended, with
//! the twist it left. [`window`] works out the cards for the time through asked for.
//!
//! **Times through.** The cards at the start of time `t` are the cards after `t - 1` times through.
//! Each card's arrangement moves by the same quarter turns and flips every time, a fixed symmetry of
//! the card's four corners whose fourth power is the identity, and its threading flips with the
//! number of flips; the holes that last crossed and the last twining follow from those. So from time 2
//! on, everything but the twist repeats every four times through, and the twist changes by the same
//! amount every four times (nothing at all when the weaver releases it every time). A time through
//! past the fifth is worked out from the first five folds of the band, never by folding it billions
//! of times; a twist too large to count is unknown. Tests hold this to the band worked out in full.
//!
//! **Work states.** Each window hands back opaque bytes ([`WorkWindow::states`]): every card at a
//! few places on the time through (its start, when the window had to work it out; every 32 picks for
//! the 256 picks before the window that it folded through; the pick before it; its last pick), bound
//! to the band and the time through.
//! Given back with a later window, the latest one before it is checked against the band and resumed
//! from, so a time through is folded once per tracking session: Next, Previous and a Go to near the
//! place fold only a few dozen picks. States are sealed with a key drawn once per run of the app, so
//! an edited state, or one another run made, is refused (the window is then worked out without it,
//! with the same result). They must never be saved or exported: they live in the tracker's memory.
//!
//! A pick's IDENTITY is everything the weaver is told to do at it: every card's turn (with the
//! pattern's words for a turn Ply does not model), the cards released and flipped before it, its
//! note, and its weft. A place's fingerprint on the first time through is the hash of the setup
//! (every card's threads with their colours, threading and start) and of every pick's identity up to
//! and including the place ([`prefix`]), so an edit at or before the place, or to the setup, which
//! changes what each card should show, is caught, and an edit after it is not. On a later time
//! through the whole band has been woven before the place (and decides where the cards start), so
//! the fingerprint is of the setup, every pick of the band, and then the picks up to the place: any
//! edit to the band is caught. See [`ply_common::progress`] for how a saved place is compared with
//! the band as it is now.

use crate::band::{ColorIndex, NoteKind, PickNote, TabletBand, TabletLimits};
use crate::card::{Hole, ThreadingDirection, Turn};
use crate::checkpoint::{band_fingerprint, decode_state, encode_state};
use crate::error::TabletError;
use crate::instructions::{cards_text, pick_text, usable_packs, word_ids};
use crate::simulate::{
    CardPick, CardSim, CardState, Fold, NoObserver, Observer, PickContext, Place,
};
use crate::validate::{check, Checked};
use ply_common::progress::{reconcile, Basis, Fingerprint, Resume, ResumeStatus};
use std::collections::HashMap;

/// The most picks one [`window`] returns.
pub const MAX_WORK_WINDOW: u32 = 500;

/// The most cells (cards times picks) one [`window`] returns: a band of many cards gets fewer picks
/// per window. The first pick asked for is always returned (a band has at most 1,000 cards).
pub const MAX_WORK_CELLS: usize = 50_000;

/// The most bytes of full notes and `?` words one [`window`] returns beyond its first pick (whose own
/// are always returned in full); a later pick past it has [`PickWork::text_left_out`].
pub const MAX_WORK_TEXT_BYTES: usize = 1_000_000;

/// How far apart, before a window, [`window`] keeps work states (beside the one at the pick before
/// it): a little more than the windows the app asks for, so the windows before (Previous at a
/// window's first pick, again and again) resume from near them too.
pub const WORK_STATE_LOOKBACK: u32 = 32;

/// How many work states [`window`] keeps before a window it folds up to from further back: the
/// stretch a weaver can step back through ([`WORK_STATE_LOOKBACK`] times this, 256 picks) before a
/// window is folded from the start of the time through again.
pub const WORK_STATE_LOOKBACKS: u32 = 8;

/// A work state (see the module docs): opaque bytes for every card after pick `done` of a time
/// through (0: at its start). For the tracker's memory only: never saved or exported.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkState {
    pub done: u32,
    pub bytes: Vec<u8>,
}

/// The pattern's own words for some `?` cards of a pick, in full.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PickWords {
    /// The cards (0-based, ascending) given these words, in words: `card 3`, `cards 3 to 5`.
    pub cards: String,
    pub text: String,
}

/// One pick, as the weaver works it on one time through the band.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PickWork {
    /// The pick of the expanded band, from 1.
    pub pick: u32,
    /// Where it is written (all from 1): the segment, the written pick in it, which time through the
    /// SEGMENT this is (not the time through the band, [`WorkWindow::time`]), and how many times the
    /// segment is worked.
    pub segment: u32,
    pub step: u32,
    pub segment_repeat: u32,
    pub segment_repeats: u32,
    /// What to do, in words: the events before the pick, every card's turn (by pack or card range),
    /// any note and the pick's own weft, as the printed working instructions word one pick (a note
    /// is quoted in its first 80 characters and a `?` turn's words in their first 60 or 80).
    pub text: String,
    /// The band has cards and none of them turns.
    pub all_idle: bool,
    /// The pick's weft, or the band's.
    pub weft: Option<ColorIndex>,
    /// The pick's note in full.
    pub note: Option<PickNote>,
    /// The pattern's words for the `?` cards in full, cards with the same words together, in card
    /// order.
    pub words: Vec<PickWords>,
    /// The full note and words were left out to keep the window within [`MAX_WORK_TEXT_BYTES`]
    /// (`note` and `words` are then empty); a window starting at this pick holds them.
    pub text_left_out: bool,
    /// The prefix fingerprint at this pick on this time through (see the module docs): the same on
    /// every time through from the second on.
    pub prefix: u64,
}

/// A window of picks on one time through the band.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkWindow {
    /// The band's picks.
    pub picks: u32,
    pub cards: usize,
    /// The time through the band (from 1).
    pub time: u32,
    /// Every card before the window's first pick on this time through (its arrangement, threading
    /// and twist): how the weaver's cards should be before they work it.
    pub before: Vec<CardState>,
    pub rows: Vec<PickWork>,
    /// Every card at each pick of the window, after the pick's events and turn: pick-major, card 1
    /// first. The runs of picks a thread has floated are not counted here (`top_run` and `back_run`
    /// are `None`).
    pub cells: Vec<CardPick>,
    /// When the cards do not start this time through as they were set up: the sentence that says so.
    pub start_note: Option<String>,
    /// Work states to give back with later windows of this time through, by pick: the start of the
    /// time through (when the window had to work it out: a later time, and no usable state given),
    /// every [`WORK_STATE_LOOKBACK`] picks for [`WORK_STATE_LOOKBACKS`] stretches before the window
    /// (those it folded through), the pick before it, and its last pick.
    pub states: Vec<WorkState>,
}

impl WorkWindow {
    /// The cards of one pick of the window (from 1).
    pub fn row(&self, pick: u32) -> Option<&[CardPick]> {
        let first = self.rows.first()?.pick;
        let i = pick.checked_sub(first)? as usize;
        let start = i.checked_mul(self.cards)?;
        self.cells.get(start..start.checked_add(self.cards)?)
    }
}

/// The setup a place's fingerprint starts from: every card's threads (each hole's colour index and
/// that colour), threading and start arrangement, in card order.
fn setup(c: &Checked<'_>) -> Fingerprint {
    let band = c.band;
    let mut fp = Fingerprint::new();
    fp.number(band.cards.len() as u64);
    for (card, start) in band.cards.iter().zip(&c.starts) {
        for h in start.holes() {
            fp.number(h.index() as u64);
        }
        fp.number(match card.threading {
            ThreadingDirection::S => 0,
            ThreadingDirection::Z => 1,
        });
        for h in Hole::ALL {
            feed_color(&mut fp, band, card.threads.get(h));
        }
    }
    fp
}

/// A colour by palette index and the colour it names (or that there is none).
fn feed_color(fp: &mut Fingerprint, band: &TabletBand, color: Option<ColorIndex>) {
    match color {
        None => fp.number(0),
        Some(i) => {
            fp.number(1 + u64::from(i));
            match band.palette.get(i as usize) {
                Some(c) => fp.bytes(&[1, c.r, c.g, c.b]),
                None => fp.bytes(&[0]),
            }
        }
    }
}

/// The identity of every written pick (by segment, then written pick), hashed once: what the weaver
/// is told at it, the same every time it is worked.
fn written(c: &Checked<'_>) -> Vec<Vec<u64>> {
    let band = c.band;
    band.turning
        .segments
        .iter()
        .zip(&c.steps)
        .map(|(seg, refs)| {
            seg.picks
                .iter()
                .zip(refs)
                .map(|(spec, refs)| {
                    let mut fp = Fingerprint::new();
                    fp.text(&spec.turns);
                    match refs.as_deref() {
                        None => fp.number(0),
                        Some(r) => {
                            fp.number(1);
                            fp.number(r.words.len() as u64);
                            for (card, words) in &r.words {
                                fp.number(*card as u64);
                                fp.text(words);
                            }
                            for list in [&r.release, &r.flip] {
                                let mut cards = list.clone();
                                cards.sort_unstable();
                                cards.dedup();
                                fp.number(cards.len() as u64);
                                for i in cards {
                                    fp.number(i as u64);
                                }
                            }
                        }
                    }
                    match &spec.note {
                        None => fp.number(0),
                        Some(n) => {
                            fp.number(match n.kind {
                                NoteKind::Brocade => 1,
                                NoteKind::Other => 2,
                            });
                            fp.text(&n.text);
                        }
                    }
                    feed_color(&mut fp, band, spec.weft.or(band.weft));
                    fp.value()
                })
                .collect()
        })
        .collect()
}

/// Visit the written pick (segment, written pick, both 0-based) of every expanded pick from 1 to
/// `stop` (at most the band's picks), in order, as the fold walks them.
fn each_pick(c: &Checked<'_>, stop: u32, mut f: impl FnMut(usize, usize)) {
    let mut done = 0u32;
    for (s, seg) in c.band.turning.segments.iter().enumerate() {
        if seg.picks.is_empty() {
            continue;
        }
        for _ in 0..seg.repeat {
            for k in 0..seg.picks.len() {
                if done >= stop {
                    return;
                }
                f(s, k);
                done += 1;
            }
        }
    }
}

/// The fingerprint before pick 1 of the `time`-th time through: the setup, and from the second time
/// on every pick of the band too.
fn time_start(c: &Checked<'_>, ids: &[Vec<u64>], time: u32) -> Fingerprint {
    let mut fp = setup(c);
    if time > 1 {
        each_pick(c, c.total_picks, |s, k| fp.number(ids[s][k]));
        fp.text("then again");
    }
    fp
}

/// The prefix fingerprint at pick `pick` (from 1) of the `time`-th time through a checked band (see
/// the module docs). A pick past the end hashes the picks there are.
fn prefix_checked(c: &Checked<'_>, pick: u32, time: u32) -> u64 {
    let ids = written(c);
    let mut fp = time_start(c, &ids, time);
    each_pick(c, pick, |s, k| fp.number(ids[s][k]));
    fp.value()
}

/// The prefix fingerprint at pick `pick` (from 1) of the `time`-th time through `band` (see the
/// module docs; a time of 0 reads as 1). Refuses a band with structural errors, as simulation does.
pub fn prefix(
    band: &TabletBand,
    pick: u32,
    time: u32,
    limits: &TabletLimits,
) -> Result<u64, TabletError> {
    Ok(prefix_checked(&check(band, limits)?, pick, time))
}

/// The largest count a card may hold before a time through of the band (it moves by at most one
/// quarter turn a pick, and the fold's arithmetic is `i32`).
fn count_limit(c: &Checked<'_>) -> i64 {
    i64::from(i32::MAX) - i64::from(c.total_picks)
}

/// The counts of `sims` that could pass `i32` during a time through made unknown (never at the
/// default limits, where they stay far below it).
fn bounded(c: &Checked<'_>, mut sims: Vec<CardSim>) -> Vec<CardSim> {
    let limit = count_limit(c);
    let fits = |v: Option<i32>| v.filter(|&v| i64::from(v).abs() <= limit);
    for s in &mut sims {
        s.twist.twist = fits(s.twist.twist);
        s.twist.woven = fits(s.twist.woven);
    }
    sims
}

/// Every card after one more whole time through the band from `sims` (as a weaver who carries on
/// from where the last time through ended): the fold of every pick, with each hole's run of picks in
/// one layer started again.
fn once_through(c: &Checked<'_>, sims: Vec<CardSim>) -> Vec<CardSim> {
    let mut fold = Fold::resume(c, bounded(c, sims), Place::default());
    fold.advance(c.total_picks, &mut NoObserver);
    let mut sims = fold.sims;
    for s in &mut sims {
        s.runs = [None; 4];
    }
    sims
}

/// `v + n * d`, when it is known and stays within `limit` either way (a twist past it could not be
/// counted on through a time through of the band, so it is unknown).
fn extend(v: Option<i32>, d: Option<i64>, n: u64, limit: i64) -> Option<i32> {
    let total = i128::from(v?) + i128::from(d?) * i128::from(n);
    if total.abs() > i128::from(limit) {
        return None;
    }
    i32::try_from(total).ok()
}

/// Every card at the start of time `time` through the band (from 1): as set up for time 1, then
/// where the time before ended. Exact folds for times 1 to 5; from time 6 on, the arrangement,
/// threading, last crossing and twining of time `t' = 2 + (time - 2) % 4` and the twist and woven
/// counts moved on by the same change every four times through (see the module docs): twice the
/// change over times 1 and 2, or none for the twist of a card the band releases (its twist then
/// starts every later time through the same). At most four folds of the band, and two or three for
/// most times. From time 2 on, a count too large to carry through another time through is unknown.
fn start_of(c: &Checked<'_>, time: u32) -> Vec<CardSim> {
    let first = Fold::new(c).sims;
    if time <= 1 {
        return first;
    }
    let same = if time <= 5 { time } else { 2 + (time - 2) % 4 }; // 2..=5
                                                                  // starts[k] is the start of time k + 1; time 3 is needed for the change over four times.
    let need = if time <= 5 { time } else { same.max(3) };
    let mut starts = vec![first];
    while (starts.len() as u32) < need {
        let next = once_through(c, starts.last().cloned().unwrap_or_default());
        starts.push(next);
    }
    let at = |t: u32| &starts[(t - 1) as usize];
    let mut out = at(same).clone();
    if time > 5 {
        let limit = count_limit(c);
        let fours = u64::from((time - same) / 4);
        let mut released = vec![false; c.band.cards.len()];
        for refs in c.steps.iter().flatten().flatten() {
            for &i in &refs.release {
                if let Some(r) = released.get_mut(i) {
                    *r = true;
                }
            }
        }
        // The change over four times through: twice the change over times 1 and 2 (from the
        // start, where both counts are 0, to the start of time 3).
        let step = |a: Option<i32>, b: Option<i32>| Some(2 * (i64::from(b?) - i64::from(a?)));
        for (i, card) in out.iter_mut().enumerate() {
            let (one, three) = (&at(1)[i].twist, &at(3)[i].twist);
            let twist = if released[i] {
                Some(0)
            } else {
                step(one.twist, three.twist)
            };
            card.twist.twist = extend(card.twist.twist, twist, fours, limit);
            card.twist.woven = extend(card.twist.woven, step(one.woven, three.woven), fours, limit);
        }
    }
    bounded(c, out)
}

/// Whether each card starts as it was set up (its arrangement and threading).
fn as_set_up(c: &Checked<'_>, sims: &[CardSim]) -> bool {
    sims.iter()
        .zip(c.band.cards.iter().zip(&c.starts))
        .all(|(s, (card, &start))| s.position == Some(start) && s.threading == Some(card.threading))
}

/// The cards before the first pick of a window, and every pick of it, as the fold works them.
struct WorkObserver<'c, 'a> {
    c: &'c Checked<'a>,
    packs: Vec<Option<Vec<usize>>>,
    ids: Vec<Vec<u64>>,
    /// Each written pick's [`word_ids`], worked out the first time the window meets it.
    words: HashMap<(usize, usize), Vec<u32>>,
    fp: Fingerprint,
    first: u32,
    /// Each card's threading before the pick being worked (from the pick before `first` on).
    threading: Vec<Option<ThreadingDirection>>,
    before: Vec<CardState>,
    rows: Vec<PickWork>,
    cells: Vec<CardPick>,
    /// Bytes of full notes and words the window may still hold.
    text_budget: usize,
}

impl WorkObserver<'_, '_> {
    /// The full note and the `?` cards' full words of a pick, grouped by words, when they fit the
    /// window's budget (always for the window's first pick).
    fn full_text(
        &mut self,
        ctx: &PickContext<'_>,
        ids: &[u32],
    ) -> (Option<PickNote>, Vec<PickWords>, bool) {
        let mut groups: Vec<(u32, Vec<usize>, &str)> = Vec::new();
        if let Some(refs) = ctx.refs {
            for &(card, text) in &refs.words {
                let id = ids.get(card).copied().unwrap_or(0);
                match groups.iter_mut().find(|(g, _, _)| *g == id) {
                    Some((_, cards, _)) => cards.push(card),
                    None => groups.push((id, vec![card], text)),
                }
            }
        }
        let note = ctx.spec.note.as_ref();
        let size = note.map_or(0, |n| n.text.len())
            + groups.iter().map(|(_, _, t)| t.len()).sum::<usize>();
        if size == 0 {
            return (None, Vec::new(), false);
        }
        if !self.rows.is_empty() && size > self.text_budget {
            return (None, Vec::new(), true);
        }
        self.text_budget = self.text_budget.saturating_sub(size);
        let words = groups
            .into_iter()
            .map(|(_, mut cards, text)| {
                cards.sort_unstable();
                PickWords {
                    cards: cards_text(&cards),
                    text: text.to_string(),
                }
            })
            .collect();
        (note.cloned(), words, false)
    }
}

impl Observer for WorkObserver<'_, '_> {
    fn pick(&mut self, ctx: &PickContext<'_>, row: &[CardPick]) {
        self.fp.number(self.ids[ctx.segment][ctx.step]);
        if ctx.pick.saturating_add(1) < self.first {
            return;
        }
        if ctx.pick >= self.first {
            let band = self.c.band;
            let seg = &band.turning.segments[ctx.segment];
            let n = |i: usize| u32::try_from(i + 1).unwrap_or(u32::MAX);
            let cards = band.cards.len();
            let ids = self
                .words
                .entry((ctx.segment, ctx.step))
                .or_insert_with(|| word_ids(ctx.refs, cards))
                .clone();
            let (note, words, text_left_out) = self.full_text(ctx, &ids);
            self.rows.push(PickWork {
                pick: ctx.pick,
                segment: n(ctx.segment),
                step: n(ctx.step),
                segment_repeat: ctx.repeat.saturating_add(1),
                segment_repeats: seg.repeat,
                text: pick_text(band, &self.packs, ctx, &self.threading, &ids, false),
                all_idle: !row.is_empty() && row.iter().all(|c| c.turn == Turn::Idle),
                weft: ctx.spec.weft.or(band.weft),
                note,
                words,
                text_left_out,
                prefix: self.fp.value(),
            });
            self.cells.extend(row.iter().map(|c| CardPick {
                top_run: None,
                back_run: None,
                ..*c
            }));
        } else {
            // The pick just before the window: how the cards are when the weaver comes to it.
            self.before = row
                .iter()
                .map(|c| CardState {
                    position: c.position,
                    threading: c.threading,
                    twist: c.twist,
                })
                .collect();
        }
        for (t, c) in self.threading.iter_mut().zip(row) {
            *t = c.threading;
        }
    }
}

/// The sentence for a time through on which the cards do not start as set up.
fn start_note(time: u32) -> String {
    format!(
        "On time {time} through the band your cards do not start as they were set up: they start \
         where time {} ended, so what they show here differs from the band chart.",
        time - 1
    )
}

/// Picks `first..=last` (numbered from 1) of the `time`-th time through the band (from 1), as the
/// weaver works them: what to do at each, every card before the first and at each pick, and each
/// pick's fingerprint. At most [`MAX_WORK_WINDOW`] picks and [`MAX_WORK_CELLS`] cells (`last` is cut
/// to them and to the band's end), and `first` is always returned. The time through changes the
/// cards (they start where the time before ended) and the words of a flip. `from` is a work state an
/// earlier window of this time through gave ([`WorkWindow::states`], best the latest before
/// `first`); one before `first` that this run sealed for this band and time through is resumed from,
/// anything else is ignored, with the same result. A band with no picks gives an empty window for a
/// `first` of 1. Refuses a band with structural errors, a time of 0, and a `first` outside the band
/// or after `last`. Never panics.
pub fn window(
    band: &TabletBand,
    first: u32,
    last: u32,
    time: u32,
    from: Option<&[u8]>,
    limits: &TabletLimits,
) -> Result<WorkWindow, TabletError> {
    let c = check(band, limits)?;
    let picks = c.total_picks;
    let cards = band.cards.len();
    if time == 0 {
        return Err(TabletError::InvalidTime);
    }
    let fingerprint = band_fingerprint(band);
    if picks == 0 && first == 1 {
        let start = Fold::new(&c);
        return Ok(WorkWindow {
            picks,
            cards,
            time,
            before: start.sims.iter().map(CardSim::state).collect(),
            rows: Vec::new(),
            cells: Vec::new(),
            start_note: None,
            states: vec![WorkState {
                done: 0,
                bytes: encode_state(fingerprint, time, false, start.place, &start.sims),
            }],
        });
    }
    if first == 0 || first > picks || last < first {
        return Err(TabletError::InvalidWindow { first, last, picks });
    }
    let fit = u32::try_from(MAX_WORK_CELLS / cards.max(1))
        .unwrap_or(u32::MAX)
        .max(1);
    let last = last
        .min(picks)
        .min(first.saturating_add(MAX_WORK_WINDOW - 1))
        .min(first.saturating_add(fit - 1));
    let limit = u64::try_from(count_limit(&c)).unwrap_or(0);
    // A state the app kept for this band and time through, at or before the pick before the
    // window: resume from it. Otherwise work out where the time through starts.
    let resumed = from
        .and_then(|b| decode_state(b, band, fingerprint, time, picks, limit).ok())
        .filter(|s| s.place.done < first);
    let mut states = Vec::with_capacity(4);
    let (moved, mut fold) = match resumed {
        Some(s) => (s.moved, Fold::resume(&c, s.cards, s.place)),
        None => {
            let start = start_of(&c, time);
            let moved = time > 1 && !as_set_up(&c, &start);
            if time > 1 {
                states.push(WorkState {
                    done: 0,
                    bytes: encode_state(fingerprint, time, moved, Place::default(), &start),
                });
            }
            (moved, Fold::resume(&c, start, Place::default()))
        }
    };
    let from_done = fold.place.done;
    let state_at = |fold: &Fold<'_, '_>| WorkState {
        done: fold.place.done,
        bytes: encode_state(fingerprint, time, moved, fold.place, &fold.sims),
    };
    let rows = (last - first + 1) as usize;
    let ids = written(&c);
    // The picks before the window are folded without keeping anything (the fastest fold) up to the
    // one before the window, which the observer sees: how the cards are when the weaver comes to
    // the window, and their threading for the words of a flip. The fingerprint is fed for them
    // from the written picks alone.
    let quiet = first.saturating_sub(2);
    let mut fp = time_start(&c, &ids, time);
    each_pick(&c, quiet.max(from_done), |s, k| fp.number(ids[s][k]));
    for k in (1..=WORK_STATE_LOOKBACKS).rev() {
        let at = first.saturating_sub(1 + WORK_STATE_LOOKBACK * k);
        if at > fold.place.done {
            fold.advance(at, &mut NoObserver);
            states.push(state_at(&fold));
        }
    }
    fold.advance(quiet, &mut NoObserver);
    let mut obs = WorkObserver {
        c: &c,
        packs: usable_packs(band),
        ids,
        words: HashMap::new(),
        fp,
        first,
        threading: fold.sims.iter().map(|s| s.threading).collect(),
        before: fold.sims.iter().map(CardSim::state).collect(),
        rows: Vec::with_capacity(rows),
        cells: Vec::with_capacity(rows.saturating_mul(cards)),
        text_budget: MAX_WORK_TEXT_BYTES,
    };
    if first - 1 > from_done {
        fold.advance(first - 1, &mut obs);
        states.push(state_at(&fold));
    }
    fold.advance(last, &mut obs);
    states.push(state_at(&fold));
    Ok(WorkWindow {
        picks,
        cards,
        time,
        before: obs.before,
        rows: obs.rows,
        cells: obs.cells,
        start_note: moved.then(|| start_note(time)),
        states,
    })
}

/// Where a weaver resumes: how their saved place compares, the pick to show (from 1), and the
/// sentence to show with it (`None` when there is nothing to say).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PickResume {
    pub resume: Resume,
    pub pick: u32,
    pub picks: u32,
    pub message: Option<String>,
}

/// Compare a saved place (`pick` of the `time`-th time through, both numbered from 1, with its
/// `basis`) with the band as it is now. A pick or time of 0 reads as 1. On a later time through the
/// whole band is before the place, so any change to it (picks added at the end too) shows the place
/// for checking. Never moves the place: see [`ply_common::progress::reconcile`]. Refuses a band with
/// structural errors (nothing can be shown for it).
pub fn resume(
    band: &TabletBand,
    pick: u32,
    time: u32,
    basis: Option<Basis>,
    limits: &TabletLimits,
) -> Result<PickResume, TabletError> {
    let c = check(band, limits)?;
    let picks = c.total_picks;
    let saved = pick.max(1) - 1;
    let time = time.max(1);
    let r = reconcile(
        u64::from(saved),
        basis,
        u64::from(picks),
        |u| prefix_checked(&c, u32::try_from(u + 1).unwrap_or(u32::MAX), time),
        || None,
    );
    let shown = u32::try_from(r.unit + 1).unwrap_or(u32::MAX);
    let message = match r.status {
        ResumeStatus::Same => None,
        ResumeStatus::LengthChanged { was } => Some(format!(
            "The band has changed after your place: it now has {picks} picks (it had {was}). Your \
             place is unchanged."
        )),
        ResumeStatus::Changed if time > 1 => Some(format!(
            "The band has changed since you saved your place, and on time {time} through all of \
             it was woven before your place. Check that pick {shown} is where you are and that \
             your cards are as shown."
        )),
        ResumeStatus::Changed => Some(format!(
            "The band has changed at or before pick {shown} since you saved your place. Check that \
             pick {shown} is where you are and that your cards are as shown."
        )),
        ResumeStatus::Clamped { was } => Some(format!(
            "Your place was pick {}, but the band now has {picks} picks. It is shown at pick \
             {shown}: check where you are.",
            was + 1
        )),
        ResumeStatus::Empty => Some("This band has no picks to weave.".to_string()),
    };
    Ok(PickResume {
        resume: r,
        pick: if r.status == ResumeStatus::Empty {
            1
        } else {
            shown
        },
        picks,
        message,
    })
}

#[cfg(test)]
mod tests;
