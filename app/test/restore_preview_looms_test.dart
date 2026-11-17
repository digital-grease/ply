import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/app_settings_repository.dart';
import 'package:ply/src/data/library_backup.dart';
import 'package:ply/src/models/app_settings.dart';
import 'package:ply/src/screens/restore_preview_screen.dart';
import 'package:ply/src/screens/settings_screen.dart';
import 'package:ply/src/state/backup_providers.dart';
import 'package:ply/src/state/loom_providers.dart';
import 'package:ply/src/state/theme_providers.dart';

import 'backup_test_support.dart';
import 'library_backup_looms_test.dart' show loomA, loomC, loomService, writeLooms;
import 'loom_test_support.dart';

// The restore preview's "My looms" section (ADR 0014): new looms listed, different ones offered as
// copies (ticked by default, untickable), the button and the closing sentence counting looms.

void main() {
  testWidgets('the preview lists the backup\'s looms and restores the ticked ones', (t) async {
    t.view.physicalSize = const Size(1200, 4000);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    late RestorePlan plan;
    await t.runAsync(() async {
      docs = await Directory.systemTemp.createTemp('ui_docs');
      work = await Directory.systemTemp.createTemp('ui_work');
      final source = await Directory.systemTemp.createTemp('ui_src');
      addTearDown(() async {
        await docs.delete(recursive: true);
        await work.delete(recursive: true);
        await source.delete(recursive: true);
      });
      await seedLibrary(source);
      await put(
          source,
          'drafts/d1.json',
          sidecar('Twill', 'Weaving', extra: {
            'loomPlan': {'loomId': 'loom-c', 'loomName': 'Gamma'},
          }));
      await writeLooms(source, [loomA, loomC]);
      final archive = await backUp(loomService(into: source));
      await writeLooms(docs, [loomC.copyWith(notes: 'edited here')]);
      plan = await loomService().inspectBackup(archive);
    });
    final backup = FakeBackup()..inspected = plan;
    String? closing;
    await t.pumpWidget(ProviderScope(
      overrides: [
        libraryBackupProvider.overrideWithValue(backup),
        loomRepositoryProvider.overrideWithValue(FakeLoomRepository()),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  final r = await Navigator.of(context).push<RestoreResult>(
                      MaterialPageRoute(builder: (_) => RestorePreviewScreen(plan: plan)));
                  if (r != null) closing = restoredMessage(r);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();

    expect(find.text('My looms'), findsOneWidget);
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Different from My looms (1)'), findsOneWidget);
    expect(
        find.text('Ticked looms are added as copies. Your looms are not changed.'), findsOneWidget);
    expect(
        find.text('Add as "Gamma (restored)". The draft from this backup planned for it will use '
            'the copy.'),
        findsOneWidget);
    expect(find.text('Restore 4 projects and 2 looms'), findsOneWidget);

    await t.tap(find.widgetWithText(CheckboxListTile, 'Gamma'));
    await t.pumpAndSettle();
    expect(find.text('Restore 4 projects and 1 loom'), findsOneWidget);
    await t.tap(find.text('Restore 4 projects and 1 loom'));
    await t.pumpAndSettle();
    expect(backup.skippedLooms, {'loom-c'});
    expect(closing, 'Restored 4 projects and 1 loom.');
  });

  test('the closing sentence names projects, looms and settings', () {
    expect(restoredMessage(const RestoreResult([], loomsRestored: 2)), 'Restored 2 looms.');
    expect(restoredMessage(const RestoreResult([], loomsRestored: 1, settingsRestored: true)),
        'Restored 1 loom and app settings.');
    expect(restoredMessage(const RestoreResult([])), isNull);
  });

  test('the closing sentence says which drafts now use a restored copy of their loom', () {
    expect(
        restoredMessage(const RestoreResult([(craft: BackupCraft.weaving, id: 'd')],
            loomsRestored: 1, draftsRelinked: 1)),
        'Restored 1 project and 1 loom. 1 draft now uses the restored copy of its loom.');
    expect(restoredMessage(const RestoreResult([], loomsRestored: 1, draftsRelinked: 3)),
        'Restored 1 loom. 3 drafts now use the restored copy of their loom.');
  });

  testWidgets('the backup summary says My looms was left out, and why', (t) async {
    final backup = FakeBackup()
      ..plan = BackupPlan(
        createdAt: DateTime(2026, 11, 15),
        appVersion: 'test',
        files: const [],
        projectCounts: const {
          BackupCraft.weaving: 1,
          BackupCraft.knitting: 0,
          BackupCraft.nalbinding: 0
        },
        photoCount: 0,
        loomsLeftOut: BackupPlan.loomsNewer,
      );
    t.view.physicalSize = const Size(1200, 3000);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    await t.pumpWidget(ProviderScope(
      overrides: [
        appSettingsRepositoryProvider.overrideWithValue(_Settings()),
        libraryBackupProvider.overrideWithValue(backup),
        loomRepositoryProvider.overrideWithValue(FakeLoomRepository()),
      ],
      child: const MaterialApp(home: SettingsScreen()),
    ));
    await t.pumpAndSettle();
    await t.tap(find.text('Back up library'));
    await t.pumpAndSettle();
    expect(find.text(BackupPlan.loomsNewer), findsOneWidget);
  });
}

class _Settings extends AppSettingsRepository {
  @override
  Future<AppSettings> load() async => const AppSettings();
  @override
  Future<void> save(AppSettings settings) async {}
}
