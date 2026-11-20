//! The stress cases of ADR 0022 section 23, generated here rather than stored: a 300 by 300 blanket
//! (90,000 stitches), a 1,000,000-item piece at the cap resolved as windows, a `to_end` repeat over
//! 100,000 positions, and identical output across runs.
//!
//! Run: `cargo test -p ply-crochet --test stress --release` (it also passes in debug, more slowly).

mod common;

use common::*;
use ply_crochet::*;

/// A blanket of `rows` rows of `width` `b0`, worked flat from a foundation chain.
fn blanket(width: u32, rows: u32) -> CrochetPattern {
    let mut layers = vec![(
        row(vec![
            Instr::start_from_foundation(1, CountsAs::Nothing),
            Instr::to_end(vec![st(B0, nch())]),
        ]),
        stitches(width),
    )];
    for _ in 1..rows {
        layers.push((
            row(vec![ch_none(1), Instr::to_end(vec![st(B0, ns())])]),
            stitches(width),
        ));
    }
    piece(PieceStart::FoundationChain(width + 1), layers)
}

#[test]
fn a_300_by_300_blanket() {
    let p = blanket(300, 300);
    let all = resolve_all(&p);
    assert_eq!(all.layers.len(), 300);
    let stitches: u64 = all
        .layers
        .iter()
        .map(|l| l.count.as_ref().unwrap().total_stitches())
        .sum();
    assert_eq!(stitches, 90_000);
    assert!(all
        .layers
        .iter()
        .all(|l| l.stated == Some(StatedCheck::Met)));
    // Rows alternate their turn: row 300's first stitch goes into row 299's last.
    let last = &all.layers[299];
    assert_eq!(anchors(&last.made[1]), "299.300");
    // A window is the same rows as the whole.
    let w = try_resolve(&p, 291..=300, &CrochetLimits::DEFAULT).unwrap();
    assert_eq!(w.layers.len(), 10);
    assert_eq!(w.layers[..], all.layers[290..]);
    assert!(validate(&p).is_empty());
}

#[test]
fn a_million_items_at_the_cap_resolve_as_windows() {
    // Each row makes 100,000 items (its starting chain and 99,999 stitches): 10 rows are the cap.
    let p = blanket(99_999, 10);
    let w = try_resolve(&p, 10..=10, &CrochetLimits::DEFAULT).unwrap();
    assert_eq!(w.layers.len(), 1, "only the window's items are kept");
    assert_eq!(w.layers[0].made.len(), 100_000);
    assert_eq!(w.layers[0].count.as_ref().unwrap().total_stitches(), 99_999);
    assert!(validate(&p).is_empty());
    // One more row passes the piece's cap while resolving: refused, never a panic.
    let p = blanket(99_999, 11);
    match try_resolve(&p, 11..=11, &CrochetLimits::DEFAULT) {
        Err(CrochetError::Invalid(ds)) => assert_eq!(codes(&ds), ["crochet.too_large"]),
        other => panic!("{other:?}"),
    }
    assert_eq!(codes(&validate(&p)), ["crochet.too_large"]);
}

#[test]
fn a_to_end_repeat_over_100_000_positions_stops() {
    // Row 2's base has 99,999 positions; a body of one `next stitch` makes exactly 99,999
    // repetitions, and a body of two leaves one position (listed once, not twice).
    let p = blanket(99_999, 2);
    let w = resolve_all(&p);
    let r2 = &w.layers[1];
    assert_eq!(r2.made.last().unwrap().repetition, vec![99_999]);
    let mut p2 = blanket(99_999, 1);
    p2.push(
        row(vec![
            ch_none(1),
            Instr::to_end(vec![st(B0, ns()), st(B0, ns())]),
        ]),
        None,
    );
    let ds = validate(&p2);
    assert_eq!(codes(&ds), ["crochet.repeat_does_not_fit"]);
    // A body that never moves forward stops before its first repetition.
    let mut p3 = blanket(99_999, 1);
    p3.push(row(vec![ch_none(1), Instr::to_end(vec![ch(1)])]), None);
    assert_eq!(codes(&validate(&p3)), ["crochet.repeat_does_not_fit"]);
}

#[test]
fn output_is_identical_across_runs() {
    let p = blanket(120, 40);
    let a = resolve_all(&p);
    let b = resolve_all(&p.clone());
    assert_eq!(a, b);
    assert_eq!(validate(&p), validate(&p));
}

#[test]
fn passing_a_huge_base_is_bounded() {
    // `next space` over 99,999 stitches with no space: one walk per try, answered from the tables,
    // so many failing tries stay fast and every one is reported (capped per code).
    let mut p = blanket(99_999, 1);
    p.push(
        row(vec![ch_none(1), Instr::times(5_000, vec![st(B0, nsp())])]),
        None,
    );
    let ds = validate(&p);
    let kinds = ds
        .iter()
        .filter(|d| d.code == CrochetCode::AnchorKind)
        .count();
    assert_eq!(kinds, MAX_DIAGNOSTICS_PER_CODE);
    let capped = ds
        .iter()
        .find(|d| d.code == CrochetCode::ListCapped)
        .unwrap();
    assert_eq!(
        capped.detail,
        Detail::Omitted {
            code: CrochetCode::AnchorKind,
            count: 4_000
        }
    );
}

#[test]
fn many_different_chain_runs_are_counted_in_linear_time() {
    // One row of ten repetitions of ch 1, ch 2, ..., ch 9,998: 99,980 spaces of 9,998 lengths.
    let mut p = blanket(5, 1);
    p.push(
        row(vec![
            ch_none(1),
            Instr::times(10, (1..=9_998).map(ch).collect()),
        ]),
        None,
    );
    let t = std::time::Instant::now();
    let w = resolve_all(&p);
    let took = t.elapsed();
    let c = w.layers[1].count.as_ref().unwrap();
    assert_eq!(c.spaces.len(), 9_998);
    assert!(c
        .spaces
        .iter()
        .enumerate()
        .all(|(i, &(m, n))| m == i as u32 + 1 && n == 10));
    assert!(took < std::time::Duration::from_secs(5), "took {took:?}");
}
