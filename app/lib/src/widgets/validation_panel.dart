// The inline validation band: surfaces the engine's structural issues (Errors red, Warnings amber)
// between the draft and the DimensionsBar, re-running live on every edit via [validationProvider].
//
// ZERO CHROME WHEN CLEAN. A clean draft (or a still-loading / errored validation) collapses to a
// SizedBox.shrink — validation is ADVISORY, so the band never blinks a spinner or an error card; it
// only appears when there are real issues. Collapsed to a one-line summary by default; tapping the
// header (or the Save-with-errors dialog's "Show me") expands it to a bounded, scrollable list with
// Errors sorted first. The band has INTRINSIC height (it is NOT inside the body's Expanded), so it
// shrinks the drawdown viewport only when issues exist and never steals space from a clean draft.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/draft_issue.dart';
import '../state/editor_providers.dart';
import '../theme/ply_colors.dart';

class ValidationPanel extends ConsumerWidget {
  const ValidationPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Watch FIRST, unconditionally, so the autoDispose [validationProvider] stays subscribed even in
    // the clean case (branching before watching would silently stop live validation). Branch on the
    // value SECOND: a loading/error AsyncValue collapses to "show nothing".
    final issues = ref.watch(validationProvider).valueOrNull ?? const <DraftIssue>[];
    if (issues.isEmpty) return const SizedBox.shrink();

    final colors = Theme.of(context).colorScheme;
    // The warning role M3's ColorScheme lacks, supplied by the [PlyColors] theme extension. The
    // `??` is a safety net for a tree where the extension was not registered: fall back to the
    // amber the band historically hardcoded so the warning tone never resolves to null.
    final warning = Theme.of(context).extension<PlyColors>()?.warning ?? const Color(0xFFB26A00);
    final errors = issues.where((i) => i.isError).length;
    final warnings = issues.length - errors;
    final hasError = errors > 0;
    // The worst severity present drives the band's tone.
    final tone = hasError ? colors.error : warning;
    final bg = hasError ? colors.errorContainer : warning.withValues(alpha: 0.12);
    final headerIcon = hasError ? Icons.error : Icons.warning_amber_rounded;
    final expanded = ref.watch(editorIssuesExpandedProvider);

    return Material(
      elevation: 1,
      color: bg,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Collapsed summary: one tappable row. Compact to sit close to the DimensionsBar.
            // liveRegion so a screen reader is told when issues first appear or the count changes.
            Semantics(
              liveRegion: true,
              child: InkWell(
                onTap: () =>
                    ref.read(editorIssuesExpandedProvider.notifier).state = !expanded,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Row(
                    children: [
                      Icon(headerIcon, color: tone, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _summary(issues, errors, warnings),
                          // Severity is SPOKEN, not signalled by color alone, on the at-rest summary.
                          semanticsLabel: _semanticSummary(issues, errors, warnings),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ),
                      Icon(expanded ? Icons.expand_less : Icons.expand_more, size: 20),
                    ],
                  ),
                ),
              ),
            ),
            // Expanded: the full list, Errors first, bounded so many issues scroll INSIDE the band
            // instead of eating the drawdown. The cap GROWS with the text scale so larger type still
            // shows several rows before scrolling (rows get taller at scale), but never past half the
            // screen height.
            if (expanded)
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: _expandedMaxHeight(context),
                ),
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.only(bottom: 8),
                  children: [
                    for (final issue in _sorted(issues)) _IssueRow(issue: issue, amber: warning),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// The expanded list's max height. Scales with the text scale so larger type (an accessibility
  /// setting) still shows several rows before scrolling — rows grow taller at scale, so a fixed cap
  /// would starve them. Floor 120; cap grows with scale but never past half the screen height.
  double _expandedMaxHeight(BuildContext context) {
    final h = MediaQuery.sizeOf(context).height;
    final scale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 2.0);
    // Upper bound = half the screen (the band never eats the drawdown), but never below the 120
    // floor: on a short LANDSCAPE phone h*0.5 can dip under the floor, which would invert the
    // clamp range and THROW. The floor wins there — a short scrollable panel, not a crash.
    final upper = math.max(120.0, h * 0.5);
    // Desired cap grows with the text scale (bigger type -> more rows before scrolling), bounded
    // into [120, upper]. The 120 floor never binds the value (240*scale >= 240 always); it only
    // keeps the clamp range valid (lower <= upper) when a short viewport pushes `upper` below 240.
    final cap = (240.0 * scale).clamp(120.0, upper);
    return (h * 0.25 * scale).clamp(120.0, cap);
  }

  /// The summary as a screen reader should hear it: a single issue is prefixed with its severity
  /// (color is not the only signal); a multi-issue summary already names the severities.
  String _semanticSummary(List<DraftIssue> issues, int errors, int warnings) {
    if (issues.length == 1) {
      final i = issues.single;
      return '${i.isError ? 'Error' : 'Warning'}: ${i.message}';
    }
    return _summary(issues, errors, warnings);
  }

  /// Exactly one issue -> its engine-formatted message verbatim (e.g. "treadle 1 ties shaft 5
  /// outside 1..=2"); many -> a pluralized count, omitting a zero count.
  String _summary(List<DraftIssue> issues, int errors, int warnings) {
    if (issues.length == 1) return issues.single.message;
    final parts = <String>[];
    if (errors > 0) parts.add('$errors ${errors == 1 ? 'error' : 'errors'}');
    if (warnings > 0) parts.add('$warnings ${warnings == 1 ? 'warning' : 'warnings'}');
    return parts.join(', ');
  }

  /// Errors first, then Warnings; engine order preserved within each group (stable sort over the
  /// severity index, error=0 < warning=1).
  List<DraftIssue> _sorted(List<DraftIssue> issues) {
    final out = [...issues];
    out.sort((a, b) => a.severity.index.compareTo(b.severity.index));
    return out;
  }
}

class _IssueRow extends StatelessWidget {
  const _IssueRow({required this.issue, required this.amber});

  final DraftIssue issue;
  final Color amber;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final isError = issue.isError;
    final tone = isError ? colors.error : amber;
    final icon = isError ? Icons.error : Icons.warning_amber_rounded;
    // Color is not the only signal: screen readers get an explicit severity prefix.
    return Semantics(
      label: '${isError ? 'Error' : 'Warning'}: ${issue.message}',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: tone, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(issue.message,
                  softWrap: true, style: Theme.of(context).textTheme.bodySmall),
            ),
          ],
        ),
      ),
    );
  }
}
