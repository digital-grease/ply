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
// references these types unqualified, so the types that appear in a bridge fn signature must
// be re-exported from this module. The calc types still cross the boundary (estimate_* fns).
pub use ply_weave::calc::{WarpPlan, WeftEstimate, WeftPlan, YarnEstimate};

// `Draft` and the `weave` alias are now used ONLY inside fn bodies and the DTO conversions —
// no bridge fn takes or returns the opaque `Draft` since Phase 2.3 dropped `parse_wif`/
// `render_preview`. So this is a private `use`, NOT `pub use`: frb emits NO opaque-`Draft`
// codec and no bridge fn references it, so the single-use handle is unreachable from Dart and
// the editor speaks `DraftDto` end to end. (An inert `abstract class Draft {}` stub may still
// appear in the generated, git-ignored `lib.dart` because `Draft` stays reachable through this
// engine `use`; it is dead and harmless.)
use ply_weave::{self as weave, Draft};

// M2 editor DTOs (transparent, non-opaque). Re-exported into `crate::api` so frb discovers
// them while scanning this module. See `dto.rs` for why an editor needs these.
pub use crate::dto::{
    ColorDto, DraftDto, DriveDto, RenderOptionsDto, RetainedEntryDto, RetainedSectionDto,
    SeverityKind, ShedKind, StructureFamily, ThreadingKind, UnitKind, ValidationIssueDto,
    WarpPlanDto, WeftEstimateDto, WeftPlanDto, YarnEstimateDto,
};

/// Serialize an editor `DraftDto` back to WIF text. Takes the mirrored DTO (not an opaque
/// handle), so the editor's Save path can re-serialize the live document. `Err` if the DTO
/// fails to convert back to a `Draft` (e.g. malformed ids); WIF writing itself is infallible.
///
/// NOTE: `write` re-serializes from the model, so it normalizes formatting and DROPS source
/// comments — but it no longer drops DATA: modeled sections, per-thread thickness (M4), and
/// unmodeled sections kept verbatim in `retained` (M3) all round-trip. The editor still keeps the
/// original WIF verbatim until a structural edit dirties it, then re-serializes via this. See
/// `docs/WIF_MAPPING.md`.
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

// ---------------------------------------------------------------------------
// M2 editor surface (transparent DTO). The opaque-`Draft` `parse_wif`/`render_preview` fns
// were removed in Phase 2.3 once `DraftRepository` migrated to this DTO surface; the editor
// now holds a mirrored value end to end, so the M1 single-use-handle trap is gone for good.
// ---------------------------------------------------------------------------

/// Parse WIF into the transparent editor `DraftDto`. The returned value is a plain mirrored
/// struct the editor can hold and pass to render/validate/write repeatedly (no opaque,
/// single-use `Draft` handle).
pub fn parse_wif_dto(text: String) -> Result<DraftDto, String> {
    weave::wif::parse(&text)
        .map(|d| DraftDto::from(&d))
        .map_err(|e| e.to_string())
}

