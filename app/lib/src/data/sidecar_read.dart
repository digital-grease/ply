// Reading projects' sidecars (`<craft dir>/<id>.json`) as untrusted input, shared by the library
// listings and the backup restore (ADR 0007, amendment of 2026-11-18, later).
//
// A sidecar is small when Ply writes it (about 7,200 JSON values at the most), but one restored from
// a backup can hold up to the restore's limit of values, and one an earlier build wrote can hold
// megabytes of notes. Dart's `jsonDecode` takes memory for every value, and decoding such a file on
// the UI isolate stalls it. So the same bounds apply wherever one is read: its values are counted
// and its nesting measured before it is decoded ([sidecarFit]); one past the bounds is not decoded
// at all; one with more than [kInlineSidecarValues] values, or over [kInlineSidecarBytes], is
// decoded on a background isolate. Pure Dart: no engine, no Flutter.

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../models/draft_meta.dart';
import 'json_count.dart';

/// The most JSON values a sidecar may have to be decoded: `BackupLimits.maxSidecarValues` (a restore
/// refuses a project whose sidecar has more), over 25 times the most Ply writes.
const int kMaxSidecarValues = 200000;

/// The deepest nesting of lists and objects a sidecar may have to be decoded:
/// `BackupLimits.maxSidecarDepth` (Ply writes 4).
const int kMaxSidecarDepth = 64;

/// A sidecar with at most this many JSON values is decoded on the calling isolate (about a
/// millisecond); one with more, up to [kMaxSidecarValues], on a background isolate
/// (`LibraryBackup.inlineSidecarValues`).
const int kInlineSidecarValues = 10000;

/// A library sidecar larger than this is read, measured and decoded on a background isolate, never
/// on the UI isolate (the largest sidecar a backup carries).
const int kInlineSidecarBytes = 1024 * 1024;

/// A library sidecar larger than this is not read in full for its listing (the largest document a
/// backup reads, and the largest sidecar whose notes Ply opens).
const int kMaxListedSidecarBytes = 64 * 1024 * 1024;

/// How a sidecar's text fits the bounds, found before anything is decoded.
enum SidecarFit {
  /// Within the bounds and at most [kInlineSidecarValues] values: decoded where it is read.
  inline,

  /// Within the bounds, with more values: decoded on a background isolate.
  background,

  /// Past [kMaxSidecarValues] values or [kMaxSidecarDepth] levels, or holding a number too large
  /// for a double (`jsonDecode` makes it infinity, which `jsonEncode` refuses when it is written
  /// again): not decoded.
  tooComplex,
}

/// How [bytes] (a sidecar's UTF-8 text, or its code units) fit the bounds, measured in one pass that
/// allocates nothing ([measureJson]). A malformed text gets a fit too; decoding it then fails.
SidecarFit sidecarFit(List<int> bytes,
    {int maxValues = kMaxSidecarValues, int maxDepth = kMaxSidecarDepth}) {
  final shape = measureJson(bytes, stop: maxValues);
  if (shape.values > maxValues || shape.depth > maxDepth || shape.nonFinite) {
    return SidecarFit.tooComplex;
  }
  return shape.values <= kInlineSidecarValues ? SidecarFit.inline : SidecarFit.background;
}

/// How much of a sidecar is read for its name when it is not decoded: Ply writes `name` first.
const int _headBytes = 4096;

