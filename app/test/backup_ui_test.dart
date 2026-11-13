import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:ply/src/data/app_settings_repository.dart';
import 'package:ply/src/data/draft_repository.dart';
import 'package:ply/src/data/knit_repository.dart';
import 'package:ply/src/data/library_backup.dart';
import 'package:ply/src/data/nalbind_repository.dart';
import 'package:ply/src/models/app_settings.dart';
import 'package:ply/src/models/draft_doc.dart' show MeasureUnit;
import 'package:ply/src/models/draft_meta.dart';
import 'package:ply/src/models/nalbind_project.dart';
import 'package:ply/src/rust/knit_dto.dart';
import 'package:ply/src/screens/home_screen.dart';
import 'package:ply/src/screens/settings_screen.dart';
import 'package:ply/src/state/backup_providers.dart';
import 'package:ply/src/state/editor_providers.dart';
import 'package:ply/src/state/nalbind_providers.dart';
import 'package:ply/src/state/theme_providers.dart';

import 'backup_test_support.dart';

// The Settings "Backup" section and the restore preview, over a stand-in service and file picker:
// the summary before saving (with the app settings checkbox), the save, the preview's groups,
// conflict choice and app settings item, the library refresh after a restore, and the error
// dialogs. Plus the thumbnail rebuilders a restore calls and the settings wiring of the service.

class FakeSettingsRepo extends AppSettingsRepository {
  final saved = <AppSettings>[];
  Object? saveError;

  @override
  Future<AppSettings> load() async => const AppSettings();
  @override
  Future<void> save(AppSettings s) async {
    if (saveError != null) throw saveError!;
    saved.add(s);
  }
}

const AppSettings backedUp = AppSettings(
  themeMode: ThemeMode.dark,
  accentSeed: 0xFF00696E,
  useDynamicColor: false,
  unit: MeasureUnit.centimeters,
);

BackupPlan summaryPlan({AppSettings? settings}) => BackupPlan(
      createdAt: DateTime(2026, 11, 12),
      appVersion: 'test',
      files: const [],
      projectCounts: const {
        BackupCraft.weaving: 2,
        BackupCraft.knitting: 1,
        BackupCraft.nalbinding: 1,
      },
      photoCount: 3,
      settings: settings == null ? null : BackupSettingsFile.of(settings),
      includeSettings: settings != null,
    );

class CountingNalbindRepo extends NalbindRepository {
  int lists = 0;
  @override
  Future<List<NalbindProjectEntry>> listProjects() async {
    lists++;
    return const [];
  }
}

class CountingDraftRepo extends DraftRepository {
  int lists = 0;
  @override
  Future<List<DraftEntry>> list() async {
    lists++;
    return const [];
  }
}

late FakeBackup backup;
late FakeFiles files;
late CountingNalbindRepo nalbinds;

Future<ProviderContainer> pumpSettings(WidgetTester t) async {
  // Tall enough that the whole restore preview is laid out (its list is lazy).
  t.view.physicalSize = const Size(1200, 4000);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  final c = ProviderContainer(overrides: [
    appSettingsRepositoryProvider.overrideWithValue(FakeSettingsRepo()),
    libraryBackupProvider.overrideWithValue(backup),
    backupFileAccessProvider.overrideWithValue(files),
    nalbindRepositoryProvider.overrideWithValue(nalbinds),
  ]);
  addTearDown(c.dispose);
  await t.pumpWidget(UncontrolledProviderScope(
    container: c,
    child: const MaterialApp(home: SettingsScreen()),
  ));
  await t.pumpAndSettle();
  return c;
}

Future<void> tapTile(WidgetTester t, String title) async {
  await t.ensureVisible(find.text(title));
  await t.pumpAndSettle();
  await t.tap(find.text(title));
  await t.pumpAndSettle();
}

