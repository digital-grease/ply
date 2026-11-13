import 'draft_doc.dart';

/// Double-weave layer splitting.
///
/// Double weave is two independent cloth layers woven at once. Each layer is a set of warp ends (on
/// the layer's shafts) crossed by the picks that weave that layer. A layer's visible cloth face is
/// simply the FULL drawdown restricted to that layer's ends and picks — so rendering a draft that
/// keeps ONLY those ends/picks (with the original tie-up + shed, so each kept pick still raises the
/// same shafts) reproduces exactly that one layer's cloth, with no new engine code.
///
/// The user chooses which shafts are the TOP layer; the rest are the bottom. Which PICKS weave each
/// layer is derived from the structure (the textbook top-on-top double weave): a TOP pick leaves the
/// bottom layer down (no bottom shaft raised, it sits below the top weft) and raises SOME but not all
/// top shafts (so it actually interlaces with the top layer); a BOTTOM pick lifts the whole top layer
/// clear (every top shaft raised) and raises some but not all bottom shafts. Every other pick weaves
/// neither layer and is REPORTED by [classifyPicks] with a reason, never silently dropped or counted
/// twice. Each layer view is that layer's own interlacement, not the face of the finished cloth.

/// The highest shaft the cloth uses (max of the header and any threaded shaft) — the number of shafts
/// the layer picker offers.
int maxLayerShaft(DraftDoc doc) =>
    doc.threading.fold<int>(doc.shafts, (m, row) => row.fold<int>(m, (a, s) => s > a ? s : a));

/// Whether [doc] can offer the layered double-weave view: a non-empty cloth that uses at least 4
/// shafts (two 2-shaft layers). Gates on [maxLayerShaft] (real shaft usage, not just the header), so a
/// composed or edited double weave whose `shafts` header drifted below its usage still qualifies.
bool supportsLayerView(DraftDoc doc) =>
    doc.ends > 0 && doc.picks > 0 && maxLayerShaft(doc) >= 4;

/// The default TOP-layer shafts: the odd shafts (matching the `double_weave` generator). The user can
/// reassign any shaft to top or bottom in the layer inspector.
Set<int> defaultTopShafts(DraftDoc doc) {
  final n = maxLayerShaft(doc);
  return {for (var s = 1; s <= n; s += 2) s};
}

/// Which shafts a [pick] raises — a Dart mirror of the engine's `Draft::raised_shafts`, used ONLY to
/// classify which layer a pick weaves (not to render). A liftplan lists raised shafts directly; a
/// treadled draft unions the tie-up rows of the pick's treadles, and a SINKING shed raises the
/// complement within 1..shafts. Kept in lockstep with the engine rule by [raisedShafts]'s tests.
Set<int> raisedShafts(DraftDoc doc, int pick) {
  switch (doc.drive) {
    case DraftLiftplan(:final liftplan):
      return pick < liftplan.length ? liftplan[pick].toSet() : <int>{};
    case DraftTreadled(:final tieup, :final treadling):
      final tied = <int>{};
      if (pick < treadling.length) {
        for (final t in treadling[pick]) {
          if (t >= 1 && t <= tieup.length) tied.addAll(tieup[t - 1]);
        }
      }
      if (doc.shed == Shed.sinking) {
        final n = maxLayerShaft(doc);
        return {for (var s = 1; s <= n; s++) if (!tied.contains(s)) s};
      }
      return tied;
  }
}

/// Why a pick weaves neither layer under the current shaft assignment.
enum UnclassifiedPick {
  /// Every shaft is in one layer, so there is no second layer to split off.
  noSplit,

  /// Raises nothing: the weft floats over both layers.
  overEverything,

  /// Raises every shaft: the weft passes under both layers.
  underEverything,

  /// Raises exactly the top layer: the weft lies between the layers, interlacing with neither.
  betweenLayers,

  /// Raises shafts of both layers in a way that is neither a top nor a bottom pick (a stitching pick
  /// that joins the layers, or a draft that is not double weave with this assignment).
  crossesLayers,
}

/// The layer each pick weaves, for one shaft assignment. Every pick is in exactly one of [top],
/// [bottom], or [unclassified] (0-based pick indices, ascending).
class PickLayers {
  const PickLayers({required this.top, required this.bottom, required this.unclassified});
  final List<int> top;
  final List<int> bottom;
  final Map<int, UnclassifiedPick> unclassified;
}

/// Classify every pick of [doc] for the TOP layer [topShafts] (the rest of `1..maxLayerShaft` is the
/// bottom). See the library doc for the rule; picks that fit neither layer carry their reason.
PickLayers classifyPicks(DraftDoc doc, Set<int> topShafts) {
  final n = maxLayerShaft(doc);
  final all = {for (var s = 1; s <= n; s++) s};
  final topSet = topShafts.intersection(all);
  final bottomSet = all.difference(topSet);
  final top = <int>[];
  final bottom = <int>[];
  final unclassified = <int, UnclassifiedPick>{};
  for (var p = 0; p < doc.picks; p++) {
    if (topSet.isEmpty || bottomSet.isEmpty) {
      unclassified[p] = UnclassifiedPick.noSplit;
      continue;
    }
    final raised = raisedShafts(doc, p).intersection(all);
    final raisedTop = raised.intersection(topSet);
    final raisedBottom = raised.intersection(bottomSet);
    bool proper(Set<int> part, Set<int> whole) => part.isNotEmpty && part.length < whole.length;
    if (raisedBottom.isEmpty && proper(raisedTop, topSet)) {
      top.add(p);
    } else if (raisedTop.length == topSet.length && proper(raisedBottom, bottomSet)) {
      bottom.add(p);
    } else if (raised.isEmpty) {
      unclassified[p] = UnclassifiedPick.overEverything;
    } else if (raised.length == all.length) {
      unclassified[p] = UnclassifiedPick.underEverything;
    } else if (raisedBottom.isEmpty && raisedTop.length == topSet.length) {
      unclassified[p] = UnclassifiedPick.betweenLayers;
    } else {
      unclassified[p] = UnclassifiedPick.crossesLayers;
    }
  }
  return PickLayers(top: top, bottom: bottom, unclassified: unclassified);
}

