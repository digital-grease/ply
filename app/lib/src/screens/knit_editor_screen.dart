import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/draft_doc.dart' show DraftColor;
import '../models/draft_meta.dart';
import '../models/knit_stitches.dart';
import '../rust/dto.dart' show ColorDto, SeverityKind;
import '../rust/knit_dto.dart' show KnitIssueDto, KnitPatternDto;
import '../state/knit_editor_providers.dart';
import '../state/knit_editor_state.dart';
import '../theme/ply_colors.dart';
import '../widgets/cable_builder_dialog.dart';
import '../widgets/knit_chart_view.dart';
import '../widgets/knit_legend_sheet.dart';
import '../widgets/knit_planning_sheet.dart';
import '../widgets/knit_settings_sheet.dart';
import '../widgets/name_input_dialog.dart';
import '../widgets/rgb_color_picker.dart';
import 'knit_written_screen.dart';

/// The knit editor's overflow-menu actions.
enum _EditorMenu { zoomIn, zoomOut, written, legend, planning, settings }

/// The knitting chart editor (M5): paint a chart of stitch symbols, resize the grid, undo/redo, see
/// live stitch-count validation, and save to the on-device knit library. The knit analog of the
/// weaving `EditorScreen`; the gauge/yardage panel and cable placement layer on next.
class KnitEditorScreen extends ConsumerStatefulWidget {
  const KnitEditorScreen({this.openId, this.initialPattern, super.key});

  /// When non-null, open this SAVED pattern (by id) instead of a fresh blank starter.
  final String? openId;

  /// When non-null (and [openId] is null), start editing this freshly-built pattern (from the New
  /// pattern setup screen) instead of the default blank 8x8.
  final KnitPatternDto? initialPattern;

  @override
  ConsumerState<KnitEditorScreen> createState() => _KnitEditorScreenState();
}

