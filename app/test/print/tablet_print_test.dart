import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart' show PdfPageFormat;
import 'package:ply/src/data/tablet_repository.dart';
import 'package:ply/src/models/app_settings.dart';
import 'package:ply/src/models/draft_doc.dart' show MeasureUnit;
import 'package:ply/src/models/readiness.dart';
import 'package:ply/src/models/tablet_band.dart';
import 'package:ply/src/print/pdf_builder.dart';
import 'package:ply/src/print/pdf_fonts.dart';
import 'package:ply/src/print/print_document.dart';
import 'package:ply/src/print/print_export.dart';
import 'package:ply/src/print/print_layout.dart';
import 'package:ply/src/print/tablet_print.dart';
import 'package:ply/src/rust/tablet_dto.dart';
import 'package:ply/src/state/tablet_editor_providers.dart';
import 'package:ply/src/state/theme_providers.dart';

import 'print_test_support.dart';

// The printed TABLET WEAVING band (ADR 0018 sections 8 and 15): the setup page (threading chart with
// A at the bottom, colour key, start positions and the card diagram, the S and Z legend, packs), the
// turning chart, the band chart (top face and back, card 1 at the right on the back), the working
// instructions as the engine writes them, the checks, the review caution, the band's readiness, a
// band with structural errors (setup only, charts and instructions said to be missing), a band too
// long to chart whole, a real PDF build, offline, and the shared print flow. Host only: the engine
// is a fake repository with canned reports, instructions and rasters.

// --- the oracle bands, read from the shared fixtures ------------------------------------------------

/// A `.plytab` fixture as the DTO the editor holds (only the fields these bands use).
TabletDocumentDto _fixture(String name) {
  final file = File('../fixtures/tablet/documents/$name.plytab');
  final d = (jsonDecode(file.readAsStringSync()) as Map<String, dynamic>)['document']
      as Map<String, dynamic>;
  TabletHoleKind hole(Object? s) => TabletHoleKind.values.byName((s as String).toLowerCase());
  TabletColorDto color(Object? hex) {
    final v = int.parse((hex as String).substring(1), radix: 16);
    return TabletColorDto(r: v >> 16 & 255, g: v >> 8 & 255, b: v & 255);
  }

  List<String> ids(Object? l) => [for (final x in (l as List<dynamic>? ?? const [])) x as String];
  return TabletDocumentDto(
    name: d['name'] as String,
    notes: d['notes'] as String,
    palette: [for (final c in d['palette'] as List<dynamic>) color(c)],
    weft: d['weft'] as int?,
    cards: [
      for (final c in (d['cards'] as List<dynamic>).cast<Map<String, dynamic>>())
        TabletCardDto(
          id: c['id'] as String,
          a: (c['threads'] as Map<String, dynamic>)['A'] as int?,
          b: (c['threads'] as Map<String, dynamic>)['B'] as int?,
          c: (c['threads'] as Map<String, dynamic>)['C'] as int?,
          d: (c['threads'] as Map<String, dynamic>)['D'] as int?,
          threading: c['threading'] == 'S' ? TabletThreadingKind.s : TabletThreadingKind.z,
          start: TabletArrangementDto(
            nearTop: hole((c['start'] as Map<String, dynamic>)['near_top']),
            farTop: hole((c['start'] as Map<String, dynamic>)['far_top']),
            farBottom: hole((c['start'] as Map<String, dynamic>)['far_bottom']),
            nearBottom: hole((c['start'] as Map<String, dynamic>)['near_bottom']),
          ),
        ),
    ],
    packs: [
      for (final p in (d['packs'] as List<dynamic>? ?? const []).cast<Map<String, dynamic>>())
        TabletPackDto(id: p['id'] as String, name: p['name'] as String, cards: ids(p['cards'])),
    ],
    turning: [
      for (final s in (d['turning'] as List<dynamic>).cast<Map<String, dynamic>>())
        TabletSegmentDto(repeat: s['repeat'] as int, picks: [
          for (final p in (s['picks'] as List<dynamic>).cast<Map<String, dynamic>>())
            TabletPickDto(
              turns: p['turns'] as String,
              releaseTwist: ids(p['release_twist']),
              flip: ids(p['flip']),
              unsupported: const [],
            ),
        ]),
    ],
    settings: kDefaultTabletSettings,
  );
}

final TabletDocumentDto _band1 = _fixture('band-1-threaded-in');
final TabletDocumentDto _sampler2 = _fixture('sampler-2-starts-idles-flip');

// --- engine stand-ins --------------------------------------------------------------------------------

TabletLocationDto _loc(
  TabletLocationKind kind, {
  int? card,
  TabletHoleKind? hole,
  List<int> cards = const [],
  int? cardsTotal,
  int? pack,
  List<int> packs = const [],
  int? segment,
  int? step,
  int? pick,
  TabletFaceKind? face,
  int? firstPick,
  int? lastPick,
}) =>
    TabletLocationDto(
      kind: kind,
      card: card,
      hole: hole,
      cards: Uint32List.fromList(cards),
      cardsTotal: cardsTotal ?? cards.length,
      pack: pack,
      packs: Uint32List.fromList(packs),
      packsTotal: packs.length,
      listings: 0,
      segment: segment,
      step: step,
      pick: pick,
      face: face,
      firstPick: firstPick,
      lastPick: lastPick,
      omittedCount: 0,
    );

TabletDiagnosticDto _diag(
        TabletSeverityKind severity, String code, String message, TabletLocationDto location,
        {String? remediation}) =>
    TabletDiagnosticDto(
        code: code,
        severity: severity,
        location: location,
        message: message,
        remediation: remediation);

TabletReportDto _report(List<TabletDiagnosticDto> diagnostics,
    {int? picks = 12, bool review = true}) {
  int count(TabletSeverityKind k) => diagnostics.where((d) => d.severity == k).length;
  return TabletReportDto(
    diagnostics: diagnostics,
    expandedPicks: picks,
    errors: count(TabletSeverityKind.error),
    warnings: count(TabletSeverityKind.warning),
    unsupported: count(TabletSeverityKind.unsupported),
    infos: count(TabletSeverityKind.info),
    reviewPending: review,
    rulesVersion: 1,
  );
}

/// Oracle band 1's check: two reversals (information only), as ADR 0018 section 11 expects.
final _band1Report = _report([
  _diag(TabletSeverityKind.info, 'tablet.reversal', 'Reversal at pick 5, cards 1 to 8.',
      _loc(TabletLocationKind.pick, pick: 5, cards: [1, 2, 3, 4, 5, 6, 7, 8])),
  _diag(TabletSeverityKind.info, 'tablet.reversal', 'Reversal at pick 9, cards 1 to 4.',
      _loc(TabletLocationKind.pick, pick: 9, cards: [1, 2, 3, 4])),
]);

