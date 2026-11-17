//! Transparently-mirrored editor DTOs (M2).
//!
//! The engine `Draft` crosses FFI today as an OPAQUE, single-use handle: the bridge fns take
//! it by value, and frb's default for a `pub use`'d engine struct is `RustOpaqueMoi` (see
//! `frb_generated.rs`). An interactive editor cannot live with a single-use handle, so the
//! editor speaks these DTOs instead — plain structs/enums DECLARED IN THE BRIDGE, which frb
//! mirrors transparently (the same mechanism that makes `PreviewImage` a real Dart class with
//! fields rather than an opaque handle).
//!
//! These convert to/from the engine `Draft` HERE AND ONLY HERE: the 1-based `ShaftId`/
//! `TreadleId` <-> `u16` and 0-based `ColorIndex(usize)` <-> `u32` base conversions live at
//! this boundary, never sprinkled through the engine or the Dart side (CLAUDE.md: convert at
//! the boundary only). `Drive` stays a real sum type so the illegal "both/neither" state is
//! unrepresentable (DATA_MODEL decision 1).

use ply_common::{Color, Unit};
use ply_weave::calc::{WarpPlan, WeftEstimate, WeftPlan, YarnEstimate};
use ply_weave::construction::Construction;
use ply_weave::draft::{
    ColorPlan, Draft, Drive, Liftplan, PickRole, RetainedSection, ShaftId, ShedType, ShotGroup,
    ShuttleId, Side, Threading, TieUp, TreadleId, Treadling, WeftWork,
};
use ply_weave::shadow::{
    ShadowBlock, ShadowError, ShadowLayout, ShadowParams, ShadowShafts, ShadowSystem,
    TwillDirection, WeftPhase,
};
use ply_weave::validate::{Severity, ValidationIssue, WeaveLocation};
use ply_weave::{DrawdownRegion, RenderError, RenderOptions};

/// An sRGB color. No alpha — the engine/WIF `Color` is RGB only.
pub struct ColorDto {
    pub r: u8,
    pub g: u8,
    pub b: u8,
}

/// Which way the loom moves the shafts named in the tie-up / liftplan.
pub enum ShedKind {
    Rising,
    Sinking,
}

/// What a weft pick is for in the working sequence, mirroring `draft::PickRole`. Flat C-like enum,
/// so frb mirrors it as a plain Dart enum (no freezed union). `Unknown` is the default: roles are
/// never inferred.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PickRoleKind {
    Unknown,
    Pattern,
    Tabby,
    TopLayer,
    BottomLayer,
}

impl From<PickRole> for PickRoleKind {
    fn from(r: PickRole) -> Self {
        match r {
            PickRole::Unknown => PickRoleKind::Unknown,
            PickRole::Pattern => PickRoleKind::Pattern,
            PickRole::Tabby => PickRoleKind::Tabby,
            PickRole::TopLayer => PickRoleKind::TopLayer,
            PickRole::BottomLayer => PickRoleKind::BottomLayer,
        }
    }
}

impl From<PickRoleKind> for PickRole {
    fn from(r: PickRoleKind) -> Self {
        match r {
            PickRoleKind::Unknown => PickRole::Unknown,
            PickRoleKind::Pattern => PickRole::Pattern,
            PickRoleKind::Tabby => PickRole::Tabby,
            PickRoleKind::TopLayer => PickRole::TopLayer,
            PickRoleKind::BottomLayer => PickRole::BottomLayer,
        }
    }
}

/// A selvedge as the weaver sees the cloth from the front of the loom, mirroring `draft::Side`. Flat
/// C-like enum, so frb mirrors it as a plain Dart enum.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ShuttleSideKind {
    Left,
    Right,
}

/// A shot group (consecutive picks worked as repeated passes in ONE shed), mirroring
/// `draft::ShotGroup`: `start` is the 0-based first pick, `picks` how many passes (at least 2).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ShotGroupDto {
    pub start: u32,
    pub picks: u32,
}

/// The side shuttle `shuttle` (1-based) starts its first pass from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ShuttleStartDto {
    pub shuttle: u8,
    pub side: ShuttleSideKind,
}

/// The declared double-weave construction, mirroring `Option<construction::Construction>` as one flat
/// C-like enum (frb mirrors it as a plain Dart enum, no freezed union). `None` = not declared, which is
/// every third-party WIF; a construction is never inferred (ADR 0010).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LayerConstructionKind {
    None,
    TwoLayers,
    Tube,
    DoubleWidthFoldLeft,
    DoubleWidthFoldRight,
}

