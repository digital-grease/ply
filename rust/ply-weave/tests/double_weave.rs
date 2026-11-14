//! Double-weave construction (M8-09, ADR 0010): the derived edges against the worked examples of
//! the double-weave research note, the declared construction and its mismatch messages, the generator's
//! three constructions, the WIF round trip, and the tracked fixtures.
//!
//! The weft-path ORACLE below is independent of the engine's edge rule: it follows each shuttle's
//! passes and checks that plain weave continues across every join and that every open turn catches
//! the layer's outermost end. End 1 is at the RIGHT (as the weaver sees the loom), so the right edge's
//! outermost end of a layer is its lowest-numbered one.

use ply_weave::construction::{
    agrees_with, construction_issues, derive_edges, Construction, EdgeBehavior, MissingEdgeData,
};
use ply_weave::draft::*;
use ply_weave::drawdown::{compute, Cell};
use ply_weave::structure::double_weave;
use ply_weave::validate::{validate, Severity};
use ply_weave::wif;
use std::collections::BTreeMap;

use EdgeBehavior::{Joined, Mixed, NoTurns, Open};
use PickRole::{BottomLayer as B, TopLayer as T};
use Side::{Left, Right};

// ---------------------------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------------------------

/// The research examples' draft: straight 1-2-3-4 over `ends`, top layer on shafts 1 and 3, bottom on 2
/// and 4; tie-up 1 = {1} (top a), 2 = {1,2,3} (bottom a), 3 = {3} (top b), 4 = {1,3,4} (bottom b).
fn example(
    ends: usize,
    treadling: &[u16],
    roles: &[PickRole],
    shuttles: &[u8],
    starts: &[(u8, Side)],
) -> Draft {
    let mut d = Draft::blank(4, 4);
    d.threading = Threading::straight(ends, 4);
    d.drive = Drive::Treadled {
        tieup: TieUp(vec![
            vec![ShaftId(1)],
            vec![ShaftId(1), ShaftId(2), ShaftId(3)],
            vec![ShaftId(3)],
            vec![ShaftId(1), ShaftId(3), ShaftId(4)],
        ]),
        treadling: Treadling(treadling.iter().map(|&t| vec![TreadleId(t)]).collect()),
    };
    d.colors.warp = (0..ends).map(|i| i % 2).collect();
    d.colors.weft = vec![0; treadling.len()];
    d.pick_roles = roles.to_vec();
    d.weft_work.shuttles = shuttles.iter().map(|&s| Some(ShuttleId(s))).collect();
    d.weft_work.shuttle_starts = starts
        .iter()
        .map(|&(s, side)| (ShuttleId(s), side))
        .collect::<BTreeMap<_, _>>();
    d
}

/// `pattern` repeated over `picks`.
fn cycle<T: Copy>(pattern: &[T], picks: usize) -> Vec<T> {
    (0..picks).map(|p| pattern[p % pattern.len()]).collect()
}

fn edges(d: &Draft) -> (EdgeBehavior, EdgeBehavior) {
    let e = derive_edges(d).expect("edges derive");
    (e.left, e.right)
}

fn up(d: &Draft, end: usize, pick: usize) -> bool {
    d.threading.0[end]
        .iter()
        .any(|s| d.raised_shafts(pick).contains(s))
}

/// The layer an end of a straight 1-2-3-4 threading belongs to: odd shafts are the top layer.
fn end_on_top(d: &Draft, end: usize) -> bool {
    d.threading.0[end][0].0 % 2 == 1
}

fn outer_end(d: &Draft, top: bool, side: Side) -> usize {
    let ends: Vec<usize> = (0..d.ends()).filter(|&e| end_on_top(d, e) == top).collect();
    match side {
        Side::Right => ends[0],
        Side::Left => *ends.last().unwrap(),
    }
}

/// The independent weft-path oracle. Returns every fault found (empty = the plain weave continues
/// across every join and every open turn catches its end). It follows each shuttle on its own,
/// deriving directions by simple alternation from the starting side, not through the engine.
fn weft_path_faults(d: &Draft) -> Vec<String> {
    let top = |p: usize| d.pick_role(p) == PickRole::TopLayer;
    // On the outer face the weft shows on the top layer where the end is down, and on the bottom
    // layer (seen from below) where the end is up.
    let weft_shows = |end: usize, pick: usize| {
        if top(pick) {
            !up(d, end, pick)
        } else {
            up(d, end, pick)
        }
    };
    let mut faults = Vec::new();
    let mut by_shuttle: BTreeMap<ShuttleId, Vec<usize>> = BTreeMap::new();
    for p in 0..d.picks() {
        by_shuttle.entry(d.shuttle(p).unwrap()).or_default().push(p);
    }
    for (shuttle, picks) in by_shuttle {
        let start = d.weft_work.shuttle_starts[&shuttle];
        for (i, pair) in picks.windows(2).enumerate() {
            let (a, b) = (pair[0], pair[1]);
            // Pass i starts from `start` when i is even; it ends on the other side.
            let ended = if i % 2 == 0 { start.other() } else { start };
            if top(a) != top(b) {
                let (ea, eb) = (outer_end(d, top(a), ended), outer_end(d, top(b), ended));
                if weft_shows(ea, a) == weft_shows(eb, b) {
                    faults.push(format!("join at {ended:?} after pick {}", a + 1));
                }
            } else {
                let e = outer_end(d, top(a), ended);
                if up(d, e, a) == up(d, e, b) {
                    faults.push(format!("open turn at {ended:?} after pick {}", a + 1));
                }
            }
        }
    }
    faults
}

