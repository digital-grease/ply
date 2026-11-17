// Add or edit one swatch (ADR 0016): the craft and technique, the yarns, the tools and (for weaving)
// the loom setup, what was measured at each stage with how it was measured, the finishing, the
// swatch's mass, tension notes, the date and where the numbers came from, and photos. Every field is
// optional. What Ply works out (gauge per 10 cm, shrinkage, take-up, draw-in) is shown below the
// form and never saved in place of a measurement.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/materials_repository.dart' show kSwatchPhotoDir;
import '../models/draft_doc.dart' show MeasureUnit;
import '../models/material_record.dart';
import '../state/material_providers.dart';
import '../state/theme_providers.dart';
import '../theme/spacing.dart';
import '../widgets/project_photos.dart';
import '../widgets/quantity_fields.dart';
import '../widgets/record_report_panel.dart';
import '../widgets/unsaved_changes_guard.dart';
import 'materials_screen.dart' show failureMessage;

class SwatchEditScreen extends ConsumerStatefulWidget {
  const SwatchEditScreen({this.swatch, super.key});

  /// The swatch to edit, or null to add one.
  final SwatchRecord? swatch;

  @override
  ConsumerState<SwatchEditScreen> createState() => _SwatchEditScreenState();
}

/// The entries of one stage.
class _StageEntries {
  _StageEntries(SwatchStage s, {required LengthUnit unit, required Length span})
      : width = LengthEntry(initial: s.width, defaultUnit: unit),
        length = LengthEntry(initial: s.length, defaultUnit: unit),
        across = CountEntry(initial: s.across, defaultSpan: span),
        along = CountEntry(initial: s.along, defaultSpan: span),
        conditions = TextEditingController(text: s.conditions);

  final LengthEntry width;
  final LengthEntry length;
  final CountEntry across;
  final CountEntry along;
  final TextEditingController conditions;

  SwatchStage get value => SwatchStage(
        width: width.value,
        length: length.value,
        across: across.value,
        along: along.value,
        conditions: conditions.text,
      );

  bool get isBlank => value.isEmpty;

  List<String> get errors => [
        for (final e in [
          width.error,
          length.error,
          across.countError,
          across.spanError,
          along.countError,
          along.spanError,
        ])
          if (e != null) e,
      ];

  /// Give the counts that are still blank the craft's usual span.
  void respan(Length span) {
    for (final c in [across, along]) {
      if (c.count.text.trim().isEmpty) {
        c.span.text = exactQuantityNumber(span.value);
        c.unit = span.unit;
      }
    }
  }

  void dispose() {
    width.dispose();
    length.dispose();
    across.dispose();
    along.dispose();
    conditions.dispose();
  }
}

class _SwatchEditScreenState extends ConsumerState<SwatchEditScreen> {
  late final String _id = widget.swatch?.id ?? ref.read(materialLibraryProvider.notifier).newId();

  /// What the library holds for this swatch (null until a new swatch is first saved).
  late SwatchRecord? _saved = widget.swatch;
  late final _name = TextEditingController(text: widget.swatch?.name ?? '');
  late final _technique = TextEditingController(text: widget.swatch?.technique ?? '');
  late final _date = TextEditingController(text: widget.swatch?.date ?? '');
  late final _tools = TextEditingController(text: widget.swatch?.tools ?? '');
  late final _finishing = TextEditingController(text: widget.swatch?.finishing ?? '');
  late final _tension = TextEditingController(text: widget.swatch?.tension ?? '');
  late final _provenance = TextEditingController(text: widget.swatch?.provenance ?? '');
  late final _notes = TextEditingController(text: widget.swatch?.notes ?? '');
  late SwatchCraft? _craft = widget.swatch?.craft;
  late List<SwatchYarn> _yarns = [...?widget.swatch?.yarns];
  late final CountEntry _sett;
  late final LengthEntry _widthInReed;
  late final Map<StageKind, _StageEntries> _stages;
  late final MassEntry _mass;
  late final MeasureUnit _unit;
  RecordReport _report = RecordReport.empty;
  int _seq = 0;
  bool _saving = false;
  bool _leaving = false;

