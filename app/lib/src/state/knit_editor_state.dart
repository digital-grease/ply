import '../models/knit_stitches.dart';
import '../rust/dto.dart' show ColorDto, UnitKind; // shared with the weave bridge
import '../rust/knit_dto.dart';

/// Immutable editor state: the open knitting [pattern] plus a bounded undo/redo history and the
/// [saved] baseline the dirty check compares against. Every edit returns a NEW state (the generated
/// DTOs are final-field/immutable, so an edit reconstructs the changed path). The notifier just swaps
/// `state`; all the logic lives here so it is pure-testable.
class KnitEditorState {
  const KnitEditorState({
    required this.pattern,
    this.undo = const [],
    this.redo = const [],
    this.saved,
  });

  final KnitPatternDto pattern;
  final List<KnitPatternDto> undo;
  final List<KnitPatternDto> redo;

  /// The pattern exactly as last loaded or saved (the "nothing to lose" baseline), or null before
  /// the editor has loaded anything. Carried unchanged through every edit, undo, and redo.
  final KnitPatternDto? saved;

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

  /// Whether [pattern] has unsaved edits. IDENTITY, not deep equality: every real edit builds a NEW
  /// pattern instance (a no-op edit returns the same one), and undo/redo restore the exact instances
  /// they stacked, so undoing back to the saved pattern reads clean again. An edit reverted by hand
  /// (paint a cell, paint it back) is a new instance and reads dirty, which is the safe direction.
  bool get isDirty => saved != null && !identical(pattern, saved);

  /// Record [persisted] as the saved baseline (the save path passes the EXACT instance it wrote, so
  /// an edit made while the write was in flight still reads dirty). History is untouched.
  KnitEditorState markSaved(KnitPatternDto persisted) => identical(persisted, saved)
      ? this
      : KnitEditorState(pattern: pattern, undo: undo, redo: redo, saved: persisted);

  KnitEditorState _commit(KnitPatternDto next) {
    if (identical(next, pattern)) return this; // a no-op edit returns the same instance
    final u = [...undo, pattern];
    final trimmed = u.length > _maxUndo ? u.sublist(u.length - _maxUndo) : u;
    return KnitEditorState(pattern: next, undo: trimmed, redo: const [], saved: saved);
  }

  /// Paint cell ([row], [col]) with the brush [stitch] (a legend id) and an optional colorwork
  /// [color] index. Out-of-range coordinates or a no-change paint are no-ops (no undo entry).
  ///
  /// Cable-aware: if [stitch] is a cable brush (a legend entry carrying a [CableDefDto]) this places
  /// the cable ANCHOR plus its `span - 1` trailing no-stitch fillers in one edit, clearing any cable
  /// it overlaps, and is a no-op if the span would run off the row's right edge. Painting a regular
  /// stitch onto a cell that belongs to a cable clears that whole cable first (so no orphan fillers
  /// are ever left, which validate would otherwise flag).
  KnitEditorState paintCell(int row, int col, int stitch, int? color,
      {bool keepColor = false, bool keepStitch = false}) {
    final rows = pattern.chart.rows;
    if (row < 0 || row >= rows.length) return this;
    if (col < 0 || col >= rows[row].cells.length) return this;
    final existing = rows[row].cells[col];
    // keepColor preserves the cell's CURRENT color (so a stitch symbol can be added without wiping the
    // colorwork under it); otherwise the brush [color] is applied.
    final wanted = keepColor ? existing.color : color;
    // Defense in depth: never persist a color index past the palette (a stale brush color) — drop it
    // to a symbol-only cell rather than write a dangling reference.
    final c = (wanted != null && wanted >= pattern.palette.length) ? null : wanted;
    // keepStitch leaves the cell's stitch (and any cable it belongs to) untouched, painting only the
    // color — the mirror of keepColor, so a color can be added under an existing symbol.
    if (keepStitch) {
      if (existing.color == c) return this; // nothing changes
      final cells = [...rows[row].cells]..[col] = CellDto(stitch: existing.stitch, color: c);
      final newRows = [...rows]..[row] = RowDto(cells: cells, repeats: rows[row].repeats);
      return _commit(_withChart(pattern, ChartDto(width: pattern.chart.width, rows: newRows)));
    }
    final span = _legendCableSpan(pattern.legend, stitch);
    final next = span != null
        ? _placeCable(pattern, row, col, stitch, span, c)
        : _paintRegular(pattern, row, col, stitch, c);
    return _commit(next);
  }