/// Unfold a double-width cloth with its fold on `fold` into one wide cloth: the top layer from the
/// open edge to the fold, then the bottom layer from the fold back to the open edge, one row per top
/// pick and the bottom pick joined to it at the fold. Returns the face rows (`#` = warp shows).
fn unfold(d: &Draft, fold: Side) -> Vec<String> {
    let mut top_ends: Vec<usize> = (0..d.ends()).filter(|&e| end_on_top(d, e)).collect();
    let mut bottom_ends: Vec<usize> = (0..d.ends()).filter(|&e| !end_on_top(d, e)).collect();
    match fold {
        Side::Right => top_ends.reverse(),
        Side::Left => bottom_ends.reverse(),
    }
    let e = derive_edges(d).unwrap();
    e.turns
        .iter()
        .filter(|t| t.joins && t.side == fold)
        .map(|t| {
            let (tp, bp) = if d.pick_role(t.from) == PickRole::TopLayer {
                (t.from, t.to)
            } else {
                (t.to, t.from)
            };
            let mut row: String = top_ends
                .iter()
                .map(|&e| if up(d, e, tp) { '#' } else { '.' })
                .collect();
            row.extend(
                bottom_ends
                    .iter()
                    .map(|&e| if up(d, e, bp) { '.' } else { '#' }),
            );
            row
        })
        .collect()
}

/// True when `rows` is plain weave: every row alternates, and every column alternates row to row.
fn is_plain_weave(rows: &[String]) -> bool {
    let grid: Vec<Vec<char>> = rows.iter().map(|r| r.chars().collect()).collect();
    grid.iter().all(|r| r.windows(2).all(|w| w[0] != w[1]))
        && grid
            .windows(2)
            .all(|w| w[0].iter().zip(&w[1]).all(|(a, b)| a != b))
}

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

fn warnings(d: &Draft) -> Vec<String> {
    validate(d)
        .into_iter()
        .filter(|i| i.severity == Severity::Warning)
        .map(|i| i.message)
        .collect()
}

// ---------------------------------------------------------------------------------------------
// The edge rule against the worked examples (research section 6)
// ---------------------------------------------------------------------------------------------

#[test]
fn two_independent_layers_are_open_at_both_edges_whatever_the_starting_sides() {
    for starts in [
        [(1, Right), (2, Right)],
        [(1, Right), (2, Left)],
        [(1, Left), (2, Left)],
    ] {
        let a = example(
            8,
            &cycle(&[1, 2, 3, 4], 8),
            &cycle(&[T, B], 8),
            &cycle(&[1, 2], 8),
            &starts,
        );
        assert_eq!(edges(&a), (Open, Open), "{starts:?}");
        let e = derive_edges(&a).unwrap();
        assert_eq!(e.construction(), Some(Construction::TwoLayers));
        // Each shuttle's turns are two picks apart, on its own layer.
        assert!(e.turns.iter().all(|t| t.to == t.from + 2 && !t.joins));
        assert!(weft_path_faults(&a).is_empty(), "{starts:?}");
    }
}

#[test]
fn a_tube_joins_both_edges_and_needs_an_odd_warp() {
    // Example B: one shuttle, the two-layer treadling, from the left, on an odd warp.
    for ends in [7, 9, 11, 13] {
        let b = example(
            ends,
            &cycle(&[1, 2, 3, 4], 8),
            &cycle(&[T, B], 8),
            &[1; 8],
            &[(1, Left)],
        );
        assert_eq!(edges(&b), (Joined, Joined), "{ends} ends");
        assert_eq!(
            derive_edges(&b).unwrap().construction(),
            Some(Construction::Tube)
        );
        assert!(
            weft_path_faults(&b).is_empty(),
            "{ends} ends: {:?}",
            weft_path_faults(&b)
        );
        // Example B': from the right, the bottom sheds the other way round.
        let b2 = example(
            ends,
            &cycle(&[1, 4, 3, 2], 8),
            &cycle(&[T, B], 8),
            &[1; 8],
            &[(1, Right)],
        );
        assert_eq!(edges(&b2), (Joined, Joined));
        assert!(
            weft_path_faults(&b2).is_empty(),
            "{ends} ends from the right"
        );
    }
    // An even warp is still a tube by its edges, but two ends weave alike at the starting edge.
    for (start, faulty) in [(Left, Left), (Right, Right)] {
        let x = example(
            8,
            &cycle(&[1, 2, 3, 4], 8),
            &cycle(&[T, B], 8),
            &[1; 8],
            &[(1, start)],
        );
        assert_eq!(edges(&x), (Joined, Joined));
        let faults = weft_path_faults(&x);
        assert!(!faults.is_empty() && faults.iter().all(|f| f.contains(&format!("{faulty:?}"))));
    }
}

