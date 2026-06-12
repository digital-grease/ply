import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/draft_doc.dart';
import '../models/draft_issue.dart';
import '../models/draft_meta.dart';
import '../state/draft_editor_notifier.dart';
import '../state/editor_providers.dart';
import '../widgets/dimensions_bar.dart';
import '../widgets/integrated_draft_view.dart';
import '../widgets/save_draft_dialog.dart';
import '../widgets/validation_panel.dart';

/// The interactive weaving editor: a live drawdown and the editable tie-up grid. Tapping a
/// tie-up cell toggles it and the drawdown re-renders live (engine recompute is microseconds;
/// the preview provider is latest-wins). Undo/redo walk the snapshot history; Save persists via
/// the repository's dual path.
class EditorScreen extends ConsumerStatefulWidget {
  const EditorScreen({
    this.wifText,
    this.initialDoc,
    required this.title,
    this.id,
    this.meta,
    super.key,
  }) : assert((wifText == null) != (initialDoc == null),
            'provide exactly one of wifText (import/open) or initialDoc (new draft)');

  /// The draft's source WIF text: parsed into the editor and kept for the verbatim save path.
  /// Mutually exclusive with [initialDoc].
  final String? wifText;

  /// A from-scratch draft to open DIRECTLY (the Library "New draft" path), bypassing WIF parsing.
  /// Such a draft has no original WIF, so its `sourceWif` stays null (it always re-serializes on
  /// save) and its `meta` is null until the first save prompts for it. Mutually exclusive with
  /// [wifText].
  final DraftDoc? initialDoc;

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
      // A new draft opens its in-memory doc directly (no WIF, no source); an import/open parses its
      // WIF text and keeps it for the verbatim save path. Either way the provider writes below must
      // land AFTER the first build — the WIF path defers via the parse await; the in-memory path
      // yields a microtask so it never modifies a provider during initState.
      final DraftDoc doc;
      final String? source;
      if (widget.initialDoc != null) {
        doc = widget.initialDoc!;
        source = null;
        await Future<void>.microtask(() {});
      } else {
        doc = await ref.read(repositoryProvider).parseDoc(widget.wifText!);
        source = widget.wifText;
      }
      if (!mounted) return;
      ref.read(draftEditorProvider.notifier).load(doc, sourceWif: source);
      // Reset the inline-panel chrome for this fresh editor session: editorIssuesExpandedProvider is
      // a global StateProvider, so a previous draft's "Show me"/expanded state would otherwise bleed
      // into this one.
      ref.read(editorIssuesExpandedProvider.notifier).state = false;
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
      // Capture ONCE: this exact draft instance is the one we validate AND persist, so "what was
      // checked" can never diverge from "what was saved".
      final state = ref.read(draftEditorProvider);

