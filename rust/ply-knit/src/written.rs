//! Chart -> WRITTEN INSTRUCTIONS: the second rendering of the one canonical chart (the design's
//! chart-as-source). One line per row in working order (bottom-to-top, row 1 first), each line the
//! stitches in WORKING order with consecutive identical stitches run-length collapsed ("k3").
//!
//! Reading direction follows knitting convention: a flat RS row reads RIGHT-TO-LEFT, a flat WS row
//! LEFT-TO-RIGHT, and every in-the-round round right-to-left (always from the RS). A symbol is stored
//! RS-relative, so on a WS row it is emitted as its [`StitchDef::ws_variant`](crate::StitchDef) (knit
//! shows as "p"). The line is built from the row's [`RowInstruction`], the same IR stitch counting and
//! validation use.
//!
//! Authored repeats are written in the conventional forms:
//! - a fixed repeat: `[k2, p2] 3 times` (`[k2, p2] once` for one);
//! - a to-end repeat: `*k2, p2; rep from * to end`, or `*k2, p2; rep from * to last st, k` /
//!   `... to last 3 sts, ...`, the number being what the stitches after the repeat consume;
//! - both in one row: `k, [k2tog, yo] 2 times, *k2, p2; rep from * to last st, k`.
//!
//! Runs never merge across a repeat boundary. Colorwork colors ride the line as labels (MC / CC); a
//! motif's first run always carries its label, since each repeat is entered from the motif's own last
//! color. A row whose repeats cannot be worked as authored is written as `(repeats need fixing: ...)`
//! rather than as its drawn cells. Chart -> minimal-FOLDED text (detecting repeats the author did not
//! mark) stays out of scope: it is lossy. A `NoStitch` cell emits nothing; a cable emits its one
//! symbol (the columns it covers are no-stitch and skipped).

use crate::instruction::{row_instruction, ReadingCols, RowInstruction, RowItem, StitchOp};
use crate::pattern::{builtin, Construction, KnitPattern, Side};
use std::collections::{BTreeSet, HashMap};

/// One written line per chart row, bottom-to-top (row 1 = the first worked).
pub fn to_written(pattern: &KnitPattern) -> Vec<String> {
    // Colorwork labels (MC / CC / CC1.. ) — `None` when the chart is a single colour, which keeps a
    // plain stitch line uncluttered (and matches the no-colorwork V1 behaviour).
    let labels = color_labels(pattern);
    let mut lines = Vec::with_capacity(pattern.chart.rows.len());

    for r in 0..pattern.chart.rows.len() {
        let rs = matches!(pattern.row_side(r), Side::Rs);
        let label = match pattern.construction {
            Construction::InTheRound => format!("Round {}", r + 1),
            Construction::Flat => format!("Row {} ({})", r + 1, if rs { "RS" } else { "WS" }),
        };
        let body = match row_instruction(pattern, r) {
            RowInstruction::Sequence(items) => {
                let mut writer = LineWriter {
                    pattern,
                    labels: labels.as_ref(),
                    prev_color: None,
                    parts: Vec::new(),
                };
                writer.items(&items);
                if writer.parts.is_empty() {
                    "(no stitches)".to_string()
                } else {
                    writer.parts.join(", ")
                }
            }
            RowInstruction::Unsupported(problems) => {
                let cols = ReadingCols::for_row(pattern, r);
                let reasons: Vec<String> = problems.iter().map(|p| p.reason(r, &cols)).collect();
                format!("(repeats need fixing: {})", reasons.join("; "))
            }
        };
        lines.push(format!("{label}: {body}"));
    }

    lines
}

/// Builds one row's text from its items: comma-separated parts, with the colorwork label state
/// carried along in working order.
struct LineWriter<'a> {
    pattern: &'a KnitPattern,
    labels: Option<&'a HashMap<usize, String>>,
    /// The colour of the last stitch written (for colorwork labels).
    prev_color: Option<usize>,
    parts: Vec<String>,
}

