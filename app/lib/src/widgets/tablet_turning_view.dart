// The Turning tab of the tablet weaving editor (M10-02, ADR 0018 sections 4, 7 and 8): a turning
// chart of the written picks, one row per pick with pick 1 at the BOTTOM, one column per card, each
// cell a letter (F forward, B backward, I idle, ? something Ply does not model, never a slash),
// flips and twist releases marked under the cell of the pick they come before. Picks are grouped in
// segments, each worked a number of times. A tap cycles a cell F, B, I; a long press offers every
// choice; each row's menu opens the full pick editor (every card, the packs, the events and a note),
// which is also the screen-reader path.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/tablet_band.dart';
import '../rust/tablet_dto.dart';
import '../state/tablet_editor_providers.dart';
import 'tablet_widgets.dart' show Utf8ByteLimit;

const double _labelWidth = 104;
const double _menuWidth = 44;

/// One row of the chart, in drawing order.
sealed class _Item {
  const _Item(this.segment);
  final int segment;
}

final class _Header extends _Item {
  const _Header(super.segment);
}

final class _Step extends _Item {
  const _Step(super.segment, this.step);
  final int step;
}

class TabletTurningView extends ConsumerStatefulWidget {
  const TabletTurningView({super.key});

  @override
  ConsumerState<TabletTurningView> createState() => _TabletTurningViewState();
}

class _TabletTurningViewState extends ConsumerState<TabletTurningView> {
  final _vertical = ScrollController();
  final _horizontal = ScrollController();

  @override
  void dispose() {
    _vertical.dispose();
    _horizontal.dispose();
    super.dispose();
  }

  /// The focus last scrolled to.
  TabletFocus? _shown;

  List<_Item> _items(TabletDocumentDto doc) => [
        for (var s = 0; s < doc.turning.length; s++) ...[
          _Header(s),
          for (var k = 0; k < doc.turning[s].picks.length; k++) _Step(s, k),
        ],
      ];

