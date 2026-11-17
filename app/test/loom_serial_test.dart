import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/state/loom_providers.dart';

import 'loom_test_support.dart';

// My looms' changes run one at a time (ADR 0014, as the materials library in ADR 0016): each runs on
// the looms the one before it left, so a delete and a duplicate made together never bring back the
// deleted loom, and a failed change does not stop the next.

void main() {
  test('a delete and a duplicate at once: the duplicate runs on what the delete left', () async {
    final gate = Completer<void>();
    final repo = FakeLoomRepository(looms: [floorLoom, borrowedLoom])..saveGate = gate.future;
    final c = ProviderContainer(overrides: [loomRepositoryProvider.overrideWithValue(repo)]);
    addTearDown(c.dispose);
    await c.read(loomLibraryProvider.future);
    final notifier = c.read(loomLibraryProvider.notifier);
    final deleted = notifier.delete(floorLoom.id);
    final copied = notifier.duplicate(floorLoom.id);
    gate.complete();
    await deleted;
    expect(await copied, isNull, reason: 'the loom was gone by then');
    expect(repo.looms.map((l) => l.id), [borrowedLoom.id], reason: 'never brought back');
    expect(c.read(loomLibraryProvider).value!.looms.map((l) => l.id), [borrowedLoom.id]);
  });

  test('changes made together all land, in order, and a failure does not block the next', () async {
    final gate = Completer<void>();
    final repo = FakeLoomRepository(looms: [floorLoom])..saveGate = gate.future;
    final c = ProviderContainer(overrides: [loomRepositoryProvider.overrideWithValue(repo)]);
    addTearDown(c.dispose);
    await c.read(loomLibraryProvider.future);
    final notifier = c.read(loomLibraryProvider.notifier);
    final a = notifier.upsert(borrowedLoom);
    final b = notifier.duplicate(floorLoom.id);
    gate.complete();
    await a;
    final copy = await b;
    expect(repo.looms.map((l) => l.id), [floorLoom.id, copy!.id, borrowedLoom.id],
        reason: 'the duplicate saw the upsert before it');
    repo.saveError = StateError('disk');
    await expectLater(notifier.delete(borrowedLoom.id), throwsStateError);
    repo.saveError = null;
    await notifier.delete(borrowedLoom.id);
    expect(repo.looms.map((l) => l.id), [floorLoom.id, copy.id]);
  });
}
