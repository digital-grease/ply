import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/models/draft_doc.dart';
import 'package:ply/src/state/draft_editor_notifier.dart';
import 'package:ply/src/widgets/tieup_grid.dart';

void main() {
  group('tieupCellAt', () {
    const size = Size(80, 40); // 4 treadles x 4 shafts -> 20x10 cells

    test('maps points to the right 1-based (treadle, shaft) cell', () {
      expect(tieupCellAt(const Offset(10, 5), size, treadles: 4, shafts: 4), (1, 1));
      expect(tieupCellAt(const Offset(70, 5), size, treadles: 4, shafts: 4), (4, 1));
      expect(tieupCellAt(const Offset(10, 35), size, treadles: 4, shafts: 4), (1, 4));
      expect(tieupCellAt(const Offset(70, 35), size, treadles: 4, shafts: 4), (4, 4));
      expect(tieupCellAt(const Offset(30, 15), size, treadles: 4, shafts: 4), (2, 2));
    });

    test('a cell owns its left/top edge (half-open intervals)', () {
      expect(tieupCellAt(const Offset(0, 0), size, treadles: 4, shafts: 4), (1, 1));
      expect(tieupCellAt(const Offset(19.9, 0), size, treadles: 4, shafts: 4), (1, 1));
      expect(tieupCellAt(const Offset(20, 0), size, treadles: 4, shafts: 4), (2, 1));
    });

    test('returns null outside the grid', () {
      expect(tieupCellAt(const Offset(-1, 5), size, treadles: 4, shafts: 4), isNull);
      expect(tieupCellAt(const Offset(5, -1), size, treadles: 4, shafts: 4), isNull);
      expect(tieupCellAt(const Offset(80, 5), size, treadles: 4, shafts: 4), isNull);
      expect(tieupCellAt(const Offset(5, 40), size, treadles: 4, shafts: 4), isNull);
    });

    test('clamps far-edge floating-point overshoot into range', () {
      expect(tieupCellAt(const Offset(79.9, 39.9), size, treadles: 4, shafts: 4), (4, 4));
    });

    test('returns null for degenerate dimensions', () {
      expect(tieupCellAt(const Offset(5, 5), size, treadles: 0, shafts: 4), isNull);
      expect(tieupCellAt(const Offset(5, 5), size, treadles: 4, shafts: 0), isNull);
    });
  });

  testWidgets('tapping a tie-up cell toggles it through the notifier', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container
        .read(draftEditorProvider.notifier)
        .load(DraftDoc.blank(shafts: 4, treadles: 4));

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(width: 80, height: 80, child: TieupGrid()),
            ),
          ),
        ),
      ),
    );

    // 4x4 grid in an 80x80 box => 20x20 cells. Tap the top-left cell (treadle 1, shaft 1).
    final topLeft = tester.getTopLeft(find.byType(TieupGrid));
    await tester.tapAt(topLeft + const Offset(10, 10));
    await tester.pump();

    final drive = container.read(draftEditorProvider).draft.drive as DraftTreadled;
    expect(drive.tieup[0], equals([1]), reason: 'shaft 1 tied to treadle 1');
    expect(container.read(draftEditorProvider).canUndo, isTrue);

    // Tapping the same cell again clears it (toggle off).
    await tester.tapAt(topLeft + const Offset(10, 10));
    await tester.pump();
    final after =
        container.read(draftEditorProvider).draft.drive as DraftTreadled;
    expect(after.tieup[0], isEmpty);
  });

  testWidgets('a tap maps through the AspectRatio letterbox offset on a NON-square grid',
      (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    // 6 treadles x 3 shafts => AspectRatio 2.0, which letterboxes inside a 4:5 box (loose
    // constraints via the inner Center), so the painted area is offset from the box origin.
    container
        .read(draftEditorProvider.notifier)
        .load(DraftDoc.blank(shafts: 3, treadles: 6));

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 360,
                height: 300,
                child: Center(child: TieupGrid()),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final paint = find.descendant(
      of: find.byType(TieupGrid),
      matching: find.byType(CustomPaint),
    );
    final rect = tester.getRect(paint);
    expect(rect.height, lessThan(300), reason: 'the grid really did letterbox');

    // Center of cell (treadle 3, shaft 2), computed from the PAINTED rect. This only resolves
    // to the right cell if the tap's localPosition maps through the centering offset.
    final target = rect.topLeft +
        Offset((3 - 0.5) * (rect.width / 6), (2 - 0.5) * (rect.height / 3));
    await tester.tapAt(target);
    await tester.pump();

    final tieup =
        (container.read(draftEditorProvider).draft.drive as DraftTreadled).tieup;
    expect(tieup[2], equals([2]),
        reason: 'offset-mapped tap toggled cell (treadle 3, shaft 2)');
  });

  group('TieupGeometry painter/hit-test agreement', () {
    // The painter fills cells at TieupGeometry.rectFor(t,s); the hit-test maps a tap via
    // TieupGeometry.cellAt. They are the SAME object's two methods, so pinning their inverse
    // relationship pins that a painted cell and a tapped cell are always the same cell (the
    // transpose/off-by-one class the rasterized probe was meant to catch, checked directly).
    const size = Size(80, 40); // 4 treadles x 2 shafts -> 20x20 cells, non-square on purpose
    final geom = TieupGeometry(size, treadles: 4, shafts: 2);

    test('rectFor places each 1-based cell at the expected pixel rect', () {
      expect(geom.rectFor(1, 1), const Rect.fromLTWH(0, 0, 20, 20));
      expect(geom.rectFor(4, 2), const Rect.fromLTWH(60, 20, 20, 20));
      expect(geom.rectFor(2, 1), const Rect.fromLTWH(20, 0, 20, 20),
          reason: 'treadle advances X, shaft advances Y (axes not transposed)');
    });

    test('the center of rectFor(t,s) taps back to (t,s) via cellAt', () {
      for (var t = 1; t <= 4; t++) {
        for (var s = 1; s <= 2; s++) {
          expect(geom.cellAt(geom.rectFor(t, s).center), (t, s),
              reason: 'paint and tap must agree for cell ($t, $s)');
        }
      }
    });
  });
}
