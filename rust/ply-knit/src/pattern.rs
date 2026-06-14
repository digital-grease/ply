//! The knitting pattern model: a bottom-to-top CHART of stitch cells over an OPEN stitch legend —
//! the canonical editable source from which written instructions and (later) machine output derive.
//!
//! See `docs/KNIT_DESIGN.md` for the rationale, the prior-art survey, and the open owner decisions.
//! This is the M5 Phase-1 core model (the `ply-weave` `draft.rs` analog); render / validate / calc /
//! native-IO land in sibling modules in later phases. Pure Rust + serde — no FFI, no Flutter.
//!
//! Design choices baked in here (all research-backed, all owner-overridable — see the design doc):
//! - **Chart-as-source**: the chart is canonical; written/machine views are derived.
//! - **Open vocabulary**: stitches are DATA ([`StitchLegend`]), not enum arms, so a new stitch never
//!   touches the schema (the anti-KnitML rule).
//! - **RS-relative symbols**: a cell stores its right-side identity; the worked op on a WS row is
//!   resolved through [`StitchDef::ws_variant`].
//! - **Per-stitch `(consumes, produces)`**: so a row's live stitch count is derived, and `NoStitch`
//!   fillers keep the grid rectangular across increases/decreases.

use crate::error::KnitError;
use ply_common::{Color, Unit};
use serde::{Deserialize, Serialize};

/// Index into a [`KnitPattern::legend`] — the open, per-pattern stitch vocabulary.
pub type StitchId = usize;
/// Index into a [`KnitPattern::palette`] (colorwork). `None` on a cell means "the working yarn".
pub type ColorIndex = usize;

/// Flat (worked back and forth, alternating RS/WS) or in the round (every round from the RS).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Construction {
    Flat,
    InTheRound,
}

/// Which face a row is worked from. Symbols are stored RS-relative; the WS form is resolved via
/// [`StitchDef::ws_variant`]. Only meaningful when [`Construction::Flat`]; in the round all rows are RS.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Side {
    Rs,
    Ws,
}

/// Which way a cable leans / which group of stitches crosses on top.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Cross {
    Right,
    Left,
}

/// A cable crossing, fully defined by the four data points real charts use: how many stitches cross
/// in front vs back, the lean, and whether either group is purled (the `P` in RPC/LPC).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct CableDef {
    pub front: u8,
    pub back: u8,
    pub direction: Cross,
    pub front_purl: bool,
    pub back_purl: bool,
}

impl CableDef {
    /// Total stitches the cable spans. Count-neutral: it consumes and produces `span` (only reorders).
    pub fn span(self) -> u8 {
        self.front + self.back
    }
}

/// One entry in the OPEN stitch vocabulary. Custom stitches are DATA (not new enum arms), so adding a
/// stitch never touches the schema. Symbol names mirror the Craft Yarn Council / StitchMastery
/// conventions ("k", "p", "yo", "k2tog", "ssk", "cdd", ...).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StitchDef {
    /// Glyph / shorthand name, RS-relative.
    pub symbol: String,
    /// Stitches consumed from the row below.
    pub consumes: u8,
    /// Stitches produced onto this row.
    pub produces: u8,
    /// The stitch this is *worked as* on a WS row (k->p, k2tog->p2tog, ...). `None` = side-agnostic
    /// (yo, no-stitch, most cables).
    pub ws_variant: Option<StitchId>,
    /// Set for a multi-column cable crossing (its grid layout is a renderer concern, deferred).
    pub cable: Option<CableDef>,
    /// 1 for an ordinary stitch; >1 for an opaque macro worked over several rows in one cell (bobble,
    /// cast-on, bind-off).
    pub macro_rows: u8,
}

impl StitchDef {
    /// A plain 1->1 stitch with the given symbol and optional WS variant.
    pub fn simple(symbol: &str, ws_variant: Option<StitchId>) -> Self {
        StitchDef {
            symbol: symbol.into(),
            consumes: 1,
            produces: 1,
            ws_variant,
            cable: None,
            macro_rows: 1,
        }
    }

