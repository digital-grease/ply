import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/app_settings_repository.dart';
import '../models/app_settings.dart';

/// The settings store (overridable in tests).
final appSettingsRepositoryProvider =
    Provider<AppSettingsRepository>((_) => AppSettingsRepository());

/// The live app settings. Starts at DEFAULTS synchronously — so the very first frame has a theme —
/// then loads the persisted values asynchronously and swaps them in. Every mutation persists
/// fire-and-forget. (Defaults-first + async-swap avoids a provider write during build and a
/// loading-flash on launch.)
class AppSettingsNotifier extends Notifier<AppSettings> {
  @override
  AppSettings build() {
    _load();
    return const AppSettings();
  }

  Future<void> _load() async {
    state = await ref.read(appSettingsRepositoryProvider).load();
  }

  void _update(AppSettings next) {
    if (next == state) return;
    state = next;
    ref.read(appSettingsRepositoryProvider).save(next); // persist, don't await
  }

  void setThemeMode(ThemeMode mode) => _update(state.copyWith(themeMode: mode));
  void setAccentSeed(int seed) => _update(state.copyWith(accentSeed: seed));
  void setUseDynamicColor(bool value) => _update(state.copyWith(useDynamicColor: value));
}

final appSettingsProvider =
    NotifierProvider<AppSettingsNotifier, AppSettings>(AppSettingsNotifier.new);
