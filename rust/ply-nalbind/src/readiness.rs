//! Is a nalbinding project ready to make or share (ADR 0021)? One function over everything a printed
//! or shared project depends on: its notation, the stitch it reads as, and its recipe. Saving never
//! asks this.
//!
//! What blocks and why:
//!
//! - **The project's notation is authored strictly** (ADR 0003): every finding the strict reader
//!   refuses is an error, exactly as the project screen shows it; formatting notes are information.
//! - **The stitch's own errors block, its warnings ask** (checked only when the notation reads
//!   exactly; otherwise the notation's errors already say why).
//! - **The recipe's errors block, its warnings ask, its notes inform**; a free-text step is
//!   unsupported: Ply does not read it, so nothing in it is checked.

use ply_common::readiness::{Check, Readiness, ReadinessBuilder, ReadinessItem, Severity};

use crate::notation::{parse_strict, NotationDiagnostic, NotationSeverity};
use crate::recipe::{check, place_of, Recipe, SegmentKind};
use crate::stitch::StitchType;
use crate::validate::{validate, NalbindLocation};

/// The code of a free-text recipe step, which Ply does not read.
pub const FREE_TEXT_STEP: &str = "free-text-step";

/// The most characters of a notation quoted in a place.
const QUOTED_CHARS: usize = 40;

/// Is the project with stitch `notation` (as typed; it is trimmed, as a save stores it) and
/// `recipe` ready to make or share?
pub fn ready_to_make(notation: &str, recipe: Option<&Recipe>) -> Readiness {
    let mut r = ReadinessBuilder::new();
    let notation = notation.trim();
    if !notation.is_empty() {
        r.ran(Check::Notation);
        match parse_strict(notation) {
            Ok(parsed) => {
                for d in &parsed.diagnostics {
                    push_notation(&mut r, notation, d);
                }
                r.ran(Check::Stitch);
                let stitch = StitchType::anonymous(parsed.passes, parsed.connections);
                for issue in validate(&stitch) {
                    r.push_with(Check::Stitch, issue.code, issue.severity, || {
                        ReadinessItem::new(
                            Check::Stitch,
                            issue.code,
                            issue.severity,
                            match issue.location {
                                NalbindLocation::Stitch => None,
                                l => Some(l.text()),
                            },
                            upper_first(&issue.message),
                        )
                    });
                }
            }
            Err(rejection) => {
                for d in &rejection.diagnostics {
                    push_notation(&mut r, notation, d);
                }
            }
        }
    }
    if let Some(recipe) = recipe {
        r.ran(Check::Recipe);
        let report = check(recipe, notation);
        for issue in &report.issues {
            let severity = issue.severity.level();
            r.push_with(Check::Recipe, issue.code.as_str(), severity, || {
                // The check writes `<place>: <message>` for an issue at a step or a fit measurement.
                let place = issue
                    .text
                    .strip_suffix(issue.message.as_str())
                    .and_then(|p| p.strip_suffix(": "))
                    .map(str::to_string);
                ReadinessItem::new(
                    Check::Recipe,
                    issue.code.as_str(),
                    severity,
                    place,
                    upper_first(&issue.message),
                )
            });
        }
        for s in report
            .segments
            .iter()
            .filter(|s| !s.checked && s.kind == SegmentKind::Freeform)
        {
            let Some(segment) = recipe.segments.get(s.index) else {
                continue;
            };
            r.push_with(Check::Recipe, FREE_TEXT_STEP, Severity::Unsupported, || {
                ReadinessItem::new(
                    Check::Recipe,
                    FREE_TEXT_STEP,
                    Severity::Unsupported,
                    Some(place_of(segment, s.index)),
                    "Ply did not check this step: it is free text, which Ply does not read, and it \
                     is printed as written.",
                )
            });
        }
    }
    r.finish()
}

/// One finding of the strict reading: information stays information, everything else is an error
/// (strict mode refuses it). Placed by the text it quotes.
fn push_notation(r: &mut ReadinessBuilder, notation: &str, d: &NotationDiagnostic) {
    let severity = match d.severity {
        NotationSeverity::Info => Severity::Info,
        _ => Severity::Error,
    };
    r.push_with(Check::Notation, d.code.as_str(), severity, || {
        let quoted = d.span.text(notation).trim();
        ReadinessItem::new(
            Check::Notation,
            d.code.as_str(),
            severity,
            Some(if quoted.is_empty() {
                "Notation".to_string()
            } else {
                format!("Notation, at \"{}\"", excerpt(quoted, QUOTED_CHARS))
            }),
            upper_first(&d.message),
        )
    });
}

