import 'package:flutter/material.dart';

import '../models/knit_sections.dart';
import '../rust/knit_dto.dart';

/// Open the form for a section step of [kind]: a new step (no [initial]) or an edit of one. Returns
/// the step's action on Save, or null on Cancel. [pattern] supplies the chart's height (for chart
/// rows) and the hold steps a "return held stitches" step can name. The form checks only that each
/// number is a whole number in range; whether the step fits the stitches on the needle is the
/// engine ledger's call, shown beside the step. [sectionIndex] is the section the step is in, so a
/// join does not offer the piece that section works.
Future<KnitStepActionDto?> showKnitStepDialog(
  BuildContext context, {
  required KnitStepKind kind,
  required KnitPatternDto pattern,
  KnitStepActionDto? initial,
  int? sectionIndex,
}) =>
    showDialog<KnitStepActionDto>(
      context: context,
      builder: (_) => KnitStepDialog(
          kind: kind, pattern: pattern, initial: initial, sectionIndex: sectionIndex),
    );

/// Open a dialog with one multi-line text field (section notes). Returns the text on Save (possibly
/// empty, to clear it), or null on Cancel.
Future<String?> showKnitTextDialog(
  BuildContext context, {
  required String title,
  required String label,
  String initial = '',
}) =>
    showDialog<String>(
      context: context,
      builder: (_) => _TextDialog(title: title, label: label, initial: initial),
    );

/// How far a work step goes, as the form offers it.
enum _Reach { end, last, count }

/// Where a short row turns, as the form offers it.
enum _Turn { last, count, beforeGap, pastGap }

/// One needle group's fields in the groups form. [id] is stable while the form is open, so
/// removing a group in the middle keeps every other group's fields with their own text.
class _GroupFields {
  _GroupFields({String name = '', String count = '', String notes = ''})
      : id = _nextId++,
        name = TextEditingController(text: name),
        count = TextEditingController(text: count),
        notes = TextEditingController(text: notes);

  static int _nextId = 0;
  final int id;
  final TextEditingController name;
  final TextEditingController count;
  final TextEditingController notes;

  void dispose() {
    name.dispose();
    count.dispose();
    notes.dispose();
  }
}

/// The step form. Public for tests.
class KnitStepDialog extends StatefulWidget {
  const KnitStepDialog(
      {required this.kind, required this.pattern, this.initial, this.sectionIndex, super.key});

  final KnitStepKind kind;
  final KnitPatternDto pattern;
  final KnitStepActionDto? initial;

  /// The section the step is in (a join leaves out the piece it works), when known.
  final int? sectionIndex;

  @override
  State<KnitStepDialog> createState() => _KnitStepDialogState();
}

class _KnitStepDialogState extends State<KnitStepDialog> {
  late final KnitStepActionDto _start = widget.initial ??
      defaultKnitStepAction(widget.kind, widget.pattern, sectionIndex: widget.sectionIndex);

  // Every field the forms use; each kind reads the ones it needs.
  final _count = TextEditingController();
  final _first = TextEditingController();
  final _last = TextEditingController();
  final _name = TextEditingController();
  final _text = TextEditingController();
  final _change = TextEditingController();
  final _after = TextEditingController(text: '1');
  final _every = TextEditingController();
  final _target = TextEditingController();
  WorkStitchKind _stitch = WorkStitchKind.knit;
  _Reach _reach = _Reach.end;
  _Turn _turn = _Turn.last;
  TurnMethodKind _method = TurnMethodKind.wrapAndTurn;
  bool _resolve = false;
  bool _rest = true; // bind off / hold: the rest of the row
  String _hold = '';
  SideKind? _facing;
  bool _decrease = false; // short row: a decrease before the turn
  DecreaseKind _decKind = DecreaseKind.ssk;
  bool _slip = true; // work flat: slip the first stitch of every row
  bool _shapeDecrease = true;
  bool _untilRemain = false;
  final Set<String> _shapeGroups = {};
  // Shaping: the groups the step named when the form opened (kept, in order, even when a group
  // step no longer sets one: such a group shows as "not found" until it is unticked).
  final List<String> _initialGroups = [];
  String _along = ''; // pick up: the work-flat step's id, or '' for another edge
  String _group = ''; // pick up: the needle group, or '' for none
  final List<_GroupFields> _groupRows = [];
  CloseMethodKind _close = CloseMethodKind.graft;
  bool _joinPiece = true; // join: another piece (true) or held stitches
  String _piece = ''; // join: the piece's id
  bool _closeHeld = false; // close: two groups on hold instead of the stitches on the needle
  String _closeA = ''; // close: the two hold steps' ids
  String _closeB = '';
  bool _submitted = false;

  int get _height => widget.pattern.chart.rows.length;
  List<KnitHoldRef> get _holds => knitHoldSteps(widget.pattern);
  List<KnitHoldRef> get _flatParts => knitFlatParts(widget.pattern);
  List<String> get _groupNames => knitGroupNames(widget.pattern);

