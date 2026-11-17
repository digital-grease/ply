// The warp, weft and finishing plan of a weaving draft (roadmap M8-03, ADR 0019), kept in the
// draft's sidecar under one additive key:
//
//   "weavePlan": { "version": 1, "structure": "twill", "items": 4,
//                  "finishedWidth": {"value": 18, "unit": "in"}, ...,
//                  "swatchId": "...", "swatchName": "...", "overrides": {"takeUp": 0.12} }
//
// The plan holds the weaver's choices only: the finished size and allowances, the structure that
// picks Ply's starting estimates, the swatch and yarns it names (by id, with their names as they
// were), and the assumptions the weaver overrode. It never copies a measurement out of a swatch or a
// material, and nothing here writes into one. Unknown keys (in the plan and in its overrides) are
// kept and written back; a plan of a newer version is not read (the sidecar keeps it as it is). The
// engine's twin (`ply_weave::worksheet::WeavePlan`) reads the same shape for the fixtures.
//
// Also here: the worksheet the engine works out from a plan (pure data, the domain twin of the
// bridge's `WorksheetDto`).

import 'package:collection/collection.dart';

import 'loom_check.dart' show LoomSeverity, Sett;
import 'loom_profile.dart' show DentUnit, Reed;
import 'material_record.dart';

/// The structure the starting estimates are chosen for.
enum PlanStructure {
  plain('plain', 'Plain weave'),
  twill('twill', 'Twill'),
  satin('satin', 'Satin'),
  other('other', 'Another structure');

  const PlanStructure(this.serialName, this.label);

  final String serialName;
  final String label;

  static PlanStructure? bySerialName(Object? s) =>
      values.firstWhereOrNull((v) => v.serialName == s);
}

/// One assumption the weaver can override. [jsonKey] is its key in `overrides`.
enum PlanAssumption {
  takeUp('takeUp', 'take-up', 'Take-up',
      'The length the cloth loses from the loom to off the loom, as a share of the length on the loom. A negative value is a gain.'),
  lengthShrinkage('lengthShrinkage', 'length shrinkage', 'Length shrinkage',
      'The length lost in wet finishing, as a share of the length off the loom. A negative value is a gain.'),
  drawIn('drawIn', 'draw-in', 'Draw-in',
      'How much narrower the cloth weaves than the warp in the reed, as a share of the width in the reed. A negative value is a gain (weft-faced cloth can spread).'),
  widthShrinkage('widthShrinkage', 'width shrinkage', 'Width shrinkage',
      'The width lost in wet finishing, as a share of the width off the loom. A negative value is a gain.'),
  weftAllowance('weftAllowance', 'weft allowance', 'Weft allowance',
      'Extra weft in each pick for its crimp and the turns at the selvedges, as a share of the width in the reed.'),
  loomWaste('loomWaste', 'loom waste', 'Loom waste',
      'Warp that cannot be woven: tying on, and the length left behind the heddles. Your own loom\'s measured waste is better than an estimate.'),
  sett('sett', 'sett', 'Sett', 'Ends per inch or per cm in the reed.'),
  wpi('wpi', 'wraps per inch', 'Wraps per inch',
      'Wraps of the warp yarn side by side over a span. Ply takes a share of it as a starting sett, a rule of thumb for the structure.'),
  ppi('ppi', 'picks', 'Picks', 'Picks per inch or per cm, counted on the loom under tension.'),
  ends('ends', 'warp ends', 'Warp ends',
      'Your own number of warp ends. Without it, Ply works them out from the finished width.'),
  reed('reed', 'reed', 'Reed', 'The reed to sley, in dents per inch or per 10 cm.');

  const PlanAssumption(this.jsonKey, this.noun, this.label, this.explanation);

  final String jsonKey;

  /// "take-up", for "Change take-up".
  final String noun;
  final String label;

  /// What it is, with its denominator, for the edit dialog.
  final String explanation;

