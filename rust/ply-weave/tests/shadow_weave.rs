//! Shadow weave (Atwater and Powell): the generator against original worked examples, the
//! structural properties that define the technique, and the look-alikes it must not be mistaken
//! for.
//!
//! Matrices are written pick 1 first (top row) with end 1 in the LEFT column, which is array order;
//! the editor draws end 1 at the right, so it shows the mirror image. `X` = warp over weft on the
//! face (rising shed), `.` = weft over warp. In color drawdowns `D` = a dark thread shows.

use ply_weave::draft::{
    ColorIndex, ColorPlan, Draft, Drive, ShaftId, ShedType, Threading, TieUp, TreadleId, Treadling,
};
use ply_weave::drawdown::{compute, Cell};
use ply_weave::shadow::check::{self, Run};
use ply_weave::shadow::{
    atwater_to_powell, block_letter, block_lines, block_of, expand, generate, partner, tieup,
    Lines, Role, ShadowBlock, ShadowLayout, ShadowParams, ShadowShafts, ShadowSystem,
    TwillDirection, WeftPhase, DARK_COLOR, LIGHT_COLOR,
};
use ply_weave::wif;
use proptest::prelude::*;

use ShadowLayout::{Point, Repeat};
use ShadowShafts::{Eight, Four};
use ShadowSystem::{Atwater, Powell};

// ---------------------------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------------------------

/// "A2 B1 C1 D2" -> block entries.
fn seq(text: &str) -> Vec<ShadowBlock> {
    text.split_whitespace()
        .map(|t| {
            let mut chars = t.chars();
            let letter = chars.next().unwrap();
            ShadowBlock {
                block: u16::from(letter as u8 - b'A'),
                units: chars.as_str().parse().unwrap(),
            }
        })
        .collect()
}

/// One unbalanced repeat each way: exactly the worked examples' size.
fn one_repeat(
    system: ShadowSystem,
    shafts: ShadowShafts,
    layout: ShadowLayout,
    blocks: &str,
) -> ShadowParams {
    ShadowParams {
        system,
        shafts,
        layout,
        blocks: seq(blocks),
        direction: TwillDirection::Forward,
        weft_phase: WeftPhase::Standard,
        warp_repeats: 1,
        weft_repeats: 1,
        balance: false,
    }
}

fn nums(text: &str) -> Vec<u16> {
    text.split_whitespace()
        .map(|n| n.parse().unwrap())
        .collect()
}

fn shafts_of(d: &Draft) -> Vec<u16> {
    d.threading.0.iter().map(|v| v[0].0).collect()
}

fn treadles_of(d: &Draft) -> Vec<u16> {
    match &d.drive {
        Drive::Treadled { treadling, .. } => treadling.0.iter().map(|v| v[0].0).collect(),
        Drive::Liftplan(_) => panic!("expected a treadled draft"),
    }
}

fn tieup_rows(d: &Draft) -> Vec<Vec<u16>> {
    match &d.drive {
        Drive::Treadled { tieup, .. } => tieup
            .0
            .iter()
            .map(|r| r.iter().map(|s| s.0).collect())
            .collect(),
        Drive::Liftplan(_) => panic!("expected a treadled draft"),
    }
}

fn roles(colors: &[ColorIndex]) -> String {
    colors
        .iter()
        .map(|&c| if c == DARK_COLOR { 'D' } else { 'L' })
        .collect()
}

fn alternating(len: usize, first_dark: bool) -> String {
    (0..len)
        .map(|i| if (i % 2 == 0) == first_dark { 'D' } else { 'L' })
        .collect()
}

/// Interlacement rows: `X` = warp over weft.
fn matrix(d: &Draft) -> Vec<String> {
    let dd = compute(d);
    (0..dd.picks)
        .map(|p| {
            (0..dd.ends)
                .map(|e| match dd.cell(e, p) {
                    Cell::WarpUp(_) => 'X',
                    Cell::WeftUp(_) => '.',
                })
                .collect()
        })
        .collect()
}

/// Color drawdown rows: `D` = a dark thread shows.
fn color_rows(d: &Draft) -> Vec<String> {
    let dd = compute(d);
    (0..dd.picks)
        .map(|p| {
            (0..dd.ends)
                .map(|e| match dd.cell(e, p) {
                    Cell::WarpUp(c) | Cell::WeftUp(c) if c == DARK_COLOR => 'D',
                    _ => '.',
                })
                .collect()
        })
        .collect()
}

fn line_char(l: Lines) -> char {
    match l {
        Lines::Horizontal => 'H',
        Lines::Vertical => 'V',
        Lines::Uniform => '=',
        Lines::Mixed => '?',
    }
}

/// Order of runs starting with the one that covers thread 0 (so a run wrapping the repeat join
/// reads as one, first).
fn from_zero(runs: &[Run], total: usize) -> Vec<usize> {
    let k = runs
        .iter()
        .position(|r| (r.start..r.start + r.len).any(|i| i % total == 0))
        .unwrap();
    (k..runs.len()).chain(0..k).collect()
}

/// The H/V map as the worked examples print it: the warp runs, then one row per weft run. Each run
/// is labelled by the block of its first thread, read through that thread's actual color (so with
/// swapped weft colors the weft rows are relabelled, as the examples show).
fn hv_table(d: &Draft, system: ShadowSystem, shafts: ShadowShafts) -> Vec<String> {
    let regions = check::block_regions(d, true);
    let threading = shafts_of(d);
    let treadling = treadles_of(d);
    let label = |shaft: u16, color: ColorIndex, len: usize| {
        let dark = if color == DARK_COLOR {
            shaft
        } else {
            partner(system, shafts, shaft)
        };
        format!("{}{}", block_letter(block_of(system, shafts, dark)), len)
    };
    let warp = from_zero(&regions.warp_runs, d.ends());
    let weft = from_zero(&regions.weft_runs, d.picks());
    let mut out = vec![warp
        .iter()
        .map(|&k| {
            let r = regions.warp_runs[k];
            label(threading[r.start], d.colors.warp[r.start], r.len)
        })
        .collect::<Vec<_>>()
        .join(" ")];
    for &w in &weft {
        let r = regions.weft_runs[w];
        let row: String = warp
            .iter()
            .map(|&k| line_char(regions.lines[w][k]))
            .collect();
        out.push(format!(
            "{} {}",
            label(treadling[r.start], d.colors.weft[r.start], r.len),
            row
        ));
    }
    out
}

