//! Drawing a simulated window (ADR 0018 section 8): the band's top face and back as a colour chart,
//! and the turning chart, as RGBA rasters with their own budget (ADR 0018 M10-01 amendment 7: the
//! engines do not share a renderer).
//!
//! **Band face.** One square cell per card per pick, the colour of the thread that face shows. Pick 1
//! is at the BOTTOM and the newest pick at the top (every tablet source reads charts from the bottom,
//! unlike Ply's shaft drafts). The top face has card 1 at the left; the back, as the weaver sees it
//! after turning the band over sideways, card 1 at the right. Each turned cell carries its stitch
//! slant (`/` for Z twining, `\` for S, on both faces). A continued float (an idle card) has no slant
//! and no line between it and the cell below, so the float reads as one long cell; a reversal is a
//! black line with a white edge under the cell; an ambiguous cell shows both candidate colours side by
//! side with a mark; an unknown cell is cross-hatched and a not-modelled cell (an empty hole) hatched.
//! Hole letters can be drawn in the cells so the chart does not rely on colour alone.
//!
//! **Turning chart.** One cell per card per pick, pick 1 at the bottom, card 1 at the left, each with
//! its letter (`F`, `B`, `I`, `?`, never a slash) on a fill that differs by action; a flip before a
//! pick is a thick dashed line along the foot of the card's cell, a twist release a dotted line just
//! above it (so a card both released and flipped shows both).
//!
//! **Bounded.** Sizes come from untrusted files: the cell count, each side and the raster bytes are
//! checked against [`RasterLimits`] with checked arithmetic before anything is allocated. When the
//! requested pitch would pass them, the raster drops to the largest pitch that fits; when even one
//! pixel per cell does not fit, it is refused.

use crate::band::TabletBand;
use crate::card::{Face, Hole, Turn, Twining};
use crate::simulate::{face_color, FaceColor, FaceThread, TabletWindow};
use ply_common::Color;

/// The raster budget of one render.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct RasterLimits {
    /// Most cells (cards times picks) drawn at once.
    pub max_cells: usize,
    /// Most bytes in the RGBA buffer.
    pub max_raster_bytes: usize,
    /// Most pixels on either side.
    pub max_side: usize,
}

impl RasterLimits {
    /// The phone budget: the engine's window cap in cells, 48 MB of pixels, 16,384 pixels a side.
    pub const DEFAULT: RasterLimits = RasterLimits {
        max_cells: crate::band::MAX_WINDOW_CELLS,
        max_raster_bytes: 48 * 1024 * 1024,
        max_side: 16_384,
    };
}

impl Default for RasterLimits {
    fn default() -> Self {
        RasterLimits::DEFAULT
    }
}

/// The largest pitch drawn, in pixels per cell.
pub const MAX_CELL_PX: u32 = 64;

/// The smallest pitch at which hole letters are drawn in the cells.
pub const MIN_LETTER_CELL_PX: u32 = 9;

/// How to draw.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct RenderOptions {
    /// The pitch asked for (pixels per cell); a raster over budget uses a smaller one.
    pub cell_px: u32,
    /// Draw each cell's hole letter (from [`MIN_LETTER_CELL_PX`]).
    pub letters: bool,
    /// Draw lines between the cells (from 5 pixels per cell).
    pub grid: bool,
}

impl Default for RenderOptions {
    fn default() -> Self {
        RenderOptions {
            cell_px: 16,
            letters: false,
            grid: true,
        }
    }
}

/// An RGBA8 raster, row-major, top row first.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct TabletRaster {
    pub width: u32,
    pub height: u32,
    /// The pitch actually drawn (0 for an empty raster).
    pub cell_px: u32,
    pub pixels: Vec<u8>,
}

impl TabletRaster {
    fn empty() -> TabletRaster {
        TabletRaster {
            width: 0,
            height: 0,
            cell_px: 0,
            pixels: Vec::new(),
        }
    }

    /// The RGBA of pixel (`x`, `y`), if inside.
    pub fn pixel(&self, x: u32, y: u32) -> Option<[u8; 4]> {
        if x >= self.width || y >= self.height {
            return None;
        }
        let i = ((y as usize) * (self.width as usize) + x as usize) * 4;
        self.pixels.get(i..i + 4).map(|p| [p[0], p[1], p[2], p[3]])
    }
}

/// Why a raster cannot be drawn.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum RenderError {
    /// Too many cells, or too large even at one pixel per cell.
    #[error("a chart of {columns} by {rows} cells is too large to draw (the limit is {limit})")]
    TooLarge {
        columns: usize,
        rows: usize,
        limit: String,
    },
    /// The allocator refused a buffer that was within budget.
    #[error("could not allocate {bytes} bytes for the chart")]
    AllocFailed { bytes: usize },
}

