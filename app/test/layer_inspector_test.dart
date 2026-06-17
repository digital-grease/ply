import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/draft_repository.dart';
import 'package:ply/src/models/draft_doc.dart';
import 'package:ply/src/screens/layer_inspector_screen.dart';
import 'package:ply/src/state/editor_providers.dart';

/// Records every draft handed to the renderer so a test can assert which layer cloths were drawn.
class CapturingRepo extends DraftRepository {
  final List<DraftDoc> rendered = [];

  @override
  Future<ui.Image> renderDto(
    DraftDoc doc, {
    required int cellPx,
    bool gridlines = false,
    int floatThreshold = 0,
  }) {
    rendered.add(doc);
    final c = Completer<ui.Image>();
    ui.decodeImageFromPixels(
        Uint8List.fromList(const [0, 0, 0, 255]), 1, 1, ui.PixelFormat.rgba8888, c.complete);
    return c.future;
  }
}

DraftDoc doubleWeave() => DraftDoc.blank(shafts: 4, treadles: 4).copyWith(
      threading: const [
        [1],
        [2],
        [3],
        [4],
      ],
      drive: DraftTreadled(
        tieup: const [
          [1, 2, 4],
          [2],
          [2, 3, 4],
          [4],
        ],
        treadling: const [
          [1],
          [2],
          [3],
          [4],
        ],
      ),
      warpColors: const [0, 1, 0, 1],
      weftColors: const [0, 1, 0, 1],
    );

/// The kept threading of a rendered layer, flattened to a comparable string.
String th(DraftDoc d) => [for (final r in d.threading) ...r].join(',');

/// Bounded pump (NOT pumpAndSettle: the inspector shows a CircularProgressIndicator while rendering).
/// Generous iteration count because a render now does TWO sequential image decodes (top + bottom).
Future<void> settle(WidgetTester t) async {
  await t.pump();
  for (var i = 0; i < 24; i++) {
    await t.pump(const Duration(milliseconds: 20));
  }
}

Future<CapturingRepo> pump(WidgetTester tester) async {
  final repo = CapturingRepo();
  await tester.pumpWidget(ProviderScope(
    overrides: [repositoryProvider.overrideWithValue(repo)],
    child: MaterialApp(home: LayerInspectorScreen(draft: doubleWeave())),
  ));
  await settle(tester);
  return repo;
}

void main() {
  testWidgets('renders BOTH layers at once and a chip per shaft', (tester) async {
    final repo = await pump(tester);
    expect(find.byType(FilterChip), findsNWidgets(4), reason: 'one chip per shaft (1..4)');
    expect(repo.rendered.any((d) => th(d) == '1,3'), isTrue, reason: 'top layer (shafts 1,3) drawn');
    expect(repo.rendered.any((d) => th(d) == '2,4'), isTrue, reason: 'bottom layer (shafts 2,4) drawn');
  });

  testWidgets('toggling a shaft re-splits the layers', (tester) async {
    final repo = await pump(tester);
    repo.rendered.clear();
    await tester.tap(find.widgetWithText(FilterChip, '2')); // move shaft 2 to the top
    await settle(tester);
    expect(repo.rendered.any((d) => th(d) == '1,2,3'), isTrue,
        reason: 'shaft 2 now joins the top warp (ends on shafts 1,2,3)');
  });

  testWidgets('an empty layer shows a message instead of a 0x0 cloth', (tester) async {
    await pump(tester);
    // Move every shaft to the top -> the bottom layer has no shafts, so both layers are empty.
    await tester.tap(find.widgetWithText(FilterChip, '2'));
    await settle(tester);
    await tester.tap(find.widgetWithText(FilterChip, '4'));
    await settle(tester);
    expect(find.text('No threads on this layer.'), findsWidgets);
    expect(tester.takeException(), isNull, reason: 'no NaN AspectRatio from an empty layer');
  });
}
