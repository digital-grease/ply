//! KNITTING SECTIONS (M9-01, first slice: flat short rows and held stitches): an OPTIONAL
//! construction layer above the chart, never a replacement for it. A pattern may name sections
//! ("Back", "Left shoulder"), each an ordered list of steps: work a range of the pattern's chart
//! rows, cast on, bind off, work across in a plain stitch, work a short row and turn, put stitches on
//! hold as a named group, return a group to the needle, or an unchecked written step in the
//! pattern's own words. A pattern with no sections is a chart-only pattern and behaves exactly as
//! before.
//!
//! # The stitch ledger
//!
//! [`ledger`] walks every step in order and keeps a precise count after each one: the stitches on
//! the needle, how many are still to work in the row in progress, how many wait past a short-row
//! turn, every group on hold, and how many have been bound off. Anything a step asks for that the
//! needle cannot give (binding off or holding more stitches than are left in the row, turning past
//! the end, returning a group that was never put on hold or was already returned, a chart row that
//! does not take the stitches waiting for it) is an issue in plain words, and the step is not
//! applied: a count never goes negative, and Ply never guesses a number the pattern did not give.
//!
//! **The needle.** Flat work only in this slice. The live stitches are numbered 1..=n in "piece
//! order": a row worked from the side that row 1 is worked from (the pattern's `first_row_side`)
//! travels toward n. The work's position is a boundary `c` (0..=n) between the stitches already on
//! the right needle and those still on the left needle, plus the direction of travel. Working `k`
//! stitches moves `c` by `k`; a turn flips the direction and leaves `c` where it is. That one rule
//! gives short rows their meaning: after "knit to last 6 sts, turn" the return row covers only the
//! stitches between the turn and the edge, and the six past the turn wait on the other needle until a
//! later row in the first direction reaches them again. A row ends, and the work turns, whenever
//! nothing is left on the left needle.
//!
//! **Short rows.** A short-row turn records the stitches past it as waiting, and, for wrap and turn,
//! a wrap on the first stitch past the turn; for a German short row, a double stitch made from the
//! last stitch worked (slipped at the start of the next row, so the next row's text begins "make a
//! double stitch"). An unspecified "turn" records neither. A later step that works across a wrap or
//! double stitch resolves it when it says so (`resolve_turns`); one that does not gets a warning. A
//! section that ends with stitches still waiting past a turn gets a warning (the next part of a sock
//! heel legitimately finishes them, so it is not an error).
//!
//! **Held stitches.** A hold takes the next stitches from the left needle (or all that are left in
//! the row) into a group named by the step; the group is referred to by the HOLD STEP'S ID, so a
//! rename never breaks the step that returns it. Returning a group puts its stitches on the left
//! needle (the next to be worked). Onto an empty needle, the step must say which side faces the
//! knitter; Ply reports when it does not. Holding stitches from the middle of a row leaves a gap
//! between the stitches either side; working straight across it joins the sides with a strand of
//! yarn (a warning), casting on over it or returning stitches into it closes it.
//!
//! **Limits.** At most [`MAX_LIVE_STITCHES`] on the needle and on hold (a step past it is "has too
//! many stitches to count"), [`MAX_STEPS`] steps and [`MAX_LINES`] lines (past them, one error and
//! the counting stops); [`check_limits`] is what a file must meet to open.
//!
//! **Unknown stays unknown.** An unchecked step that does not say how it changes the stitch count
//! makes every later count unknown (one warning); a chart row that cannot be counted does the same.
//! Patterns worked in the round are not counted in this slice (one warning).
//!
//! The written form ([`written`]) and validation ([`crate::validate`]) both read this one ledger.

use std::collections::HashMap;

use serde::{Deserialize, Serialize};

use crate::flow::chart_row_count;
use crate::instruction::{CountSource, ReadingCols, RowInstruction};
use crate::pattern::{Construction, KnitPattern, Side};
use crate::validate::Severity;

// --- limits ------------------------------------------------------------------------------------

/// The most stitches the ledger keeps on the needle and on hold together ([`crate::calc::MAX_STITCHES`],
/// far beyond any garment). A step that would go past it is refused ("has too many stitches to
/// count"), so every position stays far from the integer limits.
pub const MAX_LIVE_STITCHES: u64 = crate::calc::MAX_STITCHES as u64;

/// The most steps the ledger walks in one pattern. A garment's construction is a few hundred steps;
/// past this the ledger reports one "too long to count" error and counts nothing.
pub const MAX_STEPS: usize = 10_000;

/// The most ledger lines (one per step, one per chart row a step works). Past this the ledger
/// reports one "too long to count" error and stops, so a file cannot make every edit write
/// megabytes of text.
pub const MAX_LINES: usize = 20_000;

/// The most sections a pattern may have, and the longest a section's or step's id, name, notes or
/// text may be (in bytes), for a file to open ([`check_limits`]; the bridge applies it on load).
pub const MAX_SECTIONS: usize = 1_000;
pub const MAX_TEXT_BYTES: usize = 10_000;

/// Whether `pattern`'s sections are within the sizes a file may have: at most [`MAX_SECTIONS`]
/// sections and [`MAX_STEPS`] steps, every id, name, note and text at most [`MAX_TEXT_BYTES`], and
/// every unchecked step's stitch change within [`MAX_LIVE_STITCHES`] either way (a larger one could
/// never be applied). `Err` says, in plain words, which limit a file goes past.
pub fn check_limits(pattern: &KnitPattern) -> Result<(), String> {
    let sections = &pattern.sections;
    if sections.len() > MAX_SECTIONS {
        return Err(format!(
            "the pattern has {} sections; Ply opens at most {MAX_SECTIONS}",
            sections.len()
        ));
    }
    let steps: usize = sections.iter().map(|s| s.steps.len()).sum();
    if steps > MAX_STEPS {
        return Err(format!(
            "the pattern has {steps} section steps; Ply opens at most {MAX_STEPS}"
        ));
    }
    let long = |t: &str| t.len() > MAX_TEXT_BYTES;
    for s in sections {
        if long(&s.id) || long(&s.name) || long(&s.notes) {
            return Err(format!(
                "a section's id, name or notes is longer than {MAX_TEXT_BYTES} bytes"
            ));
        }
        for st in &s.steps {
            let too_long = long(&st.id)
                || match &st.action {
                    StepAction::Hold { name, .. } => long(name),
                    StepAction::Resume { hold, .. } => long(hold),
                    StepAction::Opaque { text, .. } => long(text),
                    _ => false,
                };
            if too_long {
                return Err(format!(
                    "a step's id or text is longer than {MAX_TEXT_BYTES} bytes"
                ));
            }
            if let StepAction::Opaque {
                stitch_change: Some(d),
                ..
            } = st.action
            {
                if d.unsigned_abs() > MAX_LIVE_STITCHES {
                    return Err(format!(
                        "an unchecked step changes the stitch count by {d}; Ply counts at most \
                         {MAX_LIVE_STITCHES} stitches"
                    ));
                }
            }
        }
    }
    Ok(())
}

// --- model (part of the `.plyknit` schema since version 4) -----------------------------------------

/// A named part of the pattern's construction ("Back", "Left shoulder"), with its steps in working
/// order. `id` is stable: it never changes when the section is renamed or moved.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Section {
    pub id: String,
    pub name: String,
    /// Free text printed under the section's heading (needles, yarn, a reminder).
    pub notes: String,
    pub steps: Vec<Step>,
}

/// One step of a section. `id` is stable and unique in the pattern; a step that returns held
/// stitches names the hold step by it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Step {
    pub id: String,
    pub action: StepAction,
}

/// The plain stitch a work step or short row is worked in.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum WorkStitch {
    Knit,
    Purl,
    /// Continue the stitch pattern as it is set ("work in pattern").
    InPattern,
}

/// How far a work step goes along the row.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum WorkTo {
    /// To the end of the row: everything left on the left needle. The work then turns.
    End,
    /// Until this many stitches are left on the left needle ("knit to last 3 sts").
    Last(u32),
    /// This many stitches ("knit 14 sts").
    Count(u32),
}

/// Where a short row turns.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum TurnAt {
    /// When this many stitches are left on the left needle ("knit to last 6 sts, turn").
    Last(u32),
    /// After working this many stitches ("knit 10 sts, turn").
    Count(u32),
}

/// How a short row turns.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum TurnMethod {
    /// Wrap the next stitch, then turn; the wrap is later worked together with its stitch.
    WrapAndTurn,
    /// Turn, then make a double stitch of the first stitch; it is later worked as one stitch.
    German,
    /// The pattern says "turn" and leaves the method to the knitter.
    Unspecified,
}

/// What a step does. Externally tagged in the file (`{"ShortRow": {...}}`). A kind this build does
/// not know makes the file unreadable rather than being dropped: a later version adds kinds behind a
/// schema version bump, which this build refuses before reading the document.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum StepAction {
    /// Work chart rows `first..=last` (1-based) of the pattern's chart, each over every stitch left
    /// to work in the row, turning after each.
    ChartRows { first: u32, last: u32 },
    /// Work across in a plain stitch, without a short-row turn.
    Work {
        stitch: WorkStitch,
        to: WorkTo,
        resolve_turns: bool,
    },
    /// Work across, then turn before the end of the row.
    ShortRow {
        stitch: WorkStitch,
        to: TurnAt,
        method: TurnMethod,
        resolve_turns: bool,
    },
    /// Cast on stitches: onto an empty needle, at the start of a row (onto the left needle, worked
    /// in that row), or in the middle of a row (onto the right needle).
    CastOn { count: u32 },
    /// Bind off the next `count` stitches, or every stitch left in the row when `None`.
    BindOff {
        count: Option<u32>,
        resolve_turns: bool,
    },
    /// Put the next `count` stitches (every stitch left in the row when `None`) on a holder as a
    /// group called `name`.
    Hold { count: Option<u32>, name: String },
    /// Return the group put on hold by the step with id `hold` to the left needle. `facing` is the
    /// side toward the knitter (required when the needle is empty).
    Resume { hold: String, facing: Option<Side> },
    /// A step in the pattern's own words that Ply does not check, with how it changes the number of
    /// stitches on the needle when the pattern says (`None`: not stated, so later counts are
    /// unknown). Ply assumes it does not move along the row or turn the work.
    Opaque {
        text: String,
        stitch_change: Option<i64>,
    },
}

// --- ledger output ---------------------------------------------------------------------------------

/// A group of stitches on hold, as the ledger counts it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HeldCount {
    /// The id of the step that put the group on hold.
    pub hold: String,
    /// The group's name as that step gives it.
    pub name: String,
    pub count: u64,
}

/// What the ledger knows after a step.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NeedleCount {
    /// Live stitches on the needle.
    pub on_needle: u64,
    /// Stitches still on the left needle in the row in progress (at the start of a row: every
    /// stitch the row can reach).
    pub to_work: u64,
    /// The work is part way through a row.
    pub mid_row: bool,
    /// Stitches on the needle not worked since a short-row turn left them.
    pub past_turns: u64,
    /// Wraps and double stitches on the needle not worked yet.
    pub pending_turns: u64,
    /// Every group on hold, in the order they were put there.
    pub held: Vec<HeldCount>,
    /// Stitches bound off so far, in the whole pattern.
    pub bound_off: u64,
    /// The side the row in progress (or the next row) is worked from, when known.
    pub side: Option<Side>,
}

impl NeedleCount {
    /// Stitches on hold in all groups.
    pub fn held_total(&self) -> u64 {
        self.held.iter().map(|h| h.count).sum()
    }

    /// The count as the written instructions give it, without brackets: `24 sts on the needle, 6
    /// waiting past a turn; 12 on hold; 6 bound off`.
    pub fn text(&self) -> String {
        let mut s = format!("{} on the needle", sts(self.on_needle));
        if self.mid_row && self.to_work > 0 {
            s.push_str(&format!(", {} still to work in this row", self.to_work));
        }
        if self.past_turns > 0 {
            s.push_str(&format!(", {} waiting past a turn", self.past_turns));
        }
        match self.held.as_slice() {
            [] => {}
            [one] => s.push_str(&format!("; {} on hold", one.count)),
            many => {
                let parts: Vec<String> = many
                    .iter()
                    .map(|h| format!("{} {}", display_name(&h.name), h.count))
                    .collect();
                s.push_str(&format!("; on hold: {}", parts.join(", ")));
            }
        }
        if self.bound_off > 0 {
            s.push_str(&format!("; {} bound off", self.bound_off));
        }
        s
    }
}

/// The ledger's count after one line.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LineCount {
    Counted(NeedleCount),
    /// Ply cannot know the count here (after an unchecked step with no stated change, an uncounted
    /// chart row, or in a pattern worked in the round).
    Unknown,
    /// The step asked for something impossible and was not applied (see its issue).
    NotCounted,
}

impl LineCount {
    pub fn counted(&self) -> Option<&NeedleCount> {
        match self {
            LineCount::Counted(c) => Some(c),
            _ => None,
        }
    }

    /// The count as the written instructions give it, without brackets.
    pub fn text(&self) -> String {
        match self {
            LineCount::Counted(c) => c.text(),
            LineCount::Unknown => "stitch count unknown".to_string(),
            LineCount::NotCounted => "not counted: see the problems".to_string(),
        }
    }
}

