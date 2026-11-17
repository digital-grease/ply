//! "Ready to make or share" (ADR 0021): one DTO for every craft's readiness report, and the three
//! craft calls behind `api::weave_readiness`, `api::knit_readiness` and `api::nalbind_readiness`.
//! Flat enums only (no freezed rebuild). A new craft adds one call that maps its engine's
//! `ready_to_make` through [`ReadinessDto::from`].

use ply_common::readiness::{Check, Readiness, Verdict};
use ply_weave::feasibility::{check, LoomCheckInput};
use ply_weave::loom::LoomProfile;
use ply_weave::readiness::{LoomCheck, PlanInput};
use ply_weave::Draft;

use crate::dto::{DraftDto, SeverityKind};
use crate::knit_dto::KnitPatternDto;
use crate::loom_dto::{LoomProfileDto, SettDto};
use crate::nalbind_recipe_dto::RecipeDto;
use crate::weave_plan_dto::WeavePlanRequestDto;

/// Which check a readiness item came from (mirrors `ply_common::readiness::Check`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReadinessCheckKind {
    Draft,
    Loom,
    Plan,
    Chart,
    Sections,
    Notation,
    Stitch,
    Recipe,
    Band,
}

/// What an output may do (mirrors `ply_common::readiness::Verdict`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReadinessVerdictKind {
    /// Nothing to ask: produce it.
    Ready,
    /// Warnings or unsupported items to acknowledge in one step first.
    NeedsAcknowledgement,
    /// Errors: never produced as ready; only an explicitly chosen, labelled draft copy.
    NotReady,
}

/// One finding an output must consider.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReadinessItemDto {
    pub check: ReadinessCheckKind,
    /// The engine's stable code (unique within its check).
    pub code: String,
    pub severity: SeverityKind,
    /// Where it is, in words; `None` for the whole document.
    pub place: Option<String>,
    pub message: String,
    pub remediation: Option<String>,
    /// 0 for a finding; for the item that closes a kind past the engine's cap (200 of a kind), how
    /// many findings of that kind it stands for (counted, not listed). Saturates at `u32::MAX`.
    pub omitted: u32,
}

/// A whole readiness report: the verdict, the checks that ran, and every finding (most serious
/// first).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReadinessDto {
    pub verdict: ReadinessVerdictKind,
    pub checked: Vec<ReadinessCheckKind>,
    pub items: Vec<ReadinessItemDto>,
}

impl From<Check> for ReadinessCheckKind {
    fn from(c: Check) -> Self {
        match c {
            Check::Draft => ReadinessCheckKind::Draft,
            Check::Loom => ReadinessCheckKind::Loom,
            Check::Plan => ReadinessCheckKind::Plan,
            Check::Chart => ReadinessCheckKind::Chart,
            Check::Sections => ReadinessCheckKind::Sections,
            Check::Notation => ReadinessCheckKind::Notation,
            Check::Stitch => ReadinessCheckKind::Stitch,
            Check::Recipe => ReadinessCheckKind::Recipe,
            Check::Band => ReadinessCheckKind::Band,
        }
    }
}

impl From<Verdict> for ReadinessVerdictKind {
    fn from(v: Verdict) -> Self {
        match v {
            Verdict::Ready => ReadinessVerdictKind::Ready,
            Verdict::NeedsAcknowledgement => ReadinessVerdictKind::NeedsAcknowledgement,
            Verdict::NotReady => ReadinessVerdictKind::NotReady,
        }
    }
}

impl From<&Readiness> for ReadinessDto {
    fn from(r: &Readiness) -> Self {
        ReadinessDto {
            verdict: r.verdict().into(),
            checked: r.checked.iter().map(|&c| c.into()).collect(),
            items: r
                .items
                .iter()
                .map(|i| ReadinessItemDto {
                    check: i.check.into(),
                    code: i.code.clone(),
                    severity: i.severity.into(),
                    place: i.place.clone(),
                    message: i.message.clone(),
                    remediation: i.remediation.clone(),
                    omitted: u32::try_from(i.omitted).unwrap_or(u32::MAX),
                })
                .collect(),
        }
    }
}

