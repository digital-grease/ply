// M2 Phase-4.2 device proof: painting warp/weft COLORS updates the rendered cloth (real FFI), and
// the color lengths stay coupled to ends/picks.
//
//   flutter test integration_test/m4_color_bands_test.dart -d emulator-5554

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:ply/src/data/draft_repository.dart';
import 'package:ply/src/models/draft_doc.dart';
import 'package:ply/src/models/editor_state.dart';
import 'package:ply/src/rust/frb_generated.dart';

/// All-WARP-showing (rising liftplan raising the only threaded shaft), so each warp end's color
/// fills its drawdown column. Palette: black(0), red(1), green(2).
DraftDoc allWarp() => DraftDoc(
      name: 'w',
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
        DraftColor(r: 0, g: 0, b: 0),
        DraftColor(r: 255, g: 0, b: 0),
        DraftColor(r: 0, g: 255, b: 0),
      ],
      warpColors: const [0, 0],
      weftColors: const [0, 0],
      notes: '',
    );

/// All-WEFT-showing (liftplan raises an UNTHREADED shaft, so no warp is ever up), so each pick's
/// weft color fills its row.
DraftDoc allWeft() => DraftDoc(
      name: 'wf',
      shafts: 2,
      treadles: 0,
      shed: Shed.rising,
      unit: MeasureUnit.inches,
      threading: const [
        [1],
        [1],
      ],
      drive: DraftLiftplan(liftplan: const [
        [2],
        [2],
      ]),
      palette: const [
        DraftColor(r: 0, g: 0, b: 0),
        DraftColor(r: 255, g: 0, b: 0),
        DraftColor(r: 0, g: 255, b: 0),
      ],
      warpColors: const [0, 0],
      weftColors: const [0, 0],
      notes: '',
    );

Future<Uint8List> rawBytes(ui.Image image) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  return data!.buffer.asUint8List();
}

(int, int, int) pixelAt(ui.Image img, Uint8List bytes, int x, int y) {
  final i = (y * img.width + x) * 4;
  return (bytes[i], bytes[i + 1], bytes[i + 2]);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  testWidgets('painting a warp stripe updates the rendered cloth', (tester) async {
    final repo = DraftRepository();
    final src = allWarp();
    const px = 12;

    final before = await rawBytes(await repo.renderDto(src, cellPx: px));
    // fillWarpStripe([1,2]) -> warpColors [1,2] = red, green. end0 (leftmost column) becomes red.
    final painted = EditorState(draft: src).fillWarpStripe([1, 2]).draft;
    expect(painted.warpColors, const [1, 2]);
    expect(painted.warpColors.length, painted.ends, reason: 'warp length stays == ends');

    final after = await repo.renderDto(painted, cellPx: px);
    final afterBytes = await rawBytes(after);
    expect(pixelAt(after, afterBytes, px ~/ 2, after.height ~/ 2), (255, 0, 0),
        reason: 'end0 painted red');
    expect(afterBytes, isNot(equals(before)), reason: 'the cloth re-rendered');
    after.dispose();
  });

  testWidgets('painting a weft stripe updates the rendered cloth (pick-0 bottom)', (tester) async {
    final repo = DraftRepository();
    final src = allWeft();
    const px = 12;

    final before = await rawBytes(await repo.renderDto(src, cellPx: px));
    final painted = EditorState(draft: src).fillWeftStripe([1, 2]).draft; // pick0 red, pick1 green
    expect(painted.weftColors.length, painted.picks, reason: 'weft length stays == picks');

    final after = await repo.renderDto(painted, cellPx: px);
    final afterBytes = await rawBytes(after);
    // pick 0 is the BOTTOM row.
    expect(pixelAt(after, afterBytes, px ~/ 2, after.height - px ~/ 2), (255, 0, 0),
        reason: 'pick 0 (bottom) painted red');
    expect(afterBytes, isNot(equals(before)));
    after.dispose();
  });

  testWidgets('color lengths stay coupled through a paint then a resize (validate clean)',
      (tester) async {
    final repo = DraftRepository();
    final painted = EditorState(draft: allWarp()).fillWarpStripe([1, 2]).draft;
    expect((await repo.validateDto(painted)).where((i) => i.isError), isEmpty);

    // A resize re-couples warp/weft to the new ends/picks (engine resize trims/pads).
    final resized = await repo.resizeDoc(painted, ends: 4, picks: 2, shafts: 1, treadles: 0);
    expect(resized.warpColors.length, resized.ends);
    expect(resized.weftColors.length, resized.picks);
    expect((await repo.validateDto(resized)).where((i) => i.isError), isEmpty,
        reason: 'no warp/weft color-count Error after the paint + resize');
  });
}
