// The printable TABLET WEAVING band (M10-02, ADR 0018 sections 8 and 15): a setup page (the threading
// chart, the colour key, the start positions with the section 2 card diagram, the threading legend
// with the section 3 diagram, the packs), the turning chart, the band chart (top face and back), the
// written working instructions with the twist ledger, and every finding of the band's check.
// [gatherTabletPrint] makes the engine calls once; [buildTabletPrintDocument] is pure, so every
// printed word is host-testable; [printOrShareTabletPdf] hands the result to the shared flow.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/widgets.dart' show BuildContext;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/tablet_repository.dart';
import '../models/readiness.dart';
import '../models/tablet_band.dart';
import '../rust/tablet_dto.dart';
import '../state/tablet_editor_providers.dart';
import 'print_document.dart';
import 'print_export.dart';

// --- the print budget ------------------------------------------------------------------------------

/// The most cells (cards times picks) each printed chart holds. A band longer than this is charted
/// from pick 1 for as many picks as fit; the PDF says so, and the working instructions cover the
/// rest. Three charts are drawn (the turning chart, the top face and the back), so this keeps the
/// whole PDF's pictures to a few tens of megabytes on a phone.
const int kTabletPrintMaxCells = 20000;

/// The biggest and smallest raster pixels per printed cell. A typical band prints at 24 px for a
/// 5 mm cell (about 120 dpi); a large chart drops toward 12, still enough for the hole letters.
const int kTabletPrintCellPxMax = 24;
const int kTabletPrintCellPxMin = 12;

/// Raster pixels per chart, before the pitch is clamped.
const int _printPixelBudget = 3000000;

/// The engine's longest raster side (`ply_tablet::RasterLimits::DEFAULT`).
const int _rasterSide = 16384;

/// The most lines of working instructions the PDF prints.
const int kTabletPrintMaxLines = 2000;

/// The most lines the PDF prints from the band file itself (the pattern's words for every `?`, the
/// notes on picks and, for a band with errors, the turning as written), all together; the rest are
/// counted. A band file can hold over a million of them within the engine's limits.
const int kTabletPrintMaxFileLines = 2000;

/// The most characters those lines hold together.
const int kTabletPrintMaxFileChars = 400000;

/// The most cards one printed event or word list names before "and N more".
const int kTabletPrintMaxCardsPerLine = 32;

/// The budget of [kTabletPrintMaxFileLines] lines and [kTabletPrintMaxFileChars] characters shared by
/// everything printed straight from the band file. Once a line does not fit, nothing more does.
class _FileText {
  int _lines = kTabletPrintMaxFileLines;
  int _chars = kTabletPrintMaxFileChars;

  bool take(PrintLine line) {
    final n = line.text.length + (line.label?.length ?? 0);
    if (_lines <= 0 || n > _chars) {
      _lines = 0;
      return false;
    }
    _lines--;
    _chars -= n;
    return true;
  }
}

/// [s] trimmed to at most [max] characters, with "..." when cut (as the engine quotes text).
String _short(String s, [int max = 80]) {
  final t = s.trim();
  final r = t.runes;
  if (r.length <= max) return t;
  return '${String.fromCharCodes(r.take(max))}...';
}

/// [cards] (sorted card numbers) in words, naming at most [kTabletPrintMaxCardsPerLine] of them.
String _cardsUpTo(List<int> cards) =>
    tabletCardsText(cards.take(kTabletPrintMaxCardsPerLine).toList(), cards.length);

/// The cards [ids] name, by number where the band has them: "cards 1 to 32 and 968 more", with any
/// unknown ids quoted in short (at most a few, then counted).
String _cardsNamed(List<String> ids, Map<String, int> number) {
  final known = <int>[];
  final unknown = <String>[];
  for (final id in ids) {
    final n = number[id];
    if (n != null) {
      known.add(n);
    } else {
      unknown.add(id);
    }
  }
  known.sort();
  final parts = <String>[
    if (known.isNotEmpty)
      tabletCardsText(known.take(kTabletPrintMaxCardsPerLine).toList(), known.length),
    for (final id in unknown.take(3)) 'card "${_short(id, 40)}" (not in the band)',
    if (unknown.length > 3) '${_count(unknown.length - 3)} more cards not in the band',
  ];
  return _and(parts);
}

/// The most notes (information findings) the Checks table lists; more are counted instead.
const int kTabletPrintMaxNotes = 40;

/// The picks charted (from pick 1) and the raster pitch for a band of [cards] cards and [total]
/// picks: at most [kTabletPrintMaxCells] cells, a pitch between [kTabletPrintCellPxMin] and
/// [kTabletPrintCellPxMax] from the pixel budget, and never a raster side past the engine's limit,
/// so the engine draws exactly the pitch asked for.
({int picks, int cellPx}) tabletPrintWindow(int cards, int total) {
  if (cards <= 0 || total <= 0) return (picks: 0, cellPx: kTabletPrintCellPxMax);
  final wanted = math.min(total, math.max(1, kTabletPrintMaxCells ~/ cards));
  final fit = math.sqrt(_printPixelBudget / (cards * wanted)).floor();
  final px = math.min(
    fit.clamp(kTabletPrintCellPxMin, kTabletPrintCellPxMax),
    math.max(1, _rasterSide ~/ cards),
  );
  return (picks: math.min(wanted, _rasterSide ~/ px), cellPx: px);
}

// --- the source ------------------------------------------------------------------------------------

/// The cells of the printed keys, each drawn by the engine exactly as on the charts.
enum TabletKeyCell {
  forward,
  backward,
  idle,
  notModelledTurn,
  flip,
  release,
  zSlant,
  sSlant,
  continued,
  reversal,
  ambiguous,
  emptyHole,
  unknown,
}

/// Everything a printed band is made from, gathered from the engine once.
class TabletPrintSource {
  const TabletPrintSource({
    required this.name,
    required this.doc,
    required this.report,
    required this.printedAt,
    this.instructions,
    this.instructionsFailure,
    this.turning,
    this.top,
    this.back,
    this.chartedPicks = 0,
    this.chartFailure,
    this.keys = const {},
  });

  /// The band's display name.
  final String name;
  final TabletDocumentDto doc;

  /// The engine's check of [doc].
  final TabletReportDto report;

  /// The working instructions (at most [kTabletPrintMaxLines] lines), or null when the band has
  /// structural errors or they could not be written ([instructionsFailure] says why).
  final TabletInstructionsDto? instructions;
  final String? instructionsFailure;

  /// The turning chart, top face and back (with hole letters) of picks 1 to [chartedPicks], or null
  /// when the band has structural errors or could not be drawn ([chartFailure] says why).
  final PrintRaster? turning;
  final PrintRaster? top;
  final PrintRaster? back;
  final int chartedPicks;
  final String? chartFailure;

  /// The key cells, drawn by the engine (missing ones are described in words only).
  final Map<TabletKeyCell, PrintRaster> keys;
  final DateTime printedAt;

  /// The band's picks with every repeat written out.
  int get totalPicks => report.expandedPicks ?? expandedPicks(doc);

  bool get hasErrors => report.errors > 0;
}

