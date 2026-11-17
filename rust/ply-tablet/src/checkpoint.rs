//! Checkpoints for paging through a long band (ADR 0018 M10-01 amendment 10, built in M10-02): the
//! whole simulation state after a pick, so a window anywhere in the band is folded from the nearest
//! checkpoint before it instead of from pick 1.
//!
//! A checkpoint carries, per card, everything a later pick depends on: the arrangement, the
//! threading, `twist` and `woven`, the holes that last crossed the top and the bottom (none at the
//! start, after a flip, or once unknown), the last turned pick's twining, and each hole's open run
//! (its layer and first pick). Each card's `twist` after the previous pick, which the diagnostics
//! compare against, is the checkpoint's own `twist`. It also carries the place in the turning (the
//! segment, repeat and written pick of the next pick) and a fingerprint of the band it belongs to.
//!
//! **Always the same result.** [`try_simulate_from`] and [`state_after_from`] use a checkpoint only
//! when it belongs to the band (same fingerprint and rules version) and lies before the window;
//! otherwise they fold from pick 1, so a resumed window is always exactly the window
//! [`crate::try_simulate`] gives. Tests hold them to that.
//!
//! **Untrusted bytes.** A checkpoint can leave the engine as bytes ([`Checkpoint::encode`]) and come
//! back ([`Checkpoint::decode`]); decoding checks the length, a checksum, every value's range and the
//! place against the band before anything uses it, so no byte string can make the fold panic.

use crate::band::{TabletBand, TabletLimits};
use crate::card::{CardPosition, Hole, ThreadingDirection, Twining};
use crate::error::TabletError;
use crate::simulate::{
    simulate_window_from, BandState, CardSim, Fold, NoObserver, Place, Run, RunsOnly, TabletWindow,
    TwistState,
};
use crate::validate::check;
use crate::RULES_VERSION;
use std::ops::RangeInclusive;

/// The fewest picks between checkpoints: a fold of this many picks is cheap even at the card limit.
pub const MIN_CHECKPOINT_INTERVAL: u32 = 256;

/// The most card states all the checkpoints of one band hold together (about 4 MB encoded), so a
/// band at the limits gets fewer, wider-spaced checkpoints rather than more memory.
pub const MAX_CHECKPOINT_CARD_STATES: u64 = 131_072;

/// The simulation state after pick [`Checkpoint::pick`] of one band.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Checkpoint {
    fingerprint: u64,
    place: Place,
    cards: Vec<CardSim>,
}

