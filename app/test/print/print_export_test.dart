import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart' show PdfPageFormat;
import 'package:ply/src/models/app_settings.dart';
import 'package:ply/src/models/draft_doc.dart' show MeasureUnit;
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

// The "Print or share PDF" flow: the Print / Share choice, the export-readiness question for a
// pattern with errors (cancel exports nothing; "anyway" prints the problems box), the paper by
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

List<Override> _overrides(RecordingOutput out, {MeasureUnit unit = MeasureUnit.inches}) => [
      pdfOutputProvider.overrideWithValue(out),
      plyPdfFontsProvider.overrideWith((_) async => testFonts()),
      appSettingsProvider.overrideWith(() => _FixedSettings(unit)),
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

/// A job whose document records every build.
class _Job {
  _Job(this.errors);
  final List<String> errors;
  final builds = <bool>[];

  PdfExportJob get job => PdfExportJob(
        fileStem: 'Harbor hat',
        errors: errors,
        document: ({required withProblemsBox}) {
          builds.add(withProblemsBox);
          return PrintDocument(
            title: 'Harbor hat',
            kind: 'Knitting pattern',
            problemsBox: withProblemsBox
                ? PrintNotice(
                    level: PrintNoticeLevel.problem,
                    title: 'This pattern has problems',
                    lines: errors)
                : null,
            sections: const [
              PrintSection('Notes', [PrintParagraph('Warm.')])
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

String _text(Uint8List bytes) => PdfReadBack(bytes).text;

const _errors = ['Row 2 consumes 6 stitches but row 1 produced 7'];

void main() {
  // The PDF bytes are compressed in the flow; read them back through a second, uncompressed build
  // where content matters (PdfReadBack needs plain streams), and check the bytes are a real PDF.
  bool isPdf(Uint8List b) => String.fromCharCodes(b.take(5)) == '%PDF-';

  testWidgets('a clean pattern prints straight away on the units-setting paper', (tester) async {
    final out = RecordingOutput();
    final j = _Job(const []);
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
    await _pumpHost(tester, out, () async => _Job(const []).job, unit: MeasureUnit.centimeters);
    await _choose(tester, 'Print');
    expect(out.printed.single.$2.width, closeTo(PdfPageFormat.a4.width, 0.01));
  });

  testWidgets('errors: the question lists them, and Cancel exports nothing', (tester) async {
    final out = RecordingOutput();
    final j = _Job(_errors);
    await _pumpHost(tester, out, () async => j.job);
    await _choose(tester, 'Print');
    expect(find.text('This pattern has problems'), findsOneWidget);
    expect(find.text('Ply found 1 error in this pattern:'), findsOneWidget);
    expect(find.text('• ${_errors.single}'), findsOneWidget);
    expect(find.text('Print anyway'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(out.calls, 0);
    expect(j.builds, isEmpty, reason: 'no document was even built');
  });

  testWidgets('errors: Print anyway prints the PDF with the problems box', (tester) async {
    final out = RecordingOutput();
    final j = _Job(_errors);
    await _pumpHost(tester, out, () async => j.job);
    await _choose(tester, 'Print');
    await tester.tap(find.text('Print anyway'));
    await tester.pumpAndSettle();
    expect(out.printed.length, 1);
    expect(j.builds, [true]);
    expect(j.job.document(withProblemsBox: true).problemsBox!.lines, _errors);
  });

  testWidgets('errors: Share anyway hands the share sheet a PDF named after the pattern',
      (tester) async {
    final out = RecordingOutput();
    final j = _Job(_errors);
    await _pumpHost(tester, out, () async => j.job);
    await _choose(tester, 'Share PDF');
    expect(find.text('Share anyway'), findsOneWidget);
    await tester.tap(find.text('Share anyway'));
    await tester.pumpAndSettle();
    expect(out.printed, isEmpty);
    final (file, bytes) = out.shared.single;
    expect(file, 'Harbor hat.pdf');
    expect(isPdf(bytes), isTrue);
    expect(j.builds, [true]);
  });

  testWidgets('dismissing the choice does nothing', (tester) async {
    final out = RecordingOutput();
    var prepared = 0;
    await _pumpHost(tester, out, () async {
      prepared++;
      return _Job(const []).job;
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

    testWidgets('knit editor: a pattern with errors asks first', (tester) async {
      final out = RecordingOutput();
      final repo = _EditorPrintRepo(issues: const [
        KnitIssueDto(
            severity: SeverityKind.error,
            message: 'row 1 consumes 2 stitches but the cast-on is 3'),
      ]);
      await tester.pumpWidget(ProviderScope(
        overrides: [..._overrides(out), knitRepositoryProvider.overrideWithValue(repo)],
        child: MaterialApp(home: KnitEditorScreen(initialPattern: pattern())),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Print or share PDF'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Share PDF'));
      await tester.pumpAndSettle();
      expect(find.text('This pattern has problems'), findsOneWidget);
      expect(find.text('• Row 1 consumes 2 stitches but the cast-on is 3'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
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
      await tester.pumpWidget(ProviderScope(
        overrides: [
          ..._overrides(out),
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
      expect(find.text('This project has problems'), findsOneWidget,
          reason: 'strict notation errors');
      await tester.tap(find.text('Print anyway'));
      await tester.pumpAndSettle();
      expect(out.printed.single.$1, 'Winter socks.pdf');
      expect(isPdf(out.printed.single.$3), isTrue);
    });
  });

  test('print anyway: the uncompressed build of the same document carries the box', () async {
    // (The flow's bytes are compressed; this reads the same document back in plain form.)
    final j = _Job(_errors);
    final doc = j.job.document(withProblemsBox: true);
    expect(doc.problemsBox!.title, 'This pattern has problems');
    expect(_text(await _plain(doc)), contains('This pattern has problems'));
    expect(_text(await _plain(j.job.document(withProblemsBox: false))),
        isNot(contains('This pattern has problems')));
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