/// Check [doc], and when it has no structural errors write its working instructions and draw its
/// charts (picks 1 to [tabletPrintWindow]'s picks) and key cells through [repo].
Future<TabletPrintSource> gatherTabletPrint(
  TabletRepository repo, {
  required String name,
  required TabletDocumentDto doc,
  DateTime? now,
}) async {
  final report = await repo.validate(doc);
  final printedAt = now ?? DateTime.now();
  final cards = doc.cards.length;
  final total = report.expandedPicks ?? 0;
  if (report.errors > 0 || cards == 0 || total == 0) {
    return TabletPrintSource(name: name, doc: doc, report: report, printedAt: printedAt);
  }

  TabletInstructionsDto? instructions;
  String? instructionsFailure;
  try {
    instructions = await repo.instructions(doc, maxLines: kTabletPrintMaxLines);
  } on TabletRunFailure catch (f) {
    instructionsFailure = f.message;
  }

  final window = tabletPrintWindow(cards, total);
  PrintRaster? turning, top, back;
  String? chartFailure;
  try {
    turning = _raster(await repo.renderTurning(doc, 1, window.picks, cellPx: window.cellPx));
    top = _raster(await repo.renderFace(doc, 1, window.picks,
        face: TabletFaceKind.top, cellPx: window.cellPx, letters: true));
    back = _raster(await repo.renderFace(doc, 1, window.picks,
        face: TabletFaceKind.back, cellPx: window.cellPx, letters: true));
  } on TabletRunFailure catch (f) {
    turning = top = back = null;
    chartFailure = f.message;
  }

  final keys = <TabletKeyCell, PrintRaster>{};
  if (chartFailure == null) {
    try {
      final t = await repo.renderTurning(_turningKeyDoc, 1, 2, cellPx: window.cellPx);
      for (final (cell, card, pick) in _turningKeyCells) {
        final g = _crop(t, card: card, pick: pick);
        if (g != null) keys[cell] = g;
      }
      final f = await repo.renderFace(_faceKeyDoc, 1, 3,
          face: TabletFaceKind.top, cellPx: window.cellPx, letters: true);
      for (final (cell, card, pick, tall) in _faceKeyCells) {
        final g = _crop(f, card: card, pick: pick, picks: tall);
        if (g != null) keys[cell] = g;
      }
    } on TabletRunFailure {
      // The keys then describe every mark in words only.
    }
  }

  return TabletPrintSource(
    name: name,
    doc: doc,
    report: report,
    printedAt: printedAt,
    instructions: instructions,
    instructionsFailure: instructionsFailure,
    turning: turning,
    top: top,
    back: back,
    chartedPicks: turning == null ? 0 : window.picks,
    chartFailure: chartFailure,
    keys: keys,
  );
}

PrintRaster? _raster(TabletRasterDto r) => r.width == 0 || r.height == 0 || r.rgba.isEmpty
    ? null
    : PrintRaster(width: r.width, height: r.height, rgba: r.rgba);

/// The cells of card [card] (0-based column, left to right as drawn) for picks [pick] to
/// [pick] + [picks] - 1 of [r], or null when they are not in it.
PrintRaster? _crop(TabletRasterDto r, {required int card, required int pick, int picks = 1}) {
  final px = r.cellPx > 0 ? r.cellPx : (r.cards > 0 ? r.width ~/ r.cards : 0);
  if (px <= 0 || r.rgba.length < r.width * r.height * 4) return null;
  final x0 = card * px;
  final y0 = (r.lastPick - (pick + picks - 1)) * px;
  final w = px, h = px * picks;
  if (x0 < 0 || y0 < 0 || x0 + w > r.width || y0 + h > r.height) return null;
  final out = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    final from = ((y0 + y) * r.width + x0) * 4;
    out.setRange(y * w * 4, (y + 1) * w * 4, r.rgba, from);
  }
  return PrintRaster(width: w, height: h, rgba: out);
}

TabletCardDto _keyCard(String id, int? a, int? b, int? c, int? d) => TabletCardDto(
    id: id, a: a, b: b, c: c, d: d, threading: TabletThreadingKind.s, start: kPlyHome);

/// A small band whose turning chart has every mark the key explains: picks "FBI?" then a flip of
/// card 1 and a twist release of card 2.
final _turningKeyDoc = TabletDocumentDto(
  name: 'key',
  notes: '',
  palette: const [TabletColorDto(r: 0xf2, g: 0xef, b: 0xe6)],
  cards: [for (var i = 1; i <= 4; i++) _keyCard('k$i', 0, 0, 0, 0)],
  packs: const [],
  turning: const [
    TabletSegmentDto(repeat: 1, picks: [
      TabletPickDto(
        turns: 'FBI?',
        releaseTwist: [],
        flip: [],
        unsupported: [TabletWordsDto(card: 'k4', text: 'a key cell')],
      ),
      TabletPickDto(turns: 'FFFF', releaseTwist: ['k2'], flip: ['k1'], unsupported: []),
    ]),
  ],
  settings: kDefaultTabletSettings,
);

/// (key cell, card column, pick) in [_turningKeyDoc]'s turning chart.
const _turningKeyCells = [
  (TabletKeyCell.forward, 0, 1),
  (TabletKeyCell.backward, 1, 1),
  (TabletKeyCell.idle, 2, 1),
  (TabletKeyCell.notModelledTurn, 3, 1),
  (TabletKeyCell.flip, 0, 2),
  (TabletKeyCell.release, 1, 2),
];

/// A small band whose top face has every kind of cell the key explains (all S-threaded at Ply home):
/// card 1 forward, forward, idle (a Z slant, then a continued float); card 2 backward (an S slant);
/// card 3 forward then backward (a reversal); card 4 idle first with two colours on top (ambiguous);
/// card 5 a `?` then forward (unknown); card 6 with empty holes (no thread there).
final _faceKeyDoc = TabletDocumentDto(
  name: 'key',
  notes: '',
  palette: const [
    TabletColorDto(r: 0xf2, g: 0xef, b: 0xe6),
    TabletColorDto(r: 0x1a, g: 0x1a, b: 0x1a)
  ],
  cards: [
    _keyCard('k1', 0, 0, 0, 0),
    _keyCard('k2', 0, 0, 0, 0),
    _keyCard('k3', 0, 0, 0, 0),
    _keyCard('k4', 0, 0, 0, 1),
    _keyCard('k5', 0, 0, 0, 0),
    _keyCard('k6', null, null, null, null),
  ],
  packs: const [],
  turning: const [
    TabletSegmentDto(repeat: 1, picks: [
      TabletPickDto(
        turns: 'FBFI?F',
        releaseTwist: [],
        flip: [],
        unsupported: [TabletWordsDto(card: 'k5', text: 'a key cell')],
      ),
      TabletPickDto(turns: 'FBBFFF', releaseTwist: [], flip: [], unsupported: []),
      TabletPickDto(turns: 'IBBFFF', releaseTwist: [], flip: [], unsupported: []),
    ]),
  ],
  settings: kDefaultTabletSettings,
);

/// (key cell, card column, first pick, picks tall) in [_faceKeyDoc]'s top face.
const _faceKeyCells = [
  (TabletKeyCell.zSlant, 0, 1, 1),
  (TabletKeyCell.sSlant, 1, 1, 1),
  (TabletKeyCell.continued, 0, 2, 2),
  (TabletKeyCell.reversal, 2, 2, 1),
  (TabletKeyCell.ambiguous, 3, 1, 1),
  (TabletKeyCell.emptyHole, 5, 1, 1),
  (TabletKeyCell.unknown, 4, 2, 1),
];

// --- places and readiness ------------------------------------------------------------------------

