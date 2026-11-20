//! A layer's base and the cursor that walks it (ADR 0022 sections 1, 5, 7, 8 and 10).
//!
//! The **base** is what a layer is worked into: the positions of the start (foundation chains, or the
//! ring) for layer 1, the positions the layer before made for every later layer, **in the order the
//! crocheter meets them**. A row after a turn meets the previous row in reverse work order; a joined
//! round meets the previous round from the item its join went into; a turned round starts there and
//! then goes the other way; a spiral round meets the previous round from its first position.
//!
//! The **cursor** is where the hook is on the base: before a position, on one, or on one chain of a
//! space being worked chain by chain. Everything strictly ahead of the cursor is untouched, so finding
//! the next position of a kind is a pure function of the cursor and the base's kinds, answered in
//! constant time from tables built once per layer.
//!
//! A space (the opening under a chain run) is one position that can be entered as a whole or chain
//! by chain, not both. While the cursor is on a space taken whole, its chains are inside it, so
//! `next chain` is `crochet.space_opened`; while the cursor is on a chain of a space with chains still
//! to come, the space is the current position, so `next space` is the same error. Leaving a space's
//! chains for a later stitch passes the chains not yet worked.

use crate::pattern::PosKind;
use crate::place::{ChainAt, PosRef};
use serde::{Deserialize, Serialize};

/// What kind of place a base position is.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PositionKind {
    /// A stitch top (including the top of a counted starting chain).
    Stitch,
    /// The space under a chain run of `chains` chains.
    Space { chains: u32 },
    /// One foundation chain.
    Chain,
    /// The ring: takes any number of stitches and is never used up.
    Ring,
}

/// One position on a base.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct Position {
    pub at: PosRef,
    pub kind: PositionKind,
    /// Made by an opaque instruction (or an opaque layer): Ply knows it is a stitch position and
    /// nothing more, so work into it is shown as unverified.
    pub unverified: bool,
}

impl Position {
    pub(crate) const fn new(at: PosRef, kind: PositionKind) -> Position {
        Position {
            at,
            kind,
            unverified: false,
        }
    }
}

/// Where the hook is on the base.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub(crate) enum Cursor {
    /// Before position i (at the start of a layer, i is 0).
    Before(u32),
    /// On position i, taken whole.
    On(u32),
    /// On chain c (in the order met, from 0) of the space at position i.
    OnChain(u32, u32),
}

impl Cursor {
    /// A total order on cursor places, to tell whether a repetition moved forward.
    pub(crate) fn ordinal(self) -> (u32, u64) {
        match self {
            Cursor::Before(i) => (i, 0),
            Cursor::OnChain(i, c) => (i, u64::from(c) + 1),
            Cursor::On(i) => (i, u64::MAX),
        }
    }
}

/// One place the cursor can land on: a whole position, or one chain of a space.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub(crate) struct Unit {
    pub pos: u32,
    pub chain: Option<u32>,
}

impl Unit {
    pub(crate) const fn whole(pos: u32) -> Unit {
        Unit { pos, chain: None }
    }

    /// The cursor after landing here.
    pub(crate) const fn cursor(self) -> Cursor {
        match self.chain {
            None => Cursor::On(self.pos),
            Some(c) => Cursor::OnChain(self.pos, c),
        }
    }
}

/// A found unit and what the cursor passes on the way to it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Found {
    pub unit: Unit,
    /// The space whose chains after the cursor are passed (the cursor was inside it).
    pub pass_rest_of: Option<u32>,
    /// Whole positions `pass_from..pass_to` are passed.
    pub pass_from: u32,
    pub pass_to: u32,
}

impl Found {
    fn direct(unit: Unit) -> Found {
        Found {
            unit,
            pass_rest_of: None,
            pass_from: 0,
            pass_to: 0,
        }
    }

    /// How many whole positions are passed.
    pub(crate) fn passed(&self) -> u64 {
        u64::from(self.pass_to.saturating_sub(self.pass_from))
    }
}

/// Why no unit was found.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Miss {
    /// Nothing is left on the base.
    PastEnd,
    /// Positions are left, but none of the asked kind.
    Kind,
    /// `next chain` met something that is not a chain.
    NotChain,
    /// The space at the cursor was taken the other way (whole, or chain by chain).
    Opened,
    /// The base is a ring: it is worked into with `ring`, never walked.
    Ring,
}

