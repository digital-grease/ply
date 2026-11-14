import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/print/book_draft_layout.dart';
import 'package:ply/src/print/print_document.dart';
import 'package:ply/src/print/print_layout.dart';

// The book draft's page geometry: in every one of the four layouts the quadrants share their axes
// exactly (end k's threading column is its drawdown column, shaft s's threading row is its tie-up row,
// treadle t's tie-up column is its treadling column, pick p's treadling row is its drawdown row), the
// tie-up sits in the named corner, and every 1 is where the page says (end 1 on the tie-up side, shaft
// 1 next to the drawdown, treadle 1 next to the threading, pick 1 next to the tie-up). Then the cell
// rule and how a large draft is cut into parts.

const _margins = BookMargins(left: 10, right: 30, top: 9, bottom: 9, gap: 6);

BookGeometry _geometry(BookCorner corner,
        {int ends = 7, int rows = 5, int shafts = 4, int columns = 6, double cell = 9}) =>
    BookGeometry(
      cell: cell,
      margins: _margins,
      shafts: shafts,
      columns: columns,
      ends: ends,
      rows: rows,
      corner: corner,
    );

bool _inside(BookBox inner, BookBox outer) =>
    inner.x >= outer.x - 1e-9 &&
    inner.y >= outer.y - 1e-9 &&
    inner.right <= outer.right + 1e-9 &&
    inner.bottom <= outer.bottom + 1e-9;

bool _overlaps(BookBox a, BookBox b) =>
    a.x < b.right - 1e-9 && b.x < a.right - 1e-9 && a.y < b.bottom - 1e-9 && b.y < a.bottom - 1e-9;

