//! STITCH FLOW: how many stitches each chart row takes from the row below and leaves on the needle,
//! computed from the row's WORKED sequence ([`crate::instruction`]), repeats included. The single
//! place stitch counts are worked out; [`crate::validate`] reports what this finds.
//!
//! Rows are walked bottom to top. Row `r + 1` consumes what row `r` produced. A row's counts are those
//! of its expanded worked sequence (`prefix + motif x n + suffix`), computed arithmetically with
//! checked `u64` math; that equals the sums over [`RowInstruction::expand`] (held equal by a property
//! test) without allocating a huge worked row.
//!
//! The count before row 1 is the pattern's cast-on ([`KnitPattern::cast_on`]) when it states one:
//! row 1 must then consume exactly that many stitches ([`RowProblem::CastOnMismatch`] otherwise),
//! and a to-end repeat on row 1 resolves against it like on any other row. Without a cast-on, row 1's
//! own consumption is the starting count and a to-end repeat on it cannot be counted.
//!
//! A to-end repeat resolves only when the stitch count before its row is known and the stitches left
//! after the rest of the row (`available - reserved`) are a positive exact multiple of the motif's
//! consumption. Otherwise the row gets a [`RowProblem`] and its count is UNKNOWN, never guessed. A row
//! after an unknown row counts again if it has no to-end repeat (its consumption is its own), but its
//! continuity with the unknown row below cannot be checked.

use crate::instruction::{op_totals, row_instruction, RowInstruction, RowItem, RowProblem};
use crate::pattern::{KnitPattern, Side};

/// The worked stitch counts of one row.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RowCount {
    /// Stitches taken from the row below (for row 1, the stitches cast on).
    pub consumed: u64,
    /// Stitches on the needle after the row.
    pub produced: u64,
    /// How many times the row's to-end repeat is worked, when it has one.
    pub to_end_times: Option<u64>,
}

/// One row of the flow.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RowFlow {
    /// The chart row (0-based, bottom row = 0).
    pub row: usize,
    /// The side the row is worked from.
    pub side: Side,
    /// The row as an instruction.
    pub instruction: RowInstruction,
    /// Stitches on the needle before the row, when known: what the row below produced, or for the
    /// first row the pattern's cast-on (`None` when the pattern does not state one).
    pub available: Option<u64>,
    /// The row's counts, when they can be worked out.
    pub count: Option<RowCount>,
    /// Everything wrong with the row's repeats or counts (structural problems first).
    pub problems: Vec<RowProblem>,
}

impl RowFlow {
    /// The expanded worked sequence of this row, when it can be expanded (see
    /// [`RowInstruction::expand`]).
    pub fn worked(&self) -> Option<Vec<crate::instruction::StitchOp>> {
        let times = self.count.and_then(|c| c.to_end_times);
        self.instruction.expand(times)
    }
}

/// Chart row `r` (0-based) as an instruction, and its counts when worked over `available` stitches
/// (`None` = unknown), with every problem found in its repeats or counts. No continuity check: the
/// caller compares the row's consumption with what it has on the needle. [`stitch_flow`] walks the
/// chart with it; the section ledger ([`crate::sections`]) works a chart row from the stitches the
/// ledger has waiting.
pub fn chart_row_count(
    pattern: &KnitPattern,
    r: usize,
    available: Option<u64>,
) -> (RowInstruction, Option<RowCount>, Vec<RowProblem>) {
    let instruction = row_instruction(pattern, r);
    let mut problems = Vec::new();
    let count = match &instruction {
        RowInstruction::Unsupported(found) => {
            problems.extend(found.iter().cloned());
            None
        }
        RowInstruction::Sequence(items) => count_row(items, available, r, &mut problems),
    };
    (instruction, count, problems)
}

/// Walk every chart row, bottom to top, and work out its counts.
pub fn stitch_flow(pattern: &KnitPattern) -> Vec<RowFlow> {
    let mut out = Vec::with_capacity(pattern.chart.rows.len());
    let mut available: Option<u64> = pattern.cast_on.map(u64::from);
    for r in 0..pattern.chart.rows.len() {
        let (instruction, count, mut problems) = chart_row_count(pattern, r, available);
        // Continuity: the row must take exactly what the row below left, and row 1 exactly the
        // cast-on. (A to-end row takes all of it by construction; an unknown count below cannot be
        // checked.)
        if let (Some(below), Some(c)) = (available, count) {
            if c.consumed != below {
                problems.push(if r == 0 {
                    RowProblem::CastOnMismatch {
                        consumed: c.consumed,
                        cast_on: below,
                    }
                } else {
                    RowProblem::CountMismatch {
                        consumed: c.consumed,
                        produced_below: below,
                    }
                });
            }
        }
        out.push(RowFlow {
            row: r,
            side: pattern.row_side(r),
            instruction,
            available,
            count,
            problems,
        });
        available = count.map(|c| c.produced);
    }
    out
}

