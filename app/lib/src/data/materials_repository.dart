import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../diagnostics/log_buffer.dart';
import '../models/draft_doc.dart';
import '../models/material_record.dart';
import '../rust/api.dart' as api;
import '../rust/knit_dto.dart' show YarnWeightKind;
import '../rust/materials_dto.dart' as wire;
import 'draft_repository.dart';

/// The `format` of `materials.json` (mirrors `ply_common::materials_file::MATERIALS_FORMAT`).
const String kMaterialsFormat = 'ply.materials';

/// The `materials.json` schema version this build reads and writes (mirrors
/// `MATERIALS_SCHEMA_VERSION`).
const int kMaterialsSchemaVersion = 1;

/// The documents subfolder swatch photos live in: `<documents>/swatches/<swatch id>.photos/`.
const String kSwatchPhotoDir = 'swatches';

/// What stopped Ply from reading, or from replacing, `materials.json`.
enum MaterialsFileProblem { newerVersion, unreadable, tooLarge }

/// `materials.json` could not be read, or (when [whileSaving]) was not replaced. The file itself is
/// never modified.
class MaterialsFileException implements Exception {
  const MaterialsFileException(this.problem, {this.whileSaving = false, this.detail});

  final MaterialsFileProblem problem;
  final bool whileSaving;
  final String? detail;

  String get message {
    if (whileSaving) {
      return switch (problem) {
        MaterialsFileProblem.newerVersion =>
          'Your materials were saved by a newer version of Ply, so they were not changed.',
        MaterialsFileProblem.tooLarge =>
          'Your materials file is too large to open, so it was not changed.',
        MaterialsFileProblem.unreadable =>
          'Your saved materials could not be read, so they were not changed.',
      };
    }
    return switch (problem) {
      MaterialsFileProblem.newerVersion =>
        'Your materials were saved by a newer version of Ply. Update the app to change them.',
      MaterialsFileProblem.tooLarge => 'Your materials file is too large to open.',
      MaterialsFileProblem.unreadable => 'Your saved materials could not be read.',
    };
  }

  @override
  String toString() => detail == null ? message : '$message ($detail)';
}

/// How `materials.json` was found when it was loaded.
enum MaterialsFileStatus {
  /// Read (or there was none yet).
  ok,

  /// Saved by a newer Ply: left alone, and Materials is read only.
  newer,

  /// Could not be read, so it was moved aside and Materials starts empty.
  setAside,

  /// Too large to open: left where it is, and Materials is read only.
  tooLarge,

  /// Could not be reached (an I/O error): left where it is, read only for this run.
  unreachable,
}

/// Every material and swatch.
class MaterialLibrary {
  const MaterialLibrary({this.materials = const [], this.swatches = const []});

  static const MaterialLibrary empty = MaterialLibrary();

  final List<MaterialRecord> materials;
  final List<SwatchRecord> swatches;

  bool get isEmpty => materials.isEmpty && swatches.isEmpty;
}

/// The records, and how the file was found.
class MaterialsLoad {
  const MaterialsLoad(this.library, {this.status = MaterialsFileStatus.ok, this.setAsidePath});

  final MaterialLibrary library;
  final MaterialsFileStatus status;
  final String? setAsidePath;
}

/// The one place the app touches `materials.json` and the materials bridge symbols (ADR 0016). The
/// engine owns the format, the diagnostics, the derived figures and the estimates; this repository
/// does the file I/O as the loom repository does: atomic writes (temp, flush, rename), never
/// replacing a newer or unreadable file, and moving an unreadable one aside (never over an older
/// copy) before Materials starts empty.
class MaterialsRepository {
  MaterialsRepository({@visibleForTesting Directory? dirOverride, DraftRepository? drafts})
      : _dirOverride = dirOverride,
        _drafts = drafts ?? DraftRepository();

  final Directory? _dirOverride;
  final DraftRepository _drafts;

  static const String fileName = 'materials.json';

  /// The largest `materials.json` read (mirrors `MAX_MATERIALS_FILE_BYTES`).
  static const int maxFileBytes = 2 * 1024 * 1024;

  /// The largest file whose version is still probed when it is over [maxFileBytes].
  static const int maxProbedFileBytes = 16 * 1024 * 1024;

  static const String corruptSuffix = '.corrupt';

