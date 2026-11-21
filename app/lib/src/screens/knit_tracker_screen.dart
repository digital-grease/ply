// Knit a pattern row by row (ADR 0023): the chart row, or the section step and the row inside it, with
// what to knit and the stitch count after it; Next when it is knitted, Previous to correct, Go to,
// Undo, notes pinned to a place and the log. The place is written at once to the project's own
// progress record (never to the pattern), so closing the app at any row resumes there, offline.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/library_backup.dart' show BackupCraft;
import '../data/progress_repository.dart' show ProgressStatus;
import '../data/work_repository.dart';
import '../models/progress.dart';
import '../rust/knit_dto.dart' show KnitPatternDto;
import '../rust/progress_dto.dart';
import '../state/progress_controller.dart';
import '../widgets/progress_panels.dart';

/// The editor menu entry and the screen's title.
const String kKnitTrackerTitle = 'Knit row by row';

/// Words for knitting places, from the pattern's work.
class KnitPlaceWords {
  const KnitPlaceWords(this.work);

  final KnitWorkDto work;

  bool get chart => work.mode == KnitWorkModeKind.chart;

  String get rowWord => chart && work.round ? 'round' : 'row';

  /// The unit [place] names now: by its section and step ids when it has them (wherever the step is
  /// now; `null` when it is no longer in the pattern), else by its number.
  int? unitOf(KnitPlace place) {
    if (place.hasIds) {
      final i = work.units.indexWhere((u) =>
          u.sectionId == place.sectionId &&
          u.stepId == place.stepId &&
          (u.section == null ? null : u.chartRow) == place.chartRow);
      return i < 0 ? null : i;
    }
    return place.unit < work.units.length ? place.unit : null;
  }

  /// "row 3", "round 3, time 2", or "Section 1: Cuff, step 2, row 5".
  String call(WorkPlace place) {
    if (place is! KnitPlace) return '';
    final i = unitOf(place);
    if (i == null) {
      return place.hasIds ? 'a step no longer in the pattern' : 'a place no longer in the pattern';
    }
    final u = work.units[i];
    if (chart) {
      final r = u.chartRow ?? place.unit + 1;
      return place.repeat > 1 ? '$rowWord $r, time ${place.repeat}' : '$rowWord $r';
    }
    return [if (_heading(u) case final h?) h, ..._inStep(u, place)].join(', ');
  }

  /// The words a library tile shows for [place], kept in its record as the place's label (ADR 0023,
  /// follow-up 6): with sections, the words above ("Section 1: Cuff, step 2, row 5"), the heading
  /// shortened when the whole would pass [ProgressLimits.maxLabelChars] (a section's name is the
  /// knitter's own and may be long), so the step and row are always kept, and left out when nothing
  /// readable of it would be left; for a chart, the row or round as above with the tile's "of"
  /// ("Round 5 of 24, time 2": without a label a tile can only say Chart row, since the record does
  /// not say whether the chart is worked flat or in the round). The "of" is the tile's: [units],
  /// those of the basis stored with the place, left out without them or for a row past them.
  /// `null` for a place no longer in the pattern.
  String? label(KnitPlace place, {int? units}) {
    final i = unitOf(place);
    if (i == null) return null;
    final u = work.units[i];
    if (chart) {
      final r = u.chartRow ?? place.unit + 1;
      return '${rowWord == 'round' ? 'Round' : 'Row'} $r'
          '${units != null && r <= units ? ' of $units' : ''}'
          '${place.repeat > 1 ? ', time ${place.repeat}' : ''}';
    }
    final rest = _inStep(u, place).join(', ');
    final heading = _heading(u);
    if (rest.isEmpty) return heading == null ? null : PlaceLabel.fit(heading);
    final shown = heading == null
        ? ''
        : PlaceLabel.fit(heading, max: ProgressLimits.maxLabelChars - rest.length - 2);
    return shown.isEmpty ? '${rest[0].toUpperCase()}${rest.substring(1)}' : '$shown, $rest';
  }

  /// The heading of [u]'s section ("Section 1: Cuff"), when it has one.
  String? _heading(KnitWorkUnitDto u) =>
      u.section != null && u.section! < work.headings.length ? work.headings[u.section!] : null;

