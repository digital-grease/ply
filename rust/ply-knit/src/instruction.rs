//! The ROW-INSTRUCTION IR: one drawn chart row turned into what the knitter actually works, with its
//! authored horizontal repeats made explicit. Written instructions ([`crate::written`]), stitch
//! counting ([`crate::flow`]) and validation ([`crate::validate`]) all read this one representation,
//! so they cannot disagree about what a row means. This module is the specification of a repeat's
//! meaning; the repeats ADR records why.
//!
//! **Meaning of a repeat.** `Row.cells` is the chart AS DRAWN. A [`RepeatSpan`](crate::RepeatSpan)
//! marks drawn cells `[start, end)` (storage columns, 0 = leftmost): the MOTIF. `Repeat::Times(n)`
//! works the motif `n` times in total; `Repeat::ToEnd` repeats it as often as the stitches on the
//! needle allow after reserving what the rest of the row consumes. The worked row is
//! `prefix + motif x n + suffix` in WORKING order. Cells are never duplicated into the chart.
//!
//! **Working order.** A flat right-side row and every round are worked right to left, a flat
//! wrong-side row left to right (as [`crate::written`] always has). The plain runs and spans are
//! mirrored with the row, each motif is read in the row's direction, and on a wrong-side row every
//! stitch is resolved to its [`StitchDef::ws_variant`](crate::StitchDef::ws_variant). So on a RS row
//! the "suffix" (the cells worked after the span) is the cells to the LEFT of the span.
//!
//! **What is refused.** A row whose repeats cannot be worked as authored becomes
//! [`RowInstruction::Unsupported`] with every [`RowProblem`] found; it is never flattened into the
//! drawn cells. See [`row_instruction`] for the list.

use crate::pattern::{builtin, ColorIndex, KnitPattern, Repeat, Row, Side, StitchId};

/// One worked stitch: a drawn cell resolved for the side its row is worked from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct StitchOp {
    /// Storage column of the drawn cell (0 = leftmost).
    pub column: usize,
    /// The legend stitch as drawn (its right-side identity).
    pub drawn: StitchId,
    /// The legend stitch as worked: the drawn stitch, or its WS variant on a wrong-side row.
    pub worked: StitchId,
    /// The cell's colorwork color (`None` = the working yarn).
    pub color: Option<ColorIndex>,
    /// Stitches the worked stitch takes from the row below.
    pub consumes: u32,
    /// Stitches the worked stitch makes on this row.
    pub produces: u32,
}

/// A repeat span as authored: its index in [`Row::repeats`] and its drawn columns.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SpanRef {
    /// Index of the span in the row's `repeats`.
    pub index: usize,
    /// First drawn storage column (inclusive).
    pub start: usize,
    /// Last drawn storage column (exclusive).
    pub end: usize,
}

/// One item of a worked row, in working order.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RowItem {
    /// A stitch worked once.
    Stitch(StitchOp),
    /// A motif worked `times` times in total (`[k2, p2] 3 times`).
    RepeatFixed {
        span: SpanRef,
        times: u16,
        motif: Vec<StitchOp>,
    },
    /// A motif repeated until only the stitches the rest of the row needs remain
    /// (`*k2, p2; rep from * to last st`).
    RepeatToEnd { span: SpanRef, motif: Vec<StitchOp> },
}

/// A drawn row as an instruction.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RowInstruction {
    /// The row's items in working order.
    Sequence(Vec<RowItem>),
    /// The row's repeats cannot be worked as authored. Nothing is flattened: callers must report
    /// the problems instead of guessing.
    Unsupported(Vec<RowProblem>),
}

/// Why a row's repeats cannot be worked, or why its stitches cannot be counted. Structural problems
/// come from [`row_instruction`]; the counting ones from [`crate::flow::stitch_flow`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RowProblem {
    /// `Times(0)`: a repeat must be worked at least once.
    ZeroTimes(SpanRef),
    /// The span is empty, inverted, or runs past the row's cells.
    OutOfRange { span: SpanRef, cells: usize },
    /// Two spans share columns without one containing the other (or are the same columns).
    Overlap { first: SpanRef, second: SpanRef },
    /// One span lies inside another: repeats inside repeats are not supported yet.
    Nested { outer: SpanRef, inner: SpanRef },
    /// More than one span in the row is worked to the end.
    SeveralToEnd { first: SpanRef, second: SpanRef },
    /// The span cuts through a cable (the cable cell and its trailing no-stitch fillers).
    SplitsCable {
        span: SpanRef,
        cable_start: usize,
        cable_end: usize,
    },
    /// The motif has no worked stitches (only no-stitch cells).
    NoStitches(SpanRef),
    /// A to-end motif that takes no stitches from the row below would never end.
    ToEndUsesNothing(SpanRef),
    /// A to-end repeat whose available stitch count is unknown: the first row of a pattern with no
    /// cast-on count, or a row after one that could not be counted. `motif` and `reserved` give the
    /// "multiple of `motif` plus `reserved`" the row works over.
    ToEndUnknownCount {
        span: SpanRef,
        first_row: bool,
        motif: u64,
        reserved: u64,
    },
    /// The stitches left for a to-end repeat are not a whole number of motifs.
    ToEndNotDivisible {
        span: SpanRef,
        available: u64,
        reserved: u64,
        motif: u64,
    },
    /// The rest of the row needs more stitches than are available.
    ToEndNoRoom {
        span: SpanRef,
        available: u64,
        reserved: u64,
    },
    /// The rest of the row uses every available stitch, leaving none for the repeat.
    ToEndNoneLeft { span: SpanRef, available: u64 },
    /// The worked stitch count does not fit in 64 bits.
    CountTooLarge,
    /// The row consumes a different number of stitches than the row below produced.
    CountMismatch { consumed: u64, produced_below: u64 },
    /// The first row consumes a different number of stitches than the pattern casts on.
    CastOnMismatch { consumed: u64, cast_on: u64 },
}

