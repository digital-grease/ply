// Weave a tablet weaving band pick by pick (ADR 0023, ADR 0018 section 15): the pick you are on and
// what to turn for it, how every card should be before you turn (its arrangement and twist, so you
// can check your cards) and after, Next when it is woven, Previous to correct, Go to, Undo, notes
// pinned to a pick and the log. A band is woven as many times through its turning as it needs; a
// later time through starts where the one before ended, and the engine works out the cards for it.
// The place is written at once to the band's own progress record (never to the band), so closing
// the app at any pick resumes there, offline. The editor's stepper (the Band tab) shows the place.

import 'dart:math' as math;

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/library_backup.dart' show BackupCraft;
import '../data/work_repository.dart';
import '../models/progress.dart';
import '../models/tablet_band.dart';
import '../rust/progress_dto.dart';
import '../rust/tablet_dto.dart';
import '../widgets/pick_tracker.dart';
import '../widgets/tablet_band_view.dart' show TabletCardTile, tabletCardStripHeight;
import '../widgets/tablet_widgets.dart';

/// The band editor's menu entry and the screen's title: the same words as shaft weaving's, since a
/// tablet weaver works the band pick by pick too.
const String kTabletTrackerTitle = 'Weave pick by pick';

/// Said instead of a tracker for a band with structural errors.
const String kTabletTrackerHasErrors =
    'This band has errors, so Ply cannot work out its picks. Fix them in the editor (the Checks '
    'tab lists them), then come back: your place is kept.';

/// "pick 12", or "pick 12, time 2" past the first time through the band.
String tabletPlaceWords(WorkPlace place) => pickPlaceWords(place);

/// "Segment 2, written pick 3, time 2 of 4": where a pick is written in the turning.
String tabletWrittenWhere(TabletWorkPickDto s) => 'Segment ${s.segment}, written pick ${s.step}'
    '${s.segmentRepeats > 1 ? ', time ${s.segmentRepeat} of ${s.segmentRepeats}' : ''}';

class TabletTrackerScreen extends ConsumerStatefulWidget {
  const TabletTrackerScreen({
    required this.projectId,
    required this.band,
    required this.name,
    this.unsavedEdits = false,
    super.key,
  });

  /// The saved band's library id (its progress record is keyed by it).
  final String projectId;

  /// The band as the editor has it.
  final TabletDocumentDto band;
  final String name;

  /// The editor holds changes not yet saved (the tracker follows the band on screen, and says so).
  final bool unsavedEdits;

  @override
  ConsumerState<TabletTrackerScreen> createState() => _TabletTrackerScreenState();
}

class _TabletTrackerScreenState extends PickTrackerState<TabletTrackerScreen> {
  TabletWorkDto? _window;

  /// The engine's work states (ADR 0023), by time through: every card after some pick of it (0:
  /// its start). Given back with the next window, the latest one before it saves folding the band
  /// again, so a time through is folded once per session and Next, Previous and a nearby Go to fold
  /// a few dozen picks. They are sealed for this run of the app: kept in memory for this session
  /// only, never saved or exported.
  final Map<int, _States> _states = {};

  /// The most times through whose states are kept.
  static const int _keepTimes = 4;

  /// How many picks a window starts before the pick asked for (so Previous stays in it a while),
  /// within the engine's cells per window.
  int get _lead => math.min(16, (50000 ~/ math.max(1, widget.band.cards.length)) ~/ 3);

  WorkRepository get _work => ref.read(workRepositoryProvider);

  @override
  BackupCraft get craft => BackupCraft.tabletWeaving;

  @override
  String get projectId => widget.projectId;

  @override
  String get projectName => widget.name;

  @override
  bool get unsavedEdits => widget.unsavedEdits;

  @override
  String get title => kTabletTrackerTitle;

  @override
  String get patternWord => 'band';

  @override
  String get noPicksText => 'This band has no picks to weave.';

  @override
  String describe(Object error) => switch (error) {
        TabletRunFailure(kind: TabletRunFailureKind.hasErrors) => kTabletTrackerHasErrors,
        TabletRunFailure(:final message) => message,
        _ => super.describe(error),
      };

