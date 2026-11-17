//! Is a weaving draft ready to make or share (ADR 0021)? One function over everything a printed or
//! shared draft depends on: its structural validation, the loom chosen for it, and its warp, weft and
//! finishing plan. Saving never asks this.
//!
//! What blocks and why:
//!
//! - **Structural errors block**: a dangling shaft, treadle or color, counts of roles, shuttles or
//!   strands that do not match the picks, a malformed shot group. The drawdown and the printed
//!   directions would be wrong. Structural warnings ask; advice is information.
//! - **The loom check never blocks**: a draft for eight shafts is a correct draft that does not fit
//!   a four-shaft loom. A conflict with the chosen loom is a warning naming the loom, advice is
//!   information, a check Ply could not make is unsupported, and a fit is not listed.
//! - **The plan never blocks**: it is about materials and the finished size, not the draft. An
//!   unusable value, a loom or reed conflict, or less yarn on hand than it needs is a warning; an
//!   input not given yet, or a check the plan could not make for lack of optional information (no
//!   reeds or width recorded), is information; a plan Ply could not work out at all is unsupported.
//!   A plan check that says the same as the loom check (the loom's width or reed) is listed once, by
//!   the loom check.
//!
//! The report is bounded (ADR 0021): at most `MAX_ITEMS_PER_KIND` findings of a kind are listed and
//! the rest counted, and user text (a loom or yarn name) is shortened.

use ply_common::readiness::{Check, Readiness, ReadinessBuilder, ReadinessItem, Severity};

use crate::draft::Draft;
use crate::feasibility::{LocationKind, LoomLocation, LoomReport, LoomSeverity};
use crate::validate::{validate, WeaveLocation};
use crate::worksheet::{IssueKind, SupplyRole, Worksheet};

/// The most characters of a loom or yarn name a finding repeats.
const NAME_CHARS: usize = 40;