#[test]
fn double_width_folds_on_the_edge_opposite_the_start() {
    // Example C (fold left, start right) and D (fold right, start left), T-B-B-T.
    for ends in [6usize, 8, 10] {
        let c = example(
            ends,
            &cycle(&[1, 2, 4, 3], 8),
            &cycle(&[T, B, B, T], 8),
            &[1; 8],
            &[(1, Right)],
        );
        assert_eq!(edges(&c), (Joined, Open), "{ends} ends");
        assert_eq!(
            derive_edges(&c).unwrap().construction(),
            Some(Construction::DoubleWidth { fold: Left })
        );
        assert!(weft_path_faults(&c).is_empty());
        assert!(is_plain_weave(&unfold(&c, Left)), "{ends} ends unfold");

        let d = example(
            ends,
            &cycle(&[1, 2, 4, 3], 8),
            &cycle(&[T, B, B, T], 8),
            &[1; 8],
            &[(1, Left)],
        );
        assert_eq!(edges(&d), (Open, Joined), "{ends} ends");
        assert_eq!(
            derive_edges(&d).unwrap().construction(),
            Some(Construction::DoubleWidth { fold: Right })
        );
        assert!(weft_path_faults(&d).is_empty());
        assert!(is_plain_weave(&unfold(&d, Right)));
    }
    // Example C, turn by turn (research section 6): 1 -> 2 joins on the left, 2 -> 3 open on the
    // right, 3 -> 4 joins on the left, 4 -> 5 open on the right.
    let c = example(
        8,
        &cycle(&[1, 2, 4, 3], 8),
        &cycle(&[T, B, B, T], 8),
        &[1; 8],
        &[(1, Right)],
    );
    let turns: Vec<(usize, usize, Side, bool)> = derive_edges(&c)
        .unwrap()
        .turns
        .iter()
        .take(4)
        .map(|t| (t.from + 1, t.to + 1, t.side, t.joins))
        .collect();
    assert_eq!(
        turns,
        vec![
            (1, 2, Left, true),
            (2, 3, Right, false),
            (3, 4, Left, true),
            (4, 5, Right, false)
        ]
    );
}

#[test]
fn odd_warps_need_the_bottom_sheds_ordered_for_a_left_fold() {
    // Example C-odd: on 7 or 9 ends the fold on the left continues only with 1, 4, 2, 3.
    for ends in [7usize, 9] {
        let good = example(
            ends,
            &cycle(&[1, 4, 2, 3], 8),
            &cycle(&[T, B, B, T], 8),
            &[1; 8],
            &[(1, Right)],
        );
        assert!(weft_path_faults(&good).is_empty(), "{ends}");
        assert!(is_plain_weave(&unfold(&good, Left)));
        let bad = example(
            ends,
            &cycle(&[1, 2, 4, 3], 8),
            &cycle(&[T, B, B, T], 8),
            &[1; 8],
            &[(1, Right)],
        );
        assert!(!weft_path_faults(&bad).is_empty(), "{ends}");
        assert!(!is_plain_weave(&unfold(&bad, Left)));
        // Both are double width with the fold on the left by their EDGES: continuity is a separate
        // property the edge rule does not claim.
        assert_eq!(edges(&good), edges(&bad));
    }
}

#[test]
fn starting_on_the_other_side_moves_the_fold_and_more_wefts_keep_it() {
    // Example E: the same picks from the left fold on the right.
    let e = example(
        8,
        &cycle(&[1, 2, 4, 3], 8),
        &cycle(&[T, B, B, T], 8),
        &[1; 8],
        &[(1, Left)],
    );
    assert_eq!(edges(&e), (Open, Joined));
    // Example F: a second weft (shuttle 2) works B-T-T-B from the right: the fold stays on the left.
    let f = example(
        8,
        &[1, 2, 4, 3, 2, 1, 3, 4],
        &[T, B, B, T, B, T, T, B],
        &[1, 1, 1, 1, 2, 2, 2, 2],
        &[(1, Right), (2, Right)],
    );
    assert_eq!(edges(&f), (Joined, Open));
    assert_eq!(
        derive_edges(&f).unwrap().construction(),
        Some(Construction::DoubleWidth { fold: Left }),
        "double width is defined by its edges, not by one shuttle"
    );
    assert!(is_plain_weave(&unfold(&f, Left)));
    // Example G: T-T-B-B from the left folds on the starting side.
    let g = example(
        8,
        &cycle(&[1, 3, 4, 2], 8),
        &cycle(&[T, T, B, B], 8),
        &[1; 8],
        &[(1, Left)],
    );
    assert_eq!(edges(&g), (Joined, Open));
    assert!(weft_path_faults(&g).is_empty());
    // Example H: layers woven in blocks with one shuttle join once: mixed, no construction.
    let h = example(
        8,
        &[1, 3, 1, 3, 2, 4, 2, 4],
        &[T, T, T, T, B, B, B, B],
        &[1; 8],
        &[(1, Right)],
    );
    assert_eq!(edges(&h), (Open, Mixed));
    assert_eq!(derive_edges(&h).unwrap().construction(), None);
}

