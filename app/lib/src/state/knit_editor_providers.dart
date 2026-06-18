import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/knit_repository.dart';
import '../models/knit_stitches.dart';
import '../rust/dto.dart' show ColorDto;
import '../rust/knit_dto.dart';
import 'knit_editor_state.dart';

/// The app's single [KnitRepository] (the sole owner of the knit FFI). The default is a real
/// instance (the FFI is initialized globally in `main`); tests override it with a fake.
final knitRepositoryProvider = Provider<KnitRepository>((_) => KnitRepository());

/// The on-screen pixels-per-cell for the chart view. Bounded by [kKnitZoomMin]/[kKnitZoomMax].
final knitZoomProvider = StateProvider<int>((ref) => 24);

/// Pixels-per-cell zoom bounds + step for the chart view.
const int kKnitZoomMin = 12;
const int kKnitZoomMax = 48;
const int kKnitZoomStep = 4;

/// Whether the inline validation band is expanded to its full issue list (vs the one-line summary).
final knitIssuesExpandedProvider = StateProvider<bool>((ref) => false);

/// Sentinel for [activeKnitStitchProvider]: KEEP a painted cell's existing stitch (change only its
/// colorwork color), the mirror of [knitColorKeep]. Any value >= 0 is a real legend stitch id.
const int knitStitchKeep = -1;

/// The active brush stitch: a builtin/cable legend id (>= 0) painted on tap, or [knitStitchKeep] to
/// leave a cell's stitch untouched and paint only its color. Default knit.
final activeKnitStitchProvider = StateProvider<int>((ref) => KnitStitch.knit);

/// Sentinel brush values for [activeKnitColorProvider] (any value >= 0 is a palette index).
const int knitColorKeep = -2; // keep a painted cell's existing color (add a stitch symbol only)
const int knitColorNone = -1; // clear the color (a symbol-only / uncolored cell)

/// The active colorwork brush: [knitColorKeep], [knitColorNone], or a palette index (>= 0). Defaults
/// to KEEP so painting a stitch symbol never wipes the colorwork already under it.
final activeKnitColorProvider = StateProvider<int>((ref) => knitColorKeep);

/// The chart interaction tool: PAINT taps single cells (and lets the chart scroll); SELECT drags out a
/// rectangular region to fill in one go (the chart scroll is frozen so the drag selects).
enum KnitTool { paint, select }

/// The current chart tool. Default paint, so a freshly-opened chart is immediately editable.
final knitToolProvider = StateProvider<KnitTool>((ref) => KnitTool.paint);

/// A rectangular chart selection (inclusive), stored as the drag's ANCHOR cell + its CURRENT cell;
/// [rowMin]/[rowMax]/[colMin]/[colMax] normalize it. Null when nothing is selected.
class KnitSelection {
  const KnitSelection(this.rowA, this.colA, this.rowB, this.colB);
  final int rowA;
  final int colA;
  final int rowB;
  final int colB;

  int get rowMin => rowA < rowB ? rowA : rowB;
  int get rowMax => rowA < rowB ? rowB : rowA;
  int get colMin => colA < colB ? colA : colB;
  int get colMax => colA < colB ? colB : colA;

  /// The same anchor with a new current corner (during a drag).
  KnitSelection toCurrent(int row, int col) => KnitSelection(rowA, colA, row, col);

  @override
  bool operator ==(Object other) =>
      other is KnitSelection &&
      other.rowA == rowA &&
      other.colA == colA &&
      other.rowB == rowB &&
      other.colB == colB;

  @override
  int get hashCode => Object.hash(rowA, colA, rowB, colB);
}

/// The current rectangular selection (SELECT tool), or null.
final knitSelectionProvider = StateProvider<KnitSelection?>((ref) => null);

/// The single source of truth for the open pattern + its undo history.
class KnitEditorNotifier extends Notifier<KnitEditorState> {
  @override
  KnitEditorState build() => const KnitEditorState(pattern: KnitEditorState.placeholder);

  /// Open [pattern] for editing, resetting the undo history. Also resets the active brush color so a
  /// stale palette index from a prior session can't paint a dangling colorwork reference.
  void load(KnitPatternDto pattern) {
    state = KnitEditorState(pattern: pattern);
    ref.read(activeKnitColorProvider.notifier).state = knitColorKeep;
  }

  void paintCell(int row, int col, int stitch, int? color,
          {bool keepColor = false, bool keepStitch = false}) =>
      state = state.paintCell(row, col, stitch, color, keepColor: keepColor, keepStitch: keepStitch);