class _KnitEditorScreenState extends ConsumerState<KnitEditorScreen> {
  bool _loading = true;
  String? _error;
  String? _id; // the saved pattern id; null until the first save
  String _name = 'Knitting pattern';
  DateTime? _savedAt;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final repo = ref.read(knitRepositoryProvider);
      if (widget.openId != null) {
        // Open a saved pattern: read its chart + bump lastOpened.
        final pattern = await repo.readPattern(widget.openId!);
        final entry = await repo.openKnit(widget.openId!);
        if (!mounted) return;
        _id = entry.id;
        _name = entry.meta.name;
        _savedAt = entry.meta.savedAt;
        ref.read(knitEditorProvider.notifier).load(pattern);
      } else if (widget.initialPattern != null) {
        // Built by the New pattern setup screen (size / gauge / construction / starting stitch).
        ref.read(knitEditorProvider.notifier).load(widget.initialPattern!);
      } else {
        // A fresh pattern: the engine blank carries the builtin legend; start it as an 8x8 grid on a
        // clean state so the starter has no undo history.
        final blank = await repo.blank();
        if (!mounted) return;
        final starter = KnitEditorState(pattern: blank).resizeChart(8, 8).pattern;
        ref.read(knitEditorProvider.notifier).load(starter);
      }
      setState(() => _loading = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not open the knitting pattern: $e';
        _loading = false;
      });
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// Step the chart zoom by [delta] pixels-per-cell, clamped to the editor's bounds.
  void _zoom(int delta) {
    final z = ref.read(knitZoomProvider);
    final next = (z + delta).clamp(kKnitZoomMin, kKnitZoomMax);
    if (next != z) ref.read(knitZoomProvider.notifier).state = next;
  }

  Future<void> _save() async {
    if (_saving) return;
    final pattern = ref.read(knitEditorProvider).pattern;
    if (pattern.chart.width == 0 || pattern.chart.rows.isEmpty) {
      _snack('Add some rows and stitches before saving.');
      return;
    }
    var name = _name;
    if (_id == null) {
      final entered = await promptForName(
        context,
        title: 'Name this pattern',
        confirmLabel: 'Save',
        initial: name,
        fieldLabel: 'Pattern name',
      );
      if (entered == null) return; // cancelled or left blank
      name = entered;
    }
    if (!mounted) return; // the name dialog is an async gap
    setState(() => _saving = true);
    try {
      final repo = ref.read(knitRepositoryProvider);
      final now = DateTime.now();
      final meta = DraftMeta(name: name, craft: 'Knitting', savedAt: _savedAt ?? now, lastOpened: now);
      final id = await repo.saveKnit(pattern: pattern, meta: meta, id: _id);
      if (!mounted) return;
      setState(() {
        _id = id;
        _name = name;
        _savedAt ??= now;
        _saving = false;
      });
      _snack('Saved to your knit patterns.');
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _snack('Could not save: $e');
    }
  }

  /// Fill the current selection with the active stitch + color (one undo entry), then clear it. A cable
  /// brush spans columns and can't fill a region, so it is blocked with a hint instead of a silent
  /// no-op.
  void _fillSelection() {
    final sel = ref.read(knitSelectionProvider);
    if (sel == null) return;
    final stitch = ref.read(activeKnitStitchProvider);
    final legend = ref.read(knitEditorProvider).pattern.legend.stitches;
    final isCable = stitch >= 0 && stitch < legend.length && legend[stitch].cable != null;
    if (isCable) {
      _snack('Cables span columns and can’t fill a region — pick a single stitch.');
      return;
    }
    final brush = ref.read(activeKnitColorProvider);
    ref.read(knitEditorProvider.notifier).fillRegion(
          sel.rowMin,
          sel.colMin,
          sel.rowMax,
          sel.colMax,
          stitch,
          brush >= 0 ? brush : null,
          keepColor: brush == knitColorKeep,
        );
    ref.read(knitSelectionProvider.notifier).state = null; // clear after filling
  }

  @override
  Widget build(BuildContext context) {
    final canUndo = ref.watch(knitEditorProvider.select((s) => s.canUndo));
    final canRedo = ref.watch(knitEditorProvider.select((s) => s.canRedo));
    final select = ref.watch(knitToolProvider) == KnitTool.select;
    final selection = ref.watch(knitSelectionProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(_name),
        actions: [
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: select ? 'Selecting (tap to draw)' : 'Drawing (tap to select)',
            isSelected: select,
            icon: Icon(select ? Icons.select_all : Icons.edit_outlined),
            onPressed: () {
              final next = select ? KnitTool.paint : KnitTool.select;
              ref.read(knitToolProvider.notifier).state = next;
              if (next == KnitTool.paint) ref.read(knitSelectionProvider.notifier).state = null;
            },
          ),
          if (select && selection != null)
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: 'Fill selection',
              icon: const Icon(Icons.format_color_fill),
              onPressed: _fillSelection,
            ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: 'Save',
            icon: _saving
                ? const SizedBox(
                    width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.save_outlined),
            onPressed: _saving ? null : _save,
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: 'Undo',
            icon: const Icon(Icons.undo),
            onPressed: canUndo ? () => ref.read(knitEditorProvider.notifier).undo() : null,
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: 'Redo',
            icon: const Icon(Icons.redo),
            onPressed: canRedo ? () => ref.read(knitEditorProvider.notifier).redo() : null,
          ),
          PopupMenuButton<_EditorMenu>(
            tooltip: 'More',
            onSelected: (m) => switch (m) {
              _EditorMenu.zoomIn => _zoom(kKnitZoomStep),
              _EditorMenu.zoomOut => _zoom(-kKnitZoomStep),
              _EditorMenu.written => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const KnitWrittenScreen()),
                ),
              _EditorMenu.legend => showKnitLegendSheet(context),
              _EditorMenu.planning => showKnitPlanningSheet(context),
              _EditorMenu.settings => showKnitSettingsSheet(context),
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: _EditorMenu.zoomIn,
                child: ListTile(
                  leading: Icon(Icons.zoom_in),
                  title: Text('Zoom in'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: _EditorMenu.zoomOut,
                child: ListTile(
                  leading: Icon(Icons.zoom_out),
                  title: Text('Zoom out'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuDivider(),
              PopupMenuItem(
                value: _EditorMenu.written,
                child: ListTile(
                  leading: Icon(Icons.format_list_numbered),
                  title: Text('Written instructions'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: _EditorMenu.legend,
                child: ListTile(
                  leading: Icon(Icons.menu_book_outlined),
                  title: Text('Stitch key'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: _EditorMenu.planning,
                child: ListTile(
                  leading: Icon(Icons.calculate_outlined),
                  title: Text('Gauge & yardage'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: _EditorMenu.settings,
                child: ListTile(
                  leading: Icon(Icons.tune),
                  title: Text('Pattern settings'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(padding: const EdgeInsets.all(32), child: Text(_error!, textAlign: TextAlign.center)),
      );
    }
    return const Column(
      children: [
        Expanded(child: KnitChartView()),
        _KnitValidationBar(),
        Divider(height: 1),
        _KnitToolBar(),
      ],
    );
  }
}

/// The inline validation band: full stitch-count balancing + structural issues. ZERO CHROME WHEN
/// CLEAN. Collapsed to a one-line summary (worst severity drives the tone); tap to expand a bounded,
/// scrollable list with Errors sorted first. Severity-coded (Errors red, Warnings amber).
class _KnitValidationBar extends ConsumerWidget {
  const _KnitValidationBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final issues = ref.watch(knitValidationProvider).valueOrNull ?? const <KnitIssueDto>[];
    if (issues.isEmpty) return const SizedBox.shrink();

    final colors = Theme.of(context).colorScheme;
    final warning = Theme.of(context).extension<PlyColors>()?.warning ?? const Color(0xFFB26A00);
    final errors = issues.where((i) => i.severity == SeverityKind.error).length;
    final warnings = issues.length - errors;
    final hasError = errors > 0;
    final tone = hasError ? colors.error : warning;
    final bg = hasError ? colors.errorContainer : warning.withValues(alpha: 0.12);
    final headerIcon = hasError ? Icons.error_outline : Icons.warning_amber_rounded;
    final expanded = ref.watch(knitIssuesExpandedProvider);

    // Errors first, then warnings, preserving the engine's order within each group.
    final sorted = [
      ...issues.where((i) => i.severity == SeverityKind.error),
      ...issues.where((i) => i.severity != SeverityKind.error),
    ];

    return Material(
      elevation: 1,
      color: bg,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            liveRegion: true,
            button: true,
            label: _summary(errors, warnings),
            child: InkWell(
              onTap: () =>
                  ref.read(knitIssuesExpandedProvider.notifier).state = !expanded,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    Icon(headerIcon, size: 20, color: tone),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        issues.length == 1 ? issues.first.message : _summary(errors, warnings),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                    Icon(expanded ? Icons.expand_less : Icons.expand_more, size: 20, color: tone),
                  ],
                ),
              ),
            ),
          ),
          if (expanded)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 160),
              child: ListView.separated(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                itemCount: sorted.length,
                separatorBuilder: (_, __) => const SizedBox(height: 4),
                itemBuilder: (_, i) {
                  final issue = sorted[i];
                  final isErr = issue.severity == SeverityKind.error;
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(isErr ? Icons.error_outline : Icons.warning_amber_rounded,
                          size: 16, color: isErr ? colors.error : warning),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(issue.message, style: Theme.of(context).textTheme.bodySmall),
                      ),
                    ],
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  static String _summary(int errors, int warnings) {
    final parts = <String>[];
    if (errors > 0) parts.add('$errors ${errors == 1 ? 'error' : 'errors'}');
    if (warnings > 0) parts.add('$warnings ${warnings == 1 ? 'warning' : 'warnings'}');
    return parts.isEmpty ? 'No issues' : parts.join(', ');
  }
}

/// The bottom tool bar: rows/cols steppers + the stitch brush picker.
class _KnitToolBar extends ConsumerWidget {
  const _KnitToolBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dims = ref.watch(knitEditorProvider
        .select((s) => (s.pattern.chart.width, s.pattern.chart.rows.length)));
    final active = ref.watch(activeKnitStitchProvider);
    // Watch the legend so custom cable brushes appear/select live. The legend object identity only
    // changes when a cable is added (other edits reuse it), so this rebuilds rarely.
    final legend = ref.watch(knitEditorProvider.select((s) => s.pattern.legend));
    final cols = dims.$1;
    final rows = dims.$2;
    final notifier = ref.read(knitEditorProvider.notifier);

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _Stepper(label: 'Sts', value: cols, onChanged: (v) => notifier.resizeChart(v, rows)),
                const SizedBox(width: 16),
                _Stepper(label: 'Rows', value: rows, onChanged: (v) => notifier.resizeChart(cols, v)),
              ],
            ),
            const SizedBox(height: 6),
            SizedBox(
              height: 40,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  for (final b in kKnitBrushes)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        label: Text(b.symbol),
                        tooltip: b.label,
                        selected: active == b.id,
                        onSelected: (_) =>
                            ref.read(activeKnitStitchProvider.notifier).state = b.id,
                      ),
                    ),
                  // Custom cable brushes (legend entries carrying a CableDefDto).
                  for (var i = 0; i < legend.stitches.length; i++)
                    if (legend.stitches[i].cable != null)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ChoiceChip(
                          avatar: const Icon(Icons.swap_calls, size: 16),
                          label: Text(legend.stitches[i].symbol),
                          tooltip: 'Cable ${legend.stitches[i].symbol}',
                          selected: active == i,
                          onSelected: (_) =>
                              ref.read(activeKnitStitchProvider.notifier).state = i,
                        ),
                      ),
                  // "+ cable" — define a new custom cable, which becomes the active brush.
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ActionChip(
                      avatar: const Icon(Icons.add, size: 16),
                      label: const Text('Cable'),
                      onPressed: () => _addCable(context, ref),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            const _KnitColorRow(),
          ],
        ),
      ),
    );
  }

  /// Open the cable builder; on confirm, add the cable to the legend and make it the active brush so
  /// the next chart tap places it.
  Future<void> _addCable(BuildContext context, WidgetRef ref) async {
    final cable = await showCableBuilder(context);
    if (cable == null || !context.mounted) return;
    final id = ref.read(knitEditorProvider.notifier).addCable(cable, cableSymbol(cable));
    ref.read(activeKnitStitchProvider.notifier).state = id;
  }
}

