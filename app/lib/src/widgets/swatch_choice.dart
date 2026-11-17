// "Use a swatch" for the planning calculators (ADR 0016): the swatches of one craft, the ones the
// open project links first. Shown only when there is a swatch to choose, so with no swatches the
// calculators look as they always did.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/material_record.dart';
import '../state/material_providers.dart';
import 'project_materials_sheet.dart' show projectMaterialsProvider;

/// The swatches a calculator for [craft] can use (that craft, or no craft recorded), the ones the
/// open project links first, then in library order.
List<SwatchRecord> swatchesForCraft(WidgetRef ref, SwatchCraft craft) {
  final lib = ref.watch(materialLibraryProvider).valueOrNull;
  if (lib == null || lib.readOnly) return const [];
  final project = ref.watch(openProjectProvider);
  final links = project == null ? null : ref.watch(projectMaterialsProvider(project)).valueOrNull;
  final mine = [
    for (final s in lib.swatches)
      if (s.craft == craft || s.craft == null) s
  ];
  bool linked(SwatchRecord s) => links?.linksSwatch(s.id) ?? false;
  return [...mine.where(linked), ...mine.where((s) => !linked(s))];
}

/// The swatch's one yarn as a material, when it has exactly one and it is in the library (the
/// weighed-swatch yarn estimate needs its length per mass).
MaterialRecord? singleYarnOf(WidgetRef ref, SwatchRecord s) {
  if (s.yarns.length != 1 || s.yarns.first.materialId == null) return null;
  return ref.read(materialLibraryProvider).valueOrNull?.material(s.yarns.first.materialId!);
}

/// A dropdown of [swatches] ("None" first). Renders nothing when there are none.
class SwatchChooser extends StatelessWidget {
  const SwatchChooser({
    required this.swatches,
    required this.selected,
    required this.onChanged,
    this.linkedIds = const {},
    super.key,
  });

  final List<SwatchRecord> swatches;
  final SwatchRecord? selected;
  final ValueChanged<SwatchRecord?> onChanged;
  final Set<String> linkedIds;

  @override
  Widget build(BuildContext context) {
    if (swatches.isEmpty) return const SizedBox.shrink();
    final value = selected == null ? null : swatches.where((s) => s.id == selected!.id).firstOrNull;
    return DropdownButtonFormField<SwatchRecord?>(
      key: const ValueKey('use-swatch'),
      initialValue: value,
      isExpanded: true,
      decoration: const InputDecoration(
        labelText: 'Use a swatch',
        helperText: 'Fills in what the swatch measured, and the estimates say what they took '
            'from it.',
        helperMaxLines: 2,
      ),
      items: [
        const DropdownMenuItem<SwatchRecord?>(value: null, child: Text('None')),
        for (final s in swatches)
          DropdownMenuItem<SwatchRecord?>(
            value: s,
            child: Text(
                '${s.displayName}${s.date == null ? '' : ' (${s.date})'}'
                '${linkedIds.contains(s.id) ? ', linked' : ''}',
                overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: onChanged,
    );
  }
}

/// [v] for a text field the calculator fills in: at most two decimals, no trailing zeros.
String filledNumber(double v) => formatQuantityNumber(v);
