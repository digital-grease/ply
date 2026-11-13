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
// SHOT GROUPS, SHUTTLES, STRANDS (M8-06). A row of ungrouped picks in the same shed is a display
// convenience; a shot group (passes in ONE shed: a double shot, a triple shot) is a deliberate
// instruction, so it is always its own row, labelled. The selected row can be grouped (its first N
// picks) or ungrouped, and its picks (all, or one) given a shuttle and a strand count. Each shuttle's
// starting side is set in the Shuttles panel; the direction of every pass is DERIVED from those (see
// weft_work.dart) and shown as an arrow, never stored per pick. Shuttles are never guessed from colors.
//
// Full-listing edits are kept only where each maps to explicit per-pick changes that the re-derived
// rows show back exactly: set a row's single treadle (all its picks), change its count (add or remove
// picks at the END of the row, an added pick copying the row's last pick, weft color, role, shuttle,
// and strands included; on a shot group's row the added picks are more passes of the group), delete
// the row's picks, group or ungroup, or set roles, shuttles, and strands. Each commits one undo entry
// on the editor.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/draft_doc.dart';
import '../models/treadling_entries.dart';
import '../models/use_tabby.dart';
import '../models/weft_work.dart';
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

/// The Shuttles panel.
const String kShuttlesTitle = 'Shuttles';
const String kShuttlesExplainer = 'Each shuttle changes direction on every pass, so Ply works out the '
    'direction of each pick from its shuttle: ← right to left, → left to right, as you sit at the '
    'loom. Ply never guesses a shuttle from a color.';
const String kShuttlesNone = 'No pick has a shuttle yet. Select a row to set its shuttle.';

/// The shot group controls of the selected row.
const String kShotGroupTitle = 'Shot group';
const String kShotGroupExplainer = 'Picks in the same shed stay separate picks, with a shed change '
    'between them, unless you group them. A shot group means passing the weft again without changing '
    'the shed.';
const String kShotGroupCatch = 'These picks are worked in one shed without changing it. Catch the '
    'weft at the selvedge on each return pass, for example with a floating selvedge.';
const String kUngroup = 'Ungroup these picks';

/// The strands control's explanation: two yarns in one pass are not two passes in one shed.
const String kStrandsExplainer = 'Strands are yarns carried together in one pass. That is not a '
    'double shot, which is two passes in one shed.';

/// The most picks whose shuttle and direction a row spells out before "and N more".
const int _kShownPasses = 8;

/// The picks of a row as a list of 0-based picks.
List<int> _range(int start, int end) => [for (var p = start; p < end; p++) p];

/// One pass as text: "1 ←" (shuttle 1, right to left), "1" (shuttle 1, direction unknown), or "?"
/// (shuttle unknown).
String _passToken(DraftDoc doc, List<ShuttleSide?> starts, int pick) {
  final s = doc.shuttleAt(pick);
  if (s == null) return '?';
  final side = pick < starts.length ? starts[pick] : null;
  return side == null ? '$s' : '$s ${passArrow(side)}';
}

/// One pass in words: "shuttle 1 right to left", "shuttle 1, direction unknown", "shuttle unknown".
String _passWords(DraftDoc doc, List<ShuttleSide?> starts, int pick) {
  final s = doc.shuttleAt(pick);
  if (s == null) return 'shuttle unknown';
  final side = pick < starts.length ? starts[pick] : null;
  return side == null ? 'shuttle $s, direction unknown' : 'shuttle $s ${passWords(side)}';
}

