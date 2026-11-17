import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/models/native_format.dart';
import 'package:ply/src/models/tablet_band.dart';
import 'package:ply/src/rust/tablet_dto.dart';
import 'package:ply/src/state/tablet_editor_state.dart';
import 'package:ply/src/widgets/tablet_widgets.dart';

import 'tablet_test_support.dart';

// The tablet weaving document helpers (M10-02): the presets and card geometry against ADR 0018's
// drawings, the expanded turning, and every edit the editor makes (inserting and deleting cards keeps
// every turn string, pack and event list in step).

void main() {
  group('presets and arrangements (ADR 0018 sections 2 and 4)', () {
    test('Ply home is the first and default preset, listed first, and said to be provisional', () {
      expect(kFirstTabletPreset, TabletPreset.plyHome);
      expect(tabletPresetsInOrder.first, kFirstTabletPreset);
      expect(tabletPresetsInOrder.toSet(), TabletPreset.values.toSet());
      expect(kFirstPresetNote, contains('awaits'));
      expect(blankTabletDocument().cards.every((c) => sameArrangement(c.start, kPlyHome)), isTrue);
    });

    test('the presets and quarter turns match the ADR drawings', () {
      expect(arrangementText(kPlyHome), 'A D C B');
      expect(arrangementText(kPrintedFaceRight), 'D A B C');
      // "Before and after one quarter turn, from Ply home".
      expect(arrangementText(turnedForward(kPlyHome)), 'B A D C');
      expect(arrangementText(turnedBackward(kPlyHome)), 'D C B A');
      // Oracle sampler 2, card 2: Ply home turned one quarter forward.
      expect(arrangementText(presetArrangement(TabletPreset.plyHome, 1)), 'B A D C');
      var a = kPlyHome;
      for (var i = 0; i < 4; i++) {
        a = turnedForward(a);
      }
      expect(sameArrangement(a, kPlyHome), isTrue);
      expect(sameArrangement(turnedBackward(turnedForward(kPrintedFaceRight)), kPrintedFaceRight),
          isTrue);
    });

    test('exactly 8 legal arrangements, each found as a preset and quarter turns', () {
      final all = <String>{};
      for (final p in TabletPreset.values) {
        for (var q = 0; q < 4; q++) {
          final a = presetArrangement(p, q);
          all.add(arrangementText(a));
          expect(presetOf(a), (preset: p, quarters: q));
        }
      }
      expect(all.length, 8);
      // Two diagonal holes on one edge (A at NT, C at FT) is not a position a card can take.
      const bad = TabletArrangementDto(
          nearTop: TabletHoleKind.a,
          farTop: TabletHoleKind.c,
          farBottom: TabletHoleKind.b,
          nearBottom: TabletHoleKind.d);
      expect(isLegalArrangement(bad), isFalse);
      expect(startWords(bad), contains('not a position'));
      expect(startWords(kPlyHome), 'A at the near top');
      expect(startWords(presetArrangement(TabletPreset.printedFaceRight, 2)),
          '2 quarter turns forward from "Printed face to the right, D at the near top"');
    });

    test('twist in words', () {
      expect(twistText(4), '+4');
      expect(twistText(-3), '-3');
      expect(twistText(0), '0');
      expect(twistText(null), 'unknown');
      expect(twistTurnsText(4), '1 full turn');
      expect(twistTurnsText(-9), '2 full turns and 1 quarter turn');
      expect(twistTurnsText(3), '3 quarter turns');
    });
  });

  group('the turning', () {
    test('oracle sampler 2 expands to 9 picks and maps each back to its written pick', () {
      final d = oracleDocument('sampler-2-starts-idles-flip');
      expect(expandedPicks(d), 9);
      expect(firstPickOfSegment(d, 0), 1);
      expect(firstPickOfSegment(d, 1), 3);
      expect(firstPickOfSegment(d, 2), 5);
      expect(placeOfPick(d, 1), (segment: 0, step: 0, repeat: 0));
      expect(placeOfPick(d, 4), (segment: 1, step: 0, repeat: 1));
      expect(placeOfPick(d, 6), (segment: 2, step: 1, repeat: 0));
      expect(placeOfPick(d, 10), isNull);
      expect(placeOfPick(d, 0), isNull);
    });

    test('a turning past the pick limit is capped, not counted to overflow', () {
      final d = copyDoc(blankTabletDocument(cards: 2), turning: [
        TabletSegmentDto(repeat: 4000000000, picks: [uniformPick(2, 'F')])
      ]);
      expect(expandedPicks(d), kMaxTabletPicks + 1);
    });
  });

  group('card edits keep the turning in step', () {
    TabletDocumentDto band() {
      var d = blankTabletDocument(cards: 3);
      d = addPack(d, 'Left');
      d = setCardPack(d, 0, 0);
      d = setCardPack(d, 2, 0);
      d = copyDoc(d, turning: [
        const TabletSegmentDto(repeat: 2, picks: [
          TabletPickDto(
              turns: 'FB?',
              releaseTwist: ['card-2'],
              flip: ['card-3'],
              unsupported: [TabletWordsDto(card: 'card-3', text: 'half turn')]),
        ]),
      ]);
      return d;
    }

    test('inserting a card adds a letter to every pick and keeps packs and events', () {
      final d = insertCard(band(), 1);
      expect(d.cards.length, 4);
      expect(d.cards[1].id, 'card-4');
      // Copies its left neighbour's letter.
      expect(d.turning[0].picks[0].turns, 'FFB?');
      expect(d.packs[0].cards, ['card-1', 'card-3']);
      expect(d.turning[0].picks[0].flip, ['card-3']);
      // Next to a ?, a new card gets F (a ? needs its own words).
      expect(insertCard(band(), 3).turning[0].picks[0].turns, 'FB?F');
    });

    test('removing a card drops its letter and every mention of its id', () {
      final d = removeCard(band(), 2);
      expect(d.turning[0].picks[0].turns, 'FB');
      expect(d.turning[0].picks[0].flip, isEmpty);
      expect(d.turning[0].picks[0].unsupported, isEmpty);
      expect(d.packs[0].cards, ['card-1']);
      final e = removeCard(band(), 1);
      expect(e.turning[0].picks[0].releaseTwist, isEmpty);
      expect(e.turning[0].picks[0].turns, 'F?');
    });

    test('a card is in at most one pack, kept in card order', () {
      var d = addPack(band(), 'Right');
      d = setCardPack(d, 0, 1);
      expect(d.packs[0].cards, ['card-3']);
      expect(d.packs[1].cards, ['card-1']);
      d = setCardPack(d, 2, 1);
      expect(d.packs[1].cards, ['card-1', 'card-3']);
      expect(packOf(d, 2), 1);
      expect(identical(setCardPack(d, 2, 1), d), isTrue);
      expect(packCards(d, 1), [0, 2]);
    });

    test('holes, threading and starts', () {
      var d = setHole(band(), 1, TabletHoleKind.d, 1);
      expect(d.cards[1].d, 1);
      d = setHole(d, 1, TabletHoleKind.a, null);
      expect(d.cards[1].a, isNull);
      expect(identical(setHole(d, 1, TabletHoleKind.a, null), d), isTrue);
      d = setThreading(d, 0, TabletThreadingKind.z);
      expect(d.cards[0].threading, TabletThreadingKind.z);
      d = setAllStarts(d, kPrintedFaceRight);
      expect(d.cards.every((c) => sameArrangement(c.start, kPrintedFaceRight)), isTrue);
      expect(setCardCount(d, 1).cards.length, 1);
      expect(setCardCount(d, 5).turning[0].picks[0].turns.length, 5);
    });

    test('a colour in use cannot be removed; removing another renumbers the rest', () {
      var d = addColor(blankTabletDocument(cards: 2), const TabletColorDto(r: 1, g: 2, b: 3));
      d = setHole(d, 0, TabletHoleKind.a, 2);
      expect(colorInUse(d, 0), isTrue);
      expect(identical(removeColor(d, 0), d), isTrue);
      final e = removeColor(d, 1); // the light colour: unused
      expect(e.palette.length, 2);
      expect(e.cards[0].a, 1); // was colour 3, now colour 2
    });
  });

  group('turning edits', () {
    test('a ? always carries the pattern\'s words, and leaving ? drops them', () {
      var d = blankTabletDocument(cards: 2);
      expect(identical(setTurn(d, 0, 0, 1, '?'), d), isTrue);
      d = setTurn(d, 0, 0, 1, '?', words: 'half turn forward');
      expect(d.turning[0].picks[0].turns, 'F?');
      expect(wordsFor(d, 0, 0, 1), 'half turn forward');
      d = setTurn(d, 0, 0, 1, 'B');
      expect(d.turning[0].picks[0].turns, 'FB');
      expect(d.turning[0].picks[0].unsupported, isEmpty);
    });

    test('flips, releases, notes, picks and segments', () {
      var d = blankTabletDocument(cards: 2);
      d = toggleFlip(d, 0, 0, 1);
      expect(d.turning[0].picks[0].flip, ['card-2']);
      d = toggleFlip(d, 0, 0, 1);
      expect(d.turning[0].picks[0].flip, isEmpty);
      d = toggleRelease(d, 0, 0, 0);
      expect(d.turning[0].picks[0].releaseTwist, ['card-1']);
      d = setNote(d, 0, 0, const TabletNoteDto(kind: TabletNoteKind.brocade, text: 'gold'));
      expect(d.turning[0].picks[0].note?.text, 'gold');
      d = insertPick(d, 0, 1);
      expect(d.turning[0].picks.length, 2);
      // A copy of the turns, without the events.
      expect(d.turning[0].picks[1].releaseTwist, isEmpty);
      d = setRepeat(d, 0, 0);
      expect(d.turning[0].repeat, 1);
      d = addSegment(d, repeat: 3);
      expect(expandedPicks(d), 2 + 3);
      d = removePick(d, 1, 0); // its only pick: the segment goes too
      expect(d.turning.length, 1);
      d = setTurns(d, 0, 1, [0, 1], 'I');
      expect(d.turning[0].picks[1].turns, 'II');
    });
  });

  group('numbers stay within the engine\'s limits', () {
    test('a repeat past the pick limit is over the cap before anything is multiplied', () {
      final d = blankTabletDocument(cards: 2);
      for (final huge in [kMaxTabletPicks + 1, 4294967297, 1 << 40, 1 << 62]) {
        final e = copyDoc(d, turning: [
          TabletSegmentDto(repeat: huge, picks: [uniformPick(2, 'F'), uniformPick(2, 'B')]),
          TabletSegmentDto(repeat: 1, picks: [uniformPick(2, 'F')]),
        ]);
        expect(expandedPicks(e), kMaxTabletPicks + 1, reason: '$huge');
        expect(firstPickOfSegment(e, 1), kMaxTabletPicks + 1);
        expect(placeOfPick(e, 5), (segment: 0, step: 0, repeat: 2));
      }
    });

    test('repeats and thresholds are clamped as they are set', () {
      var d = blankTabletDocument(cards: 2);
      d = setRepeat(d, 0, 4294967297); // would be 1 once cut to 32 bits
      expect(d.turning[0].repeat, kMaxTabletRepeat);
      d = setRepeat(d, 0, -3);
      expect(d.turning[0].repeat, 1);
      expect(addSegment(d, repeat: 1 << 40).turning.last.repeat, kMaxTabletRepeat);
      d = setSettings(
          d, const TabletSettingsDto(twistWarningQuarters: 4294967296, floatWarningPicks: -1));
      expect(d.settings.twistWarningQuarters, kMaxTabletThreshold);
      expect(d.settings.floatWarningPicks, 0);
    });
  });

  test('text inputs stop at the document\'s byte limits', () {
    final limit = Utf8ByteLimit(10);
    const old = TextEditingValue(text: 'abc');
    expect(
        limit.formatEditUpdate(old, const TextEditingValue(text: 'abcdefghij')).text, 'abcdefghij');
    expect(limit.formatEditUpdate(old, const TextEditingValue(text: 'abcdefghijk')).text, 'abc');
    // Bytes, not letters: five two-byte letters fill ten bytes.
    expect(limit.formatEditUpdate(old, const TextEditingValue(text: 'ééééé')).text, 'ééééé');
    expect(limit.formatEditUpdate(old, const TextEditingValue(text: 'éééééé')).text, 'abc');
    final validate = tabletTextLimit(kMaxTabletTextBytes);
    expect(validate('x' * kMaxTabletTextBytes), isNull);
    expect(validate('x' * (kMaxTabletTextBytes + 1)), isNotNull);
  });

  group('the usual start', () {
    test('is the start most cards share, the first one met when they tie', () {
      var d = blankTabletDocument(cards: 4);
      expect(sameArrangement(usualStart(d)!, kPlyHome), isTrue);
      d = setStart(d, 0, kPrintedFaceRight);
      d = setStart(d, 1, kPrintedFaceRight);
      // Two and two: card 1's start is met first.
      expect(sameArrangement(usualStart(d)!, kPrintedFaceRight), isTrue);
      d = setStart(d, 2, kPrintedFaceRight);
      expect(sameArrangement(usualStart(d)!, kPrintedFaceRight), isTrue);
      expect(usualStart(copyDoc(d, cards: const [])), isNull);
    });
  });

  group('editor state', () {
    test('the undo history keeps to its memory budget, newest first', () {
      // A band of about 2 MB: each card inserted rebuilds every pick.
      var doc = blankTabletDocument(cards: 900);
      doc = copyDoc(doc, turning: [
        TabletSegmentDto(repeat: 1, picks: List.generate(2000, (_) => uniformPick(900, 'F'))),
      ]);
      final one = tabletDocBytes(doc);
      expect(one, greaterThan(2000 * 900));
      var s = TabletEditorState(doc: doc, saved: doc, maxBytes: one * 3);
      for (var i = 0; i < 10; i++) {
        s = s.apply((d) => insertCard(d, 0));
      }
      expect(s.undo.length, lessThanOrEqualTo(3));
      expect(s.historyBytes, lessThanOrEqualTo(one * 4), reason: 'the budget, with a margin');
      expect(s.canUndo, isTrue);
      // A small edit's history is not trimmed by the budget.
      var small = TabletEditorState(doc: blankTabletDocument(), maxBytes: one * 3);
      for (var i = 0; i < 30; i++) {
        small = small.apply((d) => setThreading(
            d,
            0,
            d.cards[0].threading == TabletThreadingKind.s
                ? TabletThreadingKind.z
                : TabletThreadingKind.s));
      }
      expect(small.undo.length, 30);
    });

    test('identity-based dirty, undo and redo', () {
      final doc = blankTabletDocument(cards: 2);
      var s = TabletEditorState(doc: doc, saved: doc);
      expect(s.isDirty, isFalse);
      expect(identical(s.apply((d) => d), s), isTrue);
      s = s.apply((d) => setThreading(d, 0, TabletThreadingKind.z));
      expect(s.isDirty, isTrue);
      expect(s.canUndo, isTrue);
      s = s.undone();
      expect(s.isDirty, isFalse);
      s = s.redone();
      expect(s.doc.cards[0].threading, TabletThreadingKind.z);
      final saved = s.markSaved(s.doc);
      expect(saved.isDirty, isFalse);
    });
  });

  test('the .plytab version probe follows the engine\'s detection rule', () {
    expect(plytabSchemaVersion(fixtureText('documents/band-1-threaded-in.plytab')), 1);
    expect(plytabSchemaVersion(fixtureText('documents/invalid/newer-version.plytab')), 2);
    expect(plytabSchemaVersion(fixtureText('documents/invalid/wrong-format-knit.plytab')), isNull);
    expect(plytabSchemaVersion(fixtureText('documents/invalid/bare-band.plytab')), isNull);
    expect(plytabSchemaVersion(fixtureText('documents/invalid/not-json.plytab')), isNull);
    expect(plytabSchemaVersion(fixtureText('documents/invalid/version-zero.plytab')), isNull);
  });
}
