//! Drawdown computation and rendering.
//!
//! The drawdown is the over/under interlacement grid — what the cloth actually looks
//! like. It is a pure function of the draft and cheap to recompute (microseconds for
//! normal drafts), which is what makes live preview feel instant.

use crate::draft::{ColorIndex, Draft};
use serde::{Deserialize, Serialize};
use ply_common::Color;

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

/// Compute the drawdown for a draft. Deterministic; the heart of the engine.
pub fn compute(draft: &Draft) -> Drawdown {
    let ends = draft.ends();
    let picks = draft.picks();
    let mut cells = Vec::with_capacity(ends * picks);

    for pick in 0..picks {
        let raised = draft.raised_shafts(pick);
        let weft_color = draft.colors.weft.get(pick).copied().unwrap_or(0);
        for end in 0..ends {
            // Is this warp end on a raised shaft?
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

    Drawdown { ends, picks, cells }
}

/// A flat RGBA8 image buffer suitable for handing to Flutter (decode into a `ui.Image`).
#[derive(Debug, Clone, PartialEq)]
pub struct RgbaImage {
    pub width: u32,
    pub height: u32,
    pub pixels: Vec<u8>,
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
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
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

impl Default for RenderOptions {
    fn default() -> Self {
        RenderOptions { gridlines: false, float_threshold: 0, thread_texture: false }
    }
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
pub fn render_rgba_with(draft: &Draft, cell_px: u32, opts: &RenderOptions) -> RgbaImage {
    let dd = compute(draft);
    if dd.ends == 0 || dd.picks == 0 {
        return RgbaImage { width: 0, height: 0, pixels: Vec::new() };
    }
    let base = cell_px.max(1) as usize;
    let col_w = thread_extents(&draft.warp_thickness, dd.ends, base);
    let row_h = thread_extents(&draft.weft_thickness, dd.picks, base);

    // Cumulative left edge per end (end 0 at the left); total width is the running sum.
    let mut col_left = Vec::with_capacity(dd.ends);
    let mut acc = 0usize;
    for &cw in &col_w {
        col_left.push(acc);
        acc += cw;
    }
    let w = acc;

    // Pick 0 sits at the BOTTOM, so build top edges from the bottom up: a pick's top edge is the
    // image height minus the cloth woven up to and including it.
    let h: usize = row_h.iter().sum();

    // Guard the raster allocation: w/h derive from untrusted dimensions and the caller's cell_px, so
    // `w * h * 4` can overflow `usize` (a debug panic, or a release wrap -> under-alloc -> OOB writes)
    // or demand a petabyte buffer. Size it with CHECKED math and bail to an empty image past a cap.
    const MAX_RASTER_BYTES: usize = 512 * 1024 * 1024; // 512 MB
    let Some(total) = w
        .checked_mul(h)
        .and_then(|wh| wh.checked_mul(4))
        .filter(|&t| t <= MAX_RASTER_BYTES)
    else {
        return RgbaImage { width: 0, height: 0, pixels: Vec::new() };
    };

    let mut row_top = vec![0usize; dd.picks];
    let mut from_bottom = 0usize;
    for pick in 0..dd.picks {
        from_bottom += row_h[pick];
        row_top[pick] = h - from_bottom;
    }

    let mask = long_float_mask(&dd, opts.float_threshold as usize);
    let mut px = vec![0u8; total];
    let palette = &draft.colors.palette;
    let color_at = |idx: ColorIndex| -> Color { palette.get(idx).copied().unwrap_or(Color::WHITE) };

    for pick in 0..dd.picks {
        let top = row_top[pick];
        let ch = row_h[pick];
        for end in 0..dd.ends {
            let cell = dd.cell(end, pick);
            // Warp on top => a vertical thread; weft on top => a horizontal one. Drives the texture's
            // shading axis below.
            let warp_up = matches!(cell, Cell::WarpUp(_));
            let base_c = match cell {
                Cell::WarpUp(i) | Cell::WeftUp(i) => color_at(i),
            };
            // Tint cells that belong to a long float so they read at a glance (over any palette).
            let c = if mask[pick * dd.ends + end] {
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
        draw_gridlines(&mut px, w, h, &col_left, &row_top, dd.ends, dd.picks);
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

    RgbaImage { width: w as u32, height: h as u32, pixels: px }
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
    Color::rgb(mix(base.r, over[0]), mix(base.g, over[1]), mix(base.b, over[2]))
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
    let f = |ch: u8| ((ch as f32) * mul + ridge * 255.0).round().clamp(0.0, 255.0) as u8;
    Color::rgb(f(c.r), f(c.g), f(c.b))
}

/// Mark every cell that belongs to a float — a maximal run of same-face cells along the warp (down
/// a column) or weft (across a row) — of length `>= threshold`. A `threshold` below 2 marks nothing
/// (a "float" of one is just ordinary interlacement). The flat mask is indexed like the drawdown.
fn long_float_mask(dd: &Drawdown, threshold: usize) -> Vec<bool> {
    let mut mask = vec![false; dd.cells.len()];
    if threshold < 2 {
        return mask;
    }
    // Warp floats: consecutive WarpUp down each column. The `0..=picks` sweep uses the final
    // out-of-range step as a sentinel that flushes a run ending at the top edge.
    for end in 0..dd.ends {
        let mut run: Vec<usize> = Vec::new();
        for pick in 0..=dd.picks {
            let is_warp = pick < dd.picks && matches!(dd.cell(end, pick), Cell::WarpUp(_));
            if is_warp {
                run.push(pick);
            } else {
                if run.len() >= threshold {
                    for &p in &run {
                        mask[p * dd.ends + end] = true;
                    }
                }
                run.clear();
            }
        }
    }
    // Weft floats: consecutive WeftUp across each row.
    for pick in 0..dd.picks {
        let mut run: Vec<usize> = Vec::new();
        for end in 0..=dd.ends {
            let is_weft = end < dd.ends && matches!(dd.cell(end, pick), Cell::WeftUp(_));
            if is_weft {
                run.push(end);
            } else {
                if run.len() >= threshold {
                    for &e in &run {
                        mask[pick * dd.ends + e] = true;
                    }
                }
                run.clear();
            }
        }
    }
    mask
}

/// Draw interior cell-boundary seams (one between each pair of adjacent ends/picks; no outer
/// border) in [`GRID_LINE`], aligned to the variable cell positions so the grid stays true under
/// per-thread thickness.
fn draw_gridlines(
    px: &mut [u8],
    w: usize,
    h: usize,
    col_left: &[usize],
    row_top: &[usize],
    ends: usize,
    picks: usize,
) {
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
    for end in 1..ends {
        let x = col_left[end];
        for y in 0..h {
            set(x, y);
        }
    }
    // Horizontal seams at the top edge of every cell except the topmost pick (whose top edge is the
    // outer image border at y == 0).
    for &y in row_top.iter().take(picks) {
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

        assert_eq!((scaled.width, scaled.height), (uniform.width, uniform.height));
        assert_eq!(scaled.pixels, uniform.pixels, "uniform thickness == plain grid");
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
        let opts = RenderOptions { gridlines: true, float_threshold: 0, thread_texture: false };
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
            &RenderOptions { gridlines: false, float_threshold: 7, thread_texture: false },
        );
        assert_eq!(center(&high), [0, 0, 0], "float shorter than threshold is untouched");

        // At threshold (5 <= 6): tinted toward the warm highlight (no longer pure black).
        let on = render_rgba_with(
            &d,
            4,
            &RenderOptions { gridlines: false, float_threshold: 5, thread_texture: false },
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
            colors: ColorPlan { palette: vec![Color::WHITE], warp: vec![0], weft: vec![0] },
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
        let opts = RenderOptions { gridlines: false, float_threshold: 0, thread_texture: true };
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
}
