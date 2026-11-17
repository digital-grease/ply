import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/knit_sections.dart';
import '../rust/dto.dart' show SeverityKind;
import '../rust/knit_dto.dart';
import '../state/knit_editor_providers.dart';
import '../theme/ply_colors.dart';
import '../widgets/knit_step_dialog.dart';
import '../widgets/name_input_dialog.dart';

/// The SECTIONS editor (M9-01): the pattern's construction as named sections of ordered steps (chart
/// rows, knit or purl across, rows or rounds, short rows, cast on, bind off, stitches put on hold and
/// returned, joining in the round, working part of the round flat, picking up, needle groups,
/// shaping, grafting, and written steps Ply does not check). A section can say whether it is worked
/// flat or in the round. Every step shows its words and the stitch count after it from
/// the engine's ledger ([knitConstructionProvider]), with any problem right beneath it. Edits go
/// through the knit editor's state, so Undo and Redo here and in the chart editor are one history.
/// Optional: a pattern without sections shows a short explanation and works as a chart, as before.
class KnitSectionsScreen extends ConsumerWidget {
  const KnitSectionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pattern = ref.watch(knitEditorProvider.select((s) => s.pattern));
    final canUndo = ref.watch(knitEditorProvider.select((s) => s.canUndo));
    final canRedo = ref.watch(knitEditorProvider.select((s) => s.canRedo));
    final construction = ref.watch(knitConstructionProvider).valueOrNull;
    final notifier = ref.read(knitEditorProvider.notifier);
    final general = [
      for (final i in construction?.issues ?? const <KnitSectionIssueDto>[])
        if (i.sectionId == null) i,
    ];
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sections'),
        actions: [
          IconButton(
            tooltip: 'Undo',
            icon: const Icon(Icons.undo),
            onPressed: canUndo ? notifier.undo : null,
          ),
          IconButton(
            tooltip: 'Redo',
            icon: const Icon(Icons.redo),
            onPressed: canRedo ? notifier.redo : null,
          ),
          IconButton(
            key: const Key('knit-add-section'),
            tooltip: 'Add section',
            icon: const Icon(Icons.add),
            onPressed: () => _addSection(context, ref),
          ),
        ],
      ),
      body: pattern.sections.isEmpty
          ? _Intro(onAdd: () => _addSection(context, ref))
          : ListView(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 32),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
                  child: Text(
                    'The written instructions follow these sections in order. The count after '
                    'each step is what is on the needle, on hold and bound off once it is done.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                if (general.isNotEmpty) _IssueList(general),
                for (var i = 0; i < pattern.sections.length; i++)
                  _SectionCard(
                    index: i,
                    pattern: pattern,
                    construction: construction,
                  ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: () => _addSection(context, ref),
                    icon: const Icon(Icons.add),
                    label: const Text('Add section'),
                  ),
                ),
              ],
            ),
    );
  }
}

Future<void> _addSection(BuildContext context, WidgetRef ref) async {
  final name = await promptForName(
    context,
    title: 'New section',
    confirmLabel: 'Add',
    fieldLabel: 'Section name',
    validator: _sectionNameProblem,
  );
  if (name == null) return;
  ref.read(knitEditorProvider.notifier).addSection(name);
}

/// Shown while the pattern has no sections.
class _Intro extends StatelessWidget {
  const _Intro({required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text('Build the pattern in sections', style: text.titleMedium),
        const SizedBox(height: 12),
        const Text(
          'Sections describe how a piece is made, step by step: casting on, working rows of the '
          'chart, short rows, putting stitches on hold and returning them to the needle, binding '
          'off, and for socks and other work in the round, heel flaps, picking up stitches, needle '
          'groups such as the instep and the sole, shaping and grafting. Ply counts the stitches '
          'after every step and says when a step asks for more stitches than there are.',
        ),
        const SizedBox(height: 12),
        const Text(
          'You do not need sections. Without them the written instructions follow the chart row '
          'by row, as they do now. Once a pattern has a section, the written instructions follow '
          'the sections instead, and a chart row appears where a section works it.',
        ),
        const SizedBox(height: 24),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            key: const Key('knit-add-first-section'),
            onPressed: onAdd,
            icon: const Icon(Icons.add),
            label: const Text('Add a section'),
          ),
        ),
      ],
    );
  }
}

enum _SectionMenu { rename, notes, construction, up, down, delete }

enum _StepMenu { edit, up, down, delete }

class _SectionCard extends ConsumerWidget {
  const _SectionCard({required this.index, required this.pattern, required this.construction});

