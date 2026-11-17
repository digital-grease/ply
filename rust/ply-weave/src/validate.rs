//! Structural validation of a draft. Cheap enough to run on every edit so the editor
//! can surface problems live (shafts out of range, color counts that don't line up,
//! treadles with no tie-up, etc.).
//!
//! Every finding carries a stable [`WeaveCode`] and a typed [`WeaveLocation`] in the weaver's 1-based
//! numbers (ADR 0021), beside the sentence the editor shows; tests and navigation key on the code and
//! the location, never on the words.

use crate::draft::{Draft, Drive, PickRole, ShotGroup, TabbyRule, MAX_SHUTTLES, MAX_STRANDS};

/// The severity vocabulary every craft shares (ADR 0021). Weaving validation reports errors,
/// warnings and information; it has nothing it cannot check.
pub use ply_common::readiness::Severity;

/// Every structural finding's stable code. The string form ([`WeaveCode::as_str`]) never changes once
/// released.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum WeaveCode {
    /// A warp end is threaded on a shaft outside the draft's shafts.
    ThreadingShaft,
    /// The warp color list does not have one color per end.
    WarpColorCount,
    /// The weft color list does not have one color per pick.
    WeftColorCount,
    /// The tie-up has a different number of treadles than the draft's header.
    TreadleCount,
    /// A treadle is tied to a shaft outside the draft's shafts.
    TieUpShaft,
    /// A pick presses a treadle that has no tie-up.
    TreadleUntied,
    /// A lift plan pick raises a shaft outside the draft's shafts.
    LiftPlanShaft,
    /// A warp end's color is not in the palette.
    WarpColorRef,
    /// A pick's color is not in the palette.
    WeftColorRef,
    /// The pick roles do not have one role per pick.
    PickRoleCount,
    /// Picks marked tabby whose sheds do not weave plain weave.
    TabbyOffShed,
    /// The pick shuttles do not have one entry per pick.
    ShuttleCount,
    /// The strands per pick do not have one entry per pick.
    StrandCount,
    /// A pick names a shuttle outside 1..=8.
    ShuttleRange,
    /// A starting side is given for a shuttle outside 1..=8.
    ShuttleStartRange,
    /// A pick carries a number of strands outside 1..=4.
    StrandRange,
    /// A shot group of fewer than two picks.
    ShotGroupShort,
    /// A shot group that reaches past the last pick.
    ShotGroupPastEnd,
    /// Two shot groups that share picks.
    ShotGroupOverlap,
    /// A shot group whose picks are not all one shed.
    ShotGroupMixedSheds,
    /// One shuttle passes twice in one shed without a shot group.
    UngroupedSameShed,
    /// Advice: a grouped return pass needs the weft caught at the selvedge.
    ShotGroupCatch,
    /// A declared double-weave construction the derived edges do not bear out.
    Construction,
    /// A shaft that is threaded but never raised.
    ShaftNeverRaised,
}

impl WeaveCode {
    /// Every code.
    pub const ALL: [WeaveCode; 24] = [
        WeaveCode::ThreadingShaft,
        WeaveCode::WarpColorCount,
        WeaveCode::WeftColorCount,
        WeaveCode::TreadleCount,
        WeaveCode::TieUpShaft,
        WeaveCode::TreadleUntied,
        WeaveCode::LiftPlanShaft,
        WeaveCode::WarpColorRef,
        WeaveCode::WeftColorRef,
        WeaveCode::PickRoleCount,
        WeaveCode::TabbyOffShed,
        WeaveCode::ShuttleCount,
        WeaveCode::StrandCount,
        WeaveCode::ShuttleRange,
        WeaveCode::ShuttleStartRange,
        WeaveCode::StrandRange,
        WeaveCode::ShotGroupShort,
        WeaveCode::ShotGroupPastEnd,
        WeaveCode::ShotGroupOverlap,
        WeaveCode::ShotGroupMixedSheds,
        WeaveCode::UngroupedSameShed,
        WeaveCode::ShotGroupCatch,
        WeaveCode::Construction,
        WeaveCode::ShaftNeverRaised,
    ];

    /// The stable string, e.g. `weave.treadle_untied`.
    pub const fn as_str(self) -> &'static str {
        match self {
            WeaveCode::ThreadingShaft => "weave.threading_shaft",
            WeaveCode::WarpColorCount => "weave.warp_color_count",
            WeaveCode::WeftColorCount => "weave.weft_color_count",
            WeaveCode::TreadleCount => "weave.treadle_count",
            WeaveCode::TieUpShaft => "weave.tieup_shaft",
            WeaveCode::TreadleUntied => "weave.treadle_untied",
            WeaveCode::LiftPlanShaft => "weave.liftplan_shaft",
            WeaveCode::WarpColorRef => "weave.warp_color_ref",
            WeaveCode::WeftColorRef => "weave.weft_color_ref",
            WeaveCode::PickRoleCount => "weave.pick_role_count",
            WeaveCode::TabbyOffShed => "weave.tabby_off_shed",
            WeaveCode::ShuttleCount => "weave.shuttle_count",
            WeaveCode::StrandCount => "weave.strand_count",
            WeaveCode::ShuttleRange => "weave.shuttle_range",
            WeaveCode::ShuttleStartRange => "weave.shuttle_start_range",
            WeaveCode::StrandRange => "weave.strand_range",
            WeaveCode::ShotGroupShort => "weave.shot_group_short",
            WeaveCode::ShotGroupPastEnd => "weave.shot_group_past_end",
            WeaveCode::ShotGroupOverlap => "weave.shot_group_overlap",
            WeaveCode::ShotGroupMixedSheds => "weave.shot_group_mixed_sheds",
            WeaveCode::UngroupedSameShed => "weave.ungrouped_same_shed",
            WeaveCode::ShotGroupCatch => "weave.shot_group_catch",
            WeaveCode::Construction => "weave.construction",
            WeaveCode::ShaftNeverRaised => "weave.shaft_never_raised",
        }
    }

    /// The code for a stable string, if any (the inverse of [`WeaveCode::as_str`]).
    pub fn parse(s: &str) -> Option<WeaveCode> {
        WeaveCode::ALL.into_iter().find(|c| c.as_str() == s)
    }
}

