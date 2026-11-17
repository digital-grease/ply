import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/library_backup.dart';
import 'package:ply/src/models/weave_plan.dart';

import 'backup_test_support.dart';
import 'library_backup_materials_test.dart'
    show materialService, readRecords, sidecarOf, writeRecords;
import 'materials_test_support.dart';

// A weaving draft's warp and weft plan in a library backup (ADR 0019): the plan is part of the
// draft's sidecar, so a full backup and a single-project export carry it as it is; a restore that
// adds a record the plan names as a copy points the plan at the copy (as it does the project's
// links), counts the draft as using it, and keeps every other key of the plan.

/// A weaving draft whose plan names the wool as warp and the towel sample, with no links.
Future<void> putPlannedDraft(Directory root) async {
  await put(root, 'drafts/d7.wif', wifBytes);
  await put(
      root,
      'drafts/d7.json',
      sidecar('Towels', 'Weaving', extra: {
        WeavePlan.key: {
          'version': 1,
          'structure': 'twill',
          'items': 4,
          'swatchId': 'sw-towel',
          'swatchName': 'Towel sample',
          'warpMaterialId': 'grey-wool',
          'warpMaterialName': 'Grey wool',
          'overrides': {'takeUp': 0.12, 'later': 'kept'},
          'laterKey': [1, 2],
        },
      }));
}

void main() {
  setUp(() async {
    docs = await Directory.systemTemp.createTemp('backup_docs');
    work = await Directory.systemTemp.createTemp('backup_work');
  });
  tearDown(() async {
    await docs.delete(recursive: true);
    await work.delete(recursive: true);
  });

  test('a restore points the plan at a restored copy and keeps the rest of it', () async {
    final source = await Directory.systemTemp.createTemp('backup_src');
    addTearDown(() => source.delete(recursive: true));
    await putPlannedDraft(source);
    await writeRecords(source, materials: [wool], swatches: [towelSwatch]);
    final archive = await backUp(materialService(into: source));

    // This device has its own, different Grey wool under the same id.
    await writeRecords(docs, materials: [wool.copyWith(name: 'Grey wool, mine')]);
    final plan = await materialService().inspectBackup(archive);
    final byKey = {for (final i in plan.materials!.items) i.key: i};
    expect(byKey['material/grey-wool']!.status, RestoreStatus.conflict);
    expect(byKey['material/grey-wool']!.projects, 1,
        reason: 'the draft uses the wool through its plan, without a link');
    expect(byKey['swatch/sw-towel']!.status, RestoreStatus.add);

    final result = await materialService().restore(plan);
    expect(result.projectsRelinkedToMaterials, 1);
    final copy = (await readRecords(docs)).materials.last;
    expect(copy.name, 'Grey wool (restored)');
    final restored = sidecarOf(docs, 'drafts/d7.json')[WeavePlan.key] as Map;
    expect(restored['warpMaterialId'], copy.id);
    expect(restored['warpMaterialName'], 'Grey wool (restored)');
    expect(restored['swatchId'], 'sw-towel', reason: 'added under its own id');
    expect(restored['overrides'], {'takeUp': 0.12, 'later': 'kept'});
    expect(restored['laterKey'], [1, 2]);
    expect(WeavePlan.fromJson(restored)!.overrides.value<double>(PlanAssumption.takeUp), 0.12);

    // The same backup again: the draft, pointed at the copy, is already here.
    final again = await materialService().inspectBackup(archive);
    expect(again.projects.singleWhere((p) => p.id == 'd7').status, RestoreStatus.alreadyPresent);
  });

  test('a single-project export carries the plan as it is', () async {
    await putPlannedDraft(docs);
    final export = await exportOne(materialService(), BackupCraft.weaving, 'd7');
    final entries = await entriesOf(export);
    final json = entries.singleWhere((e) => e.$1 == 'drafts/d7.json').$2;
    expect(json, File('${docs.path}/drafts/d7.json').readAsBytesSync());
  });
}