  @override
  void initState() {
    super.initState();
    switch (_start) {
      case KnitStepActionDto_ChartRows(:final first, :final last):
        _first.text = '$first';
        _last.text = '$last';
      case KnitStepActionDto_Work(:final stitch, :final to, :final resolveTurns):
        _stitch = stitch;
        _resolve = resolveTurns;
        switch (to) {
          case WorkToDto_End():
            _reach = _Reach.end;
          case WorkToDto_Last(:final count):
            _reach = _Reach.last;
            _count.text = '$count';
          case WorkToDto_Count(:final count):
            _reach = _Reach.count;
            _count.text = '$count';
        }
      case KnitStepActionDto_ShortRow(
          :final stitch,
          :final to,
          :final method,
          :final resolveTurns,
          :final decrease
        ):
        _stitch = stitch;
        _method = method;
        _resolve = resolveTurns;
        switch (to) {
          case TurnAtDto_Last(:final count):
            _turn = _Turn.last;
            _count.text = '$count';
          case TurnAtDto_Count(:final count):
            _turn = _Turn.count;
            _count.text = '$count';
          case TurnAtDto_BeforeGap(:final count):
            _turn = _Turn.beforeGap;
            _count.text = '$count';
          case TurnAtDto_PastGap(:final count):
            _turn = _Turn.pastGap;
            _count.text = '$count';
        }
        if (decrease != null) {
          _decrease = true;
          _decKind = decrease.kind;
          _after.text = '${decrease.after}';
        }
      case KnitStepActionDto_CastOn(:final count):
        _count.text = '$count';
      case KnitStepActionDto_BindOff(:final count, :final resolveTurns):
        _rest = count == null;
        _count.text = count == null ? '' : '$count';
        _resolve = resolveTurns;
      case KnitStepActionDto_Hold(:final count, :final name):
        _rest = count == null;
        _count.text = count == null ? '' : '$count';
        _name.text = name;
      case KnitStepActionDto_Resume(:final hold, :final facing):
        _hold = hold;
        _facing = facing;
      case KnitStepActionDto_Opaque(:final text, :final stitchChange):
        _text.text = text;
        _change.text = stitchChange == null ? '' : '$stitchChange';
      case KnitStepActionDto_JoinRound():
      case KnitStepActionDto_RoundStart():
        break;
      case KnitStepActionDto_WorkFlat(:final count, :final name, :final slipEdges):
        _count.text = '$count';
        _name.text = name;
        _slip = slipEdges;
      case KnitStepActionDto_Rows(:final count, :final text):
        _count.text = '$count';
        _text.text = text;
      case KnitStepActionDto_Shape(
          :final change,
          :final every,
          :final until,
          :final groups,
          :final text
        ):
        _shapeDecrease = change <= 0;
        _count.text = '${change.abs()}';
        _every.text = '$every';
        switch (until) {
          case ShapeUntilDto_Times(:final count):
            _untilRemain = false;
            _target.text = '$count';
          case ShapeUntilDto_Remain(:final count):
            _untilRemain = true;
            _target.text = '$count';
        }
        _shapeGroups.addAll(groups);
        _initialGroups.addAll(groups);
        _text.text = text;
      case KnitStepActionDto_PickUp(:final count, :final along, :final group):
        _count.text = '$count';
        switch (along) {
          case PickUpAlongDto_Piece(:final step):
            _along = step;
          case PickUpAlongDto_Edge(:final text):
            _along = '';
            _text.text = text;
        }
        _group = group ?? '';
      case KnitStepActionDto_Groups(:final groups):
        _groupRows.addAll([
          for (final g in groups) _GroupFields(name: g.name, count: '${g.count}', notes: g.notes),
        ]);
        if (widget.initial == null && _groupRows.isEmpty) {
          _groupRows.addAll([_GroupFields(), _GroupFields()]);
        }
      case KnitStepActionDto_Close(:final method, :final holds):
        _close = method;
        _closeHeld = holds.isNotEmpty;
        if (holds.isNotEmpty) _closeA = holds.first;
        if (holds.length > 1) _closeB = holds[1];
      case KnitStepActionDto_Join(:final source, :final stitch, :final resolveTurns):
        _stitch = stitch;
        _resolve = resolveTurns;
        switch (source) {
          case JoinSourceDto_Piece(:final piece):
            _joinPiece = true;
            _piece = piece;
          case JoinSourceDto_Held(:final hold):
            _joinPiece = false;
            _hold = hold;
        }
    }
  }

  @override
  void dispose() {
    for (final c in [_count, _first, _last, _name, _text, _change, _after, _every, _target]) {
      c.dispose();
    }
    for (final g in _groupRows) {
      g.dispose();
    }
    super.dispose();
  }

  bool get _gapTurn => _turn == _Turn.beforeGap || _turn == _Turn.pastGap;

  /// Every text field this form may save; none may be longer than the engine keeps.
  Iterable<TextEditingController> get _texts sync* {
    yield _name;
    yield _text;
    for (final g in _groupRows) {
      yield g.name;
      yield g.notes;
    }
  }

  /// [kKnitTextTooLong] when [c] holds more than a section text may, else null.
  String? _lengthError(TextEditingController c) =>
      knitTextTooLong(c.text.trim()) ? kKnitTextTooLong : null;

  /// The groups a shaping step saves: those it named first, in their order, then any newly ticked.
  List<String> get _chosenShapeGroups => [
        for (final g in _initialGroups)
          if (_shapeGroups.contains(g)) g,
        for (final g in _groupNames)
          if (_shapeGroups.contains(g) && !_initialGroups.contains(g)) g,
      ];

  /// A whole number from [min] to [max] in [c], or null.
  int? _int(TextEditingController c, {int min = 1, int max = kMaxStepCount}) {
    final v = int.tryParse(c.text.trim());
    return v != null && v >= min && v <= max ? v : null;
  }

