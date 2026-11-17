import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart' show ImageSource;
import 'package:uuid/uuid.dart';

import '../data/library_backup.dart' show BackupCraft;
import '../data/materials_repository.dart';
import '../data/project_links_repository.dart';
import '../models/material_record.dart';

/// The materials store (overridable in tests).
final materialsRepositoryProvider = Provider<MaterialsRepository>((_) => MaterialsRepository());

/// The projects' links store (overridable in tests).
final projectLinksRepositoryProvider =
    Provider<ProjectLinksRepository>((_) => ProjectLinksRepository());

/// The library's materials and swatches, and how `materials.json` was found.
class MaterialLibraryState {
  const MaterialLibraryState(this.library,
      {this.status = MaterialsFileStatus.ok, this.setAsidePath});

  final MaterialLibrary library;
  final MaterialsFileStatus status;
  final String? setAsidePath;

  List<MaterialRecord> get materials => library.materials;
  List<SwatchRecord> get swatches => library.swatches;

  /// A newer (or unreachable, or too large) file must not be overwritten, so nothing can change.
  bool get readOnly =>
      status == MaterialsFileStatus.newer ||
      status == MaterialsFileStatus.unreachable ||
      status == MaterialsFileStatus.tooLarge;

  /// Why the records cannot be used or changed now; null when they can.
  String? get readOnlyReason => switch (status) {
        MaterialsFileStatus.newer => 'Your materials were saved by a newer version of Ply and '
            'cannot be used until Ply is updated.',
        MaterialsFileStatus.tooLarge => 'Your materials file is too large to open. It was left as '
            'it is, and your materials cannot be used or changed.',
        MaterialsFileStatus.unreachable => 'Your materials could not be reached on this device.',
        MaterialsFileStatus.ok || MaterialsFileStatus.setAside => null,
      };

  MaterialRecord? material(String id) {
    for (final m in materials) {
      if (m.id == id) return m;
    }
    return null;
  }

  SwatchRecord? swatch(String id) {
    for (final s in swatches) {
      if (s.id == id) return s;
    }
    return null;
  }

  MaterialLibraryState withLibrary(MaterialLibrary library) =>
      MaterialLibraryState(library, status: MaterialsFileStatus.ok);
}

/// The crafter's materials and swatches: loaded from `materials.json`, and every change saved before
/// the state changes (a failed save throws and leaves the records as they were).
class MaterialLibraryNotifier extends AsyncNotifier<MaterialLibraryState> {
  static const Uuid _uuid = Uuid();

  @override
  Future<MaterialLibraryState> build() async {
    final load = await ref.read(materialsRepositoryProvider).load();
    return MaterialLibraryState(load.library, status: load.status, setAsidePath: load.setAsidePath);
  }

  /// A new record id.
  String newId() => _uuid.v4();

  Future<MaterialLibraryState> _current() async => state.valueOrNull ?? await future;

  /// The last change queued. Changes run one at a time, each on the records the one before it left,
  /// so a delete and a duplicate made together can never bring back a deleted record (whose photos
  /// are gone).
  Future<void> _tail = Future<void>.value();

  Future<T> _serialized<T>(Future<T> Function() change) {
    final run = _tail.then((_) => change());
    _tail = run.then((_) {}, onError: (Object _) {});
    return run;
  }

  Future<void> _save(MaterialLibrary library) async {
    final current = await _current();
    if (current.readOnly) {
      throw MaterialsFileException(
          switch (current.status) {
            MaterialsFileStatus.newer => MaterialsFileProblem.newerVersion,
            MaterialsFileStatus.tooLarge => MaterialsFileProblem.tooLarge,
            _ => MaterialsFileProblem.unreadable,
          },
          whileSaving: true);
    }
    await ref.read(materialsRepositoryProvider).saveAll(library);
    state = AsyncData(current.withLibrary(library));
  }

  static List<T> _upsert<T>(List<T> list, T item, String Function(T) id) {
    final out = [...list];
    final i = out.indexWhere((x) => id(x) == id(item));
    if (i >= 0) {
      out[i] = item;
    } else {
      out.add(item);
    }
    return out;
  }

