import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/rust/knit_dto.dart';
import 'package:ply/src/widgets/cable_builder_dialog.dart';

// Covers the cable builder: it returns the configured CableDefDto on confirm (default 2/2 RC),
// captures a left-cross selection, returns null on cancel, and the cableSymbol label format.

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
  test('cableSymbol formats front/back + cross direction', () {
    expect(
      cableSymbol(const CableDefDto(
          front: 2, back: 2, direction: CrossKind.right, frontPurl: false, backPurl: false)),
      '2/2 RC',
    );
    expect(
      cableSymbol(const CableDefDto(
          front: 3, back: 1, direction: CrossKind.left, frontPurl: false, backPurl: false)),
      '3/1 LC',
    );
  });

  testWidgets('returns the default 2/2 right-cross cable on Add', (tester) async {
    final ctx = await pumpHost(tester);
    final future = showCableBuilder(ctx);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add cable'));
    await tester.pumpAndSettle();
    final cable = await future;
    expect(cable, isNotNull);
    expect((cable!.front, cable.back), (2, 2));
    expect(cable.direction, CrossKind.right);
  });

  testWidgets('captures a left-cross selection', (tester) async {
    final ctx = await pumpHost(tester);
    final future = showCableBuilder(ctx);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Left cross'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add cable'));
    await tester.pumpAndSettle();
    expect((await future)!.direction, CrossKind.left);
  });

  testWidgets('cancel returns null', (tester) async {
    final ctx = await pumpHost(tester);
    final future = showCableBuilder(ctx);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await future, isNull);
  });
}