  /// Whether the value is a fraction (shown and entered as a percentage).
  bool get isFraction => switch (this) {
        takeUp || lengthShrinkage || drawIn || widthShrinkage || weftAllowance => true,
        _ => false,
      };

  /// The engine input keys whose value this assumption sets.
  static List<PlanAssumption> forInput(String key) => switch (key) {
        'take_up' => const [takeUp],
        'length_shrinkage' => const [lengthShrinkage],
        'length_loss' => const [takeUp, lengthShrinkage],
        'draw_in' => const [drawIn],
        'width_shrinkage' => const [widthShrinkage],
        'width_loss' => const [drawIn, widthShrinkage],
        'weft_allowance' => const [weftAllowance],
        'loom_waste' => const [loomWaste],
        'sett' => const [sett, wpi],
        // The wraps give a starting sett: the sett can be entered from the same row.
        'wpi' => const [sett, wpi],
        'ppi' => const [ppi],
        'ends' => const [ends],
        'reed' => const [reed],
        _ => const [],
      };
}

Length? lengthFromJson(Object? m) {
  if (m is! Map) return null;
  final v = m['value'];
  final u = LengthUnit.bySymbol(m['unit']);
  if (v is! num || u == null || !v.isFinite) return null;
  return Length(v.toDouble(), u);
}

CountOver? countFromJson(Object? m) {
  if (m is! Map) return null;
  final c = m['count'];
  final over = lengthFromJson(m['over']);
  if (c is! num || !c.isFinite || over == null) return null;
  return CountOver(c.toDouble(), over);
}

Reed? reedFromJson(Object? m) {
  if (m is! Map) return null;
  final d = m['dents'];
  final per = switch (m['per']) {
    'inch' => DentUnit.perInch,
    '10cm' => DentUnit.per10cm,
    _ => null,
  };
  if (d is! num || !d.isFinite || per == null) return null;
  return Reed(d.toDouble(), per);
}

Map<String, Object?> reedToJson(Reed r) =>
    {'dents': r.dents, 'per': r.per == DentUnit.perInch ? 'inch' : '10cm'};

/// The weaver's own values for the assumptions. A missing one is the swatch's (when the chosen
/// swatch measured it), else Ply's starting estimate.
class PlanOverrides {
  PlanOverrides(
      {Map<PlanAssumption, Object> values = const {}, Map<String, Object?> extra = const {}})
      : values = Map.unmodifiable(values),
        extra = Map.unmodifiable(extra);

  /// Each overridden assumption's value: a double (fractions), a [Length] (loom waste), a
  /// [CountOver] (sett, wraps, picks), an int (ends) or a [Reed].
  final Map<PlanAssumption, Object> values;

  /// Keys this build does not read, and values of known keys it could not read, kept as they were.
  final Map<String, Object?> extra;

  static final PlanOverrides none = PlanOverrides();

  bool has(PlanAssumption a) => values.containsKey(a);

  T? value<T>(PlanAssumption a) {
    final v = values[a];
    return v is T ? v : null;
  }

  /// With [a] set to [value], or taken out (the way back to the swatch or the estimate) when
  /// [value] is null. A value this build could not read under the same key is dropped.
  PlanOverrides set(PlanAssumption a, Object? value) => PlanOverrides(
        values: {
          for (final e in values.entries)
            if (e.key != a) e.key: e.value,
          if (value != null) a: value,
        },
        extra: {
          for (final e in extra.entries)
            if (e.key != a.jsonKey) e.key: e.value,
        },
      );

  Map<String, Object?> toJson() => {
        for (final a in PlanAssumption.values)
          if (values[a] case final v?)
            a.jsonKey: switch (v) {
              final Length l => l.toMap(),
              final CountOver c => c.toMap(),
              final Reed r => reedToJson(r),
              _ => v,
            },
        ...extra,
      };

