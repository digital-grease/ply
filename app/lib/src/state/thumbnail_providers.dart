import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../diagnostics/log_buffer.dart';

/// Rebuilds the thumbnails the weaving and knitting libraries are missing (a thumbnail is a cache:
/// only a save or a restore writes one, so one can be absent, for instance after a save whose render
/// failed). A library asks for each tile without a thumbnail; the rebuilds run in the background, ONE
/// AT A TIME in the order asked, and never block the list, which shows the placeholder meanwhile.
///
/// Each project is tried at most once per app run: the outcome is remembered, so a file that cannot
/// be read or drawn keeps its placeholder instead of being retried every time its library is shown
/// (a later save writes its thumbnail anyway).
class ThumbnailRegenerator {
  final Map<String, Future<bool>> _outcomes = {};
  Future<void> _tail = Future<void>.value();

  /// Rebuild a missing thumbnail with [rebuild], which completes with whether the thumbnail now
  /// exists (throwing counts as no). [key] names the project ("<craft>/<id>"): a key asked for
  /// before in this run is not rebuilt again, and its first outcome is returned. Never throws.
  Future<bool> request(String key, Future<bool> Function() rebuild) =>
      _outcomes.putIfAbsent(key, () {
        final outcome = _tail.then((_) => _run(key, rebuild));
        _tail = outcome;
        return outcome;
      });

  static Future<bool> _run(String key, Future<bool> Function() rebuild) async {
    try {
      if (await rebuild()) return true;
      PlyLog.instance.warn('Could not rebuild the thumbnail of $key.');
    } catch (e) {
      PlyLog.instance.warn('Could not rebuild the thumbnail of $key: $e');
    }
    return false;
  }

  /// Completes when every rebuild asked for so far has finished.
  @visibleForTesting
  Future<void> get idle => _tail;
}

/// The app's one [ThumbnailRegenerator], shared by the weaving and knitting libraries so their
/// rebuilds queue together and each project's outcome outlives a library reload.
final thumbnailRegeneratorProvider = Provider<ThumbnailRegenerator>((_) => ThumbnailRegenerator());
