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
| `[TEXT]` other lines (`Author`, `Address`, `EMail`, `Telephone`, `FAX`, ...) | `Draft.retained` as `TEXT` | ✅ (kept verbatim and written back into `[TEXT]` beside the Title, so a re-save keeps the credit) |
| `[WIF]` `Source Program`, `Source Version` of a file another program wrote | `Draft.retained` as `[PRIVATE PLY SOURCE]` | ✅ (Ply's written file names Ply as its `Source Program`; the first program is recorded in this private section and kept through every later save; a file that already has the section keeps it) |
| `[COLOR PALETTE]` `Range`, `Form` | palette range/format | ✅ (any `Range` scaled to 0..255; re-export normalizes to 255) |
| `[WARP THICKNESS]`, `[WEFT THICKNESS]` | `Draft.warp_thickness` / `weft_thickness` | ✅ (modeled; drives variable-cell rendering) |
| `[PRIVATE PLY PICKS]` (Ply's WIF 1.1 private section) | `Draft.pick_roles`, `Draft.weft_work` (shuttles, starting sides, strands, shot groups, the declared double-weave construction) | ✅ (written only when something is recorded; see below) |
| `[PRIVATE PLY PICK ROLES]` (the earlier roles-only layout) | `Draft.pick_roles` | read only (`Version=1`); the next save writes `[PRIVATE PLY PICKS]` |
| other unmodeled sections (spacing, vendor, other programs' `[PRIVATE ...]`) | `Draft.retained` | ✅ (kept verbatim, re-emitted) |
| `[NOTES]` | `Draft.notes` | ✅ |

Index convention: WIF is **1-based** (color index 1, shaft 1, …). The parser converts color
references to 0-based `ColorIndex` and stores the palette 0-based; shaft/treadle IDs stay
1-based as `ShaftId`/`TreadleId` to match the format and the domain.

## What v1 round-trips

The common shaft-loom draft: geometry + threading + (tie-up & treadling **or** liftplan) +
color table + warp/weft color sequences. `wif::tests::roundtrips_through_write_then_parse`
asserts `parse → write → parse` is stable for that case.

## Per-pick working data (Ply private section)

Per-pick roles (pattern, tabby, top layer, bottom layer), shuttles and their starting sides, strands
per pick, and shot groups (double shots and longer) are not part of WIF proper. WIF 1.1 reserves
`[PRIVATE <SourceID> <SectionName>]` sections for program-specific data, and readers that do not
recognize one skip it, so Ply stores them in `[PRIVATE PLY PICKS]` (Source ID `PLY`, listed in
`[CONTENTS]` as `PRIVATE PLY PICKS=true`):

```
[PRIVATE PLY PICKS]
Version=1
Picks=8
Sheds=<fingerprint>
Shuttle 1 Start=right
Shot 5=2
1=role pattern, shuttle 1, strands 2
2=role tabby, shuttle 2
```

A declared double-weave construction adds one key and raises the layout to `Version=2`:

```
[PRIVATE PLY PICKS]
Version=2
Picks=8
Sheds=<fingerprint>
Construction=double-width, fold left
Shuttle 1 Start=right
1=role top-layer, shuttle 1
2=role bottom-layer, shuttle 1
```

`Construction` is `two-layers`, `tube`, `double-width, fold left` or `double-width, fold right`
(read case-insensitively; anything else is no construction, never a guess). It is a label the weaver
confirms or a generator sets; Ply checks it against the edges it derives from the roles, shuttles and
starting sides, and never labels a WIF that does not carry it. A draft without one still writes
`Version=1`, byte-identical to before; a `Version=1` section never carries a construction, and this
build reads both.

`Version` is the section layout (a higher one is kept verbatim and not read). Only picks with
something recorded are listed, as comma-separated `name value` attributes: `role` (`pattern`,
`tabby`, `top-layer`, `bottom-layer`), `shuttle` (1 to 8), `strands` (1 to 4; 1 is not written).
`Shuttle <n> Start` is that shuttle's starting side (`left` / `right`, as the weaver sits at the
loom); pass directions are derived from it, never stored. `Shot <first pick>=<passes>` is a shot
group: that many passes in one shed. `Picks` and `Sheds` tie the data to the cloth: `Sheds` is FNV-1a
64-bit over each pick's raised shafts (ascending, comma-separated, each pick followed by `;`) as 16
lowercase hex digits, so it is the same for any re-expression of one cloth (tie-up or liftplan,
either shed) and changes when picks are added, removed, reordered, or re-shedded. The section is read
only when both match, so a file whose picks another program changed opens with all of it unknown
rather than on the wrong picks. A WIF without the section (every third-party file) opens with
everything unknown; nothing is guessed (not shuttles from colors, not double shots from repeated
treadles). A program that re-saves a Ply file may drop private sections (WIF does not require
keeping them); the woven draft is unaffected (a double shot is two consecutive picks on one shed in
any reader), only the working data is lost. The earlier `[PRIVATE PLY PICK ROLES]` layout (`Version=1`,
`pick=role` lines) is still read for roles. Rationale: ADR 0008, ADR 0009 and ADR 0010 (private).

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
