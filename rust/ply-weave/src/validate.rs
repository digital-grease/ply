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

    // Color references point at an existing palette entry. A dangling index is NOT a panic —
    // `render_rgba` silently substitutes white (`palette.get(idx).unwrap_or(WHITE)`) — so the
    // editor cannot otherwise tell the cloth is mis-rendering. Surface it as an Error.
    let palette_len = draft.colors.palette.len();
    for (i, &idx) in draft.colors.warp.iter().enumerate() {
        if idx >= palette_len {
            push(
                &mut issues,
                Severity::Error,
                format!("warp end {} uses color {} outside palette 0..{}", i + 1, idx, palette_len),
            );
        }
    }
    for (p, &idx) in draft.colors.weft.iter().enumerate() {
        if idx >= palette_len {
            push(
                &mut issues,
                Severity::Error,
                format!("pick {} uses color {} outside palette 0..{}", p + 1, idx, palette_len),
            );
        }
    }

    issues
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::draft::*;

    #[test]
    fn flags_dangling_color_index() {
        let mut d = Draft::blank(2, 2);
        d.threading = Threading(vec![vec![ShaftId(1)]]); // 1 end so warp-count matches
        d.colors.warp = vec![5]; // palette has 2 colors -> index 5 dangles
        let issues = validate(&d);
        assert!(
            issues
                .iter()
                .any(|i| i.severity == Severity::Error && i.message.contains("color")),
            "expected a color-range Error, got {issues:?}"
        );
        // The clamp helper resolves it.
        d.colors.clamp_to_palette();
        assert!(
            validate(&d)
                .iter()
                .all(|i| !(i.severity == Severity::Error && i.message.contains("color"))),
            "color error should be gone after clamp"
        );
    }
}
