//! Property tests of the quantities, the materials and swatch records, and `materials.json`
//! (roadmap M8-01, ADR 0016):
//!
//! 1. conversions use exact factors and come back (within a few ulps) through any unit;
//! 2. working out diagnostics and figures never panics, whatever the numbers (NaN, infinities,
//!    negatives, huge) or the text, and every figure is a finite number;
//! 3. a figure is only ever worked out from values that are recorded: unknown is never zero;
//! 4. derived figures are never stored: a written file holds only the records, reads back equal,
//!    and gives the same figures;
//! 5. the file writer refuses exactly the libraries with an error diagnostic, and the reader never
//!    panics on any text.
//!
//! Run: `cargo test -p ply-common --test materials_proptest`

use ply_common::materials::*;
use ply_common::materials_file::{read, write, MaterialLibrary};
use ply_common::provenance::{Recorded, Source};
use ply_common::quantity::*;
use ply_common::{CraftKind, YarnWeight};
use proptest::prelude::*;

fn arb_length_unit() -> impl Strategy<Value = LengthUnit> {
    prop::sample::select(LengthUnit::ALL.to_vec())
}

fn arb_mass_unit() -> impl Strategy<Value = MassUnit> {
    prop::sample::select(MassUnit::ALL.to_vec())
}

/// Any number, adversarial ones included.
fn arb_any_f64() -> impl Strategy<Value = f64> {
    prop_oneof![
        3 => 0.001f64..10_000.0,
        1 => Just(0.0),
        1 => Just(-1.0),
        1 => Just(f64::NAN),
        1 => Just(f64::INFINITY),
        1 => Just(f64::NEG_INFINITY),
        1 => Just(1e300),
        1 => Just(f64::MIN_POSITIVE),
        1 => any::<f64>(),
    ]
}

/// A number the engine accepts as a size.
fn arb_size() -> impl Strategy<Value = f64> {
    prop_oneof![0.01f64..500.0, Just(1.0), Just(10.0), Just(4.0)]
}

fn arb_source() -> impl Strategy<Value = Source> {
    prop_oneof![
        4 => Just(Source::Measured),
        4 => Just(Source::Entered),
        1 => Just(Source::Default),
    ]
}

fn arb_rec_length(v: BoxedStrategy<f64>) -> impl Strategy<Value = Option<Recorded<Length>>> {
    prop::option::of(
        (v, arb_length_unit(), arb_source()).prop_map(|(value, unit, source)| Recorded {
            value: Length::new(value, unit),
            source,
        }),
    )
}

fn arb_rec_count(v: BoxedStrategy<f64>) -> impl Strategy<Value = Option<Recorded<CountOver>>> {
    prop::option::of((v.clone(), v, arb_length_unit(), arb_source()).prop_map(
        |(count, over, unit, source)| Recorded {
            value: CountOver::new(count, Length::new(over, unit)),
            source,
        },
    ))
}

fn arb_rec_mass(v: BoxedStrategy<f64>) -> impl Strategy<Value = Option<Recorded<Mass>>> {
    prop::option::of(
        (v, arb_mass_unit(), arb_source()).prop_map(|(value, unit, source)| Recorded {
            value: Mass::new(value, unit),
            source,
        }),
    )
}

fn arb_stage(v: BoxedStrategy<f64>) -> impl Strategy<Value = Stage> {
    (
        arb_rec_length(v.clone()),
        arb_rec_length(v.clone()),
        arb_rec_count(v.clone()),
        arb_rec_count(v),
        ".{0,20}",
    )
        .prop_map(|(width, length, across, along, conditions)| Stage {
            width,
            length,
            across,
            along,
            conditions,
        })
}

fn arb_text() -> impl Strategy<Value = String> {
    prop_oneof![Just(String::new()), ".{0,30}", Just("x".repeat(250))]
}

