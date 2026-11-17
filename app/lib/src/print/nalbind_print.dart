// The printable NALBINDING project (M9-02): name, stitch (name and notation exactly as written), the
// loop diagram as vector graphics from the same geometry the screen draws, the notation findings,
// notes, the recipe when the project has one (ADR 0017: each step in working order with its stitch,
// count, target, notes, caution and whether Ply checked it, then the recipe findings) and photos.
// [gatherNalbindPrint] reads the notation, checks the recipe and loads the photos once;
// [buildNalbindPrintDocument] is pure.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart' show BuildContext, StringCharacters;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/nalbind_repository.dart';
import '../data/readiness_repository.dart';
import '../data/photo_store.dart';
import '../models/nalbind_diagram_shapes.dart';
import '../models/nalbind_project.dart';
import '../models/nalbind_recipe.dart';
import '../models/nalbind_recipe_view.dart';
import '../rust/dto.dart' show SeverityKind;
import '../rust/nalbind_dto.dart';
import '../rust/nalbind_recipe_dto.dart';
import '../state/nalbind_providers.dart';
import '../widgets/nalbind_diagram_view.dart';
import 'knit_print.dart' show isoDate;
import 'print_document.dart';
import 'print_export.dart';

/// One project photo to print.
class PrintPhotoFile {
  const PrintPhotoFile({required this.name, required this.bytes});
  final String name;
  final Uint8List bytes;
}

/// Everything a printed nalbinding project is made from.
class NalbindPrintSource {
  const NalbindPrintSource({
    required this.project,
    required this.reading,
    required this.photos,
    required this.saved,
    required this.printedAt,
    this.recipe,
  });

  /// The project as the form holds it (notation trimmed, as a save stores it).
  final NalbindProject project;

  /// The strict (authoring) reading of the notation, or null when no notation is entered.
  final NotationReading? reading;

  /// The project's photos, in the order the project screen shows them (newest first).
  final List<PrintPhotoFile> photos;

  /// Whether the project has been saved (photos can only be attached after the first save).
  final bool saved;
  final DateTime printedAt;

  /// The engine's check of the project's recipe, or null for a note-only project.
  final RecipeReportDto? recipe;
}

/// Read [project]'s notation strictly (as the project screen does) and load the photos of the saved
/// project [id] (none when unsaved).
Future<NalbindPrintSource> gatherNalbindPrint(
  NalbindRepository repo, {
  required NalbindProject project,
  String? id,
  Directory? docsOverride,
  DateTime? now,
}) async {
  final notation = project.notation.trim();
  final reading = notation.isEmpty ? null : await repo.read(notation, strict: true);
  final recipe = project.recipe;
  final report = recipe == null ? null : await repo.checkRecipe(recipe, projectNotation: notation);
  final photos = <PrintPhotoFile>[];
  if (id != null) {
    final files = await PhotoStore(subdir: 'nalbinds', id: id, docsOverride: docsOverride).list();
    for (final f in files) {
      try {
        photos.add(PrintPhotoFile(name: f.uri.pathSegments.last, bytes: await f.readAsBytes()));
      } on FileSystemException {
        // Removed between listing and reading: there is nothing left to print.
      }
    }
  }
  return NalbindPrintSource(
    project: project,
    reading: reading,
    photos: photos,
    saved: id != null,
    printedAt: now ?? DateTime.now(),
    recipe: report,
  );
}

/// One notation finding as the project screen words it: `Error at "XYZ": message`.
String nalbindFindingText(String level, String message, String quote) {
  final q = _shorten(quote);
  return q.isEmpty ? '$level: $message' : '$level at "$q": $message';
}

/// The errors that make the export ask before printing: in the strict (authoring) reading every
/// notation problem is an error, plus the stitch's own validation errors, plus the recipe's errors.
List<String> nalbindPrintErrors(NalbindPrintSource s) => [
      ..._notationErrors(s),
      for (final e in s.recipe?.errorTexts ?? const <String>[]) 'Recipe, $e',
    ];

