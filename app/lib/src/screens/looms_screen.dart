// My looms (roadmap M8-02, ADR 0014): the weaver's equipment, listed, added, edited, duplicated and
// deleted. Every field is optional and says what it is for; a value the weaver leaves blank stays
// unknown (never zero), and the weaving editor's loom check then says it could not check it.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/loom_repository.dart';
import '../models/draft_doc.dart' show MeasureUnit;
import '../models/loom_profile.dart';
import '../models/loom_type.dart';
import '../state/loom_providers.dart';
import '../theme/spacing.dart';
import '../widgets/unsaved_changes_guard.dart';

/// The list of the weaver's looms.
class LoomsScreen extends ConsumerWidget {
  const LoomsScreen({super.key});

  static const String title = 'My looms';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final library = ref.watch(loomLibraryProvider);
    final ready = library.valueOrNull;
    final canEdit = ready != null && !ready.readOnly;
    return Scaffold(
      appBar: AppBar(title: const Text(title)),
      floatingActionButton: canEdit
          ? FloatingActionButton.extended(
              onPressed: () => _edit(context, null),
              icon: const Icon(Icons.add),
              label: const Text('Add loom'),
            )
          : null,
      body: library.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => const _Note('Your looms could not be opened.'),
        data: (lib) => _LoomList(library: lib),
      ),
    );
  }

  static Future<void> _edit(BuildContext context, LoomProfile? loom) => Navigator.of(context)
      .push(MaterialPageRoute<void>(builder: (_) => LoomEditScreen(loom: loom)));
}

class _LoomList extends ConsumerWidget {
  const _LoomList({required this.library});

  final LoomLibraryState library;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notice = switch (library.status) {
      LoomFileStatus.ok => null,
      LoomFileStatus.newer =>
        'Your looms were saved by a newer version of Ply. Update the app to see and change them.',
      LoomFileStatus.unreachable =>
        'Your looms could not be reached on this device, so they cannot be changed right now.',
      LoomFileStatus.tooLarge => 'Your looms file is too large to open (over 1 MB). It was left '
          'as it is, and My looms cannot be changed.',
      LoomFileStatus.setAside => 'Your saved looms could not be read. The file was kept as '
          '${LoomRepository.fileName}${LoomRepository.corruptSuffix}, and My looms starts empty.',
    };
    return ListView(
      padding: const EdgeInsets.only(bottom: 88),
      children: [
        if (notice != null) _Note(notice),
        if (library.looms.isEmpty && !library.readOnly)
          const _Note('No looms yet. Add the looms you weave on, and the weaving editor can check '
              'a draft against one: its shafts, treadles, width and reeds.'),
        for (final loom in library.looms)
          ListTile(
            title: Text(loom.displayName),
            subtitle: Text(loom.summary),
            onTap: library.readOnly ? null : () => LoomsScreen._edit(context, loom),
            trailing: library.readOnly
                ? null
                : PopupMenuButton<String>(
                    tooltip: 'Loom actions',
                    onSelected: (action) => switch (action) {
                      'edit' => LoomsScreen._edit(context, loom),
                      'duplicate' => _duplicate(context, ref, loom),
                      _ => _delete(context, ref, loom),
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'edit', child: Text('Edit')),
                      PopupMenuItem(value: 'duplicate', child: Text('Duplicate')),
                      PopupMenuItem(value: 'delete', child: Text('Delete')),
                    ],
                  ),
          ),
      ],
    );
  }

  Future<void> _duplicate(BuildContext context, WidgetRef ref, LoomProfile loom) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(loomLibraryProvider.notifier).duplicate(loom.id);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(_failure(e))));
    }
  }

  Future<void> _delete(BuildContext context, WidgetRef ref, LoomProfile loom) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete "${loom.displayName}"?'),
        content: const Text(
            'Drafts planned for this loom keep its name, but can no longer be checked against it.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(loomLibraryProvider.notifier).delete(loom.id);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(_failure(e))));
    }
  }
}

String _failure(Object e) => e is LoomFileException ? e.message : 'Could not save your looms.';

class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(PlySpacing.md),
      child: Text(text,
          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
    );
  }
}

/// Add or edit one loom. Every field is optional.
class LoomEditScreen extends ConsumerStatefulWidget {
  const LoomEditScreen({this.loom, super.key});

  /// The loom to edit, or null to add one.
  final LoomProfile? loom;

  @override
  ConsumerState<LoomEditScreen> createState() => _LoomEditScreenState();
}

