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
import 'package:ply/src/models/nalbind_recipe.dart';
import 'package:ply/src/models/progress.dart';
import 'package:ply/src/rust/dto.dart';
import 'package:ply/src/rust/knit_dto.dart' show KnitPatternDto;
import 'package:ply/src/rust/progress_dto.dart';
import 'package:ply/src/rust/tablet_dto.dart';
import 'package:ply/src/state/progress_controller.dart';

// Shared stand-ins for the progress tracker host tests (ADR 0023): the engine's work calls, with the
// engine's resume rule mirrored on canned units (its own tests are in Rust), a project folder with a
// sidecar, and a settle that lets real file writes finish between frames.

String fakePrefix(int unit) => unit.toRadixString(16).padLeft(16, '0');

/// The stand-in fingerprint of [unit] on a later time through (the whole pattern before it).
String fakeLaterPrefix(int unit) => (0x7000 + unit).toRadixString(16).padLeft(16, '0');

/// A 32-bit FNV-1a of [text], as a fingerprint's 16 hexadecimal digits (a stand-in that changes
/// when the text does).
String fakeHash(String text) {
  var h = 0x811c9dc5;
  for (final c in text.codeUnits) {
    h = ((h ^ c) * 0x01000193) & 0xffffffff;
  }
  return h.toRadixString(16).padLeft(16, '0');
}

/// The stand-in fingerprint of recipe step [i]: every step up to it, by id, kind, label and notes.
String fakeStepPrefix(NalbindRecipe recipe, int i) => fakeHash([
      for (final s in recipe.segments.take(i + 1)) '${s.id}|${s.kind.name}|${s.title}|${s.notes}',
    ].join('/'));

/// What the stand-in says to turn at a tablet pick.
String fakeTurns(int pick) => pick.isOdd ? 'Every card forward.' : 'Every card backward.';

const _home = TabletArrangementDto(
    nearTop: TabletHoleKind.a,
    farTop: TabletHoleKind.d,
    farBottom: TabletHoleKind.c,
    nearBottom: TabletHoleKind.b);
const _face =
    TabletFaceThreadDto(kind: TabletFaceThreadKind.thread, hole: TabletHoleKind.a, color: 0);

/// The engine's work calls over canned data. Weaving: [picks] picks, pick k pressing treadle
/// `(k - 1) % 4 + 1`, its fingerprint [prefixOf]. Knitting: [knit]. Tablet weaving: [tabletPicks]
/// picks of [tabletCards] cards, forward on odd picks and backward on even ones, every card's twist
/// before time t being `t - 1`, fingerprints [prefixOf]; [tabletErrors] refuses the band as having
/// errors. Nalbinding: [fakeStepPrefix] of the recipe.
class FakeWork extends WorkRepository {
  FakeWork({this.picks = 6, String Function(int pick)? prefixOf, this.knit})
      : prefixOf = prefixOf ?? fakePrefix;

  int picks;
  String Function(int) prefixOf;
  KnitWorkDto? knit;
  int windowCalls = 0;
  int tabletPicks = 6;
  int tabletCards = 2;
  bool tabletErrors = false;

  /// The time through each tablet window was asked for, in order.
  final List<int> tabletTimes = [];

  /// The nalbinding resumes asked for, in order.
  final List<NalbindPlaceDto> nalbindResumes = [];

  static const _hasErrors = TabletRunFailure(
      kind: TabletRunFailureKind.hasErrors,
      message: 'the band cannot be simulated: 1 error(s), the first: Card 1 is wrong.');

  /// The work state each tablet window was given, in order (`null` when none).
  final List<Uint8List?> tabletFroms = [];

  /// The pick each tablet window was resumed from, as the engine would (`null`: worked out from the
  /// start of its time through).
  final List<int?> tabletResumedFrom = [];

  /// The first pick each tablet window was asked for.
  final List<int> tabletFirsts = [];

