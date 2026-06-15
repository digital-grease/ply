/// Builtin stitch legend ids — these MUST match `ply_knit::pattern::builtin` (the order
/// `StitchLegend::builtin()` seeds), which a pattern from `knitBlankPattern` carries. The editor
/// paints by these ids; the engine's legend gives them meaning (consumes/produces/symbol).
class KnitStitch {
  const KnitStitch._();

  static const int noStitch = 0;
  static const int knit = 1;
  static const int purl = 2;
  static const int yo = 3;
  static const int k2tog = 4;
  static const int ssk = 5;
  static const int p2tog = 6;
  static const int cdd = 7;
  static const int m1l = 8;
  static const int m1r = 9;
  static const int kfb = 10;
  static const int slip = 11;
}

/// A paintable stitch in the editor's brush picker: its builtin id, a label, and the shorthand symbol.
class KnitBrush {
  const KnitBrush(this.id, this.label, this.symbol);
  final int id;
  final String label;
  final String symbol;
}

/// The brushes the editor offers, in picker order. Cables/custom stitches are a later addition (they
/// need the multi-column placement UI); v1 paints the single-column builtins.
const List<KnitBrush> kKnitBrushes = [
  KnitBrush(KnitStitch.knit, 'Knit', 'k'),
  KnitBrush(KnitStitch.purl, 'Purl', 'p'),
  KnitBrush(KnitStitch.yo, 'Yarn over', 'yo'),
  KnitBrush(KnitStitch.k2tog, 'K2tog', 'k2tog'),
  KnitBrush(KnitStitch.ssk, 'Ssk', 'ssk'),
  KnitBrush(KnitStitch.cdd, 'Centered dec', 'cdd'),
  KnitBrush(KnitStitch.m1l, 'Make 1 L', 'm1l'),
  KnitBrush(KnitStitch.m1r, 'Make 1 R', 'm1r'),
  KnitBrush(KnitStitch.kfb, 'Kfb', 'kfb'),
  KnitBrush(KnitStitch.slip, 'Slip', 'sl'),
  KnitBrush(KnitStitch.noStitch, 'No stitch', 'ns'),
];
