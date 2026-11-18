// The Cards tab of the tablet weaving editor (M10-02, ADR 0018 sections 2, 3, 7 and 8): every
// card's thread per hole from the palette, its S or Z threading, its start position (by the two
// named presets, or any of the 8 a card can take), and the packs. The threading chart reads as
// ADR 0018 section 8 draws it: one column per card, card 1 at the left; one row per hole, A at the
// BOTTOM to D at the top, each row labelled; then the threading row and the start row (the hole at
// the near top).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/draft_doc.dart' show DraftColor;
import '../models/tablet_band.dart';
import '../rust/tablet_dto.dart';
import '../state/tablet_editor_providers.dart';
import 'name_input_dialog.dart';
import 'rgb_color_picker.dart';
import 'tablet_widgets.dart';

/// Pixels a side of one threading-chart cell (a comfortable touch target).
const double kTabletSetupCell = 40;

/// The rows of the threading chart, top to bottom: D at the top, A at the bottom.
const List<TabletHoleKind> kHoleRowsTopDown = [
  TabletHoleKind.d,
  TabletHoleKind.c,
  TabletHoleKind.b,
  TabletHoleKind.a,
];

class TabletSetupView extends ConsumerWidget {
  const TabletSetupView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final doc = ref.watch(tabletDocProvider);
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall;
    return ListView(
      key: const PageStorageKey('tablet-setup'),
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        const _Heading('Start position'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            'Cards are drawn from the weaver\'s right: the band and the weaver at the left, the far '
            'end at the right. A forward turn moves the top edge away from the weaver. Choose a start '
            'for every card here, or tap a card\'s start in the chart to set it alone.',
            style: muted,
          ),
        ),
        for (final preset in tabletPresetsInOrder) _PresetTile(preset: preset),
        const _Heading('Cards'),
        _CardCountRow(count: doc.cards.length),
        const _PaletteBar(),
        const _ThreadingChart(),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: Text(
            'Tap a hole to give it the chosen colour. S and Z name the thread\'s path through the '
            'card seen from above (an S card\'s threads run like the middle stroke of an S). The last '
            'row is the hole at the near top (NT); a * marks a card not at the start the others share.',
            style: muted,
          ),
        ),
        const _Heading('Packs'),
        const _PacksSection(),
      ],
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
        child: Semantics(
          header: true,
          child: Text(text, style: Theme.of(context).textTheme.titleMedium),
        ),
      );
}

class _PresetTile extends ConsumerWidget {
  const _PresetTile({required this.preset});
  final TabletPreset preset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final doc = ref.watch(tabletDocProvider);
    final all = doc.cards.isNotEmpty &&
        doc.cards.every((c) => sameArrangement(c.start, preset.arrangement));
    return ListTile(
      key: ValueKey('tablet-preset-${preset.name}'),
      leading: Icon(all ? Icons.radio_button_checked : Icons.radio_button_unchecked),
      title: Text(preset.label),
      subtitle: Text(preset.description),
      trailing: TabletCardDiagram(arrangement: preset.arrangement, size: 40, showForward: true),
      selected: all,
      onTap: () =>
          ref.read(tabletEditorProvider.notifier).edit((d) => setAllStarts(d, preset.arrangement)),
    );
  }
}

class _CardCountRow extends ConsumerWidget {
  const _CardCountRow({required this.count});
  final int count;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final edit = ref.read(tabletEditorProvider.notifier).edit;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Remove the last card',
            icon: const Icon(Icons.remove),
            onPressed: count > 1 ? () => edit((d) => setCardCount(d, count - 1)) : null,
          ),
          Semantics(
            liveRegion: true,
            label: '$count ${count == 1 ? 'card' : 'cards'}',
            child: ExcludeSemantics(
              child: Text('$count ${count == 1 ? 'card' : 'cards'}',
                  style: Theme.of(context).textTheme.titleSmall),
            ),
          ),
          IconButton(
            tooltip: 'Add a card at the right',
            icon: const Icon(Icons.add),
            onPressed:
                count < kMaxTabletCards ? () => edit((d) => setCardCount(d, count + 1)) : null,
          ),
          const Spacer(),
          Flexible(
            flex: 3,
            child: Text('Card 1 is at the weaver\'s left.',
                style: Theme.of(context).textTheme.bodySmall, textAlign: TextAlign.end),
          ),
          const SizedBox(width: 8),
        ],
      ),
    );
  }
}