/// One line of the worked construction: a step, or one chart row of a chart-rows step.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LedgerLine {
    /// Index of the section in [`KnitPattern::sections`].
    pub section: usize,
    /// Index of the step in its section.
    pub step: usize,
    /// The chart row (0-based) this line works, for a chart-rows step.
    pub chart_row: Option<usize>,
    /// `Short row 2 (WS)`, `Next row (RS)`, `Row 5 (RS)`, `Not checked by Ply`, or none for a step
    /// in the middle of a row or between rows.
    pub label: Option<String>,
    /// The instruction in a knitter's words (lower case after a label, capitalized without one).
    pub text: String,
    /// An unchecked step in the pattern's own words.
    pub opaque: bool,
    pub count: LineCount,
}

impl LedgerLine {
    /// The line as written: `Short row 1 (RS): knit to last 6 sts, wrap and turn. (24 sts on the
    /// needle, 6 waiting past a turn)`.
    pub fn written(&self) -> String {
        let body = match &self.label {
            Some(label) => format!("{label}: {}", self.text),
            None => self.text.clone(),
        };
        format!("{body} ({})", self.count.text())
    }
}

/// A problem the ledger found. `section`/`step`/`chart_row` locate it (all `None` for the pattern as
/// a whole).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SectionIssue {
    pub severity: Severity,
    pub section: Option<usize>,
    pub step: Option<usize>,
    pub chart_row: Option<usize>,
    /// The problem without its location, for showing beside the step.
    pub text: String,
    /// The problem with its location (`Back, step 3: ...`), as validation reports it.
    pub message: String,
}

/// Every line of the worked construction, and every problem found.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Ledger {
    pub lines: Vec<LedgerLine>,
    pub issues: Vec<SectionIssue>,
    /// The construction is too long to count ([`MAX_STEPS`], [`MAX_LINES`]): the lines stop where
    /// the ledger stopped, and one error says so.
    pub stopped: bool,
}

/// A section's display name: its name, or `Section 2` when it has none.
pub fn section_title(pattern: &KnitPattern, section: usize) -> String {
    match pattern.sections.get(section).map(|s| s.name.trim()) {
        Some(name) if !name.is_empty() => name.to_string(),
        _ => format!("Section {}", section + 1),
    }
}

/// The heading line the written instructions give a section: `Section 1: Back`, or `Section 2`.
pub fn heading(pattern: &KnitPattern, section: usize) -> String {
    match pattern.sections.get(section).map(|s| s.name.trim()) {
        Some(name) if !name.is_empty() => format!("Section {}: {name}", section + 1),
        _ => format!("Section {}", section + 1),
    }
}

/// The written instructions of a pattern with sections (see [`crate::to_written`]).
pub fn written(pattern: &KnitPattern) -> Vec<String> {
    let ledger = ledger(pattern);
    let mut out = Vec::with_capacity(ledger.lines.len() + 2 * pattern.sections.len() + 1);
    if let Some(n) = pattern.cast_on {
        out.push(crate::written::cast_on_line(pattern.construction, n));
    }
    // Where the ledger stopped, when the construction is too long to count.
    let stop = ledger
        .stopped
        .then(|| ledger.lines.last().map_or(0, |l| l.section));
    for (si, section) in pattern.sections.iter().enumerate() {
        out.push(heading(pattern, si));
        if !section.notes.trim().is_empty() {
            out.push(format!("Notes: {}", section.notes.trim()));
        }
        let mut any = false;
        for line in ledger.lines.iter().filter(|l| l.section == si) {
            out.push(line.written());
            any = true;
        }
        if stop == Some(si) {
            out.push(
                "(Ply stopped here: the construction is too long to count. See the problems.)"
                    .to_string(),
            );
            break;
        }
        if !any {
            out.push("(This section has no steps yet.)".to_string());
        }
    }
    out
}

/// Walk every section's steps in order and keep the stitch ledger. Never panics: no more than
/// [`MAX_LIVE_STITCHES`] are ever on the needle and on hold, the rest is checked arithmetic, and a
/// construction past [`MAX_STEPS`] or [`MAX_LINES`] is one "too long to count" error.
pub fn ledger(pattern: &KnitPattern) -> Ledger {
    let mut walk = Walk::new(pattern);
    walk.run();
    Ledger {
        lines: walk.lines,
        issues: walk.issues,
        stopped: walk.stopped,
    }
}

// --- the needle --------------------------------------------------------------------------------

/// What a short-row turn leaves to resolve.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Pending {
    Wrap,
    Double,
}

/// A wrap or double stitch on the stitch at `pos` (1-based piece order).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Mark {
    pos: u64,
    kind: Pending,
}

/// A gap left by stitches put on hold from the middle of a row: between stitches `at` and `at + 1`.
#[derive(Debug, Clone, PartialEq, Eq)]
struct Gap {
    at: u64,
    name: String,
}

/// The live stitches and where the work is (see the module docs).
#[derive(Debug, Clone, PartialEq, Eq)]
struct Needle {
    n: u64,
    c: u64,
    /// The row in progress travels toward stitch n.
    up: bool,
    /// The side facing the knitter on a row that travels toward n, when known.
    up_side: Option<Side>,
    /// The yarn is at the boundary: something was worked in this row since the last turn.
    yarn_here: bool,
    /// No step has worked this row yet (the next one gets the row's label).
    row_start: bool,
    /// Stitches at the low and high edges not worked since a turn left them.
    lo: u64,
    hi: u64,
    marks: Vec<Mark>,
    gaps: Vec<Gap>,
    /// A fresh needle whose side is not known yet, so which way its first row travels is not known
    /// either; the first side Ply learns (from a chart row) sets both.
    unoriented: bool,
}

impl Needle {
    fn empty() -> Self {
        Needle::fresh(0, None)
    }

    fn fresh(n: u64, up_side: Option<Side>) -> Self {
        Needle {
            n,
            c: 0,
            up: true,
            up_side,
            yarn_here: false,
            row_start: true,
            lo: 0,
            hi: 0,
            marks: Vec::new(),
            gaps: Vec::new(),
            unoriented: false,
        }
    }

    /// A fresh needle of `n` stitches in piece order (stitches held from an earlier needle keep
    /// their order), with `facing` toward the knitter. A row from the pattern's `first` side travels
    /// toward stitch n, so the other side's first row starts at stitch n. Not stated: unknown, and
    /// oriented when the side is learned.
    fn facing(n: u64, facing: Option<Side>, first: Side) -> Self {
        let mut needle = Needle::fresh(n, Some(first));
        match facing {
            Some(f) if f != first => {
                needle.up = false;
                needle.c = n;
            }
            Some(_) => {}
            None => {
                needle.up_side = None;
                needle.unoriented = true;
            }
        }
        needle
    }

    /// Stitches still on the left needle in this row.
    fn lh(&self) -> u64 {
        if self.up {
            self.n - self.c
        } else {
            self.c
        }
    }

    /// Stitches on the right needle.
    fn rh(&self) -> u64 {
        self.n - self.lh()
    }

    fn side(&self) -> Option<Side> {
        self.up_side.map(|s| if self.up { s } else { s.other() })
    }

    /// Make `side` the side of the row in progress (`first`: the pattern's first-row side). On a
    /// fresh needle whose side was not known, nothing is worked yet, so the row is turned the way the
    /// piece order says: a `first`-side row travels toward stitch n.
    fn set_side(&mut self, side: Side, first: Side) {
        if self.unoriented && self.row_start && self.up && self.c == 0 {
            self.up = side == first;
            self.c = if self.up { 0 } else { self.n };
            self.up_side = Some(first);
        } else {
            self.up_side = Some(if self.up { side } else { side.other() });
        }
        self.unoriented = false;
    }

    /// The work is at the start edge of the needle (not at a short-row turn).
    fn at_edge(&self) -> bool {
        if self.up {
            self.c == 0
        } else {
            self.c == self.n
        }
    }

    /// Work `k` stitches (`k <= lh`): the wraps and double stitches and the gaps it works across.
    fn traverse(&mut self, k: u64) -> (Vec<Mark>, Vec<Gap>) {
        let (lo_pos, hi_pos) = if self.up {
            (self.c + 1, self.c + k)
        } else {
            (self.c + 1 - k, self.c)
        };
        let crossed_marks = take(&mut self.marks, |m| m.pos >= lo_pos && m.pos <= hi_pos);
        let (c, yarn) = (self.c, self.yarn_here);
        let up = self.up;
        let crossed_gaps = take(&mut self.gaps, |g| {
            let inside = if up {
                g.at > c && g.at < c + k
            } else {
                g.at + k > c && g.at < c
            };
            inside || (g.at == c && yarn && k > 0)
        });
        if self.up {
            self.c += k;
            self.hi = self.hi.min(self.n - self.c);
        } else {
            self.c -= k;
            self.lo = self.lo.min(self.c);
        }
        if k > 0 {
            self.yarn_here = true;
            self.unoriented = false;
        }
        (crossed_marks, crossed_gaps)
    }

    /// Take the next `k` stitches off the left needle (`k <= lh`). Returns the wraps and double
    /// stitches they carry, with their 1-based offsets in the removed run.
    fn remove_ahead(&mut self, k: u64) -> Vec<(u64, Mark)> {
        let start = if self.up { self.c + 1 } else { self.c + 1 - k };
        let end = start + k - 1;
        let taken: Vec<(u64, Mark)> = take(&mut self.marks, |m| m.pos >= start && m.pos <= end)
            .into_iter()
            .map(|m| (m.pos - start + 1, m))
            .collect();
        for m in &mut self.marks {
            if m.pos > end {
                m.pos -= k;
            }
        }
        self.gaps.retain(|g| !(g.at >= start && g.at < end));
        for g in &mut self.gaps {
            if g.at >= end {
                g.at -= k;
            }
        }
        if self.up {
            let overlap = end.saturating_sub(self.n - self.hi);
            self.hi -= overlap.min(self.hi);
        } else {
            let overlap = self.lo.saturating_sub(start - 1);
            self.lo -= overlap.min(self.lo);
            self.c -= k;
        }
        self.n -= k;
        self.tidy();
        taken
    }

    /// Insert `k` new stitches at the boundary: ahead (on the left needle, worked next) or behind
    /// (on the right needle). `marks` are offsets in the inserted run. Returns a gap it closed.
    fn insert(&mut self, k: u64, ahead: bool, marks: &[(u64, Mark)]) -> Option<Gap> {
        let c = self.c;
        for m in &mut self.marks {
            if m.pos > c {
                m.pos += k;
            }
        }
        let closed = take(&mut self.gaps, |g| g.at == c).into_iter().next();
        for g in &mut self.gaps {
            if g.at > c {
                g.at += k;
            }
        }
        for (offset, m) in marks {
            self.marks.push(Mark {
                pos: c + offset,
                kind: m.kind,
            });
        }
        self.n += k;
        // Ahead on a row toward n, or behind on a row toward 1, the boundary stays below the new
        // stitches; otherwise it moves above them.
        if ahead != self.up {
            self.c += k;
        }
        closed
    }

    /// Take `k` stitches off the right needle (`k <= rh`), nearest the boundary first.
    fn remove_behind(&mut self, k: u64) {
        let start = if self.up { self.c + 1 - k } else { self.c + 1 };
        let end = start + k - 1;
        self.marks.retain(|m| !(m.pos >= start && m.pos <= end));
        for m in &mut self.marks {
            if m.pos > end {
                m.pos -= k;
            }
        }
        self.gaps.retain(|g| !(g.at >= start && g.at < end));
        for g in &mut self.gaps {
            if g.at >= end {
                g.at -= k;
            }
        }
        if self.up {
            let overlap = self.lo.saturating_sub(start - 1);
            self.lo -= overlap.min(self.lo);
            self.c -= k;
        } else {
            let overlap = end.saturating_sub(self.n - self.hi);
            self.hi -= overlap.min(self.hi);
        }
        self.n -= k;
        self.tidy();
    }

    /// Turn the work where it is: everything past the boundary is left unworked.
    fn turn(&mut self) {
        if self.up {
            self.hi = self.n - self.c;
        } else {
            self.lo = self.c;
        }
        self.up = !self.up;
        self.yarn_here = false;
        self.row_start = true;
        self.unoriented = false;
    }

    /// After a step: an empty needle has no position; a row with nothing left on the left needle
    /// has ended, and the work turns.
    fn settle(&mut self) {
        if self.n == 0 {
            *self = Needle::empty();
        } else if self.lh() == 0 {
            self.turn();
        }
    }

    /// Drop gaps that are no longer between two stitches, and duplicates.
    fn tidy(&mut self) {
        let n = self.n;
        self.gaps.retain(|g| g.at > 0 && g.at < n);
        let mut seen = Vec::new();
        self.gaps.retain(|g| {
            if seen.contains(&g.at) {
                false
            } else {
                seen.push(g.at);
                true
            }
        });
    }
}

