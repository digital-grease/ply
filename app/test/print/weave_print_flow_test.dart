import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/loom_repository.dart' show LoomFileStatus;
import 'package:ply/src/data/readiness_repository.dart';
import 'package:ply/src/models/app_settings.dart';
import 'package:ply/src/models/draft_doc.dart';
import 'package:ply/src/models/draft_issue.dart';
import 'package:ply/src/models/draft_meta.dart';
import 'package:ply/src/models/drawdown_region.dart';
import 'package:ply/src/models/loom_check.dart';
import 'package:ply/src/models/readiness.dart';
import 'package:ply/src/print/pdf_fonts.dart';
import 'package:ply/src/print/print_document.dart';
import 'package:ply/src/print/print_export.dart';
import 'package:ply/src/print/weave_print.dart';
import 'package:ply/src/rust/api.dart' show PreviewImage;
import 'package:ply/src/screens/editor_screen.dart';
import 'package:ply/src/state/draft_editor_notifier.dart';
import 'package:ply/src/state/editor_providers.dart';
import 'package:ply/src/state/loom_providers.dart';
import 'package:ply/src/state/weave_plan_providers.dart';
import 'package:ply/src/state/material_providers.dart';
import 'package:ply/src/models/weave_plan.dart';
import 'package:ply/src/data/materials_repository.dart' show MaterialLibrary;
import 'package:ply/src/state/theme_providers.dart';

import '../editor_screen_test.dart' show FakeRepo, letAsyncSettle;
import 'print_export_test.dart' show RecordingOutput;
import 'print_test_support.dart';
import 'readiness_test_support.dart';
import 'weave_print_test_support.dart';

