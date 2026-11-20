//! Size budgets (ADR 0022 section 20). Sizes come from untrusted files and FFI calls: every count is
//! checked against these with checked (saturating) arithmetic before anything proportional to it is
//! allocated, and resolution stops with `crochet.too_large` the moment a budget would be passed,
//! never with a panic or an unbounded loop.

/// Size budgets for a crochet pattern.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct CrochetLimits {
    /// Most layers in a piece.
    pub max_layers: usize,
    /// Most instructions in one layer, counting every instruction inside its repeats.
    pub max_instructions_per_layer: usize,
    /// Most instructions in a document: every layer's and every legend body's.
    pub max_instructions: usize,
    /// Deepest nesting of repeats in one instruction list.
    pub max_repeat_depth: usize,
    /// Deepest nesting of named stitches (a named stitch whose body uses another counts 2).
    pub max_named_depth: usize,
    /// Most items (stitches, chain runs, a starting chain) one layer may make.
    pub max_items_per_layer: u32,
    /// Most items a whole piece may make.
    pub max_items: u64,
    /// Most chains in one run, one starting chain or a chain ring.
    pub max_run_chains: u32,
    /// Most chains in a foundation chain.
    pub max_foundation_chains: u32,
    /// Most stitches into one target (`n`).
    pub max_n: u32,
    /// Most legs of one `tog` (at least 2 are always required).
    pub max_legs: u32,
    /// Most markers placed in a piece.
    pub max_markers: usize,
    /// Most legend entries.
    pub max_legend_entries: usize,
    /// Most bytes in one text field (a name, a note, an opaque instruction's words, an id).
    pub max_text_bytes: usize,
    /// Most instruction steps (and walked positions) resolving one layer may take, failed tries of
    /// a repeat included: a bound on time for patterns whose sizes are each within the limits.
    pub max_steps_per_layer: u64,
    /// Most diagnostics listed for one code; the rest are counted in one `crochet.list_capped` item.
    pub max_diagnostics_per_code: usize,
}

/// Most layers ([`CrochetLimits::DEFAULT`]).
pub const MAX_LAYERS: usize = 20_000;
/// Most instructions per layer ([`CrochetLimits::DEFAULT`]).
pub const MAX_INSTRUCTIONS_PER_LAYER: usize = 10_000;
/// Most instructions per document ([`CrochetLimits::DEFAULT`]).
pub const MAX_INSTRUCTIONS: usize = 1_000_000;
/// Deepest repeat nesting ([`CrochetLimits::DEFAULT`]).
pub const MAX_REPEAT_DEPTH: usize = 8;
/// Deepest named stitch nesting ([`CrochetLimits::DEFAULT`]).
pub const MAX_NAMED_DEPTH: usize = 8;
/// Most items per layer ([`CrochetLimits::DEFAULT`]).
pub const MAX_ITEMS_PER_LAYER: u32 = 100_000;
/// Most items per piece: the knitting cap (`ply_knit::calc::MAX_STITCHES`).
pub const MAX_ITEMS: u64 = 1_000_000;
/// Most chains per run ([`CrochetLimits::DEFAULT`]).
pub const MAX_RUN_CHAINS: u32 = 10_000;
/// Most chains in a foundation chain ([`CrochetLimits::DEFAULT`]).
pub const MAX_FOUNDATION_CHAINS: u32 = 100_000;
/// Most stitches into one target ([`CrochetLimits::DEFAULT`]).
pub const MAX_N: u32 = 1_000;
/// Most legs of a `tog` ([`CrochetLimits::DEFAULT`]).
pub const MAX_LEGS: u32 = 8;
/// Most markers ([`CrochetLimits::DEFAULT`]).
pub const MAX_MARKERS: usize = 1_000;
/// Most legend entries ([`CrochetLimits::DEFAULT`]).
pub const MAX_LEGEND_ENTRIES: usize = 512;
/// Most bytes in one text field ([`CrochetLimits::DEFAULT`]).
pub const MAX_TEXT_BYTES: usize = 10_000;
/// Most steps resolving one layer ([`CrochetLimits::DEFAULT`]).
pub const MAX_STEPS_PER_LAYER: u64 = 4_000_000;
/// Most diagnostics listed per code ([`CrochetLimits::DEFAULT`]).
pub const MAX_DIAGNOSTICS_PER_CODE: usize = 1_000;

