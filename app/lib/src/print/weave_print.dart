// The printable WEAVING draft (M9-02, ADR 0012): what the PDF says, built from the draft open in the
// editor (unsaved edits included) and the engine's own interlacement, colors and validation.
// [gatherWeavePrint] makes the engine calls once; [buildWeavePrintDocument] is pure, so every printed
// word is host-testable.
//
// The PDF holds, in order: notes; the source the file credits; materials (counts, the color key, the
// warp and weft color orders); the four-quadrant BOOK DRAFT in the chosen layout, with its reading
// directions in words and a key for every mark; the traditional "Use tabby" presentation when the
// draft's pick roles make it exact; the colored drawdown; written directions for the threading, the
// tie-up and the treadling (or lift plan) that work without the grids; and the problems, with what the
// PDF cannot show exactly. Annotations appear only where the model knows them (roles, shot groups,
// shuttles and derived pass directions, a construction confirmed by the derived edges); unknown data
// is printed as unknown or left out with a note, never guessed.
//
// The structural drawdown is the engine's: the draft is rendered at one pixel per crossing with the
// warp drawn black and the weft white, so `Draft::raised_shafts` stays the single source of shed
// logic. The colored drawdown is the engine's uniform render at one pixel per crossing. Both are then
// drawn as vector squares (pdf_book_draft.dart).

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/draft_repository.dart';
import '../models/double_weave_construction.dart';
import '../models/double_weave_layers.dart' show hasLayerRoles, maxLayerShaft;
import '../models/draft_doc.dart';
import '../models/draft_issue.dart';
import '../models/drawdown_region.dart';
import '../models/treadling_entries.dart';
import '../models/use_tabby.dart';
import '../models/weft_work.dart';
import '../state/draft_editor_notifier.dart';
import '../state/editor_providers.dart' show repositoryProvider, structuralDraft;
import '../widgets/book_view_sheet.dart'
    show
        bookPickRangeLabel,
        bookRoleDescription,
        bookShedLabel,
        bookWeftDescription,
        kShotGroupCatch,
        shuttlesSummary;
import 'knit_print.dart' show isoDate;
import 'print_document.dart';
import 'print_export.dart';

// ---------------------------------------------------------------------------------------------------
// Limits
// ---------------------------------------------------------------------------------------------------

/// The most crossings (ends times picks) a printed draft may have, and the most ends or picks. Beyond
/// them the export is refused with a reason before any engine call: such a draft would need many
/// hundreds of pages and more memory than a phone should spend on one PDF.
const int kWeavePrintMaxCells = 2000000;
const int kWeavePrintMaxThreads = 20000;

/// Thrown by [gatherWeavePrint] for a draft over the print limits; [message] says why in plain words.
class WeavePrintTooLarge implements Exception {
  const WeavePrintTooLarge(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Refuse a draft over the print limits.
void checkWeavePrintSize(DraftDoc doc) {
  final ends = doc.ends, picks = doc.picks;
  if (ends > kWeavePrintMaxThreads ||
      picks > kWeavePrintMaxThreads ||
      ends * picks > kWeavePrintMaxCells) {
    throw WeavePrintTooLarge('This draft is too large to print: $ends ends by $picks picks. Ply '
        'prints drafts of up to ${_thousands(kWeavePrintMaxCells)} crossings (ends times picks) '
        'and up to ${_thousands(kWeavePrintMaxThreads)} ends or picks.');
  }
}

// ---------------------------------------------------------------------------------------------------
// Source attribution
// ---------------------------------------------------------------------------------------------------

/// What a WIF file says about where it came from: its [title] and [author] (`[TEXT]`) and the
/// [program] that wrote it (`[WIF]` Source Program and Version). [hasContact] when `[TEXT]` also
/// lists contact details (address, email, telephone, fax), which Ply never prints.
class WeaveAttribution {
  const WeaveAttribution({this.title, this.author, this.program, this.hasContact = false});
  final String? title;
  final String? author;
  final String? program;
  final bool hasContact;
}

/// Read [WeaveAttribution] from WIF text (the editor's source file). Only those keys are read; every
/// value is trimmed, stripped of control characters and cut to 120 characters. An absent or
/// unreadable file gives an empty attribution.
WeaveAttribution readWifAttribution(String? wif) {
  if (wif == null || wif.isEmpty) return const WeaveAttribution();
  String? section;
  final text = <String, String>{};
  final head = <String, String>{};
  for (final raw in wif.split(RegExp(r'\r\n|\r|\n'))) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith(';')) continue;
    final s = RegExp(r'^\[(.+)\]$').firstMatch(line);
    if (s != null) {
      section = s[1]!.trim().toUpperCase();
      continue;
    }
    final eq = line.indexOf('=');
    if (eq <= 0) continue;
    final key = line.substring(0, eq).trim().toLowerCase();
    var value = line.substring(eq + 1).replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '').trim();
    if (value.runes.length > 120) value = '${String.fromCharCodes(value.runes.take(119))}…';
    if (value.isEmpty) continue;
    if (section == 'TEXT') text[key] = value;
    if (section == 'WIF') head[key] = value;
  }
  final program = head['source program'];
  final version = head['source version'];
  return WeaveAttribution(
    title: text['title'],
    author: text['author'],
    program: program == null ? null : (version == null ? program : '$program $version'),
    hasContact:
        const ['address', 'email', 'e-mail', 'telephone', 'phone', 'fax'].any(text.containsKey),
  );
}

// ---------------------------------------------------------------------------------------------------
// Gathering from the engine
// ---------------------------------------------------------------------------------------------------

/// Everything a printed draft is made from, gathered from the engine once.
class WeavePrintSource {
  const WeavePrintSource({
    required this.name,
    required this.doc,
    required this.issues,
    required this.interlacement,
    this.drawdownError,
    required this.colors,
    this.colorsError,
    this.attribution = const WeaveAttribution(),
    this.credit,
    required this.printedAt,
  });

  /// The draft's display name.
  final String name;
  final DraftDoc doc;

  /// The engine's validation of [doc].
  final List<DraftIssue> issues;

  /// The engine's interlacement, `picks * ends`, row-major, end index 0 first: 1 = warp on top. Null
  /// when the draft has no crossings or it could not be drawn ([drawdownError] says why).
  final Uint8List? interlacement;
  final String? drawdownError;

  /// The engine's colored drawdown, one 0xRRGGBB per crossing in the same order. Null as above.
  final Uint32List? colors;
  final String? colorsError;

  /// Where the source file says the draft came from.
  final WeaveAttribution attribution;

  /// The author credit saved with the draft in Ply (the library entry), if any.
  final String? credit;
  final DateTime printedAt;
}

