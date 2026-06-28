// Riverpod providers that wire the editor's pure state ([draftEditorProvider]) to the FFI-backed
// repository and the live drawdown image.

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/draft_repository.dart';
import '../models/draft_issue.dart';
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

/// Pixels-per-intersection the ENGINE renders the drawdown at (internal raster pitch). The
/// integrated view scales this bitmap to the on-screen pitch via RawImage; the engine never
/// re-renders on zoom. Crispness only.
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

/// The SELECTED compressed-treadling entry (run) index, or null when nothing is selected. Tapping a
/// treadling row selects it; the dimensions bar's per-row count stepper edits this entry. Ephemeral
/// view chrome (like the zoom) — reset on load. A consumer treats an index past the live entry count
/// (a run that merged away) as "no selection".
final selectedTreadlingEntryProvider = StateProvider<int?>((ref) => null);

/// Whether the open draft uses the OVERSHOT "book" treadling: the treadling collapses runs of
/// identical consecutive picks into one numbered row ("throw this shed N times"), and the dimensions
/// bar shows the per-row treadle / count / add / delete controls. OFF (the default) shows the normal
/// per-pick treadling — one row per pick, aligned with the drawdown, no repeat counts — so the
/// overshot shorthand never leaks onto plain/twill/satin drafts. Auto-set true when an Overshot
/// structure is generated, toggleable from the editor overflow menu, and persisted per draft in the
/// sidecar [DraftMeta] (seeded on load, written on save). Ephemeral editor chrome like
/// [loomTypeProvider]: it is a VIEW+EDIT mode, not part of the rendered cloth, so it lives off
/// EditorState and never touches undo/dedup.
final overshotTreadlingProvider = StateProvider<bool>((ref) => false);

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

/// The live drawdown image for the draft currently held by [draftEditorProvider]. Re-renders on
/// every edit (the engine recompute is microseconds) and decodes the RGBA buffer to a [ui.Image].
///
/// LATEST-WINS. A render is asynchronous (the FFI hop plus image decode), so a fast edit can
/// dispatch a newer render before an older one resolves, and Dart Futures carry no ordering
/// guarantee. A monotonic [_seq] guard tags each render; when a render finishes it checks whether
/// a newer one has since started, and if so DROPS its frame (frees the image, never resolves into
/// state) so a slow earlier render can never paint over a newer one. The superseded image is
/// disposed immediately because it was never shown; the image that IS shown is reclaimed by the
/// engine's `ui.Image` finalizer once a newer frame replaces it (eagerly disposing a frame that
/// might still be painted this turn would risk a use-after-dispose, so we don't).
final previewProvider =
    AutoDisposeAsyncNotifierProvider<PreviewController, ui.Image>(PreviewController.new);

class PreviewController extends AutoDisposeAsyncNotifier<ui.Image> {
  /// Monotonic across rebuilds (the notifier instance is stable; only `build` re-runs).
  int _seq = 0;

  @override
  Future<ui.Image> build() async {
    final repo = ref.watch(repositoryProvider);
    final draft = ref.watch(draftEditorProvider.select((s) => s.draft));
    // Overlay toggles are view chrome: watching them re-renders the cloth on toggle WITHOUT touching
    // the document (so undo/validation never fire). A no-op recompute is microseconds.
    final gridlines = ref.watch(showGridlinesProvider);
    final highlightFloats = ref.watch(highlightFloatsProvider);
    final threadTexture = ref.watch(showThreadTextureProvider);
    final mySeq = ++_seq;
    // The FFI render is un-cancellable, so it can resolve after the provider is disposed
    // (navigate away mid-render). Track that so we free the orphaned image instead of leaking it.
    var disposed = false;
    ref.onDispose(() => disposed = true);

    final image = await repo.renderDto(
      draft,
      cellPx: previewCellPx,
      gridlines: gridlines,
      floatThreshold: highlightFloats ? kLongFloatThreshold : 0,
      threadTexture: threadTexture,
    );

    if (disposed || mySeq != _seq) {
      // Either the provider was torn down while we rendered, or a newer edit superseded us. Both
      // mean this frame will never be shown: free it and never resolve.
      image.dispose();
      return Completer<ui.Image>().future; // intentionally never completes
    }
    return image;
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
/// summary). Pure view chrome (ephemeral like [zoomCellProvider]), kept out of EditorState — it must
/// survive a validate re-resolve AND be settable cross-widget from the Save-with-errors dialog's
/// "Show me" action.
final editorIssuesExpandedProvider = StateProvider<bool>((ref) => false);
