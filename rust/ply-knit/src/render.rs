//! Chart rendering: a [`KnitPattern`] chart -> a flat RGBA8 buffer, the knitting analog of
//! `ply-weave`'s `drawdown.rs`. Unlike weaving (where the drawdown is COMPUTED from the draft), the
//! knitting chart IS the editable source, so rendering is a straight draw of the stored grid.
//!
//! Each cell is a `cell_px` square. A cell shows its colorwork color (if any) as the background and a
//! stitch SYMBOL on top; a no-stitch cell is grey; a cable is one glyph drawn across the columns it
//! spans. Rows are drawn BOTTOM-TO-TOP (row 0 at the bottom — knitting charts read upward), matching
//! the weaving bitmap convention so the Flutter side blits it without a flip.
//!
//! Authored repeats do not change the raster: the chart shows the cells AS DRAWN (one copy of each
//! motif), and the app draws the repeat brackets as an overlay.
//! What the knitter works, motifs expanded, is [`crate::instruction`]'s business.
//!
//! The v1 symbol set is deliberately simple, recognizable primitives (dot / ring / diagonals / bars),
//! not the full CYC/StitchMastery glyph font — that fidelity is a later refinement. The whole buffer
//! is computed in Rust and handed across the FFI in one shot (never per cell).

use crate::pattern::{builtin, Cell, Cross, KnitPattern};
use ply_common::Color;

/// A flat RGBA8 image buffer (same shape as weaving's, but local so `ply-knit` stays independent).
#[derive(Debug, Clone, PartialEq)]
pub struct RgbaImage {
    pub width: u32,
    pub height: u32,
    pub pixels: Vec<u8>,
}

const CHART_BG: Color = Color::rgb(250, 248, 244); // a faint cream so symbols read
const SYMBOL_DARK: Color = Color::rgb(40, 40, 40);
const SYMBOL_LIGHT: Color = Color::rgb(245, 245, 245);
const NO_STITCH: Color = Color::rgb(205, 205, 205); // the conventional grey "no stitch" square
const GRID_LINE: Color = Color::rgb(180, 180, 180);

/// A guard on the raster size (untrusted dimensions + caller `cell_px`): bail to an empty image past
/// this, never overflow/OOM. Mirrors the weaving renderer's cap.
const MAX_RASTER_BYTES: usize = 512 * 1024 * 1024;

/// Render the chart to an RGBA8 buffer at `cell_px` pixels per cell. An empty chart (0 width or
/// height) or an over-large raster yields a 0x0 image (the caller treats that as "nothing to show").
pub fn render_rgba(pattern: &KnitPattern, cell_px: u32) -> RgbaImage {
    let chart = &pattern.chart;
    let s = cell_px.max(1) as usize;
    let cols = chart.width;
    let rows = chart.rows.len();
    if cols == 0 || rows == 0 {
        return RgbaImage {
            width: 0,
            height: 0,
            pixels: Vec::new(),
        };
    }
    // `cols`/`rows` are untrusted (`chart.width` need not match the backing cells, and `cell_px` is
    // caller-supplied), so the dimension multiplies themselves can overflow `usize` BEFORE the raster
    // cap below — guard them with `checked_mul` too, not just `w * h * 4`.
    let Some((w, h, total)) = cols
        .checked_mul(s)
        .zip(rows.checked_mul(s))
        .and_then(|(w, h)| Some((w, h, w.checked_mul(h)?.checked_mul(4)?)))
        .filter(|&(_, _, t)| t <= MAX_RASTER_BYTES)
    else {
        return RgbaImage {
            width: 0,
            height: 0,
            pixels: Vec::new(),
        };
    };
    let mut px = vec![0u8; total];

    for (r, row) in chart.rows.iter().enumerate() {
        // Row 0 sits at the BOTTOM: its top pixel edge is h - (r+1)*s.
        let y0 = h - (r + 1) * s;
        let mut col = 0usize;
        while col < cols {
            let cell = row.cells.get(col).copied().unwrap_or(Cell {
                stitch: builtin::KNIT,
                color: None,
            });
            let x0 = col * s;
            // A cable spans several columns; draw it once across its (bounds-clamped) span and skip
            // the no-stitch fillers it covers.
            let span = cable_span(pattern, cell).min(cols - col).max(1);
            draw_cell(&mut px, w, h, x0, y0, s, span, pattern, cell);
            col += span;
        }
    }

    draw_gridlines(&mut px, w, h, s, cols, rows);
    RgbaImage {
        width: w as u32,
        height: h as u32,
        pixels: px,
    }
}

