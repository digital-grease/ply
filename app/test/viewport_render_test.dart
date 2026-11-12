import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/draft_repository.dart';
import 'package:ply/src/models/draft_doc.dart';
import 'package:ply/src/rust/dto.dart';
import 'package:ply/src/state/draft_editor_notifier.dart';
import 'package:ply/src/state/editor_providers.dart';
import 'package:ply/src/widgets/draft_grids.dart';
import 'package:ply/src/widgets/draft_layout.dart';
import 'package:ply/src/widgets/integrated_draft_view.dart';

// M7-01 viewport rendering, host side: a draft over kWholeRenderMaxCells intersections renders its
// drawdown a viewport at a time (the engine's region render, faked here with a bitmap whose every
// cell has its own color), the request follows pan and zoom, the tile lands pixel-exactly under the
// threading and beside the treadling, the grids paint only what is in view, and a draft past the
// engine's 4 million intersection whole-render budget shows cloth instead of "too large".

/// A unique color per drawdown cell (0-based end and pick indices, both below 4096).
Color regionCellColor(int end, int pick) =>
    Color.fromARGB(255, end % 256, pick % 256, ((end ~/ 256) % 16) * 16 + (pick ~/ 256) % 16);

/// The bitmap the engine returns for [region] at [px]: highest end at the LEFT, first pick at the
/// TOP, every cell [px] square in [regionCellColor]. Must run in real async (image decode).
Future<ui.Image> encodeRegion(DrawdownRegion region, int px) {
  final w = region.endCount * px;
  final h = region.pickCount * px;
  final rgba = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    final pick = region.pickStart + y ~/ px;
    for (var x = 0; x < w; x++) {
      final c = regionCellColor(region.endEnd - 1 - x ~/ px, pick);
      final i = (y * w + x) * 4;
      rgba[i] = (c.r * 255).round();
      rgba[i + 1] = (c.g * 255).round();
      rgba[i + 2] = (c.b * 255).round();
      rgba[i + 3] = 255;
    }
  }
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(rgba, w, h, ui.PixelFormat.rgba8888, completer.complete);
  return completer.future;
}

/// One region render the view asked for, answered by [RegionRepo.fulfill].
class RegionCall {
  RegionCall(this.doc, this.region, this.cellPx, this.gridlines, this.threadTexture);

  final DraftDoc doc;
  final DrawdownRegion region;
  final int cellPx;
  final bool gridlines;
  final bool threadTexture;
  final Completer<ui.Image> result = Completer<ui.Image>();
}

/// Records whole and region renders. A whole render of a draft past the engine's 4M budget fails as
/// the engine would; region renders wait for [fulfill] (or fail with [regionError]).
class RegionRepo extends DraftRepository {
  final List<DraftDoc> wholeCalls = [];
  final List<RegionCall> regionCalls = [];
  final List<RegionCall> _pending = [];
  Object? regionError;

  @override
  Future<ui.Image> renderDto(
    DraftDoc doc, {
    required int cellPx,
    bool gridlines = false,
    int floatThreshold = 0,
    bool threadTexture = false,
  }) {
    wholeCalls.add(doc);
    if (doc.ends * doc.picks > 4000000) {
      return Future<ui.Image>.error(const RenderFailure(
          kind: RenderFailureKind.tooLarge, message: 'over the 4000000 intersection budget'));
    }
    return Completer<ui.Image>().future; // the small-draft path is covered elsewhere
  }

  @override
  Future<ui.Image> renderRegion(
    DraftDoc doc,
    DrawdownRegion region, {
    required int cellPx,
    bool gridlines = false,
    int floatThreshold = 0,
    bool threadTexture = false,
  }) {
    final call = RegionCall(doc, region, cellPx, gridlines, threadTexture);
    regionCalls.add(call);
    if (regionError != null) return Future<ui.Image>.error(regionError!);
    _pending.add(call);
    return call.result.future;
  }

  /// Decode and deliver every pending region bitmap (call inside `tester.runAsync`).
  Future<void> fulfill() async {
    while (_pending.isNotEmpty) {
      final call = _pending.removeAt(0);
      call.result.complete(await encodeRegion(call.region, call.cellPx));
    }
  }
}

