//! The stored crochet pattern (ADR 0022 sections 1 to 13 and the engine interface of section 20).
//!
//! This is what an author writes and a file will hold: a piece is a **start** and its **layers**
//! (rows or rounds) in work order, each layer a list of instructions that name their targets
//! **relatively**, as patterns do ("sc in next st", "3 dc in next ch-2 sp", "2 sc in same st",
//! "sk next st"). Nothing resolved is stored: item numbers, explicit attachments and counts are
//! derived on every call by [`crate::try_resolve`], so a pattern cannot disagree with itself.
//!
//! The types are plain owned data with no shared or resolved state, so M11-02's native document
//! (ADR 0022 section 21) can map them one to one. The leaf words (kinds, parts, roles, terms) derive
//! serde with section 21's spelling; the composite types do not, because section 21's shape (for
//! example `{"op": "b0", "into": {"next": "stitch"}, "n": 2}`) is a format decision for M11-02.
//!
//! A pattern built in code or read from a file may be wrong in any way. Validation names every
//! problem with a typed diagnostic instead of refusing to hold it; only the few states that have no
//! meaning at all (a basic stitch v1 does not have, a foundation layer with instructions) cannot be
//! represented.

use crate::stitch::{Basic, Counted, SlipRole};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// The kind of base position a `next` or `skip` looks for (ADR 0022 section 5).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PosKind {
    /// The top of a stitch (or of a counted starting chain, or of an ordinary slip stitch).
    Stitch,
    /// The opening under a run of chains made in the layer below, as a whole.
    Space,
    /// One chain: of the foundation, or of a run entered chain by chain.
    Chain,
    /// Whatever position comes next.
    Any,
}

/// Which part of a stitch top is worked, **as worked**: the loop nearer to the crocheter while
/// working this layer is the front loop (ADR 0022 section 4). Both loops is the default.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Part {
    #[default]
    Both,
    FrontLoop,
    BackLoop,
}

/// Which part of a chain is worked. No source fixes a default, so Ply never picks one.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ChainPart {
    #[default]
    Unspecified,
    TopLoop,
    BackBump,
}

/// A stated part. A part that does not fit the position it meets (a loop of a space, a back bump of
/// a stitch top) is `crochet.part_invalid`. The defaults ([`Part::Both`], [`ChainPart::Unspecified`])
/// mean the same as stating no part.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum PartSpec {
    Top(Part),
    Chain(ChainPart),
}

impl PartSpec {
    /// True when this part says no more than the default.
    pub const fn is_default(self) -> bool {
        matches!(
            self,
            PartSpec::Top(Part::Both) | PartSpec::Chain(ChainPart::Unspecified)
        )
    }

    /// This part, or `None` when it is the default (the canonical form).
    pub const fn stated(self) -> Option<PartSpec> {
        if self.is_default() {
            None
        } else {
            Some(self)
        }
    }
}

/// Where an operation is worked, written relatively (ADR 0022 section 5). The engine resolves each
/// target to an explicit attachment ([`crate::Anchor`]) by walking a cursor along the base.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum Target {
    /// Move forward to the next position of `kind` and work into it. Positions of other kinds on
    /// the way are passed over (left unworked, and listed as information); a position of `kind` is
    /// never passed over. `next chain` passes nothing.
    Next {
        kind: PosKind,
        part: Option<PartSpec>,
    },
    /// Work into the position the cursor is on again (increases, groups, shells).
    Same { part: Option<PartSpec> },
    /// Work into the ring; the base must be the piece's ring.
    Ring,
    /// A join's target only: the round's first counted item.
    RoundStart,
    /// A join's target only in v1: a stitch of the same round tagged with `mark`.
    Marker {
        name: String,
        part: Option<PartSpec>,
    },
    /// Inside a named stitch's body only: the target given at the place the named stitch is used.
    UseSite,
    /// An opaque target: a known operation worked somewhere Ply does not model ("around the post of
    /// next st"). The stitch is made and counted; its attachment is unverified; it uses `consumes`
    /// base positions.
    Unmodelled { text: String, consumes: u32 },
}

