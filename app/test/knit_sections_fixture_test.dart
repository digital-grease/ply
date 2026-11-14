import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/knit_repository.dart';
import 'package:ply/src/models/draft_doc.dart' show MeasureUnit;
import 'package:ply/src/models/native_format.dart';
import 'package:ply/src/print/knit_print.dart';
import 'package:ply/src/print/pdf_builder.dart';
import 'package:ply/src/print/print_document.dart';
import 'package:ply/src/print/print_layout.dart';
import 'package:ply/src/rust/api.dart' show PreviewImage;
import 'package:ply/src/rust/knit_dto.dart';
import 'package:ply/src/screens/knit_written_screen.dart';
import 'package:ply/src/state/knit_editor_providers.dart';

import 'knit_sections_test_support.dart';
import 'print/print_test_support.dart';

// The knitting section acceptance fixtures (fixtures/knitting/sections/, shared with the Rust tests)
// as the app sees them: every one is a current (version 4) .plyknit envelope, and what the engine
// says about it (its hand-derived oracle: the written instructions, the ledger and the problems)
// reaches the written-instructions screen and the printed PDF intact: each section under its
// heading, each step with its row label and its stitch count, uncounted steps flagged, and every
// problem placed at its section and step.

/// Stands in for the engine with a fixture's oracle.
class OracleRepo extends KnitRepository {
  OracleRepo(this.name) : pattern = patternFromPlyknit(sectionFixtureText(name, 'plyknit'));

  final String name;
  final KnitPatternDto pattern;
  Map<String, dynamic> get oracle => sectionOracle(name);

  @override
  Future<List<KnitIssueDto>> validate(KnitPatternDto pattern) async => oracleIssues(oracle);

  @override
  Future<List<String>> written(KnitPatternDto pattern) async =>
      [for (final l in oracle['written'] as List) l as String];

  @override
  Future<KnitConstructionDto> construction(KnitPatternDto pattern) async =>
      oracleConstruction(this.pattern, oracle);

  @override
  Future<PreviewImage> renderPixels(KnitPatternDto pattern, {required int cellPx}) async {
    final r = solidRaster(pattern.chart.width * cellPx, pattern.chart.rows.length * cellPx);
    return PreviewImage(width: r.width, height: r.height, rgba: r.rgba);
  }
}

Future<PrintDocument> _document(String name, {bool box = true}) async {
  final repo = OracleRepo(name);
  final source = await gatherKnitPrint(repo,
      name: repo.pattern.name, pattern: repo.pattern, now: DateTime(2026, 11, 13));
  expect(source.construction, isNotNull, reason: 'gathered for a pattern with sections');
  return buildKnitPrintDocument(source, withProblemsBox: box);
}

PrintSection _section(PrintDocument d, String heading) =>
    d.sections.firstWhere((s) => s.heading == heading);