impl From<Option<Construction>> for LayerConstructionKind {
    fn from(c: Option<Construction>) -> Self {
        match c {
            None => LayerConstructionKind::None,
            Some(Construction::TwoLayers) => LayerConstructionKind::TwoLayers,
            Some(Construction::Tube) => LayerConstructionKind::Tube,
            Some(Construction::DoubleWidth { fold: Side::Left }) => {
                LayerConstructionKind::DoubleWidthFoldLeft
            }
            Some(Construction::DoubleWidth { fold: Side::Right }) => {
                LayerConstructionKind::DoubleWidthFoldRight
            }
        }
    }
}

impl From<LayerConstructionKind> for Option<Construction> {
    fn from(k: LayerConstructionKind) -> Self {
        match k {
            LayerConstructionKind::None => None,
            LayerConstructionKind::TwoLayers => Some(Construction::TwoLayers),
            LayerConstructionKind::Tube => Some(Construction::Tube),
            LayerConstructionKind::DoubleWidthFoldLeft => {
                Some(Construction::DoubleWidth { fold: Side::Left })
            }
            LayerConstructionKind::DoubleWidthFoldRight => {
                Some(Construction::DoubleWidth { fold: Side::Right })
            }
        }
    }
}

/// Measurement unit for the draft's lengths.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UnitKind {
    Inches,
    Centimeters,
}

/// Which weave-structure family the "Generate structure" action builds. Plain/Twill/Satin generate a
/// tie-up (composed Dart-side with a threading + straight treadling); Overshot/DoubleWeave are
/// interdependent WHOLE-DRAFT structures built in the engine and returned as a complete `DraftDto`
/// via `generate_structure_dto`. ShadowWeave is whole-draft too, with its own typed parameters:
/// it is built by `generate_shadow_weave_dto` from a [`ShadowParamsDto`]. Flat C-like enum so frb
/// mirrors it as a plain Dart enum.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StructureFamily {
    Plain,
    Twill,
    Satin,
    Overshot,
    ShadowWeave,
    DoubleWeave,
}

/// Which threading the "Generate structure" action lays down. Flat C-like enum.
pub enum ThreadingKind {
    Straight,
    Point,
}

/// Shadow-weave shaft numbering (mirrors `shadow::ShadowSystem`). Both weave the same cloth.
pub enum ShadowSystemKind {
    /// Partners half the loom apart (1-3, 2-4), with the straight twill tie-up.
    Atwater,
    /// Partners on neighboring shafts (1-2, 3-4), with the renumbered tie-up.
    Powell,
}

/// How a shadow-weave block sequence is laid out (mirrors `shadow::ShadowLayout`).
pub enum ShadowLayoutKind {
    /// The sequence repeated as given.
    Repeat,
    /// The sequence, then mirrored back (the turning blocks keep their shadows).
    Point,
}

/// Which way the shadow-weave tie-up's twill runs (mirrors `shadow::TwillDirection`).
pub enum TwillDirectionKind {
    Forward,
    Reverse,
}

/// The shadow-weave weft color order (mirrors `shadow::WeftPhase`).
pub enum WeftPhaseKind {
    /// Each pick has the color of the thread it is treadled from: smooth block edges.
    Standard,
    /// Weft colors swapped within every pick pair: feathery block edges, same interlacement.
    Swapped,
}

/// One entry of a shadow-weave block sequence: 0-based `block` (0 = A) and its width in `units`
/// (one dark and one light thread each).
pub struct ShadowBlockDto {
    pub block: u16,
    pub units: u16,
}

/// Every parameter of the shadow-weave generator, mirrored transparently for Dart. The engine
/// checks them all and reports a problem as an error; nothing is clamped. `shafts` must be 4 or 8.
pub struct ShadowParamsDto {
    pub system: ShadowSystemKind,
    pub shafts: u16,
    pub layout: ShadowLayoutKind,
    /// The block sequence of one repeat (for a point layout, its first half).
    pub blocks: Vec<ShadowBlockDto>,
    pub direction: TwillDirectionKind,
    pub weft_phase: WeftPhaseKind,
    /// Whole threading repeats across the warp (at least 1).
    pub warp_repeats: u16,
    /// Whole treadling repeats up the weft (at least 1).
    pub weft_repeats: u16,
    /// Weave the first end and pick once more at the end.
    pub balance: bool,
}

