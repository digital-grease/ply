//! Loom profile and loom check DTOs (M8-02, ADR 0014), mirrored transparently for the Dart app.
//!
//! The engine's `LoomProfile` (`ply_weave::loom`), the `looms.json` file (`ply_weave::loom_file`)
//! and the feasibility report (`ply_weave::feasibility`) cross the boundary as these plain structs
//! and FLAT enums only (no data-carrying enum, so no freezed rebuild is needed). Conversions live
//! here and nowhere else. Profiles coming from Dart are untrusted: `TryFrom` refuses one outside the
//! engine's limits instead of checking against it.

use crate::dto::UnitKind;
use ply_common::Unit;
use ply_weave::feasibility::{
    LocationKind, LoomDiagnostic, LoomReport, LoomSeverity, Sett, SettSource,
};
use ply_weave::loom::{DentUnit, Length, LoomKind, LoomProfile, Reed};
use ply_weave::loom_file::{LoomFileError, LoomLibrary};

/// The loom type, mirroring `Option<loom::LoomKind>` as one flat enum: `Unknown` = not recorded.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LoomTypeKind {
    Unknown,
    Jack,
    Counterbalance,
    Countermarch,
    Table,
    Dobby,
}

/// How a reed's dents are counted.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DentUnitKind {
    PerInch,
    Per10Cm,
}

/// A length with its unit.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct LengthDto {
    pub value: f64,
    pub unit: UnitKind,
}

/// One reed.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ReedDto {
    pub dents: f64,
    pub per: DentUnitKind,
}

/// One loom profile. Every equipment field may be missing: `None`, `Unknown`, or an empty list
/// (never 0).
#[derive(Debug, Clone, PartialEq)]
pub struct LoomProfileDto {
    pub id: String,
    pub name: String,
    pub kind: LoomTypeKind,
    pub shafts: Option<u16>,
    pub treadles: Option<u16>,
    pub weaving_width: Option<LengthDto>,
    pub reeds: Vec<ReedDto>,
    pub treadles_at_once: Option<u8>,
    pub notes: String,
}

/// Every loom in `looms.json`, in order.
#[derive(Debug, Clone, PartialEq)]
pub struct LoomLibraryDto {
    pub looms: Vec<LoomProfileDto>,
}

/// Why a `looms.json` could not be read (see [`LoomFileFailure`]).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LoomFileFailureKind {
    /// Saved by a newer Ply: must not be read or overwritten.
    NewerVersion,
    /// A JSON object of another format (or with no format).
    WrongFormat,
    /// Over the size or loom-count limit.
    TooLarge,
    /// Not readable: bad JSON, a malformed envelope, a value outside its limits, a repeated id.
    Unreadable,
}

/// The typed error `parse_looms` returns, thrown as an exception on the Dart side.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LoomFileFailure {
    pub kind: LoomFileFailureKind,
    /// Detail for logs (versions, the parse error). Never shown as the main message.
    pub message: String,
}

impl From<LoomFileError> for LoomFileFailure {
    fn from(e: LoomFileError) -> Self {
        let kind = match e {
            LoomFileError::NewerVersion { .. } => LoomFileFailureKind::NewerVersion,
            LoomFileError::WrongFormat { .. } => LoomFileFailureKind::WrongFormat,
            LoomFileError::TooLarge(_) => LoomFileFailureKind::TooLarge,
            LoomFileError::Malformed(_) => LoomFileFailureKind::Unreadable,
        };
        LoomFileFailure {
            kind,
            message: e.to_string(),
        }
    }
}

/// A sett: `ends` per inch or per cm.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct SettDto {
    pub ends: f64,
    pub per: UnitKind,
}

/// Mirrors `feasibility::LoomSeverity`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LoomSeverityKind {
    NotFeasible,
    Advice,
    NotChecked,
    Fits,
}

/// Mirrors `feasibility::LocationKind`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LoomLocationKind {
    Shafts,
    Treadles,
    Picks,
}

/// Where a diagnostic applies: 1-based numbers (at most 24 listed), `total` in all.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LoomLocationDto {
    pub kind: LoomLocationKind,
    pub numbers: Vec<u32>,
    pub total: u32,
}

/// One loom finding. `code` is the stable string (`loom.shafts_exceeded`, ...).
#[derive(Debug, Clone, PartialEq)]
pub struct LoomDiagnosticDto {
    pub code: String,
    pub severity: LoomSeverityKind,
    pub summary: String,
    pub message: String,
    pub location: Option<LoomLocationDto>,
    pub remediation: Option<String>,
}

