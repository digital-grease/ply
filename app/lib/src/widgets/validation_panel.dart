// The inline validation band: surfaces the engine's structural issues (Errors red, Warnings amber)
// between the draft and the DimensionsBar, re-running live on every edit via [validationProvider].
//
// ZERO CHROME WHEN CLEAN. A clean draft (or a still-loading / errored validation) collapses to a
// SizedBox.shrink — validation is ADVISORY, so the band never blinks a spinner or an error card; it
// only appears when there are real issues. Collapsed to a one-line summary by default; tapping the
// header (or the Save-with-errors dialog's "Show me") expands it to a bounded, scrollable list with
// Errors sorted first. The band has INTRINSIC height (it is NOT inside the body's Expanded), so it
// shrinks the drawdown viewport only when issues exist and never steals space from a clean draft.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/draft_issue.dart';
import '../state/editor_providers.dart';

class ValidationPanel extends ConsumerWidget {
  const ValidationPanel({super.key});

  /// Warning amber. The Material [ColorScheme] has no semantic "warning" role, so the one amber the
  /// editor uses is centralized HERE — the standing M4 theming request swaps it in a single place.
  static const Color _amber = Color(0xFFB26A00);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Watch FIRST, unconditionally, so the autoDispose [validationProvider] stays subscribed even in
    // the clean case (branching before watching would silently stop live validation). Branch on the
    // value SECOND: a loading/error AsyncValue collapses to "show nothing".
    final issues = ref.watch(validationProvider).valueOrNull ?? const <DraftIssue>[];
    if (issues.isEmpty) return const SizedBox.shrink();

    final colors = Theme.of(context).colorScheme;
    final errors = issues.where((i) => i.isError).length;
    final warnings = issues.length - errors;
    final hasError = errors > 0;
    // The worst severity present drives the band's tone.
    final tone = hasError ? colors.error : _amber;
    final bg = hasError ? colors.errorContainer : _amber.withValues(alpha: 0.12);
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
            // instead of eating the drawdown. The cap is relative to the screen so a large text scale
            // still shows several rows (never below 120, never above 240).
            if (expanded)
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: (MediaQuery.sizeOf(context).height * 0.25).clamp(120.0, 240.0),
                ),
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.only(bottom: 8),
                  children: [
                    for (final issue in _sorted(issues)) _IssueRow(issue: issue, amber: _amber),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
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
