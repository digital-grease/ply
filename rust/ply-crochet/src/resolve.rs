//! Resolution: from relative instructions to explicit attachments (ADR 0022 sections 5 to 13).
//!
//! Each layer is a fold over the positions the layer before made: its base is built in the order the
//! crocheter meets them ([`crate::base`]), a cursor walks it as the instructions say, and every
//! stitch, leg and slip stitch gets an explicit [`Anchor`]. Every base position ends up worked,
//! skipped, passed over, left unworked on purpose, used by an opaque item, or not reached. The layer's
//! items then become the next layer's positions. Nothing here reads a label set.
//!
//! The rules that shape the result:
//!
//! - **One mistake, one error.** A target that cannot be found is reported where it is; the stitch is
//!   still made and counted with an impossible anchor, and the cursor does not move. A part that does
//!   not fit the position it meets (`crochet.part_invalid`) is the exception: the position exists and
//!   is of the kind asked for, so the cursor moves onto it and only the anchor is impossible, which
//!   keeps the rest of the layer where the author meant it.
//! - **Repeats to the end are tried whole** (section 11): each repetition of a `to_end` or `to_last`
//!   body is run as a trial and undone, without a diagnostic, if any target in it finds no position;
//!   the repeat then stops, and positions it leaves are one `crochet.repeat_does_not_fit`. Every
//!   applied repetition moves the cursor forward, so a repeat makes at most as many repetitions as
//!   its base has positions.
//! - **Unknown stays unknown** (section 12): an opaque instruction that does not state both what it
//!   uses and what it makes ends what Ply can check. Its layer and every later layer have unknown
//!   counts, one `crochet.count_unknown` says so, and nothing that depends on where the work is gets
//!   reported after it; diagnostics that belong to an instruction itself still are.
//! - **What Ply does not check stays unchecked.** A named stitch whose body uses anything opaque is
//!   opaque as a whole (section 9): every stitch it makes is an opaque item (never counted as the
//!   identity its body names), every position it uses is used by an opaque item, its chain runs stay
//!   spaces marked unverified, and its use site gets one `crochet.unsupported_op`. `same` after an
//!   opaque target or item works where that one did, so it is unverified too, never silently the
//!   top of the position under the cursor.
//! - **Bounded.** Items (and listed joins and travelling slip stitches) per layer and per piece and
//!   steps per layer are counted as they happen; the moment a budget would be passed, resolution
//!   stops with `crochet.too_large`. Diagnostics are counted per code as they are found and only
//!   the listed ones are built (`max_diagnostics_per_code`); `try_resolve` builds none.

use crate::base::{Base, Cursor, Found, Miss, Position, PositionKind, Unit};
use crate::check::{layer_word, op_targets, Checked};
use crate::count::{LayerCount, StatedCheck};
use crate::diagnostic::{
    count, thousands, Admit, Collector, Counts, CrochetCode, CrochetLocation, Detail, Diagnostic,
    MAX_LISTED,
};
use crate::limits::CrochetLimits;
use crate::pattern::{
    ChainPart, Close, CountsAs, Instr, LayerId, LayerKind, Op, Part, PartSpec, PieceStart, PosKind,
    RepeatCount, StartChain, Target,
};
use crate::place::{Anchor, ChainAt, ItemId, PosRef, Side};
use crate::stitch::{Basic, Counted, Identity, SlipRole};
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};

/// How one base position was used.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum BaseUse {
    Worked,
    Skipped,
    /// Passed over by a `next` (or `skip`) looking for another kind: left unworked.
    Passed,
    /// Left by `leave_unworked`.
    LeftUnworked,
    /// The layer's instructions ended before reaching it.
    NotReached,
    /// Used by an opaque instruction or target: Ply does not know how.
    Unverified,
    /// A space entered chain by chain: see each chain's use.
    ByChain,
    /// After the count became unknown in this layer: where the work went is not known.
    Unknown,
}

/// The chains of a space entered chain by chain, in the order met.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct ChainUses {
    /// The chains the cursor reached, first met first.
    pub visited: Vec<BaseUse>,
    /// How the chains after them were used (all alike).
    pub rest: BaseUse,
    /// How many chains follow the visited ones.
    pub rest_count: u32,
}

/// One position of a layer's base and how it was used.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct BaseSlot {
    pub position: Position,
    pub used: BaseUse,
    /// For a space entered chain by chain.
    pub chains: Option<ChainUses>,
}

/// A layer's base, resolved.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ResolvedBase {
    /// The layer has no base (foundation stitches are layer 1 itself).
    None,
    /// Its positions in the order met.
    Known(Vec<BaseSlot>),
    /// An earlier unknown count leaves its base unknown.
    Unknown,
}

/// What an item is.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Made {
    /// Item 0. `taken` is the range of foundation chains it is made of (form a), first to last.
    StartChain {
        chains: u32,
        counts: Option<Counted>,
        space: Option<u32>,
        from_foundation: bool,
        taken: Option<(u32, u32)>,
    },
    /// A foundation stitch (layer 1 of a piece started with foundation stitches).
    Foundation(Basic),
    Stitch(Basic),
    Together {
        stitch: Basic,
        legs: u32,
    },
    /// An ordinary slip stitch (it makes a position).
    Slip,
    ChainRun {
        chains: u32,
    },
    /// A stitch position made by an opaque instruction or layer: never counted as any identity.
    Opaque,
}

impl Made {
    /// The identity this item is (a starting chain is a chain; an opaque item has none).
    pub fn identity(&self) -> Option<Identity> {
        match *self {
            Made::StartChain { .. } | Made::ChainRun { .. } => Some(Identity::Chain),
            Made::Foundation(b) | Made::Stitch(b) => Some(Identity::Basic(b)),
            Made::Together { stitch, legs } => Some(Identity::Together { stitch, legs }),
            Made::Slip => Some(Identity::Slip),
            Made::Opaque => None,
        }
    }

    /// What it counts as in the layer's stitch count, if it is a stitch.
    pub fn counted(&self) -> Option<Counted> {
        match *self {
            Made::StartChain { counts, .. } => counts,
            Made::Foundation(b) | Made::Stitch(b) | Made::Together { stitch: b, .. } => {
                Some(Counted::Basic(b))
            }
            Made::Slip => Some(Counted::Slip),
            Made::ChainRun { .. } | Made::Opaque => None,
        }
    }
}

/// One item a layer made.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct MadeItem {
    pub id: ItemId,
    pub made: Made,
    /// What it is worked into: one anchor per leg of a `tog`, one for any other stitch, the position
    /// a counted starting chain stands on, none for a chain run or an uncounted starting chain.
    pub anchors: Vec<Anchor>,
    /// Its attachment is not checked: an opaque item, an opaque target, or work into a position an
    /// opaque item made.
    pub unverified: bool,
    /// The instruction that made it (the use site, for a named stitch's items).
    pub source: Vec<u32>,
    /// The repetition of each repeat on `source`.
    pub repetition: Vec<u32>,
    /// The legend entry (index) whose use made it, for a named stitch's items.
    pub named: Option<u32>,
    /// A marker placed in it.
    pub mark: Option<String>,
}

/// A slip stitch that makes no position: a join or a travelling slip stitch.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct SlipMove {
    pub role: SlipRole,
    pub anchor: Anchor,
    pub source: Vec<u32>,
    pub repetition: Vec<u32>,
    /// How many items the layer had made before it (its place in work order).
    pub after: u32,
}

/// The shape of a layer, for views.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LayerShape {
    Foundation,
    Row,
    Round { close: Close, turn: bool },
    Opaque,
}

/// One layer, resolved. Derived on every call, never stored.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct ResolvedLayer {
    /// Its position in the piece (from 1).
    pub layer: u32,
    pub id: LayerId,
    pub shape: LayerShape,
    /// The side facing the crocheter while working it; `None` after an opaque layer.
    pub facing: Option<Side>,
    pub base: ResolvedBase,
    /// Items in work order (item 0 first when it has one).
    pub made: Vec<MadeItem>,
    /// Joins and travelling slip stitches, in work order.
    pub moves: Vec<SlipMove>,
    /// The derived count, or `None` when it is unknown.
    pub count: Option<LayerCount>,
    /// How the stated count fared, when there is one.
    pub stated: Option<StatedCheck>,
    /// A spiral round's derived marker: its first stitch (ADR 0022 section 8).
    pub spiral_marker: Option<PosRef>,
    /// The instruction at which the count became unknown, when it did in this layer (empty for an
    /// opaque layer).
    pub unknown_from: Option<Vec<u32>>,
}

impl ResolvedLayer {
    /// Item `item` of this layer. Items are in work order, which is the order of their numbers, so
    /// this is a binary search.
    pub fn item(&self, item: u32) -> Option<&MadeItem> {
        self.made
            .binary_search_by_key(&item, |m| m.id.item)
            .ok()
            .map(|i| &self.made[i])
    }

    /// The positions this layer gives the next one, in work order.
    pub fn positions(&self) -> Vec<Position> {
        positions_of(&self.made)
    }

    /// Its base slots (empty when it has none or it is unknown).
    pub fn base_slots(&self) -> &[BaseSlot] {
        match &self.base {
            ResolvedBase::Known(s) => s,
            _ => &[],
        }
    }
}

/// Layers `first` to `last` of a piece, resolved.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct ResolvedWindow {
    pub first: u32,
    pub last: u32,
    pub layers: Vec<ResolvedLayer>,
}

impl ResolvedWindow {
    /// The layer at position `layer`, if the window holds it.
    pub fn layer(&self, layer: u32) -> Option<&ResolvedLayer> {
        self.layers.iter().find(|l| l.layer == layer)
    }
}

