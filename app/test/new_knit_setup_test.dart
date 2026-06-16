import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/models/knit_stitches.dart';
import 'package:ply/src/rust/knit_dto.dart';
import 'package:ply/src/screens/new_knit_setup_screen.dart';

// The PURE chart-fill of the New-knit setup screen (the FFI parts — blank pattern + gauge seed — are
// engine-tested separately). Confirms each starting stitch pattern paints the right cells and the
// re-paint preserves width, per-row repeats, and cell colors.

ChartDto allKnit(int w, int h) => ChartDto(
      width: w,
      rows: [
        for (var r = 0; r < h; r++)
          RowDto(
            cells: [for (var c = 0; c < w; c++) const CellDto(stitch: KnitStitch.knit)],
            repeats: const <RepeatSpanDto>[],
          ),
      ],
    );

void main() {
  test('starterStitchAt places knit/purl per pattern', () {
    // Stockinette: knit everywhere.
    expect(starterStitchAt(KnitStarter.stockinette, 2, 3), KnitStitch.knit);
    // Garter: odd ROWS purl (horizontal ridges).
    expect(starterStitchAt(KnitStarter.garter, 0, 5), KnitStitch.knit);
    expect(starterStitchAt(KnitStarter.garter, 1, 0), KnitStitch.purl);
    // 1x1 ribbing: odd COLUMNS purl (vertical ribs).
    expect(starterStitchAt(KnitStarter.ribbing, 3, 0), KnitStitch.knit);
    expect(starterStitchAt(KnitStarter.ribbing, 3, 1), KnitStitch.purl);
    // Seed: (row+col) odd purl (checkerboard).
    expect(starterStitchAt(KnitStarter.seed, 0, 0), KnitStitch.knit);
    expect(starterStitchAt(KnitStarter.seed, 0, 1), KnitStitch.purl);
    expect(starterStitchAt(KnitStarter.seed, 1, 1), KnitStitch.knit);
  });

  test('starterChart fills cells and preserves shape + repeats', () {
    final base = allKnit(4, 3);

    final seed = starterChart(base, KnitStarter.seed);
    expect(seed.width, 4);
    expect(seed.rows.length, 3);
    expect(seed.rows[0].cells[0].stitch, KnitStitch.knit);
    expect(seed.rows[0].cells[1].stitch, KnitStitch.purl);
    expect(seed.rows[1].cells[0].stitch, KnitStitch.purl);
    expect(seed.rows[0].repeats, isEmpty, reason: 'per-row repeat info is carried through');

    final ribbing = starterChart(base, KnitStarter.ribbing);
    expect(ribbing.rows.every((row) => row.cells[0].stitch == KnitStitch.knit), isTrue);
    expect(ribbing.rows.every((row) => row.cells[1].stitch == KnitStitch.purl), isTrue);

    final stock = starterChart(base, KnitStarter.stockinette);
    expect(stock.rows.every((row) => row.cells.every((c) => c.stitch == KnitStitch.knit)), isTrue);
  });
}
