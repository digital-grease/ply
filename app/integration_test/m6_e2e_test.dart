// M2 Phase-6.1 device proof: the WHOLE editing loop, end to end, on a real device + filesystem.
//
// One imported draft accumulates EVERY edit type — tie-up, threading, treadling, palette,
// warp colors, weft colors, and a resize — through the real EditorState reducers + FFI, and the
// engine-rendered drawdown CHANGES at each step (so each edit is genuinely live). The final cloth
// is Saved through the structural-dirty path (write_wif), reopened from disk via a FRESH
// repository (a relaunch), and renders BYTE-IDENTICAL to the in-memory edited cloth while
// validating clean. Undo walks the whole mixed history back to the import; redo returns it. A new
// blank draft then grows + round-trips. (The end-0-LEFT / pick-0-BOTTOM orientation contract is
// pinned separately by m2_editor_test.)
//
//   flutter test integration_test/m6_e2e_test.dart -d emulator-5554

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:ply/src/data/draft_repository.dart';
import 'package:ply/src/models/draft_doc.dart';
import 'package:ply/src/models/editor_state.dart';
import 'package:ply/src/models/draft_meta.dart';
import 'package:ply/src/rust/frb_generated.dart';

/// A 4x4, 2/2 twill whose every section is non-trivial, so each edit type below visibly reshapes
/// the cloth. palette: 0=black, 1=white; warp all black, weft all white. SINKING shed on purpose:
/// the only non-default `Rising Shed` value, so the save->reopen round-trip actually exercises shed
/// write/parse fidelity (a regression that always wrote Rising would survive a Rising-only draft).
const String kTwillWif = '''[WIF]
Version=1.1
[WEAVING]
Shafts=4
Treadles=4
Rising Shed=false
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

Future<Uint8List> rawBytes(ui.Image image) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  return data!.buffer.asUint8List();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  testWidgets('the full editing loop: import -> every edit live -> save -> reopen -> undo/redo',
      (tester) async {
    final repo = DraftRepository();
    const px = 8;

    // IMPORT.
    final imported = await repo.parseDoc(kTwillWif);
    final importedBytes = await rawBytes(await repo.renderDto(imported, cellPx: px));

    // Each step renders and must DIFFER from the step before it — i.e. the edit reached the cloth.
    var state = EditorState(draft: imported);
    var prev = importedBytes;
    Future<void> stepChangesCloth(EditorState next, String label) async {
      expect(next.dirtyStructural, isTrue, reason: '$label marks the draft dirty');
      final bytes = await rawBytes(await repo.renderDto(next.draft, cellPx: px));
      expect(bytes, isNot(equals(prev)), reason: '$label changes the rendered cloth');
      prev = bytes;
      state = next;
    }

    // 1. TIE-UP: untie shaft 1 from treadle 1.
    await stepChangesCloth(state.toggleTieupCell(1, 1), 'tie-up edit');

    // 2. THREADING: rethread end 0 onto shaft 2 (was shaft 1).
    final newThreading = [...state.draft.threading.map((e) => [...e])]..[0] = const [2];
    await stepChangesCloth(
        state.commitEdit(state.draft.copyWith(threading: newThreading)), 'threading edit');

    // 3. TREADLING: change pick 0 to treadle 2 (was treadle 1).
    final td = state.draft.drive as DraftTreadled;
    final newTreadling = [...td.treadling.map((e) => [...e])]..[0] = const [2];
    await stepChangesCloth(
        state.commitEdit(state.draft.copyWith(
            drive: DraftTreadled(tieup: td.tieup, treadling: newTreadling))),
        'treadling edit');

    // 4. PALETTE: recolor index 1 (white -> red); the weft uses it, so the cloth shifts.
    await stepChangesCloth(
        state.setPaletteColor(1, const DraftColor(r: 220, g: 20, b: 20)), 'palette recolor');

    // 5. WARP COLORS: stripe black/red across the warp (was all black).
    await stepChangesCloth(state.fillWarpStripe([0, 1]), 'warp colour stripe');

    // 6. WEFT COLORS: stripe red/black across the weft (was all index 1).
    await stepChangesCloth(state.fillWeftStripe([1, 0]), 'weft colour stripe');

    // 7. RESIZE: shrink 4x4 -> 3x3 (truncates every section; stays valid).
    final resized = await repo.resizeDoc(state.draft, ends: 3, picks: 3, shafts: 4, treadles: 4);
    await stepChangesCloth(state.commitEdit(resized), 'resize');

    final editedDraft = state.draft;
    final editedBytes = prev;
    expect((await repo.validateDto(editedDraft)).where((i) => i.isError), isEmpty,
        reason: 'the fully-edited cloth validates clean');

    // SAVE through the structural-dirty path (sourceWif null -> re-serialize via write_wif).
    final meta = DraftMeta(name: 'e2e', savedAt: DateTime.now(), lastOpened: DateTime.now());
    final id = await repo.saveDto(editedDraft, meta: meta, sourceWif: null);
    addTearDown(() => repo.delete(id));

    // REOPEN from disk via a FRESH repository instance — the relaunch a weaver would do.
    final fresh = DraftRepository();
    final reopened = await fresh.parseDoc(await fresh.readWif(id));
    final reopenedBytes = await rawBytes(await fresh.renderDto(reopened, cellPx: px));
    expect(reopenedBytes, equals(editedBytes),
        reason: 'the reopened cloth is byte-identical to the edited one (persistence is faithful)');
    expect((await fresh.validateDto(reopened)).where((i) => i.isError), isEmpty,
        reason: 'the reopened draft validates clean');
    expect(editedDraft.shed, Shed.sinking, reason: 'the draft is sinking-shed throughout');
    expect(reopened.shed, equals(editedDraft.shed),
        reason: 'shed survives write_wif -> parse (catches an always-write-Rising regression)');
    final reDrive = reopened.drive as DraftTreadled;
    final edDrive = editedDraft.drive as DraftTreadled;
    expect(reopened.threading, equals(editedDraft.threading));
    expect(reDrive.tieup, equals(edDrive.tieup));
    expect(reDrive.treadling, equals(edDrive.treadling));
    expect(reopened.warpColors, equals(editedDraft.warpColors));
    expect(reopened.weftColors, equals(editedDraft.weftColors));
    expect(reopened.palette, equals(editedDraft.palette));

    // UNDO the whole mixed history back to the import.
    var unwind = state;
    var steps = 0;
    while (unwind.canUndo) {
      unwind = unwind.undoEdit();
      steps++;
    }
    expect(steps, 7, reason: 'one undo entry per edit in the chain');
    expect(await rawBytes(await repo.renderDto(unwind.draft, cellPx: px)), equals(importedBytes),
        reason: 'undoing every edit renders the original imported cloth');

    // REDO all the way returns to the fully-edited cloth.
    var rewind = unwind;
    while (rewind.canRedo) {
      rewind = rewind.redoEdit();
    }
    expect(await rawBytes(await repo.renderDto(rewind.draft, cellPx: px)), equals(editedBytes),
        reason: 'redoing every edit returns the fully-edited cloth');
  });

  testWidgets('a NEW blank draft grows then round-trips through save + reopen', (tester) async {
    final repo = DraftRepository();
    // Start blank (0x0), grow to a 2x2 plain cell with threading + tie-up + treadling + colours.
    final grown = DraftDoc.blank(shafts: 2, treadles: 2).copyWith(
      name: 'fresh',
      threading: const [
        [1],
        [2],
      ],
      drive: DraftTreadled(tieup: const [
        [1],
        [2],
      ], treadling: const [
        [1],
        [2],
      ]),
      warpColors: const [0, 0],
      weftColors: const [1, 1],
    );
    final meta = DraftMeta(name: 'fresh', savedAt: DateTime.now(), lastOpened: DateTime.now());
    final id = await repo.saveDto(grown, meta: meta, sourceWif: null);
    addTearDown(() => repo.delete(id));

    final fresh = DraftRepository();
    final reopened = await fresh.parseDoc(await fresh.readWif(id));
    expect(reopened.ends, 2);
    expect(reopened.picks, 2);
    expect((await fresh.validateDto(reopened)).where((i) => i.isError), isEmpty);
    expect(await rawBytes(await fresh.renderDto(reopened, cellPx: 10)),
        equals(await rawBytes(await repo.renderDto(grown, cellPx: 10))),
        reason: 'a from-scratch draft survives the real save -> reopen round-trip');
  });
}
