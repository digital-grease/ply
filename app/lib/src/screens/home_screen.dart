import 'package:flutter/material.dart';

import '../data/draft_repository.dart';
import 'glossary_screen.dart';
import 'knit_library_screen.dart';
import 'library_screen.dart';
import 'nalbind_reference_screen.dart';
import 'settings_screen.dart';

/// The app home: one library with a tab per craft (Weaving, Knitting). The shared chrome — the title
/// and the Glossary / Settings actions — lives here; each tab hosts that craft's library (its grid +
/// FABs) as an AppBar-less [Scaffold]. Replaces the older arrangement where the weave library WAS the
/// home and the knit library hung off an AppBar action.
class HomeScreen extends StatelessWidget {
  const HomeScreen({required this.repository, super.key});

  /// The weave repository (the sole owner of the weave FFI + storage), handed to the Weaving tab.
  /// The Knitting tab resolves its repository from Riverpod (`knitRepositoryProvider`).
  final DraftRepository repository;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Ply'),
          bottom: const TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.center,
            tabs: [
              Tab(text: 'Weaving', icon: Icon(Icons.texture)),
              Tab(text: 'Knitting', icon: Icon(Icons.grid_on)),
              Tab(text: 'Nalbinding', icon: Icon(Icons.gesture)),
            ],
          ),
          actions: [
            IconButton(
              tooltip: 'Glossary',
              icon: const Icon(Icons.menu_book_outlined),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const GlossaryScreen()),
              ),
            ),
            IconButton(
              tooltip: 'Settings',
              icon: const Icon(Icons.settings_outlined),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
              ),
            ),
          ],
        ),
        body: TabBarView(
          children: [
            LibraryScreen(repository: repository),
            const KnitLibraryScreen(),
            const NalbindReferenceScreen(),
          ],
        ),
      ),
    );
  }
}
