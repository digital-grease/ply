//! The structural check: everything about a pattern that can be known without walking a base.
//!
//! Sizes are untrusted, so the counts are checked first, with saturating arithmetic and before
//! anything proportional to them is allocated: text fields, layers, instructions (each layer's tree
//! is walked no deeper than the repeat limit and no wider than the instruction limit), legend
//! entries, markers, and a lower bound on the items and steps each layer's `times` repeats make
//! ("repeat products past the caps or overflowing u32", ADR 0022 section 23).
//!
//! Findings go straight to the shared collector, counted per code as they are found, so a pattern
//! with a million errors keeps only the listed ones. Errors found here are of two sorts.
//! **Refusing** errors leave resolution undefined (an unknown legend entry, a legend cycle, a
//! misplaced starting chain or join, a repeat of 0, a `tog` with one leg, rows and rounds mixed, a
//! size limit): [`crate::try_resolve`] refuses and lists them (each code up to the cap). The other
//! findings (a legend word that collides with a label set, two layers with one id, a starting chain
//! in a spiral round) are reported beside the resolution's own.
//!
//! Lower bounds are only lower bounds: an opaque item that states `makes` but not `consumes` still
//! counts its `makes`, and the instructions after it still count, although resolution stops there;
//! and a failed try of a `to_end` repeat counts against the step budget. Either can refuse only a
//! degenerate or erroneous pattern (ADR 0022 amendment of 2026-11-18).

use crate::diagnostic::{count, thousands, Collector, CrochetCode, CrochetLocation, Diagnostic};
use crate::labels::{is_reserved_word, word_key};
use crate::limits::CrochetLimits;
use crate::pattern::{
    Close, CountsAs, CrochetPattern, Instr, LayerKind, Op, PieceStart, RepeatCount, Target,
};
use crate::stitch::SlipRole;
use std::collections::HashMap;

/// A pattern after the structural check.
pub(crate) struct Checked<'p> {
    pub p: &'p CrochetPattern,
    /// Legend entry index by id (the first entry of each id).
    pub legend_index: HashMap<&'p str, usize>,
    /// True when a refusing error was found (listed in the collector, or counted past its cap).
    pub refused: bool,
    /// For each legend entry: whether its body uses anything opaque (an opaque instruction or
    /// target, directly or through another named stitch), which makes the named stitch opaque
    /// (ADR 0022 section 9).
    pub opaque_legend: Vec<bool>,
}

impl Checked<'_> {
    pub(crate) fn refused(&self) -> bool {
        self.refused
    }
}

/// The identity words a legend id may not be (ADR 0022 section 3).
const IDENTITY_WORDS: [&str; 8] = ["chain", "slip", "b0", "b1h", "b1", "b2", "b3", "tog"];

/// "Row 3", "Round 2", "Layer 4" (an opaque layer; a foundation layer is displayed as a row).
pub(crate) fn layer_word(kind: &LayerKind, position: u32) -> String {
    match kind {
        LayerKind::Row { .. } | LayerKind::Foundation { .. } => format!("Row {position}"),
        LayerKind::Round { .. } => format!("Round {position}"),
        LayerKind::Opaque { .. } => format!("Layer {position}"),
    }
}

#[derive(Clone, Copy)]
struct Ctx {
    /// Position of the layer (from 1), or `None` in a legend body.
    layer: Option<u32>,
    legend: Option<u32>,
    /// Repeat nesting so far.
    depth: usize,
    /// True for a layer's own list (not a repeat body, not a legend body).
    top: bool,
    /// The layer is a joined round.
    joined: bool,
    spiral: bool,
}

struct Walk<'a, 'p> {
    p: &'p CrochetPattern,
    limits: &'a CrochetLimits,
    /// Where findings go, counted per code as they are found.
    out: &'a mut Collector,
    refused: bool,
    legend_index: HashMap<&'p str, usize>,
    /// For each legend entry: whether its body takes the use site's target.
    takes_target: Vec<bool>,
    /// For each legend entry: whether it makes a stitch a marker could sit in.
    makes_stitch: Vec<bool>,
    /// For each legend entry: whether its body uses anything opaque.
    opaque_legend: Vec<bool>,
    /// Marker name to (layer, path) of the instruction that places it.
    marks: HashMap<&'p str, (u32, Vec<u32>)>,
    mark_count: usize,
    /// Joins into a marker: (layer, path, name).
    join_uses: Vec<(u32, Vec<u32>, &'p str)>,
    /// Legend entries children first (entries a body uses before it), when the legend has no cycle.
    legend_order: Vec<usize>,
    /// Instructions seen in the whole document.
    instructions: usize,
    /// Instructions seen in the current list owner (a layer or a legend body).
    owner_instructions: usize,
    owner_stopped: bool,
}

impl<'a, 'p> Walk<'a, 'p> {
    fn loc(&self, ctx: Ctx, path: &[u32]) -> CrochetLocation {
        CrochetLocation {
            layer: ctx.layer,
            legend: ctx.legend,
            path: path.to_vec(),
            ..CrochetLocation::default()
        }
    }

    /// A refusing error.
    fn err(&mut self, code: CrochetCode, loc: CrochetLocation, message: impl Into<String>) {
        self.refused = true;
        self.out
            .push_with(code, || Diagnostic::new(code, loc, message));
    }

