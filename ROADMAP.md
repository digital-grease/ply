# Ply roadmap

Milestones are roughly ordered. The guiding principle: **make one craft excellent end to
end (weaving) to harden the shared shell before fanning out.**

## Current state (verified 2026-11-12)

M0 to M6 have shipped. Status words: **Verified** (works in the current checkout), **Partial**
(exists, but important behavior is missing), **Not built**.

| Area | Status | Known limits |
|---|---|---|
| Weaving editor, drawdown, WIF import/export, calculators, validation | Verified | Rendering is bounded to a phone memory budget; large drafts render only the visible part of the drawdown at the current zoom, so even drafts over 4 million intersections can be viewed and edited |
| Variable thread thickness | Verified | The editor is a strict structural draft (uniform cells, ignores thickness, every cell aligned); thickness shows in the yarn previews, labelled as an approximate look, not a fabric model |
| Structure generators | Partial | Plain/twill/satin accurate (plain weave on an odd shaft count requires a point draw); shadow weave is the authentic Atwater/Powell block weave on 4 or 8 shafts (straight or point layout, treadled as drawn in, sized in whole repeats), checked against original reference fixtures that still await a practitioner weave-check; overshot and double weave are simplified examples. Generated structures weave the same cloth on rising and sinking (counterbalance/countermarch) sheds |
| Overshot book treadling | Partial | A separate Book view groups runs of identical picks (pick ranges, every weft color, round-trip edits); the editor keeps one row per pick. Real "Use Tabby" shorthand needs pattern/tabby pick roles, not built yet |
| Double-weave layer view | Partial | Each pick is shown in exactly one layer or listed with the reason it weaves neither; the views show each layer's own interlacement, and there is no view of the finished cloth's face yet |
| Profile drafts | Partial | Engine helper only, not exposed in the app |
| Knitting chart editor, written instructions, validation | Verified | Repeats (worked N times or to the end of the row) drive written instructions, stitch counts and validation; an optional cast-on count checks row 1 and opens the written instructions; save does not validate |
| Nalbinding reference, notation playground, loop diagram | Partial | Notation is read strictly or leniently with every problem listed at its position, and nothing is dropped silently; the loop diagram is labelled as a one-stitch sketch and marked approximate when the notation was not read exactly. Multi-round and fabric views are not built |
| Nalbinding projects (notation, notes, photos) | Verified | Notation is checked strictly as you type and problems stay listed, but saving is still allowed (a project is a draft); no structured recipe model yet |
| Native file formats | Verified | `.plyknit` and `.plynal` carry a schema version: older files migrate on open (a knit file keeps a one-time backup before its first upgrade), files from a newer Ply are refused and never overwritten. Sidecars keep keys they do not know. Unknown fields inside a document are not kept (newer files are refused instead); no general backup/restore yet |
| Library backup and restore | Verified | Settings saves every project (with photos) to one `.plybackup` file wherever you choose; restore checks every file first, previews new, identical and differing projects, and adds differing ones as copies without replacing anything. App settings and single-project export are not included yet |
| Export/share of patterns | Not built | Planned in M9 (print and share layouts) |
| Engineering gates | Verified | 365 Rust + 829 Flutter host tests green; CI also gates on `cargo fmt` and `cargo clippy -D warnings`, and binding generation runs without hanging on current Flutter |

## M0 — Engine foundation ✅ (done)
- Cargo workspace; `ply-common` + `ply-weave` + `ply-bridge`.
- Weaving draft model (WIF-shaped), drawdown + RGBA render, sett & warp/yarn calculators,
  validation, WIF import/export. Tested.
- frb bridge surface compiles.

## M1 — Weaving end-to-end in the app ✅ (done)
- Run `flutter_rust_bridge_codegen generate`; initialize frb in `main.dart`.
- Import a `.wif` (file_picker) → parse → render preview from the engine's RGBA buffer.
- Persist: save/load drafts as `.wif` on device + a JSON sidecar for app metadata
  (`ProjectMeta`). Local-first, no backend.
- Library screen: list saved drafts with preview thumbnails.
- **Exit criterion:** open a public WIF draft on a phone and see a correct drawdown.

