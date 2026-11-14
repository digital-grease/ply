import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/draft_repository.dart';
import 'package:ply/src/models/double_weave_construction.dart' show constructionLabel;
import 'package:ply/src/models/draft_doc.dart';
import 'package:ply/src/models/draft_issue.dart';
import 'package:ply/src/models/drawdown_region.dart';
import 'package:ply/src/models/use_tabby.dart';
import 'package:ply/src/models/weft_work.dart' show passStarts;
import 'package:ply/src/print/print_document.dart';
import 'package:ply/src/print/weave_print.dart';
import 'package:ply/src/rust/api.dart' show PreviewImage;

import 'weave_print_test_support.dart';

// The printed WEAVING draft's content: the engine calls and their orientation, the title block and
// source attribution, materials and the color key, the book draft block (quadrants, numbers, roles,
// shuttles and passes, shot-group brackets, edge labels) in every layout, the reading words, sinking
// sheds and lift plans, Use tabby (proved exact by expanding the printed words back into picks), the
// written directions, what the PDF cannot show, and the problems box only for a draft with errors.

Future<WeavePrintSource> _source(DraftDoc doc,
        {FakeWeaveRepo? repo, String? wif, String? credit, String? name}) =>
    gatherWeavePrint(repo ?? FakeWeaveRepo(),
        name: name ?? doc.name,
        doc: doc,
        sourceWif: wif,
        credit: credit,
        now: DateTime(2026, 11, 13));

Future<PrintDocument> _doc(DraftDoc doc,
        {BookCorner corner = BookCorner.topRight,
        FakeWeaveRepo? repo,
        String? wif,
        String? credit,
        bool box = false}) async =>
    buildWeavePrintDocument(await _source(doc, repo: repo, wif: wif, credit: credit),
        withProblemsBox: box, corner: corner);

PrintSection? _section(PrintDocument d, String heading) {
  for (final s in d.sections) {
    if (s.heading == heading) return s;
  }
  return null;
}

List<T> _all<T>(PrintSection s) => s.blocks.whereType<T>().toList();

String _text(PrintDocument d) => d.allText.join('\n');

String _facts(PrintDocument d) =>
    [for (final f in d.titleFacts) '${f.label}: ${f.value}'].join('; ');

const _err = DraftIssue(
    severity: IssueSeverity.error, message: 'pick 3 presses treadle 9 which has no tie-up');
const _warn =
    DraftIssue(severity: IssueSeverity.warning, message: 'warp color count (5) != warp ends (4)');

List<List<int>> _sorted(List<List<int>> rows) => [
      for (final r in rows) [...r]..sort(),
    ];

