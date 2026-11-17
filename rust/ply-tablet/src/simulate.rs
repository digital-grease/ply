//! The card-turn state machine (ADR 0018 sections 4 to 7): the state after pick n is a fold of the
//! rules over picks 1 to n, the same on every platform.
//!
//! Each pick, for each card, in this order: a recorded twist release, then a flip, then the turn.
//!
//! * **Turn.** Forward moves every hole one corner on (NT to FT to FB to NB); backward the reverse.
//!   The thread whose hole travelled along the top edge is the top-face thread for the pick, the one
//!   along the bottom edge the back thread (the published crossing rule).
//! * **Twining and twist.** An S card forward or a Z card backward weaves a Z quarter (+1); an S card
//!   backward or a Z card forward an S quarter (-1). `twist` sums them since the start or the last
//!   recorded release, `woven` since the start; neither is ever reset by a reversal or a flip.
//! * **Reversal.** A turned pick whose twining differs from the card's previous turned pick.
//! * **Idle.** Nothing crosses: the last top and back threads carry on as longer floats, or, if the
//!   card has not turned since the start or its last flip, the face is ambiguous (both threads of
//!   the layer are reported, never guessed).
//! * **Flip.** NT and FT swap, NB and FB swap, S becomes Z and Z becomes S; twist is unchanged.
//! * **Unsupported (`?`).** The card's state is unknown from here (sections 4 and 10): its
//!   arrangement, faces, threading (so the twining of later turns too) and twist. Nothing makes the
//!   arrangement or threading known again; a recorded release sets `twist` to 0 until the next turn
//!   (whose twining is unknown); `woven` stays unknown.
//!
//! Memory is O(cards) plus the requested window; time is O(cards times the last pick simulated):
//! every card id was resolved to an index when the band was checked, so a pick never looks at one.

use crate::band::{BandSettings, ColorIndex, HoleThreads, NoteKind, TabletBand, TabletLimits};
use crate::card::{CardPosition, Face, Hole, Position, ThreadingDirection, Turn, Twining};
use crate::diagnostic::{
    count, excerpt, CardSet, Collector, Diagnostic, RunEnd, TabletCode, TabletLocation,
    MAX_LOCATION_CARDS,
};
use crate::error::TabletError;
use crate::validate::{check, Checked, StepRefs};
use serde::Serialize;
use std::ops::RangeInclusive;

/// What one face of one card shows at one pick.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize)]
#[serde(rename_all = "snake_case", tag = "kind", content = "holes")]
pub enum FaceThread {
    /// The thread in this hole crossed the edge in this pick's turn.
    Thread(Hole),
    /// The card idled: the thread that last crossed carries on as a longer float.
    Continued(Hole),
    /// The card idled without having turned since the start of the band or its last flip: either of
    /// the two threads of the layer may show (top: the holes at NT then FT; back: FB then NB).
    Ambiguous(Hole, Hole),
    /// The hole that crossed (or carries on) has no thread: the face there is not modelled.
    Empty(Hole),
    /// After an action Ply does not model, the card's arrangement is unknown.
    Unknown,
}

impl FaceThread {
    /// The single hole this face shows, when there is one.
    pub fn hole(self) -> Option<Hole> {
        match self {
            FaceThread::Thread(h) | FaceThread::Continued(h) | FaceThread::Empty(h) => Some(h),
            FaceThread::Ambiguous(..) | FaceThread::Unknown => None,
        }
    }
}

/// A card's twist ledger in quarter turns, Z (right-handed) positive. `None` is unknown (after an
/// action Ply does not model).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize)]
pub struct TwistState {
    /// Net twining woven since the start of the band or the card's last recorded release. The unwoven
    /// warp behind the card holds the same amount of twist of the opposite hand.
    pub twist: Option<i32>,
    /// Net twining woven since the start of the band; never reset.
    pub woven: Option<i32>,
}

impl TwistState {
    pub const ZERO: TwistState = TwistState {
        twist: Some(0),
        woven: Some(0),
    };
}

/// One card at one pick, after the pick's events and turn.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize)]
pub struct CardPick {
    pub turn: Turn,
    /// The weaver released this card's twist before the pick.
    pub released: bool,
    /// The card was flipped before the pick.
    pub flipped: bool,
    /// The arrangement after the turn; `None` once unknown.
    pub position: Option<CardPosition>,
    /// The threading after any flip; `None` once unknown.
    pub threading: Option<ThreadingDirection>,
    pub top: FaceThread,
    pub back: FaceThread,
    /// The twining woven this pick (`None` for an idle, for an action Ply does not model, and for a
    /// turn of a card whose threading is unknown).
    pub twining: Option<Twining>,
    /// This pick's twining differs from the card's previous turned pick.
    pub reversal: bool,
    pub twist: TwistState,
    /// How many consecutive picks, up to and including this one, the top-face thread has spent in
    /// the upper layer (`None` unless the top face is one known, threaded hole).
    pub top_run: Option<u32>,
    /// The same for the back thread in the lower layer.
    pub back_run: Option<u32>,
}

/// One card's state between picks.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize)]
pub struct CardState {
    /// `None` once unknown.
    pub position: Option<CardPosition>,
    /// `None` once unknown.
    pub threading: Option<ThreadingDirection>,
    pub twist: TwistState,
}

/// The whole band after `pick` picks (0 = as set up): for resuming work and print checks.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize)]
pub struct BandState {
    pub pick: u32,
    pub cards: Vec<CardState>,
}

