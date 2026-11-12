// The BOOK VIEW: a separate presentation of the open draft's treadling (or liftplan) as a numbered
// list of rows, each row a run of consecutive picks that use the same shed, with its count, the
// picks it covers, and EVERY weft color in it. It never reshapes the editor: the structural draft
// grid stays one treadling row per pick, and this view is re-derived from those picks on every
// build (see treadling_entries.dart), so the two can never disagree.
//
// Honest scope: this groups runs of identical picks. It is NOT "Use Tabby" shorthand, which needs
// explicit pattern/tabby pick roles that Ply does not record yet (tabby picks interleave the pattern
// picks, so a generated overshot groups into one row per pick here). The header says so.
//
// Edits are kept only where each maps to explicit per-pick changes that the re-derived rows show
// back exactly: set a row's single treadle (all its picks), change its count (add or remove picks at
// the END of the row, an added pick copying the row's last pick, weft color included), or delete
// the row's picks. Each commits one undo entry on the editor.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/draft_doc.dart';
import '../models/treadling_entries.dart';
import '../state/draft_editor_notifier.dart';
import '../state/editor_providers.dart';
import 'adaptive_sheet.dart';

/// Open the Book view for the draft in the editor. Call from a context inside the editor's
/// ProviderScope (the editor overflow menu or the pinned dimensions-bar button). Adaptive: a bottom
/// sheet on phones, a centered dialog on tablet/wide screens.
Future<void> showBookViewSheet(BuildContext context) =>
    showAdaptiveSheet<void>(context, child: const BookViewSheet());

/// The user-visible title of the Book view (sheet heading, overflow item, and pinned button).
const String kBookViewTitle = 'Book view';

/// The Book view's statement of what it is and is not.
const String kBookViewExplainer =
    'Each row groups consecutive picks that use the same shed, with how many picks it covers.';
const String kBookViewNotTabby = 'This is not "Use Tabby" shorthand. Tabby picks between pattern '
    'picks stay as their own rows, because Ply does not yet record which picks are pattern and '
    'which are tabby.';
const String kBookViewKeepsPicks =
    'The draft keeps every pick. Edits here change those picks and can be undone in the editor.';

/// The most picks a single row may hold through the count stepper (matches the editor's Picks
/// stepper ceiling).
const int kBookViewMaxCount = 200;

/// "Treadle 3", "Treadles 1 + 3", "No treadle" (treadled), or the shaft wording for a liftplan.
String bookShedLabel(List<int> shed, {required bool treadled}) {
  final ids = [...shed]..sort();
  if (treadled) {
    if (ids.isEmpty) return 'No treadle';
    return ids.length == 1 ? 'Treadle ${ids.single}' : 'Treadles ${ids.join(' + ')}';
  }
  if (ids.isEmpty) return 'No shafts raised';
  return ids.length == 1 ? 'Shaft ${ids.single}' : 'Shafts ${ids.join(' + ')}';
}

/// "Pick 4" or "Picks 1 to 3" for the 0-based half-open range [start, end), shown 1-based.
String bookPickRangeLabel(int start, int end) =>
    end - start == 1 ? 'Pick ${start + 1}' : 'Picks ${start + 1} to $end';

/// "1 pick" / "3 picks".
String _picks(int n) => n == 1 ? '1 pick' : '$n picks';

/// A screen-reader description of [entry]'s weft colors in pick order, 1-based palette numbers to
/// match the editor's color bands: "weft color 2 for 2 picks, then color 1 for 1 pick".
String bookWeftDescription(TreadlingEntry entry, List<int> weftColors) {
  final runs = weftColorRuns(entry, weftColors);
  final parts = [
    for (var i = 0; i < runs.length; i++)
      '${i == 0 ? 'weft color' : 'then color'} ${runs[i].color + 1} for ${_picks(runs[i].count)}',
  ];
  return parts.join(', ');
}

/// The opaque swatch for palette entry [idx]; an out-of-range index is WHITE, exactly as the engine
/// drawdown and the editor's color bands draw it.
Color _swatch(List<DraftColor> palette, int idx) {
  if (idx < 0 || idx >= palette.length) return const Color(0xFFFFFFFF);
  final c = palette[idx];
  return Color.fromARGB(255, c.r, c.g, c.b);
}

