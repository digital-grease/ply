//! Unit-aware quantities (roadmap M8-01 and contract 10.3, ADR 0016): a length, a mass, a length per
//! mass (how much yarn a gram holds), and a count over a length (a gauge, a sett, picks per inch,
//! wraps per inch). Each keeps the numbers and the unit the crafter gave ("20 stitches over 10 cm",
//! "200 m per 100 g"), so a record never stores a converted or rounded figure in place of what was
//! measured.
//!
//! Conversions are exact by definition: the international inch is 2.54 cm and the yard 0.9144 m;
//! the avoirdupois pound is 453.59237 g and the ounce 1/16 of it, 28.349523125 g (both 1959). Each
//! unit is stored as an exact whole number of a base unit (micrometres, nanograms), so a conversion
//! is one multiplication and one division of exact integers by the value: the result is the
//! correctly rounded quotient, and a round trip comes back within a couple of ulps.
//!
//! Values come from files and across FFI, so they are untrusted: [`Length::problem`] and its
//! siblings say why a value cannot be used (not a finite number, not above zero, too large). Nothing
//! here panics on any input; a conversion of a bad value gives a bad number, never a crash, and
//! callers check first.

use serde::{Deserialize, Serialize};

use crate::Unit;

/// The largest number a length, a mass or a count may hold, in its own unit. Far beyond any real
/// yarn or swatch (a million metres of yarn); it only rejects absurd values from an untrusted file.
pub const MAX_QUANTITY_VALUE: f64 = 1_000_000.0;

/// Why a quantity cannot be used.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum QuantityProblem {
    /// Not a finite number (NaN or infinite).
    NotFinite,
    /// Zero or negative where only a size above zero makes sense.
    NotPositive,
    /// Larger than [`MAX_QUANTITY_VALUE`].
    TooLarge,
}

impl QuantityProblem {
    /// The stable diagnostic code for this problem.
    pub fn code(self) -> &'static str {
        match self {
            QuantityProblem::NotFinite => "quantity.not_finite",
            QuantityProblem::NotPositive => "quantity.not_positive",
            QuantityProblem::TooLarge => "quantity.too_large",
        }
    }

    /// A short phrase for messages ("is not a number").
    pub fn phrase(self) -> &'static str {
        match self {
            QuantityProblem::NotFinite => "is not a number",
            QuantityProblem::NotPositive => "must be more than 0",
            QuantityProblem::TooLarge => "is too large",
        }
    }
}

/// The problem with a positive size `v`, if any.
pub fn positive_problem(v: f64) -> Option<QuantityProblem> {
    if !v.is_finite() {
        Some(QuantityProblem::NotFinite)
    } else if v <= 0.0 {
        Some(QuantityProblem::NotPositive)
    } else if v > MAX_QUANTITY_VALUE {
        Some(QuantityProblem::TooLarge)
    } else {
        None
    }
}

/// The problem with a signed amount `v` (an ease may be negative), if any.
pub fn signed_problem(v: f64) -> Option<QuantityProblem> {
    if !v.is_finite() {
        Some(QuantityProblem::NotFinite)
    } else if v.abs() > MAX_QUANTITY_VALUE {
        Some(QuantityProblem::TooLarge)
    } else {
        None
    }
}

// --- length ---------------------------------------------------------------------------------------

/// A unit of length.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum LengthUnit {
    #[serde(rename = "mm")]
    Millimeter,
    #[serde(rename = "cm")]
    Centimeter,
    #[serde(rename = "m")]
    Meter,
    #[serde(rename = "in")]
    Inch,
    #[serde(rename = "yd")]
    Yard,
}

impl LengthUnit {
    /// Every unit, for tests and pickers.
    pub const ALL: [LengthUnit; 5] = [
        LengthUnit::Millimeter,
        LengthUnit::Centimeter,
        LengthUnit::Meter,
        LengthUnit::Inch,
        LengthUnit::Yard,
    ];

    /// The unit's exact size in micrometres (a whole number for every unit).
    pub const fn micrometers(self) -> f64 {
        match self {
            LengthUnit::Millimeter => 1_000.0,
            LengthUnit::Centimeter => 10_000.0,
            LengthUnit::Meter => 1_000_000.0,
            LengthUnit::Inch => 25_400.0,
            LengthUnit::Yard => 914_400.0,
        }
    }

