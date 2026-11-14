// Lays a [PrintDocument] out as a PDF with the `pdf` package (Apache-2.0; owner decision
// 2026-11-12): a title block, the problems box, headed sections, keys, facts, notices, instructions,
// charts split into page-sized parts, vector drawings and photos, on A4 or US Letter with a
// "Page 2 of 5" footer. Craft-agnostic: everything craft-specific is already in the document (the
// weaving grids are drawn by the part file pdf_book_draft.dart).
//
// Offline by construction: the fonts are the bundled [PlyPdfFonts], images come from the document's
// own bytes, and nothing here (or in the `pdf` package code it calls) opens a network connection.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'book_draft_layout.dart';
import 'jpeg_metadata.dart';
import 'pdf_fonts.dart';
import 'print_document.dart';
import 'print_layout.dart';

part 'pdf_book_draft.dart';

/// Ink colors, chosen to print well in black and white (meaning is always in the text too).
const _ink = PdfColor.fromInt(0xFF1A1A1A);
const _muted = PdfColor.fromInt(0xFF555555);
const _rule = PdfColor.fromInt(0xFF9E9E9E);
const _problem = PdfColor.fromInt(0xFFB00020);
const _caution = PdfColor.fromInt(0xFF8A5A00);
const _boxLine = PdfColor.fromInt(0xFF1A1A1A);

const double _body = 10.5;
const double _small = 8.5;

/// Height reserved for the page footer (the MultiPage footer widget is laid out inside it).
const double _footerHeight = 22;

/// Chart gutters: room for a three-digit row number either side and a stitch number below.
const double _rowGutter = 17;
const double _colGutter = 12;

/// Height reserved above a chart part for its caption.
const double _captionHeight = 18;

/// Build [doc] as PDF bytes on [page], set in [fonts]. [compress] is off only in tests that read
/// the output back.
Future<Uint8List> buildPrintPdf(
  PrintDocument doc, {
  required PrintPageSetup page,
  required PlyPdfFonts fonts,
  bool compress = true,
}) async {
  final pdf = pw.Document(
    compress: compress,
    title: doc.title,
    subject: doc.kind,
    creator: 'Ply',
  );
  final builder = _Builder(pdf.document, page, fonts);
  final missing = fonts.unsupportedIn(doc.allText);
  final children = <pw.Widget>[
    ...builder.titleBlock(doc),
    if (missing.isNotEmpty)
      builder.notice(PrintNotice(
        level: PrintNoticeLevel.caution,
        title: 'Some characters cannot be printed',
        intro: 'The print font has no shape for these characters, so they show as empty boxes '
            'in this PDF: ${missing.map((c) => '"$c"').join(', ')}.',
      )),
    if (doc.problemsBox != null) builder.notice(doc.problemsBox!, strong: true),
    for (final s in doc.sections) ...builder.section(s),
  ];

  pdf.addPage(pw.MultiPage(
    pageFormat: page.format,
    margin: pw.EdgeInsets.all(page.margin),
    theme: pw.ThemeData.withFont(base: fonts.regular, bold: fonts.bold).copyWith(
      defaultTextStyle: pw.TextStyle(
        font: fonts.regular,
        fontNormal: fonts.regular,
        fontBold: fonts.bold,
        fontSize: _body,
        lineSpacing: 1.5,
        color: _ink,
      ),
    ),
    // A real pattern can run long (a 200-row chart, its written rows); the package's default cap of
    // 20 pages is a debugging guard, not a layout rule.
    maxPages: 5000,
    footer: (ctx) => builder.footer(doc.title, ctx.pageNumber, ctx.pagesCount),
    build: (_) => children,
  ));
  return pdf.save();
}

class _Builder {
  _Builder(this.document, this.page, this.fonts);
  final PdfDocument document;
  final PrintPageSetup page;
  final PlyPdfFonts fonts;

  double get _width => page.contentWidth;