/// "card 3", "cards 1 to 8", "cards 1, 2 and 5 to 8", "cards 1 to 32 and 10 more" (a run of three
/// or more is a range, as the engine writes it); [total] counts cards beyond those listed.
String tabletCardsText(List<int> cards, [int? total]) {
  final all = total ?? cards.length;
  final parts = <String>[];
  var i = 0;
  while (i < cards.length) {
    var j = i;
    while (j + 1 < cards.length && cards[j + 1] == cards[j] + 1) {
      j++;
    }
    if (j >= i + 2) {
      parts.add('${cards[i]} to ${cards[j]}');
    } else {
      for (var k = i; k <= j; k++) {
        parts.add('${cards[k]}');
      }
    }
    i = j + 1;
  }
  if (all > cards.length) parts.add('${_count(all - cards.length)} more');
  if (parts.isEmpty) return 'no cards';
  return '${all == 1 && cards.length == 1 ? 'card' : 'cards'} ${_and(parts)}';
}

/// Where a diagnostic is, in words: "Card 3", "Card 1, hole B", "Cards 2 and 3", "Pack 2 (Left)",
/// "Segment 2", "Segment 2, pick 1, card 4" (a written pick), "Pick 5, cards 1 to 8, top face",
/// "Card 1, hole B, top face, picks 1 to 4"; null for the whole band. With [doc], packs are named.
String? tabletPlaceText(TabletLocationDto l, {TabletDocumentDto? doc}) {
  String hole(TabletHoleKind? h) => h == null ? '?' : holeLetter(h);
  String face(TabletFaceKind f) => f == TabletFaceKind.top ? 'top face' : 'back';
  String pack(int p) {
    final name =
        doc != null && p >= 1 && p <= doc.packs.length ? _short(doc.packs[p - 1].name, 40) : '';
    return name.isEmpty ? 'Pack $p' : 'Pack $p ($name)';
  }

  return switch (l.kind) {
    TabletLocationKind.band || TabletLocationKind.omitted => null,
    TabletLocationKind.card => 'Card ${l.card}',
    TabletLocationKind.hole => 'Card ${l.card}, hole ${hole(l.hole)}',
    TabletLocationKind.cards => _capitalized(tabletCardsText(l.cards.toList(), l.cardsTotal)),
    TabletLocationKind.pack => l.pack == null ? 'A pack' : pack(l.pack!),
    TabletLocationKind.packCard => [
        'Card ${l.card}',
        if (l.packs.isNotEmpty)
          '${l.packs.length == 1 && l.packsTotal <= 1 ? 'pack' : 'packs'} '
              '${_and([
                for (final p in l.packs) '$p',
                if (l.packsTotal > l.packs.length) '${l.packsTotal - l.packs.length} more',
              ])}',
      ].join(', '),
    TabletLocationKind.segment => 'Segment ${l.segment}',
    TabletLocationKind.step => [
        'Segment ${l.segment}',
        'pick ${l.step}',
        if (l.card != null) 'card ${l.card}',
      ].join(', '),
    TabletLocationKind.pick => [
        'Pick ${l.pick}',
        if (l.cards.isNotEmpty || l.cardsTotal > 0) tabletCardsText(l.cards.toList(), l.cardsTotal),
        if (l.face != null) face(l.face!),
      ].join(', '),
    TabletLocationKind.run => [
        'Card ${l.card}',
        'hole ${hole(l.hole)}',
        if (l.face != null) face(l.face!),
        l.firstPick == l.lastPick ? 'pick ${l.firstPick}' : 'picks ${l.firstPick} to ${l.lastPick}',
      ].join(', '),
  };
}

ReadinessLevel _level(TabletSeverityKind s) => switch (s) {
      TabletSeverityKind.error => ReadinessLevel.error,
      TabletSeverityKind.warning => ReadinessLevel.warning,
      TabletSeverityKind.unsupported => ReadinessLevel.unsupported,
      TabletSeverityKind.info => ReadinessLevel.info,
    };

/// THE TABLET BAND'S READINESS (ADR 0021) until the shared readiness work (M7-05) gives bands their
/// own engine call: the band's check as a [ReadinessReport]. Structural errors block a ready PDF
/// (only a labelled draft copy is made), warnings and things Ply does not model are acknowledged in
/// one step, and information is kept as [ReadinessLevel.info], which never asks. Every item is from
/// [ReadinessCheck.band], with the engine's code, message and remediation and its place in words
/// ([tabletPlaceText]); most serious first, in the engine's order within a level.
ReadinessReport tabletReadiness(TabletReportDto report) => ReadinessReport(
      checked: const [ReadinessCheck.band],
      items: [
        for (final level in ReadinessLevel.values)
          for (final d in report.diagnostics)
            if (_level(d.severity) == level)
              ReadinessItem(
                check: ReadinessCheck.band,
                code: d.code,
                level: level,
                message: d.message,
                place: tabletPlaceText(d.location),
                remediation: d.remediation,
              ),
      ],
    );

// --- the document ----------------------------------------------------------------------------------

/// The structural errors, each with its place: what the problems box lists.
List<String> tabletPrintErrors(TabletPrintSource s) => [
      for (final d in s.report.diagnostics)
        if (d.severity == TabletSeverityKind.error) _findingText(d, s.doc),
    ];

String _findingText(TabletDiagnosticDto d, TabletDocumentDto doc) {
  final place = tabletPlaceText(d.location, doc: doc);
  return place == null ? d.message : '$place: ${d.message}';
}

/// The document for [s]. [withProblemsBox] is the user's draft-copy choice (ADR 0021): when the band
/// has structural errors, a box at the top lists them. Without errors there is never a box.
PrintDocument buildTabletPrintDocument(TabletPrintSource s, {required bool withProblemsBox}) {
  final d = s.doc;
  final fileText = _FileText();
  final errors = tabletPrintErrors(s);
  final usual = tabletUsualStart(d);
  final elsewhere = [
    for (final c in d.cards)
      if (usual != null && !sameArrangement(c.start, usual)) c,
  ];
  final title = s.name.trim().isNotEmpty
      ? s.name.trim()
      : (d.name.trim().isNotEmpty ? d.name.trim() : 'Untitled band');
  final total = s.totalPicks;

  final cautions = <PrintBlock>[
    if (s.report.reviewPending)
      const PrintNotice(
        level: PrintNoticeLevel.caution,
        title: 'Awaiting a tablet weaver\'s review',
        intro: kTabletReviewNote,
        lines: [
          'The band chart is a colour chart, not a picture of the cloth: each square is the colour '
              'of the thread that shows for one card at one pick. It does not show the weft, the '
              'width of the cords or how the band draws in.',
        ],
      ),
    if (s.hasErrors)
      PrintNotice(
        level: PrintNoticeLevel.problem,
        title: 'No charts can be drawn yet',
        intro: 'Ply found ${_n(s.report.errors, 'structural error', 'structural errors')} in this '
            'band (listed under Checks), so it cannot work out the turning chart, the band chart or '
            'the working instructions. They are missing from this PDF until the errors are fixed. '
            'The setup and the turning as written are printed from the band as it is.',
      ),
  ];

  return PrintDocument(
    title: title,
    kind: 'Tablet weaving band',
    titleFacts: [
      PrintFact('Printed', _isoDate(s.printedAt)),
      PrintFact('Cards', _count(d.cards.length)),
      PrintFact('Picks',
          total > kMaxTabletPicks ? 'more than ${_count(kMaxTabletPicks)}' : _count(total)),
      PrintFact('Packs', d.packs.isEmpty ? 'None' : _count(d.packs.length)),
      if (usual != null)
        PrintFact(
          'Start',
          elsewhere.isEmpty
              ? startWords(usual)
              : '${startWords(usual)} (${_n(elsewhere.length, 'card starts', 'cards start')} '
                  'elsewhere)',
        ),
    ],
    problemsBox: withProblemsBox && errors.isNotEmpty
        ? PrintNotice(
            level: PrintNoticeLevel.problem,
            title: 'This band has problems',
            intro: 'Ply found ${_n(errors.length, 'error', 'errors')} in this band, so it cannot '
                'draw the charts or write the working instructions. Fix '
                '${errors.length == 1 ? 'it' : 'them'} before you weave from it; Checks at the end '
                'lists every finding.',
            lines: errors,
          )
        : null,
    sections: [
      if (cautions.isNotEmpty) PrintSection('Before you weave', cautions),
      if (d.notes.trim().isNotEmpty) PrintSection('Notes', [PrintParagraph(d.notes.trim())]),
      PrintSection('Setup', _setupBlocks(d, usual, elsewhere)),
      PrintSection('Turning chart', _turningBlocks(s, fileText)),
      PrintSection('Band chart', _bandBlocks(s)),
      PrintSection('Working instructions', _instructionBlocks(s, fileText)),
      PrintSection('Checks', _checkBlocks(s)),
    ],
  );
}

