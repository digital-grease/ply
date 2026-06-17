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

/// A paintable stitch in the editor's brush picker: its builtin id, a label, the shorthand symbol, and
/// a plain-language [description] (used by the in-editor stitch legend).
class KnitBrush {
  const KnitBrush(this.id, this.label, this.symbol, this.description);
  final int id;
  final String label;
  final String symbol;
  final String description;
}

/// The brushes the editor offers, in picker order. Cables/custom stitches are a later addition (they
/// need the multi-column placement UI); v1 paints the single-column builtins. The [description]s back
/// the in-editor stitch legend / abbreviation key.
const List<KnitBrush> kKnitBrushes = [
  KnitBrush(KnitStitch.knit, 'Knit', 'k', 'Knit stitch — smooth "V" on the right side.'),
  KnitBrush(KnitStitch.purl, 'Purl', 'p', 'Purl stitch — the bump; the reverse of a knit.'),
  KnitBrush(KnitStitch.yo, 'Yarn over', 'yo', 'Yarn over — wrap the yarn to add a stitch (an eyelet).'),
  KnitBrush(KnitStitch.k2tog, 'K2tog', 'k2tog',
      'Knit two together — a right-leaning decrease (2 stitches become 1).'),
  KnitBrush(KnitStitch.ssk, 'Ssk', 'ssk',
      'Slip, slip, knit — a left-leaning decrease (2 stitches become 1).'),
  KnitBrush(KnitStitch.cdd, 'Centered dec', 'cdd',
      'Centered double decrease — 3 stitches become 1, centered.'),
  KnitBrush(KnitStitch.m1l, 'Make 1 L', 'm1l', 'Make one left — a left-leaning increase (adds 1).'),
  KnitBrush(KnitStitch.m1r, 'Make 1 R', 'm1r', 'Make one right — a right-leaning increase (adds 1).'),
  KnitBrush(KnitStitch.kfb, 'Kfb', 'kfb', 'Knit front and back — an increase (1 stitch becomes 2).'),
  KnitBrush(KnitStitch.slip, 'Slip', 'sl', 'Slip stitch — move a stitch to the other needle, unworked.'),
  KnitBrush(KnitStitch.noStitch, 'No stitch', 'ns',
      'No stitch — a chart placeholder (no stitch worked there).'),
];
