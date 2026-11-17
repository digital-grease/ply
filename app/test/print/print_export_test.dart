import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart' show PdfPageFormat;
import 'package:ply/src/data/readiness_repository.dart';
import 'package:ply/src/models/app_settings.dart';
import 'package:ply/src/models/draft_doc.dart' show MeasureUnit;
import 'package:ply/src/models/readiness.dart';
import 'package:ply/src/print/pdf_builder.dart';
import 'package:ply/src/print/pdf_fonts.dart';
import 'package:ply/src/print/print_document.dart';
import 'package:ply/src/print/print_export.dart';
import 'package:ply/src/print/print_layout.dart';
import 'package:ply/src/rust/dto.dart' show ColorDto, SeverityKind, UnitKind;
import 'package:ply/src/rust/knit_dto.dart';
import 'package:ply/src/rust/nalbind_dto.dart' show NalbindStitchDto;
import 'package:ply/src/screens/knit_editor_screen.dart';
import 'package:ply/src/screens/knit_written_screen.dart';
import 'package:ply/src/screens/nalbind_project_screen.dart';
import 'package:ply/src/state/knit_editor_providers.dart';
import 'package:ply/src/state/nalbind_providers.dart';
import 'package:ply/src/state/theme_providers.dart';

import 'knit_print_test.dart' show FakePrintRepo;
import 'nalbind_print_test.dart' show FakeReadRepo;
import 'print_test_support.dart';
import 'readiness_test_support.dart';

// The "Print or share PDF" flow: the Print / Share choice, readiness (ADR 0021: a ready pattern
// prints straight away, warnings and things Ply could not check are acknowledged in one step, a
// pattern with errors is only ever a labelled draft copy, marked on every page), the paper by
// units, failures reported, and the entry points on the knit editor, the written instructions and
// the nalbind project screen.

/// Records what reached the system print / share dialogs.
class RecordingOutput implements PdfOutput {
  final printed = <(String, PdfPageFormat, Uint8List)>[];
  final shared = <(String, Uint8List)>[];

  int get calls => printed.length + shared.length;

  @override
  Future<bool> print({
    required String name,
    required PdfPageFormat format,
    required Future<Uint8List> Function(PdfPageFormat format) build,
  }) async {
    printed.add((name, format, await build(format)));
    return true;
  }

  @override
  Future<bool> share({required String filename, required Uint8List bytes}) async {
    shared.add((filename, bytes));
    return true;
  }
}

class _FixedSettings extends AppSettingsNotifier {
  _FixedSettings(this.unit);
  final MeasureUnit unit;
  @override
  AppSettings build() => AppSettings(unit: unit);
}

List<Override> _overrides(RecordingOutput out,
        {MeasureUnit unit = MeasureUnit.inches, ReadinessRepository? readiness}) =>
    [
      pdfOutputProvider.overrideWithValue(out),
      plyPdfFontsProvider.overrideWith((_) async => testFonts()),
      appSettingsProvider.overrideWith(() => _FixedSettings(unit)),
      readinessRepositoryProvider.overrideWithValue(readiness ?? FakeReadiness()),
      // The recorded bytes are read back: they must not be compressed.
      pdfCompressProvider.overrideWithValue(false),
    ];

/// A host with one button that runs the flow on [job].
Future<void> _pumpHost(
  WidgetTester tester,
  RecordingOutput out,
  Future<PdfExportJob> Function() prepare, {
  MeasureUnit unit = MeasureUnit.inches,
}) async {
  await tester.pumpWidget(ProviderScope(
    overrides: _overrides(out, unit: unit),
    child: MaterialApp(
      home: Scaffold(
        body: Consumer(
          builder: (context, ref, _) => Center(
            child: ElevatedButton(
              onPressed: () => printOrSharePdf(context, ref, noun: 'pattern', prepare: prepare),
              child: const Text('go'),
            ),
          ),
        ),
      ),
    ),
  ));
}

/// A job whose document records every build. A [long] document runs over several pages.
class _Job {
  _Job([this.readiness = const ReadinessReport(), this.long = false, this.listNotChecked = false]);
  final ReadinessReport readiness;
  final bool long;
  final bool listNotChecked;
  final builds = <bool>[];

