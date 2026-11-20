//! Why a pattern could not be resolved.

use crate::diagnostic::Diagnostic;
use std::fmt;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CrochetError {
    /// The pattern has structural errors (or passes a size limit), so resolution is undefined; every
    /// one is listed, each code at most `max_diagnostics_per_code` times. Anchor and count problems
    /// are not errors here: they are diagnostics of a resolution that goes on.
    Invalid(Vec<Diagnostic>),
    /// A window that is empty or reaches outside the piece (layers are numbered from 1).
    InvalidWindow { first: u32, last: u32, layers: u32 },
}

impl fmt::Display for CrochetError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            CrochetError::Invalid(d) => write!(
                f,
                "the pattern cannot be resolved: {} error(s), the first: {}",
                d.len(),
                d.first().map_or("", |d| d.message.as_str())
            ),
            CrochetError::InvalidWindow {
                first,
                last,
                layers,
            } => write!(
                f,
                "layers {first} to {last} are not a window of this {layers}-layer piece"
            ),
        }
    }
}

impl std::error::Error for CrochetError {}
