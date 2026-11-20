import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/models/draft_meta.dart';
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

  testWidgets('notes past the limit are refused with how long they are, never cut short',
      (t) async {
    final h = await openDialog(t, 'Seed');
    final long = 'n' * (DraftMeta.maxNotesChars + 1);
    await t.enterText(find.widgetWithText(TextField, 'Notes (optional)'), long);
    await t.tap(find.widgetWithText(FilledButton, 'Save'));
    await t.pumpAndSettle();
    expect(find.text('Notes can be at most 10,000 characters (these have 10,001).'), findsOneWidget);
    expect(h.result(), isNull, reason: 'still open, nothing returned');
    final field = t.widget<TextField>(find.byType(TextField).last);
    expect(field.controller!.text, long, reason: 'the notes are left as typed');

    // Back within the limit, the error clears and Save returns them.
    await t.enterText(find.byType(TextField).last, 'n' * DraftMeta.maxNotesChars);
    await t.pumpAndSettle();
    expect(find.textContaining('Notes can be at most'), findsNothing);
    await t.tap(find.widgetWithText(FilledButton, 'Save'));
    await t.pumpAndSettle();
    expect(h.result()!.notes, 'n' * DraftMeta.maxNotesChars);
  });

  testWidgets('a name or author past the limit is refused with how long it is, never cut short',
      (t) async {
    final h = await openDialog(t, 'Seed');
    final longName = 'N' * (DraftMeta.maxNameChars + 1);
    final longAuthor = 'A' * 1234;
    await t.enterText(find.widgetWithText(TextField, 'Name'), longName);
    await t.enterText(find.widgetWithText(TextField, 'Author (optional)'), longAuthor);
    await t.tap(find.widgetWithText(FilledButton, 'Save'));
    await t.pumpAndSettle();
    expect(find.text('Names can be at most 200 characters (this one has 201).'), findsOneWidget);
    expect(find.text('The author can be at most 200 characters (this has 1,234).'), findsOneWidget);
    expect(h.result(), isNull, reason: 'still open, nothing returned');
    final fields = t.widgetList<TextField>(find.byType(TextField)).toList();
    expect(fields[0].controller!.text, longName, reason: 'the name is left as typed');
    expect(fields[1].controller!.text, longAuthor, reason: 'the author is left as typed');

    // The count follows the typing, and the message goes once the text is within the limit.
    await t.enterText(find.byType(TextField).first, 'N' * 250);
    await t.pumpAndSettle();
    expect(find.text('Names can be at most 200 characters (this one has 250).'), findsOneWidget);
    await t.enterText(find.byType(TextField).first, '  ${'N' * DraftMeta.maxNameChars}  ');
    await t.enterText(find.byType(TextField).at(1), 'A' * DraftMeta.maxAuthorChars);
    await t.pumpAndSettle();
    expect(find.textContaining('can be at most'), findsNothing,
        reason: 'counted as saved, without the spaces at either end');
    await t.tap(find.widgetWithText(FilledButton, 'Save'));
    await t.pumpAndSettle();
    expect(h.result()!.name, 'N' * DraftMeta.maxNameChars);
    expect(h.result()!.author, 'A' * DraftMeta.maxAuthorChars);
  });
}
