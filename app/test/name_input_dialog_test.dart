import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/models/draft_meta.dart';
import 'package:ply/src/widgets/name_input_dialog.dart';

// Covers the reusable name dialog AND its reason for existing: it owns + disposes its
// TextEditingController in State.dispose, so confirming/cancelling (which runs the route's exit
// animation, rebuilding the TextField once more) never throws "used after being disposed".

/// Pump a host and return a live [BuildContext] the test can open the dialog from. The test owns all
/// pumping after this (so the dialog future stays un-flattened and awaitable at the end).
Future<BuildContext> pumpHost(WidgetTester tester) async {
  late BuildContext ctx;
  await tester.pumpWidget(MaterialApp(
    home: Builder(builder: (c) {
      ctx = c;
      return const Scaffold(body: SizedBox());
    }),
  ));
  return ctx;
}

void main() {
  testWidgets('confirm returns the trimmed name (and settles the exit animation cleanly)',
      (tester) async {
    final ctx = await pumpHost(tester);
    final future = promptForName(ctx, title: 'Name it', confirmLabel: 'Save', initial: 'Hat');
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '  Beanie  ');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle(); // runs the exit transition; a disposed controller would throw here
    expect(await future, 'Beanie');
  });

  testWidgets('cancel returns null', (tester) async {
    final ctx = await pumpHost(tester);
    final future = promptForName(ctx, title: 'Name it', confirmLabel: 'Save', initial: 'Hat');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(await future, isNull);
  });

  testWidgets('an all-whitespace name returns null (never persists a blank title)', (tester) async {
    final ctx = await pumpHost(tester);
    final future = promptForName(ctx, title: 'Name it', confirmLabel: 'Save', initial: 'x');
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '   ');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(await future, isNull);
  });

  testWidgets('with the project name limit: a longer name, saved before it, must be shortened',
      (tester) async {
    final ctx = await pumpHost(tester);
    final old = 'Old name ' * 30; // 270 characters, 269 as saved (trimmed)
    final future = promptForName(ctx,
        title: 'Rename pattern',
        confirmLabel: 'Rename',
        initial: old,
        validator: projectNameProblem);
    await tester.pumpAndSettle();
    const said = 'Names can be at most 200 characters (this one has 269).';
    expect(find.text(said), findsOneWidget, reason: 'said as soon as it opens');
    await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
    await tester.pumpAndSettle();
    expect(find.text(said), findsOneWidget, reason: 'still open');
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, old,
        reason: 'nothing is cut short');

    await tester.enterText(find.byType(TextField), 'x' * 200);
    await tester.pumpAndSettle();
    expect(find.textContaining('can be at most'), findsNothing);
    await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
    await tester.pumpAndSettle();
    expect(await future, 'x' * 200);
  });

  test('the limits count the text as it is saved, and name the count', () {
    expect(projectNameProblem('x' * DraftMeta.maxNameChars), isNull);
    expect(projectNameProblem('x' * 1234),
        'Names can be at most 200 characters (this one has 1,234).');
    expect(authorProblem('a' * DraftMeta.maxAuthorChars), isNull);
    expect(authorProblem('a' * 201), 'The author can be at most 200 characters (this has 201).');
  });
}
