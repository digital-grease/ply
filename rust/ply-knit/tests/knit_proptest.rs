//! Property-based hardening of `ply-knit` (M5). Three guarantees over generated, deliberately
//! ADVERSARIAL patterns (ragged rows, dangling stitch/color ids, malformed cables, out-of-range
//! repeats, overflowing cell sizes, non-finite calculator inputs):
//!
//! 1. the `.plyknit` write -> parse round-trip is identity (over finite-gauge patterns, cast-on set or
//!    not), a legacy (version 1) file migrates with every cell on the stitch it named, and a version-2
//!    file migrates to the same pattern with the cast-on not set, and
//! 2. `validate` / `render_rgba` / `to_written` / the stitch flow / the calculators NEVER panic:
//!    they return a value (often a flagged issue or a clamped 0), the contract the FFI boundary
//!    relies on, and
//! 3. authored repeats mean one thing everywhere: a row with fixed repeats works exactly the
//!    stitches of the same row drawn out in full, a to-end repeat resolves exactly when the stitches
//!    left divide by its motif, the counts equal the sums over the expanded worked sequence, and a
//!    row is refused by the written text exactly when validation reports it (valid repeat rows are
//!    generated too, not only adversarial ones), and a stated cast-on is what row 1 is counted
//!    against.
//!
//! Run: `cargo test -p ply-knit --test knit_proptest`

use ply_common::{Color, Unit, YarnWeight};
use ply_knit::calc::{
    cast_on, estimate_yards_from_swatch, estimate_yards_stockinette, finished_length,
    finished_width, seed_gauge, total_stitches, with_buffer,
};
use ply_knit::instruction::{op_totals, row_instruction, RowInstruction, RowProblem, StitchOp};
use ply_knit::pattern::*;
use ply_knit::{
    render_rgba, stitch_flow, to_written, validate, Severity, KNIT_FORMAT, KNIT_SCHEMA_VERSION,
};
use proptest::prelude::*;

// --- strategies --------------------------------------------------------------------------------

fn arb_unit() -> impl Strategy<Value = Unit> {
    prop_oneof![Just(Unit::Inches), Just(Unit::Centimeters)]
}

/// A FINITE gauge (the only thing `to_json` requires), so the round-trip stays serializable.
fn arb_finite_gauge() -> impl Strategy<Value = Gauge> {
    (0.0f32..1000.0, 0.0f32..1000.0, arb_unit()).prop_map(|(sts, rows, unit)| Gauge {
        sts,
        rows,
        unit,
    })
}

fn arb_color() -> impl Strategy<Value = Color> {
    (any::<u8>(), any::<u8>(), any::<u8>()).prop_map(|(r, g, b)| Color { r, g, b })
}

fn arb_cross() -> impl Strategy<Value = Cross> {
    prop_oneof![Just(Cross::Right), Just(Cross::Left)]
}

/// A cable with possibly-degenerate spans (front/back may be 0) to probe edge handling.
fn arb_cable() -> impl Strategy<Value = CableDef> {
    (0u8..5, 0u8..5, arb_cross(), any::<bool>(), any::<bool>()).prop_map(
        |(front, back, direction, front_purl, back_purl)| CableDef {
            front,
            back,
            direction,
            front_purl,
            back_purl,
        },
    )
}

/// The builtin legend plus 0..=2 custom cables, so cell stitch ids can reference real cables.
fn arb_legend() -> impl Strategy<Value = StitchLegend> {
    prop::collection::vec(arb_cable(), 0..=2).prop_map(|cables| {
        let mut legend = StitchLegend::builtin();
        for (i, c) in cables.into_iter().enumerate() {
            let span = c.span();
            legend.stitches.push(StitchDef {
                symbol: format!("C{i}"),
                consumes: span,
                produces: span,
                ws_variant: None,
                cable: Some(c),
                macro_rows: 1,
            });
        }
        legend
    })
}

/// A cell whose stitch id MAY exceed the legend and whose color MAY exceed the palette.
fn arb_cell() -> impl Strategy<Value = Cell> {
    (0usize..18, prop::option::of(0usize..8)).prop_map(|(stitch, color)| Cell { stitch, color })
}

/// Includes `Times(0)` (refused) on purpose.
fn arb_repeat() -> impl Strategy<Value = Repeat> {
    prop_oneof![(0u16..8).prop_map(Repeat::Times), Just(Repeat::ToEnd)]
}

