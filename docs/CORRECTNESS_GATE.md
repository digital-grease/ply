# Correctness gate — weaving drawdown

Drawdown correctness is pinned in two layers: a cheap deterministic one in Rust, and a
visual one on-device. The phone step is *confirmation*, not the proof — it displays the
exact buffer the Rust test already pins.

## 1. Deterministic, host-only (Rust golden tests)

`rust/ply-weave/tests/golden_render.rs` parses two committed fixtures, computes the
drawdown, and asserts exact RGBA pixels from `render_rgba`, including the **orientation**:
end 1 at the right, pick 1 at the top (the conventional draft orientation, since `1d35503`).

```bash
cd rust && cargo test -p ply-weave        # includes the golden_render tests
```

Fixtures (`rust/ply-weave/tests/fixtures/`, original content, black warp / white weft):
- **`plain_2x2.wif`** — 2-shaft plain weave → a 2×2 checkerboard.
- **`twill_2_2.wif`** — 4-shaft 2/2 twill → an ascending diagonal.

The twill is the orientation oracle: its diagonal direction is only correct one way, so it
catches both interlacement *and* flip bugs that a symmetric plain weave would hide.

## 2. On-device visual acceptance (M1 exit criterion)

The Dart path (`renderPreview` → `decodeImageFromPixels` → `DrawdownPainter`) draws the
same buffer the golden test pins, so a visual match is sufficient.

```bash
adb push rust/ply-weave/tests/fixtures/twill_2_2.wif /sdcard/Download/
adb push rust/ply-weave/tests/fixtures/plain_2x2.wif /sdcard/Download/
cd app && flutter run -d <device>
```

In the app: tap **Import pattern** → **Downloads** → pick the file.

**Acceptance:**
- `twill_2_2.wif` → a 2/2 twill whose black diagonal **ascends left-to-right toward the
  TOP** (pick 1 at the top, end 1 at the right; the 180° turn keeps the diagonal's direction).
- `plain_2x2.wif` → a clean black/white checkerboard.

## Orientation contract (do not "fix")

`PreviewImage.rgba` is RGBA8, row-major, **top-to-bottom**. `render_rgba`
(`ply-weave/src/drawdown.rs`) builds the buffer in natural raster order (end 0 left, pick 0
bottom) and turns it 180° as its last step, so the output has **end 1 at the right and pick 1
at the top**. The editor grids use matching right/top origins. The Dart side must **not** flip
again: `decodeImageFromPixels` decodes width×height as-is and the painter does not flip the
canvas.

## Status

✅ **PASSED 2026-06-10** on `emulator-5554` (Android 16, API 36, x86_64): both fixtures
render correctly (interlacement + orientation). Engine golden tests green.

That device pass predates the orientation change in `1d35503` (2026-06-17). The host goldens were
updated with that change and pass at `1cb0612`; the device check has not been re-recorded here.
