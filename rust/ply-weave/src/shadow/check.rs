//! Structural tests that tell authentic shadow weave from look-alikes.
//!
//! Each test is measured on the cloth or on the raised shafts per pick, never on tie-up text, so
//! treadle order, shed direction and Atwater or Powell numbering make no difference.
//!
//! * **T1** Warp and weft colors alternate strictly: no two neighboring threads share a color.
//! * **T2** The shafts pair up: an even count of at least 4, and every lift raises exactly one
//!   shaft of each pair ([`lift_pairing`]).
//! * **T3** Every end lies beside an end that always does the opposite (its partner), and every
//!   pick lies beside a pick with the opposite shed (its shadow pick).
//! * **T4** No float is longer than two threads, on either face, in either direction, and at least
//!   one two-thread float exists.
//! * **T5** Every block region is at least two threads each way and plain weave.
//! * **T6** With the colors replaced by a strict dark and light alternation, the regions still show
//!   both horizontal and vertical lines: the pattern lives in the structure, not in the colors.
//!
//! Log cabin fails T1, because its pattern comes from placing two like colors side by side, and
//! then T2 (on 2 shafts) or T3 and T5 (on a twill ground). A one-and-one color-and-weave on an
//! ordinary twill fails T3: in a straight draw no end lies beside the shaft that always does the
//! opposite.
//!
//! **Block regions.** Two neighboring ends belong to the same block when, read as dark and light
//! threads by their position (even positions dark), their interlacement columns agree: in other
//! words when the two ends always do the opposite of each other. Runs of such ends are the warp
//! blocks; picks are grouped the same way by rows. Treadled as drawn in, these are exactly the
//! blocks of the design, and every region of one warp block and one weft block is plain weave.
//! Blocks the treadling never separates (a weft woven only on the plain-weave pair of treadles, for
//! example) interlace identically, so read from the cloth alone they form one region.
//!
//! `cyclic` measures across the repeat join, so pass exactly one repeat. Without it the draft is a
//! finished piece and its first and last threads are edges. Every check computes the whole
//! interlacement, one cell per intersection, so use them on drafts of a sensible size.

use crate::draft::{ColorIndex, Draft, ShaftId};
use crate::drawdown::{compute, Cell};

use super::Lines;

/// The interlacement and the color shown at every intersection.
struct Cloth {
    ends: usize,
    picks: usize,
    /// `[pick * ends + end]`: the warp is over the weft on the face.
    up: Vec<bool>,
    shown: Vec<ColorIndex>,
}

impl Cloth {
    fn of(draft: &Draft) -> Cloth {
        let dd = compute(draft);
        Cloth {
            ends: dd.ends,
            picks: dd.picks,
            up: dd
                .cells
                .iter()
                .map(|c| matches!(c, Cell::WarpUp(_)))
                .collect(),
            shown: dd
                .cells
                .iter()
                .map(|c| match c {
                    Cell::WarpUp(i) | Cell::WeftUp(i) => *i,
                })
                .collect(),
        }
    }

    fn up(&self, end: usize, pick: usize) -> bool {
        self.up[pick * self.ends + end]
    }

    /// Ends `a` and `b` are opposite on every pick.
    fn opposite_ends(&self, a: usize, b: usize) -> bool {
        (0..self.picks).all(|p| self.up(a, p) != self.up(b, p))
    }

    /// Picks `a` and `b` are opposite on every end.
    fn opposite_picks(&self, a: usize, b: usize) -> bool {
        (0..self.ends).all(|e| self.up(e, a) != self.up(e, b))
    }

    /// Ends `a` and `b` belong to one block: read as dark/light by position, their columns agree.
    fn same_warp_block(&self, a: usize, b: usize) -> bool {
        let flip = (a % 2) != (b % 2);
        (0..self.picks).all(|p| (self.up(a, p) != self.up(b, p)) == flip)
    }

    /// Picks `a` and `b` belong to one block, read the same way by rows.
    fn same_weft_block(&self, a: usize, b: usize) -> bool {
        let flip = (a % 2) != (b % 2);
        (0..self.ends).all(|e| (self.up(e, a) != self.up(e, b)) == flip)
    }
}