impl LineWriter<'_> {
    fn items(&mut self, items: &[RowItem]) {
        let mut i = 0;
        while i < items.len() {
            match &items[i] {
                RowItem::Stitch(_) => {
                    // Collapse the whole plain run up to the next repeat.
                    let mut run = Vec::new();
                    while let Some(RowItem::Stitch(op)) = items.get(i) {
                        run.push(*op);
                        i += 1;
                    }
                    let parts = self.collapse(&run);
                    self.parts.extend(parts);
                    continue;
                }
                RowItem::RepeatFixed { times, motif, .. } => {
                    let body = self.motif(motif);
                    let n = match times {
                        1 => "once".to_string(),
                        n => format!("{n} times"),
                    };
                    self.parts.push(format!("[{body}] {n}"));
                }
                RowItem::RepeatToEnd { motif, .. } => {
                    let body = self.motif(motif);
                    // "to last N sts": what the items after the repeat take from the row below.
                    let after = items[i + 1..]
                        .iter()
                        .try_fold(0u64, |acc, item| acc.checked_add(item.fixed_totals()?.0));
                    let tail = match after {
                        Some(0) => "to end".to_string(),
                        Some(1) => "to last st".to_string(),
                        Some(n) => format!("to last {n} sts"),
                        // An overflowing suffix is flagged by validation; keep the line readable.
                        None => "to the stitches the rest of the row needs".to_string(),
                    };
                    self.parts.push(format!("*{body}; rep from * {tail}"));
                }
            }
            i += 1;
        }
    }

    /// A motif's text. Its first run always carries its colour label: each repeat after the first is
    /// entered from the motif's own last colour, not from what preceded the repeat.
    fn motif(&mut self, motif: &[StitchOp]) -> String {
        self.prev_color = None;
        self.collapse(motif).join(", ")
    }

    /// Run-length collapse worked stitches: `k, k, k -> "k3"`. When the chart is colorwork, a run is
    /// prefixed with its colour label whenever the colour changes from the previous run (e.g.
    /// `MC k2, CC1 p3`); a run only collapses across stitches of the same symbol AND colour. Without
    /// colorwork, colour is ignored entirely.
    fn collapse(&mut self, ops: &[StitchOp]) -> Vec<String> {
        let legend = &self.pattern.legend;
        let cells: Vec<(&str, usize)> = ops
            .iter()
            .filter_map(|op| {
                // A cell with no explicit colour rides the main colour (index 0).
                legend
                    .get(op.worked)
                    .map(|d| (d.symbol.as_str(), op.color.unwrap_or(0)))
            })
            .collect();
        collapse(&cells, self.labels, &mut self.prev_color)
    }
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
            map.insert(
                idx,
                if multi_contrast {
                    format!("CC{n}")
                } else {
                    "CC".to_string()
                },
            );
        }
    }
    Some(map)
}