/// The H/V map over the DESIGN's blocks: runs come from the threading and treadling read through
/// the system's partners (not from the cloth), labelled like [`hv_table`].
fn design_hv_table(d: &Draft, system: ShadowSystem, shafts: ShadowShafts) -> Vec<String> {
    let runs = |ids: &[u16], colors: &[ColorIndex]| -> Vec<(u16, Vec<usize>)> {
        let mut out: Vec<(u16, Vec<usize>)> = Vec::new();
        for (i, (&id, &c)) in ids.iter().zip(colors).enumerate() {
            let dark = if c == DARK_COLOR {
                id
            } else {
                partner(system, shafts, id)
            };
            let block = block_of(system, shafts, dark);
            match out.last_mut() {
                Some((b, members)) if *b == block => members.push(i),
                _ => out.push((block, vec![i])),
            }
        }
        out
    };
    let shown = color_rows(d);
    let at = |e: usize, p: usize| shown[p].as_bytes()[e];
    let warp = runs(&shafts_of(d), &d.colors.warp);
    let weft = runs(&treadles_of(d), &d.colors.weft);
    let mut out = vec![warp
        .iter()
        .map(|(b, m)| format!("{}{}", block_letter(*b), m.len()))
        .collect::<Vec<_>>()
        .join(" ")];
    for (wb, ps) in &weft {
        let row: String = warp
            .iter()
            .map(|(_, es)| {
                let rows = ps
                    .iter()
                    .all(|&p| es.iter().all(|&e| at(e, p) == at(es[0], p)));
                let cols = es
                    .iter()
                    .all(|&e| ps.iter().all(|&p| at(e, p) == at(e, ps[0])));
                match (rows, cols) {
                    (true, false) => 'H',
                    (false, true) => 'V',
                    (true, true) => '=',
                    (false, false) => '?',
                }
            })
            .collect();
        out.push(format!("{}{} {}", block_letter(*wb), ps.len(), row));
    }
    out
}

/// **T7.** Every region shows the lines the oracle predicts for its warp and weft blocks. Blocks
/// are read structurally here: a run's first thread, taken as dark on an even position.
fn assert_oracle(d: &Draft, p: &ShadowParams) {
    let regions = check::block_regions(d, true);
    let threading = shafts_of(d);
    let treadling = treadles_of(d);
    let block = |id: u16, index: usize| {
        let dark = if index.is_multiple_of(2) {
            id
        } else {
            partner(p.system, p.shafts, id)
        };
        block_of(p.system, p.shafts, dark)
    };
    for (w, wr) in regions.weft_runs.iter().enumerate() {
        for (e, er) in regions.warp_runs.iter().enumerate() {
            let want = block_lines(
                p.shafts,
                p.direction,
                p.weft_phase,
                block(threading[er.start], er.start),
                block(treadling[wr.start], wr.start),
            );
            assert_eq!(
                regions.lines[w][e], want,
                "region (warp run {e}, weft run {w}) of {p:?}"
            );
        }
    }
}

/// The partner pairing of `system` splits every lift of the draft.
fn system_pairs_split_every_lift(d: &Draft, p: &ShadowParams) -> bool {
    (0..d.picks()).all(|pick| {
        let raised: Vec<u16> = d.raised_shafts(pick).iter().map(|s| s.0).collect();
        (1..=p.shafts.count())
            .all(|s| raised.contains(&s) != raised.contains(&partner(p.system, p.shafts, s)))
    })
}

fn other(system: ShadowSystem) -> ShadowSystem {
    match system {
        Atwater => Powell,
        Powell => Atwater,
    }
}

// ---------------------------------------------------------------------------------------------
// Worked examples (original, generated by the rules; every one reproduced exactly)
// ---------------------------------------------------------------------------------------------

#[test]
fn aw1_atwater_4_shaft_straight_repeat() {
    let p = one_repeat(Atwater, Four, Repeat, "A2 B2 C2 D2");
    let d = generate(&p).unwrap();
    assert_eq!((d.ends(), d.picks(), d.shafts, d.treadles), (16, 16, 4, 4));
    assert_eq!(d.shed, ShedType::Rising);
    assert_eq!(
        tieup_rows(&d),
        vec![vec![1, 2], vec![2, 3], vec![3, 4], vec![1, 4]]
    );
    let threading = nums("1 3 1 3 2 4 2 4 3 1 3 1 4 2 4 2");
    assert_eq!(shafts_of(&d), threading);
    assert_eq!(treadles_of(&d), threading, "treadled as drawn in");
    assert_eq!(roles(&d.colors.warp), alternating(16, true));
    assert_eq!(roles(&d.colors.weft), alternating(16, true));
    assert_eq!(matrix(&d), AW1_MATRIX);
    assert_eq!(color_rows(&d), AW1_COLORS);
    assert_eq!(hv_table(&d, Atwater, Four), AW1_MAP);
    assert!(check::report(&d, true).is_shadow_weave());
    assert_oracle(&d, &p);
}

/// Swapping the weft colors keeps the interlacement and exchanges H and V everywhere: block edges
/// go from smooth to feathery.
#[test]
fn aw1_with_swapped_weft_colors() {
    let p = ShadowParams {
        weft_phase: WeftPhase::Swapped,
        ..one_repeat(Atwater, Four, Repeat, "A2 B2 C2 D2")
    };
    let d = generate(&p).unwrap();
    assert_eq!(roles(&d.colors.warp), alternating(16, true));
    assert_eq!(roles(&d.colors.weft), alternating(16, false));
    assert_eq!(matrix(&d), AW1_MATRIX, "the interlacement is unchanged");
    assert_eq!(color_rows(&d), AW1_SWAPPED_COLORS);
    assert_eq!(hv_table(&d, Atwater, Four), AW1_SWAPPED_MAP);
    assert!(check::report(&d, true).is_shadow_weave());
    assert_oracle(&d, &p);

    // Read structurally (by position, not color), every region trades H for V.
    let standard = check::block_regions(
        &generate(&one_repeat(Atwater, Four, Repeat, "A2 B2 C2 D2")).unwrap(),
        true,
    );
    let swapped = check::block_regions(&d, true);
    assert_eq!(standard.warp_runs, swapped.warp_runs);
    assert_eq!(standard.weft_runs, swapped.weft_runs);
    for (a, b) in standard
        .lines
        .iter()
        .flatten()
        .zip(swapped.lines.iter().flatten())
    {
        let flipped = match a {
            Lines::Horizontal => Lines::Vertical,
            Lines::Vertical => Lines::Horizontal,
            other => *other,
        };
        assert_eq!(*b, flipped);
    }
}