/// [doc] for reading its interlacement off the engine: uniform cells, every warp end black and every
/// pick white, so a black pixel is a crossing with the warp on top.
DraftDoc blackWhiteDraft(DraftDoc doc) => structuralDraft(doc).copyWith(
      palette: const [DraftColor(r: 255, g: 255, b: 255), DraftColor(r: 0, g: 0, b: 0)],
      warpColors: List<int>.filled(doc.ends, 1),
      weftColors: List<int>.filled(doc.picks, 0),
    );

void _checkPixels(int width, int height, Uint8List rgba, int ends, int picks) {
  if (width != ends || height != picks || rgba.length < width * height * 4) {
    throw StateError('the engine drew $width x $height pixels for $ends ends and $picks picks');
  }
}

/// The most ends and picks asked of the engine in one render: a tile of at most about a million
/// crossings, far inside its per-render budget (4 million crossings, 8192 pixels a side), so every
/// draft within the print limits is read a tile at a time instead of being refused for its width.
const int kWeavePrintTileSide = 1024;

/// Render [doc]'s whole drawdown at one pixel per crossing, a tile at a time (the engine draws each
/// tile's highest end in its left column and its first pick in its top row), handing [take] the
/// model end and pick of every crossing with its pixel's offset in the tile's RGBA.
Future<void> _readCrossings(
  DraftRepository repo,
  DraftDoc doc,
  void Function(int end, int pick, Uint8List rgba, int offset) take,
) async {
  final ends = doc.ends, picks = doc.picks;
  for (var p0 = 0; p0 < picks; p0 += kWeavePrintTileSide) {
    final ph = math.min(kWeavePrintTileSide, picks - p0);
    for (var e0 = 0; e0 < ends; e0 += kWeavePrintTileSide) {
      final ew = math.min(kWeavePrintTileSide, ends - e0);
      final region = DrawdownRegion(endStart: e0, endCount: ew, pickStart: p0, pickCount: ph);
      final px = await repo.renderRegionPixels(doc, region, cellPx: 1);
      _checkPixels(px.width, px.height, px.rgba, ew, ph);
      for (var y = 0; y < ph; y++) {
        for (var x = 0; x < ew; x++) {
          take(e0 + ew - 1 - x, p0 + y, px.rgba, (y * px.width + x) * 4);
        }
      }
    }
  }
}

/// The interlacement, `picks * ends`, end index 0 first: 1 = warp on top, read from the engine's
/// render of [blackWhiteDraft] (a dark pixel is a crossing with the warp on top).
Future<Uint8List> readInterlacement(DraftRepository repo, DraftDoc doc) async {
  final ends = doc.ends;
  final out = Uint8List(ends * doc.picks);
  await _readCrossings(repo, blackWhiteDraft(doc), (e, p, rgba, i) {
    out[p * ends + e] = rgba[i] + rgba[i + 1] + rgba[i + 2] < 384 ? 1 : 0;
  });
  return out;
}

/// The colored drawdown, one 0xRRGGBB per crossing in model order (end index 0 first), read from the
/// engine's uniform render of [doc].
Future<Uint32List> readColors(DraftRepository repo, DraftDoc doc) async {
  final ends = doc.ends;
  final out = Uint32List(ends * doc.picks);
  await _readCrossings(repo, structuralDraft(doc), (e, p, rgba, i) {
    out[p * ends + e] = (rgba[i] << 16) | (rgba[i + 1] << 8) | rgba[i + 2];
  });
  return out;
}

/// Read [doc]'s validation, interlacement and colors from [repo]. [sourceWif] is the file the editor
/// opened (for its attribution); [credit] the author saved with the draft in Ply. Throws
/// [WeavePrintTooLarge] for a draft over the print limits, before any engine call; a drawdown the
/// engine cannot draw is recorded with its reason (the PDF says so), never dropped silently.
Future<WeavePrintSource> gatherWeavePrint(
  DraftRepository repo, {
  required String name,
  required DraftDoc doc,
  String? sourceWif,
  String? credit,
  DateTime? now,
}) async {
  checkWeavePrintSize(doc);
  final issues = await repo.validateDto(doc);
  Uint8List? interlacement;
  Uint32List? colors;
  String? drawdownError, colorsError;
  final ends = doc.ends, picks = doc.picks;
  if (ends > 0 && picks > 0) {
    try {
      interlacement = await readInterlacement(repo, doc);
    } catch (e) {
      drawdownError = previewErrorMessage(e);
    }
    try {
      colors = await readColors(repo, doc);
    } catch (e) {
      colorsError = previewErrorMessage(e);
    }
  }
  final trimmed = credit?.trim();
  return WeavePrintSource(
    name: name,
    doc: doc,
    issues: issues,
    interlacement: interlacement,
    drawdownError: drawdownError,
    colors: colors,
    colorsError: colorsError,
    attribution: readWifAttribution(sourceWif),
    credit: trimmed == null || trimmed.isEmpty ? null : trimmed,
    printedAt: now ?? DateTime.now(),
  );
}

// ---------------------------------------------------------------------------------------------------
// Words
// ---------------------------------------------------------------------------------------------------

/// The layout's name in the print sheet and on the page.
String bookLayoutLabel(BookCorner c) => switch (c) {
      BookCorner.topRight => 'Tie-up top right',
      BookCorner.topLeft => 'Tie-up top left',
      BookCorner.bottomRight => 'Tie-up bottom right',
      BookCorner.bottomLeft => 'Tie-up bottom left',
    };

/// One line about the layout for the print sheet.
String bookLayoutHint(BookCorner c) => switch (c) {
      BookCorner.topRight => "Ply's editor layout, common in North American books.",
      BookCorner.topLeft => 'Mirror image: end 1 at the left, threading read left to right.',
      BookCorner.bottomRight => 'Threading at the bottom, picks read upward.',
      BookCorner.bottomLeft => 'Mirror image with the threading at the bottom.',
    };

