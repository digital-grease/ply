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
import 'package:ply/src/models/loom_type.dart';
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
    // A NON-EMPTY 4x4 straight-draw cloth: distinct from DraftDoc.blank() (the build() default) so
    // "load reflects the draft" is real, AND with ends/picks > 0 so a save clears the editor's
    // GATE 0 (an empty draft is refused) — every save/gate test operates on this loaded draft.
    return DraftDoc.blank(shafts: 4, treadles: 4).copyWith(
      name: 'loaded',
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
  }

  @override
  Future<ui.Image> renderDto(
    DraftDoc doc, {
    required int cellPx,
    bool gridlines = false,
    int floatThreshold = 0,
    bool threadTexture = false,
  }) =>
      _stubImage();

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

/// A from-scratch draft that has been GROWN to a 1x1 plain cell — the smallest cloth that clears
/// the editor's GATE 0 (non-empty) check, so the metadata-prompt tests reach the prompt. A truly
/// blank (0x0) DraftDoc.blank() would be refused before prompting (see the GATE 0 test).
DraftDoc grownNewDraft() => DraftDoc.blank(shafts: 4, treadles: 4).copyWith(
      threading: const [
        [1],
      ],
      drive: DraftTreadled(tieup: const [
        [1],
      ], treadling: const [
        [1],
      ]),
      warpColors: const [0],
      weftColors: const [0],
    );

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

/// A SAVED-draft meta (the production reality for a wifText-based editor: Edit is gated to saved
/// drafts, so a wifText editor always carries a meta). Used as the default so save tests don't hit
/// the new-draft metadata prompt.
DraftMeta savedMeta() =>
    DraftMeta(name: 'T', savedAt: DateTime.utc(2020), lastOpened: DateTime.utc(2020));

