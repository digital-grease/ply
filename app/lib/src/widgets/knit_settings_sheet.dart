// Pattern settings: construction (flat vs in-the-round), the first row's worked side (RS/WS), the
// cast-on count, and free-text notes. Construction + first-row-side drive the written-instructions
// wording (Row N (RS) vs Round N) and the RS/WS alternation, so this is where a knitter switches a
// chart from flat to in the round. The cast-on is what row 1 is checked against and the first line
// of the written instructions; it is optional (blank = the pattern does not state one). Each control
// writes back onto the open pattern via the editor notifier.
//
// Construction/side toggles and Clear commit immediately (one discrete undo entry each). Notes and
// the typed cast-on commit ONCE, when their field loses focus (or the sheet closes), so typing doesn't
// spam the undo stack with a snapshot per keystroke.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter, LengthLimitingTextInputFormatter;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../rust/knit_dto.dart';
import '../state/knit_editor_providers.dart';
import '../state/knit_editor_state.dart';
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
  late final TextEditingController _castOn;
  late final FocusNode _castOnFocus;
  // Capture the notifier OBJECT in initState: `ref` itself cannot be used outside build/dispose
  // restrictions, but the captured notifier stays valid for a focus-loss callback.
  late final KnitEditorNotifier _notifier;

  @override
  void initState() {
    super.initState();
    _notifier = ref.read(knitEditorProvider.notifier);
    final pattern = ref.read(knitEditorProvider).pattern;
    _notes = TextEditingController(text: pattern.notes);
    _notesFocus = FocusNode()..addListener(_onNotesFocusChange);
    _castOn = TextEditingController(text: pattern.castOn?.toString() ?? '');
    _castOnFocus = FocusNode()..addListener(_onCastOnFocusChange);
  }

  /// Why the typed cast-on cannot be used, or null when it can (blank = not set, which is fine).
  static String? castOnError(String text) {
    final t = text.trim();
    if (t.isEmpty) return null;
    final n = int.tryParse(t);
    if (n == null || n < 1) return 'Enter at least 1 stitch, or clear it.';
    if (n > KnitEditorState.maxCastOn) return 'Enter at most ${KnitEditorState.maxCastOn} stitches.';
    return null;
  }

  /// Commit the typed cast-on ONCE, when the field loses focus or is submitted: blank clears it, a
  /// usable number sets it, anything else is left uncommitted (its error shows under the field).
  void _commitCastOn() {
    final t = _castOn.text.trim();
    if (castOnError(t) != null) return;
    _notifier.setCastOn(t.isEmpty ? null : int.parse(t));
  }

  void _onCastOnFocusChange() {
    if (!_castOnFocus.hasFocus) _commitCastOn();
  }

  void _clearCastOn() {
    _castOn.clear();
    _notifier.setCastOn(null);
    setState(() {});
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
    _castOnFocus.removeListener(_onCastOnFocusChange);
    _castOnFocus.dispose();
    _castOn.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = text.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);
    final construction = ref.watch(knitEditorProvider.select((s) => s.pattern.construction));
    final side = ref.watch(knitEditorProvider.select((s) => s.pattern.firstRowSide));
    final castOn = ref.watch(knitEditorProvider.select((s) => s.pattern.castOn));
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

            Text('Cast-on', style: text.titleSmall),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('knit-cast-on-field'),
                    controller: _castOn,
                    focusNode: _castOnFocus,
                    keyboardType: TextInputType.number,
                    textInputAction: TextInputAction.done,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(7),
                    ],
                    onChanged: (_) => setState(() {}), // refresh the error and the Clear button
                    onSubmitted: (_) => _commitCastOn(),
                    decoration: InputDecoration(
                      border: const OutlineInputBorder(),
                      labelText: 'Stitches cast on',
                      hintText: 'Not set',
                      suffixText: 'sts',
                      errorText: castOnError(_castOn.text),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: TextButton(
                    key: const Key('knit-cast-on-clear'),
                    // Enabled while there is something to clear: a saved count or typed text.
                    onPressed: castOn == null && _castOn.text.isEmpty ? null : _clearCastOn,
                    child: const Text('Clear'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              inRound
                  ? 'Stitches cast on and joined before round 1. Round 1 is checked against this '
                      'count, and the written instructions start with it. Leave it blank if the '
                      'pattern does not say.'
                  : 'Stitches on the needle before row 1. Row 1 is checked against this count, and '
                      'the written instructions start with it. Leave it blank if the pattern does '
                      'not say.',
              style: muted,
            ),

            const Divider(height: 32),

            Text('Notes', style: text.titleSmall),
            const SizedBox(height: 8),
            TextField(
              key: const Key('knit-notes-field'),
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
