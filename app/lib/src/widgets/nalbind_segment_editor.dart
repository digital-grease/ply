import 'package:flutter/material.dart';

import '../models/nalbind_recipe.dart';
import '../models/nalbind_recipe_view.dart' show recipeTextTooLong;

/// An earlier opening a pick-up can start from or a join can close: its segment id and how the
/// editor names it (`Step 4: Thumb opening`).
class RecipeOpeningChoice {
  const RecipeOpeningChoice(this.id, this.label);
  final String id;
  final String label;
}

/// The sheet of segment kinds, grouped by phase, each with its help line. Resolves to the chosen
/// kind, or null when dismissed.
Future<SegmentKind?> showSegmentKindChooser(BuildContext context) =>
    showModalBottomSheet<SegmentKind>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.75,
          maxChildSize: 0.95,
          builder: (context, scroll) => ListView(
            controller: scroll,
            children: [
              for (final phase in RecipePhase.values) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Semantics(
                    header: true,
                    child: Text(phase == RecipePhase.other ? 'Anything else' : phase.label,
                        style: Theme.of(context).textTheme.titleSmall),
                  ),
                ),
                for (final kind in SegmentKind.values.where((k) => k.phase == phase))
                  ListTile(
                    key: ValueKey('segment-kind-${kind.json}'),
                    title: Text(kind.label),
                    subtitle: Text(kind.help),
                    onTap: () => Navigator.of(context).pop(kind),
                  ),
              ],
            ],
          ),
        ),
      ),
    );

/// Open the form for one segment of [kind] (a full-screen page). Resolves to the edited segment,
/// or null when cancelled. [initial] is the segment being edited (null for a new one, which gets
/// [id]); [openings] are the earlier openings a pick-up or join can name; [projectStitch] names the
/// project's stitch for the "the project's stitch" choice.
Future<RecipeSegment?> showSegmentEditor(
  BuildContext context, {
  required SegmentKind kind,
  required String id,
  RecipeSegment? initial,
  List<RecipeOpeningChoice> openings = const [],
  required String projectStitch,
}) =>
    Navigator.of(context).push<RecipeSegment>(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => NalbindSegmentEditor(
        kind: kind,
        id: id,
        initial: initial,
        openings: openings,
        projectStitch: projectStitch,
      ),
    ));

/// The kind-specific form for one recipe segment: a label, the stitch (the project's or its own,
/// with its notation kept exactly as typed), the kind's numbers and choices, how far it goes,
/// what it aims for, notes and a caution. Only whole-number and unit checks happen here; whether
/// the step fits the recipe is the engine's call, shown on the recipe screen.
class NalbindSegmentEditor extends StatefulWidget {
  const NalbindSegmentEditor({
    required this.kind,
    required this.id,
    this.initial,
    this.openings = const [],
    required this.projectStitch,
    super.key,
  });

  final SegmentKind kind;
  final String id;
  final RecipeSegment? initial;
  final List<RecipeOpeningChoice> openings;
  final String projectStitch;

  /// The most a count field takes: what a file and the bridge carry. The engine says when a stitch
  /// number is past what it counts (1,000,000), as it does for one in a file.
  static const int maxCount = kMaxRecipeCount;

  @override
  State<NalbindSegmentEditor> createState() => _NalbindSegmentEditorState();
}

/// How far a segment goes, as the form offers it.
enum _Reach { unstated, rounds, untilStitches, until }

class _NalbindSegmentEditorState extends State<NalbindSegmentEditor> {
  final _form = GlobalKey<FormState>();
  final _title = TextEditingController();
  final _notation = TextEditingController();
  final _stitchName = TextEditingController();
  final _stitches = TextEditingController();
  final _skip = TextEditingController();
  final _perRound = TextEditingController();
  final _reachCount = TextEditingController();
  final _untilLabel = TextEditingController();
  final _untilValue = TextEditingController();
  final _targetLabel = TextEditingController();
  final _targetValue = TextEditingController();
  final _text = TextEditingController();
  final _notes = TextEditingController();
  final _caution = TextEditingController();

