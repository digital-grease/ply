// The pick-by-pick tracker the weaving crafts share (ADR 0023): shaft weaving ("Weave pick by pick"
// in the draft editor) and tablet weaving (the same entry in the band editor). Both keep a place of
// a pick and the time through the pattern; both ask their engine for a window of picks of one time
// through (what to do at each, and each pick's fingerprint) and for where a saved place resumes.
// This holds what they share: reading the record, resolving and checking the place, Next, Previous,
// Go to, Undo, notes, the log, Clear, and the screen around the craft's own view of a pick.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/library_backup.dart' show BackupCraft;
import '../data/progress_repository.dart';
import '../models/progress.dart';
import '../rust/progress_dto.dart' show WorkResumeDto, WorkResumeKind;
import '../state/progress_controller.dart';
import 'progress_panels.dart';

/// "pick 12", or "pick 12, time 2" past the first time through.
String pickPlaceWords(WorkPlace place) {
  if (place is! PickPlace) return '';
  return place.repeat > 1 ? 'pick ${place.pick}, time ${place.repeat}' : 'pick ${place.pick}';
}

/// "1 pick", "40 picks".
String pickCount(int n) => n == 1 ? '1 pick' : '$n picks';

/// A pick tracker's screen state. A craft gives its words, its engine's window and resume, and its
/// view of one pick; everything else is here.
abstract class PickTrackerState<T extends ConsumerStatefulWidget> extends ConsumerState<T> {
  // --- what the craft gives --------------------------------------------------------------------

  BackupCraft get craft;

  /// The saved project's library id (its progress record is keyed by it).
  String get projectId;

  /// The project's name, shown above the place.
  String get projectName;

  /// The editor holds changes not yet saved (the tracker follows the pattern on screen).
  bool get unsavedEdits;

  /// The screen's title (the editor's menu entry).
  String get title;

  /// The pattern in the craft's words: `draft`, `band`.
  String get patternWord;

  /// Said when the pattern has no picks.
  String get noPicksText;

  /// An engine or file error in words (a craft's own failure carries its sentence).
  String describe(Object error) => errorWords(error);

  /// The engine's reason the picks could not be worked out, in words.
  String failureText(Object error) =>
      'Could not work out this $patternWord\'s picks: ${describe(error)}';

  /// Ask the engine for a window of a few dozen picks of the [time]-th time through holding [pick]
  /// and a few after it, and keep it; returns the pattern's picks. It may start a little before
  /// [pick] (so Previous stays in it), but with [atPick] it starts at [pick], whose words the engine
  /// then always gives in full.
  Future<int> fetchWindow(int pick, int time, {bool atPick = false});

  /// Whether the kept window holds [pick].
  bool windowHas(int pick);

  /// The kept window's fingerprint at [pick], when it holds it.
  String? prefixAt(int pick);

  /// Where the stored [place] (saved against [basis]) resumes in the pattern as it is now.
  Future<WorkResumeDto> resumeAt(PickPlace place, PlaceBasis? basis);

  /// What to do at [pick] (of [place]'s time through), from the kept window.
  List<Widget> buildPick(BuildContext context, PickPlace place, int pick);

  /// The line for [pick] under "Coming up", when the window holds it.
  String? comingUp(int pick);

  /// Lines a craft adds above the place (none by default).
  List<Widget> buildAbove(BuildContext context, PickPlace place) => const [];

  // --- the shared tracker ----------------------------------------------------------------------

  bool _loading = true;
  String? _problem;
  bool _canStartAgain = false;

  /// The device could not read the record just now: offer to read it again. Start again is offered
  /// only once reading it again has failed too ([_triedAgain]), and then moves the file aside
  /// unread ([_asideUnread]).
  bool _canTryAgain = false;
  bool _triedAgain = false;
  bool _asideUnread = false;

  /// Reading the record again because a save met one this session never read.
  bool _reloading = false;
  ProgressController? _c;

  /// The time through the pattern the kept window was worked out for (what the cards or the
  /// shuttle do there depends on it).
  int _windowTime = 0;
  int _picks = 0;
  String? _message;
  bool _needsLook = false;
  bool _busy = false;

  /// The tracking session, once the record is read.
  ProgressController? get controller => _c;

  /// The pattern's picks.
  int get picks => _picks;

  /// The place on screen.
  PickPlace? get place => _c?.place as PickPlace?;

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

