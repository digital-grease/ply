import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../data/library_backup.dart' show BackupCraft;
import '../data/tablet_repository.dart';
import '../models/tablet_band.dart';
import '../widgets/tablet_widgets.dart' show TabletReviewNote, tabletTextLimit;
import '../rust/tablet_dto.dart' show TabletDocumentDto;
import '../state/tablet_editor_providers.dart';
import '../state/thumbnail_providers.dart';
import '../util/responsive.dart';
import '../widgets/library_place.dart';
import '../widgets/name_input_dialog.dart';
import '../widgets/project_export.dart';
import '../widgets/thumb_unavailable.dart';
import 'tablet_editor_screen.dart';
import 'tablet_tracker_screen.dart' show kTabletTrackerTitle;

/// The Tablet weaving tab of the library (M10-02; "card weaving" is another name for the craft): a
/// grid of saved `.plytab` bands with thumbnails and a New band button. A tile without a thumbnail
/// asks [thumbnailRegeneratorProvider] to rebuild it in the background (once per app run).
class TabletLibraryScreen extends ConsumerStatefulWidget {
  const TabletLibraryScreen({super.key});

  @override
  ConsumerState<TabletLibraryScreen> createState() => _TabletLibraryScreenState();
}

enum _TileAction { open, track, rename, export, delete }