    /// "mm", "cm", "m", "in", "yd".
    pub const fn symbol(self) -> &'static str {
        match self {
            LengthUnit::Millimeter => "mm",
            LengthUnit::Centimeter => "cm",
            LengthUnit::Meter => "m",
            LengthUnit::Inch => "in",
            LengthUnit::Yard => "yd",
        }
    }

    /// Whether the unit is metric (mm, cm, m) rather than imperial (in, yd).
    pub const fn is_metric(self) -> bool {
        matches!(
            self,
            LengthUnit::Millimeter | LengthUnit::Centimeter | LengthUnit::Meter
        )
    }
}

impl From<Unit> for LengthUnit {
    fn from(u: Unit) -> Self {
        match u {
            Unit::Inches => LengthUnit::Inch,
            Unit::Centimeters => LengthUnit::Centimeter,
        }
    }
}

/// A length in the unit it was given in.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Length {
    pub value: f64,
    pub unit: LengthUnit,
}

impl Length {
    pub const fn new(value: f64, unit: LengthUnit) -> Length {
        Length { value, unit }
    }

    pub const fn cm(value: f64) -> Length {
        Length::new(value, LengthUnit::Centimeter)
    }

    pub const fn inches(value: f64) -> Length {
        Length::new(value, LengthUnit::Inch)
    }

    /// This length expressed in `unit` (exact factors; see the module doc).
    pub fn to(self, unit: LengthUnit) -> f64 {
        if unit == self.unit {
            return self.value;
        }
        self.value * self.unit.micrometers() / unit.micrometers()
    }

    /// This length converted to `unit`.
    pub fn converted(self, unit: LengthUnit) -> Length {
        Length::new(self.to(unit), unit)
    }

    /// The problem with this length as a size (it must be above zero), if any.
    pub fn problem(self) -> Option<QuantityProblem> {
        positive_problem(self.value)
    }

    /// "10 cm", "4 in", "2.5 yd".
    pub fn describe(self) -> String {
        format!("{} {}", number(self.value), self.unit.symbol())
    }
}

// --- mass -----------------------------------------------------------------------------------------

/// A unit of mass.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum MassUnit {
    #[serde(rename = "g")]
    Gram,
    #[serde(rename = "kg")]
    Kilogram,
    #[serde(rename = "oz")]
    Ounce,
    #[serde(rename = "lb")]
    Pound,
}

impl MassUnit {
    /// Every unit, for tests and pickers.
    pub const ALL: [MassUnit; 4] = [
        MassUnit::Gram,
        MassUnit::Kilogram,
        MassUnit::Ounce,
        MassUnit::Pound,
    ];

    /// The unit's exact size in nanograms (a whole number for every unit).
    pub const fn nanograms(self) -> f64 {
        match self {
            MassUnit::Gram => 1_000_000_000.0,
            MassUnit::Kilogram => 1_000_000_000_000.0,
            MassUnit::Ounce => 28_349_523_125.0,
            MassUnit::Pound => 453_592_370_000.0,
        }
    }

    /// "g", "kg", "oz", "lb".
    pub const fn symbol(self) -> &'static str {
        match self {
            MassUnit::Gram => "g",
            MassUnit::Kilogram => "kg",
            MassUnit::Ounce => "oz",
            MassUnit::Pound => "lb",
        }
    }
}

/// A mass in the unit it was given in.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Mass {
    pub value: f64,
    pub unit: MassUnit,
}

impl Mass {
    pub const fn new(value: f64, unit: MassUnit) -> Mass {
        Mass { value, unit }
    }

    pub const fn grams(value: f64) -> Mass {
        Mass::new(value, MassUnit::Gram)
    }

    /// This mass expressed in `unit` (exact factors).
    pub fn to(self, unit: MassUnit) -> f64 {
        if unit == self.unit {
            return self.value;
        }
        self.value * self.unit.nanograms() / unit.nanograms()
    }

    pub fn converted(self, unit: MassUnit) -> Mass {
        Mass::new(self.to(unit), unit)
    }

    /// The problem with this mass (it must be above zero), if any.
    pub fn problem(self) -> Option<QuantityProblem> {
        positive_problem(self.value)
    }

    /// "100 g", "4 oz".
    pub fn describe(self) -> String {
        format!("{} {}", number(self.value), self.unit.symbol())
    }
}

// --- length per mass ------------------------------------------------------------------------------

