//! Validation (ADR 0018 section 13 and roadmap 10.2). [`validate()`] lists every structural error of
//! a band; when there are none it also simulates the band and adds the warnings, unsupported markers
//! and information of sections 5 to 7. Structural errors refuse simulation; per-card `?` actions do
//! not.
//!
//! Sizes are untrusted: the counts (cards, segments, picks written and expanded, packs, palette) are
//! checked first, with checked arithmetic and before anything is allocated in proportion to them, and
//! a band that passes a limit gets only its `tablet.too_large` errors. Every card id a pick refers to
//! is resolved to a card index here, once per written pick, so simulating a pick never touches an id
//! string again. Diagnostics past the per-code cap are counted without being formatted.

use crate::band::{TabletBand, TabletLimits, TurnSequence};
use crate::card::{CardPosition, IllegalArrangement, Turn};
use crate::diagnostic::{
    count, excerpt, thousands, CardSet, Collector, Diagnostic, PackSet, Severity, TabletCode,
    TabletLocation, MAX_LOCATION_PACKS,
};
use crate::error::TabletError;
use crate::simulate::run_diagnostics;
use ply_common::materials::is_valid_id;
use std::collections::HashMap;
use std::fmt;

/// The events and words of one written pick, with every card id already resolved to a card index.
#[derive(Debug, Default)]
pub(crate) struct StepRefs<'a> {
    /// Cards whose twist is released before the pick.
    pub release: Vec<usize>,
    /// Cards flipped before the pick.
    pub flip: Vec<usize>,
    /// The pattern's words for each card marked `?`, by card index, ascending.
    pub words: Vec<(usize, &'a str)>,
}

impl StepRefs<'_> {
    /// The words for the `?` of card `card` (empty if none).
    pub fn words_for(&self, card: usize) -> &str {
        self.words
            .binary_search_by_key(&card, |&(c, _)| c)
            .map_or("", |i| self.words[i].1)
    }
}

/// A band whose structure has been checked: every start legal, every reference resolved, every
/// turn letter one of `F`, `B`, `I`, `?`, and every size within the limits.
pub(crate) struct Checked<'a> {
    pub band: &'a TabletBand,
    pub starts: Vec<CardPosition>,
    /// Per segment, per written pick: its resolved events and words (`None` when it has none).
    pub steps: Vec<Vec<Option<Box<StepRefs<'a>>>>>,
    pub total_picks: u32,
}

/// Validate with the default limits.
pub fn validate(band: &TabletBand) -> Vec<Diagnostic> {
    validate_with(band, &TabletLimits::DEFAULT)
}

/// Every diagnostic of a band: its structural errors, or (when it has none) everything the
/// simulation finds. Listed errors first, then warnings, unsupported markers and information, each
/// code at most `limits.max_diagnostics_per_code` times (the rest counted in `tablet.list_capped`).
pub fn validate_with(band: &TabletBand, limits: &TabletLimits) -> Vec<Diagnostic> {
    let mut out = Collector::new(limits.max_diagnostics_per_code);
    if let Some(checked) = check_into(band, limits, &mut out) {
        run_diagnostics(&checked, &mut out);
    }
    out.finish()
}

/// The structural check alone: the checked band, or every error found (each code at most
/// `limits.max_diagnostics_per_code` times, with a `tablet.list_capped` for each error code that
/// passed it).
pub(crate) fn check<'a>(
    band: &'a TabletBand,
    limits: &TabletLimits,
) -> Result<Checked<'a>, TabletError> {
    let mut out = Collector::new(limits.max_diagnostics_per_code);
    match check_into(band, limits, &mut out) {
        Some(c) => Ok(c),
        None => Err(TabletError::Invalid(
            out.finish()
                .into_iter()
                .filter(|d| match d.location {
                    TabletLocation::Omitted { code, .. } => code.severity() == Severity::Error,
                    _ => d.severity == Severity::Error,
                })
                .collect(),
        )),
    }
}

