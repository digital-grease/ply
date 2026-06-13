// A bottom bar of dimension steppers (ends / picks / shafts / treadles). Each +/- resizes the
// draft through the engine (prune stale refs on shrink, pad blanks on grow) and commits the result
// as ONE undo entry. Always visible (even on a blank draft) so a from-scratch draft can be grown
// to a size the integrated grids can edit.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/draft_doc.dart';
import '../state/draft_editor_notifier.dart';
import '../state/editor_providers.dart';
import 'palette_sheet.dart';
import 'planning_sheet.dart';
import 'structure_sheet.dart';

class DimensionsBar extends ConsumerStatefulWidget {
  const DimensionsBar({super.key});

  @override
  ConsumerState<DimensionsBar> createState() => _DimensionsBarState();
}

class _DimensionsBarState extends ConsumerState<DimensionsBar> {
  /// A sane ceiling for the steppers (a hand loom never approaches this).
  static const int _maxDim = 200;

  /// True while a resize is in flight. Serializes resizes (a second stepper tap is ignored until
  /// the first commits), so two fast taps can't both read the same pre-resize draft and lose one
  /// axis's update across the async FFI hop.
  bool _resizing = false;

  Future<void> _resize({int? ends, int? picks, int? shafts, int? treadles}) async {
    if (_resizing) return;
    setState(() => _resizing = true);
    try {
      final repo = ref.read(repositoryProvider);
      final d = ref.read(draftEditorProvider).draft;
      final next = await repo.resizeDoc(
        d,
        ends: ends ?? d.ends,
        picks: picks ?? d.picks,
        shafts: shafts ?? d.shafts,
        treadles: treadles ?? d.treadles,
      );
      // LATEST-WINS. `_resizing` only disables the steppers; the AppBar undo/redo and the paint
      // Listener stay live during this FFI hop. If an edit landed, `d` is stale -- committing the
      // resize derived from it would overwrite that edit and wipe redo. Drop it (`identical` is
      // sound: DraftDoc is immutable and the notifier only swaps whole instances).
      if (!mounted || !identical(ref.read(draftEditorProvider).draft, d)) return;
      ref.read(draftEditorProvider.notifier).commitEdit(next);
    } finally {
      if (mounted) setState(() => _resizing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final (ends, picks, shafts, treadles, isTreadled) =
        ref.watch(draftEditorProvider.select((s) => (
              s.draft.ends,
              s.draft.picks,
              s.draft.shafts,
              s.draft.treadles,
              s.draft.drive is DraftTreadled,
            )));
    final palette = ref.watch(draftEditorProvider.select((s) => s.draft.palette));
    final active = ref.watch(activePaletteColorProvider);
    final cs = Theme.of(context).colorScheme;
    // The chip's leading dot is the active BRUSH color, so the chosen color is visible without
    // opening the sheet.
    final brushColor = palette.isEmpty
        ? cs.surfaceContainerHighest
        : () {
            final c = palette[clampBrush(active, palette.length)];
            return Color.fromARGB(255, c.r, c.g, c.b);
          }();
    final enabled = !_resizing;
    return Material(
      elevation: 2,
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              // Opens the palette editor sheet; the leading dot is the active brush color. Leads the
              // dimension steppers; the row already scrolls horizontally, so it never overflows.
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: ActionChip(
                  avatar: Container(
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(
                      color: brushColor,
                      shape: BoxShape.circle,
                      border: Border.all(color: cs.outlineVariant),
                    ),
                  ),
                  label: Text('Colors ${palette.length}'),
                  onPressed: () => showPaletteSheet(context),
                ),
              ),
              // Opens the planning calculator (sett + warp-yarn estimate). A sibling of the Colors
              // chip; the row scrolls so it never overflows.
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: ActionChip(
                  avatar: const Icon(Icons.calculate_outlined, size: 18),
                  label: const Text('Calculator'),
                  onPressed: () => showPlanningSheet(context),
                ),
              ),
              // Generate a plain/twill/satin structure into the draft (one undo entry).
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: ActionChip(
                  avatar: const Icon(Icons.grid_4x4, size: 18),
                  label: const Text('Structure'),
                  onPressed: () => showStructureSheet(context),
                ),
              ),
              _Stepper(
                  label: 'Ends',
                  value: ends,
                  min: 0,
                  max: _maxDim,
                  enabled: enabled,
                  onChange: (v) => _resize(ends: v)),
              _Stepper(
                  label: 'Picks',
                  value: picks,
                  min: 0,
                  max: _maxDim,
                  enabled: enabled,
                  onChange: (v) => _resize(picks: v)),
              _Stepper(
                  label: 'Shafts',
                  value: shafts,
                  min: 1,
                  max: _maxDim,
                  enabled: enabled,
                  onChange: (v) => _resize(shafts: v)),
              // A liftplan has no treadle axis (treadles==0, ignored by the engine), so the stepper
              // would be a meaningless dead control: hide it. Pairs with the convert action going
              // unavailable in the same frame.
              if (isTreadled)
                _Stepper(
                    label: 'Treadles',
                    value: treadles,
                    min: 0,
                    max: _maxDim,
                    enabled: enabled,
                    onChange: (v) => _resize(treadles: v)),
            ],
          ),
        ),
      ),
    );
  }
}

class _Stepper extends StatelessWidget {
  const _Stepper({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.enabled,
    required this.onChange,
  });

  final String label;
  final int value;
  final int min;
  final int max;
  final bool enabled;
  final void Function(int) onChange;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            visualDensity: VisualDensity.compact,
            iconSize: 20,
            tooltip: 'Fewer $label',
            onPressed: enabled && value > min ? () => onChange(value - 1) : null,
            icon: const Icon(Icons.remove),
          ),
          Text('$label $value', style: Theme.of(context).textTheme.labelLarge),
          IconButton(
            visualDensity: VisualDensity.compact,
            iconSize: 20,
            tooltip: 'More $label',
            onPressed: enabled && value < max ? () => onChange(value + 1) : null,
            icon: const Icon(Icons.add),
          ),
        ],
      ),
    );
  }
}
