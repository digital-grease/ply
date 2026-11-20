import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/library_backup.dart' show BackupCraft;
import '../data/progress_repository.dart' show ProgressStatus;
import '../data/tablet_repository.dart';
import '../models/draft_meta.dart';
import '../models/native_format.dart';
import '../models/progress.dart' show PickPlace;
import '../models/tablet_band.dart';
import '../print/print_export.dart' show PdfExportText;
import '../print/tablet_print.dart';
import '../rust/tablet_dto.dart';
import '../state/material_providers.dart' show openProjectProvider;
import '../state/progress_controller.dart' show progressRepositoryProvider;
import '../state/tablet_editor_providers.dart';
import '../widgets/name_input_dialog.dart';
import '../widgets/project_materials_sheet.dart';
import '../widgets/tablet_band_view.dart';
import '../widgets/tablet_checks_view.dart';
import '../widgets/tablet_setup_view.dart';
import '../widgets/tablet_turning_view.dart';
import '../widgets/tablet_widgets.dart';
import '../widgets/unsaved_changes_guard.dart';
import 'tablet_tracker_screen.dart';

enum _Menu { track, pdf, materials, settings }

/// The tablet weaving band editor (M10-02, ADR 0018): four tabs on one band, Cards (setup),
/// Turning (the turning chart), Band (the band chart and the pick-by-pick stepper) and Checks (the
/// engine's diagnostics, each a way to its place). Edits are undoable; Save writes the `.plytab` in
/// place; leaving with unsaved edits asks first, as the other editors do.
class TabletEditorScreen extends ConsumerStatefulWidget {
  const TabletEditorScreen({this.openId, this.initialDoc, this.openTracker = false, super.key});

  /// Open this saved band (by id).
  final String? openId;

  /// Or start editing this new band (from the New band dialog).
  final TabletDocumentDto? initialDoc;

  /// Open Weave pick by pick as soon as the saved band [openId] is on screen, as its menu entry does
  /// (a library tile's way to continue at the saved place, ADR 0023). Back from the tracker is this
  /// editor, its stepper at the place.
  final bool openTracker;

  @override
  ConsumerState<TabletEditorScreen> createState() => _TabletEditorScreenState();
}

