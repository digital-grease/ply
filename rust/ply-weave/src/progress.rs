//! Working a draft pick by pick (roadmap M8-05, ADR 0023): what to press or lift for each pick, in
//! a weaver's words, and where a weaver who saved their place resumes.
//!
//! The work unit is one pick of the draft, numbered from 1 as the draft numbers it, and a draft is
//! woven as many times through as the cloth needs. What is up comes from [`Draft::raised_shafts`],
//! the one place shed direction is handled; what goes down is every other shaft. On a sinking shed
//! (a counterbalance or countermarch loom) a treadle pulls its tied shafts down, so the sentence says
//! what goes down and what that leaves up. The working semantics the draft records (pick roles,
//! shuttles and their starting sides, strands, shot groups; ADR 0008, 0009) are told as notes, for
//! the time through the weaver is on; nothing is inferred when they are not recorded.
//!
//! A pick's IDENTITY is everything the weaver is told to do at it: the treadles pressed, the shafts
//! up, the weft (its palette index and colour), the role, the shuttle and the side it starts from,
//! the strands and the shot group. A place's fingerprint is the hash of every pick's identity up to
//! and including it ([`prefix`]), so inserting or removing a whole shed repeat before the place (two
//! picks of plain weave in a stripe) changes it. See [`ply_common::progress`] for how a saved place
//! is compared with the draft as it is now.

use crate::draft::{Draft, Drive, PickRole, ShedType, Side};
use ply_common::progress::{reconcile, Basis, Fingerprint, Resume, ResumeStatus};
use ply_common::Color;

/// The most picks one [`window`] call returns.
pub const MAX_WINDOW: usize = 500;

/// The most shaft and treadle numbers one [`window`] call lists in all; the window stops after the
/// pick that passes it (the first pick asked for is always returned). Keeps a window of a hostile
/// draft (tens of thousands of shafts on every pick) small.
pub const MAX_WINDOW_NUMBERS: usize = 100_000;

/// The most numbers a sentence lists before "and N more".
const MAX_LISTED: usize = 24;

/// One pick, as the weaver works it.
#[derive(Debug, Clone, PartialEq)]
pub struct PickWork {
    /// The pick, numbered from 1.
    pub pick: usize,
    /// The treadles pressed (treadled drafts; sorted, without repeats). Empty for a lift plan.
    pub treadles: Vec<u16>,
    /// The shafts up for this pick (sorted, without repeats), from [`Draft::raised_shafts`].
    pub raised: Vec<u16>,
    /// What to do, as one sentence: `Press treadle 3: shafts 1 and 2 rise.`, `Lift shafts 1, 2 and
    /// 4.`, or on a sinking shed `Press treadle 3: shafts 3 and 4 go down, so shafts 1 and 2 are up.`
    pub action: String,
    /// The weft colour's palette index and colour (`None` when the draft gives this pick none, or one
    /// past its palette).
    pub weft_index: Option<usize>,
    pub weft: Option<Color>,
    /// The recorded role (`Unknown` when not recorded).
    pub role: PickRole,
    /// The working notes in words, in a fixed order: role, shuttle and side, strands, shot group,
    /// same shed as the pick before.
    pub notes: Vec<String>,
    /// The prefix fingerprint at this pick (see the module docs). The same on every time through.
    pub prefix: u64,
}

/// A window could not be made.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WindowError {
    /// `first` is 0 or past the draft's picks, or after `last`, or the time through is 0.
    OutOfRange {
        first: usize,
        last: usize,
        picks: usize,
    },
}

impl std::fmt::Display for WindowError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            WindowError::OutOfRange { first, last, picks } => write!(
                f,
                "picks {first} to {last} are not in this draft, which has {picks} picks"
            ),
        }
    }
}

impl std::error::Error for WindowError {}

/// What a draft says about each pick beyond its shed, worked out once per call (linear in the picks
/// and shot groups, whatever a hostile draft holds).
struct Facts {
    treadled: bool,
    /// The side each pick's pass starts from on the first time through ([`Draft::pass_starts`]).
    starts: Vec<Option<Side>>,
    /// Per shuttle, its passes in one time through; empty when any pick's shuttle is unknown (every
    /// direction after the first time through is then unknown).
    passes: Option<std::collections::BTreeMap<u8, usize>>,
    /// Per pick, its pass in a shot group and the group's size: the first group in the draft's list
    /// that holds it, as [`Draft::shot_group_at`] finds it.
    shots: Vec<Option<(usize, usize)>>,
}

