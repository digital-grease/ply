//! Property-based hardening of `ply-nalbind`. Guarantees over generated stitches / arbitrary strings:
//! the notation `parse(print(x)) == x` round-trip is identity; `parse` never panics on arbitrary
//! text/bytes; `diagram` and `validate` never panic and the diagram stays consistent (one loop glyph
//! per step, finite bounds); and the `StitchType` JSON round-trip is identity.
//!
//! Run: `cargo test -p ply-nalbind --test nalbind_proptest`

use ply_nalbind::diagram::diagram;
use ply_nalbind::notation;
use ply_nalbind::stitch::{ConnSide, Connection, Pass, PublishedCode, Step, StitchType, Twist};
use ply_nalbind::validate::validate;
use proptest::prelude::*;

fn arb_step() -> impl Strategy<Value = Step> {
    prop_oneof![
        Just(Step::Under),
        Just(Step::Over),
        Just(Step::SkippedUnder),
        Just(Step::SkippedOver),
        Just(Step::NoEngage),
    ]
}

fn arb_side() -> impl Strategy<Value = ConnSide> {
    prop_oneof![Just(ConnSide::Front), Just(ConnSide::Back), Just(ConnSide::Middle)]
}

fn arb_twist() -> impl Strategy<Value = Twist> {
    prop_oneof![Just(Twist::Untwisted), Just(Twist::Twisted)]
}

/// Passes for the NOTATION round-trip: each pass has >= 1 step (an empty trailing pass is dropped by
/// `parse`, which would break `parse(print(x)) == x` — real stitches have no empty passes anyway).
fn arb_passes_nonempty() -> impl Strategy<Value = Vec<Pass>> {
    prop::collection::vec(prop::collection::vec(arb_step(), 1..6).prop_map(Pass::new), 1..4)
}

/// Connections the notation can round-trip: `side + count`, no `extra` (the parser never emits one).
fn arb_conns_simple() -> impl Strategy<Value = Vec<Connection>> {
    prop::collection::vec(
        (arb_side(), 0u8..30).prop_map(|(side, count)| Connection::new(side, count)),
        0..3,
    )
}

/// A full (possibly degenerate) stitch for the no-panic + JSON-round-trip properties — passes may be
/// empty, connections may carry an `extra` escape-hatch string.
fn arb_stitch() -> impl Strategy<Value = StitchType> {
    (
        "[A-Za-z ]{0,10}",
        prop::collection::vec(prop::collection::vec(arb_step(), 0..6).prop_map(Pass::new), 0..4),
        prop::collection::vec(
            (arb_side(), 0u8..30, prop::option::of("[a-z ]{0,8}"))
                .prop_map(|(side, count, extra)| Connection { side, count, extra }),
            0..3,
        ),
        prop::option::of((0u8..5, 0u8..5)),
        arb_twist(),
        prop::collection::vec("[a-z]{1,6}", 0..3),
        prop::collection::vec(("[UO/():-]{0,10}", "[a-z.]{1,10}"), 0..2),
        "[a-z .]{0,20}",
    )
        .prop_map(
            |(name, passes, connections, thumb_loops, twist, aka, codes, note)| StitchType {
                name,
                passes,
                connections,
                thumb_loops,
                twist,
                also_known_as: aka,
                codes: codes
                    .into_iter()
                    .map(|(code, source)| PublishedCode { code, source })
                    .collect(),
                note,
            },
        )
}

proptest! {
    /// `parse(print(passes, conns)) == (passes, conns)` — the notation round-trip is identity.
    #[test]
    fn notation_round_trips(passes in arb_passes_nonempty(), conns in arb_conns_simple()) {
        let s = notation::print(&passes, &conns);
        let (p2, c2) = notation::parse(&s).expect("our own printed output must parse");
        prop_assert_eq!(p2, passes);
        prop_assert_eq!(c2, conns);
    }

    /// `parse` never panics on arbitrary text...
    #[test]
    fn parse_never_panics_on_text(s in ".*") {
        let _ = notation::parse(&s);
    }

    /// ...nor on arbitrary bytes read as lossy UTF-8.
    #[test]
    fn parse_never_panics_on_bytes(bytes in prop::collection::vec(any::<u8>(), 0..256)) {
        let _ = notation::parse(&String::from_utf8_lossy(&bytes));
    }

    /// `diagram` and `validate` never panic; the diagram stays consistent (one glyph per step, finite).
    #[test]
    fn diagram_and_validate_never_panic(st in arb_stitch()) {
        let total: usize = st.passes.iter().map(|p| p.steps.len()).sum();
        let d = diagram(&st);
        prop_assert_eq!(d.loops.len(), total);
        prop_assert!(d.width.is_finite() && d.height.is_finite() && d.width > 0.0);
        let _ = validate(&st);
    }

    /// `from_json(to_json(s)) == s` — the StitchType JSON round-trip is identity.
    #[test]
    fn stitch_json_round_trips(st in arb_stitch()) {
        let json = st.to_json().expect("serializes");
        let back = StitchType::from_json(&json).expect("parses back");
        prop_assert_eq!(back, st);
    }
}
