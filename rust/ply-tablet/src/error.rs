//! Why a band could not be simulated.

use crate::diagnostic::Diagnostic;
use thiserror::Error;

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum TabletError {
    /// The band has structural errors (or passes a size limit); every one is listed, each code at
    /// most `max_diagnostics_per_code` times. Fix them, then simulate. Unsupported actions are not
    /// errors.
    #[error("the band cannot be simulated: {} error(s), the first: {}", .0.len(), first_message(.0))]
    Invalid(Vec<Diagnostic>),
    /// A window that is empty or reaches outside the band (picks are 1-based).
    #[error("picks {first} to {last} are not a window of this {picks}-pick band")]
    InvalidWindow { first: u32, last: u32, picks: u32 },
    /// A pick past the end of the band.
    #[error("pick {pick} is past the end of this {picks}-pick band")]
    PickOutOfRange { pick: u32, picks: u32 },
    /// The window has more cells (cards times picks) than the limit; ask for a smaller window.
    #[error("a window of {cards} cards by {picks} picks has {cells} cells; the limit is {limit}")]
    WindowTooLarge {
        cards: usize,
        picks: u32,
        cells: usize,
        limit: usize,
    },
    /// The allocator refused a buffer that was within budget.
    #[error("could not allocate {bytes} bytes for the window")]
    AllocFailed { bytes: usize },
}

fn first_message(d: &[Diagnostic]) -> &str {
    d.first().map_or("", |d| d.message.as_str())
}
