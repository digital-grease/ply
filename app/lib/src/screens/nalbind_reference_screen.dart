import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../rust/dto.dart' show SeverityKind;
import '../rust/nalbind_dto.dart';
import '../state/nalbind_providers.dart';
import '../widgets/nalbind_diagram_view.dart';
import 'nalbind_project_screen.dart';

/// Open the nalbind project editor ([id] null = new); refresh the saved-projects list on return.
Future<void> _openNalbindProject(BuildContext context, WidgetRef ref, String? id) async {
  await Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => NalbindProjectScreen(openId: id)),
  );
  ref.invalidate(nalbindProjectsProvider);
}

/// The Nalbinding tab: a stitch REFERENCE (M6 v1). A notation playground at the top (type a Hansen
/// string → live loop diagram + validation), then the curated builtin dictionary, each stitch showing
/// its notation, the `a+b` thumb-loop alias, alternate names, the generated structural diagram, and a
/// one-line description. No project editor or persistence yet (see `docs/NALBIND_DESIGN.md`).
class NalbindReferenceScreen extends ConsumerWidget {
  const NalbindReferenceScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final builtins = ref.watch(nalbindBuiltinsProvider);
    // No AppBar: this is the Nalbinding TAB inside HomeScreen, which owns the shared chrome.
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'newNalbind',
        onPressed: () => _openNalbindProject(context, ref, null),
        icon: const Icon(Icons.add),
        label: const Text('New project'),
      ),
      body: builtins.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Text('Could not load the stitch reference:\n$e', textAlign: TextAlign.center),
          ),
        ),
        data: (entries) => ListView(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 88), // bottom pad clears the FAB
          children: [
            const _ProjectsSection(),
            const _NotationPrimer(),
            const SizedBox(height: 8),
            const _NotationPlayground(),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
              child: Text('Stitch dictionary', style: Theme.of(context).textTheme.titleSmall),
            ),
            for (final e in entries) _StitchCard(stitch: e.stitch, diagram: e.diagram),
          ],
        ),
      ),
    );
  }
}

/// The saved-projects list at the top of the Nalbinding tab (hidden until the first project exists —
/// the FAB invites creation before then). Tap to open; the overflow menu deletes.
class _ProjectsSection extends ConsumerWidget {
  const _ProjectsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projects = ref.watch(nalbindProjectsProvider);
    return projects.maybeWhen(
      data: (list) {
        if (list.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
              child: Text('My projects', style: Theme.of(context).textTheme.titleSmall),
            ),
            for (final proj in list)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.gesture),
                  title: Text(proj.name),
                  onTap: () => _openNalbindProject(context, ref, proj.id),
                  trailing: PopupMenuButton<String>(
                    tooltip: 'Project actions',
                    onSelected: (v) {
                      if (v == 'delete') _confirmDelete(context, ref, proj.id, proj.name);
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'delete', child: Text('Delete')),
                    ],
                  ),
                ),
              ),
            const Divider(height: 24),
          ],
        );
      },
      orElse: () => const SizedBox.shrink(),
    );
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref, String id, String name) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete project?'),
        content: Text('"$name" will be permanently removed.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(nalbindRepositoryProvider).deleteProject(id);
    ref.invalidate(nalbindProjectsProvider);
  }
}

