import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/widgets/draft_layout.dart'; // re-exports DraftRegion/DraftHit

// Pure-VM tests for the integrated draft view's single geometry source of truth. Two things must
// hold: (1) each region's rectFor/cellAt are exact inverses (a painted cell == a tapped cell), and
// (2) the four regions' shared edges are the SAME expression so they cannot drift.

void main() {
  // A deliberately NON-square treadled layout: ends 4, picks 3, shafts 2, treadles 5, cell 10.
  DraftLayout treadled() => DraftLayout(
        ends: 4,
        picks: 3,
        shafts: 2,
        treadles: 5,
        hasTieup: true,
        cell: 10,
      );

  // Liftplan: same dims but the right band is shafts (not treadles) wide, tie-up omitted.
  DraftLayout liftplan() => DraftLayout(
        ends: 4,
        picks: 3,
        shafts: 2,
        treadles: 5,
        hasTieup: false,
        cell: 10,
      );

  group('DraftLayout region rects (flush, structural alignment)', () {
    test('rects tile the canvas with no gaps and no gutters', () {
      final l = treadled();
      expect(l.threadingRect, const Rect.fromLTWH(0, 0, 40, 20));
      expect(l.tieupRect, const Rect.fromLTWH(40, 0, 50, 20));
      expect(l.drawdownRect, const Rect.fromLTWH(0, 20, 40, 30));
      expect(l.rightRect, const Rect.fromLTWH(40, 20, 50, 30));
      expect(l.totalSize, const Size(90, 50));
    });

    test('shared edges are equal (the alignment guarantee), treadled', () {
      final l = treadled();
      expect(l.threadingRect.width, equals(l.drawdownRect.width), reason: 'end columns align');
      expect(l.tieupRect.width, equals(l.rightRect.width), reason: 'treadle columns align');
      expect(l.threadingRect.height, equals(l.tieupRect.height), reason: 'shaft rows align');
      expect(l.rightRect.height, equals(l.drawdownRect.height), reason: 'pick rows align');
    });

    test('liftplan right band is shafts-wide and still aligns', () {
      final l = liftplan();
      expect(l.rightCols, equals(2)); // shafts, not treadles
      expect(l.rightRect.width, equals(l.tieupRect.width));
      expect(l.threadingRect.width, equals(l.drawdownRect.width));
      expect(l.rightRect.height, equals(l.drawdownRect.height));
    });
  });

  group('RegionGeom rectFor/cellAt inverse agreement', () {
    test('threading: end 1 LEFT, shaft 1 BOTTOM; center taps back', () {
      final g = treadled().threading; // 4 ends x 2 shafts, cell 10
      // end 1 at left (x 0), shaft 1 at bottom (y 10 of a 20-tall region).
      expect(g.rectFor(1, 1), const Rect.fromLTWH(0, 10, 10, 10));
      expect(g.rectFor(1, 2), const Rect.fromLTWH(0, 0, 10, 10)); // shaft 2 above shaft 1
      expect(g.rectFor(4, 1), const Rect.fromLTWH(30, 10, 10, 10)); // end 4 at the right
      for (var end = 1; end <= 4; end++) {
        for (var shaft = 1; shaft <= 2; shaft++) {
          expect(g.cellAt(g.rectFor(end, shaft).center), (end, shaft),
              reason: 'paint==tap for threading ($end,$shaft)');
        }
      }
    });

    test('right band (treadled): treadle 1 LEFT, pick 0 BOTTOM (0-based rows)', () {
      final g = treadled().right; // 5 treadles x 3 picks
      expect(g.rectFor(1, 0), const Rect.fromLTWH(0, 20, 10, 10)); // pick 0 at the bottom
      expect(g.rectFor(1, 2), const Rect.fromLTWH(0, 0, 10, 10)); // pick 2 at the top
      for (var treadle = 1; treadle <= 5; treadle++) {
        for (var pick = 0; pick < 3; pick++) {
          expect(g.cellAt(g.rectFor(treadle, pick).center), (treadle, pick),
              reason: 'paint==tap for right ($treadle,$pick)');
        }
      }
    });

    test('a cell owns its left/top edge; far-edge overshoot clamps; outside -> null', () {
      final g = treadled().threading; // cell 10, 4x2, size 40x20
      expect(g.cellAt(const Offset(0, 0)), isNotNull);
      expect(g.cellAt(const Offset(9.9, 0.0)), g.cellAt(const Offset(0, 0)),
          reason: 'still column 1');
      expect(g.cellAt(const Offset(39.9, 19.9)), (4, 1), reason: 'far corner clamps in range');
      expect(g.cellAt(const Offset(-1, 0)), isNull);
      expect(g.cellAt(const Offset(40, 0)), isNull);
      expect(g.cellAt(const Offset(0, 20)), isNull);
    });
  });

  group('DraftLayout.hitTest classification', () {
    test('routes a point to the right region (treadled)', () {
      final l = treadled();
      expect(l.hitTest(const Offset(5, 15))?.region, DraftRegion.threading);
      expect(l.hitTest(const Offset(45, 5))?.region, DraftRegion.tieup);
      expect(l.hitTest(const Offset(45, 25))?.region, DraftRegion.right);
      // The drawdown is display-only -> null even though the point is inside drawdownRect.
      expect(l.drawdownRect.contains(const Offset(5, 25)), isTrue);
      expect(l.hitTest(const Offset(5, 25)), isNull);
      // Outside the canvas -> null.
      expect(l.hitTest(const Offset(95, 5)), isNull);
    });

    test('liftplan: the tie-up region is not hit-tested (no tie-up)', () {
      final l = liftplan();
      // The (40,5) point falls in tieupRect's math, but hasTieup is false so it routes to null.
      expect(l.tieupRect.contains(const Offset(45, 5)), isTrue);
      expect(l.hitTest(const Offset(45, 5)), isNull);
      // The right band (liftplan) is still hit, classified with shaft columns.
      expect(l.hitTest(const Offset(45, 25))?.region, DraftRegion.right);
    });

    test('hitTest col/row matches the region geom', () {
      final l = treadled();
      final hit = l.hitTest(const Offset(45, 25))!; // right band, content space
      final local = const Offset(45, 25) - l.rightRect.topLeft;
      expect((hit.col, hit.row), l.right.cellAt(local));
    });
  });
}