  Future<void> upsertMaterial(MaterialRecord m) => _serialized(() async {
        final lib = (await _current()).library;
        await _save(MaterialLibrary(
            materials: _upsert(lib.materials, m, (x) => x.id), swatches: lib.swatches));
      });

  Future<void> upsertSwatch(SwatchRecord s) => _serialized(() async {
        final lib = (await _current()).library;
        await _save(MaterialLibrary(
            materials: lib.materials, swatches: _upsert(lib.swatches, s, (x) => x.id)));
      });

  static String copyName(String name, String fallback) {
    const suffix = ' (copy)';
    final base = name.trim().isEmpty ? fallback : name.trim();
    return '${clipRunes(base, MaterialLimits.maxNameChars - suffix.length)}$suffix';
  }

  /// A copy of material [id] under a new id, named "<name> (copy)", placed after it.
  Future<MaterialRecord?> duplicateMaterial(String id) => _serialized(() async {
        final lib = (await _current()).library;
        final i = lib.materials.indexWhere((m) => m.id == id);
        if (i < 0) return null;
        final copy = lib.materials[i]
            .copyWith(id: newId(), name: copyName(lib.materials[i].name, 'Unnamed material'));
        await _save(MaterialLibrary(
            materials: [...lib.materials]..insert(i + 1, copy), swatches: lib.swatches));
        return copy;
      });

  /// A copy of swatch [id] under a new id (without its photos, which are of the first swatch).
  Future<SwatchRecord?> duplicateSwatch(String id) => _serialized(() async {
        final lib = (await _current()).library;
        final i = lib.swatches.indexWhere((s) => s.id == id);
        if (i < 0) return null;
        final copy = lib.swatches[i]
            .copyWith(id: newId(), name: copyName(lib.swatches[i].name, 'Unnamed swatch'));
        await _save(MaterialLibrary(
            materials: lib.materials, swatches: [...lib.swatches]..insert(i + 1, copy)));
        return copy;
      });

  /// Delete material [id]. Projects and swatches that name it keep its name.
  Future<void> deleteMaterial(String id) => _serialized(() async {
        final lib = (await _current()).library;
        await _save(MaterialLibrary(
            materials: [...lib.materials]..removeWhere((m) => m.id == id), swatches: lib.swatches));
      });

  /// Delete swatch [id] and its photos. Projects that link it keep its name.
  Future<void> deleteSwatch(String id) => _serialized(() async {
        final lib = (await _current()).library;
        await _save(MaterialLibrary(
            materials: lib.materials, swatches: [...lib.swatches]..removeWhere((s) => s.id == id)));
        await ref.read(materialsRepositoryProvider).deletePhotos(id);
      });
}

final materialLibraryProvider =
    AsyncNotifierProvider<MaterialLibraryNotifier, MaterialLibraryState>(
        MaterialLibraryNotifier.new);

/// Whether the crafter has any material or swatch. The editors offer "Materials and swatches..."
/// only then (or when the project already links one), so with no records every screen looks as it
/// did before.
final hasMaterialRecordsProvider = Provider<bool>((ref) {
  final lib = ref.watch(materialLibraryProvider).valueOrNull;
  return lib != null && !lib.library.isEmpty;
});

/// Which projects link which records (for the delete confirmation and the lists). Refreshed by
/// invalidating it after a link changes.
final linkUsageProvider = FutureProvider.autoDispose<LinkUsage>(
    (ref) => ref.read(projectLinksRepositoryProvider).usage());

/// Picks a swatch photo (camera or gallery) and returns its path, or null when cancelled. Null here
/// means the system picker; the device tests override it with a file of their own.
final swatchPhotoPickerProvider =
    Provider<Future<String?> Function(ImageSource source)?>((_) => null);

/// The project open in an editor (its craft, and its id once saved), so the planning calculators
/// can offer the swatches it links first. Set by the weaving and knitting editors when they load.
final openProjectProvider = StateProvider<({BackupCraft craft, String? id})?>((_) => null);
