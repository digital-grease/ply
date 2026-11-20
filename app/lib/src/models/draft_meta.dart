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
//
// FORWARD COMPATIBILITY. The sidecar is REWRITTEN on every open (the lastOpened bump), rename, and
// save, so a build must never drop what it does not understand: every key this build does not know,
// and any known key whose value it cannot interpret (say a loom type added later), is kept in
// [DraftMeta.extra] and written back verbatim. Sidecar changes are therefore ADDITIVE ONLY: a new
// build may add keys, but an existing key never changes meaning or type (use a new key instead), and
// `schemaVersion` stays 1 while that holds. See the format ADR.

import 'package:collection/collection.dart';

import 'loom_check.dart';
import 'loom_type.dart';
import 'weave_plan.dart';

/// Metadata describing one saved draft, serialized to `<id>.json`.
class DraftMeta {
  DraftMeta({
    required this.name,
    this.craft = 'Weaving',
    this.author,
    this.notes = '',
    this.loomType = LoomType.jack,
    this.overshotTreadling = false,
    this.loomPlan,
    this.weavePlan,
    required DateTime savedAt,
    required DateTime lastOpened,
    this.schemaVersion = currentSchemaVersion,
    Map<String, Object?> extra = const {},
  })  : extra = Map.unmodifiable(extra),
        // Normalize to UTC at the boundary so the sidecar is timezone-stable: a
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

  /// The most characters a user can enter as [notes] (the weaving save dialog checks it). Even as
  /// JSON escapes (6 bytes a character at most) they stay far under the 1 MB a backup takes for a
  /// sidecar. Notes already longer (written before the limit) are kept as they are: a sidecar is
  /// never cut short on open or save.
  static const int maxNotesChars = 10000;

  /// The most characters a user can enter as a project's [name] (the weaving save dialog and every
  /// dialog that names or renames a weaving draft or a knitting pattern check it), and as [author]
  /// ([maxAuthorChars]). Counted as saved, without spaces at either end. Names and authors already
  /// longer (written before the limit) are kept as they are: they list, open and back up as before,
  /// and renaming one asks for a shorter name.
  static const int maxNameChars = 200;

  /// The most characters a user can enter as [author] (see [maxNameChars]).
  static const int maxAuthorChars = 200;

  /// The loom this draft is built for (shed + drive preset). App-only; serde tolerates it as an
  /// unknown field. Defaults to [LoomType.jack] when absent (older sidecar).
  final LoomType loomType;

  /// Whether this draft pins a "Book view" button to the editor's tools. App-only; serde tolerates it
  /// as an unknown field. Defaults to false (an older sidecar, or any non-overshot draft).
  ///
  /// The key predates the separate Book view: it once switched the editor to an inline collapsed
  /// "overshot treadling" layout. That layout is gone (the editor grid is always one row per pick),
  /// so an older sidecar that set it now just pins the button. The key name is kept so those
  /// sidecars load unchanged and keep the value across a save.
  final bool overshotTreadling;

  /// The loom this draft is planned for (ADR 0014): the loom's id and name and the weaver's sett for
  /// the loom check, or null when none was chosen. App-only (never in the WIF); stored under
  /// `loomPlan`, written only when set, and a value this build cannot read is kept in [extra].
  final LoomPlan? loomPlan;

  /// The draft's warp, weft and finishing plan (ADR 0019), or null when it has none. App-only (never
  /// in the WIF); stored under `weavePlan`, written only when set, and a plan this build cannot read
  /// (a newer version) is kept in [extra] as it is.
  final WeavePlan? weavePlan;

  /// Whether the sidecar holds a plan this build cannot read (kept in [extra]): the worksheet then
  /// refuses to replace it.
  bool get hasUnreadablePlan => extra.containsKey(WeavePlan.key);

  /// When the draft was first saved.
  final DateTime savedAt;

  /// When the draft was last opened — drives the Library sort order. Dart-only.
  final DateTime lastOpened;

  /// Sidecar schema version, for tolerant forward migration.
  final int schemaVersion;

  /// The sidecar schema version this build writes. It stays 1 while sidecar changes are additive (see
  /// the file header); a sidecar with a higher version was written by a build that broke that rule,
  /// and a backup restore refuses it.
  static const int currentSchemaVersion = 1;

  /// Sidecar entries this build does not interpret, written back verbatim by [toJson] so a rewrite
  /// (open, rename, save) never erases what another build stored: every unknown key, plus any known
  /// key whose stored value this build could not read. Setting that field through [copyWith] drops
  /// the preserved value in favour of the new one. Unmodifiable.
  final Map<String, Object?> extra;

  /// The keys this build reads into fields. Everything else in a sidecar goes to [extra].
  static const Set<String> knownKeys = {
    'name',
    'craft',
    'author',
    'notes',
    'loomType',
    'overshotTreadling',
    'loomPlan',
    WeavePlan.key,
    'savedAt',
    'lastOpened',
    'schemaVersion',
  };

