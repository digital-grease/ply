import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/draft_repository.dart';
import 'package:ply/src/models/draft_doc.dart';
import 'package:ply/src/state/draft_editor_notifier.dart';
import 'package:ply/src/state/editor_providers.dart';
import 'package:ply/src/widgets/planning_sheet.dart';

// The planning calculator's UI logic: seeding ends from the draft, parsing/validating inputs, calling
// the repo wrappers (faked), the percent->the-wrapper hand-off, and the blank-draft sett case. The
// engine math itself is cargo-tested + device-verified separately.

class FakePlanningRepo extends DraftRepository {
  double? settWpi;
  String? settStructure;
  double settReturn = 12.0;
  ({double finishedLength, int items, int ends, double loomWaste, double takeupPercent})? warpArgs;

  @override
  Future<double> suggestSettCalc(double wpi, String structure) async {
    settWpi = wpi;
    settStructure = structure;
    return settReturn;
  }

  @override
  Future<(double, double)> estimateWarpPlan({
    required double finishedLength,
    required int items,
    required int ends,
    required double loomWaste,
    required double takeupPercent,
  }) async {
    warpArgs = (
      finishedLength: finishedLength,
      items: items,
      ends: ends,
      loomWaste: loomWaste,
      takeupPercent: takeupPercent,
    );
    return (27.0, 270.0);
  }
}

/// A draft with 4 ends (threading length 4) so the warp "ends" field seeds to 4.
DraftDoc fourEnds() => DraftDoc(
      name: 'f',
      shafts: 2,
      treadles: 0,
      shed: Shed.rising,
      unit: MeasureUnit.inches,
      threading: const [
        [1],
        [2],
        [1],
        [2],
      ],
      drive: DraftLiftplan(liftplan: const [[1]]),
      palette: const [DraftColor(r: 0, g: 0, b: 0)],
      warpColors: const [0, 0, 0, 0],
      weftColors: const [0],
      notes: '',
    );

Future<ProviderContainer> pumpSheet(WidgetTester t, FakePlanningRepo repo, {DraftDoc? doc}) async {
  final c = ProviderContainer(overrides: [repositoryProvider.overrideWithValue(repo)]);
  addTearDown(c.dispose);
  c.read(draftEditorProvider.notifier).load(doc ?? fourEnds());
  await t.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: const MaterialApp(home: Scaffold(body: PlanningSheet())),
    ),
  );
  await t.pump();
  return c;
}

