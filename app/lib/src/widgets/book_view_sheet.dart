// The BOOK VIEW: a separate presentation of the open draft's treadling (or liftplan) as a numbered
// list of rows, each row a run of consecutive picks that use the same shed, with its count, the
// picks it covers, and EVERY weft color in it. It never reshapes the editor: the structural draft
// grid stays one treadling row per pick, and this view is re-derived from those picks on every
// build (see treadling_entries.dart), so the two can never disagree.
//
// PICK ROLES (M8-06). Each pick may carry a role (pattern, tabby, top layer, bottom layer, or
// unknown). The selected row's controls set the role of the whole row or of one pick in it, and
// "Mark tabby picks" PROPOSES tabby roles for the picks on the draft's plain-weave sheds, written only
// after the weaver confirms. Roles are edited here rather than in a band on the draft grid: the Book
// view is where the working order is read, and a band would change the grid's fixed layout.
//
// USE TABBY (M8-08). When the roles make it exact (see use_tabby.dart), the view can show the
// traditional "Use tabby" abbreviation instead: one instruction for the tabby picks (which tabby comes
// first) and rows of pattern picks only. When the policy does not hold, the full listing stays and the
// switch says why. Edits in Use tabby mode change the pattern list and are committed only if the
// expanded picks read back as exactly that shorthand; otherwise they are refused with the reason.
//
// Full-listing edits are kept only where each maps to explicit per-pick changes that the re-derived
// rows show back exactly: set a row's single treadle (all its picks), change its count (add or remove
// picks at the END of the row, an added pick copying the row's last pick, weft color and role
// included), delete the row's picks, or set roles. Each commits one undo entry on the editor.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/draft_doc.dart';
import '../models/treadling_entries.dart';
import '../models/use_tabby.dart';
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

/// The Book view's statement of what it is.
const String kBookViewExplainer =
    'Each row groups consecutive picks that use the same shed, with how many picks it covers.';
const String kBookViewKeepsPicks =
    'The draft keeps every pick. Edits here change those picks and can be undone in the editor.';

/// The Use tabby switch and its explanation when it is on.
const String kBookViewUseTabby = 'Use tabby shorthand';
const String kBookViewUseTabbyOn = 'Rows list the pattern picks only. The tabby picks between them '
    'follow the instruction below.';

/// The Mark tabby picks helper.
const String kMarkTabbyPicks = 'Mark tabby picks';
const String kMarkTabbyNone =
    'No pick uses a plain-weave (tabby) shed, so there are no tabby picks to mark.';
const String kMarkTabbyAllDone = 'Every pick on a tabby shed is already marked tabby.';

/// The note under the Use tabby row editor.
const String kUseTabbyCountNote = 'Count adds or removes pattern picks at the end of this row, each '
    "with its tabby pick, and an added pattern pick copies the row's last one. The tabby keeps "
    'alternating, so an odd change moves every later tabby pick to the other tabby shed.';

/// The most picks a single row may hold through the count stepper (matches the editor's Picks
/// stepper ceiling).
const int kBookViewMaxCount = 200;

/// "Treadle 3", "Treadles 1 + 3", "No treadle" (treadled), or the shaft wording for a liftplan.
String bookShedLabel(List<int> shed, {required bool treadled}) =>
    shedLabel(shed, treadled: treadled);

/// "Pick 4" or "Picks 1 to 3" for the 0-based half-open range [start, end), shown 1-based.
String bookPickRangeLabel(int start, int end) =>
    end - start == 1 ? 'Pick ${start + 1}' : 'Picks ${start + 1} to $end';

/// "1 pick" / "3 picks".
String _picks(int n) => n == 1 ? '1 pick' : '$n picks';

/// A screen-reader description of [entry]'s weft colors in pick order, 1-based palette numbers to
/// match the editor's color bands: "weft color 2 for 2 picks, then color 1 for 1 pick".
String bookWeftDescription(TreadlingEntry entry, List<int> weftColors) =>
    _weftWords(weftColorRuns(entry, weftColors).map((r) => (r.color, r.count)).toList());

String _weftWords(List<(int, int)> runs) => [
      for (var i = 0; i < runs.length; i++)
        '${i == 0 ? 'weft color' : 'then color'} ${runs[i].$1 + 1} for ${_picks(runs[i].$2)}',
    ].join(', ');

