import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/json_count.dart';
import 'package:ply/src/data/library_backup.dart' show BackupLimits;
import 'package:ply/src/models/progress.dart';

// The progress record (ADR 0023) as pure data: the file round-trips with unknown keys kept, a newer
// record is refused from its version alone, anything malformed or past a bound is unreadable, the log
// merges a session into one entry and keeps within its bound, Undo reverses each change exactly (also
// after the record was written and read back), notes keep to their limits, the place's label is
// kept only for its own place and dropped (never unreadable) when it is not well formed, and the
// largest record the bounds allow fits the file bound.

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

/// A stand-in for the knitting tracker's words for a place.
String? cuffWords(WorkPlace w, int? units) =>
    w is KnitPlace ? 'Section 1: Cuff, step ${w.unit + 1}, row ${w.row}' : null;

const cuff = KnitPlace(2, row: 5, sectionId: 'section-1', stepId: 'step-3');

/// A knitting record moved to [cuff] with [label] as its words.
Progress atCuff({PlaceWords? label = cuffWords}) =>
    const Progress(craft: ProgressCraft.knitting).moved(
        from: const KnitPlace(0),
        to: cuff,
        basis: b(3),
        kind: LogKind.worked,
        now: t0,
        label: label);

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

    test('a tablet weaving record holds a pick place like weaving\'s, under its own craft', () {
      final p = weave(const Progress(craft: ProgressCraft.tabletWeaving), 1, 4);
      final json = jsonDecode(p.encodeFitted().text) as Map<String, dynamic>;
      expect(json['craft'], 'tablet_weaving');
      expect(json['place'], {'pick': 4, 'repeat': 1});
      expect(reread(p).place, const PickPlace(4));
      expect(() => Progress.decode(p.encodeFitted().text, craft: ProgressCraft.weaving),
          throwsA(isA<ProgressFileException>()));
    });

    test('a nalbinding place names its step by id; one outside the id grammar is not stored', () {
      const place = NalbindPlace(2, stepId: 'segment-3');
      final p = const Progress(craft: ProgressCraft.nalbinding).moved(
          from: const NalbindPlace(0, stepId: 'segment-1'),
          to: place,
          basis: b(3),
          kind: LogKind.jump,
          now: t0);
      final json = jsonDecode(p.encodeFitted().text) as Map<String, dynamic>;
      expect(json['craft'], 'nalbinding');
      expect(json['place'], {'unit': 2, 'step': 'segment-3'});
      expect(reread(p).place, place);
      expect(reread(p).log.single.from, const NalbindPlace(0, stepId: 'segment-1'));
      final odd = const Progress(craft: ProgressCraft.nalbinding).moved(
          from: const NalbindPlace(0),
          to: const NalbindPlace(1, stepId: 'has a space'),
          basis: b(1),
          kind: LogKind.jump,
          now: t0);
      expect(reread(odd).place, const NalbindPlace(1));
      String withPlace(Object place) => jsonEncode({
            ...jsonDecode(p.encodeFitted().text) as Map<String, dynamic>,
            'place': place,
          });
      for (final bad in [
        {'step': 'segment-3'},
        {'unit': -1, 'step': 'segment-3'},
        {'unit': 1, 'step': 7},
        {'unit': 1, 'step': ''},
        {'unit': 1, 'step': 'segment-3', 'row': 2},
      ]) {
        expect(() => Progress.decode(withPlace(bad), craft: ProgressCraft.nalbinding),
            throwsA(isA<ProgressFileException>()),
            reason: '$bad');
      }
    });

    test('a nalbinding note stays with its step, wherever the step is now', () {
      final p = const Progress(craft: ProgressCraft.nalbinding)
          .withNote(const NalbindPlace(2, stepId: 'segment-3'), 'Thumb gap here', now: t0);
      expect(p.notesAt(const NalbindPlace(4, stepId: 'segment-3')), hasLength(1));
      expect(p.notesAt(const NalbindPlace(2, stepId: 'segment-5')), isEmpty);
      expect(p.notesAt(const NalbindPlace(2)), hasLength(1), reason: 'by number without an id');
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

  group('the label', () {
    /// The label's words and place, without its stamp.
    (String, WorkPlace)? said(Progress p) =>
        p.label == null ? null : (p.label!.text, p.label!.place);

    test('a label is written with its place and read back; a record without one reads as before',
        () {
      final p = atCuff();
      final json = jsonDecode(p.encodeFitted().text) as Map<String, dynamic>;
      expect(json['label'], {
        'text': 'Section 1: Cuff, step 3, row 5',
        'place': {'unit': 2, 'row': 5, 'repeat': 1, 'section': 'section-1', 'step': 'step-3'},
        'updated': json['updated'],
      });
      final back = reread(p);
      expect(back.label,
          PlaceLabel(text: 'Section 1: Cuff, step 3, row 5', place: cuff, updated: t0));
      expect(back.extra, isEmpty, reason: 'a known key, never kept as an unknown one');
      expect(back.encodeFitted().text, p.encodeFitted().text, reason: 'written back as read');
      // Without words no key is written, and a record without the key (every earlier build's)
      // reads as before and is written back exactly.
      final text = atCuff(label: null).encodeFitted().text;
      expect((jsonDecode(text) as Map).containsKey('label'), isFalse);
      final older = Progress.decode(text, craft: ProgressCraft.knitting);
      expect(older.label, isNull);
      expect(older.place, cuff);
      expect(older.encodeFitted().text, text);
    });

    test('a label not well formed, or not of this place and last change, is dropped as if absent',
        () {
      final good = jsonDecode(atCuff().encodeFitted().text) as Map<String, dynamic>;
      final place = good['place'] as Map<String, dynamic>;
      final stamp = good['updated'] as String;
      Map<String, Object?> label(Object? text, {Object? at, Object? updated}) => {
            'text': text,
            'place': at ?? place,
            'updated': updated ?? stamp,
          };
      final cases = <String, Object?>{
        'text alone': 'Section 1: Cuff',
        'a list': [],
        'no text': {'place': place, 'updated': stamp},
        'text that is not a string': label(7),
        'empty text': label(''),
        'blank text': label('   '),
        'text past the cap': label('x' * (ProgressLimits.maxLabelChars + 1)),
        'half of a symbol at the end': label('Cuff \ud83e'),
        'half of a symbol before a letter': label('Cuff \ud83ex'),
        'the other half alone': label('Cuff \udd76'),
        'no place': {'text': 'Cuff', 'updated': stamp},
        'no stamp': {'text': 'Cuff', 'place': place},
        'a stamp that is not a time': label('Cuff', updated: 'yesterday'),
        'an unknown key': {...label('Cuff'), 'more': 1},
        'another craft\'s place': label('Pick 3', at: {'pick': 3, 'repeat': 1}),
        'a place past a bound': label('Cuff', at: {...place, 'row': -1}),
        'an id outside the grammar': label('Cuff', at: {...place, 'step': 'has a space'}),
        // A build from before the key keeps it verbatim and writes it back as it moves the place.
        'the words of another place': label('Section 1: Cuff, step 1',
            at: {'unit': 0, 'row': 1, 'repeat': 1, 'section': 'section-1', 'step': 'step-1'}),
        'the same spot without its ids': label('Cuff', at: {'unit': 2, 'row': 5, 'repeat': 1}),
        // ... and back at the same place (or after a note), with its own last change.
        'another last change': label('Section 1: Ribbing, step 3, row 5',
            updated: '2026-11-18T11:00:00.000Z'),
      };
      for (final MapEntry(:key, :value) in cases.entries) {
        final text = jsonEncode({...good, 'label': value});
        final p = Progress.decode(text, craft: ProgressCraft.knitting);
        expect(p.label, isNull, reason: key);
        expect((p.place, p.log.length, p.undo.length), (cuff, 1, 1),
            reason: '$key: the rest reads');
        expect(p.extra, isEmpty, reason: key);
        expect((jsonDecode(p.encodeFitted().text) as Map).containsKey('label'), isFalse,
            reason: '$key: not written back');
      }
      // A whole symbol, and text at the cap, are kept; a record with no place keeps no label.
      for (final text in ['Cuff \u{1F9F6}', 'x' * ProgressLimits.maxLabelChars]) {
        expect(
            Progress.decode(jsonEncode({...good, 'label': label(text)}),
                    craft: ProgressCraft.knitting)
                .label
                ?.text,
            text);
      }
      final noPlace = Map.of(good)
        ..remove('place')
        ..remove('basis')
        ..['label'] = label('Cuff');
      expect(Progress.decode(jsonEncode(noPlace), craft: ProgressCraft.knitting).label, isNull);
    });

    test('an earlier build\'s move away and back makes the label old', () {
      // That build keeps `label` as an unknown key and writes it back unchanged; every move and
      // note change it makes changes `updated`. Here it moved on and back, after the section was
      // renamed: the place is the same, the words are not.
      final json = jsonDecode(atCuff().encodeFitted().text) as Map<String, dynamic>;
      final earlier = {...json, 'updated': '2026-11-18T12:00:00.000Z'};
      final p = Progress.decode(jsonEncode(earlier), craft: ProgressCraft.knitting);
      expect(p.place, cuff);
      expect(p.label, isNull);
    });

    test('any craft\'s record may hold one for its place; a move without words drops it', () {
      final json = jsonDecode(weave(const Progress(craft: ProgressCraft.weaving), 1, 3)
          .encodeFitted()
          .text) as Map<String, dynamic>;
      json['label'] = {
        'text': 'Pick 3, the blue stripe',
        'place': {'pick': 3, 'repeat': 1},
        'updated': json['updated'],
      };
      final p = Progress.decode(jsonEncode(json), craft: ProgressCraft.weaving);
      expect(said(p), ('Pick 3, the blue stripe', const PickPlace(3)));
      final moved = p.moved(
          from: const PickPlace(3),
          to: const PickPlace(4),
          basis: b(4),
          kind: LogKind.worked,
          now: at(3));
      expect(moved.label, isNull);
      expect((jsonDecode(moved.encodeFitted().text) as Map).containsKey('label'), isFalse);
    });

    test('every change of place writes fresh words or none; other changes keep and stamp them',
        () {
      var p = atCuff();
      expect(said(p), ('Section 1: Cuff, step 3, row 5', cuff));
      // Notes do not move the place: the words stay, stamped with each change.
      for (final change in <Progress Function(Progress)>[
        (p) => p.withNote(cuff, 'Second ball', now: at(1)),
        (p) => p.withNoteText('note-1', 'Third ball', now: at(2)),
        (p) => p.withoutNote('note-1', now: at(3)),
      ]) {
        p = change(p);
        expect(said(p), ('Section 1: Cuff, step 3, row 5', cuff));
        expect(p.label!.updated, p.updated);
        expect(reread(p).label, p.label, reason: 'written with the record\'s new last change');
      }
      // A move with words: fresh ones. Without (another craft's tracker): none.
      const next = KnitPlace(2, row: 6, sectionId: 'section-1', stepId: 'step-3');
      p = p.moved(
          from: cuff, to: next, basis: b(3), kind: LogKind.worked, now: at(4), label: cuffWords);
      expect(p.label,
          PlaceLabel(text: 'Section 1: Cuff, step 3, row 6', place: next, updated: at(4)));
      expect(p.moved(from: next, to: cuff, basis: b(3), kind: LogKind.back, now: at(5)).label,
          isNull);
      // A place accepted where it is: the pattern changed under it, so its words are given again.
      final rebased = p.rebased(
          place: next,
          basis: b(9),
          now: at(6),
          label: (_, __) => 'Section 1: Ribbing, step 3, row 6');
      expect(said(rebased), ('Section 1: Ribbing, step 3, row 6', next));
      expect(p.rebased(place: next, basis: b(9), now: at(6)).label, isNull,
          reason: 'the old words may not hold');
      // Undo frames hold no words: the words for the place undone to, or none.
      expect(said(rebased.undone(now: at(7), label: cuffWords)!),
          ('Section 1: Cuff, step 3, row 6', next));
      expect(rebased.undone(now: at(7))!.label, isNull);
      expect(atCuff().undone(now: at(7), label: cuffWords)!.label, isNull, reason: 'no place now');
      // No words, blank ones or broken ones: no label. Long ones are shortened to fit.
      Progress movedWith(PlaceWords words) => p.moved(
          from: next, to: cuff, basis: b(3), kind: LogKind.jump, now: at(8), label: words);
      expect(movedWith((_, __) => null).label, isNull);
      expect(movedWith((_, __) => ' \n ').label, isNull);
      expect(movedWith((_, __) => 'Cuff \ud83e').label, isNull);
      final long = movedWith((_, __) => 'Section 1: ${'Long name ' * 30}').label!;
      expect(long.text.length, lessThanOrEqualTo(ProgressLimits.maxLabelChars));
      expect(long.text, endsWith('…'));
      expect(reread(movedWith((_, __) => 'Section 1: ${'Long name ' * 30}')).label, long);
      // The label is for the place as stored: an id outside the grammar is left out of both.
      final odd = const Progress(craft: ProgressCraft.knitting).moved(
          from: const KnitPlace(0),
          to: const KnitPlace(1, sectionId: 'has a space', stepId: 'step-1'),
          basis: b(1),
          kind: LogKind.jump,
          now: t0,
          label: (_, __) => 'Step 2');
      expect(odd.label?.place, const KnitPlace(1, stepId: 'step-1'));
      expect(reread(odd).label?.text, 'Step 2');
    });

    test('the words are asked with the units of the basis stored with the place, on every path',
        () {
      final asked = <(WorkPlace, int?)>[];
      String? words(WorkPlace w, int? units) {
        asked.add((w, units));
        return 'Row ${(w as KnitPlace).unit + 1} of $units';
      }

      PlaceBasis of(int units) => PlaceBasis(units: units, prefix: 'f' * 16);
      // Row 5 of a chart of 24; rows were added at the end; Next stores row 6 against 30.
      var p = const Progress(craft: ProgressCraft.knitting).moved(
          from: const KnitPlace(0),
          to: const KnitPlace(4),
          basis: of(24),
          kind: LogKind.jump,
          now: t0,
          label: words);
      p = p.moved(
          from: const KnitPlace(4),
          to: const KnitPlace(5),
          basis: of(30),
          kind: LogKind.worked,
          now: at(1),
          label: words);
      expect(p.label?.text, 'Row 6 of 30');
      // Undo puts back row 5 with the basis of 24: its words say 24, as the tile counts.
      final undone = p.undone(now: at(2), label: words)!;
      expect(undone.basis?.units, 24);
      expect(undone.label?.text, 'Row 5 of 24');
      final rebased = p.rebased(place: const KnitPlace(5), basis: of(31), now: at(3), label: words);
      expect(rebased.label?.text, 'Row 6 of 31');
      expect(asked.map((a) => a.$2), [24, 30, 24, 31]);
    });

    test('a note with half of a symbol is refused, and a record holding one is unreadable', () {
      const p = Progress(craft: ProgressCraft.weaving);
      expect(
          () => p.withNote(p1, 'Second ball \ud83e', now: t0),
          throwsA(isA<ProgressLimitException>()
              .having((e) => e.message, 'message', contains('broken symbol'))));
      final kept = p.withNote(p1, 'Second ball \u{1F9F6}', now: t0);
      expect(
          () => kept.withNoteText('note-1', '\udd76 Third ball', now: t0),
          throwsA(isA<ProgressLimitException>()));
      expect(reread(kept).notes.single.text, 'Second ball \u{1F9F6}');
      final json = jsonDecode(kept.encodeFitted().text) as Map<String, dynamic>;
      (json['notes'] as List).first['text'] = 'Second ball \ud83e';
      expect(
          () => Progress.decode(jsonEncode(json), craft: ProgressCraft.weaving),
          throwsA(isA<ProgressFileException>()
              .having((e) => e.problem, 'problem', ProgressProblem.unreadable)));
    });

    test('words past the cap are shortened at a word, with an ellipsis, never inside a character',
        () {
      expect(PlaceLabel.fit('Section 1: Cuff, step 2'), 'Section 1: Cuff, step 2');
      expect(PlaceLabel.fit('  Section 1:\n Cuff \t step 2 '), 'Section 1: Cuff step 2');
      final long = 'Section 1: ${'Long name ' * 40}';
      final words = PlaceLabel.fit(long);
      expect(words.length, lessThanOrEqualTo(ProgressLimits.maxLabelChars));
      expect(words, endsWith('…'));
      expect(long.startsWith('${words.substring(0, words.length - 1)} '), isTrue,
          reason: 'cut after a whole word: $words');
      // One long word: cut between characters.
      expect(PlaceLabel.fit('a' * 300), '${'a' * 199}…');
      // At a word boundary already: nothing more is cut.
      expect(PlaceLabel.fit('${'a' * 199} ${'b' * 10}'), '${'a' * 199}…');
      // No comma left hanging before the ellipsis.
      expect(PlaceLabel.fit('Cuff, ribbing and more', max: 12), 'Cuff…');
      // Never inside a character as a reader sees it: a yarn ball (two UTF-16 units), a flag
      // (two symbols of two units), a family joined from three people, a letter and its accent.
      for (final (keep, character) in [
        (198, '\u{1F9F6}'),
        (197, '\u{1F1F3}\u{1F1F4}'),
        (195, '\u{1F468}‍\u{1F469}‍\u{1F467}'),
        (198, 'é'),
      ]) {
        expect(PlaceLabel.fit('${'a' * keep}$character${'b' * 10}'), '${'a' * keep}…',
            reason: character);
      }
      // Nothing readable left once shortened: no words.
      expect(PlaceLabel.fit('(' * 300), '');
      expect(PlaceLabel.fit('(((', max: 200), '(((', reason: 'what fits is never changed');
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
      // Every count at its largest, every id 64 characters, every note and label character one that
      // JSON writes as six bytes (a control character).
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
        label: PlaceLabel(text: '\u0001' * ProgressLimits.maxLabelChars, place: big(), updated: t0),
      );
      final out = p.encodeFitted();
      final bytes = utf8.encode(out.text).length;
      expect(bytes, lessThan(ProgressLimits.maxFileBytes));
      expect(bytes, greaterThan(150 * 1024), reason: 'the worst case is near the ADR figure');
      expect(out.progress.log, hasLength(ProgressLimits.maxLogEntries), reason: 'nothing dropped');
      // ignore: avoid_print
      print('largest progress record: $bytes bytes (${(bytes / 1024).toStringAsFixed(1)} KiB)');
      final back = Progress.decode(out.text, craft: ProgressCraft.knitting);
      expect(back.notes, hasLength(100));
      expect(back.label, p.label, reason: 'a label at its bound is kept');
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
