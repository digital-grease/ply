//! Is a knitting pattern ready to make or share (ADR 0021)? One function over everything a printed or
//! shared pattern depends on: its chart, its sections and their stitch ledger. Saving never asks this.
//!
//! What blocks and why:
//!
//! - **Chart and ledger errors block**: a stitch the legend lacks, a cable that does not fit, a
//!   repeat that cannot be worked, a row that does not take what the row below left, a step the
//!   needle cannot do. The written instructions and the stitch counts would be wrong.
//! - **Warnings ask**: a to-end repeat Ply cannot count without a cast-on, an unchecked step that
//!   does not say how it changes the count.
//! - **A step in the pattern's own words is unsupported**: Ply prints it as written and says it did
//!   not check it, one item per step.
//!
//! The report is bounded (ADR 0021): at most `MAX_ITEMS_PER_KIND` findings of a kind are listed and
//! the rest counted, a section's title is shortened as the ledger's messages shorten it, and a step's
//! own words are quoted in part.

use std::collections::{HashMap, HashSet};

use ply_common::readiness::{Check, Readiness, ReadinessBuilder, ReadinessItem, Severity};

use crate::pattern::KnitPattern;
use crate::sections;
use crate::validate::{validate, KnitLocation};

/// The code of a step in the pattern's own words, which Ply does not check.
pub const UNCHECKED_STEP: &str = "unchecked-step";

/// The most characters of an unchecked step's own words quoted in its readiness item.
const QUOTED_CHARS: usize = 60;

/// Is `pattern` ready to make or share?
pub fn ready_to_make(pattern: &KnitPattern) -> Readiness {
    let mut r = ReadinessBuilder::new();
    r.ran(Check::Chart);
    if !pattern.sections.is_empty() {
        r.ran(Check::Sections);
    }
    for issue in validate(pattern) {
        let check = match issue.location {
            KnitLocation::Step { .. } => Check::Sections,
            KnitLocation::Pattern if !pattern.sections.is_empty() && issue.code == "sections" => {
                Check::Sections
            }
            _ => Check::Chart,
        };
        r.push_with(check, issue.code, issue.severity, || {
            let place = match issue.location {
                KnitLocation::Pattern => None,
                ref l => Some(l.text()),
            };
            // A ledger finding's message starts with its place (`Back, step 3: ...`); the item
            // carries the place on its own, so the sentence is the finding alone.
            let message = match (&issue.location, &place) {
                (KnitLocation::Step { .. }, Some(at)) => issue
                    .message
                    .strip_prefix(at.as_str())
                    .and_then(|rest| rest.strip_prefix(": "))
                    .unwrap_or(&issue.message),
                _ => issue.message.as_str(),
            };
            ReadinessItem::new(
                check,
                issue.code,
                issue.severity,
                place,
                upper_first(message),
            )
        });
    }
    if !pattern.sections.is_empty() {
        let ledger = sections::ledger(pattern);
        let mut seen: HashSet<(usize, usize)> = HashSet::new();
        // Each section's title once, shortened as the ledger's messages shorten it.
        let mut titles: HashMap<usize, String> = HashMap::new();
        for line in ledger.lines.iter().filter(|l| l.opaque) {
            if !seen.insert((line.section, line.step)) {
                continue;
            }
            r.push_with(
                Check::Sections,
                UNCHECKED_STEP,
                Severity::Unsupported,
                || {
                    let title = titles.entry(line.section).or_insert_with(|| {
                        sections::short(
                            &sections::section_title(pattern, line.section),
                            sections::SECTION_IN_MESSAGE_CHARS,
                        )
                    });
                    ReadinessItem::new(
                        Check::Sections,
                        UNCHECKED_STEP,
                        Severity::Unsupported,
                        Some(format!("{title}, step {}", line.step + 1)),
                        format!(
                        "Ply did not check this step: it is in the pattern's own words (\"{}\") \
                         and is printed as written.",
                        excerpt(line.text.trim(), QUOTED_CHARS)
                    ),
                    )
                },
            );
        }
    }
    r.finish()
}

fn upper_first(s: &str) -> String {
    let mut c = s.chars();
    match c.next() {
        Some(f) => f.to_uppercase().collect::<String>() + c.as_str(),
        None => String::new(),
    }
}

