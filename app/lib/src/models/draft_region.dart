// The four regions of the integrated weaving draft view, and a classified hit within one.
//
// These are the shared vocabulary between the geometry (DraftLayout, which CLASSIFIES a pointer
// into a region + cell) and the editor reducers (EditorState.paintCell, which APPLIES an edit to
// the hit cell). Keeping them in models/ lets both the geometry (widgets/draft_layout.dart) and
// the pure state layer depend on them without the state layer importing any widget code.

/// A region of the integrated draft view.
enum DraftRegion {
  /// Across the top: per warp end, which shaft(s) it threads through.
  threading,

  /// Top-right: per treadle, which shaft(s) it is tied to (treadled drafts only).
  tieup,

  /// Down the right side: per pick, the pressed treadle(s) (treadled) OR raised shaft(s) (liftplan).
  right,

  /// A top strip above threading: per warp end, its palette color (painted with the active brush).
  warpColor,

  /// A left strip beside the drawdown: per pick, its palette color (painted with the active brush).
  weftColor,

  /// The main cloth area. Display-only (rendered by the engine); never edited directly.
  drawdown,
}

/// A classified hit: which [region], and that region's `(col, row)` in its OWN terms.
///
///   * threading -> (end 1-based, shaft 1-based)
///   * tieup     -> (treadle 1-based, shaft 1-based)
///   * right     -> treadled: (treadle 1-based, pick 0-based); liftplan: (shaft 1-based, pick 0-based)
///   * warpColor -> (end 1-based, 0)
///   * weftColor -> (1, pick 0-based)
class DraftHit {
  const DraftHit(this.region, this.col, this.row);

  final DraftRegion region;
  final int col;
  final int row;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DraftHit &&
          runtimeType == other.runtimeType &&
          region == other.region &&
          col == other.col &&
          row == other.row;

  @override
  int get hashCode => Object.hash(region, col, row);

  @override
  String toString() => 'DraftHit($region, col=$col, row=$row)';
}
