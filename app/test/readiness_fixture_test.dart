import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/readiness_repository.dart';
import 'package:ply/src/models/app_settings.dart';
import 'package:ply/src/models/draft_doc.dart' show MeasureUnit;
import 'package:ply/src/models/nalbind_project.dart';
import 'package:ply/src/models/readiness.dart';
import 'package:ply/src/print/pdf_fonts.dart';
import 'package:ply/src/print/print_document.dart';
import 'package:ply/src/print/print_export.dart';
import 'package:ply/src/state/theme_providers.dart';

import 'print/print_export_test.dart' show RecordingOutput;
import 'print/print_test_support.dart';
import 'print/readiness_test_support.dart';

// The readiness acceptance fixtures (fixtures/<craft>/readiness/, ADR 0021, shared with the Rust
// tests), one per craft, as the print and share flow shows them. Each fixture's hand-derived oracle
// stands in for the engine (host tests have no native library; the Rust tests hold the engine to
// the same oracle): a pattern with errors is not ready and only becomes a draft copy when chosen;
// the same pattern with its errors fixed asks once about its warnings and lists what Ply could not
// check; with nothing but information it prints straight away.

/// The craft fixtures: oracle path, and the noun its flow uses.
const _fixtures = {
  'weaving': 'draft',
  'knitting': 'pattern',
  'nalbinding': 'project',
};

Map<String, dynamic> _oracle(String craft) =>
    jsonDecode(File('../fixtures/$craft/readiness/mixed-problems.expect.json').readAsStringSync())
        as Map<String, dynamic>;

ReadinessLevel _level(String s) => ReadinessLevel.values.byName(s);
ReadinessCheck _check(String s) => ReadinessCheck.values.byName(s);

/// The fixture's oracle as the readiness report the engine gives.
ReadinessReport oracleReadiness(String craft) {
  final o = _oracle(craft);
  return ReadinessReport(
    checked: [for (final c in o['checked'] as List) _check(c as String)],
    items: [
      for (final i in (o['items'] as List).cast<Map<String, dynamic>>())
        ReadinessItem(
          check: _check(i['check'] as String),
          code: i['code'] as String,
          level: _level(i['severity'] as String),
          place: i['place'] as String?,
          message: i['message'] as String,
        ),
    ],
  );
}

class _Settings extends AppSettingsNotifier {
  @override
  AppSettings build() => const AppSettings(unit: MeasureUnit.inches);
}

class _Job {
  _Job(this.readiness);
  final ReadinessReport readiness;
  final builds = <bool>[];

  PdfExportJob job(String name) => PdfExportJob(
        fileStem: name,
        readiness: readiness,
        document: ({required withProblemsBox}) {
          builds.add(withProblemsBox);
          return PrintDocument(title: name, kind: 'Test', sections: const [
            PrintSection('Notes', [PrintParagraph('Fixture.')]),
          ]);
        },
      );
}