/// The positions items give the next layer, in work order.
pub(crate) fn positions_of(items: &[MadeItem]) -> Vec<Position> {
    let mut out = Vec::with_capacity(items.len());
    for it in items {
        match it.made {
            Made::StartChain { counts, space, .. } => {
                if counts.is_some() {
                    out.push(Position::new(PosRef::StartTop(it.id), PositionKind::Stitch));
                    if let Some(chains) = space {
                        out.push(Position::new(
                            PosRef::Space(it.id),
                            PositionKind::Space { chains },
                        ));
                    }
                }
            }
            // A chain run is unverified only when an opaque named stitch made it.
            Made::ChainRun { chains } => out.push(Position {
                at: PosRef::Space(it.id),
                kind: PositionKind::Space { chains },
                unverified: it.unverified,
            }),
            Made::Opaque => out.push(Position {
                at: PosRef::Top(it.id),
                kind: PositionKind::Stitch,
                unverified: true,
            }),
            Made::Foundation(_) | Made::Stitch(_) | Made::Together { .. } | Made::Slip => {
                out.push(Position::new(PosRef::Top(it.id), PositionKind::Stitch))
            }
        }
    }
    out
}

/// The derived count of a layer's items. Spaces are found by chain length through a map, so a layer
/// of many different run lengths is counted in linear time.
pub(crate) fn count_of(items: &[MadeItem]) -> LayerCount {
    let mut c = LayerCount::default();
    let mut space_at: HashMap<u32, usize> = HashMap::new();
    let mut add_space = |c: &mut LayerCount, chains: u32| match space_at.get(&chains) {
        Some(&i) => c.spaces[i].1 = c.spaces[i].1.saturating_add(1),
        None => {
            space_at.insert(chains, c.spaces.len());
            c.spaces.push((chains, 1));
        }
    };
    for it in items {
        match it.made {
            Made::StartChain { counts, space, .. } => {
                if let Some(k) = counts {
                    c.add_stitch(k);
                    if let Some(m) = space {
                        add_space(&mut c, m);
                    }
                }
            }
            Made::ChainRun { chains } => add_space(&mut c, chains),
            Made::Opaque => c.add_not_checked(),
            _ => {
                if let Some(k) = it.made.counted() {
                    c.add_stitch(k);
                }
            }
        }
    }
    c
}

// ---------------------------------------------------------------------------------------------
// One layer's run.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Use {
    Fresh,
    Worked,
    Skipped,
    Passed,
    Left,
    Unverified,
    Opened,
}

#[derive(Debug, Clone)]
struct OpenSpace {
    visited: Vec<Use>,
    rest: Use,
}

#[derive(Debug, Clone)]
enum Undo {
    Use(u32, Use),
    Visit(u32),
    VisitSet(u32, u32, Use),
    Rest(u32, Use),
    Open(u32),
    Reported((Vec<u32>, CrochetCode)),
}

#[derive(Debug, Clone, Copy)]
enum Passed {
    Whole(u32),
    /// The chains of the space at `space` from `from` (in the order met) on.
    Rest {
        space: u32,
        from: u32,
    },
}

/// Why a run stopped early.
#[derive(Debug)]
pub(crate) enum Stop {
    /// A trial repetition found no position for a target: undo it.
    Trial,
    /// An opaque item left the count unknown.
    Unknown,
    /// A budget would be passed.
    TooLarge(Box<Diagnostic>),
}

struct UseSite<'p> {
    target: Option<&'p Target>,
    resolved: Option<(Anchor, bool)>,
}

/// What resolving one target gave.
struct Resolved {
    anchor: Anchor,
    /// The anchor is worked into a position an opaque item made.
    unverified: bool,
    own: Own,
}

/// A diagnostic that belongs to the instruction itself, reported once per instruction.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Own {
    None,
    RingMissing,
    Unmodelled,
}

struct Snap<'p> {
    journal: usize,
    cursor: Cursor,
    items: usize,
    moves: usize,
    next_item: u32,
    markers: usize,
    passed: usize,
    ridges: usize,
    counts: Counts,
    excused_from: Option<u32>,
    excused_rest: Option<u32>,
    use_sites: Vec<Option<(Anchor, bool)>>,
    pending_mark: Option<&'p str>,
    items_total: u64,
    cursor_unverified: bool,
}

struct Run<'c, 'p> {
    chk: &'c Checked<'p>,
    limits: &'c CrochetLimits,
    layer: u32,
    word: String,
    base: &'c Base,
    uses: Vec<Use>,
    open: HashMap<u32, OpenSpace>,
    cursor: Cursor,
    items: Vec<MadeItem>,
    moves: Vec<SlipMove>,
    next_item: u32,
    markers: Vec<(&'p str, ItemId)>,
    passed: Vec<Passed>,
    ridges: Vec<(ItemId, Part)>,
    /// Positions from this index on were listed by a repeat's `crochet.repeat_does_not_fit`.
    excused_from: Option<u32>,
    /// The space whose remaining chains were so listed.
    excused_rest: Option<u32>,
    /// Where diagnostics go: counted per code when found, built only when they will be listed.
    out: &'c mut Collector,
    reported: HashSet<(Vec<u32>, CrochetCode)>,
    journal: Vec<Undo>,
    trial: u32,
    path: Vec<u32>,
    reps: Vec<u32>,
    body_depth: u32,
    use_sites: Vec<UseSite<'p>>,
    named: Vec<u32>,
    pending_mark: Option<&'p str>,
    cur_item: Option<u32>,
    steps: u64,
    items_total: u64,
    unknown_at: Option<Vec<u32>>,
    join: Option<Anchor>,
    left: bool,
    /// How many opaque named stitches are being expanded: inside one, every stitch is an opaque
    /// item and every position used is used by an opaque item (ADR 0022 section 9).
    opaque_named: u32,
    /// The cursor's position was last reached by an opaque target or item, so `same` works where
    /// that one did: somewhere Ply does not model.
    cursor_unverified: bool,
}

impl<'c, 'p> Run<'c, 'p> {
    fn new(
        chk: &'c Checked<'p>,
        limits: &'c CrochetLimits,
        layer: u32,
        word: String,
        base: &'c Base,
        items_total: u64,
        out: &'c mut Collector,
    ) -> Run<'c, 'p> {
        Run {
            chk,
            limits,
            layer,
            word,
            base,
            uses: vec![Use::Fresh; base.positions.len()],
            open: HashMap::new(),
            cursor: Cursor::Before(0),
            items: Vec::new(),
            moves: Vec::new(),
            next_item: 1,
            markers: Vec::new(),
            passed: Vec::new(),
            ridges: Vec::new(),
            excused_from: None,
            excused_rest: None,
            out,
            reported: HashSet::new(),
            journal: Vec::new(),
            trial: 0,
            path: Vec::new(),
            reps: Vec::new(),
            body_depth: 0,
            use_sites: Vec::new(),
            named: Vec::new(),
            pending_mark: None,
            cur_item: None,
            steps: 0,
            items_total,
            unknown_at: None,
            join: None,
            left: false,
            opaque_named: 0,
            cursor_unverified: false,
        }
    }

    // ---- bookkeeping --------------------------------------------------------------------------

    fn loc(&self) -> CrochetLocation {
        CrochetLocation {
            layer: Some(self.layer),
            legend: None,
            path: self.path.clone(),
            repetition: self.reps.clone(),
            item: self.cur_item,
            position: None,
        }
    }

    /// Count one finding of `code`; true when it is to be built and given to [`Run::store`]. Nothing
    /// is built for a finding past the per-code cap, or when the collector is off.
    fn admit(&mut self, code: CrochetCode) -> bool {
        self.out.admit(code) == Admit::Kept
    }

    fn store(&mut self, code: CrochetCode, loc: CrochetLocation, message: String, detail: Detail) {
        self.out
            .store(Diagnostic::new(code, loc, message).with_detail(detail));
    }

    /// A diagnostic of the instruction itself, once per instruction (keyed by its path). Inside an
    /// opaque named stitch the opaque parts are not reported one by one: the named stitch is the
    /// opaque item, reported once at its first item.
    fn own_diag(&mut self, code: CrochetCode, item: Option<u32>) {
        if self.opaque_named > 0
            && matches!(
                code,
                CrochetCode::UnsupportedOp | CrochetCode::UnsupportedTarget
            )
        {
            return;
        }
        let key = (self.path.clone(), code);
        if self.reported.contains(&key) {
            return;
        }
        if self.trial > 0 {
            self.journal.push(Undo::Reported(key.clone()));
        }
        self.reported.insert(key);
        if self.admit(code) {
            let loc = CrochetLocation { item, ..self.loc() };
            let message = own_message(code, &self.word);
            self.store(code, loc, message, Detail::None);
        }
    }

    fn too_large(&self, message: String) -> Stop {
        Stop::TooLarge(Box::new(Diagnostic::new(
            CrochetCode::TooLarge,
            CrochetLocation::layer(self.layer),
            message,
        )))
    }

    fn step(&mut self, n: u64) -> Result<(), Stop> {
        self.steps = self.steps.saturating_add(n);
        if self.steps > self.limits.max_steps_per_layer {
            return Err(self.too_large(format!(
                "{} takes more than {} steps to work out, Ply's limit.",
                self.word,
                thousands(self.limits.max_steps_per_layer)
            )));
        }
        Ok(())
    }

    fn set_use(&mut self, i: u32, u: Use) {
        let Some(old) = self.uses.get(i as usize).copied() else {
            return;
        };
        if old == u {
            return;
        }
        if self.trial > 0 {
            self.journal.push(Undo::Use(i, old));
        }
        self.uses[i as usize] = u;
    }

