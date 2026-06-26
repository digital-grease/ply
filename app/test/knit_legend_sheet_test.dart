import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/widgets/knit_legend_sheet.dart';

void main() {
  testWidgets('the stitch key shows abbreviations with their meanings', (t) async {
    t.view.physicalSize = const Size(800, 1600);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(const MaterialApp(home: Scaffold(body: KnitLegendSheet())));
    expect(find.text('Stitch key'), findsOneWidget);
    expect(find.text('k2tog'), findsOneWidget);
    expect(find.textContaining('Knit two together'), findsOneWidget);
    expect(find.text('yo'), findsOneWidget);
    expect(find.text('ssk'), findsOneWidget);
    expect(find.text('p2tog'), findsOneWidget, reason: 'the purl-decrease brush is in the key');
    expect(find.text('k3tog'), findsOneWidget, reason: 'an appended shaping stitch is in the key');
    expect(find.text('m1lp'), findsOneWidget, reason: 'a purlwise increase brush is in the key');
  });
}
