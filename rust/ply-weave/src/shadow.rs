//! Shadow weave in the Atwater and Powell systems.
//!
//! Shadow weave is a block weave made by the threading, not by the color order. Warp and weft both
//! alternate a dark and a light thread one by one, everywhere. Each dark end has a light "shadow"
//! end beside it on its partner shaft, and every lift raises exactly one shaft of each partner pair,
//! so the cloth is plain weave inside every block. Where two blocks meet, the only irregularity is
//! a skip over two threads. With the twill tie-up and the weft treadled as drawn in, each block
//! shows fine horizontal or vertical lines, and half of the blocks show each at any time.
//!
//! Two numbering systems describe the same cloth:
//!
//! * **Atwater** puts each shaft's partner half the loom away (1-3 and 2-4 on 4 shafts; 1-5, 2-6,
//!   3-7 and 4-8 on 8) and ties up the balanced straight twill (2/2 on 4 shafts, 4/4 on 8).
//! * **Powell** renumbers the shafts so that partners are neighbors (1-2, 3-4, ...) and applies the
//!   same renumbering to the tie-up. On 4 shafts that is exchanging shafts 2 and 3 and treadles 2
//!   and 3.
//!
//! For the same design both systems weave identical cloth, cell for cell; [`atwater_to_powell`] is
//! the renumbering. Only 4 and 8 shafts are offered, the counts the published sources document.
//!
//! A design is a sequence of blocks with a width in **units** (one dark and one light thread of the
//! block, side by side), laid out as a straight repeat or as a point (the sequence, then back again).
//! The point layout keeps each turning block's shadow inside it, so floats never exceed two threads.
//! Sizes are whole repeats, plus an optional balancing end and pick; a unit is never cut in half.
//!
//! [`check`] holds the structural tests that tell authentic shadow weave from look-alikes such as
//! log cabin (plain weave whose pattern comes from breaking the color alternation).

pub mod check;

use std::fmt;

use ply_common::Unit;

use crate::draft::{
    ColorIndex, ColorPlan, Draft, Drive, ShaftId, ShedType, Threading, TieUp, TreadleId, Treadling,
};
use crate::structure::{DARK, LIGHT};
use crate::wif::MAX_THREADS;

/// Palette index of the light ("shadow") color in a generated draft.
pub const LIGHT_COLOR: ColorIndex = 0;
/// Palette index of the dark ("pattern") color in a generated draft.
pub const DARK_COLOR: ColorIndex = 1;

/// Which shaft numbering the draft uses. The cloth is the same in both.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum ShadowSystem {
    /// Partners half the loom apart, with the straight twill tie-up.
    #[default]
    Atwater,
    /// Partners on neighboring shafts, with the renumbered twill tie-up.
    Powell,
}

impl ShadowSystem {
    /// The system's name as weavers write it.
    pub fn name(self) -> &'static str {
        match self {
            ShadowSystem::Atwater => "Atwater",
            ShadowSystem::Powell => "Powell",
        }
    }
}

/// The supported shaft counts. Other counts are not offered: no accessible source documents them.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum ShadowShafts {
    #[default]
    Four,
    Eight,
}

impl ShadowShafts {
    /// The number of shafts (also the number of treadles and of blocks).
    pub const fn count(self) -> u16 {
        match self {
            ShadowShafts::Four => 4,
            ShadowShafts::Eight => 8,
        }
    }

    /// The number of blocks: each partner pair gives two (dark on either shaft).
    pub const fn blocks(self) -> u16 {
        self.count()
    }

    /// Half the shaft count: the number of partner pairs and of shafts in each lift.
    pub const fn pairs(self) -> u16 {
        self.count() / 2
    }
}

impl TryFrom<u16> for ShadowShafts {
    type Error = ShadowError;

    fn try_from(shafts: u16) -> Result<Self, Self::Error> {
        match shafts {
            4 => Ok(ShadowShafts::Four),
            8 => Ok(ShadowShafts::Eight),
            other => Err(ShadowError::UnsupportedShafts(other)),
        }
    }
}

/// How the block sequence is laid out across one repeat.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum ShadowLayout {
    /// The sequence as given, repeated: `2 * units` threads per repeat.
    Repeat,
    /// The sequence is half of a point: it runs forward, then mirrors back without repeating the
    /// turning threads, giving `4 * units - 2` threads per repeat. The first block becomes a turning
    /// run centered on its dark thread and the last one centered on its light thread, so each keeps
    /// its shadow and floats stay at two threads.
    #[default]
    Point,
}

/// Which way the twill in the tie-up runs. Both appear in published drafts; they change which
/// neighboring blocks show the same lines, not whether the cloth is shadow weave.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum TwillDirection {
    /// Atwater treadle `t` raises shafts `t, t+1, ...` (wrapping). The usual direction.
    #[default]
    Forward,
    /// Atwater treadle `t` raises shafts `t, t-1, ...` (wrapping).
    Reverse,
}

