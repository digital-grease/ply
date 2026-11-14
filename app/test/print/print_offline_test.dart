import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/models/draft_doc.dart' show MeasureUnit;
import 'package:ply/src/models/nalbind_project.dart';
import 'package:ply/src/print/knit_print.dart';
import 'package:ply/src/print/nalbind_print.dart';
import 'package:ply/src/print/pdf_builder.dart';
import 'package:ply/src/print/pdf_fonts.dart';
import 'package:ply/src/print/print_layout.dart';
import 'package:ply/src/print/weave_print.dart';
import 'package:ply/src/rust/dto.dart' show ColorDto, UnitKind;
import 'package:ply/src/rust/knit_dto.dart';

import 'knit_print_test.dart' show FakePrintRepo;
import 'nalbind_print_test.dart' show FakeReadRepo;
import 'print_test_support.dart';
import 'weave_print_test_support.dart';

// Ply is local-first: making a PDF never touches the network. Every way out (an HTTP client, a
// socket, a listening socket) is trapped while a knitting, a nalbinding and a weaving PDF are built
// from the real bundled font assets; the print code is also scanned for the network-backed APIs of
// the PDF packages (Google Fonts, network images).

/// Counts and refuses every attempt to reach the network inside [body].
Future<int> _networkAttempts(Future<void> Function() body) async {
  var attempts = 0;
  Never refuse(String what) {
    attempts++;
    throw StateError('network access during PDF export: $what');
  }

  await HttpOverrides.runZoned(
    () => IOOverrides.runZoned(
      body,
      socketConnect: (host, port, {sourceAddress, sourcePort = 0, timeout}) =>
          refuse('socket $host:$port'),
      socketStartConnect: (host, port, {sourceAddress, sourcePort = 0}) =>
          refuse('socket $host:$port'),
      serverSocketBind: (address, port, {backlog = 0, v6Only = false, shared = false}) =>
          refuse('listen $address:$port'),
    ),
    createHttpClient: (_) => refuse('HTTP client'),
  );
  return attempts;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the bundled fonts load from the app assets, with their license beside them', () async {
    final fonts = await PlyPdfFonts.load();
    expect(fonts.supports('×'.runes.single), isTrue);
    expect(fonts.supports('→'.runes.single), isTrue);
    expect(fonts.supports('–'.runes.single), isTrue, reason: 'en dash');
    expect(fonts.unsupportedIn(['Åsle ØÆ ąęł Ελληνικά Кириллица m1l F1 ×3 → ← … “”']), isEmpty);
    expect(fonts.unsupportedIn(['字 ok']), ['字']);
    final license = File('assets/fonts/OFL.txt').readAsStringSync();
    expect(license, contains('SIL OPEN FONT LICENSE Version 1.1'));
    expect(license, contains('Mozilla Foundation'));
  });

  test('building a knitting and a nalbinding PDF never touches the network', () async {
    final docs = Directory.systemTemp.createTempSync('ply_offline');
    addTearDown(() => docs.deleteSync(recursive: true));
    final photos = Directory('${docs.path}/nalbinds/p1.photos')..createSync(recursive: true);
    File('${photos.path}/a.jpg').writeAsBytesSync(jpegWithExif);

    final outputs = <Uint8List>[];
    final attempts = await _networkAttempts(() async {
      final fonts = await PlyPdfFonts.load();
      final knit = await gatherKnitPrint(
        FakePrintRepo(),
        name: 'Offline hat',
        pattern: const KnitPatternDto(
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
        ),
      );
      outputs.add(await buildPrintPdf(buildKnitPrintDocument(knit, withProblemsBox: false),
          page: PrintPageSetup.forUnit(MeasureUnit.inches), fonts: fonts));
      final nal = await gatherNalbindPrint(
        FakeReadRepo(),
        project: const NalbindProject(name: 'Offline socks', notation: 'UO/UOO F1'),
        id: 'p1',
        docsOverride: docs,
      );
      outputs.add(await buildPrintPdf(buildNalbindPrintDocument(nal, withProblemsBox: false),
          page: PrintPageSetup.forUnit(MeasureUnit.centimeters), fonts: fonts));
    });
    expect(attempts, 0);
    expect(outputs.length, 2);
    for (final o in outputs) {
      expect(String.fromCharCodes(o.take(5)), '%PDF-');
    }
  });

  test('building a weaving PDF never touches the network', () async {
    Uint8List? out;
    final attempts = await _networkAttempts(() async {
      final fonts = await PlyPdfFonts.load();
      final doc = overshotDoc();
      final source = await gatherWeavePrint(FakeWeaveRepo(), name: 'Offline runner', doc: doc);
      out = await buildPrintPdf(buildWeavePrintDocument(source, withProblemsBox: false),
          page: PrintPageSetup.forUnit(MeasureUnit.centimeters), fonts: fonts);
    });
    expect(attempts, 0);
    expect(String.fromCharCodes(out!.take(5)), '%PDF-');
  });

  test('the trap itself catches a connection attempt (so a zero above means none)', () async {
    final attempts = await _networkAttempts(() async {
      try {
        HttpClient();
      } on StateError {/* refused */}
      try {
        await Socket.connect('192.0.2.1', 80);
      } on StateError {/* refused */}
    });
    expect(attempts, 2);
  });

  test('the print code uses no network-backed PDF features', () {
    final sources = Directory('lib/src/print')
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .toList();
    expect(sources, isNotEmpty);
    for (final f in sources) {
      final code = f.readAsStringSync();
      for (final banned in [
        'PdfGoogleFonts',
        'networkImage',
        'package:http/',
        'HttpClient',
        'Socket',
        'Uri.parse',
      ]) {
        expect(code, isNot(contains(banned)), reason: '${f.path} uses $banned');
      }
      // Only the export flow talks to the printing plugin, and only through the dialogs.
      if (!f.path.endsWith('print_export.dart')) {
        expect(code, isNot(contains('package:printing/')), reason: f.path);
      }
    }
  });
}
