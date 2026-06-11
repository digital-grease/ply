// Ply — local-first pattern tool (weaving first).
//
// This file is just the shell: initialize the native engine, build one
// DraftRepository (the sole owner of the FFI bridge + on-device storage), and
// hand it to the Library home screen. All real work lives in src/.

import 'package:flutter/material.dart';

import 'src/data/draft_repository.dart';
import 'src/screens/library_screen.dart';
import 'src/rust/frb_generated.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init(); // load the native engine before any bridge call
  runApp(PlyApp(repository: DraftRepository()));
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
