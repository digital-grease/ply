import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/library_backup.dart';
import '../models/app_settings.dart';
import '../models/draft_doc.dart' show MeasureUnit;
import '../state/backup_providers.dart';
import '../state/loom_providers.dart';
import '../state/material_providers.dart';
import '../state/nalbind_providers.dart';
import '../theme/spacing.dart';

/// The restore preview: what a checked backup (or single-project export) holds, grouped by craft
/// into new projects, projects that differ from the library (restored as copies unless unticked),
/// projects already in the library (skipped) and projects this build cannot restore (with the
/// reason), then the backup's looms (new ones added, different ones offered as copies, ticked by
/// default; ADR 0014), then its materials and swatches (the same way; ADR 0016), then the backup's
/// app settings when it has them: their own item, unticked by
/// default, applied only when ticked (or refused with the reason). Nothing is written until
/// "Restore" is tapped. Pops with the [RestoreResult] after a successful restore.
class RestorePreviewScreen extends ConsumerStatefulWidget {
  const RestorePreviewScreen({required this.plan, super.key});

  final RestorePlan plan;

  @override
  ConsumerState<RestorePreviewScreen> createState() => _RestorePreviewScreenState();
}

class _RestorePreviewScreenState extends ConsumerState<RestorePreviewScreen> {
  /// Keys of the conflicts the user unticked.
  final Set<String> _skipped = {};

  /// Keys of the loom conflicts the user unticked.
  final Set<String> _skippedLooms = {};

  /// Keys of the material and swatch conflicts the user unticked.
  final Set<String> _skippedRecords = {};

  /// Whether to apply the backup's app settings (never by default: they replace the user's own).
  bool _restoreSettings = false;
  bool _busy = false;

  RestorePlan get _plan => widget.plan;

  int get _toRestore => _plan.projects
      .where((p) =>
          p.status == RestoreStatus.add ||
          (p.status == RestoreStatus.conflict && !_skipped.contains(p.key)))
      .length;

  int get _loomsToRestore => _plan.looms?.selected(_skippedLooms).length ?? 0;

  ({int materials, int swatches}) get _recordsToRestore {
    final m = _plan.materials;
    if (m == null || m.limitProblem(_skippedRecords) != null) return (materials: 0, swatches: 0);
    final sel = m.selected(_skippedRecords);
    return (materials: sel.materials.length, swatches: sel.swatches.length);
  }

