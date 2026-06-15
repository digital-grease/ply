//! Ply FFI bridge for Flutter, via flutter_rust_bridge.
//!
//! This is the ONLY crate that depends on `flutter_rust_bridge`. It keeps the engine
//! crates (`ply-weave`, `ply-common`) FFI-free and reusable. After editing `api.rs`,
//! regenerate the Dart bindings with:
//!
//! ```text
//! flutter_rust_bridge_codegen generate
//! ```
//!
//! (frb v2 also emits a `frb_generated.rs` here during codegen; it is git-ignored and
//! recreated by the command above, so it is intentionally not checked in.)

pub mod api;
pub mod dto;
pub mod knit_dto;

// frb emits this (git-ignored). It MUST sit below the crate's `//!` inner docs — frb's
// codegen injects it at the very top by default, which makes the inner doc comments
// illegal (E0753). frb detects this existing line on re-runs and won't re-inject.
mod frb_generated;