  /// The tallest single block that is guaranteed to fit on one page under the footer.
  double get _pageRoom => page.contentHeight - _footerHeight - 4;

  pw.TextStyle get _mutedStyle => const pw.TextStyle(fontSize: _small, color: _muted);
  pw.TextStyle get _boldStyle => pw.TextStyle(font: fonts.bold, fontBold: fonts.bold);

  pw.Widget footer(String title, int pageNumber, int pages) => pw.Container(
        height: _footerHeight,
        alignment: pw.Alignment.bottomLeft,
        child: pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.end,
          children: [
            pw.Expanded(
              child:
                  pw.Text(title, style: _mutedStyle, maxLines: 1, overflow: pw.TextOverflow.clip),
            ),
            pw.SizedBox(width: 12),
            pw.Text(pageLabel(pageNumber, pages), style: _mutedStyle),
          ],
        ),
      );

  List<pw.Widget> titleBlock(PrintDocument doc) => [
        pw.Text(doc.title, style: pw.TextStyle(font: fonts.bold, fontSize: 22)),
        pw.SizedBox(height: 2),
        pw.Text(doc.kind, style: const pw.TextStyle(fontSize: 12, color: _muted)),
        if (doc.titleFacts.isNotEmpty) ...[
          pw.SizedBox(height: 6),
          pw.Wrap(
            spacing: 16,
            runSpacing: 2,
            children: [
              for (final f in doc.titleFacts)
                pw.RichText(
                  text: pw.TextSpan(
                    style: _mutedStyle,
                    children: [
                      pw.TextSpan(text: '${f.label}: ', style: _boldStyle),
                      pw.TextSpan(text: f.value),
                    ],
                  ),
                ),
            ],
          ),
        ],
        pw.SizedBox(height: 10),
      ];

  List<pw.Widget> section(PrintSection s) {
    final heading = pw.Container(
      width: double.infinity,
      margin: const pw.EdgeInsets.only(top: 12, bottom: 6),
      padding: const pw.EdgeInsets.only(bottom: 2),
      decoration: const pw.BoxDecoration(
        border: pw.Border(bottom: pw.BorderSide(color: _rule, width: 0.6)),
      ),
      child: pw.Text(s.heading, style: pw.TextStyle(font: fonts.bold, fontSize: 14)),
    );
    if (s.blocks.isEmpty) return [heading];
    final first = block(s.blocks.first);
    final rest = [for (final b in s.blocks.skip(1)) ...block(b)];
    // Keep the heading with what follows it (no heading alone at the foot of a page) when that
    // first piece is known to fit on a page; a long table or paragraph is left free to split.
    if (first.isEmpty || !_fitsOnAPage(s.blocks.first)) return [heading, ...first, ...rest];
    return [
      pw.Inseparable(
        child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start, children: [heading, first.first]),
      ),
      ...first.skip(1),
      ...rest,
    ];
  }

  /// Whether the FIRST widget [block] makes is certain to fit on one page (so it may be bound to
  /// its heading without risking an unsplittable block taller than a page).
  static bool _fitsOnAPage(PrintBlock b) => switch (b) {
        PrintParagraph(:final text) => text.split('\n').first.length <= 600,
        PrintFacts(:final facts) => facts.length <= 12,
        PrintLegend(:final entries) => entries.length <= 3,
        PrintLines(:final lines) => lines.isEmpty || lines.first.text.length <= 1500,
        PrintNotice() || PrintPhoto() => true,
        // A chart part is sized to a whole page already; a heading on top would not fit.
        PrintChart() || PrintBookDraft() || PrintColorDrawdown() => false,
        PrintDrawing(:final label) => label != null,
        PrintIssues(:final issues) => issues.isEmpty,
      };

  List<pw.Widget> block(PrintBlock b) => switch (b) {
        PrintParagraph() => paragraph(b),
        PrintFacts() => [facts(b.facts)],
        PrintLegend() => [legend(b)],
        PrintLines() => lines(b),
        PrintNotice() => [notice(b)],
        PrintIssues() => issues(b),
        PrintChart() => chart(b),
        PrintBookDraft() => bookDraft(b),
        PrintColorDrawdown() => colorDrawdown(b),
        PrintDrawing() => drawing(b),
        PrintPhoto() => photo(b),
      };

  // --- text --------------------------------------------------------------------------------------

  List<pw.Widget> paragraph(PrintParagraph p) {
    final style = switch (p.style) {
      PrintTextStyle.body => null,
      PrintTextStyle.muted => _mutedStyle,
      PrintTextStyle.strong => _boldStyle,
    };
    return [
      for (final line in p.text.split('\n'))
        line.trim().isEmpty
            ? pw.SizedBox(height: 5)
            : pw.Padding(
                padding: const pw.EdgeInsets.only(bottom: 4),
                // span: a paragraph longer than a page continues on the next one.
                child: pw.Text(line, style: style, overflow: pw.TextOverflow.span),
              ),
    ];
  }

  pw.Widget facts(List<PrintFact> facts) => pw.Table(
        columnWidths: const {0: pw.FixedColumnWidth(110), 1: pw.FlexColumnWidth()},
        children: [
          for (final f in facts)
            pw.TableRow(children: [
              pw.Padding(
                padding: const pw.EdgeInsets.only(right: 8, bottom: 4),
                child: pw.Text(f.label, style: _boldStyle),
              ),
              pw.Padding(padding: const pw.EdgeInsets.only(bottom: 4), child: pw.Text(f.value)),
            ]),
        ],
      );

  List<pw.Widget> lines(PrintLines block) => [
        for (final l in block.lines)
          pw.Container(
            margin: const pw.EdgeInsets.only(bottom: 5),
            padding: l.flagged ? const pw.EdgeInsets.only(left: 6) : pw.EdgeInsets.zero,
            decoration: l.flagged
                ? const pw.BoxDecoration(
                    border: pw.Border(left: pw.BorderSide(color: _problem, width: 2)),
                  )
                : null,
            child: pw.RichText(
              overflow: pw.TextOverflow.span,
              text: pw.TextSpan(
                children: [
                  if (l.label != null) pw.TextSpan(text: '${l.label}: ', style: _boldStyle),
                  pw.TextSpan(text: l.text, style: l.label == null ? _boldStyle : null),
                ],
              ),
            ),
          ),
      ];

  /// A boxed notice. Long lists are cut to a page's worth (the full list is always in the
  /// document's own Problems section).
  pw.Widget notice(PrintNotice n, {bool strong = false}) {
    const maxLines = 14;
    final shown = n.lines.length > maxLines ? n.lines.sublist(0, maxLines - 1) : n.lines;
    final hidden = n.lines.length - shown.length;
    final color = n.level == PrintNoticeLevel.problem ? _problem : _caution;
    return pw.Container(
      width: double.infinity,
      margin: const pw.EdgeInsets.only(top: 4, bottom: 8),
      padding: const pw.EdgeInsets.all(8),
      decoration: pw.BoxDecoration(border: pw.Border.all(color: color, width: strong ? 2.2 : 1.2)),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(n.title, style: pw.TextStyle(font: fonts.bold, fontSize: strong ? 13 : 11)),
          if (n.intro != null)
            pw.Padding(padding: const pw.EdgeInsets.only(top: 3), child: pw.Text(n.intro!)),
          for (final line in shown) _bullet(line),
          if (hidden > 0) _bullet('and $hidden more, listed under Problems.'),
        ],
      ),
    );
  }

  pw.Widget _bullet(String text) => pw.Padding(
        padding: const pw.EdgeInsets.only(top: 3),
        child: pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.SizedBox(width: 10, child: pw.Text('•')),
            pw.Expanded(child: pw.Text(text)),
          ],
        ),
      );

  List<pw.Widget> issues(PrintIssues block) {
    if (block.issues.isEmpty) return [pw.Text(block.emptyText)];
    String severity(PrintIssueSeverity s) => switch (s) {
          PrintIssueSeverity.error => 'Error',
          PrintIssueSeverity.warning => 'Warning',
          PrintIssueSeverity.note => 'Note',
        };
    pw.Widget cell(String text, {pw.TextStyle? style}) => pw.Padding(
          padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 3),
          child: pw.Text(text, style: style),
        );
    return [
      pw.Table(
        border: const pw.TableBorder(
          horizontalInside: pw.BorderSide(color: _rule, width: 0.4),
          bottom: pw.BorderSide(color: _rule, width: 0.4),
        ),
        columnWidths: const {
          0: pw.FixedColumnWidth(56),
          1: pw.FixedColumnWidth(84),
          2: pw.FlexColumnWidth(),
        },
        children: [
          pw.TableRow(
            repeat: true,
            decoration: const pw.BoxDecoration(
              border: pw.Border(bottom: pw.BorderSide(color: _ink, width: 0.8)),
            ),
            children: [
              cell('Severity', style: _boldStyle),
              cell('Where', style: _boldStyle),
              cell('Problem', style: _boldStyle),
            ],
          ),
          for (final i in block.issues)
            pw.TableRow(children: [
              cell(severity(i.severity),
                  style: i.severity == PrintIssueSeverity.error ? _boldStyle : null),
              cell(i.where),
              cell(i.message),
            ]),
        ],
      ),
    ];
  }

  // --- keys --------------------------------------------------------------------------------------

  /// Printed size of one key symbol cell.
  static const double _keyCell = 15;

  pw.Widget legend(PrintLegend block) {
    final widest = block.entries.fold<double>(
      _keyCell,
      (w, e) => e.glyph == null || e.glyph!.height == 0
          ? w
          : math.max(w, _keyCell * e.glyph!.width / e.glyph!.height),
    );
    final symbolColumn = math.min(widest, 90.0) + 8;
    return pw.Table(
      border: const pw.TableBorder(horizontalInside: pw.BorderSide(color: _rule, width: 0.4)),
      columnWidths: {
        0: pw.FixedColumnWidth(symbolColumn),
        1: const pw.FixedColumnWidth(64),
        2: const pw.FlexColumnWidth(),
      },
      children: [
        for (final e in block.entries)
          pw.TableRow(
            verticalAlignment: pw.TableCellVerticalAlignment.top,
            children: [
              pw.Padding(padding: const pw.EdgeInsets.symmetric(vertical: 4), child: _symbol(e)),
              pw.Padding(
                padding: const pw.EdgeInsets.fromLTRB(0, 4, 6, 4),
                child: pw.Text(e.code, style: pw.TextStyle(font: fonts.bold, fontSize: 11)),
              ),
              pw.Padding(
                padding: const pw.EdgeInsets.symmetric(vertical: 4),
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(e.name, style: _boldStyle),
                    pw.Text(e.meaning),
                    for (final n in e.notes)
                      pw.Padding(
                        padding: const pw.EdgeInsets.only(top: 2),
                        child: pw.Text(n, style: _mutedStyle),
                      ),
                  ],
                ),
              ),
            ],
          ),
      ],
    );
  }

  pw.Widget _symbol(PrintLegendEntry e) {
    final glyph = e.glyph;
    if (glyph != null && !glyph.isEmpty) {
      const h = _keyCell;
      final w = math.min(90.0, _keyCell * glyph.width / glyph.height);
      return pw.Container(
        width: w,
        height: h,
        decoration: pw.BoxDecoration(border: pw.Border.all(color: _boxLine, width: 0.6)),
        child:
            pw.Image(pw.ImageProxy(_rasterImage(glyph)), width: w, height: h, fit: pw.BoxFit.fill),
      );
    }
    final swatch = e.swatch;
    if (swatch != null) {
      return pw.Container(
        width: _keyCell,
        height: _keyCell,
        decoration: pw.BoxDecoration(
          color: PdfColor.fromInt(0xFF000000 | (swatch.r << 16) | (swatch.g << 8) | swatch.b),
          border: pw.Border.all(color: _boxLine, width: 0.6),
        ),
      );
    }
    final mark = e.mark;
    if (mark != null) return _markSymbol(mark, _keyCell);
    return pw.SizedBox(width: _keyCell, height: _keyCell);
  }

  /// An opaque RGB image of [r] (the engine rasters are opaque, so no alpha mask is embedded).
  PdfImage _rasterImage(PrintRaster r) {
    final n = r.width * r.height;
    final rgb = Uint8List(n * 3);
    for (var i = 0, j = 0; i < n; i++, j += 4) {
      rgb[i * 3] = r.rgba[j];
      rgb[i * 3 + 1] = r.rgba[j + 1];
      rgb[i * 3 + 2] = r.rgba[j + 2];
    }
    return PdfImage(document, image: rgb, width: r.width, height: r.height, alpha: false);
  }

  // --- charts ------------------------------------------------------------------------------------

  List<pw.Widget> chart(PrintChart c) {
    if (c.columns == 0 || c.rows == 0 || c.raster.isEmpty) return const [];
    final layout = layoutChart(
      columns: c.columns,
      rows: c.rows,
      width: _width - 2 * _rowGutter,
      height: _pageRoom - _colGutter - _captionHeight - 4,
      startAtRight: c.startAtRight,
    );
    // ONE image for the whole chart, drawn clipped into every part (no per-part pixel copies).
    final image = _rasterImage(c.raster);
    final many = layout.parts.length > 1;
    return [
      for (final (i, part) in layout.parts.indexed)
        pw.Inseparable(
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Container(
                height: _captionHeight,
                alignment: pw.Alignment.bottomLeft,
                padding: const pw.EdgeInsets.only(bottom: 3),
                child: pw.Text(
                  _partCaption(c, part, i, layout.parts.length, many),
                  style: _boldStyle.copyWith(fontSize: 9.5),
                ),
              ),
              _ChartPartWidget(
                chart: c,
                part: part,
                cell: layout.cell,
                image: image,
                regular: fonts.regular,
                bold: fonts.bold,
              ),
              pw.SizedBox(height: 4),
            ],
          ),
        ),
    ];
  }

  static String _partCaption(PrintChart c, ChartPart part, int index, int count, bool many) {
    String range(Iterable<int> numbers) {
      final list = numbers.toList()..sort();
      return list.first == list.last ? '${list.first}' : '${list.first} to ${list.last}';
    }

    final rows = range(c.rowNumbers.sublist(part.rowStart, part.rowEnd));
    final cols = range(c.columnNumbers.sublist(part.colStart, part.colEnd));
    final where = '${c.rowsName} $rows, ${c.columnsName} $cols';
    return many ? 'Part ${index + 1} of $count: $where' : where;
  }

  // --- drawings ----------------------------------------------------------------------------------

  List<pw.Widget> drawing(PrintDrawing d) {
    if (d.width <= 0 || d.height <= 0) return const [];
    // Shrink a wide drawing to fit when it stays readable; otherwise cut it into strips.
    final fit = _width / d.width;
    final scale = fit >= 1 ? 1.0 : (fit >= 0.6 ? fit : 1.0);
    final stripWidth = _width / scale;
    final strips = <(double, double)>[
      for (var x = 0.0; x < d.width; x += stripWidth) (x, math.min(d.width, x + stripWidth)),
    ];
    return [
      if (d.label != null)
        pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 4),
          child: pw.Text(d.label!, style: _boldStyle),
        ),
      for (final (x0, x1) in strips)
        pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 4),
          child: _VectorStripWidget(
            drawing: d,
            scale: scale,
            x0: x0,
            x1: x1,
            font: fonts.regular,
          ),
        ),
      if (d.caption != null)
        pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 6),
          child: pw.Text(d.caption!, style: _mutedStyle),
        ),
    ];
  }

  // --- photos ------------------------------------------------------------------------------------

  List<pw.Widget> photo(PrintPhoto p) {
    final image = _photoImage(p.bytes);
    if (image == null) {
      return [
        notice(PrintNotice(
          level: PrintNoticeLevel.caution,
          title: p.caption,
          intro: p.unprintable,
        )),
      ];
    }
    final maxH = math.min(_pageRoom - 30, page.contentHeight * 0.6);
    final aspect = image.width / image.height;
    var w = _width;
    var h = w / aspect;
    if (h > maxH) {
      h = maxH;
      w = h * aspect;
    }
    return [
      pw.Inseparable(
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            _PhotoWidget(image, w, h),
            pw.Padding(
              padding: const pw.EdgeInsets.only(top: 3, bottom: 10),
              child: pw.Text(p.caption, style: _mutedStyle),
            ),
          ],
        ),
      ),
    ];
  }

  /// The photo as a PDF image, or null when it cannot be printed. A JPEG is embedded as it is
  /// (no re-encoding) minus its metadata (GPS position, camera, time); its orientation is kept by
  /// reading it first. Other formats are decoded to pixels, which drops their metadata too.
  PdfImage? _photoImage(Uint8List bytes) {
    try {
      if (isJpeg(bytes)) {
        final orientation = PdfJpegInfo(bytes).orientation;
        final clean = stripJpegMetadata(bytes);
        if (clean == null) return null;
        final img = PdfImage.jpeg(document, image: clean, orientation: orientation);
        return img.width > 0 && img.height > 0 ? img : null;
      }
      final img = PdfImage.file(document, bytes: bytes);
      return img.width > 0 && img.height > 0 ? img : null;
    } catch (_) {
      return null; // not a format the PDF library can read (HEIC, a damaged file)
    }
  }
}

