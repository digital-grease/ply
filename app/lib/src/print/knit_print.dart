// The printable KNITTING pattern (M9-02): what the PDF says, built from the open pattern and the
// engine's own render, written-instructions and validation output. [gatherKnitPrint] makes the
// engine calls once; [buildKnitPrintDocument] is pure, so every printed word is host-testable.

import 'dart:collection';
import 'dart:math' as math;

import 'package:collection/collection.dart' show ListEquality;
import 'package:flutter/widgets.dart' show BuildContext;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/knit_repository.dart';
import '../models/knit_sections.dart';
import '../models/knit_stitches.dart';
import '../rust/dto.dart' show ColorDto, SeverityKind, UnitKind;
import '../rust/knit_dto.dart';
import '../state/knit_editor_providers.dart';
import '../widgets/knit_chart_view.dart' show repeatBoxes, repeatLabel;
import 'print_document.dart';
import 'print_export.dart';

/// Everything a printed knitting pattern is made from, gathered from the engine once.
class KnitPrintSource {
  const KnitPrintSource({
    required this.name,
    required this.pattern,
    required this.issues,
    required this.written,
    required this.chart,
    required this.glyphs,
    required this.printedAt,
    this.construction,
  });

  /// The pattern's display name.
  final String name;
  final KnitPatternDto pattern;

  /// The engine's validation of [pattern].
  final List<KnitIssueDto> issues;

  /// The engine's written instructions (cast-on line first when stated).
  final List<String> written;

  /// The chart as the engine draws it, or null when it has no cells (or could not be drawn).
  final PrintRaster? chart;

  /// Each stitch the chart shows, drawn by the engine exactly as on the chart (one cell, or a
  /// cable's span), for the stitch key.
  final Map<int, PrintRaster> glyphs;
  final DateTime printedAt;

  /// The engine's worked construction (sections and their stitch ledger), when the pattern has
  /// sections; null for a chart-only pattern. Places each section problem in the Problems table.
  final KnitConstructionDto? construction;
}

/// The biggest and smallest raster pixels per chart cell, and the pixel budget between them: a
/// typical chart prints at 24 px per 5 mm cell (about 120 dpi); a very large one drops toward 12 so
/// the raster stays small enough for a phone.
const int kPrintCellPxMax = 24;
const int kPrintCellPxMin = 12;
const int _printPixelBudget = 6000000;

/// Raster pixels per cell for printing a [columns] x [rows] chart.
int knitPrintCellPx(int columns, int rows) {
  if (columns <= 0 || rows <= 0) return kPrintCellPxMax;
  final fit = math.sqrt(_printPixelBudget / (columns * rows)).floor();
  return fit.clamp(kPrintCellPxMin, kPrintCellPxMax);
}

/// Whether chart row [r] is worked from the wrong side (the engine's `row_side`).
bool knitRowIsWs(KnitPatternDto p, int r) =>
    p.construction == ConstructionKind.flat && (r.isEven != (p.firstRowSide == SideKind.rs));

/// The legend entry for stitch [id], or null when the chart names a stitch the legend lacks.
StitchDefDto? _def(KnitPatternDto p, int id) =>
    id >= 0 && id < p.legend.stitches.length ? p.legend.stitches[id] : null;

int _span(StitchDefDto? def) {
  final c = def?.cable;
  return c == null ? 1 : math.max(1, c.front + c.back);
}

/// The stitches a chart's cells show, in first-seen order, walking each row the way the renderer
/// draws it (a cable once across its span, the no-stitch filler cells it covers skipped; a row
/// shorter than the chart reads as knit), plus the ones that fall on a wrong-side row.
({List<int> ids, Set<int> onWs}) knitUsedStitches(KnitPatternDto p) {
  final ids = <int>[];
  final seen = <int>{};
  final onWs = <int>{};
  for (var r = 0; r < p.chart.rows.length; r++) {
    final row = p.chart.rows[r];
    final ws = knitRowIsWs(p, r);
    var col = 0;
    while (col < p.chart.width) {
      final stitch = col < row.cells.length ? row.cells[col].stitch : KnitStitch.knit;
      if (seen.add(stitch)) ids.add(stitch);
      if (ws) onWs.add(stitch);
      col += math.max(1, math.min(_span(_def(p, stitch)), p.chart.width - col));
    }
  }
  return (ids: ids, onWs: onWs);
}