/// The shuttle line of [picks] (in pick order), or null when the draft records no shuttle: "Shuttle 1
/// ←" for one pick, "Shuttle 1: ← → ←" when every pick is on one known shuttle, otherwise "Shuttles:
/// 1 ←, 2 →, ?" ("?" = no shuttle), with "and N more" past [_kShownPasses] picks.
String? bookShuttleLine(DraftDoc doc, List<ShuttleSide?> starts, List<int> picks) {
  if (doc.pickShuttles.isEmpty || picks.isEmpty) return null;
  final shuttles = {for (final p in picks) doc.shuttleAt(p)};
  final more = picks.length > _kShownPasses ? ' and ${picks.length - _kShownPasses} more' : '';
  if (shuttles.length == 1) {
    final s = shuttles.single;
    if (s == null) return picks.length == 1 ? 'Shuttle unknown' : 'Shuttles unknown';
    final arrows = [
      for (final p in picks.take(_kShownPasses))
        if (p < starts.length && starts[p] != null) passArrow(starts[p]!) else '?',
    ];
    if (arrows.every((a) => a == '?')) return 'Shuttle $s';
    if (picks.length == 1) return 'Shuttle $s ${arrows.single}';
    return 'Shuttle $s: ${arrows.join(' ')}$more';
  }
  return 'Shuttles: ${picks.take(_kShownPasses).map((p) => _passToken(doc, starts, p)).join(', ')}'
      '$more';
}

/// [bookShuttleLine] for a screen reader: every pass in words.
String? bookShuttleWords(DraftDoc doc, List<ShuttleSide?> starts, List<int> picks) {
  if (doc.pickShuttles.isEmpty || picks.isEmpty) return null;
  final shown = picks.take(_kShownPasses).map((p) => _passWords(doc, starts, p)).join(', then ');
  return picks.length > _kShownPasses ? '$shown, and ${picks.length - _kShownPasses} more' : shown;
}

/// The strands line of [picks], or null when every one carries a single strand: "2 strands carried
/// together" (one pick), "2 strands carried together in each pass", or "Strands carried together: 2,
/// 1, 2".
String? bookStrandsLine(DraftDoc doc, List<int> picks) {
  final counts = [for (final p in picks) doc.strandsAt(p)];
  if (counts.every((n) => n == 1)) return null;
  if (counts.toSet().length == 1) {
    return picks.length == 1
        ? '${counts.first} strands carried together'
        : '${counts.first} strands carried together in each pass';
  }
  final shown = counts.take(_kShownPasses).join(', ');
  return 'Strands carried together: $shown'
      '${counts.length > _kShownPasses ? ' and ${counts.length - _kShownPasses} more' : ''}';
}

