//! Property-based hardening of `ply-knit` (M5). Two guarantees over generated, deliberately
//! ADVERSARIAL patterns (ragged rows, dangling stitch/color ids, malformed cables, out-of-range
//! repeats, overflowing cell sizes, non-finite calculator inputs):
//!
//! 1. the JSON write -> parse round-trip is identity (over finite-gauge patterns), and
//! 2. `validate` / `render_rgba` / `to_written` / the calculators NEVER panic — they return a value
//!    (often a flagged issue or a clamped 0), the contract the FFI boundary relies on.
//!
//! Run: `cargo test -p ply-knit --test knit_proptest`

use ply_common::{Color, Unit, YarnWeight};
use ply_knit::calc::{
    cast_on, estimate_yards_from_swatch, estimate_yards_stockinette, finished_length,
    finished_width, seed_gauge, total_stitches, with_buffer,
};
use ply_knit::pattern::*;
use ply_knit::{render_rgba, to_written, validate};
use proptest::prelude::*;

// --- strategies --------------------------------------------------------------------------------

fn arb_unit() -> impl Strategy<Value = Unit> {
    prop_oneof![Just(Unit::Inches), Just(Unit::Centimeters)]
}

/// A FINITE gauge (the only thing `to_json` requires), so the round-trip stays serializable.
fn arb_finite_gauge() -> impl Strategy<Value = Gauge> {
    (0.0f32..1000.0, 0.0f32..1000.0, arb_unit())
        .prop_map(|(sts, rows, unit)| Gauge { sts, rows, unit })
}

fn arb_color() -> impl Strategy<Value = Color> {
    (any::<u8>(), any::<u8>(), any::<u8>()).prop_map(|(r, g, b)| Color { r, g, b })
}

fn arb_cross() -> impl Strategy<Value = Cross> {
    prop_oneof![Just(Cross::Right), Just(Cross::Left)]
}

/// A cable with possibly-degenerate spans (front/back may be 0) to probe edge handling.
fn arb_cable() -> impl Strategy<Value = CableDef> {
    (0u8..5, 0u8..5, arb_cross(), any::<bool>(), any::<bool>()).prop_map(
        |(front, back, direction, front_purl, back_purl)| CableDef {
            front,
            back,
            direction,
            front_purl,
            back_purl,
        },
    )
}

/// The builtin legend plus 0..=2 custom cables, so cell stitch ids can reference real cables.
fn arb_legend() -> impl Strategy<Value = StitchLegend> {
    prop::collection::vec(arb_cable(), 0..=2).prop_map(|cables| {
        let mut legend = StitchLegend::builtin();
        for (i, c) in cables.into_iter().enumerate() {
            let span = c.span();
            legend.stitches.push(StitchDef {
                symbol: format!("C{i}"),
                consumes: span,
                produces: span,
                ws_variant: None,
                cable: Some(c),
                macro_rows: 1,
            });
        }
        legend
    })
}

/// A cell whose stitch id MAY exceed the legend and whose color MAY exceed the palette.
fn arb_cell() -> impl Strategy<Value = Cell> {
    (0usize..18, prop::option::of(0usize..8)).prop_map(|(stitch, color)| Cell { stitch, color })
}

fn arb_repeat() -> impl Strategy<Value = Repeat> {
    prop_oneof![(0u16..8).prop_map(Repeat::Times), Just(Repeat::ToEnd)]
}

fn arb_repeat_span(width: usize) -> impl Strategy<Value = RepeatSpan> {
    let hi = width + 3;
    (0..hi, 0..hi, arb_repeat()).prop_map(|(start, end, count)| RepeatSpan { start, end, count })
}

/// RAGGED-capable rows: the cell count is 0..=width+2 (NOT pinned to `width`), with possibly
/// out-of-bounds repeats — the exact adversarial shapes validate/render/written must survive.
fn arb_row(width: usize) -> impl Strategy<Value = Row> {
    (
        prop::collection::vec(arb_cell(), 0..=width + 2),
        prop::collection::vec(arb_repeat_span(width), 0..=2),
    )
        .prop_map(|(cells, repeats)| Row { cells, repeats })
}

