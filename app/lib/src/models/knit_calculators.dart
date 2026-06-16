// Pure knitting-math helpers for the Calculators tab (the ones NOT already in the engine). Cast-on
// and yardage reuse the ply-knit engine via KnitRepository; these two — gauge-ratio RESIZE and the
// increase/decrease-EVENLY distribution — are pure integer/ratio arithmetic, kept here so they are
// fast, synchronous, and fully host-testable without the FFI. References: knitterskitchen.com
// (gauge-ratio resize) and worldknits.com (increase/decrease evenly).

import 'dart:math' as math;

/// Stitches per single unit (inch or cm) from a gauge measured over a 4 in / 10 cm window.
double stitchesPerUnit(double gaugeStitches, bool metric) => gaugeStitches / (metric ? 10.0 : 4.0);

/// Cast-on stitches for a finished [width] + [ease] (in the chosen unit) at [gaugeStitches] per window,
/// rounded to the nearest [repeat] multiple (>= one repeat). Returns 0 for non-positive inputs.
int castOnForWidth({
  required double gaugeStitches,
  required bool metric,
  required double width,
  required double ease,
  int repeat = 1,
}) {
  final raw = ((width + ease) * stitchesPerUnit(gaugeStitches, metric)).round();
  if (raw <= 0) return 0;
  if (repeat <= 1) return raw;
  return math.max(repeat, (raw / repeat).round() * repeat);
}

/// A ROUGH stockinette yardage estimate: yards ≈ width_in × length_in × stitches_per_in / 6, plus a
/// [bufferPct] safety margin. Worsted-calibrated and approximate — surface it as such. Units in/cm.
double yardageStockinette({
  required double gaugeStitches,
  required bool metric,
  required double width,
  required double length,
  double bufferPct = 10,
}) {
  final widthIn = metric ? width / 2.54 : width;
  final lengthIn = metric ? length / 2.54 : length;
  final stitchesPerInch = metric ? gaugeStitches / 10.0 * 2.54 : gaugeStitches / 4.0;
  if (widthIn <= 0 || lengthIn <= 0 || stitchesPerInch <= 0) return 0;
  return widthIn * lengthIn * stitchesPerInch / 6.0 * (1 + bufferPct / 100.0);
}

/// Resize a pattern's horizontal STITCH COUNT to your own gauge (knitterskitchen method): the new
/// count is the old count scaled by the gauge ratio. STITCH-COUNT ONLY — it does not recompute row
/// counts or correct shaping/bias, so the caller should surface that caveat. Both gauges are stitches
/// over the SAME window (4 in / 10 cm). Returns 0 on a non-positive pattern gauge.
int resizeToGauge({
  required int patternStitches,
  required double patternGauge,
  required double yourGauge,
}) {
  if (patternGauge <= 0) return 0;
  return (patternStitches * yourGauge / patternGauge).round();
}

/// The result of [distributeEvenly]: [count] increases/decreases spread over a row, [shortGap] stitches
/// between most of them and [longGap] (= shortGap + 1) before [longGapCount] of them, so the extras are
/// used up without bunching.
class EvenSpread {
  const EvenSpread({
    required this.count,
    required this.shortGap,
    required this.longGap,
    required this.longGapCount,
  });

  /// How many increases/decreases are worked.
  final int count;

  /// Stitches worked between most markers.
  final int shortGap;

  /// Stitches worked before the [longGapCount] longer gaps (== [shortGap] when there is no remainder).
  final int longGap;

  /// How many gaps are [longGap] long (the remainder).
  final int longGapCount;

  /// How many gaps are [shortGap] long.
  int get shortGapCount => count - longGapCount;

  @override
  bool operator ==(Object other) =>
      other is EvenSpread &&
      count == other.count &&
      shortGap == other.shortGap &&
      longGap == other.longGap &&
      longGapCount == other.longGapCount;

  @override
  int get hashCode => Object.hash(count, shortGap, longGap, longGapCount);
}

/// Spread [count] markers (increases or decreases) as evenly as possible across [total] stitches: the
/// row is split into [count] gaps whose lengths differ by at most one (the worldknits "evenly across a
/// row" math). Returns a zero spread for a non-positive [count].
EvenSpread distributeEvenly({required int total, required int count}) {
  if (count <= 0) {
    return EvenSpread(count: 0, shortGap: math.max(total, 0), longGap: math.max(total, 0), longGapCount: 0);
  }
  final t = math.max(total, 0);
  final base = t ~/ count;
  final rem = t % count;
  return EvenSpread(
    count: count,
    shortGap: base,
    longGap: rem > 0 ? base + 1 : base,
    longGapCount: rem,
  );
}