impl TryFrom<ShadowParamsDto> for ShadowParams {
    type Error = ShadowError;

    fn try_from(d: ShadowParamsDto) -> Result<Self, Self::Error> {
        Ok(ShadowParams {
            system: match d.system {
                ShadowSystemKind::Atwater => ShadowSystem::Atwater,
                ShadowSystemKind::Powell => ShadowSystem::Powell,
            },
            shafts: ShadowShafts::try_from(d.shafts)?,
            layout: match d.layout {
                ShadowLayoutKind::Repeat => ShadowLayout::Repeat,
                ShadowLayoutKind::Point => ShadowLayout::Point,
            },
            blocks: d
                .blocks
                .iter()
                .map(|b| ShadowBlock {
                    block: b.block,
                    units: b.units,
                })
                .collect(),
            direction: match d.direction {
                TwillDirectionKind::Forward => TwillDirection::Forward,
                TwillDirectionKind::Reverse => TwillDirection::Reverse,
            },
            weft_phase: match d.weft_phase {
                WeftPhaseKind::Standard => WeftPhase::Standard,
                WeftPhaseKind::Swapped => WeftPhase::Swapped,
            },
            warp_repeats: d.warp_repeats,
            weft_repeats: d.weft_repeats,
            balance: d.balance,
        })
    }
}

/// How the raised-shaft pattern per pick is specified. A draft is EITHER treadled OR
/// liftplan-driven — a real sum type, never coexisting fields. All ids are 1-based `u16`.
pub enum DriveDto {
    Treadled {
        /// Per treadle, the shafts it is tied to (1-based).
        tieup: Vec<Vec<u16>>,
        /// Per pick, the treadle(s) pressed (1-based).
        treadling: Vec<Vec<u16>>,
    },
    Liftplan {
        /// Per pick, the shafts raised directly (1-based).
        liftplan: Vec<Vec<u16>>,
    },
}

/// The severity vocabulary every craft shares (`ply_common::readiness::Severity`, ADR 0021). Flat
/// C-like enum so frb mirrors it transparently; it preserves the engine severity the M1 bridge
/// flattened into a string.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SeverityKind {
    Error,
    Warning,
    /// Something Ply cannot check or represent, listed as such (readiness; a validator that has
    /// nothing it cannot check never reports it).
    Unsupported,
    /// Advice or a fact (weaving's advice about a deliberate instruction, a notation's formatting).
    Info,
}

impl From<Severity> for SeverityKind {
    fn from(s: Severity) -> Self {
        match s {
            Severity::Error => SeverityKind::Error,
            Severity::Warning => SeverityKind::Warning,
            Severity::Unsupported => SeverityKind::Unsupported,
            Severity::Info => SeverityKind::Info,
        }
    }
}

/// One validation problem, with its severity preserved (not flattened into the message) so
/// the editor can color Errors red vs Warnings amber, plus its stable code, its place in words and
/// where it is (ADR 0021).
pub struct ValidationIssueDto {
    /// The stable code (`weave.treadle_untied`, ...). Tests and navigation key on it.
    pub code: String,
    pub severity: SeverityKind,
    pub message: String,
    /// Where it is, in words ("Pick 3, treadle 9"); `None` for the whole draft.
    pub place: Option<String>,
    /// Where it is, for the editor to go there; `None` for the whole draft.
    pub location: Option<WeaveLocationDto>,
}

/// What a [`WeaveLocationDto`] names (mirrors `validate::WeaveLocation`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WeaveLocationKind {
    Threading,
    TieUp,
    Treadling,
    LiftPlan,
    WarpColor,
    WeftColor,
    Pick,
    Picks,
    PickList,
    PickRanges,
    Shaft,
    Shuttle,
}

/// Where a weaving finding is, in the weaver's 1-based numbers: the cell or the first of the picks
/// it names (a list or several ranges keep only their first pick or range here; the words in
/// `ValidationIssueDto::place` name them all). `color` is the 0-based palette index named.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct WeaveLocationDto {
    pub kind: WeaveLocationKind,
    pub end: Option<u32>,
    pub pick: Option<u32>,
    /// The last pick of the first range named (equal to `pick` for one pick).
    pub last_pick: Option<u32>,
    pub shaft: Option<u32>,
    pub treadle: Option<u32>,
    pub color: Option<u32>,
    pub shuttle: Option<u32>,
}

