// The canonical spacing scale, named once so the rest of the UI stops sprinkling magic numbers
// through `EdgeInsets`/`SizedBox`. The editor had settled on ~four recurring gaps (8/12/16/24
// logical px); pinning them as named constants makes layout intent readable at call sites
// (`PlySpacing.md` over a bare `16`) and lets the M4 theming pass retune the whole rhythm in one
// place. An `abstract final` class is just a namespace — it cannot be instantiated or subclassed,
// so these are accessed only as `PlySpacing.xs` etc.

/// Canonical spacing scale (logical px). Use instead of magic `EdgeInsets`/`SizedBox` numbers.
abstract final class PlySpacing {
  /// Tight gap: between an icon and its label, or inside a compact row.
  static const double xs = 8;

  /// Small gap: a snug horizontal/vertical padding.
  static const double sm = 12;

  /// Medium gap: the default content padding / inter-element spacing.
  static const double md = 16;

  /// Large gap: separating major sections or framing a panel.
  static const double lg = 24;
}
