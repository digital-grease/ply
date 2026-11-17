import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/nalbind_recipe.dart';
import '../models/nalbind_recipe_view.dart';
import '../rust/nalbind_recipe_dto.dart';
import '../state/nalbind_providers.dart';
import '../widgets/nalbind_recipe_issues.dart';
import '../widgets/nalbind_segment_editor.dart';
import 'nalbind_follow_screen.dart';

/// The name of the project's stitch as the recipe screens show it (`Oslo, UO/UOO F1`), or empty.
String projectStitchLabel(String name, String notation) {
  final n = notation.trim();
  if (n.isEmpty) return '';
  return name.trim().isEmpty ? n : '${name.trim()}, $n';
}

/// The RECIPE editor of a nalbinding project (ADR 0017): the fit it aims for and its steps in
/// working order, each with the engine's written instruction, its stitch and count, whether Ply
/// checked it and every problem found. Steps can be added (a sheet of kinds, then a small form),
/// edited, reordered (drag, or move up and down), duplicated and deleted (with Undo).
///
/// The recipe lives in the project screen beneath: every edit goes straight back through
/// [onChanged], so leaving this screen never loses one, and the project's Save (here too, through
/// [onSave]) writes it. [onTick] is the project's follow-view tick.
class NalbindRecipeScreen extends ConsumerStatefulWidget {
  const NalbindRecipeScreen({
    required this.initial,
    required this.projectNotation,
    required this.projectStitchName,
    required this.onChanged,
    required this.onTick,
    this.onSave,
    super.key,
  });

  final NalbindRecipe initial;
  final String projectNotation;
  final String projectStitchName;

  /// Every edit, as the whole new recipe; null when the maker removes the recipe.
  final ValueChanged<NalbindRecipe?> onChanged;

  /// Tick a step done (or not); resolves to a message to show, or null.
  final Future<String?> Function(String segmentId, bool done) onTick;

  /// The project's save; resolves true when written.
  final Future<bool> Function()? onSave;

  @override
  ConsumerState<NalbindRecipeScreen> createState() => _NalbindRecipeScreenState();
}

class _NalbindRecipeScreenState extends ConsumerState<NalbindRecipeScreen> {
  late NalbindRecipe _recipe = widget.initial;
  RecipeReportDto? _report;

  /// The recipe [_report] was computed for (a report for an older recipe is not shown).
  NalbindRecipe? _reported;
  String? _checkError;
  int _seq = 0;

