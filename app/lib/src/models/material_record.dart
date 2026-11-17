// Materials and swatch records (roadmap M8-01, ADR 0016): the domain twins of the bridge's
// `MaterialDto` and `SwatchDto` (mirrored, not imported, so the UI and state layers never touch
// generated symbols; `MaterialsRepository` maps them), with unit-aware quantities, where each number
// came from, the engine's diagnostics and derived figures, and traced planning estimates. Pure data.
//
// Every field may be missing, and unknown is never zero: a value the crafter did not give is null
// (or empty text). Derived figures are never stored: the engine works them out from the measurements
// each time they are shown.

import 'dart:convert';

import 'package:collection/collection.dart';

/// A unit of length.
enum LengthUnit {
  millimeter('mm', true),
  centimeter('cm', true),
  meter('m', true),
  inch('in', false),
  yard('yd', false);

  const LengthUnit(this.symbol, this.isMetric);

  /// "mm", "cm", "m", "in", "yd" (also the file's spelling).
  final String symbol;
  final bool isMetric;

  /// The unit's exact size in micrometres.
  double get micrometers => switch (this) {
        LengthUnit.millimeter => 1000,
        LengthUnit.centimeter => 10000,
        LengthUnit.meter => 1000000,
        LengthUnit.inch => 25400,
        LengthUnit.yard => 914400,
      };

  static LengthUnit? bySymbol(Object? s) => values.firstWhereOrNull((u) => u.symbol == s);
}

/// A unit of mass.
enum MassUnit {
  gram('g'),
  kilogram('kg'),
  ounce('oz'),
  pound('lb');

  const MassUnit(this.symbol);

  final String symbol;

  static MassUnit? bySymbol(Object? s) => values.firstWhereOrNull((u) => u.symbol == s);
}

/// Where a value came from (the engine's `Source`). A stored record only ever holds [measured] or
/// [entered]; [plyDefault] appears in estimates.
enum ValueSource {
  /// The crafter measured it (counted, wrapped, weighed, measured).
  measured('measured', 'Measured'),

  /// The crafter typed it from somewhere else: a ball band, a pattern, their own setup.
  entered('entered', 'Entered'),

  /// Ply's default or rule of thumb.
  plyDefault('default', 'Ply default');

  const ValueSource(this.serialName, this.label);

  final String serialName;
  final String label;

  static ValueSource? bySerialName(Object? s) => values.firstWhereOrNull((v) => v.serialName == s);
}

/// A number as a crafter writes it: at most two decimals, no trailing zeros (20, 22.5, 0.25).
String formatQuantityNumber(double v) {
  if (!v.isFinite) return '?';
  var s = ((v * 100).roundToDouble() / 100).toStringAsFixed(2);
  if (s.contains('.')) {
    s = s.replaceFirst(RegExp(r'0+$'), '');
    if (s.endsWith('.')) s = s.substring(0, s.length - 1);
  }
  return s == '-0' ? '0' : s;
}

/// [v] exactly, for a text field to start from: the shortest text that reads back as the same
/// number, without a trailing ".0".
String exactQuantityNumber(double v) =>
    v.isFinite && v == v.truncateToDouble() && v.abs() < 1e15 ? v.toInt().toString() : v.toString();

/// A length in the unit it was given in.
class Length {
  const Length(this.value, this.unit);

  final double value;
  final LengthUnit unit;

  /// This length in [to] (exact factors).
  double inUnit(LengthUnit to) => to == unit ? value : value * unit.micrometers / to.micrometers;

  /// "10 cm".
  String get label => '${formatQuantityNumber(value)} ${unit.symbol}';

  Map<String, Object?> toMap() => {'value': value, 'unit': unit.symbol};

  @override
  bool operator ==(Object other) => other is Length && other.value == value && other.unit == unit;

  @override
  int get hashCode => Object.hash(value, unit);

  @override
  String toString() => 'Length($label)';
}

/// A mass in the unit it was given in.
class Mass {
  const Mass(this.value, this.unit);

  final double value;
  final MassUnit unit;

  String get label => '${formatQuantityNumber(value)} ${unit.symbol}';

  Map<String, Object?> toMap() => {'value': value, 'unit': unit.symbol};

  @override
  bool operator ==(Object other) => other is Mass && other.value == value && other.unit == unit;

  @override
  int get hashCode => Object.hash(value, unit);

  @override
  String toString() => 'Mass($label)';
}

