import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/nalbind_repository.dart';
import 'package:ply/src/models/nalbind_project.dart';
import 'package:ply/src/models/nalbind_recipe.dart';
import 'package:ply/src/models/nalbind_recipe_view.dart';
import 'package:ply/src/models/native_format.dart';
import 'package:ply/src/rust/nalbind_recipe_dto.dart';

import 'nalbind_recipe_test_support.dart';

// The nalbinding RECIPE model and `.plynal` schema version 3 (ADR 0017): the recipe's JSON form,
// the v2 -> v3 migration over real version 2 files (fixtures/migrations/plynal/schema-v2/, which
// must open unchanged in meaning and gain no recipe), the acceptance fixtures (written by this
// writer: they decode and re-encode byte for byte), refusal of an unknown segment kind or value
// (never loaded with the segment dropped, never overwritten), stable ids and ticks, the follow
// view's tick written alone into the saved file, and the mapping to the engine's DTO.

Matcher refused(NativeFormatProblem problem) =>
    throwsA(isA<NativeFormatException>().having((e) => e.problem, 'problem', problem));

const _chain = RecipeSegment(
  id: 'segment-1',
  kind: SegmentKind.foundationChain,
  title: 'Cuff start',
  stitch: SegmentStitch(notation: 'UO/UOO F2', name: 'Oslo, F2 connection'),
  stitches: 36,
  chainJoin: ChainJoin.ring,
  notes: 'n',
  caution: 'c',
);

const _rounds = RecipeSegment(
  id: 'segment-2',
  kind: SegmentKind.rounds,
  roundJoin: RoundJoin.spiral,
  extent: Extent.until(Measurement(label: 'from the cuff edge', value: 7, unit: LengthUnit.cm)),
);

NalbindProject _withRecipe(NalbindRecipe r) =>
    NalbindProject(name: 'M', notation: 'UO/UOO F1', stitchName: 'Oslo', recipe: r);

