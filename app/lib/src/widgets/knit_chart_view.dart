import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../rust/knit_dto.dart';
import '../state/knit_editor_providers.dart';

/// Width (px) of the right gutter that carries row numbers, and height of the bottom gutter that
/// carries stitch numbers. Fixed so 3-digit counts (up to a few hundred rows) fit.
const double _rowGutter = 28;
const double _colGutter = 16;

/// The 1-based number shown for cell index [i] on an axis of [count] cells. A ROW counts UP from the
/// bottom (`i + 1`, since row 0 draws at the bottom); a STITCH counts RIGHT-TO-LEFT (`count - i`, so
/// the rightmost column is 1) to match the knitting reading order — the same order the written
/// instructions and the validation columns use.
int axisNumberAt({required bool row, required int i, required int count}) => row ? i + 1 : count - i;

/// One repeat bracket to draw: storage columns `[colStart, colEnd)` on chart rows [rowLo]..[rowHi]
/// (row 0 at the bottom), worked [count]. Consecutive rows that mark the same columns and count share
/// one box, the way printed charts draw a repeat box.
class RepeatBox {
  const RepeatBox({
    required this.colStart,
    required this.colEnd,
    required this.rowLo,
    required this.rowHi,
    required this.count,
  });
  final int colStart;
  final int colEnd;
  final int rowLo;
  final int rowHi;
  final RepeatDto count;

  @override
  bool operator ==(Object other) =>
      other is RepeatBox &&
      other.colStart == colStart &&
      other.colEnd == colEnd &&
      other.rowLo == rowLo &&
      other.rowHi == rowHi &&
      other.count == count;

  @override
  int get hashCode => Object.hash(colStart, colEnd, rowLo, rowHi, count);

  @override
  String toString() => 'RepeatBox($colStart..$colEnd, rows $rowLo..$rowHi, $count)';
}

/// The repeat brackets for [chart]: every row's authored repeats, clipped to the chart width (a span
/// with nothing left inside the chart is not drawn; validation reports it), merged upward across
/// consecutive rows with the same columns and count. The chart itself keeps showing the drawn cells.
List<RepeatBox> repeatBoxes(ChartDto chart) {
  final done = <RepeatBox>[];
  // Boxes still open after the previous row, keyed by (start, end, count).
  var open = <(int, int, RepeatDto), RepeatBox>{};
  for (var r = 0; r < chart.rows.length; r++) {
    final next = <(int, int, RepeatDto), RepeatBox>{};
    for (final s in chart.rows[r].repeats) {
      final start = s.start.clamp(0, chart.width);
      final end = s.end.clamp(0, chart.width);
      if (start >= end) continue;
      final key = (start, end, s.count);
      if (next.containsKey(key)) continue; // a duplicate span on one row draws once
      final below = open.remove(key);
      next[key] = below == null
          ? RepeatBox(colStart: start, colEnd: end, rowLo: r, rowHi: r, count: s.count)
          : RepeatBox(colStart: start, colEnd: end, rowLo: below.rowLo, rowHi: r, count: s.count);
    }
    done.addAll(open.values); // not continued on this row
    open = next;
  }
  done.addAll(open.values);
  done.sort((a, b) => a.rowLo != b.rowLo ? a.rowLo.compareTo(b.rowLo) : a.colStart.compareTo(b.colStart));
  return done;
}

/// The short label drawn on a repeat bracket: "×3", or "to end".
String repeatLabel(RepeatDto count) => switch (count) {
      RepeatDto_Times(:final count) => '×$count',
      RepeatDto_ToEnd() => 'to end',
    };

