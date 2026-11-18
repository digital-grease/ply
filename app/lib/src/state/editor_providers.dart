// Riverpod providers that wire the editor's pure state ([draftEditorProvider]) to the FFI-backed
// repository and the live drawdown image.

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/draft_repository.dart';
import '../models/draft_doc.dart';
import '../models/draft_issue.dart';
import '../models/drawdown_region.dart';
import '../models/loom_type.dart';
import 'draft_editor_notifier.dart';

/// The app's single [DraftRepository] (the sole owner of the FFI bridge and on-device storage).
///
/// It must be OVERRIDDEN in `main()`'s `ProviderScope` with the instance built AFTER
/// `RustLib.init()`. The default throws on read so a forgotten override fails loudly at startup
/// rather than lazily mid-edit (and so widget tests must supply a fake, never a half-real repo).
final repositoryProvider = Provider<DraftRepository>((ref) {
  throw UnimplementedError(
    'repositoryProvider must be overridden in the root ProviderScope',
  );
});

/// Bumped when the weaving editor finishes writing a draft after it has already been left (a
/// Discard chosen while the write was under way). The write still lands, but the editor popped
/// without `true`, so the weaving library listens to this to list the draft. An ordinary save pops
/// `true` and the library refreshes on that instead.
final draftLibraryWritesProvider = StateProvider<int>((ref) => 0);

/// Pixels-per-intersection the ENGINE renders the drawdown at (internal raster pitch). The
/// integrated view scales this bitmap to the on-screen pitch via RawImage; the engine never
/// re-renders on zoom. Crispness only. (The editor's render is the [structuralDraft], so every
/// cell of that bitmap is exactly this many pixels square and the scale is uniform.)
const int previewCellPx = 12;

/// The editor's interaction mode. PENCIL paints cells (scroll is disabled so a drag never scrolls
/// instead of painting); HAND scrolls/pans the draft (no painting). Toggled from the editor AppBar.
enum EditorTool { pencil, hand }

/// The current tool. Default is pencil so a freshly-opened draft is immediately editable.
final editorToolProvider = StateProvider<EditorTool>((ref) => EditorTool.pencil);

/// The active brush-color palette index (0-based) for warp/weft painting. Ephemeral VIEW CHROME, NOT
/// on EditorState (so it never poisons undo-dedup or the preview select), exactly like
/// [zoomCellProvider]/[editorToolProvider]. Reset to 0 on [DraftEditorNotifier.load], remapped across
/// a palette remove (see [remapAfterRemove]), and clamped-on-read (see [activeBrushIndex]) so it can
/// never dangle past a shrunk palette.
final activePaletteColorProvider = StateProvider<int>((ref) => 0);

/// The engine's color-remove renumbering (matches `Draft::with_color_removed`): the brush pointing at
/// [e] after color [removed] is dropped — `e == removed -> 0`, `e > removed -> e - 1`, else unchanged.
/// Pure + top-level so it is unit-testable and stays in lockstep with the Rust rule.
int remapAfterRemove(int e, int removed) => e == removed ? 0 : (e > removed ? e - 1 : e);

/// Clamp a brush index into a palette of [paletteLength] colors (defends a dangling brush after a
/// smaller-palette shrink). The shared rule the brush consumers apply on read: the notifier's stroke
/// (off `state`), the palette ring, and the dimensions-bar dot. (The notifier cannot read its own
/// provider, so it calls this with `state.draft.palette.length` rather than a `Ref`.)
int clampBrush(int index, int paletteLength) =>
    paletteLength == 0 ? 0 : index.clamp(0, paletteLength - 1);

/// Discrete on-screen cell sizes (logical px) the integrated view can zoom through. Discrete +
/// integer so cells stay crisp and the tap math is scroll-/zoom-invariant. These are the SNAP points
/// the +/- buttons step through; pinch-zoom is continuous and clamps to [minCellPx]/[maxCellPx]
/// instead (kept off this list so adding a bigger step would not move the open-time auto-fit).
const List<int> zoomCellLevels = [8, 12, 16, 24, 32, 48];

