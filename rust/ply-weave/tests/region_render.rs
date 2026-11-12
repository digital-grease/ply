//! Region (viewport/tile) rendering, M7-01 second slice.
//!
//! `try_render_region` must draw EXACTLY the matching crop of a full uniform render: the same
//! interlacement, colors, thread texture, gridline seams (which belong to the whole draft, so they
//! can fall on a tile edge) and long-float tint (floats crossing a tile edge are still measured in
//! full). These tests compare a region against the crop of `try_render_rgba_with` over random and
//! hand-picked drafts, regions, pitches and options, and reassemble whole drafts from tiles.

use ply_common::{Color, Unit};
use ply_weave::draft::{ColorPlan, RetainedSection};
use ply_weave::{
    fit_region_cell_px, structure, try_render_region, try_render_rgba_with, Draft, DrawdownRegion,
    Drive, Liftplan, RenderError, RenderLimits, RenderOptions, RgbaImage, ShaftId, ShedType,
    Threading, TieUp, TreadleId, Treadling,
};
use proptest::prelude::*;

const UNBOUNDED: RenderLimits = RenderLimits::UNBOUNDED;

/// `draft` with its per-thread thickness cleared: the structural draft a region render draws.
fn uniform(draft: &Draft) -> Draft {
    let mut d = draft.clone();
    d.warp_thickness.clear();
    d.weft_thickness.clear();
    d
}

/// The `w` x `h` px crop of `img` at (`x`, `y`).
fn crop(img: &RgbaImage, x: usize, y: usize, w: usize, h: usize) -> RgbaImage {
    let stride = img.width as usize * 4;
    let mut pixels = Vec::with_capacity(w * h * 4);
    for row in y..y + h {
        let o = row * stride + x * 4;
        pixels.extend_from_slice(&img.pixels[o..o + w * 4]);
    }
    RgbaImage {
        width: w as u32,
        height: h as u32,
        pixels,
    }
}

/// The crop of the full uniform render that `region` must reproduce: end 1 sits at the right, so
/// the region's left edge is `(ends - region.ends.end)` cells in; pick 1 sits at the top.
fn expected(draft: &Draft, region: &DrawdownRegion, px: u32, opts: &RenderOptions) -> RgbaImage {
    let full = try_render_rgba_with(&uniform(draft), px, opts, &UNBOUNDED).unwrap();
    let p = px as usize;
    crop(
        &full,
        (draft.ends() - region.ends.end) * p,
        region.picks.start * p,
        region.width() * p,
        region.height() * p,
    )
}

fn region(ends: std::ops::Range<usize>, picks: std::ops::Range<usize>) -> DrawdownRegion {
    DrawdownRegion::new(ends, picks)
}

fn assert_region_is_crop(draft: &Draft, r: &DrawdownRegion, px: u32, opts: &RenderOptions) {
    let got = try_render_region(draft, r, px, opts, &UNBOUNDED).unwrap();
    let want = expected(draft, r, px, opts);
    assert_eq!(
        (got.width, got.height),
        (want.width, want.height),
        "size of {r:?}"
    );
    assert!(
        got.pixels == want.pixels,
        "region {r:?} at {px} px with {opts:?} differs from the crop of the full render"
    );
}

fn opts(gridlines: bool, float_threshold: u32, thread_texture: bool) -> RenderOptions {
    RenderOptions {
        gridlines,
        float_threshold,
        thread_texture,
    }
}

/// Every option combination the editor can ask for, plus a few float thresholds.
fn all_opts() -> Vec<RenderOptions> {
    let mut v = Vec::new();
    for g in [false, true] {
        for t in [false, true] {
            for f in [0, 1, 2, 3, 5] {
                v.push(opts(g, f, t));
            }
        }
    }
    v
}

