import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:ply/src/data/draft_repository.dart';
import 'package:ply/src/data/knit_repository.dart';
import 'package:ply/src/data/library_backup.dart' show BackupCraft;
import 'package:ply/src/data/library_places.dart';
import 'package:ply/src/data/progress_repository.dart';
import 'package:ply/src/data/sidecar_writes.dart';
import 'package:ply/src/data/tablet_repository.dart';
import 'package:ply/src/data/work_repository.dart';
import 'package:ply/src/models/draft_doc.dart';
import 'package:ply/src/models/draft_issue.dart';
import 'package:ply/src/models/draft_meta.dart';
import 'package:ply/src/models/knit_entry.dart';
import 'package:ply/src/models/knit_stitches.dart';
import 'package:ply/src/models/nalbind_project.dart';
import 'package:ply/src/models/nalbind_recipe.dart';
import 'package:ply/src/models/progress.dart';
import 'package:ply/src/rust/dto.dart' show ColorDto, UnitKind;
import 'package:ply/src/rust/knit_dto.dart';
import 'package:ply/src/rust/progress_dto.dart' show KnitWorkDto, KnitWorkModeKind, KnitWorkUnitDto;
import 'package:ply/src/screens/editor_screen.dart';
import 'package:ply/src/screens/home_screen.dart';
import 'package:ply/src/screens/knit_editor_screen.dart';
import 'package:ply/src/screens/knit_library_screen.dart';
import 'package:ply/src/screens/knit_tracker_screen.dart';
import 'package:ply/src/screens/library_screen.dart';
import 'package:ply/src/screens/nalbind_follow_screen.dart';
import 'package:ply/src/screens/nalbind_project_screen.dart';
import 'package:ply/src/screens/nalbind_reference_screen.dart';
import 'package:ply/src/screens/tablet_editor_screen.dart';
import 'package:ply/src/screens/tablet_library_screen.dart';
import 'package:ply/src/screens/tablet_tracker_screen.dart';
import 'package:ply/src/screens/weave_tracker_screen.dart';
import 'package:ply/src/state/backup_providers.dart' show libraryRevisionProvider;
import 'package:ply/src/state/editor_providers.dart';
import 'package:ply/src/state/knit_editor_providers.dart';
import 'package:ply/src/state/library_place_providers.dart';
import 'package:ply/src/state/nalbind_providers.dart';
import 'package:ply/src/state/progress_controller.dart';
import 'package:ply/src/state/tablet_editor_providers.dart';
import 'package:ply/src/widgets/library_place.dart';

import 'nalbind_recipe_test_support.dart';
import 'pick_roles_support.dart';
import 'progress_test_support.dart';
import 'tablet_test_support.dart';

// Each library tile's saved place (ADR 0023, amendment of 2026-11-19) on the host. The reader: a
// place as the record states it for every craft, a short line for a record a newer Ply wrote or one
// that cannot be read (never a place, and nothing on disk changed), a large record read on a
// background isolate with the same result as the tracker's read, a record being written read once
// the write lands, and no failure ever. The tiles: each craft's library shows the place, nothing
// without one, and the line for a newer or unreadable record; the place, and the tile's menu, open
// the project straight into its tracker through its editor, exactly as the editor's menu does, and
// back from the tracker is the editor; the place is read again after tracking, renaming, deleting
// and restoring. A knitting tile says the place in the tracker's own words when the record keeps
// them for that place (its label, follow-up 6), and its own words otherwise.

/// The record's last change and the clock the tiles read, in the device's time zone.
final DateTime _earlier = DateTime(2026, 11, 18, 9);
final DateTime _now = DateTime(2026, 11, 18, 17);

const _ok = 'aa000000-1111-4222-8333-944455556601';
const _none = 'aa000000-1111-4222-8333-944455556602';
const _newer = 'aa000000-1111-4222-8333-944455556603';
const _bad = 'aa000000-1111-4222-8333-944455556604';
const _labelled = 'aa000000-1111-4222-8333-944455556605';
const _oldLabel = 'aa000000-1111-4222-8333-944455556606';
const _brokenLabel = 'aa000000-1111-4222-8333-944455556607';

Future<Directory> _library() async {
  final docs = await Directory.systemTemp.createTemp('ply_library_place');
  for (final c in BackupCraft.values) {
    Directory(p.join(docs.path, c.directory)).createSync();
  }
  return docs;
}

File _recordFile(Directory docs, BackupCraft craft, String id) =>
    File(p.join(docs.path, craft.directory, '$id.plyprogress'));

/// The project's sidecar, which a tracker's write checks for.
void _sidecar(Directory docs, BackupCraft craft, String id) =>
    File(p.join(docs.path, craft.directory, '$id.json'))
        .writeAsStringSync('{"name":"$id","craft":"${craft.label}"}');

void _write(Directory docs, BackupCraft craft, String id, Progress progress) =>
    _recordFile(docs, craft, id).writeAsStringSync(progress.encodeFitted().text);

void _writeText(Directory docs, BackupCraft craft, String id, String text) =>
    _recordFile(docs, craft, id).writeAsStringSync(text);

Progress _at(ProgressCraft craft, WorkPlace place, {required int units, required String prefix}) =>
    Progress(
      craft: craft,
      place: place,
      basis: PlaceBasis(units: units, prefix: prefix),
      started: _earlier.toUtc(),
      updated: _earlier.toUtc(),
    );

String _newerText(ProgressCraft craft) =>
    '{"format":"ply.progress","schemaVersion":2,"craft":"${craft.key}","place":{"x":1}}';

const _unreadableText = '{"format":"ply.progress","schemaVersion":1,"craft":';

/// What every file under [docs] holds, to show nothing was written, moved or set aside.
Map<String, String> _snapshot(Directory docs) => {
      for (final f in docs.listSync(recursive: true).whereType<File>())
        p.relative(f.path, from: docs.path): base64.encode(f.readAsBytesSync()),
    };

Finder _line(String id) => find.byKey(ValueKey('library-place-$id'));

Finder _lineText(String id, String text) =>
    find.descendant(of: _line(id), matching: find.text(text));

Finder _trackerPlace(String text) => find.descendant(
    of: find.byKey(const ValueKey('tracker-place')), matching: find.text(text), matchRoot: true);

/// The overrides of every tile test: the records over [docs], the engine's work stood in, a fixed
/// clock.
List<Override> _overrides(Directory docs, FakeWork work) => [
      progressRepositoryProvider.overrideWithValue(ProgressRepository(docsOverride: docs)),
      workRepositoryProvider.overrideWithValue(work),
      progressClockProvider.overrideWithValue(() => _now),
    ];

