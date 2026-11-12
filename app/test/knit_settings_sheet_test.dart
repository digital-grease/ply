import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/rust/knit_dto.dart';
import 'package:ply/src/state/knit_editor_providers.dart';
import 'package:ply/src/widgets/knit_settings_sheet.dart';

// Host coverage for the pattern-settings sheet: construction toggles write straight to the pattern,
// notes and the typed cast-on commit ONCE when their field loses focus (not per keystroke), Clear
// unsets the cast-on, and an unusable count is shown as an error instead of being committed. Pure
// state, no FFI.

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

    await tester.enterText(find.byKey(const Key('knit-notes-field')), 'worsted, US7');
    // Mid-edit (still focused) the notes are NOT yet committed -> typing isn't one undo per key.
    expect(c.read(knitEditorProvider).pattern.notes, '');

    // Dismiss the sheet by tapping the scrim -> the field loses focus -> notes commit exactly once.
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(c.read(knitEditorProvider).pattern.notes, 'worsted, US7');
    expect(c.read(knitEditorProvider).canUndo, isTrue, reason: 'the notes edit is one undo entry');
  });

  group('cast-on', () {
    final field = find.byKey(const Key('knit-cast-on-field'));
    final clear = find.byKey(const Key('knit-cast-on-clear'));

    testWidgets('starts blank (not set) with Clear disabled', (tester) async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      await pumpSheet(tester, c);
      expect(c.read(knitEditorProvider).pattern.castOn, isNull);
      expect(find.text('Not set'), findsOneWidget, reason: 'the hint of the empty field');
      expect(tester.widget<TextButton>(clear).onPressed, isNull);
      expect(find.textContaining('Stitches on the needle before row 1.'), findsOneWidget);
    });

    testWidgets('a typed count commits once, on submit, then Clear unsets it', (tester) async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      await pumpSheet(tester, c);

      await tester.enterText(field, '26');
      await tester.pump();
      expect(c.read(knitEditorProvider).pattern.castOn, isNull, reason: 'not per keystroke');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(c.read(knitEditorProvider).pattern.castOn, 26);
      expect(c.read(knitEditorProvider).undo, hasLength(1), reason: 'one undo entry');

      await tester.ensureVisible(clear);
      await tester.tap(clear);
      await tester.pumpAndSettle();
      expect(c.read(knitEditorProvider).pattern.castOn, isNull);
      expect(tester.widget<TextField>(field).controller!.text, isEmpty);
      expect(c.read(knitEditorProvider).undo, hasLength(2));
    });

    testWidgets('a typed count commits when the sheet closes', (tester) async {
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
      showModalBottomSheet<void>(context: ctx, builder: (_) => const KnitSettingsSheet());
      await tester.pumpAndSettle();
      await tester.enterText(field, '96');
      await tester.tapAt(const Offset(10, 10)); // the scrim: the field loses focus
      await tester.pumpAndSettle();
      expect(c.read(knitEditorProvider).pattern.castOn, 96);
    });

    testWidgets('shows the saved count, and the in-the-round wording', (tester) async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(knitEditorProvider.notifier)
        ..setConstruction(ConstructionKind.inTheRound)
        ..setCastOn(96);
      await pumpSheet(tester, c);
      expect(tester.widget<TextField>(field).controller!.text, '96');
      expect(tester.widget<TextButton>(clear).onPressed, isNotNull);
      expect(find.textContaining('Stitches cast on and joined before round 1.'), findsOneWidget);
    });

    testWidgets('zero is an error and is not committed; clearing the text unsets', (tester) async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(knitEditorProvider.notifier).setCastOn(26);
      await pumpSheet(tester, c);

      await tester.enterText(field, '0');
      await tester.pump();
      expect(find.text('Enter at least 1 stitch, or clear it.'), findsOneWidget);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(c.read(knitEditorProvider).pattern.castOn, 26, reason: 'the bad count is not saved');

      await tester.enterText(field, '');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(c.read(knitEditorProvider).pattern.castOn, isNull, reason: 'blank = not set');
    });
  });
}
