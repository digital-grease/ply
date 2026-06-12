// Ply — local-first pattern tool (weaving first).
//
// This file is just the shell: initialize the native engine, build one
// DraftRepository (the sole owner of the FFI bridge + on-device storage), and
// hand it to the Library home screen. All real work lives in src/.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/data/draft_repository.dart';
import 'src/screens/library_screen.dart';
import 'src/state/editor_providers.dart';
import 'src/rust/frb_generated.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init(); // load the native engine before any bridge call
  final repository = DraftRepository();
  // The Library/Preview screens take the repository by constructor; the editor reads it from
  // Riverpod. One instance, exposed both ways, so there is a single owner of the FFI bridge.
  runApp(
    ProviderScope(
      overrides: [repositoryProvider.overrideWithValue(repository)],
      child: PlyApp(repository: repository),
    ),
  );
}

class PlyApp extends StatelessWidget {
  const PlyApp({required this.repository, super.key});

  final DraftRepository repository;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ply',
      theme: ThemeData(colorSchemeSeed: const Color(0xFF6B4FA0), useMaterial3: true),
      home: LibraryScreen(repository: repository),
    );
  }
}
