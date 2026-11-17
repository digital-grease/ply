//! Knitting planning estimates that show their working (roadmap M8-01, ADR 0016): the calculators of
//! [`crate::calc`] (cast-on for a width, yarn for a rectangle), fed from a swatch, a typed gauge or
//! one of Ply's defaults, and returned with every input, its source, and the arithmetic in words.
//!
//! The numbers are the calculators' own: these functions convert the inputs into the calculators'
//! units and call them, so an estimate with a swatch gives exactly what the calculator gives for the
//! same gauge. A swatch is read, never changed.

use crate::calc::{cast_on, estimate_yards_from_swatch, estimate_yards_stockinette};
use crate::pattern::Gauge;
use ply_common::materials::{Material, StageKind, Swatch};
use ply_common::provenance::{Origin, PlanProblem, Source, Traced, TracedInput};
use ply_common::quantity::{
    number, percent, signed_problem, CountOver, Length, LengthUnit, MassUnit,
};
use ply_common::{CraftKind, Unit};

/// A cast-on for a finished width.
#[derive(Debug, Clone, PartialEq)]
pub struct CastOnRequest<'a> {
    /// The swatch the gauge may come from.
    pub swatch: Option<&'a Swatch>,
    /// The stitch gauge (stitches over a span).
    pub gauge: Origin<CountOver>,
    pub width: Length,
    /// Ease: added to the width (negative for a close fit).
    pub ease: Length,
    /// The stitch repeat the count is rounded to (1 = none).
    pub repeat: u32,
}

/// A yarn estimate for a rectangle.
#[derive(Debug, Clone, PartialEq)]
pub struct YardageRequest<'a> {
    pub swatch: Option<&'a Swatch>,
    pub gauge: Origin<CountOver>,
    pub width: Length,
    pub length: Length,
    /// The swatch's yarn, when the swatch names exactly one material: its length per mass turns the
    /// swatch's weight into length (the weighed-swatch method).
    pub yarn: Option<&'a Material>,
    /// The planning buffer as a fraction (0.1 = 10%).
    pub buffer: Origin<f64>,
}

/// How a yarn estimate was worked out.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum YardageMethod {
    /// The swatch's mass per area, scaled to the project and turned into length by the yarn's
    /// length per mass. The most direct estimate.
    WeighedSwatch,
    /// The stockinette rule of thumb, yards about width x length x stitches per inch / 6 (inches).
    StockinetteRule,
}

/// A yarn estimate.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct YarnAmount {
    pub method: YardageMethod,
    pub yards: f64,
    pub meters: f64,
    /// With the buffer.
    pub buffered_yards: f64,
    pub buffered_meters: f64,
}

const YD_IN_M: f64 = 0.9144;

fn problem(what: &str) -> PlanProblem {
    PlanProblem(what.to_string())
}

/// The stitch gauge to use, with its traced input and any caveat.
fn resolve_gauge(
    swatch: Option<&Swatch>,
    gauge: &Origin<CountOver>,
) -> Result<(CountOver, TracedInput, Vec<String>), PlanProblem> {
    let mut notes = Vec::new();
    let (g, input) = match gauge {
        Origin::Swatch => {
            let s = swatch.ok_or_else(|| problem("Choose a swatch to take the gauge from."))?;
            if matches!(
                s.craft,
                Some(CraftKind::Weaving)
                    | Some(CraftKind::Nalbinding)
                    | Some(CraftKind::TabletWeaving)
            ) {
                return Err(PlanProblem(format!(
                    "{} is not a knitting swatch, so it has no knitting gauge.",
                    capitalize(&s.citation())
                )));
            }
            let (rec, stage) = s.planning_across().ok_or_else(|| {
                PlanProblem(format!(
                    "{} has no stitch count, so it cannot give a gauge.",
                    capitalize(&s.citation())
                ))
            })?;
            if stage == StageKind::Before {
                notes.push(
                    "The gauge was measured before finishing: the finished fabric may come out a \
                     different size. Wash or block the swatch and measure it again to be sure."
                        .to_string(),
                );
            }
            (
                rec.value,
                TracedInput {
                    key: "stitch_gauge".into(),
                    label: "Stitch gauge".into(),
                    value: rec.value.describe("sts"),
                    source: rec.source,
                    basis: s.basis(rec.source, Some(stage)),
                    swatch_id: Some(s.id.clone()),
                    material_id: None,
                },
            )
        }
        other => other
            .traced("stitch_gauge", "Stitch gauge", |g: CountOver| {
                g.describe("sts")
            })
            .expect("not a swatch origin"),
    };
    if g.problem().is_some() {
        return Err(problem(
            "The stitch gauge must be a count above 0 over a span above 0.",
        ));
    }
    Ok((g, input, notes))
}

