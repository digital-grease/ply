// The immutable Dart domain model the weaving editor mutates through PURE REDUCERS:
// every edit returns a brand-new [DraftDoc] and leaves the old one untouched. That single
// property is what makes the rest of the editor cheap to build correctly, and it drives
// every decision in this file:
//
//   1. VALUE EQUALITY MUST BE DEEP. The undo/redo stack is a list of whole-[DraftDoc]
//      snapshots, and a snapshot only earns its place if it actually differs from the top,
//      so we dedup with `==`. A live-preview Riverpod provider also `ref.watch`es the doc
//      and only re-renders when it changes. Dart's built-in `List ==` is IDENTITY, so two
//      structurally-identical drafts would compare unequal and both behaviours would break
//      (the undo stack would grow on every no-op edit, the preview would re-render the
//      cloth on every keystroke that changed nothing). `hashCode` MUST agree with that deep
//      `==`: equal docs hash equal, and the hash is over CONTENTS, not list identity. A raw
//      `Object.hash(aList)` hashes the list's identity and would silently break both.
//
//   2. SNAPSHOTS MUST BE FROZEN. Because the undo stack holds references to past
//      [DraftDoc]s, any caller who mutated a list reachable from a snapshot would silently
//      corrupt history (an "undo" would restore already-mutated state, and a mutated alias
//      could even make two distinct snapshots compare wrongly equal). So this model does not
//      trust callers: it DEFENSIVELY seals every list at construction (deep-copy, then wrap
//      in an UnmodifiableListView). Once built, a [DraftDoc] has no reachable mutable list.
//
// This model is deliberately ISOLATED from the wire. It is NOT serialized and NOT sent
// across FFI. The repository (the sole owner of the generated bridge symbols) maps
// [DraftDoc] <-> the generated `DraftDto` in a later phase, doing the typed-list
// (Uint16List/Uint32List) and id/index base conversions THERE. So this file imports NO
// generated symbol; it defines its own domain enums ([Shed], [MeasureUnit]) and its own
// [DraftDrive] sum type. (The generated `DraftDto` uses XOR hashCode and identity-based
// List `==`, so it is deliberately equality-INCOMPATIBLE with [DraftDoc]; the repository
// mapper must be the sole bridge so a `DraftDto` never leaks into an equality-sensitive
// collection that expects [DraftDoc] semantics.)
//
// Domain list fields are PLAIN growable Dart lists (`List<int>`, `List<List<int>>`), never
// `Uint16List`/`Uint32List`: the typed lists are fixed-length and value-clamped, which is
// hostile to an editor that inserts and removes ends/picks. Every id stays a 1-BASED plain
// `int` exactly as the weaver and WIF number them (a `0` in a shaft/treadle slot is an
// invalid id, not a valid index); base conversion lives ONLY at the repository boundary,
// never as a +1/-1 sprinkled through this model (see CLAUDE.md).
//
// EQUALITY ENGINE. A single shared `const DeepCollectionEquality` (`_deepEq`) backs BOTH
// `==` and `hashCode` for every nested-list field. Using ONE vetted instance for both
// halves is exactly what guarantees the equal-docs-hash-equal contract with zero desync
// surface, and it is the same engine the generated `dto.freezed.dart` already relies on.

import 'package:collection/collection.dart';

/// One deep structural equality used for EVERY nested-list field in this file, and the
/// matching `.hash()` for every hashCode. It recurses into `List<List<int>>` (threading,
/// tie-up, treadling, liftplan), `List<int>` (warp/weft color indices), and
/// `List<DraftColor>` (where it bottoms out on [DraftColor]'s own value `==`). It is
/// `const`, so there is one shared instance and no per-comparison allocation. Routing both
/// `==` and `hashCode` through this SAME object is what keeps them consistent: equal
/// contents produce equal `.equals(...)` AND equal `.hash(...)`.
const DeepCollectionEquality _deepEq = DeepCollectionEquality();

