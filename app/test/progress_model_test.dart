import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/json_count.dart';
import 'package:ply/src/data/library_backup.dart' show BackupLimits;
import 'package:ply/src/models/progress.dart';

// The progress record (ADR 0023) as pure data: the file round-trips with unknown keys kept, a newer
// record is refused from its version alone, anything malformed or past a bound is unreadable, the log
// merges a session into one entry and keeps within its bound, Undo reverses each change exactly (also
// after the record was written and read back), notes keep to their limits, and the largest record the
// bounds allow fits the file bound.

final t0 = DateTime.utc(2026, 11, 18, 10);
DateTime at(int minutes) => t0.add(Duration(minutes: minutes));

const p1 = PickPlace(1);
PlaceBasis b(int n) => PlaceBasis(units: 48, prefix: n.toRadixString(16).padLeft(16, '0'));

/// Weave picks [from]..[to] one Next at a time, a minute apart from [minute].
Progress weave(Progress p, int from, int to, {int minute = 0}) {
  for (var k = from; k < to; k++) {
    p = p.moved(
      from: PickPlace(k),
      to: PickPlace(k + 1),
      basis: b(k + 1),
      kind: LogKind.worked,
      now: at(minute + k - from),
    );
  }
  return p;
}

Progress reread(Progress p) => Progress.decode(p.encodeFitted().text, craft: p.craft);

