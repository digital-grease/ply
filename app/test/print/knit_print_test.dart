import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/knit_repository.dart';
import 'package:ply/src/models/draft_doc.dart' show MeasureUnit;
import 'package:ply/src/models/knit_stitches.dart';
import 'package:ply/src/print/knit_print.dart';
import 'package:ply/src/print/pdf_builder.dart';
import 'package:ply/src/print/print_document.dart';
import 'package:ply/src/print/print_layout.dart';
import 'package:ply/src/rust/api.dart' show PreviewImage;
import 'package:ply/src/rust/dto.dart' show ColorDto, SeverityKind, UnitKind;
import 'package:ply/src/rust/knit_dto.dart';

import 'print_test_support.dart';

// The printed KNITTING pattern's content: materials and gauge, a stitch key that lists every symbol
// the chart uses (with its abbreviation, meaning and wrong-side reading, and a flag when two symbols
// look alike), the chart model (numbers, sides, repeat boxes), the written instructions with the
// cast-on line, the Problems section, and the "has problems" box only for a pattern with errors.

/// The engine's builtin legend (`ply_knit::pattern::builtin`), in id order.
List<StitchDefDto> _builtins() {
  StitchDefDto d(String s, int c, int p, [int? ws]) =>
      StitchDefDto(symbol: s, consumes: c, produces: p, wsVariant: ws, macroRows: 1);
  return [
    d('ns', 0, 0),
    d('k', 1, 1, 2),
    d('p', 1, 1, 1),
    d('yo', 0, 1),
    d('k2tog', 2, 1, 6),
    d('ssk', 2, 1, 6),
    d('p2tog', 2, 1, 4),
    d('cdd', 3, 1),
    d('m1l', 0, 1),
    d('m1r', 0, 1),
    d('kfb', 1, 2),
    d('sl', 1, 1),
    d('k3tog', 3, 1),
    d('sk2po', 3, 1),
    d('ssp', 2, 1),
    d('kbf', 1, 2),
    d('pfb', 1, 2),
    d('m1p', 0, 1),
    d('m1lp', 0, 1),
    d('m1rp', 0, 1),
    d('ktbl', 1, 1),
  ];
}

const _cable = CableDefDto(
  front: 2,
  back: 2,
  direction: CrossKind.right,
  frontPurl: false,
  backPurl: false,
);
const int _cableId = 21;

CellDto _c(int stitch, [int? color]) => CellDto(stitch: stitch, color: color);
RowDto _row(List<CellDto> cells, [List<RepeatSpanDto> repeats = const []]) =>
    RowDto(cells: cells, repeats: repeats);

/// A 6-wide, 4-row flat pattern (row 1 RS): knit, purl, k2tog, yo, a 2/2 right cable, k3tog and ssp
/// (which the engine draws alike), a no-stitch cell, knit on a wrong-side row, and a x3 repeat.
KnitPatternDto _pattern({
  ConstructionKind construction = ConstructionKind.flat,
  SideKind first = SideKind.rs,
  int? castOn = 6,
  UnitKind unit = UnitKind.inches,
  List<ColorDto> palette = const [ColorDto(r: 255, g: 255, b: 255)],
  List<RowDto>? rows,
  String notes = 'Block gently.',
}) =>
    KnitPatternDto(
      name: 'x',
      construction: construction,
      firstRowSide: first,
      castOn: castOn,
      gauge: GaugeDto(sts: 18, rows: 24.5, unit: unit),
      palette: palette,
      legend: StitchLegendDto(stitches: [
        ..._builtins(),
        const StitchDefDto(symbol: '2/2 RC', consumes: 4, produces: 4, cable: _cable, macroRows: 1),
      ]),
      chart: ChartDto(
        width: 6,
        rows: rows ??
            [
              _row([
                _c(1),
                _c(1),
                _c(2),
                _c(2),
                _c(4),
                _c(3)
              ], const [
                RepeatSpanDto(start: 0, end: 2, count: RepeatDto.times(count: 3)),
              ]),
              _row([for (var i = 0; i < 6; i++) _c(1)]),
              _row([_c(_cableId), _c(0), _c(0), _c(0), _c(1), _c(12)]),
              _row([_c(14), _c(1), _c(1), _c(1), _c(1), _c(0)]),
            ],
      ),
      notes: notes,
      sections: const [],
      pieces: const [],
    );

