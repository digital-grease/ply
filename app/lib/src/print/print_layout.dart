// Page geometry for printed patterns: the paper size from the units setting, the margins, and how a
// chart is split into page-sized parts. Pure math (no PDF objects), so the pagination rules are
// tested directly.

import 'package:pdf/pdf.dart';

import '../models/draft_doc.dart' show MeasureUnit;

/// One millimetre in PDF points.
const double kMm = PdfPageFormat.mm;

/// The paper and margins a document is laid out on.
class PrintPageSetup {
  const PrintPageSetup({required this.format, this.margin = 15 * kMm});

  /// The units setting picks the paper: metric prints on A4, imperial on US Letter.
  factory PrintPageSetup.forUnit(MeasureUnit unit) => PrintPageSetup(
        format: unit == MeasureUnit.centimeters ? PdfPageFormat.a4 : PdfPageFormat.letter,
      );

  /// A paper size chosen in the system print dialog, with Ply's margins.
  factory PrintPageSetup.forFormat(PdfPageFormat format) =>
      PrintPageSetup(format: PdfPageFormat(format.width, format.height));

  final PdfPageFormat format;

  /// The same margin on every side, in points.
  final double margin;

  /// The paper's name in plain words, for the title block.
  String get paperName {
    bool near(double a, double b) => (a - b).abs() < 1;
    final w = format.width, h = format.height;
    if (near(w, PdfPageFormat.a4.width) && near(h, PdfPageFormat.a4.height)) return 'A4';
    if (near(w, PdfPageFormat.letter.width) && near(h, PdfPageFormat.letter.height)) {
      return 'US Letter';
    }
    return '${(w / kMm).round()} x ${(h / kMm).round()} mm';
  }

  double get contentWidth => format.width - 2 * margin;
  double get contentHeight => format.height - 2 * margin;
}

/// The page footer's page label.
String pageLabel(int page, int pages) => 'Page $page of $pages';

/// Chart cell sizes on paper. A cell is never printed smaller than [minCell]: a chart too wide for
/// the page at that size is split into parts at [splitCell] instead of being shrunk.
class ChartCellRule {
  const ChartCellRule({
    this.minCell = 4 * kMm,
    this.maxCell = 6 * kMm,
    this.splitCell = 5 * kMm,
  });
  final double minCell;
  final double maxCell;
  final double splitCell;
}

/// One page-sized part of a chart: storage columns [colStart, colEnd) and rows [rowStart, rowEnd)
/// (row 0 at the bottom).
class ChartPart {
  const ChartPart({
    required this.colStart,
    required this.colEnd,
    required this.rowStart,
    required this.rowEnd,
  });
  final int colStart;
  final int colEnd;
  final int rowStart;
  final int rowEnd;

  int get columns => colEnd - colStart;
  int get rows => rowEnd - rowStart;

  @override
  bool operator ==(Object other) =>
      other is ChartPart &&
      other.colStart == colStart &&
      other.colEnd == colEnd &&
      other.rowStart == rowStart &&
      other.rowEnd == rowEnd;

  @override
  int get hashCode => Object.hash(colStart, colEnd, rowStart, rowEnd);

  @override
  String toString() => 'ChartPart(cols $colStart..$colEnd, rows $rowStart..$rowEnd)';
}

/// How a chart is laid out: the printed [cell] size and the parts in reading order.
class ChartLayout {
  const ChartLayout({required this.cell, required this.parts});
  final double cell;
  final List<ChartPart> parts;
}

/// Lay out a [columns] x [rows] chart in a [width] x [height] area (points) that already excludes
/// the axis gutters and a part's caption. The cell is as large as fits (up to [ChartCellRule.maxCell])
/// while the whole width fits at a readable size; otherwise the chart is split at
/// [ChartCellRule.splitCell]. Parts run from the bottom rows up (a chart is read upward); within a
/// band of rows, from the right edge when [startAtRight], else from the left. A band that does not
/// fill a part is the LAST one in its direction (the far edge), so the first part always starts at
/// stitch 1 / row 1.
ChartLayout layoutChart({
  required int columns,
  required int rows,
  required double width,
  required double height,
  bool startAtRight = false,
  ChartCellRule rule = const ChartCellRule(),
}) {
  if (columns <= 0 || rows <= 0) return const ChartLayout(cell: 0, parts: []);
  final fit = width / columns;
  final cell = fit >= rule.minCell ? (fit < rule.maxCell ? fit : rule.maxCell) : rule.splitCell;
  // At least one cell per part even on an absurdly small page (it is clipped, never shrunk).
  final perRow = (width / cell + 1e-9).floor().clamp(1, columns);
  final perColumn = (height / cell + 1e-9).floor().clamp(1, rows);

  final colBands = <(int, int)>[];
  if (startAtRight) {
    for (var end = columns; end > 0; end -= perRow) {
      colBands.add(((end - perRow).clamp(0, columns), end));
    }
  } else {
    for (var start = 0; start < columns; start += perRow) {
      colBands.add((start, (start + perRow).clamp(0, columns)));
    }
  }
  final parts = <ChartPart>[
    for (var r = 0; r < rows; r += perColumn)
      for (final (c0, c1) in colBands)
        ChartPart(colStart: c0, colEnd: c1, rowStart: r, rowEnd: (r + perColumn).clamp(0, rows)),
  ];
  return ChartLayout(cell: cell, parts: parts);
}