/// Remove and return every element matching `pred`.
fn take<T>(items: &mut Vec<T>, mut pred: impl FnMut(&T) -> bool) -> Vec<T> {
    let mut taken = Vec::new();
    let mut kept = Vec::with_capacity(items.len());
    for item in items.drain(..) {
        if pred(&item) {
            taken.push(item);
        } else {
            kept.push(item);
        }
    }
    *items = kept;
    taken
}

// --- the walk ----------------------------------------------------------------------------------

/// A group of stitches put on hold.
#[derive(Debug, Clone)]
struct Group {
    hold: String,
    name: String,
    /// `None` when held while the count was unknown.
    count: Option<u64>,
    marks: Vec<(u64, Mark)>,
    resumed: Option<(usize, usize)>,
}

struct Walk<'a> {
    p: &'a KnitPattern,
    /// `None`: the count is unknown (sticky) or not kept (in the round).
    needle: Option<Needle>,
    bound_off: u64,
    groups: Vec<Group>,
    /// Hold steps that were processed but could not put anything on hold.
    failed_holds: Vec<String>,
    lines: Vec<LedgerLine>,
    issues: Vec<SectionIssue>,
    by_id: HashMap<&'a str, (usize, usize)>,
    used_rows: Vec<bool>,
    short_no: u32,
    /// The line of a German short-row turn whose double stitch is still to be mentioned.
    make_ds: Option<usize>,
    /// That turn line, for the step being walked: the step mentions the double stitch when it starts
    /// working the next row; otherwise the turn line does, after the step.
    ds_now: Option<usize>,
    /// The construction is too long to count: nothing more is walked.
    stopped: bool,
    colors: Option<HashMap<usize, String>>,
}

impl<'a> Walk<'a> {
    fn new(p: &'a KnitPattern) -> Self {
        Walk {
            p,
            needle: None,
            bound_off: 0,
            groups: Vec::new(),
            failed_holds: Vec::new(),
            lines: Vec::new(),
            issues: Vec::new(),
            by_id: HashMap::new(),
            used_rows: vec![false; p.chart.rows.len()],
            short_no: 0,
            make_ds: None,
            ds_now: None,
            stopped: false,
            colors: crate::written::color_labels(p),
        }
    }

    fn run(&mut self) {
        let p = self.p;
        if p.sections.is_empty() {
            return;
        }
        let steps: usize = p.sections.iter().map(|s| s.steps.len()).sum();
        if steps > MAX_STEPS {
            self.stopped = true;
            self.error(
                None,
                None,
                None,
                format!(
                    "this construction is too long for Ply to count: it has {steps} steps, and Ply \
                     counts at most {MAX_STEPS}"
                ),
            );
            return;
        }
        self.index_ids();
        self.needle = match p.construction {
            Construction::Flat => match p.cast_on {
                Some(n) if u64::from(n) > MAX_LIVE_STITCHES => {
                    self.error(
                        None,
                        None,
                        None,
                        format!(
                            "the cast-on of {n} stitches is more than Ply can count \
                             ({MAX_LIVE_STITCHES}), so the sections are not counted"
                        ),
                    );
                    None
                }
                Some(n) if n > 0 => Some(Needle::fresh(u64::from(n), Some(p.first_row_side))),
                _ => Some(Needle::empty()),
            },
            Construction::InTheRound => {
                self.warn(
                    None,
                    None,
                    None,
                    "sections are counted only for flat knitting so far; this pattern is worked in \
                     the round, so Ply does not count its sections"
                        .into(),
                );
                None
            }
        };
        for (si, section) in p.sections.iter().enumerate() {
            self.short_no = 0;
            self.make_ds = None;
            for (ti, step) in section.steps.iter().enumerate() {
                self.step(si, ti, step);
                if self.stopped {
                    return;
                }
            }
            self.end_section(si);
        }
        self.end_pattern();
    }

    /// Room for `lines` more ledger lines; when there is none, one error and the walk stops.
    fn room(&mut self, lines: usize) -> bool {
        if self.lines.len().saturating_add(lines) <= MAX_LINES {
            return true;
        }
        self.stopped = true;
        self.error(
            None,
            None,
            None,
            format!(
                "this construction is too long for Ply to count: it would need more than \
                 {MAX_LINES} lines (one per step, one per chart row a step works), so the counts \
                 stop here"
            ),
        );
        false
    }

    /// Stitches on hold in every group still there (a group held while the count was unknown has
    /// no count; the needle is unknown then too).
    fn held_total(&self) -> u64 {
        self.groups
            .iter()
            .filter(|g| g.resumed.is_none())
            .filter_map(|g| g.count)
            .sum()
    }

    /// Whether adding `k` stitches to the needle would put more than [`MAX_LIVE_STITCHES`] on the
    /// needle and on hold.
    fn too_big(&self, k: u64) -> bool {
        let n = self.needle.as_ref().map_or(0, |n| n.n);
        n.saturating_add(self.held_total()).saturating_add(k) > MAX_LIVE_STITCHES
    }

    /// Ids must be unique and present: a returned group names its hold step by id.
    fn index_ids(&mut self) {
        let p = self.p;
        let mut section_ids: Vec<&str> = Vec::new();
        for (si, section) in p.sections.iter().enumerate() {
            if section.id.trim().is_empty() {
                self.error(Some(si), None, None, "the section has no id".into());
            } else if section_ids.contains(&section.id.as_str()) {
                self.error(
                    Some(si),
                    None,
                    None,
                    format!("another section already has the id '{}'", section.id),
                );
            } else {
                section_ids.push(&section.id);
            }
            for (ti, step) in section.steps.iter().enumerate() {
                if step.id.trim().is_empty() {
                    self.error(Some(si), Some(ti), None, "the step has no id".into());
                } else if let Some(&(s0, t0)) = self.by_id.get(step.id.as_str()) {
                    let other = self.place(s0, Some(t0), None);
                    self.error(
                        Some(si),
                        Some(ti),
                        None,
                        format!(
                            "{other} has the same id ('{}'), so a step that returns held stitches \
                             could name the wrong one",
                            step.id
                        ),
                    );
                } else {
                    self.by_id.insert(&step.id, (si, ti));
                }
            }
        }
    }

    // --- issues and lines ---

    fn place(&self, si: usize, ti: Option<usize>, row: Option<usize>) -> String {
        let mut s = section_title(self.p, si);
        if let Some(t) = ti {
            s.push_str(&format!(", step {}", t + 1));
        }
        if let Some(r) = row {
            s.push_str(&format!(", chart row {}", r + 1));
        }
        s
    }

    fn issue(
        &mut self,
        severity: Severity,
        si: Option<usize>,
        ti: Option<usize>,
        row: Option<usize>,
        text: String,
    ) {
        let message = match si {
            Some(si) => format!("{}: {text}", self.place(si, ti, row)),
            None => text.clone(),
        };
        self.issues.push(SectionIssue {
            severity,
            section: si,
            step: ti,
            chart_row: row,
            text,
            message,
        });
    }

    fn error(&mut self, si: Option<usize>, ti: Option<usize>, row: Option<usize>, text: String) {
        self.issue(Severity::Error, si, ti, row, text);
    }

    fn warn(&mut self, si: Option<usize>, ti: Option<usize>, row: Option<usize>, text: String) {
        self.issue(Severity::Warning, si, ti, row, text);
    }

    /// The ledger's count now.
    fn snapshot(&self) -> LineCount {
        let Some(needle) = &self.needle else {
            return LineCount::Unknown;
        };
        let held = self
            .groups
            .iter()
            .filter(|g| g.resumed.is_none())
            .map(|g| HeldCount {
                hold: g.hold.clone(),
                name: g.name.clone(),
                count: g.count.unwrap_or(0),
            })
            .collect();
        LineCount::Counted(NeedleCount {
            on_needle: needle.n,
            to_work: needle.lh(),
            mid_row: !needle.row_start && needle.n > 0,
            past_turns: needle.lo + needle.hi,
            pending_turns: needle.marks.len() as u64,
            held,
            bound_off: self.bound_off,
            side: needle.side(),
        })
    }

    /// Add a line. `text` is lower case; it is capitalized when there is no label. `sentence` adds
    /// the closing full stop (chart rows and unchecked steps keep their own text).
    #[allow(clippy::too_many_arguments)]
    fn push_line(
        &mut self,
        si: usize,
        ti: usize,
        row: Option<usize>,
        label: Option<String>,
        text: String,
        sentence: bool,
        opaque: bool,
        count: LineCount,
    ) -> usize {
        let mut text = if label.is_none() {
            capitalize(&text)
        } else {
            text
        };
        if sentence {
            text.push('.');
        }
        self.lines.push(LedgerLine {
            section: si,
            step: ti,
            chart_row: row,
            label,
            text,
            opaque,
            count,
        });
        self.lines.len() - 1
    }

    /// A step that could not be applied: an error, and a line that says it was not counted.
    fn refuse(&mut self, si: usize, ti: usize, text: String, problem: String) {
        self.error(Some(si), Some(ti), None, problem);
        self.push_line(si, ti, None, None, text, true, false, LineCount::NotCounted);
    }

    /// The row label for a step that starts working a row, taking it: `Short row 2 (WS)` for a row
    /// that starts at a turn or is itself a short row, `Next row (RS)` otherwise. `None` when the
    /// row is already started or the count is unknown.
    fn take_label(&mut self, short_row: bool) -> Option<String> {
        let needle = self.needle.as_mut()?;
        if !needle.row_start {
            return None;
        }
        needle.row_start = false;
        let side = match needle.side() {
            Some(Side::Rs) => " (RS)",
            Some(Side::Ws) => " (WS)",
            None => "",
        };
        if short_row || !needle.at_edge() {
            self.short_no += 1;
            Some(format!("Short row {}{side}", self.short_no))
        } else {
            self.short_no = 0;
            Some(format!("Next row{side}"))
        }
    }

    /// The first step of a row after a German short-row turn starts by making the double stitch,
    /// when it is the step right after the turn.
    fn with_double_stitch(&mut self, text: String) -> String {
        if self.ds_now.take().is_some() {
            format!("make a double stitch, {text}")
        } else {
            text
        }
    }

    /// Say on a German turn line that the double stitch is made right after turning.
    fn ds_on_turn_line(&mut self, line: usize) {
        let text = &mut self.lines[line].text;
        let at = text.len() - 1; // before the full stop
        text.insert_str(at, ", then make a double stitch");
    }

    /// Wording and warnings for the wraps, double stitches and gaps a step worked across.
    #[allow(clippy::too_many_arguments)]
    fn crossings(
        &mut self,
        si: usize,
        ti: usize,
        row: Option<usize>,
        mut text: String,
        marks: &[Mark],
        gaps: &[Gap],
        resolve: bool,
        can_resolve: bool,
    ) -> String {
        let wraps = marks.iter().filter(|m| m.kind == Pending::Wrap).count();
        let doubles = marks.iter().filter(|m| m.kind == Pending::Double).count();
        if resolve {
            match (wraps > 0, doubles > 0) {
                (true, true) => text.push_str(
                    ", working each wrap together with its stitch and each double stitch as one \
                     stitch",
                ),
                (true, false) => text.push_str(", working each wrap together with its stitch"),
                (false, true) => text.push_str(", working each double stitch as one stitch"),
                (false, false) => self.warn(
                    Some(si),
                    Some(ti),
                    row,
                    "says to work the wraps or double stitches from the short rows, but it works \
                     past none"
                        .into(),
                ),
            }
        } else {
            let how = if can_resolve {
                "; say to work them in this step"
            } else {
                "; work across them with a knit, purl or bind-off step that says to work them"
            };
            if wraps > 0 {
                self.warn(
                    Some(si),
                    Some(ti),
                    row,
                    format!(
                        "works past {} without working {} together with {}{how}",
                        count_of(wraps as u64, "wrapped stitch", "wrapped stitches"),
                        if wraps == 1 { "the wrap" } else { "the wraps" },
                        if wraps == 1 {
                            "its stitch"
                        } else {
                            "their stitches"
                        }
                    ),
                );
            }
            if doubles > 0 {
                self.warn(
                    Some(si),
                    Some(ti),
                    row,
                    format!(
                        "works past {} without saying to work {} as one stitch{how}",
                        count_of(doubles as u64, "double stitch", "double stitches"),
                        if doubles == 1 { "it" } else { "each" }
                    ),
                );
            }
        }
        for gap in gaps {
            self.warn(
                Some(si),
                Some(ti),
                row,
                format!(
                    "works across the gap left by the stitches put on hold ({}), which joins the \
                     two sides with a strand of yarn; cast on over the gap, or put one side on \
                     hold to work the sides separately",
                    display_name(&gap.name)
                ),
            );
        }
        text
    }

    // --- steps ---

    fn step(&mut self, si: usize, ti: usize, step: &'a Step) {
        let lines = match step.action {
            StepAction::ChartRows { first, last } if last >= first => (last - first) as usize + 1,
            _ => 1,
        };
        if !self.room(lines) {
            return;
        }
        // A pending double stitch is this step's to mention, or the turn line's.
        self.ds_now = self.make_ds.take();
        self.dispatch(si, ti, step);
        if let Some(line) = self.ds_now.take() {
            self.ds_on_turn_line(line);
        }
    }

