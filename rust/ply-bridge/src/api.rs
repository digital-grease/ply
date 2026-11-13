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
    ColorDto, DraftDto, DrawdownRegionDto, DriveDto, PickRoleKind, RenderFailure,
    RenderFailureKind, RenderOptionsDto, RetainedEntryDto, RetainedSectionDto, SeverityKind,
    ShadowBlockDto, ShadowLayoutKind, ShadowParamsDto, ShadowSystemKind, ShedKind, StructureFamily,
    ThreadingKind, TwillDirectionKind, UnitKind, ValidationIssueDto, WarpPlanDto, WeftEstimateDto,
    WeftPhaseKind, WeftPlanDto, YarnEstimateDto,
};

/// Most shafts a structure generator will build a tie-up for. Real looms stop far below this (the
/// editor caps input at 200); the cap stops an absurd request (e.g. a 65535-shaft twill, about
/// 8.6 GB of tie-up) from aborting the app.
const MAX_GENERATED_SHAFTS: u32 = 1024;

/// Below this pitch a FITTED render drops the gridline and thread-texture overlays: a 1 px seam on a
/// 2 or 3 px cell would cover a third to half of the cloth once the view scales it up.
const MIN_OVERLAY_CELL_PX: u32 = 4;

/// Reject an ends/picks request above the document cap shared with WIF import.
fn check_threads(ends: u32, picks: u32) -> Result<(usize, usize), String> {
    let (e, p) = (ends as usize, picks as usize);
    if e > weave::MAX_THREADS || p > weave::MAX_THREADS {
        return Err(format!(
            "a draft can have at most {} ends and {} picks (asked for {e} x {p})",
            weave::MAX_THREADS,
            weave::MAX_THREADS
        ));
    }
    Ok((e, p))
}

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
///
/// RESOURCE BOUNDS: `cell_px` is the pitch the caller would LIKE. When that raster would exceed the
/// device budget (`RenderLimits::DEFAULT`), the render drops to the largest pitch that fits; every
/// current view scales the image to its own layout, so a big draft draws at lower resolution
/// instead of going blank. Below 4 px a fitted render also drops gridlines and thread texture.
/// A draft too large even at 1 px per intersection (or an invalid DTO) is an `Err(RenderFailure)`,
/// which Dart receives as a thrown `RenderFailure`. Nothing is allocated before the size checks.
pub fn render_preview_dto(
    dto: DraftDto,
    cell_px: u32,
    options: Option<RenderOptionsDto>,
) -> Result<PreviewImage, RenderFailure> {
    render_preview_within(dto, cell_px, options, &weave::RenderLimits::DEFAULT)
}

/// [`render_preview_dto`] against explicit limits (tests use small ones).
fn render_preview_within(
    dto: DraftDto,
    cell_px: u32,
    options: Option<RenderOptionsDto>,
    limits: &weave::RenderLimits,
) -> Result<PreviewImage, RenderFailure> {
    let draft = Draft::try_from(dto).map_err(|message| RenderFailure {
        kind: RenderFailureKind::InvalidDraft,
        message,
    })?;
    let mut opts: weave::RenderOptions = options.map(Into::into).unwrap_or_default();
    let px = weave::fit_cell_px(&draft, cell_px, limits)?;
    if px < cell_px && px < MIN_OVERLAY_CELL_PX {
        opts.gridlines = false;
        opts.thread_texture = false;
    }
    let img = weave::try_render_rgba_with(&draft, px, &opts, limits)?;
    Ok(PreviewImage {
        width: img.width,
        height: img.height,
        rgba: img.pixels,
    })
}

/// Render one rectangle of an editor `DraftDto`'s drawdown (`region`) to an RGBA preview, for a view
/// that shows only part of a large draft. Cells are UNIFORM (per-thread thickness ignored, matching
/// the structural editor) and the image is pixel-identical to the matching crop of the full uniform
/// render: the region's highest end at the left, its first pick at the top, gridline seams on the
/// whole draft's interior boundaries, and the long-float tint measured past the region's edges.
/// Only the region (plus a float margin of `float_threshold - 1`) is computed, so a draft far over
/// the whole-render budget can still be shown a viewport at a time.
///
/// RESOURCE BOUNDS, as [`render_preview_dto`]: `cell_px` is the pitch the caller would LIKE; when the
/// region's raster would exceed the device budget the render drops to the largest pitch that fits
/// (the caller scales the image to the region's cells anyway), and below 4 px a fitted render drops
/// gridlines and thread texture. A region with more intersections than the budget allows is a
/// `TooLarge` failure; an empty region or one past the draft is `InvalidRegion`.
pub fn render_region_dto(
    dto: DraftDto,
    region: DrawdownRegionDto,
    cell_px: u32,
    options: Option<RenderOptionsDto>,
) -> Result<PreviewImage, RenderFailure> {
    render_region_within(dto, region, cell_px, options, &weave::RenderLimits::DEFAULT)
}