fn arb_pattern() -> impl Strategy<Value = KnitPattern> {
    (0usize..8, arb_legend()).prop_flat_map(|(width, legend)| {
        (
            prop::collection::vec(arb_row(width), 0..=6),
            prop::collection::vec(arb_color(), 0..=4),
            arb_finite_gauge(),
            prop_oneof![Just(Construction::Flat), Just(Construction::InTheRound)],
            prop_oneof![Just(Side::Rs), Just(Side::Ws)],
        )
            .prop_map(move |(rows, palette, gauge, construction, first_row_side)| KnitPattern {
                name: "p".into(),
                construction,
                first_row_side,
                gauge,
                palette,
                legend: legend.clone(),
                chart: Chart { width, rows },
                notes: String::new(),
            })
    })
}

/// cell_px including the OVERFLOW extremes that must hit render's `checked_mul` guard, not panic.
fn arb_cell_px() -> impl Strategy<Value = u32> {
    prop_oneof![1u32..16, Just(0), Just(u32::MAX / 2), Just(u32::MAX)]
}

/// f32 inputs INCLUDING non-finite, so the calculators' guards are exercised.
fn arb_f32() -> impl Strategy<Value = f32> {
    prop_oneof![
        -1e9f32..1e9,
        Just(0.0f32),
        Just(f32::NAN),
        Just(f32::INFINITY),
        Just(f32::NEG_INFINITY),
    ]
}

fn arb_yarn_weight() -> impl Strategy<Value = YarnWeight> {
    prop_oneof![
        Just(YarnWeight::Lace),
        Just(YarnWeight::SuperFine),
        Just(YarnWeight::Fine),
        Just(YarnWeight::Light),
        Just(YarnWeight::Medium),
        Just(YarnWeight::Bulky),
        Just(YarnWeight::SuperBulky),
        Just(YarnWeight::Jumbo),
    ]
}

// --- properties --------------------------------------------------------------------------------

proptest! {
    /// `from_json(to_json(p)) == p` for finite-gauge patterns — the JSON round-trip is identity.
    #[test]
    fn json_round_trip_is_identity(p in arb_pattern()) {
        let json = p.to_json().expect("a finite-gauge pattern serializes");
        let back = KnitPattern::from_json(&json).expect("our own output parses back");
        prop_assert_eq!(back, p);
    }

    /// `validate` never panics on arbitrary (adversarial) patterns.
    #[test]
    fn validate_never_panics(p in arb_pattern()) {
        let _ = validate(&p);
    }

    /// `render_rgba` never panics — incl. cell_px extremes that exercise the overflow guard — and
    /// the raster is always exactly width*height*4 bytes (empty when guarded / zero-area).
    #[test]
    fn render_never_panics_and_buffer_is_consistent(p in arb_pattern(), cell_px in arb_cell_px()) {
        let img = render_rgba(&p, cell_px);
        prop_assert_eq!(img.pixels.len(), img.width as usize * img.height as usize * 4);
    }

    /// `to_written` never panics and emits exactly one line per chart row.
    #[test]
    fn written_never_panics_one_line_per_row(p in arb_pattern()) {
        let lines = to_written(&p);
        prop_assert_eq!(lines.len(), p.chart.rows.len());
    }

    /// `from_json` never panics on arbitrary text...
    #[test]
    fn from_json_never_panics_on_text(s in ".*") {
        let _ = KnitPattern::from_json(&s);
    }

    /// ...nor on arbitrary bytes read as lossy UTF-8.
    #[test]
    fn from_json_never_panics_on_bytes(bytes in prop::collection::vec(any::<u8>(), 0..256)) {
        let _ = KnitPattern::from_json(&String::from_utf8_lossy(&bytes));
    }

    /// The calculators never panic and never return NaN on arbitrary (incl. non-finite) inputs.
    #[test]
    fn calculators_never_panic_or_nan(
        a in arb_f32(), b in arb_f32(), ease in arb_f32(),
        sts in arb_f32(), rows in arb_f32(), unit in arb_unit(),
        count in any::<u32>(), repeat in any::<u32>(), frac in arb_f32(),
        sw in (arb_f32(), arb_f32(), arb_f32(), arb_f32(), arb_f32()),
        weight in arb_yarn_weight(),
    ) {
        let g = Gauge { sts, rows, unit };
        prop_assert!(!finished_width(count, g).is_nan());
        prop_assert!(!finished_length(count, g).is_nan());
        let _ = cast_on(a, ease, g, repeat); // a u32 count, never NaN, must not panic
        prop_assert!(!total_stitches(a, b, g).is_nan());
        let est = estimate_yards_stockinette(a, b, g);
        prop_assert!(!est.is_nan());
        // with_buffer is fed the guarded (non-NaN) estimate + an arbitrary fraction.
        prop_assert!(!with_buffer(est, frac).is_nan());
        prop_assert!(!estimate_yards_from_swatch(sw.0, sw.1, sw.2, sw.3, sw.4).is_nan());
        // seed_gauge always yields a positive, finite gauge.
        let sg = seed_gauge(weight);
        prop_assert!(sg.sts.is_finite() && sg.sts > 0.0 && sg.rows.is_finite() && sg.rows > 0.0);
    }
}