    /// Net change to the live stitch count when this stitch is worked (`produces - consumes`).
    pub fn delta(&self) -> i32 {
        self.produces as i32 - self.consumes as i32
    }
}

/// Stable ids for the [`StitchLegend::builtin`] seed vocabulary.
pub mod builtin {
    use super::StitchId;
    pub const NO_STITCH: StitchId = 0;
    pub const KNIT: StitchId = 1;
    pub const PURL: StitchId = 2;
    pub const YO: StitchId = 3;
    pub const K2TOG: StitchId = 4;
    pub const SSK: StitchId = 5;
    pub const P2TOG: StitchId = 6;
    pub const CDD: StitchId = 7;
    pub const M1L: StitchId = 8;
    pub const M1R: StitchId = 9;
    pub const KFB: StitchId = 10;
    pub const SLIP: StitchId = 11;
}

/// The open stitch vocabulary for a pattern: built-ins plus any custom [`StitchDef`]s.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StitchLegend {
    pub stitches: Vec<StitchDef>,
}

impl StitchLegend {
    pub fn get(&self, id: StitchId) -> Option<&StitchDef> {
        self.stitches.get(id)
    }

    /// The common hand-knitting built-ins (lace + basic shaping), in [`builtin`] id order — a starting
    /// vocabulary a pattern extends with custom stitches. WS pairings are approximate where a purl-side
    /// decrease (ssp) is folded onto p2tog for the seed.
    pub fn builtin() -> Self {
        use builtin::*;
        let def = |symbol: &str, consumes: u8, produces: u8, ws: Option<StitchId>| StitchDef {
            symbol: symbol.into(),
            consumes,
            produces,
            ws_variant: ws,
            cable: None,
            macro_rows: 1,
        };
        StitchLegend {
            stitches: vec![
                def("ns", 0, 0, None),            // NO_STITCH
                def("k", 1, 1, Some(PURL)),       // KNIT  -> worked as purl on the WS
                def("p", 1, 1, Some(KNIT)),       // PURL  -> worked as knit on the WS
                def("yo", 0, 1, None),            // YO    (increase)
                def("k2tog", 2, 1, Some(P2TOG)),  // K2TOG (right-leaning dec)
                def("ssk", 2, 1, Some(P2TOG)),    // SSK   (left-leaning dec; ws approx)
                def("p2tog", 2, 1, Some(K2TOG)),  // P2TOG
                def("cdd", 3, 1, None),           // CDD   (centered double dec)
                def("m1l", 0, 1, None),           // M1L   (increase)
                def("m1r", 0, 1, None),           // M1R   (increase)
                def("kfb", 1, 2, None),           // KFB   (1->2 increase)
                def("sl", 1, 1, None),            // SLIP
            ],
        }
    }
}

/// Gauge as the publishing convention states it: stitches AND rows per gauge WINDOW, where the window
/// is 4 inches OR 10 centimetres per [`Gauge::unit`] ("X sts and Y rows = 4 in (10 cm)"). Per-unit
/// density (per inch / per cm) is derived via the unit-aware window — NOT a fixed `/4`, which would
/// make a metric (per-10-cm) gauge wrong by 2.5x.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Gauge {
    /// Stitches per gauge window (4 in / 10 cm).
    pub sts: f32,
    /// Rows per gauge window (4 in / 10 cm).
    pub rows: f32,
    pub unit: Unit,
}

impl Gauge {
    /// The gauge-window length in [`Gauge::unit`]: 4 inches, or 10 centimetres.
    pub fn window(self) -> f32 {
        match self.unit {
            Unit::Inches => 4.0,
            Unit::Centimeters => 10.0,
        }
    }
    /// Stitches per single unit (per inch or per cm).
    pub fn sts_per_unit(self) -> f32 {
        self.sts / self.window()
    }
    /// Rows per single unit (per inch or per cm).
    pub fn rows_per_unit(self) -> f32 {
        self.rows / self.window()
    }
}

