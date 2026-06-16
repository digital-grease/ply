import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'log_buffer.dart';
import 'log_scrubber.dart';
import 'platform_log.dart';

/// App version stamped into crash reports + the GitHub issue form. Keep in sync with pubspec on
/// release (there is no package_info plugin — Ply avoids extra native deps).
const String kPlyAppVersion = '0.1.0';

/// Captures UNCAUGHT Dart/Flutter errors, writes a scrubbed crash report to disk (surviving a
/// restart), and exposes it for the Diagnostics screen to surface on the next launch. Everything is
/// LOCAL: nothing is uploaded automatically — the user chooses whether to share a report.
///
/// Note: this captures DART-level errors (framework, async, zone). A native crash (in the Rust engine
/// or the platform) is not a Dart exception and is not caught here; those show up in platform logs.
class CrashReporter {
  CrashReporter._();
  static final CrashReporter instance = CrashReporter._();

  static const String fileName = 'ply_crash_report.txt';

  /// Tests point this at a temp dir to stand in for the app documents directory.
  Directory? docsOverride;

  Future<File> _file() async {
    final docs = docsOverride ?? await getApplicationDocumentsDirectory();
    return File(p.join(docs.path, fileName));
  }

  /// Install the framework + platform error handlers. Call once, before `runApp`. Pair with
  /// [runGuarded] to also catch uncaught errors in the async zone.
  void installHandlers() {
    final priorFlutterOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      PlyLog.instance.error('FlutterError: ${details.exceptionAsString()}');
      priorFlutterOnError?.call(details); // keep the default red-screen / console report
      unawaited(write(details.exception, details.stack ?? StackTrace.current));
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      PlyLog.instance.error('Uncaught: $error');
      unawaited(write(error, stack));
      return true; // handled — don't tear the app down over a recoverable async error
    };
  }

  /// Run [body] in a guarded zone so uncaught asynchronous errors land in a crash report. Wrap the
  /// whole of `main` (the `runApp` call) with this.
  Future<void> runGuarded(FutureOr<void> Function() body) {
    return runZonedGuarded(() async => body(), (error, stack) {
      PlyLog.instance.error('Zone error: $error');
      unawaited(write(error, stack));
    }) ?? Future<void>.value();
  }

  /// Overwrite the single crash report with app/platform info + the scrubbed error, stack, and recent
  /// logs. Best-effort and never throws (it runs while something is already going wrong).
  Future<void> write(Object error, StackTrace stack) async {
    try {
      final report = StringBuffer()
        ..writeln('=== Ply crash report ===')
        ..writeln('Time: ${DateTime.now().toUtc().toIso8601String()}')
        ..writeln('App: Ply $kPlyAppVersion')
        ..writeln('Platform: ${_platform()}')
        ..writeln()
        ..writeln('=== Error ===')
        ..writeln(LogScrubber.scrub(error.toString()))
        ..writeln()
        ..writeln('=== Stack ===')
        ..writeln(LogScrubber.scrub(stack.toString()))
        ..writeln()
        ..writeln('=== Recent logs ===')
        ..writeln(LogScrubber.scrub(PlyLog.instance.dump()));
      // The app's own platform log (Android logcat) — captures native engine/plugin lines the Dart
      // buffer misses. Best-effort; null on iOS or a device that blocks logcat.
      final platform = await PlatformLog.capture();
      if (platform != null && platform.isNotEmpty) {
        report
          ..writeln()
          ..writeln('=== Device log ===')
          ..writeln(LogScrubber.scrub(platform));
      }
      await (await _file()).writeAsString(report.toString(), flush: true);
    } catch (e) {
      debugPrint('CrashReporter: failed to write report: $e');
    }
  }

  static String _platform() {
    try {
      return '${Platform.operatingSystem} ${Platform.operatingSystemVersion}';
    } catch (_) {
      return 'unknown';
    }
  }

  Future<bool> hasReport() async => (await _file()).exists();

  Future<String?> read() async {
    final f = await _file();
    if (!await f.exists()) return null;
    try {
      return await f.readAsString();
    } catch (_) {
      return null;
    }
  }

  Future<void> dismiss() async {
    final f = await _file();
    if (await f.exists()) {
      try {
        await f.delete();
      } catch (_) {/* tolerate */}
    }
  }
}
