import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart' show PdfPageFormat;
import 'package:ply/src/models/draft_doc.dart';
import 'package:ply/src/print/book_draft_layout.dart';
import 'package:ply/src/print/pdf_builder.dart';
import 'package:ply/src/print/print_document.dart';
import 'package:ply/src/print/print_layout.dart';
import 'package:ply/src/print/weave_print.dart';

import 'print_test_support.dart';
import 'weave_print_test_support.dart';

// The real PDF of a printed weaving draft, read back: pages, paper, the words and numbers on them,
// the book draft's captions and parts, the layouts, and a large draft's size and build time.

Future<PrintDocument> _doc(DraftDoc doc, {BookCorner corner = BookCorner.topRight}) async =>
    buildWeavePrintDocument(
        await gatherWeavePrint(FakeWeaveRepo(),
            name: doc.name, doc: doc, now: DateTime(2026, 11, 13)),
        withProblemsBox: false,
        corner: corner);

Future<PdfReadBack> _read(PrintDocument d, {MeasureUnit unit = MeasureUnit.centimeters}) async =>
    PdfReadBack(await buildPrintPdf(d,
        page: PrintPageSetup.forUnit(unit), fonts: testFonts(), compress: false));

/// The number of pages of a (possibly compressed) Ply PDF: page dictionaries are never compressed.
int _pages(Uint8List bytes) => RegExp(r'/Type\s*/Page[^s]').allMatches(latin1.decode(bytes)).length;

