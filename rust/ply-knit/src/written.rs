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

use crate::pattern::{builtin, Construction, KnitPattern, Side};
use std::collections::{BTreeSet, HashMap};

/// One written line per chart row, bottom-to-top (row 1 = the first worked).
pub fn to_written(pattern: &KnitPattern) -> Vec<String> {
    let legend = &pattern.legend;
    // Colorwork labels (MC / CC / CC1.. ) — `None` when the chart is a single colour, which keeps a
    // plain stitch line uncluttered (and matches the no-colorwork V1 behaviour).
    let labels = color_labels(pattern);
    let mut lines = Vec::with_capacity(pattern.chart.rows.len());

    for (r, row) in pattern.chart.rows.iter().enumerate() {
        let side = pattern.row_side(r);
        let rs = matches!(side, Side::Rs);

        // Reading order: RS right-to-left, WS left-to-right. Each kept cell becomes a
        // (stitch symbol, resolved colour index) pair; no-stitch cells emit nothing.
        let order: Box<dyn Iterator<Item = usize>> = if rs {
            Box::new((0..row.cells.len()).rev())
        } else {
            Box::new(0..row.cells.len())
        };
        let cells: Vec<(&str, usize)> = order
            .filter_map(|c| {
                let cell = row.cells[c];
                if cell.stitch == builtin::NO_STITCH {
                    return None;
                }
                let def = legend.get(cell.stitch)?;
                // WS resolution: a stitch worked on the wrong side is emitted as its ws_variant.
                let def = if rs {
                    def
                } else {
                    def.ws_variant.and_then(|id| legend.get(id)).unwrap_or(def)
                };
                // A cell with no explicit colour rides the main colour (index 0).
                Some((def.symbol.as_str(), cell.color.unwrap_or(0)))
            })
            .collect();

        let body = collapse(&cells, labels.as_ref());
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

/// Map each palette index used in the chart to its colorwork label: index 0 is the Main Colour
/// ("MC"); other used indices are Contrast Colours — a lone contrast is just "CC", several are
/// numbered "CC1", "CC2", ... in palette order. Returns `None` when the chart uses a single colour
/// (nothing to label).
fn color_labels(pattern: &KnitPattern) -> Option<HashMap<usize, String>> {
    let mut used: BTreeSet<usize> = BTreeSet::new();
    for row in &pattern.chart.rows {
        for cell in &row.cells {
            if cell.stitch != builtin::NO_STITCH {
                used.insert(cell.color.unwrap_or(0));
            }
        }
    }
    if used.len() < 2 {
        return None;
    }
    let multi_contrast = used.iter().filter(|&&i| i != 0).count() > 1;
    let mut map = HashMap::new();
    let mut n = 0;
    for &idx in &used {
        if idx == 0 {
            map.insert(0, "MC".to_string());
        } else {
            n += 1;
            map.insert(idx, if multi_contrast { format!("CC{n}") } else { "CC".to_string() });
        }
    }
    Some(map)
}

/// Run-length collapse a row's (symbol, colour) cells: `k, k, k -> "k3"`, joined with `", "`. When
/// `labels` is `Some` (the chart is colorwork), a run is prefixed with its colour label whenever the
/// colour changes from the previous run (e.g. `MC k2, CC1 p3`); a run only collapses across cells of
/// the same stitch AND colour. When `labels` is `None`, colour is ignored entirely.
fn collapse(cells: &[(&str, usize)], labels: Option<&HashMap<usize, String>>) -> String {
    let mut parts: Vec<String> = Vec::new();
    let mut prev_color: Option<usize> = None;
    let mut i = 0;
    while i < cells.len() {
        let (sym, color) = cells[i];
        let mut n = 1;
        while i + n < cells.len()
            && cells[i + n].0 == sym
            && (labels.is_none() || cells[i + n].1 == color)
        {
            n += 1;
        }
        let stitch = if n > 1 { format!("{sym}{n}") } else { sym.to_string() };
        match labels {
            Some(map) if prev_color != Some(color) => {
                let lbl = map.get(&color).map(String::as_str).unwrap_or("MC");
                parts.push(format!("{lbl} {stitch}"));
                prev_color = Some(color);
            }
            _ => parts.push(stitch),
        }
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

    fn colored_row(spec: &[(usize, usize)]) -> Row {
        Row::plain(spec.iter().map(|&(s, c)| Cell::colored(s, c)).collect())
    }

    #[test]
    fn single_colour_chart_has_no_colour_labels() {
        // Every cell is colour 0 -> not colorwork -> plain stitch line (no "MC").
        let p = pat(vec![colored_row(&[(builtin::KNIT, 0), (builtin::KNIT, 0)])], Construction::Flat, Side::Rs);
        assert_eq!(to_written(&p), vec!["Row 1 (RS): k2"]);
    }

    #[test]
    fn two_colour_chart_labels_mc_and_a_lone_cc() {
        // Stored L->R: k(MC), k(MC), k(CC). RS reads R->L: CC k, then MC k2. One contrast -> "CC".
        let p = pat(
            vec![colored_row(&[(builtin::KNIT, 0), (builtin::KNIT, 0), (builtin::KNIT, 1)])],
            Construction::Flat,
            Side::Rs,
        );
        assert_eq!(to_written(&p), vec!["Row 1 (RS): CC k, MC k2"]);
    }

    #[test]
    fn three_colours_number_the_contrasts() {
        // Stored L->R: k(MC), k(CC1), k(CC2). RS reads R->L: CC2, CC1, MC. Two contrasts -> numbered.
        let p = pat(
            vec![colored_row(&[(builtin::KNIT, 0), (builtin::KNIT, 1), (builtin::KNIT, 2)])],
            Construction::Flat,
            Side::Rs,
        );
        assert_eq!(to_written(&p), vec!["Row 1 (RS): CC2 k, CC1 k, MC k"]);
    }

    #[test]
    fn colour_label_only_repeats_when_it_changes() {
        // Stored L->R all colour 1, mixed stitches. RS reads R->L: p, k, k. Lone contrast -> "CC",
        // labelled once at the start (colour never changes).
        let p = pat(
            vec![colored_row(&[(builtin::KNIT, 0), (builtin::KNIT, 1), (builtin::PURL, 1)])],
            Construction::Flat,
            Side::Rs,
        );
        // R->L: (p,1),(k,1),(k,0) -> "CC p, CC k"? no: first CC p, then CC k (same colour, no relabel),
        // then MC k. -> "CC p, k, MC k".
        assert_eq!(to_written(&p), vec!["Row 1 (RS): CC p, k, MC k"]);
    }
}
