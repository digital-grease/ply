// Page geometry of a printed weaving BOOK DRAFT (M9-02, ADR 0012): the four quadrants (threading,
// tie-up, treadling, drawdown) on ONE shared cell pitch, in each of the four layouts Ply offers, and
// how a draft too large for a page is cut into page-sized parts. Also the parts of the colored
// drawdown. Pure math (no PDF objects), so the coordinate rules are tested directly.
//
// CANONICAL FRAME. Every box is first computed in Ply's editor layout ([BookCorner.topRight]):
//
//        [ shaft numbers ][ threading: ends ]  gap  [ tie-up: columns ]
//                          gap
//                         [ drawdown: ends ]   gap  [ treadling ][ pick numbers, roles, passes ]
//                         [ edge labels ]
//
// with end 1 in the RIGHT column of the threading and the drawdown, shaft 1 in the BOTTOM row of the
// threading and the tie-up, treadle (or lift plan shaft) 1 in the LEFT column of the tie-up and the
// treadling, and the part's first row (pick 1) at the TOP of the treadling and the drawdown, y
// growing down from the block's top-left corner. The other three layouts are that frame reflected
// left to right ([BookCorner.mirrorX]), top to bottom ([BookCorner.mirrorY]), or both, applied to
// every box at the end. So in every layout the quadrants share their axes exactly, end 1 is on the
// tie-up side, shaft 1 is the threading row next to the drawdown, treadle 1 is the tie-up column next
// to the threading, and pick 1 is the treadling row next to the tie-up. Text is placed, never
// mirrored: a box keeps its text upright and only its alignment flips with the picture.

import 'dart:math' as math;

import 'print_document.dart' show BookCorner;
import 'print_layout.dart' show kMm;

/// An axis-aligned box in points, y growing DOWN from the block's top-left corner.
class BookBox {
  const BookBox(this.x, this.y, this.w, this.h);
  final double x;
  final double y;
  final double w;
  final double h;

  double get right => x + w;
  double get bottom => y + h;
  double get centerX => x + w / 2;
  double get centerY => y + h / 2;

  /// This box reflected inside a [width] x [height] frame.
  BookBox mirrored(double width, double height, {required bool x, required bool y}) => BookBox(
        x ? width - this.x - w : this.x,
        y ? height - this.y - h : this.y,
        w,
        h,
      );

  @override
  bool operator ==(Object other) =>
      other is BookBox &&
      (other.x - x).abs() < 1e-6 &&
      (other.y - y).abs() < 1e-6 &&
      (other.w - w).abs() < 1e-6 &&
      (other.h - h).abs() < 1e-6;

  @override
  int get hashCode => Object.hash(x.round(), y.round(), w.round(), h.round());

  @override
  String toString() => 'BookBox($x, $y, $w x $h)';
}

/// How a text box aligns its text, said in the canonical frame (it flips with a left-right mirror).
enum BookAlign { start, center, end }

/// Room around the four quadrants, in points, in the canonical frame: [left] for the shaft numbers,
/// [right] for the margin columns beside the treadling, [top] for the end and treadle numbers,
/// [bottom] for the edge labels under the drawdown, and the [gap] between the quadrants.
class BookMargins {
  const BookMargins({
    this.left = 0,
    this.right = 0,
    this.top = 0,
    this.bottom = 0,
    this.gap = 2 * kMm,
  });
  final double left;
  final double right;
  final double top;
  final double bottom;
  final double gap;

  double get horizontal => left + gap + right;
  double get vertical => top + gap + bottom;
}

/// Book draft cell sizes. A whole draft that fits on one page prints at the largest cell from
/// [minCell] to [maxCell]; a draft that does not fit at [minCell] is split into page-sized parts at
/// [minCell]. Weaving drafts conventionally print small: 3 mm squares hold a clear mark and a
/// 5.5 point number, and anything smaller stops being countable by eye.
class BookCellRule {
  const BookCellRule({this.minCell = 3 * kMm, this.maxCell = 5 * kMm});
  final double minCell;
  final double maxCell;
}

/// The colored drawdown's cell sizes: it is a picture of the cloth, so it may print smaller than a
/// book draft (the book draft carries every number), but never below [minCell].
const BookCellRule kColorDrawdownCellRule = BookCellRule(minCell: 1.5 * kMm, maxCell: 4 * kMm);

/// The fewest ends and rows a split part must hold (fewer if the draft itself is smaller). A page
/// that cannot hold them, because the tie-up or the threading alone fill it, cannot print the draft.
const int kBookMinBand = 4;

/// One page-sized part: ends [endStart, endEnd) and rows [rowStart, rowEnd) (0-based; end 0 is end
/// 1, row 0 the block's first row).
class BookPart {
  const BookPart({
    required this.endStart,
    required this.endEnd,
    required this.rowStart,
    required this.rowEnd,
  });
  final int endStart;
  final int endEnd;
  final int rowStart;
  final int rowEnd;

