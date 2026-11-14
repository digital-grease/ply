// The printable NALBINDING project (M9-02): name, stitch (name and notation exactly as written), the
// loop diagram as vector graphics from the same geometry the screen draws, the notation findings,
// notes and photos. [gatherNalbindPrint] reads the notation and the photos once;
// [buildNalbindPrintDocument] is pure.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart' show BuildContext, StringCharacters;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/nalbind_repository.dart';
import '../data/photo_store.dart';
import '../models/nalbind_diagram_shapes.dart';
import '../models/nalbind_project.dart';
import '../rust/dto.dart' show SeverityKind;
import '../rust/nalbind_dto.dart';
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
  );
}

/// One notation finding as the project screen words it: `Error at "XYZ": message`.
String nalbindFindingText(String level, String message, String quote) {
  final q = _shorten(quote);
  return q.isEmpty ? '$level: $message' : '$level at "$q": $message';
}

/// The errors that make the export ask before printing: in the strict (authoring) reading every
/// notation problem is an error, plus the stitch's own validation errors.
List<String> nalbindPrintErrors(NalbindPrintSource s) {
  final r = s.reading;
  if (r == null) return const [];
  return [
    for (final d in r.parsed.diagnostics)
      if (d.severity == NotationSeverityKind.error) nalbindFindingText('Error', d.message, d.text),
    for (final i in r.issues)
      if (i.severity == SeverityKind.error) nalbindFindingText('Error', i.message, ''),
  ];
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

/// The document for [s]. [withProblemsBox] is the user's "print anyway" choice: when the notation
/// has errors, a box at the top lists them. Without errors there is never a box.
PrintDocument buildNalbindPrintDocument(NalbindPrintSource s, {required bool withProblemsBox}) {
  final p = s.project;
  final r = s.reading;
  final errors = nalbindPrintErrors(s);
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
            intro: 'Ply found ${errors.length} ${errors.length == 1 ? 'error' : 'errors'} in the '
                'stitch notation, so the stitch and its sketch may not be what you meant.',
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
      PrintSection('Photos', photoBlocks),
    ],
  );
}

/// Run the print-or-share flow for the project the form holds ([id] when it has been saved).
Future<void> printOrShareNalbindPdf(
  BuildContext context,
  WidgetRef ref, {
  required NalbindProject project,
  String? id,
}) {
  final repo = ref.read(nalbindRepositoryProvider);
  return printOrSharePdf(
    context,
    ref,
    noun: 'project',
    prepare: () async {
      final source = await gatherNalbindPrint(repo, project: project, id: id);
      return PdfExportJob(
        fileStem: project.name,
        errors: nalbindPrintErrors(source),
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
