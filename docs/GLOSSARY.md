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

### Knitting
- **Knit** (k) — the basic stitch; a new loop pulled through to the back, making a flat "V" on
  the right side.
- **Purl** (p) — the reverse of a knit, the loop drawn through to the front, making a horizontal
  bump.
- **Gauge** (tension) — stitches and rows per 4 in / 10 cm; knitting's sett analogue, and what
  decides the finished size.
- **Right side / wrong side** (RS/WS) — the face meant to show (RS) versus the back (WS); on a
  flat piece the rows alternate between them.
- **Cast on** — the foundation row that puts the first loops on the needle.
- **Bind off** (cast off) — securing the last loops so the work won't unravel.
- **Stockinette** (stocking stitch) — knit on right-side rows, purl on wrong-side rows; a smooth
  field of "V"s that curls at the edges.
- **Garter** — knit every row; a reversible, ridged fabric that lies flat.
- **Yarn over** (yo) — wrapping the yarn to add a stitch and leave a deliberate hole, the basis of
  lace.
- **k2tog / ssk** — paired decreases that each turn two stitches into one, leaning right (k2tog) or
  left (ssk).
- **Chart** — a grid where each cell is one stitch, read bottom to top; right-side rows read right
  to left, wrong-side rows left to right.
- **Repeat** — a block of stitches or rows worked over and over across a row or up the piece.
- **Cable** — stitches crossed over their neighbours (held on a cable needle) to make a rope-like
  twist.
- **In the round** — worked as a tube on circular or double-pointed needles, so every round faces
  the right side.

### Nalbinding
- **Nalbinding** (nålbinding) — an ancient single-needle looping craft, worked in a spiral with
  short lengths of yarn; predates knitting and crochet, and does not unravel when cut.
- **Hansen notation** — the standard encoding of a nalbinding stitch: a string of `U` (needle
  under a loop) and `O` (over), with `/` marking the turn where the thread reverses, plus a
  connection. E.g. the Oslo stitch is `UO/UOO F1`.
- **Connection** (F/B) — how a new loop anchors into the previous round: `F` enters from the
  front, `B` from the back, and the number is how many loops it engages (`F2` = one new + one old).
- **Thumb loop** — a loop held around the thumb while forming the next stitch; the `a+b` count
  (Oslo = 1+1, Mammen = 1+2) names a stitch by its thumb-loop groups.
- **Spiral** — nalbinding has no rows; it climbs continuously in a spiral, leaving a visible
  "step" where one round meets the next.
- **Increase / decrease** — shaping by eye: an increase works two stitches into one connection
  point, a decrease skips a loop, judged by the thumb-loop angle to the centre.