/// Why bytes are not a checkpoint of this band.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[error("not a checkpoint of this band: {0}")]
pub struct CheckpointError(pub &'static str);

impl Checkpoint {
    /// The pick after which this is the state (1-based; a checkpoint is never at pick 0).
    pub fn pick(&self) -> u32 {
        self.place.done
    }

    /// The fingerprint of the band it belongs to ([`band_fingerprint`]).
    pub fn fingerprint(&self) -> u64 {
        self.fingerprint
    }

    /// Whether this checkpoint belongs to `band` (and to this engine's rules).
    pub fn belongs_to(&self, band: &TabletBand) -> bool {
        self.cards.len() == band.cards.len() && self.fingerprint == band_fingerprint(band)
    }

    /// The band's state at this checkpoint, as [`crate::state_after`] gives it.
    pub fn state(&self) -> BandState {
        BandState {
            pick: self.place.done,
            cards: self.cards.iter().map(CardSim::state).collect(),
        }
    }

    /// The checkpoint as bytes: a header (magic, format and rules version, fingerprint, place,
    /// cards), 33 bytes per card and a checksum.
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(HEADER_BYTES + self.cards.len() * CARD_BYTES + 8);
        out.extend_from_slice(MAGIC);
        out.push(FORMAT_VERSION);
        out.push(RULES_VERSION as u8);
        out.extend_from_slice(&self.fingerprint.to_le_bytes());
        for v in [
            self.place.done,
            u32::try_from(self.place.segment).unwrap_or(u32::MAX),
            self.place.repeat,
            u32::try_from(self.place.step).unwrap_or(u32::MAX),
            u32::try_from(self.cards.len()).unwrap_or(u32::MAX),
        ] {
            out.extend_from_slice(&v.to_le_bytes());
        }
        for c in &self.cards {
            encode_card(c, &mut out);
        }
        let sum = fnv1a(FNV_OFFSET, &out);
        out.extend_from_slice(&sum.to_le_bytes());
        out
    }

    /// Read bytes [`Checkpoint::encode`] wrote, checking them against `band`: the length and
    /// checksum, the format and rules version, the card count, the place (a written pick of the
    /// band's turning whose expanded number is the checkpoint's pick) and every card's values (a
    /// legal arrangement, twist no larger than the picks woven, runs that started by then, and
    /// nothing known about a card whose arrangement is not). The fingerprint is checked when the
    /// checkpoint is used, not here.
    pub fn decode(bytes: &[u8], band: &TabletBand) -> Result<Checkpoint, CheckpointError> {
        let err = CheckpointError;
        if bytes.len() < HEADER_BYTES + 8 {
            return Err(err("too short"));
        }
        let (body, sum) = bytes.split_at(bytes.len() - 8);
        if fnv1a(FNV_OFFSET, body).to_le_bytes() != sum {
            return Err(err("its checksum does not match"));
        }
        if &body[..MAGIC.len()] != MAGIC {
            return Err(err("it does not start with the checkpoint mark"));
        }
        let mut r = Reader {
            bytes: body,
            at: MAGIC.len(),
        };
        if r.u8()? != FORMAT_VERSION || u32::from(r.u8()?) != RULES_VERSION {
            return Err(err("it was written by another version of the engine"));
        }
        let fingerprint = r.u64()?;
        let pick = r.u32()?;
        let segment = r.u32()? as usize;
        let repeat = r.u32()?;
        let step = r.u32()? as usize;
        let cards = r.u32()? as usize;
        if cards != band.cards.len() {
            return Err(err("its card count is not the band's"));
        }
        if body.len() != HEADER_BYTES + cards.saturating_mul(CARD_BYTES) {
            return Err(err("its length does not match its card count"));
        }
        if pick == 0 {
            return Err(err("a checkpoint is after a pick, never before pick 1"));
        }
        let place = Place {
            segment,
            repeat,
            step,
            done: pick,
        };
        if !place_is_pick(band, place) {
            return Err(err("its place in the turning is not its pick"));
        }
        let mut sims = Vec::with_capacity(cards);
        for _ in 0..cards {
            sims.push(decode_card(&mut r, pick)?);
        }
        Ok(Checkpoint {
            fingerprint,
            place,
            cards: sims,
        })
    }
}

/// A fingerprint of everything in a band (FNV-1a over its serde form, streamed without a copy):
/// equal bands give equal fingerprints, and a checkpoint is only used with the band it was made
/// from.
pub fn band_fingerprint(band: &TabletBand) -> u64 {
    let mut h = Fnv(FNV_OFFSET ^ u64::from(RULES_VERSION));
    // Serializing these types cannot fail, and the hasher never refuses bytes.
    let _ = serde_json::to_writer(&mut h, band);
    h.0
}

/// The spacing of a band's checkpoints: at least [`MIN_CHECKPOINT_INTERVAL`] picks, and wide enough
/// that all of them hold at most [`MAX_CHECKPOINT_CARD_STATES`] card states.
pub fn checkpoint_interval(cards: usize, picks: u32) -> u32 {
    let cells = (cards as u64).saturating_mul(u64::from(picks));
    let wide = cells.div_ceil(MAX_CHECKPOINT_CARD_STATES);
    u32::try_from(wide)
        .unwrap_or(u32::MAX)
        .max(MIN_CHECKPOINT_INTERVAL)
}

