// M8-03 device proof: the warp and weft plan against the REAL engine and filesystem (ADR 0019). The
// towel acceptance fixture's records (a washed 2/2 twill sample and two 8/2 cottons) go into
// Materials and swatches and its four-shaft jack loom into My looms; an 8-end twill draft planned
// for that loom is opened in the editor, and More > Warp and weft plan goes from four 18 in by 30 in
// towels through the sample to the yarn: 494 ends, 247 dents of the 12-dent reed, 2444.08 yd of
// warp yarn. Overriding the take-up alone moves the warp and leaves the swatch file untouched; Use
// the swatch puts it back. The plan is saved with the draft (its sidecar, never the WIF) and comes
// back on reopening. The device's own materials.json and looms.json are put back as they were, and
// the app's units are set to inches for the test without touching the device's settings.
//
//   flutter test integration_test/m8_warp_plan_test.dart -d emulator-5554

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:ply/src/data/draft_repository.dart';
import 'package:ply/src/data/loom_repository.dart';
import 'package:ply/src/data/materials_repository.dart';
import 'package:ply/src/models/app_settings.dart';
import 'package:ply/src/models/draft_doc.dart' show MeasureUnit;
import 'package:ply/src/models/draft_meta.dart';
import 'package:ply/src/models/loom_check.dart';
import 'package:ply/src/models/loom_profile.dart';
import 'package:ply/src/models/loom_type.dart';
import 'package:ply/src/models/material_record.dart';
import 'package:ply/src/models/weave_plan.dart';
import 'package:ply/src/rust/frb_generated.dart';
import 'package:ply/src/screens/editor_screen.dart';
import 'package:ply/src/screens/weave_plan_screen.dart';
import 'package:ply/src/state/editor_providers.dart';
import 'package:ply/src/state/theme_providers.dart';
import 'package:ply/src/state/weave_plan_providers.dart';

/// A 2/2 twill, one 8-end repeat, 8 picks.
String twill() {
  final b = StringBuffer('''[WIF]
Version=1.1
Source Program=Elsewhere
[WEAVING]
Shafts=4
Treadles=4
Rising Shed=true
[WARP]
Threads=8
Units=Inches
[WEFT]
Threads=8
[COLOR TABLE]
1=245,240,230
2=40,60,140
[THREADING]
''');
  for (var e = 1; e <= 8; e++) {
    b.writeln('$e=${(e - 1) % 4 + 1}');
  }
  b.writeln('[TIEUP]');
  for (var t = 1; t <= 4; t++) {
    b.writeln('$t=$t,${t % 4 + 1}');
  }
  b.writeln('[TREADLING]');
  for (var p = 1; p <= 8; p++) {
    b.writeln('$p=${(p - 1) % 4 + 1}');
  }
  b.writeln('[WARP COLORS]');
  for (var e = 1; e <= 8; e++) {
    b.writeln('$e=1');
  }
  b.writeln('[WEFT COLORS]');
  for (var p = 1; p <= 8; p++) {
    b.writeln('$p=2');
  }
  return b.toString();
}

const lb = Mass(1, MassUnit.pound);
const cottonLpm = Recorded.entered(LengthPerMass(Length(3360, LengthUnit.yard), lb));

/// The towel fixture's records (fixtures/weaving/plans/towel.plan.json).
const natural = MaterialRecord(
  id: 'm8-plan-cotton-natural',
  name: '8/2 cotton, natural',
  lengthPerMass: cottonLpm,
  availableLength: Recorded.entered(Length(4200, LengthUnit.yard)),
);
const blue = MaterialRecord(
  id: 'm8-plan-cotton-blue',
  name: '8/2 cotton, blue',
  lengthPerMass: cottonLpm,
  availableMass: Recorded.measured(lb),
);
const sample = SwatchRecord(
  id: 'm8-plan-towel-sample',
  name: 'Towel sample',
  craft: SwatchCraft.weaving,
  technique: '2/2 twill',
  date: '2026-11-03',
  sett: Recorded.entered(CountOver(24, Length(1, LengthUnit.inch))),
  widthInReed: Recorded.entered(Length(12, LengthUnit.inch)),
  onLoom: SwatchStage(
    width: Recorded.measured(Length(11.4, LengthUnit.inch)),
    length: Recorded.measured(Length(20, LengthUnit.inch)),
    along: Recorded.measured(CountOver(24, Length(1, LengthUnit.inch))),
  ),
  before: SwatchStage(
    width: Recorded.measured(Length(11, LengthUnit.inch)),
    length: Recorded.measured(Length(19, LengthUnit.inch)),
  ),
  after: SwatchStage(
    width: Recorded.measured(Length(10.5, LengthUnit.inch)),
    length: Recorded.measured(Length(18, LengthUnit.inch)),
  ),
  finishing: 'machine washed warm, tumble dried, pressed',
);
const jack = LoomProfile(
  id: 'm8-plan-four-shaft-jack',
  name: 'Four-shaft jack loom',
  type: LoomType.jack,
  shafts: 4,
  treadles: 6,
  weavingWidth: LoomLength(24, MeasureUnit.inches),
  reeds: [Reed(12, DentUnit.perInch), Reed(10, DentUnit.perInch)],
  treadlesAtOnce: 2,
);