#[test]
fn aw2_atwater_4_shaft_point() {
    let p = one_repeat(Atwater, Four, Point, "A2 B1 C1 D2");
    let d = generate(&p).unwrap();
    assert_eq!((d.ends(), d.picks()), (22, 22), "period 4W - 2 = 22");
    let threading = nums("1 3 1 3 2 4 3 1 4 2 4 2 4 2 4 1 3 4 2 3 1 3");
    assert_eq!(shafts_of(&d), threading);
    assert_eq!(treadles_of(&d), threading);
    assert_eq!(roles(&d.colors.warp), alternating(22, true));
    assert_eq!(roles(&d.colors.weft), alternating(22, true));
    assert_eq!(matrix(&d), AW2_MATRIX);
    assert_eq!(color_rows(&d), AW2_COLORS);
    assert_eq!(hv_table(&d, Atwater, Four), AW2_MAP);
    assert!(check::report(&d, true).is_shadow_weave());
    assert_oracle(&d, &p);

    // Balanced: end 1 (dark, shaft 1) and pick 1 (dark, treadle 1) once more at the very end.
    let balanced = generate(&ShadowParams {
        balance: true,
        ..p.clone()
    })
    .unwrap();
    assert_eq!((balanced.ends(), balanced.picks()), (23, 23));
    let mut want = threading.clone();
    want.push(1);
    assert_eq!(shafts_of(&balanced), want);
    assert_eq!(treadles_of(&balanced), want);
    assert_eq!(roles(&balanced.colors.warp), alternating(23, true));
    assert!(check::report(&balanced, false).is_shadow_weave());
}

#[test]
fn aw3_atwater_8_shaft_straight_twill_turned_shadow() {
    let p = one_repeat(Atwater, Eight, Repeat, "A1 B1 C1 D1 E1 F1 G1 H1");
    let d = generate(&p).unwrap();
    assert_eq!((d.ends(), d.picks(), d.shafts, d.treadles), (16, 16, 8, 8));
    assert_eq!(
        tieup_rows(&d),
        vec![
            vec![1, 2, 3, 4],
            vec![2, 3, 4, 5],
            vec![3, 4, 5, 6],
            vec![4, 5, 6, 7],
            vec![5, 6, 7, 8],
            vec![1, 6, 7, 8],
            vec![1, 2, 7, 8],
            vec![1, 2, 3, 8],
        ]
    );
    let threading = nums("1 5 2 6 3 7 4 8 5 1 6 2 7 3 8 4");
    assert_eq!(shafts_of(&d), threading);
    assert_eq!(treadles_of(&d), threading);
    assert_eq!(matrix(&d), AW3_MATRIX);
    assert_eq!(color_rows(&d), AW3_COLORS);
    assert_eq!(hv_table(&d, Atwater, Eight), AW3_MAP);
    assert!(check::report(&d, true).is_shadow_weave());
    assert_oracle(&d, &p);
}

#[test]
fn pw1_powell_4_shaft_is_the_renumbered_aw1() {
    let p = one_repeat(Powell, Four, Repeat, "A2 B2 C2 D2");
    let d = generate(&p).unwrap();
    assert_eq!(
        tieup_rows(&d),
        vec![vec![1, 3], vec![2, 4], vec![2, 3], vec![1, 4]]
    );
    let threading = nums("1 2 1 2 3 4 3 4 2 1 2 1 4 3 4 3");
    assert_eq!(shafts_of(&d), threading);
    assert_eq!(treadles_of(&d), threading);
    assert_eq!(matrix(&d), PW1_MATRIX);
    assert_eq!(PW1_MATRIX, AW1_MATRIX);
    assert_eq!(color_rows(&d), AW1_COLORS);
    assert_eq!(hv_table(&d, Powell, Four), AW1_MAP);

    // Threading and treadling are AW-1's, renumbered (exchange 2 and 3).
    let aw1 = generate(&one_repeat(Atwater, Four, Repeat, "A2 B2 C2 D2")).unwrap();
    let renumbered: Vec<u16> = shafts_of(&aw1)
        .iter()
        .map(|&s| atwater_to_powell(Four, s))
        .collect();
    assert_eq!(shafts_of(&d), renumbered);
    assert_eq!(treadles_of(&d), renumbered);
    assert_eq!(compute(&d), compute(&aw1), "identical cloth, cell for cell");
    assert!(check::report(&d, true).is_shadow_weave());
    assert_oracle(&d, &p);
}

#[test]
fn pw2_powell_8_shaft_point() {
    let p = one_repeat(Powell, Eight, Point, "A1 B1 C1 D1 E1 F1 G1 H1");
    let d = generate(&p).unwrap();
    assert_eq!((d.ends(), d.picks(), d.shafts, d.treadles), (30, 30, 8, 8));
    assert_eq!(
        tieup_rows(&d),
        vec![
            vec![1, 3, 5, 7],
            vec![2, 4, 6, 8],
            vec![2, 3, 5, 7],
            vec![1, 4, 6, 8],
            vec![2, 4, 5, 7],
            vec![1, 3, 6, 8],
            vec![2, 4, 6, 7],
            vec![1, 3, 5, 8],
        ]
    );
    let threading = nums("1 2 3 4 5 6 7 8 2 1 4 3 6 5 8 7 8 5 6 3 4 1 2 8 7 6 5 4 3 2");
    assert_eq!(shafts_of(&d), threading);
    assert_eq!(treadles_of(&d), threading);
    assert_eq!(matrix(&d), PW2_MATRIX);
    assert_eq!(color_rows(&d), PW2_COLORS);
    assert_eq!(hv_table(&d, Powell, Eight), PW2_MAP);
    assert!(check::report(&d, true).is_shadow_weave());
    assert_oracle(&d, &p);

    // Its Atwater preimage weaves identical cloth.
    let atwater = generate(&ShadowParams {
        system: Atwater,
        ..p.clone()
    })
    .unwrap();
    assert_eq!(
        shafts_of(&atwater),
        nums("1 5 2 6 3 7 4 8 5 1 6 2 7 3 8 4 8 3 7 2 6 1 5 8 4 7 3 6 2 5")
    );
    assert_eq!(compute(&atwater), compute(&d));
}

/// PW-3 weaves the weft to its own profile (A3 C3, a same-pair change), which the generator does not
/// offer yet; the draft is built from the engine's own expansion and tie-up, as a future independent
/// treadling would be.
#[test]
fn pw3_powell_independent_weft_from_the_engine_rules() {
    let warp = expand(Powell, Four, Repeat, &seq("A3 B3 C3 D3")).unwrap();
    let weft = expand(Powell, Four, Repeat, &seq("A3 C3")).unwrap();
    let color = |r: Role| match r {
        Role::Dark => DARK_COLOR,
        Role::Light => LIGHT_COLOR,
    };
    let d = Draft {
        name: "PW-3".into(),
        shafts: 4,
        treadles: 4,
        shed: ShedType::Rising,
        unit: ply_common::Unit::Inches,
        threading: Threading(warp.iter().map(|t| vec![ShaftId(t.shaft)]).collect()),
        drive: Drive::Treadled {
            tieup: tieup(Powell, Four, TwillDirection::Forward),
            treadling: Treadling(weft.iter().map(|t| vec![TreadleId(t.shaft)]).collect()),
        },
        colors: ColorPlan {
            palette: vec![
                ply_common::Color::rgb(219, 219, 219),
                ply_common::Color::rgb(45, 45, 45),
            ],
            warp: warp.iter().map(|t| color(t.role)).collect(),
            weft: weft.iter().map(|t| color(t.role)).collect(),
        },
        warp_thickness: Vec::new(),
        weft_thickness: Vec::new(),
        notes: String::new(),
        retained: Vec::new(),
        pick_roles: Vec::new(),
    };
    assert_eq!(
        shafts_of(&d),
        nums("1 2 1 2 1 2 3 4 3 4 3 4 2 1 2 1 2 1 4 3 4 3 4 3")
    );
    assert_eq!(treadles_of(&d), nums("1 2 1 2 1 2 2 1 2 1 2 1"));
    assert_eq!(matrix(&d), PW3_MATRIX);
    assert_eq!(color_rows(&d), PW3_COLORS);
    assert_eq!(design_hv_table(&d, Powell, Four), PW3_MAP);
    // This weft only ever uses the plain-weave treadle pair, so blocks A and B (and C and D)
    // interlace identically: read from the cloth alone they are one region each.
    assert_eq!(hv_table(&d, Powell, Four), ["A12 C12", "A6 HV", "C6 VH"]);
    let r = check::report(&d, true);
    assert!(r.is_shadow_weave(), "{r:?}");
    assert!(r.floats_ok(), "the same-pair change keeps floats at 2");
}