/// Where a pick comes from in the written turning, and what is recorded with it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize)]
pub struct PickInfo {
    /// 1-based expanded pick number.
    pub pick: u32,
    /// 1-based segment.
    pub segment: u32,
    /// 1-based pick within the segment, as written.
    pub step: u32,
    /// Which time through the segment (1-based).
    pub repeat: u32,
    /// The band has cards and none of them turns (the weft lies in the same shed as the pick
    /// before).
    pub all_idle: bool,
    pub note: Option<NoteKind>,
    /// The pick's weft, or the band's (recorded, not drawn in v1).
    pub weft: Option<ColorIndex>,
}

/// Simulated rows for a range of picks. A band with no picks gives an empty window (`first_pick`
/// 1, `last_pick` 0, no rows).
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize)]
pub struct TabletWindow {
    /// The first and last pick of the window (1-based, inclusive).
    pub first_pick: u32,
    pub last_pick: u32,
    /// Cards per row.
    pub cards: usize,
    /// One per pick, `first_pick` first.
    pub rows: Vec<PickInfo>,
    /// Pick-major: the cards of `first_pick` (card 1 first), then of the next pick, and so on.
    pub cells: Vec<CardPick>,
}

/// The colour a face cell shows.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize)]
#[serde(rename_all = "snake_case", tag = "kind", content = "colors")]
pub enum FaceColor {
    /// One thread's colour (crossed or carrying on).
    One(ColorIndex),
    /// Either of two colours (an ambiguous idle); `None` for an empty hole.
    Either(Option<ColorIndex>, Option<ColorIndex>),
    /// An empty hole: not modelled.
    NotModelled,
    /// After an action Ply does not model.
    Unknown,
}

/// One cell of a face, in display order.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize)]
pub struct FaceCell {
    /// 0-based card index (card 1 is 0).
    pub card: usize,
    pub thread: FaceThread,
    pub color: FaceColor,
    /// The stitch slant: `/` for Z twining, `\` for S, on both faces.
    pub twining: Option<Twining>,
    pub reversal: bool,
}

/// The colour a card's face shows.
pub fn face_color(band: &TabletBand, card: usize, thread: FaceThread) -> FaceColor {
    let color = |h: Hole| band.thread_color(card, h);
    match thread {
        FaceThread::Thread(h) | FaceThread::Continued(h) => match color(h) {
            Some(c) => FaceColor::One(c),
            None => FaceColor::NotModelled,
        },
        FaceThread::Ambiguous(a, b) => FaceColor::Either(color(a), color(b)),
        FaceThread::Empty(_) => FaceColor::NotModelled,
        FaceThread::Unknown => FaceColor::Unknown,
    }
}

impl TabletWindow {
    /// Picks in the window.
    pub fn picks(&self) -> u32 {
        self.last_pick
            .checked_sub(self.first_pick)
            .map_or(0, |d| d.saturating_add(1))
    }

    /// The cards of one pick (1-based pick number), card 1 first.
    pub fn row(&self, pick: u32) -> Option<&[CardPick]> {
        if pick < self.first_pick || pick > self.last_pick {
            return None;
        }
        let start = ((pick - self.first_pick) as usize).checked_mul(self.cards)?;
        self.cells.get(start..start.checked_add(self.cards)?)
    }

    /// One card (0-based index) at one pick (1-based).
    pub fn card_pick(&self, pick: u32, card: usize) -> Option<&CardPick> {
        self.row(pick).and_then(|r| r.get(card))
    }

    pub fn info(&self, pick: u32) -> Option<&PickInfo> {
        if pick < self.first_pick {
            return None;
        }
        self.rows.get((pick - self.first_pick) as usize)
    }

    /// One pick of a face as drawn (ADR 0018 section 8): the top face with card 1 at the left, the
    /// back (turned over sideways) with card 1 at the right.
    pub fn face_row(&self, band: &TabletBand, pick: u32, face: Face) -> Option<Vec<FaceCell>> {
        let row = self.row(pick)?;
        Some(
            face.display_order(row.len())
                .map(|card| {
                    let cp = &row[card];
                    let thread = match face {
                        Face::Top => cp.top,
                        Face::Back => cp.back,
                    };
                    FaceCell {
                        card,
                        thread,
                        color: face_color(band, card, thread),
                        twining: cp.twining,
                        reversal: cp.reversal,
                    }
                })
                .collect(),
        )
    }
}

/// Simulate a window of picks (1-based, inclusive): every card's state and faces at each pick.
/// Refuses a band with structural errors (listing them all), a window outside the band, and a window
/// of more than `limits.max_window_cells` cells, before allocating it.
pub fn try_simulate(
    band: &TabletBand,
    picks: RangeInclusive<u32>,
    limits: &TabletLimits,
) -> Result<TabletWindow, TabletError> {
    let checked = check(band, limits)?;
    simulate_window(&checked, *picks.start(), *picks.end(), limits)
}

fn simulate_window(
    checked: &Checked<'_>,
    first: u32,
    last: u32,
    limits: &TabletLimits,
) -> Result<TabletWindow, TabletError> {
    simulate_window_from(checked, None, first, last, limits)
}

