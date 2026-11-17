//! A tablet band as the weaver sets it up: the palette, the cards (threads, threading, start), the
//! packs, the turning and the warning settings (ADR 0018 sections 2, 3, 7 and 10).
//!
//! These are plain data, in the shape of the native document body (ADR 0018 section 14): a band read
//! from a file may be wrong in any way, and [`crate::validate()`] names every problem with a typed
//! diagnostic instead of refusing to hold it. The per-card, per-pick actions are the source of truth;
//! packs are named groups for authoring and print only.

use crate::card::{Arrangement, CardPosition, Hole, ThreadingDirection, Turn};
use ply_common::Color;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// An index into the band's palette.
pub type ColorIndex = u32;

/// A card's stable id: it survives inserting, deleting and moving cards (packs, flips, releases and
/// unsupported-turn texts refer to cards by id, turn strings by position).
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(transparent)]
pub struct CardId(pub String);

impl CardId {
    pub fn new(id: impl Into<String>) -> CardId {
        CardId(id.into())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl From<&str> for CardId {
    fn from(s: &str) -> CardId {
        CardId(s.to_string())
    }
}

/// The thread in one hole: a palette colour, or `None` for an empty hole.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct HoleThread {
    pub hole: Hole,
    pub color: Option<ColorIndex>,
}

/// A card's four threads, by hole. `None` is an empty hole. All four keys must be present when
/// read (`null` for an empty hole), so a hole left out by mistake is refused rather than read as
/// empty.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct HoleThreads {
    #[serde(rename = "A", deserialize_with = "required")]
    pub a: Option<ColorIndex>,
    #[serde(rename = "B", deserialize_with = "required")]
    pub b: Option<ColorIndex>,
    #[serde(rename = "C", deserialize_with = "required")]
    pub c: Option<ColorIndex>,
    #[serde(rename = "D", deserialize_with = "required")]
    pub d: Option<ColorIndex>,
}

/// An `Option` that must still be written out (as `null` when empty): with `deserialize_with`, serde
/// no longer treats the missing key as `None`.
fn required<'de, D: serde::Deserializer<'de>>(d: D) -> Result<Option<ColorIndex>, D::Error> {
    Option::<ColorIndex>::deserialize(d)
}

impl HoleThreads {
    /// Every hole threaded with one colour.
    pub const fn all(color: ColorIndex) -> HoleThreads {
        HoleThreads {
            a: Some(color),
            b: Some(color),
            c: Some(color),
            d: Some(color),
        }
    }

    /// Threads for holes A, B, C, D in that order.
    pub const fn new(a: ColorIndex, b: ColorIndex, c: ColorIndex, d: ColorIndex) -> HoleThreads {
        HoleThreads {
            a: Some(a),
            b: Some(b),
            c: Some(c),
            d: Some(d),
        }
    }

    pub const fn get(&self, hole: Hole) -> Option<ColorIndex> {
        match hole {
            Hole::A => self.a,
            Hole::B => self.b,
            Hole::C => self.c,
            Hole::D => self.d,
        }
    }

    pub fn set(&mut self, hole: Hole, color: Option<ColorIndex>) {
        match hole {
            Hole::A => self.a = color,
            Hole::B => self.b = color,
            Hole::C => self.c = color,
            Hole::D => self.d = color,
        }
    }

    /// The four threads, hole A first.
    pub fn iter(&self) -> impl Iterator<Item = HoleThread> + '_ {
        Hole::ALL.into_iter().map(|hole| HoleThread {
            hole,
            color: self.get(hole),
        })
    }
}

/// One card as set up before weaving.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Tablet {
    pub id: CardId,
    pub threads: HoleThreads,
    /// The threading at the start of the band (flips change it during weaving).
    pub threading: ThreadingDirection,
    /// Which hole is at each corner at the start. Checked by validation: only the 8 legal
    /// arrangements can be woven.
    pub start: Arrangement,
}

impl Tablet {
    /// A fully threaded card at a legal start.
    pub fn new(
        id: impl Into<String>,
        threads: HoleThreads,
        threading: ThreadingDirection,
        start: CardPosition,
    ) -> Tablet {
        Tablet {
            id: CardId(id.into()),
            threads,
            threading,
            start: start.arrangement(),
        }
    }
}

/// A named set of cards, turned together when the weaver chooses (an authoring and printing aid;
/// cards may move between packs, so the stored per-card turns stay the source of truth).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Pack {
    pub id: String,
    pub name: String,
    pub cards: Vec<CardId>,
}

/// What a pick note records that is not card state.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum NoteKind {
    /// A supplementary (brocade) weft on this pick.
    Brocade,
    /// Anything else Ply does not model (beads, threads picked out of a shed, ...).
    Other,
}

/// A note on one pick: never changes card state; the face view says it does not show it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PickNote {
    pub kind: NoteKind,
    pub text: String,
}

