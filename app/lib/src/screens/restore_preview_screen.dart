import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/library_backup.dart';
import '../models/app_settings.dart';
import '../models/draft_doc.dart' show MeasureUnit;
import '../state/backup_providers.dart';
import '../state/loom_providers.dart';
import '../state/nalbind_providers.dart';
import '../theme/spacing.dart';

/// The restore preview: what a checked backup (or single-project export) holds, grouped by craft
/// into new projects, projects that differ from the library (restored as copies unless unticked),
/// projects already in the library (skipped) and projects this build cannot restore (with the
/// reason), then the backup's looms (new ones added, different ones offered as copies, ticked by
/// default; ADR 0014), then the backup's app settings when it has them: their own item, unticked by
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

  Future<void> _restore() async {
    setState(() => _busy = true);
    try {
      final result = await ref.read(libraryBackupProvider).restore(_plan,
          skippedConflicts: {..._skipped},
          restoreSettings: _restoreSettings,
          skippedLoomConflicts: {..._skippedLooms});
      // Every library tab reloads its list, and My looms its looms.
      ref.read(libraryRevisionProvider.notifier).state++;
      ref.invalidate(nalbindProjectsProvider);
      if (result.loomsRestored > 0) ref.invalidate(loomLibraryProvider);
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
            ..._settingsSection(),
          ],
        ),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(PlySpacing.md),
            child: FilledButton(
              onPressed: ((count > 0 || looms > 0 || settings) && !_busy) ? _restore : null,
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
                  : Text(_restoreLabel(count, settings: settings, looms: looms)),
            ),
          ),
        ),
      ),
    );
  }

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
            subtitle: p.photoCount > 0 ? Text(plural(p.photoCount, 'photo')) : null,
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
            subtitle: Text('Restore as "${p.targetName}"'),
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
            subtitle: Text('Add as "${i.target!.displayName}"'
                '${i.drafts == 0 ? '' : '. ${i.drafts == 1 ? 'The draft' : '${i.drafts} drafts'} '
                    'from this backup planned for it will use the copy.'}'),
          ),
      ],
      if (present.isNotEmpty) ...[
        _groupHeader('Already in My looms (${present.length})'),
        for (final i in present)
          ListTile(dense: true, title: Text(i.loom.displayName), subtitle: const Text('Skipped')),
      ],
    ];
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

  static String _restoreLabel(int count, {required bool settings, int looms = 0}) {
    final parts = [
      if (count > 0) plural(count, 'project'),
      if (looms > 0) plural(looms, 'loom'),
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

/// "1 project", "3 projects".
String plural(int n, String noun) => '$n $noun${n == 1 ? '' : 's'}';

/// The sentence after a restore ("Restored 2 projects and app settings.", "Restored 2 projects, 1
/// loom and app settings."), or null when it wrote nothing.
String? restoredMessage(RestoreResult result) {
  final parts = [
    if (result.count > 0) plural(result.count, 'project'),
    if (result.loomsRestored > 0) plural(result.loomsRestored, 'loom'),
    if (result.settingsRestored) 'app settings',
  ];
  if (parts.isEmpty) return null;
  final relinked = result.draftsRelinked;
  return 'Restored ${_andList(parts)}.'
      '${relinked == 0 ? '' : ' ${plural(relinked, 'draft')} now use${relinked == 1 ? 's' : ''} the '
          'restored copy of ${relinked == 1 ? 'its' : 'their'} loom.'}';
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