#[test]
fn edges_are_unknown_when_roles_shuttles_or_sides_are_missing() {
    let full = example(
        8,
        &cycle(&[1, 2, 3, 4], 8),
        &cycle(&[T, B], 8),
        &[1; 8],
        &[(1, Left)],
    );
    assert!(derive_edges(&full).is_ok());

    let mut no_picks = full.resized(8, 0, 4, 4);
    no_picks.weft_work.shuttle_starts.clear();
    assert_eq!(derive_edges(&no_picks), Err(MissingEdgeData::NoPicks));

    let mut roles = full.clone();
    roles.pick_roles[2] = PickRole::Unknown;
    roles.pick_roles[3] = PickRole::Tabby;
    roles.pick_roles[4] = PickRole::Pattern;
    assert_eq!(
        derive_edges(&roles),
        Err(MissingEdgeData::NoLayerRole(vec![2, 3, 4]))
    );
    let mut no_roles = full.clone();
    no_roles.pick_roles.clear();
    assert!(
        matches!(derive_edges(&no_roles), Err(MissingEdgeData::NoLayerRole(p)) if p.len() == 8)
    );

    let mut shuttles = full.clone();
    shuttles.weft_work.shuttles[1] = None;
    shuttles.weft_work.shuttles[3] = None;
    assert_eq!(
        derive_edges(&shuttles),
        Err(MissingEdgeData::NoShuttle(vec![1, 3]))
    );

    let mut sides = full.clone();
    sides.weft_work.shuttles[5] = Some(ShuttleId(2));
    sides.weft_work.shuttle_starts.clear();
    assert_eq!(
        derive_edges(&sides),
        Err(MissingEdgeData::NoStartingSide(vec![
            ShuttleId(1),
            ShuttleId(2)
        ]))
    );

    // Too few picks for a turn at one edge: known, but that edge has none.
    let short = example(
        8,
        &[1, 2, 3, 4],
        &[T, B, T, B],
        &[1, 2, 1, 2],
        &[(1, Right), (2, Right)],
    );
    assert_eq!(edges(&short), (Open, NoTurns));
    assert_eq!(
        derive_edges(&short).unwrap().construction(),
        None,
        "not an exact match"
    );
    assert!(agrees_with(
        &derive_edges(&short).unwrap(),
        Construction::TwoLayers
    ));
    assert!(!agrees_with(
        &derive_edges(&short).unwrap(),
        Construction::Tube
    ));
}

#[test]
fn one_layer_only_is_no_construction() {
    let top = example(8, &cycle(&[1, 3], 8), &[T; 8], &[1; 8], &[(1, Right)]);
    let e = derive_edges(&top).unwrap();
    assert_eq!((e.left, e.right), (Open, Open));
    assert_eq!((e.top_picks, e.bottom_picks), (8, 0));
    assert_eq!(e.construction(), None);
    assert!(!agrees_with(&e, Construction::TwoLayers));
}

// ---------------------------------------------------------------------------------------------
// Declared construction: validation messages
// ---------------------------------------------------------------------------------------------

#[test]
fn a_declared_construction_that_matches_validates_clean() {
    let mut c = example(
        8,
        &cycle(&[1, 2, 4, 3], 8),
        &cycle(&[T, B, B, T], 8),
        &[1; 8],
        &[(1, Right)],
    );
    c.weft_work.construction = Some(Construction::DoubleWidth { fold: Left });
    assert!(construction_issues(&c).is_empty());
    assert!(validate(&c).is_empty(), "{:?}", validate(&c));
    // No declared construction: nothing to compare, nothing reported (an imported WIF stays unlabeled).
    c.weft_work.construction = None;
    assert!(construction_issues(&c).is_empty());
}