/// A treadled draft with a twill-ish pattern, a sinking or rising shed, three palette colors and a
/// color stripe in each direction. Big enough to cut into tiles; no thickness.
fn twill(ends: usize, picks: usize, shed: ShedType) -> Draft {
    let shafts = 4u16;
    Draft {
        name: "twill".into(),
        shafts,
        treadles: 4,
        shed,
        unit: Unit::Inches,
        threading: Threading(
            (0..ends)
                .map(|e| vec![ShaftId((e % 4) as u16 + 1)])
                .collect(),
        ),
        drive: Drive::Treadled {
            tieup: TieUp(vec![
                vec![ShaftId(1), ShaftId(2)],
                vec![ShaftId(2), ShaftId(3)],
                vec![ShaftId(3), ShaftId(4)],
                vec![ShaftId(4), ShaftId(1)],
            ]),
            // A point treadling so floats and their tints vary across the cloth.
            treadling: Treadling(
                (0..picks)
                    .map(|p| {
                        let k = p % 6;
                        vec![TreadleId(if k < 4 { k as u16 + 1 } else { 7 - k as u16 })]
                    })
                    .collect(),
            ),
        },
        colors: ColorPlan {
            palette: vec![
                Color::rgb(20, 40, 160),
                Color::WHITE,
                Color::rgb(200, 30, 30),
            ],
            warp: (0..ends).map(|e| if e % 7 < 3 { 0 } else { 2 }).collect(),
            weft: (0..picks).map(|p| if p % 5 == 0 { 2 } else { 1 }).collect(),
        },
        warp_thickness: Vec::new(),
        weft_thickness: Vec::new(),
        notes: String::new(),
        retained: Vec::<RetainedSection>::new(),
    }
}

/// One end threaded on shaft 1 among ends on shaft 2, raised on every pick: a warp float the full
/// height of the draft, crossing every horizontal tile edge. Plus one pick that raises nothing: a
/// weft float the full width, crossing every vertical tile edge.
fn long_floats(ends: usize, picks: usize) -> Draft {
    let mut d = twill(ends, picks, ShedType::Rising);
    d.shafts = 2;
    d.treadles = 0;
    d.threading = Threading(
        (0..ends)
            .map(|e| vec![ShaftId(if e == ends / 2 { 1 } else { 2 })])
            .collect(),
    );
    d.drive = Drive::Liftplan(Liftplan(
        (0..picks)
            .map(|p| {
                if p == picks / 2 {
                    Vec::new()
                } else if p % 2 == 0 {
                    vec![ShaftId(1), ShaftId(2)]
                } else {
                    vec![ShaftId(1)]
                }
            })
            .collect(),
    ));
    d
}

// --- exact crops, hand-picked cases ------------------------------------------------------------

/// Regions touching each edge and corner, single cells, single rows and columns, and the whole
/// draft, for every option combination, on both shed directions and both drives.
#[test]
fn edge_and_corner_regions_equal_the_crop() {
    let (ends, picks) = (11, 9);
    let drafts = [
        twill(ends, picks, ShedType::Rising),
        twill(ends, picks, ShedType::Sinking),
        long_floats(ends, picks),
    ];
    let regions = [
        region(0..ends, 0..picks),                // whole draft
        region(0..1, 0..1),                       // end 1, pick 1: the top-right corner cell
        region(ends - 1..ends, picks - 1..picks), // the bottom-left corner cell
        region(0..1, picks - 1..picks),           // bottom-right corner cell
        region(ends - 1..ends, 0..1),             // top-left corner cell
        region(4..5, 3..4),                       // an interior cell (seams on all four sides)
        region(0..ends, 4..5),                    // one full pick
        region(5..6, 0..picks),                   // one full end
        region(0..4, 0..3),                       // touches the right and top edges
        region(7..ends, 6..picks),                // touches the left and bottom edges
        region(3..8, 2..7),                       // interior block
        region(0..ends, 2..6),                    // full-width band
        region(2..9, 0..picks),                   // full-height band
    ];
    for d in &drafts {
        for r in &regions {
            for o in all_opts() {
                for px in [1, 2, 5] {
                    assert_region_is_crop(d, r, px, &o);
                }
            }
        }
    }
}

/// A region renders the STRUCTURAL draft: per-thread thickness is ignored (it equals the crop of
/// the full render of the same draft with its thickness cleared), so tiles stay on the fixed grid.
#[test]
fn region_ignores_thread_thickness() {
    let mut d = twill(8, 6, ShedType::Rising);
    d.warp_thickness = vec![1.0, 2.0, 3.0, 1.0, 1.0, 4.0, 1.0, 2.0];
    d.weft_thickness = vec![2.0, 1.0, 1.0, 3.0, 1.0, 1.0];
    for o in all_opts() {
        assert_region_is_crop(&d, &region(1..6, 2..5), 4, &o);
        let img = try_render_region(&d, &region(0..8, 0..6), 4, &o, &UNBOUNDED).unwrap();
        assert_eq!((img.width, img.height), (32, 24), "uniform 4 px cells");
    }
}

