// Pure helpers for a knitting pattern's SECTIONS (the construction layer above the chart; the
// engine's `ply_knit::sections` owns their meaning and the stitch ledger). No FFI: ids, the step
// kinds the editor offers, the hold steps a "return stitches" step can name, and the garment's
// PIECES (ADR 0020) a section works and a join step brings in.

import 'dart:convert';

import '../rust/knit_dto.dart';

/// The kinds of step the sections editor can add, in the order the add menu lists them.
enum KnitStepKind {
  chartRows('Chart rows', 'Work rows of the chart, each over every stitch left in the row.'),
  work('Knit or purl across', 'Work part of a row, or to the end of the row, in one stitch.'),
  rows(
      'Rows or rounds', 'Work a number of whole rows or rounds without changing the stitch count.'),
  shortRow('Short row', 'Work part of the row, then turn before the end.'),
  castOn('Cast on', 'Cast on new stitches.'),
  bindOff('Bind off', 'Bind off some stitches, or the rest of the row.'),
  hold('Put stitches on hold', 'Move stitches to a holder or waste yarn, as a named group.'),
  resume('Return held stitches', 'Put a group from a holder back on the needle.'),
  joinRound('Join in the round',
      'Join the stitches into a round, or join a part worked flat back into the round.'),
  workFlat('Work part of the round flat',
      'Work back and forth over some of the stitches, such as a heel flap, while the rest wait.'),
  pickUp('Pick up and knit', 'Pick up and knit new stitches along an edge, such as a heel flap.'),
  groups('Needle groups',
      'Name groups of stitches on the needle, such as the instep and the sole, to count each.'),
  shape('Shaping',
      'Decrease or increase on some rows or rounds, a number of times or to a stitch count.'),
  close('Graft or close',
      'Graft the last stitches together, or bind them off together; or close two groups on hold.'),
  roundStart('Move the start of the round',
      'Make the round start where the work is now, as patterns say after a gusset pick-up.'),
  join(
      'Join a piece or held stitches',
      'Knit another piece, or stitches on hold, into this piece where the work is: sleeves onto a '
          'yoke, a thumb from its held stitches.'),
  unchecked('Written step (not checked)',
      'Any other instruction, in your own words. Ply does not check it.');

  const KnitStepKind(this.label, this.help);

  /// The kind's name in the editor.
  final String label;

  /// One plain sentence saying what the kind does.
  final String help;
}

/// The kind of [action].
KnitStepKind knitStepKind(KnitStepActionDto action) => switch (action) {
      KnitStepActionDto_ChartRows() => KnitStepKind.chartRows,
      KnitStepActionDto_Work() => KnitStepKind.work,
      KnitStepActionDto_ShortRow() => KnitStepKind.shortRow,
      KnitStepActionDto_CastOn() => KnitStepKind.castOn,
      KnitStepActionDto_BindOff() => KnitStepKind.bindOff,
      KnitStepActionDto_Hold() => KnitStepKind.hold,
      KnitStepActionDto_Resume() => KnitStepKind.resume,
      KnitStepActionDto_Opaque() => KnitStepKind.unchecked,
      KnitStepActionDto_JoinRound() => KnitStepKind.joinRound,
      KnitStepActionDto_WorkFlat() => KnitStepKind.workFlat,
      KnitStepActionDto_Rows() => KnitStepKind.rows,
      KnitStepActionDto_Shape() => KnitStepKind.shape,
      KnitStepActionDto_PickUp() => KnitStepKind.pickUp,
      KnitStepActionDto_Groups() => KnitStepKind.groups,
      KnitStepActionDto_Close() => KnitStepKind.close,
      KnitStepActionDto_RoundStart() => KnitStepKind.roundStart,
      KnitStepActionDto_Join() => KnitStepKind.join,
    };

/// The plain-words name of a work stitch.
String workStitchLabel(WorkStitchKind s) => switch (s) {
      WorkStitchKind.knit => 'Knit',
      WorkStitchKind.purl => 'Purl',
      WorkStitchKind.inPattern => 'In pattern',
    };

