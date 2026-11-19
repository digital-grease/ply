// Reading and rewriting the notes of a saved weaving draft in its sidecar (ADR 0007, amendment of
// 2026-11-18, item 7), shared by the notes editor's repository calls and the backup's check of a
// sidecar too large because of its notes, so the two never disagree about which notes can be
// changed.
//
// A sidecar written before the notes limit can hold a megabyte or more of notes, so it is read with
// the backup's bounds: at most 64 MB (the largest document a backup reads), its JSON values counted
// and its nesting measured before it is decoded (a restore's limits for a sidecar), and past 1 MB
// read and decoded on a background isolate, never on the UI isolate. Pure Dart: no engine, no
// Flutter.

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../models/draft_meta.dart';
import 'json_count.dart';

/// The largest sidecar whose notes Ply opens or changes: the largest document a backup reads.
const int maxNotesSidecarBytes = 64 * 1024 * 1024;

/// Past this size a sidecar is read and decoded for its notes on a background isolate (a backup's
/// limit for a sidecar).
const int inlineNotesSidecarBytes = 1024 * 1024;

/// The most JSON values, and the deepest nesting, a sidecar may have for its notes to be opened: a
/// restore's limits for a sidecar. A sidecar past them, or holding a number too large for a double
/// (which could not be written again), is refused as unreadable before it is decoded.
const int maxNotesSidecarValues = 200000;
const int maxNotesSidecarDepth = 64;

/// Why a draft's notes cannot be read or changed. [message] is the plain sentence for the weaver.
enum DraftNotesProblem {
  /// The sidecar is gone: the draft was deleted.
  gone('This draft is no longer in your library.'),

  /// The sidecar is over [maxNotesSidecarBytes].
  tooLarge("This draft's notes are too large for Ply to open (over 64 MB)."),

  /// Not a sidecar, past the value or nesting limit, a number too large for a double, or a file the
  /// device cannot read.
  unreadable("This draft's details could not be read."),

  /// Written by a newer sidecar schema, whose notes this build must not change.
  newerVersion(
      'This draft was saved by a newer version of Ply, so its notes cannot be changed here.'),

  /// The notes are not text: a value this build keeps as it is but cannot show.
  notText("This draft's notes were saved in a form this version of Ply cannot change."),

  /// The notes on disk are not the ones the weaver opened (changed in another notes editor).
  changed('The notes changed while you had them open, so your changes were not saved. Open '
      'Notes again to see them.');

  const DraftNotesProblem(this.message);

  final String message;
}

/// Why this build must not change the notes in a decoded sidecar [json] (a newer sidecar schema, or
/// notes that are not text), or null when it may.
DraftNotesProblem? notesProblemIn(Map<String, dynamic> json) {
  final version = json['schemaVersion'];
  if (version is num && version > DraftMeta.currentSchemaVersion) {
    return DraftNotesProblem.newerVersion;
  }
  final notes = json['notes'];
  if (notes != null && notes is! String) return DraftNotesProblem.notText;
  return null;
}

/// A sidecar's [bytes] decoded for its notes: the sidecar ([json]) and its notes (empty when it has
/// none), or the [problem] that stops them being read or changed. The values are counted and the
/// nesting measured before anything is decoded.
({DraftNotesProblem? problem, Map<String, dynamic>? json, String notes}) decodeNotesSidecar(
    Uint8List bytes) {
  const unreadable = (problem: DraftNotesProblem.unreadable, json: null, notes: '');
  final shape = measureJson(bytes, stop: maxNotesSidecarValues);
  if (shape.values > maxNotesSidecarValues ||
      shape.depth > maxNotesSidecarDepth ||
      shape.nonFinite) {
    return unreadable;
  }
  final Object? json;
  try {
    json = jsonDecode(utf8.decode(bytes));
  } on FormatException {
    return unreadable;
  }
  if (json is! Map<String, dynamic>) return unreadable;
  final problem = notesProblemIn(json);
  if (problem != null) return (problem: problem, json: null, notes: '');
  return (problem: null, json: json, notes: (json['notes'] as String?) ?? '');
}

