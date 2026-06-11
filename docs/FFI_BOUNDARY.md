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

The M2 editor speaks the transparent `DraftDto` (see "DTO vs. direct types" above): a plain
mirrored value the editor can hold and pass to render/validate/write repeatedly, with no
single-use trap. Base conversions (1-based ids ↔ `u16`, 0-based color index ↔ `u32`) happen
only in `dto.rs`.

| Function | Purpose |
|---|---|
| `parse_wif_dto(text) -> Result<DraftDto, String>` | Import a WIF document into the editor DTO |
| `write_wif(dto) -> Result<String, String>` | Export the editor DTO to WIF (lossy header — see `WIF_MAPPING.md`) |
| `render_preview_dto(dto, cell_px) -> Result<PreviewImage, String>` | Whole-cloth RGBA buffer for live preview |
| `validate_draft(dto) -> Result<Vec<ValidationIssueDto>, String>` | Structural issues with `SeverityKind` (empty = clean) |
| `blank_draft(shafts, treadles) -> DraftDto` | A blank, valid draft to start editing |
| `to_liftplan_dto(dto) -> Result<DraftDto, String>` | Canonical Treadled→Liftplan conversion (drawdown unchanged) |
| `suggest_sett(wpi, structure) -> f32` | Sett (EPI) suggestion |
| `estimate_warp(plan) -> YarnEstimate` | Warp length + yarn estimate |
| `estimate_weft(plan) -> WeftEstimate` | Weft yarn estimate |

**Transitional (M1, opaque `Draft`):** `parse_wif(text) -> Result<Draft, String>` and
`render_preview(draft, cell_px) -> PreviewImage` remain only until `DraftRepository` migrates
to the DTO render path (plan Phase 2.3); they hand back the opaque, single-use `Draft` handle
the DTO surface replaces. Do not build new callers on them.

Add knitting/nalbinding entry points here as those engines come online.
