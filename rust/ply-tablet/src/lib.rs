//! Tablet (card) weaving engine: the card-turn state machine of ADR 0018.
//!
//! **Pure and deterministic**: no Flutter, no FFI, no I/O beyond serde. Given a band (each card's
//! threads, threading and start arrangement, and an ordered list of per-card turns with flips and
//! twist releases between picks), the engine computes, pick by pick and card by card, the
//! arrangement, the thread on each face (by the published crossing rule), the twining, reversals,
//! float runs and the twist ledger. Twist is computed, never reset by a reversal or a flip; the only
//! reset is a release the weaver records.
//!
//! Conventions (ADR 0018 sections 1 to 7): the weaver sits at the near end; cards are numbered from
//! the weaver's left; positions are named NT, FT, FB, NB as seen from the weaver's right; a forward
//! turn moves the top edge away from the weaver; S and Z name the thread's path; Z twining is
//! positive. Everything outside v1 (half turns, cards on points, other hole counts, faces where an
//! empty hole crosses, an idle with no earlier turn) is reported, never guessed.
//!
//! **Untrusted sizes**: [`validate()`], [`try_simulate`] and [`state_after`] check every count against
//! [`TabletLimits`] with checked arithmetic before allocating, and never panic.
//!
//! Results are to be labelled as awaiting a tablet weaver's review (ADR 0018 section 17) until that
//! review is done: see [`PRACTITIONER_REVIEW_PENDING`].

pub mod band;
pub mod card;
pub mod checkpoint;
pub mod diagnostic;
pub mod document;
pub mod error;
pub mod instructions;
// Working a band pick by pick and resuming a saved place (roadmap M8-05, ADR 0023).
pub mod progress;
pub mod render;
pub mod simulate;
pub mod validate;

pub use band::{
    BandSettings, CardId, ColorIndex, HoleThread, HoleThreads, NoteKind, Pack, PickNote, PickSpec,
    Segment, Tablet, TabletBand, TabletLimits, TurnSequence, DEFAULT_FLOAT_WARNING_PICKS,
    DEFAULT_TWIST_WARNING_QUARTERS, MAX_CARDS, MAX_DIAGNOSTICS_PER_CODE, MAX_PACKS, MAX_PALETTE,
    MAX_PICKS, MAX_SEGMENTS, MAX_TEXT_BYTES, MAX_WINDOW_CELLS,
};
pub use card::{
    Arrangement, CardPosition, Face, Hole, IllegalArrangement, Position, ThreadingDirection, Turn,
    Twining,
};
pub use checkpoint::{
    band_fingerprint, checkpoint_interval, checkpoints, nearest_before, state_after_from,
    try_simulate_from, Checkpoint, CheckpointError, MAX_CHECKPOINT_CARD_STATES,
    MIN_CHECKPOINT_INTERVAL,
};
pub use diagnostic::{
    CardSet, Diagnostic, PackSet, RunEnd, Severity, TabletCode, TabletLocation, MAX_LOCATION_CARDS,
    MAX_LOCATION_PACKS,
};
pub use document::{
    check_document_limits, document_schema_version, read_document, write_document, DocumentError,
    LoadedDocument, TabletDocument, MAX_DOCUMENT_BYTES, MAX_NOTES_BYTES, MAX_PROBED_DOCUMENT_BYTES,
    TABLET_FORMAT, TABLET_SCHEMA_VERSION,
};
pub use error::TabletError;
pub use instructions::{
    working_instructions, InstructionKind, InstructionLine, Instructions, MAX_GROUPS_PER_LINE,
};
pub use render::{
    fit_cell_px, try_render_face, try_render_turning, RasterLimits, RenderError, RenderOptions,
    TabletRaster, MAX_CELL_PX, MIN_LETTER_CELL_PX,
};
pub use simulate::{
    face_color, state_after, try_simulate, try_simulate_all, BandState, CardPick, CardState,
    FaceCell, FaceColor, FaceThread, PickInfo, TabletWindow, TwistState,
};
pub use validate::{expanded_picks, validate, validate_with};

/// The version of the rules this engine applies (ADR 0018 sections 4 to 7). The same band and the
/// same rules version always give the same output; a change to any rule's result bumps it.
pub const RULES_VERSION: u32 = 1;

/// True until a tablet weaver has reviewed the rules (ADR 0018 section 17); while it is, screens and
/// prints label the computed faces and twist as awaiting that review.
pub const PRACTITIONER_REVIEW_PENDING: bool = true;
