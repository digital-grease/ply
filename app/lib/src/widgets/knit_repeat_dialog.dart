import 'package:flutter/material.dart';

import '../rust/knit_dto.dart';

/// What the repeat dialog decided: mark the selected stitches as a repeat, or remove the repeats
/// they overlap.
sealed class RepeatChoice {
  const RepeatChoice();
}

/// Mark the selection as a repeat worked [count] (a number of times, or to the end of the row).
class MarkRepeatChoice extends RepeatChoice {
  const MarkRepeatChoice(this.count);
  final RepeatDto count;
}

/// Remove the repeats the selection overlaps.
class RemoveRepeatChoice extends RepeatChoice {
  const RemoveRepeatChoice();
}

/// The most times the dialog's stepper offers for a new repeat (wider rows are usually "to the end
/// of the row"). A larger count already on the selected repeat is kept as the ceiling.
const int kMaxRepeatTimes = 99;

/// Ask how the selected stitches repeat. [where] names the selection for the knitter (see
/// [describeRepeatSelection]); [canRemove] offers "Remove repeat" when the selection overlaps an
/// existing repeat; [initial] preselects a repeat already marked on exactly these stitches. Resolves
/// null on cancel.
Future<RepeatChoice?> showRepeatDialog(
  BuildContext context, {
  required String where,
  required bool canRemove,
  RepeatDto? initial,
}) {
  return showDialog<RepeatChoice>(
    context: context,
    builder: (_) => _RepeatDialog(where: where, canRemove: canRemove, initial: initial),
  );
}

/// "Stitches 2 to 5, row 3" (or "rows 1 to 4") for the storage selection cols [colMin]..[colMax],
/// rows [rowMin]..[rowMax] on a chart [width] stitches wide. Stitches are numbered as the chart's
/// bottom axis numbers them (right to left, the right-side reading order); rows count up from 1.
String describeRepeatSelection(
    {required int colMin, required int colMax, required int rowMin, required int rowMax, required int width}) {
  final a = width - colMax;
  final b = width - colMin;
  final stitches = a == b ? 'Stitch $a' : 'Stitches $a to $b';
  final rows = rowMin == rowMax ? 'row ${rowMin + 1}' : 'rows ${rowMin + 1} to ${rowMax + 1}';
  return '$stitches, $rows';
}

class _RepeatDialog extends StatefulWidget {
  const _RepeatDialog({required this.where, required this.canRemove, this.initial});

  final String where;
  final bool canRemove;
  final RepeatDto? initial;

  @override
  State<_RepeatDialog> createState() => _RepeatDialogState();
}

class _RepeatDialogState extends State<_RepeatDialog> {
  late bool _toEnd = widget.initial is RepeatDto_ToEnd;
  // A count already authored above the stepper's usual ceiling (from a file) is kept, never clamped.
  late final int _max = switch (widget.initial) {
    RepeatDto_Times(:final count) when count > kMaxRepeatTimes => count,
    _ => kMaxRepeatTimes,
  };
  late int _times = switch (widget.initial) {
    RepeatDto_Times(:final count) => count.clamp(1, _max),
    _ => 2,
  };

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final small = Theme.of(context).textTheme.bodySmall?.copyWith(color: muted);
    return AlertDialog(
      title: const Text('Repeat stitches'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(widget.where, style: small),
          const SizedBox(height: 12),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('Times')),
              ButtonSegment(value: true, label: Text('To end')),
            ],
            selected: {_toEnd},
            onSelectionChanged: (s) => setState(() => _toEnd = s.first),
          ),
          const SizedBox(height: 8),
          if (!_toEnd)
            Row(
              children: [
                const Expanded(child: Text('Number of times')),
                IconButton(
                  tooltip: 'Fewer times',
                  icon: const Icon(Icons.remove),
                  onPressed: _times > 1 ? () => setState(() => _times--) : null,
                ),
                SizedBox(width: 28, child: Text('$_times', textAlign: TextAlign.center)),
                IconButton(
                  tooltip: 'More times',
                  icon: const Icon(Icons.add),
                  onPressed: _times < _max ? () => setState(() => _times++) : null,
                ),
              ],
            ),
          Text(
            _toEnd
                ? 'Repeated across the row as many times as the stitches allow.'
                : 'Worked $_times ${_times == 1 ? 'time' : 'times'} in all.',
            style: small,
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        if (widget.canRemove)
          TextButton(
            onPressed: () => Navigator.pop(context, const RemoveRepeatChoice()),
            child: const Text('Remove repeat'),
          ),
        FilledButton(
          onPressed: () => Navigator.pop(
            context,
            MarkRepeatChoice(_toEnd ? const RepeatDto.toEnd() : RepeatDto.times(count: _times)),
          ),
          child: const Text('Mark repeat'),
        ),
      ],
    );
  }
}
