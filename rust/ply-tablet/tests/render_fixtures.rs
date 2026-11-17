//! The band renderer and the written working instructions (M10-02) against the oracle bands of
//! `fixtures/tablet/oracle/`. The rendered top face and back are read back pixel by pixel and must
//! show, in every cell, the colour of the oracle's grids (transcribed from ADR 0018's hand-worked
//! tables, never from the engine), the oracle's stitch slant, its reversal lines, its ambiguous
//! cells (both candidate colours) and its not-modelled cells (hatched). The turning chart shows each
//! action and the flip and release marks. The instructions of oracle band 1 and sampler 2 are the
//! lines ADR 0018 sections 8, 11 and 12 describe, word for word.
//!
//! Run: `cargo test -p ply-tablet --test render_fixtures`

use ply_tablet::{
    try_render_face, try_render_turning, try_simulate, try_simulate_all, working_instructions,
    Face, InstructionKind, RasterLimits, RenderOptions, TabletBand, TabletLimits, TabletRaster,
};
use serde_json::Value;

const PX: u32 = 10;
const INK_DARK: [u8; 4] = [20, 20, 20, 255];
const INK_LIGHT: [u8; 4] = [245, 245, 245, 255];
const HATCH_BG: [u8; 4] = [250, 250, 250, 255];
const HATCH_INK: [u8; 4] = [140, 140, 140, 255];

fn read(name: &str, ext: &str) -> String {
    let path = format!(
        "{}/../../fixtures/tablet/oracle/{name}.{ext}",
        env!("CARGO_MANIFEST_DIR")
    );
    std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{path}: {e}"))
}

fn band(name: &str) -> TabletBand {
    serde_json::from_str(&read(name, "band.json")).unwrap()
}

fn oracle(name: &str) -> Value {
    serde_json::from_str(&read(name, "expect.json")).unwrap()
}

fn plain() -> RenderOptions {
    RenderOptions {
        cell_px: PX,
        letters: false,
        grid: false,
    }
}

fn rgba(band: &TabletBand, letter: &str, letters: &[String]) -> [u8; 4] {
    let i = letters.iter().position(|l| l == letter).unwrap();
    let c = band.palette[i];
    [c.r, c.g, c.b, 255]
}

/// Pixel (`dx`, `dy`) of the cell drawn at column `x` for pick `pick` (pick 1 at the bottom).
fn at(r: &TabletRaster, picks: u32, x: usize, pick: u32, dx: u32, dy: u32) -> [u8; 4] {
    let y = (picks - pick) * PX;
    r.pixel(x as u32 * PX + dx, y + dy).unwrap()
}

/// The oracle's per-card entry for one pick.
fn entry(exp: &Value, card: usize, pick: u32) -> &Value {
    &exp["cards"][card]["picks"][(pick - 1) as usize]
}