/// The roles of the picks [start] to [end] - 1 as text: "Role: pattern" when they agree, otherwise
/// "Roles: pattern ×2, unknown" in pick order.
String bookRoleDescription(DraftDoc doc, int start, int end) {
  final runs = <(PickRole, int)>[];
  for (var p = start; p < end; p++) {
    final r = doc.roleAt(p);
    if (runs.isNotEmpty && runs.last.$1 == r) {
      runs[runs.length - 1] = (r, runs.last.$2 + 1);
    } else {
      runs.add((r, 1));
    }
  }
  if (runs.length == 1) return 'Role: ${pickRoleWord(runs.single.$1)}';
  return 'Roles: ${runs.map((x) => x.$2 == 1 ? pickRoleWord(x.$1) : '${pickRoleWord(x.$1)} ×${x.$2}').join(', ')}';
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
  /// The selected row of the full listing, anchored by its FIRST pick rather than its index, so the
  /// selection follows the picks when an edit regroups the rows. Null when no row is selected.
  int? _anchorPick;

  /// The selected Use tabby row, anchored by its first pattern pick's index in the pattern list.
  int? _anchorPattern;

  /// Whether to show the Use tabby shorthand when the draft allows it (local view state).
  bool _useTabby = true;

  /// Why the last Use tabby edit was refused, shown under the selected row (null = none). Shown
  /// inline, like the palette sheet's errors, because a SnackBar can sit under a modal sheet.
  String? _rowNotice;

  /// What the last "Mark tabby picks" found when there was nothing to propose (null = none).
  String? _markNotice;

  void _edited(String? refusal) {
    if (mounted) setState(() => _rowNotice = refusal);
  }

  Future<void> _markTabby(DraftDoc doc) async {
    final proposal = proposeTabbyRoles(doc);
    if (proposal.noTabbySheds) {
      setState(() => _markNotice = kMarkTabbyNone);
      return;
    }
    if (proposal.toTabby.isEmpty && proposal.otherUnknown.isEmpty) {
      setState(() => _markNotice = kMarkTabbyAllDone);
      return;
    }
    setState(() => _markNotice = null);
    final roles = await showDialog<Map<int, PickRole>>(
      context: context,
      builder: (_) => MarkTabbyDialog(
        proposal: proposal,
        treadled: doc.drive is DraftTreadled,
      ),
    );
    if (roles == null || roles.isEmpty || !mounted) return;
    ref.read(draftEditorProvider.notifier).applyPickRoles(roles);
  }

  @override
  Widget build(BuildContext context) {
    final draft = ref.watch(draftEditorProvider.select((s) => s.draft));
    final pinned = ref.watch(overshotTreadlingProvider);
    final rows = draft.drive.rows;
    final treadled = draft.drive is DraftTreadled;
    final reading = readUseTabby(draft);
    final book = _useTabby && reading is UseTabbyBook ? reading : null;
    final entries = treadlingEntries(rows);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant);

    final String switchSubtitle = switch (reading) {
      UseTabbyBook() => kBookViewUseTabbyOn,
      UseTabbyUnavailable(:final reason) => reason,
    };

    // Only the title and the summary stay fixed; the explanation, the switches, the rows, and the
    // selected row's controls (inline, right under that row) all scroll together, so nothing can
    // overflow a short phone screen however long the draft is.
    final header = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(kBookViewExplainer, style: muted),
        const SizedBox(height: 4),
        Text(kBookViewKeepsPicks, style: muted),
        // A draft with no picks has nothing to abbreviate or mark.
        if (draft.picks > 0)
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text(kBookViewUseTabby),
            subtitle: Text(switchSubtitle),
            value: reading is UseTabbyBook && _useTabby,
            onChanged: reading is UseTabbyBook
                ? (v) => setState(() {
                      _useTabby = v;
                      _anchorPick = null;
                      _anchorPattern = null;
                      _rowNotice = null;
                    })
                : null,
          ),
        if (draft.picks > 0)
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: () => _markTabby(draft),
              icon: const Icon(Icons.checklist),
              label: const Text(kMarkTabbyPicks),
            ),
          ),
        if (_markNotice != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(_markNotice!, key: const ValueKey('mark-tabby-notice'), style: muted),
          ),
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('Book view button in the editor'),
          subtitle: const Text('Saved with this draft. Generating an overshot turns it on.'),
          value: pinned,
          onChanged: (v) => ref.read(overshotTreadlingProvider.notifier).state = v,
        ),
        const Divider(height: 1),
        if (book != null)
          _UseTabbyHeader(book: book, palette: draft.palette)
        else if (entries.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text('This draft has no picks yet.', style: muted),
          ),
      ],
    );

    final int itemCount;
    final Widget Function(BuildContext, int) itemBuilder;
    final String summary;
    if (book != null) {
      final bookRows = book.rows;
      final anchor = _anchorPattern;
      final selected = anchor == null
          ? null
          : bookRows.indexWhere((r) => anchor >= r.firstPattern && anchor < r.endPattern);
      summary = useTabbySummary(book);
      itemCount = bookRows.length;
      itemBuilder = (context, i) {
        final row = _UseTabbyRowTile(
          index: i,
          row: bookRows[i],
          book: book,
          palette: draft.palette,
          selected: i == selected,
          onTap: () => setState(() {
            _anchorPattern = i == selected ? null : bookRows[i].firstPattern;
            _rowNotice = null;
          }),
        );
        if (i != selected) return row;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            row,
            _UseTabbyRowEditor(
              index: i,
              row: bookRows[i],
              treadled: treadled,
              treadles: draft.treadles,
              notice: _rowNotice,
              onResult: _edited,
              onDeleted: () => setState(() => _anchorPattern = null),
            ),
            const Divider(height: 1),
          ],
        );
      };
    } else {
      final anchor = _anchorPick;
      final selected = anchor == null ? null : entryIndexForPick(entries, anchor);
      summary =
          '${_picks(rows.length)} in ${entries.length == 1 ? '1 row' : '${entries.length} rows'}';
      itemCount = entries.length;
      itemBuilder = (context, i) {
        final row = _BookRow(
          index: i,
          entry: entries[i],
          doc: draft,
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
              doc: draft,
              treadled: treadled,
              treadles: draft.treadles,
              onDeleted: () => setState(() => _anchorPick = null),
            ),
            const Divider(height: 1),
          ],
        );
      };
    }

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
              Text(summary, style: theme.textTheme.titleSmall),
              const SizedBox(height: 4),
              Flexible(
                child: ListView.builder(
                  // A short list sizes the sheet to its content; a long one fills the sheet and
                  // scrolls lazily instead of laying out every row up front.
                  shrinkWrap: itemCount <= 50,
                  itemCount: itemCount + 1, // the header, then one item per row
                  itemBuilder: (context, item) =>
                      item == 0 ? header : itemBuilder(context, item - 1),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The weft swatches of one row, in order: one swatch per stretch of one color, with its count when
/// it covers more than one pick. [runs] are (palette index, count, key suffix).
class _WeftSwatches extends StatelessWidget {
  const _WeftSwatches({required this.runs, required this.palette, required this.keyPrefix});

  final List<(int, int, int)> runs;
  final List<DraftColor> palette;
  final String keyPrefix;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text('Weft', style: theme.textTheme.bodySmall),
        for (final (color, count, at) in runs)
          Row(
            key: ValueKey('$keyPrefix-$at'),
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  color: _swatch(palette, color),
                  borderRadius: BorderRadius.circular(2),
                  border: Border.all(color: cs.outline),
                ),
              ),
              if (count > 1) ...[
                const SizedBox(width: 2),
                Text('×$count', style: theme.textTheme.bodySmall),
              ],
            ],
          ),
      ],
    );
  }
}

