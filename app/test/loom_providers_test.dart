import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/loom_repository.dart';
import 'package:ply/src/models/draft_doc.dart';
import 'package:ply/src/models/loom_check.dart';
import 'package:ply/src/models/loom_profile.dart';
import 'package:ply/src/state/draft_editor_notifier.dart';
import 'package:ply/src/state/loom_providers.dart';

import 'loom_test_support.dart';

/// A loom store whose checks the test completes by hand, in any order.
class GatedLoomRepository extends FakeLoomRepository {
  GatedLoomRepository() : super(looms: [floorLoom]);

  final List<Completer<LoomReport>> pending = [];

  @override
  Future<LoomReport> check(DraftDoc draft, LoomProfile loom, {Sett? sett}) {
    final c = Completer<LoomReport>();
    pending.add(c);
    return c.future;
  }
}

LoomReport named(String tag) => LoomReport(loomName: tag, diagnostics: const []);

void main() {
  ProviderContainer containerWith(LoomRepository repo) {
    final c = ProviderContainer(overrides: [loomRepositoryProvider.overrideWithValue(repo)]);
    addTearDown(c.dispose);
    return c;
  }

  group('My looms', () {
    test('add, replace, duplicate and delete are saved before the list changes', () async {
      final repo = FakeLoomRepository(looms: [floorLoom]);
      final c = containerWith(repo);
      final n = c.read(loomLibraryProvider.notifier);
      await c.read(loomLibraryProvider.future);

      await n.upsert(borrowedLoom);
      await n.upsert(floorLoom.copyWith(shafts: 8));
      expect([for (final l in repo.looms) (l.id, l.shafts)],
          [(floorLoom.id, 8), (borrowedLoom.id, 8)]);
      final copy = await n.duplicate(floorLoom.id);
      expect(copy!.name, 'Floor loom (copy)');
      expect(repo.looms[1].id, copy.id);
      await n.delete(floorLoom.id);
      expect([for (final l in c.read(loomLibraryProvider).value!.looms) l.id],
          [copy.id, borrowedLoom.id]);
      expect(repo.saves, 4);
    });

    test('a failed save leaves the list as it was', () async {
      final repo = FakeLoomRepository(looms: [floorLoom])..saveError = Exception('disk full');
      final c = containerWith(repo);
      await c.read(loomLibraryProvider.future);
      await expectLater(c.read(loomLibraryProvider.notifier).delete(floorLoom.id), throwsException);
      expect(c.read(loomLibraryProvider).value!.looms, [floorLoom]);
    });

    test('a newer looms file is read only: nothing is saved over it', () async {
      final repo = FakeLoomRepository(status: LoomFileStatus.newer);
      final c = containerWith(repo);
      expect((await c.read(loomLibraryProvider.future)).readOnly, isTrue);
      await expectLater(
          c.read(loomLibraryProvider.notifier).upsert(borrowedLoom),
          throwsA(isA<LoomFileException>()
              .having((e) => e.problem, 'problem', LoomFileProblem.newerVersion)));
      expect(repo.saves, 0);
    });
  });

  group('the loom check', () {
    test('nothing runs and nothing is read when the draft names no loom', () async {
      final repo = FakeLoomRepository(looms: [floorLoom]);
      final c = containerWith(repo);
      final sub = c.listen(loomCheckProvider, (_, __) {});
      addTearDown(sub.close);
      expect(await c.read(loomCheckProvider.future), isNull);
      expect(repo.checks, 0);
    });

    test('a named loom is checked with the plan\'s sett; a missing one is not', () async {
      final repo = FakeLoomRepository(looms: [floorLoom], report: notFeasibleReport);
      final c = containerWith(repo);
      final sub = c.listen(loomCheckProvider, (_, __) {});
      addTearDown(sub.close);
      c.read(draftLoomPlanProvider.notifier).state = LoomPlan(
          loomId: floorLoom.id, loomName: 'Floor loom', sett: const Sett(24, MeasureUnit.inches));
      final view = await c.read(loomCheckProvider.future);
      expect(view, isA<LoomCheckReady>());
      expect((view! as LoomCheckReady).report, notFeasibleReport);
      expect(repo.lastSett, const Sett(24, MeasureUnit.inches));

      c.read(draftLoomPlanProvider.notifier).state = LoomPlan(loomId: 'gone', loomName: 'Old');
      expect(await c.read(loomCheckProvider.future), isA<LoomCheckMissing>());
      expect(repo.checks, 1);
    });

    test('latest wins: a slow earlier check never overwrites a newer one', () async {
      final repo = GatedLoomRepository();
      final c = containerWith(repo);
      final sub = c.listen(loomCheckProvider, (_, __) {});
      addTearDown(sub.close);
      c.read(draftLoomPlanProvider.notifier).state =
          LoomPlan(loomId: floorLoom.id, loomName: 'Floor loom');
      await pumpEventQueue();
      expect(repo.pending, hasLength(1));
      c.read(draftEditorProvider.notifier).load(DraftDoc.blank(shafts: 8, treadles: 2));
      await pumpEventQueue();
      expect(repo.pending, hasLength(2));
      repo.pending[1].complete(named('newer'));
      await pumpEventQueue();
      repo.pending[0].complete(named('older'));
      await pumpEventQueue();
      final view = c.read(loomCheckProvider).value as LoomCheckReady;
      expect(view.report.loomName, 'newer');
    });
  });
}