  Future<Directory> documents() async => _dirOverride ?? await getApplicationDocumentsDirectory();

  Future<File> file() async => File(p.join((await documents()).path, fileName));

  /// The folder of a swatch's photos (it may not exist).
  Future<Directory> photoDir(String swatchId) async =>
      Directory(p.join((await documents()).path, kSwatchPhotoDir, '$swatchId.photos'));

  /// Read the records. Never throws for the file's content (see [MaterialsFileStatus]).
  Future<MaterialsLoad> load() async {
    final File f;
    final Uint8List bytes;
    try {
      f = await file();
      if (!await f.exists()) return const MaterialsLoad(MaterialLibrary.empty);
      bytes = await f.readAsBytes();
    } catch (e) {
      PlyLog.instance.warn('materials.json could not be reached: $e');
      return const MaterialsLoad(MaterialLibrary.empty, status: MaterialsFileStatus.unreachable);
    }
    try {
      return MaterialsLoad(await decodeBytes(bytes));
    } on MaterialsFileException catch (e) {
      if (e.problem == MaterialsFileProblem.newerVersion) {
        return const MaterialsLoad(MaterialLibrary.empty, status: MaterialsFileStatus.newer);
      }
      if (e.problem == MaterialsFileProblem.tooLarge) {
        return const MaterialsLoad(MaterialLibrary.empty, status: MaterialsFileStatus.tooLarge);
      }
      final aside = await _setAside(f);
      return MaterialsLoad(MaterialLibrary.empty,
          status: MaterialsFileStatus.setAside, setAsidePath: aside);
    }
  }

  /// The records in [bytes]: checked as UTF-8, then read by the engine ([decode]), as the loom
  /// repository reads `looms.json`. Nothing here decodes the JSON (ADR 0007, amendment of
  /// 2026-11-18, later): the engine says itself when a newer Ply wrote the file, from the envelope
  /// alone. A file over [maxFileBytes] is too large, unless the engine finds it was written by a
  /// newer Ply (it looks only at the envelope of such a file, up to [maxProbedFileBytes]). Throws
  /// a [MaterialsFileException].
  Future<MaterialLibrary> decodeBytes(List<int> bytes) async {
    final overLimit = bytes.length > maxFileBytes;
    final tooLarge =
        MaterialsFileException(MaterialsFileProblem.tooLarge, detail: '${bytes.length} bytes');
    if (bytes.length > maxProbedFileBytes) throw tooLarge;
    final String text;
    try {
      text = utf8.decode(bytes);
    } on FormatException catch (e) {
      throw overLimit
          ? tooLarge
          : MaterialsFileException(MaterialsFileProblem.unreadable, detail: '$e');
    }
    if (!overLimit) return decode(text);
    try {
      await decode(text);
    } on MaterialsFileException catch (e) {
      if (e.problem == MaterialsFileProblem.newerVersion) rethrow;
    } catch (_) {
      // Only a newer version changes what a file over the limit is.
    }
    throw tooLarge;
  }

  /// Read `materials.json` text with the engine. Throws a [MaterialsFileException]: newer (from the
  /// envelope alone, before the records are read), too large (over [maxFileBytes] and not newer, or
  /// too many records) or unreadable. Host tests override this (and [encode]) with a Dart stand-in
  /// that reports a newer version and the size the same way; the engine is the format's owner.
  Future<MaterialLibrary> decode(String text) async {
    try {
      return libraryFromDto(await api.parseMaterials(text: text));
    } on wire.MaterialsFileFailure catch (f) {
      throw MaterialsFileException(
        switch (f.kind) {
          wire.MaterialsFileFailureKind.newerVersion => MaterialsFileProblem.newerVersion,
          wire.MaterialsFileFailureKind.tooLarge => MaterialsFileProblem.tooLarge,
          wire.MaterialsFileFailureKind.wrongFormat ||
          wire.MaterialsFileFailureKind.unreadable =>
            MaterialsFileProblem.unreadable,
        },
        detail: f.message,
      );
    }
  }

  /// Write [library] as `materials.json` text with the engine. Throws when a record has an error.
  Future<String> encode(MaterialLibrary library) => api.writeMaterials(dto: libraryToDto(library));