/// A window folded from `from` (a checkpoint's cards and place, which must lie before `first`) or,
/// without one, from pick 1. The window is checked and allocated before any pick is worked.
pub(crate) fn simulate_window_from(
    checked: &Checked<'_>,
    from: Option<(Vec<CardSim>, Place)>,
    first: u32,
    last: u32,
    limits: &TabletLimits,
) -> Result<TabletWindow, TabletError> {
    let total = checked.total_picks;
    if first == 0 || first > last || last > total {
        return Err(TabletError::InvalidWindow {
            first,
            last,
            picks: total,
        });
    }
    let cards = checked.band.cards.len();
    let rows = last - first + 1;
    let cells = cards
        .checked_mul(rows as usize)
        .ok_or(TabletError::WindowTooLarge {
            cards,
            picks: rows,
            cells: usize::MAX,
            limit: limits.max_window_cells,
        })?;
    if cells > limits.max_window_cells {
        return Err(TabletError::WindowTooLarge {
            cards,
            picks: rows,
            cells,
            limit: limits.max_window_cells,
        });
    }
    let mut window = WindowObserver {
        first,
        band_weft: checked.band.weft,
        rows: try_vec(rows as usize)?,
        cells: try_vec(cells)?,
    };
    let mut fold = match from {
        Some((sims, place)) if place.done < first => Fold::resume(checked, sims, place),
        _ => Fold::new(checked),
    };
    fold.advance(last, &mut window);
    Ok(TabletWindow {
        first_pick: first,
        last_pick: last,
        cards,
        rows: window.rows,
        cells: window.cells,
    })
}

/// Simulate every pick of the band (within the window limit). A band with no picks gives an empty
/// window.
pub fn try_simulate_all(
    band: &TabletBand,
    limits: &TabletLimits,
) -> Result<TabletWindow, TabletError> {
    let checked = check(band, limits)?;
    if checked.total_picks == 0 {
        return Ok(TabletWindow {
            first_pick: 1,
            last_pick: 0,
            cards: band.cards.len(),
            rows: Vec::new(),
            cells: Vec::new(),
        });
    }
    simulate_window(&checked, 1, checked.total_picks, limits)
}

/// The band's state after `pick` picks (0 = as set up), without keeping any rows.
pub fn state_after(
    band: &TabletBand,
    pick: u32,
    limits: &TabletLimits,
) -> Result<BandState, TabletError> {
    let checked = check(band, limits)?;
    if pick > checked.total_picks {
        return Err(TabletError::PickOutOfRange {
            pick,
            picks: checked.total_picks,
        });
    }
    let sims = simulate_with(&checked, pick, &mut NoObserver);
    Ok(BandState {
        pick,
        cards: sims.iter().map(|s| s.state()).collect(),
    })
}

/// An empty `Vec` with room for exactly `n` items, or [`TabletError::AllocFailed`] when the
/// allocator says no.
fn try_vec<T>(n: usize) -> Result<Vec<T>, TabletError> {
    let mut v = Vec::new();
    v.try_reserve_exact(n)
        .map_err(|_| TabletError::AllocFailed {
            bytes: n.saturating_mul(std::mem::size_of::<T>()),
        })?;
    Ok(v)
}

/// A run of consecutive picks a thread spent in one layer.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct ClosedRun {
    pub card: usize,
    pub hole: Hole,
    pub upper: bool,
    pub first: u32,
    pub last: u32,
    pub end: RunEnd,
}

/// Where a pick sits in the written turning, and its resolved events and words.
pub(crate) struct PickContext<'a> {
    pub pick: u32,
    pub segment: usize,
    pub step: usize,
    pub repeat: u32,
    pub spec: &'a crate::band::PickSpec,
    pub refs: Option<&'a StepRefs<'a>>,
}

pub(crate) trait Observer {
    /// Whether the observer looks at rows and runs at all (a bare fold to a state does not, and
    /// skips that bookkeeping).
    const DETAIL: bool = true;
    fn pick(&mut self, _ctx: &PickContext<'_>, _row: &[CardPick]) {}
    fn run_closed(&mut self, _run: ClosedRun) {}
}

pub(crate) struct NoObserver;
impl Observer for NoObserver {
    const DETAIL: bool = false;
}

struct WindowObserver {
    first: u32,
    band_weft: Option<ColorIndex>,
    rows: Vec<PickInfo>,
    cells: Vec<CardPick>,
}

/// Every card idles, and there is at least one card.
fn all_idle(row: &[CardPick]) -> bool {
    !row.is_empty() && row.iter().all(|c| c.turn == Turn::Idle)
}

fn pick_info(ctx: &PickContext<'_>, row: &[CardPick], band_weft: Option<ColorIndex>) -> PickInfo {
    let n = |i: usize| u32::try_from(i + 1).unwrap_or(u32::MAX);
    PickInfo {
        pick: ctx.pick,
        segment: n(ctx.segment),
        step: n(ctx.step),
        repeat: ctx.repeat.saturating_add(1),
        all_idle: all_idle(row),
        note: ctx.spec.note.as_ref().map(|n| n.kind),
        weft: ctx.spec.weft.or(band_weft),
    }
}

impl Observer for WindowObserver {
    fn pick(&mut self, ctx: &PickContext<'_>, row: &[CardPick]) {
        if ctx.pick >= self.first {
            self.rows.push(pick_info(ctx, row, self.band_weft));
            self.cells.extend_from_slice(row);
        }
    }
}

/// The picks a hole has spent in one layer so far: since `start` (1-based), in the upper layer or
/// the lower.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub(crate) struct Run {
    pub upper: bool,
    pub start: u32,
}