/// The band's checkpoints after picks `every`, `2 * every`, ... (each before the last pick; a
/// checkpoint at the end would never be resumed from), in pick order. `every` of 0 is read as
/// [`checkpoint_interval`]. Refuses a band with structural errors, as simulation does. One fold over
/// the band; memory is O(cards) per checkpoint.
pub fn checkpoints(
    band: &TabletBand,
    every: u32,
    limits: &TabletLimits,
) -> Result<Vec<Checkpoint>, TabletError> {
    let checked = check(band, limits)?;
    let total = checked.total_picks;
    let every = if every == 0 {
        checkpoint_interval(band.cards.len(), total)
    } else {
        every
    };
    let fingerprint = band_fingerprint(band);
    let mut fold = Fold::new(&checked);
    let mut out = Vec::new();
    let mut at = every;
    while at < total {
        fold.advance(at, &mut RunsOnly);
        out.push(Checkpoint {
            fingerprint,
            place: fold.place,
            cards: fold.sims.clone(),
        });
        at = match at.checked_add(every) {
            Some(next) => next,
            None => break,
        };
    }
    Ok(out)
}

/// The checkpoint to resume `band` from for a window starting at pick `first`: the latest one
/// before it that belongs to the band, if any.
pub fn nearest_before<'a>(
    checkpoints: &'a [Checkpoint],
    band: &TabletBand,
    first: u32,
) -> Option<&'a Checkpoint> {
    let fingerprint = band_fingerprint(band);
    checkpoints
        .iter()
        .filter(|c| c.fingerprint == fingerprint && c.cards.len() == band.cards.len())
        .filter(|c| c.place.done < first)
        .max_by_key(|c| c.place.done)
}

/// [`crate::try_simulate`] resumed from `from` when it belongs to the band and lies before the
/// window (otherwise folded from pick 1): exactly the same window, in time proportional to the
/// picks after the checkpoint.
pub fn try_simulate_from(
    band: &TabletBand,
    from: Option<&Checkpoint>,
    picks: RangeInclusive<u32>,
    limits: &TabletLimits,
) -> Result<TabletWindow, TabletError> {
    let checked = check(band, limits)?;
    let (first, last) = (*picks.start(), *picks.end());
    let resume = usable(from, band, first).map(|cp| (cp.cards.clone(), cp.place));
    simulate_window_from(&checked, resume, first, last, limits)
}

/// [`crate::state_after`] resumed from `from` when it belongs to the band and lies at or before
/// `pick` (otherwise folded from pick 1).
pub fn state_after_from(
    band: &TabletBand,
    from: Option<&Checkpoint>,
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
    let mut fold = match usable(from, band, pick.saturating_add(1)) {
        Some(cp) => Fold::resume(&checked, cp.cards.clone(), cp.place),
        None => Fold::new(&checked),
    };
    fold.advance(pick, &mut NoObserver);
    Ok(BandState {
        pick,
        cards: fold.sims.iter().map(CardSim::state).collect(),
    })
}

fn usable<'a>(
    from: Option<&'a Checkpoint>,
    band: &TabletBand,
    first: u32,
) -> Option<&'a Checkpoint> {
    from.filter(|c| c.place.done < first && c.belongs_to(band))
}

/// Whether `place` is the written pick that expanded pick `place.done + 1` comes from (or the end of
/// the band when that is past the last pick).
fn place_is_pick(band: &TabletBand, place: Place) -> bool {
    let segs = &band.turning.segments;
    let mut before: u64 = 0;
    for seg in segs.iter().take(place.segment.min(segs.len())) {
        let n = (seg.picks.len() as u64).saturating_mul(u64::from(seg.repeat));
        before = before.saturating_add(n);
    }
    let done = u64::from(place.done);
    match segs.get(place.segment) {
        None => {
            place.segment == segs.len() && place.repeat == 0 && place.step == 0 && before == done
        }
        Some(seg) => {
            if seg.picks.is_empty() || place.step >= seg.picks.len() || place.repeat >= seg.repeat {
                return false;
            }
            let within = u64::from(place.repeat)
                .saturating_mul(seg.picks.len() as u64)
                .saturating_add(place.step as u64);
            before.saturating_add(within) == done
        }
    }
}

