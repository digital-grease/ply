// A small, dependency-free RGB color picker dialog. RGB-ONLY by construction: exactly three sliders
// (R/G/B, integer 0..255), a 6-digit #RRGGBB readout, and an always-opaque swatch. There is NO alpha
// slider, NO opacity affordance, and NO editable hex field (slider-first on a phone; the readout is
// orientation-only). It is a pure value-in / value-out widget — FFI-free and Riverpod-free — so the
// caller decides whether to apply the result via setPaletteColor or the add flow.

import 'package:flutter/material.dart';

import '../models/draft_doc.dart';

/// Show the RGB picker seeded with [initial]; resolves to the chosen [DraftColor], or null if the
/// user cancels (Cancel button OR a barrier/back dismissal). [title] labels the dialog ("Add color"
/// from the add flow, "Edit color" when editing a swatch).
Future<DraftColor?> showRgbColorPicker(
  BuildContext context, {
  required DraftColor initial,
  String title = 'Edit color',
}) {
  return showDialog<DraftColor>(
    context: context,
    builder: (_) => _RgbColorPickerDialog(initial: initial, title: title),
  );
}

class _RgbColorPickerDialog extends StatefulWidget {
  const _RgbColorPickerDialog({required this.initial, required this.title});

  final DraftColor initial;
  final String title;

  @override
  State<_RgbColorPickerDialog> createState() => _RgbColorPickerDialogState();
}

class _RgbColorPickerDialogState extends State<_RgbColorPickerDialog> {
  late int _r = widget.initial.r;
  late int _g = widget.initial.g;
  late int _b = widget.initial.b;

  String get _hex {
    String h(int v) => v.toRadixString(16).padLeft(2, '0').toUpperCase();
    return '#${h(_r)}${h(_g)}${h(_b)}';
  }

  @override
  Widget build(BuildContext context) {
    final swatch = Color.fromARGB(255, _r, _g, _b);
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Large live swatch (always opaque) + the read-only hex readout.
          Container(
            height: 64,
            decoration: BoxDecoration(
              color: swatch,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
            ),
          ),
          const SizedBox(height: 8),
          Center(
            child: Text(
              _hex,
              style: const TextStyle(fontFamily: 'monospace', letterSpacing: 1.5),
            ),
          ),
          const SizedBox(height: 8),
          _channel('R', _r, (v) => setState(() => _r = v)),
          _channel('G', _g, (v) => setState(() => _g = v)),
          _channel('B', _b, (v) => setState(() => _b = v)),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, DraftColor(r: _r, g: _g, b: _b)),
          child: const Text('Use color'),
        ),
      ],
    );
  }

  Widget _channel(String label, int value, ValueChanged<int> onChanged) {
    return Row(
      children: [
        SizedBox(width: 16, child: Text(label)),
        Expanded(
          child: Slider(
            min: 0,
            max: 255,
            divisions: 255,
            value: value.toDouble(),
            label: '$value',
            onChanged: (v) => onChanged(v.round()),
          ),
        ),
        SizedBox(width: 32, child: Text('$value', textAlign: TextAlign.end)),
      ],
    );
  }
}
