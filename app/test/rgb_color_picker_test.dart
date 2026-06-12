import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/models/draft_doc.dart';
import 'package:ply/src/widgets/rgb_color_picker.dart';

// The RGB picker is RGB-ONLY by construction: exactly three sliders, no alpha/opacity, integer
// channels, value-in/value-out. No Riverpod, no FFI.

/// Pump a host that opens the picker (fire-and-forget) seeded with [initial], leaving the dialog up.
Future<void> openPicker(WidgetTester tester, DraftColor initial) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () => showRgbColorPicker(context, initial: initial),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows exactly three sliders and NO alpha/opacity affordance', (tester) async {
    await openPicker(tester, const DraftColor(r: 10, g: 20, b: 30));
    expect(find.byType(Slider), findsNWidgets(3), reason: 'R, G, B only — no fourth alpha slider');
    expect(find.textContaining('Alpha'), findsNothing);
    expect(find.textContaining('Opacity'), findsNothing);
    // The read-only hex readout reflects the initial color.
    expect(find.text('#0A141E'), findsOneWidget);
  });

  testWidgets('Use color returns the chosen DraftColor; Cancel returns null', (tester) async {
    DraftColor? out;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () async =>
                    out = await showRgbColorPicker(context, initial: const DraftColor(r: 5, g: 5, b: 5)),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    // Use color returns the (unchanged) initial value.
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use color'));
    await tester.pumpAndSettle();
    expect(out, const DraftColor(r: 5, g: 5, b: 5));

    // Cancel returns null.
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(out, isNull);
  });

  testWidgets('dragging a channel slider updates the live hex readout', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () =>
                    showRgbColorPicker(context, initial: const DraftColor(r: 0, g: 0, b: 0)),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('#000000'), findsOneWidget);

    // Three per-channel numeric readouts, all '0' initially.
    expect(find.text('0'), findsNWidgets(3));

    // Drag the first (R) slider to the right; the hex readout AND the R numeric must change.
    await tester.drag(find.byType(Slider).first, const Offset(200, 0));
    await tester.pumpAndSettle();
    expect(find.text('#000000'), findsNothing, reason: 'moving R changed the color');
    expect(find.text('0'), findsNWidgets(2), reason: 'only R left 0; G and B stay 0');
  });

  testWidgets('a barrier tap dismisses the picker as null (cancel)', (tester) async {
    DraftColor? out = const DraftColor(r: 9, g: 9, b: 9); // non-null sentinel
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () async =>
                    out = await showRgbColorPicker(context, initial: const DraftColor(r: 1, g: 2, b: 3)),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(10, 10)); // tap the scrim, outside the centered dialog
    await tester.pumpAndSettle();
    expect(out, isNull, reason: 'a barrier dismissal is a cancel');
  });

  testWidgets('the dialog title reflects the flow (Add vs Edit)', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () => showRgbColorPicker(context,
                    initial: const DraftColor(r: 0, g: 0, b: 0), title: 'Add color'),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Add color'), findsOneWidget);
    expect(find.text('Edit color'), findsNothing);
  });
}