    fn dispatch(&mut self, si: usize, ti: usize, step: &'a Step) {
        match &step.action {
            StepAction::ChartRows { first, last } => self.chart_rows(si, ti, *first, *last),
            StepAction::Work {
                stitch,
                to,
                resolve_turns,
            } => self.work(si, ti, *stitch, *to, *resolve_turns),
            StepAction::ShortRow {
                stitch,
                to,
                method,
                resolve_turns,
            } => self.short_row(si, ti, *stitch, *to, *method, *resolve_turns),
            StepAction::CastOn { count } => self.cast_on(si, ti, *count),
            StepAction::BindOff {
                count,
                resolve_turns,
            } => self.bind_off(si, ti, *count, *resolve_turns),
            StepAction::Hold { count, name } => self.hold(si, ti, step, *count, name),
            StepAction::Resume { hold, facing } => self.resume(si, ti, hold, *facing),
            StepAction::Opaque {
                text,
                stitch_change,
            } => self.opaque(si, ti, text, *stitch_change),
        }
    }

    /// A line for a step while the count is unknown.
    fn unknown_line(&mut self, si: usize, ti: usize, text: String) {
        self.push_line(si, ti, None, None, text, true, false, LineCount::Unknown);
    }

    /// The stitches a work or short-row step works, or the problem that stops it.
    fn reach(lh: u64, to: WorkTo) -> Result<u64, String> {
        match to {
            WorkTo::End => Ok(lh),
            WorkTo::Last(m) => {
                let m = u64::from(m);
                if m > lh {
                    Err(format!(
                        "works to the last {}, but {}",
                        stitches(m),
                        only_left(lh)
                    ))
                } else if m == lh {
                    Err(format!(
                        "works no stitches: the last {} are all that is left to work in this row",
                        stitches(m)
                    ))
                } else {
                    Ok(lh - m)
                }
            }
            WorkTo::Count(0) => Err("works 0 stitches".into()),
            WorkTo::Count(m) => {
                let m = u64::from(m);
                if m > lh {
                    Err(format!("works {}, but {}", stitches(m), only_left(lh)))
                } else {
                    Ok(m)
                }
            }
        }
    }

    fn work(&mut self, si: usize, ti: usize, stitch: WorkStitch, to: WorkTo, resolve: bool) {
        let base = work_text(stitch, to);
        let Some(needle) = &self.needle else {
            return self.unknown_line(si, ti, base);
        };
        if needle.n == 0 {
            return self.refuse(si, ti, base, no_stitches());
        }
        let k = match Self::reach(needle.lh(), to) {
            Ok(k) => k,
            Err(problem) => return self.refuse(si, ti, base, problem),
        };
        let label = self.take_label(false);
        let base = if label.is_some() {
            self.with_double_stitch(base)
        } else {
            base
        };
        let needle = self.needle.as_mut().expect("counting");
        let (marks, gaps) = needle.traverse(k);
        let text = self.crossings(si, ti, None, base, &marks, &gaps, resolve, true);
        self.needle.as_mut().expect("counting").settle();
        let count = self.snapshot();
        self.push_line(si, ti, None, label, text, true, false, count);
    }

    fn short_row(
        &mut self,
        si: usize,
        ti: usize,
        stitch: WorkStitch,
        to: TurnAt,
        method: TurnMethod,
        resolve: bool,
    ) {
        let reach = match to {
            TurnAt::Last(m) => WorkTo::Last(m),
            TurnAt::Count(m) => WorkTo::Count(m),
        };
        let work_part = work_text(stitch, reach);
        let turn_part = match method {
            TurnMethod::WrapAndTurn => ", wrap and turn",
            TurnMethod::German | TurnMethod::Unspecified => ", turn",
        };
        let base = format!("{work_part}{turn_part}");
        let Some(needle) = &self.needle else {
            return self.unknown_line(si, ti, base);
        };
        if needle.n == 0 {
            return self.refuse(si, ti, base, no_stitches());
        }
        let lh = needle.lh();
        let nothing_past = match to {
            TurnAt::Last(m) => m == 0,
            TurnAt::Count(m) => u64::from(m) == lh,
        };
        if nothing_past {
            return self.refuse(
                si,
                ti,
                base,
                "turns with no stitches left past the turn; to work every stitch left in the row, \
                 use a plain work step instead"
                    .into(),
            );
        }
        let k = match Self::reach(lh, reach) {
            Ok(k) => k,
            Err(problem) => {
                let problem = match to {
                    TurnAt::Last(m) if u64::from(m) == lh => format!(
                        "turns before working any stitches: the last {} are all that is left to \
                         work in this row",
                        stitches(lh)
                    ),
                    TurnAt::Count(0) => "turns before working any stitches".to_string(),
                    _ => problem,
                };
                return self.refuse(si, ti, base, problem);
            }
        };
        if method == TurnMethod::German && needle.rh() + k < 2 {
            // After the turn the next row works the stitches on the right needle now, and its first
            // one becomes the double stitch: with only one, that row would have nothing to work.
            return self.refuse(
                si,
                ti,
                base,
                "turns too soon for a German short row: the next row would have only the double \
                 stitch to work; work at least 2 stitches before this turn, or use another method"
                    .into(),
            );
        }
        let label = self.take_label(true);
        let work_part = if label.is_some() {
            self.with_double_stitch(work_part)
        } else {
            work_part
        };
        let needle = self.needle.as_mut().expect("counting");
        let (marks, gaps) = needle.traverse(k);
        // Any resolving phrase belongs to the stitches worked, before the turn.
        let mut text = self.crossings(si, ti, None, work_part, &marks, &gaps, resolve, true);
        text.push_str(turn_part);
        let needle = self.needle.as_mut().expect("counting");
        match method {
            TurnMethod::WrapAndTurn => {
                let pos = if needle.up { needle.c + 1 } else { needle.c };
                needle.marks.push(Mark {
                    pos,
                    kind: Pending::Wrap,
                });
            }
            TurnMethod::German => {
                let pos = if needle.up { needle.c } else { needle.c + 1 };
                needle.marks.push(Mark {
                    pos,
                    kind: Pending::Double,
                });
            }
            TurnMethod::Unspecified => {}
        }
        needle.turn();
        if method == TurnMethod::German {
            // Slip the double stitch: the first stitch of the next row (k >= 1, so it exists).
            if needle.up {
                needle.c += 1;
            } else {
                needle.c -= 1;
            }
            needle.yarn_here = true;
            needle.settle();
        }
        let count = self.snapshot();
        let line = self.push_line(si, ti, None, label, text, true, false, count);
        if method == TurnMethod::German {
            self.make_ds = Some(line);
        }
    }

    fn cast_on(&mut self, si: usize, ti: usize, count: u32) {
        let k = u64::from(count);
        if self.needle.is_none() {
            return self.unknown_line(si, ti, format!("cast on {}", sts(k)));
        }
        if k == 0 {
            return self.refuse(
                si,
                ti,
                "cast on 0 sts".into(),
                "casts on 0 stitches; cast on at least 1".into(),
            );
        }
        if self.too_big(k) {
            return self.refuse(si, ti, format!("cast on {}", sts(k)), too_many());
        }
        let needle = self.needle.as_ref().expect("counting");
        let text = if needle.n == 0 {
            // A new piece: its first row is worked from the side the pattern's first row is.
            self.needle = Some(Needle::fresh(k, Some(self.p.first_row_side)));
            format!("cast on {}", sts(k))
        } else if needle.row_start {
            self.needle.as_mut().expect("counting").insert(k, true, &[]);
            format!("cast on {} at the start of the row", sts(k))
        } else {
            let closed = self
                .needle
                .as_mut()
                .expect("counting")
                .insert(k, false, &[]);
            match closed {
                Some(gap) => format!(
                    "cast on {} onto the right needle, over the gap left by the stitches on hold \
                     ({})",
                    sts(k),
                    display_name(&gap.name)
                ),
                None => format!("cast on {} onto the right needle", sts(k)),
            }
        };
        self.needle.as_mut().expect("counting").settle();
        let count = self.snapshot();
        self.push_line(si, ti, None, None, text, true, false, count);
    }

    fn bind_off(&mut self, si: usize, ti: usize, count: Option<u32>, resolve: bool) {
        let asked = match count {
            Some(c) => format!("bind off {}", sts(u64::from(c))),
            None => "bind off to end".to_string(),
        };
        let Some(needle) = &self.needle else {
            return self.unknown_line(si, ti, asked);
        };
        if needle.n == 0 {
            return self.refuse(si, ti, asked, no_stitches());
        }
        let lh = needle.lh();
        let k = count.map(u64::from).unwrap_or(lh);
        if k == 0 {
            return self.refuse(
                si,
                ti,
                asked,
                "binds off 0 stitches; bind off at least 1".into(),
            );
        }
        if k > lh {
            return self.refuse(
                si,
                ti,
                asked,
                format!("binds off {}, but {}", stitches(k), only_left(lh)),
            );
        }
        let Some(total) = self.bound_off.checked_add(k) else {
            return self.refuse(si, ti, asked, too_many());
        };
        let whole = count.is_none() && needle.rh() == 0;
        let label = self.take_label(false);
        let needle = self.needle.as_mut().expect("counting");
        let mut marks: Vec<Mark> = needle.remove_ahead(k).into_iter().map(|(_, m)| m).collect();
        let mut gaps = Vec::new();
        let remains = needle.lh() > 0;
        if remains {
            // The last stitch of the bind-off stays on the right needle.
            let (m, g) = needle.traverse(1);
            marks.extend(m);
            gaps = g;
        } else {
            needle.yarn_here = true;
        }
        let emptied = needle.n == 0;
        self.bound_off = total;
        let base = if whole && emptied {
            "bind off all sts".to_string()
        } else {
            asked
        };
        let base = if label.is_some() {
            self.with_double_stitch(base)
        } else {
            base
        };
        let mut text = self.crossings(si, ti, None, base, &marks, &gaps, resolve, true);
        if remains {
            text.push_str("; 1 st remains on the right needle");
        }
        self.needle.as_mut().expect("counting").settle();
        let line_count = self.snapshot();
        self.push_line(si, ti, None, label, text, true, false, line_count);
    }

    fn hold(&mut self, si: usize, ti: usize, step: &Step, count: Option<u32>, name: &str) {
        let shown = match name.trim() {
            "" => String::new(),
            n => format!(" ({n})"),
        };
        let fallback = match count {
            Some(c) => format!("place the next {} on a holder{shown}", sts(u64::from(c))),
            None => format!("place the remaining sts on a holder{shown}"),
        };
        let name_taken = self.groups.iter().any(|g| {
            g.resumed.is_none()
                && !name.trim().is_empty()
                && g.name.trim().eq_ignore_ascii_case(name.trim())
        });
        let Some(needle) = &self.needle else {
            self.groups.push(Group {
                hold: step.id.clone(),
                name: name.to_string(),
                count: count.map(u64::from),
                marks: Vec::new(),
                resumed: None,
            });
            return self.unknown_line(si, ti, fallback);
        };
        if needle.n == 0 {
            self.failed_holds.push(step.id.clone());
            return self.refuse(si, ti, fallback, no_stitches());
        }
        let lh = needle.lh();
        let k = count.map(u64::from).unwrap_or(lh);
        if k == 0 {
            self.failed_holds.push(step.id.clone());
            return self.refuse(
                si,
                ti,
                fallback,
                "puts 0 stitches on hold; put at least 1 on hold".into(),
            );
        }
        if k > lh {
            self.failed_holds.push(step.id.clone());
            return self.refuse(
                si,
                ti,
                fallback,
                format!("puts {} on hold, but {}", stitches(k), only_left(lh)),
            );
        }
        let all = count.is_none() && needle.rh() == 0;
        if name_taken {
            self.warn(
                Some(si),
                Some(ti),
                None,
                format!(
                    "another group of stitches on hold is also called {}; give each group its own \
                     name so the steps that return them are clear",
                    name.trim()
                ),
            );
        }
        let text = if all {
            format!("place all {} on a holder{shown}", sts(k))
        } else if count.is_none() {
            format!("place the remaining {} on a holder{shown}", sts(k))
        } else {
            format!("place the next {} on a holder{shown}", sts(k))
        };
        let needle = self.needle.as_mut().expect("counting");
        let marks = needle.remove_ahead(k);
        if needle.rh() > 0 && needle.lh() > 0 {
            needle.gaps.push(Gap {
                at: needle.c,
                name: name.to_string(),
            });
            needle.tidy();
        }
        needle.settle();
        self.groups.push(Group {
            hold: step.id.clone(),
            name: name.to_string(),
            count: Some(k),
            marks,
            resumed: None,
        });
        let line_count = self.snapshot();
        self.push_line(si, ti, None, None, text, true, false, line_count);
    }

