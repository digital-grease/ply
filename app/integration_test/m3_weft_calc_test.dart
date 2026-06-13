// M3 Phase-1 device proof: the weft calculator against the REAL engine, matching ply-weave's
// `weft_estimate_uses_user_takeup` cargo math through the transparent WeftPlanDto bridge.
//
//   flutter test integration_test/m3_weft_calc_test.dart -d emulator-5554

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:ply/src/data/draft_repository.dart';
import 'package:ply/src/rust/frb_generated.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  testWidgets('estimateWeftPlan matches the engine (take-up as a percent)', (tester) async {
    final repo = DraftRepository();
    // picks = round(12 ppi * 60") * 1 item = 720; total = 720 * 20" * (1 + 0.10) = 15_840.
    final (picks, totalWeft) = await repo.estimateWeftPlan(
      picksPerUnit: 12,
      width: 20,
      wovenLength: 60,
      items: 1,
      takeupPercent: 10,
    );
    expect(picks, 720);
    expect(totalWeft, closeTo(15840.0, 0.001));
  });

  testWidgets('weft picks scale with item count', (tester) async {
    final repo = DraftRepository();
    final (picks, _) = await repo.estimateWeftPlan(
      picksPerUnit: 12,
      width: 20,
      wovenLength: 60,
      items: 3,
      takeupPercent: 0,
    );
    expect(picks, 2160); // 720 * 3
  });
}
