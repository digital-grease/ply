import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/nalbind_project.dart';
import '../state/nalbind_providers.dart';
import '../rust/nalbind_dto.dart';
import '../widgets/nalbind_diagram_view.dart';
import '../widgets/project_photos.dart';

/// The nalbinding PROJECT editor (M6 write path): name the project, pick a stitch (tap a builtin chip
/// or type a Hansen string), and keep free-text working notes — the way the craft is shared, since
/// there is no chart. Saves to the on-device nalbind library. The notation drives a live loop diagram.
class NalbindProjectScreen extends ConsumerStatefulWidget {
  const NalbindProjectScreen({this.openId, super.key});

  /// When non-null, open this saved project (by id) instead of a fresh one.
  final String? openId;

  @override
  ConsumerState<NalbindProjectScreen> createState() => _NalbindProjectScreenState();
}

class _NalbindProjectScreenState extends ConsumerState<NalbindProjectScreen> {
  final _name = TextEditingController();
  final _notation = TextEditingController();
  final _notes = TextEditingController();

  String _stitchName = ''; // the chosen builtin's display name, '' once the notation is hand-edited
  String? _id;
  bool _loading = true;
  bool _saving = false;

  int _seq = 0;
  DiagramDto? _diagram;
  String? _diagramError;

  @override
  void initState() {
    super.initState();
    _id = widget.openId;
    _load();
  }

  Future<void> _load() async {
    if (widget.openId == null) {
      setState(() => _loading = false);
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
      setState(() => _loading = false);
      _refreshDiagram(project.notation);
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _snack('Could not open the project: $e');
    }
  }

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

  /// Parse the notation to a diagram, latest-wins (a fast edit supersedes an older parse).
  Future<void> _refreshDiagram(String notation) async {
    final trimmed = notation.trim();
    final mySeq = ++_seq;
    if (trimmed.isEmpty) {
      setState(() {
        _diagram = null;
        _diagramError = null;
      });
      return;
    }
    try {
      final repo = ref.read(nalbindRepositoryProvider);
      final stitch = await repo.parse(trimmed);
      final diagram = await repo.diagram(stitch);
      if (!mounted || mySeq != _seq) return;
      setState(() {
        _diagram = diagram;
        _diagramError = null;
      });
    } catch (e) {
      if (!mounted || mySeq != _seq) return;
      final s = e.toString();
      final i = s.indexOf('invalid Hansen notation:');
      setState(() {
        _diagram = null;
        _diagramError = i >= 0 ? s.substring(i) : s;
      });
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final repo = ref.read(nalbindRepositoryProvider);
      final project = NalbindProject(
        name: _name.text.trim().isEmpty ? 'Untitled' : _name.text.trim(),
        notation: _notation.text.trim(),
        stitchName: _stitchName,
        notes: _notes.text,
      );
      final id = await repo.saveProject(project, id: _id);
      ref.invalidate(nalbindProjectsProvider); // refresh the library list
      if (!mounted) return;
      // Save in place (don't pop) so the Photos section can appear now that we have an id.
      setState(() => _id = id);
      _snack('Saved.');
    } catch (e) {
      if (mounted) _snack('Could not save: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final builtins = ref.watch(nalbindBuiltinsProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.openId == null ? 'New project' : 'Project'),
        actions: [
          IconButton(
            tooltip: 'Save',
            icon: const Icon(Icons.save_outlined),
            onPressed: _saving ? null : _save,
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
                    _refreshDiagram(v);
                  },
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: 'Hansen notation',
                    hintText: 'e.g. UO/UOO F1',
                  ),
                ),
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
                            _refreshDiagram(code);
                          },
                        ),
                    ],
                  ),
                  orElse: () => const SizedBox.shrink(),
                ),
                if (_diagramError != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(_diagramError!, style: TextStyle(color: cs.error)),
                  ),
                if (_diagram != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: NalbindDiagramView(diagram: _diagram!),
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
    );
  }
}
