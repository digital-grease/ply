//! `ply-nalbind` — the nalbinding (nålbinding) engine. M6 v1 covers a stitch REFERENCE: a model of a
//! stitch type around Hansen notation, a round-trippable notation parser/printer, a curated builtin
//! stitch dictionary, a per-stitch structural loop diagram, and validation. M8-04 adds structured
//! RECIPES (`recipe`): ordered start, body, shaping and finish segments with checks that say what Ply
//! verified (notation, order, references, counts) and what it only records (ADR 0017). No gauge
//! calculator (gauge is unstable in this craft); see `docs/NALBIND_DESIGN.md`.
//!
//! FFI-free and Flutter-free, like its sibling engines. The frb DTOs live only in `ply-bridge`.

pub mod diagram;
pub mod dictionary;
pub mod error;
// The version a `.plynal` file states, read without decoding the project (the app owns the file).
pub mod native;
pub mod notation;
pub mod recipe;
// Is a project ready to make or share (ADR 0021)?
pub mod readiness;
pub mod stitch;
pub mod validate;

pub use diagram::{diagram, Diagram};
pub use dictionary::builtin;
pub use error::NalbindError;
pub use notation::{
    parse_lenient, parse_strict, DiagnosticCode, Fidelity, NotationDiagnostic, NotationSeverity,
    ParseMode, ParsedNotation, StrictRejection,
};
pub use stitch::{ConnSide, Connection, Pass, PublishedCode, Step, StitchType, Twist};
pub use validate::{validate, NalbindIssue, NalbindLocation, Severity};