/// The most picks a [`WeaveLocation::PickList`] or ranges a [`WeaveLocation::PickRanges`] lists (its
/// `total` still counts them all).
pub const MAX_LOCATION_PICKS: usize = 24;

/// Where a structural finding applies, in the weaver's 1-based numbers: end 1, pick 1, shaft 1,
/// treadle 1. A palette color is its 0-based index in the palette (as the messages name it).
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum WeaveLocation {
    /// The draft as a whole (a count that does not match, a construction).
    Draft,
    /// A threading cell: warp `end` on `shaft`.
    Threading { end: u32, shaft: u32 },
    /// A tie-up cell: `treadle` tied to `shaft`.
    TieUp { treadle: u32, shaft: u32 },
    /// A treadling cell: `pick` presses `treadle`.
    Treadling { pick: u32, treadle: u32 },
    /// A lift plan cell: `pick` raises `shaft`.
    LiftPlan { pick: u32, shaft: u32 },
    /// Warp `end`'s color, which names palette index `color`.
    WarpColor { end: u32, color: u32 },
    /// `pick`'s weft color, which names palette index `color`.
    WeftColor { pick: u32, color: u32 },
    /// One pick.
    Pick { pick: u32 },
    /// The picks `first..=last`.
    Picks { first: u32, last: u32 },
    /// Several picks, ascending (at most [`MAX_LOCATION_PICKS`] listed; `total` in all).
    PickList { picks: Vec<u32>, total: u32 },
    /// Several ranges of picks `(first, last)`, ascending (at most [`MAX_LOCATION_PICKS`] listed;
    /// `total` in all).
    PickRanges { ranges: Vec<(u32, u32)>, total: u32 },
    /// One shaft.
    Shaft { shaft: u32 },
    /// One shuttle.
    Shuttle { shuttle: u32 },
}

impl WeaveLocation {
    /// The place in words, for a list beside the message: "Pick 3, treadle 9", "Tie-up, treadle 1,
    /// shaft 5", "Picks 4 to 6", "Whole draft".
    pub fn text(&self) -> String {
        match self {
            WeaveLocation::Draft => "Whole draft".to_string(),
            WeaveLocation::Threading { end, shaft } => format!("End {end}, shaft {shaft}"),
            WeaveLocation::TieUp { treadle, shaft } => {
                format!("Tie-up, treadle {treadle}, shaft {shaft}")
            }
            WeaveLocation::Treadling { pick, treadle } => format!("Pick {pick}, treadle {treadle}"),
            WeaveLocation::LiftPlan { pick, shaft } => format!("Pick {pick}, shaft {shaft}"),
            WeaveLocation::WarpColor { end, .. } => format!("End {end}, color"),
            WeaveLocation::WeftColor { pick, .. } => format!("Pick {pick}, color"),
            WeaveLocation::Pick { pick } => format!("Pick {pick}"),
            WeaveLocation::Picks { first, last } => upper_first(&picks_range(
                (*first as usize).saturating_sub(1),
                *last as usize,
            )),
            WeaveLocation::PickList { picks, total } => {
                // As the messages list them: five numbers, then "and n more" of the total.
                const SHOWN: usize = 5;
                let nums: Vec<String> = picks.iter().take(SHOWN).map(u32::to_string).collect();
                let more = (*total as usize).saturating_sub(nums.len());
                let words = if more > 0 {
                    format!("{} and {more} more", nums.join(", "))
                } else {
                    and_join(&nums)
                };
                format!("{} {words}", if *total == 1 { "Pick" } else { "Picks" })
            }
            WeaveLocation::PickRanges { ranges, total } => {
                // As the messages list them: three ranges, then "and n more" of the total.
                const SHOWN: usize = 3;
                let parts: Vec<String> = ranges
                    .iter()
                    .take(SHOWN)
                    .map(|&(a, b)| picks_range((a as usize).saturating_sub(1), b as usize))
                    .collect();
                let more = (*total as usize).saturating_sub(parts.len());
                let words = if more > 0 {
                    format!("{} and {more} more", parts.join(", "))
                } else {
                    and_join(&parts)
                };
                upper_first(&words)
            }
            WeaveLocation::Shaft { shaft } => format!("Shaft {shaft}"),
            WeaveLocation::Shuttle { shuttle } => format!("Shuttle {shuttle}"),
        }
    }

    /// The first pick the location names, if it names one (for a view to scroll to).
    pub fn first_pick(&self) -> Option<u32> {
        match self {
            WeaveLocation::Treadling { pick, .. }
            | WeaveLocation::LiftPlan { pick, .. }
            | WeaveLocation::WeftColor { pick, .. }
            | WeaveLocation::Pick { pick } => Some(*pick),
            WeaveLocation::Picks { first, .. } => Some(*first),
            WeaveLocation::PickList { picks, .. } => picks.first().copied(),
            WeaveLocation::PickRanges { ranges, .. } => ranges.first().map(|r| r.0),
            _ => None,
        }
    }

    /// The last pick of a contiguous range the location names, if it names one.
    pub fn last_pick(&self) -> Option<u32> {
        match self {
            WeaveLocation::Picks { last, .. } => Some(*last),
            WeaveLocation::PickRanges { ranges, .. } => ranges.first().map(|r| r.1),
            _ => self.first_pick(),
        }
    }
}

/// One structural finding.
#[derive(Debug, Clone, PartialEq)]
pub struct ValidationIssue {
    pub code: WeaveCode,
    pub severity: Severity,
    pub location: WeaveLocation,
    /// The finding as the editor shows it (unchanged wording; the place is also in [`Self::location`]).
    pub message: String,
}

