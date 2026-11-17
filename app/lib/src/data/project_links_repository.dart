import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/draft_meta.dart';
import '../models/project_materials.dart';
import 'library_backup.dart' show BackupCraft, isBackupProjectId;
import 'sidecar_writes.dart';

/// One saved project, as a link or usage list names it.
class ProjectRef {
  const ProjectRef(this.craft, this.id, {this.name = ''});

  final BackupCraft craft;
  final String id;
  final String name;

  @override
  bool operator ==(Object other) => other is ProjectRef && other.craft == craft && other.id == id;

  @override
  int get hashCode => Object.hash(craft, id);
}

/// Which projects link which records.
class LinkUsage {
  const LinkUsage({this.materials = const {}, this.swatches = const {}});

  static const LinkUsage none = LinkUsage();

  /// Material id to the projects that link it.
  final Map<String, List<ProjectRef>> materials;

  /// Swatch id to the projects that link it.
  final Map<String, List<ProjectRef>> swatches;

  List<ProjectRef> ofMaterial(String id) => materials[id] ?? const [];
  List<ProjectRef> ofSwatch(String id) => swatches[id] ?? const [];
}

/// A project's sidecar could not be read or written for its links.
class ProjectLinksException implements Exception {
  const ProjectLinksException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Reads and writes a project's links to the library's materials and swatches: the `materials` key
/// of its sidecar (`<documents>/<craft folder>/<id>.json`, every craft; ADR 0016). A write changes
/// that key alone: every other key keeps its value, and the file is replaced atomically. The editors'
/// saves keep the key as it is on disk, so a link takes effect at once and never makes a project
/// unsaved.
class ProjectLinksRepository {
  ProjectLinksRepository({@visibleForTesting Directory? docsOverride})
      : _docsOverride = docsOverride;

  final Directory? _docsOverride;

  Future<Directory> _docs() async => _docsOverride ?? await getApplicationDocumentsDirectory();

  Future<File> _sidecar(BackupCraft craft, String id) async {
    if (!isBackupProjectId(id)) {
      throw const ProjectLinksException('This project has no saved file.');
    }
    return File(p.join((await _docs()).path, craft.directory, '$id.json'));
  }

  Future<Map<String, dynamic>> _readJson(File f) async {
    if (!await f.exists()) {
      throw const ProjectLinksException('Save the project first to link materials and swatches.');
    }
    final Object? json;
    try {
      json = jsonDecode(await f.readAsString());
    } catch (_) {
      throw const ProjectLinksException('This project\'s details could not be read.');
    }
    if (json is! Map<String, dynamic>) {
      throw const ProjectLinksException('This project\'s details could not be read.');
    }
    return json;
  }

  /// The project's links (none when it has no `materials` key).
  Future<ProjectMaterials> read(BackupCraft craft, String id) async {
    final json = await _readJson(await _sidecar(craft, id));
    return ProjectMaterials.fromJson(json[ProjectMaterials.key]) ?? ProjectMaterials.none;
  }

  /// Replace the project's links with [links] (the key is removed when there are none). Refuses a
  /// sidecar this build cannot read, or one written by a newer sidecar schema, without writing.
  Future<void> write(BackupCraft craft, String id, ProjectMaterials links) async {
    final f = await _sidecar(craft, id);
    // One write at a time to this sidecar (an editor's save may be writing it too), and a temp file
    // of its own, never the `<id>.json.tmp` the saves use.
    await SidecarWrites.run(f.path, () => _write(f, links));
  }

  Future<void> _write(File f, ProjectMaterials links) async {
    final json = await _readJson(f);
    final version = json['schemaVersion'];
    if (version is int && version > DraftMeta.currentSchemaVersion) {
      throw const ProjectLinksException(
          'This project was saved by a newer version of Ply, so its links were not changed.');
    }
    final raw = json[ProjectMaterials.key];
    if (raw != null && raw is! Map) {
      throw const ProjectLinksException(
          'This project\'s links were saved in a form this version of Ply cannot change.');
    }
    if (links.isEmpty) {
      json.remove(ProjectMaterials.key);
    } else {
      json[ProjectMaterials.key] = links.toJson();
    }
    final tmp = File('${f.path}.links.tmp');
    await tmp.writeAsString(jsonEncode(json), flush: true);
    await tmp.rename(f.path);
  }

  /// Which projects of every craft link which records. A sidecar that cannot be read is skipped (the
  /// library does not list it either).
  Future<LinkUsage> usage() async {
    final docs = await _docs();
    final materials = <String, List<ProjectRef>>{};
    final swatches = <String, List<ProjectRef>>{};
    for (final craft in BackupCraft.values) {
      final dir = Directory(p.join(docs.path, craft.directory));
      if (!await dir.exists()) continue;
      await for (final ent in dir.list(followLinks: false)) {
        if (ent is! File || p.extension(ent.path) != '.json') continue;
        final id = p.basenameWithoutExtension(ent.path);
        if (!isBackupProjectId(id)) continue;
        try {
          final json = jsonDecode(await ent.readAsString());
          if (json is! Map<String, dynamic> || !json.containsKey(ProjectMaterials.key)) continue;
          final name = json['name'] is String ? json['name'] as String : 'Untitled';
          final ref = ProjectRef(craft, id, name: name);
          final ids = ProjectMaterials.idsIn(json);
          for (final m in ids.materials) {
            (materials[m] ??= []).add(ref);
          }
          for (final s in ids.swatches) {
            (swatches[s] ??= []).add(ref);
          }
        } catch (_) {
          continue;
        }
      }
    }
    int byName(ProjectRef a, ProjectRef b) => a.name.compareTo(b.name);
    for (final l in [...materials.values, ...swatches.values]) {
      l.sort(byName);
    }
    return LinkUsage(materials: materials, swatches: swatches);
  }
}
