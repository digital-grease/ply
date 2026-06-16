// A saved nalbinding PROJECT — the first write path for the craft (M6 v1 was reference-only).
//
// Nalbinding has no chart/drawdown to lay out (the loop graph is per-stitch, not per-garment), so the
// way the craft is actually shared is PROSE: a chosen stitch plus free-text working notes (cast-on
// count, increases, fit, yarn). This is the smallest useful slice of the deferred nalbind project
// model in docs/NALBIND_DESIGN.md. Pure data; no FFI symbols imported. Persisted as `<id>.plynal`
// JSON beside a craft-agnostic `<id>.json` DraftMeta sidecar (craft = 'Nalbinding'), mirroring the
// knit `<id>.{plyknit,json}` pair.

/// One saved nalbinding project: a name, the chosen stitch (its Hansen [notation] + display
/// [stitchName]), and free-text [notes].
class NalbindProject {
  const NalbindProject({
    this.name = '',
    this.notation = '',
    this.stitchName = '',
    this.notes = '',
  });

  /// Display name of the project (the on-disk filename is an opaque uuid, never this).
  final String name;

  /// The chosen stitch's Hansen-notation string (e.g. `UO/UOO F1`), or empty for "no stitch picked".
  final String notation;

  /// A human display name for the stitch (e.g. `Oslo`), or empty when only a raw notation was typed.
  final String stitchName;

  /// Free-form working notes — the heart of the feature.
  final String notes;

  NalbindProject copyWith({String? name, String? notation, String? stitchName, String? notes}) =>
      NalbindProject(
        name: name ?? this.name,
        notation: notation ?? this.notation,
        stitchName: stitchName ?? this.stitchName,
        notes: notes ?? this.notes,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'notation': notation,
        'stitchName': stitchName,
        'notes': notes,
      };

  /// Tolerant parse so a partially-written or older file still loads rather than crashing the list.
  factory NalbindProject.fromJson(Map<String, dynamic> json) => NalbindProject(
        name: (json['name'] as String?) ?? '',
        notation: (json['notation'] as String?) ?? '',
        stitchName: (json['stitchName'] as String?) ?? '',
        notes: (json['notes'] as String?) ?? '',
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NalbindProject &&
          runtimeType == other.runtimeType &&
          name == other.name &&
          notation == other.notation &&
          stitchName == other.stitchName &&
          notes == other.notes;

  @override
  int get hashCode => Object.hash(name, notation, stitchName, notes);
}

/// An in-memory pairing of a saved project's sidecar metadata with its on-disk path — the nalbind
/// analog of [KnitEntry]. Reuses the craft-agnostic DraftMeta (`meta.craft == 'Nalbinding'`).
class NalbindProjectEntry {
  const NalbindProjectEntry({required this.id, required this.name, required this.lastOpened});

  /// The uuid stem shared by `<id>.plynal` and `<id>.json`.
  final String id;

  /// Display name (from the sidecar).
  final String name;

  /// Last-opened time, for the list sort order.
  final DateTime lastOpened;
}