/// The column span of a cell: a cable's `span`, else 1.
fn cable_span(pattern: &KnitPattern, cell: Cell) -> usize {
    pattern
        .legend
        .get(cell.stitch)
        .and_then(|d| d.cable)
        .map(|c| c.span() as usize)
        .unwrap_or(1)
        .max(1)
}

/// Fill one cell's (possibly multi-column) box with its background and draw its stitch symbol.
fn draw_cell(
    px: &mut [u8],
    w: usize,
    h: usize,
    x0: usize,
    y0: usize,
    s: usize,
    span: usize,
    pattern: &KnitPattern,
    cell: Cell,
) {
    let bw = span * s; // box width (1 cell, or a cable's span)
    let stitch = cell.stitch;
    let is_no_stitch = stitch == builtin::NO_STITCH;

    // Background: no-stitch grey, else the colorwork color, else the cream chart ground.
    let bg = if is_no_stitch {
        NO_STITCH
    } else {
        cell.color
            .and_then(|i| pattern.palette.get(i).copied())
            .unwrap_or(CHART_BG)
    };
    fill_rect(px, w, h, x0, y0, bw, s, bg);
    if is_no_stitch {
        return;
    }

    // Symbol colour contrasts the background so it reads on a dark colorwork cell too.
    let sym = if luminance(bg) > 140 {
        SYMBOL_DARK
    } else {
        SYMBOL_LIGHT
    };
    // Inset margin, capped so it never exceeds a tiny (even 1px) cell; the far edges use SATURATING
    // subtraction so a small cell_px can't underflow usize and panic.
    let m = (s / 5).max(1).min(s.saturating_sub(1).max(1));
    let left = x0 + m;
    let right = (x0 + bw).saturating_sub(1 + m);
    let top = y0 + m;
    let bottom = (y0 + s).saturating_sub(1 + m);
    let cx = x0 + bw / 2;
    let cy = y0 + s / 2;

    // A cable is drawn across its whole span; everything else fits one cell.
    if let Some(cable) = pattern.legend.get(stitch).and_then(|d| d.cable) {
        // A cable crossing reads as two diagonals, but RC and LC must look different (the chart's
        // only cue to which way the cable leans). The OVER strand is a continuous diagonal whose
        // lean encodes the cross direction; the UNDER strand is the opposite diagonal drawn BROKEN
        // at the crossing so it reads as passing behind. Right cross leans "/", left cross "\".
        match cable.direction {
            Cross::Right => {
                draw_line(px, w, h, left, bottom, right, top, sym); // "/" over (continuous)
                draw_broken_line(px, w, h, left, top, right, bottom, sym); // "\" under (behind)
            }
            Cross::Left => {
                draw_line(px, w, h, left, top, right, bottom, sym); // "\" over (continuous)
                draw_broken_line(px, w, h, left, bottom, right, top, sym); // "/" under (behind)
            }
        }
        return;
    }

    match stitch {
        builtin::KNIT => {} // blank
        builtin::PURL => draw_disc(px, w, h, cx, cy, (s / 8).max(1), sym),
        builtin::YO => draw_ring(px, w, h, cx, cy, (s / 2).saturating_sub(m).max(1), sym),
        builtin::K2TOG => draw_line(px, w, h, left, bottom, right, top, sym), // /
        builtin::SSK => draw_line(px, w, h, left, top, right, bottom, sym),   // \
        builtin::P2TOG => {
            draw_line(px, w, h, left, bottom, right, top, sym); // / with a purl dot
            draw_disc(px, w, h, cx, top, (s / 10).max(1), sym);
        }
        builtin::CDD => draw_line(px, w, h, cx, top, cx, bottom, sym), // |
        builtin::M1L => {
            // a "<" (left-make)
            draw_line(px, w, h, cx, top, left, cy, sym);
            draw_line(px, w, h, left, cy, cx, bottom, sym);
        }
        builtin::M1R => {
            // a ">" (right-make)
            draw_line(px, w, h, cx, top, right, cy, sym);
            draw_line(px, w, h, right, cy, cx, bottom, sym);
        }
        builtin::KFB => {
            // a "+" (increase)
            draw_line(px, w, h, left, cy, right, cy, sym);
            draw_line(px, w, h, cx, top, cx, bottom, sym);
        }
        builtin::SLIP => {
            // a "V"
            draw_line(px, w, h, left, top, cx, bottom, sym);
            draw_line(px, w, h, cx, bottom, right, top, sym);
        }
        builtin::KTBL => {
            // a twisted knit: the knit column (|) with a diagonal twist (/) crossing it.
            draw_line(px, w, h, cx, top, cx, bottom, sym);
            draw_line(px, w, h, left, bottom, right, top, sym);
        }
        // The appended shaping stitches (ids 12..=19) extend the same families: a double decrease
        // leans like its single decrease with a second leg converging on the same corner, a purl-side
        // stitch is its knit-side shape plus the purl dot (as p2tog is k2tog's "/" plus a dot), and a
        // mirrored stitch is its partner's shape mirrored or turned.
        builtin::K3TOG => {
            // a right-leaning fan: k2tog's "/" plus a second leg from the bottom center, both
            // meeting at the top right (three stitches into one, leaning right).
            draw_line(px, w, h, left, bottom, right, top, sym);
            draw_line(px, w, h, cx, bottom, right, top, sym);
        }
        builtin::SK2PO => {
            // the left-leaning fan: ssk's "\" plus a second leg, both meeting at the top left.
            draw_line(px, w, h, right, bottom, left, top, sym);
            draw_line(px, w, h, cx, bottom, left, top, sym);
        }
        builtin::SSP => {
            // ssk's "\" with a purl dot (p2tog's mirror).
            draw_line(px, w, h, left, top, right, bottom, sym);
            draw_disc(px, w, h, cx, top, (s / 10).max(1), sym);
        }
        builtin::KBF => {
            // kfb's "+" turned a quarter: an "x" of two unbroken diagonals in one cell (a cable is
            // always several cells wide, and its under strand is broken).
            draw_line(px, w, h, left, top, right, bottom, sym);
            draw_line(px, w, h, left, bottom, right, top, sym);
        }
        builtin::PFB => {
            // kfb's "+" with a purl dot in the upper left quarter.
            draw_line(px, w, h, left, cy, right, cy, sym);
            draw_line(px, w, h, cx, top, cx, bottom, sym);
            draw_disc(
                px,
                w,
                h,
                halfway(left, cx),
                halfway(top, cy),
                (s / 10).max(1),
                sym,
            );
        }
        builtin::M1P => {
            // a make-one with no lean: an upward caret "^" with a purl dot under its point.
            draw_line(px, w, h, left, bottom, cx, top, sym);
            draw_line(px, w, h, cx, top, right, bottom, sym);
            draw_disc(px, w, h, cx, (cy + bottom) / 2, (s / 10).max(1), sym);
        }
        builtin::M1LP => {
            // m1l's "<" with a purl dot in the open right half.
            draw_line(px, w, h, cx, top, left, cy, sym);
            draw_line(px, w, h, left, cy, cx, bottom, sym);
            draw_disc(px, w, h, halfway(right, cx), cy, (s / 10).max(1), sym);
        }
        builtin::M1RP => {
            // m1r's ">" with a purl dot in the open left half.
            draw_line(px, w, h, cx, top, right, cy, sym);
            draw_line(px, w, h, right, cy, cx, bottom, sym);
            draw_disc(px, w, h, halfway(left, cx), cy, (s / 10).max(1), sym);
        }
        _ => {
            // Unknown / custom stitch: a hollow square placeholder.
            draw_rect_outline(px, w, h, left, top, right, bottom, sym);
        }
    }
}

