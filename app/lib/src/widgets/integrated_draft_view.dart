// The integrated weaving draft view: threading across the top, tie-up top-right, the engine
// drawdown bitmap filling the main area, treadling/liftplan down the right side, all sharing ONE
// cell pitch (DraftLayout) so they stay pixel-aligned. See draft_layout.dart for the geometry and
// the axis decisions (the conventional end-1-at-RIGHT, pick-1-at-TOP, shaft-1-at-BOTTOM orientation,
// conforming to the engine bitmap).
//
// STRUCTURAL DRAFT MODE, always: one cell per end and per pick in every region (one treadling row
// per pick), and the drawdown is rendered from the structural draft (per-thread thickness ignored),
// so drawdown cell k shares its edges with threading column k and treadling row k. Yarn thickness
// is shown only by the separate yarn preview (woven_preview.dart); runs of identical picks are
// grouped only by the separate Book view (book_view_sheet.dart).
//
// INTERACTION. One content-space [Listener] routes a pointer to the right region via
// [DraftLayout.hitTest] and drives the editor's drag-paint stroke (begin/paint/end on the
// notifier, which confines the stroke to its start region and coalesces it into one undo entry).
// Scroll-vs-paint is resolved by a TOOL MODE: in PENCIL the scroll views are frozen
// (NeverScrollableScrollPhysics) so the Listener owns every drag; in HAND the Listener is inert
// and the two-axis scroll pans the draft. The Listener sits INSIDE the scroll views, so its
// localPosition is content-space (scroll-invariant) and hit-testing needs no matrix un-projection.
//
// LARGE DRAFTS (M7-01 viewport rendering, ADR 0005). The view tracks the
// canvas rect in view (scroll offsets + viewport size). Every grid paints only the cells inside a
// margin-padded, tile-snapped [GridWindow] of it. A draft over [kWholeRenderMaxCells] intersections
// does not render its whole drawdown on each edit: the view asks for just the drawdown cells in view
// plus a margin ([drawdownViewRequestProvider], at the on-screen pitch in physical pixels) and lays
// the returned tile over exactly those cells ([DraftLayout.drawdownCellsRect]), the same uniform
// stretch as the whole bitmap, so alignment with the threading and treadling stays exact. Smaller
// drafts keep the whole-render path unchanged.

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show SchedulerBinding;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/draft_repository.dart' show previewErrorMessage, regionPreviewErrorMessage;
import '../models/double_weave_layers.dart' show hasLayerRoles;
import '../models/draft_doc.dart';
import '../state/draft_editor_notifier.dart';
import '../state/editor_providers.dart';
import 'draft_grids.dart';
import 'draft_layout.dart';

class IntegratedDraftView extends ConsumerStatefulWidget {
  const IntegratedDraftView({super.key});

  @override
  ConsumerState<IntegratedDraftView> createState() => _IntegratedDraftViewState();
}

class _IntegratedDraftViewState extends ConsumerState<IntegratedDraftView> {
  /// The single pointer that owns the in-progress paint stroke. A drag-paint is SINGLE-TOUCH: a second
  /// finger is ignored so it cannot split the stroke (the notifier holds one stroke's scratch).
  /// Plain field, not setState: it only steers later pointer events, never the build output.
  int? _activePointer;

  /// Every pointer currently down on the canvas, in GLOBAL (screen) coordinates — scroll-invariant, so
  /// they drive the two-finger navigate gesture (pinch distance + pan focal) regardless of pan offset.
  /// Plain field: it only steers later pointer events, never the build output.
  final Map<int, Offset> _pointers = {};

  /// Controllers for the two nested scroll views, so a two-finger PAN can drive the offset directly
  /// while they are frozen during the gesture. Owned here; disposed in [dispose].
  final ScrollController _hCtrl = ScrollController();
  final ScrollController _vCtrl = ScrollController();

  /// True while a two-finger NAVIGATE (pinch-zoom + pan) is in progress, in ANY tool. It freezes the
  /// scroll physics so the two fingers own the gesture, so it DOES gate the build output (setState).
  bool _navigating = false;
  double _navStartDist = 0;
  int _navStartPitch = 16;
  Offset _navFocal = Offset.zero;

  /// The canvas-space rect the grids paint (the view plus a margin, snapped to tiles; see
  /// [gridPaintWindow]). Updated on scroll and layout; the grid painters repaint when it moves.
  final ValueNotifier<Rect> _paintWindow = ValueNotifier<Rect>(Rect.zero);