/// The app's units for this test, set explicitly (the plan's fields are in the app's units): inches,
/// whatever the device's settings say. Nothing is read from or written to the settings file.
class InchesSettings extends AppSettingsNotifier {
  @override
  AppSettings build() => const AppSettings(unit: MeasureUnit.inches);
}

Future<void> settle(WidgetTester tester, {int frames = 20}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Keep a device file and put it back afterwards; start the test without it.
Future<void> setAside(File file) async {
  final before = await file.exists() ? await file.readAsBytes() : null;
  addTearDown(() async {
    if (before == null) {
      if (await file.exists()) await file.delete();
    } else {
      await file.writeAsBytes(before, flush: true);
    }
  });
  if (before != null) await file.delete();
}

Finder inPlan(Finder f) => find.descendant(of: find.byType(WeavePlanScreen), matching: f);

/// Scroll the plan until [f] is on screen. The plan is a lazy list: on a phone a row above the
/// current position may not be built at all, and scrolling on down would never find it. So when
/// [f] is not on screen, start again from the top of the plan. The last scroll is a jump, so pump
/// a few frames after it: a tap reads where things were laid out, and until the next frame that is
/// still where they were before the jump.
Future<void> reveal(WidgetTester tester, Finder f) async {
  final plan = find
      .descendant(of: find.byKey(const ValueKey('weave-plan')), matching: find.byType(Scrollable))
      .first;
  if (f.evaluate().isEmpty) {
    tester.state<ScrollableState>(plan).position.jumpTo(0);
    await settle(tester, frames: 4);
  }
  await tester.scrollUntilVisible(f, 200, scrollable: plan);
  await settle(tester, frames: 4);
}

Future<void> choose(WidgetTester tester, String key, String item) async {
  await reveal(tester, find.byKey(ValueKey(key)));
  await tester.tap(find.byKey(ValueKey(key)));
  await settle(tester);
  await tester.tap(find.text(item).last);
  await settle(tester);
}

/// Type into a plan field. On a device enterText types through the real soft keyboard, which
/// slides up and makes the plan scroll the field into view; a tap made meanwhile can miss (the list
/// ignores taps while it scrolls). So close the keyboard, as a weaver would, and let it settle.
Future<void> type(WidgetTester tester, String key, String text) async {
  await reveal(tester, find.byKey(ValueKey(key)));
  await tester.enterText(find.byKey(ValueKey(key)), text);
  FocusManager.instance.primaryFocus?.unfocus();
  await settle(tester);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  testWidgets('four towels planned from a washed sample to the yarn, saved with the draft',
      (tester) async {
    // A tap that misses fails here, where it missed, not as a puzzle several steps later.
    WidgetController.hitTestWarningShouldBeFatal = true;
    addTearDown(() => WidgetController.hitTestWarningShouldBeFatal = false);
    final materials = MaterialsRepository();
    final looms = LoomRepository();
    final drafts = DraftRepository();
    final materialsFile = await materials.file();
    final loomsFile = await looms.file();
    await setAside(materialsFile);
    await setAside(loomsFile);
    await materials.saveAll(const MaterialLibrary(materials: [natural, blue], swatches: [sample]));
    await looms.saveAll(const [jack]);
    final recordsBytes = await materialsFile.readAsBytes();

    final wif = twill();
    final id = await drafts.saveDto(
      await drafts.parseDoc(wif),
      meta: DraftMeta(
        name: 'Tea towels',
        savedAt: DateTime.now(),
        lastOpened: DateTime.now(),
        loomPlan: LoomPlan(loomId: jack.id, loomName: jack.name),
      ),
      sourceWif: wif,
    );
    addTearDown(() => drafts.delete(id));

    final overrides = [
      repositoryProvider.overrideWithValue(drafts),
      appSettingsProvider.overrideWith(InchesSettings.new),
    ];
    // A fresh app on the editor (a relaunch: the old app, if any, is taken down first, so the
    // reopened editor reads the draft and its plan from disk rather than keeping them in memory).
    Future<void> openEditor() async {
      final entry = await drafts.open(id);
      await tester.pumpWidget(const SizedBox());
      await settle(tester, frames: 4);
      await tester.pumpWidget(ProviderScope(
        overrides: overrides,
        child: MaterialApp(
          home: EditorScreen(
              wifText: await drafts.readWif(id), title: entry.meta.name, id: id, meta: entry.meta),
        ),
      ));
      await settle(tester, frames: 40);
    }

    // 1. Open the plan from the editor's menu.
    await openEditor();
    await tester.tap(find.byTooltip('More actions'));
    await settle(tester);
    await tester.tap(find.text('$kWeavePlanTitle…'));
    await settle(tester, frames: 30);
    expect(find.byType(WeavePlanScreen), findsOneWidget);

    // 2. The finished size, the structure, the swatch and the yarns, and the loom's own waste.
    await choose(tester, 'plan-structure', 'Twill');
    await type(tester, 'plan-items', '4');
    await type(tester, 'plan-finished-width', '18');
    await type(tester, 'plan-finished-length', '30');
    await type(tester, 'plan-hems', '4');
    await type(tester, 'plan-end-multiple', '4');
    await type(tester, 'plan-extra-ends', '2');
    await choose(tester, 'plan-swatch', 'Towel sample (2026-11-03)');
    await choose(tester, 'plan-warp-yarn', '8/2 cotton, natural');
    await choose(tester, 'plan-weft-yarn', '8/2 cotton, blue');
    await settle(tester, frames: 30);
    await reveal(tester, find.byKey(const ValueKey('change-loomWaste')));
    await tester.tap(find.byKey(const ValueKey('change-loomWaste')));
    await settle(tester);
    await tester.enterText(find.byKey(const ValueKey('override-value')), '27');
    await tester.tap(find.text('Use this value'));
    await settle(tester, frames: 30);

    // 3. The engine's worksheet, as the fixture's hand working gives it.
    final input = find.byKey(const ValueKey('input-length_loss'));
    await reveal(tester, input);
    expect(
        tester.widget<Text>(input).data,
        'Take-up and shrinkage: 10% of the length on the loom, from the loom to finished, from 20 '
        'in on the loom and 18 in after wet finishing (measured), swatch Towel sample 2026-11-03');
    for (final text in [
      'Warp ends: 494 ends',
      'Width in the reed: 20.58 in (52.28 cm)',
      'Warp length: 4.95 yd (4.52 m)',
      'Warp yarn: 2444.08 yd (2234.87 m)',
      'Picks: 3628 picks',
      'Weft yarn: 2281.78 yd (2086.46 m)',
    ]) {
      await reveal(tester, inPlan(find.text(text)));
      expect(inPlan(find.text(text)), findsOneWidget, reason: text);
    }
    await reveal(tester, inPlan(find.textContaining('494 ends fill 247 dents')));
    await reveal(tester, inPlan(find.textContaining('About 1755.92 yd left over')));

    // 4. Override the take-up alone: the warp moves, the swatch file does not.
    await reveal(tester, find.byKey(const ValueKey('change-takeUp')));
    await tester.tap(find.byKey(const ValueKey('change-takeUp')));
    await settle(tester);
    await tester.enterText(find.byKey(const ValueKey('override-value')), '12');
    await tester.tap(find.text('Use this value'));
    await settle(tester, frames: 30);
    await reveal(tester, inPlan(find.text('Warp yarn: 2609.02 yd (2385.69 m)')));
    expect(await materialsFile.readAsBytes(), recordsBytes, reason: 'the swatch is never written');
    await reveal(tester, find.byKey(const ValueKey('reset-takeUp')));
    await tester.tap(find.byKey(const ValueKey('reset-takeUp')));
    await settle(tester, frames: 30);
    await reveal(tester, inPlan(find.text('Warp yarn: 2444.08 yd (2234.87 m)')));

    // 5. Back to the editor and save: the plan goes into the sidecar, never the WIF.
    final container = ProviderScope.containerOf(tester.element(find.byType(WeavePlanScreen)));
    final plan = container.read(draftWeavePlanProvider)!;
    await tester.pageBack();
    await settle(tester, frames: 20);
    await tester.tap(find.byTooltip('Save'));
    await settle(tester, frames: 40);
    expect(await drafts.readWif(id), wif, reason: 'the WIF is saved as it was');
    final entry = await drafts.open(id);
    expect(entry.meta.weavePlan, plan);
    expect(entry.meta.weavePlan!.swatchId, sample.id);
    expect(entry.meta.weavePlan!.overrides.value<Length>(PlanAssumption.loomWaste),
        const Length(27, LengthUnit.inch));
    expect(entry.meta.weavePlan!.overrides.has(PlanAssumption.takeUp), isFalse);

    // 6. Reopen: the plan is there and works out the same.
    await openEditor();
    await tester.tap(find.byTooltip('More actions'));
    await settle(tester);
    await tester.tap(find.text('$kWeavePlanTitle…'));
    await settle(tester, frames: 40);
    await reveal(tester, inPlan(find.text('Warp ends: 494 ends')));
    expect(inPlan(find.text('Warp ends: 494 ends')), findsOneWidget);
  });
}
