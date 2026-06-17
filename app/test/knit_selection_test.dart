import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/state/knit_editor_providers.dart';

void main() {
  test('KnitSelection normalizes its corners (any drag direction)', () {
    const s = KnitSelection(3, 5, 1, 2); // anchor (row 3, col 5) -> current (row 1, col 2)
    expect((s.rowMin, s.rowMax), (1, 3));
    expect((s.colMin, s.colMax), (2, 5));
  });

  test('toCurrent keeps the anchor and moves only the current corner', () {
    const s = KnitSelection(2, 2, 2, 2);
    final d = s.toCurrent(0, 5);
    expect((d.rowMin, d.rowMax, d.colMin, d.colMax), (0, 2, 2, 5));
  });
}