/// The calculators work in inches or centimetres: the family of `unit`.
fn working_unit(unit: LengthUnit) -> (Unit, LengthUnit) {
    if unit.is_metric() {
        (Unit::Centimeters, LengthUnit::Centimeter)
    } else {
        (Unit::Inches, LengthUnit::Inch)
    }
}

/// `g` as the calculators' gauge (stitches per 4 in or per 10 cm) in `unit`.
fn as_gauge(g: CountOver, unit: Unit) -> Gauge {
    let window = match unit {
        Unit::Inches => Length::inches(4.0),
        Unit::Centimeters => Length::cm(10.0),
    };
    let sts = g.per(window) as f32;
    Gauge {
        sts,
        rows: sts,
        unit,
    }
}

fn length_problem(what: &str, l: Length) -> Result<(), PlanProblem> {
    match l.problem() {
        Some(p) => Err(PlanProblem(format!("The {what} {}.", p.phrase()))),
        None => Ok(()),
    }
}

/// [`crate::calc::cast_on`] with its working: the cast-on for `width` plus `ease` at the gauge,
/// rounded to a whole stitch and to the nearest multiple of the repeat. 0 when the width is too
/// small for the gauge (as the calculator gives).
pub fn cast_on_traced(req: &CastOnRequest) -> Result<Traced<u32>, PlanProblem> {
    let (g, gauge_input, notes) = resolve_gauge(req.swatch, &req.gauge)?;
    length_problem("finished width", req.width)?;
    if let Some(p) = signed_problem(req.ease.value) {
        return Err(PlanProblem(format!("The ease {}.", p.phrase())));
    }
    let (unit, lu) = working_unit(req.width.unit);
    let width = req.width.to(lu) as f32;
    let ease = req.ease.to(lu) as f32;
    let gauge = as_gauge(g, unit);
    let repeat = req.repeat.max(1);
    let n = cast_on(width, ease, gauge, repeat);
    let spu = gauge.sts_per_unit();
    let target = width + ease;
    let sym = lu.symbol();
    let mut working = vec![format!(
        "{} is {} sts per {sym}.",
        g.describe("sts"),
        number(f64::from(spu))
    )];
    working.push(format!(
        "({} {sym} + {} {sym}) x {} sts per {sym} = {} sts, rounded to {} sts.",
        number(f64::from(width)),
        number(f64::from(ease)),
        number(f64::from(spu)),
        number(f64::from(target * spu)),
        number(f64::from((target * spu).round().max(0.0)))
    ));
    if repeat > 1 {
        working.push(format!(
            "Rounded to the nearest multiple of {repeat}: {n} sts."
        ));
    }
    let mut notes = notes;
    if n == 0 {
        notes.push("The width is too small for this gauge.".to_string());
    }
    Ok(Traced {
        value: n,
        inputs: vec![
            gauge_input,
            TracedInput::entered("width", "Finished width", req.width.describe()),
            TracedInput::entered("ease", "Ease", req.ease.describe()),
            TracedInput::entered("repeat", "Stitch repeat", format!("multiple of {repeat}")),
        ],
        working,
        notes,
    })
}

