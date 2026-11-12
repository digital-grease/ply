//! Drawdown computation and rendering.
//!
//! The drawdown is the over/under interlacement grid — what the cloth actually looks
//! like. It is a pure function of the draft and cheap to recompute (microseconds for
//! normal drafts), which is what makes live preview feel instant.
//!
//! **Resource bounds.** Draft sizes come from untrusted files and FFI calls, and the drawdown grows
//! with `ends * picks`. The `try_*` entry points check every size against [`RenderLimits`] with
//! checked arithmetic *before* allocating, and report a [`RenderError`] instead of allocating
//! without bound or returning a silent blank. [`compute`], [`render_rgba`] and [`render_rgba_with`]
//! remain as conveniences for trusted, test-sized drafts.

use crate::draft::{ColorIndex, Draft};
use ply_common::Color;
use serde::{Deserialize, Serialize};
use thiserror::Error;

/// What shows on the face of the cloth at one warp/weft intersection.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Cell {
    /// Warp thread on top; carries the warp end's color index.
    WarpUp(ColorIndex),
    /// Weft thread on top; carries the weft pick's color index.
    WeftUp(ColorIndex),
}

/// The computed interlacement grid, row-major by pick.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Drawdown {
    pub ends: usize,
    pub picks: usize,
    /// `len == ends * picks`, indexed `[pick * ends + end]`.
    pub cells: Vec<Cell>,
}

impl Drawdown {
    pub fn cell(&self, end: usize, pick: usize) -> Cell {
        self.cells[pick * self.ends + end]
    }
}

/// Size budgets for computing and rendering a drawdown.
///
/// [`RenderLimits::DEFAULT`] is sized for an average mid-range phone (roughly 4 to 6 GB of RAM and a
/// GPU that accepts 8192 px textures). A render briefly holds its raster about three times over
/// (the engine buffer, the FFI copy, the decoded image), so a 64 MiB raster keeps the peak near
/// 200 MB; the interlacement itself costs one byte per intersection while rendering. These are
/// budgets, not physical facts: revisit them with measurements from real devices.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RenderLimits {
    /// Most warp/weft intersections (`ends * picks`) computed in one call.
    pub max_cells: usize,
    /// Most bytes in one RGBA8 raster.
    pub max_raster_bytes: usize,
    /// Most pixels along either side of one raster.
    pub max_raster_side: usize,
}

impl RenderLimits {
    /// The phone budget: 4 million intersections (e.g. 2000 x 2000), a 64 MiB raster, and at most
    /// 8192 px per side.
    pub const DEFAULT: RenderLimits = RenderLimits {
        max_cells: 4_000_000,
        max_raster_bytes: 64 * 1024 * 1024,
        max_raster_side: 8192,
    };

    /// No budget beyond what `usize` arithmetic allows. For trusted, test-sized drafts only.
    pub const UNBOUNDED: RenderLimits = RenderLimits {
        max_cells: usize::MAX,
        max_raster_bytes: usize::MAX,
        max_raster_side: usize::MAX,
    };
}

impl Default for RenderLimits {
    fn default() -> Self {
        Self::DEFAULT
    }
}

/// Why a drawdown could not be computed or rendered within its [`RenderLimits`].
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum RenderError {
    /// `ends * picks` exceeds [`RenderLimits::max_cells`].
    #[error("a {ends} x {picks} draft has {cells} intersections; the limit is {limit}")]
    TooManyCells {
        ends: usize,
        picks: usize,
        cells: usize,
        limit: usize,
    },
    /// The raster at the requested pitch exceeds the byte or the per-side budget.
    #[error(
        "a {width} x {height} px preview needs {bytes} bytes; the limit is {max_bytes} bytes \
         and {max_side} px per side"
    )]
    RasterTooLarge {
        width: usize,
        height: usize,
        bytes: usize,
        max_bytes: usize,
        max_side: usize,
    },
    /// A size computation overflowed `usize` (only reachable with absurd dimensions or pitch).
    #[error("the draft's dimensions are too large to size")]
    Overflow,
    /// The allocator refused a buffer that was within budget.
    #[error("could not allocate {bytes} bytes for the drawdown")]
    AllocFailed { bytes: usize },
}

/// Check the intersection budget; returns `(ends, picks, ends * picks)`.
fn check_cells(draft: &Draft, limits: &RenderLimits) -> Result<(usize, usize, usize), RenderError> {
    let (ends, picks) = (draft.ends(), draft.picks());
    let cells = ends.checked_mul(picks).ok_or(RenderError::Overflow)?;
    if cells > limits.max_cells {
        return Err(RenderError::TooManyCells {
            ends,
            picks,
            cells,
            limit: limits.max_cells,
        });
    }
    Ok((ends, picks, cells))
}

/// An empty `Vec` with room for exactly `n` items, or [`RenderError::AllocFailed`] (instead of an
/// abort) when the allocator says no.
fn try_vec<T>(n: usize) -> Result<Vec<T>, RenderError> {
    let mut v = Vec::new();
    v.try_reserve_exact(n)
        .map_err(|_| RenderError::AllocFailed {
            bytes: n.saturating_mul(std::mem::size_of::<T>()),
        })?;
    Ok(v)
}

/// Walk every intersection in pick-major order (the drawdown's own `[pick * ends + end]` layout),
/// calling `visit(end, pick, warp_up)`. Shed direction comes only from [`Draft::raised_shafts`]. A
/// per-pick lookup table makes "is one of this end's shafts raised?" an O(1) test, so a draft with
/// many shafts (where a sinking shed raises nearly all of them) stays linear in its size.
fn for_each_intersection(draft: &Draft, mut visit: impl FnMut(usize, usize, bool)) {
    let ends = draft.ends();
    let mut raised_table = vec![false; usize::from(u16::MAX) + 1];
    for pick in 0..draft.picks() {
        let raised = draft.raised_shafts(pick);
        for s in &raised {
            raised_table[usize::from(s.0)] = true;
        }
        for end in 0..ends {
            let warp_up = draft.threading.0[end]
                .iter()
                .any(|s| raised_table[usize::from(s.0)]);
            visit(end, pick, warp_up);
        }
        for s in &raised {
            raised_table[usize::from(s.0)] = false;
        }
    }
}