  @override
  Widget build(BuildContext context) {
    final doc = ref.watch(tabletDocProvider);
    final cell = ref.watch(tabletCellPxProvider).toDouble().clamp(24.0, 40.0);
    final focus = ref.watch(tabletFocusProvider);
    final items = _items(doc);
    final rowHeight = cell + 4;
    // Once per new focus (a check selected), never on later rebuilds: an edit must not pull the
    // chart back while the weaver scrolls it.
    if (focus?.segment != null && !identical(focus, _shown)) {
      _shown = focus;
      final target = items.indexWhere((it) => it is _Step
          ? it.segment == focus!.segment && it.step == (focus.step ?? 0)
          : it is _Header && it.segment == focus!.segment && focus.step == null);
      if (target >= 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_vertical.hasClients) {
            _vertical.jumpTo((target * rowHeight).clamp(0.0, _vertical.position.maxScrollExtent));
          }
        });
      }
    }
    final total = expandedPicks(doc);
    final written = doc.turning.fold<int>(0, (n, s) => n + s.picks.length);
    final width = _labelWidth + doc.cards.length * cell + _menuWidth;
    final muted = Theme.of(context).textTheme.bodySmall;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  total > kMaxTabletPicks
                      ? 'More than ${kMaxTabletPicks ~/ 1000},000 picks: too many to weave in Ply.'
                      : '$total ${total == 1 ? 'pick' : 'picks'} from $written written. Pick 1 is at '
                          'the bottom.',
                  style: muted,
                ),
              ),
              TextButton.icon(
                key: const ValueKey('tablet-add-segment'),
                onPressed: () => ref.read(tabletEditorProvider.notifier).edit((d) => addSegment(d)),
                icon: const Icon(Icons.add),
                label: const Text('Segment'),
              ),
            ],
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, box) => Scrollbar(
              controller: _horizontal,
              child: SingleChildScrollView(
                controller: _horizontal,
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                  width: math.max(width, box.maxWidth),
                  height: box.maxHeight,
                  child: Column(
                    children: [
                      _CardNumbers(cards: doc.cards.length, cell: cell),
                      Expanded(
                        child: ListView.builder(
                          key: const ValueKey('tablet-turning-list'),
                          controller: _vertical,
                          reverse: true, // pick 1 at the bottom
                          itemCount: items.length,
                          itemExtent: rowHeight,
                          itemBuilder: (_, i) => switch (items[i]) {
                            _Header(:final segment) => _SegmentHeader(segment: segment),
                            _Step(:final segment, :final step) => _StepRow(
                                segment: segment,
                                step: step,
                                cell: cell,
                                focused: focus?.segment == segment && focus?.step == step,
                              ),
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _CardNumbers extends StatelessWidget {
  const _CardNumbers({required this.cards, required this.cell});
  final int cards;
  final double cell;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelSmall;
    return ExcludeSemantics(
      child: SizedBox(
        height: 22,
        child: Row(children: [
          SizedBox(width: _labelWidth, child: Text('  Card', style: style)),
          for (var i = 0; i < cards; i++)
            SizedBox(width: cell, child: Center(child: Text('${i + 1}', style: style))),
        ]),
      ),
    );
  }
}

class _SegmentHeader extends ConsumerWidget {
  const _SegmentHeader({required this.segment});
  final int segment;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final doc = ref.watch(tabletDocProvider);
    if (segment >= doc.turning.length) return const SizedBox.shrink();
    final seg = doc.turning[segment];
    final first = firstPickOfSegment(doc, segment);
    final last = first + seg.picks.length * seg.repeat - 1;
    final edit = ref.read(tabletEditorProvider.notifier).edit;
    final theme = Theme.of(context);
    final text =
        'Segment ${segment + 1}: ${first == last ? 'pick $first' : 'picks $first to $last'}'
        '${seg.repeat > 1 ? ', ${seg.picks.length} ${seg.picks.length == 1 ? 'pick' : 'picks'} worked ${seg.repeat} times' : ''}';
    return Container(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Row(children: [
        const SizedBox(width: 8),
        Flexible(
          child: Semantics(
            header: true,
            child: Text(text,
                style: theme.textTheme.labelLarge, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          tooltip: 'Work segment ${segment + 1} one time fewer',
          icon: const Icon(Icons.remove, size: 18),
          onPressed:
              seg.repeat > 1 ? () => edit((d) => setRepeat(d, segment, seg.repeat - 1)) : null,
        ),
        Text('x${seg.repeat}', style: theme.textTheme.labelLarge),
        IconButton(
          visualDensity: VisualDensity.compact,
          tooltip: 'Work segment ${segment + 1} one time more',
          icon: const Icon(Icons.add, size: 18),
          onPressed: seg.repeat < kMaxTabletRepeat
              ? () => edit((d) => setRepeat(d, segment, seg.repeat + 1))
              : null,
        ),
        PopupMenuButton<String>(
          tooltip: 'Segment ${segment + 1} actions',
          icon: const Icon(Icons.more_vert, size: 18),
          onSelected: (v) async {
            switch (v) {
              case 'repeat':
                final n = await askTimesWorked(context, 'Work segment ${segment + 1}', seg.repeat);
                if (n != null) edit((d) => setRepeat(d, segment, n));
              case 'add':
                edit((d) => insertPick(d, segment, seg.picks.length));
              case 'after':
                edit((d) => addSegment(d, at: segment + 1));
              case 'delete':
                edit((d) => removeSegment(d, segment));
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'repeat', child: Text('Times worked...')),
            PopupMenuItem(value: 'add', child: Text('Add a pick at its top')),
            PopupMenuItem(value: 'after', child: Text('Add a segment above it')),
            PopupMenuItem(value: 'delete', child: Text('Delete this segment')),
          ],
        ),
      ]),
    );
  }
}

/// Ask how many times to work a segment: a whole number from 1 to [kMaxTabletRepeat], said so
/// when it is outside (nothing larger reaches the engine, whose count is 32-bit). Null on cancel.
Future<int?> askTimesWorked(BuildContext context, String title, int initial) async {
  final controller = TextEditingController(text: '$initial');
  String? problem(String text) {
    final v = int.tryParse(text.trim());
    if (v == null || v < 1) return 'A whole number, 1 or more.';
    if (v > kMaxTabletRepeat) return 'At most $kMaxTabletRepeatText times (Ply\'s pick limit).';
    return null;
  }

  final n = await showDialog<int>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        final error = problem(controller.text);
        return AlertDialog(
          title: Text(title),
          content: TextField(
            key: const ValueKey('tablet-times-worked'),
            controller: controller,
            autofocus: true,
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(9),
            ],
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
                labelText: 'Times', suffixText: 'times', errorText: error, errorMaxLines: 2),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              onPressed: error == null
                  ? () => Navigator.pop(ctx, int.parse(controller.text.trim()))
                  : null,
              child: const Text('Set'),
            ),
          ],
        );
      },
    ),
  );
  // Not disposed here: the dialog's closing animation still shows the field after it returns. A
  // controller holds no native resource, so the collector takes it with the dialog.
  return n;
}

/// "200,000".
const String kMaxTabletRepeatText = '200,000';

class _StepRow extends ConsumerWidget {
  const _StepRow({
    required this.segment,
    required this.step,
    required this.cell,
    required this.focused,
  });

  final int segment;
  final int step;
  final double cell;
  final bool focused;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final doc = ref.watch(tabletDocProvider);
    if (segment >= doc.turning.length || step >= doc.turning[segment].picks.length) {
      return const SizedBox.shrink();
    }
    final seg = doc.turning[segment];
    final pick = seg.picks[step];
    final first = firstPickOfSegment(doc, segment) + step;
    final label = seg.repeat > 1 ? 'Step ${step + 1}' : 'Pick $first';
    final theme = Theme.of(context);
    // Card ids to positions, worked out once per band (not once per card per row).
    final index = ref.watch(tabletCardIndexProvider);
    final flips = {
      for (final id in pick.flip)
        if (index[id] != null) index[id]!
    };
    final releases = {
      for (final id in pick.releaseTwist)
        if (index[id] != null) index[id]!
    };
    final letters = [for (var i = 0; i < doc.cards.length; i++) letterAt(pick.turns, i)];
    final events = [
      if (releases.isNotEmpty) 'release before: cards ${releases.map((i) => i + 1).join(', ')}',
      if (flips.isNotEmpty) 'flip before: cards ${flips.map((i) => i + 1).join(', ')}',
      if (pick.note != null) 'note',
    ];
    final spoken =
        '$label${seg.repeat > 1 ? ' of segment ${segment + 1}, first pick $first' : ''}: '
        '${letters.map((l) => l.isEmpty ? 'missing' : l).join(' ')}'
        '${events.isEmpty ? '' : '; ${events.join('; ')}'}';
    final edit = ref.read(tabletEditorProvider.notifier).edit;
    return Container(
      decoration: BoxDecoration(
        color: focused ? theme.colorScheme.primaryContainer : null,
        border: Border(bottom: BorderSide(color: theme.colorScheme.outlineVariant, width: 0.5)),
      ),
      child: Row(children: [
        SizedBox(
          width: _labelWidth,
          child: Padding(
            padding: const EdgeInsets.only(left: 8),
            child: Row(children: [
              Flexible(
                child: ExcludeSemantics(
                  child: Text(label,
                      style: theme.textTheme.labelMedium, overflow: TextOverflow.ellipsis),
                ),
              ),
              if (pick.note != null)
                const Padding(
                    padding: EdgeInsets.only(left: 2),
                    child: ExcludeSemantics(child: Icon(Icons.sticky_note_2_outlined, size: 14))),
            ]),
          ),
        ),
        Semantics(
          label: spoken,
          hint: 'Use the pick actions to edit it',
          child: ExcludeSemantics(
            child: GestureDetector(
              key: ValueKey('tablet-turns-$segment-$step'),
              behavior: HitTestBehavior.opaque,
              onTapUp: (d) {
                final card = d.localPosition.dx ~/ cell;
                if (card < 0 || card >= doc.cards.length) return;
                final now = letters[card];
                if (now == '?') {
                  showPickEditor(context, ref, segment, step, focusCard: card);
                  return;
                }
                final i = kTurnCycle.indexOf(now);
                final next = kTurnCycle[(i + 1) % kTurnCycle.length];
                edit((dd) => setTurn(dd, segment, step, card, next));
              },
              onLongPressStart: (d) {
                final card = d.localPosition.dx ~/ cell;
                if (card < 0 || card >= doc.cards.length) return;
                _cellSheet(context, ref, segment, step, card);
              },
              child: CustomPaint(
                size: Size(doc.cards.length * cell, cell),
                painter: _TurnsPainter(
                  letters: letters,
                  flips: flips,
                  releases: releases,
                  cell: cell,
                  ink: theme.colorScheme.onSurface,
                  muted: theme.colorScheme.outline,
                  line: theme.colorScheme.outlineVariant,
                  backward: theme.colorScheme.secondaryContainer,
                  idle: theme.colorScheme.surfaceContainerHighest,
                  unsupported: theme.colorScheme.tertiaryContainer,
                ),
              ),
            ),
          ),
        ),
        SizedBox(
          width: _menuWidth,
          child: PopupMenuButton<String>(
            key: ValueKey('tablet-pick-menu-$segment-$step'),
            tooltip: '$label actions',
            icon: const Icon(Icons.more_vert, size: 18),
            onSelected: (v) {
              switch (v) {
                case 'edit':
                  showPickEditor(context, ref, segment, step);
                case 'F' || 'B' || 'I':
                  edit((d) =>
                      setTurns(d, segment, step, List.generate(d.cards.length, (i) => i), v));
                case 'below':
                  edit((d) => insertPick(d, segment, step));
                case 'above':
                  edit((d) => insertPick(d, segment, step + 1));
                case 'copy':
                  edit((d) =>
                      insertPick(d, segment, step + 1, pick: d.turning[segment].picks[step]));
                case 'delete':
                  edit((d) => removePick(d, segment, step));
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'edit', child: Text('Edit this pick...')),
              PopupMenuItem(value: 'F', child: Text('Every card forward')),
              PopupMenuItem(value: 'B', child: Text('Every card backward')),
              PopupMenuItem(value: 'I', child: Text('Every card idle')),
              PopupMenuItem(value: 'below', child: Text('Insert a pick below')),
              PopupMenuItem(value: 'above', child: Text('Insert a pick above')),
              PopupMenuItem(value: 'copy', child: Text('Repeat this pick above it')),
              PopupMenuItem(value: 'delete', child: Text('Delete this pick')),
            ],
          ),
        ),
      ]),
    );
  }
}

