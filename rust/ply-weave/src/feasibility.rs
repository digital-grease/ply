//! Loom feasibility (roadmap M8-02, ADR 0014): can this draft be woven on this loom, as drafted?
//!
//! SEPARATE from structural validation ([`crate::validate`]): a draft can be structurally sound and
//! not feasible on a given loom, and a structurally broken draft still gets its loom check (only the
//! ids it can read are used; nothing here panics). Loom diagnostics are never structural issues and
//! structural issues never appear here.
//!
//! Every check family reports exactly one outcome, in a fixed order (shafts, drive, treadles at once,
//! shed direction, balance, width, reed), each with a stable [`LoomCode`]. A check whose input is
//! unknown (the loom's shaft count not recorded, no sett) says so as [`LoomSeverity::NotChecked`]; it
//! never passes silently. Wording is a weaver's: "This draft threads 8 shafts; Floor loom has 4."
//!
//! What the checks rely on (research note, ADR 0014): shafts and treadles are positions, so a draft
//! needs as many as it uses DISTINCT ones; a shed-direction mismatch is woven by tying the other
//! squares (advice, not an error); a table loom or dobby works from the lift plan; unbalanced sheds on
//! a counterbalance are advice; double width is checked at its folded width in the reed.

use crate::construction::{side_word, Construction};
use crate::draft::{Draft, Drive, ShedType};
use crate::loom::{number, DentUnit, Length, LoomKind, LoomProfile, Reed, CM_PER_INCH};
use ply_common::Unit;
use std::collections::{BTreeMap, BTreeSet};

/// How serious a loom diagnostic is.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum LoomSeverity {
    /// The draft cannot be woven on this loom as drafted.
    NotFeasible,
    /// It can be, with a change of tie-up, a different approach, or care.
    Advice,
    /// An input is unknown, so this was not checked.
    NotChecked,
    /// Checked, and it fits.
    Fits,
}

/// A stable, machine-readable diagnostic code (see [`LoomCode::as_str`]). Tests and the UI key on
/// these, never on the message text.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum LoomCode {
    ShaftsExceeded,
    ShaftsRenumber,
    ShaftsFit,
    ShaftsUnknown,
    ThreadingEmpty,
    UnthreadedShaftsLifted,
    TreadlesExceeded,
    TreadlesFit,
    TreadlesUnknown,
    LiftPlanLoom,
    LiftPlanShedsFit,
    LiftPlanShedsExceeded,
    DriveEmpty,
    TreadlesAtOnceExceeded,
    TreadlesAtOnceFit,
    TreadlesAtOnceUnknown,
    CountermarchSkeleton,
    ShedFits,
    TieUpForSinkingShed,
    TieUpForRisingShed,
    CountermarchTieUp,
    ShedUnknown,
    UnbalancedSheds,
    ShedsBalanced,
    BalanceNoSheds,
    WidthExceeded,
    WidthFits,
    WidthUnknownLoom,
    WidthUnknownSett,
    WidthNoEnds,
    ReedFits,
    ReedIrregular,
    ReedNoneFits,
    ReedUnknown,
    ReedNoSett,
}

impl LoomCode {
    /// Every code, in declaration order.
    pub const ALL: [LoomCode; 35] = [
        LoomCode::ShaftsExceeded,
        LoomCode::ShaftsRenumber,
        LoomCode::ShaftsFit,
        LoomCode::ShaftsUnknown,
        LoomCode::ThreadingEmpty,
        LoomCode::UnthreadedShaftsLifted,
        LoomCode::TreadlesExceeded,
        LoomCode::TreadlesFit,
        LoomCode::TreadlesUnknown,
        LoomCode::LiftPlanLoom,
        LoomCode::LiftPlanShedsFit,
        LoomCode::LiftPlanShedsExceeded,
        LoomCode::DriveEmpty,
        LoomCode::TreadlesAtOnceExceeded,
        LoomCode::TreadlesAtOnceFit,
        LoomCode::TreadlesAtOnceUnknown,
        LoomCode::CountermarchSkeleton,
        LoomCode::ShedFits,
        LoomCode::TieUpForSinkingShed,
        LoomCode::TieUpForRisingShed,
        LoomCode::CountermarchTieUp,
        LoomCode::ShedUnknown,
        LoomCode::UnbalancedSheds,
        LoomCode::ShedsBalanced,
        LoomCode::BalanceNoSheds,
        LoomCode::WidthExceeded,
        LoomCode::WidthFits,
        LoomCode::WidthUnknownLoom,
        LoomCode::WidthUnknownSett,
        LoomCode::WidthNoEnds,
        LoomCode::ReedFits,
        LoomCode::ReedIrregular,
        LoomCode::ReedNoneFits,
        LoomCode::ReedUnknown,
        LoomCode::ReedNoSett,
    ];

    /// The stable string form, e.g. `loom.shafts_exceeded`. Never changes once released.
    pub fn as_str(self) -> &'static str {
        match self {
            LoomCode::ShaftsExceeded => "loom.shafts_exceeded",
            LoomCode::ShaftsRenumber => "loom.shafts_renumber",
            LoomCode::ShaftsFit => "loom.shafts_fit",
            LoomCode::ShaftsUnknown => "loom.shafts_unknown",
            LoomCode::ThreadingEmpty => "loom.threading_empty",
            LoomCode::UnthreadedShaftsLifted => "loom.unthreaded_shafts_lifted",
            LoomCode::TreadlesExceeded => "loom.treadles_exceeded",
            LoomCode::TreadlesFit => "loom.treadles_fit",
            LoomCode::TreadlesUnknown => "loom.treadles_unknown",
            LoomCode::LiftPlanLoom => "loom.lift_plan_loom",
            LoomCode::LiftPlanShedsFit => "loom.lift_plan_sheds_fit",
            LoomCode::LiftPlanShedsExceeded => "loom.lift_plan_sheds_exceeded",
            LoomCode::DriveEmpty => "loom.drive_empty",
            LoomCode::TreadlesAtOnceExceeded => "loom.treadles_at_once_exceeded",
            LoomCode::TreadlesAtOnceFit => "loom.treadles_at_once_fit",
            LoomCode::TreadlesAtOnceUnknown => "loom.treadles_at_once_unknown",
            LoomCode::CountermarchSkeleton => "loom.countermarch_skeleton",
            LoomCode::ShedFits => "loom.shed_fits",
            LoomCode::TieUpForSinkingShed => "loom.tie_up_for_sinking_shed",
            LoomCode::TieUpForRisingShed => "loom.tie_up_for_rising_shed",
            LoomCode::CountermarchTieUp => "loom.countermarch_tie_up",
            LoomCode::ShedUnknown => "loom.shed_unknown",
            LoomCode::UnbalancedSheds => "loom.unbalanced_sheds",
            LoomCode::ShedsBalanced => "loom.sheds_balanced",
            LoomCode::BalanceNoSheds => "loom.balance_no_sheds",
            LoomCode::WidthExceeded => "loom.width_exceeded",
            LoomCode::WidthFits => "loom.width_fits",
            LoomCode::WidthUnknownLoom => "loom.width_unknown_loom",
            LoomCode::WidthUnknownSett => "loom.width_unknown_sett",
            LoomCode::WidthNoEnds => "loom.width_no_ends",
            LoomCode::ReedFits => "loom.reed_fits",
            LoomCode::ReedIrregular => "loom.reed_irregular",
            LoomCode::ReedNoneFits => "loom.reed_none_fits",
            LoomCode::ReedUnknown => "loom.reed_unknown",
            LoomCode::ReedNoSett => "loom.reed_no_sett",
        }
    }

    /// The code for a stable string, if any (the inverse of [`as_str`](Self::as_str)).
    pub fn parse(s: &str) -> Option<LoomCode> {
        LoomCode::ALL.into_iter().find(|c| c.as_str() == s)
    }
}

/// What a location's numbers count.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum LocationKind {
    Shafts,
    Treadles,
    Picks,
}

/// The most numbers a location lists (its `total` still counts them all).
pub const MAX_LOCATION_NUMBERS: usize = 24;

/// Where in the draft a diagnostic applies: 1-based shaft, treadle or pick numbers, ascending, at most
/// [`MAX_LOCATION_NUMBERS`] of them; `total` is how many there are in all.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LoomLocation {
    pub kind: LocationKind,
    pub numbers: Vec<u32>,
    pub total: usize,
}

/// One loom finding.
#[derive(Debug, Clone, PartialEq)]
pub struct LoomDiagnostic {
    pub code: LoomCode,
    pub severity: LoomSeverity,
    /// A few words for a summary line: "needs 8 shafts, has 4".
    pub summary: String,
    /// The full sentence, with the exact requirement: "This draft threads 8 shafts; Floor loom has 4."
    pub message: String,
    pub location: Option<LoomLocation>,
    /// What the weaver can do, when Ply can suggest something.
    pub remediation: Option<String>,
}

/// A sett: `ends` per inch or per cm (`per`).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Sett {
    pub ends: f64,
    pub per: Unit,
}

/// The largest sett accepted, in ends per inch (a fine silk is about 100 to 120).
pub const MAX_SETT_PER_INCH: f64 = 1_000.0;

/// The smallest sett accepted, in ends per inch (a rag rug is about 4 to 8).
pub const MIN_SETT_PER_INCH: f64 = 0.01;

/// Decipoints (tenths of a point) in an inch: WIF 1.1's third unit.
pub const DECIPOINTS_PER_INCH: f64 = 720.0;

impl Sett {
    /// Ends per inch.
    pub fn per_inch(self) -> f64 {
        match self.per {
            Unit::Inches => self.ends,
            Unit::Centimeters => self.ends * CM_PER_INCH,
        }
    }

    /// Whether this is a usable sett: finite, from [`MIN_SETT_PER_INCH`] to [`MAX_SETT_PER_INCH`].
    pub fn is_valid(self) -> bool {
        self.ends.is_finite() && (MIN_SETT_PER_INCH..=MAX_SETT_PER_INCH).contains(&self.per_inch())
    }

    /// "24 ends per inch", "10 ends per cm".
    pub fn describe(self) -> String {
        let unit = match self.per {
            Unit::Inches => "inch",
            Unit::Centimeters => "cm",
        };
        format!("{} ends per {unit}", number(self.ends))
    }
}

/// Where the sett a check used came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SettSource {
    /// The weaver entered it for this draft.
    Entered,
    /// The draft's WIF file: `1 / [WARP] Spacing`.
    File,
}

/// The sett a check used, and its source.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct SettUsed {
    pub sett: Sett,
    pub source: SettSource,
}

/// What the weaver supplies beyond the draft and the loom.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct LoomCheckInput {
    /// The sett for this draft, overriding the file's. An invalid one ([`Sett::is_valid`]) is ignored.
    pub sett: Option<Sett>,
}