/// A screen-reader description of a repeat box on a chart [width] stitches wide, numbering stitches
/// as the bottom axis does (right to left): "stitches 2 to 5, rows 1 to 4, 3 times".
String describeRepeatBox(RepeatBox b, int width) {
  final first = width - (b.colEnd - 1);
  final last = width - b.colStart;
  final stitches = first == last ? 'stitch $first' : 'stitches $first to $last';
  final rows = b.rowLo == b.rowHi ? 'row ${b.rowLo + 1}' : 'rows ${b.rowLo + 1} to ${b.rowHi + 1}';
  final times = switch (b.count) {
    RepeatDto_Times(:final count) => count == 1 ? 'once' : '$count times',
    RepeatDto_ToEnd() => 'to the end of the row',
  };
  return '$stitches, $rows, $times';
}

/// The editable knitting chart: the engine-rendered RGBA chart (symbols + colorwork + cable spans)
/// shown 1:1, with tap-to-paint. Rows draw BOTTOM-TO-TOP (row 0 at the bottom, the knitting reading
/// order), so a tap's pixel row is flipped back to a chart row. Numbered gutters sit to the RIGHT (row
/// numbers, 1 at the bottom) and ALONG THE BOTTOM (stitch numbers, 1 at the right — the RS reading
/// start), keeping the chart itself at the top-left origin so the tap math is unchanged.
class KnitChartView extends ConsumerWidget {
  const KnitChartView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dims = ref.watch(knitEditorProvider
        .select((s) => (s.pattern.chart.width, s.pattern.chart.rows.length)));
    final cell = ref.watch(knitZoomProvider);
    final cols = dims.$1;
    final rows = dims.$2;

