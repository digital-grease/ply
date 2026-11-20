import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/tablet_repository.dart';
import '../models/progress.dart' show PickPlace;
import '../models/tablet_band.dart';
import '../rust/tablet_dto.dart';
import 'tablet_editor_state.dart';

/// The app's one [TabletRepository] (the sole owner of the tablet FFI). Tests override it.
final tabletRepositoryProvider = Provider<TabletRepository>((_) => TabletRepository());

/// The open band and its undo history.
class TabletEditorNotifier extends Notifier<TabletEditorState> {
  @override
  TabletEditorState build() => TabletEditorState(doc: TabletEditorState.placeholder);

  /// Open [doc] for editing: a clean history, and [doc] the saved baseline. The view chrome (the
  /// stepper's pick, the brush colour) starts again too.
  void load(TabletDocumentDto doc) {
    state = TabletEditorState(doc: doc, saved: doc);
    ref.read(tabletPickProvider.notifier).state = 1;
    ref.read(tabletBrushProvider.notifier).state = doc.palette.isEmpty ? null : 0;
    ref.read(tabletFocusProvider.notifier).state = null;
    ref.read(tabletSavedPlaceProvider.notifier).state = null;
  }

  void markSaved(TabletDocumentDto persisted) => state = state.markSaved(persisted);

  /// One edit (one undo entry); a no-op edit changes nothing.
  void edit(TabletDocumentDto Function(TabletDocumentDto) change) => _move(state.apply(change));

  void undo() => _move(state.undone());
  void redo() => _move(state.redone());

  /// Take [next]; when it changes the band's shape (its cards or its written picks), drop the focus
  /// a check set: the focus names places by position, which then point elsewhere.
  void _move(TabletEditorState next) {
    final before = state.doc;
    state = next;
    if (ref.read(tabletFocusProvider) != null && !sameShape(before, next.doc)) {
      ref.read(tabletFocusProvider.notifier).state = null;
    }
  }
}

final tabletEditorProvider =
    NotifierProvider<TabletEditorNotifier, TabletEditorState>(TabletEditorNotifier.new);

/// The open band.
final tabletDocProvider =
    Provider<TabletDocumentDto>((ref) => ref.watch(tabletEditorProvider.select((s) => s.doc)));

/// Each card id's position (0-based) in the open band, worked out once per change of the cards.
final tabletCardIndexProvider = Provider<Map<String, int>>((ref) {
  final cards = ref.watch(tabletDocProvider.select((d) => d.cards));
  return {for (var i = 0; i < cards.length; i++) cards[i].id: i};
});

/// Whether the tablet rules still await a tablet weaver's review (the engine's flag): the library
/// says so above its thumbnails, which show computed faces. True until the engine answers.
final tabletReviewPendingProvider = FutureProvider<bool>(
    (ref) => ref.watch(tabletRepositoryProvider).reviewPending().catchError((Object _) => true));

/// The editor's tabs.
enum TabletEditorTab { cards, turning, band, checks }

final tabletTabProvider = StateProvider<TabletEditorTab>((_) => TabletEditorTab.cards);

/// The stepper's pick (1-based expanded pick), shown on the Band tab.
final tabletPickProvider = StateProvider<int>((_) => 1);

/// The place saved for the open band by "Weave pick by pick" (ADR 0023): the stepper shows it and
/// can go to it. `null` when there is none (or the band is not saved, or the record cannot be read).
final tabletSavedPlaceProvider = StateProvider<PickPlace?>((_) => null);

/// Which face the band chart shows.
final tabletFaceProvider = StateProvider<TabletFaceKind>((_) => TabletFaceKind.top);

/// Whether the band chart draws each cell's hole letter (so it never relies on colour alone).
final tabletLettersProvider = StateProvider<bool>((_) => false);

/// The palette colour the Cards tab paints holes with; null paints an empty hole.
final tabletBrushProvider = StateProvider<int?>((_) => 0);

/// Pixels per cell of the on-screen band chart and the turning grid.
final tabletCellPxProvider = StateProvider<int>((_) => 22);
const int kTabletCellPxMin = 12;
const int kTabletCellPxMax = 40;