/// The point halfway from `from` toward `to`, rounded toward `from`, in either direction (so a dot
/// placed halfway from the left edge mirrors one placed halfway from the right edge), without
/// underflowing on a cell too small for its margins.
fn halfway(from: usize, to: usize) -> usize {
    if to >= from {
        from + (to - from) / 2
    } else {
        from - (from - to) / 2
    }
}

// --- pixel primitives (all bounds-checked) ---------------------------------------------------------

fn set_px(px: &mut [u8], w: usize, h: usize, x: usize, y: usize, c: Color) {
    if x >= w || y >= h {
        return;
    }
    let o = (y * w + x) * 4;
    px[o] = c.r;
    px[o + 1] = c.g;
    px[o + 2] = c.b;
    px[o + 3] = 255;
}

fn fill_rect(
    px: &mut [u8],
    w: usize,
    h: usize,
    x0: usize,
    y0: usize,
    rw: usize,
    rh: usize,
    c: Color,
) {
    for y in y0..(y0 + rh).min(h) {
        for x in x0..(x0 + rw).min(w) {
            set_px(px, w, h, x, y, c);
        }
    }
}

fn draw_rect_outline(
    px: &mut [u8],
    w: usize,
    h: usize,
    x0: usize,
    y0: usize,
    x1: usize,
    y1: usize,
    c: Color,
) {
    draw_line(px, w, h, x0, y0, x1, y0, c);
    draw_line(px, w, h, x0, y1, x1, y1, c);
    draw_line(px, w, h, x0, y0, x0, y1, c);
    draw_line(px, w, h, x1, y0, x1, y1, c);
}