/// Where the sett a check used came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SettSourceKind {
    Entered,
    File,
}

/// A whole loom check.
#[derive(Debug, Clone, PartialEq)]
pub struct LoomReportDto {
    pub loom_name: String,
    pub diagnostics: Vec<LoomDiagnosticDto>,
    /// The sett the width and reed checks used, and its source (both `None` when unknown).
    pub sett: Option<SettDto>,
    pub sett_source: Option<SettSourceKind>,
    /// The file's own sett, when it gives one.
    pub file_sett: Option<SettDto>,
    /// The warp's width in the reed, when known.
    pub reed_width: Option<LengthDto>,
}

// --- conversions -----------------------------------------------------------------------------------

fn unit_in(u: UnitKind) -> Unit {
    match u {
        UnitKind::Inches => Unit::Inches,
        UnitKind::Centimeters => Unit::Centimeters,
    }
}

fn unit_out(u: Unit) -> UnitKind {
    match u {
        Unit::Inches => UnitKind::Inches,
        Unit::Centimeters => UnitKind::Centimeters,
    }
}

impl From<Option<LoomKind>> for LoomTypeKind {
    fn from(k: Option<LoomKind>) -> Self {
        match k {
            None => LoomTypeKind::Unknown,
            Some(LoomKind::Jack) => LoomTypeKind::Jack,
            Some(LoomKind::Counterbalance) => LoomTypeKind::Counterbalance,
            Some(LoomKind::Countermarch) => LoomTypeKind::Countermarch,
            Some(LoomKind::Table) => LoomTypeKind::Table,
            Some(LoomKind::Dobby) => LoomTypeKind::Dobby,
        }
    }
}

impl From<LoomTypeKind> for Option<LoomKind> {
    fn from(k: LoomTypeKind) -> Self {
        match k {
            LoomTypeKind::Unknown => None,
            LoomTypeKind::Jack => Some(LoomKind::Jack),
            LoomTypeKind::Counterbalance => Some(LoomKind::Counterbalance),
            LoomTypeKind::Countermarch => Some(LoomKind::Countermarch),
            LoomTypeKind::Table => Some(LoomKind::Table),
            LoomTypeKind::Dobby => Some(LoomKind::Dobby),
        }
    }
}

impl From<Length> for LengthDto {
    fn from(l: Length) -> Self {
        LengthDto {
            value: l.value,
            unit: unit_out(l.unit),
        }
    }
}

impl From<LengthDto> for Length {
    fn from(l: LengthDto) -> Self {
        Length {
            value: l.value,
            unit: unit_in(l.unit),
        }
    }
}

impl From<&LoomProfile> for LoomProfileDto {
    fn from(p: &LoomProfile) -> Self {
        LoomProfileDto {
            id: p.id.clone(),
            name: p.name.clone(),
            kind: p.kind.into(),
            shafts: p.shafts,
            treadles: p.treadles,
            weaving_width: p.weaving_width.map(LengthDto::from),
            reeds: p
                .reeds
                .iter()
                .map(|r| ReedDto {
                    dents: r.dents,
                    per: match r.per {
                        DentUnit::PerInch => DentUnitKind::PerInch,
                        DentUnit::Per10Cm => DentUnitKind::Per10Cm,
                    },
                })
                .collect(),
            treadles_at_once: p.treadles_at_once,
            notes: p.notes.clone(),
        }
    }
}

impl From<LoomProfileDto> for LoomProfile {
    /// Shape only; [`LoomProfile::problems`] says whether the values are within the limits.
    fn from(d: LoomProfileDto) -> Self {
        LoomProfile {
            id: d.id,
            name: d.name,
            kind: d.kind.into(),
            shafts: d.shafts,
            treadles: d.treadles,
            weaving_width: d.weaving_width.map(Length::from),
            reeds: d
                .reeds
                .into_iter()
                .map(|r| Reed {
                    dents: r.dents,
                    per: match r.per {
                        DentUnitKind::PerInch => DentUnit::PerInch,
                        DentUnitKind::Per10Cm => DentUnit::Per10Cm,
                    },
                })
                .collect(),
            treadles_at_once: d.treadles_at_once,
            notes: d.notes,
        }
    }
}

impl From<&LoomLibrary> for LoomLibraryDto {
    fn from(l: &LoomLibrary) -> Self {
        LoomLibraryDto {
            looms: l.looms.iter().map(LoomProfileDto::from).collect(),
        }
    }
}

impl From<LoomLibraryDto> for LoomLibrary {
    fn from(d: LoomLibraryDto) -> Self {
        LoomLibrary {
            looms: d.looms.into_iter().map(LoomProfile::from).collect(),
        }
    }
}

