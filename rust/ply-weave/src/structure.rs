//! Whole-draft structure generators (M4+): given a few parameters, build a COMPLETE `Draft`
//! (threading + tie-up + treadling + colors) for a named weave structure. Unlike the plain/twill/
//! satin tie-up constructors in [`crate::draft`] (which the editor composes with a threading + a
//! straight treadling on the Dart side), these structures are interdependent — the threading, the
//! tie-up, the treadling, and (for color-and-weave) the warp/weft colors must agree — so each is
//! generated here as one whole, testable unit and surfaced through a single bridge call.
//!
//! Each generator is PURE and returns a validate()-clean draft sized to the requested ends x picks.
//! The worked examples in the tests were hand-derived AND adversarially verified (a straight-draw
//! "overshot" is really a twill; a half-drop "shadow weave" is really solid stripes; a both-shafts-up
//! "double weave" is really single-layer tabby) — the matrices below are the CORRECTED forms.

use ply_common::{Color, Unit};

use crate::draft::{
    ColorIndex, ColorPlan, Draft, Drive, ShaftId, ShedType, Threading, TieUp, Treadling, TreadleId,
};

/// Two mid-contrast greys for color-and-weave; softer than pure black/white (which reads harsh),
/// per the shadow-weave convention. Index 0 = light, 1 = dark.
const LIGHT: Color = Color { r: 219, g: 219, b: 219 };
const DARK: Color = Color { r: 45, g: 45, b: 45 };

fn base_draft(name: &str, shafts: u16, treadles: u16, threading: Threading, tieup: TieUp,
    treadling: Treadling, palette: Vec<Color>, warp: Vec<ColorIndex>, weft: Vec<ColorIndex>,
) -> Draft {
    Draft {
        name: name.to_string(),
        shafts,
        treadles,
        shed: ShedType::Rising,
        unit: Unit::Inches,
        threading,
        drive: Drive::Treadled { tieup, treadling },
        colors: ColorPlan { palette, warp, weft },
        warp_thickness: Vec::new(),
        weft_thickness: Vec::new(),
        notes: String::new(),
        retained: Vec::new(),
    }
}

/// OVERSHOT (basic two-block / "monk's belt" form). A figured pattern weave: a fine plain-weave
/// ground (tabby) carries a thicker PATTERN weft that floats over whole BLOCKS to draw the motif.
///
/// Two opposite blocks — block A on shafts {1,2}, block B on shafts {3,4} — alternate every `block`
/// ends, so the threading is NOT a straight draw (a straight draw figures nothing — it is a twill).
/// Pattern picks raise one block's shaft-pair (hiding the pattern weft there and floating it over the
/// other block); tabby picks (odds {1,3} / evens {2,4}) lock the ground. Picks alternate
/// pattern / tabby. The pattern weft is palette color 1, the ground (and warp) color 0.
///
/// `block` is the block width in ends (>= 2); `ends`/`picks` size the cloth (picks ideally even).
pub fn overshot(ends: usize, picks: usize, block: usize) -> Draft {
    let block = block.max(2);
    // Threading: alternate block A {1,2} and block B {3,4} every `block` ends; within a block the
    // pair alternates (lo, hi, lo, hi) so the tabby still plain-weaves across both blocks.
    let threading = Threading(
        (0..ends)
            .map(|i| {
                let block_b = (i / block) % 2 == 1; // false = A {1,2}, true = B {3,4}
                let hi = i % 2 == 1; // second shaft of the pair on odd positions
                let shaft = match (block_b, hi) {
                    (false, false) => 1,
                    (false, true) => 2,
                    (true, false) => 3,
                    (true, true) => 4,
                };
                vec![ShaftId(shaft)]
            })
            .collect(),
    );
    // Tie-up: treadle 1 = pattern A {1,2}, 2 = pattern B {3,4}, 3 = tabby odds {1,3}, 4 = tabby evens.
    let tieup = TieUp(vec![
        vec![ShaftId(1), ShaftId(2)],
        vec![ShaftId(3), ShaftId(4)],
        vec![ShaftId(1), ShaftId(3)],
        vec![ShaftId(2), ShaftId(4)],
    ]);
    // Treadling: pattern picks (even) follow the block sequence (each block held for `block`/2 pattern
    // rows, mirroring the threading "as drawn in"); tabby picks (odd) alternate treadles 3 and 4.
    let rows_per_block = (block / 2).max(1);
    let treadling = Treadling(
        (0..picks)
            .map(|p| {
                if p % 2 == 0 {
                    let pattern_row = p / 2;
                    let block_b = (pattern_row / rows_per_block) % 2 == 1;
                    vec![TreadleId(if block_b { 2 } else { 1 })]
                } else {
                    let tabby = p / 2; // strict 3,4,3,4 alternation
                    vec![TreadleId(if tabby % 2 == 0 { 3 } else { 4 })]
                }
            })
            .collect(),
    );
    let warp = vec![0; ends];
    let weft = (0..picks).map(|p| if p % 2 == 0 { 1 } else { 0 }).collect();
    base_draft("Overshot", 4, 4, threading, tieup, treadling,
        vec![Color::WHITE, DARK], warp, weft)
}

