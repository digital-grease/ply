//! Stable, typed diagnostics (ADR 0018 section 13 and roadmap 10.2): a machine code that never
//! changes once released, a severity, a typed location (card, hole, pack, segment and step, pick,
//! face, run), a sentence for the weaver and, where Ply can suggest one, a remedy.

use crate::card::{Face, Hole};
use serde::{Deserialize, Serialize};

/// How much a diagnostic matters.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Severity {
    /// The band cannot be simulated until it is fixed.
    Error,
    /// The band can be woven, but something is likely to go wrong at the loom or in print.
    Warning,
    /// Something Ply does not model; shown as such, never approximated.
    Unsupported,
    /// A fact about the band worth showing (a reversal, a flip, a release).
    Info,
}

/// Every diagnostic code. The string form ([`TabletCode::as_str`]) is the stable identifier.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum TabletCode {
    /// A card's start is not one of the 8 legal arrangements.
    StartIllegal,
    /// A turn string does not have one letter per card.
    TurnsLength,
    /// A turn string holds something other than `F`, `B`, `I` or `?`.
    TurnLetter,
    /// A `?` without the pattern's words, or words for a card not marked `?`.
    UnsupportedText,
    /// A pack, flip, release or unsupported-turn text names a card that is not in the band, or
    /// names a card twice in one flip or release list.
    CardRef,
    /// A colour index past the end of the palette.
    PaletteRef,
    /// Two cards, or two packs, share an id.
    DuplicateId,
    /// A card or pack id is not of the form `[A-Za-z0-9][A-Za-z0-9_-]{0,63}`.
    IdInvalid,
    /// A segment repeated 0 times.
    RepeatZero,
    /// Something passes a size limit (cards, picks, segments, packs, a pack's list, palette, a text
    /// field), or the limits themselves cannot be used.
    TooLarge,
    /// A card's twist passes the band's warning threshold.
    TwistHigh,
    /// A thread stays in one layer for longer than the band's float threshold.
    LongFloat,
    /// No card turns on a pick (the weft lies in the same shed as the pick before).
    AllIdle,
    /// A card is listed in two packs (or twice in one).
    PackOverlap,
    /// A card's action is something Ply does not model (`?`).
    UnsupportedTurn,
    /// An empty hole crosses an edge (or is one of the two candidates of an ambiguous idle), so that
    /// face cell is not modelled.
    EmptyHoleFace,
    /// A pick note (brocade or other) that the face view does not show.
    NoteNotDrawn,
    /// A card's twining changes direction.
    Reversal,
    /// A card is flipped before a pick.
    Flip,
    /// The weaver released the twist behind some cards.
    TwistReleased,
    /// An idle card that has not turned since the start or its last flip: either upper (or lower)
    /// thread may show.
    FaceAmbiguous,
    /// More diagnostics of one code than the limit lists; the rest are counted here.
    ListCapped,
}

impl TabletCode {
    /// Every code, errors first, then warnings, unsupported and information. Diagnostics are
    /// listed in this order.
    pub const ALL: [TabletCode; 22] = [
        TabletCode::StartIllegal,
        TabletCode::TurnsLength,
        TabletCode::TurnLetter,
        TabletCode::UnsupportedText,
        TabletCode::CardRef,
        TabletCode::PaletteRef,
        TabletCode::DuplicateId,
        TabletCode::IdInvalid,
        TabletCode::RepeatZero,
        TabletCode::TooLarge,
        TabletCode::TwistHigh,
        TabletCode::LongFloat,
        TabletCode::AllIdle,
        TabletCode::PackOverlap,
        TabletCode::UnsupportedTurn,
        TabletCode::EmptyHoleFace,
        TabletCode::NoteNotDrawn,
        TabletCode::Reversal,
        TabletCode::Flip,
        TabletCode::TwistReleased,
        TabletCode::FaceAmbiguous,
        TabletCode::ListCapped,
    ];

