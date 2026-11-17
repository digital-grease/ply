// Add or edit one material (ADR 0016). Every field is optional and says what it is for; a value left
// blank stays unknown. What Ply works out (yards per 100 g, the length on hand) is shown below the
// form and never saved.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/material_record.dart';
import '../state/material_providers.dart';
import '../state/theme_providers.dart';
import '../theme/spacing.dart';
import '../widgets/quantity_fields.dart';
import '../widgets/record_report_panel.dart';
import '../widgets/unsaved_changes_guard.dart';
import 'materials_screen.dart' show failureMessage;

class MaterialEditScreen extends ConsumerStatefulWidget {
  const MaterialEditScreen({this.material, super.key});

  /// The material to edit, or null to add one.
  final MaterialRecord? material;

  @override
  ConsumerState<MaterialEditScreen> createState() => _MaterialEditScreenState();
}

class _MaterialEditScreenState extends ConsumerState<MaterialEditScreen> {
  late final MaterialRecord? _m = widget.material;
  late final String _id = _m?.id ?? ref.read(materialLibraryProvider.notifier).newId();
  late final _name = TextEditingController(text: _m?.name ?? '');
  late final _maker = TextEditingController(text: _m?.maker ?? '');
  late final _structure = TextEditingController(text: _m?.structure ?? '');
  late final _color = TextEditingController(text: _m?.color ?? '');
  late final _dyeLot = TextEditingController(text: _m?.dyeLot ?? '');
  late final _notes = TextEditingController(text: _m?.notes ?? '');
  final _fiber = TextEditingController();
  final _fiberPercent = TextEditingController();
  late List<FiberPart> _fibers = [...?_m?.fibers];
  late YarnWeightCategory? _weight = _m?.weight;
  late final LengthPerMassEntry _lpm;
  late final CountEntry _wpi;
  late final MassEntry _availableMass;
  late final LengthEntry _availableLength;
  String? _fiberError;
  RecordReport _report = RecordReport.empty;
  int _seq = 0;
  bool _saving = false;
  bool _leaving = false;

