//! The knitting readiness acceptance fixture (ADR 0021, `fixtures/knitting/readiness/`, shared with
//! the app's tests): `mixed-problems.plyknit` is a flat k2, p2 ribbed brim with the slips a knitter
//! makes (a cast-on that is not a multiple of the rib, a bind-off of more stitches than are on the
//! needle, a step in the pattern's own words that does not say how it changes the count) around two
//! steps Ply does not check. Its hand-derived `.expect.json` says what readiness must report: the
//! verdict, the checks that ran, and every item (check, code, severity, place, exact sentence) in
//! order.
//!
//! Run: `cargo test -p ply-knit --test readiness_fixtures`

use ply_common::readiness::Severity;
use ply_common::{Color, Unit};
use ply_knit::pattern::{
    builtin, Cell, Chart, Construction, Gauge, KnitPattern, Repeat, RepeatSpan, Row, Side,
    StitchLegend,
};
use ply_knit::readiness::ready_to_make;
use ply_knit::sections::{Section, Step, StepAction};
use ply_knit::{native, validate};
use serde_json::Value;

const NAME: &str = "mixed-problems";

fn path(ext: &str) -> String {
    format!(
        "{}/../../fixtures/knitting/readiness/{NAME}.{ext}",
        env!("CARGO_MANIFEST_DIR")
    )
}

fn read(ext: &str) -> String {
    let p = path(ext);
    std::fs::read_to_string(&p).unwrap_or_else(|e| panic!("{p}: {e}"))
}

fn step(id: &str, action: StepAction) -> Step {
    Step {
        id: id.into(),
        action,
    }
}

/// The pattern the fixture records, as a knitter wrote it.
fn drawn() -> KnitPattern {
    let k = Cell::of(builtin::KNIT);
    let p = Cell::of(builtin::PURL);
    KnitPattern {
        name: "Ribbed brim with slips".into(),
        construction: Construction::Flat,
        first_row_side: Side::Rs,
        // 22 is not a multiple of the 4-stitch rib.
        cast_on: Some(22),
        gauge: Gauge {
            sts: 22.0,
            rows: 30.0,
            unit: Unit::Inches,
        },
        palette: vec![Color::WHITE],
        legend: StitchLegend::builtin(),
        chart: Chart {
            width: 4,
            rows: vec![Row {
                cells: vec![k, k, p, p],
                repeats: vec![RepeatSpan {
                    start: 0,
                    end: 4,
                    count: Repeat::ToEnd,
                }],
            }],
        },
        notes: "Readiness fixture: a brim with the slips a knitter makes.".into(),
        sections: vec![Section {
            id: "section-1".into(),
            name: "Brim".into(),
            notes: String::new(),
            construction: None,
            piece: None,
            steps: vec![
                step("step-1", StepAction::ChartRows { first: 1, last: 1 }),
                step(
                    "step-2",
                    StepAction::Opaque {
                        text: "Work 6 more rows of rib as set.".into(),
                        stitch_change: Some(0),
                    },
                ),
                step(
                    "step-3",
                    StepAction::BindOff {
                        count: Some(30),
                        resolve_turns: false,
                    },
                ),
                step(
                    "step-4",
                    StepAction::Opaque {
                        text: "Change to the larger needles.".into(),
                        stitch_change: None,
                    },
                ),
            ],
        }],
        pieces: Vec::new(),
    }
}

/// Write the fixture with the engine's own `.plyknit` writer. Run on purpose only:
/// `cargo test -p ply-knit --test readiness_fixtures -- --ignored`.
#[test]
#[ignore]
fn write_the_fixture() {
    std::fs::write(path("plyknit"), drawn().to_json().unwrap()).unwrap();
}

#[test]
fn the_fixture_is_the_written_pattern_and_re_saves_to_the_same_bytes() {
    let text = read("plyknit");
    let loaded = native::read(&text).expect("the fixture opens");
    assert_eq!(loaded.source_version, ply_knit::KNIT_SCHEMA_VERSION);
    assert_eq!(
        loaded.pattern.to_json().unwrap(),
        text,
        "re-saving gives the same bytes"
    );
    assert_eq!(loaded.pattern, drawn(), "the file is the written pattern");
}

#[test]
fn readiness_matches_the_oracle() {
    let pattern = native::read(&read("plyknit")).unwrap().pattern;
    let r = ready_to_make(&pattern);
    let oracle: Value = serde_json::from_str(&read("expect.json")).unwrap();
    assert_eq!(
        serde_json::to_value(r.verdict()).unwrap(),
        oracle["verdict"]
    );
    let checked: Vec<&str> = r.checked.iter().map(|c| c.as_str()).collect();
    let want: Vec<&str> = oracle["checked"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v.as_str().unwrap())
        .collect();
    assert_eq!(checked, want, "checks");
    let items = oracle["items"].as_array().unwrap();
    assert_eq!(r.items.len(), items.len(), "{:#?}", r.items);
    for (got, want) in r.items.iter().zip(items) {
        let at = format!("{} {}", got.check.as_str(), got.code);
        assert_eq!(got.check.as_str(), want["check"], "{at}: check");
        assert_eq!(got.code, want["code"].as_str().unwrap(), "{at}: code");
        assert_eq!(got.severity.as_str(), want["severity"], "{at}: severity");
        assert_eq!(got.place.as_deref(), want["place"].as_str(), "{at}: place");
        assert_eq!(
            got.message,
            want["message"].as_str().unwrap(),
            "{at}: message"
        );
    }
    // The blocking set is exactly validation's errors (what the PDF's problems box lists).
    let errors = validate(&pattern)
        .iter()
        .filter(|i| i.severity == Severity::Error)
        .count();
    assert_eq!(r.count(Severity::Error), errors as u64);
    assert_eq!(oracle["errors"], errors);
}