  Future<void> _restore() async {
    setState(() => _busy = true);
    try {
      final result = await ref.read(libraryBackupProvider).restore(_plan,
          skippedConflicts: {..._skipped},
          restoreSettings: _restoreSettings,
          skippedLoomConflicts: {..._skippedLooms},
          skippedMaterialConflicts: {..._skippedRecords});
      // Every library tab reloads its list, and My looms its looms.
      ref.read(libraryRevisionProvider.notifier).state++;
      ref.invalidate(nalbindProjectsProvider);
      if (result.loomsRestored > 0) ref.invalidate(loomLibraryProvider);
      if (result.materialsRestored > 0 || result.swatchesRestored > 0) {
        ref.invalidate(materialLibraryProvider);
      }
      ref.invalidate(linkUsageProvider);
      if (mounted) Navigator.of(context).pop(result);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      final message = e is BackupException
          ? e.message
          : const BackupException(BackupProblem.restoreFailed).message;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Restore failed'),
          content: Text(message),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('OK')),
          ],
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final count = _toRestore;
    final looms = _loomsToRestore;
    final records = _recordsToRestore;
    final settings = _restoreSettings && _plan.settings?.settings != null;
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(title: const Text('Restore backup')),
        body: ListView(
          padding: const EdgeInsets.only(bottom: PlySpacing.lg),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  PlySpacing.md, PlySpacing.md, PlySpacing.md, PlySpacing.xs),
              child: Text(
                  'Backup made ${_formatDate(_plan.createdAt)} with Ply ${_plan.appVersion}.'),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: PlySpacing.md),
              child: Text('Nothing in your library is replaced.', style: muted),
            ),
            if (_plan.projects.isEmpty)
              Padding(
                padding: const EdgeInsets.all(PlySpacing.md),
                child: Text('This backup has no projects.', style: muted),
              ),
            for (final craft in BackupCraft.values) ..._craftSection(craft, muted),
            ..._loomsSection(muted),
            ..._materialsSection(muted),
            ..._settingsSection(),
          ],
        ),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(PlySpacing.md),
            child: FilledButton(
              onPressed: ((count > 0 ||
                          looms > 0 ||
                          records.materials > 0 ||
                          records.swatches > 0 ||
                          settings) &&
                      !_busy)
                  ? _restore
                  : null,
              child: _busy
                  ? const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox.square(
                            dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                        SizedBox(width: PlySpacing.sm),
                        Text('Restoring...'),
                      ],
                    )
                  : Text(_restoreLabel(count,
                      settings: settings,
                      looms: looms,
                      materials: records.materials,
                      swatches: records.swatches)),
            ),
          ),
        ),
      ),
    );
  }

  /// A project's lines under its name in the preview, one a line; none when there are none.
  static Widget? _projectNotes(List<String> lines) => lines.isEmpty ? null : Text(lines.join('\n'));

  List<Widget> _craftSection(BackupCraft craft, TextStyle? muted) {
    final added = _plan.forCraft(craft, RestoreStatus.add);
    final conflicts = _plan.forCraft(craft, RestoreStatus.conflict);
    final present = _plan.forCraft(craft, RestoreStatus.alreadyPresent);
    final refused = _plan.forCraft(craft, RestoreStatus.refused);
    if (added.isEmpty && conflicts.isEmpty && present.isEmpty && refused.isEmpty) return const [];
    final theme = Theme.of(context);
    return [
      const Divider(height: PlySpacing.lg),
      _sectionHeader(craft.label),
      if (added.isNotEmpty) ...[
        _groupHeader('New (${added.length})'),
        for (final p in added)
          ListTile(
            dense: true,
            title: Text(p.name),
            subtitle: _projectNotes([
              if (p.photoCount > 0) plural(p.photoCount, 'photo'),
              if (p.progressLeftOut) RestoreProject.progressLeftOutText,
            ]),
          ),
      ],
      if (conflicts.isNotEmpty) ...[
        _groupHeader('Different from your library (${conflicts.length})'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: PlySpacing.md),
          child: Text('Ticked projects are added as copies. Your projects are not changed.',
              style: muted),
        ),
        for (final p in conflicts)
          CheckboxListTile(
            dense: true,
            value: !_skipped.contains(p.key),
            onChanged: _busy
                ? null
                : (on) => setState(() => on == true ? _skipped.remove(p.key) : _skipped.add(p.key)),
            title: Text(p.name),
            subtitle: _projectNotes([
              'Restore as "${p.targetName}"',
              if (p.progressLeftOut) RestoreProject.progressLeftOutText,
            ]),
          ),
      ],
      if (present.isNotEmpty) ...[
        _groupHeader('Already in your library (${present.length})'),
        for (final p in present)
          ListTile(dense: true, title: Text(p.name), subtitle: const Text('Skipped')),
      ],
      if (refused.isNotEmpty) ...[
        _groupHeader('Cannot restore (${refused.length})'),
        for (final p in refused)
          ListTile(
            dense: true,
            leading: Icon(Icons.error_outline, color: theme.colorScheme.error),
            title: Text(p.name),
            subtitle: Text(p.refusal?.message ?? ''),
          ),
      ],
    ];
  }

  /// The backup's looms, after the projects: new ones (added), different ones (added as copies when
  /// ticked, the default), ones already in My looms (skipped), or the reason they cannot be restored.
  /// Nothing when the backup has none.
  List<Widget> _loomsSection(TextStyle? muted) {
    final l = _plan.looms;
    if (l == null) return const [];
    final theme = Theme.of(context);
    final added = l.withStatus(RestoreStatus.add);
    final conflicts = l.withStatus(RestoreStatus.conflict);
    final present = l.withStatus(RestoreStatus.alreadyPresent);
    return [
      const Divider(height: PlySpacing.lg),
      _sectionHeader('My looms'),
      if (l.refusal != null)
        ListTile(
          dense: true,
          leading: Icon(Icons.error_outline, color: theme.colorScheme.error),
          title: Text(l.refusal!),
        ),
      if (added.isNotEmpty) ...[
        _groupHeader('New (${added.length})'),
        for (final i in added)
          ListTile(dense: true, title: Text(i.loom.displayName), subtitle: Text(i.loom.summary)),
      ],
      if (conflicts.isNotEmpty) ...[
        _groupHeader('Different from My looms (${conflicts.length})'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: PlySpacing.md),
          child: Text('Ticked looms are added as copies. Your looms are not changed.', style: muted),
        ),
        for (final i in conflicts)
          CheckboxListTile(
            dense: true,
            value: !_skippedLooms.contains(i.key),
            onChanged: _busy
                ? null
                : (on) => setState(
                    () => on == true ? _skippedLooms.remove(i.key) : _skippedLooms.add(i.key)),
            title: Text(i.loom.displayName),
            subtitle: Text(_loomSubtitle(i)),
          ),
      ],
      if (present.isNotEmpty) ...[
        _groupHeader('Already in My looms (${present.length})'),
        for (final i in present)
          ListTile(dense: true, title: Text(i.loom.displayName), subtitle: const Text('Skipped')),
      ],
    ];
  }

  /// The backup's materials and swatches, after the looms: new ones (added), different ones (added
  /// as copies when ticked, the default), ones already in the library (skipped), or the reason they
  /// cannot be restored. Nothing when the backup has none.
  List<Widget> _materialsSection(TextStyle? muted) {
    final m = _plan.materials;
    if (m == null) return const [];
    final theme = Theme.of(context);
    String photos(RestoreRecord r) => r.photoCount == 0 ? '' : ', ${plural(r.photoCount, 'photo')}';
    String uses(RestoreRecord r) => r.projects == 0
        ? ''
        : '. ${r.projects == 1 ? 'The project' : '${r.projects} projects'} from this backup that '
            'use${r.projects == 1 ? 's' : ''} it will use the copy.';
    // Unticked: the restored projects (and swatches) keep naming the record by its id, which here is
    // a different record of yours, or none.
    String yours(RestoreRecord r) =>
        r.localName == null ? 'it as not in your materials' : 'your own "${r.localName}"';
    String unticked(RestoreRecord r) {
      final projects = r.projects == 1 ? 'The project' : '${r.projects} projects';
      final swatches = r.swatchesNaming == 1 ? 'The swatch' : '${r.swatchesNaming} swatches';
      final none = r.localName == null;
      return 'Not added.'
          '${r.projects == 0 ? '' : ' $projects from this backup that use'
              '${r.projects == 1 ? 's' : ''} it will ${none ? 'show' : 'use'} ${yours(r)}.'}'
          '${r.swatchesNaming == 0 ? '' : ' $swatches from this backup that name'
              '${r.swatchesNaming == 1 ? 's' : ''} it will ${none ? 'show' : 'name'} ${yours(r)}.'}';
    }
    List<Widget> group(bool swatches) {
      final added = m.withStatus(RestoreStatus.add, swatches: swatches);
      final conflicts = m.withStatus(RestoreStatus.conflict, swatches: swatches);
      final present = m.withStatus(RestoreStatus.alreadyPresent, swatches: swatches);
      final noun = swatches ? 'swatches' : 'materials';
      String count(int n) =>
          swatches ? plural(n, 'swatch', 'swatches') : plural(n, 'material');
      return [
        if (added.isNotEmpty) ...[
          _groupHeader('New $noun (${added.length})'),
          for (final i in added)
            ListTile(dense: true, title: Text(i.name), subtitle: Text('${i.summary}${photos(i)}')),
        ],
        if (conflicts.isNotEmpty) ...[
          _groupHeader('Different from yours (${count(conflicts.length)})'),
          for (final i in conflicts)
            CheckboxListTile(
              dense: true,
              value: !_skippedRecords.contains(i.key),
              onChanged: _busy
                  ? null
                  : (on) => setState(() =>
                      on == true ? _skippedRecords.remove(i.key) : _skippedRecords.add(i.key)),
              title: Text(i.name),
              subtitle: Text(_skippedRecords.contains(i.key)
                  ? unticked(i)
                  : 'Add as "${i.copyName}"${photos(i)}${uses(i)}'),
            ),
        ],
        if (present.isNotEmpty) ...[
          _groupHeader('Already in your materials (${count(present.length)})'),
          for (final i in present)
            ListTile(dense: true, title: Text(i.name), subtitle: const Text('Skipped')),
        ],
      ];
    }

    return [
      const Divider(height: PlySpacing.lg),
      _sectionHeader('Materials and swatches'),
      if (m.refusal != null)
        ListTile(
          dense: true,
          leading: Icon(Icons.error_outline, color: theme.colorScheme.error),
          title: Text(m.refusal!),
        ),
      if (m.limitProblem(_skippedRecords) != null)
        ListTile(
          dense: true,
          leading: Icon(Icons.error_outline, color: theme.colorScheme.error),
          title: Text(m.limitProblem(_skippedRecords)!),
        ),
      if (m.items.any((i) => i.status == RestoreStatus.conflict))
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: PlySpacing.md),
          child: Text('Ticked records are added as copies. Yours are not changed.', style: muted),
        ),
      ...group(false),
      ...group(true),
    ];
  }

  /// What happens to a different loom: added as a copy the backup's drafts use, or (unticked) not
  /// added, and then the drafts keep naming the loom by its id, which is a different loom of yours.
  String _loomSubtitle(RestoreLoom i) {
    final drafts = i.drafts == 1 ? 'The draft' : '${i.drafts} drafts';
    if (_skippedLooms.contains(i.key)) {
      final which =
          i.localName == null ? 'a loom not in My looms' : 'your own "${i.localName}"';
      return 'Not added.'
          '${i.drafts == 0 ? '' : ' $drafts from this backup planned for it will be planned for '
              '$which.'}';
    }
    return 'Add as "${i.target!.displayName}"'
        '${i.drafts == 0 ? '' : '. $drafts from this backup planned for it will use the copy.'}';
  }

  /// The backup's app settings, after the projects: a tickable item (off by default) describing
  /// them, or the reason they cannot be restored. Nothing when the backup has none.
  List<Widget> _settingsSection() {
    final s = _plan.settings;
    if (s == null) return const [];
    final theme = Theme.of(context);
    final value = s.settings;
    return [
      const Divider(height: PlySpacing.lg),
      _sectionHeader('App settings'),
      if (value != null)
        CheckboxListTile(
          dense: true,
          value: _restoreSettings,
          onChanged: _busy ? null : (on) => setState(() => _restoreSettings = on == true),
          title: const Text('Restore app settings'),
          subtitle: Text('${describeSettings(value)} Replaces your current settings.'),
          secondary: ExcludeSemantics(child: _AccentDot(color: Color(value.accentSeed))),
        )
      else
        ListTile(
          dense: true,
          leading: Icon(Icons.error_outline, color: theme.colorScheme.error),
          title: Text(s.refusal ?? RestoreSettings.unreadable),
        ),
    ];
  }

  Widget _sectionHeader(String text) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(PlySpacing.md, 0, PlySpacing.md, PlySpacing.xs),
      child: Semantics(
        header: true,
        child: Text(text,
            style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary)),
      ),
    );
  }

  static String _restoreLabel(int count,
      {required bool settings, int looms = 0, int materials = 0, int swatches = 0}) {
    final parts = [
      if (count > 0) plural(count, 'project'),
      if (looms > 0) plural(looms, 'loom'),
      if (materials > 0) plural(materials, 'material'),
      if (swatches > 0) plural(swatches, 'swatch', 'swatches'),
      if (settings) 'app settings',
    ];
    return parts.isEmpty ? 'Nothing to restore' : 'Restore ${_andList(parts)}';
  }

  Widget _groupHeader(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(
            PlySpacing.md, PlySpacing.sm, PlySpacing.md, PlySpacing.xs),
        child: Text(text, style: Theme.of(context).textTheme.labelLarge),
      );

  static String _formatDate(DateTime when) {
    final d = when.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }
}

