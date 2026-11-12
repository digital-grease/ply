//! Transparently-mirrored KNITTING DTOs (M5) — the knit analog of `dto.rs`.
//!
//! The engine `KnitPattern` would cross FFI as an opaque, single-use handle (frb's default for a
//! `pub use`'d engine struct). An interactive editor can't live with that, so it speaks these plain
//! mirrored structs/enums declared in the bridge. All conversions to/from the engine live HERE: the
//! 0-based `StitchId`/`ColorIndex` (`usize`) <-> `u32` and the `usize` chart dims <-> `u32` base
//! conversions happen at this boundary, never in the engine or on the Dart side.
//!
//! `ColorDto`, `UnitKind`, and `SeverityKind` are REUSED from `dto.rs` so weaving and knitting share
//! one Dart enum/struct rather than minting parallel copies.

use ply_common::{Color, Unit, YarnWeight};
use ply_knit::pattern::{
    CableDef, Cell, Chart, Construction, Cross, Gauge, KnitPattern, Repeat, RepeatSpan, Row, Side,
    StitchDef, StitchLegend,
};
use ply_knit::validate::{KnitIssue, Severity};
use ply_knit::KnitError;

use crate::dto::{ColorDto, SeverityKind, UnitKind};

// --- enums (flat C-like; frb mirrors them as plain Dart enums) -------------------------------------

pub enum ConstructionKind {
    Flat,
    InTheRound,
}

/// Which face a flat row is worked from (in the round every row is `Rs`).
pub enum SideKind {
    Rs,
    Ws,
}

/// Which way a cable leans / which group crosses on top.
pub enum CrossKind {
    Right,
    Left,
}

/// Craft Yarn Council weight category, used to seed a default gauge.
pub enum YarnWeightKind {
    Lace,
    SuperFine,
    Fine,
    Light,
    Medium,
    Bulky,
    SuperBulky,
    Jumbo,
}

/// How many times a horizontal repeat span is worked. A data-carrying enum, so frb mirrors it as a
/// Dart freezed union (regenerate freezed after codegen, like `DriveDto`).
pub enum RepeatDto {
    Times { count: u16 },
    ToEnd,
}

// --- structs ---------------------------------------------------------------------------------------

/// Stitches AND rows per gauge window (4 in / 10 cm, per `unit`).
pub struct GaugeDto {
    pub sts: f32,
    pub rows: f32,
    pub unit: UnitKind,
}

pub struct CableDefDto {
    pub front: u8,
    pub back: u8,
    pub direction: CrossKind,
    pub front_purl: bool,
    pub back_purl: bool,
}

/// One stitch in the open vocabulary. `ws_variant` is a 0-based legend index.
pub struct StitchDefDto {
    pub symbol: String,
    pub consumes: u8,
    pub produces: u8,
    pub ws_variant: Option<u32>,
    pub cable: Option<CableDefDto>,
    pub macro_rows: u8,
}

pub struct StitchLegendDto {
    pub stitches: Vec<StitchDefDto>,
}

/// A chart cell: a 0-based legend `stitch` index + an optional 0-based palette `color`.
pub struct CellDto {
    pub stitch: u32,
    pub color: Option<u32>,
}

pub struct RepeatSpanDto {
    pub start: u32,
    pub end: u32,
    pub count: RepeatDto,
}

pub struct RowDto {
    pub cells: Vec<CellDto>,
    pub repeats: Vec<RepeatSpanDto>,
}

pub struct ChartDto {
    pub width: u32,
    pub rows: Vec<RowDto>,
}

pub struct KnitPatternDto {
    pub name: String,
    pub construction: ConstructionKind,
    pub first_row_side: SideKind,
    /// Stitches cast on before chart row 1 (flat) or joined before round 1 (in the round); `None` =
    /// the pattern does not state one. See `KnitPattern::cast_on`.
    pub cast_on: Option<u32>,
    pub gauge: GaugeDto,
    pub palette: Vec<ColorDto>,
    pub legend: StitchLegendDto,
    pub chart: ChartDto,
    pub notes: String,
}

