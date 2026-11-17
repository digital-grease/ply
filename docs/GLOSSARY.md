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

### Looms and reeds
- **Jack loom**: a floor loom whose treadles raise the shafts tied to them while the other shafts
  stay down. It weaves a tie-up written for a rising shed.
- **Counterbalance loom**: a floor loom whose shafts hang from rollers or pulleys, linked to each
  other, so every treadle moves every shaft: the tied shafts sink and the rest rise. It weaves a
  tie-up written for a sinking shed, and works best when each shed raises as many shafts as it
  lowers (a balanced shed).
- **Countermarch loom**: a floor loom with two sets of lamms, one that raises shafts and one that
  lowers them, so every shaft is tied up or down on each treadle. It weaves a tie-up written either
  way.
- **Table loom**: a smaller loom worked by hand levers, usually one for each shaft, set for each
  pick instead of pressing treadles. It follows a liftplan.
- **Dobby loom**: a loom that selects the shafts for each pick itself, with pegs on bars or a
  computer, following a liftplan. It suits drafts with many shafts.
- **Lamm**: a bar between the treadles and the shafts that carries the tie-up cords.
- **Skeleton tie-up**: a tie-up for more sheds than the loom has treadles, where some picks press
  two treadles at once, one with each foot.
- **Reed**: the comb-like frame in the beater that spaces the warp ends and beats the weft into
  place. It is sized by its dents per inch, or per 10 cm for a metric reed (a 40/10 reed has 40
  dents in 10 cm).
- **Dent**: one space between the wires of a reed. One or more ends go in each dent; the dents per
  inch times the ends in each dent is the sett.
- **Sleying order**: how many ends go in each dent, repeated across the warp, such as 2, 1, 1 for 16
  ends per inch in a 12-dent reed.
- **Weaving width** (width in the reed): how wide the warp is in the reed, its ends divided by its
  sett. A loom's weaving width is the widest warp it takes. A double-width cloth is woven folded, so
  it is about half as wide in the reed as it is opened out.
- **Loom profile**: in Ply, a loom you describe in My looms (its type, shafts, treadles, weaving
  width and reeds), so a draft can be checked against it.

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
- **Join in the round**: bring the two ends of the knitting together so it goes on around as a tube
  instead of turning; after a cast-on, take care not to twist the stitches.
- **Heel flap**: in a sock knitted from the cuff down, a flap worked back and forth over the heel
  stitches while the instep stitches wait. Slipping the first stitch of every row makes a chain of
  edge stitches, one for every two rows, to pick up the gusset from.
- **Heel turn** (turning the heel): short rows across the bottom of the heel flap that cup the
  heel. Each row works to the gap, decreases across it, works a stitch or so more and turns, until
  every heel stitch is worked.
- **Gap** (in short rows): the place where an earlier short row on the same side turned, between the
  stitches it worked and the ones it left. A heel turn works to it and decreases across it.
- **Gusset**: the stitches picked up along the sides of a heel flap, then decreased every other
  round until the sock is back to its stitch count, which shapes the foot below the ankle.
- **Instep**: the top of the foot. In a sock, the stitches that wait while the heel is worked.
- **Pick up and knit**: draw new loops through an edge of the knitting, such as the slipped stitches
  along a heel flap, and knit them, adding stitches to the needle. The pattern says how many to pick
  up, often one for each slipped edge stitch and an extra one at a corner.
- **Short-row heel**: a sock heel worked back and forth over half the stitches with short rows, each
  row shorter and then longer again, with no flap or gusset; the wraps or double stitches are worked
  as the rows grow, and the knitting goes back to rounds.
- **Kitchener stitch** (grafting): sewing two needles of live stitches together with a tapestry
  needle, so the join looks like a row of knitting. It closes a sock toe.
- **Three-needle bind-off**: binding off the stitches of two needles together, with the right sides
  facing each other and a third needle, which joins two pieces such as shoulders.
- **Needle group**: in Ply, a named group of the stitches on the needle, such as the instep and the
  sole, so the count after each step gives each group.
- **Start of the round** (beginning of round): the point where each round begins, usually kept with
  a marker. Sock patterns often move it, for example to the center of the heel after picking up the
  gusset stitches.
- **Piece**: in Ply, a part of a garment knitted on its own needle, such as the body, a sleeve or a
  thumb. Each section works one piece; the first piece is the one the cast-on is for.
- **Join pieces**: knit the stitches of one piece onto the needle of another, so they go on as one,
  such as sleeves knitted onto the body for a yoke. In Ply a join step knits another piece, or
  stitches on hold, into the row or round where the work is, with the right side facing.
- **Set aside**: in Ply, the stitches of the pieces not being worked, waiting on their own needles or
  holders until a section works them or a join brings them in. Every count lists them.
