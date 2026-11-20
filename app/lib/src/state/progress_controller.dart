// One tracking session over a project's progress record (ADR 0023): the place on screen, the record
// as stored, and every change written at once. Craft-free: the trackers decide what the next unit is
// and ask the engine for its fingerprint; this keeps the record, the log, undo and notes.

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/library_backup.dart' show BackupCraft;
import '../data/progress_repository.dart';
import '../models/progress.dart';

class ProgressController extends ChangeNotifier {
  ProgressController({
    required this.repository,
    required this.craft,
    required this.id,
    required Progress progress,
    required WorkPlace place,
    PlaceBasis? basis,
    this.pendingCheck = false,
    DateTime Function()? clock,
    bool fromRecord = true,
  })  : _progress = progress,
        _place = place,
        _basis = basis,
        _clock = clock ?? DateTime.now,
        _guard = ProgressSaveGuard(expectNoRecord: !fromRecord);

  final ProgressRepository repository;
  final BackupCraft craft;
  final String id;
  final DateTime Function() _clock;

  Progress _progress;
  WorkPlace _place;
  PlaceBasis? _basis;

  /// Whether the session began from a record read from the device ([ProgressController.new]'s
  /// `fromRecord`; false when none was found): until this session writes one, a record that appears
  /// is never written over (ADR 0023, amendment of 2026-11-19).
  final ProgressSaveGuard _guard;

  /// A save met a record this session never read (see [ProgressSaveGuard]): nothing was written, and
  /// the tracker reads the record again and shows it.
  bool foundAgain = false;

  /// The place on screen was shown for checking (the pattern changed under it) and the crafter has not
  /// said it is right yet. Nothing about it is stored until they act.
  bool pendingCheck;

  /// Why the last write failed, until a later one succeeds.
  String? saveError;

  /// The record as the app holds it (the last change, written or being written).
  Progress get progress => _progress;

  /// The place on screen.
  WorkPlace get place => _place;

  /// What the place on screen is worked against (from the engine).
  PlaceBasis? get basis => _basis;

  bool get canUndo => !pendingCheck && _progress.canUndo;

  List<ProgressNote> get notesHere => _progress.notesAt(_place);

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Hold [next] as the record and write it. A write still in flight when the tracker closes
  /// finishes; it just has no screen to tell.
  Future<void> _write(Progress next) async {
    _progress = next;
    _notify();
    try {
      final written = await repository.save(craft, id, next, guard: _guard);
      // A later change may have replaced the record meanwhile; keep the newest.
      if (identical(_progress, next)) _progress = written;
      saveError = null;
    } on ProgressFileException catch (e) {
      saveError = e.message;
      if (e.problem == ProgressProblem.foundAgain) foundAgain = true;
    } catch (e) {
      saveError = 'Your place could not be saved: $e';
    }
    _notify();
  }

  /// Record the place on screen as right when it was shown for checking: a `fix` entry when it is not
  /// where the record had it, otherwise just its new basis.
  Future<void> accept() async {
    final basis = _basis;
    // Without the engine's basis for the place on screen nothing is stored: it stays to be checked.
    if (!pendingCheck || basis == null) return;
    pendingCheck = false;
    final stored = _progress.place;
    final now = _clock();
    // Not the same place when either its number or the step it names differs (a nalbinding place
    // whose step is gone is shown at the same number on another step): that move is logged.
    if (stored != null && !(stored.sameSpot(_place) && stored.samePlace(_place))) {
      await _write(
          _progress.moved(from: stored, to: _place, basis: basis, kind: LogKind.fix, now: now));
    } else {
      await _write(_progress.rebased(place: _place, basis: basis, now: now));
    }
  }

  /// Move to [to] (worked against [basis], which the engine gave for it: a place is never stored
  /// without one) and log it as [kind]. A place shown for checking is accepted first (Next and
  /// Previous count as accepting it; a jump replaces it).
  Future<void> moveTo(WorkPlace to, PlaceBasis basis, LogKind kind, {int count = 1}) async {
    if (pendingCheck && kind != LogKind.jump) await accept();
    pendingCheck = false;
    final from = _place;
    _place = to;
    _basis = basis;
    await _write(
        _progress.moved(from: from, to: to, basis: basis, kind: kind, now: _clock(), count: count));
  }

  /// Undo the last change of place. Returns false when there is nothing to undo. The place on screen
  /// becomes the stored place before it ([start] when none was stored); the tracker then checks it
  /// against the pattern again, as on opening, and shows it with [settle].
  Future<bool> undo({required WorkPlace start}) async {
    if (!canUndo) return false;
    final back = _progress.undone(now: _clock());
    if (back == null) return false;
    _place = back.place ?? start;
    _basis = back.basis;
    await _write(back);
    return true;
  }

  /// Add a note pinned to the place on screen. Throws [ProgressLimitException] with a sentence.
  Future<void> addNote(String text) => _write(_progress.withNote(_place, text, now: _clock()));

  /// Change a note. Throws [ProgressLimitException] with a sentence.
  Future<void> editNote(String noteId, String text) =>
      _write(_progress.withNoteText(noteId, text, now: _clock()));

  Future<void> deleteNote(String noteId) => _write(_progress.withoutNote(noteId, now: _clock()));

  /// Show [shown] (worked against [basis]) for the stored place, as the engine resolved it against the
  /// pattern as it is now: [check] when the crafter must check it before going on. Nothing is
  /// written.
  void settle({required WorkPlace shown, PlaceBasis? basis, required bool check}) {
    _place = shown;
    _basis = basis;
    pendingCheck = check;
    _notify();
  }

  /// Remove the project's progress (place, log and notes) and start over at [start].
  Future<void> clear({required WorkPlace start, PlaceBasis? basis}) async {
    await repository.delete(craft, id);
    // No record now: one that appears before this session writes is not its own.
    _guard.expectNoRecord = true;
    _progress = Progress(craft: _progress.craft);
    _place = start;
    _basis = basis;
    pendingCheck = false;
    saveError = null;
    _notify();
  }
}

/// The progress records on the device. Tests override it with one over a temp folder.
final progressRepositoryProvider = Provider<ProgressRepository>((_) => ProgressRepository());

/// The clock progress changes are stamped with. Tests override it.
final progressClockProvider = Provider<DateTime Function()>((_) => DateTime.now);