class _TabletEditorScreenState extends ConsumerState<TabletEditorScreen>
    with UnsavedChangesGuard<TabletEditorScreen>, SingleTickerProviderStateMixin {
  bool _loading = true;
  String? _error;
  String? _id;
  String _name = 'Tablet weaving band';
  DateTime? _savedAt;
  bool _saving = false;
  late final TabController _tabs =
      TabController(length: TabletEditorTab.values.length, vsync: this);

  @override
  void initState() {
    super.initState();
    _tabs.addListener(() {
      if (_tabs.indexIsChanging) return;
      final tab = TabletEditorTab.values[_tabs.index];
      if (ref.read(tabletTabProvider) != tab) ref.read(tabletTabProvider.notifier).state = tab;
    });
    _load();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final repo = ref.read(tabletRepositoryProvider);
      final TabletDocumentDto doc;
      if (widget.openId != null) {
        // The id is adopted only after the file parsed, so a band that fails to open can never
        // become this session's save target.
        doc = await repo.readBand(widget.openId!);
        final entry = await repo.openBand(widget.openId!);
        if (!mounted) return;
        _id = entry.id;
        _name = entry.meta.name;
        _savedAt = entry.meta.savedAt;
      } else {
        // Yield once: initState runs during build, and Riverpod forbids changing a provider then.
        await Future<void>.delayed(Duration.zero);
        if (!mounted) return;
        doc = widget.initialDoc ?? repo.blank();
        if (doc.name.isNotEmpty) _name = doc.name;
      }
      ref.read(tabletEditorProvider.notifier).load(doc);
      ref.read(tabletTabProvider.notifier).state = TabletEditorTab.cards;
      ref.read(openProjectProvider.notifier).state = (craft: BackupCraft.tabletWeaving, id: _id);
      setState(() => _loading = false);
      _readPlace();
      if (widget.openTracker && _id != null) _openTracker();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is NativeFormatException ? e.message : 'Could not open the band: $e';
        _loading = false;
      });
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// Read the band's saved place (ADR 0023) for the stepper; nothing is shown when there is none or
  /// it cannot be read (the tracker says why). Never writes.
  Future<PickPlace?> _readPlace() async {
    final id = _id;
    PickPlace? place;
    if (id != null) {
      try {
        final load = await ref.read(progressRepositoryProvider).load(BackupCraft.tabletWeaving, id);
        if (load.status == ProgressStatus.ok && load.progress!.place is PickPlace) {
          place = load.progress!.place as PickPlace;
        }
      } catch (_) {
        // No place to show.
      }
    }
    if (!mounted) return null;
    ref.read(tabletSavedPlaceProvider.notifier).state = place;
    return place;
  }

  /// Weave the band pick by pick (ADR 0023) on the band as it is on screen. The place is kept with
  /// the saved band, so an unsaved band is asked to be saved first; the tracker never writes the
  /// band. Back in the editor, the stepper goes to the place.
  Future<void> _openTracker() async {
    final id = _id;
    if (id == null) {
      _snack('Save the band first to keep your place.');
      return;
    }
    final editor = ref.read(tabletEditorProvider);
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => TabletTrackerScreen(
        projectId: id,
        band: editor.doc,
        name: _name,
        unsavedEdits: editor.isDirty,
      ),
    ));
    final place = await _readPlace();
    if (!mounted || place == null) return;
    final total = expandedPicks(ref.read(tabletDocProvider));
    if (total > 0) ref.read(tabletPickProvider.notifier).state = place.pick.clamp(1, total);
  }

  @override
  String get unsavedChangesNoun => 'band';

  @override
  bool get hasUnsavedChanges =>
      !_loading && _error == null && ref.read(tabletEditorProvider).isDirty;

  @override
  Future<bool> performSave() async {
    // Capture once: this instance is written and becomes the saved baseline, so an edit made during
    // the write still reads as unsaved afterwards. A band with errors saves as a draft.
    final doc = ref.read(tabletEditorProvider).doc;
    var name = _name;
    if (_id == null) {
      final entered = await promptForName(context,
          title: 'Name this band',
          confirmLabel: 'Save',
          initial: doc.name.isNotEmpty ? doc.name : '',
          fieldLabel: 'Band name',
          validator: tabletTextLimit(kMaxTabletTextBytes));
      if (entered == null) return false;
      name = entered;
    }
    if (!mounted) return false;
    setState(() => _saving = true);
    try {
      final repo = ref.read(tabletRepositoryProvider);
      final now = DateTime.now();
      final meta =
          DraftMeta(name: name, craft: kTabletCraft, savedAt: _savedAt ?? now, lastOpened: now);
      final id = await repo.saveBand(doc: doc, meta: meta, id: _id);
      if (!mounted) return true;
      ref.read(tabletEditorProvider.notifier).markSaved(doc);
      ref.read(openProjectProvider.notifier).state = (craft: BackupCraft.tabletWeaving, id: id);
      setState(() {
        _id = id;
        _name = name;
        _savedAt ??= now;
        _saving = false;
      });
      _snack('Saved to your tablet weaving bands.');
      return true;
    } on NativeFormatException catch (e) {
      // The file on disk must not be replaced (a newer Ply's, say): the next Save makes a new band.
      if (!mounted) return false;
      setState(() {
        _id = null;
        _saving = false;
      });
      _snack('${e.message} Save again to keep your changes as a new band.');
      return false;
    } catch (e) {
      if (!mounted) return false;
      setState(() => _saving = false);
      _snack('Could not save: $e');
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final canUndo = ref.watch(tabletEditorProvider.select((s) => s.canUndo));
    final canRedo = ref.watch(tabletEditorProvider.select((s) => s.canRedo));
    final edited = ref.watch(tabletEditorProvider.select((s) => s.isDirty));
    final offerMaterials =
        ref.watch(offerProjectMaterialsProvider((craft: BackupCraft.tabletWeaving, id: _id)));
    ref.listen<TabletEditorTab>(tabletTabProvider, (_, tab) {
      if (_tabs.index != tab.index) _tabs.animateTo(tab.index);
    });
    final ready = !_loading && _error == null;
    return PopScope<Object?>(
      canPop: !ready || !edited,
      onPopInvokedWithResult: onLeaveRequested,
      child: Scaffold(
        appBar: AppBar(
          title: Text(_name),
          actions: [
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: 'Save',
              icon: _saving
                  ? const SizedBox(
                      width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.save_outlined),
              onPressed: _saving || !ready ? null : guardedSave,
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: 'Undo',
              icon: const Icon(Icons.undo),
              onPressed:
                  ready && canUndo ? () => ref.read(tabletEditorProvider.notifier).undo() : null,
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: 'Redo',
              icon: const Icon(Icons.redo),
              onPressed:
                  ready && canRedo ? () => ref.read(tabletEditorProvider.notifier).redo() : null,
            ),
            PopupMenuButton<_Menu>(
              tooltip: 'More',
              onSelected: (m) => switch (m) {
                _Menu.track => _openTracker(),
                _Menu.pdf => printOrShareTabletPdf(context, ref, name: _name),
                _Menu.materials =>
                  showProjectMaterials(context, craft: BackupCraft.tabletWeaving, id: _id),
                _Menu.settings => showBandSettings(context, ref),
              },
              itemBuilder: (_) => [
                // Weave the band pick by pick, keeping your place (ADR 0023): a saved band only,
                // since the place is kept with the saved band.
                PopupMenuItem(
                  value: _Menu.track,
                  enabled: ready,
                  child: const ListTile(
                    leading: Icon(Icons.playlist_play),
                    title: Text('$kTabletTrackerTitle…'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                PopupMenuItem(
                  value: _Menu.pdf,
                  enabled: ready,
                  child: const ListTile(
                    leading: Icon(Icons.print_outlined),
                    title: Text(PdfExportText.action),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                if (offerMaterials)
                  const PopupMenuItem(
                    value: _Menu.materials,
                    child: ListTile(
                      leading: Icon(Icons.inventory_2_outlined),
                      title: Text('$kProjectMaterialsTitle...'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                PopupMenuItem(
                  value: _Menu.settings,
                  enabled: ready,
                  child: const ListTile(
                    leading: Icon(Icons.tune),
                    title: Text('Band settings'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ],
            ),
          ],
          bottom: ready
              ? TabBar(
                  controller: _tabs,
                  isScrollable: true,
                  tabAlignment: TabAlignment.center,
                  tabs: const [
                    Tab(text: 'Cards'),
                    Tab(text: 'Turning'),
                    Tab(text: 'Band'),
                    Tab(child: _ChecksTabLabel(key: ValueKey('tablet-checks-tab'))),
                  ],
                )
              : null,
        ),
        body: _body(),
      ),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
            padding: const EdgeInsets.all(32), child: Text(_error!, textAlign: TextAlign.center)),
      );
    }
    return TabBarView(
      controller: _tabs,
      // The charts scroll sideways; tabs change by tapping them, never by a stray swipe.
      physics: const NeverScrollableScrollPhysics(),
      children: const [
        TabletSetupView(),
        TabletTurningView(),
        TabletBandView(),
        TabletChecksView(),
      ],
    );
  }
}

/// "Checks", with the count of errors, warnings and things not modelled once known.
class _ChecksTabLabel extends ConsumerWidget {
  const _ChecksTabLabel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = ref.watch(tabletReportProvider).valueOrNull;
    final n = r == null ? 0 : r.errors + r.warnings + r.unsupported;
    if (r == null || n == 0) return const Text('Checks');
    final errors = r.errors > 0;
    return Semantics(
      label: 'Checks, $n to look at${errors ? ', with errors' : ''}',
      child: ExcludeSemantics(
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Text('Checks'),
          const SizedBox(width: 6),
          Badge(
            label: Text('$n'),
            backgroundColor: errors ? Theme.of(context).colorScheme.error : null,
          ),
        ]),
      ),
    );
  }
}

/// The band's notes, weft and warning thresholds.
Future<void> showBandSettings(BuildContext context, WidgetRef ref) async {
  final doc = ref.read(tabletDocProvider);
  final notes = TextEditingController(text: doc.notes);
  final twist = TextEditingController(text: '${doc.settings.twistWarningQuarters}');
  final float = TextEditingController(text: '${doc.settings.floatWarningPicks}');
  int? weft = doc.weft;
  final saved = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        // A threshold is a whole number from 0 to the pick limit: nothing larger reaches the
        // engine, whose thresholds are 32-bit.
        String? limit(String text) {
          final v = int.tryParse(text.trim());
          if (v == null || v < 0) return 'A whole number, 0 or more.';
          if (v > kMaxTabletThreshold) return 'At most 200,000 (Ply\'s pick limit).';
          return null;
        }

        final twistError = limit(twist.text), floatError = limit(float.text);
        final numbers = [
          FilteringTextInputFormatter.digitsOnly,
          LengthLimitingTextInputFormatter(9),
        ];
        return AlertDialog(
          title: const Text('Band settings'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                controller: notes,
                maxLines: 4,
                inputFormatters: [Utf8ByteLimit(kMaxTabletNotesBytes)],
                decoration: const InputDecoration(labelText: 'Notes'),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<int?>(
                initialValue: weft != null && weft! < doc.palette.length ? weft : null,
                decoration: const InputDecoration(
                  labelText: 'Weft colour',
                  helperText: 'Recorded and printed; the band chart does not draw the weft.',
                ),
                items: [
                  const DropdownMenuItem(value: null, child: Text('Not recorded')),
                  for (var i = 0; i < doc.palette.length; i++)
                    DropdownMenuItem(value: i, child: Text('Colour ${i + 1}')),
                ],
                onChanged: (v) => setState(() => weft = v),
              ),
              const SizedBox(height: 8),
              TextField(
                key: const ValueKey('tablet-twist-threshold'),
                controller: twist,
                keyboardType: TextInputType.number,
                inputFormatters: numbers,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: 'Warn when twist passes',
                  suffixText: 'quarter turns',
                  helperText: 'Ply\'s starting value is 32 (8 full turns), a heuristic.',
                  errorText: twistError,
                ),
              ),
              TextField(
                key: const ValueKey('tablet-float-threshold'),
                controller: float,
                keyboardType: TextInputType.number,
                inputFormatters: numbers,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: 'Warn about floats longer than',
                  suffixText: 'picks',
                  helperText: 'Ply\'s starting value is 3.',
                  errorText: floatError,
                ),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(
              onPressed:
                  twistError == null && floatError == null ? () => Navigator.pop(ctx, true) : null,
              child: const Text('Apply'),
            ),
          ],
        );
      },
    ),
  );
  if (saved == true) {
    final t = int.tryParse(twist.text.trim());
    final f = int.tryParse(float.text.trim());
    ref.read(tabletEditorProvider.notifier).edit((d) {
      var next = copyDoc(d, notes: notes.text, weft: weft, clearWeft: weft == null);
      next = setSettings(
        next,
        TabletSettingsDto(
          twistWarningQuarters: t != null && t >= 0 ? t : d.settings.twistWarningQuarters,
          floatWarningPicks: f != null && f >= 0 ? f : d.settings.floatWarningPicks,
        ),
      );
      final unchanged = next.notes == d.notes &&
          next.weft == d.weft &&
          next.settings.twistWarningQuarters == d.settings.twistWarningQuarters &&
          next.settings.floatWarningPicks == d.settings.floatWarningPicks;
      return unchanged ? d : next;
    });
  }
  // The controllers are not disposed here: the dialog's closing animation still shows the fields
  // after it returns. They hold no native resource, so the collector takes them with the dialog.
}