/// Run-length collapse a row's (symbol, colour) cells: `k, k, k -> "k3"`, one part per run. When
/// `labels` is `Some` (the chart is colorwork), a run is prefixed with its colour label whenever the
/// colour changes from `prev_color` (e.g. `MC k2, CC1 p3`), which is updated as runs are written; a run
/// only collapses across cells of the same stitch AND colour. When `labels` is `None`, colour is
/// ignored entirely.
fn collapse(
    cells: &[(&str, usize)],
    labels: Option<&HashMap<usize, String>>,
    prev_color: &mut Option<usize>,
) -> Vec<String> {
    let mut parts: Vec<String> = Vec::new();
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
        let stitch = if n > 1 {
            format!("{sym}{n}")
        } else {
            sym.to_string()
        };
        match labels {
            Some(map) if *prev_color != Some(color) => {
                let lbl = map.get(&color).map(String::as_str).unwrap_or("MC");
                parts.push(format!("{lbl} {stitch}"));
                *prev_color = Some(color);
            }
            _ => parts.push(stitch),
        }
        i += n;
    }
    parts
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
            gauge: Gauge {
                sts: 20.0,
                rows: 28.0,
                unit: Unit::Inches,
            },
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
        let p = pat(
            vec![cells(&[builtin::KNIT, builtin::PURL, builtin::PURL])],
            Construction::Flat,
            Side::Rs,
        );
        assert_eq!(to_written(&p), vec!["Row 1 (RS): p2, k"]);
    }

    #[test]
    fn ws_reads_left_to_right_and_resolves_knit_to_purl() {
        // row 0 (WS) stored [k, p, p]; read left-to-right, WS-resolved (k->p, p->k) -> p, k, k -> "p, k2".
        let p = pat(
            vec![cells(&[builtin::KNIT, builtin::PURL, builtin::PURL])],
            Construction::Flat,
            Side::Ws,
        );
        assert_eq!(to_written(&p), vec!["Row 1 (WS): p, k2"]);
    }

    #[test]
    fn flat_alternates_rs_ws_across_rows() {
        let p = pat(
            vec![
                cells(&[builtin::KNIT, builtin::KNIT]),
                cells(&[builtin::KNIT, builtin::KNIT]),
            ],
            Construction::Flat,
            Side::Rs,
        );
        let lines = to_written(&p);
        assert!(lines[0].starts_with("Row 1 (RS):"));
        assert!(lines[1].starts_with("Row 2 (WS):"));
    }

    #[test]
    fn in_the_round_is_all_rounds_no_ws() {
        let p = pat(
            vec![cells(&[builtin::KNIT, builtin::PURL])],
            Construction::InTheRound,
            Side::Rs,
        );
        // a round reads right-to-left; [k, p] -> p, k.
        assert_eq!(to_written(&p), vec!["Round 1: p, k"]);
    }

    #[test]
    fn no_stitch_emits_nothing_and_an_empty_run_is_labeled() {
        let p = pat(
            vec![cells(&[builtin::NO_STITCH, builtin::NO_STITCH])],
            Construction::Flat,
            Side::Rs,
        );
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
        let p = pat(
            vec![colored_row(&[(builtin::KNIT, 0), (builtin::KNIT, 0)])],
            Construction::Flat,
            Side::Rs,
        );
        assert_eq!(to_written(&p), vec!["Row 1 (RS): k2"]);
    }

    #[test]
    fn two_colour_chart_labels_mc_and_a_lone_cc() {
        // Stored L->R: k(MC), k(MC), k(CC). RS reads R->L: CC k, then MC k2. One contrast -> "CC".
        let p = pat(
            vec![colored_row(&[
                (builtin::KNIT, 0),
                (builtin::KNIT, 0),
                (builtin::KNIT, 1),
            ])],
            Construction::Flat,
            Side::Rs,
        );
        assert_eq!(to_written(&p), vec!["Row 1 (RS): CC k, MC k2"]);
    }

    #[test]
    fn three_colours_number_the_contrasts() {
        // Stored L->R: k(MC), k(CC1), k(CC2). RS reads R->L: CC2, CC1, MC. Two contrasts -> numbered.
        let p = pat(
            vec![colored_row(&[
                (builtin::KNIT, 0),
                (builtin::KNIT, 1),
                (builtin::KNIT, 2),
            ])],
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
            vec![colored_row(&[
                (builtin::KNIT, 0),
                (builtin::KNIT, 1),
                (builtin::PURL, 1),
            ])],
            Construction::Flat,
            Side::Rs,
        );
        // R->L: (p,1),(k,1),(k,0) -> "CC p, CC k"? no: first CC p, then CC k (same colour, no relabel),
        // then MC k. -> "CC p, k, MC k".
        assert_eq!(to_written(&p), vec!["Row 1 (RS): CC p, k, MC k"]);
    }

    // --- authored repeats (ADR 0004) ----------------------------------------------------------------

    fn spanned(ids: &[usize], repeats: Vec<RepeatSpan>) -> Row {
        Row {
            cells: ids.iter().map(|&i| Cell::of(i)).collect(),
            repeats,
        }
    }

    fn rep(start: usize, end: usize, count: Repeat) -> RepeatSpan {
        RepeatSpan { start, end, count }
    }

    use builtin::{KNIT as K, PURL as P};

    /// Storage [k | p p k k | k]: on a RS row the edge at the right is worked first and the motif is
    /// read right to left (k k p p).
    const RIB: [usize; 6] = [K, P, P, K, K, K];

    #[test]
    fn the_audit_row_writes_its_repeat() {
        // R-02: this row used to be written "k, p2, k3" (the drawn cells), hiding 8 stitches.
        let p = pat(
            vec![spanned(&RIB, vec![rep(1, 5, Repeat::Times(3))])],
            Construction::Flat,
            Side::Rs,
        );
        assert_eq!(to_written(&p), vec!["Row 1 (RS): k, [k2, p2] 3 times, k"]);
    }

    #[test]
    fn a_simple_fixed_repeat_with_no_edges() {
        let p = pat(
            vec![spanned(&[P, K], vec![rep(0, 2, Repeat::Times(6))])],
            Construction::InTheRound,
            Side::Rs,
        );
        assert_eq!(to_written(&p), vec!["Round 1: [k, p] 6 times"]);
        let once = pat(
            vec![spanned(&[P, K], vec![rep(0, 2, Repeat::Times(1))])],
            Construction::InTheRound,
            Side::Rs,
        );
        assert_eq!(to_written(&once), vec!["Round 1: [k, p] once"]);
    }

    #[test]
    fn a_ws_row_mirrors_the_repeat_and_uses_ws_variants() {
        let p = pat(
            vec![
                spanned(&RIB, vec![rep(1, 5, Repeat::Times(3))]),
                spanned(&RIB, vec![rep(1, 5, Repeat::Times(3))]),
            ],
            Construction::Flat,
            Side::Rs,
        );
        assert_eq!(
            to_written(&p),
            vec![
                "Row 1 (RS): k, [k2, p2] 3 times, k",
                "Row 2 (WS): p, [k2, p2] 3 times, p"
            ]
        );
    }

    #[test]
    fn to_end_names_what_the_rest_of_the_row_takes() {
        let lines = |cells: &[usize], s: RepeatSpan| {
            to_written(&pat(
                vec![spanned(cells, vec![s])],
                Construction::Flat,
                Side::Rs,
            ))
        };
        assert_eq!(
            lines(&RIB, rep(1, 5, Repeat::ToEnd)),
            vec!["Row 1 (RS): k, *k2, p2; rep from * to last st, k"]
        );
        // Nothing after the repeat (on a RS row, nothing LEFT of it).
        assert_eq!(
            lines(&RIB[1..], rep(0, 4, Repeat::ToEnd)),
            vec!["Row 1 (RS): k, *k2, p2; rep from * to end"]
        );
        // Three stitches after the repeat: "to last 3 sts", with the run collapsed.
        assert_eq!(
            lines(&[K, K, K, P, P, K, K, K], rep(3, 7, Repeat::ToEnd)),
            vec!["Row 1 (RS): k, *k2, p2; rep from * to last 3 sts, k3"]
        );
        // A suffix that takes nothing from the row below (a yo) still ends the repeat "to end".
        assert_eq!(
            lines(&[builtin::YO, P, P, K, K], rep(1, 5, Repeat::ToEnd)),
            vec!["Row 1 (RS): *k2, p2; rep from * to end, yo"]
        );
    }

    #[test]
    fn a_decrease_after_the_repeat_counts_the_stitches_it_takes() {
        // [k2tog | p p k k]: k2tog after the motif takes 2 stitches -> "to last 2 sts".
        let p = pat(
            vec![spanned(
                &[builtin::K2TOG, P, P, K, K],
                vec![rep(1, 5, Repeat::ToEnd)],
            )],
            Construction::Flat,
            Side::Rs,
        );
        assert_eq!(
            to_written(&p),
            vec!["Row 1 (RS): *k2, p2; rep from * to last 2 sts, k2tog"]
        );
    }

    #[test]
    fn fixed_and_to_end_repeats_share_a_row() {
        // Storage [k | k k p p | yo k2tog yo k2tog | k] with 1..5 to the end and 5..9 twice. A RS row
        // works right to left: the edge k (col 9), then 5..9 read as k2tog, yo, k2tog, yo, then 1..5
        // read as p, p, k, k, then the edge k (col 0).
        let cells = [
            K,
            K,
            K,
            P,
            P,
            builtin::YO,
            builtin::K2TOG,
            builtin::YO,
            builtin::K2TOG,
            K,
        ];
        let p = pat(
            vec![spanned(
                &cells,
                vec![rep(1, 5, Repeat::ToEnd), rep(5, 9, Repeat::Times(2))],
            )],
            Construction::Flat,
            Side::Rs,
        );
        assert_eq!(
            to_written(&p),
            vec![
                "Row 1 (RS): k, [k2tog, yo, k2tog, yo] 2 times, *p2, k2; rep from * to last st, k"
            ]
        );
    }

    #[test]
    fn runs_do_not_merge_across_a_repeat_boundary() {
        // [k k | k k] with the motif on the right: a RS row works the motif first, then the plain k2;
        // the four knits are not merged into one run.
        let p = pat(
            vec![spanned(&[K, K, K, K], vec![rep(2, 4, Repeat::Times(2))])],
            Construction::Flat,
            Side::Rs,
        );
        assert_eq!(to_written(&p), vec!["Row 1 (RS): [k2] 2 times, k2"]);
    }

    #[test]
    fn a_colorwork_motif_always_labels_its_first_run() {
        // Stored L->R: k(MC) | k(CC) k(MC) | k(MC). RS reads R->L: MC k, [MC k, CC k] 2 times, MC k.
        let row = Row {
            cells: vec![
                Cell::colored(K, 0),
                Cell::colored(K, 1),
                Cell::colored(K, 0),
                Cell::colored(K, 0),
            ],
            repeats: vec![rep(1, 3, Repeat::Times(2))],
        };
        let p = pat(vec![row], Construction::Flat, Side::Rs);
        assert_eq!(
            to_written(&p),
            vec!["Row 1 (RS): MC k, [MC k, CC k] 2 times, MC k"]
        );
    }

    #[test]
    fn a_cable_inside_a_motif_is_written_once() {
        let mut p = pat(vec![], Construction::InTheRound, Side::Rs);
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
        let c = p.legend.stitches.len() - 1;
        let ns = builtin::NO_STITCH;
        p.chart = Chart {
            width: 8,
            rows: vec![spanned(
                &[P, c, ns, ns, ns, P, K, K],
                vec![rep(0, 6, Repeat::Times(4))],
            )],
        };
        assert_eq!(to_written(&p), vec!["Round 1: k2, [p, 2/2 RC, p] 4 times"]);
    }

    #[test]
    fn an_unsupported_row_is_flagged_not_flattened() {
        let p = pat(
            vec![spanned(
                &RIB,
                vec![rep(0, 3, Repeat::Times(2)), rep(2, 5, Repeat::Times(2))],
            )],
            Construction::Flat,
            Side::Rs,
        );
        assert_eq!(
            to_written(&p),
            vec![
                "Row 1 (RS): (repeats need fixing: the repeats over cols 2-4 and cols 4-6 overlap)"
            ]
        );
    }
}