fn arb_swatch(v: BoxedStrategy<f64>) -> impl Strategy<Value = Swatch> {
    (
        (
            "[a-z0-9]{1,8}",
            arb_text(),
            prop::option::of(prop_oneof![
                Just(CraftKind::Weaving),
                Just(CraftKind::Knitting),
                Just(CraftKind::Nalbinding)
            ]),
            prop::option::of(prop_oneof![
                Just("2026-11-10".to_string()),
                Just("2024-02-29".to_string()),
                Just("2023-02-29".to_string()),
                "[0-9-]{0,12}"
            ]),
        ),
        (
            arb_rec_count(v.clone()),
            arb_rec_length(v.clone()),
            arb_stage(v.clone()),
            arb_stage(v.clone()),
            arb_stage(v.clone()),
            arb_rec_mass(v),
        ),
        prop::collection::vec(
            (prop::option::of("[a-z]{1,6}"), ".{0,10}").prop_map(|(material_id, name)| {
                SwatchYarn {
                    material_id,
                    name,
                    role: None,
                }
            }),
            0..3,
        ),
    )
        .prop_map(
            |(
                (id, name, craft, date),
                (sett, width_in_reed, on_loom, before, after, mass),
                yarns,
            )| {
                Swatch {
                    id,
                    name,
                    craft,
                    technique: String::new(),
                    date,
                    yarns,
                    tools: String::new(),
                    sett,
                    width_in_reed,
                    on_loom,
                    before,
                    after,
                    finishing: "washed".into(),
                    mass,
                    tension: String::new(),
                    provenance: String::new(),
                    notes: String::new(),
                }
            },
        )
}

fn arb_material(v: BoxedStrategy<f64>) -> impl Strategy<Value = Material> {
    (
        "[a-z0-9]{1,8}",
        arb_text(),
        prop::collection::vec(
            (".{0,8}", prop::option::of(v.clone()))
                .prop_map(|(fiber, percent)| FiberPart { fiber, percent }),
            0..4,
        ),
        prop::option::of(
            (
                (v.clone(), arb_length_unit()),
                (v.clone(), arb_mass_unit()),
                arb_source(),
            )
                .prop_map(|((l, lu), (m, mu), source)| Recorded {
                    value: LengthPerMass::new(Length::new(l, lu), Mass::new(m, mu)),
                    source,
                }),
        ),
        arb_rec_count(v.clone()),
        arb_rec_mass(v.clone()),
        arb_rec_length(v),
    )
        .prop_map(
            |(id, name, fibers, length_per_mass, wpi, available_mass, available_length)| Material {
                id,
                name,
                maker: String::new(),
                fibers,
                weight: Some(YarnWeight::Fine),
                structure: String::new(),
                length_per_mass,
                wpi,
                color: String::new(),
                dye_lot: String::new(),
                available_mass,
                available_length,
                notes: String::new(),
            },
        )
}

