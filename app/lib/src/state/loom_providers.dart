import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../data/loom_repository.dart';
import '../models/loom_check.dart';
import '../models/loom_profile.dart';
import 'draft_editor_notifier.dart';

/// The loom store (overridable in tests).
final loomRepositoryProvider = Provider<LoomRepository>((_) => LoomRepository());

/// My looms, and how `looms.json` was found.
class LoomLibraryState {
  const LoomLibraryState(this.looms, {this.status = LoomFileStatus.ok, this.setAsidePath});

  final List<LoomProfile> looms;
  final LoomFileStatus status;

  /// Where an unreadable file was moved, when [status] is [LoomFileStatus.setAside].
  final String? setAsidePath;

  /// A newer (or unreachable) file must not be overwritten, so nothing can be added or changed.
  bool get readOnly =>
      status == LoomFileStatus.newer ||
      status == LoomFileStatus.unreachable ||
      status == LoomFileStatus.tooLarge;

  /// Why My looms cannot be used or changed now, in a sentence; null when it can.
  String? get readOnlyReason => switch (status) {
        LoomFileStatus.newer => 'My looms was saved by a newer version of Ply and cannot be used '
            'until Ply is updated.',
        LoomFileStatus.tooLarge => 'Your looms file is too large to open. It was left as it is, '
            'and My looms cannot be used or changed.',
        LoomFileStatus.unreachable => 'My looms could not be reached on this device.',
        LoomFileStatus.ok || LoomFileStatus.setAside => null,
      };

  LoomProfile? byId(String id) {
    for (final l in looms) {
      if (l.id == id) return l;
    }
    return null;
  }

  LoomLibraryState withLooms(List<LoomProfile> looms) =>
      LoomLibraryState(List.unmodifiable(looms), status: LoomFileStatus.ok);
}

/// The weaver's looms: loaded from `looms.json`, and every change saved before the state changes
/// (a failed save throws and leaves the list as it was).
class LoomLibraryNotifier extends AsyncNotifier<LoomLibraryState> {
  static const Uuid _uuid = Uuid();

  @override
  Future<LoomLibraryState> build() async {
    final load = await ref.read(loomRepositoryProvider).load();
    return LoomLibraryState(List.unmodifiable(load.looms),
        status: load.status, setAsidePath: load.setAsidePath);
  }

  /// A new loom id.
  String newId() => _uuid.v4();

  Future<LoomLibraryState> _current() async => state.valueOrNull ?? await future;

  Future<void> _save(List<LoomProfile> looms) async {
    final current = await _current();
    if (current.readOnly) {
      throw LoomFileException(
          switch (current.status) {
            LoomFileStatus.newer => LoomFileProblem.newerVersion,
            LoomFileStatus.tooLarge => LoomFileProblem.tooLarge,
            _ => LoomFileProblem.unreadable,
          },
          whileSaving: true);
    }
    await ref.read(loomRepositoryProvider).saveAll(looms);
    state = AsyncData(current.withLooms(looms));
  }

  /// Add [loom], or replace the loom with its id.
  Future<void> upsert(LoomProfile loom) async {
    final looms = [...(await _current()).looms];
    final i = looms.indexWhere((l) => l.id == loom.id);
    if (i >= 0) {
      looms[i] = loom;
    } else {
      looms.add(loom);
    }
    await _save(looms);
  }

  /// A copy of the loom [id] under a new id, named "<name> (copy)", placed after it.
  Future<LoomProfile?> duplicate(String id) async {
    final looms = [...(await _current()).looms];
    final i = looms.indexWhere((l) => l.id == id);
    if (i < 0) return null;
    final base = looms[i].name.trim().isEmpty ? 'Unnamed loom' : looms[i].name.trim();
    const suffix = ' (copy)';
    final copy = looms[i].copyWith(
      id: newId(),
      name: '${clipToRunes(base, LoomLimits.maxNameChars - suffix.length)}$suffix',
    );
    looms.insert(i + 1, copy);
    await _save(looms);
    return copy;
  }

  Future<void> delete(String id) async {
    final looms = [...(await _current()).looms]..removeWhere((l) => l.id == id);
    await _save(looms);
  }
}

final loomLibraryProvider =
    AsyncNotifierProvider<LoomLibraryNotifier, LoomLibraryState>(LoomLibraryNotifier.new);

/// The open draft's loom choice in this editor session (null = none). Seeded from the sidecar when
/// the editor opens and saved with the draft.
final draftLoomPlanProvider = StateProvider<LoomPlan?>((ref) => null);

/// Whether the editor's loom group is expanded. Reset for each editor session.
final loomCheckExpandedProvider = StateProvider<bool>((ref) => false);

/// What the editor's loom group shows.
sealed class LoomCheckView {
  const LoomCheckView(this.plan);

  final LoomPlan plan;
}

/// The engine's report for the planned loom.
class LoomCheckReady extends LoomCheckView {
  const LoomCheckReady(super.plan, this.loom, this.report);

  final LoomProfile loom;
  final LoomReport report;
}

/// The draft names a loom that is not in My looms (deleted, or restored from another device).
class LoomCheckMissing extends LoomCheckView {
  const LoomCheckMissing(super.plan);
}

/// My looms cannot be used on this device (a newer, too large or unreachable file), so the draft's
/// loom is not checked (it is not missing), or the check failed.
class LoomCheckUnavailable extends LoomCheckView {
  const LoomCheckUnavailable(super.plan, this.reason);

  final String reason;
}

/// The loom check of the open draft: null when the draft names no loom (and then nothing is read).
/// Re-runs on every draft, plan or looms change, LATEST WINS like the structural validation: a slow
/// earlier check never overwrites a newer one.
final loomCheckProvider =
    AutoDisposeAsyncNotifierProvider<LoomCheckController, LoomCheckView?>(LoomCheckController.new);

class LoomCheckController extends AutoDisposeAsyncNotifier<LoomCheckView?> {
  int _seq = 0;

  @override
  Future<LoomCheckView?> build() async {
    final plan = ref.watch(draftLoomPlanProvider);
    if (plan == null) return null;
    final draft = ref.watch(draftEditorProvider.select((s) => s.draft));
    final mySeq = ++_seq;
    var disposed = false;
    ref.onDispose(() => disposed = true);
    final LoomCheckView view;
    try {
      final library = await ref.watch(loomLibraryProvider.future);
      final loom = library.byId(plan.loomId);
      if (loom == null) {
        view = library.readOnly
            ? LoomCheckUnavailable(plan, library.readOnlyReason ?? 'My looms could not be read.')
            : LoomCheckMissing(plan);
      } else {
        final report = await ref.read(loomRepositoryProvider).check(draft, loom, sett: plan.sett);
        view = LoomCheckReady(plan, loom, report);
      }
    } catch (e) {
      if (disposed || mySeq != _seq) return Completer<LoomCheckView?>().future;
      return LoomCheckUnavailable(plan, 'The loom check could not run.');
    }
    if (disposed || mySeq != _seq) {
      return Completer<LoomCheckView?>().future; // superseded: never resolves
    }
    return view;
  }
}
