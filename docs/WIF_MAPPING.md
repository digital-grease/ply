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
| `[COLOR TABLE]` `index=r,g,b` | `ColorPlan.palette` | ✅ (assumes 0..255 range) |
| `[WARP COLORS]` `end=index` | `ColorPlan.warp` | ✅ |
| `[WEFT COLORS]` `pick=index` | `ColorPlan.weft` | ✅ |
| `[TEXT]` `Title` | `Draft.name` | ✅ (read) |
| `[COLOR PALETTE]` `Range`, `Form` | palette range/format | ⬜ assumed RGB 0..255 |
| `[WARP THICKNESS]`, `[WEFT THICKNESS]`, spacing | per-thread thickness/spacing | ⬜ TODO (render fidelity) |
| `[NOTES]` | `Draft.notes` | ⬜ TODO |

Index convention: WIF is **1-based** (color index 1, shaft 1, …). The parser converts color
references to 0-based `ColorIndex` and stores the palette 0-based; shaft/treadle IDs stay
1-based as `ShaftId`/`TreadleId` to match the format and the domain.

## What v1 round-trips

The common shaft-loom draft: geometry + threading + (tie-up & treadling **or** liftplan) +
color table + warp/weft color sequences. `wif::tests::roundtrips_through_write_then_parse`
asserts `parse → write → parse` is stable for that case.

## Known gaps / caveats

- **Palette range.** Only the standard 0..255 RGB range is handled; WIF permits other
  ranges (e.g. 0..999) via `[COLOR PALETTE] Range`. Scale before reading for M3.
- **Thickness & spacing.** Parsed leniently / ignored for now. Needed for realistic cloth
  rendering (thread-width-aware cells), not for structure. M3.
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