/// One cell in the chart grid: a stitch from the legend plus an optional colorwork color.
///
/// Each cell occupies exactly ONE column, so a row always keeps `cells.len() == Chart::width` and
/// columns align across rows. A multi-column **CABLE** (owner decision #2: cables are in v1) is a
/// single cell — its `StitchDef.cable` is `Some`, with `consumes == produces == span` — placed at its
/// LEFTMOST column and FOLLOWED by `span - 1` `NoStitch` cells that hold the columns it visually
/// covers. So the grid stays rectangular and the live stitch count stays correct (the trailing
/// no-stitch cells contribute 0). `validate` enforces this convention (a cable must fit the width and
/// be trailed by no-stitch); `render` draws the cable glyph across the span.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Cell {
    pub stitch: StitchId,
    pub color: Option<ColorIndex>,
}

impl Cell {
    pub fn of(stitch: StitchId) -> Self {
        Cell { stitch, color: None }
    }
    pub fn colored(stitch: StitchId, color: ColorIndex) -> Self {
        Cell { stitch, color: Some(color) }
    }
}

/// How many times a horizontal [`RepeatSpan`] is worked.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Repeat {
    Times(u16),
    ToEnd,
}

/// An AUTHORED horizontal repeat over columns `[start, end)` of a row (`[..] N times` / `*..; rep
/// from *`). First-class structure — never auto-detected — so chart->written is a trivial expansion
/// and the lossy chart->minimal-folded direction is avoided.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct RepeatSpan {
    pub start: usize,
    pub end: usize,
    pub count: Repeat,
}

/// One chart row, read bottom-to-top. `cells.len() == Chart::width` (a short row is padded with
/// `NoStitch` so the grid stays rectangular and columns align across increases/decreases).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Row {
    pub cells: Vec<Cell>,
    pub repeats: Vec<RepeatSpan>,
}

impl Row {
    /// A row of plain cells with no authored repeats.
    pub fn plain(cells: Vec<Cell>) -> Self {
        Row { cells, repeats: Vec::new() }
    }
}

/// The chart: a fixed-width grid of rows — the canonical editable source.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Chart {
    pub width: usize,
    pub rows: Vec<Row>,
}

impl Chart {
    pub fn height(&self) -> usize {
        self.rows.len()
    }
}

/// A knitting pattern: a chart over an open stitch legend and a colorwork palette, plus gauge.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct KnitPattern {
    pub name: String,
    pub construction: Construction,
    pub first_row_side: Side,
    pub gauge: Gauge,
    pub palette: Vec<Color>,
    pub legend: StitchLegend,
    pub chart: Chart,
    pub notes: String,
}

impl KnitPattern {
    /// The side chart row `row` (0-based, bottom row = 0) is worked from. In the round every row is
    /// RS; flat alternates from [`KnitPattern::first_row_side`].
    pub fn row_side(&self, row: usize) -> Side {
        match self.construction {
            Construction::InTheRound => Side::Rs,
            Construction::Flat => {
                let even = row % 2 == 0;
                match (self.first_row_side, even) {
                    (Side::Rs, true) | (Side::Ws, false) => Side::Rs,
                    _ => Side::Ws,
                }
            }
        }
    }

    /// Serialize to the native `.plyknit` format (pretty JSON). Round-trips losslessly for a valid
    /// pattern. A NaN/infinite gauge is REJECTED here: serde would emit JSON `null`, which then fails
    /// to parse back (a write-then-unreadable file), so we fail the save cleanly instead.
    pub fn to_json(&self) -> Result<String, KnitError> {
        if !self.gauge.sts.is_finite() || !self.gauge.rows.is_finite() {
            return Err(KnitError::NonFiniteGauge);
        }
        Ok(serde_json::to_string_pretty(self)?)
    }

