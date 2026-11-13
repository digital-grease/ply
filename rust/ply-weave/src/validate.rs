//! Structural validation of a draft. Cheap enough to run on every edit so the editor
//! can surface problems live (shafts out of range, color counts that don't line up,
//! treadles with no tie-up, etc.).

use crate::draft::{Draft, Drive, PickRole, TabbyRule};
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
                    format!(
                        "warp end {} uses shaft {} outside 1..={}",
                        i + 1,
                        s.0,
                        draft.shafts
                    ),
                );
            }
        }
    }

    // Color plan lengths line up with geometry.
    if draft.colors.warp.len() != draft.ends() {
        push(
            &mut issues,
            Severity::Warning,
            format!(
                "warp color count ({}) != warp ends ({})",
                draft.colors.warp.len(),
                draft.ends()
            ),
        );
    }
    if draft.colors.weft.len() != draft.picks() {
        push(
            &mut issues,
            Severity::Warning,
            format!(
                "weft color count ({}) != picks ({})",
                draft.colors.weft.len(),
                draft.picks()
            ),
        );
    }

    // Drive-specific checks.
    match &draft.drive {
        Drive::Treadled { tieup, treadling } => {
            if tieup.treadles() as u16 != draft.treadles {
                push(
                    &mut issues,
                    Severity::Warning,
                    format!(
                        "tie-up has {} treadles, header says {}",
                        tieup.treadles(),
                        draft.treadles
                    ),
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
                            format!(
                                "treadle {} ties shaft {} outside 1..={}",
                                t + 1,
                                s.0,
                                draft.shafts
                            ),
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
                            format!(
                                "liftplan pick {} raises shaft {} outside 1..={}",
                                p + 1,
                                s.0,
                                draft.shafts
                            ),
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
                format!(
                    "warp end {} uses color {} outside palette 0..{}",
                    i + 1,
                    idx,
                    palette_len
                ),
            );
        }
    }
    for (p, &idx) in draft.colors.weft.iter().enumerate() {
        if idx >= palette_len {
            push(
                &mut issues,
                Severity::Error,
                format!(
                    "pick {} uses color {} outside palette 0..{}",
                    p + 1,
                    idx,
                    palette_len
                ),
            );
        }
    }

    // Pick roles (M8-06): when recorded they are length-coupled to the picks (empty = all unknown).
    // A length mismatch means some role names no pick, or some pick lost its role: an Error.
    if !draft.pick_roles.is_empty() && draft.pick_roles.len() != draft.picks() {
        push(
            &mut issues,
            Severity::Error,
            format!(
                "pick role count ({}) != picks ({})",
                draft.pick_roles.len(),
                draft.picks()
            ),
        );
    }
    // A pick marked tabby should weave plain weave; one that does not is legal but suspicious (a
    // wrong role, or a threading/tie-up edit that broke the ground). One summarizing Warning.
    let tabby = TabbyRule::new(&draft.threading);
    let off_tabby: Vec<usize> = (0..draft.picks())
        .filter(|&p| {
            draft.pick_role(p) == PickRole::Tabby && tabby.phase(&draft.raised_shafts(p)).is_none()
        })
        .collect();
    if !off_tabby.is_empty() {
        let (noun, verb) = if off_tabby.len() == 1 {
            ("pick", "its shed does")
        } else {
            ("picks", "their sheds do")
        };
        push(
            &mut issues,
            Severity::Warning,
            format!(
                "{noun} {} marked tabby but {verb} not weave plain weave",
                pick_list(&off_tabby)
            ),
        );
    }

    // A shaft that is THREADED but never RAISED by any pick floats the whole cloth length on the
    // back. Every such shaft is in range, so nothing above catches it, yet the cloth is structurally
    // broken — e.g. a satin whose move number shares a factor with the shaft count. `raised_shafts`
    // already honors shed direction. Advisory (a deliberate warp-float is rare but legal), and only
    // meaningful once the cloth has picks.
    if draft.picks() > 0 {
        use std::collections::BTreeSet;
        let raised: BTreeSet<u16> = (0..draft.picks())
            .flat_map(|p| draft.raised_shafts(p))
            .map(|s| s.0)
            .collect();
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

/// "4", "4 and 6", "4, 6 and 8", or "4, 6, 8, 10, 12 and 3 more" for 0-based picks (shown 1-based),
/// so a message about many picks stays one short line.
fn pick_list(picks: &[usize]) -> String {
    const SHOWN: usize = 5;
    let nums: Vec<String> = picks
        .iter()
        .take(SHOWN)
        .map(|p| (p + 1).to_string())
        .collect();
    if picks.len() > SHOWN {
        return format!("{} and {} more", nums.join(", "), picks.len() - SHOWN);
    }
    match nums.split_last() {
        Some((last, rest)) if !rest.is_empty() => format!("{} and {last}", rest.join(", ")),
        _ => nums.join(""),
    }
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
                treadling: Treadling(
                    (0..8)
                        .map(|i| vec![TreadleId((i % 8) as u16 + 1)])
                        .collect(),
                ),
            },
            colors: ColorPlan {
                palette: vec![ply_common::Color::WHITE, ply_common::Color::BLACK],
                warp: vec![0; 8],
                weft: vec![1; 8],
            },
            warp_thickness: Vec::new(),
            weft_thickness: Vec::new(),
            notes: String::new(),
            retained: Vec::new(),
            pick_roles: Vec::new(),
        };
        let issues = validate(&d);
        assert!(
            issues.iter().all(|i| i.severity != Severity::Error),
            "no Errors: {issues:?}"
        );
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

    /// Overshot-style 4-shaft draft with a pattern shed (treadle 1) and two tabby sheds (3 and 4).
    fn roles_draft(treadling: &[u16], roles: Vec<PickRole>) -> Draft {
        let mut d = Draft::blank(4, 4);
        d.threading = Threading(
            [1, 2, 1, 2, 3, 4, 3, 4]
                .iter()
                .map(|&s| vec![ShaftId(s)])
                .collect(),
        );
        d.colors.warp = vec![0; 8];
        d.drive = Drive::Treadled {
            tieup: TieUp(vec![
                vec![ShaftId(1), ShaftId(2)],
                vec![ShaftId(3), ShaftId(4)],
                vec![ShaftId(1), ShaftId(3)],
                vec![ShaftId(2), ShaftId(4)],
            ]),
            treadling: Treadling(treadling.iter().map(|&t| vec![TreadleId(t)]).collect()),
        };
        d.colors.weft = vec![0; treadling.len()];
        d.pick_roles = roles;
        d
    }

    #[test]
    fn pick_role_count_mismatch_is_an_error() {
        use PickRole::*;
        let d = roles_draft(&[1, 3, 1], vec![Pattern, Tabby]);
        assert!(
            validate(&d).iter().any(|i| i.severity == Severity::Error
                && i.message == "pick role count (2) != picks (3)"),
            "{:?}",
            validate(&d)
        );
        // Empty (no roles recorded) is never a mismatch, and an aligned list is clean.
        assert!(validate(&roles_draft(&[1, 3, 2], vec![])).is_empty());
        assert!(validate(&roles_draft(&[1, 3, 2], vec![Pattern, Tabby, Pattern])).is_empty());
    }

    #[test]
    fn a_tabby_pick_off_the_tabby_sheds_is_one_warning() {
        use PickRole::*;
        // Pick 3 (treadle 1, a pattern shed) is marked tabby.
        let d = roles_draft(&[1, 3, 1, 4], vec![Pattern, Tabby, Tabby, Tabby]);
        let issues = validate(&d);
        assert_eq!(
            issues,
            vec![ValidationIssue {
                severity: Severity::Warning,
                message: "pick 3 marked tabby but its shed does not weave plain weave".into(),
            }]
        );
        // Several are summarized in one line.
        let many = roles_draft(&[1, 1, 1, 2, 2, 2, 1], vec![Tabby; 7]);
        let warns: Vec<_> = validate(&many)
            .into_iter()
            .filter(|i| i.message.contains("marked tabby"))
            .collect();
        assert_eq!(warns.len(), 1);
        assert_eq!(
            warns[0].message,
            "picks 1, 2, 3, 4, 5 and 2 more marked tabby but their sheds do not weave plain weave"
        );
        // Pattern picks on any shed are fine.
        assert!(validate(&roles_draft(&[3, 4], vec![Pattern, Pattern])).is_empty());
    }

    #[test]
    fn pick_list_reads_naturally() {
        assert_eq!(pick_list(&[3]), "4");
        assert_eq!(pick_list(&[3, 5]), "4 and 6");
        assert_eq!(pick_list(&[3, 5, 7]), "4, 6 and 8");
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
            validate(&d)
                .iter()
                .any(|i| i.severity == Severity::Error
                    && i.message.contains("treadle 1 ties shaft 5")),
            "expected a tie-up shaft-range Error, got {:?}",
            validate(&d)
        );
    }
}