void main() {
  group('every layout shares its axes across the quadrants', () {
    for (final corner in BookCorner.values) {
      test(corner.name, () {
        final g = _geometry(corner);
        for (var e = 0; e < g.ends; e++) {
          for (var s = 1; s <= g.shafts; s++) {
            for (var r = 0; r < g.rows; r++) {
              final t = g.threadingCell(e, s), d = g.drawdownCell(e, r);
              expect(t.x, d.x, reason: 'end ${e + 1}: threading and drawdown column');
              expect(t.w, d.w);
            }
          }
        }
        for (var s = 1; s <= g.shafts; s++) {
          for (var c = 1; c <= g.columns; c++) {
            expect(g.threadingCell(0, s).y, g.tieupCell(c, s).y, reason: 'shaft $s row');
          }
        }
        for (var c = 1; c <= g.columns; c++) {
          for (var r = 0; r < g.rows; r++) {
            expect(g.tieupCell(c, 1).x, g.treadlingCell(c, r).x, reason: 'column $c');
          }
        }
        for (var r = 0; r < g.rows; r++) {
          for (var e = 0; e < g.ends; e++) {
            expect(g.treadlingCell(1, r).y, g.drawdownCell(e, r).y, reason: 'row $r');
          }
        }
        // Every cell lies in its quadrant; the quadrants never overlap and fit in the block.
        final block = BookBox(0, 0, g.width, g.height);
        for (var e = 0; e < g.ends; e++) {
          expect(_inside(g.threadingCell(e, 1), g.threadingArea), isTrue);
          expect(_inside(g.drawdownCell(e, g.rows - 1), g.drawdownArea), isTrue);
        }
        expect(_inside(g.tieupCell(g.columns, g.shafts), g.tieupArea), isTrue);
        expect(_inside(g.treadlingCell(g.columns, 0), g.treadlingArea), isTrue);
        final areas = [g.threadingArea, g.tieupArea, g.treadlingArea, g.drawdownArea];
        for (final a in areas) {
          expect(_inside(a, block), isTrue);
          for (final b in areas) {
            if (!identical(a, b)) expect(_overlaps(a, b), isFalse);
          }
        }
        // A run of ends is exactly the cells it covers.
        final run = g.drawdownRun(2, 5, 1);
        final cells = [for (var e = 2; e < 5; e++) g.drawdownCell(e, 1)];
        expect(run.x, cells.map((c) => c.x).reduce((a, b) => a < b ? a : b));
        expect(run.right, cells.map((c) => c.right).reduce((a, b) => a > b ? a : b));
        expect(run.w, closeTo(3 * g.cell, 1e-9));
      });
    }
  });

  group('the tie-up is in the named corner and every 1 is where the page says', () {
    for (final corner in BookCorner.values) {
      test(corner.name, () {
        final g = _geometry(corner);
        final right = !corner.mirrorX, top = !corner.mirrorY;
        expect(g.tieupArea.centerX > g.drawdownArea.centerX, right, reason: 'tie-up side');
        expect(g.tieupArea.centerY < g.drawdownArea.centerY, top, reason: 'tie-up height');
        expect(g.threadingArea.centerY < g.drawdownArea.centerY, top, reason: 'threading');
        // End 1 is the column on the tie-up side: rightmost when the tie-up is on the right.
        final end1 = g.threadingCell(0, 1), last = g.threadingCell(g.ends - 1, 1);
        expect(end1.x > last.x, right);
        // Shaft 1 is the threading row next to the drawdown (bottom row when the threading is on top).
        final shaft1 = g.threadingCell(0, 1), top4 = g.threadingCell(0, g.shafts);
        expect(shaft1.y > top4.y, top);
        // Treadle 1 is the tie-up column next to the threading.
        expect(g.tieupCell(1, 1).x < g.tieupCell(g.columns, 1).x, right);
        // Pick 1 (row 0) is the treadling row next to the tie-up.
        expect(g.treadlingCell(1, 0).y < g.treadlingCell(1, g.rows - 1).y, top);
        // Numbers sit outside their grid: shaft numbers beside the threading on the far side from the
        // tie-up, end numbers on the threading's outer edge, pick numbers beyond the treadling.
        expect(g.shaftNumberBox(1).centerX < g.threadingArea.x, right);
        expect(g.endNumberBox(0).centerY < g.threadingArea.y, top);
        expect(g.endNumberBox(0).centerX, end1.centerX);
        expect(g.marginBox(0, offset: 0, w: 10).centerX > g.treadlingArea.centerX, right);
        expect(g.marginBox(0, offset: 0, w: 10).centerY, g.treadlingCell(1, 0).centerY);
        expect(g.edgeLabelStrip.centerY > g.drawdownArea.centerY, top);
        // Text alignment follows a left-right mirror; centered text stays centered.
        expect(g.align(BookAlign.start), right ? BookAlign.start : BookAlign.end);
        expect(g.align(BookAlign.center), BookAlign.center);
      });
    }

    test('a lift plan numbers its columns in the empty tie-up corner, next to the lift plan', () {
      for (final corner in BookCorner.values) {
        final g = _geometry(corner);
        final box = g.columnNumberBox(1, liftplan: true, strip: 8);
        expect(box.centerX, g.treadlingCell(1, 0).centerX);
        expect(_inside(box, g.tieupArea), isTrue, reason: corner.name);
        final gap =
            corner.mirrorY ? box.y - g.treadlingArea.bottom : g.treadlingArea.y - box.bottom;
        expect(gap, closeTo(_margins.gap, 1e-9), reason: corner.name);
        // A treadled draft numbers them outside the tie-up instead.
        final outer = g.columnNumberBox(1, liftplan: false, strip: 8);
        expect(_overlaps(outer, g.tieupArea), isFalse);
      }
    });

    test('heavier lines sit on the boundaries of the numbered threads', () {
      for (final corner in BookCorner.values) {
        final g = _geometry(corner, ends: 12, rows: 12);
        // The boundary between local ends 9 and 10 (ends 10 and 11) is the shared edge of their cells.
        final a = g.drawdownCell(9, 0), b = g.drawdownCell(10, 0);
        final x = g.endBoundaryX(10);
        expect(x == a.x || x == a.right, isTrue);
        expect(x == b.x || x == b.right, isTrue);
        final y = g.rowBoundaryY(10);
        final r9 = g.drawdownCell(0, 9), r10 = g.drawdownCell(0, 10);
        expect(y == r9.y || y == r9.bottom, isTrue);
        expect(y == r10.y || y == r10.bottom, isTrue);
      }
    });
  });

  group('cell size and parts', () {
    test('a draft that fits prints whole, at the largest cell up to 5 mm', () {
      final small = layoutBookDraft(
          ends: 22, rows: 22, shafts: 4, columns: 4, width: 500, height: 700, margins: _margins);
      expect(small.parts, [const BookPart(endStart: 0, endEnd: 22, rowStart: 0, rowEnd: 22)]);
      expect(small.cell, 5 * kMm);
      final medium = layoutBookDraft(
          ends: 40, rows: 40, shafts: 8, columns: 8, width: 500, height: 700, margins: _margins);
      expect(medium.parts, hasLength(1));
      expect(medium.cell, closeTo((500 - _margins.horizontal) / 48, 1e-9));
      expect(medium.cell, inInclusiveRange(3 * kMm, 5 * kMm));
    });

    test('a draft too big for a page is split at 3 mm, never smaller, every crossing once', () {
      final layout = layoutBookDraft(
          ends: 400,
          rows: 1000,
          shafts: 16,
          columns: 16,
          width: 510,
          height: 700,
          margins: _margins);
      expect(layout.cell, 3 * kMm);
      expect(layout.tooLarge, isFalse);
      final first = layout.parts.first;
      expect((first.endStart, first.rowStart), (0, 0), reason: 'part 1 holds end 1 and pick 1');
      // Reading order: a band of picks across the whole width, then the next band.
      expect(layout.parts[1].rowStart, 0);
      expect(layout.parts[1].endStart, first.endEnd);
      final perEnds = first.ends, perRows = first.rows;
      expect(perEnds, ((510 - _margins.horizontal - 16 * 3 * kMm) / (3 * kMm) + 1e-9).floor());
      expect(perRows, ((700 - _margins.vertical - 16 * 3 * kMm) / (3 * kMm) + 1e-9).floor());
      expect(layout.parts, hasLength((400 / perEnds).ceil() * (1000 / perRows).ceil()));
      final seen = <int>{};
      for (final p in layout.parts) {
        expect(p.ends, lessThanOrEqualTo(perEnds));
        expect(p.rows, lessThanOrEqualTo(perRows));
        // Every part fits the page at its cell size.
        final g = BookGeometry(
            cell: layout.cell,
            margins: _margins,
            shafts: 16,
            columns: 16,
            ends: p.ends,
            rows: p.rows,
            corner: BookCorner.topRight);
        expect(g.width, lessThanOrEqualTo(510 + 1e-6));
        expect(g.height, lessThanOrEqualTo(700 + 1e-6));
        for (var r = p.rowStart; r < p.rowEnd; r++) {
          for (var e = p.endStart; e < p.endEnd; e++) {
            expect(seen.add(r * 400 + e), isTrue);
          }
        }
      }
      expect(seen, hasLength(400 * 1000));
    });

    test('a tie-up or threading that fills the page leaves no room: too large, no parts', () {
      final layout = layoutBookDraft(
          ends: 40,
          rows: 40,
          shafts: 120,
          columns: 120,
          width: 510,
          height: 700,
          margins: _margins);
      expect(layout.tooLarge, isTrue);
      expect(layout.parts, isEmpty);
      expect(
          layoutBookDraft(ends: 0, rows: 5, shafts: 4, columns: 4, width: 510, height: 700).parts,
          isEmpty);
    });

    test('the colored drawdown prints down to 1.5 mm, then splits', () {
      const m = BookMargins(right: 20, top: 20, gap: 0);
      final whole = layoutBookDraft(
          ends: 100,
          rows: 100,
          shafts: 0,
          columns: 0,
          width: 510,
          height: 700,
          margins: m,
          rule: kColorDrawdownCellRule);
      expect(whole.parts, hasLength(1));
      expect(whole.cell, closeTo(490 / 100, 1e-9));
      final split = layoutBookDraft(
          ends: 400,
          rows: 1000,
          shafts: 0,
          columns: 0,
          width: 510,
          height: 700,
          margins: m,
          rule: kColorDrawdownCellRule);
      expect(split.cell, 1.5 * kMm);
      expect(split.parts.length, greaterThan(1));
    });

    test('numbers: every thread when they fit, else every 2nd, 5th or 10th', () {
      expect(numberStep(8.5, 3), 1);
      expect(numberStep(8.5, 9), 2);
      expect(numberStep(4.25, 9), 5);
      expect(numberStep(4.25, 14), 5);
      expect(numberStep(4.25, 25), 10);
      expect(numberedThreads(0, 12, 1), [for (var i = 0; i < 12; i++) i]);
      expect(numberedThreads(0, 12, 2), [1, 3, 5, 7, 9, 11]);
      expect(numberedThreads(0, 21, 5), [0, 4, 9, 14, 19], reason: 'end 1, then 5, 10, 15, 20');
      expect(numberedThreads(40, 61, 10), [49, 59], reason: 'only end 1 overall gets the extra');
    });
  });
}