/// One card during simulation: everything a later pick depends on (ADR 0018 M10-01 amendment 10
/// lists it), so a checkpoint is a copy of these.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub(crate) struct CardSim {
    pub position: Option<CardPosition>,
    pub threading: Option<ThreadingDirection>,
    pub twist: TwistState,
    /// The holes that crossed the top and the bottom in the latest turn; `None` before the first
    /// turn, after a flip, or once unknown.
    pub last_crossed: Option<(Hole, Hole)>,
    /// The twining of the latest turned pick; `None` before the first turn or once unknown.
    pub last_twining: Option<Twining>,
    /// The current run of each hole (by hole), while the position is known.
    pub runs: [Option<Run>; 4],
}

fn face_of(threads: &HoleThreads, hole: Hole, continued: bool) -> FaceThread {
    match threads.get(hole) {
        None => FaceThread::Empty(hole),
        Some(_) if continued => FaceThread::Continued(hole),
        Some(_) => FaceThread::Thread(hole),
    }
}

/// One quarter turn of twining added to a ledger. The magnitude never passes the pick count, which
/// `TabletLimits::unsound` keeps within `i32`, so an overflow is a broken invariant: it fails loudly
/// rather than giving a wrong count.
fn add_quarter(v: Option<i32>, q: i32) -> Option<i32> {
    v.map(|v| {
        v.checked_add(q)
            .expect("twist is bounded by max_picks, which is checked to fit i32")
    })
}

impl CardSim {
    fn new(start: CardPosition, threading: ThreadingDirection) -> CardSim {
        CardSim {
            position: Some(start),
            threading: Some(threading),
            twist: TwistState::ZERO,
            last_crossed: None,
            last_twining: None,
            runs: [None; 4],
        }
    }

    pub(crate) fn state(&self) -> CardState {
        CardState {
            position: self.position,
            threading: self.threading,
            twist: self.twist,
        }
    }

    fn close_runs<O: Observer>(&mut self, card: usize, last: u32, end: RunEnd, obs: &mut O) {
        for h in Hole::ALL {
            if let Some(r) = self.runs[h.index()].take() {
                obs.run_closed(ClosedRun {
                    card,
                    hole: h,
                    upper: r.upper,
                    first: r.start,
                    last,
                    end,
                });
            }
        }
    }

    /// One pick for this card: release, flip, turn, then the faces, ledger and runs.
    #[allow(clippy::too_many_arguments)]
    fn step<O: Observer>(
        &mut self,
        threads: &HoleThreads,
        turn: Turn,
        released: bool,
        flipped: bool,
        pick: u32,
        card: usize,
        obs: &mut O,
    ) -> CardPick {
        if released {
            self.twist.twist = Some(0);
        }
        if flipped {
            self.position = self.position.map(CardPosition::flipped);
            self.threading = self.threading.map(ThreadingDirection::flipped);
            // Until the card turns again, an idle cannot say which upper thread shows.
            self.last_crossed = None;
        }
        let mut twining = None;
        let mut reversal = false;
        let (top, back) = match turn {
            Turn::Forward | Turn::Backward => {
                let forward = turn == Turn::Forward;
                match self.threading.map(|t| Twining::of(t, forward)) {
                    Some(t) => {
                        twining = Some(t);
                        reversal = self.last_twining.is_some_and(|prev| prev != t);
                        self.last_twining = Some(t);
                        self.twist.twist = add_quarter(self.twist.twist, t.quarters());
                        self.twist.woven = add_quarter(self.twist.woven, t.quarters());
                    }
                    None => {
                        // A turn of unknown twining: the count is unknown again.
                        self.twist.twist = None;
                        self.twist.woven = None;
                    }
                }
                match self.position {
                    Some(p) => {
                        let (over, under) = p.crossing(forward);
                        self.position = Some(if forward { p.forward() } else { p.backward() });
                        self.last_crossed = Some((over, under));
                        (
                            face_of(threads, over, false),
                            face_of(threads, under, false),
                        )
                    }
                    None => (FaceThread::Unknown, FaceThread::Unknown),
                }
            }
            Turn::Idle => match (self.position, self.last_crossed) {
                (None, _) => (FaceThread::Unknown, FaceThread::Unknown),
                (Some(_), Some((over, under))) => {
                    (face_of(threads, over, true), face_of(threads, under, true))
                }
                (Some(p), None) => (
                    FaceThread::Ambiguous(
                        p.hole_at(Position::NearTop),
                        p.hole_at(Position::FarTop),
                    ),
                    FaceThread::Ambiguous(
                        p.hole_at(Position::FarBottom),
                        p.hole_at(Position::NearBottom),
                    ),
                ),
            },
            Turn::Unsupported => {
                self.position = None;
                self.threading = None;
                self.twist = TwistState {
                    twist: None,
                    woven: None,
                };
                self.last_crossed = None;
                self.last_twining = None;
                (FaceThread::Unknown, FaceThread::Unknown)
            }
        };

        if !O::DETAIL {
            return CardPick {
                turn,
                released,
                flipped,
                position: self.position,
                threading: self.threading,
                top,
                back,
                twining,
                reversal,
                twist: self.twist,
                top_run: None,
                back_run: None,
            };
        }
        // Runs: which layer each threaded hole is in after the turn. A flip keeps the upper holes
        // upper, so a run carries on through it.
        match self.position {
            Some(p) => {
                let [nt, ft, _, _] = p.holes();
                for h in Hole::ALL {
                    if threads.get(h).is_none() {
                        continue; // an empty hole has no thread to float
                    }
                    let upper = h == nt || h == ft;
                    let slot = &mut self.runs[h.index()];
                    match *slot {
                        Some(r) if r.upper == upper => {}
                        Some(r) => {
                            obs.run_closed(ClosedRun {
                                card,
                                hole: h,
                                upper: r.upper,
                                first: r.start,
                                last: pick.saturating_sub(1),
                                end: RunEnd::Ended,
                            });
                            *slot = Some(Run { upper, start: pick });
                        }
                        None => *slot = Some(Run { upper, start: pick }),
                    }
                }
            }
            None => self.close_runs(card, pick.saturating_sub(1), RunEnd::StateUnknown, obs),
        }
        let run_of = |face: FaceThread, upper: bool| -> Option<u32> {
            match face {
                FaceThread::Thread(h) | FaceThread::Continued(h) => self.runs[h.index()]
                    .filter(|r| r.upper == upper)
                    .map(|r| pick - r.start + 1),
                _ => None,
            }
        };
        CardPick {
            turn,
            released,
            flipped,
            position: self.position,
            threading: self.threading,
            top,
            back,
            twining,
            reversal,
            twist: self.twist,
            top_run: run_of(top, true),
            back_run: run_of(back, false),
        }
    }
}