List<String> _notationErrors(NalbindPrintSource s) {
  final r = s.reading;
  if (r == null) return const [];
  return [
    for (final d in r.parsed.diagnostics)
      if (d.severity == NotationSeverityKind.error) nalbindFindingText('Error', d.message, d.text),
    for (final i in r.issues)
      if (i.severity == SeverityKind.error) nalbindFindingText('Error', i.message, ''),
  ];
}

/// The problems box's opening sentence: what the errors are in, and what that means.
String _problemsIntro(int notation, int recipe) {
  final n = notation + recipe;
  final errors = '$n ${n == 1 ? 'error' : 'errors'}';
  if (recipe == 0) {
    return 'Ply found $errors in the stitch notation, so the stitch and its sketch may not be '
        'what you meant.';
  }
  if (notation == 0) {
    return 'Ply found $errors in the recipe, so some steps may not be what you meant.';
  }
  return 'Ply found $errors in the stitch notation and the recipe, so the stitch, its sketch and '
      'some steps may not be what you meant.';
}

/// The printed recipe: what Ply checks, the fit, then every step in working order (a heading for
/// each part) with its written instruction and its facts.
List<PrintBlock> nalbindRecipeBlocks(NalbindRecipe recipe, RecipeReportDto report,
    {required String projectStitchName}) {
  final blocks = <PrintBlock>[
    const PrintParagraph(
        '$kRecipeCheckedText Steps marked free text are the author\'s own '
        'words, which Ply does not read.',
        style: PrintTextStyle.muted),
  ];
  if (report.fit.isNotEmpty) {
    blocks.add(PrintLines([for (final f in report.fit) PrintLine(f, label: 'Fit')]));
  }
  if (recipe.segments.isEmpty) {
    blocks.add(const PrintParagraph('The recipe has no steps yet.'));
    return blocks;
  }
  int? part;
  final total = recipe.segments.length;
  for (final (i, seg) in recipe.segments.indexed) {
    final s = report.at(i);
    if (s?.partNumber != null && s!.partNumber != part) {
      part = s.partNumber;
      final title = seg.title.trim();
      blocks.add(PrintParagraph(
          seg.phase == RecipePhase.start && title.isNotEmpty ? 'Part $part: $title' : 'Part $part',
          style: PrintTextStyle.strong));
    }
    final errors =
        report.issuesAt(i).where((x) => x.severity == RecipeSeverityKind.error).isNotEmpty;
    blocks.add(PrintLines([
      PrintLine(
        recipeWrittenText(report, seg, i) ?? '',
        label: recipeStepLabel(seg, i, total),
        flagged: errors,
      ),
    ]));
    final stitch =
        s == null ? null : recipeStitchText(report, s, projectStitchName: projectStitchName);
    final count = s == null ? null : recipeCountText(s);
    blocks.add(PrintFacts([
      if (stitch != null) PrintFact('Stitch', stitch),
      if (count != null) PrintFact('Stitches after', count),
      if (s?.target != null) PrintFact('Aim for', s!.target!),
      if (seg.notes.trim().isNotEmpty) PrintFact('Notes', seg.notes.trim()),
      if (seg.caution.trim().isNotEmpty) PrintFact('Watch out for', seg.caution.trim()),
      PrintFact('Checked', recipeStatusText(report, i)),
      if (recipe.done.contains(seg.id)) const PrintFact('Done', 'Ticked done'),
    ]));
  }
  return blocks;
}

/// Every recipe finding, placed (`Step 3 (Cuff)`, `Fit 1`, `Whole recipe`).
List<PrintIssue> nalbindRecipeIssues(NalbindRecipe recipe, RecipeReportDto report) => [
      for (final sev in const [
        RecipeSeverityKind.error,
        RecipeSeverityKind.warning,
        RecipeSeverityKind.info,
      ])
        for (final i in report.issues.where((x) => x.severity == sev))
          PrintIssue(
            severity: switch (sev) {
              RecipeSeverityKind.error => PrintIssueSeverity.error,
              RecipeSeverityKind.warning => PrintIssueSeverity.warning,
              RecipeSeverityKind.info => PrintIssueSeverity.note,
            },
            where: _recipePlace(recipe, i),
            message: i.message,
          ),
    ];