      // GATE 0 — non-empty cloth. A from-scratch draft starts 0x0 (the editor shows a placeholder
      // until it's grown via the dimensions bar). An empty draft validates clean but isn't a
      // meaningful library entry, and its 0-area drawdown can't be rendered into a thumbnail. Refuse
      // rather than persist a degenerate cloth. (The repo's decode also fails fast on 0-area as a
      // backstop, but blocking here gives the weaver a clear reason instead of a swallowed save.)
      if (state.draft.ends == 0 || state.draft.picks == 0) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Add at least one end and one pick before saving.')));
        return;
      }

      // GATE 1 — structural Errors (correctness). Re-validate the EXACT draft fresh rather than
      // reading the async [validationProvider] (which may be stale/in-flight at the tap), so an Error
      // from the most recent edit can't be missed. Fail-CLOSED: if the check itself fails, refuse to
      // save rather than risk persisting a mis-rendering cloth. Warnings never gate (advisory only).
      final List<DraftIssue> issues;
      try {
        issues = await repo.validateDto(state.draft);
      } catch (_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Could not check the pattern for problems; not saved.')));
        return;
      }
      if (!mounted) return;
      final errorCount = issues.where((i) => i.isError).length;
      if (errorCount > 0) {
        final proceed = await _confirmSaveWithErrors(errorCount);
        // Cancel, "Show me" (which expands the panel), or unmounted -> abort before any write. The
        // lossy gate below is never reached, and _warnedLossy stays untouched.
        if (proceed != true || !mounted) return;
      }

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

      // LATEST-WINS (mirrors _convertToLiftplan / DimensionsBar._resize). An edit can land during the
      // gate's validate FFI hop — the canvas + dimensions bar stay live until a modal opens, and
      // _saving disables only the Save button — making the captured `state` stale. Persisting it
      // would drop that edit AND could pick the wrong save path (its dirtyStructural/sourceWif are
      // from the stale snapshot). Bail so the user re-saves on the current draft.
      if (!mounted || !identical(ref.read(draftEditorProvider).draft, state.draft)) return;

      // METADATA. A saved/imported draft reuses its existing sidecar meta (overwrite in place); a
      // from-scratch draft (no meta) prompts for name/author/notes on its FIRST save — that names the
      // new library entry. Cancelling the prompt aborts the save. (The prompt is a modal, so no edit
      // can land between the latest-wins check above and the persist below.)
      final DraftMeta meta;
      // The doc to persist. A from-scratch draft adopts the prompt name into the document itself
      // (below), so its WIF carries a [TEXT] Title matching the sidecar — without that, write_wif
      // would emit no name and a reopen would default to "Untitled". An edit keeps its doc as-is.
      var docToSave = state.draft;
      if (widget.meta != null) {
        meta = widget.meta!.copyWith(lastOpened: DateTime.now());
      } else {
        final input = await showSaveDraftDialog(context, initialName: widget.title);
        if (input == null || !mounted) return; // cancelled the name prompt
        final now = DateTime.now();
        meta = DraftMeta(
          name: input.name,
          craft: 'Weaving',
          author: input.author,
          notes: input.notes,
          savedAt: now,
          lastOpened: now,
        );
        docToSave = state.draft.copyWith(name: input.name);
      }
      final messenger = ScaffoldMessenger.of(context);
      final sourceWif = reSerializing ? null : state.sourceWif;
      await repo.saveDto(docToSave, meta: meta, id: widget.id, sourceWif: sourceWif);
      if (!mounted) return;
      // Feedback ONCE. An edit pops back to the preview (which shows nothing), so the editor owns the
      // confirmation. A from-scratch draft (meta == null) pops to the Library, which shows its own
      // "Saved to library." — staying silent here avoids a double toast and matches the import path.
      if (widget.meta != null) {
        messenger.showSnackBar(const SnackBar(content: Text('Saved.')));
      }
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

  /// Confirm saving a draft that has structural Errors (it will render incorrectly). Returns true to
  /// proceed. "Show me" expands the inline validation panel and ABORTS the save (returns false) so
  /// the user can read which problems they're consenting to. Shown every save (the error set changes
  /// as the user edits, and the consequence is severe), never suppressed once-per-session.
  Future<bool?> _confirmSaveWithErrors(int count) {
    final problems = count == 1 ? '1 problem' : '$count problems';
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Save with problems?'),
        content: Text(
          'This pattern has $problems that make it render incorrectly (some threads show as '
          'blank). You can fix them first, or save anyway.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              // Open the panel to the full issue list, then abort the save so the user reads them.
              ref.read(editorIssuesExpandedProvider.notifier).state = true;
              Navigator.pop(ctx, false);
            },
            child: const Text('Show me'),
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
    // The validation band sits between the draft and the (always-visible) dimensions bar, with
    // INTRINSIC height: it shrinks the drawdown viewport only when there are issues, and is zero
    // chrome otherwise.
    return const Column(
      children: [
        Expanded(child: IntegratedDraftView()),
        ValidationPanel(),
        DimensionsBar(),
      ],
    );
  }
}