/// Gridline seams belong to the whole draft: a tile that starts after end 1 or stops before the last
/// pick carries the seam on that edge; a tile on the draft's border has none there.
#[test]
fn gridline_seams_follow_the_whole_draft_on_tile_edges() {
    let d = twill(6, 6, ShedType::Rising);
    let o = opts(true, 0, false);
    let gray = [128u8, 128, 128, 255];
    let at = |img: &RgbaImage, x: usize, y: usize| -> [u8; 4] {
        let i = (y * img.width as usize + x) * 4;
        img.pixels[i..i + 4].try_into().unwrap()
    };
    // In the final orientation each cell's seams are its RIGHT pixel column (except end 1's cell,
    // the draft's right border) and its BOTTOM pixel row (except the last pick's, the bottom border).
    let interior = try_render_region(&d, &region(2..4, 2..4), 4, &o, &UNBOUNDED).unwrap();
    assert_eq!(
        at(&interior, 7, 1),
        gray,
        "seam on the tile's right edge (end 2|3)"
    );
    assert_eq!(
        at(&interior, 1, 7),
        gray,
        "seam on the tile's bottom edge (pick 3|4)"
    );
    assert_ne!(
        at(&interior, 0, 1),
        gray,
        "no seam on the tile's left edge pixel"
    );
    assert_ne!(
        at(&interior, 1, 0),
        gray,
        "no seam on the tile's top edge pixel"
    );
    let corner = try_render_region(&d, &region(0..2, 4..6), 4, &o, &UNBOUNDED).unwrap();
    assert_ne!(
        at(&corner, 7, 1),
        gray,
        "end 1 is the draft's right border: no seam"
    );
    assert_ne!(
        at(&corner, 1, 7),
        gray,
        "the last pick is the bottom border: no seam"
    );
    assert_eq!(
        at(&corner, 3, 1),
        gray,
        "the seam between the tile's two ends"
    );
    for r in [region(2..4, 2..4), region(0..2, 4..6), region(4..6, 0..2)] {
        assert_region_is_crop(&d, &r, 4, &o);
    }
}

/// A float longer than the tile, crossing its edges, is still tinted inside the tile (its full length
/// is measured through the margin), and a float that just reaches the threshold only across the edge
/// is tinted too.
#[test]
fn floats_crossing_tile_edges_are_tinted() {
    let (ends, picks) = (13, 11);
    let d = long_floats(ends, picks);
    let mid_end = ends / 2;
    let mid_pick = picks / 2;
    for t in [2, 3, 4, 5, 6, 9, 11, 13, 40] {
        let o = opts(false, t, false);
        // 1x1 tiles straddling the long warp float and the long weft float.
        assert_region_is_crop(&d, &region(mid_end..mid_end + 1, 0..1), 3, &o);
        assert_region_is_crop(&d, &region(mid_end..mid_end + 1, 4..5), 3, &o);
        assert_region_is_crop(&d, &region(0..1, mid_pick..mid_pick + 1), 3, &o);
        assert_region_is_crop(&d, &region(ends - 2..ends, mid_pick..mid_pick + 1), 3, &o);
        // Thin bands cut across both floats.
        assert_region_is_crop(&d, &region(0..ends, 2..4), 2, &o);
        assert_region_is_crop(&d, &region(5..8, 0..picks), 2, &o);
    }
    // Sanity: the long warp float really is tinted in a 1x1 tile at threshold 5 (not raw black).
    let warp_cell = try_render_region(
        &d,
        &region(mid_end..mid_end + 1, 1..2),
        1,
        &opts(false, 5, false),
        &UNBOUNDED,
    )
    .unwrap();
    let plain = try_render_region(
        &d,
        &region(mid_end..mid_end + 1, 1..2),
        1,
        &opts(false, 0, false),
        &UNBOUNDED,
    )
    .unwrap();
    assert_ne!(
        warp_cell.pixels, plain.pixels,
        "a 1x1 tile on a long float is tinted"
    );
}

