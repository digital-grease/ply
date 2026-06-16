// App-side metadata for a saved draft.
//
// This is the JSON sidecar that lives next to each `<id>.wif` on device. It is owned
// entirely in Dart — `ProjectMeta` is NOT marshalled across the FFI boundary (see
// docs/FFI_BOUNDARY.md). The first four fields (`name`, `craft`, `author`, `notes`)
// deliberately mirror `ply_common::ProjectMeta` so a future Rust/CLI tool can
// `serde_json` this sidecar directly. The rest (`savedAt`, `lastOpened`,
// `schemaVersion`) are app-only; serde tolerates them as unknown fields.
//
// `craft` is stored as serde's representation of `CraftKind` — i.e. "Weaving"
// (capitalized) — NOT a lowercase free string, precisely so that cross-tool
// round-trip with the Rust enum actually works. `lastOpened` is Dart-only
// book-keeping (Library sort order); nothing on the Rust side reads it.
//
// No generated bridge symbols are imported here on purpose: this file is pure data.

import 'loom_type.dart';

/// Metadata describing one saved draft, serialized to `<id>.json`.
class DraftMeta {
  DraftMeta({
    required this.name,
    this.craft = 'Weaving',
    this.author,
    this.notes = '',
    this.loomType = LoomType.jack,
    required DateTime savedAt,
    required DateTime lastOpened,
    this.schemaVersion = 1,
  })  : // Normalize to UTC at the boundary so the sidecar is timezone-stable: a
        // local DateTime serializes with NO offset, which would resolve to a
        // different instant if the device tz changes (travel/DST/restore) and
        // silently reorder the lastOpened-sorted Library. UTC also serializes with
        // a 'Z' suffix, which a cross-tool reader can parse unambiguously.
        savedAt = savedAt.toUtc(),
        lastOpened = lastOpened.toUtc();

  /// Display name (the filename is the opaque uuid, never this).
  final String name;

  /// Serde representation of `ply_common::CraftKind` (e.g. "Weaving").
  final String craft;

  /// Optional author/designer credit.
  final String? author;

  /// Free-form notes; empty string when absent (mirrors the Rust `String`, not `Option`).
  final String notes;

  /// The loom this draft is built for (shed + drive preset). App-only; serde tolerates it as an
  /// unknown field. Defaults to [LoomType.jack] when absent (older sidecar).
  final LoomType loomType;

  /// When the draft was first saved.
  final DateTime savedAt;

  /// When the draft was last opened — drives the Library sort order. Dart-only.
  final DateTime lastOpened;

  /// Sidecar schema version, for tolerant forward migration.
  final int schemaVersion;

  DraftMeta copyWith({
    String? name,
    String? craft,
    String? author,
    String? notes,
    LoomType? loomType,
    DateTime? savedAt,
    DateTime? lastOpened,
    int? schemaVersion,
  }) {
    return DraftMeta(
      name: name ?? this.name,
      craft: craft ?? this.craft,
      author: author ?? this.author,
      notes: notes ?? this.notes,
      loomType: loomType ?? this.loomType,
      savedAt: savedAt ?? this.savedAt,
      lastOpened: lastOpened ?? this.lastOpened,
      schemaVersion: schemaVersion ?? this.schemaVersion,
    );
  }

  /// Serialize to a JSON-encodable map. Dates are ISO-8601. `author` is omitted
  /// when null (matches serde's `Option` -> absent-key convention).
  Map<String, dynamic> toJson() => {
        'name': name,
        'craft': craft,
        if (author != null) 'author': author,
        'notes': notes,
        'loomType': loomType.serialName,
        'savedAt': savedAt.toIso8601String(),
        'lastOpened': lastOpened.toIso8601String(),
        'schemaVersion': schemaVersion,
      };

  /// Parse a sidecar map. Tolerant of missing optionals and malformed dates so a
  /// partially-written or older sidecar still loads rather than crashing the Library.
  factory DraftMeta.fromJson(Map<String, dynamic> json) {
    final savedAt = _parseDate(json['savedAt']);
    return DraftMeta(
      name: (json['name'] as String?) ?? 'Untitled',
      craft: (json['craft'] as String?) ?? 'Weaving',
      author: json['author'] as String?,
      notes: (json['notes'] as String?) ?? '',
      loomType: loomTypeFromSerial(json['loomType'] as String?),
      savedAt: savedAt,
      // Fall back to savedAt so sort order is still sensible if lastOpened is absent.
      lastOpened: _parseDate(json['lastOpened'], fallback: savedAt),
      schemaVersion: (json['schemaVersion'] as num?)?.toInt() ?? 1,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DraftMeta &&
          runtimeType == other.runtimeType &&
          name == other.name &&
          craft == other.craft &&
          author == other.author &&
          notes == other.notes &&
          loomType == other.loomType &&
          savedAt == other.savedAt &&
          lastOpened == other.lastOpened &&
          schemaVersion == other.schemaVersion;

  @override
  int get hashCode => Object.hash(
        name,
        craft,
        author,
        notes,
        loomType,
        savedAt,
        lastOpened,
        schemaVersion,
      );

  @override
  String toString() =>
      'DraftMeta(name: $name, craft: $craft, author: $author, savedAt: $savedAt)';
}

/// Parse an ISO-8601 string, falling back gracefully. Returns [fallback] (or the
/// epoch) for null/non-string/unparseable input so a corrupt sidecar still loads.
DateTime _parseDate(Object? value, {DateTime? fallback}) {
  if (value is String) {
    final parsed = DateTime.tryParse(value);
    if (parsed != null) return parsed;
  }
  return fallback ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
}

/// An in-memory pairing of a sidecar with its on-disk files. Built by
/// `DraftRepository.list()`; not itself serialized.
class DraftEntry {
  const DraftEntry({
    required this.id,
    required this.meta,
    required this.wifPath,
    this.thumbPath,
  });

  /// The uuid stem shared by `<id>.wif`, `<id>.json`, and `<id>.png`.
  final String id;

  /// The decoded sidecar metadata.
  final DraftMeta meta;

  /// Absolute path to the `<id>.wif` source text (always present — `list()`
  /// skips entries whose `.wif` is missing).
  final String wifPath;

  /// Absolute path to the `<id>.png` thumbnail, or null if it hasn't been
  /// generated yet (rendered lazily by the Library in that case).
  final String? thumbPath;
}