/// Pinch-zoom pitch bounds (logical px/cell). Wider than [zoomCellLevels] so a pinch can push past the
/// largest button step or below the smallest; still integer, so the drawdown bitmap stays crisp.
/// [minCellPx] is the NORMAL floor; a LARGE draft lowers it adaptively (see [minZoomCellProvider]) so
/// you can always zoom out far enough to see the whole thing.
const int minCellPx = 6;
const int maxCellPx = 64;

/// The effective zoom-OUT floor (logical px/cell) for the open draft + viewport: [minCellPx] normally,
/// but LOWER for a draft too big to fit even at [minCellPx], so a pinch or the zoom-out button can
/// shrink it until the whole draft is visible (the fix for a large imported WIF that could not be
/// zoomed out enough). The integrated view recomputes this from the live dimensions + viewport via
/// [DraftLayout.fitCellPx]; pure VIEW CHROME like [zoomCellProvider].
final minZoomCellProvider = StateProvider<int>((ref) => minCellPx);

/// Step the cell pitch to the next/previous [zoomCellLevels] step from [cur] (dir +1 / -1). Snaps an
/// OFF-level [cur] (e.g. an exact pitch a pinch left behind) to the nearest level in the step
/// direction, saturating at [maxCellPx] going up and at [minPx] going down (pass the adaptive
/// [minZoomCellProvider] floor so a big draft steps below [minCellPx]). Pure so the AppBar overflow
/// and the on-canvas controls step identically.
int stepZoomLevel(int cur, int dir, {int minPx = minCellPx}) => dir > 0
    ? zoomCellLevels.firstWhere((l) => l > cur, orElse: () => maxCellPx)
    : zoomCellLevels.reversed.firstWhere((l) => l < cur, orElse: () => minPx);

/// The on-screen pixels-per-cell (the shared grid pitch). Stepped through [zoomCellLevels] by the
/// buttons, set freely (within [minCellPx]..[maxCellPx]) by a pinch.
final zoomCellProvider = StateProvider<int>((ref) => 16);

/// Whether the user has taken MANUAL control of the zoom (stepped it from the AppBar). Until then the
/// integrated view AUTO-FITS the initial pitch to the viewport on open (the largest [zoomCellLevels]
/// step whose whole draft fills the available area); once the user zooms, auto-fit yields and never
/// overrides their choice. Reset to false on each draft load so a freshly-opened draft re-fits.
/// Ephemeral view chrome, off EditorState like [zoomCellProvider].
final zoomUserSetProvider = StateProvider<bool>((ref) => false);

/// Whether the open draft PINS a "Book view" button to the editor's tools (the dimensions bar). The
/// Book view (see book_view_sheet.dart) is a separate presentation that lists the treadling grouped
/// into runs of identical picks; it is always reachable from the editor's overflow menu, and this
/// flag only decides whether a one-tap button sits with the other tools. It never changes the
/// editor's structural grid, which is one treadling row per pick, always.
///
/// The name and the persisted sidecar key ([DraftMeta.overshotTreadling]) are kept from the earlier
/// inline "overshot treadling" mode, so an older sidecar that set it now simply pins the button.
/// Auto-set true when an Overshot structure is generated (false for the other whole-draft
/// structures), toggleable from the Book view itself, and persisted per draft (seeded on load,
/// written on save). Ephemeral editor chrome like [loomTypeProvider]: it is not part of the cloth, so
/// it lives off EditorState and never touches undo/dedup.
final overshotTreadlingProvider = StateProvider<bool>((ref) => false);

/// The latest notice about shot groups that an edit changed as a SIDE EFFECT (a member's shed was
/// painted on the draft grid, a resize pruned a treadle, the shed direction changed), in plain words,
/// or null. Set by [DraftEditorNotifier]; the editor screen shows it once and clears it. Explicit
/// group edits in the Book view never set it.
final shotGroupNoticeProvider = StateProvider<String?>((ref) => null);

/// The loom type of the open draft. Seeded on [DraftEditorNotifier.load] from the sidecar
/// [DraftMeta] (a saved draft) or the new-draft choice, written back into the sidecar on save.
/// Ephemeral editor chrome (like [zoomCellProvider]) — it is metadata, not part of the rendered
/// cloth, so it lives off EditorState; picking a type applies its shed/drive PRESET to the draft.
final loomTypeProvider = StateProvider<LoomType>((ref) => LoomType.jack);

