import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
                    if (select) {
                      ref.read(knitSelectionProvider.notifier).state =
                          KnitSelection(row, col, row, col);
                      return;
                    }
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