/// The colorwork labels the written instructions use, by palette index (the engine's
/// `color_labels`): MC for color 0, CC for a lone contrast, CC1, CC2... for several. Null when the
/// chart uses one color.
Map<int, String>? knitColorLabels(KnitPatternDto p) {
  final used = SplayTreeSet<int>();
  for (final row in p.chart.rows) {
    for (final cell in row.cells) {
      if (cell.stitch != KnitStitch.noStitch) used.add(cell.color ?? 0);
    }
  }
  if (used.length < 2) return null;
  final multi = used.where((i) => i != 0).length > 1;
  var n = 0;
  return {
    for (final i in used) i: i == 0 ? 'MC' : (multi ? 'CC${++n}' : 'CC'),
  };
}

/// Read the pattern's validation, written instructions, chart raster and key symbols from [repo].
Future<KnitPrintSource> gatherKnitPrint(
  KnitRepository repo, {
  required String name,
  required KnitPatternDto pattern,
  DateTime? now,
}) async {
  final issues = await repo.validate(pattern);
  final written = await repo.written(pattern);
  final construction = pattern.sections.isEmpty ? null : await repo.construction(pattern);
  final cols = pattern.chart.width, rows = pattern.chart.rows.length;
  PrintRaster? chart;
  if (cols > 0 && rows > 0) {
    final px = await repo.renderPixels(pattern, cellPx: knitPrintCellPx(cols, rows));
    if (px.width > 0 && px.height > 0) {
      chart = PrintRaster(width: px.width, height: px.height, rgba: px.rgba);
    }
  }
  final glyphs = <int, PrintRaster>{};
  for (final id in knitUsedStitches(pattern).ids) {
    final span = _span(_def(pattern, id));
    final one = KnitPatternDto(
      name: '',
      construction: ConstructionKind.flat,
      firstRowSide: SideKind.rs,
      gauge: pattern.gauge,
      palette: pattern.palette,
      legend: pattern.legend,
      chart: ChartDto(width: span, rows: [
        RowDto(cells: [
          CellDto(stitch: id),
          for (var i = 1; i < span; i++) const CellDto(stitch: KnitStitch.noStitch),
        ], repeats: const []),
      ]),
      notes: '',
      sections: const [],
    );
    final px = await repo.renderPixels(one, cellPx: kPrintCellPxMax);
    if (px.width > 0 && px.height > 0) {
      glyphs[id] = PrintRaster(width: px.width, height: px.height, rgba: px.rgba);
    }
  }
  return KnitPrintSource(
    name: name,
    pattern: pattern,
    issues: issues,
    written: written,
    chart: chart,
    glyphs: glyphs,
    printedAt: now ?? DateTime.now(),
    construction: construction,
  );
}

/// A validation message as a sentence ("Row 3 consumes 6 stitches but row 2 produced 14").
String knitIssueText(KnitIssueDto i) => _sentence(i.message);

/// The errors that make the export ask before printing (warnings never block).
List<String> knitPrintErrors(KnitPrintSource s) => [
      for (final i in s.issues)
        if (i.severity == SeverityKind.error) knitIssueText(i),
    ];