/// A weaving draft: its structure, the loom chosen for it (with the weaver's sett) and its plan.
/// `Err` only when the draft DTO cannot convert; a loom profile or plan Ply cannot use is a finding.
pub fn weave(
    draft: DraftDto,
    loom: Option<LoomProfileDto>,
    sett: Option<SettDto>,
    plan: Option<WeavePlanRequestDto>,
) -> Result<ReadinessDto, String> {
    let draft = Draft::try_from(draft)?;
    let report;
    let why;
    let loom = match loom.map(LoomProfile::from) {
        None => LoomCheck::NotChosen,
        Some(profile) => match profile.problems().into_iter().next() {
            Some(problem) => {
                why = format!("the loom profile is not usable: {problem}");
                LoomCheck::Unusable(&why)
            }
            None => {
                report = check(
                    &draft,
                    &profile,
                    &LoomCheckInput {
                        sett: sett.map(Into::into),
                    },
                );
                LoomCheck::Checked(&report)
            }
        },
    };
    let worked = plan.map(crate::weave_plan_dto::work_out);
    let plan = match &worked {
        None => PlanInput::NotPlanned,
        Some(Ok(worksheet)) => PlanInput::WorkedOut(worksheet),
        Some(Err(why)) => PlanInput::NotWorkedOut(why),
    };
    let readiness = ply_weave::readiness::ready_to_make(&draft, loom, plan);
    Ok(ReadinessDto::from(&readiness))
}

/// A knitting pattern: its chart, its sections and their ledger.
pub fn knit(pattern: KnitPatternDto) -> ReadinessDto {
    let pattern = ply_knit::KnitPattern::from(pattern);
    ReadinessDto::from(&ply_knit::readiness::ready_to_make(&pattern))
}

/// A nalbinding project: its notation (read strictly) and its recipe.
pub fn nalbind(notation: &str, recipe: Option<RecipeDto>) -> ReadinessDto {
    let recipe = recipe.map(ply_nalbind::recipe::Recipe::from);
    ReadinessDto::from(&ply_nalbind::readiness::ready_to_make(
        notation,
        recipe.as_ref(),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::dto::DriveDto;
    use crate::loom_dto::LoomTypeKind;

    /// An 8-shaft straight 4/4 twill, 16 ends by 16 picks.
    fn twill() -> DraftDto {
        use ply_weave::draft::{Drive, Threading, TieUp, TreadleId, Treadling};
        let mut d = Draft::blank(8, 8);
        d.threading = Threading::straight(16, 8);
        d.drive = Drive::Treadled {
            tieup: TieUp::twill(4, 4),
            treadling: Treadling((0..16).map(|i| vec![TreadleId(i % 8 + 1)]).collect()),
        };
        d.colors.warp = vec![0; 16];
        d.colors.weft = vec![1; 16];
        DraftDto::from(&d)
    }

    fn loom(shafts: u16) -> LoomProfileDto {
        LoomProfileDto {
            id: "loom-1".into(),
            name: "Jack loom".into(),
            kind: LoomTypeKind::Jack,
            shafts: Some(shafts),
            treadles: Some(10),
            weaving_width: None,
            reeds: Vec::new(),
            treadles_at_once: None,
            notes: String::new(),
        }
    }

    #[test]
    fn weaving_readiness_crosses_with_its_checks_and_verdict() {
        let clean = weave(twill(), None, None, None).unwrap();
        assert_eq!(clean.verdict, ReadinessVerdictKind::Ready);
        assert_eq!(clean.checked, vec![ReadinessCheckKind::Draft]);

        let small = weave(twill(), Some(loom(4)), None, None).unwrap();
        assert_eq!(small.verdict, ReadinessVerdictKind::NeedsAcknowledgement);
        assert!(small
            .items
            .iter()
            .any(|i| i.check == ReadinessCheckKind::Loom
                && i.code == "loom.shafts_exceeded"
                && i.severity == SeverityKind::Warning));

        let mut broken = twill();
        if let DriveDto::Treadled { treadling, .. } = &mut broken.drive {
            treadling[0] = vec![42];
        }
        let r = weave(broken, None, None, None).unwrap();
        assert_eq!(r.verdict, ReadinessVerdictKind::NotReady);
        assert_eq!(r.items[0].severity, SeverityKind::Error);
        assert_eq!(r.items[0].place.as_deref(), Some("Pick 1, treadle 42"));
    }

    #[test]
    fn a_loom_profile_ply_cannot_use_is_not_checked_not_an_error() {
        let mut bad = loom(4);
        bad.shafts = Some(0);
        let r = weave(twill(), Some(bad), None, None).unwrap();
        assert_eq!(r.verdict, ReadinessVerdictKind::NeedsAcknowledgement);
        let u = r
            .items
            .iter()
            .find(|i| i.code == "loom.profile_unusable")
            .unwrap();
        assert_eq!(u.severity, SeverityKind::Unsupported);
    }

    #[test]
    fn knitting_and_nalbinding_readiness_cross() {
        let blank = crate::api::knit_blank_pattern();
        assert_eq!(knit(blank).verdict, ReadinessVerdictKind::Ready);
        let r = nalbind("UO/XYZ", None);
        assert_eq!(r.verdict, ReadinessVerdictKind::NotReady);
        assert!(r.checked.contains(&ReadinessCheckKind::Notation));
        assert_eq!(
            nalbind("UO/UOO F1", None).verdict,
            ReadinessVerdictKind::Ready
        );
    }
}