String _recipePlace(NalbindRecipe recipe, RecipeIssueDto i) {
  final seg = i.segment;
  if (seg != null) {
    final title = seg < recipe.segments.length ? recipe.segments[seg].title.trim() : '';
    return title.isEmpty ? 'Step ${seg + 1}' : 'Step ${seg + 1} ($title)';
  }
  final fit = i.fit;
  if (fit != null) {
    final label = fit < recipe.fit.length ? recipe.fit[fit].label.trim() : '';
    return label.isEmpty ? 'Fit ${fit + 1}' : 'Fit ${fit + 1} ($label)';
  }
  return 'Whole recipe';
}

/// Points per loop slot for the printed diagram: about 30 mm tall for a typical stitch.
const double _diagramScale = 32;

/// [diagram] as a vector drawing, from the geometry the on-screen view draws.
PrintDrawing nalbindDrawing(DiagramDto diagram, {required bool approximate}) {
  final scale = diagram.height > 0 ? _diagramScale : 1.0;
  PrintInk ink(DiagramInk i) => switch (i) {
        DiagramInk.thread => PrintInk.strong,
        DiagramInk.loop => PrintInk.accent,
        DiagramInk.faint => PrintInk.faint,
        DiagramInk.connection => PrintInk.highlight,
        DiagramInk.label => PrintInk.label,
      };
  return PrintDrawing(
    width: nalbindDiagramWidth(diagram, scale),
    height: nalbindDiagramHeight(diagram, scale),
    faded: approximate,
    label: approximate ? NalbindDiagramView.approximateLabel : null,
    caption: NalbindDiagramView.caption,
    shapes: [
      for (final s in nalbindDiagramShapes(diagram, scale))
        switch (s) {
          DiagramLine(:final from, :final to) =>
            PrintVectorLine(from.dx, from.dy, to.dx, to.dy, ink(s.ink)),
          DiagramArc(:final rect, :final startAngle, :final sweepAngle) => PrintVectorArc(
              rect.center.dx,
              rect.center.dy,
              rect.width / 2,
              rect.height / 2,
              startAngle,
              sweepAngle,
              ink(s.ink)),
          DiagramLabel(:final topLeft, :final text) =>
            PrintVectorText(topLeft.dx, topLeft.dy, text, size: 11),
        },
    ],
  );
}

