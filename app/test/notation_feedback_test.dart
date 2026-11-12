import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/nalbind_repository.dart';
import 'package:ply/src/rust/dto.dart' show SeverityKind;
import 'package:ply/src/rust/nalbind_dto.dart';
import 'package:ply/src/widgets/nalbind_diagram_view.dart';
import 'package:ply/src/widgets/notation_feedback.dart';

import 'nalbind_test_support.dart';

// Unit coverage for the notation-reading UI pieces: the trust rule (`isExact`), the repository's
// read composition (validation only for an exact reading), the findings list (order, quoting,
// collapsed formatting notes), and the diagram's schematic caption and approximate label.

const _stitch = NalbindStitchDto(
  name: '',
  passes: [
    PassDto(steps: [StepKind.under, StepKind.over]),
  ],
  connections: [ConnectionDto(side: ConnSideKind.front, count: 1)],
  twist: TwistKind.untwisted,
  alsoKnownAs: [],
  codes: [],
  note: '',
);

final _diagram = DiagramDto(
  width: 4,
  height: 2.6,
  baseline: 1.6,
  loops: const [LoopGlyphDto(x: 0.5, kind: LoopKindDto.underEngaged)],
  turns: Float32List(0),
  connections: const [],
);

class _ReadRepo extends NalbindRepository {
  _ReadRepo(this.result);

  final ParsedNotationDto result;
  int validateCount = 0;

  @override
  Future<ParsedNotationDto> analyze(String notation, {required bool strict}) async => result;

  @override
  Future<DiagramDto> diagram(NalbindStitchDto dto) async => _diagram;

  @override
  Future<List<NalbindIssueDto>> validate(NalbindStitchDto dto) async {
    validateCount++;
    return const [NalbindIssueDto(severity: SeverityKind.warning, message: 'checked')];
  }
}

Future<void> pumpFeedback(WidgetTester tester, ParsedNotationDto parsed,
    {List<NalbindIssueDto> issues = const []}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(body: NotationFeedback(parsed: parsed, issues: issues)),
  ));
}