fn check_face(name: &str, face: Face, grid_key: &str) {
    let b = band(name);
    let exp = oracle(name);
    let Some(grid) = exp.get(grid_key) else {
        return;
    };
    let letters: Vec<String> = exp["palette_letters"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v.as_str().unwrap().to_string())
        .collect();
    let w = try_simulate_all(&b, &TabletLimits::DEFAULT).unwrap();
    let picks = w.last_pick;
    let r = try_render_face(&b, &w, face, &plain(), &RasterLimits::DEFAULT).unwrap();
    let n = b.cards.len();
    assert_eq!(
        (r.width, r.height, r.cell_px),
        (n as u32 * PX, picks * PX, PX)
    );
    let slants = exp.get("top_slant");
    for (p, row) in grid.as_array().unwrap().iter().enumerate() {
        let pick = p as u32 + 1;
        let cells: Vec<&str> = row.as_str().unwrap().split(' ').collect();
        for (x, cell) in cells.iter().enumerate() {
            let card = match face {
                Face::Top => x,
                Face::Back => n - 1 - x,
            };
            let e = entry(&exp, card, pick);
            let what = format!("{name} {face:?} pick {pick} card {}", card + 1);
            match *cell {
                "?" => {
                    // Both candidates, NT (or FB) on the left half, FT (or NB) on the right.
                    let key = if face == Face::Top {
                        "top_color"
                    } else {
                        "back_color"
                    };
                    let both: Vec<&str> = e[key].as_str().unwrap().split(" or ").collect();
                    let side = |l: &str| {
                        if l == "none" {
                            None
                        } else {
                            Some(rgba(&b, l, &letters))
                        }
                    };
                    for (dx, want) in [(0, side(both[0])), (PX - 1, side(both[1]))] {
                        let got = at(&r, picks, x, pick, dx, PX / 2);
                        match want {
                            Some(c) => assert_eq!(got, c, "{what}: candidate"),
                            None => assert!(got == HATCH_BG || got == HATCH_INK, "{what}"),
                        }
                    }
                }
                "-" => {
                    let px: Vec<[u8; 4]> = (0..PX)
                        .flat_map(|dy| (0..PX).map(move |dx| (dx, dy)))
                        .map(|(dx, dy)| at(&r, picks, x, pick, dx, dy))
                        .collect();
                    assert!(
                        px.contains(&HATCH_BG) && px.contains(&HATCH_INK),
                        "{what}: hatched"
                    );
                }
                letter => {
                    let colour = rgba(&b, letter, &letters);
                    // Off both diagonals: the cell's own colour.
                    assert_eq!(at(&r, picks, x, pick, 2, 6), colour, "{what}");
                    let ink = if colour[..3].iter().map(|&v| u32::from(v)).sum::<u32>() < 384 {
                        INK_LIGHT
                    } else {
                        INK_DARK
                    };
                    // The slant: '/' passes (4, 5), '\' passes (4, 4) at 10 px (inset 1).
                    // The slant grid is the top face's (card 1 at the left); a cord has the same
                    // hand from either side, so the back shows the same slant for the same card.
                    let slant = slants
                        .map(|s| {
                            s[p].as_str()
                                .unwrap()
                                .split(' ')
                                .nth(card)
                                .unwrap()
                                .to_string()
                        })
                        .unwrap_or_else(|| match e["twining"].as_str() {
                            Some("Z") => "/".into(),
                            Some("S") => "\\".into(),
                            _ => "|".into(),
                        });
                    let (rising, falling) =
                        (at(&r, picks, x, pick, 4, 5), at(&r, picks, x, pick, 4, 4));
                    match slant.as_str() {
                        "/" => assert_eq!((rising, falling), (ink, colour), "{what}: /"),
                        "\\" => assert_eq!((rising, falling), (colour, ink), "{what}: \\"),
                        _ => assert_eq!((rising, falling), (colour, colour), "{what}: no slant"),
                    }
                    // The reversal line along the cell's foot, or the cell's colour there.
                    let foot = at(&r, picks, x, pick, 2, PX - 1);
                    if e["reversal"].as_bool().unwrap() {
                        assert_eq!(foot, INK_DARK, "{what}: reversal");
                        assert_eq!(at(&r, picks, x, pick, 2, PX - 2), INK_LIGHT, "{what}: edge");
                    } else {
                        assert_eq!(foot, colour, "{what}: no reversal");
                    }
                }
            }
        }
    }
}

#[test]
fn rendered_faces_show_every_oracle_cell() {
    for name in [
        "band-1-threaded-in",
        "sampler-2-starts-idles-flip",
        "sampler-3-flip-then-opposite",
    ] {
        check_face(name, Face::Top, "top_face");
        check_face(name, Face::Back, "back_face");
    }
}

#[test]
fn a_window_renders_as_the_same_rows_of_the_whole_band() {
    let b = band("band-1-threaded-in");
    let limits = TabletLimits::DEFAULT;
    let opts = RenderOptions {
        cell_px: 12,
        letters: true,
        grid: true,
    };
    let whole = try_render_face(
        &b,
        &try_simulate_all(&b, &limits).unwrap(),
        Face::Top,
        &opts,
        &RasterLimits::DEFAULT,
    )
    .unwrap();
    let part = try_render_face(
        &b,
        &try_simulate(&b, 5..=8, &limits).unwrap(),
        Face::Top,
        &opts,
        &RasterLimits::DEFAULT,
    )
    .unwrap();
    let row_bytes = whole.width as usize * 4;
    // Picks 5 to 8 are rows (12 - 8) * 12 to (12 - 4) * 12 of the whole band (pick 1 at the bottom).
    let from = 4 * 12 * row_bytes;
    assert_eq!(part.pixels, whole.pixels[from..from + 4 * 12 * row_bytes]);
    // Letters change the drawing; the colours under them do not.
    let bare = try_render_face(
        &b,
        &try_simulate(&b, 5..=8, &limits).unwrap(),
        Face::Top,
        &RenderOptions {
            letters: false,
            ..opts
        },
        &RasterLimits::DEFAULT,
    )
    .unwrap();
    assert_ne!(bare.pixels, part.pixels);
}

