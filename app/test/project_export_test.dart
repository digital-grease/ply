import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/draft_repository.dart';
import 'package:ply/src/data/knit_repository.dart';
import 'package:ply/src/data/library_backup.dart';
import 'package:ply/src/data/nalbind_repository.dart';
import 'package:ply/src/models/draft_meta.dart';
import 'package:ply/src/models/knit_entry.dart';
import 'package:ply/src/models/nalbind_project.dart';
import 'package:ply/src/rust/nalbind_dto.dart';
import 'package:ply/src/screens/knit_library_screen.dart';
import 'package:ply/src/screens/library_screen.dart';
import 'package:ply/src/screens/nalbind_reference_screen.dart';
import 'package:ply/src/state/backup_providers.dart';
import 'package:ply/src/state/editor_providers.dart';
import 'package:ply/src/state/knit_editor_providers.dart';
import 'package:ply/src/state/nalbind_providers.dart';

import 'backup_test_support.dart';

// "Export" in each library's project actions: it plans a single-project backup of that project,
// builds it, and hands it to the save dialog under the project's file name, reporting the outcome.
// Over the stand-in backup service and file dialog (the format itself is covered in
// library_backup_test.dart, including that an export restores through "Restore from backup").

DraftMeta _meta(String name, String craft) => DraftMeta(
      name: name,
      craft: craft,
      savedAt: DateTime.utc(2020),
      lastOpened: DateTime.utc(2020),
    );

class _Drafts extends DraftRepository {
  @override
  Future<List<DraftEntry>> list() async =>
      [DraftEntry(id: 'd1', wifPath: '/nowhere/d1.wif', meta: _meta('Twill 2/2', 'Weaving'))];

  @override
  Future<void> rebuildThumbnail(String id) async {} // draws nothing: the tile keeps its placeholder
}

class _Knits extends KnitRepository {
  @override
  Future<List<KnitEntry>> listKnits() async => [
        KnitEntry(
            id: 'k1', patternPath: '/nowhere/k1.plyknit', meta: _meta('Hat', 'Knitting')),
      ];

  @override
  Future<Never> readPattern(String id) async => throw Exception('no engine in host tests');
}

class _Nalbinds extends NalbindRepository {
  @override
  Future<List<NalbindStitchDto>> builtins() async => const [];

  @override
  Future<List<NalbindProjectEntry>> listProjects() async =>
      [NalbindProjectEntry(id: 'n1', name: 'Mitten', lastOpened: DateTime.utc(2020))];
}

late FakeBackup backup;
late FakeFiles files;

BackupPlan _projectPlan(BackupCraft craft, String name) => BackupPlan(
      createdAt: DateTime(2026, 11, 12),
      appVersion: 'test',
      files: const [],
      projectCounts: {for (final c in BackupCraft.values) c: c == craft ? 1 : 0},
      photoCount: 0,
      contents: BackupContents.project,
      projectName: name,
    );

/// Pump [home] (given the stand-in weaving repository) over the stand-in services.
Future<void> _pump(WidgetTester t, Widget Function(DraftRepository drafts) home) async {
  final drafts = _Drafts();
  final c = ProviderContainer(overrides: [
    repositoryProvider.overrideWithValue(drafts),
    knitRepositoryProvider.overrideWithValue(_Knits()),
    nalbindRepositoryProvider.overrideWithValue(_Nalbinds()),
    libraryBackupProvider.overrideWithValue(backup),
    backupFileAccessProvider.overrideWithValue(files),
  ]);
  addTearDown(c.dispose);
  await t.pumpWidget(UncontrolledProviderScope(
    container: c,
    child: MaterialApp(home: home(drafts)),
  ));
  await t.pumpAndSettle();
}

/// Open the project's ⋮ menu and choose Export.
Future<void> _exportFromMenu(WidgetTester t, String tooltip) async {
  await t.tap(find.byTooltip(tooltip));
  await t.pumpAndSettle();
  await t.tap(find.text('Export'));
  await t.pumpAndSettle();
}

