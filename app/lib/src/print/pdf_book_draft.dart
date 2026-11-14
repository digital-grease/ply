part of 'pdf_builder.dart';

// The weaving blocks of a printed draft (M9-02, ADR 0012): the four-quadrant BOOK DRAFT and the
// COLORED DRAWDOWN. Both are cut into page-sized parts by book_draft_layout.dart and drawn as vector
// shapes: grid lines, marks, the engine's interlacement (or its colors) one square per crossing,
// numbers on every axis, and beside the treadling the pick numbers, role letters, shuttle and pass
// arrows and shot-group brackets; under the drawdown, the edge labels. Vector keeps every square crisp
// at any zoom, and adjacent squares of one row merge into one rectangle, so a 400 x 1000 draft stays a
// few megabytes. Part of the builder library so it shares its inks and page metrics.

const _gridLine = PdfColor.fromInt(0xFF9A9A9A);
const _tenthLine = PdfColor.fromInt(0xFF505050);
const _markInk = PdfColor.fromInt(0xFF1A1A1A);

/// The text size of the numbers, letters and labels around the weaving grids.
const double _gridText = 5.5;

/// Space between a grid and its numbers, and inside a margin column.
const double _numberPad = 2;

/// The colored drawdown's color bands: thickness and the gap between a band and the cloth.
const double _bandThickness = 2.5 * kMm;
const double _bandGap = 1.5;

/// One margin column beside the treadling: [offset] beyond it, [w] wide.
class _MarginColumn {
  const _MarginColumn(this.offset, this.w);
  final double offset;
  final double w;
}

/// The margin columns of a book draft, in canonical order outward from the treadling.
class _BookColumns {
  _BookColumns(this.picks, this.roles, this.passes, this.brackets, this.total);
  final _MarginColumn picks;
  final _MarginColumn? roles;
  final _MarginColumn? passes;
  final _MarginColumn? brackets;
  final double total;
}

/// The text of a pass beside the treadling, with the arrow that matches the picture: on Ply's loom a
/// pass from the end 1 edge (the right) goes right to left; a left-right mirrored layout draws it the
/// other way.
String _passToken(PrintPass p, {required bool mirrored}) {
  final s = p.shuttle;
  if (s == null) return '?';
  final arrow = switch (p.direction) {
    PrintPassDirection.unknown => null,
    PrintPassDirection.fromEndOne => mirrored ? '→' : '←',
    PrintPassDirection.towardEndOne => mirrored ? '←' : '→',
  };
  return arrow == null ? '$s' : '$s $arrow';
}

extension _WeaveBlocks on _Builder {
  /// The height a part may use under its caption.
  double get _partRoom => _pageRoom - _captionHeight - 8;

  _BookColumns _bookColumns(PrintBookDraft b) {
    double w(String s) => fonts.textWidth(s, _gridText);
    var offset = 0.0;
    _MarginColumn next(double width) {
      final c = _MarginColumn(offset, width);
      offset += width;
      return c;
    }

    final maxPick = b.pickNumbers.fold<int>(1, math.max);
    final picks = next(w('$maxPick') + 2 * _numberPad);
    final letters = b.roles.where((r) => r.isNotEmpty).toSet();
    final roles =
        letters.isEmpty ? null : next(letters.map(w).fold<double>(0, math.max) + 2 * _numberPad);
    final passes = b.passes.isEmpty
        ? null
        : next(b.passes
                .map((p) => w(_passToken(p, mirrored: b.corner.mirrorX)))
                .fold<double>(w('?'), math.max) +
            2 * _numberPad);
    final brackets = b.brackets.isEmpty
        ? null
        : next(6 + b.brackets.map((x) => w(x.label)).fold<double>(0, math.max) + 2 * _numberPad);
    return _BookColumns(picks, roles, passes, brackets, offset);
  }

  BookMargins _bookMargins(PrintBookDraft b, _BookColumns columns) {
    const numberRow = _gridText + 2 * _numberPad;
    final edges = b.highEndEdge != null || b.endOneEdge != null;
    return BookMargins(
      left: fonts.textWidth('${b.shafts}', _gridText) + 2 * _numberPad,
      right: columns.total,
      top: numberRow,
      bottom: edges ? numberRow + 1 : 0,
    );
  }