#[test]
fn the_turning_chart_shows_actions_flips_and_releases() {
    let b = band("sampler-2-starts-idles-flip");
    let w = try_simulate_all(&b, &TabletLimits::DEFAULT).unwrap();
    let r = turning(&w);
    let picks = w.last_pick;
    // A fill per action (the letters are drawn on top in the middle). Pick 1 is FFFI.
    let fill = |card: usize, pick: u32| at(&r, picks, card, pick, 1, 1);
    assert_eq!(fill(0, 1), [255, 255, 255, 255], "F");
    assert_eq!(fill(3, 1), [236, 236, 236, 255], "I");
    // Pick 3 is IFBF.
    assert_eq!(fill(2, 3), [200, 208, 214, 255], "B");
    // Before pick 6: card 4 flipped (dashes along the foot), card 1's twist released (dots 3 px
    // above the foot, where they never cover a flip's dashes).
    let foot = |x: usize, dx: u32| at(&r, picks, x, 6, dx, PX - 1);
    let dots = |x: usize, dx: u32| at(&r, picks, x, 6, dx, PX - 4);
    let dashes = (foot(3, 0), foot(3, 1), foot(3, 2));
    assert_eq!(dashes, (INK_DARK, INK_DARK, INK_DARK));
    let grid = [176, 176, 176, 255];
    assert_eq!(foot(3, 3), grid, "a gap in the dashes shows the grid line");
    assert_eq!(dots(0, 0), INK_DARK);
    assert_ne!(dots(0, 1), INK_DARK);
    assert_eq!(foot(0, 0), grid, "no flip under card 1");
    // Card 2 has neither: just the grid line.
    assert_eq!(foot(1, 0), grid);
    assert_ne!(dots(1, 0), INK_DARK);
}

fn turning(w: &ply_tablet::TabletWindow) -> TabletRaster {
    let opts = RenderOptions {
        cell_px: PX,
        ..RenderOptions::default()
    };
    try_render_turning(w, &opts, &RasterLimits::DEFAULT).unwrap()
}

#[test]
fn a_card_released_and_flipped_shows_both_marks() {
    let mut b = band("sampler-2-starts-idles-flip");
    // Pick 6 releases card 1 and flips card 4: release card 4 as well.
    b.turning.segments[2].picks[1]
        .release_twist
        .push("card-4".into());
    let w = try_simulate_all(&b, &TabletLimits::DEFAULT).unwrap();
    let r = turning(&w);
    let picks = w.last_pick;
    assert_eq!(
        at(&r, picks, 3, 6, 0, PX - 1),
        INK_DARK,
        "the flip's dashes"
    );
    assert_eq!(
        at(&r, picks, 3, 6, 0, PX - 4),
        INK_DARK,
        "the release's dots"
    );
    assert_ne!(at(&r, picks, 3, 6, 1, PX - 4), INK_DARK);
}

#[test]
fn a_raster_past_its_budget_is_refused_and_a_large_one_drops_its_pitch() {
    let b = band("band-1-threaded-in");
    let w = try_simulate_all(&b, &TabletLimits::DEFAULT).unwrap();
    let small = RasterLimits {
        max_cells: 95, // 8 cards by 12 picks is 96 cells
        ..RasterLimits::DEFAULT
    };
    assert!(try_render_face(&b, &w, Face::Top, &plain(), &small).is_err());
    let tight = RasterLimits {
        max_raster_bytes: 8 * 12 * 25 * 4, // fits 5 px a cell
        ..RasterLimits::DEFAULT
    };
    let r = try_render_face(
        &b,
        &w,
        Face::Top,
        &RenderOptions {
            cell_px: 40,
            ..plain()
        },
        &tight,
    )
    .unwrap();
    assert_eq!((r.cell_px, r.width, r.height), (5, 40, 60));
}

