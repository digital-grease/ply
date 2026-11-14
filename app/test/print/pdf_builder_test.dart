import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart';
import 'package:ply/src/models/draft_doc.dart' show MeasureUnit;
import 'package:ply/src/print/pdf_builder.dart';
import 'package:ply/src/print/print_document.dart';
import 'package:ply/src/print/print_layout.dart';

import 'print_test_support.dart';

// The craft-agnostic PDF builder, checked by reading the PDF back: sections and title block, page
// numbering, paper size by units, pagination of long text and of a large chart (numbers repeated on
// every part), the problems box, notices for unprintable characters, and photos (metadata removed).

final _a4 = PrintPageSetup.forUnit(MeasureUnit.centimeters);
final _letter = PrintPageSetup.forUnit(MeasureUnit.inches);

Future<PdfReadBack> _read(PrintDocument doc, {PrintPageSetup? page}) async =>
    PdfReadBack(await buildPrintPdf(doc, page: page ?? _a4, fonts: testFonts(), compress: false));

PrintChart _chart(int cols, int rows, {List<PrintChartBox> boxes = const []}) => PrintChart(
      raster: solidRaster(cols * 4, rows * 4),
      columns: cols,
      rows: rows,
      columnNumbers: [for (var i = 0; i < cols; i++) cols - i],
      rowNumbers: [for (var r = 0; r < rows; r++) r + 1],
      rowNumberSides: [for (var r = 0; r < rows; r++) r.isEven ? PrintSide.right : PrintSide.left],
      boxes: boxes,
      startAtRight: true,
      rowsName: 'Rows',
      columnsName: 'stitches',
    );