  bool _ownStitch = false;
  StitchReading _reading = StitchReading.strict;
  ChainJoin? _chainJoin;
  RoundJoin? _roundJoin;
  IncreaseMethod? _increaseMethod;
  DecreaseMethod? _decreaseMethod;
  FinishMethod? _finishMethod;
  String? _reference;
  RecipePhase _role = RecipePhase.other;
  _Reach _reach = _Reach.unstated;
  LengthUnit? _untilUnit;
  LengthUnit? _targetUnit;
  Map<String, Object?> _untilExtra = const {};
  Map<String, Object?> _targetExtra = const {};

  SegmentKind get _kind => widget.kind;

  @override
  void initState() {
    super.initState();
    final s = widget.initial;
    if (s == null) return;
    _title.text = s.title;
    final stitch = s.stitch;
    if (stitch != null) {
      _ownStitch = true;
      _notation.text = stitch.notation;
      _stitchName.text = stitch.name;
      _reading = stitch.reading;
    }
    _stitches.text = s.stitches?.toString() ?? '';
    _skip.text = s.skip?.toString() ?? '';
    _perRound.text = s.perRound?.toString() ?? '';
    _chainJoin = s.chainJoin;
    _roundJoin = s.roundJoin;
    _increaseMethod = s.increaseMethod;
    _decreaseMethod = s.decreaseMethod;
    _finishMethod = s.finishMethod;
    _reference = s.reference;
    _role = s.role;
    _text.text = s.text;
    _notes.text = s.notes;
    _caution.text = s.caution;
    final extent = s.extent;
    if (extent != null) {
      switch (extent.type) {
        case ExtentType.rounds:
          _reach = _Reach.rounds;
          _reachCount.text = '${extent.count}';
        case ExtentType.untilStitches:
          _reach = _Reach.untilStitches;
          _reachCount.text = '${extent.count}';
        case ExtentType.until:
          _reach = _Reach.until;
          _untilLabel.text = extent.measure!.label;
          _untilValue.text = _number(extent.measure!.value);
          _untilExtra = extent.measure!.extra;
          _untilUnit = extent.measure!.unit;
      }
    }
    final target = s.target;
    if (target != null) {
      _targetLabel.text = target.label;
      _targetValue.text = _number(target.value);
      _targetExtra = target.extra;
      _targetUnit = target.unit;
    }
  }