  List<pw.Widget> bookDraft(PrintBookDraft b) {
    if (b.ends == 0 || b.rows == 0) return const [];
    final columns = _bookColumns(b);
    final margins = _bookMargins(b, columns);
    final layout = layoutBookDraft(
      ends: b.ends,
      rows: b.rows,
      shafts: b.shafts,
      columns: b.columns,
      width: _width,
      height: _partRoom,
      margins: margins,
    );
    if (layout.tooLarge) {
      return [
        notice(PrintNotice(
          level: PrintNoticeLevel.caution,
          title: 'This draft is too large for a book draft on this paper',
          intro: 'Its ${b.shafts} shafts and ${b.columns} '
              '${b.isLiftplan ? 'lift plan columns' : 'treadles'} leave no room for '
              '$kBookMinBand ends and $kBookMinBand picks at the smallest readable square (3 mm). '
              'The written directions list every end and pick.',
        )),
      ];
    }
    final many = layout.parts.length > 1;
    return [
      for (final (i, part) in layout.parts.indexed)
        pw.Inseparable(
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              _gridCaption(_bookCaption(b, part, i, layout.parts.length, many)),
              _BookPartWidget(
                draft: b,
                part: part,
                geometry: BookGeometry(
                  cell: layout.cell,
                  margins: margins,
                  shafts: b.shafts,
                  columns: b.columns,
                  ends: part.ends,
                  rows: part.rows,
                  corner: b.corner,
                ),
                columns: columns,
                regular: fonts.regular,
                bold: fonts.bold,
              ),
              pw.SizedBox(height: 4),
            ],
          ),
        ),
    ];
  }

  pw.Widget _gridCaption(String text) => pw.Container(
        height: _captionHeight,
        alignment: pw.Alignment.bottomLeft,
        padding: const pw.EdgeInsets.only(bottom: 3),
        child: pw.Text(text, style: _boldStyle.copyWith(fontSize: 9.5)),
      );

  List<pw.Widget> colorDrawdown(PrintColorDrawdown d) {
    if (d.ends == 0 || d.picks == 0) return const [];
    const numberRow = _gridText + 2 * _numberPad;
    final pickW = fonts.textWidth('${d.picks}', _gridText) + 2 * _numberPad;
    final margins = BookMargins(
      left: _numberPad,
      right: _bandGap + _bandThickness + pickW,
      top: numberRow + _bandThickness + _bandGap,
      gap: 0,
    );
    final layout = layoutBookDraft(
      ends: d.ends,
      rows: d.picks,
      shafts: 0,
      columns: 0,
      width: _width,
      height: _partRoom,
      margins: margins,
      rule: kColorDrawdownCellRule,
    );
    final many = layout.parts.length > 1;
    return [
      for (final (i, part) in layout.parts.indexed)
        pw.Inseparable(
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              _gridCaption(_rangeCaption(
                ends: (part.endStart, part.endEnd),
                picks: (part.rowStart + 1, part.rowEnd),
                index: i,
                count: layout.parts.length,
                many: many,
              )),
              _ColorPartWidget(
                drawdown: d,
                part: part,
                geometry: BookGeometry(
                  cell: layout.cell,
                  margins: margins,
                  shafts: 0,
                  columns: 0,
                  ends: part.ends,
                  rows: part.rows,
                  corner: d.corner,
                ),
                numberRow: numberRow,
                pickOffset: _bandGap + _bandThickness,
                pickWidth: pickW,
                regular: fonts.regular,
              ),
              pw.SizedBox(height: 4),
            ],
          ),
        ),
    ];
  }

  static String _bookCaption(PrintBookDraft b, BookPart part, int index, int count, bool many) {
    final numbers = b.pickNumbers.sublist(part.rowStart, part.rowEnd);
    return _rangeCaption(
      ends: (part.endStart, part.endEnd),
      picks: (numbers.reduce(math.min), numbers.reduce(math.max)),
      note: b.rowsNote,
      index: index,
      count: count,
      many: many,
    );
  }

  /// "Ends 1 to 22, picks 1 to 22" or "Part 2 of 6: ends 41 to 80, picks 1 to 60" ([ends] 0-based
  /// half-open, [picks] the first and last printed number).
  static String _rangeCaption({
    required (int, int) ends,
    required (int, int) picks,
    String? note,
    required int index,
    required int count,
    required bool many,
  }) {
    final e = ends.$2 - ends.$1 == 1 ? 'end ${ends.$2}' : 'ends ${ends.$1 + 1} to ${ends.$2}';
    final p = picks.$1 == picks.$2 ? 'pick ${picks.$1}' : 'picks ${picks.$1} to ${picks.$2}';
    final where = '$e, $p${note == null ? '' : ' ($note)'}';
    return many
        ? 'Part ${index + 1} of $count: $where'
        : '${where[0].toUpperCase()}${where.substring(1)}';
  }
}