  String get _stitchLabel => projectStitchLabel(widget.projectStitchName, widget.projectNotation);

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final recipe = _recipe;
    final mine = ++_seq;
    try {
      final report = await ref
          .read(nalbindRepositoryProvider)
          .checkRecipe(recipe, projectNotation: widget.projectNotation);
      if (!mounted || mine != _seq) return;
      setState(() {
        _report = report;
        _reported = recipe;
        _checkError = null;
      });
    } catch (e) {
      if (!mounted || mine != _seq) return;
      setState(() => _checkError = 'Could not check the recipe: $e');
    }
  }

  /// Apply an edit. Any edit ends a pending Undo (its snack bar goes), so an Undo can never act on
  /// a recipe that has moved on.
  void _update(NalbindRecipe recipe) {
    ScaffoldMessenger.maybeOf(context)?.hideCurrentSnackBar();
    setState(() => _recipe = recipe);
    widget.onChanged(recipe);
    _check();
  }

  void _snack(String message, {SnackBarAction? action}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message), action: action));
  }

  /// The openings before position [before] a pick-up or join there can name.
  List<RecipeOpeningChoice> _openings(int before) => [
        for (final (i, s) in _recipe.segments.indexed)
          if (i < before && s.kind == SegmentKind.opening)
            RecipeOpeningChoice(
                s.id, 'Step ${i + 1}: ${s.title.trim().isEmpty ? 'Opening' : s.title.trim()}'),
      ];

  Future<void> _add() async {
    final kind = await showSegmentKindChooser(context);
    if (kind == null || !mounted) return;
    final segment = await showSegmentEditor(
      context,
      kind: kind,
      id: _recipe.nextId(),
      openings: _openings(_recipe.segments.length),
      projectStitch: _stitchLabel,
    );
    if (segment == null || !mounted) return;
    // The id is given for good only now: a cancelled form gives none away.
    final (next, id) = _recipe.issueId();
    _update(next.copyWith(segments: [...next.segments, segment.withId(id)]));
  }

  Future<void> _edit(int i) async {
    final s = _recipe.segments[i];
    final edited = await showSegmentEditor(
      context,
      kind: s.kind,
      id: s.id,
      initial: s,
      openings: _openings(i),
      projectStitch: _stitchLabel,
    );
    if (edited == null || edited == s) return;
    final segments = [..._recipe.segments]..[i] = edited;
    _update(_recipe.copyWith(segments: segments));
  }

  void _move(int from, int to) {
    if (to < 0 || to >= _recipe.segments.length || to == from) return;
    final segments = [..._recipe.segments];
    final s = segments.removeAt(from);
    segments.insert(to, s);
    _update(_recipe.copyWith(segments: segments));
  }

  void _duplicate(int i) {
    final (next, id) = _recipe.issueId();
    final copy = next.segments[i].withId(id);
    _update(next.copyWith(segments: [...next.segments]..insert(i + 1, copy)));
  }

  void _delete(int i) {
    final s = _recipe.segments[i];
    final wasDone = _recipe.done.contains(s.id);
    _update(_recipe.copyWith(
      segments: [..._recipe.segments]..removeAt(i),
      done: {..._recipe.done}..remove(s.id),
    ));
    _snack('Step ${i + 1} deleted.',
        action: SnackBarAction(label: 'Undo', onPressed: () => _restore(s, i, wasDone)));
  }

  /// Undo a delete: put [s] back at [at] in the recipe as it is NOW (anything since, such as a tick
  /// in the follow view, stays), with its tick if it had one. Its id was never given again.
  void _restore(RecipeSegment s, int at, bool wasDone) {
    if (!mounted || _recipe.segments.any((x) => x.id == s.id)) return;
    final segments = [..._recipe.segments]..insert(at.clamp(0, _recipe.segments.length), s);
    final restored = _recipe.copyWith(segments: segments);
    _update(wasDone ? restored.withDone(s.id, true) : restored);
  }

  Future<void> _editFit(int? i) async {
    final m = await showDialog<Measurement>(
      context: context,
      builder: (_) => _FitDialog(initial: i == null ? null : _recipe.fit[i]),
    );
    if (m == null) return;
    final fit = [..._recipe.fit];
    if (i == null) {
      fit.add(m);
    } else {
      fit[i] = m;
    }
    _update(_recipe.copyWith(fit: fit));
  }

  void _deleteFit(int i) => _update(_recipe.copyWith(fit: [..._recipe.fit]..removeAt(i)));

  Future<void> _removeRecipe() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove the recipe?'),
        content: const Text('Every step and tick of the recipe is removed when you save the '
            'project. The notes, stitch and photos stay.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Remove')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    widget.onChanged(null);
    Navigator.of(context).pop();
  }

  Future<void> _follow() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => NalbindFollowScreen(
        recipe: _recipe,
        projectNotation: widget.projectNotation,
        projectStitchName: widget.projectStitchName,
        onTick: (id, done) async {
          final message = await widget.onTick(id, done);
          if (mounted) setState(() => _recipe = _recipe.withDone(id, done));
          return message;
        },
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    // Ticks are progress, not instructions: a report stays current across them.
    final reported = _reported;
    final report = reported != null &&
            (identical(reported, _recipe) ||
                reported.copyWith(done: const {}) == _recipe.copyWith(done: const {}))
        ? _report
        : null;
    final segments = _recipe.segments;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Recipe'),
        actions: [
          IconButton(
            key: const ValueKey('recipe-follow'),
            tooltip: 'Follow the recipe',
            icon: const Icon(Icons.playlist_play),
            onPressed: segments.isEmpty ? null : _follow,
          ),
          if (widget.onSave != null)
            IconButton(
              key: const ValueKey('recipe-save'),
              tooltip: 'Save the project',
              icon: const Icon(Icons.save_outlined),
              onPressed: () => widget.onSave!(),
            ),
          PopupMenuButton<String>(
            tooltip: 'More',
            onSelected: (v) {
              if (v == 'remove') _removeRecipe();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'remove', child: Text('Remove the recipe')),
            ],
          ),
        ],
      ),
      body: ReorderableListView.builder(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        buildDefaultDragHandles: false,
        itemCount: segments.length,
        onReorderItem: _move,
        header: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              child: Text(kRecipeCheckedText,
                  style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
            ),
            if (_checkError != null)
              Padding(
                padding: const EdgeInsets.all(4),
                child: Text(_checkError!, style: TextStyle(color: cs.error)),
              ),
            _FitCard(
              fit: _recipe.fit,
              report: report,
              onAdd: () => _editFit(null),
              onEdit: _editFit,
              onDelete: _deleteFit,
            ),
            if (report != null && report.recipeWide.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                child: RecipeIssueList(issues: report.recipeWide, withPlace: true),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
              child: Semantics(header: true, child: Text('Steps', style: text.titleMedium)),
            ),
            if (segments.isEmpty)
              Padding(
                padding: const EdgeInsets.all(4),
                child: Text(
                  'No steps yet. Begin with a start: a foundation chain, a centre start, or loops '
                  'picked up from earlier work. Then add the body, the shaping and the finish.',
                  style: text.bodyMedium,
                ),
              ),
          ],
        ),
        footer: Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              key: const ValueKey('recipe-add-step'),
              onPressed: segments.length >= kMaxRecipeSegments ? null : _add,
              icon: const Icon(Icons.add),
              label: const Text('Add a step'),
            ),
          ),
        ),
        itemBuilder: (context, i) => _SegmentCard(
          key: ValueKey('recipe-step-$i-${segments[i].id}'),
          index: i,
          segment: segments[i],
          total: segments.length,
          report: report,
          done: _recipe.done.contains(segments[i].id),
          projectStitchName: widget.projectStitchName,
          onEdit: () => _edit(i),
          onMoveUp: i > 0 ? () => _move(i, i - 1) : null,
          onMoveDown: i < segments.length - 1 ? () => _move(i, i + 1) : null,
          onDuplicate: segments.length >= kMaxRecipeSegments ? null : () => _duplicate(i),
          onDelete: () => _delete(i),
        ),
      ),
    );
  }
}

