// M2 Phase-3.1 device proof: the INTEGRATED draft view on a real device.
//
// Drives the actual integrated view (the composed grids + the engine drawdown bitmap, real FFI
// render) and proves the load-bearing claim: tapping a tie-up cell in the integrated view edits it
// AND the live drawdown re-renders to a DIFFERENT cloth. Also exercises a second edit + undo.
//
//   flutter test integration_test/m2_editor_test.dart -d emulator-5554

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:ply/src/data/draft_repository.dart';
import 'package:ply/src/models/draft_doc.dart';
import 'package:ply/src/state/draft_editor_notifier.dart';
import 'package:ply/src/state/editor_providers.dart';
import 'package:ply/src/widgets/draft_layout.dart';
import 'package:ply/src/widgets/integrated_draft_view.dart';
import 'package:ply/src/rust/frb_generated.dart';

/// A plain-weave-ish treadled draft whose tie-up actually shapes the cloth, so toggling a tie
/// changes the rendered drawdown.
DraftDoc plainWeave() => DraftDoc(
      name: 'plain',
      shafts: 2,
      treadles: 2,
      shed: Shed.rising,
      unit: MeasureUnit.inches,
      threading: const [
        [1],
        [2],
        [1],
        [2],
      ],
      drive: DraftTreadled(
        tieup: const [
          [1],
          [2],
        ],
        treadling: const [
          [1],
          [2],
          [1],
          [2],
        ],
      ),
      palette: const [
        DraftColor(r: 255, g: 255, b: 255),
        DraftColor(r: 0, g: 0, b: 0),
      ],
      warpColors: const [0, 0, 0, 0],
      weftColors: const [1, 1, 1, 1],
      notes: '',
    );