- **Yoke**: the upper part of a sweater that joins the body and the sleeves and narrows toward the
  neck. In a bottom-up yoke the body and the sleeves are knitted to the underarms and then joined on
  one needle.
- **Raglan**: a sweater whose sleeves meet the body along diagonal lines from the underarm to the
  neck. A top-down raglan divides its yoke at the underarms into the body and the two sleeves.
- **Underarm stitches**: stitches put on hold or bound off where a sleeve meets the body, later
  grafted or bound off together to close the underarm.
- **Held-stitch thumb**: a mitten thumb whose stitches go on a holder while the hand goes on, with
  stitches cast on over the gap; the thumb is knitted later from the held stitches plus stitches
  picked up along the opening.
- **Afterthought thumb**: a mitten thumb placed by knitting a few stitches with waste yarn; later the
  waste yarn is pulled out and the live stitches above and below it are picked up for the thumb.

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

### Materials and swatches
- **Swatch** (sample): a small piece worked in the yarn, stitch, tools and tension of a project, then
  measured before and after it is finished the way the project will be, to find the gauge (or sett
  and picks) and how much the fabric changes. In Ply, a swatch record can be linked to any number of
  projects, and the planning calculators can take their numbers from it.
- **Material**: in Ply, a yarn or thread you describe in Materials and swatches: its fibers, weight
  category, structure, length per mass, wraps per inch, color, dye lot and how much you have. Every
  field is optional.
