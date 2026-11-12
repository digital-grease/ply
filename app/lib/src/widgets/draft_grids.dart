// The three interactive grids of the integrated draft view: threading (top), tie-up (top-right),
// and the right band (treadling for a treadled draft, liftplan for a liftplan draft). Each is a
// ConsumerWidget that watches ONLY its own data slice (so a tie-up edit never rebuilds threading)
// and paints filled cells through the shared [RegionGeom] from DraftLayout — the SAME geometry the
// gesture router hit-tests, so a painted cell and a tapped cell can never disagree. None of these
// paints the drawdown or re-implements shed logic; the cloth is the engine bitmap (RawImage).
//
// None has its own GestureDetector: the parent IntegratedDraftView owns one content-space Listener
// that routes pointers to the right region. These widgets are pure presentation of a data slice.
//
// VISIBLE CELLS ONLY. A large draft's grids are far bigger than the screen (100,000 picks at 6 px is
// 600,000 px of treadling), so each painter can take a [GridWindow]: the part of the canvas in view
// (plus a margin), shared by every grid of the integrated view and updated as it scrolls. The painter
// then draws its background, filled cells and grid lines only over the cells in that window, and
// repaints when the window moves. Without a window (a grid on its own, as in tests) it paints
// everything, exactly as before.

import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable, listEquals;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/draft_doc.dart';
import '../state/draft_editor_notifier.dart';
import 'draft_layout.dart';

/// The part of the integrated canvas worth painting, as seen by one grid: [visible] is the
/// CANVAS-space rect in view (plus a margin), shared by every grid and updated as the view scrolls;
/// [origin] is this grid's top-left in canvas space.
@immutable
class GridWindow {
  const GridWindow(this.visible, this.origin);

  final ValueListenable<Rect> visible;
  final Offset origin;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GridWindow && identical(visible, other.visible) && origin == other.origin;

  @override
  int get hashCode => Object.hash(identityHashCode(visible), origin);
}

/// The cell-aligned part of [geom]'s LOCAL area to paint: all of it without a [window], otherwise
/// the whole cells that the window touches (empty when the grid is out of view).
Rect gridPaintArea(RegionGeom geom, GridWindow? window) {
  final full = Offset.zero & geom.size;
  if (window == null) return full;
  final seen = window.visible.value.shift(-window.origin).intersect(full);
  if (seen.width <= 0 || seen.height <= 0) return Rect.zero;
  final c = geom.cell;
  return Rect.fromLTRB(
    (seen.left / c).floor() * c,
    (seen.top / c).floor() * c,
    math.min(full.right, (seen.right / c).ceil() * c),
    math.min(full.bottom, (seen.bottom / c).ceil() * c),
  );
}

/// Remembers values derived from an immutable document list (the editor's lists are sealed, and an
/// edit reuses every unchanged list by reference), keyed on that list's identity plus [key]. A
/// rebuild that changes only the pitch (every zoom step rebuilds every grid) then reuses the cell
/// list, the colors and the screen-reader text instead of walking every end or pick again, which
/// keeps a 100,000-pick draft's zoom responsive. Weakly held: a dropped document frees its entries.
class _ListMemo<T> {
  final Expando<(Object, T)> _cache = Expando<(Object, T)>();

  T of(List<Object?> list, Object key, T Function() compute) {
    final hit = _cache[list];
    if (hit != null && hit.$1 == key) return hit.$2;
    final value = compute();
    _cache[list] = (key, value);
    return value;
  }
}

final _threadingCells = _ListMemo<List<(int, int)>>();
final _rightCells = _ListMemo<List<(int, int)>>();
final _bandCells = _ListMemo<(List<(int, int)>, List<Color>)>();
final _bandValues = _ListMemo<String>();

/// The grid lines of [geom] over [area] (a [gridPaintArea]): every column and row boundary inside
/// it, each spanning the area. Over the whole grid this is every line, edge to edge.
void _paintGridLines(Canvas canvas, RegionGeom geom, Rect area, Color line) {
  final linePaint = Paint()
    ..color = line
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1;
  final cell = geom.cell;
  for (var c = (area.left / cell).round(); c <= (area.right / cell).round(); c++) {
    final x = c * cell;
    canvas.drawLine(Offset(x, area.top), Offset(x, area.bottom), linePaint);
  }
  for (var r = (area.top / cell).round(); r <= (area.bottom / cell).round(); r++) {
    final y = r * cell;
    canvas.drawLine(Offset(area.left, y), Offset(area.right, y), linePaint);
  }
}

