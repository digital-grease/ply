# Ply roadmap

Milestones are roughly ordered. The guiding principle: **make one craft excellent end to
end (weaving) to harden the shared shell before fanning out.**

## Current state (verified 2026-11-19)

M0 to M6 have shipped. Status words: **Verified** (works in the current checkout), **Partial**
(exists, but important behavior is missing), **Not built**.

| Area | Status | Known limits |
|---|---|---|
| Weaving editor, drawdown, WIF import/export, calculators, validation | Verified | Rendering is bounded to a phone memory budget; large drafts render only the visible part of the drawdown at the current zoom, so even drafts over 4 million intersections can be viewed and edited. Re-saving a WIF from another program keeps its author and other credit lines and records which program first wrote it (drafts re-saved by earlier builds already lost that credit); it also keeps the file's warp and weft spacing and the other `[WARP]` and `[WEFT]` keys Ply does not model, under their own units |
| Loom profiles and the loom check | Verified | My looms (in Settings) describes the looms you weave on: type, shafts, treadles, how many treadles you press at once, weaving width, reeds and notes, every field optional and never invented. A draft planned for one of them gets a loom check, kept apart from its structural validation, that names the exact conflict: shafts, treadles or lift plan, treadles at once, a tie-up written for the other shed, unbalanced sheds on a counterbalance, the width in the reed (a double-width cloth at its folded width) and the reed and sleying order for the sett. Levers, dobby pegs and skeleton tie-ups are not modelled, and the checks await a weaver's review |
| Warp, weft and finishing planning | Verified | A worksheet in the weaving editor works from the finished size you want (width, length, how many items, hems, fringe and sampling) back through draw-in, take-up, shrinkage and loom waste to the warp ends, the width in the reed, a reed and sleying plan, the warp length, the picks and the warp and weft yarn, and compares the yarn with what the linked materials have on hand. A measured swatch is used where it has the number, every other figure is labelled as one of Ply's starting estimates (chosen by structure), and any one assumption can be overridden and set back without changing the swatch or the material. Double weave is planned as one layer (enter its ends and sett), there are no per-fiber estimates, the plan is not printed yet, and the figures await a weaver's review |
| Variable thread thickness | Verified | The editor is a strict structural draft (uniform cells, ignores thickness, every cell aligned); thickness shows in the yarn previews, labelled as an approximate look, not a fabric model |
| Structure generators | Partial | Plain/twill/satin accurate (plain weave on an odd shaft count requires a point draw); shadow weave is the authentic Atwater/Powell block weave on 4 or 8 shafts (straight or point layout, treadled as drawn in, sized in whole repeats), checked against original reference fixtures that still await a practitioner weave-check; overshot and double weave are simplified examples. Generated structures weave the same cloth on rising and sinking (counterbalance/countermarch) sheds |
| Overshot book treadling, pick roles, shot groups, shuttles | Verified | Picks can be marked pattern, tabby, top or bottom layer; runs in one shed can be grouped as double or triple shots; each pick can carry a shuttle (pass direction is worked out from each shuttle's rhythm) and a strand count. All of it travels in a WIF private section other programs skip. The Book view shows exact, editable "Use tabby" shorthand when pattern and tabby picks alternate, and says why when they do not |
| Double weave: layers and construction | Verified | Each pick is shown in exactly one layer or listed with the reason it weaves neither. Ply works out each edge (open, or layers joined at a fold or closed edge) from the layer roles, shuttles and starting sides; a construction (two independent layers, tube, double width with the fold left or right) is labelled only when you confirm it and is checked against those edges. A top-face view is shown only when it is unambiguous. Layer exchange, pockets and stitched cloth are not built |
| Profile drafts | Partial | Engine helper only, not exposed in the app |
| Knitting chart editor, written instructions, validation | Verified | Every built-in stitch has its own chart symbol. Repeats (worked N times or to the end of the row) drive written instructions, stitch counts and validation; an optional cast-on count checks row 1 and opens the written instructions; save does not validate |
| Knitting sections (construction) | Partial | Optional named sections of steps, flat or in the round: chart rows, knitting or purling across, rows or rounds, short rows (wrap and turn, German, or a plain turn, including turns at the gap with a decrease for a heel turn), cast on, bind off, stitches put on hold and returned, working flat over part of the stitches (a heel flap), picking up stitches along an edge, needle groups such as instep and sole, repeated shaping until a count remains, moving the start of the round, grafting or a three-needle bind-off, and written steps Ply does not check. Ply counts the stitches after every step, for each needle group too, and refuses a step that asks for stitches the needle does not have instead of guessing; the written instructions and the PDF follow the sections. A pattern can also name its pieces (a hand and a thumb, a body and two sleeves): each piece has its own needle and stitch count, stitches on hold can become a new piece with picked-up stitches, and a join knits another piece or a held group into the work, so a sock, a mitten with its thumb, a yoke sweater and a top-down raglan split into body and sleeves can be written. Seaming pieces with no live stitches, working two pieces at once and "make 2" are not built, and the wording awaits a knitter's check |
| Nalbinding reference, notation playground, loop diagram | Partial | Notation is read strictly or leniently with every problem listed at its position, and nothing is dropped silently; the loop diagram is labelled as a one-stitch sketch and marked approximate when the notation was not read exactly. Multi-round and fabric views are not built |
| Nalbinding projects (notation, notes, photos, recipes) | Verified | Notation is checked strictly as you type and problems stay listed, but saving is still allowed (a project is a draft). An optional recipe lists the piece as steps in working order (start, body, shaping, finish, and free text Ply does not read), each with its own stitch if needed; Ply checks the order, the numbers and each notation and counts the stitches from the recipe's own numbers, but does not simulate the fabric. A follow view ticks steps done. The step names and wording await a nalbinder's check |
| Materials and swatches | Verified | Yarns and measured swatches for every craft, with every number in its unit and marked measured or entered; what Ply works out from a swatch (gauge, shrinkage, take-up, draw-in) is shown, never saved over the measurements. Projects link to them, one swatch can serve many projects, and the knitting and weaving calculators and the warp and weft plan can use a swatch and list where each input came from. There is no nalbinding calculator |
| Tablet weaving | Verified | A Tablet weaving tab (card weaving finds it too) with an editor for the cards (threads per hole, S or Z threading, a starting position from two named presets, packs), the turning per card and per pack (forward, backward, idle, turns written as words, flips, twist releases, repeats), a pick-by-pick stepper showing each card's position and twist, the band's top face and back (pick 1 at the bottom), and the checks with their places. Ply works out which thread shows on each face and keeps a twist count for every card, and reports long floats, too much twist and the setups it does not model (half turns, other hole counts) instead of guessing. Bands are saved as `.plytab` files, carried by backups and printed with the setup, the turning chart, the band and written instructions. Checked against three hand-worked bands; the rules await a tablet weaver's review, and no band has been woven from Ply yet |
| Crochet engine | Partial | The engine only, no app yet: flat rows with turning chains, joined, spiral and turned rounds, chain spaces, front and back loops, increases, decreases, groups and repeats, with every stitch attached to an explicit place and every row and round counted; US and UK names are labels on the same stitches. What it does not model stays the pattern's own words, marked not checked. No editor, file, chart or written instructions yet (M11-02), and the rules await a crocheter's review |
| Ready to make or share | Verified | Saving never checks anything. Printing or sharing a PDF first checks the pattern for each craft: errors stop a ready copy (the dialog's default is Go back), and the pattern can only be printed as a separately chosen draft copy whose every page says it is not ready and how many errors it has; warnings and what Ply could not check are listed in full and acknowledged in one step. Each weaving, knitting and nalbinding problem says where it is (end, pick, chart row and column, section and step, notation position, recipe step) with a Show button that goes there. The loom check and the warp and weft plan warn but never block. WIF files, project exports and backups are never gated, and no editor asks before saving |
| Progress tracking | Partial | Every craft: weave pick by pick (shaft looms and tablet bands), knit row by row (chart rows, or section steps with a row counter inside them) and nalbind step by step (a recipe's steps; its Done ticks stay as they are). Ply shows what to press, lift or turn, or what to knit and from which side, keeps your place, a short log and notes apart from the pattern, and resumes after a restart. When the pattern changes at or before your place (on a second or later time through, anywhere in it) it asks you to check the place instead of moving it, and a place it cannot read just now is never written over. Each library tile shows the saved place (a knitting one in the tracker's own words, such as "Section 1: Cuff, step 2, row 5") and opens straight into the tracker. Backups carry your place. The wording awaits a weaver's, a knitter's, a nalbinder's and a tablet weaver's check |
| Native file formats | Verified | `.plyknit`, `.plynal` and `.plytab` carry a schema version: older files migrate on open (a knit file keeps a one-time backup before its first upgrade), files from a newer Ply are refused and never overwritten; the loom profiles and materials files and the progress records follow the same rules. Sidecars keep keys they do not know. Unknown fields inside a document are not kept (newer files are refused instead) |
| Library backup and restore | Verified | Settings saves every project of every craft (with photos and your place in it, your loom profiles, and your materials and swatches with their photos, and optionally app settings) to one `.plybackup` file wherever you choose; any single project can be exported the same way. Restore checks every file first (a pattern from a newer Ply is refused from its version alone, and a file far more complex or more deeply nested than any Ply makes is refused without being decoded), previews new, identical and differing projects, adds differing ones as copies without replacing anything (a project that differs only in your place counts as already there and keeps your place), and restores settings only if ticked. Long nalbinding notes no longer stop a backup. Weaving notes are limited to 10,000 characters and can be read and changed from a saved draft's menu; when notes saved before that limit stop a backup, the message says how to shorten them, and over-long notes open read-only with the choice to save them as a text file, keep the first 10,000 characters or clear them. Loom profiles, materials and older knitting files are read within a fixed memory budget, libraries read large project details in the background, and names are limited to 200 characters where they are typed (longer names saved earlier still open) |
| Printable patterns (PDF) | Partial | Weaving drafts (a four-quadrant book draft with the tie-up in any corner, split into numbered parts when large; the colored drawdown; Use tabby when exact; role letters, shot groups, shuttles and pass directions, fold and open edges; written directions), knitting patterns (gauge, cast-on, stitch key, chart with numbers and repeat boxes, written instructions, problems) and nalbinding projects (notation, loop diagram, findings, notes, photos) and tablet bands (setup, turning chart, band, written instructions) print or share as PDF, offline, A4 or US Letter by your units; a pattern with errors prints only as a marked draft copy. Printed weaving drafts still await a weaver's comparison with reference patterns; threading repeats and profile blocks are not printed because drafts do not record them |
| Engineering gates | Verified | 1101 Rust + 1889 Flutter host tests green; all 88 device integration tests (33 files) passed on the emulator on 2026-11-19; CI also gates on `cargo fmt` and `cargo clippy -D warnings`. The Android build uses Gradle 9 and AGP 9, so it runs on current JDKs |

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
- ✅ Pick roles and Use tabby (M8-06 first slice and M8-08, pulled forward): roles stay aligned
  through every edit, travel inside the .wif, and drive an exact, editable "Use tabby" Book view.
- ✅ Backup follow-ups: single-project export, opt-in app settings, restored nalbind copies keep
  their new name, missing thumbnails regenerate. Generating a tie-up or treadling onto a
  liftplan draft is now refused unless it covers every pick (it used to drop picks).
- ✅ Shot groups and shuttles (rest of M8-06): double and triple shots, shuttles with derived pass
  direction, strands per pick, kept aligned through every edit and stored with the pick roles.
- ✅ Android toolchain: Gradle 9.8, AGP 9.4 and Kotlin 2.4 (the Rust build plugin was ported to the
  Gradle 9 APIs), and the device integration suite runs and passes on an emulator again.
- ✅ Double-weave construction (M8-09, first two slices): derived edges, confirmed construction
  labels checked against them, a generator for two layers, tube and double width, an edge legend and
  an honest top-face view.
- ✅ Printable patterns, first slice (M9-02): PDF infrastructure plus knitting and nalbinding PDFs.
- ✅ Printable weaving drafts (M9-02, second slice): a four-quadrant book draft in any of four
  layouts, the colored drawdown, Use tabby, working annotations and written directions.
- ✅ Every built-in knitting stitch has its own chart symbol (eight shaping stitches used to share
  the custom-stitch square).
- ✅ WIF credit kept on re-save: the author and other `[TEXT]` lines survive a save, the program
  that first wrote the file is recorded in Ply's private section and printed, and a structure
  generator that changes the draft's size no longer drops the file's other kept sections.
- ✅ Knitting sections, first slice (M9-01): flat short rows and held stitches, with a stitch
  ledger after every step, in knit format v4 (older files migrate with no sections).
- ✅ Loom profiles (M8-02): My looms, a loom chosen for each draft, and a loom check apart from
  structural validation that names the exact conflict; full backups carry the profiles, and a WIF
  re-save keeps the file's warp and weft spacing.
- ✅ Knitting sections, second slice (M9-01): a sock heel and gusset, with work in the round, a heel
  flap and heel turn, picked-up stitches, needle groups, repeated shaping and a grafted toe, in knit
  format v5 (older files migrate with the old meaning).
- ✅ Materials and swatch records (M8-01): yarns and measured swatches shared by every craft, linked
  from any project, and calculator estimates that list where each input came from; full backups
  carry them with the swatches' photos.
- ✅ Nalbinding recipes (M8-04): an optional step-by-step recipe with checked stitches and counts and
  a follow view, in nalbinding format v3 (older projects open unchanged).
- ✅ Photos lose their location, camera and time details when they are added (JPEG and PNG).
- ✅ Tablet weaving conventions (M10-00): the viewpoint, hole labels, threading, turns and twist are
  decided with worked examples; the files will be `.plytab`, and the craft is called tablet weaving
  (card weaving finds it too).
- ✅ Warp, weft and finishing planning (M8-03): a worksheet from the finished size to the loom setup
  and the yarn, with every figure's source shown and one assumption at a time overridable, saved
  with the draft and carried by backups.
- ✅ Knitting sections, third slice (M9-01): pieces, joins and pieces made from held stitches, with a
  stitch count per piece, in knit format v6 (older files migrate as one piece).
- ✅ Tablet weaving engine (M10-01): a deterministic card-turn engine with the visible face and a
  twist count per card, bounded against hostile files and checked against hand-worked bands.
- ✅ Ready to make or share (M7-05): one set of severities for every craft, problems with their
  places and a Show button, and a readiness check before printing or sharing that allows a pattern
  with errors only as a marked draft copy; previews and charts that cannot be drawn say so.
- ✅ Tablet weaving in the app (M10-02): the editor, stepper, band preview, `.plytab` files, backup
  and restore, and a printable setup and turning chart.
- ✅ Backup and restore hardening: long nalbinding notes no longer stop a backup; restore counts the
  values and depth of the backup's index and of each sidecar before reading them; a knitting pattern
  of the current version is read without a general-purpose copy in memory (at most about 160 MiB for
  a crafted file, down from about 900 MiB); weaving notes are limited to 10,000 characters.
- ✅ Weaving draft notes after saving: a saved draft's notes can be read and changed from its menu in
  the library or the editor, an editor save never writes older notes back, and notes too long for a
  backup open read-only with ways to keep them as a text file, shorten them or clear them.
- ✅ Progress tracking, first slice (M8-05): weaving and knitting trackers that keep your place apart
  from the pattern, resume after a restart, never move a place silently when the pattern changes,
  and travel in backups.
- ✅ Crochet research and proposed conventions (M11-00): stitches identified by structure with US and
  UK names as labels, explicit attachment for every stitch, turning chains, joined, spiral and
  turned rounds, and worked examples counted by hand. Accepted by the owner (2026-11-18): US terms
  by default with a UK setting, `.plycro` files; a crocheter's review is still to come.
- ✅ Progress tracking for every craft (M8-05): tablet weaving and nalbinding trackers, a later
  time through checked against the whole pattern, a place that cannot be read just now never
  written over, and the place on each library tile (a knitting one in the tracker's own words)
  with a way straight into the tracker.
- ✅ Crochet core (M11-01): an engine that attaches every stitch to an explicit place and counts
  every row and round, with the conventions' hand-counted examples as its tests; no app yet.
- ✅ Restore and library hardening: loom profiles, materials and older knitting files decoded
  within a fixed memory budget, library listings that read large project details in the
  background, and a 200-character limit on names where they are typed.
- ⬜ Next: a weaver's check of the printed drafts, the shadow-weave and double-weave fixtures, the
  loom checks and the warp and weft plans; a knitter's check of the section wording and the sock,
  mitten, yoke and raglan fixtures; a nalbinder's check of the recipes; a tablet weaver's check of
  the card-turn rules and a woven band; a crocheter's review of the conventions and the engine;
  then crochet authoring and display (M11-02), full profile drafting, and a project completion
  record (M9-03).

## Later / opportunistic
- Desktop companion (Iced or Flutter desktop) reusing the same engine crates.
- Shared stash/yarn manager across crafts (now M8-01 in the post-M6 plan).
- Trigger Claude Code build/test sessions remotely (ties into existing homelab workflow).