fn arb_repeat_span(width: usize) -> impl Strategy<Value = RepeatSpan> {
    let hi = width + 3;
    (0..hi, 0..hi, arb_repeat()).prop_map(|(start, end, count)| RepeatSpan { start, end, count })
}

/// RAGGED-capable rows: the cell count is 0..=width+2 (NOT pinned to `width`), with possibly
/// out-of-bounds repeats — the exact adversarial shapes validate/render/written must survive.
fn arb_row(width: usize) -> impl Strategy<Value = Row> {
    (
        prop::collection::vec(arb_cell(), 0..=width + 2),
        prop::collection::vec(arb_repeat_span(width), 0..=2),
    )
        .prop_map(|(cells, repeats)| Row { cells, repeats })
}

/// A cast-on that is not stated, small (so it often matches or divides row 1), 0 (an error), or huge.
fn arb_cast_on() -> impl Strategy<Value = Option<u32>> {
    prop_oneof![Just(None), (0u32..40).prop_map(Some), Just(Some(u32::MAX)),]
}

fn arb_pattern() -> impl Strategy<Value = KnitPattern> {
    (0usize..8, arb_legend()).prop_flat_map(|(width, legend)| {
        (
            prop::collection::vec(arb_row(width), 0..=6),
            prop::collection::vec(arb_color(), 0..=4),
            arb_finite_gauge(),
            prop_oneof![Just(Construction::Flat), Just(Construction::InTheRound)],
            prop_oneof![Just(Side::Rs), Just(Side::Ws)],
            arb_cast_on(),
        )
            .prop_map(
                move |(rows, palette, gauge, construction, first_row_side, cast_on)| KnitPattern {
                    name: "p".into(),
                    construction,
                    first_row_side,
                    cast_on,
                    gauge,
                    palette,
                    legend: legend.clone(),
                    chart: Chart { width, rows },
                    notes: String::new(),
                    sections: Vec::new(),
                },
            )
    })
}

/// Non-cable stitches for VALID repeat rows (plus no-stitch, so motifs can hold fillers).
const PLAIN_STITCHES: [StitchId; 12] = [
    builtin::NO_STITCH,
    builtin::KNIT,
    builtin::PURL,
    builtin::YO,
    builtin::K2TOG,
    builtin::SSK,
    builtin::P2TOG,
    builtin::CDD,
    builtin::M1L,
    builtin::KFB,
    builtin::SLIP,
    builtin::KTBL,
];

/// How one segment of a valid repeat row is worked.
#[derive(Debug, Clone, Copy)]
enum Seg {
    Plain,
    Times(u16),
    ToEnd,
}

/// A row with VALID repeats: segments of 1..=3 cells, each plain or a repeat worked 1..=4 times, and
/// (when `to_end`) exactly one repeat worked to the end. Every motif works at least one stitch and a
/// to-end motif takes at least one from the row below (patched, not filtered, so cases are not lost).
fn arb_valid_repeat_row(to_end: bool) -> impl Strategy<Value = Row> {
    let seg = (
        1usize..=3,
        prop_oneof![Just(Seg::Plain), (1u16..=4).prop_map(Seg::Times)],
        prop::collection::vec(0usize..PLAIN_STITCHES.len(), 3),
    );
    (
        prop::collection::vec(seg, 1..=5),
        any::<prop::sample::Index>(),
    )
        .prop_map(move |(segs, pick)| {
            let mut segs: Vec<_> = segs;
            if to_end {
                let i = pick.index(segs.len());
                segs[i].1 = Seg::ToEnd;
            }
            let mut cells = Vec::new();
            let mut repeats = Vec::new();
            for (len, kind, ids) in segs {
                let start = cells.len();
                let mut motif: Vec<Cell> = ids[..len]
                    .iter()
                    .map(|&i| Cell::of(PLAIN_STITCHES[i]))
                    .collect();
                let count = match kind {
                    Seg::Plain => None,
                    Seg::Times(n) => Some(Repeat::Times(n)),
                    Seg::ToEnd => Some(Repeat::ToEnd),
                };
                if let Some(count) = count {
                    let legend = StitchLegend::builtin();
                    let takes = motif
                        .iter()
                        .map(|c| legend.get(c.stitch).unwrap().consumes)
                        .sum::<u8>();
                    let works = motif.iter().any(|c| c.stitch != builtin::NO_STITCH);
                    if !works || (count == Repeat::ToEnd && takes == 0) {
                        motif[0] = Cell::of(builtin::KNIT);
                    }
                    repeats.push(RepeatSpan {
                        start,
                        end: start + len,
                        count,
                    });
                }
                cells.extend(motif);
            }
            Row { cells, repeats }
        })
}

