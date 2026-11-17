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

use crate::flow::stitch_flow;
use crate::instruction::{row_instruction, ReadingCols, RowInstruction};
use crate::pattern::{builtin, KnitPattern, Row, Side, StitchLegend};
use crate::sections;

/// Issue severity. Errors are hard problems (a save gate should refuse); warnings are advisory.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Severity {
    Error,
    Warning,
}

/// One validation finding.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KnitIssue {
    pub severity: Severity,
    pub message: String,
}

impl KnitIssue {
    fn error(message: String) -> Self {
        KnitIssue {
            severity: Severity::Error,
            message,
        }
    }

    fn warning(message: String) -> Self {
        KnitIssue {
            severity: Severity::Warning,
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
            issues.push(KnitIssue::error(format!(
                "row {rownum} has {} cells but the chart width is {width}",
                row.cells.len()
            )));
        }

        for (c, cell) in row.cells.iter().enumerate() {
            let col = reading_col(rs, width, c);
            if legend.get(cell.stitch).is_none() {
                issues.push(KnitIssue::error(format!(
                    "row {rownum} col {col} references stitch #{} which is not in the legend",
                    cell.stitch
                )));
            }
            if let Some(ci) = cell.color {
                if ci >= palette_len {
                    issues.push(KnitIssue::error(format!(
                        "row {rownum} col {col} uses color #{ci} outside the {palette_len}-color palette"
                    )));
                }
            }
        }

        check_cable_spans(legend, row, rownum, width, rs, &mut issues);
    }

    if pattern.sections.is_empty() {
        // Repeats and stitch counts: each row's worked sequence must take exactly what the row
        // below left, and every repeat must be workable as authored. An unknown stitch counts 0 (it
        // is already flagged above).
        for flow in stitch_flow(pattern) {
            let cols = ReadingCols::for_row(pattern, flow.row);
            for problem in &flow.problems {
                let message = problem.message(flow.row, &cols);
                issues.push(if problem.is_warning() {
                    KnitIssue::warning(message)
                } else {
                    KnitIssue::error(message)
                });
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
                    issues.push(if problem.is_warning() {
                        KnitIssue::warning(message)
                    } else {
                        KnitIssue::error(message)
                    });
                }
            }
        }
        for issue in sections::ledger(pattern).issues {
            issues.push(KnitIssue {
                severity: issue.severity,
                message: issue.message,
            });
        }
    }

    issues
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

/// A cable cell must fit the width and be followed by `span - 1` no-stitch cells (the columns it
/// covers), and its declared consumes/produces must equal its span (count-neutral).
fn check_cable_spans(
    legend: &StitchLegend,
    row: &Row,
    rownum: usize,
    width: usize,
    rs: bool,
    issues: &mut Vec<KnitIssue>,
) {
    for (c, cell) in row.cells.iter().enumerate() {
        let Some(def) = legend.get(cell.stitch) else {
            continue;
        };
        let Some(cable) = def.cable else { continue };
        let col = reading_col(rs, width, c);
        let span = cable.span() as usize;
        if span == 0 {
            continue;
        }
        if def.consumes as usize != span || def.produces as usize != span {
            issues.push(KnitIssue::error(format!(
                "row {rownum} col {col}: cable stitch declares consumes {}/produces {} but its span is {span}",
                def.consumes, def.produces
            )));
        }
        if c + span > width {
            issues.push(KnitIssue::error(format!(
                "row {rownum} col {col} has a {span}-wide cable that runs past the chart edge"
            )));
            continue;
        }
        // Use `.get()` (not direct indexing): a RAGGED row whose cell count is below the chart width
        // can satisfy the `c + span > width` edge check above while a filler index runs past the
        // actual cells — a missing filler cell is a violation, not a panic.
        for k in 1..span {
            match row.cells.get(c + k) {
                Some(cell) if cell.stitch == builtin::NO_STITCH => {}
                _ => {
                    issues.push(KnitIssue::error(format!(
                        "row {rownum} col {col}: a {span}-wide cable must be followed by no-stitch cells (col {} is not)",
                        reading_col(rs, width, c + k)
                    )));
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
            validate(&p),
            vec![KnitIssue {
                severity: Severity::Error,
                message: "row 2 consumes 6 stitches but row 1 produced 14".into(),
            }]
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
            validate(&p),
            vec![KnitIssue {
                severity: Severity::Warning,
                message:
                    "row 1: the repeat over cols 2-5 is worked to the end of the row, but the \
                          pattern has no cast-on count, so Ply cannot count this row (it needs a \
                          multiple of 4 stitches plus 2); set the cast-on in the pattern settings"
                        .into(),
            }]
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
            validate(&p),
            vec![KnitIssue {
                severity: Severity::Error,
                message:
                    "row 1: the repeat over cols 2-5 cannot be worked to the end: the cast-on \
                          is 27 stitches, the rest of the row uses 2, and the 25 left are not a \
                          multiple of 4"
                        .into(),
            }]
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
            validate(&p),
            vec![KnitIssue {
                severity: Severity::Error,
                message: "row 1 consumes 4 stitches but the cast-on is 6".into(),
            }]
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
            validate(&p),
            vec![KnitIssue {
                severity: Severity::Error,
                message: "the cast-on is 0 stitches; cast on at least 1 stitch, or clear the \
                          cast-on"
                    .into(),
            }]
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
            validate(&p),
            vec![KnitIssue {
                severity: Severity::Error,
                message: "row 2: the repeat over cols 2-5 cannot be worked to the end: row 1 \
                          produced 7 stitches, the rest of the row uses 2, and the 5 left are not a \
                          multiple of 4"
                    .into(),
            }]
        );
    }
}
