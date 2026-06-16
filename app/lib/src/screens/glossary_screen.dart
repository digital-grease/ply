import 'package:flutter/material.dart';

import '../data/glossary_data.g.dart';
import '../models/glossary_term.dart';
import '../theme/spacing.dart';

/// A searchable, tap-to-expand reference of fiber-craft terms (weaving, knitting, nalbinding),
/// reached from Help (the "?" action in the home AppBar opens [HelpScreen], whose Glossary tile
/// pushes this).
///
/// The content comes straight from [kGlossary] (generated from `docs/GLOSSARY.md`, the single
/// source), so there is no FFI or async load here — just a client-side filter over a small const
/// list. Each match is an [ExpansionTile] so the list reads as a scannable index that opens to the
/// full definition on tap.
class GlossaryScreen extends StatefulWidget {
  const GlossaryScreen({super.key});

  @override
  State<GlossaryScreen> createState() => _GlossaryScreenState();
}

class _GlossaryScreenState extends State<GlossaryScreen> {
  final TextEditingController _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// Case-insensitive match over the term, its alias, and the definition, so a search for "epi"
  /// finds Sett (whose definition mentions EPI), not just headword hits.
  List<GlossaryTerm> get _filtered {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return kGlossary;
    return [
      for (final t in kGlossary)
        if (t.term.toLowerCase().contains(q) ||
            (t.aka?.toLowerCase().contains(q) ?? false) ||
            t.definition.toLowerCase().contains(q))
          t,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final results = _filtered;
    return Scaffold(
      appBar: AppBar(title: const Text('Glossary')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(PlySpacing.md),
            child: TextField(
              controller: _search,
              onChanged: (v) => setState(() => _query = v),
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                labelText: 'Search terms',
                prefixIcon: const Icon(Icons.search),
                border: const OutlineInputBorder(),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear',
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _search.clear();
                          setState(() => _query = '');
                        },
                      ),
              ),
            ),
          ),
          if (results.isEmpty)
            Expanded(
              child: Center(
                child: Text(
                  'No terms match "${_query.trim()}".',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            )
          else
            Expanded(
              child: ListView.separated(
                itemCount: results.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) => _GlossaryTile(term: results[i]),
              ),
            ),
        ],
      ),
    );
  }
}

/// One expandable glossary entry: the headword (and any alias) as the title, the definition
/// revealed on tap.
class _GlossaryTile extends StatelessWidget {
  const _GlossaryTile({required this.term});

  final GlossaryTerm term;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ExpansionTile(
      title: Text(term.term, style: theme.textTheme.titleMedium),
      subtitle: term.aka == null ? null : Text('also: ${term.aka}'),
      childrenPadding: const EdgeInsets.fromLTRB(
        PlySpacing.md,
        0,
        PlySpacing.md,
        PlySpacing.md,
      ),
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Text(term.definition, style: theme.textTheme.bodyMedium),
        ),
      ],
    );
  }
}