  String? _countError(TextEditingController c, {int min = 1, int max = kMaxStepCount}) {
    if (!_submitted || _int(c, min: min, max: max) != null) return null;
    return 'Enter a whole number from $min to $max.';
  }

  /// The action the form describes, or null while a field is not valid.
  KnitStepActionDto? _action() {
    if (_texts.any((c) => knitTextTooLong(c.text.trim()))) return null;
    switch (widget.kind) {
      case KnitStepKind.chartRows:
        if (_height == 0) return null;
        final first = _int(_first, max: _height);
        final last = _int(_last, max: _height);
        if (first == null || last == null || last < first) return null;
        return KnitStepActionDto.chartRows(first: first, last: last);
      case KnitStepKind.work:
        final WorkToDto to;
        switch (_reach) {
          case _Reach.end:
            to = const WorkToDto.end();
          case _Reach.last:
            final n = _int(_count);
            if (n == null) return null;
            to = WorkToDto.last(count: n);
          case _Reach.count:
            final n = _int(_count);
            if (n == null) return null;
            to = WorkToDto.count(count: n);
        }
        return KnitStepActionDto.work(stitch: _stitch, to: to, resolveTurns: _resolve);
      case KnitStepKind.shortRow:
        final n = _int(_count, min: _gapTurn ? 0 : 1);
        if (n == null) return null;
        TurnDecreaseDto? decrease;
        if (_decrease) {
          final after = _int(_after, min: 0);
          if (after == null) return null;
          decrease = TurnDecreaseDto(kind: _decKind, after: after);
        }
        return KnitStepActionDto.shortRow(
          stitch: _stitch,
          to: switch (_turn) {
            _Turn.last => TurnAtDto.last(count: n),
            _Turn.count => TurnAtDto.count(count: n),
            _Turn.beforeGap => TurnAtDto.beforeGap(count: n),
            _Turn.pastGap => TurnAtDto.pastGap(count: n),
          },
          method: _method,
          resolveTurns: _resolve,
          decrease: decrease,
        );
      case KnitStepKind.castOn:
        final n = _int(_count);
        return n == null ? null : KnitStepActionDto.castOn(count: n);
      case KnitStepKind.bindOff:
        if (_rest) return KnitStepActionDto.bindOff(resolveTurns: _resolve);
        final n = _int(_count);
        return n == null ? null : KnitStepActionDto.bindOff(count: n, resolveTurns: _resolve);
      case KnitStepKind.hold:
        final name = _name.text.trim();
        if (name.isEmpty) return null;
        if (_rest) return KnitStepActionDto.hold(name: name);
        final n = _int(_count);
        return n == null ? null : KnitStepActionDto.hold(count: n, name: name);
      case KnitStepKind.resume:
        if (!_holds.any((h) => h.stepId == _hold)) return null;
        return KnitStepActionDto.resume(hold: _hold, facing: _facing);
      case KnitStepKind.unchecked:
        final text = _text.text.trim();
        if (text.isEmpty) return null;
        final raw = _change.text.trim();
        if (raw.isEmpty) return KnitStepActionDto.opaque(text: text);
        final d = int.tryParse(raw);
        if (d == null || d.abs() > kMaxStepCount) return null;
        return KnitStepActionDto.opaque(text: text, stitchChange: d);
      case KnitStepKind.joinRound:
        return const KnitStepActionDto.joinRound();
      case KnitStepKind.workFlat:
        final n = _int(_count);
        if (n == null) return null;
        return KnitStepActionDto.workFlat(count: n, name: _name.text.trim(), slipEdges: _slip);
      case KnitStepKind.rows:
        final n = _int(_count);
        if (n == null) return null;
        return KnitStepActionDto.rows(count: n, text: _text.text.trim());
      case KnitStepKind.shape:
        final n = _int(_count);
        final every = _int(_every);
        final target = _int(_target);
        if (n == null || every == null || target == null) return null;
        if (_chosenShapeGroups.length > kMaxNeedleGroups) return null;
        return KnitStepActionDto.shape(
          change: _shapeDecrease ? -n : n,
          every: every,
          until: _untilRemain
              ? ShapeUntilDto.remain(count: target)
              : ShapeUntilDto.times(count: target),
          groups: _chosenShapeGroups,
          text: _text.text.trim(),
        );
      case KnitStepKind.pickUp:
        final n = _int(_count);
        if (n == null) return null;
        final PickUpAlongDto along;
        if (_along.isNotEmpty) {
          // A part worked flat, even one no longer in the pattern: the step keeps naming it.
          along = PickUpAlongDto.piece(step: _along);
        } else {
          final edge = _text.text.trim();
          if (edge.isEmpty) return null;
          along = PickUpAlongDto.edge(text: edge);
        }
        return KnitStepActionDto.pickUp(
            count: n, along: along, group: _group.isEmpty ? null : _group);
      case KnitStepKind.groups:
        final groups = <NeedleGroupDto>[];
        for (final g in _groupRows) {
          final name = g.name.text.trim();
          final count = _int(g.count);
          if (name.isEmpty || count == null) return null;
          groups.add(NeedleGroupDto(name: name, count: count, notes: g.notes.text.trim()));
        }
        return KnitStepActionDto.groups(groups: groups);
      case KnitStepKind.close:
        if (!_closeHeld) return KnitStepActionDto.close(method: _close, holds: const []);
        if (_closeA.isEmpty || _closeB.isEmpty || _closeA == _closeB) return null;
        return KnitStepActionDto.close(method: _close, holds: [_closeA, _closeB]);
      case KnitStepKind.roundStart:
        return const KnitStepActionDto.roundStart();
      case KnitStepKind.join:
        // A piece or hold no longer in the pattern is kept, and saved as it is, until another is
        // chosen (the engine reports it).
        if (_joinPiece) {
          if (_piece.isEmpty) return null;
          return KnitStepActionDto.join(
              source: JoinSourceDto.piece(piece: _piece), stitch: _stitch, resolveTurns: _resolve);
        }
        if (_hold.isEmpty) return null;
        return KnitStepActionDto.join(
            source: JoinSourceDto.held(hold: _hold), stitch: _stitch, resolveTurns: _resolve);
    }
  }

