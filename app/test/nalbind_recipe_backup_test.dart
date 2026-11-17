import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:ply/src/data/library_backup.dart';
import 'package:ply/src/models/nalbind_project.dart';
import 'package:ply/src/models/native_format.dart';

import 'backup_test_support.dart';
import 'nalbind_recipe_test_support.dart';

// Nalbinding recipes survive a library backup and restore (the M8 exit gate, ADR 0017): the
// project's `.plynal` (schema version 3, its recipe and ticks inside) comes back byte for byte, a
// renamed copy keeps its recipe, and a backup whose recipe this build cannot read is refused
// rather than restored without it.

void main() {
  setUp(() async {
    docs = await Directory.systemTemp.createTemp('recipe_backup_docs');
    work = await Directory.systemTemp.createTemp('recipe_backup_work');
  });
  tearDown(() async {
    await docs.delete(recursive: true);
    await work.delete(recursive: true);
  });

  Future<Directory> library() async {
    final source = await Directory.systemTemp.createTemp('recipe_backup_src');
    addTearDown(() => source.delete(recursive: true));
    await put(
        source, 'nalbinds/m1.plynal', utf8.encode(recipeFixtureText('mitten-cuff-up', 'plynal')));
    await put(source, 'nalbinds/m1.json', sidecar('Cuff-up mittens', 'Nalbinding'));
    await put(
        source, 'nalbinds/h1.plynal', utf8.encode(recipeFixtureText('hat-centre-start', 'plynal')));
    await put(source, 'nalbinds/h1.json', sidecar('Crown-down hat', 'Nalbinding'));
    return source;
  }

  test('a backup restores every recipe byte for byte, ticks included', () async {
    final source = await library();
    final archive = await backUp(service(into: source));
    final s = service();
    final plan = await s.inspectBackup(archive);
    expect(plan.projects.every((p) => p.status == RestoreStatus.add), isTrue);
    final result = await s.restore(plan);
    expect(result.count, 2);
    for (final (id, name) in [('m1', 'mitten-cuff-up'), ('h1', 'hat-centre-start')]) {
      final restored = File(p.join(docs.path, 'nalbinds', '$id.plynal')).readAsStringSync();
      expect(restored, recipeFixtureText(name, 'plynal'), reason: name);
      expect(NalbindProject.decode(restored).recipe, recipeFixture(name).recipe);
    }
    expect(
        NalbindProject.decode(File(p.join(docs.path, 'nalbinds', 'h1.plynal')).readAsStringSync())
            .recipe!
            .doneInOrder,
        ['segment-1', 'segment-2']);
  });

  test('a renamed copy (a conflict) keeps its recipe', () async {
    final source = await library();
    final archive = await backUp(service(into: source));
    // The same project already in the library, changed since: the restore keeps both.
    await put(docs, 'nalbinds/m1.plynal',
        utf8.encode(jsonEncode(recipeFixture('mitten-cuff-up').withRecipe(null).toJson())));
    await put(docs, 'nalbinds/m1.json', sidecar('Cuff-up mittens', 'Nalbinding'));
    final s = service();
    final plan = await s.inspectBackup(archive);
    final mitten = plan.projects.firstWhere((p) => p.id == 'm1');
    expect(mitten.status, RestoreStatus.conflict);
    await s.restore(plan);
    final copies = Directory(p.join(docs.path, 'nalbinds'))
        .listSync()
        .whereType<File>()
        .where((f) =>
            f.path.endsWith('.plynal') &&
            !f.path.endsWith('m1.plynal') &&
            !f.path.endsWith('h1.plynal'))
        .toList();
    expect(copies, hasLength(1));
    final copy = NalbindProject.decode(copies.single.readAsStringSync());
    expect(copy.name, isNot('Cuff-up mittens'), reason: 'the copy is renamed');
    expect(copy.recipe, recipeFixture('mitten-cuff-up').recipe, reason: 'and keeps its recipe');
    expect(
        NalbindProject.decode(File(p.join(docs.path, 'nalbinds', 'm1.plynal')).readAsStringSync())
            .recipe,
        isNull,
        reason: 'the original is untouched');
  });

  test('a recipe this build cannot read is refused, never restored without it', () async {
    final source = await Directory.systemTemp.createTemp('recipe_backup_bad');
    addTearDown(() => source.delete(recursive: true));
    final json = jsonDecode(recipeFixtureText('mitten-cuff-up', 'plynal')) as Map<String, dynamic>;
    ((json['recipe'] as Map<String, dynamic>)['segments'] as List)[0]['work'] = {'kind': 'weaveIn'};
    await put(source, 'nalbinds/x1.plynal', utf8.encode(jsonEncode(json)));
    await put(source, 'nalbinds/x1.json', sidecar('Odd', 'Nalbinding'));
    expect(() => NalbindProject.decode(jsonEncode(json)), throwsA(isA<NativeFormatException>()));
    final archive = await backUp(service(into: source));
    final plan = await service().inspectBackup(archive);
    final odd = plan.projects.single;
    expect(odd.status, RestoreStatus.refused);
    expect(odd.refusal, RestoreRefusal.unreadable);
  });
}