/// A photo drawn at [width] x [height] points. Drawn directly rather than through `pw.Image`, whose
/// image proxy swaps the sides of a rotated (EXIF-oriented) photo twice; `drawImage` takes the
/// displayed size and applies the orientation itself.
class _PhotoWidget extends pw.Widget {
  _PhotoWidget(this.image, this.width, this.height);
  final PdfImage image;
  final double width;
  final double height;

  @override
  void layout(pw.Context context, pw.BoxConstraints constraints, {bool parentUsesSize = false}) {
    box = PdfRect(0, 0, width, height);
  }

  @override
  void paint(pw.Context context) {
    super.paint(context);
    context.canvas.drawImage(image, box!.left, box!.bottom, width, height);
  }
}

/// One page-sized part of a chart: its cells (the chart image, clipped), a border, the repeat boxes
/// that fall in it, the row numbers in the side gutters and the column numbers below.
class _ChartPartWidget extends pw.Widget {
  _ChartPartWidget({
    required this.chart,
    required this.part,
    required this.cell,
    required this.image,
    required this.regular,
    required this.bold,
  });

  final PrintChart chart;
  final ChartPart part;
  final double cell;
  final PdfImage image;
  final pw.Font regular;
  final pw.Font bold;

  double get _cellsWidth => part.columns * cell;
  double get _cellsHeight => part.rows * cell;