void main() {
  group('the file', () {
    test('a weaving record round-trips, unknown top-level keys kept and written back', () {
      var p = weave(const Progress(craft: ProgressCraft.weaving), 1, 5);
      p = p.withNote(const PickPlace(3), 'Mended a broken end', now: at(9));
      final json = jsonDecode(p.encodeFitted().text) as Map<String, dynamic>;
      expect(json['format'], kProgressFormat);
      expect(json['schemaVersion'], 1);
      expect(json['craft'], 'weaving');
      json['laterKey'] = {'kept': true};
      final back = Progress.decode(jsonEncode(json), craft: ProgressCraft.weaving);
      expect(back.place, const PickPlace(5));
      expect(back.basis, b(5));
      expect(back.log, p.log);
      expect(back.notes, p.notes);
      expect(back.undo.length, 4);
      expect(back.started, at(0));
      expect(back.extra, {
        'laterKey': {'kept': true}
      });
      final again = jsonDecode(back.encodeFitted().text) as Map<String, dynamic>;
      expect(again['laterKey'], {'kept': true});
    });

    test('a knitting place keeps its ids; one outside the id grammar is not stored', () {
      const place = KnitPlace(4, row: 3, repeat: 2, sectionId: 'section-1', stepId: 'step-2');
      final p = const Progress(craft: ProgressCraft.knitting)
          .moved(from: const KnitPlace(0), to: place, basis: b(1), kind: LogKind.jump, now: t0);
      expect(reread(p).place, place);
      final odd = const Progress(craft: ProgressCraft.knitting).moved(
          from: const KnitPlace(0),
          to: const KnitPlace(1, sectionId: 'has a space', stepId: 'step-1', chartRow: 2),
          basis: b(1),
          kind: LogKind.jump,
          now: t0);
      final back = reread(odd).place as KnitPlace;
      expect(back.sectionId, isNull);
      expect(back.stepId, 'step-1');
      expect(back.chartRow, 2);
    });

    test('log entries keep their places whole, ids included', () {
      final p = const Progress(craft: ProgressCraft.knitting).moved(
          from: const KnitPlace(0, sectionId: 'section-1', stepId: 'step-1'),
          to: const KnitPlace(1, sectionId: 'section-1', stepId: 'step-2'),
          basis: b(1),
          kind: LogKind.worked,
          now: t0);
      final json = jsonDecode(p.encodeFitted().text) as Map<String, dynamic>;
      expect((json['log'] as List).single['to'],
          {'unit': 1, 'row': 1, 'repeat': 1, 'section': 'section-1', 'step': 'step-2'});
      expect(reread(p).log.single.to, const KnitPlace(1, sectionId: 'section-1', stepId: 'step-2'));
      expect(json['place'],
          {'unit': 1, 'row': 1, 'repeat': 1, 'section': 'section-1', 'step': 'step-2'});
    });

    test('a record stating one version first and decoding to another is unreadable', () {
      final valid = weave(const Progress(craft: ProgressCraft.weaving), 1, 3).encodeFitted().text;
      final body = valid.substring('{"format":"ply.progress","schemaVersion":1,'.length);
      for (final text in [
        '{"format":"ply.progress","schemaVersion":2,${body.replaceFirst(RegExp(r'}$'), ',"schemaVersion":1}')}',
        '{"format":"ply.progress","schemaVersion":1,${body.replaceFirst(RegExp(r'}$'), ',"schemaVersion":2}')}',
      ]) {
        expect(
            () => Progress.decode(text, craft: ProgressCraft.weaving),
            throwsA(isA<ProgressFileException>()
                .having((e) => e.problem, 'problem', ProgressProblem.unreadable)),
            reason: text.substring(0, 60));
      }
    });

    test('a newer record is refused from its version keys alone', () {
      final text = jsonEncode({'format': kProgressFormat, 'schemaVersion': 2, 'log': 'anything'});
      expect(
          () => Progress.decode(text, craft: ProgressCraft.weaving),
          throwsA(isA<ProgressFileException>()
              .having((e) => e.problem, 'problem', ProgressProblem.newerVersion)
              .having((e) => e.message, 'message', contains('newer version of Ply'))));
    });

    test('anything malformed, foreign or past a bound is unreadable', () {
      final good = jsonDecode(weave(const Progress(craft: ProgressCraft.weaving), 1, 3)
          .withNote(p1, 'x', now: t0)
          .encodeFitted()
          .text) as Map<String, dynamic>;
      Map<String, dynamic> copy() => jsonDecode(jsonEncode(good)) as Map<String, dynamic>;
      final cases = <String, String>{
        'not json': 'not json',
        'a list': '[]',
        'no format': jsonEncode(copy()..remove('format')),
        'another format': jsonEncode(copy()..['format'] = 'ply.knit'),
        'version 0': jsonEncode(copy()..['schemaVersion'] = 0),
        'version as text': jsonEncode(copy()..['schemaVersion'] = '1'),
        'another craft': jsonEncode(copy()..['craft'] = 'knitting'),
        'a negative pick': jsonEncode(copy()..['place'] = {'pick': -1, 'repeat': 1}),
        'pick 0': jsonEncode(copy()..['place'] = {'pick': 0, 'repeat': 1}),
        'past 32 bits': jsonEncode(copy()..['place'] = {'pick': 4294967296, 'repeat': 1}),
        'an unknown key in a place':
            jsonEncode(copy()..['place'] = {'pick': 1, 'repeat': 1, 'x': 1}),
        'a bad fingerprint':
            jsonEncode(copy()..['basis'] = {'units': 3, 'prefix': 'ABCDEF0123456789'}),
        'an unknown log kind': jsonEncode(copy()
          ..['log'] = [
            {...(good['log'] as List).first as Map, 'kind': 'skipped'}
          ]),
        'a bad time': jsonEncode(copy()..['started'] = 'yesterday'),
        'a long time': jsonEncode(copy()..['started'] = '2026-11-18T10:00:00.000Z${' ' * 20}'),
        'a local time': jsonEncode(copy()..['started'] = '2026-11-18T10:00:00.000'),
        'a time with an offset': jsonEncode(copy()..['started'] = '2026-11-18T10:00:00+01:00'),
        'a date alone': jsonEncode(copy()..['started'] = '2026-11-18'),
        'a space for the T': jsonEncode(copy()..['started'] = '2026-11-18 10:00:00Z'),
        'an empty note': jsonEncode(copy()
          ..['notes'] = [
            {...(good['notes'] as List).first as Map, 'text': ''}
          ]),
        'a note past its counter': jsonEncode(copy()..['lastNoteNumber'] = 0),
        'too many log entries': jsonEncode(copy()
          ..['log'] = List.filled(ProgressLimits.maxLogEntries + 1, (good['log'] as List).first)),
        'too many undo frames': jsonEncode(copy()
          ..['undo'] = List.filled(ProgressLimits.maxUndo + 1, (good['undo'] as List).first)),
        'an undo frame without its entry': jsonEncode(copy()
          ..['undo'] = [
            {'place': null, 'basis': null, 'change': 'extended'}
          ]),
      };
      for (final MapEntry(:key, :value) in cases.entries) {
        expect(
            () => Progress.decode(value, craft: ProgressCraft.weaving),
            throwsA(isA<ProgressFileException>()
                .having((e) => e.problem, 'problem', ProgressProblem.unreadable)),
            reason: key);
      }
    });

    test('notes past their limits in a file are unreadable', () {
      Map<String, Object?> note(int i, String text) => {
            'id': 'note-$i',
            'place': {'pick': 1, 'repeat': 1},
            'text': text,
            'at': '2026-11-18T10:00:00.000Z',
          };
      String file(List<Map<String, Object?>> notes) => jsonEncode({
            'format': kProgressFormat,
            'schemaVersion': 1,
            'craft': 'weaving',
            'log': [],
            'logDropped': 0,
            'notes': notes,
            'lastNoteNumber': notes.length,
            'undo': [],
          });
      expect(Progress.decode(file([note(1, 'x' * 500)]), craft: ProgressCraft.weaving).notes,
          hasLength(1));
      expect(() => Progress.decode(file([note(1, 'x' * 501)]), craft: ProgressCraft.weaving),
          throwsA(isA<ProgressFileException>()));
      expect(
          () => Progress.decode(file([for (var i = 1; i <= 21; i++) note(i, 'x' * 500)]),
              craft: ProgressCraft.weaving),
          throwsA(isA<ProgressFileException>()),
          reason: 'past 10,000 characters in all');
      expect(
          () => Progress.decode(file([for (var i = 1; i <= 101; i++) note(i, 'x')]),
              craft: ProgressCraft.weaving),
          throwsA(isA<ProgressFileException>()),
          reason: 'past 100 notes');
    });
  });

  group('the log', () {
    test('a session of Nexts is one entry; a gap, a correction or a jump starts another', () {
      var p = weave(const Progress(craft: ProgressCraft.weaving), 1, 41);
      expect(p.log, hasLength(1));
      expect(p.log.single.kind, LogKind.worked);
      expect(p.log.single.count, 40);
      expect(p.log.single.from, p1);
      expect(p.log.single.to, const PickPlace(41));
      expect(p.log.single.start, at(0));
      expect(p.log.single.end, at(39));
      // After a break longer than the session gap: a new entry.
      p = weave(p, 41, 43, minute: 39 + 31);
      expect(p.log, hasLength(2));
      // Previous, twice: one back entry.
      p = p.moved(
          from: const PickPlace(43),
          to: const PickPlace(42),
          basis: b(42),
          kind: LogKind.back,
          now: at(80));
      p = p.moved(
          from: const PickPlace(42),
          to: const PickPlace(41),
          basis: b(41),
          kind: LogKind.back,
          now: at(81));
      expect(p.log, hasLength(3));
      expect(p.log.last.count, 2);
      // A jump never merges.
      p = p.moved(from: const PickPlace(41), to: p1, basis: b(1), kind: LogKind.jump, now: at(82));
      p = p.moved(from: p1, to: const PickPlace(9), basis: b(9), kind: LogKind.jump, now: at(83));
      expect(p.log, hasLength(5));
    });

    test('the log keeps its newest 400 entries and counts the rest', () {
      var p = const Progress(craft: ProgressCraft.weaving);
      for (var k = 0; k < ProgressLimits.maxLogEntries + 25; k++) {
        p = p.moved(
            from: PickPlace(k + 1),
            to: PickPlace(k + 2),
            basis: b(k),
            kind: LogKind.jump,
            now: at(k));
      }
      expect(p.log, hasLength(ProgressLimits.maxLogEntries));
      expect(p.logDropped, 25);
      expect(p.log.first.to, const PickPlace(27));
      expect(p.started, at(0), reason: 'when tracking began is kept');
      expect(reread(p).logDropped, 25);
    });
  });

  group('undo', () {
    test('each change is reversed exactly, also after the record is written and read back', () {
      final start = weave(const Progress(craft: ProgressCraft.weaving), 1, 5);
      var p = reread(start);
      // A jump far away by mistake...
      p = p.moved(
          from: const PickPlace(5),
          to: const PickPlace(500),
          basis: b(500),
          kind: LogKind.jump,
          now: at(10));
      p = reread(p);
      // ... is undone: the place, its basis and the log as they were.
      p = reread(p.undone(now: at(11))!);
      expect(p.place, const PickPlace(5));
      expect(p.basis, b(5));
      expect(p.log, start.log);
      // Undo the last Next of the merged run: the run shrinks by one.
      p = p.undone(now: at(12))!;
      expect(p.place, const PickPlace(4));
      expect(p.log.single.count, 3);
      expect(p.log.single.to, const PickPlace(4));
      // All the way back: no place stored, nothing logged.
      p = p.undone(now: at(13))!.undone(now: at(13))!.undone(now: at(13))!;
      expect(p.place, isNull);
      expect(p.basis, isNull);
      expect(p.log, isEmpty);
      expect(p.undone(now: at(14)), isNull);
    });

    test('a rebase is undone without touching the log; frames are capped at 50', () {
      var p = weave(const Progress(craft: ProgressCraft.weaving), 1, 3);
      final log = p.log;
      p = p.rebased(place: const PickPlace(3), basis: b(99), now: at(5));
      expect(p.basis, b(99));
      expect(p.log, log);
      p = p.undone(now: at(6))!;
      expect(p.basis, b(3));
      expect(p.log, log);
      p = weave(const Progress(craft: ProgressCraft.weaving), 1, 80);
      expect(p.undo, hasLength(ProgressLimits.maxUndo));
    });

    test('notes are not changes of place', () {
      var p = weave(const Progress(craft: ProgressCraft.weaving), 1, 3);
      p = p.withNote(const PickPlace(3), 'Second ball', now: at(4));
      p = p.undone(now: at(5))!;
      expect(p.notes, hasLength(1));
      expect(p.place, const PickPlace(2));
    });
  });

  group('notes', () {
    test('a knitting note stays with its step when the step moves', () {
      const note = KnitPlace(1, row: 3, sectionId: 'section-1', stepId: 'step-2');
      final p =
          const Progress(craft: ProgressCraft.knitting).withNote(note, 'Second ball', now: t0);
      expect(p.notesAt(const KnitPlace(2, row: 3, sectionId: 'section-1', stepId: 'step-2')),
          hasLength(1),
          reason: 'the same step, now one later');
      expect(
          p.notesAt(const KnitPlace(1, row: 3, sectionId: 'section-1', stepId: 'step-9')), isEmpty,
          reason: 'another step at its old number');
      expect(p.notesAt(const KnitPlace(1, row: 3)), hasLength(1),
          reason: 'a place without ids matches by number');
    });

    test('the note counter never passes the largest number a file holds', () {
      const p = Progress(craft: ProgressCraft.weaving, lastNoteNumber: ProgressLimits.maxNumber);
      expect(
          () => p.withNote(p1, 'One more', now: t0),
          throwsA(isA<ProgressLimitException>()
              .having((e) => e.message, 'message', contains('too many notes'))));
      final almost =
          const Progress(craft: ProgressCraft.weaving, lastNoteNumber: ProgressLimits.maxNumber - 1)
              .withNote(p1, 'Last one', now: t0);
      expect(reread(almost).lastNoteNumber, ProgressLimits.maxNumber);
    });

    test('add, change and delete; ids are never reused; the notes of a place', () {
      var p = const Progress(craft: ProgressCraft.weaving);
      p = p.withNote(const PickPlace(3), '  Second ball  ', now: at(1));
      p = p.withNote(const PickPlace(3, repeat: 2), 'Next time through', now: at(2));
      expect(p.notes.first.text, 'Second ball');
      expect(p.notesAt(const PickPlace(3)).map((n) => n.id), ['note-1']);
      p = p.withNoteText('note-1', 'Third ball', now: at(3));
      expect(p.notes.first.text, 'Third ball');
      p = p.withoutNote('note-2', now: at(4));
      p = p.withNote(p1, 'Again', now: at(5));
      expect(p.notes.map((n) => n.id), ['note-1', 'note-3']);
      expect(reread(p).notes, p.notes);
    });

    test('a note past a limit is refused with a sentence', () {
      const p = Progress(craft: ProgressCraft.weaving);
      expect(() => p.withNote(p1, '   ', now: t0), throwsA(isA<ProgressLimitException>()));
      expect(
          () => p.withNote(p1, 'x' * 501, now: t0),
          throwsA(isA<ProgressLimitException>()
              .having((e) => e.message, 'message', contains('at most 500 characters'))));
      var full = p;
      for (var i = 0; i < 20; i++) {
        full = full.withNote(p1, 'x' * 500, now: t0);
      }
      expect(() => full.withNote(p1, 'y', now: t0),
          throwsA(isA<ProgressLimitException>().having((e) => e.message, 'm', contains('in all'))));
      var many = p;
      for (var i = 0; i < ProgressLimits.maxNotes; i++) {
        many = many.withNote(p1, 'n', now: t0);
      }
      expect(() => many.withNote(p1, 'n', now: t0),
          throwsA(isA<ProgressLimitException>().having((e) => e.message, 'm', contains('100'))));
    });
  });

  group('the bound', () {
    test('the version of a file too large to decode is read from its first bytes', () {
      final text = const Progress(craft: ProgressCraft.weaving).encodeFitted().text;
      expect(Progress.probeVersion(text), 1);
      expect(text.startsWith('{"format":"ply.progress","schemaVersion":1,'), isTrue,
          reason: 'the writer puts the version keys first');
      expect(Progress.probeVersion('{"format": "ply.progress", "schemaVersion": 7, "x": 1'), 7);
      expect(Progress.probeVersion('{"schemaVersion": 7, "format": "ply.progress"}'), isNull);
      expect(Progress.probeVersion('{"format":"ply.knit","schemaVersion":7,'), isNull);
      expect(Progress.probeVersion('not json'), isNull);
    });

    test('the largest record the bounds allow fits the file bound', () {
      // Every count at its largest, every id 64 characters, every note character one that JSON
      // writes as six bytes (a control character).
      final id = 'a' * 64;
      const max = ProgressLimits.maxNumber;
      KnitPlace big() =>
          KnitPlace(max, row: max, repeat: max, sectionId: id, stepId: id, chartRow: max);
      final entry = LogEntry(
          kind: LogKind.worked,
          from: big(),
          to: big(),
          count: max,
          start: DateTime.utc(2026, 11, 18, 10, 0, 0, 123),
          end: DateTime.utc(2026, 11, 18, 10, 0, 0, 456));
      final basis = PlaceBasis(units: max, prefix: 'f' * 16);
      // Notes at their limits: 19 of 500 characters, one of 420 and 80 of one, 10,000 in all.
      final lengths = [
        for (var i = 0; i < 19; i++) ProgressLimits.maxNoteChars,
        420,
        for (var i = 0; i < 80; i++) 1,
      ];
      expect(lengths.fold<int>(0, (a, n) => a + n), ProgressLimits.maxNotesTotalChars);
      final p = Progress(
        craft: ProgressCraft.knitting,
        place: big(),
        basis: basis,
        log: List.filled(ProgressLimits.maxLogEntries, entry),
        logDropped: max,
        notes: [
          for (var i = 0; i < ProgressLimits.maxNotes; i++)
            // Note ids as long as the reader accepts (Ply writes `note-N`).
            ProgressNote(
                id: '${i.toString().padLeft(2, '0')}${'n' * 62}',
                place: big(),
                text: '\u0001' * lengths[i],
                at: t0),
        ],
        lastNoteNumber: max,
        undo: List.filled(ProgressLimits.maxUndo,
            UndoFrame(place: big(), basis: basis, change: LogChange.extended, last: entry)),
        started: t0,
        updated: t0,
      );
      final out = p.encodeFitted();
      final bytes = utf8.encode(out.text).length;
      expect(bytes, lessThan(ProgressLimits.maxFileBytes));
      expect(bytes, greaterThan(150 * 1024), reason: 'the worst case is near the ADR figure');
      expect(out.progress.log, hasLength(ProgressLimits.maxLogEntries), reason: 'nothing dropped');
      // ignore: avoid_print
      print('largest progress record: $bytes bytes (${(bytes / 1024).toStringAsFixed(1)} KiB)');
      expect(Progress.decode(out.text, craft: ProgressCraft.knitting).notes, hasLength(100));
      // What a backup restore measures before it decodes a record (ADR 0023, section 9).
      final shape = measureJson(utf8.encode(out.text));
      // ignore: avoid_print
      print('largest progress record: ${shape.values} JSON values, nested ${shape.depth} deep');
      const limits = BackupLimits();
      expect(shape.values * 4, lessThan(limits.maxProgressValues));
      expect(shape.depth, 5);
      expect(bytes, lessThanOrEqualTo(limits.maxProgressBytes));
    });

    test('unknown keys that would pass the bound drop the oldest log entries, counted', () {
      final p = weave(const Progress(craft: ProgressCraft.weaving), 1, 3);
      final json = jsonDecode(p.encodeFitted().text) as Map<String, dynamic>;
      json['later'] = 'z' * (ProgressLimits.maxFileBytes - 8000);
      var read = Progress.decode(jsonEncode(json), craft: ProgressCraft.weaving);
      for (var k = 0; k < 40; k++) {
        read = read.moved(
            from: PickPlace(k + 1),
            to: PickPlace(k + 100),
            basis: b(k),
            kind: LogKind.jump,
            now: at(k));
      }
      final out = read.encodeFitted();
      expect(utf8.encode(out.text).length, lessThanOrEqualTo(ProgressLimits.maxFileBytes));
      expect(out.progress.logDropped, greaterThan(0));
      expect(out.progress.log.length + out.progress.logDropped, 41);
      expect(out.progress.extra['later'], json['later']);
      // With no log left to drop, the oldest undo frames go.
      json['later'] = 'z' * (ProgressLimits.maxFileBytes - 3000);
      json['log'] = [];
      var frames = Progress.decode(jsonEncode(json), craft: ProgressCraft.weaving);
      for (var k = 0; k < 45; k++) {
        frames = frames.rebased(place: const PickPlace(3), basis: b(k), now: at(k));
      }
      final fitted = frames.encodeFitted();
      expect(utf8.encode(fitted.text).length, lessThanOrEqualTo(ProgressLimits.maxFileBytes));
      expect(fitted.progress.undo.length, lessThan(frames.undo.length));
      expect(fitted.progress.basis, b(44), reason: 'the place itself is never dropped');
      final huge = Progress(
          craft: ProgressCraft.weaving, extra: {'later': 'z' * ProgressLimits.maxFileBytes});
      expect(
          () => huge.encodeFitted(),
          throwsA(isA<ProgressFileException>()
              .having((e) => e.problem, 'p', ProgressProblem.tooLarge)));
    });
  });
}
