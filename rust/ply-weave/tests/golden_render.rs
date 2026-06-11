//! Golden render tests: pin `render_rgba`'s exact pixel output for known WIF fixtures.
//!
//! Deterministic, host-only (`cargo test`) — no Flutter, no FFI. They lock two things
//! at once:
//!   1. interlacement correctness (which intersections show warp vs weft), and
//!   2. the vertical-flip ORIENTATION contract: `render_rgba` draws pick 0 at the
//!      BOTTOM of the image (`row_top = (picks - 1 - pick) * cell`, see
//!      `drawdown.rs`), so the Flutter side must NOT flip again.
//!
//! The fixtures use a black warp (palette idx 1 = 0,0,0) over a white weft
//! (idx 2 = 255,255,255), so every warp-up pixel is pure black and every weft-up
//! pixel pure white — making pixel assertions unambiguous.

use ply_weave::{compute, render_rgba, wif, Cell, RgbaImage};

const BLACK: [u8; 4] = [0, 0, 0, 255];
const WHITE: [u8; 4] = [255, 255, 255, 255];

/// RGBA8 at (x, y). Buffer is row-major, tightly packed (stride = width * 4),
/// top-to-bottom.
fn px(img: &RgbaImage, x: usize, y: usize) -> [u8; 4] {
    let o = (y * img.width as usize + x) * 4;
    [img.pixels[o], img.pixels[o + 1], img.pixels[o + 2], img.pixels[o + 3]]
}

/// How many pixels exactly equal `want`.
fn count(img: &RgbaImage, want: [u8; 4]) -> usize {
    img.pixels.chunks_exact(4).filter(|c| **c == want).count()
}

#[test]
fn plain_weave_golden() {
    let d = wif::parse(include_str!("fixtures/plain_2x2.wif")).expect("plain fixture parses");
    assert_eq!((d.ends(), d.picks()), (2, 2));

    // Interlacement (palette-independent): a clean 2x2 checkerboard.
    let dd = compute(&d);
    assert!(matches!(dd.cell(0, 0), Cell::WarpUp(_)));
    assert!(matches!(dd.cell(1, 0), Cell::WeftUp(_)));
    assert!(matches!(dd.cell(0, 1), Cell::WeftUp(_)));
    assert!(matches!(dd.cell(1, 1), Cell::WarpUp(_)));

    // Render at 4 px/cell -> 8x8.
    let img = render_rgba(&d, 4);
    assert_eq!((img.width, img.height), (8, 8));
    assert_eq!(img.pixels.len(), 8 * 8 * 4);

    // Corner pixels prove interlacement AND that pick 0 is at the BOTTOM (rows y=4..7):
    //   bottom band (pick 0): end0 warp-up=BLACK, end1 weft-up=WHITE
    //   top band    (pick 1): end0 weft-up=WHITE, end1 warp-up=BLACK
    assert_eq!(px(&img, 0, 4), BLACK, "bottom-left = pick0/end0 warp-up");
    assert_eq!(px(&img, 4, 4), WHITE, "bottom-right = pick0/end1 weft-up");
    assert_eq!(px(&img, 0, 0), WHITE, "top-left = pick1/end0 weft-up");
    assert_eq!(px(&img, 4, 0), BLACK, "top-right = pick1/end1 warp-up");

    // Balanced plain weave: exactly half the pixels are warp-up (black).
    assert_eq!(count(&img, BLACK), 8 * 8 / 2);
    assert_eq!(count(&img, WHITE), 8 * 8 / 2);
}

#[test]
fn twill_2_2_golden() {
    // 2/2 twill: tie-up 1=1,2 / 2=2,3 / 3=3,4 / 4=1,4 ; straight threading & treadling.
    //
    //   pick | raised shafts | warp-up (black) ends | image row band (cell=4, picks=4)
    //   -----+---------------+----------------------+---------------------------------
    //    0   | {1,2}         | {0,1}                | y = 12..15  (BOTTOM)
    //    1   | {2,3}         | {1,2}                | y =  8..11
    //    2   | {3,4}         | {2,3}                | y =  4..7
    //    3   | {1,4}         | {0,3}                | y =  0..3   (TOP)
    //
    // The black run shifts RIGHT as the band moves UP -> an ascending-to-the-right
    // diagonal, which only reads correctly because pick 0 is at the bottom (no flip).
    let d = wif::parse(include_str!("fixtures/twill_2_2.wif")).expect("twill fixture parses");
    assert_eq!((d.ends(), d.picks()), (4, 4));

    let dd = compute(&d);
    let expected_black: [&[usize]; 4] = [&[0, 1], &[1, 2], &[2, 3], &[0, 3]];
    for pick in 0..4usize {
        for end in 0..4usize {
            let is_warp_up = matches!(dd.cell(end, pick), Cell::WarpUp(_));
            assert_eq!(is_warp_up, expected_black[pick].contains(&end), "pick {pick} end {end}");
        }
    }

    let img = render_rgba(&d, 4);
    assert_eq!((img.width, img.height), (16, 16));

    // Sample the middle of representative cells per pick band (any pixel within a cell
    // is uniform): y selects the band, x = end*4 + 1 selects the end.
    // pick 0 (BOTTOM, y=13): end0 black, end2 white
    assert_eq!(px(&img, 1, 13), BLACK);
    assert_eq!(px(&img, 9, 13), WHITE);
    // pick 1 (y=9): end1 black, end0 white
    assert_eq!(px(&img, 5, 9), BLACK);
    assert_eq!(px(&img, 1, 9), WHITE);
    // pick 2 (y=5): end3 black, end0 white
    assert_eq!(px(&img, 13, 5), BLACK);
    assert_eq!(px(&img, 1, 5), WHITE);
    // pick 3 (TOP, y=1): end0 black, end1 white, end3 black
    assert_eq!(px(&img, 1, 1), BLACK);
    assert_eq!(px(&img, 5, 1), WHITE);
    assert_eq!(px(&img, 13, 1), BLACK);

    // Balanced 2/2 twill: exactly half warp-up (black).
    assert_eq!(count(&img, BLACK), 16 * 16 / 2);
    assert_eq!(count(&img, WHITE), 16 * 16 / 2);
}