/// Compute the drawdown for a draft, refusing drafts over `limits` before allocating.
/// Deterministic; the heart of the engine.
pub fn try_compute(draft: &Draft, limits: &RenderLimits) -> Result<Drawdown, RenderError> {
    let (ends, picks, n) = check_cells(draft, limits)?;
    let mut cells = try_vec::<Cell>(n)?;
    let (warp, weft) = (&draft.colors.warp, &draft.colors.weft);
    for_each_intersection(draft, |end, pick, warp_up| {
        cells.push(if warp_up {
            Cell::WarpUp(warp.get(end).copied().unwrap_or(0))
        } else {
            Cell::WeftUp(weft.get(pick).copied().unwrap_or(0))
        });
    });
    Ok(Drawdown { ends, picks, cells })
}

/// Compute the drawdown for a trusted, reasonably sized draft: [`try_compute`] with
/// [`RenderLimits::UNBOUNDED`]. Panics if the drawdown cannot be sized or allocated, so anything
/// that handles untrusted input (files, FFI) uses [`try_compute`] or [`try_render_rgba_with`].
pub fn compute(draft: &Draft) -> Drawdown {
    match try_compute(draft, &RenderLimits::UNBOUNDED) {
        Ok(dd) => dd,
        Err(e) => panic!("drawdown: {e}"),
    }
}

/// A flat RGBA8 image buffer suitable for handing to Flutter (decode into a `ui.Image`).
#[derive(Debug, Clone, PartialEq)]
pub struct RgbaImage {
    pub width: u32,
    pub height: u32,
    pub pixels: Vec<u8>,
}

impl RgbaImage {
    fn empty() -> Self {
        RgbaImage {
            width: 0,
            height: 0,
            pixels: Vec::new(),
        }
    }
}

/// Pixel geometry of one raster: per-thread extents plus the checked totals.
struct RasterLayout {
    col_w: Vec<usize>,
    row_h: Vec<usize>,
    width: usize,
    height: usize,
    bytes: usize,
}

/// Size the raster for `draft` at `cell_px`, checking the byte and per-side budgets with checked
/// arithmetic. Allocates only the per-thread extents (linear in ends + picks).
fn raster_layout(
    draft: &Draft,
    cell_px: u32,
    limits: &RenderLimits,
) -> Result<RasterLayout, RenderError> {
    let base = cell_px.max(1) as usize;
    let col_w = thread_extents(&draft.warp_thickness, draft.ends(), base);
    let row_h = thread_extents(&draft.weft_thickness, draft.picks(), base);
    let sum = |v: &[usize]| {
        v.iter()
            .try_fold(0usize, |acc, &x| acc.checked_add(x))
            .ok_or(RenderError::Overflow)
    };
    let (width, height) = (sum(&col_w)?, sum(&row_h)?);
    let bytes = width
        .checked_mul(height)
        .and_then(|wh| wh.checked_mul(4))
        .ok_or(RenderError::Overflow)?;
    if bytes > limits.max_raster_bytes
        || width > limits.max_raster_side
        || height > limits.max_raster_side
    {
        return Err(RenderError::RasterTooLarge {
            width,
            height,
            bytes,
            max_bytes: limits.max_raster_bytes,
            max_side: limits.max_raster_side,
        });
    }
    Ok(RasterLayout {
        col_w,
        row_h,
        width,
        height,
        bytes,
    })
}

/// The largest pixel pitch `<= max_cell_px` (and at least 1) at which `draft` renders within
/// `limits`. Every current preview scales its image to fit, so a caller can trade resolution for
/// memory instead of failing. An error means the draft is too large even at 1 px per intersection.
pub fn fit_cell_px(
    draft: &Draft,
    max_cell_px: u32,
    limits: &RenderLimits,
) -> Result<u32, RenderError> {
    check_cells(draft, limits)?;
    let fits = |px: u32| raster_layout(draft, px, limits).is_ok();
    let mut hi = max_cell_px.max(1);
    if fits(hi) {
        return Ok(hi);
    }
    // Report the real reason when even the smallest pitch is over budget.
    raster_layout(draft, 1, limits)?;
    // Invariant: `lo` fits and `hi` does not. The raster never shrinks as the pitch grows.
    let mut lo = 1;
    while hi - lo > 1 {
        let mid = lo + (hi - lo) / 2;
        if fits(mid) {
            lo = mid;
        } else {
            hi = mid;
        }
    }
    Ok(lo)
}

/// Per-thread pixel extents from relative thickness values.
///
/// The **thinnest** positive thread becomes `base` px and thicker ones scale up proportionally
/// (ratio clamped to keep one fat thread from dwarfing the cloth). An empty or all-default slice
/// yields a uniform `base`-px grid, so equal thickness reproduces the old raster exactly.
fn thread_extents(thickness: &[f32], n: usize, base: usize) -> Vec<usize> {
    const MAX_RATIO: f32 = 6.0;
    // Reference = the smallest positive, finite thickness actually present (the thinnest thread
    // maps to `base` px). With none set we fall straight back to a uniform grid.
    let min = thickness
        .iter()
        .take(n)
        .copied()
        .filter(|t| t.is_finite() && *t > 0.0)
        .fold(f32::INFINITY, f32::min);
    if !min.is_finite() {
        return vec![base; n];
    }
    (0..n)
        .map(|i| {
            let t = thickness
                .get(i)
                .copied()
                .filter(|t| t.is_finite() && *t > 0.0)
                .unwrap_or(min);
            let scale = (t / min).clamp(1.0, MAX_RATIO);
            ((base as f32 * scale).round() as usize).max(1)
        })
        .collect()
}

/// Optional overlays drawn onto the drawdown raster. Default-OFF (a plain cloth render): the live
/// editor turns these on per-view; the thumbnail/library path leaves them off so the saved preview
/// stays a clean cloth.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct RenderOptions {
    /// Draw a 1px separator between cells so the interlacement reads as a grid (aligned to the
    /// variable cell boundaries, so it stays correct under per-thread thickness).
    pub gridlines: bool,
    /// Tint every cell belonging to a float (a run of same-face cells) of this length OR MORE,
    /// flagging snag-prone long floats. `0` (or `1`) disables the cue.
    pub float_threshold: u32,
    /// Shade each cell like a rounded thread — a warp-faced cell reads as a vertical thread, a
    /// weft-faced cell as a horizontal one — so the cloth looks woven instead of a flat color grid
    /// (see [`thread_shade`]). Off by default (a plain flat fill, byte-identical to the old raster).
    pub thread_texture: bool,
}

