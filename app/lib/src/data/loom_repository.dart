import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../diagnostics/log_buffer.dart';
import '../models/draft_doc.dart';
import '../models/loom_check.dart';
import '../models/loom_profile.dart';
import '../models/loom_type.dart';
import '../rust/api.dart';
import '../rust/dto.dart' show UnitKind;
import '../rust/loom_dto.dart' as wire;
import 'draft_repository.dart';

/// The `format` of `looms.json` (mirrors `ply_weave::loom_file::LOOMS_FORMAT`).
const String kLoomsFormat = 'ply.looms';

/// The `looms.json` schema version this build reads and writes (mirrors
/// `ply_weave::loom_file::LOOMS_SCHEMA_VERSION`).
const int kLoomsSchemaVersion = 1;

/// What stopped Ply from reading, or from replacing, `looms.json`.
enum LoomFileProblem { newerVersion, unreadable, tooLarge }

/// `looms.json` could not be read, or (when [whileSaving]) was not replaced. The file itself is never
/// modified. [message] is the user-facing sentence; [detail] is for logs.
class LoomFileException implements Exception {
  const LoomFileException(this.problem, {this.whileSaving = false, this.detail});

  final LoomFileProblem problem;
  final bool whileSaving;
  final String? detail;

  String get message {
    if (whileSaving) {
      return switch (problem) {
        LoomFileProblem.newerVersion =>
          'Your looms were saved by a newer version of Ply, so they were not changed.',
        LoomFileProblem.tooLarge => 'Your looms file is too large to open, so it was not changed.',
        LoomFileProblem.unreadable =>
          'Your saved looms could not be read, so they were not changed.',
      };
    }
    return switch (problem) {
      LoomFileProblem.newerVersion =>
        'Your looms were saved by a newer version of Ply. Update the app to change them.',
      LoomFileProblem.tooLarge => 'Your looms file is too large to open.',
      LoomFileProblem.unreadable => 'Your saved looms could not be read.',
    };
  }

  @override
  String toString() => detail == null ? message : '$message ($detail)';
}

/// How `looms.json` was found when it was loaded.
enum LoomFileStatus {
  /// Read (or there was none yet).
  ok,

  /// Saved by a newer Ply: left alone, and My looms is read only.
  newer,

  /// Could not be read, so it was moved aside (see [LoomLoad.setAsidePath]) and My looms starts empty.
  setAside,

  /// Too large to open: left where it is (it may come from a newer Ply), and My looms is read only.
  tooLarge,

  /// Could not be reached (an I/O error): left where it is, and My looms is read only for this run.
  unreachable,
}

/// The looms, and how the file was found.
class LoomLoad {
  const LoomLoad(this.looms, {this.status = LoomFileStatus.ok, this.setAsidePath});

  final List<LoomProfile> looms;
  final LoomFileStatus status;

  /// Where an unreadable file was moved, when [status] is [LoomFileStatus.setAside].
  final String? setAsidePath;
}

/// The one place the app touches `looms.json` and the loom bridge symbols (ADR 0014). The engine owns
/// the format and the checks; this repository does the file I/O: atomic writes (temp, flush,
/// rename), never replacing a newer or unreadable file, and moving an unreadable one aside (never
/// over an older copy) before My looms starts empty.
class LoomRepository {
  LoomRepository({@visibleForTesting Directory? dirOverride, DraftRepository? drafts})
      : _dirOverride = dirOverride,
        _drafts = drafts ?? DraftRepository();

  final Directory? _dirOverride;
  final DraftRepository _drafts;

  /// The file name, beside `app_settings.json` and the craft folders.
  static const String fileName = 'looms.json';

  /// The largest `looms.json` read (mirrors `ply_weave::loom_file::MAX_LOOMS_FILE_BYTES`).
  static const int maxFileBytes = 1024 * 1024;

  /// The largest file whose version is still probed when it is over [maxFileBytes], so a larger file
  /// from a newer Ply is reported as newer (mirrors `MAX_PROBED_FILE_BYTES`).
  static const int maxProbedFileBytes = 16 * 1024 * 1024;

