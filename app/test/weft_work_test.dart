import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/draft_repository.dart';
import 'package:ply/src/models/double_weave_layers.dart';
import 'package:ply/src/models/draft_doc.dart';
import 'package:ply/src/models/editor_state.dart';
import 'package:ply/src/models/treadling_entries.dart';
import 'package:ply/src/models/use_tabby.dart';
import 'package:ply/src/models/weft_work.dart';
import 'package:ply/src/rust/dto.dart' show ShuttleSideKind;

import 'pick_roles_support.dart';

// Host coverage for shot groups, shuttles, and strands in the editor model (M8-06, ADR 0009): one
// representation for "nothing recorded", groups that stay on the right picks through every editor
// operation that inserts, removes, or re-sheds picks (and undo), the derived pass directions (the Dart
// twin of the engine's `Draft::pass_starts`, on the same cases as its Rust tests), the DTO mapping
// (the save and reopen path), the structure overlay, the layer split, and Use tabby.

const L = ShuttleSide.left;
const R = ShuttleSide.right;

/// Six picks on a straight 4-shaft draft: treadles 1, 1, 1, 2, 3, 3 (the engine's `worked_fixture`).
/// Picks 1-2 and 5-6 are double shots; shuttle 1 (from the right) weaves every pick except pick 4
/// (shuttle 2, no starting side); strands 1, 1, 2, 1, 1, 3.
DraftDoc worked() => DraftDoc(
      name: 'w',
      shafts: 4,
      treadles: 4,
      shed: Shed.rising,
      unit: MeasureUnit.inches,
      threading: const [
        [1],
        [2],
        [3],
        [4],
      ],
      drive: DraftTreadled(tieup: const [
        [1],
        [2],
        [3],
        [4],
      ], treadling: const [
        [1],
        [1],
        [1],
        [2],
        [3],
        [3],
      ]),
      palette: const [DraftColor(r: 255, g: 255, b: 255), DraftColor(r: 0, g: 0, b: 0)],
      warpColors: const [0, 0, 0, 0],
      weftColors: const [1, 1, 0, 1, 0, 1],
      notes: '',
      pickShuttles: const [1, 1, 1, 2, 1, 1],
      pickStrands: const [1, 1, 2, 1, 1, 3],
      shotGroups: const [ShotGroup(0, 2), ShotGroup(4, 2)],
      shuttleStarts: const {1: R},
    );

List<int> treadles(DraftDoc d) => [for (final r in d.drive.rows) r.isEmpty ? 0 : r.single];

