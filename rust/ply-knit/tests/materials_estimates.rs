//! The knitting estimates of the materials fixture (ADR 0016): a cast-on and a yarn estimate worked
//! out from the swatch in `fixtures/materials/materials.json`, checked against the hand-written
//! oracle (`materials.expect.json`, "estimates"), every input with its source and its sentence.

use ply_common::materials_file::{read, MaterialLibrary};
use ply_common::provenance::{Origin, TracedInput};
use ply_common::quantity::{CountOver, Length};
use ply_knit::plan::{
    cast_on_traced, yardage_traced, CastOnRequest, YardageMethod, YardageRequest,
};
use serde_json::Value;

const DIR: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../fixtures/materials");

fn fixture() -> (MaterialLibrary, Value) {
    let lib = read(&std::fs::read_to_string(format!("{DIR}/materials.json")).unwrap()).unwrap();
    let e: Value = serde_json::from_str(
        &std::fs::read_to_string(format!("{DIR}/materials.expect.json")).unwrap(),
    )
    .unwrap();
    (lib, e["estimates"].clone())
}

/// The oracle's inputs (in order; a prefix of the estimate's when the oracle lists fewer).
fn check_inputs(what: &str, got: &[TracedInput], want: &Value) {
    let want = want.as_array().unwrap();
    assert!(got.len() >= want.len(), "{what}: {got:?}");
    for (g, w) in got.iter().zip(want) {
        assert_eq!(g.key, w["key"].as_str().unwrap(), "{what}");
        assert_eq!(
            g.source.as_str(),
            w["source"].as_str().unwrap(),
            "{what} {}",
            g.key
        );
        assert_eq!(
            g.sentence(),
            w["sentence"].as_str().unwrap(),
            "{what} {}",
            g.key
        );
    }
}

#[test]
fn cast_on_from_the_swatch_and_from_a_default() {
    let (lib, e) = fixture();
    let s = lib.swatch("sw-knit").unwrap();
    let t = cast_on_traced(&CastOnRequest {
        swatch: Some(s),
        gauge: Origin::Swatch,
        width: Length::cm(50.0),
        ease: Length::cm(5.0),
        repeat: 4,
    })
    .unwrap();
    let w = &e["knit_cast_on_from_swatch"];
    assert_eq!(u64::from(t.value), w["value"].as_u64().unwrap());
    check_inputs("cast-on from the swatch", &t.inputs, &w["inputs"]);
    assert_eq!(t.inputs.len(), 4);

    let t = cast_on_traced(&CastOnRequest {
        swatch: None,
        gauge: Origin::Default(CountOver::new(22.0, Length::cm(10.0)), "for DK".into()),
        width: Length::cm(50.0),
        ease: Length::cm(0.0),
        repeat: 1,
    })
    .unwrap();
    let w = &e["knit_cast_on_from_default"];
    assert_eq!(u64::from(t.value), w["value"].as_u64().unwrap());
    check_inputs("cast-on from a default", &t.inputs, &w["inputs"]);
    assert!(t.has_defaults());
}

#[test]
fn yarn_from_the_weighed_swatch() {
    let (lib, e) = fixture();
    let s = lib.swatch("sw-knit").unwrap();
    let yarn = lib.material("grey-wool").unwrap();
    let t = yardage_traced(&YardageRequest {
        swatch: Some(s),
        gauge: Origin::Swatch,
        width: Length::cm(50.0),
        length: Length::cm(60.0),
        yarn: Some(yarn),
        buffer: Origin::Default(0.1, String::new()),
    })
    .unwrap();
    let w = &e["knit_yardage_weighed_swatch"];
    let tol = w["tolerance"].as_f64().unwrap();
    assert_eq!(t.value.method, YardageMethod::WeighedSwatch);
    for (got, key) in [
        (t.value.meters, "meters"),
        (t.value.yards, "yards"),
        (t.value.buffered_meters, "buffered_meters"),
        (t.value.buffered_yards, "buffered_yards"),
    ] {
        let want = w[key].as_f64().unwrap();
        assert!((got - want).abs() <= tol, "{key}: {got} vs {want}");
    }
    check_inputs("yarn from the swatch", &t.inputs, &w["inputs"]);
    assert_eq!(t.inputs.len(), 6);
}
