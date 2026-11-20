import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/library_backup.dart' show BackupCraft;
import '../data/library_places.dart';
import '../data/nalbind_repository.dart';
import '../models/nalbind_project.dart';
import '../rust/nalbind_dto.dart';
import 'library_place_providers.dart';
import 'progress_controller.dart' show progressRepositoryProvider;

/// The app's single [NalbindRepository] (the sole owner of the nalbind FFI). Tests override it.
final nalbindRepositoryProvider = Provider<NalbindRepository>((_) => NalbindRepository());

/// The saved nalbinding projects, newest-opened first. `ref.invalidate(nalbindProjectsProvider)` after
/// a save / rename / delete to refresh the list.
final nalbindProjectsProvider = FutureProvider<List<NalbindProjectEntry>>(
  (ref) => ref.watch(nalbindRepositoryProvider).listProjects(),
);

/// The saved place of each listed project (ADR 0023), by id: read after the list, which it never
/// holds up, and again whenever the list is (so invalidating [nalbindProjectsProvider] after a save,
/// a delete, a restore or a return from the project refreshes the places too). It starts from the
/// places last read, so nothing pops in, then gives the places again as each is read, and last the
/// read's whole result; a read begun again (the list invalidated) stops the one before.
final nalbindPlacesProvider = StreamProvider<Map<String, LibraryPlace>>((ref) {
  final repository = ref.watch(progressRepositoryProvider);
  final cache = ref.watch(libraryPlaceCacheProvider);
  final projects = ref.watch(nalbindProjectsProvider.future);
  final out = StreamController<Map<String, LibraryPlace>>();
  var live = true;
  ref.onDispose(() {
    live = false;
    out.close();
  });
  var places = cache.lastFor(BackupCraft.nalbinding);
  out.add(places);
  () async {
    try {
      final list = await projects;
      if (!live) return;
      final read = await readLibraryPlaces(
        repository,
        BackupCraft.nalbinding,
        [for (final p in list) p.id],
        cache: cache,
        stillWanted: () => live,
        onRead: (id, place) {
          if (places[id] == place) return;
          places = {...places};
          if (place == null) {
            places.remove(id);
          } else {
            places[id] = place;
          }
          out.add(places);
        },
      );
      if (live) out.add(read);
    } catch (_) {
      // No list: no places (the list says why).
    }
  }();
  return out.stream;
});

/// A builtin stitch paired with its rendered diagram.
typedef NalbindEntry = ({NalbindStitchDto stitch, DiagramDto diagram});

/// The builtin stitch dictionary, each paired with its diagram, loaded once for the reference list.
final nalbindBuiltinsProvider = FutureProvider<List<NalbindEntry>>((ref) async {
  final repo = ref.watch(nalbindRepositoryProvider);
  final stitches = await repo.builtins();
  return Future.wait(stitches.map(repo.withDiagram));
});
