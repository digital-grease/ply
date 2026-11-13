// How the weft is worked beyond its sheds (roadmap M8-06): shot groups (double shots and longer),
// shuttles and the direction of every pass, and strands per pick.
//
// The per-pick draft stays the source of truth. A SHOT GROUP is an explicit instruction that names
// consecutive picks worked as repeated passes in ONE shed; consecutive picks with the same shed and
// no group stay separate picks (the weaver changes the shed between them). Every group must stay on
// one shed, so every edit that inserts, removes, or re-sheds picks keeps the groups on the right
// picks with these rules (the engine applies the same ones on resize and on a shed conversion):
//
//   * insert BEFORE a group (at or before its first pick): the group shifts; insert after its last
//     pick: unchanged, unless the edit is the Book view count of that group's own row, which adds
//     passes to it; insert INSIDE a group: the group grows over the new picks, and then
//   * a group whose picks no longer share one shed (an inserted pick in another shed, a member whose
//     shed changed, a treadle pruned by a resize) keeps only its maximal one-shed runs of at least two
//     picks: it shrinks, splits, or dissolves (the editor says so when that happens);
//   * remove picks: a group keeps its remaining members (still consecutive and one shed) when at
//     least two remain, otherwise it dissolves; groups after the removal shift back.
//
// The DIRECTION of a pass is never stored: every shuttle alternates its own direction from its
// starting side, so it follows from the shuttles (see [passStarts], the Dart twin of the engine's
// `Draft::pass_starts`; both suites test the same cases).

import 'double_weave_layers.dart' show raisedShafts;
import 'draft_doc.dart';
import 'use_tabby.dart' show describePicks;

// ---------------------------------------------------------------------------
// Words
// ---------------------------------------------------------------------------

/// "Double shot", "Triple shot", or "4 passes in one shed" for a shot group of [passes] picks.
String shotGroupLabel(int passes) => switch (passes) {
      2 => 'Double shot',
      3 => 'Triple shot',
      _ => '$passes passes in one shed',
    };

/// [shotGroupLabel] with its meaning: "Double shot (2 passes in one shed)", "Triple shot (3 passes in
/// one shed)", or "4 passes in one shed".
String shotGroupDescription(int passes) => passes == 2 || passes == 3
    ? '${shotGroupLabel(passes)} ($passes passes in one shed)'
    : shotGroupLabel(passes);

/// [shotGroupLabel] inside a sentence: "a double shot", "a triple shot", "4 passes in one shed".
String shotGroupPhrase(int passes) => passes == 2 || passes == 3
    ? 'a ${shotGroupLabel(passes).toLowerCase()}'
    : shotGroupLabel(passes);

/// The arrow for a pass that starts from [start]: "←" (right to left) or "→" (left to right).
String passArrow(ShuttleSide start) => start == ShuttleSide.right ? '←' : '→';

/// "right to left" or "left to right" for a pass that starts from [start].
String passWords(ShuttleSide start) =>
    start == ShuttleSide.right ? 'right to left' : 'left to right';

/// "Left" or "Right".
String sideLabel(ShuttleSide side) => side == ShuttleSide.left ? 'Left' : 'Right';

// ---------------------------------------------------------------------------
// Sheds and groups
// ---------------------------------------------------------------------------

/// True when the 0-based picks [a] and [b] raise exactly the same shafts (the same shed, whatever
/// treadles or liftplan rows express it).
bool sameRaisedShed(DraftDoc doc, int a, int b) {
  final ra = raisedShafts(doc, a);
  final rb = raisedShafts(doc, b);
  return ra.length == rb.length && ra.containsAll(rb);
}