  /// The suffix of a file that could not be read and was moved aside.
  static const String corruptSuffix = '.corrupt';

  Future<File> file() async {
    final dir = _dirOverride ?? await getApplicationDocumentsDirectory();
    return File(p.join(dir.path, fileName));
  }

  /// Read the looms. Never throws for the file's content: a newer file is left alone
  /// ([LoomFileStatus.newer]), and so is one too large to open ([LoomFileStatus.tooLarge]: a file is
  /// never moved aside only for its size); an unreadable one is moved aside
  /// ([LoomFileStatus.setAside]).
  Future<LoomLoad> load() async {
    final File f;
    final Uint8List bytes;
    try {
      f = await file();
      if (!await f.exists()) return const LoomLoad([]);
      bytes = await f.readAsBytes();
    } catch (e) {
      PlyLog.instance.warn('looms.json could not be reached: $e');
      return const LoomLoad([], status: LoomFileStatus.unreachable);
    }
    try {
      return LoomLoad(await decodeBytes(bytes));
    } on LoomFileException catch (e) {
      if (e.problem == LoomFileProblem.newerVersion) {
        return const LoomLoad([], status: LoomFileStatus.newer);
      }
      if (e.problem == LoomFileProblem.tooLarge) {
        return const LoomLoad([], status: LoomFileStatus.tooLarge);
      }
      final aside = await _setAside(f);
      return LoomLoad([], status: LoomFileStatus.setAside, setAsidePath: aside);
    }
  }

  /// The looms in [bytes]: checked as UTF-8, then read by the engine ([decode]). Nothing here decodes
  /// the JSON (ADR 0007, amendment of 2026-11-18, later): the engine reads the envelope without
  /// building a tree and says itself when a newer Ply wrote the file, so a newer file is reported
  /// as newer before its looms are looked at. A file over [maxFileBytes] is too large, unless the engine
  /// finds it was written by a newer Ply (it looks only at the envelope of such a file, up to
  /// [maxProbedFileBytes]; a newer Ply may write a larger file). Throws a [LoomFileException].
  Future<List<LoomProfile>> decodeBytes(List<int> bytes) async {
    final overLimit = bytes.length > maxFileBytes;
    final tooLarge = LoomFileException(LoomFileProblem.tooLarge, detail: '${bytes.length} bytes');
    if (bytes.length > maxProbedFileBytes) throw tooLarge;
    final String text;
    try {
      text = utf8.decode(bytes);
    } on FormatException catch (e) {
      throw overLimit ? tooLarge : LoomFileException(LoomFileProblem.unreadable, detail: '$e');
    }
    if (!overLimit) return decode(text);
    try {
      await decode(text);
    } on LoomFileException catch (e) {
      if (e.problem == LoomFileProblem.newerVersion) rethrow;
    } catch (_) {
      // Only a newer version changes what a file over the limit is.
    }
    throw tooLarge;
  }

  /// Read `looms.json` text with the engine. Throws a [LoomFileException]: newer (from the envelope
  /// alone, before the looms are read), too large (over [maxFileBytes] and not newer, or too many
  /// looms) or unreadable. Host tests override this (and [encode]) with a Dart stand-in that reports
  /// a newer version and the size the same way; the engine is the format's owner.
  Future<List<LoomProfile>> decode(String text) async {
    try {
      final lib = await parseLooms(text: text);
      return [for (final l in lib.looms) loomFromDto(l)];
    } on wire.LoomFileFailure catch (f) {
      throw LoomFileException(
        switch (f.kind) {
          wire.LoomFileFailureKind.newerVersion => LoomFileProblem.newerVersion,
          wire.LoomFileFailureKind.tooLarge => LoomFileProblem.tooLarge,
          wire.LoomFileFailureKind.wrongFormat ||
          wire.LoomFileFailureKind.unreadable =>
            LoomFileProblem.unreadable,
        },
        detail: f.message,
      );
    }
  }

