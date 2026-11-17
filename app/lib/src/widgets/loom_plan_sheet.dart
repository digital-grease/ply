// "Loom for this draft": choose which of My looms the open draft is planned for, and the sett for
// the width and reed checks (ADR 0014). The choice is saved with the draft (its sidecar), never in
// the WIF; changing it makes the draft unsaved like any edit.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/draft_doc.dart' show MeasureUnit;
import '../models/loom_check.dart';
import '../models/loom_profile.dart';
import '../state/draft_editor_notifier.dart';
import '../state/loom_providers.dart';
import '../theme/spacing.dart';
import 'adaptive_sheet.dart';

/// The menu entry and sheet title.
const String kLoomForDraftTitle = 'Loom for this draft';

/// What the sheet returns: the new plan (null = no loom).
class LoomPlanChoice {
  const LoomPlanChoice(this.plan);

  final LoomPlan? plan;
}

/// Open the chooser for the open draft and apply the choice to [draftLoomPlanProvider].
Future<void> chooseLoomForDraft(BuildContext context, WidgetRef ref) async {
  List<LoomProfile> looms = const [];
  String? unusable;
  try {
    final library = await ref.read(loomLibraryProvider.future);
    looms = library.looms;
    unusable = library.readOnly ? library.readOnlyReason : null;
  } catch (_) {
    unusable = 'My looms could not be read.'; // the current choice can still be cleared
  }
  final draft = ref.read(draftEditorProvider).draft;
  Sett? fileSett;
  try {
    fileSett = await ref.read(loomRepositoryProvider).fileSett(draft);
  } catch (_) {/* the file's sett is a hint only */}
  if (!context.mounted) return;
  final choice = await showAdaptiveSheet<LoomPlanChoice>(
    context,
    child: LoomPlanSheet(
      looms: looms,
      current: ref.read(draftLoomPlanProvider),
      fileSett: fileSett,
      defaultUnit: draft.unit,
      unusableReason: unusable,
    ),
  );
  if (choice == null) return;
  ref.read(draftLoomPlanProvider.notifier).state = choice.plan;
}

class LoomPlanSheet extends StatefulWidget {
  const LoomPlanSheet({
    required this.looms,
    required this.current,
    required this.fileSett,
    required this.defaultUnit,
    this.unusableReason,
    super.key,
  });

  final List<LoomProfile> looms;
  final LoomPlan? current;

  /// The sett the draft's file gives, shown as a hint.
  final Sett? fileSett;

  /// The unit the sett field starts in when nothing else says.
  final MeasureUnit defaultUnit;

  /// Why My looms cannot be used now (a newer or unreadable file), or null when it can. The looms
  /// are then not offered, and the draft's loom is shown as not checked rather than missing.
  final String? unusableReason;

  @override
  State<LoomPlanSheet> createState() => _LoomPlanSheetState();
}

class _LoomPlanSheetState extends State<LoomPlanSheet> {
  late String? _selected = widget.current?.loomId;
  late final TextEditingController _sett = TextEditingController(
      text: widget.current?.sett == null ? '' : exactLoomNumber(widget.current!.sett!.ends));
  late MeasureUnit _per = widget.current?.sett?.per ?? widget.fileSett?.per ?? widget.defaultUnit;
  String? _settError;

  @override
  void dispose() {
    _sett.dispose();
    super.dispose();
  }

  bool get _currentMissing =>
      widget.current != null && widget.looms.every((l) => l.id != widget.current!.loomId);

  /// The sett entered, null when blank; sets [_settError] and returns false when it cannot be used.
  (bool, Sett?) _readSett() {
    final text = _sett.text.trim();
    if (text.isEmpty) return (true, null);
    final value = double.tryParse(text);
    final sett = value == null ? null : Sett(value, _per);
    if (sett == null || !sett.isValid) {
      final max = _per == MeasureUnit.inches ? '1000 ends per inch' : '393 ends per cm';
      setState(() => _settError = 'Enter a sett above 0 and up to $max, or leave it blank.');
      return (false, null);
    }
    return (true, sett);
  }

