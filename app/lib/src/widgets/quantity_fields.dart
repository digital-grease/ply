// Form fields for unit-aware quantities in the materials and swatch forms (ADR 0016): a number, its
// unit, and where the number came from (measured, or entered from a label, a pattern or a setup).
// A blank field is unknown, never zero. Each entry turns its text back into a recorded value only
// when the text is a number the engine accepts; the forms refuse anything else before saving.

import 'package:flutter/material.dart';

import '../models/draft_doc.dart' show MeasureUnit;
import '../models/material_record.dart';
import '../theme/spacing.dart';

/// The short length unit (swatch sizes, spans) for the app's unit choice.
LengthUnit shortUnitFor(MeasureUnit u) =>
    u == MeasureUnit.centimeters ? LengthUnit.centimeter : LengthUnit.inch;

/// The long length unit (yarn lengths) for the app's unit choice.
LengthUnit longUnitFor(MeasureUnit u) =>
    u == MeasureUnit.centimeters ? LengthUnit.meter : LengthUnit.yard;

/// The units a span or a swatch size is offered in.
const List<LengthUnit> kShortUnits = [
  LengthUnit.centimeter,
  LengthUnit.millimeter,
  LengthUnit.inch
];

/// The units a yarn length is offered in.
const List<LengthUnit> kLongUnits = [LengthUnit.meter, LengthUnit.yard];

/// "Enter a number above 0, or leave it blank." when [text] is not blank and not a positive finite
/// number within the engine's limit; null otherwise.
String? positiveNumberError(String text, {bool allowBlank = true}) {
  final t = text.trim();
  if (t.isEmpty) return allowBlank ? null : 'Enter a number above 0.';
  final v = double.tryParse(t);
  if (v == null || !v.isFinite || v <= 0) return 'Enter a number above 0, or leave it blank.';
  if (v > MaterialLimits.maxValue) return 'This number is too large.';
  return null;
}

double? _number(String text) {
  final v = double.tryParse(text.trim());
  return v != null && v.isFinite && v > 0 && v <= MaterialLimits.maxValue ? v : null;
}

/// A length being edited.
class LengthEntry {
  LengthEntry(
      {Recorded<Length>? initial,
      required LengthUnit defaultUnit,
      this.defaultSource = ValueSource.measured})
      : text = TextEditingController(
            text: initial == null ? '' : exactQuantityNumber(initial.value.value)),
        unit = initial?.value.unit ?? defaultUnit,
        source = initial?.source ?? defaultSource;

  final TextEditingController text;
  LengthUnit unit;
  ValueSource source;
  final ValueSource defaultSource;

  /// The recorded value, or null when blank or not usable.
  Recorded<Length>? get value {
    final v = _number(text.text);
    return v == null ? null : Recorded(Length(v, unit), source);
  }

  String? get error => positiveNumberError(text.text);

  void dispose() => text.dispose();
}

/// A mass being edited.
class MassEntry {
  MassEntry({Recorded<Mass>? initial, this.defaultSource = ValueSource.measured})
      : text = TextEditingController(
            text: initial == null ? '' : exactQuantityNumber(initial.value.value)),
        unit = initial?.value.unit ?? MassUnit.gram,
        source = initial?.source ?? defaultSource;

  final TextEditingController text;
  MassUnit unit;
  ValueSource source;
  final ValueSource defaultSource;

  Recorded<Mass>? get value {
    final v = _number(text.text);
    return v == null ? null : Recorded(Mass(v, unit), source);
  }

  String? get error => positiveNumberError(text.text);

  void dispose() => text.dispose();
}

/// A count over a span being edited: "[20] over [10] [cm]".
class CountEntry {
  CountEntry({
    Recorded<CountOver>? initial,
    required Length defaultSpan,
    this.defaultSource = ValueSource.measured,
  })  : count = TextEditingController(
            text: initial == null ? '' : exactQuantityNumber(initial.value.count)),
        span = TextEditingController(
            text: exactQuantityNumber((initial?.value.over ?? defaultSpan).value)),
        unit = (initial?.value.over ?? defaultSpan).unit,
        source = initial?.source ?? defaultSource;

  final TextEditingController count;
  final TextEditingController span;
  LengthUnit unit;
  ValueSource source;
  final ValueSource defaultSource;

  /// Null when the count is blank (the span alone records nothing) or either number is not usable.
  Recorded<CountOver>? get value {
    final c = _number(count.text);
    final s = _number(span.text);
    if (c == null || s == null) return null;
    return Recorded(CountOver(c, Length(s, unit)), source);
  }

  String? get countError => positiveNumberError(count.text);

  String? get spanError =>
      count.text.trim().isEmpty ? null : positiveNumberError(span.text, allowBlank: false);

  void dispose() {
    count.dispose();
    span.dispose();
  }
}