impl WeaveLocationDto {
    /// `None` for the whole draft.
    pub fn of(l: &WeaveLocation) -> Option<Self> {
        let blank = |kind| WeaveLocationDto {
            kind,
            end: None,
            pick: l.first_pick(),
            last_pick: l.last_pick(),
            shaft: None,
            treadle: None,
            color: None,
            shuttle: None,
        };
        Some(match *l {
            WeaveLocation::Draft => return None,
            WeaveLocation::Threading { end, shaft } => WeaveLocationDto {
                end: Some(end),
                shaft: Some(shaft),
                ..blank(WeaveLocationKind::Threading)
            },
            WeaveLocation::TieUp { treadle, shaft } => WeaveLocationDto {
                treadle: Some(treadle),
                shaft: Some(shaft),
                ..blank(WeaveLocationKind::TieUp)
            },
            WeaveLocation::Treadling { treadle, .. } => WeaveLocationDto {
                treadle: Some(treadle),
                ..blank(WeaveLocationKind::Treadling)
            },
            WeaveLocation::LiftPlan { shaft, .. } => WeaveLocationDto {
                shaft: Some(shaft),
                ..blank(WeaveLocationKind::LiftPlan)
            },
            WeaveLocation::WarpColor { end, color } => WeaveLocationDto {
                end: Some(end),
                color: Some(color),
                ..blank(WeaveLocationKind::WarpColor)
            },
            WeaveLocation::WeftColor { color, .. } => WeaveLocationDto {
                color: Some(color),
                ..blank(WeaveLocationKind::WeftColor)
            },
            WeaveLocation::Pick { .. } => blank(WeaveLocationKind::Pick),
            WeaveLocation::Picks { .. } => blank(WeaveLocationKind::Picks),
            WeaveLocation::PickList { .. } => blank(WeaveLocationKind::PickList),
            WeaveLocation::PickRanges { .. } => blank(WeaveLocationKind::PickRanges),
            WeaveLocation::Shaft { shaft } => WeaveLocationDto {
                shaft: Some(shaft),
                ..blank(WeaveLocationKind::Shaft)
            },
            WeaveLocation::Shuttle { shuttle } => WeaveLocationDto {
                shuttle: Some(shuttle),
                ..blank(WeaveLocationKind::Shuttle)
            },
        })
    }
}

/// Inputs to the warp-yarn estimate, mirroring `calc::WarpPlan` transparently (the engine
/// `WarpPlan` would otherwise cross FFI as an opaque, un-constructible handle). Lengths are in the
/// draft's unit; `takeup_shrinkage` is a FRACTION (0.10 = 10%).
pub struct WarpPlanDto {
    pub finished_length: f32,
    pub items: u32,
    pub ends: u32,
    pub loom_waste: f32,
    pub takeup_shrinkage: f32,
}

/// The warp-yarn estimate result, mirroring `calc::YarnEstimate` (else an opaque handle with no
/// readable fields). `warp_length` = length to wind (all items + take-up + one loom-waste);
/// `total_warp` = `warp_length * ends`.
pub struct YarnEstimateDto {
    pub warp_length: f32,
    pub total_warp: f32,
}

impl From<WarpPlanDto> for WarpPlan {
    fn from(d: WarpPlanDto) -> Self {
        WarpPlan {
            finished_length: d.finished_length,
            items: d.items,
            ends: d.ends,
            loom_waste: d.loom_waste,
            takeup_shrinkage: d.takeup_shrinkage,
        }
    }
}

impl From<&YarnEstimate> for YarnEstimateDto {
    fn from(e: &YarnEstimate) -> Self {
        YarnEstimateDto {
            warp_length: e.warp_length,
            total_warp: e.total_warp,
        }
    }
}

/// Inputs to the weft-yarn estimate, mirroring `calc::WeftPlan` transparently (else an opaque,
/// un-constructible handle). `picks_per_unit` is picks per unit of woven length (picks-per-inch in
/// an imperial draft); `width` is the woven width in the reed; `woven_length` is the length actually
/// woven per item; `takeup` is a width-direction FRACTION (0.10 = 10%).
pub struct WeftPlanDto {
    pub picks_per_unit: f32,
    pub width: f32,
    pub woven_length: f32,
    pub items: u32,
    pub takeup: f32,
}

/// The weft-yarn estimate result, mirroring `calc::WeftEstimate` (else an opaque handle). `picks` =
/// total picks across all items; `total_weft` = `picks * width * (1 + takeup)`, in the draft's unit.
pub struct WeftEstimateDto {
    pub picks: u32,
    pub total_weft: f32,
}