/// Cutting a draft into tiles of any size and pasting them back reproduces the full render exactly.
#[test]
fn tiles_reassemble_into_the_full_render() {
    let d = twill(23, 17, ShedType::Sinking);
    let px = 3usize;
    for o in [
        opts(true, 3, true),
        opts(false, 0, false),
        opts(true, 5, false),
    ] {
        let full = try_render_rgba_with(&d, px as u32, &o, &UNBOUNDED).unwrap();
        for (tw, th) in [(1, 1), (4, 4), (5, 3), (7, 17), (23, 2)] {
            let mut pasted = vec![0u8; full.pixels.len()];
            let stride = full.width as usize * 4;
            for e0 in (0..23).step_by(tw) {
                for p0 in (0..17).step_by(th) {
                    let r = region(e0..(e0 + tw).min(23), p0..(p0 + th).min(17));
                    let tile = try_render_region(&d, &r, px as u32, &o, &UNBOUNDED).unwrap();
                    let (x0, y0) = ((23 - r.ends.end) * px, r.picks.start * px);
                    let row = tile.width as usize * 4;
                    for y in 0..tile.height as usize {
                        let dst = (y0 + y) * stride + x0 * 4;
                        pasted[dst..dst + row]
                            .copy_from_slice(&tile.pixels[y * row..(y + 1) * row]);
                    }
                }
            }
            assert!(pasted == full.pixels, "{tw} x {th} tiles with {o:?}");
        }
    }
}

// --- errors ------------------------------------------------------------------------------------

#[test]
fn empty_or_outside_regions_are_errors_not_panics() {
    let d = twill(5, 4, ShedType::Rising);
    let o = opts(true, 3, true);
    #[allow(clippy::reversed_empty_ranges)]
    let bad = [
        region(0..0, 0..4),
        region(0..5, 2..2),
        region(3..2, 0..4),
        region(0..6, 0..4),
        region(0..5, 0..5),
        region(5..6, 0..1),
        region(usize::MAX - 1..usize::MAX, 0..1),
        region(0..usize::MAX, 0..usize::MAX),
    ];
    for r in &bad {
        let got = try_render_region(&d, r, 4, &o, &RenderLimits::DEFAULT);
        assert!(
            matches!(got, Err(RenderError::InvalidRegion { .. })),
            "{r:?}: {got:?}"
        );
        assert!(matches!(
            fit_region_cell_px(&d, r, 4, &RenderLimits::DEFAULT),
            Err(RenderError::InvalidRegion { .. })
        ));
    }
    // A draft with no ends or picks has no valid region at all.
    let empty = Draft::blank(4, 4);
    assert!(matches!(
        try_render_region(&empty, &region(0..1, 0..1), 4, &o, &UNBOUNDED),
        Err(RenderError::InvalidRegion {
            ends: 0,
            picks: 0,
            ..
        })
    ));
    // The message names the region and the draft.
    let msg = try_render_region(&d, &region(0..6, 0..4), 4, &o, &UNBOUNDED)
        .unwrap_err()
        .to_string();
    assert!(msg.contains("0..6") && msg.contains("5 x 4"), "{msg}");
}

