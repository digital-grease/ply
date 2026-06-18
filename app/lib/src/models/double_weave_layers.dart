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
/// bottom layer down (no bottom shaft raised — it sits below the top weft), a BOTTOM pick lifts the
/// whole top layer clear (every top shaft raised) so the bottom weft passes under it.

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

/// Build the sub-draft for ONE layer of a double weave so the existing renderer draws just that
/// layer's cloth face. [topShafts] is the user's assignment of shafts to the TOP layer (the rest are
/// bottom). For the requested layer ([top] = top vs bottom):
///   - WARP: ends threaded on the layer's shafts (an UNTHREADED end goes to the top so the two layers
///     still partition every end).
///   - WEFT: the picks that weave THIS layer — a TOP pick leaves the bottom layer down (no bottom
///     shaft raised); a BOTTOM pick lifts the whole top layer clear (every top shaft raised). A pick
///     that fits neither (a malformed / non-double-weave draft) is dropped from both layers.
/// The tie-up + shed and the header counts are preserved; only the threading, drive rows, and the
/// per-thread colors AND thickness are narrowed to the layer (so the kept threads keep their widths).
DraftDoc doubleWeaveLayerDraft(DraftDoc doc, {required Set<int> topShafts, required bool top}) {
  final n = maxLayerShaft(doc);
  final bottomShafts = {for (var s = 1; s <= n; s++) if (!topShafts.contains(s)) s};
  final layerShafts = top ? topShafts : bottomShafts;

  bool endOnLayer(int end) {
    final row = doc.threading[end];
    if (row.isEmpty) return top; // unthreaded -> top, so layers partition every end
    return row.any(layerShafts.contains);
  }

  bool pickOnLayer(int pick) {
    final raised = raisedShafts(doc, pick);
    return top
        ? bottomShafts.isNotEmpty && bottomShafts.every((s) => !raised.contains(s)) // bottom stays down
        : topShafts.isNotEmpty && topShafts.every(raised.contains); // top lifted clear
  }

  final keepEnds = [for (var e = 0; e < doc.ends; e++) if (endOnLayer(e)) e];
  final keepPicks = [for (var p = 0; p < doc.picks; p++) if (pickOnLayer(p)) p];

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
  );
}