/// One pick as written: every card's action, and the events before it.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PickSpec {
    /// One letter per card, in card order: `F` forward, `B` backward, `I` idle, `?` something Ply
    /// does not model (whose words are in [`PickSpec::unsupported`]).
    pub turns: String,
    /// Cards whose twist the weaver released before this pick (applied first).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub release_twist: Vec<CardId>,
    /// Cards flipped before this pick (applied after the releases, before the turns).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub flip: Vec<CardId>,
    /// The pattern's own words for each card marked `?`, by card id (exactly those cards).
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub unsupported: BTreeMap<CardId, String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub note: Option<PickNote>,
    /// This pick's weft, when it differs from the band's (recorded, not drawn in v1).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub weft: Option<ColorIndex>,
}

impl PickSpec {
    /// A pick from its turn letters, with no events.
    pub fn new(turns: impl Into<String>) -> PickSpec {
        PickSpec {
            turns: turns.into(),
            ..PickSpec::default()
        }
    }

    /// A pick from typed turns (a `?` card still needs its words in [`PickSpec::unsupported`]).
    pub fn from_turns(turns: &[Turn]) -> PickSpec {
        PickSpec::new(turns.iter().map(|t| t.letter()).collect::<String>())
    }

    /// Every card does the same thing.
    pub fn all(turn: Turn, cards: usize) -> PickSpec {
        PickSpec::new(std::iter::repeat_n(turn.letter(), cards).collect::<String>())
    }

    /// The action of the card at `index` (0-based), if the letter there is a turn letter.
    pub fn turn(&self, index: usize) -> Option<Turn> {
        self.turns.as_bytes().get(index).and_then(|&b| {
            if b.is_ascii() {
                Turn::from_byte(b)
            } else {
                None
            }
        })
    }

    pub fn with_flip(mut self, cards: &[&str]) -> PickSpec {
        self.flip = cards.iter().map(|&c| CardId::from(c)).collect();
        self
    }

    pub fn with_release(mut self, cards: &[&str]) -> PickSpec {
        self.release_twist = cards.iter().map(|&c| CardId::from(c)).collect();
        self
    }
}

fn one() -> u32 {
    1
}

/// A block of picks worked `repeat` times in a row (at least once). Events inside a repeated block
/// happen in every repeat.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Segment {
    #[serde(default = "one")]
    pub repeat: u32,
    pub picks: Vec<PickSpec>,
}

impl Segment {
    pub fn new(repeat: u32, picks: Vec<PickSpec>) -> Segment {
        Segment { repeat, picks }
    }
}

/// The turning: segments in order. Expanding the repeats gives the picks the engine, the progress
/// tracker and the diagnostics count (1-based).
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(transparent)]
pub struct TurnSequence {
    pub segments: Vec<Segment>,
}

impl TurnSequence {
    pub fn new(segments: Vec<Segment>) -> TurnSequence {
        TurnSequence { segments }
    }
}

/// The default `twist_warning_quarters`: 32 quarter turns, that is 8 full turns. A heuristic; no
/// source gives a number.
pub const DEFAULT_TWIST_WARNING_QUARTERS: u32 = 32;
/// The default `float_warning_picks`: runs of more than 3 picks are warned about (double-face and
/// 3/1 broken twill float over 3 routinely).
pub const DEFAULT_FLOAT_WARNING_PICKS: u32 = 3;

fn default_twist_warning() -> u32 {
    DEFAULT_TWIST_WARNING_QUARTERS
}

fn default_float_warning() -> u32 {
    DEFAULT_FLOAT_WARNING_PICKS
}

/// Warning thresholds, adjustable per band.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BandSettings {
    /// Warn when a card's `|twist|` passes this many quarter turns.
    #[serde(default = "default_twist_warning")]
    pub twist_warning_quarters: u32,
    /// Warn about an upper or lower run longer than this many picks.
    #[serde(default = "default_float_warning")]
    pub float_warning_picks: u32,
}

impl Default for BandSettings {
    fn default() -> Self {
        BandSettings {
            twist_warning_quarters: DEFAULT_TWIST_WARNING_QUARTERS,
            float_warning_picks: DEFAULT_FLOAT_WARNING_PICKS,
        }
    }
}

/// A whole band: what the engine simulates.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TabletBand {
    /// Colours as `#rrggbb`.
    #[serde(with = "hex_palette")]
    pub palette: Vec<Color>,
    /// The band's weft (recorded, not drawn in v1).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub weft: Option<ColorIndex>,
    /// Card 1 (the weaver's left) first.
    pub cards: Vec<Tablet>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub packs: Vec<Pack>,
    pub turning: TurnSequence,
    #[serde(default)]
    pub settings: BandSettings,
}

impl TabletBand {
    /// The colour of a card's hole, if the card exists and the hole is threaded.
    pub fn thread_color(&self, card: usize, hole: Hole) -> Option<ColorIndex> {
        self.cards.get(card).and_then(|c| c.threads.get(hole))
    }
}