// ---------------------------------------------------------------------------------------------
// Properties over many designs
// ---------------------------------------------------------------------------------------------

fn arb_params() -> impl Strategy<Value = ShadowParams> {
    (
        prop_oneof![Just(Atwater), Just(Powell)],
        prop_oneof![Just(Four), Just(Eight)],
        prop_oneof![Just(Repeat), Just(Point)],
        prop_oneof![Just(TwillDirection::Forward), Just(TwillDirection::Reverse)],
        prop_oneof![Just(WeftPhase::Standard), Just(WeftPhase::Swapped)],
        prop::collection::vec((0u16..8, 1u16..=3), 1..=6),
    )
        .prop_map(
            |(system, shafts, layout, direction, weft_phase, entries)| ShadowParams {
                system,
                shafts,
                layout,
                blocks: entries
                    .into_iter()
                    .map(|(b, units)| ShadowBlock {
                        block: b % shafts.blocks(),
                        units,
                    })
                    .collect(),
                direction,
                weft_phase,
                warp_repeats: 1,
                weft_repeats: 1,
                balance: false,
            },
        )
        .prop_filter("needs two different blocks", |p| p.validate().is_ok())
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(400))]

    /// T1 to T7 hold for every design, measured across the repeat join; the other system weaves the
    /// identical cloth (T8); a sinking-shed loom weaves it too.
    #[test]
    fn every_generated_design_is_authentic_shadow_weave(p in arb_params()) {
        let d = generate(&p).unwrap();
        let r = check::report(&d, true);
        prop_assert!(r.is_shadow_weave(), "{:?} -> {:?}", p, r);
        prop_assert!(r.partners.is_some());
        prop_assert!(system_pairs_split_every_lift(&d, &p));
        assert_oracle(&d, &p);

        // T8: same design in the other system, identical cloth, renumbered threading.
        let q = ShadowParams { system: other(p.system), ..p.clone() };
        let e = generate(&q).unwrap();
        prop_assert_eq!(compute(&d), compute(&e));
        let (atw, pow) = if p.system == Atwater { (&d, &e) } else { (&e, &d) };
        let renumbered: Vec<u16> =
            shafts_of(atw).iter().map(|&s| atwater_to_powell(p.shafts, s)).collect();
        prop_assert_eq!(shafts_of(pow), renumbered);

        // Several repeats still pass across the join, and so does a sinking shed.
        let tiled = generate(&ShadowParams { warp_repeats: 2, weft_repeats: 3, ..p.clone() }).unwrap();
        prop_assert!(check::report(&tiled, true).is_shadow_weave());
        let sinking = d.with_shed(ShedType::Sinking);
        prop_assert_eq!(compute(&sinking), compute(&d));
        prop_assert_eq!(check::report(&sinking, true), r);

        // Balanced pieces: a point closes as a mirror and passes as a finished piece; a straight
        // repeat ends on one extra thread, so only its edge thread may lack a partner.
        let balanced = generate(&ShadowParams { balance: true, warp_repeats: 2, ..p.clone() }).unwrap();
        let b = check::report(&balanced, false);
        prop_assert!(b.warp_alternates && b.weft_alternates && b.floats_ok(), "{:?}", b);
        if p.layout == Point {
            prop_assert!(b.is_shadow_weave(), "{:?} -> {:?}", p, b);
        }
        let (long, short) = (shafts_of(&balanced), shafts_of(&d));
        prop_assert_eq!(&long[..short.len()], &short[..]);
        prop_assert_eq!(long.last(), short.first());
    }

    /// The generator is deterministic: identical parameters write byte-identical WIF.
    #[test]
    fn identical_parameters_give_identical_wif(p in arb_params()) {
        prop_assert_eq!(wif::write(&generate(&p).unwrap()), wif::write(&generate(&p).unwrap()));
    }
}

#[test]
fn the_default_design_passes_as_a_finished_piece() {
    let d = generate(&ShadowParams::default()).unwrap();
    assert_eq!((d.ends(), d.picks()), (61, 61));
    let r = check::report(&d, false);
    assert!(r.is_shadow_weave(), "{r:?}");
    assert!(ply_weave::validate::validate(&d).is_empty());
}

#[test]
fn reversing_the_twill_turns_the_block_diagonal() {
    let forward = generate(&one_repeat(Atwater, Four, Repeat, "A2 B2 C2 D2")).unwrap();
    let reverse = generate(&ShadowParams {
        direction: TwillDirection::Reverse,
        ..one_repeat(Atwater, Four, Repeat, "A2 B2 C2 D2")
    })
    .unwrap();
    assert_eq!(hv_table(&forward, Atwater, Four)[1], "A4 HHVV");
    assert_eq!(hv_table(&reverse, Atwater, Four)[1], "A4 HVVH");
    assert!(check::report(&reverse, true).is_shadow_weave());
}

// ---------------------------------------------------------------------------------------------
// Look-alikes that must not pass as shadow weave
// ---------------------------------------------------------------------------------------------