const MAGIC: &[u8; 6] = b"PLYTCK";
const FORMAT_VERSION: u8 = 1;
/// Magic, format and rules version, fingerprint, then pick, segment, repeat, step and cards.
const HEADER_BYTES: usize = 6 + 1 + 1 + 8 + 4 * 5;
/// Position, threading, flags, twist, woven, last crossed, last twining, four runs.
const CARD_BYTES: usize = 1 + 1 + 1 + 4 + 4 + 1 + 1 + 4 * 5;
const NONE: u8 = 0xFF;

fn encode_card(c: &CardSim, out: &mut Vec<u8>) {
    let all = CardPosition::all();
    out.push(
        c.position
            .and_then(|p| all.iter().position(|q| *q == p))
            .map_or(NONE, |i| i as u8),
    );
    out.push(match c.threading {
        Some(ThreadingDirection::S) => 0,
        Some(ThreadingDirection::Z) => 1,
        None => NONE,
    });
    let flags = u8::from(c.twist.twist.is_some()) | (u8::from(c.twist.woven.is_some()) << 1);
    out.push(flags);
    out.extend_from_slice(&c.twist.twist.unwrap_or(0).to_le_bytes());
    out.extend_from_slice(&c.twist.woven.unwrap_or(0).to_le_bytes());
    out.push(c.last_crossed.map_or(NONE, |(over, under)| {
        (over.index() * 4 + under.index()) as u8
    }));
    out.push(match c.last_twining {
        Some(Twining::S) => 0,
        Some(Twining::Z) => 1,
        None => NONE,
    });
    for run in c.runs {
        match run {
            None => {
                out.push(0);
                out.extend_from_slice(&0u32.to_le_bytes());
            }
            Some(r) => {
                out.push(if r.upper { 2 } else { 1 });
                out.extend_from_slice(&r.start.to_le_bytes());
            }
        }
    }
}

fn decode_card(r: &mut Reader<'_>, pick: u32) -> Result<CardSim, CheckpointError> {
    let err = CheckpointError;
    let all = CardPosition::all();
    let position = match r.u8()? {
        NONE => None,
        i if (i as usize) < all.len() => Some(all[i as usize]),
        _ => return Err(err("a card's arrangement is not one of the 8")),
    };
    let threading = match r.u8()? {
        0 => Some(ThreadingDirection::S),
        1 => Some(ThreadingDirection::Z),
        NONE => None,
        _ => return Err(err("a card's threading is not S or Z")),
    };
    let flags = r.u8()?;
    if flags > 3 {
        return Err(err("a card's twist flags are not known"));
    }
    let twist = r.i32()?;
    let woven = r.i32()?;
    // Twist moves one quarter turn a pick, so it can never pass the pick count: this also keeps the
    // fold's checked arithmetic from ever overflowing.
    let bounded = |v: i32| v.unsigned_abs() <= pick;
    if !bounded(twist) || !bounded(woven) {
        return Err(err("a card holds more twist than the picks woven"));
    }
    let twist = TwistState {
        twist: (flags & 1 != 0).then_some(twist),
        woven: (flags & 2 != 0).then_some(woven),
    };
    let last_crossed = match r.u8()? {
        NONE => None,
        v if v < 16 && v / 4 != v % 4 => Some((
            Hole::from_index(usize::from(v / 4)),
            Hole::from_index(usize::from(v % 4)),
        )),
        _ => return Err(err("a card's last crossing is not two holes")),
    };
    let last_twining = match r.u8()? {
        0 => Some(Twining::S),
        1 => Some(Twining::Z),
        NONE => None,
        _ => return Err(err("a card's last twining is not S or Z")),
    };
    let mut runs = [None; 4];
    for slot in &mut runs {
        let kind = r.u8()?;
        let start = r.u32()?;
        *slot = match kind {
            0 => None,
            1 | 2 if (1..=pick).contains(&start) => Some(Run {
                upper: kind == 2,
                start,
            }),
            _ => {
                return Err(err(
                    "a card's run is not one that started by the checkpoint",
                ))
            }
        };
    }
    if position.is_none()
        && (threading.is_some()
            || last_crossed.is_some()
            || last_twining.is_some()
            || runs.iter().any(Option::is_some))
    {
        return Err(err(
            "a card whose arrangement is unknown cannot hold known state",
        ));
    }
    Ok(CardSim {
        position,
        threading,
        twist,
        last_crossed,
        last_twining,
        runs,
    })
}

