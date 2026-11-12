import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/library_backup.dart';
import '../state/backup_providers.dart';
import '../state/nalbind_providers.dart';
import '../theme/spacing.dart';

/// The restore preview: what a checked backup holds, grouped by craft into new projects, projects
/// that differ from the library (restored as copies unless unticked), projects already in the
/// library (skipped) and projects this build cannot restore (with the reason). Nothing is written
/// until "Restore" is tapped. Pops with the [RestoreResult] after a successful restore.
class RestorePreviewScreen extends ConsumerStatefulWidget {
  const RestorePreviewScreen({required this.plan, super.key});

  final RestorePlan plan;

  @override
  ConsumerState<RestorePreviewScreen> createState() => _RestorePreviewScreenState();
}

class _RestorePreviewScreenState extends ConsumerState<RestorePreviewScreen> {
  /// Keys of the conflicts the user unticked.
  final Set<String> _skipped = {};
  bool _busy = false;

  RestorePlan get _plan => widget.plan;

  int get _toRestore => _plan.projects
      .where((p) =>
          p.status == RestoreStatus.add ||
          (p.status == RestoreStatus.conflict && !_skipped.contains(p.key)))
      .length;

  Future<void> _restore() async {
    setState(() => _busy = true);
    try {
      final result =
          await ref.read(libraryBackupProvider).restore(_plan, skippedConflicts: {..._skipped});
      // Every library tab reloads its list.
      ref.read(libraryRevisionProvider.notifier).state++;
      ref.invalidate(nalbindProjectsProvider);
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
              child: Text('Nothing in your library is replaced. App settings are not restored.',
                  style: muted),
            ),
            if (_plan.projects.isEmpty)
              Padding(
                padding: const EdgeInsets.all(PlySpacing.md),
                child: Text('This backup has no projects.', style: muted),
              ),
            for (final craft in BackupCraft.values) ..._craftSection(craft, muted),
          ],
        ),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(PlySpacing.md),
            child: FilledButton(
              onPressed: (count > 0 && !_busy) ? _restore : null,
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
                  : Text(count > 0 ? 'Restore ${plural(count, 'project')}' : 'Nothing to restore'),
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
      Padding(
        padding: const EdgeInsets.fromLTRB(PlySpacing.md, 0, PlySpacing.md, PlySpacing.xs),
        child: Semantics(
          header: true,
          child: Text(craft.label,
              style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary)),
        ),
      ),
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
