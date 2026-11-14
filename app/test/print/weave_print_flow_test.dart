import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/models/app_settings.dart';
import 'package:ply/src/models/draft_doc.dart';
import 'package:ply/src/models/draft_issue.dart';
import 'package:ply/src/models/draft_meta.dart';
import 'package:ply/src/models/drawdown_region.dart';
import 'package:ply/src/print/pdf_fonts.dart';
import 'package:ply/src/print/print_document.dart';
import 'package:ply/src/print/print_export.dart';
import 'package:ply/src/print/weave_print.dart';
import 'package:ply/src/rust/api.dart' show PreviewImage;
import 'package:ply/src/screens/editor_screen.dart';
import 'package:ply/src/state/draft_editor_notifier.dart';
import 'package:ply/src/state/editor_providers.dart';
import 'package:ply/src/state/theme_providers.dart';

import '../editor_screen_test.dart' show FakeRepo, letAsyncSettle;
import 'print_export_test.dart' show RecordingOutput;
import 'print_test_support.dart';
import 'weave_print_test_support.dart';

// "Print or share PDF" from the weaving editor: a separate overflow action (not Save, not the WIF),
// the book draft layout chosen in the Print / Share sheet (the editor's layout by default, no extra
// tap), the draft printed as it is in the editor, and the readiness question for a draft with errors.

/// The editor's repository with the print engine calls faked.
class _PrintRepo extends FakeRepo {
  int printRenders = 0;

  @override
  Future<PreviewImage> renderRegionPixels(DraftDoc doc, DrawdownRegion region,
      {required int cellPx}) async {
    printRenders++;
    return fakeEnginePixels(doc, region);
  }
}

class _Settings extends AppSettingsNotifier {
  @override
  AppSettings build() => const AppSettings(unit: MeasureUnit.centimeters);
}

Future<ProviderContainer> _pump(WidgetTester tester, _PrintRepo repo, RecordingOutput out,
    {DraftDoc? doc}) async {
  final container = ProviderContainer(overrides: [
    repositoryProvider.overrideWithValue(repo),
    pdfOutputProvider.overrideWithValue(out),
    plyPdfFontsProvider.overrideWith((_) async => testFonts()),
    appSettingsProvider.overrideWith(_Settings.new),
  ]);
  addTearDown(container.dispose);
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      home: EditorScreen(
        initialDoc: doc ?? aw2Doc(),
        title: 'Harbor runner',
        meta: DraftMeta(
            name: 'Harbor runner',
            author: 'Guild sample',
            savedAt: DateTime.utc(2026),
            lastOpened: DateTime.utc(2026)),
      ),
    ),
  ));
  await letAsyncSettle(tester);
  return container;
}

Future<void> _openPrint(WidgetTester tester) async {
  await tester.tap(find.byTooltip('More actions'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Print or share PDF'));
  await tester.pumpAndSettle();
}

bool _isPdf(Uint8List b) => String.fromCharCodes(b.take(5)) == '%PDF-';

void main() {
  testWidgets('the weaving editor shares the draft as a PDF, in the editor layout by default',
      (tester) async {
    final repo = _PrintRepo();
    final out = RecordingOutput();
    final container = await _pump(tester, repo, out);
    await _openPrint(tester);
    // The layout choice sits in the sheet, already on the editor's layout.
    expect(find.text('Book draft layout'), findsOneWidget);
    expect(find.text('Tie-up top right'), findsOneWidget);
    expect(find.text("Ply's editor layout, common in North American books."), findsOneWidget);
    await tester.tap(find.text('Share PDF'));
    await tester.pumpAndSettle();
    expect(out.shared.single.$1, 'Harbor runner.pdf');
    expect(_isPdf(out.shared.single.$2), isTrue);
    expect(repo.printRenders, 2, reason: 'interlacement and colors, once each');
    expect(container.read(weavePrintCornerProvider), BookCorner.topRight);
  });

  testWidgets('a layout chosen in the sheet is kept for the session', (tester) async {
    final repo = _PrintRepo();
    final out = RecordingOutput();
    final container = await _pump(tester, repo, out);
    await _openPrint(tester);
    await tester.tap(find.byKey(const ValueKey('book-layout')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tie-up bottom left').last);
    await tester.pumpAndSettle();
    expect(find.text('Mirror image with the threading at the bottom.'), findsOneWidget);
    expect(container.read(weavePrintCornerProvider), BookCorner.bottomLeft);
    await tester.tap(find.text('Print'));
    await tester.pumpAndSettle();
    expect(out.printed.single.$1, 'Harbor runner.pdf');
    expect(_isPdf(out.printed.single.$3), isTrue);
    // Opened again: the sheet remembers the choice.
    await _openPrint(tester);
    expect(find.text('Tie-up bottom left'), findsOneWidget);
  });

  testWidgets('a draft with errors asks first; cancel exports nothing', (tester) async {
    final repo = _PrintRepo()
      ..issues = const [
        DraftIssue(
            severity: IssueSeverity.error, message: 'pick 3 presses treadle 9 which has no tie-up'),
      ];
    final out = RecordingOutput();
    await _pump(tester, repo, out);
    await _openPrint(tester);
    await tester.tap(find.text('Share PDF'));
    await tester.pumpAndSettle();
    expect(find.text('This draft has problems'), findsOneWidget);
    expect(find.text('• Pick 3 presses treadle 9 which has no tie-up'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(out.calls, 0);
    await _openPrint(tester);
    await tester.tap(find.text('Share PDF'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Share anyway'));
    await tester.pumpAndSettle();
    expect(out.shared, hasLength(1));
  });

  testWidgets('the PDF prints the draft as it is in the editor, unsaved edits included',
      (tester) async {
    final repo = _PrintRepo();
    final out = RecordingOutput();
    final container = await _pump(tester, repo, out);
    // An unsaved edit: the first pick's treadle changes.
    final notifier = container.read(draftEditorProvider.notifier);
    final before = container.read(draftEditorProvider).draft;
    final treadled = before.drive as DraftTreadled;
    notifier.commitEdit(before.copyWith(
        drive: treadled.copyWith(treadling: [
      [4],
      ...treadled.treadling.skip(1)
    ])));
    final source = await gatherWeavePrint(repo,
        name: 'Harbor runner', doc: container.read(draftEditorProvider).draft);
    expect(source.doc.drive.rows.first, [4]);
    final d = buildWeavePrintDocument(source, withProblemsBox: false);
    final book = d.sections
        .firstWhere((s) => s.heading == 'Draft')
        .blocks
        .whereType<PrintBookDraft>()
        .single;
    expect(book.treadling.first, [4]);
  });
}
