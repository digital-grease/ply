# Architecture

## Layers

```
┌───────────────────────────────────────────────────────────┐
│  Flutter app  (app/)                                        │
│  screens · interactive grid · CustomPainter preview · state │
└───────────────▲───────────────────────────────────────────┘
                │ generated Dart bindings (app/lib/src/rust)
┌───────────────┴───────────────────────────────────────────┐
│  ply-bridge   — the ONLY crate that imports frb           │
│  api.rs: coarse-grained calls + bridge DTOs                 │
└───────────────▲───────────────────────────────────────────┘
                │ plain Rust calls
┌───────────────┴───────────────────────────────────────────┐
│  Engine crates (pure Rust, no FFI, no Flutter)              │
│    ply-weave   draft · drawdown · wif · calc · validate   │
│    ply-common  color · yarn · units · craft kind          │
│  (future: ply-knit, ply-nalbind as siblings)            │
└───────────────────────────────────────────────────────────┘
```

The rule that makes this work: **dependencies only point downward, and frb only exists in
`ply-bridge`.** The engine never knows it's being driven by Flutter. That's what keeps it
reusable (a CLI, a desktop app, a server-side draft generator, fuzz harnesses) and what
lets you develop and test the hard logic in plain `cargo test` with a fast inner loop.

## Why a Rust core (for this project specifically)

- The maintainer's comfort language is Rust, so the usual "Rust is harder" cost mostly
  evaporates; the real cost is the FFI/toolchain glue, which is front-loaded and one-time.
- Weave structures model cleanly as sum types with exhaustive matching, killing whole bug
  classes at compile time.
- **Weaving's schema is fixed by WIF**, so the one genuine risk of starting in Rust —
  data-model churn thrashing across the FFI boundary — is minimized. Lock the WIF-shaped
  model, wire the bridge once, iterate.

## Render pipeline (live preview)

1. UI has a `Draft` (imported from WIF or edited in-app).
2. UI calls `render_preview(draft, cell_px)` **once** per change.
3. `ply-weave::compute` builds the drawdown (over/under grid); `render_rgba` paints it to
   a flat RGBA8 buffer (pick 0 at the bottom; the buffer is top-to-bottom for image
   conventions).
4. The bridge returns `{width, height, rgba}`. Dart decodes it into a `ui.Image` and a
   `CustomPainter` blits it.

Recompute is microseconds for normal drafts, so "recompute the whole thing on every edit"
is the correct, simple strategy. Do **not** try to call the engine per cell — see
`FFI_BOUNDARY.md`.

For the editor grid itself (threading/tie-up/treadling cells), paint in Flutter with
`CustomPainter` + `RepaintBoundary`. Rendering lives in Flutter regardless of core
language, so grid-paint discipline (not Rust) is where preview perf is won or lost.

## Persistence (local-first, no backend)

- **Patterns are files.** A weaving draft saves as a real `.wif` — the native, portable,
  interoperable format. No proprietary container.
- **App metadata** (project name, author, free-form notes, last-opened) saves as a small
  JSON sidecar next to the `.wif` (`ply_common::ProjectMeta`), or in an app index.
- This keeps user data portable and private, and means "export" is mostly free.

## State management

Riverpod is the suggested choice (testable, no `BuildContext` coupling, plays well with
async bridge calls). Not load-bearing — any solution works. Keep engine calls behind a thin
repository/service layer so the UI never imports generated symbols directly.

## Where knitting & nalbinding slot in

Each is a new sibling engine crate (`ply-knit`, `ply-nalbind`) depending on
`ply-common`, exposed through additional `ply-bridge` calls. The shared shell —
library, persistence, calculators pattern, glossary — is reused; only the craft-specific
model + editor differ. Knitting needs a custom schema (no interchange standard);
nalbinding uses Hansen notation over a worked-in-spiral structure. See `DATA_MODEL.md`.