#[test]
fn mismatches_say_precisely_what_disagrees() {
    let c = example(
        8,
        &cycle(&[1, 2, 4, 3], 8),
        &cycle(&[T, B, B, T], 8),
        &[1; 8],
        &[(1, Right)],
    );
    let declare = |construction: Construction| {
        let mut d = c.clone();
        d.weft_work.construction = Some(construction);
        construction_issues(&d)
    };
    // The cloth folds on the left; declared fold on the right.
    assert_eq!(
        declare(Construction::DoubleWidth { fold: Right }),
        vec![
            "The fold should be on the right, but the layers join on the left between picks 1 and 2 \
             (and at 3 more turns)."
                .to_string(),
            "The fold should be on the right, but the layers do not join on the right between picks \
             2 and 3 (and at 2 more turns)."
                .to_string(),
        ]
    );
    assert_eq!(
        declare(Construction::TwoLayers),
        vec![
            "Two independent layers should be open at both edges, but the layers join on the left \
              between picks 1 and 2 (and at 3 more turns)."
                .to_string()
        ]
    );
    assert_eq!(
        declare(Construction::Tube),
        vec![
            "A tube should join the layers at both edges, but the layers do not join on the right \
              between picks 2 and 3 (and at 2 more turns)."
                .to_string()
        ]
    );
    // One stray turn: a two-layer cloth whose shuttle 2 weaves one top pick.
    let mut stray = example(
        8,
        &cycle(&[1, 2, 3, 4], 8),
        &cycle(&[T, B], 8),
        &cycle(&[1, 2], 8),
        &[(1, Right), (2, Right)],
    );
    stray.weft_work.shuttles[4] = Some(ShuttleId(2));
    stray.weft_work.construction = Some(Construction::TwoLayers);
    // Shuttle 2 now carries picks 2, 4, 5, 6 and 8: it turns from the bottom layer into the top at
    // the right after pick 4, and back at the left after pick 5.
    let issues = construction_issues(&stray);
    assert_eq!(
        issues,
        vec![
            "Two independent layers should be open at both edges, but the layers join on the left \
             between picks 5 and 6."
                .to_string(),
            "Two independent layers should be open at both edges, but the layers join on the right \
             between picks 4 and 5."
                .to_string(),
        ]
    );
    // The mismatch reaches validate() as a warning, never an error.
    for issue in &issues {
        assert!(warnings(&stray).contains(issue));
    }
    assert!(validate(&stray)
        .iter()
        .all(|i| i.severity != Severity::Error));
}

#[test]
fn a_declared_construction_without_the_data_says_why_it_cannot_be_checked() {
    let base = example(
        8,
        &cycle(&[1, 2, 3, 4], 8),
        &cycle(&[T, B], 8),
        &[1; 8],
        &[(1, Left)],
    );
    let with = |f: &dyn Fn(&mut Draft)| {
        let mut d = base.clone();
        d.weft_work.construction = Some(Construction::Tube);
        f(&mut d);
        construction_issues(&d)
    };
    assert_eq!(with(&|_| {}), Vec::<String>::new());
    assert_eq!(
        with(&|d| d.pick_roles[2..5].fill(PickRole::Unknown)),
        vec![
            "This draft is marked as a tube, but Ply cannot check its edges because picks 3 to 5 \
              are not marked top layer or bottom layer."
                .to_string()
        ]
    );
    assert_eq!(
        with(&|d| d.weft_work.shuttles[6] = None),
        vec![
            "This draft is marked as a tube, but Ply cannot check its edges because pick 7 has no \
              shuttle."
                .to_string()
        ]
    );
    assert_eq!(
        with(&|d| d.weft_work.shuttle_starts.clear()),
        vec![
            "This draft is marked as a tube, but Ply cannot check its edges because shuttle 1 has \
              no starting side."
                .to_string()
        ]
    );
    assert_eq!(
        with(&|d| {
            d.weft_work.shuttles[1] = Some(ShuttleId(2));
            d.weft_work.shuttles[3] = Some(ShuttleId(3));
            d.weft_work.shuttle_starts.clear();
        }),
        vec![
            "This draft is marked as a tube, but Ply cannot check its edges because shuttles 1, 2 \
              and 3 have no starting side."
                .to_string()
        ]
    );
    assert_eq!(
        with(&|d| d.pick_roles.fill(PickRole::TopLayer)),
        vec![
            "This draft is marked as a tube, but every pick is on the top layer, so there is only \
              one layer."
                .to_string()
        ]
    );
    let mut empty = Draft::blank(4, 4);
    empty.weft_work.construction = Some(Construction::DoubleWidth { fold: Left });
    assert_eq!(
        construction_issues(&empty),
        vec![
            "This draft is marked as double width with the fold on the left, but Ply cannot check \
              its edges because it has no picks."
                .to_string()
        ]
    );
}

// ---------------------------------------------------------------------------------------------
// The generator
// ---------------------------------------------------------------------------------------------

#[test]
fn the_two_layer_cloth_is_unchanged_and_now_records_its_shuttles() {
    let d = double_weave(12, 8, Construction::TwoLayers);
    // The cloth from before constructions existed: straight threading, the four-shed tie-up,
    // treadles 1, 2, 3, 4, warp and weft colored by layer.
    let before = example(12, &cycle(&[1, 2, 3, 4], 8), &[], &[], &[]);
    assert_eq!(d.threading, before.threading);
    assert_eq!(d.drive, before.drive);
    assert_eq!(compute(&d), {
        let mut b = before.clone();
        b.colors = d.colors.clone();
        compute(&b)
    });
    assert_eq!(d.colors.warp, cycle(&[0, 1], 12));
    assert_eq!(d.colors.weft, cycle(&[0, 1], 8));
    assert_eq!(d.pick_roles, cycle(&[T, B], 8));
    assert_eq!(
        d.weft_work.shuttles,
        cycle(&[Some(ShuttleId(1)), Some(ShuttleId(2))], 8)
    );
    assert_eq!(
        d.weft_work.shuttle_starts,
        [(ShuttleId(1), Right), (ShuttleId(2), Right)]
            .into_iter()
            .collect()
    );
    assert_eq!(d.weft_work.construction, Some(Construction::TwoLayers));
    assert_eq!(edges(&d), (Open, Open));
    assert!(validate(&d).is_empty(), "{:?}", validate(&d));
    assert!(weft_path_faults(&d).is_empty());
}