void main() {
  test('a small draft prints on A4 or US Letter with its book draft whole on one page', () async {
    final d = await _doc(aw2Doc());
    final a4 = await _read(d);
    expect(a4.mediaBoxes.first,
        [0, 0, closeTo(PdfPageFormat.a4.width, 0.01), closeTo(PdfPageFormat.a4.height, 0.01)]);
    expect(a4.pageCount, inInclusiveRange(3, 5));
    expect(a4.pages.first, contains('Shadow weave (Atwater)'));
    expect(a4.pages.first, contains('Weaving draft'));
    expect(a4.text, contains('Ends 1 to 22, picks 1 to 22'));
    expect(a4.text, isNot(contains('Part 1 of')));
    expect(a4.text, contains('Page 1 of ${a4.pageCount}'));
    // Every shaft, end, treadle and pick number is printed on the grid (5 mm cells hold them all),
    // read back in drawing order.
    final draftPage = a4.pages.firstWhere((p) => p.contains('Ends 1 to 22, picks 1 to 22'));
    final all22 = [for (var i = 1; i <= 22; i++) i].join(' ');
    expect(draftPage, contains('1 2 3 4 $all22 1 2 3 4 $all22'));
    final letter = await _read(d, unit: MeasureUnit.inches);
    expect(letter.mediaBoxes.first[2], closeTo(PdfPageFormat.letter.width, 0.01));
  });

  test('overshot prints USE TABBY and the pattern-only grid', () async {
    final r = await _read(await _doc(overshotDoc()));
    expect(r.text, contains('USE TABBY'));
    expect(r.text, contains('Weave one tabby pick after every pattern pick.'));
    expect(r.text, contains('Ends 1 to 16, picks 1 to 15 (pattern picks only)'));
    expect(r.text, contains('Row 1: Treadle 1 ×2, picks 1 to 3. Pattern weft color 2.'));
  });

  test('double width: fold and open edges, layer letters and pass arrows that follow the picture',
      () async {
    final doc = doubleWeaveDoc('double-width-fold-left', LayerConstruction.doubleWidthFoldLeft);
    final plain = await _read(await _doc(doc));
    expect(plain.text, contains('Fold'));
    expect(plain.text, contains('Open'));
    // Roles then passes, pick 1 first: a top-layer pick on shuttle 1 going right to left, and the
    // passes alternate; then the edge labels.
    expect(plain.text, contains('U L L U U L L U 1 ← 1 → 1 ← 1 → 1 ← 1 → 1 ← 1 → Fold Open'));
    final mirrored = await _read(await _doc(doc, corner: BookCorner.topLeft));
    expect(mirrored.text, contains('U L L U U L L U 1 → 1 ← 1 → 1 ← 1 → 1 ← 1 → 1 ←'),
        reason: 'mirror image: the arrows follow the picture');
    expect(
        mirrored.text, contains('This layout is the mirror image of the cloth as Ply records it'));
    expect(mirrored.text, contains('The arrows and edge labels on the grids follow the picture.'));
    // The written directions keep Ply's left and right in every layout.
    expect(mirrored.text, contains('Shuttle 1, right to left (←)'));
  });

  test('every layout builds, with the same captions and the layout named', () async {
    for (final c in BookCorner.values) {
      final r = await _read(await _doc(aw2Doc(), corner: c));
      expect(r.text, contains('Ends 1 to 22, picks 1 to 22'), reason: c.name);
      expect(r.text, contains('Layout: ${bookLayoutLabel(c)}'));
    }
  });

  test('a draft too large for one page splits into captioned parts that repeat the numbers',
      () async {
    final doc = largeDoc(ends: 120, picks: 150, shafts: 8);
    final r = await _read(await _doc(doc));
    final captions = RegExp(r'Part (\d+) of (\d+): ends (\d+) to (\d+), picks (\d+) to (\d+)')
        .allMatches(r.text)
        .toList();
    expect(captions, isNotEmpty);
    final book = captions.where((m) => m[2] == captions.first[2]).toList();
    final n = int.parse(book.first[2]!);
    expect([for (final m in book) int.parse(m[1]!)], [for (var i = 1; i <= n; i++) i]);
    expect((book.first[3], book.first[5]), ('1', '1'), reason: 'part 1 holds end 1 and pick 1');
    // Every part repeats the shaft numbers, the treadle numbers and its own pick numbers: the page
    // of part 2 starts its pick numbers at 1 again (same band of picks, next ends).
    final part2 = r.pages.firstWhere((p) => p.contains('Part 2 of $n:'));
    final m2 = RegExp(r'Part 2 of \d+: ends (\d+) to (\d+), picks 1 to (\d+)').firstMatch(part2)!;
    expect(int.parse(m2[1]!), int.parse(book.first[4]!) + 1, reason: 'the next ends');
    expect(part2, contains(' 1 2 3 4 5 6 7 8 '), reason: 'shaft or treadle numbers again');
  });

  test('a tie-up too big for the page is said, not shrunk; the directions still print', () async {
    const shafts = 120;
    final doc = DraftDoc.blank(shafts: shafts, treadles: 0, name: 'Wide dobby').copyWith(
      threading: [
        for (var e = 0; e < 40; e++) [e % shafts + 1],
      ],
      drive: DraftLiftplan(liftplan: [
        for (var p = 0; p < 10; p++) [p + 1, p + 2],
      ]),
      warpColors: List.filled(40, 0),
      weftColors: List.filled(10, 1),
    );
    final r = await _read(await _doc(doc));
    expect(r.text, contains('This draft is too large for a book draft on this paper'));
    expect(r.text, contains('Lift plan'));
    expect(r.text, contains('Row 1: Shafts 1 + 2, pick 1. Weft color 2.'));
  });

  test('a large draft (400 ends x 1000 picks, 16 shafts) prints within budget', () async {
    final doc = largeDoc();
    final sw = Stopwatch()..start();
    final source = await gatherWeavePrint(FakeWeaveRepo(), name: 'Large twill', doc: doc);
    final gathered = sw.elapsedMilliseconds;
    final d = buildWeavePrintDocument(source, withProblemsBox: false);
    final built = sw.elapsedMilliseconds;
    final bytes = await buildPrintPdf(d,
        page: PrintPageSetup.forUnit(MeasureUnit.centimeters), fonts: testFonts());
    final pdf = sw.elapsedMilliseconds;
    final pages = _pages(bytes);
    // ignore: avoid_print
    print('large draft 400x1000x16: gather ${gathered}ms, document ${built - gathered}ms, '
        'PDF ${pdf - built}ms, ${(bytes.length / 1048576).toStringAsFixed(2)} MB, $pages pages');
    expect(bytes.length, lessThan(16 * 1024 * 1024));
    expect(pages, greaterThan(100));
    // The book draft parts are exactly what the layout says for A4.
    final a4 = PrintPageSetup.forUnit(MeasureUnit.centimeters);
    final layout = layoutBookDraft(
        ends: 400,
        rows: 1000,
        shafts: 16,
        columns: 16,
        width: a4.contentWidth,
        height: a4.contentHeight);
    expect(layout.cell, 3 * kMm);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