struct Reader<'b> {
    bytes: &'b [u8],
    at: usize,
}

impl Reader<'_> {
    fn take<const N: usize>(&mut self) -> Result<[u8; N], CheckpointError> {
        let end = self
            .at
            .checked_add(N)
            .filter(|&e| e <= self.bytes.len())
            .ok_or(CheckpointError("it ends early"))?;
        let mut out = [0u8; N];
        out.copy_from_slice(&self.bytes[self.at..end]);
        self.at = end;
        Ok(out)
    }
    fn u8(&mut self) -> Result<u8, CheckpointError> {
        Ok(self.take::<1>()?[0])
    }
    fn u32(&mut self) -> Result<u32, CheckpointError> {
        Ok(u32::from_le_bytes(self.take()?))
    }
    fn i32(&mut self) -> Result<i32, CheckpointError> {
        Ok(i32::from_le_bytes(self.take()?))
    }
    fn u64(&mut self) -> Result<u64, CheckpointError> {
        Ok(u64::from_le_bytes(self.take()?))
    }
}

const FNV_OFFSET: u64 = 0xcbf2_9ce4_8422_2325;
const FNV_PRIME: u64 = 0x0000_0100_0000_01b3;

fn fnv1a(mut h: u64, bytes: &[u8]) -> u64 {
    for &b in bytes {
        h ^= u64::from(b);
        h = h.wrapping_mul(FNV_PRIME);
    }
    h
}

/// A streaming FNV-1a hasher that serde can write into.
struct Fnv(u64);