/// The region's own intersections, its float-margin rectangle, and its raster each obey the budget.
#[test]
fn region_budgets_are_exact() {
    let d = twill(20, 20, ShedType::Rising);
    let lim = |cells, bytes, side| RenderLimits {
        max_cells: cells,
        max_raster_bytes: bytes,
        max_raster_side: side,
    };
    let r = region(5..10, 5..10); // 25 intersections, 20 x 20 px at 4 px = 1600 bytes
    let plain = RenderOptions::default();
    assert!(try_render_region(&d, &r, 4, &plain, &lim(25, 1600, 20)).is_ok());
    assert!(matches!(
        try_render_region(&d, &r, 4, &plain, &lim(24, usize::MAX, usize::MAX)),
        Err(RenderError::TooManyCells {
            ends: 5,
            picks: 5,
            cells: 25,
            limit: 24
        })
    ));
    assert!(matches!(
        try_render_region(&d, &r, 4, &plain, &lim(usize::MAX, 1599, usize::MAX)),
        Err(RenderError::RasterTooLarge { bytes: 1600, .. })
    ));
    assert!(matches!(
        try_render_region(&d, &r, 4, &plain, &lim(usize::MAX, usize::MAX, 19)),
        Err(RenderError::RasterTooLarge { width: 20, .. })
    ));
    // A float threshold of 3 grows the measured rectangle by 2 on each side: 9 x 9 = 81.
    let floats = opts(false, 3, false);
    assert!(try_render_region(&d, &r, 4, &floats, &lim(81, usize::MAX, usize::MAX)).is_ok());
    assert!(matches!(
        try_render_region(&d, &r, 4, &floats, &lim(80, usize::MAX, usize::MAX)),
        Err(RenderError::TooManyCells {
            ends: 9,
            picks: 9,
            cells: 81,
            ..
        })
    ));
    // An absurd threshold is clipped to the draft (20 x 20 = 400), never sized past it.
    let absurd = opts(false, u32::MAX, false);
    assert!(try_render_region(&d, &r, 4, &absurd, &lim(400, usize::MAX, usize::MAX)).is_ok());
    assert!(try_render_region(&d, &r, 4, &absurd, &lim(399, usize::MAX, usize::MAX)).is_err());
    // A pitch whose raster cannot even be sized is an overflow, not a wrap or a panic (64-bit: the
    // byte count overflows; 32-bit: the side already does).
    assert_eq!(
        try_render_region(&d, &r, u32::MAX, &plain, &UNBOUNDED),
        Err(RenderError::Overflow)
    );
}

#[test]
fn fit_region_cell_px_finds_the_largest_pitch_that_fits() {
    let d = twill(20, 20, ShedType::Rising);
    let r = region(0..10, 0..5);
    let lim = |bytes, side| RenderLimits {
        max_cells: usize::MAX,
        max_raster_bytes: bytes,
        max_raster_side: side,
    };
    // Asked-for pitch fits: kept. 0 is treated as 1.
    assert_eq!(
        fit_region_cell_px(&d, &r, 12, &RenderLimits::DEFAULT),
        Ok(12)
    );
    assert_eq!(fit_region_cell_px(&d, &r, 0, &RenderLimits::DEFAULT), Ok(1));
    // 10 x 5 cells at 4 px = 40 x 20 px = 3200 bytes.
    assert_eq!(
        fit_region_cell_px(&d, &r, 12, &lim(3200, usize::MAX)),
        Ok(4)
    );
    assert_eq!(
        fit_region_cell_px(&d, &r, 12, &lim(3199, usize::MAX)),
        Ok(3)
    );
    assert_eq!(fit_region_cell_px(&d, &r, 12, &lim(usize::MAX, 59)), Ok(5));
    assert!(matches!(
        fit_region_cell_px(&d, &r, 12, &lim(usize::MAX, 9)),
        Err(RenderError::RasterTooLarge { width: 10, .. })
    ));
    // A fitted pitch always renders.
    let px = fit_region_cell_px(&d, &r, 12, &lim(3000, usize::MAX)).unwrap();
    assert!(try_render_region(
        &d,
        &r,
        px,
        &RenderOptions::default(),
        &lim(3000, usize::MAX)
    )
    .is_ok());
}

/// A small region of a realistic large draft renders under the default budget even though the
/// whole draft is far over it.
#[test]
fn a_region_of_a_huge_draft_renders_under_the_default_budget() {
    let big = structure::plain_weave(3000, 3000); // 9 million intersections
    let o = opts(true, 5, true);
    assert!(matches!(
        try_render_rgba_with(&big, 1, &o, &RenderLimits::DEFAULT),
        Err(RenderError::TooManyCells { .. })
    ));
    let r = region(1400..1480, 2900..3000);
    let img = try_render_region(&big, &r, 12, &o, &RenderLimits::DEFAULT).unwrap();
    assert_eq!((img.width, img.height), (80 * 12, 100 * 12));
    assert_region_is_crop(
        &structure::plain_weave(1500, 3000),
        &region(1400..1480, 2900..3000),
        2,
        &o,
    );
}