/// The document for [s]. [withProblemsBox] is the user's "print anyway" choice: when the pattern
/// has errors, a box at the top lists them. Without errors there is never a box.
PrintDocument buildKnitPrintDocument(KnitPrintSource s, {required bool withProblemsBox}) {
  final p = s.pattern;
  final flat = p.construction == ConstructionKind.flat;
  final cols = p.chart.width, rows = p.chart.rows.length;
  final labels = knitColorLabels(p);
  final used = knitUsedStitches(p);
  final errors = knitPrintErrors(s);
  final printNotes = <String>[];

  // --- stitch key ---
  final shared = _sharedGlyphs(used.ids, s.glyphs);
  final sharedGroups = {
    for (final group in shared)
      for (final id in group) id: group
  };
  final codes = {for (final id in used.ids) id: _code(p, id)};
  final stitchEntries = <PrintLegendEntry>[
    for (final id in _keyOrder(used.ids))
      _stitchEntry(
        p,
        id,
        glyph: s.glyphs[id],
        onWs: used.onWs.contains(id),
        sameAs: [
          for (final other in sharedGroups[id] ?? const <int>[])
            if (other != id) codes[other]!,
        ],
      ),
  ];
  for (final group in shared) {
    printNotes.add('${_and([for (final id in group) codes[id]!])} look the same on the chart. The '
        'stitch key and the written instructions tell them apart.');
  }
  for (final id in used.ids) {
    if (_def(p, id) == null) {
      printNotes
          .add('The chart uses stitch #$id, which is not in the pattern\'s stitch list, so this '
              'PDF cannot say what it is.');
    }
  }
  final colorEntries = labels == null
      ? const <PrintLegendEntry>[]
      : [
          for (final MapEntry(key: i, value: label) in labels.entries)
            PrintLegendEntry(
              code: label,
              name: label == 'MC'
                  ? 'Main color'
                  : (label == 'CC' ? 'Contrast color' : 'Contrast color ${label.substring(2)}'),
              meaning: i < p.palette.length
                  ? 'Palette color ${i + 1}, ${_color(p.palette[i]).hex}.'
                  : 'Color ${i + 1}, which is not in the pattern\'s palette.',
              swatch: i < p.palette.length ? _color(p.palette[i]) : null,
            ),
        ];
  if (labels != null) {
    printNotes.add('Colors are printed only as square fills on the chart. The written instructions '
        'name each color, so use them when printing in black and white.');
  }

  // --- chart ---
  final chartBlocks = <PrintBlock>[];
  if (cols == 0 || rows == 0) {
    chartBlocks.add(const PrintParagraph('This chart has no rows or stitches yet.'));
  } else if (s.chart == null) {
    chartBlocks.add(const PrintNotice(
      level: PrintNoticeLevel.caution,
      title: 'The chart could not be drawn',
      intro: 'Use the written instructions, which describe every row.',
    ));
    printNotes.add('The chart could not be drawn for printing.');
  } else {
    final boxes = repeatBoxes(p.chart);
    chartBlocks
      ..add(PrintParagraph(flat
          ? 'Read the chart from the bottom up, starting at row 1. Right-side rows are numbered on '
              'the right and read from right to left; wrong-side rows are numbered on the left and '
              'read from left to right. Stitch 1 is at the right edge.'
          : 'Read the chart from the bottom up, starting at round 1, and read every round from '
              'right to left. Stitch 1 is at the right edge.'))
      ..addAll([
        if (boxes.isNotEmpty)
          const PrintParagraph('A box marks a repeat. The chart draws its stitches once; the label '
              'says how many times to work them (for example ×3), or "to end" to repeat them to the '
              'end of the row.'),
        if (labels != null)
          const PrintParagraph(
              'Colors are shown as square fills. If you print in black and white, '
              'follow the written instructions, which name each color (MC, CC).',
              style: PrintTextStyle.muted),
        const PrintParagraph(
            'The chart squares are a picture drawn by Ply\'s chart engine at print '
            'resolution; the numbers and repeat boxes are printed as text and lines.',
            style: PrintTextStyle.muted),
      ])
      ..add(PrintChart(
        raster: s.chart!,
        columns: cols,
        rows: rows,
        columnNumbers: [for (var i = 0; i < cols; i++) cols - i],
        rowNumbers: [for (var r = 0; r < rows; r++) r + 1],
        rowNumberSides: [
          for (var r = 0; r < rows; r++) knitRowIsWs(p, r) ? PrintSide.left : PrintSide.right,
        ],
        boxes: [
          for (final b in boxes)
            PrintChartBox(
              colStart: b.colStart,
              colEnd: b.colEnd,
              rowLo: b.rowLo,
              rowHi: b.rowHi,
              label: repeatLabel(b.count),
            ),
        ],
        startAtRight: true,
        rowsName: flat ? 'Rows' : 'Rounds',
        columnsName: 'stitches',
      ));
  }

  // --- problems ---
  final places = _sectionPlaces(s);
  final issueRows = [
    for (final i in s.issues.where((i) => i.severity == SeverityKind.error)) _issue(i, places),
    for (final i in s.issues.where((i) => i.severity != SeverityKind.error)) _issue(i, places),
  ];
  final hasSections = p.sections.isNotEmpty;
  final mentionsColumns = s.issues.any((i) => RegExp(r'\bcols? \d').hasMatch(i.message));

  return PrintDocument(
    title: s.name,
    kind: 'Knitting pattern',
    titleFacts: [
      PrintFact('Printed', isoDate(s.printedAt)),
      PrintFact('Chart',
          '${_n(cols, 'stitch', 'stitches')} wide, ${_n(rows, flat ? 'row' : 'round', flat ? 'rows' : 'rounds')}'),
    ],
    problemsBox: withProblemsBox && errors.isNotEmpty
        ? PrintNotice(
            level: PrintNoticeLevel.problem,
            title: 'This pattern has problems',
            intro: 'Ply found ${_n(errors.length, 'error', 'errors')} in this pattern. Check '
                '${errors.length == 1 ? 'it' : 'them'} before you knit from it; Problems at the end '
                'lists every finding.',
            lines: errors,
          )
        : null,
    sections: [
      if (p.notes.trim().isNotEmpty) PrintSection('Notes', [PrintParagraph(p.notes.trim())]),
      PrintSection('Materials and gauge', [
        PrintFacts([
          PrintFact('Gauge', knitGaugeText(p.gauge)),
          PrintFact('Cast on', p.castOn == null ? 'Not stated' : _n(p.castOn!, 'st', 'sts')),
          PrintFact(
            'Construction',
            flat
                ? 'Flat: rows alternate right side (RS) and wrong side (WS)'
                : 'In the round: every round is worked from the right side',
          ),
          PrintFact(
            'First row',
            !flat
                ? 'Right side (every round)'
                : (p.firstRowSide == SideKind.rs ? 'Right side (RS)' : 'Wrong side (WS)'),
          ),
          if (hasSections)
            PrintFact(
              'Sections',
              [for (var i = 0; i < p.sections.length; i++) knitSectionTitle(p, i)].join(', '),
            ),
          PrintFact('Colors',
              labels == null ? 'One color' : '${labels.length} colors, see the color key'),
        ]),
      ]),
      PrintSection('Stitch key', [
        PrintParagraph(stitchEntries.isEmpty
            ? 'The chart has no stitches yet.'
            : 'Every symbol this chart uses, with the abbreviation the written instructions use '
                'for it.'),
        if (stitchEntries.isNotEmpty) PrintLegend(stitchEntries),
        if (colorEntries.isNotEmpty) ...[
          const PrintParagraph('Colors', style: PrintTextStyle.strong),
          PrintLegend(colorEntries),
        ],
      ]),
      PrintSection('Chart', chartBlocks),
      PrintSection('Written instructions', [
        if (s.written.isEmpty)
          const PrintParagraph('There are no written instructions yet: the chart has no rows.')
        else if (hasSections) ...[
          PrintParagraph(
            'Worked section by section, in order. RS is the right side, WS the wrong side, and a '
            'rnd is a round. The count in brackets after each step is what is on the needle once '
            'the step is done, with any stitches on hold and bound off. "Waiting past a turn" '
            'counts the stitches a short row has left unworked. When the stitches are in needle '
            'groups, the count gives each group (such as the instep and the sole); "worked flat" '
            'and "resting" count the stitches of a part worked back and forth, such as a heel '
            'flap, and those waiting on the needle meanwhile. A step marked "Not checked by Ply" '
            'is in the pattern\'s own words and Ply did not check it.'
            '${labels == null ? '' : ' MC is the main color and CC a contrast color (see the color key).'}',
            style: PrintTextStyle.muted,
          ),
          ..._sectionBlocks(s.written),
        ] else ...[
          PrintParagraph(
            '${flat ? 'Worked from the cast-on edge up. RS is the right side, WS the wrong side.' : 'Worked from the cast-on edge up; every round is a right-side round.'}'
            '${labels == null ? '' : ' MC is the main color and CC a contrast color (see the color key).'}',
            style: PrintTextStyle.muted,
          ),
          PrintLines([for (final l in s.written) knitWrittenLine(l)]),
        ],
      ]),
      PrintSection('Problems', [
        if (mentionsColumns)
          PrintParagraph(
            flat
                ? 'Column numbers in these messages count in working order: from the right on '
                    'right-side rows and from the left on wrong-side rows.'
                : 'Column numbers in these messages count from the right, the way each round is '
                    'worked.',
            style: PrintTextStyle.muted,
          ),
        PrintIssues(issueRows, emptyText: 'Ply found no problems in this pattern.'),
        if (printNotes.isNotEmpty)
          PrintNotice(
            level: PrintNoticeLevel.caution,
            title: 'What this PDF cannot show exactly',
            lines: printNotes,
          ),
      ]),
    ],
  );
}