#[test]
fn the_tube_has_one_shuttle_from_the_left_and_an_odd_warp() {
    for ends in 1..=41usize {
        let d = double_weave(ends, 12, Construction::Tube);
        let odd = if ends % 2 == 0 { ends - 1 } else { ends };
        assert_eq!(d.ends(), odd, "an even request weaves one end fewer");
        assert_eq!(d.pick_roles, cycle(&[T, B], 12));
        assert!(d
            .weft_work
            .shuttles
            .iter()
            .all(|&s| s == Some(ShuttleId(1))));
        assert_eq!(
            d.weft_work.shuttle_starts,
            [(ShuttleId(1), Left)].into_iter().collect()
        );
        assert_eq!(d.weft_work.construction, Some(Construction::Tube));
        assert!(
            d.colors.weft.iter().all(|&c| c == 0),
            "one shuttle, one weft"
        );
        if odd >= 3 {
            assert_eq!(edges(&d), (Joined, Joined), "{ends}");
            assert!(
                weft_path_faults(&d).is_empty(),
                "{ends}: {:?}",
                weft_path_faults(&d)
            );
            assert!(validate(&d).is_empty(), "{ends}: {:?}", validate(&d));
        }
    }
}

#[test]
fn double_width_folds_where_asked_and_unfolds_to_plain_weave() {
    for fold in [Left, Right] {
        for ends in 2..=40usize {
            let d = double_weave(ends, 16, Construction::DoubleWidth { fold });
            assert_eq!(d.ends(), ends);
            assert_eq!(d.pick_roles, cycle(&[T, B, B, T], 16));
            assert!(d
                .weft_work
                .shuttles
                .iter()
                .all(|&s| s == Some(ShuttleId(1))));
            assert_eq!(
                d.weft_work.shuttle_starts,
                [(ShuttleId(1), fold.other())].into_iter().collect(),
                "the shuttle starts at the open selvedges"
            );
            assert_eq!(
                d.weft_work.construction,
                Some(Construction::DoubleWidth { fold })
            );
            let want = if fold == Left {
                (Joined, Open)
            } else {
                (Open, Joined)
            };
            assert_eq!(edges(&d), want, "{fold:?} {ends}");
            assert!(
                weft_path_faults(&d).is_empty(),
                "{fold:?} {ends}: {:?}",
                weft_path_faults(&d)
            );
            let unfolded = unfold(&d, fold);
            assert_eq!(
                unfolded.len(),
                8,
                "two picks make one weft across the unfolded width"
            );
            assert!(is_plain_weave(&unfolded), "{fold:?} {ends}: {unfolded:?}");
            assert!(
                validate(&d).is_empty(),
                "{fold:?} {ends}: {:?}",
                validate(&d)
            );
        }
    }
}

#[test]
fn every_construction_keeps_its_layers_clear_of_each_other() {
    // A top pick lifts no bottom shaft; a bottom pick lifts the whole top layer (no stitching), in
    // every construction: the cloth is two unstitched layers, so its top face is the top layer.
    for c in [
        Construction::TwoLayers,
        Construction::Tube,
        Construction::DoubleWidth { fold: Left },
        Construction::DoubleWidth { fold: Right },
    ] {
        let d = double_weave(12, 12, c);
        for p in 0..d.picks() {
            let raised: Vec<u16> = d.raised_shafts(p).iter().map(|s| s.0).collect();
            match d.pick_role(p) {
                PickRole::TopLayer => {
                    assert!(!raised.contains(&2) && !raised.contains(&4), "{c:?} {p}");
                    assert_eq!(raised.len(), 1);
                }
                PickRole::BottomLayer => {
                    assert!(raised.contains(&1) && raised.contains(&3), "{c:?} {p}");
                    assert_eq!(raised.len(), 3);
                }
                other => panic!("{c:?}: pick {p} has role {other:?}"),
            }
        }
        // And the sinking-shed re-expression the app applies keeps the cloth and every record.
        let sinking = d.with_shed(ShedType::Sinking);
        assert_eq!(compute(&sinking), compute(&d));
        assert_eq!(sinking.weft_work, d.weft_work);
        assert_eq!(sinking.pick_roles, d.pick_roles);
        assert!(
            validate(&sinking).is_empty(),
            "{c:?}: {:?}",
            validate(&sinking)
        );
    }
}

// ---------------------------------------------------------------------------------------------
// WIF storage
// ---------------------------------------------------------------------------------------------