impl Facts {
    fn new(draft: &Draft) -> Facts {
        let picks = draft.picks();
        let recorded = draft.weft_work.shuttles.iter().any(Option::is_some);
        let starts = if recorded {
            draft.pass_starts()
        } else {
            Vec::new()
        };
        let passes = recorded
            .then(|| {
                let mut n = std::collections::BTreeMap::new();
                for p in 0..picks {
                    *n.entry(draft.shuttle(p)?.0).or_insert(0usize) += 1;
                }
                Some(n)
            })
            .flatten();
        // The first group in list order holding each pick; `next[k]` skips picks already given one,
        // so every pick is assigned once however the groups overlap.
        let mut shots: Vec<Option<(usize, usize)>> = vec![None; picks];
        let mut next: Vec<usize> = (0..=picks).collect();
        fn find(next: &mut [usize], k: usize) -> usize {
            let mut r = k;
            while next[r] != r {
                r = next[r];
            }
            let mut c = k;
            while next[c] != r {
                let n = next[c];
                next[c] = r;
                c = n;
            }
            r
        }
        for g in &draft.weft_work.shot_groups {
            let end = g.end().min(picks);
            if g.start >= end {
                continue;
            }
            let mut k = find(&mut next, g.start);
            while k < end {
                shots[k] = Some((k - g.start + 1, g.picks));
                next[k] = k + 1;
                k = find(&mut next, k + 1);
            }
        }
        Facts {
            treadled: matches!(draft.drive, Drive::Treadled { .. }),
            starts,
            passes,
            shots,
        }
    }

    /// The side the 0-based `pick`'s pass starts from on the `time`-th time through (from 1): a
    /// shuttle with an odd number of passes in one time through starts from the other side every
    /// second time.
    fn start(&self, draft: &Draft, pick: usize, time: usize) -> Option<Side> {
        let first = self.starts.get(pick).copied().flatten();
        if time <= 1 {
            return first;
        }
        let n = *self.passes.as_ref()?.get(&draft.shuttle(pick)?.0)?;
        let flip = !n.is_multiple_of(2) && time.is_multiple_of(2);
        first.map(|s| if flip { s.other() } else { s })
    }
}

/// The treadles pressed for the 0-based `pick` (empty for a lift plan), sorted, without repeats.
fn treadles_of(draft: &Draft, pick: usize) -> Vec<u16> {
    match &draft.drive {
        Drive::Treadled { treadling, .. } => {
            let mut t: Vec<u16> = treadling
                .0
                .get(pick)
                .map(|row| row.iter().map(|t| t.0).collect())
                .unwrap_or_default();
            t.sort_unstable();
            t.dedup();
            t
        }
        Drive::Liftplan(_) => Vec::new(),
    }
}

/// The shafts up for the 0-based `pick`, sorted, without repeats.
fn raised_of(draft: &Draft, pick: usize) -> Vec<u16> {
    let mut s: Vec<u16> = draft.raised_shafts(pick).iter().map(|s| s.0).collect();
    s.sort_unstable();
    s.dedup();
    s
}

/// The shafts down for a pick: every shaft of the loom that [`Draft::raised_shafts`] does not raise
/// (`raised` sorted). Shed direction is decided there alone.
fn lowered_of(draft: &Draft, raised: &[u16]) -> Vec<u16> {
    (1..=draft.shafts)
        .filter(|s| raised.binary_search(s).is_err())
        .collect()
}

/// Feed the identity of the 0-based `pick` (everything the weaver is told at it) into `fp`.
fn feed(
    fp: &mut Fingerprint,
    draft: &Draft,
    facts: &Facts,
    pick: usize,
    treadles: &[u16],
    raised: &[u16],
) {
    fp.number(u64::from(facts.treadled));
    fp.number(treadles.len() as u64);
    for &t in treadles {
        fp.number(u64::from(t));
    }
    fp.number(raised.len() as u64);
    for &s in raised {
        fp.number(u64::from(s));
    }
    match draft.colors.weft.get(pick) {
        Some(&i) => {
            fp.number(1 + i as u64);
            match draft.colors.palette.get(i) {
                Some(c) => fp.bytes(&[1, c.r, c.g, c.b]),
                None => fp.bytes(&[0]),
            }
        }
        None => fp.number(0),
    }
    fp.number(match draft.pick_role(pick) {
        PickRole::Unknown => 0,
        PickRole::Pattern => 1,
        PickRole::Tabby => 2,
        PickRole::TopLayer => 3,
        PickRole::BottomLayer => 4,
    });
    fp.number(draft.shuttle(pick).map_or(0, |s| 1 + u64::from(s.0)));
    fp.number(match facts.starts.get(pick).copied().flatten() {
        None => 0,
        Some(Side::Left) => 1,
        Some(Side::Right) => 2,
    });
    fp.number(u64::from(draft.strands(pick)));
    let (pass, of) = facts.shots.get(pick).copied().flatten().unwrap_or((0, 0));
    fp.number(pass as u64);
    fp.number(of as u64);
}