Future<void> _run(WidgetTester tester, RecordingOutput out, _Job job, String noun,
    {String action = 'Print'}) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [
      pdfOutputProvider.overrideWithValue(out),
      plyPdfFontsProvider.overrideWith((_) async => testFonts()),
      appSettingsProvider.overrideWith(_Settings.new),
      readinessRepositoryProvider.overrideWithValue(FakeReadiness()),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: Consumer(
          builder: (context, ref, _) => Center(
            child: ElevatedButton(
              onPressed: () => printOrSharePdf(context, ref,
                  noun: noun, prepare: () async => job.job('Fixture')),
              child: const Text('go'),
            ),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('go'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(action));
  await tester.pumpAndSettle();
}

String _count(int n, String one, String many) => n == 1 ? '1 $one' : '$n $many';

void main() {
  test('every oracle is well formed and agrees with its own verdict and error count', () {
    for (final craft in _fixtures.keys) {
      final o = _oracle(craft);
      final r = oracleReadiness(craft);
      expect(
          r.verdict.name,
          switch (o['verdict']) {
            'not_ready' => 'notReady',
            'needs_acknowledgement' => 'needsAcknowledgement',
            _ => 'ready',
          },
          reason: craft);
      expect(r.errors.length, o['errors'], reason: craft);
      // Most serious first, as the engine lists them.
      final order = [for (final i in r.items) i.level.index];
      expect(order, [...order]..sort(), reason: craft);
      // A realistic mix: something of every kind the craft can report.
      expect(r.errors, isNotEmpty, reason: craft);
      expect(r.warnings, isNotEmpty, reason: craft);
      expect(r.unsupported, isNotEmpty, reason: craft);
    }
  });

  test('the nalbinding fixture is in the app\'s own byte layout', () {
    final text = File('../fixtures/nalbinding/readiness/mixed-problems.plynal').readAsStringSync();
    final project = NalbindProject.decode(text);
    expect(jsonEncode(project.toJson()), text, reason: 're-encoding gives the same bytes');
    expect(project.notation, 'uo/uoo f1');
    expect(project.recipe!.segments, hasLength(7));
  });

  for (final MapEntry(key: craft, value: noun) in _fixtures.entries) {
    group(craft, () {
      testWidgets(
          'with errors it is not ready: every error is listed with its place, and only a '
          'draft copy is made', (tester) async {
        final r = oracleReadiness(craft);
        final out = RecordingOutput();
        final job = _Job(r);
        await _run(tester, out, job, noun);
        expect(find.text('This $noun is not ready to make or share'), findsOneWidget);
        expect(find.text('Ply found ${_count(r.errors.length, 'error', 'errors')} in this $noun:'),
            findsOneWidget);
        for (final e in r.errors) {
          expect(find.text('• ${e.text}'), findsOneWidget, reason: e.code);
          expect(e.place, isNotNull, reason: 'every fixture error is placed: ${e.code}');
        }
        final others = [
          if (r.warnings.isNotEmpty) _count(r.warnings.length, 'warning', 'warnings'),
          if (r.unsupported.isNotEmpty)
            _count(r.unsupported.length, 'thing Ply could not check', 'things Ply could not check'),
        ];
        expect(find.text('It also has ${others.join(' and ')}.'), findsOneWidget);
        expect(find.widgetWithText(FilledButton, 'Go back'), findsOneWidget);
        await tester.tap(find.text('Print a draft copy'));
        await tester.pumpAndSettle();
        expect(out.printed.single.$1, 'Fixture (draft copy).pdf');
        expect(job.builds, [true], reason: 'the draft copy keeps the problems box');
      });

      testWidgets(
          'with its errors fixed, the warnings and what Ply could not check are '
          'acknowledged in one step', (tester) async {
        final full = oracleReadiness(craft);
        final r = ReadinessReport(
            checked: full.checked, items: [...full.warnings, ...full.unsupported, ...full.info]);
        expect(r.verdict, ReadinessVerdict.needsAcknowledgement);
        final out = RecordingOutput();
        final job = _Job(r);
        await _run(tester, out, job, noun, action: 'Share PDF');
        expect(find.text('Check this $noun before you share it'), findsOneWidget);
        expect(find.text('Warnings'), findsOneWidget);
        for (final w in r.warnings) {
          expect(find.text('• ${w.text}'), findsOneWidget, reason: w.code);
        }
        expect(find.text('Ply could not check'), findsOneWidget);
        for (final u in r.unsupported.take(6)) {
          expect(find.text('• ${u.text}'), findsOneWidget, reason: u.code);
        }
        for (final i in r.info) {
          expect(find.text('• ${i.text}'), findsNothing, reason: 'information never asks');
        }
        expect(find.textContaining('Ply found no errors in ${r.checkedWords}.'), findsOneWidget);
        await tester.tap(find.text('Acknowledge and share'));
        await tester.pumpAndSettle();
        expect(out.shared.single.$1, 'Fixture.pdf', reason: 'a ready copy');
        expect(job.builds, [false]);
      });

      testWidgets('with only information it is ready and prints straight away', (tester) async {
        final full = oracleReadiness(craft);
        final r = ReadinessReport(checked: full.checked, items: full.info);
        final out = RecordingOutput();
        final job = _Job(r);
        await _run(tester, out, job, noun);
        expect(find.byType(AlertDialog), findsNothing);
        expect(out.printed.single.$1, 'Fixture.pdf');
        expect(job.builds, [false]);
      });
    });
  }
}