/// Whether the live drawdown draws cell-boundary gridlines. Ephemeral VIEW CHROME (like
/// [zoomCellProvider]): it changes only how the cloth is rasterized for display, never the document,
/// so it stays off [DraftEditorNotifier]'s state and never touches undo/dedup. Default off.
final showGridlinesProvider = StateProvider<bool>((ref) => false);

/// Whether the live drawdown highlights snag-prone long floats (runs of [kLongFloatThreshold]+
/// same-face cells). Ephemeral view chrome, same rationale as [showGridlinesProvider]. Default off.
final highlightFloatsProvider = StateProvider<bool>((ref) => false);

/// Whether the live drawdown shades each cell as a rounded woven thread (warp-faced cells read as
/// vertical strands, weft-faced as horizontal) so the cloth looks like fabric instead of a flat color
/// grid. Ephemeral view chrome like [showGridlinesProvider], but defaults ON: it is a presentation
/// nicety the editor wants by default (toggle it off from the editor's overflow menu). The thumbnail/
/// library path is unaffected — it always renders plain cloth (no options).
final showThreadTextureProvider = StateProvider<bool>((ref) => true);

/// The float length (in cells) at/above which [highlightFloatsProvider] tints a float. A pragmatic
/// default for "long enough to snag"; not user-tunable in this milestone.
const int kLongFloatThreshold = 5;

/// The STRUCTURAL draft the editor's drawdown is rendered from: [doc] with its per-thread warp and
/// weft thickness dropped, so the engine rasterizes exactly one uniform cell per end and pick. The
/// integrated view stretches that bitmap over its fixed grid, and only a uniform bitmap keeps
/// drawdown cell k on the same pixel edges as threading column k and treadling row k at every zoom
/// and pixel ratio. The thickness stays in the document (saved, exported, and shown by the yarn
/// preview); only this editor render ignores it. Returns [doc] itself when it has no thickness.
DraftDoc structuralDraft(DraftDoc doc) =>
    doc.warpThickness.isEmpty && doc.weftThickness.isEmpty
        ? doc
        : doc.copyWith(warpThickness: const <double>[], weftThickness: const <double>[]);

/// LATEST-WINS rendering shared by the editor's two drawdown images ([previewProvider] and
/// [wovenPreviewProvider]). A render is asynchronous (the FFI hop plus image decode), so a fast edit
/// can dispatch a newer render before an older one resolves, and Dart Futures carry no ordering
/// guarantee. A monotonic [_seq] guard tags each render; when a render finishes it checks whether a
/// newer one has since started, and if so DROPS its frame (frees the image, never resolves into
/// state) so a slow earlier render can never paint over a newer one. The superseded image is
/// disposed immediately because it was never shown; the image that IS shown is reclaimed by the
/// engine's `ui.Image` finalizer once a newer frame replaces it (eagerly disposing a frame that might
/// still be painted this turn would risk a use-after-dispose, so we don't).
abstract class DrawdownRenderController extends AutoDisposeAsyncNotifier<ui.Image> {
  /// Monotonic across rebuilds (the notifier instance is stable; only `build` re-runs).
  int _seq = 0;

  /// Start this provider's render. Called synchronously at the top of [build], so every `ref.watch`
  /// it makes registers before the first await.
  Future<ui.Image> startRender();

  @override
  Future<ui.Image> build() async {
    final mySeq = ++_seq;
    // The FFI render is un-cancellable, so it can resolve after the provider is disposed
    // (navigate away mid-render). Track that so we free the orphaned image instead of leaking it.
    var disposed = false;
    ref.onDispose(() => disposed = true);

    final image = await startRender();

    if (disposed || mySeq != _seq) {
      // Either the provider was torn down while we rendered, or a newer edit superseded us. Both
      // mean this frame will never be shown: free it and never resolve.
      image.dispose();
      return Completer<ui.Image>().future; // intentionally never completes
    }
    return image;
  }
}