/// Every choice for one card on one written pick.
Future<void> _cellSheet(
    BuildContext context, WidgetRef ref, int segment, int step, int card) async {
  final doc = ref.read(tabletDocProvider);
  final pick = doc.turning[segment].picks[step];
  final id = doc.cards[card].id;
  final now = letterAt(pick.turns, card);
  final choice = await showModalBottomSheet<String>(
    context: context,
    builder: (ctx) => SafeArea(
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(title: Text('Card ${card + 1}')),
          for (final (v, words) in [('F', 'Forward'), ('B', 'Backward'), ('I', 'Idle')])
            ListTile(
              leading: Icon(now == v ? Icons.radio_button_checked : Icons.radio_button_unchecked),
              title: Text('$v: $words'),
              onTap: () => Navigator.pop(ctx, v),
            ),
          ListTile(
            leading: Icon(now == '?' ? Icons.radio_button_checked : Icons.radio_button_unchecked),
            title: const Text('?: something Ply does not model...'),
            subtitle: const Text('A half turn, say, in the pattern\'s own words'),
            onTap: () => Navigator.pop(ctx, '?'),
          ),
          CheckboxListTile(
            value: pick.flip.contains(id),
            onChanged: (_) => Navigator.pop(ctx, 'flip'),
            title: const Text('Flip the card before this pick'),
          ),
          CheckboxListTile(
            value: pick.releaseTwist.contains(id),
            onChanged: (_) => Navigator.pop(ctx, 'release'),
            title: const Text('Release its twist before this pick'),
          ),
        ]),
      ),
    ),
  );
  if (choice == null || !context.mounted) return;
  final edit = ref.read(tabletEditorProvider.notifier).edit;
  switch (choice) {
    case 'flip':
      edit((d) => toggleFlip(d, segment, step, card));
    case 'release':
      edit((d) => toggleRelease(d, segment, step, card));
    case '?':
      final words = await askUnsupportedWords(context, card + 1,
          initial: wordsFor(doc, segment, step, card) ?? '');
      if (words != null) edit((d) => setTurn(d, segment, step, card, '?', words: words));
    default:
      edit((d) => setTurn(d, segment, step, card, choice));
  }
}

