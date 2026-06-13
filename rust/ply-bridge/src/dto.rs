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
use ply_weave::draft::{
    ColorPlan, Draft, Drive, Liftplan, RetainedSection, ShaftId, ShedType, Threading, TieUp,
    TreadleId, Treadling,
};
use ply_weave::validate::{Severity, ValidationIssue};

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

/// Measurement unit for the draft's lengths.
pub enum UnitKind {
    Inches,
    Centimeters,
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

/// Severity of a validation issue. Flat C-like enum so frb mirrors it transparently; it
/// preserves the engine `Severity` the M1 bridge flattened into a string.
pub enum SeverityKind {
    Error,
    Warning,
}

/// One validation problem, with its severity preserved (not flattened into the message) so
/// the editor can color Errors red vs Warnings amber and gate Save on Errors.
pub struct ValidationIssueDto {
    pub severity: SeverityKind,
    pub message: String,
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
    pub notes: String,
    /// Unmodeled WIF sections kept verbatim (see [`RetainedSectionDto`]).
    pub retained: Vec<RetainedSectionDto>,
}

// ---------------------------------------------------------------------------
// Conversions — the ONLY place id/index base conversion happens.
// ---------------------------------------------------------------------------

fn shaft_rows_out(rows: &[Vec<ShaftId>]) -> Vec<Vec<u16>> {
    rows.iter().map(|r| r.iter().map(|s| s.0).collect()).collect()
}
fn treadle_rows_out(rows: &[Vec<TreadleId>]) -> Vec<Vec<u16>> {
    rows.iter().map(|r| r.iter().map(|t| t.0).collect()).collect()
}
fn shaft_rows_in(rows: &[Vec<u16>]) -> Vec<Vec<ShaftId>> {
    rows.iter().map(|r| r.iter().map(|&n| ShaftId(n)).collect()).collect()
}
fn treadle_rows_in(rows: &[Vec<u16>]) -> Vec<Vec<TreadleId>> {
    rows.iter().map(|r| r.iter().map(|&n| TreadleId(n)).collect()).collect()
}

impl From<&ValidationIssue> for ValidationIssueDto {
    fn from(i: &ValidationIssue) -> Self {
        ValidationIssueDto {
            severity: match i.severity {
                Severity::Error => SeverityKind::Error,
                Severity::Warning => SeverityKind::Warning,
            },
            message: i.message.clone(),
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
                .map(|c| ColorDto { r: c.r, g: c.g, b: c.b })
                .collect(),
            warp_colors: d.colors.warp.iter().map(|&i| i as u32).collect(),
            weft_colors: d.colors.weft.iter().map(|&i| i as u32).collect(),
            notes: d.notes.clone(),
            retained: d
                .retained
                .iter()
                .map(|s| RetainedSectionDto {
                    name: s.name.clone(),
                    entries: s
                        .entries
                        .iter()
                        .map(|(k, v)| RetainedEntryDto { key: k.clone(), value: v.clone() })
                        .collect(),
                })
                .collect(),
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
                palette: dto.palette.iter().map(|c| Color::rgb(c.r, c.g, c.b)).collect(),
                warp: dto.warp_colors.iter().map(|&i| i as usize).collect(),
                weft: dto.weft_colors.iter().map(|&i| i as usize).collect(),
            },
            notes: dto.notes,
            retained: dto
                .retained
                .into_iter()
                .map(|s| RetainedSection {
                    name: s.name,
                    entries: s.entries.into_iter().map(|e| (e.key, e.value)).collect(),
                })
                .collect(),
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
            notes: "n".into(),
            // A retained unmodeled section must survive the DTO round-trip too (Draft's PartialEq
            // includes `retained`, so assert_roundtrip fails if the DTO drops it).
            retained: vec![RetainedSection {
                name: "WARP THICKNESS".into(),
                entries: vec![("1".into(), "10".into()), ("2".into(), "10".into())],
            }],
        };
        assert_roundtrip(&d);
    }
}
