import 'draft_doc.dart';

/// Double-weave layer splitting.
///
/// Double weave is two independent cloth layers woven at once: by this app's convention (and its
/// `double_weave` generator), the FRONT/top layer is the warp ends on ODD shafts {1,3,…} woven by the
/// even-index picks, and the BACK/bottom layer is the even shafts {2,4,…} woven by the odd-index
/// picks. A layer's visible cloth face is simply the FULL drawdown restricted to that layer's ends and
/// picks — so rendering a draft that keeps ONLY those ends/picks (with the original tie-up + shed, so
/// each kept pick still raises the same shafts) reproduces exactly that one layer's cloth, with no new
/// engine code.

/// Whether [doc] can offer the layered double-weave view: at least 4 shafts (two 2-shaft layers) and a
/// non-empty cloth. The split assumes the odd/even convention above, so it is EXACT for generated
/// double weave and a best-effort heuristic for hand-built or imported cloth.
bool supportsLayerView(DraftDoc doc) => doc.shafts >= 4 && doc.ends > 0 && doc.picks > 0;

/// The two layers of a double weave.
enum DoubleWeaveLayer { front, back }

/// Build the sub-draft for one [layer] so the existing renderer draws just that layer's cloth face.
/// FRONT keeps ends on an odd shaft + even-index picks; BACK keeps even shafts + odd-index picks. The
/// tie-up and shed are preserved unchanged (a kept pick raises the same shafts as in the full draft),
/// and the header shaft/treadle counts are left as-is — the threading, drive rows, and per-thread
/// colors AND thickness are narrowed to the layer so the kept threads keep their own widths/heights.
DraftDoc doubleWeaveLayerDraft(DraftDoc doc, DoubleWeaveLayer layer) {
  final front = layer == DoubleWeaveLayer.front;

  // An end belongs to this layer if it is threaded on a shaft of the layer's parity (odd = front). An
  // UNTHREADED end (empty row — legal in the model) has no parity, so it is assigned to the FRONT, so
  // front + back still partition every end (its column is all-weft on the combined cloth regardless).
  bool endOnLayer(int end) {
    final row = doc.threading[end];
    return row.isEmpty ? front : row.any((shaft) => shaft.isOdd == front);
  }

  final keepEnds = [for (var e = 0; e < doc.ends; e++) if (endOnLayer(e)) e];
  final keepPicks = [for (var p = 0; p < doc.picks; p++) if (p.isEven == front) p];

  // Read the parallel per-thread arrays defensively: the model permits a color band SHORTER than the
  // threading (validation, not the model, enforces parallelism, and the engine falls back to index 0),
  // so a short band must not throw a RangeError here. Per-thread THICKNESS is narrowed too — dropping
  // it would leave the parent's full-length array to be applied positionally to the reindexed threads,
  // rendering the wrong column widths / row heights. An empty thickness list means "uniform" and a
  // shorter-than-full one is treated as uniform (cleared) rather than mis-indexed.
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
