import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/draft_repository.dart';
import 'package:ply/src/screens/preview_screen.dart';
import 'package:ply/src/widgets/drawdown_view.dart';

// The library preview draws the pattern as saved, INCLUDING its per-thread yarn thickness, so it
// must say plainly that the picture is an approximate look, not a fabric model (M7-09). The render
// is faked (no FFI): the repository hands back a pre-decoded image.

class _FakeRepo extends DraftRepository {
  _FakeRepo(this.image);
  final ui.Image image;
  String? renderedText;

  @override
  Future<ui.Image> renderDrawdown(String wifText, {required int cellPx}) {
    renderedText = wifText;
    return Future<ui.Image>.value(image.clone());
  }
}

Future<ui.Image> _image() {
  final c = Completer<ui.Image>();
  ui.decodeImageFromPixels(
      Uint8List.fromList(List<int>.filled(3 * 2 * 4, 180)), 3, 2, ui.PixelFormat.rgba8888, c.complete);
  return c.future;
}

void main() {
  testWidgets('the library preview captions its thickness-aware drawdown as an approximate look',
      (tester) async {
    final image = await tester.runAsync(_image);
    final repo = _FakeRepo(image!);
    await tester.pumpWidget(MaterialApp(
      home: PreviewScreen.unsaved(repository: repo, wifText: 'WIF', suggestedName: 'Runner'),
    ));
    await tester.pump();
    await tester.pump();

    expect(repo.renderedText, 'WIF', reason: 'the saved pattern text is what gets drawn');
    expect(find.byType(DrawdownView), findsOneWidget);
    expect(
        find.text("Yarn preview: thread widths follow the pattern's yarn sizes. "
            'Approximate look, not a fabric model.'),
        findsOneWidget);
  });
}
