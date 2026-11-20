import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/library_backup.dart' show BackupCraft;
import '../data/nalbind_repository.dart';
import '../models/nalbind_project.dart';
import '../models/nalbind_recipe.dart';
import '../models/native_format.dart';
import '../print/nalbind_print.dart';
import '../print/print_export.dart' show PdfExportText;
import '../state/nalbind_providers.dart';
import '../widgets/nalbind_diagram_view.dart';
import '../widgets/name_input_dialog.dart' show projectNameProblem;
import '../widgets/notation_feedback.dart';
import '../widgets/project_materials_sheet.dart';
import '../widgets/project_photos.dart';
import '../widgets/unsaved_changes_guard.dart';
import 'nalbind_follow_screen.dart';
import 'nalbind_recipe_screen.dart';

/// The nalbinding PROJECT editor (M6 write path): name the project, pick a stitch (tap a builtin chip
/// or type a Hansen string), and keep free-text working notes — the way the craft is shared, since
/// there is no chart. Saves to the on-device nalbind library. The notation drives a live loop diagram.
///
/// The notation field is AUTHORING, so it is read in strict mode: every problem is listed under
/// the field as an error, and a reading that is not exact draws its diagram labelled approximate.
/// Saving is still allowed with problems (a project is a draft); they stay listed until fixed.
class NalbindProjectScreen extends ConsumerStatefulWidget {
  const NalbindProjectScreen({this.openId, this.openTracker = false, super.key});

  /// When non-null, open this saved project (by id) instead of a fresh one.
  final String? openId;

  /// Open Nalbind step by step as soon as the saved project [openId] is on screen, as its menu entry
  /// does (a library tile's way to continue at the saved place, ADR 0023). Back from it is this
  /// project.
  final bool openTracker;

  @override
  ConsumerState<NalbindProjectScreen> createState() => _NalbindProjectScreenState();
}

