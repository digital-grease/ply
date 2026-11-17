import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ply/src/data/library_backup.dart';
import 'package:ply/src/data/materials_repository.dart';
import 'package:ply/src/data/project_links_repository.dart';
import 'package:ply/src/models/draft_doc.dart';
import 'package:ply/src/models/material_record.dart';
import 'package:ply/src/models/project_materials.dart';

// Shared helpers for the materials and swatch tests (ADR 0016). Host tests have no native library,
// so the engine's `materials.json` reader, its reports and its estimates are replaced by stand-ins:
// an in-memory repository for the screens, and a small Dart codec (the same envelope, detection rule
// and record shape, read with `recordFromMap`) for the file and backup tests. The engine's own format
// and its numbers are tested in Rust.

const MaterialRecord wool = MaterialRecord(
  id: 'grey-wool',
  name: 'Grey wool',
  fibers: [FiberPart('wool', 80), FiberPart('nylon', 20)],
  weight: YarnWeightCategory.light,
  lengthPerMass:
      Recorded.entered(LengthPerMass(Length(200, LengthUnit.meter), Mass(100, MassUnit.gram))),
  wpi: Recorded.measured(CountOver(11, Length(1, LengthUnit.inch))),
  availableMass: Recorded.measured(Mass(450, MassUnit.gram)),
);

const MaterialRecord cotton = MaterialRecord(id: 'cotton-8-2', name: '8/2 cotton');

const SwatchRecord knitSwatch = SwatchRecord(
  id: 'sw-knit',
  name: 'Grey wool stockinette',
  craft: SwatchCraft.knitting,
  date: '2026-11-10',
  yarns: [SwatchYarn(materialId: 'grey-wool', name: 'Grey wool', role: YarnRole.main)],
  before: SwatchStage(
    width: Recorded.measured(Length(13.5, LengthUnit.centimeter)),
    across: Recorded.measured(CountOver(22, Length(10, LengthUnit.centimeter))),
  ),
  after: SwatchStage(
    width: Recorded.measured(Length(15, LengthUnit.centimeter)),
    length: Recorded.measured(Length(15, LengthUnit.centimeter)),
    across: Recorded.measured(CountOver(20, Length(10, LengthUnit.centimeter))),
    along: Recorded.measured(CountOver(32, Length(10, LengthUnit.centimeter))),
  ),
  finishing: 'washed in cool water, dried flat',
  mass: Recorded.measured(Mass(9, MassUnit.gram)),
);

const SwatchRecord towelSwatch = SwatchRecord(
  id: 'sw-towel',
  name: 'Towel sample',
  craft: SwatchCraft.weaving,
  date: '2026-11-02',
  sett: Recorded.entered(CountOver(24, Length(1, LengthUnit.inch))),
  widthInReed: Recorded.entered(Length(12, LengthUnit.inch)),
  onLoom: SwatchStage(
    length: Recorded.measured(Length(20, LengthUnit.inch)),
    along: Recorded.measured(CountOver(22, Length(1, LengthUnit.inch))),
  ),
  after: SwatchStage(length: Recorded.measured(Length(18, LengthUnit.inch))),
);

// --- the Dart stand-in codec ---------------------------------------------------------------------

Length? _length(Object? m) =>
    m is Map ? Length((m['value'] as num).toDouble(), LengthUnit.bySymbol(m['unit'])!) : null;
Mass? _mass(Object? m) =>
    m is Map ? Mass((m['value'] as num).toDouble(), MassUnit.bySymbol(m['unit'])!) : null;
CountOver? _count(Object? m) =>
    m is Map ? CountOver((m['count'] as num).toDouble(), _length(m['over'])!) : null;
Recorded<T>? _rec<T>(Object? m, T? Function(Object?) f) =>
    m is Map ? Recorded(f(m['value']) as T, ValueSource.bySerialName(m['source'])!) : null;
