//! Property tests of the knitting estimates that show their working (`ply_knit::plan`, ADR 0016):
//! they never panic on any input, and with a typed gauge they give exactly the calculator's numbers
//! (`ply_knit::calc`), with every input listed.
//!
//! Run: `cargo test -p ply-knit --test plan_proptest`

use ply_common::provenance::{Origin, Source};
use ply_common::quantity::{CountOver, Length, LengthUnit};
use ply_common::Unit;
use ply_knit::calc::{cast_on, estimate_yards_stockinette};
use ply_knit::plan::{cast_on_traced, yardage_traced, CastOnRequest, YardageRequest};
use ply_knit::Gauge;
use proptest::prelude::*;

fn any_f64() -> impl Strategy<Value = f64> {
    prop_oneof![
        3 => 0.01f64..500.0,
        1 => Just(0.0),
        1 => Just(-5.0),
        1 => Just(f64::NAN),
        1 => Just(f64::INFINITY),
        1 => any::<f64>(),
    ]
}

proptest! {
    #[test]
    fn never_panics(g in any_f64(), span in any_f64(), w in any_f64(), ease in any_f64(),
            l in any_f64(), repeat in any::<u32>(), buffer in any_f64()) {
        let gauge = Origin::Entered(CountOver::new(g, Length::cm(span)));
        let _ = cast_on_traced(&CastOnRequest {
            swatch: None, gauge: gauge.clone(), width: Length::cm(w), ease: Length::cm(ease), repeat,
        });
        let _ = yardage_traced(&YardageRequest {
            swatch: None, gauge, width: Length::inches(w), length: Length::inches(l), yarn: None,
            buffer: Origin::Entered(buffer),
        });
    }

    #[test]
    fn a_typed_gauge_gives_the_calculators_numbers(sts in 5.0f64..40.0, w in 1.0f64..200.0,
            ease in -5.0f64..10.0, repeat in 1u32..12, l in 1.0f64..200.0) {
        let gauge = Origin::Entered(CountOver::new(sts, Length::cm(10.0)));
        let t = cast_on_traced(&CastOnRequest {
            swatch: None, gauge: gauge.clone(), width: Length::cm(w), ease: Length::cm(ease), repeat,
        }).unwrap();
        let g = Gauge { sts: sts as f32, rows: sts as f32, unit: Unit::Centimeters };
        prop_assert_eq!(t.value, cast_on(w as f32, ease as f32, g, repeat));
        prop_assert!(t.inputs.iter().all(|i| i.source == Source::Entered));
        let y = yardage_traced(&YardageRequest {
            swatch: None, gauge, width: Length::cm(w), length: Length::cm(l), yarn: None,
            buffer: Origin::Default(0.1, String::new()),
        }).unwrap();
        let plain = f64::from(estimate_yards_stockinette(w as f32, l as f32, g));
        prop_assert!((y.value.yards - plain).abs() <= 1e-6 * plain.max(1.0));
        prop_assert!(y.has_defaults(), "the buffer and the rule of thumb are defaults");
        // The same length in inches gives the same cast-on within a stitch.
        let t2 = cast_on_traced(&CastOnRequest {
            swatch: None,
            gauge: Origin::Entered(CountOver::new(sts, Length::cm(10.0))),
            width: Length::cm(w).converted(LengthUnit::Inch),
            ease: Length::cm(ease).converted(LengthUnit::Inch),
            repeat: 1,
        }).unwrap();
        let t1 = cast_on(w as f32, ease as f32, g, 1);
        prop_assert!((i64::from(t2.value) - i64::from(t1)).abs() <= 1);
    }
}
