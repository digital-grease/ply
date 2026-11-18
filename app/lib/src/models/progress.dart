// Progress tracking (ADR 0023): where a crafter is in a project, in their craft's own work unit, with
// a completion log, notes pinned to places, and undo that survives a restart. Pure data: no FFI and
// no file I/O. `ProgressRepository` reads and writes the file (`<craft folder>/<id>.plyprogress`);
// the engines say what a unit is, what to do at it, and whether a saved place still means the same.
//
// The record is the app's own file, apart from the pattern and its sidecar, so keeping a place never
// rewrites the pattern, never marks it edited and never runs a migration or a readiness check.

import 'dart:convert';

/// The `format` value of a progress file.
const String kProgressFormat = 'ply.progress';

/// The progress file schema version this build writes (and the newest it reads).
const int kProgressSchemaVersion = 1;

/// The hard bounds of a progress record (ADR 0023 section 3). The writer keeps to them and the reader
/// refuses anything past them, so Ply never writes a file it would refuse.
abstract final class ProgressLimits {
  /// The file, in bytes. A larger file is not decoded (its version is still probed from its first
  /// bytes, so a newer one is never taken for an unreadable one).
  static const int maxFileBytes = 512 * 1024;

  /// How much of a file past [maxFileBytes] is read to find its version.
  static const int versionProbeBytes = 4096;

  /// Log entries kept; the oldest is dropped (and counted) past it.
  static const int maxLogEntries = 400;

  /// Undo frames kept; the oldest is dropped past it.
  static const int maxUndo = 50;

  /// Notes, the characters of one note, and the characters of all notes together (UTF-16 units,
  /// `String.length`).
  static const int maxNotes = 100;
  static const int maxNoteChars = 500;
  static const int maxNotesTotalChars = 10000;

  /// Every number in the file (pick, repeat, unit, row, count, units).
  static const int maxNumber = 0xFFFFFFFF;

  /// A stored time.
  static const int maxTimeChars = 40;

  /// The most JSON values a record may have, counted before it is decoded. The largest record the
  /// bounds above allow has 19,991; this is five times that, for keys a later build adds within the
  /// same version.
  static const int maxValues = 100000;

  /// The deepest nesting of lists and objects a record may have (Ply writes 5: an undo frame's
  /// entry's place). A deeper one, or one holding a number too large for a double, is unreadable:
  /// writing it again would recurse past the stack or refuse the number.
  static const int maxDepth = 64;

  /// Consecutive steps the same way within this gap of the last one extend its log entry.
  static const Duration sessionGap = Duration(minutes: 30);
}

/// The crafts this build tracks, by the `craft` key of the file (the backup's craft names).
enum ProgressCraft {
  weaving('weaving'),
  knitting('knitting');

  const ProgressCraft(this.key);

  final String key;
}

/// What stopped Ply from reading or writing a progress record.
enum ProgressProblem {
  /// Saved by a newer version of Ply: never read and never replaced.
  newerVersion,

  /// Not a progress record this build can read (bad JSON, wrong shape, past a bound, too large).
  unreadable,

  /// The record would be past the file bound even with its oldest log entries dropped.
  tooLarge,

  /// The project is no longer in the library (it was deleted while the tracker was open).
  projectGone,
}

/// A progress record this build must not read, or must not write.
class ProgressFileException implements Exception {
  const ProgressFileException(this.problem, {this.detail});

  final ProgressProblem problem;

  /// For logs and tests; never the main message.
  final String? detail;

  String get message => switch (problem) {
        ProgressProblem.newerVersion =>
          'Your place in this project was saved by a newer version of Ply. Update the app to keep '
              'tracking it.',
        ProgressProblem.unreadable => 'Your place in this project could not be read.',
        ProgressProblem.tooLarge => 'Your place could not be saved: the record is too large.',
        ProgressProblem.projectGone =>
          'Your place could not be saved: this project is no longer in your library.',
      };

  @override
  String toString() => message;
}

