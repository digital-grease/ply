// Weave a draft pick by pick (ADR 0023): the pick you are on and what to press or lift for it, Next
// when it is woven, Previous to correct, Go to, Undo, notes pinned to a pick and the log. The place
// is written at once to the project's own progress record (never to the draft), so closing the app
// at any pick resumes there, offline.

import 'dart:math' as math;

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/library_backup.dart' show BackupCraft;
import '../data/progress_repository.dart' show ProgressStatus;
import '../data/work_repository.dart';
import '../models/progress.dart';
import '../rust/dto.dart' show DraftDto;
import '../rust/progress_dto.dart';
import '../state/progress_controller.dart';
import '../widgets/progress_panels.dart';

/// The editor menu entry and the screen's title.
const String kWeaveTrackerTitle = 'Weave pick by pick';

/// "pick 12", or "pick 12, time 2" past the first time through the draft.
String weavePlaceWords(WorkPlace place) {
  if (place is! PickPlace) return '';
  return place.repeat > 1 ? 'pick ${place.pick}, time ${place.repeat}' : 'pick ${place.pick}';
}

String _pickCount(int n) => n == 1 ? '1 pick' : '$n picks';

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

class _WeaveTrackerScreenState extends ConsumerState<WeaveTrackerScreen> {
  bool _loading = true;
  String? _problem;
  bool _canStartAgain = false;
  ProgressController? _c;
  WeaveWorkDto? _window;

  /// The time through the draft [_window] was worked out for (a shuttle's side and pick 1's shed
  /// depend on it).
  int _windowTime = 1;
  int _picks = 0;
  String? _message;
  bool _needsLook = false;
  bool _busy = false;

