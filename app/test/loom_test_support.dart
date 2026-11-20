import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ply/src/data/library_backup.dart';
import 'package:ply/src/data/loom_repository.dart';
import 'package:ply/src/models/draft_doc.dart';
import 'package:ply/src/models/loom_check.dart';
import 'package:ply/src/models/loom_profile.dart';
import 'package:ply/src/models/loom_type.dart';

// Shared helpers for the loom tests (ADR 0014). Host tests have no native library, so the engine's
// `looms.json` reader and the loom check are replaced by stand-ins: an in-memory repository for the
// screens and the editor, and a small Dart codec (same envelope and detection rule, a subset of the
// fields) for the file and backup tests. The engine's own format is tested in Rust.

/// A four-shaft jack loom with most things recorded.
const LoomProfile floorLoom = LoomProfile(
  id: 'loom-floor',
  name: 'Floor loom',
  type: LoomType.jack,
  shafts: 4,
  treadles: 6,
  weavingWidth: LoomLength(24, MeasureUnit.inches),
  reeds: [Reed(12, DentUnit.perInch)],
  treadlesAtOnce: 2,
  notes: 'In the studio.',
);

/// A partial profile: only the shaft count is known.
const LoomProfile borrowedLoom = LoomProfile(id: 'loom-borrowed', name: 'Borrowed loom', shafts: 8);

/// The report the engine gives an eight-shaft draft on [floorLoom] (abridged).
const LoomReport notFeasibleReport = LoomReport(
  loomName: 'Floor loom',
  diagnostics: [
    LoomDiagnostic(
      code: 'loom.width_fits',
      severity: LoomSeverity.fits,
      summary: '0.8 of 24 in wide',
      message:
          'This draft is 0.8 in wide in the reed (16 ends at 20 ends per inch, from the file); '
          'Floor loom weaves up to 24 in.',
    ),
    LoomDiagnostic(
      code: 'loom.shafts_exceeded',
      severity: LoomSeverity.notFeasible,
      summary: 'needs 8 shafts, has 4',
      message: 'This draft threads 8 shafts; Floor loom has 4.',
      location: LoomLocation(kind: LoomLocationKind.shafts, numbers: [5, 6, 7, 8], total: 4),
      remediation: 'Weave it on a loom with at least 8 shafts, or choose a draft for 4 shafts.',
    ),
    LoomDiagnostic(
      code: 'loom.reed_unknown',
      severity: LoomSeverity.notChecked,
      summary: 'no reeds recorded',
      message: 'No reeds are recorded for Floor loom, so no reed was chosen.',
    ),
  ],
);

/// An in-memory loom store: no file, no engine.
class FakeLoomRepository extends LoomRepository {
  FakeLoomRepository({
    List<LoomProfile> looms = const [],
    this.status = LoomFileStatus.ok,
    this.report,
    this.fileSettValue,
  })  : looms = [...looms],
        super(dirOverride: Directory.systemTemp);

  List<LoomProfile> looms;
  LoomFileStatus status;

  /// What [check] returns (a clean report naming the loom when null).
  LoomReport? report;
  Sett? fileSettValue;
  Object? saveError;
  int saves = 0;

  /// When set, every save waits for it (to run changes at the same time).
  Future<void>? saveGate;
  int checks = 0;
  LoomProfile? lastChecked;
  Sett? lastSett;

  @override
  Future<LoomLoad> load() async => LoomLoad([...looms], status: status);

  @override
  Future<void> saveAll(List<LoomProfile> next) async {
    if (saveGate != null) await saveGate;
    if (saveError != null) throw saveError!;
    saves++;
    looms = [...next];
  }

  @override
  Future<LoomReport> check(DraftDoc draft, LoomProfile loom, {Sett? sett}) async {
    checks++;
    lastChecked = loom;
    lastSett = sett;
    return report ?? LoomReport(loomName: loom.displayName, diagnostics: const []);
  }