/// Draws text in boxes of a grid widget and fills boxes, in the widget's y-down frame.
mixin _GridPainter on pw.Widget {
  double _px(double x) => box!.left + x;
  double _py(double y) => box!.top - y;

  void _rect(PdfGraphics canvas, BookBox r, {double inset = 0}) =>
      canvas.drawRect(_px(r.x + inset), _py(r.bottom - inset), r.w - 2 * inset, r.h - 2 * inset);

  void _text(PdfGraphics canvas, PdfFont font, String s, BookBox r, BookAlign a,
      {double size = _gridText}) {
    final tw = font.stringMetrics(s).advanceWidth * size;
    final x = switch (a) {
      BookAlign.start => r.x + _numberPad,
      BookAlign.center => r.centerX - tw / 2,
      BookAlign.end => r.right - _numberPad - tw,
    };
    canvas.drawString(font, size, s, _px(x), _py(r.centerY) - size * 0.36);
  }

  void _lines(PdfGraphics canvas, List<(double, double, double, double)> lines, PdfColor color,
      double width) {
    if (lines.isEmpty) return;
    canvas
      ..setStrokeColor(color)
      ..setLineWidth(width)
      ..setLineCap(PdfLineCap.butt);
    for (final (x1, y1, x2, y2) in lines) {
      canvas
        ..moveTo(_px(x1), _py(y1))
        ..lineTo(_px(x2), _py(y2));
    }
    canvas.strokePath();
  }

  /// Every cell boundary of [area], [cols] x [rows] cells of [cell] points.
  static List<(double, double, double, double)> _cellLines(
      BookBox area, int cols, int rows, double cell) {
    if (area.w <= 0 || area.h <= 0) return const [];
    return [
      for (var c = 1; c < cols; c++) (area.x + c * cell, area.y, area.x + c * cell, area.bottom),
      for (var r = 1; r < rows; r++) (area.x, area.y + r * cell, area.right, area.y + r * cell),
    ];
  }

  void _frame(PdfGraphics canvas, BookBox area) {
    if (area.w <= 0 || area.h <= 0) return;
    canvas
      ..setStrokeColor(_boxLine)
      ..setLineWidth(0.8)
      ..drawRect(_px(area.x), _py(area.bottom), area.w, area.h)
      ..strokePath();
  }
}

/// One page-sized part of a book draft.
class _BookPartWidget extends pw.Widget with _GridPainter {
  _BookPartWidget({
    required this.draft,
    required this.part,
    required this.geometry,
    required this.columns,
    required this.regular,
    required this.bold,
  });

  final PrintBookDraft draft;
  final BookPart part;
  final BookGeometry geometry;
  final _BookColumns columns;
  final pw.Font regular;
  final pw.Font bold;

  @override
  void layout(pw.Context context, pw.BoxConstraints constraints, {bool parentUsesSize = false}) {
    box = PdfRect(0, 0, geometry.width, geometry.height);
  }