/// The generator Ply used to label "shadow weave": a straight draw on plain weave (2 shafts) or a
/// 2/2 twill (4 shafts), with a 1:1 light/dark order whose phase flips every `block` threads. That
/// is log cabin. Rebuilt here only as a negative example.
fn legacy_log_cabin(ends: usize, picks: usize, twill: bool, block: usize) -> Draft {
    let shafts: u16 = if twill { 4 } else { 2 };
    let period = if twill { 4 } else { 2 };
    let phase = |i: usize| -> ColorIndex { (i + ((i / block) % 2)) % 2 };
    Draft {
        name: "log cabin".into(),
        shafts,
        treadles: period as u16,
        shed: ShedType::Rising,
        unit: ply_common::Unit::Inches,
        threading: Threading::straight(ends, shafts),
        drive: Drive::Treadled {
            tieup: if twill {
                TieUp::twill(2, 2)
            } else {
                TieUp::plain(2)
            },
            treadling: Treadling(
                (0..picks)
                    .map(|p| vec![TreadleId((p % period) as u16 + 1)])
                    .collect(),
            ),
        },
        colors: ColorPlan {
            palette: vec![
                ply_common::Color::rgb(219, 219, 219),
                ply_common::Color::rgb(45, 45, 45),
            ],
            warp: (0..ends).map(phase).collect(),
            weft: (0..picks).map(phase).collect(),
        },
        warp_thickness: Vec::new(),
        weft_thickness: Vec::new(),
        notes: String::new(),
        retained: Vec::new(),
        pick_roles: Vec::new(),
    }
}

#[test]
fn log_cabin_on_plain_weave_is_rejected() {
    let d = legacy_log_cabin(16, 16, false, 4);
    assert_eq!(roles(&d.colors.warp), "LDLDDLDLLDLDDLDL");
    let r = check::report(&d, true);
    assert!(
        !r.warp_alternates && !r.weft_alternates,
        "T1: two like colors touch"
    );
    assert_eq!(r.partners, None, "T2: two shafts cannot pair up");
    assert_eq!(
        (r.floats.weft, r.floats.warp),
        (1, 1),
        "T4: pure plain weave"
    );
    assert!(!r.floats_ok());
    assert!(
        !r.lines_from_structure,
        "T6: normalized colors show one direction only"
    );
    assert!(!r.is_shadow_weave());
}

#[test]
fn log_cabin_on_a_twill_ground_is_rejected() {
    let d = legacy_log_cabin(16, 16, true, 4);
    let r = check::report(&d, true);
    assert!(!r.warp_alternates && !r.weft_alternates, "T1");
    assert_eq!(
        r.partners,
        Some(vec![3, 4, 1, 2]),
        "T2 passes: a 2/2 twill splits 1-3 and 2-4"
    );
    assert!(
        !r.ends_beside_partner,
        "T3: shaft 1 never sits beside shaft 3"
    );
    assert!(!r.regions_plain, "T5: no plain-weave block regions");
    assert!(!r.is_shadow_weave());
}

/// A 1:1 color-and-weave on an ordinary 2/2 twill keeps the alternation (T1) and splits the pairs
/// (T2), but no end lies beside its partner.
#[test]
fn one_and_one_color_and_weave_on_a_twill_is_rejected() {
    let mut d = legacy_log_cabin(16, 16, true, 4);
    d.colors.warp = (0..16).map(|i| 1 - i % 2).collect();
    d.colors.weft = (0..16).map(|i| 1 - i % 2).collect();
    let r = check::report(&d, true);
    assert!(r.warp_alternates && r.weft_alternates);
    assert!(r.partners.is_some());
    assert!(!r.ends_beside_partner && !r.picks_beside_shadow, "T3 fails");
    assert!(!r.is_shadow_weave());
}

/// Dropping a shadow at a point turn (one published variant) leaves three-thread skips; the point
/// layout keeps each turning block's partner instead, and floats stay at two.
#[test]
fn a_dropped_shadow_at_the_turn_makes_three_thread_floats() {
    // The point twill 1 2 3 4 3 2 as units, with the shadow of each peak dropped: ... D3 L1 D4 L1 D3 ...
    let dropped = nums("1 3 2 4 3 1 4 1 3 4 2 3");
    let mut d = generate(&one_repeat(Atwater, Four, Repeat, "A1 B1 C1 D1")).unwrap();
    d.threading = Threading(dropped.iter().map(|&s| vec![ShaftId(s)]).collect());
    d.drive = Drive::Treadled {
        tieup: tieup(Atwater, Four, TwillDirection::Forward),
        treadling: Treadling(dropped.iter().map(|&t| vec![TreadleId(t)]).collect()),
    };
    let alternate: Vec<ColorIndex> = (0..dropped.len())
        .map(|i| if i % 2 == 0 { DARK_COLOR } else { LIGHT_COLOR })
        .collect();
    d.colors.warp = alternate.clone();
    d.colors.weft = alternate;
    let floats = check::longest_floats(&d, true);
    assert_eq!(floats.weft.max(floats.warp), 3);
    assert!(!check::report(&d, true).is_shadow_weave());

    let kept = generate(&one_repeat(Atwater, Four, Point, "A1 B1 C1 D1")).unwrap();
    assert_eq!(shafts_of(&kept), nums("1 3 2 4 3 1 4 2 4 1 3 4 2 3"));
    let kept_floats = check::longest_floats(&kept, true);
    assert_eq!(kept_floats.weft.max(kept_floats.warp), 2);
}

// ---------------------------------------------------------------------------------------------
// WIF and fixtures
// ---------------------------------------------------------------------------------------------

#[test]
fn wif_round_trip_keeps_the_draft_matrix_and_colors() {
    for p in [
        ShadowParams::default(),
        one_repeat(Powell, Eight, Point, "A1 B1 C1 D1 E1 F1 G1 H1"),
        ShadowParams {
            weft_phase: WeftPhase::Swapped,
            direction: TwillDirection::Reverse,
            ..one_repeat(Atwater, Four, Repeat, "A2 B2 C2 D2")
        },
    ] {
        let d = generate(&p).unwrap();
        let back = wif::parse(&wif::write(&d)).unwrap();
        assert_eq!(back, d, "{p:?}");
        assert_eq!(matrix(&back), matrix(&d));
        assert_eq!(color_rows(&back), color_rows(&d));
    }
    // Atwater and Powell files of the same design parse to identical cloth.
    let a = generate(&one_repeat(Atwater, Eight, Point, "A2 C1 F3 H1")).unwrap();
    let b = generate(&one_repeat(Powell, Eight, Point, "A2 C1 F3 H1")).unwrap();
    assert_ne!(wif::write(&a), wif::write(&b));
    assert_eq!(
        compute(&wif::parse(&wif::write(&a)).unwrap()),
        compute(&wif::parse(&wif::write(&b)).unwrap())
    );
}

const FIXTURES: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../fixtures/weaving/shadow");

fn fixture(name: &str, ext: &str) -> String {
    let path = format!("{FIXTURES}/{name}.{ext}");
    std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{path}: {e}"))
}

fn json_strings(v: &serde_json::Value) -> Vec<String> {
    v.as_array()
        .unwrap()
        .iter()
        .map(|s| s.as_str().unwrap().to_string())
        .collect()
}

fn json_nums(v: &serde_json::Value) -> Vec<u16> {
    v.as_array()
        .unwrap()
        .iter()
        .map(|n| n.as_u64().unwrap() as u16)
        .collect()
}

