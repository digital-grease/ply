//! Structural validation of a draft. Cheap enough to run on every edit so the editor
//! can surface problems live (shafts out of range, color counts that don't line up,
//! treadles with no tie-up, etc.).

use crate::draft::{Drive, Draft};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Severity {
    Error,
    Warning,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ValidationIssue {
    pub severity: Severity,
    pub message: String,
}

/// Run structural sanity checks. Empty result = clean.
pub fn validate(draft: &Draft) -> Vec<ValidationIssue> {
    let mut issues: Vec<ValidationIssue> = Vec::new();
    let push = |issues: &mut Vec<ValidationIssue>, severity: Severity, message: String| {
        issues.push(ValidationIssue { severity, message });
    };

    // Threading references shafts within range.
    for (i, shafts) in draft.threading.0.iter().enumerate() {
        for s in shafts {
            if s.0 == 0 || s.0 > draft.shafts {
                push(
                    &mut issues,
                    Severity::Error,
                    format!("warp end {} uses shaft {} outside 1..={}", i + 1, s.0, draft.shafts),
                );
            }
        }
    }

    // Color plan lengths line up with geometry.
    if draft.colors.warp.len() != draft.ends() {
        push(
            &mut issues,
            Severity::Warning,
            format!("warp color count ({}) != warp ends ({})", draft.colors.warp.len(), draft.ends()),
        );
    }
    if draft.colors.weft.len() != draft.picks() {
        push(
            &mut issues,
            Severity::Warning,
            format!("weft color count ({}) != picks ({})", draft.colors.weft.len(), draft.picks()),
        );
    }

    // Drive-specific checks.
    match &draft.drive {
        Drive::Treadled { tieup, treadling } => {
            if tieup.treadles() as u16 != draft.treadles {
                push(
                    &mut issues,
                    Severity::Warning,
                    format!("tie-up has {} treadles, header says {}", tieup.treadles(), draft.treadles),
                );
            }
            for (p, treadles) in treadling.0.iter().enumerate() {
                for t in treadles {
                    if t.0 == 0 || t.0 as usize > tieup.treadles() {
                        push(
                            &mut issues,
                            Severity::Error,
                            format!("pick {} presses treadle {} which has no tie-up", p + 1, t.0),
                        );
                    }
                }
            }
        }
        Drive::Liftplan(lp) => {
            for (p, shafts) in lp.0.iter().enumerate() {
                for s in shafts {
                    if s.0 == 0 || s.0 > draft.shafts {
                        push(
                            &mut issues,
                            Severity::Error,
                            format!("liftplan pick {} raises shaft {} outside 1..={}", p + 1, s.0, draft.shafts),
                        );
                    }
                }
            }
        }
    }

    issues
}
