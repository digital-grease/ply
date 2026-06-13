import 'package:flutter/material.dart';

import '../util/responsive.dart';

/// Show [child] as a modal bottom sheet on phones, or a centered, content-sized dialog on
/// tablet/wide screens (where a full-width bottom sheet wastes horizontal space). Returns the same
/// `Future<T?>` either way, so callers stay layout-agnostic.
///
/// The three sheet bodies (PlanningSheet / PaletteSheet / StructureSheet) already supply their own
/// `SafeArea` + padding (and, for the tall ones, their own `SingleChildScrollView` with
/// keyboard-inset avoidance). So the dialog path deliberately does NOT add another
/// `SingleChildScrollView`/padding wrapper — that would double-pad and, on the scrolling bodies,
/// nest two scroll views. It only constrains the width and lets the body lay itself out. The
/// bottom-sheet path is byte-for-byte the same `showModalBottomSheet` call the sheets used before.
Future<T?> showAdaptiveSheet<T>(BuildContext context, {required Widget child}) {
  if (isWide(context)) {
    return showDialog<T>(
      context: context,
      builder: (_) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: child,
        ),
      ),
    );
  }
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => child,
  );
}
