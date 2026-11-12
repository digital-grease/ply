// The BOOK VIEW's grouping: a derived reading of the per-pick treadling as runs of identical picks.
//
// The per-pick treadling (one row per pick, in DraftDoc) is the CANONICAL form: the engine drawdown,
// WIF I/O, the DTO, and the editor's structural draft grid all consume it unchanged, one row per
// pick. This file only DERIVES a presentation from it: a run of consecutive picks that press the
// SAME shed groups into ONE entry that reads "this shed, N times". The Book view lists the entries;
// its edits map back to explicit per-pick mutations (see EditorState's entry reducers), and the
// entries are re-derived after every edit, so the grouping can never drift from the picks.
//
// This is NOT "Use Tabby" shorthand. Tabby picks interleave the pattern picks, so consecutive-run
// grouping cannot recover them; that needs explicit pattern/tabby pick roles (planned later).

/// One Book view entry: a maximal run of consecutive picks pressing the same shed.
class TreadlingEntry {
  const TreadlingEntry({required this.shed, required this.count, required this.startPick});

  /// The 1-based ids pressed for every pick in the run: treadle ids (treadled) or raised shaft ids
  /// (liftplan). Empty means a pick that presses nothing (a blank shed).
  final List<int> shed;

  /// How many consecutive picks press [shed] (always >= 1).
  final int count;

  /// The 0-based index of the run's FIRST pick in the per-pick model.
  final int startPick;

  /// The 0-based index just past the run's last pick (`startPick + count`).
  int get endPick => startPick + count;
}

/// True when two sheds press the same set of ids, independent of order/duplicates (the model keeps
/// them canonical, but comparing as sets makes the grouping robust to either).
bool sameShed(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  final sa = a.toSet();
  return b.every(sa.contains);
}

/// Group a per-pick [rows] list (treadling or liftplan) into maximal runs of identical sheds, in
/// pick order. The entries' counts sum to `rows.length`; an empty input yields an empty list.
List<TreadlingEntry> treadlingEntries(List<List<int>> rows) {
  final entries = <TreadlingEntry>[];
  var i = 0;
  while (i < rows.length) {
    final shed = rows[i];
    var n = 1;
    while (i + n < rows.length && sameShed(rows[i + n], shed)) {
      n++;
    }
    entries.add(TreadlingEntry(shed: List<int>.unmodifiable(shed), count: n, startPick: i));
    i += n;
  }
  return entries;
}

/// The entry index that the 0-based [pick] falls in, or null if [pick] is out of range. Used to keep
/// a selection anchored to its pick across edits that reshape the runs.
int? entryIndexForPick(List<TreadlingEntry> entries, int pick) {
  for (var e = 0; e < entries.length; e++) {
    if (pick >= entries[e].startPick && pick < entries[e].endPick) return e;
  }
  return null;
}

/// One stretch of consecutive picks inside an entry that share a weft color.
class WeftColorRun {
  const WeftColorRun({required this.color, required this.startPick, required this.count});

  /// The 0-based palette index of the weft color.
  final int color;

  /// The 0-based index of the stretch's first pick.
  final int startPick;

  /// How many consecutive picks carry [color] (always >= 1).
  final int count;
}

/// Every weft color in [entry], in pick order, as maximal stretches of one color. A run whose picks
/// alternate two yarns (a two-color double shot, say) yields one stretch per change, so no color is
/// hidden behind the run's first pick. A [weftColors] list shorter than the draft reads as palette
/// index 0 past its end, the same pad the engine and the editor's weft band use.
List<WeftColorRun> weftColorRuns(TreadlingEntry entry, List<int> weftColors) {
  int colorAt(int pick) => pick < weftColors.length ? weftColors[pick] : 0;
  final runs = <WeftColorRun>[];
  var p = entry.startPick;
  while (p < entry.endPick) {
    final color = colorAt(p);
    var n = 1;
    while (p + n < entry.endPick && colorAt(p + n) == color) {
      n++;
    }
    runs.add(WeftColorRun(color: color, startPick: p, count: n));
    p += n;
  }
  return runs;
}
