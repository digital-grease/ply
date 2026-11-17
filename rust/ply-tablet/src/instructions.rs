//! Written working instructions (ADR 0018 sections 8 and 15): one line per pick, or per repeated
//! block of picks, naming packs and card ranges, with the events before a pick in words and the
//! twist ledger at the end of every segment.
//!
//! ```text
//! Picks 9 to 12   Left (cards 1 to 4) forward; Right (cards 5 to 8) backward. Worked 4 times.
//! Pick 6          Before the pick: release the twist behind card 1; flip card 4 (it becomes
//!                 Z-threaded). Cards 1 and 2 backward; cards 3 and 4 forward.
//! After pick 12   Twist: cards 1 to 8 +4. Every card is back at its starting position.
//! ```
//!
//! A pick is written by pack where a pack's cards all do the same thing, and otherwise by card
//! ranges; packs never add meaning to the per-card actions (section 7). The lines follow the written
//! turning: a segment of one written pick is one line; a segment of several picks worked once is one
//! line per pick; worked several times, a heading and one line per step.
//!
//! **Bounded.** At most `max_lines` lines are built; the rest are counted, not formatted. Every line
//! is bounded too: a pick lists at most 12 groups of cards, each group at most 32 card numbers, and
//! names and words are quoted in short.

use crate::band::{TabletBand, TabletLimits};
use crate::card::{ThreadingDirection, Turn};
use crate::diagnostic::{card_list_text, excerpt, MAX_LOCATION_CARDS};
use crate::error::TabletError;
use crate::simulate::{CardPick, Fold, Observer, PickContext};
use crate::validate::{check, Checked};

/// What a line is.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum InstructionKind {
    /// One pick, or one written pick worked several times in a row.
    Pick,
    /// The heading of a block of several picks worked several times.
    Block,
    /// One pick of such a block.
    Step,
    /// Each card's twist after the last pick of a segment.
    Ledger,
}

/// One line of working instructions.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct InstructionLine {
    pub kind: InstructionKind,
    /// "Pick 6", "Picks 9 to 12", "Step 2", "After pick 12".
    pub label: String,
    pub text: String,
    /// The 1-based segment the line is about.
    pub segment: u32,
    /// The expanded picks the line covers (the first time through, for a step).
    pub first_pick: u32,
    pub last_pick: u32,
}

/// A band's working instructions: the lines kept, and how many more there are.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Default)]
pub struct Instructions {
    pub lines: Vec<InstructionLine>,
    pub omitted: u64,
}

/// The most groups of cards one pick's line names; the rest are counted.
pub const MAX_GROUPS_PER_LINE: usize = 12;

/// The working instructions of a band, at most `max_lines` lines. Refuses a band with structural
/// errors, as simulation does. One fold over the band (for the threading after a flip and the twist
/// ledger); only kept lines are formatted.
pub fn working_instructions(
    band: &TabletBand,
    limits: &TabletLimits,
    max_lines: usize,
) -> Result<Instructions, TabletError> {
    let checked = check(band, limits)?;
    // Each pack's cards as indices, once; a pack that names a card twice (or none) is never used to
    // write a pick, since its cards would be named twice.
    let index: std::collections::HashMap<&str, usize> = band
        .cards
        .iter()
        .enumerate()
        .map(|(i, c)| (c.id.as_str(), i))
        .collect();
    let packs = band
        .packs
        .iter()
        .map(|p| {
            let mut idx = Vec::with_capacity(p.cards.len());
            let mut seen = std::collections::HashSet::with_capacity(p.cards.len());
            for id in &p.cards {
                let i = *index.get(id.as_str())?;
                if !seen.insert(i) {
                    return None;
                }
                idx.push(i);
            }
            (!idx.is_empty()).then_some(idx)
        })
        .collect();
    let mut obs = Writer {
        c: &checked,
        packs,
        max: max_lines,
        out: Instructions::default(),
        seg_first: 0,
        before: band.cards.iter().map(|c| Some(c.threading)).collect(),
    };
    let mut fold = Fold::new(&checked);
    fold.advance(checked.total_picks, &mut obs);
    Ok(obs.out)
}