  void fillRegion(int r0, int c0, int r1, int c1, int stitch, int? color,
          {bool keepColor = false, bool keepStitch = false}) =>
      state = state.fillRegion(r0, c0, r1, c1, stitch, color,
          keepColor: keepColor, keepStitch: keepStitch);

  void resizeChart(int width, int rows) => state = state.resizeChart(width, rows);

  void setGauge(GaugeDto gauge) => state = state.setGauge(gauge);

  void setConstruction(ConstructionKind c) => state = state.setConstruction(c);

  void setFirstRowSide(SideKind s) => state = state.setFirstRowSide(s);

  void setNotes(String notes) => state = state.setNotes(notes);

  void addPaletteColor(ColorDto color) => state = state.addPaletteColor(color);

  void setPaletteColor(int idx, ColorDto color) => state = state.setPaletteColor(idx, color);

  /// Append a custom cable to the legend and return its new brush id (legend length - 1), so the
  /// caller can make it the active brush.
  int addCable(CableDefDto cable, String symbol) {
    state = state.addCable(cable, symbol);
    return state.pattern.legend.stitches.length - 1;
  }

  void undo() => state = state.undoEdit();
  void redo() => state = state.redoEdit();
}

final knitEditorProvider =
    NotifierProvider<KnitEditorNotifier, KnitEditorState>(KnitEditorNotifier.new);

/// The live RGBA chart image for the pattern in [knitEditorProvider], re-rendered on every edit.
/// LATEST-WINS: a monotonic seq guard drops a stale frame so a slow earlier render never paints over
/// a newer one, and the superseded image is disposed (mirrors the weave `previewProvider`).
final knitPreviewProvider =
    AutoDisposeAsyncNotifierProvider<KnitPreviewController, ui.Image>(KnitPreviewController.new);

class KnitPreviewController extends AutoDisposeAsyncNotifier<ui.Image> {
  int _seq = 0;

  @override
  Future<ui.Image> build() async {
    final repo = ref.watch(knitRepositoryProvider);
    final pattern = ref.watch(knitEditorProvider.select((s) => s.pattern));
    final cellPx = ref.watch(knitZoomProvider);
    final mySeq = ++_seq;
    var disposed = false;
    ref.onDispose(() => disposed = true);

    final image = await repo.render(pattern, cellPx: cellPx);

    if (disposed || mySeq != _seq) {
      image.dispose();
      return Completer<ui.Image>().future; // superseded: never resolves
    }
    return image;
  }
}

/// The live validation of the pattern in [knitEditorProvider] (full stitch-count balancing); the
/// inline panel watches this. Same latest-wins shape as [knitPreviewProvider], minus the image
/// dispose (a list holds no native handle).
final knitValidationProvider =
    AutoDisposeAsyncNotifierProvider<KnitValidationController, List<KnitIssueDto>>(
        KnitValidationController.new);

class KnitValidationController extends AutoDisposeAsyncNotifier<List<KnitIssueDto>> {
  int _seq = 0;

  @override
  Future<List<KnitIssueDto>> build() async {
    final repo = ref.watch(knitRepositoryProvider);
    final pattern = ref.watch(knitEditorProvider.select((s) => s.pattern));
    final mySeq = ++_seq;
    var disposed = false;
    ref.onDispose(() => disposed = true);

    final issues = await repo.validate(pattern);

    if (disposed || mySeq != _seq) {
      return Completer<List<KnitIssueDto>>().future;
    }
    return issues;
  }
}

/// The live written-instructions rendering of the editor pattern (RS/WS aware, run-length collapsed,
/// cast-on edge first). The written-instructions screen watches this. Same latest-wins shape as
/// [knitValidationProvider].
final knitWrittenProvider =
    AutoDisposeAsyncNotifierProvider<KnitWrittenController, List<String>>(KnitWrittenController.new);

class KnitWrittenController extends AutoDisposeAsyncNotifier<List<String>> {
  int _seq = 0;

  @override
  Future<List<String>> build() async {
    final repo = ref.watch(knitRepositoryProvider);
    final pattern = ref.watch(knitEditorProvider.select((s) => s.pattern));
    final mySeq = ++_seq;
    var disposed = false;
    ref.onDispose(() => disposed = true);

    final lines = await repo.written(pattern);

    if (disposed || mySeq != _seq) {
      return Completer<List<String>>().future;
    }
    return lines;
  }
}
