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

use crate::construction::Construction;
use ply_common::{Color, Unit};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

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

    /// A straight draw over `ends` ends: end i threads shaft `((i-1) mod shafts) + 1`
    /// (1, 2, …, N, 1, 2, …). The most common threading and the natural partner of a twill tie-up.
    pub fn straight(ends: usize, shafts: u16) -> Threading {
        let n = shafts.max(1) as usize;
        Threading(
            (0..ends)
                .map(|i| vec![ShaftId((i % n) as u16 + 1)])
                .collect(),
        )
    }

    /// A point (zigzag) draw over `ends`: 1, 2, …, N, N-1, …, 2, 1, 2, … (period `2N - 2`), the
    /// threading that turns a twill into a chevron / point twill.
    pub fn point(ends: usize, shafts: u16) -> Threading {
        let n = shafts.max(1) as usize;
        let period = if n > 1 { 2 * (n - 1) } else { 1 };
        Threading(
            (0..ends)
                .map(|i| {
                    let p = i % period;
                    let s = if p < n { p + 1 } else { 2 * n - p - 1 };
                    vec![ShaftId(s as u16)]
                })
                .collect(),
        )
    }
}

/// Tie-up: for each treadle (in order), the set of shafts it is tied to.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TieUp(pub Vec<Vec<ShaftId>>);

impl TieUp {
    pub fn treadles(&self) -> usize {
        self.0.len()
    }

    /// The tie-up for a loom with the OTHER shed direction: each treadle ties exactly the shafts in
    /// `1..=shafts` it did not tie before. A rising (jack) tie-up names the shafts that go up and a
    /// sinking (counterbalance/countermarch) one names the shafts that go down, so a pick that presses
    /// ONE treadle raises the same shafts either way. Ids above `shafts` are dropped.
    pub fn complement(&self, shafts: u16) -> TieUp {
        TieUp(
            self.0
                .iter()
                .map(|tied| {
                    (1..=shafts)
                        .map(ShaftId)
                        .filter(|s| !tied.contains(s))
                        .collect()
                })
                .collect(),
        )
    }

    /// Shafts tied to a given 1-based treadle, or empty if out of range.
    pub fn shafts_for(&self, t: TreadleId) -> &[ShaftId] {
        self.0
            .get((t.0 as usize).wrapping_sub(1))
            .map(|v| v.as_slice())
            .unwrap_or(&[])
    }

    // --- Structure generators (M3) — pure constructors for common weave families. Each returns a
    // canonical tie-up sized to the structure's natural repeat, ready to commit into a draft. ---

    /// Plain weave (tabby): 2 treadles — treadle 1 raises the ODD shafts, treadle 2 the EVEN — over
    /// `shafts` shafts, so it alternates correctly under a multi-shaft straight threading.
    pub fn plain(shafts: u16) -> TieUp {
        let odds = (1..=shafts).step_by(2).map(ShaftId).collect();
        let evens = (2..=shafts).step_by(2).map(ShaftId).collect();
        TieUp(vec![odds, evens])
    }

    /// A straight `over`/`under` twill over `over + under` shafts and the same number of treadles:
    /// treadle i (1-based) raises `over` consecutive shafts starting at shaft i, wrapping. E.g.
    /// `twill(2, 2)` is the classic 2/2 twill on 4 shafts (`[[1,2],[2,3],[3,4],[4,1]]`).
    pub fn twill(over: u16, under: u16) -> TieUp {
        // Sum in u32 so `over + under` near the u16 ceiling cannot overflow (panic in debug).
        let n = (over as u32 + under as u32).max(1);
        let rows = (0..n)
            .map(|i| {
                (0..over as u32)
                    .map(|k| ShaftId(((i + k) % n + 1) as u16))
                    .collect()
            })
            .collect();
        TieUp(rows)
    }

    /// A `shafts`-shaft satin: each treadle raises ONE shaft, stepping by `counter` (the satin move),
    /// giving long floats. For a TRUE satin `counter` is coprime with `shafts` and not 1 or
    /// `shafts - 1`, but any value yields a valid tie-up.
    pub fn satin(shafts: u16, counter: u16) -> TieUp {
        let n = shafts.max(1) as u32;
        let rows = (0..n)
            .map(|i| vec![ShaftId(((i * counter as u32) % n + 1) as u16)])
            .collect();
        TieUp(rows)
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

/// What a weft pick is FOR in the weaver's working sequence (roadmap M8-06): the semantic layer on
/// top of the shed. A shed says which shafts rise; a role says why the pick is woven (an overshot
/// pattern pick or the tabby that binds it, a pick of a double weave's top or bottom layer).
///
/// Roles are OPTIONAL and never inferred. A pick nobody marked is [`PickRole::Unknown`], including
/// every pick of a third-party WIF: color and shaft combinations are suggestive, not proof, so the
/// engine does not guess. (The app's "Mark tabby picks" helper only PROPOSES tabby roles from the
/// sheds and writes them after the weaver confirms.)
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
pub enum PickRole {
    /// Not recorded. The default, and what every pick of a draft without role data reads as.
    #[default]
    Unknown,
    /// A pattern (figure) pick, e.g. the heavier weft of overshot.
    Pattern,
    /// A tabby (plain-weave ground) pick between pattern picks.
    Tabby,
    /// A pick that weaves the top layer of a double weave.
    TopLayer,
    /// A pick that weaves the bottom layer of a double weave.
    BottomLayer,
}

/// The most shuttles a draft can number (1..=8). Hand weaving rarely uses more than four; the cap keeps
/// file data and the editor's controls bounded.
pub const MAX_SHUTTLES: u8 = 8;

/// The most strands one pass can carry together (1..=4): "two yarns in one pass" up to a few more.
pub const MAX_STRANDS: u8 = 4;

/// 1-based shuttle number, as the weaver labels the shuttles (shuttle 1, shuttle 2, ...).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
pub struct ShuttleId(pub u8);

/// A selvedge, as the weaver sees the cloth sitting at the front of the loom. A shuttle that starts
/// from the right makes its first pass right to left.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum Side {
    Left,
    Right,
}

impl Side {
    /// The opposite selvedge.
    pub fn other(self) -> Side {
        match self {
            Side::Left => Side::Right,
            Side::Right => Side::Left,
        }
    }
}

/// A deliberate instruction to work consecutive picks as repeated passes of the weft in ONE shed: a
/// double shot (2 passes), a triple shot (3), and so on (roadmap M8-06). This is not double weave, and
/// it is not two yarns carried in one pass (that is [`WeftWork::strands`]).
///
/// Consecutive picks with identical sheds and NO group stay unrelated picks: the weaver changes the
/// shed between them. A group always covers at least two picks, and every pick in it must raise the
/// same shafts (validation reports a group that does not).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct ShotGroup {
    /// The 0-based first pick of the group.
    pub start: usize,
    /// How many picks (passes) the group holds; at least 2.
    pub picks: usize,
}

impl ShotGroup {
    /// The 0-based pick just past the group.
    pub fn end(&self) -> usize {
        self.start.saturating_add(self.picks)
    }

    /// True when the 0-based `pick` is one of the group's passes.
    pub fn contains(&self, pick: usize) -> bool {
        pick >= self.start && pick < self.end()
    }
}

