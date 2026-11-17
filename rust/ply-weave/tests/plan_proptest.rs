//! Property tests of the weaving estimates that show their working (`ply_weave::plan`, ADR 0016):
//! they never panic on any input, and with typed inputs they give exactly the calculator's numbers
//! (`ply_weave::calc`).
//!
//! Run: `cargo test -p ply-weave --test plan_proptest`

use ply_common::provenance::Origin;
use ply_common::quantity::{CountOver, Length, LengthUnit};
use ply_weave::calc::{estimate_warp, estimate_weft, WarpPlan, WeftPlan};
use ply_weave::plan::{warp_traced, weft_traced, WarpRequest, WeftRequest};
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
    fn never_panics(a in any_f64(), b in any_f64(), c in any_f64(), d in any_f64(),
            n in any::<u32>(), m in any::<u32>()) {
        let _ = warp_traced(&WarpRequest {
            swatch: None,
            finished_length: Length::new(a, LengthUnit::Yard),
            items: n,
            ends: Origin::Entered(m),
            sett_width: Some(Length::inches(b)),
            loom_waste: Origin::Entered(Length::new(c, LengthUnit::Yard)),
            allowance: Origin::Entered(d),
        });
        let _ = weft_traced(&WeftRequest {
            swatch: None,
            ppi: Origin::Entered(CountOver::new(a, Length::inches(b))),
            width: Length::inches(c),
            woven_length: Length::new(d, LengthUnit::Meter),
            items: n,
            takeup: Origin::Entered(d),
            mean_strands: a,
        });
    }

    #[test]
    fn typed_inputs_give_the_calculators_numbers(fl in 0.1f64..20.0, items in 1u32..20,
            ends in 1u32..2000, waste in 0.0f64..2.0, t in 0.0f64..0.5, ppi in 4.0f64..60.0,
            w in 1.0f64..60.0, wl in 1.0f64..200.0) {
        let tr = warp_traced(&WarpRequest {
            swatch: None,
            finished_length: Length::new(fl, LengthUnit::Yard),
            items,
            ends: Origin::Entered(ends),
            sett_width: None,
            loom_waste: Origin::Entered(Length::new(waste, LengthUnit::Yard)),
            allowance: Origin::Entered(t),
        }).unwrap();
        let plain = estimate_warp(&WarpPlan { finished_length: fl as f32, items, ends,
            loom_waste: waste as f32, takeup_shrinkage: t as f32 });
        prop_assert_eq!(tr.value.warp_length.value, f64::from(plain.warp_length));
        prop_assert_eq!(tr.value.total.value, f64::from(plain.total_warp));
        let wt = weft_traced(&WeftRequest {
            swatch: None,
            ppi: Origin::Entered(CountOver::new(ppi, Length::inches(1.0))),
            width: Length::inches(w),
            woven_length: Length::inches(wl),
            items,
            takeup: Origin::Entered(t),
            mean_strands: 1.0,
        }).unwrap();
        let plain = estimate_weft(&WeftPlan { picks_per_unit: ppi as f32, width: w as f32,
            woven_length: wl as f32, items, takeup: t as f32 });
        prop_assert_eq!(wt.value.picks, plain.picks);
        prop_assert_eq!(wt.value.total.value, f64::from(plain.total_weft));
    }
}