## M2 — Weaving editor ✅ (done)
- Edit threading / tie-up / treadling (or liftplan) on an interactive grid.
- Live preview recompute on every edit (it's microseconds).
- Color palette + warp/weft color sequence editing.
- Surface `validate()` issues inline.
- Sett and warp/yarn calculators as a planning panel.

## M3 — Weaving depth ✅ (done, two items open)
- Weft-yardage estimate (`estimate_weft`: needs PPI + woven width).
- Structure helpers (generate plain/twill/satin tie-ups).
- ⬜ Profile drafts: only an engine helper (`ply-weave/src/profile.rs`) that nothing calls yet;
  not in the app (full block-level profile drafting is planned for M8).
- Export refinements: thickness/spacing, color-palette ranges other than 0..255.
- ⬜ Open: iOS file-type association for `.wif` (UTI), see `docs/WIF_MAPPING.md`. Not present in
  `app/ios/Runner/Info.plist`; Android has no `.wif` intent filter either.
- Property tests / fuzzing: WIF round-trip invariants; engine never panics on adversarial
  input.

## M4 — Visual & UX design pass ✅ (done)
- First real design system (this is where dedicated UI/design work belongs — not earlier).
- Drawdown rendering polish: thickness-aware cells, float rendering, zoom/pan, theming.
- Tutorials + reference glossary in-app (seed content from `docs/GLOSSARY.md`).
- Accessibility + responsive layout for tablets.

## M5 — Knitting engine (`ply-knit`) ✅ (core done)
- New sibling crate. Knitting has **no universal interchange standard**, so we designed a
  custom schema (chart grid + stitch legend/op model; resolved owner decisions in
  `docs/KNIT_DESIGN.md`). Native format is JSON (`.plyknit`).
- ✅ Engine: pattern model, drawdown/RGBA chart render (symbols + colorwork + cable spans),
  sett/cast-on/yardage calculators, full stitch-count balancing validation, and chart →
  written-instructions (RS/WS aware, run-length collapsed). FFI-free, unit + property-tested
  (JSON round-trip identity + no-panic over adversarial patterns: ragged rows, dangling ids,
  malformed cables, out-of-range repeats, overflow cell sizes, non-finite calc inputs).
- ✅ Bridge: mirrored knit DTOs + a thin `api.rs` surface; transparent `KnitPatternDto`
  (no opaque handle) so a pattern renders/validates/writes repeatedly.
- ✅ App: chart editor (paint, colorwork palette, undo/redo, zoom), a **cable builder**
  (front/back/cross/purl → a placeable brush that lays the anchor + auto-fills its no-stitch
  cells, with whole-group clearing), on-device persistence (`<docs>/knits/<id>.{plyknit,json,
  png}` triplet), an expandable severity-coded validation band, a written-instructions view, a
  gauge/yardage planning sheet, and pattern settings (construction, first-row side, notes).
- ✅ Unified home: a single library with a tab per craft (Weaving | Knitting, plus Nalbinding
  from M6); the in-app glossary now carries knitting terms too.
- ✅ Repeats (M7): a repeat box over chart cells is worked N times or to the end of the row; written
  instructions, stitch counts and validation all follow it, and the chart editor can mark and clear
  repeats.
- ⬜ Deferred: optional **Knitout export** for machine knitters (the one M5 item not yet built).

## M6 — Nalbinding engine (`ply-nalbind`) ✅ (v1 done)
- New sibling crate. Stitches modeled around **Hansen notation** (`U`/`O` passes, `/`/`:` turns,
  `( )` skipped, `-` no-engage, `F`/`B`/`M`+count connections), identity keyed on (skeleton,
  connection). Owner decisions + research in `docs/NALBIND_DESIGN.md`.
- ✅ Engine: the stitch model (full Hansen grammar), a round-trippable notation parser/printer,
  a curated 12-stitch dictionary (source-attributed codes), a per-stitch structural loop diagram
  generator, and validation. FFI-free, unit + property-tested (notation round-trip + no-panic).
- ✅ Bridge + app: mirrored nalbind DTOs; a "Nalbinding" tab in the unified home → a stitch
  REFERENCE (browse the dictionary with notation + a+b alias + the generated loop diagram drawn by
  a CustomPainter) + a notation playground (type a Hansen string → live diagram + validation). The
  glossary gains nalbinding terms.
- ✅ Simple projects (shipped after v1, in `b246c06`): save a worked piece on device with its
  notation, notes, and photos (`<docs>/nalbinds/<id>.plynal` + sidecar + photo folder).
- Known gaps: the notation parser accepts some malformed input and loses information; the loop
  diagram is a one-stitch schematic with no caption saying so.
- ⬜ Deferred: the structured project/recipe model (worked pieces: spiral/tube/short-row shaping
  segments) and its spiral node-graph view; a 3-D/round structural render.

## M7 onward
Post-M6 milestones: M7 integrity and reliability, M8 loom-aware planning and weaving fidelity,
M9 garment construction and print, M10 tablet weaving, M11 crochet.
- ✅ M7 baseline audit (2026-11-11): current behavior verified against the code; the table above
  reflects it.
- ✅ Data safety: deleting a nalbind project removes its photos (and cleans up photos left by
  earlier deletes); the knit and nalbind editors ask before discarding unsaved edits.
- ✅ Bounded weaving render, first slice: size checks before any allocation, reduced-resolution
  previews for large drafts, a clear message for drafts too large to preview, size caps on
  resize and structure generation.
- ✅ Versioned native formats: explicit schema versions with ordered migrations for `.plyknit` and
  `.plynal`, tested against real files written by v0.1.5 to v0.1.7 (`fixtures/migrations/`); a
  file saved by a newer Ply is refused with a plain message and never overwritten; sidecars keep
  unknown keys on rewrite; settings and photo writes are flushed and atomic.
- ✅ Weaving fixes: generated structures keep their cloth on a sinking shed; plain weave on an odd
  shaft count asks for a point draw; misrouted generator requests are errors instead of a silent
  plain weave; the layer view accounts for every pick.
- ✅ Nalbinding notation: strict reading for authoring and lenient reading for reference, with
  positioned diagnostics, the original text kept, and unsupported syntax preserved instead of
  dropped; the diagram is labelled as a sketch and marked approximate when the reading is not exact.
- ✅ Structural draft and Book view (M7-09): the editor keeps one row per pick on a uniform grid
  shared by all four quadrants; yarn thickness moves to labelled previews; runs of identical
  picks are listed in a separate Book view.
- ✅ Authentic shadow weave (M8-07, pulled forward): Atwater and Powell systems on 4 or 8 shafts,
  straight or point layouts, per-block widths, either twill direction, smooth or feathery block
  edges, whole repeats with an optional balancing end and pick. The structural tests that separate it
  from log cabin run on every generated design, and two original reference fixtures
  (`fixtures/weaving/shadow/`) record the expected cloth. The old log-cabin generator is gone.
- ✅ Executable knitting repeats: worked N times or to the end of the row, with conventional written
  forms (`[k2, p2] 3 times`, `*k2, p2; rep from * to last st, k1`), stitch counts from the worked
  row, and clear problems for repeats that do not divide evenly, overlap, or split a cable.
- ✅ Viewport rendering: large weaving drafts render only what is on screen, at the current zoom,
  so editing stays responsive and drafts over 4 million intersections can be viewed and edited.
- ✅ Knitting cast-on count: optional, stored in knit format v3 (older files migrate with it
  unset); row 1 is checked against it and the written instructions open with it.
- ✅ Library backup and restore: one `.plybackup` file, saved offline wherever you choose; restore
  validates every path and checksum before writing, previews the result, never replaces a
  project, and leaves the library unchanged if anything fails.
- ⬜ Next: a weaver's check of the shadow-weave fixtures; pattern/tabby pick roles for real "Use
  Tabby" shorthand; single-project export.

## Later / opportunistic
- Desktop companion (Iced or Flutter desktop) reusing the same engine crates.
- Shared stash/yarn manager across crafts (now M8-01 in the post-M6 plan).
- Trigger Claude Code build/test sessions remotely (ties into existing homelab workflow).