impl RowProblem {
    /// Whether this problem is advisory. Only an unknown to-end count is: the row is not wrong, Ply
    /// just cannot count it. Everything else is an error.
    pub fn is_warning(&self) -> bool {
        matches!(self, RowProblem::ToEndUnknownCount { .. })
    }

    /// A stable identifier for tests and future tooling (never shown to the user).
    pub fn code(&self) -> &'static str {
        match self {
            RowProblem::ZeroTimes(_) => "repeat-zero-times",
            RowProblem::OutOfRange { .. } => "repeat-out-of-range",
            RowProblem::Overlap { .. } => "repeat-overlap",
            RowProblem::Nested { .. } => "repeat-nested",
            RowProblem::SeveralToEnd { .. } => "repeat-several-to-end",
            RowProblem::SplitsCable { .. } => "repeat-splits-cable",
            RowProblem::NoStitches(_) => "repeat-no-stitches",
            RowProblem::ToEndUsesNothing(_) => "repeat-to-end-uses-nothing",
            RowProblem::ToEndUnknownCount { .. } => "repeat-to-end-unknown-count",
            RowProblem::ToEndNotDivisible { .. } => "repeat-to-end-not-divisible",
            RowProblem::ToEndNoRoom { .. } => "repeat-to-end-no-room",
            RowProblem::ToEndNoneLeft { .. } => "repeat-to-end-none-left",
            RowProblem::CountTooLarge => "stitch-count-too-large",
            RowProblem::CountMismatch { .. } => "stitch-count-mismatch",
            RowProblem::CastOnMismatch { .. } => "cast-on-mismatch",
        }
    }

    /// The span this problem is about, if it is about one.
    pub fn span(&self) -> Option<SpanRef> {
        match *self {
            RowProblem::ZeroTimes(s)
            | RowProblem::OutOfRange { span: s, .. }
            | RowProblem::SplitsCable { span: s, .. }
            | RowProblem::NoStitches(s)
            | RowProblem::ToEndUsesNothing(s)
            | RowProblem::ToEndUnknownCount { span: s, .. }
            | RowProblem::ToEndNotDivisible { span: s, .. }
            | RowProblem::ToEndNoRoom { span: s, .. }
            | RowProblem::ToEndNoneLeft { span: s, .. } => Some(s),
            RowProblem::Overlap { first: s, .. }
            | RowProblem::Nested { outer: s, .. }
            | RowProblem::SeveralToEnd { first: s, .. } => Some(s),
            RowProblem::CountTooLarge
            | RowProblem::CountMismatch { .. }
            | RowProblem::CastOnMismatch { .. } => None,
        }
    }

    /// The problem as a sentence fragment without the row number, for the written instructions
    /// (`the repeats over cols 2-5 and 4-7 overlap`). `row` is 0-based (used only by messages that
    /// name what the row works from: the row below, or for the first row the cast-on); `cols` maps
    /// storage columns to reading-order numbers.
    pub fn reason(&self, row: usize, cols: &ReadingCols) -> String {
        let from = if row == 0 {
            CountSource::CastOn
        } else {
            CountSource::RowBelow(row)
        };
        self.reason_from(from, cols)
    }

    /// [`RowProblem::reason`] with the row's stitches coming from `from`: the cast-on, the chart row
    /// below, or (in a section, [`crate::sections`]) the stitches left to work in the row.
    pub fn reason_from(&self, from: CountSource, cols: &ReadingCols) -> String {
        // Where the row's stitches come from: "row 2 produced 14 stitches" / "the cast-on is 14
        // stitches" (a first row has a known count only when the pattern states a cast-on) / "14
        // stitches are left to work in this row".
        let row = match from {
            CountSource::RowBelow(r) => r,
            _ => 0,
        };
        let source = |n: u64| match from {
            CountSource::CastOn => format!("the cast-on is {}", stitches(n)),
            CountSource::RowBelow(r) => format!("row {r} produced {}", stitches(n)),
            CountSource::InRow => format!(
                "{} {} left to work in this row",
                stitches(n),
                if n == 1 { "is" } else { "are" }
            ),
        };
        match *self {
            RowProblem::ZeroTimes(s) => format!(
                "the repeat over {} is worked 0 times; a repeat must be worked at least once",
                cols.span(s)
            ),
            RowProblem::OutOfRange { span, cells } if span.start >= span.end => format!(
                "a repeat covers no columns (stored as {}..{} on a {cells}-column row)",
                span.start, span.end
            ),
            RowProblem::OutOfRange { span, cells } => format!(
                "a repeat runs past the edge of the row (stored as {}..{} on a {cells}-column row)",
                span.start, span.end
            ),
            RowProblem::Overlap { first, second } => {
                let (a, b) = cols.in_reading_order(first, second);
                format!(
                    "the repeats over {} and {} overlap",
                    cols.span(a),
                    cols.span(b)
                )
            }
            RowProblem::Nested { outer, inner } => format!(
                "the repeat over {} is inside the repeat over {}; a repeat inside a repeat is not supported yet",
                cols.span(inner),
                cols.span(outer)
            ),
            RowProblem::SeveralToEnd { first, second } => {
                let (a, b) = cols.in_reading_order(first, second);
                format!(
                    "the repeats over {} and {} are both worked to the end of the row; a row can have only one",
                    cols.span(a),
                    cols.span(b)
                )
            }
            RowProblem::SplitsCable {
                span,
                cable_start,
                cable_end,
            } => format!(
                "the repeat over {} splits the cable at {}; a cable must be wholly inside or outside a repeat",
                cols.span(span),
                cols.range(cable_start, cable_end)
            ),
            RowProblem::NoStitches(s) => {
                format!("the repeat over {} has no stitches to work", cols.span(s))
            }
            RowProblem::ToEndUsesNothing(s) => format!(
                "the repeat over {} is worked to the end of the row but takes no stitches from the row below, so it would never end",
                cols.span(s)
            ),
            RowProblem::ToEndUnknownCount {
                span,
                first_row,
                motif,
                reserved,
            } => {
                let (why, fix) = match from {
                    CountSource::InRow => (
                        "Ply does not know how many stitches are on the needle here".to_string(),
                        "",
                    ),
                    _ if first_row => (
                        "the pattern has no cast-on count".to_string(),
                        "; set the cast-on in the pattern settings",
                    ),
                    _ => (format!("the stitch count after row {row} is unknown"), ""),
                };
                format!(
                    "the repeat over {} is worked to the end of the row, but {why}, so Ply cannot count this row (it needs {}){fix}",
                    cols.span(span),
                    multiple_of(motif, reserved)
                )
            }
            RowProblem::ToEndNotDivisible {
                span,
                available,
                reserved,
                motif,
            } => format!(
                "the repeat over {} cannot be worked to the end: {}, the rest of the row uses {reserved}, and the {} left {} not a multiple of {motif}",
                cols.span(span),
                source(available),
                available.saturating_sub(reserved),
                if available.saturating_sub(reserved) == 1 { "is" } else { "are" }
            ),
            RowProblem::ToEndNoRoom {
                span,
                available,
                reserved,
            } => format!(
                "the repeat over {} cannot be worked to the end: {} but the rest of the row uses {reserved}",
                cols.span(span),
                source(available)
            ),
            RowProblem::ToEndNoneLeft { span, available } => {
                let of = match from {
                    CountSource::CastOn => "of the cast-on".to_string(),
                    CountSource::RowBelow(r) => format!("row {r} produced"),
                    CountSource::InRow => "left to work in this row".to_string(),
                };
                format!(
                    "the repeat over {} cannot be worked to the end: the rest of the row uses all {} {of}, leaving none for the repeat",
                    cols.span(span),
                    stitches(available)
                )
            }
            RowProblem::CountTooLarge => {
                "has too many stitches to count".to_string()
            }
            RowProblem::CountMismatch {
                consumed,
                produced_below,
            } => format!(
                "consumes {consumed} stitches but row {} produced {produced_below}",
                row
            ),
            RowProblem::CastOnMismatch { consumed, cast_on } => {
                format!("consumes {consumed} stitches but the cast-on is {cast_on}")
            }
        }
    }

    /// The full user-facing message, starting with the 1-based row number (`row 3: ...`). The
    /// stitch-count mismatches keep the established wording (`row 3 consumes 12 stitches but row 2
    /// produced 14`, `row 1 consumes 24 stitches but the cast-on is 26`).
    pub fn message(&self, row: usize, cols: &ReadingCols) -> String {
        let n = row + 1;
        match self {
            RowProblem::CountMismatch { .. }
            | RowProblem::CastOnMismatch { .. }
            | RowProblem::CountTooLarge => {
                format!("row {n} {}", self.reason(row, cols))
            }
            _ => format!("row {n}: {}", self.reason(row, cols)),
        }
    }
}