/// Stands in for the engine: canned validation and written lines; rasters whose color depends on
/// the drawn stitch, with k3tog..m1rp (ids 12-19) all drawn alike, as the engine's placeholder.
class FakePrintRepo extends KnitRepository {
  FakePrintRepo({this.issues = const [], this.lines = const ['Cast on 6 sts.', 'Row 1 (RS): k6']});
  final List<KnitIssueDto> issues;
  final List<String> lines;
  final renders = <(int, int, int)>[]; // (cellPx, width, rows)

  @override
  Future<List<KnitIssueDto>> validate(KnitPatternDto pattern) async => issues;

  @override
  Future<List<String>> written(KnitPatternDto pattern) async => lines;

  @override
  Future<PreviewImage> renderPixels(KnitPatternDto pattern, {required int cellPx}) async {
    renders.add((cellPx, pattern.chart.width, pattern.chart.rows.length));
    final single =
        pattern.chart.rows.length == 1 ? pattern.chart.rows.first.cells.first.stitch : -1;
    final shade = single >= 12 && single <= 19 ? 7 : single + 30;
    final r = solidRaster(pattern.chart.width * cellPx, pattern.chart.rows.length * cellPx,
        r: shade, g: shade, b: shade);
    return PreviewImage(width: r.width, height: r.height, rgba: r.rgba);
  }
}

Future<KnitPrintSource> _source(KnitPatternDto p, {FakePrintRepo? repo}) =>
    gatherKnitPrint(repo ?? FakePrintRepo(),
        name: 'Harbor hat', pattern: p, now: DateTime(2026, 11, 12));

PrintSection _section(PrintDocument d, String heading) =>
    d.sections.firstWhere((s) => s.heading == heading);

T _only<T>(PrintSection s) => s.blocks.whereType<T>().single;

