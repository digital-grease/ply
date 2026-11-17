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
| `PickRole`, `pick_roles` (`Vec<PickRole>`) | Per weft pick, what it is for: `Unknown` (default), `Pattern`, `Tabby`, `TopLayer`, `BottomLayer`. Empty = every role unknown (every third-party WIF); otherwise length-coupled to the picks and kept aligned by every operation that changes them. Never inferred from color or shafts. The overshot and double-weave generators record them; the Book view sets them and, when they allow it exactly, shows the overshot "Use tabby" shorthand. Stored in a WIF 1.1 private section (see WIF_MAPPING). |
| `WeftWork`, `weft_work` | How the weft is worked (M8-06): per pick its shuttle (`Option<ShuttleId>`, 1 to 8; empty = all unknown) and strands carried together in the pass (`u8`, 1 to 4; empty = all 1), each shuttle's starting `Side`, and the `ShotGroup`s (a range of at least two consecutive picks worked as repeated passes in ONE shed: a double or triple shot, which is not double weave). Pass direction is DERIVED (`Draft::pass_starts`: each shuttle alternates its own direction from its starting side), never stored. Groups are kept on one shed by `Draft::sound_shot_groups` through every pick edit. Never inferred. Stored with the roles in the WIF private section. Also the declared double-weave `construction` (below). |
| `Construction`, `weft_work.construction` (`Option<Construction>`) | The double-weave construction the weaver declared or a generator set (M8-09): `TwoLayers`, `Tube`, or `DoubleWidth { fold: Side }`. A label, never inferred: `construction::derive_edges` derives what happens at each selvedge from the pick roles, shuttles and starting sides (at each turn of a shuttle, its next pick on the other layer joins the layers at that edge, on the same layer leaves the edge open), summarized per edge as open, joined, mixed, or unknown; validation warns where the declared construction and the derived edges disagree. Kept through every pick edit. Stored in the WIF private section (`Version=2`). |
| `RetainedSection` | A WIF `[SECTION]` Ply does not model (spacing, vendor sections), kept verbatim for export fidelity (M3): round-tripped on a structural edit, stale per-thread ones dropped on a resize. The `[TEXT]` lines other than the title and the unmodeled keys of `[WARP]` / `[WEFT]` (such as `Spacing`) are kept the same way under the names `TEXT`, `WARP` and `WEFT`, and written back inside their own sections. |

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
- `estimate_weft_for_draft(plan, draft)`: the same, counting the strands each pass carries. The plan
  works from totals, so the draft's picks are taken as the repeat and the total scales by the draft's
  average strands per pick (`Draft::mean_strands`); the pick count is unchanged.

### Validation (`validate.rs`)

Cheap structural checks (shaft/treadle ranges, color-count mismatches, treadles with no
tie-up, a pick-role list whose length disagrees with the picks, picks marked tabby whose shed
is not plain weave, shuttle and strand ranges, a shot group whose picks do not share one shed,
one shuttle passing twice in one shed without a shot group, a declared double-weave construction
that the derived edges contradict or cannot check), returned as `Vec<ValidationIssue>`
with `Error`/`Warning`/`Info` severity. `Info` is advice about a deliberate instruction (a grouped
double shot needs the weft caught at the selvedge). Safe to run on every edit.

A **tabby (plain-weave) shed** is a raised-shaft set that lifts exactly every other threaded
warp end (`Draft::plain_weave_phase`); "tabby a" lifts the first threaded end.

### Loom profiles and feasibility (`loom.rs`, `loom_file.rs`, `feasibility.rs`)

A **loom profile** (`LoomProfile`) is the weaver's equipment, not part of a draft: a stable id, a
name, a loom type (`LoomKind`: jack, counterbalance, countermarch, table, dobby, or not recorded),
shafts, treadles, the weaving width (the widest warp in the reed, with its unit), the reeds (dents
per inch or per 10 cm), how many treadles the weaver presses at once, and free setup notes. Every
equipment field may be missing; unknown is `None` (or an empty reed list), never 0. The profiles
are stored in Ply's own `looms.json` (an envelope like `.plyknit`: `format` `ply.looms`,
`schema_version` 1, a newer file refused), never in WIF. Which loom a draft is planned for is kept
in the draft's sidecar under `loomPlan` (the loom's id and name, and the weaver's sett for the
check).