/// A note that cannot be added or changed as it is (empty, too long, too many).
class ProgressLimitException implements Exception {
  const ProgressLimitException(this.message);

  final String message;

  @override
  String toString() => message;
}

final RegExp _idGrammar = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$');
final RegExp _hex16 = RegExp(r'^[0-9a-f]{16}$');

/// A section or step id a knitting place may store (the id grammar); anything else is not stored.
bool isStorableId(String? id) => id != null && _idGrammar.hasMatch(id);

// --- places ----------------------------------------------------------------------------------------

/// Where a crafter is: the unit they are about to work, in their craft's own terms. Each craft has its
/// own fields; there is no shared notion of a row.
sealed class WorkPlace {
  const WorkPlace();

  /// The place in the file. [full] false keeps only the numbers (a log entry's places).
  Map<String, Object?> toJson({bool full = true});

  /// The same unit, row and time through (ids and other details aside).
  bool sameSpot(WorkPlace other);

  /// The same place in the pattern: for knitting places that both name their step, the same section,
  /// step, chart row, row and time through, wherever the step is now; otherwise [sameSpot].
  bool samePlace(WorkPlace other) => sameSpot(other);

  static WorkPlace fromJson(ProgressCraft craft, Object? json) => switch (craft) {
        ProgressCraft.weaving => PickPlace.fromJson(json),
        ProgressCraft.knitting => KnitPlace.fromJson(json),
      };
}

/// A weaving place: the pick (from 1) and the time through the draft (from 1).
class PickPlace extends WorkPlace {
  const PickPlace(this.pick, {this.repeat = 1});

  final int pick;
  final int repeat;

  factory PickPlace.fromJson(Object? json) {
    final m = _object(json, const {'pick', 'repeat'});
    return PickPlace(_number(m['pick'], min: 1), repeat: _number(m['repeat'], min: 1));
  }

  @override
  Map<String, Object?> toJson({bool full = true}) => {'pick': pick, 'repeat': repeat};

  @override
  bool sameSpot(WorkPlace other) =>
      other is PickPlace && other.pick == pick && other.repeat == repeat;

  @override
  bool operator ==(Object other) => other is PickPlace && sameSpot(other);

  @override
  int get hashCode => Object.hash(pick, repeat);

  @override
  String toString() => 'PickPlace($pick, repeat $repeat)';
}

/// A knitting place: the unit (from 0: a chart row, or a line of the sections' ledger), the row inside
/// it (from 1), the time through the chart (from 1), and for a sections line the ids and chart row
/// that let a moved step be found again.
class KnitPlace extends WorkPlace {
  const KnitPlace(this.unit,
      {this.row = 1, this.repeat = 1, this.sectionId, this.stepId, this.chartRow});

  final int unit;
  final int row;
  final int repeat;
  final String? sectionId;
  final String? stepId;
  final int? chartRow;

  factory KnitPlace.fromJson(Object? json) {
    final m = _object(json, const {'unit', 'row', 'repeat', 'section', 'step', 'chartRow'});
    String? id(String key) {
      final v = m[key];
      if (v == null) return null;
      if (v is! String || !isStorableId(v)) throw FormatException('bad $key');
      return v;
    }

    return KnitPlace(
      _number(m['unit'], min: 0),
      row: _number(m['row'], min: 1),
      repeat: _number(m['repeat'], min: 1),
      sectionId: id('section'),
      stepId: id('step'),
      chartRow: m['chartRow'] == null ? null : _number(m['chartRow'], min: 1),
    );
  }

  /// The same place with ids outside the grammar left out (the place then rests on its number and
  /// fingerprint).
  KnitPlace storable() => KnitPlace(unit,
      row: row,
      repeat: repeat,
      sectionId: isStorableId(sectionId) ? sectionId : null,
      stepId: isStorableId(stepId) ? stepId : null,
      chartRow: chartRow);

