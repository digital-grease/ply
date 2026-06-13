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
pub mod validate;
pub mod wif;

pub use draft::{Draft, Drive, Liftplan, ShaftId, ShedType, Threading, TieUp, Treadling, TreadleId};
pub use drawdown::{
    compute, render_rgba, render_rgba_with, Cell, Drawdown, RenderOptions, RgbaImage,
};
pub use error::{Result, WeaveError};
