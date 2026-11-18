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
use ply_knit::sections::{
    CloseMethod, Decrease, HeldCount, JoinSource, Ledger, LedgerLine, LineCount, NeedleCount,
    NeedleGroup, PickUpAlong, Piece, PieceSummary, Section, SectionIssue, ShapeUntil, Step,
    StepAction, TurnAt, TurnDecrease, TurnMethod, WorkStitch, WorkTo,
};
use ply_knit::validate::{KnitIssue, KnitLocation, Severity};
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

/// Craft Yarn Council weight category, used to seed a default gauge (and a material's weight).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
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

/// The plain stitch a section's work step or short row is worked in.
pub enum WorkStitchKind {
    Knit,
    Purl,
    InPattern,
}

/// How a short row turns.
pub enum TurnMethodKind {
    WrapAndTurn,
    German,
    Unspecified,
}

/// How far a section's work step goes along the row (data-carrying: a freezed union in Dart).
pub enum WorkToDto {
    End,
    Last { count: u32 },
    Count { count: u32 },
}

/// Where a short row turns (data-carrying: a freezed union in Dart). `BeforeGap` and `PastGap` turn
/// relative to the gap an earlier short row on this side left (schema version 5).
pub enum TurnAtDto {
    Last { count: u32 },
    Count { count: u32 },
    BeforeGap { count: u32 },
    PastGap { count: u32 },
}

/// A decrease that works two stitches together.
pub enum DecreaseKind {
    K2tog,
    Ssk,
    P2tog,
    Ssp,
}

/// A decrease worked just before a short row turns, then `after` more stitches.
pub struct TurnDecreaseDto {
    pub kind: DecreaseKind,
    pub after: u32,
}

/// How many times a shaping step shapes, or the stitch count it shapes to (a freezed union).
pub enum ShapeUntilDto {
    Times { count: u32 },
    Remain { count: u32 },
}

/// The edge a pick-up step picks up along (a freezed union): a side of a part worked flat (by the
/// id of the step that worked it flat), or any edge in the pattern's own words.
pub enum PickUpAlongDto {
    Piece { step: String },
    Edge { text: String },
}

/// A named needle group (instep, sole) with its stitch count and a note.
pub struct NeedleGroupDto {
    pub name: String,
    pub count: u32,
    pub notes: String,
}

/// How a closing step finishes the last stitches.
pub enum CloseMethodKind {
    Graft,
    ThreeNeedleBindOff,
}

/// What a join step works into the row (schema version 6, a freezed union): every stitch of another
/// piece (by the piece's id), or a group on hold (by the id of the step that put it there).
pub enum JoinSourceDto {
    Piece { piece: String },
    Held { hold: String },
}

/// What a section step does; mirrors `ply_knit::sections::StepAction` (a freezed union in Dart).
/// `stitch_change` is an `i32` here (the engine keeps `i64`, which frb would make a `BigInt` on the
/// web): `parse_knit` refuses a file whose change is past `MAX_LIVE_STITCHES` (1,000,000), so every
/// value that opens crosses exactly.
pub enum KnitStepActionDto {
    ChartRows {
        first: u32,
        last: u32,
    },
    Work {
        stitch: WorkStitchKind,
        to: WorkToDto,
        resolve_turns: bool,
    },
    ShortRow {
        stitch: WorkStitchKind,
        to: TurnAtDto,
        method: TurnMethodKind,
        resolve_turns: bool,
        decrease: Option<TurnDecreaseDto>,
    },
    CastOn {
        count: u32,
    },
    BindOff {
        count: Option<u32>,
        resolve_turns: bool,
    },
    Hold {
        count: Option<u32>,
        name: String,
    },
    Resume {
        hold: String,
        facing: Option<SideKind>,
    },
    Opaque {
        text: String,
        stitch_change: Option<i32>,
    },
    // Schema version 5: working in the round, sock heels and toes.
    JoinRound,
    WorkFlat {
        count: u32,
        name: String,
        slip_edges: bool,
    },
    Rows {
        count: u32,
        text: String,
    },
    /// `change` is per needle group named (or the whole needle), per shaping row; an `i32` like
    /// `stitch_change`, and capped the same way on load.
    Shape {
        change: i32,
        every: u32,
        until: ShapeUntilDto,
        groups: Vec<String>,
        text: String,
    },
    PickUp {
        count: u32,
        along: PickUpAlongDto,
        group: Option<String>,
    },
    Groups {
        groups: Vec<NeedleGroupDto>,
    },
    /// `holds` (schema version 6): two hold steps' ids, to close those groups against each other;
    /// empty to close the stitches on the needle.
    Close {
        method: CloseMethodKind,
        holds: Vec<String>,
    },
    RoundStart,
    // Schema version 6: several pieces.
    Join {
        source: JoinSourceDto,
        stitch: WorkStitchKind,
        resolve_turns: bool,
    },
}

// --- structs ---------------------------------------------------------------------------------------

/// One step of a section: a stable id (unique in the pattern) and what it does.
pub struct KnitStepDto {
    pub id: String,
    pub action: KnitStepActionDto,
}

/// A named section of the pattern's construction (see `ply_knit::sections`).
pub struct KnitSectionDto {
    pub id: String,
    pub name: String,
    pub notes: String,
    /// Whether the section is worked flat or in the round, when the pattern says.
    pub construction: Option<ConstructionKind>,
    /// The id of the piece the section works (`None`: the pattern's first piece).
    pub piece: Option<String>,
    pub steps: Vec<KnitStepDto>,
}

/// A piece of the garment (the body, a sleeve), with a stable id; the first is the main piece, the
/// one the pattern's cast-on is for.
pub struct KnitPieceDto {
    pub id: String,
    pub name: String,
}

/// Another piece set aside while a line's piece is worked, as the ledger counts it (`count`: `None`
/// when unknown).
pub struct KnitPieceCountDto {
    /// The piece's index in the pattern's pieces (its id and name are there).
    pub piece_index: u32,
    pub count: Option<u32>,
}

/// How a piece ends, from the ledger: its sections, its live stitches at the end (`None`:
/// unknown), where it was joined to another piece, and all of it in words.
pub struct KnitPieceSummaryDto {
    pub id: String,
    pub name: String,
    /// 0-based position in the pattern's pieces.
    pub index: u32,
    /// 0-based positions of the sections that work it, in order.
    pub section_indices: Vec<u32>,
    pub live: Option<u32>,
    /// The piece it was joined to, and the join step's 0-based section and step positions.
    pub joined_into: Option<String>,
    pub joined_section_index: Option<u32>,
    pub joined_step_index: Option<u32>,
    /// `18 sts left on the needle at the end`, `joined to the body at Yoke, step 3`.
    pub text: String,
}

/// A group of stitches on hold, as the ledger counts it. `hold` is the hold step's id.
pub struct KnitHeldCountDto {
    /// The group's index in [`KnitConstructionDto::holds`] (its name and hold step are there).
    pub hold_index: u32,
    pub count: u32,
}

/// A group put on hold, named once for the whole construction: the hold step's id and place, and
/// the group's name.
pub struct KnitHoldNameDto {
    pub hold_step_id: String,
    pub section_index: u32,
    pub step_index: u32,
    pub name: String,
}

/// A needle group as the ledger counts it.
pub struct KnitGroupCountDto {
    /// The group's name, as an index into [`KnitConstructionDto::group_names`].
    pub name_index: u32,
    pub count: u32,
}