/// The pitch a `columns` by `rows` chart is drawn at when `want` is asked for: `want` (at least 1,
/// at most [`MAX_CELL_PX`]) when it fits `limits`, else the largest that does.
pub fn fit_cell_px(
    columns: usize,
    rows: usize,
    want: u32,
    limits: &RasterLimits,
) -> Result<u32, RenderError> {
    let too_large = |limit: String| RenderError::TooLarge {
        columns,
        rows,
        limit,
    };
    let cells = columns
        .checked_mul(rows)
        .ok_or_else(|| too_large(format!("{} cells", limits.max_cells)))?;
    if cells > limits.max_cells {
        return Err(too_large(format!("{} cells", limits.max_cells)));
    }
    let fits = |px: usize| -> bool {
        let (Some(w), Some(h)) = (columns.checked_mul(px), rows.checked_mul(px)) else {
            return false;
        };
        w <= limits.max_side
            && h <= limits.max_side
            && w.checked_mul(h)
                .and_then(|a| a.checked_mul(4))
                .is_some_and(|b| b <= limits.max_raster_bytes)
    };
    let want = want.clamp(1, MAX_CELL_PX) as usize;
    if fits(want) {
        return Ok(want as u32);
    }
    // The largest pitch below `want` that fits (fits is monotonic in the pitch).
    let (mut lo, mut hi) = (0usize, want);
    while hi - lo > 1 {
        let mid = lo + (hi - lo) / 2;
        if fits(mid) {
            lo = mid;
        } else {
            hi = mid;
        }
    }
    if lo == 0 {
        Err(too_large(format!(
            "{} pixels a side and {} bytes",
            limits.max_side, limits.max_raster_bytes
        )))
    } else {
        Ok(lo as u32)
    }
}

/// Draw one face of a simulated window (see the module notes). An empty window is a 0 by 0 raster.
pub fn try_render_face(
    band: &TabletBand,
    window: &TabletWindow,
    face: Face,
    opts: &RenderOptions,
    limits: &RasterLimits,
) -> Result<TabletRaster, RenderError> {
    let cards = window.cards;
    let picks = window.picks() as usize;
    if cards == 0 || picks == 0 {
        return Ok(TabletRaster::empty());
    }
    let px = fit_cell_px(cards, picks, opts.cell_px, limits)?;
    let mut canvas = Canvas::new(cards, picks, px)?;
    let grid = opts.grid && px >= 5;
    let letters = opts.letters && px >= MIN_LETTER_CELL_PX;
    let colour = |i: u32| -> Rgb {
        band.palette
            .get(i as usize)
            .map_or(MISSING, |c: &Color| [c.r, c.g, c.b])
    };
    for pick in window.first_pick..=window.last_pick {
        let Some(row) = window.row(pick) else {
            continue;
        };
        // Pick 1 at the bottom: the window's last pick is the raster's top row.
        let y = (window.last_pick - pick) as usize;
        for (x, card) in face.display_order(row.len()).enumerate() {
            let cp = &row[card];
            let thread = match face {
                Face::Top => cp.top,
                Face::Back => cp.back,
            };
            let cell = canvas.cell(x, y);
            let continued = matches!(thread, FaceThread::Continued(_));
            match face_color(band, card, thread) {
                FaceColor::One(c) => {
                    let rgb = colour(c);
                    canvas.fill(cell, rgb);
                    if let Some(t) = cp.twining {
                        canvas.slant(cell, t, ink_on(rgb), letters);
                    }
                    if letters {
                        if let Some(h) = thread.hole() {
                            canvas.glyph(cell, hole_glyph(h), ink_on(rgb));
                        }
                    }
                }
                FaceColor::Either(a, b) => {
                    canvas.halves(cell, a.map(colour), b.map(colour));
                    canvas.mark(cell);
                }
                FaceColor::NotModelled => {
                    canvas.hatch(cell, HATCH_BG, HATCH_INK, false);
                    if letters {
                        if let Some(h) = thread.hole() {
                            canvas.glyph(cell, hole_glyph(h), INK_DARK);
                        }
                    }
                }
                FaceColor::Unknown => canvas.hatch(cell, HATCH_BG, HATCH_INK, true),
            }
            if grid {
                canvas.grid_right(cell);
                if !continued {
                    canvas.grid_bottom(cell);
                }
            }
            // On the cell's foot, even at the window's first pick (the reversal is then with the
            // pick just below the window).
            if cp.reversal {
                canvas.reversal(cell);
            }
        }
    }
    Ok(canvas.into_raster())
}

