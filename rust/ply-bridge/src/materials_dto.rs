//! Materials, swatches and traced planning DTOs (M8-01, ADR 0016), mirrored transparently for the
//! Dart app.
//!
//! The engine's records (`ply_common::materials`), the `materials.json` file
//! (`ply_common::materials_file`), the record reports (diagnostics and derived figures) and the
//! traced estimates (`ply_knit::plan`, `ply_weave::plan`) cross the boundary as these plain structs
//! and FLAT enums only (no data-carrying enum, so no freezed rebuild is needed). Conversions live
//! here and nowhere else. Records from Dart are untrusted: the file writer refuses one with an
//! error, and the planners check every value they use.

use ply_common::materials::{
    FiberPart, Figure, Material, RecordDiagnostic, Severity, Stage, Swatch, SwatchYarn, YarnRole,
};
use ply_common::materials_file::{MaterialLibrary, MaterialsFileError};
use ply_common::provenance::{Origin, Recorded, Source, TracedInput};
use ply_common::quantity::{CountOver, Length, LengthPerMass, LengthUnit, Mass, MassUnit};
use ply_common::{CraftKind, YarnWeight};

use crate::knit_dto::YarnWeightKind;

// --- quantities ------------------------------------------------------------------------------------

/// Mirrors `quantity::LengthUnit`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum QuantityLengthUnit {
    Millimeter,
    Centimeter,
    Meter,
    Inch,
    Yard,
}

/// Mirrors `quantity::MassUnit`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum QuantityMassUnit {
    Gram,
    Kilogram,
    Ounce,
    Pound,
}