/// One validation problem, severity preserved (reuses the weave `SeverityKind`).
pub struct KnitIssueDto {
    pub severity: SeverityKind,
    pub message: String,
}

/// Why a `.plyknit` file could not be opened (see [`KnitFormatFailure`]).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KnitFormatFailureKind {
    /// Saved by a newer Ply with a schema this build does not know. The file must not be written to.
    NewerVersion,
    /// A Ply file of some other format (for example a nalbinding project).
    WrongFormat,
    /// Not a readable `.plyknit` file (bad JSON, a malformed envelope, or a missing field).
    Unreadable,
}

/// The typed error `parse_knit` returns, thrown as an exception on the Dart side so the app can say
/// "saved by a newer version of Ply" instead of showing a raw parser message.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KnitFormatFailure {
    pub kind: KnitFormatFailureKind,
    /// Human-readable detail (versions found / supported, or the parse error), for logs.
    pub message: String,
}

impl From<KnitError> for KnitFormatFailure {
    fn from(e: KnitError) -> Self {
        let kind = match e {
            KnitError::NewerVersion { .. } => KnitFormatFailureKind::NewerVersion,
            KnitError::WrongFormat { .. } => KnitFormatFailureKind::WrongFormat,
            KnitError::Json(_) | KnitError::Malformed(_) | KnitError::NonFiniteGauge => {
                KnitFormatFailureKind::Unreadable
            }
        };
        KnitFormatFailure {
            kind,
            message: e.to_string(),
        }
    }
}

// --- conversions (engine <-> DTO, the only place the base conversions live) ------------------------

impl From<Construction> for ConstructionKind {
    fn from(c: Construction) -> Self {
        match c {
            Construction::Flat => Self::Flat,
            Construction::InTheRound => Self::InTheRound,
        }
    }
}
impl From<ConstructionKind> for Construction {
    fn from(c: ConstructionKind) -> Self {
        match c {
            ConstructionKind::Flat => Self::Flat,
            ConstructionKind::InTheRound => Self::InTheRound,
        }
    }
}

impl From<Side> for SideKind {
    fn from(s: Side) -> Self {
        match s {
            Side::Rs => Self::Rs,
            Side::Ws => Self::Ws,
        }
    }
}
impl From<SideKind> for Side {
    fn from(s: SideKind) -> Self {
        match s {
            SideKind::Rs => Self::Rs,
            SideKind::Ws => Self::Ws,
        }
    }
}

impl From<Cross> for CrossKind {
    fn from(c: Cross) -> Self {
        match c {
            Cross::Right => Self::Right,
            Cross::Left => Self::Left,
        }
    }
}
impl From<CrossKind> for Cross {
    fn from(c: CrossKind) -> Self {
        match c {
            CrossKind::Right => Self::Right,
            CrossKind::Left => Self::Left,
        }
    }
}

impl From<YarnWeightKind> for YarnWeight {
    fn from(w: YarnWeightKind) -> Self {
        match w {
            YarnWeightKind::Lace => Self::Lace,
            YarnWeightKind::SuperFine => Self::SuperFine,
            YarnWeightKind::Fine => Self::Fine,
            YarnWeightKind::Light => Self::Light,
            YarnWeightKind::Medium => Self::Medium,
            YarnWeightKind::Bulky => Self::Bulky,
            YarnWeightKind::SuperBulky => Self::SuperBulky,
            YarnWeightKind::Jumbo => Self::Jumbo,
        }
    }
}

impl From<Repeat> for RepeatDto {
    fn from(r: Repeat) -> Self {
        match r {
            Repeat::Times(count) => Self::Times { count },
            Repeat::ToEnd => Self::ToEnd,
        }
    }
}
impl From<RepeatDto> for Repeat {
    fn from(r: RepeatDto) -> Self {
        match r {
            RepeatDto::Times { count } => Self::Times(count),
            RepeatDto::ToEnd => Self::ToEnd,
        }
    }
}