  @override
  Map<String, Object?> toJson({bool full = true}) => {
        'unit': unit,
        'row': row,
        'repeat': repeat,
        if (full && isStorableId(sectionId)) 'section': sectionId,
        if (full && isStorableId(stepId)) 'step': stepId,
        if (full && chartRow != null) 'chartRow': chartRow,
      };

  @override
  bool sameSpot(WorkPlace other) =>
      other is KnitPlace && other.unit == unit && other.row == row && other.repeat == repeat;

  /// True when this place names its step by id.
  bool get hasIds => stepId != null;

  @override
  bool samePlace(WorkPlace other) {
    if (other is! KnitPlace) return false;
    if (!hasIds || !other.hasIds) return sameSpot(other);
    return other.sectionId == sectionId &&
        other.stepId == stepId &&
        other.chartRow == chartRow &&
        other.row == row &&
        other.repeat == repeat;
  }

  @override
  bool operator ==(Object other) =>
      other is KnitPlace &&
      sameSpot(other) &&
      other.sectionId == sectionId &&
      other.stepId == stepId &&
      other.chartRow == chartRow;

  @override
  int get hashCode => Object.hash(unit, row, repeat, sectionId, stepId, chartRow);

  @override
  String toString() => 'KnitPlace($unit, row $row, repeat $repeat)';
}

/// What a place was saved against: the pattern's units then, and the prefix fingerprint at the place
/// (16 lowercase hexadecimal digits, from the engine).
class PlaceBasis {
  const PlaceBasis({required this.units, required this.prefix});

  final int units;
  final String prefix;

  factory PlaceBasis.fromJson(Object? json) {
    final m = _object(json, const {'units', 'prefix'});
    final prefix = m['prefix'];
    if (prefix is! String || !_hex16.hasMatch(prefix)) throw const FormatException('bad prefix');
    return PlaceBasis(units: _number(m['units'], min: 0), prefix: prefix);
  }

  Map<String, Object?> toJson() => {'units': units, 'prefix': prefix};

  @override
  bool operator ==(Object other) =>
      other is PlaceBasis && other.units == units && other.prefix == prefix;

  @override
  int get hashCode => Object.hash(units, prefix);
}

// --- the log ---------------------------------------------------------------------------------------

/// What a log entry records.
enum LogKind {
  /// Units worked (Next).
  worked('worked'),

  /// A correction: units stepped back (Previous).
  back('back'),

  /// The place set by hand (Go to).
  jump('jump'),

  /// The place moved because the pattern did (a place shown for checking, accepted).
  fix('fix');

  const LogKind(this.key);

  final String key;

  static LogKind? byKey(Object? key) {
    for (final k in values) {
      if (k.key == key) return k;
    }
    return null;
  }
}

/// One entry of the completion log. Its places are kept whole (a knitting place with its section and
/// step ids), so the log still names the right step after the pattern changes.
class LogEntry {
  const LogEntry({
    required this.kind,
    required this.from,
    required this.to,
    required this.count,
    required this.start,
    required this.end,
  });

  final LogKind kind;
  final WorkPlace from;
  final WorkPlace to;

  /// Units worked or stepped back (1 for a jump or a fix).
  final int count;
  final DateTime start;
  final DateTime end;

  factory LogEntry.fromJson(ProgressCraft craft, Object? json) {
    final m = _object(json, const {'kind', 'from', 'to', 'count', 'start', 'end'});
    final kind = LogKind.byKey(m['kind']);
    if (kind == null) throw const FormatException('bad log kind');
    return LogEntry(
      kind: kind,
      from: WorkPlace.fromJson(craft, m['from']),
      to: WorkPlace.fromJson(craft, m['to']),
      count: _number(m['count'], min: 1),
      start: _time(m['start']),
      end: _time(m['end']),
    );
  }

  Map<String, Object?> toJson() => {
        'kind': kind.key,
        'from': from.toJson(),
        'to': to.toJson(),
        'count': count,
        'start': _timeText(start),
        'end': _timeText(end),
      };