/// The start most cards have (the one met first, card 1 onwards, when they tie), or null for a band
/// with no cards: [usualStart], which the editor's chart uses too.
TabletArrangementDto? tabletUsualStart(TabletDocumentDto d) => usualStart(d);

// --- setup -----------------------------------------------------------------------------------------

List<PrintBlock> _setupBlocks(
    TabletDocumentDto d, TabletArrangementDto? usual, List<TabletCardDto> elsewhere) {
  final number = {for (var i = 0; i < d.cards.length; i++) d.cards[i].id: i + 1};
  List<int> numbers(Iterable<String> ids) => [
        for (final id in ids)
          if (number[id] != null) number[id]!,
      ]..sort();
  final s = [
    for (var i = 0; i < d.cards.length; i++)
      if (d.cards[i].threading == TabletThreadingKind.s) i + 1
  ];
  final z = [
    for (var i = 0; i < d.cards.length; i++)
      if (d.cards[i].threading == TabletThreadingKind.z) i + 1
  ];
  final blocks = <PrintBlock>[
    PrintFacts([
      PrintFact('Cards', d.cards.isEmpty ? 'None yet' : _count(d.cards.length)),
      if (s.isNotEmpty) PrintFact('S-threaded', _capitalized(_cardsUpTo(s))),
      if (z.isNotEmpty) PrintFact('Z-threaded', _capitalized(_cardsUpTo(z))),
      PrintFact('Weft', d.weft == null ? 'Not stated' : _colorWords(d, d.weft!)),
      if (usual != null) PrintFact('Usual start', startWords(usual)),
    ]),
  ];
  if (d.cards.isEmpty) {
    blocks.add(const PrintParagraph('This band has no cards yet.'));
    return blocks;
  }

  // The threading chart.
  blocks
    ..add(const PrintParagraph('Threading chart', style: PrintTextStyle.strong))
    ..add(const PrintParagraph(
      'One column per card, card 1 at the left. One row per hole, A at the bottom to D at the top; '
      'each square gives the colour code of the thread in that hole (see the colour key), and "-" '
      'an empty hole. Below them, the threading (S or Z, see the threading legend) and the start: '
      'the hole at the near top (NT) when the cards are set up. A * marks a card that starts in '
      'another position (see Start positions).',
      style: PrintTextStyle.muted,
    ));
  for (var from = 0; from < d.cards.length; from += _cardsPerStrip) {
    final to = math.min(d.cards.length, from + _cardsPerStrip);
    blocks.add(threadingDrawing(d, from, to, usual: usual));
  }

  // The colour key.
  blocks
    ..add(const PrintParagraph('Colour key', style: PrintTextStyle.strong))
    ..add(PrintLegend(_colorEntries(d)));

  // Start positions.
  blocks.add(const PrintParagraph('Start positions', style: PrintTextStyle.strong));
  if (usual != null) {
    final p = presetOf(usual);
    // A named preset carries its own description (which spells out the corners); any other start
    // is spelled out here.
    final how = p != null && p.quarters == 0
        ? '. ${p.preset.description}'
        : ': ${arrangementWords(usual)}.';
    blocks.add(PrintParagraph(
      '${elsewhere.isEmpty ? 'Every card starts' : 'Cards start'} at "${startWords(usual)}"$how'
      '${elsewhere.isEmpty ? '' : ' These cards start in another position:'}',
    ));
    if (elsewhere.isNotEmpty) {
      blocks.add(PrintLines([
        for (final c in elsewhere)
          PrintLine('${arrangementWords(c.start)}${_startAside(c.start)}.',
              label: 'Card ${number[c.id]}'),
      ]));
    }
    blocks.add(cardDiagram(usual));
  }

  // The threading legend.
  blocks
    ..add(const PrintParagraph('Threading S and Z', style: PrintTextStyle.strong))
    ..add(threadingLegend());

  // Packs.
  blocks.add(const PrintParagraph('Packs', style: PrintTextStyle.strong));
  if (d.packs.isEmpty) {
    blocks
        .add(const PrintParagraph('No packs: the working instructions name the cards by number.'));
  } else {
    final packed = <String>{for (final p in d.packs) ...p.cards};
    final loose = [
      for (var i = 0; i < d.cards.length; i++)
        if (!packed.contains(d.cards[i].id)) i + 1
    ];
    blocks.add(PrintFacts([
      for (final (i, p) in d.packs.indexed)
        PrintFact(
          p.name.trim().isEmpty ? 'Pack ${i + 1}' : _short(p.name),
          [
            numbers(p.cards).isEmpty ? 'No cards' : _capitalized(_cardsUpTo(numbers(p.cards))),
            if (p.cards.any((id) => number[id] == null)) 'and a card that is not in the band',
          ].join(', '),
        ),
      if (loose.isNotEmpty) PrintFact('In no pack', _capitalized(_cardsUpTo(loose))),
    ]));
  }
  return blocks;
}

/// How a start relates to the presets: '; that is, the start "Printed face to the right, D at the
/// near top"', '; that is, 1 quarter turn forward from "A at the near top"', or why it is not one a
/// card can take.
String _startAside(TabletArrangementDto a) {
  final p = presetOf(a);
  if (p == null) return ' (${startWords(a)})';
  return p.quarters == 0
      ? '; that is, the start "${p.preset.label}"'
      : '; that is, ${startWords(a)}';
}

/// "Colour 2 (#F2EFE6)", or words for an index the palette lacks.
String _colorWords(TabletDocumentDto d, int i) => i >= 0 && i < d.palette.length
    ? 'Colour ${i + 1} (${_printColor(d.palette[i]).hex})'
    : 'Colour ${i + 1}, which is not in the band\'s palette';

PrintColor _printColor(TabletColorDto c) => PrintColor(c.r, c.g, c.b);

/// The code a hole's thread has on the threading chart: its palette number, or "-" for none.
String tabletColorCode(int? i) => i == null ? '-' : '${i + 1}';