  /// Write [looms] as `looms.json` text with the engine. Throws when a profile is outside the limits.
  Future<String> encode(List<LoomProfile> looms) =>
      writeLooms(dto: wire.LoomLibraryDto(looms: [for (final l in looms) loomToDto(l)]));

  /// Save every loom, replacing `looms.json` atomically. Refuses (with [LoomFileException],
  /// `whileSaving`) to replace a file on disk that is newer or cannot be read.
  Future<void> saveAll(List<LoomProfile> looms) async {
    final f = await file();
    await _checkReplaceable(f);
    await _atomicWrite(f, utf8.encode(await encode(looms)));
  }

  /// The bytes of `looms.json` now, or null when there is none.
  Future<Uint8List?> currentBytes() async {
    final f = await file();
    return await f.exists() ? await f.readAsBytes() : null;
  }

  /// Add [added] to the looms in one write (a library restore), and return how to undo it: the
  /// previous bytes are written back exactly, or the file removed when there was none.
  Future<Future<void> Function()> addLooms(List<LoomProfile> added) async {
    final f = await file();
    final before = await f.exists() ? await f.readAsBytes() : null;
    final current = before == null ? const <LoomProfile>[] : await decodeBytes(before);
    await _atomicWrite(f, utf8.encode(await encode([...current, ...added])));
    return () async {
      if (before == null) {
        if (await f.exists()) await f.delete();
      } else {
        await _atomicWrite(f, before);
      }
    };
  }

  /// Check [draft] against [loom] with the engine, using [sett] when the weaver entered one.
  Future<LoomReport> check(DraftDoc draft, LoomProfile loom, {Sett? sett}) async {
    final report = await checkLoomDto(
      draft: _drafts.toDto(draft),
      loom: loomToDto(loom),
      sett: sett == null ? null : settToDto(sett),
    );
    return reportFromDto(report);
  }

  /// The sett [draft]'s WIF gives (`1 / [WARP] Spacing`), or null.
  Future<Sett?> fileSett(DraftDoc draft) async {
    final s = await draftSettDto(draft: _drafts.toDto(draft));
    return s == null ? null : settFromDto(s);
  }

  Future<void> _checkReplaceable(File f) async {
    if (!await f.exists()) return;
    final bytes = await f.readAsBytes();
    try {
      await decodeBytes(bytes);
    } on LoomFileException catch (e) {
      throw LoomFileException(e.problem, whileSaving: true, detail: e.detail);
    }
  }

  /// Move an unreadable file to `looms.json.corrupt` (or `.corrupt.2`, `.corrupt.3`, ... so an older
  /// copy is never replaced). Returns where it went, or null when it could not be moved.
  Future<String?> _setAside(File f) async {
    try {
      var target = '${f.path}$corruptSuffix';
      for (var n = 2; await File(target).exists() && n < 1000; n++) {
        target = '${f.path}$corruptSuffix.$n';
      }
      await f.rename(target);
      PlyLog.instance.warn('looms.json could not be read; kept it as ${p.basename(target)}.');
      return target;
    } catch (e) {
      PlyLog.instance.warn('looms.json could not be read or moved aside: $e');
      return null;
    }
  }

  static Future<void> _atomicWrite(File target, List<int> bytes) async {
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(target.path);
  }

  // --- DTO mapping: the ONLY place the loom domain types meet the generated ones. ---------------

  static LoomType? typeFromKind(wire.LoomTypeKind k) => switch (k) {
        wire.LoomTypeKind.unknown => null,
        wire.LoomTypeKind.jack => LoomType.jack,
        wire.LoomTypeKind.counterbalance => LoomType.counterbalance,
        wire.LoomTypeKind.countermarch => LoomType.countermarch,
        wire.LoomTypeKind.table => LoomType.table,
        wire.LoomTypeKind.dobby => LoomType.dobby,
      };

