// Each library tile's saved place (ADR 0023, amendment of 2026-11-19): what a project's progress
// record (`<craft dir>/<id>.plyprogress`) says about where the crafter is, looked up by id apart from
// the listing, which it never holds up.
//
// A record is untrusted input (a backup brings it), so it is read with the tracker's own read: a
// record of at most [kInlinePlaceBytes] through `ProgressRepository.load` itself, a larger one through
// `ProgressRepository.readFileSync` (the same steps, with synchronous file calls) on one background
// isolate for the whole listing, started only when one is needed. At most [kPlaceReadsAtOnce] records
// are read at a time, so a large library never runs out of open files, and each place is handed on
// as soon as it is read. A [LibraryPlaceCache] keeps what each record was found to be, so a record
// that has not changed since is not decoded again.
//
// Nothing here writes, moves or sets a record aside, and nothing here throws: a record that cannot
// be read, or that a newer Ply wrote, gives a short line instead of a place; a record the device
// could not read just now, or any other failure no record explains, gives no line at all.
//
// Only what the record states is kept: its place, the pattern's units when the place was saved, and
// when the record last changed. The engine's resume is not run per tile: whether the pattern changed
// under the place is the tracker's to say, when it opens.

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import '../models/progress.dart';
import 'library_backup.dart' show BackupCraft;
import 'progress_repository.dart';

/// A record of at most this many bytes is read on the calling isolate (it decodes in about a
/// millisecond); a larger one, up to the file bound, on a background isolate. Many records of
/// ordinary use are larger (a full 400-entry log in knitting sections is about 113 KB, and notes
/// take a weaving record with a full log past it), so a listing of tracked projects often uses the
/// background isolate.
const int kInlinePlaceBytes = 64 * 1024;

/// The most records a listing reads at the same time.
const int kPlaceReadsAtOnce = 8;

/// What a tile can say about a project's record.
enum LibraryPlaceKind {
  /// The record reads: [LibraryPlace.place] is where the crafter is.
  read,

  /// Saved by a newer version of Ply: not read (the tracker says to update the app).
  newer,

  /// Not a record this build can read (bad JSON, past a bound, too large): not read (the tracker
  /// offers Start again, which keeps it aside).
  unreadable,
}

/// A project's saved place as its record states it, for its library tile.
class LibraryPlace {
  const LibraryPlace.read({required WorkPlace this.place, this.units, this.updated})
      : kind = LibraryPlaceKind.read;

  const LibraryPlace.newer()
      : kind = LibraryPlaceKind.newer,
        place = null,
        units = null,
        updated = null;

  const LibraryPlace.unreadable()
      : kind = LibraryPlaceKind.unreadable,
        place = null,
        units = null,
        updated = null;

  final LibraryPlaceKind kind;

  /// The place (the next unit to work), for [LibraryPlaceKind.read].
  final WorkPlace? place;

  /// How many units the pattern had when the place was saved (its basis), when the record says.
  final int? units;

  /// When the record last changed (a move, or a note added, changed or deleted), when it says.
  final DateTime? updated;

  /// What a tile shows for [load]: nothing for no record, a record with no place yet (the tracker
  /// starts at the first unit), or a record the device could not read just now.
  static LibraryPlace? fromLoad(ProgressLoad load) => switch (load.status) {
        ProgressStatus.none || ProgressStatus.failed => null,
        ProgressStatus.ok => _fromProgress(load.progress),
        ProgressStatus.newer => const LibraryPlace.newer(),
        ProgressStatus.unreadable => const LibraryPlace.unreadable(),
      };

  static LibraryPlace? _fromProgress(Progress? p) {
    final place = p?.place;
    if (p == null || place == null) return null;
    return LibraryPlace.read(place: place, units: p.basis?.units, updated: p.updated);
  }

  @override
  bool operator ==(Object other) =>
      other is LibraryPlace &&
      other.kind == kind &&
      other.place == place &&
      other.units == units &&
      other.updated == updated;

  @override
  int get hashCode => Object.hash(kind, place, units, updated);

  @override
  String toString() => 'LibraryPlace($kind, $place, of $units, $updated)';
}

/// What a record file was when it was read: its path, size, last change of content and of the file
/// itself, and how many writes this app had made to it. The same stamp again means the same record.
class _Stamp {
  const _Stamp(this.path, this.size, this.modified, this.changed, this.writes);

  final String path;
  final int size;
  final DateTime modified;
  final DateTime changed;
  final int writes;

  @override
  bool operator ==(Object other) =>
      other is _Stamp &&
      other.path == path &&
      other.size == size &&
      other.modified == modified &&
      other.changed == changed &&
      other.writes == writes;

  @override
  int get hashCode => Object.hash(path, size, modified, changed, writes);
}

/// What each record was found to be when it was last read, by project, so an unchanged record is not
/// decoded again, and a screen built again shows the places it showed before while it reads them
/// anew. One per app (and per progress repository). Holds only what a tile shows.
class LibraryPlaceCache {
  final Map<(BackupCraft, String), (_Stamp, LibraryPlace?)> _read = {};

  /// The places last read for [craft]'s projects, by id (those with a line to show).
  Map<String, LibraryPlace> lastFor(BackupCraft craft) => {
        for (final e in _read.entries)
          if (e.key.$1 == craft && e.value.$2 != null) e.key.$2: e.value.$2!,
      };

