//! Property tests of the warp, weft and finishing worksheet (`ply_weave::worksheet`, ADR 0019): it
//! never panics and never shows a figure that is not a finite number, whatever the plan or the
//! records hold; and more of a loss, of loom waste or of weft allowance never needs less yarn.
//!
//! Run: `cargo test -p ply-weave --test worksheet_proptest`

use ply_common::materials::{Material, Swatch};
use ply_common::provenance::Recorded;
use ply_common::quantity::{CountOver, Length, LengthPerMass, LengthUnit, Mass, MassUnit};
use ply_common::{CraftKind, Unit};
use ply_weave::feasibility::Sett;
use ply_weave::loom::{DentUnit, LoomProfile, Reed};
use ply_weave::worksheet::{
    work_out, DraftFacts, PlanOverrides, PlanStructure, WeavePlan, Worksheet, WorksheetRequest,
};
use proptest::prelude::*;

fn any_f64() -> BoxedStrategy<f64> {
    prop_oneof![
        4 => 0.01f64..500.0,
        1 => -1.0f64..1.0,
        1 => Just(0.0),
        1 => Just(-5.0),
        1 => Just(f64::NAN),
        1 => Just(f64::INFINITY),
        1 => Just(1e300),
        1 => any::<f64>(),
    ]
    .boxed()
}

fn opt<T: std::fmt::Debug + Clone + 'static>(
    s: impl Strategy<Value = T> + 'static,
) -> BoxedStrategy<Option<T>> {
    prop_oneof![1 => Just(None), 3 => s.prop_map(Some)].boxed()
}

fn unit() -> impl Strategy<Value = LengthUnit> {
    prop_oneof![
        Just(LengthUnit::Millimeter),
        Just(LengthUnit::Centimeter),
        Just(LengthUnit::Meter),
        Just(LengthUnit::Inch),
        Just(LengthUnit::Yard),
    ]
}

fn length() -> BoxedStrategy<Length> {
    (any_f64(), unit())
        .prop_map(|(v, u)| Length::new(v, u))
        .boxed()
}

fn count() -> BoxedStrategy<CountOver> {
    (any_f64(), length())
        .prop_map(|(c, l)| CountOver::new(c, l))
        .boxed()
}

fn count_u32() -> impl Strategy<Value = u32> {
    prop_oneof![3 => 0u32..2_000, 1 => any::<u32>()]
}

prop_compose! {
    fn overrides()(
        a in opt(any_f64()), b in opt(any_f64()), c in opt(any_f64()), d in opt(any_f64()),
        e in opt(any_f64()), waste in opt(length()), sett in opt(count()), wpi in opt(count()),
        ppi in opt(count()), ends in opt(count_u32()),
        reed in opt((any_f64(), any::<bool>()).prop_map(|(dents, metric)| Reed {
            dents,
            per: if metric { DentUnit::Per10Cm } else { DentUnit::PerInch },
        })),
    ) -> PlanOverrides {
        PlanOverrides {
            take_up: a,
            length_shrinkage: b,
            draw_in: c,
            width_shrinkage: d,
            weft_allowance: e,
            loom_waste: waste,
            sett,
            wpi,
            ppi,
            ends,
            reed,
        }
    }
}

prop_compose! {
    fn plan()(
        structure in prop_oneof![
            Just(PlanStructure::Plain), Just(PlanStructure::Twill), Just(PlanStructure::Satin),
            Just(PlanStructure::Other),
        ],
        items in count_u32(),
        fw in opt(length()), fl in opt(length()), hems in opt(length()), fringe in opt(length()),
        sampling in opt(length()), multiple in opt(count_u32()), extra in count_u32(),
        overrides in overrides(),
    ) -> WeavePlan {
        WeavePlan {
            structure,
            items,
            finished_width: fw,
            finished_length: fl,
            hems,
            fringe,
            sampling,
            end_multiple: multiple,
            extra_ends: extra,
            overrides,
            ..Default::default()
        }
    }
}

fn rec_length() -> impl Strategy<Value = Option<Recorded<Length>>> {
    opt(length().prop_map(Recorded::measured))
}