/// What the stitch ledger knows after a line. The engine counts in `u64`, but its ledger never
/// holds more than `MAX_LIVE_STITCHES` (1,000,000) on the needle and on hold, and its lines are
/// capped, so these `u32`s never saturate in practice (they would, rather than wrap).
pub struct KnitNeedleCountDto {
    pub on_needle: u32,
    pub to_work: u32,
    pub mid_row: bool,
    pub past_turns: u32,
    pub pending_turns: u32,
    pub held: Vec<KnitHeldCountDto>,
    pub bound_off: u32,
    pub side: Option<SideKind>,
    /// The work is in the round (`to_work` is what is left of the round).
    pub in_round: bool,
    /// The needle groups, in order from the start of the round or row (empty without groups).
    pub groups: Vec<KnitGroupCountDto>,
    /// While part of the round is worked flat: the stitches worked flat (the rest of `on_needle`
    /// rests on the needle).
    pub flat: Option<u32>,
    pub grafted: u32,
    /// Every other piece that still has stitches, set aside while this one is worked.
    pub set_aside: Vec<KnitPieceCountDto>,
    /// Bound off and grafted in the whole pattern (`bound_off` and `grafted` are the piece's own).
    pub bound_off_total: u32,
    pub grafted_total: u32,
}

/// Whether a ledger line was counted, could not be known, or was refused.
pub enum KnitLineCountKind {
    Counted,
    Unknown,
    NotCounted,
}

/// One line of the worked construction: a step, or one chart row of a chart-rows step.
/// Lines carry positions and counts only, never a copy of an id or a name: the pattern and the
/// construction's tables have those (ADR 0020 review: a file's names would otherwise be repeated
/// on every line).
pub struct KnitLedgerLineDto {
    /// 0-based positions of the section and the step.
    pub section_index: u32,
    pub step_index: u32,
    /// The chart row (1-based) a chart-rows line works.
    pub chart_row: Option<u32>,
    pub label: Option<String>,
    pub text: String,
    pub opaque: bool,
    pub count_kind: KnitLineCountKind,
    pub count: Option<KnitNeedleCountDto>,
    /// The count in words, without brackets (`24 sts on the needle, 6 waiting past a turn`).
    pub count_text: String,
    /// The whole line as the written instructions give it.
    pub written: String,
    /// The index in the pattern's pieces of the piece the line's section works (`None` for a
    /// pattern of one piece).
    pub piece_index: Option<u32>,
}

/// A problem the ledger found, located by section and step position when it is about one.
pub struct KnitSectionIssueDto {
    pub severity: SeverityKind,
    /// 0-based positions of the section and step (ids can repeat in a hand-edited file; the
    /// positions never do).
    pub section_index: Option<u32>,
    pub step_index: Option<u32>,
    /// 1-based chart row, for a chart-rows step.
    pub chart_row: Option<u32>,
    /// Without its place, for showing beside the step.
    pub text: String,
    /// With its place (`Back, step 3: ...`), as validation reports it.
    pub message: String,
}

/// The pattern's worked construction: every ledger line and every problem, in one call.
pub struct KnitConstructionDto {
    pub lines: Vec<KnitLedgerLineDto>,
    pub issues: Vec<KnitSectionIssueDto>,
    /// How each of the pattern's pieces ends (empty for a pattern of one piece).
    pub pieces: Vec<KnitPieceSummaryDto>,
    /// Every group put on hold, in the order the ledger met them (counts name them by index).
    pub holds: Vec<KnitHoldNameDto>,
    /// Every needle group name the counts refer to by index.
    pub group_names: Vec<String>,
}

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
    /// The construction sections; empty for a chart-only pattern. See `KnitPattern::sections`.
    pub sections: Vec<KnitSectionDto>,
    /// The garment's pieces; empty for a pattern of one piece. See `KnitPattern::pieces`.
    pub pieces: Vec<KnitPieceDto>,
}

/// One validation problem, severity preserved (reuses the shared `SeverityKind`), with its stable
/// code, its place in words and where it is (ADR 0021).
pub struct KnitIssueDto {
    pub severity: SeverityKind,
    pub message: String,
    /// The stable code (`unknown-stitch`, `stitch-count-mismatch`, `section-step`, ...).
    pub code: String,
    /// Where it is, in words ("Row 3, column 4", "Back, step 2"); `None` for the whole pattern.
    pub place: Option<String>,
    /// Where it is, for the editor to go there; `None` for the whole pattern.
    pub location: Option<KnitLocationDto>,
}

/// What a [`KnitLocationDto`] names (mirrors `validate::KnitLocation`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KnitLocationKind {
    Row,
    Cell,
    Repeat,
    Step,
}

/// Where a knitting finding is, by 0-based position: `row` is the chart row (for a step, the chart
/// row it works, if any), `column` the storage column of a cell or the first of a repeat and
/// `end_column` one past a repeat's last; `section`, `step` and `piece` place a section finding.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct KnitLocationDto {
    pub kind: KnitLocationKind,
    pub row: Option<u32>,
    pub column: Option<u32>,
    pub end_column: Option<u32>,
    pub section: Option<u32>,
    pub step: Option<u32>,
    pub piece: Option<u32>,
}

impl KnitLocationDto {
    /// `None` for the whole pattern.
    pub fn of(l: &KnitLocation) -> Option<Self> {
        let n = |v: usize| Some(sat(v as u64));
        let blank = |kind| KnitLocationDto {
            kind,
            row: None,
            column: None,
            end_column: None,
            section: None,
            step: None,
            piece: None,
        };
        Some(match *l {
            KnitLocation::Pattern => return None,
            KnitLocation::Row { row } => KnitLocationDto {
                row: n(row),
                ..blank(KnitLocationKind::Row)
            },
            KnitLocation::Cell { row, column, .. } => KnitLocationDto {
                row: n(row),
                column: n(column),
                ..blank(KnitLocationKind::Cell)
            },
            KnitLocation::Repeat {
                row, start, end, ..
            } => KnitLocationDto {
                row: n(row),
                column: n(start),
                end_column: n(end),
                ..blank(KnitLocationKind::Repeat)
            },
            KnitLocation::Step {
                section,
                step,
                chart_row,
                piece,
                ..
            } => KnitLocationDto {
                row: chart_row.and_then(n),
                section: n(section),
                step: step.and_then(n),
                piece: piece.and_then(n),
                ..blank(KnitLocationKind::Step)
            },
        })
    }
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

/// Read a `.plyknit` file as the editor opens it: the engine reader, then the section limits. Sizes
/// from a file are untrusted: sections past the engine's limits (counts, text lengths, a stitch
/// change no ledger could apply) are refused instead of loaded, so every value that opens also fits
/// the DTOs exactly.
pub(crate) fn read_checked(text: &str) -> Result<KnitPattern, KnitFormatFailure> {
    let pattern = KnitPattern::from_json(text).map_err(KnitFormatFailure::from)?;
    ply_knit::sections::check_limits(&pattern).map_err(|why| KnitFormatFailure {
        kind: KnitFormatFailureKind::Unreadable,
        message: match why {
            ply_knit::sections::LimitError::TooLarge(why) => {
                format!("the pattern's sections are too large to open: {why}")
            }
            ply_knit::sections::LimitError::BadPieceId(why) => {
                format!("the pattern's pieces cannot be opened: {why}")
            }
        },
    })?;
    Ok(pattern)
}

/// The schema version a `.plyknit` file says it has, read from its envelope alone (nothing else in
/// the file is built, however large it is): 1 for a legacy file, `None` when it is not a `.plyknit`
/// at all; a newer version than this build reads is returned as found (at most `u32::MAX`), for the
/// caller to refuse.
pub(crate) fn document_version(text: &str) -> Option<u32> {
    match ply_knit::native::schema_version(text) {
        Ok(v) => Some(v),
        Err(KnitError::NewerVersion { found, .. }) => {
            Some(u32::try_from(found).unwrap_or(u32::MAX))
        }
        Err(_) => None,
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
            sections: p.sections.iter().map(KnitSectionDto::from).collect(),
            pieces: p
                .pieces
                .iter()
                .map(|x| KnitPieceDto {
                    id: x.id.clone(),
                    name: x.name.clone(),
                })
                .collect(),
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
            sections: p.sections.into_iter().map(Section::from).collect(),
            pieces: p
                .pieces
                .into_iter()
                .map(|x| Piece {
                    id: x.id,
                    name: x.name,
                })
                .collect(),
        }
    }
}