/// How many picks the turning expands to, or the `tablet.too_large` error that refuses it (too many
/// segments, or more picks written out or expanded than `limits.max_picks`, including totals past
/// `u32`, or limits that cannot be used). Nothing is allocated per pick.
pub fn expanded_picks(seq: &TurnSequence, limits: &TabletLimits) -> Result<u32, TabletError> {
    let mut out = Collector::new(limits.max_diagnostics_per_code);
    if !limits_sound(limits, &mut out) {
        return Err(TabletError::Invalid(out.finish()));
    }
    match count_picks(seq, limits, &mut out) {
        Some(n) => Ok(n),
        None => Err(TabletError::Invalid(out.finish())),
    }
}

fn too_large(out: &mut Collector, location: TabletLocation, message: impl FnOnce() -> String) {
    out.push_with(TabletCode::TooLarge, || {
        Diagnostic::new(TabletCode::TooLarge, location, message())
    });
}

fn limits_sound(limits: &TabletLimits, out: &mut Collector) -> bool {
    match limits.unsound() {
        None => true,
        Some(why) => {
            too_large(out, TabletLocation::Band, || {
                format!("These limits cannot be used: {why}.")
            });
            false
        }
    }
}

fn count_picks(seq: &TurnSequence, limits: &TabletLimits, out: &mut Collector) -> Option<u32> {
    let segments = seq.segments.len();
    if segments > limits.max_segments {
        too_large(out, TabletLocation::Band, || {
            format!(
                "The turning has {}; Ply's limit is {}.",
                count(segments as u64, "segment", "segments"),
                thousands(limits.max_segments as u64)
            )
        });
        return None;
    }
    let mut written: u64 = 0;
    let mut expanded: Option<u64> = Some(0);
    for seg in &seq.segments {
        let n = seg.picks.len() as u64;
        written = written.saturating_add(n);
        expanded = expanded.and_then(|e| {
            n.checked_mul(u64::from(seg.repeat))
                .and_then(|m| e.checked_add(m))
        });
    }
    let max = u64::from(limits.max_picks);
    let mut ok = true;
    if written > max {
        ok = false;
        too_large(out, TabletLocation::Band, || {
            format!(
                "The turning writes out {}; Ply's limit is {}.",
                count(written, "pick", "picks"),
                thousands(max)
            )
        });
    }
    match expanded {
        None => {
            ok = false;
            too_large(out, TabletLocation::Band, || {
                format!(
                    "The turning's repeats expand to more picks than can be counted; Ply's limit \
                     is {}.",
                    thousands(max)
                )
            });
        }
        Some(e) if e > max => {
            ok = false;
            too_large(out, TabletLocation::Band, || {
                format!(
                    "The turning's repeats expand to {}; Ply's limit is {}.",
                    count(e, "pick", "picks"),
                    thousands(max)
                )
            });
        }
        Some(_) => {}
    }
    match expanded {
        Some(e) if ok => u32::try_from(e).ok(),
        _ => None,
    }
}

/// The size checks that must pass before anything else is looked at.
fn check_sizes(band: &TabletBand, limits: &TabletLimits, out: &mut Collector) -> Option<u32> {
    let mut ok = true;
    let mut over = |n: usize, one: &str, many: &str, max: usize, out: &mut Collector| {
        if n > max {
            ok = false;
            too_large(out, TabletLocation::Band, || {
                format!(
                    "The band has {}; Ply's limit is {}.",
                    count(n as u64, one, many),
                    thousands(max as u64)
                )
            });
        }
    };
    over(band.cards.len(), "card", "cards", limits.max_cards, out);
    over(
        band.palette.len(),
        "palette colour",
        "palette colours",
        limits.max_palette,
        out,
    );
    over(band.packs.len(), "pack", "packs", limits.max_packs, out);
    let picks = count_picks(&band.turning, limits, out);
    if ok {
        picks
    } else {
        None
    }
}

fn text_too_long(
    out: &mut Collector,
    limits: &TabletLimits,
    text: &str,
    what: impl FnOnce() -> String,
    location: TabletLocation,
) {
    if text.len() > limits.max_text_bytes {
        too_large(out, location, || {
            format!(
                "{} is {} bytes long; Ply's limit is {}.",
                what(),
                thousands(text.len() as u64),
                thousands(limits.max_text_bytes as u64)
            )
        });
    }
}

