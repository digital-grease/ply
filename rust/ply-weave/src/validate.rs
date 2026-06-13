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
            // Tie-up shafts within range. A dangling tie (shaft > header) renders white silently
            // (like a dangling threading shaft), so surface it as an Error.
            for (t, shafts) in tieup.0.iter().enumerate() {
                for s in shafts {
                    if s.0 == 0 || s.0 > draft.shafts {
                        push(
                            &mut issues,
                            Severity::Error,
                            format!("treadle {} ties shaft {} outside 1..={}", t + 1, s.0, draft.shafts),
                        );
                    }
                }
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

    // A shaft that is THREADED but never RAISED by any pick floats the whole cloth length on the
    // back. Every such shaft is in range, so nothing above catches it, yet the cloth is structurally
    // broken — e.g. a satin whose move number shares a factor with the shaft count. `raised_shafts`
    // already honors shed direction. Advisory (a deliberate warp-float is rare but legal), and only
    // meaningful once the cloth has picks.
    if draft.picks() > 0 {
        use std::collections::BTreeSet;
        let raised: BTreeSet<u16> =
            (0..draft.picks()).flat_map(|p| draft.raised_shafts(p)).map(|s| s.0).collect();
        let mut warned: BTreeSet<u16> = BTreeSet::new();
        for shafts in draft.threading.0.iter() {
            for s in shafts {
                if s.0 >= 1 && s.0 <= draft.shafts && !raised.contains(&s.0) && warned.insert(s.0) {
                    push(
                        &mut issues,
                        Severity::Warning,
                        format!(
                            "shaft {} is threaded but never raised — its warp ends float the whole length",
                            s.0
                        ),
                    );
                }
            }
        }
    }

    issues
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::draft::*;

    /// A degenerate satin (counter shares a factor with shafts) threads shafts it never raises;
    /// validate() must WARN (the cloth renders "valid" but floats on the back).
    #[test]
    fn warns_on_threaded_but_never_raised_shaft() {
        let d = Draft {
            name: String::new(),
            shafts: 8,
            treadles: 8,
            shed: ShedType::Rising,
            unit: ply_common::Unit::Inches,
            threading: Threading::straight(8, 8),
            drive: Drive::Treadled {
                tieup: TieUp::satin(8, 2), // raises only shafts 1,3,5,7
                treadling: Treadling((0..8).map(|i| vec![TreadleId((i % 8) as u16 + 1)]).collect()),
            },
            colors: ColorPlan {
                palette: vec![ply_common::Color::WHITE, ply_common::Color::BLACK],
                warp: vec![0; 8],
                weft: vec![1; 8],
            },
            notes: String::new(),
            retained: Vec::new(),
        };
        let issues = validate(&d);
        assert!(issues.iter().all(|i| i.severity != Severity::Error), "no Errors: {issues:?}");
        let warns = issues
            .iter()
            .filter(|i| i.severity == Severity::Warning && i.message.contains("never raised"))
            .count();
        assert_eq!(warns, 4, "shafts 2,4,6,8 each warn once: {issues:?}");
    }

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

    #[test]
    fn flags_dangling_tieup_shaft() {
        // A tie-up referencing a shaft beyond the header renders white silently; validate() must
        // surface it as an Error (the blind spot a resize-prune regression would otherwise hide).
        let mut d = Draft::blank(2, 2);
        if let Drive::Treadled { tieup, .. } = &mut d.drive {
            tieup.0[0] = vec![ShaftId(5)]; // treadle 1 ties shaft 5 of a 2-shaft draft
        }
        assert!(
            validate(&d).iter().any(|i| i.severity == Severity::Error
                && i.message.contains("treadle 1 ties shaft 5")),
            "expected a tie-up shaft-range Error, got {:?}",
            validate(&d)
        );
    }
}
