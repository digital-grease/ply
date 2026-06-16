import 'package:flutter/material.dart';

import '../data/draft_repository.dart';
import 'calculators_screen.dart';
import 'help_screen.dart';
import 'knit_library_screen.dart';
import 'library_screen.dart';
import 'nalbind_reference_screen.dart';
import 'settings_screen.dart';

/// The app home: one library with a tab per craft (Weaving, Knitting, Nalbinding). The shared chrome
/// — the title and the Help / Settings actions — lives here; each tab hosts that craft's library (its
/// grid + FABs) as an AppBar-less [Scaffold]. The Help ("?") action opens the FAQ + Glossary hub.
class HomeScreen extends StatelessWidget {
  const HomeScreen({required this.repository, super.key});

  /// The weave repository (the sole owner of the weave FFI + storage), handed to the Weaving tab.
  /// The Knitting tab resolves its repository from Riverpod (`knitRepositoryProvider`).
  final DraftRepository repository;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 4,
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
              Tab(text: 'Calculators', icon: Icon(Icons.calculate_outlined)),
            ],
          ),
          actions: [
            IconButton(
              tooltip: 'Help & FAQ',
              icon: const Icon(Icons.help_outline),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const HelpScreen()),
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
            const CalculatorsScreen(),
          ],
        ),
      ),
    );
  }
}
