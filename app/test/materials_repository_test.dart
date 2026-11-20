import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:ply/src/data/library_backup.dart' show BackupCraft;
import 'package:ply/src/data/materials_repository.dart';
import 'package:ply/src/data/project_links_repository.dart';
import 'package:ply/src/models/material_record.dart';
import 'package:ply/src/models/project_materials.dart';

import 'materials_test_support.dart';

// materials.json on the device (ADR 0016): atomic writes, a newer or unreadable file never replaced,
// an unreadable one moved aside, a large one left in place; and a project's links in its sidecar
// (one key, every other key kept), with the usage scan the delete confirmation relies on.

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('materials'));
  tearDown(() => dir.delete(recursive: true));

  File file() => File(p.join(dir.path, MaterialsRepository.fileName));

  group('materials.json', () {
    test('no file reads as empty; a save writes it atomically and reads back', () async {
      final repo = DartCodecMaterialsRepository(dir);
      expect((await repo.load()).library.isEmpty, isTrue);
      const lib = MaterialLibrary(materials: [wool, cotton], swatches: [knitSwatch, towelSwatch]);
      await repo.saveAll(lib);
      expect(File('${file().path}.tmp').existsSync(), isFalse);
      final back = (await repo.load()).library;
      expect(back.materials, lib.materials);
      expect(back.swatches, lib.swatches);
    });

    test('a newer file is left alone and never replaced', () async {
      final text = jsonEncode({'format': kMaterialsFormat, 'schema_version': 2, 'x': 1});
      file().writeAsStringSync(text);
      final repo = DartCodecMaterialsRepository(dir);
      expect((await repo.load()).status, MaterialsFileStatus.newer);
      await expectLater(
          repo.saveAll(const MaterialLibrary(materials: [wool])),
          throwsA(isA<MaterialsFileException>()
              .having((e) => e.problem, 'problem', MaterialsFileProblem.newerVersion)
              .having((e) => e.whileSaving, 'whileSaving', isTrue)));
      expect(file().readAsStringSync(), text);
    });

    test('an unreadable file is moved aside, never over an older copy', () async {
      file().writeAsStringSync('not json');
      File('${file().path}.corrupt').writeAsStringSync('older');
      final load = await DartCodecMaterialsRepository(dir).load();
      expect(load.status, MaterialsFileStatus.setAside);
      expect(load.setAsidePath, endsWith('.corrupt.2'));
      expect(File('${file().path}.corrupt').readAsStringSync(), 'older');
      expect(file().existsSync(), isFalse);
    });

    test('a file over the limit is left in place, and a large newer one reads as newer', () async {
      final big = jsonEncode({
        'format': kMaterialsFormat,
        'schema_version': 1,
        'pad': 'x' * MaterialsRepository.maxFileBytes,
      });
      file().writeAsStringSync(big);
      expect((await DartCodecMaterialsRepository(dir).load()).status, MaterialsFileStatus.tooLarge);
      expect(file().existsSync(), isTrue);
      file().writeAsStringSync(big.replaceFirst('"schema_version":1', '"schema_version":3'));
      expect((await DartCodecMaterialsRepository(dir).load()).status, MaterialsFileStatus.newer);
    });

    test('the engine alone reads the file, newer version included', () async {
      // decodeBytes decodes no JSON of its own (ADR 0007, amendment of 2026-11-18, later): a
      // crafted file of two megabytes once cost about 100 MiB in Dart before the engine saw it.
      late Future<MaterialLibrary> Function() answer;
      final repo = _ScriptedMaterialsRepository(dir, () => answer());
      Matcher refused(MaterialsFileProblem problem) =>
          throwsA(isA<MaterialsFileException>().having((e) => e.problem, 'problem', problem));
      final stated2 = jsonEncode({'format': kMaterialsFormat, 'schema_version': 2});

      // Within the limit: the engine's verdict stands, whatever version the text states.
      answer = () async => const MaterialLibrary(materials: [wool]);
      expect((await repo.decodeBytes(utf8.encode(stated2))).materials, [wool]);
      answer = () async => throw const MaterialsFileException(MaterialsFileProblem.unreadable);
      await expectLater(
          repo.decodeBytes(utf8.encode(stated2)), refused(MaterialsFileProblem.unreadable));
      answer = () async => throw const MaterialsFileException(MaterialsFileProblem.newerVersion);
      await expectLater(
          repo.decodeBytes(utf8.encode('{}')), refused(MaterialsFileProblem.newerVersion));
      expect(repo.asked, [stated2, stated2, '{}']);

      // Over the limit: too large unless the engine finds a newer version.
      final big = utf8.encode(' ' * (MaterialsRepository.maxFileBytes + 1));
      await expectLater(repo.decodeBytes(big), refused(MaterialsFileProblem.newerVersion));
      for (final other in <Future<MaterialLibrary> Function()>[
        () async => MaterialLibrary.empty,
        () async => throw const MaterialsFileException(MaterialsFileProblem.unreadable),
        () async => throw const MaterialsFileException(MaterialsFileProblem.tooLarge),
        () async => throw StateError('the engine failed'),
      ]) {
        answer = other;
        await expectLater(repo.decodeBytes(big), refused(MaterialsFileProblem.tooLarge));
      }

      expect(repo.asked, hasLength(8), reason: 'the whole text, for its envelope, each time');

      // Not UTF-8, or past the largest file whose version is looked at: the engine is not asked.
      repo.asked.clear();
      await expectLater(repo.decodeBytes([0xff]), refused(MaterialsFileProblem.unreadable));
      await expectLater(repo.decodeBytes(List.filled(MaterialsRepository.maxFileBytes + 1, 0xff)),
          refused(MaterialsFileProblem.tooLarge));
      await expectLater(repo.decodeBytes(Uint8List(MaterialsRepository.maxProbedFileBytes + 1)),
          refused(MaterialsFileProblem.tooLarge));
      expect(repo.asked, isEmpty);

      // The stand-in engine the other tests use reports a newer version the same way.
      final codec = DartCodecMaterialsRepository(dir);
      await expectLater(
          codec.decodeBytes(utf8.encode(stated2)), refused(MaterialsFileProblem.newerVersion));
      expect(codec.decodes, 1);
    });

    test('adding records (a restore) can be undone exactly', () async {
      final repo = DartCodecMaterialsRepository(dir);
      final undoFirst = await repo.addRecords([wool], []);
      await undoFirst();
      expect(file().existsSync(), isFalse, reason: 'there was no file before');
      await repo.saveAll(const MaterialLibrary(materials: [cotton]));
      final before = file().readAsBytesSync();
      final undo = await repo.addRecords([wool], [knitSwatch]);
      expect((await repo.load()).library.materials.map((m) => m.id), ['cotton-8-2', 'grey-wool']);
      await undo();
      expect(file().readAsBytesSync(), before);
    });

    test('a deleted swatch takes its photos with it', () async {
      final repo = DartCodecMaterialsRepository(dir);
      final photos = await repo.photoDir('sw-knit');
      await photos.create(recursive: true);
      File(p.join(photos.path, 'a.jpg')).writeAsBytesSync([1, 2]);
      await repo.deletePhotos('sw-knit');
      expect(photos.existsSync(), isFalse);
      await repo.deletePhotos('sw-none'); // nothing there: no error
    });
  });

  group('project links', () {
    Future<File> sidecar(String folder, String id, Map<String, Object?> json) async {
      final f = File(p.join(dir.path, folder, '$id.json'));
      await f.parent.create(recursive: true);
      await f.writeAsString(jsonEncode(json));
      return f;
    }

    final links = ProjectMaterials(
      yarns: [
        MaterialLink(materialId: 'grey-wool', materialName: 'Grey wool', role: YarnRole.main)
      ],
      swatches: [SwatchLink(swatchId: 'sw-knit', swatchName: 'Grey wool stockinette')],
    );

    test('a write changes the materials key alone and keeps every other key', () async {
      final f = await sidecar('knits', 'k1', {
        'name': 'Hat',
        'craft': 'Knitting',
        'futureKey': {'kept': true},
        'schemaVersion': 1,
      });
      final repo = ProjectLinksRepository(docsOverride: dir);
      expect(await repo.read(BackupCraft.knitting, 'k1'), ProjectMaterials.none);
      await repo.write(BackupCraft.knitting, 'k1', links);
      final json = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      expect(json['futureKey'], {'kept': true});
      expect(json['name'], 'Hat');
      expect(json['materials']['yarns'][0],
          {'materialId': 'grey-wool', 'materialName': 'Grey wool', 'role': 'main'});
      expect(await repo.read(BackupCraft.knitting, 'k1'), links);
      // Unlinking everything removes the key.
      await repo.write(BackupCraft.knitting, 'k1', ProjectMaterials.none);
      expect((jsonDecode(f.readAsStringSync()) as Map).containsKey('materials'), isFalse);
    });

    test('links keep what this build does not know', () {
      final raw = {
        'yarns': [
          {'materialId': 'a', 'materialName': 'A', 'role': 'filler', 'note': 'x'},
          {'no': 'id'},
        ],
        'swatches': [
          {'swatchId': 's', 'swatchName': 'S'}
        ],
        'plan': {'later': 1},
      };
      final l = ProjectMaterials.fromJson(raw)!;
      expect(l.yarns.single.role, isNull, reason: 'an unknown role is kept, not guessed');
      expect(l.toJson(), raw);
      expect(l.copyWith(yarns: const []).toJson()['yarns'], [
        {'no': 'id'}
      ]);
    });

    test('an unsaved project, a newer sidecar or an odd value is refused without writing',
        () async {
      final repo = ProjectLinksRepository(docsOverride: dir);
      await expectLater(
          repo.write(BackupCraft.weaving, 'nope', links), throwsA(isA<ProjectLinksException>()));
      final newer = await sidecar('drafts', 'd1', {'name': 'D', 'schemaVersion': 2});
      final before = newer.readAsStringSync();
      await expectLater(
          repo.write(BackupCraft.weaving, 'd1', links), throwsA(isA<ProjectLinksException>()));
      expect(newer.readAsStringSync(), before);
      final odd = await sidecar('drafts', 'd2', {'name': 'D', 'materials': 'later'});
      final oddBefore = odd.readAsStringSync();
      await expectLater(
          repo.write(BackupCraft.weaving, 'd2', links), throwsA(isA<ProjectLinksException>()));
      expect(odd.readAsStringSync(), oddBefore);
    });

    test('usage lists the projects of every craft that link a record', () async {
      await sidecar('drafts', 'd1', {'name': 'Towel', 'materials': links.toJson()});
      await sidecar('knits', 'k1', {'name': 'Hat', 'materials': links.toJson()});
      await sidecar('nalbinds', 'n1', {'name': 'Mitten'});
      final usage = await ProjectLinksRepository(docsOverride: dir).usage();
      expect(usage.ofMaterial('grey-wool').map((r) => r.name), ['Hat', 'Towel']);
      expect(usage.ofSwatch('sw-knit').map((r) => r.craft),
          unorderedEquals([BackupCraft.weaving, BackupCraft.knitting]));
      expect(usage.ofMaterial('cotton-8-2'), isEmpty);
    });

    test('relinking points links at copies and keeps every other key', () {
      final json = {
        'name': 'Hat',
        'materials': {
          'yarns': [
            {'materialId': 'grey-wool', 'materialName': 'Grey wool', 'role': 'main', 'x': 1},
            {'materialId': 'other', 'materialName': 'Other'},
          ],
          'swatches': [
            {'swatchId': 'sw-knit', 'swatchName': 'Old'}
          ],
          'kept': true,
        },
      };
      final out = ProjectMaterials.relinked(json, {'grey-wool': ('copy-1', 'Grey wool (restored)')},
          {'sw-knit': ('copy-2', 'Swatch (restored)')});
      expect(out['name'], 'Hat');
      final m = out['materials'] as Map;
      expect(m['kept'], isTrue);
      expect(m['yarns'][0],
          {'materialId': 'copy-1', 'materialName': 'Grey wool (restored)', 'role': 'main', 'x': 1});
      expect(m['yarns'][1], {'materialId': 'other', 'materialName': 'Other'});
      expect(m['swatches'][0], {'swatchId': 'copy-2', 'swatchName': 'Swatch (restored)'});
    });
  });

  group('the model', () {
    test('lengths convert with exact factors and records compare field by field', () {
      expect(const Length(1, LengthUnit.inch).inUnit(LengthUnit.centimeter), 2.54);
      expect(const Length(1, LengthUnit.yard).inUnit(LengthUnit.meter), 0.9144);
      expect(
          const CountOver(20, Length(10, LengthUnit.centimeter))
              .per(const Length(4, LengthUnit.inch)),
          closeTo(20.32, 1e-9));
      expect(wool == materialFromMap(wool.toMap()), isTrue);
      expect(wool == wool.copyWith(name: 'Other'), isFalse);
      expect(formatQuantityNumber(22.352), '22.35');
      expect(formatQuantityNumber(20), '20');
      expect(knitSwatch.summary, contains('20 sts per 10 cm after finishing'));
      expect(const SwatchRecord(id: 'x').summary, 'Nothing recorded yet');
      expect(const MaterialRecord(id: 'x').displayName, 'Unnamed material');
    });
  });
}

/// The materials repository with the engine's reader scripted by the test, recording every text it
/// is asked to read.
class _ScriptedMaterialsRepository extends MaterialsRepository {
  _ScriptedMaterialsRepository(Directory dir, this.answer) : super(dirOverride: dir);

  final Future<MaterialLibrary> Function() answer;
  final List<String> asked = [];

  @override
  Future<MaterialLibrary> decode(String text) {
    asked.add(text);
    return answer();
  }
}
