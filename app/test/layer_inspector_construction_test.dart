import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/draft_repository.dart';
import 'package:ply/src/models/double_weave_layers.dart';
import 'package:ply/src/models/draft_doc.dart';
import 'package:ply/src/screens/editor_screen.dart' show LayeredDrawdownNote;
import 'package:ply/src/screens/layer_inspector_screen.dart';
import 'package:ply/src/state/draft_editor_notifier.dart';
import 'package:ply/src/state/editor_providers.dart';

// The layer inspector's construction surface (M8-09, ADR 0010): the declared construction and
// whether the edges match, the left/right edge legend, the working order, "Use as" offered only for
// an exact match and applied only after confirmation, removing the label, the "Top face" view only
// when it is provable; and the editor's caption over a multi-layer drawdown.

class _Repo extends DraftRepository {
  @override
  Future<ui.Image> renderDto(
    DraftDoc doc, {
    required int cellPx,
    bool gridlines = false,
    int floatThreshold = 0,
    bool threadTexture = false,
  }) {
    final c = Completer<ui.Image>();
    ui.decodeImageFromPixels(
        Uint8List.fromList(const [0, 0, 0, 255]), 1, 1, ui.PixelFormat.rgba8888, c.complete);
    return c.future;
  }
}

const L = ShuttleSide.left;
const R = ShuttleSide.right;
const T = PickRole.topLayer;
const B = PickRole.bottomLayer;

List<X> cycle<X>(List<X> pattern, int n) =>
    [for (var i = 0; i < n; i++) pattern[i % pattern.length]];

/// 8 ends, straight 1-2-3-4, the four-shed double-weave tie-up, the given treadling and working data.
DraftDoc draft(List<int> treadling, List<PickRole> roles, List<int?> shuttles,
        Map<int, ShuttleSide> starts,
        {LayerConstruction construction = LayerConstruction.none}) =>
    DraftDoc.blank(shafts: 4, treadles: 4).copyWith(
      threading: [
        for (var e = 0; e < 8; e++) [e % 4 + 1],
      ],
      drive: DraftTreadled(
        tieup: const [
          [1],
          [1, 2, 3],
          [3],
          [1, 3, 4],
        ],
        treadling: [
          for (final t in treadling) [t],
        ],
      ),
      warpColors: cycle(const [0, 1], 8),
      weftColors: List.filled(treadling.length, 0),
      pickRoles: roles,
      pickShuttles: shuttles,
      shuttleStarts: starts,
      construction: construction,
    );

/// Double width, fold on the right: one shuttle from the left, T-B-B-T.
DraftDoc foldRight({LayerConstruction construction = LayerConstruction.none}) => draft(
    cycle(const [1, 2, 4, 3], 8), cycle(const [T, B, B, T], 8), List.filled(8, 1), const {1: L},
    construction: construction);

Future<void> settle(WidgetTester t) async {
  await t.pump();
  for (var i = 0; i < 24; i++) {
    await t.pump(const Duration(milliseconds: 20));
  }
}

/// Open the inspector on [doc], with the same draft loaded in the editor.
Future<ProviderContainer> open(WidgetTester t, DraftDoc doc) async {
  t.view.physicalSize = const Size(800, 2400);
  t.view.devicePixelRatio = 1.0;
  addTearDown(() {
    t.view.resetPhysicalSize();
    t.view.resetDevicePixelRatio();
  });
  final c = ProviderContainer(overrides: [repositoryProvider.overrideWithValue(_Repo())]);
  addTearDown(c.dispose);
  c.read(draftEditorProvider.notifier).load(doc);
  await t.pumpWidget(UncontrolledProviderScope(
    container: c,
    child: MaterialApp(home: LayerInspectorScreen(draft: doc)),
  ));
  await settle(t);
  return c;
}

String textOf(WidgetTester t, String key) => t.widget<Text>(find.byKey(Key(key))).data!;