  @override
  void paint(pw.Context context) {
    super.paint(context);
    final canvas = context.canvas;
    final g = geometry;
    final b = draft;
    final cell = g.cell;

    // The engine's interlacement: warp on top in black, a row's adjacent squares as one rectangle.
    final dd = b.drawdown;
    if (dd != null) {
      canvas.setFillColor(_markInk);
      var any = false;
      for (var r = 0; r < part.rows; r++) {
        final base = (part.rowStart + r) * b.ends + part.endStart;
        var j = 0;
        while (j < part.ends) {
          if (dd[base + j] != 1) {
            j++;
            continue;
          }
          var k = j + 1;
          while (k < part.ends && dd[base + k] == 1) {
            k++;
          }
          _rect(canvas, g.drawdownRun(j, k, r));
          any = true;
          j = k;
        }
      }
      if (any) canvas.fillPath();
    }

    // Marks: threading, tie-up, treadling (or lift plan), inset so the grid stays visible.
    final inset = cell * 0.14;
    final filled = <BookBox>[];
    final crosses = <BookBox>[];
    for (var j = 0; j < part.ends; j++) {
      for (final s in b.threading[part.endStart + j]) {
        if (s >= 1 && s <= b.shafts) filled.add(g.threadingCell(j, s));
      }
    }
    final tieup = b.tieup;
    if (tieup != null) {
      for (var t = 0; t < tieup.length; t++) {
        for (final s in tieup[t]) {
          if (s < 1 || s > b.shafts) continue;
          (b.tieupMark == PrintMark.cross ? crosses : filled).add(g.tieupCell(t + 1, s));
        }
      }
    }
    for (var r = 0; r < part.rows; r++) {
      for (final t in b.treadling[part.rowStart + r]) {
        if (t >= 1 && t <= b.columns) filled.add(g.treadlingCell(t, r));
      }
    }
    if (filled.isNotEmpty) {
      canvas.setFillColor(_markInk);
      for (final f in filled) {
        _rect(canvas, f, inset: inset);
      }
      canvas.fillPath();
    }
    _lines(
        canvas,
        [
          for (final c in crosses) ...[
            (c.x + inset, c.y + inset, c.right - inset, c.bottom - inset),
            (c.x + inset, c.bottom - inset, c.right - inset, c.y + inset),
          ],
        ],
        _markInk,
        0.9);

    // Grid lines, a heavier line after every 10th end and row, then the quadrant frames.
    final areas = [
      (g.threadingArea, part.ends, b.shafts),
      if (tieup != null) (g.tieupArea, b.columns, b.shafts),
      (g.treadlingArea, b.columns, part.rows),
      (g.drawdownArea, part.ends, part.rows),
    ];
    _lines(
        canvas,
        [
          for (final (area, cols, rows) in areas)
            ..._GridPainter._cellLines(area, cols, rows, cell),
        ],
        _gridLine,
        0.3);
    final warp = [g.threadingArea, g.drawdownArea];
    final weft = [g.treadlingArea, g.drawdownArea];
    _lines(
        canvas,
        [
          for (var j = 1; j < part.ends; j++)
            if ((part.endStart + j) % 10 == 0)
              for (final a in warp) (g.endBoundaryX(j), a.y, g.endBoundaryX(j), a.bottom),
          for (var j = 1; j < part.rows; j++)
            if ((part.rowStart + j) % 10 == 0)
              for (final a in weft) (a.x, g.rowBoundaryY(j), a.right, g.rowBoundaryY(j)),
        ],
        _tenthLine,
        0.7);
    for (final (area, _, _) in areas) {
      _frame(canvas, area);
    }

    _paintNumbers(context, canvas);
    _paintMargins(context, canvas);
  }

  void _paintNumbers(pw.Context context, PdfGraphics canvas) {
    final g = geometry;
    final b = draft;
    final font = regular.getFont(context);
    canvas.setFillColor(_ink);
    for (var s = 1; s <= b.shafts; s++) {
      _text(canvas, font, '$s', g.shaftNumberBox(s), BookAlign.center);
    }
    final endStep = numberStep(g.cell, font.stringMetrics('${b.ends}').advanceWidth * _gridText);
    for (final e in numberedThreads(part.endStart, part.endEnd, endStep)) {
      _text(canvas, font, '${e + 1}', g.endNumberBox(e - part.endStart), BookAlign.center);
    }
    final colStep = numberStep(g.cell, font.stringMetrics('${b.columns}').advanceWidth * _gridText);
    const strip = _gridText + 2 * _numberPad;
    for (final t in numberedThreads(0, b.columns, colStep)) {
      _text(canvas, font, '${t + 1}',
          g.columnNumberBox(t + 1, liftplan: b.isLiftplan, strip: strip), BookAlign.center);
    }
    final picks = columns.picks;
    for (var r = 0; r < part.rows; r++) {
      _text(canvas, font, '${b.pickNumbers[part.rowStart + r]}',
          g.marginBox(r, offset: picks.offset, w: picks.w), BookAlign.center);
    }
  }