// "Print or share PDF" from the weaving editor: a separate overflow action (not Save, not the WIF),
// the book draft layout chosen in the Print / Share sheet (the editor's layout by default, no extra
// tap), the draft printed as it is in the editor, and readiness (ADR 0021): a draft with errors is
// only a draft copy, and a loom chosen for the draft that Ply cannot find is listed as not checked.

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
    {DraftDoc? doc, FakeReadiness? readiness, List<Override> extra = const []}) async {
  final container = ProviderContainer(overrides: [
    repositoryProvider.overrideWithValue(repo),
    pdfOutputProvider.overrideWithValue(out),
    plyPdfFontsProvider.overrideWith((_) async => testFonts()),
    appSettingsProvider.overrideWith(_Settings.new),
    readinessRepositoryProvider.overrideWithValue(readiness ?? FakeReadiness()),
    // The recorded bytes are read back: they must not be compressed.
    pdfCompressProvider.overrideWithValue(false),
    ...extra,
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

  testWidgets('a draft with errors is not ready: go back, or a draft copy marked as one',
      (tester) async {
    final repo = _PrintRepo()
      ..issues = const [
        DraftIssue(
            severity: IssueSeverity.error,
            code: 'weave.treadle_untied',
            place: 'Pick 3, treadle 9',
            message: 'pick 3 presses treadle 9 which has no tie-up'),
      ];
    final readiness = FakeReadiness(report([
      finding(ReadinessLevel.error, 'Pick 3 presses treadle 9 which has no tie-up',
          check: ReadinessCheck.draft, place: 'Pick 3, treadle 9', code: 'weave.treadle_untied'),
    ], checked: const [
      ReadinessCheck.draft
    ]));
    final out = RecordingOutput();
    await _pump(tester, repo, out, readiness: readiness);
    await _openPrint(tester);
    await tester.tap(find.text('Share PDF'));
    await tester.pumpAndSettle();
    expect(readiness.calls, ['weave']);
    expect(find.text('This draft is not ready to make or share'), findsOneWidget);
    expect(find.text('• Pick 3, treadle 9: Pick 3 presses treadle 9 which has no tie-up'),
        findsOneWidget);
    await tester.tap(find.text('Go back'));
    await tester.pumpAndSettle();
    expect(out.calls, 0);
    await _openPrint(tester);
    await tester.tap(find.text('Share PDF'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Share a draft copy'));
    await tester.pumpAndSettle();
    expect(out.shared.single.$1, 'Harbor runner (draft copy).pdf');
  });

  testWidgets('a draft copy of a book draft split over several pages is marked on every page',
      (tester) async {
    final repo = _PrintRepo()
      ..issues = const [
        DraftIssue(
            severity: IssueSeverity.error,
            code: 'weave.treadle_untied',
            place: 'Pick 3, treadle 9',
            message: 'pick 3 presses treadle 9 which has no tie-up'),
      ];
    final readiness = FakeReadiness(report([
      finding(ReadinessLevel.error, 'Pick 3 presses treadle 9 which has no tie-up',
          check: ReadinessCheck.draft, place: 'Pick 3, treadle 9', code: 'weave.treadle_untied'),
    ], checked: const [
      ReadinessCheck.draft
    ]));
    final out = RecordingOutput();
    await _pump(tester, repo, out,
        readiness: readiness, doc: largeDoc(ends: 160, picks: 260, shafts: 8));
    await _openPrint(tester);
    await tester.tap(find.text('Share PDF'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Share a draft copy'));
    await tester.pumpAndSettle();
    final pdf = PdfReadBack(out.shared.single.$2);
    expect(pdf.pageCount, greaterThan(3));
    expect(pdf.text, contains('Part 2 of'), reason: 'the book draft is split into parts');
    for (final page in pdf.pages) {
      expect(page, contains('Draft copy, not ready to make or share: 1 error'));
    }
    expect(pdf.pages.first, contains('This draft has problems'));
  });

  group('the plan and the loom Ply cannot check are listed, never left out', () {
    Future<void> acknowledge(WidgetTester tester, List<Override> extra,
        void Function(ProviderContainer c) set, String message) async {
      final repo = _PrintRepo();
      final readiness = FakeReadiness();
      final out = RecordingOutput();
      final c = await _pump(tester, repo, out, readiness: readiness, extra: extra);
      set(c);
      await _openPrint(tester);
      await tester.tap(find.text('Print'));
      await tester.pumpAndSettle();
      expect(find.text('Check this draft before you print it'), findsOneWidget);
      expect(find.text('Ply could not check'), findsOneWidget);
      expect(find.text('• $message'), findsOneWidget);
      await tester.tap(find.text('Acknowledge and print'));
      await tester.pumpAndSettle();
      // The PDF says so too.
      final pdf = PdfReadBack(out.printed.single.$3);
      expect(pdf.text, contains('Not checked by Ply'));
    }

    testWidgets('a yarn the plan names that is no longer in the materials', (tester) async {
      await acknowledge(
        tester,
        [materialLibraryProvider.overrideWith(_NoMaterials.new)],
        (c) => c.read(draftWeavePlanProvider.notifier).state =
            WeavePlan(warpMaterialId: 'gone', warpMaterialName: '8/2 cotton'),
        'The warp and weft plan names the warp yarn "8/2 cotton", which is no longer in your '
        'materials and swatches, so Ply could not check the plan with it or the yarn on hand.',
      );
    });

    testWidgets('materials and swatches that cannot be read', (tester) async {
      await acknowledge(
        tester,
        [materialLibraryProvider.overrideWith(_BrokenMaterials.new)],
        (c) => c.read(draftWeavePlanProvider.notifier).state = WeavePlan(
            swatchId: 'sw', swatchName: 'Towel sample', warpMaterialId: 'm', weftMaterialId: 'm'),
        'Ply could not check the warp and weft plan with the swatch "Towel sample" and the warp '
        'yarn: your materials and swatches could not be read on this device.',
      );
    });

    testWidgets('a plan saved by a newer Ply', (tester) async {
      await acknowledge(
        tester,
        const [],
        (c) => c.read(draftWeavePlanLockedProvider.notifier).state = true,
        "This draft's warp and weft plan was saved by a newer version of Ply, so this version "
        'could not check it.',
      );
    });

    testWidgets('a loom from My looms that cannot be used, said once, without a doubled stop',
        (tester) async {
      await acknowledge(
        tester,
        [loomLibraryProvider.overrideWith(_NewerLooms.new)],
        (c) => c.read(draftLoomPlanProvider.notifier).state =
            LoomPlan(loomId: 'l', loomName: 'Big loom'),
        'Ply could not check the draft against Big loom, the loom chosen for it: My looms was '
        'saved by a newer version of Ply and cannot be used until Ply is updated.',
      );
    });
  });

  testWidgets('a loom chosen for the draft that is not in My looms is listed as not checked',
      (tester) async {
    final repo = _PrintRepo();
    final readiness = FakeReadiness();
    final out = RecordingOutput();
    final container = await _pump(tester, repo, out,
        readiness: readiness, extra: [loomLibraryProvider.overrideWith(_NoLooms.new)]);
    container.read(draftLoomPlanProvider.notifier).state =
        LoomPlan(loomId: 'gone', loomName: 'Big loom');
    await _openPrint(tester);
    await tester.tap(find.text('Print'));
    await tester.pumpAndSettle();
    expect(readiness.lastLoom, isNull, reason: 'no profile to check against');
    expect(find.text('Check this draft before you print it'), findsOneWidget);
    expect(find.text('Ply could not check'), findsOneWidget);
    expect(
        find.text('• Ply could not check the draft against Big loom, the loom chosen for it: it '
            'is not in My looms.'),
        findsOneWidget);
    await tester.tap(find.text('Acknowledge and print'));
    await tester.pumpAndSettle();
    expect(out.printed.single.$1, 'Harbor runner.pdf');
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

/// My looms with no looms in it.
class _NoLooms extends LoomLibraryNotifier {
  @override
  Future<LoomLibraryState> build() async => const LoomLibraryState([]);
}

/// No materials or swatches.
class _NoMaterials extends MaterialLibraryNotifier {
  @override
  Future<MaterialLibraryState> build() async => const MaterialLibraryState(MaterialLibrary.empty);
}

/// Materials and swatches that cannot be read.
class _BrokenMaterials extends MaterialLibraryNotifier {
  @override
  Future<MaterialLibraryState> build() async => throw StateError('disk gone');
}

/// My looms from a newer Ply: read-only, with its reason.
class _NewerLooms extends LoomLibraryNotifier {
  @override
  Future<LoomLibraryState> build() async =>
      const LoomLibraryState([], status: LoomFileStatus.newer);
}