/// SHADOW WEAVE — a color-and-weave on a simple ground (plain or 2/2 twill) where each warp/weft
/// thread alternates LIGHT/DARK, but the color order is PHASE-SHIFTED every `block` threads
/// (log-cabin style). A plain half-drop alternation flattens to solid stripes; the per-block phase
/// flip is what makes adjacent same-colored threads interlace oppositely, producing the fine shifting
/// shadow lines. `twill` selects a 2/2-twill ground (4 shafts) over plain weave (2 shafts).
pub fn shadow_weave(ends: usize, picks: usize, twill: bool, block: usize) -> Draft {
    let block = block.max(2);
    let shafts: u16 = if twill { 4 } else { 2 };
    let threading = Threading::straight(ends, shafts);
    let tieup = if twill { TieUp::twill(2, 2) } else { TieUp::plain(2) };
    let period = if twill { 4 } else { 2 };
    let treadling = Treadling(
        (0..picks).map(|p| vec![TreadleId((p % period) as u16 + 1)]).collect(),
    );
    // Log-cabin phase shift: flip the L/D parity every `block` threads. (i + (i/block mod 2)) mod 2.
    let phase = |i: usize| -> ColorIndex { (i + ((i / block) % 2)) % 2 };
    let warp = (0..ends).map(phase).collect();
    let weft = (0..picks).map(phase).collect();
    base_draft(if twill { "Shadow weave (twill)" } else { "Shadow weave" },
        shafts, period as u16, threading, tieup, treadling, vec![LIGHT, DARK], warp, weft)
}

/// DOUBLE WEAVE — two INDEPENDENT plain-weave layers woven at once on 4 shafts: the top layer on
/// shafts {1,3}, the bottom on {2,4}, threaded straight (1,2,3,4 …). The textbook rising-shed
/// (jack/liftplan) form: a TOP pick raises ONE top shaft and leaves the bottom layer DOWN (it sits
/// below the top weft); a BOTTOM pick raises BOTH top shafts (lifting the whole top layer up out of
/// the way) plus one bottom shaft, so the bottom weft passes under the top layer. This keeps the
/// {1,3} (color 0) layer physically on top, matching the warp-colour legend — so the flat drawdown
/// reads as the top layer's face rather than the inverted, muddled mix the both-bottom-shafts-up
/// variant produces. Each layer reads cleanly on its own in the layer inspector. (Naively raising a
/// layer's BOTH shafts together collapses to single-layer tabby.)
pub fn double_weave(ends: usize, picks: usize) -> Draft {
    let threading = Threading::straight(ends, 4);
    // 4 distinct sheds (top,bottom,top,bottom): a top pick raises one top shaft (bottom stays down,
    // below); a bottom pick raises BOTH top shafts + one bottom shaft (top lifted clear, above).
    let tieup = TieUp(vec![
        vec![ShaftId(1)],                          // top weft, top end on shaft 1 up; bottom down
        vec![ShaftId(1), ShaftId(2), ShaftId(3)], // bottom weft, top {1,3} lifted clear + shaft 2 up
        vec![ShaftId(3)],                          // top weft, top end on shaft 3 up; bottom down
        vec![ShaftId(1), ShaftId(3), ShaftId(4)], // bottom weft, top {1,3} lifted clear + shaft 4 up
    ]);
    let treadling = Treadling(
        (0..picks).map(|p| vec![TreadleId((p % 4) as u16 + 1)]).collect(),
    );
    // Warp by layer parity (odd shafts = top = color 0, even shafts = bottom = color 1); weft by pick
    // parity (top picks 0,2 = color 0; bottom picks 1,3 = color 1).
    let warp = (0..ends).map(|i| i % 2).collect();
    let weft = (0..picks).map(|p| p % 2).collect();
    base_draft("Double weave", 4, 4, threading, tieup, treadling,
        vec![Color { r: 40, g: 70, b: 130 }, Color { r: 205, g: 130, b: 60 }], warp, weft)
}

