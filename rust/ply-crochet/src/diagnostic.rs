//! Stable, typed diagnostics (ADR 0022 section 13, roadmap contract 10.2, ADR 0021): a machine code
//! that never changes once released, the shared severity of `ply_common::readiness`, a typed location
//! (layer, instruction path through repeats, repetition, item, base position), structured detail and
//! a sentence for people.
//!
//! Messages never use a stitch name or abbreviation: validation reads no label set, so the same
//! document gives the same diagnostics for every viewer (ADR 0022 section 3). A view that wants "sc"
//! or "dc" in the sentence builds it from the location and detail with the viewer's label set.

use crate::place::{ItemId, PosRef, Side};
use crate::stitch::Counted;
pub use ply_common::readiness::Severity;
use serde::{Deserialize, Serialize};

/// Every diagnostic code. The string form ([`CrochetCode::as_str`]) is the stable identifier.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum CrochetCode {
    // Errors: impossible anchors.
    /// A `next` or `skip` beyond the last position: an impossible anchor, never wrapped or clamped.
    AnchorPastEnd,
    /// No position of the asked kind remains, or `next chain` meets something other than a chain.
    AnchorKind,
    /// `same` when the cursor is on no position (at the start of a layer).
    SameWithoutPosition,
    /// A part that does not fit its position: a loop of a space, a back bump of a stitch top.
    PartInvalid,
    /// A space worked both as a whole and chain by chain.
    SpaceOpened,
    /// `ring` when the base is not the piece's ring.
    RingMissing,
    // Errors: markers.
    /// A join names a marker no instruction places (or that was not placed when the join came).
    MarkerUnknown,
    /// Two placements of one marker name.
    MarkerDuplicate,
    /// A marker used other than as a join target of its own round (v1).
    MarkerScope,
    /// A `mark` on something that makes no stitch (a chain run, a slip stitch, a skip), or inside a
    /// named stitch's body.
    MarkInvalid,
    /// A target made after the stitch that uses it.
    AnchorFuture,
    // Errors: structure.
    /// A join into something other than its round's first counted item or a marked stitch of the
    /// round, a join in a row or a spiral round, a join that is not its round's last instruction (or
    /// is inside a repeat or a named stitch), or `round_start` used by anything but a join.
    JoinTarget,
    /// A joined round with no join (ADR 0022 amendment of 2026-11-18).
    JoinMissing,
    /// `turn` on a spiral round, or on a joined round after a spiral round.
    SpiralTurn,
    /// `turn` on round 1.
    TurnInvalid,
    /// Rows and rounds mixed in one piece, or a row worked into a ring.
    LayerSequence,
    /// `leave_unworked` inside a repeat or a named stitch, or not as the layer's last instruction.
    LeaveMisplaced,
    /// A starting chain that is not first apart from travelling slip stitches, two in one layer, or
    /// one inside a repeat or a named stitch.
    StartMisplaced,
    /// A starting chain or a start that cannot be: 0 chains; a chain taken from the foundation
    /// outside layer 1 on a foundation chain, counting as a stitch and a space, taking more chains
    /// than the foundation has, or after travelling slip stitches; a foundation layer anywhere but
    /// layer 1 of a piece started with foundation stitches, or such a piece without one; an empty
    /// foundation, ring or foundation layer.
    StartInvalid,
    /// A repeat, skip, `n` or chain run of 0.
    RepeatZero,
    /// A `to_end` or `to_last` repeat that leaves positions it does not fit (listed), cannot move
    /// forward, or works over a ring.
    RepeatDoesNotFit,
    /// A `tog` with fewer than 2 legs or more than the limit.
    TogetherLegs,
    /// A named stitch's use site gives a target its body does not take, or none when the body takes
    /// one; or `target` used outside a named stitch's body (ADR 0022 amendment of 2026-11-18).
    NamedTarget,
    /// A stated count that differs from the derived count.
    CountMismatch,
    /// An operation names a legend entry that does not exist (Ply never reads a display name such
    /// as "sc" as an identity).
    LegendUnknown,
    /// A legend body that uses itself, directly or through other entries.
    LegendCycle,
    /// A legend entry that reuses a word of either built-in label set, an id that is an identity
    /// name, or a name or abbreviation of another entry.
    LegendCollision,
    /// Two layers, or two legend entries, share an id.
    DuplicateId,
    /// Something passes a size limit, or the limits themselves cannot be used.
    TooLarge,
    // Warnings.
    /// A layer's instructions end before its base is used up.
    BaseUnfinished,
    /// `leave_unworked` with nothing left to leave.
    LeaveUnworkedEmpty,
    /// An opaque item or layer that does not state its counts: every count after it is unknown.
    CountUnknown,
    /// A starting chain in a spiral round after round 1.
    SpiralStartChain,
    // Unsupported.
    /// An opaque instruction (or a named stitch whose body holds one).
    UnsupportedOp,
    /// An opaque target.
    UnsupportedTarget,
    /// An opaque layer.
    UnsupportedLayer,
    // Information.
    /// Positions a `next` (or `skip`) passed over, left unworked.
    PassedOver,
    /// Single-loop work leaves a ridge on side A or side B.
    UnworkedLoops,
    /// More diagnostics of one code than the limit lists; the rest are counted here.
    ListCapped,
}