/// One-row pattern holding `row`, flat (either side) or in the round.
fn single_row(row: Row, construction: Construction, first: Side) -> KnitPattern {
    mk_with(row.cells.len(), vec![row], construction, first)
}

fn mk_with(width: usize, rows: Vec<Row>, construction: Construction, first: Side) -> KnitPattern {
    KnitPattern {
        name: "r".into(),
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
    }
}

/// The row drawn out in full: every fixed motif's cells copied `n` times in storage order, no spans.
fn flattened(row: &Row) -> Row {
    let mut cells = Vec::new();
    let mut col = 0;
    let mut spans = row.repeats.clone();
    spans.sort_by_key(|s| s.start);
    for s in spans {
        cells.extend_from_slice(&row.cells[col..s.start]);
        let Repeat::Times(n) = s.count else {
            panic!("only fixed repeats flatten")
        };
        for _ in 0..n {
            cells.extend_from_slice(&row.cells[s.start..s.end]);
        }
        col = s.end;
    }
    cells.extend_from_slice(&row.cells[col..]);
    Row::plain(cells)
}

/// What a worked stitch IS, without the drawn column it came from.
fn worked_ids(ops: &[StitchOp]) -> Vec<(StitchId, StitchId, Option<usize>, u32, u32)> {
    ops.iter()
        .map(|o| (o.drawn, o.worked, o.color, o.consumes, o.produces))
        .collect()
}

fn arb_construction() -> impl Strategy<Value = (Construction, Side)> {
    (
        prop_oneof![Just(Construction::Flat), Just(Construction::InTheRound)],
        prop_oneof![Just(Side::Rs), Just(Side::Ws)],
    )
}

/// cell_px including the OVERFLOW extremes that must hit render's `checked_mul` guard, not panic.
fn arb_cell_px() -> impl Strategy<Value = u32> {
    prop_oneof![1u32..16, Just(0), Just(u32::MAX / 2), Just(u32::MAX)]
}

/// f32 inputs INCLUDING non-finite, so the calculators' guards are exercised.
fn arb_f32() -> impl Strategy<Value = f32> {
    prop_oneof![
        -1e9f32..1e9,
        Just(0.0f32),
        Just(f32::NAN),
        Just(f32::INFINITY),
        Just(f32::NEG_INFINITY),
    ]
}

fn arb_yarn_weight() -> impl Strategy<Value = YarnWeight> {
    prop_oneof![
        Just(YarnWeight::Lace),
        Just(YarnWeight::SuperFine),
        Just(YarnWeight::Fine),
        Just(YarnWeight::Light),
        Just(YarnWeight::Medium),
        Just(YarnWeight::Bulky),
        Just(YarnWeight::SuperBulky),
        Just(YarnWeight::Jumbo),
    ]
}

// --- properties --------------------------------------------------------------------------------