/// A yarn estimate for a `width` x `length` rectangle, with its working: by the weighed swatch when
/// the gauge comes from a swatch that was weighed and measured whole and has one yarn with a length
/// per mass, otherwise by the stockinette rule of thumb at the gauge ([`crate::calc`]).
pub fn yardage_traced(req: &YardageRequest) -> Result<Traced<YarnAmount>, PlanProblem> {
    length_problem("width", req.width)?;
    length_problem("length", req.length)?;
    let (buffer, buffer_input) = match &req.buffer {
        Origin::Swatch => return Err(problem("A swatch does not give a buffer.")),
        other => other
            .traced("buffer", "Buffer", percent)
            .expect("not a swatch origin"),
    };
    if !buffer.is_finite() || !(0.0..=10.0).contains(&buffer) {
        return Err(problem("The buffer must be 0% or more."));
    }
    let mut notes = Vec::new();
    let mut inputs = Vec::new();
    let mut working = Vec::new();
    let weighed = if req.gauge == Origin::Swatch {
        weighed_inputs(req, &mut notes)
    } else {
        None
    };
    let (method, yards) = if let Some(w) = weighed {
        let (s, mass, (stage, area_cm2), yarn, lpm) = w;
        let project_cm2 =
            req.width.to(LengthUnit::Centimeter) * req.length.to(LengthUnit::Centimeter);
        let grams = mass.value.to(MassUnit::Gram);
        let skein_yards = lpm.value.length.to(LengthUnit::Yard);
        let skein_grams = lpm.value.mass.to(MassUnit::Gram);
        let yards = f64::from(estimate_yards_from_swatch(
            grams as f32,
            area_cm2 as f32,
            project_cm2 as f32,
            skein_yards as f32,
            skein_grams as f32,
        ));
        inputs.push(TracedInput {
            key: "swatch_mass".into(),
            label: "Swatch mass".into(),
            value: mass.value.describe(),
            source: mass.source,
            basis: s.basis(mass.source, None),
            swatch_id: Some(s.id.clone()),
            material_id: None,
        });
        inputs.push(TracedInput {
            key: "swatch_area".into(),
            label: "Swatch area".into(),
            value: format!("{} sq cm", number(area_cm2)),
            source: Source::Measured,
            basis: format!("width x length {}", s.basis(Source::Measured, Some(stage))),
            swatch_id: Some(s.id.clone()),
            material_id: None,
        });
        inputs.push(TracedInput::entered("width", "Width", req.width.describe()));
        inputs.push(TracedInput::entered(
            "length",
            "Length",
            req.length.describe(),
        ));
        inputs.push(TracedInput {
            key: "length_per_mass".into(),
            label: "Yarn length per mass".into(),
            value: lpm.value.describe(),
            source: lpm.source,
            basis: format!("{}, material {}", lpm.source.as_str(), yarn.display_name()),
            swatch_id: None,
            material_id: Some(yarn.id.clone()),
        });
        let grams_needed = grams / area_cm2 * project_cm2;
        working.push(format!(
            "The swatch weighs {} over {} sq cm, {} g per 100 sq cm.",
            mass.value.describe(),
            number(area_cm2),
            number(grams / area_cm2 * 100.0)
        ));
        working.push(format!(
            "{} x {} is {} sq cm, so about {} g.",
            req.width.describe(),
            req.length.describe(),
            number(project_cm2),
            number(grams_needed)
        ));
        working.push(format!(
            "At {}, {} g is about {} yd ({} m).",
            lpm.value.describe(),
            number(grams_needed),
            number(yards),
            number(yards * YD_IN_M)
        ));
        (YardageMethod::WeighedSwatch, yards)
    } else {
        let (g, gauge_input, gauge_notes) = resolve_gauge(req.swatch, &req.gauge)?;
        notes.extend(gauge_notes);
        let (unit, lu) = working_unit(req.width.unit);
        let gauge = as_gauge(g, unit);
        let w = req.width.to(lu) as f32;
        let l = req.length.to(lu) as f32;
        let yards = f64::from(estimate_yards_stockinette(w, l, gauge));
        let sts_per_in = g.per_unit(LengthUnit::Inch);
        inputs.push(gauge_input);
        inputs.push(TracedInput::entered("width", "Width", req.width.describe()));
        inputs.push(TracedInput::entered(
            "length",
            "Length",
            req.length.describe(),
        ));
        inputs.push(TracedInput::default(
            "method",
            "Method",
            "stockinette rule of thumb".to_string(),
            "(yards about width x length in inches x stitches per inch / 6)",
        ));
        working.push(format!(
            "{} x {} at {} sts per in: about {} yd ({} m).",
            req.width.converted(LengthUnit::Inch).describe(),
            req.length.converted(LengthUnit::Inch).describe(),
            number(sts_per_in),
            number(yards),
            number(yards * YD_IN_M)
        ));
        notes.push(
            "A rough estimate for stockinette: textured stitches and cables use more. Weigh your \
             swatch for a closer one."
                .to_string(),
        );
        (YardageMethod::StockinetteRule, yards)
    };
    inputs.push(buffer_input);
    let buffered = yards * (1.0 + buffer);
    working.push(format!(
        "With a {} buffer: about {} yd ({} m).",
        percent(buffer),
        number(buffered),
        number(buffered * YD_IN_M)
    ));
    Ok(Traced {
        value: YarnAmount {
            method,
            yards,
            meters: yards * YD_IN_M,
            buffered_yards: buffered,
            buffered_meters: buffered * YD_IN_M,
        },
        inputs,
        working,
        notes,
    })
}

type Weighed<'a> = (
    &'a Swatch,
    ply_common::provenance::Recorded<ply_common::quantity::Mass>,
    (StageKind, f64),
    &'a Material,
    ply_common::provenance::Recorded<ply_common::quantity::LengthPerMass>,
);