void main() {
  testWidgets('renders both sections and seeds warp ends from the draft', (t) async {
    await pumpSheet(t, FakePlanningRepo()); // 4 ends
    expect(find.text('Suggest a sett'), findsOneWidget);
    expect(find.text('Estimate warp yarn'), findsOneWidget);
    // The "Warp ends" field is pre-filled with the draft's ends.
    final ends = t.widget<TextFormField>(find.widgetWithText(TextFormField, 'Warp ends'));
    expect(ends.controller!.text, '4');
  });

  testWidgets('Suggest sett parses WPI + structure and shows the result', (t) async {
    final repo = FakePlanningRepo();
    await pumpSheet(t, repo);
    await t.enterText(find.widgetWithText(TextFormField, 'Wraps per inch'), '20');
    await t.tap(find.text('Suggest sett'));
    await t.pump();
    expect(repo.settWpi, 20.0);
    expect(repo.settStructure, 'plain');
    expect(find.text('12 ends/in'), findsOneWidget);
  });

  testWidgets('invalid WPI shows an inline error and does NOT call the engine', (t) async {
    final repo = FakePlanningRepo();
    await pumpSheet(t, repo);
    await t.tap(find.text('Suggest sett')); // WPI empty
    await t.pump();
    expect(find.text('Enter a number greater than 0'), findsOneWidget);
    expect(repo.settWpi, isNull, reason: 'no FFI on invalid input');
  });

  testWidgets('the sett section works on a BLANK draft (ends == 0)', (t) async {
    final repo = FakePlanningRepo();
    await pumpSheet(t, repo, doc: DraftDoc.blank()); // 0 ends
    final ends = t.widget<TextFormField>(find.widgetWithText(TextFormField, 'Warp ends'));
    expect(ends.controller!.text, isEmpty, reason: 'nothing to seed on a blank draft');
    // The sett section is independent of ends.
    await t.enterText(find.widgetWithText(TextFormField, 'Wraps per inch'), '24');
    await t.tap(find.text('Suggest sett'));
    await t.pump();
    expect(repo.settWpi, 24.0);
    expect(find.text('12 ends/in'), findsOneWidget);
  });

  testWidgets('Estimate warp passes the parsed fields (take-up as a percent) and shows the result',
      (t) async {
    final repo = FakePlanningRepo();
    await pumpSheet(t, repo);
    await t.enterText(find.widgetWithText(TextFormField, 'Finished length (in)'), '2');
    await t.enterText(find.widgetWithText(TextFormField, 'Loom waste (in)'), '0.5');
    // items default '1', ends seeded '4', take-up default '10'.
    await t.tap(find.text('Estimate warp'));
    await t.pump();
    expect(repo.warpArgs, isNotNull);
    expect(repo.warpArgs!.finishedLength, 2.0);
    expect(repo.warpArgs!.items, 1);
    expect(repo.warpArgs!.ends, 4);
    expect(repo.warpArgs!.loomWaste, 0.5);
    expect(repo.warpArgs!.takeupPercent, 10.0, reason: 'entered as a percent; the repo divides by 100');
    expect(find.text('Warp length: 27 in'), findsOneWidget);
    expect(find.text('Total warp yarn: 270 in'), findsOneWidget);
  });

  testWidgets('an empty required warp field blocks the estimate', (t) async {
    final repo = FakePlanningRepo();
    await pumpSheet(t, repo);
    await t.tap(find.text('Estimate warp')); // Finished length is empty
    await t.pump();
    expect(repo.warpArgs, isNull, reason: 'no FFI until every field is valid');
    expect(find.text('Enter a number greater than 0'), findsWidgets);
  });

  testWidgets('an over-large count is rejected with an inline error, NOT silently truncated', (t) async {
    final repo = FakePlanningRepo();
    await pumpSheet(t, repo);
    await t.enterText(find.widgetWithText(TextFormField, 'Finished length (in)'), '2');
    await t.enterText(find.widgetWithText(TextFormField, 'Warp ends'), '5000000000'); // > u32
    await t.tap(find.text('Estimate warp'));
    await t.pump();
    expect(find.text('Too large'), findsWidgets);
    expect(repo.warpArgs, isNull, reason: 'a > u32 count never crosses FFI to truncate');
  });

  test('the repo backstop THROWS on a > u32 count rather than truncating', () async {
    // The UI caps far below this; the repo is the backstop for any direct caller. The guard throws
    // before any FFI, so this runs on the host VM.
    final repo = DraftRepository();
    await expectLater(
      repo.estimateWarpPlan(
          finishedLength: 1, items: 0x100000000, ends: 1, loomWaste: 0, takeupPercent: 0),
      throwsRangeError,
    );
  });

  testWidgets('the structure dropdown selection is passed to the engine', (t) async {
    final repo = FakePlanningRepo();
    await pumpSheet(t, repo);
    await t.enterText(find.widgetWithText(TextFormField, 'Wraps per inch'), '20');
    await t.tap(find.text('Plain')); // open the dropdown
    await t.pumpAndSettle();
    await t.tap(find.text('Twill').last);
    await t.pumpAndSettle();
    await t.tap(find.text('Suggest sett'));
    await t.pump();
    expect(repo.settStructure, 'twill');
  });

  testWidgets('a too-small WPI shows a "too low" message, not "0 ends/in"', (t) async {
    final repo = FakePlanningRepo()..settReturn = 0.0; // a tiny WPI rounds to 0
    await pumpSheet(t, repo);
    await t.enterText(find.widgetWithText(TextFormField, 'Wraps per inch'), '1');
    await t.tap(find.text('Suggest sett'));
    await t.pump();
    expect(find.textContaining('too low'), findsOneWidget);
    expect(find.text('0 ends/in'), findsNothing);
  });

  testWidgets('a centimeters draft labels warp lengths in cm', (t) async {
    await pumpSheet(t, FakePlanningRepo(), doc: fourEnds().copyWith(unit: MeasureUnit.centimeters));
    expect(find.widgetWithText(TextFormField, 'Finished length (cm)'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Loom waste (cm)'), findsOneWidget);
  });
}
