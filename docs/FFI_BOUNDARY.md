# The FFI boundary

`ply-bridge` is the membrane between Flutter and the Rust engine. Treat it as a
deliberate API, not an afterthought — a sloppy boundary is the one way a Rust core can end
up *slower* than pure Dart.

## Rules

1. **Coarse-grained calls only.** One call does a meaningful unit of work and returns a
   whole result. The canonical example: `render_preview` returns an entire RGBA buffer in
   one shot. **Never** expose a per-cell call like `cell_at(end, pick)` — crossing the FFI
   boundary tens of thousands of times per frame is the classic way to make this stack
   crawl.
2. **The engine stays frb-free.** Only `ply-bridge` imports `flutter_rust_bridge`. If an
   engine type is awkward to send across, add a thin DTO in the bridge and convert — do not
   put frb attributes on engine types (that would make the engine depend on frb and lose
   its reusability).
3. **Errors cross as messages.** Engine `Result<_, WeaveError>` maps to `Result<_, String>`
   (or a small bridge error enum) so the UI can show something useful.
4. **Buffers, not objects, for hot paths.** Pixels go across as `Vec<u8>` (frb hands large
   byte arrays efficiently). Decode on the Dart side.

## DTO vs. direct types

For v1, `ply-weave` types (`Draft`, etc.) are sent across directly where frb can mirror
them, to avoid premature boilerplate. Introduce a bridge DTO when:

- an engine type doesn't map cleanly (lifetimes, non-serializable internals), or
- the UI wants a different shape than the engine's (e.g. a flattened preview struct —
  `PreviewImage` already does this), or
- you want to decouple the wire format from an engine refactor.

When you add a DTO, keep the conversion (`From`/`Into`) in the bridge crate.

## Codegen workflow

The Dart bindings are **generated**, not hand-written:

```bash
flutter_rust_bridge_codegen generate   # reads flutter_rust_bridge.yaml
# Data-carrying enum DTOs (e.g. DriveDto) are emitted as freezed sealed classes, so also:
cd app && dart run build_runner build --delete-conflicting-outputs
```

This reads `crate::api` from `rust/ply-bridge`, emits Dart into `app/lib/src/rust`, and
(re)creates `rust/ply-bridge/src/frb_generated.rs`. Both generated locations are
git-ignored; regenerate after every change to `api.rs`. Don't edit generated files by hand.

A Rust **enum with associated data** (sum type) mirrors to Dart as a `freezed` sealed class
(`part '<mod>.freezed.dart'`), so frb codegen requires `freezed`/`build_runner` in the app
and a `build_runner build` pass to emit the `*.freezed.dart` part — without it the app won't
compile. Fieldless enums (e.g. `ShedKind`) become plain Dart enums and need neither.

## Current surface (`ply-bridge/src/api.rs`)

| Function | Purpose |
|---|---|
| `parse_wif(text) -> Result<Draft, String>` | Import a WIF document |
| `write_wif(draft) -> String` | Export to WIF |
| `render_preview(draft, cell_px) -> PreviewImage` | Whole-cloth RGBA buffer for live preview |
| `validate_draft(draft) -> Vec<String>` | Structural issues (empty = clean) |
| `suggest_sett(wpi, structure) -> f32` | Sett (EPI) suggestion |

Add knitting/nalbinding entry points here as those engines come online.
