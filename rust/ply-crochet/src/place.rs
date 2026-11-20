//! Names for places in a resolved piece (ADR 0022 sections 1 and 4), shared by the resolved model
//! and by diagnostics.
//!
//! - An **item** is anything a layer makes, numbered in work order: item 0 is the layer's starting
//!   chain (when it has one), items 1, 2, ... its stitches and chain runs. `r.k` below is item k of
//!   layer r, r being the layer's position in the piece (Row 3, Round 2), counted from 1.
//! - A **position** is one place on a layer's base that can be worked into: a stitch top, the top
//!   of a counted starting chain, a space under a chain run, one chain, or the ring.
//! - An **anchor** is what a stitch is worked into, resolved explicitly.

use crate::pattern::{ChainPart, Part};
use serde::{Deserialize, Serialize};
use std::fmt;

/// Item `item` of the layer at position `layer` (both as the ADR writes them: layer 1 is the first
/// layer, item 0 a starting chain).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
pub struct ItemId {
    pub layer: u32,
    pub item: u32,
}

impl ItemId {
    pub const fn new(layer: u32, item: u32) -> ItemId {
        ItemId { layer, item }
    }
}

impl fmt::Display for ItemId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}.{}", self.layer, self.item)
    }
}

/// One chain that can be worked into.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ChainAt {
    /// Foundation chain `F i`: `F1` is the first made (next to the slip knot), `Fn` the one nearest
    /// the hook.
    Foundation(u32),
    /// The `index`-th chain made (from 1) of the chain run `of` (or of the space of a starting chain
    /// that counts as a stitch and a space, `of` being its item 0).
    Run { of: ItemId, index: u32 },
}

/// A position on a base, by what made it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PosRef {
    /// The top of stitch `r.k` (a basic stitch, a `tog`, an ordinary slip stitch, a foundation
    /// stitch, or a position an opaque instruction made).
    Top(ItemId),
    /// The top chain of the counted starting chain `r.0` ("3rd ch of beg ch-3").
    StartTop(ItemId),
    /// The space under chain run `r.k` (or the space of a starting chain counting as a stitch and a
    /// space, `r.0`), as a whole.
    Space(ItemId),
    /// One chain.
    Chain(ChainAt),
    /// The piece's ring.
    Ring,
}

impl fmt::Display for PosRef {
    /// The ADR's notation: `2.7`, `2.0^`, `sp 3.8`, `F9`, `3.2#1` (chain 1 of run 3.2), `ring`.
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            PosRef::Top(id) => write!(f, "{id}"),
            PosRef::StartTop(id) => write!(f, "{id}^"),
            PosRef::Space(id) => write!(f, "sp {id}"),
            PosRef::Chain(ChainAt::Foundation(i)) => write!(f, "F{i}"),
            PosRef::Chain(ChainAt::Run { of, index }) => write!(f, "{of}#{index}"),
            PosRef::Ring => f.write_str("ring"),
        }
    }
}

/// The two faces of the fabric. Side A faces the crocheter while working layer 1; the document's
/// `first_side` says whether that is the right side.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Side {
    A,
    B,
}

impl Side {
    pub const fn other(self) -> Side {
        match self {
            Side::A => Side::B,
            Side::B => Side::A,
        }
    }
}

/// What a stitch, a leg or a slip stitch is worked into, resolved (ADR 0022 section 4).
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Anchor {
    /// The top of stitch `of`, in both loops or one, as worked.
    Top {
        of: ItemId,
        part: Part,
    },
    /// The top chain of the counted starting chain `of`.
    StartTop {
        of: ItemId,
    },
    /// The space under chain run `of`, as a whole.
    Space {
        of: ItemId,
    },
    /// One chain, in an unspecified part or the one the pattern states.
    Chain {
        at: ChainAt,
        part: ChainPart,
    },
    Ring,
    /// An opaque target: worked somewhere Ply does not model; the attachment is unverified.
    Unmodelled,
    /// The stated target cannot be worked (a diagnostic says why). The stitch is still made and
    /// counted.
    Impossible,
}

impl Anchor {
    /// The base position this anchor is worked into, if it names one.
    pub fn position(&self) -> Option<PosRef> {
        match *self {
            Anchor::Top { of, .. } => Some(PosRef::Top(of)),
            Anchor::StartTop { of } => Some(PosRef::StartTop(of)),
            Anchor::Space { of } => Some(PosRef::Space(of)),
            Anchor::Chain { at, .. } => Some(PosRef::Chain(at)),
            Anchor::Ring => Some(PosRef::Ring),
            Anchor::Unmodelled | Anchor::Impossible => None,
        }
    }
}

impl fmt::Display for Anchor {
    /// The ADR's notation: `4.8/BL`, `4.5/FL`, `2.0^`, `sp 3.8`, `F9`, `F9/back_bump`, `ring`.
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Anchor::Top { of, part } => match part {
                Part::Both => write!(f, "{of}"),
                Part::BackLoop => write!(f, "{of}/BL"),
                Part::FrontLoop => write!(f, "{of}/FL"),
            },
            Anchor::Chain { at, part } => {
                write!(f, "{}", PosRef::Chain(*at))?;
                match part {
                    ChainPart::Unspecified => Ok(()),
                    ChainPart::TopLoop => f.write_str("/top_loop"),
                    ChainPart::BackBump => f.write_str("/back_bump"),
                }
            }
            Anchor::Unmodelled => f.write_str("unmodelled"),
            Anchor::Impossible => f.write_str("impossible"),
            other => match other.position() {
                Some(p) => write!(f, "{p}"),
                None => Ok(()),
            },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn places_print_in_the_adr_notation() {
        let id = ItemId::new(2, 7);
        assert_eq!(PosRef::Top(id).to_string(), "2.7");
        assert_eq!(PosRef::StartTop(ItemId::new(2, 0)).to_string(), "2.0^");
        assert_eq!(PosRef::Space(ItemId::new(3, 8)).to_string(), "sp 3.8");
        assert_eq!(PosRef::Chain(ChainAt::Foundation(9)).to_string(), "F9");
        assert_eq!(
            PosRef::Chain(ChainAt::Run {
                of: ItemId::new(3, 2),
                index: 1
            })
            .to_string(),
            "3.2#1"
        );
        assert_eq!(
            Anchor::Top {
                of: ItemId::new(4, 8),
                part: Part::BackLoop
            }
            .to_string(),
            "4.8/BL"
        );
        assert_eq!(Anchor::Ring.to_string(), "ring");
        assert_eq!(Side::A.other(), Side::B);
    }
}