  @override
  void layout(pw.Context context, pw.BoxConstraints constraints, {bool parentUsesSize = false}) {
    box = PdfRect(0, 0, _rowGutter * 2 + _cellsWidth, _cellsHeight + _colGutter);
  }

  @override
  void paint(pw.Context context) {
    super.paint(context);
    final canvas = context.canvas;
    final x0 = box!.left + _rowGutter;
    final y0 = box!.bottom + _colGutter;
    final w = _cellsWidth, h = _cellsHeight;

    // Cells: the whole chart image, offset so this part's cells land in the frame, clipped to it.
    canvas
      ..saveContext()
      ..drawRect(x0, y0, w, h)
      ..clipPath()
      ..drawImage(image, x0 - part.colStart * cell, y0 - part.rowStart * cell, chart.columns * cell,
          chart.rows * cell)
      ..restoreContext();
    _paintBoxes(context, x0, y0);
    // The frame last, so a box's white underlay never breaks it.
    canvas
      ..setStrokeColor(_boxLine)
      ..setLineWidth(0.8)
      ..drawRect(x0, y0, w, h)
      ..strokePath();
    _paintNumbers(context, x0, y0);
  }

  void _paintBoxes(pw.Context context, double x0, double y0) {
    final canvas = context.canvas;
    final font = bold.getFont(context);
    for (final b in chart.boxes) {
      final c0 = math.max(b.colStart, part.colStart), c1 = math.min(b.colEnd, part.colEnd);
      final r0 = math.max(b.rowLo, part.rowStart), r1 = math.min(b.rowHi + 1, part.rowEnd);
      if (c0 >= c1 || r0 >= r1) continue;
      const inset = 0.9;
      final left = x0 + (c0 - part.colStart) * cell + inset;
      final right = x0 + (c1 - part.colStart) * cell - inset;
      final bottom = y0 + (r0 - part.rowStart) * cell + inset;
      final top = y0 + (r1 - part.rowStart) * cell - inset;
      // Only the box's real edges: a side cut off by the part's edge stays open, so a box that runs
      // on into the next part reads as continuing.
      final edges = <(double, double, double, double)>[
        if (b.colStart >= part.colStart) (left, bottom, left, top),
        if (b.colEnd <= part.colEnd) (right, bottom, right, top),
        if (b.rowLo >= part.rowStart) (left, bottom, right, bottom),
        if (b.rowHi + 1 <= part.rowEnd) (left, top, right, top),
      ];
      // A white underlay keeps the box visible on dark colorwork cells.
      for (final (width, color) in [(3.2, PdfColors.white), (1.5, _boxLine)]) {
        canvas
          ..setStrokeColor(color)
          ..setLineWidth(width)
          ..setLineCap(PdfLineCap.square);
        for (final (ax, ay, bx, by) in edges) {
          canvas
            ..moveTo(ax, ay)
            ..lineTo(bx, by);
        }
        canvas.strokePath();
      }
      // The count label, top-right (the right-side reading start), on every part the box is in.
      const size = 7.0;
      final textW = font.stringMetrics(b.label).advanceWidth * size;
      final pillW = textW + 4, pillH = size + 2.5;
      final px = math.max(left, right - pillW);
      canvas
        ..setFillColor(_boxLine)
        ..drawRect(px, top - pillH, pillW, pillH)
        ..fillPath()
        ..setFillColor(PdfColors.white)
        ..drawString(font, size, b.label, px + 2, top - pillH + 2.2);
    }
  }