impl CrochetCode {
    /// Every code, errors first, then warnings, unsupported and information.
    pub const ALL: [CrochetCode; 39] = [
        CrochetCode::AnchorPastEnd,
        CrochetCode::AnchorKind,
        CrochetCode::SameWithoutPosition,
        CrochetCode::PartInvalid,
        CrochetCode::SpaceOpened,
        CrochetCode::RingMissing,
        CrochetCode::MarkerUnknown,
        CrochetCode::MarkerDuplicate,
        CrochetCode::MarkerScope,
        CrochetCode::MarkInvalid,
        CrochetCode::AnchorFuture,
        CrochetCode::JoinTarget,
        CrochetCode::JoinMissing,
        CrochetCode::SpiralTurn,
        CrochetCode::TurnInvalid,
        CrochetCode::LayerSequence,
        CrochetCode::LeaveMisplaced,
        CrochetCode::StartMisplaced,
        CrochetCode::StartInvalid,
        CrochetCode::RepeatZero,
        CrochetCode::RepeatDoesNotFit,
        CrochetCode::TogetherLegs,
        CrochetCode::NamedTarget,
        CrochetCode::CountMismatch,
        CrochetCode::LegendUnknown,
        CrochetCode::LegendCycle,
        CrochetCode::LegendCollision,
        CrochetCode::DuplicateId,
        CrochetCode::TooLarge,
        CrochetCode::BaseUnfinished,
        CrochetCode::LeaveUnworkedEmpty,
        CrochetCode::CountUnknown,
        CrochetCode::SpiralStartChain,
        CrochetCode::UnsupportedOp,
        CrochetCode::UnsupportedTarget,
        CrochetCode::UnsupportedLayer,
        CrochetCode::PassedOver,
        CrochetCode::UnworkedLoops,
        CrochetCode::ListCapped,
    ];

    /// The stable string form, e.g. `crochet.anchor_past_end`. Never changes once released.
    pub const fn as_str(self) -> &'static str {
        match self {
            CrochetCode::AnchorPastEnd => "crochet.anchor_past_end",
            CrochetCode::AnchorKind => "crochet.anchor_kind",
            CrochetCode::SameWithoutPosition => "crochet.same_without_position",
            CrochetCode::PartInvalid => "crochet.part_invalid",
            CrochetCode::SpaceOpened => "crochet.space_opened",
            CrochetCode::RingMissing => "crochet.ring_missing",
            CrochetCode::MarkerUnknown => "crochet.marker_unknown",
            CrochetCode::MarkerDuplicate => "crochet.marker_duplicate",
            CrochetCode::MarkerScope => "crochet.marker_scope",
            CrochetCode::MarkInvalid => "crochet.mark_invalid",
            CrochetCode::AnchorFuture => "crochet.anchor_future",
            CrochetCode::JoinTarget => "crochet.join_target",
            CrochetCode::JoinMissing => "crochet.join_missing",
            CrochetCode::SpiralTurn => "crochet.spiral_turn",
            CrochetCode::TurnInvalid => "crochet.turn_invalid",
            CrochetCode::LayerSequence => "crochet.layer_sequence",
            CrochetCode::LeaveMisplaced => "crochet.leave_misplaced",
            CrochetCode::StartMisplaced => "crochet.start_misplaced",
            CrochetCode::StartInvalid => "crochet.start_invalid",
            CrochetCode::RepeatZero => "crochet.repeat_zero",
            CrochetCode::RepeatDoesNotFit => "crochet.repeat_does_not_fit",
            CrochetCode::TogetherLegs => "crochet.together_legs",
            CrochetCode::NamedTarget => "crochet.named_target",
            CrochetCode::CountMismatch => "crochet.count_mismatch",
            CrochetCode::LegendUnknown => "crochet.legend_unknown",
            CrochetCode::LegendCycle => "crochet.legend_cycle",
            CrochetCode::LegendCollision => "crochet.legend_collision",
            CrochetCode::DuplicateId => "crochet.duplicate_id",
            CrochetCode::TooLarge => "crochet.too_large",
            CrochetCode::BaseUnfinished => "crochet.base_unfinished",
            CrochetCode::LeaveUnworkedEmpty => "crochet.leave_unworked_empty",
            CrochetCode::CountUnknown => "crochet.count_unknown",
            CrochetCode::SpiralStartChain => "crochet.spiral_start_chain",
            CrochetCode::UnsupportedOp => "crochet.unsupported_op",
            CrochetCode::UnsupportedTarget => "crochet.unsupported_target",
            CrochetCode::UnsupportedLayer => "crochet.unsupported_layer",
            CrochetCode::PassedOver => "crochet.passed_over",
            CrochetCode::UnworkedLoops => "crochet.unworked_loops",
            CrochetCode::ListCapped => "crochet.list_capped",
        }
    }

    /// The code for a stable string, if any.
    pub fn parse(s: &str) -> Option<CrochetCode> {
        CrochetCode::ALL.into_iter().find(|c| c.as_str() == s)
    }

    /// Each code always has the same severity.
    pub const fn severity(self) -> Severity {
        match self {
            CrochetCode::BaseUnfinished
            | CrochetCode::LeaveUnworkedEmpty
            | CrochetCode::CountUnknown
            | CrochetCode::SpiralStartChain => Severity::Warning,
            CrochetCode::UnsupportedOp
            | CrochetCode::UnsupportedTarget
            | CrochetCode::UnsupportedLayer => Severity::Unsupported,
            CrochetCode::PassedOver | CrochetCode::UnworkedLoops | CrochetCode::ListCapped => {
                Severity::Info
            }
            _ => Severity::Error,
        }
    }

    /// Position in [`CrochetCode::ALL`].
    pub(crate) fn rank(self) -> usize {
        CrochetCode::ALL
            .iter()
            .position(|&c| c == self)
            .unwrap_or(CrochetCode::ALL.len())
    }
}