/// Draw the turning chart of a simulated window (see the module notes). An empty window is a 0 by 0
/// raster.
pub fn try_render_turning(
    window: &TabletWindow,
    opts: &RenderOptions,
    limits: &RasterLimits,
) -> Result<TabletRaster, RenderError> {
    let cards = window.cards;
    let picks = window.picks() as usize;
    if cards == 0 || picks == 0 {
        return Ok(TabletRaster::empty());
    }
    let px = fit_cell_px(cards, picks, opts.cell_px, limits)?;
    let mut canvas = Canvas::new(cards, picks, px)?;
    let grid = px >= 5;
    let letters = px >= 7;
    for pick in window.first_pick..=window.last_pick {
        let Some(row) = window.row(pick) else {
            continue;
        };
        let y = (window.last_pick - pick) as usize;
        for (x, cp) in row.iter().enumerate() {
            let cell = canvas.cell(x, y);
            let (bg, glyph, ink) = match cp.turn {
                Turn::Forward => (TURN_F, &GLYPH_F, INK_DARK),
                Turn::Backward => (TURN_B, &GLYPH_B, INK_DARK),
                Turn::Idle => (TURN_I, &GLYPH_I, INK_MUTED),
                Turn::Unsupported => (TURN_Q, &GLYPH_Q, INK_DARK),
            };
            if cp.turn == Turn::Unsupported {
                canvas.hatch(cell, bg, HATCH_INK, false);
            } else {
                canvas.fill(cell, bg);
            }
            if letters {
                canvas.glyph(cell, glyph, ink);
            }
            if grid {
                canvas.grid_right(cell);
                canvas.grid_bottom(cell);
            }
            if cp.flipped {
                canvas.event_line(cell, 3, 2, 0);
            }
            if cp.released {
                // Dots above the flip's dashes, so a card both released and flipped shows both.
                canvas.event_line(cell, 1, 2, if px >= 8 { 3 } else { 0 });
            }
        }
    }
    Ok(canvas.into_raster())
}

type Rgb = [u8; 3];

/// A colour index the palette does not have (validation refuses such a band, so never drawn).
const MISSING: Rgb = [255, 0, 255];
const GRID: Rgb = [176, 176, 176];
const HATCH_BG: Rgb = [250, 250, 250];
const HATCH_INK: Rgb = [140, 140, 140];
const INK_DARK: Rgb = [20, 20, 20];
const INK_LIGHT: Rgb = [245, 245, 245];
const INK_MUTED: Rgb = [110, 110, 110];
const TURN_F: Rgb = [255, 255, 255];
const TURN_B: Rgb = [200, 208, 214];
const TURN_I: Rgb = [236, 236, 236];
const TURN_Q: Rgb = [255, 244, 214];

/// Dark ink on a light colour, light ink on a dark one.
fn ink_on(c: Rgb) -> Rgb {
    let luma = 299 * u32::from(c[0]) + 587 * u32::from(c[1]) + 114 * u32::from(c[2]);
    if luma > 140_000 {
        INK_DARK
    } else {
        INK_LIGHT
    }
}

/// A 5 by 7 glyph, one row per byte, the high five bits used (bit 4 is the left column).
type Glyph = [u8; 7];
const GLYPH_A: Glyph = [0x0E, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11];
const GLYPH_B: Glyph = [0x1E, 0x11, 0x11, 0x1E, 0x11, 0x11, 0x1E];
const GLYPH_C: Glyph = [0x0E, 0x11, 0x10, 0x10, 0x10, 0x11, 0x0E];
const GLYPH_D: Glyph = [0x1E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x1E];
const GLYPH_F: Glyph = [0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x10];
const GLYPH_I: Glyph = [0x0E, 0x04, 0x04, 0x04, 0x04, 0x04, 0x0E];
const GLYPH_Q: Glyph = [0x0E, 0x11, 0x01, 0x02, 0x04, 0x00, 0x04];

fn hole_glyph(h: Hole) -> &'static Glyph {
    match h {
        Hole::A => &GLYPH_A,
        Hole::B => &GLYPH_B,
        Hole::C => &GLYPH_C,
        Hole::D => &GLYPH_D,
    }
}

/// One cell's pixel box: [x0, x1) by [y0, y1).
#[derive(Clone, Copy)]
struct Cell {
    x0: usize,
    y0: usize,
    px: usize,
}