  /// The latest geometry, viewport size and pixel ratio, kept for the scroll listener (which runs
  /// outside build). Plain fields: they only steer [_syncViewport].
  DraftLayout? _layout;
  Size? _viewport;
  double _dpr = 1;

  /// Whether the open draft renders its drawdown a viewport at a time ([usesRegionRender]).
  bool _regionMode = false;

  /// A post-frame viewport settle is already queued for this frame.
  bool _settleQueued = false;

  @override
  void initState() {
    super.initState();
    _hCtrl.addListener(_syncViewport);
    _vCtrl.addListener(_syncViewport);
  }

  @override
  void dispose() {
    _hCtrl.dispose();
    _vCtrl.dispose();
    _paintWindow.dispose();
    super.dispose();
  }

  /// The canvas rect in view: the scroll offsets (clamped to what the current layout can scroll,
  /// since a shrinking canvas corrects its offsets silently during layout) by the viewport size.
  Rect? _visibleRect() {
    final layout = _layout;
    final viewport = _viewport;
    if (layout == null || viewport == null) return null;
    double offset(ScrollController c, double content, double extent) {
      final raw = c.hasClients && c.position.hasPixels ? c.offset : 0.0;
      final max = content - extent;
      return raw.clamp(0.0, max > 0 ? max : 0.0);
    }

    final total = layout.totalSize;
    return Rect.fromLTWH(
      offset(_hCtrl, total.width, viewport.width),
      offset(_vCtrl, total.height, viewport.height),
      viewport.width,
      viewport.height,
    );
  }

  /// Bring the grids' paint window up to date with the view at once (so this frame paints what is in
  /// view), then settle after the frame: re-check with the laid-out offsets and, for a large draft,
  /// update the drawdown's viewport request (a provider write, so never during build or layout).
  void _syncViewport() {
    final visible = _visibleRect();
    if (visible == null) return;
    final window = gridPaintWindow(visible);
    if (_paintWindow.value != window) _paintWindow.value = window;
    if (_settleQueued) return;
    _settleQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _settleQueued = false;
      if (!mounted) return;
      final visible = _visibleRect();
      final layout = _layout;
      if (visible == null || layout == null) return;
      final window = gridPaintWindow(visible);
      if (_paintWindow.value != window) _paintWindow.value = window;
      if (!_regionMode) return;
      final seen = layout.drawdownCellsIn(visible);
      if (seen == null) return; // the drawdown is scrolled out of view: keep the last request
      final request = ref.read(drawdownViewRequestProvider.notifier);
      final next = regionRequestFor(
        visible: seen,
        ends: layout.ends,
        picks: layout.picks,
        cellPx: regionCellPx(layout.cell, _dpr),
        previous: request.state,
      );
      if (next != request.state) request.state = next;
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  @override
  Widget build(BuildContext context) {
    // If the user flips to HAND while a stroke is open, the pencil handlers stop painting and no
    // pointer-up would seal it, so seal the stroke here. Flipping to PENCIL ends any live pinch (the
    // single pointer is about to paint); the editorTool watch below rebuilds, so no setState needed.
    ref.listen(editorToolProvider, (_, tool) {
      if (tool != EditorTool.pencil && _activePointer != null) {
        _activePointer = null;
        ref.read(draftEditorProvider.notifier).endStroke();
      }
    });

    // Watch ONLY what changes the geometry; cell pitch + tool from their own providers.
    final dims = ref.watch(draftEditorProvider.select((s) => (
          s.draft.ends,
          s.draft.picks,
          s.draft.shafts,
          s.draft.treadles,
          s.draft.drive is DraftTreadled,
        )));
    final cell = ref.watch(zoomCellProvider);
    final pencil = ref.watch(editorToolProvider) == EditorTool.pencil;
    _dpr = MediaQuery.devicePixelRatioOf(context);

    final layout = DraftLayout(
      ends: dims.$1,
      picks: dims.$2,
      shafts: dims.$3,
      treadles: dims.$4,
      hasTieup: dims.$5,
      cell: cell.toDouble(),
    );

    if (layout.ends == 0 || layout.picks == 0) {
      // ANY empty axis: a zero-area drawdown bitmap can't be decoded (the preview would hang), so
      // show the placeholder until the draft has both warp ends and picks.
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'This draft has no warp ends or picks yet.\nUse the steppers below to add ends and picks.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ),
      );
    }

    final notifier = ref.read(draftEditorProvider.notifier);
    _regionMode = usesRegionRender(layout.ends, layout.picks);
    // Watch the user-set guard so the "Fit to view" control (which clears it) rebuilds us and re-runs
    // the open-time auto-fit below.
    ref.watch(zoomUserSetProvider);
    // Freeze scrolling in PENCIL (the Listener owns single-finger drags to paint) AND during a
    // two-finger navigate (the gesture drives pan + zoom directly). At rest in HAND both are false, so
    // a single finger pans via the scroll views.
    final physics =
        (pencil || _navigating) ? const NeverScrollableScrollPhysics() : null;

    // Size the pitch to fill the viewport on open (one-shot per load, until the user zooms manually).
    // A LayoutBuilder gives the TRUE bounded viewport on both axes; the scroll view's own
    // context.size shrink-wraps its scrolling axis to content, which would defeat the fit.
    return LayoutBuilder(builder: (context, constraints) {
      _maybeAutoFit(dims, constraints.biggest);
      _updateMinPitch(dims, constraints.biggest);
      // Cap the canvas to its CONTENT height (not the whole viewport) so that when the cloth fits
      // with room to spare — e.g. a small/new draft on a tall phone — the editor's Column can pull
      // the dimension controls up into the freed space instead of leaving a gap under the cloth. In
      // a tight parent (the tablet rail's Expanded) the SizedBox is forced to fill, unchanged; only
      // a LOOSE parent (the phone body's Flexible) lets it shrink. Taller-than-viewport drafts cap
      // to maxHeight and scroll as before.
      final h = layout.totalSize.height.clamp(0.0, constraints.maxHeight);
      // Track the viewport (an unbounded width, never expected here, falls back to the canvas width)
      // before building the grids, so their first paint already covers what is in view.
      _layout = layout;
      _viewport = Size(
        constraints.maxWidth.isFinite ? constraints.maxWidth : layout.totalSize.width,
        h,
      );
      _syncViewport();
      // The cloth fills its area; pan/zoom is now BY GESTURE directly on it (pinch + two-finger drag),
      // with the zoom/fit buttons living in the dimensions bar (off the grid) rather than floating over
      // editable cells.
      return SizedBox(height: h, child: _canvas(layout, physics, pencil, notifier));
    });
  }