- **Length per mass** (yardage, grist): how much yarn a weight of it holds, as on a ball band ("200 m
  per 100 g"). Weavers often give it as yards per pound (YPP). Weigh a measured length to find your
  own.
- **Dye lot**: the batch a yarn was dyed in, printed on the label. Skeins from one lot match; another
  lot of the same color may not.
- **Fiber blend**: the fibers a yarn is spun from, with their share by weight, as the label gives
  them ("80% wool, 20% nylon").
- **Finishing** (wet finishing, blocking, fulling): what is done to a piece after it is worked, such
  as washing, pinning out to dry, pressing or fulling. It changes the fabric's size, so a swatch is
  measured after finishing it the same way as the project.
- **Draw-in**: how much narrower the woven cloth is than the warp in the reed, as a share of the
  width in the reed. Weft-faced cloth can draw in very little.
- **Shrinkage**: how much a piece loses in width or length when it is finished, as a share of its
  size before.
- **Length allowance**: in Ply, the share to add to a finished length so the warp covers take-up and
  shrinkage together, worked out from a sample as its length on the loom over its length after wet
  finishing, minus one. Adding the lost share instead would fall a little short.
- **Weighed swatch**: a yarn estimate from a swatch's weight: its grams per area times the project's
  area, turned into length by the yarn's length per mass. Closer than a rule of thumb.
- **Measured, entered, Ply default**: in Ply, where a number came from: you measured it, you entered
  it (from a label, a pattern or your setup), or it is Ply's starting value or rule of thumb. Every
  estimate made with a swatch says which of its inputs are which.

### Warp and weft planning
- **Warp and weft plan**: in Ply, a draft's planning worksheet. From the finished size of each item
  it works back through draw-in, take-up, shrinkage and loom waste to the warp ends, the width in the
  reed and the denting, the warp length, the picks and the weft, and the yarn against what you have,
  and says where every number came from. It is saved with the draft.
- **Starting estimate**: in Ply, a rule of thumb used for an assumption until a swatch measures it,
  such as 10% take-up for plain weave. It is marked Ply default and is never a measurement; a sample
  woven and finished like the project gives a better number.
- **Width allowance**: in Ply, the share to add to a finished width so the warp in the reed covers
  draw-in and width shrinkage together, worked out from a sample as its width in the reed over its
  width after wet finishing, minus one.
- **Weft allowance** (weft take-up): the extra weft each pick takes beyond the width in the reed, for
  its bending over and under the warp and its turn at each selvedge, as a share of the width in the
  reed.
- **Hems and fringe**: in a warp plan, the cloth each item folds into its hems (woven, so it shrinks
  with the rest) and the unwoven warp it keeps for fringe, both ends together.
- **Sampling allowance**: extra warp woven at the start of a warp to check the sett, the beat and the
  colors before weaving the project, measured on the loom.
- **Denting** (denting plan): how the warp is spread in the reed: which reed, how many ends go in
  each dent in a repeating order, and how many dents the ends fill.

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
- **Recipe (nalbinding)**: the optional step-by-step plan of a nalbinding project in Ply, in
  working order: a start, the body, the shaping and a finish, for each part (a mitten's hand, then
  its thumb). Ply checks the order, the numbers and each stitch's notation; it does not simulate
  the fabric.
- **Foundation chain** (starting chain): the first stitches of a piece, worked with no round
  before them. Joined into a ring it starts a cuff or a brim; left open it is the first row of a
  flat piece.
- **Centre start**: a small ring of stitches pulled tight at the centre, worked outward in a
  spiral: the crown of a hat, the tip of a mitten, the toe of a sock.
- **Thumb opening**: a gap left in the round for a thumb: some loops of the previous round are
  skipped and the stitches across the gap are not connected to them. The thumb is later worked
  from the loops around it.
- **Pick up loops**: start a new part from loops of earlier work, such as a thumb started at a
  corner of the thumb opening, connecting into the loops along its edge.

### Ready to make or share
- **Ready to make or share**: in Ply, a pattern with no errors, ready to print or share. Before Ply
  prints or shares a pattern it checks everything the PDF depends on: a weaving draft's structure,
  the loom chosen for it and its warp and weft plan; a knitting pattern's chart and sections; a
  nalbinding project's notation and recipe. Errors keep a pattern from being ready; warnings, and
  anything Ply could not check, are listed first and you acknowledge them once. Saving never checks:
  an unfinished pattern always saves.
- **Draft copy**: in Ply, a PDF of a pattern that still has errors, printed or shared only when you
  choose it. Every page says "Draft copy, not ready to make or share" with the number of errors, the
  first page lists them, and the file name ends in "(draft copy)". Not to be confused with a weaving
  draft, the pattern itself.
- **Not checked by Ply** (unsupported): something in a pattern that Ply cannot check or represent,
  such as a step in the pattern's own words, free text in a recipe, or a loom setting the loom
  profile does not record. Ply keeps it as written and says what it did not check, rather than
  guessing.

### Tablet weaving
- **Tablet weaving** (card weaving): weaving a narrow band in which every warp thread passes through
  a hole in a small square card. Turning the cards opens each new shed and twists each card's
  threads into a cord. It is not drafted with shafts, a tie-up and treadling: in Ply it is a craft
  of its own, with its own tab in the library and its bands saved as .plytab files, and Ply does not
  read or write WIF or other programs' files for it. Ply draws a tablet band with pick 1 at the
  bottom and the newest pick at the top, as the band grows away from the weaver, unlike its shaft
  drafts, which put pick 1 at the top. The rules Ply uses to work out a band's faces and twist await
  a tablet weaver's review.
- **Card** (tablet): a small square card with a hole at each corner; each hole carries one warp
  thread or is left empty. Tablets and cards are the same thing, which is why tablet weaving is also
  called card weaving. The cards stand on edge side by side, their faces to the weaver's left and
  right, and are numbered from 1 at the weaver's left. Every card drawing in Ply is a side view from
  the weaver's right, with the band and the weaver at the left of the drawing and the far end of the
  warp at the right.
- **Hole**: one of a card's four holes, lettered A, B, C and D in order round the card, so A and C
  are diagonal, and so are B and D. Each hole is threaded with one color from the band's palette, or
  left empty.
- **Pack**: a named group of cards turned together, such as Left for cards 1 to 4, so an instruction
  can say "turn the Left pack forward". A card is in at most one pack at a time. In Ply a pack is a
  way to write and print the turning: what is saved is every card's own turn on every pick, because
  cards move between packs and are often turned one by one.
- **Near top and far top** (NT, FT): two of the four corners of a card held flat, named by where
  they are rather than by a letter. The near top is the upper corner nearest the weaver and the far
  top the upper corner toward the far end of the warp; below them are the near bottom and the far
  bottom. The threads at the near top and far top make the upper layer of the shed, those at the
  near bottom and far bottom the lower layer, and the weft passes between them.
- **Home position**: the way a card is set at the start of a band. Ply's home has hole A at the near
  top, D at the far top, C at the far bottom and B at the near bottom; seen from the weaver's right
  the letters run A, B, C, D counterclockwise from the near top, so forward turns bring A, B, C and
  D across the top in that order. Many commercial cards are lettered clockwise on their printed face
  and set with the printed face to the right and D at the near top: the same card turned the other
  way round. Ply offers both as presets, "A at the near top" and "printed face to the right, D at
  the near top", and keeps each card's start with its printed letters, so nothing is converted or
  lost.
- **Forward and backward turn** (F, B): a forward turn rotates a card a quarter turn so that its top
  edge moves away from the weaver; seen from the weaver's right it is clockwise, and from Ply home
  it takes hole A from the near top to the far top. A backward turn is the reverse, the top edge
  moving toward the weaver. On every pick each card turns forward, turns backward or stays idle. The
  thread whose hole moves along the top edge during a turn is the one that shows on the band's top
  face for that pick, and the one that moves along the bottom edge shows on the back. Ply's turning
  chart writes F, B and I (and ? for a move Ply does not model), never slashes, which mean different
  things in different sources; a few sources also use "forward" the other way round, so check what
  a pattern means.
- **S and Z threading**: which way the threads pass through a card. Seen from above, with the weaver
  at the bottom and the warp running up the page, each thread of an S-threaded card crosses the card
  like the middle stroke of an S, from upper left to lower right: on the band side it lies along the
  card's face that points to the weaver's right, and on the far side along the face that points
  left. A Z-threaded card is the mirror image. This is the thread-path meaning most weavers use
  (Collingwood's); some sources name S and Z by the card's slant instead, which gives the opposite
  letter. It does not depend on which face is printed, and it is a property of how the card faces
  now, so a flip changes S to Z and Z to S.

```text
Top view of one card, the weaver at the bottom and the warp running up the page.
":" is the card standing on edge; the slanted line is one warp thread.

+-------------------+-------------------+
|    S-threaded     |    Z-threaded     |
|        far        |        far        |
|     \   :         |         :   /     |
|      \  :         |         :  /      |
|       \ :         |         : /       |
|        \:         |         :/        |
|         #  hole   |   hole  #         |
|         :\        |        /:         |
|         : \       |       / :         |
|         :  \      |      /  :         |
|         :   \     |     /   :         |
|        near       |       near        |
+-------------------+-------------------+
S: on the band (near) side the thread lies along the face to the weaver's right, on the far side
along the face to the left. Z: the mirror, band side left and far side right.
```

- **Twining**: the cord twist woven into the band. On every pick a card turns, its threads twine a
  quarter turn round one another: an S-threaded card turned forward, or a Z-threaded card turned
  backward, weaves a Z-twined quarter, and an S-threaded card turned backward, or a Z-threaded card
  turned forward, weaves an S-twined quarter; an idle card weaves none. Ply draws an S-twined stitch
  slanted like \ and a Z-twined stitch slanted like /, the way the cord looks with the warp running
  up the page.
- **Twist**: the twist that builds up in the unwoven warp behind the cards. Ply counts it for each
  card in quarter turns (four make a full turn), with Z twining counted as plus and S twining as
  minus: each turn adds one for a Z-twined quarter or takes one away for an S-twined quarter, and
  the warp behind the card holds that amount of the opposite hand (S twist behind the cards when the
  count is plus). Turning back the other way undoes it turn by turn. A reversal or a flip never
  resets it (a flip leaves it as it was, though later turns in the same direction then count the
  other way); only a twist release the weaver records sets it back to 0. By default Ply warns when a
  card holds more than 8 full turns. The count is computed, and Ply's tablet rules await a tablet
  weaver's review.
- **Twist release**: an event the weaver records before a pick, saying they took the twist out of
  the warp behind some cards, for example by untying the far end and combing it out, or by letting
  swivels spin. It sets those cards' twist count back to 0 and keeps the record of the twining woven
  so far. Ply never assumes a release: nothing else resets the count.
- **Reversal**: a pick on which a card twines the other way from its last turned pick (idle picks
  are skipped over), because the card's turning direction changed, or because it was flipped and
  turned on the same way. It leaves a visible line in the band where the stitch slant changes, shows
  one thread's color on two picks in a row, and makes one thread float over three picks. Ply marks
  it with a line between the two picks and a note in the checks; it never resets or changes the
  twist count. Reversals are computed, and Ply's tablet rules await a tablet weaver's review.
- **Idle**: a card left unturned for a pick (I in the turning chart). Nothing crosses the top or the
  bottom edge, so the card weaves no twining, and its last top-face thread (and last back thread)
  carries on as a longer float; Ply shows the same thread again and marks it as a continued float. A
  card that idles before it has turned at all in the band, or before it has turned again since a
  flip, has no last thread to carry on, so Ply shows both threads of that layer and says so instead
  of guessing.
- **Flip**: turning a card half way round on its vertical axis between picks, so its near and far
  corners change places: from Ply home, D comes to the near top, A to the far top, B to the far
  bottom and C to the near bottom. A flip changes the card from S to Z threading or from Z to S. It
  leaves the twist count as it was, but later turns in the same direction then count the other way,
  so flipping and turning on untwists. Until the card turns again, an idle is shown as ambiguous.
- **Float (tablet weaving)**: in a tablet band, the run of picks a thread spends in the upper layer
  of the shed (toward the top face) or the lower layer (toward the back) before turning takes it to
  the other layer. Steady turning one way gives runs of 2 picks, a reversal 3, and each idle pick
  adds 1. By default Ply warns about a run longer than 3 picks; double-face and 3/1 broken twill
  float over 3 as a matter of course, so they raise no warning. Floats are computed, and Ply's
  tablet rules await a tablet weaver's review.