Future<Uint8List> rawBytes(ui.Image image) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  return data!.buffer.asUint8List();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  testWidgets('tapping a tie-up cell in the INTEGRATED view re-renders the drawdown',
      (tester) async {
    const cell = 16;
    final repo = DraftRepository();
    final container = ProviderContainer(
      overrides: [
        repositoryProvider.overrideWithValue(repo),
        zoomCellProvider.overrideWith((ref) => cell),
      ],
    );
    addTearDown(container.dispose);
    container.read(draftEditorProvider.notifier).load(plainWeave());
    // Opt out of the M4 open-time auto-fit so the rendered pitch stays `cell`; the hand-computed
    // tie-up tap coordinates below assume that pitch. Without this, auto-fit resizes the grid to the
    // device viewport and the tap lands off the cell (the regression this device run surfaced).
    container.read(zoomUserSetProvider.notifier).state = true;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: IntegratedDraftView())),
      ),
    );

    // The plainWeave is ends 4, picks 4, shafts 2, treadles 2. Compute tie-up cell tap points in
    // content space from the SAME geometry the view uses, then offset by the view's origin.
    final layout = DraftLayout(
      ends: 4, picks: 4, shafts: 2, treadles: 2, hasTieup: true, cell: cell.toDouble());
    final origin = tester.getTopLeft(find.byType(IntegratedDraftView));
    Offset tieupTap(int treadle, int shaft) =>
        origin + layout.tieupRect.topLeft + layout.tieup.rectFor(treadle, shaft).center;

    // Read the FRESH frame for whatever draft is current (await the new render, not pumpAndSettle,
    // since skipLoadingOnReload keeps the stale frame on screen during a re-render).
    Future<Uint8List> freshFrame() async {
      await tester.pump();
      await container.read(previewProvider.future);
      return rawBytes(container.read(previewProvider).requireValue);
    }

    final before = await freshFrame();

    // Tap tie-up (treadle 1, shaft 1): it is filled, so the tap erases it (untie).
    await tester.tapAt(tieupTap(1, 1));
    final after = await freshFrame();
    expect((container.read(draftEditorProvider).draft.drive as DraftTreadled).tieup[0], isEmpty,
        reason: 'treadle 1 untied from shaft 1 via the integrated tie-up grid');
    expect(after, isNot(equals(before)),
        reason: 'the drawdown re-rendered to a different cloth');

    // A second edit also re-renders.
    await tester.tapAt(tieupTap(2, 2));
    final after2 = await freshFrame();
    expect(after2, isNot(equals(after)), reason: 'the second edit also updates the drawdown');

    // Undo restores the first edited cloth (deterministic engine -> same bytes).
    container.read(draftEditorProvider.notifier).undo();
    final undone = await freshFrame();
    expect(undone, equals(after), reason: 'undo brings back the previous drawdown');
  });

  testWidgets('drawdown orientation: end-0 LEFT, pick-0 BOTTOM (no mirror or flip)',
      (tester) async {
    final repo = DraftRepository();
    // A draft where EXACTLY ONE intersection is warp: end 0 (on shaft 1) raised only on pick 0;
    // every other pick raises shaft 3 which NO end threads, so all other cells are weft. Warp is
    // black, weft is white. The single black cell pins the axis origins the grids assume.
    final doc = DraftDoc(
      name: 'asym',
      shafts: 4,
      treadles: 0,
      shed: Shed.rising,
      unit: MeasureUnit.inches,
      threading: const [
        [1],
        [2],
        [2],
        [2],
      ],
      drive: DraftLiftplan(liftplan: const [
        [1], // pick 0 raises shaft 1 -> only end 0 shows warp
        [3],
        [3],
        [3],
      ]),
      palette: const [DraftColor(r: 0, g: 0, b: 0), DraftColor(r: 255, g: 255, b: 255)],
      warpColors: const [0, 0, 0, 0], // black warp
      weftColors: const [1, 1, 1, 1], // white weft
      notes: '',
    );

    const px = 12; // previewCellPx
    final img = await repo.renderDto(doc, cellPx: px); // 4 ends x 4 picks -> 48x48
    final bytes = await rawBytes(img);
    bool isWarp(int x, int y) {
      final i = (y * img.width + x) * 4;
      return bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 0; // black
    }

    // end 0 / pick 0 must be the BOTTOM-LEFT cell. A horizontal mirror moves it bottom-right; a
    // vertical flip moves it top-left; either would fail.
    expect(isWarp(px ~/ 2, img.height - px ~/ 2), isTrue,
        reason: 'end 0 / pick 0 warp is bottom-LEFT');
    expect(isWarp(img.width - px ~/ 2, px ~/ 2), isFalse, reason: 'top-right is weft');
    expect(isWarp(img.width - px ~/ 2, img.height - px ~/ 2), isFalse,
        reason: 'bottom-right is weft (not horizontally mirrored)');
    expect(isWarp(px ~/ 2, px ~/ 2), isFalse, reason: 'top-left is weft (not vertically flipped)');
    img.dispose();
  });

  testWidgets('resize round-trip: a shrink stays clean; a grow pads weft (real FFI)',
      (tester) async {
    final repo = DraftRepository();
    final doc = plainWeave(); // ends 4, picks 4, shafts 2, treadles 2

    // Shrink shafts 2 -> 1: references to shaft 2 must be pruned so validate() reports no Error.
    final shrunk = await repo.resizeDoc(doc,
        ends: doc.ends, picks: doc.picks, shafts: 1, treadles: doc.treadles);
    expect(shrunk.shafts, 1);
    final issues = await repo.validateDto(shrunk);
    expect(issues.where((i) => i.isError), isEmpty,
        reason: 'a shrink never leaves a dangling-reference Error to hand-fix');
    // The prune actually happened on EVERY axis (not just that validate is clean): no surviving
    // threading OR tie-up reference exceeds the new shaft count. A dangling tie-up shaft renders
    // white silently, so this pins the blind spot validate() now also guards.
    expect(shrunk.threading.expand((r) => r), everyElement(lessThanOrEqualTo(1)),
        reason: 'threading shaft refs pruned to 1..=1');
    final shrunkTie = (shrunk.drive as DraftTreadled).tieup;
    expect(shrunkTie.expand((r) => r), everyElement(lessThanOrEqualTo(1)),
        reason: 'tie-up shaft refs pruned to 1..=1, not left dangling');

    // Grow picks by 2: the weft colors are padded so weft.length stays coupled to picks.
    final grown = await repo.resizeDoc(doc,
        ends: doc.ends, picks: doc.picks + 2, shafts: doc.shafts, treadles: doc.treadles);
    expect(grown.picks, doc.picks + 2);
    expect(grown.weftColors.length, doc.picks + 2, reason: 'growing picks pads weft colors');

    // Grow a BLANK draft so the integrated grids become editable.
    final blank = await repo.resizeDoc(DraftDoc.blank(shafts: 4, treadles: 4),
        ends: 3, picks: 3, shafts: 4, treadles: 4);
    expect(blank.ends, 3);
    expect(blank.picks, 3);
    expect((await repo.validateDto(blank)).where((i) => i.isError), isEmpty);
  });
}