/// The lenient reading's verdict on `notation` (for tests: the strict one must agree on what it
/// refuses).
#[cfg(test)]
fn lenient_problems(notation: &str) -> usize {
    crate::notation::parse_lenient(notation)
        .diagnostics
        .iter()
        .filter(|d| d.severity > NotationSeverity::Info)
        .count()
}

fn upper_first(s: &str) -> String {
    let mut c = s.chars();
    match c.next() {
        Some(f) => f.to_uppercase().collect::<String>() + c.as_str(),
        None => String::new(),
    }
}

fn excerpt(text: &str, max: usize) -> String {
    let mut chars = text.chars();
    let mut out: String = chars.by_ref().take(max).collect();
    if chars.next().is_some() {
        out.push_str("...");
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use ply_common::readiness::Verdict;

    #[test]
    fn a_clean_notation_without_a_recipe_is_ready() {
        let r = ready_to_make("  UO/UOO F1  ", None);
        assert_eq!(r.verdict(), Verdict::Ready, "{r:?}");
        assert_eq!(r.checked, vec![Check::Notation, Check::Stitch]);
        // A project with no stitch and no recipe has nothing to check, and nothing blocks.
        let empty = ready_to_make("", None);
        assert!(empty.checked.is_empty() && empty.items.is_empty());
    }

    #[test]
    fn every_finding_the_strict_reader_refuses_blocks_and_quotes_its_text() {
        let r = ready_to_make("UO/XYZ", None);
        assert_eq!(r.verdict(), Verdict::NotReady);
        let e = r
            .items
            .iter()
            .find(|i| i.code == "unexpected-character")
            .expect("the uninterpretable XYZ");
        assert_eq!((e.check, e.severity), (Check::Notation, Severity::Error));
        assert_eq!(e.place.as_deref(), Some("Notation, at \"XYZ\""));
        // A lenient warning (here a skip group inside another) is refused in strict mode too.
        let nested = ready_to_make("U((U))O F1", None);
        assert_eq!(
            nested.count(Severity::Error),
            lenient_problems("U((U))O F1") as u64
        );
        assert!(nested.count(Severity::Error) > 0);
        assert!(
            !nested.checked.contains(&Check::Stitch),
            "not exact: no stitch check"
        );
    }

    #[test]
    fn formatting_notes_inform_and_never_ask() {
        let r = ready_to_make("uo/uoo f1", None);
        assert_eq!(r.verdict(), Verdict::Ready, "{r:?}");
        assert!(r.items.iter().all(|i| i.severity == Severity::Info));
        assert!(!r.items.is_empty());
    }

    #[test]
    fn a_free_text_step_is_listed_as_not_checked() {
        let recipe: Recipe = serde_json::from_str(
            r#"{"segments":[
                {"id":"segment-1","title":"Start","work":{"kind":"foundationChain","stitches":30,"join":"ring"}},
                {"id":"segment-2","title":"Fancy edge","work":{"kind":"freeform","role":"finish","text":"work a decorative edge"}}
            ]}"#,
        )
        .expect("a recipe");
        let r = ready_to_make("UO/UOO F1", Some(&recipe));
        assert!(r.checked.contains(&Check::Recipe));
        let u: Vec<&ReadinessItem> = r.with_severity(Severity::Unsupported).collect();
        assert_eq!(u.len(), 1, "{r:?}");
        assert_eq!(u[0].code, FREE_TEXT_STEP);
        assert_eq!(u[0].place.as_deref(), Some("Step 2 (Fancy edge)"));
        assert_eq!(r.verdict(), Verdict::NeedsAcknowledgement);
    }

    #[test]
    fn a_long_notation_of_junk_gives_a_bounded_report() {
        let junk = "UO/U(X ".repeat(20_000);
        let r = ready_to_make(&junk, None);
        assert_eq!(r.verdict(), Verdict::NotReady);
        assert!(r.count(Severity::Error) > 20_000);
        // A few kinds of finding, 200 of each at most, plus one count each.
        assert!(r.items.len() <= 6 * (ply_common::readiness::MAX_ITEMS_PER_KIND + 1));
        assert!(r
            .items
            .iter()
            .all(|i| i.message.chars().count() <= ply_common::readiness::MAX_MESSAGE_CHARS + 3));
    }
}