  @override
  Future<Sett?> fileSett(DraftDoc draft) async => fileSettValue;
}

/// A loom repository over a real directory with a Dart stand-in for the engine's codec: the same
/// envelope and detection rule, and the fields the file tests need. Like the engine, it reports a
/// newer version itself (the repository has no probe of its own), and a file over the size limit is
/// too large unless its envelope states a newer version.
class DartCodecLoomRepository extends LoomRepository {
  DartCodecLoomRepository(Directory dir) : super(dirOverride: dir);

  /// How many times the stand-in engine was asked to read a file.
  int decodes = 0;

  @override
  Future<List<LoomProfile>> decode(String text) async {
    decodes++;
    final size = utf8.encode(text).length;
    if (size > LoomRepository.maxFileBytes) {
      if (size <= LoomRepository.maxProbedFileBytes &&
          (statedVersion(text, kLoomsFormat) ?? 0) > kLoomsSchemaVersion) {
        throw const LoomFileException(LoomFileProblem.newerVersion);
      }
      throw const LoomFileException(LoomFileProblem.tooLarge);
    }
    final Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException catch (e) {
      throw LoomFileException(LoomFileProblem.unreadable, detail: '$e');
    }
    if (json is! Map || json['format'] != kLoomsFormat) {
      throw const LoomFileException(LoomFileProblem.unreadable, detail: 'format');
    }
    final v = json['schema_version'];
    if (v is! int || v < 1) throw const LoomFileException(LoomFileProblem.unreadable);
    if (v > kLoomsSchemaVersion) throw const LoomFileException(LoomFileProblem.newerVersion);
    final looms = json['looms'];
    if (looms is! List) throw const LoomFileException(LoomFileProblem.unreadable);
    return [
      for (final l in looms)
        if (l is Map && l['id'] is String)
          LoomProfile(
            id: l['id'] as String,
            name: (l['name'] as String?) ?? '',
            shafts: l['shafts'] as int?,
            treadles: l['treadles'] as int?,
            notes: (l['notes'] as String?) ?? '',
          )
        else
          throw const LoomFileException(LoomFileProblem.unreadable),
    ];
  }

  @override
  Future<String> encode(List<LoomProfile> looms) async => jsonEncode({
        'format': kLoomsFormat,
        'schema_version': kLoomsSchemaVersion,
        'looms': [
          for (final l in looms)
            {
              'id': l.id,
              'name': l.name,
              'shafts': l.shafts,
              'treadles': l.treadles,
              'notes': l.notes,
            },
        ],
      });
}

/// The schema version a file's envelope states by the engine's detection rule (one JSON object
/// whose `format` is [format] and whose `schema_version` is a positive integer), or null: what the
/// stand-in codecs check before anything else, as the engine does.
int? statedVersion(String text, String format) {
  try {
    final json = jsonDecode(text);
    if (json is! Map || json['format'] != format) return null;
    final v = json['schema_version'];
    return v is int && v >= 1 ? v : null;
  } on FormatException {
    return null;
  }
}

/// `looms.json` text the stand-in codec reads, holding [looms].
String loomsText(List<LoomProfile> looms, {int version = kLoomsSchemaVersion}) => jsonEncode({
      'format': kLoomsFormat,
      'schema_version': version,
      'looms': [
        for (final l in looms)
          {
            'id': l.id,
            'name': l.name,
            'shafts': l.shafts,
            'treadles': l.treadles,
            'notes': l.notes
          },
      ],
    });

/// The backup hooks production wires (see `backup_providers.dart`), over [repo].
LoomBackupHooks loomHooks(LoomRepository repo) => LoomBackupHooks(
      currentFile: repo.currentBytes,
      decode: (Uint8List bytes) => repo.decodeBytes(bytes),
      currentLooms: () async {
        final bytes = await repo.currentBytes();
        return bytes == null ? const [] : await repo.decodeBytes(bytes);
      },
      add: repo.addLooms,
    );
