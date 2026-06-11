// M2 Phase-1 spike proof, on a real device.
//
// Proves the architecture-defining claim in one test: the transparently-mirrored `DraftDto`
// retires M1's opaque single-use `Draft` trap. We parse a WIF into ONE `DraftDto`, read its
// fields (transparency), pattern-match its freezed sealed `DriveDto` (the sum-type invariant),
// and render the SAME instance TWICE — which would be a use-after-free with the old opaque
// handle but is fine for a mirrored value type.
//
//   flutter test integration_test/m2_dto_spike_test.dart -d emulator-5554

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:ply/src/rust/api.dart';
import 'package:ply/src/rust/dto.dart';
import 'package:ply/src/rust/frb_generated.dart';

/// A 4x4, 2/2 twill (straight threading + treadling), black warp / white weft.
const String kTwillWif = '''[WIF]
Version=1.1
[WEAVING]
Shafts=4
Treadles=4
Rising Shed=true
[WARP]
Threads=4
Units=Inches
[WEFT]
Threads=4
[COLOR TABLE]
1=0,0,0
2=255,255,255
[THREADING]
1=1
2=2
3=3
4=4
[TIEUP]
1=1,2
2=2,3
3=3,4
4=1,4
[TREADLING]
1=1
2=2
3=3
4=4
[WARP COLORS]
1=1
2=1
3=1
4=1
[WEFT COLORS]
1=2
2=2
3=2
4=2
''';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  testWidgets('DraftDto is transparent, a real sum type, and not single-use',
      (tester) async {
    // Parse once into a plain mirrored value.
    final dto = await parseWifDto(text: kTwillWif);

    // Transparency: fields are readable Dart values, not an opaque handle.
    expect(dto.shafts, 4);
    expect(dto.treadles, 4);
    expect(dto.shed, ShedKind.rising);
    expect(dto.unit, UnitKind.inches);
    expect(dto.threading.length, 4);
    expect(dto.palette.length, 2);
    expect(dto.warpColors.length, 4);
    expect(dto.weftColors.length, 4);

    // The Drive sum type survives the wire as a freezed sealed class: it is treadled,
    // with a 4-treadle tie-up and 4-pick treadling. Pattern-match proves both/neither
    // is unrepresentable at the Dart type level.
    final drive = dto.drive;
    switch (drive) {
      case DriveDto_Treadled(:final tieup, :final treadling):
        expect(tieup.length, 4);
        expect(treadling.length, 4);
      case DriveDto_Liftplan():
        fail('twill fixture is treadled, not liftplan');
    }

    // THE TRAP KILL: render the SAME dto instance twice. With the old opaque move-by-value
    // Draft this would be a use-after-free; with a mirrored value it just works, identically.
    final first = await renderPreviewDto(dto: dto, cellPx: 16);
    final second = await renderPreviewDto(dto: dto, cellPx: 16);

    expect(first.width, 64);
    expect(first.height, 64);
    expect(second.width, first.width);
    expect(second.height, first.height);
    expect(second.rgba, equals(first.rgba),
        reason: 'two renders of the same DTO must be byte-identical');

    // And the DTO is STILL usable after two renders (not consumed/freed).
    final third = await renderPreviewDto(dto: dto, cellPx: 8);
    expect(third.width, 32);
    expect(third.height, 32);
  });
}