impl From<WeftPlanDto> for WeftPlan {
    fn from(d: WeftPlanDto) -> Self {
        WeftPlan {
            picks_per_unit: d.picks_per_unit,
            width: d.width,
            woven_length: d.woven_length,
            items: d.items,
            takeup: d.takeup,
        }
    }
}

impl From<&WeftEstimate> for WeftEstimateDto {
    fn from(e: &WeftEstimate) -> Self {
        WeftEstimateDto {
            picks: e.picks,
            total_weft: e.total_weft,
        }
    }
}

/// One `key=value` line of a retained (unmodeled) WIF section, mirrored transparently (frb does not
/// mirror raw tuples cleanly, so the engine's `(String, String)` becomes this named pair).
pub struct RetainedEntryDto {
    pub key: String,
    pub value: String,
}

/// An unmodeled WIF section kept verbatim, mirroring `draft::RetainedSection` for the Dart editor so
/// it survives a structural-edit re-serialize (not just the verbatim save path).
pub struct RetainedSectionDto {
    pub name: String,
    pub entries: Vec<RetainedEntryDto>,
}

/// Optional drawdown overlays the live editor toggles, mirroring `drawdown::RenderOptions`
/// transparently. All-off (the `Default`) is a plain cloth render, byte-identical to the no-options
/// path — so the thumbnail/library render simply omits this.
pub struct RenderOptionsDto {
    /// Draw a 1px seam between cells so the structure reads as a grid.
    pub gridlines: bool,
    /// Tint floats spanning this many cells OR MORE (warp or weft). 0 disables the cue.
    pub float_threshold: u32,
    /// Shade each cell as a rounded thread (warp-faced = vertical, weft-faced = horizontal) so the
    /// cloth reads as woven fabric rather than a flat color grid.
    pub thread_texture: bool,
}

impl From<RenderOptionsDto> for RenderOptions {
    fn from(d: RenderOptionsDto) -> Self {
        RenderOptions {
            gridlines: d.gridlines,
            float_threshold: d.float_threshold,
            thread_texture: d.thread_texture,
        }
    }
}

/// What kind of problem stopped a preview render (see [`RenderFailure`]).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RenderFailureKind {
    /// The DTO does not convert back to a draft. Reserved: the conversion currently accepts every
    /// DTO (structural problems are reported by validation, not by rendering).
    InvalidDraft,
    /// The draft is too large to preview within the device budget, even at 1 px per intersection.
    TooLarge,
    /// A buffer within budget could not be allocated.
    OutOfMemory,
    /// A region render asked for an empty region or one that reaches past the draft.
    InvalidRegion,
}

/// Why `render_preview_dto` or `render_region_dto` produced no image. Thrown as an exception on the
/// Dart side, so the UI can say "too large to preview" instead of showing a blank or a raw engine
/// message.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RenderFailure {
    pub kind: RenderFailureKind,
    /// Human-readable detail (dimensions and the limit hit), for logs and diagnostics.
    pub message: String,
}

impl From<RenderError> for RenderFailure {
    fn from(e: RenderError) -> Self {
        let kind = match e {
            RenderError::TooManyCells { .. }
            | RenderError::RasterTooLarge { .. }
            | RenderError::Overflow => RenderFailureKind::TooLarge,
            RenderError::AllocFailed { .. } => RenderFailureKind::OutOfMemory,
            RenderError::InvalidRegion { .. } => RenderFailureKind::InvalidRegion,
        };
        RenderFailure {
            kind,
            message: e.to_string(),
        }
    }
}

/// A rectangle of the drawdown for a region (viewport) render: `end_count` warp ends from the
/// 0-based end `end_start` (end 1 is `0`) by `pick_count` picks from the 0-based pick `pick_start`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DrawdownRegionDto {
    pub end_start: u32,
    pub end_count: u32,
    pub pick_start: u32,
    pub pick_count: u32,
}

impl TryFrom<DrawdownRegionDto> for DrawdownRegion {
    type Error = RenderFailure;

    /// The engine region, or an `InvalidRegion` failure when `start + count` overflows `usize`. An
    /// empty or out-of-draft region converts and is refused by the render itself.
    fn try_from(d: DrawdownRegionDto) -> Result<Self, RenderFailure> {
        let span = |start: u32, count: u32| {
            let start = usize::try_from(start).ok()?;
            Some(start..start.checked_add(usize::try_from(count).ok()?)?)
        };
        match (
            span(d.end_start, d.end_count),
            span(d.pick_start, d.pick_count),
        ) {
            (Some(ends), Some(picks)) => Ok(DrawdownRegion::new(ends, picks)),
            _ => Err(RenderFailure {
                kind: RenderFailureKind::InvalidRegion,
                message: format!("region {d:?} cannot be sized"),
            }),
        }
    }
}