List<PrintLegendEntry> _colorEntries(TabletDocumentDto d) {
  final holes = <int?, int>{};
  for (final c in d.cards) {
    for (final h in TabletHoleKind.values) {
      final i = holeColor(c, h);
      holes[i] = (holes[i] ?? 0) + 1;
    }
  }
  return [
    for (var i = 0; i < d.palette.length; i++)
      PrintLegendEntry(
        code: tabletColorCode(i),
        name: 'Colour ${i + 1}',
        meaning: '${_printColor(d.palette[i]).hex}. '
            '${holes[i] == null ? 'Not threaded in any hole.' : 'Threaded in ${_n(holes[i]!, 'hole', 'holes')}.'}',
        swatch: _printColor(d.palette[i]),
        notes: [if (d.weft == i) 'The weft is this colour.'],
      ),
    for (final i in holes.keys)
      if (i != null && (i < 0 || i >= d.palette.length))
        PrintLegendEntry(
          code: tabletColorCode(i),
          name: 'Colour ${i + 1}',
          meaning: 'Not in the band\'s palette (see Checks). Threaded in '
              '${_n(holes[i]!, 'hole', 'holes')}.',
        ),
    if (holes[null] != null)
      PrintLegendEntry(
        code: '-',
        name: 'Empty hole',
        meaning: 'No thread in this hole (${_n(holes[null]!, 'hole', 'holes')}).',
      ),
  ];
}

/// Cards per strip of the threading chart: as many as fit the narrowest page Ply prints on.
const int _cardsPerStrip = 24;
const double _labelW = 64;
const double _cellW = 18;
const double _rowH = 16;

/// Rough advance of a text run in the print font, to centre short labels.
double _textWidth(String s, double size) => s.length * size * 0.56;

/// The threading chart of cards [from] to [to] (0-based, [to] exclusive) as a vector drawing (ADR
/// 0018 section 8): a header row of card numbers; rows D at the top down to A, each labelled with
/// its letter, giving each hole's colour code; then the threading (S or Z) and the start (the hole
/// at the near top; "*" when the card's start is not [usual]).
PrintDrawing threadingDrawing(TabletDocumentDto d, int from, int to,
    {TabletArrangementDto? usual}) {
  final n = to - from;
  final right = _labelW + n * _cellW;
  final shapes = <PrintShape>[];
  void label(int row, String text, {double size = 9}) =>
      shapes.add(PrintVectorText(4, row * _rowH + (_rowH - size) / 2, text, size: size));
  void cell(int row, int col, String text, {double size = 9}) => shapes.add(PrintVectorText(
        _labelW + (col + 0.5) * _cellW - _textWidth(text, size) / 2,
        row * _rowH + (_rowH - size) / 2,
        text,
        size: size,
      ));

  // Row 0: card numbers.
  label(0, 'Card', size: 8);
  for (var c = 0; c < n; c++) {
    cell(0, c, '${from + c + 1}', size: 7.5);
  }
  // Rows 1 to 4: holes D, C, B, A (A at the bottom).
  const holes = [TabletHoleKind.d, TabletHoleKind.c, TabletHoleKind.b, TabletHoleKind.a];
  for (final (r, h) in holes.indexed) {
    label(r + 1, holeLetter(h));
    for (var c = 0; c < n; c++) {
      cell(r + 1, c, tabletColorCode(holeColor(d.cards[from + c], h)));
    }
  }
  // Row 5: threading; row 6: the start.
  label(5, 'Threading', size: 8);
  label(6, 'Start (NT)', size: 8);
  for (var c = 0; c < n; c++) {
    final card = d.cards[from + c];
    cell(5, c, threadingLetter(card.threading));
    final other = usual != null && !sameArrangement(card.start, usual);
    cell(6, c, '${holeLetter(card.start.nearTop)}${other ? '*' : ''}');
  }

  // The grid: faint cell lines, a strong frame and a strong rule under the holes.
  for (var r = 2; r < 7; r++) {
    if (r == 5) continue;
    shapes.add(PrintVectorLine(_labelW, r * _rowH, right, r * _rowH, PrintInk.faint));
  }
  for (var c = 1; c < n; c++) {
    final x = _labelW + c * _cellW;
    shapes.add(PrintVectorLine(x, _rowH, x, 7 * _rowH, PrintInk.faint));
  }
  shapes.addAll([
    PrintVectorLine(_labelW, _rowH, right, _rowH, PrintInk.strong),
    PrintVectorLine(_labelW, 5 * _rowH, right, 5 * _rowH, PrintInk.strong),
    PrintVectorLine(_labelW, 7 * _rowH, right, 7 * _rowH, PrintInk.strong),
    const PrintVectorLine(_labelW, _rowH, _labelW, 7 * _rowH, PrintInk.strong),
    PrintVectorLine(right, _rowH, right, 7 * _rowH, PrintInk.strong),
  ]);
  return PrintDrawing(
    width: right + 2,
    height: 7 * _rowH + 2,
    shapes: shapes,
    caption: 'Threading chart, ${tabletCardsText([for (var i = from; i < to; i++) i + 1])}.',
  );
}

/// The section 2 card diagram at [a]: one card seen from the weaver's right, the band and the weaver
/// at the left and the far end at the right, each corner with its name and hole letter, and a
/// clockwise arrow for a forward turn.
PrintDrawing cardDiagram(TabletArrangementDto a) {
  const left = 104.0, right = 244.0, top = 36.0, bottom = 106.0;
  const cx = (left + right) / 2, cy = (top + bottom) / 2;
  final shapes = <PrintShape>[
    const PrintVectorLine(left, top, right, top, PrintInk.strong),
    const PrintVectorLine(right, top, right, bottom, PrintInk.strong),
    const PrintVectorLine(right, bottom, left, bottom, PrintInk.strong),
    const PrintVectorLine(left, bottom, left, top, PrintInk.strong),
  ];
  final corners = [
    ('NT', a.nearTop, left, top),
    ('FT', a.farTop, right, top),
    ('FB', a.farBottom, right, bottom),
    ('NB', a.nearBottom, left, bottom),
  ];
  for (final (name, hole, x, y) in corners) {
    shapes.add(PrintVectorArc(x, y, 4, 4, 0, 2 * math.pi, PrintInk.strong));
    final isLeft = x == left, isTop = y == top;
    final ty = isTop ? y - 20 : y + 6;
    shapes
      ..add(PrintVectorText(isLeft ? x - 20 : x + 9, ty, holeLetter(hole), size: 13))
      ..add(PrintVectorText(isLeft ? x - 42 : x + 25, ty + 4, name, size: 8));
  }
  // The forward turn: a clockwise arc over the top, its head at the far end.
  const rx = 42.0, ry = 20.0, start = -2.6, sweep = 2.2;
  shapes.add(const PrintVectorArc(cx, cy, rx, ry, start, sweep, PrintInk.highlight));
  const t = start + sweep;
  final ex = cx + rx * math.cos(t), ey = cy + ry * math.sin(t);
  final tx = -rx * math.sin(t), ty = ry * math.cos(t);
  final len = math.sqrt(tx * tx + ty * ty);
  final ux = tx / len, uy = ty / len;
  for (final turn in const [0.5, -0.5]) {
    final hx = ux * math.cos(turn) - uy * math.sin(turn);
    final hy = ux * math.sin(turn) + uy * math.cos(turn);
    shapes.add(PrintVectorLine(ex, ey, ex - 7 * hx, ey - 7 * hy, PrintInk.highlight));
  }
  shapes
    ..add(const PrintVectorText(cx - 15, cy + 2, 'forward', size: 8))
    ..add(const PrintVectorText(0, cy - 10, 'near end', size: 8))
    ..add(const PrintVectorText(0, cy + 1, '(band, weaver)', size: 8))
    ..add(const PrintVectorText(right + 44, cy - 5, 'far end', size: 8));
  return PrintDrawing(
    width: right + 80,
    height: bottom + 24,
    shapes: shapes,
    caption:
        'One card seen from the weaver\'s right, at "${startWords(a)}": the band and the weaver '
        'at the left, the far end at the right. NT is the near top, FT the far top, FB the far '
        'bottom and NB the near bottom; the letters are the holes there. A forward turn moves the '
        'top edge away from the weaver: clockwise in this view, NT to FT to FB to NB. A backward '
        'turn is the reverse.',
  );
}