SwatchStage _stage(Object? m) => m is Map
    ? SwatchStage(
        width: _rec(m['width'], _length),
        length: _rec(m['length'], _length),
        across: _rec(m['across'], _count),
        along: _rec(m['along'], _count),
        conditions: (m['conditions'] as String?) ?? '',
      )
    : const SwatchStage();

/// A material from the engine's JSON shape (the inverse of [MaterialRecord.toMap]).
MaterialRecord materialFromMap(Map m) => MaterialRecord(
      id: m['id'] as String,
      name: (m['name'] as String?) ?? '',
      maker: (m['maker'] as String?) ?? '',
      fibers: [
        for (final f in (m['fibers'] as List?) ?? const [])
          FiberPart(f['fiber'] as String, (f['percent'] as num?)?.toDouble()),
      ],
      weight: YarnWeightCategory.values.where((w) => w.serialName == m['weight']).firstOrNull,
      structure: (m['structure'] as String?) ?? '',
      lengthPerMass: _rec(m['length_per_mass'],
          (v) => v is Map ? LengthPerMass(_length(v['length'])!, _mass(v['mass'])!) : null),
      wpi: _rec(m['wpi'], _count),
      color: (m['color'] as String?) ?? '',
      dyeLot: (m['dye_lot'] as String?) ?? '',
      availableMass: _rec(m['available_mass'], _mass),
      availableLength: _rec(m['available_length'], _length),
      notes: (m['notes'] as String?) ?? '',
    );

/// A swatch from the engine's JSON shape (the inverse of [SwatchRecord.toMap]).
SwatchRecord swatchFromMap(Map m) => SwatchRecord(
      id: m['id'] as String,
      name: (m['name'] as String?) ?? '',
      craft: SwatchCraft.values.where((c) => c.serialName == m['craft']).firstOrNull,
      technique: (m['technique'] as String?) ?? '',
      date: m['date'] as String?,
      yarns: [
        for (final y in (m['yarns'] as List?) ?? const [])
          SwatchYarn(
              materialId: y['material_id'] as String?,
              name: (y['name'] as String?) ?? '',
              role: YarnRole.bySerialName(y['role'])),
      ],
      tools: (m['tools'] as String?) ?? '',
      sett: _rec(m['sett'], _count),
      widthInReed: _rec(m['width_in_reed'], _length),
      onLoom: _stage(m['on_loom']),
      before: _stage(m['before']),
      after: _stage(m['after']),
      finishing: (m['finishing'] as String?) ?? '',
      mass: _rec(m['mass'], _mass),
      tension: (m['tension'] as String?) ?? '',
      provenance: (m['provenance'] as String?) ?? '',
      notes: (m['notes'] as String?) ?? '',
    );

/// A materials repository over a real directory with a Dart stand-in for the engine's codec.
class DartCodecMaterialsRepository extends MaterialsRepository {
  DartCodecMaterialsRepository(Directory dir) : super(dirOverride: dir);

  @override
  Future<MaterialLibrary> decode(String text) async {
    final Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException catch (e) {
      throw MaterialsFileException(MaterialsFileProblem.unreadable, detail: '$e');
    }
    if (json is! Map || json['format'] != kMaterialsFormat) {
      throw const MaterialsFileException(MaterialsFileProblem.unreadable, detail: 'format');
    }
    final v = json['schema_version'];
    if (v is! int || v < 1) throw const MaterialsFileException(MaterialsFileProblem.unreadable);
    if (v > kMaterialsSchemaVersion) {
      throw const MaterialsFileException(MaterialsFileProblem.newerVersion);
    }
    try {
      return MaterialLibrary(
        materials: [for (final m in json['materials'] as List) materialFromMap(m as Map)],
        swatches: [for (final s in json['swatches'] as List) swatchFromMap(s as Map)],
      );
    } catch (e) {
      throw MaterialsFileException(MaterialsFileProblem.unreadable, detail: '$e');
    }
  }

