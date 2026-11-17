// What Ply works out from a material or swatch record, and what it would check: the engine's derived
// figures (never stored) and its diagnostics, shown under the form as the crafter types.

import 'package:flutter/material.dart';

import '../models/material_record.dart';
import '../theme/spacing.dart';

/// The engine's report for a record: errors and warnings first, then the figures.
class RecordReportPanel extends StatelessWidget {
  const RecordReportPanel({required this.report, this.emptyText, super.key});

  final RecordReport report;

  /// Shown when there is nothing to work out yet.
  final String? emptyText;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final errors = report.diagnostics.where((d) => d.isError).toList();
    final warnings = report.diagnostics.where((d) => !d.isError).toList();
    return Column(
      key: const ValueKey('record-report'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          header: true,
          child: Text('What Ply works out', style: theme.textTheme.titleSmall),
        ),
        const SizedBox(height: PlySpacing.xs),
        Text(
            'Worked out from what you recorded each time it is shown. It is never saved in place '
            'of your measurements.',
            style: muted),
        for (final d in errors)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.error_outline, color: theme.colorScheme.error),
            title: Text(d.message),
            subtitle: const Text('Fix this to save.'),
          ),
        for (final d in warnings)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.info_outline, color: theme.colorScheme.tertiary),
            title: Text(d.message),
          ),
        if (report.figures.isEmpty && errors.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: PlySpacing.sm),
            child: Text(emptyText ?? 'Nothing to work out yet.', style: muted),
          ),
        for (final f in report.figures)
          ListTile(
            key: ValueKey('figure-${f.code}'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text('${f.label}: ${f.text}'),
            subtitle: Text(f.from),
          ),
      ],
    );
  }
}

/// A traced planning estimate: every input with its source in plain words, the working, and any
/// caveat. Shown under a calculator's result when the estimate uses a swatch.
class EstimateTrace extends StatelessWidget {
  const EstimateTrace({required this.estimate, super.key});

  final TracedEstimate<Object?> estimate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Semantics(
      container: true,
      child: Column(
        key: const ValueKey('estimate-trace'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: PlySpacing.sm),
          Text('How this was worked out', style: theme.textTheme.labelLarge),
          for (final i in estimate.inputs)
            Padding(
              padding: const EdgeInsets.only(top: PlySpacing.xs),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2, right: PlySpacing.xs),
                    child: SourceBadge(i.source),
                  ),
                  Expanded(
                    child: Text('${i.label}: ${i.sentence}',
                        key: ValueKey('trace-${i.key}'), style: theme.textTheme.bodySmall),
                  ),
                ],
              ),
            ),
          for (final w in estimate.working)
            Padding(
              padding: const EdgeInsets.only(top: PlySpacing.xs),
              child: Text(w, style: muted),
            ),
          if (estimate.hasDefaults)
            Padding(
              padding: const EdgeInsets.only(top: PlySpacing.xs),
              child: Text('Inputs marked Ply default are assumed, not measured.', style: muted),
            ),
          for (final n in estimate.notes)
            Padding(
              padding: const EdgeInsets.only(top: PlySpacing.xs),
              child: Text(n, style: theme.textTheme.bodySmall),
            ),
        ],
      ),
    );
  }
}

/// A small "Measured", "Entered" or "Ply default" badge for where a value came from (also used by
/// the warp and weft plan, ADR 0019).
class SourceBadge extends StatelessWidget {
  const SourceBadge(this.source, {super.key});

  final ValueSource source;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final (bg, fg) = switch (source) {
      ValueSource.measured => (cs.primaryContainer, cs.onPrimaryContainer),
      ValueSource.entered => (cs.secondaryContainer, cs.onSecondaryContainer),
      ValueSource.plyDefault => (cs.tertiaryContainer, cs.onTertiaryContainer),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(6)),
      child: Text(source.label, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: fg)),
    );
  }
}
