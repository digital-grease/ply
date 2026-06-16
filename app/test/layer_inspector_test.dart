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

/// Captures the draft handed to the renderer so a test can assert WHICH cloth (combined vs a layer)
/// the inspector asked to render.
class CapturingRepo extends DraftRepository {
  DraftDoc? lastRendered;

  @override
  Future<ui.Image> renderDto(
    DraftDoc doc, {
    required int cellPx,
    bool gridlines = false,
    int floatThreshold = 0,
  }) {
    lastRendered = doc;
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

/// Bounded pump (NOT pumpAndSettle: the inspector shows a CircularProgressIndicator while a render is
/// in flight, an infinite animation pumpAndSettle would wait on forever) to let the stub render decode.
Future<void> settle(WidgetTester t) async {
  await t.pump();
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(milliseconds: 20));
  }
}

Future<CapturingRepo> pump(WidgetTester tester) async {
  final repo = CapturingRepo();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [repositoryProvider.overrideWithValue(repo)],
      child: MaterialApp(home: LayerInspectorScreen(draft: doubleWeave())),
    ),
  );
  await settle(tester);
  return repo;
}

void main() {
  testWidgets('opens on the Combined cloth (the whole draft)', (tester) async {
    final repo = await pump(tester);
    expect(find.byWidgetPredicate((w) => w is SegmentedButton), findsOneWidget);
    expect(find.text('Combined'), findsOneWidget);
    expect(find.text('Front'), findsOneWidget);
    expect(find.text('Back'), findsOneWidget);
    expect(repo.lastRendered!.ends, 4, reason: 'combined renders the whole 4-end cloth');
  });

  testWidgets('Front renders only the front layer (half the ends/picks)', (tester) async {
    final repo = await pump(tester);
    await tester.tap(find.text('Front'));
    await settle(tester);
    expect(repo.lastRendered!.ends, 2, reason: 'front = ends on shafts 1 and 3');
    expect(repo.lastRendered!.picks, 2);
  });

  testWidgets('Back renders only the back layer', (tester) async {
    final repo = await pump(tester);
    await tester.tap(find.text('Back'));
    await settle(tester);
    expect(repo.lastRendered!.ends, 2, reason: 'back = ends on shafts 2 and 4');
    expect(repo.lastRendered!.picks, 2);
  });

  testWidgets('a layer with no threads shows a message instead of a 0x0 cloth', (tester) async {
    // A single-pick draft: pick 0 is a FRONT pick, so the BACK layer has no picks at all.
    final oneRow = DraftDoc.blank(shafts: 4, treadles: 4).copyWith(
      threading: const [
        [1],
        [2],
        [3],
        [4],
      ],
      drive: DraftTreadled(tieup: const [
        [1, 2, 4],
        [2],
        [2, 3, 4],
        [4],
      ], treadling: const [
        [1],
      ]),
      warpColors: const [0, 1, 0, 1],
      weftColors: const [0],
    );
    await tester.pumpWidget(ProviderScope(
      overrides: [repositoryProvider.overrideWithValue(CapturingRepo())],
      child: MaterialApp(home: LayerInspectorScreen(draft: oneRow)),
    ));
    await settle(tester);
    await tester.tap(find.text('Back'));
    await settle(tester);
    expect(find.text('This layer has no threads.'), findsOneWidget);
    expect(tester.takeException(), isNull, reason: 'no NaN AspectRatio from a 0x0 image');
  });
}