  @override
  Future<TabletWorkDto> tabletWindow(TabletDocumentDto band, int first, int last, int time,
      {Uint8List? from}) async {
    if (tabletErrors) throw _hasErrors;
    tabletTimes.add(time);
    tabletFroms.add(from);
    tabletFirsts.add(first);
    final n = tabletPicks;
    // A stand-in work state: the time through and the pick it is after. Used, as the engine uses
    // one, when it is of this time and before the window.
    TabletWorkStateDto state(int done) => TabletWorkStateDto(
        done: done, bytes: Uint8List.fromList([time % 256, done >> 8, done % 256]));
    final fromDone =
        from != null && from.length == 3 && from[0] == time % 256 ? from[1] * 256 + from[2] : null;
    final usable = fromDone != null && fromDone < first;
    tabletResumedFrom.add(usable ? fromDone : null);
    if (n == 0) {
      return TabletWorkDto(
          picks: 0,
          cards: tabletCards,
          time: time,
          before: const [],
          steps: const [],
          cells: const [],
          reviewPending: true,
          states: [state(0)]);
    }
    if (first < 1 || first > n || last < first || time < 1) {
      throw const TabletRunFailure(
          kind: TabletRunFailureKind.invalidWindow, message: 'not a window of this band');
    }
    final end = math.min(last, n);
    TabletCardPickDto cell(int pick) => TabletCardPickDto(
          turn: pick.isOdd ? TabletTurnKind.forward : TabletTurnKind.backward,
          released: false,
          flipped: false,
          position: _home,
          threading: TabletThreadingKind.s,
          top: _face,
          back: _face,
          reversal: pick > 1 && pick.isOdd,
          twist: (time - 1) + (pick.isOdd ? 1 : 0),
          woven: time - 1,
        );
    return TabletWorkDto(
      picks: n,
      cards: tabletCards,
      time: time,
      before: [
        for (var c = 0; c < tabletCards; c++)
          TabletCardStateDto(
              position: _home, threading: TabletThreadingKind.s, twist: time - 1, woven: time - 1),
      ],
      steps: [
        for (var k = first; k <= end; k++)
          TabletWorkPickDto(
            pick: k,
            segment: 1,
            step: (k - 1) % 2 + 1,
            segmentRepeat: (k - 1) ~/ 2 + 1,
            segmentRepeats: (n + 1) ~/ 2,
            text: fakeTurns(k),
            allIdle: false,
            weft: k == 1 ? 1 : null,
            noteKind: k == tabletNotePick ? TabletNoteKind.other : null,
            noteText: k == tabletNotePick && !tabletNoteLeftOut(first, k) ? tabletNote : null,
            words: const [],
            textLeftOut: k == tabletNotePick && tabletNoteLeftOut(first, k),
            prefix: time > 1 ? fakeLaterPrefix(k) : prefixOf(k),
          ),
      ],
      cells: [
        for (var k = first; k <= end; k++)
          for (var c = 0; c < tabletCards; c++) cell(k)
      ],
      startNote: time > 1
          ? 'On time $time through the band your cards do not start as they were set up: they '
              'start where time ${time - 1} ended, so what they show here differs from the band '
              'chart.'
          : null,
      reviewPending: true,
      states: [
        if (time > 1 && !usable) state(0),
        for (var k = 8; k >= 1; k--)
          if (first - 1 - 32 * k > (usable ? fromDone : 0)) state(first - 1 - 32 * k),
        if (first - 1 > (usable ? fromDone : 0)) state(first - 1),
        state(end),
      ],
    );
  }

  /// The pick (if any) whose full note the stand-in gives, and the note.
  int? tabletNotePick;
  String tabletNote = '';

  /// As the engine's budget: a later pick's full note is left out when the window starts before it.
  bool tabletNoteLeftOut(int first, int pick) => pick > first && tabletNote.length > 100;

  @override
  Future<WorkResumeDto> tabletResume(TabletDocumentDto band, TabletPlaceDto place) async {
    if (tabletErrors) throw _hasErrors;
    final n = tabletPicks;
    if (n == 0) {
      return const WorkResumeDto(
          status: WorkResumeKind.empty,
          unit: 0,
          row: 1,
          units: 0,
          message: 'This band has no picks to weave.');
    }
    final saved = math.max(place.pick, 1) - 1;
    if (saved >= n) {
      return WorkResumeDto(
          status: WorkResumeKind.clamped,
          unit: n - 1,
          row: 1,
          units: n,
          message: 'Your place was pick ${saved + 1}, but the band now has $n picks. It is shown '
              'at pick $n: check where you are.');
    }
    if (place.prefix == (place.repeat > 1 ? fakeLaterPrefix(saved + 1) : prefixOf(saved + 1))) {
      return WorkResumeDto(
          status: place.picks == n ? WorkResumeKind.same : WorkResumeKind.lengthChanged,
          unit: saved,
          row: 1,
          units: n,
          message: place.picks == n
              ? null
              : 'The band has changed after your place: it now has $n picks (it had '
                  '${place.picks}). Your place is unchanged.');
    }
    return WorkResumeDto(
        status: WorkResumeKind.changed,
        unit: saved,
        row: 1,
        units: n,
        message: 'The band has changed at or before pick ${saved + 1} since you saved your place. '
            'Check that pick ${saved + 1} is where you are and that your cards are as shown.');
  }

  @override
  Future<NalbindWorkDto> nalbindWork(NalbindRecipe recipe,
          {required String projectNotation, required String projectStitchName}) async =>
      NalbindWorkDto(steps: [
        for (final (i, s) in recipe.segments.indexed)
          NalbindWorkStepDto(id: s.id, prefix: fakeStepPrefix(recipe, i)),
      ], stopped: false);