/// A treadled draft of [ends] x [picks]: a straight draw over 4 shafts, treadled straight. Cheap to
/// build at any size (linear in ends + picks).
DraftDoc bigDraft(int ends, int picks) => DraftDoc(
      name: 'big',
      shafts: 4,
      treadles: 4,
      shed: Shed.rising,
      unit: MeasureUnit.inches,
      threading: [
        for (var e = 0; e < ends; e++) [e % 4 + 1]
      ],
      drive: DraftTreadled(
        tieup: const [
          [1, 2],
          [2, 3],
          [3, 4],
          [4, 1],
        ],
        treadling: [
          for (var p = 0; p < picks; p++) [p % 4 + 1]
        ],
      ),
      palette: const [DraftColor(r: 255, g: 255, b: 255), DraftColor(r: 0, g: 0, b: 0)],
      warpColors: List.filled(ends, 0),
      weftColors: List.filled(picks, 1),
      notes: '',
    );

DraftDoc smallDraft() => bigDraft(4, 4);

const Key kBoundary = Key('canvas');

/// Pump the integrated view at a fixed logical [size] and pixel ratio [dpr], at pitch [cell].
Future<ProviderContainer> pumpEditor(
  WidgetTester tester,
  RegionRepo repo,
  DraftDoc doc, {
  int cell = 8,
  double dpr = 1.0,
  Size size = const Size(400, 400),
  EditorTool tool = EditorTool.hand,
}) async {
  tester.view.physicalSize = Size(size.width * dpr, size.height * dpr);
  tester.view.devicePixelRatio = dpr;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final c = ProviderContainer(overrides: [repositoryProvider.overrideWithValue(repo)]);
  addTearDown(c.dispose);
  c.read(zoomCellProvider.notifier).state = cell;
  c.read(zoomUserSetProvider.notifier).state = true; // keep this exact pitch
  c.read(editorToolProvider.notifier).state = tool;
  c.read(draftEditorProvider.notifier).load(doc);
  await tester.pumpWidget(UncontrolledProviderScope(
    container: c,
    child: const MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: RepaintBoundary(key: kBoundary, child: IntegratedDraftView()),
        ),
      ),
    ),
  ));
  await tester.pump(); // the post-frame viewport settle writes the request
  return c;
}

/// Let the view settle its request, the debounce elapse, deliver the region bitmaps, and show them.
/// (Riverpod refreshes a provider on the next frame, and a tile shows one frame after it lands.)
Future<void> settleRegion(WidgetTester tester, RegionRepo repo) async {
  await tester.pump();
  await tester.pump();
  await tester.pump(kRegionDebounce + const Duration(milliseconds: 5));
  await tester.runAsync(repo.fulfill);
  await tester.pump();
  await tester.pump();
}

ScrollPosition scrollOf(WidgetTester tester, AxisDirection dir) => tester
    .state<ScrollableState>(
        find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == dir))
    .position;

/// The canvas rect in view, from the live scroll positions.
Rect visibleCanvas(WidgetTester tester) {
  final h = scrollOf(tester, AxisDirection.right);
  final v = scrollOf(tester, AxisDirection.down);
  return Rect.fromLTWH(h.pixels, v.pixels, h.viewportDimension, v.viewportDimension);
}

DraftLayout layoutOf(ProviderContainer c) {
  final d = c.read(draftEditorProvider).draft;
  return DraftLayout(
    ends: d.ends,
    picks: d.picks,
    shafts: d.shafts,
    treadles: d.treadles,
    hasTieup: d.drive is DraftTreadled,
    cell: c.read(zoomCellProvider).toDouble(),
  );
}

/// A canvas that only counts the draw calls a painter makes.
class CountingCanvas implements Canvas {
  int rects = 0;
  int lines = 0;

  @override
  void drawRect(Rect rect, Paint paint) => rects++;