proptest! {
    #![proptest_config(ProptestConfig { cases: 256, ..ProptestConfig::default() })]

    /// Exact factors: converting through any unit and back returns the value within 4 ulps.
    #[test]
    fn length_and_mass_conversions_come_back(v in 1e-6f64..1e6, a in arb_length_unit(),
            b in arb_length_unit(), c in arb_length_unit(), ma in arb_mass_unit(),
            mb in arb_mass_unit()) {
        let l = Length::new(v, a);
        let back = l.converted(b).converted(c).to(a);
        prop_assert!((back - v).abs() <= 4.0 * f64::EPSILON * v, "{v} {a:?}->{b:?}->{c:?}: {back}");
        let m = Mass::new(v, ma);
        let back = m.converted(mb).to(ma);
        prop_assert!((back - v).abs() <= 4.0 * f64::EPSILON * v);
        // A count over a span is the same density whatever unit the span is in.
        let g = CountOver::new(v, Length::new(10.0, a));
        let g2 = CountOver::new(v, Length::new(10.0, a).converted(b));
        prop_assert!((g.per_10cm() - g2.per_10cm()).abs() <= 1e-9 * g.per_10cm().abs().max(1.0));
    }

    /// Nothing panics on any input, and every figure is finite.
    #[test]
    fn records_never_panic(s in arb_swatch(arb_any_f64().boxed()), m in arb_material(arb_any_f64().boxed())) {
        for f in s.figures().into_iter().chain(m.figures()) {
            prop_assert!(f.value.is_finite(), "{} = {}", f.code, f.value);
            prop_assert!(!f.text.is_empty());
        }
        let _ = s.diagnostics();
        let _ = m.diagnostics();
        let _ = s.length_allowance();
        let _ = s.area_cm2();
        let _ = s.citation();
    }

    /// A figure is only worked out from values that are recorded (unknown is never zero).
    #[test]
    fn figures_need_their_inputs(s in arb_swatch(arb_size().boxed()), m in arb_material(arb_size().boxed())) {
        let codes: Vec<String> = s.figures().into_iter().map(|f| f.code).collect();
        let has = |c: &str| codes.iter().any(|x| x == c);
        let weaving = s.craft == Some(CraftKind::Weaving);
        if s.after.width.is_none() {
            prop_assert!(!has("swatch.width_change") && !has("swatch.width_shrinkage")
                && !has("swatch.total_width_loss") && !has("swatch.width_allowance"));
        }
        if s.on_loom.length.is_none() || s.after.length.is_none() {
            prop_assert!(!has("swatch.length_allowance") && !has("swatch.total_length_loss"));
            prop_assert!(s.length_allowance().is_none());
        }
        if s.width_in_reed.is_none() {
            prop_assert!(!has("swatch.draw_in") && !has("swatch.total_width_loss"));
        }
        if s.mass.is_none() {
            prop_assert!(!has("swatch.grams_per_100cm2"));
        }
        if !weaving {
            prop_assert!(!has("swatch.draw_in") && !has("swatch.take_up"));
        }
        for (k, stage) in [("on_loom", &s.on_loom), ("before", &s.before), ("after", &s.after)] {
            let across = format!("swatch.{k}.across");
            let along = format!("swatch.{k}.along");
            if stage.across.is_none() {
                prop_assert!(!codes.iter().any(|c| c.starts_with(&across)));
            }
            if stage.along.is_none() {
                prop_assert!(!codes.iter().any(|c| c.starts_with(&along)));
            }
        }
        let mcodes: Vec<String> = m.figures().into_iter().map(|f| f.code).collect();
        if m.length_per_mass.is_none() {
            prop_assert!(!mcodes.iter().any(|c| c.contains("per_100g") || c.contains("pound")
                || c.contains("available")));
        }
        if m.wpi.is_none() {
            prop_assert!(!mcodes.iter().any(|c| c.contains("wraps")));
        }
    }

    /// Derived figures are never stored; writing and reading give the same records and figures; the
    /// writer refuses exactly the libraries with an error diagnostic.
    #[test]
    fn the_file_keeps_records_not_figures(
        swatches in prop::collection::vec(arb_swatch(arb_any_f64().boxed()), 0..4),
        materials in prop::collection::vec(arb_material(arb_any_f64().boxed()), 0..4),
    ) {
        let mut lib = MaterialLibrary { materials, swatches };
        // Unique ids, so only the record values decide.
        for (i, m) in lib.materials.iter_mut().enumerate() { m.id = format!("m{i}"); }
        for (i, s) in lib.swatches.iter_mut().enumerate() { s.id = format!("s{i}"); }
        let has_error = lib.materials.iter().map(|m| m.diagnostics()).chain(lib.swatches.iter().map(|s| s.diagnostics()))
            .any(|d| d.iter().any(|x| x.severity == Severity::Error));
        match write(&lib) {
            Ok(text) => {
                prop_assert!(!has_error);
                prop_assert!(!text.contains("per_10cm") && !text.contains("\"figures\"")
                    && !text.contains("allowance"));
                let back = read(&text).unwrap();
                prop_assert_eq!(&back, &lib);
                for (a, b) in back.swatches.iter().zip(&lib.swatches) {
                    prop_assert_eq!(a.figures(), b.figures());
                }
                prop_assert_eq!(write(&back).unwrap(), text);
            }
            Err(_) => prop_assert!(has_error),
        }
    }

    /// The reader never panics, whatever the text.
    #[test]
    fn reading_any_text_never_panics(text in ".{0,200}") {
        let _ = read(&text);
        let wrapped = format!(r#"{{"format":"ply.materials","schema_version":1,"materials":[{text}],"swatches":[]}}"#);
        let _ = read(&wrapped);
    }
}
