import '../models/knit_stitches.dart';
import '../rust/dto.dart' show ColorDto, UnitKind; // shared with the weave bridge
import '../rust/knit_dto.dart';

/// Immutable editor state: the open knitting [pattern] plus a bounded undo/redo history. Every edit
/// returns a NEW state (the generated DTOs are final-field/immutable, so an edit reconstructs the
/// changed path). The notifier just swaps `state`; all the logic lives here so it is pure-testable.
class KnitEditorState {
  const KnitEditorState({required this.pattern, this.undo = const [], this.redo = const []});

  final KnitPatternDto pattern;
  final List<KnitPatternDto> undo;
  final List<KnitPatternDto> redo;

  static const int _maxUndo = 100;

  /// A synchronous placeholder so the editor never holds a null before the real pattern (with the
  /// builtin legend) async-loads from the engine. Its legend is EMPTY — it is shown behind a spinner
  /// and never edited; the screen replaces it via [KnitEditorNotifier.load].
  static const KnitPatternDto placeholder = KnitPatternDto(
    name: '',
    construction: ConstructionKind.flat,
    firstRowSide: SideKind.rs,
    gauge: GaugeDto(sts: 18, rows: 24, unit: UnitKind.inches),
    palette: [ColorDto(r: 255, g: 255, b: 255)],
    legend: StitchLegendDto(stitches: []),
    chart: ChartDto(width: 0, rows: []),
    notes: '',
  );

  bool get canUndo => undo.isNotEmpty;
  bool get canRedo => redo.isNotEmpty;

  KnitEditorState _commit(KnitPatternDto next) {
    if (identical(next, pattern)) return this; // a no-op edit returns the same instance
    final u = [...undo, pattern];
    final trimmed = u.length > _maxUndo ? u.sublist(u.length - _maxUndo) : u;
    return KnitEditorState(pattern: next, undo: trimmed, redo: const []);
  }

  /// Paint cell ([row], [col]) with the brush [stitch] (a legend id) and an optional colorwork
  /// [color] index. Out-of-range coordinates or a no-change paint are no-ops (no undo entry).
  ///
  /// Cable-aware: if [stitch] is a cable brush (a legend entry carrying a [CableDefDto]) this places
  /// the cable ANCHOR plus its `span - 1` trailing no-stitch fillers in one edit, clearing any cable
  /// it overlaps, and is a no-op if the span would run off the row's right edge. Painting a regular
  /// stitch onto a cell that belongs to a cable clears that whole cable first (so no orphan fillers
  /// are ever left, which validate would otherwise flag).
  KnitEditorState paintCell(int row, int col, int stitch, int? color) {
    final rows = pattern.chart.rows;
    if (row < 0 || row >= rows.length) return this;
    if (col < 0 || col >= rows[row].cells.length) return this;
    // Defense in depth: never persist a color index past the palette (a stale brush color) — drop it
    // to a symbol-only cell rather than write a dangling reference.
    final c = (color != null && color >= pattern.palette.length) ? null : color;
    final span = _legendCableSpan(pattern.legend, stitch);
    final next = span != null
        ? _placeCable(pattern, row, col, stitch, span, c)
        : _paintRegular(pattern, row, col, stitch, c);
    return _commit(next);
  }

  /// Resize the chart grid to [width] columns x [rows] rows: existing cells are kept, new cells are
  /// knit, extras are truncated.
  KnitEditorState resizeChart(int width, int rows) =>
      _commit(_resizeChart(pattern, width.clamp(0, 1 << 16), rows.clamp(0, 1 << 16)));

  /// Set the pattern's [gauge] (stitches/rows per 4 in or 10 cm). A no-change is a no-op (GaugeDto
  /// has value equality).
  KnitEditorState setGauge(GaugeDto gauge) {
    if (pattern.gauge == gauge) return this;
    return _commit(_withGauge(pattern, gauge));
  }

  /// Set the construction (flat vs in-the-round). Drives the written-instructions wording (Row vs
  /// Round) and the RS/WS alternation. A no-change is a no-op.
  KnitEditorState setConstruction(ConstructionKind construction) {
    if (pattern.construction == construction) return this;
    return _commit(_withMeta(pattern, construction: construction));
  }