/// A layer's base: its positions in the order met, and lookup tables.
#[derive(Debug, Clone)]
pub(crate) struct Base {
    pub positions: Vec<Position>,
    /// True when the base meets the layer below in reverse work order, so a space's chains are met
    /// last-made first.
    pub reversed: bool,
    /// True when the base is the piece's ring.
    pub ring: bool,
    /// `next_stitch[i]`: the first stitch position at or after i (`len` when none).
    next_stitch: Vec<u32>,
    /// `next_space[i]`: the first space position at or after i (`len` when none).
    next_space: Vec<u32>,
}

impl Base {
    pub(crate) fn new(positions: Vec<Position>, reversed: bool) -> Base {
        let ring = positions
            .first()
            .is_some_and(|p| p.kind == PositionKind::Ring);
        let len = positions.len();
        let mut next_stitch = vec![len as u32; len + 1];
        let mut next_space = vec![len as u32; len + 1];
        for i in (0..len).rev() {
            next_stitch[i] = if positions[i].kind == PositionKind::Stitch {
                i as u32
            } else {
                next_stitch[i + 1]
            };
            next_space[i] = if matches!(positions[i].kind, PositionKind::Space { .. }) {
                i as u32
            } else {
                next_space[i + 1]
            };
        }
        Base {
            positions,
            reversed,
            ring,
            next_stitch,
            next_space,
        }
    }

    /// The ring as a base.
    pub(crate) fn ring() -> Base {
        Base::new(vec![Position::new(PosRef::Ring, PositionKind::Ring)], false)
    }

    pub(crate) fn len(&self) -> u32 {
        self.positions.len() as u32
    }

    /// Chains of the space at `pos` (0 for anything else).
    pub(crate) fn chains(&self, pos: u32) -> u32 {
        match self.positions.get(pos as usize).map(|p| p.kind) {
            Some(PositionKind::Space { chains }) => chains,
            _ => 0,
        }
    }

    /// The chain met `c`-th (from 0) in the space at `pos`, named by the order it was made.
    pub(crate) fn chain_at(&self, pos: u32, c: u32) -> Option<ChainAt> {
        let p = self.positions.get(pos as usize)?;
        let PosRef::Space(of) = p.at else {
            return None;
        };
        let chains = self.chains(pos);
        let index = if self.reversed {
            chains.checked_sub(c)?
        } else {
            c.checked_add(1)?
        };
        Some(ChainAt::Run { of, index })
    }

    /// The first whole position strictly after the cursor's.
    pub(crate) fn start_index(&self, cur: Cursor) -> u32 {
        match cur {
            Cursor::Before(i) => i,
            Cursor::On(i) | Cursor::OnChain(i, _) => i.saturating_add(1),
        }
    }

    /// Chains of the space at the cursor still to come (0 unless the cursor is on one of its chains).
    pub(crate) fn open_remaining(&self, cur: Cursor) -> u32 {
        match cur {
            Cursor::OnChain(i, c) => self.chains(i).saturating_sub(c.saturating_add(1)),
            _ => 0,
        }
    }

    /// How many positions are left ahead of the cursor (a chain still to come in the space at the
    /// cursor counts 1).
    pub(crate) fn remaining(&self, cur: Cursor) -> u64 {
        u64::from(self.open_remaining(cur))
            + u64::from(self.len().saturating_sub(self.start_index(cur)))
    }

