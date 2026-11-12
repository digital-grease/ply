// The shadow-weave generator's parameters as the structure sheet collects them (pure Dart). The
// repository maps them to the bridge DTO; the engine builds and checks the draft.
//
// Shadow weave here is the authentic Atwater / Powell block weave: warp and weft alternate dark and
// light one by one, every dark end has its light partner beside it, and the weft is treadled as
// drawn in. The blocks always run in twill order (A, B, C, ...), one width per block, and the size
// is whole repeats plus an optional balancing end and pick, so a unit is never cut in half.

import 'package:flutter/foundation.dart' show immutable, listEquals;

/// Which shaft numbering the draft uses. Both weave the same cloth.
enum ShadowSystem {
  /// Partners half the loom apart (1 & 3, 2 & 4 on 4 shafts).
  atwater,

  /// Partners side by side (1 & 2, 3 & 4).
  powell,
}

/// How the blocks are laid out across one repeat.
enum ShadowLayout {
  /// A, B, C, ... then start over.
  repeat,

  /// A, B, C, ... then back again (the turning blocks keep their partners).
  point,
}

@immutable
class ShadowWeaveParams {
  const ShadowWeaveParams({
    this.system = ShadowSystem.atwater,
    this.shafts = 4,
    this.layout = ShadowLayout.point,
    this.blockUnits = const [2, 2, 2, 2],
    this.reverseTwill = false,
    this.featheryEdges = false,
    this.warpRepeats = 2,
    this.weftRepeats = 2,
    this.balanced = true,
  });

  /// The shaft counts offered (the ones the published sources document).
  static const List<int> supportedShafts = [4, 8];

  /// Width a block field starts at.
  static const int defaultUnits = 2;

  /// Largest width a single block field accepts.
  static const int maxUnits = 64;

  final ShadowSystem system;

  /// 4 or 8; also the number of blocks and of treadles.
  final int shafts;
  final ShadowLayout layout;

  /// One width per block in units (one dark and one light thread), block A first. Its length is
  /// [shafts].
  final List<int> blockUnits;

  /// Run the tie-up's twill the other way (the block diagonal turns).
  final bool reverseTwill;

  /// Swap the weft colors in every pair of picks: feathery block edges instead of smooth ones,
  /// with the same interlacement.
  final bool featheryEdges;
  final int warpRepeats;
  final int weftRepeats;

  /// Weave the first end and pick once more at the end.
  final bool balanced;

  int get totalUnits => blockUnits.fold(0, (sum, u) => sum + u);

  /// Threads in one repeat (warp and weft alike): 2 per unit for a straight repeat, and for a point
  /// 4 per unit less the two turning threads that are not repeated.
  int get repeatLength => layout == ShadowLayout.repeat ? 2 * totalUnits : 4 * totalUnits - 2;

  int get ends => warpRepeats * repeatLength + (balanced ? 1 : 0);
  int get picks => weftRepeats * repeatLength + (balanced ? 1 : 0);

  /// The letter weavers use for 0-based block [block] (A, B, C, ...).
  static String blockLetter(int block) => String.fromCharCode(0x41 + block);

  /// The shaft partnered with [shaft] (1-based) in [system] on [shafts] shafts.
  static int partner(ShadowSystem system, int shafts, int shaft) => switch (system) {
        ShadowSystem.atwater => (shaft - 1 + shafts ~/ 2) % shafts + 1,
        ShadowSystem.powell => shaft.isOdd ? shaft + 1 : shaft - 1,
      };

  /// The (dark, light) shafts of 0-based [block]. Atwater block b is dark on shaft b + 1 with its
  /// partner light; Powell blocks are the same blocks renumbered (on 4 shafts A = 1 & 2, B = 3 & 4,
  /// C = 2 & 1, D = 4 & 3, the letter order of Powell's book). Mirrors the engine's `block_shafts`.
  static (int, int) blockShafts(ShadowSystem system, int shafts, int block) {
    final half = shafts ~/ 2;
    final dark = block + 1;
    final light = partner(ShadowSystem.atwater, shafts, dark);
    int toPowell(int s) => s <= half ? 2 * s - 1 : 2 * (s - half);
    return switch (system) {
      ShadowSystem.atwater => (dark, light),
      ShadowSystem.powell => (toPowell(dark), toPowell(light)),
    };
  }

  /// The partner pairs of [system] on [shafts] shafts, lowest shaft first: Atwater 4 is
  /// `[(1, 3), (2, 4)]`, Powell 4 is `[(1, 2), (3, 4)]`.
  static List<(int, int)> partnerPairs(ShadowSystem system, int shafts) => [
        for (var s = 1; s <= shafts; s++)
          if (partner(system, shafts, s) > s) (s, partner(system, shafts, s)),
      ];

  ShadowWeaveParams copyWith({
    ShadowSystem? system,
    int? shafts,
    ShadowLayout? layout,
    List<int>? blockUnits,
    bool? reverseTwill,
    bool? featheryEdges,
    int? warpRepeats,
    int? weftRepeats,
    bool? balanced,
  }) =>
      ShadowWeaveParams(
        system: system ?? this.system,
        shafts: shafts ?? this.shafts,
        layout: layout ?? this.layout,
        blockUnits: blockUnits ?? this.blockUnits,
        reverseTwill: reverseTwill ?? this.reverseTwill,
        featheryEdges: featheryEdges ?? this.featheryEdges,
        warpRepeats: warpRepeats ?? this.warpRepeats,
        weftRepeats: weftRepeats ?? this.weftRepeats,
        balanced: balanced ?? this.balanced,
      );

  @override
  bool operator ==(Object other) =>
      other is ShadowWeaveParams &&
      other.system == system &&
      other.shafts == shafts &&
      other.layout == layout &&
      listEquals(other.blockUnits, blockUnits) &&
      other.reverseTwill == reverseTwill &&
      other.featheryEdges == featheryEdges &&
      other.warpRepeats == warpRepeats &&
      other.weftRepeats == weftRepeats &&
      other.balanced == balanced;

  @override
  int get hashCode => Object.hash(system, shafts, layout, Object.hashAll(blockUnits), reverseTwill,
      featheryEdges, warpRepeats, weftRepeats, balanced);

  @override
  String toString() => 'ShadowWeaveParams($system, $shafts shafts, $layout, $blockUnits, '
      'reverseTwill: $reverseTwill, featheryEdges: $featheryEdges, '
      'repeats: $warpRepeats x $weftRepeats, balanced: $balanced)';
}