/// The shuttle chips offered: 1 to 4, or one past the highest shuttle the draft uses, up to
/// [kMaxShuttles].
int _shuttleChoices(DraftDoc doc) {
  final used = shuttlesInUse(doc);
  final top = used.isEmpty ? 0 : used.last;
  final n = top + 1 > 4 ? top + 1 : 4;
  return n > kMaxShuttles ? kMaxShuttles : n;
}

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
    final entries = treadlingEntries(rows, draft.shotGroups);
    final starts = passStarts(draft);
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
        if (draft.picks > 0) _ShuttlesPanel(doc: draft),
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
          _UseTabbyHeader(
              book: book, palette: draft.palette, recordsShuttles: draft.pickShuttles.isNotEmpty)
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
          doc: draft,
          starts: starts,
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
          starts: starts,
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
    required this.starts,
    required this.treadled,
    required this.selected,
    required this.onTap,
  });

  final int index;
  final TreadlingEntry entry;
  final DraftDoc doc;
  final List<ShuttleSide?> starts;
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
    final picks = _range(entry.startPick, entry.endPick);
    final shot = entry.grouped ? shotGroupDescription(entry.count) : null;
    final shuttle = bookShuttleLine(doc, starts, picks);
    final strands = bookStrandsLine(doc, picks);
    final shuttleWords = bookShuttleWords(doc, starts, picks);
    final label = 'Row ${index + 1}: $shed, '
        '${shot == null ? _picks(entry.count) : shot.toLowerCase()}, '
        '${range.toLowerCase()}, ${bookWeftDescription(entry, doc.weftColors)}'
        '${roles == null ? '' : ', ${roles.toLowerCase()}'}'
        '${shuttleWords == null ? '' : ', $shuttleWords'}'
        '${strands == null ? '' : ', ${strands.toLowerCase()}'}';
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
                      // A shot group reads distinctly from a run of separate picks in one shed.
                      if (shot != null)
                        Row(
                          key: ValueKey('shot-${entry.startPick}'),
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.replay, size: 16, color: cs.primary),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(shot,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                      color: cs.primary, fontWeight: FontWeight.w600)),
                            ),
                          ],
                        ),
                      Text(range, style: theme.textTheme.bodySmall),
                      if (roles != null) Text(roles, style: theme.textTheme.bodySmall),
                      if (shuttle != null)
                        Text(shuttle,
                            key: ValueKey('shuttle-${entry.startPick}'),
                            style: theme.textTheme.bodySmall),
                      if (strands != null)
                        Text(strands,
                            key: ValueKey('strands-${entry.startPick}'),
                            style: theme.textTheme.bodySmall),
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
  /// Which pick of the row the single-pick controls address, as an offset into the run.
  int _offset = 0;

  /// How many of the row's first picks the Group button groups (null = all of them).
  int? _passes;

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final doc = widget.doc;
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
      for (var p = entry.startPick; p < entry.endPick; p++) doc.roleAt(p),
    };
    final rowShuttles = {
      for (var p = entry.startPick; p < entry.endPick; p++) doc.shuttleAt(p),
    };
    final rowStrands = [for (var p = entry.startPick; p < entry.endPick; p++) doc.strandsAt(p)];
    final strandsLow = rowStrands.reduce((a, b) => a < b ? a : b);
    final strandsHigh = rowStrands.reduce((a, b) => a > b ? a : b);
    final strandsMixed = strandsLow != strandsHigh;
    final passes = (_passes ?? entry.count).clamp(2, entry.count < 2 ? 2 : entry.count);
    final shuttleChoices = _shuttleChoices(doc);
    final many = entry.count > 1;
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
              entry.grouped
                  ? 'Count adds or removes passes at the end of this shot group. An added pass '
                      'copies the last one, weft color, role, shuttle, and strands included.'
                  : "Count adds or removes picks at the end of this row. An added pick copies the "
                      "row's last pick, weft color, role, shuttle, and strands included.",
              style: muted),
          // Shot group: a group row can be ungrouped; a row of several separate picks in one shed can
          // have its first N picks grouped.
          if (entry.grouped) ...[
            const SizedBox(height: 8),
            Text('$kShotGroupTitle: ${shotGroupDescription(entry.count)}',
                style: theme.textTheme.labelLarge),
            Text(kShotGroupCatch, style: muted),
            OutlinedButton.icon(
              key: const ValueKey('ungroup-shot'),
              onPressed: () => notifier.ungroupShot(entry.startPick),
              icon: const Icon(Icons.call_split),
              label: const Text(kUngroup),
            ),
          ] else if (many) ...[
            const SizedBox(height: 8),
            Text(kShotGroupTitle, style: theme.textTheme.labelLarge),
            Text(kShotGroupExplainer, style: muted),
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              children: [
                if (entry.count > 2)
                  _BookStepper(
                    label: 'Passes',
                    value: '$passes',
                    decTooltip: 'Fewer passes in the group',
                    incTooltip: 'More passes in the group',
                    onDec: passes > 2 ? () => setState(() => _passes = passes - 1) : null,
                    onInc: passes < entry.count
                        ? () => setState(() => _passes = passes + 1)
                        : null,
                  ),
                FilledButton.tonal(
                  key: const ValueKey('group-shot'),
                  onPressed: () => notifier.groupShot(entry.startPick, passes),
                  child: Text('Group as ${shotGroupPhrase(passes)}'),
                ),
              ],
            ),
            if (passes < entry.count)
              Text('This groups the first $passes picks of this row.', style: muted),
          ],
          const SizedBox(height: 8),
          Text(many ? 'Role of all ${entry.count} picks' : 'Role',
              style: theme.textTheme.labelLarge),
          _RoleChips(
            keyPrefix: 'row-role',
            selected: rowRoles.length == 1 ? rowRoles.single : null,
            onSelected: (r) => notifier.setPickRoles(entry.startPick, entry.endPick, r),
          ),
          Text(many ? 'Shuttle of all ${entry.count} picks' : 'Shuttle',
              style: theme.textTheme.labelLarge),
          _ShuttleChips(
            keyPrefix: 'row-shuttle',
            choices: shuttleChoices,
            values: rowShuttles,
            onSelected: (v) => notifier.setPickShuttles(entry.startPick, entry.endPick, v),
          ),
          _BookStepper(
            key: const ValueKey('row-strands'),
            label: many ? 'Strands in each pick:' : 'Strands',
            value: strandsMixed ? 'mixed' : '$strandsLow',
            decTooltip: many ? 'Fewer strands in every pick of this row' : 'Fewer strands',
            incTooltip: many ? 'More strands in every pick of this row' : 'More strands',
            // On a row with mixed counts, Fewer makes every pick the smallest count and More the
            // largest; otherwise they step the shared count.
            onDec: strandsMixed || strandsLow > 1
                ? () => notifier.setPickStrands(
                    entry.startPick, entry.endPick, strandsMixed ? strandsLow : strandsLow - 1)
                : null,
            onInc: strandsMixed || strandsHigh < kMaxStrands
                ? () => notifier.setPickStrands(
                    entry.startPick, entry.endPick, strandsMixed ? strandsHigh : strandsHigh + 1)
                : null,
          ),
          Text(kStrandsExplainer, style: muted),
          if (many) ...[
            const SizedBox(height: 8),
            _BookStepper(
              label: 'Selected pick',
              value: '${pick + 1}',
              decTooltip: 'Previous pick in this row',
              incTooltip: 'Next pick in this row',
              onDec: offset > 0 ? () => setState(() => _offset = offset - 1) : null,
              onInc: offset < entry.count - 1 ? () => setState(() => _offset = offset + 1) : null,
            ),
            Text('Role of pick ${pick + 1}', style: theme.textTheme.labelLarge),
            _RoleChips(
              keyPrefix: 'pick-role',
              selected: doc.roleAt(pick),
              onSelected: (r) => notifier.setPickRoles(pick, pick + 1, r),
            ),
            Text('Shuttle of pick ${pick + 1}', style: theme.textTheme.labelLarge),
            _ShuttleChips(
              keyPrefix: 'pick-shuttle',
              choices: shuttleChoices,
              values: {doc.shuttleAt(pick)},
              onSelected: (v) => notifier.setPickShuttles(pick, pick + 1, v),
            ),
            _BookStepper(
              key: const ValueKey('pick-strands'),
              label: 'Strands of pick ${pick + 1}:',
              value: '${doc.strandsAt(pick)}',
              decTooltip: 'Fewer strands in this pick',
              incTooltip: 'More strands in this pick',
              onDec: doc.strandsAt(pick) > 1
                  ? () => notifier.setPickStrands(pick, pick + 1, doc.strandsAt(pick) - 1)
                  : null,
              onInc: doc.strandsAt(pick) < kMaxStrands
                  ? () => notifier.setPickStrands(pick, pick + 1, doc.strandsAt(pick) + 1)
                  : null,
            ),
          ],
        ],
      ),
    );
  }
}

