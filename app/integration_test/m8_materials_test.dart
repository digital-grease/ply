// M8-01 device proof: materials and swatches against the REAL engine and filesystem (ADR 0016). A
// measured knitting swatch is recorded in Materials and swatches (the engine checks it and writes
// materials.json), a photo is added (kept under swatches/<id>.photos/), the swatch is linked to two
// knitting patterns from the shared project sheet (each pattern's sidecar gains the link), the
// knitting editor's Gauge & yardage calculator uses it and cites it through the engine's traced
// cast-on, and after a reopen the swatch is still there, linked twice, with its photo. The device's
// own materials.json is put back as it was.
//
//   flutter test integration_test/m8_materials_test.dart -d emulator-5554

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

import 'package:ply/src/data/draft_repository.dart';
import 'package:ply/src/data/knit_repository.dart';
import 'package:ply/src/data/library_backup.dart' show BackupCraft;
import 'package:ply/src/data/materials_repository.dart';
import 'package:ply/src/data/project_links_repository.dart';
import 'package:ply/src/models/draft_meta.dart';
import 'package:ply/src/models/material_record.dart';
import 'package:ply/src/rust/frb_generated.dart';
import 'package:ply/src/screens/knit_editor_screen.dart';
import 'package:ply/src/screens/materials_screen.dart';
import 'package:ply/src/state/editor_providers.dart';
import 'package:ply/src/state/knit_editor_state.dart';
import 'package:ply/src/state/material_providers.dart';
import 'package:ply/src/widgets/project_materials_sheet.dart';

/// A 1 x 1 PNG, a real image the photo strip can draw.
final List<int> onePixelPng = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==');

Future<void> settle(WidgetTester tester, {int frames = 20}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// On a device, enterText types through the real soft keyboard: it slides up, the form shrinks and
/// scrolls the field into view, and a tap made meanwhile can miss (the list ignores taps while it
/// scrolls). Close the keyboard, as a person would, and let the screen settle before the next tap.
Future<void> hideKeyboard(WidgetTester tester) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await settle(tester);
}

