// The Checks tab of the tablet weaving editor (M10-02, ADR 0018 section 13): every diagnostic the
// engine gives, grouped errors, warnings, not modelled and notes, each with its typed location in
// words and the remedy when there is one. Selecting one goes to it: a card's setup on the Cards tab,
// a written pick on the Turning tab, an expanded pick (or a float's first pick) on the Band tab.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/tablet_band.dart';
import '../rust/tablet_dto.dart';
import '../state/tablet_editor_providers.dart';
import 'tablet_widgets.dart';

class TabletChecksView extends ConsumerWidget {
  const TabletChecksView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final report = ref.watch(tabletReportProvider);
    return report.when(
      skipLoadingOnReload: true,
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text('Could not check the band: $e', textAlign: TextAlign.center),
        ),
      ),
      data: (r) => _ChecksList(report: r),
    );
  }
}

class _ChecksList extends ConsumerWidget {
  const _ChecksList({required this.report});
  final TabletReportDto report;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final groups = [
      (TabletSeverityKind.error, 'Errors', 'Ply cannot work out the band until these are fixed.'),
      (TabletSeverityKind.warning, 'Warnings', 'The band can be woven, but check these.'),
      (
        TabletSeverityKind.unsupported,
        'Not modelled',
        'Things Ply does not model: shown as such, never guessed.'
      ),
      (TabletSeverityKind.info, 'Notes', 'Facts about the band worth knowing.'),
    ];
    final summary = report.errors == 0 && report.warnings == 0 && report.unsupported == 0
        ? 'No errors, warnings or things Ply does not model.'
        : [
            '${report.errors} ${report.errors == 1 ? 'error' : 'errors'}',
            '${report.warnings} ${report.warnings == 1 ? 'warning' : 'warnings'}',
            '${report.unsupported} not modelled',
          ].join(', ');
    return ListView(
      key: const ValueKey('tablet-checks'),
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        TabletReviewNote(pending: report.reviewPending),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Semantics(
            liveRegion: true,
            child: Text(summary, style: theme.textTheme.titleSmall),
          ),
        ),
        if (report.expandedPicks != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
                '${report.expandedPicks} ${report.expandedPicks == 1 ? 'pick' : 'picks'} once every '
                'repeat is worked.',
                style: theme.textTheme.bodySmall),
          ),
        for (final (sev, title, help) in groups)
          ...() {
            final items = [
              for (final d in report.diagnostics)
                if (d.severity == sev) d
            ];
            if (items.isEmpty) return const <Widget>[];
            return [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: Semantics(
                  header: true,
                  child: Text('$title (${items.length})', style: theme.textTheme.titleMedium),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(help, style: theme.textTheme.bodySmall),
              ),
              for (var i = 0; i < items.length; i++)
                _DiagnosticTile(key: ValueKey('tablet-diag-${sev.name}-$i'), d: items[i]),
            ];
          }(),
      ],
    );
  }
}

class _DiagnosticTile extends ConsumerWidget {
  const _DiagnosticTile({required this.d, super.key});
  final TabletDiagnosticDto d;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final where = tabletLocationText(d.location);
    final target = diagnosticTarget(d.location);
    final color = severityColor(context, d.severity);
    return ListTile(
      leading: Icon(severityIcon(d.severity), color: color),
      title: Text(d.message),
      subtitle: Text([
        '${severityWord(d.severity)}${where == null ? '' : ': $where'}',
        if (d.remediation != null) d.remediation!,
      ].join('\n')),
      isThreeLine: d.remediation != null,
      trailing: target == null ? null : const Icon(Icons.chevron_right),
      onTap: target == null ? null : () => goToDiagnostic(ref, target),
    );
  }
}

/// Where a diagnostic's location takes the editor, or null for the whole band.
({TabletEditorTab tab, TabletFocus focus})? diagnosticTarget(TabletLocationDto l) {
  int? zero(int? n) => n == null ? null : n - 1;
  return switch (l.kind) {
    TabletLocationKind.card || TabletLocationKind.hole || TabletLocationKind.packCard => (
        tab: TabletEditorTab.cards,
        focus: TabletFocus(card: zero(l.card))
      ),
    TabletLocationKind.cards => (
        tab: TabletEditorTab.cards,
        focus: TabletFocus(card: l.cards.isEmpty ? null : l.cards.first - 1),
      ),
    TabletLocationKind.pack => (tab: TabletEditorTab.cards, focus: const TabletFocus()),
    TabletLocationKind.segment => (
        tab: TabletEditorTab.turning,
        focus: TabletFocus(segment: zero(l.segment)),
      ),
    TabletLocationKind.step => (
        tab: TabletEditorTab.turning,
        focus: TabletFocus(segment: zero(l.segment), step: zero(l.step), card: zero(l.card)),
      ),
    TabletLocationKind.pick => (
        tab: TabletEditorTab.band,
        focus: TabletFocus(pick: l.pick, card: l.cards.isEmpty ? null : l.cards.first - 1),
      ),
    TabletLocationKind.run => (
        tab: TabletEditorTab.band,
        focus: TabletFocus(pick: l.firstPick, card: zero(l.card)),
      ),
    TabletLocationKind.band || TabletLocationKind.omitted => null,
  };
}

/// Go to a diagnostic's place: switch tab, focus it, and for a pick move the stepper there.
void goToDiagnostic(WidgetRef ref, ({TabletEditorTab tab, TabletFocus focus}) target) {
  final pick = target.focus.pick;
  if (pick != null) {
    final total = expandedPicks(ref.read(tabletDocProvider));
    ref.read(tabletPickProvider.notifier).state = pick.clamp(1, total < 1 ? 1 : total);
  }
  ref.read(tabletFocusProvider.notifier).state = target.focus;
  ref.read(tabletTabProvider.notifier).state = target.tab;
}