class _FitCard extends StatelessWidget {
  const _FitCard({
    required this.fit,
    required this.report,
    required this.onAdd,
    required this.onEdit,
    required this.onDelete,
  });

  final List<Measurement> fit;
  final RecipeReportDto? report;
  final VoidCallback onAdd;
  final ValueChanged<int> onEdit;
  final ValueChanged<int> onDelete;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final r = report;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(header: true, child: Text('Fit', style: text.titleSmall)),
            if (fit.isEmpty)
              const Text(
                  'No measurements yet: for example the hand around the knuckles, or the head '
                  'around the forehead.'),
            for (final (i, m) in fit.indexed)
              ListTile(
                key: ValueKey('recipe-fit-$i'),
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text(r != null && i < r.fit.length ? r.fit[i] : m.label),
                subtitle: r == null || r.fitIssuesAt(i).isEmpty
                    ? null
                    : RecipeIssueList(issues: r.fitIssuesAt(i)),
                onTap: () => onEdit(i),
                trailing: IconButton(
                  tooltip: 'Remove this measurement',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => onDelete(i),
                ),
              ),
            TextButton.icon(
              key: const ValueKey('recipe-add-fit'),
              onPressed: fit.length >= kMaxRecipeFit ? null : onAdd,
              icon: const Icon(Icons.straighten),
              label: const Text('Add a measurement'),
            ),
          ],
        ),
      ),
    );
  }
}

class _SegmentCard extends StatelessWidget {
  const _SegmentCard({
    required this.index,
    required this.segment,
    required this.total,
    required this.report,
    required this.done,
    required this.projectStitchName,
    required this.onEdit,
    required this.onMoveUp,
    required this.onMoveDown,
    required this.onDuplicate,
    required this.onDelete,
    super.key,
  });