struct Writer<'c, 'a> {
    c: &'c Checked<'a>,
    /// Each pack's card indices (`None`: not usable for writing picks).
    packs: Vec<Option<Vec<usize>>>,
    max: usize,
    out: Instructions,
    /// The first expanded pick of the current segment.
    seg_first: u32,
    /// Each card's threading before the current pick (`None` once unknown): a flip's new threading
    /// is said from this, not from the pick's row, where a `?` on the same pick has made it unknown.
    before: Vec<Option<ThreadingDirection>>,
}

/// Keep the line `make` builds, or only count it once `max` lines are kept.
fn push(out: &mut Instructions, max: usize, make: impl FnOnce() -> InstructionLine) {
    if out.lines.len() < max {
        out.lines.push(make());
    } else {
        out.omitted = out.omitted.saturating_add(1);
    }
}

impl Observer for Writer<'_, '_> {
    fn pick(&mut self, ctx: &PickContext<'_>, row: &[CardPick]) {
        let band = self.c.band;
        let seg = &band.turning.segments[ctx.segment];
        let n = seg.picks.len() as u32;
        let m = seg.repeat;
        let segment = u32::try_from(ctx.segment + 1).unwrap_or(u32::MAX);
        if ctx.step == 0 && ctx.repeat == 0 {
            self.seg_first = ctx.pick;
        }
        let first = self.seg_first;
        let last = first.saturating_add(n.saturating_mul(m)).saturating_sub(1);
        if ctx.repeat == 0 {
            if n == 1 {
                push(&mut self.out, self.max, || InstructionLine {
                    kind: InstructionKind::Pick,
                    label: picks_label(first, last),
                    text: {
                        let mut t = pick_text(band, &self.packs, ctx, &self.before, m > 1);
                        if m > 1 {
                            t.push_str(&format!(" Worked {m} times."));
                        }
                        t
                    },
                    segment,
                    first_pick: first,
                    last_pick: last,
                });
            } else if m == 1 {
                push(&mut self.out, self.max, || InstructionLine {
                    kind: InstructionKind::Pick,
                    label: format!("Pick {}", ctx.pick),
                    text: pick_text(band, &self.packs, ctx, &self.before, false),
                    segment,
                    first_pick: ctx.pick,
                    last_pick: ctx.pick,
                });
            } else {
                if ctx.step == 0 {
                    push(&mut self.out, self.max, || InstructionLine {
                        kind: InstructionKind::Block,
                        label: picks_label(first, last),
                        text: format!("Work the next {n} picks {m} times."),
                        segment,
                        first_pick: first,
                        last_pick: last,
                    });
                }
                push(&mut self.out, self.max, || InstructionLine {
                    kind: InstructionKind::Step,
                    label: format!("Step {}", ctx.step + 1),
                    text: pick_text(band, &self.packs, ctx, &self.before, true),
                    segment,
                    first_pick: ctx.pick,
                    last_pick: ctx.pick,
                });
            }
        }
        for (b, c) in self.before.iter_mut().zip(row) {
            *b = c.threading;
        }
        let ends_segment = ctx.step + 1 == seg.picks.len() && ctx.repeat + 1 == m;
        if ends_segment {
            let starts = &self.c.starts;
            push(&mut self.out, self.max, || InstructionLine {
                kind: InstructionKind::Ledger,
                label: format!("After pick {}", ctx.pick),
                text: ledger_text(row, |i| {
                    row[i].position.is_some_and(|p| p == starts[i])
                        && row[i].threading == Some(band.cards[i].threading)
                }),
                segment,
                first_pick: ctx.pick,
                last_pick: ctx.pick,
            });
        }
    }
}

fn picks_label(first: u32, last: u32) -> String {
    if first == last {
        format!("Pick {first}")
    } else {
        format!("Picks {first} to {last}")
    }
}

