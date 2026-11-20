//! Operation identities by structure (ADR 0022 section 2).
//!
//! An operation is known by how it is made, never by a name: "dc" is a US double crochet and a UK
//! single-height stitch, so nothing in the model is keyed by a display name. The basic stitches differ
//! only in the yarn wraps put on the hook before it is inserted and in how the loops are worked off:
//!
//! | Identity | Structure |
//! |---|---|
//! | `b0` | no wrap; insert, pull up a loop, yarn over, through 2 |
//! | `b1h` | 1 wrap; insert, pull up a loop, yarn over, through all 3 |
//! | `b1` | 1 wrap; insert, pull up a loop, (yarn over, through 2) twice |
//! | `b2` | 2 wraps; then (yarn over, through 2) three times |
//! | `b3` | 3 wraps; then (yarn over, through 2) four times |
//!
//! Chains and slip stitches are their own identities, and `tog` (k legs of one basic stitch, each
//! stopped before its last pull, then one pull through all) is one identity for decreases, clusters,
//! bobbles and puffs: which of these a pattern means is decided by where the legs go, not by a name.
//! The names a crocheter reads ("sc", "dc", "tr") belong to a label set ([`crate::labels`]), which
//! only changes text.

use serde::{Deserialize, Deserializer, Serialize, Serializer};
use std::fmt;

/// A basic stitch by its structure: how many yarn wraps go on the hook before it is inserted, and
/// whether it is finished "half" (one pull through all the loops after the first).
///
/// Only the five basic stitches of v1 can be made ([`Basic::ALL`]): the fields are private so a
/// two-wrap half stitch (`b2h`) or a four-wrap stitch (`b4`) cannot appear by accident. They enter
/// the model when their labels are confirmed by a second source and a crocheter (ADR 0022 sections 2
/// and 24); [`Basic::new`] is the one place that will then accept them.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct Basic {
    wraps: u8,
    half: bool,
}

impl Basic {
    /// No wrap (US single crochet, UK double crochet).
    pub const B0: Basic = Basic {
        wraps: 0,
        half: false,
    };
    /// One wrap, finished half (US half double crochet, UK half treble).
    pub const B1H: Basic = Basic {
        wraps: 1,
        half: true,
    };
    /// One wrap (US double crochet, UK treble).
    pub const B1: Basic = Basic {
        wraps: 1,
        half: false,
    };
    /// Two wraps (US treble, UK double treble).
    pub const B2: Basic = Basic {
        wraps: 2,
        half: false,
    };
    /// Three wraps (US double treble, UK triple treble).
    pub const B3: Basic = Basic {
        wraps: 3,
        half: false,
    };

    /// Every basic stitch of v1, shortest first.
    pub const ALL: [Basic; 5] = [Basic::B0, Basic::B1H, Basic::B1, Basic::B2, Basic::B3];

    /// The basic stitch with this structure, if v1 has it.
    pub const fn new(wraps: u8, half: bool) -> Option<Basic> {
        match (wraps, half) {
            (0, false) | (1, true) | (1, false) | (2, false) | (3, false) => {
                Some(Basic { wraps, half })
            }
            _ => None,
        }
    }

    /// Yarn wraps on the hook before it is inserted.
    pub const fn wraps(self) -> u8 {
        self.wraps
    }

    /// True for a stitch finished with one pull through all its loops (`b1h`).
    pub const fn half(self) -> bool {
        self.half
    }

    /// The identity's own word, as files and tests write it: `b0`, `b1h`, `b1`, `b2`, `b3`.
    pub const fn word(self) -> &'static str {
        match (self.wraps, self.half) {
            (0, _) => "b0",
            (1, true) => "b1h",
            (1, false) => "b1",
            (2, _) => "b2",
            _ => "b3",
        }
    }

    /// The basic stitch named by its identity word (never by a display name such as "sc").
    pub fn from_word(word: &str) -> Option<Basic> {
        Basic::ALL.into_iter().find(|b| b.word() == word)
    }

    /// The starting chain height Ply suggests for a layer that begins with this stitch (ADR 0022
    /// section 7): 1 chain for `b0`, 2 for `b1h`, 3 for `b1`, 4 for `b2`, 5 for `b3`.
    pub const fn suggested_chain_height(self) -> u32 {
        match (self.wraps, self.half) {
            (0, _) => 1,
            (1, true) => 2,
            (w, _) => w as u32 + 2,
        }
    }

    /// Position in [`Basic::ALL`], shortest first.
    pub(crate) const fn index(self) -> usize {
        match (self.wraps, self.half) {
            (0, _) => 0,
            (1, true) => 1,
            (1, false) => 2,
            (2, _) => 3,
            _ => 4,
        }
    }
}

