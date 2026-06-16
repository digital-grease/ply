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
    test('rects tile the canvas; the color bands reserve a left/top strip; gutter separates regions', () {
      final l = treadled(); // leftPad=topPad=cell=10; gutter = round(10*0.4) = 4
      expect(l.gutter, 4);
      // The four core regions shift right/down past the bands; the right column (+x) and bottom row
      // (+y) shift a further `gutter`.
      expect(l.threadingRect, const Rect.fromLTWH(10, 10, 40, 20));
      expect(l.tieupRect, const Rect.fromLTWH(54, 10, 50, 20)); // +4 gutter in x
      expect(l.drawdownRect, const Rect.fromLTWH(10, 34, 40, 30)); // +4 gutter in y
      expect(l.rightRect, const Rect.fromLTWH(54, 34, 50, 30)); // +4 in both
      // Warp colors: top strip, ends wide, sharing the warp column's X+width (flush with threading).
      expect(l.warpColorRect, const Rect.fromLTWH(10, 0, 40, 10));
      // Weft colors: left strip, picks tall, sharing the drawdown's Y+height (shifts with it).
      expect(l.weftColorRect, const Rect.fromLTWH(0, 34, 10, 30));
      expect(l.totalSize, const Size(104, 64)); // +4 gutter on each axis
    });

    test('color bands are column/row aligned with the cloth', () {
      final l = treadled();
      expect(l.warpColorRect.left, l.threadingRect.left);
      expect(l.warpColorRect.left, l.drawdownRect.left);
      expect(l.warpColorRect.width, l.drawdownRect.width);
      expect(l.weftColorRect.top, l.drawdownRect.top);
      expect(l.weftColorRect.height, l.drawdownRect.height);
    });

    test('the bands collapse on a blank axis (origin stays at 0,0)', () {
      final blank = DraftLayout(ends: 0, picks: 0, shafts: 2, treadles: 2, hasTieup: true, cell: 10);
      expect(blank.threadingRect.left, 0, reason: 'no weft band when picks==0');
      expect(blank.threadingRect.top, 0, reason: 'no warp band when ends==0');
      // The band rects are zero-area (pads collapsed), so nothing paints or hit-tests there.
      expect(blank.warpColorRect.width == 0 || blank.warpColorRect.height == 0, isTrue);
      expect(blank.weftColorRect.width == 0 || blank.weftColorRect.height == 0, isTrue);
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
    test('routes a point to the right region (treadled), with the bands shifted in', () {
      final l = treadled(); // pad 10: threading (10,10,40,20), tieup (50,10,..), right (50,30,..)
      expect(l.hitTest(const Offset(15, 25))?.region, DraftRegion.threading);
      expect(l.hitTest(const Offset(55, 15))?.region, DraftRegion.tieup);
      expect(l.hitTest(const Offset(55, 35))?.region, DraftRegion.right);
      // The two color bands.
      expect(l.hitTest(const Offset(15, 5))?.region, DraftRegion.warpColor); // top strip
      expect(l.hitTest(const Offset(5, 35))?.region, DraftRegion.weftColor); // left strip
      // The drawdown is display-only -> null even though the point is inside drawdownRect.
      expect(l.drawdownRect.contains(const Offset(15, 35)), isTrue);
      expect(l.hitTest(const Offset(15, 35)), isNull);
      // The dead top-left corner (above the weft band, left of the warp band) -> null.
      expect(l.hitTest(const Offset(5, 5)), isNull);
      // Outside the canvas -> null.
      expect(l.hitTest(const Offset(105, 5)), isNull);
    });

    test('liftplan: the tie-up region is not hit-tested (no tie-up)', () {
      final l = liftplan();
      // The (55,15) point falls in tieupRect's math, but hasTieup is false so it routes to null.
      expect(l.tieupRect.contains(const Offset(55, 15)), isTrue);
      expect(l.hitTest(const Offset(55, 15)), isNull);
      // The right band (liftplan) is still hit, classified with shaft columns.
      expect(l.hitTest(const Offset(55, 35))?.region, DraftRegion.right);
    });

    test('hitTest col/row matches the region geom (right band + both color bands)', () {
      final l = treadled();
      final hit = l.hitTest(const Offset(55, 35))!; // right band, content space
      expect((hit.col, hit.row), l.right.cellAt(const Offset(55, 35) - l.rightRect.topLeft));

      final warp = l.hitTest(const Offset(15, 5))!;
      expect(warp.region, DraftRegion.warpColor);
      expect(warp.row, 0, reason: 'warp band is a single row (row 0)');
      expect((warp.col, warp.row), l.warpColor.cellAt(const Offset(15, 5) - l.warpColorRect.topLeft));

      final weft = l.hitTest(const Offset(5, 35))!;
      expect(weft.region, DraftRegion.weftColor);
      expect(weft.col, 1, reason: 'weft band is a single column (col 1)');
      expect((weft.col, weft.row), l.weftColor.cellAt(const Offset(5, 35) - l.weftColorRect.topLeft));
    });

    test('a warp-band column maps to the SAME end as the cloth column below it', () {
      final l = treadled(); // 4 ends
      for (var end = 1; end <= 4; end++) {
        final warpCenter = l.warpColorRect.topLeft + l.warpColor.rectFor(end, 0).center;
        final threadCenter = l.threadingRect.topLeft + l.threading.rectFor(end, 1).center;
        expect(l.hitTest(warpCenter)!.col, l.hitTest(threadCenter)!.col,
            reason: 'warp band end $end is column-aligned with its cloth column');
      }
    });

    test('a weft-band row maps to the SAME pick as the cloth row beside it', () {
      final l = treadled(); // 3 picks
      for (var pick = 0; pick < 3; pick++) {
        final weftCenter = l.weftColorRect.topLeft + l.weftColor.rectFor(1, pick).center;
        final rightCenter = l.rightRect.topLeft + l.right.rectFor(1, pick).center;
        expect(l.hitTest(weftCenter)!.row, l.hitTest(rightCenter)!.row,
            reason: 'weft band pick $pick is row-aligned with its cloth row');
      }
    });

    test('color-band rectFor/cellAt are exact inverses', () {
      final l = treadled();
      final w = l.warpColor; // ends 4 x 1 row, end-1 LEFT
      for (var end = 1; end <= 4; end++) {
        expect(w.cellAt(w.rectFor(end, 0).center), (end, 0));
      }
      final f = l.weftColor; // 1 col x picks 3, pick-0 BOTTOM
      expect(f.rectFor(1, 0), const Rect.fromLTWH(0, 20, 10, 10), reason: 'pick 0 at the bottom');
      for (var pick = 0; pick < 3; pick++) {
        expect(f.cellAt(f.rectFor(1, pick).center), (1, pick));
      }
    });
  });

  group('DraftLayout.fitCellLevel (auto-fit the open pitch to the viewport)', () {
    // Same dims as treadled(): width = (1 + ends 4 + treadles 5) = 10 cells, height = (1 + shafts 2
    // + picks 3) = 6 cells, plus the gutter G = round(0.4S), so totalSize at pitch S is
    // (10S + G, 6S + G). E.g. S=16 -> G=6 -> (166, 102); S=12 -> G=5 -> (125, 77).
    int fit(Size available) => DraftLayout.fitCellLevel(
          ends: 4,
          picks: 3,
          shafts: 2,
          treadles: 5,
          hasTieup: true,
          available: available,
          levels: const [8, 12, 16, 24, 32, 48],
        );

    test('a roomy viewport picks the LARGEST level that fits', () {
      expect(fit(const Size(1000, 1000)), 48); // 499x307 fits
    });
    test('a tight WIDTH binds the level', () {
      expect(fit(const Size(200, 1000)), 16); // 16 -> 166 wide fits; 24 -> 250 wide overflows
    });
    test('a tight HEIGHT binds the level', () {
      expect(fit(const Size(1000, 100)), 12); // 12 -> 77 tall fits; 16 -> 102 tall overflows
    });
    test('exact fit is inclusive (<=)', () {
      expect(fit(const Size(166, 102)), 16); // pitch 16 with gutter: 166x102 exactly
    });
    test('falls back to the SMALLEST level when even it overflows (the draft then scrolls)', () {
      expect(fit(const Size(50, 50)), 8); // 8 -> 83x51 overflows 50 but is the floor
    });
  });
}