proptest! {
    /// `from_json(to_json(p)) == p` for finite-gauge patterns: the envelope round-trip is identity,
    /// the output is always a current-version `ply.knit` envelope, and it reads back as current.
    #[test]
    fn json_round_trip_is_identity(p in arb_pattern()) {
        let json = p.to_json().expect("a finite-gauge pattern serializes");
        let v: serde_json::Value = serde_json::from_str(&json).expect("valid JSON");
        prop_assert_eq!(&v["format"], KNIT_FORMAT);
        prop_assert_eq!(v["schema_version"].as_u64(), Some(u64::from(KNIT_SCHEMA_VERSION)));
        let loaded = ply_knit::native::read(&json).expect("our own output parses back");
        prop_assert_eq!(loaded.source_version, KNIT_SCHEMA_VERSION);
        prop_assert_eq!(&loaded.pattern, &p);
        // Saving what was loaded writes the same bytes (a re-save is stable).
        prop_assert_eq!(loaded.pattern.to_json().unwrap(), json);
    }

    /// A LEGACY (bare, version 1) file of a pattern already on the full built-in vocabulary, as
    /// v0.1.7 wrote it (no cast-on), loads unchanged with the cast-on not set: the v1 -> v2 migration
    /// only re-bases older vocabularies and v2 -> v3 states no cast-on.
    #[test]
    fn legacy_file_on_the_full_vocabulary_loads_unchanged(p in arb_pattern()) {
        let legacy = serde_json::to_string(&without_cast_on(&p)).expect("serializes");
        let loaded = ply_knit::native::read(&legacy).expect("a legacy file parses");
        prop_assert_eq!(loaded.source_version, 1);
        prop_assert_eq!(loaded.pattern, KnitPattern { cast_on: None, ..p });
    }

    /// A version-2 envelope (no `cast_on` in its document, as that writer stored it) migrates to the
    /// same pattern with the cast-on not set, and re-saves as a current envelope.
    #[test]
    fn v2_file_migrates_to_the_same_pattern_without_a_cast_on(p in arb_pattern()) {
        let v2 = serde_json::json!({
            "format": KNIT_FORMAT,
            "schema_version": 2,
            "document": without_cast_on(&p),
        })
        .to_string();
        let loaded = ply_knit::native::read(&v2).expect("a v2 file parses");
        prop_assert_eq!(loaded.source_version, 2);
        let expected = KnitPattern { cast_on: None, ..p };
        prop_assert_eq!(&loaded.pattern, &expected);
        let saved = loaded.pattern.to_json().unwrap();
        prop_assert_eq!(ply_knit::native::schema_version(&saved).unwrap(), KNIT_SCHEMA_VERSION);
    }

    /// A pattern as v0.1.0 to v0.1.5 held it (12 built-ins, then its custom cables) migrates so every
    /// cell names the same stitch definition, with the same color, that it named before.
    #[test]
    fn twelve_builtin_legacy_file_keeps_every_cell_on_its_stitch(p in arb_pattern()) {
        let n = StitchLegend::builtin().stitches.len();
        let customs = p.legend.stitches.len() - n;
        let mut old = p.clone();
        old.legend.stitches.drain(12..n);
        for (r, row) in old.chart.rows.iter_mut().enumerate() {
            for (c, cell) in row.cells.iter_mut().enumerate() {
                cell.stitch = if customs > 0 && (r + c) % 3 == 0 {
                    12 + c % customs // a custom cable, at its old index
                } else if (12..n).contains(&cell.stitch) {
                    builtin::KNIT // a built-in that release did not have yet
                } else {
                    cell.stitch
                };
            }
        }
        let migrated =
            KnitPattern::from_json(&serde_json::to_string(&without_cast_on(&old)).unwrap()).unwrap();
        prop_assert_eq!(migrated.cast_on, None);
        prop_assert_eq!(&migrated.legend, &p.legend);
        prop_assert_eq!(migrated.chart.rows.len(), old.chart.rows.len());
        for (old_row, new_row) in old.chart.rows.iter().zip(&migrated.chart.rows) {
            prop_assert_eq!(old_row.cells.len(), new_row.cells.len());
            for (o, m) in old_row.cells.iter().zip(&new_row.cells) {
                prop_assert_eq!(old.legend.get(o.stitch), migrated.legend.get(m.stitch));
                prop_assert_eq!(o.color, m.color);
            }
        }
    }

    /// A legacy file whose cells carry ANY integer id (up to u64::MAX) never panics the migration.
    #[test]
    fn legacy_migration_never_panics_on_huge_ids(ids in prop::collection::vec(any::<u64>(), 0..6)) {
        let builtins = serde_json::to_value(&StitchLegend::builtin().stitches[..12]).unwrap();
        let cells: Vec<_> =
            ids.iter().map(|id| serde_json::json!({"stitch": id, "color": null})).collect();
        let legacy = serde_json::json!({
            "name": "x", "construction": "Flat", "first_row_side": "Rs",
            "gauge": {"sts": 20.0, "rows": 28.0, "unit": "Inches"},
            "palette": [], "legend": {"stitches": builtins},
            "chart": {"width": ids.len(), "rows": [{"cells": cells, "repeats": []}]},
            "notes": "",
        });
        let _ = KnitPattern::from_json(&legacy.to_string());
    }

    /// `validate` never panics on arbitrary (adversarial) patterns.
    #[test]
    fn validate_never_panics(p in arb_pattern()) {
        let _ = validate(&p);
    }

    /// `render_rgba` never panics — incl. cell_px extremes that exercise the overflow guard — and
    /// the raster is always exactly width*height*4 bytes (empty when guarded / zero-area).
    #[test]
    fn render_never_panics_and_buffer_is_consistent(p in arb_pattern(), cell_px in arb_cell_px()) {
        let img = render_rgba(&p, cell_px);
        prop_assert_eq!(img.pixels.len(), img.width as usize * img.height as usize * 4);
    }

    /// `to_written` never panics and emits exactly one line per chart row, after a cast-on line
    /// exactly when the pattern states a cast-on.
    #[test]
    fn written_never_panics_one_line_per_row(p in arb_pattern()) {
        let lines = to_written(&p);
        let cast_on_line = usize::from(p.cast_on.is_some());
        prop_assert_eq!(lines.len(), cast_on_line + p.chart.rows.len());
        if let Some(n) = p.cast_on {
            let starts = format!("Cast on {n} st");
            prop_assert!(lines[0].starts_with(&starts), "{}", lines[0]);
        }
    }

    /// Row 1 is checked against a stated cast-on and nothing else: a cast-on mismatch exactly when
    /// row 1 is counted and consumes a different number, never the row-to-row mismatch on row 1, and
    /// without a cast-on row 1 has no count to match.
    #[test]
    fn row_1_is_checked_against_the_cast_on(p in arb_pattern()) {
        let flow = stitch_flow(&p);
        let Some(first) = flow.first() else { return Ok(()) };
        prop_assert_eq!(first.available, p.cast_on.map(u64::from));
        let mismatch = first
            .problems
            .iter()
            .any(|q| matches!(q, RowProblem::CastOnMismatch { .. }));
        let expected = match (p.cast_on, first.count) {
            (Some(n), Some(c)) => c.consumed != u64::from(n),
            _ => false,
        };
        prop_assert_eq!(mismatch, expected);
        let row_to_row = first
            .problems
            .iter()
            .any(|q| matches!(q, RowProblem::CountMismatch { .. }));
        prop_assert!(!row_to_row, "row 1 has no row below: {:?}", first.problems);
        for f in &flow[1..] {
            let later = f
                .problems
                .iter()
                .any(|q| matches!(q, RowProblem::CastOnMismatch { .. }));
            prop_assert!(!later, "only row 1 works from the cast-on: {:?}", f.problems);
        }
    }

    /// The stitch flow never panics, and wherever it counts a row (and the row is small enough to
    /// write out) the counts are exactly the sums over the expanded worked sequence.
    #[test]
    fn flow_counts_are_the_sums_over_the_expansion(p in arb_pattern()) {
        for f in stitch_flow(&p) {
            let Some(c) = f.count else { continue };
            if c.consumed.max(c.produced) > 20_000 {
                continue;
            }
            let worked = f.worked().expect("a counted row expands");
            prop_assert_eq!(op_totals(&worked), Some((c.consumed, c.produced)));
        }
    }

    /// A row is written as "repeats need fixing" exactly when its repeats are refused, and then every
    /// reason is also a validation error for that row.
    #[test]
    fn written_and_validate_agree_on_refused_rows(p in arb_pattern()) {
        let lines = to_written(&p);
        let issues = validate(&p);
        let rows = &lines[usize::from(p.cast_on.is_some())..];
        for (r, line) in rows.iter().enumerate() {
            let refused = matches!(row_instruction(&p, r), RowInstruction::Unsupported(_));
            prop_assert_eq!(line.contains("(repeats need fixing:"), refused, "{}", line);
            if refused {
                let prefix = format!("row {}:", r + 1);
                prop_assert!(
                    issues.iter().any(|i| i.severity == Severity::Error && i.message.starts_with(&prefix)),
                    "{:?}", issues
                );
            }
        }
    }

    /// Fixed repeats work exactly the stitches of the same row drawn out in full, on either side and
    /// in the round: same worked sequence, same counts.
    #[test]
    fn fixed_repeats_work_the_flattened_row(
        row in arb_valid_repeat_row(false),
        (construction, first) in arb_construction(),
    ) {
        let p = single_row(row.clone(), construction, first);
        let f = single_row(flattened(&row), construction, first);
        let worked = row_instruction(&p, 0).expand(None).expect("a valid row expands");
        let drawn_out = row_instruction(&f, 0).expand(None).expect("a plain row expands");
        prop_assert_eq!(worked_ids(&worked), worked_ids(&drawn_out));
        let (pc, fc) = (stitch_flow(&p)[0].count, stitch_flow(&f)[0].count);
        prop_assert_eq!(pc.map(|c| (c.consumed, c.produced)), fc.map(|c| (c.consumed, c.produced)));
        prop_assert!(validate(&p).iter().all(|i| !i.message.contains("repeat")), "{:?}", validate(&p));
    }

    /// A to-end repeat over a known count resolves exactly when the stitches left after the rest of
    /// the row are a positive multiple of the motif, and then the row takes all of them.
    #[test]
    fn to_end_resolves_exactly_when_the_remainder_divides(
        row in arb_valid_repeat_row(true),
        (construction, first) in arb_construction(),
        times in 1u16..=6,
    ) {
        let w = row.cells.len();
        let base = Row {
            cells: vec![Cell::of(builtin::KNIT); w],
            repeats: vec![RepeatSpan { start: 0, end: w, count: Repeat::Times(times) }],
        };
        let p = mk_with(w, vec![base, row], construction, first);
        let flow = stitch_flow(&p);
        let available = (w as u64) * u64::from(times);
        prop_assert_eq!(flow[0].count.map(|c| c.produced), Some(available));
        let (span, motif) = flow[1].instruction.to_end().expect("one to-end repeat");
        let (motif_c, _) = op_totals(motif).unwrap();
        let reserved: u64 = flow[1]
            .instruction
            .items()
            .unwrap()
            .iter()
            .filter_map(|i| i.fixed_totals().map(|t| t.0))
            .sum();
        let divides = available > reserved && (available - reserved).is_multiple_of(motif_c);
        match flow[1].count {
            Some(c) => {
                prop_assert!(divides);
                prop_assert_eq!(c.consumed, available);
                prop_assert_eq!(reserved + c.to_end_times.unwrap() * motif_c, available);
                let worked = flow[1].worked().unwrap();
                prop_assert_eq!(op_totals(&worked), Some((c.consumed, c.produced)));
                prop_assert!(flow[1].problems.is_empty());
            }
            None => {
                prop_assert!(!divides);
                prop_assert_eq!(flow[1].problems.len(), 1);
                prop_assert_eq!(flow[1].problems[0].span(), Some(span));
                prop_assert!(matches!(
                    flow[1].problems[0].code(),
                    "repeat-to-end-not-divisible" | "repeat-to-end-no-room" | "repeat-to-end-none-left"
                ));
            }
        }
    }

    /// A to-end repeat on row 1 over a stated cast-on resolves exactly when the cast-on, less what the
    /// rest of the row uses, is a positive multiple of the motif; then the row takes the whole
    /// cast-on. Without a cast-on the same row is the advisory unknown-count warning.
    #[test]
    fn a_first_row_to_end_resolves_against_the_cast_on(
        row in arb_valid_repeat_row(true),
        (construction, first) in arb_construction(),
        stated in 0u32..60,
    ) {
        let mut p = single_row(row, construction, first);
        let flow = stitch_flow(&p);
        prop_assert!(flow[0].count.is_none());
        prop_assert_eq!(flow[0].problems.len(), 1);
        let unknown = matches!(
            flow[0].problems[0],
            RowProblem::ToEndUnknownCount { first_row: true, .. }
        );
        prop_assert!(unknown, "{:?}", flow[0].problems);
        prop_assert!(flow[0].problems[0].is_warning());

        p.cast_on = Some(stated);
        let flow = stitch_flow(&p);
        let (_, motif) = flow[0].instruction.to_end().expect("one to-end repeat");
        let (motif_c, _) = op_totals(motif).unwrap();
        let reserved: u64 = flow[0]
            .instruction
            .items()
            .unwrap()
            .iter()
            .filter_map(|i| i.fixed_totals().map(|t| t.0))
            .sum();
        let available = u64::from(stated);
        let divides = available > reserved && (available - reserved).is_multiple_of(motif_c);
        match flow[0].count {
            Some(c) => {
                prop_assert!(divides);
                prop_assert_eq!(c.consumed, available);
                prop_assert_eq!(reserved + c.to_end_times.unwrap() * motif_c, available);
                prop_assert!(flow[0].problems.is_empty(), "{:?}", flow[0].problems);
            }
            None => {
                prop_assert!(!divides);
                prop_assert_eq!(flow[0].problems.len(), 1);
                prop_assert!(!flow[0].problems[0].is_warning());
            }
        }
    }

    /// `from_json` never panics on arbitrary text...
    #[test]
    fn from_json_never_panics_on_text(s in ".*") {
        let _ = KnitPattern::from_json(&s);
    }

    /// ...nor on arbitrary bytes read as lossy UTF-8.
    #[test]
    fn from_json_never_panics_on_bytes(bytes in prop::collection::vec(any::<u8>(), 0..256)) {
        let _ = KnitPattern::from_json(&String::from_utf8_lossy(&bytes));
    }

    /// The calculators never panic and never return NaN on arbitrary (incl. non-finite) inputs.
    #[test]
    fn calculators_never_panic_or_nan(
        a in arb_f32(), b in arb_f32(), ease in arb_f32(),
        sts in arb_f32(), rows in arb_f32(), unit in arb_unit(),
        count in any::<u32>(), repeat in any::<u32>(), frac in arb_f32(),
        sw in (arb_f32(), arb_f32(), arb_f32(), arb_f32(), arb_f32()),
        weight in arb_yarn_weight(),
    ) {
        let g = Gauge { sts, rows, unit };
        prop_assert!(!finished_width(count, g).is_nan());
        prop_assert!(!finished_length(count, g).is_nan());
        let _ = cast_on(a, ease, g, repeat); // a u32 count, never NaN, must not panic
        prop_assert!(!total_stitches(a, b, g).is_nan());
        let est = estimate_yards_stockinette(a, b, g);
        prop_assert!(!est.is_nan());
        // with_buffer is fed the guarded (non-NaN) estimate + an arbitrary fraction.
        prop_assert!(!with_buffer(est, frac).is_nan());
        prop_assert!(!estimate_yards_from_swatch(sw.0, sw.1, sw.2, sw.3, sw.4).is_nan());
        // seed_gauge always yields a positive, finite gauge.
        let sg = seed_gauge(weight);
        prop_assert!(sg.sts.is_finite() && sg.sts > 0.0 && sg.rows.is_finite() && sg.rows > 0.0);
    }
}