  @override
  bool operator ==(Object other) =>
      other is LogEntry &&
      other.kind == kind &&
      other.from.sameSpot(from) &&
      other.to.sameSpot(to) &&
      other.count == count &&
      other.start == start &&
      other.end == end;

  @override
  int get hashCode => Object.hash(kind, count, start, end);
}

// --- notes -----------------------------------------------------------------------------------------

/// The crafter's own note, pinned to a place.
class ProgressNote {
  const ProgressNote({required this.id, required this.place, required this.text, required this.at});

  final String id;
  final WorkPlace place;
  final String text;
  final DateTime at;

  factory ProgressNote.fromJson(ProgressCraft craft, Object? json) {
    final m = _object(json, const {'id', 'place', 'text', 'at'});
    final id = m['id'];
    final text = m['text'];
    if (id is! String || !isStorableId(id)) throw const FormatException('bad note id');
    if (text is! String || text.isEmpty || text.length > ProgressLimits.maxNoteChars) {
      throw const FormatException('bad note text');
    }
    return ProgressNote(
        id: id, place: WorkPlace.fromJson(craft, m['place']), text: text, at: _time(m['at']));
  }

  Map<String, Object?> toJson() =>
      {'id': id, 'place': place.toJson(), 'text': text, 'at': _timeText(at)};

  @override
  bool operator ==(Object other) =>
      other is ProgressNote &&
      other.id == id &&
      other.place == place &&
      other.text == text &&
      other.at == at;

  @override
  int get hashCode => Object.hash(id, text, at);
}

// --- undo ------------------------------------------------------------------------------------------

/// What a change of place did to the log, so Undo can reverse it exactly.
enum LogChange {
  /// It added a new entry (Undo removes the last entry).
  appended('appended'),

  /// It extended the last entry ([UndoFrame.last] is that entry as it was).
  extended('extended'),

  /// It left the log alone.
  none('none');

  const LogChange(this.key);

  final String key;

  static LogChange? byKey(Object? key) {
    for (final c in values) {
      if (c.key == key) return c;
    }
    return null;
  }
}

/// How to undo one change of place: the place and basis before it, and what it did to the log.
class UndoFrame {
  const UndoFrame({required this.place, this.basis, required this.change, this.last});

  /// The stored place before the change (`null`: none was stored yet).
  final WorkPlace? place;
  final PlaceBasis? basis;
  final LogChange change;

  /// For [LogChange.extended]: the log's last entry before the change.
  final LogEntry? last;

  factory UndoFrame.fromJson(ProgressCraft craft, Object? json) {
    final m = _object(json, const {'place', 'basis', 'change', 'last'});
    final change = LogChange.byKey(m['change']);
    if (change == null) throw const FormatException('bad undo change');
    final last = m['last'] == null ? null : LogEntry.fromJson(craft, m['last']);
    if ((change == LogChange.extended) != (last != null)) {
      throw const FormatException('undo frame without its entry');
    }
    return UndoFrame(
      place: m['place'] == null ? null : WorkPlace.fromJson(craft, m['place']),
      basis: m['basis'] == null ? null : PlaceBasis.fromJson(m['basis']),
      change: change,
      last: last,
    );
  }

  Map<String, Object?> toJson() => {
        'place': place?.toJson(),
        'basis': basis?.toJson(),
        'change': change.key,
        if (last != null) 'last': last!.toJson(),
      };
}

// --- the record ------------------------------------------------------------------------------------

/// A project's checkpoint record: the place (the next unit to work), what it was saved against, the
/// completion log, the notes, undo, and when tracking began and last changed. Unknown top-level keys
/// from a later build are kept in [extra] and written back. Immutable: every change returns a new
/// record.
class Progress {
  const Progress({
    required this.craft,
    this.place,
    this.basis,
    this.log = const [],
    this.logDropped = 0,
    this.notes = const [],
    this.lastNoteNumber = 0,
    this.undo = const [],
    this.started,
    this.updated,
    this.extra = const {},
  });

