use thiserror::Error;

#[derive(Debug, Error)]
pub enum WeaveError {
    #[error("WIF parse error: {0}")]
    WifParse(String),
    #[error("invalid draft: {0}")]
    Invalid(String),
}

pub type Result<T> = std::result::Result<T, WeaveError>;
