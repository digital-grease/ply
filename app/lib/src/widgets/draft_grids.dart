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
import '../models/treadling_entries.dart';
import '../state/draft_editor_notifier.dart';
import '../state/editor_providers.dart';
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

/// A [CellGridPainter] that also overlays a PICK-REPEAT COUNT on the COMPRESSED treadling: each row is
/// one run (overshot's "throw this shed N times"), and a run of two or more picks shows its length as
/// a number centered in its cell. Runs of one carry no number, so a non-repeating treadling stays
/// uncluttered.
class CountedCellGridPainter extends CellGridPainter {
  CountedCellGridPainter({
    required super.cells,
    required super.geom,
    required super.fill,
    required super.line,
    required super.background,
    required this.counts,
    required this.countColor,
    this.highlightRow,
    required this.highlightColor,
  });

  /// `(col, row, value)` per annotated entry (only runs with `value >= 2`): the number [value] is drawn
  /// centered in the single cell ([col], [row]) — its representative treadle, or column 1 for a blank
  /// shed.
  final List<(int, int, int)> counts;
  final Color countColor;

  /// The selected entry row to ring (the dimensions-bar count stepper edits it), or null.
  final int? highlightRow;
  final Color highlightColor;

  @override
  void paint(Canvas canvas, Size size) {
    super.paint(canvas, size); // background + filled cells + grid lines
    if (geom.isDegenerate) return;
    final fontSize = (geom.cell * 0.5).clamp(8.0, 14.0);
    for (final (col, row, value) in counts) {
      final rect = geom.rectFor(col, row);
      final tp = TextPainter(
        text: TextSpan(
          text: '$value',
          style: TextStyle(color: countColor, fontSize: fontSize, fontWeight: FontWeight.w700),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, rect.center - Offset(tp.width / 2, tp.height / 2));
    }
    final hr = highlightRow;
    if (hr != null && hr >= 0 && hr < geom.rows) {
      // The selected entry's whole row (all treadle columns), drawn top-origin like the band.
      final rect = Rect.fromLTWH(0, hr * geom.cell, geom.cols * geom.cell, geom.cell).deflate(1);
      canvas.drawRect(rect, Paint()..color = highlightColor..style = PaintingStyle.stroke..strokeWidth = 2);
    }
  }

  @override
  bool shouldRepaint(CellGridPainter old) {
    if (old is! CountedCellGridPainter) return true;
    return countColor != old.countColor ||
        highlightRow != old.highlightRow ||
        highlightColor != old.highlightColor ||
        !listEquals(counts, old.counts) ||
        super.shouldRepaint(old);
  }
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
        ),
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
  });

  final List<Color> colors; // parallel to [cells]
  final List<(int, int)> cells; // (col, row) per cell, region-local terms
  final RegionGeom geom;
  final Color line;
  final Color background;

  @override
  void paint(Canvas canvas, Size size) {
    if (geom.isDegenerate) return;
    assert(size == geom.size, 'ColorBandPainter size $size != geom.size ${geom.size}');
    final gsize = geom.size;
    canvas.drawRect(Offset.zero & gsize, Paint()..color = background);

    for (var i = 0; i < cells.length; i++) {
      final (col, row) = cells[i];
      canvas.drawRect(geom.rectFor(col, row).deflate(0.5), Paint()..color = colors[i]);
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
  bool shouldRepaint(ColorBandPainter old) =>
      geom != old.geom ||
      line != old.line ||
      background != old.background ||
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
  const WarpColorBand({required this.geom, super.key});

  final RegionGeom geom; // cols = ends, rows = 1

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (warpColors, palette) = ref.watch(
        draftEditorProvider.select((s) => (s.draft.warpColors, s.draft.palette)));
    final cells = <(int, int)>[for (var end = 1; end <= geom.cols; end++) (end, 0)];
    final colors = <Color>[
      for (var end = 1; end <= geom.cols; end++)
        _swatch(palette, end - 1 < warpColors.length ? warpColors[end - 1] : 0),
    ];
    final cs = Theme.of(context).colorScheme;
    return Semantics(
      label: 'Warp colors',
      value: _bandValue(warpColors, geom.cols, 'end'),
      child: CustomPaint(
        size: geom.size,
        painter: ColorBandPainter(
          colors: colors,
          cells: cells,
          geom: geom,
          line: cs.outlineVariant,
          background: cs.surfaceContainerHighest,
        ),
      ),
    );
  }
}

/// A compact screen-reader value for a color band: the 1-based palette color of each cell, e.g.
/// "end 1 color 2, end 2 color 1" (a missing entry reads as color 1, the engine's pad).
String _bandValue(List<int> indices, int count, String unit) => [
      for (var i = 0; i < count; i++)
        '$unit ${i + 1} color ${(i < indices.length ? indices[i] : 0) + 1}',
    ].join(', ');