/// How to read the book draft in [corner], in words: where each quadrant is and where end 1, shaft 1,
/// treadle 1 and pick 1 are. [annotated] when the grids carry arrows or edge labels (a mirrored
/// layout then says they follow the picture).
List<String> bookReadingText(BookCorner c, {required bool liftplan, bool annotated = false}) {
  final top = !c.mirrorY;
  final side = c.mirrorX ? 'left' : 'right';
  final near = c.mirrorX ? 'right' : 'left';
  final edge = top ? 'top' : 'bottom';
  final corner = '$edge $side';
  final under = top ? 'under' : 'above';
  final sentences = <String>[
    if (liftplan)
      'The threading runs along the $edge, the drawdown is $under it, and the lift plan is beside '
          'the drawdown on the $side. A lift plan has no tie-up, so the $corner corner holds only '
          "the lift plan's shaft numbers."
    else
      'The threading runs along the $edge with the tie-up at the $corner. The treadling is $under '
          'the tie-up and the drawdown $under the threading.',
    'End 1 is the $side-hand column of the threading, so read the threading from $side to $near.',
    'Shaft 1 is the ${top ? 'bottom' : 'top'} row of the threading'
        '${liftplan ? '' : ' and of the tie-up'}, the row next to the drawdown.',
    if (liftplan)
      'In the lift plan, shaft 1 is the $near-hand column.'
    else
      'Treadle 1 is the $near-hand column of the tie-up and of the treadling.',
    'Pick 1 is the ${top ? 'top' : 'bottom'} row of the ${liftplan ? 'lift plan' : 'treadling'} '
        'and of the drawdown, so read the ${liftplan ? 'lift plan' : 'treadling'} '
        '${top ? 'from the top down' : 'from the bottom up'}. The number beside each row is its '
        'pick number.',
    'A heavier line follows every 10th end and every 10th pick.',
    if (c.mirrorX) ...[
      'This layout is the mirror image of the cloth as Ply records it, with end 1 at the weaver\'s '
          'right. Woven with end 1 at your left, the cloth comes out mirror image: a twill line '
          'leans the other way.',
      if (annotated)
        'The arrows and edge labels on the grids follow the picture. The written directions say '
            'left and right as you sit at the loom with end 1 at your right, as Ply records them.',
    ],
    'Other books may put the tie-up in another corner, read the threading from the other side, or '
        'number shafts and treadles from the other edge, so check where each 1 is before you '
        'compare drafts.',
  ];
  return sentences;
}

/// What a mark in the tie-up (or lift plan) means for [doc]'s shed.
String shedMeaning(DraftDoc doc) {
  if (doc.drive is DraftLiftplan) {
    return 'A filled square in the lift plan raises that shaft for the pick.'
        '${doc.shed == Shed.sinking ? ' This draft is marked for a sinking shed, but a lift plan '
            'always lists the shafts that rise.' : ''}';
  }
  return doc.shed == Shed.sinking
      ? 'Sinking shed: an X in the tie-up means that shaft sinks when you press the treadle, and '
          'every shaft without an X rises.'
      : 'Rising shed: a filled square in the tie-up means that shaft rises when you press the '
          'treadle.';
}

/// The margin letter for a pick role ("" when unknown).
String roleLetter(PickRole r) => switch (r) {
      PickRole.unknown => '',
      PickRole.pattern => 'P',
      PickRole.tabby => 'T',
      PickRole.topLayer => 'U',
      PickRole.bottomLayer => 'L',
    };

/// The edge labels for a confirmed [construction]: (the edge at the highest end, which is the weaver's
/// left; the edge at end 1, the weaver's right).
(String?, String?) constructionEdgeLabels(LayerConstruction c) => switch (c) {
      LayerConstruction.none => (null, null),
      LayerConstruction.twoLayers => ('Open', 'Open'),
      LayerConstruction.tube => ('Joined', 'Joined'),
      LayerConstruction.doubleWidthFoldLeft => ('Fold', 'Open'),
      LayerConstruction.doubleWidthFoldRight => ('Open', 'Fold'),
    };

/// One end's threading as a token: "1", "1+3" (an end on two shafts), "–" (not threaded).
String threadingToken(List<int> shafts) => shafts.isEmpty ? '–' : ([...shafts]..sort()).join('+');

/// The shuttle and pass of [picks] (0-based, in order) in words, or null when the draft records no
/// shuttle. Never cut short: "Shuttle 1, right to left (←)" for one pick; "Shuttle 1: ← → ←, the first
/// pass right to left" for a few passes on one shuttle; for many, "Shuttle 1: 20 passes, the first
/// right to left (←), changing direction on every pass" or "..., every one right to left (←)" when the
/// directions really are so; otherwise every pass ("Shuttles: 1 ←, 2 →, ?").
String? weaveShuttleText(DraftDoc doc, List<ShuttleSide?> starts, List<int> picks) {
  if (doc.pickShuttles.isEmpty || picks.isEmpty) return null;
  ShuttleSide? side(int p) => p < starts.length ? starts[p] : null;
  final shuttles = {for (final p in picks) doc.shuttleAt(p)};
  if (shuttles.length == 1) {
    final s = shuttles.single;
    if (s == null) return picks.length == 1 ? 'Shuttle unknown' : 'Shuttles unknown';
    final sides = [for (final p in picks) side(p)];
    if (sides.every((x) => x == null)) return 'Shuttle $s, direction unknown';
    if (sides.every((x) => x != null)) {
      final first = sides.first!;
      if (picks.length == 1) return 'Shuttle $s, ${passWords(first)} (${passArrow(first)})';
      if (picks.length <= 12) {
        return 'Shuttle $s: ${sides.map((x) => passArrow(x!)).join(' ')}, the first pass '
            '${passWords(first)}';
      }
      // Said in words only when the derived directions really follow one pattern (a Use tabby row
      // lists every other pick, so on a shared shuttle its passes all go the same way).
      if (sides.every((x) => x == first)) {
        return 'Shuttle $s: ${picks.length} passes, every one ${passWords(first)} '
            '(${passArrow(first)})';
      }
      if ([for (var i = 1; i < sides.length; i++) sides[i] != sides[i - 1]].every((x) => x)) {
        return 'Shuttle $s: ${picks.length} passes, the first ${passWords(first)} '
            '(${passArrow(first)}), changing direction on every pass';
      }
    }
  }
  String token(int p) {
    final s = doc.shuttleAt(p);
    if (s == null) return '?';
    final x = side(p);
    return x == null ? '$s' : '$s ${passArrow(x)}';
  }

  return 'Shuttles: ${picks.map(token).join(', ')}';
}

/// The strands of [picks] in words, or null when each carries one strand. Never cut short.
String? weaveStrandsText(DraftDoc doc, List<int> picks) {
  final counts = [for (final p in picks) doc.strandsAt(p)];
  if (counts.every((n) => n == 1)) return null;
  if (counts.toSet().length == 1) {
    return picks.length == 1
        ? '${counts.first} strands carried together'
        : '${counts.first} strands carried together in each pass';
  }
  return 'Strands carried together: ${counts.join(', ')}';
}

