# Ply

A local-first pattern tool for **weaving, knitting, and nalbinding** — create, modify,
store, and preview fiber-craft patterns on Android and iOS. No backend, no accounts;
patterns live as files on your device.

Weaving ships first. Knitting and nalbinding are designed-for but not yet built.

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
| `rust/ply-common` | Shared pure types (color, yarn, units, craft kind) |
| `rust/ply-weave`  | Weaving engine: draft model, drawdown, WIF I/O, calculators, validation |
| `rust/ply-bridge` | The only FFI crate; thin surface over the engine for Flutter |
| `app/`              | Flutter app (UI) |
| `docs/`             | Architecture, data model, WIF mapping, FFI rules, glossary |

## Quickstart

```bash
# 1. Verify the engine (no Flutter toolchain required):
cd rust
cargo test -p ply-common -p ply-weave        # 9 tests, all green

# 2. Generate the Dart<->Rust bindings:
cargo install flutter_rust_bridge_codegen        # if not already installed
flutter_rust_bridge_codegen generate             # reads flutter_rust_bridge.yaml

# 3. Run the app (needs Flutter + platform toolchains; see frb's setup docs):
cd ../app
flutter pub get
flutter run
```

## Status

The **weaving engine is real and tested** (drawdown, RGBA preview render, sett and
warp/yarn calculators, draft validation, WIF import/export). The **bridge compiles**
against frb v2. The **Flutter app is a skeleton** to be wired after codegen. See
`CLAUDE.md` for the build-vs-stub breakdown and `ROADMAP.md` for what's next.

## License

Licensed under the [GNU Affero General Public License v3.0](LICENSE) (AGPL-3.0). In short: you're
free to use, study, modify, and share Ply, but derivative works — including ones offered over a
network — must be released under the same license with their source available.

Copyright (C) 2026 digital-grease
