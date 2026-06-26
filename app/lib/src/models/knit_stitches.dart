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
  // Appended shaping stitches — ids are a serialization contract, only ever added at the end (they
  // MUST stay in lockstep with `ply_knit::pattern::builtin`).
  static const int k3tog = 12;
  static const int sk2po = 13;
  static const int ssp = 14;
  static const int kbf = 15;
  static const int pfb = 16;
  static const int m1p = 17;
  static const int m1lp = 18;
  static const int m1rp = 19;
}

/// How the brush picker GROUPS its stitches into collapsible sections. [cables] is a UI-only section
/// (its chips come from the live legend's cable entries + the "add cable" action, not [kKnitBrushes]),
/// so no [KnitBrush] ever carries it.
enum KnitBrushCategory { basic, decreases, increases, cables }

/// A paintable stitch in the editor's brush picker: its builtin id, a label, the shorthand symbol, a
/// plain-language [description] (used by the in-editor stitch legend), and the [category] it groups
/// under in the picker.
class KnitBrush {
  const KnitBrush(this.id, this.label, this.symbol, this.description, this.category);
  final int id;
  final String label;
  final String symbol;
  final String description;
  final KnitBrushCategory category;
}

/// The brushes the editor offers, in picker order. Cables/custom stitches are a later addition (they
/// need the multi-column placement UI); v1 paints the single-column builtins. The [description]s back
/// the in-editor stitch legend / abbreviation key.
const List<KnitBrush> kKnitBrushes = [
  // --- Basic ---
  KnitBrush(KnitStitch.knit, 'Knit', 'k', 'Knit stitch — smooth "V" on the right side.',
      KnitBrushCategory.basic),
  KnitBrush(KnitStitch.purl, 'Purl', 'p', 'Purl stitch — the bump; the reverse of a knit.',
      KnitBrushCategory.basic),
  KnitBrush(KnitStitch.slip, 'Slip', 'sl', 'Slip stitch — move a stitch to the other needle, unworked.',
      KnitBrushCategory.basic),
  KnitBrush(KnitStitch.noStitch, 'No stitch', 'ns',
      'No stitch — a chart placeholder (no stitch worked there).', KnitBrushCategory.basic),
  // --- Decreases ---
  KnitBrush(KnitStitch.k2tog, 'K2tog', 'k2tog',
      'Knit two together — a right-leaning decrease (2 stitches become 1).', KnitBrushCategory.decreases),
  KnitBrush(KnitStitch.ssk, 'Ssk', 'ssk',
      'Slip, slip, knit — a left-leaning decrease (2 stitches become 1).', KnitBrushCategory.decreases),
  KnitBrush(KnitStitch.p2tog, 'P2tog', 'p2tog',
      'Purl two together — a decrease worked from the purl side (2 stitches become 1).',
      KnitBrushCategory.decreases),
  KnitBrush(KnitStitch.cdd, 'Centered dec', 'cdd',
      'Centered double decrease — 3 stitches become 1, centered.', KnitBrushCategory.decreases),
  KnitBrush(KnitStitch.k3tog, 'K3tog', 'k3tog',
      'Knit three together — a right-leaning double decrease (3 stitches become 1).',
      KnitBrushCategory.decreases),
  KnitBrush(KnitStitch.sk2po, 'Sk2po', 'sk2po',
      'Slip 1, knit 2 together, pass over — a left-leaning double decrease (3 become 1).',
      KnitBrushCategory.decreases),
  KnitBrush(KnitStitch.ssp, 'Ssp', 'ssp',
      'Slip, slip, purl — a left-leaning decrease worked on the purl side (2 become 1).',
      KnitBrushCategory.decreases),
  // --- Increases ---
  KnitBrush(KnitStitch.yo, 'Yarn over', 'yo', 'Yarn over — wrap the yarn to add a stitch (an eyelet).',
      KnitBrushCategory.increases),
  KnitBrush(KnitStitch.m1l, 'Make 1 L', 'm1l', 'Make one left — a left-leaning increase (adds 1).',
      KnitBrushCategory.increases),
  KnitBrush(KnitStitch.m1r, 'Make 1 R', 'm1r', 'Make one right — a right-leaning increase (adds 1).',
      KnitBrushCategory.increases),
  KnitBrush(KnitStitch.kfb, 'Kfb', 'kfb', 'Knit front and back — an increase (1 stitch becomes 2).',
      KnitBrushCategory.increases),
  KnitBrush(KnitStitch.kbf, 'Kbf', 'kbf', 'Knit back and front — an increase (1 stitch becomes 2).',
      KnitBrushCategory.increases),
  KnitBrush(KnitStitch.pfb, 'Pfb', 'pfb',
      'Purl front and back — an increase worked on the purl side (1 becomes 2).',
      KnitBrushCategory.increases),
  KnitBrush(KnitStitch.m1p, 'Make 1 P', 'm1p', 'Make one purlwise — a purl increase (adds 1).',
      KnitBrushCategory.increases),
  KnitBrush(KnitStitch.m1lp, 'Make 1 LP', 'm1lp',
      'Make one left purlwise — a left-leaning purl increase (adds 1).', KnitBrushCategory.increases),
  KnitBrush(KnitStitch.m1rp, 'Make 1 RP', 'm1rp',
      'Make one right purlwise — a right-leaning purl increase (adds 1).', KnitBrushCategory.increases),
];