/// Paints a region's grid lines and its filled cells (given in the region's own 1-based/0-based
/// (col, row) terms) at [geom]'s cell rects. With a [window], only the cells in view are drawn.
class CellGridPainter extends CustomPainter {
  CellGridPainter({
    required this.cells,
    required this.geom,
    required this.fill,
    required this.line,
    required this.background,
    this.window,
  }) : super(repaint: window?.visible);

  final List<(int, int)> cells; // (col, row) filled cells, region-local terms
  final RegionGeom geom;
  final Color fill;
  final Color line;
  final Color background;
  final GridWindow? window;

  @override
  void paint(Canvas canvas, Size size) {
    if (geom.isDegenerate) return;
    // Single source of truth: everything (background, cells, grid lines) is derived from `geom`,
    // never the passed `size`. The Positioned.fromRect sizes the CustomPaint to exactly geom.size,
    // which this assert pins so a future rect/geom divergence fails loudly instead of mis-painting.
    assert(size == geom.size, 'CellGridPainter size $size != geom.size ${geom.size}');
    final area = gridPaintArea(geom, window);
    if (area.isEmpty) return;
    canvas.drawRect(area, Paint()..color = background);

    final fillPaint = Paint()..color = fill;
    for (final (col, row) in cells) {
      final rect = geom.rectFor(col, row);
      if (area.overlaps(rect)) canvas.drawRect(rect.deflate(0.5), fillPaint);
    }

    _paintGridLines(canvas, geom, area, line);
  }

  @override
  bool shouldRepaint(CellGridPainter old) =>
      geom != old.geom ||
      fill != old.fill ||
      line != old.line ||
      background != old.background ||
      window != old.window ||
      !listEquals(cells, old.cells);
}

/// Threading grid: per warp end, the shaft(s) it threads through. Cells are (end, shaft).
class ThreadingGrid extends ConsumerWidget {
  const ThreadingGrid({required this.geom, this.window, super.key});

  final RegionGeom geom;

  /// The part of the canvas in view; null paints every cell.
  final GridWindow? window;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final threading = ref.watch(draftEditorProvider.select((s) => s.draft.threading));
    final cells = _threadingCells.of(threading, (geom.cols, geom.rows), () => [
          for (var end = 1; end <= geom.cols; end++)
            if (end - 1 < threading.length)
              for (final shaft in threading[end - 1])
                if (shaft >= 1 && shaft <= geom.rows) (end, shaft),
        ]);
    return _grid(context, cells);
  }

  Widget _grid(BuildContext context, List<(int, int)> cells) {
    final colors = Theme.of(context).colorScheme;
    // Compact structural label only (geom.cols = ends, geom.rows = shafts), so it stays O(1) and
    // updates on resize. Per-cell semantics + screen-reader editing of individual threadings is
    // future work (would need a Semantics node per cell, too costly for a large draft).
    return Semantics(
      label: 'Threading: ${geom.cols} warp ends across ${geom.rows} shafts',
      container: true,
      child: CustomPaint(
        size: geom.size,
        painter: CellGridPainter(
          cells: cells,
          geom: geom,
          fill: colors.primary,
          line: colors.outlineVariant,
          background: colors.surfaceContainerHighest,
          window: window,
        ),
      ),
    );
  }
}

/// Tie-up grid (treadled drafts): per treadle, the shaft(s) it is tied to. Cells are (treadle,
/// shaft), shaft-1-at-bottom (the geom owns the flip).
class TieupGrid extends ConsumerWidget {
  const TieupGrid({required this.geom, this.window, super.key});

  final RegionGeom geom;

  /// The part of the canvas in view; null paints every cell.
  final GridWindow? window;

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
    // Compact structural label only (geom.cols = treadles, geom.rows = shafts); per-cell semantics
    // + screen-reader editing of individual ties is future work.
    return Semantics(
      label: 'Tie-up: ${geom.cols} treadles by ${geom.rows} shafts',
      container: true,
      child: CustomPaint(
        size: geom.size,
        painter: CellGridPainter(
          cells: cells,
          geom: geom,
          fill: colors.primary,
          line: colors.outlineVariant,
          background: colors.surfaceContainerHighest,
          window: window,
        ),
      ),
    );
  }
}