impl ValidationIssue {
    fn new(code: WeaveCode, severity: Severity, location: WeaveLocation, message: String) -> Self {
        ValidationIssue {
            code,
            severity,
            location,
            message,
        }
    }
}

/// `n` (an index or a count) as a 1-based location number, saturating rather than wrapping.
fn num(n: usize) -> u32 {
    u32::try_from(n).unwrap_or(u32::MAX)
}

/// `n + 1` for a 0-based index, saturating.
fn one_based(n: usize) -> u32 {
    num(n.saturating_add(1))
}

/// 0-based picks as a capped [`WeaveLocation::PickList`].
fn pick_list_location(picks: &[usize]) -> WeaveLocation {
    WeaveLocation::PickList {
        picks: picks
            .iter()
            .take(MAX_LOCATION_PICKS)
            .map(|&p| one_based(p))
            .collect(),
        total: num(picks.len()),
    }
}

/// 0-based inclusive runs as a capped [`WeaveLocation::PickRanges`].
fn pick_ranges_location(runs: &[(usize, usize)]) -> WeaveLocation {
    if let [(a, b)] = runs {
        return WeaveLocation::Picks {
            first: one_based(*a),
            last: one_based(*b),
        };
    }
    WeaveLocation::PickRanges {
        ranges: runs
            .iter()
            .take(MAX_LOCATION_PICKS)
            .map(|&(a, b)| (one_based(a), one_based(b)))
            .collect(),
        total: num(runs.len()),
    }
}

/// The distinct ids of one list that are not `valid`, in first-seen order.
fn bad_ids(ids: impl Iterator<Item = u16>, valid: impl Fn(u16) -> bool) -> Vec<u16> {
    distinct(ids.filter(|&id| !valid(id))).collect()
}

/// "shaft 9", "shafts 9 and 12", "shafts 9, 10, 11, 12, 13 and 1,019 more" for distinct `ids`.
fn id_words(one: &str, many: &str, ids: &[u16]) -> String {
    const SHOWN: usize = 5;
    if let [id] = ids {
        return format!("{one} {id}");
    }
    let nums: Vec<String> = ids.iter().take(SHOWN).map(u16::to_string).collect();
    let more = ids.len().saturating_sub(SHOWN);
    if more > 0 {
        format!("{many} {} and {more} more", nums.join(", "))
    } else {
        format!("{many} {}", and_join(&nums))
    }
}

/// The ids of one list, each once, in first-seen order. A short list (every real one) is checked in
/// place; a long one through a set, so a hostile list never costs more than linear time.
fn distinct(ids: impl Iterator<Item = u16>) -> impl Iterator<Item = u16> {
    const SMALL: usize = 16;
    let mut small: Vec<u16> = Vec::new();
    let mut large: std::collections::HashSet<u16> = std::collections::HashSet::new();
    ids.filter(move |&id| {
        if large.is_empty() {
            if small.contains(&id) {
                return false;
            }
            if small.len() < SMALL {
                small.push(id);
                return true;
            }
            large.extend(small.drain(..));
        }
        large.insert(id)
    })
}

/// "a", "a and b", "a, b and c".
fn and_join(parts: &[String]) -> String {
    match parts.split_last() {
        Some((last, rest)) if !rest.is_empty() => format!("{} and {last}", rest.join(", ")),
        _ => parts.join(""),
    }
}

fn upper_first(s: &str) -> String {
    let mut c = s.chars();
    match c.next() {
        Some(f) => f.to_uppercase().collect::<String>() + c.as_str(),
        None => String::new(),
    }
}