/// Where a row's stitches come from, for the wording of a counting problem.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CountSource {
    /// The pattern's cast-on (chart row 1 of a chart-only pattern).
    CastOn,
    /// What chart row `n` (1-based) produced.
    RowBelow(usize),
    /// The stitches the section ledger has left to work in the row ([`crate::sections`]).
    InRow,
}

/// "a multiple of 4 stitches plus 2" (or "... stitches" when nothing is reserved).
fn multiple_of(motif: u64, reserved: u64) -> String {
    let base = if motif == 1 {
        "any number of stitches".to_string()
    } else {
        format!("a multiple of {motif} stitches")
    };
    if reserved == 0 {
        base
    } else if motif == 1 {
        format!("at least {} stitches", reserved + 1)
    } else {
        format!("{base} plus {reserved}")
    }
}

fn stitches(n: u64) -> String {
    if n == 1 {
        "1 stitch".to_string()
    } else {
        format!("{n} stitches")
    }
}

/// Maps storage columns to the 1-based READING-order column numbers a knitter counts (and the chart's
/// bottom axis shows): a RS row (and every round) is numbered right to left, a WS row left to right.
/// The same rule as the validation messages' `col N`.
#[derive(Debug, Clone, Copy)]
pub struct ReadingCols {
    rs: bool,
    width: usize,
}