/// A hand-built corpus of adversarial patterns that must validate/render/write WITHOUT panicking —
/// including the cable-on-a-ragged-row shape that previously indexed past the row's cells.
#[test]
fn adversarial_corpus_never_panics() {
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
    let g = Gauge {
        sts: 20.0,
        rows: 28.0,
        unit: Unit::Inches,
    };

    let cases: Vec<KnitPattern> = vec![
        // a lone span-4 cable on a width-6 chart with a 1-cell (ragged) row.
        mk(
            6,
            vec![Row::plain(vec![Cell::of(cable_id)])],
            legend.clone(),
            g,
        ),
        // a cell referencing a stitch id well past the legend, plus an out-of-range color.
        mk(
            2,
            vec![Row::plain(vec![
                Cell {
                    stitch: 999,
                    color: Some(99),
                },
                Cell::of(1),
            ])],
            legend.clone(),
            g,
        ),
        // a row far longer than the chart width.
        mk(
            1,
            vec![Row::plain(vec![Cell::of(1); 20])],
            legend.clone(),
            g,
        ),
        // an out-of-range repeat span.
        mk(
            3,
            vec![Row {
                cells: vec![Cell::of(1); 3],
                repeats: vec![RepeatSpan {
                    start: 5,
                    end: 99,
                    count: Repeat::ToEnd,
                }],
            }],
            legend.clone(),
            g,
        ),
        // an empty chart (zero width, no rows).
        mk(0, vec![], legend.clone(), g),
    ];

    for p in cases {
        let _ = validate(&p);
        let _ = render_rgba(&p, 4);
        let _ = render_rgba(&p, u32::MAX); // exercise the overflow guard too
        let _ = to_written(&p);
    }
}

/// `p` as JSON without the `cast_on` key: how the version-1 and version-2 writers stored a pattern.
fn without_cast_on(p: &KnitPattern) -> serde_json::Value {
    let mut v = serde_json::to_value(p).expect("serializes");
    v.as_object_mut().expect("an object").remove("cast_on");
    v
}

fn mk(width: usize, rows: Vec<Row>, legend: StitchLegend, gauge: Gauge) -> KnitPattern {
    KnitPattern {
        name: "t".into(),
        construction: Construction::Flat,
        first_row_side: Side::Rs,
        cast_on: None,
        gauge,
        palette: vec![Color::WHITE],
        legend,
        chart: Chart { width, rows },
        notes: String::new(),
        sections: Vec::new(),
    }
}