  /// Where [place] is inside its section: the step, the chart row of a chart-rows step, and the row
  /// inside a step that works several.
  List<String> _inStep(KnitWorkUnitDto u, KnitPlace place) => [
        if (u.step != null) 'step ${u.step! + 1}',
        if (u.chartRow != null) 'chart row ${u.chartRow}',
        if (u.rows > 1) '${isRound(u) ? 'round' : 'row'} ${place.row}',
      ];

  /// "3 rows", "1 round", "4 rows and steps".
  String units(int n) {
    if (chart) return n == 1 ? '1 $rowWord' : '$n ${rowWord}s';
    return n == 1 ? '1 row or step' : '$n rows and steps';
  }

  /// A sections line that works rounds (the ledger labels it "Next 50 rnds").
  static bool isRound(KnitWorkUnitDto u) => (u.label ?? '').contains('rnd');
}

class KnitTrackerScreen extends ConsumerStatefulWidget {
  const KnitTrackerScreen({
    required this.projectId,
    required this.pattern,
    required this.name,
    this.unsavedEdits = false,
    super.key,
  });

  /// The saved pattern's library id (its progress record is keyed by it).
  final String projectId;

  /// The pattern as the editor has it.
  final KnitPatternDto pattern;
  final String name;

  /// The editor holds changes not yet saved (the tracker follows the pattern on screen, and says so).
  final bool unsavedEdits;

  @override
  ConsumerState<KnitTrackerScreen> createState() => _KnitTrackerScreenState();
}

class _KnitTrackerScreenState extends ConsumerState<KnitTrackerScreen> {
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
  KnitWorkDto? _work;
  String? _message;
  bool _needsLook = false;
  int? _suggested;
  bool _busy = false;

  List<KnitWorkUnitDto> get _units => _work?.units ?? const [];
  bool get _chart => _work?.mode == KnitWorkModeKind.chart;

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

  KnitPlace _place(int unit, int row, int repeat) {
    final u = _units[unit];
    return KnitPlace(unit,
        row: row,
        repeat: repeat,
        sectionId: u.sectionId,
        stepId: u.stepId,
        chartRow: u.section != null ? u.chartRow : null);
  }

  /// What [unit] of the [repeat]-th time through is worked against: from the second time through a
  /// chart on, the whole chart is before every row, so it has its own fingerprint.
  PlaceBasis? _basisOf(int unit, int repeat) => unit < _units.length
      ? PlaceBasis(
          units: _units.length, prefix: repeat > 1 ? _units[unit].laterPrefix : _units[unit].prefix)
      : null;

  /// The words written with a stored place as its label, from the pattern's work as the tracker has
  /// it (the label is the tracker's words, so it follows the pattern on screen, as the place does),
  /// with [units] of the basis stored with it for a chart's "of".
  String? _labelOf(WorkPlace place, int? units) {
    final work = _work;
    return work != null && place is KnitPlace
        ? KnitPlaceWords(work).label(place, units: units)
        : null;
  }