impl ReadingCols {
    /// Reading-order numbering for a row worked from side `rs` on a chart `width` columns wide.
    pub fn new(rs: bool, width: usize) -> Self {
        ReadingCols { rs, width }
    }

    /// For chart row `row` of `pattern` (0-based).
    pub fn for_row(pattern: &KnitPattern, row: usize) -> Self {
        ReadingCols::new(pattern.row_side(row) == Side::Rs, pattern.chart.width)
    }

    /// The reading-order number of storage column `idx`. A ragged over-wide index falls back to
    /// `idx + 1` rather than underflow.
    pub fn col(&self, idx: usize) -> usize {
        if self.rs && self.width > idx {
            self.width - idx
        } else {
            idx + 1
        }
    }

    /// `cols 2-5` (or `col 3`) for storage columns `[start, end)`, lowest number first.
    pub fn range(&self, start: usize, end: usize) -> String {
        if end <= start {
            return format!("col {}", self.col(start));
        }
        let (a, b) = (self.col(start), self.col(end - 1));
        let (lo, hi) = if a <= b { (a, b) } else { (b, a) };
        if lo == hi {
            format!("col {lo}")
        } else {
            format!("cols {lo}-{hi}")
        }
    }

    fn span(&self, s: SpanRef) -> String {
        self.range(s.start, s.end)
    }

    /// Two spans ordered by where a knitter meets them (lowest reading-order column first).
    fn in_reading_order(&self, a: SpanRef, b: SpanRef) -> (SpanRef, SpanRef) {
        let first_col = |s: SpanRef| self.col(s.start).min(self.col(s.end.saturating_sub(1)));
        if first_col(b) < first_col(a) {
            (b, a)
        } else {
            (a, b)
        }
    }
}

/// The (consumed, produced) totals of a run of stitch ops, checked.
pub fn op_totals(ops: &[StitchOp]) -> Option<(u64, u64)> {
    ops.iter().try_fold((0u64, 0u64), |(c, p), op| {
        Some((
            c.checked_add(u64::from(op.consumes))?,
            p.checked_add(u64::from(op.produces))?,
        ))
    })
}

impl RowItem {
    /// The (consumed, produced) totals of this item, or `None` for a to-end repeat (whose count is
    /// not the item's own) or on overflow.
    pub fn fixed_totals(&self) -> Option<(u64, u64)> {
        match self {
            RowItem::Stitch(op) => Some((u64::from(op.consumes), u64::from(op.produces))),
            RowItem::RepeatFixed { times, motif, .. } => {
                let (c, p) = op_totals(motif)?;
                let t = u64::from(*times);
                Some((c.checked_mul(t)?, p.checked_mul(t)?))
            }
            RowItem::RepeatToEnd { .. } => None,
        }
    }
}

impl RowInstruction {
    /// The row's items, or `None` if it is unsupported.
    pub fn items(&self) -> Option<&[RowItem]> {
        match self {
            RowInstruction::Sequence(items) => Some(items),
            RowInstruction::Unsupported(_) => None,
        }
    }

    /// The span and motif of the row's to-end repeat, if it has one.
    pub fn to_end(&self) -> Option<(SpanRef, &[StitchOp])> {
        self.items()?.iter().find_map(|item| match item {
            RowItem::RepeatToEnd { span, motif } => Some((*span, motif.as_slice())),
            _ => None,
        })
    }

