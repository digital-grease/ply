//! Knitting planning calculators: gauge -> finished dimensions / cast-on, and yarn-yardage
//! estimation. The knitting analog of `ply-weave`'s `calc.rs`.
//!
//! Everything here is **inherently rough** — gauge varies between knitters and yarn use depends on the
//! stitch pattern (cables and textured stitches eat more than stockinette). Treat results as estimates
//! and surface a buffer. Formulas + the seed table are sourced in `docs/KNIT_DESIGN.md`.
//!
//! Guards: a non-positive or non-finite gauge yields 0 rather than NaN/inf, so untrusted or
//! half-entered input never produces a garbage number downstream.

use crate::pattern::Gauge;
use ply_common::{Unit, YarnWeight};

const CM_PER_IN: f32 = 2.54;

/// A sanity cap on a computed stitch count, so an absurd target can never overflow the `u32`
/// arithmetic (a float->int cast saturates silently) or return a garbage `u32::MAX`. Far beyond any
/// real garment.
const MAX_STITCHES: u32 = 1_000_000;

fn positive_finite(x: f32) -> bool {
    x.is_finite() && x > 0.0
}

/// Finished width (in the gauge's unit) of `stitches` worked at `gauge`. 0 if the stitch gauge is
/// non-positive / non-finite.
pub fn finished_width(stitches: u32, gauge: Gauge) -> f32 {
    let g = gauge.sts_per_unit();
    if positive_finite(g) {
        stitches as f32 / g
    } else {
        0.0
    }
}

/// Finished length (in the gauge's unit) of `rows` worked at `gauge`. 0 if the row gauge is
/// non-positive / non-finite.
pub fn finished_length(rows: u32, gauge: Gauge) -> f32 {
    let g = gauge.rows_per_unit();
    if positive_finite(g) {
        rows as f32 / g
    } else {
        0.0
    }
}

/// Cast-on stitch count for a target finished `width` plus `ease` (both in the gauge's unit), rounded
/// to a whole stitch and then to the nearest multiple of a stitch-pattern `repeat` (>= 1). 0 if the
/// gauge is unusable or the target is non-positive.
pub fn cast_on(width: f32, ease: f32, gauge: Gauge, repeat: u32) -> u32 {
    let g = gauge.sts_per_unit();
    let target = width + ease;
    if !positive_finite(g) || !target.is_finite() || target <= 0.0 {
        return 0;
    }
    // Clamp BEFORE the float->int cast (a bare `as u32` saturates a huge float to u32::MAX silently)
    // and use saturating arithmetic, so an absurd width/gauge can't overflow-panic or wrap to garbage.
    let raw = (target * g).round().clamp(0.0, MAX_STITCHES as f32) as u32;
    let r = repeat.max(1);
    // Round to the nearest multiple of the repeat (e.g. a k2/p2 rib needs a multiple of 4).
    (raw.saturating_add(r / 2) / r) * r
}

/// Total stitches worked over a rectangular `width` x `length` piece (both in the gauge's unit) —
/// area x stitch-gauge x row-gauge. The basis for a yardage estimate (NOT the live stitch count of a
/// single row). 0 on an unusable gauge or non-positive dimensions.
pub fn total_stitches(width: f32, length: f32, gauge: Gauge) -> f32 {
    let (gs, gr) = (gauge.sts_per_unit(), gauge.rows_per_unit());
    if !positive_finite(gs) || !positive_finite(gr) || !positive_finite(width) || !positive_finite(length)
    {
        return 0.0;
    }
    (width * gs) * (length * gr)
}

