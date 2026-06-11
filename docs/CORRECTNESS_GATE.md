# Correctness gate — weaving drawdown

Drawdown correctness is pinned in two layers: a cheap deterministic one in Rust, and a
visual one on-device. The phone step is *confirmation*, not the proof — it displays the
exact buffer the Rust test already pins.

## 1. Deterministic, host-only (Rust golden tests)

`rust/ply-weave/tests/golden_render.rs` parses two committed fixtures, computes the
drawdown, and asserts exact RGBA pixels from `render_rgba` — including the vertical-flip
**orientation** (pick 0 at the bottom row).

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
  TOP** (pick 0 at the bottom).
- `plain_2x2.wif` → a clean black/white checkerboard.

## Orientation contract (do not "fix")

`PreviewImage.rgba` is RGBA8, row-major, **top-to-bottom**. `render_rgba`
(`ply-weave/src/drawdown.rs`) already applies the vertical flip so pick 0 is the bottom
row. The Dart side must **not** flip again — `decodeImageFromPixels` decodes width×height
as-is and the painter does not flip the canvas.

## Status

✅ **PASSED 2026-06-10** on `emulator-5554` (Android 16, API 36, x86_64): both fixtures
render correctly (interlacement + orientation). Engine golden tests green.
