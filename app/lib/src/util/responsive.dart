import 'package:flutter/widgets.dart';

/// The single tablet/wide breakpoint (logical px). At or above it the UI switches to its
/// space-filling layout: a wider Library grid, a side-rail editor (controls beside the cloth rather
/// than crushing it below in landscape), and dialogs instead of bottom sheets. 600 is Material's
/// compact -> medium boundary.
const double kWideBreakpoint = 600;

/// True on a tablet / wide / landscape viewport (width at or above [kWideBreakpoint]).
bool isWide(BuildContext context) => MediaQuery.sizeOf(context).width >= kWideBreakpoint;
