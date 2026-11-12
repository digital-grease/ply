import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:ply/src/data/draft_repository.dart';
import 'package:ply/src/models/draft_doc.dart';
import 'package:ply/src/rust/dto.dart';
import 'package:ply/src/state/draft_editor_notifier.dart';
import 'package:ply/src/state/editor_providers.dart';
import 'package:ply/src/widgets/integrated_draft_view.dart';

// Host coverage for the bounded weaving render (M7-01) on the Dart side: the engine reports a draft
// too large to preview as a typed RenderFailure (it already falls back to the largest pitch that
// fits, which the Rust tests pin), and the UI must say so instead of showing a bare error box. Also
// covers the weaving delete removing an interrupted save's `.tmp` leftovers.

/// A repo whose every render fails the way the engine reports an oversized draft.
class TooLargeRepo extends DraftRepository {
  @override
  Future<ui.Image> renderDto(
    DraftDoc doc, {
    required int cellPx,
    bool gridlines = false,
    int floatThreshold = 0,
    bool threadTexture = false,
  }) =>
      Future<ui.Image>.error(const RenderFailure(
        kind: RenderFailureKind.tooLarge,
        message: 'a 3000 x 2000 draft has 6000000 intersections; the limit is 4000000',
      ));
}

DraftDoc _doc() => DraftDoc(
      name: 'big',
      shafts: 2,
      treadles: 2,
      shed: Shed.rising,
      unit: MeasureUnit.inches,
      threading: const [
        [1],
        [2],
      ],
      drive: DraftTreadled(
        tieup: const [
          [1],
          [2],
        ],
        treadling: const [
          [1],
          [2],
        ],
      ),
      palette: const [DraftColor(r: 255, g: 255, b: 255), DraftColor(r: 0, g: 0, b: 0)],
      warpColors: const [0, 0],
      weftColors: const [1, 1],
      notes: '',
    );

void main() {
  group('previewErrorMessage', () {
    test('explains each RenderFailure kind in plain words', () {
      String msg(RenderFailureKind k) => previewErrorMessage(RenderFailure(kind: k, message: 'x'));
      expect(msg(RenderFailureKind.tooLarge), 'This draft is too large to preview on this device.');
      expect(msg(RenderFailureKind.outOfMemory),
          'There was not enough memory to draw this preview.');
      expect(msg(RenderFailureKind.invalidDraft), 'This draft could not be drawn.');
    });

    test('passes any other error through unchanged', () {
      expect(previewErrorMessage(const FormatException('bad wif')), contains('bad wif'));
    });
  });

  testWidgets('the editor says a draft is too large instead of a bare error box', (tester) async {
    final c = ProviderContainer(overrides: [repositoryProvider.overrideWithValue(TooLargeRepo())]);
    addTearDown(c.dispose);
    c.read(zoomUserSetProvider.notifier).state = true;
    c.read(draftEditorProvider.notifier).load(_doc());
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(home: Scaffold(body: IntegratedDraftView())),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('This draft is too large to preview on this device.'), findsOneWidget);
  });

  group('weaving delete', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('ply_drafts_'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('removes the draft, its sidecar, thumbnail, and interrupted-save leftovers', () async {
      final repo = DraftRepository(draftsDirOverride: dir);
      final names = [
        'd1.wif', 'd1.json', 'd1.png', //
        'd1.wif.tmp', 'd1.json.tmp', 'd1.png.tmp',
        'd2.wif', 'd2.json', // another draft: untouched
      ];
      for (final n in names) {
        File(p.join(dir.path, n)).writeAsStringSync('x');
      }
      await repo.delete('d1');
      final left = dir.listSync().map((e) => p.basename(e.path)).toSet();
      expect(left, {'d2.wif', 'd2.json'});
    });

    test('tolerates files that are already gone', () async {
      final repo = DraftRepository(draftsDirOverride: dir);
      await repo.delete('missing');
      expect(dir.listSync(), isEmpty);
    });
  });
}