/// The section 3 threading legend: one card seen from above, S-threaded and Z-threaded.
PrintDrawing threadingLegend() {
  final shapes = <PrintShape>[];
  for (final (i, z) in const [(0, false), (1, true)]) {
    final x0 = i * 150.0, cx = x0 + 60;
    shapes
      ..add(PrintVectorText(x0 + 30, 0, z ? 'Z-threaded' : 'S-threaded', size: 10))
      ..add(PrintVectorText(cx - 6, 16, 'far', size: 8))
      ..add(PrintVectorText(cx - 26, 114, 'near (weaver)', size: 8));
    // The card standing on edge, dotted, with its hole.
    for (var y = 30.0; y < 110; y += 7) {
      shapes.add(PrintVectorLine(cx, y, cx, math.min(110, y + 3.5), PrintInk.strong));
    }
    shapes
      ..add(PrintVectorArc(cx, 70, 3.5, 3.5, 0, 2 * math.pi, PrintInk.strong))
      // One warp thread through the hole: S like the middle stroke of an S, Z its mirror.
      ..add(z
          ? PrintVectorLine(cx + 36, 30, cx - 36, 110, PrintInk.accent)
          : PrintVectorLine(cx - 36, 30, cx + 36, 110, PrintInk.accent));
  }
  return PrintDrawing(
    width: 290,
    height: 128,
    shapes: shapes,
    caption: 'One card seen from above, the weaver at the bottom and the warp running up the page; '
        'the dotted line is the card standing on edge and the slanted line one warp thread through '
        'its hole. S-threaded: on the band side the threads lie along the card\'s face that points '
        'to the weaver\'s right, and on the far side along the face that points left. Z-threaded: '
        'the mirror. A flip changes S to Z and back.',
  );
}

// --- the turning chart and the band chart ----------------------------------------------------------

String? _missingCharts(TabletPrintSource s) {
  if (s.hasErrors) return null;
  if (s.doc.cards.isEmpty) return 'This band has no cards yet, so there is nothing to chart.';
  if (s.totalPicks == 0) return 'This band has no picks yet, so there is nothing to chart.';
  return null;
}

/// The notice for a band charted only in part, or null when every pick is charted.
PrintNotice? _partNotice(TabletPrintSource s) {
  final total = s.totalPicks;
  if (s.chartedPicks <= 0 || s.chartedPicks >= total) return null;
  final ins = s.instructions;
  final covered = ins != null && ins.omitted == 0
      ? 'The working instructions cover every pick.'
      : (ins != null && ins.lines.isNotEmpty
          ? 'The working instructions are printed up to pick ${_count(ins.lines.map((l) => l.lastPick).reduce(math.max))}.'
          : 'The working instructions are not printed either.');
  return PrintNotice(
    level: PrintNoticeLevel.caution,
    title: 'Picks 1 to ${_count(s.chartedPicks)} of ${_count(total)} are charted',
    intro: 'The rest are not charted, to keep the PDF to a size a phone can make. $covered',
  );
}

List<PrintBlock> _chartUnavailable(TabletPrintSource s, String what) {
  final missing = _missingCharts(s);
  if (missing != null) return [PrintParagraph(missing)];
  if (s.hasErrors) {
    return [
      PrintNotice(
        level: PrintNoticeLevel.problem,
        title: 'The $what is missing',
        intro: 'It cannot be drawn until the band\'s '
            '${s.report.errors == 1 ? 'structural error is' : 'structural errors are'} fixed '
            '(see Checks).',
      ),
    ];
  }
  return [
    PrintNotice(
      level: PrintNoticeLevel.caution,
      title: 'The $what could not be drawn',
      intro: '${s.chartFailure == null ? '' : '${_sentence(s.chartFailure!)}. '}'
          'The working instructions describe every pick.',
    ),
  ];
}

PrintChart _chart(TabletPrintSource s, PrintRaster raster, {required bool reversed}) {
  final cards = s.doc.cards.length, rows = s.chartedPicks;
  return PrintChart(
    raster: raster,
    columns: cards,
    rows: rows,
    columnNumbers: [for (var i = 0; i < cards; i++) reversed ? cards - i : i + 1],
    rowNumbers: [for (var r = 0; r < rows; r++) r + 1],
    rowNumberSides: [for (var r = 0; r < rows; r++) PrintSide.left],
    // The back has card 1 at the right: a chart split across pages starts there.
    startAtRight: reversed,
    rowsName: 'Picks',
    columnsName: 'cards',
  );
}

PrintLegendEntry _key(TabletPrintSource s, TabletKeyCell cell,
        {required String code, required String name, required String meaning}) =>
    PrintLegendEntry(code: code, name: name, meaning: meaning, glyph: s.keys[cell]);

List<PrintBlock> _turningBlocks(TabletPrintSource s, _FileText fileText) {
  final raster = s.turning;
  if (raster == null || s.chartedPicks <= 0) {
    return [
      ..._chartUnavailable(s, 'turning chart'),
      if (s.hasErrors) ..._wordsBlocks(s.doc, fileText),
    ];
  }
  final part = _partNotice(s);
  return [
    const PrintParagraph('Read from the bottom up: pick 1 is the bottom row and card 1 the left '
        'column. Each square says what that card does for the pick; a mark along the foot of a '
        'square is something done before the pick.'),
    if (part != null) part,
    PrintLegend([
      _key(s, TabletKeyCell.forward,
          code: 'F',
          name: 'Forward',
          meaning: 'Turn the card a quarter turn forward: its top edge moves away from you '
              '(clockwise in the card diagram).'),
      _key(s, TabletKeyCell.backward,
          code: 'B',
          name: 'Backward',
          meaning: 'A quarter turn backward: the top edge moves toward you.'),
      _key(s, TabletKeyCell.idle,
          code: 'I', name: 'Idle', meaning: 'Do not turn the card for this pick.'),
      _key(s, TabletKeyCell.notModelledTurn,
          code: '?',
          name: 'Not modelled',
          meaning: 'Something Ply does not model, in the pattern\'s own words (listed below). Ply '
              'treats that card as unknown from that pick on.'),
      _key(s, TabletKeyCell.flip,
          code: 'Flip',
          name: 'Flip before the pick',
          meaning:
              'A thick dashed line along the foot of a square: before the pick, flip that card '
              '(turn it half way round its upright axis). It changes from S to Z threading or back.'),
      _key(s, TabletKeyCell.release,
          code: 'Release',
          name: 'Twist released before the pick',
          meaning: 'A dotted line along the foot of a square: before the pick, the twist behind '
              'that card is removed, and its twist count starts again at 0.'),
    ]),
    ..._wordsBlocks(s.doc, fileText),
    _chart(s, raster, reversed: false),
  ];
}