/// Plain weave (tabby) as a whole draft — a straight draw on 2 shafts with the canonical plain
/// tie-up. Mostly a neutral fallback for the whole-draft bridge path; the editor's Plain/Twill/Satin
/// "generate structure" action composes its own draft on the Dart side.
pub fn plain_weave(ends: usize, picks: usize) -> Draft {
    let threading = Threading::straight(ends, 2);
    let treadling = Treadling((0..picks).map(|p| vec![TreadleId((p % 2) as u16 + 1)]).collect());
    base_draft("Plain weave", 2, 2, threading, TieUp::plain(2), treadling,
        vec![Color::WHITE, Color::BLACK], vec![0; ends], vec![1; picks])
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::validate::validate;

    // Pull the raised-shaft set for a pick straight off the draft, the same way the drawdown does,
    // so the structural assertions below test the ACTUAL interlacement, not a re-derivation.
    fn raised(d: &Draft, pick: usize) -> Vec<u16> {
        let mut s: Vec<u16> = d.raised_shafts(pick).iter().map(|x| x.0).collect();
        s.sort_unstable();
        s
    }

    // The shaft each end threads (overshot/shadow/double all thread exactly one shaft per end).
    fn shaft_of(d: &Draft, end: usize) -> u16 {
        d.threading.0[end][0].0
    }

    // Does warp end `end` show on the face at `pick` (its shaft is raised, Rising shed)?
    fn warp_up(d: &Draft, end: usize, pick: usize) -> bool {
        d.raised_shafts(pick).contains(&ShaftId(shaft_of(d, end)))
    }

    #[test]
    fn overshot_matches_hand_verified_golden() {
        let d = overshot(16, 8, 4);
        assert_eq!(d.shafts, 4);
        assert_eq!(d.treadles, 4);
        let threading: Vec<u16> = d.threading.0.iter().map(|v| v[0].0).collect();
        assert_eq!(threading, vec![1, 2, 1, 2, 3, 4, 3, 4, 1, 2, 1, 2, 3, 4, 3, 4]);
        if let Drive::Treadled { tieup, treadling } = &d.drive {
            let tu: Vec<Vec<u16>> = tieup.0.iter().map(|r| r.iter().map(|s| s.0).collect()).collect();
            assert_eq!(tu, vec![vec![1, 2], vec![3, 4], vec![1, 3], vec![2, 4]]);
            let tr: Vec<Vec<u16>> =
                treadling.0.iter().map(|r| r.iter().map(|t| t.0).collect()).collect();
            assert_eq!(tr, vec![vec![1], vec![3], vec![1], vec![4], vec![2], vec![3], vec![2], vec![4]]);
        } else {
            panic!("expected treadled");
        }
        assert_eq!(d.colors.weft, vec![1, 0, 1, 0, 1, 0, 1, 0]);
        assert!(validate(&d).is_empty(), "overshot golden must validate clean: {:?}", validate(&d));
    }

    #[test]
    fn overshot_figures_blocks_not_a_twill_diagonal() {
        // The whole point: pattern weft must appear as BLOCKS that swap regions between A-picks and
        // B-picks, not advance one end per pick (which would be a twill).
        let d = overshot(16, 8, 4);
        // Pattern pick 0 (treadle 1, raise {1,2}): block-A ends (0-3, 8-11) show warp; block-B ends
        // (4-7, 12-15) show pattern weft (their shafts 3,4 are DOWN).
        assert_eq!(raised(&d, 0), vec![1, 2]);
        assert!(warp_up(&d, 0, 0) && warp_up(&d, 2, 0), "block A warp up on an A pick");
        assert!(!warp_up(&d, 4, 0) && !warp_up(&d, 6, 0), "block B floats pattern weft on an A pick");
        // Pattern pick 4 (treadle 2, raise {3,4}): the float SWAPS — block A now carries the weft.
        assert_eq!(raised(&d, 4), vec![3, 4]);
        assert!(!warp_up(&d, 0, 4) && !warp_up(&d, 2, 4), "block A floats pattern weft on a B pick");
        assert!(warp_up(&d, 4, 4) && warp_up(&d, 6, 4), "block B warp up on a B pick");
    }

    #[test]
    fn overshot_tabby_picks_plain_weave_the_ground() {
        let d = overshot(16, 8, 4);
        // Tabby picks 1 (odds {1,3}) and 3 (evens {2,4}) must be exact complements over the warp.
        assert_eq!(raised(&d, 1), vec![1, 3]);
        assert_eq!(raised(&d, 3), vec![2, 4]);
        for end in 0..16 {
            assert_ne!(warp_up(&d, end, 1), warp_up(&d, end, 3),
                "tabby picks 1 and 3 must oppose at end {end} (plain-weave ground)");
        }
    }

    #[test]
    fn shadow_weave_columns_vary_not_solid_stripes() {
        // The corrected (log-cabin) color order must make at least one column change color down its
        // length — the broken half-drop version made every column a single solid color.
        let d = shadow_weave(8, 8, false, 4);
        assert_eq!(d.shafts, 2);
        assert_eq!(d.colors.warp, vec![0, 1, 0, 1, 1, 0, 1, 0]);
        assert_eq!(d.colors.weft, vec![0, 1, 0, 1, 1, 0, 1, 0]);
        // Displayed color at (end, pick): warp color if warp_up else weft color.
        let shown = |end: usize, pick: usize| -> usize {
            if warp_up(&d, end, pick) { d.colors.warp[end] } else { d.colors.weft[pick] }
        };
        let mut any_varies = false;
        for end in 0..8 {
            let c0 = shown(end, 0);
            if (0..8).any(|p| shown(end, p) != c0) {
                any_varies = true;
                break;
            }
        }
        assert!(any_varies, "a real shadow weave must have columns that change color (not solid stripes)");
        assert!(validate(&d).is_empty(), "shadow golden must validate: {:?}", validate(&d));
    }

    #[test]
    fn double_weave_each_layer_plain_weaves_and_clears_the_other() {
        let d = double_weave(8, 4);
        if let Drive::Treadled { tieup, treadling } = &d.drive {
            let tu: Vec<Vec<u16>> = tieup.0.iter().map(|r| r.iter().map(|s| s.0).collect()).collect();
            assert_eq!(tu, vec![vec![1], vec![1, 2, 3], vec![3], vec![1, 3, 4]]);
            let tr: Vec<Vec<u16>> =
                treadling.0.iter().map(|r| r.iter().map(|t| t.0).collect()).collect();
            assert_eq!(tr, vec![vec![1], vec![2], vec![3], vec![4]]);
        } else {
            panic!("expected treadled");
        }
        // TOP layer = shafts {1,3}: over its picks (0,2) exactly ONE of {1,3} is up each pick, and
        // they swap -> plain weave.
        assert_eq!(raised(&d, 0), vec![1]);
        assert_eq!(raised(&d, 2), vec![3]);
        assert!(d.raised_shafts(0).contains(&ShaftId(1)) && !d.raised_shafts(0).contains(&ShaftId(3)));
        assert!(!d.raised_shafts(2).contains(&ShaftId(1)) && d.raised_shafts(2).contains(&ShaftId(3)));
        // BOTTOM layer = shafts {2,4}: over its picks (1,3) exactly one of {2,4} is up, swapping.
        assert_eq!(raised(&d, 1), vec![1, 2, 3]);
        assert_eq!(raised(&d, 3), vec![1, 3, 4]);
        assert!(d.raised_shafts(1).contains(&ShaftId(2)) && !d.raised_shafts(1).contains(&ShaftId(4)));
        assert!(!d.raised_shafts(3).contains(&ShaftId(2)) && d.raised_shafts(3).contains(&ShaftId(4)));
        // CLEARING (top layer {1,3} stays on top): on a TOP pick the bottom layer {2,4} is fully
        // DOWN (it sits below the top weft); on a BOTTOM pick the top layer {1,3} is fully UP (lifted
        // clear so the bottom weft passes under it).
        for &top_pick in &[0usize, 2] {
            assert!(!d.raised_shafts(top_pick).contains(&ShaftId(2))
                && !d.raised_shafts(top_pick).contains(&ShaftId(4)),
                "bottom layer must stay DOWN under a top pick");
        }
        for &bottom_pick in &[1usize, 3] {
            assert!(d.raised_shafts(bottom_pick).contains(&ShaftId(1))
                && d.raised_shafts(bottom_pick).contains(&ShaftId(3)),
                "top layer must lift UP clear of a bottom pick");
        }
        assert!(validate(&d).is_empty(), "double-weave golden must validate: {:?}", validate(&d));
    }

    #[test]
    fn generators_size_to_request_and_validate() {
        for d in [overshot(24, 12, 6), shadow_weave(20, 20, true, 4), double_weave(12, 8)] {
            assert_eq!(d.ends(), d.threading.ends());
            assert!(validate(&d).is_empty(), "{} must validate clean: {:?}", d.name, validate(&d));
        }
    }
}