  /// Set which side the first chart row is worked from (RS or WS). A no-change is a no-op.
  KnitEditorState setFirstRowSide(SideKind side) {
    if (pattern.firstRowSide == side) return this;
    return _commit(_withMeta(pattern, firstRowSide: side));
  }

  /// Replace the free-text pattern notes. A no-change is a no-op.
  KnitEditorState setNotes(String notes) {
    if (pattern.notes == notes) return this;
    return _commit(_withMeta(pattern, notes: notes));
  }

  /// Append a colorwork [color] to the palette (its index becomes a paintable cell color).
  KnitEditorState addPaletteColor(ColorDto color) =>
      _commit(_withPalette(pattern, [...pattern.palette, color]));

  /// Replace palette entry [idx]'s color. Out-of-range or no-change is a no-op.
  KnitEditorState setPaletteColor(int idx, ColorDto color) {
    final palette = pattern.palette;
    if (idx < 0 || idx >= palette.length || palette[idx] == color) return this;
    return _commit(_withPalette(pattern, [...palette]..[idx] = color));
  }

  /// Append a custom [cable] (with display [symbol]) to the legend as a new brush. The new brush's
  /// id is the resulting legend length minus one. A cable is count-neutral: consumes == produces ==
  /// its span (front + back).
  KnitEditorState addCable(CableDefDto cable, String symbol) {
    final span = cable.front + cable.back;
    final def = StitchDefDto(
      symbol: symbol,
      consumes: span,
      produces: span,
      cable: cable,
      macroRows: 1,
    );
    return _commit(_withLegend(pattern, [...pattern.legend.stitches, def]));
  }

  KnitEditorState undoEdit() {
    if (undo.isEmpty) return this;
    return KnitEditorState(
      pattern: undo.last,
      undo: undo.sublist(0, undo.length - 1),
      redo: [...redo, pattern],
    );
  }

  KnitEditorState redoEdit() {
    if (redo.isEmpty) return this;
    return KnitEditorState(
      pattern: redo.last,
      undo: [...undo, pattern],
      redo: redo.sublist(0, redo.length - 1),
    );
  }
}

// --- pure DTO reconstruction helpers ---------------------------------------------------------------

KnitPatternDto _withChart(KnitPatternDto p, ChartDto chart) => KnitPatternDto(
      name: p.name,
      construction: p.construction,
      firstRowSide: p.firstRowSide,
      gauge: p.gauge,
      palette: p.palette,
      legend: p.legend,
      chart: chart,
      notes: p.notes,
    );

KnitPatternDto _withMeta(
  KnitPatternDto p, {
  ConstructionKind? construction,
  SideKind? firstRowSide,
  String? notes,
}) =>
    KnitPatternDto(
      name: p.name,
      construction: construction ?? p.construction,
      firstRowSide: firstRowSide ?? p.firstRowSide,
      gauge: p.gauge,
      palette: p.palette,
      legend: p.legend,
      chart: p.chart,
      notes: notes ?? p.notes,
    );

KnitPatternDto _withGauge(KnitPatternDto p, GaugeDto gauge) => KnitPatternDto(
      name: p.name,
      construction: p.construction,
      firstRowSide: p.firstRowSide,
      gauge: gauge,
      palette: p.palette,
      legend: p.legend,
      chart: p.chart,
      notes: p.notes,
    );

KnitPatternDto _withPalette(KnitPatternDto p, List<ColorDto> palette) => KnitPatternDto(
      name: p.name,
      construction: p.construction,
      firstRowSide: p.firstRowSide,
      gauge: p.gauge,
      palette: palette,
      legend: p.legend,
      chart: p.chart,
      notes: p.notes,
    );

KnitPatternDto _withLegend(KnitPatternDto p, List<StitchDefDto> stitches) => KnitPatternDto(
      name: p.name,
      construction: p.construction,
      firstRowSide: p.firstRowSide,
      gauge: p.gauge,
      palette: p.palette,
      legend: StitchLegendDto(stitches: stitches),
      chart: p.chart,
      notes: p.notes,
    );

/// The span (front + back) of the cable at legend id [stitch], or null if [stitch] is out of range
/// or not a cable. The one place "is this brush a cable, and how wide?" is answered.
int? _legendCableSpan(StitchLegendDto legend, int stitch) {
  if (stitch < 0 || stitch >= legend.stitches.length) return null;
  final cable = legend.stitches[stitch].cable;
  return cable == null ? null : cable.front + cable.back;
}