  @override
  void dispose() {
    for (final c in [
      _title,
      _notation,
      _stitchName,
      _stitches,
      _skip,
      _perRound,
      _reachCount,
      _untilLabel,
      _untilValue,
      _targetLabel,
      _targetValue,
      _text,
      _notes,
      _caution,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  static String _number(double? v) => v == null ? '' : formatRecipeNumber(v);

  /// A whole number from 0 to the cap, or null for an empty field.
  static int? _count(String text) => text.trim().isEmpty ? null : int.tryParse(text.trim());

  static String? _countError(String? v, {bool required = false}) {
    final t = (v ?? '').trim();
    if (t.isEmpty) return required ? 'Enter a whole number' : null;
    final n = int.tryParse(t);
    if (n == null || n < 0) return 'Enter a whole number';
    if (n > NalbindSegmentEditor.maxCount) return 'Enter a number up to 4,294,967,295';
    return null;
  }

  static double? _decimal(String text) {
    final t = text.trim().replaceAll(',', '.');
    if (t.isEmpty) return null;
    final v = double.tryParse(t);
    return v != null && v.isFinite ? v : null;
  }

  static String? _decimalError(String? v) {
    final t = (v ?? '').trim();
    if (t.isEmpty) return null;
    return _decimal(t) == null ? 'Enter a number' : null;
  }

  Measurement? _measure(String label, String value, LengthUnit? unit,
      {bool always = false, Map<String, Object?> extra = const {}}) {
    final m = Measurement(label: label.trim(), value: _decimal(value), unit: unit, extra: extra);
    if (!always && m.label.isEmpty && m.value == null && m.unit == null) return null;
    return m;
  }

  /// The extent the form holds, keeping the keys a newer Ply wrote on it when its type is the same.
  Extent? _extent() {
    final before = widget.initial?.extent;
    Map<String, Object?> extra(ExtentType t) =>
        before != null && before.type == t ? before.extra : const {};
    return switch (_reach) {
      _Reach.unstated => null,
      _Reach.rounds => Extent.rounds(_count(_reachCount.text)!, extra: extra(ExtentType.rounds)),
      _Reach.untilStitches =>
        Extent.untilStitches(_count(_reachCount.text)!, extra: extra(ExtentType.untilStitches)),
      _Reach.until => Extent.until(
          _measure(_untilLabel.text, _untilValue.text, _untilUnit,
              always: true, extra: _untilExtra)!,
          extra: extra(ExtentType.until)),
    };
  }

  RecipeSegment _compose() {
    final k = _kind;
    final usesStitches = const {
      SegmentKind.foundationChain,
      SegmentKind.centreStart,
      SegmentKind.pickUp,
      SegmentKind.opening,
    }.contains(k);
    // A kind this form shows no stitch for keeps the one it had (a file may carry one).
    final SegmentStitch? stitch = k.usesStitch
        ? (_ownStitch
            ? SegmentStitch(
                notation: _notation.text.trim(),
                name: _stitchName.text.trim(),
                reading: _reading,
                extra: widget.initial?.stitch?.extra ?? const {},
              )
            : null)
        : widget.initial?.stitch;
    return RecipeSegment(
      id: widget.initial?.id ?? widget.id,
      kind: k,
      title: _title.text.trim(),
      stitch: stitch,
      stitches: usesStitches ? _count(_stitches.text) : null,
      skip: k == SegmentKind.opening ? _count(_skip.text) : null,
      chainJoin: k == SegmentKind.foundationChain ? _chainJoin : null,
      roundJoin: k == SegmentKind.rounds ? _roundJoin : null,
      perRound:
          k == SegmentKind.increase || k == SegmentKind.decrease ? _count(_perRound.text) : null,
      increaseMethod: k == SegmentKind.increase ? _increaseMethod : null,
      decreaseMethod: k == SegmentKind.decrease ? _decreaseMethod : null,
      finishMethod: k == SegmentKind.finish ? _finishMethod : null,
      extent: k.hasExtent ? _extent() : null,
      reference: k == SegmentKind.pickUp || k == SegmentKind.join ? _reference : null,
      role: k == SegmentKind.freeform ? _role : RecipePhase.other,
      text: k == SegmentKind.freeform ? _text.text : '',
      target: k == SegmentKind.freeform
          ? null
          : _measure(_targetLabel.text, _targetValue.text, _targetUnit, extra: _targetExtra),
      notes: _notes.text,
      caution: _caution.text,
      // Keys a newer Ply wrote on the step, or on its work, stay as they were.
      extra: widget.initial?.extra ?? const {},
      workExtra: widget.initial?.workExtra ?? const {},
    );
  }

  void _done() {
    if (!(_form.currentState?.validate() ?? false)) return;
    Navigator.of(context).pop(_compose());
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final k = _kind;
    const gap = SizedBox(height: 12);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.initial == null ? 'New step: ${k.label}' : 'Edit step: ${k.label}'),
        actions: [
          TextButton(
              key: const ValueKey('segment-done'), onPressed: _done, child: const Text('Done')),
        ],
      ),
      // Not a lazy list: every field stays built, so the form validates all of them, even those
      // scrolled out of view.
      body: Form(
        key: _form,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(k.help, style: text.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
              gap,
              TextFormField(
                key: const ValueKey('segment-title'),
                controller: _title,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  labelText: 'Label (optional)',
                  hintText: _titleHint(k),
                ),
                validator: recipeTextTooLong,
              ),
              if (k.usesStitch) ..._stitchFields(text, cs),
              ..._kindFields(),
              if (k.hasExtent) ..._extentFields(),
              if (k != SegmentKind.freeform) ..._targetFields(text),
              gap,
              _multiline('segment-notes', _notes, 'Construction notes',
                  'How to work it: placement, tension, what to check.'),
              gap,
              _multiline('segment-caution', _caution, 'Watch out for (optional)',
                  'A warning for whoever follows the recipe.'),
            ],
          ),
        ),
      ),
    );
  }

  static String _titleHint(SegmentKind k) => switch (k) {
        SegmentKind.foundationChain => 'e.g. Cuff start',
        SegmentKind.centreStart => 'e.g. Crown',
        SegmentKind.pickUp => 'e.g. Thumb',
        SegmentKind.opening => 'e.g. Thumb opening',
        SegmentKind.finish => 'e.g. Close the top',
        _ => 'e.g. Hand',
      };

  Widget _multiline(String key, TextEditingController c, String label, String hint) =>
      TextFormField(
        key: ValueKey(key),
        controller: c,
        maxLines: null,
        minLines: 2,
        keyboardType: TextInputType.multiline,
        textCapitalization: TextCapitalization.sentences,
        decoration: InputDecoration(
          border: const OutlineInputBorder(),
          labelText: label,
          hintText: hint,
          alignLabelWithHint: true,
        ),
        validator: recipeTextTooLong,
      );

  Widget _countField(String key, TextEditingController c, String label, {bool required = false}) =>
      Padding(
        padding: const EdgeInsets.only(top: 12),
        child: TextFormField(
          key: ValueKey(key),
          controller: c,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: label,
            helperText: required ? null : 'Leave blank if the recipe does not say.',
          ),
          validator: (v) => _countError(v, required: required),
        ),
      );

  Widget _dropdown<T>(
          String key, String label, T? value, Map<T?, String> items, ValueChanged<T?> onChanged) =>
      Padding(
        padding: const EdgeInsets.only(top: 12),
        child: DropdownButtonFormField<T?>(
          key: ValueKey(key),
          initialValue: value,
          isExpanded: true,
          decoration: InputDecoration(labelText: label),
          items: [
            for (final e in items.entries)
              DropdownMenuItem<T?>(
                  value: e.key, child: Text(e.value, overflow: TextOverflow.ellipsis)),
          ],
          onChanged: (v) => setState(() => onChanged(v)),
        ),
      );

  List<Widget> _stitchFields(TextTheme text, ColorScheme cs) => [
        const SizedBox(height: 16),
        Semantics(header: true, child: Text('Stitch', style: text.titleSmall)),
        RadioGroup<bool>(
          groupValue: _ownStitch,
          onChanged: (v) => setState(() => _ownStitch = v ?? false),
          child: Column(
            children: [
              RadioListTile<bool>(
                key: const ValueKey('segment-project-stitch'),
                value: false,
                contentPadding: EdgeInsets.zero,
                title: const Text("The project's stitch"),
                subtitle: Text(widget.projectStitch.isEmpty
                    ? 'No stitch is chosen for the project yet.'
                    : widget.projectStitch),
              ),
              const RadioListTile<bool>(
                key: ValueKey('segment-own-stitch'),
                value: true,
                contentPadding: EdgeInsets.zero,
                title: Text('Its own stitch'),
                subtitle: Text('For example a cuff in a denser connection.'),
              ),
            ],
          ),
        ),
        if (_ownStitch) ...[
          TextFormField(
            key: const ValueKey('segment-notation'),
            controller: _notation,
            autocorrect: false,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: 'Hansen notation',
              hintText: 'e.g. UO/UOO F2',
              helperText: 'Kept exactly as typed. The connection (such as F1 or B1) says how '
                  'this step joins the round before.',
              helperMaxLines: 3,
            ),
            validator: (v) => recipeTextTooLong(v, max: kMaxRecipeNotation),
          ),
          const SizedBox(height: 12),
          TextFormField(
            key: const ValueKey('segment-stitch-name'),
            controller: _stitchName,
            decoration: const InputDecoration(
              labelText: 'Stitch name (optional)',
              hintText: 'e.g. Oslo, F2 connection',
            ),
            validator: recipeTextTooLong,
          ),
          _dropdown<StitchReading>(
            'segment-reading',
            'Read the notation',
            _reading,
            {for (final r in StitchReading.values) r: r.label},
            (v) => _reading = v ?? StitchReading.strict,
          ),
        ],
      ];

  List<RecipeOpeningChoice> _openingChoices() {
    final choices = [...widget.openings];
    final ref = _reference;
    if (ref != null && !choices.any((c) => c.id == ref)) {
      // Keep a reference the list does not offer (a later opening, or one not in the recipe), so
      // editing never drops it; the recipe screen says what is wrong with it.
      choices.add(RecipeOpeningChoice(ref, 'Not an earlier opening ($ref)'));
    }
    return choices;
  }

  List<Widget> _kindFields() {
    switch (_kind) {
      case SegmentKind.foundationChain:
        return [
          _countField('segment-stitches', _stitches, 'Stitches in the chain'),
          _dropdown<ChainJoin>(
              'segment-chain-join',
              'Then',
              _chainJoin,
              {
                null: 'Not stated',
                for (final j in ChainJoin.values) j: j.label,
              },
              (v) => _chainJoin = v),
        ];
      case SegmentKind.centreStart:
        return [_countField('segment-stitches', _stitches, 'Stitches in the first round')];
      case SegmentKind.pickUp:
        return [
          _dropdown<String>(
              'segment-reference',
              'Start from',
              _reference,
              {
                null: 'Earlier work (not a named opening)',
                for (final o in _openingChoices()) o.id: o.label,
              },
              (v) => _reference = v),
          _countField('segment-stitches', _stitches, 'Loops to pick up'),
        ];
      case SegmentKind.rounds:
        return [
          _dropdown<RoundJoin>(
              'segment-round-join',
              'Worked',
              _roundJoin,
              {
                null: 'Not stated',
                for (final j in RoundJoin.values) j: j.label,
              },
              (v) => _roundJoin = v),
        ];
      case SegmentKind.increase:
        return [
          _countField('segment-per-round', _perRound, 'Stitches added in each round'),
          _dropdown<IncreaseMethod>(
              'segment-method',
              'How',
              _increaseMethod,
              {
                null: 'Not stated',
                for (final m in IncreaseMethod.values) m: m.label,
              },
              (v) => _increaseMethod = v),
        ];
      case SegmentKind.decrease:
        return [
          _countField('segment-per-round', _perRound, 'Stitches taken away in each round'),
          _dropdown<DecreaseMethod>(
              'segment-method',
              'How',
              _decreaseMethod,
              {
                null: 'Not stated',
                for (final m in DecreaseMethod.values) m: m.label,
              },
              (v) => _decreaseMethod = v),
        ];
      case SegmentKind.opening:
        return [
          _countField('segment-skip', _skip, 'Loops of the previous round to skip'),
          _countField('segment-stitches', _stitches, 'Stitches to work across the gap'),
        ];
      case SegmentKind.join:
        return [
          _dropdown<String>(
              'segment-reference',
              'Closes',
              _reference,
              {
                null: 'No opening (join edges)',
                for (final o in _openingChoices()) o.id: o.label,
              },
              (v) => _reference = v),
        ];
      case SegmentKind.finish:
        return [
          _dropdown<FinishMethod>(
              'segment-method',
              'How',
              _finishMethod,
              {
                null: 'Not stated',
                for (final m in FinishMethod.values) m: m.label,
              },
              (v) => _finishMethod = v),
        ];
      case SegmentKind.freeform:
        return [
          _dropdown<RecipePhase>(
              'segment-role',
              'Where it belongs',
              _role,
              {
                for (final p in RecipePhase.values)
                  p: p == RecipePhase.other ? 'A note, not a step of the work' : p.label,
              },
              (v) => _role = v ?? RecipePhase.other),
          const SizedBox(height: 12),
          _multiline('segment-text', _text, 'Your instructions',
              'Written exactly as you want it followed. Ply does not read or check it.'),
        ];
      case SegmentKind.rows:
      case SegmentKind.shortRows:
        return const [];
    }
  }

  List<Widget> _extentFields() {
    final rows = _kind.countsRows;
    final shaping = _kind == SegmentKind.increase || _kind == SegmentKind.decrease;
    return [
      _dropdown<_Reach>(
          'segment-reach',
          'How far',
          _reach,
          {
            _Reach.unstated: 'Not stated',
            _Reach.rounds: rows ? 'A number of rows' : 'A number of rounds',
            if (shaping)
              _Reach.untilStitches: _kind == SegmentKind.increase
                  ? 'Until there are this many stitches'
                  : 'Until this many stitches remain'
            // A file can say this for rounds or rows: it is kept (the recipe screen says why it
            // cannot be checked) rather than missing from the list.
            else if (_reach == _Reach.untilStitches)
              _Reach.untilStitches: 'Until there are this many stitches (only shaping changes it)',
            _Reach.until: 'Until it measures or reaches something',
          },
          (v) => _reach = v ?? _Reach.unstated),
      if (_reach == _Reach.rounds || _reach == _Reach.untilStitches)
        _countField(
          'segment-reach-count',
          _reachCount,
          _reach == _Reach.untilStitches ? 'Stitches' : (rows ? 'Rows' : 'Rounds'),
          required: true,
        ),
      if (_reach == _Reach.until) ...[
        const SizedBox(height: 12),
        TextFormField(
          key: const ValueKey('segment-until-label'),
          controller: _untilLabel,
          decoration: const InputDecoration(
            labelText: 'Until',
            hintText: 'e.g. it reaches the base of the thumb, or: from the cuff edge',
          ),
          validator: recipeTextTooLong,
        ),
        ..._lengthRow(
            'segment-until', _untilValue, _untilUnit, (u) => _untilUnit = u, 'Measures (optional)'),
      ],
    ];
  }

  List<Widget> _lengthRow(String key, TextEditingController value, LengthUnit? unit,
          ValueChanged<LengthUnit?> onUnit, String label) =>
      [
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 3,
              child: TextFormField(
                key: ValueKey('$key-value'),
                controller: value,
                keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                decoration: InputDecoration(labelText: label),
                validator: _decimalError,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: DropdownButtonFormField<LengthUnit?>(
                key: ValueKey('$key-unit'),
                initialValue: unit,
                decoration: const InputDecoration(labelText: 'Unit'),
                items: [
                  const DropdownMenuItem<LengthUnit?>(value: null, child: Text('None')),
                  for (final u in LengthUnit.values)
                    DropdownMenuItem<LengthUnit?>(value: u, child: Text(u.json)),
                ],
                onChanged: (u) => setState(() => onUnit(u)),
                // A length needs its unit: Ply never guesses one.
                validator: (u) =>
                    u == null && _decimal(value.text) != null ? 'Choose a unit' : null,
              ),
            ),
          ],
        ),
      ];

  List<Widget> _targetFields(TextTheme text) => [
        const SizedBox(height: 16),
        Semantics(header: true, child: Text('Aim for (optional)', style: text.titleSmall)),
        TextFormField(
          key: const ValueKey('segment-target-label'),
          controller: _targetLabel,
          decoration: const InputDecoration(
            labelText: 'What',
            hintText: 'e.g. Width across the crown',
          ),
          validator: recipeTextTooLong,
        ),
        ..._lengthRow(
            'segment-target', _targetValue, _targetUnit, (u) => _targetUnit = u, 'Length'),
      ];
}
