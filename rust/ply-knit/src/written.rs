//! Chart -> WRITTEN INSTRUCTIONS: the second rendering of the one canonical chart (the design's
//! chart-as-source). One line per row in working order (bottom-to-top, row 1 first), each line the
//! stitches in READING order with consecutive identical stitches run-length collapsed ("k3").
//!
//! Reading direction follows knitting convention: a flat RS row reads RIGHT-TO-LEFT, a flat WS row
//! LEFT-TO-RIGHT, and every in-the-round round right-to-left (always from the RS). A symbol is stored
//! RS-relative, so on a WS row it is emitted as its [`StitchDef::ws_variant`] (knit shows as "p").
//!
//! V1 SCOPE (per `docs/KNIT_DESIGN.md`): LITERAL per-row text — authored repeats are not folded into
//! `*..; rep from *` (that minimal-folding is lossy and deferred), and colorwork colors ride the
//! chart, not the written line (the line names stitches). A `NoStitch` cell emits nothing; a cable
//! emits its one symbol (the columns it covers are no-stitch and skipped).

use crate::pattern::{builtin, Construction, KnitPattern, Side, StitchDef};

/// One written line per chart row, bottom-to-top (row 1 = the first worked).
pub fn to_written(pattern: &KnitPattern) -> Vec<String> {
    let legend = &pattern.legend;
    let mut lines = Vec::with_capacity(pattern.chart.rows.len());

    for (r, row) in pattern.chart.rows.iter().enumerate() {
        let side = pattern.row_side(r);
        let rs = matches!(side, Side::Rs);

        // Reading order: RS right-to-left, WS left-to-right.
        let ordered: Vec<&StitchDef> = {
            let cells: Box<dyn Iterator<Item = usize>> = if rs {
                Box::new((0..row.cells.len()).rev())
            } else {
                Box::new(0..row.cells.len())
            };
            cells
                .filter_map(|c| {
                    let cell = row.cells[c];
                    if cell.stitch == builtin::NO_STITCH {
                        return None;
                    }
                    let def = legend.get(cell.stitch)?;
                    // WS resolution: a stitch worked on the wrong side is emitted as its ws_variant.
                    Some(if rs {
                        def
                    } else {
                        def.ws_variant.and_then(|id| legend.get(id)).unwrap_or(def)
                    })
                })
                .collect()
        };

        let body = collapse(ordered.iter().map(|d| d.symbol.as_str()));
        let label = match pattern.construction {
            Construction::InTheRound => format!("Round {}", r + 1),
            Construction::Flat => format!("Row {} ({})", r + 1, if rs { "RS" } else { "WS" }),
        };
        lines.push(if body.is_empty() {
            format!("{label}: (no stitches)")
        } else {
            format!("{label}: {body}")
        });
    }

    lines
}

/// Run-length collapse a sequence of stitch symbols: `k, k, k -> "k3"`, joined with `", "`.
fn collapse<'a>(symbols: impl Iterator<Item = &'a str>) -> String {
    let symbols: Vec<&str> = symbols.collect();
    let mut parts: Vec<String> = Vec::new();
    let mut i = 0;
    while i < symbols.len() {
        let s = symbols[i];
        let mut n = 1;
        while i + n < symbols.len() && symbols[i + n] == s {
            n += 1;
        }
        parts.push(if n > 1 { format!("{s}{n}") } else { s.to_string() });
        i += n;
    }
    parts.join(", ")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::pattern::*;
    use ply_common::{Color, Unit};

    fn pat(rows: Vec<Row>, construction: Construction, first: Side) -> KnitPattern {
        let width = rows.first().map(|r| r.cells.len()).unwrap_or(0);
        KnitPattern {
            name: "t".into(),
            construction,
            first_row_side: first,
            gauge: Gauge { sts: 20.0, rows: 28.0, unit: Unit::Inches },
            palette: vec![Color::WHITE],
            legend: StitchLegend::builtin(),
            chart: Chart { width, rows },
            notes: String::new(),
        }
    }

    fn cells(ids: &[usize]) -> Row {
        Row::plain(ids.iter().map(|&i| Cell::of(i)).collect())
    }

    #[test]
    fn rs_reads_right_to_left_with_run_length() {
        // row 0 (RS) stored [k, p, p]; read right-to-left -> p, p, k -> "p2, k".
        let p = pat(vec![cells(&[builtin::KNIT, builtin::PURL, builtin::PURL])], Construction::Flat, Side::Rs);
        assert_eq!(to_written(&p), vec!["Row 1 (RS): p2, k"]);
    }

    #[test]
    fn ws_reads_left_to_right_and_resolves_knit_to_purl() {
        // row 0 (WS) stored [k, p, p]; read left-to-right, WS-resolved (k->p, p->k) -> p, k, k -> "p, k2".
        let p = pat(vec![cells(&[builtin::KNIT, builtin::PURL, builtin::PURL])], Construction::Flat, Side::Ws);
        assert_eq!(to_written(&p), vec!["Row 1 (WS): p, k2"]);
    }

    #[test]
    fn flat_alternates_rs_ws_across_rows() {
        let p = pat(
            vec![cells(&[builtin::KNIT, builtin::KNIT]), cells(&[builtin::KNIT, builtin::KNIT])],
            Construction::Flat,
            Side::Rs,
        );
        let lines = to_written(&p);
        assert!(lines[0].starts_with("Row 1 (RS):"));
        assert!(lines[1].starts_with("Row 2 (WS):"));
    }

    #[test]
    fn in_the_round_is_all_rounds_no_ws() {
        let p = pat(vec![cells(&[builtin::KNIT, builtin::PURL])], Construction::InTheRound, Side::Rs);
        // a round reads right-to-left; [k, p] -> p, k.
        assert_eq!(to_written(&p), vec!["Round 1: p, k"]);
    }

    #[test]
    fn no_stitch_emits_nothing_and_an_empty_run_is_labeled() {
        let p = pat(vec![cells(&[builtin::NO_STITCH, builtin::NO_STITCH])], Construction::Flat, Side::Rs);
        assert_eq!(to_written(&p), vec!["Row 1 (RS): (no stitches)"]);
    }

    #[test]
    fn a_yo_keeps_its_symbol() {
        // [k, yo, k2tog] RS read right-to-left -> k2tog, yo, k.
        let p = pat(
            vec![cells(&[builtin::KNIT, builtin::YO, builtin::K2TOG])],
            Construction::Flat,
            Side::Rs,
        );
        assert_eq!(to_written(&p), vec!["Row 1 (RS): k2tog, yo, k"]);
    }
}
