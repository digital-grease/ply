// GlossaryScreen behavior: it lists terms, filters on search (including definition-body matches),
// and reveals a definition on tap. Pure widget test (no FFI / repository).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/glossary_data.g.dart';
import 'package:ply/src/screens/glossary_screen.dart';

void main() {
  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: GlossaryScreen()));
    await tester.pumpAndSettle();
  }

  testWidgets('lists every term headword on first open', (tester) async {
    await pumpScreen(tester);
    // A representative spread of headwords is present (the list scrolls, but these top ones render).
    expect(find.text('Warp'), findsOneWidget);
    expect(find.text('Weft'), findsOneWidget);
    expect(find.text('End'), findsOneWidget);
  });

  testWidgets('search filters by headword', (tester) async {
    await pumpScreen(tester);
    await tester.enterText(find.byType(TextField), 'twill');
    await tester.pumpAndSettle();
    expect(find.text('Twill'), findsOneWidget);
    expect(find.text('Warp'), findsNothing, reason: 'non-matching terms are filtered out');
  });

  testWidgets('search matches definition bodies, not just headwords', (tester) async {
    await pumpScreen(tester);
    await tester.enterText(find.byType(TextField), 'EPI');
    await tester.pumpAndSettle();
    // "EPI" appears in Sett's definition, not its headword.
    expect(find.text('Sett'), findsOneWidget);
  });

  testWidgets('a no-match query shows the empty state', (tester) async {
    await pumpScreen(tester);
    await tester.enterText(find.byType(TextField), 'zzzznotaterm');
    await tester.pumpAndSettle();
    expect(find.textContaining('No terms match'), findsOneWidget);
  });

  testWidgets('tapping a term reveals its definition', (tester) async {
    await pumpScreen(tester);
    // Filter via a word unique to Warp's DEFINITION ("tension"), so the query text in the search
    // field can't collide with the "Warp" headword we tap.
    await tester.enterText(find.byType(TextField), 'tension');
    await tester.pumpAndSettle();
    final def = kGlossary.firstWhere((t) => t.term == 'Warp').definition;
    expect(find.text('Warp'), findsOneWidget, reason: 'only Warp matches "tension"');
    expect(find.text(def), findsNothing, reason: 'collapsed by default');
    await tester.tap(find.text('Warp'));
    await tester.pumpAndSettle();
    expect(find.text(def), findsOneWidget, reason: 'tap expands to the definition');
  });
}
