// The weaver's loom profiles ("My looms", roadmap M8-02, ADR 0014): the equipment a draft can be
// checked against. Pure data, the domain twin of the bridge's `LoomProfileDto` (mirrored, not
// imported, so the UI and state layers never touch generated symbols; `LoomRepository` maps them).
//
// Every equipment field may be missing. Unknown is not zero: a count the weaver did not give is null
// (or an empty reed list), and the engine's check then says it could not check it.

import 'package:collection/collection.dart';

import 'draft_doc.dart' show MeasureUnit;
import 'loom_type.dart';

/// The engine's limits for a profile (`ply_weave::loom`), checked again here so the form can say
/// what is wrong before anything is saved.
abstract final class LoomLimits {
  static const int maxShafts = 200;
  static const int maxTreadles = 200;
  static const int maxTreadlesAtOnce = 10;
  static const double maxWidth = 10000;
  static const double maxReedDents = 1000;
  static const int maxReeds = 20;
  static const int maxNameChars = 100;
  static const int maxNotesChars = 4000;

  /// The most looms `looms.json` holds (`ply_weave::loom_file::MAX_LOOMS`).
  static const int maxLooms = 200;

  /// The largest sett the check accepts, in ends per inch.
  static const double maxSettPerInch = 1000;

  /// The smallest sett the check accepts, in ends per inch.
  static const double minSettPerInch = 0.01;
}

/// A number as a weaver writes it: at most one decimal, no trailing ".0" (12, 12.5, 0.8). The same
/// rule as the engine's messages.
String formatLoomNumber(double v) {
  final r = (v * 10).roundToDouble() / 10;
  if ((r - r.roundToDouble()).abs() < 1e-9) return r.round().toString();
  return r.toStringAsFixed(1);
}

/// [v] exactly, for a text field to start from: the shortest text that reads back as the same number
/// (12.25, not the 12.3 [formatLoomNumber] shows), without a trailing ".0". A field pre-filled this
/// way reads back unchanged, so opening and closing a form changes nothing.
String exactLoomNumber(double v) =>
    v.isFinite && v == v.truncateToDouble() && v.abs() < 1e15 ? v.toInt().toString() : v.toString();

/// [text] cut to at most [max] characters, counted as Unicode code points the way the engine counts
/// them (never splitting one).
String clipToRunes(String text, int max) =>
    text.runes.length <= max ? text : String.fromCharCodes(text.runes.take(max));

/// A length with its unit.
class LoomLength {
  const LoomLength(this.value, this.unit);

  final double value;
  final MeasureUnit unit;

  /// "36 in", "90 cm".
  String get label => '${formatLoomNumber(value)} ${unit == MeasureUnit.inches ? 'in' : 'cm'}';

  @override
  bool operator ==(Object other) =>
      other is LoomLength && other.value == value && other.unit == unit;

  @override
  int get hashCode => Object.hash(value, unit);

  @override
  String toString() => 'LoomLength($label)';
}

/// How a reed's dents are counted: per inch, or per 10 cm (a metric reed number such as 40/10).
enum DentUnit { perInch, per10cm }

/// One reed: dents per inch or per 10 cm.
class Reed {
  const Reed(this.dents, this.per);

  final double dents;
  final DentUnit per;

  /// "12-dent" or "40/10".
  String get shortLabel =>
      per == DentUnit.perInch ? '${formatLoomNumber(dents)}-dent' : '${formatLoomNumber(dents)}/10';

  /// "12 dents per inch" or "40 dents per 10 cm".
  String get label =>
      '${formatLoomNumber(dents)} dents per ${per == DentUnit.perInch ? 'inch' : '10 cm'}';

  @override
  bool operator ==(Object other) => other is Reed && other.dents == dents && other.per == per;

  @override
  int get hashCode => Object.hash(dents, per);

  @override
  String toString() => 'Reed($label)';
}