/// Ask for the pattern's own words for a card marked `?`; null when cancelled or left blank.
Future<String?> askUnsupportedWords(BuildContext context, int card, {String initial = ''}) async {
  final controller = TextEditingController(text: initial);
  final words = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Card $card: not modelled'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('Ply does not model this, so the card\'s position, faces and twist are unknown '
            'from here. Write what the pattern says.'),
        TextField(
          key: const ValueKey('tablet-unsupported-words'),
          controller: controller,
          inputFormatters: [Utf8ByteLimit(kMaxTabletTextBytes)],
          autofocus: true,
          decoration:
              const InputDecoration(labelText: 'The pattern\'s words', hintText: 'half turn'),
        ),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            final t = controller.text.trim();
            Navigator.pop(ctx, t.isEmpty ? null : t);
          },
          child: const Text('Set'),
        ),
      ],
    ),
  );
  // Not disposed here: the dialog's closing animation still shows the field after it returns. A
  // controller holds no native resource, so the collector takes it with the dialog.
  return words;
}

class _TurnsPainter extends CustomPainter {
  _TurnsPainter({
    required this.letters,
    required this.flips,
    required this.releases,
    required this.cell,
    required this.ink,
    required this.muted,
    required this.line,
    required this.backward,
    required this.idle,
    required this.unsupported,
  });