  void _paintMargins(pw.Context context, PdfGraphics canvas) {
    final g = geometry;
    final b = draft;
    final font = regular.getFont(context);
    final boldFont = bold.getFont(context);
    canvas.setFillColor(_ink);
    final roles = columns.roles;
    if (roles != null) {
      for (var r = 0; r < part.rows; r++) {
        final letter = b.roles[part.rowStart + r];
        if (letter.isEmpty) continue;
        _text(canvas, boldFont, letter, g.marginBox(r, offset: roles.offset, w: roles.w),
            BookAlign.center);
      }
    }
    final passes = columns.passes;
    if (passes != null) {
      for (var r = 0; r < part.rows; r++) {
        _text(canvas, font, _passToken(b.passes[part.rowStart + r], mirrored: b.corner.mirrorX),
            g.marginBox(r, offset: passes.offset, w: passes.w), BookAlign.center);
      }
    }
    final brackets = columns.brackets;
    if (brackets != null) {
      final lines = <(double, double, double, double)>[];
      for (final br in b.brackets) {
        final from = math.max(br.start, part.rowStart), to = math.min(br.end, part.rowEnd);
        if (from >= to) continue;
        final span = g.marginSpan(from - part.rowStart, to - part.rowStart,
            offset: brackets.offset, w: brackets.w);
        // The bracket stands next to the treadling (the canonical start side) with its ticks
        // pointing at the rows; an end cut off by the part edge stays open.
        final mx = b.corner.mirrorX;
        final x = mx ? span.right - _numberPad - 1 : span.x + _numberPad + 1;
        final tick = mx ? x + 2 : x - 2;
        final firstY = b.corner.mirrorY ? span.bottom - 1 : span.y + 1;
        final lastY = b.corner.mirrorY ? span.y + 1 : span.bottom - 1;
        lines.add((x, span.y + 1, x, span.bottom - 1));
        if (br.start >= part.rowStart) lines.add((x, firstY, tick, firstY));
        if (br.end <= part.rowEnd) lines.add((x, lastY, tick, lastY));
        final label = BookBox(mx ? span.x : x + 2, span.y, span.w - _numberPad - 3, span.h);
        _text(canvas, font, br.label, label, g.align(BookAlign.start));
      }
      _lines(canvas, lines, _ink, 0.8);
    }
    final strip = g.edgeLabelStrip;
    if (strip.h > 0) {
      if (b.highEndEdge != null && part.endEnd == b.ends) {
        _text(canvas, boldFont, b.highEndEdge!, strip, g.align(BookAlign.start), size: 6);
      }
      if (b.endOneEdge != null && part.endStart == 0) {
        _text(canvas, boldFont, b.endOneEdge!, strip, g.align(BookAlign.end), size: 6);
      }
    }
  }
}

/// One page-sized part of a colored drawdown: the cloth squares, the warp and weft color bands, and
/// the end and pick numbers.
class _ColorPartWidget extends pw.Widget with _GridPainter {
  _ColorPartWidget({
    required this.drawdown,
    required this.part,
    required this.geometry,
    required this.numberRow,
    required this.pickOffset,
    required this.pickWidth,
    required this.regular,
  });

  final PrintColorDrawdown drawdown;
  final BookPart part;
  final BookGeometry geometry;
  final double numberRow;
  final double pickOffset;
  final double pickWidth;
  final pw.Font regular;

  @override
  void layout(pw.Context context, pw.BoxConstraints constraints, {bool parentUsesSize = false}) {
    box = PdfRect(0, 0, geometry.width, geometry.height);
  }

  static PdfColor _pdf(int rgb) => PdfColor.fromInt(0xFF000000 | rgb);
  static int _rgb(PrintColor c) => (c.r << 16) | (c.g << 8) | c.b;

  void _fillRuns(PdfGraphics canvas, Map<int, List<BookBox>> runs) {
    for (final MapEntry(key: rgb, value: boxes) in runs.entries) {
      canvas.setFillColor(_pdf(rgb));
      for (final r in boxes) {
        _rect(canvas, r);
      }
      canvas.fillPath();
    }
  }

