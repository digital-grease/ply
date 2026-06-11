//! The weaving draft model.
//!
//! A `Draft` is the editable, round-trippable document. It mirrors the structure of a
//! WIF file so import/export is lossless for the data we support.
//!
//! Key design decisions (see `docs/DATA_MODEL.md`):
//!  * IDs are **1-based** newtypes (`ShaftId`, `TreadleId`) to match how weavers and WIF
//!    count, eliminating off-by-one bugs at the format boundary.
//!  * A draft is driven by **either** a tie-up + treadling **or** a direct liftplan,
//!    modeled as the `Drive` enum. `to_liftplan` always works; factoring a liftplan back
//!    into a tie-up is best-effort and deferred.
//!  * Shed direction is handled in exactly one place — `Draft::raised_shafts` — which
//!    yields the canonical "set of raised shafts per pick" the drawdown consumes.

use serde::{Deserialize, Serialize};
use ply_common::{Color, Unit};

/// 1-based shaft (harness) identifier.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
pub struct ShaftId(pub u16);

/// 1-based treadle identifier.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
pub struct TreadleId(pub u16);

/// Index into a draft's color palette (0-based internally; WIF's 1-based indices are
/// converted at the format boundary).
pub type ColorIndex = usize;

/// Which way the loom moves the shafts named in the tie-up / liftplan.
/// `Rising` = named shafts go up (warp lifts above weft). `Sinking` = named shafts go down.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ShedType {
    Rising,
    Sinking,
}

/// Threading: for each warp end (in warp order), the shaft(s) it passes through.
/// Empty = an unthreaded (skipped) end, which is legal. Almost always exactly one shaft.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Threading(pub Vec<Vec<ShaftId>>);

impl Threading {
    pub fn ends(&self) -> usize {
        self.0.len()
    }
}

/// Tie-up: for each treadle (in order), the set of shafts it is tied to.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TieUp(pub Vec<Vec<ShaftId>>);

impl TieUp {
    pub fn treadles(&self) -> usize {
        self.0.len()
    }

    /// Shafts tied to a given 1-based treadle, or empty if out of range.
    pub fn shafts_for(&self, t: TreadleId) -> &[ShaftId] {
        self.0
            .get((t.0 as usize).wrapping_sub(1))
            .map(|v| v.as_slice())
            .unwrap_or(&[])
    }
}

/// Treadling: for each weft pick (in order), the treadle(s) pressed.
/// Multiple treadles per pick is legal.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Treadling(pub Vec<Vec<TreadleId>>);

impl Treadling {
    pub fn picks(&self) -> usize {
        self.0.len()
    }
}

/// Liftplan: for each weft pick, the shafts raised directly. Used by table and dobby looms.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Liftplan(pub Vec<Vec<ShaftId>>);

impl Liftplan {
    pub fn picks(&self) -> usize {
        self.0.len()
    }
}

/// How the raised-shaft pattern per pick is specified.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum Drive {
    Treadled { tieup: TieUp, treadling: Treadling },
    Liftplan(Liftplan),
}

impl Drive {
    pub fn picks(&self) -> usize {
        match self {
            Drive::Treadled { treadling, .. } => treadling.picks(),
            Drive::Liftplan(lp) => lp.picks(),
        }
    }
}

/// Per-thread color assignments referencing the palette.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ColorPlan {
    pub palette: Vec<ply_common::Color>,
    /// One entry per warp end; should match `Threading::ends`.
    pub warp: Vec<ColorIndex>,
    /// One entry per weft pick; should match `Drive::picks`.
    pub weft: Vec<ColorIndex>,
}

impl ColorPlan {
    /// Remap any warp/weft color index that points past the end of the palette back to 0.
    /// Used after removing a palette color so no reference dangles — the renderer would
    /// otherwise silently substitute white (`render_rgba` does `palette.get(idx)`), which
    /// `validate()` historically did not catch. Returns how many indices were remapped.
    /// (A precise "remove index k and shift the rest down" lives in the editor's remove
    /// reducer; this is the safety net.)
    pub fn clamp_to_palette(&mut self) -> usize {
        let len = self.palette.len();
        let mut remapped = 0;
        for idx in self.warp.iter_mut().chain(self.weft.iter_mut()) {
            if *idx >= len {
                *idx = 0; // 0 is in range whenever the palette is non-empty
                remapped += 1;
            }
        }
        remapped
    }
}

/// A complete weaving draft — the editable, round-trippable document.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Draft {
    pub name: String,
    pub shafts: u16,
    pub treadles: u16,
    pub shed: ShedType,
    pub unit: Unit,
    pub threading: Threading,
    pub drive: Drive,
    pub colors: ColorPlan,
    pub notes: String,
}

impl Draft {
    /// A minimal, valid draft to start editing from scratch. Rising shed, inches, no warp
    /// ends or picks yet, an empty tie-up sized to `treadles` (so the header matches), and a
    /// 2-color palette (white, black) so the default color index 0 is always in range.
    pub fn blank(shafts: u16, treadles: u16) -> Draft {
        Draft {
            name: String::new(),
            shafts,
            treadles,
            shed: ShedType::Rising,
            unit: Unit::Inches,
            threading: Threading(Vec::new()),
            drive: Drive::Treadled {
                tieup: TieUp(vec![Vec::new(); treadles as usize]),
                treadling: Treadling(Vec::new()),
            },
            colors: ColorPlan {
                palette: vec![Color::WHITE, Color::BLACK],
                warp: Vec::new(),
                weft: Vec::new(),
            },
            notes: String::new(),
        }
    }