  /// Fill the rectangular region rows [r0]..[r1] × cols [c0]..[c1] (corners in any order) with the
  /// regular [stitch] + optional colorwork [color], committed as ONE undo entry. Cable brushes span
  /// columns and aren't fillable, so a cable [stitch] is a no-op; any cable overlapping a filled column
  /// is cleared first so no orphan fillers remain. Coordinates are clamped to the chart.
  KnitEditorState fillRegion(int r0, int c0, int r1, int c1, int stitch, int? color,
      {bool keepColor = false, bool keepStitch = false}) {
    // A cable brush spans columns and isn't a regular fill — unless keepStitch (we touch only colors).
    if (!keepStitch && _legendCableSpan(pattern.legend, stitch) != null) return this;
    final rows = pattern.chart.rows;
    final width = pattern.chart.width;
    if (rows.isEmpty || width == 0) return this;
    final rLo = (r0 < r1 ? r0 : r1).clamp(0, rows.length - 1);
    final rHi = (r0 < r1 ? r1 : r0).clamp(0, rows.length - 1);
    final cLo = (c0 < c1 ? c0 : c1).clamp(0, width - 1);
    final cHi = (c0 < c1 ? c1 : c0).clamp(0, width - 1);
    // Defense in depth: drop a colorwork index past the palette rather than write a dangling ref.
    int? clamp(int? i) => (i != null && i >= pattern.palette.length) ? null : i;
    final setColor = clamp(color);
    // keepColor leaves each cell's OWN color in place; keepStitch leaves each cell's stitch (and its
    // cables) in place and only sets the color. Otherwise the brush stitch + color fill every cell.
    final newRows = [...rows];
    for (var row = rLo; row <= rHi; row++) {
      final r = newRows[row];
      // Don't disturb cables when only colors are changing.
      final cells = keepStitch
          ? [...r.cells]
          : _clearCablesOverlapping(pattern.legend, r.cells, cLo, cHi + 1);
      for (var c = cLo; c <= cHi && c < cells.length; c++) {
        cells[c] = CellDto(
          stitch: keepStitch ? cells[c].stitch : stitch,
          color: keepColor ? clamp(cells[c].color) : setColor,
        );
      }
      newRows[row] = RowDto(cells: cells, repeats: r.repeats);
    }
    return _commit(_withChart(pattern, ChartDto(width: width, rows: newRows)));
  }

  /// Resize the chart grid to [width] columns x [rows] rows: existing cells are kept, new cells are
  /// knit, extras are truncated. Authored repeats are CLIPPED with the cells they cover, never
  /// dropped silently: a repeat that still starts inside the new width is shortened to the new edge,
  /// one that starts past it is removed, and removed rows take their repeats with them. Call
  /// [repeatCutsOnResize] first to tell the user what a resize will do to them (Undo restores it).
  KnitEditorState resizeChart(int width, int rows) =>
      _commit(_resizeChart(pattern, width.clamp(0, 1 << 16), rows.clamp(0, 1 << 16)));