/// The project name in [head], the first bytes of a sidecar, or null when they hold none (or only
/// spaces): Ply writes `name` first, so the first 4 KB hold any name Ply would let a crafter type.
/// Only a top-level `name` counts (the first one in [head] whose value is text): a name inside a
/// value, such as a loom plan's, is skipped, and so is anything inside a string. The head is scanned once, as text,
/// tracking how deeply lists and objects nest; nothing is decoded but the key and the name.
String? sidecarNameAtHead(List<int> head) {
  try {
    final text = utf8.decode(head, allowMalformed: true);
    final n = text.length;
    int skipSpace(int i) {
      while (i < n && ' \t\n\r'.contains(text[i])) {
        i++;
      }
      return i;
    }

    // Just past the string that opens at [i], or -1 when it does not end in [head].
    int stringEnd(int i) {
      for (i++; i < n; i++) {
        final c = text[i];
        if (c == '\\') {
          i++;
        } else if (c == '"') {
          return i + 1;
        }
      }
      return -1;
    }

    var i = skipSpace(0);
    if (i >= n || text[i] != '{') return null;
    var depth = 0;
    while (i < n) {
      final c = text[i];
      if (c == '"') {
        final start = i;
        final end = stringEnd(i);
        if (end < 0) return null;
        i = end;
        // A key of the top-level object is a string inside it, at depth 1, followed by a colon.
        if (depth != 1) continue;
        final colon = skipSpace(end);
        if (colon >= n || text[colon] != ':' || jsonDecode(text.substring(start, end)) != 'name') {
          continue;
        }
        final value = skipSpace(colon + 1);
        if (value >= n) return null;
        if (text[value] != '"') continue; // a name that is not text: look further
        final valueEnd = stringEnd(value);
        if (valueEnd < 0) return null;
        final name = jsonDecode(text.substring(value, valueEnd));
        return name is String && name.trim().isNotEmpty ? name : null;
      }
      if (c == '{' || c == '[') {
        depth++;
      } else if (c == '}' || c == ']') {
        depth--;
        if (depth <= 0) return null; // the top-level object ended
      }
      i++;
    }
    return null;
  } catch (_) {
    return null; // only a name is at stake: the caller names the project another way
  }
}

/// [sidecarNameAtHead] of the first 4 KB of [sidecar], or null when they cannot be read.
Future<String?> sidecarNameInFile(File sidecar) async {
  try {
    final head = BytesBuilder(copy: false);
    await for (final chunk in sidecar.openRead(0, _headBytes)) {
      head.add(chunk);
    }
    return sidecarNameAtHead(head.takeBytes());
  } catch (_) {
    return null;
  }
}

/// The metadata of each sidecar in [sidecars] (the `<id>.json` files of one craft's folder, [craft]
/// being the sidecar's `craft` value, such as `Weaving`), in order, for that craft's library
/// listing; null for a file to leave out of the listing, as the listings have always left them out:
/// one the device cannot read, and, within the bounds, one that is not UTF-8, not JSON or not a
/// JSON object. Nothing on disk is changed.
///
/// - A sidecar of at most [kInlineSidecarBytes] with at most [kInlineSidecarValues] values (every
///   sidecar Ply writes) is decoded here, into its full [DraftMeta], as before.
/// - Any other is read, measured and decoded on one background isolate for the whole call (started
///   only when one is needed), and comes back with what a listing shows: its name, craft, author,
///   dates, version and loom fields. Its notes, plans and the keys this build does not know are
///   left out, so a listing never holds a large sidecar's tree or notes in memory. Opening,
///   renaming and saving a project read its sidecar from disk again, so nothing is lost.
/// - One past the bounds ([SidecarFit.tooComplex]), or over [kMaxListedSidecarBytes], is not decoded,
///   so whether it is valid JSON is not known (telling would take the decode the bounds avoid). It
///   lists when it starts as a JSON object (`{`) and is UTF-8 (over [kMaxListedSidecarBytes], when
///   its first 4 KB start with `{`; nothing more is read), JSON or not: a project's files are
///   better shown than hidden, and opening or renaming one that is not JSON fails as it always did,
///   while deleting it works. It lists under the name at its head ([sidecarNameAtHead], as a
///   backup's refusal names it) or, without one, its id (the file's name), dated by the file's last
///   change. One past the bounds that does not start with `{` or is not UTF-8 is left out.
Future<List<DraftMeta?>> readListedSidecars(List<File> sidecars, {required String craft}) async {
  final out = List<DraftMeta?>.filled(sidecars.length, null);
  final later = <int>[];
  for (var i = 0; i < sidecars.length; i++) {
    final f = sidecars[i];
    try {
      if (await f.length() > kInlineSidecarBytes) {
        later.add(i);
        continue;
      }
      final bytes = await f.readAsBytes();
      if (bytes.length > kInlineSidecarBytes || sidecarFit(bytes) != SidecarFit.inline) {
        later.add(i);
        continue;
      }
      out[i] = _decodedMeta(bytes, full: true);
    } catch (_) {
      // The device cannot read it, or it is no sidecar: left out, as before (one bad sidecar never
      // breaks the listing).
    }
  }
  if (later.isNotEmpty) {
    final read = await _readInBackground([for (final i in later) sidecars[i].path], craft);
    for (var k = 0; k < later.length; k++) {
      out[later[k]] = read[k];
    }
  }
  return out;
}

