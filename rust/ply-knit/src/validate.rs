//! Structural + stitch-count validation of a knitting chart — the knitting analog of `ply-weave`'s
//! `validate.rs`, and (like weaving's shed logic) the single place stitch arithmetic lives so the
//! renderer and editor never re-derive it.
//!
//! Owner decision #7 = FULL stitch-count balancing: each row must consume exactly the stitches the
//! row below produced (so a stray `yo` without its matching decrease is caught), cables must fit their
//! span and be trailed by no-stitch, every cell must reference a real legend stitch / palette color,
//! and the grid stays rectangular.
//!
//! Stitch counts come from [`crate::flow`], which counts each row's WORKED sequence: authored repeats
//! are expanded (`Times(n)` works the motif n times, `ToEnd` resolves from the row below), so a row
//! drawn as 6 cells with a 4-cell motif worked 3 times counts as the 14 stitches it makes. Every repeat
//! problem it finds (a span worked 0 times, outside the row, overlapping, nested, a second to-end span,
//! a split cable, a to-end count that does not divide or cannot be known) is reported here with its
//! row and columns (see [`crate::instruction`]).
//!
//! When the pattern states a cast-on ([`KnitPattern::cast_on`]), row 1 must consume exactly that
//! many stitches, and a cast-on of 0 is an error. Without one, row 1's own count is the start.
//!
//! A pattern with SECTIONS ([`KnitPattern::sections`]) is checked by its stitch ledger instead of
//! bottom-to-top row continuity: every chart row's cells and repeats are checked as above, and each
//! row's stitch count where a section works it ([`crate::sections`]); the ledger's problems carry
//! their place (`Back, step 3: ...`).
//!
//! Every finding carries a stable code and a typed [`KnitLocation`] (ADR 0021) beside the sentence the
//! editor shows: tests and navigation key on the code and the location, never on the words.

use crate::flow::stitch_flow;
use crate::instruction::{row_instruction, ReadingCols, RowInstruction, RowProblem};
use crate::pattern::{builtin, KnitPattern, Row, Side, StitchLegend};
use crate::sections;

/// The severity vocabulary every craft shares (ADR 0021). Errors are hard problems; warnings are
/// advisory. Knitting validation reports errors and warnings; the steps Ply does not check are
/// listed by readiness ([`crate::readiness`]).
pub use ply_common::readiness::Severity;

/// The code of a stated cast-on of 0.
pub const CAST_ON_ZERO: &str = "cast-on-zero";
/// The code of a row whose cell count is not the chart width.
pub const ROW_WIDTH: &str = "row-width";
/// The code of a cell naming a stitch the legend does not have.
pub const UNKNOWN_STITCH: &str = "unknown-stitch";
/// The code of a cell naming a palette color the pattern does not have.
pub const COLOR_OUT_OF_RANGE: &str = "color-out-of-range";
/// The code of a cable whose consumes/produces are not its span.
pub const CABLE_COUNTS: &str = "cable-counts";
/// The code of a cable that runs past the chart edge.
pub const CABLE_PAST_EDGE: &str = "cable-past-edge";
/// The code of a cable not followed by its no-stitch cells.
pub const CABLE_FILLER: &str = "cable-filler";
/// The code of a stitch-ledger finding about one section step (ADR 0013).
pub const SECTION_STEP: &str = "section-step";
/// The code of a stitch-ledger finding about the construction as a whole.
pub const SECTIONS: &str = "sections";

/// Where a knitting finding applies. Rows, columns, sections and steps are 0-based positions in the
/// pattern; [`KnitLocation::text`] gives the 1-based words a knitter reads.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum KnitLocation {
    /// The pattern as a whole (its cast-on, its construction).
    Pattern,
    /// One chart row.
    Row { row: usize },
    /// One chart cell: its storage row and column; its column as the chart numbers it (stitch 1 at
    /// the right edge on every row, as the chart's axis, the editor and the PDF number it; `None` for
    /// a cell past the chart's width); and its column in working order, as the message counts it
    /// (from the right on a right-side row, from the left on a wrong-side row).
    Cell {
        row: usize,
        column: usize,
        chart_col: Option<usize>,
        reading_col: usize,
    },
    /// A repeat in a chart row: the span's index in the row's repeats, its storage columns
    /// `start..end`, its lowest and highest columns as the chart numbers them (the part inside the
    /// chart; `None` when none of it is), and its lowest and highest columns in working order.
    Repeat {
        row: usize,
        repeat: usize,
        start: usize,
        end: usize,
        chart_cols: Option<(usize, usize)>,
        first_col: usize,
        last_col: usize,
    },
    /// A step of a section (as the stitch ledger places it): the section, the step when it is about
    /// one, the chart row when the step works one, the section's piece, and the place in words
    /// (`Back, step 3, chart row 5`).
    Step {
        section: usize,
        step: Option<usize>,
        chart_row: Option<usize>,
        piece: Option<usize>,
        place: String,
    },
}