void main() {
  test('print cell pixels shrink only for very large charts, within bounds', () {
    expect(knitPrintCellPx(40, 60), kPrintCellPxMax);
    expect(knitPrintCellPx(100, 100), kPrintCellPxMax);
    expect(knitPrintCellPx(200, 200), kPrintCellPxMin);
    expect(knitPrintCellPx(5000, 5000), kPrintCellPxMin, reason: 'never below the minimum');
  });

  test('gather renders the chart and one key symbol per used stitch', () async {
    final repo = FakePrintRepo();
    final s = await _source(_pattern(), repo: repo);
    expect(s.chart!.width, 6 * kPrintCellPxMax);
    expect(s.chart!.height, 4 * kPrintCellPxMax);
    expect(s.glyphs.keys.toSet(), {1, 2, 4, 3, _cableId, 0, 12, 14});
    expect(s.glyphs[_cableId]!.width, 4 * kPrintCellPxMax,
        reason: 'a cable is drawn across its span');
    expect(repo.renders.first, (kPrintCellPxMax, 6, 4), reason: 'the whole chart first');
  });

  group('stitch key', () {
    test('lists every stitch the chart shows, in picker order, with symbol and text', () async {
      final doc = buildKnitPrintDocument(await _source(_pattern()), withProblemsBox: false);
      final legends = _section(doc, 'Stitch key').blocks.whereType<PrintLegend>().toList();
      final key = legends.first.entries;
      expect(key.map((e) => e.code), ['k', 'p', 'ns', 'k2tog', 'k3tog', 'ssp', 'yo', '2/2 RC']);
      for (final e in key) {
        expect(e.glyph, isNotNull, reason: '${e.code} shows its chart symbol');
        expect(e.name, isNotEmpty);
        expect(e.meaning, isNotEmpty);
        expect(e.meaning, isNot(contains('\u2014')), reason: 'plain print text');
      }
      expect(key.first.name, 'Knit');
      expect(key.first.meaning, startsWith('Knit stitch: smooth'));
      expect(legends.length, 1, reason: 'no color key for a one-color chart');
    });

    test('says how a stitch reads on wrong-side rows', () async {
      final key = _only<PrintLegend>(_section(
              buildKnitPrintDocument(await _source(_pattern()), withProblemsBox: false),
              'Stitch key'))
          .entries;
      final knit = key.firstWhere((e) => e.code == 'k');
      expect(knit.notes, contains('On wrong-side rows the written instructions say p (Purl).'));
      // ssp is on a WS row but has no WS form: no note. Purl is only on an RS row: no note.
      expect(key.firstWhere((e) => e.code == 'ssp').notes.where((n) => n.contains('wrong-side')),
          isEmpty);
      expect(key.firstWhere((e) => e.code == 'p').notes, isEmpty);
    });

    test('flags stitches whose symbols look alike, in the key and the print notes', () async {
      final doc = buildKnitPrintDocument(await _source(_pattern()), withProblemsBox: false);
      final key = _only<PrintLegend>(_section(doc, 'Stitch key')).entries;
      expect(
          key.firstWhere((e) => e.code == 'k3tog').notes,
          contains(
              'Looks the same on the chart as ssp. Use the written instructions to tell them apart.'));
      final notes = _section(doc, 'Problems').blocks.whereType<PrintNotice>().single;
      expect(notes.title, 'What this PDF cannot show exactly');
      expect(notes.lines, contains(startsWith('k3tog and ssp look the same on the chart.')));
    });

    test('a cable is described; its no-stitch fillers are not a key entry', () async {
      final p = _pattern(rows: [
        _row([_c(_cableId), _c(0), _c(0), _c(0), _c(1), _c(1)]),
      ]);
      final key = _only<PrintLegend>(_section(
              buildKnitPrintDocument(await _source(p), withProblemsBox: false), 'Stitch key'))
          .entries;
      expect(key.map((e) => e.code), ['k', '2/2 RC']);
      final cable = key.last;
      expect(cable.name, '2/2 right cross');
      expect(cable.meaning, contains('hold at the back, k2, then k2 from the cable needle'));
    });

    test('colorwork adds a color key with labels and hex, never color alone', () async {
      final p = _pattern(
        palette: const [ColorDto(r: 255, g: 255, b: 255), ColorDto(r: 0x1A, g: 0x2B, b: 0x3C)],
        rows: [
          _row([_c(1, 0), _c(1, 1), _c(1), _c(1), _c(1, 1), _c(1)]),
        ],
      );
      final doc = buildKnitPrintDocument(await _source(p), withProblemsBox: false);
      final colors = _section(doc, 'Stitch key').blocks.whereType<PrintLegend>().last.entries;
      expect(colors.map((e) => e.code), ['MC', 'CC']);
      expect(colors.last.name, 'Contrast color');
      expect(colors.last.meaning, 'Palette color 2, #1A2B3C.');
      expect(colors.last.swatch, const PrintColor(0x1A, 0x2B, 0x3C));
      final facts = _only<PrintFacts>(_section(doc, 'Materials and gauge')).facts;
      expect(facts.firstWhere((f) => f.label == 'Colors').value, '2 colors, see the color key');
    });

    test('a stitch missing from the legend is named as unknown and flagged', () async {
      final p = _pattern(rows: [
        _row([_c(1), _c(99), _c(1), _c(1), _c(1), _c(1)])
      ]);
      final doc = buildKnitPrintDocument(await _source(p), withProblemsBox: false);
      final key = _only<PrintLegend>(_section(doc, 'Stitch key')).entries;
      expect(key.last.code, '#99');
      expect(key.last.name, 'Unknown stitch');
      final notes = _section(doc, 'Problems').blocks.whereType<PrintNotice>().single;
      expect(notes.lines, contains(contains('stitch #99')));
    });
  });

  group('materials and gauge', () {
    test('gauge, cast-on, construction, first-row side', () async {
      final doc = buildKnitPrintDocument(await _source(_pattern()), withProblemsBox: false);
      final facts = {
        for (final f in _only<PrintFacts>(_section(doc, 'Materials and gauge')).facts)
          f.label: f.value
      };
      expect(facts['Gauge'], '18 sts and 24.5 rows = 4 in');
      expect(facts['Cast on'], '6 sts');
      expect(facts['Construction'], 'Flat: rows alternate right side (RS) and wrong side (WS)');
      expect(facts['First row'], 'Right side (RS)');
    });

    test('metric gauge, no cast-on, in the round', () async {
      final p = _pattern(
        unit: UnitKind.centimeters,
        castOn: null,
        construction: ConstructionKind.inTheRound,
      );
      final doc = buildKnitPrintDocument(await _source(p), withProblemsBox: false);
      final facts = {
        for (final f in _only<PrintFacts>(_section(doc, 'Materials and gauge')).facts)
          f.label: f.value
      };
      expect(facts['Gauge'], '18 sts and 24.5 rows = 10 cm');
      expect(facts['Cast on'], 'Not stated');
      expect(facts['Construction'], 'In the round: every round is worked from the right side');
    });

    test('notes are printed when the pattern has some', () async {
      final doc = buildKnitPrintDocument(await _source(_pattern()), withProblemsBox: false);
      expect(_only<PrintParagraph>(_section(doc, 'Notes')).text, 'Block gently.');
      final none =
          buildKnitPrintDocument(await _source(_pattern(notes: '  ')), withProblemsBox: false);
      expect(none.sections.any((s) => s.heading == 'Notes'), isFalse);
    });
  });

  group('chart', () {
    test('numbers stitches from the right and rows from the bottom; RS numbers right, WS left',
        () async {
      final doc = buildKnitPrintDocument(await _source(_pattern()), withProblemsBox: false);
      final chart = _only<PrintChart>(_section(doc, 'Chart'));
      expect(chart.columnNumbers, [6, 5, 4, 3, 2, 1]);
      expect(chart.rowNumbers, [1, 2, 3, 4]);
      expect(
          chart.rowNumberSides, [PrintSide.right, PrintSide.left, PrintSide.right, PrintSide.left]);
      expect(chart.startAtRight, isTrue);
      expect(chart.boxes.single.label, '×3');
      expect(chart.boxes.single.colStart, 0);
      expect(chart.boxes.single.colEnd, 2);
      expect(chart.rowsName, 'Rows');
    });

    test('a first wrong-side row flips the sides; in the round every number is on the right',
        () async {
      final ws = _only<PrintChart>(_section(
          buildKnitPrintDocument(await _source(_pattern(first: SideKind.ws)),
              withProblemsBox: false),
          'Chart'));
      expect(ws.rowNumberSides.first, PrintSide.left);
      final round = _only<PrintChart>(_section(
          buildKnitPrintDocument(await _source(_pattern(construction: ConstructionKind.inTheRound)),
              withProblemsBox: false),
          'Chart'));
      expect(round.rowNumberSides.toSet(), {PrintSide.right});
      expect(round.rowsName, 'Rounds');
    });

    test('says the cells are a picture from the chart engine', () async {
      final doc = buildKnitPrintDocument(await _source(_pattern()), withProblemsBox: false);
      expect(
        _section(doc, 'Chart').blocks.whereType<PrintParagraph>().map((p) => p.text),
        contains(contains("a picture drawn by Ply's chart engine")),
      );
    });

    test('an empty chart says so instead of printing nothing', () async {
      final p = _pattern(rows: const []);
      final doc = buildKnitPrintDocument(await _source(p), withProblemsBox: false);
      expect(_section(doc, 'Chart').blocks.single, isA<PrintParagraph>());
      expect((_section(doc, 'Chart').blocks.single as PrintParagraph).text,
          'This chart has no rows or stitches yet.');
    });
  });

  group('written instructions', () {
    test('cast-on line first, then labelled rows; a row needing fixes is flagged', () async {
      final repo = FakePrintRepo(lines: const [
        'Cast on 26 sts.',
        'Row 1 (RS): k, *k2, p2; rep from * to last st, k',
        'Row 2 (WS): p, [k2, p2] 3 times, p',
        'Row 3 (RS): (repeats need fixing: the repeats over cols 2-4 and cols 4-6 overlap)',
      ]);
      final doc =
          buildKnitPrintDocument(await _source(_pattern(), repo: repo), withProblemsBox: false);
      final lines = _only<PrintLines>(_section(doc, 'Written instructions')).lines;
      expect(lines.first.label, isNull);
      expect(lines.first.text, 'Cast on 26 sts.');
      expect(lines[1].label, 'Row 1 (RS)');
      expect(lines[1].text, 'k, *k2, p2; rep from * to last st, k', reason: 'the folded form kept');
      expect(lines[2].text, 'p, [k2, p2] 3 times, p');
      expect(lines.take(3).any((l) => l.flagged), isFalse);
      expect(lines[3].flagged, isTrue);
    });

    test('round labels parse too', () {
      final l = knitWrittenLine('Round 4: k2, p2');
      expect(l.label, 'Round 4');
      expect(l.text, 'k2, p2');
    });
  });

  group('problems', () {
    const issues = [
      KnitIssueDto(severity: SeverityKind.warning, message: 'row 3 is wider than the cast-on'),
      KnitIssueDto(
          severity: SeverityKind.error, message: 'row 2 consumes 6 stitches but row 1 produced 7'),
      KnitIssueDto(
          severity: SeverityKind.error,
          message: 'the cast-on is 0 stitches; cast on at least 1 stitch'),
    ];

    test('lists errors then warnings, with their rows', () async {
      final doc = buildKnitPrintDocument(
          await _source(_pattern(), repo: FakePrintRepo(issues: issues)),
          withProblemsBox: false);
      final list = _only<PrintIssues>(_section(doc, 'Problems')).issues;
      expect(list.map((i) => (i.severity, i.where, i.message)), [
        (PrintIssueSeverity.error, 'Row 2', 'Row 2 consumes 6 stitches but row 1 produced 7'),
        (
          PrintIssueSeverity.error,
          'Whole pattern',
          'The cast-on is 0 stitches; cast on at least 1 stitch'
        ),
        (PrintIssueSeverity.warning, 'Row 3', 'Row 3 is wider than the cast-on'),
      ]);
    });

    test('a clean pattern says it has no problems', () async {
      final doc = buildKnitPrintDocument(await _source(_pattern()), withProblemsBox: true);
      expect(_only<PrintIssues>(_section(doc, 'Problems')).issues, isEmpty);
      expect(_only<PrintIssues>(_section(doc, 'Problems')).emptyText,
          'Ply found no problems in this pattern.');
    });

    test('the "has problems" box appears only for errors the user chose to print anyway', () async {
      final faulty = await _source(_pattern(), repo: FakePrintRepo(issues: issues));
      final box = buildKnitPrintDocument(faulty, withProblemsBox: true).problemsBox!;
      expect(box.title, 'This pattern has problems');
      expect(box.level, PrintNoticeLevel.problem);
      expect(
          box.lines,
          [
            'Row 2 consumes 6 stitches but row 1 produced 7',
            'The cast-on is 0 stitches; cast on at least 1 stitch',
          ],
          reason: 'errors only; warnings never block');
      expect(buildKnitPrintDocument(faulty, withProblemsBox: false).problemsBox, isNull);

      final warningsOnly = await _source(_pattern(),
          repo: FakePrintRepo(issues: const [
            KnitIssueDto(severity: SeverityKind.warning, message: 'row 3 is wide'),
          ]));
      expect(knitPrintErrors(warningsOnly), isEmpty);
      expect(buildKnitPrintDocument(warningsOnly, withProblemsBox: true).problemsBox, isNull);
    });
  });

  test('the whole pattern prints: every section, the key, and no em dashes', () async {
    final source = await _source(_pattern(),
        repo: FakePrintRepo(issues: const [
          KnitIssueDto(
              severity: SeverityKind.error,
              message: 'row 2 consumes 6 stitches but row 1 produced 7'),
        ]));
    Future<PdfReadBack> read(bool box) async => PdfReadBack(await buildPrintPdf(
          buildKnitPrintDocument(source, withProblemsBox: box),
          page: PrintPageSetup.forUnit(MeasureUnit.inches),
          fonts: testFonts(),
          compress: false,
        ));
    final pdf = await read(true);
    for (final s in [
      'Harbor hat',
      'Knitting pattern',
      'Printed: 2026-11-12',
      'This pattern has problems',
      'Materials and gauge',
      'Stitch key',
      '2/2 RC',
      'Chart',
      'Rows 1 to 4, stitches 1 to 6',
      'Written instructions',
      'Cast on 6 sts.',
      'Row 1 (RS): k6',
      'Problems',
      'Row 2 consumes 6 stitches but row 1 produced 7',
      'Page 1 of ${pdf.pageCount}',
    ]) {
      expect(pdf.text, contains(s));
    }
    expect(pdf.text, isNot(contains('\u2014')));
    expect(pdf.mediaBoxes.first[2], closeTo(612, 0.01), reason: 'imperial: US Letter');
    expect((await read(false)).text, isNot(contains('This pattern has problems')));
  });

  test('every builtin brush description prints without a dash', () {
    for (final b in kKnitBrushes) {
      expect(plainText(b.description), isNot(contains('\u2014')), reason: b.symbol);
    }
  });
}