/// The shot groups still sound for [doc]'s picks (twin of the engine's `Draft::sound_shot_groups`):
/// in pick order, cut at the last pick, a group overlapping an earlier one dropped, and each split
/// into its maximal runs of picks that raise the same shafts, keeping only runs of at least two.
/// [groups] defaults to the doc's own.
List<ShotGroup> soundShotGroups(DraftDoc doc, [List<ShotGroup>? groups]) {
  final picks = doc.picks;
  final sorted = List<ShotGroup>.of(groups ?? doc.shotGroups)
    ..sort((a, b) => a.start != b.start ? a.start.compareTo(b.start) : a.count.compareTo(b.count));
  final out = <ShotGroup>[];
  var taken = 0;
  for (final g in sorted) {
    final start = g.start;
    final end = g.end < picks ? g.end : picks;
    if (start < taken || start < 0 || start >= end) continue;
    var run = start;
    for (var p = start + 1; p <= end; p++) {
      if (p == end || !sameRaisedShed(doc, run, p)) {
        if (p - run >= 2) out.add(ShotGroup(run, p - run));
        run = p;
      }
    }
    taken = end;
  }
  return out;
}

/// [doc] with its shot groups made sound (see [soundShotGroups]); [doc] itself when they already are.
DraftDoc withSoundShotGroups(DraftDoc doc) {
  if (doc.shotGroups.isEmpty) return doc;
  final sound = soundShotGroups(doc);
  return _sameGroups(sound, doc.shotGroups) ? doc : doc.copyWith(shotGroups: sound);
}

