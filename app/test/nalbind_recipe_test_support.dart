import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ply/src/data/nalbind_repository.dart';
import 'package:ply/src/models/nalbind_project.dart';
import 'package:ply/src/models/nalbind_recipe.dart';
import 'package:ply/src/rust/nalbind_dto.dart';
import 'package:ply/src/rust/nalbind_recipe_dto.dart';

import 'nalbind_test_support.dart';

// Shared helpers for the nalbinding recipe tests (ADR 0017): the acceptance fixtures under
// fixtures/nalbinding/recipes/ with their hand-derived oracles turned into the engine's report
// DTOs (so host tests stand in for the engine with the oracle), and a fake repository that keeps
// projects in memory and "checks" a recipe with a simple stand-in report.

/// Every recipe acceptance fixture.
const kRecipeFixtures = ['mitten-cuff-up', 'hat-centre-start', 'recipe-problems', 'recipe-empty'];

/// A `.plynal` migration fixture's text (`schema-v2/mitten-notes.plynal`).
String plynalMigration(String rel) => File('../fixtures/migrations/plynal/$rel').readAsStringSync();

String recipeFixtureText(String name, String ext) =>
    File('../fixtures/nalbinding/recipes/$name.$ext').readAsStringSync();

Map<String, dynamic> recipeOracle(String name) =>
    jsonDecode(recipeFixtureText(name, 'expect.json')) as Map<String, dynamic>;

NalbindProject recipeFixture(String name) =>
    NalbindProject.decode(recipeFixtureText(name, 'plynal'));

const _stitch = NalbindStitchDto(
  name: '',
  passes: [
    PassDto(steps: [StepKind.under, StepKind.over]),
    PassDto(steps: [StepKind.under, StepKind.over, StepKind.over]),
  ],
  connections: [ConnectionDto(side: ConnSideKind.front, count: 1)],
  twist: TwistKind.untwisted,
  alsoKnownAs: [],
  codes: [],
  note: '',
);

final _diagram = DiagramDto(
  width: 6,
  height: 2.6,
  baseline: 1.6,
  loops: const [LoopGlyphDto(x: 0.5, kind: LoopKindDto.underEngaged)],
  turns: Float32List.fromList([2.0]),
  connections: const [ConnArrowDto(x: 6, side: ConnSideKind.front, count: 1)],
);

T _byName<T extends Enum>(List<T> values, String name) =>
    values.firstWhere((v) => v.name == name, orElse: () => throw StateError('no $T $name'));

/// The oracle's `count` as the engine reports it.
(RecipeCountKind, int?) _count(Object? c) => switch (c) {
      final int n => (RecipeCountKind.known, n),
      'unknown' => (RecipeCountKind.unknown, null),
      'refused' => (RecipeCountKind.refused, null),
      'not-applicable' => (RecipeCountKind.notApplicable, null),
      _ => throw StateError('bad count $c'),
    };

/// The engine's reading of [notation], accepted or not and read or not, as an oracle says.
RecipeStitchReadingDto oracleStitchReading(
  String notation, {
  String name = '',
  required bool strict,
  required bool accepted,
  bool read = true,
}) =>
    RecipeStitchReadingDto(
      notation: notation,
      name: name,
      reading: strict ? RecipeReadingKind.strict : RecipeReadingKind.lenient,
      read: read,
      accepted: read && accepted,
      exact: read && accepted,
      normalized: read ? notation.toUpperCase() : '',
      connection: read ? RegExp(r'[FBM]\d+').allMatches(notation).map((m) => m[0]).join(' ') : '',
      problems: read && !accepted ? 1 : 0,
    );

