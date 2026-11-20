//! Crochet engine: the operation, attachment and counting model of ADR 0022 (roadmap M11-01).
//!
//! **Pure and deterministic**: no Flutter, no FFI, no I/O beyond serde. A pattern
//! ([`CrochetPattern`]) is a start and its layers (rows or rounds) in work order, each a list of
//! instructions that name their targets relatively, as written patterns do: "sc in next st", "3 dc
//! in next ch-2 sp", "2 sc in same st", "sk next st", "rep from * across". The engine resolves every
//! target to an explicit attachment by walking a cursor along the layer's base, so a stitch "in next
//! sp" and one "in next st" are different facts even when the counts agree, and a chart drawn from
//! the result puts each stitch's foot where it is worked.
//!
//! The model in one place (ADR 0022 sections 1 to 13):
//!
//! - **Identities by structure** ([`Basic`], [`Identity`]): `b0`, `b1h`, `b1`, `b2`, `b3`, `chain`,
//!   `slip` and `tog`. Names such as "sc" and "dc" belong to a label set ([`LabelSet`]), which only
//!   changes text; "dc" is `b1` in US terms and `b0` in UK terms.
//! - **Positions and targets** ([`PosRef`], [`Anchor`]): stitch tops (both loops, or one, as
//!   worked), the top of a counted starting chain, spaces under chain runs, single chains, the ring.
//! - **The cursor words** ([`Target`]): `next` of a kind (other kinds on the way are passed over and
//!   listed), `same`, `skip`, `ring`, the use site of a named stitch, and joins into the round's start
//!   or a marker; `leave_unworked` ends a row on purpose.
//! - **Starts and starting chains** ([`PieceStart`], [`StartChain`]): a foundation chain (layer 1's
//!   chain taken from it, form a, or standing on it, form b), foundation stitches, a magic or chain
//!   ring; every starting chain stores whether it counts, as nothing, a stitch, or a stitch and a
//!   space. Ply's `by_height` suggestion ([`StartChainRule::suggest`]) is never read when resolving.
//! - **Rows, joined rounds, spiral rounds and turned rounds**, each with its rule for where the next
//!   layer's base begins.
//! - **Repeats** (`times`, `to_end`, `to_last`, nested), with stopping rules that always terminate.
//! - **What Ply does not model stays the pattern's words**: opaque instructions, targets and layers
//!   carry an unsupported severity and are never counted as stitches they do not state; an opaque
//!   item that states neither what it uses nor what it makes leaves every later count unknown.
//! - **Counts and diagnostics** ([`LayerCount`], [`Diagnostic`]): derived counts, stated counts
//!   compared exactly, and stable codes (`crochet.*`) with typed locations and the shared severities
//!   of ADR 0021.
//!
//! **Untrusted sizes**: [`validate()`], [`try_resolve`] and [`try_resolve_all`] check every count
//! against [`CrochetLimits`] with saturating arithmetic before allocating, stop the moment a budget
//! would be passed, and never panic.
//!
//! Not here (ADR 0022 sections 14 and 21, M11-02): the native document, the written instructions
//! (only the count phrase of rule W17 is built, [`LabelSet::count_text`]) and the chart. Results are to
//! be labelled as awaiting a crocheter's review (ADR 0022 section 24) until it is done:
//! [`PRACTITIONER_REVIEW_PENDING`].

pub mod base;
mod check;
pub mod count;
pub mod diagnostic;
pub mod error;
pub mod labels;
pub mod limits;
pub mod pattern;
pub mod place;
pub mod resolve;
pub mod stitch;
mod validate;

pub use base::{Position, PositionKind};
pub use count::{LayerCount, StatedCheck};
pub use diagnostic::{
    CountDiff, CountWhat, CrochetCode, CrochetLocation, Detail, Diagnostic, Severity, MAX_LISTED,
};
pub use error::CrochetError;
pub use labels::{is_reserved_word, LabelSet, LabelSetId};
pub use limits::{
    CrochetLimits, MAX_DIAGNOSTICS_PER_CODE, MAX_FOUNDATION_CHAINS, MAX_INSTRUCTIONS,
    MAX_INSTRUCTIONS_PER_LAYER, MAX_ITEMS, MAX_ITEMS_PER_LAYER, MAX_LAYERS, MAX_LEGEND_ENTRIES,
    MAX_LEGS, MAX_MARKERS, MAX_N, MAX_NAMED_DEPTH, MAX_REPEAT_DEPTH, MAX_RUN_CHAINS,
    MAX_STEPS_PER_LAYER, MAX_TEXT_BYTES,
};
pub use pattern::{
    ChainPart, Close, CountsAs, CrochetPattern, FirstSide, Instr, Layer, LayerId, LayerKind,
    LegendEntry, LegendId, Op, Part, PartSpec, PieceStart, PosKind, RepeatCount, StartChain,
    StartChainRule, StatedCount, Target, Terms,
};
pub use place::{Anchor, ChainAt, ItemId, PosRef, Side};
pub use resolve::{
    BaseSlot, BaseUse, ChainUses, LayerShape, Made, MadeItem, ResolvedBase, ResolvedLayer,
    ResolvedWindow, SlipMove,
};
pub use stitch::{Basic, Counted, Identity, SlipRole};
pub use validate::{try_resolve, try_resolve_all, validate, validate_with};

/// The version of the rules this engine applies (ADR 0022 sections 5 to 13). The same pattern and
/// the same rules version always give the same output; a change to any rule's result bumps it.
pub const RULES_VERSION: u32 = 1;

/// True until a crocheter has reviewed the conventions (ADR 0022 section 24); while it is, screens
/// and prints label the resolved attachments and counts as awaiting that review.
pub const PRACTITIONER_REVIEW_PENDING: bool = true;