/// One loom, as the weaver describes it.
class LoomProfile {
  const LoomProfile({
    required this.id,
    this.name = '',
    this.type,
    this.shafts,
    this.treadles,
    this.weavingWidth,
    this.reeds = const [],
    this.treadlesAtOnce,
    this.notes = '',
  });

  /// Stable id (a uuid); drafts refer to the loom by it.
  final String id;

  /// What the weaver calls the loom. May be empty.
  final String name;

  /// The loom type, or null when not recorded.
  final LoomType? type;
  final int? shafts;

  /// Treadles on a floor loom (a table loom has a lever per shaft, a dobby selects the shafts).
  final int? treadles;

  /// The widest warp the loom takes in the reed.
  final LoomLength? weavingWidth;

  /// The reeds the weaver has; empty = none recorded.
  final List<Reed> reeds;

  /// The most treadles the weaver presses together for one pick.
  final int? treadlesAtOnce;
  final String notes;

  /// The name to show: the trimmed name, or "Unnamed loom".
  String get displayName => name.trim().isEmpty ? 'Unnamed loom' : name.trim();

  /// One line for a list: "Jack (floor loom), 8 shafts, 10 treadles, 36 in". Only what is recorded.
  String get summary {
    final parts = <String>[
      if (type != null) type!.label,
      if (shafts != null) '$shafts ${shafts == 1 ? 'shaft' : 'shafts'}',
      if (treadles != null) '$treadles ${treadles == 1 ? 'treadle' : 'treadles'}',
      if (weavingWidth != null) '${weavingWidth!.label} wide',
      if (reeds.isNotEmpty) reeds.length == 1 ? '1 reed' : '${reeds.length} reeds',
    ];
    return parts.isEmpty ? 'Nothing recorded yet' : parts.join(', ');
  }

  LoomProfile copyWith({
    String? id,
    String? name,
    LoomType? type,
    bool clearType = false,
    int? shafts,
    bool clearShafts = false,
    int? treadles,
    bool clearTreadles = false,
    LoomLength? weavingWidth,
    bool clearWeavingWidth = false,
    List<Reed>? reeds,
    int? treadlesAtOnce,
    bool clearTreadlesAtOnce = false,
    String? notes,
  }) =>
      LoomProfile(
        id: id ?? this.id,
        name: name ?? this.name,
        type: clearType ? null : (type ?? this.type),
        shafts: clearShafts ? null : (shafts ?? this.shafts),
        treadles: clearTreadles ? null : (treadles ?? this.treadles),
        weavingWidth: clearWeavingWidth ? null : (weavingWidth ?? this.weavingWidth),
        reeds: reeds ?? this.reeds,
        treadlesAtOnce: clearTreadlesAtOnce ? null : (treadlesAtOnce ?? this.treadlesAtOnce),
        notes: notes ?? this.notes,
      );

  /// Every field in a fixed order, as text: equal profiles give equal keys (a restore compares and
  /// hashes looms with it).
  String get canonicalKey => [
        id,
        name,
        type?.serialName ?? '',
        shafts ?? '',
        treadles ?? '',
        weavingWidth == null ? '' : '${weavingWidth!.value} ${weavingWidth!.unit.name}',
        for (final r in reeds) '${r.dents} ${r.per.name}',
        treadlesAtOnce ?? '',
        notes,
      ].join('\u0000');

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LoomProfile &&
          other.id == id &&
          other.name == name &&
          other.type == type &&
          other.shafts == shafts &&
          other.treadles == treadles &&
          other.weavingWidth == weavingWidth &&
          const ListEquality<Reed>().equals(other.reeds, reeds) &&
          other.treadlesAtOnce == treadlesAtOnce &&
          other.notes == notes;

  @override
  int get hashCode => Object.hash(id, name, type, shafts, treadles, weavingWidth,
      const ListEquality<Reed>().hash(reeds), treadlesAtOnce, notes);

  @override
  String toString() => 'LoomProfile($id, $displayName)';
}
