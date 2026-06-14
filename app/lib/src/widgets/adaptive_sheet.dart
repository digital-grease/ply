import 'package:flutter/material.dart';

import '../util/responsive.dart';

/// Show [child] as a modal bottom sheet on phones, or a centered, content-sized dialog on
/// tablet/wide screens (where a full-width bottom sheet wastes horizontal space). Returns the same
/// `Future<T?>` either way, so callers stay layout-agnostic.
///
/// The three sheet bodies (PlanningSheet / PaletteSheet / StructureSheet) each supply their own
/// `SafeArea` + `SingleChildScrollView` (with keyboard-inset avoidance), so each scrolls within
/// whatever height it is given. The dialog path therefore deliberately does NOT add another
/// `SingleChildScrollView`/padding wrapper — that would double-pad and nest two scroll views. It
/// only constrains the width and lets the body lay itself out and scroll within the dialog's
/// height. The bottom-sheet path is byte-for-byte the same `showModalBottomSheet` call before.
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
