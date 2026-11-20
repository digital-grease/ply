import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../data/draft_repository.dart';
import '../data/library_backup.dart' show BackupCraft;
import '../models/draft_meta.dart';
import '../models/loom_type.dart';
import '../state/backup_providers.dart' show backupFileAccessProvider;
import '../state/editor_providers.dart' show draftLibraryWritesProvider;
import '../state/thumbnail_providers.dart';
import '../util/responsive.dart';
import '../widgets/draft_notes_dialog.dart';
import '../widgets/library_place.dart';
import '../widgets/loom_type_picker.dart';
import '../widgets/name_input_dialog.dart' show projectNameProblem, promptForName;
import '../widgets/project_export.dart';
import '../widgets/thumb_unavailable.dart';
import 'editor_screen.dart';
import 'preview_screen.dart';
import 'weave_tracker_screen.dart' show kWeaveTrackerTitle;

/// Home screen: a grid of saved drafts with preview thumbnails, plus an import FAB.
///
/// Depends only on [DraftRepository] (never the generated bridge). `dart:io` wraps a thumbnail
/// path in a `File` for `Image.file` and checks that a rebuilt thumbnail landed. A tile without a
/// thumbnail asks [thumbnailRegeneratorProvider] to rebuild it in the background (once per app run).
class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({required this.repository, super.key});

  final DraftRepository repository;

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

enum _TileAction { open, track, rename, notes, export, delete }

/// Why an imported file that is not UTF-8 text cannot be read.
const String kImportNotUtf8 = 'Ply could not read that file: a WIF file is text, and this one is '
    'not UTF-8 text (older weaving programs may save in another text encoding). Nothing was '
    'imported.';

class _LibraryScreenState extends ConsumerState<LibraryScreen> with LibraryPlaces<LibraryScreen> {
  late Future<List<DraftEntry>> _entriesFuture;

  @override
  BackupCraft get placesCraft => BackupCraft.weaving;

  /// Drafts listed without a thumbnail whose thumbnail has since been rebuilt.
  final Set<String> _rebuiltThumbs = {};

  /// Drafts whose thumbnail could not be rebuilt (the draft could not be read or drawn): their tile
  /// says so instead of showing the ordinary empty placeholder (ADR 0021, no silent blank image).
  final Set<String> _failedThumbs = {};

  /// Drafts whose notes are being read or shown (see [_handle]).
  final Set<String> _notesOpen = {};