/// The whole editable document, mirrored transparently for the Dart editor.
pub struct DraftDto {
    pub name: String,
    pub shafts: u16,
    pub treadles: u16,
    pub shed: ShedKind,
    pub unit: UnitKind,
    /// Per warp end (in warp order), the shaft(s) it threads through (1-based).
    pub threading: Vec<Vec<u16>>,
    pub drive: DriveDto,
    pub palette: Vec<ColorDto>,
    /// Per warp end, a 0-based index into `palette`.
    pub warp_colors: Vec<u32>,
    /// Per pick, a 0-based index into `palette`.
    pub weft_colors: Vec<u32>,
    /// Per warp end, a relative thread thickness (1.0 = base) driving variable-width drawdown cells.
    /// EMPTY means "all default 1.0" (a uniform grid); otherwise length-coupled to the ends.
    pub warp_thickness: Vec<f32>,
    /// Per pick, a relative thickness driving variable-height cells. Empty = all 1.0.
    pub weft_thickness: Vec<f32>,
    pub notes: String,
    /// Unmodeled WIF sections kept verbatim (see [`RetainedSectionDto`]).
    pub retained: Vec<RetainedSectionDto>,
    /// Per pick, its role. EMPTY means every role is unknown; otherwise length-coupled to the picks.
    pub pick_roles: Vec<PickRoleKind>,
    /// Per pick, the 1-based shuttle that carries it, `0` when unknown. EMPTY means every shuttle is
    /// unknown; otherwise length-coupled to the picks.
    pub pick_shuttles: Vec<u8>,
    /// Per pick, how many strands its pass carries (1..=4). EMPTY means one strand for every pick.
    pub pick_strands: Vec<u8>,
    /// The shot groups, in pick order.
    pub shot_groups: Vec<ShotGroupDto>,
    /// Each shuttle's starting side, ascending by shuttle; a shuttle not listed has none recorded.
    pub shuttle_starts: Vec<ShuttleStartDto>,
    /// The declared double-weave construction (`None` when not declared).
    pub construction: LayerConstructionKind,
}

// ---------------------------------------------------------------------------
// Conversions — the ONLY place id/index base conversion happens.
// ---------------------------------------------------------------------------

fn shaft_rows_out(rows: &[Vec<ShaftId>]) -> Vec<Vec<u16>> {
    rows.iter()
        .map(|r| r.iter().map(|s| s.0).collect())
        .collect()
}
fn treadle_rows_out(rows: &[Vec<TreadleId>]) -> Vec<Vec<u16>> {
    rows.iter()
        .map(|r| r.iter().map(|t| t.0).collect())
        .collect()
}
fn shaft_rows_in(rows: &[Vec<u16>]) -> Vec<Vec<ShaftId>> {
    rows.iter()
        .map(|r| r.iter().map(|&n| ShaftId(n)).collect())
        .collect()
}
fn treadle_rows_in(rows: &[Vec<u16>]) -> Vec<Vec<TreadleId>> {
    rows.iter()
        .map(|r| r.iter().map(|&n| TreadleId(n)).collect())
        .collect()
}

impl From<&ValidationIssue> for ValidationIssueDto {
    fn from(i: &ValidationIssue) -> Self {
        ValidationIssueDto {
            code: i.code.as_str().to_string(),
            severity: i.severity.into(),
            message: i.message.clone(),
            place: match i.location {
                WeaveLocation::Draft => None,
                ref l => Some(l.text()),
            },
            location: WeaveLocationDto::of(&i.location),
        }
    }
}

