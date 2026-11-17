import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/nalbind_repository.dart';
import 'package:ply/src/rust/dto.dart' show SeverityKind;
import 'package:ply/src/rust/nalbind_dto.dart';
import 'package:ply/src/screens/nalbind_reference_screen.dart';
import 'package:ply/src/state/nalbind_providers.dart';
import 'package:ply/src/widgets/nalbind_diagram_view.dart';

import 'nalbind_test_support.dart';

// Host coverage for the Nalbinding reference tab: the builtin dictionary renders (name + notation +
// diagram + schematic caption), and the notation playground reads a string in LENIENT (reference)
// mode, lists its findings under the field (errors first, formatting notes collapsed), and labels a
// diagram drawn from an inexact reading as approximate. A fake repo returns fixed DTOs (no FFI).

const _oslo = NalbindStitchDto(
  name: 'Oslo',
  passes: [
    PassDto(steps: [StepKind.under, StepKind.over]),
    PassDto(steps: [StepKind.under, StepKind.over, StepKind.over]),
  ],
  connections: [ConnectionDto(side: ConnSideKind.front, count: 1)],
  thumbLoops: ThumbLoopsDto(a: 1, b: 1),
  twist: TwistKind.untwisted,
  alsoKnownAs: ['Finnish 1+1'],
  codes: [PublishedCodeDto(code: 'UO/UOO F1', source: 'neulakintaat.fi')],
  note: 'The classic beginner stitch.',
);

/// The best-effort structure of `UO/XYZ` (just `UO`).
const _uo = NalbindStitchDto(
  name: '',
  passes: [
    PassDto(steps: [StepKind.under, StepKind.over]),
  ],
  connections: [],
  twist: TwistKind.untwisted,
  alsoKnownAs: [],
  codes: [],
  note: '',
);

final _diagram = DiagramDto(
  width: 6,
  height: 2.6,
  baseline: 1.6,
  loops: const [
    LoopGlyphDto(x: 0.5, kind: LoopKindDto.underEngaged),
    LoopGlyphDto(x: 1.5, kind: LoopKindDto.overEngaged),
    LoopGlyphDto(x: 2.5, kind: LoopKindDto.overSkipped),
    LoopGlyphDto(x: 3.5, kind: LoopKindDto.noLoop),
  ],
  turns: Float32List.fromList([2.0]),
  connections: const [ConnArrowDto(x: 6, side: ConnSideKind.front, count: 1)],
);

const _caption = "Sketch of one stitch's needle path, not a picture of finished fabric.";
const _approximate = 'Approximate: the notation was not read exactly, so this sketch may be wrong.';

class FakeNalbindRepo extends NalbindRepository {
  /// The `strict` flag of every analyze call, in order.
  final modes = <bool>[];
  int validateCount = 0;

  /// When true, analyze throws (the bridge itself failing).
  bool analyzeError = false;

  /// What validate returns for an exact reading.
  List<NalbindIssueDto> issues = const [];

  @override
  Future<List<NalbindStitchDto>> builtins() async => [_oslo];

  @override
  Future<DiagramDto> diagram(NalbindStitchDto dto) async => _diagram;

  @override
  Future<ParsedNotationDto> analyze(String notation, {required bool strict}) async {
    modes.add(strict);
    if (analyzeError) throw Exception('bridge unavailable');
    return switch (notation) {
      'UO/XYZ' => badReading(_uo, strict: strict),
      'uo/uoo f1' => lowercaseReading(_oslo, strict: strict),
      _ => reading(notation, _oslo, strict: strict),
    };
  }

  @override
  Future<List<NalbindIssueDto>> validate(NalbindStitchDto dto) async {
    validateCount++;
    return issues;
  }
}

Future<FakeNalbindRepo> pump(WidgetTester tester, [FakeNalbindRepo? repo]) async {
  final fake = repo ?? FakeNalbindRepo();
  final c = ProviderContainer(
    overrides: [nalbindRepositoryProvider.overrideWithValue(fake)],
  );
  addTearDown(c.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: const MaterialApp(home: Scaffold(body: NalbindReferenceScreen())),
    ),
  );
  await tester.pumpAndSettle();
  return fake;
}