void main() {
  test('every section fixture is a current (version 4) envelope', () {
    for (final name in kSectionFixtures) {
      expect(plyknitSchemaVersion(sectionFixtureText(name, 'plyknit')), 4, reason: name);
      final record = sectionFixtureText(name, 'fixture.toml');
      expect(record, contains('practitioner_knit_check = "pending"'), reason: name);
      expect(record, contains('license = "original"'), reason: name);
    }
  });

  for (final name in kSectionFixtures) {
    test('$name: the PDF prints each section, every step with its count, and the problems',
        () async {
      final oracle = sectionOracle(name);
      final d = await _document(name);
      final p = OracleRepo(name).pattern;

      final facts = _section(d, 'Materials and gauge').blocks.whereType<PrintFacts>().single.facts;
      expect(facts.firstWhere((f) => f.label == 'Sections').value,
          [for (final s in p.sections) s.name].join(', '));

      // Written instructions: the cast-on line, then per section its heading (bold), its notes and
      // its lines, in the oracle's order.
      final blocks = _section(d, 'Written instructions').blocks;
      final printed = <String>[];
      for (final b in blocks.skip(1)) {
        switch (b) {
          case PrintParagraph(:final text, :final style):
            printed.add(style == PrintTextStyle.strong ? text : 'Notes: $text');
          case PrintLines(:final lines):
            for (final l in lines) {
              printed.add(l.label == null ? l.text : '${l.label}: ${l.text}');
              expect(l.flagged, l.text.endsWith('(not counted: see the problems)'),
                  reason: '$name: ${l.text}');
            }
          default:
            fail('unexpected block $b');
        }
      }
      expect(printed, [for (final l in oracle['written'] as List) l as String],
          reason: '$name: every line of the written instructions, in order');
      final intro = (blocks.first as PrintParagraph).text;
      expect(intro, contains('The count in brackets after each step'));

      // Problems: every issue, each at its place.
      final issues = _section(d, 'Problems').blocks.whereType<PrintIssues>().single.issues;
      expect(issues, hasLength((oracle['issues'] as List).length));
      for (final i in issues) {
        expect(i.message, isNot(startsWith('Problems, step')),
            reason: 'the place is its own column');
      }
    });
  }

  test('ledger-problems-flat: each problem is placed by section, step and chart row', () async {
    final issues = _section(await _document('ledger-problems-flat'), 'Problems')
        .blocks
        .whereType<PrintIssues>()
        .single
        .issues;
    String whereOf(String start) => issues.firstWhere((i) => i.message.startsWith(start)).where;
    expect(whereOf('Works over 20 stitches'), 'Problems, step 3, chart row 1');
    expect(whereOf('Binds off 30 stitches'), 'Problems, step 4');
    expect(whereOf('Ends with short rows'), 'Problems');
    expect(whereOf('Chart rows 2 to 3 are not worked'), 'Whole pattern');
    expect(whereOf('Row 3: the repeat'), 'Row 3', reason: 'a drawn-chart problem, as before');
    expect(issues.first.severity, PrintIssueSeverity.error, reason: 'errors first');
  });

  test('the shoulder fixture prints as a real PDF with the ledger counts', () async {
    final pdf = PdfReadBack(await buildPrintPdf(
      await _document('shoulder-short-rows-flat'),
      page: PrintPageSetup.forUnit(MeasureUnit.inches),
      fonts: testFonts(),
      compress: false,
    ));
    for (final s in [
      'Sections Body, Shoulder',
      'Section 2: Shoulder',
      'Short row 1 (RS): knit to last 6 sts, wrap and turn. (24 sts on the needle, 6 waiting',
      'Not checked by Ply: Repeat rows 1 and 2',
      'Place all 24 sts on a holder (shoulder). (0 sts on the needle; 24 on hold)',
    ]) {
      expect(pdf.text, contains(s));
    }
    expect(pdf.text, isNot(contains('\u2014')), reason: 'no em dashes');
  });

  testWidgets('the written-instructions screen sets each section heading apart', (tester) async {
    final repo = OracleRepo('neckline-hold-flat');
    final container =
        ProviderContainer(overrides: [knitRepositoryProvider.overrideWithValue(repo)]);
    addTearDown(container.dispose);
    container.read(knitEditorProvider.notifier).load(repo.pattern);
    await tester.binding.setSurfaceSize(const Size(600, 3000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: KnitWrittenScreen()),
    ));
    await tester.pumpAndSettle();
    for (final h in ['Section 1: Body', 'Section 3: Left side', 'Section 5: Neck edge']) {
      expect(find.text(h), findsOneWidget);
      final node = tester.getSemantics(find.text(h));
      expect(node.flagsCollection.isHeader, isTrue, reason: h);
    }
    expect(
        find.text('With the RS facing, return the 9 sts on hold (right side) to the needle and '
            'join the yarn. (9 sts on the needle; 12 on hold; 9 bound off)'),
        findsOneWidget);
    final step = tester.getSemantics(find.text('Next row (RS): knit 9 sts. (30 sts on the needle, '
        '21 still to work in this row)'));
    expect(step.flagsCollection.isHeader, isFalse);
    handle.dispose();
  });
}