    /// The stable string form, e.g. `tablet.long_float`. Never changes once released.
    pub const fn as_str(self) -> &'static str {
        match self {
            TabletCode::StartIllegal => "tablet.start_illegal",
            TabletCode::TurnsLength => "tablet.turns_length",
            TabletCode::TurnLetter => "tablet.turn_letter",
            TabletCode::UnsupportedText => "tablet.unsupported_text",
            TabletCode::CardRef => "tablet.card_ref",
            TabletCode::PaletteRef => "tablet.palette_ref",
            TabletCode::DuplicateId => "tablet.duplicate_id",
            TabletCode::IdInvalid => "tablet.id_invalid",
            TabletCode::RepeatZero => "tablet.repeat_zero",
            TabletCode::TooLarge => "tablet.too_large",
            TabletCode::TwistHigh => "tablet.twist_high",
            TabletCode::LongFloat => "tablet.long_float",
            TabletCode::AllIdle => "tablet.all_idle",
            TabletCode::PackOverlap => "tablet.pack_overlap",
            TabletCode::UnsupportedTurn => "tablet.unsupported_turn",
            TabletCode::EmptyHoleFace => "tablet.empty_hole_face",
            TabletCode::NoteNotDrawn => "tablet.note_not_drawn",
            TabletCode::Reversal => "tablet.reversal",
            TabletCode::Flip => "tablet.flip",
            TabletCode::TwistReleased => "tablet.twist_released",
            TabletCode::FaceAmbiguous => "tablet.face_ambiguous",
            TabletCode::ListCapped => "tablet.list_capped",
        }
    }

    /// The code for a stable string, if any (the inverse of [`TabletCode::as_str`]).
    pub fn parse(s: &str) -> Option<TabletCode> {
        TabletCode::ALL.into_iter().find(|c| c.as_str() == s)
    }

    /// Each code always has the same severity.
    pub const fn severity(self) -> Severity {
        match self {
            TabletCode::StartIllegal
            | TabletCode::TurnsLength
            | TabletCode::TurnLetter
            | TabletCode::UnsupportedText
            | TabletCode::CardRef
            | TabletCode::PaletteRef
            | TabletCode::DuplicateId
            | TabletCode::IdInvalid
            | TabletCode::RepeatZero
            | TabletCode::TooLarge => Severity::Error,
            TabletCode::TwistHigh
            | TabletCode::LongFloat
            | TabletCode::AllIdle
            | TabletCode::PackOverlap => Severity::Warning,
            TabletCode::UnsupportedTurn | TabletCode::EmptyHoleFace | TabletCode::NoteNotDrawn => {
                Severity::Unsupported
            }
            TabletCode::Reversal
            | TabletCode::Flip
            | TabletCode::TwistReleased
            | TabletCode::FaceAmbiguous
            | TabletCode::ListCapped => Severity::Info,
        }
    }

    /// Position in [`TabletCode::ALL`].
    pub(crate) fn rank(self) -> usize {
        TabletCode::ALL
            .iter()
            .position(|&c| c == self)
            .unwrap_or(TabletCode::ALL.len())
    }
}

impl Serialize for TabletCode {
    fn serialize<S: serde::Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(self.as_str())
    }
}

impl<'de> Deserialize<'de> for TabletCode {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let s = String::deserialize(d)?;
        TabletCode::parse(&s)
            .ok_or_else(|| serde::de::Error::custom(format!("unknown tablet code {s:?}")))
    }
}

/// The most card numbers a location lists (its `total` still counts them all).
pub const MAX_LOCATION_CARDS: usize = 32;

/// A set of cards: 1-based card numbers (card 1 at the weaver's left), ascending, at most
/// [`MAX_LOCATION_CARDS`] of them; `total` is how many there are in all.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
pub struct CardSet {
    pub cards: Vec<u32>,
    pub total: u32,
}

impl CardSet {
    /// From 1-based card numbers in ascending order.
    pub fn from_sorted(numbers: &[u32]) -> CardSet {
        CardSet {
            cards: numbers.iter().copied().take(MAX_LOCATION_CARDS).collect(),
            total: u32::try_from(numbers.len()).unwrap_or(u32::MAX),
        }
    }

