import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/models/double_weave_layers.dart';
import 'package:ply/src/models/draft_doc.dart';

/// A 4-shaft, 4-pick double weave like the engine generator: straight threading, layer colors by
/// shaft/pick parity.
DraftDoc doubleWeave() => DraftDoc.blank(shafts: 4, treadles: 4).copyWith(
      threading: const [
        [1],
        [2],
        [3],
        [4],
      ],
      drive: DraftTreadled(
        tieup: const [
          [1, 2, 4],
          [2],
          [2, 3, 4],
          [4],
        ],
        treadling: const [
          [1],
          [2],
          [3],
          [4],
        ],
      ),
      warpColors: const [0, 1, 0, 1],
      weftColors: const [0, 1, 0, 1],
    );

void main() {
  group('supportsLayerView', () {
    test('true for a 4-shaft non-empty cloth', () {
      expect(supportsLayerView(doubleWeave()), isTrue);
    });
    test('false for fewer than 4 shafts or an empty cloth', () {
      expect(supportsLayerView(DraftDoc.blank(shafts: 2, treadles: 2)), isFalse);
      expect(supportsLayerView(DraftDoc.blank(shafts: 4, treadles: 4)), isFalse,
          reason: 'blank is 0x0');
    });
  });

  group('doubleWeaveLayerDraft', () {
    test('FRONT keeps odd-shaft ends and even-index picks', () {
      final f = doubleWeaveLayerDraft(doubleWeave(), DoubleWeaveLayer.front);
      expect(f.ends, 2, reason: 'ends on shafts 1 and 3');
      expect(f.picks, 2, reason: 'picks 0 and 2');
      expect(f.threading, const [
        [1],
        [3],
      ]);
      expect((f.drive as DraftTreadled).treadling, const [
        [1],
        [3],
      ]);
      expect((f.drive as DraftTreadled).tieup.length, 4, reason: 'the tie-up is preserved whole');
      expect(f.warpColors, const [0, 0]);
      expect(f.weftColors, const [0, 0]);
      expect(f.shafts, 4, reason: 'the header shaft count is unchanged');
    });

    test('BACK keeps even-shaft ends and odd-index picks', () {
      final b = doubleWeaveLayerDraft(doubleWeave(), DoubleWeaveLayer.back);
      expect(b.ends, 2);
      expect(b.picks, 2);
      expect(b.threading, const [
        [2],
        [4],
      ]);
      expect((b.drive as DraftTreadled).treadling, const [
        [2],
        [4],
      ]);
      expect(b.warpColors, const [1, 1]);
      expect(b.weftColors, const [1, 1]);
    });

    test('per-thread thickness is narrowed to the kept ends/picks (not left full-length)', () {
      final d = doubleWeave().copyWith(
        warpThickness: const [1.0, 2.0, 3.0, 4.0],
        weftThickness: const [1.0, 2.0, 3.0, 4.0],
      );
      final f = doubleWeaveLayerDraft(d, DoubleWeaveLayer.front);
      expect(f.warpThickness, const [1.0, 3.0], reason: 'ends 0 and 2');
      expect(f.weftThickness, const [1.0, 3.0], reason: 'picks 0 and 2');
    });

    test('uniform (empty) thickness stays empty', () {
      final f = doubleWeaveLayerDraft(doubleWeave(), DoubleWeaveLayer.front);
      expect(f.warpThickness, isEmpty);
      expect(f.weftThickness, isEmpty);
    });

    test('a color band shorter than the threading does not throw (missing -> 0)', () {
      final d = doubleWeave().copyWith(warpColors: const [5]); // only end 0 has a color
      final f = doubleWeaveLayerDraft(d, DoubleWeaveLayer.front); // keeps ends 0 and 2
      expect(f.warpColors, const [5, 0], reason: 'end 0 -> 5, the missing end 2 -> 0 (like the engine)');
    });

    test('an unthreaded end is assigned to the FRONT layer (front+back partition every end)', () {
      final d = doubleWeave().copyWith(threading: const [
        <int>[],
        [2],
        [3],
        [4],
      ]);
      final f = doubleWeaveLayerDraft(d, DoubleWeaveLayer.front);
      final b = doubleWeaveLayerDraft(d, DoubleWeaveLayer.back);
      expect(f.threading, const [<int>[], [3]], reason: 'the unthreaded end 0 goes to front');
      expect(b.threading, const [[2], [4]], reason: 'and not to back');
    });

    test('a liftplan draft narrows its liftplan rows to the layer picks', () {
      final lp = DraftDoc.blank(shafts: 4, treadles: 0).copyWith(
        threading: const [
          [1],
          [2],
          [3],
          [4],
        ],
        drive: DraftLiftplan(liftplan: const [
          [1, 2, 4],
          [2],
          [2, 3, 4],
          [4],
        ]),
        warpColors: const [0, 1, 0, 1],
        weftColors: const [0, 1, 0, 1],
      );
      final f = doubleWeaveLayerDraft(lp, DoubleWeaveLayer.front);
      expect(f.drive, isA<DraftLiftplan>());
      expect((f.drive as DraftLiftplan).liftplan, const [
        [1, 2, 4],
        [2, 3, 4],
      ], reason: 'rows 0 and 2 (the front picks)');
      expect(f.threading, const [
        [1],
        [3],
      ]);
    });
  });
}