  void snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(m)));
  }

  /// Make sure the window holds [pick] of the [time]-th time through and a few picks after it.
  Future<void> _ensure(int pick, int time, {bool atPick = false}) async {
    final ahead = math.min(pick + 5, _picks);
    if (_windowTime == time && windowHas(pick) && windowHas(ahead)) return;
    _picks = await fetchWindow(pick, time, atPick: atPick);
    _windowTime = time;
  }

  /// Where the stored place in [progress] is shown in the pattern as it is now (the engine's resume,
  /// as on opening), with the window for it: the place shown, the sentence, and whether the crafter
  /// must check it.
  Future<({PickPlace shown, String? message, bool needsLook})> _resolve(Progress progress) async {
    final stored = progress.place is PickPlace ? progress.place as PickPlace : null;
    if (stored == null) {
      await _ensure(1, 1);
      return (shown: const PickPlace(1), message: null, needsLook: false);
    }
    final r = await resumeAt(stored, progress.basis);
    final shown = PickPlace(r.unit + 1, repeat: stored.repeat);
    await _ensure(shown.pick, shown.repeat);
    return (
      shown: shown,
      message: r.message,
      needsLook: r.status == WorkResumeKind.changed || r.status == WorkResumeKind.clamped,
    );
  }

  /// What [pick] of the [time]-th time through is worked against: from the kept window, only when
  /// it was worked out for that time (a place is never stored with another time's fingerprint).
  PlaceBasis? _basisOf(int pick, int time) {
    final prefix = _windowTime == time ? prefixAt(pick) : null;
    return prefix == null ? null : PlaceBasis(units: _picks, prefix: prefix);
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _problem = null;
      _canStartAgain = false;
      _canTryAgain = false;
    });
    final repo = ref.read(progressRepositoryProvider);
    try {
      final load = await repo.load(craft, projectId);
      switch (load.status) {
        case ProgressStatus.newer:
          _problem = const ProgressFileException(ProgressProblem.newerVersion).message;
        case ProgressStatus.unreadable:
          _problem = const ProgressFileException(ProgressProblem.unreadable).message;
          _canStartAgain = true;
        case ProgressStatus.failed:
          _problem = const ProgressFileException(ProgressProblem.ioFailed).message;
          _canTryAgain = true;
          _canStartAgain = _triedAgain;
        case ProgressStatus.none:
        case ProgressStatus.ok:
          break;
      }
      _asideUnread = load.status == ProgressStatus.failed;
      if (load.status != ProgressStatus.failed) _triedAgain = false;
      if (_problem != null) {
        if (mounted) setState(() => _loading = false);
        return;
      }
      final progress = load.progress ?? Progress(craft: ProgressRepository.craftOf(craft)!);
      final res = await _resolve(progress);
      final c = ProgressController(
        repository: repo,
        craft: craft,
        id: projectId,
        progress: progress,
        place: res.shown,
        basis: _basisOf(res.shown.pick, res.shown.repeat),
        pendingCheck: res.needsLook,
        clock: ref.read(progressClockProvider),
        fromRecord: load.status == ProgressStatus.ok,
      );
      c.addListener(_changed);
      if (!mounted) {
        c.dispose();
        return;
      }
      setState(() {
        _c?.dispose();
        _c = c;
        _message = res.message;
        _needsLook = res.needsLook;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _problem = failureText(e);
        _loading = false;
      });
    }
  }

  void _changed() {
    if (!mounted) return;
    if (_c?.foundAgain ?? false) {
      // A save met a record this session never read: nothing was written; show that record.
      if (_reloading) return;
      _reloading = true;
      snack(const ProgressFileException(ProgressProblem.foundAgain).message);
      Future<void>.microtask(_load).whenComplete(() => _reloading = false);
      return;
    }
    setState(() {});
  }

  /// Read the record again after the device could not read it.
  Future<void> _tryAgain() async {
    _triedAgain = true;
    await _load();
  }

  /// Ask the engine again for a window starting at the place on screen (a craft whose window left
  /// something out of a later pick uses it to show that pick in full).
  Future<void> reloadAtPlace() async {
    final p = place;
    if (p == null || _busy) return;
    setState(() => _busy = true);
    try {
      _windowTime = 0;
      await _ensure(p.pick, p.repeat, atPick: true);
    } catch (e) {
      snack(failureText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _startAgain() async {
    try {
      await ref
          .read(progressRepositoryProvider)
          .setAside(craft, projectId, evenIfNotRead: _asideUnread);
    } catch (e) {
      snack(startAgainFailedText(e));
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
      final basis = _basisOf(to.pick, to.repeat);
      if (basis == null) {
        // Never store a place the engine could not work out.
        snack('Ply could not work out pick ${to.pick} of this $patternWord, so your place was not '
            'moved.');
        return;
      }
      await c.moveTo(to, basis, kind);
      _message = null;
      _needsLook = false;
    } catch (e) {
      snack('Could not move to ${pickPlaceWords(to)}: ${describe(e)}');
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
        // The place undone to is checked against the pattern again, as on opening: one the pattern
        // changed under is shown for checking, never as if nothing happened.
        final res = await _resolve(c.progress);
        if (!mounted) return;
        c.settle(
            shown: res.shown,
            basis: _basisOf(res.shown.pick, res.shown.repeat),
            check: res.needsLook);
        _message = res.message;
        _needsLook = res.needsLook;
        if (!res.needsLook) snack('Back at ${pickPlaceWords(res.shown)}.');
      }
    } catch (e) {
      snack('Could not undo: ${describe(e)}');
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
      builder: (_) => GoToPickDialog(
          picks: _picks,
          pick: math.min(cur.pick, _picks),
          time: cur.repeat,
          timeLabel: 'Time through the $patternWord'),
    );
    if (!mounted || chosen == null || chosen.sameSpot(c.place)) return;
    await _go(chosen, LogKind.jump);
  }

  Future<void> _clear() async {
    final c = _c;
    // Never while a move is working out its window: the two would share it.
    if (c == null || _busy || !await confirmClearProgress(context)) return;
    if (_busy || !mounted) return;
    setState(() => _busy = true);
    try {
      await _ensure(1, 1);
      await c.clear(start: const PickPlace(1), basis: _basisOf(1, 1));
      if (!mounted) return;
      setState(() {
        _message = null;
        _needsLook = false;
      });
      snack('Your place and notes for this $patternWord were cleared.');
    } catch (e) {
      snack('Could not clear your place: ${describe(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
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
                    'notes' => showProgressNotes(context, c, pickPlaceWords),
                    'log' => showProgressLog(context, c.progress, pickPlaceWords, pickCount),
                    _ => _clear(),
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: 'notes', child: Text('Notes')),
                    const PopupMenuItem(value: 'log', child: Text('Log')),
                    PopupMenuItem(
                        value: 'clear', enabled: !_busy, child: const Text('Clear my place')),
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
          message: _problem!,
          onStartAgain: _canStartAgain ? _startAgain : null,
          onTryAgain: _canTryAgain ? _tryAgain : null);
    }
    final c = _c!;
    final text = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    if (_picks == 0) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(noPicksText, textAlign: TextAlign.center),
        ),
      );
    }
    final place = c.place as PickPlace;
    final pick = math.min(place.pick, _picks);
    final coming = <String>[
      for (var k = pick + 1; k <= math.min(pick + 4, _picks); k++)
        if (comingUp(k) != null) comingUp(k)!,
    ];
    return ListView(
      key: const ValueKey('tracker-body'),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        Text(projectName, style: text.titleSmall?.copyWith(color: cs.onSurfaceVariant)),
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
        if (unsavedEdits)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'You have unsaved changes to this $patternWord. Your place follows the '
              '$patternWord as it is on screen.',
              style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
          ),
        if (c.saveError != null) SaveErrorLine(c.saveError!),
        ...buildAbove(context, place),
        const SizedBox(height: 16),
        Semantics(
          header: true,
          child: Text('Pick $pick', key: const ValueKey('tracker-place'), style: text.displaySmall),
        ),
        Text(
          [
            'of $_picks',
            if (place.repeat > 1) 'time ${place.repeat} through the $patternWord',
          ].join(', '),
          style: text.titleMedium?.copyWith(color: cs.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        if (!windowHas(pick) || _windowTime != place.repeat)
          Text(_busy
              ? 'Working out this pick…'
              : 'Ply could not work out this pick of the $patternWord.')
        else
          ...buildPick(context, place, pick),
        const SizedBox(height: 12),
        NotesHere(controller: c),
        if (coming.isNotEmpty || pick + 4 >= _picks) ...[
          const Divider(height: 24),
          Text('Coming up', style: text.labelLarge),
          for (final s in coming)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(s, style: text.bodySmall),
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
}

/// Go to a pick: the pick and the time through the pattern. The dialog owns its fields.
class GoToPickDialog extends StatefulWidget {
  const GoToPickDialog({
    required this.picks,
    required this.pick,
    required this.time,
    this.timeLabel = 'Time through the draft',
    super.key,
  });

  final int picks;
  final int pick;
  final int time;

  /// The time field's label: `Time through the draft`, `Time through the band`.
  final String timeLabel;

  @override
  State<GoToPickDialog> createState() => _GoToPickDialogState();
}

class _GoToPickDialogState extends State<GoToPickDialog> {
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
      setState(() => _error = 'Give the ${widget.timeLabel.toLowerCase()}, from 1.');
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
              decoration: InputDecoration(labelText: widget.timeLabel),
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