/// Which way the loom moves the shafts named in the tie-up or liftplan. A domain twin of the
/// wire `ShedKind` (mirrored, not imported, to keep this model free of generated symbols).
/// The engine inverts the drawdown for [sinking], so the preview depends on this and it is
/// part of value equality.
enum Shed { rising, sinking }

/// Measurement unit for the draft's lengths. A domain twin of the wire `UnitKind`. Named
/// [MeasureUnit] rather than `Unit` to avoid colliding with the conventional Dart habit of a
/// `Unit`/`void`-ish placeholder and to read clearly at call sites (`MeasureUnit.inches`).
enum MeasureUnit { inches, centimeters }

/// An sRGB color in the draft's palette: three 0..255 channels, no alpha (the engine and WIF
/// `Color` are RGB only, so an alpha channel here would be a value the wire type cannot
/// carry). A tiny value type so `DeepCollectionEquality` over `List<DraftColor>` compares and
/// hashes element-wise, and so swapping a palette entry for an equal one reads as a no-op to
/// the preview provider.
///
/// This is a pure container: it does NOT clamp or validate channels. Range reconciliation is
/// the repository's job at the wire boundary, and the color picker owns user-facing limits.
class DraftColor {
  const DraftColor({required this.r, required this.g, required this.b});

  /// Red channel, 0..255.
  final int r;

  /// Green channel, 0..255.
  final int g;

  /// Blue channel, 0..255.
  final int b;

  DraftColor copyWith({int? r, int? g, int? b}) =>
      DraftColor(r: r ?? this.r, g: g ?? this.g, b: b ?? this.b);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DraftColor &&
          runtimeType == other.runtimeType &&
          r == other.r &&
          g == other.g &&
          b == other.b;

  @override
  int get hashCode => Object.hash(r, g, b);

  @override
  String toString() => 'DraftColor($r, $g, $b)';
}

/// How the raised-shaft pattern per pick is specified: a draft is EITHER treadled OR
/// liftplan-driven, never both and never neither. Modelled as a Dart 3 `sealed class` so that
/// illegal state is UNREPRESENTABLE (you cannot construct one carrying both a tie-up and a
/// liftplan, nor one carrying neither), mirroring the engine/wire `Drive` sum type.
///
/// Reducers and the preview read the active variant with an exhaustive `switch`, which the
/// analyzer proves total at compile time, so adding a future variant is a compile error at
/// every read site rather than a silent fall-through:
///
/// ```dart
/// final picks = switch (doc.drive) {
///   DraftTreadled(:final treadling) => treadling.length,
///   DraftLiftplan(:final liftplan) => liftplan.length,
/// };
/// ```
///
/// There is deliberately NO cross-variant `copyWith` on this base. Turning a treadled draft
/// into a liftplan one is a meaningful, lossy editor ACTION (a dedicated reducer that calls
/// the engine's `to_liftplan_dto`), not a field tweak, and a base `copyWith` could only
/// produce half-built variants (a tie-up with stale treadling). Per-variant, variant-
/// preserving `copyWith` lives on the subclasses for the common "edit one row" case.
///
/// All ids carried here are 1-BASED plain `int` (shaft ids in the tie-up and liftplan,
/// treadle ids in the treadling); no base conversion happens in this model.
sealed class DraftDrive {
  const DraftDrive();

  /// The number of picks (weft rows) this drive specifies. Lives on the base so
  /// [DraftDoc.picks] can read it without re-matching the variant: treadling rows for a
  /// treadled draft, liftplan rows for a liftplan draft (both are "one row per pick").
  int get pickCount;
}

/// A treadled drive: a fixed tie-up plus a per-pick treadling sequence (the loom-mechanical
/// representation).
///
/// `tieup[t]` is the shaft id(s) (1-based) tied to treadle `t`, in treadle order.
/// `treadling[p]` is the treadle id(s) (1-based) pressed for pick `p`. Multi-shaft and
/// multi-treadle entries are allowed, hence the nesting. Both outer and inner lists are
/// DEFENSIVELY SEALED (deep-copied into UnmodifiableListViews) at construction, so a snapshot
/// on the undo stack can never be mutated through a leaked inner-list reference.
final class DraftTreadled extends DraftDrive {
  /// Seals the caller's lists so the instance is fully frozen. Reducers hand in plain
  /// growable lists; the sealing makes the result safe to stash on the undo stack.
  DraftTreadled({
    required List<List<int>> tieup,
    required List<List<int>> treadling,
  })  : tieup = _sealRows(tieup),
        treadling = _sealRows(treadling);