  WorkRepository get _work => ref.read(workRepositoryProvider);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(m)));
  }

  WeaveWorkPickDto? _step(int pick) => _window?.steps.firstWhereOrNull((s) => s.pick == pick);

  /// Make sure the window holds [pick] of the [time]-th time through and a few picks after it. The
  /// window starts at [pick], so the engine always returns it.
  Future<void> _ensure(int pick, int time) async {
    final ahead = math.min(pick + 5, _picks);
    if (_window != null && _windowTime == time && _step(pick) != null && _step(ahead) != null) {
      return;
    }
    final w = await _work.weaveWindow(widget.draft, pick, pick + 30, time);
    _window = w;
    _windowTime = time;
    _picks = w.picks;
  }

  /// Where the stored place in [progress] is shown in the draft as it is now (the engine's resume,
  /// as on opening), with the window for it: the place shown, the sentence, and whether the weaver
  /// must check it.
  Future<({PickPlace shown, String? message, bool needsLook})> _resolve(Progress progress) async {
    final stored = progress.place is PickPlace ? progress.place as PickPlace : null;
    if (stored == null) {
      await _ensure(1, 1);
      return (shown: const PickPlace(1), message: null, needsLook: false);
    }
    final r = await _work.weaveResume(
      widget.draft,
      WeavePlaceDto(
        pick: stored.pick,
        picks: progress.basis?.units ?? 0,
        prefix: progress.basis?.prefix ?? '',
      ),
    );
    final shown = PickPlace(r.unit + 1, repeat: stored.repeat);
    await _ensure(shown.pick, shown.repeat);
    return (
      shown: shown,
      message: r.message,
      needsLook: r.status == WorkResumeKind.changed || r.status == WorkResumeKind.clamped,
    );
  }

  PlaceBasis? _basisOf(int pick) {
    final s = _step(pick);
    return s == null ? null : PlaceBasis(units: _picks, prefix: s.prefix);
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _problem = null;
      _canStartAgain = false;
    });
    final repo = ref.read(progressRepositoryProvider);
    try {
      final load = await repo.load(BackupCraft.weaving, widget.projectId);
      switch (load.status) {
        case ProgressStatus.newer:
          _problem = const ProgressFileException(ProgressProblem.newerVersion).message;
        case ProgressStatus.unreadable:
          _problem = const ProgressFileException(ProgressProblem.unreadable).message;
          _canStartAgain = true;
        case ProgressStatus.none:
        case ProgressStatus.ok:
          break;
      }
      if (_problem != null) {
        if (mounted) setState(() => _loading = false);
        return;
      }
      final progress = load.progress ?? const Progress(craft: ProgressCraft.weaving);
      final res = await _resolve(progress);
      final message = res.message;
      final needsLook = res.needsLook;
      final c = ProgressController(
        repository: repo,
        craft: BackupCraft.weaving,
        id: widget.projectId,
        progress: progress,
        place: res.shown,
        basis: _basisOf(res.shown.pick),
        pendingCheck: needsLook,
        clock: ref.read(progressClockProvider),
      );
      c.addListener(_changed);
      if (!mounted) {
        c.dispose();
        return;
      }
      setState(() {
        _c?.dispose();
        _c = c;
        _message = message;
        _needsLook = needsLook;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _problem = 'Could not work out this draft\'s picks: $e';
        _loading = false;
      });
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _startAgain() async {
    try {
      await ref.read(progressRepositoryProvider).setAside(BackupCraft.weaving, widget.projectId);
    } on ProgressFileException catch (e) {
      _snack(e.message);
      return;
    }
    if (!mounted) return;
    await _load();
  }

  Future<void> _go(PickPlace to, LogKind kind) async {
    final c = _c;
    if (c == null || _busy) return;
    setState(() => _busy = true);
    try {
      await _ensure(to.pick, to.repeat);
      final basis = _basisOf(to.pick);
      if (basis == null) {
        // Never store a place the engine could not work out.
        _snack(
            'Ply could not work out pick ${to.pick} of this draft, so your place was not moved.');
        return;
      }
      await c.moveTo(to, basis, kind);
      _message = null;
      _needsLook = false;
    } catch (e) {
      _snack('Could not move to ${weavePlaceWords(to)}: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  PickPlace? _nextOf(PickPlace p) {
    if (_picks == 0) return null;
    if (p.pick < _picks) return PickPlace(p.pick + 1, repeat: p.repeat);
    if (p.repeat >= ProgressLimits.maxNumber) return null;
    return PickPlace(1, repeat: p.repeat + 1);
  }

  PickPlace? _previousOf(PickPlace p) {
    if (p.pick > 1) return PickPlace(math.min(p.pick - 1, _picks), repeat: p.repeat);
    if (p.repeat > 1) return PickPlace(_picks, repeat: p.repeat - 1);
    return null;
  }

  Future<void> _accept() async {
    await _c?.accept();
    if (!mounted) return;
    setState(() {
      _message = null;
      _needsLook = false;
    });
  }

  Future<void> _undo() async {
    final c = _c;
    if (c == null || _busy) return;
    setState(() => _busy = true);
    try {
      if (await c.undo(start: const PickPlace(1))) {
        // The place undone to is checked against the draft again, as on opening: one the draft
        // changed under is shown for checking, never as if nothing happened.
        final res = await _resolve(c.progress);
        if (!mounted) return;
        c.settle(shown: res.shown, basis: _basisOf(res.shown.pick), check: res.needsLook);
        _message = res.message;
        _needsLook = res.needsLook;
        if (!res.needsLook) _snack('Back at ${weavePlaceWords(res.shown)}.');
      }
    } catch (e) {
      _snack('Could not undo: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _goTo() async {
    final c = _c;
    if (c == null || _picks == 0) return;
    final cur = c.place as PickPlace;
    final chosen = await showDialog<PickPlace>(
      context: context,
      builder: (_) =>
          _GoToPickDialog(picks: _picks, pick: math.min(cur.pick, _picks), time: cur.repeat),
    );
    if (!mounted || chosen == null || chosen.sameSpot(c.place)) return;
    await _go(chosen, LogKind.jump);
  }

  Future<void> _clear() async {
    final c = _c;
    if (c == null || !await confirmClearProgress(context)) return;
    try {
      await _ensure(1, 1);
      await c.clear(start: const PickPlace(1), basis: _basisOf(1));
      if (!mounted) return;
      setState(() {
        _message = null;
        _needsLook = false;
      });
      _snack('Your place and notes for this draft were cleared.');
    } catch (e) {
      _snack('Could not clear your place: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    return Scaffold(
      appBar: AppBar(
        title: const Text(kWeaveTrackerTitle),
        actions: c == null
            ? null
            : [
                IconButton(
                  key: const ValueKey('tracker-undo'),
                  tooltip: 'Undo',
                  onPressed: c.canUndo && !_busy ? _undo : null,
                  icon: const Icon(Icons.undo),
                ),
                IconButton(
                  key: const ValueKey('tracker-goto'),
                  tooltip: 'Go to a pick',
                  onPressed: _picks == 0 ? null : _goTo,
                  icon: const Icon(Icons.pin_outlined),
                ),
                PopupMenuButton<String>(
                  tooltip: 'More',
                  onSelected: (a) => switch (a) {
                    'notes' => showProgressNotes(context, c, weavePlaceWords),
                    'log' => showProgressLog(context, c.progress, weavePlaceWords, _pickCount),
                    _ => _clear(),
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'notes', child: Text('Notes')),
                    PopupMenuItem(value: 'log', child: Text('Log')),
                    PopupMenuItem(value: 'clear', child: Text('Clear my place')),
                  ],
                ),
              ],
      ),
      body: _body(),
      bottomNavigationBar: c == null || _picks == 0
          ? null
          : TrackerControls(
              onPrevious: _busy || _previousOf(c.place as PickPlace) == null
                  ? null
                  : () => _go(_previousOf(c.place as PickPlace)!, LogKind.back),
              onNext: _busy || _nextOf(c.place as PickPlace) == null
                  ? null
                  : () => _go(_nextOf(c.place as PickPlace)!, LogKind.worked),
              nextLabel: 'Woven, next pick',
            ),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_problem != null) {
      return TrackerRecordProblem(
          message: _problem!, onStartAgain: _canStartAgain ? _startAgain : null);
    }
    final c = _c!;
    final text = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    if (_picks == 0) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('This draft has no picks to weave.', textAlign: TextAlign.center),
        ),
      );
    }
    final place = c.place as PickPlace;
    final pick = math.min(place.pick, _picks);
    final step = _step(pick);
    final coming = <WeaveWorkPickDto>[
      for (var k = pick + 1; k <= math.min(pick + 4, _picks); k++)
        if (_step(k) != null) _step(k)!,
    ];
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        Text(widget.name, style: text.titleSmall?.copyWith(color: cs.onSurfaceVariant)),
        if (_message != null) ...[
          const SizedBox(height: 8),
          TrackerBanner(
            message: _message!,
            needsLook: _needsLook && c.pendingCheck,
            onRight: _needsLook && c.pendingCheck ? _accept : null,
            onGoTo: _needsLook && c.pendingCheck ? _goTo : null,
            onDismiss: _needsLook && c.pendingCheck ? null : () => setState(() => _message = null),
          ),
        ],
        if (widget.unsavedEdits)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'You have unsaved changes to this draft. Your place follows the draft as it is on '
              'screen.',
              style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
          ),
        if (c.saveError != null) SaveErrorLine(c.saveError!),
        const SizedBox(height: 16),
        Semantics(
          header: true,
          child: Text('Pick $pick', key: const ValueKey('tracker-place'), style: text.displaySmall),
        ),
        Text(
          [
            'of $_picks',
            if (place.repeat > 1) 'time ${place.repeat} through the draft',
          ].join(', '),
          style: text.titleMedium?.copyWith(color: cs.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        if (step == null)
          Text(_busy ? 'Working out this pick…' : 'Ply could not work out this pick of the draft.')
        else ...[
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
        ],
        const SizedBox(height: 12),
        NotesHere(controller: c),
        if (coming.isNotEmpty || pick + 4 >= _picks) ...[
          const Divider(height: 24),
          Text('Coming up', style: text.labelLarge),
          for (final s in coming)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('Pick ${s.pick}: ${s.action}', style: text.bodySmall),
            ),
          if (pick + 4 >= _picks)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('Then start again at pick 1.', style: text.bodySmall),
            ),
        ],
      ],
    );
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

