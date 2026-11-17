import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/materials_repository.dart';
import 'package:ply/src/models/material_record.dart';

import 'materials_test_support.dart';

// The tracked materials fixture (fixtures/materials, ADR 0016) as the app sees it: the version probe
// reads it as schema version 1, the Dart model reads every field of every record (its engine-shape
// map gives back the very JSON), and the DTO mapping loses nothing.

final Map<String, dynamic> fixture =
    jsonDecode(File('../fixtures/materials/materials.json').readAsStringSync())
        as Map<String, dynamic>;

void main() {
  test('the version probe reads the fixture as schema version 1', () {
    final text = File('../fixtures/materials/materials.json').readAsStringSync();
    expect(materialsFileVersion(text), kMaterialsSchemaVersion);
    expect(materialsFileVersion('{"format":"ply.looms","schema_version":1}'), isNull);
    expect(materialsFileVersion('{"format":"ply.materials","schema_version":2}'), 2);
    expect(materialsFileVersion('not json'), isNull);
  });

  test('the Dart model reads every field of every record', () {
    for (final raw in fixture['materials'] as List) {
      final m = materialFromMap(raw as Map);
      expect(const DeepCollectionEquality().equals(m.toMap(), raw), isTrue,
          reason: '${m.id}: ${m.toMap()} vs $raw');
    }
    for (final raw in fixture['swatches'] as List) {
      final s = swatchFromMap(raw as Map);
      expect(const DeepCollectionEquality().equals(s.toMap(), raw), isTrue,
          reason: '${s.id}: ${s.toMap()} vs $raw');
    }
  });

  test('records survive the DTO mapping', () {
    for (final raw in fixture['materials'] as List) {
      final m = materialFromMap(raw as Map);
      expect(MaterialsRepository.materialFromDto(MaterialsRepository.materialToDto(m)), m);
    }
    for (final raw in fixture['swatches'] as List) {
      final s = swatchFromMap(raw as Map);
      expect(MaterialsRepository.swatchFromDto(MaterialsRepository.swatchToDto(s)), s);
    }
    const lib = MaterialLibrary(materials: [wool, cotton], swatches: [knitSwatch]);
    final back = MaterialsRepository.libraryFromDto(MaterialsRepository.libraryToDto(lib));
    expect(back.materials, lib.materials);
    expect(back.swatches, lib.swatches);
  });

  test('the fixture records read as the crafter wrote them', () {
    final knit = swatchFromMap((fixture['swatches'] as List).first as Map);
    expect(knit.craft, SwatchCraft.knitting);
    expect(knit.after.across!.value.label('sts'), '20 sts per 10 cm');
    expect(knit.planningAcross!.$2, StageKind.after);
    expect(knit.stageName(StageKind.after), 'after finishing');
    final towel = swatchFromMap((fixture['swatches'] as List)[1] as Map);
    expect(towel.isWeaving, isTrue);
    expect(towel.stageName(StageKind.before), 'off the loom');
    expect(towel.sett!.value.label('ends'), '24 ends per in');
    expect(towel.sett!.source, ValueSource.entered);
    final w = materialFromMap((fixture['materials'] as List).first as Map);
    expect(w.summary, contains('200 m per 100 g'));
  });
}