  final List<String> letters;
  final Set<int> flips;
  final Set<int> releases;
  final double cell;
  final Color ink;
  final Color muted;
  final Color line;
  final Color backward;
  final Color idle;
  final Color unsupported;

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = line
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8;
    // One laid-out letter per kind of cell, shared by every cell of the row.
    final painters = <String, TextPainter>{};
    TextPainter letter(String l) => painters.putIfAbsent(
        l,
        () => TextPainter(
              text: TextSpan(
                text: l.isEmpty ? '-' : l,
                style: TextStyle(
                  color: l == 'I' ? muted : ink,
                  fontSize: cell * 0.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              textDirection: TextDirection.ltr,
            )..layout());
    for (var i = 0; i < letters.length; i++) {
      final r = Rect.fromLTWH(i * cell, 0, cell, cell);
      final l = letters[i];
      final fill = switch (l) {
        'B' => backward,
        'I' => idle,
        '?' => unsupported,
        _ => null,
      };
      if (fill != null) canvas.drawRect(r.deflate(1), Paint()..color = fill);
      canvas.drawRect(r, grid);
      final tp = letter(l);
      tp.paint(canvas, r.center - Offset(tp.width / 2, tp.height / 2));
      // Events before the pick, along the cell's foot: a dashed line for a flip, dots for a release.
      final foot = r.bottom - 2;
      final mark = Paint()
        ..color = ink
        ..strokeWidth = 2.5;
      if (flips.contains(i)) {
        for (var x = r.left + 2; x < r.right - 2; x += 7) {
          canvas.drawLine(Offset(x, foot), Offset(math.min(x + 4, r.right - 2), foot), mark);
        }
      }
      if (releases.contains(i)) {
        for (var x = r.left + 3; x < r.right - 2; x += 5) {
          canvas.drawCircle(Offset(x, foot - 4), 1.3, Paint()..color = ink);
        }
      }
    }
    for (final tp in painters.values) {
      tp.dispose();
    }
  }

  @override
  bool shouldRepaint(covariant _TurnsPainter old) =>
      old.letters.join() != letters.join() ||
      old.flips.length != flips.length ||
      !old.flips.containsAll(flips) ||
      old.releases.length != releases.length ||
      !old.releases.containsAll(releases) ||
      old.cell != cell ||
      old.ink != ink;
}

/// The full editor for one written pick: every card's action (F, B, I, or ? with the pattern's
/// words), flips and releases before it, whole packs at once, and a note. One undo entry.
Future<void> showPickEditor(BuildContext context, WidgetRef ref, int segment, int step,
    {int? focusCard}) async {
  final doc = ref.read(tabletDocProvider);
  final result = await Navigator.of(context).push<TabletPickDto>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => _PickEditor(doc: doc, segment: segment, step: step, focusCard: focusCard),
    ),
  );
  if (result == null) return;
  ref.read(tabletEditorProvider.notifier).edit((d) {
    if (segment >= d.turning.length || step >= d.turning[segment].picks.length) return d;
    final seg = d.turning[segment];
    final picks = [...seg.picks]..[step] = result;
    return copyDoc(d,
        turning: [...d.turning]..[segment] = TabletSegmentDto(repeat: seg.repeat, picks: picks));
  });
}