/// Mirrors `provenance::Source`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SourceKind {
    Measured,
    Entered,
    Default,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct QuantityLengthDto {
    pub value: f64,
    pub unit: QuantityLengthUnit,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct QuantityMassDto {
    pub value: f64,
    pub unit: QuantityMassUnit,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct LengthPerMassDto {
    pub length: QuantityLengthDto,
    pub mass: QuantityMassDto,
}

/// A count over a span: "20 over 10 cm".
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct CountOverDto {
    pub count: f64,
    pub over: QuantityLengthDto,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct RecordedLengthDto {
    pub value: QuantityLengthDto,
    pub source: SourceKind,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct RecordedMassDto {
    pub value: QuantityMassDto,
    pub source: SourceKind,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct RecordedLengthPerMassDto {
    pub value: LengthPerMassDto,
    pub source: SourceKind,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct RecordedCountOverDto {
    pub value: CountOverDto,
    pub source: SourceKind,
}

// --- records ---------------------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq)]
pub struct FiberPartDto {
    pub fiber: String,
    pub percent: Option<f64>,
}

/// One material. Every field may be missing (`None` or empty text).
#[derive(Debug, Clone, PartialEq)]
pub struct MaterialDto {
    pub id: String,
    pub name: String,
    pub maker: String,
    pub fibers: Vec<FiberPartDto>,
    pub weight: Option<YarnWeightKind>,
    pub structure: String,
    pub length_per_mass: Option<RecordedLengthPerMassDto>,
    pub wpi: Option<RecordedCountOverDto>,
    pub color: String,
    pub dye_lot: String,
    pub available_mass: Option<RecordedMassDto>,
    pub available_length: Option<RecordedLengthDto>,
    pub notes: String,
}

/// The craft of a swatch.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SwatchCraftKind {
    Weaving,
    Knitting,
    Nalbinding,
}

/// Mirrors `materials::YarnRole`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum YarnRoleKind {
    Main,
    Contrast,
    Warp,
    Weft,
}

#[derive(Debug, Clone, PartialEq)]
pub struct SwatchYarnDto {
    pub material_id: Option<String>,
    pub name: String,
    pub role: Option<YarnRoleKind>,
}

/// What was measured at one stage of a swatch.
#[derive(Debug, Clone, PartialEq)]
pub struct SwatchStageDto {
    pub width: Option<RecordedLengthDto>,
    pub length: Option<RecordedLengthDto>,
    pub across: Option<RecordedCountOverDto>,
    pub along: Option<RecordedCountOverDto>,
    pub conditions: String,
}

/// One swatch. Every field may be missing.
#[derive(Debug, Clone, PartialEq)]
pub struct SwatchDto {
    pub id: String,
    pub name: String,
    pub craft: Option<SwatchCraftKind>,
    pub technique: String,
    pub date: Option<String>,
    pub yarns: Vec<SwatchYarnDto>,
    pub tools: String,
    pub sett: Option<RecordedCountOverDto>,
    pub width_in_reed: Option<RecordedLengthDto>,
    pub on_loom: SwatchStageDto,
    pub before: SwatchStageDto,
    pub after: SwatchStageDto,
    pub finishing: String,
    pub mass: Option<RecordedMassDto>,
    pub tension: String,
    pub provenance: String,
    pub notes: String,
}

/// Every material and swatch in `materials.json`, in order.
#[derive(Debug, Clone, PartialEq)]
pub struct MaterialLibraryDto {
    pub materials: Vec<MaterialDto>,
    pub swatches: Vec<SwatchDto>,
}

/// Why a `materials.json` could not be read.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MaterialsFileFailureKind {
    NewerVersion,
    WrongFormat,
    TooLarge,
    Unreadable,
}

/// The typed error `parse_materials` returns, thrown as an exception on the Dart side.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MaterialsFileFailure {
    pub kind: MaterialsFileFailureKind,
    /// Detail for logs. Never shown as the main message.
    pub message: String,
}

impl From<MaterialsFileError> for MaterialsFileFailure {
    fn from(e: MaterialsFileError) -> Self {
        let kind = match e {
            MaterialsFileError::NewerVersion { .. } => MaterialsFileFailureKind::NewerVersion,
            MaterialsFileError::WrongFormat { .. } => MaterialsFileFailureKind::WrongFormat,
            MaterialsFileError::TooLarge(_) => MaterialsFileFailureKind::TooLarge,
            MaterialsFileError::Malformed(_) => MaterialsFileFailureKind::Unreadable,
        };
        MaterialsFileFailure {
            kind,
            message: e.to_string(),
        }
    }
}

// --- reports ---------------------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RecordSeverityKind {
    Error,
    Warning,
}

/// One finding about a record (`code` is stable; `field` is the value's path).
#[derive(Debug, Clone, PartialEq)]
pub struct RecordDiagnosticDto {
    pub code: String,
    pub severity: RecordSeverityKind,
    pub field: String,
    pub message: String,
}

/// One derived figure, worked out from the record (never stored). Percentages are fractions.
#[derive(Debug, Clone, PartialEq)]
pub struct FigureDto {
    pub code: String,
    pub label: String,
    pub value: f64,
    pub text: String,
    pub from: String,
}

/// A record's diagnostics and derived figures.
#[derive(Debug, Clone, PartialEq)]
pub struct RecordReportDto {
    pub diagnostics: Vec<RecordDiagnosticDto>,
    pub figures: Vec<FigureDto>,
}

// --- traced estimates ------------------------------------------------------------------------------

/// One input of an estimate, with its source.
#[derive(Debug, Clone, PartialEq)]
pub struct TracedInputDto {
    pub key: String,
    pub label: String,
    pub value: String,
    pub source: SourceKind,
    pub basis: String,
    pub swatch_id: Option<String>,
    pub material_id: Option<String>,
}

/// Where an input of a request comes from (mirrors `provenance::Origin` without its value).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InputOriginKind {
    /// From the request's swatch (the engine reads the swatch; `value` is ignored).
    Swatch,
    Entered,
    /// One of Ply's defaults; `note` says what for.
    Default,
    /// From the open pattern or draft; `note` says what it is.
    Pattern,
}

