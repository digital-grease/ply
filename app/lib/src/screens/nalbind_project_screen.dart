import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/nalbind_repository.dart';
import '../models/nalbind_project.dart';
import '../models/native_format.dart';
import '../print/nalbind_print.dart';
import '../print/print_export.dart' show PdfExportText;
import '../state/nalbind_providers.dart';
import '../widgets/nalbind_diagram_view.dart';
import '../widgets/notation_feedback.dart';
import '../widgets/project_photos.dart';
import '../widgets/unsaved_changes_guard.dart';

/// The nalbinding PROJECT editor (M6 write path): name the project, pick a stitch (tap a builtin chip
/// or type a Hansen string), and keep free-text working notes — the way the craft is shared, since
/// there is no chart. Saves to the on-device nalbind library. The notation drives a live loop diagram.
///
/// The notation field is AUTHORING, so it is read in strict mode: every problem is listed under
/// the field as an error, and a reading that is not exact draws its diagram labelled approximate.
/// Saving is still allowed with problems (a project is a draft); they stay listed until fixed.
class NalbindProjectScreen extends ConsumerStatefulWidget {
  const NalbindProjectScreen({this.openId, super.key});

  /// When non-null, open this saved project (by id) instead of a fresh one.
  final String? openId;

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
  String? _id;
  bool _loading = true;
  bool _saving = false;

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
      setState(() {
        _loading = false;
        _baseline = _compose();
      });
      _refreshNotation(project.notation);
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
      );

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
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: [
                TextField(
                  controller: _name,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    labelText: 'Project name',
                    hintText: 'e.g. Winter socks',
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
