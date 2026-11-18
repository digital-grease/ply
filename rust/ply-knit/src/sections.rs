//! KNITTING SECTIONS (M9-01; first slice: flat short rows and held stitches; second slice: work in
//! the round, sock heels, gussets and toes): an OPTIONAL construction layer above the chart, never a
//! replacement for it. A pattern may name sections ("Back", "Heel flap"), each an ordered list of
//! steps: work a range of the pattern's chart rows, cast on, bind off, work across in a plain
//! stitch, work whole rows or rounds, work a short row and turn (also relative to the gap, with a
//! decrease before the turn), put stitches on hold as a named group, return a group to the needle,
//! join the work in the round, work part of the round flat while the rest rests, pick up and knit
//! along an edge, divide the stitches into named needle groups, shape over several rows or rounds,
//! graft or bind off the last stitches together, or an unchecked written step in the pattern's own
//! words. A section may say whether it is worked flat or in the round. A pattern with no sections is
//! a chart-only pattern and behaves exactly as before.
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
//! **In the round.** A pattern worked in the round starts with its cast-on joined into a round (a
//! cast-on step onto an empty needle is joined too); a [`StepAction::JoinRound`] joins flat work.
//! The stitches are numbered from the start of the round, every round travels toward n from the
//! right side, and a round that reaches n ends there and the next starts at stitch 1: no turns.
//! [`StepAction::WorkFlat`] works the next stitches back and forth as a flat part (a heel flap) with
//! the needle model above, while the rest of the round RESTS on the needle (counted, never worked);
//! a join puts them back, waiting short-row stitches becoming ordinary stitches of the round (wraps
//! and double stitches stay where they are). Whole rows of a flat part, before its first short-row
//! turn, are counted per edge, so a pick-up along its side can say how many slipped edge stitches
//! that side has; Ply never guesses how many to pick up. A part's two sides are boundaries that move
//! with the stitches, so a pick-up along one is found wherever the work is, and
//! [`StepAction::RoundStart`] moves the start of the round keeping every place.
//!
//! **Needle groups.** [`StepAction::Groups`] names runs of stitches (the instep, the sole); every
//! step after it keeps each group's count exactly: held stitches go back into their groups, a
//! pick-up names its group, a shaping step names the groups it shapes, a cast-on over a gap takes the
//! held stitches' group. A step that changes the count where Ply cannot place the change between the
//! groups (an unchecked step, a chart row, a shaping step that names none, stitches added between
//! two groups) stops counting the groups, with a warning: it never picks a neighbour.
//!
//! **Unknown stays unknown.** An unchecked step that does not say how it changes the stitch count
//! makes every later count unknown (one warning); a chart row that cannot be counted does the same.
//!
//! **Pieces** (third slice, ADR 0020). A pattern may name its pieces ([`KnitPattern::pieces`]: the
//! body, the left sleeve, a thumb) and each section the piece it works ([`Section::piece`]; none:
//! the first piece, which the pattern's cast-on is for). The ledger keeps one needle per piece:
//! starting a section of another piece sets the current one aside where it is. Holders are shared,
//! so a piece can take up stitches another put on hold (the split of a raglan yoke, a thumb), and
//! [`StepAction::Join`] works another piece's stitches, or a held group, into the row where the work
//! is, with the right side facing (sleeves onto a yoke; a thumb from held stitches, then a pick-up).
//! Every count also lists the other pieces' stitches set aside, and a join only ever moves
//! stitches. [`Ledger::pieces`] says how each piece ends.
//!
//! The written form ([`written`]) and validation ([`crate::validate`]) both read this one ledger.

use std::collections::HashMap;
use std::sync::Arc;

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

/// The most needle groups one step may name or set (a sock has two or three).
pub const MAX_GROUPS: usize = 100;

/// The most pieces a pattern may have (a garment has a handful; a blanket of squares a few dozen),
/// and the longest a piece's name may be, in bytes: a set-aside piece is named in every count.
pub const MAX_PIECES: usize = 50;
pub const MAX_PIECE_NAME_BYTES: usize = 200;

/// Why a file's sections cannot be opened or saved ([`check_limits`]).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LimitError {
    /// Past one of the sizes a file may have.
    TooLarge(String),
    /// A piece's id, or a section's or a join's reference to one, is not a short id: 1 to 64
    /// letters, digits, `-` and `_`, starting with a letter or digit (the grammar of the materials
    /// ids, `ply_common::materials::is_valid_id`). Piece ids are new in schema version 6.
    BadPieceId(String),
}

impl std::fmt::Display for LimitError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            LimitError::TooLarge(why) | LimitError::BadPieceId(why) => f.write_str(why),
        }
    }
}

/// Whether `pattern`'s sections are within the sizes a file may have: at most [`MAX_SECTIONS`]
/// sections and [`MAX_STEPS`] steps, every id, name, note and text at most [`MAX_TEXT_BYTES`], and
/// every unchecked step's stitch change within [`MAX_LIVE_STITCHES`] either way (a larger one could
/// never be applied); at most [`MAX_PIECES`] pieces, each name at most [`MAX_PIECE_NAME_BYTES`];
/// and every piece id, and every reference to one, a short id ([`LimitError::BadPieceId`]). `Err`
/// says, in plain words, which rule a file breaks.
pub fn check_limits(pattern: &KnitPattern) -> Result<(), LimitError> {
    check_piece_ids(pattern)?;
    check_sizes(pattern).map_err(LimitError::TooLarge)
}

/// Piece ids and the references to them follow the short-id grammar.
fn check_piece_ids(pattern: &KnitPattern) -> Result<(), LimitError> {
    let valid = ply_common::materials::is_valid_id;
    let bad = |what: &str| {
        Err(LimitError::BadPieceId(format!(
            "{what} is not a piece id Ply can use (1 to 64 letters, digits, - and _, starting \
             with a letter or digit)"
        )))
    };
    if pattern.pieces.len() > MAX_PIECES {
        // Reported by the sizes check, without looking at every id.
        return Ok(());
    }
    if pattern.pieces.iter().any(|p| !valid(&p.id)) {
        return bad("a piece's id");
    }
    for s in &pattern.sections {
        if s.piece.as_deref().is_some_and(|id| !valid(id)) {
            return bad("the piece a section works");
        }
        for st in &s.steps {
            if let StepAction::Join {
                source: JoinSource::Piece(id),
                ..
            } = &st.action
            {
                if !valid(id) {
                    return bad("the piece a join step names");
                }
            }
        }
    }
    Ok(())
}

fn check_sizes(pattern: &KnitPattern) -> Result<(), String> {
    let pieces = &pattern.pieces;
    if pieces.len() > MAX_PIECES {
        return Err(format!(
            "the pattern has {} pieces; Ply opens at most {MAX_PIECES}",
            pieces.len()
        ));
    }
    for piece in pieces {
        if piece.name.len() > MAX_PIECE_NAME_BYTES {
            return Err(format!(
                "a piece's name is longer than {MAX_PIECE_NAME_BYTES} bytes"
            ));
        }
    }
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
        if long(&s.id) || long(&s.name) || long(&s.notes) || s.piece.as_deref().is_some_and(long) {
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
                    StepAction::WorkFlat { name, .. } => long(name),
                    StepAction::Rows { text, .. } => long(text),
                    StepAction::Shape { groups, text, .. } => {
                        long(text) || groups.iter().any(|g| long(g))
                    }
                    StepAction::PickUp { along, group, .. } => {
                        group.as_deref().is_some_and(long)
                            || match along {
                                PickUpAlong::Piece(t) | PickUpAlong::Edge(t) => long(t),
                            }
                    }
                    StepAction::Groups { groups } => {
                        groups.iter().any(|g| long(&g.name) || long(&g.notes))
                    }
                    StepAction::Join { source, .. } => match source {
                        JoinSource::Piece(t) | JoinSource::Held(t) => long(t),
                    },
                    StepAction::Close { holds, .. } => holds.iter().any(|h| long(h)),
                    _ => false,
                };
            if too_long {
                return Err(format!(
                    "a step's id or text is longer than {MAX_TEXT_BYTES} bytes"
                ));
            }
            let many = match &st.action {
                StepAction::Shape { groups, .. } => groups.len(),
                StepAction::Groups { groups } => groups.len(),
                StepAction::Close { holds, .. } => holds.len(),
                _ => 0,
            };
            if many > MAX_GROUPS {
                return Err(format!(
                    "a step names {many} needle groups; Ply opens at most {MAX_GROUPS}"
                ));
            }
            let change = match st.action {
                StepAction::Opaque {
                    stitch_change: Some(d),
                    ..
                } => Some(("an unchecked step", d)),
                StepAction::Shape { change, .. } => Some(("a shaping step", change)),
                _ => None,
            };
            if let Some((what, d)) = change {
                if d.unsigned_abs() > MAX_LIVE_STITCHES {
                    return Err(format!(
                        "{what} changes the stitch count by {d}; Ply counts at most \
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
    /// Whether the section is worked flat or in the round, when the pattern says (schema version
    /// 5; `None` for older files and when not stated). It is shown with the heading and checked at
    /// the section's start; the steps themselves join the work into the round
    /// ([`StepAction::JoinRound`]) or work part of it flat ([`StepAction::WorkFlat`]).
    pub construction: Option<Construction>,
    /// The id of the piece ([`KnitPattern::pieces`]) the section works (schema version 6). `None`:
    /// the first piece, the one the pattern's cast-on is for (in older files, the only piece).
    pub piece: Option<String>,
    pub steps: Vec<Step>,
}

/// A piece of the garment (the body, the left sleeve, a thumb), worked on its own needle by the
/// sections that name it (schema version 6). `id` is stable: it never changes on a rename or move.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Piece {
    pub id: String,
    pub name: String,
}

/// The stitches a [`StepAction::Join`] works into the row (schema version 6).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum JoinSource {
    /// Every live stitch of the piece with this id (a sleeve joined to the body for the yoke).
    Piece(String),
    /// The group put on hold by the step with this id (a thumb's held stitches).
    Held(String),
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
    /// Until this many stitches are left before the GAP: where an earlier short row on this side
    /// turned, the edge of the stitches waiting past that turn ("knit to 1 st before the gap").
    /// Schema version 5.
    BeforeGap(u32),
    /// Through the gap and this many stitches past it ("knit to 1 st past the gap"). Schema
    /// version 5.
    PastGap(u32),
}

/// A decrease that works two stitches together as one.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Decrease {
    K2tog,
    Ssk,
    P2tog,
    Ssp,
}

/// A decrease worked just before a short row turns, then `after` more stitches (a heel turn's
/// "ssk, k1, turn"). Schema version 5.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct TurnDecrease {
    pub kind: Decrease,
    pub after: u32,
}

/// How many times a shaping step shapes, or the stitch count it shapes to.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ShapeUntil {
    /// This many shaping rows or rounds.
    Times(u32),
    /// Until this many stitches are on the needle; it must be reachable by whole repeats.
    Remain(u32),
}

/// The edge a pick-up step picks up along.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum PickUpAlong {
    /// A side of the part worked flat by the step with this id (a [`StepAction::WorkFlat`], such
    /// as a heel flap). Ply finds which side from where the work is, and says how many slipped
    /// edge stitches or rows that side has when it knows.
    Piece(String),
    /// Any other edge, in the pattern's own words ("the cast-on edge").
    Edge(String),
}

/// A named group of stitches on the needle (the instep, the sole), with a note such as which
/// needles hold it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct NeedleGroup {
    pub name: String,
    pub count: u32,
    pub notes: String,
}

/// How a closing step finishes the last stitches.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum CloseMethod {
    /// Graft the two halves together with Kitchener stitch (a sock toe).
    Graft,
    /// Bind the two halves off together with a three-needle bind-off.
    ThreeNeedleBindOff,
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
    /// Work across, then turn before the end of the row. `decrease` (schema version 5; `None` in
    /// older files) is a decrease worked just before the turn, then a few more stitches, as a heel
    /// turn does ("knit to 1 st before the gap, ssk, k1, turn").
    ShortRow {
        stitch: WorkStitch,
        to: TurnAt,
        method: TurnMethod,
        resolve_turns: bool,
        decrease: Option<TurnDecrease>,
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
    // --- schema version 5: working in the round, sock heels and toes ---
    /// Join the stitches into a round (from flat work at the start of a row), or join a part worked
    /// flat ([`StepAction::WorkFlat`]) back into the round with the stitches that rested.
    JoinRound {},
    /// From the start of a round, work back and forth over the next `count` stitches (a heel flap);
    /// the others rest on the needle until a [`StepAction::JoinRound`]. `name` names the part
    /// ("heel flap"); `slip_edges`: the first stitch of every row is slipped, so each side has one
    /// slipped edge stitch for every two rows.
    WorkFlat {
        count: u32,
        name: String,
        slip_edges: bool,
    },
    /// Work `count` whole rows (flat) or rounds, from the start of a row or round, without
    /// changing the stitch count. `text` is the pattern's own words for them; Ply counts the rows
    /// and the stitches, not the stitches' names.
    Rows { count: u32, text: String },
    /// Work whole rows or rounds, changing the count by `change` stitches in each named group (or
    /// on the whole needle when `groups` is empty) on the first row and then every `every` rows,
    /// `until` a number of times or a stitch count. `text` is the pattern's own words for a shaping
    /// row ("k1, ssk, knit to last 3 sts, k2tog, k1"), not checked.
    Shape {
        change: i64,
        every: u32,
        until: ShapeUntil,
        groups: Vec<String>,
        text: String,
    },
    /// Pick up and knit `count` stitches along an edge, with the right side facing, onto the
    /// needle group `group` when the needle has groups. Ply never guesses a pick-up rate.
    PickUp {
        count: u32,
        along: PickUpAlong,
        group: Option<String>,
    },
    /// Divide the stitches into named needle groups, in working order from the start of the row
    /// or round; the counts must add up to the stitches on the needle. An empty list stops
    /// counting groups.
    Groups { groups: Vec<NeedleGroup> },
    /// Close the last stitches: graft the two halves together or bind them off together. With
    /// `holds` (schema version 6; `[]` in older files and for the stitches on the needle): close
    /// the two groups on hold that the hold steps with these ids made, against each other (the
    /// underarm stitches held on a body and on a sleeve), leaving the needle as it is.
    Close {
        method: CloseMethod,
        holds: Vec<String>,
    },
    /// Make the round start where the work is now, partway through a round ("knit 9 sts: this is
    /// the new start of the round", after a gusset pick-up); every stitch, group and side keeps its
    /// place. A part worked flat starts at the start of the round, so this also chooses where it
    /// starts.
    RoundStart {},
    // --- schema version 6: several pieces ---
    /// Work the stitches of another piece, or a group on hold, into the row where the work is, with
    /// the right side facing: they join this piece ("knit across the 54 sts of the left sleeve";
    /// onto an empty needle, a new piece's first row). `resolve_turns` works the wraps and double
    /// stitches among them, as a work step does.
    Join {
        source: JoinSource,
        stitch: WorkStitch,
        resolve_turns: bool,
    },
}

// --- ledger output ---------------------------------------------------------------------------------

/// A group of stitches on hold, as the ledger counts it: an index into [`LedgerNames::holds`] and
/// its count, so no line copies the group's name or its hold step's id.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct HeldCount {
    /// The group's index in [`LedgerNames::holds`] (the order the groups were put on hold).
    pub hold: usize,
    pub count: u64,
}

/// A group of stitches on hold, as the ledger names it (once, however many lines count it).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HoldName {
    /// The id of the step that put the group on hold, and that step's place.
    pub hold: String,
    pub section: usize,
    pub step: usize,
    /// The group's name as that step gives it.
    pub name: String,
}

/// The names a ledger's counts refer to by index: every group put on hold, every needle group
/// name, every piece (its display name). Each is stored once, so a ledger's memory grows with the
/// file, never with a name's length times the number of lines (ADR 0020 review).
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct LedgerNames {
    pub holds: Vec<HoldName>,
    pub groups: Vec<String>,
    pub pieces: Vec<String>,
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
    /// Stitches bound off so far from the piece being worked (with one piece: in the whole
    /// pattern).
    pub bound_off: u64,
    /// The side the row in progress (or the next row) is worked from, when known.
    pub side: Option<Side>,
    /// The work is in the round: `to_work` counts what is left of the round in progress.
    pub in_round: bool,
    /// The needle groups (instep, sole) and their stitches, in order from the start of the round
    /// or row; empty when the pattern has not divided the stitches into groups.
    pub groups: Vec<GroupCount>,
    /// While part of the round is worked flat ([`StepAction::WorkFlat`]): the stitches being worked
    /// flat. The rest of `on_needle` rests on the needle; `to_work` and `past_turns` count the
    /// flat part.
    pub flat: Option<u64>,
    /// Stitches grafted closed so far in the piece being worked (with one piece: in the whole
    /// pattern).
    pub grafted: u64,
    /// Every OTHER piece that still has stitches, set aside while this one is worked, in the
    /// pattern's piece order (schema version 6; empty for a pattern of one piece).
    pub set_aside: Vec<PieceCount>,
    /// Stitches bound off and grafted so far in the whole pattern, every piece together (the same
    /// as `bound_off` and `grafted` with one piece).
    pub bound_off_total: u64,
    pub grafted_total: u64,
    /// The names `held`, `groups` and `set_aside` refer to: one table shared by every line.
    pub names: Arc<LedgerNames>,
}

/// A piece set aside, as the ledger counts it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PieceCount {
    /// The piece's index in [`KnitPattern::pieces`] (and [`LedgerNames::pieces`]).
    pub piece: usize,
    /// Its live stitches (on its needle, a part worked flat included); `None` when its count is
    /// unknown.
    pub count: Option<u64>,
}

/// A needle group as the ledger counts it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct GroupCount {
    /// The group's name, as an index into [`LedgerNames::groups`].
    pub name: usize,
    pub count: u64,
}

/// The most entries of one list (needle groups, groups on hold) a count names; past it the count
/// gives how many and their stitches, so its text stays short whatever the file holds.
const NAMED_IN_COUNT: usize = 6;

/// The most pieces set aside that a count names.
const PIECES_IN_COUNT: usize = 3;

impl NeedleCount {
    /// Stitches on hold in all groups.
    pub fn held_total(&self) -> u64 {
        self.held.iter().map(|h| h.count).sum()
    }

    /// Stitches set aside on the other pieces, when every one of their counts is known.
    pub fn set_aside_total(&self) -> Option<u64> {
        self.set_aside.iter().map(|p| p.count).sum()
    }

    /// The name of a group on hold this count lists.
    pub fn hold_name(&self, h: &HeldCount) -> &str {
        self.names.holds.get(h.hold).map_or("", |x| x.name.as_str())
    }

