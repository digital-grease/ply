import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:ply/src/data/library_backup.dart' show BackupCraft;
import 'package:ply/src/data/progress_repository.dart';
import 'package:ply/src/data/work_repository.dart';
import 'package:ply/src/rust/dto.dart';
import 'package:ply/src/rust/knit_dto.dart' show KnitPatternDto;
import 'package:ply/src/rust/progress_dto.dart';
import 'package:ply/src/state/progress_controller.dart';

// Shared stand-ins for the progress tracker host tests (ADR 0023): the engine's work calls, with the
// engine's resume rule mirrored on canned units (its own tests are in Rust), a project folder with a
// sidecar, and a settle that lets real file writes finish between frames.

String fakePrefix(int unit) => unit.toRadixString(16).padLeft(16, '0');

/// The engine's work calls over canned data. Weaving: [picks] picks, pick k pressing treadle
/// `(k - 1) % 4 + 1`, its fingerprint [prefixOf]. Knitting: [knit].
class FakeWork extends WorkRepository {
  FakeWork({this.picks = 6, String Function(int pick)? prefixOf, this.knit})
      : prefixOf = prefixOf ?? fakePrefix;

  int picks;
  String Function(int) prefixOf;
  KnitWorkDto? knit;
  int windowCalls = 0;

  /// The time through each window was asked for, in order.
  final List<int> windowTimes = [];

  static String actionOf(int pick) {
    final t = (pick - 1) % 4 + 1;
    return 'Press treadle $t: shafts $t and ${t % 4 + 1} rise.';
  }

  @override
  Future<WeaveWorkDto> weaveWindow(DraftDto draft, int first, int last, int time) async {
    windowCalls++;
    windowTimes.add(time);
    if (picks == 0) return const WeaveWorkDto(picks: 0, treadled: true, steps: []);
    if (first < 1 || first > picks || last < first || time < 1) {
      throw 'picks $first to $last are not here';
    }
    return WeaveWorkDto(picks: picks, treadled: true, steps: [
      for (var k = first; k <= math.min(last, picks); k++)
        WeaveWorkPickDto(
          pick: k,
          treadles: Uint16List.fromList([(k - 1) % 4 + 1]),
          raised: Uint16List.fromList([(k - 1) % 4 + 1, (k - 1) % 4 + 1 == 4 ? 1 : k % 4 + 1]),
          action: actionOf(k),
          weftIndex: 0,
          weft: const ColorDto(r: 20, g: 40, b: 200),
          role: PickRoleKind.unknown,
          // The engine's words for a shuttle that changes sides every second time through.
          notes: [
            if (k == 2) 'A tabby pick.',
            if (k == 1) 'Shuttle 1, from the ${time.isEven ? 'right' : 'left'}.',
          ],
          prefix: prefixOf(k),
        ),
    ]);
  }

  @override
  Future<WorkResumeDto> weaveResume(DraftDto draft, WeavePlaceDto place) async {
    if (picks == 0) {
      return const WorkResumeDto(
          status: WorkResumeKind.empty,
          unit: 0,
          row: 1,
          units: 0,
          message: 'This draft has no picks to weave.');
    }
    final saved = math.max(place.pick, 1) - 1;
    if (saved >= picks) {
      return WorkResumeDto(
          status: WorkResumeKind.clamped,
          unit: picks - 1,
          row: 1,
          units: picks,
          message: 'Your place was pick ${saved + 1}, but the draft now has $picks picks. It is '
              'shown at pick $picks: check where you are.');
    }
    if (place.prefix == prefixOf(saved + 1)) {
      return WorkResumeDto(
          status: place.picks == picks ? WorkResumeKind.same : WorkResumeKind.lengthChanged,
          unit: saved,
          row: 1,
          units: picks,
          message: place.picks == picks
              ? null
              : 'The draft has changed after your place: it now has $picks picks (it had '
                  '${place.picks}). Your place is unchanged.');
    }
    return WorkResumeDto(
        status: WorkResumeKind.changed,
        unit: saved,
        row: 1,
        units: picks,
        message: 'The draft has changed at or before pick ${saved + 1} since you saved your place. '
            'Check that pick ${saved + 1} is where you are.');
  }