/// "18 sts and 24 rows = 4 in" (or 10 cm), the publishing convention.
String knitGaugeText(GaugeDto g) =>
    '${_num(g.sts)} sts and ${_num(g.rows)} rows = ${g.unit == UnitKind.centimeters ? '10 cm' : '4 in'}';

final _labelledLine = RegExp(
    r'^(Row \d+ \((?:RS|WS)\)|Round \d+|Short row \d+(?: \((?:RS|WS)\))?|Next row(?: \((?:RS|WS)\))?'
    r'|Next rnd|Next \d+ rows(?: \(first row (?:RS|WS)\))?|Next \d+ rnds|Not checked by Ply): (.*)$',
    dotAll: true);

/// The count a section step's line ends with when the step could not be counted.
const String _notCounted = '(not counted: see the problems)';

/// One written-instructions line split into its bold label ("Row 1 (RS)", "Short row 2 (WS)",
/// "Not checked by Ply") and the rest; a row the engine could not write as authored ("(repeats need
/// fixing: ...)") or a section step it could not count is flagged.
PrintLine knitWrittenLine(String line) {
  final flagged = line.endsWith(_notCounted);
  final m = _labelledLine.firstMatch(line);
  if (m == null) return PrintLine(line, flagged: flagged);
  final body = m.group(2)!;
  return PrintLine(body,
      label: m.group(1), flagged: flagged || body.startsWith('(repeats need fixing'));
}