/// The plain-words name of a turning method.
String turnMethodLabel(TurnMethodKind m) => switch (m) {
      TurnMethodKind.wrapAndTurn => 'Wrap and turn',
      TurnMethodKind.german => 'German short row',
      TurnMethodKind.unspecified => 'Just turn (method not stated)',
    };

/// The plain-words name of a decrease worked at a short row's turn.
String decreaseLabel(DecreaseKind d) => switch (d) {
      DecreaseKind.k2Tog => 'k2tog',
      DecreaseKind.ssk => 'ssk',
      DecreaseKind.p2Tog => 'p2tog',
      DecreaseKind.ssp => 'ssp',
    };

/// The plain-words name of a way to close the last stitches.
String closeMethodLabel(CloseMethodKind m) => switch (m) {
      CloseMethodKind.graft => 'Graft (Kitchener stitch)',
      CloseMethodKind.threeNeedleBindOff => 'Three-needle bind-off',
    };

/// How a section says it is worked, in plain words (`null`: the section does not say).
String sectionConstructionLabel(ConstructionKind? c) => switch (c) {
      null => 'Not stated',
      ConstructionKind.flat => 'Worked flat',
      ConstructionKind.inTheRound => 'Worked in the round',
    };

/// Whether a written-instructions line is a section heading (`Section 2: Left side`, or `Section 2`
/// for a section with no name, with the piece it works and `(worked flat)` or `(worked in the
/// round)` in brackets when the pattern has pieces or the section says), as the engine writes them
/// for a pattern with sections.
bool isKnitSectionHeading(String line) => RegExp(r'^Section \d+(?:: .*| \(.+\))?$').hasMatch(line);

/// Whether a written-instructions line is the engine's opening line for a pattern in several
/// pieces (`Made in 3 pieces: body, left sleeve and right sleeve. ...`).
bool isKnitPiecesLine(String line) => RegExp(r'^Made in \d+ pieces?: ').hasMatch(line);

/// The largest stitch count a step form accepts (the same bound as the pattern cast-on).
const int kMaxStepCount = 100000;

/// The most a section's or step's name, notes or text may hold, in bytes of UTF-8 as the engine
/// measures it (`ply_knit::sections::MAX_TEXT_BYTES`): a pattern past it would save but not open.
const int kMaxSectionTextBytes = 10000;

/// The most needle groups one step may name or set (`ply_knit::sections::MAX_GROUPS`).
const int kMaxNeedleGroups = 100;

/// Whether [text] is longer than a section or step text may be.
bool knitTextTooLong(String text) => utf8.encode(text).length > kMaxSectionTextBytes;

/// The most pieces a pattern may have (`ply_knit::sections::MAX_PIECES`).
const int kMaxKnitPieces = 50;

/// The most a piece's name may hold, in bytes of UTF-8 (`ply_knit::sections::MAX_PIECE_NAME_BYTES`):
/// it is named in every count while it is set aside.
const int kMaxPieceNameBytes = 200;

/// What a form says when a piece's name is past [kMaxPieceNameBytes], or null when it fits.
String? knitPieceNameProblem(String name) => utf8.encode(name.trim()).length > kMaxPieceNameBytes
    ? 'Too long: keep a piece\'s name under 200 bytes (most letters take 1).'
    : null;

/// What a form says when a text is past [kMaxSectionTextBytes].
const String kKnitTextTooLong =
    'Too long for Ply to save: keep it under 10,000 bytes (most letters take 1, accented letters '
    'and symbols 2 to 4).';

/// The next free id of the form `<prefix>N`: one more than the largest N already used, so a new id
/// never clashes with an existing one (including ids a deleted item freed, which are not reused).
String _nextId(Iterable<String> ids, String prefix) {
  var max = 0;
  for (final id in ids) {
    if (!id.startsWith(prefix)) continue;
    final n = int.tryParse(id.substring(prefix.length));
    if (n != null && n > max) max = n;
  }
  return '$prefix${max + 1}';
}

/// The id for a new section of [p] (`section-N`).
String nextSectionId(KnitPatternDto p) => _nextId([for (final s in p.sections) s.id], 'section-');