  final int index;
  final RecipeSegment segment;
  final int total;
  final RecipeReportDto? report;
  final bool done;
  final String projectStitchName;
  final VoidCallback onEdit;
  final VoidCallback? onMoveUp;
  final VoidCallback? onMoveDown;
  final VoidCallback? onDuplicate;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final r = report;
    final s = r?.at(index);
    final stitch = s == null || r == null
        ? null
        : recipeStitchText(r, s, projectStitchName: projectStitchName);
    final count = s == null ? null : recipeCountText(s);
    final issues = r?.issuesAt(index) ?? const <RecipeIssueDto>[];
    return Card(
      child: InkWell(
        onTap: onEdit,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 0, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ReorderableDragStartListener(
                index: index,
                child: const Padding(
                  padding: EdgeInsets.all(8),
                  child: Icon(Icons.drag_handle, semanticLabel: 'Drag to reorder'),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(recipeStepLabel(segment, index, total), style: text.titleSmall),
                    if (done) Text('Done', style: text.labelMedium?.copyWith(color: cs.primary)),
                    const SizedBox(height: 4),
                    Text(recipeWrittenText(r, segment, index) ?? 'Checking…'),
                    if (stitch != null) Text('Stitch: $stitch', style: text.bodySmall),
                    if (count != null) Text('Stitches: $count', style: text.bodySmall),
                    if (s?.target != null) Text('Aim for: ${s!.target}', style: text.bodySmall),
                    if (r != null)
                      Text(recipeStatusText(r, index),
                          style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                    if (issues.isNotEmpty) RecipeIssueList(issues: issues),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                key: ValueKey('recipe-step-menu-$index'),
                tooltip: 'Step ${index + 1} actions',
                onSelected: (v) => switch (v) {
                  'edit' => onEdit(),
                  'up' => onMoveUp?.call(),
                  'down' => onMoveDown?.call(),
                  'duplicate' => onDuplicate?.call(),
                  'delete' => onDelete(),
                  _ => null,
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'edit', child: Text('Edit')),
                  PopupMenuItem(
                      value: 'up', enabled: onMoveUp != null, child: const Text('Move up')),
                  PopupMenuItem(
                      value: 'down', enabled: onMoveDown != null, child: const Text('Move down')),
                  PopupMenuItem(
                      value: 'duplicate',
                      enabled: onDuplicate != null,
                      child: const Text('Duplicate')),
                  const PopupMenuItem(value: 'delete', child: Text('Delete')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The form for one fit measurement.
class _FitDialog extends StatefulWidget {
  const _FitDialog({this.initial});
  final Measurement? initial;

  @override
  State<_FitDialog> createState() => _FitDialogState();
}

class _FitDialogState extends State<_FitDialog> {
  final _form = GlobalKey<FormState>();
  late final _label = TextEditingController(text: widget.initial?.label ?? '');
  late final _value = TextEditingController(
      text: widget.initial?.value == null ? '' : formatRecipeNumber(widget.initial!.value!));
  late LengthUnit? _unit = widget.initial?.unit;

  static double? _decimal(String text) {
    final t = text.trim().replaceAll(',', '.');
    if (t.isEmpty) return null;
    final v = double.tryParse(t);
    return v != null && v.isFinite ? v : null;
  }

  @override
  void dispose() {
    _label.dispose();
    _value.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.initial == null ? 'Add a measurement' : 'Edit the measurement'),
        content: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                key: const ValueKey('fit-label'),
                controller: _label,
                decoration: const InputDecoration(
                  labelText: 'What',
                  hintText: 'e.g. Hand around the knuckles',
                ),
                validator: recipeTextTooLong,
              ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 3,
                    child: TextFormField(
                      key: const ValueKey('fit-value'),
                      controller: _value,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: 'Length'),
                      validator: (v) => (v ?? '').trim().isNotEmpty && _decimal(v!) == null
                          ? 'Enter a number'
                          : null,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: DropdownButtonFormField<LengthUnit?>(
                      key: const ValueKey('fit-unit'),
                      initialValue: _unit,
                      decoration: const InputDecoration(labelText: 'Unit'),
                      items: [
                        const DropdownMenuItem<LengthUnit?>(value: null, child: Text('None')),
                        for (final u in LengthUnit.values)
                          DropdownMenuItem<LengthUnit?>(value: u, child: Text(u.json)),
                      ],
                      onChanged: (u) => setState(() => _unit = u),
                      validator: (u) =>
                          u == null && _decimal(_value.text) != null ? 'Choose a unit' : null,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(
            key: const ValueKey('fit-done'),
            onPressed: () {
              if (!(_form.currentState?.validate() ?? false)) return;
              Navigator.pop(
                context,
                Measurement(
                  label: _label.text.trim(),
                  value: _decimal(_value.text),
                  unit: _unit,
                  // Keys a newer Ply wrote here stay as they were.
                  extra: widget.initial?.extra ?? const {},
                ),
              );
            },
            child: const Text('Done'),
          ),
        ],
      );
}
