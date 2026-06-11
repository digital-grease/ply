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
use ply_common::Unit;

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
}
