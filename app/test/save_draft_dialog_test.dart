import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/widgets/save_draft_dialog.dart';

// The shared save-metadata dialog (extracted from preview_screen so the editor can reuse it).

Future<({SaveDraftInput? Function() result})> openDialog(WidgetTester t, String initial) async {
  SaveDraftInput? out;
  await t.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: ElevatedButton(
              onPressed: () async => out = await showSaveDraftDialog(ctx, initialName: initial),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await t.tap(find.text('open'));
  await t.pumpAndSettle();
  return (result: () => out);
}

void main() {
  testWidgets('returns the entered name/author/notes on Save', (t) async {
    final h = await openDialog(t, 'Seed');
    await t.enterText(find.widgetWithText(TextField, 'Name'), 'My draft');
    await t.enterText(find.widgetWithText(TextField, 'Author (optional)'), 'Ada');
    await t.enterText(find.widgetWithText(TextField, 'Notes (optional)'), 'heirloom');
    await t.tap(find.widgetWithText(FilledButton, 'Save'));
    await t.pumpAndSettle();
    final out = h.result()!;
    expect(out.name, 'My draft');
    expect(out.author, 'Ada');
    expect(out.notes, 'heirloom');
  });

  testWidgets('the name is pre-seeded; empty author becomes null', (t) async {
    final h = await openDialog(t, 'Seed');
    await t.tap(find.widgetWithText(FilledButton, 'Save')); // keep the seeded name, no author/notes
    await t.pumpAndSettle();
    final out = h.result()!;
    expect(out.name, 'Seed');
    expect(out.author, isNull, reason: 'a blank author returns null');
    expect(out.notes, '');
  });

  testWidgets('an empty name shows an error and keeps the dialog open', (t) async {
    final h = await openDialog(t, '');
    await t.tap(find.widgetWithText(FilledButton, 'Save'));
    await t.pumpAndSettle();
    expect(find.text('A name is required'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Save'), findsOneWidget, reason: 'still open');
    expect(h.result(), isNull, reason: 'nothing returned yet');
  });

  testWidgets('Cancel returns null', (t) async {
    final h = await openDialog(t, 'Seed');
    await t.tap(find.widgetWithText(TextButton, 'Cancel'));
    await t.pumpAndSettle();
    expect(h.result(), isNull);
  });

  testWidgets('the name-required error clears as soon as you start typing', (t) async {
    final h = await openDialog(t, '');
    await t.tap(find.widgetWithText(FilledButton, 'Save')); // surface the error
    await t.pumpAndSettle();
    expect(find.text('A name is required'), findsOneWidget);

    await t.enterText(find.widgetWithText(TextField, 'Name'), 'x'); // typing resets it
    await t.pumpAndSettle();
    expect(find.text('A name is required'), findsNothing, reason: 'error clears on change');

    await t.tap(find.widgetWithText(FilledButton, 'Save'));
    await t.pumpAndSettle();
    expect(h.result()!.name, 'x', reason: 'now valid -> returns the typed name');
  });
}
