import 'package:flutter/material.dart' show ThemeMode;

/// App-level preferences, persisted to a sidecar `app_settings.json` next to the draft library.
/// Theme-only for M4 (extend as the app grows). Immutable + value-equal so a Riverpod provider can
/// hold it and dedup rebuilds.
///
/// [accentSeed] is an ARGB int used as the `ColorScheme.fromSeed` seed when dynamic color is off or
/// unavailable; it defaults to Ply's original purple. [useDynamicColor] opts into Material You (the
/// device palette) when the platform supports it, falling back to [accentSeed] otherwise.
class AppSettings {
  const AppSettings({
    this.themeMode = ThemeMode.system,
    this.accentSeed = defaultAccent,
    this.useDynamicColor = true,
  });

  /// Ply's original seed (`0xFF6B4FA0`, a muted purple).
  static const int defaultAccent = 0xFF6B4FA0;

  final ThemeMode themeMode;
  final int accentSeed;
  final bool useDynamicColor;

  AppSettings copyWith({ThemeMode? themeMode, int? accentSeed, bool? useDynamicColor}) =>
      AppSettings(
        themeMode: themeMode ?? this.themeMode,
        accentSeed: accentSeed ?? this.accentSeed,
        useDynamicColor: useDynamicColor ?? this.useDynamicColor,
      );

  Map<String, dynamic> toJson() => {
        'themeMode': themeMode.name,
        'accentSeed': accentSeed,
        'useDynamicColor': useDynamicColor,
      };

  /// Tolerant parse: any missing/odd field falls back to its default (the repository also guards a
  /// malformed file wholesale).
  factory AppSettings.fromJson(Map<String, dynamic> j) => AppSettings(
        themeMode: ThemeMode.values.firstWhere(
          (m) => m.name == j['themeMode'],
          orElse: () => ThemeMode.system,
        ),
        accentSeed: (j['accentSeed'] as num?)?.toInt() ?? defaultAccent,
        useDynamicColor: j['useDynamicColor'] as bool? ?? true,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AppSettings &&
          other.themeMode == themeMode &&
          other.accentSeed == accentSeed &&
          other.useDynamicColor == useDynamicColor;

  @override
  int get hashCode => Object.hash(themeMode, accentSeed, useDynamicColor);
}