  PdfExportJob get job => PdfExportJob(
        fileStem: 'Harbor hat',
        readiness: readiness,
        listNotChecked: listNotChecked,
        document: ({required withProblemsBox}) {
          builds.add(withProblemsBox);
          return PrintDocument(
            title: 'Harbor hat',
            kind: 'Knitting pattern',
            problemsBox: withProblemsBox
                ? PrintNotice(
                    level: PrintNoticeLevel.problem,
                    title: 'This pattern has problems',
                    lines: [for (final e in readiness.errors) e.message])
                : null,
            sections: [
              PrintSection('Notes', [
                const PrintParagraph('Warm.'),
                if (long)
                  for (var i = 0; i < 160; i++) PrintParagraph('Line $i of a long set of notes.'),
              ]),
            ],
          );
        },
      );
}

Future<void> _choose(WidgetTester tester, String action) async {
  await tester.tap(find.text('go'));
  await tester.pumpAndSettle();
  expect(find.text('Print or share PDF'), findsOneWidget, reason: 'the choice sheet');
  await tester.tap(find.text(action));
  await tester.pumpAndSettle();
}

final _errors = report([
  finding(ReadinessLevel.error, 'Row 2 consumes 6 stitches but row 1 produced 7', place: 'Row 2'),
  finding(ReadinessLevel.warning, 'Row 3 is wide', place: 'Row 3'),
]);

final _warnings = report([
  finding(ReadinessLevel.warning, 'The repeat cannot be counted without a cast-on',
      place: 'Row 1, columns 2 to 5'),
  finding(ReadinessLevel.unsupported,
      'Ply did not check this step: it is in the pattern\'s own words ("block it")',
      check: ReadinessCheck.sections, place: 'Back, step 4'),
  finding(ReadinessLevel.info, 'A note that never asks'),
], checked: const [
  ReadinessCheck.chart,
  ReadinessCheck.sections
]);

