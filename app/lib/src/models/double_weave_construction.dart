// Double-weave construction (M8-09, ADR 0010): what happens at each selvedge of a two-layer cloth,
// DERIVED from the pick roles (top layer, bottom layer), the shuttles, and each shuttle's starting
// side; and the construction the weaver declares (two independent layers, a tube, or double width
// with a fold). The Dart twin of the engine's `construction` module, so the layer inspector can
// explain the edges without a round trip; both suites test the same cases, and validation messages
// come from the engine.
//
// THE EDGE RULE. Every pass ends at one edge, where its shuttle turns (each shuttle alternates its
// own direction from its starting side, see [passStarts]). If that shuttle's next pick is on the OTHER
// layer, the weft carries from one layer into the other there: the turn joins the layers at that edge
// (a fold, or a closed edge). If the next pick is on the SAME layer, the weft turns back into its own
// layer: that layer's own selvedge, open. Missing roles, shuttles or starting sides make the edges
// unknown. Nothing is inferred from sheds or colors, and a draft without a declared construction is
// never labeled one on its own: the inspector only OFFERS a construction the edges match exactly.

import 'double_weave_layers.dart' show PickLayers;
import 'draft_doc.dart';
import 'use_tabby.dart' show describePicks;
import 'weft_work.dart' show passStarts;

/// What the turns at one edge do, summarized.
enum EdgeBehavior {
  /// No shuttle turns at this edge (too few picks to tell).
  noTurns,

  /// Every turn here stays in its layer: each layer has its own selvedge.
  open,

  /// Every turn here passes from one layer to the other: a fold or a closed edge.
  joined,

  /// Some turns here join the layers and some do not.
  mixed,
}

/// One turn of a shuttle: the pass of pick [from] ended at [side], and the same shuttle's next pass is
/// pick [to] (0-based picks). [joins] when the two picks are on different layers.
class LayerTurn {
  const LayerTurn({
    required this.from,
    required this.to,
    required this.shuttle,
    required this.side,
    required this.joins,
  });

  final int from;
  final int to;
  final int shuttle;
  final ShuttleSide side;
  final bool joins;
}

/// The result of [deriveEdges]: [EdgesKnown], or [EdgesUnknown] with the reason.
sealed class EdgeDerivation {
  const EdgeDerivation();
}

/// The derived edges of a two-layer draft.
class EdgesKnown extends EdgeDerivation {
  const EdgesKnown({
    required this.left,
    required this.right,
    required this.turns,
    required this.topPicks,
    required this.bottomPicks,
  });

  final EdgeBehavior left;
  final EdgeBehavior right;

  /// Every turn, in the order of the pick that ends it.
  final List<LayerTurn> turns;
  final int topPicks;
  final int bottomPicks;

  EdgeBehavior at(ShuttleSide side) => side == ShuttleSide.left ? left : right;

  /// The construction these edges are EXACTLY ([LayerConstruction.none] when either edge is mixed or
  /// has no turns, or every pick is on one layer): two open edges are two independent layers, two
  /// joined edges a tube, one of each double width with the fold on the joined edge.
  LayerConstruction get construction {
    if (topPicks == 0 || bottomPicks == 0) return LayerConstruction.none;
    return switch ((left, right)) {
      (EdgeBehavior.open, EdgeBehavior.open) => LayerConstruction.twoLayers,
      (EdgeBehavior.joined, EdgeBehavior.joined) => LayerConstruction.tube,
      (EdgeBehavior.joined, EdgeBehavior.open) => LayerConstruction.doubleWidthFoldLeft,
      (EdgeBehavior.open, EdgeBehavior.joined) => LayerConstruction.doubleWidthFoldRight,
      _ => LayerConstruction.none,
    };
  }
}

/// The edges cannot be derived: [reason] says what is missing, as a clause ("picks 3 to 5 are not
/// marked top layer or bottom layer").
class EdgesUnknown extends EdgeDerivation {
  const EdgesUnknown(this.reason);
  final String reason;
}

