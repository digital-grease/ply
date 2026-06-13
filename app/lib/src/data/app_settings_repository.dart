import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/app_settings.dart';

/// Persists [AppSettings] to a single `app_settings.json` in the app documents directory (a sibling
/// of the `drafts/` library — the same on-device, no-backend pattern [DraftRepository] uses). Reads
/// are TOLERANT: a missing or malformed file yields defaults rather than throwing, so a settings
/// problem can never block the app from starting.
class AppSettingsRepository {
  /// Override the directory in tests (so persistence runs on the host VM without path_provider).
  @visibleForTesting
  Directory? dirOverride;

  Future<File> _file() async {
    final dir = dirOverride ?? await getApplicationDocumentsDirectory();
    return File(p.join(dir.path, 'app_settings.json'));
  }

  Future<AppSettings> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) return const AppSettings();
      final json = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      return AppSettings.fromJson(json);
    } catch (_) {
      return const AppSettings(); // unreadable / corrupt -> defaults
    }
  }

  Future<void> save(AppSettings settings) async {
    final f = await _file();
    // Atomic: write a temp then rename, so a crash mid-write never leaves a half-file.
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode(settings.toJson()));
    await tmp.rename(f.path);
  }
}
