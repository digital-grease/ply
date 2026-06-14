// The palette editor: a modal bottom sheet of swatch tiles (tap a tile to edit its RGB, the corner
// badge to remove it, "Add color" to append). It floats over the live drawdown so the cloth stays
// visible while editing. Opened from the DimensionsBar's "Colors N" chip.
//
// WIRING. setPaletteColor / addPaletteColor are PURE reducers (edit-in-place / append never shift a
// warp/weft index, so nothing dangles). REMOVE renumbers indices, so it routes through the engine
// (repo.removeColorDoc -> Draft::with_color_removed) and commits via commitEdit with the same
// serialize + latest-wins guard the DimensionsBar resize uses. The notifier stays FFI-free.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/draft_doc.dart';
import '../state/draft_editor_notifier.dart';
import '../state/editor_providers.dart';
import 'adaptive_sheet.dart';
import 'rgb_color_picker.dart';

/// Open the palette editor. Must be called from a context inside the editor's ProviderScope (the
/// DimensionsBar satisfies this) so the sheet's `ref` resolves the same providers. Adaptive: a
/// modal bottom sheet on phones, a centered dialog on tablet/wide screens.
Future<void> showPaletteSheet(BuildContext context) {
  return showAdaptiveSheet<void>(context, child: const PaletteSheet());
}

class PaletteSheet extends ConsumerStatefulWidget {
  const PaletteSheet({super.key});

  @override
  ConsumerState<PaletteSheet> createState() => _PaletteSheetState();
}

class _PaletteSheetState extends ConsumerState<PaletteSheet> {
  /// True while a remove is in flight (serializes a re-entrant remove tap across the FFI hop).
  bool _removing = false;

  /// A remove-failure message shown INLINE in the sheet (a root SnackBar would be occluded by the
  /// modal sheet pinned to the bottom). Null when there's nothing to report.
  String? _error;

  @override
  Widget build(BuildContext context) {
    // Watch the palette + the active brush so the sheet rebuilds live (colors added/edited/removed,
    // brush re-selected) and stays open across edits.
    final palette = ref.watch(draftEditorProvider.select((s) => s.draft.palette));
    final active = ref.watch(activePaletteColorProvider);
    final canRemove = palette.length > 1;
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      // Scrollable like the planning/structure sheets: a large palette (a WIF import can carry
      // dozens of colors) must scroll, not overflow — especially in the wide DIALOG path, where the
      // body is bounded to the screen height with no sheet drag to expand it.
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.viewInsetsOf(context).bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('Palette', style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                TextButton.icon(
                  onPressed: _add,
                  icon: const Icon(Icons.add),
                  label: const Text('Add color'),
                ),
              ],
            ),
            Text(
              'Tap to choose the brush color, long-press to edit.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 4),
                child: Text(_error!, style: TextStyle(color: cs.error)),
              ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (var i = 0; i < palette.length; i++)
                  _SwatchTile(
                    color: palette[i],
                    index: i,
                    canRemove: canRemove,
                    // Clamp so a transient dangling brush rings the last swatch, never nowhere.
                    selected: i == clampBrush(active, palette.length),
                    onTap: () => ref.read(activePaletteColorProvider.notifier).state = i,
                    onLongPress: () => _edit(i, palette[i]),
                    onRemove: () => _remove(i),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Tap a swatch -> edit its RGB via the picker -> commit as one undo entry (no-op if unchanged).
  Future<void> _edit(int idx, DraftColor current) async {
    if (_removing) return; // a remove is renumbering the palette; don't edit a soon-stale index
    final picked = await showRgbColorPicker(context, initial: current, title: 'Edit color');
    if (picked == null || !mounted) return;
    // Defense in depth: if the palette shrank while the picker was open (a remove resolving), [idx]
    // may now be out of range — re-validate against the LIVE palette before committing.
    if (idx >= ref.read(draftEditorProvider).draft.palette.length) return;
    ref.read(draftEditorProvider.notifier).setPaletteColor(idx, picked);
  }

  /// Add a color: open the picker (seeded mid-gray); on "Use color" append it as ONE undo entry. On
  /// Cancel, nothing is added (cleaner than appending a stray gray swatch first).
  Future<void> _add() async {
    if (_removing) return;
    final picked = await showRgbColorPicker(context,
        initial: const DraftColor(r: 128, g: 128, b: 128), title: 'Add color');
    if (picked == null || !mounted) return;
    ref.read(draftEditorProvider.notifier).addPaletteColor(picked);
  }

  /// Remove a color via the engine (safe remap), confirming first only when threads reference it.
  Future<void> _remove(int idx) async {
    if (_removing) return;
    final d = ref.read(draftEditorProvider).draft;
    if (d.palette.length <= 1) return; // belt; the engine is the suspenders
    setState(() {
      _removing = true;
      _error = null;
    });
    final repo = ref.read(repositoryProvider);
    final notifier = ref.read(draftEditorProvider.notifier);
    try {
      // The count is exactly the threads that will visibly recolor (the engine remaps e==idx -> 0;
      // e>idx merely renumber to the SAME color). Skip the dialog when nothing references it.
      final affected = d.warpColors.where((e) => e == idx).length +
          d.weftColors.where((e) => e == idx).length;
      if (affected > 0) {
        final proceed = await _confirmRemove(affected);
        if (proceed != true || !mounted) return;
      }
      final next = await repo.removeColorDoc(d, idx);
      // LATEST-WINS (mirrors DimensionsBar._resize): drop the result if an edit landed during the FFI
      // hop, so a stale remove can't stomp it.
      if (!mounted || !identical(ref.read(draftEditorProvider).draft, d)) return;
      notifier.commitEdit(next);
      // Keep the brush ringing the swatch it pointed at: the palette renumbered, so remap the brush
      // index by the SAME rule the engine used (off EditorState, so commitEdit can't touch it).
      final b = ref.read(activePaletteColorProvider);
      final nb = remapAfterRemove(b, idx);
      if (nb != b) ref.read(activePaletteColorProvider.notifier).state = nb;
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not remove the color: $e');
    } finally {
      if (mounted) setState(() => _removing = false);
    }
  }

  Future<bool?> _confirmRemove(int affected) {
    final use = affected == 1 ? 'thread uses' : 'threads use';
    final them = affected == 1 ? 'it' : 'them';
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove this color?'),
        content: Text(
          '$affected $use this color. Removing it recolors $them to the first color. '
          'You can undo this.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
        ],
      ),
    );
  }
}

