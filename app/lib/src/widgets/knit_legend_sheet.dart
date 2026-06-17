import 'package:flutter/material.dart';

import '../models/knit_stitches.dart';
import 'adaptive_sheet.dart';

/// Show the knitting stitch legend / abbreviation key. Adaptive: a bottom sheet on phones, a centered
/// dialog on tablet/wide screens.
Future<void> showKnitLegendSheet(BuildContext context) {
  return showAdaptiveSheet<void>(context, child: const KnitLegendSheet());
}

/// A read-only key of the stitch abbreviations used in the editor (e.g. "k2tog = knit two together"),
/// sourced from [kKnitBrushes] so it can never drift from the brushes the editor paints with.
class KnitLegendSheet extends StatelessWidget {
  const KnitLegendSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Stitch key', style: text.titleMedium),
            const SizedBox(height: 4),
            Text('What the chart abbreviations mean.',
                style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
            const SizedBox(height: 12),
            for (final b in kKnitBrushes)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 56,
                      child: Text(b.symbol,
                          style: text.titleSmall?.copyWith(color: cs.primary)),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(b.label, style: text.bodyLarge),
                          Text(b.description,
                              style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
