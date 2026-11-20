// Weave a draft pick by pick (ADR 0023): the pick you are on and what to press or lift for it, Next
// when it is woven, Previous to correct, Go to, Undo, notes pinned to a pick and the log. The place
// is written at once to the project's own progress record (never to the draft), so closing the app
// at any pick resumes there, offline.

import 'dart:math' as math;

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/library_backup.dart' show BackupCraft;
import '../data/work_repository.dart';
import '../models/progress.dart';
import '../rust/dto.dart' show DraftDto;
import '../rust/progress_dto.dart';
import '../widgets/pick_tracker.dart';

/// The editor menu entry and the screen's title.
const String kWeaveTrackerTitle = 'Weave pick by pick';

/// "pick 12", or "pick 12, time 2" past the first time through the draft.
String weavePlaceWords(WorkPlace place) => pickPlaceWords(place);

class WeaveTrackerScreen extends ConsumerStatefulWidget {
  const WeaveTrackerScreen({
    required this.projectId,
    required this.draft,
    required this.name,
    this.unsavedEdits = false,
    super.key,
  });

  /// The saved draft's library id (its progress record is keyed by it).
  final String projectId;

  /// The draft as the editor has it.
  final DraftDto draft;
  final String name;

  /// The editor holds changes not yet saved (the tracker follows the draft on screen, and says so).
  final bool unsavedEdits;

  @override
  ConsumerState<WeaveTrackerScreen> createState() => _WeaveTrackerScreenState();
}

class _WeaveTrackerScreenState extends PickTrackerState<WeaveTrackerScreen> {
  WeaveWorkDto? _window;

  WorkRepository get _work => ref.read(workRepositoryProvider);

  @override
  BackupCraft get craft => BackupCraft.weaving;

  @override
  String get projectId => widget.projectId;

  @override
  String get projectName => widget.name;

  @override
  bool get unsavedEdits => widget.unsavedEdits;

  @override
  String get title => kWeaveTrackerTitle;

  @override
  String get patternWord => 'draft';

  @override
  String get noPicksText => 'This draft has no picks to weave.';

  WeaveWorkPickDto? _step(int pick) => _window?.steps.firstWhereOrNull((s) => s.pick == pick);

  @override
  Future<int> fetchWindow(int pick, int time, {bool atPick = false}) async {
    final w = await _work.weaveWindow(widget.draft, pick, pick + 30, time);
    _window = w;
    return w.picks;
  }

  @override
  bool windowHas(int pick) => _step(pick) != null;

  @override
  String? prefixAt(int pick) => _step(pick)?.prefix;

  @override
  Future<WorkResumeDto> resumeAt(PickPlace place, PlaceBasis? basis) => _work.weaveResume(
        widget.draft,
        WeavePlaceDto(
            pick: place.pick,
            repeat: place.repeat,
            picks: basis?.units ?? 0,
            prefix: basis?.prefix ?? ''),
      );

  @override
  String? comingUp(int pick) {
    final s = _step(pick);
    return s == null ? null : 'Pick ${s.pick}: ${s.action}';
  }

  @override
  List<Widget> buildPick(BuildContext context, PickPlace place, int pick) {
    final step = _step(pick)!;
    final text = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return [
      Text(step.action, key: const ValueKey('tracker-action'), style: text.titleLarge),
      if (_window!.treadled)
        _Pegs(label: 'Treadles', count: _treadlesShown(step), on: step.treadles.toSet()),
      _Pegs(label: 'Shafts up', count: widget.draft.shafts, on: step.raised.toSet()),
      if (step.weft != null)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Row(
            children: [
              Semantics(
                label: 'Weft color',
                child: Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: Color.fromARGB(255, step.weft!.r, step.weft!.g, step.weft!.b),
                    border: Border.all(color: cs.outline),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text('Weft color', style: text.bodyMedium),
            ],
          ),
        ),
      for (final n in step.notes)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(n, style: text.bodyMedium),
        ),
    ];
  }

  int _treadlesShown(WeaveWorkPickDto step) =>
      math.max(widget.draft.treadles, step.treadles.isEmpty ? 0 : step.treadles.reduce(math.max));
}

/// A row of numbered pegs, those in [on] filled (treadles pressed, shafts up). Drawn only for a loom
/// of at most 24; past that the sentence says it all.
class _Pegs extends StatelessWidget {
  const _Pegs({required this.label, required this.count, required this.on});

  final String label;
  final int count;
  final Set<int> on;

  @override
  Widget build(BuildContext context) {
    if (count < 1 || count > 24) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: text.labelMedium),
          const SizedBox(height: 4),
          ExcludeSemantics(
            child: Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                for (var i = 1; i <= count; i++)
                  Container(
                    width: 28,
                    height: 28,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: on.contains(i) ? cs.primary : null,
                      border: Border.all(color: cs.outline),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text('$i',
                        style: text.labelSmall
                            ?.copyWith(color: on.contains(i) ? cs.onPrimary : cs.onSurface)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