  /// Internal constructor for lists that are ALREADY sealed, so [copyWith] can reuse an
  /// unchanged field by reference (preserving the `identical()` short-circuit in `==`/hash)
  /// instead of re-copying it. Never call this with an unsealed list.
  const DraftTreadled._sealed({required this.tieup, required this.treadling});

  /// Per treadle, the shaft id(s) it is tied to (1-based). Deeply unmodifiable; treat as
  /// frozen. Reducers build a NEW list and pass it through [copyWith], never mutate in place.
  final List<List<int>> tieup;

  /// Per pick (in weave order), the treadle id(s) pressed (1-based). Deeply unmodifiable;
  /// treat as frozen, never mutate in place.
  final List<List<int>> treadling;

  @override
  int get pickCount => treadling.length;

  /// Variant-preserving copy: returns a [DraftTreadled]. Re-seals ONLY the argument actually
  /// passed; an omitted field reuses the already-sealed `this.<field>` by reference, so a
  /// single-row edit stays O(changed-rows), not O(whole-drive).
  DraftTreadled copyWith({List<List<int>>? tieup, List<List<int>>? treadling}) {
    return DraftTreadled._sealed(
      tieup: tieup == null ? this.tieup : _sealRows(tieup),
      treadling: treadling == null ? this.treadling : _sealRows(treadling),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DraftTreadled &&
          runtimeType == other.runtimeType &&
          _deepEq.equals(tieup, other.tieup) &&
          _deepEq.equals(treadling, other.treadling);

  @override
  int get hashCode => Object.hash(
        runtimeType,
        _deepEq.hash(tieup),
        _deepEq.hash(treadling),
      );

  @override
  String toString() =>
      'DraftTreadled(tieup: ${tieup.length} treadles, treadling: ${treadling.length} picks)';
}

/// A liftplan drive: per pick, the shaft id(s) raised directly (1-based). No tie-up and no
/// treadling. The engine's `to_liftplan` can always produce one from a treadled draft, so this
/// is the canonical form the drawdown ultimately consumes; factoring a liftplan back into a
/// tie-up is deferred (CLAUDE.md), so this model never tries.
final class DraftLiftplan extends DraftDrive {
  /// Seals the caller's list so the instance is fully frozen (see [DraftTreadled]).
  DraftLiftplan({required List<List<int>> liftplan})
      : liftplan = _sealRows(liftplan);

  /// Internal constructor for an ALREADY-sealed list, used by [copyWith] to reuse an
  /// unchanged field by reference. Never call this with an unsealed list.
  const DraftLiftplan._sealed({required this.liftplan});

  /// Per pick (in weave order), the shaft id(s) raised (1-based). Deeply unmodifiable; treat
  /// as frozen, never mutate in place.
  final List<List<int>> liftplan;

  @override
  int get pickCount => liftplan.length;

  /// Variant-preserving copy: returns a [DraftLiftplan]. Re-seals only when a new list is
  /// passed (see [DraftTreadled.copyWith]).
  DraftLiftplan copyWith({List<List<int>>? liftplan}) {
    return DraftLiftplan._sealed(
      liftplan: liftplan == null ? this.liftplan : _sealRows(liftplan),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DraftLiftplan &&
          runtimeType == other.runtimeType &&
          _deepEq.equals(liftplan, other.liftplan);

  @override
  int get hashCode => Object.hash(runtimeType, _deepEq.hash(liftplan));

  @override
  String toString() => 'DraftLiftplan(${liftplan.length} picks)';
}

/// The whole editable weaving document: the immutable spine the editor mutates via pure
/// reducers (each returns a NEW [DraftDoc] via [copyWith]).
///
/// Every field mirrors a `DraftDto` field by MEANING, never by import: domain enums instead
/// of wire enums, [DraftColor]/[DraftDrive] instead of wire `ColorDto`/`DriveDto`, and plain
/// growable lists instead of typed lists. `shafts`/`treadles` are the HEADER counts (declared
/// loom capacity, mirroring WIF's `Shafts`/`Treadles`), independent of how many ends/picks
/// are currently drawn (see [ends] / [picks]); a draft may declare more shafts than it
/// threads, and a reducer may add a treadle before tying it.
///
/// DEFENSIVE IMMUTABILITY (uniform). The constructor seals every list (deep-copy into nested
/// UnmodifiableListViews) and the [DraftDrive] subclasses seal their own, so EVERY [DraftDoc],
/// whether built by [DraftDoc.blank] or by a reducer's [copyWith], is frozen identically.
/// There is no provenance-dependent behaviour: `doc.threading.add(...)` throws the same way
/// regardless of how the doc was built. The cost (one deep copy per construction) is paid once
/// per edit and is negligible next to the re-render it triggers; the payoff is that undo
/// history can never be silently corrupted.
class DraftDoc {
  /// Public constructor. Seals every list from the caller's (plain growable) input.
  DraftDoc({
    required this.name,
    required this.shafts,
    required this.treadles,
    required this.shed,
    required this.unit,
    required List<List<int>> threading,
    required this.drive,
    required List<DraftColor> palette,
    required List<int> warpColors,
    required List<int> weftColors,
    required this.notes,
  })  : threading = _sealRows(threading),
        palette = _sealList(palette),
        warpColors = _sealList(warpColors),
        weftColors = _sealList(weftColors);

  /// Internal constructor for lists that are ALREADY sealed, so [copyWith] can reuse the
  /// unchanged fields of `this` by reference (keeping the `identical()` short-circuit alive on
  /// the next equality/hash) instead of deep-copying them again. The `drive` is always an
  /// immutable, internally-sealed [DraftDrive], so it needs no special handling. Never call
  /// this with an unsealed list.
  const DraftDoc._sealed({
    required this.name,
    required this.shafts,
    required this.treadles,
    required this.shed,
    required this.unit,
    required this.threading,
    required this.drive,
    required this.palette,
    required this.warpColors,
    required this.weftColors,
    required this.notes,
  });

  /// A blank, structurally-valid document to start editing from scratch, mirroring the
  /// engine's `Draft::blank` (and the bridge's `blank_draft`) field-for-field: an empty cloth
  /// (no ends, no picks), Rising shed, inches, a tie-up sized to `treadles` (so the header
  /// matches), and a 2-color WHITE/BLACK palette (so the default color index 0 is always in
  /// range, WHITE first to match the engine).
  ///
  /// Matching the engine shape is load-bearing: a "New draft" built here must be structurally
  /// EQUAL to one fetched from Rust, otherwise the first save/round-trip would look like a
  /// spurious change to undo-dedup and the preview provider. It starts as [DraftTreadled] (not
  /// an empty liftplan) for the same reason, and so reducers can pattern-match a fresh doc
  /// without a treadled-by-default surprise. Not `const`: the tie-up is sized at runtime from
  /// `treadles`.
  factory DraftDoc.blank({int shafts = 4, int treadles = 6, String name = ''}) {
    return DraftDoc(
      name: name,
      shafts: shafts,
      treadles: treadles,
      shed: Shed.rising,
      unit: MeasureUnit.inches,
      threading: const <List<int>>[],
      drive: DraftTreadled(
        // One empty tie-up row per treadle (tied to nothing yet); no picks on a blank cloth.
        tieup: List<List<int>>.generate(treadles, (_) => const <int>[]),
        treadling: const <List<int>>[],
      ),
      palette: const <DraftColor>[
        DraftColor(r: 255, g: 255, b: 255),
        DraftColor(r: 0, g: 0, b: 0),
      ],
      warpColors: const <int>[],
      weftColors: const <int>[],
      notes: '',
    );
  }

  /// Display name of the draft.
  final String name;

  /// Header shaft count: the DECLARED loom capacity (WIF's `Shafts`), independent of [ends]
  /// and of how many shafts the threading actually uses (a draft may declare more than it
  /// threads, and a reducer may add shafts before threading them).
  final int shafts;

  /// Header treadle count: declared loom capacity (same rationale as [shafts]). Meaningful for
  /// treadled drafts; conventionally 0 for a liftplan draft.
  final int treadles;

  /// Rising vs sinking shed. The engine inverts the drawdown for sinking, so this affects the
  /// rendered cloth and therefore participates in equality (a change re-renders the preview).
  final Shed shed;

  /// Measurement unit for the draft's lengths.
  final MeasureUnit unit;

  /// Per warp end (in warp order), the shaft id(s) it threads through (1-based). In the common
  /// case each inner list is a single shaft, but doubled/multi-shaft threading is allowed,
  /// hence the nesting. DEEPLY IMMUTABLE: this list (and its rows) may be shared with undo
  /// snapshots, so never mutate either level; build a new list and pass it through [copyWith].
  final List<List<int>> threading;

  /// The raised-shaft drive: [DraftTreadled] or [DraftLiftplan]. A sealed sum type, so the
  /// illegal both/neither state is unrepresentable. Read with an exhaustive `switch`; replace
  /// wholesale via `copyWith(drive: ...)`.
  final DraftDrive drive;

  /// The color palette. `warpColors`/`weftColors` index into this list 0-based. DEEPLY
  /// IMMUTABLE; each [DraftColor] is itself immutable. Never mutate in place.
  final List<DraftColor> palette;

  /// Per warp end, a 0-based index into [palette]. Parallel to [threading] in a valid draft
  /// (same length); validation, NOT this model, enforces that parallelism. DEEPLY IMMUTABLE;
  /// never mutate in place.
  final List<int> warpColors;

  /// Per pick, a 0-based index into [palette]. Parallel to the drive's picks in a valid draft.
  /// DEEPLY IMMUTABLE; never mutate in place.
  final List<int> weftColors;

  /// Free-form notes; empty string when absent (mirrors the wire `String`, not an `Option`).
  final String notes;

  /// Number of warp ends (= columns in the drawdown), defined by the threading length (the
  /// authoritative warp axis). Mirrors the engine's `ends()` so UI, reducers, and validation
  /// read one obvious source instead of recomputing `threading.length` ad hoc. Excluded from
  /// `==`/`hashCode` (a pure function of an already-compared field).
  int get ends => threading.length;

  /// Number of picks (= rows in the drawdown), delegated to the active drive (treadling length
  /// for a treadled draft, liftplan length otherwise). Mirrors the engine's `picks()`. Also
  /// excluded from `==`/`hashCode`.
  int get picks => drive.pickCount;

  /// Produce a new [DraftDoc] with the named fields replaced. All params are nullable and
  /// default to the current value (`x ?? this.x`), matching the house style. Replacing a list
  /// passes a plain growable list which the constructor re-seals, so the result stays frozen
  /// and the PREVIOUS doc (an undo snapshot) is untouched; an UNCHANGED list is reused by
  /// reference (already sealed) so the `identical()` short-circuit fires on the next equality/
  /// hash. Replacing `drive` swaps the whole sealed [DraftDrive] wholesale (treadled <->
  /// liftplan, or an edited same-variant built via the subclass `copyWith`).
  ///
  /// NOTE: because the sentinel is `null`, `copyWith` cannot DISTINGUISH "leave unchanged" from
  /// "set to null", so it cannot clear a field. This is intentional and safe here: every field
  /// is non-nullable (notes/name default to `''`, which is a passable non-null value), so there
  /// is nothing to clear. If a future nullable field is added, give it an explicit sentinel
  /// rather than relying on `?? this.x`.
  DraftDoc copyWith({
    String? name,
    int? shafts,
    int? treadles,
    Shed? shed,
    MeasureUnit? unit,
    List<List<int>>? threading,
    DraftDrive? drive,
    List<DraftColor>? palette,
    List<int>? warpColors,
    List<int>? weftColors,
    String? notes,
  }) {
    return DraftDoc._sealed(
      name: name ?? this.name,
      shafts: shafts ?? this.shafts,
      treadles: treadles ?? this.treadles,
      shed: shed ?? this.shed,
      unit: unit ?? this.unit,
      threading: threading == null ? this.threading : _sealRows(threading),
      drive: drive ?? this.drive,
      palette: palette == null ? this.palette : _sealList(palette),
      warpColors: warpColors == null ? this.warpColors : _sealList(warpColors),
      weftColors: weftColors == null ? this.weftColors : _sealList(weftColors),
      notes: notes ?? this.notes,
    );
  }

  /// DEEP value equality. Scalars and enums compare directly, `drive` uses its own deep `==`,
  /// and every nested list routes through the SAME [_deepEq] used by [hashCode], which is what
  /// guarantees the contract (equal docs => equal hashCode). `identical` short-circuits the
  /// common "watching the same snapshot" case in O(1).
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DraftDoc &&
          runtimeType == other.runtimeType &&
          name == other.name &&
          shafts == other.shafts &&
          treadles == other.treadles &&
          shed == other.shed &&
          unit == other.unit &&
          drive == other.drive &&
          notes == other.notes &&
          _deepEq.equals(threading, other.threading) &&
          _deepEq.equals(palette, other.palette) &&
          _deepEq.equals(warpColors, other.warpColors) &&
          _deepEq.equals(weftColors, other.weftColors);

  /// `hashCode` consistent with `==`: scalars and enums by value, `drive` by its own deep hash,
  /// and every nested list by the SAME deep hash that backs `==`. This hashes the full deep
  /// contents, so it is O(total cells). That is acceptable because the consumers (undo dedup,
  /// provider memo) hash whole-doc snapshots infrequently relative to per-cell edits; if it
  /// ever shows up on a profile, the escape hatch is a content-derived cached hash or a
  /// reducer-bumped revision int hashed in its place (a deferred optimization, not premature).
  @override
  int get hashCode => Object.hash(
        name,
        shafts,
        treadles,
        shed,
        unit,
        drive,
        notes,
        _deepEq.hash(threading),
        _deepEq.hash(palette),
        _deepEq.hash(warpColors),
        _deepEq.hash(weftColors),
      );

  @override
  String toString() =>
      'DraftDoc(name: $name, ${ends}x$picks, shafts: $shafts, treadles: $treadles, '
      'shed: $shed)';
}

// ---------------------------------------------------------------------------
// Defensive sealing helpers: the ONE place lists become deeply unmodifiable.
//
// COPY-THEN-WRAP is essential. An UnmodifiableListView is only a read-only VIEW over its
// backing list; without copying first, the caller's original (mutable) list stays a live
// backdoor into our "frozen" snapshot. So we copy into a fresh list and THEN wrap it.
// ---------------------------------------------------------------------------

/// Wrap a single-level list as an unmodifiable snapshot. Copies the source into a fresh list,
/// then returns an UnmodifiableListView over that copy. Elements here (`int`, immutable
/// [DraftColor]) are themselves immutable, so a shallow copy at this level is enough.
List<T> _sealList<T>(List<T> source) =>
    UnmodifiableListView<T>(List<T>.of(source));

/// Wrap a list-of-lists so BOTH the outer and every inner list are unmodifiable. Each inner
/// row is independently sealed (copied + view-wrapped) so no row can be mutated through a
/// leaked reference, then the outer list of sealed rows is itself sealed. This is the
/// guarantee that makes a [DraftDoc] safe on the undo stack: no reachable mutable list remains
/// anywhere in the structure.
List<List<int>> _sealRows(List<List<int>> rows) =>
    UnmodifiableListView<List<int>>(
      List<List<int>>.of(rows.map(_sealList)),
    );
