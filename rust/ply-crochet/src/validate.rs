//! The entry points: [`validate()`] lists every diagnostic of a pattern, [`try_resolve`] resolves a
//! window of its layers (ADR 0022 section 20).
//!
//! Both start with the structural check. When it finds a refusing error, `validate` lists the
//! check's findings and `try_resolve` refuses with its errors. Otherwise the piece is resolved layer
//! by layer and `validate` adds what resolving found: impossible anchors, repeats that do not fit,
//! counts that differ, bases not used up, opaque items, passed positions and ridges. A size limit
//! passed while resolving refuses in the same way. Neither reads a label set: the same pattern gives
//! the same output for every viewer.

use crate::check::check;
use crate::diagnostic::{Collector, Detail, Diagnostic, Severity};
use crate::error::CrochetError;
use crate::limits::CrochetLimits;
use crate::pattern::CrochetPattern;
use crate::resolve::{resolve_piece, ResolvedWindow};
use std::ops::RangeInclusive;

/// Validate with the default limits.
pub fn validate(p: &CrochetPattern) -> Vec<Diagnostic> {
    validate_with(p, &CrochetLimits::DEFAULT)
}

/// Every diagnostic of a pattern: errors first, then warnings, unsupported items and information,
/// each code at most `limits.max_diagnostics_per_code` times (the rest counted in one
/// `crochet.list_capped`).
pub fn validate_with(p: &CrochetPattern, limits: &CrochetLimits) -> Vec<Diagnostic> {
    // One collector for the structural check and the resolution: every finding is counted per code
    // when it is made, and only the listed ones are built.
    let mut out = Collector::new(limits.max_diagnostics_per_code);
    let chk = check(p, limits, &mut out);
    if chk.refused() {
        return out.finish();
    }
    // A size limit passed while resolving refuses like the structural check: the resolution's other
    // findings are dropped and the too_large is listed with the check's own findings.
    let before = out.counts();
    if let Err(d) = resolve_piece(&chk, limits, Some((0, 0)), &mut out) {
        out.restore(&before);
        out.push(*d);
    }
    out.finish()
}

/// Resolve layers `layers` (1-based, inclusive) with every layer before them folded in. Memory is
/// bounded by the widest layer plus the window's items.
pub fn try_resolve(
    p: &CrochetPattern,
    layers: RangeInclusive<u32>,
    limits: &CrochetLimits,
) -> Result<ResolvedWindow, CrochetError> {
    let (first, last) = (*layers.start(), *layers.end());
    let count = u32::try_from(p.layers.len()).unwrap_or(u32::MAX);
    if first == 0 || first > last || last > count {
        return Err(CrochetError::InvalidWindow {
            first,
            last,
            layers: count,
        });
    }
    resolve_window(p, Some((first, last)), limits)
}

/// Resolve every layer. A piece with no layers gives an empty window (`first` 1, `last` 0).
pub fn try_resolve_all(
    p: &CrochetPattern,
    limits: &CrochetLimits,
) -> Result<ResolvedWindow, CrochetError> {
    resolve_window(p, None, limits)
}

fn resolve_window(
    p: &CrochetPattern,
    keep: Option<(u32, u32)>,
    limits: &CrochetLimits,
) -> Result<ResolvedWindow, CrochetError> {
    let mut out = Collector::new(limits.max_diagnostics_per_code);
    let chk = check(p, limits, &mut out);
    if chk.refused() {
        // Only the errors (and, for an error code past the cap, the note counting the rest).
        let errors = out
            .finish()
            .into_iter()
            .filter(|d| match d.detail {
                Detail::Omitted { code, .. } => code.severity() == Severity::Error,
                _ => d.severity == Severity::Error,
            })
            .collect();
        return Err(CrochetError::Invalid(errors));
    }
    // Nobody reads the resolution's diagnostics here, so none are built.
    let mut off = Collector::off();
    let r =
        resolve_piece(&chk, limits, keep, &mut off).map_err(|d| CrochetError::Invalid(vec![*d]))?;
    let (first, last) = keep.unwrap_or((1, p.layers.len() as u32));
    Ok(ResolvedWindow {
        first,
        last,
        layers: r.layers,
    })
}