class _NalbindProjectScreenState extends ConsumerState<NalbindProjectScreen>
    with UnsavedChangesGuard<NalbindProjectScreen> {
  final _name = TextEditingController();
  final _notation = TextEditingController();
  final _notes = TextEditingController();

  /// Fires on any edit to the three text fields, so the PopScope's canPop tracks typing without
  /// rebuilding the whole form per keystroke.
  late final Listenable _fields = Listenable.merge([_name, _notation, _notes]);

  String _stitchName = ''; // the chosen builtin's display name, '' once the notation is hand-edited

  /// The structured recipe (ADR 0017), or null for a note-only project.
  NalbindRecipe? _recipe;
  String? _id;
  bool _loading = true;
  bool _saving = false;

  /// The name the project was opened or last saved with (trimmed), which saves as it is whatever its
  /// length; null for a new project.
  String? _savedName;

  /// The project as the form held it right after opening (or after the last successful save), in
  /// the same normalized form [_compose] builds. Null until loading finishes.
  NalbindProject? _baseline;

  int _seq = 0;
  NotationReading? _reading;
  String? _readError;

  @override
  void initState() {
    super.initState();
    _id = widget.openId;
    _load();
  }

  Future<void> _load() async {
    if (widget.openId == null) {
      setState(() {
        _loading = false;
        _baseline = _compose(); // a fresh, empty form has nothing unsaved
      });
      return;
    }
    try {
      final repo = ref.read(nalbindRepositoryProvider);
      final project = await repo.readProject(widget.openId!);
      await repo.touchOpened(widget.openId!);
      if (!mounted) return;
      _name.text = project.name;
      _notation.text = project.notation;
      _notes.text = project.notes;
      _stitchName = project.stitchName;
      _recipe = project.recipe;
      _savedName = project.name.trim();
      setState(() {
        _loading = false;
        _baseline = _compose();
      });
      _refreshNotation(project.notation);
      if (widget.openTracker) _trackSteps();
    } catch (e) {
      if (!mounted) return;
      // The form stays empty; anything typed from here on still counts as unsaved. Forget the id so
      // a Save creates a NEW project: saving this empty form under the old id would overwrite the
      // project that failed to open, which may still be recoverable.
      setState(() {
        _id = null;
        _loading = false;
        _baseline = _compose();
      });
      // A format problem (a newer Ply's file, say) has its own plain explanation; anything else
      // keeps the raw error for diagnosis.
      final why = e is NativeFormatException ? e.message : 'Could not open the project: $e.';
      _snack('$why Saving will create a new project and leave the original file untouched.');
    }
  }

  /// The project the form would save right now (the one normalization both [performSave] and the
  /// dirty check use, so a difference the save would erase, like a trailing space on the name, is
  /// never reported as unsaved).
  NalbindProject _compose() => NalbindProject(
        name: _name.text.trim().isEmpty ? 'Untitled' : _name.text.trim(),
        notation: _notation.text.trim(),
        stitchName: _stitchName,
        notes: _notes.text,
        recipe: _recipe,
      );

  /// Why the name typed cannot be saved: longer than the limit weaving and knitting names have
  /// (`DraftMeta.maxNameChars`), unless it is the name the project was opened or last saved with: a
  /// name saved before the limit still loads and saves as it is (a reader is never stricter than an
  /// earlier writer), and must be shortened only to be changed. Nothing is cut short.
  String? _nameProblem() {
    final name = _name.text.trim();
    return name == _savedName ? null : projectNameProblem(name);
  }

  /// Dirty-on-exit guard input (see [UnsavedChangesGuard]): the form differs from what it held when
  /// opened or last saved. Value comparison, so typing a change and then undoing it by hand reads
  /// clean again. Photos are NOT part of this: they are written to disk the moment they are added.
  @override
  bool get hasUnsavedChanges => !_loading && _baseline != null && _compose() != _baseline;

  @override
  String get unsavedChangesNoun => 'project';

  @override
  void dispose() {
    for (final c in [_name, _notation, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// Read the notation in strict (authoring) mode for its findings and diagram, latest-wins (a fast
  /// edit supersedes an older read). The trimmed text is read because that is what a save stores.
  Future<void> _refreshNotation(String notation) async {
    final trimmed = notation.trim();
    final mySeq = ++_seq;
    if (trimmed.isEmpty) {
      setState(() {
        _reading = null;
        _readError = null;
      });
      return;
    }
    try {
      final reading = await ref.read(nalbindRepositoryProvider).read(trimmed, strict: true);
      if (!mounted || mySeq != _seq) return;
      setState(() {
        _reading = reading;
        _readError = null;
      });
    } catch (e) {
      // Reading never fails on any text, so this is the bridge itself failing.
      if (!mounted || mySeq != _seq) return;
      setState(() {
        _reading = null;
        _readError = 'Could not read the notation: $e';
      });
    }
  }

  /// The normal save flow (the Save button and the leave prompt's Save both run it, via
  /// [guardedSave], which also makes a second request join an in-flight one). Resolves true only
  /// when the project was written.
  @override
  Future<bool> performSave() async {
    // A name past the limit is never cut: the field says why, and nothing is written until it is
    // shortened.
    final nameProblem = _nameProblem();
    if (nameProblem != null) {
      _snack(nameProblem);
      return false;
    }
    setState(() => _saving = true);
    // Capture the container BEFORE the await: the screen can be left (Discard) while the write is in
    // flight, and `ref` throws once disposed, but the library list must still refresh.
    final container = ProviderScope.containerOf(context, listen: false);
    // Capture ONCE: this exact value is what gets written AND what becomes the clean baseline, so an
    // edit typed during the write's async gap still reads as unsaved afterwards.
    final project = _compose();
    try {
      final id = await container.read(nalbindRepositoryProvider).saveProject(project, id: _id);
      container.invalidate(nalbindProjectsProvider); // refresh the library list
      if (!mounted) return true;
      // Save in place (don't pop) so the Photos section can appear now that we have an id.
      setState(() {
        _id = id;
        _baseline = project;
        _savedName = project.name;
      });
      // A draft may be saved with notation problems; say so, since the list under the field is the
      // only other sign of them.
      final parsed = _reading?.parsed;
      final withProblems = parsed != null && parsed.source == project.notation && !parsed.accepted;
      _snack(withProblems ? 'Saved. The stitch notation still has problems.' : 'Saved.');
      return true;
    } on NativeFormatException catch (e) {
      // The file on disk is one this build must not replace (a newer Ply's, say). Forget the id so the
      // next Save creates a NEW project and the original stays untouched.
      if (mounted) {
        setState(() => _id = null);
        _snack('${e.message} Save again to keep your changes as a new project.');
      }
      return false;
    } catch (e) {
      if (mounted) _snack('Could not save: $e');
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// A follow-view tick (ADR 0017). It is progress, not an edit. When the step on screen is the same
  /// step the project was saved with, the clean baseline takes the tick too (so it never reads as
  /// unsaved) and ONLY the tick is written to disk at once (other unsaved edits stay unsaved).
  /// Otherwise (a step added or changed since the last save) the tick stays on screen, is saved with
  /// the project, and the maker is told so. Resolves to that message, or null when it was written.
  Future<String?> _tick(String segmentId, bool done) async {
    final current = _recipe?.segments.where((s) => s.id == segmentId).firstOrNull;
    final base = _baseline?.recipe;
    final saved = base?.segments.where((s) => s.id == segmentId).firstOrNull;
    final same = current != null && saved != null && current == saved;
    void tickBaseline(bool value) {
      final b = _baseline?.recipe;
      if (b != null) _baseline = _baseline!.withRecipe(b.withDone(segmentId, value));
    }

    setState(() {
      _recipe = _recipe?.withDone(segmentId, done);
      if (same) tickBaseline(done);
    });
    final id = _id;
    if (id == null) return 'Save the project to keep your ticks.';
    if (current == null) return null;
    if (!same) {
      return saved == null
          ? 'This step is not saved yet: its tick will be saved with the project.'
          : 'This step has changed since the last save: its tick will be saved with the project.';
    }
    try {
      final written = await ref
          .read(nalbindRepositoryProvider)
          .setSegmentDone(id, segmentId, done: done, expected: current);
      if (written) return null;
      // The saved step is not this one after all: keep the tick on screen, unsaved.
      if (mounted) setState(() => tickBaseline(!done));
      return 'This step has changed since the last save: its tick will be saved with the project.';
    } catch (_) {
      // Not on disk: take the tick back here too, so it is never taken for saved.
      if (mounted) {
        setState(() {
          _recipe = _recipe?.withDone(segmentId, !done);
          tickBaseline(!done);
        });
      }
      rethrow;
    }
  }

  Future<void> _openRecipe() async {
    final added = _recipe == null;
    final recipe = _recipe ?? const NalbindRecipe();
    if (added) setState(() => _recipe = recipe);
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => NalbindRecipeScreen(
        initial: recipe,
        projectNotation: _notation.text.trim(),
        projectStitchName: _stitchName,
        onChanged: (r) {
          if (mounted) setState(() => _recipe = r);
        },
        onTick: _tick,
        onSave: guardedSave,
        projectId: () => _id,
        unsavedEdits: () => hasUnsavedChanges,
      ),
    ));
    // "Add a recipe" and straight back with nothing in it: the project stays note-only.
    final now = _recipe;
    if (added &&
        mounted &&
        _baseline?.recipe == null &&
        now != null &&
        now.segments.isEmpty &&
        now.fit.isEmpty) {
      setState(() => _recipe = null);
    }
  }

  Future<void> _followRecipe() async {
    final recipe = _recipe;
    if (recipe == null) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => NalbindFollowScreen(
        recipe: recipe,
        projectNotation: _notation.text.trim(),
        projectStitchName: _stitchName,
        onTick: _tick,
        projectId: _id,
        unsavedEdits: hasUnsavedChanges,
      ),
    ));
  }

  /// Nalbind the recipe step by step, keeping your place (ADR 0023): the follow view of a saved
  /// project. A project without recipe steps has nothing to track, and says so.
  Future<void> _trackSteps() async {
    if ((_recipe?.segments ?? const []).isEmpty) {
      _snack(kNalbindNothingToTrack);
      return;
    }
    if (_id == null) {
      _snack('Save the project first to keep your place.');
      return;
    }
    await _followRecipe();
  }

  /// The Recipe section: optional, so a note-only project shows only how to add one.
  List<Widget> _recipeSection(TextTheme text, ColorScheme cs) {
    final recipe = _recipe;
    final steps = recipe?.segments.length ?? 0;
    final done = recipe?.doneInOrder.length ?? 0;
    return [
      const SizedBox(height: 20),
      Text('Recipe', style: text.titleSmall),
      const SizedBox(height: 8),
      Text(
        recipe == null
            ? 'Optional: write the piece as steps in working order (start, body, shaping, '
                'finish) that Ply checks and you can follow one at a time. Your notes stay as '
                'they are.'
            : steps == 0
                ? 'The recipe has no steps yet.'
                : '$steps ${steps == 1 ? 'step' : 'steps'}, $done done.',
        style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant),
      ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          FilledButton.tonalIcon(
            key: const ValueKey('project-recipe'),
            onPressed: _openRecipe,
            icon: Icon(recipe == null ? Icons.add : Icons.edit_note),
            label: Text(recipe == null ? 'Add a recipe' : 'Edit the recipe'),
          ),
          if (steps > 0)
            OutlinedButton.icon(
              key: const ValueKey('project-follow'),
              onPressed: _followRecipe,
              icon: const Icon(Icons.playlist_play),
              label: const Text(kNalbindTrackerTitle),
            ),
        ],
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final builtins = ref.watch(nalbindBuiltinsProvider);
    final reading = _reading;
    // Dirty-on-exit guard: canPop=false routes the back button / system back through the leave
    // prompt. The ListenableBuilder re-evaluates canPop on every text edit but rebuilds only the
    // PopScope (the form is its cached child); stitch-chip picks and loads rebuild via setState.
    return ListenableBuilder(
      listenable: _fields,
      builder: (context, child) => PopScope<Object?>(
        canPop: !hasUnsavedChanges,
        onPopInvokedWithResult: onLeaveRequested,
        child: child!,
      ),
      child: Scaffold(
      appBar: AppBar(
        title: Text(widget.openId == null ? 'New project' : 'Project'),
        actions: [
          // The project's materials and swatches (ADR 0016); shown only when there are any.
          ProjectMaterialsAction(craft: BackupCraft.nalbinding, id: _id),
          // Prints what the form holds now (saved or not); photos come with a saved project.
          IconButton(
            tooltip: PdfExportText.action,
            icon: const Icon(Icons.print_outlined),
            onPressed: _loading
                ? null
                : () => printOrShareNalbindPdf(context, ref, project: _compose(), id: _id),
          ),
          IconButton(
            tooltip: 'Save',
            icon: const Icon(Icons.save_outlined),
            onPressed: _saving ? null : guardedSave,
          ),
          PopupMenuButton<String>(
            key: const ValueKey('project-more'),
            tooltip: 'More',
            enabled: !_loading,
            onSelected: (_) => _trackSteps(),
            itemBuilder: (_) => const [
              // Work the recipe step by step, keeping your place (ADR 0023).
              PopupMenuItem(
                value: 'track',
                child: ListTile(
                  leading: Icon(Icons.playlist_play),
                  title: Text('$kNalbindTrackerTitle…'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: [
                // Rebuilt as the name is typed, so its limit is said at once.
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _name,
                  builder: (context, _, __) => TextField(
                    controller: _name,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: InputDecoration(
                      labelText: 'Project name',
                      hintText: 'e.g. Winter socks',
                      errorText: _nameProblem(),
                      errorMaxLines: 3,
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Text('Stitch', style: text.titleSmall),
                const SizedBox(height: 8),
                TextField(
                  controller: _notation,
                  autocorrect: false,
                  onChanged: (v) {
                    // Hand-editing the notation makes it a custom string (no builtin name).
                    setState(() => _stitchName = '');
                    _refreshNotation(v);
                  },
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: 'Hansen notation',
                    hintText: 'e.g. UO/UOO F1',
                  ),
                ),
                if (_readError != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(_readError!, style: TextStyle(color: cs.error)),
                  ),
                if (reading != null) ...[
                  NotationFeedback(parsed: reading.parsed, issues: reading.issues),
                  if (!reading.parsed.accepted)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text('You can save with these problems and fix them later.',
                          style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                    ),
                ],
                const SizedBox(height: 8),
                // Tap a builtin to fill the notation + remember its name.
                builtins.maybeWhen(
                  data: (entries) => Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      for (final e in entries)
                        ActionChip(
                          label: Text(e.stitch.name),
                          onPressed: () {
                            final code = e.stitch.codes.isNotEmpty ? e.stitch.codes.first.code : '';
                            _notation.text = code;
                            setState(() => _stitchName = e.stitch.name);
                            _refreshNotation(code);
                          },
                        ),
                    ],
                  ),
                  orElse: () => const SizedBox.shrink(),
                ),
                if (reading != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: NalbindDiagramView(
                      diagram: reading.diagram,
                      approximate: !reading.parsed.isExact,
                    ),
                  ),
                const SizedBox(height: 20),
                Text('Notes', style: text.titleSmall),
                const SizedBox(height: 8),
                TextField(
                  controller: _notes,
                  maxLines: null,
                  minLines: 6,
                  keyboardType: TextInputType.multiline,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    hintText: 'Cast-on, increases, gauge, fit, yarn — how this piece is worked.',
                    alignLabelWithHint: true,
                  ),
                ),
                ..._recipeSection(text, cs),
                const SizedBox(height: 20),
                Text('Photos', style: text.titleSmall),
                const SizedBox(height: 8),
                if (_id != null)
                  ProjectPhotos(subdir: 'nalbinds', id: _id!)
                else
                  Text('Save the project to attach photos.',
                      style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
              ],
            ),
      ),
    );
  }
}