void main() {
  group('schema version 2 files (real bytes, immutable)', () {
    const names = ['mitten-notes', 'typed-notation', 'untitled-empty'];

    test('read as version 2, open unchanged in meaning, and gain no recipe', () {
      for (final n in names) {
        final text = plynalMigration('schema-v2/$n.plynal');
        final json = jsonDecode(text) as Map<String, dynamic>;
        expect(NalbindProject.schemaVersionOf(json), 2, reason: n);
        final p = NalbindProject.decode(text);
        expect(p.recipe, isNull, reason: n);
        expect(p.name, json['name']);
        expect(p.notation, json['notation'], reason: 'kept verbatim, even lowercase');
        expect(p.stitchName, json['stitchName']);
        expect(p.notes, json['notes']);
      }
    });

    test('a re-save is version 3 with exactly the same fields and no recipe key', () {
      for (final n in names) {
        final before = jsonDecode(plynalMigration('schema-v2/$n.plynal')) as Map<String, dynamic>;
        final after = NalbindProject.decode(plynalMigration('schema-v2/$n.plynal')).toJson();
        expect(after['schemaVersion'], 3);
        expect(after.containsKey('recipe'), isFalse);
        expect({...after}..remove('schemaVersion'), {...before}..remove('schemaVersion'),
            reason: '$n: the migration is the identity on the fields');
      }
    });

    test('a stray recipe key in a version 2 file (which no writer produced) is ignored', () {
      final json =
          jsonDecode(plynalMigration('schema-v2/mitten-notes.plynal')) as Map<String, dynamic>;
      json['recipe'] = {'segments': 'not even a list'};
      expect(NalbindProject.fromJson(json).recipe, isNull);
    });

    test('released v0.1.7 files still load, without a recipe', () {
      final p = NalbindProject.decode(plynalMigration('v0.1.7/oslo-mittens.plynal'));
      expect(p.name, 'Oslo mittens');
      expect(p.recipe, isNull);
    });

    test('a released app reads a version 3 file with its fields (only the recipe is lost)', () {
      // The rule behind the inline version keys (ADR 0002): a released reader loads every field.
      final json =
          jsonDecode(recipeFixtureText('mitten-cuff-up', 'plynal')) as Map<String, dynamic>;
      final released = NalbindProject(
        name: (json['name'] as String?) ?? '',
        notation: (json['notation'] as String?) ?? '',
        stitchName: (json['stitchName'] as String?) ?? '',
        notes: (json['notes'] as String?) ?? '',
      );
      expect(released, recipeFixture('mitten-cuff-up').withRecipe(null));
    });
  });

  group('the recipe fixtures', () {
    test('are current version 3 files with a recipe, written by this writer byte for byte', () {
      for (final name in kRecipeFixtures) {
        final text = recipeFixtureText(name, 'plynal');
        final p = NalbindProject.decode(text);
        expect(NalbindProject.schemaVersionOf(jsonDecode(text) as Map<String, dynamic>), 3);
        expect(p.recipe, isNotNull, reason: name);
        expect(jsonEncode(p.toJson()), text, reason: '$name re-saves to the same bytes');
        expect(p.recipe!.doneInOrder, recipeOracle(name)['done'], reason: name);
        final record = recipeFixtureText(name, 'fixture.toml');
        expect(record, contains('practitioner_nalbind_check = "pending"'), reason: name);
        expect(record, contains('license = "original"'), reason: name);
      }
    });

    test('the mitten has separate start, body, shaping and finish steps and a worked thumb', () {
      final r = recipeFixture('mitten-cuff-up').recipe!;
      expect(r.segments.map((s) => s.phase).toSet(),
          containsAll(RecipePhase.values.where((p) => p != RecipePhase.other)));
      final thumb = r.segments.firstWhere((s) => s.kind == SegmentKind.pickUp);
      final opening = r.segments.firstWhere((s) => s.kind == SegmentKind.opening);
      expect(thumb.reference, opening.id);
    });
  });

  group('the recipe JSON form', () {
    test('a segment writes only its kind\'s fields, and round-trips', () {
      final json = _chain.toJson();
      expect(json['work'], {'kind': 'foundationChain', 'stitches': 36, 'join': 'ring'});
      expect(json['stitch'],
          {'notation': 'UO/UOO F2', 'name': 'Oslo, F2 connection', 'reading': 'strict'});
      expect(RecipeSegment.fromJson(json), _chain);
      expect(_rounds.toJson()['work'], {
        'kind': 'rounds',
        'worked': 'spiral',
        'extent': {
          'type': 'until',
          'measure': {'label': 'from the cuff edge', 'value': 7.0, 'unit': 'cm'},
        },
      });
      expect(RecipeSegment.fromJson(_rounds.toJson()), _rounds);
    });

    test('every kind round-trips through the project file', () {
      for (final kind in SegmentKind.values) {
        final s = RecipeSegment(id: 'segment-1', kind: kind, role: RecipePhase.body, text: 't');
        final p = _withRecipe(NalbindRecipe(segments: [s]));
        final back = NalbindProject.decode(jsonEncode(p.toJson()));
        expect(back.recipe!.segments.single.kind, kind);
        expect(jsonEncode(back.toJson()), jsonEncode(p.toJson()), reason: kind.json);
      }
    });

    test('missing optional fields read as not stated; a partial recipe loads', () {
      final r = NalbindRecipe.fromJson({
        'segments': [
          {
            'work': {'kind': 'centreStart'},
          },
        ],
      });
      final s = r.segments.single;
      expect(s.id, '', reason: 'the engine reports a missing id; the file still opens');
      expect(s.stitches, isNull);
      expect(s.stitch, isNull);
      expect(r.fit, isEmpty);
      expect(r.done, isEmpty);
    });

    test('an unknown segment kind or value is refused, never dropped or overwritten', () async {
      String withWork(Map<String, Object?> work) => jsonEncode({
            ..._withRecipe(const NalbindRecipe(segments: [_chain])).toJson(),
            'recipe': {
              'fit': <Object>[],
              'segments': [
                {..._chain.toJson(), 'work': work},
              ],
              'done': <Object>[],
            },
          });
      for (final work in [
        {'kind': 'weaveIn'},
        {'kind': 'finish', 'method': 'felt'},
        {
          'kind': 'rounds',
          'extent': {'type': 'forever'}
        },
        {
          'kind': 'rounds',
          'extent': {'type': 'rounds'}
        },
        {'kind': 'centreStart', 'stitches': -1},
        {'kind': 'centreStart', 'stitches': 2.5},
        {'kind': 'freeform', 'text': 'no role'},
        {'kind': 'opening', 'skip': 'four'},
      ]) {
        expect(() => NalbindProject.decode(withWork(work)), refused(NativeFormatProblem.unreadable),
            reason: '$work');
      }
      // The repository never writes over such a file.
      final dir = await Directory.systemTemp.createTemp('ply_recipe_refuse');
      addTearDown(() => dir.delete(recursive: true));
      final repo = NalbindRepository()..dirOverride = dir;
      final bad = withWork({'kind': 'weaveIn'});
      File('${dir.path}/p1.plynal').writeAsStringSync(bad);
      await expectLater(repo.readProject('p1'), throwsA(isA<NativeFormatException>()));
      await expectLater(repo.saveProject(const NalbindProject(name: 'Mine'), id: 'p1'),
          throwsA(isA<NativeFormatException>().having((e) => e.whileSaving, 'whileSaving', true)));
      expect(File('${dir.path}/p1.plynal').readAsStringSync(), bad);
    });

    test('a length that is not a finite number is refused, as the engine refuses it', () {
      final text = jsonEncode(_withRecipe(const NalbindRecipe(segments: [_rounds])).toJson())
          .replaceFirst('"value":7.0', '"value":1e400');
      expect(text, contains('1e400'));
      expect(() => NalbindProject.decode(text), refused(NativeFormatProblem.unreadable));
    });

    test('numbers show as written, never through a lossy integer', () {
      expect(formatRecipeNumber(20), '20');
      expect(formatRecipeNumber(12.5), '12.5');
      expect(formatRecipeNumber(1e19), '10000000000000000000', reason: 'not 9223372036854775807');
      expect(formatRecipeNumber(1e300), '1e+300');
      expect(double.parse(formatRecipeNumber(1e19)), 1e19, reason: 'reads back the same');
      expect(formatRecipeNumber(9007199254740991), '9007199254740991');
    });

    test('keys this build does not know are kept verbatim at every level', () {
      final json = jsonDecode(
          jsonEncode(_withRecipe(const NalbindRecipe(segments: [_chain, _rounds])).toJson()));
      final recipe = json['recipe'] as Map<String, dynamic>;
      recipe['futureRecipeKey'] = {'a': 1};
      final seg0 = (recipe['segments'] as List)[0] as Map<String, dynamic>;
      seg0['futureSegmentKey'] = [1, 2];
      (seg0['work'] as Map<String, dynamic>)['futureWorkKey'] = 'w';
      (seg0['stitch'] as Map<String, dynamic>)['futureStitchKey'] = true;
      final seg1 = (recipe['segments'] as List)[1] as Map<String, dynamic>;
      final extent = (seg1['work'] as Map<String, dynamic>)['extent'] as Map<String, dynamic>;
      extent['futureExtentKey'] = 3;
      (extent['measure'] as Map<String, dynamic>)['futureMeasureKey'] = null;
      // "stitches" is a key of other kinds, but not of rounds: kept too, not taken as its own.
      (seg1['work'] as Map<String, dynamic>)['stitches'] = 9;
      final text = jsonEncode(json);
      final p = NalbindProject.decode(text);
      expect(p.recipe!.extra, {
        'futureRecipeKey': {'a': 1}
      });
      expect(p.recipe!.segments[0].extra, {
        'futureSegmentKey': [1, 2]
      });
      expect(p.recipe!.segments[0].workExtra, {'futureWorkKey': 'w'});
      expect(p.recipe!.segments[0].stitch!.extra, {'futureStitchKey': true});
      expect(p.recipe!.segments[1].extent!.extra, {'futureExtentKey': 3});
      expect(p.recipe!.segments[1].extent!.measure!.extra, {'futureMeasureKey': null});
      expect(p.recipe!.segments[1].workExtra, {'stitches': 9});
      expect(p.recipe!.segments[1].stitches, isNull);
      expect(jsonEncode(p.toJson()), text, reason: 'written back exactly');
      expect(
          p.recipe!.segments[0].withId('segment-9').extra,
          {
            'futureSegmentKey': [1, 2]
          },
          reason: 'a duplicate keeps them');
    });

    test('a count past what Ply counts still opens (the engine says it is too large)', () {
      final r = NalbindRecipe.fromJson({
        'segments': [
          {
            'id': 'segment-1',
            'work': {'kind': 'centreStart', 'stitches': 4000000000},
          },
        ],
      });
      expect(r.segments.single.stitches, 4000000000);
      expect(
          () => NalbindRecipe.fromJson({
                'segments': [
                  {
                    'id': 'segment-1',
                    'work': {'kind': 'centreStart', 'stitches': 4294967296},
                  },
                ],
              }),
          throwsFormatException,
          reason: 'past what a file can carry');
    });

    test('more segments than the limit is refused; long text is not (a save always reopens)', () {
      Map<String, Object?> seg(int i) => {
            ..._chain.toJson(),
            'id': 'segment-$i',
          };
      expect(
          () => NalbindRecipe.fromJson({
                'segments': [for (var i = 0; i <= kMaxRecipeSegments; i++) seg(i)],
              }),
          throwsFormatException);
      final long = NalbindRecipe.fromJson({
        'segments': [
          {...seg(1), 'notes': 'x' * (kMaxRecipeText * 3)},
        ],
      });
      expect(long.segments.single.notes.length, kMaxRecipeText * 3);
    });
  });

  group('ids and ticks', () {
    test('a new id is one past the highest segment-N, whatever the order', () {
      expect(const NalbindRecipe().nextId(), 'segment-1');
      const r = NalbindRecipe(segments: [
        RecipeSegment(id: 'segment-7', kind: SegmentKind.finish),
        RecipeSegment(id: 'odd', kind: SegmentKind.finish),
        RecipeSegment(id: 'segment-2', kind: SegmentKind.finish),
      ]);
      expect(r.nextId(), 'segment-8');
    });

    test('ticks are written in segment order, only for segments that exist', () {
      const r = NalbindRecipe(
        segments: [_chain, _rounds],
        done: {'segment-2', 'gone', 'segment-1'},
      );
      expect(r.doneInOrder, ['segment-1', 'segment-2']);
      expect(r.toJson()['done'], ['segment-1', 'segment-2']);
      expect(r.withDone('segment-1', false).doneInOrder, ['segment-2']);
      expect(r.withDone('segment-1', true), r);
    });

    test('a tick is written alone into the saved project', () async {
      final dir = await Directory.systemTemp.createTemp('ply_recipe_tick');
      addTearDown(() => dir.delete(recursive: true));
      final repo = NalbindRepository()..dirOverride = dir;
      final id =
          await repo.saveProject(_withRecipe(const NalbindRecipe(segments: [_chain, _rounds])));
      final sidecar = File('${dir.path}/$id.json').readAsStringSync();

      expect(await repo.setSegmentDone(id, 'segment-2', done: true, expected: _rounds), isTrue);
      final saved = await repo.readProject(id);
      expect(saved.recipe!.done, {'segment-2'});
      expect(saved.withRecipe(saved.recipe!.withDone('segment-2', false)),
          _withRecipe(const NalbindRecipe(segments: [_chain, _rounds])),
          reason: 'nothing else changed');
      expect(File('${dir.path}/$id.json').readAsStringSync(), sidecar, reason: 'sidecar untouched');

      expect(
          await repo.setSegmentDone(id, 'segment-9',
              done: true, expected: _rounds.withId('segment-9')),
          isFalse,
          reason: 'a segment the saved recipe does not have is not written');
      expect(await repo.setSegmentDone(id, 'segment-2', done: false, expected: _rounds), isTrue);
      expect((await repo.readProject(id)).recipe!.done, isEmpty);

      final noteOnly = await repo.saveProject(const NalbindProject(name: 'Notes'));
      final before = File('${dir.path}/$noteOnly.plynal').readAsStringSync();
      expect(
          await repo.setSegmentDone(noteOnly, 'segment-1', done: true, expected: _chain), isFalse);
      expect(File('${dir.path}/$noteOnly.plynal').readAsStringSync(), before);
    });

    test('a tick is not written when the saved step with that id is another step', () async {
      final dir = await Directory.systemTemp.createTemp('ply_recipe_tick_other');
      addTearDown(() => dir.delete(recursive: true));
      final repo = NalbindRepository()..dirOverride = dir;
      final id =
          await repo.saveProject(_withRecipe(const NalbindRecipe(segments: [_chain, _rounds])));
      final before = File('${dir.path}/$id.plynal').readAsStringSync();
      // On screen, segment-2 is now a finish (say); the saved segment-2 is the rounds.
      const onScreen = RecipeSegment(id: 'segment-2', kind: SegmentKind.finish);
      expect(await repo.setSegmentDone(id, 'segment-2', done: true, expected: onScreen), isFalse);
      expect(File('${dir.path}/$id.plynal').readAsStringSync(), before, reason: 'nothing written');
    });

    test('a save and a tick never interleave: both land, in order', () async {
      final dir = await Directory.systemTemp.createTemp('ply_recipe_race');
      addTearDown(() => dir.delete(recursive: true));
      final repo = NalbindRepository()..dirOverride = dir;
      final first = _withRecipe(const NalbindRecipe(segments: [_chain, _rounds]));
      final id = await repo.saveProject(first);
      for (var round = 0; round < 20; round++) {
        final renamed = first.copyWith(name: 'Renamed $round');
        // Not awaited one by one: the tick is asked for while the save is writing.
        await Future.wait([
          repo.saveProject(renamed, id: id),
          repo.setSegmentDone(id, 'segment-1', done: round.isEven, expected: _chain),
        ]);
        final onDisk = await repo.readProject(id);
        expect(onDisk.name, 'Renamed $round', reason: 'the save landed');
        expect(onDisk.recipe!.done.contains('segment-1'), round.isEven,
            reason: 'and the tick after it, on top of it');
      }
      expect(Directory(dir.path).listSync().where((f) => f.path.endsWith('.tmp')), isEmpty);
    });

    test('ids are never given twice, across a save and reopen', () async {
      var r = const NalbindRecipe(segments: [_chain, _rounds]);
      final (withThird, third) = r.issueId();
      expect(third, 'segment-3');
      r = withThird.copyWith(segments: [
        ...withThird.segments,
        const RecipeSegment(id: 'segment-3', kind: SegmentKind.finish),
      ]);
      // Delete the newest step: its number is still given.
      r = r.copyWith(segments: r.segments.take(2).toList());
      expect(r.nextId(), 'segment-4', reason: 'segment-3 is not reused');
      final back = NalbindRecipe.fromJson(jsonDecode(jsonEncode(r.toJson())));
      expect(back.lastSegmentNumber, 3, reason: 'the counter is saved');
      expect(back.nextId(), 'segment-4');
      expect(back, r);
      // A file without the counter (or behind it) still never reuses a number in use.
      final old = NalbindRecipe.fromJson({
        'segments': [_chain.toJson(), _rounds.withId('segment-7').toJson()],
      });
      expect(old.nextId(), 'segment-8');
      expect(old.lastSegmentNumber, 7, reason: 'the counter starts at the highest id read');
      final shrunk = old.copyWith(segments: old.segments.take(1).toList());
      expect(shrunk.nextId(), 'segment-8', reason: 'deleting segment-7 does not free its number');
    });

    test('a tick for a step not in the recipe is dropped on reading and cannot be added', () {
      final r = NalbindRecipe.fromJson({
        'segments': [_chain.toJson()],
        'done': ['segment-1', 'segment-5'],
      });
      expect(r.done, {'segment-1'});
      expect(r.withDone('segment-5', true).done, {'segment-1'});
    });

    test('a save and reopen keeps the recipe, its order and its ticks', () async {
      final dir = await Directory.systemTemp.createTemp('ply_recipe_save');
      addTearDown(() => dir.delete(recursive: true));
      final repo = NalbindRepository()..dirOverride = dir;
      final mitten = recipeFixture('mitten-cuff-up');
      final r = mitten.recipe!;
      final moved = r.copyWith(
          segments: [r.segments[1], r.segments[0], ...r.segments.skip(2)], done: {'segment-2'});
      final id = await repo.saveProject(mitten.withRecipe(moved));
      final back = await repo.readProject(id);
      expect(back.recipe, moved);
      expect(back.recipe!.segments.first.id, 'segment-2');
      expect(back.notes, mitten.notes, reason: 'the notes are untouched');
    });
  });

  group('the engine DTO', () {
    test('every field crosses; ticks do not', () {
      final dto = recipeToDto(recipeFixture('mitten-cuff-up').recipe!);
      expect(dto.fit.first.unit, RecipeLengthUnitKind.centimetres);
      final chain = dto.segments.first;
      expect(chain.kind, RecipeKindDto.foundationChain);
      expect(chain.stitch?.notation, 'UO/UOO F2');
      expect(chain.stitch?.reading, RecipeReadingKind.strict);
      expect(chain.stitches, 36);
      expect(chain.chainJoin, RecipeChainJoinKind.ring);
      final opening = dto.segments[3];
      expect((opening.skip, opening.stitches), (7, 9));
      final thumb = dto.segments[7];
      expect(thumb.reference, 'segment-4');
      final top = dto.segments[5];
      expect(top.decreaseMethod, RecipeDecreaseKind.twoLoopsAtOnce);
      expect(top.extent?.kind, RecipeExtentKind.untilStitches);
      expect(top.extent?.count, 10);
      final hat = recipeToDto(recipeFixture('hat-centre-start').recipe!);
      expect(hat.segments.last.kind, RecipeKindDto.freeform);
      expect(hat.segments.last.role, RecipePhaseKind.other);
      expect(hat.segments[2].extent?.measure?.value, 17.0);
      expect(hat.segments[1].increaseMethod, RecipeIncreaseKind.sameLoopTwice);
    });

    test('the oracle reports match their fixtures segment for segment', () {
      for (final name in kRecipeFixtures) {
        final p = recipeFixture(name);
        final report = oracleReport(name);
        expect(report.segments.length, p.recipe!.segments.length, reason: name);
        for (final (i, s) in report.segments.indexed) {
          expect(s.id, p.recipe!.segments[i].id, reason: '$name $i');
        }
      }
    });
  });
}