  static PlanOverrides fromJson(Object? json) {
    if (json is! Map) return PlanOverrides();
    final values = <PlanAssumption, Object>{};
    final extra = <String, Object?>{};
    for (final e in json.entries) {
      final a = PlanAssumption.values.firstWhereOrNull((a) => a.jsonKey == e.key);
      final raw = e.value;
      final Object? v = switch (a) {
        null => null,
        PlanAssumption.loomWaste => lengthFromJson(raw),
        PlanAssumption.sett || PlanAssumption.wpi || PlanAssumption.ppi => countFromJson(raw),
        PlanAssumption.reed => reedFromJson(raw),
        PlanAssumption.ends => raw is int ? raw : null,
        _ => raw is num && raw.isFinite ? raw.toDouble() : null,
      };
      if (a != null && v != null) {
        values[a] = v;
      } else {
        extra['${e.key}'] = raw;
      }
    }
    return PlanOverrides(values: values, extra: extra);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PlanOverrides && const DeepCollectionEquality().equals(other.toJson(), toJson());

  @override
  int get hashCode => const DeepCollectionEquality().hash(toJson());
}

/// A draft's warp, weft and finishing plan.
class WeavePlan {
  WeavePlan({
    this.structure = PlanStructure.plain,
    this.items = 1,
    this.finishedWidth,
    this.finishedLength,
    this.hems,
    this.fringe,
    this.sampling,
    this.endMultiple,
    this.extraEnds = 0,
    this.swatchId,
    this.swatchName,
    this.warpMaterialId,
    this.warpMaterialName,
    this.weftMaterialId,
    this.weftMaterialName,
    PlanOverrides? overrides,
    Map<String, Object?> extra = const {},
  })  : overrides = overrides ?? PlanOverrides.none,
        extra = Map.unmodifiable(extra);

  /// The sidecar key.
  static const String key = 'weavePlan';

  /// The record version this build reads and writes.
  static const int version = 1;

  /// The most items, ends or ends in a repeat (the engine's limit).
  static const int maxCount = 100000;

  final PlanStructure structure;
  final int items;

  /// One item's width and length after wet finishing.
  final Length? finishedWidth;
  final Length? finishedLength;

  /// The finished cloth each item folds into its hems, both ends together (woven).
  final Length? hems;

  /// The unwoven warp each item keeps for its fringe, both ends together.
  final Length? fringe;

  /// A length woven at the start of the warp to sample, measured on the loom.
  final Length? sampling;

  /// Round the ends worked out from the width to a multiple of this (the threading repeat).
  final int? endMultiple;

  /// Ends added after rounding (floating selvedges, an end to balance a twill).
  final int extraEnds;

  final String? swatchId;
  final String? swatchName;
  final String? warpMaterialId;
  final String? warpMaterialName;
  final String? weftMaterialId;
  final String? weftMaterialName;
  final PlanOverrides overrides;

  /// Keys this build does not read, and values of known keys it could not read.
  final Map<String, Object?> extra;

  static const Set<String> knownKeys = {
    'version',
    'structure',
    'items',
    'finishedWidth',
    'finishedLength',
    'hems',
    'fringe',
    'sampling',
    'endMultiple',
    'extraEnds',
    'swatchId',
    'swatchName',
    'warpMaterialId',
    'warpMaterialName',
    'weftMaterialId',
    'weftMaterialName',
    'overrides',
  };

