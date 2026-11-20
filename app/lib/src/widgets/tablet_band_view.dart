// The Band tab of the tablet weaving editor (M10-02, ADR 0018 section 8): the band chart as the
// engine draws it, pick 1 at the BOTTOM and the newest pick at the top (as the weaver sees the band
// grow away from them, unlike Ply's shaft drafts), the top face with card 1 at the left or the back
// (the band turned over sideways) with card 1 at the right; and a stepper that walks the picks one at
// a time and shows every card's turn, position, threading, faces and twist at that pick. A long band
// is shown a page of picks at a time, each page resumed from the engine's nearest checkpoint.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/tablet_band.dart';
import '../rust/tablet_dto.dart';
import '../state/tablet_editor_providers.dart';
import 'tablet_widgets.dart';

/// Said next to the band chart (ADR 0018 Consequences: Help and the views say where pick 1 is).
const String kTabletChartOrientation =
    'Pick 1 is at the bottom and the newest pick at the top, nearest the cards, as the band grows '
    'away from you (Ply\'s shaft weaving drafts put pick 1 at the top). The back is the band turned '
    'over sideways: card 1 at the right.';

class TabletBandView extends ConsumerWidget {
  const TabletBandView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final doc = ref.watch(tabletDocProvider);
    final report = ref.watch(tabletReportProvider).valueOrNull;
    final total = expandedPicks(doc);
    final hasErrors = (report?.errors ?? 0) > 0;
    final pending = report?.reviewPending ?? true;
    if (doc.cards.isEmpty || total == 0) {
      return const _Message('Add cards and picks to see the band.');
    }
    if (hasErrors) {
      return _Message(
        'This band has errors, so Ply cannot work out its faces yet.',
        action: TextButton(
          onPressed: () => ref.read(tabletTabProvider.notifier).state = TabletEditorTab.checks,
          child: const Text('Show the checks'),
        ),
      );
    }
    // The whole tab scrolls, so a short (landscape) or large-text screen never overflows; the
    // chart takes what is left of the screen, at least a readable minimum, and the card strip
    // grows with the text size.
    return LayoutBuilder(builder: (context, box) {
      final scale = MediaQuery.textScalerOf(context).scale(1.0);
      final strip = tabletCardStripHeight(scale);
      final chart = math.max(200.0, box.maxHeight - strip - 250 * scale);
      return SingleChildScrollView(
        key: const ValueKey('tablet-band-tab'),
        child: Column(
          children: [
            TabletReviewNote(pending: pending, dense: true),
            const _Controls(),
            _SavedPlace(total: total),
            _Stepper(total: total),
            SizedBox(height: chart, child: const _Chart()),
            SizedBox(height: strip, child: const _CardStrip()),
          ],
        ),
      );
    });
  }
}

/// The card strip's height for a text scale: a tile's heading, its card diagram and seven lines.
double tabletCardStripHeight(double textScale) => 62 + 112 * textScale;

/// A simulation or render failure in words, never the raw exception.
String tabletRunFailureText(Object e) => switch (e) {
      TabletRunFailure(:final message) => message,
      _ => '$e',
    };

/// Whether [e] is the engine refusing a band with structural errors (the report says so, a moment
/// later, once it has rechecked the band).
bool _hasErrors(Object e) => e is TabletRunFailure && e.kind == TabletRunFailureKind.hasErrors;

class _Message extends StatelessWidget {
  const _Message(this.text, {this.action});
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(text, textAlign: TextAlign.center),
            if (action != null) action!,
          ]),
        ),
      );
}