impl KnitLocation {
    /// The place in words, with columns as the chart numbers them: "Whole pattern", "Row 3",
    /// "Row 3, chart column 4", "Row 1, chart columns 2 to 5", "Back, step 3". Where the row is
    /// worked from the other side, the working order the message counts in is added: "Row 2, chart
    /// column 6 (stitch 1 as the row is worked)".
    pub fn text(&self) -> String {
        let span = |a: usize, b: usize| {
            if a == b {
                format!("{a}")
            } else {
                format!("{a} to {b}")
            }
        };
        match self {
            KnitLocation::Pattern => "Whole pattern".to_string(),
            KnitLocation::Row { row } => format!("Row {}", row + 1),
            KnitLocation::Cell {
                row,
                chart_col,
                reading_col,
                ..
            } => match chart_col {
                Some(c) if c == reading_col => format!("Row {}, chart column {c}", row + 1),
                Some(c) => format!(
                    "Row {}, chart column {c} (stitch {reading_col} as the row is worked)",
                    row + 1
                ),
                None => format!(
                    "Row {}, past the chart's width (stitch {reading_col} as the row is worked)",
                    row + 1
                ),
            },
            KnitLocation::Repeat {
                row,
                chart_cols,
                first_col,
                last_col,
                ..
            } => {
                let worked = span(*first_col, *last_col);
                let plural = |a: usize, b: usize| if a == b { "" } else { "s" };
                match chart_cols {
                    Some((a, b)) if (*a, *b) == (*first_col, *last_col) => {
                        format!("Row {}, chart column{} {worked}", row + 1, plural(*a, *b))
                    }
                    Some((a, b)) => format!(
                        "Row {}, chart column{} {} ({} {worked} as the row is worked)",
                        row + 1,
                        plural(*a, *b),
                        span(*a, *b),
                        if first_col == last_col {
                            "stitch"
                        } else {
                            "stitches"
                        },
                    ),
                    None => format!("Row {}", row + 1),
                }
            }
            KnitLocation::Step { place, .. } => place.clone(),
        }
    }
}

/// One validation finding.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KnitIssue {
    /// A stable code: one of this module's constants, or [`RowProblem::code`] for a repeat or stitch
    /// count finding.
    pub code: &'static str,
    pub severity: Severity,
    pub location: KnitLocation,
    pub message: String,
}

impl KnitIssue {
    fn error(code: &'static str, location: KnitLocation, message: String) -> Self {
        KnitIssue {
            code,
            severity: Severity::Error,
            location,
            message,
        }
    }

    /// A chart row's repeat or stitch-count problem, located at its repeat (or its row).
    fn of_row(
        problem: &RowProblem,
        row: usize,
        width: usize,
        cols: &ReadingCols,
        message: String,
    ) -> Self {
        let location = match problem.span() {
            Some(span) => {
                let a = cols.col(span.start);
                let b = cols.col(span.end.saturating_sub(1).max(span.start));
                // The part of the span inside the chart, numbered as the chart numbers it.
                let last = span.end.saturating_sub(1).max(span.start);
                let chart_cols = (span.start < width)
                    .then(|| {
                        (
                            chart_col(width, last.min(width - 1)),
                            chart_col(width, span.start),
                        )
                    })
                    .and_then(|(lo, hi)| Some((lo?, hi?)));
                KnitLocation::Repeat {
                    row,
                    repeat: span.index,
                    start: span.start,
                    end: span.end,
                    chart_cols,
                    first_col: a.min(b),
                    last_col: a.max(b),
                }
            }
            None => KnitLocation::Row { row },
        };
        KnitIssue {
            code: problem.code(),
            severity: if problem.is_warning() {
                Severity::Warning
            } else {
                Severity::Error
            },
            location,
            message,
        }
    }
}

