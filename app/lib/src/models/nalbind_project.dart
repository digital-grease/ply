// A saved nalbinding PROJECT — the first write path for the craft (M6 v1 was reference-only).
//
// Nalbinding has no chart/drawdown to lay out (the loop graph is per-stitch, not per-garment), so the
// way the craft is actually shared is PROSE: a chosen stitch plus free-text working notes (cast-on
// count, increases, fit, yarn). This is the smallest useful slice of the deferred nalbind project
// model in docs/NALBIND_DESIGN.md. Pure data; no FFI symbols imported. Persisted as `<id>.plynal`
// JSON beside a craft-agnostic `<id>.json` DraftMeta sidecar (craft = 'Nalbinding'), mirroring the
// knit `<id>.{plyknit,json}` pair.
//
// FORMAT VERSIONING. A `.plynal` file is one JSON object with the document fields at the TOP level
// plus `format` ("ply.nalbind") and `schemaVersion` keys. Not an envelope on purpose: released readers
// (v0.1.0 to v0.1.7) read each field tolerantly, defaulting a missing one to empty, so they would load
// an enveloped file as an EMPTY project that a later save would write over the real one. With inline
// keys they load a current file correctly instead. A file without a `format` key is legacy version 1
// (what those releases wrote); version 2 only adds the two keys, so the v1 -> v2 migration is the
// identity on the fields. Version 3 (M8-04, ADR 0017) adds an optional `recipe` object (a structured
// recipe of ordered segments; see NalbindRecipe), written only when the project has one, so the
// v2 -> v3 migration is the identity too and a note-only project keeps exactly its fields. A file
// whose version is newer than [NalbindProject.currentSchemaVersion] is refused (never loaded with
// fields dropped, never overwritten); so is a version 3 recipe this build cannot read (an unknown
// segment kind, say). `format` and `schemaVersion` are reserved: no document field may use those
// names.
//
// DECODING. The project screen opens, the save guard checks and a follow-view tick rereads a file
// by decoding it on a background isolate ([decodePlynalInBackground], [checkPlynalInBackground]), so
// a large file never holds up the UI.

import 'dart:convert';
import 'dart:isolate';

import 'nalbind_recipe.dart';
import 'native_format.dart';

/// One saved nalbinding project: a name, the chosen stitch (its Hansen [notation] + display
/// [stitchName]), free-text [notes], and optionally a structured [recipe].
class NalbindProject {
  const NalbindProject({
    this.name = '',
    this.notation = '',
    this.stitchName = '',
    this.notes = '',
    this.recipe,
  });

  /// Display name of the project (the on-disk filename is an opaque uuid, never this).
  final String name;

  /// The chosen stitch's Hansen-notation string (e.g. `UO/UOO F1`), or empty for "no stitch picked".
  final String notation;

  /// A human display name for the stitch (e.g. `Oslo`), or empty when only a raw notation was typed.
  final String stitchName;

  /// Free-form working notes — the heart of the feature.
  final String notes;

  /// The structured recipe, or null for a note-only project (every project before version 3).
  final NalbindRecipe? recipe;

  NalbindProject copyWith({String? name, String? notation, String? stitchName, String? notes}) =>
      NalbindProject(
        name: name ?? this.name,
        notation: notation ?? this.notation,
        stitchName: stitchName ?? this.stitchName,
        notes: notes ?? this.notes,
        recipe: recipe,
      );

  /// This project with [recipe] (null removes it, making the project note-only again).
  NalbindProject withRecipe(NalbindRecipe? recipe) => NalbindProject(
        name: name,
        notation: notation,
        stitchName: stitchName,
        notes: notes,
        recipe: recipe,
      );

  /// The `format` value of every `.plynal` file.
  static const String formatId = 'ply.nalbind';

  /// The `.plynal` schema version this build writes, and the newest it can read.
  static const int currentSchemaVersion = 3;

  /// The current on-disk form: the version keys, then the document fields (see the file header).
  Map<String, dynamic> toJson() => {
        'format': formatId,
        'schemaVersion': currentSchemaVersion,
        'name': name,
        'notation': notation,
        'stitchName': stitchName,
        'notes': notes,
        if (recipe != null) 'recipe': recipe!.toJson(),
      };