class _Controls extends ConsumerWidget {
  const _Controls();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final face = ref.watch(tabletFaceProvider);
    final letters = ref.watch(tabletLettersProvider);
    final px = ref.watch(tabletCellPxProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SegmentedButton<TabletFaceKind>(
                key: const ValueKey('tablet-face'),
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: TabletFaceKind.top, label: Text('Top face')),
                  ButtonSegment(value: TabletFaceKind.back, label: Text('Back')),
                ],
                selected: {face},
                onSelectionChanged: (s) => ref.read(tabletFaceProvider.notifier).state = s.first,
              ),
              FilterChip(
                key: const ValueKey('tablet-letters'),
                label: const Text('Hole letters'),
                selected: letters,
                onSelected: (on) => ref.read(tabletLettersProvider.notifier).state = on,
              ),
              IconButton(
                tooltip: 'Smaller cells',
                icon: const Icon(Icons.zoom_out),
                onPressed: px > kTabletCellPxMin
                    ? () => ref.read(tabletCellPxProvider.notifier).state =
                        (px - 4).clamp(kTabletCellPxMin, kTabletCellPxMax)
                    : null,
              ),
              IconButton(
                tooltip: 'Larger cells',
                icon: const Icon(Icons.zoom_in),
                onPressed: px < kTabletCellPxMax
                    ? () => ref.read(tabletCellPxProvider.notifier).state =
                        (px + 4).clamp(kTabletCellPxMin, kTabletCellPxMax)
                    : null,
              ),
            ],
          ),
          Text(kTabletChartOrientation, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

/// The place "Weave pick by pick" saved for this band (ADR 0023), with a way to step to it. The
/// stepper shows the band as written: on a later time through the cards may stand otherwise (the
/// tracker shows them as they are then).
class _SavedPlace extends ConsumerWidget {
  const _SavedPlace({required this.total});
  final int total;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final place = ref.watch(tabletSavedPlaceProvider);
    if (place == null) return const SizedBox.shrink();
    final pick = ref.watch(tabletPickProvider);
    final at = place.pick.clamp(1, total);
    final text = [
      'Your place: pick ${place.pick}',
      if (place.repeat > 1) ', time ${place.repeat} through the band',
      '.',
      if (place.pick > total)
        ' The band now has $total ${total == 1 ? 'pick' : 'picks'}: Show goes to pick $at, and '
            'Weave pick by pick asks you to check your place.',
      if (place.repeat > 1) ' The stepper shows the first time through.',
    ].join();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 0),
      child: Row(children: [
        Icon(Icons.bookmark_outline, size: 18, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text,
              key: const ValueKey('tablet-saved-place'),
              style: Theme.of(context).textTheme.bodySmall),
        ),
        TextButton(
          key: const ValueKey('tablet-show-place'),
          onPressed: pick == at ? null : () => ref.read(tabletPickProvider.notifier).state = at,
          child: const Text('Show'),
        ),
      ]),
    );
  }
}

class _Stepper extends ConsumerWidget {
  const _Stepper({required this.total});
  final int total;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pick = ref.watch(tabletPickProvider).clamp(1, total);
    final doc = ref.watch(tabletDocProvider);
    void go(int p) => ref.read(tabletPickProvider.notifier).state = p.clamp(1, total);
    final place = placeOfPick(doc, pick);
    final seg = place == null ? null : doc.turning[place.segment];
    final where = place == null || seg == null
        ? ''
        : 'Segment ${place.segment + 1}, written pick ${place.step + 1}'
            '${seg.repeat > 1 ? ', time ${place.repeat + 1} of ${seg.repeat}' : ''}';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(children: [
        Row(children: [
          IconButton(
              tooltip: 'First pick',
              icon: const Icon(Icons.first_page),
              onPressed: pick > 1 ? () => go(1) : null),
          IconButton(
              key: const ValueKey('tablet-step-back'),
              tooltip: 'Previous pick',
              icon: const Icon(Icons.chevron_left),
              onPressed: pick > 1 ? () => go(pick - 1) : null),
          Expanded(
            child: Semantics(
              liveRegion: true,
              label: 'Pick $pick of $total. $where',
              child: ExcludeSemantics(
                child: Column(children: [
                  Text('Pick $pick of $total',
                      key: const ValueKey('tablet-step-label'),
                      style: Theme.of(context).textTheme.titleSmall),
                  Text(where,
                      style: Theme.of(context).textTheme.bodySmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ]),
              ),
            ),
          ),
          IconButton(
              key: const ValueKey('tablet-step-next'),
              tooltip: 'Next pick',
              icon: const Icon(Icons.chevron_right),
              onPressed: pick < total ? () => go(pick + 1) : null),
          IconButton(
              tooltip: 'Last pick',
              icon: const Icon(Icons.last_page),
              onPressed: pick < total ? () => go(total) : null),
        ]),
        if (total > 1)
          Slider(
            min: 1,
            max: total.toDouble(),
            value: pick.toDouble(),
            divisions: total > 1 && total <= 1000 ? total - 1 : null,
            label: 'Pick $pick',
            semanticFormatterCallback: (v) => 'Pick ${v.round()}',
            onChanged: (v) => go(v.round()),
          ),
      ]),
    );
  }
}

/// The page of the band chart holding the stepper's pick, with card and pick numbers; the
/// stepper's pick is framed. Tap a cell to step to its pick.
class _Chart extends ConsumerStatefulWidget {
  const _Chart();

  @override
  ConsumerState<_Chart> createState() => _ChartState();
}

class _ChartState extends ConsumerState<_Chart> {
  final _vertical = ScrollController();
  final _horizontal = ScrollController();

  /// The pick and page the chart last scrolled to: it follows the stepper when the pick changes,
  /// never on other rebuilds (an edit, a face switch), so scrolling the chart by hand sticks.
  (int, int, int)? _shown;

