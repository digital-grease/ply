//! Error type for the knitting engine.

use thiserror::Error;

/// Errors from `ply-knit` operations (currently the native `.plyknit` format, see [`crate::native`]).
#[derive(Debug, Error)]
pub enum KnitError {
    /// A gauge held a NaN or infinite value. JSON has no NaN/Infinity literal, so serde would emit
    /// `null`, which then fails to parse back, yielding a write-then-unreadable file. We reject it
    /// at save time instead.
    #[error("gauge stitch/row counts must be finite")]
    NonFiniteGauge,
    /// A serialization / deserialization error from the native JSON (`.plyknit`) format.
    #[error("knit pattern JSON error: {0}")]
    Json(#[from] serde_json::Error),
    /// The file was written by a newer Ply with a schema this build does not know. Nothing was
    /// decoded; the file must not be written to by this build.
    #[error(
        "saved with .plyknit schema version {found}; this build reads up to version {supported}"
    )]
    NewerVersion { found: u64, supported: u32 },
    /// The file is a Ply envelope for some other format (its `format` value is in `found`).
    #[error("not a Ply knitting pattern (format {found})")]
    WrongFormat { found: String },
    /// The file is not a well-formed `.plyknit` envelope or legacy pattern.
    #[error("malformed .plyknit file: {0}")]
    Malformed(String),
}
