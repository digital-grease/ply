import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/models/draft_doc.dart';
import 'package:ply/src/models/treadling_entries.dart';
import 'package:ply/src/models/use_tabby.dart';

import 'pick_roles_support.dart';

// Host coverage for the Use tabby shorthand (M8-08) and the tabby-role proposal (M8-06): the
// reconstruction gives back EXACTLY the expanded picks for the cases that qualify, every case that
// does not qualify falls back with its reason, and edits in the shorthand either keep book and full
// mode identical or are refused.

/// An overshot-threaded draft with exactly [treadling] and [roles] (P = pattern, T = tabby,
/// ? = unknown, L = top layer), weft colors [weft] (default: pattern 1, tabby 0).
DraftDoc custom(List<int> treadling, String roles, {List<int>? weft, List<double>? thickness}) {
  PickRole role(String c) => switch (c) {
        'P' => PickRole.pattern,
        'T' => PickRole.tabby,
        'L' => PickRole.topLayer,
        _ => PickRole.unknown,
      };
  return generatedOvershot(picks: 0).copyWith(
    treadles: 5,
    drive: DraftTreadled(tieup: const [...kOvershotTieup, [1, 3]], // treadle 5 = a copy of 3
        treadling: [for (final t in treadling) [t]]),
    weftColors: weft ?? [for (var i = 0; i < roles.length; i++) roles[i] == 'P' ? 1 : 0],
    weftThickness: thickness,
    pickRoles: [for (var i = 0; i < roles.length; i++) role(roles[i])],
  );
}

UseTabbyBook book(DraftDoc doc) {
  final r = readUseTabby(doc);
  if (r is UseTabbyUnavailable) fail('expected Use tabby, got: ${r.reason}');
  return r as UseTabbyBook;
}

String reason(DraftDoc doc) {
  final r = readUseTabby(doc);
  if (r is UseTabbyBook) fail('expected no Use tabby');
  return (r as UseTabbyUnavailable).reason;
}

/// The expansion is the draft, pick by pick: shed, role, weft color, thickness.
void expectExact(UseTabbyBook b, DraftDoc doc) {
  final e = b.expand();
  expect(e.sheds, doc.drive.rows);
  expect(e.roles, [for (var p = 0; p < doc.picks; p++) doc.roleAt(p)]);
  expect(e.colors, doc.weftColors);
  expect(e.thickness, doc.weftThickness);
  expect(e.matches(doc), isTrue);
}

DraftDoc edited(UseTabbyEditResult r) {
  if (r is UseTabbyRefused) fail('edit refused: ${r.reason}');
  return (r as UseTabbyEdited).doc;
}

String refused(UseTabbyEditResult r) {
  if (r is UseTabbyEdited) fail('edit was not refused');
  return (r as UseTabbyRefused).reason;
}

List<int> treadles(DraftDoc doc) => [for (final r in doc.drive.rows) r.single];