/// The written instructions of a pattern with sections as print blocks: the cast-on line, then each
/// section's heading, its notes and its steps.
List<PrintBlock> _sectionBlocks(List<String> written) {
  final blocks = <PrintBlock>[];
  var lines = <PrintLine>[];
  void flush() {
    if (lines.isNotEmpty) blocks.add(PrintLines(lines));
    lines = <PrintLine>[];
  }

  for (final l in written) {
    if (isKnitSectionHeading(l)) {
      flush();
      blocks.add(PrintParagraph(l, style: PrintTextStyle.strong));
    } else if (l.startsWith('Notes: ')) {
      flush();
      blocks.add(PrintParagraph(l.substring('Notes: '.length), style: PrintTextStyle.muted));
    } else {
      lines.add(knitWrittenLine(l));
    }
  }
  flush();
  return blocks;
}

/// For each section problem (by its full message), where it is ("Back, step 3", "Back, step 2,
/// chart row 5", "Back", "Whole pattern") and its text without the place.
Map<String, (String, String)> _sectionPlaces(KnitPrintSource s) {
  final c = s.construction;
  if (c == null) return const {};
  final p = s.pattern;
  final out = <String, (String, String)>{};
  for (final i in c.issues) {
    // By position: ids can repeat in a hand-edited file, positions cannot.
    final si = i.sectionIndex ?? -1;
    if (si < 0 || si >= p.sections.length) {
      out[i.message] = ('Whole pattern', i.message);
      continue;
    }
    var where = knitSectionTitle(p, si);
    final ti = i.stepIndex ?? -1;
    if (ti >= 0) where += ', step ${ti + 1}';
    if (i.chartRow != null) where += ', chart row ${i.chartRow}';
    out[i.message] = (where, i.text);
  }
  return out;
}