/// The id for a new piece of [p] (`piece-N`). Every id a section or a join step still names counts
/// as used, so deleting a piece never lets a new one take its id and silently become what those
/// steps meant.
String nextPieceId(KnitPatternDto p) => _nextId([
      for (final piece in p.pieces) piece.id,
      for (final s in p.sections) ...[
        if (s.piece != null) s.piece!,
        for (final st in s.steps)
          if (st.action case KnitStepActionDto_Join(source: JoinSourceDto_Piece(:final piece)))
            piece,
      ],
    ], 'piece-');

/// The id for a new step of [p] (`step-N`), unique across every section. Every id a "return held
/// stitches" or "pick up along" step names counts as used too, so deleting a hold or work-flat step
/// never lets a new one take its id and silently become what the orphaned step refers to.
String nextStepId(KnitPatternDto p) => _nextId([
      for (final s in p.sections)
        for (final st in s.steps) ...[
          st.id,
          if (st.action case KnitStepActionDto_Resume(:final hold)) hold,
          if (st.action case KnitStepActionDto_PickUp(along: PickUpAlongDto_Piece(:final step)))
            step,
          if (st.action case KnitStepActionDto_Join(source: JoinSourceDto_Held(:final hold))) hold,
          if (st.action case KnitStepActionDto_Close(:final holds)) ...holds,
        ],
    ], 'step-');

/// A step that puts stitches on hold, as a "return held stitches" step can name it.
class KnitHoldRef {
  const KnitHoldRef({
    required this.stepId,
    required this.name,
    required this.sectionName,
    required this.stepNumber,
  });

  /// The hold step's id (what the return step stores).
  final String stepId;

  /// The group's name as the hold step gives it.
  final String name;

  /// The section's display name (`Section 2` when it has none).
  final String sectionName;

  /// The hold step's 1-based position in its section.
  final int stepNumber;

  /// `center neck (Divide, step 2)`.
  String get label =>
      '${name.trim().isEmpty ? 'Unnamed group' : name.trim()} ($sectionName, step $stepNumber)';
}

/// A piece's display name: its name, or `piece N` (1-based) when it has none (the engine's
/// `piece_title`).
String knitPieceTitle(KnitPatternDto p, int index) {
  final name = index >= 0 && index < p.pieces.length ? p.pieces[index].name.trim() : '';
  return name.isEmpty ? 'piece ${index + 1}' : name;
}

/// [s] with its first letter in capitals, for a title.
String knitCapitalized(String s) => s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

/// The index in [p]'s pieces of the piece the section at [si] works (the engine's
/// `section_piece`): the piece it names, or the first when it names none; null for a pattern of
/// one piece, or a section naming a piece [p] does not have.
int? knitSectionPieceIndex(KnitPatternDto p, int si) {
  if (p.pieces.isEmpty || si < 0 || si >= p.sections.length) return null;
  final id = p.sections[si].piece;
  if (id == null) return 0;
  final i = p.pieces.indexWhere((piece) => piece.id == id);
  return i < 0 ? null : i;
}

/// A section's display name: its name, or `Section N` (1-based) when it has none (the engine's
/// `section_title`).
String knitSectionTitle(KnitPatternDto p, int index) {
  final name = index < p.sections.length ? p.sections[index].name.trim() : '';
  return name.isEmpty ? 'Section ${index + 1}' : name;
}

/// Every hold step in [p], in pattern order.
List<KnitHoldRef> knitHoldSteps(KnitPatternDto p) => [
      for (var si = 0; si < p.sections.length; si++)
        for (var ti = 0; ti < p.sections[si].steps.length; ti++)
          if (p.sections[si].steps[ti].action case KnitStepActionDto_Hold(:final name))
            KnitHoldRef(
              stepId: p.sections[si].steps[ti].id,
              name: name,
              sectionName: knitSectionTitle(p, si),
              stepNumber: ti + 1,
            ),
    ];

/// Every step that works part of the round flat in [p], in pattern order, as a pick-up step can
/// name it (the part's name, or `Part worked flat` when it has none).
List<KnitHoldRef> knitFlatParts(KnitPatternDto p) => [
      for (var si = 0; si < p.sections.length; si++)
        for (var ti = 0; ti < p.sections[si].steps.length; ti++)
          if (p.sections[si].steps[ti].action case KnitStepActionDto_WorkFlat(:final name))
            KnitHoldRef(
              stepId: p.sections[si].steps[ti].id,
              name: name.trim().isEmpty ? 'Part worked flat' : name,
              sectionName: knitSectionTitle(p, si),
              stepNumber: ti + 1,
            ),
    ];