    fn resume(&mut self, si: usize, ti: usize, hold: &str, facing: Option<Side>) {
        let generic = "return the held sts to the needle".to_string();
        // Find the hold step this names, and the group it made.
        let Some(&(hs, ht)) = self.by_id.get(hold) else {
            return self.refuse(
                si,
                ti,
                generic,
                "returns held stitches, but the step that put them on hold is gone (it may have \
                 been deleted)"
                    .into(),
            );
        };
        let p = self.p;
        let StepAction::Hold { name, .. } = &p.sections[hs].steps[ht].action else {
            let other = self.place(hs, Some(ht), None);
            return self.refuse(
                si,
                ti,
                generic,
                format!("names {other}, which does not put stitches on hold"),
            );
        };
        let shown = match name.trim() {
            "" => String::new(),
            n => format!(" ({n})"),
        };
        let text_for = |k: Option<u64>, empty: bool| {
            let what = match k {
                Some(k) => format!("the {} on hold{shown}", sts(k)),
                None => format!("the sts on hold{shown}"),
            };
            if empty {
                let facing = match facing {
                    Some(Side::Rs) => "with the RS facing, ",
                    Some(Side::Ws) => "with the WS facing, ",
                    None => "",
                };
                format!("{facing}return {what} to the needle and join the yarn")
            } else {
                format!("return {what} to the left needle")
            }
        };
        if (hs, ht) > (si, ti) {
            let other = self.place(hs, Some(ht), None);
            return self.refuse(
                si,
                ti,
                text_for(None, false),
                format!(
                    "returns the stitches on hold{shown} before {other} puts them on hold; move \
                     this step after it"
                ),
            );
        }
        if self.failed_holds.iter().any(|h| h == hold) {
            let other = self.place(hs, Some(ht), None);
            return self.refuse(
                si,
                ti,
                text_for(None, false),
                format!(
                    "returns the stitches on hold{shown}, but {other} could not put them on hold"
                ),
            );
        }
        let Some(gi) = self.groups.iter().rposition(|g| g.hold == hold) else {
            let other = self.place(hs, Some(ht), None);
            return self.refuse(
                si,
                ti,
                text_for(None, false),
                format!(
                    "returns the stitches on hold{shown}, but {other} could not put them on hold"
                ),
            );
        };
        if let Some((rs, rt)) = self.groups[gi].resumed {
            let other = self.place(rs, Some(rt), None);
            return self.refuse(
                si,
                ti,
                text_for(self.groups[gi].count, false),
                format!(
                    "returns the stitches on hold{shown}, but {other} already returned them to the \
                     needle"
                ),
            );
        }
        let group = self.groups[gi].clone();
        let Some(needle) = &self.needle else {
            self.groups[gi].resumed = Some((si, ti));
            return self.unknown_line(si, ti, text_for(group.count, false));
        };
        // Moving stitches from the holder to the needle keeps the total, which the cap already holds.
        let k = group.count.unwrap_or(0);
        let empty = needle.n == 0;
        let text = text_for(Some(k), empty);
        if empty {
            // The group keeps its piece order: from the other side, its first row starts at the
            // last stitch, so a wrap lands where the knitter meets it.
            let mut fresh = Needle::facing(k, facing, self.p.first_row_side);
            for (offset, m) in &group.marks {
                fresh.marks.push(Mark {
                    pos: *offset,
                    kind: m.kind,
                });
            }
            self.needle = Some(fresh);
            if facing.is_none() {
                let marks = if group.marks.is_empty() {
                    ""
                } else {
                    ", or where the short-row wraps and double stitches on these stitches fall"
                };
                self.warn(
                    Some(si),
                    Some(ti),
                    None,
                    format!(
                        "does not say which side faces you when the stitches go back on the needle, \
                         so Ply cannot tell which rows after it are right-side or wrong-side rows\
                         {marks}"
                    ),
                );
            }
        } else {
            match (facing, needle.side()) {
                (Some(f), Some(s)) if f != s => self.error(
                    Some(si),
                    Some(ti),
                    None,
                    format!(
                        "says the {} faces you, but the work is at a {} row here",
                        side_noun(f),
                        side_name(s)
                    ),
                ),
                (Some(f), None) => {
                    let first = self.p.first_row_side;
                    self.needle.as_mut().expect("counting").set_side(f, first)
                }
                _ => {}
            }
            self.needle
                .as_mut()
                .expect("counting")
                .insert(k, true, &group.marks);
        }
        self.groups[gi].resumed = Some((si, ti));
        self.needle.as_mut().expect("counting").settle();
        let count = self.snapshot();
        self.push_line(si, ti, None, None, text, true, false, count);
    }

    fn opaque(&mut self, si: usize, ti: usize, text: &str, change: Option<i64>) {
        let label = Some("Not checked by Ply".to_string());
        let shown = match text.trim() {
            "" => "(no text)".to_string(),
            t => t.to_string(),
        };
        let Some(needle) = &self.needle else {
            self.push_line(si, ti, None, label, shown, false, true, LineCount::Unknown);
            return;
        };
        let Some(change) = change else {
            self.warn(
                Some(si),
                Some(ti),
                None,
                "Ply does not check this step, and it does not say how it changes the number of \
                 stitches, so the stitch counts after it are unknown; give the change (0 if it \
                 changes nothing) to keep counting"
                    .into(),
            );
            self.needle = None;
            self.push_line(si, ti, None, label, shown, false, true, LineCount::Unknown);
            return;
        };
        let k = change.unsigned_abs();
        let at_start = needle.row_start;
        if change > 0 {
            if self.too_big(k) {
                self.error(Some(si), Some(ti), None, too_many());
                self.push_line(
                    si,
                    ti,
                    None,
                    label,
                    shown,
                    false,
                    true,
                    LineCount::NotCounted,
                );
                return;
            }
            self.needle
                .as_mut()
                .expect("counting")
                .insert(k, at_start, &[]);
        } else if change < 0 {
            let room = if at_start { needle.lh() } else { needle.rh() };
            if k > room {
                let what = if at_start {
                    only_left(room)
                } else {
                    format!(
                        "only {} worked so far in this row",
                        match room {
                            1 => "1 stitch is".to_string(),
                            n => format!("{n} stitches are"),
                        }
                    )
                };
                self.error(
                    Some(si),
                    Some(ti),
                    None,
                    format!("says it removes {}, but {what}", stitches(k)),
                );
                self.push_line(
                    si,
                    ti,
                    None,
                    label,
                    shown,
                    false,
                    true,
                    LineCount::NotCounted,
                );
                return;
            }
            let needle = self.needle.as_mut().expect("counting");
            if at_start {
                needle.remove_ahead(k);
            } else {
                needle.remove_behind(k);
            }
        }
        self.needle.as_mut().expect("counting").settle();
        let count = self.snapshot();
        self.push_line(si, ti, None, label, shown, false, true, count);
    }

    fn chart_rows(&mut self, si: usize, ti: usize, first: u32, last: u32) {
        let height = self.p.chart.rows.len() as u64;
        let range_text = if first == last {
            format!("work chart row {first}")
        } else {
            format!("work chart rows {first} to {last}")
        };
        let bad = if height == 0 {
            Some(format!(
                "works {}, but the chart has no rows",
                range_text.trim_start_matches("work ")
            ))
        } else if first == 0 {
            Some("chart rows are numbered from 1".into())
        } else if last < first {
            Some(format!(
                "works chart rows {first} to {last}; give the lower row first"
            ))
        } else if u64::from(last) > height {
            Some(format!(
                "works {}, but the chart has only {}",
                range_text.trim_start_matches("work "),
                count_of(height, "row", "rows")
            ))
        } else {
            None
        };
        if let Some(problem) = bad {
            return self.refuse(si, ti, range_text, problem);
        }
        let mut failed = false;
        for r in (first as usize - 1)..(last as usize) {
            self.used_rows[r] = true;
            let (label, body) = crate::written::chart_row_text(self.p, r, self.colors.as_ref());
            if failed {
                self.push_line(
                    si,
                    ti,
                    Some(r),
                    Some(label),
                    body,
                    false,
                    false,
                    LineCount::NotCounted,
                );
                continue;
            }
            if !self.chart_row(si, ti, r, label, body) {
                failed = true;
            }
        }
    }

    /// Work chart row `r` as part of step `ti`. Returns false when it was not applied.
    fn chart_row(&mut self, si: usize, ti: usize, r: usize, label: String, body: String) -> bool {
        let Some(needle) = &self.needle else {
            self.push_line(
                si,
                ti,
                Some(r),
                Some(label),
                body,
                false,
                false,
                LineCount::Unknown,
            );
            return true;
        };
        let refuse = |walk: &mut Self, label: String, body: String, problem: String| {
            walk.error(Some(si), Some(ti), Some(r), problem);
            walk.push_line(
                si,
                ti,
                Some(r),
                Some(label),
                body,
                false,
                false,
                LineCount::NotCounted,
            );
            false
        };
        if needle.n == 0 {
            return refuse(self, label, body, no_stitches());
        }
        if !needle.row_start {
            return refuse(
                self,
                label,
                body,
                format!(
                    "a chart row has to start at the beginning of a row, but this row is already \
                     started ({} still to work in it)",
                    stitches(needle.lh())
                ),
            );
        }
        let chart_side = self.p.row_side(r);
        let side_unknown = needle.side().is_none();
        if let Some(s) = needle.side().filter(|&s| s != chart_side) {
            let problem = format!(
                "the chart has it as a {} row, but the work is at a {} row here",
                side_name(chart_side),
                side_name(s)
            );
            self.error(Some(si), Some(ti), Some(r), problem);
        }
        // At the start of a row the stitches waiting are the same whichever way it travels, so the
        // count is checked before an unknown side is taken from the chart.
        let needle = self.needle.as_ref().expect("counting");
        let (lh, at_edge, n) = (needle.lh(), needle.at_edge(), needle.n);
        let (instruction, count, problems) = chart_row_count(self.p, r, Some(lh));
        let cols = ReadingCols::for_row(self.p, r);
        if matches!(instruction, RowInstruction::Unsupported(_)) {
            self.error(
                Some(si),
                Some(ti),
                Some(r),
                "its repeats need fixing (see the chart's problems), so Ply cannot count it and the \
                 stitch counts after it are unknown"
                    .into(),
            );
            self.needle = None;
            self.push_line(
                si,
                ti,
                Some(r),
                Some(label),
                body,
                false,
                false,
                LineCount::Unknown,
            );
            return true;
        }
        for problem in &problems {
            let text = problem.reason_from(CountSource::InRow, &cols);
            self.issue(
                if problem.is_warning() {
                    Severity::Warning
                } else {
                    Severity::Error
                },
                Some(si),
                Some(ti),
                Some(r),
                text,
            );
        }
        let Some(count) = count else {
            if problems.iter().any(|p| !p.is_warning()) {
                // The row cannot be worked over the stitches waiting (said above): not applied.
                self.push_line(
                    si,
                    ti,
                    Some(r),
                    Some(label),
                    body,
                    false,
                    false,
                    LineCount::NotCounted,
                );
                return false;
            }
            self.warn(
                Some(si),
                Some(ti),
                Some(r),
                "Ply cannot count this row, so the stitch counts after it are unknown".into(),
            );
            self.needle = None;
            self.push_line(
                si,
                ti,
                Some(r),
                Some(label),
                body,
                false,
                false,
                LineCount::Unknown,
            );
            return true;
        };
        if count.consumed != lh {
            // Not applied: the stitches on the needle are not what the chart row works over. The
            // rest of the step's rows are not counted either, so this is its one count error.
            let have = if at_edge {
                format!("{} on the needle", are_count(lh))
            } else {
                format!("{} left to work in this row", are_count(lh))
            };
            return refuse(
                self,
                label,
                body,
                format!(
                    "works over {}, but {have}, so this row and the rest of the step are not \
                     counted",
                    stitches(count.consumed)
                ),
            );
        }
        let new_n = n - lh + count.produced.min(MAX_LIVE_STITCHES + 1);
        if new_n.saturating_add(self.held_total()) > MAX_LIVE_STITCHES {
            return refuse(self, label, body, too_many());
        }
        if side_unknown {
            let first = self.p.first_row_side;
            self.needle
                .as_mut()
                .expect("counting")
                .set_side(chart_side, first);
        }
        self.needle.as_mut().expect("counting").row_start = false;
        let body = self.with_double_stitch(body);
        let needle = self.needle.as_mut().expect("counting");
        let up = needle.up;
        let (marks, gaps) = needle.traverse(lh);
        // The worked run is replaced by what the row produces.
        let produced = count.produced;
        if up {
            needle.n = new_n;
            needle.c = new_n;
        } else {
            for m in &mut needle.marks {
                m.pos = m.pos - lh + produced;
            }
            for g in &mut needle.gaps {
                g.at = g.at - lh + produced;
            }
            needle.n = new_n;
            needle.c = 0;
        }
        needle.tidy();
        let body = self.crossings(si, ti, Some(r), body, &marks, &gaps, false, false);
        self.needle.as_mut().expect("counting").settle();
        let line_count = self.snapshot();
        self.push_line(si, ti, Some(r), Some(label), body, false, false, line_count);
        true
    }

    // --- ends ---