/// The neighbors of thread `i` of `len`: the previous and next threads, wrapping when `cyclic`.
fn neighbors(i: usize, len: usize, cyclic: bool) -> impl Iterator<Item = usize> {
    let prev = if i > 0 {
        Some(i - 1)
    } else if cyclic && len > 1 {
        Some(len - 1)
    } else {
        None
    };
    let next = if i + 1 < len {
        Some(i + 1)
    } else if cyclic && len > 1 {
        Some(0)
    } else {
        None
    };
    prev.into_iter().chain(next)
}

/// **T1.** No two neighboring threads share a color. A cyclic sequence of odd length always fails,
/// since its two ends meet.
pub fn colors_alternate(colors: &[ColorIndex], cyclic: bool) -> bool {
    let n = colors.len();
    if n < 2 {
        return true;
    }
    let pairs = if cyclic { n } else { n - 1 };
    (0..pairs).all(|i| colors[i] != colors[(i + 1) % n])
}

/// **T2.** The partner of every shaft (`partners[s - 1]` for shaft `s`) when the shaft count is
/// even and at least 4 and every pick raises exactly one shaft of each pair; `None` otherwise.
/// Shafts that rise together on every pick are interchangeable, and they are paired in order.
pub fn lift_pairing(draft: &Draft) -> Option<Vec<u16>> {
    let n = draft.shafts;
    if n < 4 || !n.is_multiple_of(2) || draft.picks() == 0 {
        return None;
    }
    let lifts: Vec<Vec<ShaftId>> = (0..draft.picks()).map(|p| draft.raised_shafts(p)).collect();
    let raised = |s: u16, p: usize| lifts[p].contains(&ShaftId(s));
    let opposite = |a: u16, b: u16| (0..lifts.len()).all(|p| raised(a, p) != raised(b, p));
    let mut partners = vec![0u16; usize::from(n)];
    for s in 1..=n {
        if partners[usize::from(s - 1)] != 0 {
            continue;
        }
        let t = (s + 1..=n).find(|&t| partners[usize::from(t - 1)] == 0 && opposite(s, t))?;
        partners[usize::from(s - 1)] = t;
        partners[usize::from(t - 1)] = s;
    }
    Some(partners)
}

/// **T3, warp.** Every end has a neighbor end that is opposite on every pick.
pub fn ends_beside_partner(draft: &Draft, cyclic: bool) -> bool {
    let cloth = Cloth::of(draft);
    ends_paired(&cloth, cyclic)
}

/// **T3, weft.** Every pick has a neighbor pick that is opposite on every end.
pub fn picks_beside_shadow(draft: &Draft, cyclic: bool) -> bool {
    let cloth = Cloth::of(draft);
    picks_paired(&cloth, cyclic)
}

fn ends_paired(cloth: &Cloth, cyclic: bool) -> bool {
    (0..cloth.ends).all(|e| neighbors(e, cloth.ends, cyclic).any(|o| cloth.opposite_ends(e, o)))
}

fn picks_paired(cloth: &Cloth, cyclic: bool) -> bool {
    (0..cloth.picks).all(|p| neighbors(p, cloth.picks, cyclic).any(|o| cloth.opposite_picks(p, o)))
}

/// The longest floats, counting both faces: along a pick (`weft`, threads the weft passes over or
/// under at once) and along an end (`warp`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Floats {
    pub weft: usize,
    pub warp: usize,
}

/// The longest run of equal values among `len` values, wrapping when `cyclic`.
fn longest_run(len: usize, cyclic: bool, get: impl Fn(usize) -> bool) -> usize {
    if len == 0 {
        return 0;
    }
    let first = get(0);
    if (1..len).all(|i| get(i) == first) {
        return len;
    }
    let total = if cyclic { 2 * len } else { len };
    let (mut best, mut current, mut prev) = (0, 0, None);
    for i in 0..total {
        let v = get(i % len);
        if Some(v) == prev {
            current += 1;
        } else {
            current = 1;
            prev = Some(v);
        }
        best = usize::max(best, current);
    }
    best.min(len)
}

fn floats_of(cloth: &Cloth, cyclic: bool) -> Floats {
    let weft = (0..cloth.picks)
        .map(|p| longest_run(cloth.ends, cyclic, |e| cloth.up(e, p)))
        .max()
        .unwrap_or(0);
    let warp = (0..cloth.ends)
        .map(|e| longest_run(cloth.picks, cyclic, |p| cloth.up(e, p)))
        .max()
        .unwrap_or(0);
    Floats { weft, warp }
}