/// The engine's report for fixture [name], built from its oracle.
RecipeReportDto oracleReport(String name) {
  final o = recipeOracle(name);
  final project = recipeFixture(name);
  final segments = <RecipeSegmentReportDto>[];
  for (final e in (o['segments'] as List).cast<Map<String, dynamic>>()) {
    final index = e['index'] as int;
    final stitch = e['stitch'] as Map<String, dynamic>?;
    final (countKind, count) = _count(e['count']);
    final isProject = stitch?['source'] == 'project';
    segments.add(RecipeSegmentReportDto(
      index: index,
      id: e['id'] as String,
      kind: _byName(RecipeKindDto.values, e['kind'] as String),
      phase: _byName(RecipePhaseKind.values, e['phase'] as String),
      partNumber: e['part'] as int?,
      stitchSource: stitch == null
          ? null
          : (isProject ? RecipeStitchSourceKind.project : RecipeStitchSourceKind.own),
      stitch: stitch == null || isProject
          ? null
          : oracleStitchReading(
              stitch['notation'] as String,
              name: project.recipe!.segments[index].stitch?.name ?? '',
              strict: stitch['reading'] == 'strict',
              accepted: stitch['accepted'] as bool,
              read: (stitch['read'] as bool?) ?? true,
            ),
      countKind: countKind,
      count: count,
      written: e['written'] as String,
      target: e['target'] as String?,
      checked: e['checked'] as bool,
    ));
  }
  final issues = [
    for (final i in (o['issues'] as List).cast<Map<String, dynamic>>())
      RecipeIssueDto(
        code: i['code'] as String,
        severity: _byName(RecipeSeverityKind.values, i['severity'] as String),
        segment: i['segment'] as int?,
        segmentId: i['segment'] == null ? null : project.recipe!.segments[i['segment'] as int].id,
        fit: i['fit'] as int?,
        message: _message(i['text'] as String, i['segment'] != null || i['fit'] != null),
        text: i['text'] as String,
      ),
  ];
  // The project's stitch is read once: accepted as the steps worked in it say (with none, as
  // these fixtures' project stitches read: exactly).
  final notation = o['project_notation'] as String;
  final projectUse = (o['segments'] as List)
      .cast<Map<String, dynamic>>()
      .map((e) => e['stitch'] as Map<String, dynamic>?)
      .where((st) => st?['source'] == 'project')
      .firstOrNull;
  return RecipeReportDto(
    segments: segments,
    issues: issues,
    fit: [for (final f in o['fit'] as List) f as String],
    projectStitch: notation.isEmpty
        ? null
        : oracleStitchReading(notation,
            strict: true, accepted: (projectUse?['accepted'] as bool?) ?? true),
    tooLarge: issues.any((i) => i.code == 'too-large'),
  );
}

/// The message without its place (`Step 3 (Cuff): x` is `x`).
String _message(String text, bool placed) {
  if (!placed) return text;
  final at = text.indexOf('): ');
  if (at >= 0 && text.startsWith(RegExp(r'(Step|Fit) \d+ \('))) return text.substring(at + 3);
  final colon = text.indexOf(': ');
  return text.substring(colon + 2);
}

/// A stand-in engine check for host UI tests: each segment's written line is `Written: <kind>`
/// (with its title when it has one), the project's stitch or its own, every count unknown, and an
/// issue for each id in [problems] (an error) and [warnings].
RecipeReportDto standInReport(
  NalbindRecipe recipe, {
  String projectNotation = 'UO/UOO F1',
  Map<String, String> problems = const {},
  Map<String, String> warnings = const {},
}) {
  final segments = <RecipeSegmentReportDto>[];
  final issues = <RecipeIssueDto>[];
  for (final (i, s) in recipe.segments.indexed) {
    final title = s.title.trim();
    final own = s.stitch;
    final hasStitch = own != null || (s.kind.usesStitch && projectNotation.isNotEmpty);
    segments.add(RecipeSegmentReportDto(
      index: i,
      id: s.id,
      kind: _byName(RecipeKindDto.values, s.kind.json),
      phase: _byName(RecipePhaseKind.values, s.phase.json),
      partNumber: 1,
      stitchSource: !hasStitch
          ? null
          : (own == null ? RecipeStitchSourceKind.project : RecipeStitchSourceKind.own),
      stitch: own == null
          ? null
          : oracleStitchReading(own.notation, name: own.name, strict: true, accepted: true),
      countKind: RecipeCountKind.unknown,
      count: null,
      written: s.kind == SegmentKind.freeform
          ? s.text
          : 'Written: ${s.kind.label}${title.isEmpty ? '' : ' ($title)'}',
      target: null,
      checked: s.kind != SegmentKind.freeform,
    ));
    final place = title.isEmpty ? 'Step ${i + 1}' : 'Step ${i + 1} ($title)';
    for (final (map, sev) in [
      (problems, RecipeSeverityKind.error),
      (warnings, RecipeSeverityKind.warning),
    ]) {
      final m = map[s.id];
      if (m != null) {
        issues.add(RecipeIssueDto(
          code: sev == RecipeSeverityKind.error ? 'test-error' : 'test-warning',
          severity: sev,
          segment: i,
          segmentId: s.id,
          message: m,
          text: '$place: $m',
        ));
      }
    }
  }
  return RecipeReportDto(
    segments: segments,
    issues: issues,
    fit: [for (final m in recipe.fit) m.label],
    projectStitch: projectNotation.isEmpty
        ? null
        : oracleStitchReading(projectNotation, strict: true, accepted: true),
    tooLarge: false,
  );
}