  void _save() {
    final action = _action();
    if (action == null) {
      setState(() => _submitted = true);
      return;
    }
    Navigator.pop(context, action);
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.initial != null;
    return AlertDialog(
      title: Text(editing ? 'Edit step: ${widget.kind.label}' : widget.kind.label),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.kind.help, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            ..._fields(context),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          key: const Key('knit-step-save'),
          onPressed: _blocked() ? null : _save,
          child: const Text('Save'),
        ),
      ],
    );
  }

  /// Nothing can be saved at all (no chart rows to work, no group to return).
  bool _blocked() =>
      (widget.kind == KnitStepKind.chartRows && _height == 0) ||
      (widget.kind == KnitStepKind.resume && _holds.isEmpty) ||
      (widget.kind == KnitStepKind.join &&
          widget.pattern.pieces.length < 2 &&
          _holds.isEmpty &&
          _piece.isEmpty &&
          _hold.isEmpty);

  Widget _number(TextEditingController c, String label,
          {String? error, Key? key, bool signed = false, String? helper}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: TextField(
          key: key,
          controller: c,
          keyboardType: TextInputType.numberWithOptions(signed: signed),
          decoration: InputDecoration(
              labelText: label, errorText: error, helperText: helper, helperMaxLines: 3),
          onChanged: (_) => setState(() {}),
        ),
      );

  /// A group of radio choices with [value] selected.
  Widget _radios<T>(T value, void Function(Object?) onChanged, List<(T, String)> choices) =>
      RadioGroup<T>(
        groupValue: value,
        onChanged: onChanged,
        child: Column(
          children: [
            for (final (v, label) in choices)
              RadioListTile<T>(contentPadding: EdgeInsets.zero, title: Text(label), value: v),
          ],
        ),
      );

  Widget _stitchChoice() => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: SegmentedButton<WorkStitchKind>(
          segments: [
            for (final s in WorkStitchKind.values)
              ButtonSegment(value: s, label: Text(workStitchLabel(s))),
          ],
          selected: {_stitch},
          onSelectionChanged: (v) => setState(() => _stitch = v.first),
        ),
      );

  Widget _resolveSwitch() => SwitchListTile(
        key: const Key('knit-step-resolve'),
        contentPadding: EdgeInsets.zero,
        title: const Text('Work the short-row turns it crosses'),
        subtitle: const Text(
            'Work each wrap together with its stitch, and each double stitch as one stitch.'),
        value: _resolve,
        onChanged: (v) => setState(() => _resolve = v),
      );

  Widget _restSwitch(String what) => SwitchListTile(
        key: const Key('knit-step-rest'),
        contentPadding: EdgeInsets.zero,
        title: Text('$what every stitch left in the row'),
        value: _rest,
        onChanged: (v) => setState(() => _rest = v),
      );

  List<Widget> _fields(BuildContext context) {
    final muted = TextStyle(color: Theme.of(context).colorScheme.outline);
    switch (widget.kind) {
      case KnitStepKind.chartRows:
        if (_height == 0) {
          return [Text('The chart has no rows yet. Add rows in the chart first.', style: muted)];
        }
        final first = _int(_first, max: _height);
        final last = _int(_last, max: _height);
        return [
          Text('The chart has $_height ${_height == 1 ? 'row' : 'rows'}.', style: muted),
          const SizedBox(height: 8),
          _number(_first, 'From chart row',
              key: const Key('knit-step-first'), error: _countError(_first, max: _height)),
          _number(_last, 'To chart row',
              key: const Key('knit-step-last'),
              error: _countError(_last, max: _height) ??
                  (_submitted && first != null && last != null && last < first
                      ? 'The last row must not come before the first.'
                      : null)),
        ];
      case KnitStepKind.work:
        return [
          _stitchChoice(),
          _radios<_Reach>(_reach, (v) => setState(() => _reach = v as _Reach), [
            (_Reach.end, 'To the end of the row'),
            (_Reach.last, 'To the last stitches'),
            (_Reach.count, 'A number of stitches'),
          ]),
          if (_reach != _Reach.end)
            _number(_count, _reach == _Reach.last ? 'Stitches left at the end' : 'Stitches to work',
                key: const Key('knit-step-count'), error: _countError(_count)),
          _resolveSwitch(),
        ];
      case KnitStepKind.shortRow:
        return [
          _stitchChoice(),
          _radios<_Turn>(_turn, (v) => setState(() => _turn = v as _Turn), [
            (_Turn.last, 'Turn with this many stitches left'),
            (_Turn.count, 'Turn after this many stitches'),
            (_Turn.beforeGap, 'Turn this many stitches before the gap'),
            (_Turn.pastGap, 'Turn this many stitches past the gap'),
          ]),
          _number(_count, 'Stitches',
              key: const Key('knit-step-count'),
              error: _countError(_count, min: _gapTurn ? 0 : 1),
              helper: _gapTurn
                  ? 'The gap is where the last short row on this side turned. 0 turns right at '
                      'the gap.'
                  : null),
          SwitchListTile(
            key: const Key('knit-step-decrease'),
            contentPadding: EdgeInsets.zero,
            title: const Text('Decrease before turning'),
            subtitle: const Text('Work two stitches together, then a few more, then turn, as a '
                'heel turn does.'),
            value: _decrease,
            onChanged: (v) => setState(() => _decrease = v),
          ),
          if (_decrease) ...[
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: SegmentedButton<DecreaseKind>(
                segments: [
                  for (final d in DecreaseKind.values)
                    ButtonSegment(value: d, label: Text(decreaseLabel(d))),
                ],
                selected: {_decKind},
                onSelectionChanged: (v) => setState(() => _decKind = v.first),
              ),
            ),
            _number(_after, 'Stitches to work after the decrease',
                key: const Key('knit-step-after'), error: _countError(_after, min: 0)),
          ],
          const SizedBox(height: 4),
          Text('How to turn', style: Theme.of(context).textTheme.labelLarge),
          _radios<TurnMethodKind>(_method, (v) => setState(() => _method = v as TurnMethodKind), [
            for (final m in TurnMethodKind.values) (m, turnMethodLabel(m)),
          ]),
          _resolveSwitch(),
        ];
      case KnitStepKind.castOn:
        return [
          _number(_count, 'Stitches to cast on',
              key: const Key('knit-step-count'),
              error: _countError(_count),
              helper: 'On an empty needle this starts a piece. At the start of a row the new '
                  'stitches are worked in that row; in the middle of a row they go on the right '
                  'needle.'),
        ];
      case KnitStepKind.bindOff:
        return [
          _restSwitch('Bind off'),
          if (!_rest)
            _number(_count, 'Stitches to bind off',
                key: const Key('knit-step-count'), error: _countError(_count)),
          _resolveSwitch(),
        ];
      case KnitStepKind.hold:
        return [
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: TextField(
              key: const Key('knit-step-name'),
              controller: _name,
              decoration: InputDecoration(
                labelText: 'Name for these stitches',
                hintText: 'For example: center neck',
                errorMaxLines: 3,
                errorText: _lengthError(_name) ??
                    (_submitted && _name.text.trim().isEmpty
                        ? 'Give the group a name, so the step that returns it can say which.'
                        : null),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
          _restSwitch('Hold'),
          if (!_rest)
            _number(_count, 'Stitches to put on hold',
                key: const Key('knit-step-count'), error: _countError(_count)),
          Text('The next stitches on the left needle go on the holder.', style: muted),
        ];
      case KnitStepKind.resume:
        final holds = _holds;
        if (holds.isEmpty) {
          return [Text('No step puts stitches on hold yet. Add one first.', style: muted)];
        }
        final known = holds.any((h) => h.stepId == _hold);
        return [
          DropdownButtonFormField<String>(
            key: const Key('knit-step-hold'),
            initialValue: known ? _hold : null,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: 'Stitches to return',
              errorText: _submitted && !known ? 'Choose the stitches to return.' : null,
            ),
            items: [
              for (final h in holds)
                DropdownMenuItem(
                    value: h.stepId, child: Text(h.label, overflow: TextOverflow.ellipsis)),
            ],
            onChanged: (v) => setState(() => _hold = v ?? ''),
          ),
          const SizedBox(height: 12),
          Text('Side facing you', style: Theme.of(context).textTheme.labelLarge),
          _radios<SideKind?>(_facing, (v) => setState(() => _facing = v as SideKind?), [
            (SideKind.rs, 'Right side (RS)'),
            (SideKind.ws, 'Wrong side (WS)'),
            (null, 'Not stated'),
          ]),
          Text(
              'The stitches go back on the left needle, to be worked next. If the needle is '
              'empty, say which side faces you so Ply can tell which rows are RS and WS.',
              style: muted),
        ];
      case KnitStepKind.unchecked:
        return [
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: TextField(
              key: const Key('knit-step-text'),
              controller: _text,
              minLines: 2,
              maxLines: 6,
              decoration: InputDecoration(
                labelText: 'Instruction',
                errorMaxLines: 3,
                errorText: _lengthError(_text) ??
                    (_submitted && _text.text.trim().isEmpty ? 'Write the instruction.' : null),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
          _number(_change, 'Change in stitch count',
              key: const Key('knit-step-change'),
              signed: true,
              error: _submitted &&
                      _change.text.trim().isNotEmpty &&
                      (int.tryParse(_change.text.trim()) == null ||
                          int.parse(_change.text.trim()).abs() > kMaxStepCount)
                  ? 'Enter a whole number, such as 0, 4 or -2, or leave it blank.'
                  : null,
              helper: 'How many stitches this adds (or removes, with a minus sign). 0 if it '
                  'changes nothing. Leave it blank if you do not know; Ply then stops counting '
                  'after this step.'),
        ];
      case KnitStepKind.joinRound:
        return [
          Text(
              'From flat work, at the start of a row: the stitches join into a round, worked from '
              'the right side. After working part of the round flat: the stitches that rested join '
              'the round again, at the end of a right-side row.',
              style: muted),
        ];
      case KnitStepKind.workFlat:
        return [
          _number(_count, 'Stitches to work flat',
              key: const Key('knit-step-count'), error: _countError(_count)),
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: TextField(
              key: const Key('knit-step-name'),
              controller: _name,
              decoration: InputDecoration(
                  labelText: 'Name of the part',
                  hintText: 'For example: heel flap',
                  errorMaxLines: 3,
                  errorText: _lengthError(_name)),
              onChanged: (_) => setState(() {}),
            ),
          ),
          SwitchListTile(
            key: const Key('knit-step-slip'),
            contentPadding: EdgeInsets.zero,
            title: const Text('Slip the first stitch of every row'),
            subtitle: const Text(
                'Each side then has one slipped edge stitch for every two rows, to pick up along '
                'later.'),
            value: _slip,
            onChanged: (v) => setState(() => _slip = v),
          ),
          Text(
              'Starts at the beginning of the round with the next stitches. The other stitches '
              'rest on the needle until a "Join in the round" step.',
              style: muted),
        ];
      case KnitStepKind.rows:
        return [
          _number(_count, 'Rows or rounds',
              key: const Key('knit-step-count'), error: _countError(_count)),
          _wordsField('What they work (not checked)',
              hint: 'For example: knit',
              helper: 'Ply counts the rows and checks the stitch count stays the same. It does '
                  'not read these words.'),
        ];
      case KnitStepKind.shape:
        final names = _groupNames;
        return [
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: true, label: Text('Decrease')),
                ButtonSegment(value: false, label: Text('Increase')),
              ],
              selected: {_shapeDecrease},
              onSelectionChanged: (v) => setState(() => _shapeDecrease = v.first),
            ),
          ),
          _number(_count,
              _shapeDecrease ? 'Stitches to decrease each time' : 'Stitches to increase each time',
              key: const Key('knit-step-count'),
              error: _countError(_count),
              helper: 'On each needle group chosen below, or on the whole needle when none is.'),
          _number(_every, 'Every how many rows or rounds',
              key: const Key('knit-step-every'),
              error: _countError(_every),
              helper: '1 shapes every row or round, 2 every other one. The first row or round '
                  'worked is a shaping one.'),
          _radios<bool>(_untilRemain, (v) => setState(() => _untilRemain = v as bool), const [
            (false, 'This many times'),
            (true, 'Until this many stitches remain'),
          ]),
          _number(_target, _untilRemain ? 'Stitches to remain' : 'Times',
              key: const Key('knit-step-target'), error: _countError(_target)),
          if (names.isEmpty && _initialGroups.isEmpty)
            Text('No needle groups yet: the shaping is on the whole needle.', style: muted)
          else ...[
            Text('Needle groups to shape', style: Theme.of(context).textTheme.labelLarge),
            for (final g in [
              ...names,
              for (final g in _initialGroups)
                if (!names.contains(g)) g,
            ])
              CheckboxListTile(
                key: Key('knit-step-shape-group-$g'),
                contentPadding: EdgeInsets.zero,
                // A group the step named that no group step sets any more: kept until unticked.
                title: Text(names.contains(g) ? g : '$g (not found)'),
                value: _shapeGroups.contains(g),
                onChanged: (v) => setState(() {
                  if (v ?? false) {
                    _shapeGroups.add(g);
                  } else {
                    _shapeGroups.remove(g);
                  }
                }),
              ),
            if (_chosenShapeGroups.length > kMaxNeedleGroups)
              Text('Choose at most $kMaxNeedleGroups needle groups.',
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
          _wordsField('Each shaping row, in the pattern\'s words (optional)',
              hint: 'For example: k1, ssk, knit to last 3 sts, k2tog, k1'),
        ];
      case KnitStepKind.pickUp:
        final parts = _flatParts;
        final known = parts.any((h) => h.stepId == _along);
        final names = _groupNames;
        return [
          _number(_count, 'Stitches to pick up',
              key: const Key('knit-step-count'), error: _countError(_count)),
          DropdownButtonFormField<String>(
            key: const Key('knit-step-along'),
            initialValue: _along,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Along'),
            items: [
              for (final h in parts)
                DropdownMenuItem(
                    value: h.stepId,
                    child: Text('A side of ${h.label}', overflow: TextOverflow.ellipsis)),
              // The step it names is gone: kept, and saved as it is, until another is chosen.
              if (_along.isNotEmpty && !known)
                DropdownMenuItem(
                    value: _along,
                    child: const Text('A part worked flat (not found)',
                        overflow: TextOverflow.ellipsis)),
              const DropdownMenuItem(value: '', child: Text('Another edge')),
            ],
            onChanged: (v) => setState(() => _along = v ?? ''),
          ),
          if (_along.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 8),
              child: TextField(
                key: const Key('knit-step-edge'),
                controller: _text,
                decoration: InputDecoration(
                  labelText: 'Which edge',
                  hintText: 'For example: the cast-on edge',
                  errorMaxLines: 3,
                  errorText: _lengthError(_text) ??
                      (_submitted && _text.text.trim().isEmpty
                          ? 'Say which edge, such as "the cast-on edge".'
                          : null),
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
          if (names.isNotEmpty || _group.isNotEmpty)
            DropdownButtonFormField<String>(
              key: const Key('knit-step-group'),
              initialValue: _group,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Add them to the needle group'),
              items: [
                for (final g in names) DropdownMenuItem(value: g, child: Text(g)),
                // A group no group step sets any more: kept, and saved, until another is chosen.
                if (_group.isNotEmpty && !names.contains(_group))
                  DropdownMenuItem(value: _group, child: Text('$_group (not found)')),
                const DropdownMenuItem(value: '', child: Text('No group')),
              ],
              onChanged: (v) => setState(() => _group = v ?? ''),
            ),
          const SizedBox(height: 8),
          Text(
              'Picked up with the right side facing, where the work is. Along a part worked flat, '
              'Ply finds the side and says how many slipped edge stitches or rows it has; it never '
              'guesses how many to pick up.',
              style: muted),
        ];
      case KnitStepKind.groups:
        return [
          Text(
              'In working order from the start of the round (or of the next row). The counts '
              'must add up to the stitches on the needle. With no groups, Ply stops counting '
              'them.',
              style: muted),
          const SizedBox(height: 8),
          for (var i = 0; i < _groupRows.length; i++)
            // Keyed by the group, not its place: removing one keeps the others' fields intact.
            Column(
              key: ValueKey('knit-step-group-${_groupRows[i].id}'),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                        child:
                            Text('Group ${i + 1}', style: Theme.of(context).textTheme.labelLarge)),
                    IconButton(
                      key: Key('knit-step-group-remove-$i'),
                      tooltip: 'Remove group ${i + 1}',
                      icon: const Icon(Icons.close),
                      onPressed: () => _removeGroup(i),
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: TextField(
                    key: Key('knit-step-group-name-$i'),
                    controller: _groupRows[i].name,
                    decoration: InputDecoration(
                      labelText: 'Name',
                      hintText: 'For example: instep',
                      errorMaxLines: 3,
                      errorText: _lengthError(_groupRows[i].name) ??
                          (_submitted && _groupRows[i].name.text.trim().isEmpty
                              ? 'Give the group a name.'
                              : null),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                _number(_groupRows[i].count, 'Stitches',
                    key: Key('knit-step-group-count-$i'), error: _countError(_groupRows[i].count)),
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: TextField(
                    key: Key('knit-step-group-notes-$i'),
                    controller: _groupRows[i].notes,
                    decoration: InputDecoration(
                        labelText: 'Note (optional)',
                        hintText: 'For example: needles 1 and 2',
                        errorMaxLines: 3,
                        errorText: _lengthError(_groupRows[i].notes)),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ],
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const Key('knit-step-group-add'),
              onPressed: _groupRows.length >= kMaxNeedleGroups
                  ? null
                  : () => setState(() => _groupRows.add(_GroupFields())),
              icon: const Icon(Icons.add),
              label: const Text('Add a group'),
            ),
          ),
          if (_groupRows.length >= kMaxNeedleGroups)
            Text('Ply keeps at most $kMaxNeedleGroups needle groups in one step.', style: muted),
        ];
      case KnitStepKind.roundStart:
        return [
          Text(
              'Knit to where the new start should be first (for example "knit 9 sts" to the center '
              'of the heel); the round then starts there. Every stitch keeps its place and its '
              'needle group.',
              style: muted),
        ];
      case KnitStepKind.join:
        return _joinFields(context, muted);
      case KnitStepKind.close:
        return [
          _radios<CloseMethodKind>(_close, (v) => setState(() => _close = v as CloseMethodKind), [
            for (final m in CloseMethodKind.values) (m, closeMethodLabel(m)),
          ]),
          SwitchListTile(
            key: const Key('knit-step-close-held'),
            contentPadding: EdgeInsets.zero,
            title: const Text('Close two groups on hold'),
            subtitle: const Text('Such as the underarm stitches held on the body and on a sleeve.'),
            value: _closeHeld,
            onChanged: (v) => setState(() => _closeHeld = v),
          ),
          if (_closeHeld) ...[
            _holdChoice(const Key('knit-step-close-a'), 'First group', _closeA,
                (v) => setState(() => _closeA = v)),
            _holdChoice(const Key('knit-step-close-b'), 'Second group', _closeB,
                (v) => setState(() => _closeB = v),
                error: _submitted && _closeA.isNotEmpty && _closeA == _closeB
                    ? 'Choose two different groups.'
                    : null),
            Text(
                'Ply closes the two groups against each other, wherever the work is; they must '
                'be the same size.',
                style: muted),
          ] else
            Text(
                'Closes every stitch on the needle. They must be in two needle groups of the same '
                'size, or an even number of stitches with no groups, which Ply divides in half.',
                style: muted),
        ];
    }
  }

  /// A choice of one hold step's group, keeping one the pattern no longer has as "(not found)".
  Widget _holdChoice(Key key, String label, String value, void Function(String) onChanged,
      {String? error}) {
    final holds = _holds;
    final known = holds.any((h) => h.stepId == value);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: DropdownButtonFormField<String>(
        key: key,
        initialValue: value.isEmpty ? null : value,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: label,
          errorMaxLines: 2,
          errorText: error ?? (_submitted && value.isEmpty ? 'Choose the stitches on hold.' : null),
        ),
        items: [
          for (final h in holds)
            DropdownMenuItem(
                value: h.stepId, child: Text(h.label, overflow: TextOverflow.ellipsis)),
          if (value.isNotEmpty && !known)
            DropdownMenuItem(
                value: value,
                child: const Text('Held stitches (not found)', overflow: TextOverflow.ellipsis)),
        ],
        onChanged: (v) => onChanged(v ?? ''),
      ),
    );
  }

  /// The join form: another piece or held stitches, the stitch, and the short-row turns.
  List<Widget> _joinFields(BuildContext context, TextStyle muted) {
    final pieces = widget.pattern.pieces;
    final holds = _holds;
    // Never the piece the step's own section works: a piece cannot join itself.
    final own = widget.sectionIndex == null
        ? null
        : knitSectionPieceIndex(widget.pattern, widget.sectionIndex!);
    final choices = [
      for (var i = 0; i < pieces.length; i++)
        if (i != own) i,
    ];
    final pieceKnown = choices.any((i) => pieces[i].id == _piece);
    final holdKnown = holds.any((h) => h.stepId == _hold);
    return [
      Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: SegmentedButton<bool>(
          key: const Key('knit-step-join-source'),
          segments: const [
            ButtonSegment(value: true, label: Text('Another piece')),
            ButtonSegment(value: false, label: Text('Held stitches')),
          ],
          selected: {_joinPiece},
          onSelectionChanged: (v) => setState(() => _joinPiece = v.first),
        ),
      ),
      if (_joinPiece)
        if (choices.isEmpty && _piece.isEmpty)
          Text(
              pieces.isEmpty
                  ? 'This pattern is one piece. Add pieces on the Sections screen (such as a '
                      'sleeve) to join one here.'
                  : 'There is no other piece to join. Add one on the Sections screen.',
              style: muted)
        else
          DropdownButtonFormField<String>(
            key: const Key('knit-step-join-piece'),
            initialValue: _piece.isEmpty ? null : _piece,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: 'Piece to join',
              errorText: _submitted && _piece.isEmpty ? 'Choose the piece to join.' : null,
            ),
            items: [
              for (final i in choices)
                DropdownMenuItem(
                    value: pieces[i].id,
                    child: Text(knitCapitalized(knitPieceTitle(widget.pattern, i)),
                        overflow: TextOverflow.ellipsis)),
              if (_piece.isNotEmpty && !pieceKnown)
                DropdownMenuItem(
                    value: _piece,
                    child: Text(
                        own != null && own < pieces.length && pieces[own].id == _piece
                            ? 'This piece (it cannot join itself)'
                            : 'A piece (not found)',
                        overflow: TextOverflow.ellipsis)),
            ],
            onChanged: (v) => setState(() => _piece = v ?? ''),
          )
      else if (holds.isEmpty && _hold.isEmpty)
        Text('No step puts stitches on hold yet. Add one first.', style: muted)
      else
        DropdownButtonFormField<String>(
          key: const Key('knit-step-join-hold'),
          initialValue: _hold.isEmpty ? null : _hold,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: 'Stitches to knit',
            errorText: _submitted && _hold.isEmpty ? 'Choose the stitches to knit.' : null,
          ),
          items: [
            for (final h in holds)
              DropdownMenuItem(
                  value: h.stepId, child: Text(h.label, overflow: TextOverflow.ellipsis)),
            if (_hold.isNotEmpty && !holdKnown)
              DropdownMenuItem(
                  value: _hold,
                  child: const Text('Held stitches (not found)', overflow: TextOverflow.ellipsis)),
          ],
          onChanged: (v) => setState(() => _hold = v ?? ''),
        ),
      const SizedBox(height: 12),
      _stitchChoice(),
      _resolveSwitch(),
      Text(
          'Knitted with the right side facing where the work is: partway through a right-side row '
          'or a round, or at the end of one. On an empty needle they start this piece. A piece '
          'joined here is part of this piece from then on.',
          style: muted),
    ];
  }

  /// Remove group [i]. Its fields are let go after this frame, once nothing shows them.
  void _removeGroup(int i) {
    final removed = _groupRows[i];
    setState(() => _groupRows.removeAt(i));
    WidgetsBinding.instance.addPostFrameCallback((_) => removed.dispose());
  }

  /// A text field for the pattern's own words (rows, shaping), which Ply does not check.
  Widget _wordsField(String label, {String? hint, String? helper}) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: TextField(
          key: const Key('knit-step-text'),
          controller: _text,
          minLines: 1,
          maxLines: 4,
          decoration: InputDecoration(
              labelText: label,
              hintText: hint,
              helperText: helper,
              helperMaxLines: 3,
              errorMaxLines: 3,
              errorText: _lengthError(_text)),
          onChanged: (_) => setState(() {}),
        ),
      );
}

class _TextDialog extends StatefulWidget {
  const _TextDialog({required this.title, required this.label, required this.initial});

  final String title;
  final String label;
  final String initial;

  @override
  State<_TextDialog> createState() => _TextDialogState();
}

class _TextDialogState extends State<_TextDialog> {
  late final TextEditingController _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Past what a section's notes may hold, the text stays here to shorten (never saved, never lost).
    final tooLong = knitTextTooLong(_controller.text.trim());
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        key: const Key('knit-text-dialog-field'),
        controller: _controller,
        autofocus: true,
        minLines: 2,
        maxLines: 6,
        decoration: InputDecoration(
            labelText: widget.label,
            errorText: tooLong ? kKnitTextTooLong : null,
            errorMaxLines: 3),
        onChanged: (_) => setState(() {}),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          key: const Key('knit-text-dialog-save'),
          onPressed: tooLong ? null : () => Navigator.pop(context, _controller.text.trim()),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