    pub fn one(card: u32) -> CardSet {
        CardSet {
            cards: vec![card],
            total: 1,
        }
    }

    /// "card 4", "cards 1 to 8", "cards 1, 3 and 4", "cards 1 to 4 and 6" (with "and n more" when
    /// the list is capped).
    pub fn text(&self) -> String {
        card_list_text(&self.cards, self.total)
    }
}

/// The most pack numbers a location lists (its `total` still counts them all).
pub const MAX_LOCATION_PACKS: usize = 32;

/// A set of packs: distinct 1-based pack numbers, ascending, at most [`MAX_LOCATION_PACKS`] of
/// them; `total` is how many distinct packs there are in all.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
pub struct PackSet {
    pub packs: Vec<u32>,
    pub total: u32,
}

/// How a run of picks in one layer ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RunEnd {
    /// The thread changed layer after the run's last pick.
    Ended,
    /// The run was still going at the end of the band.
    BandEnd,
    /// The card's next action was one Ply does not model, so where the thread went is unknown.
    StateUnknown,
}

/// Where a diagnostic applies. Card, pack, segment and step numbers are 1-based positions; picks are
/// 1-based expanded pick numbers (every repeat written out).
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", tag = "kind")]
pub enum TabletLocation {
    /// The whole band (a size limit, a capped list).
    Band,
    /// One card's setup.
    Card { card: u32 },
    /// One hole of one card.
    Hole { card: u32, hole: Hole },
    /// Several cards' setup (cards that share an id).
    Cards { cards: CardSet },
    /// One pack.
    Pack { pack: u32 },
    /// A card named by several packs (or twice by one): the packs that name it, and how many
    /// times it is listed in all.
    PackCard {
        card: u32,
        packs: PackSet,
        listings: u32,
    },
    /// One segment of the turning.
    Segment { segment: u32 },
    /// One written pick (step) of a segment, before repeats are expanded; `card` when the problem is
    /// at one card's letter or event.
    Step {
        segment: u32,
        step: u32,
        card: Option<u32>,
    },
    /// Cards at one expanded pick; `face` when it concerns one face only.
    Pick {
        pick: u32,
        cards: CardSet,
        face: Option<Face>,
    },
    /// Diagnostics of `code` left out of the list because it passed the per-code limit.
    Omitted { code: TabletCode, count: u64 },
    /// One thread's run of picks in one layer (`face` top for the upper layer, back for the lower).
    Run {
        card: u32,
        hole: Hole,
        face: Face,
        first_pick: u32,
        last_pick: u32,
        end: RunEnd,
    },
}

impl TabletLocation {
    /// A sort key within one code: picks in order, runs by card, face and first pick; setup
    /// locations keep the order they were found in (document order).
    fn sort_key(&self) -> (u64, u64, u64, u64) {
        let face_rank = |f: Face| match f {
            Face::Top => 0,
            Face::Back => 1,
        };
        match self {
            TabletLocation::Pick { pick, cards, face } => (
                u64::from(*pick),
                u64::from(cards.cards.first().copied().unwrap_or(0)),
                face.map_or(0, |f| face_rank(f) + 1),
                0,
            ),
            TabletLocation::Run {
                card,
                hole,
                face,
                first_pick,
                ..
            } => (
                u64::from(*card),
                face_rank(*face),
                u64::from(*first_pick),
                hole.index() as u64,
            ),
            _ => (0, 0, 0, 0),
        }
    }
}

/// One finding about a band.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct Diagnostic {
    pub code: TabletCode,
    pub severity: Severity,
    pub location: TabletLocation,
    /// A sentence for the weaver. Tests and UI navigation use the code and location, not this text.
    pub message: String,
    /// What the weaver can do, when Ply can suggest something.
    pub remediation: Option<String>,
}

impl Diagnostic {
    pub fn new(code: TabletCode, location: TabletLocation, message: impl Into<String>) -> Self {
        Diagnostic {
            code,
            severity: code.severity(),
            location,
            message: message.into(),
            remediation: None,
        }
    }