    /// The next unit of `kind` after the cursor (ADR 0022 section 5's `next K`), or why there is
    /// none. Never changes anything.
    pub(crate) fn find(&self, cur: Cursor, kind: PosKind) -> Result<Found, Miss> {
        if self.ring {
            return Err(Miss::Ring);
        }
        let len = self.len();
        let inside = self.open_remaining(cur) > 0;
        let j = self.start_index(cur);
        match kind {
            PosKind::Chain => {
                if let Cursor::OnChain(i, c) = cur {
                    if inside {
                        return Ok(Found::direct(Unit {
                            pos: i,
                            chain: Some(c + 1),
                        }));
                    }
                }
                if let Cursor::On(i) = cur {
                    if matches!(
                        self.positions.get(i as usize).map(|p| p.kind),
                        Some(PositionKind::Space { .. })
                    ) {
                        return Err(Miss::Opened);
                    }
                }
                match self.positions.get(j as usize).map(|p| p.kind) {
                    None => Err(Miss::PastEnd),
                    Some(PositionKind::Chain) => Ok(Found::direct(Unit::whole(j))),
                    Some(PositionKind::Space { chains }) if chains > 0 => Ok(Found::direct(Unit {
                        pos: j,
                        chain: Some(0),
                    })),
                    Some(_) => Err(Miss::NotChain),
                }
            }
            PosKind::Space => {
                if inside {
                    return Err(Miss::Opened);
                }
                if j >= len {
                    return Err(Miss::PastEnd);
                }
                let k = self.next_space[j as usize];
                if k >= len {
                    return Err(Miss::Kind);
                }
                Ok(Found {
                    unit: Unit::whole(k),
                    pass_rest_of: None,
                    pass_from: j,
                    pass_to: k,
                })
            }
            PosKind::Stitch => {
                if j >= len {
                    return Err(if inside { Miss::Kind } else { Miss::PastEnd });
                }
                let k = self.next_stitch[j as usize];
                if k >= len {
                    return Err(Miss::Kind);
                }
                Ok(Found {
                    unit: Unit::whole(k),
                    pass_rest_of: match cur {
                        Cursor::OnChain(i, _) if inside => Some(i),
                        _ => None,
                    },
                    pass_from: j,
                    pass_to: k,
                })
            }
            PosKind::Any => {
                if let Cursor::OnChain(i, c) = cur {
                    if inside {
                        return Ok(Found::direct(Unit {
                            pos: i,
                            chain: Some(c + 1),
                        }));
                    }
                }
                if j >= len {
                    Err(Miss::PastEnd)
                } else {
                    Ok(Found::direct(Unit::whole(j)))
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::place::ItemId;

    fn st(k: u32) -> Position {
        Position::new(PosRef::Top(ItemId::new(1, k)), PositionKind::Stitch)
    }

    fn sp(k: u32, chains: u32) -> Position {
        Position::new(
            PosRef::Space(ItemId::new(1, k)),
            PositionKind::Space { chains },
        )
    }

    #[test]
    fn next_passes_other_kinds_and_never_its_own() {
        // st, sp(2), st, sp(3), st
        let b = Base::new(vec![st(1), sp(2, 2), st(3), sp(4, 3), st(5)], false);
        let f = b.find(Cursor::Before(0), PosKind::Space).unwrap();
        assert_eq!(f.unit, Unit::whole(1));
        assert_eq!((f.pass_from, f.pass_to), (0, 1), "the stitch is passed");
        let f = b.find(Cursor::On(1), PosKind::Stitch).unwrap();
        assert_eq!((f.unit, f.passed()), (Unit::whole(2), 0));
        assert_eq!(b.find(Cursor::On(4), PosKind::Stitch), Err(Miss::PastEnd));
        assert_eq!(b.find(Cursor::On(3), PosKind::Space), Err(Miss::Kind));
        // next chain enters a space chain by chain, then passes nothing.
        let f = b.find(Cursor::On(2), PosKind::Chain).unwrap();
        assert_eq!(f.unit.chain, Some(0));
        assert_eq!(
            b.find(Cursor::OnChain(3, 0), PosKind::Chain).unwrap().unit,
            Unit {
                pos: 3,
                chain: Some(1)
            }
        );
        assert_eq!(
            b.find(Cursor::OnChain(3, 2), PosKind::Chain),
            Err(Miss::NotChain)
        );
        assert_eq!(
            b.find(Cursor::Before(0), PosKind::Chain),
            Err(Miss::NotChain)
        );
        // One way or the other, not both.
        assert_eq!(b.find(Cursor::On(1), PosKind::Chain), Err(Miss::Opened));
        assert_eq!(
            b.find(Cursor::OnChain(3, 0), PosKind::Space),
            Err(Miss::Opened)
        );
        // Leaving a space's chains for a stitch passes the chains still to come.
        let f = b.find(Cursor::OnChain(3, 0), PosKind::Stitch).unwrap();
        assert_eq!((f.unit, f.pass_rest_of), (Unit::whole(4), Some(3)));
        assert_eq!(b.remaining(Cursor::OnChain(3, 0)), 3);
        assert_eq!(b.remaining(Cursor::Before(0)), 5);
    }

    #[test]
    fn chains_are_named_by_the_order_made() {
        let fwd = Base::new(vec![sp(2, 3)], false);
        let rev = Base::new(vec![sp(2, 3)], true);
        let at = |b: &Base, c| match b.chain_at(0, c) {
            Some(ChainAt::Run { index, .. }) => index,
            _ => 0,
        };
        assert_eq!((at(&fwd, 0), at(&fwd, 2)), (1, 3));
        assert_eq!((at(&rev, 0), at(&rev, 2)), (3, 1));
        assert!(Base::ring().ring);
        assert_eq!(
            Base::ring().find(Cursor::Before(0), PosKind::Any),
            Err(Miss::Ring)
        );
    }
}
