import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/draft_repository.dart';
import 'package:ply/src/models/double_weave_construction.dart';
import 'package:ply/src/models/double_weave_layers.dart';
import 'package:ply/src/models/draft_doc.dart';
import 'package:ply/src/rust/dto.dart' show LayerConstructionKind;

// Host coverage for the double-weave construction model (M8-09, ADR 0010): the Dart twin of the
// engine's edge rule on the same worked examples as rust/ply-weave/tests/double_weave.rs
// (the double-weave research note, section 6), the same mismatch messages, when the top face can be
// shown, the tracked fixtures' oracles, and the DTO mapping.

const L = ShuttleSide.left;
const R = ShuttleSide.right;
const T = PickRole.topLayer;
const B = PickRole.bottomLayer;

List<X> cycle<X>(List<X> pattern, int n) =>
    [for (var i = 0; i < n; i++) pattern[i % pattern.length]];

/// The research examples' draft: straight 1-2-3-4 over [ends], top layer on shafts 1 and 3; tie-up
/// 1 = {1}, 2 = {1,2,3}, 3 = {3}, 4 = {1,3,4}.
DraftDoc example(
  int ends,
  List<int> treadling,
  List<PickRole> roles,
  List<int?> shuttles,
  Map<int, ShuttleSide> starts, {
  LayerConstruction construction = LayerConstruction.none,
}) =>
    DraftDoc.blank(shafts: 4, treadles: 4).copyWith(
      threading: [
        for (var e = 0; e < ends; e++) [e % 4 + 1],
      ],
      drive: DraftTreadled(
        tieup: const [
          [1],
          [1, 2, 3],
          [3],
          [1, 3, 4],
        ],
        treadling: [
          for (final t in treadling) [t],
        ],
      ),
      warpColors: cycle(const [0, 1], ends),
      weftColors: List.filled(treadling.length, 0),
      pickRoles: roles,
      pickShuttles: shuttles,
      shuttleStarts: starts,
      construction: construction,
    );

(EdgeBehavior, EdgeBehavior) edges(DraftDoc d) {
  final e = deriveEdges(d);
  if (e is! EdgesKnown) fail('edges should derive: ${(e as EdgesUnknown).reason}');
  return (e.left, e.right);
}

String? unknown(DraftDoc d) => switch (deriveEdges(d)) {
      EdgesUnknown(:final reason) => reason,
      EdgesKnown() => null,
    };

DraftDoc doubleWidthLeft() => example(
    8, cycle(const [1, 2, 4, 3], 8), cycle(const [T, B, B, T], 8), List.filled(8, 1), const {1: R});