    fn end_section(&mut self, si: usize) {
        if let Some(line) = self.make_ds.take() {
            self.ds_on_turn_line(line);
        }
        let Some(needle) = self.needle.clone() else {
            return;
        };
        if needle.n > 0 && !needle.row_start {
            self.warn(
                Some(si),
                None,
                None,
                format!(
                    "ends part way through a row, with {} still to work in it",
                    stitches(needle.lh())
                ),
            );
        }
        let waiting = needle.lo + needle.hi;
        if waiting > 0 || !needle.marks.is_empty() {
            let wraps = needle
                .marks
                .iter()
                .filter(|m| m.kind == Pending::Wrap)
                .count() as u64;
            let doubles = needle.marks.len() as u64 - wraps;
            let mut text = format!(
                "ends with short rows not yet worked across: {} {} still waiting past a turn",
                stitches(waiting),
                if waiting == 1 { "is" } else { "are" }
            );
            if wraps > 0 {
                text.push_str(&format!(
                    ", and {} not yet worked together with {}",
                    count_of(wraps, "wrap is", "wraps are"),
                    if wraps == 1 {
                        "its stitch"
                    } else {
                        "their stitches"
                    }
                ));
            }
            if doubles > 0 {
                text.push_str(&format!(
                    ", and {} not yet worked as one stitch",
                    count_of(doubles, "double stitch is", "double stitches are")
                ));
            }
            self.warn(Some(si), None, None, text);
        }
    }

    fn end_pattern(&mut self) {
        let held: Vec<Group> = self
            .groups
            .iter()
            .filter(|g| g.resumed.is_none())
            .cloned()
            .collect();
        for g in held {
            let Some(&(hs, ht)) = self.by_id.get(g.hold.as_str()) else {
                continue;
            };
            let shown = match g.name.trim() {
                "" => String::new(),
                n => format!(" ({n})"),
            };
            let what = match g.count {
                Some(k) => format!(
                    "{} {} still on hold{shown}",
                    stitches(k),
                    if k == 1 { "is" } else { "are" }
                ),
                None => format!("the stitches put on hold{shown} are still there"),
            };
            self.warn(
                Some(hs),
                Some(ht),
                None,
                format!("{what} at the end of the pattern; no step returns them to the needle"),
            );
        }
        let unused = ranges(&self.used_rows, false);
        if !unused.is_empty() {
            let parts: Vec<String> = unused
                .iter()
                .map(|&(a, b)| {
                    if a == b {
                        format!("{}", a + 1)
                    } else {
                        format!("{} to {}", a + 1, b + 1)
                    }
                })
                .collect();
            let text = if self.used_rows.iter().all(|u| !u) {
                "no section works any of the chart's rows, so the written instructions leave the \
                 chart out"
                    .to_string()
            } else if unused.len() == 1 && unused[0].0 == unused[0].1 {
                format!(
                    "chart row {} is not worked in any section, so the written instructions leave \
                     it out",
                    parts[0]
                )
            } else {
                format!(
                    "chart rows {} are not worked in any section, so the written instructions \
                     leave them out",
                    parts.join(", ")
                )
            };
            self.warn(None, None, None, text);
        }
    }
}

// --- wording helpers -------------------------------------------------------------------------------

fn work_text(stitch: WorkStitch, to: WorkTo) -> String {
    let verb = match stitch {
        WorkStitch::Knit => "knit",
        WorkStitch::Purl => "purl",
        WorkStitch::InPattern => "work in pattern",
    };
    match to {
        WorkTo::End => format!("{verb} to end"),
        WorkTo::Last(1) => format!("{verb} to last st"),
        WorkTo::Last(m) => format!("{verb} to last {m} sts"),
        WorkTo::Count(m) => match stitch {
            WorkStitch::InPattern => format!("work {} in pattern", sts(u64::from(m))),
            _ => format!("{verb} {}", sts(u64::from(m))),
        },
    }
}

/// `1 st` / `24 sts` (the written instructions' abbreviation).
fn sts(n: u64) -> String {
    if n == 1 {
        "1 st".into()
    } else {
        format!("{n} sts")
    }
}

/// `1 stitch` / `24 stitches` (messages are sentences).
fn stitches(n: u64) -> String {
    count_of(n, "stitch", "stitches")
}

fn count_of(n: u64, one: &str, many: &str) -> String {
    if n == 1 {
        format!("1 {one}")
    } else {
        format!("{n} {many}")
    }
}

/// `1 is` / `24 are`.
fn are_count(n: u64) -> String {
    if n == 1 {
        "1 is".into()
    } else {
        format!("{n} are")
    }
}

/// `only 1 stitch is left to work in this row` / `only 24 stitches are ...`.
fn only_left(n: u64) -> String {
    format!(
        "only {} {} left to work in this row",
        stitches(n),
        if n == 1 { "is" } else { "are" }
    )
}

fn no_stitches() -> String {
    "there are no stitches on the needle; cast on first (in the pattern settings or with a cast-on \
     step)"
        .into()
}

fn too_many() -> String {
    "has too many stitches to count".into()
}

fn side_name(s: Side) -> &'static str {
    match s {
        Side::Rs => "right-side",
        Side::Ws => "wrong-side",
    }
}

fn side_noun(s: Side) -> &'static str {
    match s {
        Side::Rs => "right side",
        Side::Ws => "wrong side",
    }
}

fn display_name(name: &str) -> String {
    match name.trim() {
        "" => "unnamed".into(),
        n => n.into(),
    }
}

fn capitalize(s: &str) -> String {
    let mut chars = s.chars();
    match chars.next() {
        Some(c) => c.to_uppercase().chain(chars).collect(),
        None => String::new(),
    }
}