/// The weft color order relative to the treadling.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum WeftPhase {
    /// Each pick has the color of the thread it is treadled from: the dark pick goes on the dark
    /// thread's treadle. Block edges look smooth.
    #[default]
    Standard,
    /// The weft colors are swapped within every pick pair. The interlacement is unchanged, every
    /// region trades horizontal for vertical lines, and block edges look feathery.
    Swapped,
}

/// The two thread roles. They are roles, not fixed colors: the palette can be edited freely.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Role {
    /// The pattern thread, on the block's own shaft.
    Dark,
    /// The shadow thread, on the partner shaft.
    Light,
}

/// One thread of an expanded sequence: the shaft it is threaded on (for a pick, the treadle it is
/// woven on, which has the same number when treadled as drawn in) and its role.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Thread {
    pub shaft: u16,
    pub role: Role,
}

/// One entry of a block sequence.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct ShadowBlock {
    /// 0-based block index (0 = A). Must be below the shaft count.
    pub block: u16,
    /// Width in units (one dark and one light thread). At least 1.
    pub units: u16,
}

/// Everything the generator needs. The weft is always treadled as drawn in (tromp as writ).
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct ShadowParams {
    pub system: ShadowSystem,
    pub shafts: ShadowShafts,
    pub layout: ShadowLayout,
    /// The block sequence for one repeat (for [`ShadowLayout::Point`], the first half of it).
    pub blocks: Vec<ShadowBlock>,
    pub direction: TwillDirection,
    pub weft_phase: WeftPhase,
    /// Whole threading repeats across the warp. At least 1.
    pub warp_repeats: u16,
    /// Whole treadling repeats up the weft. At least 1.
    pub weft_repeats: u16,
    /// Weave the first end and the first pick once more at the end, so the draft closes the way it
    /// opened (for a point layout, the whole warp and weft become mirror images of themselves).
    pub balance: bool,
}

impl Default for ShadowParams {
    /// Atwater, 4 shafts, a point of A2 B2 C2 D2, standard tie-up and weft order, two repeats each
    /// way, balanced.
    fn default() -> Self {
        ShadowParams {
            system: ShadowSystem::Atwater,
            shafts: ShadowShafts::Four,
            layout: ShadowLayout::Point,
            blocks: (0..4)
                .map(|block| ShadowBlock { block, units: 2 })
                .collect(),
            direction: TwillDirection::Forward,
            weft_phase: WeftPhase::Standard,
            warp_repeats: 2,
            weft_repeats: 2,
            balance: true,
        }
    }
}

/// Why a shadow-weave request was refused. Nothing is clamped or guessed: every invalid parameter
/// is reported.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ShadowError {
    /// Only 4 and 8 shafts are supported.
    UnsupportedShafts(u16),
    /// The block sequence is empty.
    NoBlocks,
    /// Entry `index` (0-based) names a block the shaft count does not have.
    BlockOutOfRange {
        index: usize,
        block: u16,
        blocks: u16,
    },
    /// Entry `index` (0-based) has a width of 0 units.
    ZeroUnits { index: usize },
    /// The sequence uses only one block, which is plain weave with no pattern.
    SingleBlock,
    /// A warp or weft repeat count is 0.
    ZeroRepeats,
    /// The draft would exceed the per-axis document cap ([`MAX_THREADS`]).
    TooLarge { ends: usize, picks: usize },
}

impl fmt::Display for ShadowError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ShadowError::UnsupportedShafts(n) => {
                write!(f, "shadow weave needs 4 or 8 shafts, not {n}")
            }
            ShadowError::NoBlocks => write!(f, "the design has no blocks"),
            ShadowError::BlockOutOfRange {
                index,
                block,
                blocks,
            } => write!(
                f,
                "block entry {} is block number {}, but {blocks} shafts give blocks A to {}",
                index + 1,
                u32::from(*block) + 1,
                block_letter(blocks.saturating_sub(1))
            ),
            ShadowError::ZeroUnits { index } => write!(
                f,
                "block entry {} has no units; each block needs at least 1",
                index + 1
            ),
            ShadowError::SingleBlock => write!(
                f,
                "the design uses a single block; shadow weave needs at least two"
            ),
            ShadowError::ZeroRepeats => {
                write!(f, "warp and weft repeats must each be at least 1")
            }
            ShadowError::TooLarge { ends, picks } => write!(
                f,
                "the design needs {ends} ends and {picks} picks; a draft allows at most {MAX_THREADS} of each"
            ),
        }
    }
}

impl std::error::Error for ShadowError {}

