use thiserror::Error;

/// Errors from the nalbinding engine.
#[derive(Debug, Error)]
pub enum NalbindError {
    /// A Hansen-notation string contained a character the grammar does not recognize.
    #[error("invalid Hansen notation: {0}")]
    BadNotation(String),

    /// JSON (de)serialization failed.
    #[error(transparent)]
    Json(#[from] serde_json::Error),
}