/// A fingerprint of [notes] (the SHA-256 of their UTF-8 bytes, in hex), for checking that the notes
/// on disk are still the ones read without carrying those notes (up to 64 MB) to the background
/// isolate that rewrites the sidecar. A lone surrogate, which UTF-8 cannot hold, is encoded as
/// U+FFFD, the same way every time, so the same notes always give the same fingerprint.
String notesDigest(String notes) => sha256.convert(utf8.encode(notes)).toString();

/// What reading or rewriting a sidecar's notes came to: the notes read with their [notesDigest], or
/// the sidecar's new text, or the [problem] that stopped it (nothing then written).
typedef NotesFileResult = ({
  DraftNotesProblem? problem,
  String? notes,
  String? digest,
  String? rewritten,
});

NotesFileResult _refused(DraftNotesProblem problem) =>
    (problem: problem, notes: null, digest: null, rewritten: null);

/// The notes of sidecar [path] (see [decodeNotesSidecar]) and their [notesDigest], worked out where
/// the sidecar is read.
Future<NotesFileResult> readNotesFile(String path) => _onSidecar(path, _readNotes);

/// The text of sidecar [path] with its `notes` set to [notes], every other key kept with its value
/// and in its place. With [expectedDigest], refuses ([DraftNotesProblem.changed]) when the notes on
/// disk do not have that [notesDigest]. Nothing is written here: the caller writes the text.
Future<NotesFileResult> rewriteNotesFile(String path, String notes, {String? expectedDigest}) =>
    _onSidecar(path, (bytes) => _rewriteNotes(bytes, notes, expectedDigest));

NotesFileResult _readNotes(Uint8List bytes) {
  final read = decodeNotesSidecar(bytes);
  if (read.problem != null) return _refused(read.problem!);
  return (problem: null, notes: read.notes, digest: notesDigest(read.notes), rewritten: null);
}

NotesFileResult _rewriteNotes(Uint8List bytes, String notes, String? expectedDigest) {
  final read = decodeNotesSidecar(bytes);
  if (read.problem != null) return _refused(read.problem!);
  if (expectedDigest != null && notesDigest(read.notes) != expectedDigest) {
    return _refused(DraftNotesProblem.changed);
  }
  final json = read.json!..['notes'] = notes;
  try {
    return (problem: null, notes: null, digest: null, rewritten: jsonEncode(json));
  } on JsonUnsupportedObjectError {
    return _refused(DraftNotesProblem.unreadable);
  }
}

/// Run [work] on the bytes of sidecar [path]: here for a sidecar of at most
/// [inlineNotesSidecarBytes], on a background isolate (which reads the file itself) for a larger
/// one. A sidecar that is gone or over [maxNotesSidecarBytes] is refused without being read.
Future<NotesFileResult> _onSidecar(
    String path, NotesFileResult Function(Uint8List bytes) work) async {
  final int length;
  try {
    if (!await File(path).exists()) return _refused(DraftNotesProblem.gone);
    length = await File(path).length();
  } on FileSystemException {
    return _refused(DraftNotesProblem.unreadable);
  }
  if (length > maxNotesSidecarBytes) return _refused(DraftNotesProblem.tooLarge);
  Future<NotesFileResult> run() async {
    final Uint8List bytes;
    try {
      bytes = await File(path).readAsBytes();
    } on FileSystemException {
      return _refused(DraftNotesProblem.unreadable);
    }
    if (bytes.length > maxNotesSidecarBytes) return _refused(DraftNotesProblem.tooLarge);
    return work(bytes);
  }

  return length > inlineNotesSidecarBytes ? Isolate.run(run, debugName: 'draft notes') : run();
}