  @override
  Future<KnitWorkDto> knitWork(KnitPatternDto pattern) async => knit!;

  @override
  Future<WorkResumeDto> knitResume(KnitPatternDto pattern, KnitPlaceDto place) async {
    final units = knit!.units;
    if (units.isEmpty) {
      return const WorkResumeDto(
          status: WorkResumeKind.empty,
          unit: 0,
          row: 1,
          units: 0,
          message: 'This pattern has no rows or steps to knit yet.');
    }
    int? find() {
      if (place.sectionId == null) return null;
      final i = units.indexWhere((u) =>
          u.sectionId == place.sectionId &&
          u.stepId == place.stepId &&
          (u.section == null ? null : u.chartRow) == place.chartRow);
      return i < 0 ? null : i;
    }

    if (place.unit >= units.length) {
      return WorkResumeDto(
          status: WorkResumeKind.clamped,
          unit: units.length - 1,
          row: units.last.rows,
          units: units.length,
          message: 'Your place was past the end of the pattern as it is now.');
    }
    final rows = units[place.unit].rows;
    final row = math.min(math.max(place.row, 1), rows);
    // A row past the step's rows: shown at its last row, for checking (the engine escalates it).
    final rowNote = place.row > rows
        ? 'Your place was row ${place.row} of this step, but the step now works $rows '
            '${rows == 1 ? 'row' : 'rows'}. It is shown at row $rows: check where you are.'
        : null;
    if (place.prefix == units[place.unit].prefix && rowNote != null) {
      return WorkResumeDto(
          status: WorkResumeKind.changed,
          unit: place.unit,
          row: row,
          units: units.length,
          message: rowNote);
    }
    if (place.prefix == units[place.unit].prefix) {
      return WorkResumeDto(
          status: place.units == units.length ? WorkResumeKind.same : WorkResumeKind.lengthChanged,
          unit: place.unit,
          row: row,
          units: units.length,
          message: place.units == units.length
              ? null
              : 'The pattern has changed after your place. Your place is unchanged.');
    }
    final found = find();
    return WorkResumeDto(
        status: WorkResumeKind.changed,
        unit: place.unit,
        row: row,
        units: units.length,
        suggestedUnit: found == place.unit ? null : found,
        message: 'The pattern has changed at or before this step since you saved your place. '
            'Check that this is where you are.${found != null && found != place.unit ? ' The step '
                'you were on is somewhere else in the pattern now.' : ''}'
            '${rowNote == null ? '' : ' $rowNote'}');
  }
}

/// A docs folder holding one saved project of [craft] (its sidecar), for [id].
Future<Directory> projectFolder(BackupCraft craft, String id) async {
  final docs = await Directory.systemTemp.createTemp('ply_tracker');
  final dir = Directory(p.join(docs.path, craft.directory))..createSync();
  File(p.join(dir.path, '$id.json')).writeAsStringSync(
      '{"name":"Test","craft":"${craft.label}","savedAt":"2026-11-18T10:00:00.000Z",'
      '"lastOpened":"2026-11-18T10:00:00.000Z"}');
  return docs;
}

/// The overrides a tracker under test runs with: its record over [docs], the [work] stand-in, and a
/// clock that moves on a minute each time it is read.
List<Override> trackerOverrides(Directory docs, FakeWork work) {
  var minutes = 0;
  return [
    progressRepositoryProvider.overrideWithValue(ProgressRepository(docsOverride: docs)),
    workRepositoryProvider.overrideWithValue(work),
    progressClockProvider
        .overrideWithValue(() => DateTime.utc(2026, 11, 18, 10).add(Duration(minutes: minutes++))),
  ];
}

/// Let real file reads and writes finish between frames.
Future<void> settle(WidgetTester tester, {int rounds = 30}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    // Fake time moves on too, so menus, dialogs and sheets finish opening and closing.
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Pump [screen] under [overrides] on a tall phone screen and let it load.
Future<void> pumpTracker(WidgetTester tester, Widget screen, List<Override> overrides) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 2.6;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    overrides: overrides,
    child: MaterialApp(home: screen),
  ));
  await settle(tester);
}

/// Tap [finder] and let the write it starts finish.
Future<void> tapAndSettle(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await settle(tester);
}