/// The local date as YYYY-MM-DD.
String isoDate(DateTime d) {
  String two(int v) => v.toString().padLeft(2, '0');
  final l = d.toLocal();
  return '${l.year}-${two(l.month)}-${two(l.day)}';
}

/// Run the print-or-share flow for the knit editor's open pattern, shown as [name].
Future<void> printOrShareKnitPdf(BuildContext context, WidgetRef ref, {required String name}) {
  // Read everything from providers now: the flow has async gaps, and the screen may be gone after.
  final repo = ref.read(knitRepositoryProvider);
  final pattern = ref.read(knitEditorProvider).pattern;
  return printOrSharePdf(
    context,
    ref,
    noun: 'pattern',
    prepare: () async {
      final source = await gatherKnitPrint(repo, name: name, pattern: pattern);
      return PdfExportJob(
        fileStem: name,
        errors: knitPrintErrors(source),
        document: ({required withProblemsBox}) =>
            buildKnitPrintDocument(source, withProblemsBox: withProblemsBox),
      );
    },
  );
}

// --- helpers ---------------------------------------------------------------------------------------

PrintIssue _issue(KnitIssueDto i, Map<String, (String, String)> places) {
  final row = RegExp(r'^row (\d+)\b').firstMatch(i.message);
  final place = places[i.message];
  return PrintIssue(
    severity: switch (i.severity) {
      SeverityKind.error => PrintIssueSeverity.error,
      SeverityKind.warning => PrintIssueSeverity.warning,
      SeverityKind.info => PrintIssueSeverity.note,
    },
    where: place?.$1 ?? (row == null ? 'Whole pattern' : 'Row ${row.group(1)}'),
    message: place == null ? knitIssueText(i) : _sentence(place.$2),
  );
}

/// The key order: the builtins in the brush picker's order (basic, decreases, increases), then
/// cables and custom stitches in legend order, then any stitch the legend lacks.
List<int> _keyOrder(List<int> ids) {
  int rank(int id) {
    final i = kKnitBrushes.indexWhere((b) => b.id == id);
    return i >= 0 ? i : 1000 + id;
  }

  return [...ids]..sort((a, b) => rank(a).compareTo(rank(b)));
}

/// The abbreviation for stitch [id]: what the written instructions print for it.
String _code(KnitPatternDto p, int id) => _def(p, id)?.symbol ?? '#$id';

/// The builtin brush describing [id], when the legend entry really is that builtin.
KnitBrush? _brush(KnitPatternDto p, int id) {
  final def = _def(p, id);
  if (def == null || def.cable != null) return null;
  for (final b in kKnitBrushes) {
    if (b.id == id && b.symbol == def.symbol) return b;
  }
  return null;
}