`feasibility::check(draft, profile, input)` says whether the draft can be woven on that loom as
drafted, SEPARATELY from `validate`: a structurally valid draft can be not feasible, and a
structurally broken one still gets its loom check. Each finding (`LoomDiagnostic`) has a stable
code (such as `loom.shafts_exceeded`), a severity (not feasible, advice, not checked, fits), a
short summary and a sentence with the exact requirement ("This draft threads 8 shafts; Floor loom
has 4."), and where it applies (shafts, treadles or picks) and what to do when Ply can say. The
checks: distinct shafts threaded against the loom's; distinct treadles pressed (a table loom or
dobby works from the liftplan instead; a liftplan on a treadle loom needs a treadle per distinct
shed); treadles pressed at once; the tie-up's shed direction against the loom type (advice to tie
the other squares, never an error); unbalanced sheds on a counterbalance (advice); the width in
the reed (ends over the sett, from the weaver or from `[WARP] Spacing`) against the weaving width,
with a double-width cloth checked at its folded width; and a reed and sleying for the sett. A check
whose input is unknown reports that it was not checked.

## Materials and swatches (every craft: `ply-common`)

A crafter's **materials** (yarns or threads) and **swatches** (measured samples) are reusable
references shared by every craft, not part of any pattern and never in WIF, `.plyknit` or `.plynal`.
No pattern needs one to open.

**Quantities** (`quantity.rs`) keep the numbers and unit the crafter gave: `Length` (mm, cm, m, in,
yd), `Mass` (g, kg, oz, lb), `LengthPerMass` ("200 m per 100 g") and `CountOver` (a count over a
span: a gauge, a sett, picks, wraps, "20 over 10 cm"). Conversions use exact factors (1 in =
2.54 cm, 1 yd = 0.9144 m, 1 lb = 453.59237 g, 1 oz = 1/16 lb), and a value that is not a finite
number above zero is reported with a stable code (`quantity.not_finite`, `quantity.not_positive`,
`quantity.too_large`).

**Provenance** (`provenance.rs`): every stored number is `Recorded { value, source }`, where the
source is `Measured` or `Entered` (from a label, a pattern or a setup). `Default` (one of Ply's rules
of thumb) appears only in estimates; a record that holds one is refused.

**Records** (`materials.rs`). A `Material`: name, maker, fiber blend (fibers with optional shares),
Craft Yarn Council weight category, structure, length per mass, wraps per inch, color, dye lot,
mass and length on hand, notes. A `Swatch`: craft, technique, date, yarns (a material by id with its
name, or a name alone, and a role), tools, for weaving the sett and the width in the reed, and three
measurement stages (`on_loom` for weaving, `before` finishing, `after` finishing), each with the
swatch's width and length, counts across (stitches or ends) and along (rows or picks) and how it was
measured; the finishing, the swatch's mass, tension notes and provenance. Every field may be missing,
and unknown is never zero. Swatch photos are kept by the app beside the record
(`<documents>/swatches/<id>.photos/`), never in it; as any photo is added, the location, camera and
time details of a JPEG or PNG are removed (a JPEG keeps its orientation), and a WebP or HEIC is kept
as it is.

**Derived figures** (`Material::figures`, `Swatch::figures`) are worked out from the measurements
each time they are shown and are never stored: yards and metres per 100 g, yards per pound, wraps per
inch and per cm, the length (or mass) on hand; counts per 10 cm and 4 in (or per inch and cm for
weaving); the change in width and length through finishing; for weaving draw-in, take-up, shrinkage
and the total losses (each over the earlier measurement), and the length and width allowances
(earlier over finished, minus one, so the finished size times one plus the allowance is the size to
weave); grams per 100 sq cm. **Diagnostics** have stable codes: values that cannot be true
(`swatch.date_invalid`, `material.fiber_percents_over_100`, `record.default_source`, ...) stop a
record being saved; unusual ones (`swatch.grew_implausibly`, `swatch.wider_than_reed`, ...) are
warnings.

**Storage**: Ply's own `materials.json` (`materials_file.rs`: `format` `ply.materials`,
`schema_version` 1, a newer file refused before its records are read, unknown fields refused,
unknown values written as `null`, at most 500 of each record and 2 MB). A project links records in
its sidecar under `materials` (`yarns`: material id, its name, a role; `swatches`: swatch id and its
name); the name is kept so a link whose record is gone still says what it was.

**Estimates that show their working** (`ply_knit::plan`, `ply_weave::plan`): the existing
cast-on, yarn, warp and weft calculators, fed from a swatch, typed numbers, the draft or Ply's
defaults, return every input with its source and a sentence ("20 sts per 10 cm, measured after
finishing, swatch Grey wool 2026-11-10"; "10%, Ply's default"), the working, and caveats. From a
swatch they take the gauge after finishing (before finishing only with a caveat), the sett in the
reed, the length allowance, and the picks counted on the loom; the knitting yarn estimate uses the
weighed swatch (its mass per area and its one yarn's length per mass) when it can. With typed inputs
they give exactly the calculators' numbers.

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
