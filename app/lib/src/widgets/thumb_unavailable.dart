import 'package:flutter/material.dart';

/// A library tile whose picture cannot be read or drawn (ADR 0021): a "no preview" mark that says
/// so in a tooltip and to a screen reader, never the ordinary empty placeholder.
Widget thumbUnavailable(BuildContext context) {
  const why = 'No preview: Ply could not draw this project. Open it to see why.';
  final colors = Theme.of(context).colorScheme;
  return Tooltip(
    message: why,
    child: Semantics(
      label: why,
      child: ColoredBox(
        color: colors.surfaceContainerHighest,
        child: Center(child: Icon(Icons.broken_image_outlined, color: colors.outline)),
      ),
    ),
  );
}
