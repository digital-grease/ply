import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../models/draft_meta.dart';
import '../models/nalbind_project.dart';
import '../rust/api.dart';
import '../rust/nalbind_dto.dart';

/// The one place the app touches the generated bridge symbols for `ply-nalbind` — the nalbind analog
/// of [DraftRepository] / [KnitRepository]. The reference screen + notation playground depend on this,
/// never on `api.dart` directly.
///
/// The stitch reference (builtins, parse, diagram, validate) is engine-backed and read-only; the
/// PROJECT layer (save/list/open/rename/delete) is on-device persistence — a `<documents>/nalbinds/
/// <id>.{plynal,json}` pair mirroring the knit triplet, MINUS the engine-native body and the thumbnail
/// (nalbinding has no chart to render). See `docs/NALBIND_DESIGN.md`.
class NalbindRepository {
  NalbindRepository();

  // --- Stitch reference (engine-backed, read-only) ---------------------------

  /// The curated builtin stitch dictionary (~12 stitches).
  Future<List<NalbindStitchDto>> builtins() => nalbindBuiltin();

  /// Parse a Hansen-notation string into an anonymous stitch (the notation playground). Throws on an
  /// unrecognized character (the bridge returns the parse message).
  Future<NalbindStitchDto> parse(String notation) => parseNalbind(notation: notation);

  /// The canonical Hansen string for a stitch.
  Future<String> printNotation(NalbindStitchDto dto) => printNalbind(dto: dto);

  /// The per-stitch structural loop diagram (a vector model the painter draws).
  Future<DiagramDto> diagram(NalbindStitchDto dto) => nalbindDiagram(dto: dto);

  /// Validate a stitch; empty list = clean.
  Future<List<NalbindIssueDto>> validate(NalbindStitchDto dto) => validateNalbind(dto: dto);

  /// A stitch + its diagram together (the reference list shows both).
  Future<({NalbindStitchDto stitch, DiagramDto diagram})> withDiagram(NalbindStitchDto s) async =>
      (stitch: s, diagram: await diagram(s));

  // ---------------------------------------------------------------------------
  // Persistence: <documents>/nalbinds/<id>.{plynal,json} (mirrors KnitRepository, no thumb/native).
  // ---------------------------------------------------------------------------

  static const Uuid _uuid = Uuid();
  Directory? _dirCache;

  /// Tests point this at a temp dir so persistence runs without `path_provider` (mirrors
  /// `AppSettingsRepository.dirOverride`). Null in production.
  Directory? dirOverride;

  Future<Directory> _dir() async {
    final override = dirOverride;
    if (override != null) {
      await override.create(recursive: true);
      return override;
    }
    final cached = _dirCache;
    if (cached != null) return cached;
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'nalbinds'));
    await dir.create(recursive: true);
    _dirCache = dir;
    return dir;
  }

  String _projectPath(Directory d, String id) => p.join(d.path, '$id.plynal');
  String _jsonPath(Directory d, String id) => p.join(d.path, '$id.json');

  /// Save a project as the `<id>.{plynal,json}` pair, returning its id. The project body is written
  /// FIRST and the sidecar LAST, so [listProjects] never sees a `.json` without its `.plynal`.
  Future<String> saveProject(NalbindProject project, {String? id}) async {
    final dir = await _dir();
    final projectId = id ?? _uuid.v4();
    final now = DateTime.now();
    try {
      await _atomicWrite(File(_projectPath(dir, projectId)), jsonEncode(project.toJson()));
      // Preserve the original savedAt on a re-save; bump lastOpened.
      DateTime savedAt = now;
      if (id != null) {
        try {
          savedAt = (await _readSidecar(dir, id)).savedAt;
        } catch (_) {/* first save / missing sidecar */}
      }
      final meta = DraftMeta(
        name: project.name.isEmpty ? 'Untitled' : project.name,
        craft: 'Nalbinding',
        notes: project.notes,
        savedAt: savedAt,
        lastOpened: now,
      );
      await _atomicWrite(File(_jsonPath(dir, projectId)), jsonEncode(meta.toJson()));
      return projectId;
    } on FileSystemException catch (e) {
      throw Exception('Could not save the project: ${e.message}');
    }
  }

  /// List every complete saved project, newest-opened first. Skips a sidecar whose `.plynal` is gone
  /// and a malformed sidecar (one bad file never breaks the whole list).
  Future<List<NalbindProjectEntry>> listProjects() async {
    final dir = await _dir();
    if (!await dir.exists()) return const [];
    final entries = <NalbindProjectEntry>[];
    await for (final ent in dir.list()) {
      if (ent is! File || p.extension(ent.path) != '.json') continue;
      final id = p.basenameWithoutExtension(ent.path);
      try {
        if (!await File(_projectPath(dir, id)).exists()) continue;
        final meta = DraftMeta.fromJson(jsonDecode(await ent.readAsString()) as Map<String, dynamic>);
        entries.add(NalbindProjectEntry(id: id, name: meta.name, lastOpened: meta.lastOpened));
      } catch (_) {
        continue;
      }
    }
    entries.sort((a, b) => b.lastOpened.compareTo(a.lastOpened));
    return entries;
  }

  /// Read a saved project's `.plynal` body.
  Future<NalbindProject> readProject(String id) async {
    final dir = await _dir();
    try {
      final json = jsonDecode(await File(_projectPath(dir, id)).readAsString());
      return NalbindProject.fromJson(json as Map<String, dynamic>);
    } on FileSystemException catch (e) {
      throw Exception('Could not open the project: ${e.message}');
    }
  }

  /// Mark a project opened (bumps `lastOpened`, rewrites the sidecar).
  Future<void> touchOpened(String id) async {
    final dir = await _dir();
    final meta = await _readSidecar(dir, id);
    await _atomicWrite(File(_jsonPath(dir, id)), jsonEncode(meta.copyWith(lastOpened: DateTime.now()).toJson()));
  }

  /// Delete a project's pair (sidecar FIRST so [listProjects] drops it atomically). Tolerant of
  /// already-missing files.
  Future<void> deleteProject(String id) async {
    final dir = await _dir();
    for (final path in [_jsonPath(dir, id), _projectPath(dir, id)]) {
      final f = File(path);
      if (await f.exists()) {
        try {
          await f.delete();
        } catch (_) {/* tolerate races / permission quirks */}
      }
    }
  }

  Future<DraftMeta> _readSidecar(Directory dir, String id) async => DraftMeta.fromJson(
        jsonDecode(await File(_jsonPath(dir, id)).readAsString()) as Map<String, dynamic>,
      );

  Future<void> _atomicWrite(File target, String contents) async {
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsString(contents, flush: true);
    await tmp.rename(target.path);
  }
}