class _TabletLibraryScreenState extends ConsumerState<TabletLibraryScreen>
    with LibraryPlaces<TabletLibraryScreen> {
  late Future<List<TabletEntry>> _entriesFuture;
  final Set<String> _rebuiltThumbs = {};

  @override
  BackupCraft get placesCraft => BackupCraft.tabletWeaving;

  /// True from a tap that opens a band until its editor closes: a second tap opens no second editor
  /// (nor a second tracker on the same record).
  bool _opening = false;

  /// Bands whose thumbnail could not be drawn although they have something to draw: their tile
  /// says so (the shared "no preview" mark, ADR 0021) instead of the plain placeholder.
  final Set<String> _failedThumbs = {};

  @override
  void initState() {
    super.initState();
    _entriesFuture = _load();
  }

  /// List the bands, then rebuild the missing thumbnails and read each band's saved place in the
  /// background (the list waits for neither).
  Future<List<TabletEntry>> _load() {
    final future = ref.read(tabletRepositoryProvider).listBands();
    future.then(_rebuildMissingThumbnails, onError: (Object _) {});
    future.then((entries) => readPlaces([for (final e in entries) e.id]), onError: (Object _) {});
    return future;
  }

  static String _thumbPathOf(TabletEntry e) => p.join(p.dirname(e.bandPath), '${e.id}.png');

  void _rebuildMissingThumbnails(List<TabletEntry> entries) {
    if (!mounted) return;
    final regenerator = ref.read(thumbnailRegeneratorProvider);
    final repository = ref.read(tabletRepositoryProvider);
    for (final entry in entries) {
      if (entry.thumbPath != null) continue;
      final id = entry.id;
      final thumb = _thumbPathOf(entry);
      regenerator.request('tablet_weaving/$id', () async {
        await repository.rebuildThumbnail(id); // writes nothing for a band with nothing to draw
        return File(thumb).existsSync();
      }).then((rebuilt) async {
        // A band with no cards or no picks has nothing to draw: the plain placeholder, not a failure.
        final failed = !rebuilt && await repository.hasSomethingToDraw(id) != false;
        if (!mounted) return;
        setState(() {
          if (rebuilt) _rebuiltThumbs.add(id);
          if (failed) _failedThumbs.add(id);
        });
      });
    }
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    final future = _load();
    setState(() {
      _entriesFuture = future;
    });
    await future;
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _newBand() async {
    final navigator = Navigator.of(context);
    final doc = await showNewBandDialog(context);
    if (doc == null) return;
    await navigator.push(
      MaterialPageRoute<void>(builder: (_) => TabletEditorScreen(initialDoc: doc)),
    );
    await _refresh();
  }

  /// Open a saved band in the editor; with [track], straight on into Weave pick by pick from there,
  /// as the editor's menu opens it (back from the tracker is the editor, its stepper at the place).
  Future<void> _open(TabletEntry entry, {bool track = false}) async {
    if (_opening) return;
    _opening = true;
    try {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
            builder: (_) => TabletEditorScreen(openId: entry.id, openTracker: track)),
      );
    } finally {
      _opening = false;
    }
    await _refresh();
  }

  Future<void> _rename(TabletEntry entry) async {
    final newName = await promptForName(context,
        title: 'Rename band',
        confirmLabel: 'Rename',
        initial: entry.meta.name,
        validator: tabletTextLimit(kMaxTabletTextBytes));
    if (newName == null || newName == entry.meta.name || !mounted) return;
    try {
      await ref.read(tabletRepositoryProvider).renameBand(entry.id, newName);
      await _refresh();
    } catch (e) {
      _snack('Rename failed: $e');
    }
  }

  Future<void> _delete(TabletEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete band?'),
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
    if (confirmed != true || !mounted) return;
    try {
      await ref.read(tabletRepositoryProvider).deleteBand(entry.id);
      await _refresh();
    } catch (e) {
      _snack('Delete failed: $e');
    }
  }

  Future<void> _handle(_TileAction action, TabletEntry entry) async {
    switch (action) {
      case _TileAction.open:
        await _open(entry);
      case _TileAction.track:
        await _open(entry, track: true);
      case _TileAction.rename:
        await _rename(entry);
      case _TileAction.export:
        if (!mounted) return;
        await exportProject(context, ref,
            craft: BackupCraft.tabletWeaving, id: entry.id, name: entry.meta.name);
      case _TileAction.delete:
        await _delete(entry);
    }
  }

  Future<void> _showActions(TabletEntry entry) async {
    final action = await showModalBottomSheet<_TileAction>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (a, icon, label) in [
              (_TileAction.open, Icons.open_in_new, 'Open'),
              (_TileAction.track, Icons.playlist_play, kTabletTrackerTitle),
              (_TileAction.rename, Icons.drive_file_rename_outline, 'Rename'),
              (_TileAction.export, Icons.save_alt, 'Export'),
              (_TileAction.delete, Icons.delete_outline, 'Delete'),
            ])
              ListTile(
                leading: Icon(icon),
                title: Text(label),
                onTap: () => Navigator.pop(ctx, a),
              ),
          ],
        ),
      ),
    );
    if (action != null) await _handle(action, entry);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<TabletEntry>>(
      future: _entriesFuture,
      builder: (context, snapshot) {
        final done = snapshot.connectionState == ConnectionState.done;
        final entries = snapshot.data ?? const <TabletEntry>[];
        final isEmpty = done && !snapshot.hasError && entries.isEmpty;
        // No AppBar: this is a tab inside HomeScreen, which owns the shared chrome.
        return Scaffold(
          body: _body(snapshot, entries),
          floatingActionButton: isEmpty
              ? null
              : FloatingActionButton.extended(
                  heroTag: 'newTabletBand',
                  onPressed: _newBand,
                  icon: const Icon(Icons.add),
                  label: const Text('New band'),
                ),
        );
      },
    );
  }

  Widget _body(AsyncSnapshot<List<TabletEntry>> snapshot, List<TabletEntry> entries) {
    if (snapshot.connectionState != ConnectionState.done) {
      return const Center(child: CircularProgressIndicator());
    }
    if (snapshot.hasError) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text('Could not load your bands:\n${snapshot.error}', textAlign: TextAlign.center),
        ),
      );
    }
    if (entries.isEmpty) return _emptyState();
    // The thumbnails show computed faces: they carry the review note while it applies.
    final pending = ref.watch(tabletReviewPendingProvider).valueOrNull ?? true;
    return Column(children: [
      TabletReviewNote(pending: pending, dense: true),
      Expanded(child: _grid(entries)),
    ]);
  }

  Widget _grid(List<TabletEntry> entries) {
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
            Icon(Icons.view_week_outlined, size: 64, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 16),
            const Text(
              'No tablet weaving bands yet.\nSet up your cards and their turns to begin.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _newBand,
              icon: const Icon(Icons.add),
              label: const Text('New band'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tile(TabletEntry entry) {
    return Semantics(
      container: true,
      explicitChildNodes: true,
      button: true,
      label: 'Band ${entry.meta.name}',
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
                      tooltip: 'Band actions',
                      padding: EdgeInsets.zero,
                      onSelected: (a) => _handle(a, entry),
                      itemBuilder: (_) => const [
                        // Straight into the tracker at the saved place (ADR 0023).
                        PopupMenuItem(value: _TileAction.track, child: Text(kTabletTrackerTitle)),
                        PopupMenuItem(value: _TileAction.rename, child: Text('Rename')),
                        PopupMenuItem(value: _TileAction.export, child: Text('Export')),
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
              // The saved place (ADR 0023), when the band has one: a way straight into the tracker.
              if (placeOf(entry.id) case final place?)
                LibraryPlaceLine(
                  key: ValueKey('library-place-${entry.id}'),
                  place: place,
                  trackerTitle: kTabletTrackerTitle,
                  onOpen: () => _open(entry, track: true),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _thumb(TabletEntry entry) {
    final path =
        entry.thumbPath ?? (_rebuiltThumbs.contains(entry.id) ? _thumbPathOf(entry) : null);
    if (path != null) {
      return Image.file(
        File(path),
        fit: BoxFit.contain,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => thumbUnavailable(context),
      );
    }
    if (_failedThumbs.contains(entry.id)) return thumbUnavailable(context);
    return _placeholder();
  }

  Widget _placeholder() => ColoredBox(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Center(
            child: Icon(Icons.view_week_outlined, color: Theme.of(context).colorScheme.outline)),
      );
}

/// Ask for a new band's cards and start position; null when cancelled. The first start offered, and
/// the one chosen until the weaver picks another, is [kFirstTabletPreset].
Future<TabletDocumentDto?> showNewBandDialog(BuildContext context) {
  return showDialog<TabletDocumentDto>(
    context: context,
    builder: (ctx) => const _NewBandDialog(),
  );
}

class _NewBandDialog extends StatefulWidget {
  const _NewBandDialog();

  @override
  State<_NewBandDialog> createState() => _NewBandDialogState();
}

class _NewBandDialogState extends State<_NewBandDialog> {
  int _cards = 8;
  TabletPreset _preset = kFirstTabletPreset;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).textTheme.bodySmall;
    return AlertDialog(
      title: const Text('New band'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(child: Text('Cards')),
                IconButton(
                  tooltip: 'Fewer cards',
                  icon: const Icon(Icons.remove),
                  onPressed: _cards > 1 ? () => setState(() => _cards--) : null,
                ),
                Semantics(
                  liveRegion: true,
                  label: '$_cards cards',
                  child: ExcludeSemantics(
                    child: Text('$_cards', style: Theme.of(context).textTheme.titleMedium),
                  ),
                ),
                IconButton(
                  tooltip: 'More cards',
                  icon: const Icon(Icons.add),
                  onPressed: _cards < kMaxTabletCards ? () => setState(() => _cards++) : null,
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text('Every card starts at'),
            RadioGroup<TabletPreset>(
              groupValue: _preset,
              onChanged: (v) => setState(() => _preset = v ?? _preset),
              child: Column(children: [
                for (final preset in tabletPresetsInOrder)
                  RadioListTile<TabletPreset>(
                    key: ValueKey('new-band-${preset.name}'),
                    contentPadding: EdgeInsets.zero,
                    value: preset,
                    title: Text(preset.label),
                    subtitle: Text(preset.description, style: muted),
                  ),
              ]),
            ),
            Text(
                'Cards on the left half start S-threaded, the right half Z-threaded. You can change '
                'every card afterwards.',
                style: muted),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () =>
              Navigator.pop(context, blankTabletDocument(cards: _cards, preset: _preset)),
          child: const Text('Create'),
        ),
      ],
    );
  }
}