  @override
  String failureText(Object error) => switch (error) {
        TabletRunFailure(kind: TabletRunFailureKind.hasErrors) => kTabletTrackerHasErrors,
        _ => super.failureText(error),
      };

  int get _first => _window?.steps.firstOrNull?.pick ?? 0;

  TabletWorkPickDto? _step(int pick) {
    final w = _window;
    if (w == null) return null;
    final i = pick - _first;
    return i >= 0 && i < w.steps.length ? w.steps[i] : null;
  }

  /// Every card at [pick], after its events and turn.
  List<TabletCardPickDto> _cells(int pick) {
    final w = _window!;
    final start = (pick - _first) * w.cards;
    return w.cells.sublist(start, start + w.cards);
  }

  /// Every card before [pick]: as the window starts, or as the pick before left it.
  List<TabletCardStateDto> _before(int pick) {
    if (pick == _first) return _window!.before;
    return [
      for (final c in _cells(pick - 1))
        TabletCardStateDto(
            position: c.position, threading: c.threading, twist: c.twist, woven: c.woven),
    ];
  }

  @override
  Future<int> fetchWindow(int pick, int time, {bool atPick = false}) async {
    final first = atPick ? pick : math.max(1, pick - _lead);
    final kept = _states.remove(time) ?? _States();
    _states[time] = kept;
    while (_states.length > _keepTimes) {
      _states.remove(_states.keys.first);
    }
    final w = await _work.tabletWindow(widget.band, first, pick + 30, time,
        from: kept.before(first)?.bytes);
    kept.add(w.states);
    _window = w;
    return w.picks;
  }

  @override
  bool windowHas(int pick) => _step(pick) != null;

  @override
  String? prefixAt(int pick) => _step(pick)?.prefix;

  @override
  Future<WorkResumeDto> resumeAt(PickPlace place, PlaceBasis? basis) => _work.tabletResume(
        widget.band,
        TabletPlaceDto(
            pick: place.pick,
            repeat: place.repeat,
            picks: basis?.units ?? 0,
            prefix: basis?.prefix ?? ''),
      );

  @override
  String? comingUp(int pick) {
    final s = _step(pick);
    return s == null ? null : 'Pick ${s.pick}: ${s.text}';
  }

  @override
  List<Widget> buildAbove(BuildContext context, PickPlace place) => [
        const SizedBox(height: 8),
        TabletReviewNote(pending: _window?.reviewPending ?? true, dense: true),
      ];

