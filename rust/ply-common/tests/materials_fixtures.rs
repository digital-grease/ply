//! The materials and swatch fixtures (roadmap M8-01, ADR 0016): `fixtures/materials/materials.json`
//! is what the engine's writer makes of the records built here, and its oracle
//! (`materials.expect.json`, written by hand from the formulas) gives every derived figure and
//! diagnostic; `diagnostics.json` holds records that cannot be true, with the codes they must get.
//!
//! To rewrite `materials.json` after a deliberate change to the records here:
//! `PLY_WRITE_FIXTURES=1 cargo test -p ply-common --test materials_fixtures`.

use ply_common::materials::*;
use ply_common::materials_file::{read, write, MaterialLibrary};
use ply_common::provenance::Recorded;
use ply_common::quantity::*;
use ply_common::{CraftKind, YarnWeight};
use serde_json::Value;

const DIR: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../fixtures/materials");

fn m(v: f64, unit: LengthUnit) -> Recorded<Length> {
    Recorded::measured(Length::new(v, unit))
}

fn count(n: f64, over: f64, unit: LengthUnit) -> Recorded<CountOver> {
    Recorded::measured(CountOver::new(n, Length::new(over, unit)))
}

/// The fixture library: three materials (one only named) and four swatches, invented for the tests.
pub fn library() -> MaterialLibrary {
    use LengthUnit::{Centimeter as Cm, Inch as In};
    let wool = Material {
        id: "grey-wool".into(),
        name: "Grey wool".into(),
        maker: "Invented Mill, Fell DK".into(),
        fibers: vec![
            FiberPart {
                fiber: "wool".into(),
                percent: Some(80.0),
            },
            FiberPart {
                fiber: "nylon".into(),
                percent: Some(20.0),
            },
        ],
        weight: Some(YarnWeight::Light),
        structure: "4-ply, worsted-spun".into(),
        length_per_mass: Some(Recorded::entered(LengthPerMass::new(
            Length::new(200.0, LengthUnit::Meter),
            Mass::grams(100.0),
        ))),
        wpi: Some(count(11.0, 1.0, In)),
        color: "Heather grey".into(),
        dye_lot: "A12".into(),
        available_mass: Some(Recorded::measured(Mass::grams(450.0))),
        available_length: None,
        notes: "Invented for Ply's tests.".into(),
    };
    let mut cotton = Material::new("cotton-8-2", "8/2 cotton, natural");
    cotton.fibers = vec![FiberPart {
        fiber: "cotton".into(),
        percent: Some(100.0),
    }];
    cotton.structure = "8/2, unmercerized".into();
    cotton.length_per_mass = Some(Recorded::entered(LengthPerMass::new(
        Length::new(3360.0, LengthUnit::Yard),
        Mass::new(1.0, MassUnit::Pound),
    )));
    cotton.available_length = Some(Recorded::entered(Length::new(1680.0, LengthUnit::Yard)));
    let mystery = Material::new("mystery", "Mystery grey");

    let mut knit = Swatch::new("sw-knit", "Grey wool stockinette");
    knit.craft = Some(CraftKind::Knitting);
    knit.technique = "stockinette".into();
    knit.date = Some("2026-11-10".into());
    knit.yarns = vec![SwatchYarn {
        material_id: Some("grey-wool".into()),
        name: "Grey wool".into(),
        role: Some(YarnRole::Main),
    }];
    knit.tools = "4 mm circular needle".into();
    knit.before = Stage {
        width: Some(m(13.5, Cm)),
        length: Some(m(16.0, Cm)),
        across: Some(count(22.0, 10.0, Cm)),
        along: Some(count(30.0, 10.0, Cm)),
        conditions: "flat, before washing".into(),
    };
    knit.after = Stage {
        width: Some(m(15.0, Cm)),
        length: Some(m(15.0, Cm)),
        across: Some(count(20.0, 10.0, Cm)),
        along: Some(count(32.0, 10.0, Cm)),
        conditions: "flat, unpinned, after a day".into(),
    };
    knit.finishing = "washed in cool water, dried flat".into();
    knit.mass = Some(Recorded::measured(Mass::grams(9.0)));
    knit.provenance = "knitted and measured by the tester".into();

    let mut towel = Swatch::new("sw-towel", "Towel sample");
    towel.craft = Some(CraftKind::Weaving);
    towel.technique = "2/2 twill".into();
    towel.date = Some("2026-11-02".into());
    towel.yarns = vec![
        SwatchYarn {
            material_id: Some("cotton-8-2".into()),
            name: "8/2 cotton, natural".into(),
            role: Some(YarnRole::Warp),
        },
        SwatchYarn {
            material_id: Some("cotton-8-2".into()),
            name: "8/2 cotton, natural".into(),
            role: Some(YarnRole::Weft),
        },
    ];
    towel.tools = "table loom, 12-dent reed, 2 per dent".into();
    towel.sett = Some(Recorded::entered(CountOver::new(24.0, Length::inches(1.0))));
    towel.width_in_reed = Some(Recorded::entered(Length::inches(12.0)));
    towel.on_loom = Stage {
        width: Some(m(11.4, In)),
        length: Some(m(20.0, In)),
        across: None,
        along: Some(count(22.0, 1.0, In)),
        conditions: "under weaving tension".into(),
    };
    towel.before = Stage {
        width: Some(m(11.0, In)),
        length: Some(m(19.0, In)),
        ..Stage::default()
    };
    towel.after = Stage {
        width: Some(m(10.5, In)),
        length: Some(m(18.0, In)),
        across: None,
        along: Some(count(24.0, 1.0, In)),
        conditions: "dry, pressed".into(),
    };
    towel.finishing = "machine washed warm, line dried, pressed".into();

    let mut nal = Swatch::new("sw-oslo", "Oslo stitch mitten sample");
    nal.craft = Some(CraftKind::Nalbinding);
    nal.technique = "Oslo UO/UOO F1".into();
    nal.yarns = vec![SwatchYarn {
        material_id: Some("mystery".into()),
        name: "Mystery grey".into(),
        role: None,
    }];
    nal.tools = "bone needle, thumb loop held loose".into();
    nal.before = Stage {
        width: Some(m(8.0, Cm)),
        length: Some(m(6.0, Cm)),
        across: Some(count(12.0, 5.0, Cm)),
        along: Some(count(9.0, 5.0, Cm)),
        conditions: String::new(),
    };
    nal.after = Stage {
        width: Some(m(7.0, Cm)),
        length: Some(m(5.5, Cm)),
        across: Some(count(13.0, 5.0, Cm)),
        along: None,
        conditions: "dry".into(),
    };
    nal.finishing = "fulled by hand in warm soapy water".into();

    let mut lace = Swatch::new("sw-lace", "Lace, blocked hard");
    lace.craft = Some(CraftKind::Knitting);
    lace.technique = "feather and fan".into();
    lace.before = Stage {
        width: Some(m(10.0, Cm)),
        length: Some(m(10.0, Cm)),
        ..Stage::default()
    };
    lace.after = Stage {
        width: Some(m(16.0, Cm)),
        length: Some(m(13.0, Cm)),
        ..Stage::default()
    };
    lace.finishing = "soaked, pinned out to dry".into();

    MaterialLibrary {
        materials: vec![wool, cotton, mystery],
        swatches: vec![knit, towel, nal, lace],
    }
}

