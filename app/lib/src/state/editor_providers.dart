// Riverpod providers that wire the editor's pure state ([draftEditorProvider]) to the FFI-backed
// repository and the live drawdown image.

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/draft_repository.dart';
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

/// Pixels-per-intersection for the live editor preview. Crispness only; `BoxFit` handles layout.
const int previewCellPx = 12;

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
    final mySeq = ++_seq;

    final image = await repo.renderDto(draft, cellPx: previewCellPx);

    if (mySeq != _seq) {
      // A newer edit started rendering while this one was in flight. Riverpod is already
      // awaiting that newer build, so this result would be a stale frame: free it and never
      // resolve, leaving the newer build to set the state.
      image.dispose();
      return Completer<ui.Image>().future; // intentionally never completes (superseded frame)
    }
    return image;
  }
}