/// How much yarn a given mass holds, as the label or the crafter's own measurement gives it: "200 m
/// per 100 g", "1680 yd per 1 lb", or "12.5 m per 3.1 g" from a weighed sample. Both numbers are
/// kept as given.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct LengthPerMass {
    pub length: Length,
    pub mass: Mass,
}

impl LengthPerMass {
    pub const fn new(length: Length, mass: Mass) -> LengthPerMass {
        LengthPerMass { length, mass }
    }

    /// The length (in `unit`) that `mass` of this yarn holds.
    pub fn length_for(self, mass: Mass, unit: LengthUnit) -> f64 {
        self.length.to(unit) * mass.to(MassUnit::Gram) / self.mass.to(MassUnit::Gram)
    }

    /// The mass (in `unit`) of `length` of this yarn.
    pub fn mass_for(self, length: Length, unit: MassUnit) -> f64 {
        self.mass.to(unit) * length.to(LengthUnit::Meter) / self.length.to(LengthUnit::Meter)
    }

    /// Metres per 100 g.
    pub fn meters_per_100g(self) -> f64 {
        self.length_for(Mass::grams(100.0), LengthUnit::Meter)
    }

    /// Yards per 100 g.
    pub fn yards_per_100g(self) -> f64 {
        self.length_for(Mass::grams(100.0), LengthUnit::Yard)
    }

    /// Yards per pound (the weaver's YPP).
    pub fn yards_per_pound(self) -> f64 {
        self.length_for(Mass::new(1.0, MassUnit::Pound), LengthUnit::Yard)
    }

    /// The first problem with either part, if any.
    pub fn problem(self) -> Option<QuantityProblem> {
        self.length.problem().or(self.mass.problem())
    }

    /// "200 m per 100 g".
    pub fn describe(self) -> String {
        format!("{} per {}", self.length.describe(), self.mass.describe())
    }
}

// --- a count over a length ------------------------------------------------------------------------

/// A count over a measured span, as the crafter counted it: "20 stitches over 10 cm", "24 ends over
/// 1 in", "11 wraps over 1 in". A gauge, a sett, picks per inch and wraps per inch are all this
/// shape. The count may be fractional (22.5 stitches over 10 cm).
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CountOver {
    pub count: f64,
    pub over: Length,
}

impl CountOver {
    pub const fn new(count: f64, over: Length) -> CountOver {
        CountOver { count, over }
    }

    /// The count over `span` at this density.
    pub fn per(self, span: Length) -> f64 {
        self.count * span.to(self.over.unit) / self.over.value
    }

    /// The count over one `unit` (per inch, per cm).
    pub fn per_unit(self, unit: LengthUnit) -> f64 {
        self.per(Length::new(1.0, unit))
    }

    /// The count over 10 cm.
    pub fn per_10cm(self) -> f64 {
        self.per(Length::cm(10.0))
    }

    /// The count over 4 in.
    pub fn per_4in(self) -> f64 {
        self.per(Length::inches(4.0))
    }

    /// The first problem with the count or the span, if any.
    pub fn problem(self) -> Option<QuantityProblem> {
        positive_problem(self.count).or(self.over.problem())
    }

    /// The count with `noun` ("sts") as the crafter would say it: "per" a usual span (one unit, 10 cm,
    /// 4 in), "over" any other ("24 ends per in", "20 sts per 10 cm", "11 sts over 5 cm").
    pub fn describe(self, noun: &str) -> String {
        let usual = self.over.value == 1.0
            || (self.over.value == 10.0 && self.over.unit == LengthUnit::Centimeter)
            || (self.over.value == 4.0 && self.over.unit == LengthUnit::Inch);
        if self.over.value == 1.0 {
            format!(
                "{} {noun} per {}",
                number(self.count),
                self.over.unit.symbol()
            )
        } else if usual {
            format!("{} {noun} per {}", number(self.count), self.over.describe())
        } else {
            format!(
                "{} {noun} over {}",
                number(self.count),
                self.over.describe()
            )
        }
    }
}

/// A number as a crafter writes it: at most two decimals, no trailing zeros (20, 22.5, 0.25).
pub fn number(v: f64) -> String {
    if !v.is_finite() {
        return "?".to_string();
    }
    let r = (v * 100.0).round() / 100.0;
    let mut s = format!("{r:.2}");
    while s.ends_with('0') {
        s.pop();
    }
    if s.ends_with('.') {
        s.pop();
    }
    if s == "-0" {
        s = "0".to_string();
    }
    s
}

