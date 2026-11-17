//! Weaving planning estimates that show their working (roadmap M8-01, ADR 0016): the warp and weft
//! calculators of [`crate::calc`], fed from a swatch, typed numbers, the draft, or Ply's defaults,
//! and returned with every input, its source, and the arithmetic in words.
//!
//! The numbers are the calculators' own: these functions convert the inputs into one unit and call
//! [`crate::calc::estimate_warp`] and [`crate::calc::estimate_weft`]. A swatch is read, never
//! changed. What a swatch can give:
//!
//! - the **sett in the reed**, for the warp ends across a width;
//! - the **length allowance** for take-up and shrinkage together, from its length on the loom and
//!   after wet finishing ([`Swatch::length_allowance`]: `on_loom / finished - 1`, so the finished
//!   length times one plus it is exactly the length to weave);
//! - the **picks per inch counted on the loom**, for the weft. Picks counted off the loom or after
//!   finishing sit closer together than on the loom, and the weft estimate multiplies picks by the
//!   length woven on the loom, so only the count on the loom is used.

use crate::calc::{estimate_warp, estimate_weft, WarpPlan, WeftPlan};
use ply_common::materials::Swatch;
use ply_common::provenance::{Origin, PlanProblem, Source, Traced, TracedInput};
use ply_common::quantity::{number, percent, CountOver, Length, LengthUnit};
use ply_common::CraftKind;

/// The most warp ends or items a plan takes (the editor's own ceiling).
pub const MAX_PLAN_COUNT: u32 = 100_000;

/// A warp estimate.
#[derive(Debug, Clone, PartialEq)]
pub struct WarpRequest<'a> {
    pub swatch: Option<&'a Swatch>,
    /// The finished length of one item.
    pub finished_length: Length,
    pub items: u32,
    /// The warp ends. [`Origin::Swatch`] = the swatch's sett in the reed across [`Self::sett_width`].
    pub ends: Origin<u32>,
    /// The cloth width the ends are worked out for, when they come from the swatch's sett.
    pub sett_width: Option<Length>,
    /// Loom waste for the whole warp.
    pub loom_waste: Origin<Length>,
    /// Take-up and shrinkage as a fraction of the finished length (0.1 = 10%). [`Origin::Swatch`] =
    /// the swatch's length allowance.
    pub allowance: Origin<f64>,
}

/// What a warp needs.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct WarpAmount {
    pub ends: u32,
    /// The length to wind, in the finished length's unit.
    pub warp_length: Length,
    /// All the warp yarn (warp length times ends), in the same unit.
    pub total: Length,
}

/// A weft estimate.
#[derive(Debug, Clone, PartialEq)]
pub struct WeftRequest<'a> {
    pub swatch: Option<&'a Swatch>,
    /// Picks over a span. [`Origin::Swatch`] = the picks the swatch counted on the loom.
    pub ppi: Origin<CountOver>,
    /// The width in the reed.
    pub width: Length,
    /// The length woven on the loom, per item.
    pub woven_length: Length,
    pub items: u32,
    /// Weft take-up and selvedge allowance as a fraction (0.1 = 10%).
    pub takeup: Origin<f64>,
    /// The draft's average strands per pick (1 when it records none).
    pub mean_strands: f64,
}

/// What the weft needs.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct WeftAmount {
    pub picks: u32,
    /// All the weft yarn, in the width's unit family (inches or centimetres).
    pub total: Length,
}

fn problem(s: impl Into<String>) -> PlanProblem {
    PlanProblem(s.into())
}

fn weaving_swatch<'a>(swatch: Option<&'a Swatch>, what: &str) -> Result<&'a Swatch, PlanProblem> {
    let s = swatch.ok_or_else(|| problem(format!("Choose a swatch to take the {what} from.")))?;
    if matches!(
        s.craft,
        Some(CraftKind::Knitting) | Some(CraftKind::Nalbinding) | Some(CraftKind::TabletWeaving)
    ) {
        return Err(problem(format!(
            "{} is not a weaving swatch, so it has no {what}.",
            capitalize(&s.citation())
        )));
    }
    Ok(s)
}

fn check_length(what: &str, l: Length) -> Result<(), PlanProblem> {
    match l.problem() {
        Some(p) => Err(problem(format!("The {what} {}.", p.phrase()))),
        None => Ok(()),
    }
}