/// Paints a COLOR band: each cell filled with its OWN palette color (one [Color] per cell, parallel
/// to [cells]), plus the same grid lines as [CellGridPainter]. Used by the warp/weft color bands.
class ColorBandPainter extends CustomPainter {
  ColorBandPainter({
    required this.colors,
    required this.cells,
    required this.geom,
    required this.line,
    required this.background,
    this.window,
  }) : super(repaint: window?.visible);

  final List<Color> colors; // parallel to [cells]
  final List<(int, int)> cells; // (col, row) per cell, region-local terms
  final RegionGeom geom;
  final Color line;
  final Color background;
  final GridWindow? window;

  @override
  void paint(Canvas canvas, Size size) {
    if (geom.isDegenerate) return;
    assert(size == geom.size, 'ColorBandPainter size $size != geom.size ${geom.size}');
    final area = gridPaintArea(geom, window);
    if (area.isEmpty) return;
    canvas.drawRect(area, Paint()..color = background);

    for (var i = 0; i < cells.length; i++) {
      final (col, row) = cells[i];
      final rect = geom.rectFor(col, row);
      if (area.overlaps(rect)) canvas.drawRect(rect.deflate(0.5), Paint()..color = colors[i]);
    }

    _paintGridLines(canvas, geom, area, line);
  }

  @override
  bool shouldRepaint(ColorBandPainter old) =>
      geom != old.geom ||
      line != old.line ||
      background != old.background ||
      window != old.window ||
      !listEquals(cells, old.cells) ||
      !listEquals(colors, old.colors);
}

/// The opaque RGB of palette entry [idx]. An OUT-OF-RANGE index renders WHITE, exactly as the engine
/// drawdown does (`render_rgba` uses `palette.get(idx).unwrap_or(WHITE)`), so the band and the cloth
/// never disagree on a dangling reference (which `validate()` separately flags as an Error).
Color _swatch(List<DraftColor> palette, int idx) {
  if (idx < 0 || idx >= palette.length) return const Color(0xFFFFFFFF);
  final c = palette[idx];
  return Color.fromARGB(255, c.r, c.g, c.b);
}

/// Warp color band: per warp end (end-1 at LEFT), its palette color. A single row.
class WarpColorBand extends ConsumerWidget {
  const WarpColorBand({required this.geom, this.window, super.key});

  final RegionGeom geom; // cols = ends, rows = 1

  /// The part of the canvas in view; null paints every cell.
  final GridWindow? window;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (warpColors, palette) = ref.watch(
        draftEditorProvider.select((s) => (s.draft.warpColors, s.draft.palette)));
    final (cells, colors) = _bandCells.of(warpColors, ('warp', palette, geom.cols), () => (
          [for (var end = 1; end <= geom.cols; end++) (end, 0)],
          [
            for (var end = 1; end <= geom.cols; end++)
              _swatch(palette, end - 1 < warpColors.length ? warpColors[end - 1] : 0),
          ],
        ));
    final cs = Theme.of(context).colorScheme;
    return Semantics(
      label: 'Warp colors',
      value: _bandValues.of(warpColors, ('end', geom.cols),
          () => _bandValue(warpColors, geom.cols, 'end')),
      child: CustomPaint(
        size: geom.size,
        painter: ColorBandPainter(
          colors: colors,
          cells: cells,
          geom: geom,
          line: cs.outlineVariant,
          background: cs.surfaceContainerHighest,
          window: window,
        ),
      ),
    );
  }
}

/// The cells and colors of a one-column weft band of [rows] picks (shared by the band beside the
/// cloth and the markers beside the treadling, which show the same colors).
(List<(int, int)>, List<Color>) _weftBand(List<int> weftColors, List<DraftColor> palette, int rows) =>
    _bandCells.of(weftColors, ('weft', palette, rows), () => (
          [for (var pick = 0; pick < rows; pick++) (1, pick)],
          [
            for (var pick = 0; pick < rows; pick++)
              _swatch(palette, pick < weftColors.length ? weftColors[pick] : 0),
          ],
        ));