    /// The EXPANDED worked sequence: every stitch in working order, each motif written out the
    /// number of times it is worked. `to_end_times` is how often the to-end repeat is worked (from
    /// [`crate::flow::stitch_flow`]); it is required when the row has one. `None` for an unsupported
    /// row or a missing count.
    ///
    /// This allocates the whole worked row, so it is for display, export and tests. Counting uses the
    /// equivalent arithmetic in [`crate::flow`], which a property test holds equal to the sums over
    /// this expansion.
    pub fn expand(&self, to_end_times: Option<u64>) -> Option<Vec<StitchOp>> {
        let items = self.items()?;
        let mut out = Vec::new();
        for item in items {
            match item {
                RowItem::Stitch(op) => out.push(*op),
                RowItem::RepeatFixed { times, motif, .. } => {
                    for _ in 0..*times {
                        out.extend_from_slice(motif);
                    }
                }
                RowItem::RepeatToEnd { motif, .. } => {
                    for _ in 0..to_end_times? {
                        out.extend_from_slice(motif);
                    }
                }
            }
        }
        Some(out)
    }
}

/// Build the instruction for chart row `r` (0-based). Out of range yields an empty sequence.
///
/// The row is `Unsupported` when any span is: worked `Times(0)`; outside the row (empty, inverted, or
/// past the row's cells); overlapping or nested with another; one of two or more to-end spans; cutting
/// through a cable group; a motif with no worked stitches; or a to-end motif that consumes nothing.
/// Any number of non-overlapping `Times` spans, plus at most one `ToEnd`, are allowed.
pub fn row_instruction(pattern: &KnitPattern, r: usize) -> RowInstruction {
    let Some(row) = pattern.chart.rows.get(r) else {
        return RowInstruction::Sequence(Vec::new());
    };
    let rs = pattern.row_side(r) == Side::Rs;

    let problems = span_problems(pattern, row, rs);
    if !problems.is_empty() {
        return RowInstruction::Unsupported(problems);
    }

    // Storage-order segments: plain runs between spans, and the spans themselves.
    let mut spans = span_refs(row);
    spans.sort_by_key(|s| s.start);
    enum Segment {
        Plain(usize, usize),
        Span(SpanRef, Repeat),
    }
    let len = row.cells.len();
    let mut segments = Vec::with_capacity(spans.len() * 2 + 1);
    let mut col = 0;
    for s in spans {
        if col < s.start {
            segments.push(Segment::Plain(col, s.start));
        }
        segments.push(Segment::Span(s, row.repeats[s.index].count));
        col = s.end;
    }
    if col < len {
        segments.push(Segment::Plain(col, len));
    }
    // Working order: a RS row (and every round) is worked right to left.
    if rs {
        segments.reverse();
    }

    let mut items = Vec::with_capacity(len);
    for seg in segments {
        match seg {
            Segment::Plain(a, b) => {
                items.extend(ops(pattern, row, a, b, rs).into_iter().map(RowItem::Stitch))
            }
            Segment::Span(span, count) => {
                let motif = ops(pattern, row, span.start, span.end, rs);
                items.push(match count {
                    Repeat::Times(times) => RowItem::RepeatFixed { span, times, motif },
                    Repeat::ToEnd => RowItem::RepeatToEnd { span, motif },
                });
            }
        }
    }
    RowInstruction::Sequence(items)
}

/// Every span of `row` as a [`SpanRef`], in stored order.
fn span_refs(row: &Row) -> Vec<SpanRef> {
    row.repeats
        .iter()
        .enumerate()
        .map(|(index, s)| SpanRef {
            index,
            start: s.start,
            end: s.end,
        })
        .collect()
}

/// The worked stitch ops for storage columns `[a, b)` of `row`, in working order. No-stitch cells
/// (including cable fillers) and cells naming a stitch outside the legend (already an error) are not
/// worked, so they yield nothing.
fn ops(pattern: &KnitPattern, row: &Row, a: usize, b: usize, rs: bool) -> Vec<StitchOp> {
    let legend = &pattern.legend;
    let b = b.min(row.cells.len());
    let a = a.min(b);
    let op = |c: usize| -> Option<StitchOp> {
        let cell = row.cells[c];
        if cell.stitch == builtin::NO_STITCH {
            return None;
        }
        let drawn = legend.get(cell.stitch)?;
        // WS resolution: a stitch worked on the wrong side is its ws_variant (when that exists).
        let (worked, def) = if rs {
            (cell.stitch, drawn)
        } else {
            match drawn
                .ws_variant
                .and_then(|id| legend.get(id).map(|d| (id, d)))
            {
                Some(found) => found,
                None => (cell.stitch, drawn),
            }
        };
        Some(StitchOp {
            column: c,
            drawn: cell.stitch,
            worked,
            color: cell.color,
            consumes: u32::from(def.consumes),
            produces: u32::from(def.produces),
        })
    };
    if rs {
        (a..b).rev().filter_map(op).collect()
    } else {
        (a..b).filter_map(op).collect()
    }
}