/// A count-over-span input (a gauge, picks per inch).
#[derive(Debug, Clone, PartialEq)]
pub struct CountInputDto {
    pub origin: InputOriginKind,
    pub value: Option<CountOverDto>,
    pub note: String,
}

/// A length input (loom waste).
#[derive(Debug, Clone, PartialEq)]
pub struct LengthInputDto {
    pub origin: InputOriginKind,
    pub value: Option<QuantityLengthDto>,
    pub note: String,
}

/// A fraction input (0.1 = 10%: a buffer, a take-up).
#[derive(Debug, Clone, PartialEq)]
pub struct FractionInputDto {
    pub origin: InputOriginKind,
    pub value: f64,
    pub note: String,
}

/// A whole-number input (warp ends).
#[derive(Debug, Clone, PartialEq)]
pub struct WholeInputDto {
    pub origin: InputOriginKind,
    pub value: u32,
    pub note: String,
}

#[derive(Debug, Clone, PartialEq)]
pub struct KnitCastOnRequestDto {
    pub swatch: Option<SwatchDto>,
    pub gauge: CountInputDto,
    pub width: QuantityLengthDto,
    pub ease: QuantityLengthDto,
    pub repeat: u32,
}

#[derive(Debug, Clone, PartialEq)]
pub struct KnitYardageRequestDto {
    pub swatch: Option<SwatchDto>,
    pub gauge: CountInputDto,
    pub width: QuantityLengthDto,
    pub length: QuantityLengthDto,
    /// The swatch's one material, for the weighed-swatch method.
    pub yarn: Option<MaterialDto>,
    pub buffer: FractionInputDto,
}