/// The events before a pick, then its turns, then any note and weft.
fn pick_text(
    band: &TabletBand,
    packs: &[Option<Vec<usize>>],
    ctx: &PickContext<'_>,
    before: &[Option<ThreadingDirection>],
    repeated: bool,
) -> String {
    let mut out = String::new();
    if let Some(refs) = ctx.refs {
        let mut events: Vec<String> = Vec::new();
        if !refs.release.is_empty() {
            events.push(format!(
                "release the twist behind {}",
                cards_text(&refs.release)
            ));
        }
        if !refs.flip.is_empty() {
            let one = refs.flip.len() == 1;
            // The threading just after the flip, before the pick's turn.
            let flipped = |i: usize| before[i].map(ThreadingDirection::flipped);
            let now = |t: Option<ThreadingDirection>| refs.flip.iter().all(|&i| flipped(i) == t);
            let note = if repeated {
                if one {
                    " (each time it changes S to Z or Z to S)".to_string()
                } else {
                    " (each time each changes S to Z or Z to S)".to_string()
                }
            } else if now(Some(ThreadingDirection::Z)) || now(Some(ThreadingDirection::S)) {
                let letter = flipped(refs.flip[0]).map_or('?', ThreadingDirection::letter);
                format!(
                    " ({} {letter}-threaded)",
                    if one { "it becomes" } else { "they become" }
                )
            } else if now(None) {
                format!(
                    " ({} threading is unknown)",
                    if one { "its" } else { "their" }
                )
            } else {
                " (each changes S to Z or Z to S)".to_string()
            };
            events.push(format!("flip {}{note}", cards_text(&refs.flip)));
        }
        if !events.is_empty() {
            out.push_str(if repeated {
                "Before it, each time: "
            } else {
                "Before the pick: "
            });
            out.push_str(&events.join("; "));
            out.push_str(". ");
        }
    }
    out.push_str(&turns_text(band, packs, ctx));
    if let Some(note) = &ctx.spec.note {
        let kind = match note.kind {
            crate::band::NoteKind::Brocade => "a brocade weft",
            crate::band::NoteKind::Other => "something",
        };
        out.push_str(&format!(
            " The pattern adds {kind} here that the band chart does not show: \"{}\".",
            excerpt(&note.text, 80)
        ));
    }
    if let Some(w) = ctx.spec.weft {
        out.push_str(&format!(" Weft: colour {}.", u64::from(w) + 1));
    }
    out
}

/// "card 4", "cards 1 to 8" for 0-based card indices in ascending order (at most 32 numbers kept).
fn cards_text(indices: &[usize]) -> String {
    let mut sorted: Vec<u32> = indices
        .iter()
        .map(|&i| u32::try_from(i + 1).unwrap_or(u32::MAX))
        .collect();
    sorted.sort_unstable();
    let total = u32::try_from(sorted.len()).unwrap_or(u32::MAX);
    sorted.truncate(MAX_LOCATION_CARDS);
    card_list_text(&sorted, total)
}

/// One group of cards doing the same thing: its first card (for ordering) and its words.
struct Group {
    first: usize,
    text: String,
}