/// **T4.** The longest floats of the cloth.
pub fn longest_floats(draft: &Draft, cyclic: bool) -> Floats {
    floats_of(&Cloth::of(draft), cyclic)
}

/// A run of consecutive threads: `start`, then the next `len - 1` (wrapping past the last thread
/// when the regions were measured cyclically).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Run {
    pub start: usize,
    pub len: usize,
}

/// The block regions of a draft (see the module docs).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BlockRegions {
    pub warp_runs: Vec<Run>,
    pub weft_runs: Vec<Run>,
    /// `lines[weft run][warp run]`: the lines each region shows.
    pub lines: Vec<Vec<Lines>>,
    /// `plain[weft run][warp run]`: the region is plain weave.
    pub plain: Vec<Vec<bool>>,
}

impl BlockRegions {
    /// **T5.** Every region is at least 2 by 2 and plain weave.
    pub fn all_plain(&self) -> bool {
        self.warp_runs.iter().all(|r| r.len >= 2)
            && self.weft_runs.iter().all(|r| r.len >= 2)
            && self.plain.iter().flatten().all(|&p| p)
    }

    /// Some region shows horizontal lines and some region vertical lines.
    pub fn shows_both_lines(&self) -> bool {
        let all = || self.lines.iter().flatten();
        all().any(|&l| l == Lines::Horizontal) && all().any(|&l| l == Lines::Vertical)
    }
}

/// Split `len` threads into runs where `same(previous, next)` holds between neighbors.
fn runs(len: usize, cyclic: bool, same: impl Fn(usize, usize) -> bool) -> Vec<Run> {
    if len == 0 {
        return Vec::new();
    }
    let starts: Vec<usize> = (0..len)
        .filter(|&i| {
            if i == 0 {
                !cyclic || !same(len - 1, 0)
            } else {
                !same(i - 1, i)
            }
        })
        .collect();
    if starts.is_empty() {
        return vec![Run { start: 0, len }];
    }
    starts
        .iter()
        .enumerate()
        .map(|(k, &start)| {
            let end = match starts.get(k + 1) {
                Some(&next) => next,
                None if cyclic => starts[0] + len,
                None => len,
            };
            Run {
                start,
                len: end - start,
            }
        })
        .collect()
}

fn indices(run: Run, total: usize) -> Vec<usize> {
    (run.start..run.start + run.len)
        .map(|i| i % total)
        .collect()
}

fn regions(
    cloth: &Cloth,
    cyclic: bool,
    shown: impl Fn(usize, usize) -> ColorIndex,
) -> BlockRegions {
    let warp_runs = runs(cloth.ends, cyclic, |a, b| cloth.same_warp_block(a, b));
    let weft_runs = runs(cloth.picks, cyclic, |a, b| cloth.same_weft_block(a, b));
    let ends: Vec<Vec<usize>> = warp_runs.iter().map(|&r| indices(r, cloth.ends)).collect();
    let picks: Vec<Vec<usize>> = weft_runs.iter().map(|&r| indices(r, cloth.picks)).collect();
    let mut lines = Vec::with_capacity(picks.len());
    let mut plain = Vec::with_capacity(picks.len());
    for ps in &picks {
        let mut line_row = Vec::with_capacity(ends.len());
        let mut plain_row = Vec::with_capacity(ends.len());
        for es in &ends {
            let rows_uniform = ps
                .iter()
                .all(|&p| es.iter().all(|&e| shown(e, p) == shown(es[0], p)));
            let columns_uniform = es
                .iter()
                .all(|&e| ps.iter().all(|&p| shown(e, p) == shown(e, ps[0])));
            line_row.push(match (rows_uniform, columns_uniform) {
                (true, false) => Lines::Horizontal,
                (false, true) => Lines::Vertical,
                (true, true) => Lines::Uniform,
                (false, false) => Lines::Mixed,
            });
            let across = es
                .windows(2)
                .all(|w| ps.iter().all(|&p| cloth.up(w[0], p) != cloth.up(w[1], p)));
            let down = ps
                .windows(2)
                .all(|w| es.iter().all(|&e| cloth.up(e, w[0]) != cloth.up(e, w[1])));
            plain_row.push(across && down);
        }
        lines.push(line_row);
        plain.push(plain_row);
    }
    BlockRegions {
        warp_runs,
        weft_runs,
        lines,
        plain,
    }
}