  @override
  void paint(pw.Context context) {
    super.paint(context);
    final canvas = context.canvas;
    final g = geometry;
    final d = drawdown;

    // The cloth: each row's runs of one color as one rectangle, one fill per color.
    final cloth = <int, List<BookBox>>{};
    for (var r = 0; r < part.rows; r++) {
      final base = (part.rowStart + r) * d.ends + part.endStart;
      var j = 0;
      while (j < part.ends) {
        final c = d.cells[base + j];
        var k = j + 1;
        while (k < part.ends && d.cells[base + k] == c) {
          k++;
        }
        (cloth[c] ??= []).add(g.drawdownRun(j, k, r));
        j = k;
      }
    }
    _fillRuns(canvas, cloth);

    // The bands: warp colors along the threading side, weft colors along the treadling side.
    final bands = <int, List<BookBox>>{};
    var j = 0;
    while (j < part.ends) {
      final c = _rgb(d.warp[part.endStart + j]);
      var k = j + 1;
      while (k < part.ends && _rgb(d.warp[part.endStart + k]) == c) {
        k++;
      }
      (bands[c] ??= []).add(g.warpBandRun(j, k, offset: _bandGap, thickness: _bandThickness));
      j = k;
    }
    for (var r = 0; r < part.rows; r++) {
      (bands[_rgb(d.weft[part.rowStart + r])] ??= [])
          .add(g.weftBandCell(r, offset: _bandGap, thickness: _bandThickness));
    }
    _fillRuns(canvas, bands);

    final warpBand = g.warpBandRun(0, part.ends, offset: _bandGap, thickness: _bandThickness);
    final weftTop = g.weftBandCell(0, offset: _bandGap, thickness: _bandThickness);
    final weftBottom = g.weftBandCell(part.rows - 1, offset: _bandGap, thickness: _bandThickness);
    final weftBand = BookBox(weftTop.x, math.min(weftTop.y, weftBottom.y), weftTop.w,
        (weftTop.y - weftBottom.y).abs() + weftTop.h);
    for (final a in [g.drawdownArea, warpBand, weftBand]) {
      _frame(canvas, a);
    }

    final font = regular.getFont(context);
    canvas.setFillColor(_ink);
    final endStep = numberStep(g.cell, font.stringMetrics('${d.ends}').advanceWidth * _gridText);
    for (final e in numberedThreads(part.endStart, part.endEnd, endStep)) {
      _text(canvas, font, '${e + 1}', g.endNumberBox(e - part.endStart, h: numberRow),
          BookAlign.center);
    }
    final rowStep = numberStep(g.cell, _gridText);
    for (final p in numberedThreads(part.rowStart, part.rowEnd, rowStep)) {
      final r = p - part.rowStart;
      _text(canvas, font, '${p + 1}', g.marginBox(r, offset: pickOffset, w: pickWidth),
          BookAlign.center);
    }
  }
}

/// A key's vector mark, drawn as the draft's grids draw it.
pw.Widget _markSymbol(PrintMark mark, double size) => pw.CustomPaint(
      size: PdfPoint(size, size),
      painter: (canvas, s) {
        final inset = s.x * 0.14;
        canvas
          ..setStrokeColor(_boxLine)
          ..setLineWidth(0.6)
          ..drawRect(0, 0, s.x, s.y)
          ..strokePath();
        switch (mark) {
          case PrintMark.filled:
            canvas
              ..setFillColor(_markInk)
              ..drawRect(inset, inset, s.x - 2 * inset, s.y - 2 * inset)
              ..fillPath();
          case PrintMark.solid:
            canvas
              ..setFillColor(_markInk)
              ..drawRect(0, 0, s.x, s.y)
              ..fillPath();
          case PrintMark.empty:
            break;
          case PrintMark.cross:
            canvas
              ..setStrokeColor(_markInk)
              ..setLineWidth(1.1)
              ..moveTo(inset, inset)
              ..lineTo(s.x - inset, s.y - inset)
              ..moveTo(inset, s.y - inset)
              ..lineTo(s.x - inset, inset)
              ..strokePath();
          case PrintMark.bracket:
            final x = s.x * 0.6;
            canvas
              ..setStrokeColor(_markInk)
              ..setLineWidth(1.1)
              ..moveTo(x - 3, s.y - 2)
              ..lineTo(x, s.y - 2)
              ..lineTo(x, 2)
              ..lineTo(x - 3, 2)
              ..strokePath();
        }
      },
    );