/// Derive what happens at each edge of [doc] (see the library doc for the rule). Unknown unless every
/// pick has a top-layer or bottom-layer role and a shuttle, and every shuttle a starting side; the
/// first missing kind of data is the reason (twin of the engine's `derive_edges`).
EdgeDerivation deriveEdges(DraftDoc doc) {
  final picks = doc.picks;
  if (picks == 0) return const EdgesUnknown('it has no picks');
  bool? onTop(int p) => switch (doc.roleAt(p)) {
        PickRole.topLayer => true,
        PickRole.bottomLayer => false,
        _ => null,
      };
  final noRole = [
    for (var p = 0; p < picks; p++)
      if (onTop(p) == null) p,
  ];
  if (noRole.isNotEmpty) {
    return EdgesUnknown(
        '${describePicks(noRole)} ${noRole.length == 1 ? 'is' : 'are'} not marked top layer or '
        'bottom layer');
  }
  final noShuttle = [
    for (var p = 0; p < picks; p++)
      if (doc.shuttleAt(p) == null) p,
  ];
  if (noShuttle.isNotEmpty) {
    return EdgesUnknown(
        '${describePicks(noShuttle)} ${noShuttle.length == 1 ? 'has' : 'have'} no shuttle');
  }
  final unsided = ({
    for (var p = 0; p < picks; p++) doc.shuttleAt(p)!,
  }.where((s) => !doc.shuttleStarts.containsKey(s)).toList()
    ..sort());
  if (unsided.isNotEmpty) {
    return EdgesUnknown(unsided.length == 1
        ? 'shuttle ${unsided.single} has no starting side'
        : 'shuttles ${unsided.sublist(0, unsided.length - 1).join(', ')} and ${unsided.last} have '
            'no starting side');
  }

  final starts = passStarts(doc);
  final last = <int, int>{};
  final turns = <LayerTurn>[];
  for (var p = 0; p < picks; p++) {
    final shuttle = doc.shuttleAt(p)!;
    final prev = last[shuttle];
    final start = prev == null ? null : starts[prev];
    if (prev != null && start != null) {
      turns.add(LayerTurn(
        from: prev,
        to: p,
        shuttle: shuttle,
        side: start == ShuttleSide.left ? ShuttleSide.right : ShuttleSide.left,
        joins: onTop(prev) != onTop(p),
      ));
    }
    last[shuttle] = p;
  }
  EdgeBehavior summary(ShuttleSide side) {
    final at = turns.where((t) => t.side == side);
    if (at.isEmpty) return EdgeBehavior.noTurns;
    final joins = at.any((t) => t.joins);
    final opens = at.any((t) => !t.joins);
    return joins && opens
        ? EdgeBehavior.mixed
        : joins
            ? EdgeBehavior.joined
            : EdgeBehavior.open;
  }

  final top = [
    for (var p = 0; p < picks; p++)
      if (onTop(p) == true) p,
  ].length;
  return EdgesKnown(
    left: summary(ShuttleSide.left),
    right: summary(ShuttleSide.right),
    turns: turns,
    topPicks: top,
    bottomPicks: picks - top,
  );
}

/// What [construction] expects at [side]: [EdgeBehavior.joined] or [EdgeBehavior.open]
/// ([EdgeBehavior.noTurns] for [LayerConstruction.none], which expects nothing).
EdgeBehavior expectedEdge(LayerConstruction construction, ShuttleSide side) =>
    switch (construction) {
      LayerConstruction.none => EdgeBehavior.noTurns,
      LayerConstruction.twoLayers => EdgeBehavior.open,
      LayerConstruction.tube => EdgeBehavior.joined,
      LayerConstruction.doubleWidthFoldLeft =>
        side == ShuttleSide.left ? EdgeBehavior.joined : EdgeBehavior.open,
      LayerConstruction.doubleWidthFoldRight =>
        side == ShuttleSide.right ? EdgeBehavior.joined : EdgeBehavior.open,
    };

/// True when [edges] agree with [construction]: both layers have picks and no turn goes against it
/// (an edge with no turns yet agrees). Weaker than [EdgesKnown.construction], the exact match a
/// construction is offered from.
bool agreesWith(EdgesKnown edges, LayerConstruction construction) =>
    construction != LayerConstruction.none &&
    edges.topPicks > 0 &&
    edges.bottomPicks > 0 &&
    edges.turns
        .every((t) => t.joins == (expectedEdge(construction, t.side) == EdgeBehavior.joined));

/// The construction as a short label: "Two independent layers", "Tube", "Double width, fold on the
/// left", "Not declared".
String constructionLabel(LayerConstruction c) => switch (c) {
      LayerConstruction.none => 'Not declared',
      LayerConstruction.twoLayers => 'Two independent layers',
      LayerConstruction.tube => 'Tube',
      LayerConstruction.doubleWidthFoldLeft => 'Double width, fold on the left',
      LayerConstruction.doubleWidthFoldRight => 'Double width, fold on the right',
    };

/// The construction inside a sentence, as the engine's messages say it: "two independent layers",
/// "a tube", "double width with the fold on the left".
String constructionPhrase(LayerConstruction c) => switch (c) {
      LayerConstruction.none => 'no construction',
      LayerConstruction.twoLayers => 'two independent layers',
      LayerConstruction.tube => 'a tube',
      LayerConstruction.doubleWidthFoldLeft => 'double width with the fold on the left',
      LayerConstruction.doubleWidthFoldRight => 'double width with the fold on the right',
    };