struct Canvas {
    width: usize,
    height: usize,
    px: usize,
    pixels: Vec<u8>,
}

impl Canvas {
    /// A white canvas; the size was checked by [`fit_cell_px`].
    fn new(columns: usize, rows: usize, px: u32) -> Result<Canvas, RenderError> {
        let px = px as usize;
        let width = columns * px;
        let height = rows * px;
        let bytes = width * height * 4;
        let mut pixels = Vec::new();
        pixels
            .try_reserve_exact(bytes)
            .map_err(|_| RenderError::AllocFailed { bytes })?;
        pixels.resize(bytes, 255);
        Ok(Canvas {
            width,
            height,
            px,
            pixels,
        })
    }

    fn into_raster(self) -> TabletRaster {
        TabletRaster {
            width: self.width as u32,
            height: self.height as u32,
            cell_px: self.px as u32,
            pixels: self.pixels,
        }
    }

    fn cell(&self, x: usize, y: usize) -> Cell {
        Cell {
            x0: x * self.px,
            y0: y * self.px,
            px: self.px,
        }
    }

    fn put(&mut self, x: usize, y: usize, c: Rgb) {
        if x < self.width && y < self.height {
            let i = (y * self.width + x) * 4;
            self.pixels[i..i + 3].copy_from_slice(&c);
            self.pixels[i + 3] = 255;
        }
    }

    fn rect(&mut self, x0: usize, y0: usize, x1: usize, y1: usize, c: Rgb) {
        for y in y0..y1.min(self.height) {
            for x in x0..x1.min(self.width) {
                self.put(x, y, c);
            }
        }
    }

    fn fill(&mut self, cell: Cell, c: Rgb) {
        self.rect(cell.x0, cell.y0, cell.x0 + cell.px, cell.y0 + cell.px, c);
    }

    /// Left half one colour, right half the other (`None`: hatched, a hole that may be empty).
    fn halves(&mut self, cell: Cell, a: Option<Rgb>, b: Option<Rgb>) {
        let mid = cell.x0 + cell.px.div_ceil(2);
        let y1 = cell.y0 + cell.px;
        for (x0, x1, c) in [(cell.x0, mid, a), (mid, cell.x0 + cell.px, b)] {
            match c {
                Some(c) => self.rect(x0, cell.y0, x1, y1, c),
                None => {
                    self.rect(x0, cell.y0, x1, y1, HATCH_BG);
                    for y in cell.y0..y1 {
                        for x in x0..x1 {
                            if (x + y).is_multiple_of(3) {
                                self.put(x, y, HATCH_INK);
                            }
                        }
                    }
                }
            }
        }
    }

    /// The ambiguous mark: a `?` in a box, or a dot when the cell is small.
    fn mark(&mut self, cell: Cell) {
        if cell.px >= MIN_LETTER_CELL_PX as usize {
            let s = self.glyph_scale(cell);
            let (gw, gh) = (5 * s + 2, 7 * s + 2);
            let x0 = cell.x0 + (cell.px - gw) / 2;
            let y0 = cell.y0 + (cell.px - gh) / 2;
            self.rect(x0, y0, x0 + gw, y0 + gh, INK_LIGHT);
            self.glyph(cell, &GLYPH_Q, INK_DARK);
        } else {
            let c = cell.px / 2;
            let r = (cell.px / 4).max(1);
            self.rect(
                cell.x0 + c.saturating_sub(r / 2),
                cell.y0 + c.saturating_sub(r / 2),
                cell.x0 + c + r.div_ceil(2),
                cell.y0 + c + r.div_ceil(2),
                INK_DARK,
            );
        }
    }

    /// Hatching: lines one way, or both ways when `cross`.
    fn hatch(&mut self, cell: Cell, bg: Rgb, ink: Rgb, cross: bool) {
        self.fill(cell, bg);
        let step = (cell.px / 3).max(2);
        for dy in 0..cell.px {
            for dx in 0..cell.px {
                let fwd = (dx + dy).is_multiple_of(step);
                let back = cross && (dx + cell.px - dy).is_multiple_of(step);
                if fwd || back {
                    self.put(cell.x0 + dx, cell.y0 + dy, ink);
                }
            }
        }
    }