impl From<&Draft> for DraftDto {
    fn from(d: &Draft) -> Self {
        DraftDto {
            name: d.name.clone(),
            shafts: d.shafts,
            treadles: d.treadles,
            shed: match d.shed {
                ShedType::Rising => ShedKind::Rising,
                ShedType::Sinking => ShedKind::Sinking,
            },
            unit: match d.unit {
                Unit::Inches => UnitKind::Inches,
                Unit::Centimeters => UnitKind::Centimeters,
            },
            threading: shaft_rows_out(&d.threading.0),
            drive: match &d.drive {
                Drive::Treadled { tieup, treadling } => DriveDto::Treadled {
                    tieup: shaft_rows_out(&tieup.0),
                    treadling: treadle_rows_out(&treadling.0),
                },
                Drive::Liftplan(lp) => DriveDto::Liftplan {
                    liftplan: shaft_rows_out(&lp.0),
                },
            },
            palette: d
                .colors
                .palette
                .iter()
                .map(|c| ColorDto {
                    r: c.r,
                    g: c.g,
                    b: c.b,
                })
                .collect(),
            warp_colors: d.colors.warp.iter().map(|&i| i as u32).collect(),
            weft_colors: d.colors.weft.iter().map(|&i| i as u32).collect(),
            warp_thickness: d.warp_thickness.clone(),
            weft_thickness: d.weft_thickness.clone(),
            notes: d.notes.clone(),
            retained: d
                .retained
                .iter()
                .map(|s| RetainedSectionDto {
                    name: s.name.clone(),
                    entries: s
                        .entries
                        .iter()
                        .map(|(k, v)| RetainedEntryDto {
                            key: k.clone(),
                            value: v.clone(),
                        })
                        .collect(),
                })
                .collect(),
            pick_roles: d.pick_roles.iter().map(|&r| r.into()).collect(),
            pick_shuttles: d
                .weft_work
                .shuttles
                .iter()
                .map(|s| s.map_or(0, |s| s.0))
                .collect(),
            pick_strands: d.weft_work.strands.clone(),
            shot_groups: d
                .weft_work
                .shot_groups
                .iter()
                .map(|g| ShotGroupDto {
                    start: u32::try_from(g.start).unwrap_or(u32::MAX),
                    picks: u32::try_from(g.picks).unwrap_or(u32::MAX),
                })
                .collect(),
            shuttle_starts: d
                .weft_work
                .shuttle_starts
                .iter()
                .map(|(s, side)| ShuttleStartDto {
                    shuttle: s.0,
                    side: match side {
                        Side::Left => ShuttleSideKind::Left,
                        Side::Right => ShuttleSideKind::Right,
                    },
                })
                .collect(),
            construction: d.weft_work.construction.into(),
        }
    }
}

impl TryFrom<DraftDto> for Draft {
    type Error = String;