/// One choice chip per shuttle: "Unknown" and 1 to [choices]. The single value in [values] is
/// highlighted (none when the picks disagree).
class _ShuttleChips extends StatelessWidget {
  const _ShuttleChips({
    required this.keyPrefix,
    required this.choices,
    required this.values,
    required this.onSelected,
  });

  final String keyPrefix;
  final int choices;
  final Set<int?> values;
  final ValueChanged<int?> onSelected;

  @override
  Widget build(BuildContext context) {
    final selected = values.length == 1 ? values : const <int?>{};
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: [
        for (final v in <int?>[null, for (var s = 1; s <= choices; s++) s])
          ChoiceChip(
            key: ValueKey('$keyPrefix-${v ?? 'unknown'}'),
            label: Text(v == null ? 'Unknown' : '$v'),
            tooltip: v == null ? 'Shuttle unknown' : 'Shuttle $v',
            selected: selected.contains(v),
            onSelected: (_) {
              if (!selected.contains(v)) onSelected(v);
            },
          ),
      ],
    );
  }
}

/// The Shuttles panel's one-line summary: "No pick has a shuttle yet. Select a row to set its
/// shuttle." or "Shuttle 1 starts from the right, shuttle 2 has no starting side".
String shuttlesSummary(DraftDoc doc) {
  final used = shuttlesInUse(doc);
  if (used.isEmpty) return kShuttlesNone;
  final parts = [
    for (final s in used)
      switch (doc.shuttleStarts[s]) {
        null => 'shuttle $s has no starting side',
        final side => 'shuttle $s starts from the ${sideLabel(side).toLowerCase()}',
      },
  ];
  final text = parts.join(', ');
  return text[0].toUpperCase() + text.substring(1);
}

