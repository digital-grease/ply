// Pure helpers for a knitting pattern's SECTIONS (the construction layer above the chart; the
// engine's `ply_knit::sections` owns their meaning and the stitch ledger). No FFI: ids, the step
// kinds the editor offers, and the hold steps a "return stitches" step can name.

import '../rust/knit_dto.dart';

/// The kinds of step the sections editor can add, in the order the add menu lists them.
enum KnitStepKind {
  chartRows('Chart rows', 'Work rows of the chart, each over every stitch left in the row.'),
  work('Knit or purl across', 'Work part of a row, or to the end of the row, in one stitch.'),
  shortRow('Short row', 'Work part of the row, then turn before the end.'),
  castOn('Cast on', 'Cast on new stitches.'),
  bindOff('Bind off', 'Bind off some stitches, or the rest of the row.'),
  hold('Put stitches on hold', 'Move stitches to a holder or waste yarn, as a named group.'),
  resume('Return held stitches', 'Put a group from a holder back on the needle.'),
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

/// Whether a written-instructions line is a section heading (`Section 2: Left side`, or `Section 2`
/// for a section with no name), as the engine writes them for a pattern with sections.
bool isKnitSectionHeading(String line) => RegExp(r'^Section \d+(?:: .*)?$').hasMatch(line);

/// The largest stitch count a step form accepts (the same bound as the pattern cast-on).
const int kMaxStepCount = 100000;

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

/// The id for a new step of [p] (`step-N`), unique across every section. Every id a "return held
/// stitches" step names counts as used too, so deleting a hold step never lets a new one take its id
/// and silently become what the orphaned return step returns.
String nextStepId(KnitPatternDto p) => _nextId([
      for (final s in p.sections)
        for (final st in s.steps) ...[
          st.id,
          if (st.action case KnitStepActionDto_Resume(:final hold)) hold,
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

/// The action a new step of [kind] starts with in its form: nothing that would surprise (counts the
/// knitter then sets; the first hold step for a return).
KnitStepActionDto defaultKnitStepAction(KnitStepKind kind, KnitPatternDto p) => switch (kind) {
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
    };