/// Where a selected diagnostic asked the editor to go: a card (0-based), a written pick (0-based
/// segment and step), or an expanded pick (1-based).
class TabletFocus {
  const TabletFocus({this.card, this.segment, this.step, this.pick});
  final int? card;
  final int? segment;
  final int? step;
  final int? pick;
}

final tabletFocusProvider = StateProvider<TabletFocus?>((_) => null);

/// Bands larger than this many cells (cards times expanded picks) wait a moment after an edit
/// before the engine rechecks, redraws or steps them, so a run of edits never queues one long call
/// per edit (each call also encodes the whole band on this isolate); a result for a band that has
/// changed meanwhile is dropped. Smaller bands go to the engine at once.
const int kTabletRecheckCells = 200000;
const Duration kTabletRecheckDelay = Duration(milliseconds: 300);

int _cells(TabletDocumentDto d) => d.cards.length * expandedPicks(d);

/// Waits [kTabletRecheckDelay] for a large band; true when superseded meanwhile.
Future<bool> _settle(TabletDocumentDto doc, bool Function() superseded) async {
  if (_cells(doc) <= kTabletRecheckCells) return false;
  await Future<void>.delayed(kTabletRecheckDelay);
  return superseded();
}

/// The live validation of the open band (every diagnostic, typed). Latest wins: a superseded check
/// never resolves.
final tabletReportProvider =
    AutoDisposeAsyncNotifierProvider<TabletReportController, TabletReportDto>(
        TabletReportController.new);

class TabletReportController extends AutoDisposeAsyncNotifier<TabletReportDto> {
  int _seq = 0;

  @override
  Future<TabletReportDto> build() async {
    final repo = ref.watch(tabletRepositoryProvider);
    final doc = ref.watch(tabletDocProvider);
    final mySeq = ++_seq;
    var disposed = false;
    ref.onDispose(() => disposed = true);
    bool superseded() => disposed || mySeq != _seq;
    if (await _settle(doc, superseded)) return Completer<TabletReportDto>().future;
    final report = await repo.validate(doc);
    if (superseded()) return Completer<TabletReportDto>().future;
    return report;
  }
}

/// The open band's checkpoints (empty while it has errors or is short), for windows anywhere in a
/// long band.
final tabletCheckpointsProvider =
    AutoDisposeAsyncNotifierProvider<TabletCheckpointsController, List<TabletCheckpointDto>>(
        TabletCheckpointsController.new);

class TabletCheckpointsController extends AutoDisposeAsyncNotifier<List<TabletCheckpointDto>> {
  int _seq = 0;

  @override
  Future<List<TabletCheckpointDto>> build() async {
    final repo = ref.watch(tabletRepositoryProvider);
    final doc = ref.watch(tabletDocProvider);
    final mySeq = ++_seq;
    var disposed = false;
    ref.onDispose(() => disposed = true);
    bool superseded() => disposed || mySeq != _seq;
    // Short bands fold from pick 1 in no time: no checkpoints needed.
    if (expandedPicks(doc) <= 256) return const [];
    if (await _settle(doc, superseded)) return Completer<List<TabletCheckpointDto>>().future;
    List<TabletCheckpointDto> cps;
    try {
      cps = await repo.checkpoints(doc);
    } on TabletRunFailure {
      cps = const []; // a band with errors is not simulated at all
    }
    if (superseded()) return Completer<List<TabletCheckpointDto>>().future;
    return cps;
  }
}

/// The checkpoint to resume a window starting at [first] from: the latest one before it.
TabletCheckpointDto? nearestCheckpoint(List<TabletCheckpointDto> cps, int first) {
  TabletCheckpointDto? best;
  for (final c in cps) {
    if (c.pick < first && (best == null || c.pick > best.pick)) best = c;
  }
  return best;
}

/// The picks the band chart shows at once: a page of this many, containing the stepper's pick.
const int kTabletPreviewPicks = 120;

/// The page of picks containing [pick] in a band of [total] picks: (first, last), 1-based.
(int, int) previewPage(int pick, int total) {
  if (total <= 0) return (1, 0);
  final p = pick.clamp(1, total);
  final first = ((p - 1) ~/ kTabletPreviewPicks) * kTabletPreviewPicks + 1;
  final last = (first + kTabletPreviewPicks - 1).clamp(first, total);
  return (first, last);
}