void main() {
  testWidgets('the edge legend names each edge, and the working order shows each pass', (t) async {
    final semantics = t.ensureSemantics();
    await open(t, foldRight(construction: LayerConstruction.doubleWidthFoldRight));
    expect(textOf(t, 'construction-declared'), 'Double width, fold on the right');
    expect(textOf(t, 'construction-status'), 'The edges match this construction.');
    expect(textOf(t, 'edge-left'), 'Left edge: Open: each layer turns back at its own selvedge');
    expect(
        textOf(t, 'edge-right'),
        'Right edge (warp end 1): Joined: the weft passes from one layer to the other (a fold or a '
        'closed edge)');
    // One chip per pick: number, layer, direction (one shuttle, so no shuttle tag).
    for (final label in ['1 T →', '2 B ←', '3 B →', '4 T ←']) {
      expect(find.widgetWithText(Chip, label), findsOneWidget, reason: label);
    }
    expect(find.text('T top layer, B bottom layer, ← right to left, → left to right.'),
        findsOneWidget);
    expect(find.bySemanticsLabel('Pick 1, top layer, shuttle 1, left to right'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('two shuttles tag each pass with its shuttle and note crossed wefts', (t) async {
    await open(
        t,
        draft(cycle(const [1, 2, 3, 4], 8), cycle(const [T, B], 8), cycle(const [1, 2], 8),
            const {1: R, 2: R},
            construction: LayerConstruction.twoLayers));
    expect(find.widgetWithText(Chip, '1 T ← s1'), findsOneWidget);
    expect(find.widgetWithText(Chip, '2 B ← s2'), findsOneWidget);
    expect(find.textContaining('unless you cross the wefts of two shuttles there'), findsOneWidget);
    expect(textOf(t, 'edge-left'), 'Left edge: Open: each layer turns back at its own selvedge');
  });

  testWidgets('unknown edges say why, and nothing is offered', (t) async {
    await open(t, foldRight().copyWith(shuttleStarts: const {}));
    expect(textOf(t, 'construction-declared'), 'Not declared');
    expect(textOf(t, 'construction-status'),
        'Ply cannot tell the construction because shuttle 1 has no starting side.');
    expect(textOf(t, 'edge-left'), 'Left edge: Unknown');
    expect(find.textContaining('Use as'), findsNothing);
    expect(find.text('Shuttle 1 has no starting side, so its picks show no direction.'),
        findsOneWidget);
  });

  testWidgets('"Use as" is offered only for an exact match and applied only on confirmation',
      (t) async {
    final c = await open(t, foldRight());
    expect(
        textOf(t, 'construction-status'),
        'The edges match double width with the fold on the right. Ply labels a draft only when you '
        'confirm it.');
    final button = find.widgetWithText(OutlinedButton, 'Use as double width, fold on the right');
    expect(button, findsOneWidget);

    // Cancel: nothing changes.
    await t.tap(button);
    await settle(t); // bounded: the layer renders may still be decoding
    expect(find.text('Confirm the construction'), findsOneWidget);
    expect(
        find.text('The edges of this draft match double width with the fold on the right: the '
            'layers join on the right and are open on the left. Ply will keep this label with the '
            'draft and warn you if a later edit no longer matches it.'),
        findsOneWidget);
    await t.tap(find.text('Cancel'));
    await settle(t); // bounded: the layer renders may still be decoding
    expect(c.read(draftEditorProvider).draft.construction, LayerConstruction.none);
    expect(c.read(draftEditorProvider).canUndo, isFalse);

    // Confirm: the live draft is labeled (one undo entry) and the inspector says it matches.
    await t.tap(button);
    await settle(t); // bounded: the layer renders may still be decoding
    await t.tap(find.widgetWithText(FilledButton, 'Use as double width, fold on the right'));
    await settle(t);
    expect(c.read(draftEditorProvider).draft.construction, LayerConstruction.doubleWidthFoldRight);
    expect(c.read(draftEditorProvider).canUndo, isTrue);
    expect(textOf(t, 'construction-declared'), 'Double width, fold on the right');
    expect(textOf(t, 'construction-status'), 'The edges match this construction.');
    expect(find.textContaining('Use as'), findsNothing);

    // And the label can be removed again.
    await t.tap(find.text('Remove the label'));
    await settle(t);
    expect(c.read(draftEditorProvider).draft.construction, LayerConstruction.none);
    expect(find.widgetWithText(OutlinedButton, 'Use as double width, fold on the right'),
        findsOneWidget);
  });

  testWidgets('no offer when the edges are mixed or one edge has no turns yet', (t) async {
    await open(
        t,
        draft(const [1, 3, 1, 3, 2, 4, 2, 4], const [T, T, T, T, B, B, B, B], List.filled(8, 1),
            const {1: R}));
    expect(textOf(t, 'construction-status'),
        'The edges do not match one construction exactly, so Ply does not offer a label.');
    expect(textOf(t, 'edge-right'),
        'Right edge (warp end 1): Mixed: the layers join at some turns and not at others');
    expect(find.textContaining('Use as'), findsNothing);
  });

  testWidgets('a declared construction the edges contradict shows the mismatch', (t) async {
    await open(t, foldRight(construction: LayerConstruction.doubleWidthFoldLeft));
    expect(
        textOf(t, 'construction-status'),
        'The fold should be on the left, but the layers do not join on the left between picks 2 and '
        '3 (and at 2 more turns).\n'
        'The fold should be on the left, but the layers join on the right between picks 1 and 2 '
        '(and at 3 more turns).');
    expect(find.text('Top layer'), findsOneWidget);
    expect(find.text('Top face'), findsNothing);
    expect(textOf(t, 'top-face-reason'),
        'Ply shows the top face only when the edges match the declared construction.');
  });

  testWidgets('the top face is shown only when it is provable', (t) async {
    await open(t, foldRight(construction: LayerConstruction.doubleWidthFoldRight));
    expect(find.text('Top face'), findsOneWidget);
    expect(find.text('Bottom layer'), findsOneWidget);
    expect(find.textContaining('The top view is the top face'), findsOneWidget);
    expect(find.textContaining("one layer's own interlacement, not the face"), findsNothing);
    // Moving shaft 2 to the top layer breaks the clean split: back to the per-layer labeling.
    await t.tap(find.widgetWithText(FilterChip, '2'));
    await settle(t);
    expect(find.text('Top face'), findsNothing);
    expect(find.text('Top layer'), findsOneWidget);
    expect(textOf(t, 'top-face-reason'), startsWith('With these top-layer shafts, picks'));
    expect(find.textContaining("one layer's own interlacement, not the face"), findsOneWidget);
  });

  testWidgets('undeclared drafts keep the per-layer labeling', (t) async {
    await open(t, foldRight());
    expect(find.text('Top face'), findsNothing);
    expect(textOf(t, 'top-face-reason'),
        'Ply shows the top face only when a construction is declared.');
  });

  group('the editor caption over a multi-layer drawdown', () {
    Future<ProviderContainer> pumpNote(WidgetTester t, DraftDoc doc) async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(draftEditorProvider.notifier).load(doc);
      await t.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(home: Scaffold(body: LayeredDrawdownNote())),
      ));
      return c;
    }

    testWidgets('shown when any pick has a layer role', (t) async {
      await pumpNote(t, foldRight());
      expect(find.text(kLayeredDrawdownNote), findsOneWidget);
      expect(
          kLayeredDrawdownNote,
          'This drawdown shows every intersection of both layers, not the face of the cloth. Open '
          'Layers to see each layer.');
    });

    testWidgets('hidden for a draft without layer roles, and follows edits', (t) async {
      final c = await pumpNote(t, foldRight().copyWith(pickRoles: const []));
      expect(find.text(kLayeredDrawdownNote), findsNothing);
      c.read(draftEditorProvider.notifier).setPickRoles(0, 1, PickRole.topLayer);
      await t.pump();
      expect(find.text(kLayeredDrawdownNote), findsOneWidget);
      // Pattern and tabby roles are not layer roles.
      c
          .read(draftEditorProvider.notifier)
          .load(foldRight().copyWith(pickRoles: List.filled(8, PickRole.tabby)));
      await t.pump();
      expect(find.text(kLayeredDrawdownNote), findsNothing);
    });
  });
}