impl From<WorkStitch> for WorkStitchKind {
    fn from(s: WorkStitch) -> Self {
        match s {
            WorkStitch::Knit => Self::Knit,
            WorkStitch::Purl => Self::Purl,
            WorkStitch::InPattern => Self::InPattern,
        }
    }
}
impl From<WorkStitchKind> for WorkStitch {
    fn from(s: WorkStitchKind) -> Self {
        match s {
            WorkStitchKind::Knit => Self::Knit,
            WorkStitchKind::Purl => Self::Purl,
            WorkStitchKind::InPattern => Self::InPattern,
        }
    }
}

impl From<TurnMethod> for TurnMethodKind {
    fn from(m: TurnMethod) -> Self {
        match m {
            TurnMethod::WrapAndTurn => Self::WrapAndTurn,
            TurnMethod::German => Self::German,
            TurnMethod::Unspecified => Self::Unspecified,
        }
    }
}
impl From<TurnMethodKind> for TurnMethod {
    fn from(m: TurnMethodKind) -> Self {
        match m {
            TurnMethodKind::WrapAndTurn => Self::WrapAndTurn,
            TurnMethodKind::German => Self::German,
            TurnMethodKind::Unspecified => Self::Unspecified,
        }
    }
}

impl From<WorkTo> for WorkToDto {
    fn from(t: WorkTo) -> Self {
        match t {
            WorkTo::End => Self::End,
            WorkTo::Last(count) => Self::Last { count },
            WorkTo::Count(count) => Self::Count { count },
        }
    }
}
impl From<WorkToDto> for WorkTo {
    fn from(t: WorkToDto) -> Self {
        match t {
            WorkToDto::End => Self::End,
            WorkToDto::Last { count } => Self::Last(count),
            WorkToDto::Count { count } => Self::Count(count),
        }
    }
}

impl From<TurnAt> for TurnAtDto {
    fn from(t: TurnAt) -> Self {
        match t {
            TurnAt::Last(count) => Self::Last { count },
            TurnAt::Count(count) => Self::Count { count },
            TurnAt::BeforeGap(count) => Self::BeforeGap { count },
            TurnAt::PastGap(count) => Self::PastGap { count },
        }
    }
}
impl From<TurnAtDto> for TurnAt {
    fn from(t: TurnAtDto) -> Self {
        match t {
            TurnAtDto::Last { count } => Self::Last(count),
            TurnAtDto::Count { count } => Self::Count(count),
            TurnAtDto::BeforeGap { count } => Self::BeforeGap(count),
            TurnAtDto::PastGap { count } => Self::PastGap(count),
        }
    }
}

impl From<Decrease> for DecreaseKind {
    fn from(d: Decrease) -> Self {
        match d {
            Decrease::K2tog => Self::K2tog,
            Decrease::Ssk => Self::Ssk,
            Decrease::P2tog => Self::P2tog,
            Decrease::Ssp => Self::Ssp,
        }
    }
}
impl From<DecreaseKind> for Decrease {
    fn from(d: DecreaseKind) -> Self {
        match d {
            DecreaseKind::K2tog => Self::K2tog,
            DecreaseKind::Ssk => Self::Ssk,
            DecreaseKind::P2tog => Self::P2tog,
            DecreaseKind::Ssp => Self::Ssp,
        }
    }
}

impl From<TurnDecrease> for TurnDecreaseDto {
    fn from(d: TurnDecrease) -> Self {
        TurnDecreaseDto {
            kind: d.kind.into(),
            after: d.after,
        }
    }
}
impl From<TurnDecreaseDto> for TurnDecrease {
    fn from(d: TurnDecreaseDto) -> Self {
        TurnDecrease {
            kind: d.kind.into(),
            after: d.after,
        }
    }
}

impl From<ShapeUntil> for ShapeUntilDto {
    fn from(u: ShapeUntil) -> Self {
        match u {
            ShapeUntil::Times(count) => Self::Times { count },
            ShapeUntil::Remain(count) => Self::Remain { count },
        }
    }
}
impl From<ShapeUntilDto> for ShapeUntil {
    fn from(u: ShapeUntilDto) -> Self {
        match u {
            ShapeUntilDto::Times { count } => Self::Times(count),
            ShapeUntilDto::Remain { count } => Self::Remain(count),
        }
    }
}

impl From<PickUpAlong> for PickUpAlongDto {
    fn from(a: PickUpAlong) -> Self {
        match a {
            PickUpAlong::Piece(step) => Self::Piece { step },
            PickUpAlong::Edge(text) => Self::Edge { text },
        }
    }
}
impl From<PickUpAlongDto> for PickUpAlong {
    fn from(a: PickUpAlongDto) -> Self {
        match a {
            PickUpAlongDto::Piece { step } => Self::Piece(step),
            PickUpAlongDto::Edge { text } => Self::Edge(text),
        }
    }
}

impl From<CloseMethod> for CloseMethodKind {
    fn from(m: CloseMethod) -> Self {
        match m {
            CloseMethod::Graft => Self::Graft,
            CloseMethod::ThreeNeedleBindOff => Self::ThreeNeedleBindOff,
        }
    }
}
impl From<CloseMethodKind> for CloseMethod {
    fn from(m: CloseMethodKind) -> Self {
        match m {
            CloseMethodKind::Graft => Self::Graft,
            CloseMethodKind::ThreeNeedleBindOff => Self::ThreeNeedleBindOff,
        }
    }
}

/// An engine `i64` stitch change as the DTO's `i32`: exact for every file that opens (`parse_knit`
/// refuses a change past the ledger's cap, well inside `i32`); the clamp only guards a pattern
/// built in Rust.
fn change_to_dto(d: i64) -> i32 {
    d.clamp(i64::from(i32::MIN), i64::from(i32::MAX)) as i32
}