/// The brushes: each palette colour, and an empty hole. Long-press a colour to change it.
class _PaletteBar extends ConsumerWidget {
  const _PaletteBar();

  Future<void> _editColor(BuildContext context, WidgetRef ref, int i) async {
    final doc = ref.read(tabletDocProvider);
    final c = doc.palette[i];
    final inUse = colorInUse(doc, i);
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(title: Text('Colour ${i + 1} (${tabletHex(c)})')),
          ListTile(
            leading: const Icon(Icons.palette_outlined),
            title: const Text('Change colour'),
            onTap: () => Navigator.pop(ctx, 'edit'),
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: const Text('Remove colour'),
            subtitle: inUse ? const Text('In use by a hole or the weft') : null,
            enabled: !inUse,
            onTap: () => Navigator.pop(ctx, 'remove'),
          ),
        ]),
      ),
    );
    if (!context.mounted) return;
    final edit = ref.read(tabletEditorProvider.notifier).edit;
    if (action == 'edit') {
      final picked = await showRgbColorPicker(context,
          initial: DraftColor(r: c.r, g: c.g, b: c.b), title: 'Edit colour');
      if (picked != null) {
        edit((d) => setColor(d, i, TabletColorDto(r: picked.r, g: picked.g, b: picked.b)));
      }
    } else if (action == 'remove') {
      edit((d) => removeColor(d, i));
      final brush = ref.read(tabletBrushProvider);
      if (brush != null && brush >= ref.read(tabletDocProvider).palette.length) {
        ref.read(tabletBrushProvider.notifier).state = 0;
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final doc = ref.watch(tabletDocProvider);
    final brush = ref.watch(tabletBrushProvider);
    return SizedBox(
      height: 56,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          for (var i = 0; i < doc.palette.length; i++)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Semantics(
                selected: brush == i,
                button: true,
                label: 'Paint with colour ${i + 1}, ${tabletHex(doc.palette[i])}',
                onLongPressHint: 'change or remove the colour',
                child: InkWell(
                  key: ValueKey('tablet-brush-$i'),
                  onTap: () => ref.read(tabletBrushProvider.notifier).state = i,
                  onLongPress: () => _editColor(context, ref, i),
                  child: Container(
                    width: 44,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: tabletColor(doc.palette[i]),
                      border: Border.all(
                        width: brush == i ? 3 : 1,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                    child: Text('${i + 1}',
                        style: TextStyle(color: inkOn(tabletColor(doc.palette[i])))),
                  ),
                ),
              ),
            ),
          Semantics(
            selected: brush == null,
            button: true,
            label: 'Paint an empty hole',
            child: InkWell(
              key: const ValueKey('tablet-brush-empty'),
              onTap: () => ref.read(tabletBrushProvider.notifier).state = null,
              child: Container(
                width: 44,
                decoration: BoxDecoration(
                  border: Border.all(
                      width: brush == null ? 3 : 1, color: Theme.of(context).colorScheme.primary),
                ),
                child: const ExcludeSemantics(
                    child: Center(child: TabletSwatch(color: null, size: 22))),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Add a colour',
            icon: const Icon(Icons.add_circle_outline),
            onPressed: () async {
              final picked = await showRgbColorPicker(context,
                  initial: const DraftColor(r: 179, g: 38, b: 46), title: 'Add colour');
              if (picked == null) return;
              ref
                  .read(tabletEditorProvider.notifier)
                  .edit((d) => addColor(d, TabletColorDto(r: picked.r, g: picked.g, b: picked.b)));
              ref.read(tabletBrushProvider.notifier).state =
                  ref.read(tabletDocProvider).palette.length - 1;
            },
          ),
        ],
      ),
    );
  }
}

/// The threading chart: a fixed label column, then one lazily built column per card.
class _ThreadingChart extends ConsumerStatefulWidget {
  const _ThreadingChart();

  @override
  ConsumerState<_ThreadingChart> createState() => _ThreadingChartState();
}

class _ThreadingChartState extends ConsumerState<_ThreadingChart> {
  final _scroll = ScrollController();

