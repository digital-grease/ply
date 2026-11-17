// A project's links to the library's materials and swatches (roadmap M8-01, ADR 0016), kept in the
// project's sidecar (`<id>.json`, every craft) under one additive key:
//
//   "materials": {
//     "yarns":    [ { "materialId": "...", "materialName": "Grey wool", "role": "main" } ],
//     "swatches": [ { "swatchId": "...", "swatchName": "Grey wool swatch" } ]
//   }
//
// A link names its record by id and keeps the record's name as it was when linked (a snapshot), so
// a project whose material was deleted, or that was restored on another device, still says what it
// used: such a link shows as "not in your materials", it never vanishes. Unknown keys (in the object
// and in each link) are kept and written back. No link is ever needed to open a project. Pure data.

import 'package:collection/collection.dart';

import 'material_record.dart' show YarnRole;

/// A project's link to a material.
class MaterialLink {
  MaterialLink({
    required this.materialId,
    required this.materialName,
    this.role,
    Map<String, Object?> extra = const {},
  }) : extra = Map.unmodifiable(extra);

  final String materialId;

  /// The material's name when it was linked (or last seen).
  final String materialName;
  final YarnRole? role;

  /// Keys this build does not read, and a role it could not read, kept as they were.
  final Map<String, Object?> extra;

  static const Set<String> knownKeys = {'materialId', 'materialName', 'role'};

  MaterialLink copyWith({String? materialName, YarnRole? role, bool clearRole = false}) =>
      MaterialLink(
        materialId: materialId,
        materialName: materialName ?? this.materialName,
        role: clearRole ? null : (role ?? this.role),
        extra: {
          for (final e in extra.entries)
            if (!(e.key == 'role' && (role != null || clearRole))) e.key: e.value,
        },
      );

  Map<String, Object?> toJson() => {
        'materialId': materialId,
        'materialName': materialName,
        if (role != null) 'role': role!.serialName,
        ...extra,
      };

  static MaterialLink? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['materialId'];
    if (id is! String || id.isEmpty) return null;
    final name = json['materialName'];
    final rawRole = json['role'];
    final role = YarnRole.bySerialName(rawRole);
    return MaterialLink(
      materialId: id,
      materialName: name is String ? name : '',
      role: role,
      extra: {
        for (final e in json.entries)
          if (!knownKeys.contains(e.key) || (e.key == 'role' && role == null && rawRole != null))
            '${e.key}': e.value,
      },
    );
  }

  @override
  bool operator ==(Object other) =>
      other is MaterialLink &&
      other.materialId == materialId &&
      other.materialName == materialName &&
      other.role == role &&
      const DeepCollectionEquality().equals(other.extra, extra);

  @override
  int get hashCode =>
      Object.hash(materialId, materialName, role, const DeepCollectionEquality().hash(extra));
}

/// A project's link to a swatch.
class SwatchLink {
  SwatchLink({
    required this.swatchId,
    required this.swatchName,
    Map<String, Object?> extra = const {},
  }) : extra = Map.unmodifiable(extra);

  final String swatchId;
  final String swatchName;
  final Map<String, Object?> extra;

  static const Set<String> knownKeys = {'swatchId', 'swatchName'};

  SwatchLink copyWith({String? swatchName}) =>
      SwatchLink(swatchId: swatchId, swatchName: swatchName ?? this.swatchName, extra: extra);

  Map<String, Object?> toJson() => {'swatchId': swatchId, 'swatchName': swatchName, ...extra};

  static SwatchLink? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['swatchId'];
    if (id is! String || id.isEmpty) return null;
    final name = json['swatchName'];
    return SwatchLink(
      swatchId: id,
      swatchName: name is String ? name : '',
      extra: {
        for (final e in json.entries)
          if (!knownKeys.contains(e.key)) '${e.key}': e.value,
      },
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SwatchLink &&
      other.swatchId == swatchId &&
      other.swatchName == swatchName &&
      const DeepCollectionEquality().equals(other.extra, extra);

  @override
  int get hashCode => Object.hash(swatchId, swatchName, const DeepCollectionEquality().hash(extra));
}

/// Every link of one project. Unknown entries are kept: a link this build cannot read stays in
/// [unreadYarns] / [unreadSwatches], and unknown keys of the object in [extra].
class ProjectMaterials {
  ProjectMaterials({
    List<MaterialLink> yarns = const [],
    List<SwatchLink> swatches = const [],
    List<Object?> unreadYarns = const [],
    List<Object?> unreadSwatches = const [],
    Map<String, Object?> extra = const {},
  })  : yarns = List.unmodifiable(yarns),
        swatches = List.unmodifiable(swatches),
        unreadYarns = List.unmodifiable(unreadYarns),
        unreadSwatches = List.unmodifiable(unreadSwatches),
        extra = Map.unmodifiable(extra);

