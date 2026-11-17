// The recipe as the engine sees it and as the app words it: the mapping from the app's recipe model
// to the bridge DTO the engine checks, and the shared wording of a checked segment (its stitch, its
// count, whether Ply checked it) that the recipe editor, the follow view and the PDF all use, so the
// three never disagree. No FFI calls here; the DTO classes are plain data.

import '../rust/nalbind_recipe_dto.dart';
import 'nalbind_recipe.dart';

/// The engine's view of [recipe] (ticks are progress, not instructions, so they do not cross).
RecipeDto recipeToDto(NalbindRecipe recipe) => RecipeDto(
      fit: [for (final m in recipe.fit) _measure(m)],
      segments: [for (final s in recipe.segments) _segment(s)],
    );

RecipeMeasurementDto _measure(Measurement m) => RecipeMeasurementDto(
      label: m.label,
      value: m.value,
      unit: switch (m.unit) {
        null => null,
        LengthUnit.mm => RecipeLengthUnitKind.millimetres,
        LengthUnit.cm => RecipeLengthUnitKind.centimetres,
        LengthUnit.inch => RecipeLengthUnitKind.inches,
      },
    );

RecipeExtentDto _extent(Extent e) => switch (e.type) {
      ExtentType.rounds => RecipeExtentDto(kind: RecipeExtentKind.rounds, count: e.count),
      ExtentType.untilStitches =>
        RecipeExtentDto(kind: RecipeExtentKind.untilStitches, count: e.count),
      ExtentType.until =>
        RecipeExtentDto(kind: RecipeExtentKind.until, measure: _measure(e.measure!)),
    };

RecipePhaseKind _phase(RecipePhase p) => switch (p) {
      RecipePhase.start => RecipePhaseKind.start,
      RecipePhase.body => RecipePhaseKind.body,
      RecipePhase.shaping => RecipePhaseKind.shaping,
      RecipePhase.finish => RecipePhaseKind.finish,
      RecipePhase.other => RecipePhaseKind.other,
    };

RecipeKindDto _kind(SegmentKind k) => switch (k) {
      SegmentKind.foundationChain => RecipeKindDto.foundationChain,
      SegmentKind.centreStart => RecipeKindDto.centreStart,
      SegmentKind.pickUp => RecipeKindDto.pickUp,
      SegmentKind.rounds => RecipeKindDto.rounds,
      SegmentKind.rows => RecipeKindDto.rows,
      SegmentKind.increase => RecipeKindDto.increase,
      SegmentKind.decrease => RecipeKindDto.decrease,
      SegmentKind.shortRows => RecipeKindDto.shortRows,
      SegmentKind.opening => RecipeKindDto.opening,
      SegmentKind.join => RecipeKindDto.join,
      SegmentKind.finish => RecipeKindDto.finish,
      SegmentKind.freeform => RecipeKindDto.freeform,
    };

RecipeSegmentDto _segment(RecipeSegment s) => RecipeSegmentDto(
      id: s.id,
      title: s.title,
      kind: _kind(s.kind),
      stitch: s.stitch == null
          ? null
          : RecipeStitchDto(
              notation: s.stitch!.notation,
              name: s.stitch!.name,
              reading: s.stitch!.reading == StitchReading.strict
                  ? RecipeReadingKind.strict
                  : RecipeReadingKind.lenient,
            ),
      stitches: s.stitches,
      skip: s.skip,
      chainJoin: switch (s.chainJoin) {
        null => null,
        ChainJoin.ring => RecipeChainJoinKind.ring,
        ChainJoin.flat => RecipeChainJoinKind.flat,
      },
      roundJoin: switch (s.roundJoin) {
        null => null,
        RoundJoin.spiral => RecipeRoundJoinKind.spiral,
        RoundJoin.joined => RecipeRoundJoinKind.joined,
      },
      perRound: s.perRound,
      increaseMethod: s.increaseMethod == null ? null : RecipeIncreaseKind.sameLoopTwice,
      decreaseMethod: switch (s.decreaseMethod) {
        null => null,
        DecreaseMethod.twoLoopsAtOnce => RecipeDecreaseKind.twoLoopsAtOnce,
        DecreaseMethod.skipALoop => RecipeDecreaseKind.skipALoop,
      },
      finishMethod: switch (s.finishMethod) {
        null => null,
        FinishMethod.closeTip => RecipeFinishKind.closeTip,
        FinishMethod.taperEdge => RecipeFinishKind.taperEdge,
      },
      extent: s.extent == null ? null : _extent(s.extent!),
      reference: s.reference,
      role: s.kind == SegmentKind.freeform ? _phase(s.role) : null,
      text: s.text,
      target: s.target == null ? null : _measure(s.target!),
      notes: s.notes,
      caution: s.caution,
    );

/// The phase of a reported segment, in the app's terms.
RecipePhase recipePhaseOf(RecipePhaseKind k) => switch (k) {
      RecipePhaseKind.start => RecipePhase.start,
      RecipePhaseKind.body => RecipePhase.body,
      RecipePhaseKind.shaping => RecipePhase.shaping,
      RecipePhaseKind.finish => RecipePhase.finish,
      RecipePhaseKind.other => RecipePhase.other,
    };

/// What the screens, the follow view and the PDF say Ply does and does not do with a recipe.
const String kRecipeCheckedText =
    'Ply checks the recipe\'s order, its numbers and each stitch\'s notation. It does not simulate '
    'the fabric: whether the piece fits, lies flat or closes neatly is for you to judge.';