/// The block regions of `draft`, with the lines read from its own colors.
pub fn block_regions(draft: &Draft, cyclic: bool) -> BlockRegions {
    let cloth = Cloth::of(draft);
    regions(&cloth, cyclic, |e, p| cloth.shown[p * cloth.ends + e])
}

/// The block regions of `draft` with its colors replaced by a strict alternation (even ends and
/// picks dark), the normalization of **T6**.
pub fn normalized_block_regions(draft: &Draft, cyclic: bool) -> BlockRegions {
    normalized_regions(&Cloth::of(draft), cyclic)
}

fn normalized_regions(cloth: &Cloth, cyclic: bool) -> BlockRegions {
    regions(cloth, cyclic, |e, p| {
        let dark = if cloth.up(e, p) {
            e % 2 == 0
        } else {
            p % 2 == 0
        };
        ColorIndex::from(dark)
    })
}

/// The outcome of every structural test on one draft.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StructureReport {
    /// T1, warp.
    pub warp_alternates: bool,
    /// T1, weft.
    pub weft_alternates: bool,
    /// T2: the partner of each shaft, if the lifts pair the shafts up.
    pub partners: Option<Vec<u16>>,
    /// T3, warp.
    pub ends_beside_partner: bool,
    /// T3, weft.
    pub picks_beside_shadow: bool,
    /// T4.
    pub floats: Floats,
    /// T5.
    pub regions_plain: bool,
    /// T6.
    pub lines_from_structure: bool,
}

impl StructureReport {
    /// T4: no float longer than 2, and at least one of exactly 2.
    pub fn floats_ok(&self) -> bool {
        self.floats.weft <= 2
            && self.floats.warp <= 2
            && self.floats.weft.max(self.floats.warp) == 2
    }

    /// Every test passes: the draft is authentic shadow weave.
    pub fn is_shadow_weave(&self) -> bool {
        self.warp_alternates
            && self.weft_alternates
            && self.partners.is_some()
            && self.ends_beside_partner
            && self.picks_beside_shadow
            && self.floats_ok()
            && self.regions_plain
            && self.lines_from_structure
    }
}

/// Run every structural test on `draft`.
pub fn report(draft: &Draft, cyclic: bool) -> StructureReport {
    let cloth = Cloth::of(draft);
    let normalized = normalized_regions(&cloth, cyclic);
    StructureReport {
        warp_alternates: colors_alternate(&draft.colors.warp, cyclic),
        weft_alternates: colors_alternate(&draft.colors.weft, cyclic),
        partners: lift_pairing(draft),
        ends_beside_partner: ends_paired(&cloth, cyclic),
        picks_beside_shadow: picks_paired(&cloth, cyclic),
        floats: floats_of(&cloth, cyclic),
        regions_plain: normalized.all_plain(),
        lines_from_structure: normalized.shows_both_lines(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn alternation_wraps_only_when_cyclic() {
        assert!(colors_alternate(&[1, 0, 1, 0], true));
        assert!(colors_alternate(&[1, 0, 1], false));
        assert!(
            !colors_alternate(&[1, 0, 1], true),
            "odd cycle: the ends meet"
        );
        assert!(!colors_alternate(&[1, 0, 0, 1], false));
        assert!(colors_alternate(&[], true));
    }

    #[test]
    fn runs_merge_across_the_join_when_cyclic() {
        // Blocks a a b b a: cyclically the last a joins the first two.
        let keys = ['a', 'a', 'b', 'b', 'a'];
        let same = |x: usize, y: usize| keys[x] == keys[y];
        assert_eq!(
            runs(5, true, same),
            vec![Run { start: 2, len: 2 }, Run { start: 4, len: 3 }]
        );
        assert_eq!(
            runs(5, false, same),
            vec![
                Run { start: 0, len: 2 },
                Run { start: 2, len: 2 },
                Run { start: 4, len: 1 }
            ]
        );
        assert_eq!(runs(3, true, |_, _| true), vec![Run { start: 0, len: 3 }]);
    }

    #[test]
    fn longest_run_counts_the_wrap() {
        let v = [true, false, false, true, true];
        assert_eq!(longest_run(5, false, |i| v[i]), 2);
        assert_eq!(longest_run(5, true, |i| v[i]), 3);
        assert_eq!(longest_run(3, true, |_| true), 3);
    }
}
