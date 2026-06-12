import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../data/draft_repository.dart';
import '../models/draft_meta.dart';
import '../widgets/drawdown_view.dart';
import '../widgets/save_draft_dialog.dart';
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
    final input = await showSaveDraftDialog(context, initialName: _title);
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

  /// Open this SAVED draft in the interactive editor and, on return-with-`true` (an edit was
  /// saved), reload the preview to show the new cloth.
  ///
  /// Edit is offered ONLY for saved drafts (see `canEdit`), so the editor always has an id +
  /// sidecar meta and overwrites in place, preserving author/notes. To edit a freshly-imported
  /// draft you Save it first (which prompts for name/author/notes) and then Edit it. The
  /// from-scratch New-draft flow gets its first-save metadata prompt inside the editor itself
  /// (`EditorScreen._save` -> `showSaveDraftDialog`, the same shared dialog this screen uses).
  Future<void> _onEdit() async {
    final text = _wifText;
    if (text == null) return;
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => EditorScreen(
          wifText: text,
          title: _title,
          id: widget.id,
          meta: _meta,
        ),
      ),
    );
    if (changed != true || !mounted) return;
    _image?.dispose();
    _image = null;
    setState(() => _loading = true);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    final canSave = widget.isUnsaved && image != null;
    final canEdit = image != null && !widget.isUnsaved; // saved drafts only (see _onEdit)
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