prop_compose! {
    fn swatch()(
        sett in opt(count().prop_map(Recorded::entered)),
        reed in rec_length(), w1 in rec_length(), l1 in rec_length(), w2 in rec_length(),
        l2 in rec_length(), w3 in rec_length(), l3 in rec_length(),
        picks in opt(count().prop_map(Recorded::measured)),
        knit in any::<bool>(),
    ) -> Swatch {
        let mut s = Swatch::new("s", "Sample");
        s.craft = Some(if knit { CraftKind::Knitting } else { CraftKind::Weaving });
        s.sett = sett;
        s.width_in_reed = reed;
        s.on_loom.width = w1;
        s.on_loom.length = l1;
        s.on_loom.along = picks;
        s.before.width = w2;
        s.before.length = l2;
        s.after.width = w3;
        s.after.length = l3;
        s
    }
}

prop_compose! {
    fn material()(
        lpm in opt((length(), any_f64()).prop_map(|(l, g)| {
            Recorded::entered(LengthPerMass::new(l, Mass::new(g, MassUnit::Gram)))
        })),
        wpi in opt(count().prop_map(Recorded::measured)),
        mass in opt(any_f64().prop_map(|g| Recorded::measured(Mass::new(g, MassUnit::Ounce)))),
        len in opt(length().prop_map(Recorded::entered)),
    ) -> Material {
        let mut m = Material::new("m", "Yarn");
        m.length_per_mass = lpm;
        m.wpi = wpi;
        m.available_mass = mass;
        m.available_length = len;
        m
    }
}

fn all_finite(w: &Worksheet) -> bool {
    w.figures.iter().all(|f| f.value.is_finite())
        && w.supply.iter().all(|s| {
            s.need.value.is_finite()
                && s.need_mass.is_none_or(|m| m.value.is_finite())
                && s.on_hand.is_none_or(|l| l.value.is_finite())
                && s.remaining.is_none_or(|l| l.value.is_finite())
        })
        && w.denting.as_ref().is_none_or(|d| d.width.value.is_finite())
}

/// A towel plan with every input usable, for the monotonicity properties.
fn base() -> WeavePlan {
    WeavePlan {
        structure: PlanStructure::Twill,
        items: 3,
        finished_width: Some(Length::inches(18.0)),
        finished_length: Some(Length::inches(30.0)),
        hems: Some(Length::inches(4.0)),
        sampling: Some(Length::inches(10.0)),
        end_multiple: Some(4),
        extra_ends: 2,
        overrides: PlanOverrides {
            sett: Some(CountOver::new(24.0, Length::inches(1.0))),
            ..Default::default()
        },
        ..Default::default()
    }
}

fn worked(plan: &WeavePlan) -> Worksheet {
    work_out(&WorksheetRequest {
        plan,
        swatch: None,
        warp: None,
        weft: None,
        loom: None,
        loom_sett: None,
        draft: DraftFacts::default(),
        metric: false,
    })
}

