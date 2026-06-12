import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/draft_doc.dart';
import '../state/draft_editor_notifier.dart';

/// Shared cell geometry for the tie-up grid. The painter and the hit-test derive cells from the
/// EXACT SAME formula here, so a tapped pixel and the cell it fills can never disagree (a
/// transpose or off-by-one in one but not the other is structurally impossible).
///
/// LAYOUT CONVENTION: treadle 1 is the LEFT column and treadle N the right; shaft 1 is the TOP
/// row and shaft M the bottom. (Top = shaft 1 is a provisional editor convention; aligning the
/// shaft axis with the drawdown's warp axis is deferred to the threading/drawdown work.)
class TieupGeometry {
  TieupGeometry(this.size, {required this.treadles, required this.shafts})
      : cellW = treadles > 0 ? size.width / treadles : 0,
        cellH = shafts > 0 ? size.height / shafts : 0;

  final Size size;
  final int treadles;
  final int shafts;
  final double cellW;
  final double cellH;

  bool get isDegenerate => treadles <= 0 || shafts <= 0;

  /// The pixel rect of cell (treadle, shaft), both 1-based — used to PAINT a cell.
  Rect rectFor(int treadle, int shaft) =>
      Rect.fromLTWH((treadle - 1) * cellW, (shaft - 1) * cellH, cellW, cellH);

  /// The 1-based (treadle, shaft) cell at [local], or null if outside the grid. The exact
  /// INVERSE of [rectFor].
  (int, int)? cellAt(Offset local) {
    if (isDegenerate) return null;
    if (local.dx < 0 || local.dy < 0 || local.dx >= size.width || local.dy >= size.height) {
      return null;
    }
    final treadle = (local.dx ~/ cellW) + 1;
    final shaft = (local.dy ~/ cellH) + 1;
    // Guard the far edge against floating-point overshoot landing one cell past the grid.
    return (treadle.clamp(1, treadles), shaft.clamp(1, shafts));
  }
}

/// The 1-based (treadle, shaft) cell at [local] within a [size]-sized grid, or null if outside.
/// Thin wrapper over [TieupGeometry.cellAt].
(int, int)? tieupCellAt(
  Offset local,
  Size size, {
  required int treadles,
  required int shafts,
}) =>
    TieupGeometry(size, treadles: treadles, shafts: shafts).cellAt(local);

/// The editable tie-up grid for a treadled draft: [treadles] columns x [shafts] rows, a cell
/// filled when its shaft is tied to its treadle. Tapping a cell toggles it via the editor
/// notifier, which re-renders the live drawdown. A liftplan draft has no tie-up, so this shows a
/// hint instead.
class TieupGrid extends ConsumerWidget {
  const TieupGrid({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final draft = ref.watch(draftEditorProvider.select((s) => s.draft));
    final drive = draft.drive;
    final colors = Theme.of(context).colorScheme;

    if (drive is! DraftTreadled || draft.treadles <= 0 || draft.shafts <= 0) {
      return Center(
        child: Text(
          drive is DraftTreadled
              ? 'This draft declares no treadles or shafts.'
              : 'Liftplan drafts have no tie-up to edit.',
          textAlign: TextAlign.center,
          style: TextStyle(color: colors.onSurfaceVariant),
        ),
      );
    }

    final treadles = draft.treadles;
    final shafts = draft.shafts;
    return AspectRatio(
      aspectRatio: treadles / shafts,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = Size(constraints.maxWidth, constraints.maxHeight);
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (details) {
              final cell = tieupCellAt(
                details.localPosition,
                size,
                treadles: treadles,
                shafts: shafts,
              );
              if (cell != null) {
                ref
                    .read(draftEditorProvider.notifier)
                    .toggleTieupCell(cell.$1, cell.$2);
              }
            },
            child: CustomPaint(
              size: size,
              painter: TieupPainter(
                tieup: drive.tieup,
                treadles: treadles,
                shafts: shafts,
                fill: colors.primary,
                line: colors.outlineVariant,
                background: colors.surfaceContainerHighest,
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Paints the tie-up grid. Uses the SAME column/row geometry as [tieupCellAt] so a tapped pixel
/// and the cell it fills are always the same cell.
class TieupPainter extends CustomPainter {
  TieupPainter({
    required this.tieup,
    required this.treadles,
    required this.shafts,
    required this.fill,
    required this.line,
    required this.background,
  });

  final List<List<int>> tieup;
  final int treadles;
  final int shafts;
  final Color fill;
  final Color line;
  final Color background;

  @override
  void paint(Canvas canvas, Size size) {
    if (treadles <= 0 || shafts <= 0) return;
    // Same geometry the tap hit-test uses, so a filled cell and a tapped cell always agree.
    final geom = TieupGeometry(size, treadles: treadles, shafts: shafts);

    canvas.drawRect(Offset.zero & size, Paint()..color = background);

    final fillPaint = Paint()..color = fill;
    for (var t = 1; t <= treadles; t++) {
      final row = t - 1 < tieup.length ? tieup[t - 1] : const <int>[];
      for (final s in row) {
        if (s < 1 || s > shafts) continue; // ignore an out-of-range tie (validate() flags it)
        canvas.drawRect(geom.rectFor(t, s).deflate(0.5), fillPaint);
      }
    }

    final linePaint = Paint()
      ..color = line
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (var t = 0; t <= treadles; t++) {
      canvas.drawLine(Offset(t * geom.cellW, 0), Offset(t * geom.cellW, size.height), linePaint);
    }
    for (var s = 0; s <= shafts; s++) {
      canvas.drawLine(Offset(0, s * geom.cellH), Offset(size.width, s * geom.cellH), linePaint);
    }
  }

  @override
  bool shouldRepaint(TieupPainter old) =>
      // The notifier hands a NEW tie-up list on every edit, so identity is a sufficient and
      // cheap change signal; the colors/dimensions cover a theme or resize change.
      !identical(old.tieup, tieup) ||
      old.treadles != treadles ||
      old.shafts != shafts ||
      old.fill != fill ||
      old.line != line ||
      old.background != background;
}