/// A length per mass being edited: "[200] [m] per [100] [g]".
class LengthPerMassEntry {
  LengthPerMassEntry({
    Recorded<LengthPerMass>? initial,
    required LengthUnit defaultUnit,
    this.defaultSource = ValueSource.entered,
  })  : length = TextEditingController(
            text: initial == null ? '' : exactQuantityNumber(initial.value.length.value)),
        mass = TextEditingController(
            text: initial == null ? '' : exactQuantityNumber(initial.value.mass.value)),
        lengthUnit = initial?.value.length.unit ?? defaultUnit,
        massUnit = initial?.value.mass.unit ?? MassUnit.gram,
        source = initial?.source ?? defaultSource;

  final TextEditingController length;
  final TextEditingController mass;
  LengthUnit lengthUnit;
  MassUnit massUnit;
  ValueSource source;
  final ValueSource defaultSource;

  Recorded<LengthPerMass>? get value {
    final l = _number(length.text);
    final m = _number(mass.text);
    if (l == null || m == null) return null;
    return Recorded(LengthPerMass(Length(l, lengthUnit), Mass(m, massUnit)), source);
  }

  String? get lengthError => positiveNumberError(length.text);

  /// Both numbers are needed once either is given.
  String? get massError {
    if (length.text.trim().isEmpty && mass.text.trim().isEmpty) return null;
    return positiveNumberError(mass.text, allowBlank: false);
  }

  String? get lengthPairError =>
      mass.text.trim().isNotEmpty && length.text.trim().isEmpty ? 'Enter the length too.' : null;

  void dispose() {
    length.dispose();
    mass.dispose();
  }
}

/// Measured or entered, as a small two-way switch.
class SourceToggle extends StatelessWidget {
  const SourceToggle({required this.value, required this.onChanged, this.fieldKey, super.key});

  final ValueSource value;
  final ValueChanged<ValueSource> onChanged;
  final String? fieldKey;

  @override
  Widget build(BuildContext context) => SegmentedButton<ValueSource>(
        key: fieldKey == null ? null : ValueKey('$fieldKey-source'),
        style: const ButtonStyle(visualDensity: VisualDensity.compact),
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(value: ValueSource.measured, label: Text('Measured')),
          ButtonSegment(value: ValueSource.entered, label: Text('Entered')),
        ],
        selected: {value == ValueSource.plyDefault ? ValueSource.entered : value},
        onSelectionChanged: (s) => onChanged(s.first),
      );
}

InputDecoration _decoration(String label, {String? helper, String? error}) => InputDecoration(
      labelText: label,
      helperText: helper,
      helperMaxLines: 3,
      errorText: error,
      errorMaxLines: 2,
      border: const OutlineInputBorder(),
      isDense: true,
    );

Widget _unitPicker<T>(
        {required String key,
        required T value,
        required List<T> options,
        required String Function(T) label,
        required ValueChanged<T> onChanged}) =>
    DropdownButton<T>(
      key: ValueKey(key),
      value: value,
      items: [for (final o in options) DropdownMenuItem(value: o, child: Text(label(o)))],
      onChanged: (v) {
        if (v != null) onChanged(v);
      },
    );

/// A length with its unit and source.
class LengthEntryField extends StatelessWidget {
  const LengthEntryField({
    required this.entry,
    required this.label,
    required this.fieldKey,
    required this.onChanged,
    this.helper,
    this.units = kShortUnits,
    this.showSource = true,
    super.key,
  });

  final LengthEntry entry;
  final String label;
  final String fieldKey;
  final String? helper;
  final List<LengthUnit> units;
  final bool showSource;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final options = units.contains(entry.unit) ? units : [...units, entry.unit];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                key: ValueKey(fieldKey),
                controller: entry.text,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                onChanged: (_) => onChanged(),
                decoration: _decoration(label, helper: helper, error: entry.error),
              ),
            ),
            const SizedBox(width: PlySpacing.sm),
            _unitPicker<LengthUnit>(
              key: '$fieldKey-unit',
              value: entry.unit,
              options: options,
              label: (u) => u.symbol,
              onChanged: (u) {
                entry.unit = u;
                onChanged();
              },
            ),
          ],
        ),
        if (showSource)
          Padding(
            padding: const EdgeInsets.only(top: PlySpacing.xs),
            child: SourceToggle(
              fieldKey: fieldKey,
              value: entry.source,
              onChanged: (s) {
                entry.source = s;
                onChanged();
              },
            ),
          ),
      ],
    );
  }
}

/// A mass with its unit and source.
class MassEntryField extends StatelessWidget {
  const MassEntryField({
    required this.entry,
    required this.label,
    required this.fieldKey,
    required this.onChanged,
    this.helper,
    super.key,
  });