  DraftMeta copyWith({
    String? name,
    String? craft,
    String? author,
    String? notes,
    LoomType? loomType,
    bool? overshotTreadling,
    LoomPlan? loomPlan,
    bool clearLoomPlan = false,
    WeavePlan? weavePlan,
    bool clearWeavePlan = false,
    DateTime? savedAt,
    DateTime? lastOpened,
    int? schemaVersion,
  }) {
    // A field set here replaces any value preserved for its key.
    final kept = Map<String, Object?>.of(extra)
      ..removeWhere((key, _) => switch (key) {
            'name' => name != null,
            'craft' => craft != null,
            'author' => author != null,
            'notes' => notes != null,
            'loomType' => loomType != null,
            'overshotTreadling' => overshotTreadling != null,
            'loomPlan' => loomPlan != null || clearLoomPlan,
            WeavePlan.key => weavePlan != null || clearWeavePlan,
            'savedAt' => savedAt != null,
            'lastOpened' => lastOpened != null,
            'schemaVersion' => schemaVersion != null,
            _ => false,
          });
    return DraftMeta(
      name: name ?? this.name,
      craft: craft ?? this.craft,
      author: author ?? this.author,
      notes: notes ?? this.notes,
      loomType: loomType ?? this.loomType,
      overshotTreadling: overshotTreadling ?? this.overshotTreadling,
      loomPlan: clearLoomPlan ? null : (loomPlan ?? this.loomPlan),
      weavePlan: clearWeavePlan ? null : (weavePlan ?? this.weavePlan),
      savedAt: savedAt ?? this.savedAt,
      lastOpened: lastOpened ?? this.lastOpened,
      schemaVersion: schemaVersion ?? this.schemaVersion,
      extra: kept,
    );
  }

  /// Serialize to a JSON-encodable map. Dates are ISO-8601. `author` is omitted
  /// when null (matches serde's `Option` -> absent-key convention). The [extra] entries are written
  /// last and win, so a value this build could not interpret goes back exactly as it was read.
  Map<String, dynamic> toJson() => {
        'name': name,
        'craft': craft,
        if (author != null) 'author': author,
        'notes': notes,
        'loomType': loomType.serialName,
        'overshotTreadling': overshotTreadling,
        if (loomPlan != null) 'loomPlan': loomPlan!.toJson(),
        if (weavePlan != null) WeavePlan.key: weavePlan!.toJson(),
        'savedAt': savedAt.toIso8601String(),
        'lastOpened': lastOpened.toIso8601String(),
        'schemaVersion': schemaVersion,
        ...extra,
      };

  /// Parse a sidecar map. Tolerant of missing or malformed values so a partially-written, older, or
  /// newer sidecar still loads rather than crashing the Library: a value of the wrong type falls back
  /// to its default, and is kept in [extra] (with every unknown key) so a rewrite preserves it.
  factory DraftMeta.fromJson(Map<String, dynamic> json) {
    final extra = <String, Object?>{
      for (final e in json.entries)
        if (!knownKeys.contains(e.key)) e.key: e.value,
    };
    // Read a known key; keep its raw value in `extra` when present but not readable here.
    T? read<T>(String key, T? Function(Object? raw) parse) {
      if (!json.containsKey(key)) return null;
      final raw = json[key];
      final value = parse(raw);
      if (value == null && raw != null) extra[key] = raw;
      return value;
    }

    String? string(Object? raw) => raw is String ? raw : null;
    DateTime? date(Object? raw) => raw is String ? DateTime.tryParse(raw) : null;

    final savedAt = read('savedAt', date) ?? _epoch;
    return DraftMeta(
      name: read('name', string) ?? 'Untitled',
      craft: read('craft', string) ?? 'Weaving',
      author: read('author', string),
      notes: read('notes', string) ?? '',
      loomType: read('loomType', (raw) => raw is String ? loomTypeFromSerialOrNull(raw) : null) ??
          LoomType.jack,
      overshotTreadling: read('overshotTreadling', (raw) => raw is bool ? raw : null) ?? false,
      loomPlan: read('loomPlan', LoomPlan.fromJson),
      weavePlan: read(WeavePlan.key, WeavePlan.fromJson),
      savedAt: savedAt,
      // Fall back to savedAt so sort order is still sensible if lastOpened is absent.
      lastOpened: read('lastOpened', date) ?? savedAt,
      // A number too large for a double (1e400) decodes as infinity, which has no integer: kept
      // as it is, like any value this build cannot read, rather than failing the whole sidecar.
      schemaVersion:
          read('schemaVersion', (raw) => raw is num && raw.isFinite ? raw.toInt() : null) ?? 1,
      extra: extra,
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
          overshotTreadling == other.overshotTreadling &&
          loomPlan == other.loomPlan &&
          weavePlan == other.weavePlan &&
          savedAt == other.savedAt &&
          lastOpened == other.lastOpened &&
          schemaVersion == other.schemaVersion &&
          const DeepCollectionEquality().equals(extra, other.extra);

  @override
  int get hashCode => Object.hash(
        name,
        craft,
        author,
        notes,
        loomType,
        overshotTreadling,
        loomPlan,
        weavePlan,
        savedAt,
        lastOpened,
        schemaVersion,
        const DeepCollectionEquality().hash(extra),
      );

  @override
  String toString() =>
      'DraftMeta(name: $name, craft: $craft, author: $author, savedAt: $savedAt)';
}

/// The date a sidecar without a readable `savedAt` sorts at.
final DateTime _epoch = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

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

  /// Absolute path to the `<id>.png` thumbnail, or null if there is none (the Library then shows
  /// a placeholder; a save or a library restore writes it).
  final String? thumbPath;
}
