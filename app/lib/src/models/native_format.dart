// Version negotiation for Ply's own document formats (`.plyknit`, `.plynal`, `.plytab`). Pure data: no
// FFI and no file I/O. The engine (`ply-knit`, `native.rs`) owns the `.plyknit` reader and its
// migrations; the app owns the `.plynal` reader (see `NalbindProject`). This file holds what the
// crafts share: the user-facing error for a file this build must not open or overwrite, and small
// Dart version probes for host tests. The app itself reads the version of a file from disk or a
// backup through the engine, from the file's version keys alone (`KnitRepository.documentVersion`,
// `NalbindRepository.documentVersion`, `TabletRepository.documentVersion`), never by decoding it.

import 'dart:convert';

/// The `format` value of a `.plyknit` envelope (mirrors `ply_knit::KNIT_FORMAT`).
const String kPlyknitFormat = 'ply.knit';

/// Which kind of Ply document a [NativeFormatException] is about (drives its wording).
enum NativeDocument {
  knitPattern('pattern', 'knitting pattern'),
  nalbindProject('project', 'nalbinding project'),
  tabletBand('band', 'tablet weaving band');

  const NativeDocument(this.noun, this.fullName);

  /// The short noun used in messages ("pattern", "project").
  final String noun;

  /// The full name used in messages ("knitting pattern").
  final String fullName;
}

/// What stopped Ply from opening, or from overwriting, a document file.
enum NativeFormatProblem {
  /// Saved by a newer version of Ply. This build must neither load nor overwrite it.
  newerVersion,

  /// A Ply file of another kind (for example a nalbinding project where a pattern was expected).
  wrongFormat,

  /// Not readable as this format at all (bad JSON, a malformed envelope, a missing field).
  unreadable,
}

/// A document this build must not open, or (when [whileSaving]) must not replace. The file itself is
/// never modified. [message] is the user-facing sentence; [detail] is diagnostic only.
class NativeFormatException implements Exception {
  const NativeFormatException(
    this.problem, {
    required this.document,
    this.whileSaving = false,
    this.detail,
  });

  final NativeFormatProblem problem;
  final NativeDocument document;

  /// True when a SAVE was refused because the file already on disk is newer or unreadable.
  final bool whileSaving;

  /// The underlying parser or engine message, for logs. Never shown as the main message.
  final String? detail;

  /// One user-facing sentence explaining the problem and what to do.
  String get message {
    final n = document.noun;
    if (whileSaving) {
      return problem == NativeFormatProblem.newerVersion
          ? 'The saved copy of this $n is from a newer version of Ply, so it was not replaced.'
          : 'The saved copy of this $n could not be read, so it was not replaced.';
    }
    return switch (problem) {
      NativeFormatProblem.newerVersion =>
        'This $n was saved by a newer version of Ply. Update the app to open it.',
      NativeFormatProblem.wrongFormat => 'This file is not a Ply ${document.fullName}.',
      NativeFormatProblem.unreadable => 'This $n file could not be read.',
    };
  }

  @override
  String toString() => message;
}

/// The longest text [plyknitSchemaVersion] decodes.
const int kPlyknitProbeMaxBytes = 1024 * 1024;

/// The schema version of a SMALL `.plyknit` text, by the same deterministic rule the engine applies
/// (`ply_knit::native`): a JSON object WITHOUT a `format` key is legacy version 1; an object whose
/// `format` is `ply.knit` carries its version in `schema_version` (a positive integer). Returns null
/// for anything else (not JSON, not an object, a foreign format, a bad version).
///
/// It DECODES THE WHOLE TEXT, so it reads at most [kPlyknitProbeMaxBytes] and is null past that. The
/// app never uses it on a file from disk or a backup: those go through the engine's envelope-only
/// reader (`KnitRepository.documentVersion`), which builds nothing in proportion to the file. Host
/// tests, which have no engine, use it on small fixtures.
int? plyknitSchemaVersion(String text) {
  if (text.length > kPlyknitProbeMaxBytes) return null;
  final Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException {
    return null;
  }
  if (decoded is! Map<String, dynamic>) return null;
  if (!decoded.containsKey('format')) return 1;
  if (decoded['format'] != kPlyknitFormat) return null;
  final version = decoded['schema_version'];
  return version is int && version >= 1 ? version : null;
}

/// The `format` value of a `.plytab` envelope (mirrors `ply_tablet::TABLET_FORMAT`).
const String kPlytabFormat = 'ply.tablet';

/// The longest text [plytabSchemaVersion] decodes.
const int kPlytabProbeMaxBytes = 1024 * 1024;

/// The `.plytab` schema version of a SMALL text, by the engine's rule (`ply_tablet::document`): a
/// JSON object whose `format` is `ply.tablet` carries its version in `schema_version` (a positive
/// integer); there is no legacy, unversioned form. Null for anything else.
///
/// It DECODES THE WHOLE TEXT, so it reads at most [kPlytabProbeMaxBytes] and is null past that. The
/// app never uses it on a file from disk or a backup: those go through the engine's envelope-only
/// reader (`TabletRepository.documentVersion`), which builds nothing in proportion to the file.
/// Host tests, which have no engine, use it on small fixtures.
int? plytabSchemaVersion(String text) {
  if (text.length > kPlytabProbeMaxBytes) return null;
  final Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException {
    return null;
  }
  if (decoded is! Map<String, dynamic>) return null;
  if (decoded['format'] != kPlytabFormat) return null;
  final version = decoded['schema_version'];
  return version is int && version >= 1 ? version : null;
}