fn unit_to_dto(u: Unit) -> UnitKind {
    match u {
        Unit::Inches => UnitKind::Inches,
        Unit::Centimeters => UnitKind::Centimeters,
    }
}
fn unit_from_dto(u: UnitKind) -> Unit {
    match u {
        UnitKind::Inches => Unit::Inches,
        UnitKind::Centimeters => Unit::Centimeters,
    }
}

impl From<Gauge> for GaugeDto {
    fn from(g: Gauge) -> Self {
        GaugeDto {
            sts: g.sts,
            rows: g.rows,
            unit: unit_to_dto(g.unit),
        }
    }
}
impl From<GaugeDto> for Gauge {
    fn from(g: GaugeDto) -> Self {
        Gauge {
            sts: g.sts,
            rows: g.rows,
            unit: unit_from_dto(g.unit),
        }
    }
}

impl From<CableDef> for CableDefDto {
    fn from(c: CableDef) -> Self {
        CableDefDto {
            front: c.front,
            back: c.back,
            direction: c.direction.into(),
            front_purl: c.front_purl,
            back_purl: c.back_purl,
        }
    }
}
impl From<CableDefDto> for CableDef {
    fn from(c: CableDefDto) -> Self {
        CableDef {
            front: c.front,
            back: c.back,
            direction: c.direction.into(),
            front_purl: c.front_purl,
            back_purl: c.back_purl,
        }
    }
}

impl From<&StitchDef> for StitchDefDto {
    fn from(d: &StitchDef) -> Self {
        StitchDefDto {
            symbol: d.symbol.clone(),
            consumes: d.consumes,
            produces: d.produces,
            ws_variant: d.ws_variant.map(|v| v as u32),
            cable: d.cable.map(CableDefDto::from),
            macro_rows: d.macro_rows,
        }
    }
}
impl From<StitchDefDto> for StitchDef {
    fn from(d: StitchDefDto) -> Self {
        StitchDef {
            symbol: d.symbol,
            consumes: d.consumes,
            produces: d.produces,
            ws_variant: d.ws_variant.map(|v| v as usize),
            cable: d.cable.map(CableDef::from),
            macro_rows: d.macro_rows,
        }
    }
}

impl From<&StitchLegend> for StitchLegendDto {
    fn from(l: &StitchLegend) -> Self {
        StitchLegendDto {
            stitches: l.stitches.iter().map(StitchDefDto::from).collect(),
        }
    }
}
impl From<StitchLegendDto> for StitchLegend {
    fn from(l: StitchLegendDto) -> Self {
        StitchLegend {
            stitches: l.stitches.into_iter().map(StitchDef::from).collect(),
        }
    }
}

impl From<Cell> for CellDto {
    fn from(c: Cell) -> Self {
        CellDto {
            stitch: c.stitch as u32,
            color: c.color.map(|i| i as u32),
        }
    }
}
impl From<CellDto> for Cell {
    fn from(c: CellDto) -> Self {
        Cell {
            stitch: c.stitch as usize,
            color: c.color.map(|i| i as usize),
        }
    }
}

impl From<RepeatSpan> for RepeatSpanDto {
    fn from(r: RepeatSpan) -> Self {
        RepeatSpanDto {
            start: r.start as u32,
            end: r.end as u32,
            count: r.count.into(),
        }
    }
}
impl From<RepeatSpanDto> for RepeatSpan {
    fn from(r: RepeatSpanDto) -> Self {
        RepeatSpan {
            start: r.start as usize,
            end: r.end as usize,
            count: r.count.into(),
        }
    }
}

impl From<&Row> for RowDto {
    fn from(r: &Row) -> Self {
        RowDto {
            cells: r.cells.iter().map(|&c| CellDto::from(c)).collect(),
            repeats: r.repeats.iter().map(|&s| RepeatSpanDto::from(s)).collect(),
        }
    }
}
impl From<RowDto> for Row {
    fn from(r: RowDto) -> Self {
        Row {
            cells: r.cells.into_iter().map(Cell::from).collect(),
            repeats: r.repeats.into_iter().map(RepeatSpan::from).collect(),
        }
    }
}