/// [_readListedSync] of each of [paths], on one background isolate.
Future<List<DraftMeta?>> _readInBackground(List<String> paths, String craft) => Isolate.run(
    () => [for (final path in paths) _readListedSync(path, craft)],
    debugName: 'library sidecars');

/// A sidecar read for its listing on a background isolate (see [readListedSidecars]); null to leave
/// it out.
DraftMeta? _readListedSync(String path, String craft) {
  final f = File(path);
  try {
    final length = f.lengthSync();
    if (length > kMaxListedSidecarBytes) {
      final raf = f.openSync();
      final Uint8List head;
      try {
        head = raf.readSync(_headBytes);
      } finally {
        raf.closeSync();
      }
      return _startsAsObject(head) ? _unreadMeta(f, head, craft) : null;
    }
    final bytes = f.readAsBytesSync();
    if (sidecarFit(bytes) == SidecarFit.tooComplex) {
      if (!_startsAsObject(bytes) || !_isUtf8(bytes)) return null;
      return _unreadMeta(f, Uint8List.sublistView(bytes, 0, math.min(bytes.length, _headBytes)),
          craft);
    }
    return _decodedMeta(bytes, full: false);
  } catch (_) {
    return null; // as before: one bad sidecar never breaks the listing
  }
}

/// The sidecar [bytes] decoded into its [DraftMeta] ([full]), or into the part a listing shows; null
/// when they are not a sidecar (not UTF-8 or JSON, or not an object).
DraftMeta? _decodedMeta(Uint8List bytes, {required bool full}) {
  final Object? json;
  try {
    json = jsonDecode(utf8.decode(bytes));
  } on FormatException {
    return null;
  }
  if (json is! Map<String, dynamic>) return null;
  final meta = DraftMeta.fromJson(json);
  if (full) return meta;
  return DraftMeta(
    name: meta.name,
    craft: meta.craft,
    author: meta.author,
    loomType: meta.loomType,
    overshotTreadling: meta.overshotTreadling,
    savedAt: meta.savedAt,
    lastOpened: meta.lastOpened,
    schemaVersion: meta.schemaVersion,
  );
}

/// The listing's metadata of a sidecar that is not decoded: the name at its [head] or the id, and
/// the file's last change as both dates.
DraftMeta _unreadMeta(File f, List<int> head, String craft) {
  final changed = f.lastModifiedSync();
  return DraftMeta(
    name: sidecarNameAtHead(head) ?? p.basenameWithoutExtension(f.path),
    craft: craft,
    savedAt: changed,
    lastOpened: changed,
  );
}

/// Whether [bytes] start, after JSON white space, with the `{` of an object.
bool _startsAsObject(List<int> bytes) {
  for (final b in bytes) {
    if (b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D) continue;
    return b == 0x7B;
  }
  return false;
}

/// Whether [bytes] are UTF-8 text.
bool _isUtf8(List<int> bytes) {
  try {
    utf8.decode(bytes);
    return true;
  } on FormatException {
    return false;
  }
}