Future<void> typeNotation(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders the builtin dictionary with notation + a diagram', (tester) async {
    await pump(tester);
    expect(find.text('Oslo'), findsOneWidget);
    expect(find.text('UO/UOO F1'), findsWidgets); // the card code (and matches the hint elsewhere)
    expect(find.text('1+1'), findsOneWidget, reason: 'the thumb-loop alias chip');
    expect(find.textContaining('a.k.a. Finnish 1+1'), findsOneWidget);
    expect(find.byType(NalbindDiagramView), findsOneWidget, reason: 'the builtin card diagram');
  });

  testWidgets('every diagram is captioned as a schematic, builtin cards included', (tester) async {
    await pump(tester);
    expect(find.text(_caption), findsOneWidget, reason: 'the builtin card');
    await typeNotation(tester, 'UO/UOO F1');
    expect(find.byType(NalbindDiagramView), findsNWidgets(2));
    expect(find.text(_caption), findsNWidgets(2), reason: 'the card and the playground');
  });

  testWidgets('the playground reads in lenient mode; an exact reading is drawn as is',
      (tester) async {
    final repo = await pump(tester);
    await typeNotation(tester, 'UO/UOO F1');
    expect(repo.modes, [false], reason: 'the playground is a reference reading, not authoring');
    expect(find.byType(NalbindDiagramView), findsNWidgets(2));
    expect(find.text(_approximate), findsNothing);
    expect(find.textContaining('Error'), findsNothing);
    expect(find.textContaining('Warning'), findsNothing);
    expect(repo.validateCount, 1, reason: 'an exact reading is validated');
  });

  testWidgets('a bad string lists its findings, errors first, and its diagram is approximate',
      (tester) async {
    final repo = await pump(tester);
    await typeNotation(tester, 'UO/XYZ');

    final error = find.text(shownFinding(
        'Error', 'XYZ', 'unexpected characters `XYZ`; kept verbatim as an opaque token'));
    final warning = find.text(
        shownFinding('Warning', '/', 'turn `/` comes after the last needle step; dropped'));
    expect(error, findsOneWidget, reason: 'severity, quoted text, and message');
    expect(warning, findsOneWidget, reason: 'lenient keeps the warning a warning');
    expect(tester.getTopLeft(error).dy, lessThan(tester.getTopLeft(warning).dy),
        reason: 'errors come first, though the warning is first in the text');

    // The best effort is still drawn, but never as exact.
    expect(find.byType(NalbindDiagramView), findsNWidgets(2));
    expect(find.text(_approximate), findsOneWidget);
    final playground = tester.widgetList<NalbindDiagramView>(find.byType(NalbindDiagramView));
    expect(playground.where((v) => v.approximate), hasLength(1),
        reason: 'only the playground diagram; the builtin card is exact');
    expect(repo.validateCount, 0, reason: 'an approximate reading is not validated');
    expect(find.textContaining('invalid Hansen notation'), findsNothing,
        reason: 'no longer a bare parse error');
  });

  testWidgets('formatting notes stay collapsed behind one quiet line', (tester) async {
    await pump(tester);
    await typeNotation(tester, 'uo/uoo f1');
    expect(find.text('Reads as UO/UOO F1 (3 formatting notes)'), findsOneWidget);
    final note = find.text(shownFinding('Note', 'uoo', 'lowercase `uoo` is read as uppercase'));
    expect(note, findsNothing, reason: 'collapsed');
    expect(find.text(_approximate), findsNothing, reason: 'a normalized reading is exact');

    await tester.tap(find.text('Reads as UO/UOO F1 (3 formatting notes)'));
    await tester.pumpAndSettle();
    expect(note, findsOneWidget);
    expect(find.textContaining('Note at '), findsNWidgets(3));

    await tester.tap(find.text('Reads as UO/UOO F1 (3 formatting notes)'));
    await tester.pumpAndSettle();
    expect(note, findsNothing, reason: 'collapses again');
  });

  testWidgets("an exact reading lists the stitch's validation issues", (tester) async {
    final repo = FakeNalbindRepo()
      ..issues = const [
        NalbindIssueDto(
            code: 'test', severity: SeverityKind.warning, message: 'connection 1 engages 0 loops'),
      ];
    await pump(tester, repo);
    await typeNotation(tester, 'UO/UOO F0');
    expect(find.text('Warning: connection 1 engages 0 loops'), findsOneWidget);
    expect(find.text(_approximate), findsNothing);
  });

  testWidgets('clearing the field clears the findings and the diagram', (tester) async {
    await pump(tester);
    await typeNotation(tester, 'UO/XYZ');
    expect(find.text(_approximate), findsOneWidget);
    await typeNotation(tester, '   ');
    expect(find.text(_approximate), findsNothing);
    expect(find.textContaining('Error at'), findsNothing);
    expect(find.byType(NalbindDiagramView), findsOneWidget, reason: 'only the builtin card');
  });

  testWidgets('a bridge failure says the notation could not be read', (tester) async {
    final repo = FakeNalbindRepo()..analyzeError = true;
    await pump(tester, repo);
    await typeNotation(tester, 'UO/UOO F1');
    expect(find.textContaining('Could not read the notation'), findsOneWidget);
    expect(find.byType(NalbindDiagramView), findsOneWidget, reason: 'only the builtin card');
  });
}
