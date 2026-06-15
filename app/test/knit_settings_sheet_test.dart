import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/rust/knit_dto.dart';
import 'package:ply/src/state/knit_editor_providers.dart';
import 'package:ply/src/widgets/knit_settings_sheet.dart';

// Host coverage for the pattern-settings sheet: construction toggles write straight to the pattern,
// and notes commit ONCE when the sheet closes (not per keystroke). Pure state, no FFI.

Future<void> pumpSheet(WidgetTester tester, ProviderContainer c) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: const MaterialApp(home: Scaffold(body: KnitSettingsSheet())),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('toggling construction writes to the pattern and updates the hint', (tester) async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    await pumpSheet(tester, c);

    expect(c.read(knitEditorProvider).pattern.construction, ConstructionKind.flat);
    await tester.tap(find.text('In the round'));
    await tester.pumpAndSettle();
    expect(c.read(knitEditorProvider).pattern.construction, ConstructionKind.inTheRound);
    expect(find.textContaining('every row is a right-side round'), findsOneWidget);
    expect(find.textContaining('Not used in the round'), findsOneWidget);
  });

  testWidgets('notes commit once, on focus loss (not per keystroke)', (tester) async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    late BuildContext ctx;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(builder: (x) {
              ctx = x;
              return const SizedBox.expand();
            }),
          ),
        ),
      ),
    );
    // Open the settings as a real modal bottom sheet so dismissing it releases focus naturally.
    showModalBottomSheet<void>(context: ctx, builder: (_) => const KnitSettingsSheet());
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'worsted, US7');
    // Mid-edit (still focused) the notes are NOT yet committed -> typing isn't one undo per key.
    expect(c.read(knitEditorProvider).pattern.notes, '');

    // Dismiss the sheet by tapping the scrim -> the field loses focus -> notes commit exactly once.
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(c.read(knitEditorProvider).pattern.notes, 'worsted, US7');
    expect(c.read(knitEditorProvider).canUndo, isTrue, reason: 'the notes edit is one undo entry');
  });
}