void main() {
  group('DraftDoc weft work', () {
    test('nothing recorded has one representation', () {
      final d = worked().copyWith(
        pickShuttles: const [null, null, null, null, null, null],
        pickStrands: const [1, 1, 1, 1, 1, 1],
        shotGroups: const [],
        shuttleStarts: const {},
      );
      expect(d.pickShuttles, isEmpty);
      expect(d.pickStrands, isEmpty);
      expect(d.hasWeftWork, isFalse);
      expect(d.shuttleAt(0), isNull);
      expect(d.strandsAt(0), 1);
      expect(worked().hasWeftWork, isTrue);
      expect(worked().shuttleAt(3), 2);
      expect(worked().strandsAt(5), 3);
      expect(worked().strandsAt(99), 1, reason: 'past the picks is one strand');
      expect(worked().shotGroupAt(1), const ShotGroup(0, 2));
      expect(worked().shotGroupAt(2), isNull);
    });

    test('weft work is part of value equality and hash, sorted, and frozen', () {
      expect(worked(), worked());
      expect(worked().hashCode, worked().hashCode);
      final reordered = worked().copyWith(shotGroups: const [ShotGroup(4, 2), ShotGroup(0, 2)]);
      expect(reordered, worked(), reason: 'groups are sealed in pick order');
      expect(worked(), isNot(worked().copyWith(shuttleStarts: const {1: L})));
      expect(worked(), isNot(worked().copyWith(pickStrands: const [1, 1, 2, 1, 1, 2])));
      expect(() => worked().pickShuttles.add(3), throwsUnsupportedError);
      expect(() => worked().shotGroups.add(const ShotGroup(2, 2)), throwsUnsupportedError);
      expect(() => worked().shuttleStarts[2] = L, throwsUnsupportedError);
    });

    test('the DTO mapping (the save and reopen path) carries every value', () {
      final repo = DraftRepository();
      final doc = worked().copyWith(shuttleStarts: const {1: R, 2: L});
      final dto = repo.toDto(doc);
      expect(dto.pickShuttles, [1, 1, 1, 2, 1, 1]);
      expect(dto.pickStrands, [1, 1, 2, 1, 1, 3]);
      expect([for (final g in dto.shotGroups) (g.start, g.picks)], [(0, 2), (4, 2)]);
      expect([for (final s in dto.shuttleStarts) (s.shuttle, s.side)],
          [(1, ShuttleSideKind.right), (2, ShuttleSideKind.left)]);
      expect(repo.fromDto(dto), doc);
      // Unknown shuttles cross as 0 and come back unknown.
      final partial = doc.copyWith(pickShuttles: const [null, 3, null, null, null, null]);
      expect(repo.toDto(partial).pickShuttles, [0, 3, 0, 0, 0, 0]);
      expect(repo.fromDto(repo.toDto(partial)), partial);
      // Nothing recorded crosses as empty lists.
      final blank = repo.toDto(DraftDoc.blank());
      expect(blank.pickShuttles, isEmpty);
      expect(blank.shotGroups, isEmpty);
      expect(blank.shuttleStarts, isEmpty);
    });
  });

  group('pass directions (twin of the engine cases)', () {
    test('one shuttle alternates and reverses inside a double shot', () {
      final d = worked().copyWith(pickShuttles: const [1, 1, 1, 1, 1, 1]);
      expect(passStarts(d), [R, L, R, L, R, L]);
      expect(passStarts(d.copyWith(shuttleStarts: const {1: L})).take(2), [L, R]);
    });

    test('two shuttles each keep their own rhythm', () {
      final d = worked().copyWith(shuttleStarts: const {1: R, 2: L});
      expect(passStarts(d), [R, L, R, L, L, R]);
      final alternating =
          d.copyWith(shotGroups: const [], pickShuttles: const [1, 2, 1, 2, 1, 2]);
      expect(passStarts(alternating), [R, L, L, R, R, L]);
      // A double shot with two shuttles: each starts from its own side.
      expect(passStarts(alternating.copyWith(shotGroups: const [ShotGroup(0, 2)])).take(2), [R, L]);
    });

    test('unknown shuttles and sides leave directions unknown', () {
      expect(passStarts(worked()), [R, L, R, null, L, R],
          reason: 'shuttle 2 has no side; shuttle 1 keeps counting');
      final gap = worked().copyWith(pickShuttles: const [1, 1, null, 2, 1, 1]);
      expect(passStarts(gap), [R, L, null, null, null, null],
          reason: 'after an unknown shuttle no pass can be counted');
      expect(passStarts(worked().copyWith(pickShuttles: const [])), List.filled(6, null));
      expect(directionNotes(gap), [
        'Pick 3 has no shuttle, so Ply cannot tell the direction of pick 3 or of any pick after it.',
        'Shuttle 2 has no starting side, so its picks show no direction.',
      ]);
      expect(directionNotes(worked().copyWith(shuttleStarts: const {1: R, 2: L})), isEmpty);
      expect(directionNotes(worked().copyWith(pickShuttles: const [])), isEmpty);
    });

    test('average strands per pick', () {
      expect(meanStrands(worked()), 9 / 6);
      expect(meanStrands(worked().copyWith(pickStrands: const [])), 1.0);
      expect(meanStrands(DraftDoc.blank()), 1.0);
    });
  });

  group('sound shot groups (twin of the engine rule)', () {
    test('split at shed changes, cut at the last pick, overlaps dropped', () {
      final d = worked();
      expect(soundShotGroups(d, const [ShotGroup(0, 4)]), const [ShotGroup(0, 3)]);
      expect(
          soundShotGroups(d, const [
            ShotGroup(4, 2),
            ShotGroup(1, 2),
            ShotGroup(0, 2),
            ShotGroup(3, 1),
            ShotGroup(5, 4),
          ]),
          const [ShotGroup(0, 2), ShotGroup(4, 2)]);
      expect(withSoundShotGroups(d), same(d), reason: 'already sound: unchanged');
    });

    test('insert and remove rules', () {
      const g = [ShotGroup(2, 3)]; // picks 3 to 5
      expect(shotGroupsAfterInsert(g, 0, 2), const [ShotGroup(4, 3)], reason: 'before: shifts');
      expect(shotGroupsAfterInsert(g, 2, 1), const [ShotGroup(3, 3)], reason: 'at its start');
      expect(shotGroupsAfterInsert(g, 3, 1), const [ShotGroup(2, 4)], reason: 'inside: grows');
      expect(shotGroupsAfterInsert(g, 5, 1), g, reason: 'after: unchanged');
      expect(shotGroupsAfterInsert(g, 5, 1, joinGroupEndingAt: true), const [ShotGroup(2, 4)]);
      expect(shotGroupsAfterRemove(g, 0, 1), const [ShotGroup(1, 3)], reason: 'before: shifts');
      expect(shotGroupsAfterRemove(g, 3, 1), const [ShotGroup(2, 2)], reason: 'a member');
      expect(shotGroupsAfterRemove(g, 1, 3), isEmpty, reason: 'one member left: dissolved');
      expect(shotGroupsAfterRemove(g, 4, 5), const [ShotGroup(2, 2)], reason: 'its tail');
      expect(shotGroupsAfterRemove(g, 5, 2), g, reason: 'after: unchanged');
    });
  });

  group('Book view rows', () {
    test('a group is its own row; consecutive identical sheds without a group stay one run', () {
      final es = EditorState(draft: worked()).entries;
      expect([for (final e in es) (e.startPick, e.count, e.grouped)], [
        (0, 2, true),
        (2, 1, false),
        (3, 1, false),
        (4, 2, true),
      ]);
      final ungrouped = EditorState(draft: worked().copyWith(shotGroups: const [])).entries;
      expect([for (final e in ungrouped) (e.startPick, e.count, e.grouped)],
          [(0, 3, false), (3, 1, false), (4, 2, false)]);
      // A group inside a longer run splits it.
      final rows = [
        for (var p = 0; p < 5; p++) [1]
      ];
      expect([for (final e in treadlingEntries(rows, const [ShotGroup(1, 2)])) (e.startPick, e.count)],
          [(0, 1), (1, 2), (3, 2)]);
    });
  });

  group('editor edits keep groups, shuttles, and strands on the right picks', () {
    test('group and ungroup a run, as explicit edits', () {
      final s = EditorState(draft: worked().copyWith(shotGroups: const []));
      final g = s.withShotGroup(0, 3);
      expect(g.draft.shotGroups, const [ShotGroup(0, 3)]);
      expect(g.withShotGroup(0, 3), same(g), reason: 'already grouped');
      expect(g.withoutShotGroup(0).draft.shotGroups, isEmpty);
      expect(g.withoutShotGroup(4), same(g), reason: 'no group starts there');
      expect(() => s.withShotGroup(2, 2), throwsStateError, reason: 'picks 3 and 4 differ');
      expect(() => s.withShotGroup(5, 2), throwsRangeError, reason: 'past the last pick');
      expect(() => s.withShotGroup(1, 1), throwsRangeError, reason: 'one pick is not a group');
      expect(() => g.withShotGroup(1, 2), throwsStateError, reason: 'overlaps');
    });

    test('a count grow on a group row adds passes; on a plain row it adds separate picks', () {
      final s = EditorState(draft: worked());
      final grown = s.setEntryCount(0, 3); // the double shot at picks 1-2 -> triple shot
      expect(treadles(grown.draft), [1, 1, 1, 1, 2, 3, 3]);
      expect(grown.draft.shotGroups, const [ShotGroup(0, 3), ShotGroup(5, 2)]);
      expect(grown.draft.pickShuttles, [1, 1, 1, 1, 2, 1, 1], reason: 'copies the last pass');
      expect(grown.draft.pickStrands, [1, 1, 1, 2, 1, 1, 3]);
      // Row 2 (pick 3, separate, same shed as the group): its new pick is separate too.
      final plain = s.setEntryCount(1, 2);
      expect(plain.draft.shotGroups, const [ShotGroup(0, 2), ShotGroup(5, 2)]);
      expect(plain.draft.pickStrands, [1, 1, 2, 2, 1, 1, 3], reason: 'copies its strands');
      // Shrinking a double shot to one pick dissolves it.
      final one = s.setEntryCount(3, 1);
      expect(one.draft.shotGroups, const [ShotGroup(0, 2)]);
      expect(one.draft.picks, 5);
    });

    test('deleting a row, or a member, keeps every other group on its picks', () {
      final s = EditorState(draft: worked());
      final noRow2 = s.removeEntry(1); // pick 3
      expect(treadles(noRow2.draft), [1, 1, 2, 3, 3]);
      expect(noRow2.draft.shotGroups, const [ShotGroup(0, 2), ShotGroup(3, 2)]);
      expect(noRow2.draft.pickShuttles, [1, 1, 2, 1, 1]);
      expect(noRow2.draft.pickStrands, [1, 1, 1, 1, 3]);
      final noGroup = s.removeEntry(0);
      expect(noGroup.draft.shotGroups, const [ShotGroup(2, 2)]);
    });

    test('a shed change of one member splits or dissolves its group', () {
      final triple = EditorState(draft: worked().copyWith(shotGroups: const [ShotGroup(0, 3)]));
      final last = triple.withShedForPick(2, const [2]);
      expect(last.draft.shotGroups, const [ShotGroup(0, 2)], reason: 'shrinks to its one-shed run');
      expect(shotGroupChangeNotice(triple.draft, last.draft),
          'The triple shot at picks 1 to 3 now groups only picks 1 to 2, because the other picks are '
          'in a different shed now. Every pass of a shot group uses the same shed.');
      final middle = triple.withShedForPick(1, const [2]);
      expect(middle.draft.shotGroups, isEmpty, reason: 'no two picks left in one shed');
      expect(shotGroupChangeNotice(triple.draft, middle.draft),
          'Picks 1 to 3 are no longer a triple shot, because their sheds now differ. Every pass of a '
          'shot group uses the same shed.');
      // The Book view's row edit changes the whole group together, so the group stays.
      final row = EditorState(draft: worked()).withShedForEntry(0, const [4]);
      expect(row.draft.shotGroups, worked().shotGroups);
      expect(treadles(row.draft), [4, 4, 1, 2, 3, 3]);
      expect(shotGroupChangeNotice(worked(), row.draft), isNull);
    });

    test('a padded pick has no shuttle and one strand', () {
      final s = EditorState(draft: worked()).withTreadleForPick(7, const [4]);
      expect(s.draft.picks, 8);
      expect(s.draft.pickShuttles, [1, 1, 1, 2, 1, 1, null, null]);
      expect(s.draft.pickStrands, [1, 1, 2, 1, 1, 3, 1, 1]);
      expect(s.draft.shotGroups, worked().shotGroups);
    });

    test('shuttle, starting side, and strand setters', () {
      final s = EditorState(draft: worked());
      expect(s.withPickShuttles(0, 6, null).draft.pickShuttles, isEmpty);
      expect(s.withPickShuttles(3, 4, 1).draft.pickShuttles, [1, 1, 1, 1, 1, 1]);
      expect(s.withPickShuttles(3, 4, 2), same(s), reason: 'no-op');
      expect(() => s.withPickShuttles(0, 1, 9), throwsRangeError);
      expect(s.withShuttleStart(2, L).draft.shuttleStarts, const {1: R, 2: L});
      expect(s.withShuttleStart(1, null).draft.shuttleStarts, isEmpty);
      expect(s.withPickStrands(0, 6, 1).draft.pickStrands, isEmpty);
      expect(s.withPickStrands(0, 2, 4).draft.pickStrands, [4, 4, 2, 1, 1, 3]);
      expect(() => s.withPickStrands(0, 1, 5), throwsRangeError);
      expect(() => s.withPickStrands(0, 7, 2), throwsRangeError);
    });

    test('undo restores groups, shuttles, and strands exactly', () {
      var s = EditorState(draft: worked());
      s = s.commitEdit(s.removeEntry(0).draft);
      s = s.commitEdit(s.withPickStrands(0, 1, 3).draft);
      expect(s.draft.shotGroups, const [ShotGroup(2, 2)]);
      s = s.undoEdit().undoEdit();
      expect(s.draft, worked());
      s = s.redoEdit();
      expect(s.draft.shotGroups, const [ShotGroup(2, 2)]);
    });

    test('Generate structure overlay: groups over replaced sheds are dropped, the rest kept', () {
      final doc = worked();
      // Re-tread picks 5 and 6 (the second double shot) with a generated straight treadling.
      final out = DraftRepository.applyBasicStructure(
        base: doc,
        effShafts: 4,
        applyTreadling: true,
        effTreadles: 4,
        picks: 2,
        pickStart: 4,
      );
      expect(treadles(out), [1, 1, 1, 2, 1, 2]);
      expect(out.shotGroups, const [ShotGroup(0, 2)]);
      expect(out.pickShuttles, doc.pickShuttles, reason: 'the weft stays with its picks');
      expect(out.pickStrands, doc.pickStrands);
    });

    test('the double-weave layer split narrows groups, shuttles, and strands', () {
      // Picks 1 and 2 weave the top layer (treadle 1 raises only shaft 1 of top {1, 3}), pick 3 the
      // bottom (treadle 2 lifts the top and shaft 2), pick 4 the top again.
      final doc = DraftDoc(
        name: 'dw',
        shafts: 4,
        treadles: 2,
        shed: Shed.rising,
        unit: MeasureUnit.inches,
        threading: const [
          [1],
          [2],
          [3],
          [4],
        ],
        drive: DraftTreadled(tieup: const [
          [1],
          [1, 2, 3],
        ], treadling: const [
          [1],
          [1],
          [2],
          [1],
        ]),
        palette: const [DraftColor(r: 0, g: 0, b: 0)],
        warpColors: const [0, 0, 0, 0],
        weftColors: const [0, 0, 0, 0],
        notes: '',
        pickShuttles: const [1, 1, 2, 1],
        pickStrands: const [2, 2, 1, 1],
        shotGroups: const [ShotGroup(0, 2)],
      );
      final top = doubleWeaveLayerDraft(doc, topShafts: const {1, 3}, top: true);
      expect(top.picks, 3);
      expect(top.shotGroups, const [ShotGroup(0, 2)]);
      expect(top.pickShuttles, [1, 1, 1]);
      expect(top.pickStrands, [2, 2, 1]);
      final bottom = doubleWeaveLayerDraft(doc, topShafts: const {1, 3}, top: false);
      expect(bottom.shotGroups, isEmpty);
      expect(bottom.pickShuttles, [2]);
    });
  });

  group('Use tabby with shot groups, shuttles, and strands', () {
    test('a draft with a shot group falls back with its own reason', () {
      final doc = generatedOvershot().copyWith(drive: DraftTreadled(tieup: kOvershotTieup, treadling: const [
        [1],
        [1],
        [1],
        [3],
        [2],
        [4],
        [2],
        [3],
      ]), shotGroups: const [ShotGroup(0, 2)]);
      final reading = readUseTabby(doc);
      expect(reading, isA<UseTabbyUnavailable>());
      expect((reading as UseTabbyUnavailable).reason,
          'Use tabby shorthand needs one pass in each shed, but picks 1 to 2 are grouped as a '
          'double shot.');
    });

    test('one tabby weft means one tabby shuttle and strand count', () {
      final base = generatedOvershot().copyWith(
        pickShuttles: [for (var p = 0; p < 8; p++) p.isEven ? 1 : 2],
        pickStrands: [for (var p = 0; p < 8; p++) p.isEven ? 2 : 1],
        shuttleStarts: const {1: R, 2: L},
      );
      final book = readUseTabby(base);
      expect(book, isA<UseTabbyBook>());
      book as UseTabbyBook;
      expect(book.tabbyShuttle, 2);
      expect(book.tabbyStrands, 1);
      expect(book.pattern.first.shuttle, 1);
      expect(book.pattern.first.strands, 2);
      expect(book.expand().matches(base), isTrue);

      final otherShuttle = base.copyWith(pickShuttles: [1, 2, 1, 2, 1, 3, 1, 2]);
      expect((readUseTabby(otherShuttle) as UseTabbyUnavailable).reason,
          'Use tabby shorthand needs one tabby weft. Pick 6 is a tabby pick on shuttle 3, but pick '
          '2 is on shuttle 2.');
      final noShuttle = base.copyWith(pickShuttles: [1, 2, 1, null, 1, 2, 1, 2]);
      expect((readUseTabby(noShuttle) as UseTabbyUnavailable).reason,
          'Use tabby shorthand needs one tabby weft. Pick 4 is a tabby pick with no shuttle, but '
          'pick 2 is on shuttle 2.');
      final otherStrands = base.copyWith(pickStrands: [2, 1, 2, 1, 2, 1, 2, 2]);
      expect((readUseTabby(otherStrands) as UseTabbyUnavailable).reason,
          'Use tabby shorthand needs one tabby weft. Pick 8 is a tabby pick with 2 strands, but '
          'pick 2 has 1 strand.');
    });

    test('a Use tabby count edit carries the shuttles and strands exactly', () {
      final base = generatedOvershot().copyWith(
        pickShuttles: [for (var p = 0; p < 8; p++) p.isEven ? 1 : 2],
        pickStrands: [for (var p = 0; p < 8; p++) p.isEven ? 2 : 1],
      );
      final edited = editUseTabbyRowCount(base, 0, 3);
      expect(edited, isA<UseTabbyEdited>());
      final doc = (edited as UseTabbyEdited).doc;
      expect(doc.picks, 10);
      expect(doc.pickShuttles, [for (var p = 0; p < 10; p++) p.isEven ? 1 : 2]);
      expect(doc.pickStrands, [for (var p = 0; p < 10; p++) p.isEven ? 2 : 1]);
      expect(readUseTabby(doc), isA<UseTabbyBook>());
    });
  });
}
