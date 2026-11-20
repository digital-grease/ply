import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/library_places.dart';
import 'progress_controller.dart' show progressRepositoryProvider;

/// What each progress record was found to be when a library last listed it (ADR 0023, amendment of
/// 2026-11-19), shared by every library tab for the app's run, so a tab built again shows its places
/// at once and an unchanged record is not decoded again. A new one with each progress repository.
final libraryPlaceCacheProvider = Provider<LibraryPlaceCache>((ref) {
  ref.watch(progressRepositoryProvider);
  return LibraryPlaceCache();
});