impl std::io::Write for Fnv {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        self.0 = fnv1a(self.0, buf);
        Ok(buf.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::band::{HoleThreads, PickSpec, Segment, Tablet, TurnSequence};
    use crate::card::Turn;
    use crate::simulate::try_simulate;

    fn band(turns: &[&str], repeat: u32) -> TabletBand {
        let cards = turns[0].len();
        TabletBand {
            palette: vec![ply_common::Color::BLACK, ply_common::Color::WHITE],
            cards: (0..cards)
                .map(|i| {
                    Tablet::new(
                        format!("c{i}"),
                        HoleThreads::new(0, 1, 0, 1),
                        if i % 2 == 0 {
                            ThreadingDirection::S
                        } else {
                            ThreadingDirection::Z
                        },
                        CardPosition::all()[i % 8],
                    )
                })
                .collect(),
            turning: TurnSequence::new(vec![
                Segment::new(1, vec![]),
                Segment::new(repeat, turns.iter().map(|t| PickSpec::new(*t)).collect()),
                Segment::new(
                    3,
                    vec![PickSpec::all(Turn::Backward, cards).with_flip(&["c1"])],
                ),
            ]),
            ..TabletBand::default()
        }
    }

    #[test]
    fn a_checkpoint_round_trips_through_bytes() {
        let b = band(&["FBI?", "FFFF", "IBFB"], 40);
        let mut b = b;
        b.turning.segments[1].picks[0]
            .unsupported
            .insert("c3".into(), "half turn".into());
        let cps = checkpoints(&b, 7, &TabletLimits::DEFAULT).unwrap();
        assert!(cps.len() > 10);
        for cp in &cps {
            let bytes = cp.encode();
            assert_eq!(Checkpoint::decode(&bytes, &b).unwrap(), *cp);
            assert!(cp.belongs_to(&b));
        }
    }

    #[test]
    fn resumed_windows_equal_the_whole_fold() {
        let b = band(&["FBIF", "FFFF", "IBFB", "BBFF"], 30);
        let limits = TabletLimits::DEFAULT;
        let cps = checkpoints(&b, 5, &limits).unwrap();
        let total = crate::validate::expanded_picks(&b.turning, &limits).unwrap();
        for first in 1..=total {
            for last in [first, (first + 9).min(total), total] {
                let want = try_simulate(&b, first..=last, &limits).unwrap();
                let from = nearest_before(&cps, &b, first);
                let got = try_simulate_from(&b, from, first..=last, &limits).unwrap();
                assert_eq!(got, want, "window {first} to {last}");
                for cp in &cps {
                    // A checkpoint at or past the window is not used, and the result is the same.
                    let got = try_simulate_from(&b, Some(cp), first..=last, &limits).unwrap();
                    assert_eq!(got, want, "window {first} to {last} from {}", cp.pick());
                }
            }
            let want = crate::simulate::state_after(&b, first, &limits).unwrap();
            for cp in &cps {
                assert_eq!(
                    state_after_from(&b, Some(cp), first, &limits).unwrap(),
                    want
                );
            }
        }
    }

    #[test]
    fn a_checkpoint_of_another_band_is_not_used() {
        let limits = TabletLimits::DEFAULT;
        let a = band(&["FFFF"], 600);
        let mut b = a.clone();
        b.cards[2].threading = ThreadingDirection::Z;
        let cp = checkpoints(&a, 0, &limits).unwrap();
        assert!(!cp.is_empty());
        assert!(!cp[0].belongs_to(&b));
        let want = try_simulate(&b, 500..=520, &limits).unwrap();
        assert_eq!(
            try_simulate_from(&b, Some(&cp[0]), 500..=520, &limits).unwrap(),
            want
        );
        assert!(nearest_before(&cp, &b, 500).is_none());
    }

    #[test]
    fn tampered_bytes_are_refused_without_panicking() {
        let b = band(&["FBIF", "FFFF"], 20);
        let cp = checkpoints(&b, 9, &TabletLimits::DEFAULT)
            .unwrap()
            .remove(0);
        let good = cp.encode();
        // Every single-byte change and every truncation is refused (the checksum, then the checks).
        for i in 0..good.len() {
            let mut bad = good.clone();
            bad[i] ^= 0x5A;
            assert!(Checkpoint::decode(&bad, &b).is_err(), "byte {i}");
            assert!(Checkpoint::decode(&good[..i], &b).is_err(), "length {i}");
        }
        // A checksum recomputed over a value out of range still fails the value checks.
        let resum = |mut body: Vec<u8>| {
            body.truncate(body.len() - 8);
            let s = fnv1a(FNV_OFFSET, &body);
            body.extend_from_slice(&s.to_le_bytes());
            body
        };
        let mut twist = good.clone();
        let at = HEADER_BYTES + 3;
        twist[at..at + 4].copy_from_slice(&i32::MAX.to_le_bytes());
        assert_eq!(
            Checkpoint::decode(&resum(twist), &b),
            Err(CheckpointError(
                "a card holds more twist than the picks woven"
            ))
        );
        let mut place = good.clone();
        place[16..20].copy_from_slice(&5u32.to_le_bytes());
        assert!(Checkpoint::decode(&resum(place), &b).is_err());
        // Another band with as many cards: decodes (its place fits), but is never used with it.
        let other = band(&["BBBB", "FFFF"], 20);
        if let Ok(cp) = Checkpoint::decode(&good, &other) {
            assert!(!cp.belongs_to(&other));
        }
    }

    #[test]
    fn intervals_keep_the_card_states_bounded() {
        assert_eq!(checkpoint_interval(8, 12), MIN_CHECKPOINT_INTERVAL);
        assert_eq!(checkpoint_interval(0, 0), MIN_CHECKPOINT_INTERVAL);
        let every = checkpoint_interval(1_000, 200_000);
        let count = (200_000 - 1) / u64::from(every);
        assert!(count * 1_000 <= MAX_CHECKPOINT_CARD_STATES, "{every}");
    }
}
