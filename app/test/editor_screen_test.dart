import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/draft_repository.dart';
import 'package:ply/src/models/draft_doc.dart';
import 'package:ply/src/models/draft_issue.dart';
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

  int convertCount = 0;

  /// When set, toLiftplanDoc suspends on this — lets a test hold one conversion in flight.
  Completer<void>? convertGate;

  /// When true, toLiftplanDoc throws (the engine Err path) so a test can assert the SnackBar.
  bool convertError = false;

  /// What validateDto returns. Default clean so every pre-3.4 save/convert test is unchanged. The
  /// validation provider AND the Save error-gate both call this; a test flips it to drive the gate.
  List<DraftIssue> issues = const [];

  /// When true, validateDto throws — exercises the Save gate's fail-closed path.
  bool validateError = false;
  int validateCount = 0;

  /// When set, validateDto suspends on this — lets a test hold the Save gate's validate in flight
  /// and land a concurrent edit during the FFI hop.
  Completer<void>? validateGate;

  @override
  Future<List<DraftIssue>> validateDto(DraftDoc doc) async {
    validateCount++;
    if (validateError) throw Exception('validate boom');
    if (validateGate != null) await validateGate!.future;
    return issues;
  }

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

  @override
  Future<DraftDoc> toLiftplanDoc(DraftDoc doc) async {
    convertCount++;
    if (convertGate != null) await convertGate!.future;
    if (convertError) throw Exception('engine boom');
    // A DISTINCT liftplan doc so commitEdit applies and the undo stack grows.
    return doc.copyWith(drive: DraftLiftplan(liftplan: const [[1], [2]]), treadles: 0);
  }
}

/// A liftplan draft to load when testing the convert action's already-liftplan (disabled) state.
DraftDoc liftplanDoc() => DraftDoc.blank(shafts: 4, treadles: 4)
    .copyWith(drive: DraftLiftplan(liftplan: const [[1], [2]]), treadles: 0);

const DraftIssue _err =
    DraftIssue(severity: IssueSeverity.error, message: 'treadle 1 ties shaft 5 outside 1..=2');