/// The editor's live STRUCTURAL drawdown for the draft held by [draftEditorProvider]: the
/// [structuralDraft] (uniform cells, thickness ignored) with the editor's view overlays. Re-renders
/// on every edit (the engine recompute is microseconds) and decodes the RGBA buffer to a [ui.Image].
/// Latest-wins; see [DrawdownRenderController]. Only for drafts up to [kWholeRenderMaxCells]
/// intersections; a larger draft's editor renders a viewport at a time ([regionPreviewProvider]).
final previewProvider =
    AutoDisposeAsyncNotifierProvider<PreviewController, ui.Image>(PreviewController.new);

class PreviewController extends DrawdownRenderController {
  @override
  Future<ui.Image> startRender() {
    final repo = ref.watch(repositoryProvider);
    final draft = ref.watch(draftEditorProvider.select((s) => s.draft));
    // Overlay toggles are view chrome: watching them re-renders the cloth on toggle WITHOUT touching
    // the document (so undo/validation never fire). A no-op recompute is microseconds.
    final gridlines = ref.watch(showGridlinesProvider);
    final highlightFloats = ref.watch(highlightFloatsProvider);
    final threadTexture = ref.watch(showThreadTextureProvider);
    return repo.renderDto(
      structuralDraft(draft),
      cellPx: previewCellPx,
      gridlines: gridlines,
      floatThreshold: highlightFloats ? kLongFloatThreshold : 0,
      threadTexture: threadTexture,
    );
  }
}

/// The YARN PREVIEW image for the draft held by [draftEditorProvider]: its own render, independent
/// of the structural editor. It keeps the per-thread thickness (a fatter yarn draws a wider column
/// or taller row), always shades the thread texture, and never draws gridlines or float tints,
/// whatever the editor's view toggles say. An appearance approximation only, not a fabric model.
/// Watched only by the woven preview, so it renders only while that preview is on screen.
/// Latest-wins; see [DrawdownRenderController].
final wovenPreviewProvider =
    AutoDisposeAsyncNotifierProvider<WovenPreviewController, ui.Image>(WovenPreviewController.new);

class WovenPreviewController extends DrawdownRenderController {
  @override
  Future<ui.Image> startRender() {
    final repo = ref.watch(repositoryProvider);
    final draft = ref.watch(draftEditorProvider.select((s) => s.draft));
    return repo.renderDto(draft, cellPx: previewCellPx, threadTexture: true);
  }
}

// ---------------------------------------------------------------------------
// Viewport (region) rendering for LARGE drafts (M7-01). See ADR 0005.
// ---------------------------------------------------------------------------

/// The largest draft (in warp/weft intersections) whose drawdown the editor still renders WHOLE on
/// every edit ([previewProvider]). At this size the whole bitmap is already at the engine's 64 MiB
/// raster budget, which it reaches by dropping to 8 px per cell (it renders at [previewCellPx] up to
/// about 116,000 intersections), so every edit costs a budget-sized render, copy and decode. Above
/// it the drawdown renders only the cells in view ([regionPreviewProvider]), a raster about the size
/// of the screen however large the draft, which also makes drafts past the engine's 4 million
/// intersection whole-render budget viewable and editable. Small drafts keep the whole bitmap, which
/// pans and zooms without re-rendering.
const int kWholeRenderMaxCells = 250000;

/// Whether an [ends] x [picks] draft's editor drawdown renders a viewport at a time.
bool usesRegionRender(int ends, int picks) => ends * picks > kWholeRenderMaxCells;

/// The intersections a viewport request aims to stay under once it adds its overscan margin; past
/// this it asks for just the cells in view. (The engine's own budget, 4 million, is the hard limit;
/// past THAT the view says to zoom in.)
const int kRegionOverscanMaxCells = 1000000;

/// Below this engine pitch a viewport render leaves out the gridlines and the thread texture: a 1 px
/// seam on a 2 or 3 px cell would cover a third to half of the cloth (the bridge applies the same
/// rule to a render it had to fit down).
const int kMinOverlayCellPx = 4;

/// The largest engine pitch a viewport render asks for (the bridge fits it down further when the
/// region's raster would pass the device budget).
const int kMaxRegionCellPx = 256;

/// How long a viewport render waits after the view stops moving before it starts, so a pan or pinch
/// renders once where it settles instead of once per frame. Edits and overlay toggles in a still
/// view render at once.
const Duration kRegionDebounce = Duration(milliseconds: 60);

