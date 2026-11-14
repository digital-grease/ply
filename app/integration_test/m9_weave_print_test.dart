// M9-02 device proof: printable WEAVING PDFs against the REAL engine. The interlacement the PDF
// draws is read off the engine (one pixel per crossing, warp black, weft white) and must equal each
// fixture's verified oracle; then the whole PDF is built (no system dialog) and read back: the book
// draft's caption and numbers, Use tabby for a generated overshot (its printed working order expands
// to exactly the draft's picks, on a rising and a sinking shed), the Atwater shadow weave, and the
// double-width cloth's layer letters, pass arrows and fold / open edge labels.
//
// The fixtures' WIF text and oracles are embedded (a device test cannot read the repo's files); they
// are the tracked files fixtures/weaving/shadow/aw2-atwater-4-point.* and
// fixtures/weaving/doubleweave/double-width-fold-left.*, copied verbatim.
//
//   flutter test integration_test/m9_weave_print_test.dart -d emulator-5554

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:ply/src/data/draft_repository.dart';
import 'package:ply/src/models/draft_doc.dart';
import 'package:ply/src/models/draft_meta.dart';
import 'package:ply/src/models/use_tabby.dart';
import 'package:ply/src/print/pdf_builder.dart';
import 'package:ply/src/print/pdf_fonts.dart';
import 'package:ply/src/print/print_document.dart';
import 'package:ply/src/print/print_layout.dart';
import 'package:ply/src/print/weave_print.dart';
import 'package:ply/src/rust/dto.dart' show StructureFamily, ThreadingKind;
import 'package:ply/src/rust/frb_generated.dart';

import '../test/print/print_test_support.dart' show PdfReadBack;
import '../test/print/weave_print_test_support.dart'
    show expandPrintedTreadling, referenceInterlacement;

const String kAw2Wif = r'''[WIF]
Version=1.1
Developers=ply
Source Program=Ply

[TEXT]
Title=Shadow weave (Atwater)

[NOTES]
1=Atwater shadow weave on 4 shafts.
2=Threading: point of A2 B1 C1 D2, then mirrored back, 22 ends per repeat.
3=Treadling: as drawn in.
4=Tie-up: standard twill direction.
5=Colors: warp and weft alternate dark and light, both starting dark (smooth block edges).
6=Size: 1 repeat across and 1 repeat up: 22 ends x 22 picks.

[CONTENTS]
TEXT=true
NOTES=true
COLOR PALETTE=true
COLOR TABLE=true
WEAVING=true
WARP=true
WEFT=true
THREADING=true
TIEUP=true
TREADLING=true
WARP COLORS=true
WEFT COLORS=true

[WEAVING]
Shafts=4
Treadles=4
Rising Shed=true

[WARP]
Threads=22
Units=Inches

[WEFT]
Threads=22
Units=Inches

[COLOR PALETTE]
Entries=2
Form=RGB
Range=255

[COLOR TABLE]
1=219,219,219
2=45,45,45

[THREADING]
1=1
2=3
3=1
4=3
5=2
6=4
7=3
8=1
9=4
10=2
11=4
12=2
13=4
14=2
15=4
16=1
17=3
18=4
19=2
20=3
21=1
22=3

[TIEUP]
1=1,2
2=2,3
3=3,4
4=1,4

[TREADLING]
1=1
2=3
3=1
4=3
5=2
6=4
7=3
8=1
9=4
10=2
11=4
12=2
13=4
14=2
15=4
16=1
17=3
18=4
19=2
20=3
21=1
22=3

[WARP COLORS]
1=2
2=1
3=2
4=1
5=2
6=1
7=2
8=1
9=2
10=1
11=2
12=1
13=2
14=1
15=2
16=1
17=2
18=1
19=2
20=1
21=2
22=1

[WEFT COLORS]
1=2
2=1
3=2
4=1
5=2
6=1
7=2
8=1
9=2
10=1
11=2
12=1
13=2
14=1
15=2
16=1
17=2
18=1
19=2
20=1
21=2
22=1
''';

const String kDoubleWidthLeftWif = r'''[WIF]
Version=1.1
Developers=ply
Source Program=Ply

[TEXT]
Title=Double width

[CONTENTS]
TEXT=true
COLOR PALETTE=true
COLOR TABLE=true
WEAVING=true
WARP=true
WEFT=true
THREADING=true
TIEUP=true
TREADLING=true
WARP COLORS=true
WEFT COLORS=true
PRIVATE PLY PICKS=true

[WEAVING]
Shafts=4
Treadles=4
Rising Shed=true

[WARP]
Threads=12
Units=Inches

[WEFT]
Threads=8
Units=Inches

[COLOR PALETTE]
Entries=2
Form=RGB
Range=255

[COLOR TABLE]
1=40,70,130
2=205,130,60

[THREADING]
1=1
2=2
3=3
4=4
5=1
6=2
7=3
8=4
9=1
10=2
11=3
12=4

[TIEUP]
1=1
2=1,2,3
3=3
4=1,3,4

[TREADLING]
1=1
2=2
3=4
4=3
5=1
6=2
7=4
8=3

[WARP COLORS]
1=1
2=2
3=1
4=2
5=1
6=2
7=1
8=2
9=1
10=2
11=1
12=2

[WEFT COLORS]
1=1
2=1
3=1
4=1
5=1
6=1
7=1
8=1

[PRIVATE PLY PICKS]
Version=2
Picks=8
Sheds=95f0c9bec78503a5
Construction=double-width, fold left
Shuttle 1 Start=right
1=role top-layer, shuttle 1
2=role bottom-layer, shuttle 1
3=role bottom-layer, shuttle 1
4=role top-layer, shuttle 1
5=role top-layer, shuttle 1
6=role bottom-layer, shuttle 1
7=role bottom-layer, shuttle 1
8=role top-layer, shuttle 1
''';