/// Integer Bresenham line.
fn draw_line(
    px: &mut [u8],
    w: usize,
    h: usize,
    x0: usize,
    y0: usize,
    x1: usize,
    y1: usize,
    c: Color,
) {
    let (mut x0, mut y0) = (x0 as i64, y0 as i64);
    let (x1, y1) = (x1 as i64, y1 as i64);
    let dx = (x1 - x0).abs();
    let dy = -(y1 - y0).abs();
    let sx = if x0 < x1 { 1 } else { -1 };
    let sy = if y0 < y1 { 1 } else { -1 };
    let mut err = dx + dy;
    loop {
        if x0 >= 0 && y0 >= 0 {
            set_px(px, w, h, x0 as usize, y0 as usize, c);
        }
        if x0 == x1 && y0 == y1 {
            break;
        }
        let e2 = 2 * err;
        if e2 >= dy {
            err += dy;
            x0 += sx;
        }
        if e2 <= dx {
            err += dx;
            y0 += sy;
        }
    }
}

/// A diagonal drawn with a gap across its middle (~22% of the span): the two end stubs only, so a
/// crossing strand reads as passing *behind* the continuous (over) strand of a cable.
fn draw_broken_line(
    px: &mut [u8],
    w: usize,
    h: usize,
    x0: usize,
    y0: usize,
    x1: usize,
    y1: usize,
    c: Color,
) {
    let (x0i, y0i, x1i, y1i) = (x0 as i64, y0 as i64, x1 as i64, y1 as i64);
    // Linear interpolate along the segment with integer math (num/den of the way from p0 to p1).
    let lerp = |a: i64, b: i64, num: i64, den: i64| (a + (b - a) * num / den) as usize;
    let (ax, ay) = (lerp(x0i, x1i, 39, 100), lerp(y0i, y1i, 39, 100));
    let (bx, by) = (lerp(x0i, x1i, 61, 100), lerp(y0i, y1i, 61, 100));
    draw_line(px, w, h, x0, y0, ax, ay, c); // first stub (start -> 39%)
    draw_line(px, w, h, bx, by, x1, y1, c); // second stub (61% -> end)
}

/// A filled disc (midpoint, brute-force over the bounding box).
fn draw_disc(px: &mut [u8], w: usize, h: usize, cx: usize, cy: usize, r: usize, c: Color) {
    let r = r as i64;
    let (cx, cy) = (cx as i64, cy as i64);
    for y in (cy - r)..=(cy + r) {
        for x in (cx - r)..=(cx + r) {
            if x >= 0 && y >= 0 {
                let (dx, dy) = (x - cx, y - cy);
                if dx * dx + dy * dy <= r * r {
                    set_px(px, w, h, x as usize, y as usize, c);
                }
            }
        }
    }
}

/// A circle outline (1px-ish ring via the distance band).
fn draw_ring(px: &mut [u8], w: usize, h: usize, cx: usize, cy: usize, r: usize, c: Color) {
    let r = r as i64;
    let (cx, cy) = (cx as i64, cy as i64);
    let (inner, outer) = ((r - 1) * (r - 1), r * r);
    for y in (cy - r)..=(cy + r) {
        for x in (cx - r)..=(cx + r) {
            if x >= 0 && y >= 0 {
                let (dx, dy) = (x - cx, y - cy);
                let d2 = dx * dx + dy * dy;
                if d2 <= outer && d2 >= inner {
                    set_px(px, w, h, x as usize, y as usize, c);
                }
            }
        }
    }
}

