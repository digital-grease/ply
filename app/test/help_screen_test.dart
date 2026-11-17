import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/screens/help_screen.dart';

// Host coverage for the Help hub: the Glossary entry + the grouped FAQ render, a question expands to
// reveal its answer, and the Glossary entry opens the glossary screen. The FAQ content (kFaq) is a
// const list, so no FFI is needed.

void main() {
  testWidgets('shows the Glossary entry and the grouped FAQ', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: HelpScreen()));
    expect(find.text('Glossary'), findsOneWidget, reason: 'the glossary entry tile');
    expect(find.text('About Ply & privacy'), findsOneWidget, reason: 'an FAQ section header');
    expect(find.text('What is Ply?'), findsOneWidget, reason: 'an FAQ question');
    expect(kFaq, isNotEmpty);
  });

  testWidgets('tapping a question expands its answer', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: HelpScreen()));
    expect(find.textContaining('local-first pattern tool'), findsNothing, reason: 'collapsed first');
    await tester.tap(find.text('What is Ply?'));
    await tester.pumpAndSettle();
    expect(find.textContaining('local-first pattern tool'), findsOneWidget);
  });

  testWidgets('the Glossary entry opens the glossary', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: HelpScreen()));
    await tester.tap(find.text('Glossary'));
    await tester.pumpAndSettle();
    expect(find.text('Warp'), findsWidgets, reason: 'the glossary screen lists weaving terms');
  });

  test('the tablet weaving entry names card weaving and makes no WIF claim', () {
    final section = kFaq.firstWhere((s) => s.title == 'Tablet weaving');
    expect(section.entries, hasLength(1));
    final entry = section.entries.single;
    expect(entry.question, 'How do I draft a tablet weaving band?');
    expect(entry.answer, contains('card weaving'));
    expect(entry.answer, contains('.plytab'));
    expect(entry.answer, contains('pick 1 at the bottom'));
    expect(entry.answer, contains("await a tablet weaver's review"));
    expect(entry.answer, contains('does not read or write WIF'));
  });
}