impl From<&Chart> for ChartDto {
    fn from(c: &Chart) -> Self {
        ChartDto {
            width: c.width as u32,
            rows: c.rows.iter().map(RowDto::from).collect(),
        }
    }
}
impl From<ChartDto> for Chart {
    fn from(c: ChartDto) -> Self {
        Chart {
            width: c.width as usize,
            rows: c.rows.into_iter().map(Row::from).collect(),
        }
    }
}

fn color_to_dto(c: Color) -> ColorDto {
    ColorDto {
        r: c.r,
        g: c.g,
        b: c.b,
    }
}
fn color_from_dto(c: &ColorDto) -> Color {
    Color::rgb(c.r, c.g, c.b)
}

impl From<&KnitPattern> for KnitPatternDto {
    fn from(p: &KnitPattern) -> Self {
        KnitPatternDto {
            name: p.name.clone(),
            construction: p.construction.into(),
            first_row_side: p.first_row_side.into(),
            cast_on: p.cast_on,
            gauge: p.gauge.into(),
            palette: p.palette.iter().map(|&c| color_to_dto(c)).collect(),
            legend: StitchLegendDto::from(&p.legend),
            chart: ChartDto::from(&p.chart),
            notes: p.notes.clone(),
        }
    }
}
impl From<KnitPatternDto> for KnitPattern {
    fn from(p: KnitPatternDto) -> Self {
        KnitPattern {
            name: p.name,
            construction: p.construction.into(),
            first_row_side: p.first_row_side.into(),
            cast_on: p.cast_on,
            gauge: p.gauge.into(),
            palette: p.palette.iter().map(color_from_dto).collect(),
            legend: p.legend.into(),
            chart: p.chart.into(),
            notes: p.notes,
        }
    }
}