/// What the drawdown viewport wants drawn: [region] of the drawdown at [cellPx] ENGINE pixels per
/// intersection (the on-screen pitch in physical pixels, so the bitmap is crisp).
class DrawdownViewRequest {
  const DrawdownViewRequest({required this.region, required this.cellPx});

  final DrawdownRegion region;
  final int cellPx;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DrawdownViewRequest && region == other.region && cellPx == other.cellPx;

  @override
  int get hashCode => Object.hash(region, cellPx);

  @override
  String toString() => 'DrawdownViewRequest($region at $cellPx px)';
}

/// The engine pitch for a viewport render at an on-screen pitch of [cell] logical px: that many
/// PHYSICAL pixels, so the bitmap maps about 1:1 onto the screen.
int regionCellPx(double cell, double devicePixelRatio) =>
    (cell * devicePixelRatio).round().clamp(1, kMaxRegionCellPx);

/// The viewport request for a view showing [visible] cells of an [ends] x [picks] drawdown at
/// [cellPx], given the [previous] request. Keeps [previous] while it still covers everything in view
/// at the same pitch (so a pan inside the margin renders nothing); otherwise asks for the visible
/// cells grown by a quarter of the visible span on each side (at least 2 cells, so a deep zoom does
/// not ask for a raster far bigger than the screen), clipped to the draft, or just the visible cells
/// when that margin would pass [maxCells]. Pure.
DrawdownViewRequest regionRequestFor({
  required DrawdownRegion visible,
  required int ends,
  required int picks,
  required int cellPx,
  DrawdownViewRequest? previous,
  int maxCells = kRegionOverscanMaxCells,
}) {
  if (previous != null && previous.cellPx == cellPx) {
    final kept = previous.region.clippedTo(ends, picks);
    if (kept != null && kept.covers(visible)) return previous;
  }
  final grown = visible.grown(
    ends: math.max(2, visible.endCount ~/ 4),
    picks: math.max(2, visible.pickCount ~/ 4),
    totalEnds: ends,
    totalPicks: picks,
  );
  return DrawdownViewRequest(region: grown.cells > maxCells ? visible : grown, cellPx: cellPx);
}

/// The drawdown viewport's current request, written by the integrated view as it scrolls, zooms and
/// resizes (only while the open draft [usesRegionRender]). Null until the view has laid out.
/// Auto-dispose: it lives only while a region render watches it, so a stale request never outlives
/// the view or carries over to the next draft.
final drawdownViewRequestProvider =
    StateProvider.autoDispose<DrawdownViewRequest?>((ref) => null);

/// One rendered piece of the drawdown: [image] shows exactly [region]'s cells (highest end at the
/// left, first pick at the top), to be stretched over that region's cells.
class DrawdownTile {
  const DrawdownTile({required this.region, required this.image});

  final DrawdownRegion region;
  final ui.Image image;
}

/// The VIEWPORT drawdown for a large draft held by [draftEditorProvider]: just the cells the view
/// requests ([drawdownViewRequestProvider]), rendered from the [structuralDraft] with the editor's
/// overlays. A request that changed (the view moved) waits [kRegionDebounce] first; an edit or an
/// overlay toggle in a still view renders at once. Latest-wins like [DrawdownRenderController]: a
/// superseded or orphaned frame is freed and never resolves. Stays loading until the view has
/// written a request.
final regionPreviewProvider =
    AutoDisposeAsyncNotifierProvider<RegionPreviewController, DrawdownTile>(
        RegionPreviewController.new);

class RegionPreviewController extends AutoDisposeAsyncNotifier<DrawdownTile> {
  /// Monotonic across rebuilds (the notifier instance is stable; only `build` re-runs).
  int _seq = 0;

  /// The request the most recent STARTED render drew, to tell a moved view (debounce) from an edit
  /// in a still view (render at once).
  DrawdownViewRequest? _started;

