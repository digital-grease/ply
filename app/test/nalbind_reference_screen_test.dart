import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/nalbind_repository.dart';
import 'package:ply/src/rust/nalbind_dto.dart';
import 'package:ply/src/screens/nalbind_reference_screen.dart';
import 'package:ply/src/state/nalbind_providers.dart';
import 'package:ply/src/widgets/nalbind_diagram_view.dart';

// Host coverage for the Nalbinding reference tab: the builtin dictionary renders (name + notation +
// diagram), the notation playground parses a string into a live diagram, and a bad string surfaces
// the parse error. A fake repo returns fixed DTOs (no FFI).

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

class FakeNalbindRepo extends NalbindRepository {
  @override
  Future<List<NalbindStitchDto>> builtins() async => [_oslo];

  @override
  Future<DiagramDto> diagram(NalbindStitchDto dto) async => _diagram;

  @override
  Future<NalbindStitchDto> parse(String notation) async {
    if (notation.contains('X')) throw Exception('invalid Hansen notation: unexpected "X"');
    return _oslo;
  }

  @override
  Future<List<NalbindIssueDto>> validate(NalbindStitchDto dto) async => const [];
}

Future<void> pump(WidgetTester tester) async {
  final c = ProviderContainer(
    overrides: [nalbindRepositoryProvider.overrideWithValue(FakeNalbindRepo())],
  );
  addTearDown(c.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: const MaterialApp(home: Scaffold(body: NalbindReferenceScreen())),
    ),
  );
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

  testWidgets('the playground parses a notation string into a live diagram', (tester) async {
    await pump(tester);
    await tester.enterText(find.byType(TextField), 'UO/UOO F1');
    await tester.pumpAndSettle();
    // Now two diagrams: the builtin card + the playground.
    expect(find.byType(NalbindDiagramView), findsNWidgets(2));
  });

  testWidgets('a bad notation string surfaces the parse error', (tester) async {
    await pump(tester);
    await tester.enterText(find.byType(TextField), 'UO/X');
    await tester.pumpAndSettle();
    expect(find.textContaining('invalid Hansen notation'), findsOneWidget);
    expect(find.byType(NalbindDiagramView), findsOneWidget, reason: 'only the builtin card diagram');
  });
}