/// Where a fold stands in the written turning: the next pick to work is pick `done + 1`, which is
/// written pick `step` of segment `segment`, in that segment's repeat `repeat` (all 0-based). Once
/// every pick is done, `segment` is the number of segments (and `repeat` and `step` are 0).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub(crate) struct Place {
    pub segment: usize,
    pub repeat: u32,
    pub step: usize,
    pub done: u32,
}

/// The rules folded over the picks of a checked band, from the start or from a checkpoint
/// ([`crate::checkpoint`]), one pick at a time. Holds only O(cards) state.
pub(crate) struct Fold<'c, 'a> {
    c: &'c Checked<'a>,
    pub sims: Vec<CardSim>,
    pub place: Place,
    row: Vec<CardPick>,
    release: Vec<bool>,
    flip: Vec<bool>,
    /// The runs still open at the band's end have been reported (once).
    closed: bool,
}

impl<'c, 'a> Fold<'c, 'a> {
    /// Every card as set up, before pick 1.
    pub fn new(c: &'c Checked<'a>) -> Fold<'c, 'a> {
        let sims = c
            .band
            .cards
            .iter()
            .zip(&c.starts)
            .map(|(card, &start)| CardSim::new(start, card.threading))
            .collect();
        Fold::resume(c, sims, Place::default())
    }

    /// Carry on from `sims` at `place` (a checkpoint's state: one sim per card, and the place of the
    /// next pick, as [`Fold::advance`] left them).
    pub fn resume(c: &'c Checked<'a>, sims: Vec<CardSim>, place: Place) -> Fold<'c, 'a> {
        let n = c.band.cards.len();
        let mut fold = Fold {
            c,
            sims,
            place,
            row: Vec::with_capacity(n),
            release: vec![false; n],
            flip: vec![false; n],
            closed: false,
        };
        fold.skip_empty();
        fold
    }

    /// Move past segments with no picks to work (nothing to repeat, and a huge repeat count must
    /// not spin; a checked band has no repeat of 0, but one is skipped the same way).
    fn skip_empty(&mut self) {
        let segs = &self.c.band.turning.segments;
        while let Some(seg) = segs.get(self.place.segment) {
            if !seg.picks.is_empty() && seg.repeat > 0 && self.place.step < seg.picks.len() {
                break;
            }
            self.place.segment += 1;
            self.place.repeat = 0;
            self.place.step = 0;
        }
    }

    /// Work picks until `stop` picks are done (or the band ends), telling `obs` about every pick and
    /// every run that ends. When the band's last pick is done, the runs still open are reported as
    /// ending with the band (once).
    pub fn advance<O: Observer>(&mut self, stop: u32, obs: &mut O) {
        let band = self.c.band;
        let segs = &band.turning.segments;
        while self.place.done < stop {
            let Place {
                segment: s,
                repeat: r,
                step: k,
                done,
            } = self.place;
            let Some(seg) = segs.get(s) else {
                break; // every pick is done
            };
            let spec = &seg.picks[k];
            let pick = done + 1;
            let refs = self.c.steps[s][k].as_deref();
            if let Some(refs) = refs {
                for &i in &refs.release {
                    self.release[i] = true;
                }
                for &i in &refs.flip {
                    self.flip[i] = true;
                }
            }
            let letters = spec.turns.as_bytes();
            self.row.clear();
            for (i, sim) in self.sims.iter_mut().enumerate() {
                // Checked: one valid letter per card.
                let turn = letters
                    .get(i)
                    .and_then(|&b| Turn::from_byte(b))
                    .unwrap_or(Turn::Idle);
                let cp = sim.step(
                    &band.cards[i].threads,
                    turn,
                    self.release[i],
                    self.flip[i],
                    pick,
                    i,
                    obs,
                );
                if O::DETAIL {
                    self.row.push(cp);
                }
            }
            if let Some(refs) = refs {
                for &i in refs.release.iter().chain(&refs.flip) {
                    self.release[i] = false;
                    self.flip[i] = false;
                }
            }
            if O::DETAIL {
                let ctx = PickContext {
                    pick,
                    segment: s,
                    step: k,
                    repeat: r,
                    spec,
                    refs,
                };
                obs.pick(&ctx, &self.row);
            }
            // The place of the next pick.
            let mut next = Place {
                segment: s,
                repeat: r,
                step: k + 1,
                done: pick,
            };
            if next.step == seg.picks.len() {
                next.step = 0;
                next.repeat += 1;
                if next.repeat >= seg.repeat {
                    next.repeat = 0;
                    next.segment += 1;
                }
            }
            self.place = next;
            self.skip_empty();
        }
        if self.place.done == self.c.total_picks && !self.closed {
            self.closed = true;
            let done = self.place.done;
            for (i, sim) in self.sims.iter_mut().enumerate() {
                sim.close_runs(i, done, RunEnd::BandEnd, obs);
            }
        }
    }
}