  /// Save every record, replacing `materials.json` atomically. Refuses (with
  /// [MaterialsFileException], `whileSaving`) to replace a file that is newer or cannot be read.
  Future<void> saveAll(MaterialLibrary library) async {
    final f = await file();
    await _checkReplaceable(f);
    await _atomicWrite(f, utf8.encode(await encode(library)));
  }

  /// The bytes of `materials.json` now, or null when there is none.
  Future<Uint8List?> currentBytes() async {
    final f = await file();
    return await f.exists() ? await f.readAsBytes() : null;
  }

  /// Add records to the library in one write (a library restore), and return how to undo it: the
  /// previous bytes are written back exactly, or the file removed when there was none.
  Future<Future<void> Function()> addRecords(
      List<MaterialRecord> materials, List<SwatchRecord> swatches) async {
    final f = await file();
    final before = await f.exists() ? await f.readAsBytes() : null;
    final current = before == null ? MaterialLibrary.empty : await decodeBytes(before);
    await _atomicWrite(
        f,
        utf8.encode(await encode(MaterialLibrary(
          materials: [...current.materials, ...materials],
          swatches: [...current.swatches, ...swatches],
        ))));
    return () async {
      if (before == null) {
        if (await f.exists()) await f.delete();
      } else {
        await _atomicWrite(f, before);
      }
    };
  }

  /// Whether [library] could be written: within the records' limits and under [maxFileBytes] once
  /// encoded (a restore checks the merged library before offering to add to it).
  Future<bool> fits(MaterialLibrary library) async {
    try {
      return utf8.encode(await encode(library)).length <= maxFileBytes;
    } catch (_) {
      return false;
    }
  }

  /// Remove a deleted swatch's photos (best effort; a leftover folder holds nothing the library
  /// lists, and a restore treats its id as taken).
  Future<void> deletePhotos(String swatchId) async {
    try {
      final d = await photoDir(swatchId);
      if (await d.exists()) await d.delete(recursive: true);
    } catch (e) {
      PlyLog.instance.warn('Could not remove the photos of swatch $swatchId: $e');
    }
  }

  // --- engine reports and estimates ------------------------------------------------------------

  /// A material's diagnostics and derived figures (host tests override this).
  Future<RecordReport> materialReport(MaterialRecord m) async =>
      reportFromDto(await api.materialReport(dto: materialToDto(m)));

  /// A swatch's diagnostics and derived figures (host tests override this).
  Future<RecordReport> swatchReport(SwatchRecord s) async =>
      reportFromDto(await api.swatchReport(dto: swatchToDto(s)));

  /// The knitting cast-on with its working. Throws a [PlanException] with the engine's sentence when
  /// an input cannot be used.
  Future<TracedEstimate<int>> castOnTraced({
    SwatchRecord? swatch,
    required PlanInput<CountOver> gauge,
    required Length width,
    required Length ease,
    required int repeat,
  }) async {
    try {
      final t = await api.knitCastOnTraced(
          req: wire.KnitCastOnRequestDto(
        swatch: swatch == null ? null : swatchToDto(swatch),
        gauge: _countInput(gauge),
        width: lengthToDto(width),
        ease: lengthToDto(ease),
        repeat: repeat.clamp(1, 100000),
      ));
      return TracedEstimate(
          value: t.stitches, inputs: _inputs(t.inputs), working: t.working, notes: t.notes);
    } on String catch (e) {
      throw PlanException(e);
    }
  }

  /// The knitting yarn estimate with its working.
  Future<TracedEstimate<YarnAmount>> yardageTraced({
    SwatchRecord? swatch,
    MaterialRecord? yarn,
    required PlanInput<CountOver> gauge,
    required Length width,
    required Length length,
    required PlanInput<double> buffer,
  }) async {
    try {
      final t = await api.knitYardageTraced(
          req: wire.KnitYardageRequestDto(
        swatch: swatch == null ? null : swatchToDto(swatch),
        gauge: _countInput(gauge),
        width: lengthToDto(width),
        length: lengthToDto(length),
        yarn: yarn == null ? null : materialToDto(yarn),
        buffer: _fractionInput(buffer),
      ));
      return TracedEstimate(
        value: YarnAmount(
          weighed: t.method == wire.YardageMethodKind.weighedSwatch,
          yards: t.yards,
          meters: t.meters,
          bufferedYards: t.bufferedYards,
          bufferedMeters: t.bufferedMeters,
        ),
        inputs: _inputs(t.inputs),
        working: t.working,
        notes: t.notes,
      );
    } on String catch (e) {
      throw PlanException(e);
    }
  }