/// Everything a loom check found.
#[derive(Debug, Clone, PartialEq)]
pub struct LoomReport {
    /// The loom's name as the messages use it.
    pub loom_name: String,
    pub diagnostics: Vec<LoomDiagnostic>,
    /// The sett the width and reed checks used, if any.
    pub sett: Option<SettUsed>,
    /// The file's own sett (`1 / [WARP] Spacing`), when it has one, even if the weaver entered another.
    pub file_sett: Option<Sett>,
    /// The warp's width in the reed, when the sett (or the file's per-end spacing) is known.
    pub reed_width: Option<Length>,
}

impl LoomReport {
    /// True when nothing is [`LoomSeverity::NotFeasible`].
    pub fn feasible(&self) -> bool {
        self.diagnostics
            .iter()
            .all(|d| d.severity != LoomSeverity::NotFeasible)
    }

    /// The codes, in report order.
    pub fn codes(&self) -> Vec<&'static str> {
        self.diagnostics.iter().map(|d| d.code.as_str()).collect()
    }
}

/// The WIF spacing a draft carries: `[WARP] Spacing` (the centre-to-centre distance between ends, in
/// the draft's unit, "1 / sett") and the per-end overrides of `[WARP SPACING]`, both kept in
/// [`Draft::retained`] (see `wif.rs`). `None` when the draft carries neither.
#[derive(Debug, Clone, PartialEq)]
pub struct FileSpacing {
    pub unit: Unit,
    /// The default spacing, when the file gives a usable one.
    pub spacing: Option<f64>,
    /// Per-end overrides (0-based end -> spacing), only for ends the draft has.
    pub per_end: BTreeMap<usize, f64>,
    /// True when the file gives some end of the draft its own spacing that is not usable: that end's
    /// width is then unknown (it never falls back to the default).
    pub unusable_per_end: bool,
}

impl FileSpacing {
    /// The draft's spacing, read from its retained WIF data. A spacing counts only when it gives a
    /// usable sett (1 / spacing within [`Sett::is_valid`]), for the default and for every per-end
    /// value alike, so the width is never computed from a spacing the sett check would refuse. The
    /// unit is the draft's, or the section's own `Units` when the file wrote [WARP] in another
    /// (`Decipoints`, a tenth of a point, 1/720 inch, is converted to inches); an unknown unit gives
    /// no spacing at all.
    pub fn of(draft: &Draft) -> Option<FileSpacing> {
        let section = |name: &str| {
            draft
                .retained
                .iter()
                .find(|s| s.name.eq_ignore_ascii_case(name))
        };
        let warp = section(crate::wif::WARP_SECTION);
        let own_unit = warp.and_then(|s| {
            s.entries
                .iter()
                .find(|(k, _)| k.trim().eq_ignore_ascii_case("Units"))
                .map(|(_, v)| v.trim().to_ascii_lowercase())
        });
        // (unit, factor): a value times factor is a length in unit.
        let (unit, factor) = match own_unit.as_deref() {
            None => (draft.unit, 1.0),
            Some("inches" | "inch" | "in") => (Unit::Inches, 1.0),
            Some("decipoints" | "decipoint") => (Unit::Inches, 1.0 / DECIPOINTS_PER_INCH),
            Some(u) if u.contains("cent") || u == "cm" => (Unit::Centimeters, 1.0),
            Some(_) => return None,
        };
        let usable = |v: &str| {
            let spacing = v.trim().parse::<f64>().ok()? * factor;
            let sett = Sett {
                ends: 1.0 / spacing,
                per: unit,
            };
            (spacing.is_finite() && spacing > 0.0 && sett.is_valid()).then_some(spacing)
        };
        let spacing = warp.and_then(|s| {
            s.entries
                .iter()
                .find(|(k, _)| k.trim().eq_ignore_ascii_case("Spacing"))
                .and_then(|(_, v)| usable(v))
        });
        let ends = draft.ends();
        let mut per_end: BTreeMap<usize, f64> = BTreeMap::new();
        let mut unusable_per_end = false;
        for (k, v) in section("WARP SPACING")
            .into_iter()
            .flat_map(|s| s.entries.iter())
        {
            let Some(end) = k
                .trim()
                .parse::<usize>()
                .ok()
                .filter(|&e| e >= 1 && e <= ends)
            else {
                continue; // not one of the draft's ends
            };
            match usable(v) {
                Some(spacing) => {
                    per_end.insert(end - 1, spacing);
                }
                None => unusable_per_end = true,
            }
        }
        (spacing.is_some() || !per_end.is_empty() || unusable_per_end).then_some(FileSpacing {
            unit,
            spacing,
            per_end,
            unusable_per_end,
        })
    }

    /// Whether the file gives [WARP] a `Spacing` at all, usable or not.
    fn given(draft: &Draft) -> bool {
        draft.retained.iter().any(|s| {
            s.name.eq_ignore_ascii_case(crate::wif::WARP_SECTION)
                && s.entries
                    .iter()
                    .any(|(k, _)| k.trim().eq_ignore_ascii_case("Spacing"))
        })
    }

    /// The sett the file gives (`1 / Spacing`), when it spaces every end alike.
    pub fn sett(&self) -> Option<Sett> {
        let spacing = self.spacing?;
        let sett = Sett {
            ends: 1.0 / spacing,
            per: self.unit,
        };
        (self.per_end.is_empty() && !self.unusable_per_end && sett.is_valid()).then_some(sett)
    }

    /// The width of `ends` ends in the reed: the sum of their spacings, or `None` when an end has
    /// neither its own spacing nor the default.
    pub fn width(&self, ends: usize) -> Option<Length> {
        if self.unusable_per_end {
            return None;
        }
        let mut total = 0.0;
        for end in 0..ends {
            total += self.per_end.get(&end).copied().or(self.spacing)?;
        }
        Some(Length {
            value: total,
            unit: self.unit,
        })
    }
}

/// The sett a draft's file gives, if any (see [`FileSpacing::sett`]).
pub fn file_sett(draft: &Draft) -> Option<Sett> {
    FileSpacing::of(draft).and_then(|s| s.sett())
}

/// Check `draft` against `loom`. Never panics, whatever the draft or profile holds.
pub fn check(draft: &Draft, loom: &LoomProfile, input: &LoomCheckInput) -> LoomReport {
    let facts = Facts::of(draft);
    let mut c = Checker {
        draft,
        loom,
        facts: &facts,
        name: loom.display_name(),
        out: Vec::new(),
    };
    c.shafts();
    c.drive();
    c.treadles_at_once();
    c.shed_direction();
    c.balance();
    let spacing = FileSpacing::of(draft);
    let file_sett = spacing.as_ref().and_then(FileSpacing::sett);
    let sett = input
        .sett
        .filter(|s| s.is_valid())
        .map(|sett| SettUsed {
            sett,
            source: SettSource::Entered,
        })
        .or(file_sett.map(|sett| SettUsed {
            sett,
            source: SettSource::File,
        }));
    let reed_width = match sett {
        Some(SettUsed {
            sett,
            source: SettSource::Entered,
        }) => Some(width_at(draft.ends(), sett)),
        _ => spacing.as_ref().and_then(|s| s.width(draft.ends())),
    };
    c.width(sett, reed_width, spacing.as_ref());
    c.reed(sett, spacing.as_ref());
    LoomReport {
        loom_name: c.name,
        diagnostics: c.out,
        sett,
        file_sett,
        reed_width,
    }
}

/// The width of `ends` ends at `sett`, in the sett's unit.
fn width_at(ends: usize, sett: Sett) -> Length {
    Length {
        value: ends as f64 / sett.ends,
        unit: sett.per,
    }
}

// ---------------------------------------------------------------------------------------------
// What the draft uses, read robustly (invalid ids ignored, never indexed blindly).
// ---------------------------------------------------------------------------------------------

struct Facts {
    /// Shafts (>= 1) some end is threaded on.
    threaded: BTreeSet<u16>,
    /// Shafts (>= 1) the drive names: tie-up rows of pressed treadles, or the lift plan.
    named: BTreeSet<u16>,
    treadled: bool,
    /// Distinct treadles (>= 1) pressed by some pick.
    pressed: BTreeSet<u16>,
    /// 0-based picks pressing two or more distinct treadles, with the count.
    multi: Vec<(usize, usize)>,
    /// Distinct non-empty lifts of a lift-plan draft.
    lift_sheds: usize,
}

impl Facts {
    fn of(draft: &Draft) -> Facts {
        let threaded: BTreeSet<u16> = draft
            .threading
            .0
            .iter()
            .flatten()
            .map(|s| s.0)
            .filter(|&s| s >= 1)
            .collect();
        let mut named = BTreeSet::new();
        let mut pressed = BTreeSet::new();
        let mut multi = Vec::new();
        let mut lift_sheds = 0;
        let treadled = matches!(draft.drive, Drive::Treadled { .. });
        match &draft.drive {
            Drive::Treadled { tieup, treadling } => {
                for (p, row) in treadling.0.iter().enumerate() {
                    let distinct: BTreeSet<u16> =
                        row.iter().map(|t| t.0).filter(|&t| t >= 1).collect();
                    if distinct.len() >= 2 {
                        multi.push((p, distinct.len()));
                    }
                    for &t in &distinct {
                        if pressed.insert(t) {
                            if let Some(tied) = tieup.0.get(usize::from(t) - 1) {
                                named.extend(tied.iter().map(|s| s.0).filter(|&s| s >= 1));
                            }
                        }
                    }
                }
            }
            Drive::Liftplan(lp) => {
                let mut sheds: BTreeSet<Vec<u16>> = BTreeSet::new();
                for row in &lp.0 {
                    let set: BTreeSet<u16> = row.iter().map(|s| s.0).filter(|&s| s >= 1).collect();
                    if set.is_empty() {
                        continue;
                    }
                    named.extend(set.iter().copied());
                    sheds.insert(set.into_iter().collect());
                }
                lift_sheds = sheds.len();
            }
        }
        Facts {
            threaded,
            named,
            treadled,
            pressed,
            multi,
            lift_sheds,
        }
    }
}

// ---------------------------------------------------------------------------------------------
// The checks
// ---------------------------------------------------------------------------------------------

struct Checker<'a> {
    draft: &'a Draft,
    loom: &'a LoomProfile,
    facts: &'a Facts,
    name: String,
    out: Vec<LoomDiagnostic>,
}