impl Serialize for CrochetCode {
    fn serialize<S: serde::Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(self.as_str())
    }
}

impl<'de> Deserialize<'de> for CrochetCode {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let s = String::deserialize(d)?;
        CrochetCode::parse(&s)
            .ok_or_else(|| serde::de::Error::custom(format!("unknown crochet code {s:?}")))
    }
}

/// Where a diagnostic applies (ADR 0022 section 13's `CrochetLocation`). Every field is optional; a
/// document-level finding has none.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
pub struct CrochetLocation {
    /// The layer's position in the piece, from 1.
    pub layer: Option<u32>,
    /// The legend entry (index from 0) when the finding is in an entry or its body.
    pub legend: Option<u32>,
    /// The instruction: indices from 0 through repeat bodies (`[3, 1]` is the second instruction of
    /// the body of the fourth). Inside a named stitch's expansion this is the use site's path.
    pub path: Vec<u32>,
    /// The repetition (from 1) of each repeat on the path, when the finding is in one repetition.
    pub repetition: Vec<u32>,
    /// The item (`r.k`'s k) the finding is about, when it has one.
    pub item: Option<u32>,
    /// The base position the finding is about, when it has one.
    pub position: Option<PosRef>,
}

impl CrochetLocation {
    /// A whole layer.
    pub fn layer(layer: u32) -> CrochetLocation {
        CrochetLocation {
            layer: Some(layer),
            ..CrochetLocation::default()
        }
    }

    /// One instruction of a layer.
    pub fn instruction(layer: u32, path: Vec<u32>) -> CrochetLocation {
        CrochetLocation {
            layer: Some(layer),
            path,
            ..CrochetLocation::default()
        }
    }

    /// One legend entry, or an instruction of its body.
    pub fn legend(entry: u32, path: Vec<u32>) -> CrochetLocation {
        CrochetLocation {
            legend: Some(entry),
            path,
            ..CrochetLocation::default()
        }
    }

    pub fn with_item(mut self, item: Option<u32>) -> CrochetLocation {
        self.item = item;
        self
    }
}

/// What a count difference is about.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CountWhat {
    Stitches,
    Spaces,
    Identity(Counted),
}

/// One part of a stated count that differs from the derived count.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct CountDiff {
    pub what: CountWhat,
    pub stated: u32,
    pub derived: u32,
}

/// The most positions or items a diagnostic's detail lists (its `total` still counts them all).
pub const MAX_LISTED: usize = 64;