/// Go to a pick: the pick and the time through the draft. The dialog owns its fields.
class _GoToPickDialog extends StatefulWidget {
  const _GoToPickDialog({required this.picks, required this.pick, required this.time});

  final int picks;
  final int pick;
  final int time;

  @override
  State<_GoToPickDialog> createState() => _GoToPickDialogState();
}

class _GoToPickDialogState extends State<_GoToPickDialog> {
  late final TextEditingController _pick = TextEditingController(text: '${widget.pick}');
  late final TextEditingController _time = TextEditingController(text: '${widget.time}');
  String? _error;

  @override
  void dispose() {
    _pick.dispose();
    _time.dispose();
    super.dispose();
  }

  void _go() {
    final pick = int.tryParse(_pick.text);
    final time = int.tryParse(_time.text);
    if (pick == null || pick < 1 || pick > widget.picks) {
      setState(() => _error = 'Give a pick from 1 to ${widget.picks}.');
      return;
    }
    if (time == null || time < 1 || time > ProgressLimits.maxNumber) {
      setState(() => _error = 'Give the time through the draft, from 1.');
      return;
    }
    Navigator.of(context).pop(PickPlace(pick, repeat: time));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Go to a pick'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const ValueKey('tracker-goto-pick'),
              controller: _pick,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(labelText: 'Pick (1 to ${widget.picks})'),
            ),
            TextField(
              key: const ValueKey('tracker-goto-time'),
              controller: _time,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(labelText: 'Time through the draft'),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
          FilledButton(
            key: const ValueKey('tracker-goto-confirm'),
            onPressed: _go,
            child: const Text('Go'),
          ),
        ],
      );
}