    fn try_from(dto: DraftDto) -> Result<Self, Self::Error> {
        Ok(Draft {
            name: dto.name,
            shafts: dto.shafts,
            treadles: dto.treadles,
            shed: match dto.shed {
                ShedKind::Rising => ShedType::Rising,
                ShedKind::Sinking => ShedType::Sinking,
            },
            unit: match dto.unit {
                UnitKind::Inches => Unit::Inches,
                UnitKind::Centimeters => Unit::Centimeters,
            },
            threading: Threading(shaft_rows_in(&dto.threading)),
            drive: match dto.drive {
                DriveDto::Treadled { tieup, treadling } => Drive::Treadled {
                    tieup: TieUp(shaft_rows_in(&tieup)),
                    treadling: Treadling(treadle_rows_in(&treadling)),
                },
                DriveDto::Liftplan { liftplan } => {
                    Drive::Liftplan(Liftplan(shaft_rows_in(&liftplan)))
                }
            },
            colors: ColorPlan {
                palette: dto
                    .palette
                    .iter()
                    .map(|c| Color::rgb(c.r, c.g, c.b))
                    .collect(),
                warp: dto.warp_colors.iter().map(|&i| i as usize).collect(),
                weft: dto.weft_colors.iter().map(|&i| i as usize).collect(),
            },
            warp_thickness: dto.warp_thickness,
            weft_thickness: dto.weft_thickness,
            notes: dto.notes,
            retained: dto
                .retained
                .into_iter()
                .map(|s| RetainedSection {
                    name: s.name,
                    entries: s.entries.into_iter().map(|e| (e.key, e.value)).collect(),
                })
                .collect(),
            pick_roles: dto.pick_roles.into_iter().map(PickRole::from).collect(),
            weft_work: WeftWork {
                shuttles: dto
                    .pick_shuttles
                    .iter()
                    .map(|&s| (s > 0).then_some(ShuttleId(s)))
                    .collect(),
                shuttle_starts: dto
                    .shuttle_starts
                    .iter()
                    .map(|s| {
                        let side = match s.side {
                            ShuttleSideKind::Left => Side::Left,
                            ShuttleSideKind::Right => Side::Right,
                        };
                        (ShuttleId(s.shuttle), side)
                    })
                    .collect(),
                strands: dto.pick_strands,
                shot_groups: dto
                    .shot_groups
                    .iter()
                    .map(|g| ShotGroup {
                        start: g.start as usize,
                        picks: g.picks as usize,
                    })
                    .collect(),
                construction: dto.construction.into(),
            },
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ply_weave::wif;

    fn assert_roundtrip(d: &Draft) {
        let back: Draft = Draft::try_from(DraftDto::from(d)).expect("DTO -> Draft");
        assert_eq!(d, &back, "Draft -> DraftDto -> Draft must be identity");
    }

    #[test]
    fn roundtrip_treadled_fixtures() {
        for text in [
            include_str!("../../ply-weave/tests/fixtures/twill_2_2.wif"),
            include_str!("../../ply-weave/tests/fixtures/plain_2x2.wif"),
        ] {
            assert_roundtrip(&wif::parse(text).expect("parse fixture"));
        }
    }

    #[test]
    fn roundtrip_liftplan_and_sinking() {
        // No liftplan fixture exists, so build one directly; also exercise Sinking shed.
        let d = Draft {
            name: "lp".into(),
            shafts: 2,
            treadles: 0,
            shed: ShedType::Sinking,
            unit: Unit::Centimeters,
            threading: Threading(vec![vec![ShaftId(1)], vec![ShaftId(2)]]),
            drive: Drive::Liftplan(Liftplan(vec![vec![ShaftId(1)], vec![ShaftId(2)]])),
            colors: ColorPlan {
                palette: vec![Color::BLACK, Color::WHITE],
                warp: vec![0, 0],
                weft: vec![1, 1],
            },
            // Non-default per-thread thickness must survive the DTO round-trip (Draft's PartialEq
            // includes these, so assert_roundtrip fails if the DTO drops or truncates them).
            warp_thickness: vec![1.0, 2.0],
            weft_thickness: vec![1.5, 1.0],
            notes: "n".into(),
            // A retained unmodeled section must survive the DTO round-trip too (Draft's PartialEq
            // includes `retained`, so assert_roundtrip fails if the DTO drops it). `[WARP THICKNESS]`
            // is modeled now, so use a vendor section as the unmodeled example.
            retained: vec![RetainedSection {
                name: "ACME VENDOR".into(),
                entries: vec![("Foo".into(), "Bar".into())],
            }],
            // Every role kind must cross the DTO and come back (Draft's PartialEq includes them).
            pick_roles: vec![PickRole::TopLayer, PickRole::BottomLayer],
            weft_work: Default::default(),
        };
        assert_roundtrip(&d);
    }

    #[test]
    fn roundtrip_weft_work() {
        use ply_weave::draft::{ShotGroup, ShuttleId, Side, WeftWork};
        let mut d = ply_weave::structure::overshot(8, 6, 2);
        d.weft_work = WeftWork {
            shuttles: vec![
                Some(ShuttleId(1)),
                None,
                Some(ShuttleId(8)),
                None,
                None,
                None,
            ],
            shuttle_starts: [(ShuttleId(1), Side::Left), (ShuttleId(8), Side::Right)]
                .into_iter()
                .collect(),
            strands: vec![1, 2, 3, 4, 1, 1],
            shot_groups: vec![ShotGroup { start: 2, picks: 2 }],
            construction: None,
        };
        assert_roundtrip(&d);
        let dto = DraftDto::from(&d);
        assert_eq!(
            dto.pick_shuttles,
            vec![1, 0, 8, 0, 0, 0],
            "unknown crosses as 0"
        );
        assert_eq!(dto.shot_groups, vec![ShotGroupDto { start: 2, picks: 2 }]);
        // Nothing recorded crosses as empty lists.
        let blank = DraftDto::from(&Draft::blank(4, 4));
        assert!(blank.pick_shuttles.is_empty() && blank.pick_strands.is_empty());
        assert!(blank.shot_groups.is_empty() && blank.shuttle_starts.is_empty());
    }

    #[test]
    fn roundtrip_every_pick_role() {
        let mut d = ply_weave::structure::overshot(8, 5, 2);
        d.pick_roles = vec![
            PickRole::Unknown,
            PickRole::Pattern,
            PickRole::Tabby,
            PickRole::TopLayer,
            PickRole::BottomLayer,
        ];
        assert_roundtrip(&d);
        // And the generator's own roles survive the DTO.
        assert_roundtrip(&ply_weave::structure::overshot(16, 8, 4));
    }
}