  /// What [id]'s record was found to be, when it is still the record [stamp] describes.
  (LibraryPlace?,)? _lookup(BackupCraft craft, String id, _Stamp stamp) {
    final hit = _read[(craft, id)];
    return hit != null && hit.$1 == stamp ? (hit.$2,) : null;
  }

  void _store(BackupCraft craft, String id, _Stamp stamp, LibraryPlace? place) =>
      _read[(craft, id)] = (stamp, place);

  void _forget(BackupCraft craft, String id) => _read.remove((craft, id));
}

/// The saved places of [ids], projects of [craft], by id. An id with no record, whose record has no
/// place yet, whose record the device could not read just now, or whose record could not be looked
/// for at all (the documents folder is not there) is left out. Never throws and never writes.
///
/// Each record is read once every write this app has queued to it has finished, so a tile listed
/// right after the tracker closes shows the place it wrote last. [onRead] is told each id's line as
/// soon as it is known (null for none): the small records as they are read, the large ones as the
/// background isolate reads them. With [cache], a record unchanged since it was last read is not
/// read again, and what is read is kept. Once [stillWanted] says no (a newer read has begun), no
/// record is read, nothing is kept and [onRead] is not called again.
Future<Map<String, LibraryPlace>> readLibraryPlaces(
  ProgressRepository repository,
  BackupCraft craft,
  Iterable<String> ids, {
  LibraryPlaceCache? cache,
  void Function(String id, LibraryPlace? place)? onRead,
  bool Function()? stillWanted,
}) async {
  final out = <String, LibraryPlace>{};
  final ProgressCraft? pc = ProgressRepository.craftOf(craft);
  if (pc == null) return out;
  bool wanted() => stillWanted?.call() ?? true;
  void found(String id, LibraryPlace? place) {
    if (!wanted()) return;
    if (place != null) out[id] = place;
    onRead?.call(id, place);
  }

  final queue = ids.toSet().toList();
  final later = <(String, _Stamp)>[];
  var next = 0;

  Future<void> readOne(String id) async {
    try {
      final f = await repository.settled(craft, id);
      final writes = ProgressRepository.writeCount(f.path);
      final stat = await f.stat();
      if (stat.type == FileSystemEntityType.notFound) {
        cache?._forget(craft, id);
        found(id, null);
        return;
      }
      final stamp = _Stamp(f.path, stat.size, stat.modified, stat.changed, writes);
      final hit = cache?._lookup(craft, id, stamp);
      if (hit != null) {
        found(id, hit.$1);
        return;
      }
      if (stat.size > kInlinePlaceBytes) {
        later.add((id, stamp));
        return;
      }
      // The tracker's own read.
      final load = await repository.load(craft, id);
      final place = LibraryPlace.fromLoad(load);
      if (!wanted()) return;
      if (load.status == ProgressStatus.failed) {
        cache?._forget(craft, id);
      } else {
        cache?._store(craft, id, stamp, place);
      }
      found(id, place);
    } catch (_) {
      // No place to show: a record never fails a tile.
      found(id, null);
    }
  }

  Future<void> worker() async {
    while (next < queue.length && wanted()) {
      await readOne(queue[next++]);
    }
  }

  await Future.wait([for (var k = 0; k < math.min(kPlaceReadsAtOnce, queue.length); k++) worker()]);
  if (later.isNotEmpty && wanted()) {
    await _readInBackground([for (final (_, stamp) in later) stamp.path], pc, wanted, (k, load) {
      final (id, stamp) = later[k];
      final place = LibraryPlace.fromLoad(load);
      if (load.status == ProgressStatus.failed) {
        cache?._forget(craft, id);
      } else {
        cache?._store(craft, id, stamp, place);
      }
      found(id, place);
    });
  }
  return out;
}

/// Read the records at [paths] one after another on one background isolate, with the tracker's own
/// read, handing each back to [onRead] (with its index) as it is read. Ends the isolate early once
/// [wanted] says no. Records it did not get to (the isolate failed) are not handed back.
Future<void> _readInBackground(List<String> paths, ProgressCraft craft, bool Function() wanted,
    void Function(int index, ProgressLoad load) onRead) async {
  final port = ReceivePort();
  final done = Completer<void>();
  Isolate? isolate;
  late final StreamSubscription<Object?> listening;
  void finish() {
    if (done.isCompleted) return;
    listening.cancel();
    port.close();
    done.complete();
  }

  listening = port.listen((message) {
    if (message is (int, ProgressLoad)) {
      if (!wanted()) {
        isolate?.kill(priority: Isolate.immediate);
        finish();
        return;
      }
      onRead(message.$1, message.$2);
    } else {
      // All read (null), the isolate ended, or it failed.
      finish();
    }
  });
  try {
    isolate = await Isolate.spawn(_readRecords, (port.sendPort, paths, craft),
        onExit: port.sendPort, onError: port.sendPort, debugName: 'library places');
  } catch (_) {
    finish();
  }
  return done.future;
}

/// The background isolate's work: each record's read, sent back as it is done.
void _readRecords((SendPort, List<String>, ProgressCraft) job) {
  final (port, paths, craft) = job;
  for (var k = 0; k < paths.length; k++) {
    final load = ProgressRepository.readFileSync(paths[k], craft);
    // Only what a tile shows crosses back: the record itself stays here.
    final p = load.progress;
    port.send((
      k,
      ProgressLoad(
          load.status,
          p == null
              ? null
              : Progress(craft: p.craft, place: p.place, basis: p.basis, updated: p.updated)),
    ));
  }
  port.send(null);
}
