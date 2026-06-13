//! Profile-draft expansion.
//!
//! A **profile draft** is a compressed threading: instead of naming a shaft for every
//! warp end, it records a short sequence of **block** indices, where each block stands for
//! a small reusable **threading unit** (a run of shafts). Expanding repeats each block's
//! unit, in sequence order, to recover the full threading.
//!
//! This is the minimal threading-only form. A treadling profile is the natural analog but
//! is deferred — it adds nothing the threading case does not already demonstrate.

use serde::{Deserialize, Serialize};

use crate::draft::{ShaftId, Threading};

/// A compressed threading: a `sequence` of block indices over a small table of `units`.
/// `sequence[i]` is a 0-based index into `units`, and `units[b]` is the threading unit that
/// block `b` expands to — a list of 1-based shafts, one per end the unit threads.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ProfileDraft {
    /// Block indices (0-based into `units`), in warp order.
    pub sequence: Vec<usize>,
    /// The threading unit each block expands to: a run of 1-based shafts (one shaft per end).
    pub units: Vec<Vec<ShaftId>>,
}

impl ProfileDraft {
    /// Expand the profile into a full [`Threading`]: for each block in `sequence`, emit its
    /// unit's shafts as consecutive ends (each shaft becomes its own single-shaft end
    /// `vec![ShaftId(..)]`), concatenated across the whole sequence.
    ///
    /// An **out-of-range** block index (`>= units.len()`) is **skipped** — it contributes no
    /// ends. Correctness over surprise: a malformed sequence still expands to a coherent
    /// threading rather than panicking or emitting a placeholder end.
    pub fn expand_threading(&self) -> Threading {
        let mut ends: Vec<Vec<ShaftId>> = Vec::new();
        for &block in &self.sequence {
            if let Some(unit) = self.units.get(block) {
                ends.extend(unit.iter().map(|&s| vec![s]));
            }
        }
        Threading(ends)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ids(t: &Threading) -> Vec<Vec<u16>> {
        t.0.iter().map(|r| r.iter().map(|s| s.0).collect()).collect()
    }

    /// An ABA profile over two units concatenates A, B, then A again, end by end.
    #[test]
    fn aba_profile_expands_to_concatenated_ends() {
        let p = ProfileDraft {
            sequence: vec![0, 1, 0],
            units: vec![
                vec![ShaftId(1), ShaftId(2)],
                vec![ShaftId(3), ShaftId(4)],
            ],
        };
        assert_eq!(
            ids(&p.expand_threading()),
            vec![vec![1], vec![2], vec![3], vec![4], vec![1], vec![2]]
        );
    }

    /// No blocks means no ends — the threading is empty.
    #[test]
    fn empty_sequence_expands_to_empty_threading() {
        let p = ProfileDraft {
            sequence: Vec::new(),
            units: vec![vec![ShaftId(1)]],
        };
        assert_eq!(p.expand_threading(), Threading(Vec::new()));
    }

    /// An out-of-range block index is skipped, as if it weren't in the sequence.
    #[test]
    fn out_of_range_block_is_skipped() {
        let p = ProfileDraft {
            sequence: vec![0, 9, 0],
            units: vec![vec![ShaftId(1), ShaftId(2)]],
        };
        assert_eq!(
            ids(&p.expand_threading()),
            vec![vec![1], vec![2], vec![1], vec![2]]
        );
    }
}