void main() {
  // The PDF bytes are compressed in the flow; read them back through a second, uncompressed build
  // where content matters (PdfReadBack needs plain streams), and check the bytes are a real PDF.
  bool isPdf(Uint8List b) => String.fromCharCodes(b.take(5)) == '%PDF-';

  testWidgets('a clean pattern prints straight away on the units-setting paper', (tester) async {
    final out = RecordingOutput();
    final j = _Job();
    await _pumpHost(tester, out, () async => j.job);
    await _choose(tester, 'Print');
    expect(find.text('This pattern has problems'), findsNothing, reason: 'no question');
    expect(out.printed.length, 1);
    final (name, format, bytes) = out.printed.single;
    expect(name, 'Harbor hat.pdf');
    expect(format.width, closeTo(612, 0.01), reason: 'imperial: US Letter');
    expect(isPdf(bytes), isTrue);
    expect(j.builds, [false]);
  });

  testWidgets('metric prints on A4', (tester) async {
    final out = RecordingOutput();
    await _pumpHost(tester, out, () async => _Job().job, unit: MeasureUnit.centimeters);
    await _choose(tester, 'Print');
    expect(out.printed.single.$2.width, closeTo(PdfPageFormat.a4.width, 0.01));
  });

  testWidgets('information alone never asks', (tester) async {
    final out = RecordingOutput();
    final j = _Job(report([finding(ReadinessLevel.info, 'A formatting note')]));
    await _pumpHost(tester, out, () async => j.job);
    await _choose(tester, 'Print');
    expect(find.byType(AlertDialog), findsNothing);
    expect(out.printed.length, 1);
    expect(j.builds, [false]);
  });

  testWidgets('warnings and unsupported items are listed and acknowledged in one step',
      (tester) async {
    final out = RecordingOutput();
    final j = _Job(_warnings);
    await _pumpHost(tester, out, () async => j.job);
    await _choose(tester, 'Print');
    expect(find.text('Check this pattern before you print it'), findsOneWidget);
    expect(find.text('Warnings'), findsOneWidget);
    expect(find.text('• Row 1, columns 2 to 5: The repeat cannot be counted without a cast-on'),
        findsOneWidget);
    expect(find.text('Ply could not check'), findsOneWidget);
    expect(find.textContaining('• Back, step 4: Ply did not check this step'), findsOneWidget);
    expect(find.textContaining('A note that never asks'), findsNothing, reason: 'info never asks');
    expect(
        find.textContaining('Ply found no errors in the chart and the sections.'), findsOneWidget);
    expect(out.calls, 0, reason: 'nothing is made before the acknowledgement');
    await tester.tap(find.text('Acknowledge and print'));
    await tester.pumpAndSettle();
    expect(out.printed.single.$1, 'Harbor hat.pdf', reason: 'a ready copy, not a draft copy');
    expect(j.builds, [false], reason: 'no problems box');
  });

  testWidgets('cancelling the acknowledgement exports nothing', (tester) async {
    final out = RecordingOutput();
    final j = _Job(_warnings);
    await _pumpHost(tester, out, () async => j.job);
    await _choose(tester, 'Share PDF');
    expect(find.text('Check this pattern before you share it'), findsOneWidget);
    expect(find.text('Acknowledge and share'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(out.calls, 0);
    expect(j.builds, isEmpty);
  });

  testWidgets('errors: not ready, the default goes back and exports nothing', (tester) async {
    final out = RecordingOutput();
    final j = _Job(_errors);
    await _pumpHost(tester, out, () async => j.job);
    await _choose(tester, 'Print');
    expect(find.text('This pattern is not ready to make or share'), findsOneWidget);
    expect(find.text('Ply found 1 error in this pattern:'), findsOneWidget);
    expect(find.text('• Row 2: Row 2 consumes 6 stitches but row 1 produced 7'), findsOneWidget);
    expect(find.text('It also has 1 warning.'), findsOneWidget);
    expect(find.text('Print anyway'), findsNothing, reason: 'never a ready copy with errors');
    // The default (filled) button goes back; the draft copy is a separate text button.
    expect(find.widgetWithText(FilledButton, 'Go back'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Print a draft copy'), findsOneWidget);
    await tester.tap(find.text('Go back'));
    await tester.pumpAndSettle();
    expect(out.calls, 0);
    expect(j.builds, isEmpty, reason: 'no document was even built');
  });

  testWidgets('errors: a draft copy says so on every page and keeps the problems box',
      (tester) async {
    final out = RecordingOutput();
    final j = _Job(_errors);
    await _pumpHost(tester, out, () async => j.job);
    await _choose(tester, 'Print');
    await tester.tap(find.text('Print a draft copy'));
    await tester.pumpAndSettle();
    expect(out.printed.length, 1);
    expect(out.printed.single.$1, 'Harbor hat (draft copy).pdf');
    expect(j.builds, [true], reason: 'the problems box stays');
  });

  testWidgets('errors: a shared draft copy is named as one', (tester) async {
    final out = RecordingOutput();
    final j = _Job(_errors);
    await _pumpHost(tester, out, () async => j.job);
    await _choose(tester, 'Share PDF');
    expect(find.text('Share a draft copy'), findsOneWidget);
    await tester.tap(find.text('Share a draft copy'));
    await tester.pumpAndSettle();
    expect(out.printed, isEmpty);
    final (file, bytes) = out.shared.single;
    expect(file, 'Harbor hat (draft copy).pdf');
    expect(isPdf(bytes), isTrue);
    expect(j.builds, [true]);
  });

  testWidgets('the exported draft copy carries the band on every page and the box on the first',
      (tester) async {
    final out = RecordingOutput();
    final j = _Job(_errors, true);
    await _pumpHost(tester, out, () async => j.job);
    await _choose(tester, 'Share PDF');
    await tester.tap(find.text('Share a draft copy'));
    await tester.pumpAndSettle();
    final pdf = PdfReadBack(out.shared.single.$2);
    expect(pdf.pageCount, greaterThan(1));
    for (final page in pdf.pages) {
      expect(page, contains('Draft copy, not ready to make or share: 1 error'));
    }
    expect(pdf.pages.first, contains('This pattern has problems'));
    // The file's own title says so too.
    expect(latin1.decode(out.shared.single.$2), contains('Harbor hat \\(draft copy\\)'));
  });

  testWidgets('a ready copy carries no band, and lists what Ply could not check', (tester) async {
    final out = RecordingOutput();
    final j = _Job(_warnings, true, true);
    await _pumpHost(tester, out, () async => j.job);
    await _choose(tester, 'Print');
    await tester.tap(find.text('Acknowledge and print'));
    await tester.pumpAndSettle();
    final pdf = PdfReadBack(out.printed.single.$3);
    expect(pdf.text, isNot(contains('Draft copy')));
    expect(pdf.pages.last, contains('Not checked by Ply'));
    expect(pdf.pages.last, contains('Back, step 4'));
    expect(pdf.pages.last, contains('Not checked'));
    // Off by default: a craft whose own findings table lists them (tablet weaving) gets no table.
    final plain = RecordingOutput();
    await _pumpHost(tester, plain, () async => _Job(_warnings).job);
    await _choose(tester, 'Print');
    await tester.tap(find.text('Acknowledge and print'));
    await tester.pumpAndSettle();
    expect(PdfReadBack(plain.printed.single.$3).text, isNot(contains('Not checked by Ply')));
  });

  testWidgets('the acknowledgement lists every warning it covers', (tester) async {
    final out = RecordingOutput();
    final many = report([
      for (var i = 1; i <= 12; i++) finding(ReadinessLevel.warning, 'Warning $i', place: 'Row $i'),
      for (var i = 1; i <= 9; i++)
        finding(ReadinessLevel.unsupported, 'Not checked $i', place: 'Step $i'),
    ]);
    await _pumpHost(tester, out, () async => _Job(many).job);
    await _choose(tester, 'Print');
    for (var i = 1; i <= 12; i++) {
      expect(find.text('• Row $i: Warning $i'), findsOneWidget);
    }
    for (var i = 1; i <= 9; i++) {
      expect(find.text('• Step $i: Not checked $i'), findsOneWidget);
    }
    expect(find.textContaining('more.'), findsNothing, reason: 'nothing acknowledged unseen');
  });

  testWidgets('the draft-copy question counts every error, the uncounted ones included',
      (tester) async {
    final out = RecordingOutput();
    final many = report([
      for (var i = 1; i <= 200; i++) finding(ReadinessLevel.error, 'Error $i', code: 'bad'),
      const ReadinessItem(
          check: ReadinessCheck.chart,
          code: 'bad',
          level: ReadinessLevel.error,
          message: '1,000 more like this are not listed: Ply lists the first 200 of each kind.',
          omitted: 1000),
    ]);
    expect(many.errorCount, 1200);
    await _pumpHost(tester, out, () async => _Job(many).job);
    await _choose(tester, 'Share PDF');
    expect(find.text('Ply found 1200 errors in this pattern:'), findsOneWidget);
    expect(find.text('and 1194 more.'), findsOneWidget, reason: 'six listed, the rest counted');
    await tester.tap(find.text('Share a draft copy'));
    await tester.pumpAndSettle();
    expect(PdfReadBack(out.shared.single.$2).pages.first,
        contains('Draft copy, not ready to make or share: 1200 errors'));
  });

  testWidgets('preparing can be cancelled, and nothing is exported', (tester) async {
    final out = RecordingOutput();
    final never = Completer<PdfExportJob>();
    await _pumpHost(tester, out, () => never.future);
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Print'));
    await tester.pump();
    expect(find.text('Preparing the PDF...'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Preparing the PDF...'), findsNothing);
    // The work finishing later is ignored.
    never.complete(_Job().job);
    await tester.pumpAndSettle();
    expect(out.calls, 0);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('dismissing the choice does nothing', (tester) async {
    final out = RecordingOutput();
    var prepared = 0;
    await _pumpHost(tester, out, () async {
      prepared++;
      return _Job().job;
    });
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(10, 10)); // the scrim
    await tester.pumpAndSettle();
    expect(prepared, 0);
    expect(out.calls, 0);
  });

  testWidgets('a failure is reported, not swallowed', (tester) async {
    final out = RecordingOutput();
    await _pumpHost(tester, out, () async => throw StateError('no chart'));
    await _choose(tester, 'Print');
    expect(find.text('Could not make the PDF: Bad state: no chart'), findsOneWidget);
    expect(out.calls, 0);
  });

  test('file names are safe on every platform', () {
    expect(pdfFileName('Harbor hat'), 'Harbor hat.pdf');
    expect(pdfFileName('a/b:c*?'), 'a-b-c--.pdf');
    expect(pdfFileName('  ..  '), 'pattern.pdf');
    expect(pdfFileName('Åsle sokker'), 'Åsle sokker.pdf');
    // A draft copy says so in its name, and a long name never cuts that off.
    expect(pdfFileName('Harbor hat', draftCopy: true), 'Harbor hat (draft copy).pdf');
    final long = pdfFileName('x' * 80, draftCopy: true);
    expect(long, endsWith(' (draft copy).pdf'));
    expect(long.length, 60 + '.pdf'.length);
  });

  group('entry points', () {
    KnitPatternDto pattern() => const KnitPatternDto(
          name: 'x',
          construction: ConstructionKind.flat,
          firstRowSide: SideKind.rs,
          castOn: 2,
          gauge: GaugeDto(sts: 18, rows: 24, unit: UnitKind.inches),
          palette: [ColorDto(r: 255, g: 255, b: 255)],
          legend: StitchLegendDto(stitches: [
            StitchDefDto(symbol: 'ns', consumes: 0, produces: 0, macroRows: 1),
            StitchDefDto(symbol: 'k', consumes: 1, produces: 1, macroRows: 1),
          ]),
          chart: ChartDto(width: 2, rows: [
            RowDto(cells: [CellDto(stitch: 1), CellDto(stitch: 1)], repeats: []),
          ]),
          notes: '',
          sections: [],
          pieces: [],
        );

    testWidgets('knit editor: More > Print or share PDF prints the open pattern', (tester) async {
      final out = RecordingOutput();
      final repo = _EditorPrintRepo(lines: const ['Cast on 2 sts.', 'Row 1 (RS): k2']);
      await tester.pumpWidget(ProviderScope(
        overrides: [..._overrides(out), knitRepositoryProvider.overrideWithValue(repo)],
        child: MaterialApp(home: KnitEditorScreen(initialPattern: pattern())),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      expect(find.text('Print or share PDF'), findsOneWidget);
      await tester.tap(find.text('Print or share PDF'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Print'));
      await tester.pumpAndSettle();
      expect(out.printed.single.$1, 'Knitting pattern.pdf', reason: 'an unsaved pattern\'s name');
      expect(isPdf(out.printed.single.$3), isTrue);
    });

    testWidgets('knit editor: a pattern with errors is not ready, asked from its readiness',
        (tester) async {
      final out = RecordingOutput();
      final repo = _EditorPrintRepo(issues: const [
        KnitIssueDto(
            code: 'cast-on-mismatch',
            severity: SeverityKind.error,
            message: 'row 1 consumes 2 stitches but the cast-on is 3'),
      ]);
      final readiness = FakeReadiness(report([
        finding(ReadinessLevel.error, 'Row 1 consumes 2 stitches but the cast-on is 3',
            place: 'Row 1', code: 'cast-on-mismatch'),
      ]));
      await tester.pumpWidget(ProviderScope(
        overrides: [
          ..._overrides(out, readiness: readiness),
          knitRepositoryProvider.overrideWithValue(repo),
        ],
        child: MaterialApp(home: KnitEditorScreen(initialPattern: pattern())),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Print or share PDF'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Share PDF'));
      await tester.pumpAndSettle();
      expect(readiness.calls, ['knit']);
      expect(find.text('This pattern is not ready to make or share'), findsOneWidget);
      expect(find.text('• Row 1: Row 1 consumes 2 stitches but the cast-on is 3'), findsOneWidget);
      await tester.tap(find.text('Go back'));
      await tester.pumpAndSettle();
      expect(out.calls, 0);
    });

    testWidgets('written instructions: the app bar prints the pattern under its name',
        (tester) async {
      final out = RecordingOutput();
      final container = ProviderContainer(overrides: [
        ..._overrides(out),
        knitRepositoryProvider.overrideWithValue(_EditorPrintRepo()),
      ]);
      addTearDown(container.dispose);
      container.read(knitEditorProvider.notifier).load(pattern());
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: KnitWrittenScreen(patternName: 'Harbor hat')),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Print or share PDF'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Share PDF'));
      await tester.pumpAndSettle();
      expect(out.shared.single.$1, 'Harbor hat.pdf');
    });

    testWidgets('nalbind project: the app bar prints what the form holds', (tester) async {
      final out = RecordingOutput();
      final readiness = FakeReadiness(report([
        finding(ReadinessLevel.error, 'Unexpected character',
            check: ReadinessCheck.notation, place: 'Notation, at "XYZ"'),
      ], checked: const [
        ReadinessCheck.notation
      ]));
      await tester.pumpWidget(ProviderScope(
        overrides: [
          ..._overrides(out, readiness: readiness),
          nalbindRepositoryProvider.overrideWithValue(_NalbindRepo())
        ],
        child: const MaterialApp(home: NalbindProjectScreen()),
      ));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Project name'), 'Winter socks');
      await tester.enterText(find.widgetWithText(TextField, 'Hansen notation'), 'UO/XYZ');
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Print or share PDF'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Print'));
      await tester.pumpAndSettle();
      expect(readiness.lastNotation, 'UO/XYZ', reason: 'the notation the form holds');
      expect(find.text('This project is not ready to make or share'), findsOneWidget,
          reason: 'strict notation errors');
      await tester.tap(find.text('Print a draft copy'));
      await tester.pumpAndSettle();
      expect(out.printed.single.$1, 'Winter socks (draft copy).pdf');
      expect(isPdf(out.printed.single.$3), isTrue);
    });
  });

  test('a draft copy: every page says so with the count of errors, and the box stays', () async {
    // (The flow's bytes are compressed; this reads the same document back in plain form.) A long
    // document, so the band is checked on more than one page.
    final j = _Job(report([
      finding(ReadinessLevel.error, 'Row 2 consumes 6 stitches but row 1 produced 7'),
      finding(ReadinessLevel.error, 'Row 5 references stitch #99'),
    ]));
    final base = j.job.document(withProblemsBox: true);
    final long = PrintDocument(
      title: base.title,
      kind: base.kind,
      problemsBox: base.problemsBox,
      sections: [
        PrintSection('Notes', [
          for (var i = 0; i < 160; i++) PrintParagraph('Line $i of a long set of notes.'),
        ]),
      ],
    );
    final copy = long.asDraftCopy(j.readiness.errors.length);
    expect(copy.draftCopy!.text, 'Draft copy, not ready to make or share: 2 errors');
    expect(copy.problemsBox!.title, 'This pattern has problems');
    final pdf = PdfReadBack(await _plain(copy));
    expect(pdf.pageCount, greaterThan(1));
    for (final page in pdf.pages) {
      expect(page, contains('Draft copy, not ready to make or share: 2 errors'));
    }
    expect(pdf.pages.first, contains('This pattern has problems'));
    // A ready document carries neither.
    final ready = PdfReadBack(await _plain(j.job.document(withProblemsBox: false)));
    expect(ready.text, isNot(contains('Draft copy')));
    expect(ready.text, isNot(contains('This pattern has problems')));
    expect(const PrintDraftCopy(errors: 1).text, 'Draft copy, not ready to make or share: 1 error');
  });
}

Future<Uint8List> _plain(PrintDocument doc) => buildPrintPdf(doc,
    page: PrintPageSetup.forUnit(MeasureUnit.inches), fonts: testFonts(), compress: false);

/// The knit repository the editor and the print flow use, with no FFI: a 1x1 preview image for the
/// editor's live chart, canned validation and written lines, rasters for printing.
class _EditorPrintRepo extends FakePrintRepo {
  _EditorPrintRepo({super.issues, super.lines});

  @override
  Future<ui.Image> render(KnitPatternDto pattern, {required int cellPx}) {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(Uint8List.fromList(const [0, 0, 0, 255]), 1, 1,
        ui.PixelFormat.rgba8888, completer.complete);
    return completer.future;
  }
}

class _NalbindRepo extends FakeReadRepo {
  @override
  Future<List<NalbindStitchDto>> builtins() async => const [];
}