/// Each shuttle the draft uses with its starting side, and why some passes have no direction. A
/// collapsible tile with a one-line summary, so the header stays short on a phone; it opens by itself
/// once a pick has a shuttle.
class _ShuttlesPanel extends ConsumerWidget {
  const _ShuttlesPanel({required this.doc});

  final DraftDoc doc;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final used = shuttlesInUse(doc);
    final notes = directionNotes(doc);
    return ExpansionTile(
      // Rebuilt (and so opened) when the first shuttle is set, closed again when none is left.
      key: ValueKey('shuttles-panel-${used.isEmpty}'),
      initiallyExpanded: used.isNotEmpty,
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(bottom: 8),
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      title: Text(kShuttlesTitle, style: theme.textTheme.titleSmall),
      subtitle:
          Text(shuttlesSummary(doc), key: const ValueKey('shuttles-summary'), style: muted),
      children: [
        Text(kShuttlesExplainer, style: muted),
        for (final s in used)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              children: [
                Text('Shuttle $s starts from', style: theme.textTheme.labelLarge),
                SegmentedButton<ShuttleSide>(
                  key: ValueKey('shuttle-start-$s'),
                  segments: [
                    for (final side in ShuttleSide.values)
                      ButtonSegment(value: side, label: Text(sideLabel(side))),
                  ],
                  selected: {if (doc.shuttleStarts[s] != null) doc.shuttleStarts[s]!},
                  emptySelectionAllowed: true,
                  showSelectedIcon: false,
                  onSelectionChanged: (set) => ref
                      .read(draftEditorProvider.notifier)
                      .setShuttleStart(s, set.isEmpty ? null : set.single),
                ),
              ],
            ),
          ),
        for (final note in notes) Text(note, style: muted),
      ],
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
  const _UseTabbyHeader({required this.book, required this.palette, required this.recordsShuttles});

  final UseTabbyBook book;
  final List<DraftColor> palette;

  /// Whether the draft records shuttles (so the tabby shuttle is worth naming, even as unknown).
  final bool recordsShuttles;

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
            if (recordsShuttles || book.tabbyStrands > 1)
              Text(
                  [
                    if (recordsShuttles)
                      book.tabbyShuttle == null
                          ? 'Tabby shuttle unknown'
                          : 'Tabby on shuttle ${book.tabbyShuttle}',
                    if (book.tabbyStrands > 1) '${book.tabbyStrands} strands carried together',
                  ].join(', '),
                  key: const ValueKey('tabby-shuttle'),
                  style: theme.textTheme.bodySmall),
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
    required this.doc,
    required this.starts,
    required this.palette,
    required this.selected,
    required this.onTap,
  });

  final int index;
  final UseTabbyRow row;
  final UseTabbyBook book;
  final DraftDoc doc;
  final List<ShuttleSide?> starts;
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
    // The row's pattern picks in the full draft (the tabby picks between them are in the header).
    final picks = [for (var k = row.firstPattern; k < row.endPattern; k++) book.pickOfPattern(k)];
    final shuttle = bookShuttleLine(doc, starts, picks);
    final shuttleWords = bookShuttleWords(doc, starts, picks);
    final strands = bookStrandsLine(doc, picks);
    final label = 'Row ${index + 1}: $shed, $patternPicks, ${range.toLowerCase()}, '
        '${_weftWords([for (final r in runs) (r.$1, r.$2)])}'
        '${shuttleWords == null ? '' : ', $shuttleWords'}'
        '${strands == null ? '' : ', ${strands.toLowerCase()}'}';
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
                      if (shuttle != null)
                        Text(shuttle,
                            key: ValueKey('pattern-shuttle-${row.firstPattern}'),
                            style: theme.textTheme.bodySmall),
                      if (strands != null) Text(strands, style: theme.textTheme.bodySmall),
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
    super.key,
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