/// The loom part of a readiness check.
#[derive(Debug, Clone, Copy)]
pub enum LoomCheck<'a> {
    /// No loom is chosen for the draft: nothing to check.
    NotChosen,
    /// The draft checked against the chosen loom.
    Checked(&'a LoomReport),
    /// A loom is chosen but its profile cannot be checked against (it is outside the engine's
    /// limits): why, in words.
    Unusable(&'a str),
}

/// The warp and weft plan part of a readiness check.
#[derive(Debug, Clone, Copy)]
pub enum PlanInput<'a> {
    /// The draft has no plan.
    NotPlanned,
    /// The plan's worksheet.
    WorkedOut(&'a Worksheet),
    /// The draft has a plan Ply could not work out at all (a loom profile outside the engine's
    /// limits): why, in words.
    NotWorkedOut(&'a str),
}

/// Is `draft` ready to make or share? `loom` is the loom chosen for it, `plan` its warp and weft
/// plan.
pub fn ready_to_make(draft: &Draft, loom: LoomCheck<'_>, plan: PlanInput<'_>) -> Readiness {
    let mut r = ReadinessBuilder::new();

    r.ran(Check::Draft);
    for issue in validate(draft) {
        r.push_with(Check::Draft, issue.code.as_str(), issue.severity, || {
            ReadinessItem::new(
                Check::Draft,
                issue.code.as_str(),
                issue.severity,
                match issue.location {
                    WeaveLocation::Draft => None,
                    ref l => Some(l.text()),
                },
                upper_first(&issue.message),
            )
        });
    }

    let mut loom_codes: Vec<&str> = Vec::new();
    match loom {
        LoomCheck::NotChosen => {}
        LoomCheck::Checked(report) => {
            r.ran(Check::Loom);
            let name = shorten(&report.loom_name);
            for d in &report.diagnostics {
                loom_codes.push(d.code.as_str());
                let Some(severity) = loom_severity(d.severity) else {
                    continue;
                };
                r.push(
                    ReadinessItem::new(
                        Check::Loom,
                        d.code.as_str(),
                        severity,
                        d.location.as_ref().map(loom_place),
                        loom_message(&name, severity, &d.message),
                    )
                    .with_remediation(d.remediation.clone()),
                );
            }
        }
        LoomCheck::Unusable(why) => {
            r.push(ReadinessItem::new(
                Check::Loom,
                "loom.profile_unusable",
                Severity::Unsupported,
                None,
                format!(
                    "Ply could not check the draft against the loom chosen for it: {}.",
                    why.trim_end_matches('.')
                ),
            ));
        }
    }

    match plan {
        PlanInput::NotPlanned => {}
        PlanInput::NotWorkedOut(why) => {
            r.push(ReadinessItem::new(
                Check::Plan,
                "plan.not_worked_out",
                Severity::Unsupported,
                None,
                format!(
                    "Ply could not work out the warp and weft plan: {}.",
                    why.trim_end_matches('.')
                ),
            ));
        }
        PlanInput::WorkedOut(w) => {
            r.ran(Check::Plan);
            for issue in &w.issues {
                r.push(ReadinessItem::new(
                    Check::Plan,
                    issue.code,
                    match issue.kind {
                        IssueKind::Invalid => Severity::Warning,
                        IssueKind::Needed => Severity::Info,
                    },
                    plan_place(w, &issue.field),
                    upper_first(&issue.message),
                ));
            }
            for check in &w.checks {
                // The plan checks its own width and reed against the loom too: the loom check's
                // finding of the same kind is listed instead.
                if loom_codes.contains(&loom_counterpart(check.code).as_str()) {
                    continue;
                }
                let severity = match check.severity {
                    LoomSeverity::NotFeasible => Severity::Warning,
                    LoomSeverity::Advice | LoomSeverity::NotChecked => Severity::Info,
                    LoomSeverity::Fits => continue,
                };
                r.push(ReadinessItem::new(
                    Check::Plan,
                    check.code,
                    severity,
                    None,
                    upper_first(&check.message),
                ));
            }
            for line in &w.supply {
                if line.remaining.is_some_and(|left| left.value < 0.0) {
                    r.push(ReadinessItem::new(
                        Check::Plan,
                        "plan.yarn_short",
                        Severity::Warning,
                        Some(format!(
                            "{} yarn, {}",
                            upper_first(supply_noun(line.role)),
                            shorten(&line.material_name)
                        )),
                        upper_first(line.text.trim()),
                    ));
                }
            }
        }
    }

    r.finish()
}

/// The loom check's code for the same finding as plan check `code`: `plan.loom_width_exceeded` is
/// `loom.width_exceeded`, `plan.reed_unknown` is `loom.reed_unknown`.
fn loom_counterpart(code: &str) -> String {
    let rest = code.strip_prefix("plan.").unwrap_or(code);
    format!("loom.{}", rest.strip_prefix("loom_").unwrap_or(rest))
}

/// At most [`NAME_CHARS`] characters of a name, with "..." when cut.
fn shorten(name: &str) -> String {
    ply_common::readiness::bounded(name.trim(), NAME_CHARS)
}

/// A loom-check severity in an output's terms; `None` for a fit (not listed).
fn loom_severity(s: LoomSeverity) -> Option<Severity> {
    match s {
        LoomSeverity::NotFeasible => Some(Severity::Warning),
        LoomSeverity::Advice => Some(Severity::Info),
        LoomSeverity::NotChecked => Some(Severity::Unsupported),
        LoomSeverity::Fits => None,
    }
}

/// A loom finding's sentence for an output. A conflict says it is about the chosen loom, not the
/// draft (the draft may be right for another loom).
fn loom_message(loom: &str, severity: Severity, message: &str) -> String {
    let message = upper_first(message.trim());
    if severity == Severity::Warning {
        format!("Does not fit {loom}, the loom chosen for this draft: {message}")
    } else {
        message
    }
}

/// "Shafts 5 to 8", "Treadle 7", "Picks 3, 4 and 9" for a loom location.
fn loom_place(l: &LoomLocation) -> String {
    let (one, many) = match l.kind {
        LocationKind::Shafts => ("Shaft", "Shafts"),
        LocationKind::Treadles => ("Treadle", "Treadles"),
        LocationKind::Picks => ("Pick", "Picks"),
    };
    let mut parts: Vec<String> = Vec::new();
    let mut i = 0;
    while i < l.numbers.len() {
        let mut j = i;
        while j + 1 < l.numbers.len() && l.numbers[j + 1] == l.numbers[j].saturating_add(1) {
            j += 1;
        }
        if j >= i + 2 {
            parts.push(format!("{} to {}", l.numbers[i], l.numbers[j]));
        } else {
            parts.extend(l.numbers[i..=j].iter().map(u32::to_string));
        }
        i = j + 1;
    }
    let more = l.total.saturating_sub(l.numbers.len());
    if more > 0 {
        parts.push(format!("{more} more"));
    }
    let noun = if l.total == 1 { one } else { many };
    match parts.split_last() {
        Some((last, rest)) if !rest.is_empty() => {
            format!("{noun} {} and {last}", rest.join(", "))
        }
        _ => format!("{noun} {}", parts.join("")),
    }
}

/// The input a plan issue is about, by its label in the worksheet ("Take-up"), when it names one.
fn plan_place(w: &Worksheet, field: &str) -> Option<String> {
    if field.is_empty() {
        return None;
    }
    Some(match w.input(field) {
        Some(input) => format!("Plan, {}", input.label),
        None => format!("Plan, {}", field.replace('_', " ")),
    })
}

fn supply_noun(role: SupplyRole) -> &'static str {
    match role {
        SupplyRole::Warp => "warp",
        SupplyRole::Weft => "weft",
        SupplyRole::WarpAndWeft => "warp and weft",
    }
}

fn upper_first(s: &str) -> String {
    let mut c = s.chars();
    match c.next() {
        Some(f) => f.to_uppercase().collect::<String>() + c.as_str(),
        None => String::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::draft::*;
    use crate::feasibility::{check, LoomCheckInput};
    use crate::loom::LoomProfile;
    use ply_common::readiness::{Verdict, MAX_ITEMS_PER_KIND};

    fn twill(shafts: u16) -> Draft {
        let mut d = Draft::blank(shafts, shafts);
        d.threading = Threading::straight(usize::from(shafts) * 2, shafts);
        d.drive = Drive::Treadled {
            tieup: TieUp::twill(shafts / 2, shafts - shafts / 2),
            treadling: Treadling(
                (0..usize::from(shafts) * 2)
                    .map(|i| vec![TreadleId((i % usize::from(shafts)) as u16 + 1)])
                    .collect(),
            ),
        };
        d.colors.warp = vec![0; usize::from(shafts) * 2];
        d.colors.weft = vec![1; usize::from(shafts) * 2];
        d
    }

    #[test]
    fn a_clean_draft_without_a_loom_or_plan_is_ready() {
        let r = ready_to_make(&twill(4), LoomCheck::NotChosen, PlanInput::NotPlanned);
        assert_eq!(r.verdict(), Verdict::Ready, "{r:?}");
        assert_eq!(r.checked, vec![Check::Draft]);
        assert!(r.items.is_empty());
    }

    #[test]
    fn structural_errors_block_and_carry_their_place() {
        let mut d = twill(4);
        if let Drive::Treadled { treadling, .. } = &mut d.drive {
            treadling.0[2] = vec![TreadleId(9)];
        }
        let r = ready_to_make(&d, LoomCheck::NotChosen, PlanInput::NotPlanned);
        assert_eq!(r.verdict(), Verdict::NotReady);
        let e = r.with_severity(Severity::Error).next().unwrap();
        assert_eq!(
            (e.check, e.code.as_str()),
            (Check::Draft, "weave.treadle_untied")
        );
        assert_eq!(e.place.as_deref(), Some("Pick 3, treadle 9"));
        assert_eq!(e.message, "Pick 3 presses treadle 9 which has no tie-up");
        // The blocking set is exactly the validator's errors (what the PDF's problems box lists).
        let errors = validate(&d)
            .into_iter()
            .filter(|i| i.severity == Severity::Error)
            .count();
        assert_eq!(r.count(Severity::Error), errors as u64);
    }

    #[test]
    fn a_loom_conflict_warns_and_names_the_loom_but_never_blocks() {
        let d = twill(8);
        let mut loom = LoomProfile::new("table", "Table loom");
        loom.shafts = Some(4);
        let report = check(&d, &loom, &LoomCheckInput::default());
        let r = ready_to_make(&d, LoomCheck::Checked(&report), PlanInput::NotPlanned);
        assert_eq!(r.verdict(), Verdict::NeedsAcknowledgement, "{r:?}");
        assert_eq!(r.checked, vec![Check::Draft, Check::Loom]);
        let w = r.with_severity(Severity::Warning).next().unwrap();
        assert_eq!(w.check, Check::Loom);
        assert_eq!(w.code, "loom.shafts_exceeded");
        assert!(
            w.message
                .starts_with("Does not fit Table loom, the loom chosen for this draft: "),
            "{}",
            w.message
        );
        assert!(r.with_severity(Severity::Error).next().is_none());
        // What the profile does not record is not checked: listed as unsupported, never guessed.
        assert!(r
            .items
            .iter()
            .any(|i| i.check == Check::Loom && i.severity == Severity::Unsupported));
        // A fit is not listed.
        let mut roomy = LoomProfile::new("floor", "Floor loom");
        roomy.shafts = Some(8);
        roomy.treadles = Some(10);
        let fits = check(&d, &roomy, &LoomCheckInput::default());
        let r = ready_to_make(&d, LoomCheck::Checked(&fits), PlanInput::NotPlanned);
        assert!(r.items.iter().all(|i| !i.code.ends_with("_fit")), "{r:?}");
    }

    #[test]
    fn an_unusable_profile_is_listed_as_not_checked() {
        let r = ready_to_make(
            &twill(4),
            LoomCheck::Unusable("a shaft count of 0 is not possible"),
            PlanInput::NotPlanned,
        );
        assert_eq!(r.verdict(), Verdict::NeedsAcknowledgement);
        let u = &r.items[0];
        assert_eq!((u.check, u.severity), (Check::Loom, Severity::Unsupported));
        assert_eq!(
            u.message,
            "Ply could not check the draft against the loom chosen for it: a shaft count of 0 is \
             not possible."
        );
    }

    #[test]
    fn loom_places_read_naturally() {
        let at = |kind, numbers: Vec<u32>, total| {
            loom_place(&LoomLocation {
                kind,
                numbers,
                total,
            })
        };
        assert_eq!(
            at(LocationKind::Shafts, vec![5, 6, 7, 8], 4),
            "Shafts 5 to 8"
        );
        assert_eq!(at(LocationKind::Treadles, vec![7], 1), "Treadle 7");
        assert_eq!(
            at(LocationKind::Picks, vec![3, 4, 9], 3),
            "Picks 3, 4 and 9"
        );
        assert_eq!(
            at(LocationKind::Picks, vec![1, 2], 30),
            "Picks 1, 2 and 28 more"
        );
    }

    #[test]
    fn the_plan_warns_or_informs_and_never_blocks() {
        use crate::worksheet::{PlanCheck, PlanIssue, SupplyLine};
        use ply_common::quantity::{Length, LengthUnit};
        let line = |remaining: f64| SupplyLine {
            role: SupplyRole::Warp,
            material_id: "m1".into(),
            material_name: "8/2 cotton".into(),
            need: Length::new(10.0, LengthUnit::Yard),
            need_mass: None,
            on_hand: Some(Length::new(10.0 + remaining, LengthUnit::Yard)),
            on_hand_about: false,
            remaining: Some(Length::new(remaining, LengthUnit::Yard)),
            text: "10 yd of warp. About 2 yd short.".into(),
            working: Vec::new(),
            uses: Vec::new(),
            assumed: false,
        };
        let w = Worksheet {
            metric: false,
            inputs: Vec::new(),
            figures: Vec::new(),
            denting: None,
            checks: vec![
                PlanCheck {
                    code: "plan.loom_width_exceeded",
                    severity: LoomSeverity::NotFeasible,
                    message: "the warp is wider than the loom".into(),
                },
                PlanCheck {
                    code: "plan.reed_fits",
                    severity: LoomSeverity::Fits,
                    message: "fits".into(),
                },
                PlanCheck {
                    code: "plan.reed_unknown",
                    severity: LoomSeverity::NotChecked,
                    message: "no reeds are recorded".into(),
                },
            ],
            supply: vec![line(-2.0), line(3.0)],
            issues: vec![
                PlanIssue {
                    code: "plan.needs_sett",
                    kind: IssueKind::Needed,
                    field: "sett".into(),
                    message: "give the sett".into(),
                },
                PlanIssue {
                    code: "plan.out_of_range",
                    kind: IssueKind::Invalid,
                    field: "take_up".into(),
                    message: "take-up must be under 100%".into(),
                },
            ],
            input_notes: Vec::new(),
            notes: Vec::new(),
        };
        let r = ready_to_make(&twill(4), LoomCheck::NotChosen, PlanInput::WorkedOut(&w));
        assert_eq!(r.verdict(), Verdict::NeedsAcknowledgement);
        assert_eq!(r.checked, vec![Check::Draft, Check::Plan]);
        // Warnings, then information; within one severity, kinds in the order first found. A
        // check the plan could not make for lack of optional information (no reeds recorded) is
        // information, never a question.
        assert_eq!(
            r.codes(),
            vec![
                (Check::Plan, "plan.out_of_range"),
                (Check::Plan, "plan.loom_width_exceeded"),
                (Check::Plan, "plan.yarn_short"),
                (Check::Plan, "plan.needs_sett"),
                (Check::Plan, "plan.reed_unknown"),
            ]
        );
        // Only information: the plan never asks for lack of optional information.
        let quiet = Worksheet {
            checks: vec![PlanCheck {
                code: "plan.reed_unknown",
                severity: LoomSeverity::NotChecked,
                message: "no reeds are recorded".into(),
            }],
            supply: Vec::new(),
            issues: Vec::new(),
            ..w.clone()
        };
        let quiet_report = ready_to_make(
            &twill(4),
            LoomCheck::NotChosen,
            PlanInput::WorkedOut(&quiet),
        );
        assert_eq!(quiet_report.verdict(), Verdict::Ready);

        // With a loom chosen, a plan check that says what the loom check says is listed once.
        let mut loom = LoomProfile::new("small", "Small loom");
        loom.shafts = Some(4);
        loom.treadles = Some(4);
        let report = check(&twill(4), &loom, &LoomCheckInput::default());
        assert!(
            report.codes().contains(&"loom.reed_unknown"),
            "{:?}",
            report.codes()
        );
        let with_loom = ready_to_make(
            &twill(4),
            LoomCheck::Checked(&report),
            PlanInput::WorkedOut(&quiet),
        );
        let reed: Vec<_> = with_loom
            .codes()
            .into_iter()
            .filter(|(_, c)| c.ends_with("reed_unknown"))
            .collect();
        assert_eq!(reed, vec![(Check::Loom, "loom.reed_unknown")]);
        assert_eq!(
            loom_counterpart("plan.loom_width_exceeded"),
            "loom.width_exceeded"
        );
        assert_eq!(loom_counterpart("plan.reed_unknown"), "loom.reed_unknown");
        let short = r
            .items
            .iter()
            .find(|i| i.code == "plan.yarn_short")
            .unwrap();
        assert_eq!(short.place.as_deref(), Some("Warp yarn, 8/2 cotton"));
        let range = &r.items[0];
        assert_eq!(range.place.as_deref(), Some("Plan, take up"));
        assert_eq!(range.message, "Take-up must be under 100%");
    }

    #[test]
    fn a_plan_ply_could_not_work_out_is_listed_as_not_checked() {
        let r = ready_to_make(
            &twill(4),
            LoomCheck::NotChosen,
            PlanInput::NotWorkedOut("the loom profile cannot be planned with: no shafts."),
        );
        assert_eq!(r.verdict(), Verdict::NeedsAcknowledgement);
        assert_eq!(r.codes(), vec![(Check::Plan, "plan.not_worked_out")]);
        assert_eq!(
            r.items[0].message,
            "Ply could not work out the warp and weft plan: the loom profile cannot be planned \
             with: no shafts."
        );
    }

    #[test]
    fn a_hostile_draft_gives_a_bounded_report_that_counts_every_finding() {
        // 30,000 ends threaded on a shaft the draft does not have, each with a missing color, and
        // as many picks pressing a treadle with no tie-up: every finding counted, 200 of each kind
        // listed, and a long loom name shortened.
        let n = 30_000;
        let mut d = Draft::blank(4, 4);
        d.threading = Threading((0..n).map(|_| vec![ShaftId(9)]).collect());
        d.colors.warp = vec![7; n];
        d.drive = Drive::Treadled {
            tieup: TieUp(vec![vec![ShaftId(1)]; 4]),
            treadling: Treadling((0..n).map(|_| vec![TreadleId(99)]).collect()),
        };
        d.colors.weft = vec![7; n];
        let mut loom = LoomProfile::new("long", "L".repeat(1_000));
        loom.shafts = Some(2);
        let report = check(&d, &loom, &LoomCheckInput::default());
        let r = ready_to_make(&d, LoomCheck::Checked(&report), PlanInput::NotPlanned);
        assert_eq!(r.count(Severity::Error), 4 * n as u64);
        let listed = r.with_severity(Severity::Error).count();
        assert_eq!(
            listed,
            4 * (MAX_ITEMS_PER_KIND + 1),
            "200 and one count per kind"
        );
        assert!(r.items.len() < 4 * (MAX_ITEMS_PER_KIND + 1) + 20);
        // The loom's long name is bounded wherever it is repeated.
        for i in r.items.iter().filter(|i| i.check == Check::Loom) {
            assert!(
                i.message.chars().count() <= ply_common::readiness::MAX_MESSAGE_CHARS + 3,
                "{}",
                i.message.len()
            );
        }
    }
}