/// The letter weavers use for 0-based block `block` (A, B, C, ...). Past Z it is `?`.
pub fn block_letter(block: u16) -> char {
    if block < 26 {
        char::from(b'A' + block as u8)
    } else {
        '?'
    }
}

/// The Atwater-to-Powell renumbering of a shaft (1-based): Atwater shafts `1..=n` go to the odd
/// Powell shafts and `n+1..=2n` to the even ones, so Atwater partners `s` and `s + n` land side by
/// side. On 4 shafts it exchanges 2 and 3; on 8 it maps 1..8 to 1 3 5 7 2 4 6 8.
///
/// # Panics
/// If `shaft` is not in `1..=shafts.count()`.
pub fn atwater_to_powell(shafts: ShadowShafts, shaft: u16) -> u16 {
    check_shaft(shafts, shaft);
    let n = shafts.pairs();
    if shaft <= n {
        2 * shaft - 1
    } else {
        2 * (shaft - n)
    }
}

/// The inverse of [`atwater_to_powell`].
///
/// # Panics
/// If `shaft` is not in `1..=shafts.count()`.
pub fn powell_to_atwater(shafts: ShadowShafts, shaft: u16) -> u16 {
    check_shaft(shafts, shaft);
    if shaft % 2 == 1 {
        shaft.div_ceil(2)
    } else {
        shaft / 2 + shafts.pairs()
    }
}

fn check_shaft(shafts: ShadowShafts, shaft: u16) {
    assert!(
        (1..=shafts.count()).contains(&shaft),
        "shaft {shaft} is outside 1..={}",
        shafts.count()
    );
}

/// The partner ("shadow") shaft of `shaft` (1-based): `shaft + n` (wrapping) in Atwater, the
/// neighbor of the same pair (1-2, 3-4, ...) in Powell.
///
/// # Panics
/// If `shaft` is not in `1..=shafts.count()`.
pub fn partner(system: ShadowSystem, shafts: ShadowShafts, shaft: u16) -> u16 {
    check_shaft(shafts, shaft);
    match system {
        ShadowSystem::Atwater => (shaft - 1 + shafts.pairs()) % shafts.count() + 1,
        ShadowSystem::Powell => {
            if shaft % 2 == 1 {
                shaft + 1
            } else {
                shaft - 1
            }
        }
    }
}

/// The (dark, light) shafts of 0-based block `block`. Atwater block b has its dark thread on
/// shaft b+1 and its light thread on the partner (A = 1 and 3, B = 2 and 4, C = 3 and 1, D = 4 and
/// 2 on 4 shafts). Powell blocks are the same blocks renumbered (A = 1 and 2, B = 3 and 4, C = 2
/// and 1, D = 4 and 3 on 4 shafts, the letter order of Powell's own book).
///
/// # Panics
/// If `block` is not below `shafts.blocks()`.
pub fn block_shafts(system: ShadowSystem, shafts: ShadowShafts, block: u16) -> (u16, u16) {
    assert!(
        block < shafts.blocks(),
        "block {block} is outside 0..{}",
        shafts.blocks()
    );
    let dark = block + 1;
    let light = partner(ShadowSystem::Atwater, shafts, dark);
    match system {
        ShadowSystem::Atwater => (dark, light),
        ShadowSystem::Powell => (
            atwater_to_powell(shafts, dark),
            atwater_to_powell(shafts, light),
        ),
    }
}

/// The 0-based block whose dark thread is on `dark_shaft`: the inverse of [`block_shafts`]'s dark
/// shaft.
///
/// # Panics
/// If `dark_shaft` is not in `1..=shafts.count()`.
pub fn block_of(system: ShadowSystem, shafts: ShadowShafts, dark_shaft: u16) -> u16 {
    match system {
        ShadowSystem::Atwater => {
            check_shaft(shafts, dark_shaft);
            dark_shaft - 1
        }
        ShadowSystem::Powell => powell_to_atwater(shafts, dark_shaft) - 1,
    }
}

/// The shafts treadle `treadle` (1-based) raises, ascending. In both systems treadle k raises
/// shaft k, and the partner's treadle raises exactly the other shafts, so treadling as drawn in
/// follows each dark pick with its shadow pick.
///
/// # Panics
/// If `treadle` is not in `1..=shafts.count()`.
pub fn treadle_lift(
    system: ShadowSystem,
    shafts: ShadowShafts,
    direction: TwillDirection,
    treadle: u16,
) -> Vec<u16> {
    let n = shafts.count();
    let atwater = |t: u16| -> Vec<u16> {
        (0..shafts.pairs())
            .map(|k| match direction {
                TwillDirection::Forward => (t - 1 + k) % n + 1,
                TwillDirection::Reverse => (t - 1 + n - k) % n + 1,
            })
            .collect()
    };
    let mut lift = match system {
        ShadowSystem::Atwater => {
            check_shaft(shafts, treadle);
            atwater(treadle)
        }
        ShadowSystem::Powell => atwater(powell_to_atwater(shafts, treadle))
            .into_iter()
            .map(|s| atwater_to_powell(shafts, s))
            .collect(),
    };
    lift.sort_unstable();
    lift
}

