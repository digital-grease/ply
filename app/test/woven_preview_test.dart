import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/state/editor_providers.dart';
import 'package:ply/src/widgets/woven_preview.dart';

// Host coverage for the woven fabric preview: it renders the tiled cloth (with its label) when the
// drawdown bitmap exists, and renders nothing on an empty draft (no bitmap). A fake PreviewController
// supplies/withholds the image so no FFI render is needed.

class _FakePreview extends PreviewController {
  _FakePreview(this.image);
  final ui.Image? image;

  @override
  Future<ui.Image> build() async {
    final img = image;
    if (img == null) throw StateError('empty draft: no cloth bitmap');
    return img;
  }
}

Future<ui.Image> _solidImage() {
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    Uint8List.fromList(List<int>.filled(4 * 4 * 4, 200)),
    4,
    4,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  return completer.future;
}

Future<void> _pump(WidgetTester tester, ui.Image? image) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [previewProvider.overrideWith(() => _FakePreview(image))],
      child: const MaterialApp(
        home: Scaffold(body: SizedBox(width: 300, height: 220, child: WovenPreview())),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('tiles the cloth and labels it when a drawdown exists', (tester) async {
    // decodeImageFromPixels resolves on the engine, so build the image in runAsync (real async),
    // not the test's fake-async zone where its callback would never fire.
    final image = await tester.runAsync(_solidImage);
    await _pump(tester, image);
    expect(find.text('Woven preview'), findsOneWidget);
    expect(find.byType(CustomPaint), findsWidgets, reason: 'the tiled-cloth painter');
  });

  testWidgets('renders nothing on an empty draft (no bitmap)', (tester) async {
    await _pump(tester, null);
    expect(find.text('Woven preview'), findsNothing);
    expect(find.byType(WovenPreview), findsOneWidget);
  });
}