/// A real restore plan: a backup of a seeded library, checked against a library where one draft
/// changed (a conflict), one is identical (already present), and with a pattern from a newer Ply
/// and a new project in the backup. With [settings], the backup also carries those app settings.
Future<RestorePlan> realPlan(WidgetTester t, {AppSettings? settings}) async {
  late RestorePlan plan;
  await t.runAsync(() async {
    docs = await Directory.systemTemp.createTemp('ui_docs');
    work = await Directory.systemTemp.createTemp('ui_work');
    addTearDown(() async {
      await docs.delete(recursive: true);
      await work.delete(recursive: true);
    });
    final source = Directory(p.join(work.path, 'source'));
    await put(source, 'drafts/d1.wif', wifBytes);
    await put(source, 'drafts/d1.json', sidecar('Twill', 'Weaving'));
    await put(source, 'drafts/d2.wif', wifBytes);
    await put(source, 'drafts/d2.json', sidecar('Plain', 'Weaving'));
    await put(source, 'drafts/d3.wif', wifBytes);
    await put(source, 'drafts/d3.json', sidecar('Rosepath', 'Weaving'));
    await put(source, 'knits/k1.plyknit', knitFile(version: knitVersion + 1));
    await put(source, 'knits/k1.json', sidecar('Hat', 'Knitting'));
    final archive = await backUp(service(into: source, settings: settings));
    await put(docs, 'drafts/d1.wif', [1, 2, 3]);
    await put(docs, 'drafts/d1.json', sidecar('Twill', 'Weaving'));
    await put(docs, 'drafts/d2.wif', wifBytes);
    await put(docs, 'drafts/d2.json', sidecar('Plain', 'Weaving'));
    plan = await service().inspectBackup(archive);
  });
  return plan;
}

