# Data model

The source of truth is the code (`rust/ply-weave/src/draft.rs`); this explains the shape
and the *why*.

## Weaving

A weaving draft has four interacting parts, plus color. Ply models them to mirror WIF so
import/export is lossless for what we support.

```
            treadling (or liftplan)            picks ↓
                  │
   threading ─────┼──── tie-up ──── drawdown (computed) ──── render → RGBA preview
   (warp ends →)  │
                  └── color: palette + warp colors + weft colors
```

### Core types

| Type | Meaning |
|---|---|
| `Draft` | The whole editable document: shafts, treadles, shed, unit, threading, drive, colors, per-thread thickness, notes, and any retained (unmodeled) WIF sections. |
| `ShaftId(u16)`, `TreadleId(u16)` | **1-based** newtypes. Weavers and WIF count from 1; staying 1-based avoids a class of off-by-one bugs. |
| `Threading(Vec<Vec<ShaftId>>)` | Per warp end (in order), the shaft(s) it threads through. Empty = unthreaded (legal); usually exactly one. |
| `TieUp(Vec<Vec<ShaftId>>)` | Per treadle, the shafts it's tied to. |
| `Treadling(Vec<Vec<TreadleId>>)` | Per pick, the treadle(s) pressed. |
| `Liftplan(Vec<Vec<ShaftId>>)` | Per pick, the shafts raised directly (table/dobby looms). |
| `Drive` | `Treadled { tieup, treadling }` **or** `Liftplan(..)`. A draft is one or the other. |
| `ShedType` | `Rising` or `Sinking` — which way the named shafts move. |
| `ColorPlan` | `palette: Vec<Color>` + `warp: Vec<ColorIndex>` + `weft: Vec<ColorIndex>`. |
| `warp_thickness`, `weft_thickness` (`Vec<f32>`) | Per warp end / weft pick, a **relative** thread thickness (1.0 = base) that drives variable-width/height drawdown cells (M4). Empty = uniform. Length-coupled to ends/picks like colors; parsed from WIF `[WARP/WEFT THICKNESS]`, the thinnest present thread maps to the base pixel pitch. |
| `RetainedSection` | A WIF `[SECTION]` Ply does not model (spacing, vendor sections), kept verbatim for export fidelity (M3): round-tripped on a structural edit, stale per-thread ones dropped on a resize. |

### Three decisions worth knowing

**1. `Drive` is a sum type, not two optional fields.** A draft is *either* treadled *or*
liftplan-driven; an enum makes the illegal "both/neither" states unrepresentable.
`Draft::to_liftplan()` converts treadled→liftplan losslessly (union the tie-up over the
pressed treadles). The reverse, `Draft::factor_liftplan`, treats each distinct lift as one
treadle (rising shed, so the cloth is unchanged) when the plan stays under a treadle-count
cap; a too-complex dobby plan keeps its liftplan. It runs on WIF import so a `[LIFTPLAN]`-only
file shows the conventional tie-up + treadling. (The editor also renders the treadling
COMPRESSED — one numbered row per run of identical picks — but the stored model stays per-pick.)

**2. Shed direction is resolved in exactly one place.** `Draft::raised_shafts(pick)`
returns the canonical set of shafts that are *up* for a pick:
- Liftplan lists raised shafts directly → returned as-is.
- Treadled → union of tie-up entries for the pressed treadles; on a **sinking** shed those
  name the *lowered* shafts, so the raised set is the complement within `1..=shafts`.

`compute()` (drawdown) consumes only this canonical set, so no other code has to reason
about rising vs sinking. This is the single most bug-prone area of weaving software; keep it
contained here.

**3. The drawdown is derived, never stored.** `compute(&Draft) -> Drawdown` is pure and
cheap, so the editable document stays minimal and there's no cache to invalidate. Each cell
is `WarpUp(colorIndex)` or `WeftUp(colorIndex)`; `render_rgba` turns that into pixels.

### Calculators (`calc.rs`)

- `suggest_sett(wpi, structure)` — ends-per-inch from wraps-per-inch, scaled by structure
  (plain ~0.50, twill ~0.66, satin ~0.75 of WPI). Rules of thumb, meant as a starting point.
- `estimate_warp(plan)` — warp length and total warp yarn from finished length, item count,
  loom waste, and take-up/shrinkage.
- `estimate_weft(plan)` — total weft yarn from picks-per-unit, woven width, woven length,
  and item count. Weft take-up + selvedge wastage is a **user-supplied field** (`takeup`),
  not a baked-in constant: it's width-direction crimp that varies with yarn and beat, so
  the weaver dials it in. Scales each pick's length, not the pick count.

### Validation (`validate.rs`)

Cheap structural checks (shaft/treadle ranges, color-count mismatches, treadles with no
tie-up), returned as `Vec<ValidationIssue>` with `Error`/`Warning` severity. Safe to run on
every edit.

## Knitting (sketch — not built, M5)

Knitting has **no universal interchange standard** (KnitML stalled; Knitout is
machine-only), so Ply will define its own schema. Likely shape:

- A **chart grid** of `Stitch` cells (symbol + attributes), the knitting analogue of the
  drawdown — except the chart *is* the editable source, not a computed view.
- A `Stitch`/op model (knit, purl, yo, k2tog, ssk, cable-n, …) so charts and written
  instructions are two renderings of one structure.
- Gauge in stitches-and-rows-per-unit; a yardage estimator parallel to weaving's.
- Optional **Knitout** export for machine knitters.

Reuses the shell (library, persistence, calculators pattern, glossary); only the model +
editor are new.

## Nalbinding (sketch — not built, M6)

Nalbinding isn't grid-based — it's worked in a **spiral/tube**, each new stitch connecting
into earlier loops. Model it around the established **Hansen notation**:

- A stitch as a `U`/`O` sequence (needle passes Under/Over loops, viewed flat), e.g. the
  Oslo stitch `UO/OUOO`, with connection markers (`F`/`B` joins, the `/` return point).
- Structure as a sequence of stitches plus connection metadata (which earlier loops each
  new stitch enters), rather than an (x,y) grid.
- A stitch reference/dictionary (there are thousands of regional variants) and a simple
  structural visualization rather than a true drawdown.

This is the most different of the three crafts and is intentionally last, after the shell
is proven on weaving and stretched once by knitting.
