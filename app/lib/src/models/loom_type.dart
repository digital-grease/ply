import 'draft_doc.dart';

/// The loom a weaving draft is built for.
///
/// This is a PRESET + LABEL layer over the draft's shed direction and drive (tie-up + treadling vs
/// liftplan): the looms Ply models differ only in those, so picking a type just sets sensible
/// defaults rather than adding a new structural model. The cloth itself is still determined by the
/// threading / tie-up / treadling / shed / drive — the engine never needs to know the loom type.
///
/// Stored in the sidecar [DraftMeta] (persisted with the draft); it is NOT part of WIF, which has no
/// loom-type field. Rigid heddle (a genuinely different model — heddle slots, no shafts/tie-up) is
/// intentionally out of this v1 set.
enum LoomType {
  /// Jack floor loom: treadled, RISING shed (the tie-up names the shafts that lift). The default.
  jack,

  /// Counterbalance floor loom: treadled, SINKING shed (tied shafts sink, the rest rise).
  counterbalance,

  /// Countermarch floor loom: treadled, SINKING shed (independently raises and lowers shafts).
  countermarch,

  /// Table loom: hand levers, one per shaft — effectively a per-pick RISING liftplan, no tie-up.
  table,

  /// Dobby loom: liftplan-driven (mechanical or computer dobby), RISING, suits many shafts.
  dobby,
}

extension LoomTypeX on LoomType {
  /// Short display name.
  String get label => switch (this) {
        LoomType.jack => 'Jack (floor loom)',
        LoomType.counterbalance => 'Counterbalance (floor loom)',
        LoomType.countermarch => 'Countermarch (floor loom)',
        LoomType.table => 'Table loom',
        LoomType.dobby => 'Dobby loom',
      };

  /// One-line description for a picker.
  String get description => switch (this) {
        LoomType.jack => 'Treadled, rising shed. The common multi-shaft floor loom.',
        LoomType.counterbalance => 'Treadled, sinking shed. Tied shafts sink, the rest rise.',
        LoomType.countermarch => 'Treadled, sinking shed. Raises and lowers shafts independently.',
        LoomType.table => 'Hand levers, one per shaft. A rising liftplan, no tie-up.',
        LoomType.dobby => 'Liftplan-driven, rising shed. Good for many shafts.',
      };

  /// The shed direction this loom uses by default.
  Shed get defaultShed =>
      (this == LoomType.counterbalance || this == LoomType.countermarch)
          ? Shed.sinking
          : Shed.rising;

  /// Whether this loom is driven by a liftplan (table / dobby) rather than a tie-up + treadling.
  bool get prefersLiftplan => this == LoomType.table || this == LoomType.dobby;

  /// Stable token for the JSON sidecar (capitalized, mirroring how `craft` stores a serde enum).
  String get serialName => switch (this) {
        LoomType.jack => 'Jack',
        LoomType.counterbalance => 'Counterbalance',
        LoomType.countermarch => 'Countermarch',
        LoomType.table => 'Table',
        LoomType.dobby => 'Dobby',
      };
}

/// Parse a sidecar [serialName] back to a [LoomType], defaulting to [LoomType.jack] for an absent or
/// unknown value (tolerant, like the rest of DraftMeta).
LoomType loomTypeFromSerial(String? serialName) => switch (serialName) {
      'Counterbalance' => LoomType.counterbalance,
      'Countermarch' => LoomType.countermarch,
      'Table' => LoomType.table,
      'Dobby' => LoomType.dobby,
      _ => LoomType.jack,
    };

/// A from-scratch blank draft set up for [loom]: its shed direction, and a liftplan drive (no tie-up,
/// 0 treadles) for table/dobby vs the default tie-up + treadling for the floor looms. Still 0x0 — the
/// editor grows it via the dimensions bar.
DraftDoc blankDraftForLoom(LoomType loom) {
  final base = DraftDoc.blank().copyWith(shed: loom.defaultShed);
  if (loom.prefersLiftplan) {
    return base.copyWith(drive: DraftLiftplan(liftplan: const <List<int>>[]), treadles: 0);
  }
  return base;
}