/// The cable group (anchorCol, span) whose span covers [col], or null. Cables never overlap, so the
/// first anchor at or left of [col] whose span reaches [col] is the unique owner.
(int, int)? _cableGroupCovering(StitchLegendDto legend, List<CellDto> cells, int col) {
  for (var a = 0; a <= col && a < cells.length; a++) {
    final span = _legendCableSpan(legend, cells[a].stitch);
    if (span != null && a + span > col) return (a, span);
  }
  return null;
}

/// Paint a regular (non-cable) stitch at ([row], [col]). If the cell belongs to a cable group, the
/// WHOLE group is reset to knit first, then [col] takes the new stitch — never leaving orphan
/// fillers. A true no-op (no group, same cell) returns [p] unchanged.
KnitPatternDto _paintRegular(KnitPatternDto p, int row, int col, int stitch, int? color) {
  final rows = p.chart.rows;
  final r = rows[row];
  final group = _cableGroupCovering(p.legend, r.cells, col);
  final next = CellDto(stitch: stitch, color: color);
  if (group == null && r.cells[col] == next) return p; // nothing changes
  const knit = CellDto(stitch: KnitStitch.knit);
  final cells = [...r.cells];
  if (group != null) {
    for (var k = 0; k < group.$2 && group.$1 + k < cells.length; k++) {
      cells[group.$1 + k] = knit;
    }
  }
  cells[col] = next;
  final newRows = [...rows]..[row] = RowDto(cells: cells, repeats: r.repeats);
  return _withChart(p, ChartDto(width: p.chart.width, rows: newRows));
}

/// Place a cable anchored at ([row], [col]) with [span] columns: the anchor cell carries [stitchId]
/// (+ optional [color]), followed by `span - 1` no-stitch fillers. A no-op (returns [p]) if the span
/// runs past the row's right edge. Any cable group overlapping the target span is cleared first.
KnitPatternDto _placeCable(KnitPatternDto p, int row, int col, int stitchId, int span, int? color) {
  final width = p.chart.width;
  if (col + span > width) return p; // doesn't fit -> no-op
  final rows = p.chart.rows;
  final r = rows[row];
  final cells = _clearCablesOverlapping(p.legend, r.cells, col, col + span);
  cells[col] = CellDto(stitch: stitchId, color: color);
  for (var k = 1; k < span; k++) {
    cells[col + k] = const CellDto(stitch: KnitStitch.noStitch);
  }
  final newRows = [...rows]..[row] = RowDto(cells: cells, repeats: r.repeats);
  return _withChart(p, ChartDto(width: width, rows: newRows));
}

/// A fresh cell list with every cable group overlapping `[start, end)` reset to knit (so a new cable
/// can be laid without leaving fragments of an old one).
List<CellDto> _clearCablesOverlapping(
    StitchLegendDto legend, List<CellDto> cells, int start, int end) {
  const knit = CellDto(stitch: KnitStitch.knit);
  final out = [...cells];
  for (var a = 0; a < out.length; a++) {
    final span = _legendCableSpan(legend, out[a].stitch);
    if (span != null && a + span > start && a < end) {
      for (var k = 0; k < span && a + k < out.length; k++) {
        out[a + k] = knit;
      }
    }
  }
  return out;
}

KnitPatternDto _resizeChart(KnitPatternDto p, int width, int rowCount) {
  const knit = CellDto(stitch: KnitStitch.knit);
  final rows = List<RowDto>.generate(rowCount, (r) {
    final old = r < p.chart.rows.length ? p.chart.rows[r] : null;
    final cells = List<CellDto>.generate(
      width,
      (c) => (old != null && c < old.cells.length) ? old.cells[c] : knit,
    );
    // Drop any authored repeat span that no longer fits the (possibly shrunk) width, so a resize
    // can't leave a span referencing columns past the edge (which validate would flag).
    final repeats =
        (old?.repeats ?? const <RepeatSpanDto>[]).where((s) => s.end <= width).toList();
    return RowDto(cells: cells, repeats: repeats);
  });
  return _withChart(p, ChartDto(width: width, rows: rows));
}
