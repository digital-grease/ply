import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/knit_editor_providers.dart';

/// The editable knitting chart: the engine-rendered RGBA chart (symbols + colorwork + cable spans)
/// shown 1:1, with tap-to-paint. Rows draw BOTTOM-TO-TOP (row 0 at the bottom, the knitting reading
/// order), so a tap's pixel row is flipped back to a chart row.
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
    return SingleChildScrollView(
      scrollDirection: Axis.vertical,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: w,
          height: h,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (d) {
              final col = d.localPosition.dx ~/ cell;
              final rowFromTop = d.localPosition.dy ~/ cell;
              final row = rows - 1 - rowFromTop; // row 0 is at the BOTTOM
              if (col < 0 || col >= cols || row < 0 || row >= rows) return;
              final stitch = ref.read(activeKnitStitchProvider);
              final color = ref.read(activeKnitColorProvider);
              ref.read(knitEditorProvider.notifier).paintCell(row, col, stitch, color);
            },
            child: Semantics(
              label: 'Knitting chart, $cols stitches by $rows rows',
              image: true,
              child: const RepaintBoundary(child: _KnitChartImage()),
            ),
          ),
        ),
      ),
    );
  }
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
