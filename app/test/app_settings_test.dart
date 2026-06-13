import 'dart:io';

import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/app_settings_repository.dart';
import 'package:ply/src/models/app_settings.dart';

void main() {
  group('AppSettings json', () {
    test('round-trips through toJson/fromJson', () {
      const s = AppSettings(
          themeMode: ThemeMode.dark, accentSeed: 0xFF00696E, useDynamicColor: false);
      expect(AppSettings.fromJson(s.toJson()), s);
    });

    test('falls back to defaults on missing / odd fields', () {
      final s = AppSettings.fromJson({'themeMode': 'bogus'});
      expect(s.themeMode, ThemeMode.system);
      expect(s.accentSeed, AppSettings.defaultAccent);
      expect(s.useDynamicColor, true);
    });
  });

  group('AppSettingsRepository', () {
    late Directory tmp;
    late AppSettingsRepository repo;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('ply_settings_test');
      repo = AppSettingsRepository()..dirOverride = tmp;
    });
    tearDown(() async => tmp.delete(recursive: true));

    test('a missing file yields defaults', () async {
      expect(await repo.load(), const AppSettings());
    });

    test('save -> load round-trips', () async {
      const s = AppSettings(
          themeMode: ThemeMode.light, accentSeed: 0xFFB3261E, useDynamicColor: false);
      await repo.save(s);
      expect(await repo.load(), s);
    });

    test('a corrupt file yields defaults (never throws)', () async {
      await File('${tmp.path}/app_settings.json').writeAsString('{not valid json');
      expect(await repo.load(), const AppSettings());
    });
  });
}