    pub fn ends(&self) -> usize {
        self.threading.ends()
    }

    pub fn picks(&self) -> usize {
        self.drive.picks()
    }

    /// The canonical form the drawdown consumes: the set of **raised shafts** for a given
    /// 0-based pick, already accounting for shed direction. This is the *only* place shed
    /// logic lives.
    ///
    /// * Liftplan lists raised shafts directly; shed type does not invert it.
    /// * Treadled = union of shafts tied to the pressed treadles. On a **sinking** shed the
    ///   tie-up names the shafts that go *down*, so the raised set is the complement within
    ///   `1..=shafts`.
    pub fn raised_shafts(&self, pick: usize) -> Vec<ShaftId> {
        match &self.drive {
            Drive::Liftplan(lp) => lp.0.get(pick).cloned().unwrap_or_default(),
            Drive::Treadled { tieup, treadling } => {
                let mut set: Vec<ShaftId> = Vec::new();
                if let Some(treadles) = treadling.0.get(pick) {
                    for &t in treadles {
                        for &s in tieup.shafts_for(t) {
                            if !set.contains(&s) {
                                set.push(s);
                            }
                        }
                    }
                }
                match self.shed {
                    ShedType::Rising => set,
                    ShedType::Sinking => (1..=self.shafts)
                        .map(ShaftId)
                        .filter(|s| !set.contains(s))
                        .collect(),
                }
            }
        }
    }

    /// Normalize any drive into a direct liftplan of raised shafts (rising-shed semantics).
    /// Always lossless in the "what gets raised" sense; handy for export to dobby formats
    /// or for engines that only understand liftplans.
    pub fn to_liftplan(&self) -> Liftplan {
        Liftplan((0..self.picks()).map(|p| self.raised_shafts(p)).collect())
    }

    /// A canonical **liftplan-driven** copy of this draft. The drawdown is unchanged: the
    /// raised-shaft set per pick is baked in via `to_liftplan` (so a sinking-shed tie-up is
    /// already complemented). Because a liftplan names raised shafts *directly*, the shed
    /// becomes `Rising` (no further inversion) and `treadles` drops to 0 (a liftplan carries
    /// no tie-up). The reverse — factoring a liftplan back into a tie-up — is deferred.
    pub fn to_liftplan_draft(&self) -> Draft {
        Draft {
            drive: Drive::Liftplan(self.to_liftplan()),
            shed: ShedType::Rising,
            treadles: 0,
            ..self.clone()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::validate::{validate, Severity};

    #[test]
    fn blank_is_valid_and_empty() {
        let d = Draft::blank(4, 4);
        assert_eq!(d.shafts, 4);
        assert_eq!(d.treadles, 4);
        assert_eq!(d.ends(), 0);
        assert_eq!(d.picks(), 0);
        assert_eq!(d.colors.palette.len(), 2);
        // A blank draft must carry zero Error-severity issues so "new draft" opens clean.
        let issues = validate(&d);
        assert!(
            issues.iter().all(|i| i.severity != Severity::Error),
            "blank draft had errors: {issues:?}"
        );
    }

    #[test]
    fn to_liftplan_draft_preserves_raised_shafts() {
        // A sinking-shed treadled draft is the interesting case: the tie-up names the shafts
        // that sink, so `raised_shafts` complements them. The liftplan copy must render the
        // SAME cloth — equal raised set per pick — while flipping to a Rising, tie-up-free form.
        let d = Draft {
            name: "t".into(),
            shafts: 4,
            treadles: 2,
            shed: ShedType::Sinking,
            unit: Unit::Inches,
            threading: Threading(vec![vec![ShaftId(1)], vec![ShaftId(2)]]),
            drive: Drive::Treadled {
                tieup: TieUp(vec![vec![ShaftId(1), ShaftId(2)], vec![ShaftId(3)]]),
                treadling: Treadling(vec![vec![TreadleId(1)], vec![TreadleId(2)], vec![]]),
            },
            colors: ColorPlan {
                palette: vec![Color::WHITE, Color::BLACK],
                warp: vec![0, 1],
                weft: vec![1, 0, 1],
            },
            notes: String::new(),
        };
        let lp = d.to_liftplan_draft();
        assert!(matches!(lp.drive, Drive::Liftplan(_)));
        assert_eq!(lp.shed, ShedType::Rising);
        assert_eq!(lp.treadles, 0);
        assert_eq!(lp.picks(), d.picks());
        for p in 0..d.picks() {
            assert_eq!(lp.raised_shafts(p), d.raised_shafts(p), "pick {p} differs");
        }
    }

    #[test]
    fn clamp_remaps_out_of_range_color_indices() {
        let mut cp = ColorPlan {
            palette: vec![Color::WHITE, Color::BLACK],
            warp: vec![0, 5, 1],
            weft: vec![9, 0],
        };
        let remapped = cp.clamp_to_palette();
        assert_eq!(remapped, 2);
        assert_eq!(cp.warp, vec![0, 0, 1]);
        assert_eq!(cp.weft, vec![0, 0]);
        // Idempotent: a second clamp finds nothing to fix.
        assert_eq!(cp.clamp_to_palette(), 0);
    }
}
