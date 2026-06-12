// M2 Phase-5.1 device proof: the planning calculators against the REAL engine, matching the
// ply-weave cargo math.
//
//   flutter test integration_test/m5_calc_test.dart -d emulator-5554

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:ply/src/data/draft_repository.dart';
import 'package:ply/src/rust/frb_generated.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  testWidgets('suggestSettCalc matches the engine: round(WPI * structure fraction)', (tester) async {
    final repo = DraftRepository();
    expect(await repo.suggestSettCalc(20, 'plain'), 10.0); // 20 * 0.50
    expect(await repo.suggestSettCalc(20, 'twill'), 13.0); // round(20 * 0.66)
    expect(await repo.suggestSettCalc(20, 'satin'), 15.0); // 20 * 0.75
    // An unknown structure falls back to plain.
    expect(await repo.suggestSettCalc(20, 'bogus'), 10.0);
  });

  testWidgets('estimateWarpPlan matches the engine (take-up as a percent)', (tester) async {
    final repo = DraftRepository();
    // finished 2.0 * (1 + 0.10) * 1 item + 0.5 loom waste = 2.7; total = 2.7 * 10 ends = 27.0.
    final (warpLength, totalWarp) = await repo.estimateWarpPlan(
      finishedLength: 2.0,
      items: 1,
      ends: 10,
      loomWaste: 0.5,
      takeupPercent: 10,
    );
    expect(warpLength, closeTo(2.7, 0.001));
    expect(totalWarp, closeTo(27.0, 0.001));
  });
}