  final ProgressCraft craft;

  /// The stored place; `null` before the first change (the tracker starts at the first unit).
  final WorkPlace? place;
  final PlaceBasis? basis;
  final List<LogEntry> log;

  /// How many log entries were dropped to keep the log within its bound.
  final int logDropped;
  final List<ProgressNote> notes;

  /// The highest note number ever given (ids are never reused).
  final int lastNoteNumber;
  final List<UndoFrame> undo;
  final DateTime? started;
  final DateTime? updated;
  final Map<String, Object?> extra;

  static const _known = {
    'format',
    'schemaVersion',
    'craft',
    'place',
    'basis',
    'started',
    'updated',
    'log',
    'logDropped',
    'notes',
    'lastNoteNumber',
    'undo',
  };

  bool get canUndo => undo.isNotEmpty;

  Progress _copy({
    WorkPlace? place,
    bool clearPlace = false,
    PlaceBasis? basis,
    bool clearBasis = false,
    List<LogEntry>? log,
    int? logDropped,
    List<ProgressNote>? notes,
    int? lastNoteNumber,
    List<UndoFrame>? undo,
    DateTime? started,
    DateTime? updated,
  }) =>
      Progress(
        craft: craft,
        place: clearPlace ? null : (place ?? this.place),
        basis: clearBasis ? null : (basis ?? this.basis),
        log: List.unmodifiable(log ?? this.log),
        logDropped: logDropped ?? this.logDropped,
        notes: List.unmodifiable(notes ?? this.notes),
        lastNoteNumber: lastNoteNumber ?? this.lastNoteNumber,
        undo: List.unmodifiable(undo ?? this.undo),
        started: started ?? this.started,
        updated: updated ?? this.updated,
        extra: extra,
      );

  static List<UndoFrame> _pushFrame(List<UndoFrame> frames, UndoFrame f) {
    final out = [...frames, f];
    return out.length > ProgressLimits.maxUndo
        ? out.sublist(out.length - ProgressLimits.maxUndo)
        : out;
  }

  /// Move the place from [from] (the place on screen) to [to], saved against [basis], and log it as
  /// [kind] ([count] units for worked and back). Consecutive moves of the same kind that follow on
  /// within [ProgressLimits.sessionGap] extend the last entry; otherwise an entry is added, and the
  /// oldest dropped (and counted) past [ProgressLimits.maxLogEntries]. Undo returns to the STORED
  /// place before the move.
  Progress moved({
    required WorkPlace from,
    required WorkPlace to,
    required PlaceBasis? basis,
    required LogKind kind,
    required DateTime now,
    int count = 1,
  }) {
    final t = _trim(now);
    final last = log.isEmpty ? null : log.last;
    final extend = last != null &&
        (kind == LogKind.worked || kind == LogKind.back) &&
        last.kind == kind &&
        last.to.sameSpot(from) &&
        t.difference(last.end).abs() <= ProgressLimits.sessionGap;
    final frame = UndoFrame(
      place: place,
      basis: this.basis,
      change: extend ? LogChange.extended : LogChange.appended,
      last: extend ? last : null,
    );
    var entries = [...log];
    var dropped = logDropped;
    if (extend) {
      entries[entries.length - 1] = LogEntry(
        kind: kind,
        from: last.from,
        to: to,
        count: (last.count + count).clamp(1, ProgressLimits.maxNumber),
        start: last.start,
        end: t,
      );
    } else {
      entries.add(LogEntry(
          kind: kind,
          from: from,
          to: to,
          count: count.clamp(1, ProgressLimits.maxNumber),
          start: t,
          end: t));
      while (entries.length > ProgressLimits.maxLogEntries) {
        entries.removeAt(0);
        dropped = (dropped + 1).clamp(0, ProgressLimits.maxNumber);
      }
    }
    return _copy(
      place: _storablePlace(to),
      basis: basis,
      clearBasis: basis == null,
      log: entries,
      logDropped: dropped,
      undo: _pushFrame(undo, frame),
      started: started ?? t,
      updated: t,
    );
  }