/// "1 project", "3 projects" ("1 swatch", "2 swatches" with [many]).
String plural(int n, String noun, [String? many]) =>
    n == 1 ? '$n $noun' : '$n ${many ?? '${noun}s'}';

/// The sentence after a restore ("Restored 2 projects and app settings.", "Restored 2 projects, 1
/// loom and app settings."), or null when it wrote nothing.
String? restoredMessage(RestoreResult result) {
  final parts = [
    if (result.count > 0) plural(result.count, 'project'),
    if (result.loomsRestored > 0) plural(result.loomsRestored, 'loom'),
    if (result.materialsRestored > 0) plural(result.materialsRestored, 'material'),
    if (result.swatchesRestored > 0) plural(result.swatchesRestored, 'swatch', 'swatches'),
    if (result.settingsRestored) 'app settings',
  ];
  if (parts.isEmpty) return null;
  final relinked = result.draftsRelinked;
  final materialLinks = result.projectsRelinkedToMaterials;
  return 'Restored ${_andList(parts)}.'
      '${relinked == 0 ? '' : ' ${plural(relinked, 'draft')} now use${relinked == 1 ? 's' : ''} the '
          'restored copy of ${relinked == 1 ? 'its' : 'their'} loom.'}'
      '${materialLinks == 0 ? '' : ' ${plural(materialLinks, 'project')} now link'
          '${materialLinks == 1 ? 's' : ''} the restored copies of '
          '${materialLinks == 1 ? 'its' : 'their'} materials or swatches.'}';
}

/// "a", "a and b", "a, b and c".
String _andList(List<String> parts) => parts.length <= 1
    ? parts.join()
    : '${parts.sublist(0, parts.length - 1).join(', ')} and ${parts.last}';

/// Backed-up app settings in words, for the restore preview: "Dark theme, Material You off, metric
/// units." (the accent color is shown as a swatch beside it).
String describeSettings(AppSettings settings) {
  final theme = switch (settings.themeMode) {
    ThemeMode.system => 'System',
    ThemeMode.light => 'Light',
    ThemeMode.dark => 'Dark',
  };
  final units = switch (settings.unit) {
    MeasureUnit.inches => 'imperial',
    MeasureUnit.centimeters => 'metric',
  };
  return '$theme theme, Material You ${settings.useDynamicColor ? 'on' : 'off'}, $units units.';
}

/// A small swatch of the backed-up accent color (decorative; the text describes the rest).
class _AccentDot extends StatelessWidget {
  const _AccentDot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        width: 24,
        height: 24,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: Theme.of(context).colorScheme.outline),
        ),
      );
}