  @override
  void dispose() {
    _vertical.dispose();
    _horizontal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final preview = ref.watch(tabletPreviewProvider);
    final pick = ref.watch(tabletPickProvider);
    final face = ref.watch(tabletFaceProvider);
    return preview.when(
      skipLoadingOnReload: true,
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => _hasErrors(e)
          ? const _Message('Checking the band...')
          : _Message('The band could not be drawn: ${tabletRunFailureText(e)}'),
      data: (p) {
        final r = p.raster;
        final cell = r.cellPx.toDouble();
        final cards = r.cards;
        final row = (r.lastPick - pick).clamp(0, r.lastPick - r.firstPick);
        final shown = (pick, r.firstPick, r.lastPick);
        final follow = shown != _shown;
        _shown = shown;
        if (follow) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!_vertical.hasClients) return;
            final top = row * cell;
            final view = _vertical.position.viewportDimension;
            final at = _vertical.offset;
            if (top < at || top + cell > at + view) {
              _vertical.jumpTo((top - view / 2).clamp(0.0, _vertical.position.maxScrollExtent));
            }
          });
        }
        final style = Theme.of(context).textTheme.labelSmall;
        final columns = [
          for (var x = 0; x < cards; x++) face == TabletFaceKind.top ? x + 1 : cards - x
        ];
        return Scrollbar(
          controller: _horizontal,
          child: SingleChildScrollView(
            controller: _horizontal,
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: 36 + cards * cell,
              child: Column(children: [
                // Card numbers in the order the face is drawn.
                ExcludeSemantics(
                  child: Row(children: [
                    const SizedBox(width: 36),
                    for (final n in columns)
                      SizedBox(width: cell, child: Center(child: Text('$n', style: style))),
                  ]),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    controller: _vertical,
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      // Pick numbers, the newest at the top.
                      ExcludeSemantics(
                        child: SizedBox(
                          width: 36,
                          child: Column(children: [
                            for (var y = 0; y <= r.lastPick - r.firstPick; y++)
                              SizedBox(
                                height: cell,
                                child: Center(
                                  child: Text('${r.lastPick - y}',
                                      style: style?.copyWith(
                                          fontWeight:
                                              r.lastPick - y == pick ? FontWeight.bold : null)),
                                ),
                              ),
                          ]),
                        ),
                      ),
                      Semantics(
                        label: 'Band chart, ${face == TabletFaceKind.top ? 'top face' : 'back'}, '
                            'picks ${r.firstPick} to ${r.lastPick}, pick 1 at the bottom. Tap a cell '
                            'to show that pick.',
                        child: GestureDetector(
                          key: const ValueKey('tablet-band-chart'),
                          onTapUp: (d) {
                            final y = d.localPosition.dy ~/ cell;
                            final p = r.lastPick - y;
                            if (p >= r.firstPick && p <= r.lastPick) {
                              ref.read(tabletPickProvider.notifier).state = p;
                            }
                          },
                          child: Stack(children: [
                            RawImage(
                              image: p.image,
                              width: cards * cell,
                              height: (r.lastPick - r.firstPick + 1) * cell,
                              filterQuality: FilterQuality.none,
                              fit: BoxFit.fill,
                            ),
                            Positioned(
                              left: 0,
                              top: row * cell,
                              child: IgnorePointer(
                                child: Container(
                                  key: const ValueKey('tablet-current-pick'),
                                  width: cards * cell,
                                  height: cell,
                                  decoration: BoxDecoration(
                                    border: Border.all(
                                        color: Theme.of(context).colorScheme.primary, width: 2),
                                  ),
                                ),
                              ),
                            ),
                          ]),
                        ),
                      ),
                    ]),
                  ),
                ),
              ]),
            ),
          ),
        );
      },
    );
  }
}

/// Every card at the stepper's pick: its turn, position after it, threading, faces and twist.
/// The width a card tile takes in the strip (its width and margins).
const double _tileExtent = 158;

class _CardStrip extends ConsumerStatefulWidget {
  const _CardStrip();

  @override
  ConsumerState<_CardStrip> createState() => _CardStripState();
}

class _CardStripState extends ConsumerState<_CardStrip> {
  final _scroll = ScrollController();