  /// Keep the place where it is but save it against [basis] (the crafter checked a place whose
  /// pattern changed and said it is right). Not logged; Undo restores the old basis.
  Progress rebased({required WorkPlace place, required PlaceBasis basis, required DateTime now}) {
    final t = _trim(now);
    final frame = UndoFrame(place: this.place, basis: this.basis, change: LogChange.none);
    return _copy(
      place: _storablePlace(place),
      basis: basis,
      undo: _pushFrame(undo, frame),
      started: started ?? t,
      updated: t,
    );
  }

  /// Reverse the last change of place exactly: the place and basis before it, and the log as it was
  /// (an entry the log's bound dropped meanwhile stays dropped). `null` when there is nothing to undo.
  Progress? undone({required DateTime now}) {
    if (undo.isEmpty) return null;
    final frame = undo.last;
    final entries = [...log];
    switch (frame.change) {
      case LogChange.appended:
        if (entries.isNotEmpty) entries.removeLast();
      case LogChange.extended:
        if (entries.isNotEmpty) {
          entries[entries.length - 1] = frame.last!;
        } else {
          entries.add(frame.last!);
        }
      case LogChange.none:
        break;
    }
    return _copy(
      place: frame.place,
      clearPlace: frame.place == null,
      basis: frame.basis,
      clearBasis: frame.basis == null,
      log: entries,
      undo: undo.sublist(0, undo.length - 1),
      updated: _trim(now),
    );
  }

  int get _notesChars => notes.fold(0, (n, x) => n + x.text.length);

  void _checkNote(String text, {int replacing = 0}) {
    if (text.isEmpty) throw const ProgressLimitException('Write something in the note first.');
    if (text.length > ProgressLimits.maxNoteChars) {
      throw ProgressLimitException('A note can be at most ${ProgressLimits.maxNoteChars} '
          'characters, and this one is ${text.length} (some symbols, such as emoji, count as '
          'two).');
    }
    if (_notesChars - replacing + text.length > ProgressLimits.maxNotesTotalChars) {
      throw const ProgressLimitException('The notes for this project can hold at most '
          '${ProgressLimits.maxNotesTotalChars} characters in all. Shorten or delete a note '
          'first.');
    }
  }

  /// Add a note pinned to [place]. Refused, with a sentence, when empty or past a bound.
  Progress withNote(WorkPlace place, String text, {required DateTime now}) {
    final t = text.trim();
    if (notes.length >= ProgressLimits.maxNotes) {
      throw const ProgressLimitException('A project can keep at most '
          '${ProgressLimits.maxNotes} notes. Delete one first.');
    }
    _checkNote(t);
    if (lastNoteNumber >= ProgressLimits.maxNumber) {
      throw const ProgressLimitException(
          'This project has had too many notes for Ply to number another one.');
    }
    final number = lastNoteNumber + 1;
    final at = _trim(now);
    return _copy(
      notes: [
        ...notes,
        ProgressNote(id: 'note-$number', place: _storablePlace(place), text: t, at: at),
      ],
      lastNoteNumber: number,
      started: started ?? at,
      updated: at,
    );
  }

  /// Change a note's text. Refused, with a sentence, when empty or past a bound.
  Progress withNoteText(String id, String text, {required DateTime now}) {
    final i = notes.indexWhere((n) => n.id == id);
    if (i < 0) return this;
    final t = text.trim();
    _checkNote(t, replacing: notes[i].text.length);
    final next = [...notes];
    next[i] = ProgressNote(id: id, place: notes[i].place, text: t, at: notes[i].at);
    return _copy(notes: next, updated: _trim(now));
  }

  /// Delete a note.
  Progress withoutNote(String id, {required DateTime now}) => _copy(notes: [
        for (final n in notes)
          if (n.id != id) n
      ], updated: _trim(now));