  @override
  void drawLine(Offset p1, Offset p2, Paint paint) => lines++;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  group('pure geometry and requests', () {
    test('the threshold: 250,000 intersections render whole, one more renders a viewport', () {
      expect(kWholeRenderMaxCells, 250000);
      expect(usesRegionRender(500, 500), isFalse);
      expect(usesRegionRender(501, 500), isTrue);
      expect(usesRegionRender(100000, 100000), isTrue);
      expect(usesRegionRender(4, 4), isFalse);
    });

    test('DrawdownRegion covers, grows within the draft, and clips', () {
      const r = DrawdownRegion(endStart: 10, endCount: 5, pickStart: 20, pickCount: 4);
      expect((r.endEnd, r.pickEnd, r.cells), (15, 24, 20));
      expect(r.covers(const DrawdownRegion(endStart: 11, endCount: 4, pickStart: 20, pickCount: 1)),
          isTrue);
      expect(r.covers(const DrawdownRegion(endStart: 9, endCount: 2, pickStart: 20, pickCount: 1)),
          isFalse);
      expect(r.grown(ends: 3, picks: 30, totalEnds: 16, totalPicks: 100),
          const DrawdownRegion.span(endStart: 7, endEnd: 16, pickStart: 0, pickEnd: 54));
      expect(r.clippedTo(12, 22),
          const DrawdownRegion.span(endStart: 10, endEnd: 12, pickStart: 20, pickEnd: 22));
      expect(r.clippedTo(8, 100), isNull, reason: 'the draft shrank past the region');
    });

    test('drawdownCellsIn and drawdownCellsRect are inverses (end 1 at the right, pick 1 on top)',
        () {
      final layout =
          DraftLayout(ends: 100, picks: 80, shafts: 4, treadles: 4, hasTieup: true, cell: 10);
      final dd = layout.drawdownRect;
      // The whole drawdown.
      expect(layout.drawdownCellsIn(dd),
          const DrawdownRegion(endStart: 0, endCount: 100, pickStart: 0, pickCount: 80));
      // A rect touching only the drawdown's top-right cell: end index 0, pick 0.
      final corner = Rect.fromLTWH(dd.right - 3, dd.top, 3, 3);
      expect(layout.drawdownCellsIn(corner),
          const DrawdownRegion(endStart: 0, endCount: 1, pickStart: 0, pickCount: 1));
      // A partial-cell window counts every cell it touches.
      final mid = Rect.fromLTWH(dd.left + 25, dd.top + 41, 30, 12);
      final cells = layout.drawdownCellsIn(mid)!;
      expect(cells, const DrawdownRegion.span(endStart: 94, endEnd: 98, pickStart: 4, pickEnd: 6));
      final back = layout.drawdownCellsRect(cells).shift(dd.topLeft);
      expect(
          back.contains(mid.topLeft) && back.contains(mid.bottomRight - const Offset(1, 1)), isTrue,
          reason: 'the cells cover the window');
      expect(back, Rect.fromLTWH(dd.left + 20, dd.top + 40, 40, 20));
      // Outside the drawdown (the threading above it): nothing.
      expect(layout.drawdownCellsIn(layout.threadingRect), isNull);
    });

    test('regionRequestFor keeps a covering request, grows a new one, and caps the margin', () {
      const seen = DrawdownRegion(endStart: 100, endCount: 40, pickStart: 200, pickCount: 60);
      final first = regionRequestFor(visible: seen, ends: 1000, picks: 1000, cellPx: 12);
      expect(first.region,
          const DrawdownRegion.span(endStart: 90, endEnd: 150, pickStart: 185, pickEnd: 275),
          reason: 'a quarter of the visible span on each side');
      expect(first.cellPx, 12);
      // A small pan inside the margin keeps the request (no new render).
      const panned = DrawdownRegion(endStart: 105, endCount: 40, pickStart: 210, pickCount: 60);
      expect(
          identical(
              regionRequestFor(
                  visible: panned, ends: 1000, picks: 1000, cellPx: 12, previous: first),
              first),
          isTrue);
      // Leaving the margin, or changing the pitch, asks again.
      const far = DrawdownRegion(endStart: 140, endCount: 40, pickStart: 210, pickCount: 60);
      expect(regionRequestFor(visible: far, ends: 1000, picks: 1000, cellPx: 12, previous: first),
          isNot(first));
      expect(
          regionRequestFor(visible: panned, ends: 1000, picks: 1000, cellPx: 6, previous: first)
              .cellPx,
          6);
      // Clipped at the draft's edges; at least 2 cells of margin however few are in view.
      const edge = DrawdownRegion(endStart: 0, endCount: 10, pickStart: 995, pickCount: 5);
      expect(regionRequestFor(visible: edge, ends: 1000, picks: 1000, cellPx: 3).region,
          const DrawdownRegion.span(endStart: 0, endEnd: 12, pickStart: 993, pickEnd: 1000));
      // Past the overscan budget, just the visible cells.
      expect(
          regionRequestFor(visible: seen, ends: 1000, picks: 1000, cellPx: 3, maxCells: 3000)
              .region,
          seen);
    });

    test('regionCellPx is the physical pitch, clamped', () {
      expect(regionCellPx(8, 1), 8);
      expect(regionCellPx(8, 2.625), 21);
      expect(regionCellPx(1, 0.5), 1);
      expect(regionCellPx(64, 5), kMaxRegionCellPx);
    });

    test('gridPaintWindow covers the view plus a tile, snapped to tiles', () {
      const visible = Rect.fromLTWH(300, 1000, 400, 300);
      final w = gridPaintWindow(visible);
      expect(w, const Rect.fromLTRB(0, 512, 1024, 1792));
      expect(w.contains(visible.topLeft) && w.contains(visible.bottomRight), isTrue);
      // A small scroll inside the same tiles keeps the window (no repaint).
      expect(gridPaintWindow(visible.shift(const Offset(20, 10))), w);
    });

    test('a windowed grid painter draws only the cells and lines in view', () {
      // 100,000 picks of treadling at 6 px: 600,000 px tall. The window shows about 50 rows.
      const geom =
          RegionGeom(cols: 4, rows: 100000, cell: 6, colBase: 1, rowBase: 0, bottomOrigin: false);
      final cells = [for (var p = 0; p < 100000; p++) (p % 4 + 1, p)];
      final visible = ValueNotifier<Rect>(const Rect.fromLTWH(-10, 300000, 400, 300));
      addTearDown(visible.dispose);
      CellGridPainter painter(GridWindow? window) => CellGridPainter(
          cells: cells,
          geom: geom,
          fill: const Color(0xFF000000),
          line: const Color(0xFF888888),
          background: const Color(0xFFFFFFFF),
          window: window);

      final windowed = CountingCanvas();
      painter(GridWindow(visible, const Offset(0, 0))).paint(windowed, geom.size);
      expect(windowed.rects, 1 + 50, reason: 'background + the 50 filled cells in view');
      expect(windowed.lines, 5 + 51, reason: '5 column lines + 51 row lines in view');

      final everything = CountingCanvas();
      painter(null).paint(everything, geom.size);
      expect(everything.rects, 1 + 100000, reason: 'no window: every cell, as before');

      // Out of view entirely: nothing at all.
      visible.value = const Rect.fromLTWH(1000, 0, 10, 10);
      final none = CountingCanvas();
      painter(GridWindow(visible, Offset.zero)).paint(none, geom.size);
      expect((none.rects, none.lines), (0, 0));
    });

    test('the region failure messages', () {
      expect(
          regionPreviewErrorMessage(
              const RenderFailure(kind: RenderFailureKind.tooLarge, message: 'x')),
          'Too much of this draft is in view to draw at once. Zoom in to see the cloth.');
      expect(
          regionPreviewErrorMessage(
              const RenderFailure(kind: RenderFailureKind.invalidRegion, message: 'x')),
          'This part of the draft could not be drawn.');
      expect(
          regionPreviewErrorMessage(
              const RenderFailure(kind: RenderFailureKind.outOfMemory, message: 'x')),
          'There was not enough memory to draw this preview.');
    });
  });

