import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/models/treadling_entries.dart';

// The pure run grouping behind the separate Book view (the editor grid itself is one row per pick).

void main() {
  group('treadlingEntries', () {
    test('collapses maximal runs of identical sheds, in pick order', () {
      // treadle 1 x3, treadle 2 x1, treadle 1 x2.
      final e = treadlingEntries([
        [1],
        [1],
        [1],
        [2],
        [1],
        [1],
      ]);
      // Compared field-by-field: a record holding a List would compare the List by identity.
      expect(e.map((x) => x.shed).toList(), [
        [1],
        [2],
        [1],
      ]);
      expect(e.map((x) => x.count).toList(), [3, 1, 2]);
      expect(e.map((x) => x.startPick).toList(), [0, 3, 4]);
      // The counts sum to the pick count.
      expect(e.fold(0, (a, x) => a + x.count), 6);
    });

    test('an empty treadling yields no entries', () {
      expect(treadlingEntries(const []), isEmpty);
    });

    test('a non-repeating treadling is one entry per pick (count 1)', () {
      final e = treadlingEntries([
        [1],
        [2],
        [1],
        [2],
      ]);
      expect(e.length, 4);
      expect(e.every((x) => x.count == 1), isTrue);
    });

    test('an empty shed (blank pick) is its own run', () {
      final e = treadlingEntries([
        [],
        [],
        [1],
      ]);
      expect(e.length, 2);
      expect(e[0].shed, isEmpty);
      expect(e[0].count, 2);
      expect(e[1].shed, [1]);
      expect(e[1].count, 1);
    });

    test('sheds compare order-independently', () {
      final e = treadlingEntries([
        [1, 2],
        [2, 1],
      ]);
      expect(e.length, 1, reason: '{1,2} and {2,1} are the same shed');
      expect(e.single.count, 2);
    });

    test('entryIndexForPick maps a pick into its run', () {
      final e = treadlingEntries([
        [1],
        [1],
        [2],
      ]);
      expect(entryIndexForPick(e, 0), 0);
      expect(entryIndexForPick(e, 1), 0);
      expect(entryIndexForPick(e, 2), 1);
      expect(entryIndexForPick(e, 5), isNull);
    });

    test('expanding the entries reproduces the picks exactly (the Book view round-trip)', () {
      // A mix of runs, blanks, multi-treadle sheds, and an order-swapped shed: concatenating each
      // entry's shed `count` times must give back every pick, in order, with nothing merged away.
      final rows = <List<int>>[
        [1],
        [1],
        [3],
        [],
        [],
        [1, 2],
        [2, 1],
        [4],
        [1],
      ];
      final e = treadlingEntries(rows);
      final expanded = [
        for (final x in e)
          for (var k = 0; k < x.count; k++) x.shed.toSet(),
      ];
      expect(expanded, [for (final r in rows) r.toSet()]);
      // Each entry starts where the previous one ended (no gaps, no overlap).
      for (var i = 1; i < e.length; i++) {
        expect(e[i].startPick, e[i - 1].endPick);
      }
    });
  });

  group('weftColorRuns (every weft color in a Book view row)', () {
    test('a run of two contrasting yarns keeps BOTH colors, in pick order', () {
      // One shed thrown 4x (a single entry), but its picks alternate color 2 and color 5: the row
      // must not read as one color (the old marker showed only the first pick's color).
      final entry = treadlingEntries([
        [1],
        [1],
        [1],
        [1],
      ]).single;
      final runs = weftColorRuns(entry, const [2, 5, 2, 5]);
      expect(runs.map((r) => r.color).toList(), [2, 5, 2, 5]);
      expect(runs.map((r) => r.count).toList(), [1, 1, 1, 1]);
      expect(runs.map((r) => r.startPick).toList(), [0, 1, 2, 3]);
    });

    test('consecutive picks of one color group, and only the entry\'s own picks count', () {
      final entries = treadlingEntries([
        [2],
        [1],
        [1],
        [1],
        [3],
      ]);
      final runs = weftColorRuns(entries[1], const [9, 0, 0, 4, 9]); // picks 1..3
      expect(runs.map((r) => (r.color, r.startPick, r.count)).toList(), [(0, 1, 2), (4, 3, 1)]);
    });

    test('a short weftColors list reads as palette index 0 past its end', () {
      final entry = treadlingEntries([
        [1],
        [1],
        [1],
      ]).single;
      final runs = weftColorRuns(entry, const [3]);
      expect(runs.map((r) => (r.color, r.startPick, r.count)).toList(), [(3, 0, 1), (0, 1, 2)]);
    });
  });
}