class _PickEditor extends StatefulWidget {
  const _PickEditor({required this.doc, required this.segment, required this.step, this.focusCard});
  final TabletDocumentDto doc;
  final int segment;
  final int step;
  final int? focusCard;

  @override
  State<_PickEditor> createState() => _PickEditorState();
}

class _PickEditorState extends State<_PickEditor> {
  late List<String> _letters;
  late Map<int, TextEditingController> _words;
  late Set<int> _flip;
  late Set<int> _release;
  late TextEditingController _note;
  TabletNoteKind _noteKind = TabletNoteKind.other;

  TabletDocumentDto get doc => widget.doc;
  TabletPickDto get pick => doc.turning[widget.segment].picks[widget.step];

  @override
  void initState() {
    super.initState();
    final ids = [for (final c in doc.cards) c.id];
    _letters = [for (var i = 0; i < ids.length; i++) letterAt(pick.turns, i)];
    _words = {
      for (var i = 0; i < ids.length; i++)
        i: TextEditingController(text: wordsFor(doc, widget.segment, widget.step, i) ?? ''),
    };
    _flip = {
      for (var i = 0; i < ids.length; i++)
        if (pick.flip.contains(ids[i])) i
    };
    _release = {
      for (var i = 0; i < ids.length; i++)
        if (pick.releaseTwist.contains(ids[i])) i
    };
    _note = TextEditingController(text: pick.note?.text ?? '');
    _noteKind = pick.note?.kind ?? TabletNoteKind.other;
  }

  @override
  void dispose() {
    for (final c in _words.values) {
      c.dispose();
    }
    _note.dispose();
    super.dispose();
  }

  String? get _problem {
    for (var i = 0; i < _letters.length; i++) {
      if (_letters[i] == '?' && _words[i]!.text.trim().isEmpty) {
        return 'Card ${i + 1} is marked ? : write the pattern\'s words for it.';
      }
    }
    return null;
  }

  TabletPickDto _result() {
    final ids = [for (final c in doc.cards) c.id];
    final words = <TabletWordsDto>[
      for (var i = 0; i < ids.length; i++)
        if (_letters[i] == '?') TabletWordsDto(card: ids[i], text: _words[i]!.text.trim()),
    ]..sort((a, b) => a.card.compareTo(b.card));
    final noteText = _note.text.trim();
    return TabletPickDto(
      turns: [for (final l in _letters) l.isEmpty ? 'I' : l].join(),
      releaseTwist: [
        for (var i = 0; i < ids.length; i++)
          if (_release.contains(i)) ids[i]
      ],
      flip: [
        for (var i = 0; i < ids.length; i++)
          if (_flip.contains(i)) ids[i]
      ],
      unsupported: words,
      note: noteText.isEmpty ? null : TabletNoteDto(kind: _noteKind, text: noteText),
      weft: pick.weft,
    );
  }

