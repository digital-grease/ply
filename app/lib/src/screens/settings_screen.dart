import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/library_backup.dart';
import '../diagnostics/log_buffer.dart';
import '../models/draft_doc.dart' show MeasureUnit;
import '../state/backup_providers.dart';
import '../state/theme_providers.dart';
import '../theme/spacing.dart';
import 'diagnostics_screen.dart';
import 'ravelry_screen.dart';
import 'restore_preview_screen.dart';

/// App settings — appearance for M4 (theme mode, Material You, accent). Reads + writes the persisted
/// [appSettingsProvider]; every change applies live and survives a relaunch.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  /// A small palette of accent seeds (used to seed the color scheme when Material You is off or
  /// unavailable). The first is Ply's default purple.
  static const List<int> _accents = [
    0xFF6B4FA0, // purple (default)
    0xFF00696E, // teal
    0xFF1565C0, // blue
    0xFF2E7D32, // green
    0xFFB26A00, // amber
    0xFFC2185B, // pink
    0xFFB3261E, // red
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider);
    final notifier = ref.read(appSettingsProvider.notifier);
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: PlySpacing.lg),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(PlySpacing.md, PlySpacing.md, PlySpacing.md, PlySpacing.xs),
            child: Text('Appearance',
                style: text.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary)),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: PlySpacing.md, vertical: PlySpacing.xs),
            child: Align(
              alignment: Alignment.centerLeft,
              child: SegmentedButton<ThemeMode>(
                segments: const [
                  ButtonSegment(
                      value: ThemeMode.system,
                      label: Text('System'),
                      icon: Icon(Icons.brightness_auto)),
                  ButtonSegment(
                      value: ThemeMode.light, label: Text('Light'), icon: Icon(Icons.light_mode)),
                  ButtonSegment(
                      value: ThemeMode.dark, label: Text('Dark'), icon: Icon(Icons.dark_mode)),
                ],
                selected: {settings.themeMode},
                onSelectionChanged: (s) => notifier.setThemeMode(s.first),
              ),
            ),
          ),
          SwitchListTile(
            title: const Text('Material You'),
            subtitle: const Text('Use colors from your device wallpaper when available'),
            value: settings.useDynamicColor,
            onChanged: notifier.setUseDynamicColor,
          ),
          ListTile(
            title: const Text('Accent color'),
            subtitle: Text(settings.useDynamicColor
                ? 'Used when Material You is unavailable'
                : 'Seeds the color scheme'),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(PlySpacing.md, 0, PlySpacing.md, PlySpacing.sm),
            child: Wrap(
              spacing: PlySpacing.sm,
              runSpacing: PlySpacing.sm,
              children: [
                for (final seed in _accents)
                  _AccentSwatch(
                    color: Color(seed),
                    selected: settings.accentSeed == seed,
                    onTap: () => notifier.setAccentSeed(seed),
                  ),
              ],
            ),
          ),
          const Divider(height: PlySpacing.lg),
          Padding(
            padding: const EdgeInsets.fromLTRB(PlySpacing.md, PlySpacing.xs, PlySpacing.md, PlySpacing.xs),
            child: Text('Measurements',
                style: text.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(PlySpacing.md, 0, PlySpacing.md, PlySpacing.xs),
            child: Text('Units shown by the planning calculators.',
                style: text.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: PlySpacing.md, vertical: PlySpacing.xs),
            child: Align(
              alignment: Alignment.centerLeft,
              child: SegmentedButton<MeasureUnit>(
                segments: const [
                  ButtonSegment(value: MeasureUnit.inches, label: Text('Imperial')),
                  ButtonSegment(value: MeasureUnit.centimeters, label: Text('Metric')),
                ],
                selected: {settings.unit},
                onSelectionChanged: (s) => notifier.setUnit(s.first),
              ),
            ),
          ),
          const Divider(height: PlySpacing.lg),
          Padding(
            padding: const EdgeInsets.fromLTRB(PlySpacing.md, PlySpacing.xs, PlySpacing.md, PlySpacing.xs),
            child: Text('Backup',
                style: text.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary)),
          ),
          const _BackupSection(),
          const Divider(height: PlySpacing.lg),
          Padding(
            padding: const EdgeInsets.fromLTRB(PlySpacing.md, PlySpacing.xs, PlySpacing.md, PlySpacing.xs),
            child: Text('Connections',
                style: text.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary)),
          ),
          ListTile(
            leading: const Icon(Icons.cloud_outlined),
            title: const Text('Ravelry'),
            subtitle: const Text('Optional, online — search patterns with your own Ravelry key'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const RavelryScreen()),
            ),
          ),
          const Divider(height: PlySpacing.lg),
          Padding(
            padding: const EdgeInsets.fromLTRB(PlySpacing.md, PlySpacing.xs, PlySpacing.md, PlySpacing.xs),
            child: Text('Troubleshooting',
                style: text.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary)),
          ),
          ListTile(
            leading: const Icon(Icons.bug_report_outlined),
            title: const Text('Diagnostics'),
            subtitle: const Text('On-device logs + crash reports for filing a bug'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const DiagnosticsScreen()),
            ),
          ),
        ],
      ),
    );
  }
}