/// Structured detail, for tests and for views that build their own sentence.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Detail {
    #[default]
    None,
    /// Base positions (passed over, not reached, left over by a repeat), in the order met; at most
    /// [`MAX_LISTED`] are listed, `total` counts them all (a chain of an opened space counts 1).
    Positions { listed: Vec<PosRef>, total: u64 },
    /// The layers a finding concerns, `first` to `last` (for `crochet.count_unknown`, every layer it
    /// leaves unknown).
    Layers { first: u32, last: u32 },
    /// Every part of a stated count that differs.
    Counts(Vec<CountDiff>),
    /// A ridge of unworked loops on one side (`None` when the layer's facing is unknown), under these
    /// items (at most [`MAX_LISTED`]; `total` counts them all).
    Ridge {
        side: Option<Side>,
        items: Vec<ItemId>,
        total: u64,
    },
    /// Diagnostics of `code` not listed because they passed the per-code limit.
    Omitted { code: CrochetCode, count: u64 },
}

/// One finding about a pattern.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct Diagnostic {
    pub code: CrochetCode,
    pub severity: Severity,
    pub location: CrochetLocation,
    pub detail: Detail,
    /// A sentence for people, in no label set. Tests and navigation use the code and location.
    pub message: String,
}

impl Diagnostic {
    pub fn new(code: CrochetCode, location: CrochetLocation, message: impl Into<String>) -> Self {
        Diagnostic {
            code,
            severity: code.severity(),
            location,
            detail: Detail::None,
            message: message.into(),
        }
    }

    pub fn with_detail(mut self, detail: Detail) -> Self {
        self.detail = detail;
        self
    }
}

/// What [`Collector::admit`] decided for one finding.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Admit {
    /// Build it and [`Collector::store`] it: it will be listed.
    Kept,
    /// Past the cap: only counted, never built.
    Omitted,
    /// The collector is off (nobody reads this resolution's diagnostics): nothing is built.
    Off,
}

/// The per-code counts of a collector, to undo what a tried repetition found.
#[derive(Debug, Clone, Copy)]
pub(crate) struct Counts {
    items: usize,
    kept: [u32; CrochetCode::ALL.len()],
    omitted: [u64; CrochetCode::ALL.len()],
}

/// Collects diagnostics where they are made: each finding is counted per code when it is found, at
/// most `cap` of a code are built and kept, and the rest are only counted, so memory is bounded by
/// the cap whatever a pattern raises. It lists them in a fixed order: by code (errors, warnings,
/// unsupported, information), then layer, then the order found; then one `crochet.list_capped` per
/// code that passed the cap. A collector that is off builds and counts nothing.
pub(crate) struct Collector {
    cap: usize,
    on: bool,
    items: Vec<(usize, Diagnostic)>,
    kept: [u32; CrochetCode::ALL.len()],
    omitted: [u64; CrochetCode::ALL.len()],
    seq: usize,
}

impl Collector {
    pub(crate) fn new(cap: usize) -> Collector {
        Collector {
            cap: cap.max(1),
            on: true,
            items: Vec::new(),
            kept: [0; CrochetCode::ALL.len()],
            omitted: [0; CrochetCode::ALL.len()],
            seq: 0,
        }
    }

    /// A collector for a resolution whose diagnostics nobody reads.
    pub(crate) fn off() -> Collector {
        Collector {
            on: false,
            ..Collector::new(1)
        }
    }

    pub(crate) fn is_on(&self) -> bool {
        self.on
    }

    /// Count one finding of `code` and say whether it is to be built.
    pub(crate) fn admit(&mut self, code: CrochetCode) -> Admit {
        if !self.on {
            return Admit::Off;
        }
        let r = code.rank().min(CrochetCode::ALL.len() - 1);
        if (self.kept[r] as usize) < self.cap {
            self.kept[r] += 1;
            Admit::Kept
        } else {
            self.omitted[r] = self.omitted[r].saturating_add(1);
            Admit::Omitted
        }
    }

    /// Keep a diagnostic [`Collector::admit`] said to build.
    pub(crate) fn store(&mut self, d: Diagnostic) {
        self.items.push((self.seq, d));
        self.seq += 1;
    }

    /// Count a finding and keep it if it is listed.
    pub(crate) fn push(&mut self, d: Diagnostic) {
        if self.admit(d.code) == Admit::Kept {
            self.store(d);
        }
    }

    /// Count a finding of `code`, building it with `make` only when it is listed.
    pub(crate) fn push_with(&mut self, code: CrochetCode, make: impl FnOnce() -> Diagnostic) {
        if self.admit(code) == Admit::Kept {
            self.store(make());
        }
    }