/// The deepest nesting [`CrochetLimits::unsound`] accepts for repeats and for named stitches, so
/// resolving the deepest allowed pattern stays far inside a 2 MiB thread stack.
pub const MAX_SOUND_DEPTH: usize = 16;

impl CrochetLimits {
    /// The phone budget (ADR 0022 section 20).
    pub const DEFAULT: CrochetLimits = CrochetLimits {
        max_layers: MAX_LAYERS,
        max_instructions_per_layer: MAX_INSTRUCTIONS_PER_LAYER,
        max_instructions: MAX_INSTRUCTIONS,
        max_repeat_depth: MAX_REPEAT_DEPTH,
        max_named_depth: MAX_NAMED_DEPTH,
        max_items_per_layer: MAX_ITEMS_PER_LAYER,
        max_items: MAX_ITEMS,
        max_run_chains: MAX_RUN_CHAINS,
        max_foundation_chains: MAX_FOUNDATION_CHAINS,
        max_n: MAX_N,
        max_legs: MAX_LEGS,
        max_markers: MAX_MARKERS,
        max_legend_entries: MAX_LEGEND_ENTRIES,
        max_text_bytes: MAX_TEXT_BYTES,
        max_steps_per_layer: MAX_STEPS_PER_LAYER,
        max_diagnostics_per_code: MAX_DIAGNOSTICS_PER_CODE,
    };

    /// Why these limits cannot be used, if they cannot. Recursion follows repeats and named
    /// stitches, so their depths are bounded; a `tog` always has at least 2 legs; layer positions are
    /// numbered with `u32`.
    pub fn unsound(&self) -> Option<&'static str> {
        if self.max_repeat_depth > MAX_SOUND_DEPTH {
            Some("max_repeat_depth passes 16, so resolving could exhaust the stack")
        } else if self.max_named_depth > MAX_SOUND_DEPTH {
            Some("max_named_depth passes 16, so resolving could exhaust the stack")
        } else if self.max_legs < 2 {
            Some("max_legs is under 2, so no tog could be made")
        } else if u32::try_from(self.max_layers).is_err() {
            Some("max_layers passes u32::MAX, so layers could not be numbered")
        } else if self.max_diagnostics_per_code == 0 {
            Some("max_diagnostics_per_code is 0, so no problem could be listed")
        } else {
            None
        }
    }
}

impl Default for CrochetLimits {
    fn default() -> Self {
        CrochetLimits::DEFAULT
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_default_limits_are_sound_and_follow_section_20() {
        let l = CrochetLimits::DEFAULT;
        assert_eq!(l.unsound(), None);
        assert_eq!(
            (
                l.max_layers,
                l.max_instructions_per_layer,
                l.max_repeat_depth
            ),
            (20_000, 10_000, 8)
        );
        assert_eq!((l.max_items_per_layer, l.max_items), (100_000, 1_000_000));
        assert_eq!(
            (l.max_run_chains, l.max_foundation_chains),
            (10_000, 100_000)
        );
        assert_eq!((l.max_n, l.max_legs, l.max_markers), (1_000, 8, 1_000));
        assert_eq!((l.max_legend_entries, l.max_text_bytes), (512, 10_000));
        let deep = CrochetLimits {
            max_repeat_depth: 17,
            ..l
        };
        assert!(deep.unsound().is_some());
        let no_legs = CrochetLimits { max_legs: 1, ..l };
        assert!(no_legs.unsound().is_some());
    }
}
