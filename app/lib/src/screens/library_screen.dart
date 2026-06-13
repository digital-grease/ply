import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../data/draft_repository.dart';
import '../models/draft_doc.dart';
import '../models/draft_meta.dart';
import '../util/responsive.dart';
import 'editor_screen.dart';
import 'glossary_screen.dart';
import 'preview_screen.dart';
import 'settings_screen.dart';

/// Home screen: a grid of saved drafts with preview thumbnails, plus an import FAB.
///
/// Depends only on [DraftRepository] (never the generated bridge). `dart:io` is
/// imported solely to wrap a thumbnail path in a `File` for `Image.file`.
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({required this.repository, super.key});

  final DraftRepository repository;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

enum _TileAction { open, rename, delete }

class _LibraryScreenState extends State<LibraryScreen> {
  late Future<List<DraftEntry>> _entriesFuture;

  @override
  void initState() {
    super.initState();
    _entriesFuture = widget.repository.list();
  }

  /// Re-scan the library and rebuild. Returns the future so RefreshIndicator can
  /// await it. Self-guards `mounted` so every caller (some reached after an await)
  /// is safe even if this screen is ever made poppable later.
  Future<void> _refresh() async {
    if (!mounted) return;
    final future = widget.repository.list();
    setState(() => _entriesFuture = future);
    await future;
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // --- Actions ---------------------------------------------------------------

  Future<void> _import() async {
    try {
      // `.wif` has no MIME type, so a custom extension filter throws on Android.
      // Pick any file; the engine's parser decides if it's a real pattern.
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        withData: true, // populate .bytes on mobile
        allowMultiple: false,
      );
      if (result == null) return; // cancelled
      final picked = result.files.single;
      final bytes = picked.bytes;
      if (bytes == null) {
        _snack('Could not read the selected file.');
        return;
      }
      final text = utf8.decode(bytes); // WIF is INI-style text
      final stem = p.basenameWithoutExtension(picked.name);
      if (!mounted) return;
      final saved = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) => PreviewScreen.unsaved(
            repository: widget.repository,
            wifText: text,
            suggestedName: stem.isEmpty ? 'Imported pattern' : stem,
          ),
        ),
      );
      if (saved == true) {
        _snack('Saved to library.');
        await _refresh();
      }
    } on FormatException {
      _snack("That file isn't a weaving pattern.");
    } catch (e) {
      _snack('Import failed: $e');
    }
  }

  /// Start a from-scratch draft: open the editor on a blank document (no source WIF, no meta). The
  /// editor prompts for name/author/notes on its first save and pops `true` when it lands in the
  /// library.
  Future<void> _newDraft() async {
    final navigator = Navigator.of(context);
    final saved = await navigator.push<bool>(
      MaterialPageRoute(
        builder: (_) => EditorScreen(initialDoc: DraftDoc.blank(), title: 'New draft'),
      ),
    );
    if (saved == true) {
      _snack('Saved to library.');
      await _refresh();
    }
  }

  Future<void> _open(DraftEntry entry) async {
    final navigator = Navigator.of(context);
    await navigator.push(
      MaterialPageRoute(
        builder: (_) =>
            PreviewScreen.saved(repository: widget.repository, id: entry.id),
      ),
    );
    // lastOpened was bumped by opening → re-sort the grid (_refresh self-guards mounted).
    await _refresh();
  }

  Future<void> _rename(DraftEntry entry) async {
    final controller = TextEditingController(text: entry.meta.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename pattern'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Name'),
          onSubmitted: (_) {
            final v = controller.text.trim();
            if (v.isNotEmpty) Navigator.pop(ctx, v);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final v = controller.text.trim();
              if (v.isNotEmpty) Navigator.pop(ctx, v);
            },
            child: const Text('Rename'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (newName == null || newName == entry.meta.name) return;
    try {
      await widget.repository.rename(entry.id, newName);
      await _refresh();
    } catch (e) {
      _snack('Rename failed: $e');
    }
  }

  Future<void> _delete(DraftEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete pattern?'),
        content: Text('"${entry.meta.name}" will be permanently removed.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.repository.delete(entry.id);
      await _refresh();
    } catch (e) {
      _snack('Delete failed: $e');
    }
  }

  Future<void> _handle(_TileAction action, DraftEntry entry) async {
    switch (action) {
      case _TileAction.open:
        await _open(entry);
      case _TileAction.rename:
        await _rename(entry);
      case _TileAction.delete:
        await _delete(entry);
    }
  }

  Future<void> _showActions(DraftEntry entry) async {
    final action = await showModalBottomSheet<_TileAction>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.open_in_new),
              title: const Text('Open'),
              onTap: () => Navigator.pop(ctx, _TileAction.open),
            ),
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline),
              title: const Text('Rename'),
              onTap: () => Navigator.pop(ctx, _TileAction.rename),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Delete'),
              onTap: () => Navigator.pop(ctx, _TileAction.delete),
            ),
          ],
        ),
      ),
    );
    if (action != null) await _handle(action, entry);
  }

  // --- Build -----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    // Wrap the Scaffold in the FutureBuilder so the FAB can see the load state: an EMPTY library
    // shows a centered New-draft / Import call to action in _emptyState(), so suppress the FABs
    // there to avoid offering the same two actions twice. They return once a pattern exists.
    return FutureBuilder<List<DraftEntry>>(
      future: _entriesFuture,
      builder: (context, snapshot) {
        final done = snapshot.connectionState == ConnectionState.done;
        final entries = snapshot.data ?? const <DraftEntry>[];
        final isEmpty = done && !snapshot.hasError && entries.isEmpty;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Ply · Patterns'),
            actions: [
              IconButton(
                tooltip: 'Glossary',
                icon: const Icon(Icons.menu_book_outlined),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const GlossaryScreen()),
                ),
              ),
              IconButton(
                tooltip: 'Settings',
                icon: const Icon(Icons.settings_outlined),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
                ),
              ),
            ],
          ),
          body: _libraryBody(snapshot, entries),
          floatingActionButton: isEmpty ? null : _fabColumn(),
        );
      },
    );
  }

  Widget _libraryBody(
      AsyncSnapshot<List<DraftEntry>> snapshot, List<DraftEntry> entries) {
    if (snapshot.connectionState != ConnectionState.done) {
      return const Center(child: CircularProgressIndicator());
    }
    if (snapshot.hasError) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            'Could not load your library:\n${snapshot.error}',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    if (entries.isEmpty) return _emptyState();
    return RefreshIndicator(
      onRefresh: _refresh,
      child: GridView.builder(
        padding: const EdgeInsets.all(12),
        physics: const AlwaysScrollableScrollPhysics(),
        gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
          // Wider tiles on a tablet so the grid fills the width instead of a sparse phone-sized 2-up.
          maxCrossAxisExtent: isWide(context) ? 240 : 180,
          childAspectRatio: 0.8,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
        ),
        itemCount: entries.length,
        itemBuilder: (_, i) => _tile(entries[i]),
      ),
    );
  }

  Widget _fabColumn() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        FloatingActionButton.extended(
          heroTag: 'import',
          onPressed: _import,
          icon: const Icon(Icons.file_open_outlined),
          label: const Text('Import'),
        ),
        const SizedBox(height: 12),
        FloatingActionButton.extended(
          heroTag: 'newDraft',
          onPressed: _newDraft,
          icon: const Icon(Icons.add),
          label: const Text('New draft'),
        ),
      ],
    );
  }

  Widget _emptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.grid_on_outlined,
              size: 64,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 16),
            const Text(
              'No patterns yet.\nStart a new draft, or import a WIF file.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _newDraft,
              icon: const Icon(Icons.add),
              label: const Text('New draft'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _import,
              icon: const Icon(Icons.file_open_outlined),
              label: const Text('Import pattern'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tile(DraftEntry entry) {
    // The whole tile is one button (opens the draft); the thumbnail is decorative and the name is
    // folded into the tile label, so a screen reader hears "Pattern <name>, button" once (not the
    // image + the name twice). The ⋮ stays a separate, reachable button (its tooltip labels it) so
    // rename/delete don't depend on a long-press gesture.
    return Semantics(
      button: true,
      label: 'Pattern ${entry.meta.name}',
      onTapHint: 'open',
      onLongPressHint: 'show actions',
      child: Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _open(entry),
        onLongPress: () => _showActions(entry),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: ExcludeSemantics(child: _thumb(entry))),
            Padding(
              padding: const EdgeInsets.only(left: 10, right: 2, top: 4, bottom: 4),
              child: Row(
                children: [
                  Expanded(
                    child: ExcludeSemantics(
                      child: Text(
                        entry.meta.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                  ),
                  PopupMenuButton<_TileAction>(
                    tooltip: 'Pattern actions',
                    padding: EdgeInsets.zero,
                    onSelected: (a) => _handle(a, entry),
                    itemBuilder: (_) => const [
                      PopupMenuItem(
                        value: _TileAction.rename,
                        child: Text('Rename'),
                      ),
                      PopupMenuItem(
                        value: _TileAction.delete,
                        child: Text('Delete'),
                      ),
                    ],
                    child: const SizedBox(
                      width: 32,
                      height: 32,
                      child: Icon(Icons.more_vert, size: 18),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }

  Widget _thumb(DraftEntry entry) {
    final path = entry.thumbPath;
    if (path != null) {
      return Image.file(
        File(path),
        fit: BoxFit.contain,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => _thumbPlaceholder(),
      );
    }
    return _thumbPlaceholder();
  }

  Widget _thumbPlaceholder() {
    return ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Center(
        child: Icon(
          Icons.grid_on,
          color: Theme.of(context).colorScheme.outline,
        ),
      ),
    );
  }
}
