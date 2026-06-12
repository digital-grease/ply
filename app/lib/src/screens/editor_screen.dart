import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/draft_meta.dart';
import '../state/draft_editor_notifier.dart';
import '../state/editor_providers.dart';
import '../widgets/drawdown_view.dart';
import '../widgets/tieup_grid.dart';

/// The interactive weaving editor: a live drawdown and the editable tie-up grid. Tapping a
/// tie-up cell toggles it and the drawdown re-renders live (engine recompute is microseconds;
/// the preview provider is latest-wins). Undo/redo walk the snapshot history; Save persists via
/// the repository's dual path.
class EditorScreen extends ConsumerStatefulWidget {
  const EditorScreen({
    required this.wifText,
    required this.title,
    this.id,
    this.meta,
    super.key,
  });

  /// The draft's source WIF text: loaded into the editor and kept for the verbatim save path.
  final String wifText;

  /// Display title (app bar + fallback save name).
  final String title;

  /// Library id when editing a SAVED draft; null when editing an unsaved import.
  final String? id;

  /// Existing sidecar metadata for a saved draft, preserved across save.
  final DraftMeta? meta;

  @override
  ConsumerState<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends ConsumerState<EditorScreen> {
  bool _loading = true;
  String? _error;

  /// Whether the lossy-re-serialize warning has already been accepted this session, so we warn
  /// at most once (the user consents to dropping the imported WIF's extra header data once, not
  /// on every save).
  bool _warnedLossy = false;

  /// True while a save is in flight, to reject a re-entrant Save tap (and disable the button).
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final doc = await ref.read(repositoryProvider).parseDoc(widget.wifText);
      if (!mounted) return;
      ref.read(draftEditorProvider.notifier).load(doc, sourceWif: widget.wifText);
      setState(() => _loading = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not open this pattern for editing: $e';
        _loading = false;
      });
    }
  }

  Future<void> _save() async {
    // Re-entrancy guard: a fast double-tap of Save (the clean path has no modal dialog to
    // serialize it) would otherwise fire two saves and two pops, minting a duplicate library
    // entry and over-popping the route. The flag is set synchronously BEFORE the first await,
    // so the second tap's handler returns immediately; the button is also disabled while saving.
    if (_saving) return;
    setState(() => _saving = true);
    final navigator = Navigator.of(context);
    try {
      final repo = ref.read(repositoryProvider);
      final state = ref.read(draftEditorProvider);

      // Dual path. A cosmetically-clean draft saves its imported WIF BYTE-IDENTICAL (lossless).
      // A structurally-edited one is re-serialized via write_wif, which drops the WIF header's
      // thickness/spacing and any unrecognized sections. Warn (once) before that loss, but ONLY
      // when there is an imported original to lose: a from-scratch draft has no sourceWif and
      // nothing extra to drop, so it re-serializes silently.
      final reSerializing = state.dirtyStructural;
      if (reSerializing && state.sourceWif != null && !_warnedLossy) {
        final proceed = await _confirmLossySave();
        if (proceed != true || !mounted) return; // cancelled (or unmounted mid-dialog)
        _warnedLossy = true;
      }

      final messenger = ScaffoldMessenger.of(context);
      final now = DateTime.now();
      final meta = (widget.meta ??
              DraftMeta(name: widget.title, savedAt: now, lastOpened: now))
          .copyWith(lastOpened: now);
      final sourceWif = reSerializing ? null : state.sourceWif;
      await repo.saveDto(state.draft, meta: meta, id: widget.id, sourceWif: sourceWif);
      if (!mounted) return;
      messenger.showSnackBar(const SnackBar(content: Text('Saved.')));
      navigator.pop(true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not save: $e')));
      }
    } finally {
      // Re-enable if we didn't pop (cancel/error); a successful save unmounts, so skip then.
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Confirm a lossy re-serialize. Returns true to proceed, false/null to cancel.
  Future<bool?> _confirmLossySave() {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Save changes?'),
        content: const Text(
          'Saving your edits rewrites the pattern file. Yarn thickness, spacing, and any '
          'sections of the original import that Ply does not yet understand are not kept.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Save anyway'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ready = !_loading && _error == null;
    final editor = ref.watch(draftEditorProvider);
    final notifier = ref.read(draftEditorProvider.notifier);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: ready
            ? [
                IconButton(
                  tooltip: 'Undo',
                  onPressed: editor.canUndo ? notifier.undo : null,
                  icon: const Icon(Icons.undo),
                ),
                IconButton(
                  tooltip: 'Redo',
                  onPressed: editor.canRedo ? notifier.redo : null,
                  icon: const Icon(Icons.redo),
                ),
                IconButton(
                  tooltip: 'Save',
                  onPressed: _saving ? null : _save,
                  icon: const Icon(Icons.save_outlined),
                ),
              ]
            : null,
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(_error!, textAlign: TextAlign.center),
        ),
      );
    }
    return const _EditorBody();
  }
}

/// The loaded editor layout: live drawdown and the tie-up grid, side by side when wide and
/// stacked when tall.
class _EditorBody extends ConsumerWidget {
  const _EditorBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preview = ref.watch(previewProvider);
    final previewPane = Padding(
      padding: const EdgeInsets.all(16),
      child: Center(child: _Preview(preview)),
    );
    const gridPane = Padding(
      padding: EdgeInsets.all(16),
      child: Center(child: TieupGrid()),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth > constraints.maxHeight;
        return Flex(
          direction: wide ? Axis.horizontal : Axis.vertical,
          children: [
            Expanded(child: previewPane),
            const Expanded(child: gridPane),
          ],
        );
      },
    );
  }
}

class _Preview extends StatelessWidget {
  const _Preview(this.image);

  final AsyncValue<ui.Image> image;

  @override
  Widget build(BuildContext context) {
    return image.when(
      // Keep the previous frame on screen while the next render is in flight so live edits do
      // not flash a spinner. The previous ui.Image is still valid (the provider frees only
      // never-shown superseded frames eagerly).
      skipLoadingOnReload: true,
      data: DrawdownView.new,
      loading: () => const CircularProgressIndicator(),
      error: (e, _) => Padding(
        padding: const EdgeInsets.all(16),
        child: Text('Could not render this draft: $e', textAlign: TextAlign.center),
      ),
    );
  }
}