  static wire.LoomTypeKind kindFromType(LoomType? t) => switch (t) {
        null => wire.LoomTypeKind.unknown,
        LoomType.jack => wire.LoomTypeKind.jack,
        LoomType.counterbalance => wire.LoomTypeKind.counterbalance,
        LoomType.countermarch => wire.LoomTypeKind.countermarch,
        LoomType.table => wire.LoomTypeKind.table,
        LoomType.dobby => wire.LoomTypeKind.dobby,
      };

  static MeasureUnit unitFromKind(UnitKind k) =>
      k == UnitKind.inches ? MeasureUnit.inches : MeasureUnit.centimeters;

  static UnitKind kindFromUnit(MeasureUnit u) =>
      u == MeasureUnit.inches ? UnitKind.inches : UnitKind.centimeters;

  static LoomProfile loomFromDto(wire.LoomProfileDto d) => LoomProfile(
        id: d.id,
        name: d.name,
        type: typeFromKind(d.kind),
        shafts: d.shafts,
        treadles: d.treadles,
        weavingWidth: d.weavingWidth == null
            ? null
            : LoomLength(d.weavingWidth!.value, unitFromKind(d.weavingWidth!.unit)),
        reeds: [
          for (final r in d.reeds)
            Reed(r.dents, r.per == wire.DentUnitKind.perInch ? DentUnit.perInch : DentUnit.per10cm),
        ],
        treadlesAtOnce: d.treadlesAtOnce,
        notes: d.notes,
      );

  static wire.LoomProfileDto loomToDto(LoomProfile l) => wire.LoomProfileDto(
        id: l.id,
        name: l.name,
        kind: kindFromType(l.type),
        shafts: l.shafts,
        treadles: l.treadles,
        weavingWidth: l.weavingWidth == null
            ? null
            : wire.LengthDto(
                value: l.weavingWidth!.value, unit: kindFromUnit(l.weavingWidth!.unit)),
        reeds: [
          for (final r in l.reeds)
            wire.ReedDto(
                dents: r.dents,
                per: r.per == DentUnit.perInch
                    ? wire.DentUnitKind.perInch
                    : wire.DentUnitKind.per10Cm),
        ],
        treadlesAtOnce: l.treadlesAtOnce,
        notes: l.notes,
      );

  static wire.SettDto settToDto(Sett s) => wire.SettDto(ends: s.ends, per: kindFromUnit(s.per));

  static Sett settFromDto(wire.SettDto s) => Sett(s.ends, unitFromKind(s.per));

  static LoomReport reportFromDto(wire.LoomReportDto r) => LoomReport(
        loomName: r.loomName,
        diagnostics: [
          for (final d in r.diagnostics)
            LoomDiagnostic(
              code: d.code,
              severity: switch (d.severity) {
                wire.LoomSeverityKind.notFeasible => LoomSeverity.notFeasible,
                wire.LoomSeverityKind.advice => LoomSeverity.advice,
                wire.LoomSeverityKind.notChecked => LoomSeverity.notChecked,
                wire.LoomSeverityKind.fits => LoomSeverity.fits,
              },
              summary: d.summary,
              message: d.message,
              location: d.location == null
                  ? null
                  : LoomLocation(
                      kind: switch (d.location!.kind) {
                        wire.LoomLocationKind.shafts => LoomLocationKind.shafts,
                        wire.LoomLocationKind.treadles => LoomLocationKind.treadles,
                        wire.LoomLocationKind.picks => LoomLocationKind.picks,
                      },
                      numbers: List<int>.unmodifiable(d.location!.numbers),
                      total: d.location!.total,
                    ),
              remediation: d.remediation,
            ),
        ],
        sett: r.sett == null ? null : settFromDto(r.sett!),
        settSource: switch (r.settSource) {
          null => null,
          wire.SettSourceKind.entered => SettSource.entered,
          wire.SettSourceKind.file => SettSource.file,
        },
        fileSett: r.fileSett == null ? null : settFromDto(r.fileSett!),
        reedWidth: r.reedWidth == null
            ? null
            : LoomLength(r.reedWidth!.value, unitFromKind(r.reedWidth!.unit)),
      );
}