  /// True from a tap that opens a draft until its editor closes: a second tap while the draft is
  /// still being read opens no second editor (nor a second tracker on the same record).
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    _entriesFuture = _load();
  }

  /// List the library, then rebuild the missing thumbnails and read each draft's saved place in
  /// the background (the list waits for neither).
  Future<List<DraftEntry>> _load() {
    final future = widget.repository.list();
    future.then(_rebuildMissingThumbnails, onError: (Object _) {});
    future.then((entries) => readPlaces([for (final e in entries) e.id]), onError: (Object _) {});
    return future;
  }

  /// Where a draft's thumbnail lives (beside its `.wif`, as the repository writes it).
  static String _thumbPathOf(DraftEntry entry) =>
      p.join(p.dirname(entry.wifPath), '${entry.id}.png');

  void _rebuildMissingThumbnails(List<DraftEntry> entries) {
    if (!mounted) return;
    final regenerator = ref.read(thumbnailRegeneratorProvider);
    final repository = widget.repository;
    for (final entry in entries) {
      if (entry.thumbPath != null) continue;
      final id = entry.id;
      final thumb = _thumbPathOf(entry);
      regenerator.request('weaving/$id', () async {
        await repository.rebuildThumbnail(id); // best-effort: writes nothing it cannot draw
        return File(thumb).existsSync();
      }).then((rebuilt) async {
        // A draft with no ends or no picks has nothing to draw: the plain placeholder, not a failure.
        final failed = !rebuilt && await repository.hasCloth(id) != false;
        if (!mounted) return;
        setState(() {
          if (rebuilt) _rebuiltThumbs.add(id);
          if (failed) _failedThumbs.add(id);
        });
      });
    }
  }

  /// Re-scan the library and rebuild. Returns the future so RefreshIndicator can
  /// await it. Self-guards `mounted` so every caller (some reached after an await)
  /// is safe even if this screen is ever made poppable later.
  ///
  /// NB: the setState callback MUST be a block body. An arrow body `() => _entriesFuture = future`
  /// evaluates to the assigned Future, and `setState` throws on a callback that returns a Future
  /// (which the delete/rename try-catch would silently swallow, leaving the grid stale).
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
      // WIF is INI-style text. A file that is not UTF-8 says so with its reason (ADR 0021): it is
      // not "not a weaving pattern", Ply just cannot read it as text.
      final String text;
      try {
        text = utf8.decode(bytes);
      } on FormatException {
        _snack(kImportNotUtf8);
        return;
      }
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

  /// Start a from-scratch draft: pick the loom type, then open the editor on a blank document set up
  /// for it (no source WIF, no meta). The editor prompts for name/author/notes on its first save and
  /// pops `true` when it lands in the library.
  Future<void> _newDraft() async {
    final loom = await showLoomTypePicker(context, current: LoomType.jack);
    if (loom == null || !mounted) return; // dismissed the picker -> no new draft
    final navigator = Navigator.of(context);
    final saved = await navigator.push<bool>(
      MaterialPageRoute(
        builder: (_) => EditorScreen(
          initialDoc: blankDraftForLoom(loom),
          initialLoomType: loom,
          title: 'New draft',
        ),
      ),
    );
    if (saved == true) {
      _snack('Saved to library.');
      await _refresh();
    }
  }

  /// Open a saved draft in the editor; with [track], straight on into Weave pick by pick from there,
  /// as the editor's menu opens it (back from the tracker is the editor). The grid, and each tile's
  /// place, are read again on return.
  Future<void> _open(DraftEntry entry, {bool track = false}) async {
    if (_opening) return;
    _opening = true;
    final bool opened;
    try {
      opened = await _openDraft(entry, track: track);
    } finally {
      // Released as the editor closes, before the listing: a tap during it opens a draft.
      _opening = false;
    }
    if (opened) await _refresh();
  }

  /// Read [entry]'s draft and push its editor; resolves once the editor has closed (false when the
  /// draft could not be read, so no editor opened).
  Future<bool> _openDraft(DraftEntry entry, {required bool track}) async {
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    // Open a saved draft STRAIGHT into the editor (the working view), not the read-only preview —
    // the editor is the default for a tapped draft. Load its WIF the same way the preview's Edit
    // action did, and bump `lastOpened` via repository.open so the grid re-sorts on return.
    final String wifText;
    final DraftEntry opened;
    try {
      opened = await widget.repository.open(entry.id);
      wifText = await widget.repository.readWif(entry.id);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not open draft: $e')));
      return false;
    }
    await navigator.push<bool>(
      MaterialPageRoute(
        builder: (_) => EditorScreen(
          wifText: wifText,
          title: opened.meta.name,
          id: entry.id,
          meta: opened.meta,
          openTracker: track,
        ),
      ),
    );
    return true;
  }

  Future<void> _rename(DraftEntry entry) async {
    // The shared name dialog (which owns its text controller), with the name's length limit: a
    // name saved before the limit opens as it is and must be shortened to rename it.
    final newName = await promptForName(context,
        title: 'Rename pattern',
        confirmLabel: 'Rename',
        initial: entry.meta.name,
        validator: projectNameProblem);
    if (!mounted) return;
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
      case _TileAction.track:
        await _open(entry, track: true);
      case _TileAction.rename:
        await _rename(entry);
      case _TileAction.notes:
        // The action sheet was an async gap; and Notes chosen again while a draft's notes are
        // still being read opens no second notes editor.
        if (!mounted || !_notesOpen.add(entry.id)) return;
        // The notes from the draft's first save (ADR 0007), read from and written to its sidecar
        // alone. Nothing in the grid shows them, so the library is not listed again.
        try {
          final files = ref.read(backupFileAccessProvider);
          await editDraftNotes(context, widget.repository,
              id: entry.id,
              draftName: entry.meta.name,
              saveFile: (name, bytes) => files.save(name, bytes, dialogTitle: 'Save notes'));
        } finally {
          _notesOpen.remove(entry.id);
        }
      case _TileAction.export:
        if (!mounted) return; // the action sheet was an async gap
        await exportProject(context, ref,
            craft: BackupCraft.weaving, id: entry.id, name: entry.meta.name);
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
              leading: const Icon(Icons.playlist_play),
              title: const Text(kWeaveTrackerTitle),
              onTap: () => Navigator.pop(ctx, _TileAction.track),
            ),
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline),
              title: const Text('Rename'),
              onTap: () => Navigator.pop(ctx, _TileAction.rename),
            ),
            ListTile(
              leading: const Icon(Icons.notes),
              title: const Text(kDraftNotesTitle),
              onTap: () => Navigator.pop(ctx, _TileAction.notes),
            ),
            ListTile(
              leading: const Icon(Icons.save_alt),
              title: const Text('Export'),
              onTap: () => Navigator.pop(ctx, _TileAction.export),
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
    // A draft the editor finished writing after it was left (a Discard while the write was under
    // way) is listed once it lands; the editor popped without `true`, so nothing else refreshes.
    ref.listen<int>(draftLibraryWritesProvider, (_, __) => _refresh());
    // Wrap the Scaffold in the FutureBuilder so the FAB can see the load state: an EMPTY library
    // shows a centered New-draft / Import call to action in _emptyState(), so suppress the FABs
    // there to avoid offering the same two actions twice. They return once a pattern exists.
    //
    // No AppBar: this is the Weaving TAB inside HomeScreen, which owns the shared chrome (title,
    // Help, Settings). The inner Scaffold here exists only to host the FAB + body within the tab.
    return FutureBuilder<List<DraftEntry>>(
      future: _entriesFuture,
      builder: (context, snapshot) {
        final done = snapshot.connectionState == ConnectionState.done;
        final entries = snapshot.data ?? const <DraftEntry>[];
        final isEmpty = done && !snapshot.hasError && entries.isEmpty;
        return Scaffold(
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
    //
    // The tap/long-press ACTIONS live on this outer Semantics (not the InkWell) so the label and
    // the actions co-locate on ONE node — otherwise a screen reader gets a named-but-inert stop
    // plus a separate unnamed actionable stop, and the `onTapHint`/`onLongPressHint` (which need an
    // action to attach to) are silently dropped. `excludeFromSemantics` keeps the InkWell from
    // adding a duplicate action node while it still handles sighted taps AND leaves the ⋮ its node.
    return Semantics(
      // An explicit container so the label + button + tap/long-press actions form ONE node;
      // explicitChildNodes keeps the ⋮ PopupMenuButton a SEPARATE reachable child node rather than
      // merging its 'Pattern actions' label into the tile.
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
                      // Straight into the tracker at the saved place (ADR 0023).
                      PopupMenuItem(
                        value: _TileAction.track,
                        child: Text(kWeaveTrackerTitle),
                      ),
                      PopupMenuItem(
                        value: _TileAction.rename,
                        child: Text('Rename'),
                      ),
                      PopupMenuItem(
                        value: _TileAction.notes,
                        child: Text(kDraftNotesTitle),
                      ),
                      PopupMenuItem(
                        value: _TileAction.export,
                        child: Text('Export'),
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
            // The saved place (ADR 0023), when the draft has one: a way straight into the tracker.
            if (placeOf(entry.id) case final place?)
              LibraryPlaceLine(
                key: ValueKey('library-place-${entry.id}'),
                place: place,
                trackerTitle: kWeaveTrackerTitle,
                onOpen: () => _open(entry, track: true),
              ),
          ],
        ),
      ),
      ),
    );
  }

  Widget _thumb(DraftEntry entry) {
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
