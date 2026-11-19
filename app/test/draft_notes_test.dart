import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:ply/src/data/backup_file_access.dart';
import 'package:ply/src/data/draft_notes_file.dart';
import 'package:ply/src/data/draft_repository.dart';
import 'package:ply/src/data/library_backup.dart' show BackupCraft;
import 'package:ply/src/data/project_links_repository.dart';
import 'package:ply/src/data/sidecar_writes.dart';
import 'package:ply/src/models/draft_doc.dart';
import 'package:ply/src/models/draft_issue.dart';
import 'package:ply/src/models/draft_meta.dart';
import 'package:ply/src/models/loom_type.dart';
import 'package:ply/src/models/project_materials.dart';
import 'package:ply/src/screens/editor_screen.dart';
import 'package:ply/src/screens/library_screen.dart';
import 'package:ply/src/state/backup_providers.dart' show backupFileAccessProvider;
import 'package:ply/src/state/draft_editor_notifier.dart';
import 'package:ply/src/state/editor_providers.dart';
import 'package:ply/src/widgets/draft_notes_dialog.dart';

// A saved weaving draft's notes (ADR 0007, amendment of 2026-11-18, item 7): the notes editor shows
// them in full with a count against the 10,000-character limit and refuses to save past it, the
// repository writes the sidecar's `notes` alone under the sidecar lock, and an editor's save never
// undoes a notes edit (nor a notes edit a save), in either order. Real files in temp directories;
// the engine's calls are stood in.

const String id = 'd1';
const String wif = '[WIF]\nVersion=1.1\n[WEAVING]\nShafts=4\nTreadles=4\n';

/// A sidecar as Ply writes it, with keys this build does not know and the links of ADR 0016.
Map<String, Object?> sidecarJson({String notes = 'Sett 24 ends per inch.'}) => {
      'name': 'Towel',
      'craft': 'Weaving',
      'author': 'Ada',
      'notes': notes,
      'loomType': 'Jack',
      'overshotTreadling': false,
      'savedAt': '2026-01-01T00:00:00.000Z',
      'lastOpened': '2026-01-02T00:00:00.000Z',
      'schemaVersion': 1,
      'futureKey': {'kept': true},
      'materials': {
        'yarns': [],
        'swatches': [
          {'swatchId': 'sw-1', 'swatchName': 'Sample'}
        ],
      },
    };

File sidecarFile(Directory drafts) => File(p.join(drafts.path, '$id.json'));
File wifFile(Directory drafts) => File(p.join(drafts.path, '$id.wif'));
Map<String, dynamic> onDisk(Directory drafts) =>
    jsonDecode(sidecarFile(drafts).readAsStringSync()) as Map<String, dynamic>;

/// Write draft [id]'s `.wif` (dated in the past, so a rewrite shows) and its sidecar.
void seedDraft(Directory drafts, Map<String, Object?> json) {
  wifFile(drafts)
    ..writeAsStringSync(wif)
    ..setLastModifiedSync(DateTime(2020));
  sidecarFile(drafts).writeAsStringSync(jsonEncode(json));
}

/// The meta an editor opens a saved draft with, read from disk.
DraftMeta metaOnDisk(Directory drafts) => DraftMeta.fromJson(onDisk(drafts));

Future<ui.Image> stubImage() {
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    Uint8List.fromList(const [0, 0, 0, 255]),
    1,
    1,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  return completer.future;
}

/// The real repository over [dir], with the engine's calls stood in (a 4 x 4 straight draw).
class DiskRepo extends DraftRepository {
  DiskRepo(Directory dir) : super(draftsDirOverride: dir);

  int validateCount = 0;
  int saveCount = 0;

  /// When set, an editor's save waits on it before writing anything.
  Completer<void>? saveGate;

  /// When set, reading a draft's notes waits on it (large notes take a moment to read).
  Completer<void>? readGate;

  @override
  Future<({String notes, String digest})> readNotesWithDigest(String id) async {
    if (readGate != null) await readGate!.future;
    return super.readNotesWithDigest(id);
  }

  @override
  Future<DraftDoc> parseDoc(String wifText) async =>
      DraftDoc.blank(shafts: 4, treadles: 4).copyWith(
        threading: const [
          [1],
          [2],
          [3],
          [4],
        ],
        drive: DraftTreadled(tieup: const [
          [1],
          [2],
          [3],
          [4],
        ], treadling: const [
          [1],
          [2],
          [3],
          [4],
        ]),
        warpColors: const [0, 0, 0, 0],
        weftColors: const [0, 0, 0, 0],
      );

  @override
  Future<ui.Image> renderDto(
    DraftDoc doc, {
    required int cellPx,
    bool gridlines = false,
    int floatThreshold = 0,
    bool threadTexture = false,
  }) =>
      stubImage();

  @override
  Future<ui.Image> renderDrawdown(String wifText, {required int cellPx}) =>
      Future.error(StateError('no engine in host tests'));

  @override
  Future<void> rebuildThumbnail(String id) async {}

  @override
  Future<List<DraftIssue>> validateDto(DraftDoc doc) async {
    validateCount++;
    return const [];
  }

  @override
  Future<String> saveDto(DraftDoc doc,
      {required DraftMeta meta, String? id, String? sourceWif}) async {
    saveCount++;
    if (saveGate != null) await saveGate!.future;
    return super.saveDto(doc, meta: meta, id: id, sourceWif: sourceWif);
  }
}

