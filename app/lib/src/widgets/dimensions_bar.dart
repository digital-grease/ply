// A bottom bar of dimension steppers (ends / picks / shafts / treadles). Each +/- resizes the
// draft through the engine (prune stale refs on shrink, pad blanks on grow) and commits the result
// as ONE undo entry. Always visible (even on a blank draft) so a from-scratch draft can be grown
// to a size the integrated grids can edit.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/glossary_lookup.dart';
import '../models/double_weave_layers.dart';
import '../models/draft_doc.dart';
import '../models/treadling_entries.dart';
import '../screens/layer_inspector_screen.dart';
import '../state/draft_editor_notifier.dart';
import '../state/editor_providers.dart';
import 'editor_view_controls.dart';
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

  /// Append a new blank treadling row (one pick, no shed) and select it, so its count stepper is
  /// ready and a tap on the new row sets its shed.
  void _addRow() {
    final notifier = ref.read(draftEditorProvider.notifier);
    notifier.addEntry();
    // Add Row is overshot-only, so the rows collapse into runs; select the new (last) run.
    final n = treadlingEntries(ref.read(draftEditorProvider).draft.drive.rows, collapse: true).length;
    ref.read(selectedTreadlingEntryProvider.notifier).state = n - 1;
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
    // The per-row treadle / count / add / delete controls are OVERSHOT-only (the collapsed "book"
    // treadling); a non-overshot draft edits the treadling per-pick on the grid, so they stay hidden.
    final overshot = ref.watch(overshotTreadlingProvider);
    // Compressed-treadling rows (runs of identical picks). The selected row's count is editable; a
    // selection past the live row count (a run that merged away) reads as "no selection".
    final entries =
        treadlingEntries(ref.watch(draftEditorProvider.select((s) => s.draft.drive.rows)), collapse: overshot);
    final selectedRaw = ref.watch(selectedTreadlingEntryProvider);
    final selectedEntry =
        (selectedRaw != null && selectedRaw >= 0 && selectedRaw < entries.length) ? selectedRaw : null;
    // The selected run's single treadle for the per-row 'Treadle' stepper. 0 means a blank shed OR a
    // multi-treadle shed (which the grid edits cell-by-cell); stepping from 0 sets a single treadle.
    final selectedShed = selectedEntry != null ? entries[selectedEntry].shed : const <int>[];
    final selectedTreadle = selectedShed.length == 1 ? selectedShed.single : 0;
    // Whether to surface the double-weave layer view (4+ shafts used). Watched directly so the chip
    // appears/disappears as the draft changes — and it reads the threading's real shaft usage, not
    // just the header, so a generated/composed double weave reliably offers it.
    final canLayers = ref.watch(draftEditorProvider.select((s) => supportsLayerView(s.draft)));
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
    // A non-scrolling, CENTERED WRAP so every control is reachable without a sideways scroll: the
    // dimension steppers come FIRST (the primary controls), then the tool chips, flowing onto as many
    // rows as the width needs. Paired with the editor body letting the cloth shrink, this panel sits
    // in the space that used to be empty under the drawdown.
    return Material(
      elevation: 2,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Wrap(
            alignment: WrapAlignment.center,
            spacing: 4,
            runSpacing: 4,
            children: [
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
              // Compressed (overshot) treadling: tapping a row selects it and reveals its controls —
              // step its pick count ("throw this shed N times"), add a new row, or delete it. Shown only
              // for an OVERSHOT draft with a row selected, so the overshot row machinery never appears on
              // a plain/twill/satin draft (which edits its treadling per-pick on the grid instead).
              if (isTreadled && overshot && selectedEntry != null) ...[
                // Set which treadle the selected run presses, by hand — step it through 1..treadles
                // (0 clears it). The fix for overshot, where you set each block's treadle directly
                // instead of hunting the right grid cell. Re-anchors the selection if the edit merges
                // this run into an identical neighbour.
                _Stepper(
                  label: 'Treadle',
                  value: selectedTreadle,
                  min: 0,
                  max: treadles,
                  enabled: enabled,
                  onChange: (v) {
                    final notifier = ref.read(draftEditorProvider.notifier);
                    final startPick = entries[selectedEntry].startPick;
                    notifier.setEntryShed(selectedEntry, v == 0 ? const <int>[] : <int>[v]);
                    final newEntries =
                        treadlingEntries(ref.read(draftEditorProvider).draft.drive.rows);
                    ref.read(selectedTreadlingEntryProvider.notifier).state =
                        entryIndexForPick(newEntries, startPick);
                  },
                ),
                _Stepper(
                  label: 'Row ×',
                  value: entries[selectedEntry].count,
                  min: 1,
                  max: _maxDim,
                  enabled: enabled,
                  onChange: (v) =>
                      ref.read(draftEditorProvider.notifier).setEntryCount(selectedEntry, v),
                ),
                ActionChip(
                  avatar: const Icon(Icons.add, size: 18),
                  label: const Text('Row'),
                  onPressed: enabled ? _addRow : null,
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  iconSize: 20,
                  tooltip: 'Delete row',
                  onPressed: enabled
                      ? () {
                          ref.read(draftEditorProvider.notifier).removeEntry(selectedEntry);
                          ref.read(selectedTreadlingEntryProvider.notifier).state = null;
                        }
                      : null,
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
              // Tool chips: the palette editor (the leading dot is the active brush color), the
              // planning calculator, and the structure generator.
              ActionChip(
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
              ActionChip(
                avatar: const Icon(Icons.calculate_outlined, size: 18),
                label: const Text('Calculator'),
                onPressed: () => showPlanningSheet(context),
              ),
              ActionChip(
                avatar: const Icon(Icons.grid_4x4, size: 18),
                label: const Text('Structure'),
                onPressed: () => showStructureSheet(context),
              ),
              // Double-weave only: a VISIBLE entry to the layer inspector (Combined/Front/Back), so
              // switching layers doesn't require hunting the AppBar overflow.
              if (canLayers)
                ActionChip(
                  avatar: const Icon(Icons.layers_outlined, size: 18),
                  label: const Text('Layers'),
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) =>
                        LayerInspectorScreen(draft: ref.read(draftEditorProvider).draft),
                  )),
                ),
              // Zoom / fit / pan controls live here, off the cloth, so they no longer overlap editable
              // cells (the cloth itself now pans/zooms by direct gesture).
              const EditorViewControls(),
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

  /// The glossary headword each plural stepper label teaches (the source is singular: "Ends" ->
  /// "End"). Used to pull the tooltip help text from [glossaryDefinition].
  static const Map<String, String> _concept = {
    'Ends': 'End',
    'Picks': 'Pick',
    'Shafts': 'Shaft',
    'Treadles': 'Treadle',
  };

  @override
  Widget build(BuildContext context) {
    final concept = _concept[label] ?? label;
    final def = glossaryDefinition(concept);
    // The numeric label doubles as a concept tooltip: long-press (or hover) shows the glossary
    // definition, sourced from docs/GLOSSARY.md. Falls back to a bare label if the term is absent.
    final Widget labelText =
        Text('$label $value', style: Theme.of(context).textTheme.labelLarge);
    // No self-padding: the parent Wrap spaces the steppers. mainAxisSize.min keeps each stepper as
    // tight as its content so the Wrap packs as many per row as fit.
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          visualDensity: VisualDensity.compact,
          iconSize: 20,
          tooltip: 'Fewer $label',
          onPressed: enabled && value > min ? () => onChange(value - 1) : null,
          icon: const Icon(Icons.remove),
        ),
        if (def == null)
          labelText
        else
          Tooltip(message: '$concept: $def', triggerMode: TooltipTriggerMode.tap, child: labelText),
        IconButton(
          visualDensity: VisualDensity.compact,
          iconSize: 20,
          tooltip: 'More $label',
          onPressed: enabled && value < max ? () => onChange(value + 1) : null,
          icon: const Icon(Icons.add),
        ),
      ],
    );
  }
}