void main() {
  group('isExact', () {
    test('only an accepted, non-lossy reading is exact', () {
      expect(reading('UO F1', _stitch).isExact, isTrue);
      expect(reading('uo f1', _stitch, fidelity: FidelityKind.normalized).isExact, isTrue);
      // A repeated connection is read faithfully but is ambiguous, so strict refuses it.
      expect(reading('UO F1 F1', _stitch, accepted: false).isExact, isFalse);
      expect(
          reading('UO/X', _stitch, accepted: false, fidelity: FidelityKind.lossy).isExact, isFalse);
    });
  });

  group('NalbindRepository.read', () {
    test('an exact reading is diagrammed and validated', () async {
      final repo = _ReadRepo(reading('UO F1', _stitch));
      final r = await repo.read('UO F1', strict: true);
      expect(r.diagram, same(_diagram));
      expect(r.issues.single.message, 'checked');
      expect(repo.validateCount, 1);
    });

    test('an approximate reading is diagrammed but not validated', () async {
      final repo = _ReadRepo(badReading(_stitch, strict: true));
      final r = await repo.read('UO/XYZ', strict: true);
      expect(r.diagram, same(_diagram), reason: 'the best effort is still drawn');
      expect(r.issues, isEmpty, reason: "the notation's own findings already say what is wrong");
      expect(repo.validateCount, 0);
    });
  });

  group('NotationFeedback', () {
    testWidgets('errors come first, then warnings, validation issues at their own severity',
        (tester) async {
      await pumpFeedback(tester, badReading(_stitch, strict: false), issues: const [
        NalbindIssueDto(severity: SeverityKind.error, message: 'issue error'),
        NalbindIssueDto(severity: SeverityKind.warning, message: 'issue warning'),
      ]);
      final order = [
        find.text(shownFinding(
            'Error', 'XYZ', 'unexpected characters `XYZ`; kept verbatim as an opaque token')),
        find.text('Error: issue error'),
        find.text(
            shownFinding('Warning', '/', 'turn `/` comes after the last needle step; dropped')),
        find.text('Warning: issue warning'),
      ];
      for (final f in order) {
        expect(f, findsOneWidget);
      }
      final ys = order.map((f) => tester.getTopLeft(f).dy).toList();
      for (var i = 1; i < ys.length; i++) {
        expect(ys[i], greaterThan(ys[i - 1]), reason: 'row $i is out of order');
      }
    });

    testWidgets('a whitespace-only span is not quoted; its message describes it', (tester) async {
      const src = 'UO F1';
      await pumpFeedback(
        tester,
        reading(src, _stitch, fidelity: FidelityKind.normalized, normalized: 'UO F1', diagnostics: [
          diagnostic(src, 'whitespace-normalized', NotationSeverityKind.info, 2, 3,
              'non-canonical whitespace before a connection is normalized away'),
        ]),
      );
      expect(find.text('Reads as UO F1 (1 formatting note)'), findsOneWidget);
      await tester.tap(find.text('Reads as UO F1 (1 formatting note)'));
      await tester.pump();
      expect(find.text('Note: non-canonical whitespace before a connection is normalized away'),
          findsOneWidget);
    });

    testWidgets('a long quote is shortened', (tester) async {
      final src = 'X' * 60;
      await pumpFeedback(
        tester,
        reading(src, _stitch, accepted: false, fidelity: FidelityKind.lossy, diagnostics: [
          diagnostic(src, 'unexpected-character', NotationSeverityKind.error, 0, 60, 'too long'),
        ]),
      );
      expect(find.text('Error at "${'X' * 39}…": too long'), findsOneWidget);
    });

    testWidgets('a rejected reading never claims what it reads as', (tester) async {
      const src = 'uo:uoo';
      await pumpFeedback(
        tester,
        reading(src, _stitch,
            strict: true,
            accepted: false,
            fidelity: FidelityKind.lossy,
            normalized: 'UO/UOO',
            diagnostics: [
              diagnostic(src, 'case-normalized', NotationSeverityKind.info, 0, 2,
                  'lowercase `uo` is read as uppercase'),
              diagnostic(src, 'turn-marker-mismatch', NotationSeverityKind.error, 2, 3,
                  '`:` is used for the first turn'),
              diagnostic(src, 'case-normalized', NotationSeverityKind.info, 3, 6,
                  'lowercase `uoo` is read as uppercase'),
            ]),
      );
      expect(
          find.text(shownFinding('Error', ':', '`:` is used for the first turn')), findsOneWidget);
      expect(find.text('2 formatting notes'), findsOneWidget);
      expect(find.textContaining('Reads as'), findsNothing);
    });

    testWidgets('a clean reading shows nothing', (tester) async {
      await pumpFeedback(tester, reading('UO/UOO F1', _stitch));
      expect(find.byType(Text), findsNothing);
    });
  });

  group('NalbindDiagramView', () {
    const caption = "Sketch of one stitch's needle path, not a picture of finished fabric.";
    const approximate =
        'Approximate: the notation was not read exactly, so this sketch may be wrong.';

    testWidgets('always carries the schematic caption', (tester) async {
      await tester.pumpWidget(
          MaterialApp(home: Scaffold(body: NalbindDiagramView(diagram: _diagram))));
      expect(find.text(caption), findsOneWidget);
      expect(find.text(approximate), findsNothing);
      expect(find.byType(Opacity), findsNothing);
    });

    testWidgets('an approximate diagram is labelled and dimmed', (tester) async {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(body: NalbindDiagramView(diagram: _diagram, approximate: true))));
      expect(find.text(approximate), findsOneWidget);
      expect(find.text(caption), findsOneWidget);
      expect(tester.widget<Opacity>(find.byType(Opacity)).opacity, lessThan(1));
    });
  });
}