#[test]
fn the_construction_round_trips_in_version_2_of_the_private_section() {
    for c in [
        Construction::TwoLayers,
        Construction::Tube,
        Construction::DoubleWidth { fold: Left },
        Construction::DoubleWidth { fold: Right },
    ] {
        let d = double_weave(12, 8, c);
        let text = wif::write(&d);
        assert!(
            text.contains("[PRIVATE PLY PICKS]\r\nVersion=2\r\n"),
            "{c:?}"
        );
        let token = match c {
            Construction::TwoLayers => "two-layers",
            Construction::Tube => "tube",
            Construction::DoubleWidth { fold: Left } => "double-width, fold left",
            Construction::DoubleWidth { fold: Right } => "double-width, fold right",
        };
        assert!(
            text.contains(&format!("\r\nConstruction={token}\r\n")),
            "{c:?}"
        );
        let back = wif::parse(&text).unwrap();
        assert_eq!(back.weft_work, d.weft_work, "{c:?}");
        assert_eq!(back.pick_roles, d.pick_roles);
        assert_eq!(wif::write(&back), text, "stable");
        // Re-expressed as a liftplan (and factored back on import), the record stays.
        let lp = wif::parse(&wif::write(&d.to_liftplan_draft())).unwrap();
        assert_eq!(lp.weft_work.construction, Some(c));
    }
}

#[test]
fn without_a_construction_the_section_stays_version_1() {
    let mut d = double_weave(12, 8, Construction::TwoLayers);
    d.weft_work.construction = None;
    let text = wif::write(&d);
    assert!(text.contains("[PRIVATE PLY PICKS]\r\nVersion=1\r\n"));
    assert!(!text.contains("Construction"));
    assert_eq!(wif::parse(&text).unwrap().weft_work, d.weft_work);
    // A construction alone is something recorded: the section is written for it.
    let mut only = Draft::blank(4, 4).resized(4, 2, 4, 4);
    only.weft_work.construction = Some(Construction::Tube);
    let text = wif::write(&only);
    assert!(text.contains("Version=2") && text.contains("Construction=tube"));
    assert_eq!(
        wif::parse(&text).unwrap().weft_work.construction,
        Some(Construction::Tube)
    );
}

#[test]
fn construction_values_are_read_leniently_and_never_guessed() {
    let d = double_weave(12, 8, Construction::DoubleWidth { fold: Right });
    let text = wif::write(&d);
    let with = |value: &str| {
        let t = text.replace(
            "Construction=double-width, fold right",
            &format!("Construction={value}"),
        );
        wif::parse(&t).unwrap().weft_work.construction
    };
    assert_eq!(
        with("Double-Width ,  Fold  LEFT"),
        Some(Construction::DoubleWidth { fold: Left })
    );
    assert_eq!(with("TUBE"), Some(Construction::Tube));
    assert_eq!(with(" two-layers "), Some(Construction::TwoLayers));
    for junk in [
        "double-width",
        "double-width, fold up",
        "pocket",
        "",
        "tube, fold left",
    ] {
        assert_eq!(with(junk), None, "{junk:?}");
    }
    // A version 1 section carries no construction: one there is not something Ply wrote.
    let v1 = text.replace("Version=2", "Version=1");
    let back = wif::parse(&v1).unwrap();
    assert_eq!(back.weft_work.construction, None);
    assert_eq!(
        back.pick_roles, d.pick_roles,
        "the rest of the section is still read"
    );
    // A newer version is kept verbatim and nothing in it is read.
    let v3 = text.replace("Version=2", "Version=3");
    let back = wif::parse(&v3).unwrap();
    assert!(back.weft_work.is_empty() && back.pick_roles.is_empty());
    assert!(wif::write(&back).contains("Version=3"));
    // Changed picks elsewhere: the whole record, construction included, is dropped.
    let changed = text.replace("[TREADLING]\r\n1=1", "[TREADLING]\r\n1=3");
    assert_ne!(changed, text);
    assert_eq!(wif::parse(&changed).unwrap().weft_work.construction, None);
}

#[test]
fn an_imported_draft_without_the_label_is_never_labeled() {
    // A plain WIF (no private section) of a perfect double-width cloth opens with no construction and
    // nothing to derive edges from: the label is never inferred from the cloth.
    let mut d = double_weave(12, 8, Construction::DoubleWidth { fold: Left });
    d.pick_roles.clear();
    d.weft_work = WeftWork::default();
    let back = wif::parse(&wif::write(&d)).unwrap();
    assert_eq!(back.weft_work.construction, None);
    assert!(matches!(
        derive_edges(&back),
        Err(MissingEdgeData::NoLayerRole(_))
    ));
    assert!(validate(&back).is_empty());
}

// ---------------------------------------------------------------------------------------------
// Tracked fixtures (fixtures/weaving/doubleweave/)
// ---------------------------------------------------------------------------------------------

fn fixture(name: &str, ext: &str) -> String {
    let path = format!(
        "{}/../../fixtures/weaving/doubleweave/{name}.{ext}",
        env!("CARGO_MANIFEST_DIR")
    );
    std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{path}: {e}"))
}

fn json_strings(v: &serde_json::Value) -> Vec<String> {
    v.as_array()
        .unwrap()
        .iter()
        .map(|s| s.as_str().unwrap().to_string())
        .collect()
}

fn json_nums(v: &serde_json::Value) -> Vec<u64> {
    v.as_array()
        .unwrap()
        .iter()
        .map(|n| n.as_u64().unwrap())
        .collect()
}