  /// A copy with the fields given set. `clear` names fields to set to null (or 0 for extraEnds).
  /// A field set here replaces any value of its key kept in [extra].
  WeavePlan copyWith({
    PlanStructure? structure,
    int? items,
    Length? finishedWidth,
    Length? finishedLength,
    Length? hems,
    Length? fringe,
    Length? sampling,
    int? endMultiple,
    int? extraEnds,
    String? swatchId,
    String? swatchName,
    String? warpMaterialId,
    String? warpMaterialName,
    String? weftMaterialId,
    String? weftMaterialName,
    PlanOverrides? overrides,
    Set<String> clear = const {},
  }) {
    final set = <String>{
      if (structure != null) 'structure',
      if (items != null) 'items',
      if (finishedWidth != null) 'finishedWidth',
      if (finishedLength != null) 'finishedLength',
      if (hems != null) 'hems',
      if (fringe != null) 'fringe',
      if (sampling != null) 'sampling',
      if (endMultiple != null) 'endMultiple',
      if (extraEnds != null) 'extraEnds',
      if (swatchId != null) 'swatchId',
      if (swatchName != null) 'swatchName',
      if (warpMaterialId != null) 'warpMaterialId',
      if (warpMaterialName != null) 'warpMaterialName',
      if (weftMaterialId != null) 'weftMaterialId',
      if (weftMaterialName != null) 'weftMaterialName',
      if (overrides != null) 'overrides',
      ...clear,
    };
    T? pick<T>(String key, T? given, T? current) => clear.contains(key) ? null : (given ?? current);
    return WeavePlan(
      structure: structure ?? this.structure,
      items: items ?? this.items,
      finishedWidth: pick('finishedWidth', finishedWidth, this.finishedWidth),
      finishedLength: pick('finishedLength', finishedLength, this.finishedLength),
      hems: pick('hems', hems, this.hems),
      fringe: pick('fringe', fringe, this.fringe),
      sampling: pick('sampling', sampling, this.sampling),
      endMultiple: pick('endMultiple', endMultiple, this.endMultiple),
      extraEnds: clear.contains('extraEnds') ? 0 : (extraEnds ?? this.extraEnds),
      swatchId: pick('swatchId', swatchId, this.swatchId),
      swatchName: pick('swatchName', swatchName, this.swatchName),
      warpMaterialId: pick('warpMaterialId', warpMaterialId, this.warpMaterialId),
      warpMaterialName: pick('warpMaterialName', warpMaterialName, this.warpMaterialName),
      weftMaterialId: pick('weftMaterialId', weftMaterialId, this.weftMaterialId),
      weftMaterialName: pick('weftMaterialName', weftMaterialName, this.weftMaterialName),
      overrides: overrides ?? this.overrides,
      extra: {
        for (final e in extra.entries)
          if (!set.contains(e.key)) e.key: e.value,
      },
    );
  }

  Map<String, Object?> toJson() => {
        'version': version,
        'structure': structure.serialName,
        'items': items,
        if (finishedWidth != null) 'finishedWidth': finishedWidth!.toMap(),
        if (finishedLength != null) 'finishedLength': finishedLength!.toMap(),
        if (hems != null) 'hems': hems!.toMap(),
        if (fringe != null) 'fringe': fringe!.toMap(),
        if (sampling != null) 'sampling': sampling!.toMap(),
        if (endMultiple != null) 'endMultiple': endMultiple,
        if (extraEnds != 0) 'extraEnds': extraEnds,
        if (swatchId != null) 'swatchId': swatchId,
        if (swatchName != null) 'swatchName': swatchName,
        if (warpMaterialId != null) 'warpMaterialId': warpMaterialId,
        if (warpMaterialName != null) 'warpMaterialName': warpMaterialName,
        if (weftMaterialId != null) 'weftMaterialId': weftMaterialId,
        if (weftMaterialName != null) 'weftMaterialName': weftMaterialName,
        'overrides': overrides.toJson(),
        ...extra,
      };

