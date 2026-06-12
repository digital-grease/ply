// THE single source of truth for the integrated draft view: every region's pixel Rect AND every
// region's cell<->pixel mapping, derived from ONE shared pitch `cell` and ONE set of axis origins.
// Pure (Flutter-paint-free, dart:ui geometry only), fully host-testable on the VM. It supersedes
// the old TieupGeometry/tieupCellAt (fit-to-box + shaft-1-at-TOP): there is now exactly ONE
// geometry, so the four regions cannot drift and the tie-up shares its math with everything else.
//
// AXES (chosen + justified in the Phase 3.1 design synthesis):
//   ends:     warp end 1 at the LEFT, increasing RIGHT.   Conforms to the engine drawdown bitmap
//             (render_rgba puts end 0 in the LEFT column), so the bitmap blits 1:1 with NO Dart
//             mirror. The weaving-convention end-1-at-RIGHT becomes a future display toggle that
//             flips BOTH this map AND a matching engine render flag together (M4), never a Dart
//             bitmap mirror alone. Shared X axis: threading <-> drawdown.
//   shafts:   shaft 1 at the BOTTOM, increasing UP.        Matches the engine vertical flip + the
//             chosen layout. Shared Y axis: threading <-> tie-up.
//   treadles: treadle 1 at the LEFT, increasing RIGHT.     Shared X axis: tie-up <-> right band.
//   picks:    pick 0 at the BOTTOM, increasing UP.         Matches the engine flip (no Dart flip).
//             Shared Y axis: right band <-> drawdown.
//
// One content coordinate space, origin top-left (Flutter native). Bottom-origin axes are honoured
// ONLY inside the cell<->pixel maps (a row flip), never by a second coordinate space.
//
// LAYOUT (flush; NO gutter between threading and drawdown — the warp column reads pixel-continuous):
//
//        x: [ threading: ends*S ][ right band: rightCols*S ]
//        y0 +------------------+ +-------------------------+
//           |    threading     | |   tie-up (treadled)     |  rows = shafts
//           +------------------+ +-------------------------+
//           |    drawdown      | |  treadling / liftplan   |  rows = picks
//           +------------------+ +-------------------------+
//
// Shared edges are the SAME expression (threadingRect.width and drawdownRect.width are both
// ends*cell, etc.), so 4-region alignment is structural, not asserted.

import 'dart:ui' show Offset, Rect, Size;

import '../models/draft_region.dart';

export '../models/draft_region.dart' show DraftRegion, DraftHit;

/// Per-region cell<->pixel mapping in the region's OWN local space (origin = its top-left, the
/// space a CustomPaint receives). [rectFor] (paint) and [cellAt] (hit-test) apply the IDENTICAL
/// flip math, so a painted cell and a tapped cell can never disagree (the test-proven
/// TieupGeometry contract, generalized to all three grids).
///
/// Columns run left->right, [cols] of them, indexed 1-based against [colBase] (or flipped to
/// right-origin when [rightOrigin]). Rows are indexed against [rowBase] (1 for shaft ids, 0 for
/// pick ids) and drawn BOTTOM-UP when [bottomOrigin].
class RegionGeom {
  const RegionGeom({
    required this.cols,
    required this.rows,
    required this.cell,
    required this.colBase,
    required this.rowBase,
    required this.bottomOrigin,
    this.rightOrigin = false,
  });

  final int cols;
  final int rows;
  final double cell; // the shared pitch S, identical across every region
  final int colBase; // 1 for end/treadle/shaft ids
  final int rowBase; // 1 for shaft ids, 0 for pick ids
  final bool bottomOrigin;
  final bool rightOrigin;

  Size get size => Size(cols * cell, rows * cell);
  bool get isDegenerate => cols <= 0 || rows <= 0 || cell <= 0;

  /// Local pixel rect of cell (col, row). Painters fill HERE.
  Rect rectFor(int col, int row) {
    final c = col - colBase; // 0-based column from the base
    final cx = (rightOrigin ? (cols - 1 - c) : c) * cell;
    final r = row - rowBase; // 0-based row from the base
    final ry = (bottomOrigin ? (rows - 1 - r) : r) * cell;
    return Rect.fromLTWH(cx, ry, cell, cell);
  }