  /// Where the stored place in [progress] is shown in the pattern as it is now (the engine's resume,
  /// as on opening): the place shown, the sentence, whether the knitter must check it, and a step to
  /// offer.
  Future<({KnitPlace shown, String? message, bool needsLook, int? suggested})> _resolve(
      Progress progress) async {
    final stored = progress.place is KnitPlace ? progress.place as KnitPlace : null;
    if (stored == null || _units.isEmpty) {
      return (
        shown: _units.isEmpty ? const KnitPlace(0) : _place(0, 1, 1),
        message: null,
        needsLook: false,
        suggested: null,
      );
    }
    final r = await ref.read(workRepositoryProvider).knitResume(
          widget.pattern,
          KnitPlaceDto(
            unit: stored.unit,
            row: stored.row,
            units: progress.basis?.units ?? 0,
            prefix: progress.basis?.prefix ?? '',
            repeat: stored.repeat,
            sectionId: stored.sectionId,
            stepId: stored.stepId,
            chartRow: stored.chartRow,
          ),
        );
    final unit = math.min(r.unit, _units.length - 1);
    return (
      shown: _place(unit, math.max(1, math.min(r.row, _units[unit].rows)), stored.repeat),
      message: r.message,
      needsLook: r.status == WorkResumeKind.changed || r.status == WorkResumeKind.clamped,
      suggested: r.suggestedUnit,
    );
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
    final work = ref.read(workRepositoryProvider);
    try {
      final load = await repo.load(BackupCraft.knitting, widget.projectId);
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
      final plan = await work.knitWork(widget.pattern);
      _work = plan;
      final progress = load.progress ?? const Progress(craft: ProgressCraft.knitting);
      final empty = plan.units.isEmpty;
      final res = await _resolve(progress);
      final message = res.message;
      final needsLook = res.needsLook;
      final suggested = res.suggested;
      final c = ProgressController(
        repository: repo,
        craft: BackupCraft.knitting,
        id: widget.projectId,
        progress: progress,
        place: res.shown,
        basis: empty ? null : _basisOf(res.shown.unit, res.shown.repeat),
        pendingCheck: needsLook && !empty,
        clock: ref.read(progressClockProvider),
        fromRecord: load.status == ProgressStatus.ok,
        labelOf: _labelOf,
      );
      c.addListener(_changed);
      if (!mounted) {
        c.dispose();
        return;
      }
      setState(() {
        _c?.dispose();
        _c = c;
        _message = empty ? null : message;
        _needsLook = needsLook;
        _suggested = suggested;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _problem = 'Could not work out this pattern\'s rows: $e';
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
      _snack(const ProgressFileException(ProgressProblem.foundAgain).message);
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

  Future<void> _startAgain() async {
    try {
      await ref
          .read(progressRepositoryProvider)
          .setAside(BackupCraft.knitting, widget.projectId, evenIfNotRead: _asideUnread);
    } catch (e) {
      _snack(startAgainFailedText(e));
      return;
    }
    if (!mounted) return;
    await _load();
  }

  Future<void> _go(KnitPlace to, LogKind kind) async {
    final c = _c;
    if (c == null || _busy) return;
    setState(() => _busy = true);
    try {
      final basis = _basisOf(to.unit, to.repeat);
      if (basis == null) {
        // Never store a place the engine did not work out.
        _snack('That place is not in the pattern, so your place was not moved.');
        return;
      }
      await c.moveTo(to, basis, kind);
      _message = null;
      _needsLook = false;
      _suggested = null;
    } catch (e) {
      _snack('Could not move: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  KnitPlace? _nextOf(KnitPlace p) {
    if (_units.isEmpty || p.unit >= _units.length) return null;
    final u = _units[p.unit];
    if (p.row < u.rows) return _place(p.unit, p.row + 1, p.repeat);
    if (p.unit + 1 < _units.length) return _place(p.unit + 1, 1, p.repeat);
    if (_chart && p.repeat < ProgressLimits.maxNumber) return _place(0, 1, p.repeat + 1);
    return null;
  }

  KnitPlace? _previousOf(KnitPlace p) {
    if (_units.isEmpty) return null;
    final unit = math.min(p.unit, _units.length - 1);
    if (p.row > 1) return _place(unit, math.min(p.row - 1, _units[unit].rows), p.repeat);
    if (unit > 0) return _place(unit - 1, _units[unit - 1].rows, p.repeat);
    if (_chart && p.repeat > 1) {
      return _place(_units.length - 1, _units.last.rows, p.repeat - 1);
    }
    return null;
  }

  Future<void> _accept() async {
    await _c?.accept();
    if (!mounted) return;
    setState(() {
      _message = null;
      _needsLook = false;
      _suggested = null;
    });
  }

  Future<void> _undo() async {
    final c = _c;
    if (c == null || _busy) return;
    setState(() => _busy = true);
    try {
      if (await c.undo(start: _place(0, 1, 1))) {
        // The place undone to is checked against the pattern again, as on opening: one the pattern
        // changed under is shown for checking, never as if nothing happened.
        final res = await _resolve(c.progress);
        if (!mounted) return;
        c.settle(
            shown: res.shown,
            basis: _basisOf(res.shown.unit, res.shown.repeat),
            check: res.needsLook);
        _message = res.message;
        _needsLook = res.needsLook;
        _suggested = res.suggested;
        if (!res.needsLook) _snack('Back at ${KnitPlaceWords(_work!)(res.shown)}.');
      }
    } catch (e) {
      _snack('Could not undo: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _goTo() async {
    final c = _c;
    final work = _work;
    if (c == null || work == null || _units.isEmpty) return;
    final cur = c.place as KnitPlace;
    final words = KnitPlaceWords(work);
    final chosen = await showModalBottomSheet<KnitPlace>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        var repeat = cur.repeat;
        return StatefulBuilder(
          builder: (ctx, setLocal) => SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    title: Text(_chart ? 'Go to a ${words.rowWord}' : 'Go to a step',
                        style: Theme.of(ctx).textTheme.titleLarge),
                  ),
                  if (_chart)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconButton(
                          tooltip: 'One time fewer',
                          onPressed: repeat > 1 ? () => setLocal(() => repeat--) : null,
                          icon: const Icon(Icons.remove),
                        ),
                        Text('Time $repeat through the chart'),
                        IconButton(
                          tooltip: 'One time more',
                          onPressed: repeat < ProgressLimits.maxNumber
                              ? () => setLocal(() => repeat++)
                              : null,
                          icon: const Icon(Icons.add),
                        ),
                      ],
                    ),
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: _units.length,
                      itemBuilder: (ctx, i) {
                        final u = _units[i];
                        final header = !_chart &&
                            u.section != null &&
                            (i == 0 || _units[i - 1].section != u.section) &&
                            u.section! < work.headings.length;
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (header)
                              Padding(
                                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                                child: Text(work.headings[u.section!],
                                    style: Theme.of(ctx).textTheme.titleSmall),
                              ),
                            ListTile(
                              key: ValueKey('tracker-goto-unit-$i'),
                              dense: true,
                              selected: i == cur.unit,
                              title: Text(u.label == null ? u.text : '${u.label}: ${u.text}',
                                  maxLines: 2, overflow: TextOverflow.ellipsis),
                              onTap: () => Navigator.of(ctx).pop(_place(i, 1, repeat)),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
    if (!mounted || chosen == null || chosen.sameSpot(c.place)) return;
    await _go(chosen, LogKind.jump);
  }

  Future<void> _clear() async {
    final c = _c;
    if (c == null || !await confirmClearProgress(context)) return;
    try {
      await c.clear(
          start: _units.isEmpty ? const KnitPlace(0) : _place(0, 1, 1), basis: _basisOf(0, 1));
      if (!mounted) return;
      setState(() {
        _message = null;
        _needsLook = false;
        _suggested = null;
      });
      _snack('Your place and notes for this pattern were cleared.');
    } catch (e) {
      _snack('Could not clear your place: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    final work = _work;
    final words = work == null ? null : KnitPlaceWords(work);
    final place = c?.place is KnitPlace ? c!.place as KnitPlace : null;
    return Scaffold(
      appBar: AppBar(
        title: const Text(kKnitTrackerTitle),
        actions: c == null || words == null
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
                  tooltip: 'Go to',
                  onPressed: _units.isEmpty ? null : _goTo,
                  icon: const Icon(Icons.pin_outlined),
                ),
                PopupMenuButton<String>(
                  tooltip: 'More',
                  onSelected: (a) => switch (a) {
                    'notes' => showProgressNotes(context, c, words.call),
                    'log' => showProgressLog(context, c.progress, words.call, words.units),
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
      bottomNavigationBar: c == null || place == null || _units.isEmpty
          ? null
          : TrackerControls(
              onPrevious: _busy || _previousOf(place) == null
                  ? null
                  : () => _go(_previousOf(place)!, LogKind.back),
              onNext: _busy || _nextOf(place) == null
                  ? null
                  : () => _go(_nextOf(place)!, LogKind.worked),
              nextLabel: 'Knitted, next',
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
    final work = _work!;
    final text = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    if (_units.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child:
              Text('This pattern has no rows or steps to knit yet.', textAlign: TextAlign.center),
        ),
      );
    }
    final place = c.place as KnitPlace;
    final unit = math.min(place.unit, _units.length - 1);
    final u = _units[unit];
    final words = KnitPlaceWords(work);
    final round = _chart ? work.round : KnitPlaceWords.isRound(u);
    final rowWord = round ? 'Round' : 'Row';
    final next = _nextOf(place);
    // A flat chart with an odd number of rows is worked from the other side every second time
    // through: the engine gives each row's words for that side.
    final flipped = _chart && place.repeat.isEven && u.otherLabel != null;
    String labelOf(KnitWorkUnitDto k) => (flipped ? k.otherLabel : null) ?? k.label ?? '';
    String textOf(KnitWorkUnitDto k) => (flipped ? k.otherText : null) ?? k.text;
    final big = _chart
        ? (labelOf(u).isEmpty ? '$rowWord ${unit + 1}' : labelOf(u))
        : (u.rows > 1
            ? '$rowWord ${place.row} of ${u.rows}'
            : (u.label ?? 'Step ${(u.step ?? 0) + 1}'));
    final coming = [
      for (var k = unit + 1; k < math.min(unit + 4, _units.length); k++) _units[k],
    ];
    final sectionNotes = !_chart && u.section != null && u.section! < work.sectionNotes.length
        ? work.sectionNotes[u.section!]
        : null;
    final atStart = unit == 0 && place.row == 1 && place.repeat == 1;
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
            // The step they were on, at the row the record had (the place shown may be clamped).
            onSuggestion: _needsLook && c.pendingCheck && _suggested != null
                ? () {
                    final saved = c.progress.place is KnitPlace
                        ? (c.progress.place as KnitPlace).row
                        : place.row;
                    _go(
                        _place(
                            _suggested!, math.min(saved, _units[_suggested!].rows), place.repeat),
                        LogKind.jump);
                  }
                : null,
            onDismiss: _needsLook && c.pendingCheck ? null : () => setState(() => _message = null),
          ),
        ],
        if (widget.unsavedEdits)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'You have unsaved changes to this pattern. Your place follows the pattern as it is '
              'on screen.',
              style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
          ),
        if (c.saveError != null) SaveErrorLine(c.saveError!),
        const SizedBox(height: 16),
        if (atStart && work.pieces != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child:
                Text(work.pieces!, key: const ValueKey('tracker-pieces'), style: text.bodyMedium),
          ),
        if (!_chart && u.section != null && u.section! < work.headings.length)
          Text(work.headings[u.section!], style: text.titleMedium),
        if (sectionNotes != null)
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 4),
            child: Text(sectionNotes,
                key: const ValueKey('tracker-section-notes'), style: text.bodyMedium),
          ),
        if (atStart && work.castOn != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text('Before you start: ${work.castOn}', style: text.bodyMedium),
          ),
        Semantics(
          header: true,
          child: Text(big, key: const ValueKey('tracker-place'), style: text.headlineMedium),
        ),
        Text(
          [
            if (_chart) 'of ${_units.length} ${round ? 'rounds' : 'rows'}',
            if (_chart && place.repeat > 1) 'time ${place.repeat} through the chart',
            if (!_chart && u.step != null) 'step ${u.step! + 1}',
            if (!_chart && u.rows > 1 && u.label != null) u.label!,
          ].join(', '),
          style: text.titleSmall?.copyWith(color: cs.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        Text(textOf(u), key: const ValueKey('tracker-action'), style: text.titleLarge),
        if (u.every != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              (place.row - 1) % math.max(1, u.every!) == 0
                  ? 'A shaping ${rowWord.toLowerCase()}: work the shaping.'
                  : 'No shaping on this ${rowWord.toLowerCase()}.',
              key: const ValueKey('tracker-shaping'),
              style: text.bodyMedium,
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            '${_chart ? 'Stitches after this ${rowWord.toLowerCase()}' : 'Stitches after this step'}: ${u.count}',
            style: text.bodyMedium,
          ),
        ),
        if (u.opaque)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text('In the pattern\'s own words: Ply does not check this step.',
                style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
          ),
        if (flipped && work.repeatNote != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(work.repeatNote!, style: text.bodySmall),
          ),
        const SizedBox(height: 12),
        NotesHere(controller: c),
        if (next == null && !_chart)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              work.stopped
                  ? 'Ply stopped counting here: the pattern is too long to count.'
                  : 'This is the last step of the pattern.',
              style: text.bodyMedium,
            ),
          ),
        if (coming.isNotEmpty) ...[
          const Divider(height: 24),
          Text('Coming up', style: text.labelLarge),
          for (final k in coming)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(labelOf(k).isEmpty ? textOf(k) : '${labelOf(k)}: ${textOf(k)}',
                  style: text.bodySmall, maxLines: 2, overflow: TextOverflow.ellipsis),
            ),
        ],
        // The place in the words the log and the notes use.
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text('You are at ${words(place)}.',
              style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
        ),
      ],
    );
  }
}