  /// The plan [json] holds, or null when it is not one this build can read: not an object, a
  /// version other than [version] (a newer Ply's plan), or `overrides` that are not an object. The
  /// sidecar then keeps it as it is, and the worksheet does not replace it.
  static WeavePlan? fromJson(Object? json) {
    if (json is! Map) return null;
    if (json['version'] != version) return null;
    if (json.containsKey('overrides') && json['overrides'] is! Map) return null;
    final extra = <String, Object?>{
      for (final e in json.entries)
        if (!knownKeys.contains(e.key)) '${e.key}': e.value,
    };
    T? read<T>(String k, T? Function(Object? raw) parse) {
      if (!json.containsKey(k)) return null;
      final raw = json[k];
      final v = parse(raw);
      if (v == null && raw != null) extra[k] = raw;
      return v;
    }

    String? string(Object? raw) => raw is String ? raw : null;
    int? whole(Object? raw) => raw is int ? raw : null;
    return WeavePlan(
      structure: read('structure', PlanStructure.bySerialName) ?? PlanStructure.plain,
      items: read('items', whole) ?? 1,
      finishedWidth: read('finishedWidth', lengthFromJson),
      finishedLength: read('finishedLength', lengthFromJson),
      hems: read('hems', lengthFromJson),
      fringe: read('fringe', lengthFromJson),
      sampling: read('sampling', lengthFromJson),
      endMultiple: read('endMultiple', whole),
      extraEnds: read('extraEnds', whole) ?? 0,
      swatchId: read('swatchId', string),
      swatchName: read('swatchName', string),
      warpMaterialId: read('warpMaterialId', string),
      warpMaterialName: read('warpMaterialName', string),
      weftMaterialId: read('weftMaterialId', string),
      weftMaterialName: read('weftMaterialName', string),
      overrides: PlanOverrides.fromJson(json['overrides']),
      extra: extra,
    );
  }

  /// [sidecar] with its plan pointed at restored copies (ADR 0016 section 9): [materialCopies] and
  /// [swatchCopies] map a backup's record id to the copy's id and name. Every other key keeps its
  /// value; a sidecar without a plan, or with one this build cannot read (another version, or
  /// overrides that are not an object), is returned as it is.
  static Map<String, dynamic> relinked(Map<String, dynamic> sidecar,
      Map<String, (String, String)> materialCopies, Map<String, (String, String)> swatchCopies) {
    final raw = sidecar[key];
    if (raw is! Map || fromJson(raw) == null) return sidecar;
    final next = Map<String, dynamic>.of(raw.cast<String, dynamic>());
    void relink(String idKey, String nameKey, Map<String, (String, String)> to) {
      final copy = to[next[idKey]];
      if (copy == null) return;
      next[idKey] = copy.$1;
      next[nameKey] = copy.$2;
    }

    relink('swatchId', 'swatchName', swatchCopies);
    relink('warpMaterialId', 'warpMaterialName', materialCopies);
    relink('weftMaterialId', 'weftMaterialName', materialCopies);
    return {...sidecar, key: next};
  }