/// The pattern's own words for every `?` and every note on a pick, by written pick, within the
/// shared [fileText] budget (the rest counted); words and ids quoted in short.
List<PrintBlock> _wordsBlocks(TabletDocumentDto d, _FileText fileText) {
  final number = {for (var i = 0; i < d.cards.length; i++) d.cards[i].id: i + 1};
  final words = <PrintLine>[];
  final notes = <PrintLine>[];
  var moreWords = 0, moreNotes = 0;
  for (final (si, seg) in d.turning.indexed) {
    for (final (pi, p) in seg.picks.indexed) {
      final where = 'Segment ${si + 1}, pick ${pi + 1}';
      for (final w in p.unsupported) {
        final c = number[w.card];
        final line = PrintLine(_short(w.text),
            label: '$where, ${c == null ? 'card "${_short(w.card, 40)}"' : 'card $c'}');
        if (fileText.take(line)) {
          words.add(line);
        } else {
          moreWords++;
        }
      }
      final note = p.note;
      if (note != null && note.text.trim().isNotEmpty) {
        final line = PrintLine(_short(note.text, 200),
            label: '$where${note.kind == TabletNoteKind.brocade ? ' (brocade)' : ''}');
        if (fileText.take(line)) {
          notes.add(line);
        } else {
          moreNotes++;
        }
      }
    }
  }
  return [
    if (words.isNotEmpty || moreWords > 0) ...[
      const PrintParagraph('In the pattern\'s own words (not modelled by Ply)',
          style: PrintTextStyle.strong),
      if (words.isNotEmpty) PrintLines(words),
      if (moreWords > 0)
        PrintParagraph('${_n(moreWords, 'more card marked ? is', 'more cards marked ? are')} not '
            'listed, to keep the PDF to a size a phone can make; the band in Ply has them all.'),
    ],
    if (notes.isNotEmpty || moreNotes > 0) ...[
      const PrintParagraph('Notes on picks (not drawn on the charts)',
          style: PrintTextStyle.strong),
      if (notes.isNotEmpty) PrintLines(notes),
      if (moreNotes > 0)
        PrintParagraph('${_n(moreNotes, 'more note is', 'more notes are')} not listed, to keep the '
            'PDF to a size a phone can make; the band in Ply has them all.'),
    ],
  ];
}

List<PrintBlock> _bandBlocks(TabletPrintSource s) {
  final top = s.top, back = s.back;
  if (top == null || back == null || s.chartedPicks <= 0) return _chartUnavailable(s, 'band chart');
  final part = _partNotice(s);
  return [
    const PrintParagraph('A colour chart, not a picture of the cloth: each square is the colour of '
        'the thread that shows on that face for one card at one pick, drawn with the slant of its '
        'stitch. It does not show the weft, the width of the cords or how the band draws in. Pick 1 '
        'is at the bottom.'),
    if (part != null) part,
    PrintLegend([
      _key(s, TabletKeyCell.zSlant,
          code: 'Z',
          name: 'Z twining',
          meaning: 'A stitch slanting like /: an S-threaded card turned forward, or a Z-threaded '
              'card turned backward.'),
      _key(s, TabletKeyCell.sSlant,
          code: 'S',
          name: 'S twining',
          meaning: 'A stitch slanting like \\: an S-threaded card turned backward, or a Z-threaded '
              'card turned forward.'),
      _key(s, TabletKeyCell.continued,
          code: 'Float',
          name: 'Continued float',
          meaning: 'No slant and no line below: the card idled, so the same thread floats on over '
              'this pick.'),
      _key(s, TabletKeyCell.reversal,
          code: 'Reversal',
          name: 'Reversal',
          meaning: 'A black line with a white edge under a square: the twining changes direction '
              'there. The same colour shows twice and that thread floats over three picks.'),
      _key(s, TabletKeyCell.ambiguous,
          code: 'Either',
          name: 'Cannot tell which thread shows',
          meaning: 'Two halves with a mark: the card idled before it had turned (at the start, or '
              'right after a flip), so either thread may show.'),
      _key(s, TabletKeyCell.emptyHole,
          code: 'No thread',
          name: 'Not modelled',
          meaning: 'Hatched: the hole that crossed has no thread, so Ply cannot say what shows '
              'there (the weft or another thread may).'),
      _key(s, TabletKeyCell.unknown,
          code: 'Unknown',
          name: 'Unknown',
          meaning: 'Cross-hatched: after something Ply does not model, the card\'s position is '
              'unknown for the rest of the band.'),
      const PrintLegendEntry(
        code: 'A to D',
        name: 'Hole letters',
        meaning:
            'Each square carries the letter of the hole whose thread shows there, so the chart '
            'does not rely on colour alone.',
      ),
    ]),
    const PrintParagraph('Top face', style: PrintTextStyle.strong),
    const PrintParagraph('As you see it from your seat: card 1 at the left, pick 1 at the bottom.',
        style: PrintTextStyle.muted),
    _chart(s, top, reversed: false),
    const PrintParagraph('Back', style: PrintTextStyle.strong),
    const PrintParagraph(
        'As you see it after turning the band over sideways: card 1 at the right, pick 1 at the '
        'bottom. A twined cord has the same slant from either side.',
        style: PrintTextStyle.muted),
    _chart(s, back, reversed: true),
  ];
}

// --- working instructions and checks ---------------------------------------------------------------

/// How the twist numbers of the ledger read.
const String kTabletTwistNote = 'Twist is counted in quarter turns of twining since the start of '
    'the band or the card\'s last twist release: Z twining counts plus and S twining minus, and four '
    'quarter turns make one full turn. The warp behind the cards holds the same amount of twist of '
    'the opposite hand.';

List<PrintBlock> _instructionBlocks(TabletPrintSource s, _FileText fileText) {
  final ins = s.instructions;
  if (ins == null) {
    if (s.hasErrors) {
      return [
        PrintNotice(
          level: PrintNoticeLevel.problem,
          title: 'The working instructions are missing',
          intro:
              'Ply writes them only for a band without structural errors. They are missing until '
              'the ${s.report.errors == 1 ? 'error is' : 'errors are'} fixed (see Checks). The '
              'turning as written in the band follows, as it is, unchecked.',
        ),
        ..._writtenTurning(s.doc, fileText),
      ];
    }
    final missing = _missingCharts(s);
    if (missing != null) return [PrintParagraph(missing)];
    return [
      PrintNotice(
        level: PrintNoticeLevel.caution,
        title: 'The working instructions could not be written',
        intro: s.instructionsFailure == null ? null : '${_sentence(s.instructionsFailure!)}.',
      ),
    ];
  }
  final lastPick = ins.lines.isEmpty ? 0 : ins.lines.map((l) => l.lastPick).reduce(math.max);
  return [
    const PrintParagraph(
      'One line per pick, or per block of picks worked several times, naming the packs and cards '
      'and what to do before a pick. After each segment of the turning, the twist line gives each '
      'card\'s twist. $kTabletTwistNote',
      style: PrintTextStyle.muted,
    ),
    if (ins.lines.isEmpty)
      const PrintParagraph('There are no working instructions: the band has no picks yet.')
    else
      PrintLines([for (final l in ins.lines) PrintLine(l.text, label: l.label)]),
    if (ins.omitted > 0)
      PrintNotice(
        level: PrintNoticeLevel.caution,
        title: 'Not every line is printed',
        intro: 'This PDF prints the first ${_n(ins.lines.length, 'line', 'lines')} of the working '
            'instructions, up to pick ${_count(lastPick)}; the other '
            '${_n(ins.omitted, 'line is', 'lines are')} left out to keep the PDF to a size a phone '
            'can make.',
      ),
  ];
}