class _LoomEditScreenState extends ConsumerState<LoomEditScreen> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _name = TextEditingController(text: widget.loom?.name ?? '');
  late final TextEditingController _shafts = _count(widget.loom?.shafts);
  late final TextEditingController _treadles = _count(widget.loom?.treadles);
  late final TextEditingController _atOnce = _count(widget.loom?.treadlesAtOnce);
  late final TextEditingController _width = TextEditingController(
      text: widget.loom?.weavingWidth == null
          ? ''
          : exactLoomNumber(widget.loom!.weavingWidth!.value));
  late final TextEditingController _notes = TextEditingController(text: widget.loom?.notes ?? '');
  final TextEditingController _reedDents = TextEditingController();
  late LoomType? _type = widget.loom?.type;
  late MeasureUnit _widthUnit = widget.loom?.weavingWidth?.unit ?? MeasureUnit.inches;
  late List<Reed> _reeds = [...?widget.loom?.reeds];
  DentUnit _reedPer = DentUnit.perInch;
  String? _reedError;
  bool _saving = false;
  bool _leaving = false;

  static TextEditingController _count(int? v) => TextEditingController(text: v?.toString() ?? '');

  @override
  void dispose() {
    for (final c in [_name, _shafts, _treadles, _atOnce, _width, _notes, _reedDents]) {
      c.dispose();
    }
    super.dispose();
  }

  /// The loom the form describes now (the id of the loom being edited, or a new one).
  LoomProfile _built(String id) => LoomProfile(
        id: id,
        name: _name.text.trim(),
        type: _type,
        shafts: int.tryParse(_shafts.text.trim()),
        treadles: int.tryParse(_treadles.text.trim()),
        weavingWidth: double.tryParse(_width.text.trim()) == null
            ? null
            : LoomLength(double.parse(_width.text.trim()), _widthUnit),
        reeds: List.unmodifiable(_reeds),
        treadlesAtOnce: int.tryParse(_atOnce.text.trim()),
        notes: _notes.text,
      );

  bool get _dirty {
    final original = widget.loom ?? const LoomProfile(id: '');
    return _built(original.id) != original || _reedDents.text.trim().isNotEmpty;
  }

  static String? _countError(String? text, int max) {
    final t = (text ?? '').trim();
    if (t.isEmpty) return null;
    final v = int.tryParse(t);
    return v == null || v < 1 || v > max
        ? 'Enter a whole number from 1 to $max, or leave it blank.'
        : null;
  }

  /// The engine counts text in Unicode code points (`char`s), not in what the screen shows as one
  /// character (an emoji family is several code points), so the form counts the same way.
  static String? _lengthError(String? text, int max) => (text ?? '').runes.length > max
      ? 'This is too long: use at most $max letters, digits or symbols (an emoji can count as '
          'several).'
      : null;

  static String? _widthError(String? text) {
    final t = (text ?? '').trim();
    if (t.isEmpty) return null;
    final v = double.tryParse(t);
    return v == null || !v.isFinite || v <= 0 || v > LoomLimits.maxWidth
        ? 'Enter a width above 0, or leave it blank.'
        : null;
  }

  void _addReed() {
    final v = double.tryParse(_reedDents.text.trim());
    if (v == null || !v.isFinite || v <= 0 || v > LoomLimits.maxReedDents) {
      setState(() => _reedError = 'Enter the number of dents, above 0.');
      return;
    }
    if (_reeds.length >= LoomLimits.maxReeds) {
      setState(() => _reedError = 'A loom can list up to ${LoomLimits.maxReeds} reeds.');
      return;
    }
    setState(() {
      _reeds = [..._reeds, Reed(v, _reedPer)];
      _reedDents.clear();
      _reedError = null;
    });
  }

  Future<bool> _save() async {
    if (_saving) return false;
    if (!(_form.currentState?.validate() ?? false)) return false;
    if (_reedDents.text.trim().isNotEmpty) {
      _addReed(); // a reed typed but not added yet is kept, not lost
      if (_reedError != null) return false;
    }
    setState(() => _saving = true);
    final notifier = ref.read(loomLibraryProvider.notifier);
    final loom = _built(widget.loom?.id ?? notifier.newId());
    try {
      await notifier.upsert(loom);
      if (mounted) Navigator.of(context).pop();
      return true;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_failure(e))));
      }
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
          await showLeaveWithoutSavingDialog(context, noun: 'loom') ?? LeaveAction.keepEditing;
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
          title: Text(widget.loom == null ? 'Add loom' : 'Edit loom'),
          actions: [
            TextButton(onPressed: _saving ? null : _save, child: const Text('Save')),
          ],
        ),
        body: Form(
          key: _form,
          onChanged: () => setState(() {}),
          child: ListView(
            padding: const EdgeInsets.all(PlySpacing.md),
            children: [
              Text(
                  'Every field is optional. Leave out what you do not know: Ply says what it '
                  'could not check instead of guessing.',
                  style: help),
              gap,
              TextFormField(
                key: const ValueKey('loom-name'),
                controller: _name,
                validator: (t) => _lengthError(t, LoomLimits.maxNameChars),
                decoration: const InputDecoration(
                  labelText: 'Name',
                  hintText: 'Floor loom',
                  helperText: 'What you call this loom.',
                  border: OutlineInputBorder(),
                ),
              ),
              gap,
              DropdownButtonFormField<LoomType?>(
                key: const ValueKey('loom-type'),
                initialValue: _type,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Loom type',
                  border: OutlineInputBorder(),
                ),
                items: [
                  const DropdownMenuItem<LoomType?>(value: null, child: Text('Not recorded')),
                  for (final t in LoomType.values)
                    DropdownMenuItem<LoomType?>(value: t, child: Text(t.label)),
                ],
                onChanged: (t) => setState(() => _type = t),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
                child: Text(
                    _type?.description ??
                        'How the loom moves the shafts. Ply reads the tie-up the way your loom '
                            'works.',
                    style: help),
              ),
              gap,
              _numberField(
                key: 'loom-shafts',
                controller: _shafts,
                label: 'Shafts',
                helper: 'How many shafts the loom has.',
                validator: (t) => _countError(t, LoomLimits.maxShafts),
              ),
              gap,
              _numberField(
                key: 'loom-treadles',
                controller: _treadles,
                label: 'Treadles',
                helper: 'How many treadles. Leave it blank for a table loom (a lever for each '
                    'shaft) or a dobby.',
                validator: (t) => _countError(t, LoomLimits.maxTreadles),
              ),
              gap,
              _numberField(
                key: 'loom-at-once',
                controller: _atOnce,
                label: 'Treadles pressed at once',
                helper: 'The most treadles you press together for one pick, such as 2 with a '
                    'skeleton tie-up.',
                validator: (t) => _countError(t, LoomLimits.maxTreadlesAtOnce),
              ),
              gap,
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextFormField(
                      key: const ValueKey('loom-width'),
                      controller: _width,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      validator: _widthError,
                      decoration: const InputDecoration(
                        labelText: 'Weaving width',
                        helperText: 'The widest warp the loom takes in the reed.',
                        helperMaxLines: 2,
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: PlySpacing.sm),
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: SegmentedButton<MeasureUnit>(
                      segments: const [
                        ButtonSegment(value: MeasureUnit.inches, label: Text('in')),
                        ButtonSegment(value: MeasureUnit.centimeters, label: Text('cm')),
                      ],
                      selected: {_widthUnit},
                      showSelectedIcon: false,
                      onSelectionChanged: (s) => setState(() => _widthUnit = s.first),
                    ),
                  ),
                ],
              ),
              gap,
              Text('Reeds', style: theme.textTheme.titleSmall),
              const SizedBox(height: PlySpacing.xs),
              Text(
                  'The reeds you have, by dents per inch, or per 10 cm for a metric reed (a 40/10 '
                  'reed has 40 dents in 10 cm). Ply picks one for the draft\'s sett.',
                  style: help),
              const SizedBox(height: PlySpacing.xs),
              if (_reeds.isNotEmpty)
                Wrap(
                  spacing: PlySpacing.xs,
                  runSpacing: PlySpacing.xs,
                  children: [
                    for (var i = 0; i < _reeds.length; i++)
                      InputChip(
                        label: Text(_reeds[i].label),
                        onDeleted: () => setState(() => _reeds = [..._reeds]..removeAt(i)),
                        deleteButtonTooltipMessage: 'Remove this reed',
                      ),
                  ],
                ),
              const SizedBox(height: PlySpacing.xs),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextField(
                      key: const ValueKey('loom-reed-dents'),
                      controller: _reedDents,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: InputDecoration(
                        labelText: 'Dents',
                        errorText: _reedError,
                        border: const OutlineInputBorder(),
                      ),
                      onChanged: (_) => setState(() => _reedError = null),
                      onSubmitted: (_) => _addReed(),
                    ),
                  ),
                  const SizedBox(width: PlySpacing.sm),
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: SegmentedButton<DentUnit>(
                      segments: const [
                        ButtonSegment(value: DentUnit.perInch, label: Text('per inch')),
                        ButtonSegment(value: DentUnit.per10cm, label: Text('per 10 cm')),
                      ],
                      selected: {_reedPer},
                      showSelectedIcon: false,
                      onSelectionChanged: (s) => setState(() => _reedPer = s.first),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Add this reed',
                    onPressed: _addReed,
                    icon: const Icon(Icons.add_circle_outline),
                  ),
                ],
              ),
              gap,
              TextFormField(
                key: const ValueKey('loom-notes'),
                controller: _notes,
                maxLines: 4,
                minLines: 2,
                validator: (t) => _lengthError(t, LoomLimits.maxNotesChars),
                decoration: const InputDecoration(
                  labelText: 'Setup notes',
                  helperText: 'Anything else about how this loom is set up.',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _numberField({
    required String key,
    required TextEditingController controller,
    required String label,
    required String helper,
    required FormFieldValidator<String> validator,
  }) =>
      TextFormField(
        key: ValueKey(key),
        controller: controller,
        keyboardType: TextInputType.number,
        validator: validator,
        decoration: InputDecoration(
          labelText: label,
          helperText: helper,
          helperMaxLines: 2,
          border: const OutlineInputBorder(),
        ),
      );
}
