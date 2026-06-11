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

use ply_weave::calc::{WarpPlan, WeftEstimate, WeftPlan, YarnEstimate};
use ply_weave::{self as weave, Draft};

/// Parse WIF text into a `Draft`. Errors carry a human-readable message for the UI.
pub fn parse_wif(text: String) -> Result<Draft, String> {
    weave::wif::parse(&text).map_err(|e| e.to_string())
}

/// Serialize a `Draft` back to WIF text.
pub fn write_wif(draft: Draft) -> String {
    weave::wif::write(&draft)
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

/// Validate a draft; returns one formatted string per issue (empty = clean).
pub fn validate_draft(draft: Draft) -> Vec<String> {
    weave::validate::validate(&draft)
        .into_iter()
        .map(|i| format!("{:?}: {}", i.severity, i.message))
        .collect()
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