impl From<&KnitIssue> for KnitIssueDto {
    fn from(i: &KnitIssue) -> Self {
        KnitIssueDto {
            severity: match i.severity {
                Severity::Error => SeverityKind::Error,
                Severity::Warning => SeverityKind::Warning,
            },
            message: i.message.clone(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ply_knit::pattern::builtin;

    /// A non-trivial pattern (cm gauge, colorwork, a custom cable, a repeat span, every enum variant)
    /// must survive engine -> DTO -> engine unchanged, so no field is dropped at the boundary.
    #[test]
    fn pattern_dto_round_trips() {
        let cable = CableDef {
            front: 2,
            back: 1,
            direction: Cross::Left,
            front_purl: false,
            back_purl: true,
        };
        let mut legend = StitchLegend::builtin();
        legend.stitches.push(StitchDef {
            symbol: "2/1LPC".into(),
            consumes: 3,
            produces: 3,
            ws_variant: Some(builtin::PURL),
            cable: Some(cable),
            macro_rows: 1,
        });
        let p = KnitPattern {
            name: "swatch".into(),
            construction: Construction::InTheRound,
            first_row_side: Side::Ws,
            cast_on: Some(96),
            gauge: Gauge {
                sts: 22.5,
                rows: 30.0,
                unit: Unit::Centimeters,
            },
            palette: vec![Color::WHITE, Color::rgb(10, 20, 30)],
            legend,
            chart: Chart {
                width: 3,
                rows: vec![
                    Row {
                        cells: vec![
                            Cell {
                                stitch: builtin::KNIT,
                                color: Some(1),
                            },
                            Cell::of(builtin::YO),
                            Cell::of(builtin::K2TOG),
                        ],
                        repeats: vec![RepeatSpan {
                            start: 0,
                            end: 2,
                            count: Repeat::Times(4),
                        }],
                    },
                    Row::plain(vec![
                        Cell::of(builtin::PURL),
                        Cell::of(builtin::NO_STITCH),
                        Cell::of(builtin::CDD),
                    ]),
                ],
            },
            notes: "n".into(),
        };
        let back = KnitPattern::from(KnitPatternDto::from(&p));
        assert_eq!(back, p);
    }

    /// Authored repeats cross the boundary intact and mean the same thing behind it: the written
    /// instructions expand them and validation counts the worked row (the R-02 example, 14 worked
    /// stitches drawn as 6, then a plain 6-stitch row).
    #[test]
    fn repeats_are_worked_through_the_bridge() {
        let k = Cell::of(builtin::KNIT);
        let p = Cell::of(builtin::PURL);
        let pattern = KnitPattern {
            name: "rib".into(),
            construction: Construction::Flat,
            first_row_side: Side::Rs,
            cast_on: None,
            gauge: Gauge {
                sts: 22.0,
                rows: 30.0,
                unit: Unit::Inches,
            },
            palette: vec![Color::WHITE],
            legend: StitchLegend::builtin(),
            chart: Chart {
                width: 6,
                rows: vec![
                    Row {
                        cells: vec![k, p, p, k, k, k],
                        repeats: vec![RepeatSpan {
                            start: 1,
                            end: 5,
                            count: Repeat::Times(3),
                        }],
                    },
                    Row::plain(vec![k; 6]),
                ],
            },
            notes: String::new(),
        };
        assert_eq!(
            crate::api::knit_written(KnitPatternDto::from(&pattern)),
            vec!["Row 1 (RS): k, [k2, p2] 3 times, k", "Row 2 (WS): p6"]
        );
        let issues = crate::api::validate_knit(KnitPatternDto::from(&pattern));
        assert_eq!(issues.len(), 1);
        assert!(matches!(issues[0].severity, SeverityKind::Error));
        assert_eq!(
            issues[0].message,
            "row 2 consumes 6 stitches but row 1 produced 14"
        );
    }

    /// Format problems reach Dart as a typed kind, not a raw parser string.
    #[test]
    fn format_errors_map_to_typed_failures() {
        let kind =
            |text: &str| KnitFormatFailure::from(KnitPattern::from_json(text).unwrap_err()).kind;
        assert_eq!(
            kind(r#"{"format":"ply.knit","schema_version":4,"document":{}}"#),
            KnitFormatFailureKind::NewerVersion
        );
        assert_eq!(
            kind(r#"{"format":"ply.nalbind","schemaVersion":2}"#),
            KnitFormatFailureKind::WrongFormat
        );
        assert_eq!(kind("{not json"), KnitFormatFailureKind::Unreadable);
        for current_or_older in [2, 3] {
            assert_eq!(
                kind(&format!(
                    r#"{{"format":"ply.knit","schema_version":{current_or_older},"document":{{}}}}"#
                )),
                KnitFormatFailureKind::Unreadable
            );
        }
    }

    /// A schema-version-2 file (the real bytes) opens through the bridge with the cast-on not set,
    /// and saving it writes the current version; a cast-on set in the app comes back in the written
    /// instructions and is what row 1 is checked against.
    #[test]
    fn a_v2_file_opens_without_a_cast_on_and_saves_as_v3() {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../fixtures/migrations/plyknit/schema-v2/rib-cast-on-unknown-flat.plyknit"
        );
        let v2 = std::fs::read_to_string(path).unwrap();
        let dto = crate::api::parse_knit(v2).unwrap();
        assert_eq!(dto.cast_on, None);
        let saved = crate::api::write_knit(dto).unwrap();
        assert_eq!(
            ply_knit::native::schema_version(&saved).unwrap(),
            ply_knit::KNIT_SCHEMA_VERSION
        );

        let mut dto = crate::api::parse_knit(saved).unwrap();
        dto.cast_on = Some(26);
        let lines = crate::api::knit_written(
            crate::api::parse_knit(crate::api::write_knit(dto).unwrap()).unwrap(),
        );
        assert_eq!(lines[0], "Cast on 26 sts.");
        assert_eq!(lines[1], "Row 1 (RS): k, *k2, p2; rep from * to last st, k");

        let mut short = crate::api::parse_knit(std::fs::read_to_string(path).unwrap()).unwrap();
        short.cast_on = Some(27);
        let issues = crate::api::validate_knit(short);
        assert!(matches!(issues[0].severity, SeverityKind::Error));
        assert!(
            issues[0].message.contains("the cast-on is 27 stitches"),
            "{}",
            issues[0].message
        );
    }
}