/// Render an editor `DraftDto` to an RGBA preview. Takes the DTO BY VALUE but, because it is
/// a mirrored value (not an opaque handle), the Dart caller may render the SAME `DraftDto`
/// repeatedly with no use-after-free — the M1 single-use trap is gone by construction.
///
/// `options` carries the optional drawdown overlays (gridlines, long-float highlight); pass `None`
/// (the library/thumbnail path) for a plain cloth, byte-identical to the pre-overlay render.
pub fn render_preview_dto(
    dto: DraftDto,
    cell_px: u32,
    options: Option<RenderOptionsDto>,
) -> Result<PreviewImage, String> {
    let draft = Draft::try_from(dto)?;
    let opts = options.map(Into::into).unwrap_or_default();
    let img = weave::render_rgba_with(&draft, cell_px, &opts);
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

/// Resize a draft to `ends` x `picks` over `shafts`/`treadles`. SHRINKING prunes every shaft/
/// treadle reference the smaller header no longer has (so the result never leaves a dangling
/// reference for the user to hand-fix); GROWING pads blanks; warp/weft color lengths stay coupled
/// to ends/picks. `Err` if the DTO can't convert back to a `Draft`.
pub fn resize_dto(
    dto: DraftDto,
    ends: u32,
    picks: u32,
    shafts: u16,
    treadles: u16,
) -> Result<DraftDto, String> {
    let draft = Draft::try_from(dto)?;
    Ok(DraftDto::from(
        &draft.resized(ends as usize, picks as usize, shafts, treadles),
    ))
}

/// Remove palette color `index` and SAFELY remap every warp/weft reference so none dangles: a thread
/// using the removed color falls back to color 0, threads past it renumber down by one. The result
/// `validate()`s with no dangling-index issue. `Err` if `index` is out of range, the palette has only
/// one color (a draft needs >= 1), or the DTO can't convert back to a `Draft`.
pub fn remove_palette_color_dto(dto: DraftDto, index: u32) -> Result<DraftDto, String> {
    let draft = Draft::try_from(dto)?;
    Ok(DraftDto::from(&draft.with_color_removed(index as usize)?))
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

/// Estimate warp length + total warp yarn from a TRANSPARENT plan DTO (the editor's calculator path).
/// `plan.takeup_shrinkage` is the length-direction take-up + shrinkage FRACTION (0.10 = 10%). Unlike
/// `estimate_warp`, both the input and the result cross FFI as readable mirrored DTOs.
pub fn estimate_warp_dto(plan: WarpPlanDto) -> YarnEstimateDto {
    YarnEstimateDto::from(&weave::calc::estimate_warp(&plan.into()))
}

/// Estimate total weft yarn from a plan. `plan.takeup` is the user-supplied weft
/// take-up + selvedge/wastage fraction (width-direction).
pub fn estimate_weft(plan: WeftPlan) -> WeftEstimate {
    weave::calc::estimate_weft(&plan)
}

/// Estimate weft picks + total weft yarn from a TRANSPARENT plan DTO (the editor's calculator path).
/// `plan.takeup` is the width-direction weft take-up + selvedge/wastage FRACTION (0.10 = 10%). Unlike
/// `estimate_weft`, both the input and the result cross FFI as readable mirrored DTOs.
pub fn estimate_weft_dto(plan: WeftPlanDto) -> WeftEstimateDto {
    WeftEstimateDto::from(&weave::calc::estimate_weft(&plan.into()))
}

/// Generate a tie-up for a weave-structure family (the editor's "Generate structure" action). Each
/// inner list is the 1-based shaft(s) raised by that treadle. `over`/`under` apply to Twill,
/// `counter` to Satin, and `shafts` to Plain/Satin (Twill's shaft count is `over + under`).
pub fn generate_tieup_dto(
    family: StructureFamily,
    shafts: u16,
    over: u16,
    under: u16,
    counter: u16,
) -> Vec<Vec<u16>> {
    let tieup = match family {
        StructureFamily::Plain => weave::draft::TieUp::plain(shafts),
        StructureFamily::Twill => weave::draft::TieUp::twill(over, under),
        StructureFamily::Satin => weave::draft::TieUp::satin(shafts, counter),
    };
    tieup.0.iter().map(|r| r.iter().map(|s| s.0).collect()).collect()
}

/// Generate a threading (per warp end, the 1-based shaft it threads) for the chosen draw over
/// `ends` ends and `shafts` shafts.
pub fn generate_threading_dto(kind: ThreadingKind, ends: u32, shafts: u16) -> Vec<Vec<u16>> {
    let threading = match kind {
        ThreadingKind::Straight => weave::draft::Threading::straight(ends as usize, shafts),
        ThreadingKind::Point => weave::draft::Threading::point(ends as usize, shafts),
    };
    threading.0.iter().map(|r| r.iter().map(|s| s.0).collect()).collect()
}
