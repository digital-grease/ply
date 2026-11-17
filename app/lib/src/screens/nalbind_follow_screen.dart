import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/nalbind_recipe.dart';
import '../models/nalbind_recipe_view.dart';
import '../rust/nalbind_recipe_dto.dart';
import '../state/nalbind_providers.dart';
import '../widgets/nalbind_recipe_issues.dart';

/// FOLLOW a nalbinding recipe (ADR 0017): one step at a time in working order, with its written
/// instruction, stitch, count, target, notes and caution, whether Ply checked it and anything it
/// found, and a Done tick. Opens at the first step not yet done.
///
/// Ticks go through [onTick] (the project screen writes them to the saved project at once); the
/// message it resolves to, if any, is shown. Full progress tracking (a position inside a step, a
/// log, notes per session) is later work (roadmap M8-05).
class NalbindFollowScreen extends ConsumerStatefulWidget {
  const NalbindFollowScreen({
    required this.recipe,
    required this.projectNotation,
    required this.projectStitchName,
    required this.onTick,
    super.key,
  });

  final NalbindRecipe recipe;
  final String projectNotation;
  final String projectStitchName;
  final Future<String?> Function(String segmentId, bool done) onTick;

  @override
  ConsumerState<NalbindFollowScreen> createState() => _NalbindFollowScreenState();
}

class _NalbindFollowScreenState extends ConsumerState<NalbindFollowScreen> {
  late NalbindRecipe _recipe = widget.recipe;
  late int _index = _firstOpen(widget.recipe);
  RecipeReportDto? _report;
  String? _error;
  bool _ticking = false;

  static int _firstOpen(NalbindRecipe r) {
    final i = r.segments.indexWhere((s) => !r.done.contains(s.id));
    return i < 0 ? 0 : i;
  }

  @override
  void initState() {
    super.initState();
    _load();
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

  Future<void> _tick(String id, bool done) async {
    if (_ticking) return;
    final before = _recipe;
    setState(() {
      _ticking = true;
      _recipe = _recipe.withDone(id, done);
    });
    try {
      final message = await widget.onTick(id, done);
      if (message != null && mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(message)));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _recipe = before);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('Could not save the tick: $e')));
    } finally {
      if (mounted) setState(() => _ticking = false);
    }
  }

  void _go(int i) => setState(() => _index = i.clamp(0, _recipe.segments.length - 1));

  @override
  Widget build(BuildContext context) {
    final segments = _recipe.segments;
    final text = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    if (segments.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Follow')),
        body: const Center(child: Text('The recipe has no steps yet.')),
      );
    }
    final i = _index.clamp(0, segments.length - 1);
    final seg = segments[i];
    final r = _report;
    final s = r?.at(i);
    final doneCount = segments.where((x) => _recipe.done.contains(x.id)).length;
    final stitch =
        s == null ? null : recipeStitchText(r!, s, projectStitchName: widget.projectStitchName);
    final count = s == null ? null : recipeCountText(s);
    final isDone = _recipe.done.contains(seg.id);

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

    return Scaffold(
      appBar: AppBar(
        title: const Text('Follow'),
        actions: [
          PopupMenuButton<int>(
            key: const ValueKey('follow-go-to'),
            tooltip: 'Go to a step',
            icon: const Icon(Icons.list),
            onSelected: _go,
            itemBuilder: (_) => [
              for (final (j, x) in segments.indexed)
                PopupMenuItem(
                  value: j,
                  child: Text(
                      '${_recipe.done.contains(x.id) ? 'Done: ' : ''}Step ${j + 1}: ${x.title.trim().isEmpty ? x.kind.label : x.title.trim()}'),
                ),
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
                onPressed: i > 0 ? () => _go(i - 1) : null,
                icon: const Icon(Icons.chevron_left),
                label: const Text('Previous'),
              ),
              const Spacer(),
              FilledButton.icon(
                key: const ValueKey('follow-next'),
                onPressed: i < segments.length - 1 ? () => _go(i + 1) : null,
                icon: const Icon(Icons.chevron_right),
                label: const Text('Next'),
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