const DraftIssue _warn =
    DraftIssue(severity: IssueSeverity.warning, message: 'warp color count (5) != warp ends (4)');

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

  testWidgets('convert action is enabled on a treadled draft, DISABLED on a liftplan',
      (tester) async {
    final container = await pumpEditor(tester, FakeRepo()); // parseDoc returns a treadled draft
    expect(iconButton(tester, Icons.swap_horiz).onPressed, isNotNull,
        reason: 'a treadled draft can be converted');
    expect(find.byTooltip('Convert to liftplan'), findsOneWidget);

    // Load a liftplan draft: the action greys out (disabled, not hidden) with an explaining tooltip.
    container.read(draftEditorProvider.notifier).load(liftplanDoc());
    await tester.pump();
    expect(iconButton(tester, Icons.swap_horiz).onPressed, isNull,
        reason: 'already a liftplan -> disabled, never hidden');
    expect(find.byTooltip('Already a liftplan'), findsOneWidget);
  });

  testWidgets('convert confirms, commits ONE undo entry, and Undo reverts to treadled',
      (tester) async {
    final fake = FakeRepo();
    final container = await pumpEditor(tester, fake);
    await tester.tap(find.byIcon(Icons.swap_horiz));
    await letAsyncSettle(tester);
    // The confirm dialog is up and NOTHING converted yet.
    expect(find.text('Convert to liftplan?'), findsOneWidget);
    expect(fake.convertCount, 0);

    await tester.tap(find.text('Convert'));
    await letAsyncSettle(tester);
    expect(fake.convertCount, 1);
    expect(container.read(draftEditorProvider).draft.drive, isA<DraftLiftplan>());
    expect(container.read(draftEditorProvider).undo.length, 1,
        reason: 'the conversion is one undo entry');

    await tester.tap(find.byIcon(Icons.undo));
    await tester.pump();
    expect(container.read(draftEditorProvider).draft.drive, isA<DraftTreadled>(),
        reason: 'undo brings the tie-up back');
  });

  testWidgets('Cancel on the convert dialog aborts (nothing converted)', (tester) async {
    final fake = FakeRepo();
    final container = await pumpEditor(tester, fake);
    await tester.tap(find.byIcon(Icons.swap_horiz));
    await letAsyncSettle(tester);
    expect(find.text('Convert to liftplan?'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await letAsyncSettle(tester);
    expect(fake.convertCount, 0, reason: 'cancelling must not call the engine');
    expect(container.read(draftEditorProvider).draft.drive, isA<DraftTreadled>());
    expect(container.read(draftEditorProvider).undo, isEmpty);
  });

  testWidgets('a second convert while one is in flight is dropped (re-entrancy)', (tester) async {
    final fake = FakeRepo()..convertGate = Completer<void>();
    await pumpEditor(tester, fake);
    await tester.tap(find.byIcon(Icons.swap_horiz));
    await letAsyncSettle(tester);
    await tester.tap(find.text('Convert')); // confirmed -> parks inside the gated toLiftplanDoc
    await tester.pump();
    await tester.pump();
    expect(fake.convertCount, 1);
    // The button is now disabled (_converting); a second tap is a no-op.
    await tester.tap(find.byIcon(Icons.swap_horiz), warnIfMissed: false);
    await tester.pump();
    expect(fake.convertCount, 1, reason: 'a convert in flight drops a second invocation');
    fake.convertGate!.complete();
    await letAsyncSettle(tester);
  });

  testWidgets('an engine Err surfaces a SnackBar and leaves the draft treadled', (tester) async {
    final fake = FakeRepo()..convertError = true;
    final container = await pumpEditor(tester, fake);
    await tester.tap(find.byIcon(Icons.swap_horiz));
    await letAsyncSettle(tester);
    await tester.tap(find.text('Convert'));
    await letAsyncSettle(tester);
    expect(find.textContaining('Could not convert'), findsOneWidget);
    expect(container.read(draftEditorProvider).draft.drive, isA<DraftTreadled>(),
        reason: 'a failed conversion leaves the draft untouched');
    expect(container.read(draftEditorProvider).undo, isEmpty);
    expect(iconButton(tester, Icons.swap_horiz).onPressed, isNotNull,
        reason: 'a failed convert resets _converting and re-enables the button');
  });

  testWidgets('the convert dialog states cloth-preservation AND that the conversion is one-way',
      (tester) async {
    // The three consent claims the user relies on to accept a lossy, one-way op are pinned here so a
    // copy edit that drops the irreversibility warning fails a test, not just a reviewer's eye.
    await pumpEditor(tester, FakeRepo());
    await tester.tap(find.byIcon(Icons.swap_horiz));
    await letAsyncSettle(tester);
    expect(find.textContaining('woven cloth stays'), findsOneWidget, reason: 'cloth preserved');
    expect(find.textContaining('cannot convert a liftplan back'), findsOneWidget,
        reason: 'the one-way warning');
    expect(find.textContaining('undo this right after'), findsOneWidget, reason: 'undo still works');
  });

  testWidgets('converting clears a pending redo stack', (tester) async {
    final container = await pumpEditor(tester, FakeRepo());
    container.read(draftEditorProvider.notifier).toggleTieupCell(1, 1);
    await tester.pump();
    container.read(draftEditorProvider.notifier).undo(); // populate redo
    await tester.pump();
    expect(container.read(draftEditorProvider).canRedo, isTrue);

    await tester.tap(find.byIcon(Icons.swap_horiz));
    await letAsyncSettle(tester);
    await tester.tap(find.text('Convert'));
    await letAsyncSettle(tester);
    expect(container.read(draftEditorProvider).draft.drive, isA<DraftLiftplan>());
    expect(container.read(draftEditorProvider).canRedo, isFalse,
        reason: 'committing the conversion clears the stale redo');
  });

  testWidgets('a drive flip while the convert dialog is open aborts the conversion', (tester) async {
    // The post-dialog re-read (re-checking the variant on a freshly-read doc) must bail if the draft
    // became a liftplan while the modal was open, so it never calls the engine on an already-liftplan.
    final fake = FakeRepo();
    final container = await pumpEditor(tester, fake);
    await tester.tap(find.byIcon(Icons.swap_horiz));
    await letAsyncSettle(tester); // dialog open
    container.read(draftEditorProvider.notifier).load(liftplanDoc()); // drive flips under the dialog
    await tester.pump();
    await tester.tap(find.text('Convert'));
    await letAsyncSettle(tester);
    expect(fake.convertCount, 0, reason: 'the post-dialog re-read saw a liftplan and bailed');
    expect(container.read(draftEditorProvider).draft.drive, isA<DraftLiftplan>());
  });

  testWidgets('an edit landing during the convert FFI hop is preserved (stale convert dropped)',
      (tester) async {
    // The load-bearing regression test for the latest-wins guard: a concurrent Undo during the FFI
    // hop must survive, and the stale liftplan derived from the pre-edit draft must be dropped (not
    // committed over the user's edit, not clobbering redo).
    final fake = FakeRepo()..convertGate = Completer<void>();
    final container = await pumpEditor(tester, fake);
    container.read(draftEditorProvider.notifier).toggleTieupCell(1, 1); // edit B; undo=[loaded]
    await tester.pump();

    await tester.tap(find.byIcon(Icons.swap_horiz));
    await letAsyncSettle(tester);
    await tester.tap(find.text('Convert')); // confirmed -> parks inside the gated toLiftplanDoc(B)
    await tester.pump();
    await tester.pump();
    expect(fake.convertCount, 1);

    // A concurrent Undo lands while the convert is parked in the FFI hop.
    container.read(draftEditorProvider.notifier).undo(); // draft -> loaded; redo=[B]
    await tester.pump();

    fake.convertGate!.complete(); // FFI resolves with a liftplan derived from the now-stale B
    await letAsyncSettle(tester);
    final st = container.read(draftEditorProvider);
    expect(st.draft.drive, isA<DraftTreadled>(),
        reason: 'the stale liftplan was dropped, the concurrent undo survives');
    expect(st.canRedo, isTrue, reason: "the concurrent undo's redo entry was not clobbered");
  });

  testWidgets('the AppBar actions fit a standard 360dp phone without overflowing', (tester) async {
    // 7 icon actions (pencil, zoom-, zoom+, undo, redo, convert, save) plus the back button must not
    // overflow a standard 360dp phone; the compact density keeps them all hit-testable.
    tester.view.physicalSize = const Size(360 * 3, 720 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await pumpEditor(tester, FakeRepo());
    expect(tester.takeException(), isNull, reason: 'no RenderFlex overflow at 360dp');
    expect(find.byIcon(Icons.swap_horiz), findsOneWidget);
    expect(find.byIcon(Icons.save_outlined), findsOneWidget);
    expect(iconButton(tester, Icons.save_outlined).onPressed, isNotNull, reason: 'Save still usable');
  });

  // --- Phase 3.4: Save error-gating ------------------------------------------

  testWidgets('saving a draft with an Error warns, then Save anyway proceeds', (tester) async {
    final fake = FakeRepo()..issues = const [_err];
    await pumpEditor(tester, fake);
    await tester.tap(find.byIcon(Icons.save_outlined));
    await letAsyncSettle(tester);
    expect(find.text('Save with problems?'), findsOneWidget);
    expect(fake.sawSave, isFalse, reason: 'nothing written until the user consents');

    await tester.tap(find.text('Save anyway'));
    await letAsyncSettle(tester);
    expect(fake.sawSave, isTrue);
  });

  testWidgets('Cancel on the Error dialog aborts the save and re-enables Save', (tester) async {
    final fake = FakeRepo()..issues = const [_err];
    await pumpEditor(tester, fake);
    await tester.tap(find.byIcon(Icons.save_outlined));
    await letAsyncSettle(tester);
    await tester.tap(find.text('Cancel'));
    await letAsyncSettle(tester);
    expect(fake.sawSave, isFalse);
    expect(iconButton(tester, Icons.save_outlined).onPressed, isNotNull,
        reason: 'a cancelled gate resets _saving');
  });

  testWidgets('Show me on the Error dialog expands the panel and aborts the save', (tester) async {
    final fake = FakeRepo()..issues = const [_err];
    final container = await pumpEditor(tester, fake);
    await tester.tap(find.byIcon(Icons.save_outlined));
    await letAsyncSettle(tester);
    await tester.tap(find.text('Show me'));
    await letAsyncSettle(tester);
    expect(fake.sawSave, isFalse, reason: 'Show me reads, it does not save');
    expect(container.read(editorIssuesExpandedProvider), isTrue,
        reason: 'the inline panel is expanded so the user can read the problems');
  });

  testWidgets('the Error gate runs BEFORE the lossy-save gate', (tester) async {
    final fake = FakeRepo()..issues = const [_err];
    final container = await pumpEditor(tester, fake);
    container.read(draftEditorProvider.notifier).toggleTieupCell(1, 1); // dirtyStructural = true
    await tester.pump();

    await tester.tap(find.byIcon(Icons.save_outlined));
    await letAsyncSettle(tester);
    expect(find.text('Save with problems?'), findsOneWidget, reason: 'correctness gate first');
    expect(find.text('Save changes?'), findsNothing, reason: 'the lossy gate is not reached yet');

    await tester.tap(find.text('Save anyway')); // past the error gate
    await letAsyncSettle(tester);
    expect(find.text('Save changes?'), findsOneWidget, reason: 'THEN the lossy gate');
    expect(fake.sawSave, isFalse);

    await tester.tap(find.text('Save anyway')); // past the lossy gate
    await letAsyncSettle(tester);
    expect(fake.sawSave, isTrue);
    expect(fake.capturedSourceWif, isNull, reason: 're-serialized after both gates');
  });

  testWidgets('a clean-but-errored from-scratch draft gates on Errors with NO lossy dialog',
      (tester) async {
    final fake = FakeRepo()..issues = const [_err];
    final container = await pumpEditor(tester, fake);
    // A from-scratch draft (no sourceWif): the verbatim path is gone, so the lossy gate never fires.
    container.read(draftEditorProvider.notifier).load(DraftDoc.blank(shafts: 4, treadles: 4));
    await tester.pump();

    await tester.tap(find.byIcon(Icons.save_outlined));
    await letAsyncSettle(tester);
    expect(find.text('Save with problems?'), findsOneWidget);
    await tester.tap(find.text('Save anyway'));
    await letAsyncSettle(tester);
    expect(find.text('Save changes?'), findsNothing, reason: 'no imported WIF to lose');
    expect(fake.sawSave, isTrue);
  });

  testWidgets('Warnings do NOT gate Save', (tester) async {
    final fake = FakeRepo()..issues = const [_warn];
    await pumpEditor(tester, fake);
    await tester.tap(find.byIcon(Icons.save_outlined));
    await letAsyncSettle(tester);
    expect(find.text('Save with problems?'), findsNothing);
    expect(fake.sawSave, isTrue, reason: 'a warning is advisory, never blocks a save');
  });

  testWidgets('the Save gate re-validates fresh and catches an Error the live panel missed',
      (tester) async {
    // STALE-AT-SAVE: the async panel validated clean; Save must compute its OWN ground truth so an
    // Error introduced after the last panel validate is not missed.
    final fake = FakeRepo(); // issues = [] -> the panel shows nothing
    await pumpEditor(tester, fake);
    expect(find.text('Save with problems?'), findsNothing);

    fake.issues = const [_err]; // a problem the panel's stale AsyncValue hasn't observed
    await tester.tap(find.byIcon(Icons.save_outlined));
    await letAsyncSettle(tester);
    expect(find.text('Save with problems?'), findsOneWidget,
        reason: 'the Save gate re-validates the exact draft it will persist');
  });

  testWidgets('the Save gate fails closed when the validity check throws', (tester) async {
    final fake = FakeRepo()..validateError = true;
    await pumpEditor(tester, fake);
    await tester.tap(find.byIcon(Icons.save_outlined));
    await letAsyncSettle(tester);
    // The root ScaffoldMessenger mirrors the snackbar onto both the test-host and editor Scaffolds,
    // so assert "at least one" (the count is a nested-Scaffold test artifact, not production).
    expect(find.textContaining('Could not check the pattern'), findsAtLeastNWidgets(1));
    expect(fake.sawSave, isFalse, reason: 'refuse to save when correctness cannot be confirmed');
  });

  testWidgets('an edit landing during the Save validate hop is preserved (stale save bails)',
      (tester) async {
    // The Save twin of the convert/resize latest-wins guard: the canvas stays live during the gate's
    // validate FFI hop, so an edit landing there must survive, and the stale capture must NOT persist.
    final fake = FakeRepo();
    final container = await pumpEditor(tester, fake); // initial validate (clean) resolves
    fake.validateGate = Completer<void>();

    await tester.tap(find.byIcon(Icons.save_outlined));
    await tester.pump(); // _saving set; the gate's validateDto parks on validateGate
    container.read(draftEditorProvider.notifier).toggleTieupCell(1, 1); // edit during the hop
    final edited = container.read(draftEditorProvider).draft;
    await tester.pump();

    fake.validateGate!.complete();
    await letAsyncSettle(tester);
    expect(fake.sawSave, isFalse, reason: 'the stale capture was not persisted');
    expect(container.read(draftEditorProvider).draft, equals(edited),
        reason: 'the concurrent edit survived');
  });

  testWidgets('the expanded-panel chrome resets on a fresh load (no cross-session bleed)',
      (tester) async {
    final fake = FakeRepo()..issues = const [_err];
    final container = await pumpEditor(tester, fake);
    await tester.tap(find.byIcon(Icons.save_outlined));
    await letAsyncSettle(tester);
    await tester.tap(find.text('Show me'));
    await letAsyncSettle(tester);
    expect(container.read(editorIssuesExpandedProvider), isTrue);

    // A fresh editor session (new EditorScreen -> _load) must reset the expanded chrome.
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: EditorScreen(wifText: 'WIF', title: 'T2')),
      ),
    );
    await letAsyncSettle(tester);
    expect(container.read(editorIssuesExpandedProvider), isFalse,
        reason: 'a new editor load resets the panel-expanded chrome');
  });

  testWidgets('a mixed issue set gates on the ERROR count only', (tester) async {
    final fake = FakeRepo()..issues = const [_err, _warn, _warn];
    await pumpEditor(tester, fake);
    await tester.tap(find.byIcon(Icons.save_outlined));
    await letAsyncSettle(tester);
    // 1 error + 2 warnings -> the dialog counts the 1 error, not all 3 issues.
    expect(find.textContaining('1 problem'), findsOneWidget);
    expect(find.textContaining('3 problem'), findsNothing);
    await tester.tap(find.text('Save anyway'));
    await letAsyncSettle(tester);
    expect(fake.sawSave, isTrue, reason: 'the two warnings never re-gate');
  });

  testWidgets('Show me, then re-tapping Save re-gates and Save anyway proceeds', (tester) async {
    final fake = FakeRepo()..issues = const [_err];
    await pumpEditor(tester, fake);
    await tester.tap(find.byIcon(Icons.save_outlined));
    await letAsyncSettle(tester);
    await tester.tap(find.text('Show me'));
    await letAsyncSettle(tester);
    expect(fake.sawSave, isFalse);
    expect(iconButton(tester, Icons.save_outlined).onPressed, isNotNull, reason: 'Save re-enabled');

    // The dialog is not suppressed, so a second Save tap re-gates.
    await tester.tap(find.byIcon(Icons.save_outlined));
    await letAsyncSettle(tester);
    expect(find.text('Save with problems?'), findsOneWidget);
    await tester.tap(find.text('Save anyway'));
    await letAsyncSettle(tester);
    expect(fake.sawSave, isTrue);
  });
}