  /// The (col, row) cell at [local], or null if outside. EXACT inverse of [rectFor]: the same
  /// flips are applied, so the center of rectFor(c,r) always taps back to (c,r).
  (int, int)? cellAt(Offset local) {
    if (isDegenerate) return null;
    if (local.dx < 0 || local.dy < 0 || local.dx >= size.width || local.dy >= size.height) {
      return null;
    }
    final cRaw = local.dx ~/ cell; // 0-based from the LEFT
    final c = rightOrigin ? (cols - 1 - cRaw) : cRaw;
    final col = (c + colBase).clamp(colBase, colBase + cols - 1);
    final rRaw = local.dy ~/ cell; // 0-based from the TOP
    final r = bottomOrigin ? (rows - 1 - rRaw) : rRaw;
    final row = (r + rowBase).clamp(rowBase, rowBase + rows - 1);
    return (col, row);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RegionGeom &&
          runtimeType == other.runtimeType &&
          cols == other.cols &&
          rows == other.rows &&
          cell == other.cell &&
          colBase == other.colBase &&
          rowBase == other.rowBase &&
          bottomOrigin == other.bottomOrigin &&
          rightOrigin == other.rightOrigin;

  @override
  int get hashCode =>
      Object.hash(cols, rows, cell, colBase, rowBase, bottomOrigin, rightOrigin);
}

/// The whole integrated layout. Built once per (ends, picks, shafts, treadles, hasTieup, cell);
/// the Stack's Positioned rects, the drawdown's destination rect, every grid's [RegionGeom], and
/// the gesture router all read THIS object, so layout, paint, and hit-test cannot diverge.
class DraftLayout {
  DraftLayout({
    required this.ends,
    required this.picks,
    required this.shafts,
    required this.treadles,
    required this.hasTieup,
    required this.cell,
  })  : assert(cell > 0),
        // Right band: treadles wide for a treadled draft, shafts wide for a liftplan (picks x shafts).
        rightCols = hasTieup ? treadles : shafts;

  final int ends;
  final int picks;
  final int shafts;
  final int treadles;
  final int rightCols;
  final bool hasTieup;

  /// On-screen pixels per cell (the shared pitch S). Snap to an integer logical px at the call
  /// site so S*devicePixelRatio is integer (the raster bitmap's nearest-neighbor cell boundaries
  /// then land on the vector grid lines, no sub-cell seams).
  final double cell;

  double get _warpW => ends * cell; // threading & drawdown width
  double get _rightW => rightCols * cell; // tie-up & right-band width
  double get _shaftH => shafts * cell; // threading & tie-up height
  double get _pickH => picks * cell; // right-band & drawdown height

  // --- region rects in CANVAS space (what Positioned.fromRect consumes). Flush, no gutters. ---
  Rect get threadingRect => Rect.fromLTWH(0, 0, _warpW, _shaftH);
  Rect get tieupRect => Rect.fromLTWH(_warpW, 0, _rightW, _shaftH);
  Rect get drawdownRect => Rect.fromLTWH(0, _shaftH, _warpW, _pickH);
  Rect get rightRect => Rect.fromLTWH(_warpW, _shaftH, _rightW, _pickH);

  Rect rectOf(DraftRegion r) => switch (r) {
        DraftRegion.threading => threadingRect,
        DraftRegion.tieup => tieupRect,
        DraftRegion.right => rightRect,
        DraftRegion.drawdown => drawdownRect,
      };

  /// Fixed-pitch canvas size; the scrollable SizedBox uses exactly this.
  Size get totalSize => Size(_warpW + _rightW, _shaftH + _pickH);

  // --- per-grid geometry in each grid's LOCAL space ---

  /// Threading: ends columns (end 1 at LEFT, conforming to the engine bitmap), shafts rows
  /// (shaft 1 at BOTTOM).
  RegionGeom get threading => RegionGeom(
        cols: ends,
        rows: shafts,
        cell: cell,
        colBase: 1,
        rowBase: 1,
        bottomOrigin: true,
      );

  /// Tie-up: treadles columns (treadle 1 at LEFT), shafts rows (shaft 1 at BOTTOM). SAME rows as
  /// threading; SAME columns as the right band.
  RegionGeom get tieup => RegionGeom(
        cols: treadles,
        rows: shafts,
        cell: cell,
        colBase: 1,
        rowBase: 1,
        bottomOrigin: true,
      );

  /// Right band: treadled -> treadles columns x picks rows (col = treadle 1-based);
  /// liftplan -> shafts columns x picks rows (col = shaft 1-based). Picks are 0-based at BOTTOM.
  RegionGeom get right => RegionGeom(
        cols: rightCols,
        rows: picks,
        cell: cell,
        colBase: 1,
        rowBase: 0,
        bottomOrigin: true,
      );

  RegionGeom geomOf(DraftRegion r) => switch (r) {
        DraftRegion.threading => threading,
        DraftRegion.tieup => tieup,
        DraftRegion.right => right,
        DraftRegion.drawdown => throw ArgumentError('drawdown has no editable grid geometry'),
      };

  /// Whole-canvas hit test in CONTENT space -> a [DraftHit], or null in a gutter / outside / on
  /// the read-only drawdown. The single pure function the gesture router calls. A drag is confined
  /// to its start region by the CALLER comparing `hit.region` to the region the stroke began in.
  DraftHit? hitTest(Offset content) {
    if (threadingRect.contains(content)) {
      final c = threading.cellAt(content - threadingRect.topLeft);
      return c == null ? null : DraftHit(DraftRegion.threading, c.$1, c.$2);
    }
    if (hasTieup && tieupRect.contains(content)) {
      final c = tieup.cellAt(content - tieupRect.topLeft);
      return c == null ? null : DraftHit(DraftRegion.tieup, c.$1, c.$2);
    }
    if (rightRect.contains(content)) {
      final c = right.cellAt(content - rightRect.topLeft);
      return c == null ? null : DraftHit(DraftRegion.right, c.$1, c.$2);
    }
    // Drawdown is display-only; everything else is a gutter / outside.
    return null;
  }
}
