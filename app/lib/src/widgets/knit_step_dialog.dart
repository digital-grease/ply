import 'package:flutter/material.dart';

import '../models/knit_sections.dart';
import '../rust/knit_dto.dart';

/// Open the form for a section step of [kind]: a new step (no [initial]) or an edit of one. Returns
/// the step's action on Save, or null on Cancel. [pattern] supplies the chart's height (for chart
/// rows) and the hold steps a "return held stitches" step can name. The form checks only that each
/// number is a whole number in range; whether the step fits the stitches on the needle is the
/// engine ledger's call, shown beside the step.
Future<KnitStepActionDto?> showKnitStepDialog(
  BuildContext context, {
  required KnitStepKind kind,
  required KnitPatternDto pattern,
  KnitStepActionDto? initial,
}) =>
    showDialog<KnitStepActionDto>(
      context: context,
      builder: (_) => KnitStepDialog(kind: kind, pattern: pattern, initial: initial),
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

/// The step form. Public for tests.
class KnitStepDialog extends StatefulWidget {
  const KnitStepDialog({required this.kind, required this.pattern, this.initial, super.key});

  final KnitStepKind kind;
  final KnitPatternDto pattern;
  final KnitStepActionDto? initial;

  @override
  State<KnitStepDialog> createState() => _KnitStepDialogState();
}

class _KnitStepDialogState extends State<KnitStepDialog> {
  late final KnitStepActionDto _start =
      widget.initial ?? defaultKnitStepAction(widget.kind, widget.pattern);

  // Every field the forms use; each kind reads the ones it needs.
  final _count = TextEditingController();
  final _first = TextEditingController();
  final _last = TextEditingController();
  final _name = TextEditingController();
  final _text = TextEditingController();
  final _change = TextEditingController();
  WorkStitchKind _stitch = WorkStitchKind.knit;
  _Reach _reach = _Reach.end;
  TurnMethodKind _method = TurnMethodKind.wrapAndTurn;
  bool _resolve = false;
  bool _rest = true; // bind off / hold: the rest of the row
  String _hold = '';
  SideKind? _facing;
  bool _submitted = false;

  int get _height => widget.pattern.chart.rows.length;
  List<KnitHoldRef> get _holds => knitHoldSteps(widget.pattern);

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
      case KnitStepActionDto_ShortRow(:final stitch, :final to, :final method, :final resolveTurns):
        _stitch = stitch;
        _method = method;
        _resolve = resolveTurns;
        switch (to) {
          case TurnAtDto_Last(:final count):
            _reach = _Reach.last;
            _count.text = '$count';
          case TurnAtDto_Count(:final count):
            _reach = _Reach.count;
            _count.text = '$count';
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
    }
  }

  @override
  void dispose() {
    for (final c in [_count, _first, _last, _name, _text, _change]) {
      c.dispose();
    }
    super.dispose();
  }

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
        final n = _int(_count);
        if (n == null) return null;
        return KnitStepActionDto.shortRow(
          stitch: _stitch,
          to: _reach == _Reach.count ? TurnAtDto.count(count: n) : TurnAtDto.last(count: n),
          method: _method,
          resolveTurns: _resolve,
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
      (widget.kind == KnitStepKind.resume && _holds.isEmpty);

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
          _radios<_Reach>(_reach == _Reach.end ? _Reach.last : _reach,
              (v) => setState(() => _reach = v as _Reach), [
            (_Reach.last, 'Turn with this many stitches left'),
            (_Reach.count, 'Turn after this many stitches'),
          ]),
          _number(_count, 'Stitches',
              key: const Key('knit-step-count'), error: _countError(_count)),
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
                errorText: _submitted && _name.text.trim().isEmpty
                    ? 'Give the group a name, so the step that returns it can say which.'
                    : null,
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
                errorText:
                    _submitted && _text.text.trim().isEmpty ? 'Write the instruction.' : null,
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
    }
  }
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
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.title),
        content: TextField(
          controller: _controller,
          autofocus: true,
          minLines: 2,
          maxLines: 6,
          decoration: InputDecoration(labelText: widget.label),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, _controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      );
}