  /// The weaving warp estimate with its working.
  Future<TracedEstimate<WarpAmount>> warpTraced({
    SwatchRecord? swatch,
    required Length finishedLength,
    required int items,
    required PlanInput<int> ends,
    Length? settWidth,
    required PlanInput<Length> loomWaste,
    required PlanInput<double> allowance,
  }) async {
    try {
      final t = await api.weaveWarpTraced(
          req: wire.WeaveWarpRequestDto(
        swatch: swatch == null ? null : swatchToDto(swatch),
        finishedLength: lengthToDto(finishedLength),
        items: items.clamp(0, 100000),
        ends: wire.WholeInputDto(
            origin: _origin(ends.origin),
            value: (ends.value ?? 0).clamp(0, 100000),
            note: ends.note),
        settWidth: settWidth == null ? null : lengthToDto(settWidth),
        loomWaste: wire.LengthInputDto(
            origin: _origin(loomWaste.origin),
            value: loomWaste.value == null ? null : lengthToDto(loomWaste.value!),
            note: loomWaste.note),
        allowance: _fractionInput(allowance),
      ));
      return TracedEstimate(
        value: WarpAmount(
            ends: t.ends, warpLength: lengthFromDto(t.warpLength), total: lengthFromDto(t.total)),
        inputs: _inputs(t.inputs),
        working: t.working,
        notes: t.notes,
      );
    } on String catch (e) {
      throw PlanException(e);
    }
  }

  /// The weaving weft estimate (counting [draft]'s strands per pick) with its working.
  Future<TracedEstimate<WeftAmount>> weftTraced({
    SwatchRecord? swatch,
    required PlanInput<CountOver> ppi,
    required Length width,
    required Length wovenLength,
    required int items,
    required PlanInput<double> takeup,
    DraftDoc? draft,
  }) async {
    try {
      final t = await api.weaveWeftTraced(
        req: wire.WeaveWeftRequestDto(
          swatch: swatch == null ? null : swatchToDto(swatch),
          ppi: _countInput(ppi),
          width: lengthToDto(width),
          wovenLength: lengthToDto(wovenLength),
          items: items.clamp(0, 100000),
          takeup: _fractionInput(takeup),
        ),
        draft: draft == null ? null : _drafts.toDto(draft),
      );
      return TracedEstimate(
        value: WeftAmount(picks: t.picks, total: lengthFromDto(t.total)),
        inputs: _inputs(t.inputs),
        working: t.working,
        notes: t.notes,
      );
    } on String catch (e) {
      throw PlanException(e);
    }
  }

  Future<void> _checkReplaceable(File f) async {
    if (!await f.exists()) return;
    final bytes = await f.readAsBytes();
    try {
      await decodeBytes(bytes);
    } on MaterialsFileException catch (e) {
      throw MaterialsFileException(e.problem, whileSaving: true, detail: e.detail);
    }
  }

  Future<String?> _setAside(File f) async {
    try {
      var target = '${f.path}$corruptSuffix';
      for (var n = 2; await File(target).exists() && n < 1000; n++) {
        target = '${f.path}$corruptSuffix.$n';
      }
      await f.rename(target);
      PlyLog.instance.warn('materials.json could not be read; kept it as ${p.basename(target)}.');
      return target;
    } catch (e) {
      PlyLog.instance.warn('materials.json could not be read or moved aside: $e');
      return null;
    }
  }

  static Future<void> _atomicWrite(File target, List<int> bytes) async {
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(target.path);
  }

  // --- DTO mapping: the ONLY place the materials domain types meet the generated ones. --------

  static wire.InputOriginKind _origin(InputOrigin o) => switch (o) {
        InputOrigin.swatch => wire.InputOriginKind.swatch,
        InputOrigin.entered => wire.InputOriginKind.entered,
        InputOrigin.plyDefault => wire.InputOriginKind.default_,
        InputOrigin.pattern => wire.InputOriginKind.pattern,
      };

  static wire.CountInputDto _countInput(PlanInput<CountOver> i) => wire.CountInputDto(
      origin: _origin(i.origin),
      value: i.value == null ? null : countToDto(i.value!),
      note: i.note);