/// The weighed-swatch inputs, when the swatch has them; otherwise a note says what is missing.
fn weighed_inputs<'a>(req: &YardageRequest<'a>, notes: &mut Vec<String>) -> Option<Weighed<'a>> {
    let s = req.swatch?;
    if matches!(
        s.craft,
        Some(CraftKind::Weaving) | Some(CraftKind::Nalbinding) | Some(CraftKind::TabletWeaving)
    ) {
        return None; // resolve_gauge refuses it with the reason
    }
    let mass = s.mass.filter(|m| m.value.problem().is_none());
    let area = s.area_cm2();
    let lpm = req
        .yarn
        .and_then(|y| y.length_per_mass.filter(|l| l.value.problem().is_none()));
    let named = s.yarns.iter().filter(|y| y.material_id.is_some()).count();
    match (mass, area, req.yarn, lpm) {
        (Some(m), Some(a), Some(y), Some(l)) if s.yarns.len() == 1 => Some((s, m, a, y, l)),
        _ => {
            if mass.is_some() || s.yarns.len() > 1 || named > 0 {
                let why = if s.yarns.len() > 1 {
                    "it uses more than one yarn"
                } else if mass.is_none() {
                    "it was not weighed"
                } else if area.is_none() {
                    "its width and length are not both recorded"
                } else {
                    "its yarn has no length per mass"
                };
                notes.push(format!(
                    "The weighed-swatch estimate needs {} weighed and measured whole with one yarn \
                     of known length per mass, but {why}.",
                    s.citation()
                ));
            }
            None
        }
    }
}