  /// The sidecar key.
  static const String key = 'materials';

  static final ProjectMaterials none = ProjectMaterials();

  final List<MaterialLink> yarns;
  final List<SwatchLink> swatches;
  final List<Object?> unreadYarns;
  final List<Object?> unreadSwatches;
  final Map<String, Object?> extra;

  /// No links at all (and nothing kept for another build): the key can be removed.
  bool get isEmpty =>
      yarns.isEmpty &&
      swatches.isEmpty &&
      unreadYarns.isEmpty &&
      unreadSwatches.isEmpty &&
      extra.isEmpty;

  bool linksMaterial(String id) => yarns.any((y) => y.materialId == id);
  bool linksSwatch(String id) => swatches.any((s) => s.swatchId == id);

  ProjectMaterials copyWith({List<MaterialLink>? yarns, List<SwatchLink>? swatches}) =>
      ProjectMaterials(
        yarns: yarns ?? this.yarns,
        swatches: swatches ?? this.swatches,
        unreadYarns: unreadYarns,
        unreadSwatches: unreadSwatches,
        extra: extra,
      );

  Map<String, Object?> toJson() => {
        'yarns': [for (final y in yarns) y.toJson(), ...unreadYarns],
        'swatches': [for (final s in swatches) s.toJson(), ...unreadSwatches],
        ...extra,
      };

  /// Null when [json] is not an object (the caller keeps the raw value).
  static ProjectMaterials? fromJson(Object? json) {
    if (json is! Map) return null;
    final yarns = <MaterialLink>[];
    final unreadYarns = <Object?>[];
    final rawYarns = json['yarns'];
    if (rawYarns is List) {
      for (final y in rawYarns) {
        final link = MaterialLink.fromJson(y);
        link == null ? unreadYarns.add(y) : yarns.add(link);
      }
    }
    final swatches = <SwatchLink>[];
    final unreadSwatches = <Object?>[];
    final rawSwatches = json['swatches'];
    if (rawSwatches is List) {
      for (final s in rawSwatches) {
        final link = SwatchLink.fromJson(s);
        link == null ? unreadSwatches.add(s) : swatches.add(link);
      }
    }
    return ProjectMaterials(
      yarns: yarns,
      swatches: swatches,
      unreadYarns: unreadYarns,
      unreadSwatches: unreadSwatches,
      extra: {
        for (final e in json.entries)
          // A `yarns` or `swatches` value that is not a list is kept as it was.
          if ((e.key != 'yarns' && e.key != 'swatches') ||
              (e.key == 'yarns' && rawYarns is! List && rawYarns != null) ||
              (e.key == 'swatches' && rawSwatches is! List && rawSwatches != null))
            '${e.key}': e.value,
      },
    );
  }

  /// [json] (a sidecar) with its links pointed at restored copies: [materialCopies] and
  /// [swatchCopies] map a backup's record id to the copy's id and name. Every other key, in the
  /// links too, keeps its value and its place.
  static Map<String, dynamic> relinked(Map<String, dynamic> json,
      Map<String, (String, String)> materialCopies, Map<String, (String, String)> swatchCopies) {
    final raw = json[key];
    if (raw is! Map) return json;
    Object? relink(Object? link, String idKey, String nameKey, Map<String, (String, String)> to) {
      if (link is! Map) return link;
      final copy = to[link[idKey]];
      if (copy == null) return link;
      return {...link, idKey: copy.$1, nameKey: copy.$2};
    }

    final next = Map<String, dynamic>.of(raw.cast<String, dynamic>());
    final yarns = next['yarns'];
    if (yarns is List) {
      next['yarns'] = [
        for (final y in yarns) relink(y, 'materialId', 'materialName', materialCopies)
      ];
    }
    final swatches = next['swatches'];
    if (swatches is List) {
      next['swatches'] = [
        for (final s in swatches) relink(s, 'swatchId', 'swatchName', swatchCopies)
      ];
    }
    return {...json, key: next};
  }

  /// The material and swatch ids [json] (a sidecar) links to.
  static ({Set<String> materials, Set<String> swatches}) idsIn(Map<String, dynamic> json) {
    final links = fromJson(json[key]);
    if (links == null) return (materials: <String>{}, swatches: <String>{});
    return (
      materials: {for (final y in links.yarns) y.materialId},
      swatches: {for (final s in links.swatches) s.swatchId},
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ProjectMaterials && const DeepCollectionEquality().equals(other.toJson(), toJson());

  @override
  int get hashCode => const DeepCollectionEquality().hash(toJson());
}
