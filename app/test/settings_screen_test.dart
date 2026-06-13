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
}