class BookViewSheet extends ConsumerStatefulWidget {
  const BookViewSheet({super.key});

  @override
  ConsumerState<BookViewSheet> createState() => _BookViewSheetState();
}

class _BookViewSheetState extends ConsumerState<BookViewSheet> {
  /// The selected row, anchored by its FIRST pick rather than its index, so the selection follows
  /// the picks when an edit regroups the rows (a treadle change that joins the row above it, say).
  /// Null when no row is selected. Local view state only.
  int? _anchorPick;

  @override
  Widget build(BuildContext context) {
    final (rows, weftColors, palette, treadled, treadles) = ref.watch(draftEditorProvider.select((s) => (
          s.draft.drive.rows,
          s.draft.weftColors,
          s.draft.palette,
          s.draft.drive is DraftTreadled,
          s.draft.treadles,
        )));
    final pinned = ref.watch(overshotTreadlingProvider);
    final entries = treadlingEntries(rows);
    final anchor = _anchorPick;
    final selected = anchor == null ? null : entryIndexForPick(entries, anchor);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant);

    // Only the title and the summary stay fixed; the explanation, the pin switch, the rows, and the
    // selected row's controls (inline, right under that row) all scroll together, so nothing can
    // overflow a short phone screen however long the draft is.
    final header = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(kBookViewExplainer, style: muted),
        const SizedBox(height: 4),
        Text(kBookViewNotTabby, style: muted),
        const SizedBox(height: 4),
        Text(kBookViewKeepsPicks, style: muted),
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('Book view button in the editor'),
          subtitle: const Text('Saved with this draft. Generating an overshot turns it on.'),
          value: pinned,
          onChanged: (v) => ref.read(overshotTreadlingProvider.notifier).state = v,
        ),
        const Divider(height: 1),
        if (entries.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text('This draft has no picks yet.', style: muted),
          ),
      ],
    );

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(kBookViewTitle, style: theme.textTheme.titleLarge),
              const SizedBox(height: 4),
              Text(
                  '${_picks(rows.length)} in ${entries.length == 1 ? '1 row' : '${entries.length} rows'}',
                  style: theme.textTheme.titleSmall),
              const SizedBox(height: 4),
              Flexible(
                child: ListView.builder(
                  // A short list sizes the sheet to its content; a long one fills the sheet and
                  // scrolls lazily instead of laying out every row up front.
                  shrinkWrap: entries.length <= 50,
                  itemCount: entries.length + 1, // the header, then one item per row
                  itemBuilder: (context, item) {
                    if (item == 0) return header;
                    final i = item - 1;
                    final row = _BookRow(
                      index: i,
                      entry: entries[i],
                      weftColors: weftColors,
                      palette: palette,
                      treadled: treadled,
                      selected: i == selected,
                      onTap: () =>
                          setState(() => _anchorPick = i == selected ? null : entries[i].startPick),
                    );
                    if (i != selected) return row;
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        row,
                        _RowEditor(
                          index: i,
                          entry: entries[i],
                          treadled: treadled,
                          treadles: treadles,
                          onDeleted: () => setState(() => _anchorPick = null),
                        ),
                        const Divider(height: 1),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One Book view row: its number, shed, pick range, every weft color in pick order, and its count.
class _BookRow extends StatelessWidget {
  const _BookRow({
    required this.index,
    required this.entry,
    required this.weftColors,
    required this.palette,
    required this.treadled,
    required this.selected,
    required this.onTap,
  });

  final int index;
  final TreadlingEntry entry;
  final List<int> weftColors;
  final List<DraftColor> palette;
  final bool treadled;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final shed = bookShedLabel(entry.shed, treadled: treadled);
    final range = bookPickRangeLabel(entry.startPick, entry.endPick);
    final runs = weftColorRuns(entry, weftColors);
    final label = 'Row ${index + 1}: $shed, ${_picks(entry.count)}, '
        '${range.toLowerCase()}, ${bookWeftDescription(entry, weftColors)}';
    return Semantics(
      label: label,
      button: true,
      selected: selected,
      onTap: onTap,
      excludeSemantics: true,
      child: Material(
        color: selected ? cs.secondaryContainer : Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 36,
                  child: Text('${index + 1}', style: theme.textTheme.labelLarge),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(shed, style: theme.textTheme.titleSmall),
                      Text(range, style: theme.textTheme.bodySmall),
                      const SizedBox(height: 4),
                      // EVERY weft color in the run, in pick order: one swatch per stretch of one
                      // color, with its pick count when it covers more than one pick.
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text('Weft', style: theme.textTheme.bodySmall),
                          for (final r in runs)
                            Row(
                              key: ValueKey('weft-${entry.startPick}-${r.startPick}'),
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  width: 14,
                                  height: 14,
                                  decoration: BoxDecoration(
                                    color: _swatch(palette, r.color),
                                    borderRadius: BorderRadius.circular(2),
                                    border: Border.all(color: cs.outline),
                                  ),
                                ),
                                if (r.count > 1) ...[
                                  const SizedBox(width: 2),
                                  Text('×${r.count}', style: theme.textTheme.bodySmall),
                                ],
                              ],
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                Text('×${entry.count}', style: theme.textTheme.titleMedium),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The editing controls for the selected row. Every control is an explicit per-pick edit committed
/// as one undo entry through the editor notifier; the rows are re-derived from the picks afterwards.
class _RowEditor extends ConsumerWidget {
  const _RowEditor({
    required this.index,
    required this.entry,
    required this.treadled,
    required this.treadles,
    required this.onDeleted,
  });

  final int index;
  final TreadlingEntry entry;
  final bool treadled;
  final int treadles;
  final VoidCallback onDeleted;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final notifier = ref.read(draftEditorProvider.notifier);
    // The single-treadle stepper only applies to a row pressing at most one treadle; a multi-treadle
    // row is edited cell by cell on the draft grid (stepping it would silently drop treadles).
    final single = treadled && entry.shed.length <= 1;
    final treadle = entry.shed.isEmpty ? 0 : entry.shed.first;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Editing row ${index + 1}, ${bookPickRangeLabel(entry.startPick, entry.endPick).toLowerCase()}',
              style: theme.textTheme.titleSmall),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            children: [
              if (single)
                _BookStepper(
                  label: 'Treadle',
                  value: treadle == 0 ? 'none' : '$treadle',
                  decTooltip: 'Previous treadle',
                  incTooltip: 'Next treadle',
                  // Treadle 0 is "none": stepping down from treadle 1 clears the row's shed.
                  onDec: treadle > 0
                      ? () => notifier.setEntryShed(
                          index, treadle == 1 ? const <int>[] : <int>[treadle - 1])
                      : null,
                  onInc: treadle < treadles
                      ? () => notifier.setEntryShed(index, <int>[treadle + 1])
                      : null,
                ),
              _BookStepper(
                label: 'Count',
                value: '${entry.count}',
                decTooltip: 'Fewer picks in this row',
                incTooltip: 'More picks in this row',
                onDec: entry.count > 1 ? () => notifier.setEntryCount(index, entry.count - 1) : null,
                onInc: entry.count < kBookViewMaxCount
                    ? () => notifier.setEntryCount(index, entry.count + 1)
                    : null,
              ),
              TextButton.icon(
                onPressed: () {
                  notifier.removeEntry(index);
                  onDeleted();
                },
                icon: const Icon(Icons.delete_outline),
                label: const Text('Delete these picks'),
              ),
            ],
          ),
          if (treadled && !single)
            Text('This row presses more than one treadle. Change its treadles on the draft grid.',
                style: muted),
          Text(
              "Count adds or removes picks at the end of this row. An added pick copies the row's "
              'last pick, weft color included.',
              style: muted),
        ],
      ),
    );
  }
}

class _BookStepper extends StatelessWidget {
  const _BookStepper({
    required this.label,
    required this.value,
    required this.decTooltip,
    required this.incTooltip,
    required this.onDec,
    required this.onInc,
  });

  final String label;
  final String value;
  final String decTooltip;
  final String incTooltip;
  final VoidCallback? onDec;
  final VoidCallback? onInc;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          visualDensity: VisualDensity.compact,
          iconSize: 20,
          tooltip: decTooltip,
          onPressed: onDec,
          icon: const Icon(Icons.remove),
        ),
        Text('$label $value', style: Theme.of(context).textTheme.labelLarge),
        IconButton(
          visualDensity: VisualDensity.compact,
          iconSize: 20,
          tooltip: incTooltip,
          onPressed: onInc,
          icon: const Icon(Icons.add),
        ),
      ],
    );
  }
}
