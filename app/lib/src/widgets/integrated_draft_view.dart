// The integrated weaving draft view: threading across the top, tie-up top-right, the engine
// drawdown bitmap filling the main area, treadling/liftplan down the right side, all sharing ONE
// cell pitch (DraftLayout) so they stay pixel-aligned. See draft_layout.dart for the geometry and
// the axis decisions (the conventional end-1-at-RIGHT, pick-1-at-TOP, shaft-1-at-BOTTOM orientation,
// conforming to the engine bitmap).
//
// INTERACTION. One content-space [Listener] routes a pointer to the right region via
// [DraftLayout.hitTest] and drives the editor's drag-paint stroke (begin/paint/end on the
// notifier, which confines the stroke to its start region and coalesces it into one undo entry).
// Scroll-vs-paint is resolved by a TOOL MODE: in PENCIL the scroll views are frozen
// (NeverScrollableScrollPhysics) so the Listener owns every drag; in HAND the Listener is inert
// and the two-axis scroll pans the draft. The Listener sits INSIDE the scroll views, so its
// localPosition is content-space (scroll-invariant) and hit-testing needs no matrix un-projection.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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

  @override
  void dispose() {
    _hCtrl.dispose();
    _vCtrl.dispose();
    super.dispose();
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
      // Cap the canvas to its CONTENT height (not the whole viewport) so that when the cloth fits
      // with room to spare — e.g. a small/new draft on a tall phone — the editor's Column can pull
      // the dimension controls up into the freed space instead of leaving a gap under the cloth. In
      // a tight parent (the tablet rail's Expanded) the SizedBox is forced to fill, unchanged; only
      // a LOOSE parent (the phone body's Flexible) lets it shrink. Taller-than-viewport drafts cap
      // to maxHeight and scroll as before.
      final h = layout.totalSize.height.clamp(0.0, constraints.maxHeight);
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
                    label: 'Woven cloth preview, ${layout.ends} ends by ${layout.picks} picks',
                    image: true,
                    child: const RepaintBoundary(child: _DrawdownChild()),
                  ),
                ),
                Positioned.fromRect(
                  rect: layout.threadingRect,
                  child: RepaintBoundary(child: ThreadingGrid(geom: layout.threading)),
                ),
                if (layout.hasTieup)
                  Positioned.fromRect(
                    rect: layout.tieupRect,
                    child: RepaintBoundary(child: TieupGrid(geom: layout.tieup)),
                  ),
                Positioned.fromRect(
                  rect: layout.rightRect,
                  child: RepaintBoundary(child: RightGrid(geom: layout.right)),
                ),
                Positioned.fromRect(
                  rect: layout.warpColorRect,
                  child: RepaintBoundary(child: WarpColorBand(geom: layout.warpColor)),
                ),
                Positioned.fromRect(
                  rect: layout.weftColorRect,
                  child: RepaintBoundary(child: WeftColorBand(geom: layout.weftColor)),
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
      final next =
          (_navStartPitch * dist / _navStartDist).round().clamp(minCellPx, maxCellPx);
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
}

/// The cloth: the engine-rendered drawdown bitmap, stretched to fill its [drawdownRect] cell-for-
/// cell. BoxFit.fill + the exact-aspect rect means a uniform N->S nearest-neighbor scale (every
/// cloth cell lands on exactly one grid cell). No Dart re-paint of shed logic, no mirror, no
/// letterbox. During a re-render the previous frame stays (skipLoadingOnReload), so a fast edit
/// never flashes a spinner; the stale frame may stretch for one frame on a resize, then corrects.
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
      error: (e, _) => ColoredBox(color: colors.errorContainer),
    );
  }
}
