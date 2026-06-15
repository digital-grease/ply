import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/knit_entry.dart';
import '../state/knit_editor_providers.dart';
import '../util/responsive.dart';
import '../widgets/name_input_dialog.dart';
import 'knit_editor_screen.dart';

/// The on-device knitting-pattern library: a grid of saved `.plyknit` patterns with thumbnails, plus
/// a New-pattern FAB. The knit analog of [LibraryScreen]; kept SEPARATE from the weave library for
/// now (unifying the two crafts into one home is an owner-level decision, deferred).
///
/// Riverpod-wired to [knitRepositoryProvider] (the same repo the editor uses) so a test can inject a
/// fake. `dart:io` is only for wrapping a thumbnail path in a `File` for `Image.file`.
class KnitLibraryScreen extends ConsumerStatefulWidget {
  const KnitLibraryScreen({super.key});

  @override
  ConsumerState<KnitLibraryScreen> createState() => _KnitLibraryScreenState();
}

enum _TileAction { open, rename, delete }

class _KnitLibraryScreenState extends ConsumerState<KnitLibraryScreen> {
  late Future<List<KnitEntry>> _entriesFuture;

  @override
  void initState() {
    super.initState();
    _entriesFuture = ref.read(knitRepositoryProvider).listKnits();
  }

  /// Re-scan the library and rebuild; returns the future so a RefreshIndicator can await it. Self-
  /// guards `mounted` (callers reach it after an await).
  ///
  /// NB: the setState callback MUST be a block body. An arrow body `() => _entriesFuture = future`
  /// evaluates to the assigned Future, and `setState` throws on a callback that returns a Future.
  Future<void> _refresh() async {
    if (!mounted) return;
    final future = ref.read(knitRepositoryProvider).listKnits();
    setState(() {
      _entriesFuture = future;
    });
    await future;
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // --- Actions ---------------------------------------------------------------

  /// Start a fresh pattern. The editor saves in place (it does not pop a result), so just re-scan on
  /// return to pick up anything saved.
  Future<void> _newPattern() async {
    final navigator = Navigator.of(context);
    await navigator.push(
      MaterialPageRoute<void>(builder: (_) => const KnitEditorScreen()),
    );
    await _refresh();
  }

  Future<void> _open(KnitEntry entry) async {
    final navigator = Navigator.of(context);
    await navigator.push(
      MaterialPageRoute<void>(builder: (_) => KnitEditorScreen(openId: entry.id)),
    );
    // Opening bumped lastOpened (and the user may have re-saved) → re-sort the grid.
    await _refresh();
  }

  Future<void> _rename(KnitEntry entry) async {
    final newName = await promptForName(
      context,
      title: 'Rename pattern',
      confirmLabel: 'Rename',
      initial: entry.meta.name,
    );
    if (newName == null || newName == entry.meta.name) return;
    if (!mounted) return; // the rename dialog is an async gap
    try {
      await ref.read(knitRepositoryProvider).renameKnit(entry.id, newName);
      await _refresh();
    } catch (e) {
      _snack('Rename failed: $e');
    }
  }

  Future<void> _delete(KnitEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete pattern?'),
        content: Text('"${entry.meta.name}" will be permanently removed.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!mounted) return; // the confirm dialog is an async gap
    try {
      await ref.read(knitRepositoryProvider).deleteKnit(entry.id);
      await _refresh();
    } catch (e) {
      _snack('Delete failed: $e');
    }
  }

  Future<void> _handle(_TileAction action, KnitEntry entry) async {
    switch (action) {
      case _TileAction.open:
        await _open(entry);
      case _TileAction.rename:
        await _rename(entry);
      case _TileAction.delete:
        await _delete(entry);
    }
  }

  Future<void> _showActions(KnitEntry entry) async {
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
    return FutureBuilder<List<KnitEntry>>(
      future: _entriesFuture,
      builder: (context, snapshot) {
        final done = snapshot.connectionState == ConnectionState.done;
        final entries = snapshot.data ?? const <KnitEntry>[];
        final isEmpty = done && !snapshot.hasError && entries.isEmpty;
        // No AppBar: this is the Knitting TAB inside HomeScreen, which owns the shared chrome. The
        // inner Scaffold hosts the New-pattern FAB + body within the tab.
        return Scaffold(
          body: _body(snapshot, entries),
          floatingActionButton: isEmpty
              ? null
              : FloatingActionButton.extended(
                  heroTag: 'newKnit',
                  onPressed: _newPattern,
                  icon: const Icon(Icons.add),
                  label: const Text('New pattern'),
                ),
        );
      },
    );
  }

  Widget _body(AsyncSnapshot<List<KnitEntry>> snapshot, List<KnitEntry> entries) {
    if (snapshot.connectionState != ConnectionState.done) {
      return const Center(child: CircularProgressIndicator());
    }
    if (snapshot.hasError) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text('Could not load your patterns:\n${snapshot.error}',
              textAlign: TextAlign.center),
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

  Widget _emptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.grid_on_outlined, size: 64, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 16),
            const Text('No knitting patterns yet.\nStart a new chart to begin.',
                textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _newPattern,
              icon: const Icon(Icons.add),
              label: const Text('New pattern'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tile(KnitEntry entry) {
    // One tile = one node: the label + open/show-actions live on the outer Semantics so a screen
    // reader hears "Pattern <name>, button" once; the ⋮ stays a separate reachable child. (Same
    // a11y shape as the weave library tile.)
    return Semantics(
      container: true,
      explicitChildNodes: true,
      button: true,
      label: 'Pattern ${entry.meta.name}',
      onTapHint: 'open',
      onLongPressHint: 'show actions',
      onTap: () => _open(entry),
      onLongPress: () => _showActions(entry),
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _open(entry),
          onLongPress: () => _showActions(entry),
          excludeFromSemantics: true,
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
                        PopupMenuItem(value: _TileAction.rename, child: Text('Rename')),
                        PopupMenuItem(value: _TileAction.delete, child: Text('Delete')),
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

  Widget _thumb(KnitEntry entry) {
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
      child: Center(child: Icon(Icons.grid_on, color: Theme.of(context).colorScheme.outline)),
    );
  }
}