/// The names of the needle groups the pattern's group steps set, in order, each once.
List<String> knitGroupNames(KnitPatternDto p) {
  final names = <String>[];
  for (final s in p.sections) {
    for (final st in s.steps) {
      if (st.action case KnitStepActionDto_Groups(:final groups)) {
        for (final g in groups) {
          final n = g.name.trim();
          if (n.isNotEmpty && !names.contains(n)) names.add(n);
        }
      }
    }
  }
  return names;
}

/// The action a new step of [kind] starts with in its form: nothing that would surprise (counts the
/// knitter then sets; the first hold step for a return).
KnitStepActionDto defaultKnitStepAction(KnitStepKind kind, KnitPatternDto p, {int? sectionIndex}) =>
    switch (kind) {
      KnitStepKind.chartRows =>
        KnitStepActionDto.chartRows(first: 1, last: p.chart.rows.isEmpty ? 1 : p.chart.rows.length),
      KnitStepKind.work => const KnitStepActionDto.work(
          stitch: WorkStitchKind.knit, to: WorkToDto.end(), resolveTurns: false),
      KnitStepKind.shortRow => const KnitStepActionDto.shortRow(
          stitch: WorkStitchKind.knit,
          to: TurnAtDto.last(count: 4),
          method: TurnMethodKind.wrapAndTurn,
          resolveTurns: false),
      KnitStepKind.castOn => const KnitStepActionDto.castOn(count: 1),
      KnitStepKind.bindOff => const KnitStepActionDto.bindOff(resolveTurns: false),
      KnitStepKind.hold => const KnitStepActionDto.hold(name: ''),
      KnitStepKind.resume => KnitStepActionDto.resume(
          hold: knitHoldSteps(p).isEmpty ? '' : knitHoldSteps(p).last.stepId),
      KnitStepKind.unchecked => const KnitStepActionDto.opaque(text: ''),
      KnitStepKind.joinRound => const KnitStepActionDto.joinRound(),
      KnitStepKind.workFlat =>
        const KnitStepActionDto.workFlat(count: 1, name: 'heel flap', slipEdges: true),
      KnitStepKind.rows => const KnitStepActionDto.rows(count: 1, text: ''),
      KnitStepKind.shape => const KnitStepActionDto.shape(
          change: -2, every: 2, until: ShapeUntilDto.times(count: 1), groups: [], text: ''),
      KnitStepKind.pickUp => KnitStepActionDto.pickUp(
          count: 1,
          along: knitFlatParts(p).isEmpty
              ? const PickUpAlongDto.edge(text: '')
              : PickUpAlongDto.piece(step: knitFlatParts(p).last.stepId)),
      KnitStepKind.groups => const KnitStepActionDto.groups(groups: []),
      KnitStepKind.close => const KnitStepActionDto.close(method: CloseMethodKind.graft, holds: []),
      KnitStepKind.roundStart => const KnitStepActionDto.roundStart(),
      KnitStepKind.join => _defaultJoin(p, sectionIndex),
    };

/// A join's starting source: another piece than the one section [sectionIndex] works, the first
/// that is not it; else the last stitches put on hold; else none (the form asks for one).
KnitStepActionDto _defaultJoin(KnitPatternDto p, int? sectionIndex) {
  final own = sectionIndex == null ? null : knitSectionPieceIndex(p, sectionIndex);
  final others = [
    for (var i = 0; i < p.pieces.length; i++)
      if (i != own) p.pieces[i].id,
  ];
  final holds = knitHoldSteps(p);
  return KnitStepActionDto.join(
      source: others.isNotEmpty && own != null
          ? JoinSourceDto.piece(piece: others.first)
          : JoinSourceDto.held(hold: holds.isEmpty ? '' : holds.last.stepId),
      stitch: WorkStitchKind.knit,
      resolveTurns: false);
}