    fn snapshot(&self) -> Snap<'p> {
        Snap {
            journal: self.journal.len(),
            cursor: self.cursor,
            items: self.items.len(),
            moves: self.moves.len(),
            next_item: self.next_item,
            markers: self.markers.len(),
            passed: self.passed.len(),
            ridges: self.ridges.len(),
            counts: self.out.counts(),
            excused_from: self.excused_from,
            excused_rest: self.excused_rest,
            use_sites: self.use_sites.iter().map(|u| u.resolved.clone()).collect(),
            pending_mark: self.pending_mark,
            items_total: self.items_total,
            cursor_unverified: self.cursor_unverified,
        }
    }

    fn rollback(&mut self, s: Snap<'p>) {
        while self.journal.len() > s.journal {
            let Some(u) = self.journal.pop() else { break };
            match u {
                Undo::Use(i, old) => {
                    if let Some(slot) = self.uses.get_mut(i as usize) {
                        *slot = old;
                    }
                }
                Undo::Visit(i) => {
                    if let Some(sp) = self.open.get_mut(&i) {
                        sp.visited.pop();
                    }
                }
                Undo::VisitSet(i, c, old) => {
                    if let Some(v) = self
                        .open
                        .get_mut(&i)
                        .and_then(|sp| sp.visited.get_mut(c as usize))
                    {
                        *v = old;
                    }
                }
                Undo::Rest(i, old) => {
                    if let Some(sp) = self.open.get_mut(&i) {
                        sp.rest = old;
                    }
                }
                Undo::Open(i) => {
                    self.open.remove(&i);
                }
                Undo::Reported(key) => {
                    self.reported.remove(&key);
                }
            }
        }
        self.cursor = s.cursor;
        self.items.truncate(s.items);
        self.moves.truncate(s.moves);
        self.next_item = s.next_item;
        self.markers.truncate(s.markers);
        self.passed.truncate(s.passed);
        self.ridges.truncate(s.ridges);
        self.out.restore(&s.counts);
        self.excused_from = s.excused_from;
        self.excused_rest = s.excused_rest;
        for (site, r) in self.use_sites.iter_mut().zip(s.use_sites) {
            site.resolved = r;
        }
        self.pending_mark = s.pending_mark;
        self.items_total = s.items_total;
        self.cursor_unverified = s.cursor_unverified;
    }

    fn commit_trial(&mut self) {
        if self.trial == 0 {
            self.journal.clear();
        }
    }

    // ---- moving on the base -------------------------------------------------------------------

    /// What passing a position records: passed over, or (inside an opaque named stitch, whose work
    /// Ply does not check) used by an opaque item.
    fn passing(&self) -> Use {
        if self.opaque_named > 0 {
            Use::Unverified
        } else {
            Use::Passed
        }
    }

    /// Whether passed positions are listed (only for diagnostics, never inside an opaque item).
    fn lists_passed(&self) -> bool {
        self.opaque_named == 0 && self.out.is_on()
    }

    fn pass_rest(&mut self, space: u32) {
        let passing = self.passing();
        let from = match self.open.get_mut(&space) {
            Some(sp) => {
                let old = sp.rest;
                sp.rest = passing;
                let from = sp.visited.len() as u32;
                if self.trial > 0 {
                    self.journal.push(Undo::Rest(space, old));
                }
                from
            }
            None => return,
        };
        if self.lists_passed() {
            self.passed.push(Passed::Rest { space, from });
        }
    }

    fn commit(&mut self, f: &Found, u: Use) {
        if let Some(s) = f.pass_rest_of {
            self.pass_rest(s);
        }
        let passing = self.passing();
        let lists = self.lists_passed();
        for i in f.pass_from..f.pass_to {
            self.set_use(i, passing);
            if lists {
                self.passed.push(Passed::Whole(i));
            }
        }
        self.take(f.unit, u);
    }

    /// Land on `unit` and record its use. A position a modelled stitch works into stays worked when
    /// an opaque item also uses it (the ring, or `same` after an opaque target). Inside an opaque
    /// named stitch every use is an opaque item's.
    fn take(&mut self, unit: Unit, u: Use) {
        let u = if self.opaque_named > 0 {
            Use::Unverified
        } else {
            u
        };
        self.cursor_unverified = u == Use::Unverified;
        match unit.chain {
            None => {
                let keep =
                    u == Use::Unverified && self.uses.get(unit.pos as usize) == Some(&Use::Worked);
                if !keep {
                    self.set_use(unit.pos, u);
                }
            }
            Some(c) => {
                if let std::collections::hash_map::Entry::Vacant(e) = self.open.entry(unit.pos) {
                    e.insert(OpenSpace {
                        visited: Vec::new(),
                        rest: Use::Fresh,
                    });
                    if self.trial > 0 {
                        self.journal.push(Undo::Open(unit.pos));
                    }
                    self.set_use(unit.pos, Use::Opened);
                }
                let trial = self.trial > 0;
                if let Some(sp) = self.open.get_mut(&unit.pos) {
                    let ci = c as usize;
                    if ci >= sp.visited.len() {
                        sp.visited.push(u);
                        if trial {
                            self.journal.push(Undo::Visit(unit.pos));
                        }
                    } else if sp.visited[ci] != u
                        && !(u == Use::Unverified && sp.visited[ci] == Use::Worked)
                    {
                        let old = sp.visited[ci];
                        sp.visited[ci] = u;
                        if trial {
                            self.journal.push(Undo::VisitSet(unit.pos, c, old));
                        }
                    }
                }
            }
        }
        self.cursor = unit.cursor();
    }

    /// The anchor for working `unit` with `part`, or `None` when the part does not fit it.
    fn anchor_for(&self, unit: Unit, part: Option<PartSpec>) -> Option<Anchor> {
        let p = self.base.positions.get(unit.pos as usize)?;
        let part = part.filter(|x| !x.is_default());
        match (p.kind, unit.chain) {
            (PositionKind::Space { .. }, Some(c)) => {
                let at = self.base.chain_at(unit.pos, c)?;
                match part {
                    None => Some(Anchor::Chain {
                        at,
                        part: ChainPart::Unspecified,
                    }),
                    Some(PartSpec::Chain(cp)) => Some(Anchor::Chain { at, part: cp }),
                    Some(PartSpec::Top(_)) => None,
                }
            }
            (PositionKind::Space { .. }, None) => match (part, p.at) {
                (None, PosRef::Space(of)) => Some(Anchor::Space { of }),
                _ => None,
            },
            (PositionKind::Chain, _) => {
                let PosRef::Chain(at) = p.at else { return None };
                match part {
                    None => Some(Anchor::Chain {
                        at,
                        part: ChainPart::Unspecified,
                    }),
                    Some(PartSpec::Chain(cp)) => Some(Anchor::Chain { at, part: cp }),
                    Some(PartSpec::Top(_)) => None,
                }
            }
            (PositionKind::Stitch, _) => match (p.at, part) {
                (PosRef::StartTop(of), None) => Some(Anchor::StartTop { of }),
                (PosRef::Top(of), None) => Some(Anchor::Top {
                    of,
                    part: Part::Both,
                }),
                (PosRef::Top(of), Some(PartSpec::Top(t))) => Some(Anchor::Top { of, part: t }),
                _ => None,
            },
            (PositionKind::Ring, _) => part.is_none().then_some(Anchor::Ring),
        }
    }

    /// The anchor for `unit`, or an impossible anchor and `crochet.part_invalid`.
    fn anchor_or_invalid(&mut self, unit: Unit, part: Option<PartSpec>) -> Anchor {
        match self.anchor_for(unit, part) {
            Some(a) => a,
            None => {
                if self.admit(CrochetCode::PartInvalid) {
                    let at = self.unit_ref(unit);
                    let mut loc = self.loc();
                    loc.position = at;
                    let msg = format!(
                        "{}: that part cannot be worked at {}.",
                        self.word,
                        at.map_or("this position".to_string(), |a| a.to_string())
                    );
                    self.store(CrochetCode::PartInvalid, loc, msg, Detail::None);
                }
                Anchor::Impossible
            }
        }
    }

    fn unit_ref(&self, unit: Unit) -> Option<PosRef> {
        let p = self.base.positions.get(unit.pos as usize)?;
        match unit.chain {
            None => Some(p.at),
            Some(c) => self.base.chain_at(unit.pos, c).map(PosRef::Chain),
        }
    }

    fn unit_unverified(&self, unit: Unit) -> bool {
        self.base
            .positions
            .get(unit.pos as usize)
            .is_some_and(|p| p.unverified)
    }

    /// A target found no position: undo the trial, or report it and make an impossible anchor.
    fn miss(&mut self, m: Miss) -> Result<Anchor, Stop> {
        if self.trial > 0 {
            return Err(Stop::Trial);
        }
        let code = match m {
            Miss::PastEnd => CrochetCode::AnchorPastEnd,
            Miss::Kind | Miss::NotChain | Miss::Ring => CrochetCode::AnchorKind,
            Miss::Opened => CrochetCode::SpaceOpened,
        };
        if self.admit(code) {
            let msg = match m {
                Miss::PastEnd => format!("{}: nothing is left to work into here.", self.word),
                Miss::Kind => format!("{}: no position of that kind is left.", self.word),
                Miss::NotChain => format!("{}: the next position is not a chain.", self.word),
                Miss::Ring => format!(
                    "{}: the ring is worked into with \"ring\", never walked along.",
                    self.word
                ),
                Miss::Opened => format!(
                    "{}: this space is worked either as a whole or chain by chain, not both.",
                    self.word
                ),
            };
            let loc = self.loc();
            self.store(code, loc, msg, Detail::None);
        }
        Ok(Anchor::Impossible)
    }

