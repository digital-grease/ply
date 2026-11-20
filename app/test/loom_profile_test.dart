import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/loom_repository.dart';
import 'package:ply/src/models/draft_doc.dart';
import 'package:ply/src/models/draft_meta.dart';
import 'package:ply/src/models/loom_check.dart';
import 'package:ply/src/models/loom_profile.dart';
import 'package:ply/src/models/loom_type.dart';
import 'package:ply/src/rust/dto.dart' show UnitKind;
import 'package:ply/src/rust/loom_dto.dart' as wire;

import 'loom_test_support.dart';

void main() {
  group('LoomProfile', () {
    test('unknown fields stay unknown and the summary lists only what is recorded', () {
      expect(const LoomProfile(id: 'a').summary, 'Nothing recorded yet');
      expect(borrowedLoom.summary, '8 shafts');
      expect(floorLoom.summary, 'Jack (floor loom), 4 shafts, 6 treadles, 24 in wide, 1 reed');
      expect(const LoomProfile(id: 'a', name: '  ').displayName, 'Unnamed loom');
    });

    test('copyWith sets and clears each optional field', () {
      final cleared = floorLoom.copyWith(
        clearType: true,
        clearShafts: true,
        clearTreadles: true,
        clearWeavingWidth: true,
        clearTreadlesAtOnce: true,
        reeds: const [],
      );
      expect(cleared.type, isNull);
      expect(cleared.shafts, isNull);
      expect(cleared.treadles, isNull);
      expect(cleared.weavingWidth, isNull);
      expect(cleared.treadlesAtOnce, isNull);
      expect(cleared.reeds, isEmpty);
      expect(cleared.copyWith(shafts: 8).shafts, 8);
      expect(floorLoom.copyWith(), floorLoom);
      expect(floorLoom.copyWith(name: 'Other') == floorLoom, isFalse);
    });

    test('numbers read as a weaver writes them', () {
      expect(formatLoomNumber(12), '12');
      expect(formatLoomNumber(12.04), '12');
      expect(formatLoomNumber(20.32), '20.3');
      expect(const Reed(40, DentUnit.per10cm).label, '40 dents per 10 cm');
      expect(const Reed(12, DentUnit.perInch).shortLabel, '12-dent');
      expect(const LoomLength(91.4, MeasureUnit.centimeters).label, '91.4 cm');
    });
  });

  group('LoomPlan in the sidecar', () {
    test('round-trips, and keeps keys a later build adds', () {
      final plan = LoomPlan.fromJson({
        'loomId': 'loom-floor',
        'loomName': 'Floor loom',
        'sett': {'ends': 24, 'per': 'inch'},
        'denting': {'later': true},
      })!;
      expect(plan.sett, const Sett(24, MeasureUnit.inches));
      expect(plan.extra, {
        'denting': {'later': true}
      });
      expect(plan.toJson(), {
        'loomId': 'loom-floor',
        'loomName': 'Floor loom',
        'sett': {'ends': 24.0, 'per': 'inch'},
        'denting': {'later': true},
      });
      // A sett this build cannot read is kept verbatim, not lost.
      final odd = LoomPlan.fromJson({
        'loomId': 'x',
        'loomName': 'X',
        'sett': {'ends': 'many', 'per': 'furlong'},
      })!;
      expect(odd.sett, isNull);
      expect(odd.toJson()['sett'], {'ends': 'many', 'per': 'furlong'});
      // Setting a sett replaces the kept value.
      expect(odd.copyWith(sett: const Sett(10, MeasureUnit.centimeters)).toJson()['sett'],
          {'ends': 10.0, 'per': 'cm'});
      expect(LoomPlan.fromJson({'loomName': 'no id'}), isNull);
      expect(LoomPlan.fromJson('nope'), isNull);
    });

    test('DraftMeta reads, writes and clears it; an unreadable value is kept', () {
      final meta = DraftMeta(
        name: 'Twill',
        savedAt: DateTime.utc(2026),
        lastOpened: DateTime.utc(2026),
        loomPlan: LoomPlan(loomId: 'loom-floor', loomName: 'Floor loom'),
      );
      final json = meta.toJson();
      expect(json['loomPlan'], {'loomId': 'loom-floor', 'loomName': 'Floor loom'});
      final back = DraftMeta.fromJson(json);
      expect(back, meta);
      expect(back.loomPlan!.loomId, 'loom-floor');
      // No plan: no key at all (a sidecar without looms is byte-for-byte what it was).
      expect(meta.copyWith(clearLoomPlan: true).toJson().containsKey('loomPlan'), isFalse);
      expect(
          DraftMeta(name: 'x', savedAt: DateTime.utc(2026), lastOpened: DateTime.utc(2026))
              .toJson()
              .containsKey('loomPlan'),
          isFalse);
      // A plan this build cannot read survives a rewrite.
      final weird = DraftMeta.fromJson({
        'name': 'x',
        'savedAt': '2026-01-01T00:00:00.000Z',
        'loomPlan': {'loom': 'from the future'},
      });
      expect(weird.loomPlan, isNull);
      expect(weird.copyWith(lastOpened: DateTime.utc(2027)).toJson()['loomPlan'],
          {'loom': 'from the future'});
      // ...until this build sets one.
      expect(weird.copyWith(loomPlan: LoomPlan(loomId: 'a', loomName: 'A')).toJson()['loomPlan'],
          {'loomId': 'a', 'loomName': 'A'});
    });

    test('a sett outside the range the engine takes is not valid', () {
      expect(const Sett(24, MeasureUnit.inches).isValid, isTrue);
      expect(const Sett(0, MeasureUnit.inches).isValid, isFalse);
      expect(const Sett(500, MeasureUnit.centimeters).isValid, isFalse);
      expect(const Sett(double.nan, MeasureUnit.inches).isValid, isFalse);
      expect(Sett.fromJson({'ends': 0, 'per': 'inch'}), isNull);
      expect(const Sett(10, MeasureUnit.centimeters).label, '10 ends per cm');
    });
  });

  group('LoomReport', () {
    test('the headline names the first conflict, or says it fits', () {
      expect(notFeasibleReport.headline, 'On Floor loom: not feasible, needs 8 shafts, has 4');
      expect(notFeasibleReport.feasible, isFalse);
      expect([for (final d in notFeasibleReport.sorted) d.code],
          ['loom.shafts_exceeded', 'loom.reed_unknown', 'loom.width_fits']);
      LoomDiagnostic d(LoomSeverity s, [String summary = 's']) =>
          LoomDiagnostic(code: 'c', severity: s, summary: summary, message: 'm');
      LoomReport r(List<LoomDiagnostic> ds) => LoomReport(loomName: 'Floor loom', diagnostics: ds);
      expect(r([d(LoomSeverity.fits)]).headline, 'On Floor loom: fits');
      expect(r([d(LoomSeverity.fits), d(LoomSeverity.advice)]).headline,
          'On Floor loom: fits, 1 note');
      expect(
          r([d(LoomSeverity.advice), d(LoomSeverity.notChecked), d(LoomSeverity.notChecked)])
              .headline,
          'On Floor loom: fits so far, 1 note, 2 not checked');
      expect(r([d(LoomSeverity.notFeasible, 'a'), d(LoomSeverity.notFeasible, 'b')]).headline,
          'On Floor loom: not feasible, a (and 1 more)');
    });
  });

  group('DTO mapping', () {
    test('a profile maps to the wire and back, unknowns included', () {
      for (final loom in [
        floorLoom,
        borrowedLoom,
        const LoomProfile(
            id: 'm',
            type: LoomType.countermarch,
            reeds: [Reed(40, DentUnit.per10cm)],
            weavingWidth: LoomLength(100, MeasureUnit.centimeters)),
      ]) {
        final dto = LoomRepository.loomToDto(loom);
        expect(LoomRepository.loomFromDto(dto), loom);
      }
      final dto = LoomRepository.loomToDto(borrowedLoom);
      expect(dto.kind, wire.LoomTypeKind.unknown);
      expect(dto.treadles, isNull, reason: 'unknown is not zero');
      expect(dto.reeds, isEmpty);
      for (final t in [null, ...LoomType.values]) {
        expect(LoomRepository.typeFromKind(LoomRepository.kindFromType(t)), t);
      }
    });

    test('a report maps from the wire with its codes, locations and sett', () {
      final r = LoomRepository.reportFromDto(wire.LoomReportDto(
        loomName: 'Floor loom',
        diagnostics: [
          wire.LoomDiagnosticDto(
            code: 'loom.shafts_exceeded',
            severity: wire.LoomSeverityKind.notFeasible,
            summary: 'needs 8 shafts, has 4',
            message: 'This draft threads 8 shafts; Floor loom has 4.',
            location: wire.LoomLocationDto(
                kind: wire.LoomLocationKind.shafts,
                numbers: Uint32List.fromList([5, 6, 7, 8]),
                total: 4),
            remediation: 'Weave it on a loom with at least 8 shafts.',
          ),
        ],
        sett: const wire.SettDto(ends: 20, per: UnitKind.inches),
        settSource: wire.SettSourceKind.file,
        fileSett: const wire.SettDto(ends: 20, per: UnitKind.inches),
        reedWidth: const wire.LengthDto(value: 0.8, unit: UnitKind.inches),
      ));
      expect(r.headline, 'On Floor loom: not feasible, needs 8 shafts, has 4');
      expect(r.diagnostics.single.location,
          const LoomLocation(kind: LoomLocationKind.shafts, numbers: [5, 6, 7, 8], total: 4));
      expect(r.settSource, SettSource.file);
      expect(r.sett, const Sett(20, MeasureUnit.inches));
      expect(r.reedWidth, const LoomLength(0.8, MeasureUnit.inches));
      expect(
          LoomRepository.settFromDto(
              LoomRepository.settToDto(const Sett(9, MeasureUnit.centimeters))),
          const Sett(9, MeasureUnit.centimeters));
    });
  });

  group('the looms.json envelope', () {
    test('the tracked fixture states the format and version this build reads, as the engine does',
        () {
      final text = File('../fixtures/weaving/looms/looms.json').readAsStringSync();
      expect(statedVersion(text, kLoomsFormat), 1);
      expect(statedVersion(text, kLoomsFormat), kLoomsSchemaVersion);
    });

    test("the stand-ins' rule: anything that is not an envelope of the format has no version", () {
      // Many tests rely on it (the stand-in codecs check it first, as the engine does).
      expect(
          statedVersion('{"format":"ply.looms","schema_version":2,"looms":"later"}', kLoomsFormat),
          2);
      expect(statedVersion('{"format":"ply.knit","schema_version":1}', kLoomsFormat), isNull,
          reason: 'another format');
      expect(statedVersion('{"schema_version":1}', kLoomsFormat), isNull, reason: 'no format');
      expect(statedVersion('{"format":"ply.looms","schema_version":0}', kLoomsFormat), isNull);
      expect(statedVersion('{"format":"ply.looms","schema_version":-1}', kLoomsFormat), isNull);
      expect(statedVersion('{"format":"ply.looms","schema_version":"1"}', kLoomsFormat), isNull);
      expect(statedVersion('{"format":"ply.looms","schema_version":1.5}', kLoomsFormat), isNull);
      expect(statedVersion('{"format":"ply.looms"}', kLoomsFormat), isNull, reason: 'no version');
      expect(statedVersion('[{"format":"ply.looms","schema_version":1}]', kLoomsFormat), isNull,
          reason: 'a list');
      expect(statedVersion('[]', kLoomsFormat), isNull);
      expect(statedVersion('not json', kLoomsFormat), isNull);
      expect(statedVersion('', kLoomsFormat), isNull);
      expect(statedVersion('{"format":"ply.materials","schema_version":3}', 'ply.materials'), 3);
    });
  });
}