impl From<&StepAction> for KnitStepActionDto {
    fn from(a: &StepAction) -> Self {
        match a.clone() {
            StepAction::ChartRows { first, last } => Self::ChartRows { first, last },
            StepAction::Work {
                stitch,
                to,
                resolve_turns,
            } => Self::Work {
                stitch: stitch.into(),
                to: to.into(),
                resolve_turns,
            },
            StepAction::ShortRow {
                stitch,
                to,
                method,
                resolve_turns,
                decrease,
            } => Self::ShortRow {
                stitch: stitch.into(),
                to: to.into(),
                method: method.into(),
                resolve_turns,
                decrease: decrease.map(TurnDecreaseDto::from),
            },
            StepAction::CastOn { count } => Self::CastOn { count },
            StepAction::BindOff {
                count,
                resolve_turns,
            } => Self::BindOff {
                count,
                resolve_turns,
            },
            StepAction::Hold { count, name } => Self::Hold { count, name },
            StepAction::Resume { hold, facing } => Self::Resume {
                hold,
                facing: facing.map(SideKind::from),
            },
            StepAction::Opaque {
                text,
                stitch_change,
            } => Self::Opaque {
                text,
                // `parse_knit` refuses a change past the ledger's cap (well inside i32), so this is
                // exact for every file that opens; the clamp only guards a pattern built in Rust.
                stitch_change: stitch_change.map(change_to_dto),
            },
            StepAction::JoinRound {} => Self::JoinRound,
            StepAction::WorkFlat {
                count,
                name,
                slip_edges,
            } => Self::WorkFlat {
                count,
                name,
                slip_edges,
            },
            StepAction::Rows { count, text } => Self::Rows { count, text },
            StepAction::Shape {
                change,
                every,
                until,
                groups,
                text,
            } => Self::Shape {
                change: change_to_dto(change),
                every,
                until: until.into(),
                groups,
                text,
            },
            StepAction::PickUp {
                count,
                along,
                group,
            } => Self::PickUp {
                count,
                along: along.into(),
                group,
            },
            StepAction::Groups { groups } => Self::Groups {
                groups: groups
                    .into_iter()
                    .map(|g: NeedleGroup| NeedleGroupDto {
                        name: g.name,
                        count: g.count,
                        notes: g.notes,
                    })
                    .collect(),
            },
            StepAction::Close { method, holds } => Self::Close {
                method: method.into(),
                holds,
            },
            StepAction::RoundStart {} => Self::RoundStart,
            StepAction::Join {
                source,
                stitch,
                resolve_turns,
            } => Self::Join {
                source: match source {
                    JoinSource::Piece(piece) => JoinSourceDto::Piece { piece },
                    JoinSource::Held(hold) => JoinSourceDto::Held { hold },
                },
                stitch: stitch.into(),
                resolve_turns,
            },
        }
    }
}
impl From<KnitStepActionDto> for StepAction {
    fn from(a: KnitStepActionDto) -> Self {
        match a {
            KnitStepActionDto::ChartRows { first, last } => Self::ChartRows { first, last },
            KnitStepActionDto::Work {
                stitch,
                to,
                resolve_turns,
            } => Self::Work {
                stitch: stitch.into(),
                to: to.into(),
                resolve_turns,
            },
            KnitStepActionDto::ShortRow {
                stitch,
                to,
                method,
                resolve_turns,
                decrease,
            } => Self::ShortRow {
                stitch: stitch.into(),
                to: to.into(),
                method: method.into(),
                resolve_turns,
                decrease: decrease.map(TurnDecrease::from),
            },
            KnitStepActionDto::CastOn { count } => Self::CastOn { count },
            KnitStepActionDto::BindOff {
                count,
                resolve_turns,
            } => Self::BindOff {
                count,
                resolve_turns,
            },
            KnitStepActionDto::Hold { count, name } => Self::Hold { count, name },
            KnitStepActionDto::Resume { hold, facing } => Self::Resume {
                hold,
                facing: facing.map(Side::from),
            },
            KnitStepActionDto::Opaque {
                text,
                stitch_change,
            } => Self::Opaque {
                text,
                stitch_change: stitch_change.map(i64::from),
            },
            KnitStepActionDto::JoinRound => Self::JoinRound {},
            KnitStepActionDto::WorkFlat {
                count,
                name,
                slip_edges,
            } => Self::WorkFlat {
                count,
                name,
                slip_edges,
            },
            KnitStepActionDto::Rows { count, text } => Self::Rows { count, text },
            KnitStepActionDto::Shape {
                change,
                every,
                until,
                groups,
                text,
            } => Self::Shape {
                change: i64::from(change),
                every,
                until: until.into(),
                groups,
                text,
            },
            KnitStepActionDto::PickUp {
                count,
                along,
                group,
            } => Self::PickUp {
                count,
                along: along.into(),
                group,
            },
            KnitStepActionDto::Groups { groups } => Self::Groups {
                groups: groups
                    .into_iter()
                    .map(|g| NeedleGroup {
                        name: g.name,
                        count: g.count,
                        notes: g.notes,
                    })
                    .collect(),
            },
            KnitStepActionDto::Close { method, holds } => Self::Close {
                method: method.into(),
                holds,
            },
            KnitStepActionDto::RoundStart => Self::RoundStart {},
            KnitStepActionDto::Join {
                source,
                stitch,
                resolve_turns,
            } => Self::Join {
                source: match source {
                    JoinSourceDto::Piece { piece } => JoinSource::Piece(piece),
                    JoinSourceDto::Held { hold } => JoinSource::Held(hold),
                },
                stitch: stitch.into(),
                resolve_turns,
            },
        }
    }
}

impl From<&Section> for KnitSectionDto {
    fn from(s: &Section) -> Self {
        KnitSectionDto {
            id: s.id.clone(),
            name: s.name.clone(),
            notes: s.notes.clone(),
            construction: s.construction.map(ConstructionKind::from),
            piece: s.piece.clone(),
            steps: s
                .steps
                .iter()
                .map(|st| KnitStepDto {
                    id: st.id.clone(),
                    action: KnitStepActionDto::from(&st.action),
                })
                .collect(),
        }
    }
}
impl From<KnitSectionDto> for Section {
    fn from(s: KnitSectionDto) -> Self {
        Section {
            id: s.id,
            name: s.name,
            notes: s.notes,
            construction: s.construction.map(Construction::from),
            piece: s.piece,
            steps: s
                .steps
                .into_iter()
                .map(|st| Step {
                    id: st.id,
                    action: st.action.into(),
                })
                .collect(),
        }
    }
}

/// `u64` engine counts cross as `u32`, saturating.
fn sat(n: u64) -> u32 {
    u32::try_from(n).unwrap_or(u32::MAX)
}

impl From<&NeedleCount> for KnitNeedleCountDto {
    fn from(c: &NeedleCount) -> Self {
        KnitNeedleCountDto {
            on_needle: sat(c.on_needle),
            to_work: sat(c.to_work),
            mid_row: c.mid_row,
            past_turns: sat(c.past_turns),
            pending_turns: sat(c.pending_turns),
            held: c
                .held
                .iter()
                .map(|h: &HeldCount| KnitHeldCountDto {
                    hold_index: sat(h.hold as u64),
                    count: sat(h.count),
                })
                .collect(),
            bound_off: sat(c.bound_off),
            side: c.side.map(SideKind::from),
            in_round: c.in_round,
            groups: c
                .groups
                .iter()
                .map(|g| KnitGroupCountDto {
                    name_index: sat(g.name as u64),
                    count: sat(g.count),
                })
                .collect(),
            flat: c.flat.map(sat),
            grafted: sat(c.grafted),
            set_aside: c
                .set_aside
                .iter()
                .map(|a| KnitPieceCountDto {
                    piece_index: sat(a.piece as u64),
                    count: a.count.map(sat),
                })
                .collect(),
            bound_off_total: sat(c.bound_off_total),
            grafted_total: sat(c.grafted_total),
        }
    }
}

fn severity_to_dto(s: Severity) -> SeverityKind {
    SeverityKind::from(s)
}

