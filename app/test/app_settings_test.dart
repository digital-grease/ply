import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/app_settings_repository.dart';
import 'package:ply/src/models/app_settings.dart';
import 'package:ply/src/models/draft_doc.dart' show MeasureUnit;

void main() {
  group('AppSettings json', () {
    test('round-trips through toJson/fromJson', () {
      const s = AppSettings(
        themeMode: ThemeMode.dark,
        accentSeed: 0xFF00696E,
        useDynamicColor: false,
        unit: MeasureUnit.centimeters,
      );
      expect(AppSettings.fromJson(s.toJson()), s);
    });

    test('falls back to defaults on missing / odd fields', () {
      final s = AppSettings.fromJson({'themeMode': 'bogus', 'unit': 'furlongs'});
      expect(s.themeMode, ThemeMode.system);
      expect(s.accentSeed, AppSettings.defaultAccent);
      expect(s.useDynamicColor, true);
      expect(s.unit, MeasureUnit.inches, reason: 'unknown/absent unit defaults to imperial');
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

    test('a corrupt file is kept aside, so the next save cannot overwrite the only copy', () async {
      final file = File('${tmp.path}/app_settings.json');
      await file.writeAsString('{not valid json');
      expect(await repo.load(), const AppSettings());
      final kept = File('${tmp.path}/app_settings.json.corrupt');
      expect(kept.readAsStringSync(), '{not valid json', reason: 'the original bytes');
      expect(file.existsSync(), isFalse);

      const s = AppSettings(themeMode: ThemeMode.dark);
      await repo.save(s);
      expect(await repo.load(), s);
      expect(kept.readAsStringSync(), '{not valid json', reason: 'a later save leaves it alone');
    });

    test('valid JSON of the wrong shape is treated as corrupt too', () async {
      for (final bad in ['{"accentSeed":"purple"}', '[1, 2]', '"settings"']) {
        await File('${tmp.path}/app_settings.json').writeAsString(bad);
        expect(await repo.load(), const AppSettings(), reason: bad);
        expect(File('${tmp.path}/app_settings.json.corrupt').readAsStringSync(), bad);
      }
    });

    test('a file that is not UTF-8 is treated as corrupt', () async {
      await File('${tmp.path}/app_settings.json').writeAsBytes(const [0xFF, 0xFE, 0x00, 0x7B]);
      expect(await repo.load(), const AppSettings());
      expect(File('${tmp.path}/app_settings.json.corrupt').readAsBytesSync(),
          const [0xFF, 0xFE, 0x00, 0x7B]);
    });

    test('save is atomic: no temp file is left and a reload sees the new value', () async {
      await repo.save(const AppSettings(useDynamicColor: false));
      await repo.save(const AppSettings(useDynamicColor: true, accentSeed: 0xFF00696E));
      expect(File('${tmp.path}/app_settings.json.tmp').existsSync(), isFalse);
      expect(await repo.load(), const AppSettings(accentSeed: 0xFF00696E));
    });
  });

  test('decode reads bytes exactly as load reads the file (a restore checks settings with it)', () {
    const s = AppSettings(themeMode: ThemeMode.light, unit: MeasureUnit.centimeters);
    expect(AppSettingsRepository.decode(utf8.encode(jsonEncode(s.toJson()))), s);
    // Unknown keys are ignored, unknown values fall back.
    expect(AppSettingsRepository.decode(utf8.encode('{"themeMode":"light","x":1,"unit":"cubits"}')),
        const AppSettings(themeMode: ThemeMode.light));
    for (final bad in ['{"accentSeed":"purple"}', '[1, 2]', '"settings"', '{not json']) {
      expect(AppSettingsRepository.decode(utf8.encode(bad)), isNull, reason: bad);
    }
    expect(AppSettingsRepository.decode(const [0xFF, 0xFE, 0x00, 0x7B]), isNull);
  });
}