/// Weft color band: per pick (pick-0 at BOTTOM, the geom owns the flip), its palette color. A
/// single column.
class WeftColorBand extends ConsumerWidget {
  const WeftColorBand({required this.geom, super.key});

  final RegionGeom geom; // cols = 1, rows = picks

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (weftColors, palette) = ref.watch(
        draftEditorProvider.select((s) => (s.draft.weftColors, s.draft.palette)));
    final cells = <(int, int)>[for (var pick = 0; pick < geom.rows; pick++) (1, pick)];
    final colors = <Color>[
      for (var pick = 0; pick < geom.rows; pick++)
        _swatch(palette, pick < weftColors.length ? weftColors[pick] : 0),
    ];
    final cs = Theme.of(context).colorScheme;
    return Semantics(
      label: 'Weft colors',
      value: _bandValue(weftColors, geom.rows, 'pick'),
      child: CustomPaint(
        size: geom.size,
        painter: ColorBandPainter(
          colors: colors,
          cells: cells,
          geom: geom,
          line: cs.outlineVariant,
          background: cs.surfaceContainerHighest,
        ),
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
    final (rows, treadled) =
        ref.watch(draftEditorProvider.select((s) => (s.draft.drive.rows, s.draft.drive is DraftTreadled)));
    // OVERSHOT: collapse runs of identical picks into one numbered ROW ("throw this shed N times").
    // NON-overshot: one row per pick (no collapse, no counts) — the normal per-pick treadling.
    final overshot = ref.watch(overshotTreadlingProvider);
    final entries = treadlingEntries(rows, collapse: overshot);
    final cells = <(int, int)>[
      for (var e = 0; e < entries.length && e < geom.rows; e++)
        for (final id in entries[e].shed)
          if (id >= 1 && id <= geom.cols) (id, e),
    ];
    final counts = <(int, int, int)>[
      for (var e = 0; e < entries.length && e < geom.rows; e++)
        if (entries[e].count >= 2)
          ((entries[e].shed.isEmpty ? 1 : entries[e].shed.first).clamp(1, geom.cols), e, entries[e].count),
    ];
    final colors = Theme.of(context).colorScheme;
    // The selected entry (in range) is ringed so it's clear which row the count stepper edits.
    final selected = ref.watch(selectedTreadlingEntryProvider);
    final highlight = (selected != null && selected >= 0 && selected < entries.length) ? selected : null;
    // Compact structural label (entry rows + total picks); per-cell semantics is future work.
    final kind = treadled ? 'Treadling' : 'Liftplan';
    final label = '$kind: ${entries.length} rows, ${rows.length} picks';
    return Semantics(
      label: label,
      container: true,
      child: CustomPaint(
        size: geom.size,
        painter: CountedCellGridPainter(
          cells: cells,
          counts: counts,
          geom: geom,
          fill: colors.primary,
          line: colors.outlineVariant,
          background: colors.surfaceContainerHighest,
          countColor: colors.onPrimary,
          highlightRow: highlight,
          highlightColor: colors.secondary,
        ),
      ),
    );
  }
}

/// Weft-color MARKER band beside the COMPRESSED treadling: one cell per run, each showing that run's
/// (first pick's) weft color, so the pick's color reads right next to the treadle you press. EDITABLE
/// per run — a tap paints the active brush onto every pick in that run (the parent's Listener routes
/// it); the per-pick weft band stays on the left by the cloth for finer control.
class WeftMarkerBand extends ConsumerWidget {
  const WeftMarkerBand({required this.geom, super.key});

  final RegionGeom geom;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (rows, weftColors, palette) = ref.watch(draftEditorProvider
        .select((s) => (s.draft.drive.rows, s.draft.weftColors, s.draft.palette)));
    // Mirror the right band's row granularity: one cell per run (overshot) or one per pick otherwise.
    final entries = treadlingEntries(rows, collapse: ref.watch(overshotTreadlingProvider));
    final cells = <(int, int)>[for (var e = 0; e < entries.length && e < geom.rows; e++) (1, e)];
    final indices = <int>[
      for (var e = 0; e < entries.length && e < geom.rows; e++)
        entries[e].startPick < weftColors.length ? weftColors[entries[e].startPick] : 0,
    ];
    final colors = <Color>[for (final i in indices) _swatch(palette, i)];
    final cs = Theme.of(context).colorScheme;
    return Semantics(
      label: 'Weft colors by treadling row',
      value: _bandValue(indices, indices.length, 'row'),
      child: CustomPaint(
        size: geom.size,
        painter: ColorBandPainter(
          colors: colors,
          cells: cells,
          geom: geom,
          line: cs.outlineVariant,
          background: cs.surfaceContainerHighest,
        ),
      ),
    );
  }
}