/// Render the drawdown to an RGBA8 buffer at `cell_px` pixels per (thinnest) intersection, with no
/// overlays (a plain cloth). Thin wrapper over [`render_rgba_with`] for the common case.
///
/// Cells are **variable-sized** when the draft carries per-thread thickness: a fatter warp end
/// draws a wider column, a fatter weft pick a taller row (see [`thread_extents`]). With no
/// thickness set every cell is `cell_px` square — byte-identical to a plain uniform grid.
pub fn render_rgba(draft: &Draft, cell_px: u32) -> RgbaImage {
    render_rgba_with(draft, cell_px, &RenderOptions::default())
}

/// Render the drawdown to an RGBA8 buffer, optionally drawing gridlines and/or highlighting long
/// floats (see [`RenderOptions`]).
///
/// This is the function the FFI bridge calls for live preview: compute the **whole**
/// buffer in Rust and hand it across in one shot. Never marshal per cell across FFI.
///
/// The output uses the CONVENTIONAL weaving-draft orientation: end 1 at the RIGHT (ends increase
/// leftward) and pick 1 at the TOP (picks increase downward), so a newly-appended end shows on the
/// left and a newly-appended pick at the bottom. The buffer is built in the natural raster order
/// (end 0 left, pick 0 bottom) and turned 180° as a final step; the UI grids use the matching
/// right/top origins, so the bitmap blits 1:1 with NO second flip on the Dart side.
///
/// Infallible convenience over [`try_render_rgba_with`] with [`RenderLimits::DEFAULT`]: a draft over
/// budget yields an EMPTY image, which a caller cannot tell apart from an empty draft. The FFI
/// bridge uses the `try_` form so the UI can explain an oversized draft instead.
pub fn render_rgba_with(draft: &Draft, cell_px: u32, opts: &RenderOptions) -> RgbaImage {
    try_render_rgba_with(draft, cell_px, opts, &RenderLimits::DEFAULT)
        .unwrap_or_else(|_| RgbaImage::empty())
}

/// Render the drawdown like [`render_rgba_with`], but check every size against `limits` (with
/// checked arithmetic, before any large allocation) and report why a render is impossible rather
/// than returning a blank. A 0-end or 0-pick draft renders as an empty image, not an error.
pub fn try_render_rgba_with(
    draft: &Draft,
    cell_px: u32,
    opts: &RenderOptions,
    limits: &RenderLimits,
) -> Result<RgbaImage, RenderError> {
    let (ends, picks, n) = check_cells(draft, limits)?;
    if n == 0 {
        return Ok(RgbaImage::empty());
    }
    let RasterLayout {
        col_w,
        row_h,
        width: w,
        height: h,
        bytes,
    } = raster_layout(draft, cell_px, limits)?;

    // The face of every intersection, one byte each (the render needs no per-cell color copy).
    let mut warp_up = try_vec::<bool>(n)?;
    for_each_intersection(draft, |_, _, up| warp_up.push(up));
    let mask = long_float_mask(&warp_up, ends, picks, opts.float_threshold as usize)?;

    // Cumulative left edge per end (end 0 at the left). Every partial sum is bounded by the checked
    // total width, so plain addition cannot overflow here.
    let mut col_left = try_vec::<usize>(ends)?;
    let mut acc = 0usize;
    for &cw in &col_w {
        col_left.push(acc);
        acc += cw;
    }

    // Pick 0 sits at the BOTTOM, so build top edges from the bottom up: a pick's top edge is the
    // image height minus the cloth woven up to and including it.
    let mut row_top = try_vec::<usize>(picks)?;
    let mut from_bottom = 0usize;
    for &rh in &row_h {
        from_bottom += rh;
        row_top.push(h - from_bottom);
    }

    let mut px = try_vec::<u8>(bytes)?;
    px.resize(bytes, 0);
    let palette = &draft.colors.palette;
    let color_at = |idx: ColorIndex| -> Color { palette.get(idx).copied().unwrap_or(Color::WHITE) };

    for pick in 0..picks {
        let top = row_top[pick];
        let ch = row_h[pick];
        let weft_c = color_at(draft.colors.weft.get(pick).copied().unwrap_or(0));
        for end in 0..ends {
            let i = pick * ends + end;
            // Warp on top => a vertical thread; weft on top => a horizontal one. Drives the texture's
            // shading axis below.
            let warp_up = warp_up[i];
            let base_c = if warp_up {
                color_at(draft.colors.warp.get(end).copied().unwrap_or(0))
            } else {
                weft_c
            };
            // Tint cells that belong to a long float so they read at a glance (over any palette).
            let c = if mask.as_ref().is_some_and(|m| m[i]) {
                blend(base_c, FLOAT_HIGHLIGHT, 0.5)
            } else {
                base_c
            };
            let left = col_left[end];
            let cw = col_w[end];
            for dy in 0..ch {
                let row = ((top + dy) * w + left) * 4;
                for dx in 0..cw {
                    let o = row + dx * 4;
                    // Plain flat fill unless the texture overlay is on, in which case shade the pixel
                    // by its position across/along the thread so the cell reads as a rounded strand.
                    let pc = if opts.thread_texture {
                        let xt = (dx as f32 + 0.5) / cw as f32;
                        let yt = (dy as f32 + 0.5) / ch as f32;
                        // `perp` runs ACROSS the thread (the rounded cross-section), `along` its length.
                        let (perp, along) = if warp_up { (xt, yt) } else { (yt, xt) };
                        thread_shade(c, perp, along)
                    } else {
                        c
                    };
                    px[o] = pc.r;
                    px[o + 1] = pc.g;
                    px[o + 2] = pc.b;
                    px[o + 3] = 255;
                }
            }
        }
    }

    if opts.gridlines {
        draw_gridlines(&mut px, w, h, &col_left, &row_top);
    }

    // Turn the finished buffer 180° to the conventional weaving orientation (end 1 right, pick 1 top).
    // A 180° turn (H-flip + V-flip together) is exactly the pixel sequence reversed, so swap the i-th
    // 4-byte pixel with the (n-1-i)-th. Overlays drawn above ride along with the cloth. Independent of
    // the variable per-thread cell sizes — a whole-image reflection preserves every cell's extent.
    let n = w * h;
    for i in 0..n / 2 {
        let (a, b) = (i * 4, (n - 1 - i) * 4);
        for k in 0..4 {
            px.swap(a + k, b + k);
        }
    }

    // `w`/`h` are within `max_raster_side`; with the default limits that is far below `u32::MAX`, and
    // a caller-supplied larger side still cannot exceed the checked `usize` byte total.
    Ok(RgbaImage {
        width: u32::try_from(w).map_err(|_| RenderError::Overflow)?,
        height: u32::try_from(h).map_err(|_| RenderError::Overflow)?,
        pixels: px,
    })
}