/// Rebuild the generator parameters a fixture records.
fn fixture_params(g: &serde_json::Value) -> ShadowParams {
    let text = |k: &str| g[k].as_str().unwrap();
    ShadowParams {
        system: match text("system") {
            "atwater" => Atwater,
            "powell" => Powell,
            other => panic!("system {other}"),
        },
        shafts: ShadowShafts::try_from(g["shafts"].as_u64().unwrap() as u16).unwrap(),
        layout: match text("layout") {
            "repeat" => Repeat,
            "point" => Point,
            other => panic!("layout {other}"),
        },
        blocks: seq(text("blocks")),
        direction: match text("twill_direction") {
            "forward" => TwillDirection::Forward,
            "reverse" => TwillDirection::Reverse,
            other => panic!("direction {other}"),
        },
        weft_phase: match text("weft_phase") {
            "standard" => WeftPhase::Standard,
            "swapped" => WeftPhase::Swapped,
            other => panic!("phase {other}"),
        },
        warp_repeats: g["warp_repeats"].as_u64().unwrap() as u16,
        weft_repeats: g["weft_repeats"].as_u64().unwrap() as u16,
        balance: g["balance"].as_bool().unwrap(),
    }
}

/// Each tracked fixture loads, matches its structural oracle and the worked example it records, is
/// exactly what the generator writes for its recorded parameters, and passes every structural test.
#[test]
fn tracked_fixtures_load_and_match_their_oracles() {
    /// A fixture name and the worked example's interlacement, color drawdown and line map.
    type Case = (&'static str, Rows, Rows, Rows);
    type Rows = &'static [&'static str];
    let cases: [Case; 2] = [
        ("aw2-atwater-4-point", AW2_MATRIX, AW2_COLORS, AW2_MAP),
        ("pw2-powell-8-point", PW2_MATRIX, PW2_COLORS, PW2_MAP),
    ];
    for (name, spec_matrix, spec_colors, spec_map) in cases {
        let text = fixture(name, "wif");
        let expect: serde_json::Value =
            serde_json::from_str(&fixture(name, "expect.json")).unwrap();
        let d = wif::parse(&text).unwrap();

        assert_eq!(
            d.ends(),
            expect["ends"].as_u64().unwrap() as usize,
            "{name}"
        );
        assert_eq!(
            d.picks(),
            expect["picks"].as_u64().unwrap() as usize,
            "{name}"
        );
        assert_eq!(
            u64::from(d.shafts),
            expect["shafts"].as_u64().unwrap(),
            "{name}"
        );
        assert_eq!(
            u64::from(d.treadles),
            expect["treadles"].as_u64().unwrap(),
            "{name}"
        );
        assert_eq!(expect["shed"], "rising");
        assert_eq!(d.shed, ShedType::Rising);
        assert_eq!(shafts_of(&d), json_nums(&expect["threading"]), "{name}");
        assert_eq!(treadles_of(&d), json_nums(&expect["treadling"]), "{name}");
        let tie: Vec<Vec<u16>> = expect["tieup"]
            .as_array()
            .unwrap()
            .iter()
            .map(json_nums)
            .collect();
        assert_eq!(tieup_rows(&d), tie, "{name}");
        assert_eq!(
            roles(&d.colors.warp),
            expect["warp_roles"].as_str().unwrap(),
            "{name}"
        );
        assert_eq!(
            roles(&d.colors.weft),
            expect["weft_roles"].as_str().unwrap(),
            "{name}"
        );

        let want_matrix = json_strings(&expect["interlacement"]);
        assert_eq!(matrix(&d), want_matrix, "{name}: interlacement");
        assert_eq!(
            want_matrix, spec_matrix,
            "{name}: the oracle is the worked example"
        );
        assert_eq!(
            color_rows(&d),
            json_strings(&expect["color_drawdown"]),
            "{name}"
        );
        assert_eq!(
            json_strings(&expect["color_drawdown"]),
            spec_colors,
            "{name}"
        );

        let p = fixture_params(&expect["generator"]);
        assert_eq!(json_strings(&expect["line_map"]), spec_map, "{name}");
        assert_eq!(hv_table(&d, p.system, p.shafts), spec_map, "{name}");
        let generated = generate(&p).unwrap();
        assert_eq!(
            wif::write(&generated).replace("\r\n", "\n"),
            text.replace("\r\n", "\n"),
            "{name}: the fixture is the generator's own output"
        );
        assert_eq!(d, generated, "{name}");
        assert!(check::report(&d, true).is_shadow_weave(), "{name}");

        let meta = fixture(name, "fixture.toml");
        for key in [
            "license = \"original recreation\"",
            "automated_checks = \"pass\"",
            "practitioner_weave_check = \"pending\"",
        ] {
            assert!(meta.contains(key), "{name}.fixture.toml lacks `{key}`");
        }
    }
}

// ---------------------------------------------------------------------------------------------
// Reference matrices (original worked examples)
// ---------------------------------------------------------------------------------------------