    // ---- targets ------------------------------------------------------------------------------

    fn resolve(&mut self, t: &'p Target) -> Result<Resolved, Stop> {
        let plain = |anchor| Resolved {
            anchor,
            unverified: false,
            own: Own::None,
        };
        let unmodelled = Resolved {
            anchor: Anchor::Unmodelled,
            unverified: true,
            own: Own::Unmodelled,
        };
        match t {
            Target::Next { kind, part } => match self.base.find(self.cursor, *kind) {
                Ok(f) => {
                    self.step(f.passed())?;
                    self.commit(&f, Use::Worked);
                    let unverified = self.unit_unverified(f.unit);
                    Ok(Resolved {
                        anchor: self.anchor_or_invalid(f.unit, *part),
                        unverified,
                        own: Own::None,
                    })
                }
                Err(m) => Ok(plain(self.miss(m)?)),
            },
            // `same` after an opaque target or item works where that one did, which Ply does not
            // model: never silently the top of the position under the cursor. It is unverified;
            // the opaque item that put the hook there is the one reported.
            Target::Same { .. } if self.cursor_unverified => Ok(Resolved {
                own: Own::None,
                ..unmodelled
            }),
            Target::Same { part } => match self.cursor {
                Cursor::Before(_) => {
                    if self.trial > 0 {
                        return Err(Stop::Trial);
                    }
                    if self.admit(CrochetCode::SameWithoutPosition) {
                        let loc = self.loc();
                        let msg = format!(
                            "{}: \"same\" before anything has been worked into.",
                            self.word
                        );
                        self.store(CrochetCode::SameWithoutPosition, loc, msg, Detail::None);
                    }
                    Ok(plain(Anchor::Impossible))
                }
                Cursor::On(i) | Cursor::OnChain(i, _) => {
                    let unit = match self.cursor {
                        Cursor::OnChain(_, c) => Unit {
                            pos: i,
                            chain: Some(c),
                        },
                        _ => Unit::whole(i),
                    };
                    self.take(unit, Use::Worked);
                    let unverified = self.unit_unverified(unit);
                    Ok(Resolved {
                        anchor: self.anchor_or_invalid(unit, *part),
                        unverified,
                        own: Own::None,
                    })
                }
            },
            Target::Ring => {
                if self.base.ring {
                    self.take(Unit::whole(0), Use::Worked);
                    Ok(plain(Anchor::Ring))
                } else {
                    Ok(Resolved {
                        anchor: Anchor::Impossible,
                        unverified: false,
                        own: Own::RingMissing,
                    })
                }
            }
            // Refused by the structural check outside joins.
            Target::RoundStart | Target::Marker { .. } => Ok(plain(Anchor::Impossible)),
            Target::UseSite => self.use_site(),
            Target::Unmodelled { consumes, .. } => {
                self.consume(*consumes, Use::Unverified)?;
                self.cursor_unverified = true;
                Ok(unmodelled)
            }
        }
    }

    /// A named stitch's body works into its use site's target: resolved at its first use, the same
    /// position after that.
    fn use_site(&mut self) -> Result<Resolved, Stop> {
        let Some(mut site) = self.use_sites.pop() else {
            return Ok(Resolved {
                anchor: Anchor::Impossible,
                unverified: false,
                own: Own::None,
            });
        };
        if let Some((anchor, unverified)) = site.resolved.clone() {
            self.use_sites.push(site);
            return Ok(Resolved {
                anchor,
                unverified,
                own: Own::None,
            });
        }
        let r = match site.target {
            Some(t) => self.resolve(t),
            None => Ok(Resolved {
                anchor: Anchor::Impossible,
                unverified: false,
                own: Own::None,
            }),
        };
        if let Ok(res) = &r {
            site.resolved = Some((res.anchor.clone(), res.unverified));
        }
        self.use_sites.push(site);
        r
    }

    /// Move on by `n` positions of any kind, all at once or not at all, recording `u` for each.
    fn consume(&mut self, n: u32, u: Use) -> Result<(), Stop> {
        if n == 0 {
            return Ok(());
        }
        if self.base.ring {
            self.take(Unit::whole(0), u);
            return Ok(());
        }
        self.step(u64::from(n))?;
        let mut cur = self.cursor;
        for _ in 0..n {
            match self.base.find(cur, PosKind::Any) {
                Ok(f) => cur = f.unit.cursor(),
                Err(m) => {
                    self.miss(m)?;
                    return Ok(());
                }
            }
        }
        for _ in 0..n {
            match self.base.find(self.cursor, PosKind::Any) {
                Ok(f) => self.commit(&f, u),
                Err(_) => break,
            }
        }
        Ok(())
    }

    // ---- items --------------------------------------------------------------------------------

    /// The budgets for one more item or listed slip stitch: items and moves together per layer, and
    /// per piece.
    fn room(&self) -> Result<(), Stop> {
        let here = (self.items.len() + self.moves.len()) as u64;
        if here >= u64::from(self.limits.max_items_per_layer) {
            return Err(self.too_large(format!(
                "{} makes more than {} items, Ply's limit per layer.",
                self.word,
                thousands(u64::from(self.limits.max_items_per_layer))
            )));
        }
        if self.items_total >= self.limits.max_items {
            return Err(self.too_large(format!(
                "The piece makes more than {} items, Ply's limit.",
                thousands(self.limits.max_items)
            )));
        }
        Ok(())
    }

    fn make(&mut self, made: Made, anchors: Vec<Anchor>, unverified: bool) -> Result<u32, Stop> {
        self.room()?;
        // Inside an opaque named stitch (ADR 0022 section 9) every stitch is an opaque item, never
        // counted as the identity its body names; its chain runs stay spaces, unverified.
        let opaque = self.opaque_named > 0;
        let (made, anchors) = match made {
            Made::Stitch(_) | Made::Together { .. } | Made::Slip if opaque => {
                (Made::Opaque, vec![Anchor::Unmodelled])
            }
            other => (other, anchors),
        };
        let number = if matches!(made, Made::StartChain { .. }) {
            0
        } else {
            let n = self.next_item;
            self.next_item = n.saturating_add(1);
            n
        };
        let id = ItemId::new(self.layer, number);
        let stitch_like = matches!(
            made,
            Made::Stitch(_) | Made::Together { .. } | Made::Slip | Made::Opaque
        );
        let mut mark = None;
        if stitch_like {
            if let Some(name) = self.pending_mark.take() {
                if self.markers.iter().any(|(n, _)| *n == name) {
                    if self.admit(CrochetCode::MarkerDuplicate) {
                        let loc = CrochetLocation {
                            item: Some(number),
                            ..self.loc()
                        };
                        let msg = format!(
                            "{}: marker {:?} is placed again.",
                            self.word,
                            crate::diagnostic::excerpt(name, 40)
                        );
                        self.store(CrochetCode::MarkerDuplicate, loc, msg, Detail::None);
                    }
                } else {
                    self.markers.push((name, id));
                    mark = Some(name.to_string());
                }
            }
        }
        if self.out.is_on() {
            for a in &anchors {
                if let Anchor::Top {
                    part: p @ (Part::FrontLoop | Part::BackLoop),
                    ..
                } = a
                {
                    self.ridges.push((id, *p));
                }
            }
        }
        let unverified = unverified || opaque || matches!(made, Made::Opaque);
        self.items.push(MadeItem {
            id,
            made,
            anchors,
            unverified,
            source: self.path.clone(),
            repetition: self.reps.clone(),
            named: self.named.first().copied(),
            mark,
        });
        self.items_total = self.items_total.saturating_add(1);
        Ok(number)
    }

    /// List a join or travelling slip stitch (they count against the item budgets).
    fn push_move(&mut self, role: SlipRole, anchor: Anchor) -> Result<(), Stop> {
        self.room()?;
        self.moves.push(SlipMove {
            role,
            anchor,
            source: self.path.clone(),
            repetition: self.reps.clone(),
            after: self.items.len() as u32,
        });
        self.items_total = self.items_total.saturating_add(1);
        Ok(())
    }

    fn report_own(&mut self, owns: &[Own], item: Option<u32>) {
        for &o in owns {
            match o {
                Own::None => {}
                Own::RingMissing => self.own_diag(CrochetCode::RingMissing, item),
                Own::Unmodelled => self.own_diag(CrochetCode::UnsupportedTarget, item),
            }
        }
    }

    // ---- instructions -------------------------------------------------------------------------

    fn run_list(&mut self, list: &'p [Instr]) -> Result<(), Stop> {
        for (i, ins) in list.iter().enumerate() {
            let top = self.body_depth == 0;
            if top {
                self.path.push(i as u32);
            }
            let r = self.run_instr(ins);
            if top {
                self.path.pop();
            }
            r?;
            if self.left {
                break;
            }
        }
        Ok(())
    }

    fn run_instr(&mut self, ins: &'p Instr) -> Result<(), Stop> {
        self.step(1)?;
        // Each operation names the item it makes; nothing else is located at an item.
        self.cur_item = None;
        match ins {
            Instr::Start(sc) => self.start(sc),
            Instr::Work { op, mark } => {
                if let Some(m) = mark {
                    self.pending_mark = Some(m.as_str());
                }
                let r = self.work(op);
                if self.body_depth == 0 {
                    self.pending_mark = None;
                }
                r
            }
            Instr::Skip { count, kind } => {
                self.cur_item = None;
                self.skip(*count, *kind)
            }
            Instr::Repeat { body, count } => self.repeat(body, *count),
            Instr::LeaveUnworked => self.leave(),
            Instr::Opaque {
                consumes, makes, ..
            } => self.opaque(*consumes, *makes),
        }
    }

