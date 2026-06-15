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
    term: 'Take-up',
    definition: 'warp/weft shortening from interlacing (cloth is shorter/narrower than the yarn measured straight); budgeted in yarn estimates alongside shrinkage.',
  ),
  GlossaryTerm(
    term: 'Loom waste',
    definition: 'warp that can\'t be woven (tie-on, thrums); a fixed allowance per warp.',
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
    term: 'Hansen notation',
    aka: 'nalbinding',
    definition: '`U`/`O` (under/over) stitch encoding with connection markers; the basis for the future nalbinding model.',
  ),
];