impl Checker<'_> {
    fn push(
        &mut self,
        code: LoomCode,
        severity: LoomSeverity,
        summary: impl Into<String>,
        message: String,
    ) -> &mut LoomDiagnostic {
        self.out.push(LoomDiagnostic {
            code,
            severity,
            summary: summary.into(),
            message,
            location: None,
            remediation: None,
        });
        self.out.last_mut().expect("just pushed")
    }

    /// The loom works from a lift plan (table or dobby), not treadles.
    fn lift_plan_loom(&self) -> bool {
        matches!(self.loom.kind, Some(LoomKind::Table | LoomKind::Dobby))
    }

    fn shafts(&mut self) {
        let f = self.facts;
        let Some(&top) = f.threaded.last() else {
            self.push(
                LoomCode::ThreadingEmpty,
                LoomSeverity::NotChecked,
                "nothing threaded yet",
                "No warp ends are threaded yet, so there are no shafts to check.".into(),
            );
            return;
        };
        let n = f.threaded.len();
        let name = self.name.clone();
        let Some(have) = self.loom.shafts else {
            self.push(
                LoomCode::ShaftsUnknown,
                LoomSeverity::NotChecked,
                "shafts not recorded",
                format!(
                    "{name}'s shaft count is not recorded, so the shafts were not checked. This \
                     draft threads {}.",
                    plural(n, "shaft")
                ),
            )
            .remediation = Some("Add the number of shafts in My looms.".into());
            return;
        };
        let beyond: Vec<u32> = f
            .threaded
            .iter()
            .filter(|&&s| s > have)
            .map(|&s| u32::from(s))
            .collect();
        if n > usize::from(have) {
            let numbered = if usize::from(top) > n {
                format!(" (numbered up to {top})")
            } else {
                String::new()
            };
            let d = self.push(
                LoomCode::ShaftsExceeded,
                LoomSeverity::NotFeasible,
                format!("needs {n} shafts, has {have}"),
                format!("This draft threads {n} shafts{numbered}; {name} has {have}."),
            );
            d.location = location(LocationKind::Shafts, &beyond);
            d.remediation = Some(format!(
                "Weave it on a loom with at least {n} shafts, or choose a draft for {}.",
                plural(usize::from(have), "shaft")
            ));
            return;
        }
        if top > have {
            let list = and_list(&f.threaded.iter().map(|s| s.to_string()).collect::<Vec<_>>());
            let d = self.push(
                LoomCode::ShaftsRenumber,
                LoomSeverity::Advice,
                "renumber the shafts",
                format!(
                    "This draft threads shafts numbered up to {top}, but only {n} different ones \
                     ({list}); {name} has {have}."
                ),
            );
            d.location = location(LocationKind::Shafts, &beyond);
            d.remediation = Some(format!(
                "Thread them on shafts 1 to {n} in the same order, and renumber the {} to match.",
                if f.treadled { "tie-up" } else { "lift plan" }
            ));
        } else {
            self.push(
                LoomCode::ShaftsFit,
                LoomSeverity::Fits,
                format!("{n} of {have} shafts"),
                format!(
                    "This draft threads {}; {name} has {have}.",
                    plural(n, "shaft")
                ),
            );
        }
        // Shafts the drive names but no end is threaded on, past the loom's count: lifting them does
        // nothing to the cloth, but a weaver following the draft would look for them.
        let unthreaded: Vec<u32> = f
            .named
            .iter()
            .filter(|&&s| s > have && !f.threaded.contains(&s))
            .map(|&s| u32::from(s))
            .collect();
        if !unthreaded.is_empty() {
            let what = if f.treadled { "tie-up" } else { "lift plan" };
            let shafts = numbers_phrase("shaft", "shafts", &unthreaded, unthreaded.len());
            let (verb, pronoun) = if unthreaded.len() == 1 {
                ("threads", "it")
            } else {
                ("thread", "them")
            };
            let d = self.push(
                LoomCode::UnthreadedShaftsLifted,
                LoomSeverity::Advice,
                "leave out unthreaded shafts",
                format!(
                    "The {what} also names {shafts}, which {verb} no ends; {name} has {have} \
                     shafts, so leave {pronoun} out."
                ),
            );
            d.location = location(LocationKind::Shafts, &unthreaded);
        }
    }

    fn drive(&mut self) {
        let f = self.facts;
        let name = self.name.clone();
        if self.lift_plan_loom() {
            let how = if self.loom.kind == Some(LoomKind::Table) {
                format!("On {name} you lift the shafts with hand levers for each pick")
            } else {
                format!("{name} selects the shafts for each pick itself")
            };
            let d = self.push(
                LoomCode::LiftPlanLoom,
                LoomSeverity::Fits,
                "works from the lift plan",
                format!("{how}, so treadles do not limit this draft."),
            );
            if f.treadled {
                d.remediation = Some(
                    "Convert to liftplan in the editor's menu shows the shafts to lift for each \
                     pick."
                        .into(),
                );
            }
            return;
        }
        let kind_known = self.loom.kind.is_some();
        if f.treadled {
            let n = f.pressed.len();
            let top = f.pressed.last().copied().unwrap_or(0);
            if n == 0 {
                self.push(
                    LoomCode::DriveEmpty,
                    LoomSeverity::NotChecked,
                    "no picks yet",
                    "No pick presses a treadle yet, so the treadles were not checked.".into(),
                );
                return;
            }
            let Some(have) = self.loom.treadles else {
                let what = if kind_known {
                    format!("{name}'s treadle count is not recorded")
                } else {
                    format!("{name}'s type and treadles are not recorded")
                };
                self.push(
                    LoomCode::TreadlesUnknown,
                    LoomSeverity::NotChecked,
                    "treadles not recorded",
                    format!(
                        "{what}, so the treadles were not checked. This draft uses {}.",
                        plural(n, "treadle")
                    ),
                )
                .remediation = Some("Add the number of treadles in My looms.".into());
                return;
            };
            let numbered = if usize::from(top) > n {
                format!(" (numbered up to {top})")
            } else {
                String::new()
            };
            if n > usize::from(have) {
                let beyond: Vec<u32> = f
                    .pressed
                    .iter()
                    .filter(|&&t| t > have)
                    .map(|&t| u32::from(t))
                    .collect();
                let d = self.push(
                    LoomCode::TreadlesExceeded,
                    LoomSeverity::NotFeasible,
                    format!("needs {n} treadles, has {have}"),
                    format!("This draft uses {n} treadles{numbered}; {name} has {have}."),
                );
                d.location = location(LocationKind::Treadles, &beyond);
                d.remediation = Some(
                    "Combine them into a skeleton tie-up pressed two at a time, or weave it from \
                     the lift plan on a table or dobby loom."
                        .into(),
                );
            } else {
                let any = if usize::from(top) > usize::from(have) {
                    format!(": tie them on any {n}")
                } else {
                    String::new()
                };
                self.push(
                    LoomCode::TreadlesFit,
                    LoomSeverity::Fits,
                    format!("{n} of {have} treadles"),
                    format!(
                        "This draft uses {}{numbered}; {name} has {have}{any}.",
                        plural(n, "treadle")
                    ),
                );
            }
            return;
        }
        // A lift-plan draft on a treadle loom (or a loom of unknown type): one treadle per shed.
        let sheds = f.lift_sheds;
        if sheds == 0 {
            self.push(
                LoomCode::DriveEmpty,
                LoomSeverity::NotChecked,
                "no picks yet",
                "No pick of the lift plan raises a shaft yet, so the treadles were not checked."
                    .into(),
            );
            return;
        }
        let Some(have) = self.loom.treadles else {
            let what = if kind_known {
                format!("{name}'s treadle count is not recorded")
            } else {
                format!("{name}'s type and treadles are not recorded")
            };
            self.push(
                LoomCode::TreadlesUnknown,
                LoomSeverity::NotChecked,
                "treadles not recorded",
                format!(
                    "{what}, so Ply cannot tell how it lifts this draft's {}.",
                    plural(sheds, "different shed")
                ),
            )
            .remediation = Some("Add the loom type and treadles in My looms.".into());
            return;
        };
        if sheds <= usize::from(have) {
            let how = match self.loom.kind {
                Some(LoomKind::Jack) => ", tied to the shafts that shed raises",
                Some(LoomKind::Counterbalance) => ", tied to the shafts that shed lowers",
                Some(LoomKind::Countermarch) => {
                    ", with the shafts that rise on the rising lamms and the rest on the sinking \
                     lamms"
                }
                _ => "",
            };
            self.push(
                LoomCode::LiftPlanShedsFit,
                LoomSeverity::Advice,
                "tie one treadle per shed",
                format!(
                    "This draft is a lift plan with {}. {name} has {have} treadles, so tie one \
                     treadle for each shed{how}.",
                    plural(sheds, "different shed")
                ),
            );
        } else {
            self.push(
                LoomCode::LiftPlanShedsExceeded,
                LoomSeverity::NotFeasible,
                format!("needs {sheds} treadles, has {have}"),
                format!(
                    "This draft is a lift plan with {sheds} different sheds; {name} has {have} \
                     treadles, so not every shed can have its own treadle."
                ),
            )
            .remediation = Some(
                "Press treadles together with a skeleton tie-up, or weave it on a table or dobby \
                 loom."
                    .into(),
            );
        }
    }

    fn treadles_at_once(&mut self) {
        let f = self.facts;
        // Nothing is pressed yet: the drive family already says nothing was checked.
        if !f.treadled || self.lift_plan_loom() || f.pressed.is_empty() {
            return;
        }
        let name = self.name.clone();
        if f.multi.is_empty() {
            self.push(
                LoomCode::TreadlesAtOnceFit,
                LoomSeverity::Fits,
                "one treadle per pick",
                "No pick presses more than one treadle at a time.".into(),
            );
            return;
        }
        let most = f.multi.iter().map(|&(_, n)| n).max().unwrap_or(2);
        let all: Vec<usize> = f.multi.iter().map(|&(p, _)| p).collect();
        let press = |picks: &[usize], most: usize, all_same: bool| {
            let up_to = if all_same { "" } else { "up to " };
            let verb = if picks.len() == 1 { "presses" } else { "press" };
            format!(
                "{} {verb} {up_to}{most} treadles together",
                capitalize(&picks_phrase(picks))
            )
        };
        let same = |picks: &[(usize, usize)]| picks.iter().all(|&(_, n)| n == most);
        match self.loom.treadles_at_once {
            None => {
                let d = self.push(
                    LoomCode::TreadlesAtOnceUnknown,
                    LoomSeverity::NotChecked,
                    "treadles at once not recorded",
                    format!(
                        "{}; how many treadles you press at once on {name} is not recorded.",
                        press(&all, most, same(&f.multi))
                    ),
                );
                d.location = pick_location(&all);
                d.remediation = Some("Add how many treadles you press at once in My looms.".into());
            }
            Some(limit) if most > usize::from(limit) => {
                let over: Vec<(usize, usize)> = f
                    .multi
                    .iter()
                    .copied()
                    .filter(|&(_, n)| n > usize::from(limit))
                    .collect();
                let picks: Vec<usize> = over.iter().map(|&(p, _)| p).collect();
                let d = self.push(
                    LoomCode::TreadlesAtOnceExceeded,
                    LoomSeverity::NotFeasible,
                    format!("presses {most} treadles at once, you press {limit}"),
                    format!(
                        "{}; on {name} you press at most {limit} at once.",
                        press(&picks, most, same(&over))
                    ),
                );
                d.location = pick_location(&picks);
                d.remediation = Some(
                    "Tie one treadle for that combination of shafts, or plan a skeleton tie-up \
                     that needs fewer treadles at once."
                        .into(),
                );
            }
            Some(limit) => {
                let d = self.push(
                    LoomCode::TreadlesAtOnceFit,
                    LoomSeverity::Fits,
                    format!("up to {most} treadles at once"),
                    format!(
                        "{}; on {name} you press up to {limit} at once.",
                        press(&all, most, same(&f.multi))
                    ),
                );
                d.location = pick_location(&all);
            }
        }
        if self.loom.kind == Some(LoomKind::Countermarch) {
            let d = self.push(
                LoomCode::CountermarchSkeleton,
                LoomSeverity::Advice,
                "skeleton tie-up needed",
                format!(
                    "{} more than one treadle together. On a countermarch loom that needs a \
                     skeleton tie-up planned for it: every shaft must still move on every pick, and \
                     the treadles pressed together must never ask one shaft to rise and sink at once.",
                    capitalize(&format!(
                        "{} {}",
                        picks_phrase(&all),
                        if all.len() == 1 { "presses" } else { "press" }
                    ))
                ),
            );
            d.location = pick_location(&all);
        }
    }

    fn shed_direction(&mut self) {
        let f = self.facts;
        if !f.treadled || self.lift_plan_loom() {
            return;
        }
        let name = self.name.clone();
        let rising = self.draft.shed == ShedType::Rising;
        let written = if rising {
            "a rising shed (the marked shafts go up)"
        } else {
            "a sinking shed (the marked shafts go down)"
        };
        let other_squares = || {
            let mut s = "Tie each treadle to the shafts its column leaves blank; the cloth is the \
                         same."
                .to_string();
            if !f.multi.is_empty() {
                let picks: Vec<usize> = f.multi.iter().map(|&(p, _)| p).collect();
                s.push_str(&format!(
                    " {} more than one treadle, and {} differently that way, so check {}.",
                    capitalize(&format!(
                        "{} {}",
                        picks_phrase(&picks),
                        if picks.len() == 1 { "presses" } else { "press" }
                    )),
                    if picks.len() == 1 {
                        "weaves"
                    } else {
                        "they weave"
                    },
                    if picks.len() == 1 { "it" } else { "them" }
                ));
            }
            s
        };
        match self.loom.kind {
            None => {
                self.push(
                    LoomCode::ShedUnknown,
                    LoomSeverity::NotChecked,
                    "loom type not recorded",
                    format!(
                        "{name}'s type is not recorded, so Ply cannot tell whether it raises or \
                         lowers the shafts you tie. This draft's tie-up is written for {written}."
                    ),
                )
                .remediation = Some("Add the loom type in My looms.".into());
            }
            Some(LoomKind::Jack) if rising => {
                self.push(
                    LoomCode::ShedFits,
                    LoomSeverity::Fits,
                    "rising shed",
                    format!("This draft's tie-up is written for {written}, as a jack loom works."),
                );
            }
            Some(LoomKind::Counterbalance) if !rising => {
                self.push(
                    LoomCode::ShedFits,
                    LoomSeverity::Fits,
                    "sinking shed",
                    format!(
                        "This draft's tie-up is written for {written}, as a counterbalance loom \
                         works."
                    ),
                );
            }
            Some(LoomKind::Jack) => {
                let remedy = other_squares();
                self.push(
                    LoomCode::TieUpForSinkingShed,
                    LoomSeverity::Advice,
                    "tie-up is for a sinking shed",
                    format!(
                        "This draft's tie-up is written for {written}, but a jack loom raises the \
                         shafts you tie."
                    ),
                )
                .remediation = Some(remedy);
            }
            Some(LoomKind::Counterbalance) => {
                let remedy = other_squares();
                self.push(
                    LoomCode::TieUpForRisingShed,
                    LoomSeverity::Advice,
                    "tie-up is for a rising shed",
                    format!(
                        "This draft's tie-up is written for {written}, but a counterbalance loom \
                         lowers the shafts you tie."
                    ),
                )
                .remediation = Some(remedy);
            }
            Some(LoomKind::Countermarch) => {
                let (marked, rest) = if rising {
                    ("raise", "lower")
                } else {
                    ("lower", "raise")
                };
                self.push(
                    LoomCode::CountermarchTieUp,
                    LoomSeverity::Fits,
                    "tie both sets of lamms",
                    format!(
                        "This draft's tie-up is written for {written}. On a countermarch loom, tie \
                         each treadle's marked shafts to the lamms that {marked} them and every \
                         other shaft to the lamms that {rest} them."
                    ),
                );
            }
            Some(LoomKind::Table | LoomKind::Dobby) => {}
        }
    }

    fn balance(&mut self) {
        if self.loom.kind != Some(LoomKind::Counterbalance) {
            return;
        }
        let f = self.facts;
        let threaded_count = f.threaded.len();
        let top = usize::from(f.threaded.last().copied().unwrap_or(0));
        let mut is_threaded = vec![false; top + 1];
        for &s in &f.threaded {
            is_threaded[usize::from(s)] = true;
        }
        // (0-based pick, raised, lowered) of every unbalanced shed, over the threaded shafts.
        let mut unbalanced: Vec<(usize, usize, usize)> = Vec::new();
        let mut measured = 0usize;
        let mut consider = |p: usize, named_threaded: usize, named_rise: bool| {
            measured += 1;
            let raised = if named_rise {
                named_threaded
            } else {
                threaded_count - named_threaded
            };
            let lowered = threaded_count - raised;
            if raised != lowered {
                unbalanced.push((p, raised, lowered));
            }
        };
        if threaded_count > 0 {
            match &self.draft.drive {
                Drive::Treadled { tieup, treadling } => {
                    let rising = self.draft.shed == ShedType::Rising;
                    let mut mark = vec![false; top + 1];
                    let mut touched: Vec<usize> = Vec::new();
                    for (p, row) in treadling.0.iter().enumerate() {
                        let mut any = false;
                        for t in row.iter().map(|t| usize::from(t.0)).filter(|&t| t >= 1) {
                            any = true;
                            for s in tieup.0.get(t - 1).into_iter().flatten() {
                                let s = usize::from(s.0);
                                if s <= top && is_threaded[s] && !mark[s] {
                                    mark[s] = true;
                                    touched.push(s);
                                }
                            }
                        }
                        if any {
                            consider(p, touched.len(), rising);
                        }
                        for s in touched.drain(..) {
                            mark[s] = false;
                        }
                    }
                }
                Drive::Liftplan(lp) => {
                    for (p, row) in lp.0.iter().enumerate() {
                        let set: BTreeSet<usize> = row
                            .iter()
                            .map(|s| usize::from(s.0))
                            .filter(|&s| s <= top && is_threaded[s])
                            .collect();
                        if !row.is_empty() {
                            consider(p, set.len(), true);
                        }
                    }
                }
            }
        }
        if measured == 0 {
            self.push(
                LoomCode::BalanceNoSheds,
                LoomSeverity::NotChecked,
                "no sheds yet",
                "The draft has no sheds yet (no threaded end, or no pick), so the balance of its \
                 sheds was not checked."
                    .into(),
            );
            return;
        }
        if unbalanced.is_empty() {
            self.push(
                LoomCode::ShedsBalanced,
                LoomSeverity::Fits,
                "balanced sheds",
                "Every shed raises as many shafts as it lowers, which suits a counterbalance loom."
                    .into(),
            );
            return;
        }
        let picks: Vec<usize> = unbalanced.iter().map(|&(p, _, _)| p).collect();
        let (p, raised, lowered) = unbalanced[0];
        let example = if picks.len() == 1 {
            format!("it raises {} and lowers {lowered}", plural(raised, "shaft"))
        } else {
            format!(
                "pick {} raises {} and lowers {lowered}",
                p + 1,
                plural(raised, "shaft")
            )
        };
        let d = self.push(
            LoomCode::UnbalancedSheds,
            LoomSeverity::Advice,
            "unbalanced sheds",
            format!(
                "{} {} an unbalanced shed ({example}). On a counterbalance loom an unbalanced shed \
                 can open poorly.",
                capitalize(&picks_phrase(&picks)),
                if picks.len() == 1 { "has" } else { "have" }
            ),
        );
        d.location = pick_location(&picks);
        d.remediation = Some(
            "A skeleton tie-up with two shafts on each treadle, pressed two at a time, often \
             helps; on a shallow loom, adjusting the shaft heights can too."
                .into(),
        );
    }

    fn width(
        &mut self,
        sett: Option<SettUsed>,
        width: Option<Length>,
        spacing: Option<&FileSpacing>,
    ) {
        let name = self.name.clone();
        let ends = self.draft.ends();
        if ends == 0 {
            self.push(
                LoomCode::WidthNoEnds,
                LoomSeverity::NotChecked,
                "no ends yet",
                "The draft has no warp ends yet, so the width was not checked.".into(),
            );
            return;
        }
        let Some(width) = width else {
            let either = if self.loom.weaving_width.is_none() {
                format!(" {name}'s weaving width is not recorded either.")
            } else {
                String::new()
            };
            let why = match spacing {
                Some(_) => "the file does not give every end a usable spacing",
                None if FileSpacing::given(self.draft) => {
                    "the file's warp spacing does not give a usable sett"
                }
                None => "the file gives no warp spacing",
            };
            self.push(
                LoomCode::WidthUnknownSett,
                LoomSeverity::NotChecked,
                "sett not known",
                format!("The sett is not known, so the width was not checked: {why}.{either}"),
            )
            .remediation = Some("Enter a sett for this draft in Loom for this draft.".into());
            return;
        };
        let basis = match sett {
            Some(SettUsed {
                sett,
                source: SettSource::Entered,
            }) => format!("{ends} ends at {}, the sett you entered", sett.describe()),
            Some(SettUsed {
                sett,
                source: SettSource::File,
            }) => format!("{ends} ends at {}, from the file", sett.describe()),
            // Only the file's per-end spacing can give a width with no single sett.
            None if spacing.is_some_and(|s| !s.per_end.is_empty()) => {
                format!("{ends} ends, by the file's spacing of each end")
            }
            None => format!("{ends} ends"),
        };
        let Some(max) = self.loom.weaving_width else {
            let shown = describe_length(width, width.unit);
            let (phrase, _) = self.width_phrase(&shown, width, width.unit, &basis);
            let d = self.push(
                LoomCode::WidthUnknownLoom,
                LoomSeverity::NotChecked,
                "weaving width not recorded",
                format!(
                    "{name}'s weaving width is not recorded, so the width was not checked. \
                     {phrase}."
                ),
            );
            d.remediation = Some("Add the loom's weaving width in My looms.".into());
            return;
        };
        let unit = max.unit;
        let shown = describe_length(width, unit);
        let max_shown = describe_length(max, unit);
        let (phrase, joiner) = self.width_phrase(&shown, width, unit, &basis);
        // Compare in one unit, with a hair of tolerance for the unit conversion.
        if width.in_unit(unit) > max.value * (1.0 + 1e-9) {
            self.push(
                LoomCode::WidthExceeded,
                LoomSeverity::NotFeasible,
                format!("{shown} wide, weaves up to {max_shown}"),
                format!("{phrase}{joiner}{name} weaves up to {max_shown}."),
            )
            .remediation = Some("Use fewer ends or a closer sett, or a wider loom.".into());
        } else {
            self.push(
                LoomCode::WidthFits,
                LoomSeverity::Fits,
                format!("{shown} of {max_shown} wide"),
                format!("{phrase}{joiner}{name} weaves up to {max_shown}."),
            );
        }
    }

    /// "This draft is 20 in wide in the reed (240 ends at ...)", with the declared double-weave
    /// construction named: double width is checked FOLDED (its width in the reed), and opens to about
    /// twice that. Returns the phrase (no final period) and what joins it to the loom's limit: "; ",
    /// or ". " when the phrase already ends with a clause of its own.
    fn width_phrase(
        &self,
        shown: &str,
        width: Length,
        unit: Unit,
        basis: &str,
    ) -> (String, &'static str) {
        match self.draft.weft_work.construction {
            Some(Construction::DoubleWidth { fold }) => {
                let opened = describe_length(
                    Length {
                        value: width.in_unit(unit) * 2.0,
                        unit,
                    },
                    unit,
                );
                (
                    format!(
                        "Woven double width with the fold on the {}, this draft is {shown} wide in \
                         the reed, folded ({basis}); opened out, the cloth is about {opened}",
                        side_word(fold)
                    ),
                    ". ",
                )
            }
            Some(Construction::TwoLayers) => (
                format!(
                    "Woven as two layers, this draft is {shown} wide in the reed ({basis}); each \
                     layer is that wide"
                ),
                ". ",
            ),
            Some(Construction::Tube) => (
                format!(
                    "Woven as a tube, this draft is {shown} wide in the reed, flattened ({basis})"
                ),
                "; ",
            ),
            None => (
                format!("This draft is {shown} wide in the reed ({basis})"),
                "; ",
            ),
        }
    }

    fn reed(&mut self, sett: Option<SettUsed>, spacing: Option<&FileSpacing>) {
        let name = self.name.clone();
        if self.loom.reeds.is_empty() {
            self.push(
                LoomCode::ReedUnknown,
                LoomSeverity::NotChecked,
                "no reeds recorded",
                format!("No reeds are recorded for {name}, so no reed was chosen."),
            )
            .remediation = Some("Add your reeds in My looms.".into());
            return;
        }
        let Some(SettUsed { sett, .. }) = sett else {
            let why = if spacing.is_some_and(|s| !s.per_end.is_empty() || s.unusable_per_end) {
                "The file gives each end its own spacing, so there is no single sett to choose a \
                 reed for."
            } else {
                "The sett is not known, so no reed was chosen."
            };
            self.push(
                LoomCode::ReedNoSett,
                LoomSeverity::NotChecked,
                "sett not known",
                why.into(),
            )
            .remediation = Some("Enter a sett for this draft in Loom for this draft.".into());
            return;
        };
        let wanted = sett.describe();
        match best_sleying(&self.loom.reeds, sett) {
            Some(s) if s.pattern.len() == 1 && s.pattern[0] <= MAX_EVEN_PER_DENT => {
                let per = s.pattern[0];
                let message = if s.exact {
                    format!("Sley {} {per} per dent for {wanted}.", s.reed.describe())
                } else {
                    format!(
                        "Sley {} {per} per dent: {}, close to the {wanted} of this draft.",
                        s.reed.describe(),
                        s.achieved(sett.per)
                    )
                };
                self.push(
                    LoomCode::ReedFits,
                    LoomSeverity::Fits,
                    format!("{} reed, {per} per dent", reed_short(s.reed)),
                    message,
                );
            }
            Some(s) => {
                let order = s
                    .pattern
                    .iter()
                    .map(|n| n.to_string())
                    .collect::<Vec<_>>()
                    .join(", ");
                let for_sett = if s.exact {
                    format!("for {wanted}")
                } else {
                    format!("for {}, close to {wanted}", s.achieved(sett.per))
                };
                let message = if s.pattern.len() == 1 {
                    format!(
                        "Sley {} {} per dent {for_sett}; that many ends in one dent can mark the \
                         cloth, so a finer reed would be better.",
                        s.reed.describe(),
                        s.pattern[0]
                    )
                } else {
                    format!(
                        "No reed gives {wanted} with the same number of ends in every dent. Sley \
                         {} {order}, repeated across the warp, {for_sett}.",
                        s.reed.describe()
                    )
                };
                self.push(
                    LoomCode::ReedIrregular,
                    LoomSeverity::Advice,
                    format!("{} reed, sley {order}", reed_short(s.reed)),
                    message,
                );
            }
            None => {
                let needs: Vec<String> = self
                    .loom
                    .reeds
                    .iter()
                    .take(3)
                    .map(|r| {
                        format!(
                            "{} would need {} per dent",
                            r.describe(),
                            number(sett.per_inch() / r.dents_per_inch())
                        )
                    })
                    .collect();
                self.push(
                    LoomCode::ReedNoneFits,
                    LoomSeverity::Advice,
                    "no reed gives the sett",
                    format!(
                        "None of {name}'s reeds gives {wanted} with a regular sleying: {}.",
                        and_list(&needs)
                    ),
                )
                .remediation = Some("Sley it unevenly, or use another reed.".into());
            }
        }
    }
}