void main() {
  group('gathering from the engine', () {
    test('reads the interlacement and colors once each, one pixel per crossing, whole draft',
        () async {
      final repo = FakeWeaveRepo();
      final s = await _source(aw2Doc(), repo: repo);
      expect(repo.renders, [(22, 22, 1), (22, 22, 1)]);
      expect(repo.validations, 1);
      // The engine draws the highest end in the left column; the source holds end 1 first, which
      // must equal the fixture's verified oracle exactly.
      expect(s.interlacement, oracleInterlacement(fixtureOracle('shadow/aw2-atwater-4-point')));
      // Colors: a dark warp end up on pick 1 shows dark (end 1 is dark and up on pick 1).
      expect(s.colors![0], 0x2D2D2D);
    });

    test('a draft wider or longer than one engine tile is read a tile at a time, exactly',
        () async {
      // 2500 ends by 1100 picks: wider than the engine draws in one render (8192 px a side is its
      // budget; Ply asks for at most kWeavePrintTileSide a side), so it is read in 3 x 2 tiles,
      // twice (interlacement, then colors), and must come back crossing for crossing.
      final doc = largeDoc(ends: 2500, picks: 700, shafts: 8);
      final repo = FakeWeaveRepo();
      final s = await _source(doc, repo: repo);
      const t = kWeavePrintTileSide;
      final tiles = [(t, t), (t, t), (2500 - 2 * t, t)];
      expect(t, 1024);
      expect(repo.renders, [
        for (var pass = 0; pass < 2; pass++) ...[
          for (final (w, _) in tiles) (w, 700, 1),
        ],
      ]);
      expect(s.interlacement, referenceInterlacement(doc));
      final whole = fakeEnginePixels(
          doc, DrawdownRegion(endStart: 0, endCount: doc.ends, pickStart: 0, pickCount: doc.picks));
      const p = 650, e = 2499; // a crossing in the last tile, model order
      final i = (p * doc.ends + (doc.ends - 1 - e)) * 4;
      expect(s.colors![p * doc.ends + e],
          (whole.rgba[i] << 16) | (whole.rgba[i + 1] << 8) | whole.rgba[i + 2]);
    });

    test('a draft longer than one tile is split by picks too', () async {
      final doc = largeDoc(ends: 30, picks: 2100, shafts: 4);
      final repo = FakeWeaveRepo();
      final s = await _source(doc, repo: repo);
      expect(repo.renders, [
        for (var pass = 0; pass < 2; pass++) ...[(30, 1024, 1), (30, 1024, 1), (30, 52, 1)],
      ]);
      expect(s.interlacement, referenceInterlacement(doc));
    });

    test('the double-width fixture reads back its own oracle (warp up where the oracle says X)',
        () async {
      final o = fixtureOracle('doubleweave/double-width-fold-left');
      final oracle = oracleInterlacement(o);
      final doc = doubleWeaveDoc('double-width-fold-left', LayerConstruction.doubleWidthFoldLeft);
      expect(referenceInterlacement(doc), oracle, reason: 'the fake engine agrees with the oracle');
      final s = await _source(doc, repo: FakeWeaveRepo(interlacement: oracle));
      expect(s.interlacement, oracle);
    });

    test('pixels are read in the engine orientation (end 1 is the rightmost column)', () async {
      // 3 ends x 2 picks: only end 1 of pick 1 and end 3 of pick 2 are black.
      final rgba = Uint8List(3 * 2 * 4)..fillRange(0, 24, 255);
      void black(int x, int y) => rgba.fillRange((y * 3 + x) * 4, (y * 3 + x) * 4 + 3, 0);
      black(2, 0); // rightmost column, top row = end 1, pick 1
      black(0, 1); // leftmost column, second row = end 3, pick 2
      final doc = largeDoc(ends: 3, picks: 2, shafts: 4);
      expect(
          await readInterlacement(
              _CannedPixels(PreviewImage(width: 3, height: 2, rgba: rgba)), doc),
          [1, 0, 0, 0, 0, 1]);
      // A picture of the wrong size is an error, never read as if it fit.
      expect(readInterlacement(_CannedPixels(PreviewImage(width: 2, height: 2, rgba: rgba)), doc),
          throwsStateError);
    });

    test('the interlacement is read from a black-and-white copy, never colored by the draft', () {
      final bw = blackWhiteDraft(aw2Doc().copyWith(weftThickness: List.filled(22, 2.0)));
      expect(bw.palette, const [DraftColor(r: 255, g: 255, b: 255), DraftColor(r: 0, g: 0, b: 0)]);
      expect(bw.warpColors, List.filled(22, 1));
      expect(bw.weftColors, List.filled(22, 0));
      expect(bw.weftThickness, isEmpty, reason: 'uniform cells');
      expect(bw.drive, aw2Doc().drive, reason: 'the same sheds, so the engine decides the cloth');
    });

    test('a draft over the print limits is refused before any engine call', () async {
      final repo = FakeWeaveRepo();
      final big = largeDoc(ends: 2001, picks: 1000, shafts: 4);
      await expectLater(
          _source(big, repo: repo),
          throwsA(isA<WeavePrintTooLarge>().having((e) => e.toString(), 'message',
              contains('This draft is too large to print: 2001 ends by 1000 picks'))));
      expect(repo.renders, isEmpty);
      expect(repo.validations, 0);
      expect(() => checkWeavePrintSize(largeDoc(ends: 400, picks: 1000)), returnsNormally);
    });

    test('an engine failure is printed as a notice; the grids and directions still print',
        () async {
      final d = await _doc(aw2Doc(), repo: FakeWeaveRepo(failRender: true));
      final draft = _section(d, 'Draft')!;
      expect(_all<PrintNotice>(draft).single.title, 'The drawdown could not be drawn');
      expect(_all<PrintBookDraft>(draft).single.drawdown, isNull);
      expect(_all<PrintBookDraft>(draft).single.threading, aw2Doc().threading);
      expect(_all<PrintNotice>(_section(d, 'Color drawdown')!).single.title,
          'The color drawdown could not be drawn');
      expect(_section(d, 'Threading'), isNotNull);
      final cannot = _all<PrintNotice>(_section(d, 'Problems')!).single;
      expect(cannot.lines,
          contains('The drawdown could not be drawn, so its squares are left empty.'));
    });
  });

  group('title block and source', () {
    test('the title block names the loom, size, shed and layout', () async {
      final d = await _doc(aw2Doc());
      expect(d.title, 'Shadow weave (Atwater)');
      expect(d.kind, 'Weaving draft');
      expect(_facts(d),
          'Printed: 2026-11-13; Loom: 4 shafts, 4 treadles; Size: 22 ends, 22 picks; Shed: Rising shed; Layout: Tie-up top right');
      final lift = await _doc(overshotDoc().copyWith(
          drive: DraftLiftplan(liftplan: const [
        [1, 2],
        [3]
      ])));
      expect(_facts(lift), contains('Loom: 4 shafts, lift plan'));
      final empty = await _doc(DraftDoc.blank(name: ''));
      expect(empty.title, 'Untitled draft');
      expect(_section(empty, 'Draft')!.blocks.single, isA<PrintParagraph>());
      expect((_section(empty, 'Draft')!.blocks.single as PrintParagraph).text,
          'This draft has no ends or picks yet.');
    });

    test('the source keeps the file\'s title, author and program, never its contact details',
        () async {
      const wif = '[WIF]\nVersion=1.1\nSource Program=Loomcraft\nSource Version=4.2\n'
          '[TEXT]\nTitle=Snail Trail\nAuthor=A. Weaver\nAddress=1 Loom Lane\nEMail=a@example.org\n'
          'Telephone=555 0100\n';
      final a = readWifAttribution(wif);
      expect((a.title, a.author, a.program, a.hasContact),
          ('Snail Trail', 'A. Weaver', 'Loomcraft 4.2', true));
      final d = await _doc(aw2Doc(), wif: wif, credit: 'Guild sample');
      final source = _section(d, 'Source')!;
      final facts = _all<PrintFacts>(source).single.facts;
      expect([
        for (final f in facts) '${f.label}: ${f.value}'
      ], [
        'Title in the file: Snail Trail',
        'Author: A. Weaver',
        'Written by: Loomcraft 4.2',
        'Credit: Guild sample',
      ]);
      expect(_all<PrintParagraph>(source).single.text,
          'The file also lists contact details, which Ply does not print.');
      final all = _text(d);
      for (final secret in ['1 Loom Lane', 'a@example.org', '555 0100']) {
        expect(all, isNot(contains(secret)));
      }
      // No file, no credit: no Source section.
      expect(_section(await _doc(overshotDoc()), 'Source'), isNull);
      // The fixture written by Ply credits Ply.
      final fixture = readWifAttribution(fixtureWif('shadow/aw2-atwater-4-point'));
      expect((fixture.title, fixture.author, fixture.program),
          ('Shadow weave (Atwater)', null, 'Ply'));
    });

    test('a draft Ply re-saved still credits its author and the program that first wrote it',
        () async {
      // What the engine keeps on reading another program's file and writes back on every save: the
      // [TEXT] lines beyond the Title, and the first program in Ply's private source section. The
      // file the editor opened is now Ply's own (its [WIF] names Ply, its [TEXT] has the Title and
      // the kept lines).
      const resaved = '[WIF]\nVersion=1.1\nSource Program=Ply\n'
          '[TEXT]\nTitle=Snail Trail\nAuthor=A. Weaver\nEMail=a@example.org\n'
          '[PRIVATE PLY SOURCE]\nSource Program=Loomcraft\nSource Version=4.2\n';
      final doc = aw2Doc().copyWith(retained: [
        RetainedSection(kWifTextSection, const [
          RetainedEntry('Author', 'A. Weaver'),
          RetainedEntry('EMail', 'a@example.org'),
        ]),
        RetainedSection('PRIVATE PLY SOURCE', const [
          RetainedEntry('Source Program', 'Loomcraft'),
          RetainedEntry('Source Version', '4.2'),
        ]),
      ]);
      expect(readWifAttribution(resaved).program, 'Loomcraft 4.2',
          reason: "Ply's record of the first program, not the latest writer");
      final d = await _doc(doc, wif: resaved);
      final source = _section(d, 'Source')!;
      expect([for (final f in _all<PrintFacts>(source).single.facts) '${f.label}: ${f.value}'],
          ['Title in the file: Snail Trail', 'Author: A. Weaver', 'Written by: Loomcraft 4.2']);
      expect(_all<PrintParagraph>(source).single.text,
          'The file also lists contact details, which Ply does not print.');
      expect(_text(d), isNot(contains('a@example.org')));
      // The credit is printed under Source, so it is not listed as data Ply does not print.
      expect(_text(d), isNot(contains('keeps but does not print')));

      // The draft alone (no file: generated, or the file is gone) still carries its credit.
      final a = weaveAttribution(doc);
      expect(
          (a.title, a.author, a.program, a.hasContact), (null, 'A. Weaver', 'Loomcraft 4.2', true));
      // Any other kept section is still named.
      final vendor = doc.copyWith(retained: [
        ...doc.retained,
        RetainedSection('LOOMCRAFT EXTRAS', const [RetainedEntry('Bobbins', '3')]),
      ]);
      expect(_text(await _doc(vendor)),
          contains('The file holds data Ply keeps but does not print: LOOMCRAFT EXTRAS.'));
    });
  });

  group('materials', () {
    test('a color key with swatch, number, hex and counts, and the color orders as text', () async {
      final d = await _doc(aw2Doc());
      final m = _section(d, 'Materials')!;
      final facts = [for (final f in _all<PrintFacts>(m).single.facts) '${f.label}: ${f.value}'];
      expect(facts, ['Warp: 22 ends', 'Weft: 22 picks', 'Colors: 2 colors']);
      final key = _all<PrintLegend>(m).single.entries;
      expect([
        for (final e in key) (e.code, e.name, e.meaning, e.swatch?.hex)
      ], [
        ('1', 'Color 1', '#DBDBDB. Warp: 11 ends. Weft: 11 picks.', '#DBDBDB'),
        ('2', 'Color 2', '#2D2D2D. Warp: 11 ends. Weft: 11 picks.', '#2D2D2D'),
      ]);
      final lines = _all<PrintLines>(m);
      expect([
        for (final l in lines.first.lines) '${l.label}: ${l.text}'
      ], [
        'Ends 1 to 10: 2, 1, 2, 1, 2, 1, 2, 1, 2, 1',
        'Ends 11 to 20: 2, 1, 2, 1, 2, 1, 2, 1, 2, 1',
        'Ends 21 to 22: 2, 1',
      ]);
      expect(lines.last.lines.first.label, 'Picks 1 to 10');
    });

    test('a color past the palette is said, and drawn white as the engine draws it', () async {
      final doc = aw2Doc().copyWith(warpColors: [5, ...List.filled(21, 0)]);
      final key = _all<PrintLegend>(_section(await _doc(doc), 'Materials')!).single.entries;
      final six = key.firstWhere((e) => e.code == '6');
      expect(
          six.meaning, 'Not in the palette, so Ply draws it white. Warp: 1 end. Not in the weft.');
      expect(six.swatch!.hex, '#FFFFFF');
    });

    test('shuttles, strands, thickness and construction are listed when the draft records them',
        () async {
      final doc = doubleWeaveDoc('double-width-fold-left', LayerConstruction.doubleWidthFoldLeft)
          .copyWith(pickStrands: [2, 1, 1, 1, 1, 1, 1, 1], warpThickness: List.filled(12, 1.5));
      final facts = [
        for (final f in _all<PrintFacts>(_section(await _doc(doc), 'Materials')!).single.facts)
          '${f.label}: ${f.value}',
      ];
      expect(
          facts,
          containsAll([
            'Shuttles: Shuttle 1 starts from the right',
            'Strands: Some picks carry several strands together, see Treadling',
            'Thickness: Recorded for 12 ends and 0 picks; not drawn',
            'Construction: Double width, fold on the left',
          ]));
    });
  });

  group('the book draft', () {
    test('carries the quadrants, the engine drawdown and one row per pick', () async {
      final doc = aw2Doc();
      final s = await _source(doc);
      final b = _all<PrintBookDraft>(
              _section(buildWeavePrintDocument(s, withProblemsBox: false), 'Draft')!)
          .single;
      expect((b.ends, b.shafts, b.columns, b.rows), (22, 4, 4, 22));
      expect(b.threading, doc.threading);
      expect(b.tieup, (doc.drive as DraftTreadled).tieup);
      expect(b.tieupMark, PrintMark.filled);
      expect(b.treadling, doc.drive.rows);
      expect(b.pickNumbers, [for (var p = 1; p <= 22; p++) p]);
      expect(b.drawdown, s.interlacement);
      expect(b.roles, isEmpty);
      expect(b.passes, isEmpty);
      expect(b.brackets, isEmpty);
      expect((b.highEndEdge, b.endOneEdge), (null, null));
      expect(b.corner, BookCorner.topRight);
    });

    test('every layout prints the same draft, and says where each 1 is', () async {
      final expected = {
        BookCorner.topRight: [
          'The threading runs along the top with the tie-up at the top right.',
          'End 1 is the right-hand column of the threading, so read the threading from right to left.',
          'Shaft 1 is the bottom row of the threading and of the tie-up, the row next to the drawdown.',
          'Treadle 1 is the left-hand column of the tie-up and of the treadling.',
          'Pick 1 is the top row of the treadling and of the drawdown, so read the treadling from the top down.',
        ],
        BookCorner.topLeft: [
          'The threading runs along the top with the tie-up at the top left.',
          'End 1 is the left-hand column of the threading, so read the threading from left to right.',
          'Treadle 1 is the right-hand column of the tie-up and of the treadling.',
          'This layout is the mirror image of the cloth as Ply records it',
        ],
        BookCorner.bottomRight: [
          'The threading runs along the bottom with the tie-up at the bottom right. The treadling is above the tie-up and the drawdown above the threading.',
          'Shaft 1 is the top row of the threading and of the tie-up, the row next to the drawdown.',
          'Pick 1 is the bottom row of the treadling and of the drawdown, so read the treadling from the bottom up.',
        ],
        BookCorner.bottomLeft: [
          'with the tie-up at the bottom left',
          'End 1 is the left-hand column',
          'from the bottom up',
        ],
      };
      final base = buildWeavePrintDocument(await _source(aw2Doc()), withProblemsBox: false);
      final baseDraft = _all<PrintBookDraft>(_section(base, 'Draft')!).single;
      for (final c in BookCorner.values) {
        final d = await _doc(aw2Doc(), corner: c);
        final draft = _section(d, 'Draft')!;
        final words = (draft.blocks.first as PrintParagraph).text;
        for (final w in expected[c]!) {
          expect(words, contains(w), reason: c.name);
        }
        expect(words, contains('Other books may put the tie-up in another corner'));
        expect(_facts(d), contains('Layout: ${bookLayoutLabel(c)}'));
        final b = _all<PrintBookDraft>(draft).single;
        expect(b.corner, c);
        expect(b.threading, baseDraft.threading);
        expect(b.treadling, baseDraft.treadling);
        expect(b.tieup, baseDraft.tieup);
        expect(b.drawdown, baseDraft.drawdown);
        expect(b.pickNumbers, baseDraft.pickNumbers);
        expect(_all<PrintColorDrawdown>(_section(d, 'Color drawdown')!).single.corner, c);
      }
    });

    test('a sinking shed draws the tie-up as X and says what it means', () async {
      final d = await _doc(overshotDoc(shed: Shed.sinking));
      final draft = _section(d, 'Draft')!;
      expect(_all<PrintBookDraft>(draft).single.tieupMark, PrintMark.cross);
      expect(
          _text(d),
          contains(
              'Sinking shed: an X in the tie-up means that shaft sinks when you press the treadle, and every shaft without an X rises.'));
      final tie = _all<PrintLegend>(draft).single.entries.firstWhere((e) => e.name == 'Tie-up');
      expect((
        tie.mark,
        tie.meaning
      ), (
        PrintMark.cross,
        'Pressing the treadle lowers this shaft. The shafts without an X rise.'
      ));
      expect((_section(d, 'Tie-up')!.blocks.first as PrintParagraph).text,
          'Sinking shed: pressing a treadle lowers the shafts tied to it, and every other shaft rises.');
      expect(_facts(d), contains('Shed: Sinking shed'));
    });

    test('a lift plan has no tie-up, numbers its shaft columns and says how to read it', () async {
      final doc = overshotDoc().copyWith(
          drive: DraftLiftplan(liftplan: const [
            [1, 2],
            [1, 3],
            [2, 4]
          ]),
          weftColors: const [1, 0, 0],
          pickRoles: const []);
      final d = await _doc(doc);
      final b = _all<PrintBookDraft>(_section(d, 'Draft')!).single;
      expect((b.tieup, b.isLiftplan, b.columns, b.tieupMark), (null, true, 4, PrintMark.filled));
      expect(_section(d, 'Tie-up'), isNull);
      final lift = _section(d, 'Lift plan')!;
      expect([
        for (final l in _all<PrintLines>(lift).single.lines) l.text
      ], [
        'Shafts 1 + 2, pick 1. Weft color 2.',
        'Shafts 1 + 3, pick 2. Weft color 1.',
        'Shafts 2 + 4, pick 3. Weft color 1.',
      ]);
      final words = _text(d);
      expect(words, contains('A lift plan has no tie-up, so the top right corner holds only'));
      expect(words, contains('In the lift plan, shaft 1 is the left-hand column.'));
      expect(words, contains('A filled square in the lift plan raises that shaft for the pick.'));
      final sinking = await _doc(doc.copyWith(shed: Shed.sinking));
      expect(_text(sinking), contains('but a lift plan always lists the shafts that rise.'));
      expect(_all<PrintBookDraft>(_section(sinking, 'Draft')!).single.tieupMark, PrintMark.filled);
    });

    test('the key lists every mark the grids use, and only those', () async {
      List<String> names(PrintDocument d) =>
          [for (final e in _all<PrintLegend>(_section(d, 'Draft')!).single.entries) e.name];
      expect(names(await _doc(aw2Doc())),
          ['Threading', 'Tie-up', 'Treadling', 'Warp on top', 'Weft on top']);
      expect(names(await _doc(overshotDoc())), containsAll(['Pattern pick', 'Tabby pick']));
      final dw = names(await _doc(
          doubleWeaveDoc('double-width-fold-left', LayerConstruction.doubleWidthFoldLeft)));
      expect(dw, [
        'Threading',
        'Tie-up',
        'Treadling',
        'Warp on top',
        'Weft on top',
        'Top layer pick',
        'Bottom layer pick',
        'Shuttle',
        'Right to left',
        'Left to right',
        'Fold edge',
        'Open edge',
      ]);
      final mirrored = names(await _doc(
          doubleWeaveDoc('double-width-fold-left', LayerConstruction.doubleWidthFoldLeft),
          corner: BookCorner.topLeft));
      expect(mirrored, contains('Pass direction'));
      expect(mirrored, isNot(contains('Right to left')));
    });
  });

  group('annotations the model knows, never guessed', () {
    test('roles as margin letters: P/T for overshot, U/L for the two layers', () async {
      final o = _all<PrintBookDraft>(_section(await _doc(overshotDoc()), 'Draft')!).single;
      expect(o.roles.take(4), ['P', 'T', 'P', 'T']);
      final dw = _all<PrintBookDraft>(_section(
              await _doc(
                  doubleWeaveDoc('double-width-fold-left', LayerConstruction.doubleWidthFoldLeft)),
              'Draft')!)
          .single;
      expect(dw.roles.join(), 'ULLUULLU', reason: 'the fixture\'s T-B-B-T order');
      // No role recorded: no column at all; some unknown: a blank letter and a key entry.
      expect(_all<PrintBookDraft>(_section(await _doc(aw2Doc()), 'Draft')!).single.roles, isEmpty);
      final partial = await _doc(
          aw2Doc().copyWith(pickRoles: [PickRole.pattern, ...List.filled(21, PickRole.unknown)]));
      final b = _all<PrintBookDraft>(_section(partial, 'Draft')!).single;
      expect(b.roles.take(2), ['P', '']);
      expect(_text(partial), contains('No role is recorded for this pick.'));
    });

    test('shuttles and pass directions from the recorded starting side; unknown stays unknown',
        () async {
      final dw = doubleWeaveDoc('double-width-fold-left', LayerConstruction.doubleWidthFoldLeft);
      final b = _all<PrintBookDraft>(_section(await _doc(dw), 'Draft')!).single;
      // Shuttle 1 starts from the right (the end 1 edge) and changes direction every pass.
      expect([
        for (final p in b.passes) p.direction
      ], [
        for (var p = 0; p < 8; p++)
          p.isEven ? PrintPassDirection.fromEndOne : PrintPassDirection.towardEndOne,
      ]);
      expect(b.passes.every((p) => p.shuttle == 1), isTrue);
      // No starting side: shuttles without directions, and the reason printed.
      final unsided = await _doc(dw.copyWith(shuttleStarts: const {}));
      final u = _all<PrintBookDraft>(_section(unsided, 'Draft')!).single;
      expect(u.passes.every((p) => p.direction == PrintPassDirection.unknown), isTrue);
      expect(_text(unsided),
          contains('Shuttle 1 has no starting side, so its picks show no direction.'));
      // A pick with no shuttle: "?" there, and no direction after it.
      final gap = await _doc(dw.copyWith(pickShuttles: [1, 1, null, 1, 1, 1, 1, 1]));
      final g = _all<PrintBookDraft>(_section(gap, 'Draft')!).single;
      expect(g.passes[2].shuttle, isNull);
      expect([for (final p in g.passes.skip(2)) p.direction],
          List.filled(6, PrintPassDirection.unknown));
      expect(
          _text(gap),
          contains(
              'Pick 3 has no shuttle, so Ply cannot tell the direction of pick 3 or of any pick after it.'));
    });

    test('shot groups are brackets on the grid and stay their own row in the directions', () async {
      final doc = aw2Doc().copyWith(
        drive: DraftTreadled(
          tieup: (aw2Doc().drive as DraftTreadled).tieup,
          treadling: [
            [1],
            [1],
            [3],
            [3],
            [3],
            ...List.generate(17, (p) => [p % 4 + 1]),
          ],
        ),
        shotGroups: const [ShotGroup(0, 2), ShotGroup(2, 3)],
      );
      final d = await _doc(doc);
      final b = _all<PrintBookDraft>(_section(d, 'Draft')!).single;
      expect([for (final x in b.brackets) (x.start, x.end, x.label)],
          [(0, 2, 'double shot'), (2, 5, 'triple shot')]);
      final lines = _all<PrintLines>(_section(d, 'Treadling')!).single.lines;
      expect(lines[0].text,
          startsWith('Treadle 1 ×2, picks 1 to 2: double shot (2 passes in one shed).'));
      expect(lines[1].text,
          startsWith('Treadle 3 ×3, picks 3 to 5: triple shot (3 passes in one shed).'));
      expect(_text(d), contains('Catch the weft at the selvedge on each return pass'));
      expect(_all<PrintLegend>(_section(d, 'Draft')!).single.entries.last.mark, PrintMark.bracket);
    });

    test('edge labels only for a construction the derived edges confirm', () async {
      for (final (name, c, high, one) in const [
        ('double-width-fold-left', LayerConstruction.doubleWidthFoldLeft, 'Fold', 'Open'),
        ('double-width-fold-right', LayerConstruction.doubleWidthFoldRight, 'Open', 'Fold'),
        ('tube', LayerConstruction.tube, 'Joined', 'Joined'),
        ('independent-layers', LayerConstruction.twoLayers, 'Open', 'Open'),
      ]) {
        final d = await _doc(doubleWeaveDoc(name, c));
        final b = _all<PrintBookDraft>(_section(d, 'Draft')!).single;
        expect((b.highEndEdge, b.endOneEdge), (high, one), reason: name);
        expect(_text(d), contains('Construction: ${constructionLabel(c)}. The edges Ply works out'),
            reason: name);
        expect(
            _text(d),
            contains(
                'This drawdown shows every intersection of both layers, not the face of the cloth.'));
      }
      // Declared the other way round: no labels, the mismatch said.
      final wrong = await _doc(
          doubleWeaveDoc('double-width-fold-left', LayerConstruction.doubleWidthFoldRight));
      final b = _all<PrintBookDraft>(_section(wrong, 'Draft')!).single;
      expect((b.highEndEdge, b.endOneEdge), (null, null));
      final notice = _all<PrintNotice>(_section(wrong, 'Draft')!).single;
      expect(notice.title, 'The edges do not match the construction');
      expect(notice.lines.first, startsWith('The fold should be on the right, but the layers'));
      expect(_text(wrong), contains('so the grids carry no edge labels.'));
      // Not declared: never labelled, even when the edges would match a construction exactly.
      final undeclared =
          await _doc(doubleWeaveDoc('double-width-fold-left', LayerConstruction.none));
      final u = _all<PrintBookDraft>(_section(undeclared, 'Draft')!).single;
      expect((u.highEndEdge, u.endOneEdge), (null, null));
      expect(_text(undeclared), isNot(contains('Construction:')));
    });
  });

  group('Use tabby', () {
    test('prints the instruction and the pattern-only grid numbered with full-draft picks',
        () async {
      final doc = overshotDoc();
      expect(readUseTabby(doc), isA<UseTabbyBook>());
      final s = await _source(doc);
      final d = buildWeavePrintDocument(s, withProblemsBox: false);
      final section = _section(d, 'Use tabby')!;
      final paragraphs = [for (final p in _all<PrintParagraph>(section)) p.text];
      expect(paragraphs[0], 'USE TABBY');
      expect(paragraphs[1], useTabbyInstruction(readUseTabby(doc) as UseTabbyBook));
      expect(paragraphs[1],
          'Weave one tabby pick after every pattern pick. The tabby alternates between tabby a (treadle 5) and tabby b (treadle 6), starting with tabby a. Tabby a is the tabby shed that lifts the first threaded warp end.');
      final facts = [
        for (final f in _all<PrintFacts>(section).single.facts) '${f.label}: ${f.value}'
      ];
      expect(facts, [
        'Tabby weft: Color 1 (#F5F0E1)',
        'Picks: 16 picks: 8 pattern picks in 4 rows and 8 tabby picks'
      ]);
      final grid = _all<PrintBookDraft>(section).single;
      expect(grid.pickNumbers, [1, 3, 5, 7, 9, 11, 13, 15]);
      expect(grid.treadling, [
        for (final t in const [1, 1, 2, 2, 3, 3, 4, 4]) [t]
      ]);
      expect(grid.rowsNote, 'pattern picks only');
      // The pattern grid's drawdown rows are the full drawdown's rows at those picks.
      for (var k = 0; k < 8; k++) {
        final p = grid.pickNumbers[k] - 1;
        expect(grid.drawdown!.sublist(k * 16, (k + 1) * 16),
            s.interlacement!.sublist(p * 16, (p + 1) * 16));
      }
      // The full draft keeps every pick.
      expect(_all<PrintBookDraft>(_section(d, 'Draft')!).single.rows, 16);
    });

    test('the printed Use tabby directions expand to exactly the draft\'s picks', () async {
      final cases = <String, DraftDoc>{
        'trailing tabby': overshotDoc(),
        'irregular runs': overshotDoc(pattern: const [1, 2, 2, 2, 4, 3, 3, 1, 1]),
        'sinking shed': overshotDoc(shed: Shed.sinking),
      };
      // A tabby first, and no tabby last.
      final base = overshotDoc();
      final rows = base.drive.rows;
      cases['leading tabby'] = base.copyWith(
        drive: DraftTreadled(tieup: (base.drive as DraftTreadled).tieup, treadling: [
          [6],
          ...rows.take(15)
        ]),
        pickRoles: [PickRole.tabby, ...base.pickRoles.take(15)],
        weftColors: [0, ...base.weftColors.take(15)],
      );
      // A lift plan.
      cases['lift plan'] = base.copyWith(
          drive: DraftLiftplan(liftplan: [
        for (final r in rows) ...[
          [for (final t in r) ...(base.drive as DraftTreadled).tieup[t - 1]]..sort(),
        ],
      ]));
      for (final MapEntry(key: name, value: doc) in cases.entries) {
        expect(readUseTabby(doc), isA<UseTabbyBook>(), reason: name);
        final d = await _doc(doc);
        final treadled = doc.drive is DraftTreadled;
        final section = _section(d, treadled ? 'Treadling' : 'Lift plan')!;
        expect((section.blocks.first as PrintParagraph).text, startsWith('Use tabby:'),
            reason: name);
        expect(
            _sorted(expandPrintedTreadling(section, treadled: treadled)), _sorted(doc.drive.rows),
            reason: '$name: the printed working order is exactly the picks');
        // And the pattern grid plus the instruction give the same sequence.
        final grid = _all<PrintBookDraft>(_section(d, 'Use tabby')!).single;
        final book = readUseTabby(doc) as UseTabbyBook;
        expect(grid.pickNumbers,
            [for (var k = 0; k < book.pattern.length; k++) book.pickOfPattern(k) + 1]);
        for (final (k, p) in grid.pickNumbers.indexed) {
          expect(grid.treadling[k], doc.drive.rows[p - 1], reason: name);
        }
      }
    });

    test('without the policy the full listing prints, with the reason when roles exist', () async {
      // Two pattern picks in a row break the alternation.
      final base = overshotDoc();
      final doc =
          base.copyWith(pickRoles: [PickRole.pattern, PickRole.pattern, ...base.pickRoles.skip(2)]);
      expect(readUseTabby(doc), isA<UseTabbyUnavailable>());
      final d = await _doc(doc);
      expect(_section(d, 'Use tabby'), isNull);
      final t = _section(d, 'Treadling')!;
      expect((t.blocks[0] as PrintParagraph).text, startsWith('Every pick in order from pick 1.'));
      expect((t.blocks[1] as PrintParagraph).text,
          'Use tabby shorthand is not available: use tabby shorthand needs pattern and tabby picks to alternate. Picks 1 and 2 are both pattern picks.');
      expect(expandPrintedTreadling(t, treadled: true), doc.drive.rows);
      // A draft with no roles at all gets no reason (it is not an overshot question).
      final plain = _section(await _doc(aw2Doc()), 'Treadling')!;
      expect(plain.blocks.whereType<PrintParagraph>(), hasLength(1));
      expect(expandPrintedTreadling(plain, treadled: true), aw2Doc().drive.rows);
    });
  });

  group('written directions', () {
    test('threading in groups of ten, multi-shaft and unthreaded ends spelled out', () async {
      final doc = aw2Doc().copyWith(threading: [
        [1, 3],
        <int>[],
        ...aw2Doc().threading.skip(2),
      ]);
      final t = _section(await _doc(doc), 'Threading')!;
      expect((t.blocks.first as PrintParagraph).text,
          'The shaft each end is threaded on, ten ends to a line, from end 1. 1+3 means an end on shafts 1 and 3. A dash (–) is an end that is not threaded.');
      expect([
        for (final l in _all<PrintLines>(t).single.lines) '${l.label}: ${l.text}'
      ], [
        'Ends 1 to 10: 1+3, –, 1, 3, 2, 4, 3, 1, 4, 2',
        'Ends 11 to 20: 4, 2, 4, 2, 4, 1, 3, 4, 2, 3',
        'Ends 21 to 22: 1, 3',
      ]);
    });

    test('tie-up treadle by treadle, the shed meaning first', () async {
      final t = _section(await _doc(overshotDoc()), 'Tie-up')!;
      expect((t.blocks.first as PrintParagraph).text,
          'Rising shed: pressing a treadle raises the shafts tied to it.');
      expect([for (final l in _all<PrintLines>(t).single.lines) '${l.label}: ${l.text}'].take(2),
          ['Treadle 1: Shafts 1 and 2.', 'Treadle 2: Shafts 2 and 3.']);
      final untied = await _doc(aw2Doc().copyWith(treadles: 5));
      expect(_all<PrintLines>(_section(untied, 'Tie-up')!).single.lines.last.text,
          'Not tied to any shaft.');
      expect(_all<PrintBookDraft>(_section(untied, 'Draft')!).single.columns, 5);
    });

    test('treadling rows carry weft colors, roles, shuttles, directions and strands', () async {
      final dw = doubleWeaveDoc('double-width-fold-left', LayerConstruction.doubleWidthFoldLeft)
          .copyWith(pickStrands: [2, 2, 1, 1, 1, 1, 1, 1]);
      final lines = _all<PrintLines>(_section(await _doc(dw), 'Treadling')!).single.lines;
      expect(lines.first.label, 'Row 1');
      expect(lines.first.text,
          'Treadle 1, pick 1. Weft color 1. Role: top layer. Shuttle 1, right to left (←). 2 strands carried together.');
      expect(lines[1].text,
          'Treadle 2, pick 2. Weft color 1. Role: bottom layer. Shuttle 1, left to right (→). 2 strands carried together.');
      // A run of picks on one shuttle: every pass, never cut short.
      final run = aw2Doc().copyWith(
        drive: DraftTreadled(
            tieup: (aw2Doc().drive as DraftTreadled).tieup,
            treadling: List.generate(22, (_) => [1])),
        weftColors: List.filled(22, 1),
        pickShuttles: List.filled(22, 1),
        shuttleStarts: const {1: ShuttleSide.left},
      );
      final runLine = _all<PrintLines>(_section(await _doc(run), 'Treadling')!).single.lines.single;
      expect(runLine.text,
          'Treadle 1 ×22, picks 1 to 22. Weft color 2. Shuttle 1: 22 passes, the first left to right (→), changing direction on every pass.');
      final few = run.copyWith(
        drive: DraftTreadled(tieup: (aw2Doc().drive as DraftTreadled).tieup, treadling: [
          ...List.generate(3, (_) => [1]),
          ...List.generate(19, (_) => [2]),
        ]),
      );
      expect(
          weaveShuttleText(
              few, const [ShuttleSide.left, ShuttleSide.right, ShuttleSide.left], const [0, 1, 2]),
          'Shuttle 1: → ← →, the first pass left to right');
      expect(
          weaveShuttleText(few.copyWith(pickShuttles: [1, 2, null, ...List.filled(19, 1)]),
              const [ShuttleSide.left, null, null], const [0, 1, 2]),
          'Shuttles: 1 →, 2, ?');
      expect(weaveStrandsText(dw, const [0, 1, 2]), 'Strands carried together: 2, 2, 1');
      // Every other pick of one shuttle (a Use tabby row on a shared shuttle): all one way, and said
      // so, never "changing direction".
      final long = run.copyWith(
        drive: DraftTreadled(
            tieup: (aw2Doc().drive as DraftTreadled).tieup,
            treadling: List.generate(30, (_) => [1])),
        weftColors: List.filled(30, 1),
        pickShuttles: List.filled(30, 1),
      );
      expect(weaveShuttleText(long, passStarts(long), [for (var p = 0; p < 30; p += 2) p]),
          'Shuttle 1: 15 passes, every one left to right (→)');
      // Mixed directions that follow no rule are listed one by one.
      final odd = [0, 1, 3, 4, 6, 7, 9, 10, 12, 13, 15, 16, 18];
      expect(
          weaveShuttleText(run, passStarts(run), odd), startsWith('Shuttles: 1 →, 1 ←, 1 ←, 1 →'));
    });
  });

  group('problems and what the PDF cannot show', () {
    test('errors ask first and fill the box; warnings never do; the table names the pick',
        () async {
      final repo = FakeWeaveRepo(issues: const [_warn, _err]);
      final s = await _source(aw2Doc(), repo: repo);
      expect(weavePrintErrors(s), ['Pick 3 presses treadle 9 which has no tie-up']);
      final d = buildWeavePrintDocument(s, withProblemsBox: true);
      expect(d.problemsBox!.title, 'This draft has problems');
      expect(d.problemsBox!.lines, ['Pick 3 presses treadle 9 which has no tie-up']);
      expect(d.problemsBox!.intro, startsWith('Ply found 1 error in this draft.'));
      expect(buildWeavePrintDocument(s, withProblemsBox: false).problemsBox, isNull);
      final table = _all<PrintIssues>(_section(d, 'Problems')!).single;
      expect([
        for (final i in table.issues) (i.severity, i.where, i.message)
      ], [
        (PrintIssueSeverity.error, 'Pick 3', 'Pick 3 presses treadle 9 which has no tie-up'),
        (PrintIssueSeverity.warning, 'Whole draft', 'Warp color count (5) != warp ends (4)'),
      ]);
      final warnOnly = await _source(aw2Doc(), repo: FakeWeaveRepo(issues: const [_warn]));
      expect(weavePrintErrors(warnOnly), isEmpty);
      expect(buildWeavePrintDocument(warnOnly, withProblemsBox: true).problemsBox, isNull);
      expect(_all<PrintIssues>(_section(await _doc(aw2Doc()), 'Problems')!).single.emptyText,
          'Ply found no problems in this draft.');
    });

    test('thickness, strands, unknown directions, layers and unprinted file data are flagged',
        () async {
      final doc =
          doubleWeaveDoc('double-width-fold-left', LayerConstruction.doubleWidthFoldLeft).copyWith(
        weftThickness: [3.0, ...List.filled(7, 1.0)],
        pickStrands: [2, ...List.filled(7, 1)],
        shuttleStarts: const {},
        retained: [
          RetainedSection('WARP SPACING', const [RetainedEntry('1', '0.1')])
        ],
      );
      final notice = _all<PrintNotice>(_section(await _doc(doc), 'Problems')!).single;
      expect(notice.title, 'What this PDF cannot show exactly');
      expect(notice.lines, [
        'The draft is marked as double width with the fold on the left, but Ply cannot check its '
            'edges, so the grids carry no edge labels.',
        'Yarn thickness is not drawn: the grids and the color drawdown give every end and pick one square. 0 ends and 1 pick have a recorded thickness other than 1.',
        'Strands carried together are given in the treadling directions only; the grids show one mark per pick.',
        'Shuttle 1 has no starting side, so its picks show no direction.',
        'The drawdowns show every intersection of both layers, not the face of the cloth.',
        'The file holds data Ply keeps but does not print: WARP SPACING.',
      ]);
      // A plain draft has nothing to flag.
      expect(_all<PrintNotice>(_section(await _doc(aw2Doc()), 'Problems')!), isEmpty);
    });
  });

  group('the colored drawdown', () {
    test('the engine colors, with warp and weft bands from the draft', () async {
      final s = await _source(aw2Doc());
      final c = _all<PrintColorDrawdown>(
              _section(buildWeavePrintDocument(s, withProblemsBox: false), 'Color drawdown')!)
          .single;
      expect((c.ends, c.picks), (22, 22));
      expect(c.cells, s.colors);
      expect([for (final w in c.warp.take(2)) w.hex], ['#2D2D2D', '#DBDBDB']);
      expect([for (final w in c.weft.take(2)) w.hex], ['#2D2D2D', '#DBDBDB']);
    });
  });
}

/// A repository whose engine always draws the same [image].
class _CannedPixels extends DraftRepository {
  _CannedPixels(this.image);
  final PreviewImage image;

  @override
  Future<PreviewImage> renderRegionPixels(DraftDoc doc, DrawdownRegion region,
          {required int cellPx}) async =>
      image;
}