void main() {
  group('the edge rule (twin of the engine, research worked examples)', () {
    test('two independent layers are open at both edges whatever the starting sides', () {
      for (final starts in const [
        {1: R, 2: R},
        {1: R, 2: L},
        {1: L, 2: L},
      ]) {
        final a = example(8, cycle(const [1, 2, 3, 4], 8), cycle(const [T, B], 8),
            cycle(const [1, 2], 8), starts);
        expect(edges(a), (EdgeBehavior.open, EdgeBehavior.open), reason: '$starts');
        final e = deriveEdges(a) as EdgesKnown;
        expect(e.construction, LayerConstruction.twoLayers);
        expect(e.turns.every((t) => t.to == t.from + 2 && !t.joins), isTrue);
      }
    });

    test('a tube joins both edges', () {
      final b = example(
          7, cycle(const [1, 2, 3, 4], 8), cycle(const [T, B], 8), List.filled(8, 1), const {1: L});
      expect(edges(b), (EdgeBehavior.joined, EdgeBehavior.joined));
      expect((deriveEdges(b) as EdgesKnown).construction, LayerConstruction.tube);
    });

    test('double width folds on the edge opposite the start, turn by turn', () {
      final c = doubleWidthLeft();
      expect(edges(c), (EdgeBehavior.joined, EdgeBehavior.open));
      expect((deriveEdges(c) as EdgesKnown).construction, LayerConstruction.doubleWidthFoldLeft);
      final turns = (deriveEdges(c) as EdgesKnown)
          .turns
          .take(4)
          .map((t) => (t.from + 1, t.to + 1, t.side, t.joins))
          .toList();
      expect(turns, [(1, 2, L, true), (2, 3, R, false), (3, 4, L, true), (4, 5, R, false)]);
      final d = example(8, cycle(const [1, 2, 4, 3], 8), cycle(const [T, B, B, T], 8),
          List.filled(8, 1), const {1: L});
      expect(edges(d), (EdgeBehavior.open, EdgeBehavior.joined));
      expect((deriveEdges(d) as EdgesKnown).construction, LayerConstruction.doubleWidthFoldRight);
    });

    test('two wefts keep the fold; T-T-B-B folds on the start side; blocks of layers are mixed',
        () {
      final f = example(8, const [1, 2, 4, 3, 2, 1, 3, 4], const [T, B, B, T, B, T, T, B],
          const [1, 1, 1, 1, 2, 2, 2, 2], const {1: R, 2: R});
      expect(edges(f), (EdgeBehavior.joined, EdgeBehavior.open));
      expect((deriveEdges(f) as EdgesKnown).construction, LayerConstruction.doubleWidthFoldLeft);
      final g = example(8, cycle(const [1, 3, 4, 2], 8), cycle(const [T, T, B, B], 8),
          List.filled(8, 1), const {1: L});
      expect(edges(g), (EdgeBehavior.joined, EdgeBehavior.open));
      final h = example(8, const [1, 3, 1, 3, 2, 4, 2, 4], const [T, T, T, T, B, B, B, B],
          List.filled(8, 1), const {1: R});
      expect(edges(h), (EdgeBehavior.open, EdgeBehavior.mixed));
      expect((deriveEdges(h) as EdgesKnown).construction, LayerConstruction.none);
    });

    test('unknown when roles, shuttles or starting sides are missing, with the reason', () {
      final full = example(
          8, cycle(const [1, 2, 3, 4], 8), cycle(const [T, B], 8), List.filled(8, 1), const {1: L});
      expect(unknown(full), isNull);
      expect(unknown(DraftDoc.blank()), 'it has no picks');
      expect(
          unknown(full.copyWith(
              pickRoles: [T, B, PickRole.unknown, PickRole.tabby, PickRole.pattern, B, T, B])),
          'picks 3 to 5 are not marked top layer or bottom layer');
      expect(unknown(full.copyWith(pickRoles: const [])),
          'picks 1 to 8 are not marked top layer or bottom layer');
      expect(unknown(full.copyWith(pickShuttles: [1, null, 1, null, 1, 1, 1, 1])),
          'picks 2 and 4 have no shuttle');
      expect(
          unknown(full.copyWith(pickShuttles: [1, 1, 1, 1, 1, 2, 1, 1], shuttleStarts: const {})),
          'shuttles 1 and 2 have no starting side');
      // Too few picks for a turn at one edge: known, that edge has none, and no exact match.
      final short = example(
          8, const [1, 2, 3, 4], const [T, B, T, B], const [1, 2, 1, 2], const {1: R, 2: R});
      expect(edges(short), (EdgeBehavior.open, EdgeBehavior.noTurns));
      expect((deriveEdges(short) as EdgesKnown).construction, LayerConstruction.none);
      expect(agreesWith(deriveEdges(short) as EdgesKnown, LayerConstruction.twoLayers), isTrue);
      expect(agreesWith(deriveEdges(short) as EdgesKnown, LayerConstruction.tube), isFalse);
    });
  });

  group('declared construction messages (the engine\'s wording)', () {
    test('a match says nothing; nothing declared says nothing', () {
      expect(constructionIssues(doubleWidthLeft()), isEmpty);
      expect(
          constructionIssues(
              doubleWidthLeft().copyWith(construction: LayerConstruction.doubleWidthFoldLeft)),
          isEmpty);
    });

    test('mismatches name the edge and the turns', () {
      List<String> declare(LayerConstruction c) =>
          constructionIssues(doubleWidthLeft().copyWith(construction: c));
      expect(declare(LayerConstruction.doubleWidthFoldRight), [
        'The fold should be on the right, but the layers join on the left between picks 1 and 2 '
            '(and at 3 more turns).',
        'The fold should be on the right, but the layers do not join on the right between picks 2 '
            'and 3 (and at 2 more turns).',
      ]);
      expect(declare(LayerConstruction.twoLayers), [
        'Two independent layers should be open at both edges, but the layers join on the left '
            'between picks 1 and 2 (and at 3 more turns).',
      ]);
      expect(declare(LayerConstruction.tube), [
        'A tube should join the layers at both edges, but the layers do not join on the right '
            'between picks 2 and 3 (and at 2 more turns).',
      ]);
      final stray = example(8, cycle(const [1, 2, 3, 4], 8), cycle(const [T, B], 8),
          const [1, 2, 1, 2, 2, 2, 1, 2], const {1: R, 2: R},
          construction: LayerConstruction.twoLayers);
      expect(constructionIssues(stray), [
        'Two independent layers should be open at both edges, but the layers join on the left '
            'between picks 5 and 6.',
        'Two independent layers should be open at both edges, but the layers join on the right '
            'between picks 4 and 5.',
      ]);
    });

    test('missing data and a single layer are explained', () {
      final tube = example(
          8, cycle(const [1, 2, 3, 4], 8), cycle(const [T, B], 8), List.filled(8, 1), const {1: L},
          construction: LayerConstruction.tube);
      expect(constructionIssues(tube), isEmpty);
      expect(constructionIssues(tube.copyWith(pickShuttles: [1, 1, 1, 1, 1, 1, null, 1])), [
        'This draft is marked as a tube, but Ply cannot check its edges because pick 7 has no '
            'shuttle.'
      ]);
      expect(constructionIssues(tube.copyWith(shuttleStarts: const {})), [
        'This draft is marked as a tube, but Ply cannot check its edges because shuttle 1 has no '
            'starting side.'
      ]);
      expect(constructionIssues(tube.copyWith(pickRoles: List.filled(8, T))), [
        'This draft is marked as a tube, but every pick is on the top layer, so there is only one '
            'layer.'
      ]);
      expect(
          constructionIssues(
              DraftDoc.blank().copyWith(construction: LayerConstruction.doubleWidthFoldLeft)),
          [
            'This draft is marked as double width with the fold on the left, but Ply cannot check '
                'its edges because it has no picks.'
          ]);
    });

    test('labels', () {
      expect(constructionLabel(LayerConstruction.none), 'Not declared');
      expect(constructionLabel(LayerConstruction.doubleWidthFoldRight),
          'Double width, fold on the right');
      expect(useAsLabel(LayerConstruction.tube), 'Use as a tube');
      expect(useAsLabel(LayerConstruction.doubleWidthFoldLeft),
          'Use as double width, fold on the left');
      expect(useAsLabel(LayerConstruction.twoLayers), 'Use as two independent layers');
    });
  });

  group('top face', () {
    PickLayers layersOf(DraftDoc d) => classifyPicks(d, const {1, 3});

    test('only with every pick on a layer, a declared matching construction, and clean layers', () {
      final ok = doubleWidthLeft().copyWith(construction: LayerConstruction.doubleWidthFoldLeft);
      expect(topFaceUnavailable(ok, layersOf(ok)), isNull);
      // No layer role on one pick.
      final unroled = ok.copyWith(pickRoles: [
        ...cycle(const [T, B, B, T], 7),
        PickRole.unknown
      ]);
      expect(topFaceUnavailable(unroled, layersOf(unroled)),
          'Ply shows the top face only when every pick is marked top layer or bottom layer.');
      // Not declared.
      final undeclared = doubleWidthLeft();
      expect(topFaceUnavailable(undeclared, layersOf(undeclared)),
          'Ply shows the top face only when a construction is declared.');
      // Declared but the edges disagree.
      final wrong = doubleWidthLeft().copyWith(construction: LayerConstruction.tube);
      expect(topFaceUnavailable(wrong, layersOf(wrong)),
          'Ply shows the top face only when the edges match the declared construction.');
      // A stitching pick (a top pick that lifts a bottom shaft) or a shaft assignment that puts a
      // pick on the wrong layer makes the face undecidable.
      final stitched = ok.copyWith(
          drive: DraftTreadled(tieup: const [
        [1, 2],
        [1, 2, 3],
        [3],
        [1, 3, 4],
      ], treadling: [
        for (final t in cycle(const [1, 2, 4, 3], 8)) [t],
      ]));
      expect(
          topFaceUnavailable(stitched, layersOf(stitched)),
          'With these top-layer shafts, picks 1 and 5 do not weave the layer they are marked for, so '
          'the face cannot be told from the draft.');
      expect(topFaceUnavailable(ok, classifyPicks(ok, const {1, 2})),
          contains('With these top-layer shafts'));
    });

    test('a draft with no picks has none', () {
      expect(topFaceUnavailable(DraftDoc.blank(), classifyPicks(DraftDoc.blank(), const {1, 3})),
          'This draft has no picks yet.');
    });
  });

  group('tracked fixtures (fixtures/weaving/doubleweave/)', () {
    for (final (name, construction) in const [
      ('independent-layers', LayerConstruction.twoLayers),
      ('tube', LayerConstruction.tube),
      ('double-width-fold-left', LayerConstruction.doubleWidthFoldLeft),
      ('double-width-fold-right', LayerConstruction.doubleWidthFoldRight),
    ]) {
      test('$name: the twin derives the oracle\'s edges and turns', () {
        final expect_ =
            jsonDecode(File('../fixtures/weaving/doubleweave/$name.expect.json').readAsStringSync())
                as Map<String, dynamic>;
        List<int> nums(String key) => [for (final n in expect_[key] as List) n as int];
        final roles = [
          for (final c in (expect_['roles'] as String).split('')) c == 'T' ? T : B,
        ];
        final starts = {
          for (final e in (expect_['shuttle_starts'] as Map<String, dynamic>).entries)
            int.parse(e.key): e.value == 'left' ? L : R,
        };
        final doc = DraftDoc.blank(shafts: 4, treadles: 4).copyWith(
          threading: [
            for (final s in nums('threading')) [s],
          ],
          drive: DraftTreadled(
            tieup: [
              for (final row in expect_['tieup'] as List) [for (final s in row as List) s as int],
            ],
            treadling: [
              for (final t in nums('treadling')) [t],
            ],
          ),
          pickRoles: roles,
          pickShuttles: nums('shuttles'),
          shuttleStarts: starts,
          construction: construction,
        );
        final e = deriveEdges(doc) as EdgesKnown;
        String word(EdgeBehavior b) => switch (b) {
              EdgeBehavior.open => 'open',
              EdgeBehavior.joined => 'joined',
              EdgeBehavior.mixed => 'mixed',
              EdgeBehavior.noTurns => 'no turns',
            };
        expect(word(e.left), expect_['edges']['left']);
        expect(word(e.right), expect_['edges']['right']);
        expect([
          for (final t in e.turns)
            '${t.from + 1}-${t.to + 1} ${t.side == L ? 'left' : 'right'} ${t.joins ? 'joins' : 'open'}',
        ], expect_['turns']);
        expect(e.construction, construction);
        expect(constructionIssues(doc), isEmpty);
        expect(topFaceUnavailable(doc, classifyPicks(doc, const {1, 3})), isNull);
      });
    }
  });

  test('the construction is part of value equality and crosses the DTO mapping', () {
    final repo = DraftRepository();
    final doc = doubleWidthLeft().copyWith(construction: LayerConstruction.doubleWidthFoldLeft);
    expect(doc, isNot(doubleWidthLeft()));
    expect(doc.copyWith(construction: LayerConstruction.none), doubleWidthLeft());
    expect(doc.hashCode, isNot(doubleWidthLeft().hashCode));
    for (final c in LayerConstruction.values) {
      final d = doc.copyWith(construction: c);
      expect(repo.fromDto(repo.toDto(d)), d, reason: '$c');
    }
    expect(repo.toDto(doc).construction, LayerConstructionKind.doubleWidthFoldLeft);
    expect(repo.toDto(DraftDoc.blank()).construction, LayerConstructionKind.none);
  });
}
