// The COMPRESSED ("book") treadling view: a derived, collapsed reading of the per-pick treadling.
//
// The per-pick treadling (one row per pick, in DraftDoc) stays the CANONICAL form — the engine
// drawdown, WIF I/O, and the DTO all consume it unchanged. This file derives the overshot/book
// shorthand from it: a run of consecutive picks that press the SAME shed collapses to ONE entry that
// reads "press this shed, N times". The editor renders + edits the entries; the edits map back to
// per-pick mutations (see EditorState's entry reducers), so nothing downstream of the editor changes.

/// One compressed treadling entry: a maximal run of consecutive picks pressing the same shed.
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
/// them canonical, but comparing as sets makes the collapse robust to either).
bool sameShed(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  final sa = a.toSet();
  return b.every(sa.contains);
}

/// Collapse a per-pick [rows] list (treadling or liftplan) into maximal runs of identical sheds, in
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
/// a selection stable across edits that reshape the runs.
int? entryIndexForPick(List<TreadlingEntry> entries, int pick) {
  for (var e = 0; e < entries.length; e++) {
    if (pick >= entries[e].startPick && pick < entries[e].endPick) return e;
  }
  return null;
}
