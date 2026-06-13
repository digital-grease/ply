// Phase 5.2: the editor's dimension steppers carry glossary-sourced concept tooltips, so the help
// text can never drift from docs/GLOSSARY.md (it is looked up from the same generated source).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/glossary_lookup.dart';
import 'package:ply/src/widgets/dimensions_bar.dart';

void main() {
  testWidgets('Ends/Picks/Shafts/Treadles steppers tooltip their glossary definitions',
      (tester) async {
    // The default editor state is a blank TREADLED draft, so all four steppers render.
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: Scaffold(body: DimensionsBar())),
      ),
    );
    await tester.pumpAndSettle();

    for (final (label, concept) in const [
      ('Ends', 'End'),
      ('Picks', 'Pick'),
      ('Shafts', 'Shaft'),
      ('Treadles', 'Treadle'),
    ]) {
      final def = glossaryDefinition(concept);
      expect(def, isNotNull, reason: '$concept is in the glossary');
      expect(
        find.byTooltip('$concept: $def'),
        findsOneWidget,
        reason: 'the $label stepper carries $concept\'s glossary definition as its tooltip',
      );
    }
  });
}