PrintLegendEntry _stitchEntry(
  KnitPatternDto p,
  int id, {
  required PrintRaster? glyph,
  required bool onWs,
  required List<String> sameAs,
}) {
  final def = _def(p, id);
  final notes = <String>[
    if (sameAs.isNotEmpty)
      'Looks the same on the chart as ${_and(sameAs)}. Use the written instructions to tell them '
          'apart.',
  ];
  if (def == null) {
    return PrintLegendEntry(
      code: '#$id',
      name: 'Unknown stitch',
      meaning: 'This chart uses a stitch that is not in the pattern\'s stitch list, so Ply cannot '
          'say what it is, and the written instructions leave it out.',
      glyph: glyph,
      notes: notes,
    );
  }
  final ws = def.wsVariant;
  if (onWs && ws != null && ws != id && _def(p, ws) != null) {
    final wsBrush = _brush(p, ws);
    notes.insert(
        0,
        'On wrong-side rows the written instructions say ${_def(p, ws)!.symbol}'
        '${wsBrush == null ? '' : ' (${wsBrush.label})'}.');
  }
  if (id == KnitStitch.noStitch && _brush(p, id) != null) {
    notes.insert(0, 'Grey on the chart. Skip these squares: nothing is worked there.');
  }
  final cable = def.cable;
  if (cable != null) {
    return PrintLegendEntry(
      code: def.symbol,
      name:
          '${cable.front}/${cable.back} ${cable.direction == CrossKind.right ? 'right' : 'left'} cross',
      meaning: _cableMeaning(cable),
      glyph: glyph,
      notes: notes,
    );
  }
  final brush = _brush(p, id);
  if (brush != null) {
    return PrintLegendEntry(
      code: def.symbol,
      name: brush.label,
      meaning: plainText(brush.description),
      glyph: glyph,
      notes: notes,
    );
  }
  return PrintLegendEntry(
    code: def.symbol,
    name: 'Custom stitch',
    meaning: 'Works ${_n(def.consumes, 'stitch', 'stitches')} into ${def.produces}.',
    glyph: glyph,
    notes: notes,
  );
}

/// How a cable is worked, in the conventional reading of "front/back RC|LC": a right cross holds the
/// back group behind and works the front group first; a left cross holds the front group in front
/// and works the back group first.
String _cableMeaning(CableDefDto c) {
  String work(int n, bool purl) => '${purl ? 'p' : 'k'}$n';
  final total = c.front + c.back;
  final lead = 'A cable over $total stitches: ${c.front} cross in front, leaning '
      '${c.direction == CrossKind.right ? 'right' : 'left'}.';
  return c.direction == CrossKind.right
      ? '$lead Slip ${_n(c.back, 'stitch', 'stitches')} to a cable needle and hold at the back, '
          '${work(c.front, c.frontPurl)}, then ${work(c.back, c.backPurl)} from the cable needle.'
      : '$lead Slip ${_n(c.front, 'stitch', 'stitches')} to a cable needle and hold at the front, '
          '${work(c.back, c.backPurl)}, then ${work(c.front, c.frontPurl)} from the cable needle.';
}

/// Groups (two or more, in key order) of stitch ids whose key symbols are pixel-identical: they
/// cannot be told apart on the chart, so the key and the print notes say so.
List<List<int>> _sharedGlyphs(List<int> ids, Map<int, PrintRaster> glyphs) {
  const eq = ListEquality<int>();
  final groups = <List<int>>[];
  for (final id in _keyOrder(ids)) {
    final g = glyphs[id];
    if (g == null) continue;
    List<int>? match;
    for (final group in groups) {
      final other = glyphs[group.first]!;
      if (other.width == g.width && other.height == g.height && eq.equals(other.rgba, g.rgba)) {
        match = group;
        break;
      }
    }
    match == null ? groups.add([id]) : match.add(id);
  }
  return [
    for (final group in groups)
      if (group.length > 1) group
  ];
}

PrintColor _color(ColorDto c) => PrintColor(c.r, c.g, c.b);

/// A builtin description as plain print text (the in-app key uses a spaced dash, which the printed
/// pattern does not: "Knit stitch: smooth ...").
String plainText(String s) => s.replaceAll(' \u2014 ', ': ').replaceAll('\u2014', ', ');

String _sentence(String s) => s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

String _n(int n, String one, String many) => '$n ${n == 1 ? one : many}';

String _num(double v) {
  if (v == v.roundToDouble()) return v.toInt().toString();
  return v.toStringAsFixed(2).replaceFirst(RegExp(r'0+$'), '');
}

String _and(List<String> items) => items.length <= 1
    ? items.join()
    : '${items.sublist(0, items.length - 1).join(', ')} and ${items.last}';