    /// A finding that does not refuse resolution.
    fn note(&mut self, code: CrochetCode, loc: CrochetLocation, message: impl Into<String>) {
        self.out
            .push_with(code, || Diagnostic::new(code, loc, message));
    }

    /// `text` within the byte limit, or a `crochet.too_large` error.
    fn text(&mut self, text: &str, what: &str, loc: CrochetLocation) {
        if text.len() > self.limits.max_text_bytes {
            let msg = format!(
                "The {what} is {}; Ply's limit is {}.",
                count(text.len() as u64, "byte", "bytes"),
                thousands(self.limits.max_text_bytes as u64)
            );
            self.err(CrochetCode::TooLarge, loc, msg);
        }
    }

    fn too_large(&mut self, loc: CrochetLocation, message: String) {
        self.err(CrochetCode::TooLarge, loc, message);
    }

    /// Walk one instruction list. Returns false when the owner's instruction limit stopped it.
    fn list(&mut self, list: &'p [Instr], ctx: Ctx, path: &mut Vec<u32>) {
        let mut seen_start = false;
        for (i, ins) in list.iter().enumerate() {
            if self.owner_stopped {
                return;
            }
            self.instructions = self.instructions.saturating_add(1);
            self.owner_instructions = self.owner_instructions.saturating_add(1);
            if self.owner_instructions > self.limits.max_instructions_per_layer {
                self.owner_stopped = true;
                let loc = self.loc(ctx, &[]);
                let msg = format!(
                    "This list has more than {} instructions (counting those inside repeats), \
                     Ply's limit.",
                    thousands(self.limits.max_instructions_per_layer as u64)
                );
                self.too_large(loc, msg);
                return;
            }
            path.push(i as u32);
            self.instr(list, i, ins, ctx, path, &mut seen_start);
            path.pop();
        }
    }

    fn instr(
        &mut self,
        list: &'p [Instr],
        i: usize,
        ins: &'p Instr,
        ctx: Ctx,
        path: &mut Vec<u32>,
        seen_start: &mut bool,
    ) {
        let loc = self.loc(ctx, path);
        let last = i + 1 == list.len();
        match ins {
            Instr::Start(sc) => {
                if !ctx.top {
                    let msg = if ctx.legend.is_some() {
                        "A starting chain cannot be part of a named stitch."
                    } else {
                        "A starting chain cannot be inside a repeat."
                    };
                    self.err(CrochetCode::StartMisplaced, loc.clone(), msg);
                } else if *seen_start {
                    self.err(
                        CrochetCode::StartMisplaced,
                        loc.clone(),
                        "This layer has two starting chains.",
                    );
                } else if !list[..i].iter().all(is_travel) {
                    self.err(
                        CrochetCode::StartMisplaced,
                        loc.clone(),
                        "A starting chain comes first in its layer, after travelling slip \
                         stitches if any.",
                    );
                }
                *seen_start = true;
                if sc.chains == 0 {
                    self.err(
                        CrochetCode::StartInvalid,
                        loc.clone(),
                        "A starting chain of 0 chains.",
                    );
                } else if sc.chains > self.limits.max_run_chains {
                    let msg = format!(
                        "A starting chain of {} chains; Ply's limit is {}.",
                        thousands(u64::from(sc.chains)),
                        thousands(u64::from(self.limits.max_run_chains))
                    );
                    self.too_large(loc.clone(), msg);
                }
                if let CountsAs::StitchAndSpace { chains, .. } = sc.counts_as {
                    if chains == 0 || chains >= sc.chains {
                        self.err(
                            CrochetCode::StartInvalid,
                            loc.clone(),
                            "A chain counting as a stitch and a space needs at least 1 chain for \
                             the space and at least 1 for the stitch.",
                        );
                    }
                }
                if sc.from_foundation {
                    let foundation = match self.p.start {
                        PieceStart::FoundationChain(n) => Some(n),
                        _ => None,
                    };
                    if ctx.layer != Some(1) || foundation.is_none() || !ctx.top {
                        self.err(
                            CrochetCode::StartInvalid,
                            loc.clone(),
                            "Only layer 1 on a foundation chain can take its starting chain from \
                             the foundation.",
                        );
                    } else if matches!(sc.counts_as, CountsAs::StitchAndSpace { .. }) {
                        self.err(
                            CrochetCode::StartInvalid,
                            loc.clone(),
                            "A starting chain taken from the foundation cannot count as a stitch \
                             and a space in v1.",
                        );
                    } else if foundation.is_some_and(|n| sc.chains > n) {
                        let msg = format!(
                            "The starting chain takes {} from a foundation of {}.",
                            count(u64::from(sc.chains), "chain", "chains"),
                            thousands(u64::from(foundation.unwrap_or(0)))
                        );
                        self.err(CrochetCode::StartInvalid, loc.clone(), msg);
                    } else if i != 0 {
                        self.err(
                            CrochetCode::StartInvalid,
                            loc.clone(),
                            "A starting chain taken from the foundation is the layer's first \
                             instruction.",
                        );
                    }
                }
                if ctx.spiral && ctx.layer.is_some_and(|l| l > 1) {
                    self.note(
                        CrochetCode::SpiralStartChain,
                        loc,
                        "A spiral round after round 1 has no starting chain.",
                    );
                }
            }
            Instr::Work { op, mark } => {
                if let Some(name) = mark {
                    self.mark(op, name, ctx, path);
                }
                self.op(op, ctx, path, last);
            }
            Instr::Skip { count: n, .. } => {
                if *n == 0 {
                    self.err(CrochetCode::RepeatZero, loc, "A skip of 0 positions.");
                } else if *n > self.limits.max_items_per_layer {
                    let msg = format!(
                        "A skip of {} positions; no base has more than {}.",
                        thousands(u64::from(*n)),
                        thousands(u64::from(self.limits.max_items_per_layer))
                    );
                    self.too_large(loc, msg);
                }
            }
            Instr::Repeat { body, count: c } => {
                match c {
                    RepeatCount::Times(0) => {
                        self.err(CrochetCode::RepeatZero, loc.clone(), "A repeat of 0 times.");
                    }
                    RepeatCount::ToLast(m) if *m > self.limits.max_items_per_layer => {
                        let msg = format!(
                            "A repeat to the last {} positions; no base has more than {}.",
                            thousands(u64::from(*m)),
                            thousands(u64::from(self.limits.max_items_per_layer))
                        );
                        self.too_large(loc.clone(), msg);
                    }
                    _ => {}
                }
                if ctx.depth + 1 > self.limits.max_repeat_depth {
                    let msg = format!(
                        "Repeats nest more than {} deep, Ply's limit.",
                        self.limits.max_repeat_depth
                    );
                    self.too_large(loc, msg);
                } else {
                    let inner = Ctx {
                        depth: ctx.depth + 1,
                        top: false,
                        ..ctx
                    };
                    self.list(body, inner, path);
                }
            }
            Instr::LeaveUnworked => {
                if !ctx.top {
                    let msg = if ctx.legend.is_some() {
                        "Leaving stitches unworked cannot be part of a named stitch."
                    } else {
                        "Leaving stitches unworked cannot be inside a repeat."
                    };
                    self.err(CrochetCode::LeaveMisplaced, loc, msg);
                } else if !last {
                    self.err(
                        CrochetCode::LeaveMisplaced,
                        loc,
                        "Leaving the rest unworked ends a layer, so it is its last instruction.",
                    );
                }
            }
            Instr::Opaque {
                text,
                consumes,
                makes,
            } => {
                self.text(text, "opaque instruction's text", loc.clone());
                for (n, what) in [(consumes, "uses"), (makes, "makes")] {
                    if let Some(n) = n {
                        if *n > self.limits.max_items_per_layer {
                            let msg = format!(
                                "An opaque instruction that {what} {} positions; Ply's limit is {}.",
                                thousands(u64::from(*n)),
                                thousands(u64::from(self.limits.max_items_per_layer))
                            );
                            self.too_large(loc.clone(), msg);
                        }
                    }
                }
            }
        }
    }