/// An observer that keeps nothing but still has the fold keep every hole's run (checkpoints need
/// the runs, which a bare fold to a state skips).
pub(crate) struct RunsOnly;
impl Observer for RunsOnly {}

/// Fold the rules over picks 1 to `stop` (at most the band's length), telling `obs` about every
/// pick and every run that ends. Returns each card's simulation state after `stop`.
pub(crate) fn simulate_with<O: Observer>(c: &Checked<'_>, stop: u32, obs: &mut O) -> Vec<CardSim> {
    let mut fold = Fold::new(c);
    fold.advance(stop, obs);
    fold.sims
}

/// Simulate a checked band to its end, pushing the warnings, unsupported markers and information of
/// ADR 0018 sections 5 to 7 into `out`.
pub(crate) fn run_diagnostics(c: &Checked<'_>, out: &mut Collector) {
    let mut obs = DiagObserver {
        band: c.band,
        settings: c.band.settings,
        out,
        prev_twist: vec![Some(0); c.band.cards.len()],
    };
    simulate_with(c, c.total_picks, &mut obs);
}

struct DiagObserver<'a, 'o> {
    band: &'a TabletBand,
    settings: BandSettings,
    out: &'o mut Collector,
    /// Each card's `twist` after the previous pick (to see releases and thresholds crossed).
    prev_twist: Vec<Option<i32>>,
}

fn card_no(i: usize) -> u32 {
    u32::try_from(i + 1).unwrap_or(u32::MAX)
}

fn capitalized(s: &str) -> String {
    let mut c = s.chars();
    match c.next() {
        Some(f) => f.to_uppercase().collect::<String>() + c.as_str(),
        None => String::new(),
    }
}

fn quarter_turns(n: u64) -> String {
    count(n, "quarter turn", "quarter turns")
}

/// The cards of `row` that match, as a capped [`CardSet`] (at most [`MAX_LOCATION_CARDS`] numbers
/// kept, all counted).
fn card_set(row: &[CardPick], f: impl Fn(usize, &CardPick) -> bool) -> CardSet {
    let mut set = CardSet::default();
    for (i, c) in row.iter().enumerate() {
        if f(i, c) {
            if set.cards.len() < MAX_LOCATION_CARDS {
                set.cards.push(card_no(i));
            }
            set.total = set.total.saturating_add(1);
        }
    }
    set
}

fn at_pick(pick: u32, cards: CardSet, face: Option<Face>) -> TabletLocation {
    TabletLocation::Pick { pick, cards, face }
}