/// Validate a pattern's chart. An empty result is a structurally sound chart.
pub fn validate(pattern: &KnitPattern) -> Vec<KnitIssue> {
    let mut issues = Vec::new();
    let legend = &pattern.legend;
    let width = pattern.chart.width;
    let palette_len = pattern.palette.len();

    // A stated cast-on must put at least one stitch on the needle. (`None` is "not stated", fine.)
    if pattern.cast_on == Some(0) {
        issues.push(KnitIssue::error(
            CAST_ON_ZERO,
            KnitLocation::Pattern,
            "the cast-on is 0 stitches; cast on at least 1 stitch, or clear the cast-on".into(),
        ));
    }

    // Per-row structural checks (cells, colors, cables).
    for (r, row) in pattern.chart.rows.iter().enumerate() {
        let rownum = r + 1; // 1-based for human-facing messages
                            // Number stitches in READING/WORKING order so a reported "col" names the same stitch the
                            // written instructions and the knitter count to (a right-side row is worked right-to-left).
        let rs = matches!(pattern.row_side(r), Side::Rs);

        if row.cells.len() != width {
            issues.push(KnitIssue::error(
                ROW_WIDTH,
                KnitLocation::Row { row: r },
                format!(
                    "row {rownum} has {} cells but the chart width is {width}",
                    row.cells.len()
                ),
            ));
        }

        for (c, cell) in row.cells.iter().enumerate() {
            let col = reading_col(rs, width, c);
            let at = KnitLocation::Cell {
                row: r,
                column: c,
                chart_col: chart_col(width, c),
                reading_col: col,
            };
            if legend.get(cell.stitch).is_none() {
                issues.push(KnitIssue::error(
                    UNKNOWN_STITCH,
                    at.clone(),
                    format!(
                        "row {rownum} col {col} references stitch #{} which is not in the legend",
                        cell.stitch
                    ),
                ));
            }
            if let Some(ci) = cell.color {
                if ci >= palette_len {
                    issues.push(KnitIssue::error(
                        COLOR_OUT_OF_RANGE,
                        at,
                        format!(
                            "row {rownum} col {col} uses color #{ci} outside the {palette_len}-color palette"
                        ),
                    ));
                }
            }
        }

        check_cable_spans(legend, row, r, width, rs, &mut issues);
    }

    if pattern.sections.is_empty() {
        // Repeats and stitch counts: each row's worked sequence must take exactly what the row
        // below left, and every repeat must be workable as authored. An unknown stitch counts 0 (it
        // is already flagged above).
        for flow in stitch_flow(pattern) {
            let cols = ReadingCols::for_row(pattern, flow.row);
            for problem in &flow.problems {
                let message = problem.message(flow.row, &cols);
                issues.push(KnitIssue::of_row(problem, flow.row, width, &cols, message));
            }
        }
    } else {
        // With sections the chart is a set of rows the sections work, not one bottom-to-top
        // sequence: row r + 1 need not follow row r. Every row's repeats must still be workable as
        // drawn; its stitch counts are checked where a section works it, against the stitches the
        // ledger has waiting (see `crate::sections`).
        for r in 0..pattern.chart.rows.len() {
            if let RowInstruction::Unsupported(problems) = row_instruction(pattern, r) {
                let cols = ReadingCols::for_row(pattern, r);
                for problem in &problems {
                    let message = problem.message(r, &cols);
                    issues.push(KnitIssue::of_row(problem, r, width, &cols, message));
                }
            }
        }
        for issue in sections::ledger(pattern).issues {
            issues.push(ledger_issue(pattern, issue));
        }
    }

    issues
}

/// A stitch-ledger finding with the place the ledger gave it.
pub(crate) fn ledger_issue(pattern: &KnitPattern, issue: sections::SectionIssue) -> KnitIssue {
    let location = match issue.section {
        Some(section) => KnitLocation::Step {
            section,
            step: issue.step,
            chart_row: issue.chart_row,
            piece: sections::section_piece(pattern, section),
            // The ledger writes `<place>: <text>`; the place is what comes before the text.
            place: issue
                .message
                .strip_suffix(issue.text.as_str())
                .and_then(|p| p.strip_suffix(": "))
                .map(str::to_string)
                .unwrap_or_else(|| sections::section_title(pattern, section)),
        },
        None => KnitLocation::Pattern,
    };
    KnitIssue {
        code: if issue.section.is_some() {
            SECTION_STEP
        } else {
            SECTIONS
        },
        severity: issue.severity,
        location,
        message: issue.message,
    }
}

/// The 1-based column number to SHOW for storage index `idx`, in READING ORDER: a right-side (RS) row
/// is worked, read, and written right-to-left, so its rightmost stitch is column 1; a wrong-side (WS)
/// row is worked left-to-right (column = idx + 1). This mirrors `written.rs` so a validation "col N"
/// names the same stitch the written instructions and the knitter count to. The `width > idx` guard
/// keeps a ragged over-wide row (already error-flagged) from underflowing. One rule with the repeat
/// diagnostics ([`ReadingCols`]).
fn reading_col(rs: bool, width: usize, idx: usize) -> usize {
    ReadingCols::new(rs, width).col(idx)
}

/// The column number the CHART shows for storage index `idx`: stitch 1 at the right edge on every
/// row, flat or in the round (the chart's axis, the editor and the PDF all number it so). `None` for
/// a cell of a ragged row past the chart's width, which the chart does not show.
pub fn chart_col(width: usize, idx: usize) -> Option<usize> {
    (idx < width).then(|| width - idx)
}