const AW1_MATRIX: &[&str] = &[
    "X.X.X.X..X.X.X.X",
    ".X.X.X.XX.X.X.X.",
    "X.X.X.X..X.X.X.X",
    ".X.X.X.XX.X.X.X.",
    ".X.XX.X.X.X..X.X",
    "X.X..X.X.X.XX.X.",
    ".X.XX.X.X.X..X.X",
    "X.X..X.X.X.XX.X.",
    ".X.X.X.XX.X.X.X.",
    "X.X.X.X..X.X.X.X",
    ".X.X.X.XX.X.X.X.",
    "X.X.X.X..X.X.X.X",
    "X.X..X.X.X.XX.X.",
    ".X.XX.X.X.X..X.X",
    "X.X..X.X.X.XX.X.",
    ".X.XX.X.X.X..X.X",
];
const AW1_COLORS: &[&str] = &[
    "DDDDDDDDD.D.D.D.",
    "........D.D.D.D.",
    "DDDDDDDDD.D.D.D.",
    "........D.D.D.D.",
    "D.D.DDDDDDDDD.D.",
    "D.D.........D.D.",
    "D.D.DDDDDDDDD.D.",
    "D.D.........D.D.",
    "D.D.D.D.DDDDDDDD",
    "D.D.D.D.........",
    "D.D.D.D.DDDDDDDD",
    "D.D.D.D.........",
    "DDDDD.D.D.D.DDDD",
    "....D.D.D.D.....",
    "DDDDD.D.D.D.DDDD",
    "....D.D.D.D.....",
];
const AW1_MAP: &[&str] = &["A4 B4 C4 D4", "A4 HHVV", "B4 VHHV", "C4 VVHH", "D4 HVVH"];
const AW1_SWAPPED_COLORS: &[&str] = &[
    "D.D.D.D.........",
    "D.D.D.D.DDDDDDDD",
    "D.D.D.D.........",
    "D.D.D.D.DDDDDDDD",
    "....D.D.D.D.....",
    "DDDDD.D.D.D.DDDD",
    "....D.D.D.D.....",
    "DDDDD.D.D.D.DDDD",
    "........D.D.D.D.",
    "DDDDDDDDD.D.D.D.",
    "........D.D.D.D.",
    "DDDDDDDDD.D.D.D.",
    "D.D.........D.D.",
    "D.D.DDDDDDDDD.D.",
    "D.D.........D.D.",
    "D.D.DDDDDDDDD.D.",
];
const AW1_SWAPPED_MAP: &[&str] = &["A4 B4 C4 D4", "C4 VVHH", "D4 HVVH", "A4 HHVV", "B4 VHHV"];
const AW2_MATRIX: &[&str] = &[
    "X.X.X..X.X.X.X.X..X.X.",
    ".X.X.XX.X.X.X.X.XX.X.X",
    "X.X.X..X.X.X.X.X..X.X.",
    ".X.X.XX.X.X.X.X.XX.X.X",
    ".X.XX.X..X.X.X..X.XX.X",
    "X.X..X.XX.X.X.XX.X..X.",
    ".X.X.XX.X.X.X.X.XX.X.X",
    "X.X.X..X.X.X.X.X..X.X.",
    "X.X..X.XX.X.X.XX.X..X.",
    ".X.XX.X..X.X.X..X.XX.X",
    "X.X..X.XX.X.X.XX.X..X.",
    ".X.XX.X..X.X.X..X.XX.X",
    "X.X..X.XX.X.X.XX.X..X.",
    ".X.XX.X..X.X.X..X.XX.X",
    "X.X..X.XX.X.X.XX.X..X.",
    "X.X.X..X.X.X.X.X..X.X.",
    ".X.X.XX.X.X.X.X.XX.X.X",
    "X.X..X.XX.X.X.XX.X..X.",
    ".X.XX.X..X.X.X..X.XX.X",
    ".X.X.XX.X.X.X.X.XX.X.X",
    "X.X.X..X.X.X.X.X..X.X.",
    ".X.X.XX.X.X.X.X.XX.X.X",
];
const AW2_COLORS: &[&str] = &[
    "DDDDDDD.D.D.D.D.DDDDDD",
    "......D.D.D.D.D.D.....",
    "DDDDDDD.D.D.D.D.DDDDDD",
    "......D.D.D.D.D.D.....",
    "D.D.DDDDD.D.D.DDDDD.D.",
    "D.D.....D.D.D.D.....D.",
    "D.D.D.DDDDDDDDDDD.D.D.",
    "D.D.D.............D.D.",
    "DDDDD.D.DDDDDDD.D.DDDD",
    "....D.D.........D.D...",
    "DDDDD.D.DDDDDDD.D.DDDD",
    "....D.D.........D.D...",
    "DDDDD.D.DDDDDDD.D.DDDD",
    "....D.D.........D.D...",
    "DDDDD.D.DDDDDDD.D.DDDD",
    "D.D.D.............D.D.",
    "D.D.D.DDDDDDDDDDD.D.D.",
    "D.D.....D.D.D.D.....D.",
    "D.D.DDDDD.D.D.DDDDD.D.",
    "......D.D.D.D.D.D.....",
    "DDDDDDD.D.D.D.D.DDDDDD",
    "......D.D.D.D.D.D.....",
];
const AW2_MAP: &[&str] = &[
    "A7 B2 C2 D7 C2 B2",
    "A7 HHVVVH",
    "B2 VHHVHH",
    "C2 VVHHHV",
    "D7 HVVHVV",
    "C2 VVHHHV",
    "B2 VHHVHH",
];
const AW3_MATRIX: &[&str] = &[
    "X.X.X.X..X.X.X.X",
    ".X.X.X.XX.X.X.X.",
    ".XX.X.X.X..X.X.X",
    "X..X.X.X.XX.X.X.",
    ".X.XX.X.X.X..X.X",
    "X.X..X.X.X.XX.X.",
    ".X.X.XX.X.X.X..X",
    "X.X.X..X.X.X.XX.",
    ".X.X.X.XX.X.X.X.",
    "X.X.X.X..X.X.X.X",
    "X..X.X.X.XX.X.X.",
    ".XX.X.X.X..X.X.X",
    "X.X..X.X.X.XX.X.",
    ".X.XX.X.X.X..X.X",
    "X.X.X..X.X.X.XX.",
    ".X.X.XX.X.X.X..X",
];
const AW3_COLORS: &[&str] = &[
    "DDDDDDDDD.D.D.D.",
    "........D.D.D.D.",
    "D.DDDDDDDDD.D.D.",
    "D.........D.D.D.",
    "D.D.DDDDDDDDD.D.",
    "D.D.........D.D.",
    "D.D.D.DDDDDDDDD.",
    "D.D.D.........D.",
    "D.D.D.D.DDDDDDDD",
    "D.D.D.D.........",
    "DDD.D.D.D.DDDDDD",
    "..D.D.D.D.......",
    "DDDDD.D.D.D.DDDD",
    "....D.D.D.D.....",
    "DDDDDDD.D.D.D.DD",
    "......D.D.D.D...",
];
const AW3_MAP: &[&str] = &[
    "A2 B2 C2 D2 E2 F2 G2 H2",
    "A2 HHHHVVVV",
    "B2 VHHHHVVV",
    "C2 VVHHHHVV",
    "D2 VVVHHHHV",
    "E2 VVVVHHHH",
    "F2 HVVVVHHH",
    "G2 HHVVVVHH",
    "H2 HHHVVVVH",
];
const PW1_MATRIX: &[&str] = &[
    "X.X.X.X..X.X.X.X",
    ".X.X.X.XX.X.X.X.",
    "X.X.X.X..X.X.X.X",
    ".X.X.X.XX.X.X.X.",
    ".X.XX.X.X.X..X.X",
    "X.X..X.X.X.XX.X.",
    ".X.XX.X.X.X..X.X",
    "X.X..X.X.X.XX.X.",
    ".X.X.X.XX.X.X.X.",
    "X.X.X.X..X.X.X.X",
    ".X.X.X.XX.X.X.X.",
    "X.X.X.X..X.X.X.X",
    "X.X..X.X.X.XX.X.",
    ".X.XX.X.X.X..X.X",
    "X.X..X.X.X.XX.X.",
    ".X.XX.X.X.X..X.X",
];
const PW2_MATRIX: &[&str] = &[
    "X.X.X.X..X.X.X.X.X.X.X..X.X.X.",
    ".X.X.X.XX.X.X.X.X.X.X.XX.X.X.X",
    ".XX.X.X.X..X.X.X.X.X..X.X.X.XX",
    "X..X.X.X.XX.X.X.X.X.XX.X.X.X..",
    ".X.XX.X.X.X..X.X.X..X.X.X.XX.X",
    "X.X..X.X.X.XX.X.X.XX.X.X.X..X.",
    ".X.X.XX.X.X.X..X..X.X.X.XX.X.X",
    "X.X.X..X.X.X.XX.XX.X.X.X..X.X.",
    ".X.X.X.XX.X.X.X.X.X.X.XX.X.X.X",
    "X.X.X.X..X.X.X.X.X.X.X..X.X.X.",
    "X..X.X.X.XX.X.X.X.X.XX.X.X.X..",
    ".XX.X.X.X..X.X.X.X.X..X.X.X.XX",
    "X.X..X.X.X.XX.X.X.XX.X.X.X..X.",
    ".X.XX.X.X.X..X.X.X..X.X.X.XX.X",
    "X.X.X..X.X.X.XX.XX.X.X.X..X.X.",
    ".X.X.XX.X.X.X..X..X.X.X.XX.X.X",
    "X.X.X..X.X.X.XX.XX.X.X.X..X.X.",
    ".X.XX.X.X.X..X.X.X..X.X.X.XX.X",
    "X.X..X.X.X.XX.X.X.XX.X.X.X..X.",
    ".XX.X.X.X..X.X.X.X.X..X.X.X.XX",
    "X..X.X.X.XX.X.X.X.X.XX.X.X.X..",
    "X.X.X.X..X.X.X.X.X.X.X..X.X.X.",
    ".X.X.X.XX.X.X.X.X.X.X.XX.X.X.X",
    "X.X.X..X.X.X.XX.XX.X.X.X..X.X.",
    ".X.X.XX.X.X.X..X..X.X.X.XX.X.X",
    "X.X..X.X.X.XX.X.X.XX.X.X.X..X.",
    ".X.XX.X.X.X..X.X.X..X.X.X.XX.X",
    "X..X.X.X.XX.X.X.X.X.XX.X.X.X..",
    ".XX.X.X.X..X.X.X.X.X..X.X.X.XX",
    ".X.X.X.XX.X.X.X.X.X.X.XX.X.X.X",
];
const PW2_COLORS: &[&str] = &[
    "DDDDDDDDD.D.D.D.D.D.D.DDDDDDDD",
    "........D.D.D.D.D.D.D.D.......",
    "D.DDDDDDDDD.D.D.D.D.DDDDDDDDD.",
    "D.........D.D.D.D.D.D.........",
    "D.D.DDDDDDDDD.D.D.DDDDDDDDD.D.",
    "D.D.........D.D.D.D.........D.",
    "D.D.D.DDDDDDDDD.DDDDDDDDD.D.D.",
    "D.D.D.........D.D.........D.D.",
    "D.D.D.D.DDDDDDDDDDDDDDD.D.D.D.",
    "D.D.D.D.................D.D.D.",
    "DDD.D.D.D.DDDDDDDDDDD.D.D.D.DD",
    "..D.D.D.D.............D.D.D.D.",
    "DDDDD.D.D.D.DDDDDDD.D.D.D.DDDD",
    "....D.D.D.D.........D.D.D.D...",
    "DDDDDDD.D.D.D.DDD.D.D.D.DDDDDD",
    "......D.D.D.D.....D.D.D.D.....",
    "DDDDDDD.D.D.D.DDD.D.D.D.DDDDDD",
    "....D.D.D.D.........D.D.D.D...",
    "DDDDD.D.D.D.DDDDDDD.D.D.D.DDDD",
    "..D.D.D.D.............D.D.D.D.",
    "DDD.D.D.D.DDDDDDDDDDD.D.D.D.DD",
    "D.D.D.D.................D.D.D.",
    "D.D.D.D.DDDDDDDDDDDDDDD.D.D.D.",
    "D.D.D.........D.D.........D.D.",
    "D.D.D.DDDDDDDDD.DDDDDDDDD.D.D.",
    "D.D.........D.D.D.D.........D.",
    "D.D.DDDDDDDDD.D.D.DDDDDDDDD.D.",
    "D.........D.D.D.D.D.D.........",
    "D.DDDDDDDDD.D.D.D.D.DDDDDDDDD.",
    "........D.D.D.D.D.D.D.D.......",
];
const PW2_MAP: &[&str] = &[
    "A3 B2 C2 D2 E2 F2 G2 H3 G2 F2 E2 D2 C2 B2",
    "A3 HHHHVVVVVVVHHH",
    "B2 VHHHHVVVVVHHHH",
    "C2 VVHHHHVVVHHHHV",
    "D2 VVVHHHHVHHHHVV",
    "E2 VVVVHHHHHHHVVV",
    "F2 HVVVVHHHHHVVVV",
    "G2 HHVVVVHHHVVVVH",
    "H3 HHHVVVVHVVVVHH",
    "G2 HHVVVVHHHVVVVH",
    "F2 HVVVVHHHHHVVVV",
    "E2 VVVVHHHHHHHVVV",
    "D2 VVVHHHHVHHHHVV",
    "C2 VVHHHHVVVHHHHV",
    "B2 VHHHHVVVVVHHHH",
];
const PW3_MATRIX: &[&str] = &[
    "X.X.X.X.X.X..X.X.X.X.X.X",
    ".X.X.X.X.X.XX.X.X.X.X.X.",
    "X.X.X.X.X.X..X.X.X.X.X.X",
    ".X.X.X.X.X.XX.X.X.X.X.X.",
    "X.X.X.X.X.X..X.X.X.X.X.X",
    ".X.X.X.X.X.XX.X.X.X.X.X.",
    ".X.X.X.X.X.XX.X.X.X.X.X.",
    "X.X.X.X.X.X..X.X.X.X.X.X",
    ".X.X.X.X.X.XX.X.X.X.X.X.",
    "X.X.X.X.X.X..X.X.X.X.X.X",
    ".X.X.X.X.X.XX.X.X.X.X.X.",
    "X.X.X.X.X.X..X.X.X.X.X.X",
];
const PW3_COLORS: &[&str] = &[
    "DDDDDDDDDDDDD.D.D.D.D.D.",
    "............D.D.D.D.D.D.",
    "DDDDDDDDDDDDD.D.D.D.D.D.",
    "............D.D.D.D.D.D.",
    "DDDDDDDDDDDDD.D.D.D.D.D.",
    "............D.D.D.D.D.D.",
    "D.D.D.D.D.D.DDDDDDDDDDDD",
    "D.D.D.D.D.D.............",
    "D.D.D.D.D.D.DDDDDDDDDDDD",
    "D.D.D.D.D.D.............",
    "D.D.D.D.D.D.DDDDDDDDDDDD",
    "D.D.D.D.D.D.............",
];
const PW3_MAP: &[&str] = &["A6 B6 C6 D6", "A6 HHVV", "C6 VVHH"];