  @override
  void initState() {
    super.initState();
    _unit = ref.read(appSettingsProvider).unit;
    final s = widget.swatch ?? SwatchRecord(id: _id);
    final short = shortUnitFor(_unit);
    _sett = CountEntry(
        initial: s.sett,
        defaultSpan: _span(SwatchCraft.weaving),
        defaultSource: ValueSource.entered);
    _widthInReed =
        LengthEntry(initial: s.widthInReed, defaultUnit: short, defaultSource: ValueSource.entered);
    _stages = {
      for (final k in StageKind.values)
        k: _StageEntries(s.stage(k), unit: short, span: _span(_craft)),
    };
    _mass = MassEntry(initial: s.mass);
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshReport());
  }

  @override
  void dispose() {
    for (final c in [_name, _technique, _date, _tools, _finishing, _tension, _provenance, _notes]) {
      c.dispose();
    }
    _sett.dispose();
    _widthInReed.dispose();
    for (final e in _stages.values) {
      e.dispose();
    }
    _mass.dispose();
    super.dispose();
  }

  /// The usual span a count is taken over: an inch (or a cm) for a weaving sett and picks, 4 in (or
  /// 10 cm) for a knitting or nalbinding gauge.
  Length _span(SwatchCraft? craft) {
    final metric = _unit == MeasureUnit.centimeters;
    if (craft == SwatchCraft.weaving) {
      return metric ? const Length(1, LengthUnit.centimeter) : const Length(1, LengthUnit.inch);
    }
    return metric ? const Length(10, LengthUnit.centimeter) : const Length(4, LengthUnit.inch);
  }

  bool get _weaving => _craft == SwatchCraft.weaving;

  /// Weaving parts are shown for a weaving swatch, and for any swatch that has them filled in (so
  /// nothing typed is ever hidden).
  bool get _showLoom =>
      _weaving ||
      _sett.count.text.trim().isNotEmpty ||
      _widthInReed.text.text.trim().isNotEmpty ||
      !_stages[StageKind.onLoom]!.isBlank;

  SwatchRecord _built() => SwatchRecord(
        id: _id,
        name: _name.text.trim(),
        craft: _craft,
        technique: _technique.text.trim(),
        date: _date.text.trim().isEmpty ? null : _date.text.trim(),
        yarns: List.unmodifiable(_yarns),
        tools: _tools.text.trim(),
        sett: _sett.value,
        widthInReed: _widthInReed.value,
        onLoom: _stages[StageKind.onLoom]!.value,
        before: _stages[StageKind.before]!.value,
        after: _stages[StageKind.after]!.value,
        finishing: _finishing.text,
        mass: _mass.value,
        tension: _tension.text,
        provenance: _provenance.text.trim(),
        notes: _notes.text,
      );

  bool get _dirty => _built() != (_saved ?? SwatchRecord(id: _id));

  void _changed() {
    setState(() {});
    _refreshReport();
  }

  Future<void> _refreshReport() async {
    final seq = ++_seq;
    try {
      final r = await ref.read(materialsRepositoryProvider).swatchReport(_built());
      if (mounted && seq == _seq) setState(() => _report = r);
    } catch (_) {/* the panel keeps its last report */}
  }

  static final RegExp _datePattern = RegExp(r'^\d{4}-\d{2}-\d{2}$');

  String? get _dateError {
    final t = _date.text.trim();
    if (t.isEmpty) return null;
    final d = DateTime.tryParse(t);
    final ok = _datePattern.hasMatch(t) &&
        d != null &&
        d.year == int.parse(t.substring(0, 4)) &&
        d.month == int.parse(t.substring(5, 7)) &&
        d.day == int.parse(t.substring(8, 10));
    return ok ? null : 'Write the date as YYYY-MM-DD, or leave it blank.';
  }

  List<String> get _fieldErrors => [
        if (_dateError != null) _dateError!,
        for (final e in [_sett.countError, _sett.spanError, _widthInReed.error, _mass.error])
          if (e != null) e,
        for (final s in _stages.values) ...s.errors,
        if (_name.text.runes.length > MaterialLimits.maxNameChars) 'The name is too long.',
        for (final t in [_technique, _tools, _provenance])
          if (t.text.runes.length > MaterialLimits.maxShortTextChars) 'A field is too long.',
        for (final t in [_finishing, _tension, _notes, ..._stages.values.map((s) => s.conditions)])
          if (t.text.runes.length > MaterialLimits.maxNotesChars) 'A field is too long.',
      ];

  Future<bool> _save() async {
    if (_saving) return false;
    final messenger = ScaffoldMessenger.of(context);
    if (_fieldErrors.isNotEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('Fix the fields marked in red first.')));
      return false;
    }
    setState(() => _saving = true);
    final record = _built();
    try {
      final report = await ref.read(materialsRepositoryProvider).swatchReport(record);
      if (report.hasErrors) {
        if (mounted) setState(() => _report = report);
        messenger.showSnackBar(
            const SnackBar(content: Text('Some values cannot be right. See the notes below.')));
        return false;
      }
      await ref.read(materialLibraryProvider.notifier).upsertSwatch(record);
      if (!mounted) return true;
      // Saved in place, so photos can be added to a new swatch straight away.
      setState(() => _saved = record);
      messenger.showSnackBar(const SnackBar(content: Text('Saved.')));
      return true;
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(failureMessage(e))));
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _onLeave(bool didPop, Object? _) async {
    if (didPop || _leaving) return;
    _leaving = true;
    try {
      final action =
          await showLeaveWithoutSavingDialog(context, noun: 'swatch') ?? LeaveAction.keepEditing;
      if (!mounted) return;
      switch (action) {
        case LeaveAction.discard:
          Navigator.of(context).pop();
        case LeaveAction.save:
          if (await _save() && mounted) Navigator.of(context).pop();
        case LeaveAction.keepEditing:
          break;
      }
    } finally {
      if (mounted) _leaving = false;
    }
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final current = DateTime.tryParse(_date.text.trim()) ?? now;
    final d = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(1900),
      lastDate: DateTime(now.year + 1, 12, 31),
    );
    if (d == null) return;
    String two(int v) => v.toString().padLeft(2, '0');
    _date.text = '${d.year}-${two(d.month)}-${two(d.day)}';
    _changed();
  }

  Future<void> _addYarn() async {
    final materials = ref.read(materialLibraryProvider).valueOrNull?.materials ?? const [];
    final yarn = await showDialog<SwatchYarn>(
      context: context,
      builder: (_) => _YarnDialog(materials: materials, weaving: _weaving),
    );
    if (yarn == null) return;
    _yarns = [..._yarns, yarn];
    _changed();
  }

  String _yarnLabel(SwatchYarn y) {
    final lib = ref.read(materialLibraryProvider).valueOrNull;
    final m = y.materialId == null ? null : lib?.material(y.materialId!);
    final name = m?.displayName ?? (y.name.trim().isEmpty ? 'Unnamed yarn' : y.name.trim());
    final missing = y.materialId != null && lib != null && m == null && !lib.readOnly;
    return [
      name,
      if (y.role != null) y.role!.label.toLowerCase(),
      if (missing) 'not in your materials',
    ].join(', ');
  }

  String get _techniqueLabel => switch (_craft) {
        SwatchCraft.weaving => 'Weave structure',
        SwatchCraft.knitting => 'Stitch pattern',
        SwatchCraft.nalbinding => 'Stitch and connection',
        null => 'Technique',
      };

  String get _techniqueHelp => switch (_craft) {
        SwatchCraft.weaving => 'Such as plain weave or 2/2 twill.',
        SwatchCraft.knitting => 'Such as stockinette or 2x2 rib.',
        SwatchCraft.nalbinding => 'The stitch and its connection, such as Oslo UO/UOO F1.',
        null => 'The stitch pattern, weave structure, or nalbinding stitch.',
      };

  String get _toolsLabel => switch (_craft) {
        SwatchCraft.weaving => 'Loom and reed',
        SwatchCraft.knitting => 'Needles',
        SwatchCraft.nalbinding => 'Needle and thumb',
        null => 'Tools',
      };

  String get _toolsHelp => switch (_craft) {
        SwatchCraft.weaving => 'Such as table loom, 12-dent reed, 2 per dent.',
        SwatchCraft.knitting => 'Size and kind, such as 4 mm bamboo circular.',
        SwatchCraft.nalbinding => 'The needle, and how the thumb loop was held.',
        null => 'Needles, hook, or loom and reed.',
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final help = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    const gap = SizedBox(height: PlySpacing.md);
    final draftSwatch = _built();
    final across = draftSwatch.acrossNoun;
    final along = draftSwatch.alongNoun;
    final stages = [
      if (_showLoom) StageKind.onLoom,
      StageKind.before,
      StageKind.after,
    ];
    return PopScope<Object?>(
      canPop: !_dirty,
      onPopInvokedWithResult: _onLeave,
      child: Scaffold(
        appBar: AppBar(
          title: Text(_saved == null ? 'Add swatch' : 'Edit swatch'),
          actions: [
            TextButton(
                key: const ValueKey('swatch-save'),
                onPressed: _saving ? null : _save,
                child: const Text('Save')),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(PlySpacing.md),
          children: [
            Text(
                'Every field is optional. Record what you measured, as you measured it: Ply works '
                'out the rest and never replaces your numbers.',
                style: help),
            gap,
            _text(_name, 'swatch-name', 'Name', 'What you call this swatch.'),
            gap,
            Text('Craft', style: theme.textTheme.titleSmall),
            const SizedBox(height: PlySpacing.xs),
            Wrap(
              spacing: PlySpacing.xs,
              children: [
                for (final c in [null, ...SwatchCraft.values])
                  ChoiceChip(
                    key: ValueKey('swatch-craft-${c?.serialName ?? 'none'}'),
                    label: Text(c?.label ?? 'Not recorded'),
                    selected: _craft == c,
                    onSelected: (_) {
                      _craft = c;
                      for (final s in _stages.values) {
                        s.respan(_span(c));
                      }
                      _changed();
                    },
                  ),
              ],
            ),
            gap,
            _text(_technique, 'swatch-technique', _techniqueLabel, _techniqueHelp),
            gap,
            TextField(
              key: const ValueKey('swatch-date'),
              controller: _date,
              onChanged: (_) => _changed(),
              decoration: InputDecoration(
                labelText: 'Date',
                hintText: 'YYYY-MM-DD',
                helperText: 'When you made or measured it.',
                errorText: _dateError,
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  tooltip: 'Choose a date',
                  icon: const Icon(Icons.calendar_today_outlined),
                  onPressed: _pickDate,
                ),
              ),
            ),
            gap,
            Text('Yarns', style: theme.textTheme.titleSmall),
            Text('From your materials, or just a name.', style: help),
            for (var i = 0; i < _yarns.length; i++)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(_yarnLabel(_yarns[i])),
                trailing: IconButton(
                  tooltip: 'Remove this yarn',
                  icon: const Icon(Icons.close),
                  onPressed: () {
                    _yarns = [..._yarns]..removeAt(i);
                    _changed();
                  },
                ),
              ),
            if (_yarns.length < MaterialLimits.maxSwatchYarns)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const ValueKey('swatch-add-yarn'),
                  onPressed: _addYarn,
                  icon: const Icon(Icons.add),
                  label: const Text('Add yarn'),
                ),
              ),
            gap,
            _text(_tools, 'swatch-tools', _toolsLabel, _toolsHelp),
            if (_showLoom) ...[
              gap,
              Text('Loom setup', style: theme.textTheme.titleSmall),
              const SizedBox(height: PlySpacing.xs),
              CountEntryField(
                entry: _sett,
                label: 'Sett in the reed',
                noun: 'ends',
                fieldKey: 'swatch-sett',
                onChanged: _changed,
                helper: 'Ends per inch (or per cm) as you sleyed it.',
              ),
              const SizedBox(height: PlySpacing.sm),
              LengthEntryField(
                entry: _widthInReed,
                label: 'Width in the reed',
                fieldKey: 'swatch-width-in-reed',
                onChanged: _changed,
                helper: 'How wide the warp was in the reed. Ply works out the draw-in from it.',
              ),
            ],
            for (final k in stages) ...[
              const Divider(height: PlySpacing.lg),
              _stageSection(k, draftSwatch.stageName(k), across, along, help),
            ],
            const Divider(height: PlySpacing.lg),
            TextField(
              key: const ValueKey('swatch-finishing'),
              controller: _finishing,
              minLines: 1,
              maxLines: 4,
              onChanged: (_) => _changed(),
              decoration: const InputDecoration(
                labelText: 'Finishing',
                helperText: 'How it was finished: washed, blocked, pressed or fulled, the water, '
                    'and how it dried.',
                helperMaxLines: 2,
                border: OutlineInputBorder(),
              ),
            ),
            gap,
            MassEntryField(
              entry: _mass,
              label: 'Swatch mass',
              fieldKey: 'swatch-mass',
              onChanged: _changed,
              helper: 'Weigh the dry swatch. With its size and one yarn\'s length per mass, the '
                  'knitting yarn estimate can work from it.',
            ),
            gap,
            _text(_tension, 'swatch-tension', 'Tension notes',
                'How firmly you worked or beat it, and anything that changed partway.'),
            gap,
            _text(_provenance, 'swatch-provenance', 'Provenance',
                'Who made and measured it, or where the numbers came from (a pattern, a class).'),
            gap,
            _text(_notes, 'swatch-notes', 'Notes', 'Anything else.'),
            const Divider(height: PlySpacing.lg),
            Text('Photos', style: theme.textTheme.titleSmall),
            const SizedBox(height: PlySpacing.xs),
            if (_saved != null)
              ProjectPhotos(
                subdir: kSwatchPhotoDir,
                id: _id,
                pickImagePath: ref.read(swatchPhotoPickerProvider),
              )
            else
              Text('Save the swatch to add photos. They stay on this device.', style: help),
            const Divider(height: PlySpacing.lg),
            RecordReportPanel(
              report: _report,
              emptyText: 'Record sizes or counts before and after finishing, and Ply works out '
                  'how much it changed.',
            ),
          ],
        ),
      ),
    );
  }

  Widget _stageSection(StageKind k, String name, String across, String along, TextStyle? help) {
    final e = _stages[k]!;
    final theme = Theme.of(context);
    final key = 'swatch-${k.name}';
    final intro = switch (k) {
      StageKind.onLoom => 'Measured on the loom, under tension, while weaving.',
      StageKind.before =>
        _weaving ? 'Off the loom, relaxed, before wet finishing.' : 'Before washing or blocking.',
      StageKind.after => _weaving
          ? 'After wet finishing, dry and relaxed.'
          : 'After washing or blocking, dry and relaxed. Plans use these counts first.',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          header: true,
          child: Text('${name[0].toUpperCase()}${name.substring(1)}',
              style: theme.textTheme.titleSmall),
        ),
        Text(intro, style: help),
        const SizedBox(height: PlySpacing.sm),
        LengthEntryField(
            entry: e.width, label: 'Width', fieldKey: '$key-width', onChanged: _changed),
        const SizedBox(height: PlySpacing.sm),
        LengthEntryField(
            entry: e.length, label: 'Length', fieldKey: '$key-length', onChanged: _changed),
        const SizedBox(height: PlySpacing.sm),
        CountEntryField(
          entry: e.across,
          label: _weaving ? 'Ends' : 'Stitches',
          noun: across,
          fieldKey: '$key-across',
          onChanged: _changed,
          helper: _weaving
              ? null
              : 'Count in the middle, away from the edges, over as wide a span as you can.',
        ),
        const SizedBox(height: PlySpacing.sm),
        CountEntryField(
          entry: e.along,
          label: _weaving ? 'Picks' : 'Rows',
          noun: along,
          fieldKey: '$key-along',
          onChanged: _changed,
        ),
        const SizedBox(height: PlySpacing.sm),
        TextField(
          key: ValueKey('$key-conditions'),
          controller: e.conditions,
          onChanged: (_) => _changed(),
          decoration: const InputDecoration(
            labelText: 'How it was measured',
            helperText: 'Flat or hanging, pinned or relaxed, how long it rested.',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
      ],
    );
  }

  Widget _text(TextEditingController c, String key, String label, String helper) => TextField(
        key: ValueKey(key),
        controller: c,
        onChanged: (_) => _changed(),
        decoration: InputDecoration(
          labelText: label,
          helperText: helper,
          helperMaxLines: 2,
          border: const OutlineInputBorder(),
        ),
      );
}