/// A cable cell must fit the width and be followed by `span - 1` no-stitch cells (the columns it
/// covers), and its declared consumes/produces must equal its span (count-neutral).
fn check_cable_spans(
    legend: &StitchLegend,
    row: &Row,
    r: usize,
    width: usize,
    rs: bool,
    issues: &mut Vec<KnitIssue>,
) {
    let rownum = r + 1;
    for (c, cell) in row.cells.iter().enumerate() {
        let Some(def) = legend.get(cell.stitch) else {
            continue;
        };
        let Some(cable) = def.cable else { continue };
        let col = reading_col(rs, width, c);
        let at = KnitLocation::Cell {
            row: r,
            column: c,
            chart_col: chart_col(width, c),
            reading_col: col,
        };
        let span = cable.span() as usize;
        if span == 0 {
            continue;
        }
        if def.consumes as usize != span || def.produces as usize != span {
            issues.push(KnitIssue::error(
                CABLE_COUNTS,
                at.clone(),
                format!(
                    "row {rownum} col {col}: cable stitch declares consumes {}/produces {} but its span is {span}",
                    def.consumes, def.produces
                ),
            ));
        }
        if c + span > width {
            issues.push(KnitIssue::error(
                CABLE_PAST_EDGE,
                at,
                format!(
                    "row {rownum} col {col} has a {span}-wide cable that runs past the chart edge"
                ),
            ));
            continue;
        }
        // Use `.get()` (not direct indexing): a RAGGED row whose cell count is below the chart width
        // can satisfy the `c + span > width` edge check above while a filler index runs past the
        // actual cells — a missing filler cell is a violation, not a panic.
        for k in 1..span {
            match row.cells.get(c + k) {
                Some(cell) if cell.stitch == builtin::NO_STITCH => {}
                _ => {
                    issues.push(KnitIssue::error(
                        CABLE_FILLER,
                        at.clone(),
                        format!(
                            "row {rownum} col {col}: a {span}-wide cable must be followed by no-stitch cells (col {} is not)",
                            reading_col(rs, width, c + k)
                        ),
                    ));
                    break;
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::pattern::*;
    use ply_common::{Color, Unit};

    /// Each finding's severity and words (the struct also carries its code and location).
    fn pairs(issues: &[KnitIssue]) -> Vec<(Severity, String)> {
        issues
            .iter()
            .map(|i| (i.severity, i.message.clone()))
            .collect()
    }

    fn pattern(
        width: usize,
        rows: Vec<Row>,
        palette: Vec<Color>,
        legend: StitchLegend,
    ) -> KnitPattern {
        KnitPattern {
            name: "t".into(),
            construction: Construction::Flat,
            first_row_side: Side::Rs,
            cast_on: None,
            gauge: Gauge {
                sts: 20.0,
                rows: 28.0,
                unit: Unit::Inches,
            },
            palette,
            legend,
            chart: Chart { width, rows },
            notes: String::new(),
            sections: Vec::new(),
            pieces: Vec::new(),
        }
    }

    fn k() -> Cell {
        Cell::of(builtin::KNIT)
    }
    fn ns() -> Cell {
        Cell::of(builtin::NO_STITCH)
    }

    #[test]
    fn balanced_lace_is_clean() {
        // row 0: k k k k (4 sts).  row 1: k yo k2tog k (consumes 4, produces 4) — a balanced eyelet.
        let row0 = Row::plain(vec![k(), k(), k(), k()]);
        let row1 = Row::plain(vec![
            k(),
            Cell::of(builtin::YO),
            Cell::of(builtin::K2TOG),
            k(),
        ]);
        let p = pattern(
            4,
            vec![row0, row1],
            vec![Color::WHITE],
            StitchLegend::builtin(),
        );
        assert!(validate(&p).is_empty(), "{:?}", validate(&p));
    }

    #[test]
    fn stitch_count_mismatch_is_caught() {
        // row 1 has a yo but NO matching decrease: consumes 3, produces 4, below produced 4.
        let row0 = Row::plain(vec![k(), k(), k(), k()]);
        let row1 = Row::plain(vec![k(), Cell::of(builtin::YO), k(), k()]);
        let p = pattern(
            4,
            vec![row0, row1],
            vec![Color::WHITE],
            StitchLegend::builtin(),
        );
        let issues = validate(&p);
        assert!(
            issues
                .iter()
                .any(|i| i.message.contains("consumes 3") && i.message.contains("produced 4")),
            "{issues:?}"
        );
    }

    #[test]
    fn ragged_row_dangling_stitch_and_bad_color_are_caught() {
        let row = Row {
            cells: vec![
                k(),
                Cell {
                    stitch: 999,
                    color: Some(7),
                },
            ], // width says 3 -> ragged; stitch 999, color 7
            repeats: vec![],
        };
        let p = pattern(3, vec![row], vec![Color::WHITE], StitchLegend::builtin());
        let issues = validate(&p);
        assert!(issues
            .iter()
            .any(|i| i.message.contains("2 cells but the chart width is 3")));
        assert!(issues.iter().any(|i| i.message.contains("stitch #999")));
        assert!(issues.iter().any(|i| i.message.contains("color #7")));
    }

    #[test]
    fn out_of_range_repeat_is_caught() {
        let row = Row {
            cells: vec![k(), k(), k(), k()],
            repeats: vec![RepeatSpan {
                start: 2,
                end: 9,
                count: Repeat::ToEnd,
            }],
        };
        let p = pattern(4, vec![row], vec![Color::WHITE], StitchLegend::builtin());
        assert!(validate(&p).iter().any(|i| i.message
            == "row 1: a repeat runs past the edge of the row (stored as 2..9 on a 4-column row)"));
    }

    #[test]
    fn cable_must_fit_and_be_trailed_by_no_stitch() {
        // A 2/2 cable (span 4, count-neutral 4->4) plus 3 trailing no-stitch = a valid 4-wide cable.
        let cable = CableDef {
            front: 2,
            back: 2,
            direction: Cross::Right,
            front_purl: false,
            back_purl: false,
        };
        let mut legend = StitchLegend::builtin();
        legend.stitches.push(StitchDef {
            symbol: "2/2RC".into(),
            consumes: 4,
            produces: 4,
            ws_variant: None,
            cable: Some(cable),
            macro_rows: 1,
        });
        let cable_id = legend.stitches.len() - 1;

        // GOOD: cable at col 0 + 3 no-stitch.
        let good = pattern(
            4,
            vec![Row::plain(vec![Cell::of(cable_id), ns(), ns(), ns()])],
            vec![Color::WHITE],
            legend.clone(),
        );
        assert!(validate(&good).is_empty(), "{:?}", validate(&good));

        // BAD: a knit where a no-stitch filler must be.
        let bad = pattern(
            4,
            vec![Row::plain(vec![Cell::of(cable_id), k(), ns(), ns()])],
            vec![Color::WHITE],
            legend.clone(),
        );
        assert!(validate(&bad)
            .iter()
            .any(|i| i.message.contains("must be followed by no-stitch")));

        // BAD: cable runs past the edge (span 4 at width 2).
        let off = pattern(
            2,
            vec![Row::plain(vec![Cell::of(cable_id), ns()])],
            vec![Color::WHITE],
            legend,
        );
        assert!(validate(&off)
            .iter()
            .any(|i| i.message.contains("runs past the chart edge")));
    }

    #[test]
    fn cable_on_a_ragged_row_reports_an_issue_without_panicking() {
        // Regression: a RAGGED row (fewer cells than chart.width) carrying a cable used to PANIC —
        // the `c + span > width` edge check used chart.width, but the trailing-filler scan indexed
        // the (shorter) row cells, so `c + k` ran past the slice. It must report, never panic.
        let cable = CableDef {
            front: 2,
            back: 2,
            direction: Cross::Right,
            front_purl: false,
            back_purl: false,
        };
        let mut legend = StitchLegend::builtin();
        legend.stitches.push(StitchDef {
            symbol: "2/2RC".into(),
            consumes: 4,
            produces: 4,
            ws_variant: None,
            cable: Some(cable),
            macro_rows: 1,
        });
        let cable_id = legend.stitches.len() - 1;
        // width 6, but a lone span-4 cable cell (no fillers): c+span=4 <= 6 passes the edge check.
        let p = pattern(
            6,
            vec![Row::plain(vec![Cell::of(cable_id)])],
            vec![Color::WHITE],
            legend,
        );
        let issues = validate(&p); // must NOT panic
        assert!(
            issues
                .iter()
                .any(|i| i.message.contains("must be followed by no-stitch")),
            "{issues:?}"
        );
    }

    #[test]
    fn rs_row_numbers_stitches_right_to_left() {
        // On a right-side row the RIGHTMOST stitch is worked (and read, and written) first = column 1,
        // and the leftmost last; a validation "col" must match that reading order rather than the
        // left-origin storage index (the bug the alpha user hit: errors numbered the opposite way).
        let leftmost_bad = pattern(
            4,
            vec![Row::plain(vec![
                Cell {
                    stitch: 999,
                    color: None,
                },
                k(),
                k(),
                k(),
            ])],
            vec![Color::WHITE],
            StitchLegend::builtin(),
        );
        assert!(
            validate(&leftmost_bad)
                .iter()
                .any(|i| i.message.contains("col 4") && i.message.contains("#999")),
            "leftmost stitch on an RS row is worked LAST -> col 4: {:?}",
            validate(&leftmost_bad)
        );

        let rightmost_bad = pattern(
            4,
            vec![Row::plain(vec![
                k(),
                k(),
                k(),
                Cell {
                    stitch: 999,
                    color: None,
                },
            ])],
            vec![Color::WHITE],
            StitchLegend::builtin(),
        );
        assert!(
            validate(&rightmost_bad)
                .iter()
                .any(|i| i.message.contains("col 1") && i.message.contains("#999")),
            "rightmost stitch on an RS row is worked FIRST -> col 1: {:?}",
            validate(&rightmost_bad)
        );
    }

    #[test]
    fn empty_chart_is_clean() {
        let p = pattern(0, vec![], vec![Color::WHITE], StitchLegend::builtin());
        assert!(validate(&p).is_empty());
    }

    // --- repeats (ADR 0004) -------------------------------------------------------------------------

    fn spanned(ids: &[usize], repeats: Vec<RepeatSpan>) -> Row {
        Row {
            cells: ids.iter().map(|&i| Cell::of(i)).collect(),
            repeats,
        }
    }

    fn rep(start: usize, end: usize, count: Repeat) -> RepeatSpan {
        RepeatSpan { start, end, count }
    }

    const RIB: [usize; 6] = [
        builtin::KNIT,
        builtin::PURL,
        builtin::PURL,
        builtin::KNIT,
        builtin::KNIT,
        builtin::KNIT,
    ];

    #[test]
    fn the_audit_example_no_longer_validates_clean() {
        // R-02: 14 worked stitches, then a plain 6-stitch row. It used to validate clean.
        let p = pattern(
            6,
            vec![
                spanned(&RIB, vec![rep(1, 5, Repeat::Times(3))]),
                Row::plain(vec![k(); 6]),
            ],
            vec![Color::WHITE],
            StitchLegend::builtin(),
        );
        assert_eq!(
            pairs(&validate(&p)),
            vec![(
                Severity::Error,
                "row 2 consumes 6 stitches but row 1 produced 14".to_string(),
            )]
        );
    }

    #[test]
    fn a_counted_repeat_balances_the_next_row() {
        let p = pattern(
            6,
            vec![
                spanned(&RIB, vec![rep(1, 5, Repeat::Times(3))]),
                spanned(&RIB, vec![rep(1, 5, Repeat::ToEnd)]),
            ],
            vec![Color::WHITE],
            StitchLegend::builtin(),
        );
        assert!(validate(&p).is_empty(), "{:?}", validate(&p));
    }

    #[test]
    fn a_first_row_to_end_is_a_warning_with_its_multiple() {
        let p = pattern(
            6,
            vec![spanned(&RIB, vec![rep(1, 5, Repeat::ToEnd)])],
            vec![Color::WHITE],
            StitchLegend::builtin(),
        );
        assert_eq!(
            pairs(&validate(&p)),
            vec![(
                Severity::Warning,
                "row 1: the repeat over cols 2-5 is worked to the end of the row, but the \
                          pattern has no cast-on count, so Ply cannot count this row (it needs a \
                          multiple of 4 stitches plus 2); set the cast-on in the pattern settings"
                    .to_string(),
            )]
        );
    }

    // --- cast-on (ADR 0006) -------------------------------------------------------------------------

    #[test]
    fn a_first_row_to_end_resolves_against_the_cast_on() {
        // k + [k2, p2] to the end + k over 26 cast-on stitches: 6 repeats, then a row that keeps 26.
        let mut p = pattern(
            6,
            vec![
                spanned(&RIB, vec![rep(1, 5, Repeat::ToEnd)]),
                spanned(&RIB, vec![rep(1, 5, Repeat::ToEnd)]),
            ],
            vec![Color::WHITE],
            StitchLegend::builtin(),
        );
        p.cast_on = Some(26);
        assert!(validate(&p).is_empty(), "{:?}", validate(&p));
    }

    #[test]
    fn a_first_row_to_end_that_does_not_divide_the_cast_on_names_the_cast_on() {
        let mut p = pattern(
            6,
            vec![spanned(&RIB, vec![rep(1, 5, Repeat::ToEnd)])],
            vec![Color::WHITE],
            StitchLegend::builtin(),
        );
        p.cast_on = Some(27);
        assert_eq!(
            pairs(&validate(&p)),
            vec![(
                Severity::Error,
                "row 1: the repeat over cols 2-5 cannot be worked to the end: the cast-on \
                          is 27 stitches, the rest of the row uses 2, and the 25 left are not a \
                          multiple of 4"
                    .to_string(),
            )]
        );
        p.cast_on = Some(1);
        assert_eq!(
            validate(&p)[0].message,
            "row 1: the repeat over cols 2-5 cannot be worked to the end: the cast-on is 1 stitch \
             but the rest of the row uses 2"
        );
        p.cast_on = Some(2);
        assert_eq!(
            validate(&p)[0].message,
            "row 1: the repeat over cols 2-5 cannot be worked to the end: the rest of the row uses \
             all 2 stitches of the cast-on, leaving none for the repeat"
        );
    }

    #[test]
    fn row_1_must_consume_exactly_the_cast_on() {
        let mut p = pattern(
            4,
            vec![Row::plain(vec![k(); 4]), Row::plain(vec![k(); 4])],
            vec![Color::WHITE],
            StitchLegend::builtin(),
        );
        p.cast_on = Some(4);
        assert!(validate(&p).is_empty(), "{:?}", validate(&p));
        p.cast_on = Some(6);
        assert_eq!(
            pairs(&validate(&p)),
            vec![(
                Severity::Error,
                "row 1 consumes 4 stitches but the cast-on is 6".to_string(),
            )]
        );
        // Not stated: row 1's own count is the start, as before.
        p.cast_on = None;
        assert!(validate(&p).is_empty());
    }

    #[test]
    fn a_zero_cast_on_is_an_error() {
        let mut p = pattern(0, vec![], vec![Color::WHITE], StitchLegend::builtin());
        p.cast_on = Some(0);
        assert_eq!(
            pairs(&validate(&p)),
            vec![(
                Severity::Error,
                "the cast-on is 0 stitches; cast on at least 1 stitch, or clear the \
                          cast-on"
                    .to_string(),
            )]
        );
    }

    #[test]
    fn rejected_repeats_are_errors_naming_the_row_and_columns() {
        let cases: Vec<(Vec<RepeatSpan>, &str)> = vec![
            (
                vec![rep(1, 5, Repeat::Times(0))],
                "row 1: the repeat over cols 2-5 is worked 0 times",
            ),
            (
                vec![rep(0, 3, Repeat::Times(2)), rep(2, 5, Repeat::Times(2))],
                "row 1: the repeats over cols 2-4 and cols 4-6 overlap",
            ),
            (
                vec![rep(0, 6, Repeat::Times(2)), rep(2, 4, Repeat::Times(2))],
                "row 1: the repeat over cols 3-4 is inside the repeat over cols 1-6",
            ),
            (
                vec![rep(0, 2, Repeat::ToEnd), rep(3, 5, Repeat::ToEnd)],
                "row 1: the repeats over cols 2-3 and cols 5-6 are both worked to the end of the row",
            ),
            (
                vec![rep(4, 8, Repeat::Times(2))],
                "row 1: a repeat runs past the edge of the row (stored as 4..8 on a 6-column row)",
            ),
        ];
        for (repeats, want) in cases {
            let p = pattern(
                6,
                vec![spanned(&RIB, repeats)],
                vec![Color::WHITE],
                StitchLegend::builtin(),
            );
            let issues = validate(&p);
            assert!(
                issues
                    .iter()
                    .any(|i| i.severity == Severity::Error && i.message.starts_with(want)),
                "want `{want}` in {issues:?}"
            );
        }
    }

    #[test]
    fn a_repeat_splitting_a_cable_is_an_error() {
        let mut legend = StitchLegend::builtin();
        legend.stitches.push(StitchDef {
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
        let c = legend.stitches.len() - 1;
        let p = pattern(
            6,
            vec![Row {
                cells: vec![k(), Cell::of(c), ns(), ns(), ns(), k()],
                repeats: vec![rep(3, 6, Repeat::Times(2))],
            }],
            vec![Color::WHITE],
            legend,
        );
        assert!(
            validate(&p).iter().any(|i| i.severity == Severity::Error
                && i.message
                    == "row 1: the repeat over cols 1-3 splits the cable at cols 2-5; a cable \
                        must be wholly inside or outside a repeat"),
            "{:?}",
            validate(&p)
        );
    }

    #[test]
    fn a_non_dividing_to_end_is_an_error_with_the_numbers() {
        let p = pattern(
            6,
            vec![
                Row::plain(vec![k(), k(), k(), k(), k(), Cell::of(builtin::KFB)]),
                spanned(&RIB, vec![rep(1, 5, Repeat::ToEnd)]),
            ],
            vec![Color::WHITE],
            StitchLegend::builtin(),
        );
        assert_eq!(
            pairs(&validate(&p)),
            vec![(
                Severity::Error,
                "row 2: the repeat over cols 2-5 cannot be worked to the end: row 1 \
                          produced 7 stitches, the rest of the row uses 2, and the 5 left are not a \
                          multiple of 4".to_string(),
            )]
        );
    }

    // --- codes and typed locations (ADR 0021) -------------------------------------------------------

    #[test]
    fn a_cell_finding_names_its_storage_cell_and_its_working_column() {
        // Leftmost cell of a right-side row: storage column 0, worked last (column 4).
        let p = pattern(
            4,
            vec![Row::plain(vec![
                Cell {
                    stitch: 999,
                    color: Some(3),
                },
                k(),
                k(),
                k(),
            ])],
            vec![Color::WHITE],
            StitchLegend::builtin(),
        );
        let issues = validate(&p);
        let at = KnitLocation::Cell {
            row: 0,
            column: 0,
            chart_col: Some(4),
            reading_col: 4,
        };
        assert!(issues
            .iter()
            .any(|i| i.code == UNKNOWN_STITCH && i.location == at));
        assert!(issues
            .iter()
            .any(|i| i.code == COLOR_OUT_OF_RANGE && i.location == at));
        assert_eq!(at.text(), "Row 1, chart column 4");
        assert_eq!(KnitLocation::Pattern.text(), "Whole pattern");
    }

    #[test]
    fn row_and_repeat_findings_carry_their_row_and_columns() {
        let ragged = pattern(
            3,
            vec![Row::plain(vec![k(), k()])],
            vec![Color::WHITE],
            StitchLegend::builtin(),
        );
        let i = &validate(&ragged)[0];
        assert_eq!(
            (i.code, &i.location),
            (ROW_WIDTH, &KnitLocation::Row { row: 0 })
        );
        assert_eq!(i.location.text(), "Row 1");

        let p = pattern(
            6,
            vec![spanned(&RIB, vec![rep(1, 5, Repeat::Times(0))])],
            vec![Color::WHITE],
            StitchLegend::builtin(),
        );
        let i = validate(&p)
            .into_iter()
            .find(|i| i.code == "repeat-zero-times")
            .unwrap();
        assert_eq!(
            i.location,
            KnitLocation::Repeat {
                row: 0,
                repeat: 0,
                start: 1,
                end: 5,
                chart_cols: Some((2, 5)),
                first_col: 2,
                last_col: 5
            }
        );
        assert_eq!(i.location.text(), "Row 1, chart columns 2 to 5");
        assert!(i
            .message
            .starts_with("row 1: the repeat over cols 2-5 is worked 0 times"));
    }

    #[test]
    fn a_ledger_finding_keeps_the_place_the_ledger_gave_it() {
        use crate::sections::{Section, Step, StepAction};
        let mut p = pattern(0, vec![], vec![Color::WHITE], StitchLegend::builtin());
        p.cast_on = Some(10);
        p.sections = vec![Section {
            id: "s1".into(),
            name: "Back".into(),
            notes: String::new(),
            construction: None,
            piece: None,
            steps: vec![Step {
                id: "b".into(),
                action: StepAction::BindOff {
                    count: Some(99),
                    resolve_turns: false,
                },
            }],
        }];
        let i = validate(&p)
            .into_iter()
            .find(|i| i.code == SECTION_STEP)
            .expect("the ledger refuses binding off 99 of 10");
        let KnitLocation::Step {
            section,
            step,
            chart_row,
            piece,
            ref place,
        } = i.location
        else {
            panic!("{:?}", i.location);
        };
        assert_eq!((section, step, chart_row, piece), (0, Some(0), None, None));
        assert_eq!(place, "Back, step 1");
        assert!(i.message.starts_with("Back, step 1: "), "{}", i.message);
    }

    /// Places name columns as the chart numbers them (stitch 1 at the right edge on every row): on a
    /// wrong-side row of a flat chart that is not the working order the message counts in, so the
    /// place says both; in the round every row is worked from the right, and the two agree.
    #[test]
    fn places_use_the_charts_own_column_numbers() {
        let unknown = Cell {
            stitch: 999,
            color: None,
        };
        let rows = |at: usize| {
            let mut rows = vec![Row::plain(vec![k(); 6]); 2];
            rows[1].cells[at] = unknown;
            rows
        };
        // Flat, row 2 is a wrong-side row: storage column 0 is chart column 6, worked first.
        let flat = pattern(6, rows(0), vec![Color::WHITE], StitchLegend::builtin());
        let i = &validate(&flat)[0];
        assert_eq!(
            i.message,
            "row 2 col 1 references stitch #999 which is not in the legend"
        );
        assert_eq!(
            i.location,
            KnitLocation::Cell {
                row: 1,
                column: 0,
                chart_col: Some(6),
                reading_col: 1
            }
        );
        assert_eq!(
            i.location.text(),
            "Row 2, chart column 6 (stitch 1 as the row is worked)"
        );
        // In the round the same cell is chart column 6 and the sixth stitch worked.
        let mut round = pattern(6, rows(0), vec![Color::WHITE], StitchLegend::builtin());
        round.construction = Construction::InTheRound;
        let i = &validate(&round)[0];
        assert_eq!(i.location.text(), "Row 2, chart column 6");
        // A repeat on the wrong-side row: chart columns 4 to 5, the second and third stitches worked.
        let mut ws = pattern(
            6,
            vec![Row::plain(vec![k(); 6]); 2],
            vec![Color::WHITE],
            StitchLegend::builtin(),
        );
        ws.chart.rows[1].repeats = vec![rep(1, 3, Repeat::Times(0))];
        let i = validate(&ws)
            .into_iter()
            .find(|i| i.code == "repeat-zero-times")
            .unwrap();
        assert_eq!(
            i.location.text(),
            "Row 2, chart columns 4 to 5 (stitches 2 to 3 as the row is worked)"
        );
        // A cell of a ragged row past the chart's width is not on the chart.
        assert_eq!(chart_col(6, 6), None);
        let ragged = KnitLocation::Cell {
            row: 0,
            column: 7,
            chart_col: None,
            reading_col: 8,
        };
        assert_eq!(
            ragged.text(),
            "Row 1, past the chart's width (stitch 8 as the row is worked)"
        );
    }
}
