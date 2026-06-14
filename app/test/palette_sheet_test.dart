import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/draft_repository.dart';
import 'package:ply/src/models/draft_doc.dart';
import 'package:ply/src/state/draft_editor_notifier.dart';
import 'package:ply/src/state/editor_providers.dart';
import 'package:ply/src/widgets/palette_sheet.dart';

// The palette sheet: add/edit are pure reducers; remove routes through repo.removeColorDoc (faked
// here, mirroring the engine remap) + commitEdit with the serialize + latest-wins guard. No native lib.

class FakePaletteRepo extends DraftRepository {
  int removeCount = 0;
  int? removedIdx;
  Completer<void>? gate;
  bool throwOnRemove = false;

  @override
  Future<DraftDoc> removeColorDoc(DraftDoc doc, int idx) async {
    removeCount++;
    removedIdx = idx;
    if (gate != null) await gate!.future;
    if (throwOnRemove) throw Exception('boom');
    // Mirror Draft::with_color_removed: drop palette[idx], remap warp/weft (==idx->0, >idx->-1).
    final palette = [...doc.palette]..removeAt(idx);
    int remap(int e) => e == idx ? 0 : (e > idx ? e - 1 : e);
    return doc.copyWith(
      palette: palette,
      warpColors: [for (final e in doc.warpColors) remap(e)],
      weftColors: [for (final e in doc.weftColors) remap(e)],
    );
  }
}

/// 3-color palette: index 1 (black) is referenced by warp+weft; index 2 (red) is UNREFERENCED.
DraftDoc fixture() => DraftDoc(
      name: 'p',
      shafts: 2,
      treadles: 2,
      shed: Shed.rising,
      unit: MeasureUnit.inches,
      threading: const [
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
        ],
      ),
      palette: const [
        DraftColor(r: 255, g: 255, b: 255),
        DraftColor(r: 0, g: 0, b: 0),
        DraftColor(r: 255, g: 0, b: 0),
      ],
      warpColors: const [0, 1],
      weftColors: const [1, 0],
      notes: '',
    );

Future<ProviderContainer> pumpSheet(WidgetTester tester, FakePaletteRepo repo,
    {DraftDoc? doc}) async {
  final c = ProviderContainer(overrides: [repositoryProvider.overrideWithValue(repo)]);
  addTearDown(c.dispose);
  c.read(draftEditorProvider.notifier).load(doc ?? fixture());
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: const MaterialApp(home: Scaffold(body: PaletteSheet())),
    ),
  );
  await tester.pump();
  return c;
}

