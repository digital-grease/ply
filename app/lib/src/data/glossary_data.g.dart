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
    term: 'Gauge',
    aka: 'knitting',
    definition: 'stitches and rows per unit; knitting\'s sett analogue.',
  ),
  GlossaryTerm(
    term: 'Hansen notation',
    aka: 'nalbinding',
    definition: '`U`/`O` (under/over) stitch encoding with connection markers; the basis for the future nalbinding model.',
  ),
];