  void _paintNumbers(pw.Context context, double x0, double y0) {
    final canvas = context.canvas;
    final font = regular.getFont(context);
    final size = cell >= 13 ? 6.5 : 6.0;
    canvas.setFillColor(_ink);
    void centered(String s, double cx, double cy) {
      final tw = font.stringMetrics(s).advanceWidth * size;
      canvas.drawString(font, size, s, cx - tw / 2, cy - size * 0.36);
    }

    for (var r = part.rowStart; r < part.rowEnd; r++) {
      final cy = y0 + (r - part.rowStart + 0.5) * cell;
      final cx = chart.rowNumberSides[r] == PrintSide.right
          ? x0 + _cellsWidth + _rowGutter / 2
          : box!.left + _rowGutter / 2;
      centered('${chart.rowNumbers[r]}', cx, cy);
    }
    for (var c = part.colStart; c < part.colEnd; c++) {
      centered('${chart.columnNumbers[c]}', x0 + (c - part.colStart + 0.5) * cell,
          box!.bottom + _colGutter / 2);
    }
  }
}

/// One horizontal strip [x0, x1) of a vector drawing, at [scale].
class _VectorStripWidget extends pw.Widget {
  _VectorStripWidget({
    required this.drawing,
    required this.scale,
    required this.x0,
    required this.x1,
    required this.font,
  });

