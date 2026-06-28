import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/editor_providers.dart';

/// A compact, always-visible cluster of view controls floating over the draft canvas: zoom in / out,
/// fit-to-view, and a draw/pan toggle. It makes the formerly overflow-buried zoom and the tool-mode
/// pan discoverable right where the cloth is — the fix for a zoomed-in draft running off the side of
/// the tablet side-rail layout with no obvious way to move or shrink it (you can now zoom out, fit, or
/// switch to pan without hunting the AppBar).
///
/// Everything here is ephemeral VIEW CHROME driven through the same providers the AppBar uses
/// ([zoomCellProvider] via [stepZoomLevel], [zoomUserSetProvider] for fit, [editorToolProvider] for
/// the tool), so the controls and the AppBar stay in lockstep with no second source of truth.
class EditorViewControls extends ConsumerWidget {
  const EditorViewControls({super.key});

  void _step(WidgetRef ref, int dir) {
    ref.read(zoomCellProvider.notifier).state = stepZoomLevel(
      ref.read(zoomCellProvider),
      dir,
      minPx: ref.read(minZoomCellProvider), // adaptive floor: step below minCellPx for a big draft
    );
    ref.read(zoomUserSetProvider.notifier).state = true; // a manual zoom; auto-fit yields
  }

  /// Re-arm the open-time auto-fit: clearing the user-set guard makes the integrated view re-fit the
  /// pitch to the current viewport on its next build (it watches this guard), then re-claim it.
  void _fit(WidgetRef ref) => ref.read(zoomUserSetProvider.notifier).state = false;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final cell = ref.watch(zoomCellProvider);
    final minCell = ref.watch(minZoomCellProvider); // adaptive zoom-out floor (lower for a big draft)
    final pencil = ref.watch(editorToolProvider) == EditorTool.pencil;

    Widget btn({
      required IconData icon,
      required String tooltip,
      required VoidCallback? onPressed,
      bool selected = false,
    }) =>
        IconButton(
          visualDensity: VisualDensity.compact,
          iconSize: 20,
          isSelected: selected,
          tooltip: tooltip,
          onPressed: onPressed,
          icon: Icon(icon),
        );

    // A compact horizontal pill (short enough to fit even a small/short cloth area at any zoom).
    return Material(
      color: cs.surface.withValues(alpha: 0.92),
      elevation: 3,
      borderRadius: BorderRadius.circular(24),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            btn(
              icon: Icons.remove,
              tooltip: 'Zoom out',
              onPressed: cell <= minCell ? null : () => _step(ref, -1),
            ),
            btn(
              icon: Icons.add,
              tooltip: 'Zoom in',
              onPressed: cell >= maxCellPx ? null : () => _step(ref, 1),
            ),
            btn(
              icon: Icons.fit_screen_outlined,
              tooltip: 'Fit to view',
              onPressed: () => _fit(ref),
            ),
            Container(width: 1, height: 22, color: cs.outlineVariant),
            // Mirrors the AppBar pencil/pan toggle; highlighted when the draft is in pan mode.
            btn(
              icon: pencil ? Icons.pan_tool_outlined : Icons.draw,
              tooltip: pencil ? 'Pan the draft' : 'Draw on the draft',
              selected: !pencil,
              onPressed: () => ref.read(editorToolProvider.notifier).state =
                  pencil ? EditorTool.hand : EditorTool.pencil,
            ),
          ],
        ),
      ),
    );
  }
}