/// Choose a yarn for a swatch: one of the materials, or a name alone, with an optional role.
class _YarnDialog extends StatefulWidget {
  const _YarnDialog({required this.materials, required this.weaving});

  final List<MaterialRecord> materials;
  final bool weaving;

  @override
  State<_YarnDialog> createState() => _YarnDialogState();
}

class _YarnDialogState extends State<_YarnDialog> {
  MaterialRecord? _material;
  YarnRole? _role;
  final _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final roles = widget.weaving
        ? const [YarnRole.warp, YarnRole.weft]
        : const [YarnRole.main, YarnRole.contrast];
    return AlertDialog(
      title: const Text('Add yarn'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.materials.isNotEmpty)
            DropdownButtonFormField<MaterialRecord?>(
              key: const ValueKey('yarn-material'),
              initialValue: _material,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'From your materials'),
              items: [
                const DropdownMenuItem<MaterialRecord?>(value: null, child: Text('None')),
                for (final m in widget.materials)
                  DropdownMenuItem<MaterialRecord?>(value: m, child: Text(m.displayName)),
              ],
              onChanged: (m) => setState(() => _material = m),
            ),
          if (_material == null)
            TextField(
              key: const ValueKey('yarn-name'),
              controller: _name,
              decoration: const InputDecoration(labelText: 'Yarn name'),
            ),
          DropdownButtonFormField<YarnRole?>(
            key: const ValueKey('yarn-role'),
            initialValue: _role,
            decoration: const InputDecoration(labelText: 'Used as'),
            items: [
              const DropdownMenuItem<YarnRole?>(value: null, child: Text('Not recorded')),
              for (final r in roles) DropdownMenuItem<YarnRole?>(value: r, child: Text(r.label)),
            ],
            onChanged: (r) => setState(() => _role = r),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('yarn-add'),
          onPressed: () => Navigator.pop(
            context,
            SwatchYarn(
              materialId: _material?.id,
              name: clipRunes(_material?.name ?? _name.text.trim(), MaterialLimits.maxNameChars),
              role: _role,
            ),
          ),
          child: const Text('Add'),
        ),
      ],
    );
  }
}