  /// Mark storage columns [c0]..[c1] (inclusive, either order) of rows [r0]..[r1] as an authored
  /// repeat worked [count] times (or to the end of the row), as ONE undo entry. The cells are the
  /// motif as drawn; nothing is duplicated. Any repeat in those rows that overlaps the new one is
  /// replaced, so the editor never creates overlapping repeats; the row's repeats stay sorted by
  /// column. Coordinates are clamped to the chart. A `times` count below 1 (never worked) or a
  /// no-change mark is a no-op. Whether the repeat is workable (a cable cut by its edge, a second
  /// to-end repeat) is the engine validator's call, shown in the validation band like any problem.
  KnitEditorState markRepeat(int r0, int c0, int r1, int c1, RepeatDto count) {
    if (count case RepeatDto_Times(count: final n) when n < 1) return this;
    final region = _clampRegion(pattern, r0, c0, r1, c1);
    if (region == null) return this;
    final (rLo, rHi, cLo, cHi) = region;
    final span = RepeatSpanDto(start: cLo, end: cHi + 1, count: count);
    var changed = false;
    final rows = [...pattern.chart.rows];
    for (var r = rLo; r <= rHi; r++) {
      final old = rows[r].repeats;
      final kept = old.where((s) => !_overlaps(s, span.start, span.end)).toList();
      final next = [...kept, span]..sort((a, b) => a.start.compareTo(b.start));
      if (_sameRepeats(old, next)) continue;
      rows[r] = RowDto(cells: rows[r].cells, repeats: next);
      changed = true;
    }
    if (!changed) return this;
    return _commit(_withChart(pattern, ChartDto(width: pattern.chart.width, rows: rows)));
  }

  /// Remove every repeat in rows [r0]..[r1] that overlaps storage columns [c0]..[c1] (inclusive,
  /// either order), as ONE undo entry. The cells are untouched. A region with no repeat is a no-op.
  KnitEditorState clearRepeats(int r0, int c0, int r1, int c1) {
    final region = _clampRegion(pattern, r0, c0, r1, c1);
    if (region == null) return this;
    final (rLo, rHi, cLo, cHi) = region;
    var changed = false;
    final rows = [...pattern.chart.rows];
    for (var r = rLo; r <= rHi; r++) {
      final old = rows[r].repeats;
      final kept = old.where((s) => !_overlaps(s, cLo, cHi + 1)).toList();
      if (kept.length == old.length) continue;
      rows[r] = RowDto(cells: rows[r].cells, repeats: kept);
      changed = true;
    }
    if (!changed) return this;
    return _commit(_withChart(pattern, ChartDto(width: pattern.chart.width, rows: rows)));
  }

  /// Whether any repeat in rows [r0]..[r1] overlaps storage columns [c0]..[c1] (inclusive, either
  /// order): what "Remove repeat" would clear.
  bool hasRepeatIn(int r0, int c0, int r1, int c1) {
    final region = _clampRegion(pattern, r0, c0, r1, c1);
    if (region == null) return false;
    final (rLo, rHi, cLo, cHi) = region;
    for (var r = rLo; r <= rHi; r++) {
      if (pattern.chart.rows[r].repeats.any((s) => _overlaps(s, cLo, cHi + 1))) return true;
    }
    return false;
  }

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

  /// The largest cast-on the editor accepts (the engine counts in u64; this keeps the u32 wire field
  /// and the typed number sane).
  static const int maxCastOn = 100000;

  /// Set how many stitches are cast on before row 1 ([castOn] >= 1), or clear it (null = the pattern
  /// does not state one). A count below 1 or above [maxCastOn] is refused (no-op), as is a no-change.
  /// Row 1 is then checked against it and the written instructions start with it (engine side).
  KnitEditorState setCastOn(int? castOn) {
    if (castOn != null && (castOn < 1 || castOn > maxCastOn)) return this;
    if (pattern.castOn == castOn) return this;
    return _commit(_withCastOn(pattern, castOn));
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
      saved: saved,
    );
  }

  KnitEditorState redoEdit() {
    if (redo.isEmpty) return this;
    return KnitEditorState(
      pattern: redo.last,
      undo: [...undo, pattern],
      redo: redo.sublist(0, redo.length - 1),
      saved: saved,
    );
  }
}

// --- pure DTO reconstruction helpers ---------------------------------------------------------------

KnitPatternDto _withChart(KnitPatternDto p, ChartDto chart) => KnitPatternDto(
      name: p.name,
      construction: p.construction,
      firstRowSide: p.firstRowSide,
      castOn: p.castOn,
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
      castOn: p.castOn,
      gauge: p.gauge,
      palette: p.palette,
      legend: p.legend,
      chart: p.chart,
      notes: notes ?? p.notes,
    );