impl fmt::Display for Basic {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.word())
    }
}

impl Serialize for Basic {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(self.word())
    }
}

impl<'de> Deserialize<'de> for Basic {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let word = String::deserialize(d)?;
        Basic::from_word(&word).ok_or_else(|| {
            serde::de::Error::custom(format!(
                "{:?} is not a basic stitch identity (b0, b1h, b1, b2, b3)",
                crate::diagnostic::excerpt(&word, 40)
            ))
        })
    }
}

/// What a slip stitch is for (ADR 0022 sections 2 and 8).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SlipRole {
    /// An ordinary slip stitch: it makes a position the next layer can work into, as in slip-stitch
    /// fabric, and counts as a slip stitch.
    Stitch,
    /// Closes a joined round. Makes no position and is never counted.
    Join,
    /// Moves the hook along the work before a layer's starting chain ("sl st in next ch-2 sp").
    /// Makes no position and is never counted.
    Travel,
}

/// Any operation's identity: what the model stores and a label set names.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Identity {
    Chain,
    Slip,
    Basic(Basic),
    /// `tog(bN x k)`: `legs` legs of `stitch`, finished together into one stitch.
    Together {
        stitch: Basic,
        legs: u32,
    },
}

/// What a stitch counts as in a layer's stitch count (ADR 0022 section 13): a `tog` counts as one
/// stitch of its legs' basic stitch, a counted starting chain as the stitch it counts as, an
/// ordinary slip stitch as a slip stitch. It serializes as its identity word (`"slip"`, `"b0"`,
/// ...), as section 21 writes a stated count by identity (`{"b1": 18, "b0": 6}`), so it can be a
/// map key.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Counted {
    Slip,
    Basic(Basic),
}

impl Serialize for Counted {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(self.word())
    }
}

impl<'de> Deserialize<'de> for Counted {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let word = String::deserialize(d)?;
        Counted::from_word(&word).ok_or_else(|| {
            serde::de::Error::custom(format!(
                "{:?} is not a counted identity (slip, b0, b1h, b1, b2, b3)",
                crate::diagnostic::excerpt(&word, 40)
            ))
        })
    }
}

impl Counted {
    /// The identity word: `slip`, `b0`, `b1h`, `b1`, `b2`, `b3`.
    pub const fn word(self) -> &'static str {
        match self {
            Counted::Slip => "slip",
            Counted::Basic(b) => b.word(),
        }
    }

    /// The counted identity named by its word.
    pub fn from_word(word: &str) -> Option<Counted> {
        if word == "slip" {
            Some(Counted::Slip)
        } else {
            Basic::from_word(word).map(Counted::Basic)
        }
    }

    /// The identity this count names.
    pub const fn identity(self) -> Identity {
        match self {
            Counted::Slip => Identity::Slip,
            Counted::Basic(b) => Identity::Basic(b),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_the_v1_basics_exist() {
        let mut made = Vec::new();
        for wraps in 0..=u8::MAX {
            for half in [false, true] {
                if let Some(b) = Basic::new(wraps, half) {
                    assert_eq!((b.wraps(), b.half()), (wraps, half));
                    made.push(b);
                }
            }
        }
        made.sort();
        let mut all = Basic::ALL.to_vec();
        all.sort();
        assert_eq!(made, all);
        for (i, b) in Basic::ALL.iter().enumerate() {
            assert_eq!(b.index(), i);
            assert_eq!(Basic::from_word(b.word()), Some(*b));
        }
        assert_eq!(
            Basic::from_word("sc"),
            None,
            "a display name is never an identity"
        );
        assert_eq!(Basic::from_word("b2h"), None);
    }

    #[test]
    fn suggested_heights_follow_section_7() {
        let heights: Vec<u32> = Basic::ALL
            .iter()
            .map(|b| b.suggested_chain_height())
            .collect();
        assert_eq!(heights, [1, 2, 3, 4, 5]);
    }
}
