import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/draft_repository.dart';
import 'package:ply/src/models/draft_doc.dart';
import 'package:ply/src/models/draft_meta.dart';
import 'package:ply/src/screens/editor_screen.dart';
import 'package:ply/src/state/draft_editor_notifier.dart';
import 'package:ply/src/state/editor_providers.dart';

/// A repository stub for the editor's FFI-backed calls: parseDoc/renderDto/saveDto are plain
/// virtual methods, so the editor's own widget logic is host-testable with no native lib.
class FakeRepo extends DraftRepository {
  FakeRepo({this.parseError = false});

  final bool parseError;
  String? capturedSourceWif;
  DraftMeta? capturedMeta;
  bool sawSave = false;
  int saveCount = 0;

  /// When set, saveDto suspends on this until completed — lets a test hold one save in flight.
  Completer<void>? saveGate;

  @override
  Future<DraftDoc> parseDoc(String wifText) async {
    if (parseError) throw const FormatException('not a pattern');
    // Distinct from DraftDoc.blank() (the build() default) so "load reflects the draft" is real.
    return DraftDoc.blank(shafts: 4, treadles: 4).copyWith(name: 'loaded');
  }

  @override
  Future<ui.Image> renderDto(DraftDoc doc, {required int cellPx}) => _stubImage();

  @override
  Future<String> saveDto(
    DraftDoc doc, {
    required DraftMeta meta,
    String? id,
    String? sourceWif,
  }) async {
    saveCount++;
    if (saveGate != null) await saveGate!.future;
    sawSave = true;
    capturedSourceWif = sourceWif;
    capturedMeta = meta;
    return id ?? 'new-id';
  }
}

Future<ui.Image> _stubImage() {
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

/// Pumps a host that pushes the EditorScreen as a non-root route (so Save's pop is valid).
/// [id]/[meta] simulate editing a SAVED library draft (overwrite-in-place + preserved meta).
Future<ProviderContainer> pumpEditor(
  WidgetTester tester,
  FakeRepo fake, {
  String? id,
  DraftMeta? meta,
}) async {
  final container = ProviderContainer(
    overrides: [repositoryProvider.overrideWithValue(fake)],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        EditorScreen(wifText: 'WIF', title: 'T', id: id, meta: meta),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await letAsyncSettle(tester);
  return container;
}

IconButton iconButton(WidgetTester tester, IconData icon) =>
    tester.widget<IconButton>(find.widgetWithIcon(IconButton, icon));

/// Pump a bounded number of frames to let async work (parseDoc, load, render, save) resolve.
/// We cannot use pumpAndSettle here: while loading, the editor shows a CircularProgressIndicator
/// (an infinite animation) which pumpAndSettle would wait on forever.
Future<void> letAsyncSettle(WidgetTester tester) async {
  await tester.pump();
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 30));
  }
}