TabletInstructionLineDto _line(
        TabletInstructionKind kind, String label, String text, int segment, int first, int last) =>
    TabletInstructionLineDto(
        kind: kind, label: label, text: text, segment: segment, firstPick: first, lastPick: last);

/// Oracle band 1's working instructions, in the engine's words.
final _band1Lines = [
  _line(
      TabletInstructionKind.pick, 'Picks 1 to 4', 'Cards 1 to 8 forward. Worked 4 times.', 1, 1, 4),
  _line(TabletInstructionKind.ledger, 'After pick 4', 'Twist: cards 1 to 4 +4; cards 5 to 8 -4.', 1,
      4, 4),
  _line(TabletInstructionKind.pick, 'Picks 5 to 8', 'Cards 1 to 8 backward. Worked 4 times.', 2, 5,
      8),
  _line(TabletInstructionKind.ledger, 'After pick 8',
      'Twist: cards 1 to 8 0. Every card is back at its starting position.', 2, 8, 8),
  _line(TabletInstructionKind.pick, 'Picks 9 to 12',
      'Left (cards 1 to 4) forward; Right (cards 5 to 8) backward. Worked 4 times.', 3, 9, 12),
  _line(TabletInstructionKind.ledger, 'After pick 12', 'Twist: cards 1 to 8 +4.', 3, 12, 12),
];

/// Stands in for the engine: a canned report and instructions; solid rasters of the size the
/// engine would draw (a shade per drawing, so tests can tell them apart); a band with errors is
/// refused as the engine refuses it.
class FakeTabletRepo extends TabletRepository {
  FakeTabletRepo(this.report, {List<TabletInstructionLineDto>? lines, this.omitted = 0})
      : lines = lines ?? _band1Lines;

  final TabletReportDto report;
  final List<TabletInstructionLineDto> lines;
  final int omitted;
  final calls = <String>[];

  static const int topShade = 60, backShade = 120, turningShade = 200;

  void _refuseErrors() {
    if (report.errors > 0) {
      throw const TabletRunFailure(
          kind: TabletRunFailureKind.hasErrors, message: 'the band has structural errors');
    }
  }

  TabletRasterDto _raster(TabletDocumentDto doc, int first, int last, int cellPx, int shade) {
    final r = solidRaster(doc.cards.length * cellPx, (last - first + 1) * cellPx,
        r: shade, g: shade, b: shade);
    return TabletRasterDto(
      width: r.width,
      height: r.height,
      cellPx: cellPx,
      firstPick: first,
      lastPick: last,
      cards: doc.cards.length,
      rgba: r.rgba,
      reviewPending: true,
    );
  }

  @override
  Future<TabletReportDto> validate(TabletDocumentDto doc) async {
    calls.add('validate');
    return report;
  }

  @override
  Future<TabletInstructionsDto> instructions(TabletDocumentDto doc, {int maxLines = 2000}) async {
    calls.add('instructions $maxLines');
    _refuseErrors();
    return TabletInstructionsDto(lines: lines, omitted: omitted, reviewPending: true);
  }

  @override
  Future<TabletRasterDto> renderFace(
    TabletDocumentDto doc,
    int first,
    int last, {
    required TabletFaceKind face,
    required int cellPx,
    bool letters = false,
    TabletCheckpointDto? checkpoint,
  }) async {
    calls.add('${face.name} ${doc.cards.length} $first-$last @$cellPx${letters ? ' letters' : ''}');
    _refuseErrors();
    return _raster(doc, first, last, cellPx, face == TabletFaceKind.top ? topShade : backShade);
  }

  @override
  Future<TabletRasterDto> renderTurning(TabletDocumentDto doc, int first, int last,
      {required int cellPx, TabletCheckpointDto? checkpoint}) async {
    calls.add('turning ${doc.cards.length} $first-$last @$cellPx');
    _refuseErrors();
    return _raster(doc, first, last, cellPx, turningShade);
  }
}

Future<TabletPrintSource> _source(TabletDocumentDto doc,
        {FakeTabletRepo? repo, TabletReportDto? report, String name = 'Oracle band 1'}) =>
    gatherTabletPrint(repo ?? FakeTabletRepo(report ?? _band1Report),
        name: name, doc: doc, now: DateTime(2026, 11, 17));

PrintSection _section(PrintDocument d, String heading) =>
    d.sections.firstWhere((s) => s.heading == heading);

List<T> _all<T>(PrintSection s) => s.blocks.whereType<T>().toList();

/// The texts of a drawing grouped into rows (by their top edge), each row left to right.
List<List<String>> _rows(PrintDrawing d) {
  final texts = d.shapes.whereType<PrintVectorText>().toList()..sort((a, b) => a.y.compareTo(b.y));
  final rows = <List<PrintVectorText>>[];
  for (final t in texts) {
    if (rows.isNotEmpty && (t.y - rows.last.first.y).abs() < 4) {
      rows.last.add(t);
    } else {
      rows.add([t]);
    }
  }
  return [
    for (final r in rows) [for (final t in r..sort((a, b) => a.x.compareTo(b.x))) t.text],
  ];
}