/// How the weft is worked beyond its sheds (roadmap M8-06): which shuttle carries each pick, where
/// each shuttle starts, how many strands each pass carries, and which picks are shot groups. All of it
/// is optional and never inferred (not from colors, not from repeated sheds): an empty list means
/// nothing is recorded, which is the case for every third-party WIF. The pass direction of a pick is
/// NOT stored; it follows from the shuttles and their starting sides (see [`Draft::pass_starts`]).
/// Stored with the pick roles in Ply's WIF 1.1 private section (ADR 0009).
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct WeftWork {
    /// Per pick, the shuttle that carries it; `None` = unknown. EMPTY = every shuttle unknown;
    /// otherwise length-coupled to the picks like the roles.
    pub shuttles: Vec<Option<ShuttleId>>,
    /// Per shuttle, the selvedge it starts its first pass from. A shuttle with no entry has an unknown
    /// starting side, so its picks have no known direction.
    pub shuttle_starts: BTreeMap<ShuttleId, Side>,
    /// Per pick, how many strands the pass carries together (1..=[`MAX_STRANDS`]). EMPTY = one strand
    /// for every pick; otherwise length-coupled to the picks.
    pub strands: Vec<u8>,
    /// The shot groups, in pick order and not overlapping.
    pub shot_groups: Vec<ShotGroup>,
    /// The double-weave construction the weaver declared (or a generator set): two independent
    /// layers, a tube, or double width with a fold. A LABEL, checked against the edges derived from
    /// the roles, shuttles and starting sides (see [`crate::construction`]); `None` = not declared,
    /// which is every third-party WIF. Never inferred. It belongs to the draft, not to a pick, so every
    /// pick edit keeps it (validation then says whether it still matches).
    pub construction: Option<Construction>,
}

impl WeftWork {
    /// True when nothing is recorded (the state of every draft from before M8-06 and every
    /// third-party WIF).
    pub fn is_empty(&self) -> bool {
        self.shuttles.iter().all(Option::is_none)
            && self.shuttle_starts.is_empty()
            && self.strands.iter().all(|&s| s == 1)
            && self.shot_groups.is_empty()
            && self.construction.is_none()
    }
}

/// The draft's two plain-weave (tabby) sheds, precomputed from the threading. A raised-shaft set is
/// a tabby shed when, over the THREADED warp ends in warp order (unthreaded ends are skipped), it
/// lifts exactly every other end; "tabby a" lifts the first threaded end, "tabby b" the second. An end
/// threaded on several shafts is up when any of them is raised, exactly as the drawdown reads it, and
/// at least two threaded ends are needed to tell.
///
/// This is a property of the cloth, not of treadle numbers, so it holds on either shed direction and
/// for a treadled or liftplan drive (pass [`Draft::raised_shafts`]). Building the rule costs one pass
/// over the threading; checking a pick then costs its raised shafts, not the width of the warp, so
/// validation stays linear on a large (or hostile) draft. The app's Book view mirrors this rule in
/// Dart (`use_tabby.dart`); both suites test the same cases.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TabbyRule {
    /// Index 0: the shed lifting the first threaded end (a); index 1: the other (b). `None` when that
    /// shed cannot exist on this threading.
    phases: [Option<PhaseRule>; 2],
}

/// One tabby shed as constraints: lift no `down` shaft, every `must` shaft, and one of each `choice`.
#[derive(Debug, Clone, PartialEq, Eq)]
struct PhaseRule {
    /// Shafts threaded by an end that must stay down: raising any of them lifts that end.
    down: BTreeSet<u16>,
    /// Shafts that are the only way to lift an end that must rise.
    must: BTreeSet<u16>,
    /// For a must-rise end on several shafts: the shafts that can lift it (one is enough).
    choices: Vec<Vec<u16>>,
}

impl TabbyRule {
    pub fn new(threading: &Threading) -> TabbyRule {
        let ends: Vec<&Vec<ShaftId>> = threading.0.iter().filter(|e| !e.is_empty()).collect();
        if ends.len() < 2 {
            return TabbyRule {
                phases: [None, None],
            };
        }
        let build = |first_up: bool| -> Option<PhaseRule> {
            let up = |k: usize| k.is_multiple_of(2) == first_up;
            let down: BTreeSet<u16> = ends
                .iter()
                .enumerate()
                .filter(|(k, _)| !up(*k))
                .flat_map(|(_, e)| e.iter().map(|s| s.0))
                .collect();
            let mut must = BTreeSet::new();
            let mut choices: BTreeSet<Vec<u16>> = BTreeSet::new();
            for (k, end) in ends.iter().enumerate() {
                if !up(k) {
                    continue;
                }
                let lift: BTreeSet<u16> = end
                    .iter()
                    .map(|s| s.0)
                    .filter(|s| !down.contains(s))
                    .collect();
                match lift.len() {
                    0 => return None, // this end cannot rise while its neighbours stay down
                    1 => {
                        must.extend(lift);
                    }
                    _ => {
                        choices.insert(lift.into_iter().collect());
                    }
                }
            }
            let choices = choices
                .into_iter()
                .filter(|c| !c.iter().any(|s| must.contains(s)))
                .collect();
            Some(PhaseRule {
                down,
                must,
                choices,
            })
        };
        TabbyRule {
            phases: [build(true), build(false)],
        }
    }