    pub fn with_remediation(mut self, remediation: impl Into<String>) -> Self {
        self.remediation = Some(remediation.into());
        self
    }
}

#[cfg(test)]
thread_local! {
    /// How many diagnostics this thread's collectors have built (test builds only), to prove that
    /// a diagnostic past the cap is counted without being formatted.
    pub(crate) static BUILT: std::cell::Cell<u64> = const { std::cell::Cell::new(0) };
}

/// Collects diagnostics, at most `cap` per code, and lists them in a fixed order. A diagnostic past
/// the cap is only counted: callers hand [`Collector::push_with`] a closure, which runs (and
/// formats its message) only when the diagnostic will be listed.
pub(crate) struct Collector {
    cap: usize,
    items: Vec<(usize, Diagnostic)>,
    kept: [usize; TabletCode::ALL.len()],
    omitted: [u64; TabletCode::ALL.len()],
    seq: usize,
}

impl Collector {
    pub(crate) fn new(cap: usize) -> Collector {
        Collector {
            cap,
            items: Vec::new(),
            kept: [0; TabletCode::ALL.len()],
            omitted: [0; TabletCode::ALL.len()],
            seq: 0,
        }
    }

    /// Record one diagnostic of `code`, building it with `make` only if it will be listed.
    pub(crate) fn push_with(&mut self, code: TabletCode, make: impl FnOnce() -> Diagnostic) {
        let r = code.rank().min(TabletCode::ALL.len() - 1);
        if self.kept[r] < self.cap {
            #[cfg(test)]
            BUILT.with(|b| b.set(b.get() + 1));
            let d = make();
            debug_assert_eq!(d.code, code);
            self.kept[r] += 1;
            self.items.push((self.seq, d));
            self.seq += 1;
        } else {
            self.omitted[r] = self.omitted[r].saturating_add(1);
        }
    }

    pub(crate) fn has_errors(&self) -> bool {
        TabletCode::ALL.iter().enumerate().any(|(i, c)| {
            c.severity() == Severity::Error && (self.kept[i] > 0 || self.omitted[i] > 0)
        })
    }

    /// The diagnostics in code order (errors, warnings, unsupported, information), each code's own
    /// in location order, then one `tablet.list_capped` per code that passed the cap.
    pub(crate) fn finish(self) -> Vec<Diagnostic> {
        let Collector {
            cap,
            mut items,
            omitted,
            ..
        } = self;
        items.sort_by_key(|(seq, d)| (d.code.rank(), d.location.sort_key(), *seq));
        let mut out: Vec<Diagnostic> = items.into_iter().map(|(_, d)| d).collect();
        for (i, &n) in omitted.iter().enumerate() {
            if n > 0 {
                let code = TabletCode::ALL[i];
                out.push(Diagnostic::new(
                    TabletCode::ListCapped,
                    TabletLocation::Omitted { code, count: n },
                    format!(
                        "Ply lists the first {} {} diagnostic{}; {} more {} not listed.",
                        thousands(cap as u64),
                        code.as_str(),
                        if cap == 1 { "" } else { "s" },
                        thousands(n),
                        if n == 1 { "is" } else { "are" }
                    ),
                ));
            }
        }
        out
    }
}

/// `n` and the noun, singular or plural: "1 pick", "4 picks", "1,001 cards".
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
    let mut chars = text.chars();
    let mut out: String = chars.by_ref().take(max_chars).collect();
    if chars.next().is_some() {
        out.push_str("...");
    }
    out
}