impl Observer for DiagObserver<'_, '_> {
    fn pick(&mut self, ctx: &PickContext<'_>, row: &[CardPick]) {
        let pick = ctx.pick;
        // Every diagnostic below is built (and formatted) only if it will be listed; past the cap it
        // is only counted.

        // Releases (first), with the amount each card held.
        if row.iter().any(|c| c.released) {
            let prev = &self.prev_twist;
            self.out.push_with(TabletCode::TwistReleased, || {
                let released = card_set(row, |_, c| c.released);
                let mut lo = u32::MAX;
                let mut hi = 0;
                let mut unknown = false;
                for (c, p) in row.iter().zip(prev) {
                    if c.released {
                        match p {
                            Some(v) => {
                                lo = lo.min(v.unsigned_abs());
                                hi = hi.max(v.unsigned_abs());
                            }
                            None => unknown = true,
                        }
                    }
                }
                let amount = if unknown {
                    "some amounts unknown".to_string()
                } else if lo == hi {
                    let each = if released.total > 1 { " each" } else { "" };
                    format!("{}{each}", quarter_turns(u64::from(lo)))
                } else {
                    format!("from {lo} to {}", quarter_turns(u64::from(hi)))
                };
                let text = released.text();
                Diagnostic::new(
                    TabletCode::TwistReleased,
                    at_pick(pick, released, None),
                    format!("Before pick {pick}: the twist behind {text} is released ({amount})."),
                )
            });
        }

        // Flips (second).
        if row.iter().any(|c| c.flipped) {
            self.out.push_with(TabletCode::Flip, || {
                let flipped = card_set(row, |_, c| c.flipped);
                let now = |t: Option<ThreadingDirection>| {
                    row.iter().filter(|c| c.flipped).all(|c| c.threading == t)
                };
                let now = if now(Some(ThreadingDirection::Z)) {
                    " (now Z-threaded)"
                } else if now(Some(ThreadingDirection::S)) {
                    " (now S-threaded)"
                } else if now(None) {
                    " (its threading is unknown)"
                } else {
                    " (each changes S to Z or Z to S)"
                };
                let verb = if flipped.total == 1 { "is" } else { "are" };
                let text = flipped.text();
                Diagnostic::new(
                    TabletCode::Flip,
                    at_pick(pick, flipped, None),
                    format!("Before pick {pick}: {text} {verb} flipped{now}."),
                )
            });
        }

        // Actions Ply does not model, one per card with the pattern's words.
        for (i, c) in row.iter().enumerate() {
            if c.turn == Turn::Unsupported {
                self.out.push_with(TabletCode::UnsupportedTurn, || {
                    let words = ctx.refs.map_or("", |r| r.words_for(i));
                    Diagnostic::new(
                        TabletCode::UnsupportedTurn,
                        at_pick(pick, CardSet::one(card_no(i)), None),
                        format!(
                            "Pick {pick}, card {}: \"{}\" is not modelled; the card's \
                             arrangement, threading, faces and twist are unknown from here.",
                            i + 1,
                            excerpt(words, 80)
                        ),
                    )
                });
            }
        }

        if let Some(note) = &ctx.spec.note {
            self.out.push_with(TabletCode::NoteNotDrawn, || {
                let message = match note.kind {
                    NoteKind::Brocade => format!(
                        "Pick {pick} has a brocade note; the face view does not show the brocade \
                         weft."
                    ),
                    NoteKind::Other => format!(
                        "Pick {pick} has a note Ply does not model (\"{}\"); the face view does \
                         not show it.",
                        excerpt(&note.text, 80)
                    ),
                };
                Diagnostic::new(
                    TabletCode::NoteNotDrawn,
                    at_pick(pick, CardSet::default(), None),
                    message,
                )
            });
        }

        if row.iter().any(|c| c.reversal) {
            self.out.push_with(TabletCode::Reversal, || {
                let reversed = card_set(row, |_, c| c.reversal);
                let text = reversed.text();
                Diagnostic::new(
                    TabletCode::Reversal,
                    at_pick(pick, reversed, None),
                    format!("Reversal at pick {pick}, {text}."),
                )
            });
        }

        let is_ambiguous = |_: usize, c: &CardPick| matches!(c.top, FaceThread::Ambiguous(..));
        if row.iter().enumerate().any(|(i, c)| is_ambiguous(i, c)) {
            self.out.push_with(TabletCode::FaceAmbiguous, || {
                let ambiguous = card_set(row, is_ambiguous);
                let text = ambiguous.text();
                let idle = if ambiguous.total == 1 {
                    "idles"
                } else {
                    "idle"
                };
                Diagnostic::new(
                    TabletCode::FaceAmbiguous,
                    at_pick(pick, ambiguous, None),
                    format!(
                        "Pick {pick}: {text} {idle} without having turned since the start of the \
                         band or a flip, so either upper thread may show on the top face, and \
                         either lower thread on the back."
                    ),
                )
            });
        }

        // A face cell is not modelled where an empty hole crossed (or carries on), and where an
        // ambiguous idle could show an empty hole.
        let band = self.band;
        for face in [Face::Top, Face::Back] {
            let not_modelled = |i: usize, c: &CardPick| {
                let thread = match face {
                    Face::Top => c.top,
                    Face::Back => c.back,
                };
                match thread {
                    FaceThread::Empty(_) => true,
                    FaceThread::Ambiguous(a, b) => {
                        band.thread_color(i, a).is_none() || band.thread_color(i, b).is_none()
                    }
                    _ => false,
                }
            };
            if row.iter().enumerate().any(|(i, c)| not_modelled(i, c)) {
                self.out.push_with(TabletCode::EmptyHoleFace, || {
                    let empty = card_set(row, not_modelled);
                    let text = empty.text();
                    let show = if empty.total == 1 { "shows" } else { "show" };
                    Diagnostic::new(
                        TabletCode::EmptyHoleFace,
                        at_pick(pick, empty, Some(face)),
                        format!(
                            "Pick {pick}: {text} {show} (or may show) an empty hole on the {}, \
                             which Ply does not model (the weft or another thread may show there).",
                            face.name()
                        ),
                    )
                });
            }
        }

        if all_idle(row) {
            self.out.push_with(TabletCode::AllIdle, || {
                let message = if pick == 1 {
                    "No card turns on pick 1, so its weft lies in the shed the cards start in."
                        .to_string()
                } else {
                    format!(
                        "No card turns on pick {pick}, so its weft lies in the same shed as pick \
                         {}.",
                        pick - 1
                    )
                };
                Diagnostic::new(
                    TabletCode::AllIdle,
                    at_pick(pick, CardSet::default(), None),
                    message,
                )
            });
        }

        // Twist passing the threshold (each time it passes). The previous counts are state, kept
        // for every card whether or not anything is listed.
        let limit = self.settings.twist_warning_quarters;
        let passes = |before: Option<i32>, c: &CardPick| {
            let b = if c.released { Some(0) } else { before };
            matches!((b, c.twist.twist), (Some(b), Some(a)) if b.unsigned_abs() <= limit && a.unsigned_abs() > limit)
        };
        let prev = &self.prev_twist;
        if row.iter().zip(prev).any(|(c, &b)| passes(b, c)) {
            self.out.push_with(TabletCode::TwistHigh, || {
                let set = card_set(row, |i, c| passes(prev[i], c));
                let over = if limit.is_multiple_of(4) {
                    format!(
                        "more than {}",
                        count(u64::from(limit / 4), "full turn", "full turns")
                    )
                } else {
                    format!("more than {}", quarter_turns(u64::from(limit)))
                };
                let text = capitalized(&set.text());
                let (hold, cards) = if set.total == 1 {
                    ("holds", "card")
                } else {
                    ("now hold", "cards")
                };
                Diagnostic::new(
                    TabletCode::TwistHigh,
                    at_pick(pick, set, None),
                    format!(
                        "{text} {hold} {over} of twist behind the {cards} after pick {pick} ({}).",
                        quarter_turns(u64::from(limit) + 1)
                    ),
                )
                .with_remediation(
                    "Weave back the other way, flip the cards and weave on, or untie and comb out \
                     the far end (record it as a twist release).",
                )
            });
        }
        for (before, c) in self.prev_twist.iter_mut().zip(row) {
            *before = c.twist.twist;
        }
    }