/// The runs of indices where `flags[i] == value`, as inclusive `(first, last)` pairs.
fn ranges(flags: &[bool], value: bool) -> Vec<(usize, usize)> {
    let mut out = Vec::new();
    let mut i = 0;
    while i < flags.len() {
        if flags[i] == value {
            let start = i;
            while i + 1 < flags.len() && flags[i + 1] == value {
                i += 1;
            }
            out.push((start, i));
        }
        i += 1;
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::pattern::{builtin, Cell, Chart, Gauge, Row, StitchLegend};
    use crate::{to_written, validate};
    use ply_common::{Color, Unit};

    /// A flat pattern casting on `cast_on`, with `rows` chart rows of `width` knit cells (worked as
    /// stockinette: knit on the RS, purl on the WS), and the given sections.
    fn pat(cast_on: Option<u32>, width: usize, rows: usize, sections: Vec<Section>) -> KnitPattern {
        KnitPattern {
            name: "t".into(),
            construction: Construction::Flat,
            first_row_side: Side::Rs,
            cast_on,
            gauge: Gauge {
                sts: 20.0,
                rows: 28.0,
                unit: Unit::Inches,
            },
            palette: vec![Color::WHITE],
            legend: StitchLegend::builtin(),
            chart: Chart {
                width,
                rows: (0..rows)
                    .map(|_| Row::plain(vec![Cell::of(builtin::KNIT); width]))
                    .collect(),
            },
            notes: String::new(),
            sections,
        }
    }

    fn section(id: &str, name: &str, steps: Vec<(&str, StepAction)>) -> Section {
        Section {
            id: id.into(),
            name: name.into(),
            notes: String::new(),
            steps: steps
                .into_iter()
                .map(|(id, action)| Step {
                    id: id.into(),
                    action,
                })
                .collect(),
        }
    }

    fn work(stitch: WorkStitch, to: WorkTo, resolve_turns: bool) -> StepAction {
        StepAction::Work {
            stitch,
            to,
            resolve_turns,
        }
    }

    fn short(to: TurnAt, method: TurnMethod) -> StepAction {
        StepAction::ShortRow {
            stitch: WorkStitch::Knit,
            to,
            method,
            resolve_turns: false,
        }
    }

    fn hold(count: Option<u32>, name: &str) -> StepAction {
        StepAction::Hold {
            count,
            name: name.into(),
        }
    }

    fn lines(p: &KnitPattern) -> Vec<String> {
        ledger(p).lines.iter().map(LedgerLine::written).collect()
    }

    fn messages(p: &KnitPattern) -> Vec<(Severity, String)> {
        ledger(p)
            .issues
            .into_iter()
            .map(|i| (i.severity, i.message))
            .collect()
    }

    use WorkStitch::{Knit, Purl};

    #[test]
    fn wrap_and_turn_shoulder_counts_every_step_and_resolves_the_wraps() {
        let p = pat(
            Some(24),
            24,
            0,
            vec![section(
                "s1",
                "Shoulder",
                vec![
                    ("a", short(TurnAt::Last(6), TurnMethod::WrapAndTurn)),
                    ("b", work(Purl, WorkTo::End, false)),
                    ("c", short(TurnAt::Last(12), TurnMethod::WrapAndTurn)),
                    ("d", work(Purl, WorkTo::End, false)),
                    ("e", work(Knit, WorkTo::End, true)),
                ],
            )],
        );
        assert_eq!(
            lines(&p),
            vec![
                "Short row 1 (RS): knit to last 6 sts, wrap and turn. (24 sts on the needle, 6 waiting past a turn)",
                "Short row 2 (WS): purl to end. (24 sts on the needle, 6 waiting past a turn)",
                "Short row 3 (RS): knit to last 12 sts, wrap and turn. (24 sts on the needle, 12 waiting past a turn)",
                "Short row 4 (WS): purl to end. (24 sts on the needle, 12 waiting past a turn)",
                "Next row (RS): knit to end, working each wrap together with its stitch. (24 sts on the needle)",
            ]
        );
        assert!(messages(&p).is_empty(), "{:?}", messages(&p));
        let l = ledger(&p);
        let c = l.lines[2].count.counted().unwrap();
        assert_eq!((c.on_needle, c.past_turns, c.pending_turns), (24, 12, 2));
        assert_eq!(c.side, Some(Side::Ws), "the next row after the turn is WS");
        assert_eq!(l.lines[4].count.counted().unwrap().pending_turns, 0);
    }

    #[test]
    fn short_rows_turned_on_wrong_side_rows_wait_at_the_other_edge() {
        let ws_short = |to, method| StepAction::ShortRow {
            stitch: Purl,
            to,
            method,
            resolve_turns: false,
        };
        let p = pat(
            Some(12),
            12,
            0,
            vec![section(
                "s1",
                "Left shoulder",
                vec![
                    ("a", work(Knit, WorkTo::End, false)),
                    ("b", ws_short(TurnAt::Last(4), TurnMethod::WrapAndTurn)),
                    ("c", work(Knit, WorkTo::End, false)),
                    ("d", ws_short(TurnAt::Last(8), TurnMethod::German)),
                    ("e", work(Knit, WorkTo::End, false)),
                    ("f", work(Purl, WorkTo::End, true)),
                ],
            )],
        );
        assert_eq!(
            lines(&p),
            vec![
                "Next row (RS): knit to end. (12 sts on the needle)",
                "Short row 1 (WS): purl to last 4 sts, wrap and turn. (12 sts on the needle, 4 waiting past a turn)",
                "Short row 2 (RS): knit to end. (12 sts on the needle, 4 waiting past a turn)",
                "Short row 3 (WS): purl to last 8 sts, turn. (12 sts on the needle, 8 waiting past a turn)",
                "Short row 4 (RS): make a double stitch, knit to end. (12 sts on the needle, 8 waiting past a turn)",
                "Next row (WS): purl to end, working each wrap together with its stitch and each double stitch as one stitch. (12 sts on the needle)",
            ]
        );
        assert!(messages(&p).is_empty(), "{:?}", messages(&p));
    }

    #[test]
    fn a_group_returned_with_the_other_side_facing_keeps_its_wraps_where_they_are() {
        let p = pat(
            Some(10),
            10,
            0,
            vec![section(
                "s1",
                "S",
                vec![
                    ("a", short(TurnAt::Count(5), TurnMethod::WrapAndTurn)),
                    ("b", work(Purl, WorkTo::End, false)),
                    ("c", work(Knit, WorkTo::Count(3), false)),
                    ("d", hold(None, "B")),
                    (
                        "e",
                        StepAction::BindOff {
                            count: None,
                            resolve_turns: false,
                        },
                    ),
                    (
                        "f",
                        StepAction::Resume {
                            hold: "d".into(),
                            facing: Some(Side::Ws),
                        },
                    ),
                    ("g", work(Purl, WorkTo::Count(3), false)),
                    ("h", work(Purl, WorkTo::End, true)),
                ],
            )],
        );
        let l = lines(&p);
        // Purl 3 works stitches 10, 9 and 8 of the cast-on; the wrap on stitch 6 comes after.
        assert_eq!(
            l[6],
            "Next row (WS): purl 3 sts. (7 sts on the needle, 4 still to work in this row; 3 bound off)"
        );
        assert_eq!(
            l[7],
            "Purl to end, working each wrap together with its stitch. (7 sts on the needle; 3 bound off)"
        );
        assert!(messages(&p).is_empty(), "{:?}", messages(&p));
    }

    #[test]
    fn a_group_returned_with_no_side_takes_its_side_from_the_first_chart_row() {
        let steps = |facing| {
            vec![
                ("a", work(Knit, WorkTo::Count(3), false)),
                ("b", short(TurnAt::Last(2), TurnMethod::WrapAndTurn)),
                ("c", work(Purl, WorkTo::End, false)),
                ("d", hold(None, "all")),
                (
                    "e",
                    StepAction::Resume {
                        hold: "d".into(),
                        facing,
                    },
                ),
                ("f", StepAction::ChartRows { first: 2, last: 2 }),
            ]
        };
        let p = pat(Some(7), 7, 2, vec![section("s1", "S", steps(None))]);
        let l = ledger(&p);
        let row = l.lines.last().unwrap();
        assert_eq!(
            row.count.counted().unwrap().side,
            Some(Side::Rs),
            "the WS chart row was taken as the side, and the next row is RS"
        );
        let texts: Vec<&str> = l.issues.iter().map(|i| i.text.as_str()).collect();
        assert!(
            texts
                .iter()
                .any(|t| t.starts_with("does not say which side faces you")
                    && t.ends_with(
                        "or where the short-row wraps and double stitches on these stitches fall"
                    )),
            "{texts:?}"
        );
        assert!(
            !texts.iter().any(|t| t.contains("the chart has it as")),
            "no side error: the side was not known"
        );
    }

    #[test]
    fn huge_stitch_changes_are_refused_not_overflowed() {
        let opaque = |d: i64| StepAction::Opaque {
            text: "x".into(),
            stitch_change: Some(d),
        };
        let p = pat(
            Some(4),
            4,
            0,
            vec![section(
                "s1",
                "S",
                vec![
                    ("a", opaque(i64::MAX)),
                    ("b", opaque(i64::MAX)),
                    ("c", opaque(1)),
                    (
                        "d",
                        StepAction::BindOff {
                            count: None,
                            resolve_turns: false,
                        },
                    ),
                    ("e", opaque(i64::MIN)),
                    ("f", work(Knit, WorkTo::End, false)),
                    ("g", work(Purl, WorkTo::Count(1), false)),
                    ("h", StepAction::CastOn { count: u32::MAX }),
                ],
            )],
        );
        let l = ledger(&p);
        assert_eq!(l.lines[0].count, LineCount::NotCounted);
        assert_eq!(l.lines[1].count, LineCount::NotCounted);
        assert_eq!(l.issues[0].text, "has too many stitches to count");
        assert_eq!(l.lines[7].count, LineCount::NotCounted);
        // The same through the file and validation.
        let text = crate::native::write(&p).unwrap();
        let back = crate::native::read(&text).unwrap().pattern;
        let _ = validate(&back);
        let _ = to_written(&back);
        // Up to the cap is fine; one more is refused.
        let p = pat(
            Some(1),
            1,
            0,
            vec![section(
                "s1",
                "S",
                vec![
                    ("a", StepAction::CastOn { count: 999_999 }),
                    ("b", StepAction::CastOn { count: 1 }),
                ],
            )],
        );
        let l = ledger(&p);
        assert_eq!(l.lines[0].count.counted().unwrap().on_needle, 1_000_000);
        assert_eq!(l.lines[1].count, LineCount::NotCounted);
    }

    #[test]
    fn a_double_stitch_is_mentioned_on_the_turn_when_the_next_step_does_not_work_the_row() {
        let p = pat(
            Some(24),
            24,
            0,
            vec![section(
                "s1",
                "S",
                vec![
                    ("a", short(TurnAt::Last(6), TurnMethod::German)),
                    ("b", hold(None, "rest")),
                    ("c", work(Knit, WorkTo::End, true)),
                ],
            )],
        );
        let l = lines(&p);
        assert_eq!(
            l[0],
            "Short row 1 (RS): knit to last 6 sts, turn, then make a double stitch. (24 sts on the needle, 6 waiting past a turn)"
        );
        assert_eq!(
            l[2],
            "Next row (RS): knit to end, working each double stitch as one stitch. (7 sts on the needle; 17 on hold)"
        );
    }

    #[test]
    fn a_german_turn_that_leaves_only_the_double_stitch_is_refused() {
        let p = pat(
            Some(12),
            12,
            0,
            vec![section(
                "s1",
                "S",
                vec![
                    ("a", short(TurnAt::Count(1), TurnMethod::German)),
                    ("b", work(Knit, WorkTo::End, false)),
                ],
            )],
        );
        let l = ledger(&p);
        assert_eq!(l.lines[0].count, LineCount::NotCounted);
        assert_eq!(
            l.issues[0].text,
            "turns too soon for a German short row: the next row would have only the double stitch \
             to work; work at least 2 stitches before this turn, or use another method"
        );
        assert_eq!(
            l.lines[1].written(),
            "Next row (RS): knit to end. (12 sts on the needle)",
            "nothing changed: no turn, no double stitch"
        );
    }

    #[test]
    fn a_construction_too_long_to_count_stops_with_one_error() {
        let steps: Vec<(&str, StepAction)> = (0..MAX_STEPS + 1)
            .map(|_| ("x", work(Knit, WorkTo::End, false)))
            .collect();
        let p = pat(Some(4), 4, 0, vec![section("s1", "S", steps)]);
        let l = ledger(&p);
        assert!(l.stopped && l.lines.is_empty());
        assert_eq!(l.issues.len(), 1);
        assert!(l.issues[0]
            .text
            .starts_with("this construction is too long for Ply to count"));
        // Chart rows multiply: a few steps over a long chart stop at the line cap.
        let rows = 2_000;
        let steps: Vec<(&str, StepAction)> = (0..20)
            .map(|_| {
                (
                    "x",
                    StepAction::ChartRows {
                        first: 1,
                        last: rows,
                    },
                )
            })
            .collect();
        let p = pat(Some(4), 4, rows as usize, vec![section("s1", "S", steps)]);
        let l = ledger(&p);
        assert!(l.stopped);
        assert!(l.lines.len() <= MAX_LINES);
        assert_eq!(
            l.issues
                .iter()
                .filter(|i| i.text.starts_with("this construction is too long"))
                .count(),
            1
        );
        let w = to_written(&p);
        assert_eq!(
            w.last().unwrap(),
            "(Ply stopped here: the construction is too long to count. See the problems.)"
        );
        assert!(check_limits(&p).is_ok());
    }

    #[test]
    fn files_past_the_size_limits_are_named() {
        let mut p = pat(Some(4), 4, 0, vec![section("s1", "S", vec![])]);
        assert!(check_limits(&p).is_ok());
        p.sections[0].notes = "n".repeat(MAX_TEXT_BYTES + 1);
        assert!(check_limits(&p).unwrap_err().contains("longer than"));
        p.sections[0].notes.clear();
        p.sections[0].steps.push(Step {
            id: "a".into(),
            action: StepAction::Opaque {
                text: "t".into(),
                stitch_change: Some(-(MAX_LIVE_STITCHES as i64) - 1),
            },
        });
        assert!(check_limits(&p)
            .unwrap_err()
            .contains("changes the stitch count by"));
    }

    #[test]
    fn german_short_rows_make_and_work_the_double_stitch() {
        let p = pat(
            Some(12),
            12,
            0,
            vec![section(
                "s1",
                "Hem",
                vec![
                    ("a", short(TurnAt::Last(4), TurnMethod::German)),
                    ("b", work(Purl, WorkTo::End, false)),
                    ("c", work(Knit, WorkTo::End, true)),
                ],
            )],
        );
        assert_eq!(
            lines(&p),
            vec![
                "Short row 1 (RS): knit to last 4 sts, turn. (12 sts on the needle, 4 waiting past a turn)",
                "Short row 2 (WS): make a double stitch, purl to end. (12 sts on the needle, 4 waiting past a turn)",
                "Next row (RS): knit to end, working each double stitch as one stitch. (12 sts on the needle)",
            ]
        );
        assert!(messages(&p).is_empty(), "{:?}", messages(&p));
    }

    #[test]
    fn a_german_turn_at_the_end_of_a_section_says_to_make_the_double_stitch() {
        let p = pat(
            Some(12),
            12,
            0,
            vec![section(
                "s1",
                "Hem",
                vec![("a", short(TurnAt::Count(5), TurnMethod::German))],
            )],
        );
        assert_eq!(
            lines(&p),
            vec!["Short row 1 (RS): knit 5 sts, turn, then make a double stitch. (12 sts on the needle, 7 waiting past a turn)"]
        );
        assert_eq!(
            messages(&p),
            vec![(
                Severity::Warning,
                "Hem: ends with short rows not yet worked across: 7 stitches are still waiting past \
                 a turn, and 1 double stitch is not yet worked as one stitch"
                    .to_string()
            )]
        );
    }

    #[test]
    fn an_unspecified_turn_counts_the_waiting_stitches_and_leaves_nothing_to_resolve() {
        let p = pat(
            Some(10),
            10,
            0,
            vec![section(
                "s1",
                "Dart",
                vec![
                    ("a", short(TurnAt::Last(3), TurnMethod::Unspecified)),
                    ("b", work(Purl, WorkTo::End, false)),
                    ("c", work(Knit, WorkTo::End, false)),
                ],
            )],
        );
        assert_eq!(
            lines(&p),
            vec![
                "Short row 1 (RS): knit to last 3 sts, turn. (10 sts on the needle, 3 waiting past a turn)",
                "Short row 2 (WS): purl to end. (10 sts on the needle, 3 waiting past a turn)",
                "Next row (RS): knit to end. (10 sts on the needle)",
            ]
        );
        assert!(messages(&p).is_empty());
    }

    #[test]
    fn working_past_wraps_without_resolving_them_is_a_warning() {
        let p = pat(
            Some(10),
            10,
            0,
            vec![section(
                "s1",
                "S",
                vec![
                    ("a", short(TurnAt::Last(3), TurnMethod::WrapAndTurn)),
                    ("b", work(Purl, WorkTo::End, false)),
                    ("c", work(Knit, WorkTo::End, false)),
                ],
            )],
        );
        assert_eq!(
            messages(&p),
            vec![(
                Severity::Warning,
                "S, step 3: works past 1 wrapped stitch without working the wrap together with its \
                 stitch; say to work them in this step"
                    .to_string()
            )]
        );
    }

    #[test]
    fn held_stitches_split_the_row_and_return_from_the_stated_side() {
        let p = pat(
            Some(20),
            20,
            0,
            vec![
                section(
                    "s1",
                    "Divide",
                    vec![
                        ("a", work(Knit, WorkTo::Count(6), false)),
                        ("b", hold(Some(8), "center")),
                        ("c", hold(None, "right")),
                    ],
                ),
                section(
                    "s2",
                    "Left",
                    vec![
                        ("d", work(Purl, WorkTo::End, false)),
                        (
                            "e",
                            StepAction::BindOff {
                                count: None,
                                resolve_turns: false,
                            },
                        ),
                    ],
                ),
                section(
                    "s3",
                    "Right",
                    vec![
                        (
                            "f",
                            StepAction::Resume {
                                hold: "c".into(),
                                facing: Some(Side::Rs),
                            },
                        ),
                        ("g", work(Knit, WorkTo::End, false)),
                    ],
                ),
            ],
        );
        assert_eq!(
            lines(&p),
            vec![
                "Next row (RS): knit 6 sts. (20 sts on the needle, 14 still to work in this row)",
                "Place the next 8 sts on a holder (center). (12 sts on the needle, 6 still to work in this row; 8 on hold)",
                "Place the remaining 6 sts on a holder (right). (6 sts on the needle; on hold: center 8, right 6)",
                "Next row (WS): purl to end. (6 sts on the needle; on hold: center 8, right 6)",
                "Next row (RS): bind off all sts. (0 sts on the needle; on hold: center 8, right 6; 6 bound off)",
                "With the RS facing, return the 6 sts on hold (right) to the needle and join the yarn. (6 sts on the needle; 8 on hold; 6 bound off)",
                "Next row (RS): knit to end. (6 sts on the needle; 8 on hold; 6 bound off)",
            ]
        );
        assert_eq!(
            messages(&p),
            vec![(
                Severity::Warning,
                "Divide, step 2: 8 stitches are still on hold (center) at the end of the pattern; \
                 no step returns them to the needle"
                    .to_string()
            )]
        );
    }

    #[test]
    fn working_across_a_held_gap_warns_and_casting_on_over_it_does_not() {
        let gap = |bridge: bool| {
            let mut steps = vec![
                ("a", work(Knit, WorkTo::Count(5), false)),
                ("b", hold(Some(10), "pocket")),
            ];
            if bridge {
                steps.push(("c", StepAction::CastOn { count: 10 }));
            }
            steps.push(("d", work(Knit, WorkTo::End, false)));
            pat(Some(20), 20, 0, vec![section("s1", "Pocket", steps)])
        };
        assert_eq!(
            messages(&gap(false))[0],
            (
                Severity::Warning,
                "Pocket, step 3: works across the gap left by the stitches put on hold (pocket), \
                 which joins the two sides with a strand of yarn; cast on over the gap, or put one \
                 side on hold to work the sides separately"
                    .to_string()
            )
        );
        assert_eq!(
            messages(&gap(false)).len(),
            2,
            "and the pocket stitches are left on hold"
        );
        let bridged = gap(true);
        let l = lines(&bridged);
        assert_eq!(
            l[2],
            "Cast on 10 sts onto the right needle, over the gap left by the stitches on hold \
             (pocket). (20 sts on the needle, 5 still to work in this row; 10 on hold)"
        );
        assert_eq!(l[3], "Knit to end. (20 sts on the needle; 10 on hold)");
        assert_eq!(
            messages(&bridged).len(),
            1,
            "only the pocket stitches left on hold"
        );
    }

    #[test]
    fn a_mid_row_bind_off_leaves_one_stitch_on_the_right_needle() {
        let p = pat(
            Some(20),
            20,
            0,
            vec![section(
                "s1",
                "Shape",
                vec![
                    (
                        "a",
                        StepAction::BindOff {
                            count: Some(4),
                            resolve_turns: false,
                        },
                    ),
                    ("b", work(Knit, WorkTo::End, false)),
                ],
            )],
        );
        assert_eq!(
            lines(&p),
            vec![
                "Next row (RS): bind off 4 sts; 1 st remains on the right needle. (16 sts on the needle, 15 still to work in this row; 4 bound off)",
                "Knit to end. (16 sts on the needle; 4 bound off)",
            ]
        );
    }

    #[test]
    fn impossible_steps_are_errors_and_are_not_applied() {
        let p = pat(
            Some(10),
            10,
            0,
            vec![section(
                "s1",
                "P",
                vec![
                    (
                        "a",
                        StepAction::BindOff {
                            count: Some(11),
                            resolve_turns: false,
                        },
                    ),
                    ("b", hold(Some(12), "x")),
                    ("c", short(TurnAt::Last(10), TurnMethod::WrapAndTurn)),
                    ("d", short(TurnAt::Last(0), TurnMethod::WrapAndTurn)),
                    ("e", work(Knit, WorkTo::Count(0), false)),
                    (
                        "f",
                        StepAction::Resume {
                            hold: "nope".into(),
                            facing: None,
                        },
                    ),
                    (
                        "g",
                        StepAction::Resume {
                            hold: "a".into(),
                            facing: None,
                        },
                    ),
                    (
                        "h",
                        StepAction::Resume {
                            hold: "b".into(),
                            facing: None,
                        },
                    ),
                    ("i", StepAction::CastOn { count: 0 }),
                    ("j", work(Knit, WorkTo::End, false)),
                ],
            )],
        );
        let l = ledger(&p);
        for line in &l.lines[..9] {
            assert_eq!(line.count, LineCount::NotCounted, "{line:?}");
        }
        assert_eq!(
            l.lines[9].written(),
            "Next row (RS): knit to end. (10 sts on the needle)",
            "the refused steps changed nothing"
        );
        let texts: Vec<&str> = l.issues.iter().map(|i| i.text.as_str()).collect();
        assert_eq!(
            texts,
            vec![
                "binds off 11 stitches, but only 10 stitches are left to work in this row",
                "puts 12 stitches on hold, but only 10 stitches are left to work in this row",
                "turns before working any stitches: the last 10 stitches are all that is left to work in this row",
                "turns with no stitches left past the turn; to work every stitch left in the row, use a plain work step instead",
                "works 0 stitches",
                "returns held stitches, but the step that put them on hold is gone (it may have been deleted)",
                "names P, step 1, which does not put stitches on hold",
                "returns the stitches on hold (x), but P, step 2 could not put them on hold",
                "casts on 0 stitches; cast on at least 1",
            ]
        );
        assert!(l.issues.iter().all(|i| i.severity == Severity::Error));
    }

    #[test]
    fn a_group_cannot_be_returned_before_it_is_held_or_twice() {
        let p = pat(
            Some(10),
            10,
            0,
            vec![section(
                "s1",
                "P",
                vec![
                    (
                        "a",
                        StepAction::Resume {
                            hold: "b".into(),
                            facing: None,
                        },
                    ),
                    ("b", hold(Some(4), "edge")),
                    (
                        "c",
                        StepAction::Resume {
                            hold: "b".into(),
                            facing: None,
                        },
                    ),
                    (
                        "d",
                        StepAction::Resume {
                            hold: "b".into(),
                            facing: None,
                        },
                    ),
                ],
            )],
        );
        let texts: Vec<String> = ledger(&p).issues.into_iter().map(|i| i.message).collect();
        assert_eq!(
            texts,
            vec![
                "P, step 1: returns the stitches on hold (edge) before P, step 2 puts them on hold; move this step after it",
                "P, step 4: returns the stitches on hold (edge), but P, step 3 already returned them to the needle",
            ]
        );
    }

    #[test]
    fn a_chart_range_must_take_the_stitches_waiting_for_it() {
        let p = pat(
            Some(12),
            10,
            2,
            vec![section(
                "s1",
                "Body",
                vec![
                    ("a", StepAction::ChartRows { first: 1, last: 2 }),
                    ("b", work(Knit, WorkTo::End, false)),
                ],
            )],
        );
        assert_eq!(
            lines(&p),
            vec![
                "Row 1 (RS): k10 (not counted: see the problems)",
                "Row 2 (WS): p10 (not counted: see the problems)",
                "Next row (RS): knit to end. (12 sts on the needle)",
            ],
            "not applied: no stitch disappears, and the next step works the 12 that are there"
        );
        assert_eq!(
            messages(&p),
            vec![(
                Severity::Error,
                "Body, step 1, chart row 1: works over 10 stitches, but 12 are on the needle, so \
                 this row and the rest of the step are not counted"
                    .to_string()
            )],
            "one error for the step"
        );
        // Out of the chart, and a wrong-side start.
        let p = pat(
            Some(10),
            10,
            2,
            vec![section(
                "s1",
                "Body",
                vec![
                    ("a", StepAction::ChartRows { first: 2, last: 3 }),
                    ("b", StepAction::ChartRows { first: 2, last: 2 }),
                ],
            )],
        );
        assert_eq!(
            messages(&p),
            vec![
                (
                    Severity::Error,
                    "Body, step 1: works chart rows 2 to 3, but the chart has only 2 rows".into()
                ),
                (
                    Severity::Error,
                    "Body, step 2, chart row 2: the chart has it as a wrong-side row, but the work \
                     is at a right-side row here"
                        .into()
                ),
                (
                    Severity::Warning,
                    "chart row 1 is not worked in any section, so the written instructions leave \
                     it out"
                        .into()
                ),
            ]
        );
    }

    #[test]
    fn a_chart_row_must_start_a_row() {
        let p = pat(
            Some(10),
            10,
            1,
            vec![section(
                "s1",
                "Body",
                vec![
                    ("a", work(Knit, WorkTo::Count(2), false)),
                    ("b", StepAction::ChartRows { first: 1, last: 1 }),
                ],
            )],
        );
        assert_eq!(
            messages(&p),
            vec![
                (
                    Severity::Error,
                    "Body, step 2, chart row 1: a chart row has to start at the beginning of a \
                     row, but this row is already started (8 stitches still to work in it)"
                        .into()
                ),
                (
                    Severity::Warning,
                    "Body: ends part way through a row, with 8 stitches still to work in it".into()
                ),
            ]
        );
    }

    #[test]
    fn an_unchecked_step_without_a_change_makes_the_counts_unknown() {
        let p = pat(
            Some(10),
            10,
            0,
            vec![section(
                "s1",
                "Edge",
                vec![
                    (
                        "a",
                        StepAction::Opaque {
                            text: "Work a picot edge.".into(),
                            stitch_change: None,
                        },
                    ),
                    ("b", work(Knit, WorkTo::End, false)),
                    (
                        "c",
                        StepAction::BindOff {
                            count: Some(99),
                            resolve_turns: false,
                        },
                    ),
                ],
            )],
        );
        assert_eq!(
            lines(&p),
            vec![
                "Not checked by Ply: Work a picot edge. (stitch count unknown)",
                "Knit to end. (stitch count unknown)",
                "Bind off 99 sts. (stitch count unknown)",
            ]
        );
        let m = messages(&p);
        assert_eq!(
            m.len(),
            1,
            "one warning, nothing is checked after it: {m:?}"
        );
        assert_eq!(m[0].0, Severity::Warning);
        // A stated change keeps counting.
        let p = pat(
            Some(10),
            10,
            0,
            vec![section(
                "s1",
                "Edge",
                vec![
                    (
                        "a",
                        StepAction::Opaque {
                            text: "Increase 2 sts evenly across the next row.".into(),
                            stitch_change: Some(2),
                        },
                    ),
                    (
                        "b",
                        StepAction::Opaque {
                            text: "Decrease 20.".into(),
                            stitch_change: Some(-20),
                        },
                    ),
                ],
            )],
        );
        assert_eq!(
            lines(&p),
            vec![
                "Not checked by Ply: Increase 2 sts evenly across the next row. (12 sts on the needle)",
                "Not checked by Ply: Decrease 20. (not counted: see the problems)",
            ]
        );
        assert_eq!(
            messages(&p),
            vec![(
                Severity::Error,
                "Edge, step 2: says it removes 20 stitches, but only 12 stitches are left to work \
                 in this row"
                    .into()
            )]
        );
    }

    #[test]
    fn a_resume_onto_an_empty_needle_must_say_which_side_faces_you() {
        let p = pat(
            Some(8),
            8,
            0,
            vec![section(
                "s1",
                "S",
                vec![
                    ("a", hold(None, "all")),
                    (
                        "b",
                        StepAction::Resume {
                            hold: "a".into(),
                            facing: None,
                        },
                    ),
                    ("c", work(Knit, WorkTo::End, false)),
                ],
            )],
        );
        assert_eq!(
            lines(&p),
            vec![
                "Place all 8 sts on a holder (all). (0 sts on the needle; 8 on hold)",
                "Return the 8 sts on hold (all) to the needle and join the yarn. (8 sts on the needle)",
                "Next row: knit to end. (8 sts on the needle)",
            ]
        );
        assert_eq!(messages(&p).len(), 1);
        assert!(messages(&p)[0]
            .1
            .contains("does not say which side faces you"));
    }

    #[test]
    fn nothing_on_the_needle_until_something_is_cast_on() {
        let p = pat(
            None,
            8,
            0,
            vec![section(
                "s1",
                "Start",
                vec![
                    ("a", work(Knit, WorkTo::End, false)),
                    ("b", StepAction::CastOn { count: 8 }),
                    ("c", work(Knit, WorkTo::End, false)),
                ],
            )],
        );
        assert_eq!(
            lines(&p),
            vec![
                "Knit to end. (not counted: see the problems)",
                "Cast on 8 sts. (8 sts on the needle)",
                "Next row (RS): knit to end. (8 sts on the needle)",
            ]
        );
        assert!(messages(&p)[0]
            .1
            .contains("there are no stitches on the needle"));
    }

    #[test]
    fn in_the_round_sections_are_not_counted_yet() {
        let mut p = pat(
            Some(8),
            8,
            0,
            vec![section(
                "s1",
                "Leg",
                vec![("a", work(Knit, WorkTo::End, false))],
            )],
        );
        p.construction = Construction::InTheRound;
        assert_eq!(lines(&p), vec!["Knit to end. (stitch count unknown)"]);
        assert_eq!(messages(&p).len(), 1);
        assert!(messages(&p)[0].1.contains("worked in the round"));
    }

    #[test]
    fn duplicate_ids_are_errors() {
        let p = pat(
            Some(8),
            8,
            0,
            vec![
                section("s1", "A", vec![("x", hold(Some(2), "a"))]),
                section("s1", "B", vec![("x", hold(Some(2), "b"))]),
            ],
        );
        let m = messages(&p);
        assert_eq!(m[0].1, "B: another section already has the id 's1'");
        assert_eq!(
            m[1].1,
            "B, step 1: A, step 1 has the same id ('x'), so a step that returns held stitches \
             could name the wrong one"
        );
    }

    #[test]
    fn written_gives_headings_notes_and_empty_sections() {
        let mut p = pat(
            Some(8),
            8,
            0,
            vec![
                section("s1", "", vec![("a", work(Knit, WorkTo::End, false))]),
                section("s2", "Edge", vec![]),
            ],
        );
        p.sections[0].notes = "Use the small needle.".into();
        assert_eq!(
            to_written(&p),
            vec![
                "Cast on 8 sts.",
                "Section 1",
                "Notes: Use the small needle.",
                "Next row (RS): knit to end. (8 sts on the needle)",
                "Section 2: Edge",
                "(This section has no steps yet.)",
            ]
        );
    }

    #[test]
    fn validation_reports_the_ledger_and_still_checks_every_chart_row() {
        use crate::pattern::{Repeat, RepeatSpan};
        let mut p = pat(
            Some(8),
            8,
            2,
            vec![section(
                "s1",
                "Body",
                vec![("a", StepAction::ChartRows { first: 1, last: 1 })],
            )],
        );
        p.chart.rows[1].repeats.push(RepeatSpan {
            start: 0,
            end: 2,
            count: Repeat::Times(0),
        });
        let issues: Vec<String> = validate(&p).into_iter().map(|i| i.message).collect();
        assert_eq!(
            issues,
            vec![
                "row 2: the repeat over cols 1-2 is worked 0 times; a repeat must be worked at least once",
                "chart row 2 is not worked in any section, so the written instructions leave it out",
            ]
        );
    }
}
