import 'package:flutter/material.dart';

import '../rust/nalbind_recipe_dto.dart';

/// A list of recipe issues, errors first, each with its severity in words.
class RecipeIssueList extends StatelessWidget {
  const RecipeIssueList({required this.issues, this.withPlace = false, super.key});

  /// Most findings shown in one list; the rest are counted in one line (the PDF lists them all).
  static const maxShown = 12;

  final List<RecipeIssueDto> issues;

  /// Show each issue with its place (`Step 3 (Cuff): ...`) rather than its message alone.
  final bool withPlace;

  static String levelWord(RecipeSeverityKind s) => switch (s) {
        RecipeSeverityKind.error => 'Problem',
        RecipeSeverityKind.warning => 'Warning',
        RecipeSeverityKind.info => 'Note',
      };

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final ordered = [
      for (final sev in const [
        RecipeSeverityKind.error,
        RecipeSeverityKind.warning,
        RecipeSeverityKind.info,
      ])
        ...issues.where((i) => i.severity == sev),
    ];
    final shown = ordered.take(maxShown);
    final more = ordered.length - maxShown;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final i in shown)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  switch (i.severity) {
                    RecipeSeverityKind.error => Icons.error_outline,
                    RecipeSeverityKind.warning => Icons.warning_amber_outlined,
                    RecipeSeverityKind.info => Icons.info_outline,
                  },
                  size: 18,
                  color: i.severity == RecipeSeverityKind.error ? cs.error : cs.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text('${levelWord(i.severity)}: ${withPlace ? i.text : i.message}'),
                ),
              ],
            ),
          ),
        if (more > 0)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('and $more more ${more == 1 ? 'finding' : 'findings'} (the PDF lists '
                'them all)'),
          ),
      ],
    );
  }
}