    fn start(&mut self, sc: &StartChain) -> Result<(), Stop> {
        self.cur_item = Some(0);
        let counts = sc.counts_as.stitch().map(Counted::Basic);
        let space = match sc.counts_as {
            CountsAs::StitchAndSpace { chains, .. } => Some(chains),
            _ => None,
        };
        let made = |taken| Made::StartChain {
            chains: sc.chains,
            counts,
            space,
            from_foundation: sc.from_foundation,
            taken,
        };
        if sc.from_foundation {
            // Made of the foundation chains nearest the hook; it stands on no position, and the
            // base already starts at the first remaining chain (ADR 0022 section 6, form a).
            let taken = match self.chk.p.start {
                PieceStart::FoundationChain(n) => {
                    Some((n.saturating_sub(sc.chains).saturating_add(1), n))
                }
                _ => None,
            };
            self.make(made(taken), Vec::new(), false)?;
            return Ok(());
        }
        if !sc.counts_as.counts() {
            self.make(made(None), Vec::new(), false)?;
            return Ok(());
        }
        // Counted, of new chains: it stands on the cursor's position, or the first one.
        let unit = match self.cursor {
            Cursor::On(i) => Some(Unit::whole(i)),
            Cursor::OnChain(i, c) => Some(Unit {
                pos: i,
                chain: Some(c),
            }),
            Cursor::Before(i) => (i < self.base.len()).then_some(Unit::whole(i)),
        };
        let (anchor, unverified) = match unit {
            Some(u) => {
                self.take(u, Use::Worked);
                (self.anchor_or_invalid(u, None), self.unit_unverified(u))
            }
            None => (self.miss(Miss::PastEnd)?, false),
        };
        self.make(made(None), vec![anchor], unverified)?;
        Ok(())
    }

    fn work(&mut self, op: &'p Op) -> Result<(), Stop> {
        match op {
            Op::Chain { count } => {
                self.cur_item = Some(self.next_item);
                self.make(Made::ChainRun { chains: *count }, Vec::new(), false)?;
            }
            Op::Slip { role, into } => match role {
                SlipRole::Stitch => {
                    self.cur_item = Some(self.next_item);
                    let r = self.resolve(into)?;
                    let k = self.make(Made::Slip, vec![r.anchor], r.unverified)?;
                    self.report_own(&[r.own], Some(k));
                }
                SlipRole::Travel => {
                    self.cur_item = None;
                    let r = self.resolve(into)?;
                    self.push_move(SlipRole::Travel, r.anchor)?;
                    self.report_own(&[r.own], None);
                }
                SlipRole::Join => self.join(into)?,
            },
            Op::Stitch { stitch, into, n } => {
                self.cur_item = Some(self.next_item);
                let r = self.resolve(into)?;
                let mut first = None;
                for _ in 0..*n {
                    let k =
                        self.make(Made::Stitch(*stitch), vec![r.anchor.clone()], r.unverified)?;
                    first.get_or_insert(k);
                }
                self.report_own(&[r.own], first);
            }
            Op::Together { stitch, legs } => {
                self.cur_item = Some(self.next_item);
                let mut anchors = Vec::with_capacity(legs.len());
                let mut owns = Vec::with_capacity(legs.len());
                let mut unverified = false;
                for leg in legs {
                    let r = self.resolve(leg)?;
                    anchors.push(r.anchor);
                    owns.push(r.own);
                    unverified |= r.unverified;
                }
                let k = self.make(
                    Made::Together {
                        stitch: *stitch,
                        legs: legs.len() as u32,
                    },
                    anchors,
                    unverified,
                )?;
                self.report_own(&owns, Some(k));
            }
            Op::Named { id, into } => {
                let Some(&e) = self.chk.legend_index.get(id.as_str()) else {
                    return Ok(());
                };
                let Some(entry) = self.chk.p.legend.get(e) else {
                    return Ok(());
                };
                // A body that uses anything opaque makes the whole named stitch opaque (ADR 0022
                // section 9): its stitches are opaque items, the positions it uses are used by an
                // opaque item, and the use site gets one `crochet.unsupported_op`.
                let opaque = self.chk.opaque_legend.get(e).copied().unwrap_or(false);
                let first = self.next_item;
                self.cur_item = Some(first);
                self.use_sites.push(UseSite {
                    target: into.as_ref(),
                    resolved: None,
                });
                self.named.push(e as u32);
                self.body_depth += 1;
                if opaque {
                    self.opaque_named += 1;
                }
                let r = self.run_list(&entry.body);
                if opaque {
                    self.opaque_named -= 1;
                }
                self.body_depth -= 1;
                self.named.pop();
                self.use_sites.pop();
                if self.body_depth == 0 {
                    self.pending_mark = None;
                }
                if opaque && self.opaque_named == 0 {
                    // The positions after it are where the named stitch left the hook: worked by
                    // something Ply does not check.
                    self.cursor_unverified = true;
                    let made = (self.next_item > first).then_some(first);
                    self.own_diag(CrochetCode::UnsupportedOp, made);
                }
                r?;
            }
        }
        Ok(())
    }

    /// The round's first counted item: its counted starting chain's top, or its first stitch.
    fn round_start(&self) -> Option<Anchor> {
        for it in &self.items {
            match it.made {
                Made::StartChain {
                    counts: Some(_), ..
                } => return Some(Anchor::StartTop { of: it.id }),
                Made::StartChain { .. } | Made::ChainRun { .. } => continue,
                _ => {
                    return Some(Anchor::Top {
                        of: it.id,
                        part: Part::Both,
                    })
                }
            }
        }
        None
    }

    fn join(&mut self, into: &'p Target) -> Result<(), Stop> {
        self.cur_item = None;
        let anchor = match into {
            Target::RoundStart => match self.round_start() {
                Some(a) => a,
                None => {
                    if self.admit(CrochetCode::JoinTarget) {
                        let loc = self.loc();
                        let msg = format!("{}: the round has no stitch to join into.", self.word);
                        self.store(CrochetCode::JoinTarget, loc, msg, Detail::None);
                    }
                    Anchor::Impossible
                }
            },
            Target::Marker { name, part } => {
                match self
                    .markers
                    .iter()
                    .find(|(n, _)| *n == name.as_str())
                    .map(|&(_, id)| id)
                {
                    Some(of) => match part.filter(|x| !x.is_default()) {
                        None => Anchor::Top {
                            of,
                            part: Part::Both,
                        },
                        Some(PartSpec::Top(p)) => Anchor::Top { of, part: p },
                        Some(PartSpec::Chain(_)) => {
                            if self.admit(CrochetCode::PartInvalid) {
                                let loc = self.loc();
                                let msg = format!(
                                    "{}: a chain's part cannot be worked in a stitch.",
                                    self.word
                                );
                                self.store(CrochetCode::PartInvalid, loc, msg, Detail::None);
                            }
                            Anchor::Impossible
                        }
                    },
                    None => {
                        if self.admit(CrochetCode::MarkerUnknown) {
                            let loc = self.loc();
                            let msg = format!(
                                "{}: marker {:?} was not placed before the join.",
                                self.word,
                                crate::diagnostic::excerpt(name, 40)
                            );
                            self.store(CrochetCode::MarkerUnknown, loc, msg, Detail::None);
                        }
                        Anchor::Impossible
                    }
                }
            }
            _ => Anchor::Impossible,
        };
        self.push_move(SlipRole::Join, anchor.clone())?;
        self.join = Some(anchor);
        Ok(())
    }

    fn skip(&mut self, n: u32, kind: PosKind) -> Result<(), Stop> {
        self.step(u64::from(n))?;
        let mut cur = self.cursor;
        for _ in 0..n {
            match self.base.find(cur, kind) {
                Ok(f) => cur = f.unit.cursor(),
                Err(m) => {
                    self.miss(m)?;
                    return Ok(());
                }
            }
        }
        for _ in 0..n {
            match self.base.find(self.cursor, kind) {
                Ok(f) => {
                    self.step(f.passed())?;
                    self.commit(&f, Use::Skipped);
                }
                Err(_) => break,
            }
        }
        Ok(())
    }

    fn repeat(&mut self, body: &'p [Instr], count: RepeatCount) -> Result<(), Stop> {
        match count {
            RepeatCount::Times(k) => {
                for r in 1..=k {
                    self.step(1)?;
                    let top = self.body_depth == 0;
                    if top {
                        self.reps.push(r);
                    }
                    let res = self.run_list(body);
                    if top {
                        self.reps.pop();
                    }
                    res?;
                }
                Ok(())
            }
            RepeatCount::ToEnd => self.repeat_until(body, 0),
            RepeatCount::ToLast(m) => self.repeat_until(body, m),
        }
    }