    if (cols == 0 || rows == 0) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'This chart is empty.\nUse the bar below to add rows and columns, then tap to paint.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ),
      );
    }

    final w = (cols * cell).toDouble();
    final h = (rows * cell).toDouble();
    final cs = Theme.of(context).colorScheme;
    final labelColor = cs.onSurfaceVariant;
    final select = ref.watch(knitToolProvider) == KnitTool.select;
    final selection = ref.watch(knitSelectionProvider);
    // The inline validation bar is a Column sibling BELOW the chart; when issues appear it steals
    // viewport height and the preserved scroll offset would hide the bottom — the FIRST — chart row.
    // Reserve scroll clearance below the chart sized to the bar's collapsed/expanded footprint (zero
    // when the chart is clean) so the first row can always be scrolled clear of it.
    final hasIssues = ref.watch(knitValidationProvider.select((v) => v.valueOrNull?.isNotEmpty ?? false));
    final issuesExpanded = ref.watch(knitIssuesExpandedProvider);
    final bottomClearance = !hasIssues ? 0.0 : (issuesExpanded ? 210.0 : 56.0);
    // Map a pointer position (chart-local) to a clamped (row, col); row 0 is at the BOTTOM.
    (int, int) cellAt(Offset p) {
      final col = (p.dx ~/ cell).clamp(0, cols - 1);
      final rowFromTop = (p.dy ~/ cell).clamp(0, rows - 1);
      return (rows - 1 - rowFromTop, col);
    }

    return SingleChildScrollView(
      scrollDirection: Axis.vertical,
      // SELECT freezes the scroll so a drag selects a region instead of scrolling.
      physics: select ? const NeverScrollableScrollPhysics() : null,
      padding: EdgeInsets.only(bottom: bottomClearance),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        physics: select ? const NeverScrollableScrollPhysics() : null,
        child: SizedBox(
          width: w + _rowGutter,
          height: h + _colGutter,
          child: Stack(
            children: [
              // The chart bitmap + tap/drag target, at the top-left origin (unchanged geometry).
              Positioned(
                left: 0,
                top: 0,
                width: w,
                height: h,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: (d) {
                    final (row, col) = cellAt(d.localPosition);
                    // A single TAP always PAINTS the cell — in BOTH tools — so a brush (a stitch OR a
                    // colorwork color) never silently fails to apply. The SELECT tool only changes what
                    // a DRAG does: it draws a rectangular fill region (then the header's Fill action
                    // applies the brush across it), instead of scrolling the chart. A tap therefore
                    // supersedes any pending drag-region.
                    final stitch = ref.read(activeKnitStitchProvider);
                    final brush = ref.read(activeKnitColorProvider);
                    ref.read(knitEditorProvider.notifier).paintCell(
                          row,
                          col,
                          stitch,
                          brush >= 0 ? brush : null,
                          keepColor: brush == knitColorKeep,
                          keepStitch: stitch == knitStitchKeep,
                        );
                    if (select) ref.read(knitSelectionProvider.notifier).state = null;
                  },
                  onPanStart: select
                      ? (d) {
                          final (row, col) = cellAt(d.localPosition);
                          ref.read(knitSelectionProvider.notifier).state =
                              KnitSelection(row, col, row, col);
                        }
                      : null,
                  onPanUpdate: select
                      ? (d) {
                          final sel = ref.read(knitSelectionProvider);
                          if (sel == null) return;
                          final (row, col) = cellAt(d.localPosition);
                          ref.read(knitSelectionProvider.notifier).state = sel.toCurrent(row, col);
                        }
                      : null,
                  child: Semantics(
                    label: 'Knitting chart, $cols stitches by $rows rows',
                    image: true,
                    child: const RepaintBoundary(child: _KnitChartImage()),
                  ),
                ),
              ),
              // Repeat brackets over the drawn cells (the motif is drawn once; the label says how often
              // it is worked). Pointer-transparent so taps still paint.
              Positioned(
                left: 0,
                top: 0,
                width: w,
                height: h,
                child: _RepeatOverlay(cell: cell.toDouble()),
              ),
              // The selection rectangle (SELECT tool), drawn over the cloth and ignoring pointers.
              if (selection != null)
                Positioned(
                  left: selection.colMin.clamp(0, cols - 1) * cell.toDouble(),
                  top: (rows - 1 - selection.rowMax.clamp(0, rows - 1)) * cell.toDouble(),
                  width: (selection.colMax.clamp(0, cols - 1) - selection.colMin.clamp(0, cols - 1) + 1) *
                      cell.toDouble(),
                  height: (selection.rowMax.clamp(0, rows - 1) - selection.rowMin.clamp(0, rows - 1) + 1) *
                      cell.toDouble(),
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: cs.primary.withValues(alpha: 0.18),
                        border: Border.all(color: cs.primary, width: 2),
                      ),
                    ),
                  ),
                ),
              // Row numbers down the right side (1 at the bottom, counting up).
              Positioned(
                left: w,
                top: 0,
                width: _rowGutter,
                height: h,
                child: CustomPaint(
                  painter: _AxisNumbers(count: rows, cell: cell.toDouble(), color: labelColor, row: true),
                ),
              ),
              // Stitch numbers along the bottom (1 at the right, counting left).
              Positioned(
                left: 0,
                top: h,
                width: w,
                height: _colGutter,
                child: CustomPaint(
                  painter: _AxisNumbers(count: cols, cell: cell.toDouble(), color: labelColor, row: false),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The repeat brackets layer. Its own consumer, so marking or painting re-draws the brackets without
/// rebuilding the chart view around them.
class _RepeatOverlay extends ConsumerWidget {
  const _RepeatOverlay({required this.cell});

  final double cell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chart = ref.watch(knitEditorProvider.select((s) => s.pattern.chart));
    final boxes = repeatBoxes(chart);
    if (boxes.isEmpty) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    return IgnorePointer(
      child: Semantics(
        label: 'Repeats: ${boxes.map((b) => describeRepeatBox(b, chart.width)).join('; ')}',
        child: CustomPaint(
          painter: _RepeatBrackets(
            boxes: boxes,
            rows: chart.rows.length,
            cell: cell,
            color: cs.tertiary,
            onColor: cs.onTertiary,
          ),
        ),
      ),
    );
  }
}

/// Paints each [RepeatBox] as an outlined box over its cells with a small count label ("×3" or "to
/// end") in its top-right corner (the right-side reading start).
class _RepeatBrackets extends CustomPainter {
  _RepeatBrackets({
    required this.boxes,
    required this.rows,
    required this.cell,
    required this.color,
    required this.onColor,
  });

  final List<RepeatBox> boxes;
  final int rows;
  final double cell;
  final Color color;
  final Color onColor;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final fill = Paint()..color = color;
    final fontSize = (cell * 0.42).clamp(8.0, 11.0);
    for (final b in boxes) {
      final rect = Rect.fromLTRB(
        b.colStart * cell,
        (rows - 1 - b.rowHi) * cell,
        b.colEnd * cell,
        (rows - b.rowLo) * cell,
      ).deflate(1);
      canvas.drawRect(rect, stroke);
      final tp = TextPainter(
        text: TextSpan(
          text: repeatLabel(b.count),
          style: TextStyle(color: onColor, fontSize: fontSize, fontWeight: FontWeight.w600),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final pill = Rect.fromLTWH(
        (rect.right - tp.width - 6).clamp(0.0, size.width),
        rect.top,
        tp.width + 6,
        tp.height + 2,
      );
      canvas.drawRRect(RRect.fromRectAndRadius(pill, const Radius.circular(3)), fill);
      tp.paint(canvas, Offset(pill.left + 3, pill.top + 1));
    }
  }

  @override
  bool shouldRepaint(covariant _RepeatBrackets old) =>
      old.boxes.length != boxes.length ||
      !old.boxes.indexed.every((e) => e.$2 == boxes[e.$1]) ||
      old.rows != rows ||
      old.cell != cell ||
      old.color != color ||
      old.onColor != onColor;
}

/// Paints the numbers for one axis into its gutter. For ROWS the strip is vertical (number `i+1` at
/// the center of row `i`, row 0 at the BOTTOM); for STITCHES it is horizontal (number counts
/// right-to-left, so the rightmost column is 1). Labels thin out when cells are small so they stay
/// legible: every cell at a comfortable zoom, every 5th/10th when tight.
class _AxisNumbers extends CustomPainter {
  _AxisNumbers({required this.count, required this.cell, required this.color, required this.row});

  final int count;
  final double cell;
  final Color color;
  final bool row;

  static int _step(double cell) => cell >= 16 ? 1 : (cell >= 10 ? 5 : 10);

  @override
  void paint(Canvas canvas, Size size) {
    final step = _step(cell);
    final fontSize = (cell * 0.5).clamp(8.0, 12.0);
    for (var i = 0; i < count; i++) {
      final number = axisNumberAt(row: row, i: i, count: count);
      if (number != 1 && number % step != 0) continue;
      final tp = TextPainter(
        text: TextSpan(text: '$number', style: TextStyle(color: color, fontSize: fontSize)),
        textDirection: TextDirection.ltr,
      )..layout();
      final Offset center = row
          ? Offset(size.width / 2, size.height - (i + 0.5) * cell) // row 0 at the bottom
          : Offset((i + 0.5) * cell, size.height / 2);
      tp.paint(canvas, center - Offset(tp.width / 2, tp.height / 2));
    }
  }

  @override
  bool shouldRepaint(covariant _AxisNumbers old) =>
      old.count != count || old.cell != cell || old.color != color || old.row != row;
}

/// The engine-rendered chart bitmap. During a re-render the previous frame stays
/// (skipLoadingOnReload) so a fast edit never flashes.
class _KnitChartImage extends ConsumerWidget {
  const _KnitChartImage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preview = ref.watch(knitPreviewProvider);
    final colors = Theme.of(context).colorScheme;
    return preview.when(
      skipLoadingOnReload: true,
      data: (img) => RawImage(
        image: img,
        fit: BoxFit.fill,
        filterQuality: FilterQuality.none,
        isAntiAlias: false,
      ),
      loading: () => ColoredBox(color: colors.surfaceContainerHighest),
      error: (e, _) => ColoredBox(color: colors.errorContainer),
    );
  }
}
