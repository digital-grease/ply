import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/draft_repository.dart';
import 'package:ply/src/models/double_weave_layers.dart';
import 'package:ply/src/models/draft_doc.dart';
import 'package:ply/src/models/editor_state.dart';
import 'package:ply/src/rust/dto.dart' show PickRoleKind;

import 'pick_roles_support.dart';

// Host coverage for per-pick roles in the editor model (M8-06): one representation for "nothing
// recorded", roles that stay aligned with the picks through every editor operation that inserts,
// removes, or overwrites picks, the undo stack, the DTO mapping (the save path), the structure
// overlay, and the double-weave layer split.

const P = PickRole.pattern;
const T = PickRole.tabby;
const U = PickRole.unknown;

/// Treadle 1 x3, treadle 2 x1, treadle 1 x2 (three Book view rows), with roles P P T | U | T P.
DraftDoc runs() => generatedOvershot(picks: 0).copyWith(
      drive: DraftTreadled(tieup: const [
        [1, 2],
        [3, 4],
      ], treadling: const [
        [1],
        [1],
        [1],
        [2],
        [1],
        [1],
      ]),
      treadles: 2,
      weftColors: const [1, 1, 0, 0, 1, 0],
      pickRoles: const [P, P, T, U, T, P],
    );

void main() {
  group('DraftDoc roles', () {
    test('a list with no known role is the empty "nothing recorded" form', () {
      final d = runs().copyWith(pickRoles: const [U, U, U, U, U, U]);
      expect(d.pickRoles, isEmpty);
      expect(d, runs().copyWith(pickRoles: const []));
      expect(d.roleAt(2), U);
      expect(runs().roleAt(2), T);
      expect(runs().roleAt(99), U, reason: 'past the picks is unknown');
    });

    test('roles are part of value equality, hash, and frozen', () {
      expect(runs(), runs());
      expect(runs().hashCode, runs().hashCode);
      expect(runs(), isNot(runs().copyWith(pickRoles: const [P, P, T, U, T, T])));
      expect(() => runs().pickRoles.add(P), throwsUnsupportedError);
    });

    test('the DTO mapping (the save and reopen path) carries every role', () {
      final repo = DraftRepository();
      final doc = runs().copyWith(pickRoles: const [P, T, PickRole.topLayer, PickRole.bottomLayer, U, P]);
      final dto = repo.toDto(doc);
      expect(dto.pickRoles, [
        PickRoleKind.pattern,
        PickRoleKind.tabby,
        PickRoleKind.topLayer,
        PickRoleKind.bottomLayer,
        PickRoleKind.unknown,
        PickRoleKind.pattern,
      ]);
      expect(repo.fromDto(dto), doc);
      expect(repo.toDto(runs().copyWith(pickRoles: const [])).pickRoles, isEmpty);
    });
  });

  group('role edits', () {
    test('set the role of a row or one pick as an undoable edit', () {
      final s0 = EditorState(draft: runs());
      final s1 = s0.withPickRoles(0, 3, T);
      expect(s1.draft.pickRoles, const [T, T, T, U, T, P]);
      final s2 = s1.withPickRoles(3, 4, P);
      expect(s2.draft.pickRoles, const [T, T, T, P, T, P]);
      expect(identical(s2.withPickRoles(3, 4, P), s2), isTrue, reason: 'no-op');
      expect(() => s0.withPickRoles(5, 7, P), throwsRangeError);
      // A committed role edit is one undo entry and marks the draft dirty (so Save re-writes WIF).
      final c = s0.commitEdit(s1.draft);
      expect(c.dirtyStructural, isTrue);
      expect(c.undoEdit().draft, runs());
      expect(c.undoEdit().redoEdit().draft.pickRoles, const [T, T, T, U, T, P]);
    });

    test('setting roles on a draft with none materializes exactly one per pick', () {
      final none = runs().copyWith(pickRoles: const []);
      final s = EditorState(draft: none).withPickRoles(1, 2, T);
      expect(s.draft.pickRoles, const [U, T, U, U, U, U]);
      expect(EditorState(draft: s.draft).withPickRoles(1, 2, U).draft.pickRoles, isEmpty,
          reason: 'back to nothing recorded');
    });

    test('a proposal map applies in one step', () {
      final s = EditorState(draft: runs()).withPickRoleMap({3: T, 5: T});
      expect(s.draft.pickRoles, const [P, P, T, T, T, T]);
      expect(() => EditorState(draft: runs()).withPickRoleMap({6: T}), throwsRangeError);
    });
  });

  group('editor edits keep roles aligned with the picks', () {
    test('a Book view count GROW copies the last pick of the run, role included', () {
      final s = EditorState(draft: runs()).setEntryCount(0, 5); // treadle 1 x3 -> x5
      expect(s.draft.picks, 8);
      expect(s.draft.pickRoles, const [P, P, T, T, T, U, T, P]);
      expect(s.draft.weftColors, const [1, 1, 0, 0, 0, 0, 1, 0]);
    });

    test('a count SHRINK and a row delete take the picks\' roles with them', () {
      expect(EditorState(draft: runs()).setEntryCount(0, 1).draft.pickRoles, const [P, U, T, P]);
      expect(EditorState(draft: runs()).removeEntry(1).draft.pickRoles, const [P, P, T, T, P]);
      expect(EditorState(draft: runs()).removeEntry(0).draft.pickRoles, const [U, T, P]);
    });

    test('a draft with no roles stays without roles through Book view edits', () {
      final none = runs().copyWith(pickRoles: const []);
      expect(EditorState(draft: none).setEntryCount(0, 5).draft.pickRoles, isEmpty);
      expect(EditorState(draft: none).removeEntry(0).draft.pickRoles, isEmpty);
    });

    test('shed edits keep every role; a padded pick is unknown', () {
      final s = EditorState(draft: runs());
      expect(s.withShedForEntry(1, const [1]).draft.pickRoles, runs().pickRoles);
      expect(s.withShedForPick(0, const [2]).draft.pickRoles, runs().pickRoles);
      final padded = s.withTreadleForPick(7, const [1]).draft;
      expect(padded.picks, 8);
      expect(padded.pickRoles, const [P, P, T, U, T, P, U, U]);
    });

    test('a change of pick count drops per-pick retained WIF sections, as the engine does', () {
      final doc = runs().copyWith(retained: [
        RetainedSection('WEFT SPACING', const [RetainedEntry('1', '10')]),
        RetainedSection('ACME VENDOR', const [RetainedEntry('Foo', 'Bar')]),
      ]);
      final grown = EditorState(draft: doc).setEntryCount(1, 2).draft;
      expect(grown.retained.map((s) => s.name), ['ACME VENDOR']);
      final same = EditorState(draft: doc).withShedForEntry(1, const [1]).draft;
      expect(same.retained.length, 2, reason: 'same pick count: nothing to drop');
    });

    test('Generate structure overlay keeps roles coupled; overwritten picks become unknown', () {
      final base = runs();
      final out = DraftRepository.applyBasicStructure(
        base: base,
        effShafts: 4,
        applyTreadling: true,
        effTreadles: 2,
        picks: 4,
        pickStart: 4, // overwrite picks 5-6 and add picks 7-8
      );
      expect(out.picks, 8);
      expect(out.pickRoles, const [P, P, T, U, U, U, U, U]);
      final tieOnly = DraftRepository.applyBasicStructure(
          base: base, effShafts: 4, genTieup: const [
        [1],
        [2],
      ]);
      expect(tieOnly.pickRoles, base.pickRoles, reason: 'a tie-up swap keeps every pick and role');
    });

    test('the double-weave layer split narrows roles with the picks', () {
      final dw = generatedOvershot(picks: 0).copyWith(
        threading: [
          for (var i = 0; i < 8; i++) [i % 4 + 1],
        ],
        drive: DraftTreadled(tieup: const [
          [1],
          [1, 2, 3],
          [3],
          [1, 3, 4],
        ], treadling: [
          for (var p = 0; p < 4; p++) [p + 1],
        ]),
        weftColors: const [0, 1, 0, 1],
        pickRoles: const [PickRole.topLayer, PickRole.bottomLayer, PickRole.topLayer, PickRole.bottomLayer],
      );
      final top = doubleWeaveLayerDraft(dw, topShafts: {1, 3}, top: true);
      expect(top.pickRoles, const [PickRole.topLayer, PickRole.topLayer]);
      final bottom = doubleWeaveLayerDraft(dw, topShafts: {1, 3}, top: false);
      expect(bottom.pickRoles, const [PickRole.bottomLayer, PickRole.bottomLayer]);
    });
  });
}