  /// The scrollable, pannable draft canvas (threading / tie-up / drawdown / treadling + color bands)
  /// at the shared [DraftLayout] pitch. Split out so [build] can wrap it in a LayoutBuilder for the
  /// open-time auto-fit without nesting the whole tree a level deeper.
  Widget _canvas(
    DraftLayout layout,
    ScrollPhysics? physics,
    bool pencil,
    DraftEditorNotifier notifier,
  ) {
    // A double weave's drawdown is every intersection of both layers, so its image label says so.
    final layered = ref.watch(draftEditorProvider.select((s) => hasLayerRoles(s.draft)));
    return SingleChildScrollView(
      controller: _vCtrl,
      scrollDirection: Axis.vertical,
      physics: physics,
      child: SingleChildScrollView(
        controller: _hCtrl,
        scrollDirection: Axis.horizontal,
        physics: physics,
        child: SizedBox.fromSize(
          size: layout.totalSize,
          child: Listener(
            behavior: HitTestBehavior.opaque,
            // Handlers are always attached so HAND mode can observe pointers for the pinch; a Listener
            // does NOT enter the gesture arena, so this never steals the scroll views' pan. Each
            // handler branches on the tool internally.
            onPointerDown: (e) => _onPointerDown(e, layout, pencil, notifier),
            onPointerMove: (e) => _onPointerMove(e, layout, pencil, notifier),
            onPointerUp: (e) => _onPointerEnd(e, pencil, notifier),
            onPointerCancel: (e) => _onPointerEnd(e, pencil, notifier),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fromRect(
                  rect: layout.drawdownRect,
                  // Compact image label only (N ends by P picks from the live layout, so it updates
                  // on resize); per-cell semantics + screen-reader editing of the cloth is future
                  // work. The bitmap itself stays a single opaque RawImage.
                  child: Semantics(
                    label: layered
                        ? 'Drawdown of every intersection of both layers, not the face of the '
                            'cloth, ${layout.ends} ends by ${layout.picks} picks'
                        : 'Drawdown, ${layout.ends} ends by ${layout.picks} picks',
                    image: true,
                    child: RepaintBoundary(
                      child: _regionMode
                          ? _RegionDrawdown(layout: layout)
                          : const _DrawdownChild(),
                    ),
                  ),
                ),
                Positioned.fromRect(
                  rect: layout.threadingRect,
                  child: RepaintBoundary(
                    child: ThreadingGrid(
                      geom: layout.threading,
                      window: GridWindow(_paintWindow, layout.threadingRect.topLeft),
                    ),
                  ),
                ),
                if (layout.hasTieup)
                  Positioned.fromRect(
                    rect: layout.tieupRect,
                    child: RepaintBoundary(
                      child: TieupGrid(
                        geom: layout.tieup,
                        window: GridWindow(_paintWindow, layout.tieupRect.topLeft),
                      ),
                    ),
                  ),
                Positioned.fromRect(
                  rect: layout.rightRect,
                  child: RepaintBoundary(
                    child: RightGrid(
                      geom: layout.right,
                      window: GridWindow(_paintWindow, layout.rightRect.topLeft),
                    ),
                  ),
                ),
                Positioned.fromRect(
                  rect: layout.warpColorRect,
                  child: RepaintBoundary(
                    child: WarpColorBand(
                      geom: layout.warpColor,
                      window: GridWindow(_paintWindow, layout.warpColorRect.topLeft),
                    ),
                  ),
                ),
                Positioned.fromRect(
                  rect: layout.weftColorRect,
                  child: RepaintBoundary(
                    child: WeftColorBand(
                      geom: layout.weftColor,
                      window: GridWindow(_paintWindow, layout.weftColorRect.topLeft),
                    ),
                  ),
                ),
                // A mirror of each pick's weft color flush beside the treadling, so the pick's color
                // reads right next to the treadle to press (the left band by the cloth is its twin).
                Positioned.fromRect(
                  rect: layout.weftMarkerRect,
                  child: RepaintBoundary(
                    child: WeftMarkerBand(
                      geom: layout.weftMarker,
                      window: GridWindow(_paintWindow, layout.weftMarkerRect.topLeft),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // --- pointer routing: one finger PAINTS (pencil) or pans (hand); TWO fingers navigate (any tool) ---

  void _onPointerDown(
      PointerDownEvent e, DraftLayout layout, bool pencil, DraftEditorNotifier notifier) {
    _pointers[e.pointer] = e.position; // global (scroll-invariant) — for the navigate gesture
    if (_pointers.length >= 2) {
      // Two fingers anywhere on the cloth = navigate (pinch-zoom + pan), in ANY tool. Seal an open
      // paint stroke first so its cells commit as their own undo entry instead of dangling.
      if (_activePointer != null) {
        _activePointer = null;
        notifier.endStroke();
      }
      if (!_navigating) _beginNavigate();
      return;
    }
    // Single finger: PENCIL paints; HAND lets the scroll views pan (nothing to do here).
    if (pencil) {
      if (_activePointer != null) return;
      final hit = layout.hitTest(e.localPosition);
      if (hit == null) return;
      _activePointer = e.pointer;
      notifier.beginStroke(hit);
    }
  }

  void _onPointerMove(
      PointerMoveEvent e, DraftLayout layout, bool pencil, DraftEditorNotifier notifier) {
    if (_pointers.containsKey(e.pointer)) _pointers[e.pointer] = e.position; // global
    if (_navigating && _pointers.length >= 2) {
      _updateNavigate();
      return;
    }
    if (pencil && e.pointer == _activePointer) {
      final hit = layout.hitTest(e.localPosition);
      if (hit != null) notifier.paintAt(hit);
    }
  }

  void _onPointerEnd(PointerEvent e, bool pencil, DraftEditorNotifier notifier) {
    _pointers.remove(e.pointer);
    if (_navigating) {
      // A leftover single finger after a navigate is inert (it never began a stroke), so it won't
      // suddenly paint or scroll; it just ends the gesture once we drop below two pointers.
      if (_pointers.length < 2) _endNavigate();
      return;
    }
    if (pencil && e.pointer == _activePointer) {
      _activePointer = null;
      notifier.endStroke();
    }
  }

  /// Two-finger NAVIGATE (pinch-zoom + pan), in ANY tool. Implemented off the raw [Listener] — which
  /// observes pointers without entering the gesture arena — and driving the scroll controllers
  /// directly, so it coexists with single-finger paint/scroll without an arena fight. The pitch stays
  /// an integer (crisp nearest-neighbor bitmap), clamped to [minCellPx]..[maxCellPx].
  void _beginNavigate() {
    final g = _pointers.values.toList();
    _navStartDist = (g[0] - g[1]).distance;
    _navStartPitch = ref.read(zoomCellProvider);
    _navFocal = (g[0] + g[1]) / 2;
    setState(() => _navigating = true);
  }

  void _updateNavigate() {
    final g = _pointers.values.toList();
    // PAN: move the view opposite the focal-point travel so the cloth follows the fingers.
    final focal = (g[0] + g[1]) / 2;
    _panBy(_navFocal - focal);
    _navFocal = focal;
    // ZOOM: set the pitch from the pinch-distance ratio.
    final dist = (g[0] - g[1]).distance;
    if (_navStartDist > 0 && dist > 0) {
      // Clamp the lower end to the ADAPTIVE floor (minCellPx for a normal draft, lower for one too big
      // to fit at minCellPx) so a pinch can shrink a large draft until the whole thing is on screen.
      final floor = ref.read(minZoomCellProvider);
      var next = (_navStartPitch * dist / _navStartDist).round();
      if (next < floor) next = floor;
      if (next > maxCellPx) next = maxCellPx;
      if (next != ref.read(zoomCellProvider)) {
        ref.read(zoomCellProvider.notifier).state = next;
        ref.read(zoomUserSetProvider.notifier).state = true; // a manual zoom; auto-fit yields
      }
    }
  }

  /// Translate the scroll offsets by [delta] (clamped to the scrollable range). A no-op for an axis
  /// with no overflow (maxScrollExtent 0), so panning a draft that already fits does nothing.
  void _panBy(Offset delta) {
    if (_hCtrl.hasClients) {
      _hCtrl.jumpTo((_hCtrl.offset + delta.dx).clamp(0.0, _hCtrl.position.maxScrollExtent));
    }
    if (_vCtrl.hasClients) {
      _vCtrl.jumpTo((_vCtrl.offset + delta.dy).clamp(0.0, _vCtrl.position.maxScrollExtent));
    }
  }

  void _endNavigate() => setState(() => _navigating = false);

  /// Size the pitch to the viewport ONCE when a draft opens (until the user zooms manually). Fed the
  /// TRUE viewport [available] from [build]'s LayoutBuilder; the provider WRITE is deferred to a
  /// post-frame callback (so it never writes during build), and [zoomUserSetProvider] makes it a
  /// one-shot per load (a manual zoom or the next [_load] flips the guard). [dims] is the live
  /// (ends, picks, shafts, treadles, hasTieup).
  void _maybeAutoFit((int, int, int, int, bool) dims, Size available) {
    if (ref.read(zoomUserSetProvider) || !available.isFinite || available.isEmpty) return;
    final fit = DraftLayout.fitCellLevel(
      ends: dims.$1,
      picks: dims.$2,
      shafts: dims.$3,
      treadles: dims.$4,
      hasTieup: dims.$5,
      available: available,
      levels: zoomCellLevels,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || ref.read(zoomUserSetProvider)) return;
      ref.read(zoomCellProvider.notifier).state = fit;
      ref.read(zoomUserSetProvider.notifier).state = true; // one-shot per load
    });
  }

  /// Keep the adaptive zoom-OUT floor ([minZoomCellProvider]) in step with the live draft + viewport:
  /// [minCellPx] for a normal draft, but LOWER when the whole draft does not fit even at [minCellPx],
  /// so a pinch (or the zoom-out button) can shrink a large imported draft until everything is visible.
  /// Unlike [_maybeAutoFit] this is NOT one-shot — it tracks every resize/zoom — but it only WRITES the
  /// provider (post-frame, never during build) when the floor actually changes, so it never churns.
  void _updateMinPitch((int, int, int, int, bool) dims, Size available) {
    if (!available.isFinite || available.isEmpty) return;
    final floor = DraftLayout.fitCellPx(
      ends: dims.$1,
      picks: dims.$2,
      shafts: dims.$3,
      treadles: dims.$4,
      hasTieup: dims.$5,
      available: available,
      maxPx: minCellPx, // never raise the floor above the normal one; only lower it for a big draft
    );
    if (ref.read(minZoomCellProvider) == floor) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || ref.read(minZoomCellProvider) == floor) return;
      ref.read(minZoomCellProvider.notifier).state = floor;
    });
  }
}

/// The cloth: the engine-rendered STRUCTURAL drawdown bitmap, stretched to fill its [drawdownRect]
/// cell-for-cell. [previewProvider] renders the structural draft (per-thread thickness ignored), so
/// the bitmap is a uniform grid of `ends x picks` equal cells and BoxFit.fill over the exact-aspect
/// rect is a uniform nearest-neighbor scale: every cloth cell lands on exactly one grid cell, at
/// every zoom and pixel ratio. (A thickness-aware bitmap here would put its variable cell edges off
/// the fixed grid, which is why yarn sizes live only in the separate yarn preview.) No Dart re-paint
/// of shed logic, no mirror, no letterbox. During a re-render the previous frame stays
/// (skipLoadingOnReload), so a fast edit never flashes a spinner; the stale frame may stretch for
/// one frame on a resize, then corrects.
class _DrawdownChild extends ConsumerWidget {
  const _DrawdownChild();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preview = ref.watch(previewProvider);
    final colors = Theme.of(context).colorScheme;
    return preview.when(
      skipLoadingOnReload: true,
      data: (img) => RawImage(
        image: img,
        fit: BoxFit.fill,
        filterQuality: FilterQuality.none,
        isAntiAlias: false,
      ),
      loading: () => ColoredBox(color: colors.surfaceContainerHighest),
      error: (e, _) => ColoredBox(
        color: colors.errorContainer,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              previewErrorMessage(e),
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.onErrorContainer),
            ),
          ),
        ),
      ),
    );
  }
}

