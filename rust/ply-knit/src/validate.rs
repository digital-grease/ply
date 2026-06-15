//! Structural + stitch-count validation of a knitting chart — the knitting analog of `ply-weave`'s
//! `validate.rs`, and (like weaving's shed logic) the single place stitch arithmetic lives so the
//! renderer and editor never re-derive it.
//!
//! Owner decision #7 = FULL stitch-count balancing: each row must consume exactly the stitches the
//! row below produced (so a stray `yo` without its matching decrease is caught), cables must fit their
//! span and be trailed by no-stitch, every cell must reference a real legend stitch / palette color,
//! and the grid stays rectangular.
//!
//! Repeats are validated for bounds only: a chart stores the literal motif as drawn (the repeat is how
//! a knitter TILES it, not part of the motif's internal stitch count), so the continuity pass runs on
//! the literal cells.

use crate::pattern::{builtin, KnitPattern, Row, StitchLegend};

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
        KnitIssue { severity: Severity::Error, message }
    }
}

/// Validate a pattern's chart. An empty result is a structurally sound chart.
pub fn validate(pattern: &KnitPattern) -> Vec<KnitIssue> {
    let mut issues = Vec::new();
    let legend = &pattern.legend;
    let width = pattern.chart.width;
    let palette_len = pattern.palette.len();

    // Per-row structural checks, collecting each row's (consumes, produces) totals for the continuity
    // pass below.
    let mut totals: Vec<(u32, u32)> = Vec::with_capacity(pattern.chart.rows.len());
    for (r, row) in pattern.chart.rows.iter().enumerate() {
        let rownum = r + 1; // 1-based for human-facing messages

        if row.cells.len() != width {
            issues.push(KnitIssue::error(format!(
                "row {rownum} has {} cells but the chart width is {width}",
                row.cells.len()
            )));
        }

        for (c, cell) in row.cells.iter().enumerate() {
            let col = c + 1;
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

        for rep in &row.repeats {
            if rep.start >= rep.end || rep.end > width {
                issues.push(KnitIssue::error(format!(
                    "row {rownum} has an out-of-range repeat span {}..{} (width {width})",
                    rep.start, rep.end
                )));
            }
        }

        check_cable_spans(legend, row, rownum, width, &mut issues);
        totals.push(row_totals(legend, row));
    }

    // Stitch-count continuity: each row must consume exactly what the row below it produced.
    for r in 1..pattern.chart.rows.len() {
        let produced_below = totals[r - 1].1;
        let consumed_here = totals[r].0;
        if produced_below != consumed_here {
            issues.push(KnitIssue::error(format!(
                "row {} consumes {consumed_here} stitches but row {} produced {produced_below}",
                r + 1,
                r
            )));
        }
    }

    issues
}

/// Sum of (consumes, produces) over a row's cells. An unknown stitch contributes 0 (it is already
/// error-flagged); saturating so a pathological legend can't overflow.
fn row_totals(legend: &StitchLegend, row: &Row) -> (u32, u32) {
    let mut consumes = 0u32;
    let mut produces = 0u32;
    for cell in &row.cells {
        if let Some(def) = legend.get(cell.stitch) {
            consumes = consumes.saturating_add(def.consumes as u32);
            produces = produces.saturating_add(def.produces as u32);
        }
    }
    (consumes, produces)
}

/// A cable cell must fit the width and be followed by `span - 1` no-stitch cells (the columns it
/// covers), and its declared consumes/produces must equal its span (count-neutral).
fn check_cable_spans(
    legend: &StitchLegend,
    row: &Row,
    rownum: usize,
    width: usize,
    issues: &mut Vec<KnitIssue>,
) {
    for (c, cell) in row.cells.iter().enumerate() {
        let Some(def) = legend.get(cell.stitch) else { continue };
        let Some(cable) = def.cable else { continue };
        let col = c + 1;
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
                        c + k + 1
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

    fn pattern(width: usize, rows: Vec<Row>, palette: Vec<Color>, legend: StitchLegend) -> KnitPattern {
        KnitPattern {
            name: "t".into(),
            construction: Construction::Flat,
            first_row_side: Side::Rs,
            gauge: Gauge { sts: 20.0, rows: 28.0, unit: Unit::Inches },
            palette,
            legend,
            chart: Chart { width, rows },
            notes: String::new(),
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
        let row1 = Row::plain(vec![k(), Cell::of(builtin::YO), Cell::of(builtin::K2TOG), k()]);
        let p = pattern(4, vec![row0, row1], vec![Color::WHITE], StitchLegend::builtin());
        assert!(validate(&p).is_empty(), "{:?}", validate(&p));
    }

    #[test]
    fn stitch_count_mismatch_is_caught() {
        // row 1 has a yo but NO matching decrease: consumes 3, produces 4, below produced 4.
        let row0 = Row::plain(vec![k(), k(), k(), k()]);
        let row1 = Row::plain(vec![k(), Cell::of(builtin::YO), k(), k()]);
        let p = pattern(4, vec![row0, row1], vec![Color::WHITE], StitchLegend::builtin());
        let issues = validate(&p);
        assert!(
            issues.iter().any(|i| i.message.contains("consumes 3") && i.message.contains("produced 4")),
            "{issues:?}"
        );
    }

    #[test]
    fn ragged_row_dangling_stitch_and_bad_color_are_caught() {
        let row = Row {
            cells: vec![k(), Cell { stitch: 999, color: Some(7) }], // width says 3 -> ragged; stitch 999, color 7
            repeats: vec![],
        };
        let p = pattern(3, vec![row], vec![Color::WHITE], StitchLegend::builtin());
        let issues = validate(&p);
        assert!(issues.iter().any(|i| i.message.contains("2 cells but the chart width is 3")));
        assert!(issues.iter().any(|i| i.message.contains("stitch #999")));
        assert!(issues.iter().any(|i| i.message.contains("color #7")));
    }

    #[test]
    fn out_of_range_repeat_is_caught() {
        let row = Row { cells: vec![k(), k(), k(), k()], repeats: vec![RepeatSpan { start: 2, end: 9, count: Repeat::ToEnd }] };
        let p = pattern(4, vec![row], vec![Color::WHITE], StitchLegend::builtin());
        assert!(validate(&p).iter().any(|i| i.message.contains("out-of-range repeat")));
    }

    #[test]
    fn cable_must_fit_and_be_trailed_by_no_stitch() {
        // A 2/2 cable (span 4, count-neutral 4->4) plus 3 trailing no-stitch = a valid 4-wide cable.
        let cable = CableDef { front: 2, back: 2, direction: Cross::Right, front_purl: false, back_purl: false };
        let mut legend = StitchLegend::builtin();
        legend.stitches.push(StitchDef { symbol: "2/2RC".into(), consumes: 4, produces: 4, ws_variant: None, cable: Some(cable), macro_rows: 1 });
        let cable_id = legend.stitches.len() - 1;

        // GOOD: cable at col 0 + 3 no-stitch.
        let good = pattern(4, vec![Row::plain(vec![Cell::of(cable_id), ns(), ns(), ns()])], vec![Color::WHITE], legend.clone());
        assert!(validate(&good).is_empty(), "{:?}", validate(&good));

        // BAD: a knit where a no-stitch filler must be.
        let bad = pattern(4, vec![Row::plain(vec![Cell::of(cable_id), k(), ns(), ns()])], vec![Color::WHITE], legend.clone());
        assert!(validate(&bad).iter().any(|i| i.message.contains("must be followed by no-stitch")));

        // BAD: cable runs past the edge (span 4 at width 2).
        let off = pattern(2, vec![Row::plain(vec![Cell::of(cable_id), ns()])], vec![Color::WHITE], legend);
        assert!(validate(&off).iter().any(|i| i.message.contains("runs past the chart edge")));
    }

    #[test]
    fn cable_on_a_ragged_row_reports_an_issue_without_panicking() {
        // Regression: a RAGGED row (fewer cells than chart.width) carrying a cable used to PANIC —
        // the `c + span > width` edge check used chart.width, but the trailing-filler scan indexed
        // the (shorter) row cells, so `c + k` ran past the slice. It must report, never panic.
        let cable = CableDef { front: 2, back: 2, direction: Cross::Right, front_purl: false, back_purl: false };
        let mut legend = StitchLegend::builtin();
        legend.stitches.push(StitchDef { symbol: "2/2RC".into(), consumes: 4, produces: 4, ws_variant: None, cable: Some(cable), macro_rows: 1 });
        let cable_id = legend.stitches.len() - 1;
        // width 6, but a lone span-4 cable cell (no fillers): c+span=4 <= 6 passes the edge check.
        let p = pattern(6, vec![Row::plain(vec![Cell::of(cable_id)])], vec![Color::WHITE], legend);
        let issues = validate(&p); // must NOT panic
        assert!(
            issues.iter().any(|i| i.message.contains("must be followed by no-stitch")),
            "{issues:?}"
        );
    }

    #[test]
    fn empty_chart_is_clean() {
        let p = pattern(0, vec![], vec![Color::WHITE], StitchLegend::builtin());
        assert!(validate(&p).is_empty());
    }
}
