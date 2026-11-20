import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/library_backup.dart' show BackupCraft;
import '../data/progress_repository.dart' show ProgressStatus;
import '../data/work_repository.dart';
import '../models/nalbind_recipe.dart';
import '../models/nalbind_recipe_view.dart';
import '../models/progress.dart';
import '../rust/nalbind_recipe_dto.dart';
import '../rust/progress_dto.dart';
import '../state/nalbind_providers.dart';
import '../state/progress_controller.dart';
import '../widgets/nalbind_recipe_issues.dart';
import '../widgets/progress_panels.dart';

/// The project screen's menu entry and this screen's title (ADR 0023): the nalbinding tracker is the
/// recipe's follow view, keeping your place step by step.
const String kNalbindTrackerTitle = 'Nalbind step by step';

/// Said for a project with no recipe steps, instead of a tracker with nothing in it.
const String kNalbindNothingToTrack =
    'This project has no recipe steps to follow. Add a recipe in the Recipe section to work it step '
    'by step and keep your place.';

/// Words for nalbinding places, from the recipe as it is now.
class NalbindPlaceWords {
  const NalbindPlaceWords(this.recipe);

  final NalbindRecipe recipe;

  /// The step [place] names now: by its id when it has one (wherever the step is now; `null` when it
  /// is no longer in the recipe), else by its number.
  int? indexOf(NalbindPlace place) {
    final segments = recipe.segments;
    if (place.stepId != null) {
      final i = segments.indexWhere((s) => s.id == place.stepId);
      return i < 0 ? null : i;
    }
    return place.unit < segments.length ? place.unit : null;
  }

  /// "step 3 (Cuff)", "step 4", or "a step no longer in the recipe".
  String call(WorkPlace place) {
    if (place is! NalbindPlace) return '';
    final i = indexOf(place);
    if (i == null) return 'a step no longer in the recipe';
    final title = recipe.segments[i].title.trim();
    return title.isEmpty ? 'step ${i + 1}' : 'step ${i + 1} ($title)';
  }

  /// "1 step", "3 steps".
  static String units(int n) => n == 1 ? '1 step' : '$n steps';
}

/// FOLLOW a nalbinding recipe (ADR 0017), which is also nalbinding's progress tracker (ADR 0023):
/// one step at a time in working order, with its written instruction, stitch, count, target, notes
/// and caution, whether Ply checked it and anything it found, and a Done tick.
///
/// Ticks go through [onTick] (the project screen writes them to the saved project at once); the
/// message it resolves to, if any, is shown. For a saved project ([projectId]) the step you are on
/// is your place: kept at once in the project's own progress record (never in the `.plynal`), with
/// a log, notes pinned to a step, Undo and Clear, and resumed on the step by its id the next time.
/// Without a record yet, it opens at the first step not yet done. The ticks are the record of the
/// steps worked; the place never writes them.
class NalbindFollowScreen extends ConsumerStatefulWidget {
  const NalbindFollowScreen({
    required this.recipe,
    required this.projectNotation,
    required this.projectStitchName,
    required this.onTick,
    this.projectId,
    this.unsavedEdits = false,
    super.key,
  });

  final NalbindRecipe recipe;
  final String projectNotation;
  final String projectStitchName;
  final Future<String?> Function(String segmentId, bool done) onTick;

  /// The saved project's library id, which its place is kept under; `null` for a project not saved
  /// yet (the view then walks the steps without keeping a place).
  final String? projectId;

  /// The project holds changes not yet saved (the place follows the recipe as it is on screen).
  final bool unsavedEdits;

  @override
  ConsumerState<NalbindFollowScreen> createState() => _NalbindFollowScreenState();
}

class _NalbindFollowScreenState extends ConsumerState<NalbindFollowScreen> {
  late NalbindRecipe _recipe = widget.recipe;
  late int _index = _firstOpen(widget.recipe);
  RecipeReportDto? _report;
  String? _error;
  bool _ticking = false;