/// How much yarn a mass holds, as given: "200 m per 100 g".
class LengthPerMass {
  const LengthPerMass(this.length, this.mass);

  final Length length;
  final Mass mass;

  String get label => '${length.label} per ${mass.label}';

  Map<String, Object?> toMap() => {'length': length.toMap(), 'mass': mass.toMap()};

  @override
  bool operator ==(Object other) =>
      other is LengthPerMass && other.length == length && other.mass == mass;

  @override
  int get hashCode => Object.hash(length, mass);
}

/// A count over a span, as counted: "20 sts over 10 cm", "24 ends over 1 in".
class CountOver {
  const CountOver(this.count, this.over);

  final double count;
  final Length over;

  /// The count over [span] at this density.
  double per(Length span) => count * span.inUnit(over.unit) / over.value;

  /// "20 sts per 10 cm" (per a usual span: one unit, 10 cm, 4 in), "11 sts over 5 cm".
  String label(String noun) {
    final usual = over.value == 1 ||
        (over.value == 10 && over.unit == LengthUnit.centimeter) ||
        (over.value == 4 && over.unit == LengthUnit.inch);
    if (over.value == 1) return '${formatQuantityNumber(count)} $noun per ${over.unit.symbol}';
    return '${formatQuantityNumber(count)} $noun ${usual ? 'per' : 'over'} ${over.label}';
  }

  Map<String, Object?> toMap() => {'count': count, 'over': over.toMap()};

  @override
  bool operator ==(Object other) =>
      other is CountOver && other.count == count && other.over == over;

  @override
  int get hashCode => Object.hash(count, over);
}

/// A stored value with where it came from.
class Recorded<T> {
  const Recorded(this.value, this.source);

  const Recorded.measured(this.value) : source = ValueSource.measured;
  const Recorded.entered(this.value) : source = ValueSource.entered;

  final T value;
  final ValueSource source;

  @override
  bool operator ==(Object other) =>
      other is Recorded<T> && other.value == value && other.source == source;

  @override
  int get hashCode => Object.hash(value, source);
}

/// The engine's limits for a record (`ply_common::materials`), checked again by the forms.
abstract final class MaterialLimits {
  static const int maxNameChars = 100;
  static const int maxShortTextChars = 200;
  static const int maxNotesChars = 4000;
  static const int maxFibers = 8;
  static const int maxSwatchYarns = 8;
  static const double maxValue = 1000000;

  /// The most of each record `materials.json` holds.
  static const int maxMaterials = 500;
  static const int maxSwatches = 500;
}

/// The Craft Yarn Council weight categories.
enum YarnWeightCategory {
  lace('lace', '0 Lace'),
  superFine('super_fine', '1 Super fine (fingering, sock)'),
  fine('fine', '2 Fine (sport)'),
  light('light', '3 Light (DK)'),
  medium('medium', '4 Medium (worsted, aran)'),
  bulky('bulky', '5 Bulky'),
  superBulky('super_bulky', '6 Super bulky'),
  jumbo('jumbo', '7 Jumbo');

  const YarnWeightCategory(this.serialName, this.label);

  final String serialName;
  final String label;
}

/// One fiber of a blend; the percentage may be unknown.
class FiberPart {
  const FiberPart(this.fiber, [this.percent]);

  final String fiber;
  final double? percent;

  String get label => percent == null ? fiber : '$fiber ${formatQuantityNumber(percent!)}%';

  @override
  bool operator ==(Object other) =>
      other is FiberPart && other.fiber == fiber && other.percent == percent;

  @override
  int get hashCode => Object.hash(fiber, percent);
}

/// A material: a yarn or thread the crafter has or has used.
class MaterialRecord {
  const MaterialRecord({
    required this.id,
    this.name = '',
    this.maker = '',
    this.fibers = const [],
    this.weight,
    this.structure = '',
    this.lengthPerMass,
    this.wpi,
    this.color = '',
    this.dyeLot = '',
    this.availableMass,
    this.availableLength,
    this.notes = '',
  });

  final String id;
  final String name;
  final String maker;
  final List<FiberPart> fibers;
  final YarnWeightCategory? weight;
  final String structure;
  final Recorded<LengthPerMass>? lengthPerMass;
  final Recorded<CountOver>? wpi;
  final String color;
  final String dyeLot;
  final Recorded<Mass>? availableMass;
  final Recorded<Length>? availableLength;
  final String notes;

  String get displayName => name.trim().isEmpty ? 'Unnamed material' : name.trim();