/// The turns of a pick, by pack where a whole pack does one thing, else by card ranges.
fn turns_text(band: &TabletBand, packs: &[Option<Vec<usize>>], ctx: &PickContext<'_>) -> String {
    let letters = ctx.spec.turns.as_bytes();
    let n = band.cards.len();
    let turn = |i: usize| {
        letters
            .get(i)
            .and_then(|&b| Turn::from_letter(char::from(b)))
    };
    let words = |i: usize| ctx.refs.map_or("", |r| r.words_for(i));
    if n == 0 {
        return "No cards.".to_string();
    }
    let first = turn(0);
    let same_words = (0..n).all(|i| words(i) == words(0));
    if (0..n).all(|i| turn(i) == first) && (first != Some(Turn::Unsupported) || same_words) {
        return match first {
            Some(Turn::Forward) => "Every card forward.".to_string(),
            Some(Turn::Backward) => "Every card backward.".to_string(),
            Some(Turn::Idle) => "No card turns (every card idles).".to_string(),
            Some(Turn::Unsupported) => {
                format!("Every card: \"{}\" (not modelled).", excerpt(words(0), 80))
            }
            None => String::new(),
        };
    }
    let action = |t: Option<Turn>, i: usize, single: bool| -> String {
        match t {
            Some(Turn::Forward) => "forward".into(),
            Some(Turn::Backward) => "backward".into(),
            Some(Turn::Idle) => (if single { "idles" } else { "idle" }).into(),
            Some(Turn::Unsupported) => format!("\"{}\" (not modelled)", excerpt(words(i), 60)),
            None => "?".into(),
        }
    };
    let mut described = vec![false; n];
    let mut groups: Vec<Group> = Vec::new();
    // Whole packs first.
    for (pack, idx) in band.packs.iter().zip(packs) {
        let Some(idx) = idx else {
            continue;
        };
        if idx.iter().any(|&i| described[i]) {
            continue; // a card in two packs is written with the first
        }
        let t = turn(idx[0]);
        let w = words(idx[0]);
        if !idx.iter().all(|&i| turn(i) == t && words(i) == w) {
            continue;
        }
        for &i in idx {
            described[i] = true;
        }
        let first = *idx.iter().min().unwrap_or(&0);
        groups.push(Group {
            first,
            text: format!(
                "{} ({}) {}",
                excerpt(&pack.name, 40),
                cards_text(idx),
                action(t, first, false)
            ),
        });
    }
    // Then the other cards, grouped by what they do, in card order.
    let mut rest: Vec<(Option<Turn>, &str, Vec<usize>)> = Vec::new();
    for i in (0..n).filter(|&i| !described[i]) {
        let (t, w) = (turn(i), words(i));
        match rest.iter_mut().find(|(rt, rw, _)| *rt == t && *rw == w) {
            Some((_, _, list)) => list.push(i),
            None => rest.push((t, w, vec![i])),
        }
    }
    for (t, _, list) in &rest {
        let single = list.len() == 1;
        groups.push(Group {
            first: list[0],
            text: format!("{} {}", cards_text(list), action(*t, list[0], single)),
        });
    }
    groups.sort_by_key(|g| g.first);
    let more = groups.len().saturating_sub(MAX_GROUPS_PER_LINE);
    let mut parts: Vec<String> = groups
        .into_iter()
        .take(MAX_GROUPS_PER_LINE)
        .map(|g| g.text)
        .collect();
    if more > 0 {
        parts.push(format!(
            "and {more} more {} (see the turning chart)",
            if more == 1 {
                "group of cards"
            } else {
                "groups of cards"
            }
        ));
    }
    let mut text = parts.join("; ");
    if let Some(c) = text.get(..1) {
        let upper = c.to_uppercase();
        text.replace_range(..1, &upper);
    }
    text.push('.');
    text
}