/// The prefix fingerprint at the 0-based `pick`: every pick's identity from the first up to and
/// including it. `pick` past the end hashes the picks there are.
pub fn prefix(draft: &Draft, pick: usize) -> u64 {
    let facts = Facts::new(draft);
    let mut fp = Fingerprint::new();
    for p in 0..pick.saturating_add(1).min(draft.picks()) {
        feed(
            &mut fp,
            draft,
            &facts,
            p,
            &treadles_of(draft, p),
            &raised_of(draft, p),
        );
    }
    fp.value()
}

/// `shaft 1`, `shafts 1 and 2`, `shafts 1, 2 and 4`; past [`MAX_LISTED`] numbers, `shafts 1, 2,
/// ..., 24 and 40 more`.
fn list(one: &str, many: &str, numbers: &[u16]) -> String {
    let shown: Vec<String> = numbers
        .iter()
        .take(MAX_LISTED)
        .map(u16::to_string)
        .collect();
    let rest = numbers.len().saturating_sub(MAX_LISTED);
    let noun = if numbers.len() == 1 { one } else { many };
    let body = match (shown.as_slice(), rest) {
        ([], _) => String::new(),
        ([only], 0) => only.clone(),
        ([init @ .., last], 0) => format!("{} and {last}", init.join(", ")),
        (all, n) => format!("{} and {n} more", all.join(", ")),
    };
    format!("{noun} {body}")
}

/// The sentence for what to press or lift. Which shafts are up comes from [`Draft::raised_shafts`]
/// alone; the loom's shed type only chooses the words a weaver uses for it (on a sinking shed the
/// treadle pulls shafts down).
fn action(draft: &Draft, treadles: &[u16], raised: &[u16]) -> String {
    let up_list = |verb_one: &str, verb_many: &str| {
        let verb = if raised.len() == 1 {
            verb_one
        } else {
            verb_many
        };
        format!("{} {verb}", list("shaft", "shafts", raised))
    };
    match &draft.drive {
        Drive::Liftplan(_) => {
            if raised.is_empty() {
                "Lift no shafts for this pick.".to_string()
            } else {
                format!("Lift {}.", list("shaft", "shafts", raised))
            }
        }
        Drive::Treadled { .. } => {
            let press = match treadles.len() {
                0 => "No treadle is pressed for this pick".to_string(),
                1 => format!("Press {}", list("treadle", "treadles", treadles)),
                _ => format!("Press {} together", list("treadle", "treadles", treadles)),
            };
            if draft.shed == ShedType::Sinking {
                let down = lowered_of(draft, raised);
                let up = if raised.is_empty() {
                    "no shafts are up".to_string()
                } else {
                    up_list("is up", "are up")
                };
                if down.is_empty() {
                    format!("{press}: nothing goes down, so {up}.")
                } else {
                    let verb = if down.len() == 1 { "goes" } else { "go" };
                    format!(
                        "{press}: {} {verb} down, so {up}.",
                        list("shaft", "shafts", &down)
                    )
                }
            } else if raised.is_empty() {
                format!("{press}: no shafts rise.")
            } else {
                format!("{press}: {}.", up_list("rises", "rise"))
            }
        }
    }
}

/// `double`, `triple`, or `4-pass` for a shot group of `n` passes.
fn shot_name(n: usize) -> String {
    match n {
        2 => "double".to_string(),
        3 => "triple".to_string(),
        n => format!("{n}-pass"),
    }
}