  final int index;
  final KnitPatternDto pattern;
  final KnitConstructionDto? construction;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final section = pattern.sections[index];
    final title = knitSectionTitle(pattern, index);
    final notifier = ref.read(knitEditorProvider.notifier);
    final text = Theme.of(context).textTheme;
    final issues = [
      for (final i in construction?.issues ?? const <KnitSectionIssueDto>[])
        if (i.sectionIndex == index && i.stepIndex == null) i,
    ];
    return Card(
      // Position and id: ids can repeat in a hand-edited file, positions cannot.
      key: Key('knit-section-$index-${section.id}'),
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              title: Text('${index + 1}. $title', style: text.titleMedium),
              subtitle: _sectionSubtitle(section),
              trailing: PopupMenuButton<_SectionMenu>(
                tooltip: 'Section actions',
                onSelected: (m) async {
                  switch (m) {
                    case _SectionMenu.rename:
                      final name = await promptForName(context,
                          title: 'Rename section',
                          confirmLabel: 'Rename',
                          initial: section.name,
                          fieldLabel: 'Section name',
                          validator: _sectionNameProblem);
                      if (name != null) notifier.renameSectionAt(index, name);
                    case _SectionMenu.notes:
                      final notes = await showKnitTextDialog(context,
                          title: 'Section notes', label: 'Notes', initial: section.notes);
                      if (notes != null) notifier.setSectionNotesAt(index, notes);
                    case _SectionMenu.construction:
                      final choice = await _askConstruction(context, section.construction);
                      if (choice != null) notifier.setSectionConstructionAt(index, choice.$1);
                    case _SectionMenu.up:
                      notifier.moveSectionAt(index, -1);
                    case _SectionMenu.down:
                      notifier.moveSectionAt(index, 1);
                    case _SectionMenu.delete:
                      // Read the container now: this card is gone once the section is.
                      final container = ProviderScope.containerOf(context, listen: false);
                      notifier.removeSectionAt(index);
                      final deleted = container.read(knitEditorProvider).pattern;
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text('Deleted $title.'),
                          action: SnackBarAction(
                            label: 'Undo',
                            // Only while nothing else has changed since: otherwise Undo would
                            // take back a later edit instead.
                            onPressed: () {
                              if (identical(container.read(knitEditorProvider).pattern, deleted)) {
                                notifier.undo();
                              }
                            },
                          ),
                        ));
                      }
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: _SectionMenu.rename, child: Text('Rename')),
                  const PopupMenuItem(value: _SectionMenu.notes, child: Text('Notes')),
                  const PopupMenuItem(
                      value: _SectionMenu.construction, child: Text('Flat or in the round')),
                  PopupMenuItem(
                      value: _SectionMenu.up, enabled: index > 0, child: const Text('Move up')),
                  PopupMenuItem(
                      value: _SectionMenu.down,
                      enabled: index < pattern.sections.length - 1,
                      child: const Text('Move down')),
                  const PopupMenuItem(value: _SectionMenu.delete, child: Text('Delete section')),
                ],
              ),
            ),
            if (issues.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: _IssueList(issues),
              ),
            if (section.steps.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                child: Text('No steps yet.',
                    style: TextStyle(color: Theme.of(context).colorScheme.outline)),
              ),
            for (var j = 0; j < section.steps.length; j++)
              _StepTile(
                pattern: pattern,
                sectionIndex: index,
                section: section,
                index: j,
                construction: construction,
              ),
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: TextButton.icon(
                key: Key('knit-add-step-$index-${section.id}'),
                onPressed: () => _addStep(context, ref, index),
                icon: const Icon(Icons.add),
                label: const Text('Add step'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Why a section name cannot be saved (longer than a pattern file may hold), or null.
String? _sectionNameProblem(String name) => knitTextTooLong(name) ? kKnitTextTooLong : null;

/// The section's notes and, when it says, how it is worked.
Widget? _sectionSubtitle(KnitSectionDto section) {
  final parts = [
    if (section.construction != null) sectionConstructionLabel(section.construction),
    if (section.notes.trim().isNotEmpty) section.notes.trim(),
  ];
  return parts.isEmpty ? null : Text(parts.join('\n'));
}

/// Ask how a section is worked. Returns the choice (its value may be null: not stated), or null on
/// Cancel.
Future<(ConstructionKind?,)?> _askConstruction(BuildContext context, ConstructionKind? current) =>
    showDialog<(ConstructionKind?,)>(
      context: context,
      builder: (dialog) => SimpleDialog(
        title: const Text('How is this section worked?'),
        children: [
          for (final c in const [null, ConstructionKind.flat, ConstructionKind.inTheRound])
            SimpleDialogOption(
              key: Key('knit-section-construction-${c?.name ?? 'none'}'),
              onPressed: () => Navigator.pop(dialog, (c,)),
              child: Row(
                children: [
                  Icon(c == current ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                      size: 20),
                  const SizedBox(width: 12),
                  Expanded(child: Text(sectionConstructionLabel(c))),
                ],
              ),
            ),
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 8, 24, 0),
            child:
                Text('Shown with the heading. Ply checks that the work is worked this way when the '
                    'section starts; steps such as "Join in the round" and "Work part of the round '
                    'flat" change how it is worked.'),
          ),
        ],
      ),
    );

