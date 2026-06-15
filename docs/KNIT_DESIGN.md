# Knitting engine design proposal (`ply-knit`, M5)

> **Status: IMPLEMENTED (M5 core, 2026-06).** The owner decisions below are RESOLVED and the engine,
> bridge, and editor are built and tested (see `ROADMAP.md` M5) — including the cable builder and a
> unified tabbed library. This document is kept as the design rationale of record; it is
> research-backed (sources at the end). The one M5 item still deferred is Knitout export.

## Goal & constraints

Add knitting as a sibling engine `ply-knit`, reusing the proven shell (library, on-device persistence,
calculator pattern, glossary, the frb bridge) so **only the model + the editor are new**. Inherited
rules:

- **Pure engine, FFI-free** (plain Rust + serde, like `ply-weave`; only `ply-bridge` imports frb).
  Reuse `ply-common` (`CraftKind::Knitting`, `Color`, `YarnWeight`, `Yarn`, `Unit`, `ProjectMeta`) —
  don't duplicate them.
- **Coarse FFI** — compute the whole chart RGBA/symbol buffer in Rust per call.
- **No interchange standard exists, so we define our own** — which means the data model is the
  milestone's main design risk (the inverse of weaving, which WIF pinned). The research below is what
  de-risks it.

### Guiding principle, learned from KnitML's failure