  /// One line for a list: "3 Light (DK), wool 80%, nylon 20%, 200 m per 100 g". Only what is
  /// recorded.
  String get summary {
    final parts = <String>[
      if (weight != null) weight!.label,
      if (fibers.isNotEmpty) fibers.map((f) => f.label).join(', '),
      if (lengthPerMass != null) lengthPerMass!.value.label,
      if (color.trim().isNotEmpty) color.trim(),
    ];
    return parts.isEmpty ? 'Nothing recorded yet' : parts.join(', ');
  }

  MaterialRecord copyWith({String? id, String? name}) => MaterialRecord(
        id: id ?? this.id,
        name: name ?? this.name,
        maker: maker,
        fibers: fibers,
        weight: weight,
        structure: structure,
        lengthPerMass: lengthPerMass,
        wpi: wpi,
        color: color,
        dyeLot: dyeLot,
        availableMass: availableMass,
        availableLength: availableLength,
        notes: notes,
      );

  /// The engine's JSON shape of this record (for equality, digests and host-test stand-ins; the
  /// engine is the file's owner).
  Map<String, Object?> toMap() => {
        'id': id,
        'name': name,
        'maker': maker,
        'fibers': [
          for (final f in fibers) {'fiber': f.fiber, 'percent': f.percent}
        ],
        'weight': weight?.serialName,
        'structure': structure,
        'length_per_mass': _rec(lengthPerMass, (v) => v.toMap()),
        'wpi': _rec(wpi, (v) => v.toMap()),
        'color': color,
        'dye_lot': dyeLot,
        'available_mass': _rec(availableMass, (v) => v.toMap()),
        'available_length': _rec(availableLength, (v) => v.toMap()),
        'notes': notes,
      };

  /// Every field in a fixed order, as text: equal records give equal keys.
  String get canonicalKey => jsonEncode(toMap());

  @override
  bool operator ==(Object other) => other is MaterialRecord && other.canonicalKey == canonicalKey;

  @override
  int get hashCode => canonicalKey.hashCode;

  @override
  String toString() => 'MaterialRecord($id, $displayName)';
}

Map<String, Object?>? _rec<T>(Recorded<T>? r, Map<String, Object?> Function(T) f) =>
    r == null ? null : {'value': f(r.value), 'source': r.source.serialName};

/// What a yarn is for, in a swatch or a project.
enum YarnRole {
  main('main', 'Main yarn'),
  contrast('contrast', 'Contrast'),
  warp('warp', 'Warp'),
  weft('weft', 'Weft');

  const YarnRole(this.serialName, this.label);

  final String serialName;
  final String label;

  static YarnRole? bySerialName(Object? s) => values.firstWhereOrNull((r) => r.serialName == s);
}

/// The craft of a swatch.
enum SwatchCraft {
  weaving('weaving', 'Weaving'),
  knitting('knitting', 'Knitting'),
  nalbinding('nalbinding', 'Nalbinding');

  const SwatchCraft(this.serialName, this.label);

  final String serialName;
  final String label;
}

/// A yarn used in a swatch: a material (with its name as it was then), or a name alone.
class SwatchYarn {
  const SwatchYarn({this.materialId, this.name = '', this.role});

  final String? materialId;
  final String name;
  final YarnRole? role;

  @override
  bool operator ==(Object other) =>
      other is SwatchYarn &&
      other.materialId == materialId &&
      other.name == name &&
      other.role == role;

  @override
  int get hashCode => Object.hash(materialId, name, role);
}

/// The stages a swatch is measured at.
enum StageKind { onLoom, before, after }

/// What was measured at one stage.
class SwatchStage {
  const SwatchStage({this.width, this.length, this.across, this.along, this.conditions = ''});

  final Recorded<Length>? width;
  final Recorded<Length>? length;

  /// Stitches (knitting, nalbinding) or ends (weaving) across the width, over a span.
  final Recorded<CountOver>? across;

  /// Rows or rounds (knitting, nalbinding) or picks (weaving) along the length.
  final Recorded<CountOver>? along;
  final String conditions;

  bool get isEmpty =>
      width == null &&
      length == null &&
      across == null &&
      along == null &&
      conditions.trim().isEmpty;

  Map<String, Object?> toMap() => {
        'width': _rec(width, (v) => v.toMap()),
        'length': _rec(length, (v) => v.toMap()),
        'across': _rec(across, (v) => v.toMap()),
        'along': _rec(along, (v) => v.toMap()),
        'conditions': conditions,
      };
}

