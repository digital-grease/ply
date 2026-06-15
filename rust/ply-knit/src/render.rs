//! Chart rendering: a [`KnitPattern`] chart -> a flat RGBA8 buffer, the knitting analog of
//! `ply-weave`'s `drawdown.rs`. Unlike weaving (where the drawdown is COMPUTED from the draft), the
//! knitting chart IS the editable source, so rendering is a straight draw of the stored grid.
//!
//! Each cell is a `cell_px` square. A cell shows its colorwork color (if any) as the background and a
//! stitch SYMBOL on top; a no-stitch cell is grey; a cable is one glyph drawn across the columns it
//! spans. Rows are drawn BOTTOM-TO-TOP (row 0 at the bottom — knitting charts read upward), matching
//! the weaving bitmap convention so the Flutter side blits it without a flip.
//!
//! The v1 symbol set is deliberately simple, recognizable primitives (dot / ring / diagonals / bars),
//! not the full CYC/StitchMastery glyph font — that fidelity is a later refinement. The whole buffer
//! is computed in Rust and handed across the FFI in one shot (never per cell).

use crate::pattern::{builtin, Cell, KnitPattern};
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
        return RgbaImage { width: 0, height: 0, pixels: Vec::new() };
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
        return RgbaImage { width: 0, height: 0, pixels: Vec::new() };
    };
    let mut px = vec![0u8; total];

    for (r, row) in chart.rows.iter().enumerate() {
        // Row 0 sits at the BOTTOM: its top pixel edge is h - (r+1)*s.
        let y0 = h - (r + 1) * s;
        let mut col = 0usize;
        while col < cols {
            let cell = row.cells.get(col).copied().unwrap_or(Cell { stitch: builtin::KNIT, color: None });
            let x0 = col * s;
            // A cable spans several columns; draw it once across its (bounds-clamped) span and skip
            // the no-stitch fillers it covers.
            let span = cable_span(pattern, cell).min(cols - col).max(1);
            draw_cell(&mut px, w, h, x0, y0, s, span, pattern, cell);
            col += span;
        }
    }

    draw_gridlines(&mut px, w, h, s, cols, rows);
    RgbaImage { width: w as u32, height: h as u32, pixels: px }
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
    let sym = if luminance(bg) > 140 { SYMBOL_DARK } else { SYMBOL_LIGHT };
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
    if pattern.legend.get(stitch).and_then(|d| d.cable).is_some() {
        // Two crossing diagonals across the span = a cable crossing.
        draw_line(px, w, h, left, bottom, right, top, sym);
        draw_line(px, w, h, left, top, right, bottom, sym);
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
        _ => {
            // Unknown / custom stitch: a hollow square placeholder.
            draw_rect_outline(px, w, h, left, top, right, bottom, sym);
        }
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

fn fill_rect(px: &mut [u8], w: usize, h: usize, x0: usize, y0: usize, rw: usize, rh: usize, c: Color) {
    for y in y0..(y0 + rh).min(h) {
        for x in x0..(x0 + rw).min(w) {
            set_px(px, w, h, x, y, c);
        }
    }
}

fn draw_rect_outline(px: &mut [u8], w: usize, h: usize, x0: usize, y0: usize, x1: usize, y1: usize, c: Color) {
    draw_line(px, w, h, x0, y0, x1, y0, c);
    draw_line(px, w, h, x0, y1, x1, y1, c);
    draw_line(px, w, h, x0, y0, x0, y1, c);
    draw_line(px, w, h, x1, y0, x1, y1, c);
}

/// Integer Bresenham line.
fn draw_line(px: &mut [u8], w: usize, h: usize, x0: usize, y0: usize, x1: usize, y1: usize, c: Color) {
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
            gauge: Gauge { sts: 20.0, rows: 28.0, unit: Unit::Inches },
            palette,
            legend: StitchLegend::builtin(),
            chart: Chart { width, rows },
            notes: String::new(),
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
        let p = pat(3, vec![Row::plain(vec![k, k, k]), Row::plain(vec![k, k, k])], vec![Color::WHITE]);
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
        let p = pat(1, vec![Row::plain(vec![Cell::of(builtin::NO_STITCH)])], vec![Color::WHITE]);
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
        assert_eq!(px_at(&img, 5, 15), [200, 0, 0], "row 0 (red) is the bottom cell");
        assert_eq!(px_at(&img, 5, 5), [CHART_BG.r, CHART_BG.g, CHART_BG.b], "row 1 (knit) is on top");
    }

    #[test]
    fn a_symbol_marks_a_non_knit_cell() {
        // A purl cell draws a dark dot at center over the cream ground (so the center isn't cream).
        let p = pat(1, vec![Row::plain(vec![Cell::of(builtin::PURL)])], vec![Color::WHITE]);
        let img = render_rgba(&p, 16);
        assert_eq!(px_at(&img, 8, 8), [SYMBOL_DARK.r, SYMBOL_DARK.g, SYMBOL_DARK.b], "purl dot");
    }

    #[test]
    fn tiny_cell_px_does_not_panic() {
        // cell_px 1/2 must not underflow the inset math (a glyph cell with margins).
        let p = pat(2, vec![Row::plain(vec![Cell::of(builtin::KNIT), Cell::of(builtin::YO)])], vec![Color::WHITE]);
        let _ = render_rgba(&p, 1);
        let _ = render_rgba(&p, 2);
    }

    #[test]
    fn cable_spans_its_columns_without_panic() {
        let cable = CableDef { front: 2, back: 2, direction: Cross::Right, front_purl: false, back_purl: false };
        let mut legend = StitchLegend::builtin();
        legend.stitches.push(StitchDef { symbol: "2/2RC".into(), consumes: 4, produces: 4, ws_variant: None, cable: Some(cable), macro_rows: 1 });
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
            assert_ne!(px_at(&img, x, 5), [NO_STITCH.r, NO_STITCH.g, NO_STITCH.b], "no grey under a cable");
        }
        assert!(saw_symbol, "the cable crossing is drawn");
    }
}