/// One Book view row: its number, shed, pick range, every weft color in pick order, its roles (when
/// the draft records any), and its count.
class _BookRow extends StatelessWidget {
  const _BookRow({
    required this.index,
    required this.entry,
    required this.doc,
    required this.treadled,
    required this.selected,
    required this.onTap,
  });

  final int index;
  final TreadlingEntry entry;
  final DraftDoc doc;
  final bool treadled;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final shed = bookShedLabel(entry.shed, treadled: treadled);
    final range = bookPickRangeLabel(entry.startPick, entry.endPick);
    final runs = weftColorRuns(entry, doc.weftColors);
    final roles = doc.pickRoles.isEmpty
        ? null
        : bookRoleDescription(doc, entry.startPick, entry.endPick);
    final label = 'Row ${index + 1}: $shed, ${_picks(entry.count)}, '
        '${range.toLowerCase()}, ${bookWeftDescription(entry, doc.weftColors)}'
        '${roles == null ? '' : ', ${roles.toLowerCase()}'}';
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
                      if (roles != null) Text(roles, style: theme.textTheme.bodySmall),
                      const SizedBox(height: 4),
                      // EVERY weft color in the run, in pick order.
                      _WeftSwatches(
                        runs: [for (final r in runs) (r.color, r.count, r.startPick)],
                        palette: doc.palette,
                        keyPrefix: 'weft-${entry.startPick}',
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
class _RowEditor extends ConsumerStatefulWidget {
  const _RowEditor({
    required this.index,
    required this.entry,
    required this.doc,
    required this.treadled,
    required this.treadles,
    required this.onDeleted,
  });

  final int index;
  final TreadlingEntry entry;
  final DraftDoc doc;
  final bool treadled;
  final int treadles;
  final VoidCallback onDeleted;

  @override
  ConsumerState<_RowEditor> createState() => _RowEditorState();
}

class _RowEditorState extends ConsumerState<_RowEditor> {
  /// Which pick of the row the single-pick role control addresses, as an offset into the run.
  int _offset = 0;

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final notifier = ref.read(draftEditorProvider.notifier);
    // The single-treadle stepper only applies to a row pressing at most one treadle; a multi-treadle
    // row is edited cell by cell on the draft grid (stepping it would silently drop treadles).
    final single = widget.treadled && entry.shed.length <= 1;
    final treadle = entry.shed.isEmpty ? 0 : entry.shed.first;
    final offset = _offset.clamp(0, entry.count - 1);
    final pick = entry.startPick + offset;
    final rowRoles = {
      for (var p = entry.startPick; p < entry.endPick; p++) widget.doc.roleAt(p),
    };
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
              'Editing row ${widget.index + 1}, '
              '${bookPickRangeLabel(entry.startPick, entry.endPick).toLowerCase()}',
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
                          widget.index, treadle == 1 ? const <int>[] : <int>[treadle - 1])
                      : null,
                  onInc: treadle < widget.treadles
                      ? () => notifier.setEntryShed(widget.index, <int>[treadle + 1])
                      : null,
                ),
              _BookStepper(
                label: 'Count',
                value: '${entry.count}',
                decTooltip: 'Fewer picks in this row',
                incTooltip: 'More picks in this row',
                onDec: entry.count > 1
                    ? () => notifier.setEntryCount(widget.index, entry.count - 1)
                    : null,
                onInc: entry.count < kBookViewMaxCount
                    ? () => notifier.setEntryCount(widget.index, entry.count + 1)
                    : null,
              ),
              TextButton.icon(
                onPressed: () {
                  notifier.removeEntry(widget.index);
                  widget.onDeleted();
                },
                icon: const Icon(Icons.delete_outline),
                label: const Text('Delete these picks'),
              ),
            ],
          ),
          if (widget.treadled && !single)
            Text('This row presses more than one treadle. Change its treadles on the draft grid.',
                style: muted),
          Text(
              "Count adds or removes picks at the end of this row. An added pick copies the row's "
              'last pick, weft color and role included.',
              style: muted),
          const SizedBox(height: 8),
          Text(entry.count == 1 ? 'Role' : 'Role of all ${entry.count} picks',
              style: theme.textTheme.labelLarge),
          _RoleChips(
            keyPrefix: 'row-role',
            selected: rowRoles.length == 1 ? rowRoles.single : null,
            onSelected: (r) => notifier.setPickRoles(entry.startPick, entry.endPick, r),
          ),
          if (entry.count > 1) ...[
            _BookStepper(
              label: 'Role of pick',
              value: '${pick + 1}',
              decTooltip: 'Previous pick in this row',
              incTooltip: 'Next pick in this row',
              onDec: offset > 0 ? () => setState(() => _offset = offset - 1) : null,
              onInc: offset < entry.count - 1 ? () => setState(() => _offset = offset + 1) : null,
            ),
            _RoleChips(
              keyPrefix: 'pick-role',
              selected: widget.doc.roleAt(pick),
              onSelected: (r) => notifier.setPickRoles(pick, pick + 1, r),
            ),
          ],
        ],
      ),
    );
  }
}