  /// The material and swatch ids the plan in [sidecar] names (none for a plan this build cannot
  /// read).
  static ({Set<String> materials, Set<String> swatches}) idsIn(Map<String, dynamic> sidecar) {
    final raw = sidecar[key];
    if (raw is! Map || fromJson(raw) == null) return (materials: <String>{}, swatches: <String>{});
    Set<String> ids(List<String> keys) => {
          for (final k in keys)
            if (raw[k] case final String id) id,
        };
    return (
      materials: ids(const ['warpMaterialId', 'weftMaterialId']),
      swatches: ids(const ['swatchId']),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WeavePlan && const DeepCollectionEquality().equals(other.toJson(), toJson());

  @override
  int get hashCode => const DeepCollectionEquality().hash(toJson());

  @override
  String toString() => 'WeavePlan(${toJson()})';
}

// --- the worksheet the engine works out ----------------------------------------------------------

/// One figure: the value with its unit ([lengthUnit] null for a count), as shown, with its working
/// and the inputs it used.
class PlanFigure {
  const PlanFigure({
    required this.key,
    required this.label,
    required this.value,
    this.lengthUnit,
    required this.text,
    this.working = const [],
    this.uses = const [],
    this.assumed = false,
  });

  final String key;
  final String label;
  final double value;
  final LengthUnit? lengthUnit;
  final String text;
  final List<String> working;
  final List<String> uses;

  /// Whether one of the inputs it used is one of Ply's starting estimates.
  final bool assumed;
}

/// How to sley the reed.
class DentingPlan {
  const DentingPlan({
    required this.reed,
    required this.order,
    required this.dents,
    required this.width,
    required this.exact,
    required this.text,
    this.working = const [],
    this.uses = const [],
  });

  final Reed reed;
  final List<int> order;
  final int dents;
  final Length width;
  final bool exact;
  final String text;
  final List<String> working;
  final List<String> uses;
}

/// A loom check of the plan. [code] is the engine's stable id (`plan.loom_width_fits`).
class PlanCheck {
  const PlanCheck({required this.code, required this.severity, required this.message});

  final String code;
  final LoomSeverity severity;
  final String message;
}

enum SupplyRole { warp, weft, warpAndWeft }

/// One yarn's need against what is on hand.
class SupplyLine {
  const SupplyLine({
    required this.role,
    required this.materialId,
    required this.materialName,
    required this.need,
    this.needMass,
    this.onHand,
    this.onHandAbout = false,
    this.remaining,
    required this.text,
    this.working = const [],
    this.uses = const [],
    this.assumed = false,
  });

  final SupplyRole role;
  final String materialId;
  final String materialName;
  final Length need;
  final Mass? needMass;
  final Length? onHand;
  final bool onHandAbout;

  /// On hand minus the need: below zero when short.
  final Length? remaining;
  final String text;
  final List<String> working;
  final List<String> uses;

  /// Whether one of the inputs it used is one of Ply's starting estimates.
  final bool assumed;

  bool get short => (remaining?.value ?? 0) < 0;
}

/// A note that explains one input ([key]), shown next to it.
class PlanInputNote {
  const PlanInputNote(this.key, this.text);

  final String key;
  final String text;
}

/// What the worksheet reads from the open draft, worked out once per draft change.
class PlanDraftFacts {
  const PlanDraftFacts({required this.ends, required this.meanStrands, this.fileSett});

  final int ends;
  final double meanStrands;
  final Sett? fileSett;

  @override
  bool operator ==(Object other) =>
      other is PlanDraftFacts &&
      other.ends == ends &&
      other.meanStrands == meanStrands &&
      other.fileSett == fileSett;

  @override
  int get hashCode => Object.hash(ends, meanStrands, fileSett);
}

/// Whether an issue is a value that cannot be used or an input not given yet.
enum PlanIssueKind { invalid, needed }

/// Why part of the worksheet could not be worked out. [code] is stable; [field] names the input.
class PlanIssue {
  const PlanIssue(
      {required this.code, required this.kind, required this.field, required this.message});

  final String code;
  final PlanIssueKind kind;
  final String field;
  final String message;
}

/// The whole worksheet.
class PlanWorksheet {
  const PlanWorksheet({
    this.metric = false,
    this.inputs = const [],
    this.figures = const [],
    this.denting,
    this.checks = const [],
    this.supply = const [],
    this.issues = const [],
    this.inputNotes = const [],
    this.notes = const [],
  });

  final bool metric;
  final List<TracedInput> inputs;
  final List<PlanFigure> figures;
  final DentingPlan? denting;
  final List<PlanCheck> checks;
  final List<SupplyLine> supply;
  final List<PlanIssue> issues;

  /// Notes that explain one input each, shown next to it.
  final List<PlanInputNote> inputNotes;

  /// Notes about the plan as a whole.
  final List<String> notes;

  TracedInput? input(String key) => inputs.firstWhereOrNull((i) => i.key == key);

  /// The notes that explain the input [key].
  List<String> notesFor(String key) => [
        for (final n in inputNotes)
          if (n.key == key) n.text,
      ];

  PlanFigure? figure(String key) => figures.firstWhereOrNull((f) => f.key == key);
}