KnitML (the prior attempt at a universal XML knitting schema) **died of scope creep**: it tried to be
interchange format + multilingual renderer + chart renderer + feasibility validator + auto-grading
engine at once, in verbose XML, conflating "the format" with "a giant Java app," and stalled ~2012 as
a one-maintainer project. **The antidote (and Ply's existing instinct): a tiny declarative canonical
model, kept separate from the renderer/validator, shipping a minimal v1.** Every "wouldn't it be nice"
feature below is explicitly pushed to a later phase.

## Prior art (researched — what exists and why nothing is adoptable)

| Thing | What it is | Verdict for Ply |
|---|---|---|
| **KnitML** | Dead XML schema + Java impl, over-scoped | Cautionary tale, not adoptable |
| **Knitout** (CMU Textiles Lab) | Low-level *machine* needle-op stream (`knit/tuck/split/xfer/miss/drop`); "no flow-control, abstractions, or grouping" | **Export target only** (machine knitters), never the authoring model — the knit analog of G-code |
| **StitchMastery** | Dominant chart editor; proprietary `.knt2`; **chart is source, written derived, repeats auto-condensed**; 500+ glyph font = de-facto symbol standard | Closed — nothing to adopt except *mirror its symbol vocabulary* |
| **Knitspeak / Stitch Maps** | Human text DSL (`Row 1 (RS): k3, yo, ssk`); **text is source, chart derived**; repeats are **authored** (`[..] N times`, `*..rep from *`); single-color only | Best prior art for the written↔chart direction; too narrow alone (no colorwork) |
| **Knotty** | Open reimpl; XML canonical; converts XML⇄Knitspeak⇄chart⇄HTML; adds colorwork | Confirms "one canonical model, many renderings" — Ply's exact architecture |
| **FOSSASIA `knittingpattern`** | JSON, **instruction/graph (stitch-mesh) — deliberately rejects the grid** ("can't use a grid if you split the work"); models connections between stitches | The big architecture fork: mesh handles short-rows/splits a 2-D grid can't (see Owner decision #1) |

**Conclusion (research-backed): define a small, versioned, declarative custom schema; pick ONE
canonical model and derive every view (chart, written, machine); make repeats first-class explicit
structure; mirror StitchMastery's symbol vocabulary; do NOT adopt or extend any existing format.**

## How knitting charts work (the domain facts the model must obey)

- A chart is a **bottom-to-top grid**, but **a cell is not 1:1 with a stitch or a column**:
  - Each symbol carries an implied **(consumes, produces)** count: `yo` 0→1, decreases N→1, increases
    1→N. So a row's live stitch count changes, and **per-row count is derived, not stored**.
  - **"No stitch"** filler cells (grey square; X on colorwork) keep the grid rectangular and columns
    aligned across inc/dec. First-class cell variant, consumes/produces 0.
  - **Cables span multiple columns** — a 2/2 cable occupies 4 adjacent cells, reorders them, is
    count-neutral, and is defined by `{total, front/back split, R/L direction, purl background?}`.
    This breaks per-column independence and is the hardest constraint.
  - **Bobbles / cast-on / bind-off** are single cells with multi-row internal behavior — opaque
    "macro" stitches.
- **Symbols are RS-relative**: a knit symbol worked on a WS row is a purl. Store the RS identity once;
  the *executed* op is `f(symbol, row_side)`. Reading direction (flat = RS R→L / WS L→R; in-the-round
  = always R→L) is **derived from chart-level flags**, never per cell.
- **Colorwork** = an **orthogonal per-cell color channel** over a chart palette, base op defaults to
  knit. (Mirrors weaving's `ColorPlan`, so the palette editor is reused for free.)
- The symbol vocabulary is **open** — designers invent symbols with a per-pattern legend. The model
  must allow **user-defined stitches with attached semantics**, not a closed enum.

## Proposed data model (`pattern.rs`, the `draft.rs` analog)

```rust
// Reuses ply_common: Color, YarnWeight, Yarn, Unit, ProjectMeta, CraftKind::Knitting.

pub struct KnitPattern {
    pub name: String,
    pub construction: Construction,     // Flat | InTheRound
    pub first_row_side: Side,           // Rs | Ws  (flat only; in-the-round is all Rs)
    pub gauge: Gauge,
    pub palette: Vec<Color>,            // colorwork palette (mirrors weaving ColorPlan.palette)
    pub legend: StitchLegend,           // OPEN vocabulary: symbol id -> semantics (see below)
    pub chart: Chart,                   // THE canonical source; written/machine are derived
    pub notes: String,
    pub retained: Vec<RetainedSection>, // forward-compat for an external format we don't model yet
}

pub enum Construction { Flat, InTheRound }
pub enum Side { Rs, Ws }

/// CYC convention: sts AND rows per gauge WINDOW (4 in OR 10 cm, per `unit`). Per-unit density is
/// derived via the unit-aware window (`/4` for inches, `/10` for cm) — a fixed `/4` makes cm wrong.
pub struct Gauge { pub sts: f32, pub rows: f32, pub unit: Unit }

/// Bottom-to-top rows of a fixed-width grid. `NoStitch` fillers keep it rectangular.
pub struct Chart { pub width: usize, pub rows: Vec<Row> }
pub struct Row {
    pub cells: Vec<Cell>,               // len == chart.width (NoStitch pads)
    /// FIRST-CLASS repeats (the key research lesson): authored, not auto-detected. A horizontal
    /// repeat is a column span worked `count` times; vertical repeats live at the Chart level.
    pub repeats: Vec<RepeatSpan>,       // e.g. {cols: 3..7, count: Repeat::ToEnd | Repeat::Times(5)}
}
pub struct RepeatSpan { pub cols: core::ops::Range<usize>, pub count: Repeat }
pub enum Repeat { Times(u16), ToEnd }  // `[..] N times` vs `*..; rep from *`

/// A cell references a stitch in the legend, an optional color, and (for cables) a column span.
pub struct Cell {
    pub stitch: StitchId,               // index into StitchLegend (open vocabulary)
    pub color: Option<ColorIndex>,      // colorwork channel; None = use the working yarn
    pub span: u8,                       // 1 normally; >1 for a cable's owned columns (the rest NoStitch-spanned)
}

/// OPEN vocabulary. Built-ins are seeded; custom stitches are data, not new enum arms — so adding a
/// stitch never touches the schema (the anti-KnitML rule). Mirror StitchMastery symbol names.
pub struct StitchLegend { pub stitches: Vec<StitchDef> }
pub struct StitchDef {
    pub id: StitchId,
    pub symbol: String,                 // CYC/StitchMastery glyph name, e.g. "k","p","yo","k2tog","ssk","cdd"
    pub consumes: u8,
    pub produces: u8,
    pub ws_variant: Option<StitchId>,   // worked-as on a WS row (k->p, ktbl->ptbl, k2tog->p2tog, ...)
    pub cable: Option<CableDef>,        // Some -> multi-column crossing
    pub macro_rows: u8,                 // >1 for bobble/cast-on/bind-off opaque macros (else 1)
}
pub struct CableDef { pub front: u8, pub back: u8, pub direction: Cross, pub front_purl: bool, pub back_purl: bool }
pub enum Cross { Right, Left }
```

What the research forced (vs the first draft): **repeats are first-class** (`RepeatSpan`/`Repeat`),
the **vocabulary is an open `StitchLegend`** not a closed enum, **cables are spanning cells**
(`Cell.span` + `CableDef`), **`ws_variant`** captures RS/WS, **`macro_rows`** flags bobble/cast-on, and
**gauge is per-4-units** per CYC convention.

## Engine modules (mirror `ply-weave`)

| `ply-weave` | `ply-knit` | role |
|---|---|---|
| `draft.rs` | `pattern.rs` | `KnitPattern` model + edits (set cell, resize chart, palette/legend ops) |
| `drawdown.rs` | `render.rs` | chart → RGBA symbol grid + colorwork (the coarse FFI buffer); cables drawn across their span |
| — | `written.rs` | chart → written text, **expanding the authored repeats** (the easy direction; chart→*folded* is deferred) |
| `calc.rs` | `calc.rs` | gauge → dimensions/cast-on; yardage estimate (formulas below) |
| `validate.rs` | `validate.rs` | **stitch-count consistency**: row deltas balance, decreases don't underflow, cable spans fit, repeats divide evenly |
| `wif.rs` | `io.rs` | the custom native format (versioned JSON) + optional `knitout.rs` **export** |
| `profile.rs` | `motifs.rs` (later) | generators: ribbing, seed, basic lace/cable repeats |

`validate.rs` is knitting's most bug-prone area (the `raised_shafts` analog): contain all stitch
arithmetic here so the renderer and editor never re-derive it.

## Calculators (`calc.rs`) — researched formulas

- **Gauge → size** (`g_s = sts / window`, `g_r = rows / window`; window = 4 in or 10 cm):
  `width = sts / g_s`; `cast_on = round((width + ease) * g_s)`, then round to the stitch-repeat multiple
  (and clamp before the `f32 -> u32` cast so an absurd target can't overflow).
- **Yardage** (inherently an estimate — surface a 10–15% buffer):
  - seed/closed-form (stockinette): `yards ≈ (width_in * length_in * g_s) / 6` (the `/6` is an
    empirical stockinette constant, ±10–15%);
  - or swatch model: `g_per_sq_in = swatch_g / swatch_area`; `grams = g_per_sq_in * area`;
    `yards = grams * skein_yds / skein_g`.
  - **Do not** use live-stitch count as the proxy — use total stitches over all rows ≈ `area*g_s*g_r`.
- **Seed gauge from `YarnWeight`** via the CYC table (knit sts / 4 in): Lace 33–40, Super Fine 27–32,
  Fine 23–26, Light(DK) 21–24, Medium(worsted) 16–20, Bulky 12–15, Super Bulky 7–11, Jumbo ≤6. Default
  `g_s = midpoint/4`, `g_r ≈ g_s * 4/3` (rows are denser than columns). All seeds are editable.

## Open problems → proposed resolutions

- **Variable stitch count** → `NoStitch` fillers + per-stitch `(consumes, produces)`; `validate`
  checks deltas; per-row count derived.
- **Cables** → spanning cells (`Cell.span` + `CableDef`); `render` draws the crossing across the span.
- **RS/WS** → store RS identity + `ws_variant`; resolve at render/written time. One inversion point.
- **Repeats** → first-class authored structure (`RepeatSpan`); chart→written *expands* them (trivial).
  Chart→*minimal-folded* written is a lossy compression problem with no canonical answer — **deferred**.
- **No native format** → versioned JSON (`.plyknit`); trivial via serde, lossless, no parser to fuzz.
  Knitout is export-only; a human text DSL (Knitspeak-style) can come later.

## Owner decisions (the point of this doc)

> **Resolved (owner, 2026-06-13):** **#1 = grid for v1** (stitch-mesh held as a possible future layer
> *on top* if seamless garment construction becomes a goal — short rows / splits / pick-up are the
> features that would need it; v1 charts stitch patterns + flat/round panels) · **#2 = ALL** (lace +
> shaping, stranded colorwork, AND cables) · **#3 = JSON `.plyknit`** · **#4 = chart-as-source** ·
> **#5 = both** flat + in-the-round · **#6 = Knitout later** · **#7 = full stitch-count balancing**.
> Cables are grid-able (a cable cell + trailing no-stitch fillers) but are the hard render piece (P2).

1. **Core architecture: grid vs stitch-mesh.** Proposed = **fixed-width grid** (simple, matches chart
   editors, fine for flat lace/colorwork/cables). FOSSASIA's **stitch-mesh graph** handles short rows,
   splits, and non-rectangular work a grid can't — but is much more complex. Grid for v1, mesh only if
   the roadmap demands short-rows/seamless construction soon. **Confirm grid-first?**
2. **MVP stitch vocabulary.** Minimum useful = knit/purl/yo/k2tog/ssk/cdd/m1L/m1R/kfb/slip (lace +
   basic shaping). **Include cables and stranded colorwork in v1, or defer?** (Colorwork is cheap — it
   reuses the weaving palette; cables need the spanning-cell renderer.)
3. **Native format:** versioned JSON (`.plyknit`) as proposed, or a human-text DSL (Knitspeak-like)?
4. **Source of truth:** chart-as-source (StitchMastery/Knotty model, proposed) or text-as-source
   (Knitspeak model)? Both have precedent; chart-as-source reuses the weaving render architecture.
5. **Construction in v1:** flat + in-the-round both, or one first?
6. **Knitout export:** v1 or later opportunistic add?
7. **`validate` v1 scope:** full stitch-count balancing, or start at "renders without panic"?

## Proposed phasing (mirrors the M4 shape; gated on the decisions above)

- **P1** — `ply-knit` scaffold + core model (`KnitPattern`/`StitchLegend`/`Chart`) + serde round-trip
  + `ply-common` reuse. *(no UI)*
- **P2** — `render.rs` chart→RGBA (symbols + colorwork + cable spans) + `ply-bridge` DTOs + codegen.
- **P3** — `validate.rs` (stitch-count consistency) + `calc.rs` (gauge/yardage) + property tests.
- **P4** — `io.rs` native JSON (+ optional Knitout export).
- **P5** — the chart editor in the app (reusing library/persistence/palette/glossary shell).
- **P6** — `written.rs` (chart→text, expanding repeats) + milestone gate (device e2e + held review).

---

## Sources

Chart/representation: [CYC Knit Chart Symbols](https://www.craftyarncouncil.com/standards/knit-chart-symbols) ·
[Atherley — Charting Conventions](https://stitchmastery.com/charting-conventions-a-guest-post-by-kate-atherley/) ·
[Atherley — "There's Nothing There" (no-stitch)](https://stitchmastery.com/theres-nothing-there-guest-post-from-kate-atherley/) ·
[Interweave — Cable Chart Symbols](https://www.interweave.com/article/knitting/understanding-cable-chart-symbols/) ·
[Kelbourne — Colorwork Charts](https://kelbournewoolens.com/blogs/blog/working-from-charts-colorwork).
Formats/tools: [KnitML (GitHub mirror)](https://github.com/fiddlerpianist/knitml) ·
[Knitout spec](https://textiles-lab.github.io/knitout/knitout.html) ·
[StitchMastery fonts/file-types](https://stitchmastery.com/fonts/) ·
[Knitspeak / Stitch Maps](https://stitch-maps.com/about/knitspeak/) ·
[Knotty I/O](https://t0mpr1c3.github.io/knotty/io.html) ·
[FOSSASIA knittingpattern format spec](https://pythonhosted.org/knittingpattern/FileFormatSpecification.html).
Calc: [CYC Standard Yarn Weight System](https://www.craftyarncouncil.com/standards/yarn-weight-system) ·
[StitchMath — yarn estimation](https://stitchmath.com/articles/knitting-yarn-estimation-guide/) ·
[Knitting yardage formula (×g_s/6)](https://completecalculators.com/calculators/knitting/yarn-yardage-calculator).

*Authored as autonomous M5 groundwork, research-grounded. The model is a strawman; the **Owner
decisions** are the ask.*