  final MassEntry entry;
  final String label;
  final String fieldKey;
  final String? helper;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  key: ValueKey(fieldKey),
                  controller: entry.text,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  onChanged: (_) => onChanged(),
                  decoration: _decoration(label, helper: helper, error: entry.error),
                ),
              ),
              const SizedBox(width: PlySpacing.sm),
              _unitPicker<MassUnit>(
                key: '$fieldKey-unit',
                value: entry.unit,
                options: MassUnit.values,
                label: (u) => u.symbol,
                onChanged: (u) {
                  entry.unit = u;
                  onChanged();
                },
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: PlySpacing.xs),
            child: SourceToggle(
              fieldKey: fieldKey,
              value: entry.source,
              onChanged: (s) {
                entry.source = s;
                onChanged();
              },
            ),
          ),
        ],
      );
}

/// A count over a span: "[20] sts over [10] [cm]", with its source.
class CountEntryField extends StatelessWidget {
  const CountEntryField({
    required this.entry,
    required this.label,
    required this.noun,
    required this.fieldKey,
    required this.onChanged,
    this.helper,
    super.key,
  });

  final CountEntry entry;
  final String label;

  /// "sts", "rows", "ends", "picks", "wraps".
  final String noun;
  final String fieldKey;
  final String? helper;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final options = kShortUnits.contains(entry.unit) ? kShortUnits : [...kShortUnits, entry.unit];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 3,
              child: TextField(
                key: ValueKey(fieldKey),
                controller: entry.count,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                onChanged: (_) => onChanged(),
                decoration: _decoration('$label ($noun)', error: entry.countError),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(PlySpacing.sm, 12, PlySpacing.sm, 0),
              child: Text('over', style: Theme.of(context).textTheme.bodyMedium),
            ),
            Expanded(
              flex: 2,
              child: TextField(
                key: ValueKey('$fieldKey-span'),
                controller: entry.span,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                onChanged: (_) => onChanged(),
                decoration: _decoration('Span', error: entry.spanError),
              ),
            ),
            const SizedBox(width: PlySpacing.xs),
            _unitPicker<LengthUnit>(
              key: '$fieldKey-unit',
              value: entry.unit,
              options: options,
              label: (u) => u.symbol,
              onChanged: (u) {
                entry.unit = u;
                onChanged();
              },
            ),
          ],
        ),
        if (helper != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
            child: Text(helper!,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ),
        Padding(
          padding: const EdgeInsets.only(top: PlySpacing.xs),
          child: SourceToggle(
            fieldKey: fieldKey,
            value: entry.source,
            onChanged: (s) {
              entry.source = s;
              onChanged();
            },
          ),
        ),
      ],
    );
  }
}

/// A length per mass: "[200] [m] per [100] [g]", with its source.
class LengthPerMassEntryField extends StatelessWidget {
  const LengthPerMassEntryField({
    required this.entry,
    required this.fieldKey,
    required this.onChanged,
    this.helper,
    super.key,
  });

  final LengthPerMassEntry entry;
  final String fieldKey;
  final String? helper;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  key: ValueKey('$fieldKey-length'),
                  controller: entry.length,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  onChanged: (_) => onChanged(),
                  decoration:
                      _decoration('Length', error: entry.lengthError ?? entry.lengthPairError),
                ),
              ),
              const SizedBox(width: PlySpacing.xs),
              _unitPicker<LengthUnit>(
                key: '$fieldKey-length-unit',
                value: entry.lengthUnit,
                options: kLongUnits.contains(entry.lengthUnit)
                    ? kLongUnits
                    : [...kLongUnits, entry.lengthUnit],
                label: (u) => u.symbol,
                onChanged: (u) {
                  entry.lengthUnit = u;
                  onChanged();
                },
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(PlySpacing.sm, 12, PlySpacing.sm, 0),
                child: Text('per', style: Theme.of(context).textTheme.bodyMedium),
              ),
              Expanded(
                child: TextField(
                  key: ValueKey('$fieldKey-mass'),
                  controller: entry.mass,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  onChanged: (_) => onChanged(),
                  decoration: _decoration('Mass', error: entry.massError),
                ),
              ),
              const SizedBox(width: PlySpacing.xs),
              _unitPicker<MassUnit>(
                key: '$fieldKey-mass-unit',
                value: entry.massUnit,
                options: MassUnit.values,
                label: (u) => u.symbol,
                onChanged: (u) {
                  entry.massUnit = u;
                  onChanged();
                },
              ),
            ],
          ),
          if (helper != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
              child: Text(helper!,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
            ),
          Padding(
            padding: const EdgeInsets.only(top: PlySpacing.xs),
            child: SourceToggle(
              fieldKey: fieldKey,
              value: entry.source,
              onChanged: (s) {
                entry.source = s;
                onChanged();
              },
            ),
          ),
        ],
      );
}
