import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/weave_plan_repository.dart';
import 'package:ply/src/models/draft_meta.dart';
import 'package:ply/src/models/loom_profile.dart' show DentUnit, Reed;
import 'package:ply/src/models/material_record.dart';
import 'package:ply/src/models/weave_plan.dart';
import 'package:ply/src/screens/weave_plan_screen.dart' show prefillNumber;

// The warp and weft plan record (ADR 0019): the shape the sidecar keeps under `weavePlan`, read the
// same way as the engine reads the fixtures, forward-safe (unknown keys kept, a newer plan left as
// it is), and pointed at restored copies the way the project's links are.

Map<String, dynamic> fixture(String name) =>
    jsonDecode(File('../fixtures/weaving/plans/$name.plan.json').readAsStringSync())
        as Map<String, dynamic>;

DraftMeta meta({WeavePlan? plan, Map<String, Object?> extra = const {}}) => DraftMeta(
      name: 'Towels',
      savedAt: DateTime.utc(2026, 11, 16),
      lastOpened: DateTime.utc(2026, 11, 16),
      weavePlan: plan,
      extra: extra,
    );

void main() {
  group('the fixtures', () {
    for (final name in ['towel', 'scarf']) {
      test('$name: every case reads and writes back exactly as the engine reads it', () {
        final cases = fixture(name)['cases'] as List;
        expect(cases, isNotEmpty);
        for (final c in cases.cast<Map<String, dynamic>>()) {
          final json = c['plan'] as Map<String, dynamic>;
          final plan = WeavePlan.fromJson(json);
          expect(plan, isNotNull, reason: c['name'] as String);
          expect(jsonDecode(jsonEncode(plan!.toJson())), json, reason: c['name'] as String);
          expect(plan.extra, isEmpty, reason: 'every key of ${c['name']} is known');
        }
      });
    }

    test('the towel plan holds what the fixture record describes', () {
      final cases = (fixture('towel')['cases'] as List).cast<Map<String, dynamic>>();
      final plan = WeavePlan.fromJson(cases.first['plan'])!;
      expect(plan.structure, PlanStructure.twill);
      expect(plan.items, 4);
      expect(plan.finishedWidth, const Length(18, LengthUnit.inch));
      expect(plan.hems, const Length(4, LengthUnit.inch));
      expect(plan.endMultiple, 4);
      expect(plan.extraEnds, 2);
      expect(plan.swatchId, 'sw-towel-plan');
      expect(plan.overrides.value<Length>(PlanAssumption.loomWaste),
          const Length(27, LengthUnit.inch));
      final overridden = WeavePlan.fromJson(cases[1]['plan'])!;
      expect(overridden.overrides.value<double>(PlanAssumption.takeUp), 0.12);
    });
  });

  group('the record', () {
    test('unknown keys, in the plan and its overrides, are kept and written back', () {
      final json = {
        'version': 1,
        'structure': 'satin',
        'items': 2,
        'laterKey': {'a': 1},
        'items2': 3,
        'overrides': {'takeUp': 0.1, 'futureThing': true, 'sett': 'not a sett'},
      };
      final plan = WeavePlan.fromJson(json)!;
      expect(plan.structure, PlanStructure.satin);
      expect(plan.overrides.value<double>(PlanAssumption.takeUp), 0.1);
      expect(plan.overrides.has(PlanAssumption.sett), isFalse,
          reason: 'a value it cannot read is not used');
      expect(plan.toJson(), json, reason: 'and every key goes back as it was');
      // Setting the key a value could not be read under replaces that value.
      final set = plan.copyWith(
          overrides: plan.overrides
              .set(PlanAssumption.sett, const CountOver(20, Length(1, LengthUnit.inch))));
      expect((set.toJson()['overrides'] as Map)['sett'], {
        'count': 20.0,
        'over': {'value': 1.0, 'unit': 'in'}
      });
      expect((set.toJson()['overrides'] as Map)['futureThing'], true);
    });

    test('a plan of another version is not read', () {
      expect(WeavePlan.fromJson({'version': 2, 'items': 1}), isNull);
      expect(WeavePlan.fromJson({'items': 1}), isNull);
      expect(WeavePlan.fromJson('plan'), isNull);
    });

    test('overrides that are not an object make the plan unreadable, and the sidecar keeps them',
        () {
      for (final bad in ['x', null, 3, []]) {
        final json = {'version': 1, 'items': 2, 'overrides': bad};
        expect(WeavePlan.fromJson(json), isNull, reason: '$bad');
        final m = DraftMeta.fromJson(
            {'name': 'T', 'savedAt': '2026-11-16T00:00:00.000Z', WeavePlan.key: json});
        expect(m.hasUnreadablePlan, isTrue);
        // Every rewrite (an open, a rename) writes it back as it was.
        expect(m.copyWith(lastOpened: DateTime.utc(2027)).toJson()[WeavePlan.key], json);
      }
      // A plan with no overrides key at all is read, with none.
      expect(WeavePlan.fromJson({'version': 1, 'items': 2})!.overrides.values, isEmpty);
    });

    test('counts the engine does not take are reported, never clamped into range', () {
      final dto = WeavePlanRepository.planToDto(
          WeavePlan(items: 0, extraEnds: -3, endMultiple: -1, overrides: PlanOverrides()));
      expect(dto.items, 0, reason: 'the engine reports 0 items as out of range');
      expect(dto.extraEnds, WeavePlan.maxCount + 1);
      expect(dto.endMultiple, WeavePlan.maxCount + 1);
      final big = WeavePlanRepository.planToDto(WeavePlan(items: 1 << 40));
      expect(big.items, WeavePlan.maxCount + 1);
      final ok = WeavePlanRepository.planToDto(WeavePlan(items: 4, extraEnds: 2));
      expect((ok.items, ok.extraEnds), (4, 2));
    });

    test('a value starts its field rounded, not with float noise', () {
      expect(prefillNumber(0.07 * 100), '7');
      expect(prefillNumber(12.5), '12.5');
      expect(prefillNumber(2.4000000000000004), '2.4');
      expect(prefillNumber(-5), '-5');
      expect(prefillNumber(0), '0');
    });

    test('an override and the way back', () {
      var plan = WeavePlan(structure: PlanStructure.twill);
      expect(plan.overrides.has(PlanAssumption.takeUp), isFalse);
      plan = plan.copyWith(overrides: plan.overrides.set(PlanAssumption.takeUp, 0.12));
      expect(plan.toJson()['overrides'], {'takeUp': 0.12});
      plan = plan.copyWith(
          overrides: plan.overrides
              .set(PlanAssumption.reed, const Reed(40, DentUnit.per10cm))
              .set(PlanAssumption.ends, 360));
      expect(plan.toJson()['overrides'], {
        'takeUp': 0.12,
        'ends': 360,
        'reed': {'dents': 40.0, 'per': '10cm'},
      });
      expect(WeavePlan.fromJson(jsonDecode(jsonEncode(plan.toJson()))), plan);
      plan = plan.copyWith(overrides: plan.overrides.set(PlanAssumption.takeUp, null));
      expect(plan.overrides.has(PlanAssumption.takeUp), isFalse);
      expect((plan.toJson()['overrides'] as Map).containsKey('takeUp'), isFalse);
    });

    test('copyWith clears what it is told to, and keeps the rest', () {
      final plan = WeavePlan(
          finishedWidth: const Length(25, LengthUnit.centimeter),
          swatchId: 's',
          swatchName: 'Sample',
          extraEnds: 2);
      final cleared = plan.copyWith(clear: {'swatchId', 'swatchName', 'extraEnds'});
      expect(cleared.swatchId, isNull);
      expect(cleared.swatchName, isNull);
      expect(cleared.extraEnds, 0);
      expect(cleared.finishedWidth, plan.finishedWidth);
      expect(cleared.toJson().containsKey('extraEnds'), isFalse);
    });

    test('each engine input maps to the assumptions it can be overridden by', () {
      expect(PlanAssumption.forInput('length_loss'),
          [PlanAssumption.takeUp, PlanAssumption.lengthShrinkage]);
      expect(PlanAssumption.forInput('width_loss'),
          [PlanAssumption.drawIn, PlanAssumption.widthShrinkage]);
      expect(PlanAssumption.forInput('sett'), [PlanAssumption.sett, PlanAssumption.wpi]);
      expect(PlanAssumption.forInput('finished_width'), isEmpty);
    });
  });

  group('in the sidecar', () {
    test('a plan is saved with the draft and read back', () {
      final plan = WeavePlan.fromJson(
          (fixture('scarf')['cases'] as List).cast<Map<String, dynamic>>().last['plan'])!;
      final json = jsonDecode(jsonEncode(meta(plan: plan).toJson())) as Map<String, dynamic>;
      expect(json[WeavePlan.key], plan.toJson());
      final back = DraftMeta.fromJson(json);
      expect(back.weavePlan, plan);
      expect(back.hasUnreadablePlan, isFalse);
      expect(back, meta(plan: plan));
    });

    test('an old draft without a plan opens and saves exactly as before', () {
      final dir = Directory('../fixtures/migrations/sidecar/v0.1.7');
      final files = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.json'));
      expect(files, isNotEmpty);
      for (final f in files) {
        final json = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
        final m = DraftMeta.fromJson(json);
        expect(m.weavePlan, isNull, reason: f.path);
        expect(m.hasUnreadablePlan, isFalse);
        expect(m.toJson().containsKey(WeavePlan.key), isFalse, reason: f.path);
      }
    });

    test('a plan from a newer Ply is kept as it is, and not replaced by accident', () {
      final newer = {'version': 2, 'somethingNew': true};
      final m = DraftMeta.fromJson({
        'name': 'Towels',
        'savedAt': '2026-11-16T00:00:00.000Z',
        WeavePlan.key: newer,
      });
      expect(m.weavePlan, isNull);
      expect(m.hasUnreadablePlan, isTrue);
      expect(m.toJson()[WeavePlan.key], newer);
      // A rename or open (another field changed) keeps it.
      expect(m.copyWith(name: 'Tea towels').toJson()[WeavePlan.key], newer);
    });

    test('clearing the plan removes the key', () {
      final m = meta(plan: WeavePlan());
      expect(m.toJson().containsKey(WeavePlan.key), isTrue);
      expect(m.copyWith(clearWeavePlan: true).toJson().containsKey(WeavePlan.key), isFalse);
    });
  });

  group('restoring a backup', () {
    test('the plan is pointed at restored copies, every other key kept', () {
      final sidecar = <String, dynamic>{
        'name': 'Towels',
        WeavePlan.key: {
          'version': 1,
          'items': 4,
          'swatchId': 's1',
          'swatchName': 'Towel sample',
          'warpMaterialId': 'm1',
          'warpMaterialName': 'Cotton',
          'weftMaterialId': 'm2',
          'weftMaterialName': 'Blue',
          'overrides': {'takeUp': 0.12},
          'later': 1,
        },
      };
      final ids = WeavePlan.idsIn(sidecar);
      expect(ids.materials, {'m1', 'm2'});
      expect(ids.swatches, {'s1'});
      final out = WeavePlan.relinked(sidecar, {'m1': ('m1-copy', 'Cotton (restored)')},
          {'s1': ('s1-copy', 'Towel sample (restored)')});
      final plan = out[WeavePlan.key] as Map;
      expect(plan['swatchId'], 's1-copy');
      expect(plan['swatchName'], 'Towel sample (restored)');
      expect(plan['warpMaterialId'], 'm1-copy');
      expect(plan['warpMaterialName'], 'Cotton (restored)');
      expect(plan['weftMaterialId'], 'm2', reason: 'not restored as a copy: unchanged');
      expect(plan['overrides'], {'takeUp': 0.12});
      expect(plan['later'], 1);
      expect(out['name'], 'Towels');
      // A plan this build cannot read (a newer version) is left exactly as it is.
      final newer = <String, dynamic>{
        'name': 'Towels',
        WeavePlan.key: {
          'version': 2,
          'swatchId': 's1',
          'swatchName': 'Towel sample',
          'warpMaterialId': 'm1',
        },
      };
      expect(
          WeavePlan.relinked(newer, {'m1': ('m1-copy', 'Cotton (restored)')},
              {'s1': ('s1-copy', 'Towel sample (restored)')}),
          newer);
      expect(WeavePlan.idsIn(newer).materials, isEmpty);
      final odd = <String, dynamic>{
        WeavePlan.key: {'version': 1, 'swatchId': 's1', 'overrides': 'x'},
      };
      expect(WeavePlan.relinked(odd, const {}, {'s1': ('c', 'n')}), odd);
      // A sidecar without a plan is returned as it is.
      expect(WeavePlan.relinked({'name': 'x'}, {'m1': ('a', 'b')}, const {}), {'name': 'x'});
      expect(WeavePlan.idsIn({'name': 'x'}).materials, isEmpty);
      expect(WeavePlan.idsIn({'name': 'x'}).swatches, isEmpty);
    });
  });
}
