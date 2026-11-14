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
- **Book draft**: a draft printed as four parts that share their rows and columns: the threading,
  the tie-up, the treadling (or a liftplan) and the drawdown. Books put the tie-up in different
  corners and number from different sides, so a printed draft from Ply says where end 1, shaft 1,
  treadle 1 and pick 1 are.
- **Use tabby**: the traditional shorthand of an overshot draft. The treadling lists only the
  pattern picks, and one instruction says to weave a tabby (plain-weave) pick after each, changing
  between the two tabby sheds. Ply uses it only when the picks' roles make it give exactly the
  draft's picks.
- **Float** — a length of thread passing over two or more perpendicular threads without
  interlacing (e.g. the long floats of satin).
- **Sett** — how densely the warp is spaced, in **ends per inch (EPI)** / ends per
  centimeter. The weft analogue is **picks per inch (PPI)**.
- **WPI (wraps per inch)** — wraps of a yarn that fit in an inch; used to estimate a
  suitable sett.
- **Sley / sleying** — threading the warp through the reed; the reed sets the sett.
- **Beat** — pressing each pick into place against the cloth (the "fell").
- **Selvedge** (selvage) — the self-finished lengthwise edge of the cloth.
- **Floating selvedge**: an extra warp end at each edge, sleyed in the reed but not threaded through
  a heddle, so no shaft moves it. Taking the shuttle over it going in and under it coming out (or the
  reverse) catches the weft at the edge when the shed alone would not, as on a double shot.
- **Shuttle**: the tool that carries a weft across the warp. A draft with several wefts uses several
  shuttles, and each one changes direction on every pass, so the direction of a pick follows from
  its shuttle.
- **Double shot**: two passes of the weft in one shed, without changing the shed between them (a
  triple shot is three). It is not double weave, and not two strands carried together in one pass.
- **Take-up** — warp/weft shortening from interlacing (cloth is shorter/narrower than the
  yarn measured straight); budgeted in yarn estimates alongside shrinkage.
- **Loom waste** — warp that can't be woven (tie-on, thrums); a fixed allowance per warp.

### Structures (families)
- **Plain weave / tabby** — over-one/under-one; maximum interlacement, most stable.
- **Twill** — diagonal lines from offset floats (denim is a twill).
- **Satin / sateen** — long floats, smooth lustrous face, densest sett.
- **Shadow weave**: a block weave in which warp and weft both alternate dark and light threads one
  by one, and each dark end has a light "shadow" end beside it on a partner shaft. Inside each block
  the cloth is plain weave with fine horizontal or vertical lines; the only floats are two-thread
  skips where blocks meet. Unlike log cabin, the pattern comes from the threading, not the color
  order. The Atwater and Powell systems number the shafts differently but weave the same cloth.

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
- **Short row**: a row turned before it reaches the end of the needle. The stitches past the turn
  stay on the needle unworked, so the part that is worked gains rows; short rows slope shoulders,
  shape darts and turn heels.
- **German short row**: a way to turn a short row: turn, slip the first stitch with the yarn in
  front, and pull the yarn over the needle, which makes a double stitch. A later row works it as one
  stitch.
- **Double stitch** (DS): the stitch a German short row pulls up at its turn, so it looks like two.
  It counts as one stitch, and a later row works both legs together as one.
- **Held stitches** (on hold): live stitches moved off the needle onto a stitch holder or waste
  yarn, to be worked later, such as the center of a neckline. Returning them puts them back on the
  needle, and the pattern says which side faces you.
- **Section**: in Ply, a named part of a pattern's construction (such as Back or Left shoulder),
  with its steps in order. Ply counts the stitches on the needle, on hold and bound off after every
  step.

### Knitting abbreviations
- **Beginning** (beg) — the start of a row or round.
- **Decrease** (dec) — working stitches together to reduce the stitch count.
- **Increase** (inc) — adding a stitch to widen the work.
- **Double-pointed needles** (DPN) — short needles pointed at both ends, for knitting small tubes in the round.
- **Follow** (foll) — work as the named row, round, or chart directs.
- **Knitwise** (kwise) — insert the needle as if to knit.
- **Purlwise** (pwise) — insert the needle as if to purl.
- **Through the back loop** (tbl) — work into the back of the loop instead of the front, twisting the stitch.
- **Together** (tog) — work the named stitches as one, as in k2tog (knit two together).
- **Knit front and back** (kfb) — knit into the front then the back of one stitch, an increase of one.
- **Knit back and front** (kbf) — knit into the back then the front of one stitch, the mirror of kfb.
- **Knit three together** (k3tog) — a right-leaning double decrease, three stitches become one.
- **Make one** (M1) — lift the strand between two stitches and work it to add a stitch.
- **Make one left** (M1L) — a left-leaning lifted increase.
- **Make one right** (M1R) — a right-leaning lifted increase.
- **Make one purlwise** (M1P) — a lifted increase worked as a purl.
- **Purl front and back** (pfb) — purl into the front then the back of one stitch, an increase of one.
- **Purl two together** (p2tog) — a decrease worked from the purl side, two stitches become one.
- **Slip** (sl) — move a stitch to the other needle without working it.
- **Slip slip purl** (ssp) — a left-leaning purl-side decrease, two stitches become one.
- **Slip, knit 2 together, pass over** (sk2po) — slip one, knit two together, pass the slipped stitch over, a double decrease.
- **Slip 2, knit, pass over** (s2kpo) — slip two together knitwise, knit one, pass the two slipped over, a centered double decrease (the cdd in the chart).
- **Stitch** (st) — one loop on the needle; the plural is sts.
- **Remaining** (rem) — the stitches left on the needle.
- **Pattern** (patt) — the established stitch sequence to repeat.
- **Place marker** (PM) — slip a marker onto the needle to flag a position.
- **Slip marker** (SM) — move the marker across as you reach it, working on.
- **Reverse stockinette** (rev St st) — purl on right-side rows and knit on wrong-side rows, the bumpy face of stockinette.
- **With yarn in back** (wyib) — hold the working yarn behind the work, often while slipping a stitch.
- **With yarn in front** (wyif) — hold the working yarn in front of the work.
- **Wrap and turn** (w&t): wrap the next stitch and turn mid-row to work a short row; a later row
  works the wrap together with its stitch.
- **Left hand / right hand** (LH/RH) — which needle or hand a step refers to.

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