/// The colorwork palette row: select the active brush color (or "symbol only"), long-press a swatch
/// to edit its RGB, "+" to add a color. Painting then applies the active stitch AND this color.
class _KnitColorRow extends ConsumerWidget {
  const _KnitColorRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = ref.watch(knitEditorProvider.select((s) => s.pattern.palette));
    final active = ref.watch(activeKnitColorProvider);
    final notifier = ref.read(knitEditorProvider.notifier);
    final cs = Theme.of(context).colorScheme;

    return SizedBox(
      height: 34,
      child: Row(
        children: [
          // A leading label so the colorwork palette is DISCOVERABLE: without it the row reads as a
          // lone white square + plus (owner feedback 2026-06-15 — "didn't realize it was there").
          // "Colors" mirrors the weave editor's color affordance; the tooltip explains colorwork.
          Tooltip(
            message: 'Yarn colors for colorwork: pick one, then paint cells. "Keep" adds a symbol '
                'without changing a cell\'s color; "No color" clears it.',
            child: Padding(
              padding: const EdgeInsets.only(right: 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.palette_outlined, size: 18, color: cs.onSurfaceVariant),
                  const SizedBox(width: 4),
                  Text('Colors', style: Theme.of(context).textTheme.labelMedium),
                ],
              ),
            ),
          ),
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                // "Keep" — paint the stitch symbol but leave the cell's existing color untouched
                // (so a symbol can be added over a colored square). The default brush.
                _Swatch(
                  selected: active == knitColorKeep,
                  tooltip: 'Keep color (add a symbol without changing the cell color)',
                  onTap: () => ref.read(activeKnitColorProvider.notifier).state = knitColorKeep,
                  child: Icon(Icons.edit_outlined, size: 16, color: cs.onSurfaceVariant),
                ),
                // "No color" — clear a cell's colorwork (a symbol-only cell).
                _Swatch(
                  selected: active == knitColorNone,
                  tooltip: 'No color (clear the cell colorwork)',
                  onTap: () => ref.read(activeKnitColorProvider.notifier).state = knitColorNone,
                  child: Icon(Icons.format_color_reset_outlined,
                      size: 16, color: cs.onSurfaceVariant),
                ),
                for (var i = 0; i < palette.length; i++)
                  _Swatch(
                    selected: active == i,
                    fill: Color.fromARGB(255, palette[i].r, palette[i].g, palette[i].b),
                    tooltip: 'Color ${i + 1} (long-press to edit)',
                    onTap: () => ref.read(activeKnitColorProvider.notifier).state = i,
                    onLongPress: () async {
                      final c = palette[i];
                      final picked = await showRgbColorPicker(context,
                          initial: DraftColor(r: c.r, g: c.g, b: c.b), title: 'Edit color');
                      if (picked != null) {
                        notifier.setPaletteColor(i, ColorDto(r: picked.r, g: picked.g, b: picked.b));
                      }
                    },
                  ),
                _Swatch(
                  tooltip: 'Add color',
                  onTap: () async {
                    final picked = await showRgbColorPicker(context,
                        initial: const DraftColor(r: 128, g: 128, b: 128), title: 'Add color');
                    if (picked != null) {
                      notifier.addPaletteColor(ColorDto(r: picked.r, g: picked.g, b: picked.b));
                    }
                  },
                  child: Icon(Icons.add, size: 16, color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A tappable palette swatch: a filled square (or an icon affordance), ringed when selected.
class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.onTap,
    this.onLongPress,
    this.fill,
    this.child,
    this.selected = false,
    required this.tooltip,
  });

  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final Color? fill;
  final Widget? child;
  final bool selected;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Tooltip(
        message: tooltip,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          borderRadius: BorderRadius.circular(6),
          child: Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: fill ?? cs.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: selected ? cs.primary : cs.outlineVariant,
                width: selected ? 2 : 1,
              ),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// A compact -/value/+ stepper, clamped at 0 (and a sane upper bound).
class _Stepper extends StatelessWidget {
  const _Stepper({required this.label, required this.value, required this.onChanged});
  final String label;
  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$label ', style: Theme.of(context).textTheme.labelLarge),
        IconButton(
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.remove_circle_outline),
          tooltip: 'Fewer $label',
          onPressed: value > 0 ? () => onChanged(value - 1) : null,
        ),
        Text('$value', style: Theme.of(context).textTheme.titleMedium),
        IconButton(
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.add_circle_outline),
          tooltip: 'More $label',
          onPressed: value < 200 ? () => onChanged(value + 1) : null,
        ),
      ],
    );
  }
}