/// The rising-shed tie-up: one treadle per shaft, treadle k raising [`treadle_lift`]`(k)`.
///
/// Atwater forward on 4 shafts is the 2/2 twill `[1,2] [2,3] [3,4] [1,4]`; Powell forward on 4
/// shafts is `[1,3] [2,4] [2,3] [1,4]`: a plain-weave pair, then a stepped boundary.
pub fn tieup(system: ShadowSystem, shafts: ShadowShafts, direction: TwillDirection) -> TieUp {
    TieUp(
        (1..=shafts.count())
            .map(|t| {
                treadle_lift(system, shafts, direction, t)
                    .into_iter()
                    .map(ShaftId)
                    .collect()
            })
            .collect(),
    )
}

/// The lines a region shows, as the structural tests measure them on the cloth.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Lines {
    /// Every pick shows one color across the region: fine horizontal lines.
    Horizontal,
    /// Every end shows one color down the region: fine vertical lines.
    Vertical,
    /// Both at once: a single color, or a region one thread wide or tall.
    Uniform,
    /// Neither.
    Mixed,
}

/// The lines the region of warp block `warp_block` and weft block `weft_block` (both 0-based)
/// shows, treadled as drawn in with the standard tie-up. With the forward twill it is horizontal
/// when `(warp_block - weft_block) mod N < N/2`: each weft block gives horizontal lines in its own
/// warp block and the next N/2 - 1, and blocks b and b + N/2 are always opposite. The reverse twill
/// steps the other way; swapping the weft colors exchanges horizontal and vertical.
///
/// Weft blocks are counted by the treadle of each pick pair's first pick, so with swapped weft
/// colors that pick is the light one.
pub fn block_lines(
    shafts: ShadowShafts,
    direction: TwillDirection,
    weft_phase: WeftPhase,
    warp_block: u16,
    weft_block: u16,
) -> Lines {
    let n = shafts.count();
    let (b, c) = (warp_block % n, weft_block % n);
    let step = match direction {
        TwillDirection::Forward => (b + n - c) % n,
        TwillDirection::Reverse => (c + n - b) % n,
    };
    let horizontal = (step < shafts.pairs()) != (weft_phase == WeftPhase::Swapped);
    if horizontal {
        Lines::Horizontal
    } else {
        Lines::Vertical
    }
}

/// A checked block entry; neighboring entries of one block are merged, so `units` may exceed `u16`.
#[derive(Debug, Clone, Copy)]
struct BlockRun {
    block: u16,
    units: usize,
}

/// Check a block sequence and merge neighboring entries of the same block.
fn normalize(shafts: ShadowShafts, blocks: &[ShadowBlock]) -> Result<Vec<BlockRun>, ShadowError> {
    if blocks.is_empty() {
        return Err(ShadowError::NoBlocks);
    }
    let mut merged: Vec<BlockRun> = Vec::with_capacity(blocks.len());
    for (index, entry) in blocks.iter().enumerate() {
        if entry.block >= shafts.blocks() {
            return Err(ShadowError::BlockOutOfRange {
                index,
                block: entry.block,
                blocks: shafts.blocks(),
            });
        }
        if entry.units == 0 {
            return Err(ShadowError::ZeroUnits { index });
        }
        match merged.last_mut() {
            Some(last) if last.block == entry.block => {
                last.units = last.units.saturating_add(usize::from(entry.units));
            }
            _ => merged.push(BlockRun {
                block: entry.block,
                units: usize::from(entry.units),
            }),
        }
    }
    let first = merged[0].block;
    if merged.iter().all(|e| e.block == first) {
        return Err(ShadowError::SingleBlock);
    }
    Ok(merged)
}

/// Threads in one repeat of a checked sequence (at least two units), saturating at `usize::MAX`.
fn repeat_threads(layout: ShadowLayout, blocks: &[BlockRun]) -> usize {
    let units = blocks
        .iter()
        .fold(0usize, |acc, e| acc.saturating_add(e.units));
    match layout {
        ShadowLayout::Repeat => units.saturating_mul(2),
        ShadowLayout::Point => units.saturating_mul(4).saturating_sub(2),
    }
}