  void _done() {
    final (ok, sett) = _readSett();
    if (!ok) return;
    final id = _selected;
    if (id == null) {
      Navigator.of(context).pop(const LoomPlanChoice(null));
      return;
    }
    final loom = widget.looms.where((l) => l.id == id).firstOrNull;
    final current = widget.current;
    final name = loom?.name ?? current?.loomName ?? '';
    final plan = current != null && current.loomId == id
        ? current.copyWith(loomName: name, sett: sett, clearSett: sett == null)
        : LoomPlan(loomId: id, loomName: name, sett: sett);
    Navigator.of(context).pop(LoomPlanChoice(plan));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final fileSett = widget.fileSett;
    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(PlySpacing.md, 0, PlySpacing.md,
            PlySpacing.md + MediaQuery.viewInsetsOf(context).bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(kLoomForDraftTitle, style: theme.textTheme.titleLarge),
            const SizedBox(height: PlySpacing.xs),
            Text(
              'Ply checks the draft against the loom you choose: its shafts, treadles, width and '
              'reeds. The choice is saved with the draft.',
              style: muted,
            ),
            const SizedBox(height: PlySpacing.sm),
            RadioGroup<String?>(
              groupValue: _selected,
              onChanged: (v) => setState(() => _selected = v),
              child: Column(
                children: [
                  const RadioListTile<String?>(
                    value: null,
                    title: Text('No loom'),
                    contentPadding: EdgeInsets.zero,
                  ),
                  for (final loom in widget.looms)
                    RadioListTile<String?>(
                      value: loom.id,
                      title: Text(loom.displayName),
                      subtitle: Text(loom.summary),
                      contentPadding: EdgeInsets.zero,
                    ),
                  if (_currentMissing)
                    RadioListTile<String?>(
                      value: widget.current!.loomId,
                      title: Text(widget.current!.displayName),
                      subtitle: Text(widget.unusableReason == null
                          ? 'Not in My looms'
                          : 'Not checked: My looms cannot be used now'),
                      contentPadding: EdgeInsets.zero,
                    ),
                ],
              ),
            ),
            if (widget.unusableReason != null)
              Padding(
                padding: const EdgeInsets.only(bottom: PlySpacing.sm),
                child: Text(widget.unusableReason!, style: muted),
              )
            else if (widget.looms.isEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: PlySpacing.sm),
                child: Text('You have no looms yet. Add them in Settings, under My looms.',
                    style: muted),
              ),
            const Divider(height: PlySpacing.lg),
            Text('Sett for the width and reed checks', style: theme.textTheme.titleSmall),
            const SizedBox(height: PlySpacing.xs),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('loom-plan-sett'),
                    controller: _sett,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                      labelText: 'Sett',
                      hintText: fileSett == null ? null : formatLoomNumber(fileSett.ends),
                      errorText: _settError,
                      border: const OutlineInputBorder(),
                    ),
                    onChanged: (_) {
                      if (_settError != null) setState(() => _settError = null);
                    },
                  ),
                ),
                const SizedBox(width: PlySpacing.sm),
                SegmentedButton<MeasureUnit>(
                  segments: const [
                    ButtonSegment(value: MeasureUnit.inches, label: Text('per inch')),
                    ButtonSegment(value: MeasureUnit.centimeters, label: Text('per cm')),
                  ],
                  selected: {_per},
                  showSelectedIcon: false,
                  onSelectionChanged: (s) => setState(() => _per = s.first),
                ),
              ],
            ),
            const SizedBox(height: PlySpacing.xs),
            Text(
              fileSett == null
                  ? 'Ends in the reed per inch or per cm. Leave it blank if you do not know it yet.'
                  : 'The file gives ${fileSett.label}. Leave it blank to use that.',
              style: muted,
            ),
            const SizedBox(height: PlySpacing.md),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                    onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
                const SizedBox(width: PlySpacing.xs),
                FilledButton(onPressed: _done, child: const Text('Done')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
