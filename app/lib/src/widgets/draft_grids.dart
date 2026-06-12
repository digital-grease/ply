// The three interactive grids of the integrated draft view: threading (top), tie-up (top-right),
// and the right band (treadling for a treadled draft, liftplan for a liftplan draft). Each is a
// ConsumerWidget that watches ONLY its own data slice (so a tie-up edit never rebuilds threading)
// and paints filled cells through the shared [RegionGeom] from DraftLayout — the SAME geometry the
// gesture router hit-tests, so a painted cell and a tapped cell can never disagree. None of these
// paints the drawdown or re-implements shed logic; the cloth is the engine bitmap (RawImage).
//
// None has its own GestureDetector: the parent IntegratedDraftView owns one content-space Listener
// that routes pointers to the right region. These widgets are pure presentation of a data slice.

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/draft_doc.dart';
import '../state/draft_editor_notifier.dart';
import 'draft_layout.dart';

/// Paints a region's grid lines and its filled cells (given in the region's own 1-based/0-based
/// (col, row) terms) at [geom]'s cell rects.
class CellGridPainter extends CustomPainter {
  CellGridPainter({
    required this.cells,
    required this.geom,
    required this.fill,
    required this.line,
    required this.background,
  });

  final List<(int, int)> cells; // (col, row) filled cells, region-local terms
  final RegionGeom geom;
  final Color fill;
  final Color line;
  final Color background;

  @override
  void paint(Canvas canvas, Size size) {
    if (geom.isDegenerate) return;
    // Single source of truth: everything (background, cells, grid lines) is derived from `geom`,
    // never the passed `size`. The Positioned.fromRect sizes the CustomPaint to exactly geom.size,
    // which this assert pins so a future rect/geom divergence fails loudly instead of mis-painting.
    assert(size == geom.size, 'CellGridPainter size $size != geom.size ${geom.size}');
    final gsize = geom.size;
    canvas.drawRect(Offset.zero & gsize, Paint()..color = background);

    final fillPaint = Paint()..color = fill;
    for (final (col, row) in cells) {
      canvas.drawRect(geom.rectFor(col, row).deflate(0.5), fillPaint);
    }

    final linePaint = Paint()
      ..color = line
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (var c = 0; c <= geom.cols; c++) {
      final x = c * geom.cell;
      canvas.drawLine(Offset(x, 0), Offset(x, gsize.height), linePaint);
    }
    for (var r = 0; r <= geom.rows; r++) {
      final y = r * geom.cell;
      canvas.drawLine(Offset(0, y), Offset(gsize.width, y), linePaint);
    }
  }

  @override
  bool shouldRepaint(CellGridPainter old) =>
      geom != old.geom ||
      fill != old.fill ||
      line != old.line ||
      background != old.background ||
      !listEquals(cells, old.cells);
}

/// Threading grid: per warp end, the shaft(s) it threads through. Cells are (end, shaft).
class ThreadingGrid extends ConsumerWidget {
  const ThreadingGrid({required this.geom, super.key});

  final RegionGeom geom;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final threading = ref.watch(draftEditorProvider.select((s) => s.draft.threading));
    final cells = <(int, int)>[
      for (var end = 1; end <= geom.cols; end++)
        if (end - 1 < threading.length)
          for (final shaft in threading[end - 1])
            if (shaft >= 1 && shaft <= geom.rows) (end, shaft),
    ];
    return _grid(context, cells);
  }

  Widget _grid(BuildContext context, List<(int, int)> cells) {
    final colors = Theme.of(context).colorScheme;
    return CustomPaint(
      size: geom.size,
      painter: CellGridPainter(
        cells: cells,
        geom: geom,
        fill: colors.primary,
        line: colors.outlineVariant,
        background: colors.surfaceContainerHighest,
      ),
    );
  }
}

/// Tie-up grid (treadled drafts): per treadle, the shaft(s) it is tied to. Cells are (treadle,
/// shaft), shaft-1-at-bottom (the geom owns the flip).
class TieupGrid extends ConsumerWidget {
  const TieupGrid({required this.geom, super.key});

  final RegionGeom geom;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tieup = ref.watch(draftEditorProvider.select((s) {
      final d = s.draft.drive;
      return d is DraftTreadled ? d.tieup : const <List<int>>[];
    }));
    final cells = <(int, int)>[
      for (var t = 1; t <= geom.cols; t++)
        if (t - 1 < tieup.length)
          for (final shaft in tieup[t - 1])
            if (shaft >= 1 && shaft <= geom.rows) (t, shaft),
    ];
    final colors = Theme.of(context).colorScheme;
    return CustomPaint(
      size: geom.size,
      painter: CellGridPainter(
        cells: cells,
        geom: geom,
        fill: colors.primary,
        line: colors.outlineVariant,
        background: colors.surfaceContainerHighest,
      ),
    );
  }
}

/// Right band: per pick, the pressed treadle(s) (treadled, col=treadle) OR raised shaft(s)
/// (liftplan, col=shaft). Cells are (col, pick), pick-0-at-bottom (the geom owns the flip).
class RightGrid extends ConsumerWidget {
  const RightGrid({required this.geom, super.key});

  final RegionGeom geom;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = ref.watch(draftEditorProvider.select((s) {
      final d = s.draft.drive;
      return d is DraftTreadled ? d.treadling : (d as DraftLiftplan).liftplan;
    }));
    final cells = <(int, int)>[
      for (var pick = 0; pick < geom.rows; pick++)
        if (pick < rows.length)
          for (final col in rows[pick])
            if (col >= 1 && col <= geom.cols) (col, pick),
    ];
    final colors = Theme.of(context).colorScheme;
    return CustomPaint(
      size: geom.size,
      painter: CellGridPainter(
        cells: cells,
        geom: geom,
        fill: colors.primary,
        line: colors.outlineVariant,
        background: colors.surfaceContainerHighest,
      ),
    );
  }
}