  group('the editor picks its drawdown path', () {
    testWidgets('a small draft renders whole, never by region', (tester) async {
      final repo = RegionRepo();
      await pumpEditor(tester, repo, smallDraft(), cell: 16);
      await tester.pump();
      await tester.pump(kRegionDebounce * 2);
      expect(repo.wholeCalls, isNotEmpty);
      expect(repo.regionCalls, isEmpty);
    });

    testWidgets('a draft over the threshold renders only the cells in view, never whole',
        (tester) async {
      final repo = RegionRepo();
      final c = await pumpEditor(tester, repo, bigDraft(600, 600));
      expect(repo.regionCalls, isEmpty, reason: 'debounced until the view settles');
      await settleRegion(tester, repo);
      expect(repo.wholeCalls, isEmpty);
      expect(repo.regionCalls, hasLength(1));
      final call = repo.regionCalls.single;
      final seen = layoutOf(c).drawdownCellsIn(visibleCanvas(tester))!;
      expect(call.region.covers(seen), isTrue, reason: '${call.region} covers $seen');
      expect(call.region.cells, lessThan(30000), reason: 'a viewport, not 360,000 intersections');
      expect(call.cellPx, 8, reason: 'the on-screen pitch in physical pixels at 1x');
      expect(call.doc.warpThickness, isEmpty);
      expect(find.byType(RawImage), findsOneWidget);
    });

    testWidgets('the request follows a pan and a zoom', (tester) async {
      final repo = RegionRepo();
      final c = await pumpEditor(tester, repo, bigDraft(600, 600));
      await settleRegion(tester, repo);

      // Pan far right and down: the next render covers the newly visible cells.
      scrollOf(tester, AxisDirection.right).jumpTo(2400);
      scrollOf(tester, AxisDirection.down).jumpTo(3000);
      await tester.pump();
      await settleRegion(tester, repo);
      expect(repo.regionCalls, hasLength(2));
      var seen = layoutOf(c).drawdownCellsIn(visibleCanvas(tester))!;
      expect(repo.regionCalls.last.region.covers(seen), isTrue);
      expect(seen.endStart, lessThan(400), reason: 'panned toward the high ends (on the left)');

      // A pan that stays inside the rendered margin renders nothing new.
      scrollOf(tester, AxisDirection.down).jumpTo(3008);
      await tester.pump();
      await settleRegion(tester, repo);
      expect(repo.regionCalls, hasLength(2));

      // Zoom in: a new pitch and the cells now in view.
      c.read(zoomCellProvider.notifier).state = 16;
      await tester.pump();
      await tester.pump();
      await settleRegion(tester, repo);
      expect(repo.regionCalls.last.cellPx, 16);
      seen = layoutOf(c).drawdownCellsIn(visibleCanvas(tester))!;
      expect(repo.regionCalls.last.region.covers(seen), isTrue);
    });

    testWidgets('fast panning renders once, where the view settles', (tester) async {
      final repo = RegionRepo();
      await pumpEditor(tester, repo, bigDraft(600, 600));
      await settleRegion(tester, repo);
      final before = repo.regionCalls.length;
      for (var i = 1; i <= 10; i++) {
        scrollOf(tester, AxisDirection.down).jumpTo(i * 300.0);
        await tester.pump(const Duration(milliseconds: 16));
      }
      await settleRegion(tester, repo);
      expect(repo.regionCalls.length, before + 1);
    });

    testWidgets('an edit in a still view re-renders at once, with the same region', (tester) async {
      final repo = RegionRepo();
      final c = await pumpEditor(tester, repo, bigDraft(600, 600));
      await settleRegion(tester, repo);
      final region = repo.regionCalls.last.region;
      c.read(draftEditorProvider.notifier).toggleTieupCell(1, 3);
      await tester.pump();
      expect(repo.regionCalls, hasLength(2), reason: 'no debounce for an edit');
      expect(repo.regionCalls.last.region, region);
      await tester.runAsync(repo.fulfill);
      await tester.pump();
    });

    testWidgets('fine overlays are left out below 4 px, kept at or above it', (tester) async {
      final repo = RegionRepo();
      final c = await pumpEditor(tester, repo, bigDraft(600, 600), cell: 3);
      c.read(showGridlinesProvider.notifier).state = true;
      await settleRegion(tester, repo);
      expect(repo.regionCalls.last.cellPx, 3);
      expect(repo.regionCalls.last.gridlines, isFalse);
      expect(repo.regionCalls.last.threadTexture, isFalse);
      c.read(zoomCellProvider.notifier).state = 4;
      await tester.pump();
      await tester.pump();
      await settleRegion(tester, repo);
      expect(repo.regionCalls.last.cellPx, 4);
      expect(repo.regionCalls.last.gridlines, isTrue);
      expect(repo.regionCalls.last.threadTexture, isTrue);
    });

    testWidgets('the grids of a large draft paint only the window in view', (tester) async {
      final repo = RegionRepo();
      await pumpEditor(tester, repo, bigDraft(600, 600));
      await settleRegion(tester, repo);
      final right = tester.widget<CustomPaint>(
          find.descendant(of: find.byType(RightGrid), matching: find.byType(CustomPaint)));
      final painter = right.painter! as CellGridPainter;
      expect(painter.window, isNotNull);
      final area = gridPaintArea(painter.geom, painter.window);
      expect(area.height, lessThanOrEqualTo(400 + 3 * 256),
          reason: 'about the view plus a tile each side, not 600 picks x 8 px');
      expect(painter.geom.size.height, 4800);
    });
  });

