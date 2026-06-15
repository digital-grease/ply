import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../rust/dto.dart' show SeverityKind;
import '../rust/nalbind_dto.dart';
import '../state/nalbind_providers.dart';
import '../widgets/nalbind_diagram_view.dart';

/// The Nalbinding tab: a stitch REFERENCE (M6 v1). A notation playground at the top (type a Hansen
/// string → live loop diagram + validation), then the curated builtin dictionary, each stitch showing
/// its notation, the `a+b` thumb-loop alias, alternate names, the generated structural diagram, and a
/// one-line description. No project editor or persistence yet (see `docs/NALBIND_DESIGN.md`).
class NalbindReferenceScreen extends ConsumerWidget {
  const NalbindReferenceScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final builtins = ref.watch(nalbindBuiltinsProvider);
    return builtins.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text('Could not load the stitch reference:\n$e', textAlign: TextAlign.center),
        ),
      ),
      data: (entries) => ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        children: [
          const _NotationPlayground(),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
            child: Text('Stitch dictionary', style: Theme.of(context).textTheme.titleSmall),
          ),
          for (final e in entries) _StitchCard(stitch: e.stitch, diagram: e.diagram),
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