/// One choice chip per role; [selected] is highlighted (none when the picks disagree).
class _RoleChips extends StatelessWidget {
  const _RoleChips({required this.keyPrefix, required this.selected, required this.onSelected});

  final String keyPrefix;
  final PickRole? selected;
  final ValueChanged<PickRole> onSelected;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: [
        for (final r in PickRole.values)
          ChoiceChip(
            key: ValueKey('$keyPrefix-${r.name}'),
            label: Text(pickRoleLabel(r)),
            selected: r == selected,
            onSelected: (_) {
              if (r != selected) onSelected(r);
            },
          ),
      ],
    );
  }
}

/// The Use tabby instruction: where the tabby picks go, which tabby comes first, and the tabby weft.
class _UseTabbyHeader extends StatelessWidget {
  const _UseTabbyHeader({required this.book, required this.palette});

  final UseTabbyBook book;
  final List<DraftColor> palette;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Semantics(
      container: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Use tabby', style: theme.textTheme.titleMedium),
            const SizedBox(height: 2),
            Text(useTabbyInstruction(book)),
            const SizedBox(height: 4),
            Semantics(
              label: 'Tabby weft color ${book.tabbyColor + 1}',
              excludeSemantics: true,
              child: Row(
                children: [
                  Text('Tabby weft', style: theme.textTheme.bodySmall),
                  const SizedBox(width: 6),
                  Container(
                    key: const ValueKey('tabby-weft'),
                    width: 14,
                    height: 14,
                    decoration: BoxDecoration(
                      color: _swatch(palette, book.tabbyColor),
                      borderRadius: BorderRadius.circular(2),
                      border: Border.all(color: cs.outline),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The pattern-pick weft color stretches of a Use tabby row: (palette index, count, pattern index).
List<(int, int, int)> _patternWeftRuns(UseTabbyBook book, UseTabbyRow row) {
  final runs = <(int, int, int)>[];
  for (var k = row.firstPattern; k < row.endPattern; k++) {
    final c = book.pattern[k].color;
    if (runs.isNotEmpty && runs.last.$1 == c) {
      runs[runs.length - 1] = (c, runs.last.$2 + 1, runs.last.$3);
    } else {
      runs.add((c, 1, k));
    }
  }
  return runs;
}

/// One Use tabby row: consecutive pattern picks on the same shed, the picks they span, their weft
/// colors, and how many pattern picks it holds.
class _UseTabbyRowTile extends StatelessWidget {
  const _UseTabbyRowTile({
    required this.index,
    required this.row,
    required this.book,
    required this.palette,
    required this.selected,
    required this.onTap,
  });

  final int index;
  final UseTabbyRow row;
  final UseTabbyBook book;
  final List<DraftColor> palette;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final shed = bookShedLabel(row.shed, treadled: book.treadled);
    final range = bookPickRangeLabel(row.firstPick, row.lastPick + 1);
    final runs = _patternWeftRuns(book, row);
    final patternPicks = row.count == 1 ? '1 pattern pick' : '${row.count} pattern picks';
    final label = 'Row ${index + 1}: $shed, $patternPicks, ${range.toLowerCase()}, '
        '${_weftWords([for (final r in runs) (r.$1, r.$2)])}';
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
                      _WeftSwatches(
                          runs: runs, palette: palette, keyPrefix: 'pattern-${row.firstPattern}'),
                    ],
                  ),
                ),
                Text('×${row.count}', style: theme.textTheme.titleMedium),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The editing controls for the selected Use tabby row. Each control is an edit of the pattern list
/// that is committed only when the expanded picks read back as exactly that shorthand; a refusal
/// reaches [onResult] as its reason and is shown here as [notice].
class _UseTabbyRowEditor extends ConsumerWidget {
  const _UseTabbyRowEditor({
    required this.index,
    required this.row,
    required this.treadled,
    required this.treadles,
    required this.notice,
    required this.onResult,
    required this.onDeleted,
  });

  final int index;
  final UseTabbyRow row;
  final bool treadled;
  final int treadles;

  /// Why the last edit here was refused, or null.
  final String? notice;
  final ValueChanged<String?> onResult;
  final VoidCallback onDeleted;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final notifier = ref.read(draftEditorProvider.notifier);
    final single = treadled && row.shed.length <= 1;
    final treadle = row.shed.isEmpty ? 0 : row.shed.first;
    void edit(UseTabbyEditResult Function(DraftDoc doc) f) => onResult(notifier.applyUseTabbyEdit(f));
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
              'Editing row ${index + 1}, '
              '${bookPickRangeLabel(row.firstPick, row.lastPick + 1).toLowerCase()}',
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
                  onDec: treadle > 0
                      ? () => edit((d) => editUseTabbyRowShed(
                          d, index, treadle == 1 ? const <int>[] : <int>[treadle - 1]))
                      : null,
                  onInc: treadle < treadles
                      ? () => edit((d) => editUseTabbyRowShed(d, index, <int>[treadle + 1]))
                      : null,
                ),
              _BookStepper(
                label: 'Count',
                value: '${row.count}',
                decTooltip: 'Fewer pattern picks in this row',
                incTooltip: 'More pattern picks in this row',
                onDec: row.count > 1
                    ? () => edit((d) => editUseTabbyRowCount(d, index, row.count - 1))
                    : null,
                onInc: row.count < kBookViewMaxCount
                    ? () => edit((d) => editUseTabbyRowCount(d, index, row.count + 1))
                    : null,
              ),
              TextButton.icon(
                onPressed: () {
                  final reason = notifier.applyUseTabbyEdit((d) => removeUseTabbyRow(d, index));
                  onResult(reason);
                  if (reason == null) onDeleted();
                },
                icon: const Icon(Icons.delete_outline),
                label: const Text('Delete these pattern picks'),
              ),
            ],
          ),
          if (notice != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(notice!,
                  key: const ValueKey('use-tabby-refusal'),
                  style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.error)),
            ),
          if (treadled && !single)
            Text('This row presses more than one treadle. Change its treadles on the draft grid.',
                style: muted),
          Text(kUseTabbyCountNote, style: muted),
        ],
      ),
    );
  }
}