  testWidgets('a zoom step reuses the grids\' cell lists; an edit rebuilds only what it touched',
      (tester) async {
    final repo = RegionRepo();
    final c = await pumpEditor(tester, repo, bigDraft(600, 600));
    await settleRegion(tester, repo);
    T painterOf<T>(Type grid) => tester
        .widget<CustomPaint>(
            find.descendant(of: find.byType(grid), matching: find.byType(CustomPaint)))
        .painter! as T;
    final right = painterOf<CellGridPainter>(RightGrid).cells;
    final threading = painterOf<CellGridPainter>(ThreadingGrid).cells;
    final weft = painterOf<ColorBandPainter>(WeftColorBand).colors;
    expect(painterOf<ColorBandPainter>(WeftMarkerBand).colors, same(weft),
        reason: 'the band and the markers share one color list');

    c.read(zoomCellProvider.notifier).state = 9;
    await tester.pump();
    expect(painterOf<CellGridPainter>(RightGrid).cells, same(right));
    expect(painterOf<CellGridPainter>(ThreadingGrid).cells, same(threading));
    expect(painterOf<ColorBandPainter>(WeftColorBand).colors, same(weft));

    // Press treadle 2 on pick 0 (it pressed treadle 1): only the treadling's cells change.
    c.read(draftEditorProvider.notifier).beginStroke(const DraftHit(DraftRegion.right, 2, 0));
    c.read(draftEditorProvider.notifier).endStroke();
    await tester.pump();
    final edited = painterOf<CellGridPainter>(RightGrid).cells;
    expect(edited, isNot(same(right)));
    expect(edited, contains((2, 0)));
    expect(right, isNot(contains((2, 0))));
    expect(painterOf<CellGridPainter>(ThreadingGrid).cells, same(threading));
    await settleRegion(tester, repo);
  });