/// Let real file reads and writes finish between frames (they run outside the test's fake clock).
Future<void> settle(WidgetTester tester, {int rounds = 20}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// A tall phone screen, so a whole menu or dialog is on screen.
void tallPhone(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 2.6;
  addTearDown(tester.view.reset);
}

Finder get notesField => find.byKey(const ValueKey('draft-notes-field'));
String fieldText(WidgetTester tester) => tester.widget<TextField>(notesField).controller!.text;
Finder get fullNotes => find.byKey(const ValueKey('draft-notes-full'));

/// [n] with a comma between thousands, as the notes editor writes it.
String thousands(int n) =>
    n.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');

/// Back, as the system back button does it: the top route is asked to pop.
Future<void> systemBack(WidgetTester tester) async {
  await tester.state<NavigatorState>(find.byType(Navigator).first).maybePop();
  await tester.pumpAndSettle();
}

/// The system save dialog, stood in: what it was asked to save, and what it answers.
class FakeSaveFile {
  final saved = <(String, Uint8List, String?)>[];
  bool result = true;
  Object? error;

  /// When set, the save waits on it (a desktop writes the file after its dialog returns).
  Completer<void>? gate;

  Future<bool> call(String fileName, Uint8List bytes, {String? dialogTitle}) async {
    if (gate != null) await gate!.future;
    if (error != null) throw error!;
    saved.add((fileName, bytes, dialogTitle));
    return result;
  }
}

/// [FakeSaveFile] as the app's file access, for the screens.
class FakeFileAccess implements BackupFileAccess {
  FakeFileAccess(this.files);
  final FakeSaveFile files;

  @override
  Future<bool> save(String fileName, Uint8List bytes, {String dialogTitle = 'Save backup'}) =>
      files(fileName, bytes, dialogTitle: dialogTitle);

  @override
  Future<File?> pick() async => null;

  @override
  Future<void> discardPicked() async {}
}

/// [text] put back together from its [pieces] (see [notesPieces]): between two pieces there is
/// nothing, or the line break the first one ended at.
String rejoin(String text, List<(int, int)> pieces) {
  final rebuilt = StringBuffer();
  for (var i = 0; i < pieces.length; i++) {
    final (start, end) = pieces[i];
    rebuilt.write(text.substring(start, end));
    if (i + 1 < pieces.length) rebuilt.write(text.substring(end, pieces[i + 1].$1));
  }
  return rebuilt.toString();
}

void main() {
  group('the notes editor', () {
    /// Open the notes editor on [notes]; `result()` is what it resolved to (null until then, and
    /// on Cancel).
    Future<String? Function()> openDialog(WidgetTester tester, String notes,
        {FakeSaveFile? files}) async {
      tallPhone(tester);
      final save = files ?? FakeSaveFile();
      String? out;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: ElevatedButton(
                onPressed: () async => out = await showDraftNotesDialog(ctx,
                    draftName: 'Towel', notes: notes, saveFile: (n, b) => save(n, b)),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return () => out;
    }

    testWidgets('shows the notes in full, with a count against the limit', (tester) async {
      final notes = List.generate(300, (i) => 'Line ${i + 1}: ${'x' * 21}').join('\n');
      expect(notes.length, 9491);
      await openDialog(tester, notes);
      expect(find.text('Notes'), findsWidgets);
      expect(find.text('Towel'), findsOneWidget, reason: 'names the draft');
      expect(find.text(kDraftNotesKeptLine), findsOneWidget, reason: 'says what these notes are');
      final field = tester.widget<TextField>(notesField);
      expect(field.controller!.text, notes, reason: 'every line, never truncated');
      expect(field.maxLength, isNull, reason: 'no limit that would cut the text');
      expect(field.inputFormatters ?? const <TextInputFormatter>[], isEmpty);
      expect(find.text('9,491 of 10,000 characters'), findsOneWidget);

      await tester.enterText(notesField, '  Sett 24.  ');
      await tester.pump();
      expect(find.text('8 of 10,000 characters'), findsOneWidget,
          reason: 'counted as saved, without spaces at either end');
    });

    testWidgets('Save returns the notes without spaces at either end; Cancel returns nothing',
        (tester) async {
      var result = await openDialog(tester, 'old');
      await tester.enterText(notesField, '\n  Washed in cold water.  \n');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(result(), 'Washed in cold water.');

      result = await openDialog(tester, 'old');
      await tester.enterText(notesField, 'changed my mind');
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(result(), isNull);
      expect(notesField, findsNothing, reason: 'closed');
    });

    testWidgets('Save is refused past the limit with the save dialog\'s sentence, nothing cut',
        (tester) async {
      final result = await openDialog(tester, '');
      expect(find.textContaining('Notes can be at most'), findsNothing);
      final long = 'n' * (DraftMeta.maxNotesChars + 1);
      await tester.enterText(notesField, long);
      await tester.pump();
      expect(find.text('10,001 of 10,000 characters'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(
          find.text('Notes can be at most 10,000 characters (these have 10,001).'), findsOneWidget);
      expect(
          notesTooLongText(10001), 'Notes can be at most 10,000 characters (these have 10,001).');
      expect(result(), isNull, reason: 'still open');
      expect(fieldText(tester), long, reason: 'left as typed');

      // Within the limit again, the sentence goes and Save returns the notes.
      await tester.enterText(notesField, 'n' * DraftMeta.maxNotesChars);
      await tester.pump();
      expect(find.textContaining('Notes can be at most'), findsNothing);
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(result(), 'n' * DraftMeta.maxNotesChars);
    });

    testWidgets('a tap outside never closes it, and Back asks before discarding a change',
        (tester) async {
      var result = await openDialog(tester, 'Sett 24.');
      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();
      expect(notesField, findsOneWidget, reason: 'a tap outside does not close it');
      // Back with nothing changed closes it.
      await systemBack(tester);
      expect(notesField, findsNothing);
      expect(result(), isNull);

      result = await openDialog(tester, 'Sett 24.');
      await tester.enterText(notesField, 'Sett 24, beaten firmly.');
      await tester.pump();
      await systemBack(tester);
      expect(find.text('Discard your changes?'), findsOneWidget);
      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();
      expect(fieldText(tester), 'Sett 24, beaten firmly.', reason: 'still there');
      await systemBack(tester);
      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();
      expect(notesField, findsNothing);
      expect(result(), isNull, reason: 'nothing to save');
    });

    testWidgets('notes a little over the limit open read-only, and can be shortened by hand',
        (tester) async {
      final old = List.generate(1000, (i) => 'Pick ${i + 1}: weft ${'y' * 18}').join('\n');
      expect(old.length, 33892);
      final result = await openDialog(tester, old);
      expect(notesField, findsNothing, reason: 'not in an editable field at first');
      expect(fullNotes, findsOneWidget);
      expect(find.textContaining('These notes have 33,892 characters, more than the 10,000'),
          findsOneWidget);
      await tester.tap(find.text('Shorten them by hand'));
      await tester.pumpAndSettle();
      expect(fieldText(tester), old, reason: 'in full');
      expect(
          find.text('Notes can be at most 10,000 characters (these have 33,892).'), findsOneWidget,
          reason: 'said from the start');
      expect(find.text('33,892 of 10,000 characters'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(result(), isNull, reason: 'refused, never cut short');
      expect(fieldText(tester), old);

      final shortened = old.substring(0, 4000).trim();
      await tester.enterText(notesField, shortened);
      await tester.pump();
      expect(find.textContaining('Notes can be at most'), findsNothing);
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(result(), shortened);
    });

    testWidgets('long notes open read-only, a piece at a time, with no editable field',
        (tester) async {
      final old = List.generate(12000, (i) => 'Pick ${i + 1}: tabby, then pattern.').join('\n');
      expect(old.length, greaterThan(kNotesEditableChars));
      final result = await openDialog(tester, old);
      expect(notesField, findsNothing);
      expect(find.text('Shorten them by hand'), findsNothing, reason: 'too long to edit there');
      expect(find.textContaining('These notes have ${thousands(old.length)} characters'),
          findsOneWidget);
      final pieces = notesPieces(old);
      final built = find.descendant(of: fullNotes, matching: find.byType(Text)).evaluate().length;
      expect(built, lessThan(pieces.length ~/ 10),
          reason: 'only the pieces on screen are laid out');
      expect(find.textContaining('Pick 1: tabby'), findsOneWidget, reason: 'starts at the start');
      // The view ends with the notes' end.
      await tester.drag(fullNotes, const Offset(0, -1000000));
      await tester.pumpAndSettle();
      expect(find.textContaining('Pick 12000: tabby, then pattern.'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(result(), isNull);
    });

    testWidgets('Save as a text file saves them in full and writes nothing to the draft',
        (tester) async {
      final old = 'Long notes from an earlier build. ' * 2000;
      final files = FakeSaveFile();
      final result = await openDialog(tester, old, files: files);
      await tester.tap(find.text('Save as a text file'));
      await tester.pumpAndSettle();
      expect(files.saved.single.$1, 'Towel notes.txt');
      expect(utf8.decode(files.saved.single.$2), old, reason: 'in full, as they are');
      expect(find.text('Saved as a text file.'), findsOneWidget);
      expect(result(), isNull, reason: 'still open: nothing chosen yet');

      // Cancelled in the system dialog: nothing said. A failure says so.
      files.result = false;
      await tester.tap(find.text('Save as a text file'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('draft-notes-file-status')), findsNothing);
      files.error = const FileSystemException('disk full');
      await tester.tap(find.text('Save as a text file'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Could not save the text file'), findsOneWidget);
      expect(result(), isNull);
    });

    testWidgets('Keep the first 10,000 characters shows them first, and keeps them on Keep',
        (tester) async {
      final old = List.generate(600, (i) => 'Row ${i + 1}: ${'z' * 40}').join('\n');
      final result = await openDialog(tester, old);
      await tester.tap(find.text('Keep the first 10,000 characters'));
      await tester.pumpAndSettle();
      final kept = keepFirstNotes(old);
      expect(kept.length, lessThanOrEqualTo(10000));
      expect(find.text('Keep the first 10,000 characters?'), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const ValueKey('draft-notes-kept'))).data, kept);
      expect(
          find.text('The notes become the ${thousands(kept.length)} characters below, and the '
              'other ${thousands(old.length - kept.length)} are removed. Save them as a text '
              'file first to keep them all.'),
          findsOneWidget);
      expect(result(), isNull, reason: 'nothing chosen until Keep');

      // Back, the button or the system's, returns to the notes.
      await tester.tap(find.widgetWithText(TextButton, 'Back'));
      await tester.pumpAndSettle();
      expect(fullNotes, findsOneWidget);
      await tester.tap(find.text('Keep the first 10,000 characters'));
      await tester.pumpAndSettle();
      await systemBack(tester);
      expect(fullNotes, findsOneWidget);
      expect(result(), isNull);

      await tester.tap(find.text('Keep the first 10,000 characters'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Keep'));
      await tester.pumpAndSettle();
      expect(result(), kept);
    });

    testWidgets('Clear notes asks first', (tester) async {
      final old = 'Long notes from an earlier build. ' * 400;
      final result = await openDialog(tester, old);
      await tester.tap(find.text('Clear notes'));
      await tester.pumpAndSettle();
      expect(find.text('Clear these notes?'), findsOneWidget);
      expect(
          find.text('All ${thousands(old.trim().length)} characters are removed from the notes. '
              'Save them as a text file first to keep them all.'),
          findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Back'));
      await tester.pumpAndSettle();
      expect(fullNotes, findsOneWidget);
      expect(result(), isNull);

      await tester.tap(find.text('Clear notes'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Clear'));
      await tester.pumpAndSettle();
      expect(result(), '');
    });

    test('keeping the first 10,000 characters never splits a character', () {
      const yarn = '\u{1F9F6}'; // one character, two code units
      const family = '\u{1F469}\u200D\u{1F469}\u200D\u{1F467}'; // one character, eight
      const flag = '\u{1F1F8}\u{1F1EA}'; // one flag, four
      const accented = 'e\u0301'; // a letter and its accent, two
      expect(keepFirstNotes('  ${'a' * 9999}$yarn${'b' * 5000}'), 'a' * 9999,
          reason: 'the character would be cut in half, so it is left out');
      expect(keepFirstNotes('${'a' * 9998}$yarn${'b' * 10}'), '${'a' * 9998}$yarn');
      expect(keepFirstNotes('${'a' * 9995}$family${'b' * 10}'), 'a' * 9995);
      expect(keepFirstNotes('${'a' * 9992}$family${'b' * 10}'), '${'a' * 9992}$family');
      expect(keepFirstNotes('${'a' * 9998}$flag${'b' * 10}'), 'a' * 9998);
      expect(keepFirstNotes('${'a' * 9999}$accented${'b' * 10}'), 'a' * 9999);
      expect(keepFirstNotes('  short  '), 'short');
      for (final kept in [
        keepFirstNotes('$family ' * 3000),
        keepFirstNotes('$flag$accented' * 3000)
      ]) {
        expect(kept.length, lessThanOrEqualTo(10000));
      }
    });

    test('the pieces are found in time in proportion to the notes, whatever they hold', () {
      for (final (what, text) in [
        ('no spaces', '1,2\n3,4\n' * 250000), // a pasted treadling list, 2 million characters
        ('no line breaks', 'tabby then pattern ' * 105000), // one long paragraph
        ('neither', 'x' * 2000000),
      ]) {
        final watch = Stopwatch()..start();
        final pieces = notesPieces(text);
        watch.stop();
        expect(watch.elapsedMilliseconds, lessThan(1000), reason: '$what: ${watch.elapsed}');
        expect(rejoin(text, pieces), text, reason: what);
        expect(pieces.every((piece) => piece.$2 - piece.$1 <= 2000), isTrue, reason: what);
      }
    });

    test('the pieces of the read-only view cover the notes, never splitting a character', () {
      final yarn = String.fromCharCodes([0xD83E, 0xDDF6]);
      for (final text in [
        '',
        'one line',
        List.generate(500, (i) => 'Line $i ${'w' * 30}').join('\n'),
        'x' * 1999 + yarn * 3000, // no break anywhere
        ('word ' * 2000) + yarn,
      ]) {
        final pieces = notesPieces(text, size: 2000);
        for (var i = 0; i < pieces.length; i++) {
          final (start, end) = pieces[i];
          expect(end - start, lessThanOrEqualTo(2000));
          if (end > start && end < text.length) {
            final last = text.codeUnitAt(end - 1);
            expect(last >= 0xD800 && last <= 0xDBFF, isFalse, reason: 'not inside a character');
          }
        }
        expect(rejoin(text, pieces), text);
      }
    });

    testWidgets('notes padded past what the field can edit open read-only too', (tester) async {
      final padded = '${'Sett 24. ' * 100}${' ' * 60000}';
      expect(notesOverLimit(padded), isFalse, reason: 'within the limit as saved');
      final result = await openDialog(tester, padded);
      expect(notesField, findsNothing, reason: 'too long for the field');
      expect(
          find.textContaining('These notes have 60,900 characters with the spaces and blank lines '
              'around them'),
          findsOneWidget);
      expect(find.text('Shorten them by hand'), findsNothing);
      await tester.tap(find.text('Keep the first 10,000 characters'));
      await tester.pumpAndSettle();
      expect(
          find.textContaining('The notes become the 899 characters below, and the other 60,001 '
              'are removed.'),
          findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Keep'));
      await tester.pumpAndSettle();
      expect(result(), padded.trim(), reason: 'every character of the notes, the spaces gone');
    });

    testWidgets('while the text file is saved, nothing that changes the notes is offered',
        (tester) async {
      final old = 'Long notes from an earlier build. ' * 2000;
      final files = FakeSaveFile()..gate = Completer<void>();
      await openDialog(tester, old, files: files);
      OutlinedButton button(String label) => tester.widget<OutlinedButton>(find.ancestor(
          of: find.text(label), matching: find.byWidgetPredicate((w) => w is OutlinedButton)));
      await tester.tap(find.text('Save as a text file'));
      await tester.pump();
      for (final label in [
        'Save as a text file',
        'Keep the first 10,000 characters',
        'Clear notes',
      ]) {
        expect(button(label).onPressed, isNull, reason: '$label while the file is saved');
      }
      files.gate!.complete();
      await tester.pumpAndSettle();
      for (final label in ['Keep the first 10,000 characters', 'Clear notes']) {
        expect(button(label).onPressed, isNotNull, reason: '$label once it is saved');
      }
    });

    testWidgets('a text file that fails after the dialog is closed still says so', (tester) async {
      final old = 'Long notes from an earlier build. ' * 2000;
      final files = FakeSaveFile()
        ..gate = Completer<void>()
        ..error = const FileSystemException('disk full');
      final result = await openDialog(tester, old, files: files);
      await tester.tap(find.text('Save as a text file'));
      await tester.pump();
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(fullNotes, findsNothing, reason: 'closed');
      files.gate!.complete();
      await tester.pumpAndSettle();
      expect(find.textContaining('Could not save the text file'), findsOneWidget);
      expect(result(), isNull);
    });

    testWidgets('no dialog opens when the screen moved on while the notes were read',
        (tester) async {
      tallPhone(tester);
      final repo = _MemoryNotesRepo('Sett 24.');
      bool? saved;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: ElevatedButton(
                onPressed: () async => saved = await editDraftNotes(ctx, repo,
                    id: id,
                    draftName: 'Towel',
                    saveFile: (n, b) async => true,
                    stillWanted: () => false),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(notesField, findsNothing);
      expect(saved, isFalse);
      expect(repo.writes, isEmpty);
    });

    testWidgets('with the repository: reads, writes only a change, and says what happened',
        (tester) async {
      tallPhone(tester);
      final repo = _MemoryNotesRepo('Sett 24.');
      Future<bool?> run() async {
        bool? saved;
        await tester.pumpWidget(MaterialApp(
          // A fresh app each run, so an earlier run's snack bar is not still showing.
          key: UniqueKey(),
          home: Scaffold(
            body: Builder(
              builder: (ctx) => Center(
                child: ElevatedButton(
                  onPressed: () async => saved = await editDraftNotes(ctx, repo,
                      id: id, draftName: 'Towel', saveFile: (n, b) async => true),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ));
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        return saved;
      }

      // Cancel: nothing written.
      await run();
      expect(fieldText(tester), 'Sett 24.');
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(repo.writes, isEmpty);

      // Saved unchanged: nothing written either.
      await run();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(repo.writes, isEmpty);

      // Changed: written once, and said.
      await run();
      await tester.enterText(notesField, 'Sett 24, beaten firmly.');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(repo.writes, ['Sett 24, beaten firmly.']);
      expect(repo.expected, [notesDigest('Sett 24.')],
          reason: 'only if they are still the notes read');
      expect(find.text('Notes saved.'), findsOneWidget);

      // Notes changed meanwhile: the save is refused, and said.
      repo.setError = DraftNotesException(DraftNotesProblem.changed.message);
      await run();
      await tester.enterText(notesField, 'Mine.');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(find.text(DraftNotesProblem.changed.message), findsOneWidget);
      repo.setError = null;

      // Notes this build cannot change: the reason, and no editor to type into.
      repo.readError = const DraftNotesException('This draft was saved by a newer version of Ply, '
          'so its notes cannot be changed here.');
      await run();
      expect(notesField, findsNothing);
      expect(
          find.text(
              'This draft was saved by a newer version of Ply, so its notes cannot be changed here.'),
          findsOneWidget);
    });
  });

  group('the repository', () {
    late Directory drafts;
    late DraftRepository repo;
    setUp(() async {
      drafts = await Directory.systemTemp.createTemp('draft_notes');
      repo = DraftRepository(draftsDirOverride: drafts);
    });
    tearDown(() => drafts.delete(recursive: true));

    test('changes the notes alone: every other key kept in place, the pattern file untouched',
        () async {
      final original = sidecarJson();
      seedDraft(drafts, original);
      final thumb = File(p.join(drafts.path, '$id.png'))..writeAsBytesSync([1, 2, 3]);

      expect(await repo.readNotes(id), 'Sett 24 ends per inch.');
      await repo.setNotes(id, 'Sett 24 ends per inch.\nWashed in cold water.');

      final after = onDisk(drafts);
      expect(after, {...original, 'notes': 'Sett 24 ends per inch.\nWashed in cold water.'});
      expect(after.keys.toList(), original.keys.toList(), reason: 'key order is kept');
      expect(wifFile(drafts).readAsStringSync(), wif);
      expect(wifFile(drafts).lastModifiedSync(), DateTime(2020), reason: 'not rewritten');
      expect(thumb.readAsBytesSync(), [1, 2, 3]);
      expect(drafts.listSync().where((e) => e.path.endsWith('.tmp')), isEmpty);
      // The library lists it with the new notes and the same dates.
      final listed = (await repo.list()).single.meta;
      expect(listed.notes, 'Sett 24 ends per inch.\nWashed in cold water.');
      expect(listed.lastOpened, DateTime.utc(2026, 1, 2));
      expect(listed.savedAt, DateTime.utc(2026, 1, 1));
    });

    test('a sidecar without notes reads as empty, and gains them', () async {
      seedDraft(drafts, {...sidecarJson()}..remove('notes'));
      expect(await repo.readNotes(id), '');
      await repo.setNotes(id, 'First notes.');
      expect(onDisk(drafts)['notes'], 'First notes.');
      seedDraft(drafts, {...sidecarJson(), 'notes': null});
      expect(await repo.readNotes(id), '');
    });

    test('refuses without writing what it should not change', () async {
      seedDraft(drafts, sidecarJson());
      final before = sidecarFile(drafts).readAsStringSync();
      Future<void> refused(Future<Object?> call, String message) => expectLater(
          call, throwsA(isA<DraftNotesException>().having((e) => e.message, 'message', message)));

      // Past the limit (the notes editor never asks for that).
      await expectLater(
          repo.setNotes(id, 'n' * (DraftMeta.maxNotesChars + 1)), throwsArgumentError);
      expect(sidecarFile(drafts).readAsStringSync(), before);

      // From a newer sidecar schema.
      seedDraft(drafts, {...sidecarJson(), 'schemaVersion': 2});
      final newer = sidecarFile(drafts).readAsStringSync();
      const newerMessage =
          'This draft was saved by a newer version of Ply, so its notes cannot be changed here.';
      await refused(repo.readNotes(id), newerMessage);
      await refused(repo.setNotes(id, 'x'), newerMessage);
      expect(sidecarFile(drafts).readAsStringSync(), newer);

      // Notes that are not text (kept as they are).
      seedDraft(drafts, {
        ...sidecarJson(),
        'notes': {'rich': 'text'}
      });
      final rich = sidecarFile(drafts).readAsStringSync();
      const richMessage =
          "This draft's notes were saved in a form this version of Ply cannot change.";
      await refused(repo.readNotes(id), richMessage);
      await refused(repo.setNotes(id, 'x'), richMessage);
      expect(sidecarFile(drafts).readAsStringSync(), rich);

      // A number too large for a double (no Ply build writes one): refused when read, before
      // anything is typed, as it could not be written again.
      sidecarFile(drafts).writeAsStringSync(jsonEncode(sidecarJson())
          .replaceFirst('"schemaVersion":1', '"schemaVersion":1,"later":1e400'));
      final infinite = sidecarFile(drafts).readAsStringSync();
      await refused(repo.readNotes(id), "This draft's details could not be read.");
      await refused(repo.setNotes(id, 'x'), "This draft's details could not be read.");
      expect(sidecarFile(drafts).readAsStringSync(), infinite);

      // Notes changed since they were read (another notes editor saved first).
      seedDraft(drafts, sidecarJson());
      final current = sidecarFile(drafts).readAsStringSync();
      await refused(repo.setNotes(id, 'Mine.', expectedDigest: notesDigest('What I opened.')),
          DraftNotesProblem.changed.message);
      expect(sidecarFile(drafts).readAsStringSync(), current);
      final read = await repo.readNotesWithDigest(id);
      expect(read.digest, notesDigest('Sett 24 ends per inch.'));
      await repo.setNotes(id, 'Mine.', expectedDigest: read.digest);
      expect(onDisk(drafts)['notes'], 'Mine.');

      // Over 64 MB: not read at all.
      final huge = sidecarFile(drafts).openSync(mode: FileMode.append);
      huge.truncateSync(maxNotesSidecarBytes + 1);
      huge.closeSync();
      await refused(
          repo.readNotes(id), "This draft's notes are too large for Ply to open (over 64 MB).");
      await refused(
          repo.setNotes(id, 'x'), "This draft's notes are too large for Ply to open (over 64 MB).");
      expect(sidecarFile(drafts).lengthSync(), maxNotesSidecarBytes + 1);

      // A file that is not a sidecar, and a draft that is gone.
      sidecarFile(drafts).writeAsStringSync('[1, 2]');
      await refused(repo.setNotes(id, 'x'), "This draft's details could not be read.");
      expect(sidecarFile(drafts).readAsStringSync(), '[1, 2]');
      sidecarFile(drafts).deleteSync();
      await refused(repo.setNotes(id, 'x'), 'This draft is no longer in your library.');
      expect(sidecarFile(drafts).existsSync(), isFalse, reason: 'not brought back');
    });

    test('runs after the writes to the sidecar already under way, one at a time', () async {
      seedDraft(drafts, sidecarJson());
      final gate = Completer<void>();
      // An earlier write still under way when the notes are read and changed: it renames the draft
      // and changes the notes (another notes editor, say).
      final earlier = SidecarWrites.run(sidecarFile(drafts).path, () async {
        await gate.future;
        sidecarFile(drafts).writeAsStringSync(jsonEncode(
            {...sidecarJson(notes: 'Changed by the earlier write.'), 'name': 'Renamed'}));
      });
      final read = repo.readNotes(id);
      final write = repo.setNotes(id, 'After the earlier write.',
          expectedDigest: notesDigest('Changed by the earlier write.'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(onDisk(drafts)['notes'], 'Sett 24 ends per inch.', reason: 'still waiting');
      gate.complete();
      await Future.wait([earlier, write]);
      expect(await read, 'Changed by the earlier write.', reason: 'read after the earlier write');
      expect(onDisk(drafts)['name'], 'Renamed');
      expect(onDisk(drafts)['notes'], 'After the earlier write.');
    });

    test('a sidecar over 1 MB is read and rewritten off the calling isolate, keys kept', () async {
      final old = List.generate(40000, (i) => 'Pick ${i + 1}: tabby, then pattern.').join('\n');
      final original = sidecarJson(notes: old);
      seedDraft(drafts, original);
      expect(sidecarFile(drafts).lengthSync(), greaterThan(inlineNotesSidecarBytes));
      expect(await repo.readNotes(id), old);
      await repo.setNotes(id, keepFirstNotes(old), expectedDigest: notesDigest(old));
      final after = onDisk(drafts);
      expect(after, {...original, 'notes': keepFirstNotes(old)});
      expect(after.keys.toList(), original.keys.toList());
      expect(sidecarFile(drafts).lengthSync(), lessThan(inlineNotesSidecarBytes));
    });

    test('a notes edit and a link written at the same moment both keep their change', () async {
      final docs = await Directory.systemTemp.createTemp('draft_notes_docs');
      addTearDown(() => docs.delete(recursive: true));
      final inDocs = Directory(p.join(docs.path, 'drafts'))..createSync();
      final repo = DraftRepository(draftsDirOverride: inDocs);
      seedDraft(inDocs, sidecarJson());
      final linked =
          ProjectMaterials(swatches: [SwatchLink(swatchId: 'sw-2', swatchName: 'Second sample')]);
      await Future.wait([
        repo.setNotes(id, 'With the second sample.'),
        ProjectLinksRepository(docsOverride: docs).write(BackupCraft.weaving, id, linked),
      ]);
      expect(onDisk(inDocs)['notes'], 'With the second sample.');
      expect(onDisk(inDocs)['materials'], linked.toJson());
    });

    group("with an editor's save", () {
      // The weaving editor saves with the meta it opened the draft with (EditorScreen.meta), with
      // only the fields it changed set: exactly this.
      DraftMeta editorMeta(DraftMeta opened) =>
          opened.copyWith(loomType: LoomType.counterbalance, lastOpened: DateTime.now());

      test('a notes edit, then a save made with the meta opened before it: the notes stay',
          () async {
        seedDraft(drafts, sidecarJson());
        final opened = metaOnDisk(drafts);
        await repo.setNotes(id, 'Edited while the editor was open.');
        await repo.save(wifText: wif, meta: editorMeta(opened), id: id);
        final after = onDisk(drafts);
        expect(after['notes'], 'Edited while the editor was open.');
        expect(after['loomType'], 'Counterbalance', reason: 'the save landed too');
        expect(after['futureKey'], {'kept': true});
        expect(after['materials'], sidecarJson()['materials']);

        // Cleared notes stay cleared.
        await repo.setNotes(id, '');
        await repo.save(wifText: wif, meta: editorMeta(opened), id: id);
        expect(onDisk(drafts)['notes'], '');
      });

      test('a save, then a notes edit: what the save wrote stays', () async {
        seedDraft(drafts, sidecarJson());
        final opened = metaOnDisk(drafts);
        await repo.save(wifText: wif, meta: editorMeta(opened), id: id);
        final saved = onDisk(drafts);
        await repo.setNotes(id, 'Edited after the save.');
        expect(onDisk(drafts), {...saved, 'notes': 'Edited after the save.'});
        expect(onDisk(drafts)['loomType'], 'Counterbalance');
      });

      test('both under way at once, in either order: both are kept', () async {
        // The sidecar lock is held until both calls are queued on it, in the order under test, so
        // that order is the order they run in.
        final path = sidecarFile(drafts).path;
        Future<void> queued(int n) async {
          for (var i = 0; i < 400 && SidecarWrites.queuedOn(path) < n; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
          expect(SidecarWrites.queuedOn(path), n);
        }

        for (final notesFirst in [true, false]) {
          seedDraft(drafts, sidecarJson());
          final opened = metaOnDisk(drafts);
          final notes = 'Under way at once, notes first: $notesFirst';
          final gate = Completer<void>();
          final held = SidecarWrites.run(path, () => gate.future);
          final order = <String>[];
          Future<void> edit() => repo.setNotes(id, notes).then((_) => order.add('notes'));
          Future<void> save() => repo
              .save(wifText: wif, meta: editorMeta(opened), id: id)
              .then((_) => order.add('save'));
          await queued(1);
          final first = notesFirst ? edit() : save();
          await queued(2);
          final second = notesFirst ? save() : edit();
          await queued(3);
          gate.complete();
          await Future.wait([held, first, second]);
          expect(order, notesFirst ? ['notes', 'save'] : ['save', 'notes']);
          final after = onDisk(drafts);
          expect(after['notes'], notes, reason: 'notes first: $notesFirst');
          expect(after['loomType'], 'Counterbalance', reason: 'notes first: $notesFirst');
          expect(after['futureKey'], {'kept': true});
          expect(SidecarWrites.queuedOn(path), 0);
        }
      });

      test('a sidecar there that cannot be read refuses the save, writing nothing', () async {
        seedDraft(drafts, sidecarJson());
        final opened = metaOnDisk(drafts);
        final f = sidecarFile(drafts);
        final chmod = Process.runSync('chmod', ['000', f.path]);
        addTearDown(() => Process.runSync('chmod', ['644', f.path]));
        try {
          f.readAsBytesSync();
          return; // this account reads any file (root), so the failure cannot be staged here
        } on FileSystemException {
          expect(chmod.exitCode, 0);
        }
        await expectLater(
            repo.save(wifText: '[WIF]\nchanged\n', meta: editorMeta(opened), id: id),
            throwsA(isA<DraftSaveRefused>().having(
                (e) => e.message,
                'message',
                "This draft's details could not be read, so it was not saved (its notes and links "
                    'are kept as they are). Try again.')));
        expect(wifFile(drafts).readAsStringSync(), wif, reason: 'nothing written');
        expect(wifFile(drafts).lastModifiedSync(), DateTime(2020));
        Process.runSync('chmod', ['644', f.path]);
        expect(onDisk(drafts), sidecarJson(), reason: 'the notes and links are as they were');
      });

      test('a file there that is not a sidecar is replaced by the save, as before', () async {
        seedDraft(drafts, sidecarJson());
        final opened = metaOnDisk(drafts);
        for (final bytes in [
          utf8.encode('[1, 2]'),
          utf8.encode('not json'),
          [0xFF, 0xFE]
        ]) {
          sidecarFile(drafts).writeAsBytesSync(bytes);
          await repo.save(wifText: wif, meta: editorMeta(opened), id: id);
          final after = onDisk(drafts);
          expect(after['loomType'], 'Counterbalance');
          expect(after['notes'], 'Sett 24 ends per inch.', reason: 'the meta is all there is');
        }
      });

      test('a first save writes the notes it was given', () async {
        final newId = await repo.save(
            wifText: wif,
            meta: DraftMeta(
                name: 'New',
                notes: 'From the save dialog.',
                savedAt: DateTime.utc(2026),
                lastOpened: DateTime.utc(2026)));
        expect(await repo.readNotes(newId), 'From the save dialog.');
      });
    });
  });

  group('in the editor', () {
    late Directory drafts;
    late DiskRepo repo;
    setUp(() async {
      drafts = await Directory.systemTemp.createTemp('draft_notes_editor');
      repo = DiskRepo(drafts);
    });
    tearDown(() => drafts.delete(recursive: true));

    /// Push the editor on saved draft [id] as the library does, with the meta on disk now.
    Future<ProviderContainer> pumpEditor(WidgetTester tester, {List<bool?>? pops}) async {
      tallPhone(tester);
      final container = ProviderContainer(overrides: [repositoryProvider.overrideWithValue(repo)]);
      addTearDown(container.dispose);
      final meta = metaOnDisk(drafts);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () async {
                    final r = await Navigator.push<bool>(
                      context,
                      MaterialPageRoute<bool>(
                        builder: (_) =>
                            EditorScreen(wifText: wif, title: meta.name, id: id, meta: meta),
                      ),
                    );
                    pops?.add(r);
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await settle(tester);
      return container;
    }

    Future<void> openNotes(WidgetTester tester) async {
      await tester.tap(find.byTooltip('More actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Notes…'));
      await settle(tester);
    }

    Future<void> saveNotes(WidgetTester tester, String notes) async {
      await tester.enterText(notesField, notes);
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await settle(tester);
    }

    testWidgets(
        'a notes edit writes the notes alone: the draft is not edited, and a later Save '
        'keeps them', (tester) async {
      seedDraft(drafts, sidecarJson());
      final pops = <bool?>[];
      final container = await pumpEditor(tester, pops: pops);
      final validations = repo.validateCount;

      await openNotes(tester);
      expect(fieldText(tester), 'Sett 24 ends per inch.');
      await saveNotes(tester, 'Edited in the editor.');
      expect(find.text('Notes saved.'), findsOneWidget);
      expect(onDisk(drafts), {...sidecarJson(), 'notes': 'Edited in the editor.'});
      expect(wifFile(drafts).lastModifiedSync(), DateTime(2020), reason: 'pattern not rewritten');
      expect(container.read(draftEditorProvider).dirtyStructural, isFalse);
      expect(repo.saveCount, 0);
      expect(repo.validateCount, validations, reason: 'the draft did not change, nothing checked');

      // The editor's Save (its meta still holds the old notes) keeps the new ones.
      await tester.tap(find.byTooltip('Save'));
      await settle(tester);
      expect(repo.saveCount, 1);
      expect(pops, [true]);
      final after = onDisk(drafts);
      expect(after['notes'], 'Edited in the editor.');
      expect(after['lastOpened'], isNot(sidecarJson()['lastOpened']), reason: 'the save landed');
      expect(after['futureKey'], {'kept': true});
    });

    testWidgets('a clean editor still leaves without asking after a notes edit', (tester) async {
      seedDraft(drafts, sidecarJson());
      final pops = <bool?>[];
      await pumpEditor(tester, pops: pops);
      await openNotes(tester);
      await saveNotes(tester, 'Edited, then left.');
      await tester.pageBack();
      await settle(tester);
      expect(find.text('Leave without saving?'), findsNothing);
      expect(pops, [null], reason: 'left without a save');
      expect(onDisk(drafts)['notes'], 'Edited, then left.');
    });

    testWidgets('a notes edit after an editor save keeps what the save wrote', (tester) async {
      seedDraft(drafts, sidecarJson());
      final container = await pumpEditor(tester);
      // The save writes a field of its own (the Book view pin), then leaves the editor.
      container.read(overshotTreadlingProvider.notifier).state = true;
      await tester.tap(find.byTooltip('Save'));
      await settle(tester);
      expect(onDisk(drafts)['overshotTreadling'], isTrue);
      final saved = onDisk(drafts);

      // Opened again, the notes are changed there.
      await tester.pumpWidget(const SizedBox());
      await settle(tester);
      await pumpEditor(tester);
      await openNotes(tester);
      await saveNotes(tester, 'Edited after the save.');
      expect(onDisk(drafts), {...saved, 'notes': 'Edited after the save.'});
    });

    testWidgets('Cancel changes nothing', (tester) async {
      seedDraft(drafts, sidecarJson());
      final before = sidecarFile(drafts).readAsStringSync();
      await pumpEditor(tester);
      await openNotes(tester);
      await tester.enterText(notesField, 'Not kept.');
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await settle(tester);
      expect(sidecarFile(drafts).readAsStringSync(), before);
      expect(find.text('Notes saved.'), findsNothing);
    });

    testWidgets('notes it cannot change say why, with nothing to type into', (tester) async {
      seedDraft(drafts, {...sidecarJson(), 'schemaVersion': 2});
      await pumpEditor(tester);
      await openNotes(tester);
      expect(notesField, findsNothing);
      expect(
          find.text(
              'This draft was saved by a newer version of Ply, so its notes cannot be changed here.'),
          findsOneWidget);
    });

    testWidgets('the Notes item is disabled while a save is under way', (tester) async {
      seedDraft(drafts, sidecarJson());
      repo.saveGate = Completer<void>();
      await pumpEditor(tester);
      await tester.tap(find.byTooltip('Save'));
      await settle(tester, rounds: 4);
      expect(repo.saveCount, 1, reason: 'the save is under way');
      await tester.tap(find.byTooltip('More actions'));
      await tester.pumpAndSettle();
      final item = tester.widget<PopupMenuItem<Object?>>(find.ancestor(
          of: find.text('Notes…'), matching: find.byWidgetPredicate((w) => w is PopupMenuItem)));
      expect(item.enabled, isFalse);
      await tester.tap(find.text('Notes…'), warnIfMissed: false);
      await settle(tester, rounds: 4);
      expect(notesField, findsNothing, reason: 'nothing opens');
      repo.saveGate!.complete();
      await settle(tester);
    });

    testWidgets('while the notes are read, Save waits and Notes again opens one editor',
        (tester) async {
      seedDraft(drafts, sidecarJson());
      repo.readGate = Completer<void>();
      await pumpEditor(tester);
      IconButton saveButton() =>
          tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.save_outlined));
      await tester.tap(find.byTooltip('More actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Notes…'));
      await settle(tester, rounds: 4);
      expect(notesField, findsNothing, reason: 'still reading');
      expect(saveButton().onPressed, isNull, reason: 'a save now would pop the notes dialog');
      await tester.tap(find.byTooltip('Save'), warnIfMissed: false);
      await settle(tester, rounds: 4);
      expect(repo.saveCount, 0);
      // Notes chosen again while the first is still reading.
      await tester.tap(find.byTooltip('More actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Notes…'));
      await settle(tester, rounds: 4);

      repo.readGate!.complete();
      await settle(tester);
      expect(notesField, findsOneWidget, reason: 'one editor, not two stacked');
      expect(saveButton().onPressed, isNull, reason: 'not while the dialog is up');
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await settle(tester);
      expect(notesField, findsNothing);
      expect(saveButton().onPressed, isNotNull, reason: 'Save is back');
      await tester.tap(find.byTooltip('Save'));
      await settle(tester);
      expect(repo.saveCount, 1);
    });

    testWidgets('a draft not saved yet has no Notes item: its first save asks for them',
        (tester) async {
      tallPhone(tester);
      final container = ProviderContainer(overrides: [repositoryProvider.overrideWithValue(repo)]);
      addTearDown(container.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: EditorScreen(initialDoc: await repo.parseDoc(wif), title: 'New draft'),
        ),
      ));
      await settle(tester);
      await tester.tap(find.byTooltip('More actions'));
      await tester.pumpAndSettle();
      expect(find.text('Notes…'), findsNothing);
      expect(find.text('Book view'), findsOneWidget, reason: 'the menu is open');
    });
  });

  group('in the library', () {
    late Directory drafts;
    late DiskRepo repo;
    setUp(() async {
      drafts = await Directory.systemTemp.createTemp('draft_notes_library');
      repo = DiskRepo(drafts);
    });
    tearDown(() => drafts.delete(recursive: true));

    Future<void> pumpLibrary(WidgetTester tester, {FakeSaveFile? files}) async {
      tallPhone(tester);
      await tester.pumpWidget(ProviderScope(
        overrides: [
          repositoryProvider.overrideWithValue(repo),
          backupFileAccessProvider.overrideWithValue(FakeFileAccess(files ?? FakeSaveFile())),
        ],
        child: MaterialApp(home: LibraryScreen(repository: repo)),
      ));
      await settle(tester);
    }

    testWidgets("a draft's menu offers Notes: Cancel keeps them, Save writes them alone",
        (tester) async {
      seedDraft(drafts, sidecarJson());
      final before = sidecarFile(drafts).readAsStringSync();
      await pumpLibrary(tester);
      expect(find.text('Towel'), findsOneWidget);

      // From the tile's menu.
      await tester.tap(find.byTooltip('Pattern actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Notes'));
      await settle(tester);
      expect(fieldText(tester), 'Sett 24 ends per inch.');
      await tester.enterText(notesField, 'Not kept.');
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await settle(tester);
      expect(sidecarFile(drafts).readAsStringSync(), before);

      // From the sheet a long press opens.
      await tester.longPress(find.text('Towel'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, 'Notes'));
      await settle(tester);
      await tester.enterText(notesField, 'Washed in cold water.');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await settle(tester);
      expect(find.text('Notes saved.'), findsOneWidget);
      expect(onDisk(drafts), {...sidecarJson(), 'notes': 'Washed in cold water.'});
      expect(wifFile(drafts).lastModifiedSync(), DateTime(2020));
    });

    testWidgets('long notes: saved as a text file, nothing written until Keep, then kept',
        (tester) async {
      final old = 'An earlier build took notes of any length. ' * 2000;
      seedDraft(drafts, sidecarJson(notes: old));
      final before = sidecarFile(drafts).readAsStringSync();
      final files = FakeSaveFile();
      await pumpLibrary(tester, files: files);
      await tester.tap(find.byTooltip('Pattern actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Notes'));
      await settle(tester);
      expect(notesField, findsNothing);
      expect(fullNotes, findsOneWidget);

      await tester.tap(find.text('Save as a text file'));
      await settle(tester);
      expect(files.saved.single.$1, 'Towel notes.txt');
      expect(files.saved.single.$3, 'Save notes', reason: 'not called a backup on a desktop');
      expect(utf8.decode(files.saved.single.$2), old);
      expect(sidecarFile(drafts).readAsStringSync(), before, reason: 'nothing written yet');

      await tester.tap(find.text('Keep the first 10,000 characters'));
      await settle(tester);
      expect(sidecarFile(drafts).readAsStringSync(), before, reason: 'nothing written yet');
      await tester.tap(find.widgetWithText(FilledButton, 'Keep'));
      await settle(tester);
      expect(find.text('Notes saved.'), findsOneWidget);
      expect(onDisk(drafts), {...sidecarJson(), 'notes': keepFirstNotes(old)});
      expect(wifFile(drafts).lastModifiedSync(), DateTime(2020));

      // Within the limit now: the editable field from then on.
      await tester.tap(find.byTooltip('Pattern actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Notes'));
      await settle(tester);
      expect(fieldText(tester), keepFirstNotes(old));
    });

    testWidgets('Notes chosen again while the notes are read opens one editor', (tester) async {
      seedDraft(drafts, sidecarJson());
      repo.readGate = Completer<void>();
      await pumpLibrary(tester);
      for (var i = 0; i < 2; i++) {
        await tester.tap(find.byTooltip('Pattern actions'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Notes'));
        await settle(tester, rounds: 4);
      }
      expect(notesField, findsNothing, reason: 'still reading');
      repo.readGate!.complete();
      await settle(tester);
      expect(notesField, findsOneWidget, reason: 'one editor, not two stacked');
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await settle(tester);
      expect(notesField, findsNothing);
      // Once it is closed, Notes opens again.
      await tester.tap(find.byTooltip('Pattern actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Notes'));
      await settle(tester);
      expect(notesField, findsOneWidget);
    });

    testWidgets('long notes cleared from the library, after the question', (tester) async {
      seedDraft(drafts, sidecarJson(notes: 'Long. ' * 3000));
      final before = sidecarFile(drafts).readAsStringSync();
      await pumpLibrary(tester);
      await tester.longPress(find.text('Towel'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, 'Notes'));
      await settle(tester);
      await tester.tap(find.text('Clear notes'));
      await settle(tester);
      expect(sidecarFile(drafts).readAsStringSync(), before, reason: 'not before Clear');
      await tester.tap(find.widgetWithText(FilledButton, 'Clear'));
      await settle(tester);
      expect(onDisk(drafts), {...sidecarJson(), 'notes': ''});
    });
  });
}

/// Notes held in memory, for the notes editor's own flow.
class _MemoryNotesRepo extends DraftRepository {
  _MemoryNotesRepo(this.notes);

  String notes;
  final List<String> writes = [];
  final List<String?> expected = [];
  DraftNotesException? readError;
  DraftNotesException? setError;

  @override
  Future<({String notes, String digest})> readNotesWithDigest(String id) async {
    if (readError != null) throw readError!;
    return (notes: notes, digest: notesDigest(notes));
  }

  @override
  Future<void> setNotes(String id, String notes, {String? expectedDigest}) async {
    if (setError != null) throw setError!;
    writes.add(notes);
    expected.add(expectedDigest);
    this.notes = notes;
  }
}
