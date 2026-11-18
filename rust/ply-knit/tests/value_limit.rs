//! The restore guard for `.plyknit` files: the largest pattern the app can make is well within the
//! value limit, and a file just past it is refused without being decoded.
//!
//! Run: `cargo test -p ply-knit --test value_limit`

use ply_common::json_count::count_values;
use ply_common::{Color, Unit};
use ply_knit::native::{read, within_value_limit, write, MAX_VALUES};
use ply_knit::pattern::{
    CableDef, Cell, Chart, Construction, Cross, Gauge, KnitPattern, Repeat, RepeatSpan, Row, Side,
    StitchDef, StitchLegend,
};
use ply_knit::sections::{Piece, Section, Step, StepAction, MAX_PIECES, MAX_SECTIONS, MAX_STEPS};

/// The largest chart the app makes: 200 stitches (the editor's limit) by 400 rows (the new
/// pattern screen's).
const CHART_STS: usize = 200;
const CHART_ROWS: usize = 400;

/// The largest pattern the app can make, with every count at its limit. What it assumes: the chart
/// is at the size the app makes (200 stitches by 400 rows, every cell coloured, a repeat on every
/// column), and every step is an unchecked step with one text. A text of any length is one value,
/// so its length does not matter here. A pattern whose 10,000 steps each name dozens of needle
/// groups (a sock names two or three; the format allows 100 a step) is not one anyone makes, and is
/// left out.
fn largest() -> KnitPattern {
    let text_bytes = 500;
    let text = |n: usize| "x".repeat(n);
    let mut legend = StitchLegend::builtin();
    for i in 0..1000 {
        legend.stitches.push(StitchDef {
            symbol: format!("{i:064}"),
            consumes: 3,
            produces: 3,
            ws_variant: Some(1),
            cable: Some(CableDef {
                front: 2,
                back: 1,
                direction: Cross::Left,
                front_purl: true,
                back_purl: false,
            }),
            macro_rows: 1,
        });
    }
    let top_stitch = legend.stitches.len() - 1;
    let palette = vec![Color::rgb(10, 20, 30); 1000];
    let rows = (0..CHART_ROWS)
        .map(|_| Row {
            cells: vec![Cell::colored(top_stitch, palette.len() - 1); CHART_STS],
            // A repeat on every column, worked as many times as a count allows.
            repeats: (0..CHART_STS)
                .map(|c| RepeatSpan {
                    start: c,
                    end: c + 1,
                    count: Repeat::Times(u16::MAX),
                })
                .collect(),
        })
        .collect();
    let steps_each = MAX_STEPS / MAX_SECTIONS;
    let sections = (0..MAX_SECTIONS)
        .map(|s| Section {
            id: format!("section-{s:056}"),
            name: text(200),
            notes: text(text_bytes),
            construction: Some(Construction::InTheRound),
            piece: Some(format!("{:064}", s % MAX_PIECES)),
            steps: (0..steps_each)
                .map(|k| Step {
                    id: format!("step-{:059}", s * steps_each + k),
                    action: StepAction::Opaque {
                        text: text(text_bytes),
                        stitch_change: Some(-1_000_000),
                    },
                })
                .collect(),
        })
        .collect();
    KnitPattern {
        name: text(1000),
        construction: Construction::Flat,
        first_row_side: Side::Rs,
        cast_on: Some(1_000_000),
        gauge: Gauge {
            sts: 22.5,
            rows: 30.0,
            unit: Unit::Centimeters,
        },
        palette,
        legend,
        chart: Chart {
            width: CHART_STS,
            rows,
        },
        notes: text(100_000),
        sections,
        pieces: (0..MAX_PIECES)
            .map(|i| Piece {
                id: format!("{i:064}"),
                name: text(200),
            })
            .collect(),
    }
}

#[test]
fn the_largest_pattern_the_app_can_make_is_well_within_the_value_limit() {
    let p = largest();
    ply_knit::sections::check_limits(&p).expect("within the section limits");
    let text = write(&p).expect("written");
    let values = count_values(&text);
    assert!(
        values * 2 <= MAX_VALUES,
        "{values} values against {MAX_VALUES}"
    );
    assert!(within_value_limit(&text));
    assert!(
        read(&text).unwrap().pattern == p,
        "it reads back as written"
    );
}

#[test]
fn a_file_just_past_the_limit_is_refused_by_the_guard() {
    // `{"format":"ply.knit","schema_version":6,"document":[...]}` is 7 values and the list's items.
    let at = |n: u64| {
        let items = vec!["{}"; (n - 7) as usize].join(",");
        format!(r#"{{"format":"ply.knit","schema_version":6,"document":[{items}]}}"#)
    };
    assert_eq!(count_values(&at(MAX_VALUES)), MAX_VALUES);
    assert!(within_value_limit(&at(MAX_VALUES)));
    assert!(!within_value_limit(&at(MAX_VALUES + 1)));
}
