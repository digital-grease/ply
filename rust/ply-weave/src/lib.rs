//! Ply weaving engine.
//!
//! Pure Rust: draft model, drawdown computation, WIF import/export, weaving
//! calculators, and validation. **No Flutter, no FFI** — the FFI surface lives in
//! the `ply-bridge` crate so this engine stays reusable (CLI, server, tests).
//!
//! See `docs/DATA_MODEL.md` for the design rationale and `docs/WIF_MAPPING.md` for
//! how the model maps to the WIF interchange format.

pub mod calc;
pub mod draft;
pub mod drawdown;
pub mod error;
pub mod profile;
pub mod shadow;
pub mod structure;
pub mod validate;
pub mod wif;

pub use draft::{
    Draft, Drive, Liftplan, PickRole, ShaftId, ShedType, ShotGroup, ShuttleId, Side, TabbyRule,
    Threading, TieUp, TreadleId, Treadling, WeftWork, MAX_SHUTTLES, MAX_STRANDS,
};
pub use drawdown::{
    compute, fit_cell_px, fit_region_cell_px, render_rgba, render_rgba_with, try_compute,
    try_render_region, try_render_rgba_with, Cell, Drawdown, DrawdownRegion, RenderError,
    RenderLimits, RenderOptions, RgbaImage,
};
pub use error::{Result, WeaveError};
pub use wif::MAX_THREADS;