    /// The counts now, to return to with [`Collector::restore`].
    pub(crate) fn counts(&self) -> Counts {
        Counts {
            items: self.items.len(),
            kept: self.kept,
            omitted: self.omitted,
        }
    }

    /// Forget everything found since `c` was taken.
    pub(crate) fn restore(&mut self, c: &Counts) {
        self.items.truncate(c.items);
        self.kept = c.kept;
        self.omitted = c.omitted;
    }

    pub(crate) fn finish(self) -> Vec<Diagnostic> {
        let Collector {
            cap,
            mut items,
            omitted,
            ..
        } = self;
        items.sort_by_key(|(seq, d)| (d.code.rank(), d.location.layer.unwrap_or(0), *seq));
        let mut out: Vec<Diagnostic> = items.into_iter().map(|(_, d)| d).collect();
        for (i, &n) in omitted.iter().enumerate() {
            if n > 0 {
                let code = CrochetCode::ALL[i];
                out.push(
                    Diagnostic::new(
                        CrochetCode::ListCapped,
                        CrochetLocation::default(),
                        format!(
                            "Ply lists the first {} {} diagnostics; {} more {} not listed.",
                            thousands(cap as u64),
                            code.as_str(),
                            thousands(n),
                            if n == 1 { "is" } else { "are" }
                        ),
                    )
                    .with_detail(Detail::Omitted { code, count: n }),
                );
            }
        }
        out
    }
}

/// `n` and the noun, singular or plural: "1 position", "4 positions".
pub(crate) fn count(n: u64, one: &str, many: &str) -> String {
    format!("{} {}", thousands(n), if n == 1 { one } else { many })
}

/// `1234567` as "1,234,567".
pub(crate) fn thousands(n: u64) -> String {
    let digits = n.to_string();
    let mut out = String::with_capacity(digits.len() + digits.len() / 3);
    for (i, ch) in digits.chars().enumerate() {
        if i > 0 && (digits.len() - i).is_multiple_of(3) {
            out.push(',');
        }
        out.push(ch);
    }
    out
}

/// At most `max_chars` characters of `text` (cut on a character boundary), with "..." when cut.
pub(crate) fn excerpt(text: &str, max_chars: usize) -> String {
    ply_common::readiness::bounded(text, max_chars)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn codes_round_trip_and_are_listed_by_severity() {
        for c in CrochetCode::ALL {
            assert_eq!(CrochetCode::parse(c.as_str()), Some(c));
            assert!(c.as_str().starts_with("crochet."));
        }
        assert_eq!(CrochetCode::parse("crochet.nope"), None);
        let sev: Vec<Severity> = CrochetCode::ALL.iter().map(|c| c.severity()).collect();
        let mut sorted = sev.clone();
        sorted.sort();
        assert_eq!(sev, sorted, "errors, warnings, unsupported, information");
        // Section 13's lists.
        use CrochetCode::*;
        for c in [
            BaseUnfinished,
            LeaveUnworkedEmpty,
            CountUnknown,
            SpiralStartChain,
        ] {
            assert_eq!(c.severity(), Severity::Warning);
        }
        for c in [UnsupportedOp, UnsupportedTarget, UnsupportedLayer] {
            assert_eq!(c.severity(), Severity::Unsupported);
        }
        for c in [PassedOver, UnworkedLoops] {
            assert_eq!(c.severity(), Severity::Info);
        }
        assert_eq!(CountMismatch.severity(), Severity::Error);
        assert_eq!(RepeatDoesNotFit.severity(), Severity::Error);
    }

    #[test]
    fn the_collector_caps_each_code() {
        let mut c = Collector::new(2);
        for layer in (1..=5).rev() {
            c.push(Diagnostic::new(
                CrochetCode::PassedOver,
                CrochetLocation::layer(layer),
                "p",
            ));
        }
        c.push(Diagnostic::new(
            CrochetCode::AnchorKind,
            CrochetLocation::layer(9),
            "k",
        ));
        let out = c.finish();
        assert_eq!(out.len(), 4);
        assert_eq!(out[0].code, CrochetCode::AnchorKind, "errors first");
        // The first two pushed (layers 5 and 4) are kept, listed by layer.
        assert_eq!(out[1].location.layer, Some(4));
        assert_eq!(out[2].location.layer, Some(5));
        assert_eq!(out[3].code, CrochetCode::ListCapped);
        assert_eq!(
            out[3].detail,
            Detail::Omitted {
                code: CrochetCode::PassedOver,
                count: 3
            }
        );
        assert_eq!(thousands(1_234_567), "1,234,567");
        assert_eq!(count(1, "position", "positions"), "1 position");
    }
}
