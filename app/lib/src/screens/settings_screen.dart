import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/theme_providers.dart';
import '../theme/spacing.dart';
import 'ravelry_screen.dart';

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
        ],
      ),
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
