import 'package:flutter/material.dart';

import '../rust/knit_dto.dart';

/// Build a custom cable: front/back stitch counts, cross direction, and optional purled strands.
/// Returns the [CableDefDto] on confirm, or null on cancel. Stateless on close (no controllers to
/// leak), so it is safe to create + dispose around a single `await`.
Future<CableDefDto?> showCableBuilder(BuildContext context) {
  return showDialog<CableDefDto>(context: context, builder: (_) => const _CableBuilderDialog());
}

/// A readable label for a cable, e.g. "2/2 RC" (front/back stitches + cross direction).
String cableSymbol(CableDefDto c) {
  final dir = c.direction == CrossKind.right ? 'RC' : 'LC';
  return '${c.front}/${c.back} $dir';
}

class _CableBuilderDialog extends StatefulWidget {
  const _CableBuilderDialog();

  @override
  State<_CableBuilderDialog> createState() => _CableBuilderDialogState();
}

class _CableBuilderDialogState extends State<_CableBuilderDialog> {
  int _front = 2;
  int _back = 2;
  CrossKind _dir = CrossKind.right;
  bool _frontPurl = false;
  bool _backPurl = false;

  static const int _min = 1;
  static const int _max = 4;

  @override
  Widget build(BuildContext context) {
    final cable = CableDefDto(
      front: _front,
      back: _back,
      direction: _dir,
      frontPurl: _frontPurl,
      backPurl: _backPurl,
    );
    final text = Theme.of(context).textTheme;
    return AlertDialog(
      title: const Text('New cable'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _counter('Front stitches', _front, (v) => setState(() => _front = v)),
          _counter('Back stitches', _back, (v) => setState(() => _back = v)),
          const SizedBox(height: 8),
          SegmentedButton<CrossKind>(
            segments: const [
              ButtonSegment(value: CrossKind.right, label: Text('Right cross')),
              ButtonSegment(value: CrossKind.left, label: Text('Left cross')),
            ],
            selected: {_dir},
            onSelectionChanged: (s) => setState(() => _dir = s.first),
          ),
          CheckboxListTile(
            value: _frontPurl,
            dense: true,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text('Purl the front strand'),
            onChanged: (v) => setState(() => _frontPurl = v ?? false),
          ),
          CheckboxListTile(
            value: _backPurl,
            dense: true,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text('Purl the back strand'),
            onChanged: (v) => setState(() => _backPurl = v ?? false),
          ),
          const SizedBox(height: 4),
          Text(
            'Spans ${_front + _back} stitches  ·  ${cableSymbol(cable)}',
            style: text.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, cable), child: const Text('Add cable')),
      ],
    );
  }

  Widget _counter(String label, int value, ValueChanged<int> onChanged) {
    return Row(
      children: [
        Expanded(child: Text(label)),
        IconButton(
          tooltip: 'Fewer',
          icon: const Icon(Icons.remove),
          onPressed: value > _min ? () => onChanged(value - 1) : null,
        ),
        SizedBox(width: 24, child: Text('$value', textAlign: TextAlign.center)),
        IconButton(
          tooltip: 'More',
          icon: const Icon(Icons.add),
          onPressed: value < _max ? () => onChanged(value + 1) : null,
        ),
      ],
    );
  }
}