    /// `to_end` (want 0) and `to_last(want)`, by the stopping rules of ADR 0022 section 11.
    fn repeat_until(&mut self, body: &'p [Instr], want: u32) -> Result<(), Stop> {
        if self.base.ring {
            if self.admit(CrochetCode::RepeatDoesNotFit) {
                let loc = self.loc();
                let msg = format!(
                    "{}: a ring never runs out, so a repeat across or to the last stitches cannot \
                     end; give the number of times.",
                    self.word
                );
                self.store(
                    CrochetCode::RepeatDoesNotFit,
                    loc,
                    msg,
                    Detail::Positions {
                        listed: vec![PosRef::Ring],
                        total: 1,
                    },
                );
            }
            let start = self.base.start_index(self.cursor);
            self.excused_from = Some(self.excused_from.map_or(start, |e| e.min(start)));
            return Ok(());
        }
        let want = u64::from(want);
        let mut rep: u32 = 0;
        loop {
            if self.base.remaining(self.cursor) <= want {
                break;
            }
            self.step(1)?;
            rep = rep.saturating_add(1);
            let snap = self.snapshot();
            let before = self.cursor.ordinal();
            self.trial += 1;
            let top = self.body_depth == 0;
            if top {
                self.reps.push(rep);
            }
            let res = self.run_list(body);
            if top {
                self.reps.pop();
            }
            self.trial -= 1;
            match res {
                Ok(()) => {
                    if self.cursor.ordinal() <= before || self.base.remaining(self.cursor) < want {
                        self.rollback(snap);
                        break;
                    }
                    self.commit_trial();
                }
                Err(Stop::Trial) => {
                    self.rollback(snap);
                    break;
                }
                Err(Stop::Unknown) => {
                    self.commit_trial();
                    return Err(Stop::Unknown);
                }
                Err(e) => return Err(e),
            }
        }
        if self.base.remaining(self.cursor) != want {
            self.does_not_fit(want);
        }
        Ok(())
    }

    /// One `crochet.repeat_does_not_fit` listing every position left ahead of the cursor.
    fn does_not_fit(&mut self, want: u64) {
        let start = self.base.start_index(self.cursor);
        self.excused_from = Some(self.excused_from.map_or(start, |e| e.min(start)));
        if self.base.open_remaining(self.cursor) > 0 {
            if let Cursor::OnChain(i, _) = self.cursor {
                self.excused_rest = Some(i);
            }
        }
        if !self.admit(CrochetCode::RepeatDoesNotFit) {
            return;
        }
        let (listed, total) = self.leftover();
        let loc = CrochetLocation {
            item: None,
            ..self.loc()
        };
        let msg = if want == 0 {
            format!(
                "{}: the repeat does not fit the base; {} left over.",
                self.word,
                count(total, "position is", "positions are")
            )
        } else {
            format!(
                "{}: the repeat does not stop with exactly {} left; {} left over.",
                self.word,
                count(want, "position", "positions"),
                count(total, "position is", "positions are")
            )
        };
        self.store(
            CrochetCode::RepeatDoesNotFit,
            loc,
            msg,
            Detail::Positions { listed, total },
        );
    }

    /// The positions ahead of the cursor: at most [`MAX_LISTED`] named, all counted.
    fn leftover(&self) -> (Vec<PosRef>, u64) {
        let mut listed = Vec::new();
        let total = self.base.remaining(self.cursor);
        if let Cursor::OnChain(i, c) = self.cursor {
            let rest = self.base.open_remaining(self.cursor);
            for k in 1..=rest.min(MAX_LISTED as u32) {
                if let Some(at) = self.base.chain_at(i, c + k) {
                    listed.push(PosRef::Chain(at));
                }
            }
        }
        let start = self.base.start_index(self.cursor) as usize;
        for p in self.base.positions.iter().skip(start) {
            if listed.len() >= MAX_LISTED {
                break;
            }
            listed.push(p.at);
        }
        (listed, total)
    }

    fn leave(&mut self) -> Result<(), Stop> {
        self.left = true;
        let rem = self.base.remaining(self.cursor);
        if rem == 0 {
            if self.admit(CrochetCode::LeaveUnworkedEmpty) {
                let loc = CrochetLocation {
                    item: None,
                    ..self.loc()
                };
                let msg = format!("{}: nothing is left to leave unworked.", self.word);
                self.store(CrochetCode::LeaveUnworkedEmpty, loc, msg, Detail::None);
            }
            return Ok(());
        }
        self.step(rem)?;
        if self.base.open_remaining(self.cursor) > 0 {
            if let Cursor::OnChain(i, _) = self.cursor {
                if let Some(sp) = self.open.get_mut(&i) {
                    sp.rest = Use::Left;
                }
            }
        }
        for i in self.base.start_index(self.cursor)..self.base.len() {
            self.set_use(i, Use::Left);
        }
        Ok(())
    }

    fn opaque(&mut self, consumes: Option<u32>, makes: Option<u32>) -> Result<(), Stop> {
        match (consumes, makes) {
            (Some(c), Some(k)) => {
                self.cur_item = Some(self.next_item);
                self.consume(c, Use::Unverified)?;
                self.cursor_unverified = true;
                let mut first = None;
                for _ in 0..k {
                    let n = self.make(Made::Opaque, vec![Anchor::Unmodelled], true)?;
                    first.get_or_insert(n);
                }
                self.own_diag(CrochetCode::UnsupportedOp, first);
                Ok(())
            }
            _ => {
                self.cur_item = None;
                self.own_diag(CrochetCode::UnsupportedOp, None);
                self.unknown_at = Some(self.path.clone());
                Err(Stop::Unknown)
            }
        }
    }

    // ---- the end of the layer -----------------------------------------------------------------

    fn map_use(&self, u: Use, unknown: bool) -> BaseUse {
        match u {
            Use::Fresh if unknown => BaseUse::Unknown,
            Use::Fresh => BaseUse::NotReached,
            Use::Worked => BaseUse::Worked,
            Use::Skipped => BaseUse::Skipped,
            Use::Passed => BaseUse::Passed,
            Use::Left => BaseUse::LeftUnworked,
            Use::Unverified => BaseUse::Unverified,
            Use::Opened => BaseUse::ByChain,
        }
    }

    fn slots(&self, unknown: bool) -> Vec<BaseSlot> {
        self.base
            .positions
            .iter()
            .enumerate()
            .map(|(i, p)| {
                let u = self.uses.get(i).copied().unwrap_or(Use::Fresh);
                let chains = self.open.get(&(i as u32)).map(|sp| ChainUses {
                    visited: sp
                        .visited
                        .iter()
                        .map(|&v| self.map_use(v, unknown))
                        .collect(),
                    rest: self.map_use(sp.rest, unknown),
                    rest_count: self
                        .base
                        .chains(i as u32)
                        .saturating_sub(sp.visited.len() as u32),
                });
                BaseSlot {
                    position: *p,
                    used: self.map_use(u, unknown),
                    chains,
                }
            })
            .collect()
    }

    /// The warnings and information of a finished layer: base not used up, passed positions,
    /// single-loop ridges. Each is built only when it will be listed.
    fn finish_diags(&mut self, facing: Option<Side>, unknown: bool) {
        if !self.out.is_on() {
            return;
        }
        if !unknown && !self.left {
            let start = self.base.start_index(self.cursor);
            let open = self.base.open_remaining(self.cursor);
            let open_excused = match self.cursor {
                Cursor::OnChain(i, _) => {
                    self.excused_rest == Some(i) || self.excused_from.is_some_and(|e| e <= i)
                }
                _ => false,
            };
            let open = if open_excused { 0 } else { open };
            let from = self
                .excused_from
                .map_or(self.base.len(), |e| e.max(start))
                .min(self.base.len());
            let total = u64::from(open) + u64::from(from.saturating_sub(start));
            if total > 0 && self.admit(CrochetCode::BaseUnfinished) {
                let mut listed = Vec::new();
                if let Cursor::OnChain(i, c) = self.cursor {
                    for k in 1..=open.min(MAX_LISTED as u32) {
                        if let Some(at) = self.base.chain_at(i, c + k) {
                            listed.push(PosRef::Chain(at));
                        }
                    }
                }
                for i in start..from {
                    if listed.len() >= MAX_LISTED {
                        break;
                    }
                    listed.push(self.base.positions[i as usize].at);
                }
                let msg = format!(
                    "{} ends with {} of its base not reached.",
                    self.word,
                    count(total, "position", "positions")
                );
                self.store(
                    CrochetCode::BaseUnfinished,
                    CrochetLocation::layer(self.layer),
                    msg,
                    Detail::Positions { listed, total },
                );
            }
        }
        if !self.passed.is_empty() && self.admit(CrochetCode::PassedOver) {
            let mut listed = Vec::new();
            let mut total: u64 = 0;
            for p in &self.passed {
                match *p {
                    Passed::Whole(i) => {
                        total += 1;
                        if listed.len() < MAX_LISTED {
                            if let Some(pos) = self.base.positions.get(i as usize) {
                                listed.push(pos.at);
                            }
                        }
                    }
                    Passed::Rest { space, from } => {
                        let chains = self.base.chains(space);
                        total += u64::from(chains.saturating_sub(from));
                        for c in from..chains {
                            if listed.len() >= MAX_LISTED {
                                break;
                            }
                            if let Some(at) = self.base.chain_at(space, c) {
                                listed.push(PosRef::Chain(at));
                            }
                        }
                    }
                }
            }
            let msg = format!(
                "{} passes over {}, leaving them unworked.",
                self.word,
                count(total, "position", "positions")
            );
            self.store(
                CrochetCode::PassedOver,
                CrochetLocation::layer(self.layer),
                msg,
                Detail::Positions { listed, total },
            );
        }
        // Back loop only leaves the front loop on the facing side; front loop only, the far side.
        // (side, items listed, how many items, the last item counted)
        let mut groups: Vec<(Option<Side>, Vec<ItemId>, u64, ItemId)> = Vec::new();
        for &(id, part) in &self.ridges {
            let side = facing.map(|f| if part == Part::BackLoop { f } else { f.other() });
            match groups.iter_mut().find(|g| g.0 == side) {
                Some((_, items, total, last)) => {
                    if *last != id {
                        *last = id;
                        *total += 1;
                        if items.len() < MAX_LISTED {
                            items.push(id);
                        }
                    }
                }
                None => groups.push((side, vec![id], 1, id)),
            }
        }
        for (side, items, total, _) in groups {
            if !self.admit(CrochetCode::UnworkedLoops) {
                continue;
            }
            let msg = format!(
                "{} leaves a ridge of unworked loops on {}.",
                self.word,
                match side {
                    Some(Side::A) => "side A",
                    Some(Side::B) => "side B",
                    None => "a side Ply cannot tell (an earlier layer is opaque)",
                }
            );
            self.store(
                CrochetCode::UnworkedLoops,
                CrochetLocation::layer(self.layer),
                msg,
                Detail::Ridge { side, items, total },
            );
        }
    }
}