/// One full-listing row of the treadling (or lift plan) directions: the shed and its count (×3, left
/// out for a single pick), the picks, a shot group, the weft colors, roles, shuttle and pass, strands.
/// "Treadle 1 ×3, picks 1 to 3. Weft color 2 for 2 picks, then color 1 for 1 pick."
String weaveEntryText(DraftDoc doc, TreadlingEntry entry, List<ShuttleSide?> starts) {
  final treadled = doc.drive is DraftTreadled;
  final picks = [for (var p = entry.startPick; p < entry.endPick; p++) p];
  final range = _lowerFirst(bookPickRangeLabel(entry.startPick, entry.endPick));
  final shot = entry.grouped ? ': ${_lowerFirst(shotGroupDescription(entry.count))}' : '';
  final runs = weftColorRuns(entry, doc.weftColors);
  final parts = [
    '${bookShedLabel(entry.shed, treadled: treadled)}${_times(entry.count)}, $range$shot',
    runs.length == 1
        ? 'Weft color ${runs.single.color + 1}'
        : _upperFirst(bookWeftDescription(entry, doc.weftColors)),
    if (doc.pickRoles.isNotEmpty) bookRoleDescription(doc, entry.startPick, entry.endPick),
    if (weaveShuttleText(doc, starts, picks) case final s?) s,
    if (weaveStrandsText(doc, picks) case final s?) _upperFirst(s),
  ];
  return '${parts.join('. ')}.';
}

/// One Use tabby row of the treadling directions: "Treadle 1 ×4, picks 1 to 7. Pattern weft color
/// 2."
String useTabbyRowText(
    DraftDoc doc, UseTabbyBook book, UseTabbyRow row, List<ShuttleSide?> starts) {
  final picks = [for (var k = row.firstPattern; k < row.endPattern; k++) book.pickOfPattern(k)];
  final runs = <(int, int)>[];
  for (var k = row.firstPattern; k < row.endPattern; k++) {
    final c = book.pattern[k].color;
    if (runs.isNotEmpty && runs.last.$1 == c) {
      runs[runs.length - 1] = (c, runs.last.$2 + 1);
    } else {
      runs.add((c, 1));
    }
  }
  final weft = runs.length == 1
      ? 'Pattern weft color ${runs.single.$1 + 1}'
      : [
          for (final (i, (c, n)) in runs.indexed)
            '${i == 0 ? 'Pattern weft color' : 'then color'} ${c + 1} for '
                '${n == 1 ? '1 pattern pick' : '$n pattern picks'}',
        ].join(', ');
  final parts = [
    '${bookShedLabel(row.shed, treadled: book.treadled)}${_times(row.count)}, '
        '${_lowerFirst(bookPickRangeLabel(row.firstPick, row.lastPick + 1))}',
    weft,
    if (weaveShuttleText(doc, starts, picks) case final s?) s,
    if (weaveStrandsText(doc, picks) case final s?) _upperFirst(s),
  ];
  return '${parts.join('. ')}.';
}

// ---------------------------------------------------------------------------------------------------
// The document
// ---------------------------------------------------------------------------------------------------

/// The errors that make the export ask before printing (warnings and notes never block).
List<String> weavePrintErrors(WeavePrintSource s) => [
      for (final i in s.issues)
        if (i.isError) _upperFirst(i.message),
    ];

/// The book draft's quadrant sizes for [doc]: threading rows (every shaft the draft names, at least
/// its header count), and tie-up and treadling columns (treadles, or shafts for a lift plan).
({int shafts, int columns}) bookDraftSize(DraftDoc doc) {
  int top(Iterable<List<int>> rows) => rows.fold(0, (m, r) => r.fold(m, math.max));
  switch (doc.drive) {
    case DraftTreadled(:final tieup, :final treadling):
      final shafts = math.max(maxLayerShaft(doc), top(tieup));
      return (
        shafts: shafts,
        columns: math.max(math.max(doc.treadles, tieup.length), top(treadling)),
      );
    case DraftLiftplan(:final liftplan):
      final shafts = math.max(maxLayerShaft(doc), top(liftplan));
      return (shafts: shafts, columns: shafts);
  }
}