/// fixtures/weaving/shadow/aw2-atwater-4-point.expect.json "interlacement": one string per pick,
/// end 1 first, X = warp on top.
const List<String> kAw2Oracle = [
  'X.X.X..X.X.X.X.X..X.X.',
  '.X.X.XX.X.X.X.X.XX.X.X',
  'X.X.X..X.X.X.X.X..X.X.',
  '.X.X.XX.X.X.X.X.XX.X.X',
  '.X.XX.X..X.X.X..X.XX.X',
  'X.X..X.XX.X.X.XX.X..X.',
  '.X.X.XX.X.X.X.X.XX.X.X',
  'X.X.X..X.X.X.X.X..X.X.',
  'X.X..X.XX.X.X.XX.X..X.',
  '.X.XX.X..X.X.X..X.XX.X',
  'X.X..X.XX.X.X.XX.X..X.',
  '.X.XX.X..X.X.X..X.XX.X',
  'X.X..X.XX.X.X.XX.X..X.',
  '.X.XX.X..X.X.X..X.XX.X',
  'X.X..X.XX.X.X.XX.X..X.',
  'X.X.X..X.X.X.X.X..X.X.',
  '.X.X.XX.X.X.X.X.XX.X.X',
  'X.X..X.XX.X.X.XX.X..X.',
  '.X.XX.X..X.X.X..X.XX.X',
  '.X.X.XX.X.X.X.X.XX.X.X',
  'X.X.X..X.X.X.X.X..X.X.',
  '.X.X.XX.X.X.X.X.XX.X.X',
];

/// fixtures/weaving/doubleweave/double-width-fold-left.expect.json "interlacement".
const List<String> kDoubleWidthLeftOracle = [
  'X...X...X...',
  'XXX.XXX.XXX.',
  'X.XXX.XXX.XX',
  '..X...X...X.',
  'X...X...X...',
  'XXX.XXX.XXX.',
  'X.XXX.XXX.XX',
  '..X...X...X.',
];

Uint8List _oracle(List<String> rows) {
  final ends = rows.first.length;
  final out = Uint8List(ends * rows.length);
  for (var p = 0; p < rows.length; p++) {
    for (var e = 0; e < ends; e++) {
      if (rows[p][e] == 'X') out[p * ends + e] = 1;
    }
  }
  return out;
}