impl Target {
    /// `next stitch`.
    pub const NEXT_STITCH: Target = Target::Next {
        kind: PosKind::Stitch,
        part: None,
    };
    /// `next space`.
    pub const NEXT_SPACE: Target = Target::Next {
        kind: PosKind::Space,
        part: None,
    };
    /// `next chain`.
    pub const NEXT_CHAIN: Target = Target::Next {
        kind: PosKind::Chain,
        part: None,
    };
    /// `next any`.
    pub const NEXT_ANY: Target = Target::Next {
        kind: PosKind::Any,
        part: None,
    };
    /// `same`.
    pub const SAME: Target = Target::Same { part: None };

    /// `next kind`.
    pub const fn next(kind: PosKind) -> Target {
        Target::Next { kind, part: None }
    }

    /// `next stitch` in one loop (or both) of its top, as worked. Both loops, the default, is
    /// stored as no part.
    pub const fn next_stitch_in(part: Part) -> Target {
        Target::Next {
            kind: PosKind::Stitch,
            part: PartSpec::Top(part).stated(),
        }
    }

    /// `next chain` in one part of the chain. The unspecified part, the default, is stored as no
    /// part.
    pub const fn next_chain_in(part: ChainPart) -> Target {
        Target::Next {
            kind: PosKind::Chain,
            part: PartSpec::Chain(part).stated(),
        }
    }

    /// This target with a default part (`Top(Both)`, `Chain(Unspecified)`) stored as no part.
    /// Both forms mean the same to resolution; the canonical form is no part, which is what a
    /// document writes (ADR 0022 section 21 writes only the four non-default parts).
    pub fn normalized(self) -> Target {
        match self {
            Target::Next { kind, part } => Target::Next {
                kind,
                part: part.and_then(PartSpec::stated),
            },
            Target::Same { part } => Target::Same {
                part: part.and_then(PartSpec::stated),
            },
            Target::Marker { name, part } => Target::Marker {
                name,
                part: part.and_then(PartSpec::stated),
            },
            other => other,
        }
    }

    /// A join's target: the stitch tagged `name` in the same round.
    pub fn marker(name: impl Into<String>) -> Target {
        Target::Marker {
            name: name.into(),
            part: None,
        }
    }

    /// An opaque target, kept in the pattern's words.
    pub fn unmodelled(text: impl Into<String>, consumes: u32) -> Target {
        Target::Unmodelled {
            text: text.into(),
            consumes,
        }
    }

    /// The stated part, if any.
    pub fn part(&self) -> Option<PartSpec> {
        match self {
            Target::Next { part, .. } | Target::Same { part } | Target::Marker { part, .. } => {
                *part
            }
            _ => None,
        }
    }
}

/// A legend entry's id (`inc`, `shell`): what a document's operations use to name a named stitch.
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(transparent)]
pub struct LegendId(pub String);

impl LegendId {
    pub fn new(id: impl Into<String>) -> LegendId {
        LegendId(id.into())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// One operation (ADR 0022 sections 2 and 9).
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum Op {
    /// A run of `count` chains made inside the layer. It becomes one space position in the next
    /// layer (a "ch-n sp"), which can be entered as a whole or chain by chain, not both.
    Chain {
        count: u32,
    },
    Slip {
        role: SlipRole,
        into: Target,
    },
    /// `n` stitches into one target: the first into `into`, the rest into the same position.
    Stitch {
        stitch: Basic,
        into: Target,
        n: u32,
    },
    /// `tog`: one leg per target, finished together into one stitch. Legs into different positions
    /// make a decrease; legs into one position (`next`, then `same`) make a cluster, bobble or puff.
    Together {
        stitch: Basic,
        legs: Vec<Target>,
    },
    /// A named stitch from the project legend, expanded where it is used. `into` is the use site's
    /// target, given exactly when the body takes it ([`Target::UseSite`]); a body that walks the
    /// base itself (an invisible decrease) takes none.
    Named {
        id: LegendId,
        into: Option<Target>,
    },
}

/// What a starting chain counts as (ADR 0022 section 7). Stored on every chain: nothing is decided
/// when a pattern is read.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum CountsAs {
    /// "ch 1 (does not count as a st)".
    Nothing,
    /// "ch 3 (counts as dc)".
    Stitch(Basic),
    /// "ch 4 (counts as dc and ch-1 sp)": a stitch position followed by a space of `chains` chains.
    StitchAndSpace { stitch: Basic, chains: u32 },
}

impl CountsAs {
    /// True when the chain is a stitch position for the next layer.
    pub const fn counts(self) -> bool {
        !matches!(self, CountsAs::Nothing)
    }