/// The working notes of the 0-based `pick` on the `time`-th time through, in words.
fn notes(draft: &Draft, facts: &Facts, pick: usize, time: usize) -> Vec<String> {
    let mut out = Vec::new();
    match draft.pick_role(pick) {
        PickRole::Unknown => {}
        PickRole::Pattern => out.push("A pattern pick.".to_string()),
        PickRole::Tabby => out.push("A tabby pick.".to_string()),
        PickRole::TopLayer => out.push("This pick weaves the top layer.".to_string()),
        PickRole::BottomLayer => out.push("This pick weaves the bottom layer.".to_string()),
    }
    if let Some(shuttle) = draft.shuttle(pick) {
        match facts.start(draft, pick, time) {
            Some(Side::Left) => out.push(format!(
                "Shuttle {}, from the left (left to right).",
                shuttle.0
            )),
            Some(Side::Right) => out.push(format!(
                "Shuttle {}, from the right (right to left).",
                shuttle.0
            )),
            None => out.push(format!("Shuttle {}.", shuttle.0)),
        }
    }
    let strands = draft.strands(pick);
    if strands > 1 {
        out.push(format!("{strands} strands together in this pass."));
    }
    // The pick before: the one before it in the draft, or on a later time through, the draft's last
    // pick before pick 1.
    let before = match (pick, time) {
        (0, t) if t > 1 && draft.picks() > 1 => Some(draft.picks() - 1),
        (0, _) => None,
        (p, _) => Some(p - 1),
    };
    if let Some((pass, of)) = facts.shots.get(pick).copied().flatten() {
        let name = shot_name(of);
        if pass == 1 {
            out.push(format!(
                "Pass 1 of a {name} shot: {of} passes in this one shed."
            ));
        } else {
            out.push(format!(
                "Pass {pass} of a {name} shot: keep the same shed, do not change it."
            ));
        }
    } else if before.is_some_and(|b| draft.same_shed(b, pick)) {
        out.push("Same shed as the pick before.".to_string());
    }
    out
}

/// Picks `first..=last` (numbered from 1) of the `time`-th time through the draft (from 1), as the
/// weaver works them: at most [`MAX_WINDOW`] of them (`last` is cut to the draft's end and to the
/// window's size), stopping after the pick that passes [`MAX_WINDOW_NUMBERS`] listed numbers, so
/// `first` itself is always returned. The time through changes only the words that depend on it (a
/// shuttle's side, whether pick 1 repeats the shed of the last pick); fingerprints are the same on
/// every time. A draft with no picks gives an empty window for any `first` of 1. Never panics.
pub fn window(
    draft: &Draft,
    first: usize,
    last: usize,
    time: usize,
) -> Result<Vec<PickWork>, WindowError> {
    let picks = draft.picks();
    if picks == 0 && first <= 1 {
        return Ok(Vec::new());
    }
    if first == 0 || first > picks || last < first || time == 0 {
        return Err(WindowError::OutOfRange { first, last, picks });
    }
    let last = last.min(picks).min(first + MAX_WINDOW - 1);
    let facts = Facts::new(draft);
    let mut fp = Fingerprint::new();
    let mut out = Vec::with_capacity(last - first + 1);
    let mut listed = 0usize;
    for p in 0..last {
        let treadles = treadles_of(draft, p);
        let raised = raised_of(draft, p);
        feed(&mut fp, draft, &facts, p, &treadles, &raised);
        if p + 1 < first {
            continue;
        }
        listed = listed.saturating_add(treadles.len() + raised.len());
        let weft_index = draft.colors.weft.get(p).copied();
        out.push(PickWork {
            pick: p + 1,
            action: action(draft, &treadles, &raised),
            treadles,
            raised,
            weft_index,
            weft: weft_index.and_then(|i| draft.colors.palette.get(i).copied()),
            role: draft.pick_role(p),
            notes: notes(draft, &facts, p, time),
            prefix: fp.value(),
        });
        if listed > MAX_WINDOW_NUMBERS {
            break;
        }
    }
    Ok(out)
}

/// Where a weaver resumes: how their saved place compares, the pick to show (from 1), and the
/// sentence to show with it (`None` when there is nothing to say).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PickResume {
    pub resume: Resume,
    pub pick: usize,
    pub message: Option<String>,
}