/// The grid-seam color: a neutral mid-gray that reads on most cloth colors (it can vanish on a
/// near-`128` gray cell — an accepted v1 limitation).
const GRID_LINE: [u8; 3] = [128, 128, 128];

/// The long-float highlight: a warm orange that, blended at 50%, stays visible over both dark and
/// light cloth.
const FLOAT_HIGHLIGHT: [u8; 3] = [255, 120, 0];

/// Alpha-blend `over` onto `base` (`a` in 0..=1). Used for the float-highlight tint.
fn blend(base: Color, over: [u8; 3], a: f32) -> Color {
    let mix = |b: u8, o: u8| ((b as f32) * (1.0 - a) + (o as f32) * a).round() as u8;
    Color::rgb(
        mix(base.r, over[0]),
        mix(base.g, over[1]),
        mix(base.b, over[2]),
    )
}

/// Shade one pixel of a thread cell so the cloth reads as woven strands rather than flat squares
/// (used only when [`RenderOptions::thread_texture`] is set). `perp` and `along` are the pixel's
/// normalized position (0..1) ACROSS and ALONG the thread:
///   * a cylindrical cross-section darkens the two long edges toward the strand's sides — the
///     dominant cue, brightest down the centre line (`CROSS`);
///   * a faint quartic dip darkens the two ends, where the strand tucks under its crossing
///     neighbour at the cell boundary (`ENDS`);
///   * a slim additive ridge of light rides the centre line so even a near-black strand catches a
///     little sheen instead of reading flat (`RIDGE`).
///
/// All three are gentle so the cloth's color stays legible; the centre of every cell keeps
/// essentially the base color.
fn thread_shade(c: Color, perp: f32, along: f32) -> Color {
    const CROSS: f32 = 0.34;
    const ENDS: f32 = 0.12;
    const RIDGE: f32 = 0.06;
    let pd = 2.0 * perp - 1.0; // -1 (one side) .. 0 (centre) .. 1 (other side)
    let ad = 2.0 * along - 1.0;
    let cross = 1.0 - CROSS * pd * pd; // parabola: 1 at the centre line, 1-CROSS at the side edges
    let ends = 1.0 - ENDS * ad * ad * ad * ad; // quartic: flat in the middle, dips at the two tips
    let mul = cross * ends;
    let r = 1.0 - pd * pd;
    let ridge = RIDGE * r * r * r; // peaks on the centre line, vanishes at the side edges
    let f = |ch: u8| {
        ((ch as f32) * mul + ridge * 255.0)
            .round()
            .clamp(0.0, 255.0) as u8
    };
    Color::rgb(f(c.r), f(c.g), f(c.b))
}

/// Mark every cell that belongs to a float — a maximal run of same-face cells along the warp (down
/// a column) or weft (across a row) — of length `>= threshold`. A `threshold` below 2 marks nothing
/// (a "float" of one is just ordinary interlacement), and then no mask is allocated at all. The flat
/// mask is indexed like the drawdown (`[pick * ends + end]`, from `warp_up`).
fn long_float_mask(
    warp_up: &[bool],
    ends: usize,
    picks: usize,
    threshold: usize,
) -> Result<Option<Vec<bool>>, RenderError> {
    if threshold < 2 {
        return Ok(None);
    }
    let mut mask = try_vec::<bool>(warp_up.len())?;
    mask.resize(warp_up.len(), false);
    // Warp floats: consecutive warp-up cells down each column. The `0..=picks` sweep uses the final
    // out-of-range step as a sentinel that flushes a run ending at the top edge.
    for end in 0..ends {
        let mut run = 0usize;
        for pick in 0..=picks {
            if pick < picks && warp_up[pick * ends + end] {
                run += 1;
            } else {
                if run >= threshold {
                    for p in pick - run..pick {
                        mask[p * ends + end] = true;
                    }
                }
                run = 0;
            }
        }
    }
    // Weft floats: consecutive weft-up cells across each row.
    for pick in 0..picks {
        let row = pick * ends;
        let mut run = 0usize;
        for end in 0..=ends {
            if end < ends && !warp_up[row + end] {
                run += 1;
            } else {
                if run >= threshold {
                    mask[row + end - run..row + end].fill(true);
                }
                run = 0;
            }
        }
    }
    Ok(Some(mask))
}