    fn mark(&mut self, op: &'p Op, name: &'p str, ctx: Ctx, path: &[u32]) {
        let loc = self.loc(ctx, path);
        self.text(name, "marker name", loc.clone());
        if ctx.legend.is_some() {
            self.err(
                CrochetCode::MarkInvalid,
                loc,
                "A named stitch's body cannot place a marker (each use would place it again).",
            );
            return;
        }
        let ok = match op {
            Op::Stitch { .. } | Op::Together { .. } => true,
            Op::Named { id, .. } => self
                .legend_index
                .get(id.as_str())
                .is_none_or(|&e| self.makes_stitch.get(e).copied().unwrap_or(true)),
            Op::Chain { .. } | Op::Slip { .. } => false,
        };
        if !ok {
            self.err(
                CrochetCode::MarkInvalid,
                loc,
                "A marker goes in a stitch; this makes none.",
            );
            return;
        }
        let Some(layer) = ctx.layer else { return };
        self.mark_count = self.mark_count.saturating_add(1);
        if self.mark_count > self.limits.max_markers {
            // Reported once for the whole piece; the table stops growing here.
            return;
        }
        if self.marks.contains_key(name) {
            let msg = format!(
                "Marker {:?} is placed twice.",
                crate::diagnostic::excerpt(name, 40)
            );
            self.err(CrochetCode::MarkerDuplicate, loc, msg);
        } else {
            self.marks.insert(name, (layer, path.to_vec()));
        }
    }

