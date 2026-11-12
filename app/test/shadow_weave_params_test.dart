// The shadow-weave parameter model (pure Dart) and its mapping to the bridge DTO. The sizes and
// block tables pinned here are the engine's (rust/ply-weave/src/shadow.rs and its worked examples),
// so the sheet's live "Resulting size" and block legend agree with what the engine generates.

import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/draft_repository.dart';
import 'package:ply/src/models/draft_doc.dart';
import 'package:ply/src/models/shadow_weave_params.dart';
import 'package:ply/src/rust/dto.dart';

void main() {
  test('the default design is Atwater, 4 shafts, a point of A2 B2 C2 D2, balanced', () {
    const p = ShadowWeaveParams();
    expect(p.system, ShadowSystem.atwater);
    expect(p.shafts, 4);
    expect(p.layout, ShadowLayout.point);
    expect(p.blockUnits, [2, 2, 2, 2]);
    expect((p.reverseTwill, p.featheryEdges, p.balanced), (false, false, true));
    expect((p.warpRepeats, p.weftRepeats), (2, 2));
    expect(p.repeatLength, 30, reason: '4 x 8 units - 2');
    expect((p.ends, p.picks), (61, 61));
  });

  test('sizes match the engine worked examples', () {
    // AW-1 / PW-1: straight repeat of A2 B2 C2 D2, one repeat, 16 x 16.
    const aw1 = ShadowWeaveParams(
        layout: ShadowLayout.repeat, warpRepeats: 1, weftRepeats: 1, balanced: false);
    expect((aw1.ends, aw1.picks), (16, 16));
    // AW-2: point of A2 B1 C1 D2, 22 x 22; balanced adds end 1 and pick 1 once.
    const aw2 = ShadowWeaveParams(
        blockUnits: [2, 1, 1, 2], warpRepeats: 1, weftRepeats: 1, balanced: false);
    expect((aw2.ends, aw2.picks), (22, 22));
    expect((aw2.copyWith(balanced: true).ends), 23);
    // PW-2: Powell 8, point of A1 to H1, 30 x 30.
    const pw2 = ShadowWeaveParams(
      system: ShadowSystem.powell,
      shafts: 8,
      blockUnits: [1, 1, 1, 1, 1, 1, 1, 1],
      warpRepeats: 1,
      weftRepeats: 1,
      balanced: false,
    );
    expect((pw2.ends, pw2.picks), (30, 30));
    expect(pw2.copyWith(warpRepeats: 3).ends, 90, reason: 'whole repeats, never a cut unit');
  });

  test('block shafts follow each system (Powell letters as in Powell\'s book)', () {
    List<(int, int)> table(ShadowSystem s, int shafts) =>
        [for (var b = 0; b < shafts; b++) ShadowWeaveParams.blockShafts(s, shafts, b)];
    expect(table(ShadowSystem.atwater, 4), [(1, 3), (2, 4), (3, 1), (4, 2)]);
    expect(table(ShadowSystem.powell, 4), [(1, 2), (3, 4), (2, 1), (4, 3)]);
    expect(table(ShadowSystem.atwater, 8),
        [(1, 5), (2, 6), (3, 7), (4, 8), (5, 1), (6, 2), (7, 3), (8, 4)]);
    expect(table(ShadowSystem.powell, 8),
        [(1, 2), (3, 4), (5, 6), (7, 8), (2, 1), (4, 3), (6, 5), (8, 7)]);
    expect(ShadowWeaveParams.partnerPairs(ShadowSystem.atwater, 4), [(1, 3), (2, 4)]);
    expect(ShadowWeaveParams.partnerPairs(ShadowSystem.powell, 8),
        [(1, 2), (3, 4), (5, 6), (7, 8)]);
    expect([for (var b = 0; b < 8; b++) ShadowWeaveParams.blockLetter(b)].join(), 'ABCDEFGH');
  });

  test('equality covers every field, including the widths', () {
    const a = ShadowWeaveParams();
    expect(a, const ShadowWeaveParams());
    expect(a.hashCode, const ShadowWeaveParams().hashCode);
    expect(a == a.copyWith(blockUnits: [2, 2, 2, 3]), isFalse);
    expect(a == a.copyWith(featheryEdges: true), isFalse);
    expect(a == a.copyWith(reverseTwill: true), isFalse);
    expect(a == a.copyWith(balanced: false), isFalse);
  });

  test('the wire DTO carries one block entry per block, in twill order', () {
    final dto = DraftRepository.shadowParamsDto(const ShadowWeaveParams(
      system: ShadowSystem.powell,
      shafts: 8,
      layout: ShadowLayout.repeat,
      blockUnits: [3, 1, 1, 1, 1, 1, 1, 2],
      reverseTwill: true,
      featheryEdges: true,
      warpRepeats: 4,
      weftRepeats: 5,
      balanced: false,
    ));
    expect(dto.system, ShadowSystemKind.powell);
    expect(dto.shafts, 8);
    expect(dto.layout, ShadowLayoutKind.repeat);
    expect([for (final b in dto.blocks) (b.block, b.units)],
        [(0, 3), (1, 1), (2, 1), (3, 1), (4, 1), (5, 1), (6, 1), (7, 2)]);
    expect(dto.direction, TwillDirectionKind.reverse);
    expect(dto.weftPhase, WeftPhaseKind.swapped);
    expect((dto.warpRepeats, dto.weftRepeats, dto.balance), (4, 5, false));

    final standard = DraftRepository.shadowParamsDto(const ShadowWeaveParams());
    expect(standard.system, ShadowSystemKind.atwater);
    expect(standard.layout, ShadowLayoutKind.point);
    expect(standard.direction, TwillDirectionKind.forward);
    expect(standard.weftPhase, WeftPhaseKind.standard);
    expect(standard.balance, isTrue);
  });

  test('shadow weave cannot be sent down the generic whole-draft path', () async {
    await expectLater(
      DraftRepository().generateStructureDoc(
        DraftDoc.blank(),
        family: StructureFamily.shadowWeave,
        threading: ThreadingKind.straight,
        shafts: 4,
        over: 2,
        under: 2,
        counter: 2,
        ends: 16,
        picks: 16,
      ),
      throwsArgumentError,
    );
  });

  test('a value the wire cannot carry is a RangeError, never truncated', () async {
    await expectLater(
      DraftRepository().generateShadowWeaveDoc(
          DraftDoc.blank(), const ShadowWeaveParams(warpRepeats: 70000)),
      throwsRangeError,
    );
  });
}