  int get ends => endEnd - endStart;
  int get rows => rowEnd - rowStart;

  @override
  bool operator ==(Object other) =>
      other is BookPart &&
      other.endStart == endStart &&
      other.endEnd == endEnd &&
      other.rowStart == rowStart &&
      other.rowEnd == rowEnd;

  @override
  int get hashCode => Object.hash(endStart, endEnd, rowStart, rowEnd);

  @override
  String toString() => 'BookPart(ends $endStart..$endEnd, rows $rowStart..$rowEnd)';
}

/// A book draft's [cell] pitch and its [parts] in reading order. No parts (and [tooLarge]) when the
/// page cannot hold even [kBookMinBand] ends and rows beside the tie-up and under the threading.
class BookLayout {
  const BookLayout({required this.cell, required this.parts, this.tooLarge = false});
  final double cell;
  final List<BookPart> parts;
  final bool tooLarge;
}

/// Lay out a book draft of [ends] x [rows] with [shafts] threading rows and [columns] tie-up and
/// treadling columns in a [width] x [height] area (points). The shafts and columns are the quadrant
/// cells every part repeats (the threading's rows, the tie-up's columns); the colored drawdown has
/// none. Parts run from row 0 (pick 1) in bands; within a band, from end 1.
BookLayout layoutBookDraft({
  required int ends,
  required int rows,
  required int shafts,
  required int columns,
  required double width,
  required double height,
  BookMargins margins = const BookMargins(),
  BookCellRule rule = const BookCellRule(),
}) {
  if (ends <= 0 || rows <= 0) return const BookLayout(cell: 0, parts: []);
  final roomW = width - margins.horizontal;
  final roomH = height - margins.vertical;
  final fitW = roomW / (ends + columns);
  final fitH = roomH / (shafts + rows);
  final fit = math.min(fitW, fitH);
  if (fit >= rule.minCell) {
    return BookLayout(
      cell: math.min(fit, rule.maxCell),
      parts: [BookPart(endStart: 0, endEnd: ends, rowStart: 0, rowEnd: rows)],
    );
  }
  final cell = rule.minCell;
  final perEnds = ((roomW - columns * cell) / cell + 1e-9).floor();
  final perRows = ((roomH - shafts * cell) / cell + 1e-9).floor();
  if (perEnds < math.min(ends, kBookMinBand) || perRows < math.min(rows, kBookMinBand)) {
    return BookLayout(cell: cell, parts: const [], tooLarge: true);
  }
  final parts = <BookPart>[
    for (var r = 0; r < rows; r += perRows)
      for (var e = 0; e < ends; e += perEnds)
        BookPart(
          endStart: e,
          endEnd: math.min(ends, e + perEnds),
          rowStart: r,
          rowEnd: math.min(rows, r + perRows),
        ),
  ];
  return BookLayout(cell: cell, parts: parts);
}

/// The boxes of one book draft part (or one colored drawdown part, with no shafts or columns), in
/// the chosen layout. Ends and rows here are LOCAL to the part: end 0 is the part's end nearest end
/// 1, row 0 its first row.
class BookGeometry {
  BookGeometry({
    required this.cell,
    required this.margins,
    required this.shafts,
    required this.columns,
    required this.ends,
    required this.rows,
    required this.corner,
  });

  final double cell;
  final BookMargins margins;
  final int shafts;
  final int columns;
  final int ends;
  final int rows;
  final BookCorner corner;

  double get _gapX => columns > 0 ? margins.gap : 0;
  double get _gapY => shafts > 0 ? margins.gap : 0;

  /// The whole block.
  double get width => margins.left + ends * cell + _gapX + columns * cell + margins.right;
  double get height => margins.top + shafts * cell + _gapY + rows * cell + margins.bottom;

  // Canonical origins of the two columns and the two rows of quadrants.
  double get _xWarp => margins.left;
  double get _xRight => margins.left + ends * cell + _gapX;
  double get _yTop => margins.top;
  double get _yCloth => margins.top + shafts * cell + _gapY;

  BookBox _o(BookBox b) => b.mirrored(width, height, x: corner.mirrorX, y: corner.mirrorY);

  /// A canonical alignment as drawn in this layout.
  BookAlign align(BookAlign a) => !corner.mirrorX || a == BookAlign.center
      ? a
      : (a == BookAlign.start ? BookAlign.end : BookAlign.start);

  // --- quadrants ----------------------------------------------------------------------------------

  BookBox get threadingArea => _o(BookBox(_xWarp, _yTop, ends * cell, shafts * cell));
  BookBox get tieupArea => _o(BookBox(_xRight, _yTop, columns * cell, shafts * cell));
  BookBox get treadlingArea => _o(BookBox(_xRight, _yCloth, columns * cell, rows * cell));
  BookBox get drawdownArea => _o(BookBox(_xWarp, _yCloth, ends * cell, rows * cell));