  static wire.FractionInputDto _fractionInput(PlanInput<double> i) =>
      wire.FractionInputDto(origin: _origin(i.origin), value: i.value ?? 0, note: i.note);

  static List<TracedInput> _inputs(List<wire.TracedInputDto> inputs) => [
        for (final i in inputs)
          TracedInput(
            key: i.key,
            label: i.label,
            value: i.value,
            source: sourceFromKind(i.source),
            basis: i.basis,
            swatchId: i.swatchId,
            materialId: i.materialId,
          ),
      ];

  static ValueSource sourceFromKind(wire.SourceKind k) => switch (k) {
        wire.SourceKind.measured => ValueSource.measured,
        wire.SourceKind.entered => ValueSource.entered,
        wire.SourceKind.default_ => ValueSource.plyDefault,
      };

  static wire.SourceKind kindFromSource(ValueSource s) => switch (s) {
        ValueSource.measured => wire.SourceKind.measured,
        ValueSource.entered => wire.SourceKind.entered,
        ValueSource.plyDefault => wire.SourceKind.default_,
      };

  static LengthUnit lengthUnitFromKind(wire.QuantityLengthUnit k) => switch (k) {
        wire.QuantityLengthUnit.millimeter => LengthUnit.millimeter,
        wire.QuantityLengthUnit.centimeter => LengthUnit.centimeter,
        wire.QuantityLengthUnit.meter => LengthUnit.meter,
        wire.QuantityLengthUnit.inch => LengthUnit.inch,
        wire.QuantityLengthUnit.yard => LengthUnit.yard,
      };

  static wire.QuantityLengthUnit kindFromLengthUnit(LengthUnit u) => switch (u) {
        LengthUnit.millimeter => wire.QuantityLengthUnit.millimeter,
        LengthUnit.centimeter => wire.QuantityLengthUnit.centimeter,
        LengthUnit.meter => wire.QuantityLengthUnit.meter,
        LengthUnit.inch => wire.QuantityLengthUnit.inch,
        LengthUnit.yard => wire.QuantityLengthUnit.yard,
      };

  static MassUnit massUnitFromKind(wire.QuantityMassUnit k) => switch (k) {
        wire.QuantityMassUnit.gram => MassUnit.gram,
        wire.QuantityMassUnit.kilogram => MassUnit.kilogram,
        wire.QuantityMassUnit.ounce => MassUnit.ounce,
        wire.QuantityMassUnit.pound => MassUnit.pound,
      };

  static wire.QuantityMassUnit kindFromMassUnit(MassUnit u) => switch (u) {
        MassUnit.gram => wire.QuantityMassUnit.gram,
        MassUnit.kilogram => wire.QuantityMassUnit.kilogram,
        MassUnit.ounce => wire.QuantityMassUnit.ounce,
        MassUnit.pound => wire.QuantityMassUnit.pound,
      };

  static Length lengthFromDto(wire.QuantityLengthDto d) =>
      Length(d.value, lengthUnitFromKind(d.unit));

  static wire.QuantityLengthDto lengthToDto(Length l) =>
      wire.QuantityLengthDto(value: l.value, unit: kindFromLengthUnit(l.unit));

  static Mass massFromDto(wire.QuantityMassDto d) => Mass(d.value, massUnitFromKind(d.unit));

  static wire.QuantityMassDto massToDto(Mass m) =>
      wire.QuantityMassDto(value: m.value, unit: kindFromMassUnit(m.unit));

  static CountOver countFromDto(wire.CountOverDto d) => CountOver(d.count, lengthFromDto(d.over));

  static wire.CountOverDto countToDto(CountOver c) =>
      wire.CountOverDto(count: c.count, over: lengthToDto(c.over));

  static Recorded<Length>? _recLength(wire.RecordedLengthDto? d) =>
      d == null ? null : Recorded(lengthFromDto(d.value), sourceFromKind(d.source));

  static wire.RecordedLengthDto? _recLengthDto(Recorded<Length>? r) => r == null
      ? null
      : wire.RecordedLengthDto(value: lengthToDto(r.value), source: kindFromSource(r.source));

  static Recorded<Mass>? _recMass(wire.RecordedMassDto? d) =>
      d == null ? null : Recorded(massFromDto(d.value), sourceFromKind(d.source));

  static wire.RecordedMassDto? _recMassDto(Recorded<Mass>? r) => r == null
      ? null
      : wire.RecordedMassDto(value: massToDto(r.value), source: kindFromSource(r.source));