void main() {
  testWidgets('renders one removable swatch per color plus an Add affordance', (tester) async {
    await pumpSheet(tester, FakePaletteRepo());
    expect(find.byIcon(Icons.close), findsNWidgets(3), reason: 'one remove badge per color');
    expect(find.text('Add color'), findsOneWidget);
  });

  testWidgets('Add -> Use color appends a color as one undo entry', (tester) async {
    final c = await pumpSheet(tester, FakePaletteRepo());
    await tester.tap(find.text('Add color'));
    await tester.pumpAndSettle(); // picker opens
    await tester.tap(find.text('Use color'));
    await tester.pumpAndSettle();
    final st = c.read(draftEditorProvider);
    expect(st.draft.palette.length, 4);
    expect(st.undo.length, 1);
  });

  testWidgets('Add -> Cancel adds nothing', (tester) async {
    final c = await pumpSheet(tester, FakePaletteRepo());
    await tester.tap(find.text('Add color'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(c.read(draftEditorProvider).draft.palette.length, 3);
    expect(c.read(draftEditorProvider).undo, isEmpty);
  });

  testWidgets('LONG-PRESS a swatch opens the picker; a changed color commits setPaletteColor',
      (tester) async {
    final c = await pumpSheet(tester, FakePaletteRepo());
    await tester.longPress(find.text('1')); // long-press edits (tap selects the brush)
    await tester.pumpAndSettle();
    expect(find.text('Use color'), findsOneWidget, reason: 'the RGB picker opened');
    // Change R, then apply.
    await tester.drag(find.byType(Slider).first, const Offset(300, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use color'));
    await tester.pumpAndSettle();
    final st = c.read(draftEditorProvider);
    expect(st.draft.palette[0].r, greaterThan(0), reason: 'swatch 0 R was raised');
    expect(st.undo.length, 1);
  });

  testWidgets('removing an UNREFERENCED color skips the dialog and commits', (tester) async {
    final repo = FakePaletteRepo();
    final c = await pumpSheet(tester, repo);
    await tester.tap(find.byIcon(Icons.close).at(2)); // red, unreferenced
    await tester.pumpAndSettle();
    expect(find.text('Remove this color?'), findsNothing, reason: 'no confirm for an unused color');
    expect(repo.removeCount, 1);
    expect(repo.removedIdx, 2);
    expect(c.read(draftEditorProvider).draft.palette.length, 2);
    expect(c.read(draftEditorProvider).undo.length, 1);
  });

  testWidgets('removing a REFERENCED color confirms first; Cancel does not remove', (tester) async {
    final repo = FakePaletteRepo();
    await pumpSheet(tester, repo);
    await tester.tap(find.byIcon(Icons.close).at(1)); // black, referenced by 2 threads
    await tester.pumpAndSettle();
    expect(find.text('Remove this color?'), findsOneWidget);
    expect(find.textContaining('2 threads use'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(repo.removeCount, 0, reason: 'cancel removes nothing');
  });

  testWidgets('removing a REFERENCED color, confirmed, calls the engine remove', (tester) async {
    final repo = FakePaletteRepo();
    final c = await pumpSheet(tester, repo);
    await tester.tap(find.byIcon(Icons.close).at(1));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    expect(repo.removeCount, 1);
    expect(repo.removedIdx, 1);
    // The referenced threads remapped to color 0; nothing dangles.
    final st = c.read(draftEditorProvider).draft;
    expect(st.palette.length, 2);
    expect(st.warpColors, const [0, 0]); // was [0,1] -> 1 removed -> 0
  });

  testWidgets('the remove badge is DISABLED on a one-color palette', (tester) async {
    final oneColor = fixture().copyWith(
      palette: const [DraftColor(r: 0, g: 0, b: 0)],
      warpColors: const [0, 0],
      weftColors: const [0, 0],
    );
    await pumpSheet(tester, FakePaletteRepo(), doc: oneColor);
    final badge = tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.close));
    expect(badge.onPressed, isNull, reason: 'a draft needs at least one color');
  });

  testWidgets('an engine remove failure shows an INLINE error and commits nothing', (tester) async {
    final repo = FakePaletteRepo()..throwOnRemove = true;
    final c = await pumpSheet(tester, repo);
    await tester.tap(find.byIcon(Icons.close).at(2)); // unreferenced -> straight to the FFI
    await tester.pumpAndSettle();
    // The message is rendered in the sheet (a root SnackBar would be occluded by the modal sheet).
    expect(find.textContaining('Could not remove the color'), findsOneWidget);
    expect(c.read(draftEditorProvider).draft.palette.length, 3, reason: 'nothing committed');
  });

  testWidgets('a swatch edit during an in-flight remove is gated (no stale-index edit)',
      (tester) async {
    final repo = FakePaletteRepo()..gate = Completer<void>();
    final c = await pumpSheet(tester, repo);
    await tester.tap(find.byIcon(Icons.close).at(2)); // remove parks; _removing == true
    await tester.pump();
    expect(repo.removeCount, 1);

    // Long-pressing a swatch to edit must be a no-op while a remove is renumbering the palette.
    await tester.longPress(find.text('1'));
    await tester.pumpAndSettle();
    expect(find.text('Use color'), findsNothing, reason: 'the picker did not open during a remove');

    repo.gate!.complete();
    await tester.pumpAndSettle();
    expect(c.read(draftEditorProvider).draft.palette.length, 2, reason: 'the remove still committed');
  });

  testWidgets('re-opening a swatch seeds the picker from its CURRENT (edited) color', (tester) async {
    final c = await pumpSheet(tester, FakePaletteRepo());
    // Long-press swatch 2 (index 1, black) to edit — raise R.
    await tester.longPress(find.text('2'));
    await tester.pumpAndSettle();
    expect(find.text('#000000'), findsOneWidget);
    await tester.drag(find.byType(Slider).first, const Offset(300, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use color'));
    await tester.pumpAndSettle();
    expect(c.read(draftEditorProvider).draft.palette[1].r, greaterThan(0));

    // Re-open the SAME swatch: the picker now seeds from the edited color, not the stale black.
    await tester.longPress(find.text('2'));
    await tester.pumpAndSettle();
    expect(find.text('#000000'), findsNothing, reason: 'seeded from the edited color');
  });

  testWidgets('editing a swatch updates its rendered fill live', (tester) async {
    await pumpSheet(tester, FakePaletteRepo());
    Color tileColor(int i) =>
        (tester.widget<Container>(find.byType(Container).at(i)).decoration as BoxDecoration).color!;
    final before = tileColor(1); // black
    await tester.longPress(find.text('2'));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(Slider).first, const Offset(300, 0)); // raise R
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use color'));
    await tester.pumpAndSettle();
    expect(tileColor(1), isNot(before), reason: 'the swatch fill re-rendered with the new color');
  });

  testWidgets('removing a color RENUMBERS a survivor above it (e>idx -> e-1)', (tester) async {
    final repo = FakePaletteRepo();
    // warp references index 0 and index 2; index 1 (black) is UNREFERENCED.
    final doc = fixture().copyWith(warpColors: const [0, 2], weftColors: const [0, 0]);
    final c = await pumpSheet(tester, repo, doc: doc);
    await tester.tap(find.byIcon(Icons.close).at(1)); // remove the unreferenced middle color
    await tester.pumpAndSettle();
    expect(repo.removeCount, 1);
    // The survivor at index 2 renumbers down to 1 (same color, no dangle).
    expect(c.read(draftEditorProvider).draft.warpColors, const [0, 1]);
  });

  testWidgets('tapping a swatch selects it as the active brush', (tester) async {
    final c = await pumpSheet(tester, FakePaletteRepo()); // 3-color palette
    await tester.tap(find.text('3')); // swatch index 2 (1-based label)
    await tester.pump();
    expect(c.read(activePaletteColorProvider), 2);
    await tester.tap(find.text('1'));
    await tester.pump();
    expect(c.read(activePaletteColorProvider), 0);
  });

  testWidgets('the sheet shows the brush hint', (tester) async {
    await pumpSheet(tester, FakePaletteRepo());
    expect(find.textContaining('Tap to choose the brush color'), findsOneWidget);
  });

  testWidgets('a large palette on a SHORT viewport scrolls instead of overflowing', (tester) async {
    // Regression: PaletteSheet lacked a SingleChildScrollView, so a tall palette (a WIF import can
    // carry dozens of colors) overflowed the Column — a RenderFlex assertion plus clipped,
    // unreachable swatches — most visibly in the wide DIALOG path, whose height is bounded by the
    // screen with no drag-to-expand. The body must scroll.
    tester.view.physicalSize = const Size(360, 300);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final big = fixture().copyWith(
      palette: [for (var i = 0; i < 24; i++) DraftColor(r: i * 10, g: 0, b: 0)],
    );
    await pumpSheet(tester, FakePaletteRepo(), doc: big);

    expect(tester.takeException(), isNull, reason: 'the palette scrolls; no RenderFlex overflow');
    expect(
      find.descendant(of: find.byType(PaletteSheet), matching: find.byType(Scrollable)),
      findsOneWidget,
      reason: 'the palette body is scrollable',
    );
    // SingleChildScrollView is not lazy, so every swatch is built (reachable by scrolling).
    expect(find.byIcon(Icons.close), findsNWidgets(24));
  });

  testWidgets('the selected swatch announces itself as the brush (a11y)', (tester) async {
    final handle = tester.ensureSemantics();
    final c = await pumpSheet(tester, FakePaletteRepo());
    c.read(activePaletteColorProvider.notifier).state = 1;
    await tester.pump();
    expect(find.bySemanticsLabel(RegExp('selected brush')), findsOneWidget);
    handle.dispose();
  });

  testWidgets('removing a color BELOW the active brush decrements the brush', (tester) async {
    final c = await pumpSheet(tester, FakePaletteRepo());
    c.read(activePaletteColorProvider.notifier).state = 2; // brush on red (idx 2)
    await tester.tap(find.byIcon(Icons.close).at(0)); // remove idx 0 (referenced -> confirm)
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    expect(c.read(activePaletteColorProvider), 1, reason: 'brush 2 > removed 0 -> 1');
  });

  testWidgets('removing the ACTIVE color resets the brush to 0', (tester) async {
    final c = await pumpSheet(tester, FakePaletteRepo());
    c.read(activePaletteColorProvider.notifier).state = 2; // brush on red (idx 2, unreferenced)
    await tester.tap(find.byIcon(Icons.close).at(2)); // unreferenced -> no dialog
    await tester.pumpAndSettle();
    expect(c.read(activePaletteColorProvider), 0, reason: 'brush == removed -> 0');
  });

  testWidgets('a color used by exactly one thread shows the SINGULAR confirm copy', (tester) async {
    // index 1 referenced by exactly one thread (warp[1]); weft uses only 0.
    final doc = fixture().copyWith(warpColors: const [0, 1], weftColors: const [0, 0]);
    await pumpSheet(tester, FakePaletteRepo(), doc: doc);
    await tester.tap(find.byIcon(Icons.close).at(1));
    await tester.pumpAndSettle();
    expect(find.textContaining('1 thread uses'), findsOneWidget);
    expect(find.textContaining('recolors it to'), findsOneWidget);
  });

  testWidgets('a second remove during an in-flight remove is dropped (serialize)', (tester) async {
    final repo = FakePaletteRepo()..gate = Completer<void>();
    final c = await pumpSheet(tester, repo);
    await tester.tap(find.byIcon(Icons.close).at(2)); // parks in removeColorDoc
    await tester.pump();
    expect(repo.removeCount, 1);
    await tester.tap(find.byIcon(Icons.close).at(0)); // dropped by _removing guard
    await tester.pump();
    expect(repo.removeCount, 1, reason: 'the in-flight remove serializes the second tap away');
    repo.gate!.complete();
    await tester.pumpAndSettle();
    expect(c.read(draftEditorProvider).draft.palette.length, 2);
  });

  testWidgets('an edit landing during the remove FFI hop is preserved (stale remove dropped)',
      (tester) async {
    final repo = FakePaletteRepo()..gate = Completer<void>();
    final c = await pumpSheet(tester, repo);
    await tester.tap(find.byIcon(Icons.close).at(2)); // parks in removeColorDoc(idx 2)
    await tester.pump();
    expect(repo.removeCount, 1);

    // A concurrent edit lands while the remove is in flight.
    c.read(draftEditorProvider.notifier).toggleTieupCell(1, 1);
    final edited = c.read(draftEditorProvider).draft;
    await tester.pump();

    repo.gate!.complete(); // remove resolves with a now-stale result
    await tester.pumpAndSettle();
    expect(c.read(draftEditorProvider).draft, equals(edited),
        reason: 'the concurrent edit survived; the stale remove was dropped');
    expect(c.read(draftEditorProvider).draft.palette.length, 3, reason: 'remove was not applied');
  });
}
