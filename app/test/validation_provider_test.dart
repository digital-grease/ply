import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/draft_repository.dart';
import 'package:ply/src/models/draft_doc.dart';
import 'package:ply/src/models/draft_issue.dart';
import 'package:ply/src/models/draft_region.dart';
import 'package:ply/src/state/draft_editor_notifier.dart';
import 'package:ply/src/state/editor_providers.dart';

// validationProvider is the LATEST-WINS twin of previewProvider (minus the image dispose). These
// pin the same guarantees the preview provider has: a slow earlier validation never overwrites a
// newer one, a superseded result is dropped even if it resolves first, there is no debounce, and a
// no-op (deep-equal) edit does not re-validate.

/// A repository whose validateDto returns futures the test completes by hand, in any order.
class FakeRepo extends DraftRepository {
  final List<Completer<List<DraftIssue>>> pending = [];

  @override
  Future<List<DraftIssue>> validateDto(DraftDoc doc) {
    final c = Completer<List<DraftIssue>>();
    pending.add(c);
    return c.future;
  }
}

List<DraftIssue> issues(String tag) =>
    [DraftIssue(severity: IssueSeverity.error, message: tag)];

/// A paintable treadled draft whose threading is all shaft 1, so painting shaft 2 onto an end is a
/// real value change (not a no-op).
DraftDoc paintable() => DraftDoc(
      name: 'p',
      shafts: 4,
      treadles: 4,
      shed: Shed.rising,
      unit: MeasureUnit.inches,
      threading: const [
        [1],
        [1],
        [1],
        [1],
      ],
      drive: DraftTreadled(
        tieup: const [
          [1],
          [2],
          [3],
          [4],
        ],
        treadling: const [
          [1],
          [2],
          [3],
          [4],
        ],
      ),
      palette: const [DraftColor(r: 255, g: 255, b: 255), DraftColor(r: 0, g: 0, b: 0)],
      warpColors: const [0, 0, 0, 0],
      weftColors: const [1, 1, 1, 1],
      notes: '',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('latest-wins: a slow earlier validation never overwrites a newer result', () async {
    final fake = FakeRepo();
    final container = ProviderContainer(overrides: [repositoryProvider.overrideWithValue(fake)]);
    addTearDown(container.dispose);
    final sub = container.listen(validationProvider, (_, __) {});
    addTearDown(sub.close);

    final notifier = container.read(draftEditorProvider.notifier);
    await pumpEventQueue();
    expect(fake.pending.length, 1, reason: 'initial validation dispatched');

    notifier.load(DraftDoc.blank(shafts: 4, treadles: 2));
    await pumpEventQueue();
    notifier.load(DraftDoc.blank(shafts: 4, treadles: 3));
    await pumpEventQueue();
    expect(fake.pending.length, 3, reason: 'three validations now in flight');

    // Complete OUT OF ORDER: newest (#3) first, then the two stale ones.
    fake.pending[2].complete(issues('newest'));
    await pumpEventQueue();
    fake.pending[1].complete(issues('mid-stale'));
    await pumpEventQueue();
    fake.pending[0].complete(issues('oldest-stale'));
    await pumpEventQueue();

    final state = container.read(validationProvider);
    expect(state.hasValue, isTrue);
    expect(state.value!.single.message, 'newest',
        reason: 'the newest validation wins; the two stale completions are dropped');
  });

  test('a stale validation resolving BEFORE the newest is dropped', () async {
    final fake = FakeRepo();
    final container = ProviderContainer(overrides: [repositoryProvider.overrideWithValue(fake)]);
    addTearDown(container.dispose);
    final sub = container.listen(validationProvider, (_, __) {});
    addTearDown(sub.close);

    await pumpEventQueue();
    final notifier = container.read(draftEditorProvider.notifier);
    notifier.load(DraftDoc.blank(shafts: 4, treadles: 2)); // #2
    await pumpEventQueue();
    notifier.load(DraftDoc.blank(shafts: 4, treadles: 3)); // #3 (newest, still in flight)
    await pumpEventQueue();
    expect(fake.pending.length, 3);

    // The superseded middle (#2) resolves FIRST: it must NOT be shown.
    fake.pending[1].complete(issues('mid-stale'));
    await pumpEventQueue();
    expect(container.read(validationProvider).valueOrNull?.singleOrNull?.message, isNot('mid-stale'),
        reason: 'a superseded validation is dropped even if it completes before the winner');

    fake.pending[2].complete(issues('newest'));
    await pumpEventQueue();
    expect(container.read(validationProvider).value!.single.message, 'newest');

    fake.pending[0].complete(issues('oldest-stale')); // late: changes nothing
    await pumpEventQueue();
    expect(container.read(validationProvider).value!.single.message, 'newest');
  });

  test('no debounce: each distinct edit dispatches its own validate', () async {
    final fake = FakeRepo();
    final container = ProviderContainer(overrides: [repositoryProvider.overrideWithValue(fake)]);
    addTearDown(container.dispose);
    final sub = container.listen(validationProvider, (_, __) {});
    addTearDown(sub.close);

    final notifier = container.read(draftEditorProvider.notifier);
    await pumpEventQueue();
    notifier.load(DraftDoc.blank(shafts: 4, treadles: 2));
    await pumpEventQueue();
    notifier.load(DraftDoc.blank(shafts: 4, treadles: 3));
    await pumpEventQueue();
    notifier.load(DraftDoc.blank(shafts: 4, treadles: 5));
    await pumpEventQueue();
    expect(fake.pending.length, 4,
        reason: 'initial + 3 edits => 4 hops; no timer swallowed a validation');
  });

  test('a no-op edit (deep-equal draft) does not re-validate', () async {
    final fake = FakeRepo();
    final container = ProviderContainer(overrides: [repositoryProvider.overrideWithValue(fake)]);
    addTearDown(container.dispose);
    final sub = container.listen(validationProvider, (_, __) {});
    addTearDown(sub.close);

    final notifier = container.read(draftEditorProvider.notifier);
    await pumpEventQueue();
    notifier.load(DraftDoc.blank(shafts: 4, treadles: 2));
    await pumpEventQueue();
    expect(fake.pending.length, 2, reason: 'a real change re-validates');

    // A fresh-but-DEEP-EQUAL draft: the .select((s)=>s.draft) + DraftDoc deep-== dedups it.
    notifier.load(DraftDoc.blank(shafts: 4, treadles: 2));
    await pumpEventQueue();
    expect(fake.pending.length, 2, reason: 'an equal draft does not re-validate');
  });

  test('a drag-paint stroke validates per DISTINCT painted cell (a repeat is deduped)', () async {
    final fake = FakeRepo();
    final container = ProviderContainer(overrides: [repositoryProvider.overrideWithValue(fake)]);
    addTearDown(container.dispose);
    final sub = container.listen(validationProvider, (_, __) {});
    addTearDown(sub.close);

    final notifier = container.read(draftEditorProvider.notifier);
    await pumpEventQueue();
    notifier.load(paintable());
    await pumpEventQueue();
    final base = fake.pending.length;

    // The real production driver (not notifier.load): begin paints end1, drag paints end2, a repeat
    // of end2 must NOT re-validate, and the seal (endStroke) is a no value-change.
    notifier.beginStroke(const DraftHit(DraftRegion.threading, 1, 2));
    await pumpEventQueue();
    notifier.paintAt(const DraftHit(DraftRegion.threading, 2, 2));
    await pumpEventQueue();
    notifier.paintAt(const DraftHit(DraftRegion.threading, 2, 2)); // same cell -> no draft change
    await pumpEventQueue();
    notifier.endStroke();
    await pumpEventQueue();

    expect(fake.pending.length, base + 2,
        reason: 'two distinct painted cells each validated; the repeat + the seal did not');
  });

  test('the provider re-initializes clean across a teardown (no stale issues bleed)', () async {
    final fake = FakeRepo();
    final container = ProviderContainer(overrides: [repositoryProvider.overrideWithValue(fake)]);
    addTearDown(container.dispose);
    final notifier = container.read(draftEditorProvider.notifier);

    var sub = container.listen(validationProvider, (_, __) {});
    notifier.load(DraftDoc.blank(shafts: 4, treadles: 2)); // draft A
    await pumpEventQueue();
    fake.pending.last.complete(issues('stale-A'));
    await pumpEventQueue();
    expect(container.read(validationProvider).value!.single.message, 'stale-A');

    // Drop the only listener: the autoDispose provider tears down (state + _seq gone).
    sub.close();
    await pumpEventQueue();

    // Re-subscribe on a different (clean) draft: the FIRST observable state must be loading with NO
    // stale value, not draft A's issues.
    notifier.load(DraftDoc.blank(shafts: 4, treadles: 3)); // draft B
    sub = container.listen(validationProvider, (_, __) {});
    addTearDown(sub.close);
    await pumpEventQueue();
    expect(container.read(validationProvider).valueOrNull, isNull,
        reason: "a fresh subscription starts clean, not with the prior draft's issues");

    fake.pending.last.complete(const []);
    await pumpEventQueue();
    expect(container.read(validationProvider).value, isEmpty);
  });
}