  static Recorded<CountOver>? _recCount(wire.RecordedCountOverDto? d) =>
      d == null ? null : Recorded(countFromDto(d.value), sourceFromKind(d.source));

  static wire.RecordedCountOverDto? _recCountDto(Recorded<CountOver>? r) => r == null
      ? null
      : wire.RecordedCountOverDto(value: countToDto(r.value), source: kindFromSource(r.source));

  static YarnWeightCategory weightFromKind(YarnWeightKind k) => switch (k) {
        YarnWeightKind.lace => YarnWeightCategory.lace,
        YarnWeightKind.superFine => YarnWeightCategory.superFine,
        YarnWeightKind.fine => YarnWeightCategory.fine,
        YarnWeightKind.light => YarnWeightCategory.light,
        YarnWeightKind.medium => YarnWeightCategory.medium,
        YarnWeightKind.bulky => YarnWeightCategory.bulky,
        YarnWeightKind.superBulky => YarnWeightCategory.superBulky,
        YarnWeightKind.jumbo => YarnWeightCategory.jumbo,
      };

  static YarnWeightKind kindFromWeight(YarnWeightCategory w) => switch (w) {
        YarnWeightCategory.lace => YarnWeightKind.lace,
        YarnWeightCategory.superFine => YarnWeightKind.superFine,
        YarnWeightCategory.fine => YarnWeightKind.fine,
        YarnWeightCategory.light => YarnWeightKind.light,
        YarnWeightCategory.medium => YarnWeightKind.medium,
        YarnWeightCategory.bulky => YarnWeightKind.bulky,
        YarnWeightCategory.superBulky => YarnWeightKind.superBulky,
        YarnWeightCategory.jumbo => YarnWeightKind.jumbo,
      };

  static MaterialRecord materialFromDto(wire.MaterialDto d) => MaterialRecord(
        id: d.id,
        name: d.name,
        maker: d.maker,
        fibers: [for (final f in d.fibers) FiberPart(f.fiber, f.percent)],
        weight: d.weight == null ? null : weightFromKind(d.weight!),
        structure: d.structure,
        lengthPerMass: d.lengthPerMass == null
            ? null
            : Recorded(
                LengthPerMass(lengthFromDto(d.lengthPerMass!.value.length),
                    massFromDto(d.lengthPerMass!.value.mass)),
                sourceFromKind(d.lengthPerMass!.source)),
        wpi: _recCount(d.wpi),
        color: d.color,
        dyeLot: d.dyeLot,
        availableMass: _recMass(d.availableMass),
        availableLength: _recLength(d.availableLength),
        notes: d.notes,
      );

  static wire.MaterialDto materialToDto(MaterialRecord m) => wire.MaterialDto(
        id: m.id,
        name: m.name,
        maker: m.maker,
        fibers: [for (final f in m.fibers) wire.FiberPartDto(fiber: f.fiber, percent: f.percent)],
        weight: m.weight == null ? null : kindFromWeight(m.weight!),
        structure: m.structure,
        lengthPerMass: m.lengthPerMass == null
            ? null
            : wire.RecordedLengthPerMassDto(
                value: wire.LengthPerMassDto(
                    length: lengthToDto(m.lengthPerMass!.value.length),
                    mass: massToDto(m.lengthPerMass!.value.mass)),
                source: kindFromSource(m.lengthPerMass!.source)),
        wpi: _recCountDto(m.wpi),
        color: m.color,
        dyeLot: m.dyeLot,
        availableMass: _recMassDto(m.availableMass),
        availableLength: _recLengthDto(m.availableLength),
        notes: m.notes,
      );

  static SwatchStage _stageFromDto(wire.SwatchStageDto d) => SwatchStage(
        width: _recLength(d.width),
        length: _recLength(d.length),
        across: _recCount(d.across),
        along: _recCount(d.along),
        conditions: d.conditions,
      );

  static wire.SwatchStageDto _stageToDto(SwatchStage s) => wire.SwatchStageDto(
        width: _recLengthDto(s.width),
        length: _recLengthDto(s.length),
        across: _recCountDto(s.across),
        along: _recCountDto(s.along),
        conditions: s.conditions,
      );