/// [`render_region_dto`] against explicit limits (tests use small ones).
fn render_region_within(
    dto: DraftDto,
    region: DrawdownRegionDto,
    cell_px: u32,
    options: Option<RenderOptionsDto>,
    limits: &weave::RenderLimits,
) -> Result<PreviewImage, RenderFailure> {
    let draft = Draft::try_from(dto).map_err(|message| RenderFailure {
        kind: RenderFailureKind::InvalidDraft,
        message,
    })?;
    let region = weave::DrawdownRegion::try_from(region)?;
    let mut opts: weave::RenderOptions = options.map(Into::into).unwrap_or_default();
    let px = weave::fit_region_cell_px(&draft, &region, cell_px, limits)?;
    if px < cell_px && px < MIN_OVERLAY_CELL_PX {
        opts.gridlines = false;
        opts.thread_texture = false;
    }
    let img = weave::try_render_region(&draft, &region, px, &opts, limits)?;
    Ok(PreviewImage {
        width: img.width,
        height: img.height,
        rgba: img.pixels,
    })
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
/// to ends/picks. `Err` if the DTO can't convert back to a `Draft`, or if `ends`/`picks` exceed the
/// per-axis document cap shared with WIF import (`ply_weave::MAX_THREADS`).
pub fn resize_dto(
    dto: DraftDto,
    ends: u32,
    picks: u32,
    shafts: u16,
    treadles: u16,
) -> Result<DraftDto, String> {
    let (ends, picks) = check_threads(ends, picks)?;
    let draft = Draft::try_from(dto)?;
    Ok(DraftDto::from(
        &draft.resized(ends, picks, shafts, treadles),
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
/// `Err` past `MAX_GENERATED_SHAFTS` (a twill's tie-up grows with the square of its shaft count).
pub fn generate_tieup_dto(
    family: StructureFamily,
    shafts: u16,
    over: u16,
    under: u16,
    counter: u16,
) -> Result<Vec<Vec<u16>>, String> {
    let n = match family {
        StructureFamily::Twill => u32::from(over) + u32::from(under),
        _ => u32::from(shafts),
    };
    if n > MAX_GENERATED_SHAFTS {
        return Err(format!(
            "a generated tie-up can have at most {MAX_GENERATED_SHAFTS} shafts (asked for {n})"
        ));
    }
    let tieup = match family {
        StructureFamily::Plain => weave::draft::TieUp::plain(shafts),
        StructureFamily::Twill => weave::draft::TieUp::twill(over, under),
        StructureFamily::Satin => weave::draft::TieUp::satin(shafts, counter),
        // The whole-draft families must go through their own generators: a misrouted request is an
        // error, never a silently different structure.
        StructureFamily::Overshot | StructureFamily::DoubleWeave => {
            return Err(format!(
                "{family:?} is a whole-draft structure; generate it with generate_structure_dto"
            ));
        }
        StructureFamily::ShadowWeave => {
            return Err(
                "ShadowWeave is a whole-draft structure; generate it with generate_shadow_weave_dto"
                    .to_string(),
            );
        }
    };
    Ok(tieup
        .0
        .iter()
        .map(|r| r.iter().map(|s| s.0).collect())
        .collect())
}

/// Generate a COMPLETE draft for a whole-draft weave structure (overshot, double weave). Unlike
/// plain/twill/satin, whose tie-up + threading are composed Dart-side, these are interdependent (the
/// threading, tie-up, treadling, AND warp/weft colors must agree), so they are built whole in the
/// engine and returned as a ready-to-edit `DraftDto`. `block` is overshot's block width (at least 2).
/// Plain/Twill/Satin use the tie-up path and shadow weave its own typed call
/// ([`generate_shadow_weave_dto`]), so those are an `Err` here, as is a request where `ends`/`picks`
/// exceed the per-axis document cap shared with WIF import (`ply_weave::MAX_THREADS`).
pub fn generate_structure_dto(
    family: StructureFamily,
    ends: u32,
    picks: u32,
    block: u32,
) -> Result<DraftDto, String> {
    let (e, p) = check_threads(ends, picks)?;
    let b = (block as usize).max(2);
    let draft = match family {
        StructureFamily::Overshot => weave::structure::overshot(e, p, b),
        StructureFamily::DoubleWeave => weave::structure::double_weave(e, p),
        StructureFamily::ShadowWeave => {
            return Err(
                "ShadowWeave takes its own parameters; generate it with generate_shadow_weave_dto"
                    .to_string(),
            );
        }
        // Basic families are composed from tie-up + threading (`generate_tieup_dto`); a misrouted
        // request is an error, never a silently different structure.
        StructureFamily::Plain | StructureFamily::Twill | StructureFamily::Satin => {
            return Err(format!(
                "{family:?} is composed from a tie-up and threading; use generate_tieup_dto"
            ));
        }
    };
    Ok(DraftDto::from(&draft))
}

/// Generate an authentic shadow-weave draft (Atwater or Powell system) from typed parameters: the
/// threading from the block sequence and layout, the twill tie-up, the treadling as drawn in, and
/// the strict dark/light color orders, on a rising shed. Its size is whole repeats (plus one end and
/// one pick when balanced), never a cut unit. `Err` carries a plain sentence for any invalid
/// parameter: shafts other than 4 or 8, an empty sequence, a block the shafts do not have, a width of
/// 0, a single-block design, 0 repeats, or a size past the per-axis document cap shared with WIF
/// import (`ply_weave::MAX_THREADS`).
pub fn generate_shadow_weave_dto(params: ShadowParamsDto) -> Result<DraftDto, String> {
    let params = weave::shadow::ShadowParams::try_from(params).map_err(|e| e.to_string())?;
    weave::shadow::generate(&params)
        .map(|d| DraftDto::from(&d))
        .map_err(|e| e.to_string())
}

/// Generate a threading (per warp end, the 1-based shaft it threads) for the chosen draw over
/// `ends` ends and `shafts` shafts. `Err` if `ends` exceeds the per-axis document cap.
pub fn generate_threading_dto(
    kind: ThreadingKind,
    ends: u32,
    shafts: u16,
) -> Result<Vec<Vec<u16>>, String> {
    let (ends, _) = check_threads(ends, 0)?;
    let threading = match kind {
        ThreadingKind::Straight => weave::draft::Threading::straight(ends, shafts),
        ThreadingKind::Point => weave::draft::Threading::point(ends, shafts),
    };
    Ok(threading
        .0
        .iter()
        .map(|r| r.iter().map(|s| s.0).collect())
        .collect())
}

fn shed_type(shed: ShedKind) -> weave::ShedType {
    match shed {
        ShedKind::Rising => weave::ShedType::Rising,
        ShedKind::Sinking => weave::ShedType::Sinking,
    }
}

/// Re-express a draft for a loom with shed direction `shed`, keeping the cloth: a treadled draft's
/// tie-up becomes its complement (exact when each pick presses one treadle, as every generated
/// structure does). The structure generators assume a rising shed, so the editor passes their
/// output through this before giving it to a counterbalance or countermarch draft.
pub fn draft_with_shed_dto(dto: DraftDto, shed: ShedKind) -> Result<DraftDto, String> {
    let draft = Draft::try_from(dto)?;
    Ok(DraftDto::from(&draft.with_shed(shed_type(shed))))
}

/// Convert a GENERATED tie-up (rising-shed semantics, as `generate_tieup_dto` returns) into the
/// tie-up that weaves the same cloth on a loom with shed direction `shed`, over `shafts` shafts.
pub fn tieup_for_shed_dto(rows: Vec<Vec<u16>>, shafts: u16, shed: ShedKind) -> Vec<Vec<u16>> {
    match shed {
        ShedKind::Rising => rows,
        ShedKind::Sinking => weave::draft::TieUp(
            rows.iter()
                .map(|r| r.iter().map(|&s| weave::ShaftId(s)).collect())
                .collect(),
        )
        .complement(shafts)
        .0
        .iter()
        .map(|r| r.iter().map(|s| s.0).collect())
        .collect(),
    }
}

// ---------------------------------------------------------------------------
// M5 KNITTING surface (transparent DTOs). Mirrors the weaving surface — parse / write / render /
// validate over a mirrored `KnitPatternDto`, plus the gauge/yardage calculators. See `knit_dto.rs`.
// (`RepeatDto` is a data-carrying enum -> regenerate freezed after codegen, like `DriveDto`.)
// ---------------------------------------------------------------------------

pub use crate::knit_dto::{
    CableDefDto, CellDto, ChartDto, ConstructionKind, CrossKind, GaugeDto, KnitFormatFailure,
    KnitFormatFailureKind, KnitIssueDto, KnitPatternDto, RepeatDto, RepeatSpanDto, RowDto,
    SideKind, StitchDefDto, StitchLegendDto, YarnWeightKind,
};

/// Parse a native `.plyknit` file (any supported schema version) into the editor's
/// `KnitPatternDto`. A legacy file is migrated in memory; nothing is written. A file saved by a newer
/// Ply, a foreign format, or an unreadable file is an `Err(KnitFormatFailure)`, which Dart receives
/// as a thrown `KnitFormatFailure`.
pub fn parse_knit(json: String) -> Result<KnitPatternDto, KnitFormatFailure> {
    ply_knit::KnitPattern::from_json(&json)
        .map(|p| KnitPatternDto::from(&p))
        .map_err(KnitFormatFailure::from)
}

/// Serialize the editor's `KnitPatternDto` as a current-version native `.plyknit` envelope. `Err` if
/// the gauge is non-finite (the engine rejects a NaN/Inf gauge that JSON can't round-trip).
pub fn write_knit(dto: KnitPatternDto) -> Result<String, String> {
    ply_knit::KnitPattern::from(dto)
        .to_json()
        .map_err(|e| e.to_string())
}

/// Render a knitting chart `KnitPatternDto` to an RGBA preview (symbols + colorwork + cable spans).
/// A mirrored value, so the caller may render the SAME dto repeatedly (no single-use handle).
pub fn render_knit_preview(dto: KnitPatternDto, cell_px: u32) -> PreviewImage {
    let img = ply_knit::render_rgba(&ply_knit::KnitPattern::from(dto), cell_px);
    PreviewImage {
        width: img.width,
        height: img.height,
        rgba: img.pixels,
    }
}

/// Validate a knitting chart (full stitch-count balancing); one issue per problem, empty = clean.
pub fn validate_knit(dto: KnitPatternDto) -> Vec<KnitIssueDto> {
    ply_knit::validate(&ply_knit::KnitPattern::from(dto))
        .iter()
        .map(KnitIssueDto::from)
        .collect()
}

/// A blank starter pattern (builtin stitch legend, a worsted seed gauge, a one-color palette, an
/// empty chart the editor grows). The knit analog of `blank_draft`.
pub fn knit_blank_pattern() -> KnitPatternDto {
    let pattern = ply_knit::KnitPattern {
        name: String::new(),
        construction: ply_knit::Construction::Flat,
        first_row_side: ply_knit::Side::Rs,
        cast_on: None,
        gauge: ply_knit::calc::seed_gauge(ply_common::YarnWeight::Medium),
        palette: vec![ply_common::Color::WHITE],
        legend: ply_knit::StitchLegend::builtin(),
        chart: ply_knit::Chart {
            width: 0,
            rows: Vec::new(),
        },
        notes: String::new(),
    };
    KnitPatternDto::from(&pattern)
}

/// Cast-on stitch count for a target finished `width` + `ease` at `gauge`, rounded to the nearest
/// `repeat` multiple. 0 on an unusable gauge.
pub fn knit_cast_on(width: f32, ease: f32, gauge: GaugeDto, repeat: u32) -> u32 {
    ply_knit::calc::cast_on(width, ease, gauge.into(), repeat)
}

/// Estimate yards of yarn for a stockinette `width` x `length` rectangle at `gauge` (rough — the UI
/// should add a buffer).
pub fn knit_estimate_yards(width: f32, length: f32, gauge: GaugeDto) -> f32 {
    ply_knit::calc::estimate_yards_stockinette(width, length, gauge.into())
}

/// A default stockinette gauge seeded from a yarn weight (Craft Yarn Council table) — an editable
/// starting point the knitter overrides with their own swatch.
pub fn knit_seed_gauge(weight: YarnWeightKind) -> GaugeDto {
    GaugeDto::from(ply_knit::calc::seed_gauge(weight.into()))
}

/// The chart rendered as WRITTEN INSTRUCTIONS, one line per row (bottom-to-top, RS/WS-aware,
/// run-length collapsed) — the chart's second view.
pub fn knit_written(dto: KnitPatternDto) -> Vec<String> {
    ply_knit::to_written(&ply_knit::KnitPattern::from(dto))
}

// ---------------------------------------------------------------------------
// Nalbinding (M6) — stitch reference + per-stitch structural diagram. No project model or gauge
// calculator yet; see docs/NALBIND_DESIGN.md.
// ---------------------------------------------------------------------------

pub use crate::nalbind_dto::{
    ConnArrowDto, ConnSideKind, ConnectionDto, DiagramDto, FidelityKind, LoopGlyphDto, LoopKindDto,
    NalbindIssueDto, NalbindStitchDto, NotationDiagnosticDto, NotationModeKind,
    NotationSeverityKind, NotationSpanDto, OpaqueTokenDto, ParsedNotationDto, PassDto,
    PublishedCodeDto, StepKind, ThumbLoopsDto, TwistKind,
};

/// The curated builtin stitch dictionary (~12 stitches) for the reference screen.
pub fn nalbind_builtin() -> Vec<NalbindStitchDto> {
    ply_nalbind::builtin()
        .into_iter()
        .map(NalbindStitchDto::from)
        .collect()
}

/// Read a Hansen-notation string with provenance: the exact source, the best-effort stitch (for the
/// diagram), strict acceptance, fidelity, the uninterpreted tokens, and every diagnostic with its span
/// in UTF-16 code units. `strict = true` is the AUTHORING mode (a project's notation field: every
/// problem is reported as an `Error`); `false` is the REFERENCE mode (the playground: each problem at
/// its own severity). Never fails.
pub fn analyze_nalbind(text: String, strict: bool) -> ParsedNotationDto {
    crate::nalbind_dto::analyze_notation(&text, strict)
}

/// LEGACY lenient parse into an anonymous stitch, kept for compatibility: it discards warnings and
/// provenance, so the app reads notation through [`analyze_nalbind`]. `Err` carries the parse
/// message for an uninterpretable character.
pub fn parse_nalbind(notation: String) -> Result<NalbindStitchDto, String> {
    ply_nalbind::notation::parse(&notation)
        .map(|(passes, connections)| {
            NalbindStitchDto::from(ply_nalbind::StitchType::anonymous(passes, connections))
        })
        .map_err(|e| e.to_string())
}

/// Print a stitch back to a canonical Hansen string.
pub fn print_nalbind(dto: NalbindStitchDto) -> String {
    let st = ply_nalbind::StitchType::from(dto);
    ply_nalbind::notation::print(&st.passes, &st.connections)
}

/// Build the per-stitch structural loop diagram (vector model the Flutter painter draws).
pub fn nalbind_diagram(dto: NalbindStitchDto) -> DiagramDto {
    DiagramDto::from(ply_nalbind::diagram(&ply_nalbind::StitchType::from(dto)))
}

/// Validate a stitch (empty path / zero-loop connection); empty = clean.
pub fn validate_nalbind(dto: NalbindStitchDto) -> Vec<NalbindIssueDto> {
    ply_nalbind::validate(&ply_nalbind::StitchType::from(dto))
        .iter()
        .map(NalbindIssueDto::from)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn plain(ends: usize, picks: usize) -> DraftDto {
        DraftDto::from(&weave::structure::plain_weave(ends, picks))
    }

    fn limits(max_cells: usize, max_raster_bytes: usize) -> weave::RenderLimits {
        weave::RenderLimits {
            max_cells,
            max_raster_bytes,
            max_raster_side: usize::MAX,
        }
    }

    fn overlays() -> Option<RenderOptionsDto> {
        Some(RenderOptionsDto {
            gridlines: true,
            float_threshold: 0,
            thread_texture: true,
        })
    }

    #[test]
    fn preview_keeps_the_requested_pitch_when_it_fits() {
        let img = render_preview_dto(plain(4, 3), 12, None).unwrap();
        assert_eq!((img.width, img.height), (48, 36));
    }

    /// Over budget at the requested pitch: the preview drops to the largest pitch that fits instead
    /// of coming back blank (10 x 10 at 12 px = 120 x 120; a 40 x 40 budget fits 4 px).
    #[test]
    fn preview_fits_the_pitch_to_the_budget() {
        let img =
            render_preview_within(plain(10, 10), 12, None, &limits(1000, 40 * 40 * 4)).unwrap();
        assert_eq!((img.width, img.height), (40, 40));
    }

    /// A fitted pitch under 4 px drops gridlines and texture; a fitted pitch of 4 px or more keeps
    /// them, and an unfitted render always honors the request.
    #[test]
    fn fitted_previews_drop_fine_overlays_only_below_four_px() {
        let tiny = limits(1000, 20 * 20 * 4); // fits 2 px for a 10 x 10 draft
        let with = render_preview_within(plain(10, 10), 12, overlays(), &tiny).unwrap();
        let without = render_preview_within(plain(10, 10), 12, None, &tiny).unwrap();
        assert_eq!((with.width, with.height), (20, 20));
        assert_eq!(
            with.rgba, without.rgba,
            "2 px fitted render is a plain cloth"
        );

        let roomy = limits(1000, 40 * 40 * 4); // fits 4 px
        let with = render_preview_within(plain(10, 10), 12, overlays(), &roomy).unwrap();
        let without = render_preview_within(plain(10, 10), 12, None, &roomy).unwrap();
        assert_ne!(
            with.rgba, without.rgba,
            "4 px fitted render keeps its overlays"
        );

        // Asked for 2 px directly (no fitting): overlays stay as requested.
        let asked = render_preview_within(plain(10, 10), 2, overlays(), &tiny).unwrap();
        let plain2 = render_preview_within(plain(10, 10), 2, None, &tiny).unwrap();
        assert_ne!(asked.rgba, plain2.rgba);
    }

    #[test]
    fn oversized_draft_is_a_typed_too_large_failure() {
        let Err(err) = render_preview_within(plain(10, 10), 12, None, &limits(50, usize::MAX))
        else {
            panic!("expected a render failure");
        };
        assert_eq!(err.kind, RenderFailureKind::TooLarge);
        assert!(err.message.contains("intersections"), "{}", err.message);
    }

    /// The real default budget refuses the largest draft a WIF can declare, without rendering.
    #[test]
    fn default_budget_refuses_the_largest_wif_draft() {
        let Err(err) = render_preview_dto(plain(100_000, 100_000), 12, None) else {
            panic!("expected a render failure");
        };
        assert_eq!(err.kind, RenderFailureKind::TooLarge);
    }

    fn region(
        end_start: u32,
        end_count: u32,
        pick_start: u32,
        pick_count: u32,
    ) -> DrawdownRegionDto {
        DrawdownRegionDto {
            end_start,
            end_count,
            pick_start,
            pick_count,
        }
    }

    /// The DTO names the same cells as the engine region (0-based start + count), and the bridge
    /// render is the engine's region render, byte for byte, with the options passed through.
    #[test]
    fn region_dto_round_trips_to_the_engine_render() {
        assert_eq!(
            weave::DrawdownRegion::try_from(region(3, 4, 10, 2)).unwrap(),
            weave::DrawdownRegion::new(3..7, 10..12)
        );
        let mut twill = weave::structure::plain_weave(12, 9);
        twill.colors.palette = vec![
            ply_common::Color::BLACK,
            ply_common::Color::rgb(200, 90, 20),
        ];
        twill.colors.weft = vec![1; 9];
        twill.warp_thickness = vec![2.0; 12]; // ignored by a region render, kept by the DTO
        let opts = RenderOptionsDto {
            gridlines: true,
            float_threshold: 2,
            thread_texture: true,
        };
        let img =
            render_region_dto(DraftDto::from(&twill), region(3, 4, 6, 3), 5, Some(opts)).unwrap();
        let engine = weave::try_render_region(
            &twill,
            &weave::DrawdownRegion::new(3..7, 6..9),
            5,
            &weave::RenderOptions {
                gridlines: true,
                float_threshold: 2,
                thread_texture: true,
            },
            &weave::RenderLimits::DEFAULT,
        )
        .unwrap();
        assert_eq!((img.width, img.height), (20, 15));
        assert_eq!(img.rgba, engine.pixels);
        // No options is a plain cloth.
        let plain_img =
            render_region_dto(DraftDto::from(&twill), region(3, 4, 6, 3), 5, None).unwrap();
        assert_ne!(plain_img.rgba, img.rgba);
    }

    /// A region of a draft far over the whole-render budget renders; the whole draft does not.
    #[test]
    fn a_region_of_the_largest_wif_draft_renders() {
        let huge = plain(100_000, 100_000);
        let img = render_region_dto(huge, region(99_990, 10, 0, 8), 12, overlays()).unwrap();
        assert_eq!((img.width, img.height), (120, 96));
    }

    #[test]
    fn invalid_regions_are_typed_failures() {
        for bad in [
            region(0, 0, 0, 2),               // no ends
            region(0, 2, 0, 0),               // no picks
            region(3, 2, 0, 2),               // past the last end
            region(0, 2, 1, 4),               // past the last pick
            region(u32::MAX, u32::MAX, 0, 1), // start + count past the draft (or usize)
        ] {
            let Err(err) = render_region_dto(plain(4, 4), bad, 8, None) else {
                panic!("expected a failure for {bad:?}");
            };
            assert_eq!(err.kind, RenderFailureKind::InvalidRegion, "{bad:?}");
            assert!(err.message.contains("region"), "{}", err.message);
        }
    }

    /// Over the raster budget the region drops to the largest pitch that fits (and, below 4 px, to a
    /// plain cloth), exactly like the whole preview; over the intersection budget it is `TooLarge`.
    #[test]
    fn region_renders_fit_the_budget_or_fail_as_too_large() {
        // 10 x 10 cells: 40 x 40 px fits 4 px.
        let img = render_region_within(
            plain(20, 20),
            region(5, 10, 5, 10),
            12,
            overlays(),
            &limits(1000, 40 * 40 * 4),
        )
        .unwrap();
        assert_eq!((img.width, img.height), (40, 40));
        let tiny = limits(1000, 20 * 20 * 4); // fits 2 px: overlays dropped
        let with = render_region_within(plain(20, 20), region(5, 10, 5, 10), 12, overlays(), &tiny)
            .unwrap();
        let without =
            render_region_within(plain(20, 20), region(5, 10, 5, 10), 12, None, &tiny).unwrap();
        assert_eq!((with.width, with.height), (20, 20));
        assert_eq!(with.rgba, without.rgba);
        // Asked for 2 px directly: the overlays stay.
        let asked = render_region_within(plain(20, 20), region(5, 10, 5, 10), 2, overlays(), &tiny)
            .unwrap();
        assert_ne!(asked.rgba, without.rgba);

        let Err(err) = render_region_within(
            plain(20, 20),
            region(0, 10, 0, 10),
            4,
            None,
            &limits(99, usize::MAX),
        ) else {
            panic!("expected a render failure");
        };
        assert_eq!(err.kind, RenderFailureKind::TooLarge);
        assert!(err.message.contains("intersections"), "{}", err.message);
    }

    #[test]
    fn resize_and_generators_refuse_more_than_max_threads() {
        let over = (weave::MAX_THREADS + 1) as u32;
        assert!(resize_dto(plain(2, 2), over, 2, 2, 2).is_err());
        assert!(resize_dto(plain(2, 2), 2, over, 2, 2).is_err());
        assert!(resize_dto(plain(2, 2), 3, 3, 2, 2).is_ok());
        assert!(generate_structure_dto(StructureFamily::Overshot, over, 8, 4).is_err());
        assert!(generate_structure_dto(StructureFamily::DoubleWeave, 8, 8, 4).is_ok());
        assert!(generate_threading_dto(ThreadingKind::Straight, over, 4).is_err());
        assert_eq!(
            generate_threading_dto(ThreadingKind::Straight, 4, 2).unwrap(),
            vec![vec![1], vec![2], vec![1], vec![2]]
        );
    }

    /// A generated structure moved onto a sinking-shed draft weaves the same cloth (pixel-identical
    /// preview), with the tie-up flipped to name the shafts that sink.
    #[test]
    fn generated_structure_keeps_its_cloth_on_a_sinking_shed() {
        let rising = generate_structure_dto(StructureFamily::Overshot, 16, 16, 4).unwrap();
        let sinking = draft_with_shed_dto(
            generate_structure_dto(StructureFamily::Overshot, 16, 16, 4).unwrap(),
            ShedKind::Sinking,
        )
        .unwrap();
        assert!(matches!(sinking.shed, ShedKind::Sinking));
        // The pattern/tabby roles the generator recorded cross the bridge and survive the shed
        // conversion the app applies to every generated draft.
        assert_eq!(rising.pick_roles.len(), 16);
        assert_eq!(rising.pick_roles[0], PickRoleKind::Pattern);
        assert_eq!(rising.pick_roles[1], PickRoleKind::Tabby);
        assert_eq!(sinking.pick_roles, rising.pick_roles);
        let a = render_preview_dto(rising, 4, None).ok().unwrap();
        let b = render_preview_dto(sinking, 4, None).ok().unwrap();
        assert_eq!(a.rgba, b.rgba);

        assert_eq!(
            tieup_for_shed_dto(vec![vec![1, 2], vec![2, 3]], 4, ShedKind::Sinking),
            vec![vec![3, 4], vec![1, 4]]
        );
        assert_eq!(
            tieup_for_shed_dto(vec![vec![1, 2]], 4, ShedKind::Rising),
            vec![vec![1, 2]]
        );
    }

    /// Roles survive the editor's FFI round trips: WIF write and parse, resize, and the liftplan
    /// convert; a resize that adds picks pads Unknown, and validation sees the roles.
    #[test]
    fn pick_roles_cross_every_bridge_round_trip() {
        let dto = generate_structure_dto(StructureFamily::DoubleWeave, 8, 4, 2).unwrap();
        let roles = dto.pick_roles.clone();
        assert_eq!(
            roles,
            vec![
                PickRoleKind::TopLayer,
                PickRoleKind::BottomLayer,
                PickRoleKind::TopLayer,
                PickRoleKind::BottomLayer
            ]
        );
        let wif = write_wif(generate_structure_dto(StructureFamily::DoubleWeave, 8, 4, 2).unwrap())
            .unwrap();
        assert_eq!(parse_wif_dto(wif).unwrap().pick_roles, roles);
        let lp =
            to_liftplan_dto(generate_structure_dto(StructureFamily::DoubleWeave, 8, 4, 2).unwrap())
                .unwrap();
        assert_eq!(lp.pick_roles, roles);
        let grown = resize_dto(lp, 8, 6, 4, 0).unwrap();
        assert_eq!(&grown.pick_roles[..4], &roles[..]);
        assert_eq!(
            &grown.pick_roles[4..],
            &[PickRoleKind::Unknown, PickRoleKind::Unknown]
        );
        let mut bad = generate_structure_dto(StructureFamily::DoubleWeave, 8, 4, 2).unwrap();
        bad.pick_roles.pop();
        let issues = validate_draft(bad).unwrap();
        assert!(issues
            .iter()
            .any(|i| matches!(i.severity, SeverityKind::Error) && i.message.contains("pick role")));
    }

    /// A family sent to the wrong generator is an error, not a silently different structure.
    #[test]
    fn misrouted_structure_requests_are_errors() {
        assert!(generate_structure_dto(StructureFamily::Twill, 8, 8, 4).is_err());
        assert!(generate_tieup_dto(StructureFamily::Overshot, 4, 2, 2, 1).is_err());
        let shadow = generate_structure_dto(StructureFamily::ShadowWeave, 8, 8, 4);
        assert!(shadow.is_err_and(|e| e.contains("generate_shadow_weave_dto")));
        assert!(generate_tieup_dto(StructureFamily::ShadowWeave, 4, 2, 2, 1).is_err());
    }

    fn shadow(shafts: u16, blocks: &[(u16, u16)]) -> ShadowParamsDto {
        ShadowParamsDto {
            system: ShadowSystemKind::Atwater,
            shafts,
            layout: ShadowLayoutKind::Point,
            blocks: blocks
                .iter()
                .map(|&(block, units)| ShadowBlockDto { block, units })
                .collect(),
            direction: TwillDirectionKind::Forward,
            weft_phase: WeftPhaseKind::Standard,
            warp_repeats: 2,
            weft_repeats: 2,
            balance: true,
        }
    }

    fn abcd() -> ShadowParamsDto {
        shadow(4, &[(0, 2), (1, 2), (2, 2), (3, 2)])
    }

    /// The default design (Atwater, 4 shafts, a point of A2 B2 C2 D2, two repeats each way,
    /// balanced) comes back as a whole, ready-to-edit draft.
    #[test]
    fn shadow_weave_generates_the_default_design() {
        let dto = generate_shadow_weave_dto(abcd()).unwrap();
        assert_eq!(dto.name, "Shadow weave (Atwater)");
        assert_eq!((dto.shafts, dto.treadles), (4, 4));
        assert_eq!((dto.threading.len(), dto.weft_colors.len()), (61, 61));
        assert!(matches!(dto.shed, ShedKind::Rising));
        let DriveDto::Treadled { tieup, treadling } = &dto.drive else {
            panic!("expected a treadled draft");
        };
        assert_eq!(tieup, &vec![vec![1, 2], vec![2, 3], vec![3, 4], vec![1, 4]]);
        let threading: Vec<u16> = dto.threading.iter().map(|r| r[0]).collect();
        let treadles: Vec<u16> = treadling.iter().map(|r| r[0]).collect();
        assert_eq!(threading, treadles, "treadled as drawn in");
        assert!(validate_draft(dto).unwrap().is_empty());
    }

    /// Every invalid parameter is an error with a plain message; nothing is clamped.
    #[test]
    fn shadow_weave_parameters_are_validated() {
        let err = |p: ShadowParamsDto| generate_shadow_weave_dto(p).err().unwrap();
        for shafts in [0, 2, 3, 5, 6, 7, 9, 10, 16] {
            let mut p = abcd();
            p.shafts = shafts;
            assert_eq!(
                err(p),
                format!("shadow weave needs 4 or 8 shafts, not {shafts}")
            );
        }
        assert_eq!(err(shadow(4, &[])), "the design has no blocks");
        assert_eq!(
            err(shadow(4, &[(0, 2), (4, 1)])),
            "block entry 2 is block number 5, but 4 shafts give blocks A to D"
        );
        assert_eq!(
            err(shadow(4, &[(0, 2), (1, 0)])),
            "block entry 2 has no units; each block needs at least 1"
        );
        assert_eq!(
            err(shadow(8, &[(5, 3)])),
            "the design uses a single block; shadow weave needs at least two"
        );
        let mut p = abcd();
        p.warp_repeats = 0;
        assert_eq!(err(p), "warp and weft repeats must each be at least 1");
        let mut p = abcd();
        p.weft_repeats = u16::MAX;
        assert!(err(p).contains("a draft allows at most 100000 of each"));
        // 8 shafts accept blocks A to H.
        assert!(generate_shadow_weave_dto(shadow(8, &[(0, 1), (7, 1)])).is_ok());
    }

    /// Atwater and Powell are two numberings of one cloth: same preview, pixel for pixel, and the same
    /// cloth again on a sinking-shed loom.
    #[test]
    fn shadow_weave_systems_and_sheds_weave_the_same_cloth() {
        let atwater = generate_shadow_weave_dto(abcd()).unwrap();
        let mut p = abcd();
        p.system = ShadowSystemKind::Powell;
        let powell = generate_shadow_weave_dto(p).unwrap();
        assert_eq!(powell.name, "Shadow weave (Powell)");
        assert_ne!(atwater.threading, powell.threading);
        let a = render_preview_dto(atwater, 2, None).ok().unwrap();
        let sinking = draft_with_shed_dto(
            generate_shadow_weave_dto(abcd()).unwrap(),
            ShedKind::Sinking,
        )
        .unwrap();
        let b = render_preview_dto(powell, 2, None).ok().unwrap();
        let c = render_preview_dto(sinking, 2, None).ok().unwrap();
        assert_eq!(a.rgba, b.rgba);
        assert_eq!(a.rgba, c.rgba);
    }

    /// Swapping the weft colors keeps the threading and treadling and flips only the weft order.
    #[test]
    fn shadow_weave_edge_style_only_swaps_the_weft_colors() {
        let smooth = generate_shadow_weave_dto(abcd()).unwrap();
        let mut p = abcd();
        p.weft_phase = WeftPhaseKind::Swapped;
        let feathery = generate_shadow_weave_dto(p).unwrap();
        assert_eq!(smooth.threading, feathery.threading);
        assert_eq!(smooth.warp_colors, feathery.warp_colors);
        let flipped: Vec<u32> = smooth.weft_colors.iter().map(|&c| 1 - c).collect();
        assert_eq!(feathery.weft_colors, flipped);
    }

    /// A twill tie-up grows with the square of its shaft count; absurd requests are refused rather
    /// than allocating gigabytes.
    #[test]
    fn tieup_generation_refuses_absurd_shaft_counts() {
        assert!(generate_tieup_dto(StructureFamily::Twill, 0, u16::MAX, 1, 1).is_err());
        assert!(generate_tieup_dto(StructureFamily::Satin, 5000, 0, 0, 2).is_err());
        assert_eq!(
            generate_tieup_dto(StructureFamily::Twill, 0, 2, 2, 1).unwrap(),
            vec![vec![1, 2], vec![2, 3], vec![3, 4], vec![4, 1]]
        );
    }
}