  // --- cells (shaft and column are 1-based ids, as printed) --------------------------------------

  double _endX(int end) => _xWarp + (ends - 1 - end) * cell;
  double _shaftY(int shaft) => _yTop + (shafts - shaft) * cell;
  double _columnX(int column) => _xRight + (column - 1) * cell;
  double _rowY(int row) => _yCloth + row * cell;

  BookBox threadingCell(int end, int shaft) => _o(BookBox(_endX(end), _shaftY(shaft), cell, cell));
  BookBox tieupCell(int column, int shaft) =>
      _o(BookBox(_columnX(column), _shaftY(shaft), cell, cell));
  BookBox treadlingCell(int column, int row) =>
      _o(BookBox(_columnX(column), _rowY(row), cell, cell));
  BookBox drawdownCell(int end, int row) => _o(BookBox(_endX(end), _rowY(row), cell, cell));

  /// Ends [from, to) of one row of the drawdown as a single box (adjacent ends are adjacent cells).
  BookBox drawdownRun(int from, int to, int row) =>
      _o(BookBox(_endX(to - 1), _rowY(row), (to - from) * cell, cell));

  /// One row of the band beside the drawdown on the treadling side (the colored drawdown's weft band),
  /// [thickness] wide, starting [offset] beyond the drawdown.
  BookBox weftBandCell(int row, {required double offset, required double thickness}) =>
      _o(BookBox(_xWarp + ends * cell + offset, _rowY(row), thickness, cell));

  /// Ends [from, to) of the band on the threading side of the drawdown (the warp band), [thickness]
  /// tall, ending [offset] before the drawdown.
  BookBox warpBandRun(int from, int to, {required double offset, required double thickness}) =>
      _o(BookBox(_endX(to - 1), _yCloth - offset - thickness, (to - from) * cell, thickness));

  // --- lines ---------------------------------------------------------------------------------------

  /// The x of the boundary between local ends [j] - 1 and [j] (0 < j < ends), in this layout.
  double endBoundaryX(int j) {
    final x = _xWarp + (ends - j) * cell;
    return corner.mirrorX ? width - x : x;
  }

  /// The y of the boundary between local rows [j] - 1 and [j], in this layout.
  double rowBoundaryY(int j) {
    final y = _yCloth + j * cell;
    return corner.mirrorY ? height - y : y;
  }

  // --- numbers and margin columns ------------------------------------------------------------------

  /// Where shaft [shaft]'s number goes: the margin outside the threading.
  BookBox shaftNumberBox(int shaft) => _o(BookBox(0, _shaftY(shaft), margins.left, cell));

  /// Where end [end]'s number goes: the outer [h] points of the margin outside the threading (the
  /// whole margin by default).
  BookBox endNumberBox(int end, {double? h}) => _o(BookBox(_endX(end), 0, cell, h ?? margins.top));

  /// Where column [column]'s number goes: outside the tie-up for a treadled draft; for a lift plan
  /// (no tie-up) the strip of the empty tie-up corner next to the lift plan, [strip] high.
  BookBox columnNumberBox(int column, {required bool liftplan, required double strip}) => liftplan
      ? _o(BookBox(_columnX(column), _yCloth - _gapY - strip, cell, strip))
      : _o(BookBox(_columnX(column), 0, cell, margins.top));

  /// A margin column beside the treadling, [offset] beyond it and [w] wide, at row [row].
  BookBox marginBox(int row, {required double offset, required double w}) =>
      _o(BookBox(_xRight + columns * cell + offset, _rowY(row), w, cell));

  /// A margin column beside the treadling over rows [from, to).
  BookBox marginSpan(int from, int to, {required double offset, required double w}) =>
      _o(BookBox(_xRight + columns * cell + offset, _rowY(from), w, (to - from) * cell));

  /// The edge-label strip outside the drawdown, as wide as the drawdown.
  BookBox get edgeLabelStrip =>
      _o(BookBox(_xWarp, _yCloth + rows * cell, ends * cell, margins.bottom));
}

/// The ends (or rows) of a part whose number is printed: every multiple of [step], and the first
/// thread overall when [step] is at least 5 (so it never crowds its neighbour). Global 0-based
/// indices in [start, end); thread i is number i + 1.
List<int> numberedThreads(int start, int end, int step) => [
      for (var i = start; i < end; i++)
        if ((i + 1) % step == 0 || (i == 0 && step >= 5)) i,
    ];

/// The smallest step from 1, 2, 5, 10, 20, 50, 100... at which labels [labelWidth] wide fit side by
/// side in cells [cell] wide with [pad] between them (steps a weaver counts in).
int numberStep(double cell, double labelWidth, {double pad = 1.5}) {
  if (cell <= 0) return 1;
  for (final s in const [1, 2, 5, 10, 20, 50, 100, 200, 500, 1000]) {
    if (s * cell >= labelWidth + pad) return s;
  }
  return 1000;
}
