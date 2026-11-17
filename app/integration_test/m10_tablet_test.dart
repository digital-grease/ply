// M10-02 device proof: a tablet weaving band drafted, saved, reopened and simulated through the real
// engine on a device. Oracle band 1 of ADR 0018 section 11 is drafted from a new band with the
// editor's own edits (palette, every hole, S and Z cards, the Left and Right packs, the three
// segments), saved through the editor's Save button, reopened from the library folder, and checked
// against the ADR's hand-worked tables: the top face and back at chosen picks, the twist of every
// card after picks 4, 8 and 12, the reversals, and the colours of drawn cells in the band chart.
//
//   flutter test integration_test/m10_tablet_test.dart -d emulator-5554

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:ply/src/data/tablet_repository.dart';
import 'package:ply/src/models/native_format.dart';
import 'package:ply/src/models/readiness.dart';
import 'package:ply/src/models/tablet_band.dart';
import 'package:ply/src/print/tablet_print.dart';
import 'package:ply/src/rust/frb_generated.dart';
import 'package:ply/src/rust/tablet_dto.dart';
import 'package:ply/src/screens/tablet_editor_screen.dart';
import 'package:ply/src/state/tablet_editor_providers.dart';

const _k = 0, _w = 1, _r = 2, _g = 3;

/// Oracle band 1 drafted from a new band with the editor's edits (ADR 0018 section 11).
TabletDocumentDto draftBand1() {
  var d = blankTabletDocument(cards: 8);
  d = copyDoc(d, palette: const [
    TabletColorDto(r: 0x1a, g: 0x1a, b: 0x1a), // K
    TabletColorDto(r: 0xf2, g: 0xef, b: 0xe6), // W
    TabletColorDto(r: 0xb3, g: 0x26, b: 0x2e), // R
    TabletColorDto(r: 0xd4, g: 0xa0, b: 0x17), // G
  ]);
  // Holes A, B, C, D of each card (step 2 of the ADR's working).
  const holes = [
    [_k, _k, _k, _k],
    [_w, _k, _k, _r],
    [_r, _w, _k, _k],
    [_k, _r, _w, _g],
    [_k, _r, _w, _g],
    [_r, _w, _k, _k],
    [_w, _k, _k, _r],
    [_k, _k, _k, _k],
  ];
  for (var c = 0; c < 8; c++) {
    for (var h = 0; h < 4; h++) {
      d = setHole(d, c, TabletHoleKind.values[h], holes[c][h]);
    }
    d = setThreading(d, c, c < 4 ? TabletThreadingKind.s : TabletThreadingKind.z);
  }
  d = setAllStarts(d, kPlyHome);
  d = addPack(addPack(d, 'Left'), 'Right');
  for (var c = 0; c < 8; c++) {
    d = setCardPack(d, c, c < 4 ? 0 : 1);
  }
  d = copyDoc(d, turning: const [
    TabletSegmentDto(
        repeat: 4,
        picks: [TabletPickDto(turns: 'FFFFFFFF', releaseTwist: [], flip: [], unsupported: [])]),
    TabletSegmentDto(
        repeat: 4,
        picks: [TabletPickDto(turns: 'BBBBBBBB', releaseTwist: [], flip: [], unsupported: [])]),
    TabletSegmentDto(
        repeat: 4,
        picks: [TabletPickDto(turns: 'FFFFBBBB', releaseTwist: [], flip: [], unsupported: [])]),
  ]);
  return d;
}

