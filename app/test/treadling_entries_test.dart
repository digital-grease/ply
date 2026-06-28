import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/models/treadling_entries.dart';

// The pure run-collapse behind the compressed ("book") treadling view.

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

    test('collapse:false keeps one entry per pick (the non-overshot per-pick treadling)', () {
      // The SAME repeating treadling, but NOT collapsed: every pick is its own count-1 entry, so the
      // band reads one row per pick (aligned with the drawdown) instead of the overshot run shorthand.
      final e = treadlingEntries(const [
        [1],
        [1],
        [1],
        [2],
        [1],
        [1],
      ], collapse: false);
      expect(e.length, 6, reason: 'one entry per pick, no run-collapsing');
      expect(e.every((x) => x.count == 1), isTrue);
      expect(e.map((x) => x.startPick).toList(), [0, 1, 2, 3, 4, 5]);
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
  });
}
