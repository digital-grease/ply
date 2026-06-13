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

    /// A copy with palette entry `idx` removed and EVERY warp/weft reference remapped so none
    /// dangles: an entry equal to `idx` falls back to `0` (the first remaining color), an entry past
    /// `idx` shifts down by one (the palette renumbers behind it), an entry before `idx` is
    /// unchanged. This is the PRECISE remove the `clamp_to_palette` safety net alluded to. `Err` if
    /// `idx` is out of range, or if the palette has only one color (a draft needs >= 1 color).
    pub fn with_color_removed(&self, idx: usize) -> Result<ColorPlan, String> {
        if idx >= self.palette.len() {
            return Err(format!(
                "color index {} out of range 0..{}",
                idx,
                self.palette.len()
            ));
        }
        if self.palette.len() <= 1 {
            return Err("cannot remove the last palette color".to_string());
        }
        let remap = |e: ColorIndex| -> ColorIndex {
            if e == idx {
                0
            } else if e > idx {
                e - 1
            } else {
                e
            }
        };
        let mut palette = self.palette.clone();
        palette.remove(idx);
        let mut out = ColorPlan {
            palette,
            warp: self.warp.iter().map(|&e| remap(e)).collect(),
            weft: self.weft.iter().map(|&e| remap(e)).collect(),
        };
        // The remap fixes references to the REMOVED color, but a PRE-EXISTING dangling index (e.g. a
        // malformed WIF import) merely decrements and would still dangle. Clamp so the result is
        // UNCONDITIONALLY validate()-clean, not just "clean if the input was".
        out.clamp_to_palette();
        Ok(out)
    }
}

/// A WIF `[SECTION]` Ply does not model (e.g. `[WARP THICKNESS]`, a vendor section), kept verbatim
/// on import so `write` can re-emit it — closing the lossy-save gap for sections Ply ignores. `name`
/// is the section header without brackets; `entries` are its raw `key=value` pairs, in order.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RetainedSection {
    pub name: String,
    pub entries: Vec<(String, String)>,
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
    /// Unmodeled WIF sections kept verbatim for round-trip fidelity (see [`RetainedSection`]).
    /// Carried through cosmetic edits; a resize drops the per-thread WARP/WEFT ones on a changing
    /// axis (their rows would desync). Empty for a from-scratch draft.
    pub retained: Vec<RetainedSection>,
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
            retained: Vec::new(),
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

    /// A copy resized to the given dimensions. GROWING pads with blanks (empty threading / empty
    /// picks / color index 0); SHRINKING truncates AND prunes every shaft/treadle reference the
    /// new, smaller header no longer has, so a resize NEVER leaves a dangling reference the user
    /// must hand-fix (the resized draft `validate()`s with no new `Error`). Warp/weft color
    /// lengths stay coupled (`warp.len() == ends`, `weft.len() == picks`). The palette is
    /// untouched. This is the canonical, tested resize the editor's resize reducer routes through.
    pub fn resized(&self, ends: usize, picks: usize, shafts: u16, treadles: u16) -> Draft {
        let threading = Threading(
            resize_rows(&self.threading.0, ends, Vec::new)
                .into_iter()
                .map(|row| prune_shafts(row, shafts))
                .collect(),
        );

        let drive = match &self.drive {
            Drive::Treadled { tieup, treadling } => Drive::Treadled {
                tieup: TieUp(
                    resize_rows(&tieup.0, treadles as usize, Vec::new)
                        .into_iter()
                        .map(|row| prune_shafts(row, shafts))
                        .collect(),
                ),
                treadling: Treadling(
                    resize_rows(&treadling.0, picks, Vec::new)
                        .into_iter()
                        .map(|row| prune_treadles(row, treadles))
                        .collect(),
                ),
            },
            Drive::Liftplan(lp) => Drive::Liftplan(Liftplan(
                resize_rows(&lp.0, picks, Vec::new)
                    .into_iter()
                    .map(|row| prune_shafts(row, shafts))
                    .collect(),
            )),
        };

        // Retained unmodeled sections: DROP the per-thread WARP/WEFT ones (e.g. `[WARP THICKNESS]`)
        // whose axis count is changing — their one-row-per-thread data would desync the new count.
        // Keep global/vendor sections and per-thread sections on an unchanged axis. Correctness over
        // fidelity: an unprefixed per-thread section is kept (we cannot tell its axis).
        let (old_ends, old_picks) = (self.ends(), self.picks());
        let retained = self
            .retained
            .iter()
            .filter(|s| {
                let up = s.name.to_uppercase();
                !((up.starts_with("WARP ") && ends != old_ends)
                    || (up.starts_with("WEFT ") && picks != old_picks))
            })
            .cloned()
            .collect();

        Draft {
            name: self.name.clone(),
            shafts,
            treadles,
            shed: self.shed,
            unit: self.unit,
            threading,
            drive,
            colors: ColorPlan {
                palette: self.colors.palette.clone(),
                warp: resize_rows(&self.colors.warp, ends, || 0),
                weft: resize_rows(&self.colors.weft, picks, || 0),
            },
            notes: self.notes.clone(),
            retained,
        }
    }

    /// A copy with palette color `idx` removed and all warp/weft references safely remapped (see
    /// [`ColorPlan::with_color_removed`]), so the result `validate()`s with NO dangling-index issue.
    /// The canonical, tested palette-remove the editor's remove reducer routes through. `Err` if
    /// `idx` is out of range or the palette has only one color.
    pub fn with_color_removed(&self, idx: usize) -> Result<Draft, String> {
        Ok(Draft {
            colors: self.colors.with_color_removed(idx)?,
            ..self.clone()
        })
    }
}

