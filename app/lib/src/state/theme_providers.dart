import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/app_settings_repository.dart';
import '../models/app_settings.dart';
import '../models/draft_doc.dart' show MeasureUnit;

/// The settings store (overridable in tests).
final appSettingsRepositoryProvider =
    Provider<AppSettingsRepository>((_) => AppSettingsRepository());

/// The live app settings. Starts at DEFAULTS synchronously — so the very first frame has a theme —
/// then loads the persisted values asynchronously and swaps them in. Every mutation persists
/// fire-and-forget. (Defaults-first + async-swap avoids a provider write during build and a
/// loading-flash on launch.)
class AppSettingsNotifier extends Notifier<AppSettings> {
  /// Set the instant the user CHANGES a setting. Guards the load-vs-mutate race: the initial
  /// [_load] resolves the OLD persisted value, so if a real mutation lands first (the user taps
  /// Dark on a cold start before the slow first `path_provider` channel call returns), the
  /// in-flight load must NOT clobber it back to disk's stale value and desync the UI. It is set
  /// ONLY on a value-changing mutation: a no-op tap (e.g. re-tapping the already-selected accent
  /// swatch) must fall through so the persisted load still applies, not strand the user on defaults.
  bool _userTouched = false;

  @override
  AppSettings build() {
    _load();
    return const AppSettings();
  }

  Future<void> _load() async {
    final loaded = await ref.read(appSettingsRepositoryProvider).load();
    if (!_userTouched) state = loaded; // a mutation during the load wins; never revert it
  }

  void _update(AppSettings next) {
    if (next == state) return; // a no-op tap claims nothing: it must not block the in-flight load
    _userTouched = true;
    state = next;
    ref.read(appSettingsRepositoryProvider).save(next); // persist, don't await
  }

  void setThemeMode(ThemeMode mode) => _update(state.copyWith(themeMode: mode));
  void setAccentSeed(int seed) => _update(state.copyWith(accentSeed: seed));
  void setUseDynamicColor(bool value) => _update(state.copyWith(useDynamicColor: value));
  void setUnit(MeasureUnit unit) => _update(state.copyWith(unit: unit));
}

final appSettingsProvider =
    NotifierProvider<AppSettingsNotifier, AppSettings>(AppSettingsNotifier.new);