  @override
  Future<DrawdownTile> build() async {
    final repo = ref.watch(repositoryProvider);
    final draft = ref.watch(draftEditorProvider.select((s) => s.draft));
    final request = ref.watch(drawdownViewRequestProvider);
    final gridlines = ref.watch(showGridlinesProvider);
    final highlightFloats = ref.watch(highlightFloatsProvider);
    final threadTexture = ref.watch(showThreadTextureProvider);
    final mySeq = ++_seq;
    var disposed = false;
    ref.onDispose(() => disposed = true);

    // The draft can change size before the view writes its next request: draw what is left.
    final region = request?.region.clippedTo(draft.ends, draft.picks);
    if (request == null || region == null) return Completer<DrawdownTile>().future;
    if (request != _started) {
      await Future<void>.delayed(kRegionDebounce);
      if (disposed || mySeq != _seq) return Completer<DrawdownTile>().future;
    }
    _started = request;

    final fine = request.cellPx >= kMinOverlayCellPx;
    final image = await repo.renderRegion(
      structuralDraft(draft),
      region,
      cellPx: request.cellPx,
      gridlines: gridlines && fine,
      floatThreshold: highlightFloats ? kLongFloatThreshold : 0,
      threadTexture: threadTexture && fine,
    );
    if (disposed || mySeq != _seq) {
      // Torn down while rendering, or a newer request/edit superseded us: never shown, free it.
      image.dispose();
      return Completer<DrawdownTile>().future; // intentionally never completes
    }
    return DrawdownTile(region: region, image: image);
  }
}

/// The live structural validation of the draft currently held by [draftEditorProvider]: the engine's
/// [DraftIssue] list (empty = clean), re-run on every edit. The inline ValidationPanel watches this
/// for the at-rest indicator; Save does NOT consult it (it re-validates the exact draft it persists,
/// see EditorScreen._save), so this provider is purely the advisory panel feed.
///
/// A direct twin of [previewProvider]'s LATEST-WINS shape (monotonic [_seq] + dispose guard), MINUS
/// the image-dispose arm — a `List<DraftIssue>` holds no native handle, so a dropped build just never
/// resolves. The guard is still mandatory: the validate FFI hop is uncancellable, so a stale
/// completion must not paint issues for a superseded draft. No debounce: validate() is strictly
/// cheaper than the preview's RGBA render+decode, and the seq guard already collapses a drag burst.
final validationProvider =
    AutoDisposeAsyncNotifierProvider<ValidationController, List<DraftIssue>>(
        ValidationController.new);

class ValidationController extends AutoDisposeAsyncNotifier<List<DraftIssue>> {
  /// Monotonic across rebuilds (the notifier instance is stable; only `build` re-runs).
  int _seq = 0;

  @override
  Future<List<DraftIssue>> build() async {
    final repo = ref.watch(repositoryProvider);
    // The SAME narrow select previewProvider uses: undo/redo/dirtyStructural/strokeBase churn never
    // re-triggers validation, and DraftDoc deep-== dedups a wander-out-and-back drag.
    final draft = ref.watch(draftEditorProvider.select((s) => s.draft));
    final mySeq = ++_seq;
    var disposed = false;
    ref.onDispose(() => disposed = true);

    final issues = await repo.validateDto(draft);

    if (disposed || mySeq != _seq) {
      // Torn down mid-validate, or a newer edit superseded us: drop this result, never resolve.
      return Completer<List<DraftIssue>>().future; // intentionally never completes
    }
    return issues;
  }
}

/// Whether the inline ValidationPanel is expanded to its full issue list (vs the one-line collapsed
/// summary). Pure view chrome (ephemeral like [zoomCellProvider]), kept out of EditorState: it must
/// survive a validate re-resolve AND be settable cross-widget (the editor resets it on each load).
final editorIssuesExpandedProvider = StateProvider<bool>((ref) => false);

/// A place in the draft the editor was asked to show (ADR 0021): a validation finding's "Show". The
/// draft view scrolls it into view and outlines it. [serial] changes on every request, so asking
/// for the same place twice shows it twice.
class DraftFocus {
  const DraftFocus(this.place, this.serial);

  final DraftPlace place;
  final int serial;
}

/// The latest [DraftFocus] asked for (null = none since the editor opened).
final draftFocusProvider = StateProvider<DraftFocus?>((ref) => null);

/// Ask the draft view to show [place].
void showDraftPlace(WidgetRef ref, DraftPlace place) {
  final p = ref.read(draftFocusProvider.notifier);
  p.state = DraftFocus(place, (p.state?.serial ?? 0) + 1);
}
