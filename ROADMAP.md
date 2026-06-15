# Ply roadmap

Milestones are roughly ordered. The guiding principle: **make one craft excellent end to
end (weaving) to harden the shared shell before fanning out.**

## M0 — Engine foundation ✅ (done)
- Cargo workspace; `ply-common` + `ply-weave` + `ply-bridge`.
- Weaving draft model (WIF-shaped), drawdown + RGBA render, sett & warp/yarn calculators,
  validation, WIF import/export. Tested.
- frb bridge surface compiles.

## M1 — Weaving end-to-end in the app
- Run `flutter_rust_bridge_codegen generate`; initialize frb in `main.dart`.
- Import a `.wif` (file_picker) → parse → render preview from the engine's RGBA buffer.
- Persist: save/load drafts as `.wif` on device + a JSON sidecar for app metadata
  (`ProjectMeta`). Local-first, no backend.
- Library screen: list saved drafts with preview thumbnails.
- **Exit criterion:** open a public WIF draft on a phone and see a correct drawdown.

## M2 — Weaving editor
- Edit threading / tie-up / treadling (or liftplan) on an interactive grid.
- Live preview recompute on every edit (it's microseconds).
- Color palette + warp/weft color sequence editing.
- Surface `validate()` issues inline.
- Sett and warp/yarn calculators as a planning panel.

## M3 — Weaving depth
- Weft-yardage estimate (`estimate_weft`: needs PPI + woven width).
- Structure helpers (generate plain/twill/satin tie-ups; profile drafts).
- Export refinements: thickness/spacing, color-palette ranges other than 0..255.
- iOS file-type association for `.wif` (UTI) — see `docs/WIF_MAPPING.md`.
- Property tests / fuzzing: WIF round-trip invariants; engine never panics on adversarial
  input.

## M4 — Visual & UX design pass
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
- ✅ Unified home: a single library with a tab per craft (Weaving | Knitting); the in-app
  glossary now carries knitting terms too.
- ⬜ Deferred: optional **Knitout export** for machine knitters (the one M5 item not yet built).

## M6 — Nalbinding engine (`ply-nalbind`)
- New sibling crate. Encode stitches with the **Hansen notation** (UO/UOO… with connection
  markers); model worked-in-spiral structure rather than a flat grid
  (see `docs/DATA_MODEL.md` sketch).
- Stitch reference + simple structure visualization.

## Later / opportunistic
- Desktop companion (Iced or Flutter desktop) reusing the same engine crates.
- Shared stash/yarn manager across crafts.
- Trigger Claude Code build/test sessions remotely (ties into existing homelab workflow).