// ---------------------------------------------------------------------------------------------
// Reeds and sleying
// ---------------------------------------------------------------------------------------------

/// The most ends per dent that still counts as fitting (more can leave reed marks).
pub const MAX_EVEN_PER_DENT: u32 = 4;
/// The most ends in one dent Ply will suggest at all.
const MAX_PER_DENT: u32 = 6;
/// The longest repeating sleying order Ply looks for, in dents.
const MAX_ORDER_DENTS: u32 = 6;
/// How far the reed's sett may be from the draft's and still count as giving it.
const SETT_TOLERANCE: f64 = 0.02;

/// A way to sley one reed for a sett. Public so the warp planner (ADR 0019) makes the same choice
/// as the loom check.
#[derive(Debug, Clone, PartialEq)]
pub struct Sleying {
    pub reed: Reed,
    /// Ends in each dent of the repeating order, most first (one entry = the same in every dent).
    pub pattern: Vec<u32>,
    /// The sett it gives, in ends per inch.
    pub achieved_per_inch: f64,
    /// Whether that is the sett asked for (within 0.1%).
    pub exact: bool,
}

impl Sleying {
    /// The sett this sleying gives, in the reed's own unit and, for a metric reed, in `per` too.
    pub fn achieved(&self, per: Unit) -> String {
        match self.reed.per {
            DentUnit::PerInch => format!("{} ends per inch", number(self.achieved_per_inch)),
            DentUnit::Per10Cm => {
                let per_10cm = self.achieved_per_inch / CM_PER_INCH * 10.0;
                let other = match per {
                    Unit::Inches => format!("{} per inch", number(self.achieved_per_inch)),
                    Unit::Centimeters => {
                        format!("{} per cm", number(self.achieved_per_inch / CM_PER_INCH))
                    }
                };
                format!("{} ends per 10 cm (about {other})", number(per_10cm))
            }
        }
    }
}