void main() {
  testWidgets('load parses the WIF and the editor reflects the loaded draft', (tester) async {
    final container = await pumpEditor(tester, FakeRepo());
    final draft = container.read(draftEditorProvider).draft;
    expect(draft, isNot(equals(DraftDoc.blank())), reason: 'not the blank build() default');
    expect(draft.name, 'loaded');
    expect(find.byIcon(Icons.save_outlined), findsOneWidget);
  });

  testWidgets('a parse failure shows an error and hides the edit actions', (tester) async {
    await pumpEditor(tester, FakeRepo(parseError: true));
    expect(find.textContaining('Could not open'), findsOneWidget);
    expect(find.byIcon(Icons.save_outlined), findsNothing);
    expect(find.byIcon(Icons.undo), findsNothing);
    expect(find.byIcon(Icons.redo), findsNothing);
  });

  testWidgets('undo/redo buttons gate on the edit history', (tester) async {
    final container = await pumpEditor(tester, FakeRepo());
    expect(iconButton(tester, Icons.undo).onPressed, isNull, reason: 'nothing to undo yet');
    expect(iconButton(tester, Icons.redo).onPressed, isNull);

    container.read(draftEditorProvider.notifier).toggleTieupCell(1, 1);
    await tester.pump();
    expect(iconButton(tester, Icons.undo).onPressed, isNotNull, reason: 'an edit can be undone');
    expect(iconButton(tester, Icons.redo).onPressed, isNull);

    container.read(draftEditorProvider.notifier).undo();
    await tester.pump();
    expect(iconButton(tester, Icons.redo).onPressed, isNotNull, reason: 'the undo can be redone');
  });

  testWidgets('save dual-path: a CLEAN draft saves verbatim with NO warning', (tester) async {
    final fake = FakeRepo();
    await pumpEditor(tester, fake);
    await tester.tap(find.byIcon(Icons.save_outlined));
    await letAsyncSettle(tester);
    expect(find.text('Save anyway'), findsNothing, reason: 'lossless verbatim save -> no warning');
    expect(fake.sawSave, isTrue);
    expect(fake.capturedSourceWif, 'WIF', reason: 'unedited -> persist the original WIF verbatim');
  });

  testWidgets('save dual-path: an EDITED draft WARNS, then Save anyway re-serializes (null)',
      (tester) async {
    final fake = FakeRepo();
    final container = await pumpEditor(tester, fake);
    container.read(draftEditorProvider.notifier).toggleTieupCell(1, 1);
    await tester.pump();
    await tester.tap(find.byIcon(Icons.save_outlined));
    await letAsyncSettle(tester);
    // The lossy-save warning appears and NOTHING is written yet.
    expect(find.text('Save anyway'), findsOneWidget);
    expect(fake.sawSave, isFalse);

    await tester.tap(find.text('Save anyway'));
    await letAsyncSettle(tester);
    expect(fake.sawSave, isTrue);
    expect(fake.capturedSourceWif, isNull, reason: 'edited -> re-serialize via write_wif, not verbatim');
  });

  testWidgets('save dual-path: Cancel on the warning aborts the save', (tester) async {
    final fake = FakeRepo();
    final container = await pumpEditor(tester, fake);
    container.read(draftEditorProvider.notifier).toggleTieupCell(1, 1);
    await tester.pump();
    await tester.tap(find.byIcon(Icons.save_outlined));
    await letAsyncSettle(tester);
    expect(find.text('Save anyway'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await letAsyncSettle(tester);
    expect(fake.sawSave, isFalse, reason: 'cancelling must not write anything');
    expect(find.byIcon(Icons.save_outlined), findsOneWidget, reason: 'still in the editor');
  });

  testWidgets('editing a SAVED draft preserves its meta (author/notes/savedAt), bumps lastOpened',
      (tester) async {
    final fake = FakeRepo();
    final existing = DraftMeta(
      name: 'Original',
      author: 'Ada',
      notes: 'heirloom',
      savedAt: DateTime.utc(2020, 1, 1),
      lastOpened: DateTime.utc(2020, 1, 2),
    );
    await pumpEditor(tester, fake, id: 'abc', meta: existing);
    await tester.tap(find.byIcon(Icons.save_outlined)); // clean save -> overwrite in place
    await letAsyncSettle(tester);

    final m = fake.capturedMeta!;
    expect(m.author, 'Ada');
    expect(m.notes, 'heirloom');
    expect(m.craft, 'Weaving');
    expect(m.savedAt, DateTime.utc(2020, 1, 1), reason: 'original savedAt preserved');
    expect(m.lastOpened.isAfter(DateTime.utc(2020, 1, 2)), isTrue,
        reason: 'lastOpened bumped to ~now');
  });

  testWidgets('a double-tap of Save collapses to ONE save (re-entrancy guard)', (tester) async {
    final fake = FakeRepo()..saveGate = Completer<void>();
    await pumpEditor(tester, fake); // clean draft -> no dialog
    // First tap enters _save, disables the button, and suspends inside the gated saveDto.
    await tester.tap(find.byIcon(Icons.save_outlined));
    await tester.pump();
    // Second tap while the first save is in flight is rejected (guarded + disabled button).
    await tester.tap(find.byIcon(Icons.save_outlined), warnIfMissed: false);
    await tester.pump();
    expect(fake.saveCount, 1, reason: 'a double-tap must not double-write or double-pop');
    fake.saveGate!.complete();
    await letAsyncSettle(tester);
  });
}