/// Expand one repeat of a block sequence into threads (end 1 first). Each unit is the block's dark
/// thread then its light thread, so the colors alternate strictly, starting dark. The same sequence
/// serves the weft when treadled as drawn in (the treadle number equals the shaft number).
pub fn expand(
    system: ShadowSystem,
    shafts: ShadowShafts,
    layout: ShadowLayout,
    blocks: &[ShadowBlock],
) -> Result<Vec<Thread>, ShadowError> {
    let blocks = normalize(shafts, blocks)?;
    let len = repeat_threads(layout, &blocks);
    if len > MAX_THREADS {
        return Err(ShadowError::TooLarge {
            ends: len,
            picks: len,
        });
    }
    let mut half = Vec::with_capacity(len);
    for entry in &blocks {
        let (dark, light) = block_shafts(system, shafts, entry.block);
        for _ in 0..entry.units {
            half.push(Thread {
                shaft: dark,
                role: Role::Dark,
            });
            half.push(Thread {
                shaft: light,
                role: Role::Light,
            });
        }
    }
    Ok(match layout {
        ShadowLayout::Repeat => half,
        ShadowLayout::Point => {
            // Mirror back without repeating either turning thread: H ++ reverse(H[1 .. len-1]).
            let mut out = half.clone();
            out.extend(half[1..half.len() - 1].iter().rev().copied());
            out
        }
    })
}

impl ShadowParams {
    /// Check every parameter without building anything.
    pub fn validate(&self) -> Result<(), ShadowError> {
        self.size().map(|_| ())
    }

    /// Threads in one repeat (the same for warp and weft): `2 * units` for a straight repeat,
    /// `4 * units - 2` for a point. Checks the block sequence; the size cap is checked by
    /// [`size`](Self::size).
    pub fn repeat_len(&self) -> Result<usize, ShadowError> {
        Ok(repeat_threads(
            self.layout,
            &normalize(self.shafts, &self.blocks)?,
        ))
    }

    /// The finished size as `(ends, picks)`: whole repeats, plus one end and one pick when
    /// balanced. Every parameter is checked.
    pub fn size(&self) -> Result<(usize, usize), ShadowError> {
        let period = self.repeat_len()?;
        if self.warp_repeats == 0 || self.weft_repeats == 0 {
            return Err(ShadowError::ZeroRepeats);
        }
        let extra = usize::from(self.balance);
        let axis = |repeats: u16| {
            period
                .checked_mul(usize::from(repeats))
                .and_then(|t| t.checked_add(extra))
                .unwrap_or(usize::MAX)
        };
        let (ends, picks) = (axis(self.warp_repeats), axis(self.weft_repeats));
        if ends > MAX_THREADS || picks > MAX_THREADS {
            return Err(ShadowError::TooLarge { ends, picks });
        }
        Ok((ends, picks))
    }
}

/// The threads of `repeats` copies of `unit`, plus its first thread again when balanced.
fn tile(unit: &[Thread], repeats: u16, balance: bool) -> Vec<Thread> {
    let mut out = Vec::with_capacity(unit.len() * usize::from(repeats) + usize::from(balance));
    for _ in 0..repeats {
        out.extend_from_slice(unit);
    }
    if balance {
        out.push(unit[0]);
    }
    out
}

fn role_color(role: Role) -> ColorIndex {
    match role {
        Role::Dark => DARK_COLOR,
        Role::Light => LIGHT_COLOR,
    }
}

/// A plain-text recipe for the draft's notes (WIF `[NOTES]` keeps it).
fn recipe(p: &ShadowParams, ends: usize, picks: usize, period: usize) -> String {
    let blocks = normalize(p.shafts, &p.blocks).unwrap_or_default();
    let sequence = blocks
        .iter()
        .map(|e| format!("{}{}", block_letter(e.block), e.units))
        .collect::<Vec<_>>()
        .join(" ");
    let layout = match p.layout {
        ShadowLayout::Repeat => format!("straight repeat of {sequence}"),
        ShadowLayout::Point => format!("point of {sequence}, then mirrored back"),
    };
    let direction = match p.direction {
        TwillDirection::Forward => "standard twill direction",
        TwillDirection::Reverse => "reversed twill direction",
    };
    let colors = match p.weft_phase {
        WeftPhase::Standard => {
            "warp and weft alternate dark and light, both starting dark (smooth block edges)"
        }
        WeftPhase::Swapped => {
            "warp and weft alternate dark and light; the warp starts dark and the weft starts light (feathery block edges)"
        }
    };
    let balance = if p.balance {
        ", plus the first end and pick again to balance"
    } else {
        ""
    };
    let repeats = |n: u16| {
        if n == 1 {
            "1 repeat".to_string()
        } else {
            format!("{n} repeats")
        }
    };
    format!(
        "{} shadow weave on {} shafts.\n\
         Threading: {layout}, {period} ends per repeat.\n\
         Treadling: as drawn in.\n\
         Tie-up: {direction}.\n\
         Colors: {colors}.\n\
         Size: {} across and {} up{balance}: {ends} ends x {picks} picks.",
        p.system.name(),
        p.shafts.count(),
        repeats(p.warp_repeats),
        repeats(p.weft_repeats),
    )
}