/// The best way to sley one of `reeds` for `sett`, or `None` when none gives it (see ADR 0014): the
/// same number in every dent (1 to 4) first, then the shortest repeating order (up to 6 dents, most 4
/// per dent), then 5 or 6 per dent; ties go to the closer sett, then the reed listed first.
pub fn best_sleying(reeds: &[Reed], sett: Sett) -> Option<Sleying> {
    let want = sett.per_inch();
    if !(want.is_finite() && want > 0.0) {
        return None;
    }
    let mut best: Option<((u32, u32, u64), Sleying)> = None;
    for &reed in reeds {
        let dpi = reed.dents_per_inch();
        if !(dpi.is_finite() && dpi > 0.0) {
            continue;
        }
        let ratio = want / dpi; // ends per dent
        for dents in 1..=MAX_ORDER_DENTS {
            let ends = (ratio * f64::from(dents)).round();
            if ends < 1.0 || ends > f64::from(MAX_PER_DENT * dents) {
                continue;
            }
            let achieved = dpi * ends / f64::from(dents);
            let error = (achieved - want).abs() / want;
            if error > SETT_TOLERANCE {
                continue;
            }
            let pattern = order(ends as u32, dents);
            let most = pattern[0];
            if most > MAX_PER_DENT {
                continue;
            }
            let class = match (pattern.len(), most) {
                (1, m) if m <= MAX_EVEN_PER_DENT => 0,
                (_, m) if m <= MAX_EVEN_PER_DENT => 1,
                _ => 2,
            };
            let rank = (class, pattern.len() as u32, (error * 1e9) as u64);
            let candidate = Sleying {
                reed,
                pattern,
                achieved_per_inch: achieved,
                exact: error <= 0.001,
            };
            if best.as_ref().is_none_or(|(r, _)| rank < *r) {
                best = Some((rank, candidate));
            }
            break; // the shortest order for this reed
        }
    }
    best.map(|(_, s)| s)
}

/// `ends` spread over `dents` as evenly as possible, most first: 4 over 3 is 2, 1, 1; 1 over 2 is 1, 0.
/// A pattern that repeats exactly (2, 2) collapses to one dent.
fn order(ends: u32, dents: u32) -> Vec<u32> {
    let mut out: Vec<u32> = (0..dents)
        .map(|i| (i + 1) * ends / dents - i * ends / dents)
        .collect();
    out.sort_unstable_by(|a, b| b.cmp(a));
    if out.iter().all(|&n| n == out[0]) {
        out.truncate(1);
    }
    out
}

/// "12-dent" or "40/10" for a summary.
fn reed_short(reed: Reed) -> String {
    match reed.per {
        DentUnit::PerInch => format!("{}-dent", number(reed.dents)),
        DentUnit::Per10Cm => format!("{}/10", number(reed.dents)),
    }
}

// ---------------------------------------------------------------------------------------------
// Wording helpers
// ---------------------------------------------------------------------------------------------

/// "1 shaft", "4 shafts".
fn plural(n: usize, noun: &str) -> String {
    if n == 1 {
        format!("1 {noun}")
    } else {
        format!("{n} {noun}s")
    }
}

/// "a", "a and b", "a, b and c".
fn and_list(items: &[String]) -> String {
    match items {
        [] => String::new(),
        [one] => one.clone(),
        [init @ .., last] => format!("{} and {last}", init.join(", ")),
    }
}

/// The most numbers a sentence lists before "and N more".
const SHOWN_IN_TEXT: usize = 6;

/// "pick 4", "picks 3, 7 and 12", "picks 1, 2, 3, 4, 5, 6 and 10 more" for 1-based `numbers` out of
/// `total`.
fn numbers_phrase(one: &str, many: &str, numbers: &[u32], total: usize) -> String {
    let shown: Vec<String> = numbers
        .iter()
        .take(SHOWN_IN_TEXT)
        .map(|n| n.to_string())
        .collect();
    let noun = if total == 1 { one } else { many };
    let more = total.saturating_sub(shown.len());
    if more > 0 {
        format!("{noun} {} and {more} more", shown.join(", "))
    } else {
        format!("{noun} {}", and_list(&shown))
    }
}