impl KnitConstructionDto {
    /// The ledger of `pattern`: every line and problem by position, and the names the counts
    /// refer to, once each.
    pub fn of(pattern: &KnitPattern, ledger: &Ledger) -> Self {
        let line = |l: &LedgerLine| KnitLedgerLineDto {
            section_index: sat(l.section as u64),
            step_index: sat(l.step as u64),
            chart_row: l.chart_row.map(|r| sat(r as u64 + 1)),
            label: l.label.clone(),
            text: l.text.clone(),
            opaque: l.opaque,
            count_kind: match l.count {
                LineCount::Counted(_) => KnitLineCountKind::Counted,
                LineCount::Unknown => KnitLineCountKind::Unknown,
                LineCount::NotCounted => KnitLineCountKind::NotCounted,
            },
            count: l.count.counted().map(KnitNeedleCountDto::from),
            count_text: l.count.text(),
            written: l.written(),
            piece_index: l.piece.map(|i| sat(i as u64)),
        };
        let issue = |i: &SectionIssue| KnitSectionIssueDto {
            severity: severity_to_dto(i.severity),
            section_index: i.section.map(|s| sat(s as u64)),
            step_index: i.step.map(|t| sat(t as u64)),
            chart_row: i.chart_row.map(|r| sat(r as u64 + 1)),
            text: i.text.clone(),
            message: i.message.clone(),
        };
        let piece_id = |i: usize| {
            pattern
                .pieces
                .get(i)
                .map(|x| x.id.clone())
                .unwrap_or_default()
        };
        let piece = |s: &PieceSummary| KnitPieceSummaryDto {
            id: piece_id(s.piece),
            name: pattern
                .pieces
                .get(s.piece)
                .map(|x| x.name.clone())
                .unwrap_or_default(),
            index: sat(s.piece as u64),
            section_indices: s.sections.iter().map(|&i| sat(i as u64)).collect(),
            live: s.live.map(sat),
            joined_into: s.joined.map(|(into, _, _)| piece_id(into)),
            joined_section_index: s.joined.map(|(_, si, _)| sat(si as u64)),
            joined_step_index: s.joined.map(|(_, _, ti)| sat(ti as u64)),
            text: s.text.clone(),
        };
        KnitConstructionDto {
            lines: ledger.lines.iter().map(line).collect(),
            issues: ledger.issues.iter().map(issue).collect(),
            pieces: ledger.pieces.iter().map(piece).collect(),
            holds: ledger
                .names
                .holds
                .iter()
                .map(|h| KnitHoldNameDto {
                    hold_step_id: h.hold.clone(),
                    section_index: sat(h.section as u64),
                    step_index: sat(h.step as u64),
                    name: h.name.clone(),
                })
                .collect(),
            group_names: ledger.names.groups.clone(),
        }
    }
}