/// A fraction as a percentage with one decimal ("8.3%", "12%").
pub fn percent(fraction: f64) -> String {
    if !fraction.is_finite() {
        return "?%".to_string();
    }
    let r = (fraction * 1000.0).round() / 10.0;
    if (r - r.round()).abs() < 1e-9 {
        format!("{}%", r.round() as i64)
    } else {
        format!("{r:.1}%")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn factors_are_the_international_definitions() {
        assert_eq!(Length::inches(1.0).to(LengthUnit::Centimeter), 2.54);
        assert_eq!(
            Length::new(1.0, LengthUnit::Yard).to(LengthUnit::Meter),
            0.9144
        );
        assert_eq!(
            Length::new(1.0, LengthUnit::Yard).to(LengthUnit::Inch),
            36.0
        );
        assert_eq!(
            Mass::new(1.0, MassUnit::Pound).to(MassUnit::Gram),
            453.59237
        );
        assert_eq!(
            Mass::new(1.0, MassUnit::Ounce).to(MassUnit::Gram),
            28.349523125
        );
        assert_eq!(Mass::new(16.0, MassUnit::Ounce).to(MassUnit::Pound), 1.0);
        assert_eq!(Length::cm(10.0).to(LengthUnit::Millimeter), 100.0);
    }

    #[test]
    fn length_per_mass_normalizes() {
        // 220 yd per 100 g is 201.168 m per 100 g.
        let lpm = LengthPerMass::new(Length::new(220.0, LengthUnit::Yard), Mass::grams(100.0));
        assert!((lpm.meters_per_100g() - 201.168).abs() < 1e-9);
        assert!((lpm.yards_per_100g() - 220.0).abs() < 1e-9);
        // 220 yd per 100 g is 997.9 yd per pound.
        assert!((lpm.yards_per_pound() - 997.903214).abs() < 1e-5);
        // A measured sample: 12.5 m weighs 3.1 g, so 100 g holds about 403 m.
        let sample = LengthPerMass::new(Length::new(12.5, LengthUnit::Meter), Mass::grams(3.1));
        assert!((sample.meters_per_100g() - 403.2258).abs() < 1e-3);
        assert!(
            (sample.mass_for(Length::new(100.0, LengthUnit::Meter), MassUnit::Gram) - 24.8).abs()
                < 1e-9
        );
    }

    #[test]
    fn counts_over_a_span() {
        let gauge = CountOver::new(20.0, Length::cm(10.0));
        assert_eq!(gauge.per_10cm(), 20.0);
        assert!((gauge.per_unit(LengthUnit::Centimeter) - 2.0).abs() < 1e-12);
        assert!((gauge.per_4in() - 20.32).abs() < 1e-9);
        let sett = CountOver::new(24.0, Length::inches(1.0));
        assert_eq!(sett.per_unit(LengthUnit::Inch), 24.0);
        assert_eq!(sett.describe("ends"), "24 ends per in");
        assert_eq!(gauge.describe("sts"), "20 sts per 10 cm");
        assert_eq!(
            CountOver::new(11.0, Length::cm(5.0)).describe("sts"),
            "11 sts over 5 cm"
        );
    }

    #[test]
    fn problems() {
        assert_eq!(
            Length::cm(0.0).problem(),
            Some(QuantityProblem::NotPositive)
        );
        assert_eq!(
            Length::cm(-1.0).problem(),
            Some(QuantityProblem::NotPositive)
        );
        assert_eq!(
            Length::cm(f64::NAN).problem(),
            Some(QuantityProblem::NotFinite)
        );
        assert_eq!(
            Length::cm(f64::INFINITY).problem(),
            Some(QuantityProblem::NotFinite)
        );
        assert_eq!(Length::cm(2e6).problem(), Some(QuantityProblem::TooLarge));
        assert_eq!(Length::cm(1.0).problem(), None);
        assert_eq!(signed_problem(-2.0), None);
        assert_eq!(
            CountOver::new(20.0, Length::cm(0.0)).problem(),
            Some(QuantityProblem::NotPositive)
        );
    }

    #[test]
    fn numbers_read_cleanly() {
        assert_eq!(number(20.0), "20");
        assert_eq!(number(22.5), "22.5");
        assert_eq!(number(2.0 / 3.0), "0.67");
        assert_eq!(number(-0.001), "0");
        assert_eq!(number(f64::NAN), "?");
        assert_eq!(percent(0.0833333), "8.3%");
        assert_eq!(percent(0.12), "12%");
    }
}
