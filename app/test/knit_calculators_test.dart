import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/models/knit_calculators.dart';

// The pure knitting-math helpers behind the Calculators tab.

void main() {
  group('castOnForWidth', () {
    test('rounds (width+ease) x stitches-per-unit', () {
      // 20 sts / 4 in -> 5 sts/in; (10 + 2) in -> 60 sts.
      expect(castOnForWidth(gaugeStitches: 20, metric: false, width: 10, ease: 2), 60);
    });
    test('snaps to the stitch repeat', () {
      // (9.4 + 2) in x 5 sts/in = 57 -> nearest multiple of 4 = 56.
      expect(castOnForWidth(gaugeStitches: 20, metric: false, width: 9.4, ease: 2, repeat: 4), 56);
    });
    test('metric gauge uses a 10 cm window', () {
      // 22 sts / 10 cm -> 2.2 sts/cm; 30 cm -> 66.
      expect(castOnForWidth(gaugeStitches: 22, metric: true, width: 30, ease: 0), 66);
    });
  });

  group('resizeToGauge', () {
    test('scales the stitch count by your/pattern gauge', () {
      expect(resizeToGauge(patternStitches: 100, patternGauge: 20, yourGauge: 22), 110);
      expect(resizeToGauge(patternStitches: 10, patternGauge: 3, yourGauge: 4), 13); // (40/3).round()
    });
    test('guards a non-positive pattern gauge', () {
      expect(resizeToGauge(patternStitches: 50, patternGauge: 0, yourGauge: 20), 0);
    });
  });

  group('distributeEvenly', () {
    test('exact division leaves all gaps equal', () {
      final s = distributeEvenly(total: 60, count: 6);
      expect(s.shortGap, 10);
      expect(s.longGapCount, 0);
      expect(s.longGap, 10);
    });
    test('a remainder spreads one extra stitch per long gap, conserving the total', () {
      final s = distributeEvenly(total: 64, count: 6); // 64 = 6*10 + 4
      expect(s.shortGap, 10);
      expect(s.longGap, 11);
      expect(s.longGapCount, 4);
      expect(s.shortGapCount, 2);
      expect(s.shortGap * s.shortGapCount + s.longGap * s.longGapCount, 64, reason: 'total conserved');
    });
    test('count <= 0 yields a zero spread', () {
      final s = distributeEvenly(total: 40, count: 0);
      expect(s.count, 0);
      expect(s.shortGap, 40);
    });
  });

  group('yardageStockinette', () {
    test('grows with area, gauge, and the buffer', () {
      final a = yardageStockinette(gaugeStitches: 20, metric: false, width: 10, length: 10);
      final bigger = yardageStockinette(gaugeStitches: 20, metric: false, width: 20, length: 10);
      expect(bigger, greaterThan(a));
      // 10x10 in at 5 sts/in -> 10*10*5/6 = 83.3, +10% buffer ~= 91.7.
      expect(a, closeTo(91.7, 0.5));
    });
    test('non-positive inputs return 0', () {
      expect(yardageStockinette(gaugeStitches: 0, metric: false, width: 10, length: 10), 0);
    });
  });
}
