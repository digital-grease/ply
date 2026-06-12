// M2 Phase-4.1 device proof: the SAFE palette remove against the REAL engine.
//
// The load-bearing claim: removing a REFERENCED palette color remaps the threads that used it (to
// color 0) and renumbers the survivors, so the result validate()s clean and the cloth re-colors
// WITHOUT the silent-white mis-render a naive remove would cause. Plus: a swatch RGB edit re-renders
// the cloth, and removing the last color is blocked by the engine.
//
//   flutter test integration_test/m4_palette_test.dart -d emulator-5554

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:ply/src/data/draft_repository.dart';
import 'package:ply/src/models/draft_doc.dart';
import 'package:ply/src/rust/frb_generated.dart';

/// All-warp-showing draft (rising liftplan raising the only threaded shaft), so each warp end's
/// color fills its drawdown column. Palette: black(0), red(1), green(2). end0 uses red, end1 green.
DraftDoc referencedPaletteDraft() => DraftDoc(
      name: 'r',
      shafts: 1,
      treadles: 0,
      shed: Shed.rising,
      unit: MeasureUnit.inches,
      threading: const [
        [1],
        [1],
      ],
      drive: DraftLiftplan(liftplan: const [
        [1],
        [1],
      ]),
      palette: const [
        DraftColor(r: 0, g: 0, b: 0), // 0 black
        DraftColor(r: 255, g: 0, b: 0), // 1 red
        DraftColor(r: 0, g: 255, b: 0), // 2 green
      ],
      warpColors: const [1, 2], // end0 = red, end1 = green
      weftColors: const [0, 0],
      notes: '',
    );

Future<Uint8List> rawBytes(ui.Image image) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  return data!.buffer.asUint8List();
}

/// The RGB of the pixel at (x, y) in a row-major RGBA image.
(int, int, int) pixelAt(ui.Image img, Uint8List bytes, int x, int y) {
  final i = (y * img.width + x) * 4;
  return (bytes[i], bytes[i + 1], bytes[i + 2]);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  testWidgets('removing a REFERENCED color remaps threads, stays validate-clean, no silent white',
      (tester) async {
    final repo = DraftRepository();
    final doc = referencedPaletteDraft();
    const px = 12;

    // BEFORE: end0 (leftmost column, end-0-LEFT) is RED.
    final before = await repo.renderDto(doc, cellPx: px);
    final beforeBytes = await rawBytes(before);
    expect(pixelAt(before, beforeBytes, px ~/ 2, before.height ~/ 2), (255, 0, 0),
        reason: 'end0 starts red');
    before.dispose();

    // Remove RED (index 1) via the REAL engine.
    final removed = await repo.removeColorDoc(doc, 1);

    // Remap is correct and nothing dangles.
    expect(removed.palette.length, 2, reason: 'palette shrank by one');
    expect(removed.warpColors, const [0, 1],
        reason: 'end0 (was red=1) -> 0; end1 (was green=2) renumbered -> 1');
    expect((await repo.validateDto(removed)).where((i) => i.isError), isEmpty,
        reason: 'no dangling-index Error after a safe remove');

    // AFTER: end0 re-colors to palette[0] (BLACK), NOT silent white.
    final after = await repo.renderDto(removed, cellPx: px);
    final afterBytes = await rawBytes(after);
    final end0 = pixelAt(after, afterBytes, px ~/ 2, after.height ~/ 2);
    expect(end0, (0, 0, 0), reason: 'the remapped thread shows palette[0] (black)');
    expect(end0, isNot((255, 255, 255)), reason: 'never the silent-white mis-render');
    after.dispose();
  });

  testWidgets('a swatch RGB edit re-renders the cloth (setPaletteColor path)', (tester) async {
    final repo = DraftRepository();
    final doc = referencedPaletteDraft();
    const px = 12;

    final before = await rawBytes(await repo.renderDto(doc, cellPx: px));
    // Recolor index 1 (red) to blue — a pure-Dart copyWith of the palette (what setPaletteColor does).
    final edited = doc.copyWith(palette: [
      doc.palette[0],
      const DraftColor(r: 0, g: 0, b: 255),
      doc.palette[2],
    ]);
    final after = await repo.renderDto(edited, cellPx: px);
    final afterBytes = await rawBytes(after);
    expect(pixelAt(after, afterBytes, px ~/ 2, after.height ~/ 2), (0, 0, 255),
        reason: 'end0 (index 1) now renders blue');
    expect(afterBytes, isNot(equals(before)), reason: 'the cloth re-rendered');
    after.dispose();
  });

  testWidgets('removing the last color is blocked by the engine', (tester) async {
    final repo = DraftRepository();
    final oneColor = referencedPaletteDraft().copyWith(
      palette: const [DraftColor(r: 0, g: 0, b: 0)],
      warpColors: const [0, 0],
      weftColors: const [0, 0],
    );
    await expectLater(repo.removeColorDoc(oneColor, 0), throwsA(isA<Object>()),
        reason: 'a draft needs at least one color');
  });
}
