import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
}
