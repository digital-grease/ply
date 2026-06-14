import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/app_settings_repository.dart';
import 'package:ply/src/models/app_settings.dart';
import 'package:ply/src/screens/settings_screen.dart';
import 'package:ply/src/state/theme_providers.dart';

// An in-memory settings store, so the provider's async load resolves without path_provider.
class FakeSettingsRepo extends AppSettingsRepository {
  AppSettings stored = const AppSettings();
  @override
  Future<AppSettings> load() async => stored;
  @override
  Future<void> save(AppSettings s) async => stored = s;
}

/// A store whose [load] is GATED so a test can mutate the provider while the initial disk read is
/// still in flight — the load-vs-mutate race window.
class SlowSettingsRepo extends AppSettingsRepository {
  SlowSettingsRepo(this.stored);
  AppSettings stored;
  final Completer<void> gate = Completer<void>();
  @override
  Future<AppSettings> load() async {
    await gate.future;
    return stored;
  }

  @override
  Future<void> save(AppSettings s) async => stored = s;
}

Future<ProviderContainer> pumpSettings(WidgetTester t) async {
  final c = ProviderContainer(
    overrides: [appSettingsRepositoryProvider.overrideWithValue(FakeSettingsRepo())],
  );
  addTearDown(c.dispose);
  await t.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: const MaterialApp(home: SettingsScreen()),
    ),
  );
  await t.pumpAndSettle();
  return c;
}

void main() {
  testWidgets('the theme-mode segments drive the provider', (t) async {
    final c = await pumpSettings(t);
    expect(c.read(appSettingsProvider).themeMode, ThemeMode.system);
    await t.tap(find.text('Dark'));
    await t.pumpAndSettle();
    expect(c.read(appSettingsProvider).themeMode, ThemeMode.dark);
  });

  testWidgets('the Material You switch drives the provider', (t) async {
    final c = await pumpSettings(t);
    expect(c.read(appSettingsProvider).useDynamicColor, isTrue);
    await t.tap(find.byType(SwitchListTile));
    await t.pumpAndSettle();
    expect(c.read(appSettingsProvider).useDynamicColor, isFalse);
  });

  testWidgets('tapping an accent swatch updates the seed', (t) async {
    final c = await pumpSettings(t);
    // Swatches carry the 'Accent color' semantics label, in _accents order (purple, teal, ...).
    await t.tap(find.bySemanticsLabel('Accent color').at(1)); // teal
    await t.pumpAndSettle();
    expect(c.read(appSettingsProvider).accentSeed, 0xFF00696E);
  });

  // The defaults-first + async-swap launch path has a race: the initial load resolves the OLD disk
  // value, so a user mutation that lands during the load must not be reverted (UI<->disk desync).
  test('a mutation during the initial load is NOT clobbered when the stale load resolves', () async {
    final repo = SlowSettingsRepo(const AppSettings(themeMode: ThemeMode.light));
    final c = ProviderContainer(
      overrides: [appSettingsRepositoryProvider.overrideWithValue(repo)],
    );
    addTearDown(c.dispose);

    // build() returns defaults synchronously and fires the (gated) load.
    expect(c.read(appSettingsProvider).themeMode, ThemeMode.system);

    // The user taps Dark while the load is still in flight (a slow cold-start path_provider call).
    c.read(appSettingsProvider.notifier).setThemeMode(ThemeMode.dark);
    expect(c.read(appSettingsProvider).themeMode, ThemeMode.dark);

    // Let the stale disk load (light) resolve — it must NOT revert the user's dark choice.
    repo.gate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(c.read(appSettingsProvider).themeMode, ThemeMode.dark,
        reason: 'the in-flight load must not clobber a fresh user mutation');
    expect(repo.stored.themeMode, ThemeMode.dark, reason: 'disk holds the user choice');
  });

  test('the persisted value IS loaded in when the user has not touched anything', () async {
    final repo = SlowSettingsRepo(const AppSettings(themeMode: ThemeMode.dark));
    final c = ProviderContainer(
      overrides: [appSettingsRepositoryProvider.overrideWithValue(repo)],
    );
    addTearDown(c.dispose);

    expect(c.read(appSettingsProvider).themeMode, ThemeMode.system, reason: 'defaults first');
    repo.gate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(c.read(appSettingsProvider).themeMode, ThemeMode.dark,
        reason: 'an untouched provider swaps in the persisted value');
  });

  // A NO-OP setting tap (re-selecting the already-selected accent swatch fires setAccentSeed with
  // the current value) must NOT claim the touch-guard — otherwise it would block the in-flight
  // cold-start load and strand the user on defaults even though they changed nothing.
  test('a NO-OP tap during the initial load does NOT block the persisted value', () async {
    const persisted = AppSettings(accentSeed: 0xFF00696E); // teal on disk
    final repo = SlowSettingsRepo(persisted);
    final c = ProviderContainer(
      overrides: [appSettingsRepositoryProvider.overrideWithValue(repo)],
    );
    addTearDown(c.dispose);

    final defaultSeed = c.read(appSettingsProvider).accentSeed; // the synchronous default
    // Re-set the accent to the value it already holds: a no-op _update (next == state).
    c.read(appSettingsProvider.notifier).setAccentSeed(defaultSeed);

    repo.gate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(c.read(appSettingsProvider).accentSeed, 0xFF00696E,
        reason: 'a no-op tap must let the persisted load through, not strand on the default');
  });
}
