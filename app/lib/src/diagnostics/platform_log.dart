import 'package:flutter/services.dart';

/// Reads the app's OWN recent platform log (Android logcat, via a method channel to MainActivity).
/// Captures the Flutter engine / plugin lines and warnings leading up to a crash — useful for NATIVE
/// crashes that never reach the Dart error handlers (the logcat ring buffer survives the process
/// death). Returns null when unavailable: iOS has no runtime API to read the app's own log, and some
/// Android devices block logcat — both surface as a caught error here.
class PlatformLog {
  PlatformLog._();

  static const MethodChannel channel = MethodChannel('com.digitalgrease.ply/diagnostics');

  /// The app's last [lines] of platform log, or null if it can't be read on this platform/device.
  static Future<String?> capture({int lines = 500}) async {
    try {
      return await channel.invokeMethod<String>('getPlatformLog', {'lines': lines});
    } catch (_) {
      return null;
    }
  }

  /// Hand [text] to the OS share sheet (Android `ACTION_SEND`). Returns true when the share UI was
  /// shown, false where it is not available (iOS / desktop / no handler), so the caller can fall back
  /// to the clipboard.
  static Future<bool> shareText(String text, {String subject = 'Ply diagnostics'}) async {
    try {
      final ok = await channel
          .invokeMethod<bool>('shareText', {'text': text, 'subject': subject});
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }
}