fn lines(name: &str) -> Vec<(InstructionKind, String, String)> {
    working_instructions(&band(name), &TabletLimits::DEFAULT, 1_000)
        .unwrap()
        .lines
        .into_iter()
        .map(|l| (l.kind, l.label, l.text))
        .collect()
}

#[test]
fn band_1_instructions_follow_adr_0018() {
    use InstructionKind::*;
    let s = |k, a: &str, b: &str| (k, a.to_string(), b.to_string());
    assert_eq!(
        lines("band-1-threaded-in"),
        vec![
            s(Pick, "Picks 1 to 4", "Every card forward. Worked 4 times."),
            s(Ledger, "After pick 4", "Twist: cards 1 to 4 +4, cards 5 to 8 -4. Every card is back at its starting position."),
            s(Pick, "Picks 5 to 8", "Every card backward. Worked 4 times."),
            s(Ledger, "After pick 8", "Twist: cards 1 to 8 0. Every card is back at its starting position."),
            s(Pick, "Picks 9 to 12", "Left (cards 1 to 4) forward; Right (cards 5 to 8) backward. Worked 4 times."),
            s(Ledger, "After pick 12", "Twist: cards 1 to 8 +4. Every card is back at its starting position."),
        ]
    );
}

#[test]
fn sampler_2_instructions_follow_adr_0018() {
    use InstructionKind::*;
    let s = |k, a: &str, b: &str| (k, a.to_string(), b.to_string());
    assert_eq!(
        lines("sampler-2-starts-idles-flip"),
        vec![
            s(Pick, "Pick 1", "Cards 1 to 3 forward; card 4 idles."),
            s(Pick, "Pick 2", "Every card forward."),
            s(Ledger, "After pick 2", "Twist: cards 1 and 3 +2, card 2 -2, card 4 +1."),
            s(Pick, "Picks 3 to 4", "Card 1 idles; cards 2 and 4 forward; card 3 backward. Worked 2 times."),
            s(Ledger, "After pick 4", "Twist: card 1 +2, card 2 -4, card 3 0, card 4 +3."),
            s(Pick, "Pick 5", "Cards 1 and 4 forward; cards 2 and 3 backward."),
            s(Pick, "Pick 6", "Before the pick: release the twist behind card 1; flip card 4 (it becomes Z-threaded). Cards 1 and 2 backward; cards 3 and 4 forward."),
            s(Pick, "Pick 7", "Cards 1 and 2 backward; cards 3 and 4 forward."),
            s(Pick, "Pick 8", "Card 1 backward; card 2 idles; cards 3 and 4 forward."),
            s(Pick, "Pick 9", "Every card forward."),
            s(Ledger, "After pick 9", "Twist: cards 1 and 2 -2, card 3 +3, card 4 0."),
        ]
    );
}

#[test]
fn a_repeated_block_has_a_heading_and_steps() {
    let mut b = band("band-1-threaded-in");
    // Fold segments 1 and 2 into one block of two picks worked 4 times.
    let f = b.turning.segments[0].picks[0].clone();
    let back = b.turning.segments[1].picks[0]
        .clone()
        .with_flip(&["card-2"]);
    b.turning.segments = vec![ply_tablet::Segment::new(4, vec![f, back])];
    let got: Vec<(InstructionKind, String, String)> =
        working_instructions(&b, &TabletLimits::DEFAULT, 100)
            .unwrap()
            .lines
            .into_iter()
            .map(|l| (l.kind, l.label, l.text))
            .collect();
    assert_eq!(
        got[0],
        (
            InstructionKind::Block,
            "Picks 1 to 8".into(),
            "Work the next 2 picks 4 times.".into()
        )
    );
    assert_eq!(
        got[1],
        (
            InstructionKind::Step,
            "Step 1".into(),
            "Every card forward.".into()
        )
    );
    assert_eq!(
        got[2],
        (
            InstructionKind::Step,
            "Step 2".into(),
            "Before it, each time: flip card 2 (each time it changes S to Z or Z to S). Every card backward.".into()
        )
    );
    assert_eq!(got[3].0, InstructionKind::Ledger);
    assert_eq!(got.len(), 4);
}