void main() {
  setUp(() {
    backup = FakeBackup();
    files = FakeFiles();
  });

  testWidgets('a weaving draft exports to a backup file named after it', (t) async {
    backup.projectPlan = _projectPlan(BackupCraft.weaving, 'Twill 2/2');
    await _pump(t, (drafts) => LibraryScreen(repository: drafts));
    await _exportFromMenu(t, 'Pattern actions');
    expect(backup.projectAsked, (BackupCraft.weaving, 'd1'));
    expect(backup.builtFrom, same(backup.projectPlan));
    expect(files.saved.single.$1, 'Twill 2-2 2026-11-12.plybackup');
    expect(files.saved.single.$2, backup.built);
    expect(find.text('Exported "Twill 2/2".'), findsOneWidget);
  });

  testWidgets('a weaving draft also exports from the long-press actions', (t) async {
    backup.projectPlan = _projectPlan(BackupCraft.weaving, 'Twill 2/2');
    await _pump(t, (drafts) => LibraryScreen(repository: drafts));
    await t.longPress(find.text('Twill 2/2'));
    await t.pumpAndSettle();
    expect(find.widgetWithText(ListTile, 'Export'), findsOneWidget);
    await t.tap(find.widgetWithText(ListTile, 'Export'));
    await t.pumpAndSettle();
    expect(backup.projectAsked, (BackupCraft.weaving, 'd1'));
    expect(files.saved, hasLength(1));
  });

  testWidgets('a knitting pattern exports from its menu and its long-press actions', (t) async {
    backup.projectPlan = _projectPlan(BackupCraft.knitting, 'Hat');
    await _pump(t, (_) => const KnitLibraryScreen());
    await _exportFromMenu(t, 'Pattern actions');
    expect(backup.projectAsked, (BackupCraft.knitting, 'k1'));
    expect(files.saved.single.$1, 'Hat 2026-11-12.plybackup');
    expect(find.text('Exported "Hat".'), findsOneWidget);

    await t.longPress(find.text('Hat'));
    await t.pumpAndSettle();
    await t.tap(find.widgetWithText(ListTile, 'Export'));
    await t.pumpAndSettle();
    expect(files.saved, hasLength(2));
  });

  testWidgets('a nalbinding project exports from its menu', (t) async {
    backup.projectPlan = _projectPlan(BackupCraft.nalbinding, 'Mitten');
    await _pump(t, (_) => const Scaffold(body: NalbindReferenceScreen()));
    expect(find.text('Mitten'), findsOneWidget);
    await _exportFromMenu(t, 'Project actions');
    expect(backup.projectAsked, (BackupCraft.nalbinding, 'n1'));
    expect(files.saved.single.$1, 'Mitten 2026-11-12.plybackup');
    expect(find.text('Exported "Mitten".'), findsOneWidget);
  });

  testWidgets('cancelling the save dialog says nothing', (t) async {
    backup.projectPlan = _projectPlan(BackupCraft.weaving, 'Twill 2/2');
    files.saveResult = false;
    await _pump(t, (drafts) => LibraryScreen(repository: drafts));
    await _exportFromMenu(t, 'Pattern actions');
    expect(find.byType(SnackBar), findsNothing);
    expect(find.text('Exporting...'), findsNothing, reason: 'the progress dialog closed');
  });

  testWidgets('a refused export says why, and a failed save says it was not saved', (t) async {
    backup.projectPlanError = const BackupException(BackupProblem.projectNotFound);
    await _pump(t, (_) => const KnitLibraryScreen());
    await _exportFromMenu(t, 'Pattern actions');
    expect(find.text('This project is no longer in your library.'), findsOneWidget);
    expect(files.saved, isEmpty);
    await t.pump(const Duration(seconds: 5)); // the snackbar leaves
    await t.pumpAndSettle();

    backup.projectPlanError = null;
    backup.projectPlan = _projectPlan(BackupCraft.knitting, 'Hat');
    files.saveError = Exception('the system dialog failed');
    await _exportFromMenu(t, 'Pattern actions');
    expect(find.text('Could not save the export.'), findsOneWidget);
    expect(find.text('Exporting...'), findsNothing);
  });
}