/// A compact screen-reader value for a color band: the 1-based palette color of each cell, e.g.
/// "end 1 color 2, end 2 color 1" (a missing entry reads as color 1, the engine's pad).
String _bandValue(List<int> indices, int count, String unit) => [
      for (var i = 0; i < count; i++)
        '$unit ${i + 1} color ${(i < indices.length ? indices[i] : 0) + 1}',
    ].join(', ');

/// Weft color band: per pick (pick 0 at the TOP, sharing the drawdown's rows), its palette color. A
/// single column.
class WeftColorBand extends ConsumerWidget {
  const WeftColorBand({required this.geom, this.window, super.key});

  final RegionGeom geom; // cols = 1, rows = picks

  /// The part of the canvas in view; null paints every cell.
  final GridWindow? window;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (weftColors, palette) = ref.watch(
        draftEditorProvider.select((s) => (s.draft.weftColors, s.draft.palette)));
    final (cells, colors) = _weftBand(weftColors, palette, geom.rows);
    final cs = Theme.of(context).colorScheme;
    return Semantics(
      label: 'Weft colors',
      value: _bandValues.of(weftColors, ('pick', geom.rows),
          () => _bandValue(weftColors, geom.rows, 'pick')),
      child: CustomPaint(
        size: geom.size,
        painter: ColorBandPainter(
          colors: colors,
          cells: cells,
          geom: geom,
          line: cs.outlineVariant,
          background: cs.surfaceContainerHighest,
          window: window,
        ),
      ),
    );
  }
}

/// Right band: per pick, the pressed treadle(s) (treadled, col=treadle) OR raised shaft(s)
/// (liftplan, col=shaft). Cells are (col, pick): ONE ROW PER PICK, always, so treadling row k sits
/// beside drawdown row k. (Runs of identical picks are grouped only in the separate Book view.)
class RightGrid extends ConsumerWidget {
  const RightGrid({required this.geom, this.window, super.key});

  final RegionGeom geom;

  /// The part of the canvas in view; null paints every cell.
  final GridWindow? window;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (rows, treadled) =
        ref.watch(draftEditorProvider.select((s) => (s.draft.drive.rows, s.draft.drive is DraftTreadled)));
    final cells = _rightCells.of(rows, (geom.cols, geom.rows), () => [
          for (var pick = 0; pick < rows.length && pick < geom.rows; pick++)
            for (final id in rows[pick])
              if (id >= 1 && id <= geom.cols) (id, pick),
        ]);
    final colors = Theme.of(context).colorScheme;
    // Compact structural label (pick count); per-cell semantics is future work.
    final kind = treadled ? 'Treadling' : 'Liftplan';
    return Semantics(
      label: '$kind: ${rows.length} picks',
      container: true,
      child: CustomPaint(
        size: geom.size,
        painter: CellGridPainter(
          cells: cells,
          geom: geom,
          fill: colors.primary,
          line: colors.outlineVariant,
          background: colors.surfaceContainerHighest,
          window: window,
        ),
      ),
    );
  }
}

/// Weft-color MARKER band beside the treadling: one cell per pick, each showing that pick's weft
/// color, so the color reads right next to the treadle you press. EDITABLE per pick (the parent's
/// Listener routes a tap to that pick's weft), a mirror of the [WeftColorBand] beside the cloth.
class WeftMarkerBand extends ConsumerWidget {
  const WeftMarkerBand({required this.geom, this.window, super.key});

  final RegionGeom geom; // cols = 1, rows = picks

  /// The part of the canvas in view; null paints every cell.
  final GridWindow? window;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (weftColors, palette) = ref.watch(
        draftEditorProvider.select((s) => (s.draft.weftColors, s.draft.palette)));
    final (cells, colors) = _weftBand(weftColors, palette, geom.rows);
    final cs = Theme.of(context).colorScheme;
    return Semantics(
      label: 'Weft colors beside the treadling',
      value: _bandValues.of(weftColors, ('pick', geom.rows),
          () => _bandValue(weftColors, geom.rows, 'pick')),
      child: CustomPaint(
        size: geom.size,
        painter: ColorBandPainter(
          colors: colors,
          cells: cells,
          geom: geom,
          line: cs.outlineVariant,
          background: cs.surfaceContainerHighest,
          window: window,
        ),
      ),
    );
  }
}