    /// The stitch it counts as, if it counts.
    pub const fn stitch(self) -> Option<Basic> {
        match self {
            CountsAs::Nothing => None,
            CountsAs::Stitch(b) | CountsAs::StitchAndSpace { stitch: b, .. } => Some(b),
        }
    }
}

/// A layer's starting chain (turning chain, beginning chain or standing chain).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct StartChain {
    /// Its height in chains.
    pub chains: u32,
    pub counts_as: CountsAs,
    /// Form (a) of ADR 0022 section 6: the chain is the `chains` foundation chains nearest the hook,
    /// taken by layer 1 ("sc in 2nd ch from hook", "dc in 4th ch from hook"). Only layer 1 on a
    /// foundation chain may use it. Without it the chain is made of new chains.
    pub from_foundation: bool,
}

/// How many times a repeat's body is worked (ADR 0022 section 11). The count is the total: "rep from
/// * 3 more times" and "[...] 4 times" are both `Times(4)`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum RepeatCount {
    Times(u32),
    /// Until the base runs out ("rep from * across").
    ToEnd,
    /// Until exactly this many positions remain ("rep from * to last 2 sts").
    ToLast(u32),
}

/// One instruction of a layer or of a named stitch's body.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum Instr {
    /// The layer's starting chain: first in the layer, apart from travelling slip stitches.
    Start(StartChain),
    /// An operation; `mark` places a named marker in the first stitch it makes ("place marker A in
    /// first st made"), allowed on a stitch, a `tog` or a named stitch.
    Work { op: Op, mark: Option<String> },
    /// Move forward over the next `count` positions of `kind` without working them (UK "miss").
    Skip { count: u32, kind: PosKind },
    Repeat {
        body: Vec<Instr>,
        count: RepeatCount,
    },
    /// End the layer, leaving the rest of the base unworked on purpose. Only as a layer's last
    /// instruction, outside any repeat.
    LeaveUnworked,
    /// An operation Ply does not model, kept in the pattern's words (ADR 0022 section 12). When it
    /// states both how many base positions it uses and how many stitch positions it makes, the rest
    /// of the pattern can still be checked; otherwise every count after it is unknown.
    Opaque {
        text: String,
        consumes: Option<u32>,
        makes: Option<u32>,
    },
}

impl Instr {
    /// A starting chain of new chains.
    pub const fn start(chains: u32, counts_as: CountsAs) -> Instr {
        Instr::Start(StartChain {
            chains,
            counts_as,
            from_foundation: false,
        })
    }

    /// A starting chain taken from the foundation (form a).
    pub const fn start_from_foundation(chains: u32, counts_as: CountsAs) -> Instr {
        Instr::Start(StartChain {
            chains,
            counts_as,
            from_foundation: true,
        })
    }

    /// An operation with no marker.
    pub const fn op(op: Op) -> Instr {
        Instr::Work { op, mark: None }
    }

    /// One stitch into `into`.
    pub const fn stitch(stitch: Basic, into: Target) -> Instr {
        Instr::stitches(stitch, into, 1)
    }

    /// `n` stitches into one target.
    pub const fn stitches(stitch: Basic, into: Target, n: u32) -> Instr {
        Instr::op(Op::Stitch { stitch, into, n })
    }

    /// A chain run of `count` chains.
    pub const fn chain(count: u32) -> Instr {
        Instr::op(Op::Chain { count })
    }

