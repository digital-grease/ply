import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/widgets/knit_chart_view.dart';

void main() {
  group('axisNumberAt', () {
    test('rows count UP from the bottom (row 0 = 1)', () {
      expect(axisNumberAt(row: true, i: 0, count: 5), 1, reason: 'bottom row is 1');
      expect(axisNumberAt(row: true, i: 4, count: 5), 5, reason: 'top row is the highest');
    });

    test('stitches count RIGHT-TO-LEFT (rightmost = 1), matching the reading order', () {
      expect(axisNumberAt(row: false, i: 0, count: 5), 5, reason: 'leftmost column is the highest');
      expect(axisNumberAt(row: false, i: 4, count: 5), 1, reason: 'rightmost column is stitch 1');
    });
  });
}