    fn op(&mut self, op: &'p Op, ctx: Ctx, path: &[u32], last: bool) {
        let loc = self.loc(ctx, path);
        match op {
            Op::Chain { count: n } => {
                if *n == 0 {
                    self.err(CrochetCode::RepeatZero, loc, "A chain run of 0 chains.");
                } else if *n > self.limits.max_run_chains {
                    let msg = format!(
                        "A run of {} chains; Ply's limit is {}.",
                        thousands(u64::from(*n)),
                        thousands(u64::from(self.limits.max_run_chains))
                    );
                    self.too_large(loc, msg);
                }
            }
            Op::Slip { role, into } => {
                if *role == SlipRole::Join {
                    self.join(into, ctx, path, last);
                } else {
                    self.target(into, ctx, path);
                }
            }
            Op::Stitch { into, n, .. } => {
                if *n == 0 {
                    self.err(
                        CrochetCode::RepeatZero,
                        loc.clone(),
                        "0 stitches into one target.",
                    );
                } else if *n > self.limits.max_n {
                    let msg = format!(
                        "{} stitches into one target; Ply's limit is {}.",
                        thousands(u64::from(*n)),
                        thousands(u64::from(self.limits.max_n))
                    );
                    self.too_large(loc.clone(), msg);
                }
                self.target(into, ctx, path);
            }
            Op::Together { legs, .. } => {
                let n = legs.len();
                if n < 2 || n > self.limits.max_legs as usize {
                    let msg = format!(
                        "A stitch worked together has {}; it needs 2 to {}.",
                        count(n as u64, "leg", "legs"),
                        self.limits.max_legs
                    );
                    self.err(CrochetCode::TogetherLegs, loc, msg);
                }
                for leg in legs.iter().take(self.limits.max_legs as usize + 1) {
                    self.target(leg, ctx, path);
                }
            }
            Op::Named { id, into } => {
                self.text(id.as_str(), "legend id", loc.clone());
                match self.legend_index.get(id.as_str()) {
                    None => {
                        let msg = format!(
                            "No legend entry has the id {:?} (Ply never reads a stitch name as an \
                             identity).",
                            crate::diagnostic::excerpt(id.as_str(), 40)
                        );
                        self.err(CrochetCode::LegendUnknown, loc, msg);
                    }
                    Some(&e) => {
                        let takes = self.takes_target.get(e).copied().unwrap_or(false);
                        if takes && into.is_none() {
                            self.err(
                                CrochetCode::NamedTarget,
                                loc.clone(),
                                "This named stitch is worked into a target, and none is given.",
                            );
                        } else if !takes && into.is_some() {
                            self.err(
                                CrochetCode::NamedTarget,
                                loc.clone(),
                                "This named stitch finds its own positions, so it takes no target.",
                            );
                        }
                    }
                }
                if let Some(t) = into {
                    self.target(t, ctx, path);
                }
            }
        }
    }

    fn join(&mut self, into: &'p Target, ctx: Ctx, path: &[u32], last: bool) {
        let loc = self.loc(ctx, path);
        if ctx.legend.is_some() {
            self.err(
                CrochetCode::JoinTarget,
                loc,
                "A join cannot be part of a named stitch.",
            );
            return;
        }
        let placed = ctx.joined && ctx.top && last;
        if !ctx.joined {
            self.err(
                CrochetCode::JoinTarget,
                loc.clone(),
                "Only a joined round ends with a join.",
            );
        } else if !ctx.top {
            self.err(
                CrochetCode::JoinTarget,
                loc.clone(),
                "A join cannot be inside a repeat.",
            );
        } else if !last {
            self.err(
                CrochetCode::JoinTarget,
                loc.clone(),
                "A join is its round's last instruction.",
            );
        }
        match into {
            Target::RoundStart => {}
            Target::Marker { name, .. } => {
                self.text(name, "marker name", loc);
                // Only a join in its place is checked against its marker (at most one a layer);
                // a misplaced one is an error already.
                if let (Some(layer), true) = (ctx.layer, placed) {
                    self.join_uses.push((layer, path.to_vec(), name));
                }
            }
            _ => self.err(
                CrochetCode::JoinTarget,
                loc,
                "A join goes into its round's first counted item or a marked stitch of the round.",
            ),
        }
    }

    fn target(&mut self, t: &'p Target, ctx: Ctx, path: &[u32]) {
        let loc = self.loc(ctx, path);
        match t {
            Target::RoundStart => self.err(
                CrochetCode::JoinTarget,
                loc,
                "Only a join goes into the round's first counted item.",
            ),
            Target::Marker { name, .. } => {
                self.text(name, "marker name", loc.clone());
                self.err(
                    CrochetCode::MarkerScope,
                    loc,
                    "In v1 a marker is only a join's target in its own round.",
                );
            }
            Target::UseSite => {
                if ctx.legend.is_none() {
                    self.err(
                        CrochetCode::NamedTarget,
                        loc,
                        "Only a named stitch's body can work into the use site's target.",
                    );
                }
            }
            Target::Unmodelled { text, consumes } => {
                self.text(text, "opaque target's text", loc.clone());
                if *consumes > self.limits.max_items_per_layer {
                    let msg = format!(
                        "An opaque target that uses {} positions; Ply's limit is {}.",
                        thousands(u64::from(*consumes)),
                        thousands(u64::from(self.limits.max_items_per_layer))
                    );
                    self.too_large(loc, msg);
                }
            }
            Target::Next { .. } | Target::Same { .. } | Target::Ring => {}
        }
    }
}

fn is_travel(i: &Instr) -> bool {
    matches!(
        i,
        Instr::Work {
            op: Op::Slip {
                role: SlipRole::Travel,
                ..
            },
            ..
        }
    )
}

/// Every legend id a list uses (through repeats; not through other bodies), with no limit on
/// depth beyond the list's own (bounded by the instruction and repeat limits already checked).
fn named_refs<'p>(list: &'p [Instr], depth: usize, max_depth: usize, out: &mut Vec<&'p str>) {
    for ins in list {
        match ins {
            Instr::Work {
                op: Op::Named { id, .. },
                ..
            } => out.push(id.as_str()),
            Instr::Repeat { body, .. } if depth < max_depth => {
                named_refs(body, depth + 1, max_depth, out)
            }
            _ => {}
        }
    }
}

/// True when the list works into the use site's target somewhere.
fn uses_target(list: &[Instr], depth: usize, max_depth: usize) -> bool {
    list.iter().any(|ins| match ins {
        Instr::Work { op, .. } => op_targets(op).any(|t| matches!(t, Target::UseSite)),
        Instr::Repeat { body, .. } => depth < max_depth && uses_target(body, depth + 1, max_depth),
        _ => false,
    })
}