    /// `Some(true)` when `raised` is tabby a, `Some(false)` tabby b, `None` when it is not a
    /// plain-weave shed of this threading.
    pub fn phase(&self, raised: &[ShaftId]) -> Option<bool> {
        let r: BTreeSet<u16> = raised.iter().map(|s| s.0).collect();
        self.phases
            .iter()
            .position(|rule| {
                rule.as_ref().is_some_and(|rule| {
                    r.iter().all(|s| !rule.down.contains(s))
                        && rule.must.iter().all(|s| r.contains(s))
                        && rule.choices.iter().all(|c| c.iter().any(|s| r.contains(s)))
                })
            })
            .map(|i| i == 0)
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
    /// Per warp end, a relative thread thickness (1.0 = base) that drives variable-WIDTH cells in the
    /// drawdown. EMPTY means "all default 1.0" (a uniform grid); otherwise length-coupled to `ends`
    /// like the warp colors. Parsed from `[WARP THICKNESS]`; a resize couples its length.
    pub warp_thickness: Vec<f32>,
    /// Per weft pick, a relative thickness driving variable-HEIGHT cells. Empty = all 1.0. See
    /// [`Draft::warp_thickness`].
    pub weft_thickness: Vec<f32>,
    pub notes: String,
    /// Unmodeled WIF sections kept verbatim for round-trip fidelity (see [`RetainedSection`]).
    /// Carried through cosmetic edits; a resize drops the per-thread WARP/WEFT ones on a changing
    /// axis (their rows would desync). Empty for a from-scratch draft.
    pub retained: Vec<RetainedSection>,
    /// Per weft pick, its [`PickRole`]. EMPTY means every role is unknown (the common case, and
    /// every third-party WIF); otherwise length-coupled to `picks` like the weft colors, and every
    /// operation that changes the picks keeps it aligned (a resize pads `Unknown` and truncates; the
    /// shed and drive conversions keep the picks, so they keep the roles). Not part of WIF proper:
    /// stored in Ply's WIF 1.1 private section (see `wif.rs` and ADR 0008).
    pub pick_roles: Vec<PickRole>,
    /// Shuttles, strands, and shot groups (see [`WeftWork`]). Empty for a draft that records none.
    /// Kept aligned with the picks by every operation that changes them, like `pick_roles`.
    pub weft_work: WeftWork,
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
            warp_thickness: Vec::new(),
            weft_thickness: Vec::new(),
            retained: Vec::new(),
            pick_roles: Vec::new(),
            weft_work: WeftWork::default(),
        }
    }

    pub fn ends(&self) -> usize {
        self.threading.ends()
    }

    pub fn picks(&self) -> usize {
        self.drive.picks()
    }

    /// The role of the 0-based `pick`: its recorded [`PickRole`], or `Unknown` when the draft records
    /// no roles (an empty `pick_roles`) or the pick lies past the recorded ones.
    pub fn pick_role(&self, pick: usize) -> PickRole {
        self.pick_roles.get(pick).copied().unwrap_or_default()
    }

    /// True when at least one pick has a known role (so there is something to store).
    pub fn has_pick_roles(&self) -> bool {
        self.pick_roles.iter().any(|&r| r != PickRole::Unknown)
    }

    /// The shuttle that carries the 0-based `pick`, or `None` when it is not recorded.
    pub fn shuttle(&self, pick: usize) -> Option<ShuttleId> {
        self.weft_work.shuttles.get(pick).copied().flatten()
    }

    /// How many strands the 0-based `pick` carries in its pass: the recorded count, or 1 when the
    /// draft records none.
    pub fn strands(&self, pick: usize) -> u8 {
        self.weft_work.strands.get(pick).copied().unwrap_or(1)
    }

    /// The shot group the 0-based `pick` belongs to, if any.
    pub fn shot_group_at(&self, pick: usize) -> Option<ShotGroup> {
        self.weft_work
            .shot_groups
            .iter()
            .copied()
            .find(|g| g.contains(pick))
    }

    /// The average number of strands per pick over the draft (1.0 for a draft with no picks or no
    /// strands recorded). A pass carrying two strands uses twice the weft of a single-strand pass, so
    /// this scales a weft-yarn estimate (see `calc::estimate_weft_for_draft`).
    pub fn mean_strands(&self) -> f32 {
        let picks = self.picks();
        if picks == 0 || self.weft_work.strands.is_empty() {
            return 1.0;
        }
        let total: u64 = (0..picks).map(|p| u64::from(self.strands(p))).sum();
        total as f32 / picks as f32
    }

    /// True when the 0-based picks `a` and `b` raise exactly the same shafts (the same shed, whatever
    /// treadles or liftplan rows express it).
    pub fn same_shed(&self, a: usize, b: usize) -> bool {
        sorted_set(self.raised_shafts(a)) == sorted_set(self.raised_shafts(b))
    }

    /// The side each pick's pass STARTS from, derived from the shuttles; `None` where it is unknown.
    /// Directions are never stored. Every shuttle alternates its own direction: its first pass starts
    /// from its recorded starting side, its next pass from the other side, and so on, counting only
    /// that shuttle's picks. So two shuttles each keep their own rhythm, and a double shot woven with
    /// one shuttle reverses direction inside the shed (its second pass comes back).
    ///
    /// A pick's direction is unknown when its shuttle is unknown or has no starting side, and also
    /// for EVERY pick after a pick whose shuttle is unknown: that pick may have been woven with any
    /// shuttle, so the later passes of every shuttle can no longer be counted.
    pub fn pass_starts(&self) -> Vec<Option<Side>> {
        let picks = self.picks();
        let mut passes: BTreeMap<ShuttleId, usize> = BTreeMap::new();
        let mut counting = true;
        let mut out = Vec::with_capacity(picks);
        for p in 0..picks {
            let Some(shuttle) = self.shuttle(p).filter(|_| counting) else {
                counting = false;
                out.push(None);
                continue;
            };
            let n = passes.entry(shuttle).or_insert(0);
            let even = n.is_multiple_of(2);
            *n += 1;
            out.push(self.weft_work.shuttle_starts.get(&shuttle).map(|&side| {
                if even {
                    side
                } else {
                    side.other()
                }
            }));
        }
        out
    }

    /// The shot groups that are still sound for this draft's picks: in pick order, cut at the last
    /// pick, a group overlapping an earlier one dropped, and each split into its maximal runs of picks
    /// that raise the same shafts, keeping only runs of at least two picks. A group that stays in one
    /// shed is returned unchanged; one whose shed changed under it shrinks, splits, or disappears, so
    /// a group can never be left naming picks it does not describe. Operations that can change sheds
    /// or drop picks (resize, a shed-direction conversion) apply this.
    pub fn sound_shot_groups(&self) -> Vec<ShotGroup> {
        let picks = self.picks();
        let mut groups = self.weft_work.shot_groups.clone();
        groups.sort_by_key(|g| (g.start, g.picks));
        let mut out: Vec<ShotGroup> = Vec::new();
        let mut taken = 0usize; // first pick not yet claimed by an accepted group
        for g in groups {
            let (start, end) = (g.start, g.end().min(picks));
            if start < taken || start >= end {
                continue;
            }
            let mut run = start;
            for p in start + 1..=end {
                if p == end || !self.same_shed(run, p) {
                    if p - run >= 2 {
                        out.push(ShotGroup {
                            start: run,
                            picks: p - run,
                        });
                    }
                    run = p;
                }
            }
            taken = end;
        }
        out
    }

    /// Whether the raised-shaft set `raised` is one of the draft's two plain-weave (tabby) sheds, and
    /// which one (see [`TabbyRule`]): `Some(true)` = "tabby a" (lifts the first threaded warp end),
    /// `Some(false)` = "tabby b", `None` = not a plain-weave shed. Builds the rule from the threading
    /// each call; to check many picks, build one [`TabbyRule`] and reuse it.
    pub fn plain_weave_phase(&self, raised: &[ShaftId]) -> Option<bool> {
        TabbyRule::new(&self.threading).phase(raised)
    }

    /// True when the 0-based `pick` raises one of the draft's two plain-weave (tabby) sheds (see
    /// [`plain_weave_phase`](Self::plain_weave_phase)).
    pub fn is_tabby_shed(&self, pick: usize) -> bool {
        self.plain_weave_phase(&self.raised_shafts(pick)).is_some()
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

    /// The same draft re-expressed for a loom with shed direction `shed`. A treadled draft keeps its
    /// threading and treadling and swaps its tie-up for the [complement](TieUp::complement), so the
    /// cloth is IDENTICAL whenever every pick presses exactly one treadle (true of every structure
    /// generator, which all assume a rising shed). Picks that press several treadles, or none, combine
    /// differently on the two shed directions, so their cloth can change; that is loom physics, not a
    /// conversion choice. A liftplan names raised shafts directly and only its `shed` label changes.
    pub fn with_shed(&self, shed: ShedType) -> Draft {
        if shed == self.shed {
            return self.clone();
        }
        let drive = match &self.drive {
            Drive::Treadled { tieup, treadling } => Drive::Treadled {
                tieup: tieup.complement(self.shafts),
                treadling: treadling.clone(),
            },
            Drive::Liftplan(lp) => Drive::Liftplan(lp.clone()),
        };
        let mut out = Draft {
            shed,
            drive,
            ..self.clone()
        };
        // A pick pressing several treadles (or none) can raise different shafts on the other shed
        // direction, so a shot group over such picks may no longer share one shed.
        out.weft_work.shot_groups = out.sound_shot_groups();
        out
    }

    /// A canonical **liftplan-driven** copy of this draft. The drawdown is unchanged: the
    /// raised-shaft set per pick is baked in via `to_liftplan` (so a sinking-shed tie-up is
    /// already complemented). Because a liftplan names raised shafts *directly*, the shed
    /// becomes `Rising` (no further inversion) and `treadles` drops to 0 (a liftplan carries
    /// no tie-up). The reverse direction — [`factor_liftplan`](Self::factor_liftplan) — recovers a
    /// tie-up + treadling when the lift plan is simple enough.
    pub fn to_liftplan_draft(&self) -> Draft {
        Draft {
            drive: Drive::Liftplan(self.to_liftplan()),
            shed: ShedType::Rising,
            treadles: 0,
            ..self.clone()
        }
    }

    /// The inverse of [`to_liftplan_draft`](Self::to_liftplan_draft) WHEN the lift plan is simple
    /// enough for a treadle loom: factor a liftplan-driven draft into a tie-up + treadling, treating
    /// each DISTINCT lift (set of raised shafts) as one treadle in order of first appearance. Returns
    /// `None` for a non-liftplan drive, or when the plan needs more than `max_treadles` distinct lifts
    /// (an unwieldy tie-up, better left a liftplan). The result uses a **rising** shed so the tied set
    /// IS the raised set — `raised_shafts` is byte-identical to the liftplan's, only the
    /// representation changes (the cloth is untouched). This is what lets a dobby-style WIF import
    /// (a `[LIFTPLAN]` with no tie-up) show the conventional tie-up + treadling instead of the whole
    /// lift pattern dumped into the treadling column.
    pub fn factor_liftplan(&self, max_treadles: usize) -> Option<Draft> {
        let Drive::Liftplan(lp) = &self.drive else {
            return None;
        };
        // Two lifts are the same SHED iff they raise the same set of shafts (order/dups irrelevant).
        fn same_set(a: &[ShaftId], b: &[ShaftId]) -> bool {
            a.iter().all(|s| b.contains(s)) && b.iter().all(|s| a.contains(s))
        }
        let mut lifts: Vec<Vec<ShaftId>> = Vec::new(); // distinct lift sets; treadle id = index + 1
        let mut treadling: Vec<Vec<TreadleId>> = Vec::with_capacity(lp.0.len());
        for pick in &lp.0 {
            let idx = match lifts.iter().position(|l| same_set(l, pick)) {
                Some(i) => i,
                None => {
                    if lifts.len() >= max_treadles {
                        return None; // too many distinct lifts for a sane tie-up
                    }
                    lifts.push(pick.clone());
                    lifts.len() - 1
                }
            };
            treadling.push(vec![TreadleId(idx as u16 + 1)]);
        }
        let treadles = lifts.len() as u16;
        Some(Draft {
            drive: Drive::Treadled {
                tieup: TieUp(lifts),
                treadling: Treadling(treadling),
            },
            shed: ShedType::Rising,
            treadles,
            ..self.clone()
        })
    }

    /// A copy resized to the given dimensions. GROWING pads with blanks (empty threading / empty
    /// picks / color index 0); SHRINKING truncates AND prunes every shaft/treadle reference the
    /// new, smaller header no longer has, so a resize NEVER leaves a dangling reference the user
    /// must hand-fix (the resized draft `validate()`s with no new `Error`). Warp/weft color
    /// lengths stay coupled (`warp.len() == ends`, `weft.len() == picks`). The palette is
    /// untouched. This is the canonical, tested resize the editor's resize reducer routes through.
    /// (Growth lands at the HIGH index; the editor DISPLAYS end 1 at the right / pick 1 at the top,
    /// so a new high-index end shows on the LEFT and a new high-index pick at the BOTTOM.)
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

        let mut out = Draft {
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
            // Per-thread thickness stays length-coupled like the colors (growing pads the default
            // 1.0); an empty "all-default" slice stays empty rather than materializing 1.0s.
            warp_thickness: resize_thickness(&self.warp_thickness, ends),
            weft_thickness: resize_thickness(&self.weft_thickness, picks),
            notes: self.notes.clone(),
            retained,
            // Roles stay length-coupled to the picks: a shrink drops the removed picks' roles, a grow
            // adds blank picks whose role is Unknown, and "no roles recorded" stays empty.
            pick_roles: resize_roles(&self.pick_roles, picks),
            // Shuttles and strands couple to the picks the same way (a new pick has an unknown shuttle
            // and one strand). Starting sides belong to shuttles, not picks, so they are kept.
            weft_work: WeftWork {
                shuttles: resize_if_recorded(&self.weft_work.shuttles, picks, None),
                shuttle_starts: self.weft_work.shuttle_starts.clone(),
                strands: resize_if_recorded(&self.weft_work.strands, picks, 1),
                shot_groups: self.weft_work.shot_groups.clone(),
                construction: self.weft_work.construction,
            },
        };
        // A shrink cuts the groups at the last pick, and pruned shafts or treadles can change sheds:
        // keep each group only where its picks remain and still share one shed.
        out.weft_work.shot_groups = out.sound_shot_groups();
        out
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

/// The shaft numbers of `raised`, ascending and without repeats (a shed as a set).
fn sorted_set(raised: Vec<ShaftId>) -> Vec<u16> {
    let mut s: Vec<u16> = raised.into_iter().map(|s| s.0).collect();
    s.sort_unstable();
    s.dedup();
    s
}

/// First `len` of `rows`, padding with `pad()` when growing (truncating when shrinking).
fn resize_rows<T: Clone>(rows: &[T], len: usize, pad: impl FnMut() -> T) -> Vec<T> {
    let mut out: Vec<T> = rows.iter().take(len).cloned().collect();
    out.resize_with(len, pad);
    out
}

/// Resize a per-thread thickness slice, preserving the "empty == all-default 1.0" convention: an
/// empty slice stays empty (no need to materialize a uniform grid); a set one is length-coupled,
/// padding new threads with 1.0.
fn resize_thickness(t: &[f32], len: usize) -> Vec<f32> {
    if t.is_empty() {
        Vec::new()
    } else {
        resize_rows(t, len, || 1.0)
    }
}

/// Resize the per-pick roles, preserving the "empty == every role unknown" convention: an empty
/// slice stays empty; a recorded one is length-coupled, padding new picks with `Unknown`.
fn resize_roles(roles: &[PickRole], len: usize) -> Vec<PickRole> {
    if roles.is_empty() {
        Vec::new()
    } else {
        resize_rows(roles, len, PickRole::default)
    }
}

/// Resize a per-pick list whose EMPTY form means "nothing recorded": an empty list stays empty; a
/// recorded one is length-coupled, padding new picks with `pad`.
fn resize_if_recorded<T: Clone>(xs: &[T], len: usize, pad: T) -> Vec<T> {
    if xs.is_empty() {
        Vec::new()
    } else {
        resize_rows(xs, len, || pad.clone())
    }
}

/// Keep only shafts in `1..=shafts` (drops dangling references on a shrink).
fn prune_shafts(row: Vec<ShaftId>, shafts: u16) -> Vec<ShaftId> {
    row.into_iter()
        .filter(|s| s.0 >= 1 && s.0 <= shafts)
        .collect()
}

/// Keep only treadles in `1..=treadles`.
fn prune_treadles(row: Vec<TreadleId>, treadles: u16) -> Vec<TreadleId> {
    row.into_iter()
        .filter(|t| t.0 >= 1 && t.0 <= treadles)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::validate::{validate, Severity};

    fn ids(rows: &[Vec<ShaftId>]) -> Vec<Vec<u16>> {
        rows.iter()
            .map(|r| r.iter().map(|s| s.0).collect())
            .collect()
    }

    #[test]
    fn plain_tieup_alternates_odd_even() {
        assert_eq!(ids(&TieUp::plain(2).0), vec![vec![1], vec![2]]);
        // Multi-shaft plain raises all odds then all evens.
        assert_eq!(ids(&TieUp::plain(4).0), vec![vec![1, 3], vec![2, 4]]);
    }

    #[test]
    fn twill_2_2_matches_canonical_tieup() {
        // The classic 2/2 twill on 4 shafts — the same tie-up the golden + mapping fixtures use.
        assert_eq!(
            ids(&TieUp::twill(2, 2).0),
            vec![vec![1, 2], vec![2, 3], vec![3, 4], vec![4, 1]]
        );
        // A 1/3 twill: one shaft up, stepping diagonally.
        assert_eq!(
            ids(&TieUp::twill(1, 3).0),
            vec![vec![1], vec![2], vec![3], vec![4]]
        );
    }

    #[test]
    fn twill_does_not_overflow_at_the_u16_ceiling() {
        // `over + under` past u16::MAX must not panic (the sum is computed in u32). `over = 1` keeps
        // the tie-up at 65,536 entries; `over = u16::MAX` would build 4.3 billion (about 8.6 GB),
        // which no test may allocate. The FFI bridge refuses tie-ups this large anyway.
        let t = TieUp::twill(1, u16::MAX);
        assert_eq!(t.treadles(), u16::MAX as usize + 1);
        assert!(t.0.iter().all(|row| row.len() == 1));
    }

    #[test]
    fn tieup_complement_flips_each_treadle_within_the_shaft_count() {
        let t = TieUp(vec![vec![ShaftId(1), ShaftId(3)], vec![], vec![ShaftId(9)]]);
        assert_eq!(
            ids(&t.complement(4).0),
            vec![vec![2, 4], vec![1, 2, 3, 4], vec![1, 2, 3, 4]]
        );
    }

    #[test]
    fn with_shed_leaves_a_liftplan_unchanged_except_its_label() {
        let mut d = Draft::blank(4, 0);
        d.threading = Threading::straight(4, 4);
        d.drive = Drive::Liftplan(Liftplan(vec![
            vec![ShaftId(1), ShaftId(2)],
            vec![ShaftId(3)],
        ]));
        let s = d.with_shed(ShedType::Sinking);
        assert_eq!(s.drive, d.drive);
        assert_eq!(s.shed, ShedType::Sinking);
        assert_eq!(s.with_shed(ShedType::Sinking), s, "same shed is a no-op");
    }

    #[test]
    fn satin_steps_by_the_counter() {
        // 5-shaft satin, counter 2: shafts 1,3,5,2,4 (one per treadle).
        assert_eq!(
            ids(&TieUp::satin(5, 2).0),
            vec![vec![1], vec![3], vec![5], vec![2], vec![4]]
        );
    }

    #[test]
    fn straight_and_point_threadings() {
        assert_eq!(
            ids(&Threading::straight(5, 4).0),
            vec![vec![1], vec![2], vec![3], vec![4], vec![1]]
        );
        // Point draw on 4 shafts over 6 ends: 1,2,3,4,3,2 (then it would repeat 1,2,…).
        assert_eq!(
            ids(&Threading::point(6, 4).0),
            vec![vec![1], vec![2], vec![3], vec![4], vec![3], vec![2]]
        );
    }

    /// A generated twill threaded straight, tied, and treadled straight `validate()`s clean — the
    /// "Generate structure" action must produce a usable draft.
    #[test]
    fn generated_twill_draft_validates_clean() {
        let d = Draft {
            name: String::new(),
            shafts: 4,
            treadles: 4,
            shed: ShedType::Rising,
            unit: ply_common::Unit::Inches,
            threading: Threading::straight(8, 4),
            drive: Drive::Treadled {
                tieup: TieUp::twill(2, 2),
                treadling: Treadling(
                    (0..8)
                        .map(|i| vec![TreadleId((i % 4) as u16 + 1)])
                        .collect(),
                ),
            },
            colors: ColorPlan {
                palette: vec![Color::WHITE, Color::BLACK],
                warp: vec![0; 8],
                weft: vec![1; 8],
            },
            notes: String::new(),
            warp_thickness: Vec::new(),
            weft_thickness: Vec::new(),
            retained: Vec::new(),
            pick_roles: Vec::new(),
            weft_work: WeftWork::default(),
        };
        assert!(validate(&d).iter().all(|i| i.severity != Severity::Error));
    }

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
            warp_thickness: Vec::new(),
            weft_thickness: Vec::new(),
            retained: Vec::new(),
            pick_roles: Vec::new(),
            weft_work: WeftWork::default(),
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
    fn factor_liftplan_recovers_a_tieup_with_identical_cloth() {
        // Bake a sinking-shed treadled draft to a liftplan, then factor it back: the factored draft
        // must weave the SAME cloth (equal raised set per pick) with a rising, treadle-loom tie-up,
        // and a repeated shed must collapse to ONE treadle.
        let d = Draft {
            name: "t".into(),
            shafts: 4,
            treadles: 2,
            shed: ShedType::Sinking,
            unit: Unit::Inches,
            threading: Threading(vec![vec![ShaftId(1)], vec![ShaftId(2)]]),
            drive: Drive::Treadled {
                tieup: TieUp(vec![vec![ShaftId(1), ShaftId(2)], vec![ShaftId(3)]]),
                treadling: Treadling(vec![
                    vec![TreadleId(1)],
                    vec![TreadleId(2)],
                    vec![TreadleId(1)],
                ]),
            },
            colors: ColorPlan {
                palette: vec![Color::WHITE, Color::BLACK],
                warp: vec![0, 1],
                weft: vec![1, 0, 1],
            },
            notes: String::new(),
            warp_thickness: Vec::new(),
            weft_thickness: Vec::new(),
            retained: Vec::new(),
            pick_roles: Vec::new(),
            weft_work: WeftWork::default(),
        };
        let lp = d.to_liftplan_draft();
        let factored = lp.factor_liftplan(40).expect("a 2-lift plan factors");
        assert!(matches!(factored.drive, Drive::Treadled { .. }));
        assert_eq!(factored.shed, ShedType::Rising);
        assert_eq!(factored.treadles, 2, "two distinct sheds -> two treadles");
        assert_eq!(factored.picks(), lp.picks());
        if let Drive::Treadled { treadling, .. } = &factored.drive {
            assert_eq!(
                treadling.0[0], treadling.0[2],
                "the repeated shed reuses one treadle"
            );
        }
        for p in 0..lp.picks() {
            assert_eq!(
                factored.raised_shafts(p),
                lp.raised_shafts(p),
                "pick {p} cloth differs"
            );
        }
    }

    #[test]
    fn factor_liftplan_declines_when_unwieldy_or_not_a_liftplan() {
        // Three picks, each a different single-shaft lift -> 3 distinct lifts.
        let lp = Draft {
            name: "t".into(),
            shafts: 3,
            treadles: 0,
            shed: ShedType::Rising,
            unit: Unit::Inches,
            threading: Threading(vec![vec![ShaftId(1)], vec![ShaftId(2)], vec![ShaftId(3)]]),
            drive: Drive::Liftplan(Liftplan(vec![
                vec![ShaftId(1)],
                vec![ShaftId(2)],
                vec![ShaftId(3)],
            ])),
            colors: ColorPlan {
                palette: vec![Color::WHITE],
                warp: vec![0, 0, 0],
                weft: vec![0, 0, 0],
            },
            notes: String::new(),
            warp_thickness: Vec::new(),
            weft_thickness: Vec::new(),
            retained: Vec::new(),
            pick_roles: Vec::new(),
            weft_work: WeftWork::default(),
        };
        assert!(
            lp.factor_liftplan(2).is_none(),
            "3 distinct lifts exceed a cap of 2"
        );
        assert!(
            lp.factor_liftplan(40).is_some(),
            "but they fit a generous cap"
        );
        // A treadled drive is never factored (it already has a tie-up).
        let treadled = Draft {
            drive: Drive::Treadled {
                tieup: TieUp(vec![vec![ShaftId(1)]]),
                treadling: Treadling(vec![
                    vec![TreadleId(1)],
                    vec![TreadleId(1)],
                    vec![TreadleId(1)],
                ]),
            },
            ..lp.clone()
        };
        assert!(treadled.factor_liftplan(40).is_none());
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
            warp_thickness: Vec::new(),
            weft_thickness: Vec::new(),
            retained: Vec::new(),
            pick_roles: Vec::new(),
            weft_work: WeftWork::default(),
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
        assert!(
            out.warp.iter().all(|&e| e < out.palette.len()),
            "no warp dangle: {:?}",
            out.warp
        );
        assert!(
            out.weft.iter().all(|&e| e < out.palette.len()),
            "no weft dangle: {:?}",
            out.weft
        );
    }

    #[test]
    fn remove_color_rejects_bad_index_and_last_color() {
        let cp = ColorPlan {
            palette: vec![Color::WHITE, Color::BLACK],
            warp: vec![0, 1],
            weft: vec![],
        };
        assert!(
            cp.with_color_removed(2).is_err(),
            "out-of-range index rejected"
        );
        let one = ColorPlan {
            palette: vec![Color::WHITE],
            warp: vec![0],
            weft: vec![0],
        };
        assert!(
            one.with_color_removed(0).is_err(),
            "removing the last color rejected"
        );
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
            warp_thickness: Vec::new(),
            weft_thickness: Vec::new(),
            retained: Vec::new(),
            pick_roles: Vec::new(),
            weft_work: WeftWork::default(),
        }
    }

    fn no_errors(d: &Draft) -> bool {
        validate(d).iter().all(|i| i.severity != Severity::Error)
    }

    #[test]
    fn resize_grows_ends_and_picks_padding_blanks() {
        // Growth lands at the HIGH index (the editor displays end 1 right / pick 1 top, so a new
        // high-index end shows on the LEFT and a new high-index pick at the BOTTOM).
        let d = resize_fixture().resized(6, 5, 4, 4);
        assert_eq!(d.ends(), 6);
        assert_eq!(d.picks(), 5);
        assert_eq!(
            d.threading.0[5],
            Vec::<ShaftId>::new(),
            "new end is unthreaded"
        );
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
        assert!(
            no_errors(&d),
            "a shrink must never leave a dangling-shaft Error: {:?}",
            validate(&d)
        );
    }

    #[test]
    fn resize_shrinks_treadles_prunes_treadling_and_truncates_tieup() {
        let d = resize_fixture().resized(4, 4, 4, 2); // treadles 4 -> 2
        assert_eq!(d.treadles, 2);
        if let Drive::Treadled { tieup, treadling } = &d.drive {
            assert_eq!(tieup.0.len(), 2, "tie-up truncated to the treadle count");
            assert!(
                treadling.0[2].is_empty(),
                "pick 3's press of treadle 3 pruned"
            );
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
        assert!(
            no_errors(&d),
            "a grown blank draft is clean to start editing"
        );
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
            warp_thickness: Vec::new(),
            weft_thickness: Vec::new(),
            retained: Vec::new(),
            pick_roles: Vec::new(),
            weft_work: WeftWork::default(),
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

    // --- Pick roles (M8-06): length-coupled to the picks through every draft operation. ---

    fn roles_fixture() -> Draft {
        Draft {
            pick_roles: vec![
                PickRole::Pattern,
                PickRole::Tabby,
                PickRole::Pattern,
                PickRole::Tabby,
            ],
            ..resize_fixture()
        }
    }

    #[test]
    fn pick_role_reads_unknown_when_nothing_is_recorded() {
        let d = resize_fixture();
        assert!(d.pick_roles.is_empty());
        assert!(!d.has_pick_roles());
        assert_eq!(d.pick_role(0), PickRole::Unknown);
        let r = roles_fixture();
        assert!(r.has_pick_roles());
        assert_eq!(r.pick_role(1), PickRole::Tabby);
        assert_eq!(
            r.pick_role(99),
            PickRole::Unknown,
            "past the picks is unknown"
        );
    }

    #[test]
    fn resize_keeps_roles_aligned_with_the_picks() {
        // Grow: the new picks' roles are Unknown, the old ones keep theirs.
        let g = roles_fixture().resized(4, 6, 4, 4);
        assert_eq!(g.pick_roles.len(), g.picks());
        assert_eq!(&g.pick_roles[..4], &roles_fixture().pick_roles[..]);
        assert_eq!(&g.pick_roles[4..], &[PickRole::Unknown, PickRole::Unknown]);
        // Shrink: the removed picks take their roles with them.
        let s = roles_fixture().resized(4, 3, 4, 4);
        assert_eq!(
            s.pick_roles,
            vec![PickRole::Pattern, PickRole::Tabby, PickRole::Pattern]
        );
        // To zero, and an unchanged pick axis, stay aligned.
        assert!(roles_fixture().resized(4, 0, 4, 4).pick_roles.is_empty());
        assert_eq!(
            roles_fixture().resized(9, 4, 2, 1).pick_roles,
            roles_fixture().pick_roles,
            "an ends/shafts/treadles resize leaves the roles alone"
        );
        // "No roles recorded" stays empty instead of materializing Unknowns.
        assert!(resize_fixture().resized(4, 8, 4, 4).pick_roles.is_empty());
    }

    #[test]
    fn drive_and_shed_conversions_keep_every_role() {
        let d = roles_fixture();
        // Shed conversion keeps the picks, so it keeps the roles (both directions).
        let sinking = d.with_shed(ShedType::Sinking);
        assert_eq!(sinking.pick_roles, d.pick_roles);
        assert_eq!(sinking.with_shed(ShedType::Rising).pick_roles, d.pick_roles);
        // Treadled -> liftplan -> factored back: same picks, same roles.
        let lp = sinking.to_liftplan_draft();
        assert_eq!(lp.pick_roles, d.pick_roles);
        let factored = lp.factor_liftplan(40).expect("4 lifts factor");
        assert_eq!(factored.pick_roles, d.pick_roles);
        // A palette edit does not touch the picks.
        let mut colored = d.clone();
        colored.colors.palette.push(Color::rgb(1, 2, 3));
        assert_eq!(
            colored.with_color_removed(2).unwrap().pick_roles,
            d.pick_roles
        );
    }

    #[test]
    fn plain_weave_phase_finds_the_two_tabby_sheds() {
        // Overshot-style threading 1,2,1,2,3,4,3,4: {1,3} lifts ends 1,3,5,7 and {2,4} the others.
        let mut d = Draft::blank(4, 0);
        d.threading = Threading(
            [1, 2, 1, 2, 3, 4, 3, 4]
                .iter()
                .map(|&s| vec![ShaftId(s)])
                .collect(),
        );
        assert_eq!(d.plain_weave_phase(&[ShaftId(1), ShaftId(3)]), Some(true));
        assert_eq!(d.plain_weave_phase(&[ShaftId(2), ShaftId(4)]), Some(false));
        // A pattern shed (a whole block up) is not plain weave, nor is nothing or everything.
        assert_eq!(d.plain_weave_phase(&[ShaftId(1), ShaftId(2)]), None);
        assert_eq!(d.plain_weave_phase(&[]), None);
        assert_eq!(
            d.plain_weave_phase(&[ShaftId(1), ShaftId(2), ShaftId(3), ShaftId(4)]),
            None
        );
        // Unthreaded ends are skipped; one threaded end cannot show alternation.
        d.threading.0.insert(1, Vec::new());
        assert_eq!(d.plain_weave_phase(&[ShaftId(1), ShaftId(3)]), Some(true));
        d.threading = Threading(vec![vec![ShaftId(1)], Vec::new()]);
        assert_eq!(d.plain_weave_phase(&[ShaftId(1)]), None);
        // On a straight 1,2,3,4 threading a twill shed is not tabby either.
        d.threading = Threading::straight(8, 4);
        assert_eq!(d.plain_weave_phase(&[ShaftId(1), ShaftId(2)]), None);
        assert_eq!(d.plain_weave_phase(&[ShaftId(2), ShaftId(4)]), Some(false));
    }

    #[test]
    fn tabby_rule_handles_ends_on_several_shafts() {
        // Ends: {1}, {2,3}, {1}, {2}. Tabby a lifts ends 1 and 3 (shaft 1 only); tabby b lifts
        // ends 2 and 4, which needs shaft 2 (end 4) and so also covers end 2.
        let t = Threading(vec![
            vec![ShaftId(1)],
            vec![ShaftId(2), ShaftId(3)],
            vec![ShaftId(1)],
            vec![ShaftId(2)],
        ]);
        let rule = TabbyRule::new(&t);
        assert_eq!(rule.phase(&[ShaftId(1)]), Some(true));
        assert_eq!(rule.phase(&[ShaftId(1), ShaftId(2)]), None);
        assert_eq!(rule.phase(&[ShaftId(2)]), Some(false));
        assert_eq!(rule.phase(&[ShaftId(2), ShaftId(3)]), Some(false));
        assert_eq!(rule.phase(&[ShaftId(3)]), None, "end 4 would stay down");
        // An unthreaded shaft in the lift changes nothing.
        assert_eq!(rule.phase(&[ShaftId(1), ShaftId(9)]), Some(true));
        // An end whose shafts all belong to ends that must stay down can never rise alone.
        let stuck = Threading(vec![vec![ShaftId(1)], vec![ShaftId(1)], vec![ShaftId(2)]]);
        assert_eq!(TabbyRule::new(&stuck).phase(&[ShaftId(1)]), None);
        assert_eq!(TabbyRule::new(&stuck).phase(&[ShaftId(2)]), None);
    }

    /// The rule is the alternation definition, checked exhaustively against a direct walk of the
    /// threaded ends for every lift on small threadings (single- and multi-shaft ends).
    #[test]
    fn tabby_rule_matches_a_direct_alternation_walk() {
        fn walk(t: &Threading, raised: &[ShaftId]) -> Option<bool> {
            let ups: Vec<bool> =
                t.0.iter()
                    .filter(|e| !e.is_empty())
                    .map(|e| e.iter().any(|s| raised.contains(s)))
                    .collect();
            if ups.len() < 2 || ups.windows(2).any(|w| w[0] == w[1]) {
                return None;
            }
            Some(ups[0])
        }
        let threadings = [
            Threading::straight(6, 4),
            Threading::point(9, 4),
            Threading(
                [1, 2, 1, 2, 3, 4, 3, 4]
                    .iter()
                    .map(|&s| vec![ShaftId(s)])
                    .collect(),
            ),
            Threading(vec![
                vec![ShaftId(1)],
                vec![],
                vec![ShaftId(2), ShaftId(4)],
                vec![ShaftId(3)],
                vec![ShaftId(4)],
                vec![ShaftId(1), ShaftId(3)],
            ]),
        ];
        for t in &threadings {
            let rule = TabbyRule::new(t);
            for mask in 0u16..32 {
                let raised: Vec<ShaftId> = (1..=5)
                    .filter(|s| mask & (1 << (s - 1)) != 0)
                    .map(ShaftId)
                    .collect();
                assert_eq!(rule.phase(&raised), walk(t, &raised), "{t:?} {raised:?}");
            }
        }
    }

    #[test]
    fn is_tabby_shed_reads_the_raised_shafts_on_a_sinking_shed() {
        // Sinking: treadle 1 SINKS {2,4}, so it RAISES {1,3}, the tabby that lifts end 1.
        let mut d = Draft::blank(4, 2);
        d.shed = ShedType::Sinking;
        d.threading = Threading::straight(4, 4);
        d.drive = Drive::Treadled {
            tieup: TieUp(vec![vec![ShaftId(2), ShaftId(4)], vec![ShaftId(1)]]),
            treadling: Treadling(vec![vec![TreadleId(1)], vec![TreadleId(2)]]),
        };
        assert!(d.is_tabby_shed(0));
        assert!(!d.is_tabby_shed(1), "raising 2,3,4 is not plain weave");
    }

    // --- Shuttles, strands, and shot groups (M8-06, ADR 0009) ---

    /// Six picks on a straight 4-shaft draft: treadles 1, 1, 1, 2, 3, 3. Picks 1 and 2 are a double
    /// shot and picks 5 and 6 another; shuttle 1 weaves every pick except pick 4 (shuttle 2).
    fn worked_fixture() -> Draft {
        let mut d = resize_fixture().resized(4, 6, 4, 4);
        if let Drive::Treadled { treadling, .. } = &mut d.drive {
            treadling.0 = [1, 1, 1, 2, 3, 3]
                .iter()
                .map(|&t| vec![TreadleId(t)])
                .collect();
        }
        d.weft_work = WeftWork {
            shuttles: [1, 1, 1, 2, 1, 1]
                .iter()
                .map(|&s| Some(ShuttleId(s)))
                .collect(),
            shuttle_starts: [(ShuttleId(1), Side::Right)].into_iter().collect(),
            strands: vec![1, 1, 2, 1, 1, 3],
            shot_groups: vec![
                ShotGroup { start: 0, picks: 2 },
                ShotGroup { start: 4, picks: 2 },
            ],
            construction: None,
        };
        d
    }

    #[test]
    fn weft_work_reads_unknown_and_one_strand_when_nothing_is_recorded() {
        let d = resize_fixture();
        assert!(d.weft_work.is_empty());
        assert_eq!(d.shuttle(0), None);
        assert_eq!(d.strands(0), 1);
        assert_eq!(d.shot_group_at(0), None);
        assert_eq!(d.pass_starts(), vec![None; 4]);
        let w = worked_fixture();
        assert_eq!(w.shuttle(3), Some(ShuttleId(2)));
        assert_eq!(w.strands(5), 3);
        assert_eq!(w.strands(99), 1, "past the picks is one strand");
        assert_eq!(w.shot_group_at(1), Some(ShotGroup { start: 0, picks: 2 }));
        assert_eq!(w.shot_group_at(2), None);
    }

    #[test]
    fn resize_keeps_shuttles_strands_and_groups_aligned() {
        // Grow: new picks have no shuttle and one strand; the groups and starting sides are kept.
        let g = worked_fixture().resized(4, 8, 4, 4);
        assert_eq!(g.weft_work.shuttles.len(), 8);
        assert_eq!(&g.weft_work.shuttles[6..], &[None, None]);
        assert_eq!(&g.weft_work.strands[6..], &[1, 1]);
        assert_eq!(
            g.weft_work.shot_groups,
            worked_fixture().weft_work.shot_groups
        );
        assert_eq!(
            g.weft_work.shuttle_starts,
            worked_fixture().weft_work.shuttle_starts
        );
        // Shrink through the second group: it would keep one pick, so it is dissolved.
        let s = worked_fixture().resized(4, 5, 4, 4);
        assert_eq!(
            s.weft_work.shot_groups,
            vec![ShotGroup { start: 0, picks: 2 }]
        );
        assert_eq!(s.weft_work.shuttles.len(), 5);
        assert_eq!(s.weft_work.strands, vec![1, 1, 2, 1, 1]);
        // A triple shot cut to two picks stays a (double) shot.
        let mut t = worked_fixture();
        t.weft_work.shot_groups = vec![ShotGroup { start: 0, picks: 3 }];
        assert_eq!(
            t.resized(4, 2, 4, 4).weft_work.shot_groups,
            vec![ShotGroup { start: 0, picks: 2 }]
        );
        // Shrinking to 0 treadles prunes every press, so every pick raises nothing: each group is
        // still one shed and stays.
        let z = worked_fixture().resized(4, 6, 4, 0);
        assert_eq!(
            z.weft_work.shot_groups,
            worked_fixture().weft_work.shot_groups
        );
        // To zero picks, everything per pick empties.
        let e = worked_fixture().resized(4, 0, 4, 4);
        assert!(e.weft_work.shuttles.is_empty() && e.weft_work.strands.is_empty());
        assert!(e.weft_work.shot_groups.is_empty());
        // "Nothing recorded" stays empty instead of materializing unknowns and ones.
        let n = resize_fixture().resized(4, 9, 4, 4);
        assert!(n.weft_work.shuttles.is_empty() && n.weft_work.strands.is_empty());
    }

    #[test]
    fn a_group_whose_shed_changes_under_it_is_not_sound() {
        // Pick 6 presses treadles 3 + 4 and treadle 4 ties nothing, so it shares pick 5's shed and the
        // group over picks 5 and 6 is sound. Tying shaft 1 to treadle 4 changes pick 6's shed.
        let mut d = worked_fixture();
        if let Drive::Treadled { treadling, .. } = &mut d.drive {
            treadling.0[5] = vec![TreadleId(3), TreadleId(4)];
        }
        if let Drive::Treadled { tieup, .. } = &mut d.drive {
            tieup.0[3] = vec![]; // treadle 4 ties nothing, so picks 5 and 6 share one shed
        }
        assert!(d.same_shed(4, 5));
        assert_eq!(
            d.sound_shot_groups(),
            d.weft_work.shot_groups,
            "sound as built"
        );
        if let Drive::Treadled { tieup, .. } = &mut d.drive {
            tieup.0[3] = vec![ShaftId(1)]; // now pick 6 also raises shaft 1
        }
        assert!(!d.same_shed(4, 5));
        assert_eq!(
            d.sound_shot_groups(),
            vec![ShotGroup { start: 0, picks: 2 }],
            "a group whose shed changed under it is dropped, never left on mixed sheds"
        );
    }

    #[test]
    fn sound_shot_groups_split_at_shed_changes_and_drop_overlaps() {
        let mut d = worked_fixture();
        // One group over picks 1 to 4 (treadles 1, 1, 1, 2): its one-shed run is picks 1 to 3.
        d.weft_work.shot_groups = vec![ShotGroup { start: 0, picks: 4 }];
        assert_eq!(
            d.sound_shot_groups(),
            vec![ShotGroup { start: 0, picks: 3 }]
        );
        // Treadles 1, 2, 1 inside one group: no run of two, so nothing survives.
        if let Drive::Treadled { treadling, .. } = &mut d.drive {
            treadling.0[1] = vec![TreadleId(2)];
        }
        d.weft_work.shot_groups = vec![ShotGroup { start: 0, picks: 3 }];
        assert!(d.sound_shot_groups().is_empty());
        // Out of order, overlapping, one-pick, and past-the-end groups.
        let mut o = worked_fixture();
        o.weft_work.shot_groups = vec![
            ShotGroup { start: 4, picks: 2 },
            ShotGroup { start: 1, picks: 2 },
            ShotGroup { start: 0, picks: 2 },
            ShotGroup { start: 3, picks: 1 },
            ShotGroup { start: 5, picks: 4 },
        ];
        assert_eq!(
            o.sound_shot_groups(),
            vec![
                ShotGroup { start: 0, picks: 2 },
                ShotGroup { start: 4, picks: 2 }
            ]
        );
    }

    #[test]
    fn shed_and_drive_conversions_keep_weft_work() {
        let d = worked_fixture();
        let sinking = d.with_shed(ShedType::Sinking);
        assert_eq!(
            sinking.weft_work, d.weft_work,
            "one treadle per pick: the cloth is unchanged"
        );
        assert_eq!(sinking.with_shed(ShedType::Rising).weft_work, d.weft_work);
        let lp = sinking.to_liftplan_draft();
        assert_eq!(lp.weft_work, d.weft_work);
        assert_eq!(lp.factor_liftplan(40).unwrap().weft_work, d.weft_work);
        let mut colored = d.clone();
        colored.colors.palette.push(Color::rgb(1, 2, 3));
        assert_eq!(
            colored.with_color_removed(2).unwrap().weft_work,
            d.weft_work
        );
    }

    #[test]
    fn a_shed_conversion_that_separates_a_group_drops_it() {
        // Rising: pick 1 presses treadles 1 + 2 (shafts 1 and 2), pick 2 presses treadle 3 (tied to
        // shafts 1 and 2): one shed, grouped. On a sinking loom pick 1 sinks every shaft and pick 2
        // only 3 and 4, so they are no longer one shed and the group is dropped.
        let mut d = Draft::blank(4, 3);
        d.threading = Threading::straight(4, 4);
        d.drive = Drive::Treadled {
            tieup: TieUp(vec![
                vec![ShaftId(1)],
                vec![ShaftId(2)],
                vec![ShaftId(1), ShaftId(2)],
            ]),
            treadling: Treadling(vec![vec![TreadleId(1), TreadleId(2)], vec![TreadleId(3)]]),
        };
        d.weft_work.shot_groups = vec![ShotGroup { start: 0, picks: 2 }];
        assert!(d.same_shed(0, 1));
        let s = d.with_shed(ShedType::Sinking);
        assert!(!s.same_shed(0, 1));
        assert!(s.weft_work.shot_groups.is_empty());
    }

    #[test]
    fn one_shuttle_alternates_and_reverses_inside_a_double_shot() {
        use Side::*;
        let mut d = worked_fixture();
        d.weft_work.shuttles = vec![Some(ShuttleId(1)); 6];
        // Six passes of shuttle 1 from the right: the double shots at picks 1-2 and 5-6 come back
        // inside their shed, because each pass is one crossing.
        assert_eq!(
            d.pass_starts(),
            vec![
                Some(Right),
                Some(Left),
                Some(Right),
                Some(Left),
                Some(Right),
                Some(Left)
            ]
        );
        d.weft_work.shuttle_starts.insert(ShuttleId(1), Left);
        assert_eq!(d.pass_starts()[0], Some(Left));
        assert_eq!(d.pass_starts()[1], Some(Right));
    }

    #[test]
    fn two_shuttles_each_keep_their_own_rhythm() {
        use Side::*;
        let mut d = worked_fixture();
        // Shuttle 1 from the right weaves picks 1, 2, 3, 5, 6; shuttle 2 from the left weaves pick 4.
        d.weft_work.shuttle_starts.insert(ShuttleId(2), Left);
        assert_eq!(
            d.pass_starts(),
            vec![
                Some(Right),
                Some(Left),
                Some(Right),
                Some(Left),
                Some(Left),
                Some(Right)
            ]
        );
        // Alternating shuttles with no groups: each alternates on its own passes only.
        d.weft_work.shot_groups.clear();
        d.weft_work.shuttles = [1, 2, 1, 2, 1, 2]
            .iter()
            .map(|&s| Some(ShuttleId(s)))
            .collect();
        assert_eq!(
            d.pass_starts(),
            vec![
                Some(Right),
                Some(Left),
                Some(Left),
                Some(Right),
                Some(Right),
                Some(Left)
            ]
        );
        // A double shot with two shuttles (shuttle 1 then shuttle 2 in one shed): each starts from
        // its own side.
        d.weft_work.shot_groups = vec![ShotGroup { start: 0, picks: 2 }];
        assert_eq!(d.pass_starts()[..2], [Some(Right), Some(Left)]);
    }

    #[test]
    fn unknown_shuttles_and_sides_leave_directions_unknown() {
        use Side::*;
        let mut d = worked_fixture();
        // Shuttle 2 has no starting side: its pick has no direction, shuttle 1 keeps counting.
        assert_eq!(
            d.pass_starts(),
            vec![
                Some(Right),
                Some(Left),
                Some(Right),
                None,
                Some(Left),
                Some(Right)
            ]
        );
        // A pick with an unknown shuttle could have been any shuttle, so nothing after it is known.
        d.weft_work.shuttles[2] = None;
        assert_eq!(
            d.pass_starts(),
            vec![Some(Right), Some(Left), None, None, None, None]
        );
        // No shuttles at all: no directions, even with starting sides recorded.
        d.weft_work.shuttles.clear();
        assert_eq!(d.pass_starts(), vec![None; 6]);
    }

    #[test]
    fn mean_strands_averages_every_pick() {
        assert_eq!(worked_fixture().mean_strands(), 9.0 / 6.0);
        assert_eq!(resize_fixture().mean_strands(), 1.0);
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
            assert!(
                treadling.0.iter().all(|row| row.is_empty()),
                "all presses pruned"
            );
        } else {
            panic!("expected treadled");
        }
        assert!(no_errors(&t));
    }
}