/// The canvas-space rect the grids paint for a view showing [visible]: [visible] grown by one
/// [tile] on every side and snapped outward to whole tiles, so it only changes (and the grids only
/// repaint) when the view has moved about a tile, while a fling never outruns the painted cells.
/// Pure.
Rect gridPaintWindow(Rect visible, {double tile = 256}) => Rect.fromLTRB(
      ((visible.left - tile) / tile).floor() * tile,
      ((visible.top - tile) / tile).floor() * tile,
      ((visible.right + tile) / tile).ceil() * tile,
      ((visible.bottom + tile) / tile).ceil() * tile,
    );

/// The cloth of a LARGE draft ([usesRegionRender]): the engine renders only the cells in view plus a
/// margin ([regionPreviewProvider]), and that tile is stretched over exactly its own cells
/// ([DraftLayout.drawdownCellsRect]): a uniform nearest-neighbor scale of uniform cells, the same as
/// the whole bitmap in [_DrawdownChild], so tile cell (end, pick) lies under threading column `end`
/// and beside treadling row `pick` at every zoom and pixel ratio. Cells not rendered yet show the
/// plain loading color. While the next tile renders the last one stays where it was (its cells
/// keep their place through a pan, a zoom, or an added end). A failure shows its message over the
/// cells in view.
class _RegionDrawdown extends ConsumerWidget {
  const _RegionDrawdown({required this.layout});

  final DraftLayout layout;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tile = ref.watch(regionPreviewProvider);
    final request = ref.watch(drawdownViewRequestProvider);
    final colors = Theme.of(context).colorScheme;
    final failed = tile.hasError && !tile.isLoading;
    final shown = failed ? null : tile.valueOrNull;
    final errorCells = failed ? request?.region.clippedTo(layout.ends, layout.picks) : null;
    return ClipRect(
      child: Stack(
        children: [
          Positioned.fill(child: ColoredBox(color: colors.surfaceContainerHighest)),
          if (shown != null)
            Positioned.fromRect(
              rect: layout.drawdownCellsRect(shown.region),
              child: RawImage(
                image: shown.image,
                fit: BoxFit.fill,
                filterQuality: FilterQuality.none,
                isAntiAlias: false,
              ),
            ),
          if (errorCells != null)
            Positioned.fromRect(
              rect: layout.drawdownCellsRect(errorCells),
              child: ColoredBox(
                color: colors.errorContainer,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(
                      regionPreviewErrorMessage(tile.error!),
                      textAlign: TextAlign.center,
                      style: TextStyle(color: colors.onErrorContainer),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
