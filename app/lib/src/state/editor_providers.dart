// Riverpod providers that wire the editor's pure state ([draftEditorProvider]) to the FFI-backed
// repository and the live drawdown image.

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/draft_repository.dart';
import '../models/draft_issue.dart';
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
/// integer so cells stay crisp and the tap math is scroll-/zoom-invariant.
const List<int> zoomCellLevels = [8, 12, 16, 24, 32, 48];

/// The on-screen pixels-per-cell (the shared grid pitch). Stepped through [zoomCellLevels].
final zoomCellProvider = StateProvider<int>((ref) => 16);

/// Whether the live drawdown draws cell-boundary gridlines. Ephemeral VIEW CHROME (like
/// [zoomCellProvider]): it changes only how the cloth is rasterized for display, never the document,
/// so it stays off [DraftEditorNotifier]'s state and never touches undo/dedup. Default off.
final showGridlinesProvider = StateProvider<bool>((ref) => false);

/// Whether the live drawdown highlights snag-prone long floats (runs of [kLongFloatThreshold]+
/// same-face cells). Ephemeral view chrome, same rationale as [showGridlinesProvider]. Default off.
final highlightFloatsProvider = StateProvider<bool>((ref) => false);

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