  @override
  void initState() {
    super.initState();
    final unit = ref.read(appSettingsProvider).unit;
    _lpm = LengthPerMassEntry(initial: _m?.lengthPerMass, defaultUnit: longUnitFor(unit));
    _wpi = CountEntry(initial: _m?.wpi, defaultSpan: const Length(1, LengthUnit.inch));
    _availableMass = MassEntry(initial: _m?.availableMass);
    _availableLength = LengthEntry(
        initial: _m?.availableLength,
        defaultUnit: longUnitFor(unit),
        defaultSource: ValueSource.entered);
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshReport());
  }

  @override
  void dispose() {
    for (final c in [_name, _maker, _structure, _color, _dyeLot, _notes, _fiber, _fiberPercent]) {
      c.dispose();
    }
    _lpm.dispose();
    _wpi.dispose();
    _availableMass.dispose();
    _availableLength.dispose();
    super.dispose();
  }

  MaterialRecord _built() => MaterialRecord(
        id: _id,
        name: _name.text.trim(),
        maker: _maker.text.trim(),
        fibers: List.unmodifiable(_fibers),
        weight: _weight,
        structure: _structure.text.trim(),
        lengthPerMass: _lpm.value,
        wpi: _wpi.value,
        color: _color.text.trim(),
        dyeLot: _dyeLot.text.trim(),
        availableMass: _availableMass.value,
        availableLength: _availableLength.value,
        notes: _notes.text,
      );

  bool get _dirty {
    final original = _m ?? MaterialRecord(id: _id);
    return _built() != original || _fiber.text.trim().isNotEmpty;
  }

  void _changed() {
    setState(() {});
    _refreshReport();
  }

  /// The engine's report for the form as it is now, latest wins.
  Future<void> _refreshReport() async {
    final seq = ++_seq;
    try {
      final r = await ref.read(materialsRepositoryProvider).materialReport(_built());
      if (mounted && seq == _seq) setState(() => _report = r);
    } catch (_) {/* the panel keeps its last report */}
  }

  List<String> get _fieldErrors => [
        for (final e in [
          _lpm.lengthError,
          _lpm.lengthPairError,
          _lpm.massError,
          _wpi.countError,
          _wpi.spanError,
          _availableMass.error,
          _availableLength.error,
        ])
          if (e != null) e,
        if (_name.text.runes.length > MaterialLimits.maxNameChars) 'The name is too long.',
        for (final t in [_maker, _structure, _color, _dyeLot])
          if (t.text.runes.length > MaterialLimits.maxShortTextChars) 'A field is too long.',
        if (_notes.text.runes.length > MaterialLimits.maxNotesChars) 'The notes are too long.',
      ];

  void _addFiber() {
    final name = _fiber.text.trim();
    final pctText = _fiberPercent.text.trim();
    final pct = pctText.isEmpty ? null : double.tryParse(pctText);
    if (name.isEmpty) {
      setState(() => _fiberError = 'Enter the fiber, such as wool.');
      return;
    }
    if (pctText.isNotEmpty && (pct == null || !pct.isFinite || pct <= 0 || pct > 100)) {
      setState(() => _fiberError = 'Enter a share above 0 and at most 100, or leave it blank.');
      return;
    }
    if (_fibers.length >= MaterialLimits.maxFibers) {
      setState(() => _fiberError = 'A blend can list up to ${MaterialLimits.maxFibers} fibers.');
      return;
    }
    _fibers = [..._fibers, FiberPart(clipRunes(name, MaterialLimits.maxShortTextChars), pct)];
    _fiber.clear();
    _fiberPercent.clear();
    _fiberError = null;
    _changed();
  }

  Future<bool> _save() async {
    if (_saving) return false;
    if (_fiber.text.trim().isNotEmpty) {
      _addFiber(); // a fiber typed but not added yet is kept
      if (_fiberError != null) return false;
    }
    final messenger = ScaffoldMessenger.of(context);
    if (_fieldErrors.isNotEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('Fix the fields marked in red first.')));
      return false;
    }
    setState(() => _saving = true);
    final record = _built();
    try {
      final report = await ref.read(materialsRepositoryProvider).materialReport(record);
      if (report.hasErrors) {
        if (mounted) setState(() => _report = report);
        messenger.showSnackBar(
            const SnackBar(content: Text('Some values cannot be right. See the notes below.')));
        return false;
      }
      await ref.read(materialLibraryProvider.notifier).upsertMaterial(record);
      if (mounted) Navigator.of(context).pop();
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
          await showLeaveWithoutSavingDialog(context, noun: 'material') ?? LeaveAction.keepEditing;
      if (!mounted) return;
      switch (action) {
        case LeaveAction.discard:
          Navigator.of(context).pop();
        case LeaveAction.save:
          await _save();
        case LeaveAction.keepEditing:
          break;
      }
    } finally {
      if (mounted) _leaving = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final help = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    const gap = SizedBox(height: PlySpacing.md);
    return PopScope<Object?>(
      canPop: !_dirty,
      onPopInvokedWithResult: _onLeave,
      child: Scaffold(
        appBar: AppBar(
          title: Text(_m == null ? 'Add material' : 'Edit material'),
          actions: [
            TextButton(
                key: const ValueKey('material-save'),
                onPressed: _saving ? null : _save,
                child: const Text('Save')),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(PlySpacing.md),
          children: [
            Text(
                'Every field is optional. Leave out what you do not know: an estimate that needs '
                'it says it was assumed.',
                style: help),
            gap,
            _text(_name, 'material-name', 'Name', 'What you call this yarn, such as Grey wool.'),
            gap,
            _text(_maker, 'material-maker', 'Maker and yarn',
                'The mill or brand and the yarn\'s own name.'),
            gap,
            Text('Fiber blend', style: theme.textTheme.titleSmall),
            Text('The fibers in the label\'s order, with their share by weight when you know it.',
                style: help),
            if (_fibers.isNotEmpty)
              Wrap(
                spacing: PlySpacing.xs,
                children: [
                  for (var i = 0; i < _fibers.length; i++)
                    InputChip(
                      label: Text(_fibers[i].label),
                      deleteButtonTooltipMessage: 'Remove this fiber',
                      onDeleted: () {
                        _fibers = [..._fibers]..removeAt(i);
                        _changed();
                      },
                    ),
                ],
              ),
            const SizedBox(height: PlySpacing.xs),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 3,
                  child: TextField(
                    key: const ValueKey('material-fiber'),
                    controller: _fiber,
                    onChanged: (_) => setState(() => _fiberError = null),
                    decoration: InputDecoration(
                        labelText: 'Fiber',
                        errorText: _fiberError,
                        errorMaxLines: 2,
                        border: const OutlineInputBorder(),
                        isDense: true),
                  ),
                ),
                const SizedBox(width: PlySpacing.sm),
                Expanded(
                  flex: 2,
                  child: TextField(
                    key: const ValueKey('material-fiber-percent'),
                    controller: _fiberPercent,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                        labelText: '%', border: OutlineInputBorder(), isDense: true),
                  ),
                ),
                IconButton(
                    tooltip: 'Add this fiber',
                    onPressed: _addFiber,
                    icon: const Icon(Icons.add_circle_outline)),
              ],
            ),
            gap,
            DropdownButtonFormField<YarnWeightCategory?>(
              key: const ValueKey('material-weight'),
              initialValue: _weight,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Weight category',
                helperText: 'The Craft Yarn Council category on the label, 0 Lace to 7 Jumbo.',
                helperMaxLines: 2,
                border: OutlineInputBorder(),
              ),
              items: [
                const DropdownMenuItem<YarnWeightCategory?>(
                    value: null, child: Text('Not recorded')),
                for (final w in YarnWeightCategory.values)
                  DropdownMenuItem<YarnWeightCategory?>(value: w, child: Text(w.label)),
              ],
              onChanged: (w) {
                _weight = w;
                _changed();
              },
            ),
            gap,
            _text(_structure, 'material-structure', 'Structure',
                'Plies, spin and count in your words, such as 3-ply worsted-spun or 8/2 cotton.'),
            gap,
            Text('Length per mass', style: theme.textTheme.titleSmall),
            const SizedBox(height: PlySpacing.xs),
            LengthPerMassEntryField(
              entry: _lpm,
              fieldKey: 'material-lpm',
              onChanged: _changed,
              helper: 'From the ball band, such as 200 m per 100 g (Entered), or weigh a length '
                  'you measured (Measured).',
            ),
            gap,
            CountEntryField(
              entry: _wpi,
              label: 'Wraps',
              noun: 'wraps',
              fieldKey: 'material-wpi',
              onChanged: _changed,
              helper:
                  'Wraps per inch: wrap the yarn side by side, snug but not stretched, around a '
                  'ruler and count the wraps over an inch.',
            ),
            gap,
            _text(_color, 'material-color', 'Color', 'The color name or colorway.'),
            gap,
            _text(_dyeLot, 'material-dye-lot', 'Dye lot',
                'From the label. Skeins from one lot match; another lot may not.'),
            gap,
            Text('On hand', style: theme.textTheme.titleSmall),
            const SizedBox(height: PlySpacing.xs),
            MassEntryField(
              entry: _availableMass,
              label: 'Mass on hand',
              fieldKey: 'material-available-mass',
              onChanged: _changed,
              helper: 'Weigh what you have (Measured), or add up the labels (Entered).',
            ),
            const SizedBox(height: PlySpacing.sm),
            LengthEntryField(
              entry: _availableLength,
              label: 'Length on hand',
              fieldKey: 'material-available-length',
              units: kLongUnits,
              onChanged: _changed,
              helper: 'Leave it blank and Ply works it out from the mass and the length per mass.',
            ),
            gap,
            TextField(
              key: const ValueKey('material-notes'),
              controller: _notes,
              minLines: 2,
              maxLines: 6,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'Notes',
                helperText: 'Where you bought it, what it cost, what you thought of it.',
                border: OutlineInputBorder(),
              ),
            ),
            const Divider(height: PlySpacing.lg),
            RecordReportPanel(
              report: _report,
              emptyText: 'Add a length per mass or wraps per inch, and Ply works out the rest.',
            ),
          ],
        ),
      ),
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