  // Pixel-level proof (the approach of integrated_draft_view_test's structural alignment): every
  // tile cell (end, pick) shows exactly under threading end `end` and beside treadling pick `pick`,
  // after a pan, at several pitches and pixel ratios.
  group('a viewport tile stays aligned with the grids', () {
    for (final cell in [8, 13]) {
      for (final dpr in [1.0, 2.0, 3.0]) {
        testWidgets('pitch $cell at ${dpr}x', (tester) async {
          final repo = RegionRepo();
          await pumpEditor(tester, repo, bigDraft(600, 600), cell: cell, dpr: dpr);
          scrollOf(tester, AxisDirection.right).jumpTo(cell * 250.0);
          scrollOf(tester, AxisDirection.down).jumpTo(cell * 300.0);
          await tester.pump();
          await settleRegion(tester, repo);
          expect(repo.regionCalls.last.cellPx, (cell * dpr).round());

          final origin = tester.getTopLeft(find.byKey(kBoundary));
          final viewSize = tester.getSize(find.byKey(kBoundary));
          final threadingGeom = tester.widget<ThreadingGrid>(find.byType(ThreadingGrid)).geom;
          final rightGeom = tester.widget<RightGrid>(find.byType(RightGrid)).geom;
          final threadingAt = tester.getTopLeft(find.byType(ThreadingGrid));
          final rightAt = tester.getTopLeft(find.byType(RightGrid));

          final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(kBoundary));
          final shot = await tester.runAsync(() async {
            final image = await boundary.toImage(pixelRatio: dpr);
            final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
            final out = (image.width, data!.buffer.asUint8List());
            image.dispose();
            return out;
          });
          final (shotWidth, bytes) = shot!;
          Color sample(Offset global) {
            final local = (global - origin) * dpr;
            final i = (local.dy.floor() * shotWidth + local.dx.floor()) * 4;
            return Color.fromARGB(bytes[i + 3], bytes[i], bytes[i + 1], bytes[i + 2]);
          }

          // Cells whose centers fall inside the view (and inside the drawdown).
          final ddTop = tester.getTopLeft(find.byType(RawImage)).dy;
          var checked = 0;
          for (var end = 1; end <= 600; end++) {
            final x = threadingAt.dx + threadingGeom.rectFor(end, 1).center.dx;
            if (x < origin.dx + 1 || x > origin.dx + viewSize.width - 1) continue;
            for (var pick = 0; pick < 600; pick++) {
              final y = rightAt.dy + rightGeom.rectFor(1, pick).center.dy;
              if (y < origin.dy + 1 || y > origin.dy + viewSize.height - 1 || y < ddTop) continue;
              expect(sample(Offset(x, y)), regionCellColor(end - 1, pick),
                  reason: 'drawdown under threading end $end, beside treadling pick $pick');
              checked++;
            }
          }
          expect(checked, greaterThan(500), reason: 'a screenful of cells was checked');
        });
      }
    }
  });

  group('drafts past the engine whole-render budget', () {
    testWidgets('a draft over 4 million intersections shows its cells, not "too large"',
        (tester) async {
      final repo = RegionRepo();
      final c = await pumpEditor(tester, repo, bigDraft(2001, 2000));
      expect(2001 * 2000, greaterThan(4000000));
      scrollOf(tester, AxisDirection.right).jumpTo(8 * 1000.0);
      scrollOf(tester, AxisDirection.down).jumpTo(8 * 1500.0);
      await tester.pump();
      await settleRegion(tester, repo);
      expect(find.text('This draft is too large to preview on this device.'), findsNothing);
      expect(repo.wholeCalls, isEmpty);
      expect(find.byType(RawImage), findsOneWidget);
      final seen = layoutOf(c).drawdownCellsIn(visibleCanvas(tester))!;
      expect(repo.regionCalls.last.region.covers(seen), isTrue);

      // The cell in the middle of the view is that cell's own color.
      final threadingGeom = tester.widget<ThreadingGrid>(find.byType(ThreadingGrid)).geom;
      final rightGeom = tester.widget<RightGrid>(find.byType(RightGrid)).geom;
      final endIndex = seen.endStart + seen.endCount ~/ 2;
      final pick = seen.pickStart + seen.pickCount ~/ 2;
      final x = tester.getTopLeft(find.byType(ThreadingGrid)).dx +
          threadingGeom.rectFor(endIndex + 1, 1).center.dx;
      final y = tester.getTopLeft(find.byType(RightGrid)).dy + rightGeom.rectFor(1, pick).center.dy;
      final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(kBoundary));
      final origin = tester.getTopLeft(find.byKey(kBoundary));
      final color = await tester.runAsync(() async {
        final image = await boundary.toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        final local = Offset(x, y) - origin;
        final i = (local.dy.floor() * image.width + local.dx.floor()) * 4;
        final b = data!.buffer.asUint8List();
        image.dispose();
        return Color.fromARGB(b[i + 3], b[i], b[i + 1], b[i + 2]);
      });
      expect(color, regionCellColor(endIndex, pick));
    });

    testWidgets('too many intersections in view says to zoom in', (tester) async {
      final repo = RegionRepo()
        ..regionError = const RenderFailure(
            kind: RenderFailureKind.tooLarge, message: 'a 4100 x 1000 draft has 4100000');
      await pumpEditor(tester, repo, bigDraft(2001, 2000), cell: 1);
      await tester.pump();
      await tester.pump(kRegionDebounce * 2);
      await tester.pump();
      await tester.pump();
      expect(
          find.text('Too much of this draft is in view to draw at once. Zoom in to see the cloth.'),
          findsOneWidget);
      expect(find.text('This draft is too large to preview on this device.'), findsNothing);
    });
  });
}