PrintSection _section(PrintDocument d, String heading) =>
    d.sections.firstWhere((s) => s.heading == heading);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late PlyPdfFonts fonts;
  setUpAll(() async {
    await RustLib.init();
    fonts = await PlyPdfFonts.load();
  });

  Future<PdfReadBack> pdf(PrintDocument d) async => PdfReadBack(await buildPrintPdf(d,
      page: PrintPageSetup.forUnit(MeasureUnit.centimeters), fonts: fonts, compress: false));

  testWidgets('a generated overshot prints Use tabby that weaves exactly its picks',
      (tester) async {
    final repo = DraftRepository();
    for (final shed in Shed.values) {
      final doc = await repo.generateStructureDoc(
        DraftDoc.blank().copyWith(shed: shed),
        family: StructureFamily.overshot,
        threading: ThreadingKind.straight,
        shafts: 4,
        over: 2,
        under: 2,
        counter: 2,
        ends: 16,
        picks: 8,
      );
      expect(readUseTabby(doc), isA<UseTabbyBook>(), reason: shed.name);
      final source = await gatherWeavePrint(repo, name: 'Overshot', doc: doc);
      expect(source.drawdownError, isNull);
      expect(source.colorsError, isNull);
      // The engine's interlacement agrees with the Dart twin of raised_shafts on every crossing.
      expect(source.interlacement, referenceInterlacement(doc), reason: shed.name);
      expect(weavePrintErrors(source), isEmpty);
      final d = buildWeavePrintDocument(source, withProblemsBox: false);
      final treadled = doc.drive is DraftTreadled;
      final treadling = _section(d, treadled ? 'Treadling' : 'Lift plan');
      expect((treadling.blocks.first as PrintParagraph).text, startsWith('Use tabby:'));
      expect(expandPrintedTreadling(treadling, treadled: treadled), doc.drive.rows,
          reason: '${shed.name}: printed Use tabby directions = the expanded picks');
      final grid = _section(d, 'Use tabby').blocks.whereType<PrintBookDraft>().single;
      expect(grid.pickNumbers, [1, 3, 5, 7]);
      if (treadled) {
        expect(grid.tieupMark, shed == Shed.sinking ? PrintMark.cross : PrintMark.filled);
      }
      final r = await pdf(d);
      expect(r.text, contains('USE TABBY'));
      expect(r.text, contains('Ends 1 to 16, picks 1 to 8'));
      expect(r.text, contains('Ends 1 to 16, picks 1 to 7 (pattern picks only)'));
      expect(r.text, contains('P T P T P T P T'));
    }
  });

  testWidgets('the Atwater shadow weave prints the engine interlacement and its source',
      (tester) async {
    final repo = DraftRepository();
    final doc = await repo.parseDoc(kAw2Wif);
    final source = await gatherWeavePrint(repo,
        name: doc.name, doc: doc, sourceWif: kAw2Wif, credit: 'Ply fixtures');
    expect(source.interlacement, _oracle(kAw2Oracle));
    expect(weavePrintErrors(source), isEmpty);
    for (final corner in BookCorner.values) {
      final d = buildWeavePrintDocument(source, withProblemsBox: false, corner: corner);
      final book = _section(d, 'Draft').blocks.whereType<PrintBookDraft>().single;
      expect(book.drawdown, _oracle(kAw2Oracle));
      final r = await pdf(d);
      expect(r.pages.first, contains('Shadow weave (Atwater)'));
      expect(r.text, contains('Written by Ply'));
      expect(r.text, contains('Credit Ply fixtures'));
      expect(r.text, contains('Ends 1 to 22, picks 1 to 22'));
      expect(r.text, contains('Layout: ${bookLayoutLabel(corner)}'));
      expect(r.text, contains('Row 1: Treadle 1, pick 1. Weft color 2.'));
    }
  });

  testWidgets('double width prints its layers, passes and fold / open edges', (tester) async {
    final repo = DraftRepository();
    final doc = await repo.parseDoc(kDoubleWidthLeftWif);
    expect(doc.construction, LayerConstruction.doubleWidthFoldLeft);
    final source = await gatherWeavePrint(repo, name: doc.name, doc: doc);
    expect(source.interlacement, _oracle(kDoubleWidthLeftOracle));
    final d = buildWeavePrintDocument(source, withProblemsBox: false);
    final book = _section(d, 'Draft').blocks.whereType<PrintBookDraft>().single;
    expect((book.highEndEdge, book.endOneEdge), ('Fold', 'Open'));
    final r = await pdf(d);
    expect(r.text, contains('U L L U U L L U 1 ← 1 → 1 ← 1 → 1 ← 1 → 1 ← 1 → Fold Open'));
    expect(r.text, contains('Construction: Double width, fold on the left.'));
    expect(
        r.text,
        contains(
            'This drawdown shows every intersection of both layers, not the face of the cloth.'));
    final mirrored = await pdf(
        buildWeavePrintDocument(source, withProblemsBox: false, corner: BookCorner.topLeft));
    expect(mirrored.text, contains('U L L U U L L U 1 → 1 ← 1 → 1 ← 1 → 1 ← 1 → 1 ←'));
  });

  testWidgets('a draft from another program keeps its author and origin through a save and reopen',
      (tester) async {
    // The AW-2 draft as another program would have written it: its own Source Program, an author
    // and a contact line in [TEXT].
    final foreign = kAw2Wif
        .replaceFirst(
            RegExp(r'Source Program=[^\r\n]*'), 'Source Program=Loomcraft\nSource Version=4.2')
        .replaceFirst('[TEXT]', '[TEXT]\nAuthor=A. Weaver\nEMail=a@example.org');
    expect(foreign, contains('Source Program=Loomcraft'));
    expect(foreign, contains('Author=A. Weaver'));
    final repo = DraftRepository();
    final doc = await repo.parseDoc(foreign);
    final meta = DraftMeta(name: doc.name, savedAt: DateTime.now(), lastOpened: DateTime.now());
    final id = await repo.saveDto(doc, meta: meta);
    addTearDown(() => repo.delete(id));
    final saved = await repo.readWif(id);
    expect(saved, contains('Source Program=Ply'), reason: 'the file names its real writer');
    expect(saved, contains('Author=A. Weaver'));
    expect(saved, contains('[PRIVATE PLY SOURCE]'));
    final reopened = await repo.parseDoc(saved);
    // An edit that changes the size keeps the credit (only per-thread data on a changed axis goes).
    final grown = await repo.resizeDoc(reopened, ends: 24, picks: 24, shafts: 4, treadles: 4);
    for (final draft in [reopened, grown]) {
      final source = await gatherWeavePrint(repo, name: draft.name, doc: draft, sourceWif: saved);
      expect((source.attribution.author, source.attribution.program, source.attribution.hasContact),
          ('A. Weaver', 'Loomcraft 4.2', true));
      final r = await pdf(buildWeavePrintDocument(source, withProblemsBox: false));
      expect(r.text, contains('Author A. Weaver'));
      expect(r.text, contains('Written by Loomcraft 4.2'));
      expect(r.text, isNot(contains('a@example.org')));
    }
  });
}