#[derive(Debug, Clone, PartialEq)]
pub struct TracedCastOnDto {
    pub stitches: u32,
    pub inputs: Vec<TracedInputDto>,
    pub working: Vec<String>,
    pub notes: Vec<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum YardageMethodKind {
    WeighedSwatch,
    StockinetteRule,
}

#[derive(Debug, Clone, PartialEq)]
pub struct TracedYardageDto {
    pub method: YardageMethodKind,
    pub yards: f64,
    pub meters: f64,
    pub buffered_yards: f64,
    pub buffered_meters: f64,
    pub inputs: Vec<TracedInputDto>,
    pub working: Vec<String>,
    pub notes: Vec<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct WeaveWarpRequestDto {
    pub swatch: Option<SwatchDto>,
    pub finished_length: QuantityLengthDto,
    pub items: u32,
    pub ends: WholeInputDto,
    /// The cloth width the ends are for, when they come from the swatch's sett.
    pub sett_width: Option<QuantityLengthDto>,
    pub loom_waste: LengthInputDto,
    pub allowance: FractionInputDto,
}

#[derive(Debug, Clone, PartialEq)]
pub struct TracedWarpDto {
    pub ends: u32,
    pub warp_length: QuantityLengthDto,
    pub total: QuantityLengthDto,
    pub inputs: Vec<TracedInputDto>,
    pub working: Vec<String>,
    pub notes: Vec<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct WeaveWeftRequestDto {
    pub swatch: Option<SwatchDto>,
    pub ppi: CountInputDto,
    pub width: QuantityLengthDto,
    pub woven_length: QuantityLengthDto,
    pub items: u32,
    pub takeup: FractionInputDto,
}

#[derive(Debug, Clone, PartialEq)]
pub struct TracedWeftDto {
    pub picks: u32,
    pub total: QuantityLengthDto,
    pub inputs: Vec<TracedInputDto>,
    pub working: Vec<String>,
    pub notes: Vec<String>,
}

// --- conversions -----------------------------------------------------------------------------------

impl From<QuantityLengthUnit> for LengthUnit {
    fn from(k: QuantityLengthUnit) -> Self {
        match k {
            QuantityLengthUnit::Millimeter => LengthUnit::Millimeter,
            QuantityLengthUnit::Centimeter => LengthUnit::Centimeter,
            QuantityLengthUnit::Meter => LengthUnit::Meter,
            QuantityLengthUnit::Inch => LengthUnit::Inch,
            QuantityLengthUnit::Yard => LengthUnit::Yard,
        }
    }
}

impl From<LengthUnit> for QuantityLengthUnit {
    fn from(u: LengthUnit) -> Self {
        match u {
            LengthUnit::Millimeter => QuantityLengthUnit::Millimeter,
            LengthUnit::Centimeter => QuantityLengthUnit::Centimeter,
            LengthUnit::Meter => QuantityLengthUnit::Meter,
            LengthUnit::Inch => QuantityLengthUnit::Inch,
            LengthUnit::Yard => QuantityLengthUnit::Yard,
        }
    }
}

impl From<QuantityMassUnit> for MassUnit {
    fn from(k: QuantityMassUnit) -> Self {
        match k {
            QuantityMassUnit::Gram => MassUnit::Gram,
            QuantityMassUnit::Kilogram => MassUnit::Kilogram,
            QuantityMassUnit::Ounce => MassUnit::Ounce,
            QuantityMassUnit::Pound => MassUnit::Pound,
        }
    }
}

impl From<MassUnit> for QuantityMassUnit {
    fn from(u: MassUnit) -> Self {
        match u {
            MassUnit::Gram => QuantityMassUnit::Gram,
            MassUnit::Kilogram => QuantityMassUnit::Kilogram,
            MassUnit::Ounce => QuantityMassUnit::Ounce,
            MassUnit::Pound => QuantityMassUnit::Pound,
        }
    }
}

impl From<SourceKind> for Source {
    fn from(k: SourceKind) -> Self {
        match k {
            SourceKind::Measured => Source::Measured,
            SourceKind::Entered => Source::Entered,
            SourceKind::Default => Source::Default,
        }
    }
}

impl From<Source> for SourceKind {
    fn from(s: Source) -> Self {
        match s {
            Source::Measured => SourceKind::Measured,
            Source::Entered => SourceKind::Entered,
            Source::Default => SourceKind::Default,
        }
    }
}

impl From<QuantityLengthDto> for Length {
    fn from(d: QuantityLengthDto) -> Self {
        Length::new(d.value, d.unit.into())
    }
}

impl From<Length> for QuantityLengthDto {
    fn from(l: Length) -> Self {
        QuantityLengthDto {
            value: l.value,
            unit: l.unit.into(),
        }
    }
}

impl From<QuantityMassDto> for Mass {
    fn from(d: QuantityMassDto) -> Self {
        Mass::new(d.value, d.unit.into())
    }
}

impl From<Mass> for QuantityMassDto {
    fn from(m: Mass) -> Self {
        QuantityMassDto {
            value: m.value,
            unit: m.unit.into(),
        }
    }
}

impl From<LengthPerMassDto> for LengthPerMass {
    fn from(d: LengthPerMassDto) -> Self {
        LengthPerMass::new(d.length.into(), d.mass.into())
    }
}

impl From<LengthPerMass> for LengthPerMassDto {
    fn from(l: LengthPerMass) -> Self {
        LengthPerMassDto {
            length: l.length.into(),
            mass: l.mass.into(),
        }
    }
}

impl From<CountOverDto> for CountOver {
    fn from(d: CountOverDto) -> Self {
        CountOver::new(d.count, d.over.into())
    }
}

impl From<CountOver> for CountOverDto {
    fn from(c: CountOver) -> Self {
        CountOverDto {
            count: c.count,
            over: c.over.into(),
        }
    }
}

macro_rules! recorded {
    ($dto:ident, $inner_dto:ty, $inner:ty) => {
        impl From<$dto> for Recorded<$inner> {
            fn from(d: $dto) -> Self {
                Recorded {
                    value: <$inner>::from(d.value),
                    source: d.source.into(),
                }
            }
        }
        impl From<Recorded<$inner>> for $dto {
            fn from(r: Recorded<$inner>) -> Self {
                $dto {
                    value: <$inner_dto>::from(r.value),
                    source: r.source.into(),
                }
            }
        }
    };
}

recorded!(RecordedLengthDto, QuantityLengthDto, Length);
recorded!(RecordedMassDto, QuantityMassDto, Mass);
recorded!(RecordedLengthPerMassDto, LengthPerMassDto, LengthPerMass);
recorded!(RecordedCountOverDto, CountOverDto, CountOver);

impl From<MaterialDto> for Material {
    fn from(d: MaterialDto) -> Self {
        Material {
            id: d.id,
            name: d.name,
            maker: d.maker,
            fibers: d
                .fibers
                .into_iter()
                .map(|f| FiberPart {
                    fiber: f.fiber,
                    percent: f.percent,
                })
                .collect(),
            weight: d.weight.map(Into::into),
            structure: d.structure,
            length_per_mass: d.length_per_mass.map(Into::into),
            wpi: d.wpi.map(Into::into),
            color: d.color,
            dye_lot: d.dye_lot,
            available_mass: d.available_mass.map(Into::into),
            available_length: d.available_length.map(Into::into),
            notes: d.notes,
        }
    }
}

impl From<&Material> for MaterialDto {
    fn from(m: &Material) -> Self {
        MaterialDto {
            id: m.id.clone(),
            name: m.name.clone(),
            maker: m.maker.clone(),
            fibers: m
                .fibers
                .iter()
                .map(|f| FiberPartDto {
                    fiber: f.fiber.clone(),
                    percent: f.percent,
                })
                .collect(),
            weight: m.weight.map(weight_out),
            structure: m.structure.clone(),
            length_per_mass: m.length_per_mass.map(Into::into),
            wpi: m.wpi.map(Into::into),
            color: m.color.clone(),
            dye_lot: m.dye_lot.clone(),
            available_mass: m.available_mass.map(Into::into),
            available_length: m.available_length.map(Into::into),
            notes: m.notes.clone(),
        }
    }
}

fn weight_out(w: YarnWeight) -> YarnWeightKind {
    match w {
        YarnWeight::Lace => YarnWeightKind::Lace,
        YarnWeight::SuperFine => YarnWeightKind::SuperFine,
        YarnWeight::Fine => YarnWeightKind::Fine,
        YarnWeight::Light => YarnWeightKind::Light,
        YarnWeight::Medium => YarnWeightKind::Medium,
        YarnWeight::Bulky => YarnWeightKind::Bulky,
        YarnWeight::SuperBulky => YarnWeightKind::SuperBulky,
        YarnWeight::Jumbo => YarnWeightKind::Jumbo,
    }
}

fn craft_in(k: SwatchCraftKind) -> CraftKind {
    match k {
        SwatchCraftKind::Weaving => CraftKind::Weaving,
        SwatchCraftKind::Knitting => CraftKind::Knitting,
        SwatchCraftKind::Nalbinding => CraftKind::Nalbinding,
    }
}

/// `None` for a craft that is not a swatch craft at this materials schema version (tablet weaving:
/// `materials.json` never holds it, see `ply_common::materials`).
fn craft_out(c: CraftKind) -> Option<SwatchCraftKind> {
    match c {
        CraftKind::Weaving => Some(SwatchCraftKind::Weaving),
        CraftKind::Knitting => Some(SwatchCraftKind::Knitting),
        CraftKind::Nalbinding => Some(SwatchCraftKind::Nalbinding),
        CraftKind::TabletWeaving => None,
    }
}

fn role_in(k: YarnRoleKind) -> YarnRole {
    match k {
        YarnRoleKind::Main => YarnRole::Main,
        YarnRoleKind::Contrast => YarnRole::Contrast,
        YarnRoleKind::Warp => YarnRole::Warp,
        YarnRoleKind::Weft => YarnRole::Weft,
    }
}

fn role_out(r: YarnRole) -> YarnRoleKind {
    match r {
        YarnRole::Main => YarnRoleKind::Main,
        YarnRole::Contrast => YarnRoleKind::Contrast,
        YarnRole::Warp => YarnRoleKind::Warp,
        YarnRole::Weft => YarnRoleKind::Weft,
    }
}

impl From<SwatchStageDto> for Stage {
    fn from(d: SwatchStageDto) -> Self {
        Stage {
            width: d.width.map(Into::into),
            length: d.length.map(Into::into),
            across: d.across.map(Into::into),
            along: d.along.map(Into::into),
            conditions: d.conditions,
        }
    }
}

impl From<&Stage> for SwatchStageDto {
    fn from(s: &Stage) -> Self {
        SwatchStageDto {
            width: s.width.map(Into::into),
            length: s.length.map(Into::into),
            across: s.across.map(Into::into),
            along: s.along.map(Into::into),
            conditions: s.conditions.clone(),
        }
    }
}

impl From<SwatchDto> for Swatch {
    fn from(d: SwatchDto) -> Self {
        Swatch {
            id: d.id,
            name: d.name,
            craft: d.craft.map(craft_in),
            technique: d.technique,
            date: d.date,
            yarns: d
                .yarns
                .into_iter()
                .map(|y| SwatchYarn {
                    material_id: y.material_id,
                    name: y.name,
                    role: y.role.map(role_in),
                })
                .collect(),
            tools: d.tools,
            sett: d.sett.map(Into::into),
            width_in_reed: d.width_in_reed.map(Into::into),
            on_loom: d.on_loom.into(),
            before: d.before.into(),
            after: d.after.into(),
            finishing: d.finishing,
            mass: d.mass.map(Into::into),
            tension: d.tension,
            provenance: d.provenance,
            notes: d.notes,
        }
    }
}

impl From<&Swatch> for SwatchDto {
    fn from(s: &Swatch) -> Self {
        SwatchDto {
            id: s.id.clone(),
            name: s.name.clone(),
            craft: s.craft.and_then(craft_out),
            technique: s.technique.clone(),
            date: s.date.clone(),
            yarns: s
                .yarns
                .iter()
                .map(|y| SwatchYarnDto {
                    material_id: y.material_id.clone(),
                    name: y.name.clone(),
                    role: y.role.map(role_out),
                })
                .collect(),
            tools: s.tools.clone(),
            sett: s.sett.map(Into::into),
            width_in_reed: s.width_in_reed.map(Into::into),
            on_loom: (&s.on_loom).into(),
            before: (&s.before).into(),
            after: (&s.after).into(),
            finishing: s.finishing.clone(),
            mass: s.mass.map(Into::into),
            tension: s.tension.clone(),
            provenance: s.provenance.clone(),
            notes: s.notes.clone(),
        }
    }
}

impl From<MaterialLibraryDto> for MaterialLibrary {
    fn from(d: MaterialLibraryDto) -> Self {
        MaterialLibrary {
            materials: d.materials.into_iter().map(Into::into).collect(),
            swatches: d.swatches.into_iter().map(Into::into).collect(),
        }
    }
}

impl From<&MaterialLibrary> for MaterialLibraryDto {
    fn from(l: &MaterialLibrary) -> Self {
        MaterialLibraryDto {
            materials: l.materials.iter().map(Into::into).collect(),
            swatches: l.swatches.iter().map(Into::into).collect(),
        }
    }
}

impl From<&RecordDiagnostic> for RecordDiagnosticDto {
    fn from(d: &RecordDiagnostic) -> Self {
        RecordDiagnosticDto {
            code: d.code.clone(),
            severity: match d.severity {
                Severity::Error => RecordSeverityKind::Error,
                Severity::Warning => RecordSeverityKind::Warning,
            },
            field: d.field.clone(),
            message: d.message.clone(),
        }
    }
}

impl From<&Figure> for FigureDto {
    fn from(f: &Figure) -> Self {
        FigureDto {
            code: f.code.clone(),
            label: f.label.clone(),
            value: f.value,
            text: f.text.clone(),
            from: f.from.clone(),
        }
    }
}

impl RecordReportDto {
    pub fn new(diagnostics: &[RecordDiagnostic], figures: &[Figure]) -> Self {
        RecordReportDto {
            diagnostics: diagnostics.iter().map(Into::into).collect(),
            figures: figures.iter().map(Into::into).collect(),
        }
    }
}

impl From<&TracedInput> for TracedInputDto {
    fn from(i: &TracedInput) -> Self {
        TracedInputDto {
            key: i.key.clone(),
            label: i.label.clone(),
            value: i.value.clone(),
            source: i.source.into(),
            basis: i.basis.clone(),
            swatch_id: i.swatch_id.clone(),
            material_id: i.material_id.clone(),
        }
    }
}

/// `inputs` as DTOs.
pub fn traced_inputs(inputs: &[TracedInput]) -> Vec<TracedInputDto> {
    inputs.iter().map(Into::into).collect()
}

/// An origin with its value; `Err` when a non-swatch origin has no value.
fn origin<T>(kind: InputOriginKind, value: Option<T>, note: &str) -> Result<Origin<T>, String> {
    let need = |v: Option<T>| v.ok_or_else(|| "an input has no value".to_string());
    Ok(match kind {
        InputOriginKind::Swatch => Origin::Swatch,
        InputOriginKind::Entered => Origin::Entered(need(value)?),
        InputOriginKind::Default => Origin::Default(need(value)?, note.to_string()),
        InputOriginKind::Pattern => Origin::Pattern(need(value)?, note.to_string()),
    })
}

impl CountInputDto {
    pub fn to_origin(&self) -> Result<Origin<CountOver>, String> {
        origin(self.origin, self.value.map(Into::into), &self.note)
    }
}

impl LengthInputDto {
    pub fn to_origin(&self) -> Result<Origin<Length>, String> {
        origin(self.origin, self.value.map(Into::into), &self.note)
    }
}

impl FractionInputDto {
    pub fn to_origin(&self) -> Result<Origin<f64>, String> {
        origin(self.origin, Some(self.value), &self.note)
    }
}

impl WholeInputDto {
    pub fn to_origin(&self) -> Result<Origin<u32>, String> {
        origin(self.origin, Some(self.value), &self.note)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn records_survive_the_dto_round_trip() {
        let mut m = Material::new("m", "Grey wool");
        m.weight = Some(YarnWeight::Bulky);
        m.length_per_mass = Some(Recorded::entered(LengthPerMass::new(
            Length::new(160.0, LengthUnit::Yard),
            Mass::new(50.0, MassUnit::Gram),
        )));
        m.fibers = vec![FiberPart {
            fiber: "alpaca".into(),
            percent: None,
        }];
        assert_eq!(Material::from(MaterialDto::from(&m)), m);
        let mut s = Swatch::new("s", "Towel");
        s.craft = Some(CraftKind::Weaving);
        s.date = Some("2026-11-02".into());
        s.yarns = vec![SwatchYarn {
            material_id: Some("m".into()),
            name: "Grey wool".into(),
            role: Some(YarnRole::Weft),
        }];
        s.sett = Some(Recorded::entered(CountOver::new(24.0, Length::inches(1.0))));
        s.on_loom.length = Some(Recorded::measured(Length::new(
            50.0,
            LengthUnit::Centimeter,
        )));
        s.mass = Some(Recorded::measured(Mass::new(1.2, MassUnit::Ounce)));
        assert_eq!(Swatch::from(SwatchDto::from(&s)), s);
    }

    #[test]
    fn origins_need_a_value_except_from_the_swatch() {
        let c = CountInputDto {
            origin: InputOriginKind::Swatch,
            value: None,
            note: String::new(),
        };
        assert_eq!(c.to_origin().unwrap(), Origin::Swatch);
        let e = CountInputDto {
            origin: InputOriginKind::Entered,
            value: None,
            note: String::new(),
        };
        assert!(e.to_origin().is_err());
    }
}