/// A hand-built corpus of adversarial patterns that must validate/render/write WITHOUT panicking —
/// including the cable-on-a-ragged-row shape that previously indexed past the row's cells.
#[test]
fn adversarial_corpus_never_panics() {
    let cable = CableDef {
        front: 2,
        back: 2,
        direction: Cross::Right,
        front_purl: false,
        back_purl: false,
    };
    let mut legend = StitchLegend::builtin();
    legend.stitches.push(StitchDef {
        symbol: "2/2RC".into(),
        consumes: 4,
        produces: 4,
        ws_variant: None,
        cable: Some(cable),
        macro_rows: 1,
    });
    let cable_id = legend.stitches.len() - 1;
    let g = Gauge { sts: 20.0, rows: 28.0, unit: Unit::Inches };

    let cases: Vec<KnitPattern> = vec![
        // a lone span-4 cable on a width-6 chart with a 1-cell (ragged) row.
        mk(6, vec![Row::plain(vec![Cell::of(cable_id)])], legend.clone(), g),
        // a cell referencing a stitch id well past the legend, plus an out-of-range color.
        mk(
            2,
            vec![Row::plain(vec![Cell { stitch: 999, color: Some(99) }, Cell::of(1)])],
            legend.clone(),
            g,
        ),
        // a row far longer than the chart width.
        mk(1, vec![Row::plain(vec![Cell::of(1); 20])], legend.clone(), g),
        // an out-of-range repeat span.
        mk(
            3,
            vec![Row {
                cells: vec![Cell::of(1); 3],
                repeats: vec![RepeatSpan { start: 5, end: 99, count: Repeat::ToEnd }],
            }],
            legend.clone(),
            g,
        ),
        // an empty chart (zero width, no rows).
        mk(0, vec![], legend.clone(), g),
    ];

    for p in cases {
        let _ = validate(&p);
        let _ = render_rgba(&p, 4);
        let _ = render_rgba(&p, u32::MAX); // exercise the overflow guard too
        let _ = to_written(&p);
    }
}

fn mk(width: usize, rows: Vec<Row>, legend: StitchLegend, gauge: Gauge) -> KnitPattern {
    KnitPattern {
        name: "t".into(),
        construction: Construction::Flat,
        first_row_side: Side::Rs,
        gauge,
        palette: vec![Color::WHITE],
        legend,
        chart: Chart { width, rows },
        notes: String::new(),
    }
}
