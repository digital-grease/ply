//! Derived and stated stitch counts (ADR 0022 section 13).
//!
//! The **derived count** of a layer lists its stitches by identity (a counted starting chain as the
//! stitch it counts as, a `tog` as one stitch of its legs' basic stitch, an ordinary slip stitch as a
//! slip stitch, a foundation stitch as its basic stitch), its spaces by chain length, and the stitch
//! positions opaque items made, which Ply does not check ("1 not checked"). Spaces are never
//! stitches. A **stated count** is the author's checksum, compared exactly.

use crate::diagnostic::{CountDiff, CountWhat};
use crate::pattern::StatedCount;
use crate::stitch::Counted;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// A layer's derived count.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
pub struct LayerCount {
    /// Stitches by identity, in the order each identity first appears in work order.
    pub stitches: Vec<(Counted, u32)>,
    /// Spaces as (chain length, how many), in the order each length first appears.
    pub spaces: Vec<(u32, u32)>,
    /// Stitch positions made by opaque instructions (or an opaque layer's stated count): counted as
    /// positions, never as any identity.
    pub not_checked: u32,
}

impl LayerCount {
    /// Every stitch position: the stitches by identity and the opaque positions.
    pub fn total_stitches(&self) -> u64 {
        self.stitches
            .iter()
            .map(|&(_, n)| u64::from(n))
            .sum::<u64>()
            + u64::from(self.not_checked)
    }

    /// Every space.
    pub fn total_spaces(&self) -> u64 {
        self.spaces.iter().map(|&(_, n)| u64::from(n)).sum()
    }

    /// Stitches plus spaces: how many positions the next layer gets.
    pub fn positions(&self) -> u64 {
        self.total_stitches() + self.total_spaces()
    }

    /// How many stitches of one identity.
    pub fn of(&self, counted: Counted) -> u32 {
        self.stitches
            .iter()
            .find(|(c, _)| *c == counted)
            .map_or(0, |&(_, n)| n)
    }

    pub(crate) fn add_stitch(&mut self, counted: Counted) {
        match self.stitches.iter_mut().find(|(c, _)| *c == counted) {
            Some((_, n)) => *n = n.saturating_add(1),
            None => self.stitches.push((counted, 1)),
        }
    }

    /// One more space of `chains` chains (a linear search; `resolve::count_of` uses a map).
    #[cfg(test)]
    pub(crate) fn add_space(&mut self, chains: u32) {
        match self.spaces.iter_mut().find(|(m, _)| *m == chains) {
            Some((_, n)) => *n = n.saturating_add(1),
            None => self.spaces.push((chains, 1)),
        }
    }

    pub(crate) fn add_not_checked(&mut self) {
        self.not_checked = self.not_checked.saturating_add(1);
    }

    /// Every part of `stated` that differs from this count (empty when it is met). `by_identity`,
    /// when given, must equal the count by identity exactly.
    pub fn differences(&self, stated: &StatedCount) -> Vec<CountDiff> {
        let clamp = |n: u64| u32::try_from(n).unwrap_or(u32::MAX);
        let mut out = Vec::new();
        if let Some(s) = stated.stitches {
            let d = clamp(self.total_stitches());
            if s != d {
                out.push(CountDiff {
                    what: CountWhat::Stitches,
                    stated: s,
                    derived: d,
                });
            }
        }
        if let Some(s) = stated.spaces {
            let d = clamp(self.total_spaces());
            if s != d {
                out.push(CountDiff {
                    what: CountWhat::Spaces,
                    stated: s,
                    derived: d,
                });
            }
        }
        if !stated.by_identity.is_empty() {
            let mut keys: BTreeMap<Counted, ()> =
                stated.by_identity.keys().map(|&k| (k, ())).collect();
            for &(c, _) in &self.stitches {
                keys.insert(c, ());
            }
            for c in keys.into_keys() {
                let s = stated.by_identity.get(&c).copied().unwrap_or(0);
                let d = self.of(c);
                if s != d {
                    out.push(CountDiff {
                        what: CountWhat::Identity(c),
                        stated: s,
                        derived: d,
                    });
                }
            }
        }
        out
    }
}

/// How a layer's stated count fared.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum StatedCheck {
    Met,
    /// It differs (a `crochet.count_mismatch` says how).
    Mismatch,
    /// The layer's count is unknown, or it is an opaque layer whose stated count is all Ply has: the
    /// stated count is shown as "cannot be checked", never as met.
    CannotBeChecked,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::stitch::Basic;

    #[test]
    fn counts_keep_first_appearance_order_and_compare_exactly() {
        let mut c = LayerCount::default();
        c.add_stitch(Counted::Basic(Basic::B1));
        c.add_stitch(Counted::Basic(Basic::B0));
        c.add_stitch(Counted::Basic(Basic::B1));
        c.add_space(2);
        c.add_not_checked();
        assert_eq!(
            c.stitches,
            vec![
                (Counted::Basic(Basic::B1), 2),
                (Counted::Basic(Basic::B0), 1)
            ]
        );
        assert_eq!(
            (c.total_stitches(), c.total_spaces(), c.positions()),
            (4, 1, 5)
        );
        assert!(c
            .differences(&StatedCount::stitches(4).with_spaces(1))
            .is_empty());
        let diffs = c.differences(
            &StatedCount::default()
                .with_identity(Counted::Basic(Basic::B1), 2)
                .with_identity(Counted::Slip, 1),
        );
        // b0 is absent from the stated identities, so it differs too.
        assert_eq!(diffs.len(), 2);
        assert!(diffs.contains(&CountDiff {
            what: CountWhat::Identity(Counted::Slip),
            stated: 1,
            derived: 0
        }));
        assert!(diffs.contains(&CountDiff {
            what: CountWhat::Identity(Counted::Basic(Basic::B0)),
            stated: 0,
            derived: 1
        }));
    }
}