Future<ProviderContainer> _pump(WidgetTester tester, Widget home, List<Override> overrides) async {
  tester.view.physicalSize = const Size(1200, 2600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final c = ProviderContainer(overrides: overrides);
  addTearDown(c.dispose);
  await tester.pumpWidget(UncontrolledProviderScope(container: c, child: MaterialApp(home: home)));
  await settle(tester);
  return c;
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await settle(tester);
}

Future<void> _back(WidgetTester tester) async {
  await tester.pageBack();
  await settle(tester);
}

/// Rename the tile [name] to [to] through its menu.
Future<void> _rename(WidgetTester tester, String tooltip, String to) async {
  await _tap(tester, find.byTooltip(tooltip).first);
  await _tap(tester, find.text('Rename'));
  await tester.enterText(find.byType(TextField), to);
  await _tap(tester, find.widgetWithText(FilledButton, 'Rename'));
}

/// Delete the tile at [index] through its menu and the confirm dialog.
Future<void> _delete(WidgetTester tester, String tooltip, int index) async {
  await _tap(tester, find.byTooltip(tooltip).at(index));
  await _tap(tester, find.text('Delete'));
  await _tap(tester, find.widgetWithText(FilledButton, 'Delete'));
}

// --- weaving ------------------------------------------------------------------------------------

class _Drafts extends DraftRepository {
  _Drafts(this.docs, List<String> ids)
      : entries = [
          for (final id in ids)
            DraftEntry(
              id: id,
              wifPath: p.join(docs.path, 'drafts', '$id.wif'),
              meta: DraftMeta(name: 'Draft $id', savedAt: _earlier, lastOpened: _earlier),
            ),
        ];

  final Directory docs;
  List<DraftEntry> entries;

  @override
  Future<List<DraftEntry>> list() async => entries;

  @override
  Future<DraftEntry> open(String id) async => entries.firstWhere((e) => e.id == id);

  @override
  Future<String> readWif(String id) async => 'a stand-in for the WIF';

  @override
  Future<DraftDoc> parseDoc(String wifText) async => generatedOvershot(picks: 6);

  @override
  Future<List<DraftIssue>> validateDto(DraftDoc doc) async => const [];

  @override
  Future<ui.Image> renderDto(DraftDoc doc,
          {required int cellPx,
          bool gridlines = false,
          int floatThreshold = 0,
          bool threadTexture = false}) =>
      onePixelImage();

  @override
  Future<void> rebuildThumbnail(String id) async {}

  @override
  Future<bool?> hasCloth(String id) async => false;

  @override
  Future<void> rename(String id, String newName) async => entries = [
        for (final e in entries)
          e.id == id
              ? DraftEntry(id: e.id, wifPath: e.wifPath, meta: e.meta.copyWith(name: newName))
              : e,
      ];

  /// As the real delete: the project, then its progress files.
  @override
  Future<void> delete(String id) async {
    entries = entries.where((e) => e.id != id).toList();
    await ProgressRepository.deleteFilesIn(p.join(docs.path, 'drafts'), id);
  }
}

Progress _weave(int pick, {int repeat = 1}) =>
    _at(ProgressCraft.weaving, PickPlace(pick, repeat: repeat),
        units: 6, prefix: repeat > 1 ? fakeLaterPrefix(pick) : fakePrefix(pick));

List<Override> _weaveOverrides(Directory docs, _Drafts drafts, FakeWork work) =>
    [repositoryProvider.overrideWithValue(drafts), ..._overrides(docs, work)];

// --- knitting -----------------------------------------------------------------------------------

KnitPatternDto _knitPattern() => KnitPatternDto(
      name: 'Cowl',
      construction: ConstructionKind.flat,
      firstRowSide: SideKind.rs,
      gauge: const GaugeDto(sts: 18, rows: 24, unit: UnitKind.inches),
      palette: const [ColorDto(r: 255, g: 255, b: 255)],
      legend: const StitchLegendDto(stitches: []),
      chart: ChartDto(
        width: 4,
        rows: List.generate(
          3,
          (_) => RowDto(
            cells: List.generate(4, (_) => const CellDto(stitch: KnitStitch.knit)),
            repeats: const [],
          ),
        ),
      ),
      notes: '',
      sections: const [],
      pieces: const [],
    );

/// The engine's work for [_knitPattern]: three chart rows.
KnitWorkDto _knitWork() => KnitWorkDto(
      mode: KnitWorkModeKind.chart,
      round: false,
      headings: const [],
      sectionNotes: const [],
      units: [
        for (var r = 0; r < 3; r++)
          KnitWorkUnitDto(
            chartRow: r + 1,
            label: 'Row ${r + 1} (${r.isEven ? 'RS' : 'WS'})',
            text: r.isEven ? 'k4' : 'p4',
            count: '4 sts',
            rows: 1,
            opaque: false,
            prefix: fakePrefix(r + 1),
            laterPrefix: fakeLaterPrefix(r + 1),
          ),
      ],
      stopped: false,
    );

class _Knits extends KnitRepository {
  _Knits(this.docs, List<String> ids)
      : entries = [
          for (final id in ids)
            KnitEntry(
              id: id,
              patternPath: p.join(docs.path, 'knits', '$id.plyknit'),
              meta: DraftMeta(
                  name: 'Pattern $id', craft: 'Knitting', savedAt: _earlier, lastOpened: _earlier),
            ),
        ];

  final Directory docs;
  List<KnitEntry> entries;

  @override
  Future<List<KnitEntry>> listKnits() async => entries;

  @override
  Future<KnitPatternDto> readPattern(String id) async => _knitPattern();

  @override
  Future<KnitEntry> openKnit(String id) async => entries.firstWhere((e) => e.id == id);

  @override
  Future<ui.Image> render(KnitPatternDto pattern, {required int cellPx}) => onePixelImage();

  @override
  Future<List<KnitIssueDto>> validate(KnitPatternDto pattern) async => const [];

  @override
  Future<void> renameKnit(String id, String newName) async => entries = [
        for (final e in entries)
          e.id == id
              ? KnitEntry(
                  id: e.id, patternPath: e.patternPath, meta: e.meta.copyWith(name: newName))
              : e,
      ];

  @override
  Future<void> deleteKnit(String id) async {
    entries = entries.where((e) => e.id != id).toList();
    await ProgressRepository.deleteFilesIn(p.join(docs.path, 'knits'), id);
  }
}

Progress _knit(int unit) =>
    _at(ProgressCraft.knitting, KnitPlace(unit), units: 3, prefix: fakePrefix(unit + 1));

/// The engine's work for a pattern in sections: a cast-on step, six rows of rib, and a bind-off.
KnitWorkDto _knitSections() => KnitWorkDto(
      mode: KnitWorkModeKind.sections,
      round: false,
      headings: const ['Section 1: Cuff', 'Section 2: Finish'],
      sectionNotes: const [null, null],
      units: [
        for (final (i, section, step, rows) in [(0, 0, 0, 1), (1, 0, 1, 6), (2, 1, 0, 1)])
          KnitWorkUnitDto(
            section: section,
            step: step,
            sectionId: 'section-${section + 1}',
            stepId: 'step-${i + 1}',
            label: rows > 1 ? 'Next $rows rows (first row RS)' : null,
            text: 'Step ${i + 1} of the pattern.',
            count: '20 sts',
            rows: rows,
            opaque: false,
            prefix: fakePrefix(i + 1),
            laterPrefix: fakePrefix(i + 1),
          ),
      ],
      stopped: false,
    );

/// A knitting record at [place] (in sections) whose file holds [label] as its label, as given.
String _knitWithLabel(KnitPlace place, Map<String, Object?>? label,
        {int units = 120, String pad = ''}) =>
    jsonEncode({
      ...jsonDecode(_at(ProgressCraft.knitting, place, units: units, prefix: fakePrefix(1))
          .encodeFitted()
          .text) as Map<String, dynamic>,
      if (label != null) 'label': label,
      if (pad.isNotEmpty) 'later': pad,
    });

const _cuffRow3 = KnitPlace(13, row: 3, sectionId: 'section-1', stepId: 'step-4');
const _cuffWords = 'Section 1: Cuff, step 2, row 3';

/// A label as a file holds it: [text] for [at], stamped with [updated] (the last change of a record
/// [_at] makes, unless given).
Map<String, Object?> _label(Object? text, {KnitPlace at = _cuffRow3, String? updated}) =>
    {'text': text, 'place': at.toJson(), 'updated': updated ?? _earlier.toUtc().toIso8601String()};

/// Labels a tile never shows, as a file may hold them: kept by a build from before the label while
/// it moved the place (the words of another place), or while it moved away and back or changed a
/// note (another last change), and one not well formed.
final Map<String, Map<String, Object?>> _oldLabels = {
  'another place': _label('Section 1: Cuff, step 1',
      at: const KnitPlace(12, sectionId: 'section-1', stepId: 'step-3')),
  'another last change':
      _label('Section 1: Ribbing, step 2, row 3', updated: '2026-11-18T23:00:00.000Z'),
  'not well formed': _label(7),
  'half of a symbol': _label('Section 1: Cuff \ud83e'),
};

// --- tablet weaving -----------------------------------------------------------------------------

class _Bands extends FakeTabletRepo {
  _Bands(this.docs, Oracle band, List<String> ids)
      : entries = [
          for (final id in ids)
            TabletEntry(
              id: id,
              bandPath: p.join(docs.path, 'tablets', '$id.plytab'),
              meta: DraftMeta(
                  name: 'Band $id', craft: kTabletCraft, savedAt: _earlier, lastOpened: _earlier),
            ),
        ],
        super(oracle: band, stored: band.doc);

  final Directory docs;
  List<TabletEntry> entries;

  @override
  Future<List<TabletEntry>> listBands() async => entries;

  @override
  Future<void> rebuildThumbnail(String id) async {}

  @override
  Future<bool?> hasSomethingToDraw(String id) async => false;

  @override
  Future<void> renameBand(String id, String newName) async => entries = [
        for (final e in entries)
          e.id == id
              ? TabletEntry(id: e.id, bandPath: e.bandPath, meta: e.meta.copyWith(name: newName))
              : e,
      ];

  @override
  Future<void> deleteBand(String id) async {
    entries = entries.where((e) => e.id != id).toList();
    await ProgressRepository.deleteFilesIn(p.join(docs.path, 'tablets'), id);
  }
}

Progress _band(int pick) =>
    _at(ProgressCraft.tabletWeaving, PickPlace(pick), units: 6, prefix: fakePrefix(pick));

// --- nalbinding ---------------------------------------------------------------------------------

const _recipe = NalbindRecipe(segments: [
  RecipeSegment(id: 'segment-1', kind: SegmentKind.centreStart, title: 'Crown', stitches: 8),
  RecipeSegment(
      id: 'segment-2', kind: SegmentKind.rounds, title: 'Sides', extent: Extent.rounds(10)),
  RecipeSegment(
      id: 'segment-3',
      kind: SegmentKind.finish,
      title: 'Brim edge',
      finishMethod: FinishMethod.taperEdge),
], lastSegmentNumber: 3);

class _Nalbinds extends RecipeFakeRepo {
  _Nalbinds(this.docs, List<String> ids)
      : super(projects: {
          for (final id in ids)
            id: NalbindProject(
                name: 'Hat $id', notation: 'UO/UOO F1', stitchName: 'Oslo', recipe: _recipe),
        });

  final Directory docs;

  @override
  Future<List<NalbindProjectEntry>> listProjects() async => [
        for (final e in projects.entries)
          NalbindProjectEntry(id: e.key, name: e.value.name, lastOpened: _earlier),
      ];

  @override
  Future<void> deleteProject(String id) async {
    projects.remove(id);
    await ProgressRepository.deleteFilesIn(p.join(docs.path, 'nalbinds'), id);
  }
}

Progress _step(int unit) =>
    _at(ProgressCraft.nalbinding, NalbindPlace(unit, stepId: _recipe.segments[unit].id),
        units: 3, prefix: fakeStepPrefix(_recipe, unit));

List<Override> _nalbindOverrides(Directory docs, _Nalbinds repo, FakeWork work) =>
    [nalbindRepositoryProvider.overrideWithValue(repo), ..._overrides(docs, work)];

const Widget _nalbindTab = Scaffold(body: NalbindReferenceScreen());

/// A large record (past the inline size): read on the background isolate.
Progress _big(int pick) => Progress(
      craft: ProgressCraft.weaving,
      place: PickPlace(pick),
      basis: PlaceBasis(units: 6, prefix: fakePrefix(pick)),
      extra: {'later': 'y' * (kInlinePlaceBytes + 1000)},
    );

/// Make [f] unreadable to this process; false when it can still read it (a process that reads
/// any file).
bool _lockOut(File f) {
  Process.runSync('chmod', ['000', f.path]);
  addTearDown(() => _letIn(f));
  try {
    f.readAsBytesSync();
    return false;
  } on FileSystemException {
    return true;
  }
}

void _letIn(File f) => Process.runSync('chmod', ['644', f.path]);

/// The names of the files under [docs].
Set<String> _names(Directory docs) => {
      for (final f in docs.listSync(recursive: true).whereType<File>())
        p.relative(f.path, from: docs.path),
    };

void main() {
  late Directory docs;
  late FakeWork work;
  late Oracle band1;
  setUpAll(() => band1 = Oracle('band-1-threaded-in'));
  setUp(() async {
    docs = await _library();
    work = FakeWork(picks: 6)..knit = _knitWork();
  });
  tearDown(() => docs.delete(recursive: true));

  group('the reader', () {
    late ProgressRepository repo;
    setUp(() => repo = ProgressRepository(docsOverride: docs));

    test('a place as its record states it, for every craft; none without a record or a place',
        () async {
      final cases = <(BackupCraft, Progress)>[
        (
          BackupCraft.weaving,
          _at(ProgressCraft.weaving, const PickPlace(49, repeat: 2),
              units: 96, prefix: fakePrefix(1))
        ),
        (
          BackupCraft.knitting,
          _at(ProgressCraft.knitting,
              const KnitPlace(13, row: 3, sectionId: 'section-1', stepId: 'step-4'),
              units: 120, prefix: fakePrefix(1))
        ),
        (
          BackupCraft.tabletWeaving,
          _at(ProgressCraft.tabletWeaving, const PickPlace(12), units: 40, prefix: fakePrefix(1))
        ),
        (
          BackupCraft.nalbinding,
          _at(ProgressCraft.nalbinding, const NalbindPlace(2, stepId: 'segment-3'),
              units: 12, prefix: fakePrefix(1))
        ),
      ];
      for (final (craft, record) in cases) {
        _write(docs, craft, _ok, record);
        // A record with notes but no place yet: the tracker starts at the first unit.
        _write(
            docs,
            craft,
            'notes-only',
            Progress(craft: record.craft)
                .withNote(record.place!, 'Started the second ball.', now: _earlier));
        final places = await readLibraryPlaces(repo, craft, [_ok, _none, 'notes-only']);
        expect(places.keys, [_ok], reason: '$craft');
        expect(
            places[_ok],
            LibraryPlace.read(
                place: record.place!, units: record.basis!.units, updated: _earlier.toUtc()));
      }
    });

    test('newer, unreadable and past the bound: a short line, never a place, nothing changed',
        () async {
      const craft = BackupCraft.weaving;
      _writeText(docs, craft, 'newer', _newerText(ProgressCraft.weaving));
      // Too large to decode, yet its first bytes say a newer Ply wrote it.
      _writeText(docs, craft, 'newer-large',
          '{"format":"ply.progress","schemaVersion":7,"pad":"${'x' * (600 * 1024)}"}');
      _writeText(
          docs,
          craft,
          'large',
          '{"format":"ply.progress","schemaVersion":1,'
              '"pad":"${'x' * (600 * 1024)}"}');
      _writeText(docs, craft, 'bad-json', _unreadableText);
      _recordFile(docs, craft, 'not-utf8').writeAsBytesSync([0x7b, 0xff, 0xfe, 0x7d]);
      _writeText(docs, craft, 'other-craft',
          _weave(2).encodeFitted().text.replaceFirst('"weaving"', '"knitting"'));
      _writeText(
          docs,
          craft,
          'deep',
          '{"format":"ply.progress","schemaVersion":1,'
              '"craft":"weaving","x":${'[' * 70}${']' * 70}}');
      _writeText(
          docs,
          craft,
          'huge-number',
          '{"format":"ply.progress","schemaVersion":1,'
              '"craft":"weaving","x":1e400}');
      // More values than any record Ply writes, over the inline size: read in the background.
      _writeText(
          docs,
          craft,
          'many-values',
          '{"format":"ply.progress","schemaVersion":1,'
              '"craft":"weaving","x":[${List.filled(100001, '0').join(',')}]}');
      _writeText(
          docs,
          craft,
          'two-versions',
          '{"format":"ply.progress","schemaVersion":1,'
              '"schemaVersion":2,"craft":"weaving"}');
      final before = _snapshot(docs);
      final places = await readLibraryPlaces(repo, craft, [
        'newer',
        'newer-large',
        'large',
        'bad-json',
        'not-utf8',
        'other-craft',
        'deep',
        'huge-number',
        'many-values',
        'two-versions',
      ]);
      expect(places['newer'], const LibraryPlace.newer());
      expect(places['newer-large'], const LibraryPlace.newer());
      for (final id in [
        'large',
        'bad-json',
        'not-utf8',
        'other-craft',
        'deep',
        'huge-number',
        'many-values',
        'two-versions'
      ]) {
        expect(places[id], const LibraryPlace.unreadable(), reason: id);
      }
      expect(_snapshot(docs), before, reason: 'nothing written, moved or set aside');
    });

    test('agrees with the tracker\'s own read on every kind of record, large ones included',
        () async {
      const craft = BackupCraft.weaving;
      final large = Progress(
        craft: ProgressCraft.weaving,
        place: const PickPlace(7, repeat: 3),
        basis: PlaceBasis(units: 20, prefix: fakePrefix(7)),
        updated: _earlier.toUtc(),
        // Keys a later build added within version 1: kept and read past.
        extra: {'later': 'y' * (kInlinePlaceBytes + 1000)},
      );
      _write(docs, craft, 'large-ok', large);
      expect(_recordFile(docs, craft, 'large-ok').lengthSync(), greaterThan(kInlinePlaceBytes),
          reason: 'read on the background isolate');
      _write(docs, craft, 'small-ok', _weave(3));
      _writeText(docs, craft, 'newer', _newerText(ProgressCraft.weaving));
      _writeText(docs, craft, 'bad', _unreadableText);
      _writeText(
          docs,
          craft,
          'bad-large',
          '{"format":"ply.progress","schemaVersion":1,'
              '"craft":"weaving","x":"${'z' * (kInlinePlaceBytes + 10)}"}');
      final ids = ['large-ok', 'small-ok', 'newer', 'bad', 'bad-large', 'missing'];
      final places = await readLibraryPlaces(repo, craft, ids);
      for (final id in ids) {
        final tracker = LibraryPlace.fromLoad(await repo.load(craft, id));
        expect(places[id], tracker, reason: id);
        final sync = ProgressRepository.readFileSync(
            _recordFile(docs, craft, id).path, ProgressCraft.weaving);
        expect(sync.status, (await repo.load(craft, id)).status,
            reason: '$id, read as on the background isolate');
        expect(LibraryPlace.fromLoad(sync), tracker, reason: id);
      }
      expect(
          places['large-ok'],
          LibraryPlace.read(
              place: const PickPlace(7, repeat: 3), units: 20, updated: _earlier.toUtc()));
    });

    test('a record being written is read once the write lands', () async {
      const craft = BackupCraft.weaving;
      for (final id in ['small', 'large']) {
        _sidecar(docs, craft, id);
      }
      // A large record already there: the listing reads it on the background isolate.
      Progress big(int pick) => Progress(
            craft: ProgressCraft.weaving,
            place: PickPlace(pick),
            basis: PlaceBasis(units: 6, prefix: fakePrefix(pick)),
            extra: {'later': 'y' * (kInlinePlaceBytes + 1000)},
          );
      _write(docs, craft, 'large', big(2));
      // Hold both projects' sidecar locks, so their writes wait in the record's queue.
      final gate = Completer<void>();
      final held = [
        for (final id in ['small', 'large'])
          SidecarWrites.run(p.join(docs.path, 'drafts', '$id.json'), () => gate.future),
      ];
      final writes = [
        repo.save(craft, 'small', _weave(5)),
        repo.save(craft, 'large', big(4)),
      ];
      final reading = readLibraryPlaces(repo, craft, ['small', 'large']);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      gate.complete();
      await Future.wait([...held, ...writes]);
      final places = await reading;
      expect(places['small']?.place, const PickPlace(5));
      expect(places['large']?.place, const PickPlace(4));
    });

    test('small places are handed on as they are read, large ones as the isolate reads them',
        () async {
      const craft = BackupCraft.weaving;
      _write(docs, craft, 'large', _big(3));
      for (final id in ['small-1', 'small-2']) {
        _write(docs, craft, id, _weave(2));
      }
      final order = <String>[];
      final places = await readLibraryPlaces(repo, craft, ['large', 'small-1', 'small-2'],
          onRead: (id, place) => order.add(id));
      expect(order.toSet(), {'large', 'small-1', 'small-2'});
      expect(order.last, 'large');
      expect(places['large']?.place, const PickPlace(3));
    });

    test('a large library is read at most $kPlaceReadsAtOnce records at a time', () async {
      const craft = BackupCraft.weaving;
      final ids = [for (var k = 0; k < 300; k++) 'project-$k'];
      for (final id in ids) {
        _write(docs, craft, id, _weave(4));
      }
      final counting = _Counting(docs);
      final places = await readLibraryPlaces(counting, craft, ids);
      expect(places.length, 300, reason: 'every place read, none refused for too many at once');
      expect(counting.most, kPlaceReadsAtOnce);
    });

    test('an unchanged record is not read again; one written since is', () async {
      const craft = BackupCraft.weaving;
      final ids = ['a', 'b', 'c'];
      for (final id in ids) {
        _sidecar(docs, craft, id);
        _write(docs, craft, id, _weave(2));
      }
      final counting = _Counting(docs);
      final cache = LibraryPlaceCache();
      final first = await readLibraryPlaces(counting, craft, ids, cache: cache);
      expect(counting.loads, 3);
      final second = await readLibraryPlaces(counting, craft, ids, cache: cache);
      expect(counting.loads, 3, reason: 'nothing decoded again');
      expect(second, first);
      // The same size, at once: told apart by the write this app made.
      await counting.save(craft, 'a', _weave(3));
      final third = await readLibraryPlaces(counting, craft, ids, cache: cache);
      expect(counting.loads, 4);
      expect(third['a']?.place, const PickPlace(3));
      expect(cache.lastFor(craft).keys.toSet(), ids.toSet());
      // Deleted: no line, and nothing kept for it.
      await counting.delete(craft, 'b');
      final fourth = await readLibraryPlaces(counting, craft, ids, cache: cache);
      expect(fourth.keys.toSet(), {'a', 'c'});
      expect(cache.lastFor(craft).keys.toSet(), {'a', 'c'});
    });

    test('a record the device cannot read just now: no line, never replaced or set aside',
        () async {
      const craft = BackupCraft.weaving;
      _sidecar(docs, craft, 'small');
      _write(docs, craft, 'small', _weave(2));
      _write(docs, craft, 'large', _big(2));
      final small = _recordFile(docs, craft, 'small');
      final large = _recordFile(docs, craft, 'large');
      if (!_lockOut(small) || !_lockOut(large)) {
        markTestSkipped('this process can read any file');
        return;
      }
      final names = _names(docs);
      expect((await repo.load(craft, 'small')).status, ProgressStatus.failed);
      expect(ProgressRepository.readFileSync(large.path, ProgressCraft.weaving).status,
          ProgressStatus.failed);
      expect(await readLibraryPlaces(repo, craft, ['small', 'large']), isEmpty);
      final ioFailed = isA<ProgressFileException>()
          .having((e) => e.problem, 'problem', ProgressProblem.ioFailed);
      await expectLater(repo.setAside(craft, 'small'), throwsA(ioFailed));
      await expectLater(
          repo.save(craft, 'small', _weave(3)),
          throwsA(isA<ProgressFileException>()
              .having((e) => e.problem, 'problem', ProgressProblem.saveCheckFailed)));
      expect(_names(docs), names, reason: 'nothing moved aside, nothing written');
      _letIn(small);
      _letIn(large);
      expect((await repo.load(craft, 'small')).progress?.place, const PickPlace(2));
      expect((await readLibraryPlaces(repo, craft, ['small', 'large'])).keys.toSet(),
          {'small', 'large'});
    });

    test('the tracker\'s words, only when the record keeps them for its place', () async {
      const craft = BackupCraft.knitting;
      final pad = 'y' * (kInlinePlaceBytes + 1000);
      // Each read inline and, past the inline size, on the background isolate.
      final cases = <String, Map<String, Object?>?>{
        'labelled': _label(_cuffWords),
        for (final MapEntry(:key, :value) in _oldLabels.entries) key: value,
        'no label': null,
      };
      final ids = <String>[];
      cases.forEach((name, label) {
        final id = name.replaceAll(' ', '-');
        _writeText(docs, craft, id, _knitWithLabel(_cuffRow3, label));
        _writeText(docs, craft, '$id-large', _knitWithLabel(_cuffRow3, label, pad: pad));
        expect(_recordFile(docs, craft, '$id-large').lengthSync(), greaterThan(kInlinePlaceBytes));
        ids.addAll([id, '$id-large']);
      });
      final before = _snapshot(docs);
      final places = await readLibraryPlaces(repo, craft, ids);
      final updated = _earlier.toUtc();
      final words =
          LibraryPlace.read(place: _cuffRow3, units: 120, updated: updated, label: _cuffWords);
      expect(places['labelled'], words);
      expect(places['labelled-large'], words, reason: 'read on the background isolate, words too');
      for (final id in ids.where((id) => !id.startsWith('labelled'))) {
        expect(places[id], LibraryPlace.read(place: _cuffRow3, units: 120, updated: updated),
            reason: id);
        expect(libraryPlaceText(places[id]!), 'Line 14 of 120, row 3', reason: id);
      }
      expect(libraryPlaceText(places['labelled']!), _cuffWords);
      for (final id in ids) {
        expect(places[id], LibraryPlace.fromLoad(await repo.load(craft, id)), reason: id);
      }
      expect(_snapshot(docs), before, reason: 'nothing written: a bad label is only not shown');
    });

    test('never throws: a repository that cannot find its folder gives no places', () async {
      expect(await readLibraryPlaces(_NoFolder(), BackupCraft.weaving, [_ok]), isEmpty);
      expect(await readLibraryPlaces(repo, BackupCraft.weaving, ['not a project id']), isEmpty);
    });

    test('the words of a place', () {
      expect(libraryPlaceWords(const PickPlace(49), 96), 'Pick 49 of 96');
      expect(libraryPlaceWords(const PickPlace(49, repeat: 2), 96), 'Pick 49 of 96, time 2');
      expect(libraryPlaceWords(const PickPlace(3), null), 'Pick 3');
      expect(libraryPlaceWords(const PickPlace(100), 96), 'Pick 100',
          reason: 'a record past the units it states names only its place');
      expect(libraryPlaceWords(const KnitPlace(4, repeat: 2), 24), 'Chart row 5 of 24, time 2');
      expect(
          libraryPlaceWords(
              const KnitPlace(13, row: 3, sectionId: 'section-1', stepId: 'step-4'), 120),
          'Line 14 of 120, row 3');
      expect(libraryPlaceWords(const KnitPlace(13, sectionId: 'section-1', stepId: 'step-4'), 120),
          'Line 14 of 120');
      expect(libraryPlaceWords(const KnitPlace(13, row: 2), 120), 'Line 14 of 120, row 2');
      // A chart row of a chart-rows step is a line of the sections, its ids kept or not.
      expect(
          libraryPlaceWords(const KnitPlace(13, chartRow: 2), 120), 'Line 14 of 120, chart row 2');
      expect(
          libraryPlaceWords(
              const KnitPlace(13, sectionId: 'section-2', stepId: 'step-5', chartRow: 4), 120),
          'Line 14 of 120, chart row 4');
      expect(libraryPlaceWords(const NalbindPlace(2, stepId: 'segment-3'), 12), 'Step 3 of 12');
      expect(
          libraryPlaceText(
              const LibraryPlace.read(place: _cuffRow3, units: 120, label: _cuffWords)),
          _cuffWords,
          reason: 'the tracker\'s words, when the record keeps them');
      expect(libraryPlaceText(const LibraryPlace.read(place: _cuffRow3, units: 120)),
          'Line 14 of 120, row 3');
      expect(libraryPlaceText(const LibraryPlace.newer()), kLibraryPlaceNewer);
      expect(libraryPlaceText(const LibraryPlace.unreadable()), kLibraryPlaceUnreadable);

      const l = DefaultMaterialLocalizations();
      expect(libraryUpdatedText(l, _earlier, _now), 'Updated today');
      expect(libraryUpdatedText(l, _earlier, DateTime(2026, 11, 19, 8)), 'Updated yesterday');
      expect(libraryUpdatedText(l, _earlier, DateTime(2026, 11, 25)), 'Updated Nov 18, 2026');
      expect(libraryUpdatedText(l, _earlier, DateTime(2026, 11, 10)), 'Updated Nov 18, 2026',
          reason: 'a time after the clock is a date');
    });
  });

  group('weaving', () {
    _Drafts drafts(List<String> ids) {
      for (final id in ids) {
        _sidecar(docs, BackupCraft.weaving, id);
      }
      return _Drafts(docs, ids);
    }

    testWidgets('a tile shows its place, or says why not, and nothing without a record',
        (tester) async {
      final semantics = tester.ensureSemantics();
      _write(docs, BackupCraft.weaving, _ok, _weave(4, repeat: 2));
      _writeText(docs, BackupCraft.weaving, _newer, _newerText(ProgressCraft.weaving));
      _writeText(docs, BackupCraft.weaving, _bad, _unreadableText);
      final repo = drafts([_ok, _none, _newer, _bad]);
      final before = _snapshot(docs);
      await _pump(tester, LibraryScreen(repository: repo), _weaveOverrides(docs, repo, work));
      expect(_lineText(_ok, 'Pick 4 of 6, time 2'), findsOneWidget);
      expect(_lineText(_ok, 'Updated today'), findsOneWidget);
      expect(
          find.bySemanticsLabel('Continue at pick 4 of 6, time 2. Updated today'), findsOneWidget);
      expect(_line(_none), findsNothing);
      expect(_lineText(_newer, kLibraryPlaceNewer), findsOneWidget);
      expect(_lineText(_bad, kLibraryPlaceUnreadable), findsOneWidget);
      expect(find.text('Draft $_none'), findsOneWidget, reason: 'every tile is listed');
      expect(_snapshot(docs), before, reason: 'a listing never writes');
      semantics.dispose();
    });

    testWidgets(
        'the place opens the tracker through the editor; back is the editor, then the '
        'library with the place moved on', (tester) async {
      _write(docs, BackupCraft.weaving, _ok, _weave(4, repeat: 2));
      final repo = drafts([_ok]);
      await _pump(tester, LibraryScreen(repository: repo), _weaveOverrides(docs, repo, work));
      await _tap(tester, _line(_ok));
      final editor = tester.widget<EditorScreen>(find.byType(EditorScreen, skipOffstage: false));
      expect(editor.id, _ok);
      expect(editor.openTracker, isTrue);
      expect(find.byType(WeaveTrackerScreen), findsOneWidget);
      expect(_trackerPlace('Pick 4'), findsOneWidget);
      expect(find.text('of 6, time 2 through the draft'), findsOneWidget);
      expect(find.textContaining('unsaved changes'), findsNothing);
      await _tap(tester, find.byKey(const ValueKey('tracker-next')));
      expect(
          (await tester.runAsync(
                  () => ProgressRepository(docsOverride: docs).load(BackupCraft.weaving, _ok)))!
              .progress!
              .place,
          const PickPlace(5, repeat: 2));

      await _back(tester);
      expect(find.byType(WeaveTrackerScreen), findsNothing);
      expect(find.byType(EditorScreen), findsOneWidget, reason: 'back from the tracker');
      expect(find.text('Leave without saving?'), findsNothing, reason: 'tracking is not an edit');
      await _back(tester);
      expect(find.byType(EditorScreen), findsNothing);
      expect(_lineText(_ok, 'Pick 5 of 6, time 2'), findsOneWidget, reason: 'read again');
    });

    testWidgets('the tile menu opens the tracker too, at pick 1 without a place', (tester) async {
      final repo = drafts([_none]);
      await _pump(tester, LibraryScreen(repository: repo), _weaveOverrides(docs, repo, work));
      await _tap(tester, find.byTooltip('Pattern actions'));
      await _tap(tester, find.text(kWeaveTrackerTitle));
      expect(find.byType(WeaveTrackerScreen), findsOneWidget);
      expect(_trackerPlace('Pick 1'), findsOneWidget);
      // And from the long-press sheet.
      await _back(tester);
      await _back(tester);
      await tester.longPress(find.text('Draft $_none'));
      await settle(tester);
      await _tap(tester, find.widgetWithText(ListTile, kWeaveTrackerTitle));
      expect(find.byType(WeaveTrackerScreen), findsOneWidget);
    });

    testWidgets('an unreadable place opens a tracker that says so and keeps the record',
        (tester) async {
      _writeText(docs, BackupCraft.weaving, _bad, _unreadableText);
      final repo = drafts([_bad]);
      await _pump(tester, LibraryScreen(repository: repo), _weaveOverrides(docs, repo, work));
      await _tap(tester, _line(_bad));
      expect(find.byType(WeaveTrackerScreen), findsOneWidget);
      expect(find.text('Your place in this project could not be read.'), findsOneWidget);
      expect(_recordFile(docs, BackupCraft.weaving, _bad).readAsStringSync(), _unreadableText);
    });

    testWidgets('a phone\'s small tiles hold the place at every text size', (tester) async {
      _write(
          docs,
          BackupCraft.weaving,
          _ok,
          _at(ProgressCraft.weaving, const PickPlace(4321, repeat: 12),
              units: 9999, prefix: fakePrefix(1)));
      _writeText(docs, BackupCraft.weaving, _newer, _newerText(ProgressCraft.weaving));
      _writeText(docs, BackupCraft.weaving, _bad, _unreadableText);
      final repo = drafts([_ok, _none, _newer, _bad]);
      for (final scale in [1.0, 1.3, 2.0]) {
        tester.view.physicalSize = const Size(1080, 2340);
        tester.view.devicePixelRatio = 2.625;
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(ProviderScope(
          overrides: _weaveOverrides(docs, repo, work),
          child: MaterialApp(home: LibraryScreen(repository: repo)),
        ));
        await settle(tester);
        expect(tester.takeException(), isNull, reason: 'text size $scale');
        expect(_lineText(_ok, 'Pick 4321 of 9999, time 12'), findsOneWidget);
        expect(_lineText(_ok, 'Updated today'), scale > 1.5 ? findsNothing : findsOneWidget);
        expect(_lineText(_bad, kLibraryPlaceUnreadable), findsOneWidget);
      }
    });

    testWidgets('the place is read again after a rename, a delete and a restore', (tester) async {
      _write(docs, BackupCraft.weaving, _ok, _weave(4, repeat: 2));
      final repo = drafts([_ok, _none]);
      final c = await _pump(tester, HomeScreen(repository: repo),
          [..._weaveOverrides(docs, repo, work), ..._noOtherCrafts]);
      expect(_lineText(_ok, 'Pick 4 of 6, time 2'), findsOneWidget);
      expect(_line(_none), findsNothing);

      // A rename lists the library again, and every tile's place with it.
      _write(docs, BackupCraft.weaving, _none, _weave(3));
      await _rename(tester, 'Pattern actions', 'Towel');
      expect(find.text('Towel'), findsOneWidget);
      expect(_lineText(_none, 'Pick 3 of 6'), findsOneWidget);

      // A delete: the tile goes with its record, and the others are read again.
      _write(docs, BackupCraft.weaving, _none, _weave(6));
      await _delete(tester, 'Pattern actions', 0);
      expect(_line(_ok), findsNothing);
      expect(_recordFile(docs, BackupCraft.weaving, _ok).existsSync(), isFalse);
      expect(_lineText(_none, 'Pick 6 of 6'), findsOneWidget);

      // A restore rebuilds the library, which reads the places again.
      _write(docs, BackupCraft.weaving, _none, _weave(2));
      c.read(libraryRevisionProvider.notifier).state++;
      await settle(tester);
      expect(_lineText(_none, 'Pick 2 of 6'), findsOneWidget);
    });
  });

  group('knitting', () {
    _Knits knits(List<String> ids) {
      for (final id in ids) {
        _sidecar(docs, BackupCraft.knitting, id);
      }
      return _Knits(docs, ids);
    }

    List<Override> overrides(_Knits repo) =>
        [knitRepositoryProvider.overrideWithValue(repo), ..._overrides(docs, work)];

    testWidgets('a tile shows its place, or says why not, and nothing without a record',
        (tester) async {
      _write(
          docs,
          BackupCraft.knitting,
          _ok,
          _at(ProgressCraft.knitting, const KnitPlace(1, repeat: 2),
              units: 3, prefix: fakePrefix(1)));
      _writeText(docs, BackupCraft.knitting, _newer, _newerText(ProgressCraft.knitting));
      _writeText(docs, BackupCraft.knitting, _bad, _unreadableText);
      final repo = knits([_ok, _none, _newer, _bad]);
      await _pump(tester, const KnitLibraryScreen(), overrides(repo));
      expect(_lineText(_ok, 'Chart row 2 of 3, time 2'), findsOneWidget);
      expect(_lineText(_ok, 'Updated today'), findsOneWidget);
      expect(_line(_none), findsNothing);
      expect(_lineText(_newer, kLibraryPlaceNewer), findsOneWidget);
      expect(_lineText(_bad, kLibraryPlaceUnreadable), findsOneWidget);
    });

    testWidgets('the place opens Knit row by row through the editor; back is the editor',
        (tester) async {
      _write(docs, BackupCraft.knitting, _ok, _knit(1));
      final repo = knits([_ok]);
      await _pump(tester, const KnitLibraryScreen(), overrides(repo));
      expect(_lineText(_ok, 'Chart row 2 of 3'), findsOneWidget);
      await _tap(tester, _line(_ok));
      final editor =
          tester.widget<KnitEditorScreen>(find.byType(KnitEditorScreen, skipOffstage: false));
      expect((editor.openId, editor.openTracker), (_ok, true));
      expect(find.byType(KnitTrackerScreen), findsOneWidget);
      expect(_trackerPlace('Row 2 (WS)'), findsOneWidget);
      expect(find.textContaining('unsaved changes'), findsNothing);
      await _tap(tester, find.byKey(const ValueKey('tracker-next')));
      await _back(tester);
      expect(find.byType(KnitTrackerScreen), findsNothing);
      expect(find.byType(KnitEditorScreen), findsOneWidget);
      await _back(tester);
      // The tracker wrote its words with the place: a flat chart's row, where a record without
      // them can only say Chart row.
      expect(_lineText(_ok, 'Row 3 of 3'), findsOneWidget);
    });

    testWidgets(
        'a tile in sections says the place in the tracker\'s words; old or broken words are not '
        'shown', (tester) async {
      final semantics = tester.ensureSemantics();
      _writeText(
          docs, BackupCraft.knitting, _labelled, _knitWithLabel(_cuffRow3, _label(_cuffWords)));
      _writeText(docs, BackupCraft.knitting, _oldLabel,
          _knitWithLabel(_cuffRow3, _oldLabels['another last change']));
      // Half of a symbol could not be laid out: such a label is never read, so the tile lays out.
      _writeText(docs, BackupCraft.knitting, _brokenLabel,
          _knitWithLabel(_cuffRow3, _oldLabels['half of a symbol']));
      final repo = knits([_labelled, _oldLabel, _brokenLabel]);
      await _pump(tester, const KnitLibraryScreen(), overrides(repo));
      expect(_lineText(_labelled, _cuffWords), findsOneWidget);
      expect(_lineText(_labelled, 'Updated today'), findsOneWidget);
      // Said as written: the heading keeps its capital.
      expect(find.bySemanticsLabel('Continue at $_cuffWords. Updated today'), findsOneWidget);
      expect(_lineText(_oldLabel, 'Line 14 of 120, row 3'), findsOneWidget);
      expect(find.bySemanticsLabel('Continue at line 14 of 120, row 3. Updated today'),
          findsNWidgets(2));
      expect(_lineText(_brokenLabel, 'Line 14 of 120, row 3'), findsOneWidget);
      expect(tester.takeException(), isNull);
      semantics.dispose();
    });

    testWidgets('moving the place in sections gives the tile the tracker\'s words', (tester) async {
      work.knit = _knitSections();
      // Saved without words, as by a build from before them.
      _write(
          docs,
          BackupCraft.knitting,
          _ok,
          _at(ProgressCraft.knitting,
              const KnitPlace(1, row: 2, sectionId: 'section-1', stepId: 'step-2'),
              units: 3, prefix: fakePrefix(2)));
      final repo = knits([_ok]);
      await _pump(tester, const KnitLibraryScreen(), overrides(repo));
      expect(_lineText(_ok, 'Line 2 of 3, row 2'), findsOneWidget);
      await _tap(tester, _line(_ok));
      expect(_trackerPlace('Row 2 of 6'), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('tracker-next')));
      await _back(tester);
      await _back(tester);
      expect(_lineText(_ok, 'Section 1: Cuff, step 2, row 3'), findsOneWidget);
      // Go to another step: the words follow the place.
      await _tap(tester, _line(_ok));
      await _tap(tester, find.byKey(const ValueKey('tracker-goto')));
      await _tap(tester, find.byKey(const ValueKey('tracker-goto-unit-2')));
      await _back(tester);
      await _back(tester);
      expect(_lineText(_ok, 'Section 2: Finish, step 1'), findsOneWidget);
    });

    testWidgets('the place is read again after a rename and a delete', (tester) async {
      _write(docs, BackupCraft.knitting, _ok, _knit(0));
      final repo = knits([_ok, _none]);
      await _pump(tester, const KnitLibraryScreen(), overrides(repo));
      _write(docs, BackupCraft.knitting, _none, _knit(1));
      await _rename(tester, 'Pattern actions', 'Cowl');
      expect(_lineText(_none, 'Chart row 2 of 3'), findsOneWidget);
      _write(docs, BackupCraft.knitting, _none, _knit(2));
      await _delete(tester, 'Pattern actions', 0);
      expect(_line(_ok), findsNothing);
      expect(_lineText(_none, 'Chart row 3 of 3'), findsOneWidget);
    });
  });

  group('tablet weaving', () {
    _Bands bands(List<String> ids) {
      for (final id in ids) {
        _sidecar(docs, BackupCraft.tabletWeaving, id);
      }
      return _Bands(docs, band1, ids);
    }

    List<Override> overrides(_Bands repo) =>
        [tabletRepositoryProvider.overrideWithValue(repo), ..._overrides(docs, work)];

    testWidgets('a tile shows its place, or says why not, and nothing without a record',
        (tester) async {
      _write(docs, BackupCraft.tabletWeaving, _ok, _band(2));
      _writeText(docs, BackupCraft.tabletWeaving, _newer, _newerText(ProgressCraft.tabletWeaving));
      _writeText(docs, BackupCraft.tabletWeaving, _bad, _unreadableText);
      final repo = bands([_ok, _none, _newer, _bad]);
      await _pump(tester, const TabletLibraryScreen(), overrides(repo));
      expect(_lineText(_ok, 'Pick 2 of 6'), findsOneWidget);
      expect(_line(_none), findsNothing);
      expect(_lineText(_newer, kLibraryPlaceNewer), findsOneWidget);
      expect(_lineText(_bad, kLibraryPlaceUnreadable), findsOneWidget);
    });

    testWidgets('the place opens the tracker through the band editor, whose stepper goes there',
        (tester) async {
      _write(docs, BackupCraft.tabletWeaving, _ok, _band(2));
      final repo = bands([_ok]);
      final c = await _pump(tester, const TabletLibraryScreen(), overrides(repo));
      await _tap(tester, _line(_ok));
      final editor =
          tester.widget<TabletEditorScreen>(find.byType(TabletEditorScreen, skipOffstage: false));
      expect((editor.openId, editor.openTracker), (_ok, true));
      expect(find.byType(TabletTrackerScreen), findsOneWidget);
      expect(_trackerPlace('Pick 2'), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('tracker-next')));
      await _back(tester);
      expect(find.byType(TabletTrackerScreen), findsNothing);
      expect(find.byType(TabletEditorScreen), findsOneWidget);
      expect(c.read(tabletPickProvider), 3, reason: 'the stepper at the place, as from its menu');
      expect(c.read(tabletEditorProvider).isDirty, isFalse);
      await _back(tester);
      expect(_lineText(_ok, 'Pick 3 of 6'), findsOneWidget);
    });

    testWidgets('the place is read again after a rename and a delete', (tester) async {
      _write(docs, BackupCraft.tabletWeaving, _ok, _band(1));
      final repo = bands([_ok, _none]);
      await _pump(tester, const TabletLibraryScreen(), overrides(repo));
      _write(docs, BackupCraft.tabletWeaving, _none, _band(4));
      await _rename(tester, 'Band actions', 'Belt');
      expect(_lineText(_none, 'Pick 4 of 6'), findsOneWidget);
      _write(docs, BackupCraft.tabletWeaving, _none, _band(5));
      await _delete(tester, 'Band actions', 0);
      expect(_line(_ok), findsNothing);
      expect(_lineText(_none, 'Pick 5 of 6'), findsOneWidget);
    });
  });

  group('nalbinding', () {
    _Nalbinds nalbinds(List<String> ids) {
      for (final id in ids) {
        _sidecar(docs, BackupCraft.nalbinding, id);
      }
      return _Nalbinds(docs, ids);
    }

    testWidgets('a project shows its place, or says why not, and nothing without a record',
        (tester) async {
      _write(docs, BackupCraft.nalbinding, _ok, _step(1));
      _writeText(docs, BackupCraft.nalbinding, _newer, _newerText(ProgressCraft.nalbinding));
      _writeText(docs, BackupCraft.nalbinding, _bad, _unreadableText);
      final repo = nalbinds([_ok, _none, _newer, _bad]);
      await _pump(tester, _nalbindTab, _nalbindOverrides(docs, repo, work));
      expect(_lineText(_ok, 'Step 2 of 3'), findsOneWidget);
      expect(_lineText(_ok, 'Updated today'), findsOneWidget);
      expect(_line(_none), findsNothing);
      expect(find.text('Hat $_none'), findsOneWidget);
      expect(_lineText(_newer, kLibraryPlaceNewer), findsOneWidget);
      expect(_lineText(_bad, kLibraryPlaceUnreadable), findsOneWidget);
    });

    testWidgets('the place opens Nalbind step by step through the project; back is the project',
        (tester) async {
      _write(docs, BackupCraft.nalbinding, _ok, _step(1));
      final repo = nalbinds([_ok]);
      await _pump(tester, _nalbindTab, _nalbindOverrides(docs, repo, work));
      await _tap(tester, _line(_ok));
      final project = tester
          .widget<NalbindProjectScreen>(find.byType(NalbindProjectScreen, skipOffstage: false));
      expect((project.openId, project.openTracker), (_ok, true));
      expect(find.byType(NalbindFollowScreen), findsOneWidget);
      expect(
          find.descendant(
              of: find.byKey(const ValueKey('tracker-place')),
              matching: find.textContaining('Step 2 of 3'),
              matchRoot: true),
          findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('follow-next')));
      await _back(tester);
      expect(find.byType(NalbindFollowScreen), findsNothing);
      expect(find.byType(NalbindProjectScreen), findsOneWidget);
      await _back(tester);
      expect(_lineText(_ok, 'Step 3 of 3'), findsOneWidget);
    });

    testWidgets(
        'the project menu opens it too, and the place is read again after a delete and '
        'a restore', (tester) async {
      _write(docs, BackupCraft.nalbinding, _ok, _step(0));
      final repo = nalbinds([_ok, _none]);
      final c = await _pump(tester, _nalbindTab, _nalbindOverrides(docs, repo, work));
      await _tap(tester, find.byTooltip('Project actions').last);
      await _tap(tester, find.text(kNalbindTrackerTitle));
      expect(find.byType(NalbindFollowScreen), findsOneWidget);
      await _back(tester);
      await _back(tester);

      _write(docs, BackupCraft.nalbinding, _none, _step(2));
      await _delete(tester, 'Project actions', 0);
      expect(_line(_ok), findsNothing);
      expect(_recordFile(docs, BackupCraft.nalbinding, _ok).existsSync(), isFalse);
      expect(_lineText(_none, 'Step 3 of 3'), findsOneWidget);

      // As a restore does.
      _write(docs, BackupCraft.nalbinding, _none, _step(1));
      c.invalidate(nalbindProjectsProvider);
      await settle(tester);
      expect(_lineText(_none, 'Step 2 of 3'), findsOneWidget);
    });
  });

  group('reaching the place, reading again and trying again', () {
    _Drafts drafts(List<String> ids) {
      for (final id in ids) {
        _sidecar(docs, BackupCraft.weaving, id);
      }
      return _Drafts(docs, ids);
    }

    testWidgets('the place is a button switch and voice access can press', (tester) async {
      final semantics = tester.ensureSemantics();
      _write(docs, BackupCraft.weaving, _ok, _weave(4, repeat: 2));
      _writeText(docs, BackupCraft.weaving, _bad, _unreadableText);
      final repo = drafts([_ok, _bad]);
      await _pump(tester, LibraryScreen(repository: repo), _weaveOverrides(docs, repo, work));
      const spoken = 'Continue at pick 4 of 6, time 2. Updated today';
      final data = tester.getSemantics(find.bySemanticsLabel(spoken)).getSemanticsData();
      expect(data.flagsCollection.isButton, isTrue);
      expect(data.hasAction(ui.SemanticsAction.tap), isTrue);
      for (final line in [kLibraryPlaceUnreadable]) {
        expect(
            tester
                .getSemantics(find.bySemanticsLabel(line))
                .getSemanticsData()
                .hasAction(ui.SemanticsAction.tap),
            isTrue,
            reason: line);
      }
      tester.semantics.tap(find.semantics.byLabel(spoken));
      await settle(tester);
      expect(find.byType(WeaveTrackerScreen), findsOneWidget);
      expect(_trackerPlace('Pick 4'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('a second tap while a draft opens opens no second editor or tracker',
        (tester) async {
      _write(docs, BackupCraft.weaving, _ok, _weave(4, repeat: 2));
      final repo = drafts([_ok]);
      await _pump(tester, LibraryScreen(repository: repo), _weaveOverrides(docs, repo, work));
      // Two taps before the draft is read (both reach the place before anything is pushed).
      final line = tester.widget<LibraryPlaceLine>(_line(_ok));
      line.onOpen();
      line.onOpen();
      await settle(tester);
      expect(find.byType(EditorScreen, skipOffstage: false), findsOneWidget);
      expect(find.byType(WeaveTrackerScreen), findsOneWidget);
    });

    testWidgets('overlapping reads: the later one wins, and the earlier keeps nothing',
        (tester) async {
      _write(docs, BackupCraft.weaving, _ok, _weave(2));
      final repo = _SlowFirstRead(docs);
      final c = await _pump(tester, const _Harness(), [
        progressRepositoryProvider.overrideWithValue(repo),
        progressClockProvider.overrideWithValue(() => _now),
      ]);
      final state = tester.state<_HarnessState>(find.byType(_Harness));
      // Real file reads run outside the test's fake clock, so both reads start in it.
      late Future<void> first;
      await tester.runAsync(() async {
        first = state.readPlaces([_ok]);
        await repo.asked.future;
        // The record moves on while the first read is held up, and a second read begins.
        _write(docs, BackupCraft.weaving, _ok, _weave(3));
        await state.readPlaces([_ok]);
      });
      await tester.pump();
      expect(find.text('Pick 3 of 6'), findsOneWidget);
      await tester.runAsync(() async {
        repo.gate.complete();
        await first;
      });
      await tester.pump();
      expect(find.text('Pick 3 of 6'), findsOneWidget, reason: 'the earlier read shows nothing');
      expect(c.read(libraryPlaceCacheProvider).lastFor(BackupCraft.weaving)[_ok]?.place,
          const PickPlace(3));
    });

    testWidgets('a library built again starts from the places last read', (tester) async {
      _write(docs, BackupCraft.weaving, _ok, _weave(4, repeat: 2));
      final repo = drafts([_ok]);
      final c = await _pump(tester, HomeScreen(repository: repo),
          [..._weaveOverrides(docs, repo, work), ..._noOtherCrafts]);
      expect(_lineText(_ok, 'Pick 4 of 6, time 2'), findsOneWidget);
      // The record goes, and a restore builds the tab again: the place last read is there as soon as
      // the tile is, before any record is read, and goes once the read finds no record.
      _recordFile(docs, BackupCraft.weaving, _ok).deleteSync();
      c.read(libraryRevisionProvider.notifier).state++;
      await tester.pump();
      await tester.pump();
      expect(_lineText(_ok, 'Pick 4 of 6, time 2'), findsOneWidget);
      await settle(tester);
      expect(_line(_ok), findsNothing);
    });

    final ioFailed = const ProgressFileException(ProgressProblem.ioFailed).message;

    testWidgets(
        'weaving: a record the device cannot read just now offers Try again, never Start '
        'again', (tester) async {
      _sidecar(docs, BackupCraft.weaving, _ok);
      _write(docs, BackupCraft.weaving, _ok, _weave(4, repeat: 2));
      final record = _recordFile(docs, BackupCraft.weaving, _ok);
      if (!_lockOut(record)) {
        markTestSkipped('this process can read any file');
        return;
      }
      await pumpTracker(
          tester,
          WeaveTrackerScreen(
              projectId: _ok,
              draft: DraftRepository().toDto(generatedOvershot(picks: 6)),
              name: 'Towel'),
          trackerOverrides(docs, work));
      expect(find.text(ioFailed), findsOneWidget);
      expect(find.byKey(const ValueKey('tracker-start-again')), findsNothing);
      _letIn(record);
      await tapAndSettle(tester, find.byKey(const ValueKey('tracker-try-again')));
      expect(_trackerPlace('Pick 4'), findsOneWidget);
      expect(_names(docs).where((n) => n.contains('.corrupt')), isEmpty);
    });

    testWidgets('knitting and nalbinding offer Try again too', (tester) async {
      final memory = MemoryProgressRepository()
        ..problems[(BackupCraft.knitting, _ok)] = ProgressStatus.failed
        ..problems[(BackupCraft.nalbinding, _ok)] = ProgressStatus.failed;
      final overrides = [
        progressRepositoryProvider.overrideWithValue(memory),
        workRepositoryProvider.overrideWithValue(work),
        progressClockProvider.overrideWithValue(() => _now),
        nalbindRepositoryProvider.overrideWithValue(RecipeFakeRepo()),
      ];
      await _pump(tester, KnitTrackerScreen(projectId: _ok, pattern: _knitPattern(), name: 'Cowl'),
          overrides);
      expect(find.text(ioFailed), findsOneWidget);
      expect(find.byKey(const ValueKey('tracker-start-again')), findsNothing);
      memory.problems.remove((BackupCraft.knitting, _ok));
      memory.records[(BackupCraft.knitting, _ok)] = _knit(1);
      await _tap(tester, find.byKey(const ValueKey('tracker-try-again')));
      expect(_trackerPlace('Row 2 (WS)'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await _pump(
          tester,
          NalbindFollowScreen(
              recipe: _recipe,
              projectNotation: 'UO/UOO F1',
              projectStitchName: 'Oslo',
              onTick: (_, __) async => null,
              projectId: _ok),
          overrides);
      expect(find.text(ioFailed), findsOneWidget);
      expect(find.byKey(const ValueKey('tracker-start-again')), findsNothing);
      memory.problems.remove((BackupCraft.nalbinding, _ok));
      memory.records[(BackupCraft.nalbinding, _ok)] = _step(1);
      await _tap(tester, find.byKey(const ValueKey('tracker-try-again')));
      expect(
          find.descendant(
              of: find.byKey(const ValueKey('tracker-place')),
              matching: find.textContaining('Step 2 of 3'),
              matchRoot: true),
          findsOneWidget);
    });
  });
}

/// A screen that lists one weaving project's place, with nothing else.
class _Harness extends ConsumerStatefulWidget {
  const _Harness();

  @override
  ConsumerState<_Harness> createState() => _HarnessState();
}

class _HarnessState extends ConsumerState<_Harness> with LibraryPlaces<_Harness> {
  @override
  BackupCraft get placesCraft => BackupCraft.weaving;

  @override
  Widget build(BuildContext context) {
    final place = placeOf(_ok);
    return Text(place == null ? 'no place' : libraryPlaceText(place));
  }
}

/// The first read is held at [gate], with what the record held when it was asked for.
class _SlowFirstRead extends ProgressRepository {
  _SlowFirstRead(Directory docs) : super(docsOverride: docs);

  // Completed at once, in whichever zone completes them: the test's fake clock never runs late.
  final gate = Completer<void>.sync();
  final asked = Completer<void>.sync();
  var _calls = 0;

  @override
  Future<ProgressLoad> load(BackupCraft craft, String id) async {
    final read = await super.load(craft, id);
    if (_calls++ == 0) {
      asked.complete();
      await gate.future;
    }
    return read;
  }
}

/// Counts the reads under way at once, and fails one past [kPlaceReadsAtOnce].
class _Counting extends ProgressRepository {
  _Counting(Directory docs) : super(docsOverride: docs);

  int open = 0;
  int most = 0;
  int loads = 0;

  @override
  Future<ProgressLoad> load(BackupCraft craft, String id) async {
    loads++;
    open++;
    most = math.max(most, open);
    try {
      if (open > kPlaceReadsAtOnce) throw StateError('more than $kPlaceReadsAtOnce reads at once');
      await Future<void>.delayed(const Duration(milliseconds: 1));
      return await super.load(craft, id);
    } finally {
      open--;
    }
  }
}

/// The other crafts' tabs of the home, empty.
final List<Override> _noOtherCrafts = [
  knitRepositoryProvider.overrideWithValue(_NoKnits()),
  tabletRepositoryProvider.overrideWithValue(_NoBands()),
];

class _NoKnits extends KnitRepository {
  @override
  Future<List<KnitEntry>> listKnits() async => const [];
}

class _NoBands extends FakeTabletRepo {
  @override
  Future<List<TabletEntry>> listBands() async => const [];
}

/// A repository whose documents folder cannot be found.
class _NoFolder extends ProgressRepository {
  @override
  Future<File> file(BackupCraft craft, String id) async => throw StateError('no documents folder');
}