fn value(w: &Worksheet, key: &str) -> f64 {
    w.figure(key)
        .unwrap_or_else(|| panic!("{key}: {:?}", w.issues))
        .value
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(512))]

    #[test]
    fn never_panics_and_every_figure_is_finite(
        plan in plan(),
        swatch in opt(swatch()),
        warp in opt(material()),
        weft in opt(material()),
        loom_sett in opt(any_f64()),
        file_sett in opt(any_f64()),
        ends in prop_oneof![Just(0usize), 1usize..5000, Just(usize::MAX)],
        strands in any_f64(),
        width in opt(any_f64()),
        reeds in proptest::collection::vec(any_f64(), 0..3),
        metric in any::<bool>(),
    ) {
        let mut loom = LoomProfile::new("l", "Loom");
        loom.weaving_width = width.map(|value| ply_weave::loom::Length { value, unit: Unit::Inches });
        loom.reeds = reeds.into_iter().map(|dents| Reed { dents, per: DentUnit::PerInch }).collect();
        let w = work_out(&WorksheetRequest {
            plan: &plan,
            swatch: swatch.as_ref(),
            warp: warp.as_ref(),
            weft: weft.as_ref(),
            loom: Some(&loom),
            loom_sett: loom_sett.map(|ends| Sett { ends, per: Unit::Inches }),
            draft: DraftFacts {
                ends,
                mean_strands: strands,
                file_sett: file_sett.map(|ends| Sett { ends, per: Unit::Centimeters }),
            },
            metric,
        });
        prop_assert!(all_finite(&w), "{:?}", w.figures);
        for f in &w.figures {
            prop_assert!(!f.text.contains("NaN") && !f.text.contains("inf"), "{}", f.text);
        }
        for i in &w.issues {
            prop_assert!(!i.message.is_empty() && !i.field.is_empty());
        }
    }

    /// More take-up or length shrinkage never needs less warp or weft.
    #[test]
    fn more_length_loss_never_needs_less(
        a in -0.5f64..0.9, b in -0.5f64..0.9, more in 0.0f64..0.4, shrink in any::<bool>(),
    ) {
        let mut p = base();
        p.overrides.take_up = Some(a);
        p.overrides.length_shrinkage = Some(b);
        let lo = worked(&p);
        if shrink {
            p.overrides.length_shrinkage = Some((b + more).min(0.9));
        } else {
            p.overrides.take_up = Some((a + more).min(0.9));
        }
        let hi = worked(&p);
        for key in ["woven_length", "warp_length", "warp_yarn", "weft_picks", "weft_yarn"] {
            prop_assert!(value(&hi, key) >= value(&lo, key), "{key}");
        }
    }

    /// More draw-in or width shrinkage never needs fewer ends or less yarn.
    #[test]
    fn more_width_loss_never_needs_less(
        a in -0.5f64..0.9, b in -0.5f64..0.9, more in 0.0f64..0.4, shrink in any::<bool>(),
    ) {
        let mut p = base();
        p.overrides.draw_in = Some(a);
        p.overrides.width_shrinkage = Some(b);
        let lo = worked(&p);
        if shrink {
            p.overrides.width_shrinkage = Some((b + more).min(0.9));
        } else {
            p.overrides.draw_in = Some((a + more).min(0.9));
        }
        let hi = worked(&p);
        for key in ["warp_ends", "width_in_reed", "warp_yarn", "weft_yarn"] {
            prop_assert!(value(&hi, key) >= value(&lo, key), "{key}");
        }
    }

    /// More loom waste, fringe or weft allowance never needs less.
    #[test]
    fn more_allowance_never_needs_less(
        waste in 0.0f64..100.0, extra in 0.0f64..50.0, allowance in 0.0f64..1.5,
        fringe in 0.0f64..30.0,
    ) {
        let mut p = base();
        p.overrides.loom_waste = Some(Length::inches(waste));
        p.overrides.weft_allowance = Some(allowance);
        p.fringe = Some(Length::inches(fringe));
        let lo = worked(&p);
        p.overrides.loom_waste = Some(Length::inches(waste + extra));
        p.fringe = Some(Length::inches(fringe + extra));
        p.overrides.weft_allowance = Some((allowance + extra / 100.0).min(2.0));
        let hi = worked(&p);
        prop_assert!(value(&hi, "warp_length") >= value(&lo, "warp_length"));
        prop_assert!(value(&hi, "warp_yarn") >= value(&lo, "warp_yarn"));
        prop_assert!(value(&hi, "weft_yarn") >= value(&lo, "weft_yarn"));
        prop_assert_eq!(value(&hi, "weft_picks"), value(&lo, "weft_picks"));
    }

    /// Overriding one assumption changes that input alone: every other input reads the same.
    #[test]
    fn one_override_changes_one_input(v in -0.5f64..0.9, which in 0usize..4) {
        let p = base();
        let lo = worked(&p);
        let mut q = base();
        let key = match which {
            0 => { q.overrides.take_up = Some(v); "take_up" }
            1 => { q.overrides.length_shrinkage = Some(v); "length_shrinkage" }
            2 => { q.overrides.draw_in = Some(v); "draw_in" }
            _ => { q.overrides.width_shrinkage = Some(v); "width_shrinkage" }
        };
        let hi = worked(&q);
        let others = |w: &Worksheet| -> Vec<(String, String, String)> {
            w.inputs.iter().filter(|i| i.key != key)
                .map(|i| (i.key.clone(), i.value.clone(), i.basis.clone())).collect()
        };
        prop_assert_eq!(others(&lo), others(&hi));
        prop_assert_eq!(&hi.input(key).unwrap().basis, "you entered it");
    }
}