/// The "Mark tabby picks" confirmation: what the proposal would change, with an opt-in to mark the
/// other unknown picks as pattern. Pops the roles to write, or null when cancelled.
class MarkTabbyDialog extends StatefulWidget {
  const MarkTabbyDialog({super.key, required this.proposal, required this.treadled});

  final TabbyProposal proposal;
  final bool treadled;

  @override
  State<MarkTabbyDialog> createState() => _MarkTabbyDialogState();
}

class _MarkTabbyDialogState extends State<MarkTabbyDialog> {
  bool _othersAsPattern = false;

  @override
  Widget build(BuildContext context) {
    final p = widget.proposal;
    final sheds = p.sheds.map((s) => shedWord(s, treadled: widget.treadled)).join(' or ');
    final canApply = p.toTabby.isNotEmpty || _othersAsPattern;
    return AlertDialog(
      title: const Text(kMarkTabbyPicks),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(p.toTabby.isEmpty
                ? kMarkTabbyAllDone
                : '${describePicks(p.toTabby, sentenceStart: true)} '
                    '${p.toTabby.length == 1 ? 'uses' : 'use'} a plain-weave (tabby) shed ($sheds) '
                    'and will be marked tabby.'),
            if (p.replacing.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('${describePicks(p.replacing, sentenceStart: true)} '
                  '${p.replacing.length == 1 ? 'has' : 'have'} another role now, which will be '
                  'replaced.'),
            ],
            if (p.otherUnknown.isNotEmpty)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _othersAsPattern,
                onChanged: (v) => setState(() => _othersAsPattern = v ?? false),
                title: const Text('Also mark the other picks with no role as pattern'),
                subtitle: Text(describePicks(p.otherUnknown, sentenceStart: true)),
              ),
            const SizedBox(height: 8),
            const Text('Nothing changes until you confirm, and Undo puts the roles back.'),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          onPressed: canApply
              ? () => Navigator.of(context).pop(p.roles(othersAsPattern: _othersAsPattern))
              : null,
          child: const Text('Mark picks'),
        ),
      ],
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