/// Build the sub-draft for ONE layer of a double weave so the existing renderer draws just that
/// layer's cloth face. [topShafts] is the user's assignment of shafts to the TOP layer (the rest are
/// bottom). For the requested layer ([top] = top vs bottom):
///   - WARP: ends threaded on the layer's shafts (an UNTHREADED end goes to the top so the two layers
///     still partition every end).
///   - WEFT: the picks that weave THIS layer per [classifyPicks]. A pick that weaves neither layer is
///     in neither sub-draft; the inspector lists those picks and why, so none disappears silently.
/// The tie-up + shed and the header counts are preserved; only the threading, drive rows, the
/// per-thread colors AND thickness, and the pick roles are narrowed to the layer (so the kept threads
/// keep their widths and roles).
DraftDoc doubleWeaveLayerDraft(DraftDoc doc, {required Set<int> topShafts, required bool top}) {
  final n = maxLayerShaft(doc);
  final bottomShafts = {for (var s = 1; s <= n; s++) if (!topShafts.contains(s)) s};
  final layerShafts = top ? topShafts : bottomShafts;

  bool endOnLayer(int end) {
    final row = doc.threading[end];
    if (row.isEmpty) return top; // unthreaded -> top, so layers partition every end
    return row.any(layerShafts.contains);
  }

  final layers = classifyPicks(doc, topShafts);
  final keepEnds = [for (var e = 0; e < doc.ends; e++) if (endOnLayer(e)) e];
  final keepPicks = top ? layers.top : layers.bottom;

  // Read the parallel per-thread arrays defensively: the model permits a color band SHORTER than the
  // threading (validation, not the model, enforces parallelism, and the engine falls back to index 0).
  // Per-thread THICKNESS is narrowed too — dropping it would mis-apply the parent's full-length array
  // positionally to the reindexed threads. An empty/short thickness list means "uniform" (kept empty).
  int warpColorAt(int e) => e < doc.warpColors.length ? doc.warpColors[e] : 0;
  int weftColorAt(int p) => p < doc.weftColors.length ? doc.weftColors[p] : 0;
  List<double> narrowThickness(List<double> t, List<int> keep, int full) =>
      t.length < full ? const <double>[] : [for (final i in keep) t[i]];

  final threading = [for (final e in keepEnds) doc.threading[e]];
  final warpColors = [for (final e in keepEnds) warpColorAt(e)];
  final weftColors = [for (final p in keepPicks) weftColorAt(p)];

  final drive = switch (doc.drive) {
    DraftTreadled(:final tieup, :final treadling) =>
      DraftTreadled(tieup: tieup, treadling: [for (final p in keepPicks) treadling[p]]),
    DraftLiftplan(:final liftplan) =>
      DraftLiftplan(liftplan: [for (final p in keepPicks) liftplan[p]]),
  };

  return doc.copyWith(
    threading: threading,
    drive: drive,
    warpColors: warpColors,
    weftColors: weftColors,
    warpThickness: narrowThickness(doc.warpThickness, keepEnds, doc.ends),
    weftThickness: narrowThickness(doc.weftThickness, keepPicks, doc.picks),
    // Roles, shuttles, and strands are per pick, so they narrow with the picks (empty stays empty).
    pickRoles: [for (final p in keepPicks) doc.roleAt(p)],
    pickShuttles: [for (final p in keepPicks) doc.shuttleAt(p)],
    pickStrands: [for (final p in keepPicks) doc.strandsAt(p)],
    // A shot group keeps the members this layer keeps (still consecutive here, still one shed) when
    // at least two remain.
    shotGroups: _narrowGroups(doc.shotGroups, keepPicks),
  );
}

/// [groups] re-indexed onto the kept picks [keep] (ascending 0-based picks of the parent): each group
/// keeps its members that are kept, when at least two are. Between two kept members of one group only
/// that group's own picks can have been dropped, so the kept members stay consecutive.
List<ShotGroup> _narrowGroups(List<ShotGroup> groups, List<int> keep) {
  if (groups.isEmpty) return const [];
  final index = {for (var i = 0; i < keep.length; i++) keep[i]: i};
  final out = <ShotGroup>[];
  for (final g in groups) {
    final kept = [
      for (var p = g.start; p < g.end; p++)
        if (index.containsKey(p)) p,
    ];
    if (kept.length >= 2) out.add(ShotGroup(index[kept.first]!, kept.length));
  }
  return out;
}