/// Run structural sanity checks. Empty result = clean.
pub fn validate(draft: &Draft) -> Vec<ValidationIssue> {
    let mut issues: Vec<ValidationIssue> = Vec::new();
    let push = |issues: &mut Vec<ValidationIssue>,
                code: WeaveCode,
                severity: Severity,
                location: WeaveLocation,
                message: String| {
        issues.push(ValidationIssue::new(code, severity, location, message));
    };

    // Threading references shafts within range. Every distinct shaft outside the draft is named
    // once, in ONE finding per end however long a hostile list is, so validation stays linear in
    // the draft's ends and picks (ADR 0021).
    for (i, shafts) in draft.threading.0.iter().enumerate() {
        let bad = bad_ids(shafts.iter().map(|s| s.0), |s| s >= 1 && s <= draft.shafts);
        if let Some(&first) = bad.first() {
            push(
                &mut issues,
                WeaveCode::ThreadingShaft,
                Severity::Error,
                WeaveLocation::Threading {
                    end: one_based(i),
                    shaft: u32::from(first),
                },
                format!(
                    "warp end {} uses {} outside 1..={}",
                    i + 1,
                    id_words("shaft", "shafts", &bad),
                    draft.shafts
                ),
            );
        }
    }

    // Color plan lengths line up with geometry.
    if draft.colors.warp.len() != draft.ends() {
        push(
            &mut issues,
            WeaveCode::WarpColorCount,
            Severity::Warning,
            WeaveLocation::Draft,
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
            WeaveCode::WeftColorCount,
            Severity::Warning,
            WeaveLocation::Draft,
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
                    WeaveCode::TreadleCount,
                    Severity::Warning,
                    WeaveLocation::Draft,
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
                let bad = bad_ids(shafts.iter().map(|s| s.0), |s| s >= 1 && s <= draft.shafts);
                if let Some(&first) = bad.first() {
                    push(
                        &mut issues,
                        WeaveCode::TieUpShaft,
                        Severity::Error,
                        WeaveLocation::TieUp {
                            treadle: one_based(t),
                            shaft: u32::from(first),
                        },
                        format!(
                            "treadle {} ties {} outside 1..={}",
                            t + 1,
                            id_words("shaft", "shafts", &bad),
                            draft.shafts
                        ),
                    );
                }
            }
            for (p, treadles) in treadling.0.iter().enumerate() {
                let bad = bad_ids(treadles.iter().map(|t| t.0), |t| {
                    t >= 1 && usize::from(t) <= tieup.treadles()
                });
                if let Some(&first) = bad.first() {
                    push(
                        &mut issues,
                        WeaveCode::TreadleUntied,
                        Severity::Error,
                        WeaveLocation::Treadling {
                            pick: one_based(p),
                            treadle: u32::from(first),
                        },
                        format!(
                            "pick {} presses {} which {} no tie-up",
                            p + 1,
                            id_words("treadle", "treadles", &bad),
                            if bad.len() == 1 { "has" } else { "have" }
                        ),
                    );
                }
            }
        }
        Drive::Liftplan(lp) => {
            for (p, shafts) in lp.0.iter().enumerate() {
                let bad = bad_ids(shafts.iter().map(|s| s.0), |s| s >= 1 && s <= draft.shafts);
                if let Some(&first) = bad.first() {
                    push(
                        &mut issues,
                        WeaveCode::LiftPlanShaft,
                        Severity::Error,
                        WeaveLocation::LiftPlan {
                            pick: one_based(p),
                            shaft: u32::from(first),
                        },
                        format!(
                            "liftplan pick {} raises {} outside 1..={}",
                            p + 1,
                            id_words("shaft", "shafts", &bad),
                            draft.shafts
                        ),
                    );
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
                WeaveCode::WarpColorRef,
                Severity::Error,
                WeaveLocation::WarpColor {
                    end: one_based(i),
                    color: num(idx),
                },
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
                WeaveCode::WeftColorRef,
                Severity::Error,
                WeaveLocation::WeftColor {
                    pick: one_based(p),
                    color: num(idx),
                },
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
            WeaveCode::PickRoleCount,
            Severity::Error,
            WeaveLocation::Draft,
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
            WeaveCode::TabbyOffShed,
            Severity::Warning,
            if let [p] = off_tabby[..] {
                WeaveLocation::Pick { pick: one_based(p) }
            } else {
                pick_list_location(&off_tabby)
            },
            format!(
                "{noun} {} marked tabby but {verb} not weave plain weave",
                pick_list(&off_tabby)
            ),
        );
    }

    weft_work_issues(draft, &mut issues);

    // A declared double-weave construction (ADR 0010) that the derived edges do not bear out: the
    // label is the weaver's, so a mismatch is a Warning naming what disagrees, never a silent relabel.
    for message in crate::construction::construction_issues(draft) {
        push(
            &mut issues,
            WeaveCode::Construction,
            Severity::Warning,
            WeaveLocation::Draft,
            message,
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
                        WeaveCode::ShaftNeverRaised,
                        Severity::Warning,
                        WeaveLocation::Shaft {
                            shaft: u32::from(s.0),
                        },
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

/// Shuttles, strands, and shot groups (M8-06, ADR 0009): the per-pick lists stay coupled to the picks,
/// values stay in range, every shot group is one shed, and the working sequence is checked where a
/// weaver would stumble: two passes of one shuttle in one shed with no group (the weft is not caught),
/// and, as advice, every grouped return pass (the weft must be caught at the selvedge).
fn weft_work_issues(draft: &Draft, issues: &mut Vec<ValidationIssue>) {
    let work = &draft.weft_work;
    let picks = draft.picks();
    let mut push =
        |code: WeaveCode, severity: Severity, location: WeaveLocation, message: String| {
            issues.push(ValidationIssue::new(code, severity, location, message));
        };
    // A shot group's picks as a location (0-based half-open `start..end`, cut at the last pick).
    let group_at = |start: usize, end: usize| {
        let last = end.min(picks).max(start.saturating_add(1));
        if last <= start.saturating_add(1) {
            WeaveLocation::Pick {
                pick: one_based(start),
            }
        } else {
            WeaveLocation::Picks {
                first: one_based(start),
                last: num(last),
            }
        }
    };
    if !work.shuttles.is_empty() && work.shuttles.len() != picks {
        push(
            WeaveCode::ShuttleCount,
            Severity::Error,
            WeaveLocation::Draft,
            format!(
                "pick shuttle count ({}) != picks ({picks})",
                work.shuttles.len()
            ),
        );
    }
    if !work.strands.is_empty() && work.strands.len() != picks {
        push(
            WeaveCode::StrandCount,
            Severity::Error,
            WeaveLocation::Draft,
            format!(
                "strands per pick count ({}) != picks ({picks})",
                work.strands.len()
            ),
        );
    }
    for (p, s) in work.shuttles.iter().enumerate() {
        if let Some(s) = s.filter(|s| s.0 == 0 || s.0 > MAX_SHUTTLES) {
            push(
                WeaveCode::ShuttleRange,
                Severity::Error,
                WeaveLocation::Pick { pick: one_based(p) },
                format!(
                    "pick {} uses shuttle {} outside 1..={MAX_SHUTTLES}",
                    p + 1,
                    s.0
                ),
            );
        }
    }
    for s in work.shuttle_starts.keys() {
        if s.0 == 0 || s.0 > MAX_SHUTTLES {
            push(
                WeaveCode::ShuttleStartRange,
                Severity::Error,
                WeaveLocation::Shuttle {
                    shuttle: u32::from(s.0),
                },
                format!(
                    "shuttle {} has a starting side but shuttles are numbered 1..={MAX_SHUTTLES}",
                    s.0
                ),
            );
        }
    }
    for (p, &n) in work.strands.iter().enumerate() {
        if n == 0 || n > MAX_STRANDS {
            push(
                WeaveCode::StrandRange,
                Severity::Error,
                WeaveLocation::Pick { pick: one_based(p) },
                format!(
                    "pick {} carries {n} strands, outside 1..={MAX_STRANDS}",
                    p + 1
                ),
            );
        }
    }

    // Shot groups: each is a range of at least two picks inside the draft, the groups do not overlap,
    // and every pick of a group raises the same shafts (a group is ONE shed).
    let mut groups: Vec<ShotGroup> = work.shot_groups.clone();
    groups.sort_by_key(|g| (g.start, g.picks));
    let mut sound: Vec<ShotGroup> = Vec::new();
    for g in &groups {
        let range = picks_range(g.start, g.end());
        if g.picks < 2 {
            push(
                WeaveCode::ShotGroupShort,
                Severity::Error,
                WeaveLocation::Pick {
                    pick: one_based(g.start),
                },
                format!(
                    "the shot group at pick {} has {} pick{}; a shot group needs at least 2",
                    g.start + 1,
                    g.picks,
                    if g.picks == 1 { "" } else { "s" }
                ),
            );
        } else if g.end() > picks {
            push(
                WeaveCode::ShotGroupPastEnd,
                Severity::Error,
                group_at(g.start, g.end()),
                format!("the shot group at {range} reaches past the last pick ({picks})"),
            );
        } else if let Some(prev) = sound.last().filter(|prev| prev.end() > g.start) {
            push(
                WeaveCode::ShotGroupOverlap,
                Severity::Error,
                WeaveLocation::Picks {
                    first: one_based(prev.start),
                    last: num(g.end().max(prev.end())),
                },
                format!(
                    "the shot groups at {} and {range} overlap",
                    picks_range(prev.start, prev.end())
                ),
            );
        } else {
            let off: Vec<usize> = (g.start + 1..g.end())
                .filter(|&p| !draft.same_shed(g.start, p))
                .collect();
            if off.is_empty() {
                sound.push(*g);
            } else {
                push(
                    WeaveCode::ShotGroupMixedSheds,
                    Severity::Error,
                    group_at(g.start, g.end()),
                    format!(
                        "{range} are grouped as one shot, but {} {} a different shed from pick {}",
                        noun_picks(&off),
                        if off.len() == 1 { "uses" } else { "use" },
                        g.start + 1
                    ),
                );
            }
        }
    }

    // Two passes of ONE shuttle in ONE shed, not grouped: the second pass lies in the same shed as the
    // first, so the weft turns at the selvedge without interlacing and pulls back out. Either the
    // weaver meant a double shot (group it) or the draft has a mistake. Reported as maximal runs.
    // `sound` is sorted by start and its groups do not overlap: the group that could hold pick `a` is
    // found by binary search, so this stays O(picks log groups) for a draft full of groups.
    let grouped_together = |a: usize, b: usize| {
        let i = sound.partition_point(|g| g.end() <= a);
        sound.get(i).is_some_and(|g| g.contains(a) && g.contains(b))
    };
    let mut runs: Vec<(usize, usize)> = Vec::new(); // (first, last) 0-based, inclusive
    for p in 1..picks {
        let same = draft.shuttle(p).is_some()
            && draft.shuttle(p) == draft.shuttle(p - 1)
            && !grouped_together(p - 1, p)
            && draft.same_shed(p - 1, p);
        if same {
            match runs.last_mut() {
                Some(run) if run.1 == p - 1 => run.1 = p,
                _ => runs.push((p - 1, p)),
            }
        }
    }
    if !runs.is_empty() {
        let message = if let [(first, last)] = runs[..] {
            format!(
                "{} use the same shed and shuttle {} but are not grouped as one shot, so the weft \
                 will not catch the selvedge",
                picks_range(first, last + 1),
                draft.shuttle(first).map_or(0, |s| s.0)
            )
        } else {
            format!(
                "{} each use one shed and one shuttle but are not grouped as one shot, so the weft \
                 will not catch the selvedge",
                range_list(&runs)
            )
        };
        push(
            WeaveCode::UngroupedSameShed,
            Severity::Warning,
            pick_ranges_location(&runs),
            message,
        );
    }

    // Advice for every sound group that a shuttle may pass through twice (consecutive passes not
    // known to be on different shuttles): the return pass must be caught at the selvedge.
    let returning: Vec<(usize, usize)> = sound
        .iter()
        .filter(|g| {
            (g.start + 1..g.end()).any(|p| {
                let (a, b) = (draft.shuttle(p - 1), draft.shuttle(p));
                a.is_none() || b.is_none() || a == b
            })
        })
        .map(|g| (g.start, g.end() - 1))
        .collect();
    if let [(first, last)] = returning[..] {
        push(
            WeaveCode::ShotGroupCatch,
            Severity::Info,
            pick_ranges_location(&returning),
            format!(
                "{} are a {}: a shuttle that passes again in the same shed needs the weft caught at \
                 the selvedge, for example with a floating selvedge",
                picks_range(first, last + 1),
                shot_name(last + 1 - first)
            ),
        );
    } else if !returning.is_empty() {
        push(
            WeaveCode::ShotGroupCatch,
            Severity::Info,
            pick_ranges_location(&returning),
            format!(
                "{} shot groups ({}) pass more than once in one shed: a shuttle that passes again \
                 in the same shed needs the weft caught at the selvedge, for example with a floating \
                 selvedge",
                returning.len(),
                range_list(&returning)
            ),
        );
    }
}

/// "double shot", "triple shot", or "group of 5 passes" for a shot group of `passes` picks.
fn shot_name(passes: usize) -> String {
    match passes {
        2 => "double shot".to_string(),
        3 => "triple shot".to_string(),
        n => format!("group of {n} passes in one shed"),
    }
}

/// "pick 4" or "picks 4 to 6" (or "picks 4 and 5") for the 0-based half-open range `start..end`.
fn picks_range(start: usize, end: usize) -> String {
    let first = start.saturating_add(1);
    match end.saturating_sub(start) {
        0 | 1 => format!("pick {first}"),
        2 => format!("picks {first} and {end}"),
        _ => format!("picks {first} to {end}"),
    }
}

/// "pick 4" or "picks 4, 6 and 8" (via [`pick_list`]) for 0-based picks.
fn noun_picks(picks: &[usize]) -> String {
    let noun = if picks.len() == 1 { "pick" } else { "picks" };
    format!("{noun} {}", pick_list(picks))
}

/// Up to three inclusive 0-based ranges as "picks 4 and 5, picks 9 to 11 and picks 20 and 21", then
/// "and N more".
fn range_list(runs: &[(usize, usize)]) -> String {
    const SHOWN: usize = 3;
    let parts: Vec<String> = runs
        .iter()
        .take(SHOWN)
        .map(|&(a, b)| picks_range(a, b + 1))
        .collect();
    if runs.len() > SHOWN {
        return format!("{} and {} more", parts.join(", "), runs.len() - SHOWN);
    }
    match parts.split_last() {
        Some((last, rest)) if !rest.is_empty() => format!("{} and {last}", rest.join(", ")),
        _ => parts.join(""),
    }
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
            weft_work: WeftWork::default(),
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
                code: WeaveCode::TabbyOffShed,
                severity: Severity::Warning,
                location: WeaveLocation::Pick { pick: 3 },
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
        assert_eq!(
            warns[0].location,
            WeaveLocation::PickList {
                picks: vec![1, 2, 3, 4, 5, 6, 7],
                total: 7
            }
        );
        assert_eq!(warns[0].location.text(), "Picks 1, 2, 3, 4, 5 and 2 more");
        // Pattern picks on any shed are fine.
        assert!(validate(&roles_draft(&[3, 4], vec![Pattern, Pattern])).is_empty());
    }

    // --- Shuttles, strands, and shot groups (M8-06, ADR 0009) ---

    /// The overshot-style draft with treadles 1, 1, 3, 2, 2, 2, 4 (pattern A twice, tabby a, pattern
    /// B three times, tabby b), every pick unknown role.
    fn shots_draft() -> Draft {
        roles_draft(&[1, 1, 3, 2, 2, 2, 4], vec![])
    }

    fn messages(d: &Draft, severity: Severity) -> Vec<String> {
        validate(d)
            .into_iter()
            .filter(|i| i.severity == severity)
            .map(|i| i.message)
            .collect()
    }

    fn shuttles(ids: &[u8]) -> Vec<Option<ShuttleId>> {
        ids.iter()
            .map(|&s| (s > 0).then_some(ShuttleId(s)))
            .collect()
    }

    #[test]
    fn a_shot_group_on_mixed_sheds_is_an_error_naming_the_picks() {
        let mut d = shots_draft();
        d.weft_work.shot_groups = vec![ShotGroup { start: 0, picks: 3 }];
        assert_eq!(
            messages(&d, Severity::Error),
            vec!["picks 1 to 3 are grouped as one shot, but pick 3 uses a different shed from pick 1"]
        );
        d.weft_work.shot_groups = vec![ShotGroup { start: 2, picks: 5 }];
        assert_eq!(
            messages(&d, Severity::Error),
            vec![
                "picks 3 to 7 are grouped as one shot, but picks 4, 5, 6 and 7 use a different shed \
                 from pick 3"
            ]
        );
        // Same shed is clean (apart from the advice note).
        d.weft_work.shot_groups = vec![ShotGroup { start: 3, picks: 3 }];
        assert!(messages(&d, Severity::Error).is_empty());
    }

    #[test]
    fn malformed_groups_and_out_of_range_values_are_errors() {
        let mut d = shots_draft();
        d.weft_work.shot_groups = vec![
            ShotGroup { start: 0, picks: 2 },
            ShotGroup { start: 1, picks: 2 },
            ShotGroup { start: 2, picks: 1 },
            ShotGroup { start: 5, picks: 3 },
        ];
        d.weft_work.shuttles = shuttles(&[1, 9, 0, 0, 0, 0, 0]);
        d.weft_work.strands = vec![1, 0, 5, 1, 1, 1];
        d.weft_work.shuttle_starts.insert(ShuttleId(12), Side::Left);
        assert_eq!(
            messages(&d, Severity::Error),
            vec![
                "strands per pick count (6) != picks (7)",
                "pick 2 uses shuttle 9 outside 1..=8",
                "shuttle 12 has a starting side but shuttles are numbered 1..=8",
                "pick 2 carries 0 strands, outside 1..=4",
                "pick 3 carries 5 strands, outside 1..=4",
                "the shot groups at picks 1 and 2 and picks 2 and 3 overlap",
                "the shot group at pick 3 has 1 pick; a shot group needs at least 2",
                "the shot group at picks 6 to 8 reaches past the last pick (7)",
            ]
        );
        let mut short = shots_draft();
        short.weft_work.shuttles = shuttles(&[1, 1]);
        assert_eq!(
            messages(&short, Severity::Error),
            vec!["pick shuttle count (2) != picks (7)"]
        );
    }

    #[test]
    fn one_shuttle_twice_in_one_shed_without_a_group_is_a_warning() {
        let mut d = shots_draft();
        d.weft_work.shuttles = shuttles(&[1, 1, 2, 1, 1, 1, 2]);
        assert_eq!(
            messages(&d, Severity::Warning),
            vec![
                "picks 1 and 2 and picks 4 to 6 each use one shed and one shuttle but are not \
                 grouped as one shot, so the weft will not catch the selvedge"
            ]
        );
        // One run reads with its shuttle.
        d.weft_work.shuttles = shuttles(&[1, 2, 2, 1, 1, 2, 2]);
        assert_eq!(
            messages(&d, Severity::Warning),
            vec![
                "picks 4 and 5 use the same shed and shuttle 1 but are not grouped as one shot, so \
                 the weft will not catch the selvedge"
            ]
        );
        // Grouped, it is a deliberate double shot: no warning, and an advice note instead.
        d.weft_work.shot_groups = vec![ShotGroup { start: 3, picks: 2 }];
        assert!(messages(&d, Severity::Warning).is_empty());
        assert_eq!(
            messages(&d, Severity::Info),
            vec![
                "picks 4 and 5 are a double shot: a shuttle that passes again in the same shed \
                 needs the weft caught at the selvedge, for example with a floating selvedge"
            ]
        );
        // Different shuttles in one shed, or unknown shuttles: nothing to warn about.
        d.weft_work.shot_groups.clear();
        d.weft_work.shuttles = shuttles(&[1, 2, 1, 2, 1, 2, 1]);
        assert!(messages(&d, Severity::Warning).is_empty());
        d.weft_work.shuttles = shuttles(&[1, 0, 1, 1, 0, 1, 1]);
        assert!(messages(&d, Severity::Warning).is_empty());
        // Same shuttle on consecutive picks in DIFFERENT sheds is ordinary weaving.
        d.weft_work.shuttles = shuttles(&[1, 2, 1, 1, 2, 1, 1]);
        assert!(messages(&d, Severity::Warning).is_empty());
    }

    #[test]
    fn grouped_return_passes_get_one_advice_note() {
        let mut d = shots_draft();
        // No shuttles recorded: a group may be one shuttle passing twice, so the note applies.
        d.weft_work.shot_groups = vec![
            ShotGroup { start: 0, picks: 2 },
            ShotGroup { start: 3, picks: 3 },
        ];
        assert_eq!(
            messages(&d, Severity::Info),
            vec![
                "2 shot groups (picks 1 and 2 and picks 4 to 6) pass more than once in one shed: a \
                 shuttle that passes again in the same shed needs the weft caught at the selvedge, \
                 for example with a floating selvedge"
            ]
        );
        assert!(validate(&d).iter().all(|i| i.severity != Severity::Error));
        // A triple shot alone names itself.
        d.weft_work.shot_groups = vec![ShotGroup { start: 3, picks: 3 }];
        assert!(messages(&d, Severity::Info)[0].starts_with("picks 4 to 6 are a triple shot: "));
        // Every pass on a different shuttle than the one before: no return pass, no note.
        d.weft_work.shuttles = shuttles(&[1, 1, 1, 1, 2, 1, 1]);
        assert!(messages(&d, Severity::Info).is_empty());
        // Four passes name the count.
        let mut four = roles_draft(&[1, 1, 1, 1], vec![]);
        four.weft_work.shot_groups = vec![ShotGroup { start: 0, picks: 4 }];
        assert!(messages(&four, Severity::Info)[0]
            .starts_with("picks 1 to 4 are a group of 4 passes in one shed: "));
    }

    /// A group from a hostile DTO (a start or length near the integer limit) is reported, never a
    /// panic.
    #[test]
    fn an_absurd_group_is_an_error_not_a_panic() {
        let mut d = shots_draft();
        d.weft_work.shot_groups = vec![
            ShotGroup {
                start: usize::MAX,
                picks: 2,
            },
            ShotGroup {
                start: 1,
                picks: usize::MAX,
            },
        ];
        let errors = messages(&d, Severity::Error);
        assert_eq!(errors.len(), 2, "{errors:?}");
        assert!(errors
            .iter()
            .all(|m| m.contains("reaches past the last pick (7)")));
        // Making them sound cuts at the last pick (the resize rule) and keeps one-shed runs only.
        assert_eq!(
            d.sound_shot_groups(),
            vec![ShotGroup { start: 3, picks: 3 }]
        );
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

    // --- codes and typed locations (ADR 0021) ---

    fn located(d: &Draft) -> Vec<(&'static str, Severity, WeaveLocation, String)> {
        validate(d)
            .into_iter()
            .map(|i| {
                (
                    i.code.as_str(),
                    i.severity,
                    i.location.clone(),
                    i.location.text(),
                )
            })
            .collect()
    }

    #[test]
    fn codes_round_trip_and_are_unique() {
        let mut seen = std::collections::BTreeSet::new();
        for c in WeaveCode::ALL {
            assert!(c.as_str().starts_with("weave."), "{}", c.as_str());
            assert!(seen.insert(c.as_str()), "duplicate {}", c.as_str());
            assert_eq!(WeaveCode::parse(c.as_str()), Some(c));
        }
        assert_eq!(WeaveCode::parse("weave.nope"), None);
    }

    #[test]
    fn each_cell_finding_names_its_cell_in_the_weavers_numbers() {
        let mut d = Draft::blank(2, 2);
        d.threading = Threading(vec![vec![ShaftId(1)], vec![ShaftId(9)]]);
        d.colors.warp = vec![0, 5];
        if let Drive::Treadled { tieup, treadling } = &mut d.drive {
            tieup.0[0] = vec![ShaftId(5)];
            *treadling = Treadling(vec![vec![TreadleId(1)], vec![TreadleId(7)]]);
        }
        d.colors.weft = vec![0, 4];
        let found = located(&d);
        let has = |code: &str, loc: WeaveLocation, words: &str| {
            assert!(
                found.iter().any(|(c, s, l, t)| *c == code
                    && *s == Severity::Error
                    && *l == loc
                    && t == words),
                "want {code} at {loc:?} ({words}) in {found:?}"
            );
        };
        has(
            "weave.threading_shaft",
            WeaveLocation::Threading { end: 2, shaft: 9 },
            "End 2, shaft 9",
        );
        has(
            "weave.tieup_shaft",
            WeaveLocation::TieUp {
                treadle: 1,
                shaft: 5,
            },
            "Tie-up, treadle 1, shaft 5",
        );
        has(
            "weave.treadle_untied",
            WeaveLocation::Treadling {
                pick: 2,
                treadle: 7,
            },
            "Pick 2, treadle 7",
        );
        has(
            "weave.warp_color_ref",
            WeaveLocation::WarpColor { end: 2, color: 5 },
            "End 2, color",
        );
        has(
            "weave.weft_color_ref",
            WeaveLocation::WeftColor { pick: 2, color: 4 },
            "Pick 2, color",
        );

        let mut lp = Draft::blank(2, 2).to_liftplan_draft();
        lp.drive = Drive::Liftplan(Liftplan(vec![vec![ShaftId(3)]]));
        lp.colors.weft = vec![0];
        assert!(located(&lp)
            .iter()
            .any(|(c, _, l, t)| *c == "weave.liftplan_shaft"
                && *l == WeaveLocation::LiftPlan { pick: 1, shaft: 3 }
                && t == "Pick 1, shaft 3"));
    }

    #[test]
    fn whole_draft_and_shaft_findings_say_so() {
        let mut d = Draft::blank(2, 2);
        d.threading = Threading(vec![vec![ShaftId(1)]]);
        d.colors.warp = vec![0, 0, 0];
        let found = located(&d);
        assert!(found
            .iter()
            .any(|(c, s, l, t)| *c == "weave.warp_color_count"
                && *s == Severity::Warning
                && *l == WeaveLocation::Draft
                && t == "Whole draft"));
        // A satin whose shafts 2, 4, 6, 8 are never raised: one Shaft location each.
        let satin = {
            let mut d = Draft::blank(8, 8);
            d.threading = Threading::straight(8, 8);
            d.drive = Drive::Treadled {
                tieup: TieUp::satin(8, 2),
                treadling: Treadling((0..8).map(|i| vec![TreadleId(i as u16 + 1)]).collect()),
            };
            d.colors.warp = vec![0; 8];
            d.colors.weft = vec![1; 8];
            d
        };
        let shafts: Vec<WeaveLocation> = validate(&satin)
            .into_iter()
            .filter(|i| i.code == WeaveCode::ShaftNeverRaised)
            .map(|i| i.location)
            .collect();
        assert_eq!(
            shafts,
            [2, 4, 6, 8]
                .map(|shaft| WeaveLocation::Shaft { shaft })
                .to_vec()
        );
    }

    #[test]
    fn weft_work_findings_name_their_picks() {
        let mut d = shots_draft();
        d.weft_work.shot_groups = vec![ShotGroup { start: 0, picks: 3 }];
        let i = validate(&d)
            .into_iter()
            .find(|i| i.code == WeaveCode::ShotGroupMixedSheds)
            .unwrap();
        assert_eq!(i.location, WeaveLocation::Picks { first: 1, last: 3 });
        assert_eq!(i.location.text(), "Picks 1 to 3");
        assert_eq!(
            (i.location.first_pick(), i.location.last_pick()),
            (Some(1), Some(3))
        );

        let mut d = shots_draft();
        d.weft_work.shuttles = shuttles(&[1, 1, 2, 1, 1, 1, 2]);
        let i = validate(&d)
            .into_iter()
            .find(|i| i.code == WeaveCode::UngroupedSameShed)
            .unwrap();
        assert_eq!(
            i.location,
            WeaveLocation::PickRanges {
                ranges: vec![(1, 2), (4, 6)],
                total: 2
            }
        );
        assert_eq!(i.location.text(), "Picks 1 and 2 and picks 4 to 6");
        // A capped list still counts every pick.
        let long = WeaveLocation::PickList {
            picks: (1..=24).collect(),
            total: 30,
        };
        assert_eq!(long.text(), "Picks 1, 2, 3, 4, 5 and 25 more");
        let few = WeaveLocation::PickRanges {
            ranges: vec![(1, 2), (5, 5), (8, 10), (12, 13)],
            total: 4,
        };
        assert_eq!(
            few.text(),
            "Picks 1 and 2, pick 5, picks 8 to 10 and 1 more"
        );
        assert_eq!(i.location.first_pick(), Some(1));

        let mut d = shots_draft();
        d.weft_work.shuttles = shuttles(&[1, 9, 0, 0, 0, 0, 0]);
        d.weft_work.shuttle_starts.insert(ShuttleId(12), Side::Left);
        let found = located(&d);
        assert!(found.iter().any(
            |(c, _, l, _)| *c == "weave.shuttle_range" && *l == WeaveLocation::Pick { pick: 2 }
        ));
        assert!(found
            .iter()
            .any(|(c, _, l, t)| *c == "weave.shuttle_start_range"
                && *l == WeaveLocation::Shuttle { shuttle: 12 }
                && t == "Shuttle 12"));

        // An absurd group from a hostile DTO is located without overflowing.
        let mut d = shots_draft();
        d.weft_work.shot_groups = vec![ShotGroup {
            start: usize::MAX,
            picks: 2,
        }];
        let i = validate(&d)
            .into_iter()
            .find(|i| i.code == WeaveCode::ShotGroupPastEnd)
            .unwrap();
        assert!(matches!(i.location, WeaveLocation::Pick { .. }));
    }

    /// A hostile list repeating one bad shaft or treadle is one finding per cell, not one per
    /// repeat, and many shot groups are matched by binary search.
    #[test]
    fn a_repeated_bad_id_is_reported_once_per_cell() {
        let mut d = Draft::blank(4, 4);
        d.threading = Threading(vec![vec![ShaftId(9); 100_000], vec![ShaftId(1)]]);
        d.colors.warp = vec![0; 2];
        if let Drive::Treadled { tieup, treadling } = &mut d.drive {
            tieup.0[0] = vec![ShaftId(7); 1_000];
            *treadling = Treadling(vec![vec![TreadleId(99); 1_000], vec![TreadleId(1)]]);
        }
        d.colors.weft = vec![0; 2];
        let codes: Vec<WeaveCode> = validate(&d)
            .into_iter()
            .filter(|i| i.severity == Severity::Error)
            .map(|i| i.code)
            .collect();
        assert_eq!(
            codes,
            vec![
                WeaveCode::ThreadingShaft,
                WeaveCode::TieUpShaft,
                WeaveCode::TreadleUntied
            ]
        );
        let ids = [
            3u16, 1, 3, 2, 1, 20, 19, 18, 17, 16, 15, 14, 13, 12, 11, 10, 9, 8, 3, 20,
        ];
        let once: Vec<u16> = distinct(ids.into_iter()).collect();
        assert_eq!(
            once,
            vec![3, 1, 2, 20, 19, 18, 17, 16, 15, 14, 13, 12, 11, 10, 9, 8]
        );
    }
}