Future<void> pumpFor(WidgetTester tester, Duration d) async {
  final end = DateTime.now().add(d);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  testWidgets('oracle band 1 drafts, saves, reopens, and weaves as ADR 0018 works it',
      (tester) async {
    final repo = TabletRepository();
    final container =
        ProviderContainer(overrides: [tabletRepositoryProvider.overrideWithValue(repo)]);
    addTearDown(container.dispose);
    final band = draftBand1();

    // Draft it in the editor and save with the Save button.
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: TabletEditorScreen(initialDoc: band)),
    ));
    await pumpFor(tester, const Duration(seconds: 1));
    // Two edits through the screen: card 8 to S and back to Z, so the editor's own controls are
    // exercised (and the band is unsaved until the Save button writes it).
    await tester.tap(find.byKey(const ValueKey('tablet-threading-7')));
    await tester.pump();
    expect(container.read(tabletDocProvider).cards[7].threading, TabletThreadingKind.s,
        reason: 'the first tap changed card 8 from Z to S');
    await tester.tap(find.byKey(const ValueKey('tablet-threading-7')));
    await tester.pump();
    expect(container.read(tabletDocProvider).cards[7].threading, TabletThreadingKind.z);
    await tester.tap(find.byTooltip('Save'));
    await pumpFor(tester, const Duration(milliseconds: 500));
    await tester.enterText(find.byType(TextField), 'Oracle band 1 on a device');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await pumpFor(tester, const Duration(seconds: 2));
    expect(container.read(tabletEditorProvider).isDirty, isFalse);

    // Reopen it from the library folder.
    final listed = await repo.listBands();
    final entry = listed.firstWhere((e) => e.meta.name == 'Oracle band 1 on a device');
    addTearDown(() => repo.deleteBand(entry.id));
    expect(plytabSchemaVersion(File(entry.bandPath).readAsStringSync()), 1);
    final doc = await repo.readBand(entry.id);
    expect(doc.name, 'Oracle band 1 on a device');
    expect(doc.cards.length, 8);
    expect(doc.packs.map((p) => p.name), ['Left', 'Right']);
    expect(expandedPicks(doc), 12);
    // Saving the reopened band writes the same bytes (the writer is deterministic).
    expect(await repo.write(doc), File(entry.bandPath).readAsStringSync());

    // The engine's report: two reversal notes and nothing else (ADR 0018 section 11).
    final report = await repo.validate(doc);
    expect(report.errors + report.warnings + report.unsupported, 0);
    expect(report.diagnostics.map((d) => (d.code, d.location.pick)),
        [('tablet.reversal', 5), ('tablet.reversal', 9)]);
    expect(report.reviewPending, isTrue);

    // Step 4 of the ADR's working: the top and back holes and colours at picks 1, 5, 9 and 12.
    final w = await repo.window(doc, 1, 12);
    TabletCardPickDto cell(int pick, int card) => w.cells[(pick - 1) * 8 + card];
    String top(int pick) => [
          for (var c = 0; c < 8; c++) 'KWRG'[cell(pick, c).top.color!],
        ].join();
    String back(int pick) => [
          for (var c = 0; c < 8; c++) 'KWRG'[cell(pick, c).back.color!],
        ].join();
    expect(top(1), 'KWRKKRWK');
    expect(back(1), 'KKKWWKKK');
    expect(top(5), 'KRKGGKRK');
    expect(top(9), 'KWRKGKRK');
    expect(back(9), 'KKKWRWKK');
    expect(top(12), 'KRKGKRWK');
    // Step 3: twist +4 on S cards and -4 on Z cards after pick 4, 0 after pick 8, +4 everywhere
    // after pick 12; reversals at pick 5 (all cards) and pick 9 (cards 1 to 4).
    for (var c = 0; c < 8; c++) {
      expect(cell(4, c).twist, c < 4 ? 4 : -4, reason: 'card ${c + 1} after pick 4');
      expect(cell(8, c).twist, 0, reason: 'card ${c + 1} after pick 8');
      expect(cell(12, c).twist, 4, reason: 'card ${c + 1} after pick 12');
      expect(cell(5, c).reversal, isTrue);
      expect(cell(9, c).reversal, c < 4);
      expect(cell(12, c).position?.nearTop, TabletHoleKind.a, reason: 'home again');
    }
    final state = await repo.stateAfter(doc, 12);
    expect(state.cards.every((s) => s.twist == 4 && s.woven == 4), isTrue);

    // The drawn top face: the cell of card 4 at pick 4 is gold (G), card 2 at pick 1 white (W),
    // read off both diagonals of the cell (pick 1 at the bottom).
    final raster = await repo.renderFace(doc, 1, 12, face: TabletFaceKind.top, cellPx: 10);
    expect((raster.width, raster.height, raster.cellPx), (80, 120, 10));
    List<int> px(int card, int pick) {
      final x = card * 10 + 2, y = (12 - pick) * 10 + 6;
      final i = (y * raster.width + x) * 4;
      return raster.rgba.sublist(i, i + 3);
    }

    expect(px(3, 4), [0xd4, 0xa0, 0x17]);
    expect(px(1, 1), [0xf2, 0xef, 0xe6]);
    final image = await repo.decode(raster);
    expect(image.width, 80);
    image.dispose();
    final thumb = File('${File(entry.bandPath).parent.path}/${entry.id}.png');
    expect(thumb.existsSync(), isTrue, reason: 'the save wrote a thumbnail');
    final bytes = await thumb.readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    expect(frame.image.width, 8 * TabletRepository.thumbnailCellPx);
    frame.image.dispose();

    // The print source: every chart drawn, and every key symbol cut from the engine's own key
    // rasters at the right cell (F on a white fill, B on grey, as render.rs draws them).
    final source = await gatherTabletPrint(repo, name: doc.name, doc: doc);
    expect(source.turning, isNotNull);
    expect(source.top, isNotNull);
    expect(source.back, isNotNull);
    expect(source.chartedPicks, 12);
    expect(source.keys.keys.toSet(), TabletKeyCell.values.toSet());
    List<int> corner(TabletKeyCell k) => source.keys[k]!.rgba.sublist(4, 7); // pixel (1, 0)
    expect(corner(TabletKeyCell.forward), [255, 255, 255]);
    expect(corner(TabletKeyCell.backward), [200, 208, 214]);
    expect(corner(TabletKeyCell.idle), [236, 236, 236]);
    // Only the two reversal notes: ready to print without a question.
    expect(tabletReadiness(source.report).verdict, ReadinessVerdict.ready);

    // Open it in the editor and step to pick 9: card 5 shows D (gold) on the top face, twist +1.
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: TabletEditorScreen(openId: entry.id)),
    ));
    await pumpFor(tester, const Duration(seconds: 1));
    await tester.tap(find.text('Band'));
    await pumpFor(tester, const Duration(seconds: 1));
    container.read(tabletPickProvider.notifier).state = 9;
    await pumpFor(tester, const Duration(seconds: 1));
    expect(find.text('Pick 9 of 12'), findsOneWidget);
    expect(
      find.bySemanticsLabel(RegExp(r'^Card 5 at pick 9: B, backward\. .*Twist \+1 .*Top: D, '
          r'colour 4 \(#d4a017\)\.')),
      findsOneWidget,
    );
  });
}