/// The targets an operation names, in order.
pub(crate) fn op_targets(op: &Op) -> impl Iterator<Item = &Target> {
    let (one, legs): (Option<&Target>, &[Target]) = match op {
        Op::Chain { .. } => (None, &[]),
        Op::Slip { into, .. } | Op::Stitch { into, .. } => (Some(into), &[]),
        Op::Together { legs, .. } => (None, legs.as_slice()),
        Op::Named { into, .. } => (into.as_ref(), &[]),
    };
    one.into_iter().chain(legs.iter())
}

/// A lower bound on the items a list makes and an upper-ish bound on its steps, with `to_end` and
/// `to_last` counted once (their repetitions are bounded by the base when resolving). Saturating.
fn bound(list: &[Instr], legend: &[(u64, u64)], index: &HashMap<&str, usize>) -> (u64, u64) {
    let mut items: u64 = 0;
    let mut steps: u64 = 0;
    for ins in list {
        let (i, s) = match ins {
            Instr::Start(_) => (1, 1),
            Instr::Work { op, .. } => match op {
                Op::Chain { .. } | Op::Together { .. } => (1, 1),
                // Joins and travelling slip stitches are listed like items, so they count against
                // the same budget.
                Op::Slip { .. } => (1, 1),
                Op::Stitch { n, .. } => (u64::from(*n), 1),
                Op::Named { id, .. } => {
                    let (bi, bs) = index
                        .get(id.as_str())
                        .and_then(|&e| legend.get(e))
                        .copied()
                        .unwrap_or((0, 0));
                    (bi, bs.saturating_add(1))
                }
            },
            Instr::Skip { count, .. } => (0, u64::from(*count).saturating_add(1)),
            Instr::Repeat { body, count } => {
                let (bi, bs) = bound(body, legend, index);
                match count {
                    RepeatCount::Times(k) => {
                        let k = u64::from(*k);
                        (
                            bi.saturating_mul(k),
                            bs.saturating_add(1).saturating_mul(k).saturating_add(1),
                        )
                    }
                    RepeatCount::ToEnd | RepeatCount::ToLast(_) => (bi, bs.saturating_add(2)),
                }
            }
            Instr::LeaveUnworked => (0, 1),
            Instr::Opaque {
                consumes, makes, ..
            } => (
                u64::from(makes.unwrap_or(0)),
                u64::from(consumes.unwrap_or(0)).saturating_add(1),
            ),
        };
        items = items.saturating_add(i);
        steps = steps.saturating_add(s);
    }
    (items, steps)
}