  // --- the place (ADR 0023) ---
  ProgressController? _c;
  NalbindWorkDto? _work;

  /// Why the place is not kept (a newer or unreadable record, or the engine failed), when it is not.
  String? _trackProblem;
  bool _canStartAgain = false;

  /// The device could not read the record just now: offer to read it again. Start again is offered
  /// only once reading it again has failed too ([_triedAgain]), and then moves the file aside
  /// unread ([_asideUnread]).
  bool _canTryAgain = false;
  bool _triedAgain = false;
  bool _asideUnread = false;

  /// Reading the record again because a save met one this session never read.
  bool _reloading = false;
  String? _message;
  bool _needsLook = false;
  bool _busy = false;

  /// Whether the maker can move: at once for a project not saved yet, and for a saved one once its
  /// place is read (or could not be), so a move is never taken back by the place read after it.
  bool get _ready =>
      widget.projectId == null || _recipe.segments.isEmpty || _c != null || _trackProblem != null;

  static int _firstOpen(NalbindRecipe r) {
    final i = r.segments.indexWhere((s) => !r.done.contains(s.id));
    return i < 0 ? 0 : i;
  }

  @override
  void initState() {
    super.initState();
    _load();
    _track();
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

  Future<void> _load() async {
    try {
      final report = await ref
          .read(nalbindRepositoryProvider)
          .checkRecipe(_recipe, projectNotation: widget.projectNotation);
      if (mounted) setState(() => _report = report);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not check the recipe: $e');
    }
  }

  // --- the place --------------------------------------------------------------------------------

  NalbindPlace _placeOf(int i) => NalbindPlace(i, stepId: _recipe.segments[i].id);

  PlaceBasis? _basisOf(int i) {
    final steps = _work?.steps;
    if (steps == null || i < 0 || i >= steps.length) return null;
    return PlaceBasis(units: steps.length, prefix: steps[i].prefix);
  }

  WorkRepository get _engine => ref.read(workRepositoryProvider);

  /// Where the stored place in [progress] is shown in the recipe as it is now (the engine's resume):
  /// the step, the sentence, and whether the maker must check it.
  Future<({int shown, String? message, bool needsLook})> _resolve(Progress progress) async {
    final stored = progress.place is NalbindPlace ? progress.place as NalbindPlace : null;
    final last = _recipe.segments.length - 1;
    if (stored == null) return (shown: _firstOpen(_recipe), message: null, needsLook: false);
    final r = await _engine.nalbindResume(
      _recipe,
      NalbindPlaceDto(
        unit: stored.unit,
        stepId: stored.stepId,
        units: progress.basis?.units ?? 0,
        prefix: progress.basis?.prefix ?? '',
      ),
      projectNotation: widget.projectNotation,
      projectStitchName: widget.projectStitchName,
    );
    return (
      shown: math.min(r.unit, last),
      message: r.message,
      needsLook: r.status == WorkResumeKind.changed || r.status == WorkResumeKind.clamped,
    );
  }

  /// Read the project's place and resume there (a saved project with steps only). Nothing is written
  /// until the maker moves.
  Future<void> _track() async {
    final id = widget.projectId;
    if (id == null || _recipe.segments.isEmpty) return;
    final repo = ref.read(progressRepositoryProvider);
    try {
      final load = await repo.load(BackupCraft.nalbinding, id);
      final problem = switch (load.status) {
        ProgressStatus.newer => ProgressProblem.newerVersion,
        ProgressStatus.unreadable => ProgressProblem.unreadable,
        ProgressStatus.failed => ProgressProblem.ioFailed,
        ProgressStatus.none || ProgressStatus.ok => null,
      };
      _asideUnread = load.status == ProgressStatus.failed;
      if (load.status != ProgressStatus.failed) _triedAgain = false;
      if (problem != null) {
        if (!mounted) return;
        setState(() {
          _trackProblem = ProgressFileException(problem).message;
          _canStartAgain = load.status == ProgressStatus.unreadable ||
              (load.status == ProgressStatus.failed && _triedAgain);
          _canTryAgain = load.status == ProgressStatus.failed;
        });
        return;
      }
      _work = await _engine.nalbindWork(_recipe,
          projectNotation: widget.projectNotation, projectStitchName: widget.projectStitchName);
      final progress = load.progress ?? const Progress(craft: ProgressCraft.nalbinding);
      final res = await _resolve(progress);
      final c = ProgressController(
        repository: repo,
        craft: BackupCraft.nalbinding,
        id: id,
        progress: progress,
        place: _placeOf(res.shown),
        basis: _basisOf(res.shown),
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
        _index = res.shown;
        _message = res.message;
        _needsLook = res.needsLook;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _trackProblem = 'Your place could not be worked out: ${errorWords(e)}');
    }
  }

  void _changed() {
    if (!mounted) return;
    if (_c?.foundAgain ?? false) {
      // A save met a record this session never read: nothing was written; show that record.
      if (_reloading) return;
      _reloading = true;
      _snack(const ProgressFileException(ProgressProblem.foundAgain).message);
      Future<void>.microtask(() async {
        if (!mounted) return;
        setState(() {
          _c?.dispose();
          _c = null;
        });
        await _track();
      }).whenComplete(() => _reloading = false);
      return;
    }
    setState(() {});
  }

  Future<void> _startAgain() async {
    try {
      await ref
          .read(progressRepositoryProvider)
          .setAside(BackupCraft.nalbinding, widget.projectId!, evenIfNotRead: _asideUnread);
    } catch (e) {
      _snack(startAgainFailedText(e));
      return;
    }
    if (!mounted) return;
    setState(() {
      _trackProblem = null;
      _canStartAgain = false;
      _canTryAgain = false;
    });
    await _track();
  }

  /// Read the place again after the device could not read it.
  Future<void> _tryAgain() async {
    _triedAgain = true;
    setState(() {
      _trackProblem = null;
      _canTryAgain = false;
      _canStartAgain = false;
    });
    await _track();
  }

  /// Show step [i]; with a place kept, move the place there and log it as [kind].
  Future<void> _go(int i, LogKind kind) async {
    if (!_ready) return;
    final to = i.clamp(0, _recipe.segments.length - 1);
    final c = _c;
    if (c == null) {
      setState(() => _index = to);
      return;
    }
    if (_busy) return;
    final basis = _basisOf(to);
    if (basis == null) {
      _snack('Ply could not work out step ${to + 1} of this recipe, so your place was not moved.');
      return;
    }
    setState(() => _busy = true);
    try {
      await c.moveTo(_placeOf(to), basis, kind);
      _index = to;
      _message = null;
      _needsLook = false;
    } catch (e) {
      _snack('Could not move to step ${to + 1}: ${errorWords(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _goTo(int i) async {
    if (i == _index) {
      // Going to the step shown for checking says it is right.
      if (_c?.pendingCheck == true) await _accept();
      return;
    }
    await _go(i, LogKind.jump);
  }

  /// Choose a step to go to (from the banner of a place shown for checking).
  Future<void> _chooseStep() async {
    final chosen = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Go to a step'),
        children: [
          for (final (j, x) in _recipe.segments.indexed)
            SimpleDialogOption(
              onPressed: () => Navigator.of(ctx).pop(j),
              child: Text(_stepLabel(j, x)),
            ),
        ],
      ),
    );
    if (chosen != null && mounted) await _goTo(chosen);
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
      if (await c.undo(start: _placeOf(_firstOpen(_recipe)))) {
        // The place undone to is checked against the recipe again, as on opening.
        final res = await _resolve(c.progress);
        if (!mounted) return;
        c.settle(shown: _placeOf(res.shown), basis: _basisOf(res.shown), check: res.needsLook);
        _index = res.shown;
        _message = res.message;
        _needsLook = res.needsLook;
        if (!res.needsLook) _snack('Back at ${NalbindPlaceWords(_recipe)(_placeOf(res.shown))}.');
      }
    } catch (e) {
      _snack('Could not undo: ${errorWords(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clear() async {
    final c = _c;
    if (c == null || !await confirmClearProgress(context)) return;
    try {
      final first = _firstOpen(_recipe);
      await c.clear(start: _placeOf(first), basis: _basisOf(first));
      if (!mounted) return;
      setState(() {
        _index = first;
        _message = null;
        _needsLook = false;
      });
      _snack('Your place and notes for this project were cleared.');
    } catch (e) {
      _snack('Could not clear your place: ${errorWords(e)}');
    }
  }

  // --- ticks ------------------------------------------------------------------------------------

  Future<void> _tick(String id, bool done) async {
    if (_ticking) return;
    final before = _recipe;
    setState(() {
      _ticking = true;
      _recipe = _recipe.withDone(id, done);
    });
    try {
      final message = await widget.onTick(id, done);
      if (message != null && mounted) _snack(message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _recipe = before);
      _snack('Could not save the tick: ${errorWords(e)}');
    } finally {
      if (mounted) setState(() => _ticking = false);
    }
  }

  String _stepLabel(int j, RecipeSegment x) =>
      '${_recipe.done.contains(x.id) ? 'Done: ' : ''}Step ${j + 1}: '
      '${x.title.trim().isEmpty ? x.kind.label : x.title.trim()}';

  @override
  Widget build(BuildContext context) {
    final segments = _recipe.segments;
    final text = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    if (segments.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text(kNalbindTrackerTitle)),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(kNalbindNothingToTrack, textAlign: TextAlign.center),
          ),
        ),
      );
    }
    final c = _c;
    final words = NalbindPlaceWords(_recipe);
    final i = _index.clamp(0, segments.length - 1);
    final seg = segments[i];
    final r = _report;
    final s = r?.at(i);
    final doneCount = segments.where((x) => _recipe.done.contains(x.id)).length;
    final stitch =
        s == null ? null : recipeStitchText(r!, s, projectStitchName: widget.projectStitchName);
    final count = s == null ? null : recipeCountText(s);
    final isDone = _recipe.done.contains(seg.id);
    final checking = _needsLook && (c?.pendingCheck ?? false);

    Widget fact(String label, String value) => Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: text.labelLarge),
              Text(value, style: text.bodyMedium),
            ],
          ),
        );

    Widget note(String line, {Key? key}) => Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(line, key: key, style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
        );

    return Scaffold(
      appBar: AppBar(
        title: const Text(kNalbindTrackerTitle),
        actions: [
          if (c != null)
            IconButton(
              key: const ValueKey('tracker-undo'),
              tooltip: 'Undo',
              onPressed: c.canUndo && !_busy ? _undo : null,
              icon: const Icon(Icons.undo),
            ),
          PopupMenuButton<int>(
            key: const ValueKey('follow-go-to'),
            enabled: _ready,
            tooltip: 'Go to a step',
            icon: const Icon(Icons.list),
            onSelected: _goTo,
            itemBuilder: (_) => [
              for (final (j, x) in segments.indexed)
                PopupMenuItem(value: j, child: Text(_stepLabel(j, x))),
            ],
          ),
          if (c != null)
            PopupMenuButton<String>(
              tooltip: 'More',
              onSelected: (a) => switch (a) {
                'notes' => showProgressNotes(context, c, words.call),
                'log' => showProgressLog(context, c.progress, words.call, NalbindPlaceWords.units),
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
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          Text('$doneCount of ${segments.length} steps done', style: text.bodySmall),
          const SizedBox(height: 4),
          LinearProgressIndicator(
            value: doneCount / segments.length,
            semanticsLabel: 'Steps done',
          ),
          if (widget.projectId == null)
            note('Save the project to keep your place.', key: const ValueKey('follow-unsaved')),
          if (_trackProblem != null) ...[
            note(_trackProblem!, key: const ValueKey('tracker-record-problem')),
            if (_canStartAgain)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  key: const ValueKey('tracker-start-again'),
                  onPressed: _startAgain,
                  child: const Text('Start again (keeps the old record aside)'),
                ),
              ),
            if (_canTryAgain)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  key: const ValueKey('tracker-try-again'),
                  onPressed: _tryAgain,
                  child: const Text('Try again'),
                ),
              ),
          ],
          if (_message != null) ...[
            const SizedBox(height: 8),
            TrackerBanner(
              message: _message!,
              needsLook: checking,
              onRight: checking ? _accept : null,
              onGoTo: checking ? _chooseStep : null,
              onDismiss: checking ? null : () => setState(() => _message = null),
            ),
          ],
          if (c != null && widget.unsavedEdits)
            note('You have unsaved changes to this project. Your place follows the recipe as it is '
                'on screen.'),
          if (c?.saveError != null) SaveErrorLine(c!.saveError!),
          // What is wrong with the recipe as a whole (or why nothing was checked) shows here too.
          if (r != null && r.recipeWide.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: RecipeIssueList(
                key: const ValueKey('follow-recipe-issues'),
                issues: r.recipeWide,
                withPlace: true,
              ),
            ),
          const SizedBox(height: 16),
          Text(
            [
              'Step ${i + 1} of ${segments.length}',
              if (s?.partNumber != null) 'Part ${s!.partNumber}',
              seg.phase.label,
            ].join(', '),
            key: const ValueKey('tracker-place'),
            style: text.labelLarge?.copyWith(color: cs.primary),
          ),
          Semantics(
            header: true,
            child: Text(
              seg.title.trim().isEmpty ? seg.kind.label : '${seg.kind.label}: ${seg.title.trim()}',
              style: text.headlineSmall,
            ),
          ),
          const SizedBox(height: 12),
          if (_error != null) Text(_error!, style: TextStyle(color: cs.error)),
          Text(
            recipeWrittenText(r, seg, i) ?? 'Checking…',
            key: const ValueKey('follow-written'),
            style: text.bodyLarge,
          ),
          if (stitch != null) fact('Stitch', stitch),
          if (count != null) fact('Stitches after this step', count),
          if (s?.target != null) fact('Aim for', s!.target!),
          if (seg.notes.trim().isNotEmpty) fact('Notes', seg.notes.trim()),
          if (seg.caution.trim().isNotEmpty) fact('Watch out for', seg.caution.trim()),
          if (r != null) ...[
            const SizedBox(height: 12),
            Text(recipeStatusText(r, i),
                style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
            if (r.issuesAt(i).isNotEmpty) RecipeIssueList(issues: r.issuesAt(i)),
          ],
          if (c != null) ...[
            const SizedBox(height: 8),
            NotesHere(controller: c),
          ],
          const SizedBox(height: 16),
          CheckboxListTile(
            key: const ValueKey('follow-done'),
            value: isDone,
            contentPadding: EdgeInsets.zero,
            title: const Text('Done'),
            subtitle: const Text('Tick it when this step is worked.'),
            onChanged: _ticking ? null : (v) => _tick(seg.id, v ?? false),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              OutlinedButton.icon(
                key: const ValueKey('follow-previous'),
                onPressed: i > 0 && !_busy && _ready ? () => _go(i - 1, LogKind.back) : null,
                icon: const Icon(Icons.chevron_left),
                label: const Text('Previous'),
              ),
              const Spacer(),
              FilledButton.icon(
                key: const ValueKey('follow-next'),
                onPressed: i < segments.length - 1 && !_busy && _ready
                    ? () => _go(i + 1, LogKind.worked)
                    : null,
                icon: const Icon(Icons.chevron_right),
                label: Text(c == null ? 'Next' : 'Worked, next step'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(kRecipeCheckedText, style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
        ],
      ),
    );
  }
}
