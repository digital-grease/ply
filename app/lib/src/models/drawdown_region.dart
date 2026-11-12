// A rectangle of the weaving drawdown, the unit of the editor's viewport rendering (M7-01).
//
// A large draft is drawn a viewport at a time: the editor asks the engine for just the ends and
// picks in view (plus a margin), and places the returned bitmap over exactly those cells. The region
// is named in the engine's own terms, 0-based and half-open on both axes (end index 0 is the end a
// weaver calls end 1; pick index 0 is pick 1), so it maps one-to-one onto the bridge's
// `DrawdownRegionDto` with no off-by-one at the boundary.

import 'dart:math' as math;

/// [endCount] warp ends from end index [endStart] by [pickCount] picks from pick index [pickStart].
class DrawdownRegion {
  const DrawdownRegion({
    required this.endStart,
    required this.endCount,
    required this.pickStart,
    required this.pickCount,
  });

  /// The region covering end indices `[endStart, endEnd)` by pick indices `[pickStart, pickEnd)`.
  const DrawdownRegion.span({
    required this.endStart,
    required int endEnd,
    required this.pickStart,
    required int pickEnd,
  })  : endCount = endEnd - endStart,
        pickCount = pickEnd - pickStart;

  final int endStart;
  final int endCount;
  final int pickStart;
  final int pickCount;

  /// One past the region's last end index.
  int get endEnd => endStart + endCount;

  /// One past the region's last pick index.
  int get pickEnd => pickStart + pickCount;

  bool get isEmpty => endCount <= 0 || pickCount <= 0;

  /// The warp/weft intersections in the region.
  int get cells => isEmpty ? 0 : endCount * pickCount;

  /// Whether every cell of [other] is inside this region (an empty [other] is inside anything).
  bool covers(DrawdownRegion other) =>
      other.isEmpty ||
      (!isEmpty &&
          other.endStart >= endStart &&
          other.endEnd <= endEnd &&
          other.pickStart >= pickStart &&
          other.pickEnd <= pickEnd);

  /// This region grown by [ends] on each side across and [picks] on each side down, then clipped to
  /// a draft of [totalEnds] x [totalPicks].
  DrawdownRegion grown({
    required int ends,
    required int picks,
    required int totalEnds,
    required int totalPicks,
  }) =>
      DrawdownRegion.span(
        endStart: math.max(0, endStart - ends),
        endEnd: math.min(totalEnds, endEnd + ends),
        pickStart: math.max(0, pickStart - picks),
        pickEnd: math.min(totalPicks, pickEnd + picks),
      );

  /// This region clipped to a draft of [totalEnds] x [totalPicks], or null when nothing is left
  /// (the draft shrank past it).
  DrawdownRegion? clippedTo(int totalEnds, int totalPicks) {
    final r = DrawdownRegion.span(
      endStart: math.max(0, endStart),
      endEnd: math.min(totalEnds, endEnd),
      pickStart: math.max(0, pickStart),
      pickEnd: math.min(totalPicks, pickEnd),
    );
    return r.isEmpty ? null : r;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DrawdownRegion &&
          endStart == other.endStart &&
          endCount == other.endCount &&
          pickStart == other.pickStart &&
          pickCount == other.pickCount;

  @override
  int get hashCode => Object.hash(endStart, endCount, pickStart, pickCount);

  @override
  String toString() => 'DrawdownRegion(ends $endStart..$endEnd, picks $pickStart..$pickEnd)';
}
