import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart';
import 'package:ply/src/models/draft_doc.dart' show MeasureUnit;
import 'package:ply/src/print/print_layout.dart';

// The page geometry rules of printed patterns: paper by units setting, page labels, and how a chart
// is split into page-sized parts without ever shrinking a cell below a readable size.

void main() {
  group('page setup', () {
    test('metric prints on A4, imperial on US Letter', () {
      final metric = PrintPageSetup.forUnit(MeasureUnit.centimeters);
      final imperial = PrintPageSetup.forUnit(MeasureUnit.inches);
      expect(metric.format.width, closeTo(PdfPageFormat.a4.width, 0.01));
      expect(metric.format.height, closeTo(PdfPageFormat.a4.height, 0.01));
      expect(metric.paperName, 'A4');
      expect(imperial.format.width, closeTo(612, 0.01));
      expect(imperial.format.height, closeTo(792, 0.01));
      expect(imperial.paperName, 'US Letter');
    });

    test('a paper picked in the print dialog keeps Ply margins', () {
      final s = PrintPageSetup.forFormat(PdfPageFormat.a5.copyWith(marginLeft: 0, marginRight: 0));
      expect(s.format.width, closeTo(PdfPageFormat.a5.width, 0.01));
      expect(s.margin, closeTo(15 * kMm, 0.01));
      expect(s.contentWidth, closeTo(PdfPageFormat.a5.width - 30 * kMm, 0.01));
    });

    test('page label', () {
      expect(pageLabel(2, 5), 'Page 2 of 5');
    });
  });

  group('layoutChart', () {
    const rule = ChartCellRule();

    test('a small chart fits on one part at up to the largest cell', () {
      final l = layoutChart(columns: 10, rows: 12, width: 500, height: 700);
      expect(l.cell, closeTo(rule.maxCell, 1e-9));
      expect(l.parts, [const ChartPart(colStart: 0, colEnd: 10, rowStart: 0, rowEnd: 12)]);
    });

    test('a chart that fits the width at a readable size is scaled to the width', () {
      final width = 40 * rule.minCell * 1.1; // 40 columns at 1.1x the minimum cell
      final l = layoutChart(columns: 40, rows: 10, width: width, height: 700);
      expect(l.cell, closeTo(width / 40, 1e-9));
      expect(l.cell, greaterThanOrEqualTo(rule.minCell));
      expect(l.parts.single.columns, 40);
    });

    test('a too-wide chart is split, never shrunk below the minimum cell', () {
      final l = layoutChart(columns: 100, rows: 10, width: 480, height: 700);
      expect(l.cell, closeTo(rule.splitCell, 1e-9));
      expect(l.cell, greaterThanOrEqualTo(rule.minCell));
      final perPart = (480 / rule.splitCell).floor();
      expect(l.parts.first.columns, perPart);
      // Every column is in exactly one part of the row band.
      expect(l.parts.fold<int>(0, (n, p) => n + p.columns), 100);
    });

    test('a long chart is split into row bands, bottom rows first', () {
      final l = layoutChart(columns: 20, rows: 200, width: 480, height: 600);
      final perPart = (600 / l.cell).floor();
      expect(l.parts.length, (200 / perPart).ceil());
      expect(l.parts.first.rowStart, 0);
      expect(l.parts.first.rowEnd, perPart);
      expect(l.parts.last.rowEnd, 200);
      for (var i = 1; i < l.parts.length; i++) {
        expect(l.parts[i].rowStart, l.parts[i - 1].rowEnd, reason: 'contiguous bands');
      }
      expect(l.parts.every((p) => p.rows * l.cell <= 600 + 1e-6), isTrue, reason: 'each fits');
    });

    test('startAtRight puts the rightmost columns (stitch 1) first, remainder at the far edge', () {
      final l = layoutChart(columns: 100, rows: 5, width: 480, height: 700, startAtRight: true);
      final perPart = (480 / rule.splitCell).floor();
      expect(l.parts.first.colEnd, 100);
      expect(l.parts.first.colStart, 100 - perPart);
      expect(l.parts.last.colStart, 0, reason: 'the narrow leftover band is the leftmost');
      final ltr = layoutChart(columns: 100, rows: 5, width: 480, height: 700);
      expect(ltr.parts.first.colStart, 0);
      expect(ltr.parts.last.colEnd, 100);
    });

    test('a wide and long chart: rows outer, columns inner', () {
      final l = layoutChart(columns: 100, rows: 100, width: 480, height: 600, startAtRight: true);
      final bands = l.parts.map((p) => p.rowStart).toSet().length;
      final perBand = l.parts.where((p) => p.rowStart == 0).length;
      expect(l.parts.length, bands * perBand);
      expect(l.parts.take(perBand).every((p) => p.rowStart == 0), isTrue);
    });

    test('an empty chart has no parts', () {
      expect(layoutChart(columns: 0, rows: 5, width: 480, height: 600).parts, isEmpty);
      expect(layoutChart(columns: 5, rows: 0, width: 480, height: 600).parts, isEmpty);
    });
  });
}