/// The cable groups of a row: `[anchor, anchor + span)` for every cable cell, clamped to the cells.
fn cable_groups(pattern: &KnitPattern, row: &Row) -> Vec<(usize, usize)> {
    let len = row.cells.len();
    row.cells
        .iter()
        .enumerate()
        .filter_map(|(c, cell)| {
            let span = pattern.legend.get(cell.stitch)?.cable?.span() as usize;
            (span > 1).then(|| (c, (c + span).min(len)))
        })
        .collect()
}

/// Every structural problem with `row`'s repeats (empty = the row can be worked as authored).
fn span_problems(pattern: &KnitPattern, row: &Row, rs: bool) -> Vec<RowProblem> {
    let mut problems = Vec::new();
    if row.repeats.is_empty() {
        return problems;
    }
    let len = row.cells.len();
    let spans = span_refs(row);

    // Out of range, and Times(0). An out-of-range span is excluded from the pairwise checks.
    let mut valid: Vec<SpanRef> = Vec::with_capacity(spans.len());
    for s in &spans {
        if s.start >= s.end || s.end > len {
            problems.push(RowProblem::OutOfRange {
                span: *s,
                cells: len,
            });
            continue;
        }
        if row.repeats[s.index].count == Repeat::Times(0) {
            problems.push(RowProblem::ZeroTimes(*s));
        }
        valid.push(*s);
    }

    // Overlapping or nested spans.
    for (i, a) in valid.iter().enumerate() {
        for b in &valid[i + 1..] {
            if a.start < b.end && b.start < a.end {
                let a_in_b = b.start <= a.start && a.end <= b.end;
                let b_in_a = a.start <= b.start && b.end <= a.end;
                problems.push(if a_in_b && b_in_a {
                    RowProblem::Overlap {
                        first: *a,
                        second: *b,
                    }
                } else if b_in_a {
                    RowProblem::Nested {
                        outer: *a,
                        inner: *b,
                    }
                } else if a_in_b {
                    RowProblem::Nested {
                        outer: *b,
                        inner: *a,
                    }
                } else {
                    RowProblem::Overlap {
                        first: *a,
                        second: *b,
                    }
                });
            }
        }
    }

    // More than one span worked to the end.
    let to_end: Vec<SpanRef> = valid
        .iter()
        .copied()
        .filter(|s| row.repeats[s.index].count == Repeat::ToEnd)
        .collect();
    for second in to_end.iter().skip(1) {
        problems.push(RowProblem::SeveralToEnd {
            first: to_end[0],
            second: *second,
        });
    }

    // A span must hold a cable group wholly or not at all.
    let groups = cable_groups(pattern, row);
    for s in &valid {
        for &(g0, g1) in &groups {
            let cuts = |edge: usize| edge > g0 && edge < g1;
            if cuts(s.start) || cuts(s.end) {
                problems.push(RowProblem::SplitsCable {
                    span: *s,
                    cable_start: g0,
                    cable_end: g1,
                });
            }
        }
    }

    // The motif must work something, and a to-end motif must take stitches from the row below.
    for s in &valid {
        let motif = ops(pattern, row, s.start, s.end, rs);
        if motif.is_empty() {
            problems.push(RowProblem::NoStitches(*s));
        } else if row.repeats[s.index].count == Repeat::ToEnd
            && motif.iter().all(|op| op.consumes == 0)
        {
            problems.push(RowProblem::ToEndUsesNothing(*s));
        }
    }

    problems
}

