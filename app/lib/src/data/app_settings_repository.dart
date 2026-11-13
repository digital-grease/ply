import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../diagnostics/log_buffer.dart';
import '../models/app_settings.dart';

/// Persists [AppSettings] to a single `app_settings.json` in the app documents directory (a sibling
/// of the `drafts/` library — the same on-device, no-backend pattern [DraftRepository] uses). Reads
/// are TOLERANT: a missing or malformed file yields defaults rather than throwing, so a settings
/// problem can never block the app from starting. A malformed file is not silently lost: it is moved
/// aside to `app_settings.json.corrupt` (replacing an older one) before defaults are used, so the next
/// save cannot overwrite the only copy.
class AppSettingsRepository {
  /// Override the directory in tests (so persistence runs on the host VM without path_provider).
  @visibleForTesting
  Directory? dirOverride;

  /// Where a settings file that could not be parsed is kept.
  static const String corruptSuffix = '.corrupt';

  Future<File> _file() async {
    final dir = dirOverride ?? await getApplicationDocumentsDirectory();
    return File(p.join(dir.path, 'app_settings.json'));
  }

  Future<AppSettings> load() async {
    final File f;
    final List<int> bytes;
    try {
      f = await _file();
      if (!await f.exists()) return const AppSettings();
      bytes = await f.readAsBytes();
    } catch (_) {
      return const AppSettings(); // can't reach / read the file (I/O): leave it where it is
    }
    final settings = decode(bytes);
    if (settings != null) return settings;
    await _setAside(f);
    return const AppSettings();
  }

  /// Read settings file [bytes] the way [load] does: a JSON object parsed by [AppSettings.fromJson],
  /// so unknown keys are ignored (and not written back by the next save) and a missing or
  /// unrecognized value falls back to its default. Null when the bytes are not UTF-8, not a JSON
  /// object, or a field has the wrong type. A library restore checks backed-up settings with this.
  static AppSettings? decode(List<int> bytes) {
    try {
      final json = jsonDecode(utf8.decode(bytes));
      if (json is Map<String, dynamic>) return AppSettings.fromJson(json);
    } catch (_) {/* malformed JSON or a field of the wrong type */}
    return null;
  }

  /// Move an unparseable settings file aside instead of letting the next save overwrite it.
  Future<void> _setAside(File f) async {
    try {
      await f.rename('${f.path}$corruptSuffix');
      PlyLog.instance.warn('app_settings.json could not be read; kept it as '
          'app_settings.json$corruptSuffix and used the default settings.');
    } catch (_) {
      // Best effort: the defaults still apply.
    }
  }

  Future<void> save(AppSettings settings) async {
    final f = await _file();
    // Atomic and durable: write a temp, flush it to disk, then rename over the target, so a crash or
    // power loss mid-write never leaves a half-written or empty settings file.
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode(settings.toJson()), flush: true);
    await tmp.rename(f.path);
  }
}