// --- property: region == crop, for random drafts ------------------------------------------------

/// A random draft: either drive, either shed, multi-shaft and unthreaded ends, ids past the header,
/// ragged color plans, and sometimes per-thread thickness (which a region must ignore).
fn arb_draft() -> impl Strategy<Value = Draft> {
    (
        1usize..14,
        1usize..14,
        1u16..6,
        any::<bool>(),
        any::<bool>(),
        any::<bool>(),
        any::<u64>(),
    )
        .prop_map(|(ends, picks, shafts, sinking, liftplan, thick, seed)| {
            // A tiny deterministic generator keeps the strategy cheap to shrink by its seed.
            let mut s = seed | 1;
            let mut next = move |n: u64| {
                s ^= s << 13;
                s ^= s >> 7;
                s ^= s << 17;
                s % n
            };
            let shaft_ids = |next: &mut dyn FnMut(u64) -> u64, k: u64| -> Vec<ShaftId> {
                (0..next(k))
                    .map(|_| ShaftId(next(shafts as u64 + 2) as u16 + 1))
                    .collect()
            };
            let threading = Threading((0..ends).map(|_| shaft_ids(&mut next, 3)).collect());
            let drive = if liftplan {
                Drive::Liftplan(Liftplan(
                    (0..picks).map(|_| shaft_ids(&mut next, 4)).collect(),
                ))
            } else {
                let treadles = 1 + next(5) as u16;
                Drive::Treadled {
                    tieup: TieUp((0..treadles).map(|_| shaft_ids(&mut next, 4)).collect()),
                    treadling: Treadling(
                        (0..picks)
                            .map(|_| {
                                (0..next(3))
                                    .map(|_| TreadleId(next(treadles as u64 + 2) as u16 + 1))
                                    .collect()
                            })
                            .collect(),
                    ),
                }
            };
            let warp_len = (ends as u64 + 2 - next(3)) as usize;
            let weft_len = (picks as u64 + 2 - next(3)) as usize;
            Draft {
                name: "random".into(),
                shafts,
                treadles: 0,
                shed: if sinking {
                    ShedType::Sinking
                } else {
                    ShedType::Rising
                },
                unit: Unit::Inches,
                threading,
                drive,
                colors: ColorPlan {
                    palette: vec![
                        Color::BLACK,
                        Color::rgb(230, 200, 40),
                        Color::rgb(10, 140, 90),
                    ],
                    // Index 3 dangles past the palette (drawn white), as validate() would flag.
                    warp: (0..warp_len).map(|_| next(4) as usize).collect(),
                    weft: (0..weft_len).map(|_| next(4) as usize).collect(),
                },
                warp_thickness: if thick {
                    (0..ends).map(|_| 1.0 + next(3) as f32).collect()
                } else {
                    Vec::new()
                },
                weft_thickness: if thick {
                    (0..picks).map(|_| 1.0 + next(3) as f32).collect()
                } else {
                    Vec::new()
                },
                notes: String::new(),
                retained: Vec::new(),
            }
        })
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(512))]

    /// For random drafts, regions (including ones touching any edge and 1x1), pitches and option
    /// combinations, the region render equals the crop of the full uniform render.
    #[test]
    fn region_equals_the_crop_of_the_full_render(
        d in arb_draft(),
        e in (0usize..14, 1usize..14),
        p in (0usize..14, 1usize..14),
        px in 1u32..6,
        gridlines in any::<bool>(),
        float_threshold in 0u32..8,
        thread_texture in any::<bool>(),
    ) {
        let e0 = e.0 % d.ends();
        let e1 = (e0 + e.1).min(d.ends());
        let p0 = p.0 % d.picks();
        let p1 = (p0 + p.1).min(d.picks());
        let r = region(e0..e1, p0..p1);
        let o = opts(gridlines, float_threshold, thread_texture);
        let got = try_render_region(&d, &r, px, &o, &UNBOUNDED).unwrap();
        let want = expected(&d, &r, px, &o);
        prop_assert_eq!((got.width, got.height), (want.width, want.height));
        prop_assert!(got.pixels == want.pixels, "region {:?} at {} px, {:?}", r, px, o);
    }
}