/// What the stepper shows: the open band's pick [TabletStep.pick], every card, simulated.
class TabletStep {
  const TabletStep(this.pick, this.window);
  final int pick;
  final TabletWindowDto window;

  List<TabletCardPickDto> get cards => window.cells;
  TabletPickInfoDto? get info => window.rows.isEmpty ? null : window.rows.first;
}

/// The stepper's pick, simulated (one pick, every card), resumed from the nearest checkpoint.
/// Errors (a band with structural errors) surface as the provider's error.
final tabletStepProvider =
    AutoDisposeAsyncNotifierProvider<TabletStepController, TabletStep>(TabletStepController.new);

class TabletStepController extends AutoDisposeAsyncNotifier<TabletStep> {
  int _seq = 0;

  @override
  Future<TabletStep> build() async {
    final repo = ref.watch(tabletRepositoryProvider);
    final doc = ref.watch(tabletDocProvider);
    final total = expandedPicks(doc);
    final pick = ref.watch(tabletPickProvider).clamp(1, total < 1 ? 1 : total);
    final cps = ref.watch(tabletCheckpointsProvider).valueOrNull ?? const [];
    final mySeq = ++_seq;
    var disposed = false;
    ref.onDispose(() => disposed = true);
    bool superseded() => disposed || mySeq != _seq;
    if (await _settle(doc, superseded)) return Completer<TabletStep>().future;
    final w = await repo.window(doc, pick, pick, checkpoint: nearestCheckpoint(cps, pick));
    if (superseded()) return Completer<TabletStep>().future;
    return TabletStep(pick, w);
  }
}

/// The band chart on screen: one page of picks, drawn by the engine.
class TabletPreview {
  const TabletPreview({required this.image, required this.raster});
  final ui.Image image;

  /// The raster's size, pitch and picks (its pixels are in [image]).
  final TabletRasterDto raster;
}

final tabletPreviewProvider =
    AutoDisposeAsyncNotifierProvider<TabletPreviewController, TabletPreview>(
        TabletPreviewController.new);

class TabletPreviewController extends AutoDisposeAsyncNotifier<TabletPreview> {
  int _seq = 0;

  @override
  Future<TabletPreview> build() async {
    final repo = ref.watch(tabletRepositoryProvider);
    final doc = ref.watch(tabletDocProvider);
    final total = expandedPicks(doc);
    // The page, not the pick: stepping within a page keeps the drawing it has.
    final (first, last) = ref.watch(tabletPickProvider.select((p) => previewPage(p, total)));
    final face = ref.watch(tabletFaceProvider);
    final letters = ref.watch(tabletLettersProvider);
    final cellPx = ref.watch(tabletCellPxProvider);
    final cps = ref.watch(tabletCheckpointsProvider).valueOrNull ?? const [];
    final mySeq = ++_seq;
    var disposed = false;
    ref.onDispose(() => disposed = true);
    bool superseded() => disposed || mySeq != _seq;
    if (await _settle(doc, superseded)) return Completer<TabletPreview>().future;
    final raster = await repo.renderFace(doc, first, last,
        face: face, cellPx: cellPx, letters: letters, checkpoint: nearestCheckpoint(cps, first));
    final image = await repo.decode(raster);
    if (superseded()) {
      image.dispose();
      return Completer<TabletPreview>().future;
    }
    // The image stays alive while the next one renders (the view keeps painting it), as the knit
    // preview's does; only a superseded one is disposed at once.
    return TabletPreview(image: image, raster: raster);
  }
}

/// Whether two versions of a band have the same shape: the same cards in the same order, and the
/// same segments with the same number of written picks. Places named by position (a card, a
/// written pick) mean the same in both.
bool sameShape(TabletDocumentDto a, TabletDocumentDto b) {
  if (identical(a, b)) return true;
  if (a.cards.length != b.cards.length || a.turning.length != b.turning.length) return false;
  for (var i = 0; i < a.cards.length; i++) {
    if (a.cards[i].id != b.cards[i].id) return false;
  }
  for (var i = 0; i < a.turning.length; i++) {
    if (a.turning[i].picks.length != b.turning[i].picks.length) return false;
  }
  return true;
}