/// "Segment 2, pick 3" (or "segment 2, pick 3"), formatted only when a message needs it.
#[derive(Clone, Copy)]
struct At {
    segment: usize,
    step: usize,
    lower: bool,
}

impl fmt::Display for At {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let word = if self.lower { "segment" } else { "Segment" };
        write!(f, "{word} {}, pick {}", self.segment + 1, self.step + 1)
    }
}

fn card_no(i: usize) -> u32 {
    u32::try_from(i + 1).unwrap_or(u32::MAX)
}

fn quoted(id: &str) -> String {
    format!("\"{}\"", excerpt(id, 40))
}

fn capitalized(s: &str) -> String {
    let mut c = s.chars();
    match c.next() {
        Some(f) => f.to_uppercase().collect::<String>() + c.as_str(),
        None => String::new(),
    }
}

const ID_RULE: &str =
    "an id is 1 to 64 letters, digits, '-' or '_', starting with a letter or digit";

/// Which packs list one card, counted without keeping more than [`MAX_LOCATION_PACKS`] numbers.
#[derive(Clone, Default)]
struct Membership {
    last: u32,
    distinct: u32,
    listings: u32,
    packs: Vec<u32>,
}

/// Check everything structural, pushing every finding (errors, and the pack-overlap warning) into
/// `out`. `Some` when there are no errors.
fn check_into<'a>(
    band: &'a TabletBand,
    limits: &TabletLimits,
    out: &mut Collector,
) -> Option<Checked<'a>> {
    if !limits_sound(limits, out) {
        return None;
    }
    let total_picks = check_sizes(band, limits, out)?;
    let cards = band.cards.len();
    let palette = band.palette.len();
    let colours = |n: usize| count(n as u64, "colour", "colours");

    // Card ids: well formed and unique. Each id is hashed once here; nothing later looks at it.
    let mut index: HashMap<&str, usize> = HashMap::with_capacity(cards);
    let mut shared: HashMap<usize, Vec<u32>> = HashMap::new();
    for (i, card) in band.cards.iter().enumerate() {
        let id = card.id.as_str();
        if !is_valid_id(id) {
            out.push_with(TabletCode::IdInvalid, || {
                Diagnostic::new(
                    TabletCode::IdInvalid,
                    TabletLocation::Card { card: card_no(i) },
                    format!(
                        "Card {}'s id {} is not valid: {ID_RULE}.",
                        i + 1,
                        quoted(id)
                    ),
                )
            });
        }
        match index.get(id) {
            Some(&first) => shared
                .entry(first)
                .or_insert_with(|| vec![card_no(first)])
                .push(card_no(i)),
            None => {
                index.insert(id, i);
            }
        }
    }
    let mut shared: Vec<(usize, Vec<u32>)> = shared.into_iter().collect();
    shared.sort();
    for (first, list) in &shared {
        out.push_with(TabletCode::DuplicateId, || {
            let set = CardSet::from_sorted(list);
            let text = capitalized(&set.text());
            Diagnostic::new(
                TabletCode::DuplicateId,
                TabletLocation::Cards { cards: set },
                format!(
                    "{text} share the id {}.",
                    quoted(band.cards[*first].id.as_str())
                ),
            )
            .with_remediation("Give every card its own id.")
        });
    }

    // Starts and threads.
    let mut starts = Vec::with_capacity(cards);
    for (i, card) in band.cards.iter().enumerate() {
        match CardPosition::try_from_arrangement(card.start) {
            Ok(p) => starts.push(p),
            Err(e) => {
                starts.push(CardPosition::PLY_HOME);
                out.push_with(TabletCode::StartIllegal, || {
                    let why = match e {
                        IllegalArrangement::Repeated { hole, missing } => format!(
                            "names hole {hole} at two corners and leaves out hole {missing}; a \
                             card's four corners hold A, B, C and D once each"
                        ),
                        IllegalArrangement::DiagonalOnEdge {
                            first,
                            second,
                            holes,
                        } => format!(
                            "puts {} at {} and {} at {}: they are diagonal holes, so they cannot \
                             share an edge of the card",
                            holes.0,
                            first.abbreviation(),
                            holes.1,
                            second.abbreviation()
                        ),
                    };
                    let a = card.start;
                    Diagnostic::new(
                        TabletCode::StartIllegal,
                        TabletLocation::Card { card: card_no(i) },
                        format!(
                            "Card {}'s start (NT {}, FT {}, FB {}, NB {}) {why}.",
                            i + 1,
                            a.near_top,
                            a.far_top,
                            a.far_bottom,
                            a.near_bottom
                        ),
                    )
                    .with_remediation(
                        "Choose a preset (A at the near top, or printed face to the right with D \
                         at the near top), or a quarter turn from one.",
                    )
                });
            }
        }
        for t in card.threads.iter() {
            if let Some(c) = t.color {
                if c as usize >= palette {
                    out.push_with(TabletCode::PaletteRef, || {
                        Diagnostic::new(
                            TabletCode::PaletteRef,
                            TabletLocation::Hole {
                                card: card_no(i),
                                hole: t.hole,
                            },
                            format!(
                                "Card {}, hole {} uses colour {}; the palette has {}.",
                                i + 1,
                                t.hole,
                                u64::from(c) + 1,
                                colours(palette)
                            ),
                        )
                    });
                }
            }
        }
    }
    if let Some(w) = band.weft {
        if w as usize >= palette {
            out.push_with(TabletCode::PaletteRef, || {
                Diagnostic::new(
                    TabletCode::PaletteRef,
                    TabletLocation::Band,
                    format!(
                        "The band's weft uses colour {}; the palette has {}.",
                        u64::from(w) + 1,
                        colours(palette)
                    ),
                )
            });
        }
    }

    // Packs: ids well formed and unique, cards known, no card in two packs. A pack can list at most
    // as many entries as a band can have cards, and each card's memberships are counted, not kept.
    let mut pack_ids: HashMap<&str, usize> = HashMap::with_capacity(band.packs.len());
    let mut members: Vec<Membership> = vec![Membership::default(); cards];
    for (p, pack) in band.packs.iter().enumerate() {
        let pack_no = card_no(p);
        let loc = || TabletLocation::Pack { pack: pack_no };
        if !is_valid_id(&pack.id) {
            out.push_with(TabletCode::IdInvalid, || {
                Diagnostic::new(
                    TabletCode::IdInvalid,
                    loc(),
                    format!(
                        "Pack {}'s id {} is not valid: {ID_RULE}.",
                        p + 1,
                        quoted(&pack.id)
                    ),
                )
            });
        }
        text_too_long(
            out,
            limits,
            &pack.name,
            || format!("The name of pack {}", p + 1),
            loc(),
        );
        if let Some(&first) = pack_ids.get(pack.id.as_str()) {
            out.push_with(TabletCode::DuplicateId, || {
                Diagnostic::new(
                    TabletCode::DuplicateId,
                    loc(),
                    format!(
                        "Packs {} and {} share the id {}.",
                        first + 1,
                        p + 1,
                        quoted(&pack.id)
                    ),
                )
            });
        } else {
            pack_ids.insert(pack.id.as_str(), p);
        }
        if pack.cards.len() > limits.max_cards {
            too_large(out, loc(), || {
                format!(
                    "Pack {} lists {}; a band can have at most {}.",
                    p + 1,
                    count(pack.cards.len() as u64, "card", "cards"),
                    thousands(limits.max_cards as u64)
                )
            });
            continue;
        }
        for id in &pack.cards {
            match index.get(id.as_str()) {
                Some(&c) => {
                    let m = &mut members[c];
                    m.listings = m.listings.saturating_add(1);
                    if m.last != pack_no {
                        m.last = pack_no;
                        m.distinct = m.distinct.saturating_add(1);
                        if m.packs.len() < MAX_LOCATION_PACKS {
                            m.packs.push(pack_no);
                        }
                    }
                }
                None => out.push_with(TabletCode::CardRef, || {
                    Diagnostic::new(
                        TabletCode::CardRef,
                        loc(),
                        format!(
                            "Pack {} ({}) lists the card {}, which is not in the band.",
                            p + 1,
                            quoted(&pack.name),
                            quoted(id.as_str())
                        ),
                    )
                }),
            }
        }
    }
    for (c, m) in members.into_iter().enumerate() {
        if m.listings < 2 {
            continue;
        }
        out.push_with(TabletCode::PackOverlap, || {
            const NAMED: usize = 4;
            let mut names: Vec<String> = m
                .packs
                .iter()
                .take(NAMED)
                .map(|&p| quoted(&band.packs[p as usize - 1].name))
                .collect();
            if m.distinct as usize > NAMED {
                names.push(format!("{} more", m.distinct as usize - NAMED));
            }
            let packs = PackSet {
                packs: m.packs,
                total: m.distinct,
            };
            Diagnostic::new(
                TabletCode::PackOverlap,
                TabletLocation::PackCard {
                    card: card_no(c),
                    packs,
                    listings: m.listings,
                },
                format!(
                    "Card {} is listed {} times ({}: {}); printed instructions would name it more \
                     than once.",
                    c + 1,
                    thousands(u64::from(m.listings)),
                    if m.distinct == 1 {
                        "in one pack"
                    } else {
                        "across packs"
                    },
                    names.join(", ")
                ),
            )
            .with_remediation("Keep each card in one pack at a time, listed once.")
        });
    }

    // The turning. `stamp` marks the cards already named in the current flip or release list, so a
    // card named twice is found without allocating per list.
    let mut stamp: Vec<u64> = vec![0; cards];
    let mut list_no: u64 = 0;
    let mut steps: Vec<Vec<Option<Box<StepRefs<'a>>>>> =
        Vec::with_capacity(band.turning.segments.len());
    for (s, seg) in band.turning.segments.iter().enumerate() {
        let seg_no = card_no(s);
        if seg.repeat == 0 {
            out.push_with(TabletCode::RepeatZero, || {
                Diagnostic::new(
                    TabletCode::RepeatZero,
                    TabletLocation::Segment { segment: seg_no },
                    format!("Segment {} is repeated 0 times.", s + 1),
                )
                .with_remediation("A segment is worked at least once; delete it if unwanted.")
            });
        }
        let mut seg_steps = Vec::with_capacity(seg.picks.len());
        for (k, spec) in seg.picks.iter().enumerate() {
            let step_no = card_no(k);
            let here = |card: Option<u32>| TabletLocation::Step {
                segment: seg_no,
                step: step_no,
                card,
            };
            let at = At {
                segment: s,
                step: k,
                lower: false,
            };
            let mut refs = StepRefs::default();

            // Letters: one per card, each F, B, I or ?.
            let mut letters = 0usize;
            for (i, ch) in spec.turns.chars().enumerate() {
                letters += 1;
                if Turn::from_letter(ch).is_none() {
                    out.push_with(TabletCode::TurnLetter, || {
                        let card = (i < cards).then(|| card_no(i));
                        let d = Diagnostic::new(
                            TabletCode::TurnLetter,
                            here(card),
                            format!(
                                "{at}, letter {}: {:?} is not a turn. The turns are F (forward), \
                                 B (backward), I (idle) and ? (something Ply does not model).",
                                i + 1,
                                ch
                            ),
                        );
                        if ch.is_ascii_digit() {
                            d.with_remediation(
                                "Ply does not model half or whole turns yet: mark the card ? and \
                                 write what the pattern says (for example \"half turn forward\").",
                            )
                        } else if matches!(ch, 'f' | 'b' | 'i') {
                            d.with_remediation("Turn letters are capitals: F, B or I.")
                        } else {
                            d
                        }
                    });
                }
            }
            if letters != cards {
                out.push_with(TabletCode::TurnsLength, || {
                    Diagnostic::new(
                        TabletCode::TurnsLength,
                        here(None),
                        format!(
                            "{at} gives {} for a band of {}.",
                            count(letters as u64, "turn", "turns"),
                            count(cards as u64, "card", "cards")
                        ),
                    )
                });
            }

            // `?` and its words, both ways round.
            let ascii = spec.turns.is_ascii();
            if ascii {
                for (i, &b) in spec.turns.as_bytes().iter().enumerate().take(cards) {
                    if b != b'?' {
                        continue;
                    }
                    match spec.unsupported.get(&band.cards[i].id) {
                        Some(t) if !t.trim().is_empty() => refs.words.push((i, t.as_str())),
                        _ => out.push_with(TabletCode::UnsupportedText, || {
                            Diagnostic::new(
                                TabletCode::UnsupportedText,
                                here(Some(card_no(i))),
                                format!(
                                    "{at}: card {} is marked ? but has no words saying what the \
                                     pattern does.",
                                    i + 1
                                ),
                            )
                            .with_remediation(
                                "Write the pattern's own words for this card (for example \"half \
                                 turn\").",
                            )
                        }),
                    }
                }
            }
            for (id, text) in &spec.unsupported {
                let card = index.get(id.as_str()).copied();
                text_too_long(
                    out,
                    limits,
                    text,
                    || format!("{at}: the words for card {}", quoted(id.as_str())),
                    here(card.map(card_no)),
                );
                match card {
                    None => out.push_with(TabletCode::CardRef, || {
                        Diagnostic::new(
                            TabletCode::CardRef,
                            here(None),
                            format!(
                                "{at} has words for the card {}, which is not in the band.",
                                quoted(id.as_str())
                            ),
                        )
                    }),
                    Some(c) => {
                        let letter = if ascii {
                            spec.turns.as_bytes().get(c).copied()
                        } else {
                            None
                        };
                        if letter.is_some() && letter != Some(b'?') {
                            out.push_with(TabletCode::UnsupportedText, || {
                                Diagnostic::new(
                                    TabletCode::UnsupportedText,
                                    here(Some(card_no(c))),
                                    format!(
                                        "{at} has words for card {}, which is not marked ?.",
                                        c + 1
                                    ),
                                )
                                .with_remediation("Mark the card ?, or remove the words.")
                            });
                        }
                    }
                }
            }

            // Releases and flips name known cards, each once.
            for (list, what, release) in [
                (&spec.release_twist, "releases", true),
                (&spec.flip, "flips", false),
            ] {
                list_no += 1;
                for id in list {
                    match index.get(id.as_str()) {
                        None => out.push_with(TabletCode::CardRef, || {
                            Diagnostic::new(
                                TabletCode::CardRef,
                                here(None),
                                format!(
                                    "The {what} before {} name the card {}, which is not in the \
                                     band.",
                                    At { lower: true, ..at },
                                    quoted(id.as_str())
                                ),
                            )
                        }),
                        Some(&c) => {
                            if stamp[c] == list_no {
                                out.push_with(TabletCode::CardRef, || {
                                    Diagnostic::new(
                                        TabletCode::CardRef,
                                        here(Some(card_no(c))),
                                        format!(
                                            "The {what} before {} name card {} twice.",
                                            At { lower: true, ..at },
                                            c + 1
                                        ),
                                    )
                                });
                            } else {
                                stamp[c] = list_no;
                                if release {
                                    refs.release.push(c);
                                } else {
                                    refs.flip.push(c);
                                }
                            }
                        }
                    }
                }
            }

            if let Some(note) = &spec.note {
                text_too_long(
                    out,
                    limits,
                    &note.text,
                    || format!("{at}: the note"),
                    here(None),
                );
            }
            if let Some(w) = spec.weft {
                if w as usize >= palette {
                    out.push_with(TabletCode::PaletteRef, || {
                        Diagnostic::new(
                            TabletCode::PaletteRef,
                            here(None),
                            format!(
                                "{at}: the weft uses colour {}; the palette has {}.",
                                u64::from(w) + 1,
                                colours(palette)
                            ),
                        )
                    });
                }
            }
            let empty = refs.release.is_empty() && refs.flip.is_empty() && refs.words.is_empty();
            seg_steps.push((!empty).then(|| Box::new(refs)));
        }
        steps.push(seg_steps);
    }

    if out.has_errors() {
        return None;
    }
    Some(Checked {
        band,
        starts,
        steps,
        total_picks,
    })
}