fn capitalize(s: &str) -> String {
    let mut c = s.chars();
    match c.next() {
        Some(f) => f.to_uppercase().collect::<String>() + c.as_str(),
        None => String::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ply_common::materials::{Stage, SwatchYarn};
    use ply_common::provenance::Recorded;
    use ply_common::quantity::{LengthPerMass, Mass};

    fn swatch() -> Swatch {
        let mut s = Swatch::new("sw", "Grey wool");
        s.craft = Some(CraftKind::Knitting);
        s.date = Some("2026-11-10".into());
        s.finishing = "washed, dried flat".into();
        s.before.across = Some(Recorded::measured(CountOver::new(22.0, Length::cm(10.0))));
        s.after = Stage {
            width: Some(Recorded::measured(Length::cm(15.0))),
            length: Some(Recorded::measured(Length::cm(15.0))),
            across: Some(Recorded::measured(CountOver::new(20.0, Length::cm(10.0)))),
            along: None,
            conditions: String::new(),
        };
        s.mass = Some(Recorded::measured(Mass::grams(9.0)));
        s.yarns = vec![SwatchYarn {
            material_id: Some("wool".into()),
            name: "Grey wool".into(),
            role: None,
        }];
        s
    }

    fn yarn() -> Material {
        let mut m = Material::new("wool", "Grey wool");
        m.length_per_mass = Some(Recorded::entered(LengthPerMass::new(
            Length::new(200.0, LengthUnit::Meter),
            Mass::grams(100.0),
        )));
        m
    }

    #[test]
    fn cast_on_from_a_swatch_cites_it_and_matches_the_calculator() {
        let s = swatch();
        let t = cast_on_traced(&CastOnRequest {
            swatch: Some(&s),
            gauge: Origin::Swatch,
            width: Length::cm(50.0),
            ease: Length::cm(5.0),
            repeat: 4,
        })
        .unwrap();
        // 55 cm x 2 sts per cm = 110, rounded to a multiple of 4: 112.
        assert_eq!(t.value, 112);
        let plain = cast_on(
            50.0,
            5.0,
            Gauge {
                sts: 20.0,
                rows: 20.0,
                unit: Unit::Centimeters,
            },
            4,
        );
        assert_eq!(t.value, plain);
        assert_eq!(
            t.inputs[0].sentence(),
            "20 sts per 10 cm, measured after finishing (washed, dried flat), swatch Grey wool \
             2026-11-10"
        );
        assert_eq!(t.inputs[0].source, Source::Measured);
        assert_eq!(t.inputs[0].swatch_id.as_deref(), Some("sw"));
        assert!(t.notes.is_empty());
        assert!(!t.has_defaults());
    }

    #[test]
    fn a_default_gauge_says_so() {
        let t = cast_on_traced(&CastOnRequest {
            swatch: None,
            gauge: Origin::Default(CountOver::new(22.0, Length::cm(10.0)), "for DK".into()),
            width: Length::cm(50.0),
            ease: Length::cm(0.0),
            repeat: 1,
        })
        .unwrap();
        assert_eq!(t.value, 110);
        assert_eq!(
            t.inputs[0].sentence(),
            "22 sts per 10 cm, Ply's default for DK"
        );
        assert!(t.has_defaults());
    }

    #[test]
    fn a_gauge_before_finishing_carries_a_caveat() {
        let mut s = swatch();
        s.after.across = None;
        let t = cast_on_traced(&CastOnRequest {
            swatch: Some(&s),
            gauge: Origin::Swatch,
            width: Length::inches(20.0),
            ease: Length::inches(2.0),
            repeat: 1,
        })
        .unwrap();
        assert!(t.inputs[0].basis.starts_with("measured before finishing"));
        assert_eq!(t.notes.len(), 1);
        // 22 sts per 10 cm is 22.352 sts per 4 in: 22 in x 5.588 = 122.9, so 123.
        assert_eq!(t.value, 123);
    }

    #[test]
    fn unusable_requests_are_refused_in_words() {
        let mut weaving = swatch();
        weaving.craft = Some(CraftKind::Weaving);
        for req in [
            CastOnRequest {
                swatch: None,
                gauge: Origin::Swatch,
                width: Length::cm(10.0),
                ease: Length::cm(0.0),
                repeat: 1,
            },
            CastOnRequest {
                swatch: Some(&weaving),
                gauge: Origin::Swatch,
                width: Length::cm(10.0),
                ease: Length::cm(0.0),
                repeat: 1,
            },
            CastOnRequest {
                swatch: None,
                gauge: Origin::Entered(CountOver::new(0.0, Length::cm(10.0))),
                width: Length::cm(10.0),
                ease: Length::cm(0.0),
                repeat: 1,
            },
            CastOnRequest {
                swatch: None,
                gauge: Origin::Entered(CountOver::new(20.0, Length::cm(10.0))),
                width: Length::cm(f64::NAN),
                ease: Length::cm(0.0),
                repeat: 1,
            },
        ] {
            assert!(cast_on_traced(&req).is_err());
        }
    }

    #[test]
    fn yardage_uses_the_weighed_swatch_when_it_can() {
        let s = swatch();
        let y = yarn();
        let t = yardage_traced(&YardageRequest {
            swatch: Some(&s),
            gauge: Origin::Swatch,
            width: Length::cm(50.0),
            length: Length::cm(60.0),
            yarn: Some(&y),
            buffer: Origin::Default(0.1, "".into()),
        })
        .unwrap();
        assert_eq!(t.value.method, YardageMethod::WeighedSwatch);
        // 9 g over 225 sq cm = 0.04 g per sq cm; 3000 sq cm = 120 g; at 2 m per g = 240 m.
        assert!((t.value.meters - 240.0).abs() < 0.05, "{}", t.value.meters);
        assert!((t.value.buffered_meters - 264.0).abs() < 0.05);
        let keys: Vec<_> = t.inputs.iter().map(|i| i.key.as_str()).collect();
        assert_eq!(
            keys,
            vec![
                "swatch_mass",
                "swatch_area",
                "width",
                "length",
                "length_per_mass",
                "buffer"
            ]
        );
        assert_eq!(
            t.inputs[4].sentence(),
            "200 m per 100 g, entered, material Grey wool"
        );
        assert_eq!(t.inputs[5].sentence(), "10%, Ply's default");
    }

    #[test]
    fn yardage_falls_back_to_the_rule_and_says_why() {
        let mut s = swatch();
        s.mass = None;
        let y = yarn();
        let t = yardage_traced(&YardageRequest {
            swatch: Some(&s),
            gauge: Origin::Swatch,
            width: Length::inches(8.0),
            length: Length::inches(8.0),
            yarn: Some(&y),
            buffer: Origin::Entered(0.15),
        })
        .unwrap();
        assert_eq!(t.value.method, YardageMethod::StockinetteRule);
        let expect = f64::from(estimate_yards_stockinette(
            8.0,
            8.0,
            Gauge {
                sts: as_gauge(CountOver::new(20.0, Length::cm(10.0)), Unit::Inches).sts,
                rows: 0.0,
                unit: Unit::Inches,
            },
        ));
        assert!((t.value.yards - expect).abs() < 1e-6);
        assert!(t.notes.iter().any(|n| n.contains("it was not weighed")));
        assert!(t
            .inputs
            .iter()
            .any(|i| i.key == "method" && i.source == Source::Default));
    }
}
