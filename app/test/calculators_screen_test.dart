import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/screens/calculators_screen.dart';

// The Calculators tab wires the pure maths (knit_calculators_test covers those) to live UI: results
// recompute as inputs change, with no open pattern required.

// A tall viewport so every card is built by the lazy ListView (the default 600px hides the last ones).
Future<void> _pump(WidgetTester t) async {
  t.view.physicalSize = const Size(1000, 2600);
  t.view.devicePixelRatio = 1.0;
  addTearDown(() {
    t.view.resetPhysicalSize();
    t.view.resetDevicePixelRatio();
  });
  // A ProviderScope for the global unit preference (defaults to imperial).
  await t.pumpWidget(const ProviderScope(child: MaterialApp(home: CalculatorsScreen())));
}

void main() {
  testWidgets('computes and shows every calculator result from the defaults', (t) async {
    await _pump(t);
    expect(find.text('Cast on 110 stitches'), findsOneWidget); // (20+2) in x 5 sts/in
    expect(find.text('Work 109 stitches'), findsOneWidget); // 120 x 20/22 resize
    expect(find.text('Work increase every 10 sts, 6 times.'), findsOneWidget);
    expect(find.text('~440 yards'), findsOneWidget);
  });

  testWidgets('toggling Decrease updates the spread wording', (t) async {
    await _pump(t);
    await t.tap(find.text('Decrease'));
    await t.pump();
    expect(find.text('Work decrease every 10 sts, 6 times.'), findsOneWidget);
  });

  testWidgets('the in/cm toggle drives the unit labels (global preference)', (t) async {
    await _pump(t);
    expect(find.text('Width (in)'), findsWidgets);
    await t.tap(find.text('cm'));
    await t.pump();
    expect(find.text('Width (cm)'), findsWidgets);
    expect(find.text('Width (in)'), findsNothing);
  });
}
