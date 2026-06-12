import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../data/draft_repository.dart';
import '../models/draft_meta.dart';
import '../widgets/drawdown_view.dart';
import 'editor_screen.dart';

/// Full-resolution drawdown of a single draft.
///
/// Two modes:
///   - `PreviewScreen.saved(id)`   — an existing library draft (read its WIF, bump
///     `lastOpened`). No Save action.
///   - `PreviewScreen.unsaved(text)` — a freshly imported, not-yet-persisted draft.
///     Shows a Save action that pops `true` once persisted.
///
/// Screens never touch the bridge directly; all rendering/IO goes through the
/// [DraftRepository], which re-parses the WIF text on demand (the Draft handle is
/// single-use).
class PreviewScreen extends StatefulWidget {
  const PreviewScreen.saved({
    required this.repository,
    required String this.id,
    super.key,
  })  : wifText = null,
        suggestedName = null;

  const PreviewScreen.unsaved({
    required this.repository,
    required String this.wifText,
    required String this.suggestedName,
    super.key,
  }) : id = null;

  final DraftRepository repository;

  /// Non-null in `.saved` mode.
  final String? id;

  /// Non-null in `.unsaved` mode (the imported WIF text, carried verbatim).
  final String? wifText;

  /// Prefill for the Save dialog name field (`.unsaved` only).
  final String? suggestedName;

  bool get isUnsaved => id == null;

  @override
  State<PreviewScreen> createState() => _PreviewScreenState();
}

class _PreviewScreenState extends State<PreviewScreen> {
  /// Render resolution: pixels per intersection. Decoupled from on-screen size
  /// (BoxFit handles layout), so this only sets crispness.
  static const int _cellPx = 12;

  ui.Image? _image;
  String? _wifText; // resolved source text, kept for Save/Edit
  DraftMeta? _meta; // sidecar metadata (saved mode), preserved into the editor
  String _title = 'Pattern';
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final String text;
      final String title;
      DraftMeta? meta;
      if (widget.isUnsaved) {
        text = widget.wifText!;
        title = widget.suggestedName!;
      } else {
        // Bump lastOpened and read the source text.
        final entry = await widget.repository.open(widget.id!);
        title = entry.meta.name;
        meta = entry.meta;
        text = await widget.repository.readWif(widget.id!);
      }
      final image = await widget.repository.renderDrawdown(text, cellPx: _cellPx);
      if (!mounted) {
        image.dispose();
        return;
      }
      setState(() {
        _wifText = text;
        _title = title;
        _meta = meta;
        _image = image;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      final msg = _friendlyError(e);
      setState(() {
        _error = msg;
        _loading = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  String _friendlyError(Object e) {
    if (e is FormatException) return "That file isn't a weaving pattern.";
    // Engine parse errors arrive as the bridge's exception; its message
    // ("WIF parse error: …") is already user-meaningful.
    return 'Could not open this pattern: $e';
  }

  Future<void> _onSave() async {
    final text = _wifText;
    if (text == null) return; // nothing rendered to save
    final input = await showDialog<_SaveInput>(
      context: context,
      builder: (_) => _SaveDraftDialog(initialName: _title),
    );
    if (input == null || !mounted) return;
    try {
      final now = DateTime.now();
      final meta = DraftMeta(
        name: input.name,
        craft: 'Weaving',
        author: input.author,
        notes: input.notes,
        savedAt: now,
        lastOpened: now,
      );
      await widget.repository.save(wifText: text, meta: meta);
      if (!mounted) return;
      Navigator.pop(context, true); // tell Library to refresh
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not save: $e')));
    }
  }

  /// Open this draft in the interactive editor. On return-with-`true` (an edit was saved):
  /// a SAVED draft is overwritten in place, so reload to show the new cloth; an UNSAVED import
  /// is saved as a NEW library entry, so leave this throwaway preview and pop back to the
  /// Library (reloading here would re-render the ORIGINAL import and strand a duplicate Save).
  Future<void> _onEdit() async {
    final text = _wifText;
    if (text == null) return;
    final navigator = Navigator.of(context);
    final changed = await navigator.push<bool>(
      MaterialPageRoute(
        builder: (_) => EditorScreen(
          wifText: text,
          title: _title,
          id: widget.id, // null in unsaved mode -> the editor saves a new entry
          meta: _meta,
        ),
      ),
    );
    if (changed != true || !mounted) return;
    if (widget.isUnsaved) {
      navigator.pop(true); // back to the Library, which refreshes to show the new entry
      return;
    }
    _image?.dispose();
    _image = null;
    setState(() => _loading = true);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    final canSave = widget.isUnsaved && image != null;
    final canEdit = image != null && _wifText != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(_title),
        actions: [
          if (canEdit)
            IconButton(
              onPressed: _onEdit,
              icon: const Icon(Icons.edit_outlined),
              tooltip: 'Edit',
            ),
          if (canSave)
            IconButton(
              onPressed: _onSave,
              icon: const Icon(Icons.save_outlined),
              tooltip: 'Save to library',
            ),
        ],
      ),
      body: Center(child: _buildBody(image)),
    );
  }

  Widget _buildBody(ui.Image? image) {
    if (_loading) return const CircularProgressIndicator();
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.broken_image_outlined, size: 48),
            const SizedBox(height: 16),
            Text(_error!, textAlign: TextAlign.center),
          ],
        ),
      );
    }
    if (image == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.all(24),
      child: DrawdownView(image),
    );
  }
}

/// The result of the Save dialog.
class _SaveInput {
  const _SaveInput({required this.name, this.author, required this.notes});
  final String name;
  final String? author;
  final String notes;
}

/// Name (+ optional author/notes) entry before persisting an imported draft.
class _SaveDraftDialog extends StatefulWidget {
  const _SaveDraftDialog({required this.initialName});

  final String initialName;

  @override
  State<_SaveDraftDialog> createState() => _SaveDraftDialogState();
}

class _SaveDraftDialogState extends State<_SaveDraftDialog> {
  late final TextEditingController _name =
      TextEditingController(text: widget.initialName);
  final TextEditingController _author = TextEditingController();
  final TextEditingController _notes = TextEditingController();
  bool _nameEmpty = false;

  @override
  void dispose() {
    _name.dispose();
    _author.dispose();
    _notes.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _nameEmpty = true);
      return;
    }
    final author = _author.text.trim();
    Navigator.pop(
      context,
      _SaveInput(
        name: name,
        author: author.isEmpty ? null : author,
        notes: _notes.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Save pattern'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              autofocus: true,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(
                labelText: 'Name',
                errorText: _nameEmpty ? 'A name is required' : null,
              ),
              onChanged: (_) {
                if (_nameEmpty) setState(() => _nameEmpty = false);
              },
            ),
            TextField(
              controller: _author,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(labelText: 'Author (optional)'),
            ),
            TextField(
              controller: _notes,
              maxLines: 3,
              decoration: const InputDecoration(labelText: 'Notes (optional)'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Save')),
      ],
    );
  }
}