/// The structural check of a whole pattern. Findings go to `out`, counted per code as they are
/// found; whether one refuses resolution is in the result.
pub(crate) fn check<'p>(
    p: &'p CrochetPattern,
    limits: &CrochetLimits,
    out: &mut Collector,
) -> Checked<'p> {
    let mut w = Walk {
        p,
        limits,
        out,
        refused: false,
        legend_index: HashMap::new(),
        takes_target: Vec::new(),
        makes_stitch: Vec::new(),
        opaque_legend: Vec::new(),
        marks: HashMap::new(),
        mark_count: 0,
        join_uses: Vec::new(),
        legend_order: Vec::new(),
        instructions: 0,
        owner_instructions: 0,
        owner_stopped: false,
    };
    let done = |w: Walk<'_, 'p>| Checked {
        p,
        legend_index: w.legend_index,
        refused: w.refused,
        opaque_legend: w.opaque_legend,
    };
    if let Some(why) = limits.unsound() {
        w.too_large(
            CrochetLocation::default(),
            format!("These limits cannot be used: {why}."),
        );
        return done(w);
    }
    let doc = CrochetLocation::default();
    w.text(&p.name, "pattern's name", doc.clone());
    w.text(&p.notes, "pattern's notes", doc.clone());
    if p.layers.len() > limits.max_layers {
        let msg = format!(
            "The piece has {}; Ply's limit is {}.",
            count(p.layers.len() as u64, "layer", "layers"),
            thousands(limits.max_layers as u64)
        );
        w.too_large(doc.clone(), msg);
        return done(w);
    }
    if p.legend.len() > limits.max_legend_entries {
        let msg = format!(
            "The legend has {} entries; Ply's limit is {}.",
            thousands(p.legend.len() as u64),
            thousands(limits.max_legend_entries as u64)
        );
        w.too_large(doc.clone(), msg);
        return done(w);
    }
    match p.start {
        PieceStart::FoundationChain(n) | PieceStart::ChainRing(n) if n == 0 => {
            w.err(
                CrochetCode::StartInvalid,
                doc.clone(),
                "The piece starts with 0 chains.",
            );
        }
        PieceStart::FoundationChain(n) if n > limits.max_foundation_chains => {
            let msg = format!(
                "A foundation chain of {} chains; Ply's limit is {}.",
                thousands(u64::from(n)),
                thousands(u64::from(limits.max_foundation_chains))
            );
            w.too_large(doc.clone(), msg);
        }
        PieceStart::ChainRing(n) if n > limits.max_run_chains => {
            let msg = format!(
                "A chain ring of {} chains; Ply's limit is {}.",
                thousands(u64::from(n)),
                thousands(u64::from(limits.max_run_chains))
            );
            w.too_large(doc.clone(), msg);
        }
        _ => {}
    }

    legend(&mut w);
    if w.instructions > limits.max_instructions {
        let msg = format!(
            "The legend has more than {} instructions, Ply's limit.",
            thousands(limits.max_instructions as u64)
        );
        w.too_large(CrochetLocation::default(), msg);
        return done(w);
    }

    // Layers: ids, kinds, the sequence of rows and rounds, turns, then every instruction.
    let mut ids: HashMap<&str, u32> = HashMap::new();
    // A piece started in a ring is worked in rounds from layer 1, even when that layer is opaque;
    // otherwise the first layer that is not opaque decides (section 16 allows a foundation chain or
    // foundation stitches, an opaque round 1, then rounds).
    let ring_piece = matches!(p.start, PieceStart::MagicRing | PieceStart::ChainRing(_));
    let mut rows: Option<bool> = if ring_piece { Some(false) } else { None };
    for (idx, layer) in p.layers.iter().enumerate() {
        let pos = idx as u32 + 1;
        let loc = CrochetLocation::layer(pos);
        w.text(layer.id.as_str(), "layer id", loc.clone());
        w.text(&layer.note, "layer note", loc.clone());
        if let Some(first) = ids.insert(layer.id.as_str(), pos) {
            ids.insert(layer.id.as_str(), first);
            let msg = format!(
                "Layers {first} and {pos} share the id {:?}.",
                crate::diagnostic::excerpt(layer.id.as_str(), 40)
            );
            w.note(CrochetCode::DuplicateId, loc.clone(), msg);
        }
        let foundation_start = p.start == PieceStart::FoundationStitches;
        match &layer.kind {
            LayerKind::Foundation { stitches, .. } => {
                if pos != 1 || !foundation_start {
                    w.err(
                        CrochetCode::StartInvalid,
                        loc.clone(),
                        "Foundation stitches are layer 1 of a piece that starts with them.",
                    );
                }
                if *stitches == 0 {
                    w.err(
                        CrochetCode::StartInvalid,
                        loc.clone(),
                        "A layer of 0 foundation stitches.",
                    );
                } else if *stitches > limits.max_items_per_layer {
                    let msg = format!(
                        "{} foundation stitches; Ply's limit is {} per layer.",
                        thousands(u64::from(*stitches)),
                        thousands(u64::from(limits.max_items_per_layer))
                    );
                    w.too_large(loc.clone(), msg);
                }
            }
            LayerKind::Opaque { text } => w.text(text, "opaque layer's text", loc.clone()),
            LayerKind::Row { .. } | LayerKind::Round { .. } => {
                if pos == 1 && foundation_start {
                    w.err(
                        CrochetCode::StartInvalid,
                        loc.clone(),
                        "A piece that starts with foundation stitches has them as layer 1.",
                    );
                }
            }
        }
        let is_rows = match layer.kind {
            LayerKind::Row { .. } | LayerKind::Foundation { .. } => Some(true),
            LayerKind::Round { .. } => Some(false),
            LayerKind::Opaque { .. } => None,
        };
        if let Some(r) = is_rows {
            match rows {
                None => rows = Some(r),
                Some(prev) if prev != r => {
                    let msg = if r && ring_piece {
                        "A piece started in a ring is worked in rounds (rows worked into a ring \
                         are later work)."
                    } else if r {
                        "A row cannot follow rounds in one piece in v1."
                    } else {
                        "A round cannot follow rows in one piece in v1."
                    };
                    w.err(CrochetCode::LayerSequence, loc.clone(), msg);
                }
                _ => {}
            }
        }
        if let LayerKind::Round { close, turn, .. } = &layer.kind {
            if *turn {
                let prev_spiral = idx > 0
                    && matches!(
                        p.layers[idx - 1].kind,
                        LayerKind::Round {
                            close: Close::Spiral,
                            ..
                        }
                    );
                if pos == 1 {
                    w.err(
                        CrochetCode::TurnInvalid,
                        loc.clone(),
                        "Round 1 has nothing to turn from.",
                    );
                } else if *close == Close::Spiral {
                    w.err(
                        CrochetCode::SpiralTurn,
                        loc.clone(),
                        "A spiral round cannot be turned.",
                    );
                } else if prev_spiral {
                    w.err(
                        CrochetCode::SpiralTurn,
                        loc.clone(),
                        "A round after a spiral round cannot be turned: a spiral has no join to \
                         turn at.",
                    );
                }
            }
        }
        let (joined, spiral) = match layer.kind {
            LayerKind::Round { close, .. } => (close == Close::Join, close == Close::Spiral),
            _ => (false, false),
        };
        let ctx = Ctx {
            layer: Some(pos),
            legend: None,
            depth: 0,
            top: true,
            joined,
            spiral,
        };
        w.owner_instructions = 0;
        w.owner_stopped = false;
        let mut path = Vec::new();
        w.list(layer.work(), ctx, &mut path);
        if joined && !matches!(layer.work().last(), Some(i) if is_join(i)) {
            w.err(
                CrochetCode::JoinMissing,
                loc.clone(),
                "A joined round ends with a join.",
            );
        }
        if w.instructions > limits.max_instructions {
            let msg = format!(
                "The pattern has more than {} instructions, Ply's limit.",
                thousands(limits.max_instructions as u64)
            );
            w.too_large(CrochetLocation::default(), msg);
            break;
        }
    }

    // Joins into markers.
    let uses = std::mem::take(&mut w.join_uses);
    for (layer, path, name) in uses {
        let loc = CrochetLocation::instruction(layer, path.clone());
        match w.marks.get(name) {
            None => {
                let msg = format!(
                    "No instruction places marker {:?}.",
                    crate::diagnostic::excerpt(name, 40)
                );
                w.err(CrochetCode::MarkerUnknown, loc, msg);
            }
            Some((ml, mpath)) => {
                if *ml != layer {
                    let msg = format!(
                        "Marker {:?} is in layer {ml}; in v1 a join goes into a marker of its own \
                         round.",
                        crate::diagnostic::excerpt(name, 40)
                    );
                    w.err(CrochetCode::MarkerScope, loc, msg);
                } else if *mpath >= path {
                    w.err(
                        CrochetCode::AnchorFuture,
                        loc,
                        "The marked stitch is made after the join that goes into it.",
                    );
                }
            }
        }
    }
    if w.mark_count > limits.max_markers {
        let msg = format!(
            "The pattern places {} markers; Ply's limit is {}.",
            thousands(w.mark_count as u64),
            thousands(limits.max_markers as u64)
        );
        w.too_large(CrochetLocation::default(), msg);
    }

    // Lower bounds on items and steps, before anything is allocated per item.
    if !w.refused {
        let legend_bounds = legend_bounds(p, &w.legend_index, &w.legend_order);
        let mut total: u64 = 0;
        let mut layer_passed = false;
        for (idx, layer) in p.layers.iter().enumerate() {
            let pos = idx as u32 + 1;
            let (items, steps) = match &layer.kind {
                LayerKind::Foundation { stitches, .. } => (u64::from(*stitches), 1),
                _ => bound(layer.work(), &legend_bounds, &w.legend_index),
            };
            if items > u64::from(limits.max_items_per_layer) {
                let msg = format!(
                    "{} makes at least {} items; Ply's limit is {} per layer.",
                    layer_word(&layer.kind, pos),
                    thousands(items),
                    thousands(u64::from(limits.max_items_per_layer))
                );
                w.too_large(CrochetLocation::layer(pos), msg);
                layer_passed = true;
            } else if steps > limits.max_steps_per_layer {
                let msg = format!(
                    "{} takes more than {} steps to work out, Ply's limit.",
                    layer_word(&layer.kind, pos),
                    thousands(limits.max_steps_per_layer)
                );
                w.too_large(CrochetLocation::layer(pos), msg);
            }
            total = total.saturating_add(items);
        }
        if total > limits.max_items && !layer_passed {
            let msg = format!(
                "The piece makes at least {} items; Ply's limit is {}.",
                thousands(total),
                thousands(limits.max_items)
            );
            w.too_large(CrochetLocation::default(), msg);
        }
    }
    done(w)
}