fn check_count(what: &str, n: u32) -> Result<(), PlanProblem> {
    if n == 0 || n > MAX_PLAN_COUNT {
        Err(problem(format!(
            "The {what} must be a whole number from 1 to {MAX_PLAN_COUNT}."
        )))
    } else {
        Ok(())
    }
}

fn check_fraction(what: &str, f: f64) -> Result<(), PlanProblem> {
    if f.is_finite() && (0.0..=10.0).contains(&f) {
        Ok(())
    } else {
        Err(problem(format!("The {what} must be 0% or more.")))
    }
}

/// The swatch's sett in the reed across `width`: the ends and their traced input.
fn ends_from_swatch(s: &Swatch, width: Option<Length>) -> Result<(u32, TracedInput), PlanProblem> {
    let sett = s
        .sett
        .filter(|r| r.value.problem().is_none())
        .ok_or_else(|| {
            problem(format!(
                "{} has no sett in the reed recorded.",
                capitalize(&s.citation())
            ))
        })?;
    let width = width.ok_or_else(|| problem("Enter the cloth width the ends are for."))?;
    check_length("cloth width", width)?;
    let raw = sett.value.per(width).round();
    if !(1.0..=f64::from(MAX_PLAN_COUNT)).contains(&raw) {
        return Err(problem(format!(
            "{} across {} gives {} ends, outside 1 to {MAX_PLAN_COUNT}.",
            sett.value.describe("ends"),
            width.describe(),
            number(raw)
        )));
    }
    let ends = raw as u32;
    Ok((
        ends,
        TracedInput {
            key: "ends".into(),
            label: "Warp ends".into(),
            value: ends.to_string(),
            source: sett.source,
            basis: format!(
                "{} across {} (the sett in the reed, {}, {})",
                sett.value.describe("ends"),
                width.describe(),
                sett.source.as_str(),
                s.citation()
            ),
            swatch_id: Some(s.id.clone()),
            material_id: None,
        },
    ))
}

/// [`crate::calc::estimate_warp`] with its working.
pub fn warp_traced(req: &WarpRequest) -> Result<Traced<WarpAmount>, PlanProblem> {
    check_length("finished length", req.finished_length)?;
    check_count("number of items", req.items)?;
    let unit = req.finished_length.unit;
    let mut notes = Vec::new();
    let (ends, ends_input) = match &req.ends {
        Origin::Swatch => ends_from_swatch(weaving_swatch(req.swatch, "sett")?, req.sett_width)?,
        other => other
            .traced("ends", "Warp ends", |n: u32| n.to_string())
            .expect("not a swatch origin"),
    };
    check_count("number of warp ends", ends)?;
    let (waste, waste_input) = match &req.loom_waste {
        Origin::Swatch => return Err(problem("A swatch does not give the loom waste.")),
        other => other
            .traced("loom_waste", "Loom waste", |l: Length| l.describe())
            .expect("not a swatch origin"),
    };
    if waste.value != 0.0 {
        check_length("loom waste", waste)?;
    } else if !waste.value.is_finite() {
        return Err(problem("The loom waste is not a number."));
    }
    let (allowance, allowance_input) = match &req.allowance {
        Origin::Swatch => {
            let s = weaving_swatch(req.swatch, "take-up and shrinkage")?;
            let a = s.length_allowance().ok_or_else(|| {
                problem(format!(
                    "{} needs its length on the loom and after wet finishing to give the take-up \
                     and shrinkage.",
                    capitalize(&s.citation())
                ))
            })?;
            if a.fraction < 0.0 {
                notes.push(format!(
                    "{} came out longer after finishing than on the loom, so the warp is planned \
                     shorter than the finished length. Check the measurements.",
                    capitalize(&s.citation())
                ));
            }
            let source =
                if a.on_loom_source == Source::Measured && a.finished_source == Source::Measured {
                    Source::Measured
                } else {
                    Source::Entered
                };
            notes.push(format!(
                "The swatch lost {} of its length from the loom to finished ({} to {}). To finish at \
                 a length, weave it times {} / {}, which adds {}.",
                percent(a.loss),
                a.on_loom.describe(),
                a.finished.describe(),
                number(a.on_loom.value),
                number(a.finished.to(a.on_loom.unit)),
                percent(a.fraction)
            ));
            (
                a.fraction,
                TracedInput {
                    key: "length_allowance".into(),
                    label: "Take-up and shrinkage".into(),
                    value: format!("{} of the finished length", percent(a.fraction)),
                    source,
                    basis: format!(
                        "from {} on the loom and {} after wet finishing ({}), {}",
                        a.on_loom.describe(),
                        a.finished.describe(),
                        source.as_str(),
                        s.citation()
                    ),
                    swatch_id: Some(s.id.clone()),
                    material_id: None,
                },
            )
        }
        other => other
            .traced("length_allowance", "Take-up and shrinkage", |f: f64| {
                format!("{} of the finished length", percent(f))
            })
            .expect("not a swatch origin"),
    };
    if !allowance.is_finite() || !(-0.9..=10.0).contains(&allowance) {
        return Err(problem("The take-up and shrinkage must be a percentage."));
    }
    let waste_v = waste.to(unit);
    let est = estimate_warp(&WarpPlan {
        finished_length: req.finished_length.value as f32,
        items: req.items,
        ends,
        loom_waste: waste_v as f32,
        takeup_shrinkage: allowance as f32,
    });
    let warp_length = Length::new(f64::from(est.warp_length), unit);
    let total = Length::new(f64::from(est.total_warp), unit);
    let sym = unit.symbol();
    let working = vec![
        format!(
            "{} x {} x (1 + {}) + {} {sym} loom waste = {} {sym} of warp.",
            req.items,
            req.finished_length.describe(),
            percent(allowance),
            number(waste_v),
            number(warp_length.value)
        ),
        format!(
            "{} {sym} x {ends} ends = {} {sym} of warp yarn.",
            number(warp_length.value),
            number(total.value)
        ),
    ];
    Ok(Traced {
        value: WarpAmount {
            ends,
            warp_length,
            total,
        },
        inputs: vec![
            TracedInput::entered(
                "finished_length",
                "Finished length",
                req.finished_length.describe(),
            ),
            TracedInput::entered("items", "Items", req.items.to_string()),
            ends_input,
            waste_input,
            allowance_input,
        ],
        working,
        notes,
    })
}

