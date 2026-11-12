import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/models/double_weave_layers.dart';
import 'package:ply/src/models/draft_doc.dart';

/// A 4-shaft, 4-pick double weave like the engine generator: straight threading, layer colors by
/// shaft/pick parity, the textbook top-on-top tie-up — even picks leave the bottom layer down (top
/// picks), odd picks lift the whole top layer {1,3} clear (bottom picks).
DraftDoc doubleWeave() => DraftDoc.blank(shafts: 4, treadles: 4).copyWith(
      threading: const [
        [1],
        [2],
        [3],
        [4],
      ],
      drive: DraftTreadled(
        tieup: const [
          [1],
          [1, 2, 3],
          [3],
          [1, 3, 4],
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
    test('detects a 4-shaft double weave even when the shafts header is stale (below usage)', () {
      final staleHeader = doubleWeave().copyWith(shafts: 2);
      expect(supportsLayerView(staleHeader), isTrue);
    });
  });

  group('defaultTopShafts', () {
    test('is the odd shafts', () {
      expect(defaultTopShafts(doubleWeave()), {1, 3});
    });
  });

  group('raisedShafts (mirrors the engine shed logic)', () {
    test('treadled rising = union of the tie-up rows for the pick treadles', () {
      final d = doubleWeave(); // rising
      expect(raisedShafts(d, 0), {1}); // treadle 1 -> tieup[0] (top pick, bottom stays down)
      expect(raisedShafts(d, 1), {1, 2, 3}); // treadle 2 -> tieup[1] (bottom pick, top lifted clear)
    });
    test('sinking shed raises the complement within 1..shafts', () {
      final d = doubleWeave().copyWith(shed: Shed.sinking);
      expect(raisedShafts(d, 1), {4}, reason: 'tied {1,2,3} -> complement in 1..4');
    });
    test('liftplan lists raised shafts directly (shed ignored)', () {
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
        ]),
      );
      expect(raisedShafts(lp, 0), {1, 2, 4});
    });
  });

  group('doubleWeaveLayerDraft (default top = odd shafts {1,3})', () {
    test('TOP keeps the top-shaft ends and the picks that clear the bottom', () {
      final t = doubleWeaveLayerDraft(doubleWeave(), topShafts: {1, 3}, top: true);
      expect(t.ends, 2, reason: 'ends on shafts 1 and 3');
      expect(t.picks, 2, reason: 'picks 0 and 2 (the bottom layer stays down)');
      expect(t.threading, const [
        [1],
        [3],
      ]);
      expect((t.drive as DraftTreadled).treadling, const [
        [1],
        [3],
      ]);
      expect((t.drive as DraftTreadled).tieup.length, 4, reason: 'the tie-up is preserved whole');
      expect(t.warpColors, const [0, 0]);
      expect(t.weftColors, const [0, 0]);
      expect(t.shafts, 4, reason: 'the header shaft count is unchanged');
    });

    test('BOTTOM keeps the bottom-shaft ends and the picks that leave the top down', () {
      final b = doubleWeaveLayerDraft(doubleWeave(), topShafts: {1, 3}, top: false);
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
      final t = doubleWeaveLayerDraft(d, topShafts: {1, 3}, top: true);
      expect(t.warpThickness, const [1.0, 3.0], reason: 'ends 0 and 2');
      expect(t.weftThickness, const [1.0, 3.0], reason: 'picks 0 and 2');
    });

    test('uniform (empty) thickness stays empty', () {
      final t = doubleWeaveLayerDraft(doubleWeave(), topShafts: {1, 3}, top: true);
      expect(t.warpThickness, isEmpty);
      expect(t.weftThickness, isEmpty);
    });

    test('a color band shorter than the threading does not throw (missing -> 0)', () {
      final d = doubleWeave().copyWith(warpColors: const [5]); // only end 0 has a color
      final t = doubleWeaveLayerDraft(d, topShafts: {1, 3}, top: true); // keeps ends 0 and 2
      expect(t.warpColors, const [5, 0], reason: 'end 0 -> 5, the missing end 2 -> 0 (like the engine)');
    });

    test('an unthreaded end is assigned to the TOP layer (top+bottom partition every end)', () {
      final d = doubleWeave().copyWith(threading: const [
        <int>[],
        [2],
        [3],
        [4],
      ]);
      final t = doubleWeaveLayerDraft(d, topShafts: {1, 3}, top: true);
      final b = doubleWeaveLayerDraft(d, topShafts: {1, 3}, top: false);
      expect(t.threading, const [<int>[], [3]], reason: 'the unthreaded end 0 goes to top');
      expect(b.threading, const [[2], [4]], reason: 'and not to bottom');
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
          [1],
          [1, 2, 3],
          [3],
          [1, 3, 4],
        ]),
        warpColors: const [0, 1, 0, 1],
        weftColors: const [0, 1, 0, 1],
      );
      final t = doubleWeaveLayerDraft(lp, topShafts: {1, 3}, top: true);
      expect(t.drive, isA<DraftLiftplan>());
      expect((t.drive as DraftLiftplan).liftplan, const [
        [1],
        [3],
      ], reason: 'rows 0 and 2 (the top picks)');
      expect(t.threading, const [
        [1],
        [3],
      ]);
    });
  });

  group('doubleWeaveLayerDraft with a CUSTOM shaft assignment', () {
    test('moving a shaft to the top layer changes the top warp', () {
      // Reassign shaft 4 to the top: the top warp now also includes end 3 (threaded on shaft 4).
      final t = doubleWeaveLayerDraft(doubleWeave(), topShafts: {1, 3, 4}, top: true);
      expect(t.threading, const [
        [1],
        [3],
        [4],
      ], reason: 'ends on shafts 1, 3, and now 4');
    });
  });

  group('classifyPicks', () {
    DraftDoc liftplan(List<List<int>> rows) => DraftDoc.blank(shafts: 4, treadles: 0).copyWith(
          threading: const [
            [1],
            [2],
            [3],
            [4],
          ],
          drive: DraftLiftplan(liftplan: rows),
          warpColors: const [0, 0, 0, 0],
          weftColors: [for (final _ in rows) 0],
        );

    void expectPartition(PickLayers l, int picks) {
      final all = [...l.top, ...l.bottom, ...l.unclassified.keys]..sort();
      expect(all, [for (var p = 0; p < picks; p++) p], reason: 'every pick in exactly one place');
    }

    test('the generated double weave splits cleanly with nothing left over', () {
      final l = classifyPicks(doubleWeave(), {1, 3});
      expect(l.top, [0, 2]);
      expect(l.bottom, [1, 3]);
      expect(l.unclassified, isEmpty);
    });

    test('degenerate picks are reported with their reason, never counted twice', () {
      final d = liftplan(const [
        [1], // top pick
        [1, 2, 3], // bottom pick
        [1, 3], // exactly the top layer raised: between the layers (was counted in BOTH)
        [], // nothing raised: over everything (was counted as a top pick)
        [1, 2, 3, 4], // everything raised
        [1, 2], // raises shafts of both layers without clearing the top: crosses
      ]);
      final l = classifyPicks(d, {1, 3});
      expect(l.top, [0]);
      expect(l.bottom, [1]);
      expect(l.unclassified, {
        2: UnclassifiedPick.betweenLayers,
        3: UnclassifiedPick.overEverything,
        4: UnclassifiedPick.underEverything,
        5: UnclassifiedPick.crossesLayers,
      });
      expectPartition(l, 6);
      final top = doubleWeaveLayerDraft(d, topShafts: {1, 3}, top: true);
      final bottom = doubleWeaveLayerDraft(d, topShafts: {1, 3}, top: false);
      expect(top.picks + bottom.picks, 2, reason: 'no pick appears in both layer views');
    });

    test('a 2/2 twill is not double weave: every pick crosses the layers', () {
      final twill = liftplan(const [
        [1, 2],
        [2, 3],
        [3, 4],
        [4, 1],
      ]);
      final l = classifyPicks(twill, {1, 3});
      expect(l.top, isEmpty);
      expect(l.bottom, isEmpty);
      expect(l.unclassified.values.toSet(), {UnclassifiedPick.crossesLayers});
    });

    test('a one-shaft layer cannot be woven, and an all-top assignment has no split', () {
      final d = doubleWeave();
      expect(classifyPicks(d, {1, 2, 3}).bottom, isEmpty, reason: 'a single bottom shaft');
      final none = classifyPicks(d, {1, 2, 3, 4});
      expect(none.unclassified.values.toSet(), {UnclassifiedPick.noSplit});
      expectPartition(none, 4);
    });
  });
}