  final PrintDrawing drawing;
  final double scale;
  final double x0;
  final double x1;
  final pw.Font font;

  @override
  void layout(pw.Context context, pw.BoxConstraints constraints, {bool parentUsesSize = false}) {
    box = PdfRect(0, 0, (x1 - x0) * scale, drawing.height * scale);
  }

  /// A print style per ink: (color, line width). A faded drawing is drawn in lighter ink.
  (PdfColor, double) _style(PrintInk ink) {
    final (int argb, double width) = switch (ink) {
      PrintInk.strong => (0xFF111111, 1.8),
      PrintInk.accent => (0xFF1F4E8C, 1.6),
      PrintInk.faint => (0xFF9A9A9A, 1.2),
      PrintInk.highlight => (0xFF8A3B00, 1.6),
      PrintInk.label => (0xFF333333, 0),
    };
    final c = PdfColor.fromInt(argb);
    if (!drawing.faded) return (c, width * scale);
    PdfColor light(PdfColor c) => PdfColor(
        c.red + (1 - c.red) * 0.55, c.green + (1 - c.green) * 0.55, c.blue + (1 - c.blue) * 0.55);
    return (light(c), width * scale);
  }

  @override
  void paint(pw.Context context) {
    super.paint(context);
    final canvas = context.canvas;
    final left = box!.left, top = box!.top;
    double px(double x) => left + (x - x0) * scale;
    double py(double y) => top - y * scale; // y grows down in the drawing, up on the page

    canvas
      ..saveContext()
      ..drawRect(box!.left, box!.bottom, box!.width, box!.height)
      ..clipPath()
      ..setLineCap(PdfLineCap.round);
    final pdfFont = font.getFont(context);
    for (final s in drawing.shapes) {
      final (color, width) = _style(s.ink);
      switch (s) {
        case PrintVectorLine(:final x1, :final y1, :final x2, :final y2):
          canvas
            ..setStrokeColor(color)
            ..setLineWidth(width)
            ..moveTo(px(x1), py(y1))
            ..lineTo(px(x2), py(y2))
            ..strokePath();
        case PrintVectorArc():
          canvas
            ..setStrokeColor(color)
            ..setLineWidth(width);
          _arc(canvas, s, px, py);
          canvas.strokePath();
        case PrintVectorText(:final x, :final y, :final text, :final size):
          final fontSize = size * scale;
          canvas
            ..setFillColor(color)
            ..drawString(pdfFont, fontSize, text, px(x), py(y) - pdfFont.ascent * fontSize);
      }
    }
    canvas.restoreContext();
  }