/// Back up the whole library to one file, and restore one (see `library_backup.dart`). Both run
/// offline through the system save dialog and file picker.
class _BackupSection extends ConsumerStatefulWidget {
  const _BackupSection();

  @override
  ConsumerState<_BackupSection> createState() => _BackupSectionState();
}

class _BackupSectionState extends ConsumerState<_BackupSection> {
  bool _busy = false;

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  /// Run [work] behind a modal progress dialog labelled [label].
  Future<T> _withProgress<T>(String label, Future<T> Function() work) async {
    final navigator = Navigator.of(context, rootNavigator: true);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: AlertDialog(
          content: Row(
            children: [
              const CircularProgressIndicator(),
              const SizedBox(width: PlySpacing.md),
              Expanded(child: Text(label)),
            ],
          ),
        ),
      ),
    );
    try {
      return await work();
    } finally {
      navigator.pop();
    }
  }

  Future<void> _backUp() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final backup = ref.read(libraryBackupProvider);
      final plan = await _withProgress('Preparing backup...', backup.planBackup);
      if (!mounted) return;
      final go = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Back up library'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final craft in BackupCraft.values)
                Text('${craft.label}: ${plural(plan.projectCounts[craft] ?? 0, 'project')}'
                    '${craft == BackupCraft.nalbinding && plan.photoCount > 0 ? ', ${plural(plan.photoCount, 'photo')}' : ''}'),
              const SizedBox(height: PlySpacing.sm),
              Text('Size: ${formatBytes(plan.archiveSize)}'),
              const SizedBox(height: PlySpacing.sm),
              const Text('App settings are not included.'),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Save')),
          ],
        ),
      );
      if (go != true || !mounted) return;
      final bytes = await _withProgress('Making backup...', () => backup.buildBackup(plan));
      final saved = await ref.read(backupFileAccessProvider).save(plan.fileName, bytes);
      if (saved) _snack('Backup saved.');
    } on BackupException catch (e) {
      PlyLog.instance.warn('Backup refused: $e');
      _snack(e.message);
    } catch (e) {
      PlyLog.instance.error('Backup failed: $e');
      _snack('Could not save the backup.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore() async {
    if (_busy) return;
    setState(() => _busy = true);
    final files = ref.read(backupFileAccessProvider);
    File? picked;
    String? refusal;
    try {
      picked = await files.pick();
      if (picked == null || !mounted) return;
      final archive = picked;
      final plan = await _withProgress(
          'Checking backup...', () => ref.read(libraryBackupProvider).inspectBackup(archive));
      if (!mounted) return;
      final result = await Navigator.of(context).push<RestoreResult>(
        MaterialPageRoute(builder: (_) => RestorePreviewScreen(plan: plan)),
      );
      if (result != null && result.count > 0) {
        _snack('Restored ${plural(result.count, 'project')}.');
      }
    } catch (e) {
      PlyLog.instance.warn('Restore refused: $e');
      refusal = e is BackupException
          ? e.message
          : const BackupException(BackupProblem.unreadable).message;
    } finally {
      // The picker's temporary copy is no longer needed (the preview has closed).
      if (picked != null) await files.discardPicked();
      if (mounted) setState(() => _busy = false);
    }
    if (refusal != null && mounted) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Cannot restore this backup'),
          content: Text(refusal!),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('OK')),
          ],
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ListTile(
          leading: const Icon(Icons.save_alt),
          title: const Text('Back up library'),
          subtitle: const Text('Save all projects to one file. App settings are not included.'),
          enabled: !_busy,
          onTap: _backUp,
        ),
        ListTile(
          leading: const Icon(Icons.restore),
          title: const Text('Restore from backup'),
          subtitle: const Text('Add projects from a backup file. Nothing is replaced.'),
          enabled: !_busy,
          onTap: _restore,
        ),
      ],
    );
  }
}

class _AccentSwatch extends StatelessWidget {
  const _AccentSwatch({required this.color, required this.selected, required this.onTap});

  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final onColor =
        ThemeData.estimateBrightnessForColor(color) == Brightness.dark ? Colors.white : Colors.black;
    return Semantics(
      label: 'Accent color',
      button: true,
      selected: selected,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: selected
                ? Border.all(color: Theme.of(context).colorScheme.onSurface, width: 2)
                : null,
          ),
          child: selected ? Icon(Icons.check, color: onColor, size: 20) : null,
        ),
      ),
    );
  }
}