KnitPatternDto _withCastOn(KnitPatternDto p, int? castOn) => KnitPatternDto(
      name: p.name,
      construction: p.construction,
      firstRowSide: p.firstRowSide,
      castOn: castOn,
      gauge: p.gauge,
      palette: p.palette,
      legend: p.legend,
      chart: p.chart,
      notes: p.notes,
    );

KnitPatternDto _withGauge(KnitPatternDto p, GaugeDto gauge) => KnitPatternDto(
      name: p.name,
      construction: p.construction,
      firstRowSide: p.firstRowSide,
      castOn: p.castOn,
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
      castOn: p.castOn,
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
      castOn: p.castOn,
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
    // Repeats follow the cells they cover: one cut by the new edge is clipped to it, one wholly past
    // it goes with its cells. The editor reports both ([repeatCutsOnResize]); Undo restores them.
    final repeats = [
      for (final s in old?.repeats ?? const <RepeatSpanDto>[])
        if (s.end <= width)
          s
        else if (s.start < width)
          RepeatSpanDto(start: s.start, end: width, count: s.count),
    ];
    return RowDto(cells: cells, repeats: repeats);
  });
  return _withChart(p, ChartDto(width: width, rows: rows));
}

/// What a resize to [width] x [rowCount] does to [p]'s authored repeats: how many are [clipped] to
/// the new edge and how many are [removed] (wholly past the new width, or on a removed row).
class RepeatCuts {
  const RepeatCuts({this.clipped = 0, this.removed = 0});
  final int clipped;
  final int removed;
  bool get isEmpty => clipped == 0 && removed == 0;
}

/// The repeats a resize to [width] columns x [rowCount] rows would clip or remove (the same rule as
/// [KnitEditorState.resizeChart]).
RepeatCuts repeatCutsOnResize(KnitPatternDto p, int width, int rowCount) {
  width = width.clamp(0, 1 << 16);
  rowCount = rowCount.clamp(0, 1 << 16);
  var clipped = 0;
  var removed = 0;
  for (var r = 0; r < p.chart.rows.length; r++) {
    for (final s in p.chart.rows[r].repeats) {
      if (r >= rowCount) {
        removed++;
      } else if (s.end > width) {
        if (s.start < width) {
          clipped++;
        } else {
          removed++;
        }
      }
    }
  }
  return RepeatCuts(clipped: clipped, removed: removed);
}

/// The notice for a resize that changed repeats, or null when it changed none.
String? repeatCutsMessage(RepeatCuts cuts) {
  final c = cuts.clipped;
  final r = cuts.removed;
  if (c > 0 && r > 0) {
    return '$c ${c == 1 ? 'repeat was' : 'repeats were'} shortened and $r removed to fit the '
        'chart. Undo to restore.';
  }
  if (c > 0) {
    return '$c ${c == 1 ? 'repeat was' : 'repeats were'} shortened to fit the chart. '
        'Undo to restore.';
  }
  if (r > 0) {
    return '$r ${r == 1 ? 'repeat was' : 'repeats were'} removed with the stitches '
        '${r == 1 ? 'it' : 'they'} covered. Undo to restore.';
  }
  return null;
}

/// The region rows [r0]..[r1] x cols [c0]..[c1] (any corner order) clamped to [p]'s chart, as
/// (rowLo, rowHi, colLo, colHi), or null on an empty chart.
(int, int, int, int)? _clampRegion(KnitPatternDto p, int r0, int c0, int r1, int c1) {
  final rows = p.chart.rows.length;
  final width = p.chart.width;
  if (rows == 0 || width == 0) return null;
  final rLo = (r0 < r1 ? r0 : r1).clamp(0, rows - 1);
  final rHi = (r0 < r1 ? r1 : r0).clamp(0, rows - 1);
  final cLo = (c0 < c1 ? c0 : c1).clamp(0, width - 1);
  final cHi = (c0 < c1 ? c1 : c0).clamp(0, width - 1);
  return (rLo, rHi, cLo, cHi);
}

/// Whether span [s] shares a column with storage columns `[start, end)`.
bool _overlaps(RepeatSpanDto s, int start, int end) => s.start < end && start < s.end;

bool _sameRepeats(List<RepeatSpanDto> a, List<RepeatSpanDto> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
