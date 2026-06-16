import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/nalbind_repository.dart';
import '../models/nalbind_project.dart';
import '../rust/nalbind_dto.dart';

/// The app's single [NalbindRepository] (the sole owner of the nalbind FFI). Tests override it.
final nalbindRepositoryProvider = Provider<NalbindRepository>((_) => NalbindRepository());

/// The saved nalbinding projects, newest-opened first. `ref.invalidate(nalbindProjectsProvider)` after
/// a save / rename / delete to refresh the list.
final nalbindProjectsProvider = FutureProvider<List<NalbindProjectEntry>>(
  (ref) => ref.watch(nalbindRepositoryProvider).listProjects(),
);

/// A builtin stitch paired with its rendered diagram.
typedef NalbindEntry = ({NalbindStitchDto stitch, DiagramDto diagram});

/// The builtin stitch dictionary, each paired with its diagram, loaded once for the reference list.
final nalbindBuiltinsProvider = FutureProvider<List<NalbindEntry>>((ref) async {
  final repo = ref.watch(nalbindRepositoryProvider);
  final stitches = await repo.builtins();
  return Future.wait(stitches.map(repo.withDiagram));
});
