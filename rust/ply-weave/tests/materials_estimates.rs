//! The weaving estimates of the materials fixture (ADR 0016): the warp and the weft worked out from
//! the towel sample in `fixtures/materials/materials.json`, checked against the hand-written oracle
//! (`materials.expect.json`, "estimates"), every input with its source and its sentence.

use ply_common::materials_file::{read, MaterialLibrary};
use ply_common::provenance::{Origin, TracedInput};
use ply_common::quantity::{Length, LengthUnit};
use ply_weave::plan::{warp_traced, weft_traced, WarpRequest, WeftRequest};
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
fn warp_from_the_towel_sample() {
    let (lib, e) = fixture();
    let s = lib.swatch("sw-towel").unwrap();
    let t = warp_traced(&WarpRequest {
        swatch: Some(s),
        finished_length: Length::new(2.0, LengthUnit::Yard),
        items: 2,
        ends: Origin::Swatch,
        sett_width: Some(Length::inches(10.0)),
        loom_waste: Origin::Default(Length::new(0.75, LengthUnit::Yard), String::new()),
        allowance: Origin::Swatch,
    })
    .unwrap();
    let w = &e["weave_warp_from_swatch"];
    let tol = w["tolerance"].as_f64().unwrap();
    assert_eq!(u64::from(t.value.ends), w["ends"].as_u64().unwrap());
    assert!(
        (t.value.warp_length.to(LengthUnit::Yard) - w["warp_length_yd"].as_f64().unwrap()).abs()
            <= tol
    );
    assert!(
        (t.value.total.to(LengthUnit::Yard) - w["total_yd"].as_f64().unwrap()).abs() <= tol * 240.0
    );
    check_inputs("warp", &t.inputs, &w["inputs"]);
    assert_eq!(t.inputs.len(), 5);
}

#[test]
fn weft_from_the_towel_sample() {
    let (lib, e) = fixture();
    let s = lib.swatch("sw-towel").unwrap();
    let t = weft_traced(&WeftRequest {
        swatch: Some(s),
        ppi: Origin::Swatch,
        width: Length::inches(12.0),
        woven_length: Length::new(2.25, LengthUnit::Yard),
        items: 2,
        takeup: Origin::Default(0.1, String::new()),
        mean_strands: 1.0,
    })
    .unwrap();
    let w = &e["weave_weft_from_swatch"];
    assert_eq!(u64::from(t.value.picks), w["picks"].as_u64().unwrap());
    assert!(
        (t.value.total.to(LengthUnit::Inch) - w["total_in"].as_f64().unwrap()).abs()
            <= w["tolerance"].as_f64().unwrap()
    );
    check_inputs("weft", &t.inputs, &w["inputs"]);
}