  /// The focus last scrolled to.
  TabletFocus? _shown;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  static const _labels = ['Card', 'D', 'C', 'B', 'A', 'S/Z', 'NT', 'Pack'];

  @override
  Widget build(BuildContext context) {
    final doc = ref.watch(tabletDocProvider);
    final focus = ref.watch(tabletFocusProvider);
    final focusCard = focus?.card;
    // Once per new focus (a check selected), never on later rebuilds: an edit must not pull the
    // chart back while the weaver scrolls it.
    if (focusCard != null && !identical(focus, _shown)) {
      _shown = focus;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          final target =
              (focusCard * kTabletSetupCell).clamp(0.0, _scroll.position.maxScrollExtent);
          _scroll.jumpTo(target);
        }
      });
    }
    final common = usualStart(doc);
    const h = kTabletSetupCell;
    return SizedBox(
      height: h * _labels.length + 8,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Row labels (letters, so the chart never relies on colour alone).
          SizedBox(
            width: 44,
            child: Column(children: [
              for (final l in _labels)
                SizedBox(
                  height: h,
                  child: Center(
                    child: Text(l,
                        style: Theme.of(context)
                            .textTheme
                            .labelMedium
                            ?.copyWith(fontWeight: FontWeight.bold)),
                  ),
                ),
            ]),
          ),
          Expanded(
            child: ListView.builder(
              key: const ValueKey('tablet-threading-chart'),
              controller: _scroll,
              scrollDirection: Axis.horizontal,
              itemCount: doc.cards.length,
              itemExtent: h,
              itemBuilder: (_, i) => _CardColumn(
                index: i,
                differs: common != null && !sameArrangement(doc.cards[i].start, common),
                focused: focusCard == i,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CardColumn extends ConsumerWidget {
  const _CardColumn({required this.index, required this.differs, required this.focused});
  final int index;
  final bool differs;
  final bool focused;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final doc = ref.watch(tabletDocProvider);
    final card = doc.cards[index];
    final theme = Theme.of(context);
    final edit = ref.read(tabletEditorProvider.notifier).edit;
    final pack = packOf(doc, index);
    final n = index + 1;
    Widget box(Widget child, {Color? color, String? label, VoidCallback? onTap, Key? key}) =>
        Semantics(
          button: onTap != null,
          label: label,
          child: InkWell(
            key: key,
            onTap: onTap,
            child: Container(
              height: kTabletSetupCell,
              decoration: BoxDecoration(
                color: color,
                border: Border.all(color: theme.colorScheme.outlineVariant, width: 0.5),
              ),
              alignment: Alignment.center,
              child: ExcludeSemantics(child: child),
            ),
          ),
        );
    return Container(
      decoration: focused
          ? BoxDecoration(border: Border.all(color: theme.colorScheme.primary, width: 2))
          : null,
      child: Column(
        children: [
          box(
            Text('$n', style: theme.textTheme.labelMedium),
            label: 'Card $n, actions',
            key: ValueKey('tablet-card-$index'),
            onTap: () => showCardActions(context, ref, index),
          ),
          for (final hole in kHoleRowsTopDown)
            () {
              final ci = holeColor(card, hole);
              final c = ci != null && ci < doc.palette.length ? tabletColor(doc.palette[ci]) : null;
              return box(
                ci == null
                    ? const TabletSwatch(color: null, size: 18)
                    : Text('${ci + 1}',
                        style: TextStyle(color: c == null ? null : inkOn(c), fontSize: 11)),
                color: c,
                label: 'Card $n, hole ${holeLetter(hole)}: ${colorWords(doc, ci)}',
                key: ValueKey('tablet-hole-$index-${holeLetter(hole)}'),
                onTap: () => edit((d) => setHole(d, index, hole, ref.read(tabletBrushProvider))),
              );
            }(),
          box(
            Text(threadingLetter(card.threading),
                style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
            label: 'Card $n, ${threadingLetter(card.threading)}-threaded; tap to change',
            key: ValueKey('tablet-threading-$index'),
            onTap: () => edit((d) => setThreading(
                d,
                index,
                card.threading == TabletThreadingKind.s
                    ? TabletThreadingKind.z
                    : TabletThreadingKind.s)),
          ),
          box(
            Text('${holeLetter(card.start.nearTop)}${differs ? '*' : ''}',
                style: theme.textTheme.titleSmall),
            label: 'Card $n starts with ${arrangementWords(card.start)}; tap to change',
            key: ValueKey('tablet-start-$index'),
            onTap: () async {
              final a = await showStartPicker(context, card.start, card: n);
              if (a != null) edit((d) => setStart(d, index, a));
            },
          ),
          box(
            Text(pack == null ? '-' : _initials(doc.packs[pack].name),
                style: theme.textTheme.labelSmall, overflow: TextOverflow.ellipsis),
            label: pack == null
                ? 'Card $n is in no pack'
                : 'Card $n is in pack ${doc.packs[pack].name}',
            onTap: () => _choosePack(context, ref, index),
          ),
        ],
      ),
    );
  }
}

String _initials(String name) {
  final t = name.trim();
  if (t.isEmpty) return '?';
  return t.length <= 4 ? t : t.substring(0, 4);
}

/// The actions for card [index]: threading, start, pack, insert, remove.
Future<void> showCardActions(BuildContext context, WidgetRef ref, int index) async {
  final doc = ref.read(tabletDocProvider);
  final card = doc.cards[index];
  final n = index + 1;
  final action = await showModalBottomSheet<String>(
    context: context,
    builder: (ctx) => SafeArea(
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            title: Text('Card $n'),
            subtitle: Text('${threadingLetter(card.threading)}-threaded; starts with '
                '${arrangementWords(card.start)}'),
            trailing: TabletCardDiagram(arrangement: card.start, size: 36),
          ),
          ListTile(
            leading: const Icon(Icons.swap_horiz),
            title: Text('Thread it ${card.threading == TabletThreadingKind.s ? 'Z' : 'S'} instead'),
            onTap: () => Navigator.pop(ctx, 'threading'),
          ),
          ListTile(
            leading: const Icon(Icons.rotate_right),
            title: const Text('Start position...'),
            onTap: () => Navigator.pop(ctx, 'start'),
          ),
          ListTile(
            leading: const Icon(Icons.group_work_outlined),
            title: const Text('Pack...'),
            onTap: () => Navigator.pop(ctx, 'pack'),
          ),
          ListTile(
            leading: const Icon(Icons.west),
            title: const Text('Insert a card to its left'),
            onTap: () => Navigator.pop(ctx, 'left'),
          ),
          ListTile(
            leading: const Icon(Icons.east),
            title: const Text('Insert a card to its right'),
            onTap: () => Navigator.pop(ctx, 'right'),
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: const Text('Remove this card'),
            enabled: doc.cards.length > 1,
            onTap: () => Navigator.pop(ctx, 'remove'),
          ),
        ]),
      ),
    ),
  );
  if (action == null || !context.mounted) return;
  final edit = ref.read(tabletEditorProvider.notifier).edit;
  switch (action) {
    case 'threading':
      edit((d) => setThreading(d, index,
          card.threading == TabletThreadingKind.s ? TabletThreadingKind.z : TabletThreadingKind.s));
    case 'start':
      final a = await showStartPicker(context, card.start, card: n);
      if (a != null) edit((d) => setStart(d, index, a));
    case 'pack':
      if (context.mounted) await _choosePack(context, ref, index);
    case 'left':
      edit((d) => insertCard(d, index));
    case 'right':
      edit((d) => insertCard(d, index + 1));
    case 'remove':
      edit((d) => removeCard(d, index));
  }
}