/// [`crate::calc::estimate_weft`] (with the draft's strands per pick) with its working.
pub fn weft_traced(req: &WeftRequest) -> Result<Traced<WeftAmount>, PlanProblem> {
    check_length("width in the reed", req.width)?;
    check_length("woven length", req.woven_length)?;
    check_count("number of items", req.items)?;
    if !req.mean_strands.is_finite() || req.mean_strands < 1.0 || req.mean_strands > 100.0 {
        return Err(problem("The strands per pick must be 1 or more."));
    }
    let unit = if req.width.unit.is_metric() {
        LengthUnit::Centimeter
    } else {
        LengthUnit::Inch
    };
    let (ppi, ppi_input) = match &req.ppi {
        Origin::Swatch => {
            let s = weaving_swatch(req.swatch, "picks per inch")?;
            let along = s
                .on_loom
                .along
                .filter(|r| r.value.problem().is_none())
                .ok_or_else(|| {
                    problem(format!(
                    "{} has no picks counted on the loom. Picks counted after the cloth comes off \
                     the loom sit closer together, so the weft estimate does not use them.",
                    capitalize(&s.citation())
                ))
                })?;
            (
                along.value,
                TracedInput {
                    key: "ppi".into(),
                    label: "Picks".into(),
                    value: along.value.describe("picks"),
                    source: along.source,
                    basis: s.basis(along.source, Some(ply_common::materials::StageKind::OnLoom)),
                    swatch_id: Some(s.id.clone()),
                    material_id: None,
                },
            )
        }
        other => other
            .traced("ppi", "Picks", |c: CountOver| c.describe("picks"))
            .expect("not a swatch origin"),
    };
    if ppi.problem().is_some() {
        return Err(problem(
            "The picks must be a count above 0 over a span above 0.",
        ));
    }
    let (takeup, takeup_input) = match &req.takeup {
        Origin::Swatch => return Err(problem("A swatch does not give the weft take-up.")),
        other => other
            .traced("weft_takeup", "Weft take-up and selvedges", |f: f64| {
                percent(f)
            })
            .expect("not a swatch origin"),
    };
    check_fraction("weft take-up", takeup)?;
    let per_unit = ppi.per_unit(unit);
    let width = req.width.to(unit);
    let woven = req.woven_length.to(unit);
    let est = estimate_weft(&WeftPlan {
        picks_per_unit: per_unit as f32,
        width: width as f32,
        woven_length: woven as f32,
        items: req.items,
        takeup: takeup as f32,
    });
    let total = Length::new(f64::from(est.total_weft) * req.mean_strands, unit);
    let sym = unit.symbol();
    let mut working = vec![
        format!(
            "{} is {} picks per {sym}; x {} {sym} woven = {} picks per item, x {} = {} picks.",
            ppi.describe("picks"),
            number(per_unit),
            number(woven),
            number((per_unit * woven).round()),
            req.items,
            est.picks
        ),
        format!(
            "{} picks x {} {sym} x (1 + {}) = {} {sym} of weft.",
            est.picks,
            number(width),
            percent(takeup),
            number(f64::from(est.total_weft))
        ),
    ];
    let mut inputs = vec![
        ppi_input,
        TracedInput::entered("width", "Width in the reed", req.width.describe()),
        TracedInput::entered("woven_length", "Woven length", req.woven_length.describe()),
        TracedInput::entered("items", "Items", req.items.to_string()),
        takeup_input,
    ];
    if req.mean_strands != 1.0 {
        working.push(format!(
            "x {} strands per pick on average = {} {sym}.",
            number(req.mean_strands),
            number(total.value)
        ));
        inputs.push(TracedInput {
            key: "strands".into(),
            label: "Strands per pick".into(),
            value: number(req.mean_strands),
            source: Source::Entered,
            basis: "from this draft".into(),
            swatch_id: None,
            material_id: None,
        });
    }
    Ok(Traced {
        value: WeftAmount {
            picks: est.picks,
            total,
        },
        inputs,
        working,
        notes: Vec::new(),
    })
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
    use ply_common::provenance::Recorded;

    fn towel() -> Swatch {
        let mut s = Swatch::new("towel", "Towel sample");
        s.craft = Some(CraftKind::Weaving);
        s.date = Some("2026-11-02".into());
        s.sett = Some(Recorded::entered(CountOver::new(24.0, Length::inches(1.0))));
        s.width_in_reed = Some(Recorded::entered(Length::inches(12.0)));
        s.on_loom.length = Some(Recorded::measured(Length::inches(20.0)));
        s.on_loom.along = Some(Recorded::measured(CountOver::new(
            22.0,
            Length::inches(1.0),
        )));
        s.after.length = Some(Recorded::measured(Length::inches(18.0)));
        s
    }

    #[test]
    fn warp_from_a_swatch_matches_the_calculator() {
        let s = towel();
        let t = warp_traced(&WarpRequest {
            swatch: Some(&s),
            finished_length: Length::new(2.0, LengthUnit::Yard),
            items: 2,
            ends: Origin::Swatch,
            sett_width: Some(Length::inches(10.0)),
            loom_waste: Origin::Default(Length::new(0.75, LengthUnit::Yard), "".into()),
            allowance: Origin::Swatch,
        })
        .unwrap();
        assert_eq!(t.value.ends, 240);
        let plain = estimate_warp(&WarpPlan {
            finished_length: 2.0,
            items: 2,
            ends: 240,
            loom_waste: 0.75,
            takeup_shrinkage: (20.0f64 / 18.0 - 1.0) as f32,
        });
        assert_eq!(t.value.warp_length.value, f64::from(plain.warp_length));
        // 2 x 2 yd x 20/18 + 0.75 = 5.19 yd.
        assert!((t.value.warp_length.value - (4.0 * 20.0 / 18.0 + 0.75)).abs() < 1e-5);
        assert_eq!(t.value.warp_length.unit, LengthUnit::Yard);
        let keys: Vec<_> = t
            .inputs
            .iter()
            .map(|i| (i.key.as_str(), i.source))
            .collect();
        assert_eq!(
            keys,
            vec![
                ("finished_length", Source::Entered),
                ("items", Source::Entered),
                ("ends", Source::Entered),
                ("loom_waste", Source::Default),
                ("length_allowance", Source::Measured),
            ]
        );
        assert_eq!(
            t.inputs[2].sentence(),
            "240, 24 ends per in across 10 in (the sett in the reed, entered, swatch Towel sample \
             2026-11-02)"
        );
        assert_eq!(
            t.inputs[4].sentence(),
            "11.1% of the finished length, from 20 in on the loom and 18 in after wet finishing \
             (measured), swatch Towel sample 2026-11-02"
        );
        assert!(t.notes[0].contains("lost 10%"));
    }

    /// A sample can grow in finishing: the allowance is below zero, the warp is planned shorter than
    /// the finished length, and the estimate says so.
    #[test]
    fn a_sample_that_grew_gives_a_negative_allowance_and_a_note() {
        let mut s = towel();
        s.on_loom.length = Some(Recorded::measured(Length::cm(100.0)));
        s.after.length = Some(Recorded::measured(Length::cm(105.0)));
        let t = warp_traced(&WarpRequest {
            swatch: Some(&s),
            finished_length: Length::new(1.05, LengthUnit::Meter),
            items: 1,
            ends: Origin::Entered(100),
            sett_width: None,
            loom_waste: Origin::Entered(Length::new(0.0, LengthUnit::Meter)),
            allowance: Origin::Swatch,
        })
        .unwrap();
        // 1.05 m x 100 / 105 = 1 m to weave.
        assert!((t.value.warp_length.value - 1.0).abs() < 1e-6);
        assert!(
            t.inputs[4].value.starts_with("-4.8%"),
            "{}",
            t.inputs[4].value
        );
        assert!(t.notes[0].contains("came out longer after finishing"));
    }

    #[test]
    fn weft_from_a_swatch_uses_the_picks_on_the_loom() {
        let s = towel();
        let t = weft_traced(&WeftRequest {
            swatch: Some(&s),
            ppi: Origin::Swatch,
            width: Length::inches(20.0),
            woven_length: Length::inches(60.0),
            items: 1,
            takeup: Origin::Default(0.1, "".into()),
            mean_strands: 1.0,
        })
        .unwrap();
        // 22 x 60 = 1320 picks; 1320 x 20 x 1.1 = 29040 in.
        assert_eq!(t.value.picks, 1320);
        assert!((t.value.total.value - 29_040.0).abs() < 0.5);
        assert_eq!(
            t.inputs[0].sentence(),
            "22 picks per in, measured on the loom, swatch Towel sample 2026-11-02"
        );
        // Without picks on the loom the swatch cannot give them, and says why.
        let mut no = towel();
        no.on_loom.along = None;
        no.after.along = Some(Recorded::measured(CountOver::new(
            24.0,
            Length::inches(1.0),
        )));
        let err = weft_traced(&WeftRequest {
            swatch: Some(&no),
            ppi: Origin::Swatch,
            width: Length::inches(20.0),
            woven_length: Length::inches(60.0),
            items: 1,
            takeup: Origin::Entered(0.1),
            mean_strands: 1.0,
        })
        .unwrap_err();
        assert!(err.0.contains("no picks counted on the loom"), "{err}");
    }

    #[test]
    fn weft_counts_strands_and_metric_units() {
        let t = weft_traced(&WeftRequest {
            swatch: None,
            ppi: Origin::Entered(CountOver::new(8.0, Length::cm(1.0))),
            width: Length::cm(50.0),
            woven_length: Length::new(1.5, LengthUnit::Meter),
            items: 2,
            takeup: Origin::Entered(0.0),
            mean_strands: 1.5,
        })
        .unwrap();
        // 8 x 150 = 1200 per item, 2400 picks; 2400 x 50 = 120000 cm, x 1.5 strands.
        assert_eq!(t.value.picks, 2400);
        assert!((t.value.total.value - 180_000.0).abs() < 1.0);
        assert_eq!(t.value.total.unit, LengthUnit::Centimeter);
        assert!(t.inputs.iter().any(|i| i.key == "strands"));
    }

    #[test]
    fn requests_that_cannot_be_worked_out_say_why() {
        let mut knit = towel();
        knit.craft = Some(CraftKind::Knitting);
        let base = WarpRequest {
            swatch: Some(&knit),
            finished_length: Length::inches(60.0),
            items: 1,
            ends: Origin::Entered(200),
            sett_width: None,
            loom_waste: Origin::Entered(Length::inches(24.0)),
            allowance: Origin::Swatch,
        };
        assert!(warp_traced(&base)
            .unwrap_err()
            .0
            .contains("not a weaving swatch"));
        let mut missing = towel();
        missing.after.length = None;
        let req = WarpRequest {
            swatch: Some(&missing),
            ..base.clone()
        };
        assert!(warp_traced(&req)
            .unwrap_err()
            .0
            .contains("after wet finishing"));
        let req = WarpRequest {
            ends: Origin::Entered(0),
            allowance: Origin::Entered(0.1),
            ..base.clone()
        };
        assert!(warp_traced(&req).is_err());
        let req = WarpRequest {
            finished_length: Length::inches(f64::NAN),
            allowance: Origin::Entered(0.1),
            ..base
        };
        assert!(warp_traced(&req).is_err());
    }
}