/// Pumps a host that pushes the EditorScreen as a non-root route (so Save's pop is valid). Defaults
/// to a SAVED draft (a non-null [meta]); pass `newDraft: true` for the from-scratch path (initialDoc,
/// no meta) that prompts for metadata on first save.
Future<ProviderContainer> pumpEditor(
  WidgetTester tester,
  FakeRepo fake, {
  String? id,
  DraftMeta? meta,
  bool newDraft = false,
  DraftDoc? initialDoc,
  List<bool?>? popLog,
}) async {
  final container = ProviderContainer(
    overrides: [repositoryProvider.overrideWithValue(fake)],
  );
  addTearDown(container.dispose);
  final effectiveMeta = meta ?? (newDraft ? null : savedMeta());
  // A new draft opens on a GROWN (non-empty) doc by default so the prompt is reachable; a test can
  // pass a 0x0 DraftDoc.blank() to exercise GATE 0.
  final effectiveInitial = newDraft ? (initialDoc ?? grownNewDraft()) : null;
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                // push<bool> mirrors the real callers (Library/Preview), so a test can assert the
                // pop RESULT: a Save pops true (refresh), a Discard pops null (no refresh).
                onPressed: () async {
                  final r = await Navigator.push<bool>(
                    context,
                    MaterialPageRoute<bool>(
                      builder: (_) => EditorScreen(
                        wifText: newDraft ? null : 'WIF',
                        initialDoc: effectiveInitial,
                        title: 'T',
                        id: id,
                        meta: effectiveMeta,
                      ),
                    ),
                  );
                  popLog?.add(r);
                },
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

/// Open the AppBar overflow (⋮) menu. Convert + zoom live here now (the M4 declutter).
Future<void> openOverflow(WidgetTester tester) async {
  await tester.tap(find.byTooltip('More actions'));
  await tester.pumpAndSettle();
}

/// The overflow's "Convert to liftplan" menu item (the menu must be OPEN). Cast to the raw generic
/// since its value type is private to editor_screen.dart.
PopupMenuItem convertItem(WidgetTester tester) => tester.widget(find.ancestor(
      of: find.text('Convert to liftplan'),
      matching: find.byWidgetPredicate((w) => w is PopupMenuItem),
    )) as PopupMenuItem;

/// Open the overflow and tap Convert (which then raises the confirm dialog).
Future<void> tapConvert(WidgetTester tester) async {
  await openOverflow(tester);
  await tester.tap(find.text('Convert to liftplan'));
  await letAsyncSettle(tester);
}

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

  testWidgets('convert (in the overflow) is enabled on a treadled draft, DISABLED on a liftplan',
      (tester) async {
    final container = await pumpEditor(tester, FakeRepo()); // parseDoc returns a treadled draft
    await openOverflow(tester);
    expect(find.text('Convert to liftplan'), findsOneWidget, reason: 'listed in the overflow');
    expect(convertItem(tester).enabled, isTrue, reason: 'a treadled draft can be converted');
    await tester.tapAt(const Offset(5, 5)); // dismiss the menu via its barrier
    await tester.pumpAndSettle();

    // Load a liftplan draft: the action greys out (disabled, not hidden — still discoverable).
    container.read(draftEditorProvider.notifier).load(liftplanDoc());
    await tester.pump();
    await openOverflow(tester);
    expect(convertItem(tester).enabled, isFalse, reason: 'already a liftplan -> disabled, not hidden');
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
  });

  testWidgets('convert confirms, commits ONE undo entry, and Undo reverts to treadled',
      (tester) async {
    final fake = FakeRepo();
    final container = await pumpEditor(tester, fake);
    await tapConvert(tester);
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
    await tapConvert(tester);
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
    await tapConvert(tester);
    await tester.tap(find.text('Convert')); // confirmed -> parks inside the gated toLiftplanDoc
    await tester.pump();
    await tester.pump();
    expect(fake.convertCount, 1);
    // Convert is now disabled (_converting), so a second invocation can't fire.
    await openOverflow(tester);
    expect(convertItem(tester).enabled, isFalse, reason: 'a convert in flight disables a second');
    await tester.tapAt(const Offset(5, 5)); // dismiss
    await tester.pump();
    expect(fake.convertCount, 1, reason: 'a convert in flight drops a second invocation');
    fake.convertGate!.complete();
    await letAsyncSettle(tester);
  });

  testWidgets('an engine Err surfaces a SnackBar and leaves the draft treadled', (tester) async {
    final fake = FakeRepo()..convertError = true;
    final container = await pumpEditor(tester, fake);
    await tapConvert(tester);
    await tester.tap(find.text('Convert'));
    await letAsyncSettle(tester);
    expect(find.textContaining('Could not convert'), findsOneWidget);
    expect(container.read(draftEditorProvider).draft.drive, isA<DraftTreadled>(),
        reason: 'a failed conversion leaves the draft untouched');
    expect(container.read(draftEditorProvider).undo, isEmpty);
    await openOverflow(tester);
    expect(convertItem(tester).enabled, isTrue,
        reason: 'a failed convert resets _converting and re-enables convert');
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
  });

  testWidgets('the convert dialog states cloth-preservation AND that the conversion is one-way',
      (tester) async {
    // The three consent claims the user relies on to accept a lossy, one-way op are pinned here so a
    // copy edit that drops the irreversibility warning fails a test, not just a reviewer's eye.
    await pumpEditor(tester, FakeRepo());
    await tapConvert(tester);
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

    await tapConvert(tester);
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
    await tapConvert(tester); // dialog open
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

    await tapConvert(tester);
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

  testWidgets('the AppBar fits a standard 360dp phone (M4 declutter: zoom + convert in the overflow)',
      (tester) async {
    // After M4 the bar is pencil, undo, redo, save + an overflow (⋮) — zoom and convert moved into
    // the overflow — plus the back button, comfortably hit-testable at 360dp.
    tester.view.physicalSize = const Size(360 * 3, 720 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await pumpEditor(tester, FakeRepo());
    expect(tester.takeException(), isNull, reason: 'no RenderFlex overflow at 360dp');
    expect(find.byIcon(Icons.more_vert), findsOneWidget, reason: 'the overflow (⋮) button');
    expect(find.byIcon(Icons.save_outlined), findsOneWidget);
    expect(iconButton(tester, Icons.save_outlined).onPressed, isNotNull, reason: 'Save still usable');
  });

  testWidgets('the editor uses a side-rail Row on a wide screen, a vertical stack on a phone',
      (tester) async {
    // Wide (the default 800px host viewport >= the 600 breakpoint): controls move to a side rail so
    // the cloth keeps the full height. The VerticalDivider exists ONLY in that wide layout.
    await pumpEditor(tester, FakeRepo());
    expect(find.byType(VerticalDivider), findsOneWidget, reason: 'wide -> side rail');

    // Narrow phone: the original vertical stack (no side rail).
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pump();
    expect(find.byType(VerticalDivider), findsNothing, reason: 'narrow -> vertical stack');
  });

  testWidgets('the overflow Sinking shed item flips the draft shed as one undo entry', (tester) async {
    final container = await pumpEditor(tester, FakeRepo()); // loaded draft is rising-shed
    expect(container.read(draftEditorProvider).draft.shed, Shed.rising);

    await openOverflow(tester);
    await tester.tap(find.text('Sinking shed'));
    await tester.pumpAndSettle();

    final st = container.read(draftEditorProvider);
    expect(st.draft.shed, Shed.sinking, reason: 'the toggle set sinking');
    expect(st.undo.length, 1, reason: 'one undo entry for the shed change');
    expect(st.dirtyStructural, isTrue, reason: 'a shed change is structural');
  });

  testWidgets('Loom type -> Counterbalance applies a sinking shed and records the type',
      (tester) async {
    final container = await pumpEditor(tester, FakeRepo()); // loaded jack/rising/treadled
    expect(container.read(loomTypeProvider), LoomType.jack);

    await openOverflow(tester);
    await tester.tap(find.text('Loom type…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Counterbalance (floor loom)'));
    await tester.pumpAndSettle();

    expect(container.read(draftEditorProvider).draft.shed, Shed.sinking);
    expect(container.read(loomTypeProvider), LoomType.counterbalance);
  });

  testWidgets('Loom type -> Table converts a treadled draft to a liftplan (after confirm)',
      (tester) async {
    final container = await pumpEditor(tester, FakeRepo());
    expect(container.read(draftEditorProvider).draft.drive, isA<DraftTreadled>());

    await openOverflow(tester);
    await tester.tap(find.text('Loom type…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Table loom'));
    await tester.pumpAndSettle(); // the loom requires a liftplan -> convert-confirm dialog
    expect(find.text('Convert to liftplan?'), findsOneWidget);
    await tester.tap(find.text('Convert'));
    await letAsyncSettle(tester);

    expect(container.read(draftEditorProvider).draft.drive, isA<DraftLiftplan>());
    expect(container.read(loomTypeProvider), LoomType.table);
  });

  testWidgets('Loom type -> a floor loom is refused on a liftplan draft (one-way limit)',
      (tester) async {
    final container = await pumpEditor(tester, FakeRepo());
    // Drive it to a liftplan (table/dobby) first.
    container.read(draftEditorProvider.notifier).commitEdit(
        container.read(draftEditorProvider).draft.copyWith(
            drive: DraftLiftplan(liftplan: const [
              [1],
            ]),
            treadles: 0));
    container.read(loomTypeProvider.notifier).state = LoomType.dobby;
    await tester.pump();

    await openOverflow(tester);
    await tester.tap(find.text('Loom type…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Jack (floor loom)'));
    await tester.pumpAndSettle();

    expect(container.read(draftEditorProvider).draft.drive, isA<DraftLiftplan>(),
        reason: 'still a liftplan — the floor-loom switch was refused');
    expect(container.read(loomTypeProvider), LoomType.dobby, reason: 'loom type unchanged');
    expect(find.textContaining("isn't supported yet"), findsOneWidget);
  });

  testWidgets('a 4-shaft (double-weave) draft surfaces View layers in the overflow menu',
      (tester) async {
    // The loaded fixture is a 4-shaft, 4-pick cloth (the same shape a generated double weave has), so
    // the layer inspector must be reachable. Proves the menu logic; the alpha "no way to switch
    // layers" report is therefore about discoverability (it lives in the ⋮ overflow), not absence.
    await pumpEditor(tester, FakeRepo());
    await openOverflow(tester);
    expect(find.text('View layers'), findsOneWidget);
  });

  testWidgets('a double-weave draft shows a VISIBLE Layers chip (not just the overflow)',
      (tester) async {
    await pumpEditor(tester, FakeRepo()); // 4-shaft loaded draft
    expect(find.widgetWithText(ActionChip, 'Layers'), findsOneWidget,
        reason: 'layer switching is discoverable without opening the overflow menu');
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
    // Non-empty (grown) so it clears GATE 0 and reaches the Error gate under test.
    container.read(draftEditorProvider.notifier).load(grownNewDraft());
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

  testWidgets('a NEW draft prompts for name on first save, then saves with that meta', (tester) async {
    final fake = FakeRepo();
    await pumpEditor(tester, fake, newDraft: true); // initialDoc, meta == null
    await tester.tap(find.byIcon(Icons.save_outlined));
    await letAsyncSettle(tester);
    expect(find.text('Save pattern'), findsOneWidget, reason: 'the metadata dialog appears');
    expect(fake.sawSave, isFalse, reason: 'nothing saved until the name is entered');

    // Fill ALL three fields so the whole metadata payload (not just the name) is asserted to reach
    // saveDto — author/notes are easy to silently drop on the wire.
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'My scarf');
    await tester.enterText(find.widgetWithText(TextField, 'Author (optional)'), 'Ada');
    await tester.enterText(find.widgetWithText(TextField, 'Notes (optional)'), 'heirloom');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await letAsyncSettle(tester);
    expect(fake.sawSave, isTrue);
    expect(fake.capturedMeta!.name, 'My scarf');
    expect(fake.capturedMeta!.author, 'Ada', reason: 'the author flows through to saveDto');
    expect(fake.capturedMeta!.notes, 'heirloom', reason: 'the notes flow through to saveDto');
    expect(fake.capturedMeta!.craft, 'Weaving');
    expect(fake.capturedSourceWif, isNull, reason: 'a from-scratch draft has no source WIF');
  });

  testWidgets('a NEW draft EDITED before its first save still prompts and does NOT warn about loss',
      (tester) async {
    // The path production hits when a weaver builds a cloth then saves: the draft is structurally
    // dirty, but a from-scratch draft has no sourceWif, so there is nothing to lose -> no lossy
    // "Save changes?" warning, just the metadata prompt.
    final fake = FakeRepo();
    final container = await pumpEditor(tester, fake, newDraft: true);
    container.read(draftEditorProvider.notifier).toggleTieupCell(1, 1); // mark dirtyStructural
    await tester.pump();
    await tester.tap(find.byIcon(Icons.save_outlined));
    await letAsyncSettle(tester);
    expect(find.text('Save changes?'), findsNothing, reason: 'no source WIF -> nothing lossy to warn about');
    expect(find.text('Save pattern'), findsOneWidget, reason: 'still prompts for the new name');

    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Edited scarf');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await letAsyncSettle(tester);
    expect(fake.capturedMeta!.name, 'Edited scarf');
    expect(fake.capturedSourceWif, isNull);
  });

  testWidgets('a still-EMPTY (0x0) new draft is refused before prompting or saving', (tester) async {
    // GATE 0: DraftDoc.blank() is 0 ends/0 picks; saving it would hang on the 0-area thumbnail
    // decode and persist a meaningless entry. Refuse with a clear message instead.
    final fake = FakeRepo();
    await pumpEditor(tester, fake,
        newDraft: true, initialDoc: DraftDoc.blank(shafts: 4, treadles: 4));
    await tester.tap(find.byIcon(Icons.save_outlined));
    await letAsyncSettle(tester);
    expect(find.textContaining('Add at least one end'), findsAtLeastNWidgets(1));
    expect(find.text('Save pattern'), findsNothing, reason: 'no metadata prompt for an empty draft');
    expect(fake.sawSave, isFalse, reason: 'an empty draft is never persisted');
    expect(iconButton(tester, Icons.save_outlined).onPressed, isNotNull, reason: 'Save re-enabled');
  });

  test('the constructor requires EXACTLY ONE of wifText / initialDoc', () {
    expect(() => EditorScreen(title: 'x'), throwsAssertionError,
        reason: 'neither source provided');
    expect(
        () => EditorScreen(title: 'x', wifText: 'w', initialDoc: DraftDoc.blank()),
        throwsAssertionError,
        reason: 'both sources provided');
  });

  testWidgets('cancelling the name prompt aborts the new-draft save', (tester) async {
    final fake = FakeRepo();
    await pumpEditor(tester, fake, newDraft: true);
    await tester.tap(find.byIcon(Icons.save_outlined));
    await letAsyncSettle(tester);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await letAsyncSettle(tester);
    expect(fake.sawSave, isFalse, reason: 'no save without a name');
    expect(iconButton(tester, Icons.save_outlined).onPressed, isNotNull, reason: 'Save re-enabled');
  });

  testWidgets('a SAVED draft (meta present) does NOT prompt for metadata', (tester) async {
    final fake = FakeRepo();
    await pumpEditor(tester, fake); // default: a saved draft with meta
    await tester.tap(find.byIcon(Icons.save_outlined));
    await letAsyncSettle(tester);
    expect(find.text('Save pattern'), findsNothing, reason: 'an existing meta is reused, not re-prompted');
    expect(fake.sawSave, isTrue);
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

  testWidgets('the AppBar actions carry their tooltips into the semantics (M4 a11y)', (tester) async {
    // A Flutter IconButton with a `tooltip` wraps it in a Tooltip, which sets the semantic TOOLTIP
    // property (not `label`) — screen readers DO announce it, so the editor's tooltipped actions are
    // already labelled. Pin it (via the semantic tooltip data) so a refactor dropping the tooltips is
    // caught.
    final handle = tester.ensureSemantics();
    await pumpEditor(tester, FakeRepo()); // a loaded saved draft
    for (final label in ['Undo', 'Redo', 'Save']) {
      expect(find.byTooltip(label), findsOneWidget, reason: '$label has a tooltip');
      final data = tester.getSemantics(find.byTooltip(label)).getSemanticsData();
      expect(data.tooltip, contains(label), reason: '$label is in the semantics for a screen reader');
    }
    handle.dispose();
  });

  group('dirty-on-exit guard (Phase 5.3)', () {
    testWidgets('a CLEAN editor pops straight back with no prompt', (tester) async {
      await pumpEditor(tester, FakeRepo()); // loaded, no edits
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle(); // let the pop transition finish (no spinner once loaded)
      expect(find.text('Leave without saving?'), findsNothing);
      expect(find.byType(EditorScreen), findsNothing, reason: 'a clean back exits immediately');
    });

    testWidgets('back on a DIRTY editor prompts; Keep editing stays put', (tester) async {
      final fake = FakeRepo();
      final container = await pumpEditor(tester, fake);
      container.read(draftEditorProvider.notifier).toggleTieupCell(1, 1); // dirtyStructural
      await tester.pump();
      await tester.tap(find.byType(BackButton));
      await letAsyncSettle(tester);
      expect(find.text('Leave without saving?'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'Keep editing'));
      await letAsyncSettle(tester);
      expect(find.byType(EditorScreen), findsOneWidget, reason: 'still editing');
      expect(fake.sawSave, isFalse);
    });

    testWidgets('Discard leaves WITHOUT saving and pops a non-true result (no caller refresh)',
        (tester) async {
      final fake = FakeRepo();
      final popLog = <bool?>[];
      final container = await pumpEditor(tester, fake, popLog: popLog);
      container.read(draftEditorProvider.notifier).toggleTieupCell(1, 1);
      await tester.pump();
      await tester.tap(find.byType(BackButton));
      await letAsyncSettle(tester);
      await tester.tap(find.widgetWithText(TextButton, 'Discard'));
      await tester.pumpAndSettle();
      expect(find.byType(EditorScreen), findsNothing, reason: 'discard exits');
      expect(fake.sawSave, isFalse, reason: 'nothing persisted on discard');
      // The real callers (Library _newDraft / Preview _onEdit) refresh ONLY on `== true`; a discard
      // must pop a non-true result so a discarded edit never triggers a spurious library refresh.
      expect(popLog.single, isNot(true), reason: 'discard pops null, not true');
    });

    testWidgets('Save from the leave prompt runs the full save flow then exits', (tester) async {
      // A from-scratch draft: no sourceWif (so no lossy gate), so the only nested step is the
      // metadata prompt — proving the prompt's Save delegates to the real gated _save.
      final fake = FakeRepo();
      final popLog = <bool?>[];
      final container = await pumpEditor(tester, fake, newDraft: true, popLog: popLog);
      container.read(draftEditorProvider.notifier).toggleTieupCell(1, 1); // dirty
      await tester.pump();
      await tester.tap(find.byType(BackButton));
      await letAsyncSettle(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await letAsyncSettle(tester);
      expect(find.text('Save pattern'), findsOneWidget, reason: 'Save routes into the gated _save');
      await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Kept');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(fake.sawSave, isTrue);
      expect(fake.capturedMeta!.name, 'Kept');
      expect(find.byType(EditorScreen), findsNothing, reason: 'a successful save exits');
      expect(popLog.single, isTrue, reason: 'a saved exit pops true so the caller refreshes');
    });

    testWidgets('the Save AppBar action still exits a dirty draft directly (PopScope gates only back)',
        (tester) async {
      // The Save button's own Navigator.pop(true) is an unconditional pop, so a dirty save must NOT
      // re-trigger the leave prompt. (A saved draft re-serialized while dirty hits the lossy gate.)
      final fake = FakeRepo();
      final container = await pumpEditor(tester, fake);
      container.read(draftEditorProvider.notifier).toggleTieupCell(1, 1);
      await tester.pump();
      await tester.tap(find.byIcon(Icons.save_outlined));
      await letAsyncSettle(tester);
      await tester.tap(find.text('Save anyway')); // clear the lossy gate
      await tester.pumpAndSettle();
      expect(find.text('Leave without saving?'), findsNothing, reason: 'no back prompt on a save');
      expect(fake.sawSave, isTrue);
      expect(find.byType(EditorScreen), findsNothing, reason: 'save exits');
    });

    testWidgets('the leave prompt orders Discard | Keep editing | Save, Save primary, Discard red',
        (tester) async {
      final fake = FakeRepo();
      final container = await pumpEditor(tester, fake);
      container.read(draftEditorProvider.notifier).toggleTieupCell(1, 1);
      await tester.pump();
      await tester.tap(find.byType(BackButton));
      await letAsyncSettle(tester);

      expect(find.widgetWithText(FilledButton, 'Save'), findsOneWidget, reason: 'Save is the primary');
      // Destructive Discard is LEFTMOST, separated from the rightmost primary Save by Keep editing,
      // so a mis-tap toward Save never lands on data loss.
      final dxDiscard = tester.getCenter(find.text('Discard')).dx;
      final dxKeep = tester.getCenter(find.text('Keep editing')).dx;
      final dxSave = tester.getCenter(find.text('Save')).dx;
      expect(dxDiscard, lessThan(dxKeep), reason: 'Discard left of Keep editing');
      expect(dxKeep, lessThan(dxSave), reason: 'Keep editing left of Save');
      // Discard carries the theme error color as its destructive cue.
      final ctx = tester.element(find.byType(AlertDialog));
      final discard = tester.widget<TextButton>(find.widgetWithText(TextButton, 'Discard'));
      expect(discard.style?.foregroundColor?.resolve(<WidgetState>{}),
          Theme.of(ctx).colorScheme.error, reason: 'Discard is styled destructive');
    });

    testWidgets('Save from the leave prompt on a still-empty 0x0 draft shows GATE 0 and stays',
        (tester) async {
      // A draft shrunk to 0x0 is dirty but unsaveable (GATE 0). The leave prompt's Save delegates to
      // the gated _save, which surfaces the clear "add a cell" message and leaves the user in the
      // editor (free to Discard or grow) — not a silent dead-end, and never a persisted empty entry.
      final fake = FakeRepo();
      final container = await pumpEditor(tester, fake); // loaded non-empty, dirty=false
      container.read(draftEditorProvider.notifier).commitEdit(DraftDoc.blank()); // dirty + 0x0
      await tester.pump();
      await tester.tap(find.byType(BackButton));
      await letAsyncSettle(tester);
      expect(find.text('Leave without saving?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await letAsyncSettle(tester);
      expect(find.textContaining('Add at least one end'), findsAtLeastNWidgets(1),
          reason: 'GATE 0 explains why an empty draft cannot be saved');
      expect(find.byType(EditorScreen), findsOneWidget, reason: 'stays in the editor (not stuck)');
      expect(fake.sawSave, isFalse, reason: 'an empty draft is never persisted');
    });

    testWidgets('REPRO: AppBar Save in flight + back -> Discard double-pop past the parent',
        (tester) async {
      // A from-scratch draft so there is no lossy gate; after validate resolves the save would go
      // straight to the metadata prompt (and on its OK, pop). Hold the SAVE validate in flight, then
      // press back and Discard. If the finding is real, the Discard's imperative pop AND the resumed
      // _save's pop both fire, over-popping past the parent (host) route.
      final fake = FakeRepo();
      final container = await pumpEditor(tester, fake, newDraft: true);
      container.read(draftEditorProvider.notifier).toggleTieupCell(1, 1); // dirty
      await tester.pump();

      fake.validateGate = Completer<void>(); // park the Save gate's validate FFI hop
      await tester.tap(find.byIcon(Icons.save_outlined));
      await tester.pump(); // _saving set; validate parks
      expect(find.byType(EditorScreen), findsOneWidget);

      // Back-press DURING the in-flight save -> the leave prompt (back path is NOT _saving-gated).
      await tester.tap(find.byType(BackButton));
      await letAsyncSettle(tester);
      expect(find.text('Leave without saving?'), findsOneWidget,
          reason: 'the back path opens the leave prompt even mid-save');

      // Discard: imperative pop of the editor route. Resolve the parked save in the SAME window so
      // the resumed _save races the discard's exit transition (the realistic timing).
      await tester.tap(find.widgetWithText(TextButton, 'Discard'));
      await tester.pump(); // let the discard pop start (transition begins)
      fake.validateGate!.complete(); // _save resumes now, mid-transition
      await tester.pump();
      await tester.pumpAndSettle();

      // Final state. The host route ("open" button) MUST still be present; the editor gone. A
      // double-pop would also have removed the host route (over-popped the parent).
      expect(find.byType(EditorScreen), findsNothing, reason: 'the editor is gone (discarded)');
      expect(find.text('open'), findsOneWidget,
          reason: 'the parent route must survive: the resumed save must not pop a second time');
      expect(fake.sawSave, isFalse,
          reason: 'a discarded editor must not persist via the resumed save');
    });

    testWidgets('REPRO (edit path, tightest race): saved-draft Save in flight + back -> Discard',
        (tester) async {
      // The SAVED-draft path is the worst case for the finding: after validate resolves there is NO
      // metadata dialog, so the only async hop between resume and navigator.pop(true) is saveDto.
      final fake = FakeRepo();
      final container = await pumpEditor(tester, fake); // saved draft (meta present, sourceWif set)
      container.read(draftEditorProvider.notifier).toggleTieupCell(1, 1); // dirty
      await tester.pump();

      fake.validateGate = Completer<void>();
      await tester.tap(find.byIcon(Icons.save_outlined));
      await tester.pump(); // _saving set; validate parks (lossy gate is AFTER validate, not reached)

      await tester.tap(find.byType(BackButton));
      await letAsyncSettle(tester);
      expect(find.text('Leave without saving?'), findsOneWidget);
      // Tightest possible race: complete the gate in the SAME turn as the Discard tap, BEFORE any
      // pump, so the microtask resuming _save is queued right behind the imperative discard pop and
      // the route's exit transition has not advanced at all.
      // Realistic ordering: a real validateDto FFI resolves on a LATER event-loop turn, never
      // synchronously inside the Discard tap handler. Pump the discard pop first, THEN resolve.
      await tester.tap(find.widgetWithText(TextButton, 'Discard'));
      await tester.pump(); // discard pop begins its exit transition
      fake.validateGate!.complete(); // _save resumes on the next turn, mid-transition
      await tester.pumpAndSettle();

      expect(find.text('open'), findsOneWidget,
          reason: 'parent route survives: no second pop from the resumed edit-path save');
      expect(find.byType(EditorScreen), findsNothing, reason: 'the editor is gone (discarded)');
      expect(fake.sawSave, isFalse,
          reason: 'the resumed save bailed at !mounted (saveCount stays 0) before persisting');
    });
  });
}
