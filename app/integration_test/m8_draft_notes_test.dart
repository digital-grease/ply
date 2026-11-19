// A saved weaving draft's notes on a device (ADR 0007, amendment of 2026-11-18, item 7), through the
// real engine and the device's file system, over a temp directory (the app's own library is never
// touched).
//
// - A draft saved by an earlier build with notes over 1 MB stops a backup, which says to shorten
//   them and where. Its menu in the library opens the notes in full, read-only and a piece at a
//   time (no text field that large); nothing is written until a choice is confirmed; keeping the
//   first 10,000 characters saves the notes alone (every other key kept, the pattern file
//   untouched), the editable field opens from then on, and the backup is made.
// - In the editor, Notes in the overflow menu changes the notes without marking the draft edited,
//   and the editor's Save afterwards keeps them.
//
//   flutter test integration_test/m8_draft_notes_test.dart -d emulator-5554

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

import 'package:ply/src/data/draft_repository.dart';
import 'package:ply/src/data/knit_repository.dart';
import 'package:ply/src/data/library_backup.dart';
import 'package:ply/src/diagnostics/crash_reporter.dart' show kPlyAppVersion;
import 'package:ply/src/models/draft_meta.dart';
import 'package:ply/src/rust/frb_generated.dart';
import 'package:ply/src/screens/editor_screen.dart';
import 'package:ply/src/screens/library_screen.dart';
import 'package:ply/src/state/draft_editor_notifier.dart';
import 'package:ply/src/state/editor_providers.dart';
import 'package:ply/src/widgets/draft_notes_dialog.dart' show keepFirstNotes;

const String kTwillWif = '''[WIF]
Version=1.1
[WEAVING]
Shafts=4
Treadles=4
Rising Shed=true
[WARP]
Threads=4
Units=Inches
[WEFT]
Threads=4
[COLOR TABLE]
1=0,0,0
2=255,255,255
[THREADING]
1=1
2=2
3=3
4=4
[TIEUP]
1=1,2
2=2,3
3=3,4
4=1,4
[TREADLING]
1=1
2=2
3=3
4=4
[WARP COLORS]
1=1
2=1
3=1
4=1
[WEFT COLORS]
1=2
2=2
3=2
4=2
''';

