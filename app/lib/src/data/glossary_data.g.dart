// GENERATED FILE — do not edit by hand.
// Source: docs/GLOSSARY.md   Regenerate: dart run tool/gen_glossary.dart
//
// The glossary doc is the single source of truth; test/glossary_test.dart fails if
// this file drifts from it.

import '../models/glossary_term.dart';

/// Every weaving-glossary term, parsed from docs/GLOSSARY.md at codegen time.
const List<GlossaryTerm> kGlossary = [
  GlossaryTerm(
    term: 'Warp',
    definition: 'the threads held under tension on the loom, running the length of the cloth.',
  ),
  GlossaryTerm(
    term: 'Weft',
    aka: 'filling/pick',
    definition: 'the thread carried across the warp, running the width.',
  ),
  GlossaryTerm(
    term: 'End',
    definition: 'a single warp thread. "200 ends" = 200 warp threads across.',
  ),
  GlossaryTerm(
    term: 'Pick',
    definition: 'a single pass of weft; one row of the cloth.',
  ),
  GlossaryTerm(
    term: 'Shaft',
    aka: 'harness',
    definition: 'a frame that raises/lowers a group of warp ends. More shafts = more possible structures. Numbered from 1.',
  ),
  GlossaryTerm(
    term: 'Heddle',
    definition: 'a wire/cord on a shaft with an eye; each warp end passes through one, so lifting the shaft lifts those ends.',
  ),
  GlossaryTerm(
    term: 'Treadle',
    definition: 'a foot pedal. Pressing it raises (or lowers) the shafts tied to it.',
  ),
  GlossaryTerm(
    term: 'Tie-up',
    definition: 'which shafts each treadle controls. A grid of treadles × shafts.',
  ),
  GlossaryTerm(
    term: 'Threading',
    aka: 'draft-in',
    definition: 'the order in which warp ends are assigned to shafts.',
  ),
  GlossaryTerm(
    term: 'Treadling',
    definition: 'the sequence of treadles pressed, pick by pick.',
  ),
  GlossaryTerm(
    term: 'Liftplan',
    definition: 'directly specifies which shafts rise on each pick, bypassing the tie-up; used by table looms and dobby looms. A draft uses a tie-up+treadling *or* a liftplan.',
  ),
  GlossaryTerm(
    term: 'Shed',
    definition: 'the opening between raised and lowered warp ends that the weft passes through.',
  ),
  GlossaryTerm(
    term: 'Rising shed / sinking shed',
    definition: 'whether the loom *raises* or *lowers* the shafts named in the tie-up. Determines how the tie-up is interpreted (see `DATA_MODEL.md`).',
  ),
  GlossaryTerm(
    term: 'Draft',
    definition: 'the complete specification of a woven structure (threading + tie-up + treadling/liftplan + color). Also the file you save.',
  ),
  GlossaryTerm(
    term: 'Drawdown',
    definition: 'the computed picture of the cloth: for each intersection, whether warp or weft is on top. Ply computes this from the draft.',
  ),
  GlossaryTerm(
    term: 'Book draft',
    definition: 'a draft printed as four parts that share their rows and columns: the threading, the tie-up, the treadling (or a liftplan) and the drawdown. Books put the tie-up in different corners and number from different sides, so a printed draft from Ply says where end 1, shaft 1, treadle 1 and pick 1 are.',
  ),
  GlossaryTerm(
    term: 'Use tabby',
    definition: 'the traditional shorthand of an overshot draft. The treadling lists only the pattern picks, and one instruction says to weave a tabby (plain-weave) pick after each, changing between the two tabby sheds. Ply uses it only when the picks\' roles make it give exactly the draft\'s picks.',
  ),
  GlossaryTerm(
    term: 'Float',
    definition: 'a length of thread passing over two or more perpendicular threads without interlacing (e.g. the long floats of satin).',
  ),
  GlossaryTerm(
    term: 'Sett',
    definition: 'how densely the warp is spaced, in **ends per inch (EPI)** / ends per centimeter. The weft analogue is **picks per inch (PPI)**.',
  ),
  GlossaryTerm(
    term: 'WPI (wraps per inch)',
    definition: 'wraps of a yarn that fit in an inch; used to estimate a suitable sett.',
  ),
  GlossaryTerm(
    term: 'Sley / sleying',
    definition: 'threading the warp through the reed; the reed sets the sett.',
  ),
  GlossaryTerm(
    term: 'Beat',
    definition: 'pressing each pick into place against the cloth (the "fell").',
  ),
  GlossaryTerm(
    term: 'Selvedge',
    aka: 'selvage',
    definition: 'the self-finished lengthwise edge of the cloth.',
  ),
  GlossaryTerm(
    term: 'Floating selvedge',
    definition: 'an extra warp end at each edge, sleyed in the reed but not threaded through a heddle, so no shaft moves it. Taking the shuttle over it going in and under it coming out (or the reverse) catches the weft at the edge when the shed alone would not, as on a double shot.',
  ),
  GlossaryTerm(
    term: 'Shuttle',
    definition: 'the tool that carries a weft across the warp. A draft with several wefts uses several shuttles, and each one changes direction on every pass, so the direction of a pick follows from its shuttle.',
  ),
  GlossaryTerm(
    term: 'Double shot',
    definition: 'two passes of the weft in one shed, without changing the shed between them (a triple shot is three). It is not double weave, and not two strands carried together in one pass.',
  ),
  GlossaryTerm(
    term: 'Take-up',
    definition: 'warp/weft shortening from interlacing (cloth is shorter/narrower than the yarn measured straight); budgeted in yarn estimates alongside shrinkage.',
  ),
  GlossaryTerm(
    term: 'Loom waste',
    definition: 'warp that can\'t be woven (tie-on, thrums); a fixed allowance per warp.',
  ),
  GlossaryTerm(
    term: 'Jack loom',
    definition: 'a floor loom whose treadles raise the shafts tied to them while the other shafts stay down. It weaves a tie-up written for a rising shed.',
  ),
  GlossaryTerm(
    term: 'Counterbalance loom',
    definition: 'a floor loom whose shafts hang from rollers or pulleys, linked to each other, so every treadle moves every shaft: the tied shafts sink and the rest rise. It weaves a tie-up written for a sinking shed, and works best when each shed raises as many shafts as it lowers (a balanced shed).',
  ),
  GlossaryTerm(
    term: 'Countermarch loom',
    definition: 'a floor loom with two sets of lamms, one that raises shafts and one that lowers them, so every shaft is tied up or down on each treadle. It weaves a tie-up written either way.',
  ),
  GlossaryTerm(
    term: 'Table loom',
    definition: 'a smaller loom worked by hand levers, usually one for each shaft, set for each pick instead of pressing treadles. It follows a liftplan.',
  ),
  GlossaryTerm(
    term: 'Dobby loom',
    definition: 'a loom that selects the shafts for each pick itself, with pegs on bars or a computer, following a liftplan. It suits drafts with many shafts.',
  ),
  GlossaryTerm(
    term: 'Lamm',
    definition: 'a bar between the treadles and the shafts that carries the tie-up cords.',
  ),
  GlossaryTerm(
    term: 'Skeleton tie-up',
    definition: 'a tie-up for more sheds than the loom has treadles, where some picks press two treadles at once, one with each foot.',
  ),
  GlossaryTerm(
    term: 'Reed',
    definition: 'the comb-like frame in the beater that spaces the warp ends and beats the weft into place. It is sized by its dents per inch, or per 10 cm for a metric reed (a 40/10 reed has 40 dents in 10 cm).',
  ),
  GlossaryTerm(
    term: 'Dent',
    definition: 'one space between the wires of a reed. One or more ends go in each dent; the dents per inch times the ends in each dent is the sett.',
  ),
  GlossaryTerm(
    term: 'Sleying order',
    definition: 'how many ends go in each dent, repeated across the warp, such as 2, 1, 1 for 16 ends per inch in a 12-dent reed.',
  ),
  GlossaryTerm(
    term: 'Weaving width',
    aka: 'width in the reed',
    definition: 'how wide the warp is in the reed, its ends divided by its sett. A loom\'s weaving width is the widest warp it takes. A double-width cloth is woven folded, so it is about half as wide in the reed as it is opened out.',
  ),
  GlossaryTerm(
    term: 'Loom profile',
    definition: 'in Ply, a loom you describe in My looms (its type, shafts, treadles, weaving width and reeds), so a draft can be checked against it.',
  ),
  GlossaryTerm(
    term: 'Plain weave / tabby',
    definition: 'over-one/under-one; maximum interlacement, most stable.',
  ),
  GlossaryTerm(
    term: 'Twill',
    definition: 'diagonal lines from offset floats (denim is a twill).',
  ),
  GlossaryTerm(
    term: 'Satin / sateen',
    definition: 'long floats, smooth lustrous face, densest sett.',
  ),
  GlossaryTerm(
    term: 'Shadow weave',
    definition: 'a block weave in which warp and weft both alternate dark and light threads one by one, and each dark end has a light "shadow" end beside it on a partner shaft. Inside each block the cloth is plain weave with fine horizontal or vertical lines; the only floats are two-thread skips where blocks meet. Unlike log cabin, the pattern comes from the threading, not the color order. The Atwater and Powell systems number the shafts differently but weave the same cloth.',
  ),
  GlossaryTerm(
    term: 'Knit',
    aka: 'k',
    definition: 'the basic stitch; a new loop pulled through to the back, making a flat "V" on the right side.',
  ),
  GlossaryTerm(
    term: 'Purl',
    aka: 'p',
    definition: 'the reverse of a knit, the loop drawn through to the front, making a horizontal bump.',
  ),
  GlossaryTerm(
    term: 'Gauge',
    aka: 'tension',
    definition: 'stitches and rows per 4 in / 10 cm; knitting\'s sett analogue, and what decides the finished size.',
  ),
  GlossaryTerm(
    term: 'Right side / wrong side',
    aka: 'RS/WS',
    definition: 'the face meant to show (RS) versus the back (WS); on a flat piece the rows alternate between them.',
  ),
  GlossaryTerm(
    term: 'Cast on',
    definition: 'the foundation row that puts the first loops on the needle.',
  ),
  GlossaryTerm(
    term: 'Bind off',
    aka: 'cast off',
    definition: 'securing the last loops so the work won\'t unravel.',
  ),
  GlossaryTerm(
    term: 'Stockinette',
    aka: 'stocking stitch',
    definition: 'knit on right-side rows, purl on wrong-side rows; a smooth field of "V"s that curls at the edges.',
  ),
  GlossaryTerm(
    term: 'Garter',
    definition: 'knit every row; a reversible, ridged fabric that lies flat.',
  ),
  GlossaryTerm(
    term: 'Yarn over',
    aka: 'yo',
    definition: 'wrapping the yarn to add a stitch and leave a deliberate hole, the basis of lace.',
  ),
  GlossaryTerm(
    term: 'k2tog / ssk',
    definition: 'paired decreases that each turn two stitches into one, leaning right (k2tog) or left (ssk).',
  ),
  GlossaryTerm(
    term: 'Chart',
    definition: 'a grid where each cell is one stitch, read bottom to top; right-side rows read right to left, wrong-side rows left to right.',
  ),
  GlossaryTerm(
    term: 'Repeat',
    definition: 'a block of stitches or rows worked over and over across a row or up the piece.',
  ),
  GlossaryTerm(
    term: 'Cable',
    definition: 'stitches crossed over their neighbours (held on a cable needle) to make a rope-like twist.',
  ),
  GlossaryTerm(
    term: 'In the round',
    definition: 'worked as a tube on circular or double-pointed needles, so every round faces the right side.',
  ),
  GlossaryTerm(
    term: 'Short row',
    definition: 'a row turned before it reaches the end of the needle. The stitches past the turn stay on the needle unworked, so the part that is worked gains rows; short rows slope shoulders, shape darts and turn heels.',
  ),
  GlossaryTerm(
    term: 'German short row',
    definition: 'a way to turn a short row: turn, slip the first stitch with the yarn in front, and pull the yarn over the needle, which makes a double stitch. A later row works it as one stitch.',
  ),
  GlossaryTerm(
    term: 'Double stitch',
    aka: 'DS',
    definition: 'the stitch a German short row pulls up at its turn, so it looks like two. It counts as one stitch, and a later row works both legs together as one.',
  ),
  GlossaryTerm(
    term: 'Held stitches',
    aka: 'on hold',
    definition: 'live stitches moved off the needle onto a stitch holder or waste yarn, to be worked later, such as the center of a neckline. Returning them puts them back on the needle, and the pattern says which side faces you.',
  ),
  GlossaryTerm(
    term: 'Section',
    definition: 'in Ply, a named part of a pattern\'s construction (such as Back or Left shoulder), with its steps in order. Ply counts the stitches on the needle, on hold and bound off after every step.',
  ),
  GlossaryTerm(
    term: 'Join in the round',
    definition: 'bring the two ends of the knitting together so it goes on around as a tube instead of turning; after a cast-on, take care not to twist the stitches.',
  ),
  GlossaryTerm(
    term: 'Heel flap',
    definition: 'in a sock knitted from the cuff down, a flap worked back and forth over the heel stitches while the instep stitches wait. Slipping the first stitch of every row makes a chain of edge stitches, one for every two rows, to pick up the gusset from.',
  ),
  GlossaryTerm(
    term: 'Heel turn',
    aka: 'turning the heel',
    definition: 'short rows across the bottom of the heel flap that cup the heel. Each row works to the gap, decreases across it, works a stitch or so more and turns, until every heel stitch is worked.',
  ),
  GlossaryTerm(
    term: 'Gap',
    aka: 'in short rows',
    definition: 'the place where an earlier short row on the same side turned, between the stitches it worked and the ones it left. A heel turn works to it and decreases across it.',
  ),
  GlossaryTerm(
    term: 'Gusset',
    definition: 'the stitches picked up along the sides of a heel flap, then decreased every other round until the sock is back to its stitch count, which shapes the foot below the ankle.',
  ),
  GlossaryTerm(
    term: 'Instep',
    definition: 'the top of the foot. In a sock, the stitches that wait while the heel is worked.',
  ),
  GlossaryTerm(
    term: 'Pick up and knit',
    definition: 'draw new loops through an edge of the knitting, such as the slipped stitches along a heel flap, and knit them, adding stitches to the needle. The pattern says how many to pick up, often one for each slipped edge stitch and an extra one at a corner.',
  ),
  GlossaryTerm(
    term: 'Short-row heel',
    definition: 'a sock heel worked back and forth over half the stitches with short rows, each row shorter and then longer again, with no flap or gusset; the wraps or double stitches are worked as the rows grow, and the knitting goes back to rounds.',
  ),
  GlossaryTerm(
    term: 'Kitchener stitch',
    aka: 'grafting',
    definition: 'sewing two needles of live stitches together with a tapestry needle, so the join looks like a row of knitting. It closes a sock toe.',
  ),
  GlossaryTerm(
    term: 'Three-needle bind-off',
    definition: 'binding off the stitches of two needles together, with the right sides facing each other and a third needle, which joins two pieces such as shoulders.',
  ),
  GlossaryTerm(
    term: 'Needle group',
    definition: 'in Ply, a named group of the stitches on the needle, such as the instep and the sole, so the count after each step gives each group.',
  ),
  GlossaryTerm(
    term: 'Start of the round',
    aka: 'beginning of round',
    definition: 'the point where each round begins, usually kept with a marker. Sock patterns often move it, for example to the center of the heel after picking up the gusset stitches.',
  ),
  GlossaryTerm(
    term: 'Beginning',
    aka: 'beg',
    definition: 'the start of a row or round.',
  ),
  GlossaryTerm(
    term: 'Decrease',
    aka: 'dec',
    definition: 'working stitches together to reduce the stitch count.',
  ),
  GlossaryTerm(
    term: 'Increase',
    aka: 'inc',
    definition: 'adding a stitch to widen the work.',
  ),
  GlossaryTerm(
    term: 'Double-pointed needles',
    aka: 'DPN',
    definition: 'short needles pointed at both ends, for knitting small tubes in the round.',
  ),
  GlossaryTerm(
    term: 'Follow',
    aka: 'foll',
    definition: 'work as the named row, round, or chart directs.',
  ),
  GlossaryTerm(
    term: 'Knitwise',
    aka: 'kwise',
    definition: 'insert the needle as if to knit.',
  ),
  GlossaryTerm(
    term: 'Purlwise',
    aka: 'pwise',
    definition: 'insert the needle as if to purl.',
  ),
  GlossaryTerm(
    term: 'Through the back loop',
    aka: 'tbl',
    definition: 'work into the back of the loop instead of the front, twisting the stitch.',
  ),
  GlossaryTerm(
    term: 'Together',
    aka: 'tog',
    definition: 'work the named stitches as one, as in k2tog (knit two together).',
  ),
  GlossaryTerm(
    term: 'Knit front and back',
    aka: 'kfb',
    definition: 'knit into the front then the back of one stitch, an increase of one.',
  ),
  GlossaryTerm(
    term: 'Knit back and front',
    aka: 'kbf',
    definition: 'knit into the back then the front of one stitch, the mirror of kfb.',
  ),
  GlossaryTerm(
    term: 'Knit three together',
    aka: 'k3tog',
    definition: 'a right-leaning double decrease, three stitches become one.',
  ),
  GlossaryTerm(
    term: 'Make one',
    aka: 'M1',
    definition: 'lift the strand between two stitches and work it to add a stitch.',
  ),
  GlossaryTerm(
    term: 'Make one left',
    aka: 'M1L',
    definition: 'a left-leaning lifted increase.',
  ),
  GlossaryTerm(
    term: 'Make one right',
    aka: 'M1R',
    definition: 'a right-leaning lifted increase.',
  ),
  GlossaryTerm(
    term: 'Make one purlwise',
    aka: 'M1P',
    definition: 'a lifted increase worked as a purl.',
  ),
  GlossaryTerm(
    term: 'Purl front and back',
    aka: 'pfb',
    definition: 'purl into the front then the back of one stitch, an increase of one.',
  ),
  GlossaryTerm(
    term: 'Purl two together',
    aka: 'p2tog',
    definition: 'a decrease worked from the purl side, two stitches become one.',
  ),
  GlossaryTerm(
    term: 'Slip',
    aka: 'sl',
    definition: 'move a stitch to the other needle without working it.',
  ),
  GlossaryTerm(
    term: 'Slip slip purl',
    aka: 'ssp',
    definition: 'a left-leaning purl-side decrease, two stitches become one.',
  ),
  GlossaryTerm(
    term: 'Slip, knit 2 together, pass over',
    aka: 'sk2po',
    definition: 'slip one, knit two together, pass the slipped stitch over, a double decrease.',
  ),
  GlossaryTerm(
    term: 'Slip 2, knit, pass over',
    aka: 's2kpo',
    definition: 'slip two together knitwise, knit one, pass the two slipped over, a centered double decrease (the cdd in the chart).',
  ),
  GlossaryTerm(
    term: 'Stitch',
    aka: 'st',
    definition: 'one loop on the needle; the plural is sts.',
  ),
  GlossaryTerm(
    term: 'Remaining',
    aka: 'rem',
    definition: 'the stitches left on the needle.',
  ),
  GlossaryTerm(
    term: 'Pattern',
    aka: 'patt',
    definition: 'the established stitch sequence to repeat.',
  ),
  GlossaryTerm(
    term: 'Place marker',
    aka: 'PM',
    definition: 'slip a marker onto the needle to flag a position.',
  ),
  GlossaryTerm(
    term: 'Slip marker',
    aka: 'SM',
    definition: 'move the marker across as you reach it, working on.',
  ),
  GlossaryTerm(
    term: 'Reverse stockinette',
    aka: 'rev St st',
    definition: 'purl on right-side rows and knit on wrong-side rows, the bumpy face of stockinette.',
  ),
  GlossaryTerm(
    term: 'With yarn in back',
    aka: 'wyib',
    definition: 'hold the working yarn behind the work, often while slipping a stitch.',
  ),
  GlossaryTerm(
    term: 'With yarn in front',
    aka: 'wyif',
    definition: 'hold the working yarn in front of the work.',
  ),
  GlossaryTerm(
    term: 'Wrap and turn',
    aka: 'w&t',
    definition: 'wrap the next stitch and turn mid-row to work a short row; a later row works the wrap together with its stitch.',
  ),
  GlossaryTerm(
    term: 'Left hand / right hand',
    aka: 'LH/RH',
    definition: 'which needle or hand a step refers to.',
  ),
  GlossaryTerm(
    term: 'Swatch',
    aka: 'sample',
    definition: 'a small piece worked in the yarn, stitch, tools and tension of a project, then measured before and after it is finished the way the project will be, to find the gauge (or sett and picks) and how much the fabric changes. In Ply, a swatch record can be linked to any number of projects, and the planning calculators can take their numbers from it.',
  ),
  GlossaryTerm(
    term: 'Material',
    definition: 'in Ply, a yarn or thread you describe in Materials and swatches: its fibers, weight category, structure, length per mass, wraps per inch, color, dye lot and how much you have. Every field is optional.',
  ),
  GlossaryTerm(
    term: 'Length per mass',
    aka: 'yardage, grist',
    definition: 'how much yarn a weight of it holds, as on a ball band ("200 m per 100 g"). Weavers often give it as yards per pound (YPP). Weigh a measured length to find your own.',
  ),
  GlossaryTerm(
    term: 'Dye lot',
    definition: 'the batch a yarn was dyed in, printed on the label. Skeins from one lot match; another lot of the same color may not.',
  ),
  GlossaryTerm(
    term: 'Fiber blend',
    definition: 'the fibers a yarn is spun from, with their share by weight, as the label gives them ("80% wool, 20% nylon").',
  ),
  GlossaryTerm(
    term: 'Finishing',
    aka: 'wet finishing, blocking, fulling',
    definition: 'what is done to a piece after it is worked, such as washing, pinning out to dry, pressing or fulling. It changes the fabric\'s size, so a swatch is measured after finishing it the same way as the project.',
  ),
  GlossaryTerm(
    term: 'Draw-in',
    definition: 'how much narrower the woven cloth is than the warp in the reed, as a share of the width in the reed. Weft-faced cloth can draw in very little.',
  ),
  GlossaryTerm(
    term: 'Shrinkage',
    definition: 'how much a piece loses in width or length when it is finished, as a share of its size before.',
  ),
  GlossaryTerm(
    term: 'Length allowance',
    definition: 'in Ply, the share to add to a finished length so the warp covers take-up and shrinkage together, worked out from a sample as its length on the loom over its length after wet finishing, minus one. Adding the lost share instead would fall a little short.',
  ),
  GlossaryTerm(
    term: 'Weighed swatch',
    definition: 'a yarn estimate from a swatch\'s weight: its grams per area times the project\'s area, turned into length by the yarn\'s length per mass. Closer than a rule of thumb.',
  ),
  GlossaryTerm(
    term: 'Measured, entered, Ply default',
    definition: 'in Ply, where a number came from: you measured it, you entered it (from a label, a pattern or your setup), or it is Ply\'s starting value or rule of thumb. Every estimate made with a swatch says which of its inputs are which.',
  ),
  GlossaryTerm(
    term: 'Nalbinding',
    aka: 'nålbinding',
    definition: 'an ancient single-needle looping craft, worked in a spiral with short lengths of yarn; predates knitting and crochet, and does not unravel when cut.',
  ),
  GlossaryTerm(
    term: 'Hansen notation',
    definition: 'the standard encoding of a nalbinding stitch: a string of `U` (needle under a loop) and `O` (over), with `/` marking the turn where the thread reverses, plus a connection. E.g. the Oslo stitch is `UO/UOO F1`.',
  ),
  GlossaryTerm(
    term: 'Connection',
    aka: 'F/B',
    definition: 'how a new loop anchors into the previous round: `F` enters from the front, `B` from the back, and the number is how many loops it engages (`F2` = one new + one old).',
  ),
  GlossaryTerm(
    term: 'Thumb loop',
    definition: 'a loop held around the thumb while forming the next stitch; the `a+b` count (Oslo = 1+1, Mammen = 1+2) names a stitch by its thumb-loop groups.',
  ),
  GlossaryTerm(
    term: 'Spiral',
    definition: 'nalbinding has no rows; it climbs continuously in a spiral, leaving a visible "step" where one round meets the next.',
  ),
  GlossaryTerm(
    term: 'Increase / decrease',
    definition: 'shaping by eye: an increase works two stitches into one connection point, a decrease skips a loop, judged by the thumb-loop angle to the centre.',
  ),
];