/// Estimate yards of yarn for a STOCKINETTE rectangle via the empirical closed form
/// `yards ~= width_in * length_in * sts_per_in / 6`. The `/6` constant is defined for INCHES and
/// stitches-per-inch, so a centimetre gauge is normalized first. Rough (~+/-15%); pass through
/// [`with_buffer`] for real planning. 0 on unusable input.
pub fn estimate_yards_stockinette(width: f32, length: f32, gauge: Gauge) -> f32 {
    let gs = gauge.sts_per_unit();
    if !positive_finite(gs) || !positive_finite(width) || !positive_finite(length) {
        return 0.0;
    }
    // Normalize everything to inches + stitches-per-inch, the basis of the /6 constant.
    let (w_in, l_in, sts_per_in) = match gauge.unit {
        Unit::Inches => (width, length, gs),
        Unit::Centimeters => (width / CM_PER_IN, length / CM_PER_IN, gs * CM_PER_IN),
    };
    let y = w_in * l_in * sts_per_in / 6.0;
    if y.is_finite() && y > 0.0 {
        y
    } else {
        0.0
    }
}

/// Estimate yards from a weighed-swatch (the most accurate method): grams-per-area scaled to the
/// project area, then converted via the skein's yards/grams. Areas in any consistent unit. 0 on
/// unusable input.
pub fn estimate_yards_from_swatch(
    swatch_grams: f32,
    swatch_area: f32,
    project_area: f32,
    skein_yards: f32,
    skein_grams: f32,
) -> f32 {
    // All five must be positive-finite: a weight and a length are never negative, and two negatives
    // would otherwise multiply into a bogus POSITIVE yardage past the trailing `>= 0.0` check.
    if !positive_finite(swatch_area)
        || !positive_finite(skein_grams)
        || !positive_finite(swatch_grams)
        || !positive_finite(project_area)
        || !positive_finite(skein_yards)
    {
        return 0.0;
    }
    let grams = (swatch_grams / swatch_area) * project_area;
    let y = grams * (skein_yards / skein_grams);
    if y.is_finite() && y >= 0.0 {
        y
    } else {
        0.0
    }
}

/// Apply a planning buffer (a fraction, e.g. 0.15 for +15%) to a raw yardage estimate. A negative
/// fraction is clamped to 0 (never reduce the estimate).
pub fn with_buffer(yards: f32, fraction: f32) -> f32 {
    let f = if fraction.is_finite() { fraction.max(0.0) } else { 0.0 };
    yards * (1.0 + f)
}