  @override
  Future<String> encode(MaterialLibrary library) async => jsonEncode({
        'format': kMaterialsFormat,
        'schema_version': kMaterialsSchemaVersion,
        'materials': [for (final m in library.materials) m.toMap()],
        'swatches': [for (final s in library.swatches) s.toMap()],
      });

  @override
  Future<RecordReport> materialReport(MaterialRecord m) async => RecordReport.empty;

  @override
  Future<RecordReport> swatchReport(SwatchRecord s) async => RecordReport.empty;
}

/// The backup hooks over [repo].
MaterialBackupHooks materialHooks(MaterialsRepository repo,
        {Future<bool> Function(MaterialLibrary merged)? fits}) =>
    MaterialBackupHooks(
      currentFile: repo.currentBytes,
      decode: (Uint8List bytes) => repo.decodeBytes(bytes),
      current: () async {
        final bytes = await repo.currentBytes();
        return bytes == null ? MaterialLibrary.empty : await repo.decodeBytes(bytes);
      },
      add: repo.addRecords,
      fits: fits ?? repo.fits,
    );

/// An in-memory materials store: no file, no engine. Reports and estimates are what the test sets.
class FakeMaterialsRepository extends MaterialsRepository {
  FakeMaterialsRepository({
    List<MaterialRecord> materials = const [],
    List<SwatchRecord> swatches = const [],
    this.status = MaterialsFileStatus.ok,
  })  : library = MaterialLibrary(materials: [...materials], swatches: [...swatches]),
        super(dirOverride: Directory.systemTemp);

  MaterialLibrary library;
  MaterialsFileStatus status;
  RecordReport report = RecordReport.empty;
  Object? saveError;
  int saves = 0;

  /// What the traced estimates return, and what they were asked.
  TracedEstimate<int>? castOn;
  TracedEstimate<YarnAmount>? yardage;
  TracedEstimate<WarpAmount>? warp;
  TracedEstimate<WeftAmount>? weft;
  String? planError;

  /// Errors for one estimate only (the other still works).
  String? castOnError;
  String? yardageError;

  /// When set, every save waits for it (to run changes at the same time).
  Future<void>? saveGate;
  final List<Map<String, Object?>> asked = [];

  @override
  Future<MaterialsLoad> load() async => MaterialsLoad(library, status: status);

  @override
  Future<void> saveAll(MaterialLibrary next) async {
    if (saveGate != null) await saveGate;
    if (saveError != null) throw saveError!;
    saves++;
    library = next;
  }

  @override
  Future<void> deletePhotos(String swatchId) async {}

  @override
  Future<RecordReport> materialReport(MaterialRecord m) async => report;

  @override
  Future<RecordReport> swatchReport(SwatchRecord s) async => report;

  @override
  Future<TracedEstimate<int>> castOnTraced(
      {SwatchRecord? swatch,
      required PlanInput<CountOver> gauge,
      required Length width,
      required Length ease,
      required int repeat}) async {
    asked.add({
      'kind': 'castOn',
      'swatch': swatch?.id,
      'swatchRecord': swatch,
      'gauge': gauge.origin,
      'gaugeValue': gauge.value,
      'width': width,
    });
    if (planError != null) throw PlanException(planError!);
    if (castOnError != null) throw PlanException(castOnError!);
    return castOn!;
  }

  @override
  Future<TracedEstimate<YarnAmount>> yardageTraced(
      {SwatchRecord? swatch,
      MaterialRecord? yarn,
      required PlanInput<CountOver> gauge,
      required Length width,
      required Length length,
      required PlanInput<double> buffer}) async {
    asked.add({
      'kind': 'yardage',
      'swatch': swatch?.id,
      'swatchRecord': swatch,
      'yarn': yarn?.id,
      'gauge': gauge.origin,
    });
    if (planError != null) throw PlanException(planError!);
    if (yardageError != null) throw PlanException(yardageError!);
    return yardage!;
  }