/// The document for [s]. [withProblemsBox] is the user's draft-copy choice (ADR 0021): when the
/// notation has errors, a box at the top lists them. Without errors there is never a box.
PrintDocument buildNalbindPrintDocument(NalbindPrintSource s, {required bool withProblemsBox}) {
  final p = s.project;
  final r = s.reading;
  final errors = nalbindPrintErrors(s);
  final notationErrors = _notationErrors(s).length;
  final notation = p.notation.trim();

  final stitchBlocks = <PrintBlock>[];
  if (notation.isEmpty) {
    stitchBlocks.add(const PrintParagraph('No stitch chosen yet.'));
  } else {
    stitchBlocks.add(PrintFacts([
      PrintFact('Stitch', p.stitchName.isEmpty ? 'Custom stitch (typed notation)' : p.stitchName),
      PrintFact('Notation', notation),
      if (r != null && r.parsed.accepted && r.parsed.normalized != r.parsed.source)
        PrintFact('Reads as', r.parsed.normalized),
    ]));
    if (r != null) stitchBlocks.add(nalbindDrawing(r.diagram, approximate: !r.parsed.isExact));
  }

  final findings = <PrintIssue>[];
  if (r != null) {
    PrintIssue finding(PrintIssueSeverity sev, String message, String quote) => PrintIssue(
          severity: sev,
          where: _shorten(quote).isEmpty ? 'Notation' : '"${_shorten(quote)}"',
          message: message,
        );
    Iterable<NotationDiagnosticDto> at(NotationSeverityKind k) =>
        r.parsed.diagnostics.where((d) => d.severity == k);
    findings
      ..addAll(at(NotationSeverityKind.error)
          .map((d) => finding(PrintIssueSeverity.error, d.message, d.text)))
      ..addAll(r.issues
          .where((i) => i.severity == SeverityKind.error)
          .map((i) => finding(PrintIssueSeverity.error, i.message, '')))
      ..addAll(at(NotationSeverityKind.warning)
          .map((d) => finding(PrintIssueSeverity.warning, d.message, d.text)))
      ..addAll(r.issues
          .where((i) => i.severity == SeverityKind.warning)
          .map((i) => finding(PrintIssueSeverity.warning, i.message, '')))
      // Formatting notes change nothing about the stitch; on paper they are listed, not collapsed.
      ..addAll(at(NotationSeverityKind.info)
          .map((d) => finding(PrintIssueSeverity.note, d.message, d.text)));
  }

  final photoBlocks = <PrintBlock>[];
  if (!s.saved) {
    photoBlocks.add(const PrintParagraph('No photos: the project has not been saved yet.'));
  } else if (s.photos.isEmpty) {
    photoBlocks.add(const PrintParagraph('No photos.'));
  } else {
    for (final (i, ph) in s.photos.indexed) {
      photoBlocks.add(PrintPhoto(
        ph.bytes,
        caption: 'Photo ${i + 1} of ${s.photos.length}',
        unprintable: 'This photo could not be included: its file format cannot be printed. It is '
            'still in the project on the device.',
      ));
    }
  }

  return PrintDocument(
    title: p.name.trim().isEmpty ? 'Untitled' : p.name.trim(),
    kind: 'Nalbinding project',
    titleFacts: [PrintFact('Printed', isoDate(s.printedAt))],
    problemsBox: withProblemsBox && errors.isNotEmpty
        ? PrintNotice(
            level: PrintNoticeLevel.problem,
            title: 'This project has problems',
            intro: _problemsIntro(notationErrors, errors.length - notationErrors),
            lines: errors,
          )
        : null,
    sections: [
      PrintSection('Stitch', stitchBlocks),
      PrintSection('Notation findings', [
        if (r == null)
          const PrintParagraph('No notation to check.')
        else
          PrintIssues(findings, emptyText: 'No problems found in the notation.'),
      ]),
      PrintSection(
          'Notes', [PrintParagraph(p.notes.trim().isEmpty ? 'No notes.' : p.notes.trim())]),
      if (p.recipe != null && s.recipe != null) ...[
        PrintSection(
            'Recipe', nalbindRecipeBlocks(p.recipe!, s.recipe!, projectStitchName: p.stitchName)),
        PrintSection('Recipe findings', [
          PrintIssues(nalbindRecipeIssues(p.recipe!, s.recipe!),
              emptyText: 'Ply found no problems in the recipe.'),
        ]),
      ],
      PrintSection('Photos', photoBlocks),
    ],
  );
}

/// Run the print-or-share flow for the project the form holds ([id] when it has been saved): the
/// engine's readiness report (ADR 0021) decides whether it prints straight away, after an
/// acknowledgement, or only as a draft copy.
Future<void> printOrShareNalbindPdf(
  BuildContext context,
  WidgetRef ref, {
  required NalbindProject project,
  String? id,
}) {
  final repo = ref.read(nalbindRepositoryProvider);
  final readiness = ref.read(readinessRepositoryProvider);
  return printOrSharePdf(
    context,
    ref,
    noun: 'project',
    prepare: () async {
      final source = await gatherNalbindPrint(repo, project: project, id: id);
      return PdfExportJob(
        fileStem: project.name,
        readiness: await readiness.nalbind(project.notation, project.recipe),
        listNotChecked: true,
        document: ({required withProblemsBox}) =>
            buildNalbindPrintDocument(source, withProblemsBox: withProblemsBox),
      );
    },
  );
}

/// The project screen's quote shortening (a pasted paragraph would otherwise fill the row).
String _shorten(String quote) {
  if (quote.trim().isEmpty) return '';
  final chars = quote.characters;
  if (chars.length <= 40) return quote;
  return '${chars.take(39)}…';
}
