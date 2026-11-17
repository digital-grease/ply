import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:ply/src/data/nalbind_repository.dart';
import 'package:ply/src/models/draft_doc.dart' show MeasureUnit;
import 'package:ply/src/models/nalbind_diagram_shapes.dart';
import 'package:ply/src/models/nalbind_project.dart';
import 'package:ply/src/print/nalbind_print.dart';
import 'package:ply/src/print/pdf_builder.dart';
import 'package:ply/src/print/print_document.dart';
import 'package:ply/src/print/print_layout.dart';
import 'package:ply/src/rust/dto.dart' show SeverityKind;
import 'package:ply/src/rust/nalbind_dto.dart';
import 'package:ply/src/widgets/nalbind_diagram_view.dart';

import '../nalbind_test_support.dart';
import 'print_test_support.dart';

// The printed NALBINDING project: the stitch name and the notation exactly as written, the loop
// diagram as vector shapes from the on-screen geometry with its schematic caption (and the
// Approximate label when the reading is not exact), the notation findings, notes, and the photos in
// the order the project shows them.

const _oslo = NalbindStitchDto(
  name: 'Oslo',
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
  loops: const [
    LoopGlyphDto(x: 0.5, kind: LoopKindDto.underEngaged),
    LoopGlyphDto(x: 1.5, kind: LoopKindDto.overEngaged),
    LoopGlyphDto(x: 2.5, kind: LoopKindDto.overSkipped),
    LoopGlyphDto(x: 3.5, kind: LoopKindDto.noLoop),
  ],
  turns: Float32List.fromList([2.0]),
  connections: const [ConnArrowDto(x: 5, side: ConnSideKind.front, count: 1)],
);

/// Reads notation like the engine for the three inputs the tests use (no FFI).
class FakeReadRepo extends NalbindRepository {
  FakeReadRepo({this.issues = const []});
  final List<NalbindIssueDto> issues;

  @override
  Future<ParsedNotationDto> analyze(String notation, {required bool strict}) async =>
      switch (notation) {
        'UO/XYZ' => badReading(_oslo, strict: strict),
        'uo/uoo f1' => lowercaseReading(_oslo, strict: strict),
        _ => reading(notation, _oslo, strict: strict),
      };

  @override
  Future<DiagramDto> diagram(NalbindStitchDto dto) async => _diagram;

  @override
  Future<List<NalbindIssueDto>> validate(NalbindStitchDto dto) async => issues;
}

NalbindProject _project(
        {String notation = 'UO/UOO F1', String stitchName = 'Oslo', String notes = ''}) =>
    NalbindProject(name: 'Winter socks', notation: notation, stitchName: stitchName, notes: notes);

Future<NalbindPrintSource> _source(NalbindProject project,
        {String? id, Directory? docs, NalbindRepository? repo}) =>
    gatherNalbindPrint(repo ?? FakeReadRepo(),
        project: project, id: id, docsOverride: docs, now: DateTime(2026, 11, 12));

PrintSection _section(PrintDocument d, String heading) =>
    d.sections.firstWhere((s) => s.heading == heading);

Map<String, String> _facts(PrintDocument d) => {
      for (final f in _section(d, 'Stitch').blocks.whereType<PrintFacts>().single.facts)
        f.label: f.value,
    };

