//! Error type for the knitting engine.

use thiserror::Error;

/// Errors from `ply-knit` operations (currently the native-format serialization path).
#[derive(Debug, Error)]
pub enum KnitError {
    /// A gauge held a NaN or infinite value. JSON has no NaN/Infinity literal, so serde would emit
    /// `null` — which then fails to parse back, yielding a write-then-unreadable file. We reject it
    /// at save time instead.
    #[error("gauge stitch/row counts must be finite")]
    NonFiniteGauge,
    /// A serialization / deserialization error from the native JSON (`.plyknit`) format.
    #[error("knit pattern JSON error: {0}")]
    Json(#[from] serde_json::Error),
}
