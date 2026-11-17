// The editor's loom group (ADR 0014): under the structural validation band, in its own band, and
// only when the draft names a loom. "On Floor loom: not feasible, needs 8 shafts, has 4". Tapping it
// lists every loom check, not feasible first, each with what to do. It re-runs, latest wins, on every
// edit. It never gates saving: loom feasibility and structural validity are separate.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/loom_check.dart';
import '../state/loom_providers.dart';
import 'loom_plan_sheet.dart';

class LoomCheckPanel extends ConsumerWidget {
  const LoomCheckPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Watch first, unconditionally, so the autoDispose check stays subscribed. A reload keeps the
    // previous value, so the band does not blink while a newer check runs.
    final view = ref.watch(loomCheckProvider).valueOrNull;
    if (view == null) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    final expanded = ref.watch(loomCheckExpandedProvider);

    final (String headline, bool blocked, List<LoomDiagnostic> rows) = switch (view) {
      LoomCheckReady(:final report) => (report.headline, !report.feasible, report.sorted),
      LoomCheckMissing(:final plan) => (
          'Planned for ${plan.displayName}, which is not in My looms.',
          false,
          const <LoomDiagnostic>[],
        ),
      LoomCheckUnavailable(:final plan, :final reason) => (
          'Planned for ${plan.displayName}, not checked: $reason',
          false,
          const <LoomDiagnostic>[]
        ),
    };
    final tone = blocked ? colors.error : colors.primary;
    final bg = blocked ? colors.errorContainer : colors.primary.withValues(alpha: 0.06);

    return Material(
      key: const ValueKey('loom-check-panel'),
      elevation: 1,
      color: bg,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(
              liveRegion: true,
              child: InkWell(
                onTap: rows.isEmpty
                    ? () => chooseLoomForDraft(context, ref)
                    : () => ref.read(loomCheckExpandedProvider.notifier).state = !expanded,
                child: Padding(
                  padding: const EdgeInsets.only(left: 12, right: 4, top: 2, bottom: 2),
                  child: Row(
                    children: [
                      Icon(blocked ? Icons.block : Icons.fact_check_outlined,
                          color: tone, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          headline,
                          maxLines: expanded ? 3 : 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: 'Change the loom',
                        icon: const Icon(Icons.tune, size: 20),
                        onPressed: () => chooseLoomForDraft(context, ref),
                      ),
                      if (rows.isNotEmpty)
                        Icon(expanded ? Icons.expand_less : Icons.expand_more, size: 20),
                      const SizedBox(width: 8),
                    ],
                  ),
                ),
              ),
            ),
            if (expanded && rows.isNotEmpty)
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: _maxHeight(context)),
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.only(bottom: 8),
                  children: [for (final d in rows) LoomDiagnosticRow(diagnostic: d)],
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Bounded like the validation band: a scrollable list, never more than half the screen.
  double _maxHeight(BuildContext context) {
    final h = MediaQuery.sizeOf(context).height;
    final scale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 2.0);
    final upper = math.max(120.0, h * 0.5);
    return (h * 0.25 * scale).clamp(120.0, upper);
  }
}

/// The spoken severity of a loom finding.
String loomSeverityWord(LoomSeverity s) => switch (s) {
      LoomSeverity.notFeasible => 'Not feasible',
      LoomSeverity.advice => 'Note',
      LoomSeverity.notChecked => 'Not checked',
      LoomSeverity.fits => 'Fits',
    };

/// One loom finding: its icon (not color alone), the sentence, and what to do.
class LoomDiagnosticRow extends StatelessWidget {
  const LoomDiagnosticRow({required this.diagnostic, super.key});

  final LoomDiagnostic diagnostic;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final (IconData icon, Color tone) = switch (diagnostic.severity) {
      LoomSeverity.notFeasible => (Icons.block, colors.error),
      LoomSeverity.advice => (Icons.lightbulb_outline, colors.primary),
      LoomSeverity.notChecked => (Icons.help_outline, colors.onSurfaceVariant),
      LoomSeverity.fits => (Icons.check_circle_outline, colors.onSurfaceVariant),
    };
    final remedy = diagnostic.remediation;
    return Semantics(
      label: '${loomSeverityWord(diagnostic.severity)}: ${diagnostic.message}'
          '${remedy == null ? '' : ' $remedy'}',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: tone, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(diagnostic.message, style: text.bodySmall),
                  if (remedy != null)
                    Text(remedy, style: text.bodySmall?.copyWith(color: colors.onSurfaceVariant)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