Future<void> _addStep(BuildContext context, WidgetRef ref, int sectionIndex) async {
  final kind = await showModalBottomSheet<KnitStepKind>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheet) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          const ListTile(title: Text('Add a step')),
          for (final k in KnitStepKind.values)
            ListTile(
              key: Key('knit-step-kind-${k.name}'),
              title: Text(k.label),
              subtitle: Text(k.help),
              onTap: () => Navigator.pop(sheet, k),
            ),
        ],
      ),
    ),
  );
  if (kind == null || !context.mounted) return;
  final action = await showKnitStepDialog(
    context,
    kind: kind,
    pattern: ref.read(knitEditorProvider).pattern,
  );
  if (action == null) return;
  ref.read(knitEditorProvider.notifier).addStepAt(sectionIndex, action);
}

class _StepTile extends ConsumerWidget {
  const _StepTile({
    required this.pattern,
    required this.sectionIndex,
    required this.section,
    required this.index,
    required this.construction,
  });

  final KnitPatternDto pattern;

  /// The positions of the section and of the step in it (what every edit and lookup goes by).
  final int sectionIndex;
  final KnitSectionDto section;
  final int index;
  final KnitConstructionDto? construction;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final step = section.steps[index];
    final kind = knitStepKind(step.action);
    final notifier = ref.read(knitEditorProvider.notifier);
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final lines = [
      for (final l in construction?.lines ?? const <KnitLedgerLineDto>[])
        if (l.sectionIndex == sectionIndex && l.stepIndex == index) l,
    ];
    final issues = [
      for (final i in construction?.issues ?? const <KnitSectionIssueDto>[])
        if (i.sectionIndex == sectionIndex && i.stepIndex == index) i,
    ];
    return Padding(
      key: Key('knit-step-$sectionIndex-$index-${step.id}'),
      padding: const EdgeInsets.fromLTRB(16, 4, 0, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 28,
            child: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text('${index + 1}', style: text.labelLarge),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (lines.isEmpty) Text(kind.label, style: text.bodyMedium),
                for (final l in lines) ...[
                  Text(
                    l.label == null ? l.text : '${l.label}: ${l.text}',
                    style: text.bodyMedium,
                  ),
                  Text(
                    l.countText,
                    style: text.bodySmall?.copyWith(
                      color: l.countKind == KnitLineCountKind.notCounted
                          ? colors.error
                          : colors.primary,
                    ),
                  ),
                  const SizedBox(height: 2),
                ],
                if (issues.isNotEmpty) _IssueList(issues, dense: true),
              ],
            ),
          ),
          PopupMenuButton<_StepMenu>(
            tooltip: 'Step actions',
            onSelected: (m) async {
              switch (m) {
                case _StepMenu.edit:
                  final action = await showKnitStepDialog(
                    context,
                    kind: kind,
                    pattern: ref.read(knitEditorProvider).pattern,
                    initial: step.action,
                  );
                  if (action != null) notifier.replaceStepAt(sectionIndex, index, action);
                case _StepMenu.up:
                  notifier.moveStepAt(sectionIndex, index, -1);
                case _StepMenu.down:
                  notifier.moveStepAt(sectionIndex, index, 1);
                case _StepMenu.delete:
                  notifier.removeStepAt(sectionIndex, index);
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: _StepMenu.edit, child: Text('Edit')),
              PopupMenuItem(value: _StepMenu.up, enabled: index > 0, child: const Text('Move up')),
              PopupMenuItem(
                  value: _StepMenu.down,
                  enabled: index < section.steps.length - 1,
                  child: const Text('Move down')),
              const PopupMenuItem(value: _StepMenu.delete, child: Text('Delete step')),
            ],
          ),
        ],
      ),
    );
  }
}

/// Problems, errors first, each with its severity icon. [dense] drops the outer padding (under a
/// step).
class _IssueList extends StatelessWidget {
  const _IssueList(this.issues, {this.dense = false});

  final List<KnitSectionIssueDto> issues;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final warning = Theme.of(context).extension<PlyColors>()?.warning ?? const Color(0xFFB26A00);
    final sorted = [
      ...issues.where((i) => i.severity == SeverityKind.error),
      ...issues.where((i) => i.severity != SeverityKind.error),
    ];
    return Padding(
      padding: dense ? const EdgeInsets.only(top: 2, right: 4) : const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final i in sorted)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    i.severity == SeverityKind.error
                        ? Icons.error_outline
                        : Icons.warning_amber_rounded,
                    size: 16,
                    color: i.severity == SeverityKind.error ? colors.error : warning,
                    semanticLabel: i.severity == SeverityKind.error ? 'Error' : 'Warning',
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _issueText(i, dense: dense),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// An issue as shown beside its step (without the place it already sits at, but with its chart
/// row), or in full for the pattern as a whole.
String _issueText(KnitSectionIssueDto i, {required bool dense}) {
  final t = dense ? i.text : (i.sectionId == null ? i.message : i.text);
  final sentence = t.isEmpty ? t : '${t[0].toUpperCase()}${t.substring(1)}';
  return i.chartRow == null || !dense ? sentence : 'Chart row ${i.chartRow}: $t';
}