  @override
  Widget build(BuildContext context) {
    final seg = doc.turning[widget.segment];
    final first = firstPickOfSegment(doc, widget.segment) + widget.step;
    final title =
        seg.repeat > 1 ? 'Segment ${widget.segment + 1}, step ${widget.step + 1}' : 'Pick $first';
    final problem = _problem;
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          TextButton(
            key: const ValueKey('tablet-pick-done'),
            onPressed: problem == null ? () => Navigator.pop(context, _result()) : null,
            child: const Text('Done'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          if (problem != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(problem, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          if (seg.repeat > 1)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text('Worked ${seg.repeat} times: picks $first, '
                  '${first + seg.picks.length}, and so on. Flips and releases happen every time.'),
            ),
          if (doc.packs.isNotEmpty) ...[
            const ListTile(title: Text('Whole packs')),
            for (var p = 0; p < doc.packs.length; p++)
              ListTile(
                title: Text(doc.packs[p].name.isEmpty ? 'Pack ${p + 1}' : doc.packs[p].name),
                trailing: Wrap(spacing: 4, children: [
                  for (final l in kTurnCycle)
                    OutlinedButton(
                      onPressed: () => setState(() {
                        for (final c in packCards(doc, p)) {
                          _letters[c] = l;
                        }
                      }),
                      child: Text(l),
                    ),
                ]),
              ),
            const Divider(),
          ],
          for (var i = 0; i < doc.cards.length; i++)
            _cardRow(context, i, highlighted: i == widget.focusCard),
          const Divider(),
          ListTile(
            title: const Text('Note on this pick'),
            subtitle: const Text('Something Ply does not draw, such as a brocade weft or beads.'),
            trailing: DropdownButton<TabletNoteKind>(
              value: _noteKind,
              onChanged: (k) => setState(() => _noteKind = k ?? _noteKind),
              items: const [
                DropdownMenuItem(value: TabletNoteKind.other, child: Text('Other')),
                DropdownMenuItem(value: TabletNoteKind.brocade, child: Text('Brocade')),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              controller: _note,
              inputFormatters: [Utf8ByteLimit(kMaxTabletTextBytes)],
              decoration: const InputDecoration(labelText: 'Note (leave empty for none)'),
              maxLines: 2,
            ),
          ),
        ],
      ),
    );
  }

  Widget _cardRow(BuildContext context, int i, {required bool highlighted}) {
    return Container(
      color: highlighted ? Theme.of(context).colorScheme.primaryContainer : null,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          SizedBox(width: 64, child: Text('Card ${i + 1}')),
          Expanded(
            child: SegmentedButton<String>(
              key: ValueKey('tablet-pick-card-$i'),
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: 'F', label: Text('F'), tooltip: 'Forward'),
                ButtonSegment(value: 'B', label: Text('B'), tooltip: 'Backward'),
                ButtonSegment(value: 'I', label: Text('I'), tooltip: 'Idle'),
                ButtonSegment(value: '?', label: Text('?'), tooltip: 'Not modelled'),
              ],
              selected: {if (_letters[i].isNotEmpty) _letters[i]},
              emptySelectionAllowed: true,
              onSelectionChanged: (s) => setState(() => _letters[i] = s.isEmpty ? 'I' : s.first),
            ),
          ),
        ]),
        if (_letters[i] == '?')
          TextField(
            controller: _words[i],
            inputFormatters: [Utf8ByteLimit(kMaxTabletTextBytes)],
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(labelText: 'The pattern\'s words', isDense: true),
          ),
        Wrap(spacing: 8, children: [
          FilterChip(
            label: const Text('Flip before'),
            selected: _flip.contains(i),
            onSelected: (on) => setState(() => on ? _flip.add(i) : _flip.remove(i)),
          ),
          FilterChip(
            label: const Text('Release twist before'),
            selected: _release.contains(i),
            onSelected: (on) => setState(() => on ? _release.add(i) : _release.remove(i)),
          ),
        ]),
      ]),
    );
  }
}