    /// `tog` with one leg per target.
    pub const fn tog(stitch: Basic, legs: Vec<Target>) -> Instr {
        Instr::op(Op::Together { stitch, legs })
    }

    /// An ordinary slip stitch (it makes a position).
    pub const fn slip(into: Target) -> Instr {
        Instr::op(Op::Slip {
            role: SlipRole::Stitch,
            into,
        })
    }

    /// A travelling slip stitch.
    pub const fn travel(into: Target) -> Instr {
        Instr::op(Op::Slip {
            role: SlipRole::Travel,
            into,
        })
    }

    /// The join that closes a round, into its first counted item.
    pub const fn join() -> Instr {
        Instr::op(Op::Slip {
            role: SlipRole::Join,
            into: Target::RoundStart,
        })
    }

    /// The join that closes a round, into a marked stitch of the same round.
    pub fn join_marker(name: impl Into<String>) -> Instr {
        Instr::op(Op::Slip {
            role: SlipRole::Join,
            into: Target::marker(name),
        })
    }

    /// A named stitch from the legend.
    pub fn named(id: impl Into<String>, into: Option<Target>) -> Instr {
        Instr::op(Op::Named {
            id: LegendId::new(id),
            into,
        })
    }

    pub const fn skip(count: u32, kind: PosKind) -> Instr {
        Instr::Skip { count, kind }
    }

    pub const fn times(count: u32, body: Vec<Instr>) -> Instr {
        Instr::Repeat {
            body,
            count: RepeatCount::Times(count),
        }
    }

    pub const fn to_end(body: Vec<Instr>) -> Instr {
        Instr::Repeat {
            body,
            count: RepeatCount::ToEnd,
        }
    }

    pub const fn to_last(remaining: u32, body: Vec<Instr>) -> Instr {
        Instr::Repeat {
            body,
            count: RepeatCount::ToLast(remaining),
        }
    }

    /// An opaque instruction.
    pub fn opaque(text: impl Into<String>, consumes: Option<u32>, makes: Option<u32>) -> Instr {
        Instr::Opaque {
            text: text.into(),
            consumes,
            makes,
        }
    }

    /// This operation with a marker in the first stitch it makes. On anything but an operation it
    /// returns the instruction unchanged.
    pub fn marked(self, name: impl Into<String>) -> Instr {
        match self {
            Instr::Work { op, .. } => Instr::Work {
                op,
                mark: Some(name.into()),
            },
            other => other,
        }
    }
}

/// How a round closes (ADR 0022 section 8).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Close {
    /// Ends with a slip stitch join; the next round's base begins at the item the join went into.
    Join,
    /// No join; the next round begins with the stitch worked into this round's first stitch.
    Spiral,
}

/// A layer's stable id (`layer-N`, from a counter that never reuses a number, ADR 0017's rule).
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(transparent)]
pub struct LayerId(pub String);

impl LayerId {
    pub fn new(id: impl Into<String>) -> LayerId {
        LayerId(id.into())
    }

    /// `layer-n`.
    pub fn numbered(n: u32) -> LayerId {
        LayerId(format!("layer-{n}"))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// What a layer is. Section 20 of ADR 0022 puts `work` on the layer beside the kind; here it lives
/// inside the kinds that have it, so a foundation or opaque layer with instructions cannot exist.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum LayerKind {
    /// Foundation stitches (fsc, fhdc, fdc): the chain and the first row at once. Layer 1 only, when
    /// the start is [`PieceStart::FoundationStitches`]; items 1 to `stitches`, no base, no item 0.
    Foundation { stitch: Basic, stitches: u32 },
    /// A row: turned at the end; the next row meets its positions in reverse work order.
    Row { work: Vec<Instr> },
    /// A round. `turn` means the work is turned before this round (after the previous round's
    /// join), so it is worked the other way.
    Round {
        close: Close,
        turn: bool,
        work: Vec<Instr>,
    },
    /// A whole row or round kept in the pattern's words ("work in Tunisian simple stitch for 6
    /// rows"). Later layers are checked only if its stated count gives its stitches.
    Opaque { text: String },
}

/// A stated stitch count: the author's checksum, each part optional and compared exactly with the
/// derived count (ADR 0022 section 13).
#[derive(Debug, Clone, PartialEq, Eq, Hash, Default)]
pub struct StatedCount {
    /// All stitch positions the layer makes (opaque positions included, spaces not).
    pub stitches: Option<u32>,
    /// All spaces the layer makes.
    pub spaces: Option<u32>,
    /// Stitches by identity ("18 dc, 6 sc"); when not empty it must equal the derived count by
    /// identity exactly (identities it leaves out must be absent).
    pub by_identity: BTreeMap<Counted, u32>,
}

impl StatedCount {
    /// A stated count of stitches only.
    pub fn stitches(n: u32) -> StatedCount {
        StatedCount {
            stitches: Some(n),
            ..StatedCount::default()
        }
    }

