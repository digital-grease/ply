//! `ply-nalbind` — the nalbinding (nålbinding) engine. M6 v1 covers a stitch REFERENCE: a model of a
//! stitch type around Hansen notation, a round-trippable notation parser/printer, a curated builtin
//! stitch dictionary, a per-stitch structural loop diagram, and validation. No project/recipe model
//! and no gauge calculator yet (gauge is unstable in this craft); see `docs/NALBIND_DESIGN.md`.
//!
//! FFI-free and Flutter-free, like its sibling engines. The frb DTOs live only in `ply-bridge`.

pub mod diagram;
pub mod dictionary;
pub mod error;
pub mod notation;
pub mod stitch;
pub mod validate;

pub use diagram::{diagram, Diagram};
pub use dictionary::builtin;
pub use error::NalbindError;
pub use stitch::{ConnSide, Connection, Pass, PublishedCode, StitchType, Step, Twist};
pub use validate::{validate, NalbindIssue, Severity};