impl From<&KnitIssue> for KnitIssueDto {
    fn from(i: &KnitIssue) -> Self {
        KnitIssueDto {
            severity: severity_to_dto(i.severity),
            message: i.message.clone(),
            code: i.code.to_string(),
            place: match i.location {
                KnitLocation::Pattern => None,
                ref l => Some(l.text()),
            },
            location: KnitLocationDto::of(&i.location),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ply_knit::pattern::builtin;

    fn fixture(rel: &str) -> String {
        let path = format!("{}/../../fixtures/{rel}", env!("CARGO_MANIFEST_DIR"));
        std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{path}: {e}"))
    }

    #[test]
    fn the_version_of_a_large_hostile_file_comes_from_its_envelope() {
        // 20 MB of document the probe skips unread.
        let mut text = String::from(r#"{"format": "ply.knit", "schema_version": 6, "document": ["#);
        while text.len() < 20 * 1024 * 1024 {
            text.push_str("{},");
        }
        text.push_str("{}]}");
        assert_eq!(document_version(&text), Some(6));
        let newer = text.replacen("\"schema_version\": 6", "\"schema_version\": 7", 1);
        assert_eq!(document_version(&newer), Some(7));
        let huge = text.replacen("\"schema_version\": 6", "\"schema_version\": 9000000000", 1);
        assert_eq!(document_version(&huge), Some(u32::MAX));
        drop((text, newer, huge));
        assert_eq!(
            document_version(&fixture("migrations/plyknit/v0.1.5/sampler.plyknit")),
            Some(1)
        );
        let current = ply_knit::native::write(&ply_knit::KnitPattern::from(
            crate::api::knit_blank_pattern(),
        ))
        .unwrap();
        assert_eq!(
            document_version(&current),
            Some(crate::api::knit_schema_version())
        );
        for not_knit in [
            "not json",
            "[1, 2]",
            r#"{"format":"ply.nalbind","schemaVersion":3,"name":"x"}"#,
            r#"{"format":"ply.tablet","schema_version":1,"document":{}}"#,
            r#"{"format":"ply.knit","schema_version":0,"document":{}}"#,
            r#"{"format":"ply.knit","schema_version":"6","document":{}}"#,
        ] {
            assert_eq!(document_version(not_knit), None, "{not_knit}");
        }
    }

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
            sections: every_step_kind(),
            pieces: vec![
                Piece {
                    id: "piece-1".into(),
                    name: "body".into(),
                },
                Piece {
                    id: "piece-2".into(),
                    name: String::new(),
                },
            ],
        };
        let back = KnitPattern::from(KnitPatternDto::from(&p));
        assert_eq!(back, p);
    }

    /// One section holding every step kind, with every option set somewhere.
    fn every_step_kind() -> Vec<Section> {
        let step = |id: &str, action: StepAction| Step {
            id: id.into(),
            action,
        };
        vec![
            Section {
                id: "section-1".into(),
                name: "Shoulder".into(),
                notes: "n".into(),
                construction: None,
                piece: None,
                steps: vec![
                    step("a", StepAction::ChartRows { first: 1, last: 2 }),
                    step(
                        "b",
                        StepAction::Work {
                            stitch: WorkStitch::InPattern,
                            to: WorkTo::Last(3),
                            resolve_turns: true,
                        },
                    ),
                    step(
                        "c",
                        StepAction::Work {
                            stitch: WorkStitch::Purl,
                            to: WorkTo::End,
                            resolve_turns: false,
                        },
                    ),
                    step(
                        "d",
                        StepAction::ShortRow {
                            stitch: WorkStitch::Knit,
                            to: TurnAt::Count(4),
                            method: TurnMethod::German,
                            resolve_turns: true,
                            decrease: None,
                        },
                    ),
                    step(
                        "e",
                        StepAction::ShortRow {
                            stitch: WorkStitch::Purl,
                            to: TurnAt::Last(2),
                            method: TurnMethod::Unspecified,
                            resolve_turns: false,
                            decrease: None,
                        },
                    ),
                    step("f", StepAction::CastOn { count: 3 }),
                    step(
                        "g",
                        StepAction::BindOff {
                            count: Some(2),
                            resolve_turns: false,
                        },
                    ),
                    step(
                        "h",
                        StepAction::Hold {
                            count: None,
                            name: "neck".into(),
                        },
                    ),
                    step(
                        "i",
                        StepAction::Resume {
                            hold: "h".into(),
                            facing: Some(Side::Ws),
                        },
                    ),
                    step(
                        "j",
                        StepAction::Resume {
                            hold: "h".into(),
                            facing: None,
                        },
                    ),
                    step(
                        "k",
                        StepAction::Opaque {
                            text: "t".into(),
                            stitch_change: Some(-3),
                        },
                    ),
                    step(
                        "l",
                        StepAction::Opaque {
                            text: String::new(),
                            stitch_change: None,
                        },
                    ),
                ],
            },
            Section {
                id: "section-2".into(),
                name: String::new(),
                notes: String::new(),
                construction: None,
                piece: None,
                steps: Vec::new(),
            },
            Section {
                id: "section-3".into(),
                name: "Heel".into(),
                notes: String::new(),
                construction: Some(Construction::Flat),
                piece: None,
                steps: vec![
                    step(
                        "m",
                        StepAction::Groups {
                            groups: vec![NeedleGroup {
                                name: "sole".into(),
                                count: 4,
                                notes: "needle 1".into(),
                            }],
                        },
                    ),
                    step(
                        "n",
                        StepAction::WorkFlat {
                            count: 4,
                            name: "heel flap".into(),
                            slip_edges: true,
                        },
                    ),
                    step(
                        "o",
                        StepAction::Rows {
                            count: 6,
                            text: "sl 1, k1".into(),
                        },
                    ),
                    step(
                        "p",
                        StepAction::ShortRow {
                            stitch: WorkStitch::Purl,
                            to: TurnAt::BeforeGap(1),
                            method: TurnMethod::Unspecified,
                            resolve_turns: false,
                            decrease: Some(TurnDecrease {
                                kind: Decrease::P2tog,
                                after: 1,
                            }),
                        },
                    ),
                    step(
                        "q",
                        StepAction::ShortRow {
                            stitch: WorkStitch::Knit,
                            to: TurnAt::PastGap(2),
                            method: TurnMethod::German,
                            resolve_turns: true,
                            decrease: Some(TurnDecrease {
                                kind: Decrease::Ssk,
                                after: 0,
                            }),
                        },
                    ),
                    step(
                        "r",
                        StepAction::PickUp {
                            count: 3,
                            along: PickUpAlong::Piece("n".into()),
                            group: Some("sole".into()),
                        },
                    ),
                    step(
                        "s",
                        StepAction::PickUp {
                            count: 2,
                            along: PickUpAlong::Edge("the cast-on edge".into()),
                            group: None,
                        },
                    ),
                    step("t", StepAction::JoinRound {}),
                    step(
                        "u",
                        StepAction::Shape {
                            change: -2,
                            every: 2,
                            until: ShapeUntil::Remain(8),
                            groups: vec!["sole".into()],
                            text: "k1, ssk".into(),
                        },
                    ),
                    step(
                        "v",
                        StepAction::Shape {
                            change: 3,
                            every: 1,
                            until: ShapeUntil::Times(2),
                            groups: Vec::new(),
                            text: String::new(),
                        },
                    ),
                    step(
                        "w",
                        StepAction::Close {
                            method: CloseMethod::Graft,
                            holds: Vec::new(),
                        },
                    ),
                    step(
                        "x",
                        StepAction::Close {
                            method: CloseMethod::ThreeNeedleBindOff,
                            holds: Vec::new(),
                        },
                    ),
                    step("y", StepAction::RoundStart {}),
                ],
            },
            Section {
                id: "section-4".into(),
                name: "Thumb".into(),
                notes: String::new(),
                construction: Some(Construction::InTheRound),
                piece: Some("piece-2".into()),
                steps: vec![
                    step(
                        "z",
                        StepAction::Join {
                            source: JoinSource::Held("h".into()),
                            stitch: WorkStitch::Knit,
                            resolve_turns: true,
                        },
                    ),
                    step(
                        "z2",
                        StepAction::Join {
                            source: JoinSource::Piece("piece-1".into()),
                            stitch: WorkStitch::InPattern,
                            resolve_turns: false,
                        },
                    ),
                ],
            },
        ]
    }

    /// The (section, step) position of the step with id `id` in `p`.
    fn at(p: &KnitPatternDto, id: &str) -> (u32, u32) {
        for (si, s) in p.sections.iter().enumerate() {
            if let Some(ti) = s.steps.iter().position(|st| st.id == id) {
                return (si as u32, ti as u32);
            }
        }
        panic!("no step {id}");
    }

    /// The first ledger line of the step with id `id`.
    fn line_of<'c>(
        p: &KnitPatternDto,
        c: &'c KnitConstructionDto,
        id: &str,
    ) -> &'c KnitLedgerLineDto {
        let (si, ti) = at(p, id);
        c.lines
            .iter()
            .find(|l| (l.section_index, l.step_index) == (si, ti))
            .unwrap()
    }

    /// A garment in several pieces crosses with each line's piece, the pieces set aside and how
    /// each piece ends (the hand-derived yoke fixture, through the real bridge calls).
    #[test]
    fn a_yoke_construction_crosses_with_pieces_set_aside_and_joins() {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../fixtures/knitting/sections/yoke-sweater-round.plyknit"
        );
        let dto = crate::api::parse_knit(std::fs::read_to_string(path).unwrap()).unwrap();
        assert_eq!(dto.pieces.len(), 3);
        assert_eq!(dto.sections[1].piece.as_deref(), Some("piece-2"));
        assert!(dto.sections[0].piece.is_none());
        let p = KnitPattern::from(
            crate::api::parse_knit(std::fs::read_to_string(path).unwrap()).unwrap(),
        );
        let pdto = KnitPatternDto::from(&p);
        let c = crate::api::knit_construction(dto);
        assert!(c.issues.is_empty());
        let join = line_of(&pdto, &c, "step-22");
        assert_eq!(join.piece_index, Some(0));
        let count = join.count.as_ref().unwrap();
        assert_eq!(count.on_needle, 244);
        let aside: Vec<(u32, Option<u32>)> = count
            .set_aside
            .iter()
            .map(|a| (a.piece_index, a.count))
            .collect();
        assert_eq!(aside, vec![(2, Some(54))]);
        assert_eq!(pdto.pieces[2].name, "Right sleeve");
        // The groups on hold by index into the construction's table, named once there.
        let held: Vec<(String, u32)> = count
            .held
            .iter()
            .map(|h| (c.holds[h.hold_index as usize].name.clone(), h.count))
            .collect();
        assert_eq!(
            held,
            vec![
                ("left sleeve underarm".into(), 10),
                ("right sleeve underarm".into(), 10),
                ("body left underarm".into(), 10)
            ]
        );
        assert_eq!(c.holds[2].hold_step_id, "step-21");
        assert_eq!((c.holds[2].section_index, c.holds[2].step_index), (3, 1));
        let sleeve = &c.pieces[1];
        assert_eq!(
            (sleeve.id.as_str(), sleeve.index, sleeve.live),
            ("piece-2", 1, Some(0))
        );
        let last = c.lines.last().unwrap().count.as_ref().unwrap();
        assert_eq!((last.bound_off, last.bound_off_total), (136, 136));
        assert_eq!(sleeve.section_indices, vec![1]);
        assert_eq!(sleeve.joined_into.as_deref(), Some("piece-1"));
        assert_eq!(
            (sleeve.joined_section_index, sleeve.joined_step_index),
            (Some(3), Some(2))
        );
        assert_eq!(
            sleeve.text,
            "joined to Body at Joining round and yoke, step 3"
        );
        assert_eq!(c.pieces[0].section_indices, vec![0, 3, 4, 5]);
    }

    /// The real version-5 bytes open through the bridge as one piece (no pieces, every section's
    /// piece not stated), and saving writes the current version.
    #[test]
    fn a_v5_file_opens_as_one_piece_and_saves_as_current() {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../fixtures/migrations/plyknit/schema-v5/sock-heel-flap-round.plyknit"
        );
        let v5 = std::fs::read_to_string(path).unwrap();
        assert_eq!(ply_knit::native::schema_version(&v5).unwrap(), 5);
        let dto = crate::api::parse_knit(v5).unwrap();
        assert!(dto.pieces.is_empty());
        assert!(dto.sections.iter().all(|s| s.piece.is_none()));
        let c = crate::api::knit_construction(dto);
        assert!(c.pieces.is_empty());
        assert!(c.lines.iter().all(|l| l.piece_index.is_none()));
        let dto = crate::api::parse_knit(std::fs::read_to_string(path).unwrap()).unwrap();
        let saved = crate::api::write_knit(dto).unwrap();
        assert_eq!(
            ply_knit::native::schema_version(&saved).unwrap(),
            ply_knit::KNIT_SCHEMA_VERSION
        );
        let again = crate::api::parse_knit(saved.clone()).unwrap();
        assert_eq!(crate::api::write_knit(again).unwrap(), saved);
    }

    /// Every byte of text a construction crosses with.
    fn dto_bytes(c: &KnitConstructionDto) -> usize {
        let lines: usize = c
            .lines
            .iter()
            .map(|l| {
                l.text.len()
                    + l.count_text.len()
                    + l.written.len()
                    + l.label.as_ref().map_or(0, String::len)
            })
            .sum();
        let issues: usize = c
            .issues
            .iter()
            .map(|i| i.text.len() + i.message.len())
            .sum();
        let pieces: usize = c
            .pieces
            .iter()
            .map(|x| {
                x.id.len()
                    + x.name.len()
                    + x.text.len()
                    + x.joined_into.as_ref().map_or(0, String::len)
            })
            .sum();
        let holds: usize = c
            .holds
            .iter()
            .map(|h| h.hold_step_id.len() + h.name.len())
            .sum();
        lines + issues + pieces + holds + c.group_names.iter().map(String::len).sum::<usize>()
    }

    /// A hostile file at the limits crosses as a construction of about its own size: lines carry
    /// indices and counts, and every name is crossed once (the review's two measured cases: pieces
    /// at the limits with every line listing the others, and many long holds before many rows).
    #[test]
    fn a_construction_at_the_limits_is_about_the_size_of_its_file() {
        let step = |id: String, action: StepAction| Step { id, action };
        let rows = |n: usize| -> Vec<Step> {
            (0..n)
                .map(|i| {
                    step(
                        format!("r{i}"),
                        StepAction::Rows {
                            count: 1,
                            text: String::new(),
                        },
                    )
                })
                .collect()
        };
        let section = |id: String, piece: Option<String>, steps: Vec<Step>| Section {
            id,
            name: String::new(),
            notes: String::new(),
            construction: None,
            piece,
            steps,
        };
        // 50 pieces with 64-byte ids and 200-byte names, 49 one-step sections, then 9,900 rows.
        let mut many = KnitPattern::from(crate::api::knit_blank_pattern());
        many.cast_on = Some(1);
        let id = |i: usize| format!("{i:02}{}", "p".repeat(62));
        many.pieces = (0..ply_knit::sections::MAX_PIECES)
            .map(|i| Piece {
                id: id(i),
                name: "n".repeat(ply_knit::sections::MAX_PIECE_NAME_BYTES),
            })
            .collect();
        many.sections = (1..50)
            .map(|i| {
                section(
                    format!("s{i}"),
                    Some(id(i)),
                    vec![step(format!("c{i}"), StepAction::CastOn { count: 1 })],
                )
            })
            .collect();
        many.sections
            .push(section("last".into(), Some(id(0)), rows(9_900)));
        // 1,000 one-stitch holds with 100-byte ids and names, then 1,000 rows.
        let mut holds = KnitPattern::from(crate::api::knit_blank_pattern());
        holds.cast_on = Some(2_000);
        let mut steps: Vec<Step> = (0..1000)
            .map(|i| {
                step(
                    format!("{i:04}{}", "h".repeat(96)),
                    StepAction::Hold {
                        count: Some(1),
                        name: format!("{i:04}{}", "n".repeat(96)),
                    },
                )
            })
            .collect();
        steps.extend(rows(1000));
        holds.sections = vec![section("s".into(), None, steps)];
        for p in [many, holds] {
            let file = p.to_json().unwrap();
            assert!(
                crate::api::parse_knit(file.clone()).is_ok(),
                "within the limits"
            );
            let c = crate::api::knit_construction(KnitPatternDto::from(&p));
            let bytes = dto_bytes(&c);
            assert!(
                bytes < 2 * file.len() + 2_000_000,
                "{bytes} bytes of text for a {} byte file",
                file.len()
            );
        }
    }

    /// Piece ids are short ids (new in schema version 6): a file with another is refused on load,
    /// and the app's pattern is not written with one.
    #[test]
    fn a_piece_id_that_is_not_a_short_id_is_refused() {
        let mut pattern = KnitPattern::from(crate::api::knit_blank_pattern());
        pattern.pieces = vec![Piece {
            id: "x".repeat(65),
            name: "Body".into(),
        }];
        let Err(err) = crate::api::parse_knit(pattern.to_json().unwrap()) else {
            panic!("a long piece id must be refused");
        };
        assert_eq!(err.kind, KnitFormatFailureKind::Unreadable);
        assert!(
            err.message
                .starts_with("the pattern's pieces cannot be opened: "),
            "{}",
            err.message
        );
        let err = crate::api::write_knit(KnitPatternDto::from(&pattern)).unwrap_err();
        assert!(err.starts_with("a piece cannot be saved: "), "{err}");
        pattern.pieces[0].id = "piece-1".into();
        assert!(crate::api::write_knit(KnitPatternDto::from(&pattern)).is_ok());
    }

    /// A pattern past the piece limits is refused on load and never written.
    #[test]
    fn too_many_pieces_are_refused_on_load_and_on_save() {
        let mut pattern = KnitPattern::from(crate::api::knit_blank_pattern());
        pattern.pieces = (0..=ply_knit::sections::MAX_PIECES)
            .map(|i| Piece {
                id: format!("piece-{i}"),
                name: format!("p{i}"),
            })
            .collect();
        assert!(crate::api::parse_knit(pattern.to_json().unwrap()).is_err());
        assert!(crate::api::write_knit(KnitPatternDto::from(&pattern)).is_err());
        pattern.pieces.pop();
        let saved = crate::api::write_knit(KnitPatternDto::from(&pattern)).unwrap();
        assert!(crate::api::parse_knit(saved).is_ok());
    }

    /// A sock's ledger crosses with its needle groups, the part worked flat, rounds and grafting
    /// (the hand-derived fixture, through the real bridge calls).
    #[test]
    fn a_sock_construction_crosses_with_groups_flat_parts_and_grafting() {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../fixtures/knitting/sections/sock-heel-flap-round.plyknit"
        );
        let dto = crate::api::parse_knit(std::fs::read_to_string(path).unwrap()).unwrap();
        assert!(matches!(
            dto.sections[2].construction,
            Some(ConstructionKind::Flat)
        ));
        let pdto = crate::api::parse_knit(std::fs::read_to_string(path).unwrap()).unwrap();
        let c = crate::api::knit_construction(dto);
        assert!(c.issues.is_empty());
        let flap = line_of(&pdto, &c, "step-6").count.as_ref().unwrap();
        assert_eq!(
            (flap.on_needle, flap.flat, flap.in_round),
            (64, Some(32), false)
        );
        let names: Vec<(String, u32)> = flap
            .groups
            .iter()
            .map(|g| (c.group_names[g.name_index as usize].clone(), g.count))
            .collect();
        assert_eq!(names, vec![("sole".into(), 32), ("instep".into(), 32)]);
        let last = c.lines.last().unwrap().count.as_ref().unwrap();
        assert_eq!((last.on_needle, last.grafted), (0, 16));
        let joined = line_of(&pdto, &c, "step-23");
        assert!(joined.count.as_ref().unwrap().in_round);
        assert_eq!(
            joined.count_text,
            "66 sts on the needle: 34 sole, 32 instep; 32 still to work in this rnd"
        );
    }

    /// A pattern past the sizes `parse_knit` opens is never written: saving it is refused in plain
    /// words (the app keeps it unsaved), so Ply never writes a file it would then refuse to open.
    #[test]
    fn write_knit_refuses_what_parse_knit_would_not_open() {
        let mut pattern = KnitPattern::from(crate::api::knit_blank_pattern());
        let groups = |n: usize| StepAction::Groups {
            groups: (0..n)
                .map(|i| NeedleGroup {
                    name: format!("g{i}"),
                    count: 1,
                    notes: String::new(),
                })
                .collect(),
        };
        let section = |action: StepAction| Section {
            id: "s".into(),
            name: "S".into(),
            notes: String::new(),
            construction: None,
            piece: None,
            steps: vec![Step {
                id: "a".into(),
                action,
            }],
        };
        for action in [
            groups(ply_knit::sections::MAX_GROUPS + 1),
            StepAction::Rows {
                count: 1,
                text: "k".repeat(ply_knit::sections::MAX_TEXT_BYTES + 1),
            },
        ] {
            pattern.sections = vec![section(action)];
            let err = crate::api::write_knit(KnitPatternDto::from(&pattern)).unwrap_err();
            assert!(err.starts_with("a section is too large to save: "), "{err}");
            assert!(err.ends_with("Your changes are still here; shorten it and save again"));
            // And the same file, written another way, would indeed not open.
            assert!(crate::api::parse_knit(pattern.to_json().unwrap()).is_err());
        }
        // At the limits it saves and opens again.
        for action in [
            groups(ply_knit::sections::MAX_GROUPS),
            StepAction::Rows {
                count: 1,
                text: "\u{e9}".repeat(ply_knit::sections::MAX_TEXT_BYTES / 2),
            },
        ] {
            pattern.sections = vec![section(action)];
            let saved = crate::api::write_knit(KnitPatternDto::from(&pattern)).unwrap();
            assert!(crate::api::parse_knit(saved).is_ok());
        }
    }

    /// The real version-4 bytes open through the bridge with every section "not stated" and every
    /// short row without a decrease, and saving writes the current version.
    #[test]
    fn a_v4_file_opens_with_nothing_new_stated_and_saves_as_current() {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../fixtures/migrations/plyknit/schema-v4/shoulder-short-rows-flat.plyknit"
        );
        let v4 = std::fs::read_to_string(path).unwrap();
        assert_eq!(ply_knit::native::schema_version(&v4).unwrap(), 4);
        let dto = crate::api::parse_knit(v4).unwrap();
        assert!(dto.sections.iter().all(|s| s.construction.is_none()));
        let short_rows = dto
            .sections
            .iter()
            .flat_map(|s| &s.steps)
            .filter(|st| {
                matches!(
                    st.action,
                    KnitStepActionDto::ShortRow { decrease: None, .. }
                )
            })
            .count();
        assert_eq!(short_rows, 3);
        let saved = crate::api::write_knit(dto).unwrap();
        assert_eq!(
            ply_knit::native::schema_version(&saved).unwrap(),
            ply_knit::KNIT_SCHEMA_VERSION
        );
        let again = crate::api::parse_knit(saved.clone()).unwrap();
        assert_eq!(crate::api::write_knit(again).unwrap(), saved);
    }

    /// The construction call names every line and issue by section and step id, and its text and
    /// counts are the engine ledger's.
    #[test]
    fn construction_crosses_with_ids_counts_and_issues() {
        let mut pattern = KnitPattern::from(crate::api::knit_blank_pattern());
        pattern.cast_on = Some(10);
        pattern.sections = vec![Section {
            id: "section-1".into(),
            name: "Shoulder".into(),
            notes: String::new(),
            construction: None,
            piece: None,
            steps: vec![
                Step {
                    id: "step-1".into(),
                    action: StepAction::ShortRow {
                        stitch: WorkStitch::Knit,
                        to: TurnAt::Last(4),
                        method: TurnMethod::WrapAndTurn,
                        resolve_turns: false,
                        decrease: None,
                    },
                },
                Step {
                    id: "step-2".into(),
                    action: StepAction::BindOff {
                        count: Some(30),
                        resolve_turns: false,
                    },
                },
            ],
        }];
        let c = crate::api::knit_construction(KnitPatternDto::from(&pattern));
        assert_eq!(c.lines.len(), 2);
        let first = &c.lines[0];
        assert_eq!((first.section_index, first.step_index), (0, 0));
        assert_eq!(first.label.as_deref(), Some("Short row 1 (RS)"));
        assert_eq!(
            first.written,
            "Short row 1 (RS): knit to last 4 sts, wrap and turn. (10 sts on the needle, 4 waiting past a turn)"
        );
        let count = first.count.as_ref().unwrap();
        assert_eq!(
            (count.on_needle, count.to_work, count.past_turns),
            (10, 6, 4)
        );
        assert!(matches!(count.side, Some(SideKind::Ws)));
        assert!(matches!(
            c.lines[1].count_kind,
            KnitLineCountKind::NotCounted
        ));
        assert!(c.lines[1].count.is_none());
        let issue = c
            .issues
            .iter()
            .find(|i| (i.section_index, i.step_index) == (Some(0), Some(1)))
            .unwrap();
        assert!(matches!(issue.severity, SeverityKind::Error));
        assert_eq!(
            issue.text,
            "binds off 30 stitches, but only 6 stitches are left to work in this row"
        );
        assert!(issue.message.starts_with("Shoulder, step 2: "));
        // The same problems reach the editor's validation band.
        let messages: Vec<String> = crate::api::validate_knit(KnitPatternDto::from(&pattern))
            .into_iter()
            .map(|i| i.message)
            .collect();
        assert!(messages.contains(&issue.message));
        // A chart-only pattern has no construction.
        let blank = crate::api::knit_construction(crate::api::knit_blank_pattern());
        assert!(blank.lines.is_empty() && blank.issues.is_empty());
    }

    /// A file past the section limits is refused as unreadable instead of loaded; one at them opens.
    #[test]
    fn oversized_sections_are_refused_on_load() {
        let mut pattern = KnitPattern::from(crate::api::knit_blank_pattern());
        pattern.sections = vec![Section {
            id: "s".into(),
            name: "x".repeat(ply_knit::sections::MAX_TEXT_BYTES + 1),
            notes: String::new(),
            construction: None,
            piece: None,
            steps: Vec::new(),
        }];
        let Err(err) = crate::api::parse_knit(pattern.to_json().unwrap()) else {
            panic!("an oversized name must be refused");
        };
        assert_eq!(err.kind, KnitFormatFailureKind::Unreadable);
        assert!(err.message.contains("too large to open"), "{}", err.message);
        pattern.sections[0].name = "x".repeat(ply_knit::sections::MAX_TEXT_BYTES);
        pattern.sections[0].steps.push(Step {
            id: "a".into(),
            action: StepAction::Opaque {
                text: "t".into(),
                stitch_change: Some(-1_000_000),
            },
        });
        let dto = crate::api::parse_knit(pattern.to_json().unwrap()).unwrap();
        let back = KnitPattern::from(dto);
        assert_eq!(back, pattern, "a change at the cap crosses exactly");
        pattern.sections[0].steps[0].action = StepAction::Opaque {
            text: "t".into(),
            stitch_change: Some(i64::MAX),
        };
        assert!(crate::api::parse_knit(pattern.to_json().unwrap()).is_err());
    }

    /// The real version-3 bytes open through the bridge with no sections, and saving writes the
    /// current version; sections added in the app survive the next save and open.
    #[test]
    fn a_v3_file_opens_without_sections_and_saves_as_current() {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../fixtures/migrations/plyknit/schema-v3/rib-cast-on-flat.plyknit"
        );
        let dto = crate::api::parse_knit(std::fs::read_to_string(path).unwrap()).unwrap();
        assert!(dto.sections.is_empty());
        assert_eq!(dto.cast_on, Some(26));
        let mut dto = crate::api::parse_knit(crate::api::write_knit(dto).unwrap()).unwrap();
        dto.sections = every_step_kind().iter().map(KnitSectionDto::from).collect();
        let saved = crate::api::write_knit(dto).unwrap();
        assert_eq!(
            ply_knit::native::schema_version(&saved).unwrap(),
            ply_knit::KNIT_SCHEMA_VERSION
        );
        let back = KnitPattern::from(crate::api::parse_knit(saved).unwrap());
        assert_eq!(back.sections, every_step_kind());
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
            sections: Vec::new(),
            pieces: Vec::new(),
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
            kind(r#"{"format":"ply.knit","schema_version":7,"document":{}}"#),
            KnitFormatFailureKind::NewerVersion
        );
        assert_eq!(
            kind(r#"{"format":"ply.nalbind","schemaVersion":2}"#),
            KnitFormatFailureKind::WrongFormat
        );
        assert_eq!(kind("{not json"), KnitFormatFailureKind::Unreadable);
        for current_or_older in [2, 3, 4, 5, 6] {
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
