// Pattern settings: construction (flat vs in-the-round), the first row's worked side (RS/WS), and
// free-text notes. Construction + first-row-side drive the written-instructions wording (Row N (RS)
// vs Round N) and the RS/WS alternation, so this is where a knitter switches a chart from flat to in
// the round. Each control writes back onto the open pattern via the editor notifier.
//
// Construction/side toggles commit immediately (one discrete undo entry each). Notes commit ONCE,
// when the sheet closes, so typing doesn't spam the undo stack with a snapshot per keystroke.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../rust/knit_dto.dart';
import '../state/knit_editor_providers.dart';
import 'adaptive_sheet.dart';

/// Open the pattern-settings sheet. Call from a context inside the editor's ProviderScope.
Future<void> showKnitSettingsSheet(BuildContext context) {
  return showAdaptiveSheet<void>(context, child: const KnitSettingsSheet());
}

class KnitSettingsSheet extends ConsumerStatefulWidget {
  const KnitSettingsSheet({super.key});

  @override
  ConsumerState<KnitSettingsSheet> createState() => _KnitSettingsSheetState();
}

class _KnitSettingsSheetState extends ConsumerState<KnitSettingsSheet> {
  late final TextEditingController _notes;
  late final FocusNode _notesFocus;
  // Capture the notifier OBJECT in initState: `ref` itself cannot be used outside build/dispose
  // restrictions, but the captured notifier stays valid for a focus-loss callback.
  late final KnitEditorNotifier _notifier;

  @override
  void initState() {
    super.initState();
    _notifier = ref.read(knitEditorProvider.notifier);
    _notes = TextEditingController(text: ref.read(knitEditorProvider).pattern.notes);
    _notesFocus = FocusNode()..addListener(_onNotesFocusChange);
  }

  /// Commit the notes ONCE, when the field loses focus (tapping away or closing the sheet), so a
  /// whole edit is a single undo entry rather than one snapshot per keystroke. Focus callbacks fire
  /// BETWEEN frames, so modifying the provider here is safe — unlike `dispose`, where modifying a
  /// provider throws "tried to modify a provider while the widget tree was building".
  void _onNotesFocusChange() {
    if (!_notesFocus.hasFocus) _notifier.setNotes(_notes.text);
  }

  @override
  void dispose() {
    // Remove the listener BEFORE disposing the node, so the node's own unfocus-on-dispose can't fire
    // the commit during teardown (which would be a modify-during-build). A genuine focus loss during
    // the sheet's dismiss has already committed by then.
    _notesFocus.removeListener(_onNotesFocusChange);
    _notesFocus.dispose();
    _notes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = text.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);
    final construction = ref.watch(knitEditorProvider.select((s) => s.pattern.construction));
    final side = ref.watch(knitEditorProvider.select((s) => s.pattern.firstRowSide));
    final inRound = construction == ConstructionKind.inTheRound;
    final notifier = ref.read(knitEditorProvider.notifier);

    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 24 + MediaQuery.viewInsetsOf(context).bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Pattern settings', style: text.titleMedium),
            const SizedBox(height: 16),

            Text('Construction', style: text.titleSmall),
            const SizedBox(height: 8),
            SegmentedButton<ConstructionKind>(
              segments: const [
                ButtonSegment(
                  value: ConstructionKind.flat,
                  label: Text('Flat'),
                  icon: Icon(Icons.swap_horiz),
                ),
                ButtonSegment(
                  value: ConstructionKind.inTheRound,
                  label: Text('In the round'),
                  icon: Icon(Icons.loop),
                ),
              ],
              selected: {construction},
              onSelectionChanged: (s) => notifier.setConstruction(s.first),
            ),
            const SizedBox(height: 6),
            Text(
              inRound
                  ? 'Worked in the round: every row is a right-side round.'
                  : 'Worked flat: rows alternate right-side and wrong-side.',
              style: muted,
            ),

            const Divider(height: 32),

            Text('First row side', style: text.titleSmall),
            const SizedBox(height: 8),
            SegmentedButton<SideKind>(
              segments: const [
                ButtonSegment(value: SideKind.rs, label: Text('Right side')),
                ButtonSegment(value: SideKind.ws, label: Text('Wrong side')),
              ],
              selected: {side},
              // In the round there is no wrong-side row, so the choice is inert — disable it.
              onSelectionChanged: inRound ? null : (s) => notifier.setFirstRowSide(s.first),
            ),
            const SizedBox(height: 6),
            Text(
              inRound
                  ? 'Not used in the round (every round is worked from the right side).'
                  : 'Which side chart row 1 (the cast-on edge) is worked from.',
              style: muted,
            ),

            const Divider(height: 32),

            Text('Notes', style: text.titleSmall),
            const SizedBox(height: 8),
            TextField(
              controller: _notes,
              focusNode: _notesFocus,
              minLines: 3,
              maxLines: 6,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: 'Yarn, needles, finishing, anything to remember…',
              ),
            ),
          ],
        ),
      ),
    );
  }
}
