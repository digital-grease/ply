# WIF mapping

[WIF](https://en.wikipedia.org/wiki/WIF_(file_format)) (Weaving Information File) is the
universal weaving interchange format: INI-style text (`[SECTION]` headers, `key=value`
lines), supported by essentially all weaving software and computerized looms, and the
format of the large body of public drafts. Ply adopts it as the **native weaving format**
— so "import/export" is mostly free and patterns stay portable.

Implementation: `rust/ply-weave/src/wif.rs` (`parse` / `write`).

## Section → model

| WIF section | Maps to | v1 |
|---|---|---|
| `[WEAVING]` `Shafts`, `Treadles`, `Rising Shed` | `Draft.shafts`, `.treadles`, `.shed` | ✅ |
| `[WARP]` `Threads`, `Units`, `Color` | end count, `Draft.unit`, default warp color | ✅ |
| `[WEFT]` `Threads`, `Units`, `Color` | pick count, default weft color | ✅ |
| `[THREADING]` `end=shaft[,shaft]` | `Threading` | ✅ |
| `[TIEUP]` `treadle=shaft,…` | `TieUp` | ✅ |
| `[TREADLING]` `pick=treadle,…` | `Treadling` | ✅ |
| `[LIFTPLAN]` `pick=shaft,…` | `Liftplan` (used instead of tie-up+treadling) | ✅ |
| `[COLOR TABLE]` `index=r,g,b` | `ColorPlan.palette` | ✅ (scaled from `Range` to 0..255) |
| `[WARP COLORS]` `end=index` | `ColorPlan.warp` | ✅ |
| `[WEFT COLORS]` `pick=index` | `ColorPlan.weft` | ✅ |
| `[TEXT]` `Title` | `Draft.name` | ✅ (read/written) |
| `[COLOR PALETTE]` `Range`, `Form` | palette range/format | ✅ (any `Range` scaled to 0..255; re-export normalizes to 255) |
| `[WARP THICKNESS]`, `[WEFT THICKNESS]` | `Draft.warp_thickness` / `weft_thickness` | ✅ (modeled; drives variable-cell rendering) |
| other unmodeled sections (spacing, vendor) | `Draft.retained` | ✅ (kept verbatim, re-emitted) |
| `[NOTES]` | `Draft.notes` | ✅ |

Index convention: WIF is **1-based** (color index 1, shaft 1, …). The parser converts color
references to 0-based `ColorIndex` and stores the palette 0-based; shaft/treadle IDs stay
1-based as `ShaftId`/`TreadleId` to match the format and the domain.

## What v1 round-trips

The common shaft-loom draft: geometry + threading + (tie-up & treadling **or** liftplan) +
color table + warp/weft color sequences. `wif::tests::roundtrips_through_write_then_parse`
asserts `parse → write → parse` is stable for that case.

## Known gaps / caveats

- **Palette range.** Resolved (M3): a non-standard `[COLOR PALETTE] Range` (e.g. 0..999) is
  scaled into the model's 0..255 on import, and a re-export normalizes `Range` back to 255.
- **Thickness.** Resolved (M4): `[WARP THICKNESS]` / `[WEFT THICKNESS]` are modeled per-thread
  (`Draft.warp_thickness` / `weft_thickness`) and drive **variable-cell** rendering (a fatter
  thread draws a wider column / taller row); they round-trip through `write`. Other per-thread
  metadata Ply does not model (e.g. spacing) is kept verbatim in `Draft.retained` and re-emitted,
  so a structural-edit re-serialize is no longer lossy for it.
- **Leniency over strictness.** The parser never panics on imperfect files — missing
  sections default sensibly; unknown keys are ignored. It errors only when there's no
  recognizable draft data at all.
- **iOS file association.** Registering `.wif` as an openable type on iOS requires a custom
  **UTI** (`Info.plist` `CFBundleDocumentTypes` / `UTExportedTypeDeclarations`). This is a
  known iOS headache, separate from the parser. Tracked for M3.

## Where to get test drafts

WIF is decades old and widely published; importing real public `.wif` drafts is the
fastest way to exercise the parser and the preview against the M1 exit criterion ("open a
public draft on a phone and see a correct drawdown").