/// The counts of a supported row, given the stitches available before it. Pushes a problem and
/// returns `None` when they cannot be worked out.
fn count_row(
    items: &[RowItem],
    available: Option<u64>,
    r: usize,
    problems: &mut Vec<RowProblem>,
) -> Option<RowCount> {
    // Everything except the to-end repeat has a count of its own.
    let mut fixed = (0u64, 0u64);
    let mut to_end = None;
    for item in items {
        if let RowItem::RepeatToEnd { span, motif } = item {
            to_end = Some((*span, motif));
            continue;
        }
        let Some((c, p)) = item
            .fixed_totals()
            .and_then(|(c, p)| Some((fixed.0.checked_add(c)?, fixed.1.checked_add(p)?)))
        else {
            problems.push(RowProblem::CountTooLarge);
            return None;
        };
        fixed = (c, p);
    }
    let Some((span, motif)) = to_end else {
        return Some(RowCount {
            consumed: fixed.0,
            produced: fixed.1,
            to_end_times: None,
        });
    };
    let Some((motif_c, motif_p)) = op_totals(motif) else {
        problems.push(RowProblem::CountTooLarge);
        return None;
    };
    let reserved = fixed.0;
    let Some(available) = available else {
        problems.push(RowProblem::ToEndUnknownCount {
            span,
            first_row: r == 0,
            motif: motif_c,
            reserved,
        });
        return None;
    };
    if available < reserved {
        problems.push(RowProblem::ToEndNoRoom {
            span,
            available,
            reserved,
        });
        return None;
    }
    let left = available - reserved;
    // `instruction` refuses a to-end motif that consumes nothing, so motif_c > 0 here.
    if motif_c == 0 || !left.is_multiple_of(motif_c) {
        problems.push(RowProblem::ToEndNotDivisible {
            span,
            available,
            reserved,
            motif: motif_c,
        });
        return None;
    }
    let times = left / motif_c;
    if times == 0 {
        problems.push(RowProblem::ToEndNoneLeft { span, available });
        return None;
    }
    let Some(produced) = motif_p
        .checked_mul(times)
        .and_then(|m| m.checked_add(fixed.1))
    else {
        problems.push(RowProblem::CountTooLarge);
        return None;
    };
    Some(RowCount {
        consumed: available,
        produced,
        to_end_times: Some(times),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::instruction::span;
    use crate::pattern::*;
    use ply_common::{Color, Unit};

    use builtin::{K2TOG, KFB, KNIT as K, NO_STITCH as NS, PURL as P, YO};

    fn pat(width: usize, rows: Vec<Row>, construction: Construction) -> KnitPattern {
        KnitPattern {
            name: "t".into(),
            construction,
            first_row_side: Side::Rs,
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
        }
    }

    fn row(ids: &[usize], repeats: Vec<RepeatSpan>) -> Row {
        Row {
            cells: ids.iter().map(|&i| Cell::of(i)).collect(),
            repeats,
        }
    }

    fn counts(p: &KnitPattern) -> Vec<Option<(u64, u64, Option<u64>)>> {
        stitch_flow(p)
            .iter()
            .map(|f| f.count.map(|c| (c.consumed, c.produced, c.to_end_times)))
            .collect()
    }

    fn codes(p: &KnitPattern) -> Vec<Vec<&'static str>> {
        stitch_flow(p)
            .iter()
            .map(|f| f.problems.iter().map(RowProblem::code).collect())
            .collect()
    }

    const RIB: [usize; 6] = [K, P, P, K, K, K];

    #[test]
    fn the_audit_example_counts_fourteen_and_catches_the_plain_row() {
        // R-02: edge k + [k, k, p, p] x 3 + edge k, then a plain 6-stitch row.
        let p = pat(
            6,
            vec![
                row(&RIB, vec![span(1, 5, Repeat::Times(3))]),
                row(&[K; 6], vec![]),
            ],
            Construction::Flat,
        );
        assert_eq!(counts(&p), vec![Some((14, 14, None)), Some((6, 6, None))]);
        assert_eq!(codes(&p), vec![vec![], vec!["stitch-count-mismatch"]]);
    }

    #[test]
    fn to_end_resolves_from_the_row_below_across_consecutive_rows() {
        let p = pat(
            6,
            vec![
                row(&RIB, vec![span(1, 5, Repeat::Times(3))]),
                row(&RIB, vec![span(1, 5, Repeat::ToEnd)]),
                row(&RIB, vec![span(1, 5, Repeat::ToEnd)]),
            ],
            Construction::Flat,
        );
        assert_eq!(
            counts(&p),
            vec![
                Some((14, 14, None)),
                Some((14, 14, Some(3))),
                Some((14, 14, Some(3)))
            ]
        );
        assert!(codes(&p).iter().all(Vec::is_empty));
        // The expansion agrees with the counts.
        for f in stitch_flow(&p) {
            let worked = f.worked().unwrap();
            assert_eq!(worked.len(), 14);
            assert_eq!(op_totals(&worked), Some((14, 14)));
        }
    }

    #[test]
    fn to_end_with_a_remainder_is_an_error_not_a_guess() {
        // Row 1 ends with a kfb: 6 drawn stitches make 7. Row 2 reserves 2 edges: 5 left, not 4n.
        let p = pat(
            6,
            vec![
                row(&[K, K, K, K, K, KFB], vec![]),
                row(&RIB, vec![span(1, 5, Repeat::ToEnd)]),
            ],
            Construction::Flat,
        );
        assert_eq!(counts(&p), vec![Some((6, 7, None)), None]);
        let flow = stitch_flow(&p);
        assert_eq!(
            flow[1].problems,
            vec![RowProblem::ToEndNotDivisible {
                span: crate::instruction::SpanRef {
                    index: 0,
                    start: 1,
                    end: 5
                },
                available: 7,
                reserved: 2,
                motif: 4
            }]
        );
    }

    #[test]
    fn to_end_on_the_first_row_is_unknown_and_so_is_the_next_to_end_row() {
        let p = pat(
            6,
            vec![
                row(&RIB, vec![span(1, 5, Repeat::ToEnd)]),
                row(&RIB, vec![span(1, 5, Repeat::ToEnd)]),
                row(&RIB, vec![span(1, 5, Repeat::Times(2))]),
                row(&RIB, vec![span(1, 5, Repeat::ToEnd)]),
            ],
            Construction::InTheRound,
        );
        assert_eq!(
            counts(&p),
            vec![None, None, Some((10, 10, None)), Some((10, 10, Some(2)))],
            "a fixed row counts again on its own; the to-end row above it resolves"
        );
        let flow = stitch_flow(&p);
        assert!(matches!(
            flow[0].problems[..],
            [RowProblem::ToEndUnknownCount {
                first_row: true,
                motif: 4,
                reserved: 2,
                ..
            }]
        ));
        assert!(matches!(
            flow[1].problems[..],
            [RowProblem::ToEndUnknownCount {
                first_row: false,
                ..
            }]
        ));
        assert!(
            flow[2].problems.is_empty(),
            "no continuity check across an unknown row"
        );
        assert!(flow[0].problems[0].is_warning());
    }

    #[test]
    fn a_cast_on_counts_a_first_row_to_end_and_everything_after_it() {
        // The same chart as above, now with 26 stitches cast on: every row is counted.
        let mut p = pat(
            6,
            vec![
                row(&RIB, vec![span(1, 5, Repeat::ToEnd)]),
                row(&RIB, vec![span(1, 5, Repeat::ToEnd)]),
                row(&RIB, vec![span(1, 5, Repeat::Times(6))]),
            ],
            Construction::InTheRound,
        );
        p.cast_on = Some(26);
        assert_eq!(
            counts(&p),
            vec![
                Some((26, 26, Some(6))),
                Some((26, 26, Some(6))),
                Some((26, 26, None))
            ]
        );
        assert!(codes(&p).iter().all(Vec::is_empty), "{:?}", codes(&p));
        let flow = stitch_flow(&p);
        assert_eq!(flow[0].available, Some(26), "row 1 works from the cast-on");
        assert_eq!(flow[0].worked().unwrap().len(), 26);
    }

    #[test]
    fn row_1_consuming_other_than_the_cast_on_is_a_mismatch_naming_both() {
        let mut p = pat(4, vec![row(&[K; 4], vec![])], Construction::Flat);
        p.cast_on = Some(5);
        assert_eq!(counts(&p), vec![Some((4, 4, None))], "the row still counts");
        assert_eq!(
            stitch_flow(&p)[0].problems,
            vec![RowProblem::CastOnMismatch {
                consumed: 4,
                cast_on: 5
            }]
        );
        assert_eq!(codes(&p), vec![vec!["cast-on-mismatch"]]);
        // A first-row to-end repeat that does not divide the cast-on is the divisibility error,
        // with the cast-on as what is available.
        let mut p = pat(
            6,
            vec![row(&RIB, vec![span(1, 5, Repeat::ToEnd)])],
            Construction::Flat,
        );
        p.cast_on = Some(27);
        assert_eq!(counts(&p), vec![None]);
        assert!(matches!(
            stitch_flow(&p)[0].problems[..],
            [RowProblem::ToEndNotDivisible {
                available: 27,
                reserved: 2,
                motif: 4,
                ..
            }]
        ));
    }

    #[test]
    fn no_room_and_none_left_are_errors() {
        // Row 1: 1 stitch. Row 2 reserves 2.
        let p = pat(
            6,
            vec![
                row(&[K, NS, NS, NS, NS, NS], vec![]),
                row(&RIB, vec![span(1, 5, Repeat::ToEnd)]),
            ],
            Construction::InTheRound,
        );
        assert_eq!(codes(&p)[1], vec!["repeat-to-end-no-room"]);
        // Row 1: 2 stitches. Row 2 reserves exactly 2.
        let p = pat(
            6,
            vec![
                row(&[K, K, NS, NS, NS, NS], vec![]),
                row(&RIB, vec![span(1, 5, Repeat::ToEnd)]),
            ],
            Construction::InTheRound,
        );
        assert_eq!(codes(&p)[1], vec!["repeat-to-end-none-left"]);
    }

    #[test]
    fn lace_balance_is_counted_inside_the_repeat() {
        // In the round, motif worked R->L: k2tog, yo, k, k (balanced). Then an increase row (k3, kfb).
        let p = pat(
            4,
            vec![
                row(&[K, K, K, K], vec![span(0, 4, Repeat::Times(5))]),
                row(&[K, K, YO, K2TOG], vec![span(0, 4, Repeat::ToEnd)]),
                row(&[K, K, K, KFB], vec![span(0, 4, Repeat::ToEnd)]),
                row(&[K, K, K, K], vec![span(0, 4, Repeat::ToEnd)]),
            ],
            Construction::InTheRound,
        );
        assert_eq!(
            counts(&p),
            vec![
                Some((20, 20, None)),
                Some((20, 20, Some(5))),
                Some((20, 25, Some(5))),
                None
            ],
            "25 stitches are not a multiple of 4"
        );
        assert_eq!(codes(&p)[3], vec!["repeat-to-end-not-divisible"]);
    }

    #[test]
    fn an_unsupported_row_is_not_counted_and_the_next_to_end_row_says_why() {
        let p = pat(
            6,
            vec![
                row(&RIB, vec![span(1, 5, Repeat::Times(0))]),
                row(&RIB, vec![span(1, 5, Repeat::ToEnd)]),
            ],
            Construction::InTheRound,
        );
        assert_eq!(counts(&p), vec![None, None]);
        assert_eq!(
            codes(&p),
            vec![
                vec!["repeat-zero-times"],
                vec!["repeat-to-end-unknown-count"]
            ]
        );
    }

    #[test]
    fn huge_counts_report_instead_of_overflowing() {
        // A custom stitch making 255 from 1, repeated to the end, multiplies the count every row.
        let mut p = pat(1, vec![], Construction::InTheRound);
        p.legend.stitches.push(StitchDef {
            symbol: "big".into(),
            consumes: 1,
            produces: 255,
            ws_variant: None,
            cable: None,
            macro_rows: 1,
        });
        let big = p.legend.stitches.len() - 1;
        p.chart
            .rows
            .push(row(&[big], vec![span(0, 1, Repeat::Times(u16::MAX))]));
        for _ in 0..12 {
            p.chart
                .rows
                .push(row(&[big], vec![span(0, 1, Repeat::ToEnd)]));
        }
        let flow = stitch_flow(&p);
        assert!(flow
            .iter()
            .any(|f| f.problems.contains(&RowProblem::CountTooLarge)));
    }
}