/// "Twist: cards 1 to 4 +4, cards 5 to 8 -4." Cards grouped by their twist, at most 8 groups.
fn ledger_text(row: &[CardPick], at_start: impl Fn(usize) -> bool) -> String {
    if row.is_empty() {
        return "No cards.".to_string();
    }
    let mut groups: Vec<(Option<i32>, Vec<usize>)> = Vec::new();
    for (i, c) in row.iter().enumerate() {
        let t = c.twist.twist;
        match groups.iter_mut().find(|(v, _)| *v == t) {
            Some((_, list)) => list.push(i),
            None => groups.push((t, vec![i])),
        }
    }
    const MAX_LEDGER_GROUPS: usize = 8;
    let more: usize = groups
        .iter()
        .skip(MAX_LEDGER_GROUPS)
        .map(|(_, l)| l.len())
        .sum();
    let mut parts: Vec<String> = groups
        .iter()
        .take(MAX_LEDGER_GROUPS)
        .map(|(v, list)| {
            let amount = match v {
                Some(v) if *v > 0 => format!("+{v}"),
                Some(v) => v.to_string(),
                None => "unknown".to_string(),
            };
            format!("{} {amount}", cards_text(list))
        })
        .collect();
    if more > 0 {
        parts.push(format!(
            "{more} more {} other amounts",
            if more == 1 { "card with" } else { "cards with" }
        ));
    }
    let mut text = format!("Twist: {}.", parts.join(", "));
    if (0..row.len()).all(&at_start) {
        text.push_str(" Every card is back at its starting position.");
    }
    text
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::band::{HoleThreads, Pack, PickSpec, Segment, Tablet, TurnSequence};
    use crate::card::CardPosition;

    fn band(turns: &[(&str, u32)]) -> TabletBand {
        let n = turns[0].0.len();
        TabletBand {
            palette: vec![ply_common::Color::BLACK],
            cards: (0..n)
                .map(|i| {
                    Tablet::new(
                        format!("card-{}", i + 1),
                        HoleThreads::all(0),
                        ThreadingDirection::S,
                        CardPosition::ply_home(),
                    )
                })
                .collect(),
            turning: TurnSequence::new(
                turns
                    .iter()
                    .map(|(t, r)| Segment::new(*r, vec![PickSpec::new(*t)]))
                    .collect(),
            ),
            ..TabletBand::default()
        }
    }

    #[test]
    fn lines_are_capped_and_the_rest_counted() {
        let b = band(&[("FF", 1), ("BB", 1), ("FF", 1)]);
        let all = working_instructions(&b, &TabletLimits::DEFAULT, 100).unwrap();
        assert_eq!(all.lines.len(), 6);
        assert_eq!(all.omitted, 0);
        let few = working_instructions(&b, &TabletLimits::DEFAULT, 2).unwrap();
        assert_eq!(few.lines, all.lines[..2]);
        assert_eq!(few.omitted, 4);
    }

    #[test]
    fn a_flip_is_worded_from_the_threading_before_the_pick() {
        // Card 2 (S) is flipped before pick 2 and marked ? on that same pick: the flip makes it
        // Z-threaded; only afterwards is its state unknown.
        let mut b = band(&[("FF", 1), ("F?", 1), ("FF", 1)]);
        b.turning.segments[1].picks[0] = PickSpec::new("F?").with_flip(&["card-2"]);
        b.turning.segments[1].picks[0]
            .unsupported
            .insert("card-2".into(), "half turn".into());
        b.turning.segments[2].picks[0] = PickSpec::new("FF").with_flip(&["card-2"]);
        let ins = working_instructions(&b, &TabletLimits::DEFAULT, 100).unwrap();
        let text = |label: &str| {
            ins.lines
                .iter()
                .find(|l| l.label == label)
                .map(|l| l.text.clone())
                .unwrap()
        };
        assert!(
            text("Pick 2").starts_with("Before the pick: flip card 2 (it becomes Z-threaded)."),
            "{}",
            text("Pick 2")
        );
        // After the ?, its threading is unknown: a later flip says so.
        assert!(text("Pick 3").contains("flip card 2 (its threading is unknown)"));
    }

    #[test]
    fn many_groups_are_summarized() {
        let turns: String = (0..40).map(|i| ['F', 'B', 'I'][i % 3]).collect::<String>();
        let mut b = band(&[(&turns, 1)]);
        // Forty one-card packs: each its own group.
        b.packs = (0..40)
            .map(|i| Pack {
                id: format!("p{i}"),
                name: format!("P{i}"),
                cards: vec![format!("card-{}", i + 1).as_str().into()],
            })
            .collect();
        let ins = working_instructions(&b, &TabletLimits::DEFAULT, 10).unwrap();
        let text = &ins.lines[0].text;
        assert!(
            text.ends_with("and 28 more groups of cards (see the turning chart)."),
            "{text}"
        );
        assert!(text.starts_with("P0 (card 1) forward; P1 (card 2) backward; P2 (card 3) idle"));
    }
}