/// A collapsible Hansen-notation primer at the top of the nalbinding page: nalbinding has no chart, so
/// the established way to read/share a stitch is Hansen's string notation, and the playground below
/// parses exactly this. Grounded in `docs/NALBIND_DESIGN.md` (Egon Hansen, 1990).
class _NotationPrimer extends StatelessWidget {
  const _NotationPrimer();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    Widget row(String symbol, String meaning) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 44,
                padding: const EdgeInsets.symmetric(vertical: 2),
                margin: const EdgeInsets.only(right: 12, top: 1),
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(symbol,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.w600)),
              ),
              Expanded(child: Text(meaning, style: text.bodyMedium)),
            ],
          ),
        );
    Widget heading(String s) => Padding(
          padding: const EdgeInsets.only(top: 12, bottom: 2),
          child: Text(s, style: text.labelLarge?.copyWith(color: cs.primary)),
        );
    return Card(
      child: ExpansionTile(
        leading: const Icon(Icons.menu_book_outlined),
        title: const Text('Hansen notation primer'),
        subtitle: const Text('How to read the stitch strings'),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "Egon Hansen's notation (1990) traces the needle's path through the loops, the work viewed "
            'flat — the closest thing to a standard the craft has. A stitch is written '
            'as a skeleton plus a connection, e.g. Oslo = UO/UOO F1.',
            style: text.bodyMedium,
          ),
          heading('Skeleton — the needle path'),
          row('U', 'pass under a loop'),
          row('O', 'pass over a loop'),
          row('/', 'turn / return point (the thread reverses)'),
          row(':', 'a further turn (multi-turn stitches like Åsle)'),
          row('( )', 'a skipped loop — present, but the needle does not engage it, e.g. U(U)O'),
          row('-', 'no over/under on that pass (looping stitches like Coptic)'),
          heading('Connection — anchors into the previous round'),
          row('F', 'join from the front (needle front → back)'),
          row('B', 'join from the back (back → front)'),
          row('M', 'join through the middle'),
          row('n', 'how many previous-round loops it engages (F2 is denser than F1)'),
          const SizedBox(height: 10),
          Text(
            'A parallel community naming counts thumb-loop groups a+b: Oslo = 1+1, Mammen = 1+2, '
            'Finnish = 2+2. Try a string in the playground below to see its loop diagram.',
            style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// Type a Hansen string and see its diagram + validation live.
class _NotationPlayground extends ConsumerStatefulWidget {
  const _NotationPlayground();

  @override
  ConsumerState<_NotationPlayground> createState() => _NotationPlaygroundState();
}

class _NotationPlaygroundState extends ConsumerState<_NotationPlayground> {
  final _controller = TextEditingController();
  int _seq = 0;
  DiagramDto? _diagram;
  List<NalbindIssueDto> _issues = const [];
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _onChanged(String text) async {
    final mySeq = ++_seq;
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      setState(() {
        _diagram = null;
        _issues = const [];
        _error = null;
      });
      return;
    }
    final repo = ref.read(nalbindRepositoryProvider);
    try {
      final stitch = await repo.parse(trimmed);
      final diagram = await repo.diagram(stitch);
      final issues = await repo.validate(stitch);
      if (!mounted || mySeq != _seq) return; // a newer keystroke superseded this
      setState(() {
        _diagram = diagram;
        _issues = issues;
        _error = null;
      });
    } catch (e) {
      if (!mounted || mySeq != _seq) return;
      setState(() {
        _diagram = null;
        _error = _cleanError(e);
      });
    }
  }

  String _cleanError(Object e) {
    final s = e.toString();
    final i = s.indexOf('invalid Hansen notation:');
    return i >= 0 ? s.substring(i) : s;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Notation playground', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            TextField(
              controller: _controller,
              onChanged: _onChanged,
              autocorrect: false,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'Hansen notation',
                hintText: 'e.g. UO/UOO F1',
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_error!, style: TextStyle(color: cs.error)),
              ),
            if (_diagram != null) ...[
              const SizedBox(height: 12),
              NalbindDiagramView(diagram: _diagram!),
              for (final issue in _issues)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        issue.severity == SeverityKind.error
                            ? Icons.error_outline
                            : Icons.warning_amber_rounded,
                        size: 16,
                        color: issue.severity == SeverityKind.error ? cs.error : cs.tertiary,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(issue.message, style: Theme.of(context).textTheme.bodySmall),
                      ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

/// One dictionary entry: name + alias chip, notation code(s), AKAs, the diagram, and a description.
class _StitchCard extends StatelessWidget {
  const _StitchCard({required this.stitch, required this.diagram});

  final NalbindStitchDto stitch;
  final DiagramDto diagram;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final muted = text.bodySmall?.copyWith(color: cs.onSurfaceVariant);
    final code = stitch.codes.isNotEmpty ? stitch.codes.first.code : '';
    final altCodes = stitch.codes.skip(1).map((c) => c.code).toList();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(stitch.name, style: text.titleMedium)),
                if (stitch.thumbLoops != null)
                  _chip(context, '${stitch.thumbLoops!.a}+${stitch.thumbLoops!.b}'),
              ],
            ),
            if (code.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  code,
                  style: text.titleSmall?.copyWith(fontFamily: 'monospace', color: cs.primary),
                ),
              ),
            if (altCodes.isNotEmpty)
              Text('also published as ${altCodes.join(", ")}', style: muted),
            if (stitch.alsoKnownAs.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text('a.k.a. ${stitch.alsoKnownAs.join(", ")}', style: muted),
              ),
            const SizedBox(height: 10),
            NalbindDiagramView(diagram: diagram),
            if (stitch.note.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(stitch.note, style: text.bodyMedium),
              ),
          ],
        ),
      ),
    );
  }

  Widget _chip(BuildContext context, String label) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: cs.secondaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(label, style: TextStyle(color: cs.onSecondaryContainer, fontSize: 12)),
    );
  }
}