    /// The stitch slant: `/` (bottom left to top right) for Z, `\` for S. With letters, only the two
    /// ends of the stroke are drawn, so the letter stays clear.
    fn slant(&mut self, cell: Cell, t: Twining, ink: Rgb, ends_only: bool) {
        if cell.px < 4 {
            return;
        }
        let n = cell.px;
        let inset = (n / 6).max(1);
        let thick = if n >= 14 { 2 } else { 1 };
        let span = n - 2 * inset;
        for i in 0..span {
            if ends_only && i > span / 4 && i < span - span / 4 {
                continue;
            }
            let dx = inset + i;
            // Rows grow downward: `/` rises to the right, so its y falls as x grows.
            let dy = match t {
                Twining::Z => n - 1 - inset - i,
                Twining::S => inset + i,
            };
            for k in 0..thick {
                self.put(cell.x0 + dx + k, cell.y0 + dy, ink);
            }
        }
    }

    fn glyph_scale(&self, cell: Cell) -> usize {
        ((cell.px * 6 / 10) / 7).max(1)
    }

    fn glyph(&mut self, cell: Cell, g: &Glyph, ink: Rgb) {
        let s = self.glyph_scale(cell);
        let (gw, gh) = (5 * s, 7 * s);
        if gw > cell.px || gh > cell.px {
            return;
        }
        let x0 = cell.x0 + (cell.px - gw) / 2;
        let y0 = cell.y0 + (cell.px - gh) / 2;
        for (row, bits) in g.iter().enumerate() {
            for col in 0..5 {
                if bits & (0x10 >> col) != 0 {
                    self.rect(
                        x0 + col * s,
                        y0 + row * s,
                        x0 + (col + 1) * s,
                        y0 + (row + 1) * s,
                        ink,
                    );
                }
            }
        }
    }

    fn grid_right(&mut self, cell: Cell) {
        let x = cell.x0 + cell.px - 1;
        for y in cell.y0..cell.y0 + cell.px {
            self.put(x, y, GRID);
        }
    }

    fn grid_bottom(&mut self, cell: Cell) {
        let y = cell.y0 + cell.px - 1;
        for x in cell.x0..cell.x0 + cell.px {
            self.put(x, y, GRID);
        }
    }

    /// A reversal: a black line along the cell's foot (the line between this pick and the one
    /// before), with a white edge above it so it shows on any colour.
    fn reversal(&mut self, cell: Cell) {
        let thick = (cell.px / 6).max(1);
        let foot = cell.y0 + cell.px;
        self.rect(cell.x0, foot - thick, cell.x0 + cell.px, foot, INK_DARK);
        if cell.px >= 8 {
            let y = foot - thick - 1;
            self.rect(cell.x0, y, cell.x0 + cell.px, y + 1, INK_LIGHT);
        }
    }

    /// A flip (`dash` 3) or release (`dash` 1) mark along the cell's foot, `lift` pixels above it:
    /// a dashed or dotted black line `thick` pixels high.
    fn event_line(&mut self, cell: Cell, dash: usize, thick: usize, lift: usize) {
        let thick = thick.min(cell.px);
        let lift = lift.min(cell.px - thick);
        let foot = cell.y0 + cell.px - lift;
        for x in cell.x0..cell.x0 + cell.px {
            if (x - cell.x0) % (dash + 1 + dash.min(1)) < dash {
                for y in foot - thick..foot {
                    self.put(x, y, INK_DARK);
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_pitch_drops_to_fit_and_refuses_only_past_one_pixel() {
        let l = RasterLimits {
            max_cells: 1_000,
            max_raster_bytes: 40 * 40 * 4,
            max_side: 1_000,
        };
        assert_eq!(fit_cell_px(3, 3, 12, &l).unwrap(), 12); // 36 by 36 fits 40 by 40
        assert_eq!(fit_cell_px(4, 3, 12, &l).unwrap(), 11); // 48 by 36 does not
        assert_eq!(fit_cell_px(10, 10, 12, &l).unwrap(), 4);
        assert!(fit_cell_px(100, 11, 12, &l).is_err()); // 1,100 cells
        assert!(fit_cell_px(41, 1, 1, &l).is_ok());
        assert_eq!(fit_cell_px(4, 3, 0, &l).unwrap(), 1);
        assert_eq!(
            fit_cell_px(1, 1, 1_000, &RasterLimits::DEFAULT).unwrap(),
            MAX_CELL_PX
        );
        assert!(fit_cell_px(usize::MAX, 2, 1, &l).is_err());
        let side = RasterLimits {
            max_side: 50,
            ..RasterLimits::DEFAULT
        };
        assert_eq!(fit_cell_px(10, 1, 12, &side).unwrap(), 5);
    }

    #[test]
    fn ink_contrasts_with_its_cell() {
        assert_eq!(ink_on([0, 0, 0]), INK_LIGHT);
        assert_eq!(ink_on([255, 255, 255]), INK_DARK);
    }
}
