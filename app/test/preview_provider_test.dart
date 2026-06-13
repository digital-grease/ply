import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/draft_repository.dart';
import 'package:ply/src/models/draft_doc.dart';
import 'package:ply/src/state/draft_editor_notifier.dart';
import 'package:ply/src/state/editor_providers.dart';

/// A repository whose renderDto returns futures the test completes by hand, in any order.
class FakeRepo extends DraftRepository {
  final List<Completer<ui.Image>> pending = [];

  @override
  Future<ui.Image> renderDto(
    DraftDoc doc, {
    required int cellPx,
    bool gridlines = false,
    int floatThreshold = 0,
  }) {
    final completer = Completer<ui.Image>();
    pending.add(completer);
    return completer.future;
  }
}

Future<ui.Image> makeImage() {
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    Uint8List.fromList(const [0, 0, 0, 255]),
    1,
    1,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  return completer.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('previewProvider is latest-wins: a slow earlier render never overwrites a newer frame',
      () async {
    final fake = FakeRepo();
    final container = ProviderContainer(
      overrides: [repositoryProvider.overrideWithValue(fake)],
    );
    addTearDown(container.dispose);

    // Listen so the autoDispose provider stays alive and rebuilds on draft changes.
    final sub = container.listen(previewProvider, (_, __) {});
    addTearDown(sub.close);

    final notifier = container.read(draftEditorProvider.notifier);

    // Initial build dispatches render #1 (the blank draft).
    await pumpEventQueue();
    expect(fake.pending.length, 1, reason: 'initial render dispatched');

    // Two fast edits dispatch render #2 then #3 before any completes.
    notifier.load(DraftDoc.blank(shafts: 4, treadles: 2));
    await pumpEventQueue();
    notifier.load(DraftDoc.blank(shafts: 4, treadles: 3));
    await pumpEventQueue();
    expect(fake.pending.length, 3, reason: 'three renders now in flight');

    final newest = await makeImage();
    final mid = await makeImage();
    final oldest = await makeImage();

    // Complete OUT OF ORDER: the newest (#3) first, then the two stale ones.
    fake.pending[2].complete(newest);
    await pumpEventQueue();
    fake.pending[1].complete(mid);
    await pumpEventQueue();
    expect(mid.debugDisposed, isTrue, reason: 'a superseded frame is freed immediately, not leaked');
    fake.pending[0].complete(oldest);
    await pumpEventQueue();
    expect(oldest.debugDisposed, isTrue, reason: 'a superseded frame is freed immediately');

    final state = container.read(previewProvider);
    expect(state.hasValue, isTrue);
    expect(
      identical(state.value, newest),
      isTrue,
      reason: 'the newest render wins; the two stale completions are dropped, not shown',
    );
  });

  test('a stale frame is dropped even when it resolves BEFORE the newest one', () async {
    final fake = FakeRepo();
    final container = ProviderContainer(
      overrides: [repositoryProvider.overrideWithValue(fake)],
    );
    addTearDown(container.dispose);
    final sub = container.listen(previewProvider, (_, __) {});
    addTearDown(sub.close);

    await pumpEventQueue();
    final notifier = container.read(draftEditorProvider.notifier);
    notifier.load(DraftDoc.blank(shafts: 4, treadles: 2)); // render #2
    await pumpEventQueue();
    notifier.load(DraftDoc.blank(shafts: 4, treadles: 3)); // render #3 (newest, still in flight)
    await pumpEventQueue();
    expect(fake.pending.length, 3);

    final oldest = await makeImage();
    final mid = await makeImage();
    final newest = await makeImage();

    // The STALE middle render (#2) resolves FIRST, while the newest (#3) is still pending. It
    // must NOT become the shown frame (its build was already superseded when #3 started).
    fake.pending[1].complete(mid);
    await pumpEventQueue();
    expect(identical(container.read(previewProvider).value, mid), isFalse,
        reason: 'a superseded frame is dropped even if it completes before the winner');

    // The newest (#3) then completes and wins.
    fake.pending[2].complete(newest);
    await pumpEventQueue();
    expect(identical(container.read(previewProvider).value, newest), isTrue);

    // The oldest (#1) completing late changes nothing.
    fake.pending[0].complete(oldest);
    await pumpEventQueue();
    expect(identical(container.read(previewProvider).value, newest), isTrue);
  });

  test('previewProvider forwards the gridline/float view toggles to renderDto', () async {
    final fake = _CapturingRepo();
    final container = ProviderContainer(
      overrides: [
        repositoryProvider.overrideWithValue(fake),
        // Start both overlays ON so the first render already carries them.
        showGridlinesProvider.overrideWith((ref) => true),
        highlightFloatsProvider.overrideWith((ref) => true),
      ],
    );
    addTearDown(container.dispose);
    final sub = container.listen(previewProvider, (_, __) {});
    addTearDown(sub.close);

    await pumpEventQueue();
    expect(fake.lastGridlines, isTrue, reason: 'gridline toggle reaches the render');
    expect(fake.lastFloatThreshold, kLongFloatThreshold,
        reason: 'float highlight maps to the threshold');

    // Turning floats OFF re-renders with threshold 0 (gridlines untouched).
    container.read(highlightFloatsProvider.notifier).state = false;
    await pumpEventQueue();
    expect(fake.lastGridlines, isTrue);
    expect(fake.lastFloatThreshold, 0, reason: 'float cue off => no threshold');
  });
}

/// A repository that records the overlay args of the most recent [renderDto] and returns a real
/// 1x1 image, so a test can assert the preview provider forwards the view toggles.
class _CapturingRepo extends DraftRepository {
  bool lastGridlines = false;
  int lastFloatThreshold = 0;

  @override
  Future<ui.Image> renderDto(
    DraftDoc doc, {
    required int cellPx,
    bool gridlines = false,
    int floatThreshold = 0,
  }) {
    lastGridlines = gridlines;
    lastFloatThreshold = floatThreshold;
    return makeImage();
  }
}