/// [`numbers_phrase`] for 0-based picks.
fn picks_phrase(picks: &[usize]) -> String {
    let numbers: Vec<u32> = picks
        .iter()
        .take(SHOWN_IN_TEXT)
        .map(|&p| u32::try_from(p + 1).unwrap_or(u32::MAX))
        .collect();
    numbers_phrase("pick", "picks", &numbers, picks.len())
}

fn capitalize(s: &str) -> String {
    let mut chars = s.chars();
    match chars.next() {
        Some(c) => c.to_uppercase().chain(chars).collect(),
        None => String::new(),
    }
}

/// A location over 1-based `numbers` (already ascending), or `None` when there are none.
fn location(kind: LocationKind, numbers: &[u32]) -> Option<LoomLocation> {
    (!numbers.is_empty()).then(|| LoomLocation {
        kind,
        numbers: numbers.iter().copied().take(MAX_LOCATION_NUMBERS).collect(),
        total: numbers.len(),
    })
}

/// A pick location over 0-based `picks` (ascending).
fn pick_location(picks: &[usize]) -> Option<LoomLocation> {
    (!picks.is_empty()).then(|| LoomLocation {
        kind: LocationKind::Picks,
        numbers: picks
            .iter()
            .take(MAX_LOCATION_NUMBERS)
            .map(|&p| u32::try_from(p + 1).unwrap_or(u32::MAX))
            .collect(),
        total: picks.len(),
    })
}