void main() {
  test('the title block and every section heading are printed', () async {
    final pdf = await _read(const PrintDocument(
      title: 'Harbor mittens',
      kind: 'Knitting pattern',
      titleFacts: [PrintFact('Printed', '2026-11-12')],
      sections: [
        PrintSection('Notes', [PrintParagraph('Use the softest wool you have.')]),
        PrintSection('Materials and gauge', [
          PrintFacts([PrintFact('Gauge', '18 sts and 24 rows = 4 in')]),
        ]),
        PrintSection('Stitch key', [
          PrintLegend([PrintLegendEntry(code: 'k', name: 'Knit', meaning: 'Knit stitch.')]),
        ]),
        PrintSection('Written instructions', [
          PrintLines([PrintLine('Cast on 4 sts.'), PrintLine('k4', label: 'Row 1 (RS)')]),
        ]),
        PrintSection(
            'Problems', [PrintIssues([], emptyText: 'Ply found no problems in this pattern.')]),
      ],
    ));
    final text = pdf.text;
    for (final s in [
      'Harbor mittens',
      'Knitting pattern',
      'Printed: 2026-11-12',
      'Notes',
      'Use the softest wool you have.',
      'Materials and gauge',
      'Gauge 18 sts and 24 rows = 4 in',
      'Stitch key',
      'k Knit Knit stitch.',
      'Written instructions',
      'Cast on 4 sts.',
      'Row 1 (RS): k4',
      'Problems',
      'Ply found no problems in this pattern.',
    ]) {
      expect(text, contains(s));
    }
    expect(pdf.pageCount, 1);
    expect(pdf.pages.single, contains('Page 1 of 1'));
  });

  test('the paper size follows the units setting', () async {
    const doc = PrintDocument(title: 'T', kind: 'K');
    final a4 = await _read(doc, page: _a4);
    final letter = await _read(doc, page: _letter);
    expect(a4.mediaBoxes.single[2], closeTo(PdfPageFormat.a4.width, 0.01));
    expect(a4.mediaBoxes.single[3], closeTo(PdfPageFormat.a4.height, 0.01));
    expect(letter.mediaBoxes.single[2], closeTo(612, 0.01));
    expect(letter.mediaBoxes.single[3], closeTo(792, 0.01));
  });

  test('long text runs onto further pages, every page numbered "Page n of N"', () async {
    final notes = [for (var i = 1; i <= 260; i++) 'Note line $i about the yarn.'].join('\n');
    final pdf = await _read(PrintDocument(
      title: 'Long notes',
      kind: 'Knitting pattern',
      sections: [
        PrintSection('Notes', [PrintParagraph(notes)])
      ],
    ));
    expect(pdf.pageCount, greaterThan(2));
    expect(pdf.pages.first, contains('Note line 1 about the yarn.'));
    expect(pdf.pages.last, contains('Note line 260 about the yarn.'));
    for (var i = 0; i < pdf.pageCount; i++) {
      expect(pdf.pages[i], contains('Page ${i + 1} of ${pdf.pageCount}'));
      expect(pdf.pages[i], contains('Long notes'), reason: 'the footer names the pattern');
    }
    // Nothing lost or duplicated across the page breaks.
    for (var i = 1; i <= 260; i++) {
      expect(RegExp('Note line $i about').allMatches(pdf.text).length, 1, reason: 'line $i');
    }
  });

  test('a large chart is split into parts, each with its own row and stitch numbers', () async {
    const cols = 60, rows = 150;
    final pdf = await _read(PrintDocument(
      title: 'Big chart',
      kind: 'Knitting pattern',
      sections: [
        PrintSection('Chart', [
          _chart(cols, rows, boxes: const [
            PrintChartBox(colStart: 0, colEnd: 60, rowLo: 0, rowHi: 149, label: '×3'),
          ]),
        ]),
      ],
    ));
    final captions = RegExp(r'Part (\d+) of (\d+): Rows (\d+) to (\d+), stitches (\d+) to (\d+)')
        .allMatches(pdf.text)
        .toList();
    expect(captions.length, greaterThan(2));
    final count = int.parse(captions.first[2]!);
    expect(captions.length, count);
    expect(captions.first[3], '1', reason: 'the first part starts at row 1 (the bottom)');
    expect(captions.first[5], '1', reason: 'the first part starts at stitch 1 (the right edge)');

    // The parts tile the chart: every row and every stitch is covered, and a part is never wider
    // than what fits at the split cell size (never shrunk below the minimum cell).
    final perPart = ((_a4.contentWidth - 34) / const ChartCellRule().splitCell).floor();
    final rowsSeen = <int>{}, colsSeen = <int>{};
    for (final c in captions) {
      final (r0, r1, c0, c1) =
          (int.parse(c[3]!), int.parse(c[4]!), int.parse(c[5]!), int.parse(c[6]!));
      expect(c1 - c0 + 1, lessThanOrEqualTo(perPart));
      for (var r = r0; r <= r1; r++) {
        rowsSeen.add(r);
      }
      for (var k = c0; k <= c1; k++) {
        colsSeen.add(k);
      }
      // That part's page carries the numbers of ITS rows and stitches, and the repeat label.
      final page = pdf.pages.firstWhere((p) => p.contains('Part ${c[1]} of '));
      final words = page.split(' ').toSet();
      for (var r = r0; r <= r1; r++) {
        expect(words, contains('$r'), reason: 'row $r on part ${c[1]}');
      }
      for (var k = c0; k <= c1; k++) {
        expect(words, contains('$k'), reason: 'stitch $k on part ${c[1]}');
      }
      expect(page, contains('×3'), reason: 'every part a box runs through is labelled');
    }
    expect(rowsSeen, {for (var r = 1; r <= rows; r++) r});
    expect(colsSeen, {for (var k = 1; k <= cols; k++) k});
    expect(pdf.pageCount, greaterThanOrEqualTo(count));
  });

  test('the problems box prints its title, intro and lines, capped with a pointer to the rest',
      () async {
    final pdf = await _read(PrintDocument(
      title: 'Faulty',
      kind: 'Knitting pattern',
      problemsBox: PrintNotice(
        level: PrintNoticeLevel.problem,
        title: 'This pattern has problems',
        intro: 'Ply found 20 errors in this pattern.',
        lines: [
          for (var i = 1; i <= 20; i++) 'Row $i consumes 3 stitches but row ${i - 1} produced 2'
        ],
      ),
    ));
    expect(pdf.text, contains('This pattern has problems'));
    expect(pdf.text, contains('Ply found 20 errors in this pattern.'));
    expect(pdf.text, contains('Row 1 consumes 3 stitches'));
    expect(pdf.text, contains('and 7 more, listed under Problems.'));
  });

  test('characters the font cannot draw are named in a notice, not silently dropped', () async {
    // (The PDF library also prints a debug hint per missing glyph; keep the test output quiet.)
    final pdf = await runZoned(
      () => _read(const PrintDocument(title: 'Mittens 字', kind: 'Knitting pattern')),
      zoneSpecification: ZoneSpecification(print: (_, __, ___, ____) {}),
    );
    expect(pdf.text, contains('Some characters cannot be printed'));
    expect(pdf.text, contains('show as empty boxes in this PDF'));
    // Letters the font does have print as themselves.
    final ok = await _read(const PrintDocument(title: 'Åsle sokker ×2 → ø', kind: 'Nalbinding'));
    expect(ok.text, contains('Åsle sokker ×2 → ø'));
    expect(ok.text, isNot(contains('Some characters cannot be printed')));
  });

  group('photos', () {
    test('a JPEG is embedded as it is, minus its EXIF, GPS and comment', () async {
      final doc = PrintDocument(title: 'P', kind: 'K', sections: [
        PrintSection(
            'Photos', [PrintPhoto(jpegWithExif, caption: 'Photo 1 of 1', unprintable: 'x')]),
      ]);
      // Compressed: a JPEG goes in as raw DCT data, so its bytes are searchable.
      final bytes = await buildPrintPdf(doc, page: _a4, fonts: testFonts());
      expect(containsBytes(bytes, ascii.encode('PlyTestCam')), isFalse, reason: 'camera make');
      expect(containsBytes(bytes, ascii.encode('secret-comment')), isFalse, reason: 'comment');
      expect(containsBytes(bytes, ascii.encode('Exif')), isFalse, reason: 'EXIF block');
      // The compressed scan itself is copied byte for byte (no re-encoding).
      final scan = jpegWithExif.sublist(jpegWithExif.length - 40);
      expect(containsBytes(bytes, scan), isTrue);
      final pdf = await _read(doc);
      expect(pdf.text, contains('Photo 1 of 1'));
      // The EXIF orientation (rotate 90) survives the stripping: the 8x6 photo is placed with a
      // quarter-turn matrix into a portrait (taller than wide) box.
      final plain = String.fromCharCodes(
          await buildPrintPdf(doc, page: _a4, fonts: testFonts(), compress: false));
      final m = RegExp(r'q ([-\d.]+) ([-\d.]+) ([-\d.]+) ([-\d.]+) [-\d.]+ [-\d.]+ cm /I\d+ Do')
          .firstMatch(plain)!;
      final (a, b, c, d) =
          (double.parse(m[1]!), double.parse(m[2]!), double.parse(m[3]!), double.parse(m[4]!));
      expect((a, d), (0.0, 0.0), reason: 'a rotation');
      expect(b.abs(), greaterThan(c.abs()), reason: 'drawn taller than wide');
    });

    test('a PNG prints; an unreadable format says so instead of vanishing', () async {
      final pdf = await _read(PrintDocument(title: 'P', kind: 'K', sections: [
        PrintSection('Photos', [
          PrintPhoto(tinyPng, caption: 'Photo 1 of 2', unprintable: 'unused'),
          PrintPhoto(heicLike,
              caption: 'Photo 2 of 2', unprintable: 'This photo could not be included.'),
        ]),
      ]));
      expect(pdf.text, contains('Photo 1 of 2'));
      expect(pdf.text, contains('Photo 2 of 2'));
      expect(pdf.text, contains('This photo could not be included.'));
      expect(pdf.text, isNot(contains('unused')));
    });
  });

  test('a vector drawing prints its label, text and caption; a very wide one is split', () async {
    final wide = PrintDrawing(
      width: 2000,
      height: 60,
      label: 'Approximate sketch',
      caption: 'A sketch.',
      shapes: [
        const PrintVectorLine(0, 30, 2000, 30, PrintInk.strong),
        const PrintVectorArc(100, 30, 10, 20, math.pi, math.pi, PrintInk.accent),
        for (var x = 50.0; x < 2000; x += 400) PrintVectorText(x, 35, 'F$x'),
      ],
      faded: true,
    );
    final pdf = await _read(PrintDocument(title: 'D', kind: 'K', sections: [
      PrintSection('Stitch', [wide]),
    ]));
    expect(pdf.text, contains('Approximate sketch'));
    expect(pdf.text, contains('A sketch.'));
    for (var x = 50.0; x < 2000; x += 400) {
      expect(pdf.text, contains('F$x'), reason: 'labels in every strip');
    }
  });
}
