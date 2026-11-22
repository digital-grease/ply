# Ply

A local-first pattern tool for **weaving, tablet weaving, knitting, and nalbinding**. Create,
modify, store, and preview fiber-craft patterns, then follow them as you make them. No backend,
no accounts; patterns live as files on your device.

Every craft is usable today. Weaving is the most complete (a full draft editor with WIF
import/export). Knitting has a chart editor with live written instructions and sections for
shaped pieces. Tablet weaving has a card editor with a band preview. Nalbinding has a stitch
reference, a notation playground and step-by-step project recipes.

> **Name:** *Ply*, as in twisting strands together, and "to ply a craft." Fiber-universal,
> not locked to weaving.

## Why this shape

- **Rust engine + Flutter UI**, joined by [`flutter_rust_bridge`](https://github.com/fzyzcjy/flutter_rust_bridge).
  The engines are pure Rust: deterministic pattern math that's a joy to test and fuzz, and
  reusable beyond the app (CLI, batch tooling, a future desktop companion).
- **WIF-native weaving.** Ply reads and writes [WIF](docs/WIF_MAPPING.md), the universal
  weaving interchange format, so it interoperates with existing software, computerized
  looms, and the large body of public drafts.
- **One engine per craft.** Each craft is its own crate behind a shared shell, so adding a
  craft doesn't disturb the others.

## Layout

| Path | What |
|---|---|
| `rust/ply-common`  | Shared pure types (color, yarn, units, craft kind, materials, readiness, progress) |
| `rust/ply-weave`   | Weaving engine: draft model, drawdown, WIF I/O, calculators, validation |
| `rust/ply-knit`    | Knitting engine: chart model, stitch legend, written instructions, sections, validation, render |
| `rust/ply-nalbind` | Nalbinding engine: Hansen stitch grammar, stitch reference, loop diagram, recipes |
| `rust/ply-tablet`  | Tablet weaving engine: cards, turning, band simulation |
| `rust/ply-crochet` | Crochet engine: stitches, rows and rounds, counts (not in the app yet) |
| `rust/ply-bridge`  | The only FFI crate; a thin surface over the engines for Flutter |
| `app/`             | Flutter app (UI) |
| `docs/`            | Architecture, data model, WIF mapping, FFI rules, glossary |

## Quickstart

```bash
# 1. Verify the engines (no Flutter toolchain required):
cd rust
cargo test --workspace                           # every engine crate plus the bridge

# 2. Generate the Dart<->Rust bindings, then the Dart code generated from them:
cargo install flutter_rust_bridge_codegen        # if not already installed
cd ..
flutter_rust_bridge_codegen generate             # reads flutter_rust_bridge.yaml
cd app
flutter pub get
dart run build_runner build --delete-conflicting-outputs

# 3. Run the app (needs Flutter + platform toolchains; see frb's setup docs):
flutter run
```

## Status

Ply is a working, multi-craft app, released as test builds. See the
[Releases](https://github.com/digital-grease/ply/releases) page for signed Android APKs.

- **Weaving:** a full draft editor (threading, tie-up, treadling, live drawdown with zoom and
  pan), structure generators, a Book view, double weave, shuttles and pick roles, loom profiles
  with a check that a draft fits your loom, warp and weft plans from the finished size,
  calculators, validation, and WIF import/export.
- **Knitting:** a chart editor with colorwork, a stitch key, live written instructions with
  repeats, validation, and optional sections for shaped pieces (short rows, held stitches, sock
  heels and gussets, pick-ups, several pieces joined), with a running stitch count.
- **Tablet weaving:** a card editor with threading and turning, a turn-by-turn stepper, and a
  band preview.
- **Nalbinding:** a stitch reference and per-stitch visualizer, a notation playground with a
  loop diagram, and projects with notes, photos and a step-by-step recipe.
- **Follow along:** every craft keeps your place as you work (pick by pick, row by row, or step
  by step), and the library shows where you left off.
- **Shared:** an on-device library, materials and swatch records, a check that a pattern is
  ready to make or share, printable PDFs, backup and restore of the whole library, light and
  dark plus Material You theming, an in-app glossary and help, and on-device crash reporting
  and log export.

The engines are pure Rust with extensive tests (drawdown golden rasters, WIF round-trips,
property tests). See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the architecture and
`ROADMAP.md` for what is next.

## License

Licensed under the [GNU Affero General Public License v3.0](LICENSE) (AGPL-3.0). In short: you're
free to use, study, modify, and share Ply, but derivative works, including ones offered over a
network, must be released under the same license with their source available.

Copyright (C) 2026 digital-grease