    /// Parse the native `.plyknit` format.
    pub fn from_json(s: &str) -> Result<Self, KnitError> {
        Ok(serde_json::from_str(s)?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::error::KnitError;

    /// A tiny flat 1x1 ribbing chart — the model smoke fixture.
    fn ribbing() -> KnitPattern {
        let k = Cell::of(builtin::KNIT);
        let p = Cell::of(builtin::PURL);
        KnitPattern {
            name: "1x1 rib".into(),
            construction: Construction::Flat,
            first_row_side: Side::Rs,
            gauge: Gauge { sts: 24.0, rows: 32.0, unit: Unit::Inches },
            palette: vec![Color::WHITE],
            legend: StitchLegend::builtin(),
            chart: Chart {
                width: 2,
                rows: vec![Row::plain(vec![k, p]), Row::plain(vec![k, p])],
            },
            notes: String::new(),
        }
    }

    #[test]
    fn json_round_trips() {
        let p = ribbing();
        let json = p.to_json().unwrap();
        let back = KnitPattern::from_json(&json).unwrap();
        assert_eq!(back, p);
    }

    #[test]
    fn builtin_ws_variants_resolve() {
        let leg = StitchLegend::builtin();
        assert_eq!(leg.get(builtin::KNIT).unwrap().ws_variant, Some(builtin::PURL));
        assert_eq!(leg.get(builtin::PURL).unwrap().ws_variant, Some(builtin::KNIT));
        // Every ws_variant points at a real legend entry.
        for s in &leg.stitches {
            if let Some(ws) = s.ws_variant {
                assert!(leg.get(ws).is_some(), "ws_variant {ws} for '{}' must exist", s.symbol);
            }
        }
    }

    #[test]
    fn stitch_deltas_match_knitting_reality() {
        let leg = StitchLegend::builtin();
        assert_eq!(leg.get(builtin::YO).unwrap().delta(), 1, "yo is an increase");
        assert_eq!(leg.get(builtin::K2TOG).unwrap().delta(), -1, "k2tog is a decrease");
        assert_eq!(leg.get(builtin::CDD).unwrap().delta(), -2, "cdd removes two");
        assert_eq!(leg.get(builtin::KFB).unwrap().delta(), 1, "kfb is 1->2");
        assert_eq!(leg.get(builtin::KNIT).unwrap().delta(), 0);
        assert_eq!(leg.get(builtin::NO_STITCH).unwrap().delta(), 0);
    }

    #[test]
    fn cable_span_is_count_neutral() {
        let c = CableDef { front: 2, back: 2, direction: Cross::Right, front_purl: false, back_purl: false };
        assert_eq!(c.span(), 4);
    }

    #[test]
    fn flat_alternates_side_round_is_all_rs() {
        let mut p = ribbing();
        assert_eq!(p.row_side(0), Side::Rs);
        assert_eq!(p.row_side(1), Side::Ws);
        assert_eq!(p.row_side(2), Side::Rs);
        p.first_row_side = Side::Ws;
        assert_eq!(p.row_side(0), Side::Ws);
        assert_eq!(p.row_side(1), Side::Rs);
        p.construction = Construction::InTheRound;
        assert_eq!(p.row_side(1), Side::Rs, "in the round every row is RS");
    }

    #[test]
    fn gauge_derives_per_unit_window_aware() {
        let inch = Gauge { sts: 22.0, rows: 30.0, unit: Unit::Inches };
        assert_eq!(inch.sts_per_unit(), 5.5); // 22 / 4 in
        assert_eq!(inch.rows_per_unit(), 7.5);
        // The metric convention is per 10 cm, so the divisor is 10 — not 4.
        let cm = Gauge { sts: 22.0, rows: 30.0, unit: Unit::Centimeters };
        assert_eq!(cm.sts_per_unit(), 2.2); // 22 / 10 cm
        assert_eq!(cm.rows_per_unit(), 3.0);
    }

    #[test]
    fn non_finite_gauge_rejected_on_save() {
        // serde would write a NaN/Inf gauge as JSON `null`, which can't be parsed back; reject early.
        let mut p = ribbing();
        p.gauge.sts = f32::NAN;
        assert!(matches!(p.to_json(), Err(KnitError::NonFiniteGauge)));
        p.gauge.sts = f32::INFINITY;
        assert!(p.to_json().is_err());
    }
}