/// Size budgets for a band. Sizes come from untrusted files and FFI calls; every count is checked
/// against these with checked arithmetic before anything proportional to it is allocated.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct TabletLimits {
    /// Most cards (historical bands reach 300 tablets).
    pub max_cards: usize,
    /// Most picks after expanding every repeat (and most picks written out before expanding).
    pub max_picks: u32,
    /// Most segments in the turning.
    pub max_segments: usize,
    /// Most packs.
    pub max_packs: usize,
    /// Most cells (cards times picks) in one simulated window; a larger view asks for windows.
    pub max_window_cells: usize,
    /// Most bytes in one text field (an id, a pack name, a note, the words for a `?` turn).
    pub max_text_bytes: usize,
    /// Most palette entries.
    pub max_palette: usize,
    /// Most diagnostics listed for one code; the rest are counted in one `tablet.list_capped` note.
    pub max_diagnostics_per_code: usize,
}

/// Most cards in a band ([`TabletLimits::DEFAULT`]).
pub const MAX_CARDS: usize = 1_000;
/// Most expanded picks in a band ([`TabletLimits::DEFAULT`]).
pub const MAX_PICKS: u32 = 200_000;
/// Most segments in a band's turning ([`TabletLimits::DEFAULT`]).
pub const MAX_SEGMENTS: usize = 10_000;
/// Most packs in a band ([`TabletLimits::DEFAULT`]).
pub const MAX_PACKS: usize = 1_000;
/// Most cells in one simulated window ([`TabletLimits::DEFAULT`]). A cell is a [`crate::CardPick`]
/// of 48 bytes, so the largest default window is about 48 MB.
pub const MAX_WINDOW_CELLS: usize = 1_000_000;
/// Most bytes in one text field ([`TabletLimits::DEFAULT`]).
pub const MAX_TEXT_BYTES: usize = 10_000;
/// Most palette entries ([`TabletLimits::DEFAULT`]).
pub const MAX_PALETTE: usize = 256;
/// Most diagnostics listed per code ([`TabletLimits::DEFAULT`]).
pub const MAX_DIAGNOSTICS_PER_CODE: usize = 1_000;

impl TabletLimits {
    /// The phone budget. `twist` and `woven` fit in `i32` under it (at most `MAX_PICKS` in
    /// magnitude).
    pub const DEFAULT: TabletLimits = TabletLimits {
        max_cards: MAX_CARDS,
        max_picks: MAX_PICKS,
        max_segments: MAX_SEGMENTS,
        max_packs: MAX_PACKS,
        max_window_cells: MAX_WINDOW_CELLS,
        max_text_bytes: MAX_TEXT_BYTES,
        max_palette: MAX_PALETTE,
        max_diagnostics_per_code: MAX_DIAGNOSTICS_PER_CODE,
    };

    /// Why these limits cannot be used, if they cannot: every count they allow must fit the numbers
    /// the engine reports. `twist` and `woven` are `i32` and move by one quarter turn a pick, so
    /// `max_picks` may not pass `i32::MAX`; cards, packs and segments are numbered with `u32`.
    pub fn unsound(&self) -> Option<&'static str> {
        if i32::try_from(self.max_picks).is_err() {
            Some("max_picks passes i32::MAX, so the twist ledger could overflow")
        } else if u32::try_from(self.max_cards).is_err() {
            Some("max_cards passes u32::MAX, so cards could not be numbered")
        } else if u32::try_from(self.max_packs).is_err() {
            Some("max_packs passes u32::MAX, so packs could not be numbered")
        } else if u32::try_from(self.max_segments).is_err() {
            Some("max_segments passes u32::MAX, so segments could not be numbered")
        } else {
            None
        }
    }
}

impl Default for TabletLimits {
    fn default() -> Self {
        TabletLimits::DEFAULT
    }
}

/// The palette as `#rrggbb` strings. The parser checks every byte before slicing, so no input can
/// make it panic.
mod hex_palette {
    use ply_common::Color;
    use serde::{Deserialize, Deserializer, Serializer};

    pub fn serialize<S: Serializer>(palette: &[Color], s: S) -> Result<S::Ok, S::Error> {
        s.collect_seq(palette.iter().map(|c| c.to_hex()))
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Vec<Color>, D::Error> {
        let raw = Vec::<String>::deserialize(d)?;
        raw.iter()
            .map(|s| {
                parse(s).ok_or_else(|| {
                    serde::de::Error::custom("a palette colour is not of the form #rrggbb")
                })
            })
            .collect()
    }

    fn parse(s: &str) -> Option<Color> {
        let hex = s.strip_prefix('#')?.as_bytes();
        if hex.len() != 6 || !hex.iter().all(u8::is_ascii_hexdigit) {
            return None;
        }
        let byte = |i: usize| -> Option<u8> {
            let text = std::str::from_utf8(&hex[i..i + 2]).ok()?;
            u8::from_str_radix(text, 16).ok()
        };
        Some(Color {
            r: byte(0)?,
            g: byte(2)?,
            b: byte(4)?,
        })
    }

    #[cfg(test)]
    mod tests {
        use super::parse;

        #[test]
        fn parses_only_hex_triples() {
            assert_eq!(
                parse("#1a1a1a").map(|c| (c.r, c.g, c.b)),
                Some((26, 26, 26))
            );
            assert_eq!(parse("1a1a1a"), None);
            assert_eq!(parse("#1a1a1"), None);
            assert_eq!(parse("#aé123"), None);
            assert_eq!(parse("#gggggg"), None);
        }
    }
}
