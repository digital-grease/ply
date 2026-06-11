//! The FFI surface exposed to Flutter.
//!
//! BOUNDARY RULES (see `docs/FFI_BOUNDARY.md`):
//!  * **Coarse-grained only.** One call computes a whole result. Never per-cell.
//!  * The engine crates stay FFI-free; this module owns the bridge and conversions.
//!    For v1 we hand `ply-weave` types across directly where frb can mirror them; if a
//!    type proves awkward at the boundary, introduce a thin DTO here rather than putting
//!    frb attributes on the engine type.
//!
//! frb v2 auto-discovers the `pub` functions in this module during codegen — no per-fn
//! attribute is required.

// `pub use`, not `use`: the generated `frb_generated.rs` does `use crate::api::*` and
// references these types unqualified, so they must be re-exported from this module.
pub use ply_weave::calc::{WarpPlan, WeftEstimate, WeftPlan, YarnEstimate};
pub use ply_weave::{self as weave, Draft};

// M2 editor DTOs (transparent, non-opaque). Re-exported into `crate::api` so frb discovers
// them while scanning this module. See `dto.rs` for why an editor needs these.
pub use crate::dto::{
    ColorDto, DraftDto, DriveDto, SeverityKind, ShedKind, UnitKind, ValidationIssueDto,
};

/// Parse WIF text into a `Draft`. Errors carry a human-readable message for the UI.
pub fn parse_wif(text: String) -> Result<Draft, String> {
    weave::wif::parse(&text).map_err(|e| e.to_string())
}

/// Serialize an editor `DraftDto` back to WIF text. Takes the mirrored DTO (not an opaque
/// handle), so the editor's Save path can re-serialize the live document. `Err` if the DTO
/// fails to convert back to a `Draft` (e.g. malformed ids); WIF writing itself is infallible.
///
/// NOTE: `write` is lossy at the WIF header (thickness/spacing/unknown sections are dropped) —
/// the M2 editor keeps the original WIF verbatim until a structural edit dirties it, then
/// re-serializes via this and warns. See `docs/WIF_MAPPING.md`.
pub fn write_wif(dto: DraftDto) -> Result<String, String> {
    let draft = Draft::try_from(dto)?;
    Ok(weave::wif::write(&draft))
}

/// An RGBA preview buffer for the live cloth view.
pub struct PreviewImage {
    pub width: u32,
    pub height: u32,
    /// RGBA8, row-major, top-to-bottom. Decode into a `ui.Image` on the Dart side.
    pub rgba: Vec<u8>,
}

/// Render the cloth to an RGBA buffer at `cell_px` pixels per intersection. This is the
/// single call the preview widget makes; recompute is microseconds, so it is fine to call
/// on every edit.
pub fn render_preview(draft: Draft, cell_px: u32) -> PreviewImage {
    let img = weave::render_rgba(&draft, cell_px);
    PreviewImage { width: img.width, height: img.height, rgba: img.pixels }
}

// ---------------------------------------------------------------------------
// M2 editor surface (transparent DTO). Additive for the Phase-1 spike: the opaque-`Draft`
// fns above stay so the M1 app keeps building until Phase 2 migrates the repository.
// ---------------------------------------------------------------------------

/// Parse WIF into the transparent editor `DraftDto`. Unlike `parse_wif` (which yields an
/// opaque, single-use `Draft` handle), the returned value is a plain mirrored struct the
/// editor can hold and pass to render/validate/write repeatedly.
pub fn parse_wif_dto(text: String) -> Result<DraftDto, String> {
    weave::wif::parse(&text)
        .map(|d| DraftDto::from(&d))
        .map_err(|e| e.to_string())
}

/// Render an editor `DraftDto` to an RGBA preview. Takes the DTO BY VALUE but, because it is
/// a mirrored value (not an opaque handle), the Dart caller may render the SAME `DraftDto`
/// repeatedly with no use-after-free — the M1 single-use trap is gone by construction.
pub fn render_preview_dto(dto: DraftDto, cell_px: u32) -> Result<PreviewImage, String> {
    let draft = Draft::try_from(dto)?;
    let img = weave::render_rgba(&draft, cell_px);
    Ok(PreviewImage { width: img.width, height: img.height, rgba: img.pixels })
}

/// Validate an editor `DraftDto`; returns one structured issue per problem (empty = clean),
/// each carrying its `SeverityKind` so the editor can color the gutter and gate Save on
/// Errors. `Err` only if the DTO can't convert back to a `Draft`. Replaces M1's
/// `Vec<String>` (which flattened `Severity` into the message).
pub fn validate_draft(dto: DraftDto) -> Result<Vec<ValidationIssueDto>, String> {
    let draft = Draft::try_from(dto)?;
    Ok(weave::validate::validate(&draft)
        .iter()
        .map(ValidationIssueDto::from)
        .collect())
}

/// Build a blank, valid draft to start editing from scratch (Rising shed, inches, empty
/// threading/treadling, a tie-up sized to `treadles`, and a 2-color white/black palette).
pub fn blank_draft(shafts: u16, treadles: u16) -> DraftDto {
    DraftDto::from(&Draft::blank(shafts, treadles))
}

/// Convert any draft to a canonical liftplan-driven copy (raised shafts baked in, shed →
/// Rising, tie-up dropped) for the editor's Treadled→Liftplan switch. The drawdown is
/// unchanged. `Err` if the DTO can't convert back to a `Draft`. Reverse is deferred.
pub fn to_liftplan_dto(dto: DraftDto) -> Result<DraftDto, String> {
    let draft = Draft::try_from(dto)?;
    Ok(DraftDto::from(&draft.to_liftplan_draft()))
}

/// Suggest a sett (ends per inch) from wraps-per-inch and a structure name
/// ("plain" | "twill" | "satin").
pub fn suggest_sett(wpi: f32, structure: String) -> f32 {
    let s = match structure.to_lowercase().as_str() {
        "twill" => weave::calc::Structure::Twill,
        "satin" => weave::calc::Structure::Satin,
        _ => weave::calc::Structure::Plain,
    };
    weave::calc::suggest_sett(wpi, s)
}

/// Estimate warp length and total warp yarn from a plan. `plan.takeup_shrinkage` is the
/// user-supplied length-direction take-up + shrinkage fraction.
pub fn estimate_warp(plan: WarpPlan) -> YarnEstimate {
    weave::calc::estimate_warp(&plan)
}

/// Estimate total weft yarn from a plan. `plan.takeup` is the user-supplied weft
/// take-up + selvedge/wastage fraction (width-direction).
pub fn estimate_weft(plan: WeftPlan) -> WeftEstimate {
    weave::calc::estimate_weft(&plan)
}