  /// The engine's resume rule, on the stand-in fingerprints.
  @override
  Future<WorkResumeDto> nalbindResume(NalbindRecipe recipe, NalbindPlaceDto place,
      {required String projectNotation, required String projectStitchName}) async {
    nalbindResumes.add(place);
    final n = recipe.segments.length;
    if (n == 0) {
      return const WorkResumeDto(
          status: WorkResumeKind.empty,
          unit: 0,
          row: 1,
          units: 0,
          message: 'This recipe has no steps to work.');
    }
    final at =
        place.stepId == null ? null : recipe.segments.indexWhere((s) => s.id == place.stepId);
    if (at != null && at < 0) {
      final shown = math.min(place.unit, n - 1);
      return WorkResumeDto(
          status: place.unit >= n ? WorkResumeKind.clamped : WorkResumeKind.changed,
          unit: shown,
          row: 1,
          units: n,
          message: 'The step you were on is no longer in the recipe. Your place is shown at step '
              '${shown + 1}: check where you are.');
    }
    final unit = at ?? place.unit;
    if (unit >= n) {
      return WorkResumeDto(
          status: WorkResumeKind.clamped,
          unit: n - 1,
          row: 1,
          units: n,
          message: 'Your place was past the end of the recipe.');
    }
    if (place.prefix == fakeStepPrefix(recipe, unit)) {
      return WorkResumeDto(
          status: place.units == n ? WorkResumeKind.same : WorkResumeKind.lengthChanged,
          unit: unit,
          row: 1,
          units: n,
          message: place.units == n
              ? null
              : 'The recipe has changed after your place: it now has $n steps (it had '
                  '${place.units}). Your place is unchanged.');
    }
    return WorkResumeDto(
        status: WorkResumeKind.changed,
        unit: unit,
        row: 1,
        units: n,
        message: unit != place.unit
            ? 'The recipe has changed since you saved your place: the step you were on is now '
                'step ${unit + 1} (it was step ${place.unit + 1}). Check that it is where you are.'
            : 'The recipe has changed at or before step ${unit + 1} since you saved your place. '
                'Check that step ${unit + 1} is where you are.');
  }

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
          prefix: time > 1 ? fakeLaterPrefix(k) : prefixOf(k),
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
    if (place.prefix == (place.repeat > 1 ? fakeLaterPrefix(saved + 1) : prefixOf(saved + 1))) {
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
    final saved = place.repeat > 1 ? units[place.unit].laterPrefix : units[place.unit].prefix;
    if (place.prefix == saved && rowNote != null) {
      return WorkResumeDto(
          status: WorkResumeKind.changed,
          unit: place.unit,
          row: row,
          units: units.length,
          message: rowNote);
    }
    if (place.prefix == saved) {
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

/// Progress records held in memory, for screens tested under the fake clock with `pumpAndSettle`
/// (a real file write needs real time). Same rules as the file: [newer] or [unreadable] records
/// are never replaced.
class MemoryProgressRepository extends ProgressRepository {
  MemoryProgressRepository();

  final Map<(BackupCraft, String), Progress> records = {};
  final Map<(BackupCraft, String), ProgressStatus> problems = {};
  int saves = 0;

  @override
  Future<ProgressLoad> load(BackupCraft craft, String id) async {
    final problem = problems[(craft, id)];
    if (problem != null) return ProgressLoad(problem);
    final p = records[(craft, id)];
    return p == null ? const ProgressLoad(ProgressStatus.none) : ProgressLoad(ProgressStatus.ok, p);
  }

  @override
  Future<Progress> save(BackupCraft craft, String id, Progress progress,
      {ProgressSaveGuard? guard}) async {
    if (problems[(craft, id)] == ProgressStatus.newer) {
      throw const ProgressFileException(ProgressProblem.newerVersion);
    }
    if (problems[(craft, id)] == ProgressStatus.unreadable) {
      throw const ProgressFileException(ProgressProblem.unreadable);
    }
    if (problems[(craft, id)] == ProgressStatus.failed) {
      throw const ProgressFileException(ProgressProblem.saveCheckFailed);
    }
    if ((guard?.expectNoRecord ?? false) && records.containsKey((craft, id))) {
      throw const ProgressFileException(ProgressProblem.foundAgain);
    }
    saves++;
    guard?.expectNoRecord = false;
    final fitted = progress.encodeFitted().progress;
    records[(craft, id)] = fitted;
    return fitted;
  }

  @override
  Future<void> setAside(BackupCraft craft, String id, {bool evenIfNotRead = false}) async {
    if (problems[(craft, id)] == ProgressStatus.failed) {
      if (!evenIfNotRead) throw const ProgressFileException(ProgressProblem.ioFailed);
      problems.remove((craft, id));
      records.remove((craft, id));
      return;
    }
    if (problems[(craft, id)] == ProgressStatus.unreadable) problems.remove((craft, id));
  }

  @override
  Future<void> delete(BackupCraft craft, String id) async => records.remove((craft, id));
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