    fn run_closed(&mut self, run: ClosedRun) {
        if run.last < run.first {
            return;
        }
        let length = u64::from(run.last - run.first) + 1;
        if length <= u64::from(self.settings.float_warning_picks) {
            return;
        }
        let band = self.band;
        self.out.push_with(TabletCode::LongFloat, || {
            let face = if run.upper { Face::Top } else { Face::Back };
            let tail = match run.end {
                RunEnd::Ended => "",
                RunEnd::BandEnd => ", still floating at the end of the band",
                RunEnd::StateUnknown => ", and then the card does something Ply does not model",
            };
            let color = band
                .thread_color(run.card, run.hole)
                .and_then(|c| band.palette.get(c as usize))
                .map_or(String::new(), |c| format!(" ({})", c.to_hex()));
            let span = if run.first == run.last {
                format!("pick {}", run.first)
            } else {
                format!("picks {} to {}", run.first, run.last)
            };
            Diagnostic::new(
                TabletCode::LongFloat,
                TabletLocation::Run {
                    card: card_no(run.card),
                    hole: run.hole,
                    face,
                    first_pick: run.first,
                    last_pick: run.last,
                    end: run.end,
                },
                format!(
                    "Card {}: the thread in hole {}{color} floats on the {} for {} ({span}{tail}).",
                    run.card + 1,
                    run.hole,
                    face.name(),
                    count(length, "pick", "picks"),
                ),
            )
            .with_remediation(
                "Turn the card on these picks, or accept the float if the technique intends it.",
            )
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::band::{PickSpec, Segment, Tablet, TurnSequence};
    use crate::diagnostic::BUILT;
    use crate::validate::validate_with;

    fn band(cards: usize, picks: u32, turns: &str, float: u32) -> TabletBand {
        let mut b = TabletBand {
            palette: vec![ply_common::Color::BLACK],
            cards: (0..cards)
                .map(|i| {
                    Tablet::new(
                        format!("c{i}"),
                        HoleThreads::all(0),
                        ThreadingDirection::S,
                        CardPosition::ply_home(),
                    )
                })
                .collect(),
            turning: TurnSequence::new(vec![Segment::new(picks, vec![PickSpec::new(turns)])]),
            ..TabletBand::default()
        };
        b.settings.float_warning_picks = float;
        b
    }

    /// Diagnostics past the cap are counted, not built: the work spent on diagnostics is bounded by
    /// the cap, however many the band produces.
    #[test]
    fn diagnostics_past_the_cap_are_never_built() {
        // 50 cards for 1,000 picks, the odd ones idling throughout, and every run warned about
        // (threshold 0): tens of thousands of long floats and a thousand ambiguous picks.
        let turns: String = (0..50)
            .map(|i| if i % 2 == 0 { 'F' } else { 'I' })
            .collect();
        let b = band(50, 1_000, &turns, 0);
        let limits = TabletLimits {
            max_diagnostics_per_code: 7,
            ..TabletLimits::DEFAULT
        };
        let before = BUILT.with(|c| c.get());
        let diags = validate_with(&b, &limits);
        let built = BUILT.with(|c| c.get()) - before;
        // At most 7 per code were built (the list_capped summaries are built by finish, not
        // counted).
        assert!(built <= 7 * TabletCode::ALL.len() as u64, "{built}");
        let longs = diags
            .iter()
            .filter(|d| d.code == TabletCode::LongFloat)
            .count();
        assert_eq!(longs, 7);
        // Every run is counted. A card turned forward from home moves each hole one corner a pick,
        // so after pick p hole A is upper when p mod 4 is 0 or 1: it changes layer on every even
        // pick from 2 to 1,000 (500 changes, 501 runs); C likewise (501); D and B change on every
        // odd pick from 3 to 999 (499 changes, 500 runs each): 2,002 runs a card. An idle card keeps
        // its 4 holes in one run each. 25 * 2,002 + 25 * 4 = 50,150.
        let omitted = diags
            .iter()
            .find_map(|d| match d.location {
                TabletLocation::Omitted {
                    code: TabletCode::LongFloat,
                    count,
                } => Some(count),
                _ => None,
            })
            .unwrap();
        assert_eq!(omitted + 7, 50_150);
    }

    #[test]
    fn structural_errors_past_the_cap_are_never_built() {
        let b = band(2, 1, &"x".repeat(5_000), 3);
        let limits = TabletLimits {
            max_diagnostics_per_code: 5,
            ..TabletLimits::DEFAULT
        };
        let before = BUILT.with(|c| c.get());
        let diags = validate_with(&b, &limits);
        assert!(BUILT.with(|c| c.get()) - before <= 5 * TabletCode::ALL.len() as u64);
        assert_eq!(
            diags
                .iter()
                .filter(|d| d.code == TabletCode::TurnLetter)
                .count(),
            5
        );
        assert!(diags.iter().any(|d| d.location
            == TabletLocation::Omitted {
                code: TabletCode::TurnLetter,
                count: 4_995
            }));
    }
}
