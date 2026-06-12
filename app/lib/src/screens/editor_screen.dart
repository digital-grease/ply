import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/draft_doc.dart';
import '../models/draft_meta.dart';
import '../state/draft_editor_notifier.dart';
import '../state/editor_providers.dart';
import '../widgets/dimensions_bar.dart';
import '../widgets/integrated_draft_view.dart';

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

  /// True while a Treadled->Liftplan conversion is in flight (across the confirm dialog AND the FFI
  /// hop), to reject a re-entrant Convert tap and disable the button. Twin of [_saving].
  bool _converting = false;

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

  /// Convert the open treadled draft to a canonical liftplan (the engine bakes the per-pick raised
  /// shafts in, so the cloth is unchanged), committed as ONE undo entry. One-way and lossy (the
  /// tie-up + treadling are dropped), so it confirms first. Mirrors [_save]/[DimensionsBar._resize]:
  /// the FFI lives here in the widget layer; the notifier stays FFI-free.
  Future<void> _convertToLiftplan() async {
    // Serialize/re-entrancy: set synchronously BEFORE the first await so a double-tap (or a tap
    // while the dialog is open) returns immediately; the button is also disabled while converting.
    if (_converting) return;
    if (ref.read(draftEditorProvider).draft.drive is! DraftTreadled) return; // already a liftplan
    setState(() => _converting = true);
    final repo = ref.read(repositoryProvider);
    final notifier = ref.read(draftEditorProvider.notifier);
    try {
      final proceed = await _confirmConvertToLiftplan();
      if (proceed != true || !mounted) return; // cancelled (or unmounted mid-dialog)
      // Re-read post-dialog: a structural edit (e.g. a dimensions-bar resize) could have landed
      // while the modal was open, so re-check the variant before committing a stale/liftplan result.
      final cur = ref.read(draftEditorProvider).draft;
      if (cur.drive is! DraftTreadled) return;
      final next = await repo.toLiftplanDoc(cur); // the FFI hop (engine Err -> thrown -> caught)
      if (!mounted) return;
      // LATEST-WINS. The confirm dialog's modal barrier only blocks input while it is OPEN; during
      // this FFI hop the AppBar (Undo/Redo) and the dimensions bar / paint Listener are live again.
      // If any edit landed, `cur` is stale -- committing the liftplan derived from it would silently
      // overwrite that edit and wipe redo. Drop the stale result (the user can re-convert).
      // `identical` is sound: DraftDoc is immutable and the notifier only swaps whole instances.
      if (!identical(ref.read(draftEditorProvider).draft, cur)) return;
      notifier.commitEdit(next); // one undo entry; no-op if next == cur; seals any open stroke
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not convert: $e')));
      }
    } finally {
      if (mounted) setState(() => _converting = false);
    }
  }

  /// Confirm the one-way, lossy Treadled->Liftplan conversion. Returns true to proceed, false/null
  /// to cancel. Shown every time (not suppressed once-per-session like the lossy-save warning): the
  /// conversion is a rare, deliberate structural act that must not fire on a mis-tap.
  Future<bool?> _confirmConvertToLiftplan() {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Convert to liftplan?'),
        content: const Text(
          'This replaces the tie-up and treadling with a per-pick liftplan. The woven cloth stays '
          'exactly the same, but the tie-up and treadling are not kept and Ply cannot convert a '
          'liftplan back. You can still undo this right after.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Convert'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ready = !_loading && _error == null;
    // Narrow select: the AppBar only needs the two undo/redo booleans, which flip at stroke
    // boundaries, so a multi-cell drag does not rebuild the AppBar per painted cell.
    final (canUndo, canRedo) =
        ref.watch(draftEditorProvider.select((s) => (s.canUndo, s.canRedo)));
    // The convert action is only meaningful on a treadled draft (the reverse is deferred); watch
    // just the variant so it flips disabled the frame a conversion commits.
    final isTreadled =
        ref.watch(draftEditorProvider.select((s) => s.draft.drive is DraftTreadled));
    final notifier = ref.read(draftEditorProvider.notifier);
    final pencil = ref.watch(editorToolProvider) == EditorTool.pencil;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        // Seven icon actions plus the back button overflow a default AppBar on a standard phone, so
        // tighten the action buttons (the same compact density the DimensionsBar steppers use). The
        // title still ellipsizes first; this keeps every action hit-testable down to a ~360dp width.
        actions: ready
            ? [
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: pencil ? 'Pencil (tap to pan)' : 'Pan (tap to draw)',
                  isSelected: pencil,
                  onPressed: () => ref.read(editorToolProvider.notifier).state =
                      pencil ? EditorTool.hand : EditorTool.pencil,
                  icon: Icon(pencil ? Icons.draw : Icons.pan_tool_outlined),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Zoom out',
                  onPressed: () => _zoom(-1),
                  icon: const Icon(Icons.zoom_out),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Zoom in',
                  onPressed: () => _zoom(1),
                  icon: const Icon(Icons.zoom_in),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Undo',
                  onPressed: canUndo ? notifier.undo : null,
                  icon: const Icon(Icons.undo),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Redo',
                  onPressed: canRedo ? notifier.redo : null,
                  icon: const Icon(Icons.redo),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  // Disabled (not hidden) on a liftplan so the affordance stays discoverable, with
                  // a self-explaining tooltip; also disabled while a conversion is in flight.
                  tooltip: isTreadled ? 'Convert to liftplan' : 'Already a liftplan',
                  onPressed: (isTreadled && !_converting) ? _convertToLiftplan : null,
                  icon: const Icon(Icons.swap_horiz),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
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

  /// Step the on-screen cell pitch up (+1) or down (-1) through [zoomCellLevels].
  void _zoom(int dir) {
    final cur = ref.read(zoomCellProvider);
    final idx = zoomCellLevels.indexOf(cur);
    final next = ((idx < 0 ? 2 : idx) + dir).clamp(0, zoomCellLevels.length - 1);
    ref.read(zoomCellProvider.notifier).state = zoomCellLevels[next];
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
    // The dimensions bar stays below the draft (always visible) so a blank draft can be grown.
    return const Column(
      children: [
        Expanded(child: IntegratedDraftView()),
        DimensionsBar(),
      ],
    );
  }
}