  static SwatchCraft craftFromKind(wire.SwatchCraftKind k) => switch (k) {
        wire.SwatchCraftKind.weaving => SwatchCraft.weaving,
        wire.SwatchCraftKind.knitting => SwatchCraft.knitting,
        wire.SwatchCraftKind.nalbinding => SwatchCraft.nalbinding,
      };

  static wire.SwatchCraftKind kindFromCraft(SwatchCraft c) => switch (c) {
        SwatchCraft.weaving => wire.SwatchCraftKind.weaving,
        SwatchCraft.knitting => wire.SwatchCraftKind.knitting,
        SwatchCraft.nalbinding => wire.SwatchCraftKind.nalbinding,
      };

  static YarnRole roleFromKind(wire.YarnRoleKind k) => switch (k) {
        wire.YarnRoleKind.main => YarnRole.main,
        wire.YarnRoleKind.contrast => YarnRole.contrast,
        wire.YarnRoleKind.warp => YarnRole.warp,
        wire.YarnRoleKind.weft => YarnRole.weft,
      };

  static wire.YarnRoleKind kindFromRole(YarnRole r) => switch (r) {
        YarnRole.main => wire.YarnRoleKind.main,
        YarnRole.contrast => wire.YarnRoleKind.contrast,
        YarnRole.warp => wire.YarnRoleKind.warp,
        YarnRole.weft => wire.YarnRoleKind.weft,
      };

  static SwatchRecord swatchFromDto(wire.SwatchDto d) => SwatchRecord(
        id: d.id,
        name: d.name,
        craft: d.craft == null ? null : craftFromKind(d.craft!),
        technique: d.technique,
        date: d.date,
        yarns: [
          for (final y in d.yarns)
            SwatchYarn(
                materialId: y.materialId,
                name: y.name,
                role: y.role == null ? null : roleFromKind(y.role!)),
        ],
        tools: d.tools,
        sett: _recCount(d.sett),
        widthInReed: _recLength(d.widthInReed),
        onLoom: _stageFromDto(d.onLoom),
        before: _stageFromDto(d.before),
        after: _stageFromDto(d.after),
        finishing: d.finishing,
        mass: _recMass(d.mass),
        tension: d.tension,
        provenance: d.provenance,
        notes: d.notes,
      );

  static wire.SwatchDto swatchToDto(SwatchRecord s) => wire.SwatchDto(
        id: s.id,
        name: s.name,
        craft: s.craft == null ? null : kindFromCraft(s.craft!),
        technique: s.technique,
        date: s.date,
        yarns: [
          for (final y in s.yarns)
            wire.SwatchYarnDto(
                materialId: y.materialId,
                name: y.name,
                role: y.role == null ? null : kindFromRole(y.role!)),
        ],
        tools: s.tools,
        sett: _recCountDto(s.sett),
        widthInReed: _recLengthDto(s.widthInReed),
        onLoom: _stageToDto(s.onLoom),
        before: _stageToDto(s.before),
        after: _stageToDto(s.after),
        finishing: s.finishing,
        mass: _recMassDto(s.mass),
        tension: s.tension,
        provenance: s.provenance,
        notes: s.notes,
      );

  static MaterialLibrary libraryFromDto(wire.MaterialLibraryDto d) => MaterialLibrary(
        materials: List.unmodifiable([for (final m in d.materials) materialFromDto(m)]),
        swatches: List.unmodifiable([for (final s in d.swatches) swatchFromDto(s)]),
      );

  static wire.MaterialLibraryDto libraryToDto(MaterialLibrary l) => wire.MaterialLibraryDto(
        materials: [for (final m in l.materials) materialToDto(m)],
        swatches: [for (final s in l.swatches) swatchToDto(s)],
      );

  static RecordReport reportFromDto(wire.RecordReportDto r) => RecordReport(
        diagnostics: [
          for (final d in r.diagnostics)
            RecordDiagnostic(
              code: d.code,
              isError: d.severity == wire.RecordSeverityKind.error,
              field: d.field,
              message: d.message,
            ),
        ],
        figures: [
          for (final f in r.figures)
            Figure(code: f.code, label: f.label, value: f.value, text: f.text, from: f.from),
        ],
      );
}

/// A planning estimate the engine could not work out, with its sentence (shown as is).
class PlanException implements Exception {
  const PlanException(this.message);

  final String message;

  @override
  String toString() => message;
}