    pub fn with_spaces(mut self, n: u32) -> StatedCount {
        self.spaces = Some(n);
        self
    }

    pub fn with_identity(mut self, counted: Counted, n: u32) -> StatedCount {
        self.by_identity.insert(counted, n);
        self
    }
}

/// One row or round.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Layer {
    pub id: LayerId,
    pub kind: LayerKind,
    pub stated: Option<StatedCount>,
    /// The author's note on this layer (recorded, never checked).
    pub note: String,
}

impl Layer {
    pub fn new(id: LayerId, kind: LayerKind) -> Layer {
        Layer {
            id,
            kind,
            stated: None,
            note: String::new(),
        }
    }

    pub fn row(id: LayerId, work: Vec<Instr>) -> Layer {
        Layer::new(id, LayerKind::Row { work })
    }

    pub fn round(id: LayerId, close: Close, turn: bool, work: Vec<Instr>) -> Layer {
        Layer::new(id, LayerKind::Round { close, turn, work })
    }

    pub fn with_stated(mut self, stated: StatedCount) -> Layer {
        self.stated = Some(stated);
        self
    }

    /// The layer's instructions (empty for a foundation or opaque layer).
    pub fn work(&self) -> &[Instr] {
        match &self.kind {
            LayerKind::Row { work } | LayerKind::Round { work, .. } => work,
            LayerKind::Foundation { .. } | LayerKind::Opaque { .. } => &[],
        }
    }
}

/// How a piece begins (ADR 0022 section 6).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum PieceStart {
    /// A foundation chain of n chains, `F1` (next to the slip knot) to `Fn` (nearest the hook).
    FoundationChain(u32),
    /// Foundation stitches: layer 1 is a [`LayerKind::Foundation`] layer.
    FoundationStitches,
    MagicRing,
    /// A chain ring of n chains closed into a loop. Its chains are not positions in v1.
    ChainRing(u32),
}

/// The terms the pattern's author used: metadata only, never read by resolution or validation.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Terms {
    Us,
    Uk,
    #[default]
    Unstated,
}

/// Which side faces the crocheter while working layer 1 (side A).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FirstSide {
    #[default]
    Rs,
    Ws,
    NotStated,
}

/// The document setting behind Ply's suggestion for a new starting chain (ADR 0022 section 7). A
/// suggestion only: changing it never changes a chain already entered, and resolution never reads it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum StartChainRule {
    /// The chain counts as the layer's first stitch when that stitch is `b1h` or taller.
    #[default]
    ByHeight,
    Never,
    Always,
}

impl StartChainRule {
    /// The starting chain Ply suggests for a layer whose first stitch is `first` (`None` for a slip
    /// stitch): the suggested height, counting as `first` or not by this rule. The suggestion for a
    /// slip stitch is 1 chain that does not count (section 7 counts a chain before a slip stitch as
    /// nothing; it gives no height, and 1 is Ply's choice).
    pub fn suggest(self, first: Option<Basic>) -> StartChain {
        let chains = first.map_or(1, Basic::suggested_chain_height);
        let counts = match (self, first) {
            (_, None) => false,
            (StartChainRule::ByHeight, Some(b)) => b != Basic::B0,
            (StartChainRule::Never, _) => false,
            (StartChainRule::Always, _) => true,
        };
        StartChain {
            chains,
            counts_as: match (counts, first) {
                (true, Some(b)) => CountsAs::Stitch(b),
                _ => CountsAs::Nothing,
            },
            from_foundation: false,
        }
    }
}