fn is_join(i: &Instr) -> bool {
    matches!(
        i,
        Instr::Work {
            op: Op::Slip {
                role: SlipRole::Join,
                ..
            },
            ..
        }
    )
}

/// The legend: ids, words, cycles, nesting depth, then every body.
fn legend(w: &mut Walk<'_, '_>) {
    let p = w.p;
    let limits = w.limits;
    let n = p.legend.len();
    // Normalized name or abbreviation to the first entry that has it.
    let mut seen: HashMap<String, usize> = HashMap::new();
    for (e, entry) in p.legend.iter().enumerate() {
        let loc = CrochetLocation::legend(e as u32, Vec::new());
        w.text(entry.id.as_str(), "legend id", loc.clone());
        w.text(&entry.name, "legend name", loc.clone());
        w.text(&entry.abbreviation, "legend abbreviation", loc.clone());
        if let Some(&first) = w.legend_index.get(entry.id.as_str()) {
            let msg = format!(
                "Legend entries {} and {} share the id {:?}.",
                first + 1,
                e + 1,
                crate::diagnostic::excerpt(entry.id.as_str(), 40)
            );
            w.err(CrochetCode::DuplicateId, loc.clone(), msg);
        } else {
            w.legend_index.insert(entry.id.as_str(), e);
        }
        let id = entry.id.as_str();
        let id_key = word_key(id);
        if IDENTITY_WORDS.contains(&id_key.as_str()) || is_reserved_word(id) {
            let msg = format!(
                "The legend id {:?} is an identity or a word of a built-in label set.",
                crate::diagnostic::excerpt(id, 40)
            );
            w.note(CrochetCode::LegendCollision, loc.clone(), msg);
        }
        for (word, what) in [(&entry.abbreviation, "abbreviation"), (&entry.name, "name")] {
            if is_reserved_word(word) {
                let msg = format!(
                    "The legend {what} {:?} is a word of the US or UK label set.",
                    crate::diagnostic::excerpt(word, 40)
                );
                w.note(CrochetCode::LegendCollision, loc.clone(), msg);
            }
        }
        // Each word is normalized once and looked up, so the check is linear in the legend.
        let mut keys = vec![word_key(&entry.abbreviation), word_key(&entry.name)];
        keys.dedup();
        keys.retain(|k| !k.is_empty());
        if let Some(&f) = keys.iter().find_map(|k| seen.get(k)) {
            let msg = format!(
                "Legend entries {} and {} share a name or abbreviation.",
                f + 1,
                e + 1
            );
            w.note(CrochetCode::LegendCollision, loc.clone(), msg);
        }
        for k in keys {
            seen.entry(k).or_insert(e);
        }
    }
    let max_depth = limits.max_repeat_depth;
    w.takes_target = p
        .legend
        .iter()
        .map(|entry| uses_target(&entry.body, 0, max_depth))
        .collect();
    // Edges, cycles and the nesting depth.
    let edges: Vec<Vec<usize>> = p
        .legend
        .iter()
        .map(|entry| {
            let mut refs = Vec::new();
            named_refs(&entry.body, 0, max_depth, &mut refs);
            refs.iter()
                .filter_map(|r| w.legend_index.get(r).copied())
                .collect()
        })
        .collect();
    // Iterative depth-first search: 0 unvisited, 1 on the stack, 2 done.
    let mut state = vec![0u8; n];
    let mut depth = vec![1usize; n];
    let mut cyclic = vec![false; n];
    for root in 0..n {
        if state[root] != 0 {
            continue;
        }
        let mut stack: Vec<(usize, usize)> = vec![(root, 0)];
        state[root] = 1;
        while let Some(&mut (node, ref mut next)) = stack.last_mut() {
            if let Some(&child) = edges[node].get(*next) {
                *next += 1;
                match state[child] {
                    0 => {
                        state[child] = 1;
                        stack.push((child, 0));
                    }
                    1 => {
                        // A cycle through `child`: mark every entry on it.
                        for &(on, _) in stack.iter().skip_while(|(s, _)| *s != child) {
                            cyclic[on] = true;
                        }
                    }
                    _ => {}
                }
            } else {
                state[node] = 2;
                stack.pop();
                let d = edges[node]
                    .iter()
                    .map(|&c| depth[c])
                    .max()
                    .unwrap_or(0)
                    .saturating_add(1);
                depth[node] = d;
            }
        }
    }
    let any_cycle = cyclic.iter().any(|&c| c);
    for (e, &c) in cyclic.iter().enumerate() {
        if c {
            w.err(
                CrochetCode::LegendCycle,
                CrochetLocation::legend(e as u32, Vec::new()),
                "This named stitch uses itself, directly or through other named stitches.",
            );
        }
    }
    if !any_cycle {
        for (e, &d) in depth.iter().enumerate() {
            if d > limits.max_named_depth {
                let msg = format!(
                    "Named stitches nest {d} deep here; Ply's limit is {}.",
                    limits.max_named_depth
                );
                w.too_large(CrochetLocation::legend(e as u32, Vec::new()), msg);
            }
        }
    }
    // Which entries make a stitch (for markers), children first (a cycle makes it unknown: true).
    let mut makes = vec![None::<bool>; n];
    let mut opaque = vec![false; n];
    if !any_cycle {
        let mut order: Vec<usize> = (0..n).collect();
        order.sort_by_key(|&e| depth[e]);
        for &e in &order {
            let own = body_makes_stitch(&p.legend[e].body, 0, max_depth);
            let via = edges[e].iter().any(|&c| makes[c].unwrap_or(false));
            makes[e] = Some(own || via);
            opaque[e] = body_uses_opaque(&p.legend[e].body, 0, max_depth)
                || edges[e].iter().any(|&c| opaque[c]);
        }
        w.legend_order = order;
    }
    w.makes_stitch = makes.into_iter().map(|m| m.unwrap_or(true)).collect();
    w.opaque_legend = opaque;
    // Bodies.
    for (e, entry) in p.legend.iter().enumerate() {
        let ctx = Ctx {
            layer: None,
            legend: Some(e as u32),
            depth: 0,
            top: false,
            joined: false,
            spiral: false,
        };
        w.owner_instructions = 0;
        w.owner_stopped = false;
        let mut path = Vec::new();
        w.list(&entry.body, ctx, &mut path);
    }
}