/// A measured sample.
class SwatchRecord {
  const SwatchRecord({
    required this.id,
    this.name = '',
    this.craft,
    this.technique = '',
    this.date,
    this.yarns = const [],
    this.tools = '',
    this.sett,
    this.widthInReed,
    this.onLoom = const SwatchStage(),
    this.before = const SwatchStage(),
    this.after = const SwatchStage(),
    this.finishing = '',
    this.mass,
    this.tension = '',
    this.provenance = '',
    this.notes = '',
  });

  final String id;
  final String name;
  final SwatchCraft? craft;

  /// The stitch pattern, weave structure, or nalbinding stitch and connection.
  final String technique;

  /// `YYYY-MM-DD`.
  final String? date;
  final List<SwatchYarn> yarns;

  /// Needles, hook or nalbinding needle; the loom and reed.
  final String tools;

  /// Weaving: the sett in the reed.
  final Recorded<CountOver>? sett;

  /// Weaving: the warp's width in the reed.
  final Recorded<Length>? widthInReed;
  final SwatchStage onLoom;
  final SwatchStage before;
  final SwatchStage after;
  final String finishing;
  final Recorded<Mass>? mass;
  final String tension;
  final String provenance;
  final String notes;

  String get displayName => name.trim().isEmpty ? 'Unnamed swatch' : name.trim();

  bool get isWeaving => craft == SwatchCraft.weaving;

  /// "sts" or "ends".
  String get acrossNoun => isWeaving ? 'ends' : 'sts';

  /// "rows" or "picks".
  String get alongNoun => isWeaving ? 'picks' : 'rows';

  SwatchStage stage(StageKind k) => switch (k) {
        StageKind.onLoom => onLoom,
        StageKind.before => before,
        StageKind.after => after,
      };

  /// The stage name for this swatch's craft: "on the loom", "off the loom", "after wet finishing",
  /// "before finishing", "after finishing" (the engine's words).
  String stageName(StageKind k) => switch (k) {
        StageKind.onLoom => 'on the loom',
        StageKind.before => isWeaving ? 'off the loom' : 'before finishing',
        StageKind.after => isWeaving ? 'after wet finishing' : 'after finishing',
      };

  /// The count across a plan uses (after finishing first, else before), with its stage.
  (Recorded<CountOver>, StageKind)? get planningAcross {
    if (after.across != null) return (after.across!, StageKind.after);
    if (before.across != null) return (before.across!, StageKind.before);
    return null;
  }

  /// One line for a list: "Knitting, stockinette, 2026-11-10, 20 sts per 10 cm after finishing".
  String get summary {
    final across = planningAcross;
    final parts = <String>[
      if (craft != null) craft!.label,
      if (technique.trim().isNotEmpty) technique.trim(),
      if (date != null) date!,
      if (isWeaving && sett != null) '${sett!.value.label('ends')} in the reed',
      if (!isWeaving && across != null)
        '${across.$1.value.label(acrossNoun)} ${stageName(across.$2)}',
    ];
    return parts.isEmpty ? 'Nothing recorded yet' : parts.join(', ');
  }

  /// The engine's JSON shape of this record (for equality, digests and host-test stand-ins).
  Map<String, Object?> toMap() => {
        'id': id,
        'name': name,
        'craft': craft?.serialName,
        'technique': technique,
        'date': date,
        'yarns': [
          for (final y in yarns)
            {'material_id': y.materialId, 'name': y.name, 'role': y.role?.serialName}
        ],
        'tools': tools,
        'sett': _rec(sett, (v) => v.toMap()),
        'width_in_reed': _rec(widthInReed, (v) => v.toMap()),
        'on_loom': onLoom.toMap(),
        'before': before.toMap(),
        'after': after.toMap(),
        'finishing': finishing,
        'mass': _rec(mass, (v) => v.toMap()),
        'tension': tension,
        'provenance': provenance,
        'notes': notes,
      };

  String get canonicalKey => jsonEncode(toMap());

  SwatchRecord copyWith({String? id, String? name}) => SwatchRecord(
        id: id ?? this.id,
        name: name ?? this.name,
        craft: craft,
        technique: technique,
        date: date,
        yarns: yarns,
        tools: tools,
        sett: sett,
        widthInReed: widthInReed,
        onLoom: onLoom,
        before: before,
        after: after,
        finishing: finishing,
        mass: mass,
        tension: tension,
        provenance: provenance,
        notes: notes,
      );