  @override
  Future<TracedEstimate<WarpAmount>> warpTraced(
      {SwatchRecord? swatch,
      required Length finishedLength,
      required int items,
      required PlanInput<int> ends,
      Length? settWidth,
      required PlanInput<Length> loomWaste,
      required PlanInput<double> allowance}) async {
    asked.add({
      'kind': 'warp',
      'swatch': swatch?.id,
      'settWidth': settWidth,
      'ends': ends.origin,
      'allowance': allowance.origin,
      'loomWaste': loomWaste.origin,
    });
    if (planError != null) throw PlanException(planError!);
    return warp!;
  }

  @override
  Future<TracedEstimate<WeftAmount>> weftTraced(
      {SwatchRecord? swatch,
      required PlanInput<CountOver> ppi,
      required Length width,
      required Length wovenLength,
      required int items,
      required PlanInput<double> takeup,
      DraftDoc? draft}) async {
    asked.add({'kind': 'weft', 'swatch': swatch?.id, 'ppi': ppi.origin, 'takeup': takeup.origin});
    if (planError != null) throw PlanException(planError!);
    return weft!;
  }
}

/// A traced input for canned estimates.
TracedInput tracedInput(String key, String label, String value, ValueSource source, String basis) =>
    TracedInput(key: key, label: label, value: value, source: source, basis: basis);

/// An in-memory store of project sidecars for the links (widget tests cannot wait on real file
/// I/O): `<craft folder>/<id>` to the sidecar's JSON. The same rules as the real repository.
class FakeProjectLinks extends ProjectLinksRepository {
  FakeProjectLinks([Map<String, Map<String, dynamic>>? sidecars])
      : sidecars = sidecars ?? {},
        super(docsOverride: Directory.systemTemp);

  final Map<String, Map<String, dynamic>> sidecars;

  /// When set, the usage scan waits for it, then fails with [usageError] if that is set.
  Future<void>? usageGate;
  Object? usageError;

  @override
  Future<ProjectMaterials> read(BackupCraft craft, String id) async {
    final json = sidecars['${craft.directory}/$id'];
    if (json == null) {
      throw const ProjectLinksException('Save the project first to link materials and swatches.');
    }
    return ProjectMaterials.fromJson(json[ProjectMaterials.key]) ?? ProjectMaterials.none;
  }

  @override
  Future<void> write(BackupCraft craft, String id, ProjectMaterials links) async {
    final key = '${craft.directory}/$id';
    final json = sidecars[key];
    if (json == null) {
      throw const ProjectLinksException('Save the project first to link materials and swatches.');
    }
    final next = Map<String, dynamic>.of(json);
    if (links.isEmpty) {
      next.remove(ProjectMaterials.key);
    } else {
      next[ProjectMaterials.key] = jsonDecode(jsonEncode(links.toJson()));
    }
    sidecars[key] = next;
  }

  @override
  Future<LinkUsage> usage() async {
    if (usageGate != null) await usageGate;
    if (usageError != null) throw usageError!;
    final materials = <String, List<ProjectRef>>{};
    final swatches = <String, List<ProjectRef>>{};
    for (final e in sidecars.entries) {
      final folder = e.key.split('/').first;
      final craft = BackupCraft.values.firstWhere((c) => c.directory == folder);
      final ref = ProjectRef(craft, e.key.split('/').last, name: '${e.value['name']}');
      final ids = ProjectMaterials.idsIn(e.value);
      for (final m in ids.materials) {
        (materials[m] ??= []).add(ref);
      }
      for (final s in ids.swatches) {
        (swatches[s] ??= []).add(ref);
      }
    }
    for (final l in [...materials.values, ...swatches.values]) {
      l.sort((a, b) => a.name.compareTo(b.name));
    }
    return LinkUsage(materials: materials, swatches: swatches);
  }
}