/// Choose one of the 8 positions a card can take: each preset, and turned 1 to 3 quarter turns
/// forward from it.
Future<TabletArrangementDto?> showStartPicker(BuildContext context, TabletArrangementDto current,
    {required int card}) {
  return showModalBottomSheet<TabletArrangementDto>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        builder: (_, scroll) => ListView(
          controller: scroll,
          children: [
            ListTile(
              title: Text('Card $card starts with'),
              subtitle:
                  const Text('Seen from the weaver\'s right: near at the left, far at the right.'),
            ),
            for (final preset in tabletPresetsInOrder)
              for (var q = 0; q < 4; q++)
                () {
                  final a = presetArrangement(preset, q);
                  return ListTile(
                    key: ValueKey('tablet-start-choice-${preset.name}-$q'),
                    selected: sameArrangement(a, current),
                    leading: TabletCardDiagram(arrangement: a, size: 36),
                    title: Text(startWords(a)),
                    subtitle: Text(arrangementWords(a)),
                    onTap: () => Navigator.pop(ctx, a),
                  );
                }(),
          ],
        ),
      ),
    ),
  );
}

Future<void> _choosePack(BuildContext context, WidgetRef ref, int card) async {
  final doc = ref.read(tabletDocProvider);
  final current = packOf(doc, card);
  final choice = await showModalBottomSheet<int>(
    context: context,
    builder: (ctx) => SafeArea(
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(title: Text('Pack of card ${card + 1}')),
          ListTile(
            leading:
                Icon(current == null ? Icons.radio_button_checked : Icons.radio_button_unchecked),
            title: const Text('No pack'),
            onTap: () => Navigator.pop(ctx, -1),
          ),
          for (var i = 0; i < doc.packs.length; i++)
            ListTile(
              leading:
                  Icon(current == i ? Icons.radio_button_checked : Icons.radio_button_unchecked),
              title: Text(doc.packs[i].name.isEmpty ? 'Pack ${i + 1}' : doc.packs[i].name),
              onTap: () => Navigator.pop(ctx, i),
            ),
          ListTile(
            leading: const Icon(Icons.add),
            title: const Text('New pack...'),
            onTap: () => Navigator.pop(ctx, -2),
          ),
        ]),
      ),
    ),
  );
  if (choice == null || !context.mounted) return;
  final edit = ref.read(tabletEditorProvider.notifier).edit;
  if (choice == -2) {
    final name = await promptForName(context,
        title: 'New pack',
        confirmLabel: 'Add',
        fieldLabel: 'Pack name',
        validator: tabletTextLimit(kMaxTabletTextBytes));
    if (name == null) return;
    edit((d) => setCardPack(addPack(d, name), card, d.packs.length));
  } else {
    edit((d) => setCardPack(d, card, choice < 0 ? null : choice));
  }
}