/// First `len` of `rows`, padding with `pad()` when growing (truncating when shrinking).
fn resize_rows<T: Clone>(rows: &[T], len: usize, pad: impl FnMut() -> T) -> Vec<T> {
    let mut out: Vec<T> = rows.iter().take(len).cloned().collect();
    out.resize_with(len, pad);
    out
}

/// Keep only shafts in `1..=shafts` (drops dangling references on a shrink).
fn prune_shafts(row: Vec<ShaftId>, shafts: u16) -> Vec<ShaftId> {
    row.into_iter().filter(|s| s.0 >= 1 && s.0 <= shafts).collect()
}

/// Keep only treadles in `1..=treadles`.
fn prune_treadles(row: Vec<TreadleId>, treadles: u16) -> Vec<TreadleId> {
    row.into_iter().filter(|t| t.0 >= 1 && t.0 <= treadles).collect()
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
            retained: Vec::new(),
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

    /// Removing a REFERENCED middle color renumbers the survivors and falls the removed refs back to
    /// 0, so nothing dangles and the cloth re-colors predictably.
    #[test]
    fn remove_color_renumbers_and_falls_back() {
        let cp = ColorPlan {
            palette: vec![Color::WHITE, Color::BLACK, Color::rgb(255, 0, 0)],
            warp: vec![0, 1, 2], // white, black, red
            weft: vec![2, 1, 0],
        };
        let out = cp.with_color_removed(1).unwrap(); // drop BLACK (idx 1)
        assert_eq!(out.palette, vec![Color::WHITE, Color::rgb(255, 0, 0)]);
        // 0 stays 0; 1 (removed) -> 0; 2 -> 1.
        assert_eq!(out.warp, vec![0, 0, 1]);
        assert_eq!(out.weft, vec![1, 0, 0]);
    }

    /// Removing index 0 (the fallback target) still renumbers correctly: removed AND next both land
    /// on the new index 0.
    #[test]
    fn remove_first_color_is_safe() {
        let cp = ColorPlan {
            palette: vec![Color::WHITE, Color::BLACK, Color::rgb(255, 0, 0)],
            warp: vec![0, 1, 2],
            weft: vec![],
        };
        let out = cp.with_color_removed(0).unwrap();
        assert_eq!(out.palette, vec![Color::BLACK, Color::rgb(255, 0, 0)]);
        // 0 (removed) -> 0; 1 -> 0; 2 -> 1.
        assert_eq!(out.warp, vec![0, 0, 1]);
    }

    /// A remove leaves NO dangling index — `validate()` reports no color Error afterward.
    #[test]
    fn remove_color_keeps_validate_clean() {
        let d = Draft {
            name: "c".into(),
            shafts: 2,
            treadles: 0,
            shed: ShedType::Rising,
            unit: Unit::Inches,
            threading: Threading(vec![vec![ShaftId(1)], vec![ShaftId(2)]]),
            drive: Drive::Liftplan(Liftplan(vec![vec![ShaftId(1)], vec![ShaftId(2)]])),
            colors: ColorPlan {
                palette: vec![Color::WHITE, Color::BLACK, Color::rgb(255, 0, 0)],
                warp: vec![2, 1],
                weft: vec![0, 2],
            },
            notes: String::new(),
            retained: Vec::new(),
        };
        let removed = d.with_color_removed(2).unwrap(); // drop RED (referenced by warp[0], weft[1])
        assert_eq!(removed.colors.palette.len(), 2);
        assert!(
            crate::validate::validate(&removed)
                .iter()
                .all(|i| !i.message.contains("color")),
            "no color issue after remove, got {:?}",
            crate::validate::validate(&removed)
        );
    }

    /// A PRE-EXISTING dangling index (a malformed import) is cleaned by the remove, not just left
    /// decremented-but-still-dangling, so the result is unconditionally validate-clean.
    #[test]
    fn remove_color_clamps_a_preexisting_dangle() {
        let cp = ColorPlan {
            palette: vec![Color::WHITE, Color::BLACK, Color::rgb(255, 0, 0)],
            warp: vec![9, 0], // index 9 already dangles (palette len 3)
            weft: vec![2],
        };
        let out = cp.with_color_removed(0).unwrap(); // palette -> len 2
        assert!(out.warp.iter().all(|&e| e < out.palette.len()), "no warp dangle: {:?}", out.warp);
        assert!(out.weft.iter().all(|&e| e < out.palette.len()), "no weft dangle: {:?}", out.weft);
    }

    #[test]
    fn remove_color_rejects_bad_index_and_last_color() {
        let cp = ColorPlan {
            palette: vec![Color::WHITE, Color::BLACK],
            warp: vec![0, 1],
            weft: vec![],
        };
        assert!(cp.with_color_removed(2).is_err(), "out-of-range index rejected");
        let one = ColorPlan {
            palette: vec![Color::WHITE],
            warp: vec![0],
            weft: vec![0],
        };
        assert!(one.with_color_removed(0).is_err(), "removing the last color rejected");
    }

    /// A 4-shaft, 4-treadle straight-draw treadled draft for resize tests.
    fn resize_fixture() -> Draft {
        Draft {
            name: "t".into(),
            shafts: 4,
            treadles: 4,
            shed: ShedType::Rising,
            unit: Unit::Inches,
            threading: Threading(vec![
                vec![ShaftId(1)],
                vec![ShaftId(2)],
                vec![ShaftId(3)],
                vec![ShaftId(4)],
            ]),
            drive: Drive::Treadled {
                tieup: TieUp(vec![
                    vec![ShaftId(1)],
                    vec![ShaftId(2)],
                    vec![ShaftId(3)],
                    vec![ShaftId(4)],
                ]),
                treadling: Treadling(vec![
                    vec![TreadleId(1)],
                    vec![TreadleId(2)],
                    vec![TreadleId(3)],
                    vec![TreadleId(4)],
                ]),
            },
            colors: ColorPlan {
                palette: vec![Color::WHITE, Color::BLACK],
                warp: vec![0, 0, 0, 0],
                weft: vec![1, 1, 1, 1],
            },
            notes: String::new(),
            retained: Vec::new(),
        }
    }

    fn no_errors(d: &Draft) -> bool {
        validate(d).iter().all(|i| i.severity != Severity::Error)
    }

    #[test]
    fn resize_grows_ends_and_picks_padding_blanks() {
        let d = resize_fixture().resized(6, 5, 4, 4);
        assert_eq!(d.ends(), 6);
        assert_eq!(d.picks(), 5);
        assert_eq!(d.threading.0[5], Vec::<ShaftId>::new(), "new end is unthreaded");
        assert_eq!(d.colors.warp.len(), 6);
        assert_eq!(d.colors.warp[5], 0, "new warp color padded with index 0");
        assert_eq!(d.colors.weft.len(), 5);
        assert_eq!(d.colors.weft[4], 0);
        assert!(no_errors(&d));
    }

    #[test]
    fn resize_shrinks_shafts_prunes_dangling_refs_and_validates_clean() {
        let d = resize_fixture().resized(4, 4, 2, 4); // shafts 4 -> 2
        assert_eq!(d.shafts, 2);
        // Ends 3,4 threaded shafts 3,4 -> pruned to unthreaded.
        assert!(d.threading.0[2].is_empty());
        assert!(d.threading.0[3].is_empty());
        if let Drive::Treadled { tieup, .. } = &d.drive {
            assert!(tieup.0[2].is_empty(), "treadle 3's tie to shaft 3 pruned");
            assert!(tieup.0[3].is_empty());
        } else {
            panic!("expected treadled");
        }
        assert!(no_errors(&d), "a shrink must never leave a dangling-shaft Error: {:?}", validate(&d));
    }

    #[test]
    fn resize_shrinks_treadles_prunes_treadling_and_truncates_tieup() {
        let d = resize_fixture().resized(4, 4, 4, 2); // treadles 4 -> 2
        assert_eq!(d.treadles, 2);
        if let Drive::Treadled { tieup, treadling } = &d.drive {
            assert_eq!(tieup.0.len(), 2, "tie-up truncated to the treadle count");
            assert!(treadling.0[2].is_empty(), "pick 3's press of treadle 3 pruned");
            assert!(treadling.0[3].is_empty());
        } else {
            panic!("expected treadled");
        }
        assert!(no_errors(&d));
    }

    #[test]
    fn resize_keeps_warp_weft_lengths_coupled() {
        let d = resize_fixture().resized(7, 3, 4, 4);
        assert_eq!(d.colors.warp.len(), d.ends());
        assert_eq!(d.colors.weft.len(), d.picks());
    }

    #[test]
    fn resize_grows_a_blank_draft() {
        let d = Draft::blank(4, 4).resized(3, 3, 4, 4);
        assert_eq!(d.ends(), 3);
        assert_eq!(d.picks(), 3);
        assert!(no_errors(&d), "a grown blank draft is clean to start editing");
    }

    #[test]
    fn resize_liftplan_prunes_shafts() {
        let lp = Draft {
            name: "lp".into(),
            shafts: 4,
            treadles: 0,
            shed: ShedType::Rising,
            unit: Unit::Inches,
            threading: Threading(vec![vec![ShaftId(1)], vec![ShaftId(2)]]),
            drive: Drive::Liftplan(Liftplan(vec![
                vec![ShaftId(1), ShaftId(4)],
                vec![ShaftId(3)],
            ])),
            colors: ColorPlan {
                palette: vec![Color::BLACK],
                warp: vec![0, 0],
                weft: vec![0, 0],
            },
            notes: String::new(),
            retained: Vec::new(),
        };
        let d = lp.resized(2, 2, 2, 0); // shafts 4 -> 2
        if let Drive::Liftplan(l) = &d.drive {
            assert_eq!(l.0[0], vec![ShaftId(1)], "shaft 4 pruned from pick 0");
            assert!(l.0[1].is_empty(), "shaft 3 pruned from pick 1");
        } else {
            panic!("expected liftplan");
        }
        assert!(no_errors(&d));
    }

    #[test]
    fn resize_to_zero_on_every_axis_is_safe() {
        // The empty-cloth placeholder depends on resize-to-0 producing a clean, panic-free draft.
        let d = resize_fixture().resized(0, 0, 1, 0);
        assert_eq!(d.ends(), 0);
        assert_eq!(d.picks(), 0);
        assert!(d.threading.0.is_empty());
        assert!(d.colors.warp.is_empty());
        assert!(d.colors.weft.is_empty());
        if let Drive::Treadled { tieup, treadling } = &d.drive {
            assert!(tieup.0.is_empty(), "tie-up truncated to 0 treadles");
            assert!(treadling.0.is_empty(), "treadling truncated to 0 picks");
        } else {
            panic!("expected treadled");
        }
        assert!(no_errors(&d));
    }

    #[test]
    fn resize_shrinks_each_axis_to_zero_independently() {
        // ends -> 0: warp empties, coupling holds.
        let e = resize_fixture().resized(0, 4, 4, 4);
        assert_eq!(e.ends(), 0);
        assert_eq!(e.colors.warp.len(), 0);
        assert!(no_errors(&e));
        // picks -> 0: weft empties.
        let p = resize_fixture().resized(4, 0, 4, 4);
        assert_eq!(p.picks(), 0);
        assert_eq!(p.colors.weft.len(), 0);
        assert!(no_errors(&p));
        // treadles -> 0 on a treadled draft: tie-up truncated, every treadling press pruned.
        let t = resize_fixture().resized(4, 4, 4, 0);
        assert_eq!(t.treadles, 0);
        if let Drive::Treadled { tieup, treadling } = &t.drive {
            assert!(tieup.0.is_empty());
            assert!(treadling.0.iter().all(|row| row.is_empty()), "all presses pruned");
        } else {
            panic!("expected treadled");
        }
        assert!(no_errors(&t));
    }
}