void main() {
  setUp(() {
    backup = FakeBackup();
    files = FakeFiles();
    nalbinds = CountingNalbindRepo();
  });

  testWidgets('Settings has a Backup section with both actions', (t) async {
    await pumpSettings(t);
    await t.ensureVisible(find.text('Restore from backup'));
    expect(find.text('Backup'), findsOneWidget);
    expect(find.text('Back up library'), findsOneWidget);
    expect(find.text('Save all projects to one file, optionally with your app settings.'),
        findsOneWidget);
    expect(
        find.text(
            'Add projects from a backup or an exported project. Your projects are never replaced.'),
        findsOneWidget);
  });

  testWidgets('backing up shows a summary, then saves through the file dialog', (t) async {
    backup.plan = summaryPlan();
    await pumpSettings(t);
    await tapTile(t, 'Back up library');
    expect(find.text('Weaving: 2 projects'), findsOneWidget);
    expect(find.text('Knitting: 1 project'), findsOneWidget);
    expect(find.text('Nalbinding: 1 project, 3 photos'), findsOneWidget);
    expect(find.text('Size: 2 KB'), findsOneWidget);
    expect(find.text('App settings are not included.'), findsOneWidget);

    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();
    expect(files.saved, isEmpty);

    await tapTile(t, 'Back up library');
    await t.tap(find.text('Save'));
    await t.pumpAndSettle();
    expect(files.saved.single.$1, 'ply-library-2026-11-12.plybackup');
    expect(files.saved.single.$2, backup.built);
    expect(find.text('Backup saved.'), findsOneWidget);
  });

  testWidgets('backing up an empty library says so', (t) async {
    backup.planError = const BackupException(BackupProblem.noProjects);
    await pumpSettings(t);
    await tapTile(t, 'Back up library');
    expect(find.text('There are no projects to back up.'), findsOneWidget);
    expect(files.saved, isEmpty);
  });

  testWidgets('the summary offers the app settings, ticked, and the size follows the choice',
      (t) async {
    backup.plan = summaryPlan(settings: backedUp);
    await pumpSettings(t);
    await tapTile(t, 'Back up library');
    expect(find.text('App settings are not included.'), findsNothing);
    final box = find.widgetWithText(CheckboxListTile, 'Include app settings');
    expect(box, findsOneWidget);
    expect(find.text('Theme, accent color, Material You and units'), findsOneWidget);
    expect(t.widget<CheckboxListTile>(box).value, isTrue);
    expect(find.text('Size: 3 KB'), findsOneWidget);
    await t.tap(find.text('Save'));
    await t.pumpAndSettle();
    expect(backup.builtFrom!.carriesSettings, isTrue);
    expect(files.saved, hasLength(1));

    // Unticked: the size drops and the backup is made without them.
    await tapTile(t, 'Back up library');
    await t.tap(find.text('Include app settings'));
    await t.pumpAndSettle();
    expect(t.widget<CheckboxListTile>(box).value, isFalse);
    expect(find.text('Size: 2 KB'), findsOneWidget);
    await t.tap(find.text('Save'));
    await t.pumpAndSettle();
    expect(backup.builtFrom!.carriesSettings, isFalse);
    expect(backup.builtFrom!.archiveSize, lessThan(backup.plan!.archiveSize));
    expect(files.saved, hasLength(2));
  });

  testWidgets('restoring previews the backup by craft, then restores the ticked projects',
      (t) async {
    backup.inspected = await realPlan(t);
    files.toPick = File('picked.plybackup');
    final c = await pumpSettings(t);
    await c.read(nalbindProjectsProvider.future);
    expect(nalbinds.lists, 1);
    await tapTile(t, 'Restore from backup');

    expect(find.text('Restore backup'), findsOneWidget);
    expect(find.text('Nothing in your library is replaced.'), findsOneWidget);
    expect(find.text('App settings'), findsNothing, reason: 'this backup has none');
    expect(find.text('Weaving'), findsOneWidget);
    expect(find.text('New (1)'), findsOneWidget);
    expect(find.text('Rosepath'), findsOneWidget);
    expect(find.text('Different from your library (1)'), findsOneWidget);
    expect(find.text('Ticked projects are added as copies. Your projects are not changed.'),
        findsOneWidget);
    expect(find.text('Restore as "Twill (restored)"'), findsOneWidget);
    expect(find.text('Already in your library (1)'), findsOneWidget);
    expect(find.text('Skipped'), findsOneWidget);
    expect(find.text('Knitting'), findsOneWidget);
    expect(find.text('Cannot restore (1)'), findsOneWidget);
    expect(find.text('Made by a newer version of Ply. Update the app to restore it.'),
        findsOneWidget);
    expect(find.text('Restore 2 projects'), findsOneWidget);

    // Untick the conflict: only the new project is restored.
    await t.tap(find.byType(CheckboxListTile));
    await t.pumpAndSettle();
    expect(find.text('Restore 1 project'), findsOneWidget);
    await t.tap(find.text('Restore 1 project'));
    await t.pumpAndSettle();

    final conflictKey = backup.inspected!.projects
        .singleWhere((p) => p.status == RestoreStatus.conflict)
        .key;
    expect(backup.skipped, {conflictKey});
    expect(find.text('Restored 1 project.'), findsOneWidget);
    expect(find.text('Restore backup'), findsNothing); // back on Settings
    expect(c.read(libraryRevisionProvider), 1); // the library tabs reload
    await c.read(nalbindProjectsProvider.future);
    expect(nalbinds.lists, 2); // the nalbinding list was invalidated
    expect(files.discards, 1);
  });

  testWidgets('the preview offers the app settings unticked, and restores them only when ticked',
      (t) async {
    backup.inspected = await realPlan(t, settings: backedUp);
    files.toPick = File('picked.plybackup');
    await pumpSettings(t);
    await tapTile(t, 'Restore from backup');
    expect(find.text('App settings'), findsOneWidget);
    final box = find.widgetWithText(CheckboxListTile, 'Restore app settings');
    expect(t.widget<CheckboxListTile>(box).value, isFalse, reason: 'unticked by default');
    expect(find.text('Dark theme, Material You off, metric units. Replaces your current settings.'),
        findsOneWidget);
    expect(find.text('Restore 2 projects'), findsOneWidget);

    // Unticked: the restore leaves the settings alone.
    await t.tap(find.text('Restore 2 projects'));
    await t.pumpAndSettle();
    expect(backup.restoredSettings, isFalse);
    expect(find.text('Restored 2 projects.'), findsOneWidget);

    // Ticked: they are restored with the projects.
    await t.pump(const Duration(seconds: 5)); // let the snackbar go
    await t.pumpAndSettle();
    await tapTile(t, 'Restore from backup');
    await t.tap(box);
    await t.pumpAndSettle();
    expect(find.text('Restore 2 projects and app settings'), findsOneWidget);
    await t.tap(find.text('Restore 2 projects and app settings'));
    await t.pumpAndSettle();
    expect(backup.restoredSettings, isTrue);
    expect(find.text('Restored 2 projects and app settings.'), findsOneWidget);
  });

  testWidgets('settings alone can be restored', (t) async {
    backup.inspected = RestorePlan(
      archive: File('picked.plybackup'),
      createdAt: DateTime(2026, 11, 12),
      appVersion: 'test',
      projects: const [],
      settings: const RestoreSettings.available(backedUp),
    );
    files.toPick = File('picked.plybackup');
    await pumpSettings(t);
    await tapTile(t, 'Restore from backup');
    expect(find.text('This backup has no projects.'), findsOneWidget);
    final button = find.widgetWithText(FilledButton, 'Nothing to restore');
    expect(t.widget<FilledButton>(button).onPressed, isNull);
    await t.tap(find.text('Restore app settings'));
    await t.pumpAndSettle();
    await t.tap(find.widgetWithText(FilledButton, 'Restore app settings'));
    await t.pumpAndSettle();
    expect(backup.restoredSettings, isTrue);
    expect(find.text('Restored app settings.'), findsOneWidget);
  });

  testWidgets('settings that cannot be read are shown with the reason, and cannot be ticked',
      (t) async {
    backup.inspected = RestorePlan(
      archive: File('picked.plybackup'),
      createdAt: DateTime(2026, 11, 12),
      appVersion: 'test',
      projects: const [],
      settings: const RestoreSettings.refused(RestoreSettings.unreadable),
    );
    files.toPick = File('picked.plybackup');
    await pumpSettings(t);
    await tapTile(t, 'Restore from backup');
    expect(find.text('App settings'), findsOneWidget);
    expect(find.text('The app settings in this backup could not be read.'), findsOneWidget);
    expect(find.text('Restore app settings'), findsNothing);
    expect(t.widget<FilledButton>(find.widgetWithText(FilledButton, 'Nothing to restore')).onPressed,
        isNull);
  });

  testWidgets('a restore makes the home screen rebuild its library tabs', (t) async {
    final drafts = CountingDraftRepo();
    final c = ProviderContainer(overrides: [repositoryProvider.overrideWithValue(drafts)]);
    addTearDown(c.dispose);
    await t.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(home: HomeScreen(repository: drafts)),
    ));
    await t.pumpAndSettle();
    expect(drafts.lists, 1);
    c.read(libraryRevisionProvider.notifier).state++;
    await t.pumpAndSettle();
    expect(drafts.lists, 2);
  });

  testWidgets('a failed restore says the library was not changed and stays on the preview',
      (t) async {
    backup.inspected = await realPlan(t);
    backup.restoreError = const BackupException(BackupProblem.restoreFailed);
    files.toPick = File('picked.plybackup');
    final c = await pumpSettings(t);
    await tapTile(t, 'Restore from backup');
    await t.tap(find.text('Restore 2 projects'));
    await t.pumpAndSettle();
    expect(find.text('Restore failed'), findsOneWidget);
    expect(find.text('The restore did not finish. Your library was not changed.'), findsOneWidget);
    await t.tap(find.text('OK'));
    await t.pumpAndSettle();
    expect(find.text('Restore backup'), findsOneWidget);
    expect(c.read(libraryRevisionProvider), 0);
  });

  testWidgets('a file that is not a backup is refused with the reason', (t) async {
    backup.inspectError = const BackupException(BackupProblem.notABackup);
    files.toPick = File('photo.jpg');
    await pumpSettings(t);
    await tapTile(t, 'Restore from backup');
    expect(find.text('Cannot restore this backup'), findsOneWidget);
    expect(find.text('This file is not a Ply backup.'), findsOneWidget);
    expect(files.discards, 1);
  });

  testWidgets('cancelling the picker does nothing', (t) async {
    await pumpSettings(t);
    await tapTile(t, 'Restore from backup');
    expect(find.text('Restore backup'), findsNothing);
    expect(find.text('Cannot restore this backup'), findsNothing);
  });

  group('the service applies settings through the settings notifier', () {
    ProviderContainer container(FakeSettingsRepo settings) {
      final c = ProviderContainer(overrides: [
        appSettingsRepositoryProvider.overrideWithValue(settings),
        repositoryProvider.overrideWithValue(CountingDraftRepo()),
      ]);
      addTearDown(c.dispose);
      return c;
    }

    test('a full backup offers the settings in effect', () async {
      final c = container(FakeSettingsRepo());
      c.read(appSettingsProvider.notifier).setThemeMode(ThemeMode.dark);
      final current = await c.read(libraryBackupProvider).currentSettings!();
      expect(current.themeMode, ThemeMode.dark);
    });

    test('restored settings are saved first, then applied', () async {
      final repo = FakeSettingsRepo();
      final c = container(repo);
      await c.read(libraryBackupProvider).applySettings!(backedUp);
      expect(repo.saved, [backedUp]);
      expect(c.read(appSettingsProvider), backedUp);
    });

    test('settings that cannot be saved change nothing, and the error reaches the restore',
        () async {
      final repo = FakeSettingsRepo()..saveError = const FileSystemException('disk full');
      final c = container(repo);
      await expectLater(c.read(libraryBackupProvider).applySettings!(backedUp),
          throwsA(isA<FileSystemException>()));
      expect(c.read(appSettingsProvider), const AppSettings());
    });
  });

  group('thumbnails come back after a restore', () {
    testWidgets('a weaving draft', (t) async {
      await t.runAsync(() async {
        final dir = await Directory.systemTemp.createTemp('thumb_weave');
        addTearDown(() => dir.delete(recursive: true));
        await File(p.join(dir.path, 'd.wif')).writeAsBytes(wifBytes);
        final repo = ImageDraftRepo(dir);
        await repo.rebuildThumbnail('d');
        expect(_isPng(File(p.join(dir.path, 'd.png')).readAsBytesSync()), isTrue);
        await repo.rebuildThumbnail('missing'); // no draft: nothing written, nothing thrown
        expect(File(p.join(dir.path, 'missing.png')).existsSync(), isFalse);
      });
    });

    testWidgets('a knitting pattern', (t) async {
      await t.runAsync(() async {
        final dir = await Directory.systemTemp.createTemp('thumb_knit');
        addTearDown(() => dir.delete(recursive: true));
        await rebuildKnitThumbnail(ImageKnitRepo(), 'k', knitsDir: dir);
        expect(_isPng(File(p.join(dir.path, 'k.png')).readAsBytesSync()), isTrue);
        expect(File(p.join(dir.path, 'k.png.tmp')).existsSync(), isFalse);
      });
    });
  });
}

Future<ui.Image> _image() {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(const Rect.fromLTWH(0, 0, 4, 4), Paint()..color = Colors.red);
  return recorder.endRecording().toImage(4, 4);
}

bool _isPng(List<int> bytes) =>
    bytes.length > 8 && bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E;

/// A draft repository whose engine render is stood in for by a small image.
class ImageDraftRepo extends DraftRepository {
  ImageDraftRepo(Directory dir) : super(draftsDirOverride: dir);

  @override
  Future<ui.Image> renderDrawdown(String wifText, {required int cellPx}) => _image();
}

/// A knit repository whose engine read and render are stood in for.
class ImageKnitRepo extends KnitRepository {
  @override
  Future<KnitPatternDto> readPattern(String id) async => _AnyPattern();

  @override
  Future<ui.Image> render(KnitPatternDto pattern, {required int cellPx}) => _image();
}

/// Any pattern: the stand-in render never looks at it (and this keeps the test independent of the
/// DTO's fields).
class _AnyPattern implements KnitPatternDto {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