/// A named stitch of the project legend (ADR 0022 sections 3 and 9): the document's own name for a
/// short instruction list. A legend entry never changes structure; its name and abbreviation are the
/// author's words, shown unchanged in every label set.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct LegendEntry {
    pub id: LegendId,
    pub name: String,
    pub abbreviation: String,
    /// Spliced in where the named stitch is used. It may take the use site's target
    /// ([`Target::UseSite`], then `same`) or walk the base itself with `next`.
    pub body: Vec<Instr>,
}

/// A whole crochet piece (one piece and one size per document in v1).
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct CrochetPattern {
    pub name: String,
    pub notes: String,
    pub source_terms: Terms,
    pub first_side: FirstSide,
    pub start_chain_rule: StartChainRule,
    pub legend: Vec<LegendEntry>,
    pub start: PieceStart,
    pub layers: Vec<Layer>,
    /// The editor's layer id counter (`layer-N`); recorded, not checked by the engine.
    pub last_layer_number: u32,
}

impl CrochetPattern {
    /// An empty piece with this start, US source terms (a pattern made in Ply is written in the
    /// viewer's terms, US by default, the owner's decision of 2026-11-18), the right side facing on
    /// layer 1 and the `by_height` suggestion.
    pub fn new(start: PieceStart) -> CrochetPattern {
        CrochetPattern {
            name: String::new(),
            notes: String::new(),
            source_terms: Terms::Us,
            first_side: FirstSide::Rs,
            start_chain_rule: StartChainRule::ByHeight,
            legend: Vec::new(),
            start,
            layers: Vec::new(),
            last_layer_number: 0,
        }
    }

    /// Add a layer, giving it the next `layer-N` id.
    pub fn push(&mut self, kind: LayerKind, stated: Option<StatedCount>) -> &mut Layer {
        self.last_layer_number = self.last_layer_number.saturating_add(1);
        let mut layer = Layer::new(LayerId::numbered(self.last_layer_number), kind);
        layer.stated = stated;
        self.layers.push(layer);
        self.layers.last_mut().expect("just pushed")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_by_height_suggestion_counts_b1h_and_taller() {
        let s = |rule: StartChainRule, b| rule.suggest(b);
        assert_eq!(
            s(StartChainRule::ByHeight, Some(Basic::B0)).counts_as,
            CountsAs::Nothing
        );
        assert_eq!(s(StartChainRule::ByHeight, Some(Basic::B0)).chains, 1);
        assert_eq!(
            s(StartChainRule::ByHeight, Some(Basic::B1H)).counts_as,
            CountsAs::Stitch(Basic::B1H)
        );
        assert_eq!(s(StartChainRule::ByHeight, Some(Basic::B1)).chains, 3);
        assert_eq!(
            s(StartChainRule::Never, Some(Basic::B3)).counts_as,
            CountsAs::Nothing
        );
        assert_eq!(
            s(StartChainRule::Always, Some(Basic::B0)).counts_as,
            CountsAs::Stitch(Basic::B0)
        );
        assert_eq!(s(StartChainRule::Always, None).counts_as, CountsAs::Nothing);
        assert!(!s(StartChainRule::Always, Some(Basic::B2)).from_foundation);
    }

    #[test]
    fn layers_get_ids_from_the_counter() {
        let mut p = CrochetPattern::new(PieceStart::MagicRing);
        p.push(LayerKind::Opaque { text: "a".into() }, None);
        p.push(LayerKind::Opaque { text: "b".into() }, None);
        assert_eq!(p.layers[1].id, LayerId::new("layer-2"));
        assert_eq!(p.last_layer_number, 2);
        assert!(p.layers[0].work().is_empty());
    }
}