void main() {
  group('the plain-weave (tabby) shed rule', () {
    // The same cases as the engine's plain_weave_phase tests.
    test('finds the two tabby sheds of an overshot threading and nothing else', () {
      final d = generatedOvershot(ends: 8, picks: 0);
      expect(plainWeavePhase(d, {1, 3}), isTrue, reason: 'tabby a lifts end 1');
      expect(plainWeavePhase(d, {2, 4}), isFalse);
      expect(plainWeavePhase(d, {1, 2}), isNull, reason: 'a pattern block is not plain weave');
      expect(plainWeavePhase(d, {}), isNull);
      expect(plainWeavePhase(d, {1, 2, 3, 4}), isNull);
    });

    test('skips unthreaded ends and needs two threaded ends', () {
      final d = generatedOvershot(ends: 8, picks: 0);
      final gap = d.copyWith(threading: [d.threading[0], const <int>[], ...d.threading.skip(1)]);
      expect(plainWeavePhase(gap, {1, 3}), isTrue);
      final one = d.copyWith(threading: const [
        [1],
        <int>[],
      ]);
      expect(plainWeavePhase(one, {1}), isNull);
    });

    test('handles ends on several shafts (the engine cases)', () {
      DraftDoc on(List<List<int>> t) => generatedOvershot(picks: 0).copyWith(threading: t);
      final d = on(const [
        [1],
        [2, 3],
        [1],
        [2],
      ]);
      expect(plainWeavePhase(d, {1}), isTrue);
      expect(plainWeavePhase(d, {1, 2}), isNull);
      expect(plainWeavePhase(d, {2}), isFalse);
      expect(plainWeavePhase(d, {2, 3}), isFalse);
      expect(plainWeavePhase(d, {3}), isNull, reason: 'end 4 would stay down');
      expect(plainWeavePhase(d, {1, 9}), isTrue, reason: 'an unthreaded shaft changes nothing');
      final stuck = on(const [
        [1],
        [1],
        [2],
      ]);
      expect(plainWeavePhase(stuck, {1}), isNull);
      expect(plainWeavePhase(stuck, {2}), isNull);
    });

    test('the rule is the alternation definition, for every lift on small threadings', () {
      bool? walk(List<List<int>> t, Set<int> raised) {
        final ups = [
          for (final e in t)
            if (e.isNotEmpty) e.any(raised.contains),
        ];
        if (ups.length < 2) return null;
        for (var i = 1; i < ups.length; i++) {
          if (ups[i] == ups[i - 1]) return null;
        }
        return ups.first;
      }

      final threadings = <List<List<int>>>[
        [for (var i = 0; i < 6; i++) [i % 4 + 1]],
        [for (final s in [1, 2, 3, 4, 3, 2, 1, 2, 3]) [s]],
        [for (final s in [1, 2, 1, 2, 3, 4, 3, 4]) [s]],
        const [
          [1],
          <int>[],
          [2, 4],
          [3],
          [4],
          [1, 3],
        ],
      ];
      for (final t in threadings) {
        final rule = TabbyRule.of(generatedOvershot(picks: 0).copyWith(threading: t));
        for (var mask = 0; mask < 32; mask++) {
          final raised = {for (var s = 1; s <= 5; s++) if (mask & (1 << (s - 1)) != 0) s};
          expect(rule.phase(raised), walk(t, raised), reason: '$t $raised');
        }
      }
    });

    test('reads raised shafts, so a sinking-shed tie-up names the same tabby', () {
      final d = generatedOvershot(ends: 4, picks: 0).copyWith(
        shed: Shed.sinking,
        threading: const [
          [1],
          [2],
          [3],
          [4],
        ],
        drive: DraftTreadled(tieup: const [
          [2, 4],
          [1],
        ], treadling: const [
          [1],
          [2],
        ]),
      );
      expect(pickTabbyPhase(d, 0), isTrue, reason: 'sinking 2,4 raises 1,3');
      expect(pickTabbyPhase(d, 1), isNull);
    });
  });

  group('Use tabby reconstruction equals the expanded picks', () {
    test('a generated overshot', () {
      final doc = generatedOvershot();
      final b = book(doc);
      expect(b.leadingTabby, isFalse);
      expect(b.trailingTabby, isTrue);
      expect(b.firstIsA, isTrue);
      expect(b.tabbySheds, const [
        [3],
        [4],
      ]);
      expect(b.tabbyColor, 0);
      expect([for (final r in b.rows) (r.shed.single, r.count, r.firstPick, r.lastPick)], [
        (1, 2, 0, 2),
        (2, 2, 4, 6),
      ]);
      expect(useTabbySummary(b), '8 picks: 4 pattern picks in 2 rows and 4 tabby picks');
      expect(
          useTabbyInstruction(b),
          'Weave one tabby pick after every pattern pick. The tabby alternates between tabby a '
          '(treadle 3) and tabby b (treadle 4), starting with tabby a. Tabby a is the tabby shed '
          'that lifts the first threaded warp end.');
      expectExact(b, doc);
      // Larger generated drafts too, any block width.
      for (final (ends, picks, block) in [(24, 12, 6), (40, 33, 4), (16, 16, 2)]) {
        final d = generatedOvershot(ends: ends, picks: picks, block: block);
        expectExact(book(d), d);
      }
    });

    test('a tabby-phase inversion (tabby b first)', () {
      final doc = custom([1, 4, 1, 3, 2, 4], 'PTPTPT');
      final b = book(doc);
      expect(b.firstIsA, isFalse);
      expect(b.tabbyShed(a: true), [3]);
      expect(b.tabbyShed(a: false), [4]);
      expect(useTabbyInstruction(b), contains('starting with tabby b.'));
      expect(useTabbyInstruction(b),
          contains('between tabby a (treadle 3) and tabby b (treadle 4)'));
      expectExact(b, doc);
    });

    test('irregular pattern runs, mixed pattern wefts, a leading tabby and no trailing tabby', () {
      // T P T P T P T P T P T P T P : pattern 1,1,1,2,1,2,2 after a first tabby, ending on a tabby.
      final doc = custom([3, 1, 4, 1, 3, 1, 4, 2, 3, 1, 4, 2, 3, 2, 4], 'TPTPTPTPTPTPTPT',
          weft: [0, 1, 0, 2, 0, 1, 0, 1, 0, 1, 0, 2, 0, 2, 0]);
      final b = book(doc);
      expect(b.leadingTabby, isTrue);
      expect(b.trailingTabby, isTrue);
      expect([for (final r in b.rows) (r.shed.single, r.count)], [(1, 3), (2, 1), (1, 1), (2, 2)]);
      expect(b.rows.first.firstPick, 1);
      expect(useTabbyInstruction(b), startsWith('Weave one tabby pick first, then one after every'));
      expectExact(b, doc);

      final noTrailing = custom([1, 3, 1, 4, 2], 'PTPTP');
      final b2 = book(noTrailing);
      expect(b2.trailingTabby, isFalse);
      expect(useTabbyInstruction(b2),
          startsWith('Weave one tabby pick after every pattern pick except the last.'));
      expectExact(b2, noTrailing);
    });

    test('a liftplan draft names shaft sheds and keeps thickness', () {
      final base = generatedOvershot();
      final lift = base.copyWith(
        treadles: 0,
        drive: DraftLiftplan(liftplan: [
          for (final r in (base.drive as DraftTreadled).treadling) kOvershotTieup[r.single - 1],
        ]),
        weftThickness: [for (var p = 0; p < 8; p++) p.isEven ? 2.0 : 1.0],
      );
      final b = book(lift);
      expect(b.treadled, isFalse);
      expect(b.tabbyThickness, 1.0);
      expect(useTabbyInstruction(b), contains('tabby a (shafts 1 + 3)'));
      expectExact(b, lift);
    });

    test('a single tabby pick names only the shed it uses', () {
      final doc = custom([1, 4, 2], 'PTP');
      final b = book(doc);
      expect(b.tabbySheds, const [
        [4],
      ]);
      expect(useTabbyInstruction(b), contains('The tabby pick is tabby b (treadle 4).'));
      expectExact(b, doc);
    });
  });

  group('falls back to the full listing and says why', () {
    test('a missing role', () {
      final doc = generatedOvershot();
      final one = doc.copyWith(pickRoles: [...doc.pickRoles]..[2] = PickRole.unknown);
      expect(reason(one),
          'Use tabby shorthand needs every pick to have a role. Roles are unknown for pick 3.');
      final many = doc.copyWith(pickRoles: [
        for (var p = 0; p < 8; p++) (p >= 2 && p <= 5) || p == 7 ? PickRole.unknown : doc.roleAt(p),
      ]);
      expect(reason(many), endsWith('Roles are unknown for picks 3 to 6 and 8.'));
      expect(reason(generatedOvershot(roles: false)), endsWith('unknown for picks 1 to 8.'));
    });

    test('a broken alternation', () {
      expect(reason(custom([1, 3, 4, 1], 'PTTP')),
          'Use tabby shorthand needs pattern and tabby picks to alternate. Picks 2 and 3 are both '
          'tabby picks.');
      expect(reason(custom([1, 2, 3], 'PPT')), endsWith('Picks 1 and 2 are both pattern picks.'));
    });

    test('a tabby that does not alternate between its two sheds', () {
      expect(reason(custom([1, 3, 1, 3, 1], 'PTPTP')),
          'Use tabby shorthand needs the tabby to alternate between its two sheds. Tabby picks 2 '
          'and 4 both lift the same warp ends (treadle 3).');
      // Treadle 5 is tied like treadle 3: different treadles, same tabby.
      expect(reason(custom([1, 3, 1, 5, 1], 'PTPTP')),
          endsWith('Tabby picks 2 and 4 both lift the same warp ends (treadle 3 and treadle 5).'));
    });

    test('a third tabby treadle', () {
      expect(reason(custom([1, 3, 1, 4, 1, 5, 1], 'PTPTPTP')),
          'Use tabby shorthand needs every tabby pick to use one of the two tabby sheds. Pick 6 '
          'uses treadle 5, but the tabby picks before it use treadle 3 and treadle 4.');
    });

    test('a tabby pick that is not plain weave', () {
      expect(reason(custom([1, 2, 1], 'PTP')),
          'Use tabby shorthand needs the tabby picks to weave plain weave. Pick 2 is marked tabby, '
          'but its shed (treadle 2) does not lift every other warp end.');
    });

    test('other roles, counts, wefts, and an empty draft', () {
      expect(reason(custom([1, 3], 'LT')),
          'Use tabby shorthand needs only pattern and tabby picks. Pick 1 is marked top layer.');
      expect(reason(custom([3], 'T')), 'Use tabby shorthand needs at least one pattern pick.');
      expect(reason(custom([1], 'P')), 'Use tabby shorthand needs at least one tabby pick.');
      expect(reason(custom([1, 3, 1, 4, 1], 'PTPTP', weft: [1, 0, 1, 2, 1])),
          'Use tabby shorthand needs one tabby weft. Pick 4 is a tabby pick in weft color 3, but '
          'pick 2 is in color 1.');
      expect(
          reason(custom([1, 3, 1, 4], 'PTPT', thickness: [2, 1, 2, 1.5])),
          'Use tabby shorthand needs one tabby weft. Pick 4 is a tabby pick with a different weft '
          'thickness from pick 2.');
      final short = generatedOvershot().copyWith(
          pickRoles: [for (var p = 0; p < 7; p++) p.isEven ? PickRole.pattern : PickRole.tabby]);
      expect(reason(short),
          'Use tabby shorthand needs one role per pick, but this draft has 7 roles for 8 picks.');
      expect(reason(DraftDoc.blank()), 'This draft has no picks yet.');
    });

    test('a shorthand that would not rebuild the exact picks is never shown', () {
      // Picks 2 and 4 press the same two treadles in a different ORDER: the same shed, but the
      // shorthand could only write one order back, so the in-code check refuses it.
      final doc = custom([1, 3, 1, 4, 1, 3], 'PTPTPT').copyWith(
        drive: DraftTreadled(tieup: const [...kOvershotTieup, <int>[]], treadling: const [
          [1],
          [3, 5],
          [1],
          [4],
          [1],
          [5, 3],
        ]),
      );
      expect(reason(doc), kUseTabbyRebuildFailed);
    });
  });

  group('edits in the Use tabby view', () {
    test('more pattern picks keep the tabby alternating and read back as the shorthand', () {
      final doc = generatedOvershot(); // 1 3 1 4 2 3 2 4
      final grown = edited(editUseTabbyRowCount(doc, 0, 3));
      // Row 1 gets a third pattern pick (with its tabby); the tabby keeps alternating, so every
      // later tabby moves to the other shed.
      expect(treadles(grown), [1, 3, 1, 4, 1, 3, 2, 4, 2, 3]);
      expect(grown.pickRoles, [
        for (var p = 0; p < 10; p++) p.isEven ? PickRole.pattern : PickRole.tabby,
      ]);
      expect(grown.weftColors, [for (var p = 0; p < 10; p++) p.isEven ? 1 : 0]);
      final b = book(grown);
      expect([for (final r in b.rows) r.count], [3, 2]);
      expectExact(b, grown);
      // Two more keep every later tabby on its shed.
      expect(treadles(edited(editUseTabbyRowCount(doc, 0, 4))), [1, 3, 1, 4, 1, 3, 1, 4, 2, 3, 2, 4]);
    });

    test('fewer pattern picks, a changed shed (rows merge), and a deleted row', () {
      final doc = generatedOvershot();
      expect(treadles(edited(editUseTabbyRowCount(doc, 1, 1))), [1, 3, 1, 4, 2, 3]);
      final merged = edited(editUseTabbyRowShed(doc, 1, const [1]));
      expect(treadles(merged), [1, 3, 1, 4, 1, 3, 1, 4]);
      expect(book(merged).rows.single.count, 4, reason: 'the two rows are one shed now');
      final removed = edited(removeUseTabbyRow(doc, 0));
      expect(treadles(removed), [2, 3, 2, 4]);
      expectExact(book(removed), removed);
    });

    test('edits are refused with a reason when they cannot stay exact', () {
      final doc = generatedOvershot(picks: 4); // one row: 1 3 1 4
      expect(refused(removeUseTabbyRow(doc, 0)), kUseTabbyLastRow);
      // P T P: one pattern pick fewer would leave no tabby.
      expect(refused(editUseTabbyRowCount(custom([1, 3, 1], 'PTP'), 0, 1)), kUseTabbyNoTabbyLeft);
      // One tabby pick so far: the other tabby shed is not known.
      expect(refused(editUseTabbyRowCount(custom([1, 4, 1], 'PTP'), 0, 3)), kUseTabbyOneShedKnown);
      // Not Use tabby at all: the edit is refused with the fallback reason.
      expect(refused(editUseTabbyRowCount(generatedOvershot(roles: false), 0, 2)),
          endsWith('Roles are unknown for picks 1 to 8.'));
    });

    test('every edit of a generated overshot keeps book and full mode identical', () {
      final doc = generatedOvershot(ends: 24, picks: 20, block: 6);
      final rows = book(doc).rows;
      for (var i = 0; i < rows.length; i++) {
        for (final r in [
          editUseTabbyRowCount(doc, i, rows[i].count + 1),
          if (rows[i].count > 1) editUseTabbyRowCount(doc, i, rows[i].count - 1),
          editUseTabbyRowShed(doc, i, const [2]),
          if (rows.length > 1) removeUseTabbyRow(doc, i),
        ]) {
          final next = edited(r);
          expectExact(book(next), next);
          // The full listing's runs cover exactly the same picks.
          expect(treadlingEntries(next.drive.rows).fold<int>(0, (n, e) => n + e.count), next.picks);
        }
      }
    });
  });

  group('the Mark tabby picks proposal', () {
    test('proposes the tabby picks and, as an option, the rest as pattern', () {
      final doc = generatedOvershot(roles: false);
      final p = proposeTabbyRoles(doc);
      expect(p.toTabby, [1, 3, 5, 7]);
      expect(p.otherUnknown, [0, 2, 4, 6]);
      expect(p.replacing, isEmpty);
      expect(p.sheds, const [
        [3],
        [4],
      ]);
      expect(p.roles(), {1: PickRole.tabby, 3: PickRole.tabby, 5: PickRole.tabby, 7: PickRole.tabby});
      final all = p.roles(othersAsPattern: true);
      expect(all.length, 8);
      final marked = doc.copyWith(pickRoles: [for (var q = 0; q < 8; q++) all[q]!]);
      expect(marked, generatedOvershot(), reason: 'marking gives the generator roles back');
    });

    test('reports roles it would replace and picks already tabby; a twill has no tabby', () {
      final doc = generatedOvershot().copyWith(pickRoles: [
        for (var p = 0; p < 8; p++) p == 3 ? PickRole.pattern : (p == 5 ? PickRole.tabby : PickRole.unknown),
      ]);
      final p = proposeTabbyRoles(doc);
      expect(p.toTabby, [1, 3, 7]);
      expect(p.replacing, [3]);
      expect(p.alreadyTabby, [5]);
      final twill = generatedOvershot(roles: false).copyWith(
        threading: [
          for (var i = 0; i < 8; i++) [i % 4 + 1],
        ],
        drive: DraftTreadled(tieup: const [
          [1, 2],
          [2, 3],
          [3, 4],
          [4, 1],
        ], treadling: [
          for (var p = 0; p < 8; p++) [p % 4 + 1],
        ]),
      );
      expect(proposeTabbyRoles(twill).noTabbySheds, isTrue);
    });
  });

  test('pick lists read naturally', () {
    expect(describePicks(const [2]), 'pick 3');
    expect(describePicks(const [2, 3, 4, 5, 6, 7, 8]), 'picks 3 to 9');
    expect(describePicks(const [0, 2, 3, 4, 8]), 'picks 1, 3 to 5 and 9');
    expect(describePicks(const [0, 2, 4, 6, 8, 10, 11], sentenceStart: true),
        'Picks 1, 3, 5, 7 and 3 more');
  });
}
