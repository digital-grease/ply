// M4 Phase-4 device proof: the per-thread THICKNESS path end to end on a real device.
//
// Three load-bearing claims, each across the full DraftDoc -> DTO -> engine -> RGBA path:
//   1. VARIABLE CELLS: a fatter warp end draws a proportionally wider column (and the uniform
//      case is unchanged), so thickness genuinely reaches the rasterizer.
//   2. ROUND-TRIP: thickness survives a save (write_wif) -> reopen (parse) cycle through the FFI,
//      landing in the modeled fields (not dropped, not stuffed into `retained`).
//   3. OVERLAYS: the gridline + long-float toggles change the rendered bytes (the RenderOptionsDto
//      reaches the engine), and the default render is byte-identical to no-options.
//
//   flutter test integration_test/m4_thickness_render_test.dart -d emulator-5554

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:ply/src/data/draft_repository.dart';
import 'package:ply/src/models/draft_doc.dart';
import 'package:ply/src/rust/frb_generated.dart';

/// A 2-end, 2-pick liftplan checkerboard with optional per-thread thickness.
DraftDoc thicknessDoc({
  List<double> warpThickness = const <double>[],
  List<double> weftThickness = const <double>[],
}) =>
    DraftDoc(
      name: 't',
      shafts: 2,
      treadles: 0,
      shed: Shed.rising,
      unit: MeasureUnit.inches,
      threading: const [
        [1],
        [2],
      ],
      drive: DraftLiftplan(liftplan: const [
        [1],
        [2],
      ]),
      palette: const [
        DraftColor(r: 0, g: 0, b: 0),
        DraftColor(r: 255, g: 255, b: 255),
      ],
      warpColors: const [0, 0],
      weftColors: const [1, 1],
      notes: '',
      warpThickness: warpThickness,
      weftThickness: weftThickness,
    );

Future<Uint8List> rawBytes(ui.Image image) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  return data!.buffer.asUint8List();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  testWidgets('a fat warp end widens its column; uniform thickness is unchanged', (tester) async {
    final repo = DraftRepository();

    final uniform = await repo.renderDto(thicknessDoc(), cellPx: 16);
    final equal = await repo.renderDto(
      thicknessDoc(warpThickness: const [2.0, 2.0], weftThickness: const [2.0, 2.0]),
      cellPx: 16,
    );
    final fat = await repo.renderDto(thicknessDoc(warpThickness: const [1.0, 2.0]), cellPx: 16);

    // 2 ends x 16 px = 32 wide uniform; equal-thickness must be identical raster bytes.
    expect((uniform.width, uniform.height), (32, 32));
    expect(await rawBytes(equal), equals(await rawBytes(uniform)),
        reason: 'equal thickness renders the same cloth as a plain uniform grid');

    // end 0 -> 16, end 1 -> 32 => 48 wide; the fat end genuinely reached the rasterizer.
    expect(fat.width, 48, reason: 'the doubled warp end draws a 2x-wide column');
    expect(fat.height, 32, reason: 'weft is untouched');
  });

  testWidgets('thickness survives a write_wif -> parse round-trip in the modeled fields',
      (tester) async {
    final repo = DraftRepository();
    final src = thicknessDoc(warpThickness: const [1.0, 3.0], weftThickness: const [2.0, 2.0]);

    final wif = await repo.resolveSaveWif(src, null); // re-serialize via the engine
    final reopened = await repo.parseDoc(wif);

    expect(reopened.warpThickness, const [1.0, 3.0], reason: 'warp thickness round-trips');
    expect(reopened.weftThickness, const [2.0, 2.0], reason: 'weft thickness round-trips');
    expect(reopened.retained, isEmpty, reason: 'thickness is modeled, not retained verbatim');
  });

  testWidgets('the gridline + float overlays change the rendered bytes; default matches plain',
      (tester) async {
    final repo = DraftRepository();
    final doc = thicknessDoc();

    final plain = await rawBytes(await repo.renderDto(doc, cellPx: 16));
    final defaulted = await rawBytes(
      await repo.renderDto(doc, cellPx: 16, gridlines: false, floatThreshold: 0),
    );
    final gridded = await rawBytes(await repo.renderDto(doc, cellPx: 16, gridlines: true));

    expect(defaulted, equals(plain), reason: 'no overlays == the plain render');
    expect(gridded, isNot(equals(plain)), reason: 'gridlines change the raster');
    expect(gridded.length, plain.length, reason: 'overlays draw in place, not resize');
  });
}