/// The "Use as" button for an exactly matching construction: "Use as two independent layers", "Use
/// as a tube", "Use as double width, fold on the right".
String useAsLabel(LayerConstruction c) => switch (c) {
      LayerConstruction.none => '',
      LayerConstruction.twoLayers => 'Use as two independent layers',
      LayerConstruction.tube => 'Use as a tube',
      LayerConstruction.doubleWidthFoldLeft => 'Use as double width, fold on the left',
      LayerConstruction.doubleWidthFoldRight => 'Use as double width, fold on the right',
    };

String _sideWord(ShuttleSide side) => side == ShuttleSide.left ? 'left' : 'right';

/// Where [doc]'s declared construction and its derived edges disagree, in plain words (empty when
/// nothing is declared or it matches). The twin of the engine's `construction_issues`, whose messages
/// the validation band shows; the inspector repeats them beside the edge legend.
List<String> constructionIssues(DraftDoc doc) {
  final c = doc.construction;
  if (c == LayerConstruction.none) return const [];
  final derived = deriveEdges(doc);
  switch (derived) {
    case EdgesUnknown(:final reason):
      return [
        'This draft is marked as ${constructionPhrase(c)}, but Ply cannot check its edges because '
            '$reason.'
      ];
    case EdgesKnown():
  }
  final edges = derived;
  if (edges.topPicks == 0 || edges.bottomPicks == 0) {
    final layer = edges.topPicks == 0 ? 'bottom' : 'top';
    return [
      'This draft is marked as ${constructionPhrase(c)}, but every pick is on the $layer layer, so '
          'there is only one layer.'
    ];
  }
  final intro = switch (c) {
    LayerConstruction.twoLayers => 'Two independent layers should be open at both edges',
    LayerConstruction.tube => 'A tube should join the layers at both edges',
    LayerConstruction.doubleWidthFoldLeft => 'The fold should be on the left',
    LayerConstruction.doubleWidthFoldRight => 'The fold should be on the right',
    LayerConstruction.none => '',
  };
  final out = <String>[];
  for (final side in ShuttleSide.values) {
    final expected = expectedEdge(c, side);
    // Turns that go against the expectation. An edge with no turns yet contradicts nothing.
    final wrong = [
      for (final t in edges.turns)
        if (t.side == side && t.joins == (expected == EdgeBehavior.open)) t,
    ];
    if (wrong.isEmpty) continue;
    final first = wrong.first;
    final more = switch (wrong.length - 1) {
      0 => '',
      1 => ' (and at 1 more turn)',
      final n => ' (and at $n more turns)',
    };
    final verb = expected == EdgeBehavior.open ? 'join' : 'do not join';
    out.add('$intro, but the layers $verb on the ${_sideWord(side)} between picks '
        '${first.from + 1} and ${first.to + 1}$more.');
  }
  return out;
}

/// Why the inspector cannot show [doc]'s TOP FACE with the top-layer shafts that gave [layers], as a
/// sentence; null when it can. The face seen from above is exactly the top layer's own interlacement
/// only when every pick weaves one layer, the layers never cross (a top pick lifts no bottom end, a
/// bottom pick lifts the whole top layer, which [layers] tests per pick), and the declared
/// construction matches the derived edges (the double-weave research note, section 4).
String? topFaceUnavailable(DraftDoc doc, PickLayers layers) {
  final picks = doc.picks;
  if (picks == 0) return 'This draft has no picks yet.';
  for (var p = 0; p < picks; p++) {
    final r = doc.roleAt(p);
    if (r != PickRole.topLayer && r != PickRole.bottomLayer) {
      return 'Ply shows the top face only when every pick is marked top layer or bottom layer.';
    }
  }
  if (doc.construction == LayerConstruction.none) {
    return 'Ply shows the top face only when a construction is declared.';
  }
  final edges = deriveEdges(doc);
  if (edges is! EdgesKnown || !agreesWith(edges, doc.construction)) {
    return 'Ply shows the top face only when the edges match the declared construction.';
  }
  final top = layers.top.toSet();
  final bottom = layers.bottom.toSet();
  final crossing = [
    for (var p = 0; p < picks; p++)
      if (doc.roleAt(p) == PickRole.topLayer ? !top.contains(p) : !bottom.contains(p)) p,
  ];
  if (crossing.isNotEmpty) {
    final what =
        crossing.length == 1 ? 'does not weave the layer it is' : 'do not weave the layer they are';
    return 'With these top-layer shafts, ${describePicks(crossing)} $what marked for, so the face '
        'cannot be told from the draft.';
  }
  return null;
}