/// The document for [s] in the [corner] layout. [withProblemsBox] is the user's "print anyway" choice:
/// when the draft has errors, a box at the top lists them. Without errors there is never a box.
PrintDocument buildWeavePrintDocument(
  WeavePrintSource s, {
  required bool withProblemsBox,
  BookCorner corner = BookCorner.topRight,
}) {
  final doc = s.doc;
  final treadled = doc.drive is DraftTreadled;
  final rows = doc.drive.rows;
  final ends = doc.ends, picks = doc.picks;
  final size = bookDraftSize(doc);
  final errors = weavePrintErrors(s);
  final printNotes = <String>[];
  final starts = passStarts(doc);
  final reading = readUseTabby(doc);
  final book = reading is UseTabbyBook ? reading : null;
  final layered = hasLayerRoles(doc);

  // --- annotations the model knows --------------------------------------------------------------
  final roles = doc.pickRoles.isEmpty
      ? const <String>[]
      : [
          for (var p = 0; p < picks; p++) roleLetter(doc.roleAt(p)),
        ];
  PrintPass pass(int p) => PrintPass(
        shuttle: doc.shuttleAt(p),
        direction: switch (p < starts.length ? starts[p] : null) {
          null => PrintPassDirection.unknown,
          ShuttleSide.right => PrintPassDirection.fromEndOne,
          ShuttleSide.left => PrintPassDirection.towardEndOne,
        },
      );
  final hasPasses = doc.pickShuttles.isNotEmpty;
  final passes = hasPasses ? [for (var p = 0; p < picks; p++) pass(p)] : const <PrintPass>[];
  final brackets = [
    for (final g in doc.shotGroups)
      if (g.count >= 2 && g.start >= 0 && g.end <= picks)
        PrintRowBracket(start: g.start, end: g.end, label: shotGroupLabel(g.count).toLowerCase()),
  ];
  final edges = deriveEdges(doc);
  final construction = doc.construction;
  final confirmed = construction != LayerConstruction.none &&
      edges is EdgesKnown &&
      agreesWith(edges, construction);
  final (highEdge, oneEdge) = confirmed ? constructionEdgeLabels(construction) : (null, null);
  final annotated = hasPasses || highEdge != null;

  final tieup = switch (doc.drive) {
    DraftTreadled(:final tieup) => [
        for (var t = 0; t < size.columns; t++) t < tieup.length ? tieup[t] : const <int>[],
      ],
    DraftLiftplan() => null,
  };
  final sinkingTieup = treadled && doc.shed == Shed.sinking;

  // --- the book draft ----------------------------------------------------------------------------
  final draftBlocks = <PrintBlock>[];
  if (ends == 0 || picks == 0) {
    draftBlocks.add(PrintParagraph(ends == 0 && picks == 0
        ? 'This draft has no ends or picks yet.'
        : (ends == 0 ? 'This draft has no ends yet.' : 'This draft has no picks yet.')));
  } else {
    draftBlocks
      ..add(PrintParagraph(
          bookReadingText(corner, liftplan: !treadled, annotated: annotated).join(' ')))
      ..add(PrintParagraph(shedMeaning(doc)))
      ..add(const PrintParagraph(
          'In the drawdown, a black square is a crossing where the warp is on top and a white '
          "square one where the weft is on top, as Ply's weaving engine works them out from the "
          'threading, tie-up and treadling.'));
    if (layered) {
      draftBlocks.add(const PrintParagraph(
          'This drawdown shows every intersection of both layers, not the face of the cloth.',
          style: PrintTextStyle.strong));
    }
    if (construction != LayerConstruction.none) {
      if (confirmed) {
        draftBlocks.add(PrintParagraph('Construction: ${constructionLabel(construction)}. The '
            "edges Ply works out from each pick's layer, shuttle and starting side match it, so "
            "the drawdown's edges are labelled."));
      } else {
        final unknown = edges is EdgesUnknown;
        draftBlocks.add(PrintNotice(
          level: PrintNoticeLevel.caution,
          title: unknown ? 'Ply cannot check the edges' : 'The edges do not match the construction',
          intro: 'This draft is marked as ${constructionPhrase(construction)}, so the grids '
              'carry no edge labels.',
          lines: constructionIssues(doc),
        ));
        printNotes.add('The draft is marked as ${constructionPhrase(construction)}, but '
            '${unknown ? 'Ply cannot check its edges' : 'its edges do not match it'}, so the grids '
            'carry no edge labels.');
      }
    }
    if (hasPasses) {
      for (final n in directionNotes(doc)) {
        draftBlocks.add(PrintParagraph(n, style: PrintTextStyle.muted));
      }
    }
    draftBlocks.add(PrintLegend(_draftKey(
      doc,
      corner: corner,
      sinkingTieup: sinkingTieup,
      roles: roles,
      passes: passes,
      brackets: brackets.isNotEmpty,
      edges: [if (highEdge != null) highEdge, if (oneEdge != null) oneEdge],
    )));
    if (s.interlacement == null) {
      draftBlocks.add(PrintNotice(
        level: PrintNoticeLevel.caution,
        title: 'The drawdown could not be drawn',
        intro: '${s.drawdownError ?? 'The engine did not draw it.'} The threading, tie-up and '
            'treadling below are complete; the drawdown squares are left empty.',
      ));
      printNotes.add('The drawdown could not be drawn, so its squares are left empty.');
    }
    draftBlocks.add(PrintBookDraft(
      ends: ends,
      shafts: size.shafts,
      columns: size.columns,
      threading: doc.threading,
      tieup: tieup,
      tieupMark: sinkingTieup ? PrintMark.cross : PrintMark.filled,
      treadling: rows,
      pickNumbers: [for (var p = 0; p < picks; p++) p + 1],
      drawdown: s.interlacement,
      corner: corner,
      roles: roles,
      passes: passes,
      brackets: brackets,
      highEndEdge: highEdge,
      endOneEdge: oneEdge,
    ));
  }

  // --- Use tabby -----------------------------------------------------------------------------------
  PrintSection? useTabby;
  if (book != null && ends > 0) {
    final patternPicks = [for (var k = 0; k < book.pattern.length; k++) book.pickOfPattern(k)];
    final inter = s.interlacement;
    useTabby = PrintSection('Use tabby', [
      const PrintParagraph('USE TABBY', style: PrintTextStyle.strong),
      PrintParagraph(useTabbyInstruction(book)),
      PrintFacts([
        PrintFact('Tabby weft', _colorName(doc, book.tabbyColor)),
        if (hasPasses)
          PrintFact('Tabby shuttle',
              book.tabbyShuttle == null ? 'Unknown' : 'Shuttle ${book.tabbyShuttle}'),
        if (book.tabbyStrands > 1)
          PrintFact('Tabby strands', '${book.tabbyStrands} strands carried together'),
        PrintFact('Picks', useTabbySummary(book)),
      ]),
      const PrintParagraph(
          'The grid below is the traditional Use tabby presentation: the treadling and the '
          'drawdown of the pattern picks only. Each row carries its pick number in the full draft, '
          'so the numbers go up by 2, and the tabby pick between two rows is not drawn. The full '
          'draft above shows every pick; both describe exactly the same picks. A heavier line '
          'follows every 10th row here.',
          style: PrintTextStyle.muted),
      PrintBookDraft(
        ends: ends,
        shafts: size.shafts,
        columns: size.columns,
        threading: doc.threading,
        tieup: tieup,
        tieupMark: sinkingTieup ? PrintMark.cross : PrintMark.filled,
        treadling: [for (final p in patternPicks) rows[p]],
        pickNumbers: [for (final p in patternPicks) p + 1],
        drawdown: inter == null
            ? null
            : Uint8List.fromList([
                for (final p in patternPicks) ...inter.sublist(p * ends, (p + 1) * ends),
              ]),
        corner: corner,
        passes: hasPasses ? [for (final p in patternPicks) pass(p)] : const [],
        rowsNote: 'pattern picks only',
      ),
    ]);
  }

  // --- colored drawdown ---------------------------------------------------------------------------
  final colorBlocks = <PrintBlock>[];
  if (ends > 0 && picks > 0) {
    final top = !corner.mirrorY;
    colorBlocks.add(PrintParagraph('Each square is the color of the thread on top at that '
        "crossing, as Ply's weaving engine draws it. The warp colors run in a band along the "
        '${top ? 'top' : 'bottom'} and the weft colors down the ${corner.mirrorX ? 'left' : 'right'}'
        ', laid out like the draft above. The color key under Materials names every color by '
        'number.'));
    colorBlocks.add(const PrintParagraph(
        'Every end and pick is one square of the same size; yarn thickness is not drawn.',
        style: PrintTextStyle.muted));
    if (layered) {
      colorBlocks.add(const PrintParagraph(
          'Like the drawdown, this shows every intersection of both layers, not the face of the '
          'cloth.',
          style: PrintTextStyle.muted));
    }
    if (s.colors == null) {
      colorBlocks.add(PrintNotice(
        level: PrintNoticeLevel.caution,
        title: 'The color drawdown could not be drawn',
        intro: s.colorsError ?? 'The engine did not draw it.',
      ));
      printNotes.add('The color drawdown could not be drawn.');
    } else {
      colorBlocks.add(PrintColorDrawdown(
        ends: ends,
        picks: picks,
        cells: s.colors!,
        warp: [for (var e = 0; e < ends; e++) _paletteColor(doc, _warpAt(doc, e))],
        weft: [for (var p = 0; p < picks; p++) _paletteColor(doc, _weftAt(doc, p))],
        corner: corner,
      ));
    }
  }

  // --- what the PDF cannot show exactly ------------------------------------------------------------
  final thickEnds = doc.warpThickness.where((t) => t != 1.0).length;
  final thickPicks = doc.weftThickness.where((t) => t != 1.0).length;
  if (thickEnds + thickPicks > 0) {
    printNotes.add('Yarn thickness is not drawn: the grids and the color drawdown give every end '
        'and pick one square. ${_count(thickEnds, 'end')} and ${_count(thickPicks, 'pick')} have '
        'a recorded thickness other than 1.');
  }
  if (doc.pickStrands.any((n) => n > 1)) {
    printNotes.add('Strands carried together are given in the treadling directions only; the '
        'grids show one mark per pick.');
  }
  if (hasPasses) printNotes.addAll(directionNotes(doc));
  if (layered) {
    printNotes.add('The drawdowns show every intersection of both layers, not the face of the '
        'cloth.');
  }
  if (doc.retained.isNotEmpty) {
    printNotes.add('The file holds data Ply keeps but does not print: '
        '${_and([for (final r in doc.retained) r.name])}.');
  }

  // --- problems ------------------------------------------------------------------------------------
  final issueRows = [
    for (final i in s.issues.where((i) => i.isError)) _issue(i),
    for (final i in s.issues.where((i) => !i.isError)) _issue(i),
  ];

  return PrintDocument(
    title: s.name.trim().isEmpty ? 'Untitled draft' : s.name,
    kind: 'Weaving draft',
    titleFacts: [
      PrintFact('Printed', isoDate(s.printedAt)),
      PrintFact(
          'Loom',
          treadled
              ? '${_count(size.shafts, 'shaft')}, ${_count(size.columns, 'treadle')}'
              : '${_count(size.shafts, 'shaft')}, lift plan'),
      PrintFact('Size', '${_count(ends, 'end')}, ${_count(picks, 'pick')}'),
      PrintFact('Shed', doc.shed == Shed.sinking ? 'Sinking shed' : 'Rising shed'),
      PrintFact('Layout', bookLayoutLabel(corner)),
    ],
    problemsBox: withProblemsBox && errors.isNotEmpty
        ? PrintNotice(
            level: PrintNoticeLevel.problem,
            title: 'This draft has problems',
            intro: 'Ply found ${_count(errors.length, 'error')} in this draft. Check '
                '${errors.length == 1 ? 'it' : 'them'} before you weave from it; Problems at the '
                'end lists every finding.',
            lines: errors,
          )
        : null,
    sections: [
      if (doc.notes.trim().isNotEmpty) PrintSection('Notes', [PrintParagraph(doc.notes.trim())]),
      if (_sourceBlocks(s) case final blocks when blocks.isNotEmpty) PrintSection('Source', blocks),
      PrintSection('Materials', _materialBlocks(doc, size: size)),
      PrintSection('Draft', draftBlocks),
      if (useTabby != null) useTabby,
      if (colorBlocks.isNotEmpty) PrintSection('Color drawdown', colorBlocks),
      if (ends > 0) PrintSection('Threading', _threadingBlocks(doc)),
      if (tieup != null) PrintSection('Tie-up', _tieupBlocks(doc, tieup)),
      if (picks > 0)
        PrintSection(treadled ? 'Treadling' : 'Lift plan',
            _treadlingBlocks(doc, book: book, reading: reading, starts: starts)),
      PrintSection('Problems', [
        PrintIssues(issueRows, emptyText: 'Ply found no problems in this draft.'),
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

List<PrintBlock> _sourceBlocks(WeavePrintSource s) {
  final a = s.attribution;
  final facts = <PrintFact>[
    if (a.title != null && a.title != s.name) PrintFact('Title in the file', a.title!),
    if (a.author != null) PrintFact('Author', a.author!),
    if (a.program != null) PrintFact('Written by', a.program!),
    if (s.credit != null && s.credit != a.author) PrintFact('Credit', s.credit!),
  ];
  return [
    if (facts.isNotEmpty) PrintFacts(facts),
    if (a.hasContact)
      const PrintParagraph('The file also lists contact details, which Ply does not print.',
          style: PrintTextStyle.muted),
  ];
}

List<PrintBlock> _materialBlocks(DraftDoc doc, {required ({int shafts, int columns}) size}) {
  final warpCounts = <int, int>{};
  final weftCounts = <int, int>{};
  for (var e = 0; e < doc.ends; e++) {
    warpCounts.update(_warpAt(doc, e), (n) => n + 1, ifAbsent: () => 1);
  }
  for (var p = 0; p < doc.picks; p++) {
    weftCounts.update(_weftAt(doc, p), (n) => n + 1, ifAbsent: () => 1);
  }
  final used = {...warpCounts.keys, ...weftCounts.keys}.toList()..sort();
  final entries = [
    for (final i in used)
      PrintLegendEntry(
        code: '${i + 1}',
        name: 'Color ${i + 1}',
        meaning: '${[
          i < doc.palette.length
              ? _paletteColor(doc, i).hex
              : 'Not in the palette, so Ply draws it white',
          warpCounts[i] == null ? 'Not in the warp' : 'Warp: ${_count(warpCounts[i]!, 'end')}',
          weftCounts[i] == null ? 'Not in the weft' : 'Weft: ${_count(weftCounts[i]!, 'pick')}',
        ].join('. ')}.',
        swatch: _paletteColor(doc, i),
      ),
  ];
  final shuttles = shuttlesInUse(doc);
  final thickEnds = doc.warpThickness.where((t) => t != 1.0).length;
  final thickPicks = doc.weftThickness.where((t) => t != 1.0).length;
  return [
    PrintFacts([
      PrintFact('Warp', _count(doc.ends, 'end')),
      PrintFact('Weft', _count(doc.picks, 'pick')),
      PrintFact('Colors',
          used.isEmpty ? 'None yet' : (used.length == 1 ? 'One color' : '${used.length} colors')),
      if (shuttles.isNotEmpty) PrintFact('Shuttles', shuttlesSummary(doc)),
      if (doc.pickStrands.any((n) => n > 1))
        const PrintFact('Strands', 'Some picks carry several strands together, see Treadling'),
      if (thickEnds + thickPicks > 0)
        PrintFact('Thickness',
            'Recorded for ${_count(thickEnds, 'end')} and ${_count(thickPicks, 'pick')}; not drawn'),
      if (doc.construction != LayerConstruction.none)
        PrintFact('Construction', constructionLabel(doc.construction)),
    ]),
    if (entries.isNotEmpty) ...[
      const PrintParagraph('Color key', style: PrintTextStyle.strong),
      PrintLegend(entries),
    ],
    if (doc.ends > 0) ...[
      const PrintParagraph('Warp color order', style: PrintTextStyle.strong),
      const PrintParagraph('The color number of each end, ten ends to a line, from end 1.',
          style: PrintTextStyle.muted),
      PrintLines(_groupsOfTen(doc.ends, 'End', (e) => '${_warpAt(doc, e) + 1}')),
    ],
    if (doc.picks > 0) ...[
      const PrintParagraph('Weft color order', style: PrintTextStyle.strong),
      const PrintParagraph('The color number of each pick, ten picks to a line, from pick 1.',
          style: PrintTextStyle.muted),
      PrintLines(_groupsOfTen(doc.picks, 'Pick', (p) => '${_weftAt(doc, p) + 1}')),
    ],
  ];
}

List<PrintBlock> _threadingBlocks(DraftDoc doc) {
  final unthreaded = doc.threading.any((e) => e.isEmpty);
  final multi = doc.threading.any((e) => e.length > 1);
  return [
    PrintParagraph('The shaft each end is threaded on, ten ends to a line, from end 1.'
        '${multi ? ' 1+3 means an end on shafts 1 and 3.' : ''}'
        '${unthreaded ? ' A dash (–) is an end that is not threaded.' : ''}'),
    PrintLines(_groupsOfTen(doc.ends, 'End', (e) => threadingToken(doc.threading[e]))),
  ];
}

List<PrintBlock> _tieupBlocks(DraftDoc doc, List<List<int>> tieup) {
  String shafts(List<int> s) {
    final ids = [...s]..sort();
    if (ids.isEmpty) return 'Not tied to any shaft.';
    return ids.length == 1
        ? 'Shaft ${ids.single}.'
        : 'Shafts ${_and(ids.map((i) => '$i').toList())}.';
  }

  return [
    PrintParagraph(doc.shed == Shed.sinking
        ? 'Sinking shed: pressing a treadle lowers the shafts tied to it, and every other shaft '
            'rises.'
        : 'Rising shed: pressing a treadle raises the shafts tied to it.'),
    PrintLines([
      for (var t = 0; t < tieup.length; t++) PrintLine(shafts(tieup[t]), label: 'Treadle ${t + 1}'),
    ]),
  ];
}

List<PrintBlock> _treadlingBlocks(
  DraftDoc doc, {
  required UseTabbyBook? book,
  required UseTabbyReading reading,
  required List<ShuttleSide?> starts,
}) {
  final treadled = doc.drive is DraftTreadled;
  final hasShuttles = doc.pickShuttles.isNotEmpty;
  final arrows = hasShuttles
      ? ' Arrows give the direction of each pass as you sit at the loom with end 1 at your right: '
          '← right to left, → left to right.'
      : '';
  if (book != null) {
    return [
      PrintParagraph('Use tabby: these rows list the pattern picks only. '
          '${useTabbyInstruction(book)} Each row gives the ${treadled ? 'treadle' : 'shafts'}, how '
          'many pattern picks to weave on it (for example ×4), and the picks of the full draft it '
          'covers, tabby picks included.$arrows'),
      PrintLines([
        for (final (i, row) in book.rows.indexed)
          PrintLine(useTabbyRowText(doc, book, row, starts), label: 'Row ${i + 1}'),
      ]),
    ];
  }
  final entries = treadlingEntries(doc.drive.rows, doc.shotGroups);
  final showReason = reading is UseTabbyUnavailable &&
      doc.pickRoles.any((r) => r == PickRole.pattern || r == PickRole.tabby);
  return [
    PrintParagraph('Every pick in order from pick 1. Each row is a run of consecutive picks '
        '${treadled ? 'on the same treadles' : 'raising the same shafts'}; ×3 means three picks, '
        'with a shed change between them.'
        '${doc.shotGroups.isNotEmpty ? ' A shot group (double shot, triple shot) is passes in one '
            'shed: $kShotGroupCatch' : ''}$arrows'),
    if (showReason)
      PrintParagraph('Use tabby shorthand is not available: ${_lowerFirst(reading.reason)}',
          style: PrintTextStyle.muted),
    PrintLines([
      for (final (i, e) in entries.indexed)
        PrintLine(weaveEntryText(doc, e, starts), label: 'Row ${i + 1}'),
    ]),
  ];
}

List<PrintLegendEntry> _draftKey(
  DraftDoc doc, {
  required BookCorner corner,
  required bool sinkingTieup,
  required List<String> roles,
  required List<PrintPass> passes,
  required bool brackets,
  required List<String> edges,
}) {
  final treadled = doc.drive is DraftTreadled;
  final letters = roles.toSet();
  final multi = doc.drive.rows.any((r) => r.length > 1);
  return [
    const PrintLegendEntry(
        code: '',
        name: 'Threading',
        meaning: 'The end is threaded on this shaft.',
        mark: PrintMark.filled),
    if (treadled)
      PrintLegendEntry(
        code: '',
        name: 'Tie-up',
        meaning: sinkingTieup
            ? 'Pressing the treadle lowers this shaft. The shafts without an X rise.'
            : 'Pressing the treadle raises this shaft.',
        mark: sinkingTieup ? PrintMark.cross : PrintMark.filled,
      ),
    PrintLegendEntry(
      code: '',
      name: treadled ? 'Treadling' : 'Lift plan',
      meaning: treadled
          ? 'Press this treadle for the pick.${multi ? ' Two marks in a row: press both together.' : ''}'
          : 'Raise this shaft for the pick.',
      mark: PrintMark.filled,
    ),
    const PrintLegendEntry(
        code: '',
        name: 'Warp on top',
        meaning: 'A black square in the drawdown: the warp end shows at this crossing.',
        mark: PrintMark.solid),
    const PrintLegendEntry(
        code: '',
        name: 'Weft on top',
        meaning: 'A white square in the drawdown: the weft shows at this crossing.',
        mark: PrintMark.empty),
    if (letters.contains('P'))
      const PrintLegendEntry(code: 'P', name: 'Pattern pick', meaning: 'A pick of pattern weft.'),
    if (letters.contains('T'))
      const PrintLegendEntry(
          code: 'T', name: 'Tabby pick', meaning: 'A plain-weave pick that binds the pattern.'),
    if (letters.contains('U'))
      const PrintLegendEntry(
          code: 'U',
          name: 'Top layer pick',
          meaning: 'A pick of the top (upper) layer of a double weave.'),
    if (letters.contains('L'))
      const PrintLegendEntry(
          code: 'L',
          name: 'Bottom layer pick',
          meaning: 'A pick of the bottom (lower) layer of a double weave.'),
    if (letters.contains('') && letters.length > 1)
      const PrintLegendEntry(
          code: '', name: 'No letter', meaning: 'No role is recorded for this pick.'),
    if (passes.isNotEmpty) ...[
      const PrintLegendEntry(
          code: '1',
          name: 'Shuttle',
          meaning: 'The shuttle that carries the pick. A number with no arrow: Ply does not know '
              'the direction of that pass.'),
      if (corner.mirrorX)
        const PrintLegendEntry(
            code: '← →',
            name: 'Pass direction',
            meaning: 'The way the pass goes on this mirror-image picture. In Ply\'s left and right '
                '(end 1 at the weaver\'s right) each arrow points the other way.')
      else ...[
        const PrintLegendEntry(
            code: '←',
            name: 'Right to left',
            meaning: 'The pass goes from right to left, as you sit at the loom.'),
        const PrintLegendEntry(
            code: '→',
            name: 'Left to right',
            meaning: 'The pass goes from left to right, as you sit at the loom.'),
      ],
      if (passes.any((p) => p.shuttle == null))
        const PrintLegendEntry(
            code: '?', name: 'Shuttle unknown', meaning: 'No shuttle is recorded for this pick.'),
    ],
    if (brackets)
      const PrintLegendEntry(
        code: '',
        name: 'Shot group',
        meaning: 'The bracketed picks are one shot group, labelled double shot (2 passes) or '
            'triple shot (3 passes).',
        notes: [kShotGroupCatch],
        mark: PrintMark.bracket,
      ),
    if (edges.contains('Fold'))
      const PrintLegendEntry(
          code: 'Fold',
          name: 'Fold edge',
          meaning: 'At this edge the weft passes from one layer to the other: the fold of the '
              'double-width cloth.'),
    if (edges.contains('Open'))
      const PrintLegendEntry(
          code: 'Open',
          name: 'Open edge',
          meaning: 'At this edge each layer turns back into itself, so each has its own '
              'selvedge.'),
    if (edges.contains('Joined'))
      const PrintLegendEntry(
          code: 'Joined',
          name: 'Joined edge',
          meaning: 'At this edge the weft passes from one layer to the other, closing the tube.'),
  ];
}

// --- helpers ---------------------------------------------------------------------------------------

/// [n] threads in lines of ten: "Ends 1 to 10: 1, 3, 1, ...".
List<PrintLine> _groupsOfTen(int n, String noun, String Function(int) token) => [
      for (var i = 0; i < n; i += 10)
        PrintLine(
          [for (var k = i; k < math.min(n, i + 10); k++) token(k)].join(', '),
          label: math.min(n, i + 10) - i == 1
              ? '$noun ${i + 1}'
              : '${noun}s ${i + 1} to ${math.min(n, i + 10)}',
        ),
    ];

int _warpAt(DraftDoc doc, int e) => e < doc.warpColors.length ? doc.warpColors[e] : 0;
int _weftAt(DraftDoc doc, int p) => p < doc.weftColors.length ? doc.weftColors[p] : 0;

/// A palette color; an index past the palette is white, as the engine draws it.
PrintColor _paletteColor(DraftDoc doc, int i) {
  if (i < 0 || i >= doc.palette.length) return const PrintColor(255, 255, 255);
  final c = doc.palette[i];
  return PrintColor(c.r, c.g, c.b);
}

String _colorName(DraftDoc doc, int i) => 'Color ${i + 1} (${_paletteColor(doc, i).hex})';

final _where = RegExp(r'^(pick|end|treadle|shaft) (\d+)\b', caseSensitive: false);

PrintIssue _issue(DraftIssue i) {
  final m = _where.firstMatch(i.message);
  return PrintIssue(
    severity: switch (i.severity) {
      IssueSeverity.error => PrintIssueSeverity.error,
      IssueSeverity.warning => PrintIssueSeverity.warning,
      IssueSeverity.info => PrintIssueSeverity.note,
    },
    where: m == null ? 'Whole draft' : '${_upperFirst(m[1]!.toLowerCase())} ${m[2]}',
    message: _upperFirst(i.message),
  );
}

String _upperFirst(String s) => s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';
String _lowerFirst(String s) => s.isEmpty ? s : '${s[0].toLowerCase()}${s.substring(1)}';

String _count(int n, String noun) => n == 1 ? '1 $noun' : '$n ${noun}s';

/// " ×3" after a shed worked [n] times; nothing for once.
String _times(int n) => n == 1 ? '' : ' ×$n';

String _and(List<String> items) => items.length <= 1
    ? items.join()
    : '${items.sublist(0, items.length - 1).join(', ')} and ${items.last}';

String _thousands(int n) =>
    n.toString().replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+$)'), (m) => '${m[1]},');

// ---------------------------------------------------------------------------------------------------
// The flow
// ---------------------------------------------------------------------------------------------------

/// The layout chosen for printed book drafts this session (the print sheet's choice; the default is
/// Ply's editor layout, so printing needs no extra tap).
final weavePrintCornerProvider = StateProvider<BookCorner>((_) => BookCorner.topRight);

/// The layout choice shown in the Print / Share sheet for a weaving draft.
class BookLayoutChoice extends ConsumerWidget {
  const BookLayoutChoice({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final corner = ref.watch(weavePrintCornerProvider);
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Book draft layout', style: theme.textTheme.labelLarge),
          DropdownButton<BookCorner>(
            key: const ValueKey('book-layout'),
            isExpanded: true,
            value: corner,
            items: [
              for (final c in BookCorner.values)
                DropdownMenuItem(value: c, child: Text(bookLayoutLabel(c))),
            ],
            onChanged: (c) {
              if (c != null) ref.read(weavePrintCornerProvider.notifier).state = c;
            },
          ),
          Text(bookLayoutHint(corner), style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}

/// Run the print-or-share flow for the weaving editor's open draft (unsaved edits included), shown as
/// [name]; [credit] is the author saved with the draft in Ply, if any.
Future<void> printOrShareWeavePdf(
  BuildContext context,
  WidgetRef ref, {
  required String name,
  String? credit,
}) {
  // Read everything from providers now: the flow has async gaps, and the screen may be gone after.
  final repo = ref.read(repositoryProvider);
  final state = ref.read(draftEditorProvider);
  final doc = state.draft;
  final sourceWif = state.sourceWif;
  final container = ProviderScope.containerOf(context, listen: false);
  return printOrSharePdf(
    context,
    ref,
    noun: 'draft',
    options: const BookLayoutChoice(),
    prepare: () async {
      final corner = container.read(weavePrintCornerProvider);
      final source =
          await gatherWeavePrint(repo, name: name, doc: doc, sourceWif: sourceWif, credit: credit);
      return PdfExportJob(
        fileStem: name,
        errors: weavePrintErrors(source),
        document: ({required withProblemsBox}) =>
            buildWeavePrintDocument(source, withProblemsBox: withProblemsBox, corner: corner),
      );
    },
  );
}