void main() {
  group('stitch', () {
    test('name and notation exactly as written; what it reads as when tidied', () async {
      final doc = buildNalbindPrintDocument(
          await _source(_project(notation: 'uo/uoo f1', stitchName: '')),
          withProblemsBox: false);
      final facts = _facts(doc);
      expect(facts['Notation'], 'uo/uoo f1', reason: 'verbatim, not normalized');
      expect(facts['Reads as'], 'UO/UOO F1');
      expect(facts['Stitch'], 'Custom stitch (typed notation)');
      final named =
          _facts(buildNalbindPrintDocument(await _source(_project()), withProblemsBox: false));
      expect(named['Stitch'], 'Oslo');
      expect(named['Notation'], 'UO/UOO F1');
      expect(named.containsKey('Reads as'), isFalse);
    });

    test('the diagram carries the schematic caption; an exact reading is not labelled', () async {
      final doc = buildNalbindPrintDocument(await _source(_project()), withProblemsBox: false);
      final drawing = _section(doc, 'Stitch').blocks.whereType<PrintDrawing>().single;
      expect(
          drawing.caption, "Sketch of one stitch's needle path, not a picture of finished fabric.");
      expect(drawing.label, isNull);
      expect(drawing.faded, isFalse);
    });

    test('a reading that is not exact is labelled Approximate and drawn faded', () async {
      final doc = buildNalbindPrintDocument(await _source(_project(notation: 'UO/XYZ')),
          withProblemsBox: false);
      final drawing = _section(doc, 'Stitch').blocks.whereType<PrintDrawing>().single;
      expect(drawing.label,
          'Approximate: the notation was not read exactly, so this sketch may be wrong.');
      expect(drawing.label, NalbindDiagramView.approximateLabel);
      expect(drawing.faded, isTrue);
      expect(drawing.caption, NalbindDiagramView.caption);
    });

    test('no notation: says no stitch is chosen, and no diagram', () async {
      final doc = buildNalbindPrintDocument(await _source(_project(notation: '  ')),
          withProblemsBox: false);
      expect(_section(doc, 'Stitch').blocks.single, isA<PrintParagraph>());
      expect(
          (_section(doc, 'Stitch').blocks.single as PrintParagraph).text, 'No stitch chosen yet.');
      expect((_section(doc, 'Notation findings').blocks.single as PrintParagraph).text,
          'No notation to check.');
    });
  });

  group('diagram geometry', () {
    test('the printed drawing is the on-screen geometry, shape for shape', () {
      final drawing = nalbindDrawing(_diagram, approximate: false);
      final shapes = nalbindDiagramShapes(_diagram, 32);
      expect(drawing.shapes.length, shapes.length);
      expect(drawing.width, closeTo(6 * 32, 1e-9));
      expect(drawing.height, closeTo(2.6 * 32, 1e-9));
      // The working thread first, full width.
      final thread = drawing.shapes.first as PrintVectorLine;
      expect(thread.ink, PrintInk.strong);
      expect((thread.x1, thread.x2), (0.0, 6 * 32.0));
      // One arch per drawn loop (no arch for "no loop"); the skipped loop is faint.
      final arcs = drawing.shapes.whereType<PrintVectorArc>().toList();
      expect(arcs.length, 3);
      expect(arcs.map((a) => a.ink), [PrintInk.accent, PrintInk.accent, PrintInk.faint]);
      expect(arcs.first.startAngle, math.pi);
      expect(arcs.first.sweepAngle, math.pi);
      // The connection arrow is labelled.
      expect(drawing.shapes.whereType<PrintVectorText>().map((t) => t.text), ['F1']);
    });

    test('shape order matches the painter: thread, arches, over-threads, turns, connections', () {
      final shapes = nalbindDiagramShapes(_diagram, 10);
      expect(shapes.first, isA<DiagramLine>());
      expect(shapes.first.ink, DiagramInk.thread);
      expect(shapes.sublist(1, 4).every((s) => s is DiagramArc), isTrue);
      expect(shapes[4].ink, DiagramInk.thread,
          reason: 'the over-engaged loop gets the thread on top');
      expect(shapes.last, isA<DiagramLabel>());
      expect(connectionLabel(const ConnArrowDto(x: 0, side: ConnSideKind.back, count: 2)), 'B2');
    });
  });

  group('notation findings', () {
    test('errors first, each with its quoted text; formatting notes listed', () async {
      final bad = buildNalbindPrintDocument(await _source(_project(notation: 'UO/XYZ')),
          withProblemsBox: false);
      final list = _section(bad, 'Notation findings').blocks.whereType<PrintIssues>().single.issues;
      expect(list.every((i) => i.severity == PrintIssueSeverity.error), isTrue);
      expect(list.map((i) => i.where), ['"/"', '"XYZ"']);
      expect(list.last.message, 'unexpected characters `XYZ`; kept verbatim as an opaque token');

      final tidy = buildNalbindPrintDocument(await _source(_project(notation: 'uo/uoo f1')),
          withProblemsBox: false);
      final notes =
          _section(tidy, 'Notation findings').blocks.whereType<PrintIssues>().single.issues;
      expect(notes.length, 3);
      expect(notes.every((i) => i.severity == PrintIssueSeverity.note), isTrue);
      expect(notes.first.where, '"uo"');
    });

    test('the stitch\'s own validation issues join at their severity', () async {
      final repo = FakeReadRepo(issues: const [
        NalbindIssueDto(
            code: 'test', severity: SeverityKind.warning, message: 'a pass has no engaged loop'),
      ]);
      final doc =
          buildNalbindPrintDocument(await _source(_project(), repo: repo), withProblemsBox: false);
      final list = _section(doc, 'Notation findings').blocks.whereType<PrintIssues>().single.issues;
      expect(list.single.severity, PrintIssueSeverity.warning);
      expect(list.single.where, 'Notation');
    });

    test('a clean notation says so', () async {
      final doc = buildNalbindPrintDocument(await _source(_project()), withProblemsBox: false);
      final block = _section(doc, 'Notation findings').blocks.whereType<PrintIssues>().single;
      expect(block.issues, isEmpty);
      expect(block.emptyText, 'No problems found in the notation.');
    });

    test('errors block silently printing; the box lists them only on "print anyway"', () async {
      final bad = await _source(_project(notation: 'UO/XYZ'));
      expect(nalbindPrintErrors(bad), [
        'Error at "/": turn `/` comes after the last needle step; dropped',
        'Error at "XYZ": unexpected characters `XYZ`; kept verbatim as an opaque token',
      ]);
      final box = buildNalbindPrintDocument(bad, withProblemsBox: true).problemsBox!;
      expect(box.title, 'This project has problems');
      expect(box.lines, nalbindPrintErrors(bad));
      expect(buildNalbindPrintDocument(bad, withProblemsBox: false).problemsBox, isNull);
      final clean = await _source(_project());
      expect(nalbindPrintErrors(clean), isEmpty);
      expect(buildNalbindPrintDocument(clean, withProblemsBox: true).problemsBox, isNull);
    });
  });

  group('notes and photos', () {
    late Directory docs;
    setUp(() => docs = Directory.systemTemp.createTempSync('ply_print_photos'));
    tearDown(() => docs.deleteSync(recursive: true));

    File photo(String name, List<int> bytes, DateTime modified) {
      final dir = Directory(p.join(docs.path, 'nalbinds', 'p1.photos'))
        ..createSync(recursive: true);
      return File(p.join(dir.path, name))
        ..writeAsBytesSync(bytes)
        ..setLastModifiedSync(modified);
    }

    test('photos print in the order the project shows them (newest first), each captioned',
        () async {
      photo('old.jpg', jpegWithExif, DateTime(2026, 1, 1));
      photo('new.png', tinyPng, DateTime(2026, 6, 1));
      final s = await _source(_project(notes: 'Cast on 30 loops.\nIncrease at round 6.'),
          id: 'p1', docs: docs);
      expect(s.photos.map((f) => f.name), ['new.png', 'old.jpg']);
      final doc = buildNalbindPrintDocument(s, withProblemsBox: false);
      final photos = _section(doc, 'Photos').blocks.cast<PrintPhoto>();
      expect(photos.map((ph) => ph.caption), ['Photo 1 of 2', 'Photo 2 of 2']);
      expect(photos.first.bytes, tinyPng);
      expect((_section(doc, 'Notes').blocks.single as PrintParagraph).text,
          'Cast on 30 loops.\nIncrease at round 6.');
    });

    test('an unsaved project, or one without photos, says so', () async {
      final unsaved = buildNalbindPrintDocument(await _source(_project()), withProblemsBox: false);
      expect((_section(unsaved, 'Photos').blocks.single as PrintParagraph).text,
          'No photos: the project has not been saved yet.');
      expect((_section(unsaved, 'Notes').blocks.single as PrintParagraph).text, 'No notes.');
      final none = buildNalbindPrintDocument(await _source(_project(), id: 'p1', docs: docs),
          withProblemsBox: false);
      expect((_section(none, 'Photos').blocks.single as PrintParagraph).text, 'No photos.');
    });

    test('the whole project prints, photos included, with no em dashes', () async {
      photo('a.jpg', jpegWithExif, DateTime(2026, 1, 1));
      photo('b.heic', heicLike, DateTime(2026, 2, 1));
      final s = await _source(_project(notation: 'UO/XYZ', notes: 'Åsle-style cuff.'),
          id: 'p1', docs: docs);
      final pdf = PdfReadBack(await buildPrintPdf(
        buildNalbindPrintDocument(s, withProblemsBox: true),
        page: PrintPageSetup.forUnit(MeasureUnit.centimeters),
        fonts: testFonts(),
        compress: false,
      ));
      for (final t in [
        'Winter socks',
        'Nalbinding project',
        'This project has problems',
        'Stitch Oslo',
        'Notation UO/XYZ',
        'Approximate: the notation was not read exactly, so this sketch may be wrong.',
        "Sketch of one stitch's needle path, not a picture of finished fabric.",
        'F1',
        'Notation findings',
        'Åsle-style cuff.',
        'Photo 1 of 2',
        'Photo 2 of 2',
        'This photo could not be included: its file format cannot be printed.',
        'Page 1 of',
      ]) {
        expect(pdf.text, contains(t));
      }
      expect(pdf.text, isNot(contains('\u2014')));
      expect(pdf.mediaBoxes.first[2], closeTo(595.28, 0.01), reason: 'metric: A4');
    });
  });
}