  /// The schema version of a decoded `.plynal` object, by the deterministic rule: no `format` key is
  /// legacy version 1; otherwise `format` must be [formatId] and `schemaVersion` a positive integer.
  /// Throws a [NativeFormatException] for a foreign format, a bad version, or a version newer than
  /// [currentSchemaVersion].
  static int schemaVersionOf(Map<String, dynamic> json) {
    if (!json.containsKey('format')) return 1;
    if (json['format'] != formatId) {
      throw NativeFormatException(NativeFormatProblem.wrongFormat,
          document: NativeDocument.nalbindProject, detail: 'format ${json['format']}');
    }
    final version = json['schemaVersion'];
    if (version is! int || version < 1) {
      throw NativeFormatException(NativeFormatProblem.unreadable,
          document: NativeDocument.nalbindProject, detail: 'schemaVersion $version');
    }
    if (version > currentSchemaVersion) {
      throw NativeFormatException(NativeFormatProblem.newerVersion,
          document: NativeDocument.nalbindProject,
          detail: 'schemaVersion $version, this build reads up to $currentSchemaVersion');
    }
    return version;
  }

  /// Decode a `.plynal` object of any supported version. Reads the fields tolerantly (a missing one
  /// becomes empty) so a partially-written or older file still loads. Version 1 to 2 and 2 to 3
  /// need no field change: a version 1 or 2 file has no recipe (a stray `recipe` key in one, which
  /// no writer produced, is ignored). A version 3 `recipe` is read strictly (see NalbindRecipe):
  /// anything it cannot read throws a [FormatException], which [decode] reports as unreadable.
  /// Throws a [NativeFormatException] per [schemaVersionOf].
  factory NalbindProject.fromJson(Map<String, dynamic> json) {
    final version =
        schemaVersionOf(json); // refuses a foreign / newer file before any field is read
    final recipe = json['recipe'];
    return NalbindProject(
      name: (json['name'] as String?) ?? '',
      notation: (json['notation'] as String?) ?? '',
      stitchName: (json['stitchName'] as String?) ?? '',
      notes: (json['notes'] as String?) ?? '',
      recipe: version >= 3 && recipe != null ? NalbindRecipe.fromJson(recipe) : null,
    );
  }

  /// Decode `.plynal` file text. Anything that is not a JSON object of the expected shape is a
  /// [NativeFormatException] ([NativeFormatProblem.unreadable] unless it is newer or foreign).
  static NalbindProject decode(String text) {
    try {
      final json = jsonDecode(text);
      if (json is! Map<String, dynamic>) {
        throw const NativeFormatException(NativeFormatProblem.unreadable,
            document: NativeDocument.nalbindProject, detail: 'not a JSON object');
      }
      return NalbindProject.fromJson(json);
    } on NativeFormatException {
      rethrow;
    } catch (e) {
      // Bad JSON (FormatException) or a field of the wrong type (TypeError).
      throw NativeFormatException(NativeFormatProblem.unreadable,
          document: NativeDocument.nalbindProject, detail: '$e');
    }
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NalbindProject &&
          runtimeType == other.runtimeType &&
          name == other.name &&
          notation == other.notation &&
          stitchName == other.stitchName &&
          notes == other.notes &&
          recipe == other.recipe;

  @override
  int get hashCode => Object.hash(name, notation, stitchName, notes, recipe);
}

/// [NalbindProject.decode] on a background isolate, so a large file never holds up the UI. Throws
/// the same [NativeFormatException].
Future<NalbindProject> decodePlynalInBackground(String text) async {
  final (project, problem, detail) =
      await Isolate.run(() => _decodeOrProblem(text), debugName: 'plynal decode');
  if (problem != null) {
    throw NativeFormatException(problem, document: NativeDocument.nalbindProject, detail: detail);
  }
  return project!;
}

/// Read a `.plynal` text the way the project screen opens it ([NalbindProject.decode]), on a
/// background isolate, keeping only the verdict. Throws a [NativeFormatException] when it cannot be
/// opened: newer, another format, unreadable.
Future<void> checkPlynalInBackground(String text) async {
  final (_, problem, detail) =
      await Isolate.run(() => _decodeOrProblem(text, keep: false), debugName: 'plynal check');
  if (problem != null) {
    throw NativeFormatException(problem, document: NativeDocument.nalbindProject, detail: detail);
  }
}

/// Runs on the background isolate: the project (when [keep]) or why it does not open. Only this
/// record comes back.
(NalbindProject?, NativeFormatProblem?, String?) _decodeOrProblem(String text, {bool keep = true}) {
  try {
    final project = NalbindProject.decode(text);
    return (keep ? project : null, null, null);
  } on NativeFormatException catch (e) {
    return (null, e.problem, e.detail);
  } catch (e) {
    return (null, NativeFormatProblem.unreadable, '$e');
  }
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