  @override
  List<Widget> buildPick(BuildContext context, PickPlace place, int pick) {
    final step = _step(pick)!;
    final w = _window!;
    final doc = widget.band;
    final text = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final weft = step.weft;
    final scale = MediaQuery.textScalerOf(context).scale(1.0);
    final before = _before(pick);
    final after = _cells(pick);
    return [
      Text(tabletWrittenWhere(step), style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
      if (w.startNote != null)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(w.startNote!,
              key: const ValueKey('tracker-start-note'),
              style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
        ),
      const SizedBox(height: 8),
      Text(step.text, key: const ValueKey('tracker-action'), style: text.titleLarge),
      if (step.textLeftOut)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Row(children: [
            Expanded(
              child: Text(
                  'This pick\'s note or words are long: they are shown in full on their own.',
                  style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
            ),
            TextButton(
              key: const ValueKey('tracker-full-words'),
              onPressed: reloadAtPlace,
              child: const Text('Show them'),
            ),
          ]),
        )
      else if (step.noteText != null || step.words.isNotEmpty)
        ExpansionTile(
          key: const ValueKey('tracker-own-words'),
          tilePadding: EdgeInsets.zero,
          title: Text('The pattern\'s own words, in full', style: text.labelLarge),
          children: [
            if (step.noteText != null)
              _Words(
                  label: step.noteKind == TabletNoteKind.brocade ? 'Brocade weft' : 'Note',
                  text: step.noteText!),
            for (final w in step.words) _Words(label: _capital(w.cards), text: w.text),
          ],
        ),
      if (weft != null && weft < doc.palette.length)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Row(
            children: [
              Semantics(
                label: 'Weft colour',
                child: Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: tabletColor(doc.palette[weft]),
                    border: Border.all(color: cs.outline),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text('Weft: ${colorWords(doc, weft)}', style: text.bodyMedium),
            ],
          ),
        ),
      const SizedBox(height: 16),
      Text('Check your cards before you turn', style: text.labelLarge),
      Text(
        'How each card should be now, seen from your right, and the twist behind it.',
        style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant),
      ),
      const SizedBox(height: 4),
      SizedBox(
        height: 96 + 48 * scale,
        child: ListView.builder(
          key: const ValueKey('tracker-cards-before'),
          scrollDirection: Axis.horizontal,
          itemExtent: 128,
          itemCount: math.min(w.cards, doc.cards.length),
          itemBuilder: (_, i) => _BeforeTile(doc: doc, card: i, state: before[i]),
        ),
      ),
      const SizedBox(height: 12),
      Text('After this pick', style: text.labelLarge),
      const SizedBox(height: 4),
      SizedBox(
        height: tabletCardStripHeight(scale),
        child: ListView.builder(
          key: const ValueKey('tracker-cards-after'),
          scrollDirection: Axis.horizontal,
          itemExtent: 158,
          itemCount: math.min(w.cards, doc.cards.length),
          itemBuilder: (_, i) => TabletCardTile(doc: doc, card: i, pick: pick, state: after[i]),
        ),
      ),
    ];
  }
}

/// The work states kept for one time through: its start, and one for every stretch of 32 picks
/// visited (the latest), at most 64 stretches, so a move anywhere near a place worked through
/// resumes within a few dozen picks of it.
class _States {
  TabletWorkStateDto? _start;
  final Map<int, TabletWorkStateDto> _byStretch = {};

  void add(List<TabletWorkStateDto> states) {
    for (final s in states) {
      if (s.done == 0) {
        _start = s;
        continue;
      }
      _byStretch.remove(s.done ~/ 32);
      _byStretch[s.done ~/ 32] = s;
    }
    while (_byStretch.length > 64) {
      _byStretch.remove(_byStretch.keys.first);
    }
  }

  /// The latest state before pick [first].
  TabletWorkStateDto? before(int first) {
    TabletWorkStateDto? best = _start;
    for (final s in _byStretch.values) {
      if (s.done < first && (best == null || s.done > best.done)) best = s;
    }
    return best;
  }
}

String _capital(String s) => s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

/// A label and the pattern's words in full, which can be selected and copied.
class _Words extends StatelessWidget {
  const _Words({required this.label, required this.text});

  final String label;
  final String text;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: t.labelMedium),
          SelectableText(text, style: t.bodyMedium),
        ]),
      ),
    );
  }
}

/// One card before a pick: its diagram, arrangement, threading and twist.
class _BeforeTile extends StatelessWidget {
  const _BeforeTile({required this.doc, required this.card, required this.state});

  final TabletDocumentDto doc;
  final int card;
  final TabletCardStateDto state;

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
    final p = state.position;
    final lines = [
      p == null ? 'Position unknown' : arrangementText(p),
      state.threading == null
          ? 'Threading unknown'
          : '${threadingLetter(state.threading!)}-threaded',
      'Twist ${twistText(twist)}',
    ];
    return Semantics(
      container: true,
      label: 'Card ${card + 1} now: ${p == null ? 'position unknown' : arrangementWords(p)}. '
          '${lines.skip(1).join('. ')}'
          '${twist == null ? '' : ' (${twistTurnsText(twist)})'}'
          '${over ? '. More twist than the warning level' : ''}',
      child: ExcludeSemantics(
        child: Container(
          key: ValueKey('tracker-card-before-$card'),
          margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            border: Border.all(color: theme.colorScheme.outlineVariant),
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
            Center(child: TabletCardDiagram(arrangement: p, colors: colors, size: 28)),
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