/// The sentence of a diagnostic that belongs to an instruction itself.
fn own_message(code: CrochetCode, word: &str) -> String {
    match code {
        CrochetCode::UnsupportedOp => {
            format!("{word}: an operation Ply does not model, kept in the pattern's words and not checked.")
        }
        CrochetCode::UnsupportedTarget => format!(
            "{word}: a stitch worked somewhere Ply does not model; its attachment is not checked."
        ),
        CrochetCode::RingMissing => {
            format!("{word}: only round 1 of a piece started in a ring works into the ring.")
        }
        _ => format!("{word}: {}", code.as_str()),
    }
}

// ---------------------------------------------------------------------------------------------
// The whole piece.

/// What the layer before gives the next one.
struct Prev {
    positions: Vec<Position>,
    shape: LayerShape,
    join: Option<PosRef>,
    facing: Option<Side>,
}

/// The result of resolving a piece (its diagnostics went to the collector).
pub(crate) struct Resolution {
    pub layers: Vec<ResolvedLayer>,
}

fn shape_of(kind: &LayerKind) -> LayerShape {
    match kind {
        LayerKind::Foundation { .. } => LayerShape::Foundation,
        LayerKind::Row { .. } => LayerShape::Row,
        LayerKind::Round { close, turn, .. } => LayerShape::Round {
            close: *close,
            turn: *turn,
        },
        LayerKind::Opaque { .. } => LayerShape::Opaque,
    }
}

/// Layer 1's base: the foundation chains from the hook end (after those a form (a) chain takes), or
/// the ring.
fn first_base(chk: &Checked<'_>, work: &[Instr]) -> Base {
    match chk.p.start {
        PieceStart::FoundationChain(n) => {
            let taken = match work.first() {
                Some(Instr::Start(sc)) if sc.from_foundation => sc.chains.min(n),
                _ => 0,
            };
            let positions = (1..=n - taken)
                .rev()
                .map(|i| Position::new(PosRef::Chain(ChainAt::Foundation(i)), PositionKind::Chain))
                .collect();
            Base::new(positions, false)
        }
        PieceStart::MagicRing | PieceStart::ChainRing(_) => Base::ring(),
        PieceStart::FoundationStitches => Base::new(Vec::new(), false),
    }
}

/// A later layer's base, from the layer before (ADR 0022 sections 7 and 8).
fn next_base(prev: &Prev, kind: &LayerKind) -> Base {
    let n = prev.positions.len();
    let rotate_from = |j: usize, reverse: bool| -> Vec<Position> {
        (0..n)
            .map(|k| {
                let i = if reverse {
                    (j + n - k) % n
                } else {
                    (j + k) % n
                };
                prev.positions[i]
            })
            .collect()
    };
    match kind {
        LayerKind::Row { .. } => {
            let mut v = prev.positions.clone();
            v.reverse();
            Base::new(v, true)
        }
        LayerKind::Round { turn, .. } => {
            let j = match prev.shape {
                LayerShape::Round {
                    close: Close::Join, ..
                } => prev
                    .join
                    .and_then(|r| prev.positions.iter().position(|p| p.at == r))
                    .unwrap_or(0),
                _ => 0,
            };
            if n == 0 {
                Base::new(Vec::new(), *turn)
            } else {
                Base::new(rotate_from(j, *turn), *turn)
            }
        }
        LayerKind::Foundation { .. } | LayerKind::Opaque { .. } => {
            Base::new(prev.positions.clone(), false)
        }
    }
}

/// Every diagnostic that belongs to an instruction itself and was not reported while resolving:
/// opaque instructions, opaque targets and rings in a layer that has none, through repeats and the
/// bodies of named stitches (reported at the use site).
fn scan_own(
    chk: &Checked<'_>,
    list: &[Instr],
    layer: u32,
    word: &str,
    has_ring: bool,
    path: &mut Vec<u32>,
    reported: &mut HashSet<(Vec<u32>, CrochetCode)>,
    out: &mut Collector,
) {
    for (i, ins) in list.iter().enumerate() {
        path.push(i as u32);
        let mut codes = Vec::new();
        own_codes(chk, ins, has_ring, 0, &mut codes);
        for code in codes {
            let key = (path.clone(), code);
            if reported.insert(key) {
                out.push_with(code, || {
                    Diagnostic::new(
                        code,
                        CrochetLocation::instruction(layer, path.clone()),
                        own_message(code, word),
                    )
                });
            }
        }
        if let Instr::Repeat { body, .. } = ins {
            scan_own(chk, body, layer, word, has_ring, path, reported, out);
        }
        path.pop();
    }
}

/// The own diagnostics of one instruction (not of its repeat body, which `scan_own` walks with
/// paths); a named stitch's body counts as the use site's.
fn own_codes(
    chk: &Checked<'_>,
    ins: &Instr,
    has_ring: bool,
    named_depth: usize,
    out: &mut Vec<CrochetCode>,
) {
    let add = |c: CrochetCode, out: &mut Vec<CrochetCode>| {
        if !out.contains(&c) {
            out.push(c);
        }
    };
    match ins {
        Instr::Opaque { .. } => add(CrochetCode::UnsupportedOp, out),
        Instr::Work { op, .. } => {
            for t in op_targets(op) {
                match t {
                    Target::Unmodelled { .. } => add(CrochetCode::UnsupportedTarget, out),
                    Target::Ring if !has_ring => add(CrochetCode::RingMissing, out),
                    _ => {}
                }
            }
            if let Op::Named { id, .. } = op {
                // The legend has no cycle (the structural check refuses one), so this ends; the
                // bound only guards the stack.
                if named_depth < crate::limits::MAX_SOUND_DEPTH {
                    if let Some(&e) = chk.legend_index.get(id.as_str()) {
                        if let Some(entry) = chk.p.legend.get(e) {
                            let mut inner = Vec::new();
                            body_own(chk, &entry.body, has_ring, named_depth + 1, 0, &mut inner);
                            // An opaque named stitch is one opaque item: its opaque targets are
                            // reported as the item, never one by one.
                            let opaque = chk.opaque_legend.get(e).copied().unwrap_or(false);
                            for c in inner {
                                let c = if opaque && c == CrochetCode::UnsupportedTarget {
                                    CrochetCode::UnsupportedOp
                                } else {
                                    c
                                };
                                add(c, out);
                            }
                        }
                    }
                }
            }
        }
        _ => {}
    }
}

fn body_own(
    chk: &Checked<'_>,
    list: &[Instr],
    has_ring: bool,
    named_depth: usize,
    depth: usize,
    out: &mut Vec<CrochetCode>,
) {
    for ins in list {
        own_codes(chk, ins, has_ring, named_depth, out);
        if let Instr::Repeat { body, .. } = ins {
            if depth < crate::limits::MAX_SOUND_DEPTH {
                body_own(chk, body, has_ring, named_depth, depth + 1, out);
            }
        }
    }
}

/// Compare a known count with the stated one: met, or a `crochet.count_mismatch` showing both.
fn check_stated(
    c: &LayerCount,
    stated: Option<&crate::pattern::StatedCount>,
    layer: u32,
    word: &str,
    out: &mut Collector,
) -> Option<StatedCheck> {
    let s = stated?;
    let diffs = c.differences(s);
    if diffs.is_empty() {
        return Some(StatedCheck::Met);
    }
    out.push_with(CrochetCode::CountMismatch, || {
        Diagnostic::new(
            CrochetCode::CountMismatch,
            CrochetLocation::layer(layer),
            format!("{word}'s stated count differs from its stitches."),
        )
        .with_detail(Detail::Counts(diffs))
    });
    Some(StatedCheck::Mismatch)
}

