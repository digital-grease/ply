import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/state/editor_providers.dart';
import 'package:ply/src/widgets/woven_preview.dart';

// Host coverage for the yarn preview under the editor: it renders the tiled cloth (with its
// appearance-approximation label) from ITS OWN render ([wovenPreviewProvider]), independent of the
// editor's structural drawdown ([previewProvider]), and renders nothing on an empty draft (no
// bitmap). Fake controllers supply/withhold the images so no FFI render is needed.

class _FakeWoven extends WovenPreviewController {
  _FakeWoven(this.image);
  final ui.Image? image;

  @override
  Future<ui.Image> build() async {
    final img = image;
    if (img == null) throw StateError('empty draft: no cloth bitmap');
    return img;
  }
}

/// A structural editor drawdown that never resolves: the yarn preview must not depend on it.
class _NeverPreview extends PreviewController {
  @override
  Future<ui.Image> build() => Completer<ui.Image>().future;
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
      overrides: [
        wovenPreviewProvider.overrideWith(() => _FakeWoven(image)),
        previewProvider.overrideWith(_NeverPreview.new),
      ],
      child: const MaterialApp(
        home: Scaffold(body: SizedBox(width: 300, height: 220, child: WovenPreview())),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('tiles its OWN yarn render and labels it an approximate look, not a fabric model',
      (tester) async {
    // decodeImageFromPixels resolves on the engine, so build the image in runAsync (real async),
    // not the test's fake-async zone where its callback would never fire.
    final image = await tester.runAsync(_solidImage);
    await _pump(tester, image); // the structural previewProvider never resolves here
    expect(find.textContaining('Yarn preview, tiled'), findsOneWidget);
    expect(find.textContaining('Approximate look, not a fabric model.'), findsOneWidget);
    expect(find.byType(CustomPaint), findsWidgets, reason: 'the tiled-cloth painter');
  });

  testWidgets('the semantics label carries the approximation wording', (tester) async {
    final handle = tester.ensureSemantics();
    final image = await tester.runAsync(_solidImage);
    await _pump(tester, image);
    expect(
        find.bySemanticsLabel('Yarn preview, tiled. Approximate look, not a fabric model.'),
        findsOneWidget);
    handle.dispose();
  });

  testWidgets('renders nothing on an empty draft (no bitmap)', (tester) async {
    await _pump(tester, null);
    expect(find.textContaining('Yarn preview'), findsNothing);
    expect(find.byType(WovenPreview), findsOneWidget);
  });
}