/// What every step says when the recipe was too large to check.
const String kRecipeTooLargeStep = 'Not checked: the recipe is too large to check.';

/// Shortcuts over a checked recipe.
extension RecipeReportX on RecipeReportDto {
  /// The issues about segment [index], in the engine's order.
  List<RecipeIssueDto> issuesAt(int index) => [
        for (final i in issues)
          if (i.segment == index) i,
      ];

  /// The issues about fit measurement [index].
  List<RecipeIssueDto> fitIssuesAt(int index) => [
        for (final i in issues)
          if (i.fit == index) i,
      ];

  /// The issues about the recipe as a whole, and the too-large one wherever it is placed (when a
  /// recipe is too large nothing else was checked, so it belongs at the top).
  List<RecipeIssueDto> get recipeWide => [
        for (final i in issues)
          if ((i.segment == null && i.fit == null) || (tooLarge && i.code == 'too-large')) i,
      ];

  /// Every error, with its place.
  List<String> get errorTexts => [
        for (final i in issues)
          if (i.severity == RecipeSeverityKind.error) i.text,
      ];

  /// The report of segment [index], when the report covers it.
  RecipeSegmentReportDto? at(int index) =>
      index >= 0 && index < segments.length ? segments[index] : null;
}

/// The stitch a reported segment is worked in, in words (`Oslo, UO/UOO F1 (the project's stitch)`),
/// or null when it has none. [projectStitchName] is the project's display name for its stitch.
String? recipeStitchText(RecipeReportDto report, RecipeSegmentReportDto s,
    {required String projectStitchName}) {
  final project = s.stitchSource == RecipeStitchSourceKind.project;
  final reading = project ? report.projectStitch : s.stitch;
  if (reading == null || s.stitchSource == null) return null;
  final name = project ? projectStitchName : reading.name;
  final parts = <String>[
    if (name.trim().isNotEmpty) name.trim(),
    reading.notation,
  ];
  final notes = <String>[
    if (project) "the project's stitch",
    if (!project && reading.reading == RecipeReadingKind.lenient) 'read as written in a source',
    if (!reading.read) 'too long to read' else if (!reading.exact) 'the notation has problems',
  ];
  return notes.isEmpty ? parts.join(', ') : '${parts.join(', ')} (${notes.join('; ')})';
}

/// The stitch count after a reported segment, in words, or null when it does not apply (a note, or a
/// step outside a part).
String? recipeCountText(RecipeSegmentReportDto s) => switch (s.countKind) {
      RecipeCountKind.known =>
        '${s.count} ${s.count == 1 ? 'stitch' : 'stitches'} (from the recipe\'s numbers)',
      RecipeCountKind.unknown => 'Not stated in the recipe',
      RecipeCountKind.refused => 'Not counted: see the problems',
      RecipeCountKind.notApplicable => null,
    };

/// The instruction shown for segment [index]: the engine's written line; a free-text step's own
/// words; for a recipe too large to check, [kRecipeTooLargeStep]; or null while it is being
/// checked.
String? recipeWrittenText(RecipeReportDto? report, RecipeSegment seg, int index) {
  final s = report?.at(index);
  if (s != null) return s.written;
  if (seg.kind == SegmentKind.freeform) return seg.text;
  if (report != null && report.tooLarge) return kRecipeTooLargeStep;
  return null;
}

/// Whether Ply checked a reported segment, and what it found, in words. A free-text step's words
/// are never read, but its place in the recipe is checked, so its problems still show.
String recipeStatusText(RecipeReportDto report, int index) {
  if (report.tooLarge) {
    return 'Not checked: the recipe is too large to check (see the problem at the top)';
  }
  final s = report.at(index);
  final found = report.issuesAt(index);
  final errors = found.any((i) => i.severity == RecipeSeverityKind.error);
  final warnings = found.any((i) => i.severity == RecipeSeverityKind.warning);
  if (s == null || !s.checked) {
    if (errors) return 'Free text, not read by Ply: its place in the recipe has problems';
    if (warnings) return 'Free text, not read by Ply: has warnings';
    return 'Free text: Ply does not read or check it';
  }
  if (errors) return 'Checked by Ply: has problems';
  if (warnings) return 'Checked by Ply: has warnings';
  return 'Checked by Ply: no problems found';
}

/// A form's check that a text fits what the engine checks, measured as the engine measures it
/// (UTF-16 code units: Dart's `length`; an emoji counts as two), or null when it fits.
String? recipeTextTooLong(String? text, {int max = kMaxRecipeText}) {
  final n = (text ?? '').length;
  if (n <= max) return null;
  return 'Too long for Ply to check: at most ${_thousands(max)} characters, and this is '
      '${_thousands(n)} (some symbols, such as emoji, count as two).';
}

String _thousands(int n) {
  final digits = '$n';
  final out = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
    out.write(digits[i]);
  }
  return '$out';
}

/// `Step 3 of 11`, `Shaping`, `Opening` and the maker's title, for headings.
String recipeStepLabel(RecipeSegment s, int index, int total) {
  final title = s.title.trim();
  final kind = s.kind.label;
  final head = 'Step ${index + 1} of $total: ${s.phase.label}, $kind';
  return title.isEmpty ? head : '$head ($title)';
}