/// Resolve the whole piece, keeping layers `keep.0` to `keep.1` (all when `None`), its diagnostics
/// going to `out` (switched off when nobody reads them). Only called on a pattern the structural
/// check did not refuse.
pub(crate) fn resolve_piece(
    chk: &Checked<'_>,
    limits: &CrochetLimits,
    keep: Option<(u32, u32)>,
    out: &mut Collector,
) -> Result<Resolution, Box<Diagnostic>> {
    let p = chk.p;
    let last_layer = p.layers.len() as u32;
    let keep_layer = |pos: u32| keep.is_none_or(|(a, b)| pos >= a && pos <= b);
    let mut out_layers = Vec::new();
    let mut prev: Option<Prev> = None;
    let mut unknown = false;
    let mut items_total: u64 = 0;
    for (idx, layer) in p.layers.iter().enumerate() {
        let pos = idx as u32 + 1;
        let shape = shape_of(&layer.kind);
        let word = layer_word(&layer.kind, pos);
        let prev_facing = prev.as_ref().and_then(|pr| pr.facing);
        let facing = match (&layer.kind, pos) {
            (LayerKind::Opaque { .. }, _) => None,
            (_, 1) | (LayerKind::Foundation { .. }, _) => Some(Side::A),
            (LayerKind::Row { .. }, _) => prev_facing.map(Side::other),
            (LayerKind::Round { turn, .. }, _) => {
                if *turn {
                    prev_facing.map(Side::other)
                } else {
                    prev_facing
                }
            }
        };
        let has_ring =
            pos == 1 && matches!(p.start, PieceStart::MagicRing | PieceStart::ChainRing(_));
        let stated = layer.stated.as_ref();
        if unknown {
            if out.is_on() {
                let mut reported = HashSet::new();
                scan_own(
                    chk,
                    layer.work(),
                    pos,
                    &word,
                    has_ring,
                    &mut Vec::new(),
                    &mut reported,
                    out,
                );
            }
            if let LayerKind::Opaque { .. } = layer.kind {
                out.push_with(CrochetCode::UnsupportedLayer, || {
                    Diagnostic::new(
                        CrochetCode::UnsupportedLayer,
                        CrochetLocation::layer(pos),
                        format!("{word} is kept in the pattern's words and not checked."),
                    )
                });
            }
            if keep_layer(pos) {
                out_layers.push(ResolvedLayer {
                    layer: pos,
                    id: layer.id.clone(),
                    shape,
                    facing,
                    base: if matches!(layer.kind, LayerKind::Foundation { .. }) {
                        ResolvedBase::None
                    } else {
                        ResolvedBase::Unknown
                    },
                    made: Vec::new(),
                    moves: Vec::new(),
                    count: None,
                    stated: stated.map(|_| StatedCheck::CannotBeChecked),
                    spiral_marker: None,
                    unknown_from: None,
                });
            }
            prev = Some(Prev {
                positions: Vec::new(),
                shape,
                join: None,
                facing,
            });
            continue;
        }
        let base = match &prev {
            None => first_base(chk, layer.work()),
            Some(pr) => next_base(pr, &layer.kind),
        };
        let mut resolved = ResolvedLayer {
            layer: pos,
            id: layer.id.clone(),
            shape,
            facing,
            base: ResolvedBase::None,
            made: Vec::new(),
            moves: Vec::new(),
            count: None,
            stated: None,
            spiral_marker: None,
            unknown_from: None,
        };
        let mut join = None;
        match &layer.kind {
            LayerKind::Foundation { stitch, stitches } => {
                if u64::from(*stitches) > u64::from(limits.max_items_per_layer)
                    || items_total.saturating_add(u64::from(*stitches)) > limits.max_items
                {
                    return Err(Box::new(Diagnostic::new(
                        CrochetCode::TooLarge,
                        CrochetLocation::layer(pos),
                        format!("{word} passes Ply's limit on items."),
                    )));
                }
                resolved.made = (1..=*stitches)
                    .map(|k| MadeItem {
                        id: ItemId::new(pos, k),
                        made: Made::Foundation(*stitch),
                        anchors: Vec::new(),
                        unverified: false,
                        source: Vec::new(),
                        repetition: Vec::new(),
                        named: None,
                        mark: None,
                    })
                    .collect();
                let c = count_of(&resolved.made);
                resolved.stated = check_stated(&c, stated, pos, &word, out);
                resolved.count = Some(c);
            }
            LayerKind::Opaque { .. } => {
                out.push_with(CrochetCode::UnsupportedLayer, || {
                    Diagnostic::new(
                        CrochetCode::UnsupportedLayer,
                        CrochetLocation::layer(pos),
                        format!("{word} is kept in the pattern's words and not checked."),
                    )
                });
                resolved.base = ResolvedBase::Known(
                    base.positions
                        .iter()
                        .map(|&position| BaseSlot {
                            position,
                            used: BaseUse::Unverified,
                            chains: None,
                        })
                        .collect(),
                );
                // Its stitches, if its stated count gives them and no spaces.
                let known = stated.and_then(|s| {
                    if s.spaces.unwrap_or(0) != 0 {
                        return None;
                    }
                    s.stitches.or_else(|| {
                        (!s.by_identity.is_empty()).then(|| {
                            s.by_identity
                                .values()
                                .fold(0u32, |a, &v| a.saturating_add(v))
                        })
                    })
                });
                match known {
                    Some(k) => {
                        if u64::from(k) > u64::from(limits.max_items_per_layer)
                            || items_total.saturating_add(u64::from(k)) > limits.max_items
                        {
                            return Err(Box::new(Diagnostic::new(
                                CrochetCode::TooLarge,
                                CrochetLocation::layer(pos),
                                format!("{word}'s stated count passes Ply's limit on items."),
                            )));
                        }
                        resolved.made = (1..=k)
                            .map(|n| MadeItem {
                                id: ItemId::new(pos, n),
                                made: Made::Opaque,
                                anchors: vec![Anchor::Unmodelled],
                                unverified: true,
                                source: Vec::new(),
                                repetition: Vec::new(),
                                named: None,
                                mark: None,
                            })
                            .collect();
                        resolved.count = Some(count_of(&resolved.made));
                        resolved.stated = Some(StatedCheck::CannotBeChecked);
                    }
                    None => {
                        unknown = true;
                        resolved.unknown_from = Some(Vec::new());
                        resolved.stated = stated.map(|_| StatedCheck::CannotBeChecked);
                        out.push_with(CrochetCode::CountUnknown, || {
                            Diagnostic::new(
                                CrochetCode::CountUnknown,
                                CrochetLocation::layer(pos),
                                format!(
                                    "{word} does not state its stitches, so no count from here \
                                     on can be checked."
                                ),
                            )
                            .with_detail(Detail::Layers {
                                first: pos,
                                last: last_layer,
                            })
                        });
                    }
                }
            }
            LayerKind::Row { work } | LayerKind::Round { work, .. } => {
                let mut run = Run::new(chk, limits, pos, word.clone(), &base, items_total, out);
                let res = run.run_list(work);
                let layer_unknown = match res {
                    Ok(()) => false,
                    Err(Stop::Unknown) => true,
                    Err(Stop::TooLarge(d)) => return Err(d),
                    // A trial failure never escapes a repeat.
                    Err(Stop::Trial) => false,
                };
                run.cur_item = None;
                run.finish_diags(facing, layer_unknown);
                items_total = run.items_total;
                resolved.base = ResolvedBase::Known(run.slots(layer_unknown));
                if layer_unknown {
                    unknown = true;
                    let at = run.unknown_at.clone().unwrap_or_default();
                    let loc = CrochetLocation::instruction(pos, at.clone());
                    run.out.push_with(CrochetCode::CountUnknown, || {
                        Diagnostic::new(
                            CrochetCode::CountUnknown,
                            loc,
                            format!(
                                "{word}: an opaque instruction that does not state both what it \
                                 uses and what it makes; no count from here on can be checked."
                            ),
                        )
                        .with_detail(Detail::Layers {
                            first: pos,
                            last: last_layer,
                        })
                    });
                    resolved.unknown_from = Some(at);
                    resolved.stated = stated.map(|_| StatedCheck::CannotBeChecked);
                } else {
                    let c = count_of(&run.items);
                    resolved.stated = check_stated(&c, stated, pos, &word, run.out);
                    resolved.count = Some(c);
                }
                if matches!(
                    layer.kind,
                    LayerKind::Round {
                        close: Close::Spiral,
                        ..
                    }
                ) {
                    resolved.spiral_marker = run.round_start().and_then(|a| a.position());
                }
                join = run.join.as_ref().and_then(Anchor::position);
                resolved.made = std::mem::take(&mut run.items);
                resolved.moves = std::mem::take(&mut run.moves);
                let mut reported = std::mem::take(&mut run.reported);
                drop(run);
                if out.is_on() {
                    scan_own(
                        chk,
                        work,
                        pos,
                        &word,
                        has_ring,
                        &mut Vec::new(),
                        &mut reported,
                        out,
                    );
                }
            }
        }
        if !matches!(layer.kind, LayerKind::Row { .. } | LayerKind::Round { .. }) {
            items_total = items_total.saturating_add(resolved.made.len() as u64);
        }
        prev = Some(Prev {
            positions: positions_of(&resolved.made),
            shape,
            join,
            facing,
        });
        if keep_layer(pos) {
            out_layers.push(resolved);
        }
    }
    Ok(Resolution { layers: out_layers })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn made_items_count_as_section_13_says() {
        let item = |made| MadeItem {
            id: ItemId::new(1, 1),
            made,
            anchors: Vec::new(),
            unverified: false,
            source: Vec::new(),
            repetition: Vec::new(),
            named: None,
            mark: None,
        };
        let items = vec![
            item(Made::StartChain {
                chains: 4,
                counts: Some(Counted::Basic(Basic::B1)),
                space: Some(1),
                from_foundation: false,
                taken: None,
            }),
            item(Made::Together {
                stitch: Basic::B0,
                legs: 2,
            }),
            item(Made::Slip),
            item(Made::ChainRun { chains: 2 }),
            item(Made::Opaque),
        ];
        let c = count_of(&items);
        assert_eq!(c.of(Counted::Basic(Basic::B1)), 1);
        assert_eq!(c.of(Counted::Basic(Basic::B0)), 1, "a tog is one stitch");
        assert_eq!(c.of(Counted::Slip), 1);
        assert_eq!(c.spaces, vec![(1, 1), (2, 1)]);
        assert_eq!(c.not_checked, 1);
        let kinds: Vec<_> = positions_of(&items).iter().map(|p| p.kind).collect();
        assert_eq!(
            kinds,
            vec![
                PositionKind::Stitch,
                PositionKind::Space { chains: 1 },
                PositionKind::Stitch,
                PositionKind::Stitch,
                PositionKind::Space { chains: 2 },
                PositionKind::Stitch,
            ]
        );
        assert!(positions_of(&items)[5].unverified);
    }
}