fn expect() -> Value {
    serde_json::from_str(&std::fs::read_to_string(format!("{DIR}/materials.expect.json")).unwrap())
        .unwrap()
}

#[test]
fn the_fixture_is_what_the_writer_makes_and_round_trips() {
    let text = write(&library()).unwrap();
    let path = format!("{DIR}/materials.json");
    if std::env::var("PLY_WRITE_FIXTURES").is_ok() {
        std::fs::write(&path, format!("{text}\n")).unwrap();
    }
    let on_disk = std::fs::read_to_string(&path).unwrap();
    assert_eq!(
        on_disk.trim_end_matches('\n'),
        text,
        "materials.json is not what the writer makes"
    );
    let lib = read(&on_disk).unwrap();
    assert_eq!(lib, library());
    assert_eq!(write(&lib).unwrap(), text);
}

fn check_figures(what: &str, figures: &[Figure], expected: &Value) {
    let want = expected.as_array().unwrap();
    let got: Vec<&str> = figures.iter().map(|f| f.code.as_str()).collect();
    let want_codes: Vec<&str> = want.iter().map(|w| w["code"].as_str().unwrap()).collect();
    assert_eq!(got, want_codes, "{what}: figure codes");
    for (f, w) in figures.iter().zip(want) {
        let v = w["value"].as_f64().unwrap();
        assert!(
            (f.value - v).abs() <= 1e-4 * v.abs().max(1.0),
            "{what} {}: {} vs {v}",
            f.code,
            f.value
        );
        assert_eq!(f.text, w["text"].as_str().unwrap(), "{what} {}", f.code);
    }
}

fn check_diagnostics(what: &str, d: &[RecordDiagnostic], expected: &Value) {
    let want = expected.as_array().unwrap();
    assert_eq!(d.len(), want.len(), "{what}: {d:?}");
    for (x, w) in d.iter().zip(want) {
        assert_eq!(x.code, w["code"].as_str().unwrap(), "{what}");
        assert_eq!(x.field, w["field"].as_str().unwrap(), "{what} {}", x.code);
        let sev = match x.severity {
            Severity::Error => "error",
            Severity::Warning => "warning",
        };
        assert_eq!(sev, w["severity"].as_str().unwrap(), "{what} {}", x.code);
        if let Some(msg) = w.get("message") {
            assert_eq!(x.message, msg.as_str().unwrap(), "{what} {}", x.code);
        }
    }
}

#[test]
fn every_figure_and_diagnostic_matches_the_oracle() {
    let lib = library();
    let e = expect();
    for m in &lib.materials {
        let want = &e["materials"][&m.id];
        check_figures(&m.id, &m.figures(), &want["figures"]);
        check_diagnostics(&m.id, &m.diagnostics(), &want["diagnostics"]);
    }
    for s in &lib.swatches {
        let want = &e["swatches"][&s.id];
        check_figures(&s.id, &s.figures(), &want["figures"]);
        check_diagnostics(&s.id, &s.diagnostics(), &want["diagnostics"]);
    }
}

#[test]
fn impossible_records_get_their_codes() {
    let raw: Value =
        serde_json::from_str(&std::fs::read_to_string(format!("{DIR}/diagnostics.json")).unwrap())
            .unwrap();
    let e = expect();
    for r in raw["materials"].as_array().unwrap() {
        let m: Material = serde_json::from_value(r.clone()).unwrap();
        check_diagnostics(&m.id, &m.diagnostics(), &e["impossible"][&m.id]);
        // A library holding it cannot be written, and a file holding it is refused.
        let lib = MaterialLibrary {
            materials: vec![m],
            swatches: vec![],
        };
        assert!(write(&lib).is_err());
    }
    for r in raw["swatches"].as_array().unwrap() {
        let s: Swatch = serde_json::from_value(r.clone()).unwrap();
        check_diagnostics(&s.id, &s.diagnostics(), &e["impossible"][&s.id]);
        let text = serde_json::json!({"format": "ply.materials", "schema_version": 1,
            "materials": [], "swatches": [r]})
        .to_string();
        assert!(read(&text).is_err());
    }
}
