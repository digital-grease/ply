# Weaving glossary

Reference terms for the engine, the docs, and the in-app glossary/tutorials (M4). Kept
plain so it can double as user-facing help content.

- **Warp** — the threads held under tension on the loom, running the length of the cloth.
- **Weft** (filling/pick) — the thread carried across the warp, running the width.
- **End** — a single warp thread. "200 ends" = 200 warp threads across.
- **Pick** — a single pass of weft; one row of the cloth.
- **Shaft** (harness) — a frame that raises/lowers a group of warp ends. More shafts = more
  possible structures. Numbered from 1.
- **Heddle** — a wire/cord on a shaft with an eye; each warp end passes through one,
  so lifting the shaft lifts those ends.
- **Treadle** — a foot pedal. Pressing it raises (or lowers) the shafts tied to it.
- **Tie-up** — which shafts each treadle controls. A grid of treadles × shafts.
- **Threading** (draft-in) — the order in which warp ends are assigned to shafts.
- **Treadling** — the sequence of treadles pressed, pick by pick.
- **Liftplan** — directly specifies which shafts rise on each pick, bypassing the tie-up;
  used by table looms and dobby looms. A draft uses a tie-up+treadling *or* a liftplan.
- **Shed** — the opening between raised and lowered warp ends that the weft passes through.
- **Rising shed / sinking shed** — whether the loom *raises* or *lowers* the shafts named in
  the tie-up. Determines how the tie-up is interpreted (see `DATA_MODEL.md`).
- **Draft** — the complete specification of a woven structure (threading + tie-up +
  treadling/liftplan + color). Also the file you save.
- **Drawdown** — the computed picture of the cloth: for each intersection, whether warp or
  weft is on top. Ply computes this from the draft.
- **Float** — a length of thread passing over two or more perpendicular threads without
  interlacing (e.g. the long floats of satin).
- **Sett** — how densely the warp is spaced, in **ends per inch (EPI)** / ends per
  centimeter. The weft analogue is **picks per inch (PPI)**.
- **WPI (wraps per inch)** — wraps of a yarn that fit in an inch; used to estimate a
  suitable sett.
- **Sley / sleying** — threading the warp through the reed; the reed sets the sett.
- **Beat** — pressing each pick into place against the cloth (the "fell").
- **Selvedge** (selvage) — the self-finished lengthwise edge of the cloth.
- **Take-up** — warp/weft shortening from interlacing (cloth is shorter/narrower than the
  yarn measured straight); budgeted in yarn estimates alongside shrinkage.
- **Loom waste** — warp that can't be woven (tie-on, thrums); a fixed allowance per warp.

### Structures (families)
- **Plain weave / tabby** — over-one/under-one; maximum interlacement, most stable.
- **Twill** — diagonal lines from offset floats (denim is a twill).
- **Satin / sateen** — long floats, smooth lustrous face, densest sett.

### Other crafts (for later engines)
- **Gauge** (knitting) — stitches and rows per unit; knitting's sett analogue.
- **Hansen notation** (nalbinding) — `U`/`O` (under/over) stitch encoding with connection
  markers; the basis for the future nalbinding model.