/// Draw interior cell-boundary seams (one between each pair of adjacent ends/picks; no outer
/// border) in [`GRID_LINE`], aligned to the variable cell positions so the grid stays true under
/// per-thread thickness.
fn draw_gridlines(px: &mut [u8], w: usize, h: usize, col_left: &[usize], row_top: &[usize]) {
    let mut set = |x: usize, y: usize| {
        if x < w && y < h {
            let o = (y * w + x) * 4;
            px[o] = GRID_LINE[0];
            px[o + 1] = GRID_LINE[1];
            px[o + 2] = GRID_LINE[2];
            px[o + 3] = 255;
        }
    };
    // Vertical seams at the left edge of every end except the first (an interior boundary).
    for &x in col_left.iter().skip(1) {
        for y in 0..h {
            set(x, y);
        }
    }
    // Horizontal seams at the top edge of every cell except the topmost pick (whose top edge is the
    // outer image border at y == 0).
    for &y in row_top {
        if y == 0 {
            continue;
        }
        for x in 0..w {
            set(x, y);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::draft::*;
    use ply_common::{Color, Unit};

    /// A 2x2 plain weave driven by a liftplan: end 0 on shaft 1, end 1 on shaft 2;
    /// pick 0 raises shaft 1, pick 1 raises shaft 2. Should checkerboard.
    fn plain_2x2() -> Draft {
        Draft {
            name: "plain".into(),
            shafts: 2,
            treadles: 2,
            shed: ShedType::Rising,
            unit: Unit::Inches,
            threading: Threading(vec![vec![ShaftId(1)], vec![ShaftId(2)]]),
            drive: Drive::Liftplan(Liftplan(vec![vec![ShaftId(1)], vec![ShaftId(2)]])),
            colors: ColorPlan {
                palette: vec![Color::BLACK, Color::WHITE],
                warp: vec![0, 0],
                weft: vec![1, 1],
            },
            warp_thickness: Vec::new(),
            weft_thickness: Vec::new(),
            notes: String::new(),
            retained: Vec::new(),
        }
    }

    #[test]
    fn plain_weave_checkerboards() {
        let dd = compute(&plain_2x2());
        assert_eq!((dd.ends, dd.picks), (2, 2));
        assert!(matches!(dd.cell(0, 0), Cell::WarpUp(_)));
        assert!(matches!(dd.cell(1, 0), Cell::WeftUp(_)));
        assert!(matches!(dd.cell(0, 1), Cell::WeftUp(_)));
        assert!(matches!(dd.cell(1, 1), Cell::WarpUp(_)));
    }

    #[test]
    fn sinking_shed_inverts() {
        let mut d = plain_2x2();
        // Re-express as treadled so shed inversion applies.
        d.drive = Drive::Treadled {
            tieup: TieUp(vec![vec![ShaftId(1)], vec![ShaftId(2)]]),
            treadling: Treadling(vec![vec![TreadleId(1)], vec![TreadleId(2)]]),
        };
        d.shed = ShedType::Rising;
        let rising = compute(&d);
        d.shed = ShedType::Sinking;
        let sinking = compute(&d);
        // Every cell should flip between rising and sinking interpretations.
        for (a, b) in rising.cells.iter().zip(sinking.cells.iter()) {
            let a_warp = matches!(a, Cell::WarpUp(_));
            let b_warp = matches!(b, Cell::WarpUp(_));
            assert_ne!(a_warp, b_warp);
        }
    }

    #[test]
    fn renders_expected_pixel_size() {
        let img = render_rgba(&plain_2x2(), 4);
        assert_eq!((img.width, img.height), (8, 8));
        assert_eq!(img.pixels.len(), 8 * 8 * 4);
    }

    /// Equal (or absent) thickness must reproduce the plain uniform raster byte for byte — the
    /// invariant that lets every existing golden and device check keep passing.
    #[test]
    fn equal_thickness_matches_uniform_raster() {
        let uniform = render_rgba(&plain_2x2(), 5);

        let mut all_two = plain_2x2();
        all_two.warp_thickness = vec![2.0; all_two.ends()];
        all_two.weft_thickness = vec![2.0; all_two.picks()];
        let scaled = render_rgba(&all_two, 5);

        assert_eq!(
            (scaled.width, scaled.height),
            (uniform.width, uniform.height)
        );
        assert_eq!(
            scaled.pixels, uniform.pixels,
            "uniform thickness == plain grid"
        );
    }

    /// A fatter warp end draws a proportionally wider column; the thinnest thread stays `base` px.
    #[test]
    fn fat_warp_end_widens_its_column() {
        let mut d = plain_2x2();
        d.warp_thickness = vec![1.0, 2.0]; // end 1 is twice as fat
        let img = render_rgba(&d, 4);
        // end 0 -> 4 px, end 1 -> 8 px; both picks stay 4 px tall.
        assert_eq!((img.width, img.height), (12, 8));

        // After the 180° flip end 1 (the fat 8px band) is on the LEFT, x in [0,8); end 0 (4px) on the
        // RIGHT, x in [8,12). Read straight from the buffer to prove the wide band is genuinely end 1's.
        let pixel = |x: usize, y: usize| -> [u8; 3] {
            let o = (y * img.width as usize + x) * 4;
            [img.pixels[o], img.pixels[o + 1], img.pixels[o + 2]]
        };
        // The top image row is now pick 0; there end 0 = WarpUp and end 1 = WeftUp.
        let end1_a = pixel(2, 0);
        let end1_b = pixel(6, 0); // still inside the widened end-1 band
        let end0 = pixel(10, 0);
        assert_eq!(end1_a, end1_b, "the whole widened band is one color");
        assert_ne!(end0, end1_a, "end 0 and the fat end 1 differ");
    }

    /// A fatter weft pick draws a taller row; the image dimensions are flip-invariant.
    #[test]
    fn fat_weft_pick_heightens_its_row() {
        let mut d = plain_2x2();
        d.weft_thickness = vec![3.0, 1.0]; // pick 0 is 3x tall (now the TOP row after the flip)
        let img = render_rgba(&d, 4);
        // pick 0 -> 12 px, pick 1 -> 4 px => height 16; width unchanged at 8.
        assert_eq!((img.width, img.height), (8, 16));
    }

    /// Default options reproduce the plain render byte for byte (so the goldens and every existing
    /// caller are unaffected by the overlay machinery).
    #[test]
    fn default_options_match_plain_render() {
        let d = plain_2x2();
        let plain = render_rgba(&d, 5);
        let with_default = render_rgba_with(&d, 5, &RenderOptions::default());
        assert_eq!(plain.pixels, with_default.pixels);
    }

    /// Gridlines paint mid-gray seams at interior cell boundaries while leaving cell interiors (and
    /// the outer border) untouched.
    #[test]
    fn gridlines_paint_interior_seams_only() {
        let d = plain_2x2(); // 8x8 at cell 4: one interior vertical seam (x=4), one horizontal (y=4)
        let opts = RenderOptions {
            gridlines: true,
            float_threshold: 0,
            thread_texture: false,
        };
        let img = render_rgba_with(&d, 4, &opts);
        let at = |x: usize, y: usize| -> [u8; 3] {
            let o = (y * 8 + x) * 4;
            [img.pixels[o], img.pixels[o + 1], img.pixels[o + 2]]
        };
        // The final 180° flip moves the interior seams from x=4 / y=4 to x=3 / y=3.
        assert_eq!(at(3, 1), GRID_LINE, "interior vertical seam is gray");
        assert_eq!(at(1, 3), GRID_LINE, "interior horizontal seam is gray");
        // A cell interior keeps its cloth color (pure black/white), never the seam gray.
        assert_ne!(at(1, 1), GRID_LINE, "cell interior is untouched");
        // No outer border: the outer edge column (x=0) is cloth, not a seam.
        assert_ne!(at(0, 1), GRID_LINE, "no seam on the outer edge");
    }

    /// A long warp float gets tinted; below threshold (or with the cue off) the cloth is untouched.
    #[test]
    fn float_highlight_tints_only_long_floats() {
        // 1 end threaded on shaft 1, raised on all 6 picks => one warp float of length 6.
        let d = Draft {
            name: "float".into(),
            shafts: 1,
            treadles: 0,
            shed: ShedType::Rising,
            unit: Unit::Inches,
            threading: Threading(vec![vec![ShaftId(1)]]),
            drive: Drive::Liftplan(Liftplan(vec![vec![ShaftId(1)]; 6])),
            colors: ColorPlan {
                palette: vec![Color::BLACK, Color::WHITE],
                warp: vec![0],
                weft: vec![1; 6],
            },
            warp_thickness: Vec::new(),
            weft_thickness: Vec::new(),
            notes: String::new(),
            retained: Vec::new(),
        };
        let center = |img: &RgbaImage| -> [u8; 3] {
            let o = (2 * img.width as usize + 2) * 4; // somewhere inside the column
            [img.pixels[o], img.pixels[o + 1], img.pixels[o + 2]]
        };

        // Off: the warp cell is pure black (palette idx 0).
        let off = render_rgba(&d, 4);
        assert_eq!(center(&off), [0, 0, 0], "no cue => untouched cloth");

        // Below threshold (need 7+, float is 6): still untouched.
        let high = render_rgba_with(
            &d,
            4,
            &RenderOptions {
                gridlines: false,
                float_threshold: 7,
                thread_texture: false,
            },
        );
        assert_eq!(
            center(&high),
            [0, 0, 0],
            "float shorter than threshold is untouched"
        );

        // At threshold (5 <= 6): tinted toward the warm highlight (no longer pure black).
        let on = render_rgba_with(
            &d,
            4,
            &RenderOptions {
                gridlines: false,
                float_threshold: 5,
                thread_texture: false,
            },
        );
        let c = center(&on);
        assert_ne!(c, [0, 0, 0], "a long float is tinted");
        assert!(c[0] > c[2], "tint is warm (more red than blue)");
    }

    /// One white intersection whose single warp end is RAISED (warp on top) — used to prove the
    /// thread texture shades a warp-faced cell as a VERTICAL thread.
    fn warp_cell() -> Draft {
        Draft {
            name: "warp".into(),
            shafts: 1,
            treadles: 0,
            shed: ShedType::Rising,
            unit: Unit::Inches,
            threading: Threading(vec![vec![ShaftId(1)]]),
            drive: Drive::Liftplan(Liftplan(vec![vec![ShaftId(1)]])),
            colors: ColorPlan {
                palette: vec![Color::WHITE],
                warp: vec![0],
                weft: vec![0],
            },
            warp_thickness: Vec::new(),
            weft_thickness: Vec::new(),
            notes: String::new(),
            retained: Vec::new(),
        }
    }

    /// The same single white intersection but with NOTHING raised (weft on top) — a weft-faced cell,
    /// shaded as a HORIZONTAL thread.
    fn weft_cell() -> Draft {
        let mut d = warp_cell();
        d.drive = Drive::Liftplan(Liftplan(vec![vec![]]));
        d
    }

    /// The texture shades each cell as a rounded strand oriented by its face: a warp-faced cell varies
    /// across its WIDTH (a vertical thread), a weft-faced cell across its HEIGHT (a horizontal one).
    /// Off, the cell stays a flat solid fill.
    #[test]
    fn thread_texture_shades_along_the_thread_direction() {
        let opts = RenderOptions {
            gridlines: false,
            float_threshold: 0,
            thread_texture: true,
        };
        let at = |img: &RgbaImage, x: usize, y: usize| -> i32 {
            let o = (y * img.width as usize + x) * 4;
            img.pixels[o] as i32
        };

        // Warp on top: brighter down the centre line than at a side edge, ~flat down its length.
        let warp = render_rgba_with(&warp_cell(), 8, &opts);
        assert_eq!((warp.width, warp.height), (8, 8));
        assert!(
            at(&warp, 4, 4) > at(&warp, 0, 4) + 20,
            "vertical thread brightens toward its centre line (across the width)"
        );
        assert!(
            (at(&warp, 2, 1) - at(&warp, 2, 6)).abs() <= 4,
            "a warp thread barely changes down its length"
        );

        // Weft on top: the same, rotated — brighter at the centre line across the HEIGHT.
        let weft = render_rgba_with(&weft_cell(), 8, &opts);
        assert!(
            at(&weft, 4, 4) > at(&weft, 4, 0) + 20,
            "horizontal thread brightens toward its centre line (across the height)"
        );
        assert!(
            (at(&weft, 1, 2) - at(&weft, 6, 2)).abs() <= 4,
            "a weft thread barely changes along its length"
        );

        // Off (the default): the whole cell is one flat color — no per-pixel variation.
        let flat = render_rgba_with(&warp_cell(), 8, &RenderOptions::default());
        assert!(
            flat.pixels.chunks_exact(4).all(|p| p == &flat.pixels[0..4]),
            "texture off => flat solid fill"
        );
    }

    /// A caller-supplied `cell_px` (the zoom pitch, untrusted at the FFI) must never overflow the
    /// raster: `w * h * 4` would panic in debug / wrap in release. The checked size guard bails to an
    /// empty image instead of crashing the engine.
    #[test]
    fn huge_cell_px_does_not_overflow_the_raster() {
        let img = render_rgba(&plain_2x2(), u32::MAX);
        assert_eq!((img.width, img.height), (0, 0));
        assert!(img.pixels.is_empty());
    }

    // --- Resource bounds (M7-01) -------------------------------------------------------------

    /// An `ends` x `picks` liftplan draft that raises nothing: cheap to BUILD at any size (the
    /// document is linear in ends + picks), so tests can probe the quadratic drawdown budget.
    fn blank(ends: usize, picks: usize) -> Draft {
        let mut d = plain_2x2();
        d.threading = Threading(vec![vec![ShaftId(1)]; ends]);
        d.drive = Drive::Liftplan(Liftplan(vec![Vec::new(); picks]));
        d.colors.warp = vec![0; ends];
        d.colors.weft = vec![1; picks];
        d
    }

    fn limits(max_cells: usize, max_raster_bytes: usize, max_raster_side: usize) -> RenderLimits {
        RenderLimits {
            max_cells,
            max_raster_bytes,
            max_raster_side,
        }
    }

    /// The pre-M7-01 interlacement, kept verbatim as a test oracle for the lookup-table rewrite.
    fn reference_compute(draft: &Draft) -> Vec<Cell> {
        let mut cells = Vec::new();
        for pick in 0..draft.picks() {
            let raised = draft.raised_shafts(pick);
            let weft_color = draft.colors.weft.get(pick).copied().unwrap_or(0);
            for end in 0..draft.ends() {
                let warp_up = draft
                    .threading
                    .0
                    .get(end)
                    .map(|shafts| shafts.iter().any(|s| raised.contains(s)))
                    .unwrap_or(false);
                cells.push(if warp_up {
                    Cell::WarpUp(draft.colors.warp.get(end).copied().unwrap_or(0))
                } else {
                    Cell::WeftUp(weft_color)
                });
            }
        }
        cells
    }

    proptest::proptest! {
        /// Random drafts (both drives, both sheds, multi-shaft and unthreaded ends, ids past the
        /// header, ragged colors): the bounded drawdown equals the original algorithm cell for cell.
        #[test]
        fn interlacement_matches_the_reference(
            shafts in 1u16..12,
            sinking in proptest::bool::ANY,
            liftplan in proptest::bool::ANY,
            threading in proptest::collection::vec(proptest::collection::vec(1u16..14, 0..3), 0..9),
            rows in proptest::collection::vec(proptest::collection::vec(1u16..14, 0..4), 0..9),
            tieup in proptest::collection::vec(proptest::collection::vec(1u16..14, 0..4), 0..6),
            warp in proptest::collection::vec(0usize..3, 0..9),
            weft in proptest::collection::vec(0usize..3, 0..9),
        ) {
            let mut d = plain_2x2();
            d.shafts = shafts;
            d.shed = if sinking { ShedType::Sinking } else { ShedType::Rising };
            d.threading = Threading(
                threading.iter().map(|e| e.iter().map(|&s| ShaftId(s)).collect()).collect(),
            );
            d.drive = if liftplan {
                Drive::Liftplan(Liftplan(
                    rows.iter().map(|r| r.iter().map(|&s| ShaftId(s)).collect()).collect(),
                ))
            } else {
                Drive::Treadled {
                    tieup: TieUp(
                        tieup.iter().map(|t| t.iter().map(|&s| ShaftId(s)).collect()).collect(),
                    ),
                    treadling: Treadling(
                        rows.iter().map(|r| r.iter().map(|&t| TreadleId(t)).collect()).collect(),
                    ),
                }
            };
            d.colors.warp = warp;
            d.colors.weft = weft;
            proptest::prop_assert_eq!(compute(&d).cells, reference_compute(&d));
        }
    }

    /// The infallible wrapper is exactly the bounded render under the default budget.
    #[test]
    fn render_rgba_with_is_try_render_under_default_limits() {
        let mut fat = plain_2x2();
        fat.warp_thickness = vec![1.0, 2.5];
        fat.weft_thickness = vec![3.0, 1.0];
        let all_on = RenderOptions {
            gridlines: true,
            float_threshold: 2,
            thread_texture: true,
        };
        for d in [plain_2x2(), fat, warp_cell(), weft_cell()] {
            for opts in [RenderOptions::default(), all_on] {
                let legacy = render_rgba_with(&d, 6, &opts);
                let bounded = try_render_rgba_with(&d, 6, &opts, &RenderLimits::DEFAULT).unwrap();
                assert_eq!(legacy, bounded);
            }
        }
    }

    #[test]
    fn try_compute_matches_compute() {
        let mut d = plain_2x2();
        d.shed = ShedType::Sinking;
        d.drive = Drive::Treadled {
            tieup: TieUp(vec![vec![ShaftId(1)], vec![ShaftId(2)]]),
            treadling: Treadling(vec![vec![TreadleId(1)], vec![TreadleId(2)]]),
        };
        assert_eq!(
            try_compute(&d, &RenderLimits::DEFAULT).unwrap(),
            compute(&d)
        );
    }

    #[test]
    fn empty_draft_renders_empty_not_an_error() {
        let img = try_render_rgba_with(
            &blank(0, 5),
            12,
            &RenderOptions::default(),
            &RenderLimits::DEFAULT,
        )
        .unwrap();
        assert_eq!((img.width, img.height, img.pixels.len()), (0, 0, 0));
    }

    #[test]
    fn cell_budget_is_exact() {
        let d = plain_2x2(); // 4 intersections
        let opts = RenderOptions::default();
        assert!(try_render_rgba_with(&d, 1, &opts, &limits(4, usize::MAX, usize::MAX)).is_ok());
        assert_eq!(
            try_render_rgba_with(&d, 1, &opts, &limits(3, usize::MAX, usize::MAX)),
            Err(RenderError::TooManyCells {
                ends: 2,
                picks: 2,
                cells: 4,
                limit: 3
            })
        );
        assert!(matches!(
            try_compute(&d, &limits(3, usize::MAX, usize::MAX)),
            Err(RenderError::TooManyCells { .. })
        ));
    }

    #[test]
    fn raster_byte_and_side_budgets_are_exact() {
        let d = plain_2x2();
        let opts = RenderOptions::default();
        // At 4 px the raster is 8 x 8 = 256 bytes.
        assert!(try_render_rgba_with(&d, 4, &opts, &limits(usize::MAX, 256, 8)).is_ok());
        assert!(matches!(
            try_render_rgba_with(&d, 4, &opts, &limits(usize::MAX, 255, 8)),
            Err(RenderError::RasterTooLarge {
                width: 8,
                height: 8,
                bytes: 256,
                ..
            })
        ));
        assert!(matches!(
            try_render_rgba_with(&d, 4, &opts, &limits(usize::MAX, 256, 7)),
            Err(RenderError::RasterTooLarge { .. })
        ));
    }

    /// A pitch whose raster cannot even be SIZED in `usize` is reported, not wrapped or panicked on.
    #[test]
    fn unsizeable_raster_is_an_overflow_error() {
        let r = try_render_rgba_with(
            &plain_2x2(),
            u32::MAX,
            &RenderOptions::default(),
            &RenderLimits::UNBOUNDED,
        );
        // 64-bit: (2 * 4.29e9)^2 * 4 overflows the byte count. 32-bit: the extents themselves do.
        assert_eq!(r, Err(RenderError::Overflow));
    }

    /// The default budget rejects a 100,000 x 100,000 draft (the largest a WIF can declare) up front,
    /// where the old renderer asked for about 160 GB.
    #[test]
    fn default_budget_rejects_the_largest_wif_draft() {
        let d = blank(100_000, 100_000);
        assert!(matches!(
            try_render_rgba_with(&d, 12, &RenderOptions::default(), &RenderLimits::DEFAULT),
            Err(RenderError::TooManyCells {
                cells: 10_000_000_000,
                ..
            })
        ));
        assert!(matches!(
            fit_cell_px(&d, 12, &RenderLimits::DEFAULT),
            Err(RenderError::TooManyCells { .. })
        ));
    }

    /// A 1000 x 1000 draft used to come back blank at the editor's 12 px; it now fits at a smaller
    /// pitch that renders.
    #[test]
    fn fit_cell_px_finds_the_largest_pitch_that_fits() {
        let lim = RenderLimits::DEFAULT;
        let big = blank(1000, 1000);
        assert!(matches!(
            try_render_rgba_with(&big, 12, &RenderOptions::default(), &lim),
            Err(RenderError::RasterTooLarge { .. })
        ));
        // 64 MiB / 4 bytes = 16.7 M px, so 4000 x 4000 (4 px per cell) fits and 5 px does not.
        assert_eq!(fit_cell_px(&big, 12, &lim), Ok(4));
        // A small draft keeps the requested pitch; 0 is treated as 1.
        assert_eq!(fit_cell_px(&plain_2x2(), 12, &lim), Ok(12));
        assert_eq!(fit_cell_px(&plain_2x2(), 0, &lim), Ok(1));
        // Exact boundary on a tiny budget: 2 x 2 at 4 px = 256 bytes.
        assert_eq!(
            fit_cell_px(&plain_2x2(), 12, &limits(usize::MAX, 256, usize::MAX)),
            Ok(4)
        );
        // Variable thickness widens columns; the fitted pitch still respects the budget.
        let mut fat = plain_2x2();
        fat.warp_thickness = vec![1.0, 3.0];
        let px = fit_cell_px(&fat, 50, &limits(usize::MAX, 4096, usize::MAX)).unwrap();
        let img = try_render_rgba_with(
            &fat,
            px,
            &RenderOptions::default(),
            &limits(usize::MAX, 4096, usize::MAX),
        );
        assert!(img.is_ok());
        assert!(try_render_rgba_with(
            &fat,
            px + 1,
            &RenderOptions::default(),
            &limits(usize::MAX, 4096, usize::MAX)
        )
        .is_err());
    }

    #[test]
    fn fit_cell_px_reports_why_even_one_px_is_too_big() {
        // 10 ends at 1 px is already wider than an 8 px side budget.
        assert!(matches!(
            fit_cell_px(&blank(10, 2), 12, &limits(usize::MAX, usize::MAX, 8)),
            Err(RenderError::RasterTooLarge { width: 10, .. })
        ));
    }

    /// A sinking shed on a huge shaft count raises nearly every shaft; the drawdown must still be
    /// right (and is now linear in size, via the per-pick lookup table).
    #[test]
    fn sinking_shed_with_many_shafts_is_correct() {
        let mut d = plain_2x2();
        d.shafts = u16::MAX;
        d.shed = ShedType::Sinking;
        d.threading = Threading(vec![vec![ShaftId(1)], vec![ShaftId(u16::MAX)]]);
        d.drive = Drive::Treadled {
            tieup: TieUp(vec![vec![ShaftId(1)], vec![ShaftId(u16::MAX)]]),
            treadling: Treadling(vec![vec![TreadleId(1)], vec![TreadleId(2)]]),
        };
        let dd = compute(&d);
        // Pick 0 sinks shaft 1 (everything else rises): end 0 weft-up, end 1 warp-up. Pick 1 inverts.
        assert!(matches!(dd.cell(0, 0), Cell::WeftUp(_)));
        assert!(matches!(dd.cell(1, 0), Cell::WarpUp(_)));
        assert!(matches!(dd.cell(0, 1), Cell::WarpUp(_)));
        assert!(matches!(dd.cell(1, 1), Cell::WeftUp(_)));
    }

    /// The float tint is unchanged by the run-length rewrite: only runs at or over the threshold.
    #[test]
    fn float_mask_marks_runs_at_or_over_threshold() {
        // warp_up, 3 ends x 2 picks, row-major by pick: [W W W] / [W . .]
        let up = [true, true, true, true, false, false];
        assert_eq!(long_float_mask(&up, 3, 2, 0).unwrap(), None);
        let m = long_float_mask(&up, 3, 2, 2).unwrap().unwrap();
        // End 0 is a 2-long warp float; pick 1's two weft-up cells are a 2-long weft float.
        assert_eq!(m, vec![true, false, false, true, true, true]);
        let m3 = long_float_mask(&up, 3, 2, 3).unwrap().unwrap();
        assert_eq!(m3, vec![false; 6]);
    }
}