    /// The name of a needle group this count lists.
    pub fn group_name(&self, g: &GroupCount) -> &str {
        self.names.groups.get(g.name).map_or("", String::as_str)
    }

    /// The display name of a piece this count lists as set aside.
    pub fn piece_name(&self, p: &PieceCount) -> &str {
        self.names.pieces.get(p.piece).map_or("", String::as_str)
    }

    /// The count as the written instructions give it, without brackets: `24 sts on the needle, 6
    /// waiting past a turn; 12 on hold; 6 bound off`, or with needle groups or a part worked flat
    /// `64 sts on the needle: 32 sole, 32 instep; 32 worked flat, 32 resting; 12 still to work in
    /// this row`. Names are shortened past [`SHORT_NAME_CHARS`], and a list past
    /// [`NAMED_IN_COUNT`] entries is given as a number, so the text is short whatever the file.
    pub fn text(&self) -> String {
        let unit = if self.in_round { "rnd" } else { "row" };
        let mut head = format!("{} on the needle", sts(self.on_needle));
        if self.groups.len() > NAMED_IN_COUNT {
            head.push_str(&format!(" in {} needle groups", self.groups.len()));
        } else if !self.groups.is_empty() {
            let parts: Vec<String> = self
                .groups
                .iter()
                .map(|g| format!("{} {}", g.count, display_name(self.group_name(g))))
                .collect();
            head.push_str(&format!(": {}", parts.join(", ")));
        }
        let mut parts = vec![head];
        if let Some(flat) = self.flat {
            parts.push(format!(
                "{flat} worked flat, {} resting",
                self.on_needle.saturating_sub(flat)
            ));
        }
        if self.mid_row && self.to_work > 0 {
            parts.push(format!("{} still to work in this {unit}", self.to_work));
        }
        if self.past_turns > 0 {
            parts.push(format!("{} waiting past a turn", self.past_turns));
        }
        // Slice-1 wording without groups or a flat part; semicolons once a list of groups or a
        // flat part would make commas ambiguous.
        let sep = if self.groups.is_empty() && self.flat.is_none() {
            ", "
        } else {
            "; "
        };
        let mut s = parts.join(sep);
        match self.held.as_slice() {
            [] => {}
            [one] => s.push_str(&format!("; {} on hold", one.count)),
            many if many.len() > NAMED_IN_COUNT => s.push_str(&format!(
                "; {} on hold in {} groups",
                sts(self.held_total()),
                many.len()
            )),
            many => {
                let parts: Vec<String> = many
                    .iter()
                    .map(|h| format!("{} {}", display_name(self.hold_name(h)), h.count))
                    .collect();
                s.push_str(&format!("; on hold: {}", parts.join(", ")));
            }
        }
        match self.set_aside.as_slice() {
            [] => {}
            few if few.len() <= PIECES_IN_COUNT => {
                let parts: Vec<String> = few
                    .iter()
                    .map(|p| match p.count {
                        Some(k) => format!("{} {k}", display_name(self.piece_name(p))),
                        None => format!("{} (count unknown)", display_name(self.piece_name(p))),
                    })
                    .collect();
                s.push_str(&format!("; set aside: {}", parts.join(", ")));
            }
            many => {
                let known: u64 = many.iter().filter_map(|p| p.count).sum();
                let unknown = many.iter().filter(|p| p.count.is_none()).count();
                s.push_str(&format!(
                    "; set aside in {} other pieces: {}",
                    many.len(),
                    sts(known)
                ));
                if unknown > 0 {
                    s.push_str(&format!(" (count unknown for {unknown} of them)"));
                }
            }
        }
        if self.bound_off > 0 {
            s.push_str(&format!("; {} bound off", self.bound_off));
        }
        if self.grafted > 0 {
            s.push_str(&format!("; {} grafted", self.grafted));
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
    /// The index in [`KnitPattern::pieces`] of the piece the line's section works (`None` for a
    /// pattern of one piece, or a section naming a piece the pattern does not have).
    pub piece: Option<usize>,
    /// How many whole rows or rounds the line works, when it is a step that works several and the
    /// ledger counted them (`Work 10 rows`, a shaping step over 32 rows); `None` for every other line
    /// (a progress tracker counts rows inside such a step, ADR 0023).
    pub rows: Option<u64>,
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
    /// How each of the pattern's pieces ends, in [`KnitPattern::pieces`] order (empty for a pattern
    /// of one piece).
    pub pieces: Vec<PieceSummary>,
    /// The names every line's count refers to by index (the same table each count holds).
    pub names: Arc<LedgerNames>,
}

/// A piece at the end of the ledger.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PieceSummary {
    /// The piece's index in [`KnitPattern::pieces`].
    pub piece: usize,
    /// The sections that work it, in order.
    pub sections: Vec<usize>,
    /// Its live stitches at the end (`None`: unknown). 0 once it was joined to another piece.
    pub live: Option<u64>,
    /// Where it was joined to another piece: that piece's index, and the join step's section and
    /// step.
    pub joined: Option<(usize, usize, usize)>,
    /// Its end in words: `18 sts left on the needle at the end`, `joined to the body at Yoke, step
    /// 3`, `no stitches left at the end`, `no section works this piece`.
    pub text: String,
}

/// A section's display name: its name, or `Section 2` when it has none.
pub fn section_title(pattern: &KnitPattern, section: usize) -> String {
    match pattern.sections.get(section).map(|s| s.name.trim()) {
        Some(name) if !name.is_empty() => name.to_string(),
        _ => format!("Section {}", section + 1),
    }
}

/// A piece's display name: its name, or `piece 2` when it has none.
pub fn piece_title(pattern: &KnitPattern, piece: usize) -> String {
    match pattern.pieces.get(piece).map(|p| p.name.trim()) {
        Some(name) if !name.is_empty() => name.to_string(),
        _ => format!("piece {}", piece + 1),
    }
}

/// The index in [`KnitPattern::pieces`] of the piece section `section` works: the piece it names,
/// or the first piece when it names none. `None` for a pattern of one piece (no pieces listed) and
/// for a section that names a piece the pattern does not have.
pub fn section_piece(pattern: &KnitPattern, section: usize) -> Option<usize> {
    if pattern.pieces.is_empty() {
        return None;
    }
    match pattern.sections.get(section)?.piece.as_deref() {
        None => Some(0),
        Some(id) => pattern.pieces.iter().position(|p| p.id == id),
    }
}

/// The heading line the written instructions give a section: `Section 1: Back`, or `Section 2`,
/// with the piece it works when the pattern has pieces and the section is not named after it, and
/// how it is worked when the section says (`Section 3: Heel flap (worked flat)`, `Section 5: Cuff
/// (left sleeve, worked in the round)`).
pub fn heading(pattern: &KnitPattern, section: usize) -> String {
    let name = pattern.sections.get(section).map_or("", |s| s.name.trim());
    let mut h = if name.is_empty() {
        format!("Section {}", section + 1)
    } else {
        format!("Section {}: {name}", section + 1)
    };
    let mut notes = Vec::new();
    if let Some(pi) = section_piece(pattern, section) {
        let piece = piece_title(pattern, pi);
        if !piece.eq_ignore_ascii_case(name) {
            notes.push(piece);
        }
    }
    match pattern.sections.get(section).and_then(|s| s.construction) {
        Some(Construction::Flat) => notes.push("worked flat".into()),
        Some(Construction::InTheRound) => notes.push("worked in the round".into()),
        None => {}
    }
    if !notes.is_empty() {
        h.push_str(&format!(" ({})", notes.join(", ")));
    }
    h
}

/// The line a pattern with pieces starts with: `Made in 3 pieces: body, left sleeve and right
/// sleeve. The cast-on below is for the body.` `None` for a pattern of one piece.
pub fn pieces_line(pattern: &KnitPattern) -> Option<String> {
    let n = pattern.pieces.len();
    if n == 0 {
        return None;
    }
    let names: Vec<String> = (0..n).map(|i| piece_title(pattern, i)).collect();
    let list = match names.as_slice() {
        [one] => one.clone(),
        [rest @ .., last] => format!("{} and {last}", rest.join(", ")),
        [] => String::new(),
    };
    let mut s = format!("Made in {}: {list}.", count_of(n as u64, "piece", "pieces"));
    if pattern.cast_on.is_some_and(|c| c > 0) {
        s.push_str(&format!(" The cast-on below is for {}.", names[0]));
    }
    Some(s)
}

/// The written instructions of a pattern with sections (see [`crate::to_written`]).
pub fn written(pattern: &KnitPattern) -> Vec<String> {
    let ledger = ledger(pattern);
    let mut out = Vec::with_capacity(ledger.lines.len() + 2 * pattern.sections.len() + 2);
    out.extend(pieces_line(pattern));
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
    let pieces = walk.summaries();
    // One table of names for the whole ledger, shared by every count.
    let names = Arc::new(std::mem::take(&mut walk.names));
    let mut lines = walk.lines;
    for line in &mut lines {
        if let LineCount::Counted(c) = &mut line.count {
            c.names = names.clone();
        }
    }
    Ledger {
        lines,
        issues: walk.issues,
        stopped: walk.stopped,
        pieces,
        names,
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
    /// The needle group the held stitches were in, so stitches cast on over the gap take their
    /// place in it.
    group: GapGroup,
}

/// The needle group of the stitches a gap was left by.
#[derive(Debug, Clone, PartialEq, Eq)]
enum GapGroup {
    /// The stitches were not in needle groups.
    None,
    One(String),
    /// They were in more than one group: Ply cannot tell which group stitches cast on over the gap
    /// belong to.
    Several,
}

/// A side of a part worked flat ([`StepAction::WorkFlat`]), as a boundary between stitches `at`
/// and `at + 1` (in the round, 0 is the start of the round). The right side is just before the
/// part's first stitch (where its right-side rows start), the left side just after its last. They
/// move with the stitches, so a pick-up along a side is found wherever the work is.
#[derive(Debug, Clone, PartialEq, Eq)]
struct SideMark {
    /// The id of the work-flat step.
    piece: String,
    left: bool,
    at: u64,
}

/// A run of `len` stitches of one needle group, in piece order.
#[derive(Debug, Clone, PartialEq, Eq)]
struct Seg {
    name: String,
    len: u64,
}

/// Which needle group stitches added to the needle join.
#[derive(Debug, Clone, Copy)]
enum Join<'s> {
    /// The group of the stitches either side of them, when that is one group (at an edge of flat
    /// work, the one beside them). Between two groups Ply cannot tell, and does not guess.
    Adjacent,
    /// The group with this name.
    Named(&'s str),
    /// The groups they were in when they were taken off the needle (held stitches returning; empty
    /// when they were held before the stitches were divided into groups, which Ply cannot place).
    Exact(&'s [Seg]),
    /// Ply cannot tell which group they belong to.
    Unknown,
}

/// Remove stitches `start..=end` (1-based) from the groups.
fn seg_remove(segs: &mut Vec<Seg>, start: u64, end: u64) {
    let mut pos = 0;
    for s in segs.iter_mut() {
        let (a, b) = (pos + 1, pos + s.len);
        pos += s.len;
        let (lo, hi) = (a.max(start), b.min(end));
        if lo <= hi {
            s.len -= hi - lo + 1;
        }
    }
    seg_tidy(segs);
}

/// The groups of stitches `start..=end` (1-based), as their own run.
fn seg_slice(segs: &[Seg], start: u64, end: u64) -> Vec<Seg> {
    let mut out = Vec::new();
    let mut pos = 0;
    for s in segs {
        let (a, b) = (pos + 1, pos + s.len);
        pos += s.len;
        let (lo, hi) = (a.max(start), b.min(end));
        if lo <= hi {
            out.push(Seg {
                name: s.name.clone(),
                len: hi - lo + 1,
            });
        }
    }
    out
}

/// Split the groups at boundary `at` (0..=total) and return the index where a run inserted there
/// goes.
fn seg_split(segs: &mut Vec<Seg>, at: u64) -> usize {
    let mut pos = 0;
    for i in 0..segs.len() {
        if pos == at {
            return i;
        }
        let end = pos + segs[i].len;
        if at < end {
            let head = at - pos;
            let tail = Seg {
                name: segs[i].name.clone(),
                len: segs[i].len - head,
            };
            segs[i].len = head;
            segs.insert(i + 1, tail);
            return i + 1;
        }
        pos = end;
    }
    segs.len()
}

/// The group of stitch `pos` (1-based).
fn seg_at(segs: &[Seg], pos: u64) -> Option<&str> {
    let mut end = 0;
    for s in segs {
        end += s.len;
        if pos <= end {
            return Some(&s.name);
        }
    }
    None
}

/// Add `k` stitches at boundary `at` (0..=the stitches the groups cover before) to the group `join`
/// says. `round`: the stitches either side of boundary 0 are the last and the first. `fresh`: the
/// needle had no stitches, so a returning group's run becomes the needle's groups. Returns false,
/// changing nothing, when Ply cannot tell which group they join (the caller then stops counting the
/// groups, with a warning); true otherwise, and always when there are no groups.
fn seg_insert(segs: &mut Vec<Seg>, at: u64, k: u64, join: Join, round: bool, fresh: bool) -> bool {
    if k == 0 {
        return true;
    }
    if let (Join::Exact(run), true) = (join, fresh) {
        *segs = run.to_vec();
        return true;
    }
    if segs.is_empty() {
        return true;
    }
    let name = match join {
        Join::Exact(run) if !run.is_empty() => {
            let i = seg_split(segs, at);
            for (j, s) in run.iter().enumerate() {
                segs.insert(i + j, s.clone());
            }
            seg_tidy(segs);
            return true;
        }
        Join::Exact(_) | Join::Unknown => return false,
        Join::Named(name) => name.to_string(),
        Join::Adjacent => {
            let total: u64 = segs.iter().map(|s| s.len).sum();
            let before = if at > 0 {
                seg_at(segs, at)
            } else if round {
                seg_at(segs, total)
            } else {
                None
            };
            let after = if at < total {
                seg_at(segs, at + 1)
            } else if round {
                seg_at(segs, 1)
            } else {
                None
            };
            match (before, after) {
                (Some(a), Some(b)) if a == b => a.to_string(),
                (Some(a), None) | (None, Some(a)) => a.to_string(),
                _ => return false,
            }
        }
    };
    let i = seg_split(segs, at);
    if i > 0 && segs[i - 1].name == name {
        segs[i - 1].len += k;
    } else if i < segs.len() && segs[i].name == name {
        segs[i].len += k;
    } else {
        segs.insert(i, Seg { name, len: k });
    }
    seg_tidy(segs);
    true
}

/// Drop empty runs and merge neighbours of the same group.
fn seg_tidy(segs: &mut Vec<Seg>) {
    segs.retain(|s| s.len > 0);
    let mut out: Vec<Seg> = Vec::with_capacity(segs.len());
    for s in segs.drain(..) {
        match out.last_mut() {
            Some(last) if last.name == s.name => last.len += s.len,
            _ => out.push(s),
        }
    }
    *segs = out;
}

/// A needle group by name with its stitches added up, borrowed from the runs (no name is copied).
#[derive(Debug, Clone, Copy)]
struct NamedCount<'a> {
    name: &'a str,
    count: u64,
}

/// The groups by name, in the order they first appear, with their stitches added up.
fn group_counts<'a>(runs: impl IntoIterator<Item = &'a Seg>) -> Vec<NamedCount<'a>> {
    let mut out: Vec<NamedCount<'a>> = Vec::new();
    for s in runs {
        match out.iter_mut().find(|g| g.name == s.name) {
            Some(g) => g.count += s.len,
            None => out.push(NamedCount {
                name: &s.name,
                count: s.len,
            }),
        }
    }
    out
}

