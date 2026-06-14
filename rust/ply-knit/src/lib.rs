//! Ply knitting engine (M5, in progress).
//!
//! Pure Rust: the knitting pattern model (a chart over an open stitch legend) and — in later phases —
//! chart rendering, validation, gauge/yardage calculators, and the native JSON format. **No Flutter,
//! no FFI**; the FFI surface lives in `ply-bridge` so this engine stays reusable (CLI, server, tests),
//! exactly like `ply-weave`.
//!
//! See `docs/KNIT_DESIGN.md` for the design rationale, the prior-art survey, and the open owner
//! decisions that gate the milestone.

pub mod calc;
pub mod error;
pub mod pattern;
pub mod validate;

pub use error::KnitError;
pub use validate::{validate, KnitIssue, Severity};
pub use pattern::{
    builtin, CableDef, Cell, Chart, ColorIndex, Construction, Cross, Gauge, KnitPattern, Repeat,
    RepeatSpan, Row, Side, StitchDef, StitchId, StitchLegend,
};