/// "20 in", "50.8 cm": `length` shown in `unit`.
fn describe_length(length: Length, unit: Unit) -> String {
    let abbr = match unit {
        Unit::Inches => "in",
        Unit::Centimeters => "cm",
    };
    format!("{} {abbr}", number(length.in_unit(unit)))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::draft::{
        Liftplan, RetainedSection, ShaftId, Side, Threading, TieUp, TreadleId, Treadling,
    };
    use crate::loom::{DentUnit, Length, MAX_LOOM_SHAFTS};
    use crate::validate::{validate, Severity};
    use proptest::prelude::*;

    fn shafts(ids: &[u16]) -> Vec<ShaftId> {
        ids.iter().map(|&s| ShaftId(s)).collect()
    }

    /// A straight `n`-shaft twill (2 up), `ends` x `picks`, rising, with colors.
    fn twill(n: u16, ends: usize, picks: usize) -> Draft {
        let mut d = Draft::blank(n, n);
        d.threading = Threading::straight(ends, n);
        d.drive = Drive::Treadled {
            tieup: TieUp::twill(2, n - 2),
            treadling: Treadling(
                (0..picks)
                    .map(|p| vec![TreadleId((p % usize::from(n)) as u16 + 1)])
                    .collect(),
            ),
        };
        d.colors.warp = vec![0; ends];
        d.colors.weft = vec![1; picks];
        d
    }

    fn loom(kind: Option<LoomKind>, shafts: Option<u16>, treadles: Option<u16>) -> LoomProfile {
        LoomProfile {
            kind,
            shafts,
            treadles,
            ..LoomProfile::new("floor", "Floor loom")
        }
    }

    fn jack(shafts: u16, treadles: u16) -> LoomProfile {
        loom(Some(LoomKind::Jack), Some(shafts), Some(treadles))
    }

    fn find(r: &LoomReport, code: LoomCode) -> &LoomDiagnostic {
        r.diagnostics
            .iter()
            .find(|d| d.code == code)
            .unwrap_or_else(|| panic!("{} not in {:?}", code.as_str(), r.codes()))
    }

    fn with_spacing(mut d: Draft, spacing: &str) -> Draft {
        d.retained.push(RetainedSection {
            name: "WARP".into(),
            entries: vec![("Spacing".into(), spacing.into())],
        });
        d
    }

    #[test]
    fn eight_shafts_on_a_four_shaft_loom_is_not_feasible_but_structurally_valid() {
        let d = twill(8, 16, 16);
        assert!(validate(&d).iter().all(|i| i.severity != Severity::Error));
        let r = check(&d, &jack(4, 6), &LoomCheckInput::default());
        assert!(!r.feasible());
        let s = find(&r, LoomCode::ShaftsExceeded);
        assert_eq!(s.message, "This draft threads 8 shafts; Floor loom has 4.");
        assert_eq!(s.summary, "needs 8 shafts, has 4");
        assert_eq!(
            s.location,
            Some(LoomLocation {
                kind: LocationKind::Shafts,
                numbers: vec![5, 6, 7, 8],
                total: 4
            })
        );
        let t = find(&r, LoomCode::TreadlesExceeded);
        assert_eq!(t.message, "This draft uses 8 treadles; Floor loom has 6.");
        // The same draft fits an eight-shaft loom.
        let r = check(&d, &jack(8, 10), &LoomCheckInput::default());
        assert!(r.feasible(), "{:?}", r.codes());
        assert_eq!(
            find(&r, LoomCode::ShaftsFit).message,
            "This draft threads 8 shafts; Floor loom has 8."
        );
    }

    #[test]
    fn every_family_reports_once_in_order() {
        let d = with_spacing(twill(4, 40, 8), "0.1");
        let mut l = jack(4, 6);
        l.weaving_width = Some(Length {
            value: 20.0,
            unit: Unit::Inches,
        });
        l.reeds = vec![Reed {
            dents: 10.0,
            per: DentUnit::PerInch,
        }];
        l.treadles_at_once = Some(2);
        let r = check(&d, &l, &LoomCheckInput::default());
        assert_eq!(
            r.codes(),
            vec![
                "loom.shafts_fit",
                "loom.treadles_fit",
                "loom.treadles_at_once_fit",
                "loom.shed_fits",
                "loom.width_fits",
                "loom.reed_fits",
            ]
        );
        assert_eq!(
            find(&r, LoomCode::WidthFits).message,
            "This draft is 4 in wide in the reed (40 ends at 10 ends per inch, from the file); \
             Floor loom weaves up to 20 in."
        );
        assert_eq!(
            find(&r, LoomCode::ReedFits).message,
            "Sley the 10-dent reed 1 per dent for 10 ends per inch."
        );
        assert_eq!(r.file_sett.map(|s| s.ends), Some(10.0));
    }

    #[test]
    fn unknown_equipment_is_reported_as_not_checked_never_as_zero() {
        let d = twill(8, 16, 16);
        let r = check(&d, &loom(None, None, None), &LoomCheckInput::default());
        assert!(r.feasible(), "nothing unknown is treated as zero");
        let not_checked: Vec<&str> = r
            .diagnostics
            .iter()
            .filter(|d| d.severity == LoomSeverity::NotChecked)
            .map(|d| d.code.as_str())
            .collect();
        assert_eq!(
            not_checked,
            vec![
                "loom.shafts_unknown",
                "loom.treadles_unknown",
                "loom.shed_unknown",
                "loom.width_unknown_sett",
                "loom.reed_unknown",
            ]
        );
        assert_eq!(
            find(&r, LoomCode::ShaftsUnknown).message,
            "Floor loom's shaft count is not recorded, so the shafts were not checked. This draft \
             threads 8 shafts."
        );
        assert_eq!(
            find(&r, LoomCode::WidthUnknownSett).message,
            "The sett is not known, so the width was not checked: the file gives no warp \
             spacing. Floor loom's weaving width is not recorded either."
        );
    }

    #[test]
    fn sinking_tie_up_on_a_jack_loom_is_advice() {
        let d = twill(4, 8, 8).with_shed(ShedType::Sinking);
        let r = check(&d, &jack(4, 4), &LoomCheckInput::default());
        assert!(r.feasible());
        let a = find(&r, LoomCode::TieUpForSinkingShed);
        assert_eq!(a.severity, LoomSeverity::Advice);
        assert_eq!(
            a.message,
            "This draft's tie-up is written for a sinking shed (the marked shafts go down), but a \
             jack loom raises the shafts you tie."
        );
        assert_eq!(
            a.remediation.as_deref(),
            Some("Tie each treadle to the shafts its column leaves blank; the cloth is the same.")
        );
        // The reverse on a counterbalance.
        let cb = loom(Some(LoomKind::Counterbalance), Some(4), Some(4));
        let r = check(&twill(4, 8, 8), &cb, &LoomCheckInput::default());
        assert_eq!(
            find(&r, LoomCode::TieUpForRisingShed).severity,
            LoomSeverity::Advice
        );
        // A sinking draft on a counterbalance fits.
        let r = check(&d, &cb, &LoomCheckInput::default());
        assert!(r.codes().contains(&"loom.shed_fits"));
    }

    #[test]
    fn multi_treadle_picks_are_named_in_the_shed_advice_and_checked_against_the_feet() {
        let mut d = twill(4, 8, 4).with_shed(ShedType::Sinking);
        if let Drive::Treadled { treadling, .. } = &mut d.drive {
            treadling.0[2] = vec![TreadleId(1), TreadleId(3)];
        }
        let mut l = jack(4, 4);
        let r = check(&d, &l, &LoomCheckInput::default());
        let a = find(&r, LoomCode::TieUpForSinkingShed);
        assert!(
            a.remediation
                .as_deref()
                .unwrap()
                .ends_with("Pick 3 presses more than one treadle, and weaves differently that way, so check it."),
            "{:?}",
            a.remediation
        );
        assert_eq!(
            find(&r, LoomCode::TreadlesAtOnceUnknown).message,
            "Pick 3 presses 2 treadles together; how many treadles you press at once on Floor \
             loom is not recorded."
        );
        l.treadles_at_once = Some(1);
        let r = check(&d, &l, &LoomCheckInput::default());
        let x = find(&r, LoomCode::TreadlesAtOnceExceeded);
        assert_eq!(
            x.message,
            "Pick 3 presses 2 treadles together; on Floor loom you press at most 1 at once."
        );
        assert_eq!(x.location.as_ref().unwrap().numbers, vec![3]);
        l.kind = Some(LoomKind::Countermarch);
        l.treadles_at_once = Some(2);
        let r = check(&d, &l, &LoomCheckInput::default());
        assert!(r.codes().contains(&"loom.countermarch_skeleton"));
        assert!(r.codes().contains(&"loom.countermarch_tie_up"));
    }

    #[test]
    fn table_and_dobby_looms_work_from_the_lift_plan() {
        let d = twill(4, 8, 8);
        for kind in [LoomKind::Table, LoomKind::Dobby] {
            let r = check(
                &d,
                &loom(Some(kind), Some(4), None),
                &LoomCheckInput::default(),
            );
            assert!(r.feasible());
            assert!(r.codes().contains(&"loom.lift_plan_loom"));
            for gone in [
                "loom.treadles_unknown",
                "loom.treadles_at_once_fit",
                "loom.shed_fits",
            ] {
                assert!(!r.codes().contains(&gone), "{gone} on {kind:?}");
            }
        }
    }

    #[test]
    fn a_lift_plan_on_a_treadle_loom_needs_a_treadle_per_shed() {
        let d = twill(4, 8, 8).to_liftplan_draft();
        let r = check(&d, &jack(4, 4), &LoomCheckInput::default());
        assert_eq!(
            find(&r, LoomCode::LiftPlanShedsFit).message,
            "This draft is a lift plan with 4 different sheds. Floor loom has 4 treadles, so tie \
             one treadle for each shed, tied to the shafts that shed raises."
        );
        let r = check(&d, &jack(4, 3), &LoomCheckInput::default());
        assert_eq!(
            find(&r, LoomCode::LiftPlanShedsExceeded).summary,
            "needs 4 treadles, has 3"
        );
    }

    #[test]
    fn renumbering_and_unthreaded_lifts_are_advice() {
        let mut d = Draft::blank(8, 2);
        d.threading = Threading(vec![shafts(&[1]), shafts(&[2]), shafts(&[7]), shafts(&[8])]);
        d.drive = Drive::Liftplan(Liftplan(vec![shafts(&[1, 7]), shafts(&[2, 8])]));
        let r = check(&d, &jack(4, 4), &LoomCheckInput::default());
        assert!(r.feasible());
        assert_eq!(
            find(&r, LoomCode::ShaftsRenumber).message,
            "This draft threads shafts numbered up to 8, but only 4 different ones (1, 2, 7 and \
             8); Floor loom has 4."
        );
        let mut d = twill(4, 8, 4).to_liftplan_draft();
        if let Drive::Liftplan(lp) = &mut d.drive {
            lp.0[0].push(ShaftId(6));
        }
        let r = check(&d, &jack(4, 4), &LoomCheckInput::default());
        assert_eq!(
            find(&r, LoomCode::UnthreadedShaftsLifted).message,
            "The lift plan also names shaft 6, which threads no ends; Floor loom has 4 shafts, so \
             leave it out."
        );
    }

    #[test]
    fn unbalanced_sheds_on_a_counterbalance_are_advice() {
        // 1/3 twill: one shaft up, three down.
        let mut d = twill(4, 8, 4);
        d.drive = Drive::Treadled {
            tieup: TieUp::twill(1, 3),
            treadling: Treadling((1..=4).map(|t| vec![TreadleId(t)]).collect()),
        };
        let cb = loom(Some(LoomKind::Counterbalance), Some(4), Some(4));
        let r = check(&d, &cb, &LoomCheckInput::default());
        let u = find(&r, LoomCode::UnbalancedSheds);
        assert_eq!(u.severity, LoomSeverity::Advice);
        assert_eq!(
            u.message,
            "Picks 1, 2, 3 and 4 have an unbalanced shed (pick 1 raises 1 shaft and lowers 3). On \
             a counterbalance loom an unbalanced shed can open poorly."
        );
        // 2/2 twill is balanced.
        let r = check(&twill(4, 8, 4), &cb, &LoomCheckInput::default());
        assert!(r.codes().contains(&"loom.sheds_balanced"));
        // Sinking draft: the raised set is the complement, still balanced for 2/2.
        let r = check(
            &twill(4, 8, 4).with_shed(ShedType::Sinking),
            &cb,
            &LoomCheckInput::default(),
        );
        assert!(r.codes().contains(&"loom.sheds_balanced"));
    }

    #[test]
    fn width_exceeded_names_the_requirement_and_an_entered_sett_wins() {
        let d = with_spacing(twill(4, 480, 4), "0.0833333");
        let mut l = jack(4, 4);
        l.weaving_width = Some(Length {
            value: 36.0,
            unit: Unit::Inches,
        });
        let r = check(&d, &l, &LoomCheckInput::default());
        let w = find(&r, LoomCode::WidthExceeded);
        assert_eq!(
            w.message,
            "This draft is 40 in wide in the reed (480 ends at 12 ends per inch, from the file); \
             Floor loom weaves up to 36 in."
        );
        assert_eq!(w.summary, "40 in wide, weaves up to 36 in");
        let input = LoomCheckInput {
            sett: Some(Sett {
                ends: 16.0,
                per: Unit::Inches,
            }),
        };
        let r = check(&d, &l, &input);
        assert_eq!(
            find(&r, LoomCode::WidthFits).message,
            "This draft is 30 in wide in the reed (480 ends at 16 ends per inch, the sett you \
             entered); Floor loom weaves up to 36 in."
        );
        assert_eq!(r.sett.unwrap().source, SettSource::Entered);
        // A metric loom width: the draft's width is shown in the loom's unit.
        l.weaving_width = Some(Length {
            value: 90.0,
            unit: Unit::Centimeters,
        });
        let r = check(&d, &l, &input);
        assert!(find(&r, LoomCode::WidthFits)
            .message
            .contains("76.2 cm wide in the reed"));
    }

    #[test]
    fn double_width_is_checked_at_its_folded_width() {
        let mut d = with_spacing(
            crate::structure::double_weave(240, 8, Construction::DoubleWidth { fold: Side::Left }),
            "0.0416667",
        );
        d.colors.warp = vec![0; 240];
        let mut l = jack(4, 4);
        l.weaving_width = Some(Length {
            value: 15.0,
            unit: Unit::Inches,
        });
        let r = check(&d, &l, &LoomCheckInput::default());
        assert!(r.feasible(), "{:?}", r.codes());
        assert_eq!(
            find(&r, LoomCode::WidthFits).message,
            "Woven double width with the fold on the left, this draft is 10 in wide in the reed, \
             folded (240 ends at 24 ends per inch, from the file); opened out, the cloth is about \
             20 in. Floor loom weaves up to 15 in."
        );
    }

    #[test]
    fn two_layers_and_a_tube_are_named_and_checked_at_their_width_in_the_reed() {
        let mut l = jack(4, 4);
        l.weaving_width = Some(Length {
            value: 5.0,
            unit: Unit::Inches,
        });
        let at = |c: Construction| {
            let d = with_spacing(crate::structure::double_weave(96, 8, c), "0.0416667");
            find(
                &check(&d, &l, &LoomCheckInput::default()),
                LoomCode::WidthFits,
            )
            .message
            .clone()
        };
        assert_eq!(
            at(Construction::TwoLayers),
            "Woven as two layers, this draft is 4 in wide in the reed (96 ends at 24 ends per \
             inch, from the file); each layer is that wide. Floor loom weaves up to 5 in."
        );
        assert_eq!(
            at(Construction::Tube),
            "Woven as a tube, this draft is 4 in wide in the reed, flattened (95 ends at 24 ends \
             per inch, from the file); Floor loom weaves up to 5 in.",
            "a tube has an odd number of ends"
        );
    }

    #[test]
    fn per_end_spacing_sums_and_withholds_the_reed_choice() {
        let mut d = with_spacing(twill(4, 4, 4), "0.1");
        d.retained.push(RetainedSection {
            name: "WARP SPACING".into(),
            entries: vec![("1".into(), "0.2".into()), ("9".into(), "5".into())],
        });
        let mut l = jack(4, 4);
        l.weaving_width = Some(Length {
            value: 1.0,
            unit: Unit::Inches,
        });
        l.reeds = vec![Reed {
            dents: 10.0,
            per: DentUnit::PerInch,
        }];
        let r = check(&d, &l, &LoomCheckInput::default());
        assert_eq!(r.reed_width.map(|w| w.value), Some(0.5));
        assert!(find(&r, LoomCode::WidthFits)
            .message
            .contains("by the file's spacing of each end"));
        assert_eq!(
            find(&r, LoomCode::ReedNoSett).severity,
            LoomSeverity::NotChecked
        );
        assert_eq!(r.file_sett, None);
    }

    #[test]
    fn a_spacing_refused_as_a_sett_never_gives_a_width() {
        let mut l = jack(4, 4);
        l.weaving_width = Some(Length {
            value: 24.0,
            unit: Unit::Inches,
        });
        l.reeds = vec![Reed {
            dents: 12.0,
            per: DentUnit::PerInch,
        }];
        // Over 1000 ends per inch (or absurdly fine): not a sett, so no width either.
        for spacing in ["0.00001", "1e-300", "0.0005", "0", "-1", "nan"] {
            let r = check(
                &with_spacing(twill(4, 4, 4), spacing),
                &l,
                &LoomCheckInput::default(),
            );
            assert_eq!(r.file_sett, None, "{spacing}");
            assert_eq!(r.reed_width, None, "{spacing}");
            let w = find(&r, LoomCode::WidthUnknownSett);
            assert!(
                w.message
                    .ends_with("the file's warp spacing does not give a usable sett."),
                "{spacing}: {}",
                w.message
            );
            assert!(r.codes().contains(&"loom.reed_no_sett"), "{spacing}");
        }
        // A per-end value outside the range makes that end's width unknown: no fallback.
        let mut d = with_spacing(twill(4, 4, 4), "0.1");
        d.retained.push(RetainedSection {
            name: "WARP SPACING".into(),
            entries: vec![("2".into(), "0.00001".into())],
        });
        let r = check(&d, &l, &LoomCheckInput::default());
        assert_eq!(r.reed_width, None);
        assert!(find(&r, LoomCode::WidthUnknownSett)
            .message
            .contains("the file does not give every end a usable spacing"));
        // "each end" only when per-end values are used: a uniform file says "from the file".
        let r = check(
            &with_spacing(twill(4, 4, 4), "0.1"),
            &l,
            &LoomCheckInput::default(),
        );
        assert!(find(&r, LoomCode::WidthFits)
            .message
            .contains("from the file"));
    }

    #[test]
    fn decipoints_are_tenths_of_a_point_and_an_unknown_unit_is_no_spacing() {
        let warp = |entries: Vec<(&str, &str)>| {
            let mut d = twill(4, 24, 4);
            d.retained.push(RetainedSection {
                name: "WARP".into(),
                entries: entries
                    .into_iter()
                    .map(|(k, v)| (k.to_string(), v.to_string()))
                    .collect(),
            });
            d
        };
        let mut l = jack(4, 4);
        l.weaving_width = Some(Length {
            value: 24.0,
            unit: Unit::Inches,
        });
        // 30 decipoints = 30/720 in = 24 ends per inch; 24 ends are 1 in wide.
        let r = check(
            &warp(vec![("Units", "Decipoints"), ("Spacing", "30")]),
            &l,
            &LoomCheckInput::default(),
        );
        assert_eq!(
            find(&r, LoomCode::WidthFits).message,
            "This draft is 1 in wide in the reed (24 ends at 24 ends per inch, from the file); \
             Floor loom weaves up to 24 in."
        );
        // An inch value written under Decipoints gives an impossible sett: unknown, not a guess.
        let r = check(
            &warp(vec![("Units", "Decipoints"), ("Spacing", "0.0833")]),
            &l,
            &LoomCheckInput::default(),
        );
        assert!(r.codes().contains(&"loom.width_unknown_sett"));
        // A unit Ply does not know: no spacing at all.
        let r = check(
            &warp(vec![("Units", "Furlongs"), ("Spacing", "0.1")]),
            &l,
            &LoomCheckInput::default(),
        );
        assert_eq!(r.file_sett, None);
        assert!(r.codes().contains(&"loom.width_unknown_sett"));
        // A centimeter [WARP] in an inch draft is read in centimeters.
        let r = check(
            &warp(vec![("Units", "Centimeters"), ("Spacing", "0.25")]),
            &l,
            &LoomCheckInput::default(),
        );
        assert_eq!(
            r.file_sett,
            Some(Sett {
                ends: 4.0,
                per: Unit::Centimeters
            })
        );
        // Through the WIF reader: a decipoint file is kept as written and read the same way.
        let wif = crate::wif::write(&twill(4, 24, 4)).replace(
            "[WARP]\r\nThreads=24\r\nUnits=Inches\r\n",
            "[WARP]\r\nThreads=24\r\nUnits=Decipoints\r\nSpacing=30\r\n",
        );
        let d = crate::wif::parse(&wif).unwrap();
        let sett = file_sett(&d).expect("a decipoint sett");
        assert_eq!(sett.per, Unit::Inches);
        assert!((sett.ends - 24.0).abs() < 1e-9, "{}", sett.ends);
    }

    #[test]
    fn a_draft_with_no_picks_is_not_checked_for_treadles_or_balance() {
        let mut d = twill(4, 8, 0);
        d.colors.weft.clear();
        let cb = loom(Some(LoomKind::Counterbalance), Some(4), Some(4));
        let r = check(&d, &cb, &LoomCheckInput::default());
        let drive = find(&r, LoomCode::DriveEmpty);
        assert_eq!(drive.severity, LoomSeverity::NotChecked);
        assert_eq!(
            find(&r, LoomCode::BalanceNoSheds).severity,
            LoomSeverity::NotChecked
        );
        for vacuous in [
            "loom.sheds_balanced",
            "loom.treadles_fit",
            "loom.treadles_at_once_fit",
        ] {
            assert!(!r.codes().contains(&vacuous), "{vacuous}");
        }
        // A lift plan with no lifts is not checked either.
        let r = check(
            &d.to_liftplan_draft(),
            &jack(4, 4),
            &LoomCheckInput::default(),
        );
        assert!(r.codes().contains(&"loom.drive_empty"));
        assert!(!r.codes().contains(&"loom.lift_plan_sheds_fit"));
    }

    #[test]
    fn reed_choice_follows_the_sleying_rules() {
        let sett = |ends: f64| Sett {
            ends,
            per: Unit::Inches,
        };
        let reed = |dents: f64, per: DentUnit| Reed { dents, per };
        // Even sleying wins over a reed that needs an order.
        let s = best_sleying(
            &[reed(10.0, DentUnit::PerInch), reed(12.0, DentUnit::PerInch)],
            sett(24.0),
        )
        .unwrap();
        assert_eq!((s.reed.dents, s.pattern.clone()), (12.0, vec![2]));
        // 16 in a 12-dent reed is 2, 1, 1.
        let s = best_sleying(&[reed(12.0, DentUnit::PerInch)], sett(16.0)).unwrap();
        assert_eq!(s.pattern, vec![2, 1, 1]);
        // 22 in a 10-dent reed is 3, 2, 2, 2, 2.
        let s = best_sleying(&[reed(10.0, DentUnit::PerInch)], sett(22.0)).unwrap();
        assert_eq!(s.pattern, vec![3, 2, 2, 2, 2]);
        // 6 in a 12-dent reed skips every other dent.
        let s = best_sleying(&[reed(12.0, DentUnit::PerInch)], sett(6.0)).unwrap();
        assert_eq!(s.pattern, vec![1, 0]);
        // A 40/10 metric reed 2 per dent is about 20.3 per inch: close enough to 20.
        let s = best_sleying(&[reed(40.0, DentUnit::Per10Cm)], sett(20.0)).unwrap();
        assert_eq!(s.pattern, vec![2]);
        assert!(!s.exact);
        assert_eq!(
            s.achieved(Unit::Inches),
            "80 ends per 10 cm (about 20.3 per inch)"
        );
        // 19 in a 10-dent reed has no short order within 2%.
        assert_eq!(
            best_sleying(&[reed(10.0, DentUnit::PerInch)], sett(19.0)),
            None
        );
        assert_eq!(order(4, 2), vec![2]);
    }

    #[test]
    fn codes_are_stable_and_unique() {
        let strings: BTreeSet<&str> = LoomCode::ALL.iter().map(|c| c.as_str()).collect();
        assert_eq!(strings.len(), LoomCode::ALL.len());
        for c in LoomCode::ALL {
            assert!(c.as_str().starts_with("loom."));
            assert_eq!(LoomCode::parse(c.as_str()), Some(c));
        }
        // Pinned: these strings are a public contract (tests, UI keys, fixtures).
        assert_eq!(LoomCode::ShaftsExceeded.as_str(), "loom.shafts_exceeded");
        assert_eq!(LoomCode::WidthExceeded.as_str(), "loom.width_exceeded");
        assert_eq!(
            LoomCode::TieUpForSinkingShed.as_str(),
            "loom.tie_up_for_sinking_shed"
        );
    }

    #[test]
    fn structural_errors_do_not_stop_the_loom_check() {
        let mut d = twill(4, 8, 8);
        d.threading.0[0] = shafts(&[0, 9]); // shaft 0 and a shaft past the header
        if let Drive::Treadled { treadling, .. } = &mut d.drive {
            treadling.0[0] = vec![TreadleId(0), TreadleId(40)];
        }
        assert!(validate(&d).iter().any(|i| i.severity == Severity::Error));
        let r = check(&d, &jack(8, 8), &LoomCheckInput::default());
        assert!(r.codes().contains(&"loom.shafts_renumber"));
        // No loom code appears among the structural messages, and no structural message here.
        assert!(validate(&d)
            .iter()
            .all(|i| !i.message.contains("Floor loom")));
        assert!(r
            .diagnostics
            .iter()
            .all(|d| !d.message.contains("outside 1..=")));
    }

    fn arb_profile() -> impl Strategy<Value = LoomProfile> {
        (
            prop::option::of(prop::sample::select(vec![
                LoomKind::Jack,
                LoomKind::Counterbalance,
                LoomKind::Countermarch,
                LoomKind::Table,
                LoomKind::Dobby,
            ])),
            prop::option::of(1u16..=MAX_LOOM_SHAFTS),
            prop::option::of(1u16..=40),
            prop::option::of(0.1f64..200.0),
            prop::collection::vec((0.5f64..100.0, any::<bool>()), 0..4),
            prop::option::of(1u8..=4),
        )
            .prop_map(
                |(kind, shafts, treadles, width, reeds, at_once)| LoomProfile {
                    kind,
                    shafts,
                    treadles,
                    weaving_width: width.map(|value| Length {
                        value,
                        unit: Unit::Inches,
                    }),
                    reeds: reeds
                        .into_iter()
                        .map(|(dents, metric)| Reed {
                            dents,
                            per: if metric {
                                DentUnit::Per10Cm
                            } else {
                                DentUnit::PerInch
                            },
                        })
                        .collect(),
                    treadles_at_once: at_once,
                    ..LoomProfile::new("p", "Prop loom")
                },
            )
    }

    fn arb_draft() -> impl Strategy<Value = Draft> {
        (
            prop::collection::vec(prop::collection::vec(0u16..12, 0..3), 0..24),
            prop::collection::vec(prop::collection::vec(0u16..12, 0..3), 0..10),
            prop::collection::vec(prop::collection::vec(0u16..12, 0..4), 0..24),
            any::<bool>(),
            any::<bool>(),
            prop::option::of(prop::sample::select(vec![
                "0.1", "0", "-1", "nan", "abc", "1e308", "0.05",
            ])),
        )
            .prop_map(|(threading, tieup, picks, liftplan, sinking, spacing)| {
                let mut d = Draft::blank(8, tieup.len() as u16);
                d.threading = Threading(threading.iter().map(|e| shafts(e)).collect());
                d.drive = if liftplan {
                    Drive::Liftplan(Liftplan(picks.iter().map(|r| shafts(r)).collect()))
                } else {
                    Drive::Treadled {
                        tieup: TieUp(tieup.iter().map(|r| shafts(r)).collect()),
                        treadling: Treadling(
                            picks
                                .iter()
                                .map(|r| r.iter().map(|&t| TreadleId(t)).collect())
                                .collect(),
                        ),
                    }
                };
                if sinking {
                    d.shed = ShedType::Sinking;
                }
                if let Some(s) = spacing {
                    d = with_spacing(d, s);
                }
                d
            })
    }

    proptest! {
        /// Any profile against any (even malformed) draft: no panic, exactly one shafts outcome and
        /// one width outcome, every code unique per report, and a NotChecked line wherever an input
        /// is unknown.
        #[test]
        fn never_panics_and_unknown_is_never_zero(d in arb_draft(), l in arb_profile(),
                                                   sett in prop::option::of(0.0f64..60.0)) {
            let input = LoomCheckInput { sett: sett.map(|ends| Sett { ends, per: Unit::Inches }) };
            let r = check(&d, &l, &input);
            let codes = r.codes();
            let unique: BTreeSet<&str> = codes.iter().copied().collect();
            prop_assert_eq!(unique.len(), codes.len());
            let shafts_family = [
                "loom.shafts_exceeded", "loom.shafts_renumber", "loom.shafts_fit",
                "loom.shafts_unknown", "loom.threading_empty",
            ];
            prop_assert_eq!(codes.iter().filter(|c| shafts_family.contains(c)).count(), 1);
            let width_family = [
                "loom.width_exceeded", "loom.width_fits", "loom.width_unknown_loom",
                "loom.width_unknown_sett", "loom.width_no_ends",
            ];
            prop_assert_eq!(codes.iter().filter(|c| width_family.contains(c)).count(), 1);
            if l.shafts.is_none() && d.threading.0.iter().flatten().any(|s| s.0 >= 1) {
                prop_assert!(codes.contains(&"loom.shafts_unknown"));
                prop_assert!(!codes.contains(&"loom.shafts_exceeded"));
            }
            if l.weaving_width.is_none() && d.ends() > 0 {
                prop_assert!(!codes.contains(&"loom.width_exceeded"));
            }
            if l.reeds.is_empty() {
                prop_assert!(codes.contains(&"loom.reed_unknown"));
            }
            for diag in &r.diagnostics {
                prop_assert!(!diag.message.is_empty() && !diag.summary.is_empty());
                prop_assert!(!diag.message.contains('\u{2014}'), "no em-dash");
                if let Some(loc) = &diag.location {
                    prop_assert!(loc.numbers.len() <= MAX_LOCATION_NUMBERS);
                    prop_assert!(loc.numbers.iter().all(|&n| n >= 1));
                }
            }
        }
    }
}