/// Compare a saved place (`pick`, numbered from 1, with its `basis`) with the draft as it is now.
/// A pick of 0 reads as pick 1. Never moves the place: see [`ply_common::progress::reconcile`].
pub fn resume(draft: &Draft, pick: usize, basis: Option<Basis>) -> PickResume {
    let picks = draft.picks();
    let saved = pick.max(1) - 1;
    let r = reconcile(
        saved as u64,
        basis,
        picks as u64,
        |u| prefix(draft, u as usize),
        || None,
    );
    let shown = r.unit as usize + 1;
    let message = match r.status {
        ResumeStatus::Same => None,
        ResumeStatus::LengthChanged { was } => Some(format!(
            "The draft has changed after your place: it now has {picks} picks (it had {was}). Your \
             place is unchanged."
        )),
        ResumeStatus::Changed => Some(format!(
            "The draft has changed at or before pick {shown} since you saved your place. Check \
             that pick {shown} is where you are."
        )),
        ResumeStatus::Clamped { was } => Some(format!(
            "Your place was pick {}, but the draft now has {picks} picks. It is shown at pick \
             {shown}: check where you are.",
            was + 1
        )),
        ResumeStatus::Empty => Some("This draft has no picks to weave.".to_string()),
    };
    PickResume {
        resume: r,
        pick: if r.status == ResumeStatus::Empty {
            1
        } else {
            shown
        },
        message,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::draft::{Liftplan, ShaftId, ShotGroup, ShuttleId, TieUp, TreadleId, Treadling};
    use crate::structure;

    fn twill() -> Draft {
        // A 2/2 twill on 4 shafts, treadled 1, 2, 3, 4.
        let mut d = structure::plain_weave(4, 4);
        d.shafts = 4;
        d.treadles = 4;
        d.drive = Drive::Treadled {
            tieup: TieUp::twill(2, 2),
            treadling: Treadling((1..=4).map(|t| vec![TreadleId(t)]).collect()),
        };
        d
    }

    #[test]
    fn a_rising_shed_says_which_treadle_and_which_shafts_rise() {
        let d = twill();
        let w = window(&d, 1, 4, 1).unwrap();
        assert_eq!(w.len(), 4);
        assert_eq!(w[0].pick, 1);
        assert_eq!(w[0].treadles, vec![1]);
        assert_eq!(w[0].raised, raised_of(&d, 0));
        let shafts: Vec<String> = w[0].raised.iter().map(u16::to_string).collect();
        assert_eq!(
            w[0].action,
            format!("Press treadle 1: shafts {} rise.", shafts.join(" and "))
        );
    }

    #[test]
    fn a_sinking_shed_says_what_goes_down_and_what_is_up() {
        let mut d = twill();
        d.shed = ShedType::Sinking;
        let w = window(&d, 1, 1, 1).unwrap();
        let Drive::Treadled { tieup, .. } = &d.drive else {
            unreachable!()
        };
        let down: Vec<u16> = tieup.shafts_for(TreadleId(1)).iter().map(|s| s.0).collect();
        let up = raised_of(&d, 0);
        assert!(
            down.iter().all(|s| !up.contains(s)),
            "down and up are apart"
        );
        assert!(w[0].action.starts_with("Press treadle 1: shafts "));
        assert!(
            w[0].action.contains("go down, so shafts "),
            "{}",
            w[0].action
        );
        assert!(w[0].action.ends_with(" are up."), "{}", w[0].action);
    }

    #[test]
    fn a_lift_plan_says_which_shafts_to_lift() {
        let mut d = twill();
        d.drive = Drive::Liftplan(Liftplan(vec![
            vec![ShaftId(1), ShaftId(2), ShaftId(4)],
            vec![],
            vec![ShaftId(3)],
        ]));
        let w = window(&d, 1, 3, 1).unwrap();
        assert_eq!(w[0].action, "Lift shafts 1, 2 and 4.");
        assert_eq!(w[1].action, "Lift no shafts for this pick.");
        assert_eq!(w[2].action, "Lift shaft 3.");
        assert!(w[0].treadles.is_empty());
    }

    #[test]
    fn several_treadles_are_pressed_together() {
        let mut d = twill();
        if let Drive::Treadled { treadling, .. } = &mut d.drive {
            treadling.0[0] = vec![TreadleId(3), TreadleId(1), TreadleId(3)];
            treadling.0[1] = vec![];
        }
        let w = window(&d, 1, 2, 1).unwrap();
        assert_eq!(w[0].treadles, vec![1, 3]);
        assert!(w[0].action.starts_with("Press treadles 1 and 3 together: "));
        assert_eq!(
            w[1].action,
            "No treadle is pressed for this pick: no shafts rise."
        );
    }

    #[test]
    fn working_notes_follow_the_recorded_semantics_only() {
        let mut d = twill();
        assert!(window(&d, 1, 4, 1)
            .unwrap()
            .iter()
            .all(|p| p.notes.is_empty()));
        d.pick_roles = vec![PickRole::Pattern, PickRole::Tabby];
        d.weft_work.shuttles = vec![Some(ShuttleId(2)), Some(ShuttleId(2)), None, None];
        d.weft_work.shuttle_starts.insert(ShuttleId(2), Side::Right);
        d.weft_work.strands = vec![1, 2, 1, 1];
        let w = window(&d, 1, 2, 1).unwrap();
        assert_eq!(
            w[0].notes,
            vec![
                "A pattern pick.",
                "Shuttle 2, from the right (right to left)."
            ]
        );
        assert_eq!(
            w[1].notes,
            vec![
                "A tabby pick.",
                "Shuttle 2, from the left (left to right).",
                "2 strands together in this pass."
            ]
        );
    }

    #[test]
    fn a_shot_group_and_a_repeated_shed_are_told_apart() {
        let mut d = twill();
        if let Drive::Treadled { treadling, .. } = &mut d.drive {
            treadling.0 = vec![
                vec![TreadleId(1)],
                vec![TreadleId(1)],
                vec![TreadleId(2)],
                vec![TreadleId(2)],
            ];
        }
        d.weft_work.shot_groups = vec![ShotGroup { start: 0, picks: 2 }];
        let w = window(&d, 1, 4, 1).unwrap();
        assert_eq!(
            w[0].notes,
            vec!["Pass 1 of a double shot: 2 passes in this one shed."]
        );
        assert_eq!(
            w[1].notes,
            vec!["Pass 2 of a double shot: keep the same shed, do not change it."]
        );
        assert!(w[2].notes.is_empty());
        assert_eq!(w[3].notes, vec!["Same shed as the pick before."]);
    }

    #[test]
    fn the_window_carries_each_picks_prefix() {
        let d = twill();
        let w = window(&d, 2, 4, 1).unwrap();
        assert_eq!(w.iter().map(|p| p.pick).collect::<Vec<_>>(), vec![2, 3, 4]);
        for p in &w {
            assert_eq!(p.prefix, prefix(&d, p.pick - 1));
        }
        assert_ne!(w[0].prefix, w[1].prefix);
    }

    #[test]
    fn the_window_is_cut_to_the_draft_and_refuses_what_is_not_there() {
        let d = twill();
        assert_eq!(window(&d, 3, 1000, 1).unwrap().len(), 2);
        assert!(window(&d, 0, 2, 1).is_err());
        assert!(window(&d, 5, 6, 1).is_err());
        assert!(window(&d, 3, 2, 1).is_err());
        let mut empty = twill();
        empty.drive = Drive::Liftplan(Liftplan(vec![]));
        assert_eq!(window(&empty, 1, 10, 1).unwrap(), Vec::new());
    }

    #[test]
    fn a_long_list_is_cut_in_words() {
        let numbers: Vec<u16> = (1..=30).collect();
        assert_eq!(
            list("shaft", "shafts", &numbers),
            format!(
                "shafts {} and 6 more",
                (1..=24)
                    .map(|n| n.to_string())
                    .collect::<Vec<_>>()
                    .join(", ")
            )
        );
    }

    #[test]
    fn resuming_the_same_draft_needs_nothing() {
        let d = twill();
        let basis = Basis {
            units: 4,
            prefix: prefix(&d, 2),
        };
        let r = resume(&d, 3, Some(basis));
        assert_eq!(r.resume.status, ResumeStatus::Same);
        assert_eq!((r.pick, r.message), (3, None));
    }

    #[test]
    fn a_pick_inserted_before_the_place_is_shown_for_checking() {
        let d = twill();
        let basis = Basis {
            units: 4,
            prefix: prefix(&d, 2),
        };
        let mut edited = d.clone();
        if let Drive::Treadled { treadling, .. } = &mut edited.drive {
            treadling.0.insert(0, vec![TreadleId(4)]);
        }
        let r = resume(&edited, 3, Some(basis));
        assert_eq!(r.resume.status, ResumeStatus::Changed);
        assert_eq!(r.pick, 3, "never moved");
        assert_eq!(
            r.message.unwrap(),
            "The draft has changed at or before pick 3 since you saved your place. Check that \
             pick 3 is where you are."
        );
    }

    #[test]
    fn picks_added_after_the_place_are_said_but_change_nothing() {
        let d = twill();
        let basis = Basis {
            units: 4,
            prefix: prefix(&d, 1),
        };
        let mut longer = d.clone();
        if let Drive::Treadled { treadling, .. } = &mut longer.drive {
            treadling.0.push(vec![TreadleId(1)]);
        }
        let r = resume(&longer, 2, Some(basis));
        assert_eq!(r.resume.status, ResumeStatus::LengthChanged { was: 4 });
        assert_eq!(r.pick, 2);
        assert!(r.message.unwrap().contains("it now has 5 picks (it had 4)"));
    }

    #[test]
    fn picks_removed_under_the_place_clamp_it_and_say_so() {
        let d = twill();
        let basis = Basis {
            units: 4,
            prefix: prefix(&d, 3),
        };
        let mut shorter = d.clone();
        if let Drive::Treadled { treadling, .. } = &mut shorter.drive {
            treadling.0.truncate(2);
        }
        let r = resume(&shorter, 4, Some(basis));
        assert_eq!(r.resume.status, ResumeStatus::Clamped { was: 3 });
        assert_eq!(r.pick, 2);
        assert_eq!(
            r.message.unwrap(),
            "Your place was pick 4, but the draft now has 2 picks. It is shown at pick 2: check \
             where you are."
        );
    }

    #[test]
    fn a_shed_change_or_a_new_treadle_changes_the_fingerprint() {
        let d = twill();
        let mut sinking = d.clone();
        sinking.shed = ShedType::Sinking;
        assert_ne!(prefix(&d, 0), prefix(&sinking, 0));
        let lift = d.to_liftplan_draft();
        assert_ne!(
            prefix(&d, 0),
            prefix(&lift, 0),
            "pressing a treadle is not lifting"
        );
    }

    #[test]
    fn everything_the_weaver_is_told_is_in_the_fingerprint() {
        let d = twill();
        let base = prefix(&d, 3);
        let mut weft = d.clone();
        weft.colors.palette.push(Color::rgb(200, 0, 0));
        weft.colors.weft = vec![0, 0, 1, 0];
        assert_ne!(prefix(&weft, 3), base, "the weft colour");
        let mut shade = d.clone();
        shade.colors.palette[1] = Color::rgb(1, 2, 3);
        assert_ne!(prefix(&shade, 3), base, "the yarn of that colour");
        let mut role = d.clone();
        role.pick_roles = vec![PickRole::Unknown, PickRole::Tabby];
        assert_ne!(prefix(&role, 3), base, "the role");
        let mut shuttle = d.clone();
        shuttle.weft_work.shuttles = vec![None, Some(ShuttleId(2)), None, None];
        assert_ne!(prefix(&shuttle, 3), base, "the shuttle");
        let mut side = shuttle.clone();
        side.weft_work.shuttles = vec![Some(ShuttleId(2)); 4];
        let mut other = side.clone();
        side.weft_work
            .shuttle_starts
            .insert(ShuttleId(2), Side::Left);
        other
            .weft_work
            .shuttle_starts
            .insert(ShuttleId(2), Side::Right);
        assert_ne!(
            prefix(&side, 3),
            prefix(&other, 3),
            "the side it starts from"
        );
        let mut strands = d.clone();
        strands.weft_work.strands = vec![1, 1, 2, 1];
        assert_ne!(prefix(&strands, 3), base, "the strands");
        let mut shot = d.clone();
        if let Drive::Treadled { treadling, .. } = &mut shot.drive {
            treadling.0[1] = vec![TreadleId(1)];
        }
        let unshot = prefix(&shot, 3);
        shot.weft_work.shot_groups = vec![ShotGroup { start: 0, picks: 2 }];
        assert_ne!(prefix(&shot, 3), unshot, "a shot group");
        // What is after the place does not count.
        let mut later = d.clone();
        later.colors.palette.push(Color::rgb(200, 0, 0));
        later.colors.weft = vec![1, 1, 1, 2];
        assert_eq!(prefix(&later, 2), prefix(&d, 2));
    }

    /// The review probe: a plain-weave scarf in stripes of 10, the place at pick 50, and two red picks
    /// (one whole shed repeat) inserted at pick 11. The sheds up to the place are the same, but every
    /// stripe from there on is two picks off, so the place must be shown for checking.
    #[test]
    fn a_shed_repeat_inserted_before_the_place_is_caught() {
        let stripes = |picks: usize, red_at: Option<usize>| {
            let mut d = structure::plain_weave(8, picks);
            d.colors.palette = vec![Color::WHITE, Color::BLACK, Color::rgb(200, 0, 0)];
            d.colors.weft = (0..picks).map(|p| (p / 10) % 2).collect();
            if let Some(at) = red_at {
                d.colors.weft.insert(at, 2);
                d.colors.weft.insert(at, 2);
                d.colors.weft.truncate(picks);
            }
            d
        };
        let scarf = stripes(100, None);
        let basis = Basis {
            units: 100,
            prefix: prefix(&scarf, 49),
        };
        let mut edited = structure::plain_weave(8, 102);
        edited.colors = stripes(102, Some(10)).colors;
        assert_eq!(edited.picks(), 102);
        let r = resume(&edited, 50, Some(basis));
        assert_eq!(r.resume.status, ResumeStatus::Changed);
        assert_eq!(r.pick, 50, "never moved");
        assert!(r.message.unwrap().contains("changed at or before pick 50"));
    }

    #[test]
    fn a_shuttle_with_an_odd_number_of_passes_starts_from_the_other_side_every_second_time() {
        let mut d = structure::plain_weave(4, 5);
        d.weft_work.shuttles = vec![Some(ShuttleId(1)); 5];
        d.weft_work.shuttle_starts.insert(ShuttleId(1), Side::Left);
        let side = |time: usize, pick: usize| {
            window(&d, pick, pick, time).unwrap()[0]
                .notes
                .iter()
                .find(|n| n.starts_with("Shuttle"))
                .cloned()
                .unwrap()
        };
        assert_eq!(side(1, 1), "Shuttle 1, from the left (left to right).");
        assert_eq!(side(1, 5), "Shuttle 1, from the left (left to right).");
        assert_eq!(side(2, 1), "Shuttle 1, from the right (right to left).");
        assert_eq!(side(2, 5), "Shuttle 1, from the right (right to left).");
        assert_eq!(side(3, 1), "Shuttle 1, from the left (left to right).");
        // Four passes a time through: the same side every time.
        let mut even = structure::plain_weave(4, 4);
        even.weft_work.shuttles = vec![Some(ShuttleId(1)); 4];
        even.weft_work
            .shuttle_starts
            .insert(ShuttleId(1), Side::Left);
        let w = window(&even, 1, 1, 2).unwrap();
        assert!(w[0]
            .notes
            .contains(&"Shuttle 1, from the left (left to right).".to_string()));
        // A pick whose shuttle is unknown makes every later time unknown.
        let mut gap = d.clone();
        gap.weft_work.shuttles[3] = None;
        let w = window(&gap, 1, 1, 2).unwrap();
        assert!(
            w[0].notes.contains(&"Shuttle 1.".to_string()),
            "{:?}",
            w[0].notes
        );
    }

    #[test]
    fn pick_1_of_a_later_time_through_is_compared_with_the_last_pick() {
        let mut d = twill();
        if let Drive::Treadled { treadling, .. } = &mut d.drive {
            treadling.0 = vec![vec![TreadleId(1)], vec![TreadleId(2)], vec![TreadleId(1)]];
        }
        assert!(window(&d, 1, 1, 1).unwrap()[0].notes.is_empty());
        assert_eq!(
            window(&d, 1, 1, 2).unwrap()[0].notes,
            vec!["Same shed as the pick before."]
        );
        assert!(window(&d, 1, 1, 0).is_err(), "there is no time 0");
    }

    #[test]
    fn what_goes_down_is_every_shaft_not_up() {
        let mut d = twill();
        d.shed = ShedType::Sinking;
        d.shafts = 6;
        let w = window(&d, 1, 1, 1).unwrap();
        let up = raised_of(&d, 0);
        let down = lowered_of(&d, &up);
        assert_eq!(down.len() + up.len(), 6);
        assert!(down.iter().all(|s| !up.contains(s)));
        assert_eq!(
            w[0].action,
            format!(
                "Press treadle 1: {} go down, so {} are up.",
                list("shaft", "shafts", &down),
                list("shaft", "shafts", &up)
            )
        );
    }

    #[test]
    fn the_first_pick_asked_for_is_always_in_the_window() {
        let mut d = structure::plain_weave(4, 3);
        d.shafts = u16::MAX;
        d.shed = ShedType::Sinking;
        // On a sinking shed every pick has some 65,000 shafts up: the second pick passes the budget,
        // so the window stops after it.
        let w = window(&d, 1, 3, 1).unwrap();
        assert_eq!(w.iter().map(|p| p.pick).collect::<Vec<_>>(), vec![1, 2]);
        let w = window(&d, 3, 3, 1).unwrap();
        assert_eq!(w[0].pick, 3);
        assert!(w[0].action.contains(" more"), "the list is cut in words");
    }

    #[test]
    fn an_empty_draft_has_nothing_to_weave() {
        let mut d = twill();
        d.drive = Drive::Liftplan(Liftplan(vec![]));
        let r = resume(&d, 7, None);
        assert_eq!(r.resume.status, ResumeStatus::Empty);
        assert_eq!(r.pick, 1);
        assert_eq!(r.message.unwrap(), "This draft has no picks to weave.");
    }
}