  @override
  bool operator ==(Object other) => other is SwatchRecord && other.canonicalKey == canonicalKey;

  @override
  int get hashCode => canonicalKey.hashCode;

  @override
  String toString() => 'SwatchRecord($id, $displayName)';
}

/// [text] cut to at most [max] characters, counted as Unicode code points the way the engine counts
/// them.
String clipRunes(String text, int max) =>
    text.runes.length <= max ? text : String.fromCharCodes(text.runes.take(max));

// --- engine reports ------------------------------------------------------------------------------

/// One finding about a record (the engine's `RecordDiagnostic`). [code] is stable; [field] is the
/// value's path (`after.width`).
class RecordDiagnostic {
  const RecordDiagnostic({
    required this.code,
    required this.isError,
    required this.field,
    required this.message,
  });

  final String code;

  /// An error cannot be saved; a warning is worth checking.
  final bool isError;
  final String field;
  final String message;

  @override
  bool operator ==(Object other) =>
      other is RecordDiagnostic &&
      other.code == code &&
      other.isError == isError &&
      other.field == field &&
      other.message == message;

  @override
  int get hashCode => Object.hash(code, isError, field, message);
}

/// One figure the engine works out from a record (never stored).
class Figure {
  const Figure({
    required this.code,
    required this.label,
    required this.value,
    required this.text,
    required this.from,
  });

  final String code;
  final String label;

  /// A count, a length, or a FRACTION for percentages.
  final double value;
  final String text;
  final String from;
}

/// A record's diagnostics and figures.
class RecordReport {
  const RecordReport({this.diagnostics = const [], this.figures = const []});

  static const RecordReport empty = RecordReport();

  final List<RecordDiagnostic> diagnostics;
  final List<Figure> figures;

  bool get hasErrors => diagnostics.any((d) => d.isError);
}

// --- traced estimates ----------------------------------------------------------------------------

/// One input of an estimate with where it came from (the engine's `TracedInput`).
class TracedInput {
  const TracedInput({
    required this.key,
    required this.label,
    required this.value,
    required this.source,
    required this.basis,
    this.swatchId,
    this.materialId,
  });

  final String key;
  final String label;
  final String value;
  final ValueSource source;

  /// "measured after finishing, swatch Grey wool 2026-11-10", "you entered it", "Ply's default".
  final String basis;
  final String? swatchId;
  final String? materialId;

  /// "20 sts per 10 cm, measured after finishing, swatch Grey wool 2026-11-10".
  String get sentence => '$value, $basis';
}

/// A planning result with every input it used and how it was worked out.
class TracedEstimate<T> {
  const TracedEstimate({
    required this.value,
    required this.inputs,
    this.working = const [],
    this.notes = const [],
  });

  final T value;
  final List<TracedInput> inputs;
  final List<String> working;
  final List<String> notes;

  bool get hasDefaults => inputs.any((i) => i.source == ValueSource.plyDefault);
}

/// Where one input of a planning request comes from (the engine's `Origin`).
enum InputOrigin {
  /// From the swatch in use (the engine reads the swatch's own measurement).
  swatch,
  entered,
  plyDefault,

  /// From the open pattern or draft.
  pattern,
}

/// An input value with its origin and, for a default or a pattern value, what it is.
class PlanInput<T> {
  const PlanInput(this.origin, this.value, {this.note = ''});

  const PlanInput.swatch()
      : origin = InputOrigin.swatch,
        value = null,
        note = '';

  final InputOrigin origin;

  /// Null for [InputOrigin.swatch].
  final T? value;
  final String note;
}

/// A knitting yarn estimate.
class YarnAmount {
  const YarnAmount({
    required this.weighed,
    required this.yards,
    required this.meters,
    required this.bufferedYards,
    required this.bufferedMeters,
  });

  /// True for the weighed-swatch method, false for the stockinette rule of thumb.
  final bool weighed;
  final double yards;
  final double meters;
  final double bufferedYards;
  final double bufferedMeters;
}

/// A weaving warp estimate.
class WarpAmount {
  const WarpAmount({required this.ends, required this.warpLength, required this.total});

  final int ends;
  final Length warpLength;
  final Length total;
}

/// A weaving weft estimate.
class WeftAmount {
  const WeftAmount({required this.picks, required this.total});

  final int picks;
  final Length total;
}