  /// The notes pinned to [place] (same unit, row and time through).
  List<ProgressNote> notesAt(WorkPlace place) => [
        for (final n in notes)
          if (n.place.samePlace(place)) n,
      ];

  // --- the file ----------------------------------------------------------------------------------

  Map<String, Object?> toJson() => {
        'format': kProgressFormat,
        'schemaVersion': kProgressSchemaVersion,
        'craft': craft.key,
        if (place != null) 'place': place!.toJson(),
        if (basis != null) 'basis': basis!.toJson(),
        if (started != null) 'started': _timeText(started!),
        if (updated != null) 'updated': _timeText(updated!),
        'log': [for (final e in log) e.toJson()],
        'logDropped': logDropped,
        'notes': [for (final n in notes) n.toJson()],
        'lastNoteNumber': lastNoteNumber,
        'undo': [for (final f in undo) f.toJson()],
        for (final e in extra.entries) e.key: e.value,
      };

  /// The record as the file holds it, kept within [ProgressLimits.maxFileBytes]: when unknown keys
  /// kept from a later build would pass it, the oldest log entries are dropped (and counted), then the
  /// oldest undo frames, until it fits. Returns the text and the record it holds. Throws
  /// [ProgressProblem.tooLarge] when it still does not fit. (Without unknown keys the largest record
  /// the bounds allow is well under the file bound, so nothing is ever dropped for size.)
  ({String text, Progress progress}) encodeFitted() {
    var p = this;
    while (true) {
      final text = jsonEncode(p.toJson());
      if (utf8.encode(text).length <= ProgressLimits.maxFileBytes) {
        return (text: text, progress: p);
      }
      if (p.log.isNotEmpty) {
        p = p._copy(
          log: p.log.sublist(1),
          logDropped: (p.logDropped + 1).clamp(0, ProgressLimits.maxNumber),
        );
      } else if (p.undo.isNotEmpty) {
        p = p._copy(undo: p.undo.sublist(1));
      } else {
        throw const ProgressFileException(ProgressProblem.tooLarge, detail: 'past the file bound');
      }
    }
  }

  /// The version a progress file's first bytes say it has, for a file too large to decode. Ply writes
  /// `format` and `schemaVersion` as the record's first two keys (every version keeps that order), so
  /// they are always in the first [ProgressLimits.versionProbeBytes]. `null` when [head] does not
  /// start that way.
  static int? probeVersion(String head) {
    final m = _versionHead.firstMatch(head);
    return m == null ? null : int.tryParse(m.group(1)!);
  }

  static final RegExp _versionHead = RegExp(
      r'^\s*\{\s*"format"\s*:\s*"ply\.progress"\s*,\s*"schemaVersion"\s*:\s*(\d{1,10})\s*[,}]');

