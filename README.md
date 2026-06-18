# Ply

A local-first pattern tool for **weaving, knitting, and nalbinding**. Create, modify,
store, and preview fiber-craft patterns on Android and iOS. No backend, no accounts;
patterns live as files on your device.

All three crafts are usable today. Weaving is the most complete (a full draft editor with
WIF import/export). Knitting has a chart editor with live written instructions, validation,
colorwork, and calculators. Nalbinding ships a stitch reference and per-stitch visualizer
with project notes.

> **Name:** *Ply* — twisting strands together, and "to ply a craft." Fiber-universal,
> not locked to weaving. (App bundle IDs are set when you run `flutter create .`.)

## Why this shape

- **Rust engine + Flutter UI**, joined by [`flutter_rust_bridge`](https://github.com/fzyzcjy/flutter_rust_bridge).
  The weaving engine is pure Rust — deterministic interlacement math that's a joy to test
  and fuzz, and reusable beyond the app (CLI, batch tooling, a future desktop companion).
- **WIF-native weaving.** Ply reads and writes [WIF](docs/WIF_MAPPING.md), the universal
  weaving interchange format, so it interoperates with existing software, computerized
  looms, and the large body of public drafts.
- **One engine per craft.** Each craft is its own crate behind a shared shell, so adding
  knitting or nalbinding doesn't disturb weaving.

## Layout

| Path | What |
|---|---|
| `rust/ply-common`  | Shared pure types (color, yarn, units, craft kind) |
| `rust/ply-weave`   | Weaving engine: draft model, drawdown, WIF I/O, calculators, validation |
| `rust/ply-knit`    | Knitting engine: chart model, stitch legend, written instructions, validation, render |
| `rust/ply-nalbind` | Nalbinding engine: Hansen stitch grammar, stitch reference and visualization |
| `rust/ply-bridge`  | The only FFI crate; a thin surface over the engines for Flutter |
| `app/`             | Flutter app (UI) |
| `docs/`            | Architecture, data model, WIF mapping, FFI rules, glossary |

## Quickstart

```bash
# 1. Verify the engines (no Flutter toolchain required):
cd rust
cargo test                                       # all crates: weave, knit, nalbind, common, bridge

# 2. Generate the Dart<->Rust bindings:
cargo install flutter_rust_bridge_codegen        # if not already installed
flutter_rust_bridge_codegen generate             # reads flutter_rust_bridge.yaml

# 3. Run the app (needs Flutter + platform toolchains; see frb's setup docs):
cd ../app
flutter pub get
flutter run
```

## Status

Ply is a working, multi-craft app, released as test builds. See the
[Releases](https://github.com/digital-grease/ply/releases) page for signed Android APKs.

- **Weaving:** a full draft editor (threading, tie-up, treadling, live drawdown with zoom and
  pan), loom types, a double-weave layer view, planning calculators (sett, warp and weft
  yardage), validation, and WIF import/export.
- **Knitting:** a chart editor with colorwork, a stitch key, live written instructions and
  validation, row and stitch numbering, a fill-a-region tool, and standalone calculators.
- **Nalbinding:** a stitch reference and per-stitch visualizer with project notes.
- **Shared:** an on-device pattern library, light and dark plus Material You theming, an in-app
  glossary, and on-device crash reporting and log export.

The engines are pure Rust with extensive tests (drawdown golden rasters, WIF round-trips,
property tests). See `CLAUDE.md` for the architecture and `ROADMAP.md` for what is next.

## License

Licensed under the [GNU Affero General Public License v3.0](LICENSE) (AGPL-3.0). In short: you're
free to use, study, modify, and share Ply, but derivative works — including ones offered over a
network — must be released under the same license with their source available.

Copyright (C) 2026 digital-grease