/// Generate a complete shadow-weave draft: threading, tie-up, treadling (as drawn in) and the
/// dark/light color orders, on a rising shed with one treadle per shaft. Invalid parameters are an
/// error; nothing is clamped.
pub fn generate(params: &ShadowParams) -> Result<Draft, ShadowError> {
    let (ends, picks) = params.size()?;
    let unit = expand(params.system, params.shafts, params.layout, &params.blocks)?;
    let warp = tile(&unit, params.warp_repeats, params.balance);
    let weft = tile(&unit, params.weft_repeats, params.balance);
    debug_assert_eq!((warp.len(), weft.len()), (ends, picks));

    let weft_color = |role: Role| -> ColorIndex {
        match params.weft_phase {
            WeftPhase::Standard => role_color(role),
            WeftPhase::Swapped => role_color(match role {
                Role::Dark => Role::Light,
                Role::Light => Role::Dark,
            }),
        }
    };
    let count = params.shafts.count();
    Ok(Draft {
        name: format!("Shadow weave ({})", params.system.name()),
        shafts: count,
        treadles: count,
        shed: ShedType::Rising,
        unit: Unit::Inches,
        threading: Threading(warp.iter().map(|t| vec![ShaftId(t.shaft)]).collect()),
        drive: Drive::Treadled {
            tieup: tieup(params.system, params.shafts, params.direction),
            treadling: Treadling(weft.iter().map(|t| vec![TreadleId(t.shaft)]).collect()),
        },
        colors: ColorPlan {
            palette: vec![LIGHT, DARK],
            warp: warp.iter().map(|t| role_color(t.role)).collect(),
            weft: weft.iter().map(|t| weft_color(t.role)).collect(),
        },
        warp_thickness: Vec::new(),
        weft_thickness: Vec::new(),
        notes: recipe(params, ends, picks, unit.len()),
        retained: Vec::new(),
        pick_roles: Vec::new(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rows(t: &TieUp) -> Vec<Vec<u16>> {
        t.0.iter()
            .map(|r| r.iter().map(|s| s.0).collect())
            .collect()
    }

    fn blocks(spec: &[(u16, u16)]) -> Vec<ShadowBlock> {
        spec.iter()
            .map(|&(block, units)| ShadowBlock { block, units })
            .collect()
    }

    #[test]
    fn renumbering_matches_the_published_rules() {
        // 4 shafts: exchange 2 and 3. 8 shafts: 1..8 -> 1 3 5 7 2 4 6 8.
        let four: Vec<u16> = (1..=4)
            .map(|s| atwater_to_powell(ShadowShafts::Four, s))
            .collect();
        assert_eq!(four, vec![1, 3, 2, 4]);
        let eight: Vec<u16> = (1..=8)
            .map(|s| atwater_to_powell(ShadowShafts::Eight, s))
            .collect();
        assert_eq!(eight, vec![1, 3, 5, 7, 2, 4, 6, 8]);
        for shafts in [ShadowShafts::Four, ShadowShafts::Eight] {
            for s in 1..=shafts.count() {
                assert_eq!(powell_to_atwater(shafts, atwater_to_powell(shafts, s)), s);
            }
        }
    }

    #[test]
    fn partners_and_blocks_follow_each_system() {
        use ShadowSystem::*;
        let four = ShadowShafts::Four;
        let eight = ShadowShafts::Eight;
        let p = |sys, sh: ShadowShafts| -> Vec<u16> {
            (1..=sh.count()).map(|s| partner(sys, sh, s)).collect()
        };
        assert_eq!(p(Atwater, four), vec![3, 4, 1, 2]);
        assert_eq!(p(Atwater, eight), vec![5, 6, 7, 8, 1, 2, 3, 4]);
        assert_eq!(p(Powell, four), vec![2, 1, 4, 3]);
        assert_eq!(p(Powell, eight), vec![2, 1, 4, 3, 6, 5, 8, 7]);

        let b = |sys, sh: ShadowShafts| -> Vec<(u16, u16)> {
            (0..sh.blocks()).map(|k| block_shafts(sys, sh, k)).collect()
        };
        assert_eq!(b(Atwater, four), vec![(1, 3), (2, 4), (3, 1), (4, 2)]);
        // Powell's own book order: C = dark 2 / light 1, D = dark 4 / light 3.
        assert_eq!(b(Powell, four), vec![(1, 2), (3, 4), (2, 1), (4, 3)]);
        assert_eq!(
            b(Powell, eight),
            vec![
                (1, 2),
                (3, 4),
                (5, 6),
                (7, 8),
                (2, 1),
                (4, 3),
                (6, 5),
                (8, 7)
            ]
        );
        for sys in [Atwater, Powell] {
            for sh in [four, eight] {
                for k in 0..sh.blocks() {
                    let (dark, light) = block_shafts(sys, sh, k);
                    assert_eq!(partner(sys, sh, dark), light);
                    assert_eq!(block_of(sys, sh, dark), k);
                }
            }
        }
    }

    #[test]
    fn tieups_match_the_reference_goldens() {
        use ShadowSystem::*;
        use TwillDirection::*;
        let (four, eight) = (ShadowShafts::Four, ShadowShafts::Eight);
        assert_eq!(
            rows(&tieup(Atwater, four, Forward)),
            vec![vec![1, 2], vec![2, 3], vec![3, 4], vec![1, 4]]
        );
        assert_eq!(
            rows(&tieup(Atwater, eight, Forward)),
            vec![
                vec![1, 2, 3, 4],
                vec![2, 3, 4, 5],
                vec![3, 4, 5, 6],
                vec![4, 5, 6, 7],
                vec![5, 6, 7, 8],
                vec![1, 6, 7, 8],
                vec![1, 2, 7, 8],
                vec![1, 2, 3, 8],
            ]
        );
        assert_eq!(
            rows(&tieup(Powell, four, Forward)),
            vec![vec![1, 3], vec![2, 4], vec![2, 3], vec![1, 4]]
        );
        assert_eq!(
            rows(&tieup(Powell, eight, Forward)),
            vec![
                vec![1, 3, 5, 7],
                vec![2, 4, 6, 8],
                vec![2, 3, 5, 7],
                vec![1, 4, 6, 8],
                vec![2, 4, 5, 7],
                vec![1, 3, 6, 8],
                vec![2, 4, 6, 7],
                vec![1, 3, 5, 8],
            ]
        );
        // The other twill direction, as used by several contributed Powell drafts.
        assert_eq!(
            rows(&tieup(Powell, four, Reverse)),
            vec![vec![1, 4], vec![2, 3], vec![1, 3], vec![2, 4]]
        );
        assert_eq!(
            rows(&tieup(Atwater, four, Reverse)),
            vec![vec![1, 4], vec![1, 2], vec![2, 3], vec![3, 4]]
        );
    }

    /// Every treadle raises its own shaft and exactly one shaft of each pair; the partner's
    /// treadle raises the complement.
    #[test]
    fn every_treadle_splits_the_pairs_and_has_a_complement() {
        for sys in [ShadowSystem::Atwater, ShadowSystem::Powell] {
            for sh in [ShadowShafts::Four, ShadowShafts::Eight] {
                for dir in [TwillDirection::Forward, TwillDirection::Reverse] {
                    for t in 1..=sh.count() {
                        let lift = treadle_lift(sys, sh, dir, t);
                        assert!(lift.contains(&t));
                        assert_eq!(lift.len(), usize::from(sh.pairs()));
                        for s in 1..=sh.count() {
                            assert_ne!(lift.contains(&s), lift.contains(&partner(sys, sh, s)));
                        }
                        let other = treadle_lift(sys, sh, dir, partner(sys, sh, t));
                        for s in 1..=sh.count() {
                            assert_ne!(lift.contains(&s), other.contains(&s));
                        }
                    }
                }
            }
        }
    }

    #[test]
    fn unsupported_shaft_counts_are_refused() {
        for n in [0u16, 1, 2, 3, 5, 6, 7, 9, 10, 12, 16, u16::MAX] {
            assert_eq!(
                ShadowShafts::try_from(n),
                Err(ShadowError::UnsupportedShafts(n))
            );
        }
        assert_eq!(ShadowShafts::try_from(4), Ok(ShadowShafts::Four));
        assert_eq!(ShadowShafts::try_from(8), Ok(ShadowShafts::Eight));
    }

    #[test]
    fn invalid_sequences_and_sizes_are_errors_not_clamped() {
        let with = |f: &dyn Fn(&mut ShadowParams)| {
            let mut p = ShadowParams::default();
            f(&mut p);
            generate(&p).err()
        };
        assert_eq!(with(&|p| p.blocks.clear()), Some(ShadowError::NoBlocks));
        assert_eq!(
            with(&|p| p.blocks[2].block = 4),
            Some(ShadowError::BlockOutOfRange {
                index: 2,
                block: 4,
                blocks: 4
            })
        );
        assert_eq!(
            with(&|p| p.blocks[1].units = 0),
            Some(ShadowError::ZeroUnits { index: 1 })
        );
        assert_eq!(
            with(&|p| p.blocks = blocks(&[(2, 3)])),
            Some(ShadowError::SingleBlock)
        );
        assert_eq!(
            with(&|p| p.blocks = blocks(&[(1, 1), (1, 2)])),
            Some(ShadowError::SingleBlock),
            "neighboring entries of one block merge into one"
        );
        assert_eq!(
            with(&|p| p.warp_repeats = 0),
            Some(ShadowError::ZeroRepeats)
        );
        assert_eq!(
            with(&|p| p.weft_repeats = 0),
            Some(ShadowError::ZeroRepeats)
        );
        // 8 blocks of 65535 units would be millions of threads: refused before anything is built.
        let huge = ShadowParams {
            shafts: ShadowShafts::Eight,
            blocks: (0..8)
                .map(|block| ShadowBlock {
                    block,
                    units: u16::MAX,
                })
                .collect(),
            ..ShadowParams::default()
        };
        assert!(matches!(generate(&huge), Err(ShadowError::TooLarge { .. })));
        // Just over the cap on one axis.
        let tall = ShadowParams {
            layout: ShadowLayout::Repeat,
            blocks: blocks(&[(0, 1), (1, 1)]), // 4 threads per repeat
            warp_repeats: 1,
            weft_repeats: (MAX_THREADS / 4) as u16,
            balance: true,
            ..ShadowParams::default()
        };
        assert_eq!(
            tall.size(),
            Err(ShadowError::TooLarge {
                ends: 5,
                picks: MAX_THREADS + 1
            })
        );
    }

    #[test]
    fn error_messages_are_plain_sentences() {
        let msg = ShadowError::BlockOutOfRange {
            index: 0,
            block: 9,
            blocks: 8,
        }
        .to_string();
        assert_eq!(
            msg,
            "block entry 1 is block number 10, but 8 shafts give blocks A to H"
        );
        assert_eq!(
            ShadowError::UnsupportedShafts(6).to_string(),
            "shadow weave needs 4 or 8 shafts, not 6"
        );
    }

    #[test]
    fn sizes_are_whole_repeats_plus_the_balancing_thread() {
        let p = ShadowParams::default(); // point of A2 B2 C2 D2: W = 8, period 30
        assert_eq!(p.repeat_len(), Ok(30));
        assert_eq!(p.size(), Ok((61, 61)));
        let d = generate(&p).unwrap();
        assert_eq!((d.ends(), d.picks()), (61, 61));
        let repeat = ShadowParams {
            layout: ShadowLayout::Repeat,
            warp_repeats: 3,
            weft_repeats: 1,
            balance: false,
            ..ShadowParams::default()
        };
        assert_eq!(repeat.size(), Ok((48, 16)));
    }

    #[test]
    fn balanced_point_warp_and_weft_are_palindromes() {
        let d = generate(&ShadowParams::default()).unwrap();
        let threading: Vec<u16> = d.threading.0.iter().map(|v| v[0].0).collect();
        let mut rev = threading.clone();
        rev.reverse();
        assert_eq!(threading, rev);
        let mut colors = d.colors.warp.clone();
        colors.reverse();
        assert_eq!(colors, d.colors.warp);
        assert_eq!(d.colors.warp.first(), Some(&DARK_COLOR));
        assert_eq!(d.colors.warp.last(), Some(&DARK_COLOR));
    }

    #[test]
    fn the_recipe_names_the_design() {
        let d = generate(&ShadowParams::default()).unwrap();
        assert_eq!(d.name, "Shadow weave (Atwater)");
        assert!(d.notes.starts_with("Atwater shadow weave on 4 shafts."));
        assert!(d.notes.contains("point of A2 B2 C2 D2, then mirrored back"));
        assert!(d.notes.contains("61 ends x 61 picks"));
        let powell = generate(&ShadowParams {
            system: ShadowSystem::Powell,
            weft_phase: WeftPhase::Swapped,
            ..ShadowParams::default()
        })
        .unwrap();
        assert_eq!(powell.name, "Shadow weave (Powell)");
        assert!(powell.notes.contains("feathery block edges"));
    }

    #[test]
    fn the_oracle_puts_half_the_blocks_on_each_line() {
        for sh in [ShadowShafts::Four, ShadowShafts::Eight] {
            for c in 0..sh.blocks() {
                let h = (0..sh.blocks())
                    .filter(|&b| {
                        block_lines(sh, TwillDirection::Forward, WeftPhase::Standard, b, c)
                            == Lines::Horizontal
                    })
                    .count();
                assert_eq!(h, usize::from(sh.pairs()));
                // Blocks b and b + n are always opposite.
                for b in 0..sh.pairs() {
                    assert_ne!(
                        block_lines(sh, TwillDirection::Forward, WeftPhase::Standard, b, c),
                        block_lines(
                            sh,
                            TwillDirection::Forward,
                            WeftPhase::Standard,
                            b + sh.pairs(),
                            c
                        )
                    );
                }
            }
        }
    }
}