/// True when the list holds an opaque instruction or works into an opaque target (through repeats;
/// other named stitches are looked at by the caller).
fn body_uses_opaque(list: &[Instr], depth: usize, max_depth: usize) -> bool {
    list.iter().any(|ins| match ins {
        Instr::Opaque { .. } => true,
        Instr::Work { op, .. } => op_targets(op).any(|t| matches!(t, Target::Unmodelled { .. })),
        Instr::Repeat { body, .. } => {
            depth < max_depth && body_uses_opaque(body, depth + 1, max_depth)
        }
        _ => false,
    })
}

fn body_makes_stitch(list: &[Instr], depth: usize, max_depth: usize) -> bool {
    list.iter().any(|ins| match ins {
        Instr::Work { op, .. } => match op {
            Op::Stitch { .. } | Op::Together { .. } => true,
            Op::Slip { role, .. } => *role == SlipRole::Stitch,
            Op::Chain { .. } | Op::Named { .. } => false,
        },
        Instr::Opaque { makes, .. } => makes.is_none_or(|m| m > 0),
        Instr::Repeat { body, .. } => {
            depth < max_depth && body_makes_stitch(body, depth + 1, max_depth)
        }
        _ => false,
    })
}

/// Each legend entry's (items, steps) bound, computed children first in `order`. Only called when the
/// legend has no cycle (every refusing error is absent).
fn legend_bounds(
    p: &CrochetPattern,
    index: &HashMap<&str, usize>,
    order: &[usize],
) -> Vec<(u64, u64)> {
    let mut out = vec![(0u64, 0u64); p.legend.len()];
    for &e in order {
        if let Some(entry) = p.legend.get(e) {
            out[e] = bound(&entry.body, &out, index);
        }
    }
    out
}