bool _sameGroups(List<ShotGroup> a, List<ShotGroup> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// The groups after inserting [n] picks at 0-based [at] (before the pick now at [at]): a group from
/// [at] on shifts by [n]; a group around [at] grows over the new picks; a group ending exactly at [at]
/// is unchanged, or grows when [joinGroupEndingAt] (the Book view count of that group's own row).
/// Make the result sound afterwards ([soundShotGroups]): grown groups over a different shed split.
List<ShotGroup> shotGroupsAfterInsert(List<ShotGroup> groups, int at, int n,
    {bool joinGroupEndingAt = false}) {
  if (n <= 0) return groups;
  return [
    for (final g in groups)
      if (g.start >= at)
        ShotGroup(g.start + n, g.count)
      else if (g.end > at || (g.end == at && joinGroupEndingAt))
        ShotGroup(g.start, g.count + n)
      else
        g,
  ];
}

/// The groups after removing the [n] picks from 0-based [at]: a group keeps its remaining members
/// (still consecutive, still one shed) when at least two remain and dissolves otherwise; a group
/// after the removal shifts back by [n].
List<ShotGroup> shotGroupsAfterRemove(List<ShotGroup> groups, int at, int n) {
  if (n <= 0) return groups;
  final end = at + n;
  final out = <ShotGroup>[];
  for (final g in groups) {
    if (g.end <= at) {
      out.add(g);
    } else if (g.start >= end) {
      out.add(ShotGroup(g.start - n, g.count));
    } else {
      final before = at > g.start ? at - g.start : 0;
      final after = g.end > end ? g.end - end : 0;
      if (before + after >= 2) out.add(ShotGroup(g.start < at ? g.start : at, before + after));
    }
  }
  return out;
}

/// What happened to [before]'s shot groups in [after] when an edit that kept the pick count changed
/// them as a SIDE EFFECT (a shed change of a member, a resize that pruned a treadle, a shed-direction
/// change). Null when every group is still there. Explicit group edits do not ask.
String? shotGroupChangeNotice(DraftDoc before, DraftDoc after) {
  if (before.picks != after.picks) return null;
  final lost = [
    for (final g in before.shotGroups)
      if (!after.shotGroups.contains(g)) g,
  ];
  if (lost.isEmpty) return null;
  if (lost.length > 1) {
    return '${lost.length} shot groups changed because their picks no longer share one shed. '
        'Every pass of a shot group uses the same shed.';
  }
  final g = lost.single;
  final kept = [
    for (final h in after.shotGroups)
      if (h.start >= g.start && h.end <= g.end)
        for (var p = h.start; p < h.end; p++) p,
  ];
  final where = describePicks([for (var p = g.start; p < g.end; p++) p]);
  if (kept.isEmpty) {
    return '${where[0].toUpperCase()}${where.substring(1)} are no longer '
        '${shotGroupPhrase(g.count)}, because their sheds now differ. Every pass of a shot group '
        'uses the same shed.';
  }
  return 'The ${shotGroupLabel(g.count).toLowerCase()} at $where now groups only '
      '${describePicks(kept)}, because the other picks are in a different shed now. Every pass of a '
      'shot group uses the same shed.';
}

// ---------------------------------------------------------------------------
// Shuttles, directions, and strands
// ---------------------------------------------------------------------------

/// The side each pick's pass STARTS from, null where it is unknown (twin of the engine's
/// `Draft::pass_starts`). Every shuttle alternates its own direction, counting only its own picks:
/// its first pass starts from its recorded starting side, the next from the other side, and so on.
/// So a double shot with one shuttle comes back inside the shed. A pick's direction is unknown when
/// its shuttle is unknown or has no starting side, and for EVERY pick after a pick with an unknown
/// shuttle (that pick may have been any shuttle, so no later pass can be counted).
List<ShuttleSide?> passStarts(DraftDoc doc) {
  final passes = <int, int>{};
  final out = <ShuttleSide?>[];
  var counting = true;
  for (var p = 0; p < doc.picks; p++) {
    final shuttle = doc.shuttleAt(p);
    if (shuttle == null || !counting) {
      counting = false;
      out.add(null);
      continue;
    }
    final n = passes[shuttle] ?? 0;
    passes[shuttle] = n + 1;
    final side = doc.shuttleStarts[shuttle];
    if (side == null) {
      out.add(null);
    } else if (n.isEven) {
      out.add(side);
    } else {
      out.add(side == ShuttleSide.left ? ShuttleSide.right : ShuttleSide.left);
    }
  }
  return out;
}

/// The shuttles any pick uses, ascending.
List<int> shuttlesInUse(DraftDoc doc) => ({
      for (final s in doc.pickShuttles)
        if (s != null) s,
    }.toList()
      ..sort());

/// Why some passes show no direction, in plain words (empty when every pick with a shuttle has one,
/// or when no pick has a shuttle).
List<String> directionNotes(DraftDoc doc) {
  final used = shuttlesInUse(doc);
  if (used.isEmpty) return const [];
  final notes = <String>[];
  final unknown = [
    for (var p = 0; p < doc.picks; p++)
      if (doc.shuttleAt(p) == null) p,
  ];
  if (unknown.isNotEmpty) {
    final p = unknown.first;
    notes.add(p == doc.picks - 1
        ? 'Pick ${p + 1} has no shuttle, so Ply cannot tell its direction.'
        : 'Pick ${p + 1} has no shuttle, so Ply cannot tell the direction of pick ${p + 1} or of '
            'any pick after it.');
  }
  final unsided = [
    for (final s in used)
      if (!doc.shuttleStarts.containsKey(s)) s,
  ];
  if (unsided.length == 1) {
    notes.add('Shuttle ${unsided.single} has no starting side, so its picks show no direction.');
  } else if (unsided.length > 1) {
    final names = '${unsided.sublist(0, unsided.length - 1).join(', ')} and ${unsided.last}';
    notes.add('Shuttles $names have no starting side, so their picks show no direction.');
  }
  return notes;
}

/// The average strands per pick over [doc] (1.0 with no picks or no strands recorded), the factor the
/// engine's weft estimate applies (`Draft::mean_strands`).
double meanStrands(DraftDoc doc) {
  if (doc.picks == 0 || doc.pickStrands.isEmpty) return 1.0;
  var total = 0;
  for (var p = 0; p < doc.picks; p++) {
    total += doc.strandsAt(p);
  }
  return total / doc.picks;
}