/// What the engine reports for a recipe past its limits: one too-large issue (placed at [segment]
/// when that is where the long text is) and nothing else checked.
RecipeReportDto tooLargeReport({int? segment, String text = 'The recipe is too large.'}) =>
    RecipeReportDto(
      segments: const [],
      issues: [
        RecipeIssueDto(
          code: 'too-large',
          severity: RecipeSeverityKind.error,
          segment: segment,
          message: text,
          text: text,
        ),
      ],
      fit: const [],
      tooLarge: true,
    );

/// A repository with projects in memory (no disk, no FFI): saves, reads, ticks, and a stand-in
/// recipe check ([report] decides it; [standInReport] by default).
class RecipeFakeRepo extends NalbindRepository {
  /// [projects] are stored as the app would read them back: through the real file form.
  RecipeFakeRepo({Map<String, NalbindProject>? projects})
      : projects = {
          for (final e in (projects ?? const <String, NalbindProject>{}).entries)
            e.key: NalbindProject.decode(jsonEncode(e.value.toJson())),
        };

  final Map<String, NalbindProject> projects;
  final checked = <NalbindRecipe>[];
  final ticks = <(String, String, bool)>[];
  int saves = 0;
  RecipeReportDto Function(NalbindRecipe recipe, String projectNotation)? report;

  @override
  Future<List<NalbindStitchDto>> builtins() async => const [];

  @override
  Future<DiagramDto> diagram(NalbindStitchDto dto) async => _diagram;

  @override
  Future<ParsedNotationDto> analyze(String notation, {required bool strict}) async =>
      reading(notation, _stitch, strict: strict);

  @override
  Future<List<NalbindIssueDto>> validate(NalbindStitchDto dto) async => const [];

  @override
  Future<RecipeReportDto> checkRecipe(NalbindRecipe recipe,
      {required String projectNotation}) async {
    checked.add(recipe);
    return (report ?? (r, n) => standInReport(r, projectNotation: n))(recipe, projectNotation);
  }

  @override
  Future<String> saveProject(NalbindProject project, {String? id}) async {
    saves++;
    final key = id ?? 'p${projects.length + 1}';
    // Through the real file form, so what "reopens" is what a save writes.
    projects[key] = NalbindProject.decode(jsonEncode(project.toJson()));
    return key;
  }

  @override
  Future<NalbindProject> readProject(String id) async => projects[id]!;

  @override
  Future<void> touchOpened(String id) async {}

  /// When true, writing a tick fails (a full disk, say).
  bool tickError = false;

  @override
  Future<bool> setSegmentDone(String id, String segmentId,
      {required bool done, required RecipeSegment expected}) async {
    ticks.add((id, segmentId, done));
    if (tickError) throw Exception('disk full');
    final saved = projects[id];
    final recipe = saved?.recipe;
    final onDisk = recipe?.segments.where((s) => s.id == segmentId).firstOrNull;
    if (saved == null || recipe == null || onDisk == null || onDisk != expected) {
      return false;
    }
    projects[id] = saved.withRecipe(recipe.withDone(segmentId, done));
    return true;
  }
}