/// Change the group `name` by `delta` stitches, shared out over its runs (a group can sit either
/// side of the start of the round). The caller has checked that the group keeps at least one
/// stitch. Only counts change: the shaping steps that use this have worked across every wrap and
/// gap first.
fn seg_change(segs: &mut Vec<Seg>, name: &str, delta: i64) {
    let runs: Vec<usize> = (0..segs.len()).filter(|&i| segs[i].name == name).collect();
    if runs.is_empty() || delta == 0 {
        return;
    }
    let mut left = delta.unsigned_abs();
    if delta > 0 {
        let m = runs.len() as u64;
        for (j, &i) in runs.iter().enumerate() {
            segs[i].len += left / m + u64::from((j as u64) < left % m);
        }
        left = 0;
    }
    while left > 0 {
        let active: Vec<usize> = runs.iter().copied().filter(|&i| segs[i].len > 0).collect();
        if active.is_empty() {
            break;
        }
        let share = (left / active.len() as u64).max(1);
        for i in active {
            let take = share.min(segs[i].len).min(left);
            segs[i].len -= take;
            left -= take;
            if left == 0 {
                break;
            }
        }
    }
    seg_tidy(segs);
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
    /// The work is in the round: stitches 1..=n in round order from the start of the round, every
    /// round worked from the right side toward n, and no turns.
    round: bool,
    /// The needle groups over stitches 1..=n, or empty when the stitches are not in groups.
    segs: Vec<Seg>,
    /// The row in progress started at an edge, travelling toward n (`true`) or toward 1.
    edge_row: Option<bool>,
    /// Whole rows worked from edge to edge before the first short-row turn: those that started at
    /// the low edge (`[0]`) and at the high edge (`[1]`). They make the needle's two sides.
    full_rows: [u64; 2],
    /// A short-row turn was made on this needle; later rows no longer add to its sides.
    sides_frozen: bool,
    /// The sides of parts worked flat on this needle (in the round, normalized below n).
    sides: Vec<SideMark>,
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
            round: false,
            segs: Vec::new(),
            edge_row: None,
            full_rows: [0, 0],
            sides_frozen: false,
            sides: Vec::new(),
        }
    }

    /// A fresh round of `n` stitches, at the start of the round.
    fn fresh_round(n: u64) -> Self {
        let mut needle = Needle::fresh(n, Some(Side::Rs));
        needle.round = true;
        needle
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

    /// Stitches still on the left needle in this row (in the round: in this round).
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
        if self.round {
            return Some(Side::Rs);
        }
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

    /// The work is at the start edge of the needle (not at a short-row turn); in the round, at the
    /// start of the round.
    fn at_edge(&self) -> bool {
        if self.up {
            self.c == 0
        } else {
            self.c == self.n
        }
    }

    /// Stitches waiting past a turn ahead of the work in this row: the gap an earlier short row on
    /// this side left is just before them.
    fn waiting_ahead(&self) -> u64 {
        if self.up {
            self.hi
        } else {
            self.lo
        }
    }

    /// Whether the stitch `offset` stitches ahead of the work (1 = the next one) carries a mark of
    /// `kind`.
    fn mark_ahead(&self, offset: u64, kind: Pending) -> bool {
        let pos = if self.up {
            self.c.checked_add(offset)
        } else {
            (self.c + 1).checked_sub(offset)
        };
        pos.is_some_and(|p| self.marks.iter().any(|m| m.pos == p && m.kind == kind))
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
        let round = self.round;
        let crossed_gaps = take(&mut self.gaps, |g| {
            let inside = if up {
                g.at > c && g.at < c + k
            } else {
                g.at + k > c && g.at < c
            };
            // In the round a round begins where the last one ended, so its first stitch is reached
            // across a gap at the start of the round.
            let round_start = round && g.at == 0 && c == 0 && k > 0;
            inside || (g.at == c && yarn && k > 0) || round_start
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
    /// stitches they carry, with their 1-based offsets in the removed run, and their groups.
    fn remove_ahead(&mut self, k: u64) -> (Vec<(u64, Mark)>, Vec<Seg>) {
        let start = if self.up { self.c + 1 } else { self.c + 1 - k };
        let end = start + k - 1;
        let groups = seg_slice(&self.segs, start, end);
        seg_remove(&mut self.segs, start, end);
        self.sides_removed(start, end);
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
        (taken, groups)
    }

    /// Insert `k` new stitches at the boundary: ahead (on the left needle, worked next) or behind
    /// (on the right needle). `marks` are offsets in the inserted run; `join` says which needle
    /// group they join. Returns a gap it closed, and false when Ply cannot tell which needle group
    /// the stitches join (the needle groups are then not kept up to date: stop counting them).
    fn insert(
        &mut self,
        k: u64,
        ahead: bool,
        marks: &[(u64, Mark)],
        join: Join,
    ) -> (Option<Gap>, bool) {
        let c = self.c;
        let grouped = seg_insert(&mut self.segs, c, k, join, self.round, self.n == 0);
        // A part's right side is just before its first stitch, so stitches added there come before
        // it; its left side is just after its last, so they come after it.
        for side in &mut self.sides {
            if side.at > c || (side.at == c && !side.left) {
                side.at += k;
            }
        }
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
        self.norm_sides();
        (closed, grouped)
    }

    /// Add `k` stitches after stitch n (the end of the round), joining `join`'s group. The work's
    /// position does not change. False when Ply cannot tell the group (as [`Needle::insert`]).
    fn append(&mut self, k: u64, join: Join) -> (Option<Gap>, bool) {
        let n = self.n;
        // In the round, stitches added after the last one go where a gap at the start of the round
        // is, and close it.
        let closed = if self.round {
            take(&mut self.gaps, |g| g.at == 0).into_iter().next()
        } else {
            None
        };
        let grouped = seg_insert(&mut self.segs, n, k, join, self.round, n == 0);
        // The boundary at the start of the round is just after stitch n: a part whose last stitch
        // is stitch n keeps its left side there, before the new stitches; a part whose first stitch
        // is stitch 1 keeps its right side at the start of the round, after them.
        for side in &mut self.sides {
            if side.left && (side.at == 0 || side.at == n) {
                side.at = n;
            }
        }
        self.n += k;
        (closed, grouped)
    }

    /// Move the boundaries of the sides of parts worked flat after stitches `start..=end` are taken
    /// off: those past them move down, those inside close up to where the stitches were.
    fn sides_removed(&mut self, start: u64, end: u64) {
        let k = end + 1 - start;
        for side in &mut self.sides {
            if side.at >= end {
                side.at -= k;
            } else if side.at >= start {
                side.at = start - 1;
            }
        }
    }

    /// The stitches between boundaries `lo_b` and `hi_b` changed by `delta` at places Ply does not
    /// know: sides at or before `lo_b` stay, sides at or after `hi_b` move by `delta`, and sides
    /// strictly between are no longer known (dropped, so a pick-up there is refused, not guessed).
    fn sides_resized(&mut self, lo_b: u64, hi_b: u64, delta: i64) {
        if delta == 0 {
            return;
        }
        self.sides.retain(|x| x.at <= lo_b || x.at >= hi_b);
        for x in &mut self.sides {
            if x.at >= hi_b && x.at > lo_b {
                x.at = x.at.saturating_add_signed(delta);
            }
        }
    }

    /// In the round the boundary after stitch n is the start of the round, 0.
    fn norm_sides(&mut self) {
        if self.round {
            let n = self.n;
            for side in &mut self.sides {
                if side.at >= n {
                    side.at = 0;
                }
            }
        }
    }

    /// Make the round start where the work is (`0 < c < n`, in the round): every stitch, wrap, gap,
    /// group and side keeps its place, numbered from the new start.
    fn rotate(&mut self) {
        let (n, c) = (self.n, self.c);
        for m in &mut self.marks {
            m.pos = (m.pos + n - c - 1) % n + 1;
        }
        for g in &mut self.gaps {
            g.at = (g.at + n - c) % n;
        }
        for side in &mut self.sides {
            side.at = (side.at + n - c) % n;
        }
        let i = seg_split(&mut self.segs, c);
        let head: Vec<Seg> = self.segs.drain(..i).collect();
        self.segs.extend(head);
        seg_tidy(&mut self.segs);
        self.c = 0;
        self.row_start = true;
        self.yarn_here = false;
        self.edge_row = None;
        self.tidy();
    }

    /// Take `k` stitches off the right needle (`k <= rh`), nearest the boundary first.
    fn remove_behind(&mut self, k: u64) {
        let start = if self.up { self.c + 1 - k } else { self.c + 1 };
        let end = start + k - 1;
        seg_remove(&mut self.segs, start, end);
        self.sides_removed(start, end);
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

    /// Turn the work where it is: everything past the boundary is left unworked. `end_of_row`: the
    /// row reached the end of the needle (so a row begun at the other edge is a whole row and adds
    /// to that side); otherwise it is a short-row turn, after which rows no longer add to the sides.
    fn turn(&mut self, end_of_row: bool) {
        match self.edge_row.take() {
            Some(from_low) if end_of_row && !self.sides_frozen => {
                self.full_rows[usize::from(!from_low)] += 1;
            }
            _ => {}
        }
        if !end_of_row {
            self.sides_frozen = true;
        }
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
    /// has ended, and the work turns; a round with nothing left ends at the start of the round, and
    /// the next round begins there.
    fn settle(&mut self) {
        if self.n == 0 {
            *self = Needle::empty();
        } else if self.lh() == 0 {
            if self.round {
                self.c = 0;
                self.row_start = true;
                self.yarn_here = false;
                self.edge_row = None;
            } else {
                self.turn(true);
            }
        }
    }

    /// Work `rows` whole rows (or rounds) from the start of a row at an edge: the first crosses
    /// every wrap, double stitch and gap on the needle (returned), and the rest are the same rows
    /// again. Whole rows before the first short-row turn add to the needle's sides.
    fn whole_rows(&mut self, rows: u64) -> (Vec<Mark>, Vec<Gap>) {
        self.row_start = false;
        self.edge_row = Some(self.up);
        let k = self.lh();
        let crossed = self.traverse(k);
        self.settle();
        if !self.round && rows > 1 {
            let more = rows - 1;
            if more % 2 == 1 {
                self.row_start = false;
                self.edge_row = Some(self.up);
                let k = self.lh();
                self.traverse(k);
                self.settle();
            }
            if !self.sides_frozen {
                self.full_rows[0] += more / 2;
                self.full_rows[1] += more / 2;
            }
        }
        crossed
    }

    /// Turn the needle end for end, so stitch n becomes stitch 1: the same stitches, numbered the
    /// other way (used when joining flat work whose right-side rows travel toward stitch 1).
    fn mirror(&mut self) {
        let n = self.n;
        for m in &mut self.marks {
            m.pos = n + 1 - m.pos;
        }
        for g in &mut self.gaps {
            g.at = n - g.at;
        }
        for side in &mut self.sides {
            side.at = n - side.at;
        }
        self.segs.reverse();
        self.c = n - self.c;
        self.up = !self.up;
        std::mem::swap(&mut self.lo, &mut self.hi);
        self.up_side = self.up_side.map(Side::other);
        self.full_rows.swap(0, 1);
        self.edge_row = self.edge_row.map(|u| !u);
    }

    /// Drop gaps that are no longer between two stitches, and duplicates. In the round the last
    /// stitch and the first are next to each other: a gap there is at boundary 0 (the start of
    /// the round), wherever it was recorded (ADR 0020 review).
    fn tidy(&mut self) {
        let n = self.n;
        if self.round {
            for g in &mut self.gaps {
                if g.at >= n {
                    g.at = 0;
                }
            }
            self.gaps.retain(|_| n > 0);
        } else {
            self.gaps.retain(|g| g.at > 0 && g.at < n);
        }
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
    /// The needle groups the stitches were in, so they go back into them.
    segs: Vec<Seg>,
    resumed: Option<(usize, usize)>,
    /// Right-side rows travelled toward the group's last stitch when it was put on hold (`None`:
    /// not known), so a join that knits it from the right side keeps its needle groups in order.
    rs_up: Option<bool>,
    /// Put on hold from a needle whose count was known. A group held while it was not has only the
    /// count its step states, unchecked: no count lists it, and a piece that takes it up is not
    /// counted after (with one piece the whole ledger was unknown by then anyway).
    checked: bool,
}

/// One piece's needle while another piece is worked (ADR 0020): the walk keeps the current piece's
/// needle in [`Walk::needle`] and [`Walk::rest`], and every other piece's here.
#[derive(Debug, Clone)]
struct Slot {
    /// `None`: the count is unknown.
    needle: Option<Needle>,
    rest: Option<Rest>,
    /// The piece was joined to another: that piece's index, and the join step's section and step.
    joined: Option<(usize, usize, usize)>,
    /// The sections that work this piece, in order.
    sections: Vec<usize>,
}

impl Slot {
    fn empty() -> Self {
        Slot {
            needle: Some(Needle::empty()),
            rest: None,
            joined: None,
            sections: Vec::new(),
        }
    }

    /// Its live stitches (`None`: unknown).
    fn live(&self) -> Option<u64> {
        let rest = self.rest.as_ref().map_or(0, |r| r.count);
        self.needle.as_ref().map(|n| n.n + rest)
    }
}

/// The stitches resting on the needle while part of the round is worked flat
/// ([`StepAction::WorkFlat`]): they follow the flat part in round order, and a
/// [`StepAction::JoinRound`] puts them back into the round.
#[derive(Debug, Clone)]
struct Rest {
    /// The id of the step that started working flat.
    step: String,
    count: u64,
    /// Their wraps and double stitches, by 1-based offset in the resting run.
    marks: Vec<(u64, Mark)>,
    segs: Vec<Seg>,
    /// Gaps among them (left by stitches put on hold), by boundary in the resting run: 0 is
    /// between the flat part's last stitch and the first resting stitch.
    gaps: Vec<Gap>,
    /// Sides of earlier parts worked flat among them, likewise.
    sides: Vec<SideMark>,
}

/// A part worked flat, as a pick-up along its sides needs it.
#[derive(Debug, Clone)]
struct PieceRecord {
    slip_edges: bool,
    /// Whole rows that started at its right edge (the start of its right-side rows) and at its
    /// left edge, before its first short-row turn (filled in when it is joined back into the
    /// round; while it is worked, the needle has them).
    rows: [u64; 2],
    /// Its right and left sides have been picked up along.
    picked: [bool; 2],
}

struct Walk<'a> {
    p: &'a KnitPattern,
    /// `None`: the count is unknown (sticky).
    needle: Option<Needle>,
    /// While part of the round is worked flat: the stitches resting outside it. `needle` is then
    /// the part worked flat.
    rest: Option<Rest>,
    /// Every part worked flat so far, by the id of the step that started it.
    pieces: HashMap<String, PieceRecord>,
    /// A cast-on onto an empty needle is joined into the round (the pattern is worked in the round).
    default_round: bool,
    bound_off: u64,
    grafted: u64,
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
    /// Every piece's needle (ADR 0020), by its index in `p.pieces` (one slot when the pattern lists
    /// none), then one slot for a section that names a piece the pattern does not have. The current
    /// piece's slot is stale: its needle is [`Walk::needle`] and [`Walk::rest`].
    slots: Vec<Slot>,
    /// The slot being worked.
    cur: usize,
    /// The piece of the last section walked (its index in `p.pieces`).
    last_piece: Option<usize>,
    /// The current piece's needle was put back in its slot (the walk is over).
    parked: bool,
    /// The names counts refer to by index, and where each needle group name is in it.
    names: LedgerNames,
    group_index: HashMap<String, usize>,
    /// An empty table each count holds until the walk is over (then the ledger's own).
    no_names: Arc<LedgerNames>,
    /// Stitches bound off and grafted in each piece's slot.
    piece_bound: Vec<u64>,
    piece_grafted: Vec<u64>,
}

impl<'a> Walk<'a> {
    fn new(p: &'a KnitPattern) -> Self {
        let pieces = p.pieces.len().max(1);
        let mut slots = vec![Slot::empty(); pieces];
        slots.push(Slot {
            needle: None,
            ..Slot::empty()
        });
        let n_slots = slots.len();
        Walk {
            slots,
            cur: 0,
            last_piece: None,
            parked: false,
            names: LedgerNames {
                holds: Vec::new(),
                groups: Vec::new(),
                pieces: (0..p.pieces.len()).map(|i| piece_title(p, i)).collect(),
            },
            group_index: HashMap::new(),
            no_names: Arc::default(),
            piece_bound: vec![0; n_slots],
            piece_grafted: vec![0; n_slots],
            p,
            needle: None,
            rest: None,
            pieces: HashMap::new(),
            default_round: p.construction == Construction::InTheRound,
            bound_off: 0,
            grafted: 0,
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
        // The pattern's cast-on is on the needle before the first section: flat, its first row from
        // the pattern's first-row side, or joined into a round.
        self.needle = match p.cast_on {
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
            Some(n) if n > 0 => Some(match p.construction {
                Construction::Flat => Needle::fresh(u64::from(n), Some(p.first_row_side)),
                Construction::InTheRound => Needle::fresh_round(u64::from(n)),
            }),
            _ => Some(Needle::empty()),
        };
        for (si, section) in p.sections.iter().enumerate() {
            self.short_no = 0;
            self.make_ds = None;
            self.enter(si);
            self.check_construction(si, section);
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

    /// The slot of the piece a section works: its piece (the first when it names none), or the
    /// slot for a piece the pattern does not have.
    fn slot_of(&self, si: usize) -> usize {
        let orphan = self.slots.len() - 1;
        match (self.p.pieces.is_empty(), &self.p.sections[si].piece) {
            (true, None) => 0,
            (true, Some(_)) => orphan,
            (false, _) => section_piece(self.p, si).unwrap_or(orphan),
        }
    }

    /// Take up the needle of the piece section `si` works, setting the current piece's aside (ADR
    /// 0020). A section naming a piece the pattern does not have is an error, and its steps are
    /// counted on an unknown needle that nothing else shares.
    fn enter(&mut self, si: usize) {
        let target = self.slot_of(si);
        let orphan = self.slots.len() - 1;
        if target != self.cur {
            self.slots[self.cur].needle = self.needle.take();
            self.slots[self.cur].rest = self.rest.take();
            self.needle = self.slots[target].needle.take();
            self.rest = self.slots[target].rest.take();
            self.cur = target;
        }
        if target == orphan {
            self.needle = None;
            self.rest = None;
            self.last_piece = None;
            self.error(
                Some(si),
                None,
                None,
                "works a piece the pattern does not have (it may have been deleted), so its steps \
                 are not counted; choose one of the pattern's pieces"
                    .into(),
            );
            return;
        }
        self.slots[target].sections.push(si);
        self.last_piece = (!self.p.pieces.is_empty()).then_some(target);
    }

    /// The piece being worked was joined to another (that piece, and the join's section and step):
    /// every step of its sections is refused (ADR 0020 review).
    fn joined_here(&self) -> Option<(usize, usize, usize)> {
        if self.in_orphan() {
            return None;
        }
        self.slots.get(self.cur).and_then(|s| s.joined)
    }

    /// No step of this section is applied: its piece is missing, or was joined to another. Its
    /// steps are still walked for their words, on an unknown needle, and take nothing.
    fn suppressed(&self) -> bool {
        self.in_orphan() || self.joined_here().is_some()
    }

    /// The pattern lists pieces and the current section works one of them: its index.
    fn cur_piece(&self) -> Option<usize> {
        (!self.p.pieces.is_empty() && self.cur < self.p.pieces.len()).then_some(self.cur)
    }

    /// A section that says how it is worked: the work must already be worked that way when it
    /// starts, or its first step must make it so (a warning otherwise; nothing is changed).
    fn check_construction(&mut self, si: usize, section: &Section) {
        let Some(declared) = section.construction else {
            return;
        };
        let Some(needle) = &self.needle else {
            return;
        };
        if needle.n == 0 && self.rest.is_none() {
            return;
        }
        let round = needle.round;
        let first = section.steps.first().map(|s| &s.action);
        match declared {
            Construction::InTheRound
                if !round && !matches!(first, Some(StepAction::JoinRound {})) =>
            {
                self.warn(
                    Some(si),
                    None,
                    None,
                    "the section is marked as worked in the round, but the work is flat when it \
                     starts; start the section with a step that joins the work into the round, or \
                     mark it as worked flat"
                        .into(),
                )
            }
            Construction::Flat if round && !matches!(first, Some(StepAction::WorkFlat { .. })) => {
                self.warn(
                    Some(si),
                    None,
                    None,
                    "the section is marked as worked flat, but the work is in the round when it \
                     starts; start the section with a step that works part of the stitches flat, \
                     or mark it as worked in the round"
                        .into(),
                )
            }
            _ => {}
        }
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
            .filter(|g| g.resumed.is_none() && g.checked)
            .filter_map(|g| g.count)
            .sum()
    }

    /// The current section works a piece the pattern does not have.
    fn in_orphan(&self) -> bool {
        self.cur == self.slots.len() - 1
    }

    /// Whether adding `k` stitches to the needle would put more than [`MAX_LIVE_STITCHES`] on the
    /// needle and on hold.
    fn too_big(&self, k: u64) -> bool {
        let n = self.needle.as_ref().map_or(0, |n| n.n);
        let rest = self.rest.as_ref().map_or(0, |r| r.count);
        n.saturating_add(rest)
            .saturating_add(self.held_total())
            .saturating_add(self.others_total())
            .saturating_add(k)
            > MAX_LIVE_STITCHES
    }

    /// Stitches on every other piece's needle (an unknown count counts 0: its stitches were
    /// counted against the cap while they were known).
    fn others_total(&self) -> u64 {
        self.slots
            .iter()
            .enumerate()
            .filter(|&(i, _)| i != self.cur)
            .filter_map(|(_, s)| s.live())
            .fold(0u64, u64::saturating_add)
    }

    /// The other pieces that still have stitches, as a count lists them.
    fn set_aside(&self) -> Vec<PieceCount> {
        (0..self.p.pieces.len())
            .filter(|&i| i != self.cur)
            .filter_map(|i| {
                let count = self.slots[i].live();
                (count != Some(0)).then_some(PieceCount { piece: i, count })
            })
            .collect()
    }

    /// The side a row toward stitch n is worked from on a fresh needle: the pattern's first-row side,
    /// or, in a part worked flat, the right side (its rows start that way).
    fn first_side(&self) -> Side {
        if self.rest.is_some() {
            Side::Rs
        } else {
            self.p.first_row_side
        }
    }

    /// Why a step that works stitches cannot: nothing is on the needle (or, while part of the round
    /// is worked flat, nothing is left in that part).
    fn no_stitches_here(&self) -> String {
        match &self.rest {
            Some(rest) => format!(
                "there are no stitches left in the part worked flat; join the work back into the \
                 round to work the {} resting there",
                stitches(rest.count)
            ),
            None => no_stitches(),
        }
    }

    /// Every needle group's runs, the part worked flat first and then the stitches resting.
    fn all_segs(&self) -> Vec<&Seg> {
        let needle = self.needle.iter().flat_map(|n| n.segs.iter());
        let rest = self.rest.iter().flat_map(|r| r.segs.iter());
        needle.chain(rest).collect()
    }

    /// The names of the needle groups, in order.
    fn group_names(&self) -> Vec<String> {
        group_counts(self.all_segs())
            .into_iter()
            .map(|g| g.name.to_string())
            .collect()
    }

    /// How many needle groups the stitches being worked are in (while part of the round is worked
    /// flat, that part's groups; its steps never change the resting stitches).
    fn worked_groups(&self) -> usize {
        self.needle
            .as_ref()
            .map_or(0, |n| group_counts(n.segs.iter()).len())
    }

    /// Stop counting needle groups (a step changes the count in a way Ply cannot place between
    /// them), with one warning naming them.
    fn drop_groups(&mut self, si: usize, ti: usize, row: Option<usize>, why: &str) {
        let names = self.group_names();
        if names.is_empty() {
            return;
        }
        if let Some(n) = self.needle.as_mut() {
            n.segs.clear();
        }
        if let Some(r) = self.rest.as_mut() {
            r.segs.clear();
        }
        self.warn(
            Some(si),
            Some(ti),
            row,
            format!(
                "{why}, so Ply cannot tell how the change falls between the needle groups ({}); it \
                 stops counting the groups here (divide the stitches into groups again to count \
                 them)",
                listed(&names)
            ),
        );
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
        // Pieces are named by id too (by sections and joins).
        let mut piece_ids: Vec<(&str, usize)> = Vec::new();
        for (i, piece) in p.pieces.iter().enumerate() {
            if piece.id.trim().is_empty() {
                let text = format!("{} has no id", capitalize(&self.the_piece(i)));
                self.error(None, None, None, text);
            } else if let Some(&(_, first)) = piece_ids.iter().find(|(id, _)| *id == piece.id) {
                let text = format!(
                    "{} and {} have the same id ('{}'), so a section or join naming it works {}",
                    capitalize(&self.the_piece(first)),
                    self.the_piece(i),
                    piece.id,
                    self.the_piece(first)
                );
                self.error(None, None, None, text);
            } else {
                piece_ids.push((&piece.id, i));
            }
        }
    }

    // --- issues and lines ---

    fn place(&self, si: usize, ti: Option<usize>, row: Option<usize>) -> String {
        // Shortened: every message about a step names its section.
        let mut s = short(&section_title(self.p, si), SECTION_IN_MESSAGE_CHARS);
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
    fn snapshot(&mut self) -> LineCount {
        // Needle group names are kept once, in the ledger's table; a count holds their indices.
        let names: Vec<(String, u64)> = group_counts(self.all_segs())
            .into_iter()
            .filter(|g| !self.group_index.contains_key(g.name))
            .map(|g| (g.name.to_string(), g.count))
            .collect();
        for (name, _) in names {
            self.group_index
                .insert(name.clone(), self.names.groups.len());
            self.names.groups.push(name);
        }
        let Some(needle) = &self.needle else {
            return LineCount::Unknown;
        };
        let held = self
            .groups
            .iter()
            .enumerate()
            .filter(|(_, g)| g.resumed.is_none() && g.checked)
            .map(|(i, g)| HeldCount {
                hold: i,
                count: g.count.unwrap_or(0),
            })
            .collect();
        let groups = group_counts(self.all_segs())
            .into_iter()
            .map(|g| GroupCount {
                name: self.group_index.get(g.name).copied().unwrap_or(0),
                count: g.count,
            })
            .collect();
        let rest = self.rest.as_ref();
        LineCount::Counted(NeedleCount {
            on_needle: needle.n + rest.map_or(0, |r| r.count),
            to_work: needle.lh(),
            mid_row: !needle.row_start && needle.n > 0,
            past_turns: needle.lo + needle.hi,
            pending_turns: (needle.marks.len() + rest.map_or(0, |r| r.marks.len())) as u64,
            held,
            bound_off: self.piece_bound[self.cur],
            side: needle.side(),
            in_round: needle.round,
            groups,
            flat: rest.map(|_| needle.n),
            grafted: self.piece_grafted[self.cur],
            set_aside: self.set_aside(),
            bound_off_total: self.bound_off,
            grafted_total: self.grafted,
            names: self.no_names.clone(),
        })
    }

    /// Bind off or graft `k` stitches of the current piece: the pattern's totals and the piece's.
    /// The caller has checked that the pattern's total does not overflow.
    fn add_closed(&mut self, graft: bool, k: u64) {
        if graft {
            self.grafted += k;
            self.piece_grafted[self.cur] += k;
        } else {
            self.bound_off += k;
            self.piece_bound[self.cur] += k;
        }
    }

    /// Put a group on hold, naming it once in the ledger's table.
    fn push_group(&mut self, si: usize, ti: usize, group: Group) {
        self.names.holds.push(HoldName {
            hold: group.hold.clone(),
            section: si,
            step: ti,
            name: group.name.clone(),
        });
        self.groups.push(group);
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
        let piece = self.cur_piece();
        self.lines.push(LedgerLine {
            section: si,
            step: ti,
            chart_row: row,
            label,
            text,
            opaque,
            count,
            piece,
            rows: None,
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
        needle.edge_row = needle.at_edge().then_some(needle.up);
        if needle.round {
            self.short_no = 0;
            return Some("Next rnd".to_string());
        }
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
        if let Some((into, js, jt)) = self.joined_here() {
            return self.refuse_joined(si, ti, step, into, js, jt);
        }
        // A pending double stitch is this step's to mention, or the turn line's.
        self.ds_now = self.make_ds.take();
        self.dispatch(si, ti, step);
        if let Some(line) = self.ds_now.take() {
            self.ds_on_turn_line(line);
        }
    }

    /// A step of a piece that was joined to another: refused, in its own words, changing nothing.
    /// Its words come from walking it on an unknown needle (which takes nothing, see
    /// [`Walk::suppressed`]); whatever that walk says is dropped for the one problem.
    fn refuse_joined(
        &mut self,
        si: usize,
        ti: usize,
        step: &'a Step,
        into: usize,
        js: usize,
        jt: usize,
    ) {
        let needle = self.needle.take();
        let rest = self.rest.take();
        let (lines, issues, ds) = (self.lines.len(), self.issues.len(), self.make_ds);
        self.ds_now = None;
        self.dispatch(si, ti, step);
        self.ds_now = None;
        self.make_ds = ds;
        self.issues.truncate(issues);
        for line in &mut self.lines[lines..] {
            line.count = LineCount::NotCounted;
        }
        self.needle = needle;
        self.rest = rest;
        let problem = format!(
            "{} was joined to {} at {}, so it cannot be worked again; start a new piece instead",
            self.the_piece(self.cur),
            self.the_piece(into),
            self.place(js, Some(jt), None)
        );
        self.error(Some(si), Some(ti), None, problem);
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
                decrease,
            } => self.short_row(si, ti, *stitch, *to, *method, *resolve_turns, *decrease),
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
            StepAction::JoinRound {} => self.join_round(si, ti),
            StepAction::WorkFlat {
                count,
                name,
                slip_edges,
            } => self.work_flat(si, ti, step, *count, name, *slip_edges),
            StepAction::Rows { count, text } => self.rows(si, ti, *count, text),
            StepAction::Shape {
                change,
                every,
                until,
                groups,
                text,
            } => self.shape(si, ti, *change, *every, *until, groups, text),
            StepAction::PickUp {
                count,
                along,
                group,
            } => self.pick_up(si, ti, *count, along, group.as_deref()),
            StepAction::Groups { groups } => self.set_groups(si, ti, groups),
            StepAction::Close { method, holds } => {
                if holds.is_empty() {
                    self.close(si, ti, *method)
                } else {
                    self.close_held(si, ti, *method, holds)
                }
            }
            StepAction::RoundStart {} => self.round_start(si, ti),
            StepAction::Join {
                source,
                stitch,
                resolve_turns,
            } => self.join(si, ti, source, *stitch, *resolve_turns),
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
            let problem = self.no_stitches_here();
            return self.refuse(si, ti, base, problem);
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

    #[allow(clippy::too_many_arguments)]
    fn short_row(
        &mut self,
        si: usize,
        ti: usize,
        stitch: WorkStitch,
        to: TurnAt,
        method: TurnMethod,
        resolve: bool,
        decrease: Option<TurnDecrease>,
    ) {
        let dec_part = decrease.map_or(String::new(), |d| decrease_text(stitch, d));
        let turn_part = match method {
            TurnMethod::WrapAndTurn => ", wrap and turn",
            TurnMethod::German | TurnMethod::Unspecified => ", turn",
        };
        let generic = turn_work_text(stitch, to, None);
        let base = format!("{generic}{dec_part}{turn_part}");
        let Some(needle) = &self.needle else {
            return self.unknown_line(si, ti, base);
        };
        if needle.n == 0 {
            let problem = self.no_stitches_here();
            return self.refuse(si, ti, base, problem);
        }
        if needle.round {
            return self.refuse(
                si,
                ti,
                base,
                "turns partway through a round; to work short rows over part of the round (a \
                 short-row heel), first add a step that works part of the stitches flat"
                    .into(),
            );
        }
        let lh = needle.lh();
        let gap_form = matches!(to, TurnAt::BeforeGap(_) | TurnAt::PastGap(_));
        let k = if decrease.is_none() && !gap_form {
            // The first slice's forms, checked exactly as before.
            let reach = match to {
                TurnAt::Last(m) => WorkTo::Last(m),
                TurnAt::Count(m) => WorkTo::Count(m),
                _ => unreachable!("not a gap form"),
            };
            let nothing_past = match to {
                TurnAt::Last(m) => m == 0,
                TurnAt::Count(m) => u64::from(m) == lh,
                _ => false,
            };
            if nothing_past {
                return self.refuse(si, ti, base, nothing_past_problem());
            }
            match Self::reach(lh, reach) {
                Ok(k) => k,
                Err(problem) => {
                    let problem = match to {
                        TurnAt::Last(m) if u64::from(m) == lh => format!(
                            "turns before working any stitches: the last {} are all that is left \
                             to work in this row",
                            stitches(lh)
                        ),
                        TurnAt::Count(0) => "turns before working any stitches".to_string(),
                        _ => problem,
                    };
                    return self.refuse(si, ti, base, problem);
                }
            }
        } else {
            match Self::turn_reach(needle, to) {
                Ok(k) => k,
                Err(problem) => return self.refuse(si, ti, base, problem),
            }
        };
        // What the decrease and the stitches after it take, and what is left past the turn.
        let dec_used = decrease.map_or(0, |d| 2 + u64::from(d.after));
        if dec_used > lh - k {
            return self.refuse(
                si,
                ti,
                base,
                format!(
                    "has no room for the decrease: it needs {} after the first {}, but only {} \
                     left in this row",
                    stitches(dec_used),
                    stitches(k),
                    are_count(lh - k)
                ),
            );
        }
        let used = k + dec_used;
        if used == 0 {
            return self.refuse(si, ti, base, "turns before working any stitches".into());
        }
        let past = lh - used;
        // A turn relative to the gap may come out at the end of the row (the last rows of a heel
        // turn): with a plain "turn" that is just the end of the row. Every other turn needs a
        // stitch past it.
        let ends_row = past == 0;
        if ends_row && !(gap_form && method == TurnMethod::Unspecified) {
            return self.refuse(si, ti, base, nothing_past_problem());
        }
        // The decrease makes two stitches one, so it leaves one fewer on the right needle.
        let decreased = u64::from(decrease.is_some());
        if method == TurnMethod::German && needle.rh() + used - decreased < 2 {
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
        let work_part = turn_work_text(stitch, to, Some(needle));
        let label = self.take_label(true);
        let work_part = if label.is_some() {
            self.with_double_stitch(work_part)
        } else {
            work_part
        };
        let needle = self.needle.as_mut().expect("counting");
        let (mut marks, mut gaps) = needle.traverse(k);
        if let Some(d) = decrease {
            // Two stitches worked together: the one nearest the boundary is the one that goes.
            let (m, g) = needle.traverse(2);
            marks.extend(m);
            gaps.extend(g);
            needle.remove_behind(1);
            let (m, g) = needle.traverse(u64::from(d.after));
            marks.extend(m);
            gaps.extend(g);
        }
        // Any resolving phrase belongs to the stitches worked, before the turn.
        let worked = format!("{work_part}{dec_part}");
        let mut text = self.crossings(si, ti, None, worked, &marks, &gaps, resolve, true);
        text.push_str(turn_part);
        let needle = self.needle.as_mut().expect("counting");
        if ends_row {
            needle.turn(false);
        } else {
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
            needle.turn(false);
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
        }
        let count = self.snapshot();
        let line = self.push_line(si, ti, None, label, text, true, false, count);
        if method == TurnMethod::German && !ends_row {
            self.make_ds = Some(line);
        }
    }

    /// The stitches a gap-relative short row works before its decrease (or its turn), or the
    /// problem that stops it. Also the first slice's forms when they come with a decrease.
    fn turn_reach(needle: &Needle, to: TurnAt) -> Result<u64, String> {
        let lh = needle.lh();
        let ahead = needle.waiting_ahead();
        let no_gap = || {
            "works to the gap an earlier short row left, but no stitches are waiting past a turn \
             ahead in this row"
                .to_string()
        };
        match to {
            TurnAt::Last(m) => {
                let m = u64::from(m);
                if m > lh {
                    Err(format!(
                        "works to the last {}, but {}",
                        stitches(m),
                        only_left(lh)
                    ))
                } else {
                    Ok(lh - m)
                }
            }
            TurnAt::Count(0) => Err("works 0 stitches".into()),
            TurnAt::Count(m) => {
                let m = u64::from(m);
                if m > lh {
                    Err(format!("works {}, but {}", stitches(m), only_left(lh)))
                } else {
                    Ok(m)
                }
            }
            TurnAt::BeforeGap(m) => {
                if ahead == 0 {
                    return Err(no_gap());
                }
                let before = lh - ahead;
                let m = u64::from(m);
                if m > before {
                    Err(format!(
                        "works to {} before the gap, but only {} before it",
                        stitches(m),
                        are_count(before)
                    ))
                } else {
                    Ok(before - m)
                }
            }
            TurnAt::PastGap(m) => {
                if ahead == 0 {
                    return Err(no_gap());
                }
                let m = u64::from(m);
                if m > ahead {
                    Err(format!(
                        "works {} past the gap, but only {} waiting past it",
                        stitches(m),
                        are_count(ahead)
                    ))
                } else {
                    Ok(lh - ahead + m)
                }
            }
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
        let text = if needle.n == 0 && self.default_round && self.rest.is_none() {
            // A pattern worked in the round joins a new cast-on into a round.
            self.needle = Some(Needle::fresh_round(k));
            format!(
                "cast on {} and join to work in the round, being careful not to twist",
                sts(k)
            )
        } else if needle.n == 0 {
            // A new piece: its first row is worked from the side the pattern's first row is (a
            // part worked flat: from the right side, as the part's rows are).
            let first = self.first_side();
            self.needle = Some(Needle::fresh(k, Some(first)));
            format!("cast on {}", sts(k))
        } else if needle.row_start && needle.round && needle.gaps.iter().any(|g| g.at == 0) {
            // In the round, over a gap at the start of the round (the stitches before or after it
            // went on hold): onto the right needle there, at the end of the round, in the group of
            // the stitches held from it (ADR 0020 review).
            let gap_group = needle
                .gaps
                .iter()
                .find(|g| g.at == 0)
                .map(|g| g.group.clone());
            let join = match &gap_group {
                Some(GapGroup::One(name)) => Join::Named(name),
                Some(GapGroup::Several) => Join::Unknown,
                Some(GapGroup::None) | None => Join::Adjacent,
            };
            let (closed, grouped) = self.needle.as_mut().expect("counting").append(k, join);
            if !grouped {
                let why = if matches!(gap_group, Some(GapGroup::Several)) {
                    "this step casts on over a gap left by stitches from more than one needle group"
                } else {
                    "this step casts on stitches between two needle groups"
                };
                self.drop_groups(si, ti, None, why);
            }
            match closed {
                Some(gap) => format!(
                    "cast on {} onto the right needle, over the gap left by the stitches on hold \
                     ({})",
                    sts(k),
                    display_name(&gap.name)
                ),
                None => format!("cast on {} onto the right needle", sts(k)),
            }
        } else if needle.row_start {
            let unit = if needle.round { "rnd" } else { "row" };
            let (_, grouped) =
                self.needle
                    .as_mut()
                    .expect("counting")
                    .insert(k, true, &[], Join::Adjacent);
            if !grouped {
                self.drop_groups(
                    si,
                    ti,
                    None,
                    "this step casts on stitches between two needle groups",
                );
            }
            format!("cast on {} at the start of the {unit}", sts(k))
        } else {
            // Over a gap, the new stitches take the place of the held ones, in their group.
            let c = needle.c;
            let gap_group = needle
                .gaps
                .iter()
                .find(|g| g.at == c)
                .map(|g| g.group.clone());
            let join = match &gap_group {
                Some(GapGroup::One(name)) => Join::Named(name),
                Some(GapGroup::Several) => Join::Unknown,
                Some(GapGroup::None) | None => Join::Adjacent,
            };
            let (closed, grouped) =
                self.needle
                    .as_mut()
                    .expect("counting")
                    .insert(k, false, &[], join);
            if !grouped {
                let why = if matches!(gap_group, Some(GapGroup::Several)) {
                    "this step casts on over a gap left by stitches from more than one needle group"
                } else {
                    "this step casts on stitches between two needle groups"
                };
                self.drop_groups(si, ti, None, why);
            }
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
            let problem = self.no_stitches_here();
            return self.refuse(si, ti, asked, problem);
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
        let mut marks: Vec<Mark> = needle
            .remove_ahead(k)
            .0
            .into_iter()
            .map(|(_, m)| m)
            .collect();
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
        let _ = total;
        self.add_closed(false, k);
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
            if self.suppressed() {
                // Not put on hold: a later step that returns them says so.
                self.failed_holds.push(step.id.clone());
                return self.unknown_line(si, ti, fallback);
            }
            self.push_group(
                si,
                ti,
                Group {
                    hold: step.id.clone(),
                    name: name.to_string(),
                    count: count.map(u64::from),
                    marks: Vec::new(),
                    segs: Vec::new(),
                    resumed: None,
                    rs_up: None,
                    checked: false,
                },
            );
            return self.unknown_line(si, ti, fallback);
        };
        if needle.n == 0 {
            self.failed_holds.push(step.id.clone());
            let problem = self.no_stitches_here();
            return self.refuse(si, ti, fallback, problem);
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
        // Which way right-side rows travel along these stitches, for a join that knits them.
        let rs_up = if needle.round {
            Some(true)
        } else if needle.unoriented {
            None
        } else {
            needle.up_side.map(|s| s == Side::Rs)
        };
        let (marks, segs) = needle.remove_ahead(k);
        // In the round the stitches either side of the held ones are always neighbours, even when
        // the held ones started or ended the round (the gap is then at the start of the round).
        if (needle.rh() > 0 && needle.lh() > 0) || (needle.round && needle.n > 0) {
            let group = match group_counts(segs.iter()).as_slice() {
                [] => GapGroup::None,
                [one] => GapGroup::One(one.name.to_string()),
                _ => GapGroup::Several,
            };
            needle.gaps.push(Gap {
                at: needle.c,
                name: name.to_string(),
                group,
            });
            needle.tidy();
        }
        needle.settle();
        self.push_group(
            si,
            ti,
            Group {
                hold: step.id.clone(),
                name: name.to_string(),
                count: Some(k),
                marks,
                segs,
                resumed: None,
                rs_up,
                checked: true,
            },
        );
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
        let shown = shown(name);
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
            // Taken by a join (ADR 0020), which knits them, or returned by a return step.
            let did = match p.sections[rs].steps.get(rt).map(|st| &st.action) {
                Some(StepAction::Join { .. }) => "already knitted them into the work",
                _ => "already returned them to the needle",
            };
            return self.refuse(
                si,
                ti,
                text_for(self.groups[gi].count, false),
                format!("returns the stitches on hold{shown}, but {other} {did}"),
            );
        }
        let group = self.groups[gi].clone();
        let Some(needle) = &self.needle else {
            // Taken all the same, so a later step does not take it twice (not in a section whose
            // piece is missing: once that is fixed, the section is walked again).
            if !self.suppressed() {
                self.groups[gi].resumed = Some((si, ti));
            }
            return self.unknown_line(si, ti, text_for(group.count, false));
        };
        if !group.checked {
            // Held while its piece's count was unknown (only possible with several pieces).
            self.groups[gi].resumed = Some((si, ti));
            self.warn(
                Some(si),
                Some(ti),
                None,
                format!(
                    "the stitches on hold{shown} were put on hold while the stitch count was \
                     unknown, so the count after returning them is unknown too"
                ),
            );
            self.needle = None;
            return self.unknown_line(si, ti, text_for(group.count, false));
        }
        // Moving stitches from the holder to the needle keeps the total, which the cap already holds.
        let k = group.count.unwrap_or(0);
        let empty = needle.n == 0;
        let text = text_for(Some(k), empty);
        if empty {
            // The group keeps its piece order: from the other side, its first row starts at the
            // last stitch, so a wrap lands where the knitter meets it.
            let mut fresh = Needle::facing(k, facing, self.first_side());
            for (offset, m) in &group.marks {
                fresh.marks.push(Mark {
                    pos: *offset,
                    kind: m.kind,
                });
            }
            fresh.segs = group.segs.clone();
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
                    let first = self.first_side();
                    self.needle.as_mut().expect("counting").set_side(f, first)
                }
                _ => {}
            }
            let (_, grouped) = self.needle.as_mut().expect("counting").insert(
                k,
                true,
                &group.marks,
                Join::Exact(&group.segs),
            );
            if !grouped {
                self.drop_groups(
                    si,
                    ti,
                    None,
                    "these stitches were put on hold before the stitches were divided into needle \
                     groups",
                );
            }
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
        // Applied below only once it fits; then the groups go when it changes the count.
        let regroup = change != 0 && self.worked_groups() > 1;
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
            if regroup {
                self.drop_groups(si, ti, None, "this step adds stitches in its own words");
            }
            let (_, grouped) =
                self.needle
                    .as_mut()
                    .expect("counting")
                    .insert(k, at_start, &[], Join::Adjacent);
            if !grouped {
                self.drop_groups(
                    si,
                    ti,
                    None,
                    "this step adds stitches between two needle groups",
                );
            }
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
            if regroup {
                self.drop_groups(si, ti, None, "this step removes stitches in its own words");
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
            let problem = self.no_stitches_here();
            return refuse(self, label, body, problem);
        }
        let chart_round = self.p.construction == Construction::InTheRound;
        if chart_round != needle.round {
            let problem = if chart_round {
                "the chart is for working in the round, but the work is flat here; use knit, purl \
                 or row steps for the part worked flat"
            } else {
                "the chart is for working flat (it has wrong-side rows), but the work is in the \
                 round here; use knit, purl or row steps for the rounds"
            };
            return refuse(self, label, body, problem.into());
        }
        if !needle.row_start {
            let problem = if needle.round {
                format!(
                    "a chart round has to start at the beginning of a round, but this round is \
                     already started ({} still to work in it)",
                    stitches(needle.lh())
                )
            } else {
                format!(
                    "a chart row has to start at the beginning of a row, but this row is already \
                     started ({} still to work in it)",
                    stitches(needle.lh())
                )
            };
            return refuse(self, label, body, problem);
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
        let resting = self.rest.as_ref().map_or(0, |r| r.count);
        if new_n
            .saturating_add(self.held_total())
            .saturating_add(resting)
            > MAX_LIVE_STITCHES
        {
            return refuse(self, label, body, too_many());
        }
        if side_unknown {
            let first = self.first_side();
            self.needle
                .as_mut()
                .expect("counting")
                .set_side(chart_side, first);
        }
        {
            let needle = self.needle.as_mut().expect("counting");
            needle.row_start = false;
            needle.edge_row = at_edge.then_some(needle.up);
        }
        let body = self.with_double_stitch(body);
        // A row that changes the count: the groups follow it only when there is one group.
        if count.produced != count.consumed && self.worked_groups() > 1 {
            self.drop_groups(si, ti, Some(r), "this chart row changes the stitch count");
        }
        let needle = self.needle.as_mut().expect("counting");
        let up = needle.up;
        if count.produced != count.consumed {
            if let Some(name) = needle.segs.first().map(|s| s.name.clone()) {
                needle.segs = vec![Seg { name, len: new_n }];
            }
        }
        // The sides of parts worked flat at the ends of the worked run keep their places; Ply cannot
        // tell where one inside it falls once the row changes the count.
        let (lo_b, hi_b) = if up {
            (needle.c, needle.c + lh)
        } else {
            (needle.c - lh, needle.c)
        };
        needle.sides_resized(lo_b, hi_b, count.produced as i64 - lh as i64);
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
        let Some(needle) = &self.needle else {
            return;
        };
        // What the checks read, without copying the needle (its groups may have long names).
        struct Ends {
            n: u64,
            row_start: bool,
            round: bool,
            lh: u64,
            lo: u64,
            hi: u64,
            kinds: Vec<Pending>,
        }
        let needle = Ends {
            n: needle.n,
            row_start: needle.row_start,
            round: needle.round,
            lh: needle.lh(),
            lo: needle.lo,
            hi: needle.hi,
            kinds: needle.marks.iter().map(|m| m.kind).collect(),
        };
        if needle.n > 0 && !needle.row_start {
            self.warn(
                Some(si),
                None,
                None,
                format!(
                    "ends part way through a {}, with {} still to work in it",
                    if needle.round { "round" } else { "row" },
                    stitches(needle.lh)
                ),
            );
        }
        let waiting = needle.lo + needle.hi;
        let mut kinds: Vec<Pending> = needle.kinds;
        if let Some(rest) = &self.rest {
            kinds.extend(rest.marks.iter().map(|(_, m)| m.kind));
        }
        if waiting > 0 || !kinds.is_empty() {
            let wraps = kinds.iter().filter(|k| **k == Pending::Wrap).count() as u64;
            let doubles = kinds.len() as u64 - wraps;
            let mut parts = Vec::new();
            if waiting > 0 {
                parts.push(format!(
                    "{} {} still waiting past a turn",
                    stitches(waiting),
                    if waiting == 1 { "is" } else { "are" }
                ));
            }
            if wraps > 0 {
                parts.push(format!(
                    "{} not yet worked together with {}",
                    count_of(wraps, "wrap is", "wraps are"),
                    if wraps == 1 {
                        "its stitch"
                    } else {
                        "their stitches"
                    }
                ));
            }
            if doubles > 0 {
                parts.push(format!(
                    "{} not yet worked as one stitch",
                    count_of(doubles, "double stitch is", "double stitches are")
                ));
            }
            self.warn(
                Some(si),
                None,
                None,
                format!(
                    "ends with short rows not yet worked across: {}",
                    parts.join(", and ")
                ),
            );
        }
    }

    fn end_pattern(&mut self) {
        // Every piece's needle back in its slot, the current one included.
        self.park();
        let orphan = self.slots.len() - 1;
        let rests: Vec<Rest> = self.slots[..orphan]
            .iter()
            .filter_map(|s| s.rest.clone())
            .collect();
        for rest in rests {
            if let Some(&(ws, wt)) = self.by_id.get(rest.step.as_str()) {
                self.warn(
                    Some(ws),
                    Some(wt),
                    None,
                    format!(
                        "{} {} still resting on the needle at the end of the pattern; no step joins \
                         them back into the round",
                        stitches(rest.count),
                        if rest.count == 1 { "is" } else { "are" }
                    ),
                );
            }
        }
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
            let shown = shown(&g.name);
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
        self.end_pieces();
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

// --- the walk: working in the round, sock heels and toes (schema version 5) ---------------------

/// Where a pick-up goes, from where the work is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum PickPlace {
    /// Partway through a right-side row or a round: onto the right needle where the work is.
    Mid,
    /// At the start of a round: after the last stitch, ending the round before it.
    RoundEnd,
    /// Just after a right-side row reached the edge (the work has turned): onto that row's end.
    RowEnd,
    /// At the start of a right-side row, at its edge: the row begins with them.
    RowStart,
    /// Onto an empty needle: they are the needle's first row, a right-side row.
    Empty,
}

impl<'a> Walk<'a> {
    fn join_round(&mut self, si: usize, ti: usize) {
        let Some(needle) = &self.needle else {
            return self.unknown_line(si, ti, "join to work in the round".into());
        };
        if self.rest.is_some() {
            return self.rejoin(si, ti);
        }
        let generic = "join to work in the round, being careful not to twist".to_string();
        if needle.n == 0 {
            return self.refuse(si, ti, generic, no_stitches());
        }
        if needle.round {
            return self.refuse(si, ti, generic, "the work is already in the round".into());
        }
        if !needle.row_start {
            let problem = format!(
                "joins the work into the round partway through a row ({} still to work in it); \
                 join at the end of a row",
                stitches(needle.lh())
            );
            return self.refuse(si, ti, generic, problem);
        }
        if !needle.at_edge() {
            return self.refuse(
                si,
                ti,
                generic,
                "joins the work into the round at a short-row turn; work to the end of the row \
                 first"
                    .into(),
            );
        }
        if needle.up_side.is_none() {
            return self.refuse(si, ti, generic, side_unknown_problem());
        }
        let needle = self.needle.as_mut().expect("counting");
        // Rounds travel toward stitch n, from the right side.
        if needle.up_side == Some(Side::Ws) {
            needle.mirror();
        }
        // At the start of a wrong-side row the right-side row just ended here: the round goes on
        // from it instead of turning, so the next round starts at stitch 1.
        needle.round = true;
        needle.up = true;
        needle.up_side = Some(Side::Rs);
        needle.c = 0;
        needle.lo = 0;
        needle.hi = 0;
        needle.row_start = true;
        needle.yarn_here = false;
        needle.edge_row = None;
        let count = self.snapshot();
        self.push_line(si, ti, None, None, generic, true, false, count);
    }

    /// Join the part worked flat back into the round, with the stitches that rested.
    fn rejoin(&mut self, si: usize, ti: usize) {
        let rest = self.rest.clone().expect("working flat");
        let needle = self.needle.as_ref().expect("counting");
        let total = needle.n + rest.count;
        let text = format!("join to work in the round again over all {}", sts(total));
        if needle.n > 0 {
            match needle.up_side {
                Some(Side::Rs) => {}
                None => return self.refuse(si, ti, text, side_unknown_problem()),
                Some(Side::Ws) => {
                    return self.refuse(
                        si,
                        ti,
                        text,
                        "the part worked flat is turned the other way round from the round (its \
                         right-side rows run back toward the start of the round), so Ply cannot \
                         join it back in"
                            .into(),
                    )
                }
            }
            let row_end = !needle.up && needle.row_start && needle.c == needle.n;
            if !needle.up && !row_end {
                return self.refuse(
                    si,
                    ti,
                    text,
                    "joins the work back into the round partway through a wrong-side row, but \
                     rounds are worked from the right side; join at the end of a right-side row"
                        .into(),
                );
            }
        }
        if let Some(rec) = self.pieces.get_mut(&rest.step) {
            let needle = self.needle.as_ref().expect("counting");
            rec.rows = needle.full_rows;
        }
        // The groups of the part and of the stitches that rested must both be known to go on
        // counting them (all the stitches may have been worked flat, with none resting).
        let part_groups = self.needle.as_ref().is_some_and(|n| !n.segs.is_empty());
        let rest_groups = !rest.segs.is_empty();
        let part_n = self.needle.as_ref().map_or(0, |n| n.n);
        if part_n > 0 && rest.count > 0 && part_groups != rest_groups {
            self.drop_groups(
                si,
                ti,
                None,
                "the stitches worked flat and the stitches that rested are not both in needle groups",
            );
        }
        let rest_segs = self.rest.as_ref().map_or_else(Vec::new, |r| r.segs.clone());
        let needle = self.needle.as_mut().expect("counting");
        let empty_part = needle.n == 0;
        if empty_part {
            *needle = Needle::fresh_round(0);
        }
        // Waiting stitches and short-row turns end with the flat part: the rounds work every
        // stitch as they come to it. Wraps and double stitches stay where they are.
        let mid = needle.c > 0;
        let piece_n = needle.n;
        needle.round = true;
        needle.up = true;
        needle.up_side = Some(Side::Rs);
        needle.lo = 0;
        needle.hi = 0;
        needle.unoriented = false;
        needle.edge_row = None;
        if empty_part {
            needle.segs = rest_segs;
        } else if !needle.segs.is_empty() {
            needle.segs.extend(rest_segs);
            seg_tidy(&mut needle.segs);
        }
        for (offset, m) in &rest.marks {
            needle.marks.push(Mark {
                pos: piece_n + offset,
                kind: m.kind,
            });
        }
        for g in &rest.gaps {
            needle.gaps.push(Gap {
                at: piece_n + g.at,
                ..g.clone()
            });
        }
        for x in &rest.sides {
            needle.sides.push(SideMark {
                at: piece_n + x.at,
                ..x.clone()
            });
        }
        needle.n += rest.count;
        needle.norm_sides();
        needle.tidy();
        needle.row_start = !mid;
        needle.yarn_here = mid;
        needle.settle();
        self.rest = None;
        let count = self.snapshot();
        self.push_line(si, ti, None, None, text, true, false, count);
    }

    fn work_flat(
        &mut self,
        si: usize,
        ti: usize,
        step: &Step,
        count: u32,
        name: &str,
        slip_edges: bool,
    ) {
        let m = u64::from(count);
        let what = match name.trim() {
            "" => String::new(),
            n => format!(" for the {n}"),
        };
        let slip = if slip_edges {
            ", slipping the first st of every row"
        } else {
            ""
        };
        let generic = format!("work back and forth over the next {}{what}{slip}", sts(m));
        let Some(needle) = &self.needle else {
            return self.unknown_line(si, ti, generic);
        };
        if needle.n == 0 {
            let problem = self.no_stitches_here();
            return self.refuse(si, ti, generic, problem);
        }
        if self.rest.is_some() {
            return self.refuse(
                si,
                ti,
                generic,
                "part of the round is already worked flat; join it back into the round first"
                    .into(),
            );
        }
        if !needle.round {
            return self.refuse(
                si,
                ti,
                generic,
                "works part of the stitches flat, but the work is already flat; put the other \
                 stitches on hold instead"
                    .into(),
            );
        }
        if needle.c != 0 || !needle.row_start {
            let problem = format!(
                "starts working flat partway through a round ({} still to work in it); Ply starts \
                 a part worked flat at the start of the round",
                stitches(needle.lh())
            );
            return self.refuse(si, ti, generic, problem);
        }
        if m == 0 {
            return self.refuse(
                si,
                ti,
                generic,
                "works 0 stitches flat; work at least 1".into(),
            );
        }
        let n = needle.n;
        if m > n {
            let problem = format!(
                "works {} flat, but the round has only {}",
                stitches(m),
                stitches(n)
            );
            return self.refuse(si, ti, generic, problem);
        }
        let old = needle;
        let mut piece = Needle::fresh(m, Some(Side::Rs));
        piece.marks = old.marks.iter().copied().filter(|k| k.pos <= m).collect();
        piece.gaps = old.gaps.iter().filter(|g| g.at < m).cloned().collect();
        piece.segs = seg_slice(&old.segs, 1, m);
        // Earlier sides in the part stay with it; the new part's sides are its two ends.
        piece.sides = old.sides.iter().filter(|x| x.at <= m).cloned().collect();
        piece.sides.push(SideMark {
            piece: step.id.clone(),
            left: false,
            at: 0,
        });
        piece.sides.push(SideMark {
            piece: step.id.clone(),
            left: true,
            at: m,
        });
        let offset = |at: u64| at - m;
        let rest = Rest {
            step: step.id.clone(),
            count: n - m,
            marks: old
                .marks
                .iter()
                .filter(|k| k.pos > m)
                .map(|k| (k.pos - m, *k))
                .collect(),
            segs: seg_slice(&old.segs, m + 1, n),
            gaps: old
                .gaps
                .iter()
                .filter(|g| g.at >= m)
                .map(|g| Gap {
                    at: offset(g.at),
                    ..g.clone()
                })
                .collect(),
            sides: old
                .sides
                .iter()
                .filter(|x| x.at > m)
                .map(|x| SideMark {
                    at: offset(x.at),
                    ..x.clone()
                })
                .collect(),
        };
        self.needle = Some(piece);
        self.rest = Some(rest);
        self.pieces.insert(
            step.id.clone(),
            PieceRecord {
                slip_edges,
                rows: [0, 0],
                picked: [false, false],
            },
        );
        let text = if n == m {
            format!("work back and forth over all {}{what}{slip}", sts(m))
        } else {
            format!(
                "{generic}; the other {} {} on the needle",
                sts(n - m),
                if n - m == 1 { "rests" } else { "rest" }
            )
        };
        let count = self.snapshot();
        self.push_line(si, ti, None, None, text, true, false, count);
    }

    /// The label for a step that works `rows` whole rows from the start of a row: `Next 32 rows
    /// (first row RS)`, `Next 50 rnds`, or the one-row labels.
    fn rows_label(&mut self, rows: u64) -> Option<String> {
        if rows == 1 {
            return self.take_label(false);
        }
        let needle = self.needle.as_mut()?;
        needle.row_start = false;
        self.short_no = 0;
        if needle.round {
            return Some(format!("Next {rows} rnds"));
        }
        Some(match needle.side() {
            Some(Side::Rs) => format!("Next {rows} rows (first row RS)"),
            Some(Side::Ws) => format!("Next {rows} rows (first row WS)"),
            None => format!("Next {rows} rows"),
        })
    }

    /// Why a step that works whole rows cannot start here, or `None`.
    fn whole_rows_problem(&self, needle: &Needle, what: &str) -> Option<String> {
        let unit = if needle.round { "round" } else { "row" };
        if !needle.row_start {
            return Some(format!(
                "{what} whole {unit}s, but this {unit} is already started ({} still to work in \
                 it); finish the {unit} first",
                stitches(needle.lh())
            ));
        }
        if !needle.round && !needle.at_edge() {
            return Some(format!(
                "{what} whole rows, but the work is at a short-row turn here; work to the end of \
                 the row first"
            ));
        }
        None
    }

    fn rows(&mut self, si: usize, ti: usize, count: u32, text: &str) {
        let r = u64::from(count);
        let body = match text.trim().trim_end_matches('.') {
            "" => "work even".to_string(),
            t => t.to_string(),
        };
        let round_words = self.needle.as_ref().map_or(self.default_round, |n| n.round);
        let units = |round: bool| match (round, r) {
            (true, 1) => "rnd",
            (true, _) => "rnds",
            (false, 1) => "row",
            (false, _) => "rows",
        };
        let unlabelled = format!("work {r} {}: {body}", units(round_words));
        let Some(needle) = &self.needle else {
            return self.unknown_line(si, ti, unlabelled);
        };
        if needle.n == 0 {
            let problem = self.no_stitches_here();
            return self.refuse(si, ti, unlabelled, problem);
        }
        if r == 0 {
            let problem = if needle.round {
                "works 0 rounds; work at least 1"
            } else {
                "works 0 rows; work at least 1"
            };
            return self.refuse(si, ti, unlabelled, problem.into());
        }
        if let Some(problem) = self.whole_rows_problem(needle, "works") {
            return self.refuse(si, ti, unlabelled, problem);
        }
        let label = self.rows_label(r);
        let body = if label.is_some() {
            self.with_double_stitch(body)
        } else {
            body
        };
        let needle = self.needle.as_mut().expect("counting");
        let (marks, gaps) = needle.whole_rows(r);
        let text = self.crossings(si, ti, None, body, &marks, &gaps, false, false);
        let count = self.snapshot();
        let line = self.push_line(si, ti, None, label, text, true, false, count);
        self.lines[line].rows = Some(r);
    }

    #[allow(clippy::too_many_arguments)]
    fn shape(
        &mut self,
        si: usize,
        ti: usize,
        change: i64,
        every: u32,
        until: ShapeUntil,
        groups: &[String],
        how: &str,
    ) {
        let round_words = self.needle.as_ref().map_or(self.default_round, |n| n.round);
        let generic = shape_text(change, every, until, groups, how, round_words, None);
        let Some(needle) = &self.needle else {
            return self.unknown_line(si, ti, generic);
        };
        if needle.n == 0 {
            let problem = self.no_stitches_here();
            return self.refuse(si, ti, generic, problem);
        }
        let unit = if needle.round { "round" } else { "row" };
        if change == 0 {
            let problem = format!(
                "changes no stitches; to work {unit}s without shaping, use a step that works whole \
                 {unit}s"
            );
            return self.refuse(si, ti, generic, problem);
        }
        if every == 0 {
            let problem = format!(
                "shapes every 0 {unit}s; give 1 to shape every {unit}, or 2 for every other {unit}"
            );
            return self.refuse(si, ti, generic, problem);
        }
        // The groups it names must be on the needle, once each.
        let here = group_counts(needle.segs.iter());
        for (i, g) in groups.iter().enumerate() {
            if groups[..i].iter().any(|h| h.trim() == g.trim()) {
                let problem = format!("names the needle group {} twice", display_name(g));
                return self.refuse(si, ti, generic, problem);
            }
            if !here.iter().any(|h| h.name == *g) {
                let problem = if here.is_empty() && self.rest.is_none() {
                    format!(
                        "shapes the needle group {}, but the stitches are not divided into groups \
                         yet; divide them first, or leave the group out",
                        display_name(g)
                    )
                } else {
                    format!(
                        "there is no needle group called {} on the needle here",
                        display_name(g)
                    )
                };
                return self.refuse(si, ti, generic, problem);
            }
        }
        let n = needle.n;
        let places = groups.len().max(1) as i64;
        let verb = if change < 0 { "decreases" } else { "increases" };
        let Some(per_row) = change.checked_mul(places) else {
            return self.refuse(si, ti, generic, too_many());
        };
        let times: u64 = match until {
            ShapeUntil::Times(0) => {
                return self.refuse(
                    si,
                    ti,
                    generic,
                    "shapes 0 times; shape at least once".into(),
                );
            }
            ShapeUntil::Times(t) => u64::from(t),
            ShapeUntil::Remain(target) => {
                let target = u64::from(target);
                let diff = i128::from(target) - i128::from(n);
                if diff == 0 {
                    let problem = format!(
                        "shapes until {} remain, but that is how many are on the needle already",
                        stitches(target)
                    );
                    return self.refuse(si, ti, generic, problem);
                }
                if (diff < 0) != (per_row < 0) {
                    let problem = format!(
                        "{verb}, but {} is {} than the {} on the needle",
                        stitches(target),
                        if diff > 0 { "more" } else { "fewer" },
                        n
                    );
                    return self.refuse(si, ti, generic, problem);
                }
                let step = i128::from(per_row);
                if diff % step != 0 {
                    let q = diff / step;
                    let near = i128::from(n) + q * step;
                    let problem = format!(
                        "{verb} {} at a time, which cannot reach {} from {}: it goes from {} \
                         to {}",
                        stitches(per_row.unsigned_abs()),
                        target,
                        n,
                        near,
                        near + step
                    );
                    return self.refuse(si, ti, generic, problem);
                }
                (diff / step) as u64
            }
        };
        // Every count stays in range: at least 1 stitch on the needle and in each group it shapes,
        // never past the cap.
        let total = i128::from(per_row) * i128::from(times);
        let after = i128::from(n) + total;
        if after < 1 {
            let problem = format!(
                "takes off {}, but only {} on the needle",
                stitches(total.unsigned_abs() as u64),
                are_count(n)
            );
            return self.refuse(si, ti, generic, problem);
        }
        for g in groups {
            let have = here.iter().find(|h| h.name == *g).map_or(0, |h| h.count);
            let off = i128::from(change) * i128::from(times);
            if i128::from(have) + off < 1 {
                let problem = format!(
                    "takes {} off the {}, which has only {}",
                    stitches(off.unsigned_abs() as u64),
                    display_name(g),
                    stitches(have)
                );
                return self.refuse(si, ti, generic, problem);
            }
        }
        if total > 0 && self.too_big(total as u64) {
            return self.refuse(si, ti, generic, too_many());
        }
        if let Some(problem) = self.whole_rows_problem(needle, "shapes over") {
            return self.refuse(si, ti, generic, problem);
        }
        let Some(rows) = times.checked_mul(u64::from(every)) else {
            return self.refuse(si, ti, generic, too_many());
        };
        let text = if rows == 1 {
            // One shaping row or round: said as one (ADR 0020 review).
            single_shape_text(change, groups, how, Some(after as u64))
        } else {
            shape_text(change, every, until, groups, how, needle.round, Some(times))
        };
        let label = self.rows_label(rows);
        let text = if label.is_some() {
            self.with_double_stitch(text)
        } else {
            text
        };
        let needle = self.needle.as_mut().expect("counting");
        let (marks, gaps) = needle.whole_rows(rows);
        let text = self.crossings(si, ti, None, text, &marks, &gaps, false, false);
        if groups.is_empty() && self.worked_groups() > 1 {
            self.drop_groups(
                si,
                ti,
                None,
                "this step does not say which needle groups it shapes",
            );
        }
        let needle = self.needle.as_mut().expect("counting");
        // Every stitch was worked, so only the sides at the ends of the needle keep their places.
        let n_now = needle.n;
        needle.sides_resized(0, n_now, total as i64);
        if needle.round {
            needle.sides.retain(|x| x.at == 0);
        }
        if groups.is_empty() {
            if let Some(name) = needle.segs.first().map(|s| s.name.clone()) {
                seg_change(&mut needle.segs, &name, total as i64);
            }
        } else {
            for g in groups {
                seg_change(&mut needle.segs, g, change * times as i64);
            }
        }
        needle.n = after as u64;
        if !needle.up {
            needle.c = needle.n;
        }
        let count = self.snapshot();
        let line = self.push_line(si, ti, None, label, text, true, false, count);
        self.lines[line].rows = Some(rows);
    }

    fn pick_up(
        &mut self,
        si: usize,
        ti: usize,
        count: u32,
        along: &PickUpAlong,
        group: Option<&str>,
    ) {
        let k = u64::from(count);
        let onto = group.map_or(String::new(), |g| {
            format!(", adding them to the {}", display_name(g))
        });
        // The part worked flat this picks up along, when it is one, and its name.
        let piece_id = match along {
            PickUpAlong::Piece(id) => Some(id.as_str()),
            PickUpAlong::Edge(_) => None,
        };
        let piece_name = piece_id.and_then(|id| {
            let &(s, t) = self.by_id.get(id)?;
            match &self.p.sections[s].steps[t].action {
                StepAction::WorkFlat { name, .. } => Some(name.trim().to_string()),
                _ => None,
            }
        });
        let flat_words = |name: &Option<String>| match name.as_deref() {
            Some(n) if !n.is_empty() => format!("the {}", short(n, SHORT_NAME_CHARS)),
            _ => "the part worked flat".to_string(),
        };
        let edge = match along {
            PickUpAlong::Edge(t) => match t.trim() {
                "" => "the edge".to_string(),
                t => t.to_string(),
            },
            PickUpAlong::Piece(_) => format!("the side of {}", flat_words(&piece_name)),
        };
        let generic = format!("pick up and knit {} along {edge}{onto}", sts(k));
        if let Some(id) = piece_id {
            let Some(&(ws, wt)) = self.by_id.get(id) else {
                return self.refuse(
                    si,
                    ti,
                    generic,
                    "picks up along a part worked flat, but the step that worked it flat is gone \
                     (it may have been deleted)"
                        .into(),
                );
            };
            let other = self.place(ws, Some(wt), None);
            if piece_name.is_none() {
                let problem = format!("names {other}, which does not work stitches flat");
                return self.refuse(si, ti, generic, problem);
            }
            if (ws, wt) > (si, ti) {
                let problem = format!(
                    "picks up along {} before {other} works it; move this step after it",
                    flat_words(&piece_name)
                );
                return self.refuse(si, ti, generic, problem);
            }
            if !self.pieces.contains_key(id) {
                let problem = format!(
                    "picks up along {}, but {other} could not work it flat",
                    flat_words(&piece_name)
                );
                return self.refuse(si, ti, generic, problem);
            }
        }
        let Some(needle) = &self.needle else {
            return self.unknown_line(si, ti, generic);
        };
        if k == 0 {
            return self.refuse(
                si,
                ti,
                generic,
                "picks up 0 stitches; pick up at least 1".into(),
            );
        }
        if self.too_big(k) {
            return self.refuse(si, ti, generic, too_many());
        }
        let names = self.group_names();
        match group {
            Some(g) if names.is_empty() => {
                let problem = format!(
                    "adds the stitches to the needle group {}, but the stitches are not divided \
                     into groups yet; divide them first, or leave the group out",
                    display_name(g)
                );
                return self.refuse(si, ti, generic, problem);
            }
            Some(g) if !names.iter().any(|n| n == g) => {
                let problem = format!(
                    "there is no needle group called {}; the groups are {}",
                    display_name(g),
                    listed(&names)
                );
                return self.refuse(si, ti, generic, problem);
            }
            None if !names.is_empty() => {
                let problem = format!(
                    "the stitches are in needle groups ({}); say which group the picked-up \
                     stitches go on",
                    listed(&names)
                );
                return self.refuse(si, ti, generic, problem);
            }
            _ => {}
        }
        // Where the work is decides where the new stitches go: always with the right side facing.
        let place = if needle.n == 0 {
            if self.rest.is_some() {
                let problem = self.no_stitches_here();
                return self.refuse(si, ti, generic, problem);
            }
            PickPlace::Empty
        } else if needle.round {
            if needle.row_start {
                PickPlace::RoundEnd
            } else {
                PickPlace::Mid
            }
        } else if needle.side().is_none() {
            return self.refuse(si, ti, generic, side_unknown_problem());
        } else if !needle.row_start {
            if needle.side() != Some(Side::Rs) {
                return self.refuse(
                    si,
                    ti,
                    generic,
                    "picks up with the right side facing, but the work is partway through a \
                     wrong-side row"
                        .into(),
                );
            }
            PickPlace::Mid
        } else if !needle.at_edge() {
            return self.refuse(
                si,
                ti,
                generic,
                "picks up at a short-row turn; pick up at the end of a row or at its start".into(),
            );
        } else if needle.side() == Some(Side::Ws) {
            PickPlace::RowEnd
        } else {
            PickPlace::RowStart
        };
        // Along a part worked flat: which side, from where the work is.
        let mut side_info = None;
        let edge = if let Some(id) = piece_id {
            let active = self.rest.as_ref().is_some_and(|r| r.step == id);
            let rec = self.pieces.get(id).expect("checked above").clone();
            // Where the new stitches go: at the start of a round, after the last stitch; otherwise
            // where the work is. A side of the part is there when its mark is.
            let at = match place {
                PickPlace::RoundEnd => 0,
                _ => needle.c,
            };
            // 0: the right side (where its right-side rows start), 1: the left side.
            let which = match place {
                PickPlace::Empty => None,
                _ => needle
                    .sides
                    .iter()
                    .find(|m| m.piece == id && m.at == at)
                    .map(|m| usize::from(m.left)),
            };
            let Some(which) = which else {
                let problem = format!(
                    "picks up along {}, but the work is not at either side of it here (a side is \
                     at the end or the start of its right-side rows, wherever those stitches are \
                     now)",
                    flat_words(&piece_name)
                );
                return self.refuse(si, ti, generic, problem);
            };
            let rows = if active { needle.full_rows } else { rec.rows };
            side_info = Some((which, rec.picked[which]));
            let words = flat_words(&piece_name);
            let info = if rec.slip_edges {
                // No whole rows on that side yet: there are no slipped edge stitches to mention.
                match rows[which] {
                    0 => String::new(),
                    1 => " (it has 1 slipped edge st on this side)".to_string(),
                    s => format!(" (it has {s} slipped edge sts on this side)"),
                }
            } else if rows[0] + rows[1] > 0 {
                format!(" (it is {} rows long)", rows[0] + rows[1])
            } else {
                String::new()
            };
            format!(
                "the {} side of {words}{info}",
                if which == 0 { "right" } else { "left" }
            )
        } else {
            edge
        };
        if let Some((which, true)) = side_info {
            self.warn(
                Some(si),
                Some(ti),
                None,
                format!(
                    "picks up along the {} side of {} a second time",
                    if which == 0 { "right" } else { "left" },
                    flat_words(&piece_name)
                ),
            );
        }
        if let (Some((which, _)), Some(id)) = (side_info, piece_id) {
            if let Some(rec) = self.pieces.get_mut(id) {
                rec.picked[which] = true;
            }
        }
        let join = match group {
            Some(g) => Join::Named(g),
            None => Join::Adjacent,
        };
        let label = match place {
            PickPlace::RowStart => self.take_label(false),
            PickPlace::Empty => Some("Next row (RS)".to_string()),
            _ => None,
        };
        match place {
            PickPlace::Empty => {
                let mut fresh = Needle::fresh(k, Some(Side::Rs));
                fresh.c = k;
                fresh.row_start = false;
                fresh.yarn_here = true;
                fresh.settle();
                self.needle = Some(fresh);
            }
            PickPlace::RoundEnd => {
                let (_, grouped) = self.needle.as_mut().expect("counting").append(k, join);
                if !grouped {
                    self.drop_groups(
                        si,
                        ti,
                        None,
                        "this step picks up stitches between two groups",
                    );
                }
            }
            PickPlace::RowEnd | PickPlace::Mid | PickPlace::RowStart => {
                let needle = self.needle.as_mut().expect("counting");
                if place == PickPlace::RowEnd {
                    // Back onto the row that just ended: the stitches continue it.
                    needle.up = !needle.up;
                    needle.row_start = false;
                    needle.yarn_here = true;
                }
                needle.edge_row = None;
                let (_, grouped) = needle.insert(k, false, &[], join);
                needle.settle();
                if !grouped {
                    self.drop_groups(
                        si,
                        ti,
                        None,
                        "this step picks up stitches between two groups",
                    );
                }
            }
        }
        let text = format!("pick up and knit {} along {edge}{onto}", sts(k));
        let count = self.snapshot();
        self.push_line(si, ti, None, label, text, true, false, count);
    }

    fn round_start(&mut self, si: usize, ti: usize) {
        let text = "the rnd now starts here (move the marker for the start of the rnd)".to_string();
        let Some(needle) = &self.needle else {
            return self.unknown_line(si, ti, text);
        };
        if needle.n == 0 {
            let problem = self.no_stitches_here();
            return self.refuse(si, ti, text, problem);
        }
        if self.rest.is_some() {
            return self.refuse(
                si,
                ti,
                text,
                "moves the start of the round while part of the round is worked flat; join it \
                 back into the round first"
                    .into(),
            );
        }
        if !needle.round {
            return self.refuse(
                si,
                ti,
                text,
                "moves the start of the round, but the work is flat; only a round has a start"
                    .into(),
            );
        }
        if needle.c == 0 {
            return self.refuse(
                si,
                ti,
                text,
                "moves the start of the round to where it already is; work to where the new start \
                 should be first"
                    .into(),
            );
        }
        self.needle.as_mut().expect("counting").rotate();
        let count = self.snapshot();
        self.push_line(si, ti, None, None, text, true, false, count);
    }

    fn set_groups(&mut self, si: usize, ti: usize, groups: &[NeedleGroup]) {
        let list: Vec<String> = groups
            .iter()
            .map(|g| match g.notes.trim() {
                "" => format!("{} {}", g.count, display_name(&g.name)),
                notes => format!("{} {} ({notes})", g.count, display_name(&g.name)),
            })
            .collect();
        let generic = if groups.is_empty() {
            "stop counting needle groups".to_string()
        } else {
            format!("divide the sts into needle groups: {}", list.join(", "))
        };
        let Some(needle) = &self.needle else {
            return self.unknown_line(si, ti, generic);
        };
        if needle.n == 0 {
            let problem = self.no_stitches_here();
            return self.refuse(si, ti, generic, problem);
        }
        if self.rest.is_some() {
            return self.refuse(
                si,
                ti,
                generic,
                "divides the stitches into groups while part of the round is worked flat; divide \
                 them in the round, before working part of it flat"
                    .into(),
            );
        }
        let unit = if needle.round { "round" } else { "row" };
        if !needle.row_start {
            let problem = format!(
                "divides the stitches into groups partway through a {unit} ({} still to work in \
                 it); do it at the start of a {unit}",
                stitches(needle.lh())
            );
            return self.refuse(si, ti, generic, problem);
        }
        if !needle.round && !needle.at_edge() {
            return self.refuse(
                si,
                ti,
                generic,
                "divides the stitches into groups at a short-row turn; do it at the start of a row"
                    .into(),
            );
        }
        let n = needle.n;
        let round = needle.round;
        let up = needle.up;
        if groups.is_empty() {
            self.needle.as_mut().expect("counting").segs.clear();
            let count = self.snapshot();
            self.push_line(si, ti, None, None, generic, true, false, count);
            return;
        }
        for (i, g) in groups.iter().enumerate() {
            if g.name.trim().is_empty() {
                return self.refuse(si, ti, generic, "a needle group has no name".into());
            }
            if groups[..i]
                .iter()
                .any(|h| h.name.trim().eq_ignore_ascii_case(g.name.trim()))
            {
                let problem = format!("two needle groups are called {}", g.name.trim());
                return self.refuse(si, ti, generic, problem);
            }
            if g.count == 0 {
                let problem = format!("the needle group {} has 0 stitches", g.name.trim());
                return self.refuse(si, ti, generic, problem);
            }
        }
        let sum: u64 = groups.iter().map(|g| u64::from(g.count)).sum();
        if sum != n {
            let problem = format!(
                "the groups add up to {}, but {} on the needle",
                stitches(sum),
                are_count(n)
            );
            return self.refuse(si, ti, generic, problem);
        }
        // In working order from here: toward stitch n, or from stitch n down.
        let mut segs: Vec<Seg> = groups
            .iter()
            .map(|g| Seg {
                name: g.name.trim().to_string(),
                len: u64::from(g.count),
            })
            .collect();
        if !up {
            segs.reverse();
        }
        self.needle.as_mut().expect("counting").segs = segs;
        let start = if round {
            "starting at the beginning of the rnd"
        } else {
            "in the order the next row works them"
        };
        let text = format!(
            "divide the {} into needle groups, {start}: {}",
            sts(n),
            list.join(", ")
        );
        let count = self.snapshot();
        self.push_line(si, ti, None, None, text, true, false, count);
    }

    fn close(&mut self, si: usize, ti: usize, method: CloseMethod) {
        let generic = match method {
            CloseMethod::Graft => "graft the sts together with Kitchener stitch".to_string(),
            CloseMethod::ThreeNeedleBindOff => {
                "bind off the sts together with a three-needle bind-off".to_string()
            }
        };
        let Some(needle) = &self.needle else {
            return self.unknown_line(si, ti, generic);
        };
        if needle.n == 0 {
            let problem = self.no_stitches_here();
            return self.refuse(si, ti, generic, problem);
        }
        if self.rest.is_some() {
            return self.refuse(
                si,
                ti,
                generic,
                "closes the stitches while others rest on the needle outside the part worked \
                 flat; join them back into the round first"
                    .into(),
            );
        }
        if !needle.row_start {
            let unit = if needle.round { "round" } else { "row" };
            let problem = format!(
                "closes the stitches partway through a {unit} ({} still to work in it); finish \
                 the {unit} first",
                stitches(needle.lh())
            );
            return self.refuse(si, ti, generic, problem);
        }
        if !needle.round && !needle.at_edge() {
            let waiting = needle.lo + needle.hi;
            let problem = format!(
                "closes the stitches at a short-row turn, with {} still waiting past a turn; work \
                 to the end of the row first",
                stitches(waiting)
            );
            return self.refuse(si, ti, generic, problem);
        }
        let n = needle.n;
        let what = match method {
            CloseMethod::Graft => "grafting",
            CloseMethod::ThreeNeedleBindOff => "a three-needle bind-off",
        };
        let groups = group_counts(needle.segs.iter());
        let text = match groups.as_slice() {
            [a, b] => {
                if a.count != b.count {
                    let problem = format!(
                        "{what} joins two needle groups of the same size, but the {} has {} and \
                         the {} has {}",
                        display_name(a.name),
                        stitches(a.count),
                        display_name(b.name),
                        stitches(b.count)
                    );
                    return self.refuse(si, ti, generic, problem);
                }
                match method {
                    CloseMethod::Graft => format!(
                        "graft the {} {} sts to the {} {} sts with Kitchener stitch",
                        a.count,
                        display_name(a.name),
                        b.count,
                        display_name(b.name)
                    ),
                    CloseMethod::ThreeNeedleBindOff => format!(
                        "with the right sides together, bind off the {} {} sts and the {} {} sts \
                         together with a three-needle bind-off",
                        a.count,
                        display_name(a.name),
                        b.count,
                        display_name(b.name)
                    ),
                }
            }
            [_, _, ..] => {
                let names: Vec<String> = groups.iter().map(|g| g.name.to_string()).collect();
                let problem = format!(
                    "{what} joins two halves, but the stitches are in {} needle groups ({}); \
                     divide them into two groups first",
                    groups.len(),
                    listed(&names)
                );
                return self.refuse(si, ti, generic, problem);
            }
            _ => {
                if n % 2 == 1 {
                    let problem = format!(
                        "{what} joins two equal halves, but {} do not divide evenly",
                        stitches(n)
                    );
                    return self.refuse(si, ti, generic, problem);
                }
                match method {
                    CloseMethod::Graft => format!(
                        "divide the {} evenly onto two needles ({} on each) and graft them \
                         together with Kitchener stitch",
                        sts(n),
                        n / 2
                    ),
                    CloseMethod::ThreeNeedleBindOff => format!(
                        "divide the {} evenly onto two needles ({} on each) and, with the right \
                         sides together, bind them off together with a three-needle bind-off",
                        sts(n),
                        n / 2
                    ),
                }
            }
        };
        let (_, overflow) = match method {
            CloseMethod::Graft => self.grafted.overflowing_add(n),
            CloseMethod::ThreeNeedleBindOff => self.bound_off.overflowing_add(n),
        };
        if overflow {
            return self.refuse(si, ti, generic, too_many());
        }
        let needle = self.needle.as_mut().expect("counting");
        let marks = std::mem::take(&mut needle.marks);
        let gaps = std::mem::take(&mut needle.gaps);
        let text = self.crossings(si, ti, None, text, &marks, &gaps, false, false);
        match method {
            CloseMethod::Graft => self.add_closed(true, n),
            CloseMethod::ThreeNeedleBindOff => self.add_closed(false, n),
        }
        self.needle = Some(Needle::empty());
        let count = self.snapshot();
        self.push_line(si, ti, None, None, text, true, false, count);
    }
}

// --- the walk: several pieces (schema version 6, ADR 0020) ------------------------------------------

/// What a join takes once it is applied.
#[derive(Debug, Clone, Copy)]
enum JoinTake {
    /// Every stitch of the piece with this index.
    Piece(usize),
    /// The group on hold at this index of [`Walk::groups`].
    Group(usize),
}

/// The stitches a join works in, in right-side order.
struct JoinSrc {
    /// `None`: their count is unknown.
    k: Option<u64>,
    /// Wraps and double stitches among them (all crossed by the join).
    marks: Vec<Mark>,
    /// Gaps among them (crossed by the join, so warned about).
    gaps: Vec<Gap>,
    /// Their needle groups in right-side order; `None` when Ply cannot tell the order of several.
    segs: Option<Vec<Seg>>,
    /// `across the 54 sts of the left sleeve` / `the 8 sts on hold (thumb)`, without the verb.
    what: String,
    /// `across the sts of the left sleeve`: the same without a count.
    generic: String,
    /// `Left sleeve` / `the stitches on hold (thumb)`, for messages.
    who: String,
    /// The needle groups among them when their order is not known (`segs` is `None`).
    unordered: Vec<String>,
    take: JoinTake,
}

/// `segs` in right-side order, given whether right-side rows travelled toward their last stitch;
/// `None` when that is not known and the order matters (more than one group).
fn rs_order(segs: &[Seg], rs_up: Option<bool>) -> Option<Vec<Seg>> {
    match rs_up {
        Some(true) => Some(segs.to_vec()),
        Some(false) => Some(segs.iter().rev().cloned().collect()),
        None if group_counts(segs.iter()).len() <= 1 => Some(segs.to_vec()),
        None => None,
    }
}

impl<'a> Walk<'a> {
    /// A piece as words refer to it: its name as the knitter gave it (no article added, shortened
    /// past [`SHORT_NAME_CHARS`]), or `piece 3` for a piece with no name.
    fn the_piece(&self, i: usize) -> String {
        match self.p.pieces.get(i).map(|p| p.name.trim()) {
            Some(name) if !name.is_empty() => short(name, SHORT_NAME_CHARS),
            _ => format!("piece {}", i + 1),
        }
    }

    /// Put the current piece's needle back in its slot, once, so every slot is current (at the end
    /// of the walk).
    fn park(&mut self) {
        if !self.parked {
            self.slots[self.cur].needle = self.needle.take();
            self.slots[self.cur].rest = self.rest.take();
            self.parked = true;
        }
    }

    /// Warnings for the pieces at the end of the pattern: a piece no section works, and a piece other
    /// than the one worked last that still has stitches set aside.
    fn end_pieces(&mut self) {
        for i in 0..self.p.pieces.len() {
            let slot = self.slots[i].clone();
            let piece = self.the_piece(i);
            // A piece joined to another has no stitches left; one that still has some (by any
            // route) is checked like every other piece.
            if slot.joined.is_some() && slot.live() == Some(0) {
                continue;
            }
            if slot.sections.is_empty() && slot.joined.is_none() {
                let cast = match slot.live() {
                    Some(n) if n > 0 => format!(
                        "; its {} cast on {} never worked",
                        stitches(n),
                        if n == 1 { "is" } else { "are" }
                    ),
                    _ => String::new(),
                };
                self.warn(None, None, None, format!("no section works {piece}{cast}"));
                continue;
            }
            if Some(i) == self.last_piece {
                continue;
            }
            if let Some(n) = slot.live() {
                if n > 0 {
                    let last = slot.sections.last().copied();
                    self.warn(
                        last,
                        None,
                        None,
                        format!(
                            "{} of {piece} {} still set aside at the end of the pattern; no step \
                             joins {} to another piece or finishes {}",
                            stitches(n),
                            if n == 1 { "is" } else { "are" },
                            if n == 1 { "it" } else { "them" },
                            if n == 1 { "it" } else { "them" },
                        ),
                    );
                }
            }
        }
    }

    /// How each piece ends, for [`Ledger::pieces`].
    fn summaries(&mut self) -> Vec<PieceSummary> {
        self.park();
        (0..self.p.pieces.len())
            .map(|i| {
                let slot = &self.slots[i];
                let live = slot.live();
                // From the stitches left first, so none can vanish from the summary.
                let text = if let (Some((into, s, t)), Some(0)) = (slot.joined, live) {
                    format!(
                        "joined to {} at {}",
                        self.the_piece(into),
                        self.place(s, Some(t), None)
                    )
                } else if slot.sections.is_empty() && live == Some(0) {
                    "no section works this piece".to_string()
                } else {
                    match live {
                        None => "stitch count unknown at the end".to_string(),
                        Some(0) => "no stitches left at the end".to_string(),
                        Some(n) => format!("{} left on the needle at the end", sts(n)),
                    }
                };
                PieceSummary {
                    piece: i,
                    sections: slot.sections.clone(),
                    live,
                    joined: slot.joined,
                    text,
                }
            })
            .collect()
    }

    /// The stitches a join takes, or the problem that stops it (with the step's words for the
    /// refused line).
    fn join_source(
        &self,
        si: usize,
        ti: usize,
        source: &JoinSource,
    ) -> Result<JoinSrc, (String, String)> {
        match source {
            JoinSource::Piece(id) => {
                let Some(pi) = self.p.pieces.iter().position(|p| p.id == *id) else {
                    return Err((
                        "across the sts of another piece".into(),
                        "joins a piece the pattern does not have (it may have been deleted); \
                         choose one of the pattern's pieces"
                            .into(),
                    ));
                };
                let piece = self.the_piece(pi);
                let generic = format!("across the sts of {piece}");
                let refuse = |problem: String| Err((generic.clone(), problem));
                if Some(pi) == self.cur_piece() {
                    return refuse(format!(
                        "joins {piece} to itself; a join brings in the stitches of another piece \
                         or of a holder"
                    ));
                }
                let slot = &self.slots[pi];
                if let Some((into, s, t)) = slot.joined {
                    let other = self.place(s, Some(t), None);
                    return refuse(format!(
                        "{piece} was already joined to {} at {other}",
                        self.the_piece(into)
                    ));
                }
                let Some(n) = &slot.needle else {
                    return Ok(JoinSrc {
                        k: None,
                        marks: Vec::new(),
                        gaps: Vec::new(),
                        segs: Some(Vec::new()),
                        what: generic.clone(),
                        generic,
                        who: piece,
                        unordered: Vec::new(),
                        take: JoinTake::Piece(pi),
                    });
                };
                if slot.rest.is_some() {
                    return refuse(format!(
                        "part of {piece} is still worked flat; join it back into the round in its \
                         own section first"
                    ));
                }
                if n.n == 0 {
                    return refuse(if slot.sections.is_empty() {
                        format!("{piece} has no stitches yet: no section before this one works it")
                    } else {
                        format!("{piece} has no stitches left on its needle")
                    });
                }
                if !n.row_start {
                    let unit = if n.round { "round" } else { "row" };
                    return refuse(format!(
                        "{piece} is partway through a {unit} ({} still to work in it); finish the \
                         {unit} in its own section first",
                        stitches(n.lh())
                    ));
                }
                // Right-side order: a round, or a flat piece whose right-side rows travel toward its
                // last stitch, from its first stitch; otherwise from its last.
                let rs_up = if n.round {
                    Some(true)
                } else if n.unoriented {
                    None
                } else {
                    n.up_side.map(|s| s == Side::Rs)
                };
                Ok(JoinSrc {
                    k: Some(n.n),
                    marks: n.marks.clone(),
                    // Worked from its first stitch to its last: a gap at the start of a round is
                    // at the ends of the run, not crossed.
                    gaps: n
                        .gaps
                        .iter()
                        .filter(|g| !(n.round && g.at == 0))
                        .cloned()
                        .collect(),
                    segs: rs_order(&n.segs, rs_up),
                    what: format!("across the {} of {piece}", sts(n.n)),
                    generic,
                    who: piece,
                    unordered: group_counts(n.segs.iter())
                        .into_iter()
                        .map(|g| g.name.to_string())
                        .collect(),
                    take: JoinTake::Piece(pi),
                })
            }
            JoinSource::Held(hold) => {
                let Some(&(hs, ht)) = self.by_id.get(hold.as_str()) else {
                    return Err((
                        "the held sts".into(),
                        "joins held stitches, but the step that put them on hold is gone (it may \
                         have been deleted)"
                            .into(),
                    ));
                };
                let other = self.place(hs, Some(ht), None);
                let StepAction::Hold { name, .. } = &self.p.sections[hs].steps[ht].action else {
                    return Err((
                        "the held sts".into(),
                        format!("names {other}, which does not put stitches on hold"),
                    ));
                };
                let shown = shown(name);
                let generic = format!("the sts on hold{shown}");
                let refuse = |problem: String| Err((generic.clone(), problem));
                if (hs, ht) > (si, ti) {
                    return refuse(format!(
                        "joins the stitches on hold{shown} before {other} puts them on hold; move \
                         this step after it"
                    ));
                }
                let gi = match self.groups.iter().rposition(|g| g.hold == *hold) {
                    Some(gi) if !self.failed_holds.iter().any(|h| h == hold) => gi,
                    _ => {
                        return refuse(format!(
                            "joins the stitches on hold{shown}, but {other} could not put them on \
                             hold"
                        ))
                    }
                };
                let group = &self.groups[gi];
                if let Some((rs, rt)) = group.resumed {
                    let taker = self.place(rs, Some(rt), None);
                    return refuse(format!(
                        "joins the stitches on hold{shown}, but {taker} already took them off the \
                         holder"
                    ));
                }
                Ok(JoinSrc {
                    k: group.count.filter(|_| group.checked),
                    marks: group.marks.iter().map(|(_, m)| *m).collect(),
                    gaps: Vec::new(),
                    segs: rs_order(&group.segs, group.rs_up),
                    what: match group.count {
                        Some(k) => format!("the {} on hold{shown}", sts(k)),
                        None => generic.clone(),
                    },
                    generic,
                    who: format!("the stitches on hold{shown}"),
                    unordered: group_counts(group.segs.iter())
                        .into_iter()
                        .map(|g| g.name.to_string())
                        .collect(),
                    take: JoinTake::Group(gi),
                })
            }
        }
    }

    /// The source is taken: a piece's needle is emptied and recorded as joined to the current piece,
    /// a group is off its holder.
    fn take_source(&mut self, take: JoinTake, si: usize, ti: usize) {
        match take {
            JoinTake::Piece(pi) => {
                let into = self.cur_piece().unwrap_or(pi);
                let slot = &mut self.slots[pi];
                slot.needle = Some(Needle::empty());
                slot.rest = None;
                slot.joined = Some((into, si, ti));
            }
            JoinTake::Group(gi) => self.groups[gi].resumed = Some((si, ti)),
        }
    }

    /// Close two groups on hold against each other (ADR 0020 review): graft them, or bind them off
    /// together, whatever piece the work is on; the needle is left as it is. Both groups are
    /// checked as a join checks held stitches, must differ and must be the same size.
    fn close_held(&mut self, si: usize, ti: usize, method: CloseMethod, holds: &[String]) {
        let generic = match method {
            CloseMethod::Graft => {
                "graft the two groups of sts on hold together with Kitchener stitch".to_string()
            }
            CloseMethod::ThreeNeedleBindOff => {
                "bind off the two groups of sts on hold together with a three-needle bind-off"
                    .to_string()
            }
        };
        let [a, b] = holds else {
            let problem = format!(
                "closes {} on hold; name two groups, one for each needle",
                count_of(holds.len() as u64, "group", "groups")
            );
            return self.refuse(si, ti, generic, problem);
        };
        if a == b {
            return self.refuse(
                si,
                ti,
                generic,
                "names the same stitches on hold twice; name the two groups to close together"
                    .into(),
            );
        }
        let mut srcs = Vec::with_capacity(2);
        for id in [a, b] {
            match self.join_source(si, ti, &JoinSource::Held(id.clone())) {
                Ok(src) => srcs.push(src),
                Err((_, problem)) => {
                    let problem = problem.replacen("joins", "closes", 1);
                    return self.refuse(si, ti, generic, problem);
                }
            }
        }
        let (x, y) = (&srcs[0], &srcs[1]);
        let what = match method {
            CloseMethod::Graft => "grafting",
            CloseMethod::ThreeNeedleBindOff => "a three-needle bind-off",
        };
        let (tx, ty) = (x.take, y.take);
        let (Some(kx), Some(ky)) = (x.k, y.k) else {
            if !self.suppressed() {
                self.take_source(tx, si, ti);
                self.take_source(ty, si, ti);
                if self.needle.is_some() {
                    self.warn(
                        Some(si),
                        Some(ti),
                        None,
                        "the stitch count of the stitches on hold is unknown, so the count after \
                         closing them is unknown too"
                            .into(),
                    );
                    self.needle = None;
                }
            }
            return self.unknown_line(si, ti, generic);
        };
        if kx != ky {
            let problem = format!(
                "{what} joins two groups of the same size, but {} are {} and {} are {}",
                x.who,
                stitches(kx),
                y.who,
                stitches(ky)
            );
            return self.refuse(si, ti, generic, problem);
        }
        let total = kx + ky;
        let current = match method {
            CloseMethod::Graft => self.grafted,
            CloseMethod::ThreeNeedleBindOff => self.bound_off,
        };
        if current.checked_add(total).is_none() {
            return self.refuse(si, ti, generic, too_many());
        }
        let text = match method {
            CloseMethod::Graft => format!("graft {} to {} with Kitchener stitch", x.what, y.what),
            CloseMethod::ThreeNeedleBindOff => format!(
                "place {} and {} on two needles and, with the right sides together, bind them off \
                 together with a three-needle bind-off",
                x.what, y.what
            ),
        };
        let marks: Vec<Mark> = x.marks.iter().chain(&y.marks).copied().collect();
        let text = self.crossings(si, ti, None, text, &marks, &[], false, false);
        if self.suppressed() {
            return self.unknown_line(si, ti, text);
        }
        self.take_source(tx, si, ti);
        self.take_source(ty, si, ti);
        if self.needle.is_none() {
            return self.unknown_line(si, ti, text);
        }
        self.add_closed(method == CloseMethod::Graft, total);
        let count = self.snapshot();
        self.push_line(si, ti, None, None, text, true, false, count);
    }

    fn join(
        &mut self,
        si: usize,
        ti: usize,
        source: &JoinSource,
        stitch: WorkStitch,
        resolve: bool,
    ) {
        let verb = match stitch {
            WorkStitch::Knit => "knit",
            WorkStitch::Purl => "purl",
            WorkStitch::InPattern => "work",
        };
        let in_pattern = if stitch == WorkStitch::InPattern {
            " in pattern"
        } else {
            ""
        };
        let src = match self.join_source(si, ti, source) {
            Ok(src) => src,
            Err((what, problem)) => {
                return self.refuse(si, ti, format!("{verb} {what}{in_pattern}"), problem)
            }
        };
        let generic = format!("{verb} {}{in_pattern}", src.generic);
        let orphan = self.suppressed();
        let Some(needle) = &self.needle else {
            // Taken all the same, so a later step does not take it again (not in a section whose
            // piece is missing: once that is fixed, the join is walked again).
            if !orphan {
                self.take_source(src.take, si, ti);
            }
            return self.unknown_line(si, ti, generic);
        };
        if needle.n == 0 && self.rest.is_some() {
            let problem = self.no_stitches_here();
            return self.refuse(si, ti, generic, problem);
        }
        // Where the work is decides where the stitches go: always with the right side facing, as a
        // pick-up does.
        let place = if needle.n == 0 {
            PickPlace::Empty
        } else if needle.round {
            if needle.row_start {
                PickPlace::RoundEnd
            } else {
                PickPlace::Mid
            }
        } else if needle.side().is_none() {
            return self.refuse(si, ti, generic, side_unknown_problem());
        } else if !needle.row_start {
            if needle.side() != Some(Side::Rs) {
                return self.refuse(
                    si,
                    ti,
                    generic,
                    "joins with the right side facing, but the work is partway through a \
                     wrong-side row"
                        .into(),
                );
            }
            PickPlace::Mid
        } else if !needle.at_edge() {
            return self.refuse(
                si,
                ti,
                generic,
                "joins at a short-row turn; join at the end of a row or at its start".into(),
            );
        } else if needle.side() == Some(Side::Ws) {
            PickPlace::RowEnd
        } else {
            PickPlace::RowStart
        };
        let Some(k) = src.k else {
            self.take_source(src.take, si, ti);
            self.warn(
                Some(si),
                Some(ti),
                None,
                format!(
                    "the stitch count of {} is unknown, so the count after joining them is unknown \
                     too",
                    src.who
                ),
            );
            self.needle = None;
            return self.unknown_line(si, ti, generic);
        };
        let label = match place {
            PickPlace::RowStart => self.take_label(false),
            _ => None,
        };
        let base = match place {
            PickPlace::Empty => {
                format!(
                    "with the RS facing, join the yarn and {verb} {}{in_pattern}",
                    src.what
                )
            }
            _ => {
                let joining = match (src.take, self.cur_piece()) {
                    (JoinTake::Piece(_), Some(c)) => {
                        format!(", joining it to {}", self.the_piece(c))
                    }
                    _ => String::new(),
                };
                format!("{verb} {}{in_pattern}{joining}", src.what)
            }
        };
        let base = if label.is_some() {
            self.with_double_stitch(base)
        } else {
            base
        };
        let join = match &src.segs {
            Some(s) if !s.is_empty() => Join::Exact(s),
            Some(_) => Join::Adjacent,
            None => Join::Unknown,
        };
        let mut closed = None;
        let mut grouped = true;
        match place {
            PickPlace::Empty => {
                let mut fresh = Needle::fresh(k, Some(Side::Rs));
                fresh.c = k;
                fresh.row_start = false;
                fresh.yarn_here = true;
                fresh.segs = src.segs.clone().unwrap_or_default();
                fresh.settle();
                self.needle = Some(fresh);
                if src.segs.is_none() {
                    // Groups whose order Ply cannot tell: not counted on the new piece, and said.
                    self.warn(
                        Some(si),
                        Some(ti),
                        None,
                        format!(
                            "Ply cannot tell which way round the needle groups of {} ({}) go, so \
                             it does not count needle groups on this piece; divide the stitches \
                             into groups again to count them",
                            src.who,
                            listed(&src.unordered)
                        ),
                    );
                }
            }
            PickPlace::RoundEnd => {
                let (c, g) = self.needle.as_mut().expect("counting").append(k, join);
                closed = c;
                grouped = g;
            }
            PickPlace::RowEnd | PickPlace::Mid | PickPlace::RowStart => {
                let needle = self.needle.as_mut().expect("counting");
                if place == PickPlace::RowEnd {
                    // Onto the right-side row that just ended: the stitches continue it.
                    needle.up = !needle.up;
                    needle.row_start = false;
                    needle.yarn_here = true;
                }
                needle.edge_row = None;
                let (c, g) = needle.insert(k, false, &[], join);
                closed = c;
                grouped = g;
                needle.settle();
            }
        }
        if !grouped {
            self.drop_groups(
                si,
                ti,
                None,
                "this step joins stitches between two needle groups, or stitches whose groups Ply \
                 cannot place",
            );
        }
        let mut text = self.crossings(si, ti, None, base, &src.marks, &src.gaps, resolve, true);
        if place == PickPlace::RoundEnd {
            // At the start of a round they go after the last stitch: say where the round starts.
            text.push_str(
                ", before the marker for the start of the rnd (the rnd now starts after them)",
            );
        }
        if let Some(gap) = closed {
            text.push_str(&format!(
                ", over the gap left by the stitches on hold ({})",
                display_name(&gap.name)
            ));
        }
        self.take_source(src.take, si, ti);
        let count = self.snapshot();
        self.push_line(si, ti, None, label, text, true, false, count);
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

/// How far a short row works before its turn (or its decrease), in a knitter's words. With the
/// needle, a turn at the gap names the stitch the knitter sees there: `knit to the wrapped stitch`
/// (the first stitch past a wrap-and-turn gap) or `knit to the double stitch` (the last one before
/// a German turn's gap).
fn turn_work_text(stitch: WorkStitch, to: TurnAt, needle: Option<&Needle>) -> String {
    let verb = match stitch {
        WorkStitch::Knit => "knit",
        WorkStitch::Purl => "purl",
        WorkStitch::InPattern => "work in pattern",
    };
    let before_gap = needle.map(|n| n.lh() - n.waiting_ahead().min(n.lh()));
    match to {
        TurnAt::Last(m) => work_text(stitch, WorkTo::Last(m)),
        TurnAt::Count(m) => work_text(stitch, WorkTo::Count(m)),
        TurnAt::BeforeGap(0) => match (needle, before_gap) {
            (Some(n), Some(b)) if n.waiting_ahead() > 0 && n.mark_ahead(b + 1, Pending::Wrap) => {
                format!("{verb} to the wrapped stitch")
            }
            _ => format!("{verb} to the gap"),
        },
        TurnAt::BeforeGap(1) => match (needle, before_gap) {
            (Some(n), Some(b))
                if n.waiting_ahead() > 0 && b > 0 && n.mark_ahead(b, Pending::Double) =>
            {
                format!("{verb} to the double stitch")
            }
            _ => format!("{verb} to 1 st before the gap"),
        },
        TurnAt::BeforeGap(m) => format!("{verb} to {m} sts before the gap"),
        TurnAt::PastGap(0) => format!("{verb} to the gap"),
        TurnAt::PastGap(m) => format!("{verb} to {} past the gap", sts(u64::from(m))),
    }
}

/// `, ssk, k1`: a short row's decrease and the stitches worked after it.
fn decrease_text(stitch: WorkStitch, d: TurnDecrease) -> String {
    let dec = match d.kind {
        Decrease::K2tog => "k2tog",
        Decrease::Ssk => "ssk",
        Decrease::P2tog => "p2tog",
        Decrease::Ssp => "ssp",
    };
    let after = u64::from(d.after);
    if after == 0 {
        return format!(", {dec}");
    }
    let then = match stitch {
        WorkStitch::Knit => format!("k{after}"),
        WorkStitch::Purl => format!("p{after}"),
        WorkStitch::InPattern => format!("work {} in pattern", sts(after)),
    };
    format!(", {dec}, {then}")
}

/// The words of a shaping step: `decrease 2 sts on the sole in the first rnd and then every other
/// rnd until 64 sts remain (9 decrease rnds); each decrease rnd: k1, ssk, ...`. `times` is the
/// number of shaping rows or rounds when Ply knows it.
fn shape_text(
    change: i64,
    every: u32,
    until: ShapeUntil,
    groups: &[String],
    how: &str,
    round: bool,
    times: Option<u64>,
) -> String {
    if until == ShapeUntil::Times(1) && every == 1 {
        // One shaping row or round, said as one (ADR 0020 review).
        return single_shape_text(change, groups, how, None);
    }
    let unit = if round { "rnd" } else { "row" };
    let verb = if change < 0 { "decrease" } else { "increase" };
    let mut s = format!("{verb} {}", sts(change.unsigned_abs()));
    let names: Vec<String> = groups
        .iter()
        .map(|g| format!("the {}", display_name(g)))
        .collect();
    match names.as_slice() {
        [] => {}
        [one] => s.push_str(&format!(" on {one}")),
        [rest @ .., last] => s.push_str(&format!(" on each of {} and {last}", rest.join(", "))),
    }
    match every {
        0 | 1 => s.push_str(&format!(" in every {unit}")),
        2 => s.push_str(&format!(" in the first {unit} and then every other {unit}")),
        n => s.push_str(&format!(
            " in the first {unit} and then every {} {unit}",
            ordinal(n)
        )),
    }
    match until {
        ShapeUntil::Times(t) => s.push_str(&format!(
            ", {} in all",
            count_of(u64::from(t), "time", "times")
        )),
        ShapeUntil::Remain(target) => {
            s.push_str(&format!(" until {} remain", sts(u64::from(target))));
            if let Some(t) = times {
                s.push_str(&format!(
                    " ({t} {verb} {unit}{})",
                    if t == 1 { "" } else { "s" }
                ));
            }
        }
    }
    match how.trim().trim_end_matches('.') {
        "" => {}
        how => s.push_str(&format!("; each {verb} {unit}: {how}")),
    }
    s
}

/// The words of a shaping step of one row or round: `decrease 72 sts evenly (216 sts): *k2,
/// k2tog; rep from * to end`, or `decrease 1 st on the front (7 sts)`.
fn single_shape_text(change: i64, groups: &[String], how: &str, after: Option<u64>) -> String {
    let verb = if change < 0 { "decrease" } else { "increase" };
    let total = change.unsigned_abs() * groups.len().max(1) as u64;
    let names: Vec<String> = groups
        .iter()
        .map(|g| format!("the {}", display_name(g)))
        .collect();
    let mut s = match names.as_slice() {
        // "Evenly" only spreads more than one.
        [] if total == 1 => format!("{verb} 1 st"),
        [] => format!("{verb} {} evenly", sts(total)),
        [one] => format!("{verb} {} on {one}", sts(change.unsigned_abs())),
        [rest @ .., last] => format!(
            "{verb} {} on each of {} and {last}",
            sts(change.unsigned_abs()),
            rest.join(", ")
        ),
    };
    if let Some(after) = after {
        s.push_str(&format!(" ({})", sts(after)));
    }
    match how.trim().trim_end_matches('.') {
        "" => {}
        how => s.push_str(&format!(": {how}")),
    }
    s
}

/// `3rd`, `4th`, `21st`.
fn ordinal(n: u32) -> String {
    let suffix = match (n % 10, n % 100) {
        (1, 11) | (2, 12) | (3, 13) => "th",
        (1, _) => "st",
        (2, _) => "nd",
        (3, _) => "rd",
        _ => "th",
    };
    format!("{n}{suffix}")
}

fn nothing_past_problem() -> String {
    "turns with no stitches left past the turn; to work every stitch left in the row, use a plain \
     work step instead"
        .into()
}

fn side_unknown_problem() -> String {
    "Ply does not know which side of the work faces you here, so it cannot tell which way the \
     right side goes; say which side faces you in the step that returned these stitches"
        .into()
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

/// The longest a name a step, a count or a message refers to is shown, in characters; a longer one
/// is cut short with `...`. A file may give a group a name of 10,000 bytes, and every line that
/// counts it would otherwise repeat all of it.
pub const SHORT_NAME_CHARS: usize = 40;

/// The longest a section's title is shown where a message names the place, in characters.
pub const SECTION_IN_MESSAGE_CHARS: usize = 60;

/// A name as a reference to it is shown: trimmed, `unnamed` when empty, and at most
/// [`SHORT_NAME_CHARS`] characters.
fn display_name(name: &str) -> String {
    match name.trim() {
        "" => "unnamed".into(),
        n => short(n, SHORT_NAME_CHARS),
    }
}

/// `text` cut to at most `max` characters, ending `...` when it was longer.
pub(crate) fn short(text: &str, max: usize) -> String {
    if text.chars().count() <= max {
        return text.to_string();
    }
    let kept: String = text.chars().take(max.saturating_sub(3)).collect();
    format!("{}...", kept.trim_end())
}

/// Names as a message lists them: shortened, at most [`NAMED_IN_COUNT`], then how many more.
fn listed(names: &[String]) -> String {
    let mut parts: Vec<String> = names
        .iter()
        .take(NAMED_IN_COUNT)
        .map(|n| display_name(n))
        .collect();
    if names.len() > NAMED_IN_COUNT {
        parts.push(format!("and {} more", names.len() - NAMED_IN_COUNT));
    }
    parts.join(", ")
}

/// ` (center neck)`: a group on hold named where a step refers to it (empty when it has no name).
fn shown(name: &str) -> String {
    match name.trim() {
        "" => String::new(),
        n => format!(" ({})", short(n, SHORT_NAME_CHARS)),
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
            pieces: Vec::new(),
        }
    }

    fn section(id: &str, name: &str, steps: Vec<(&str, StepAction)>) -> Section {
        Section {
            id: id.into(),
            name: name.into(),
            notes: String::new(),
            construction: None,
            piece: None,
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
            decrease: None,
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
            decrease: None,
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
        assert!(check_limits(&p)
            .unwrap_err()
            .to_string()
            .contains("longer than"));
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
            .to_string()
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
    fn in_the_round_sections_are_counted_in_rounds() {
        let mut p = pat(
            Some(8),
            8,
            0,
            vec![section(
                "s1",
                "Leg",
                vec![
                    ("a", work(Knit, WorkTo::Count(3), false)),
                    ("b", work(Knit, WorkTo::End, false)),
                    ("c", work(Purl, WorkTo::End, false)),
                ],
            )],
        );
        p.construction = Construction::InTheRound;
        assert_eq!(
            lines(&p),
            vec![
                "Next rnd: knit 3 sts. (8 sts on the needle, 5 still to work in this rnd)",
                "Knit to end. (8 sts on the needle)",
                "Next rnd: purl to end. (8 sts on the needle)",
            ],
            "no turns: every round starts at the start of the round, from the right side"
        );
        assert!(messages(&p).is_empty(), "{:?}", messages(&p));
        let l = ledger(&p);
        let c = l.lines[2].count.counted().unwrap();
        assert!(c.in_round);
        assert_eq!(c.side, Some(Side::Rs));
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