/// A default stockinette gauge for a yarn weight, from the Craft Yarn Council Standard Yarn Weight
/// System (knit gauge = stitches per 4 in; midpoints of the published ranges). Row gauge is estimated
/// at the stockinette ~4:3 row:stitch ratio. Always an editable SEED — the knitter's own swatch
/// overrides it.
pub fn seed_gauge(weight: YarnWeight) -> Gauge {
    let sts = match weight {
        YarnWeight::Lace => 36.5,       // 33-40
        YarnWeight::SuperFine => 29.5,  // 27-32
        YarnWeight::Fine => 24.5,       // 23-26
        YarnWeight::Light => 22.5,      // 21-24 (DK)
        YarnWeight::Medium => 18.0,     // 16-20 (worsted)
        YarnWeight::Bulky => 13.5,      // 12-15
        YarnWeight::SuperBulky => 9.0,  // 7-11
        YarnWeight::Jumbo => 5.0,       // <=6
    };
    // Per 4 in (CYC convention); rows estimated at the stockinette ~4:3 row:stitch ratio.
    Gauge { sts, rows: sts * 4.0 / 3.0, unit: Unit::Inches }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn worsted() -> Gauge {
        // 20 sts & 30 rows per 4 in => 5 sts/in, 7.5 rows/in.
        Gauge { sts: 20.0, rows: 30.0, unit: Unit::Inches }
    }

    #[test]
    fn width_and_length_from_counts() {
        assert_eq!(finished_width(40, worsted()), 8.0); // 40 / 5
        assert_eq!(finished_length(60, worsted()), 8.0); // 60 / 7.5
    }

    #[test]
    fn cast_on_rounds_to_stitch_and_repeat() {
        assert_eq!(cast_on(20.0, 0.0, worsted(), 1), 100); // 20in * 5
        // 22in * 5 = 110, rounded to the nearest multiple of 4 (k2p2 rib) -> 112.
        assert_eq!(cast_on(20.0, 2.0, worsted(), 4), 112);
    }

    #[test]
    fn yardage_stockinette_closed_form() {
        // 8 x 8 in at 5 sts/in: 8*8*5/6 = 53.33...
        let y = estimate_yards_stockinette(8.0, 8.0, worsted());
        assert!((y - 53.333).abs() < 0.01, "got {y}");
    }

    #[test]
    fn yardage_cm_gauge_matches_inch_equivalent() {
        // A REAL per-10-cm gauge of the SAME physical density as worsted (5 sts/in) must give ~the
        // same yards for the same physical size — proving both the per-window divisor and the cm
        // normalization. 5 sts/in -> 5/2.54 sts/cm -> *10 per 10 cm.
        let sts_per_in = worsted().sts_per_unit(); // 5.0
        let cm = Gauge { sts: sts_per_in / CM_PER_IN * 10.0, rows: 30.0, unit: Unit::Centimeters };
        assert!((cm.sts_per_unit() - sts_per_in / CM_PER_IN).abs() < 1e-4, "cm density is sts/cm");
        let y_cm = estimate_yards_stockinette(8.0 * CM_PER_IN, 8.0 * CM_PER_IN, cm);
        let y_in = estimate_yards_stockinette(8.0, 8.0, worsted());
        assert!((y_cm - y_in).abs() < 0.5, "cm {y_cm} vs in {y_in}");
    }

    #[test]
    fn swatch_yardage_matches_worked_example() {
        // From the research: 14 g / 40.625 sq in = 0.3446 g/sq in; x 1440 sq in = ~496 g;
        // at 220 yd / 100 g => ~1092 yd.
        let y = estimate_yards_from_swatch(14.0, 40.625, 1440.0, 220.0, 100.0);
        assert!((y - 1092.0).abs() < 5.0, "got {y}");
    }

    #[test]
    fn buffer_adds_and_clamps() {
        assert_eq!(with_buffer(100.0, 0.15), 115.0);
        assert_eq!(with_buffer(100.0, -0.5), 100.0, "a negative buffer never reduces");
    }

    #[test]
    fn seed_gauge_from_weight() {
        let g = seed_gauge(YarnWeight::Medium);
        assert_eq!(g.sts, 18.0);
        assert_eq!(g.rows, 24.0); // 18 * 4/3
        assert_eq!(g.unit, Unit::Inches);
    }

    #[test]
    fn unusable_gauge_yields_zero_not_nan() {
        let zero = Gauge { sts: 0.0, rows: 0.0, unit: Unit::Inches };
        assert_eq!(finished_width(40, zero), 0.0);
        assert_eq!(finished_length(40, zero), 0.0);
        assert_eq!(cast_on(20.0, 0.0, zero, 1), 0);
        assert_eq!(estimate_yards_stockinette(8.0, 8.0, zero), 0.0);
        let nan = Gauge { sts: f32::NAN, rows: f32::NAN, unit: Unit::Inches };
        assert_eq!(finished_width(40, nan), 0.0);
        assert!(!estimate_yards_stockinette(8.0, 8.0, nan).is_nan());
    }

    #[test]
    fn cast_on_does_not_overflow_on_absurd_input() {
        // u32::MAX-saturating cast + saturating add: a 1e12-inch target must not panic or wrap.
        let n = cast_on(1.0e12, 0.0, worsted(), 4);
        assert!(n <= MAX_STITCHES, "bounded, no panic: {n}");
    }

    #[test]
    fn swatch_rejects_negative_inputs() {
        // Two negatives must NOT multiply into a bogus positive yardage.
        assert_eq!(estimate_yards_from_swatch(-14.0, 40.625, 1440.0, -220.0, 100.0), 0.0);
        assert_eq!(estimate_yards_from_swatch(14.0, 40.625, 1440.0, -220.0, 100.0), 0.0);
    }
}