/// A [`RepeatSpan`] over storage columns `[start, end)`, worked `count`.
#[cfg(test)]
pub(crate) fn span(start: usize, end: usize, count: Repeat) -> crate::pattern::RepeatSpan {
    crate::pattern::RepeatSpan { start, end, count }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::pattern::*;
    use ply_common::{Color, Unit};

    fn pat(width: usize, rows: Vec<Row>, construction: Construction, first: Side) -> KnitPattern {
        KnitPattern {
            name: "t".into(),
            construction,
            first_row_side: first,
            cast_on: None,
            gauge: Gauge {
                sts: 20.0,
                rows: 28.0,
                unit: Unit::Inches,
            },
            palette: vec![Color::WHITE],
            legend: StitchLegend::builtin(),
            chart: Chart { width, rows },
            notes: String::new(),
            sections: Vec::new(),
            pieces: Vec::new(),
        }
    }

    fn row(ids: &[usize], repeats: Vec<RepeatSpan>) -> Row {
        Row {
            cells: ids.iter().map(|&i| Cell::of(i)).collect(),
            repeats,
        }
    }

    use builtin::{KNIT as K, NO_STITCH as NS, PURL as P};

    fn codes(i: &RowInstruction) -> Vec<&'static str> {
        match i {
            RowInstruction::Unsupported(ps) => ps.iter().map(RowProblem::code).collect(),
            RowInstruction::Sequence(_) => vec![],
        }
    }

    #[test]
    fn a_rs_row_is_mirrored_with_its_span() {
        // Storage [k | p p k k | k], span 1..5 x3. RS works right to left: edge k (col 5), the motif
        // read right to left (k k p p), then edge k (col 0).
        let p = pat(
            6,
            vec![row(&[K, P, P, K, K, K], vec![span(1, 5, Repeat::Times(3))])],
            Construction::Flat,
            Side::Rs,
        );
        let RowInstruction::Sequence(items) = row_instruction(&p, 0) else {
            panic!("supported")
        };
        assert_eq!(items.len(), 3);
        assert!(matches!(
            items[0],
            RowItem::Stitch(StitchOp { column: 5, .. })
        ));
        let RowItem::RepeatFixed { times, motif, .. } = &items[1] else {
            panic!("fixed repeat")
        };
        assert_eq!(*times, 3);
        assert_eq!(
            motif.iter().map(|o| o.column).collect::<Vec<_>>(),
            vec![4, 3, 2, 1]
        );
        assert!(matches!(
            items[2],
            RowItem::Stitch(StitchOp { column: 0, .. })
        ));
    }

    #[test]
    fn a_ws_row_reads_left_to_right_with_ws_variants() {
        let p = pat(
            6,
            vec![row(&[K, P, P, K, K, K], vec![span(1, 5, Repeat::Times(3))])],
            Construction::Flat,
            Side::Ws,
        );
        let RowInstruction::Sequence(items) = row_instruction(&p, 0) else {
            panic!("supported")
        };
        let RowItem::RepeatFixed { motif, .. } = &items[1] else {
            panic!("fixed repeat")
        };
        // Storage order 1..5 (p p k k drawn) worked as k k p p on the wrong side.
        assert_eq!(
            motif
                .iter()
                .map(|o| (o.column, o.worked))
                .collect::<Vec<_>>(),
            vec![(1, K), (2, K), (3, P), (4, P)]
        );
        assert!(matches!(
            items[0],
            RowItem::Stitch(StitchOp {
                column: 0,
                worked: P,
                ..
            })
        ));
    }

    #[test]
    fn expansion_writes_each_motif_out() {
        let p = pat(
            6,
            vec![row(&[K, P, P, K, K, K], vec![span(1, 5, Repeat::Times(3))])],
            Construction::InTheRound,
            Side::Rs,
        );
        let worked = row_instruction(&p, 0).expand(None).unwrap();
        assert_eq!(worked.len(), 14, "edge + 4 x 3 + edge");
        assert_eq!(op_totals(&worked), Some((14, 14)));
    }

    #[test]
    fn a_to_end_row_needs_its_count_to_expand() {
        let p = pat(
            6,
            vec![row(&[K, P, P, K, K, K], vec![span(1, 5, Repeat::ToEnd)])],
            Construction::InTheRound,
            Side::Rs,
        );
        let i = row_instruction(&p, 0);
        assert_eq!(i.expand(None), None);
        assert_eq!(i.expand(Some(2)).unwrap().len(), 10);
    }

    #[test]
    fn rejected_shapes_are_unsupported_with_a_reason() {
        let cases: Vec<(Vec<RepeatSpan>, &str)> = vec![
            (vec![span(1, 3, Repeat::Times(0))], "repeat-zero-times"),
            (vec![span(4, 9, Repeat::Times(2))], "repeat-out-of-range"),
            (vec![span(3, 3, Repeat::Times(2))], "repeat-out-of-range"),
            (vec![span(4, 2, Repeat::Times(2))], "repeat-out-of-range"),
            (
                vec![span(0, 3, Repeat::Times(2)), span(2, 5, Repeat::Times(2))],
                "repeat-overlap",
            ),
            (
                vec![span(1, 3, Repeat::Times(2)), span(1, 3, Repeat::Times(4))],
                "repeat-overlap",
            ),
            (
                vec![span(0, 6, Repeat::Times(2)), span(2, 4, Repeat::Times(2))],
                "repeat-nested",
            ),
            (
                vec![span(0, 2, Repeat::ToEnd), span(3, 5, Repeat::ToEnd)],
                "repeat-several-to-end",
            ),
        ];
        for (repeats, code) in cases {
            let p = pat(
                6,
                vec![row(&[K, P, K, P, K, P], repeats.clone())],
                Construction::InTheRound,
                Side::Rs,
            );
            assert_eq!(
                codes(&row_instruction(&p, 0)),
                vec![code],
                "{repeats:?} must be refused as {code}"
            );
        }
    }

    #[test]
    fn two_fixed_spans_and_one_to_end_are_allowed() {
        let p = pat(
            8,
            vec![row(
                &[K, P, K, P, K, P, K, P],
                vec![
                    span(0, 2, Repeat::Times(2)),
                    span(2, 4, Repeat::ToEnd),
                    span(5, 7, Repeat::Times(3)),
                ],
            )],
            Construction::InTheRound,
            Side::Rs,
        );
        assert!(matches!(
            row_instruction(&p, 0),
            RowInstruction::Sequence(_)
        ));
    }

    #[test]
    fn a_motif_of_only_no_stitch_or_a_to_end_that_uses_nothing_is_refused() {
        let p = pat(
            4,
            vec![row(&[K, NS, NS, K], vec![span(1, 3, Repeat::Times(2))])],
            Construction::InTheRound,
            Side::Rs,
        );
        assert_eq!(codes(&row_instruction(&p, 0)), vec!["repeat-no-stitches"]);
        let yo = builtin::YO;
        let p = pat(
            4,
            vec![row(&[K, yo, yo, K], vec![span(1, 3, Repeat::ToEnd)])],
            Construction::InTheRound,
            Side::Rs,
        );
        assert_eq!(
            codes(&row_instruction(&p, 0)),
            vec!["repeat-to-end-uses-nothing"]
        );
        // A fixed repeat of increases is fine: [yo] 2 times makes two stitches.
        let p = pat(
            4,
            vec![row(&[K, yo, K, K], vec![span(1, 2, Repeat::Times(2))])],
            Construction::InTheRound,
            Side::Rs,
        );
        assert!(matches!(
            row_instruction(&p, 0),
            RowInstruction::Sequence(_)
        ));
    }

    fn with_cable(mut p: KnitPattern) -> (KnitPattern, usize) {
        p.legend.stitches.push(StitchDef {
            symbol: "2/2 RC".into(),
            consumes: 4,
            produces: 4,
            ws_variant: None,
            cable: Some(CableDef {
                front: 2,
                back: 2,
                direction: Cross::Right,
                front_purl: false,
                back_purl: false,
            }),
            macro_rows: 1,
        });
        let id = p.legend.stitches.len() - 1;
        (p, id)
    }

    #[test]
    fn a_cable_inside_a_repeat_is_worked_but_a_split_cable_is_refused() {
        let (base, c) = with_cable(pat(6, vec![], Construction::InTheRound, Side::Rs));
        let cells = [P, c, NS, NS, NS, P];
        // Inside: the whole group 1..5 is in the motif.
        let mut p = base.clone();
        p.chart.rows = vec![row(&cells, vec![span(0, 6, Repeat::Times(2))])];
        let RowInstruction::Sequence(items) = row_instruction(&p, 0) else {
            panic!("supported")
        };
        let RowItem::RepeatFixed { motif, .. } = &items[0] else {
            panic!("fixed")
        };
        assert_eq!(
            motif.iter().map(|o| o.drawn).collect::<Vec<_>>(),
            vec![P, c, P],
            "the cable is one worked op; its fillers are not worked"
        );
        // Crossing either edge of the group is refused, and so is a span inside its fillers (which
        // also has no stitches of its own to work).
        for s in [
            span(2, 6, Repeat::Times(2)),
            span(0, 3, Repeat::Times(2)),
            span(2, 4, Repeat::Times(2)),
        ] {
            p.chart.rows = vec![row(&cells, vec![s])];
            let i = row_instruction(&p, 0);
            assert_eq!(codes(&i)[0], "repeat-splits-cable", "{s:?}");
        }
        // A span next to the cable (sharing an edge) does not split it.
        p.chart.rows = vec![row(&cells, vec![span(5, 6, Repeat::Times(2))])];
        assert!(matches!(
            row_instruction(&p, 0),
            RowInstruction::Sequence(_)
        ));
    }

    #[test]
    fn reasons_name_reading_order_columns() {
        let cols = ReadingCols::new(true, 6);
        assert_eq!(cols.range(1, 5), "cols 2-5");
        assert_eq!(cols.range(0, 1), "col 6");
        let cols = ReadingCols::new(false, 6);
        assert_eq!(cols.range(0, 2), "cols 1-2");
        let s = SpanRef {
            index: 0,
            start: 0,
            end: 2,
        };
        assert_eq!(
            RowProblem::ZeroTimes(s).message(2, &ReadingCols::new(true, 6)),
            "row 3: the repeat over cols 5-6 is worked 0 times; a repeat must be worked at least once"
        );
    }

    #[test]
    fn multiple_of_reads_naturally() {
        assert_eq!(multiple_of(4, 2), "a multiple of 4 stitches plus 2");
        assert_eq!(multiple_of(4, 0), "a multiple of 4 stitches");
        assert_eq!(multiple_of(1, 0), "any number of stitches");
        assert_eq!(multiple_of(1, 2), "at least 3 stitches");
    }
}