impl From<SettDto> for Sett {
    fn from(s: SettDto) -> Self {
        Sett {
            ends: s.ends,
            per: unit_in(s.per),
        }
    }
}

impl From<Sett> for SettDto {
    fn from(s: Sett) -> Self {
        SettDto {
            ends: s.ends,
            per: unit_out(s.per),
        }
    }
}

impl From<&LoomDiagnostic> for LoomDiagnosticDto {
    fn from(d: &LoomDiagnostic) -> Self {
        LoomDiagnosticDto {
            code: d.code.as_str().to_string(),
            severity: match d.severity {
                LoomSeverity::NotFeasible => LoomSeverityKind::NotFeasible,
                LoomSeverity::Advice => LoomSeverityKind::Advice,
                LoomSeverity::NotChecked => LoomSeverityKind::NotChecked,
                LoomSeverity::Fits => LoomSeverityKind::Fits,
            },
            summary: d.summary.clone(),
            message: d.message.clone(),
            location: d.location.as_ref().map(|l| LoomLocationDto {
                kind: match l.kind {
                    LocationKind::Shafts => LoomLocationKind::Shafts,
                    LocationKind::Treadles => LoomLocationKind::Treadles,
                    LocationKind::Picks => LoomLocationKind::Picks,
                },
                numbers: l.numbers.clone(),
                total: u32::try_from(l.total).unwrap_or(u32::MAX),
            }),
            remediation: d.remediation.clone(),
        }
    }
}

impl From<&LoomReport> for LoomReportDto {
    fn from(r: &LoomReport) -> Self {
        LoomReportDto {
            loom_name: r.loom_name.clone(),
            diagnostics: r.diagnostics.iter().map(LoomDiagnosticDto::from).collect(),
            sett: r.sett.map(|s| s.sett.into()),
            sett_source: r.sett.map(|s| match s.source {
                SettSource::Entered => SettSourceKind::Entered,
                SettSource::File => SettSourceKind::File,
            }),
            file_sett: r.file_sett.map(SettDto::from),
            reed_width: r.reed_width.map(LengthDto::from),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::{check_loom_dto, draft_sett_dto, parse_looms, parse_wif_dto, write_looms};

    const FIXTURES: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../fixtures/weaving/looms");

    fn fixture(name: &str) -> String {
        std::fs::read_to_string(format!("{FIXTURES}/{name}")).unwrap()
    }

    #[test]
    fn the_fixture_library_round_trips_through_the_dtos() {
        let text = fixture("looms.json");
        let dto = parse_looms(text.clone()).unwrap();
        assert_eq!(dto.looms.len(), 4);
        assert_eq!(dto.looms[1].kind, LoomTypeKind::Unknown);
        assert_eq!(dto.looms[1].treadles, None);
        assert_eq!(write_looms(dto).unwrap(), text.trim_end());
    }

    #[test]
    fn a_newer_file_is_a_typed_failure() {
        let err = parse_looms(r#"{"format":"ply.looms","schema_version":9,"looms":[]}"#.into())
            .unwrap_err();
        assert_eq!(err.kind, LoomFileFailureKind::NewerVersion);
        let err = parse_looms("{}".into()).unwrap_err();
        assert_eq!(err.kind, LoomFileFailureKind::WrongFormat);
        let err = parse_looms("nope".into()).unwrap_err();
        assert_eq!(err.kind, LoomFileFailureKind::Unreadable);
    }

    #[test]
    fn an_out_of_limits_profile_is_refused_not_checked_against() {
        let mut loom = parse_looms(fixture("looms.json")).unwrap().looms.remove(0);
        let draft = parse_wif_dto(fixture("eight-shaft-twill.wif")).unwrap();
        loom.shafts = Some(0);
        assert!(check_loom_dto(draft, loom.clone(), None).is_err());
        loom.shafts = Some(4);
        let draft = parse_wif_dto(fixture("eight-shaft-twill.wif")).unwrap();
        let report = check_loom_dto(draft, loom, None).unwrap();
        assert_eq!(report.diagnostics[0].code, "loom.shafts_exceeded");
        assert_eq!(
            report.diagnostics[0].severity,
            LoomSeverityKind::NotFeasible
        );
        assert_eq!(report.diagnostics[0].summary, "needs 8 shafts, has 4");
        assert_eq!(report.sett_source, Some(SettSourceKind::File));
        let file = draft_sett_dto(parse_wif_dto(fixture("eight-shaft-twill.wif")).unwrap());
        assert_eq!(file.map(|s| s.ends), Some(20.0));
    }
}