/// At most `max` characters of `text`, with "..." when cut.
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
    use crate::pattern::*;
    use crate::sections::{Section, Step, StepAction};
    use ply_common::readiness::Verdict;
    use ply_common::{Color, Unit};

    fn pattern(rows: Vec<Row>, cast_on: Option<u32>) -> KnitPattern {
        KnitPattern {
            name: "t".into(),
            construction: Construction::Flat,
            first_row_side: Side::Rs,
            cast_on,
            gauge: Gauge {
                sts: 20.0,
                rows: 28.0,
                unit: Unit::Inches,
            },
            palette: vec![Color::WHITE],
            legend: StitchLegend::builtin(),
            chart: Chart {
                width: rows.first().map_or(0, |r| r.cells.len()),
                rows,
            },
            notes: String::new(),
            sections: Vec::new(),
            pieces: Vec::new(),
        }
    }

    fn knit_row(n: usize) -> Row {
        Row::plain(vec![Cell::of(builtin::KNIT); n])
    }

    #[test]
    fn a_balanced_chart_is_ready() {
        let r = ready_to_make(&pattern(vec![knit_row(4), knit_row(4)], Some(4)));
        assert_eq!(r.verdict(), Verdict::Ready, "{r:?}");
        assert_eq!(r.checked, vec![Check::Chart]);
    }

    #[test]
    fn a_count_mismatch_blocks_with_its_row() {
        let r = ready_to_make(&pattern(vec![knit_row(4), knit_row(4)], Some(6)));
        assert_eq!(r.verdict(), Verdict::NotReady);
        let e = &r.items[0];
        assert_eq!(
            (e.check, e.code.as_str()),
            (Check::Chart, "cast-on-mismatch")
        );
        assert_eq!(e.place.as_deref(), Some("Row 1"));
        assert_eq!(e.message, "Row 1 consumes 4 stitches but the cast-on is 6");
        // The blocking set is exactly validation's errors (what the PDF's problems box lists).
        let p = pattern(vec![knit_row(4), knit_row(4)], Some(6));
        let errors = validate(&p)
            .iter()
            .filter(|i| i.severity == Severity::Error)
            .count();
        assert_eq!(r.count(Severity::Error), errors as u64);
    }

    #[test]
    fn an_unknown_to_end_count_asks() {
        let row = Row {
            cells: vec![Cell::of(builtin::KNIT); 6],
            repeats: vec![RepeatSpan {
                start: 1,
                end: 5,
                count: Repeat::ToEnd,
            }],
        };
        let r = ready_to_make(&pattern(vec![row], None));
        assert_eq!(r.verdict(), Verdict::NeedsAcknowledgement);
        assert_eq!(r.items[0].code, "repeat-to-end-unknown-count");
        assert_eq!(
            r.items[0].place.as_deref(),
            Some("Row 1, chart columns 2 to 5")
        );
    }

    #[test]
    fn a_step_in_the_patterns_own_words_is_listed_as_not_checked() {
        let mut p = pattern(vec![], Some(20));
        p.sections = vec![Section {
            id: "s1".into(),
            name: "Back".into(),
            notes: String::new(),
            construction: None,
            piece: None,
            steps: vec![
                Step {
                    id: "t1".into(),
                    action: StepAction::Opaque {
                        text: "work the cable panel as set".into(),
                        stitch_change: Some(0),
                    },
                },
                Step {
                    id: "t2".into(),
                    action: StepAction::Opaque {
                        text: "block the piece".into(),
                        stitch_change: Some(0),
                    },
                },
            ],
        }];
        let r = ready_to_make(&p);
        assert_eq!(r.checked, vec![Check::Chart, Check::Sections]);
        let unsupported: Vec<&ReadinessItem> = r.with_severity(Severity::Unsupported).collect();
        assert_eq!(unsupported.len(), 2, "{r:?}");
        assert_eq!(unsupported[0].code, UNCHECKED_STEP);
        assert_eq!(unsupported[0].place.as_deref(), Some("Back, step 1"));
        assert!(unsupported[0]
            .message
            .contains("(\"work the cable panel as set\")"));
        assert_eq!(r.verdict(), Verdict::NeedsAcknowledgement);
    }

    #[test]
    fn many_unchecked_steps_under_a_long_title_give_a_bounded_report() {
        // 10,000 steps in the pattern's own words under a 10,000-character section title: every
        // step is counted, 200 are listed, and no place repeats the whole title.
        let mut p = pattern(vec![], Some(20));
        p.sections = vec![Section {
            id: "s1".into(),
            name: "N".repeat(10_000),
            notes: String::new(),
            construction: None,
            piece: None,
            steps: (0..10_000)
                .map(|i| Step {
                    id: format!("t{i}"),
                    action: StepAction::Opaque {
                        text: "work as set ".repeat(100),
                        stitch_change: Some(0),
                    },
                })
                .collect(),
        }];
        let r = ready_to_make(&p);
        assert_eq!(r.count(Severity::Unsupported), 10_000);
        let listed: Vec<&ReadinessItem> = r.with_severity(Severity::Unsupported).collect();
        assert_eq!(listed.len(), ply_common::readiness::MAX_ITEMS_PER_KIND + 1);
        let bytes: usize = r
            .items
            .iter()
            .map(|i| i.place.as_ref().map_or(0, String::len) + i.message.len())
            .sum();
        assert!(bytes < 100_000, "{bytes} bytes of text");
        assert!(listed[0].place.as_ref().unwrap().len() < 80);
        assert_eq!(listed.last().unwrap().omitted, 10_000 - 200);
    }
}
