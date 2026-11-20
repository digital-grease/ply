//! Ply knitting engine.
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
pub mod flow;
pub mod instruction;
// The lean JSON tree an older `.plyknit` is migrated on (ADR 0007, amendment of 2026-11-18).
mod json_tree;
pub mod native;
// The route an older `.plyknit` took through a `serde_json::Value`, the oracle of the lean one.
#[cfg(test)]
mod native_tree_oracle;
pub mod pattern;
pub mod plan;
// Working a pattern row by row, and resuming a saved place (ADR 0023).
pub mod progress;
// Is a pattern ready to make or share (ADR 0021)?
pub mod readiness;
pub mod render;
pub mod sections;
pub mod validate;
pub mod written;

pub use error::KnitError;
pub use flow::{stitch_flow, RowCount, RowFlow};
pub use instruction::{row_instruction, RowInstruction, RowItem, RowProblem, SpanRef, StitchOp};
pub use native::{LoadedPattern, KNIT_FORMAT, KNIT_SCHEMA_VERSION};
pub use pattern::{
    builtin, CableDef, Cell, Chart, ColorIndex, Construction, Cross, Gauge, KnitPattern, Repeat,
    RepeatSpan, Row, Side, StitchDef, StitchId, StitchLegend,
};
pub use render::{render_rgba, RgbaImage};
pub use sections::{
    ledger, HeldCount, Ledger, LedgerLine, LineCount, NeedleCount, Section, SectionIssue, Step,
    StepAction, TurnAt, TurnMethod, WorkStitch, WorkTo,
};
pub use validate::{validate, KnitIssue, Severity};
pub use written::to_written;
