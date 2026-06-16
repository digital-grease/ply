import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/draft_repository.dart';
import 'package:ply/src/models/draft_doc.dart';

// Unit tests for DraftRepository.applyBasicStructure — the PURE overlay step of "Generate structure"
// for the basic families (plain/twill/satin). It is split out of the FFI path so the array splicing,
// non-destructive color preservation, range placement, and dimension growth can be tested on the VM.

// A populated 8-end x 6-pick treadled draft with distinct warp/weft colors and a name to preserve.
DraftDoc populated() => DraftDoc(
      name: 'keep-me',
      shafts: 4,
      treadles: 6,
      shed: Shed.rising,
      unit: MeasureUnit.inches,
      threading: [for (var i = 0; i < 8; i++) [(i % 4) + 1]], // 1,2,3,4,1,2,3,4
      drive: DraftTreadled(
        tieup: [for (var i = 0; i < 6; i++) const <int>[]],
        treadling: [for (var i = 0; i < 6; i++) [(i % 6) + 1]],
      ),
      palette: const [DraftColor(r: 255, g: 0, b: 0), DraftColor(r: 0, g: 0, b: 255)],
      warpColors: const [0, 1, 0, 1, 0, 1, 0, 1],
      weftColors: const [1, 1, 1, 1, 1, 1],
      notes: 'my notes',
    );

void main() {
  test('whole generate onto a blank draft reproduces the classic defaults', () {
    final out = DraftRepository.applyBasicStructure(
      base: DraftDoc.blank(shafts: 4, treadles: 6),
      effShafts: 4,
      genThreading: [for (var i = 0; i < 16; i++) [(i % 4) + 1]],
      genTieup: const [
        [1, 3],
        [2, 4]
      ], // plain
      applyTreadling: true,
      effTreadles: 2,
      picks: 16,
    );
    expect(out.ends, 16);
    expect(out.picks, 16);
    expect(out.shafts, 4);
    expect(out.treadles, 2, reason: 'treadles follow the generated tie-up');
    expect(out.warpColors, List<int>.filled(16, 0));
    expect(out.weftColors, List<int>.filled(16, 1), reason: 'fresh weft seeds the contrasting color');
  });

  test('range placement: a threading patch overlays only its span, leaving the rest', () {
    final base = populated();
    final out = DraftRepository.applyBasicStructure(
      base: base,
      effShafts: 4,
      genThreading: const [
        [2],
        [2],
        [2],
        [2]
      ],
      endStart: 2, // place at ends 2..5
    );
    expect(out.ends, 8, reason: 'dimensions unchanged (patch fits inside)');
    expect(out.threading[0], [1], reason: 'before the patch: untouched');
    expect(out.threading[1], [2]);
    expect(out.threading[2], [2], reason: 'patched');
    expect(out.threading[5], [2], reason: 'patched (last of the span)');
    expect(out.threading[6], [3], reason: 'after the patch: untouched');
  });

  test('non-destructive: warp colors, name, notes, and the untouched drive are preserved', () {
    final base = populated();
    final out = DraftRepository.applyBasicStructure(
      base: base,
      effShafts: 4,
      genThreading: const [
        [1],
        [1]
      ], // regenerate just the first 2 ends
    );
    expect(out.warpColors, const [0, 1, 0, 1, 0, 1, 0, 1], reason: 'colors kept, not reset');
    expect(out.weftColors, const [1, 1, 1, 1, 1, 1]);
    expect(out.name, 'keep-me');
    expect(out.notes, 'my notes');
    // Drive untouched (no tie-up/treadling applied).
    expect(out.drive, isA<DraftTreadled>());
    expect((out.drive as DraftTreadled).treadling.length, 6);
  });

  test('component selection: tie-up only swaps the tie-up, keeps threading + treadling', () {
    final base = populated();
    final out = DraftRepository.applyBasicStructure(
      base: base,
      effShafts: 4,
      genTieup: const [
        [1, 2],
        [2, 3],
        [3, 4],
        [4, 1]
      ], // a 2/2 twill tie-up
    );
    expect(out.threading, base.threading, reason: 'threading untouched');
    expect((out.drive as DraftTreadled).tieup, const [
      [1, 2],
      [2, 3],
      [3, 4],
      [4, 1]
    ]);
    expect(out.treadles, 4, reason: 'treadle count follows the new tie-up');
    expect((out.drive as DraftTreadled).treadling.length, 6, reason: 'existing treadling kept');
  });

  test('dimension growth pads colors with defaults while preserving the existing run', () {
    final base = populated(); // 8 ends
    final out = DraftRepository.applyBasicStructure(
      base: base,
      effShafts: 4,
      genThreading: const [
        [1],
        [1],
        [1],
        [1]
      ],
      endStart: 8, // append a 4-end band past the current 8
    );
    expect(out.ends, 12);
    expect(out.warpColors.length, 12);
    expect(out.warpColors.sublist(0, 8), const [0, 1, 0, 1, 0, 1, 0, 1], reason: 'preserved');
    expect(out.warpColors.sublist(8), const [0, 0, 0, 0], reason: 'new ends padded with 0');
  });

  test('a liftplan base is converted to treadled when the drive is touched', () {
    final lift = DraftDoc(
      name: 'L',
      shafts: 4,
      treadles: 0,
      shed: Shed.rising,
      unit: MeasureUnit.inches,
      threading: [for (var i = 0; i < 4; i++) [(i % 4) + 1]],
      drive: DraftLiftplan(liftplan: const [
        [1, 3],
        [2, 4],
        [1, 3],
        [2, 4]
      ]),
      palette: const [DraftColor(r: 0, g: 0, b: 0), DraftColor(r: 255, g: 255, b: 255)],
      warpColors: const [0, 0, 0, 0],
      weftColors: const [0, 0, 0, 0],
      notes: '',
    );
    final out = DraftRepository.applyBasicStructure(
      base: lift,
      effShafts: 4,
      genTieup: const [
        [1, 3],
        [2, 4]
      ],
      applyTreadling: true,
      effTreadles: 2,
      picks: 4,
    );
    expect(out.drive, isA<DraftTreadled>());
    expect((out.drive as DraftTreadled).tieup, const [
      [1, 3],
      [2, 4]
    ]);
    expect(out.picks, 4);
  });
}
