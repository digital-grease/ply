// One write at a time to a project's sidecar (`<id>.json`) in this app (ADR 0016). The materials
// sheet rewrites a sidecar's links as they change, and an editor's save rewrites the whole sidecar
// from what is on disk; run one after the other, so neither reads a sidecar the other is replacing
// and a save right after an unlink keeps the unlink.

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;

/// Serializes the read-modify-write of each sidecar, by its path.
abstract final class SidecarWrites {
  static final Map<String, Future<void>> _tails = {};
  static final Map<String, int> _queued = {};

  /// Run [write] once every earlier write to [path] has finished (failed ones included).
  static Future<T> run<T>(String sidecarPath, Future<T> Function() write) {
    final path = p.normalize(p.absolute(sidecarPath));
    final before = _tails[path] ?? Future<void>.value();
    _queued[path] = (_queued[path] ?? 0) + 1;
    final run = before.then((_) => write());
    final tail = run.then((_) {}, onError: (Object _) {});
    _tails[path] = tail;
    tail.then((_) {
      final left = (_queued[path] ?? 1) - 1;
      if (left == 0) {
        _queued.remove(path);
      } else {
        _queued[path] = left;
      }
      if (identical(_tails[path], tail)) _tails.remove(path);
    });
    return run;
  }

  /// How many writes to [sidecarPath] are queued or running, so a test can set up an order of
  /// writes for certain.
  @visibleForTesting
  static int queuedOn(String sidecarPath) => _queued[p.normalize(p.absolute(sidecarPath))] ?? 0;
}
