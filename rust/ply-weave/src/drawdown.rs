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

/// Render the drawdown to an RGBA8 buffer at `cell_px` pixels per intersection.
///
/// This is the function the FFI bridge calls for live preview: compute the **whole**
/// buffer in Rust and hand it across in one shot. Never marshal per cell across FFI.
///
/// Pick 0 is the first row woven; cloth grows upward, so it is drawn at the bottom of
/// the image (the last pick becomes the top row of pixels).
pub fn render_rgba(draft: &Draft, cell_px: u32) -> RgbaImage {
    let dd = compute(draft);
    let cell = cell_px.max(1) as usize;
    let w = dd.ends * cell;
    let h = dd.picks * cell;
    let mut px = vec![0u8; w * h * 4];
    let palette = &draft.colors.palette;
    let color_at = |idx: ColorIndex| -> Color { palette.get(idx).copied().unwrap_or(Color::WHITE) };

    for pick in 0..dd.picks {
        let row_top = (dd.picks - 1 - pick) * cell; // vertical flip
        for end in 0..dd.ends {
            let c = match dd.cell(end, pick) {
                Cell::WarpUp(i) | Cell::WeftUp(i) => color_at(i),
            };
            let col_left = end * cell;
            for dy in 0..cell {
                let y = row_top + dy;
                for dx in 0..cell {
                    let x = col_left + dx;
                    let o = (y * w + x) * 4;
                    px[o] = c.r;
                    px[o + 1] = c.g;
                    px[o + 2] = c.b;
                    px[o + 3] = 255;
                }
            }
        }
    }

    RgbaImage { width: w as u32, height: h as u32, pixels: px }
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
            notes: String::new(),
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
}