class _SwatchTile extends StatelessWidget {
  const _SwatchTile({
    required this.color,
    required this.index,
    required this.canRemove,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
    required this.onRemove,
  });

  final DraftColor color;
  final int index; // 0-based
  final bool canRemove;
  final bool selected; // draws the active-brush ring
  final VoidCallback onTap; // select as the brush
  final VoidCallback onLongPress; // edit the RGB
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final fill = Color.fromARGB(255, color.r, color.g, color.b);
    // A readable label color over an ARBITRARY swatch: pick by the swatch's estimated brightness
    // (the framework's WCAG-aware crossover) rather than a hand-tuned luminance cut.
    final fg = ThemeData.estimateBrightnessForColor(fill) == Brightness.dark
        ? Colors.white
        : Colors.black;
    return Semantics(
      label: 'Color ${index + 1}${selected ? ', selected brush' : ''}: '
          'R ${color.r} G ${color.g} B ${color.b}',
      button: true,
      selected: selected,
      child: SizedBox(
        // The badge sits ENTIRELY inside this box (no negative Positioned / Clip.none), so its whole
        // tap target is hittable — a child painted outside the parent never receives pointers.
        width: 56,
        height: 56,
        child: Stack(
          children: [
            Positioned(
              left: 0,
              bottom: 0,
              child: InkWell(
                onTap: onTap,
                onLongPress: onLongPress,
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  width: 44,
                  height: 44,
                  alignment: Alignment.bottomRight,
                  decoration: BoxDecoration(
                    color: fill,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: selected ? colors.primary : colors.outlineVariant,
                      width: selected ? 2 : 1,
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(2),
                    child: Text('${index + 1}',
                        style: TextStyle(fontSize: 9, color: fg, fontWeight: FontWeight.w600)),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 0,
              right: 0,
              child: IconButton(
                visualDensity: VisualDensity.compact,
                iconSize: 16,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(width: 32, height: 32),
                tooltip: canRemove ? 'Remove color' : 'A draft needs at least one color',
                style: IconButton.styleFrom(
                  backgroundColor: colors.surfaceContainerHighest,
                  foregroundColor: colors.onSurfaceVariant,
                ),
                onPressed: canRemove ? onRemove : null,
                icon: const Icon(Icons.close),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