  /// An elliptical arc as cubic Beziers, at most a quarter turn each.
  static void _arc(
    PdfGraphics canvas,
    PrintVectorArc a,
    double Function(double) px,
    double Function(double) py,
  ) {
    final segments = math.max(1, (a.sweepAngle.abs() / (math.pi / 2)).ceil());
    final step = a.sweepAngle / segments;
    final k = 4 / 3 * math.tan(step / 4);
    var t = a.startAngle;
    canvas.moveTo(px(a.cx + a.rx * math.cos(t)), py(a.cy + a.ry * math.sin(t)));
    for (var i = 0; i < segments; i++) {
      final t2 = t + step;
      final (c1x, c1y) = (
        a.cx + a.rx * (math.cos(t) - k * math.sin(t)),
        a.cy + a.ry * (math.sin(t) + k * math.cos(t))
      );
      final (c2x, c2y) = (
        a.cx + a.rx * (math.cos(t2) + k * math.sin(t2)),
        a.cy + a.ry * (math.sin(t2) - k * math.cos(t2))
      );
      canvas.curveTo(px(c1x), py(c1y), px(c2x), py(c2y), px(a.cx + a.rx * math.cos(t2)),
          py(a.cy + a.ry * math.sin(t2)));
      t = t2;
    }
  }
}