class _PacksSection extends ConsumerWidget {
  const _PacksSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final doc = ref.watch(tabletDocProvider);
    final edit = ref.read(tabletEditorProvider.notifier).edit;
    final muted = Theme.of(context).textTheme.bodySmall;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            'Packs are named groups of cards, for turning several together ("Left forward") and for '
            'the printed instructions. A card is in at most one pack; the turns stay per card.',
            style: muted,
          ),
        ),
        for (var i = 0; i < doc.packs.length; i++)
          ListTile(
            key: ValueKey('tablet-pack-$i'),
            title: Text(doc.packs[i].name.isEmpty ? 'Pack ${i + 1}' : doc.packs[i].name),
            subtitle: Text(_packCardsText(doc, i)),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(
                tooltip: 'Rename pack',
                icon: const Icon(Icons.drive_file_rename_outline),
                onPressed: () async {
                  final name = await promptForName(context,
                      title: 'Rename pack',
                      confirmLabel: 'Rename',
                      initial: doc.packs[i].name,
                      fieldLabel: 'Pack name',
                      validator: tabletTextLimit(kMaxTabletTextBytes));
                  if (name != null) edit((d) => renamePack(d, i, name));
                },
              ),
              IconButton(
                tooltip: 'Remove pack',
                icon: const Icon(Icons.delete_outline),
                onPressed: () => edit((d) => removePack(d, i)),
              ),
            ]),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: TextButton.icon(
            onPressed: () async {
              final name = await promptForName(context,
                  title: 'New pack',
                  confirmLabel: 'Add',
                  fieldLabel: 'Pack name',
                  validator: tabletTextLimit(kMaxTabletTextBytes));
              if (name != null) edit((d) => addPack(d, name));
            },
            icon: const Icon(Icons.add),
            label: const Text('Add a pack'),
          ),
        ),
      ],
    );
  }

  static String _packCardsText(TabletDocumentDto doc, int pack) {
    final cards = packCards(doc, pack).map((i) => i + 1).toList();
    if (cards.isEmpty) return 'No cards yet: tap a card\'s pack cell in the chart to add it.';
    return cards.length == 1 ? 'Card ${cards.first}' : 'Cards ${cards.join(', ')}';
  }
}