/// "card 4", "cards 1 to 8", "cards 1, 3 and 4", "cards 1 to 4 and 6"; `total` past the listed
/// cards adds "and n more". Runs of three or more consecutive cards are written as ranges.
pub(crate) fn card_list_text(cards: &[u32], total: u32) -> String {
    let mut parts: Vec<String> = Vec::new();
    let mut i = 0;
    while i < cards.len() {
        let mut j = i;
        while j + 1 < cards.len() && cards[j + 1] == cards[j].saturating_add(1) {
            j += 1;
        }
        if j >= i + 2 {
            parts.push(format!("{} to {}", cards[i], cards[j]));
        } else {
            for c in &cards[i..=j] {
                parts.push(c.to_string());
            }
        }
        i = j + 1;
    }
    let listed = u32::try_from(cards.len()).unwrap_or(u32::MAX);
    if total > listed {
        parts.push(format!("{} more", thousands(u64::from(total - listed))));
    }
    let single = total == 1 && cards.len() == 1;
    let mut out = String::from(if single { "card " } else { "cards " });
    match parts.len() {
        0 => out.push_str("none"),
        1 => out.push_str(&parts[0]),
        n => {
            for (k, p) in parts.iter().enumerate() {
                if k > 0 {
                    out.push_str(if k == n - 1 { " and " } else { ", " });
                }
                out.push_str(p);
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn codes_round_trip_and_have_one_severity_each() {
        for c in TabletCode::ALL {
            assert_eq!(TabletCode::parse(c.as_str()), Some(c));
            assert!(c.as_str().starts_with("tablet."));
        }
        assert_eq!(TabletCode::parse("tablet.nope"), None);
        // Errors, then warnings, unsupported and information, as listed.
        let sev: Vec<Severity> = TabletCode::ALL.iter().map(|c| c.severity()).collect();
        let mut sorted = sev.clone();
        sorted.sort();
        assert_eq!(sev, sorted);
    }

    #[test]
    fn card_lists_read_naturally() {
        assert_eq!(card_list_text(&[4], 1), "card 4");
        assert_eq!(card_list_text(&[1, 2, 3, 4, 5, 6, 7, 8], 8), "cards 1 to 8");
        assert_eq!(card_list_text(&[1, 3, 4], 3), "cards 1, 3 and 4");
        assert_eq!(card_list_text(&[1, 2], 2), "cards 1 and 2");
        assert_eq!(card_list_text(&[1, 2, 3, 4, 6], 5), "cards 1 to 4 and 6");
        assert_eq!(card_list_text(&[1, 2], 40), "cards 1, 2 and 38 more");
        assert_eq!(card_list_text(&[], 0), "cards none");
    }

    #[test]
    fn numbers_and_excerpts() {
        assert_eq!(thousands(0), "0");
        assert_eq!(thousands(1000), "1,000");
        assert_eq!(thousands(200_000), "200,000");
        assert_eq!(thousands(1_234_567), "1,234,567");
        assert_eq!(excerpt("half turn", 20), "half turn");
        assert_eq!(excerpt("ééééé", 2), "éé...");
    }

    #[test]
    fn the_collector_caps_each_code_and_counts_the_rest() {
        let mut c = Collector::new(2);
        let before = BUILT.with(|b| b.get());
        for pick in (1..=5).rev() {
            c.push_with(TabletCode::Reversal, || {
                Diagnostic::new(
                    TabletCode::Reversal,
                    TabletLocation::Pick {
                        pick,
                        cards: CardSet::one(1),
                        face: None,
                    },
                    "r",
                )
            });
        }
        // Only the two listed diagnostics were built.
        assert_eq!(BUILT.with(|b| b.get()) - before, 2);
        assert!(!c.has_errors());
        let out = c.finish();
        assert_eq!(out.len(), 3);
        // The first two pushed are kept (picks 5 and 4), then listed in pick order.
        assert!(matches!(
            out[0].location,
            TabletLocation::Pick { pick: 4, .. }
        ));
        assert!(matches!(
            out[1].location,
            TabletLocation::Pick { pick: 5, .. }
        ));
        assert_eq!(out[2].code, TabletCode::ListCapped);
        assert_eq!(
            out[2].location,
            TabletLocation::Omitted {
                code: TabletCode::Reversal,
                count: 3
            }
        );
        assert!(out[2].message.contains("3 more are"), "{}", out[2].message);
    }
}