/// Every word a document prints.
String _text(PrintDocument d) => d.allText.join('\n');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the print budget', () {
    test('a typical band is charted whole at the largest pitch', () {
      expect(tabletPrintWindow(8, 12), (picks: 12, cellPx: kTabletPrintCellPxMax));
      expect(tabletPrintWindow(24, 100), (picks: 100, cellPx: kTabletPrintCellPxMax));
    });

    test('a long band is charted from pick 1 within the cell budget and the raster side', () {
      for (final (cards, total) in const [(8, 5000), (40, 5000), (1, 200000), (1000, 200000)]) {
        final w = tabletPrintWindow(cards, total);
        expect(w.picks, greaterThan(0));
        expect(w.picks, lessThan(total));
        expect(cards * w.picks, lessThanOrEqualTo(kTabletPrintMaxCells));
        expect(w.cellPx, inInclusiveRange(kTabletPrintCellPxMin, kTabletPrintCellPxMax));
        expect(w.picks * w.cellPx, lessThanOrEqualTo(16384), reason: 'the engine\'s side limit');
        expect(cards * w.cellPx, lessThanOrEqualTo(16384));
      }
      expect(tabletPrintWindow(8, 5000), (picks: 1365, cellPx: 12));
      expect(tabletPrintWindow(1000, 200000), (picks: 20, cellPx: 12));
    });

    test('nothing to chart', () {
      expect(tabletPrintWindow(0, 12).picks, 0);
      expect(tabletPrintWindow(8, 0).picks, 0);
    });
  });

  test('the fixture reads as ADR 0018 section 11 sets it up', () {
    String holes(TabletCardDto c) => [c.a, c.b, c.c, c.d].map((i) => 'KWRG'[i!]).join();
    expect(_band1.cards.map(holes).toList(),
        ['KKKK', 'WKKR', 'RWKK', 'KRWG', 'KRWG', 'RWKK', 'WKKR', 'KKKK']);
    expect(_band1.cards.map((c) => threadingLetter(c.threading)).join(), 'SSSSZZZZ');
    expect(_band1.cards.every((c) => sameArrangement(c.start, kPlyHome)), isTrue);
    expect([for (final c in _band1.palette) PrintColor(c.r, c.g, c.b).hex],
        ['#1A1A1A', '#F2EFE6', '#B3262E', '#D4A017']);
  });

  group('gather', () {
    test('checks the band, writes its instructions and draws its charts and keys once', () async {
      final repo = FakeTabletRepo(_band1Report);
      final s = await _source(_band1, repo: repo);
      expect(repo.calls.take(5), [
        'validate',
        'instructions $kTabletPrintMaxLines',
        'turning 8 1-12 @24',
        'top 8 1-12 @24 letters',
        'back 8 1-12 @24 letters',
      ]);
      expect(repo.calls.skip(5), ['turning 4 1-2 @24', 'top 6 1-3 @24 letters'],
          reason: 'the key cells, at the charts\' pitch');
      expect(s.chartedPicks, 12);
      expect((s.turning!.width, s.turning!.height), (8 * 24, 12 * 24));
      expect(s.top!.rgba.first, FakeTabletRepo.topShade);
      expect(s.back!.rgba.first, FakeTabletRepo.backShade);
      expect(s.keys.keys.toSet(), TabletKeyCell.values.toSet());
      expect(
          (s.keys[TabletKeyCell.forward]!.width, s.keys[TabletKeyCell.forward]!.height), (24, 24));
      expect(s.keys[TabletKeyCell.continued]!.height, 48, reason: 'a float and the cell below');
      expect(s.keys[TabletKeyCell.forward]!.rgba.first, FakeTabletRepo.turningShade);
      expect(s.keys[TabletKeyCell.zSlant]!.rgba.first, FakeTabletRepo.topShade);
      expect(s.instructions!.lines, _band1Lines);
      expect(s.printedAt, DateTime(2026, 11, 17));
    });

    test('a band with structural errors is not simulated at all', () async {
      final repo = FakeTabletRepo(_report([
        _diag(TabletSeverityKind.error, 'tablet.palette_ref', 'Hole B uses colour 9.',
            _loc(TabletLocationKind.hole, card: 2, hole: TabletHoleKind.b)),
      ]));
      final s = await _source(_band1, repo: repo);
      expect(repo.calls, ['validate']);
      expect(s.turning, isNull);
      expect(s.top, isNull);
      expect(s.instructions, isNull);
      expect(s.chartedPicks, 0);
    });
  });

  group('the document', () {
    test('has its sections in order, kind, title and title facts', () async {
      final doc = buildTabletPrintDocument(await _source(_band1), withProblemsBox: true);
      expect(doc.title, 'Oracle band 1');
      expect(doc.kind, 'Tablet weaving band');
      expect(doc.sections.map((s) => s.heading), [
        'Before you weave',
        'Notes',
        'Setup',
        'Turning chart',
        'Band chart',
        'Working instructions',
        'Checks',
      ]);
      expect({
        for (final f in doc.titleFacts) f.label: f.value
      }, {
        'Printed': '2026-11-17',
        'Cards': '8',
        'Picks': '12',
        'Packs': '2',
        'Start': 'A at the near top',
      });
      expect(doc.problemsBox, isNull, reason: 'no errors, no box');
    });

    test('says the rules await review, and that the chart is a colour chart, only when pending',
        () async {
      final pending = buildTabletPrintDocument(await _source(_band1), withProblemsBox: false);
      final notice = _all<PrintNotice>(_section(pending, 'Before you weave')).single;
      expect(notice.level, PrintNoticeLevel.caution);
      expect(notice.intro, kTabletReviewNote);
      expect(notice.lines.single, contains('colour chart, not a picture of the cloth'));
      expect(notice.lines.single, contains('weft'));

      final reviewed = buildTabletPrintDocument(
          await _source(_band1, report: _report(_band1Report.diagnostics, review: false)),
          withProblemsBox: false);
      expect(reviewed.sections.map((s) => s.heading), isNot(contains('Before you weave')));
      expect(_text(reviewed), isNot(contains(kTabletReviewNote)));
    });

    test('prints no em dashes and never names another program\'s format', () async {
      for (final doc in [
        buildTabletPrintDocument(await _source(_band1), withProblemsBox: true),
        buildTabletPrintDocument(await _source(_sampler2), withProblemsBox: true),
      ]) {
        expect(_text(doc), isNot(contains('\u2014')));
        expect(_text(doc), isNot(contains('WIF')));
      }
    });
  });

  group('setup', () {
    test('the threading chart: card numbers, D to A with A lowest, colour codes, S/Z, NT start',
        () async {
      final setup = _section(
          buildTabletPrintDocument(await _source(_band1), withProblemsBox: false), 'Setup');
      final drawing = _all<PrintDrawing>(setup).first;
      expect(_rows(drawing), [
        ['Card', '1', '2', '3', '4', '5', '6', '7', '8'],
        ['D', '1', '3', '1', '4', '4', '1', '3', '1'],
        ['C', '1', '1', '1', '2', '2', '1', '1', '1'],
        ['B', '1', '1', '2', '3', '3', '2', '1', '1'],
        ['A', '1', '2', '3', '1', '1', '3', '2', '1'],
        ['Threading', 'S', 'S', 'S', 'S', 'Z', 'Z', 'Z', 'Z'],
        ['Start (NT)', 'A', 'A', 'A', 'A', 'A', 'A', 'A', 'A'],
      ]);
      expect(drawing.caption, 'Threading chart, cards 1 to 8.');
      final texts = drawing.shapes.whereType<PrintVectorText>();
      double y(String label) => texts.firstWhere((t) => t.text == label && t.x < 20).y;
      expect(y('A'), greaterThan(y('B')));
      expect(y('B'), greaterThan(y('C')));
      expect(y('C'), greaterThan(y('D')), reason: 'A at the bottom, D at the top');
    });

    test('the colour key names each colour by number and hex, with a swatch', () async {
      final setup = _section(
          buildTabletPrintDocument(await _source(_band1), withProblemsBox: false), 'Setup');
      final key = _all<PrintLegend>(setup).single.entries;
      expect(key.map((e) => e.code), ['1', '2', '3', '4']);
      expect(key.map((e) => e.name), ['Colour 1', 'Colour 2', 'Colour 3', 'Colour 4']);
      expect(key.map((e) => e.swatch?.hex), ['#1A1A1A', '#F2EFE6', '#B3262E', '#D4A017']);
      expect(key.first.meaning, '#1A1A1A. Threaded in 18 holes.');
      expect(key.first.notes, ['The weft is this colour.']);
      expect(key.last.meaning, '#D4A017. Threaded in 2 holes.');
    });

    test('an empty hole has its own code', () async {
      final doc = setHole(_band1, 0, TabletHoleKind.a, null);
      final setup =
          _section(buildTabletPrintDocument(await _source(doc), withProblemsBox: false), 'Setup');
      expect(_rows(_all<PrintDrawing>(setup).first)[4].sublist(0, 2), ['A', '-']);
      final empty = _all<PrintLegend>(setup).single.entries.last;
      expect((empty.code, empty.name), ('-', 'Empty hole'));
    });

    test('start positions: the usual start, the card diagram and the threading legend', () async {
      final setup = _section(
          buildTabletPrintDocument(await _source(_band1), withProblemsBox: false), 'Setup');
      final paragraphs = _all<PrintParagraph>(setup).map((p) => p.text).toList();
      expect(
          paragraphs,
          contains('Every card starts at "A at the near top". Ply home: A at the near top, D at '
              'the far top, C at the far bottom, B at the near bottom. Forward turns bring A, B, '
              'C, D across the top.'));
      final diagram = _all<PrintDrawing>(setup)[1];
      final letters = {
        for (final t in diagram.shapes.whereType<PrintVectorText>())
          if (t.size == 13) (t.x < 104 ? 'near' : 'far', t.y < 36 ? 'top' : 'bottom'): t.text,
      };
      expect(letters, {
        ('near', 'top'): 'A',
        ('far', 'top'): 'D',
        ('far', 'bottom'): 'C',
        ('near', 'bottom'): 'B',
      });
      final words = diagram.shapes.whereType<PrintVectorText>().map((t) => t.text).toSet();
      expect(words, containsAll(['NT', 'FT', 'FB', 'NB', 'forward', 'near end', 'far end']));
      expect(diagram.shapes.whereType<PrintVectorArc>().length, 5, reason: '4 holes, 1 arrow');
      expect(diagram.caption, contains('clockwise in this view'));
      expect(diagram.caption, contains('away from the weaver'));

      final legend = _all<PrintDrawing>(setup)[2];
      final legendWords = legend.shapes.whereType<PrintVectorText>().map((t) => t.text);
      expect(legendWords, containsAll(['S-threaded', 'Z-threaded', 'far', 'near (weaver)']));
      // S: the thread runs like "\" (far end at the left, near end at the right); Z the mirror.
      final threads = legend.shapes
          .whereType<PrintVectorLine>()
          .where((l) => l.ink == PrintInk.accent)
          .toList();
      expect(threads.length, 2);
      expect(threads[0].x1 < threads[0].x2, isTrue, reason: 'S: near end to the right');
      expect(threads[1].x1 > threads[1].x2, isTrue, reason: 'Z: near end to the left');
      expect(legend.caption, contains("the card's face that points to the weaver's right"));
    });

    test('cards that start elsewhere are written out and starred on the chart', () async {
      final doc = buildTabletPrintDocument(await _source(_sampler2), withProblemsBox: false);
      final setup = _section(doc, 'Setup');
      expect(_rows(_all<PrintDrawing>(setup).first).last, ['Start (NT)', 'A', 'B*', 'D*', 'A']);
      final lines = _all<PrintLines>(setup).single.lines;
      expect(lines.map((l) => l.label), ['Card 2', 'Card 3']);
      expect(
          lines.first.text,
          'B at the near top, A at the far top, D at the far bottom, C at the near bottom; that '
          'is, 1 quarter turn forward from "A at the near top".');
      expect(
          lines.last.text,
          'D at the near top, A at the far top, B at the far bottom, C at the near bottom; that '
          'is, the start "Printed face to the right, D at the near top".');
      expect(_all<PrintParagraph>(setup).map((p) => p.text),
          contains(endsWith('These cards start in another position:')));
      expect(doc.titleFacts.firstWhere((f) => f.label == 'Start').value,
          'A at the near top (2 cards start elsewhere)');
    });

    test('packs list their cards', () async {
      final setup = _section(
          buildTabletPrintDocument(await _source(_band1), withProblemsBox: false), 'Setup');
      final packs = _all<PrintFacts>(setup).last.facts;
      expect({for (final f in packs) f.label: f.value},
          {'Left': 'Cards 1 to 4', 'Right': 'Cards 5 to 8'});
      final noPacks = _section(
          buildTabletPrintDocument(await _source(_sampler2), withProblemsBox: false), 'Setup');
      expect(_all<PrintParagraph>(noPacks).map((p) => p.text),
          contains('No packs: the working instructions name the cards by number.'));
    });

    test('a wide band\'s threading chart is printed in strips of whole cards', () async {
      final wide = setCardCount(_band1, 30);
      final setup = _section(
          buildTabletPrintDocument(await _source(wide, report: _report(const [])),
              withProblemsBox: false),
          'Setup');
      final strips = _all<PrintDrawing>(setup).where((d) => d.caption!.startsWith('Threading'));
      expect(strips.map((d) => d.caption),
          ['Threading chart, cards 1 to 24.', 'Threading chart, cards 25 to 30.']);
      expect(_rows(strips.last).first, ['Card', '25', '26', '27', '28', '29', '30']);
      for (final d in strips) {
        expect(d.width, lessThanOrEqualTo(510), reason: 'fits an A4 page without shrinking');
      }
    });
  });

  group('charts', () {
    test('the turning chart: numbered by pick from the bottom and by card, with its key', () async {
      final s = await _source(_band1);
      final turning =
          _section(buildTabletPrintDocument(s, withProblemsBox: false), 'Turning chart');
      final chart = _all<PrintChart>(turning).single;
      expect(identical(chart.raster, s.turning), isTrue);
      expect((chart.columns, chart.rows), (8, 12));
      expect(chart.columnNumbers, [1, 2, 3, 4, 5, 6, 7, 8]);
      expect(chart.rowNumbers, [for (var p = 1; p <= 12; p++) p], reason: 'pick 1 at the bottom');
      expect((chart.rowsName, chart.columnsName), ('Picks', 'cards'));
      final key = _all<PrintLegend>(turning).single.entries;
      expect(key.map((e) => e.code), ['F', 'B', 'I', '?', 'Flip', 'Release']);
      expect(key.every((e) => e.glyph != null), isTrue, reason: 'drawn as on the chart');
      expect(key[4].meaning, contains('dashed'));
      expect(key[5].meaning, contains('dotted'));
    });

    test('the pattern\'s own words for a ? are listed under the turning chart', () async {
      final doc = copyDoc(_band1, turning: [
        TabletSegmentDto(repeat: 1, picks: [
          copyPick(uniformPick(8, 'F'),
              turns: 'FFF?FFFF',
              unsupported: const [TabletWordsDto(card: 'card-4', text: 'half turn forward')]),
        ]),
      ]);
      final turning = _section(
          buildTabletPrintDocument(await _source(doc, report: _report(const [], picks: 1)),
              withProblemsBox: false),
          'Turning chart');
      final words = _all<PrintLines>(turning).single.lines.single;
      expect((words.label, words.text), ('Segment 1, pick 1, card 4', 'half turn forward'));
    });

    test('the band chart: the top face with card 1 at the left, the back with card 1 at the right',
        () async {
      final s = await _source(_band1);
      final band = _section(buildTabletPrintDocument(s, withProblemsBox: false), 'Band chart');
      final charts = _all<PrintChart>(band);
      expect(charts.length, 2);
      final (top, back) = (charts[0], charts[1]);
      expect(identical(top.raster, s.top), isTrue);
      expect(identical(back.raster, s.back), isTrue);
      expect(top.columnNumbers, [1, 2, 3, 4, 5, 6, 7, 8]);
      expect(back.columnNumbers, [8, 7, 6, 5, 4, 3, 2, 1]);
      expect(back.startAtRight, isTrue, reason: 'a split back starts at card 1');
      expect(top.rowNumbers.first, 1);
      final texts = _all<PrintParagraph>(band).map((p) => p.text).toList();
      expect(texts, contains('Top face'));
      expect(texts, contains('Back'));
      expect(texts, contains(contains('card 1 at the right, pick 1 at the bottom')));
      expect(texts.first, contains('not a picture of the cloth'));
      final key = _all<PrintLegend>(band).single.entries;
      expect(key.map((e) => e.code),
          ['Z', 'S', 'Float', 'Reversal', 'Either', 'No thread', 'Unknown', 'A to D']);
      expect(key.take(7).every((e) => e.glyph != null), isTrue);
    });

    test('a long band says which picks are charted', () async {
      final long = copyDoc(_band1, turning: [
        TabletSegmentDto(repeat: 5000, picks: [uniformPick(8, 'F')])
      ]);
      final repo = FakeTabletRepo(_report(const [], picks: 5000));
      final s = await _source(long, repo: repo);
      expect(repo.calls, contains('turning 8 1-1365 @12'));
      expect(s.chartedPicks, 1365);
      final doc = buildTabletPrintDocument(s, withProblemsBox: false);
      for (final heading in ['Turning chart', 'Band chart']) {
        final notice = _all<PrintNotice>(_section(doc, heading)).single;
        expect(notice.title, 'Picks 1 to 1,365 of 5,000 are charted');
        expect(notice.intro, contains('The working instructions cover every pick.'));
      }
      expect(_all<PrintChart>(_section(doc, 'Turning chart')).single.rowNumbers.last, 1365);
      expect(doc.titleFacts.firstWhere((f) => f.label == 'Picks').value, '5,000');
    });

    test('a long band whose instructions are cut short says how far they go', () async {
      final long = copyDoc(_band1, turning: [
        TabletSegmentDto(repeat: 5000, picks: [uniformPick(8, 'F')])
      ]);
      final repo = FakeTabletRepo(_report(const [], picks: 5000), omitted: 40);
      final doc = buildTabletPrintDocument(await _source(long, repo: repo), withProblemsBox: false);
      expect(_all<PrintNotice>(_section(doc, 'Turning chart')).single.intro,
          contains('The working instructions are printed up to pick 12.'));
      final cut = _all<PrintNotice>(_section(doc, 'Working instructions')).single;
      expect(cut.title, 'Not every line is printed');
      expect(cut.intro, contains('the first 6 lines'));
      expect(cut.intro, contains('the other 40 lines are left out'));
    });
  });

  group('working instructions and checks', () {
    test('the engine\'s lines print as given, labels bold, with the twist explained', () async {
      final section = _section(
          buildTabletPrintDocument(await _source(_band1), withProblemsBox: false),
          'Working instructions');
      final lines = _all<PrintLines>(section).single.lines;
      expect([for (final l in lines) (l.label, l.text)],
          [for (final l in _band1Lines) (l.label, l.text)]);
      expect(lines.every((l) => !l.flagged), isTrue);
      final intro = _all<PrintParagraph>(section).first.text;
      expect(intro, contains(kTabletTwistNote));
      expect(kTabletTwistNote, contains('quarter turns'));
      expect(kTabletTwistNote, contains('Z twining counts plus'));
      expect(kTabletTwistNote, contains('opposite hand'));
    });

    test('every finding is listed with its place; notes too while they are few', () async {
      final report = _report([
        _diag(
            TabletSeverityKind.warning,
            'tablet.long_float',
            'The thread in hole B floats over 4 picks.',
            _loc(TabletLocationKind.run,
                card: 1,
                hole: TabletHoleKind.b,
                face: TabletFaceKind.top,
                firstPick: 1,
                lastPick: 4),
            remediation: 'Turn the card, or accept the float.'),
        _diag(TabletSeverityKind.unsupported, 'tablet.unsupported_turn', 'Ply does not model this.',
            _loc(TabletLocationKind.step, segment: 2, step: 1, card: 4)),
        _diag(TabletSeverityKind.info, 'tablet.reversal', 'Reversal at pick 5, cards 1 to 8.',
            _loc(TabletLocationKind.pick, pick: 5, cards: [1, 2, 3, 4, 5, 6, 7, 8])),
        _diag(TabletSeverityKind.warning, 'tablet.pack_overlap', 'Pack 1 names card 3 twice.',
            _loc(TabletLocationKind.pack, pack: 1)),
      ]);
      final checks = _section(
          buildTabletPrintDocument(await _source(_band1, report: report), withProblemsBox: false),
          'Checks');
      final issues = _all<PrintIssues>(checks).single.issues;
      expect([
        for (final i in issues) (i.severity, i.where)
      ], [
        (PrintIssueSeverity.warning, 'Card 1, hole B, top face, picks 1 to 4'),
        (PrintIssueSeverity.warning, 'Pack 1 (Left)'),
        (PrintIssueSeverity.notChecked, 'Segment 2, pick 1, card 4'),
        (PrintIssueSeverity.note, 'Pick 5, cards 1 to 8'),
      ]);
      expect(issues.first.message,
          'The thread in hole B floats over 4 picks. Turn the card, or accept the float.');
    });

    test('many notes are counted, not listed; an empty check says so', () async {
      final notes = _report([
        for (var p = 1; p <= kTabletPrintMaxNotes + 1; p++)
          _diag(TabletSeverityKind.info, 'tablet.reversal', 'Reversal at pick $p, card 1.',
              _loc(TabletLocationKind.pick, pick: p, cards: [1])),
      ]);
      final checks = _section(
          buildTabletPrintDocument(await _source(_band1, report: notes), withProblemsBox: false),
          'Checks');
      expect(_all<PrintIssues>(checks).single.issues, isEmpty);
      expect(_all<PrintParagraph>(checks).last.text,
          startsWith('Ply also made ${kTabletPrintMaxNotes + 1} notes about this band'));
      final clean = _section(
          buildTabletPrintDocument(await _source(_band1, report: _report(const [])),
              withProblemsBox: false),
          'Checks');
      expect(_all<PrintIssues>(clean).single.emptyText, 'Ply found no problems in this band.');
    });
  });

  group('a band with structural errors', () {
    final errors = _report([
      _diag(TabletSeverityKind.error, 'tablet.turns_length', 'Pick 2 names 7 cards, not 8.',
          _loc(TabletLocationKind.step, segment: 1, step: 2)),
      _diag(TabletSeverityKind.warning, 'tablet.pack_overlap', 'Card 3 is in two packs.',
          _loc(TabletLocationKind.packCard, card: 3, packs: [1, 2])),
    ], picks: null);
    final broken = copyDoc(_band1, turning: [
      TabletSegmentDto(repeat: 2, picks: [
        uniformPick(8, 'F'),
        const TabletPickDto(
            turns: 'BBBBBBB', releaseTwist: ['card-1'], flip: ['card-4'], unsupported: []),
      ]),
    ]);

    test('prints the setup and says the charts and instructions are missing', () async {
      final doc =
          buildTabletPrintDocument(await _source(broken, report: errors), withProblemsBox: false);
      expect(doc.sections.map((s) => s.heading), [
        'Before you weave',
        'Notes',
        'Setup',
        'Turning chart',
        'Band chart',
        'Working instructions',
        'Checks',
      ]);
      final before = _all<PrintNotice>(_section(doc, 'Before you weave'));
      expect(before.last.level, PrintNoticeLevel.problem);
      expect(before.last.title, 'No charts can be drawn yet');
      expect(before.last.intro, contains('missing from this PDF until the errors are fixed'));
      // The setup is still printed from the document.
      expect(_rows(_all<PrintDrawing>(_section(doc, 'Setup')).first)[1].first, 'D');
      for (final (heading, what) in [
        ('Turning chart', 'turning chart'),
        ('Band chart', 'band chart'),
        ('Working instructions', 'working instructions'),
      ]) {
        final section = _section(doc, heading);
        expect(_all<PrintChart>(section), isEmpty);
        final notice = _all<PrintNotice>(section).first;
        expect(notice.level, PrintNoticeLevel.problem);
        expect(notice.title, 'The $what ${what.endsWith('s') ? 'are' : 'is'} missing');
      }
      // The turning as written, unchecked.
      final written = _all<PrintLines>(_section(doc, 'Working instructions')).single.lines;
      expect([
        for (final l in written) (l.label, l.text)
      ], [
        ('Pick 1', 'FFFF FFFF'),
        ('Pick 2', 'Before the pick: release the twist behind card 1; flip card 4. BBBB BBB'),
      ]);
      expect(_all<PrintParagraph>(_section(doc, 'Working instructions')).first.text,
          'Segment 1, worked 2 times');
      expect(doc.titleFacts.firstWhere((f) => f.label == 'Picks').value, '4',
          reason: 'counted from the document when the engine cannot');
      final issues = _all<PrintIssues>(_section(doc, 'Checks')).single.issues;
      expect([
        for (final i in issues) (i.severity, i.where)
      ], [
        (PrintIssueSeverity.error, 'Segment 1, pick 2'),
        (PrintIssueSeverity.warning, 'Card 3, packs 1 and 2'),
      ]);
    });

    test('a draft copy carries the problems box; without the choice there is none', () async {
      final s = await _source(broken, report: errors);
      final box = buildTabletPrintDocument(s, withProblemsBox: true).problemsBox!;
      expect(box.level, PrintNoticeLevel.problem);
      expect(box.title, 'This band has problems');
      expect(box.intro, startsWith('Ply found 1 error in this band'));
      expect(box.lines, ['Segment 1, pick 2: Pick 2 names 7 cards, not 8.']);
      expect(buildTabletPrintDocument(s, withProblemsBox: false).problemsBox, isNull);
    });
  });

  group('readiness', () {
    final mixed = _report([
      _diag(TabletSeverityKind.info, 'tablet.reversal', 'Reversal at pick 5, cards 1 to 8.',
          _loc(TabletLocationKind.pick, pick: 5, cards: [1, 2, 3, 4, 5, 6, 7, 8])),
      _diag(TabletSeverityKind.unsupported, 'tablet.empty_hole_face', 'Hole C is empty.',
          _loc(TabletLocationKind.pick, pick: 2, cards: [1, 2, 4], face: TabletFaceKind.back)),
      _diag(
          TabletSeverityKind.warning,
          'tablet.long_float',
          'A long float.',
          _loc(TabletLocationKind.run,
              card: 1, hole: TabletHoleKind.b, face: TabletFaceKind.top, firstPick: 1, lastPick: 4),
          remediation: 'Turn the card.'),
      _diag(TabletSeverityKind.error, 'tablet.start_illegal', 'Card 3 cannot start there.',
          _loc(TabletLocationKind.card, card: 3)),
      _diag(TabletSeverityKind.error, 'tablet.too_large', 'The band is too large.',
          _loc(TabletLocationKind.band)),
    ]);

    test('maps severities, codes, messages, remediations and places, most serious first', () {
      final r = tabletReadiness(mixed);
      expect(r.checked, [ReadinessCheck.band]);
      expect(r.checkedWords, 'the band');
      expect(r.items.every((i) => i.check == ReadinessCheck.band), isTrue);
      expect([
        for (final i in r.items) (i.level, i.code, i.place)
      ], [
        (ReadinessLevel.error, 'tablet.start_illegal', 'Card 3'),
        (ReadinessLevel.error, 'tablet.too_large', null),
        (ReadinessLevel.warning, 'tablet.long_float', 'Card 1, hole B, top face, picks 1 to 4'),
        (ReadinessLevel.unsupported, 'tablet.empty_hole_face', 'Pick 2, cards 1, 2 and 4, back'),
        (ReadinessLevel.info, 'tablet.reversal', 'Pick 5, cards 1 to 8'),
      ]);
      final warning = r.warnings.single;
      expect(warning.message, 'A long float.');
      expect(warning.remediation, 'Turn the card.');
      expect(warning.text, 'Card 1, hole B, top face, picks 1 to 4: A long float.');
      expect(r.errors[1].text, 'The band is too large.', reason: 'the whole band has no place');
    });

    test('verdicts: errors are not ready, warnings or unsupported ask, information never asks', () {
      ReadinessVerdict only(TabletSeverityKind k) => tabletReadiness(_report([
            _diag(k, 'tablet.x', 'x', _loc(TabletLocationKind.band)),
          ])).verdict;
      expect(tabletReadiness(mixed).verdict, ReadinessVerdict.notReady);
      expect(only(TabletSeverityKind.error), ReadinessVerdict.notReady);
      expect(only(TabletSeverityKind.warning), ReadinessVerdict.needsAcknowledgement);
      expect(only(TabletSeverityKind.unsupported), ReadinessVerdict.needsAcknowledgement);
      expect(only(TabletSeverityKind.info), ReadinessVerdict.ready);
      expect(tabletReadiness(_report(const [])).verdict, ReadinessVerdict.ready);
      expect(tabletReadiness(_band1Report).verdict, ReadinessVerdict.ready,
          reason: 'oracle band 1 has only reversal notes');
    });

    test('places in words for every kind of location', () {
      expect(tabletPlaceText(_loc(TabletLocationKind.hole, card: 1, hole: TabletHoleKind.b)),
          'Card 1, hole B');
      expect(tabletPlaceText(_loc(TabletLocationKind.cards, cards: [2, 3])), 'Cards 2 and 3');
      expect(tabletPlaceText(_loc(TabletLocationKind.pack, pack: 2)), 'Pack 2');
      expect(
          tabletPlaceText(_loc(TabletLocationKind.pack, pack: 2), doc: _band1), 'Pack 2 (Right)');
      expect(tabletPlaceText(_loc(TabletLocationKind.segment, segment: 2)), 'Segment 2');
      expect(
          tabletPlaceText(_loc(TabletLocationKind.step, segment: 2, step: 1)), 'Segment 2, pick 1');
      expect(
          tabletPlaceText(_loc(TabletLocationKind.pick,
              pick: 3, cards: [for (var c = 1; c <= 32; c++) c], cardsTotal: 40)),
          'Pick 3, cards 1 to 32 and 8 more');
      expect(tabletPlaceText(_loc(TabletLocationKind.pick, pick: 7)), 'Pick 7');
      expect(
          tabletPlaceText(_loc(TabletLocationKind.run,
              card: 2,
              hole: TabletHoleKind.d,
              face: TabletFaceKind.back,
              firstPick: 6,
              lastPick: 6)),
          'Card 2, hole D, back, pick 6');
      expect(tabletPlaceText(_loc(TabletLocationKind.omitted)), isNull);
      expect(tabletCardsText([1, 2, 4, 5, 6, 9]), 'cards 1, 2, 4 to 6 and 9');
      expect(tabletCardsText([3]), 'card 3');
    });
  });

  group('the PDF', () {
    test('lays out the whole band and reads back what it says', () async {
      final pdf = PdfReadBack(await buildPrintPdf(
        buildTabletPrintDocument(await _source(_band1), withProblemsBox: false),
        page: PrintPageSetup.forUnit(MeasureUnit.centimeters),
        fonts: testFonts(),
        compress: false,
      ));
      for (final t in [
        'Oracle band 1',
        'Tablet weaving band',
        'Printed: 2026-11-17',
        'Before you weave',
        "Awaiting a tablet weaver's review",
        'Setup',
        'Threading chart, cards 1 to 8.',
        'Start (NT)',
        'Colour key',
        'Colour 3',
        '#B3262E',
        'Start positions',
        'near end',
        'Threading S and Z',
        'S-threaded',
        'Packs',
        'Turning chart',
        'Picks 1 to 12, cards 1 to 8',
        'Band chart',
        'Top face',
        'Working instructions',
        'Picks 9 to 12:',
        'Left (cards 1 to 4) forward; Right (cards 5 to 8) backward. Worked 4 times.',
        'After pick 12:',
        'Twist: cards 1 to 8 +4.',
        'Checks',
        'Pick 5, cards 1 to 8',
        'Page 1 of ${pdf.pageCount}',
      ]) {
        expect(pdf.text, contains(t));
      }
      expect(pdf.text, isNot(contains('\u2014')));
      expect(pdf.text, isNot(contains('WIF')));
      expect(pdf.mediaBoxes.first[2], closeTo(PdfPageFormat.a4.width, 0.01));
    });

    test('a draft copy of a band with errors lays out too', () async {
      final s = await _source(_band1,
          report: _report([
            _diag(TabletSeverityKind.error, 'tablet.palette_ref', 'Hole B uses colour 9.',
                _loc(TabletLocationKind.hole, card: 2, hole: TabletHoleKind.b)),
          ], picks: null));
      final pdf = PdfReadBack(await buildPrintPdf(
        buildTabletPrintDocument(s, withProblemsBox: true).asDraftCopy(1),
        page: PrintPageSetup.forUnit(MeasureUnit.inches),
        fonts: testFonts(),
        compress: false,
      ));
      for (final t in [
        'Draft copy, not ready to make or share: 1 error',
        'This band has problems',
        'Card 2, hole B: Hole B uses colour 9.',
        'No charts can be drawn yet',
        'The turning chart is missing',
        'The working instructions are missing',
        'Segment 1, worked 4 times',
      ]) {
        expect(pdf.text, contains(t));
      }
    });

    test('making the PDF never touches the network', () async {
      var attempts = 0;
      Never refuse(String what) {
        attempts++;
        throw StateError('network access during PDF export: $what');
      }

      Uint8List? out;
      await HttpOverrides.runZoned(
        () => IOOverrides.runZoned(
          () async {
            final fonts = await PlyPdfFonts.load();
            final s = await _source(_band1);
            out = await buildPrintPdf(buildTabletPrintDocument(s, withProblemsBox: false),
                page: PrintPageSetup.forUnit(MeasureUnit.centimeters), fonts: fonts);
          },
          socketConnect: (host, port, {sourceAddress, sourcePort = 0, timeout}) =>
              refuse('socket $host:$port'),
          socketStartConnect: (host, port, {sourceAddress, sourcePort = 0}) =>
              refuse('socket $host:$port'),
          serverSocketBind: (address, port, {backlog = 0, v6Only = false, shared = false}) =>
              refuse('listen $address:$port'),
        ),
        createHttpClient: (_) => refuse('HTTP client'),
      );
      expect(attempts, 0);
      expect(String.fromCharCodes(out!.take(5)), '%PDF-');
    });
  });

  group('the print flow', () {
    Future<_Recorder> run(WidgetTester tester, TabletReportDto report, String action) async {
      final out = _Recorder();
      await tester.pumpWidget(ProviderScope(
        overrides: [
          pdfOutputProvider.overrideWithValue(out),
          plyPdfFontsProvider.overrideWith((_) async => testFonts()),
          appSettingsProvider.overrideWith(_FixedSettings.new),
          tabletRepositoryProvider.overrideWithValue(FakeTabletRepo(report)),
          tabletDocProvider.overrideWithValue(_band1),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => Center(
                child: ElevatedButton(
                  onPressed: () => printOrShareTabletPdf(context, ref, name: 'Oracle band 1'),
                  child: const Text('go'),
                ),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(action));
      await tester.pumpAndSettle();
      return out;
    }

    testWidgets('a band with only notes prints straight away', (tester) async {
      final out = await run(tester, _band1Report, 'Print');
      expect(find.byType(AlertDialog), findsNothing);
      expect(out.printed.single.$1, 'Oracle band 1.pdf');
      expect(String.fromCharCodes(out.printed.single.$2.take(5)), '%PDF-');
    });

    testWidgets('warnings are acknowledged first', (tester) async {
      final out = await run(
          tester,
          _report([
            _diag(TabletSeverityKind.warning, 'tablet.long_float', 'A long float.',
                _loc(TabletLocationKind.card, card: 2)),
          ]),
          'Share PDF');
      expect(find.text('Check this band before you share it'), findsOneWidget);
      expect(find.text('• Card 2: A long float.'), findsOneWidget);
      expect(find.textContaining('Ply found no errors in the band.'), findsOneWidget);
      await tester.tap(find.text('Acknowledge and share'));
      await tester.pumpAndSettle();
      expect(out.shared.single.$1, 'Oracle band 1.pdf');
    });

    testWidgets('errors make it not ready; only a draft copy is made', (tester) async {
      final out = await run(
          tester,
          _report([
            _diag(TabletSeverityKind.error, 'tablet.palette_ref', 'Hole B uses colour 9.',
                _loc(TabletLocationKind.hole, card: 2, hole: TabletHoleKind.b)),
          ], picks: null),
          'Print');
      expect(find.text('This band is not ready to make or share'), findsOneWidget);
      expect(find.text('• Card 2, hole B: Hole B uses colour 9.'), findsOneWidget);
      await tester.tap(find.text('Print a draft copy'));
      await tester.pumpAndSettle();
      expect(out.printed.single.$1, 'Oracle band 1 (draft copy).pdf');
    });
  });

  group('text printed straight from the band file is bounded', () {
    int lineCount(PrintDocument d) => [
          for (final s in d.sections)
            for (final b in s.blocks.whereType<PrintLines>()) b.lines.length,
        ].fold(0, (a, b) => a + b);
    TabletCardDto card(String id) => TabletCardDto(
        id: id, a: 0, b: 0, c: 0, d: 0, threading: TabletThreadingKind.s, start: kPlyHome);
    TabletDocumentDto band(List<TabletCardDto> cards, TabletPickDto pick, int picks) =>
        TabletDocumentDto(
          name: 'At the caps',
          notes: '',
          palette: const [TabletColorDto(r: 0, g: 0, b: 0)],
          cards: cards,
          packs: const [],
          turning: [TabletSegmentDto(repeat: 1, picks: List.filled(picks, pick))],
          settings: kDefaultTabletSettings,
        );

    test('1,000 cards marked ? on every pick: the words share one capped budget', () {
      const cards = 1000, picks = 400;
      final ids = [for (var i = 0; i < cards; i++) 'c$i'];
      final pick = TabletPickDto(
        turns: '?' * cards,
        releaseTwist: const [],
        flip: const [],
        unsupported: [for (final id in ids) TabletWordsDto(card: id, text: 'h')],
        note: TabletNoteDto(kind: TabletNoteKind.other, text: 'n' * 10000),
      );
      // Charts of the first pick (a few pixels each: only the text is measured here).
      final raster = PrintRaster(width: cards, height: 1, rgba: Uint8List(cards * 4));
      final s = TabletPrintSource(
          name: 'At the caps',
          doc: band([for (final id in ids) card(id)], pick, picks),
          report: _report(const [], picks: picks),
          printedAt: DateTime(2026, 11, 17),
          turning: raster,
          top: raster,
          back: raster,
          chartedPicks: 1);
      final d = buildTabletPrintDocument(s, withProblemsBox: false);
      // 400,000 words and 400 notes in the file; at most the budget printed.
      expect(lineCount(d), lessThanOrEqualTo(kTabletPrintMaxFileLines));
      final text = _text(d);
      expect(text.length, lessThan(2 * 1024 * 1024));
      expect(text, contains('more cards marked ? are not listed'));
      expect(text, contains('more notes are not listed'));
      expect(text.contains('n' * 300), isFalse, reason: 'a note is quoted in short');
    });

    test('a band with errors releasing and flipping 1,000 copies of a 10,000-byte unknown id', () {
      final id = 'x' * 10000;
      final pick = TabletPickDto(
        turns: 'FFFF',
        releaseTwist: List.filled(1000, id),
        flip: List.filled(1000, id),
        unsupported: const [],
      );
      final s = TabletPrintSource(
        name: 'Hostile',
        doc: band([for (var i = 0; i < 4; i++) card('c$i')], pick, 2061),
        report: _report([
          _diag(TabletSeverityKind.error, 'tablet.card_ref', 'Names a card not in the band.',
              _loc(TabletLocationKind.step, segment: 1, step: 1)),
        ], picks: null),
        printedAt: DateTime(2026, 11, 17),
      );
      expect(s.hasErrors, isTrue);
      final d = buildTabletPrintDocument(s, withProblemsBox: true);
      expect(lineCount(d), lessThanOrEqualTo(kTabletPrintMaxFileLines));
      final text = _text(d);
      expect(text.length, lessThan(2 * 1024 * 1024));
      expect(text.contains('x' * 100), isFalse, reason: 'ids are quoted in short');
      expect(text, contains('997 more cards not in the band'));
      expect(text, contains('more written picks are not printed'));
    });
  });
}

/// Records what reached the system print and share dialogs.
class _Recorder implements PdfOutput {
  final printed = <(String, Uint8List)>[];
  final shared = <(String, Uint8List)>[];

  @override
  Future<bool> print({
    required String name,
    required PdfPageFormat format,
    required Future<Uint8List> Function(PdfPageFormat format) build,
  }) async {
    printed.add((name, await build(format)));
    return true;
  }

  @override
  Future<bool> share({required String filename, required Uint8List bytes}) async {
    shared.add((filename, bytes));
    return true;
  }
}

class _FixedSettings extends AppSettingsNotifier {
  @override
  AppSettings build() => const AppSettings(unit: MeasureUnit.centimeters);
}