/// Frames with real time between them (the engine and the files answer on their own time).
Future<void> settle(WidgetTester tester, {int frames = 20}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Pump frames until [finder] finds something, for at most [seconds].
Future<void> pumpUntil(WidgetTester tester, Finder finder, {int seconds = 30}) async {
  for (var i = 0; i < seconds * 20 && finder.evaluate().isEmpty; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(finder, findsWidgets, reason: 'still missing after $seconds s');
}

/// A fresh app on [screen], with the draft repository over the temp directory at its root.
Future<void> openFresh(WidgetTester tester, Widget screen, DraftRepository drafts) async {
  await tester.pumpWidget(const SizedBox());
  await settle(tester, frames: 4);
  await tester.pumpWidget(ProviderScope(
    overrides: [repositoryProvider.overrideWithValue(drafts)],
    child: MaterialApp(home: screen),
  ));
  await settle(tester, frames: 40);
}

Finder get notesField => find.byKey(const ValueKey('draft-notes-field'));

String fieldText(WidgetTester tester) => tester.widget<TextField>(notesField).controller!.text;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
    // A tap that would land on another widget fails where it happens instead of later.
    WidgetController.hitTestWarningShouldBeFatal = true;
  });
  tearDownAll(() => WidgetController.hitTestWarningShouldBeFatal = false);

  late Directory docs;
  late DraftRepository drafts;
  setUp(() async {
    docs = await Directory.systemTemp.createTemp('m8_draft_notes');
    drafts =
        DraftRepository(draftsDirOverride: Directory(p.join(docs.path, 'drafts'))..createSync());
  });
  tearDown(() async {
    if (await docs.exists()) await docs.delete(recursive: true);
  });

  File sidecar(String id) => File(p.join(docs.path, 'drafts', '$id.json'));
  Map<String, dynamic> onDisk(String id) =>
      jsonDecode(sidecar(id).readAsStringSync()) as Map<String, dynamic>;

  testWidgets('notes over 1 MB stop a backup until they are shortened from the library',
      (tester) async {
    final now = DateTime.now();
    final id = await drafts.saveDto(await drafts.parseDoc(kTwillWif),
        meta: DraftMeta(name: 'Old towel', savedAt: now, lastOpened: now), sourceWif: kTwillWif);
    final wif = File(p.join(docs.path, 'drafts', '$id.wif'))..setLastModifiedSync(DateTime(2020));
    // As an earlier build saved it: notes of any length, and a key this build does not know.
    final longNotes = List.generate(40000, (i) => 'Pick ${i + 1}: tabby, then pattern.').join('\n');
    expect(longNotes.length, greaterThan(1024 * 1024));
    final original = {
      ...onDisk(id),
      'notes': longNotes,
      'futureKey': {'kept': true}
    };
    sidecar(id).writeAsStringSync(jsonEncode(original));

    final backup = LibraryBackup(
      documentsDir: () async => docs,
      currentKnitSchemaVersion: KnitRepository().schemaVersion,
      appVersion: kPlyAppVersion,
      limits: BackupLimits.forThisDevice(),
    );
    await expectLater(
        backup.planBackup(),
        throwsA(isA<BackupException>().having(
            (e) => e.message,
            'message',
            'The notes of "Old towel" are too long to back up. Shorten them to 10,000 characters '
                "or fewer: on the Weaving tab, open the draft's menu and choose Notes.")));

    // The draft's menu in the library: the notes open in full, read-only, with the choices.
    await openFresh(tester, LibraryScreen(repository: drafts), drafts);
    await pumpUntil(tester, find.byTooltip('Pattern actions'));
    await tester.tap(find.byTooltip('Pattern actions'));
    await settle(tester);
    await tester.tap(find.text('Notes'));
    await pumpUntil(tester, find.byKey(const ValueKey('draft-notes-full')), seconds: 60);
    expect(notesField, findsNothing, reason: 'no text field that large');
    expect(find.textContaining('These notes have 1,308,893 characters'), findsOneWidget);
    expect(find.textContaining('Pick 1: tabby, then pattern.'), findsOneWidget);
    expect(find.text('Shorten them by hand'), findsNothing);

    // Keep the first 10,000 characters: shown first, written only on Keep.
    await tester.tap(find.text('Keep the first 10,000 characters'));
    await settle(tester);
    expect(find.text('Keep the first 10,000 characters?'), findsOneWidget);
    expect(onDisk(id)['notes'], longNotes, reason: 'nothing written before Keep');
    await tester.tap(find.widgetWithText(FilledButton, 'Keep'));
    await pumpUntil(tester, find.text('Notes saved.'));
    expect(onDisk(id), {...original, 'notes': keepFirstNotes(longNotes)});
    expect(wif.lastModifiedSync(), DateTime(2020), reason: 'the pattern file is not rewritten');

    // Within the limit now, so the editable field opens from then on.
    await tester.tap(find.byTooltip('Pattern actions'));
    await settle(tester);
    await tester.tap(find.text('Notes'));
    await pumpUntil(tester, notesField);
    expect(fieldText(tester), keepFirstNotes(longNotes));
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await settle(tester);

    final plan = await backup.planBackup();
    expect(plan.files.map((f) => f.archivePath), contains('drafts/$id.json'));
    await tester.pumpWidget(const SizedBox());
    await settle(tester, frames: 4);
  });

  testWidgets('in the editor, a notes edit leaves the draft unedited and Save keeps it',
      (tester) async {
    final now = DateTime.now();
    final meta = DraftMeta(
        name: 'Notes twill', notes: 'From the first save.', savedAt: now, lastOpened: now);
    final id =
        await drafts.saveDto(await drafts.parseDoc(kTwillWif), meta: meta, sourceWif: kTwillWif);

    await openFresh(
        tester, EditorScreen(wifText: kTwillWif, title: 'Notes twill', id: id, meta: meta), drafts);
    await pumpUntil(tester, find.byTooltip('More actions'));
    await tester.tap(find.byTooltip('More actions'));
    await settle(tester);
    await tester.tap(find.text('Notes…'));
    await pumpUntil(tester, notesField);
    expect(fieldText(tester), 'From the first save.');
    await tester.enterText(notesField, 'Changed in the editor.');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await pumpUntil(tester, find.text('Notes saved.'));
    expect(onDisk(id)['notes'], 'Changed in the editor.');
    final element = tester.element(find.byType(EditorScreen));
    final container = ProviderScope.containerOf(element);
    expect(container.read(draftEditorProvider).dirtyStructural, isFalse);

    // The editor's Save, with the meta it opened with, keeps the new notes.
    await tester.tap(find.byTooltip('Save'));
    await settle(tester, frames: 40);
    expect(onDisk(id)['notes'], 'Changed in the editor.');
    expect(onDisk(id)['lastOpened'], isNot(meta.toJson()['lastOpened']), reason: 'the save landed');
    await tester.pumpWidget(const SizedBox());
    await settle(tester, frames: 4);
  });
}