  /// The focus last scrolled to: a check's card is brought into view once, not on every rebuild.
  TabletFocus? _shown;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final step = ref.watch(tabletStepProvider);
    final doc = ref.watch(tabletDocProvider);
    final focus = ref.watch(tabletFocusProvider);
    final focusCard = focus?.card;
    if (focus != null && !identical(focus, _shown) && focusCard != null) {
      _shown = focus;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scroll.hasClients) return;
        _scroll.jumpTo((focusCard * _tileExtent).clamp(0.0, _scroll.position.maxScrollExtent));
      });
    }
    return step.when(
      skipLoadingOnReload: true,
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => _hasErrors(e)
          ? const _Message('Checking the band...')
          : _Message('Could not work out this pick: ${tabletRunFailureText(e)}'),
      data: (s) => ListView.builder(
        key: const ValueKey('tablet-card-strip'),
        controller: _scroll,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        itemExtent: _tileExtent,
        // While a pick is worked out again after an edit, the previous result is still shown: it
        // may have more cards than the band now has (an undone insert), so only cards in both.
        itemCount: math.min(s.cards.length, doc.cards.length),
        itemBuilder: (_, i) => TabletCardTile(
          doc: doc,
          card: i,
          pick: s.pick,
          state: s.cards[i],
          highlighted: focusCard == i,
        ),
      ),
    );
  }
}

/// One card at one pick, in words and as a diagram.
class TabletCardTile extends StatelessWidget {
  const TabletCardTile({
    required this.doc,
    required this.card,
    required this.pick,
    required this.state,
    this.highlighted = false,
    super.key,
  });

  final TabletDocumentDto doc;
  final int card;
  final int pick;
  final TabletCardPickDto state;
  final bool highlighted;

  String _face(TabletFaceThreadDto f) => switch (f.kind) {
        TabletFaceThreadKind.thread => '${holeLetter(f.hole!)}, ${colorWords(doc, f.color)}',
        TabletFaceThreadKind.continued =>
          '${holeLetter(f.hole!)} carries on, ${colorWords(doc, f.color)}',
        TabletFaceThreadKind.ambiguous =>
          '${holeLetter(f.hole!)} or ${holeLetter(f.secondHole!)} (Ply cannot tell)',
        TabletFaceThreadKind.empty => '${holeLetter(f.hole!)} is empty (not modelled)',
        TabletFaceThreadKind.unknown => 'unknown',
      };

  static String _turn(TabletTurnKind t) => switch (t) {
        TabletTurnKind.forward => 'F, forward',
        TabletTurnKind.backward => 'B, backward',
        TabletTurnKind.idle => 'I, idle',
        TabletTurnKind.unsupported => '?, not modelled',
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = doc.cards[card];
    final colors = {
      for (final h in TabletHoleKind.values)
        h: () {
          final i = holeColor(c, h);
          return i == null || i >= doc.palette.length ? null : tabletColor(doc.palette[i]);
        }(),
    };
    final twist = state.twist;
    final over = twist != null && twist.abs() > doc.settings.twistWarningQuarters;
    final events = [
      if (state.released) 'twist released before',
      if (state.flipped) 'flipped before',
      if (state.reversal) 'reversal',
    ];
    // Twist before the faces: the faces' words are the longest, and the last line is the first
    // to be cut short in a narrow tile.
    final lines = <String>[
      _turn(state.turn),
      if (events.isNotEmpty) events.join(', '),
      state.position == null ? 'Position unknown' : 'Now: ${arrangementText(state.position!)}',
      state.threading == null
          ? 'Threading unknown'
          : '${threadingLetter(state.threading!)}-threaded',
      'Twist ${twistText(twist)}${twist == null ? '' : ' (${twistTurnsText(twist)})'}',
      'Top: ${_face(state.top)}',
      'Back: ${_face(state.back)}',
    ];
    final spoken = 'Card ${card + 1} at pick $pick: ${lines.join('. ')}'
        '${over ? '. More twist than the warning level' : ''}'
        '${state.position == null ? '' : '. ${arrangementWords(state.position!)}'}';
    return Semantics(
      container: true,
      label: spoken,
      child: ExcludeSemantics(
        child: Container(
          key: ValueKey('tablet-card-tile-$card'),
          width: _tileExtent - 8,
          margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            border: Border.all(
              color: highlighted ? theme.colorScheme.primary : theme.colorScheme.outlineVariant,
              width: highlighted ? 2 : 1,
            ),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text('Card ${card + 1}', style: theme.textTheme.labelLarge),
              const Spacer(),
              if (over)
                Tooltip(
                  message: 'More twist than the warning level',
                  child: Icon(Icons.warning_amber_rounded,
                      size: 16, color: severityColor(context, TabletSeverityKind.warning)),
                ),
            ]),
            Center(child: TabletCardDiagram(arrangement: state.position, colors: colors, size: 34)),
            Expanded(
              child: Text(
                lines.join('\n'),
                style: theme.textTheme.bodySmall?.copyWith(fontSize: 10.5, height: 1.2),
                overflow: TextOverflow.fade,
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