/// Bring [f] on screen, let the scroll finish, then tap it.
Future<void> tapShown(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await settle(tester, frames: 6);
  await tester.tap(f);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  testWidgets('a measured swatch with a photo, linked to two patterns, cited by the calculator',
      (tester) async {
    // A tap that misses fails here, where it missed, not as a puzzle several steps later.
    WidgetController.hitTestWarningShouldBeFatal = true;
    addTearDown(() => WidgetController.hitTestWarningShouldBeFatal = false);
    final materials = MaterialsRepository();
    final knits = KnitRepository();
    final links = ProjectLinksRepository();
    // Keep the device's own materials.json and put it back afterwards.
    final file = await materials.file();
    final before = await file.exists() ? await file.readAsBytes() : null;
    addTearDown(() async {
      if (before == null) {
        if (await file.exists()) await file.delete();
      } else {
        await file.writeAsBytes(before, flush: true);
      }
    });
    if (before != null) await file.delete();

    // The photo the "gallery" hands back.
    final tmp = await Directory.systemTemp.createTemp('m8_materials');
    addTearDown(() => tmp.delete(recursive: true));
    final picked = File(p.join(tmp.path, 'swatch.png'))..writeAsBytesSync(onePixelPng);

    final overrides = [
      repositoryProvider.overrideWithValue(DraftRepository()),
      swatchPhotoPickerProvider.overrideWithValue((_) async => picked.path),
    ];
    // A fresh app on [home] (a relaunch: new providers, read again from disk). The old app is taken
    // down first: pumping a new MaterialApp over it would keep its navigator, and the swatch form
    // still pushed on top would hide the new home.
    Future<void> launch(Widget home) async {
      await tester.pumpWidget(const SizedBox());
      await settle(tester, frames: 4);
      await tester.pumpWidget(ProviderScope(overrides: overrides, child: MaterialApp(home: home)));
    }

    // 1. Record a measured swatch through the form; the engine checks it and writes the file.
    await tester.pumpWidget(ProviderScope(
        overrides: overrides, child: const MaterialApp(home: MaterialsScreen(initialTab: 1))));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('add-swatch')));
    await settle(tester);
    await tester.enterText(find.byKey(const ValueKey('swatch-name')), 'Device swatch');
    await hideKeyboard(tester);
    await tapShown(tester, find.byKey(const ValueKey('swatch-craft-knitting')));
    await settle(tester, frames: 4);
    await tester.enterText(find.byKey(const ValueKey('swatch-date')), '2026-11-10');
    await hideKeyboard(tester);
    Future<void> type(String key, String text) async {
      final f = find.byKey(ValueKey(key));
      await tester.scrollUntilVisible(f, 200, scrollable: find.byType(Scrollable).first);
      await tester.enterText(f, text);
      await hideKeyboard(tester);
    }

    // Counted over 4 in, whatever units the device is set to.
    Future<void> overFourInches(String key) async {
      await type('$key-span', '4');
      await tapShown(tester, find.byKey(ValueKey('$key-unit')));
      await settle(tester);
      await tester.tap(find.text('in').last);
      await settle(tester);
    }

    await type('swatch-before-width', '4.5');
    await type('swatch-before-across', '22');
    await overFourInches('swatch-before-across');
    await type('swatch-after-width', '5');
    await type('swatch-after-length', '5');
    await type('swatch-after-across', '20');
    await overFourInches('swatch-after-across');
    await type('swatch-finishing', 'washed, dried flat');
    await type('swatch-mass', '9');
    await tapShown(tester, find.byKey(const ValueKey('swatch-save')));
    await settle(tester, frames: 30);

    final saved = await materials.load();
    expect(saved.status, MaterialsFileStatus.ok);
    final swatch = saved.library.swatches.single;
    expect(swatch.name, 'Device swatch');
    expect(swatch.after.across!.value.count, 20);
    expect(swatch.after.across!.value.over, const Length(4, LengthUnit.inch));
    expect(swatch.after.across!.source, ValueSource.measured);
    expect(swatch.before.length, isNull, reason: 'nothing entered, nothing invented');
    expect((jsonDecode(await file.readAsString()) as Map)['schema_version'],
        kMaterialsSchemaVersion);
    expect(await file.readAsString(), isNot(contains('per_10cm')),
        reason: 'derived figures are never stored');
    final photos = await materials.photoDir(swatch.id);
    addTearDown(() async {
      if (await photos.exists()) await photos.delete(recursive: true);
    });

    // The engine's report on the saved swatch: the width grew by 1/9 after washing.
    final report = await materials.swatchReport(swatch);
    expect(report.hasErrors, isFalse);
    expect(report.figures.map((f) => f.code), contains('swatch.width_change'));

    // 2. Add a photo (the form saved in place, so the photo strip is there now).
    final addPhoto = find.text('Add');
    await tester.scrollUntilVisible(addPhoto, 200, scrollable: find.byType(Scrollable).first);
    await tapShown(tester, addPhoto);
    await settle(tester);
    await tester.tap(find.text('Choose from gallery'));
    await settle(tester, frames: 30);
    final stored = photos.listSync().whereType<File>().toList();
    expect(stored, hasLength(1));
    expect(stored.single.readAsBytesSync(), onePixelPng);

    // 3. Two knitting patterns, each linked to the swatch from the shared sheet.
    final blank = KnitEditorState(pattern: await knits.blank()).resizeChart(8, 8).pattern;
    final ids = <String>[];
    for (final name in ['Hat for links', 'Mitts for links']) {
      final id = await knits.saveKnit(
          pattern: blank,
          meta: DraftMeta(
              name: name, craft: 'Knitting', savedAt: DateTime.now(), lastOpened: DateTime.now()));
      ids.add(id);
      addTearDown(() => knits.deleteKnit(id));
    }
    for (final id in ids) {
      await launch(Scaffold(body: ProjectMaterialsSheet(craft: BackupCraft.knitting, id: id)));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('link-swatch')));
      await settle(tester);
      await tester.tap(find.byKey(ValueKey('link-swatch-${swatch.id}')));
      await settle(tester, frames: 20);
      expect((await links.read(BackupCraft.knitting, id)).linksSwatch(swatch.id), isTrue);
    }
    final usage = await links.usage();
    expect(usage.ofSwatch(swatch.id).map((r) => r.id), unorderedEquals(ids));

    // 4. The knitting editor's calculator uses the swatch and cites it, through the engine.
    await launch(KnitEditorScreen(openId: ids.first));
    await settle(tester, frames: 30);
    await tester.tap(find.byTooltip('More'));
    await settle(tester);
    await tester.tap(find.text('Gauge & yardage'));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('use-swatch')));
    await settle(tester);
    await tester.tap(find.textContaining('Device swatch').last);
    await settle(tester);
    final width = find.widgetWithText(TextFormField, 'Finished width (in)');
    await tester.ensureVisible(width);
    await tester.enterText(width, '20');
    await hideKeyboard(tester);
    await tapShown(tester, find.widgetWithText(FilledButton, 'Calculate cast-on'));
    await settle(tester, frames: 30);
    // 20 sts over 4 in is 5 sts per in: (20 in + 0) x 5 = 100.
    expect(find.text('Cast on 100 stitches'), findsOneWidget);
    expect(
        find.text('Stitch gauge: 20 sts per 4 in, measured after finishing (washed, dried flat), '
            'swatch Device swatch 2026-11-10'),
        findsOneWidget);

    // 5. Reopen Materials: the swatch is there, used by two patterns, with its photo.
    await launch(const MaterialsScreen(initialTab: 1));
    await settle(tester, frames: 30);
    expect(find.text('Device swatch'), findsOneWidget);
    expect(find.textContaining('Used by 2 projects'), findsOneWidget);
    await tester.tap(find.text('Device swatch'));
    await settle(tester, frames: 30);
    final photo = find.byType(Image);
    await tester.scrollUntilVisible(photo, 200, scrollable: find.byType(Scrollable).first);
    expect(photo, findsOneWidget);
  });
}