fn behavior_word(b: EdgeBehavior) -> &'static str {
    match b {
        Open => "open",
        Joined => "joined",
        Mixed => "mixed",
        NoTurns => "no turns",
    }
}

#[test]
fn tracked_fixtures_load_and_match_their_oracles() {
    let cases = [
        ("independent-layers", Construction::TwoLayers),
        ("tube", Construction::Tube),
        (
            "double-width-fold-left",
            Construction::DoubleWidth { fold: Left },
        ),
        (
            "double-width-fold-right",
            Construction::DoubleWidth { fold: Right },
        ),
    ];
    for (name, construction) in cases {
        let text = fixture(name, "wif");
        let expect: serde_json::Value =
            serde_json::from_str(&fixture(name, "expect.json")).unwrap();
        let d = wif::parse(&text).unwrap();

        // It is exactly what the generator writes for the recorded parameters (line endings aside).
        let gen = &expect["generator"];
        let generated = double_weave(
            gen["ends"].as_u64().unwrap() as usize,
            gen["picks"].as_u64().unwrap() as usize,
            construction,
        );
        assert_eq!(
            text.replace("\r\n", "\n"),
            wif::write(&generated).replace("\r\n", "\n"),
            "{name}: regenerate only on purpose"
        );

        assert_eq!(d.ends() as u64, expect["ends"].as_u64().unwrap(), "{name}");
        assert_eq!(
            d.picks() as u64,
            expect["picks"].as_u64().unwrap(),
            "{name}"
        );
        let shafts: Vec<u64> = d.threading.0.iter().map(|v| u64::from(v[0].0)).collect();
        assert_eq!(shafts, json_nums(&expect["threading"]), "{name}");
        let Drive::Treadled { tieup, treadling } = &d.drive else {
            panic!("{name}: treadled");
        };
        let treadles: Vec<u64> = treadling.0.iter().map(|v| u64::from(v[0].0)).collect();
        assert_eq!(treadles, json_nums(&expect["treadling"]), "{name}");
        let tie: Vec<Vec<u64>> = tieup
            .0
            .iter()
            .map(|r| r.iter().map(|s| u64::from(s.0)).collect())
            .collect();
        let want_tie: Vec<Vec<u64>> = expect["tieup"]
            .as_array()
            .unwrap()
            .iter()
            .map(json_nums)
            .collect();
        assert_eq!(tie, want_tie, "{name}");

        let roles: String = (0..d.picks())
            .map(|p| match d.pick_role(p) {
                PickRole::TopLayer => 'T',
                PickRole::BottomLayer => 'B',
                _ => '?',
            })
            .collect();
        assert_eq!(roles, expect["roles"].as_str().unwrap(), "{name}");
        let shuttles: Vec<u64> = (0..d.picks())
            .map(|p| u64::from(d.shuttle(p).unwrap().0))
            .collect();
        assert_eq!(shuttles, json_nums(&expect["shuttles"]), "{name}");
        for (k, v) in expect["shuttle_starts"].as_object().unwrap() {
            let s = ShuttleId(k.parse().unwrap());
            let side = if v == "left" { Left } else { Right };
            assert_eq!(d.weft_work.shuttle_starts.get(&s), Some(&side), "{name}");
        }
        assert_eq!(
            d.weft_work.shuttle_starts.len(),
            expect["shuttle_starts"].as_object().unwrap().len()
        );
        assert_eq!(d.weft_work.construction, Some(construction), "{name}");

        let arrows: String = d
            .pass_starts()
            .iter()
            .map(|s| match s {
                Some(Right) => '←',
                Some(Left) => '→',
                None => '?',
            })
            .collect();
        assert_eq!(
            arrows,
            expect["pass_directions"].as_str().unwrap(),
            "{name}"
        );

        let e = derive_edges(&d).unwrap();
        assert_eq!(
            behavior_word(e.left),
            expect["edges"]["left"].as_str().unwrap(),
            "{name}"
        );
        assert_eq!(
            behavior_word(e.right),
            expect["edges"]["right"].as_str().unwrap(),
            "{name}"
        );
        let turns: Vec<String> = e
            .turns
            .iter()
            .map(|t| {
                format!(
                    "{}-{} {} {}",
                    t.from + 1,
                    t.to + 1,
                    if t.side == Left { "left" } else { "right" },
                    if t.joins { "joins" } else { "open" }
                )
            })
            .collect();
        assert_eq!(turns, json_strings(&expect["turns"]), "{name}");
        assert_eq!(e.construction(), Some(construction), "{name}");

        assert_eq!(
            matrix(&d),
            json_strings(&expect["interlacement"]),
            "{name}: interlacement"
        );
        assert!(weft_path_faults(&d).is_empty(), "{name}");
        if let Construction::DoubleWidth { fold } = construction {
            let unfolded = unfold(&d, fold);
            assert_eq!(
                unfolded,
                json_strings(&expect["unfolded_face"]),
                "{name}: unfolded"
            );
            assert!(is_plain_weave(&unfolded));
        }
        assert!(validate(&d).is_empty(), "{name}: {:?}", validate(&d));
    }
}