/// The turning exactly as written in the band (a band with errors cannot be expanded or checked),
/// segment by segment: each written pick's letters in groups of four, and its events, within the
/// shared [fileText] budget (the rest counted). Events and words name at most
/// [kTabletPrintMaxCardsPerLine] cards each, and quote ids and words in short.
List<PrintBlock> _writtenTurning(TabletDocumentDto d, _FileText fileText) {
  if (d.turning.isEmpty) return const [PrintParagraph('The band has no turning written yet.')];
  final number = {for (var i = 0; i < d.cards.length; i++) d.cards[i].id: i + 1};
  String card(String id) => number[id] == null ? 'card "${_short(id, 40)}"' : 'card ${number[id]}';
  final blocks = <PrintBlock>[];
  var hidden = 0;
  for (final (si, seg) in d.turning.indexed) {
    final lines = <PrintLine>[];
    for (final (pi, p) in seg.picks.indexed) {
      if (hidden > 0) {
        hidden++;
        continue;
      }
      final events = [
        if (p.releaseTwist.isNotEmpty)
          'release the twist behind ${_cardsNamed(p.releaseTwist, number)}',
        if (p.flip.isNotEmpty) 'flip ${_cardsNamed(p.flip, number)}',
      ];
      final shown = p.unsupported.take(kTabletPrintMaxCardsPerLine);
      final words = [
        for (final w in shown) '${card(w.card)}: "${_short(w.text)}"',
        if (p.unsupported.length > kTabletPrintMaxCardsPerLine)
          '${_count(p.unsupported.length - kTabletPrintMaxCardsPerLine)} more',
      ];
      final line = PrintLine(
        [
          if (events.isNotEmpty) 'Before the pick: ${events.join('; ')}.',
          _grouped(p.turns),
          if (words.isNotEmpty) '(? ${words.join('; ')})',
        ].join(' '),
        label: 'Pick ${pi + 1}',
      );
      if (fileText.take(line)) {
        lines.add(line);
      } else {
        hidden++;
      }
    }
    if (lines.isEmpty) continue;
    blocks
      ..add(PrintParagraph(
          'Segment ${si + 1}${seg.repeat == 1 ? '' : ', worked ${_count(seg.repeat)} times'}',
          style: PrintTextStyle.strong))
      ..add(PrintLines(lines));
  }
  if (hidden > 0) {
    blocks.add(PrintParagraph('${_n(hidden, 'more written pick is', 'more written picks are')} not '
        'printed, to keep the PDF to a size a phone can make; the band in Ply has them all.'));
  }
  return blocks;
}

/// Turn letters in groups of four, card 1 first: "FFFF BBBB".
String _grouped(String turns) {
  final r = turns.runes.map(String.fromCharCode).toList();
  if (r.isEmpty) return '(no letters)';
  return [
    for (var i = 0; i < r.length; i += 4) r.sublist(i, math.min(r.length, i + 4)).join(),
  ].join(' ');
}

PrintIssueSeverity _issueSeverity(TabletSeverityKind k) => switch (k) {
      TabletSeverityKind.error => PrintIssueSeverity.error,
      TabletSeverityKind.warning => PrintIssueSeverity.warning,
      TabletSeverityKind.unsupported => PrintIssueSeverity.notChecked,
      TabletSeverityKind.info => PrintIssueSeverity.note,
    };

List<PrintBlock> _checkBlocks(TabletPrintSource s) {
  final r = s.report;
  final notes = [
    for (final d in r.diagnostics)
      if (d.severity == TabletSeverityKind.info) d
  ];
  final listNotes = notes.length <= kTabletPrintMaxNotes;
  PrintIssue issue(TabletDiagnosticDto d) => PrintIssue(
        severity: _issueSeverity(d.severity),
        where: tabletPlaceText(d.location, doc: s.doc) ?? 'Whole band',
        message: [d.message, if (d.remediation?.trim().isNotEmpty ?? false) d.remediation!.trim()]
            .join(' '),
      );
  final issues = [
    for (final sev in const [
      TabletSeverityKind.error,
      TabletSeverityKind.warning,
      TabletSeverityKind.unsupported,
      TabletSeverityKind.info,
    ])
      if (sev != TabletSeverityKind.info || listNotes)
        for (final d in r.diagnostics)
          if (d.severity == sev) issue(d),
  ];
  return [
    const PrintParagraph(
      'Every finding of Ply\'s check of this band: errors, warnings, and things Ply does not model '
      '("Not checked"), then notes. Picks are counted with every repeat written out; "Segment 2, '
      'pick 1" is the first written pick of segment 2.',
      style: PrintTextStyle.muted,
    ),
    PrintIssues(issues, emptyText: 'Ply found no problems in this band.'),
    if (!listNotes)
      PrintParagraph('Ply also made ${_n(math.max(r.infos, notes.length), 'note', 'notes')} about '
          'this band (such as reversals, flips and faces it cannot tell apart). They change nothing '
          'about how the band is woven, so they are not listed here; the Checks tab of the editor '
          'shows them.'),
  ];
}

// --- the flow --------------------------------------------------------------------------------------

/// Run the print-or-share flow for the tablet editor's open band, shown as [name]: the band's
/// readiness ([tabletReadiness], ADR 0021) decides whether it prints straight away, after an
/// acknowledgement, or only as a draft copy. The shared flow does the asking.
Future<void> printOrShareTabletPdf(BuildContext context, WidgetRef ref, {required String name}) {
  // Read everything from providers now: the flow has async gaps, and the screen may be gone after.
  final repo = ref.read(tabletRepositoryProvider);
  final doc = ref.read(tabletDocProvider);
  return printOrSharePdf(
    context,
    ref,
    noun: 'band',
    prepare: () async {
      final source = await gatherTabletPrint(repo, name: name, doc: doc);
      return PdfExportJob(
        fileStem: name.trim().isEmpty ? 'band' : name,
        readiness: tabletReadiness(source.report),
        document: ({required withProblemsBox}) =>
            buildTabletPrintDocument(source, withProblemsBox: withProblemsBox),
      );
    },
  );
}

// --- helpers ---------------------------------------------------------------------------------------

/// The local date as YYYY-MM-DD.
String _isoDate(DateTime d) {
  String two(int v) => v.toString().padLeft(2, '0');
  final l = d.toLocal();
  return '${l.year}-${two(l.month)}-${two(l.day)}';
}

/// [n] with thousands separators: "1,365".
String _count(int n) {
  final s = n.abs().toString();
  final out = StringBuffer(n < 0 ? '-' : '');
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) out.write(',');
    out.write(s[i]);
  }
  return out.toString();
}

String _n(int n, String one, String many) => '${_count(n)} ${n == 1 ? one : many}';

String _and(List<String> items) => items.length <= 1
    ? items.join()
    : '${items.sublist(0, items.length - 1).join(', ')} and ${items.last}';

String _capitalized(String s) => s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

/// [s] as a sentence start, without a trailing full stop (the caller adds one).
String _sentence(String s) {
  final t = s.trim().replaceFirst(RegExp(r'\.+$'), '');
  return _capitalized(t);
}