/// Interior cell-boundary seams (no outer border), aligned to the cell grid.
fn draw_gridlines(px: &mut [u8], w: usize, h: usize, s: usize, cols: usize, rows: usize) {
    for c in 1..cols {
        let x = c * s;
        for y in 0..h {
            set_px(px, w, h, x, y, GRID_LINE);
        }
    }
    for r in 1..rows {
        let y = r * s;
        for x in 0..w {
            set_px(px, w, h, x, y, GRID_LINE);
        }
    }
}

/// Perceptual-ish luminance (the WCAG-weighted integer form) for symbol-contrast choice.
fn luminance(c: Color) -> u32 {
    (c.r as u32 * 299 + c.g as u32 * 587 + c.b as u32 * 114) / 1000
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::pattern::*;
    use ply_common::Unit;

    fn pat(width: usize, rows: Vec<Row>, palette: Vec<Color>) -> KnitPattern {
        KnitPattern {
            name: "t".into(),
            construction: Construction::Flat,
            first_row_side: Side::Rs,
            cast_on: None,
            gauge: Gauge {
                sts: 20.0,
                rows: 28.0,
                unit: Unit::Inches,
            },
            palette,
            legend: StitchLegend::builtin(),
            chart: Chart { width, rows },
            notes: String::new(),
            sections: Vec::new(),
        }
    }

    fn px_at(img: &RgbaImage, x: usize, y: usize) -> [u8; 3] {
        let o = (y * img.width as usize + x) * 4;
        [img.pixels[o], img.pixels[o + 1], img.pixels[o + 2]]
    }

    #[test]
    fn huge_width_times_cellpx_yields_empty_not_panic() {
        let big = 1usize << 40;
        let row = Row::plain(vec![Cell::of(builtin::KNIT)]);
        let p = pat(big, vec![row], vec![Color::WHITE]);
        let img = render_rgba(&p, 1u32 << 30); // cols*s = 2^70 -> must bail, not overflow
        assert_eq!((img.width, img.height), (0, 0));
        assert!(img.pixels.is_empty());
    }

    #[test]
    fn empty_chart_renders_empty() {
        let p = pat(0, vec![], vec![Color::WHITE]);
        let img = render_rgba(&p, 8);
        assert_eq!((img.width, img.height), (0, 0));
        assert!(img.pixels.is_empty());
    }

    #[test]
    fn dimensions_are_cols_x_rows_times_cell() {
        let k = Cell::of(builtin::KNIT);
        let p = pat(
            3,
            vec![Row::plain(vec![k, k, k]), Row::plain(vec![k, k, k])],
            vec![Color::WHITE],
        );
        let img = render_rgba(&p, 10);
        assert_eq!((img.width, img.height), (30, 20));
        assert_eq!(img.pixels.len(), 30 * 20 * 4);
    }

    #[test]
    fn colorwork_cell_fills_with_its_palette_color() {
        let red = Color::rgb(200, 0, 0);
        let cell = Cell::colored(builtin::KNIT, 1);
        let p = pat(1, vec![Row::plain(vec![cell])], vec![Color::WHITE, red]);
        let img = render_rgba(&p, 12);
        // Center pixel of the only cell is the colorwork red (knit draws no symbol over it).
        assert_eq!(px_at(&img, 6, 6), [200, 0, 0]);
    }

    #[test]
    fn no_stitch_cell_is_grey() {
        let p = pat(
            1,
            vec![Row::plain(vec![Cell::of(builtin::NO_STITCH)])],
            vec![Color::WHITE],
        );
        let img = render_rgba(&p, 12);
        assert_eq!(px_at(&img, 6, 6), [NO_STITCH.r, NO_STITCH.g, NO_STITCH.b]);
    }

    #[test]
    fn row_zero_is_at_the_bottom() {
        // Row 0 = a colorwork red cell; row 1 = a knit (cream). Red must be in the BOTTOM half.
        let r0 = Row::plain(vec![Cell::colored(builtin::KNIT, 1)]);
        let r1 = Row::plain(vec![Cell::of(builtin::KNIT)]);
        let p = pat(1, vec![r0, r1], vec![Color::WHITE, Color::rgb(200, 0, 0)]);
        let img = render_rgba(&p, 10); // 10x20
        assert_eq!(
            px_at(&img, 5, 15),
            [200, 0, 0],
            "row 0 (red) is the bottom cell"
        );
        assert_eq!(
            px_at(&img, 5, 5),
            [CHART_BG.r, CHART_BG.g, CHART_BG.b],
            "row 1 (knit) is on top"
        );
    }

    #[test]
    fn a_symbol_marks_a_non_knit_cell() {
        // A purl cell draws a dark dot at center over the cream ground (so the center isn't cream).
        let p = pat(
            1,
            vec![Row::plain(vec![Cell::of(builtin::PURL)])],
            vec![Color::WHITE],
        );
        let img = render_rgba(&p, 16);
        assert_eq!(
            px_at(&img, 8, 8),
            [SYMBOL_DARK.r, SYMBOL_DARK.g, SYMBOL_DARK.b],
            "purl dot"
        );
    }

    #[test]
    fn ktbl_draws_a_twisted_knit_symbol() {
        // ktbl draws a vertical bar (the knit column) crossing the cell center, so (cx, cy) is the dark
        // symbol over the cream ground — distinct from a plain knit, which leaves the center cream.
        let p = pat(
            1,
            vec![Row::plain(vec![Cell::of(builtin::KTBL)])],
            vec![Color::WHITE],
        );
        let img = render_rgba(&p, 16);
        assert_eq!(
            px_at(&img, 8, 8),
            [SYMBOL_DARK.r, SYMBOL_DARK.g, SYMBOL_DARK.b],
            "ktbl twist bar"
        );
    }

    #[test]
    fn tiny_cell_px_does_not_panic() {
        // Tiny cells must not underflow the inset math (a glyph cell with margins), for every
        // built-in symbol (pfb's dot once underflowed at 1 px) and the custom-stitch square.
        let mut legend = StitchLegend::builtin();
        legend.stitches.push(StitchDef::simple("bobble", None));
        let cells: Vec<Cell> = (0..legend.stitches.len()).map(Cell::of).collect();
        let mut p = pat(cells.len(), vec![Row::plain(cells)], vec![Color::WHITE]);
        p.legend = legend;
        for cell_px in 1..=6 {
            let img = render_rgba(&p, cell_px);
            assert_eq!(img.height, cell_px);
        }
    }

    #[test]
    fn cable_spans_its_columns_without_panic() {
        let cable = CableDef {
            front: 2,
            back: 2,
            direction: Cross::Right,
            front_purl: false,
            back_purl: false,
        };
        let mut legend = StitchLegend::builtin();
        legend.stitches.push(StitchDef {
            symbol: "2/2RC".into(),
            consumes: 4,
            produces: 4,
            ws_variant: None,
            cable: Some(cable),
            macro_rows: 1,
        });
        let cable_id = legend.stitches.len() - 1;
        let ns = Cell::of(builtin::NO_STITCH);
        let row = Row::plain(vec![Cell::of(cable_id), ns, ns, ns]);
        let mut p = pat(4, vec![row], vec![Color::WHITE]);
        p.legend = legend;
        let img = render_rgba(&p, 10);
        assert_eq!((img.width, img.height), (40, 10));
        // The cable's crossing diagonals are NOT grey (the trailing no-stitch fillers were drawn as
        // part of the cable box, i.e. cream + symbol, not the grey no-stitch fill).
        let mut saw_symbol = false;
        for x in 0..40 {
            if px_at(&img, x, 5) == [SYMBOL_DARK.r, SYMBOL_DARK.g, SYMBOL_DARK.b] {
                saw_symbol = true;
            }
            assert_ne!(
                px_at(&img, x, 5),
                [NO_STITCH.r, NO_STITCH.g, NO_STITCH.b],
                "no grey under a cable"
            );
        }
        assert!(saw_symbol, "the cable crossing is drawn");
    }

    #[test]
    fn left_and_right_cross_cables_render_differently() {
        // Same geometry, opposite cross direction -> the rasters must differ (the over strand leans
        // the other way and the broken under strand mirrors it).
        fn cable_img(dir: Cross) -> RgbaImage {
            let cable = CableDef {
                front: 2,
                back: 2,
                direction: dir,
                front_purl: false,
                back_purl: false,
            };
            let mut legend = StitchLegend::builtin();
            legend.stitches.push(StitchDef {
                symbol: "2/2".into(),
                consumes: 4,
                produces: 4,
                ws_variant: None,
                cable: Some(cable),
                macro_rows: 1,
            });
            let cable_id = legend.stitches.len() - 1;
            let ns = Cell::of(builtin::NO_STITCH);
            let row = Row::plain(vec![Cell::of(cable_id), ns, ns, ns]);
            let mut p = pat(4, vec![row], vec![Color::WHITE]);
            p.legend = legend;
            render_rgba(&p, 12)
        }
        let rc = cable_img(Cross::Right);
        let lc = cable_img(Cross::Left);
        assert_eq!((rc.width, rc.height), (lc.width, lc.height));
        assert_ne!(
            rc.pixels, lc.pixels,
            "a right cross must not look identical to a left cross"
        );
    }

    /// One cell of `stitch` on `ground` (palette index 1 when given), as the chart and the stitch
    /// key draw it.
    fn glyph(stitch: StitchId, ground: Option<Color>, cell_px: u32) -> RgbaImage {
        let cell = match ground {
            Some(_) => Cell::colored(stitch, 1),
            None => Cell::of(stitch),
        };
        let mut legend = StitchLegend::builtin();
        legend.stitches.push(StitchDef::simple("bobble", None)); // a custom stitch
        let mut p = pat(
            1,
            vec![Row::plain(vec![cell])],
            vec![Color::WHITE, ground.unwrap_or(Color::WHITE)],
        );
        p.legend = legend;
        render_rgba(&p, cell_px)
    }

    #[test]
    fn every_builtin_stitch_has_its_own_symbol() {
        // The chart is the knitter's only cue to which stitch a cell is, so no two built-ins may draw
        // alike, and none may look like the custom-stitch placeholder (the hollow square). Checked at
        // the editor's and the PDF's cell sizes, on the cream ground and on a dark colorwork ground
        // (where the symbol is drawn light).
        let custom = StitchLegend::builtin().stitches.len();
        let ids: Vec<StitchId> = (builtin::KNIT..=builtin::KTBL).chain([custom]).collect();
        for cell_px in [12, 16, 24, 32] {
            for ground in [None, Some(Color::rgb(30, 40, 90))] {
                let images: Vec<(StitchId, RgbaImage)> = ids
                    .iter()
                    .map(|&id| (id, glyph(id, ground, cell_px)))
                    .collect();
                for (i, (a, ia)) in images.iter().enumerate() {
                    for (b, ib) in &images[i + 1..] {
                        assert!(
                            ia.pixels != ib.pixels,
                            "stitches {a} and {b} draw alike at {cell_px} px on {ground:?}"
                        );
                    }
                }
            }
        }
    }

    #[test]
    fn appended_shaping_stitches_follow_their_families() {
        // ssp mirrors p2tog: each is a single diagonal with the purl dot at the top center, so the
        // mirrored image of one is the other.
        let mirror = |img: &RgbaImage| -> Vec<u8> {
            let (w, h) = (img.width as usize, img.height as usize);
            let mut out = Vec::with_capacity(img.pixels.len());
            for y in 0..h {
                for x in (0..w).rev() {
                    let o = (y * w + x) * 4;
                    out.extend_from_slice(&img.pixels[o..o + 4]);
                }
            }
            out
        };
        // A cell whose margins are symmetric (odd size: the center column is the middle column).
        let s = 25;
        assert!(
            mirror(&glyph(builtin::K3TOG, None, s)) == glyph(builtin::SK2PO, None, s).pixels,
            "sk2po is k3tog mirrored"
        );
        assert!(
            mirror(&glyph(builtin::M1LP, None, s)) == glyph(builtin::M1RP, None, s).pixels,
            "m1rp is m1lp mirrored"
        );
        // A purl-side stitch keeps its knit-side strokes and adds the dot: every dark pixel of the
        // knit-side shape is dark in the purl-side one too.
        let dark = [SYMBOL_DARK.r, SYMBOL_DARK.g, SYMBOL_DARK.b];
        for (knit, purl) in [
            (builtin::SSK, builtin::SSP),
            (builtin::KFB, builtin::PFB),
            (builtin::M1L, builtin::M1LP),
            (builtin::M1R, builtin::M1RP),
        ] {
            let (k, p) = (glyph(knit, None, 24), glyph(purl, None, 24));
            for y in 0..24 {
                for x in 0..24 {
                    if px_at(&k, x, y) == dark {
                        assert_eq!(px_at(&p, x, y), dark, "{purl} keeps {knit}'s strokes");
                    }
                }
            }
        }
    }
}