  /// Read a progress file's text for a project of [craft]. Throws a [ProgressFileException]: newer
  /// (from its version keys alone, before anything else is read) or unreadable (anything else wrong,
  /// a bound passed, or another craft's record).
  static Progress decode(String text, {required ProgressCraft craft}) {
    if (text.length > ProgressLimits.maxFileBytes) {
      throw const ProgressFileException(ProgressProblem.unreadable, detail: 'too large');
    }
    final Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException catch (e) {
      throw ProgressFileException(ProgressProblem.unreadable, detail: e.message);
    }
    if (json is! Map<String, dynamic>) {
      throw const ProgressFileException(ProgressProblem.unreadable, detail: 'not an object');
    }
    if (json['format'] != kProgressFormat) {
      throw const ProgressFileException(ProgressProblem.unreadable, detail: 'not a progress file');
    }
    final version = json['schemaVersion'];
    if (version is! int || version < 1) {
      throw const ProgressFileException(ProgressProblem.unreadable, detail: 'bad version');
    }
    // A repeated key decodes to its last value: a record whose first bytes state another version
    // than the one it decodes to is not one Ply wrote, whichever of the two is meant.
    final stated = probeVersion(text.length > ProgressLimits.versionProbeBytes
        ? text.substring(0, ProgressLimits.versionProbeBytes)
        : text);
    if (stated != null && stated != version) {
      throw const ProgressFileException(ProgressProblem.unreadable, detail: 'two schema versions');
    }
    if (version > kProgressSchemaVersion) {
      throw ProgressFileException(ProgressProblem.newerVersion, detail: 'version $version');
    }
    final Map<String, dynamic> map = json;
    try {
      if (map['craft'] != craft.key) throw const FormatException('another craft');
      List<Object?> list(String key, int max) {
        final v = map[key];
        if (v is! List || v.length > max) throw FormatException('bad $key');
        return v;
      }

      final log = [
        for (final e in list('log', ProgressLimits.maxLogEntries)) LogEntry.fromJson(craft, e),
      ];
      final notes = [
        for (final n in list('notes', ProgressLimits.maxNotes)) ProgressNote.fromJson(craft, n),
      ];
      if (notes.fold<int>(0, (n, x) => n + x.text.length) > ProgressLimits.maxNotesTotalChars) {
        throw const FormatException('notes too long');
      }
      if (notes.map((n) => n.id).toSet().length != notes.length) {
        throw const FormatException('note ids repeat');
      }
      final undo = [
        for (final f in list('undo', ProgressLimits.maxUndo)) UndoFrame.fromJson(craft, f),
      ];
      final lastNote = _number(json['lastNoteNumber'], min: 0);
      for (final n in notes) {
        final k = int.tryParse(n.id.startsWith('note-') ? n.id.substring(5) : '');
        if (k != null && k > lastNote) throw const FormatException('note past its counter');
      }
      return Progress(
        craft: craft,
        place: json['place'] == null ? null : WorkPlace.fromJson(craft, json['place']),
        basis: json['basis'] == null ? null : PlaceBasis.fromJson(json['basis']),
        log: List.unmodifiable(log),
        logDropped: _number(json['logDropped'], min: 0),
        notes: List.unmodifiable(notes),
        lastNoteNumber: lastNote,
        undo: List.unmodifiable(undo),
        started: json['started'] == null ? null : _time(json['started']),
        updated: json['updated'] == null ? null : _time(json['updated']),
        extra: Map.unmodifiable({
          for (final e in json.entries)
            if (!_known.contains(e.key)) e.key: e.value,
        }),
      );
    } on FormatException catch (e) {
      throw ProgressFileException(ProgressProblem.unreadable, detail: e.message);
    }
  }
}

// --- helpers ---------------------------------------------------------------------------------------

WorkPlace _storablePlace(WorkPlace p) => p is KnitPlace ? p.storable() : p;

/// A time as stored: UTC, whole milliseconds.
DateTime _trim(DateTime t) =>
    DateTime.fromMillisecondsSinceEpoch(t.millisecondsSinceEpoch, isUtc: true);

String _timeText(DateTime t) => _trim(t).toIso8601String();

/// ISO 8601 in UTC, as [_timeText] writes it: `2026-11-18T10:00:00.000Z` (fractions optional).
final RegExp _isoUtc = RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?Z$');

DateTime _time(Object? v) {
  if (v is! String || v.length > ProgressLimits.maxTimeChars || !_isoUtc.hasMatch(v)) {
    throw const FormatException('bad time');
  }
  final t = DateTime.tryParse(v);
  if (t == null || !t.isUtc) throw const FormatException('bad time');
  return _trim(t);
}

int _number(Object? v, {required int min}) {
  if (v is! int || v < min || v > ProgressLimits.maxNumber) {
    throw const FormatException('bad number');
  }
  return v;
}

Map<String, dynamic> _object(Object? json, Set<String> keys) {
  if (json is! Map<String, dynamic>) throw const FormatException('not an object');
  for (final k in json.keys) {
    if (!keys.contains(k)) throw FormatException('unknown key $k');
  }
  return json;
}
