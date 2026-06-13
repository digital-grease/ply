import 'package:flutter_test/flutter_test.dart';
import 'package:ply/src/data/draft_repository.dart';
import 'package:ply/src/models/draft_doc.dart';

// Pure-Dart tests for the DraftDoc <-> DraftDto mapping on DraftRepository. toDto/fromDto build
// plain generated value classes (DraftDto/DriveDto/ColorDto) with no FFI call, so the whole
// round-trip runs on the host VM without the native lib. (renderDto/validateDto/saveDto DO call
// FFI and are device-verified later.)

/// A treadled fixture exercising multi-shaft tie-up rows, sinking shed, and centimeters.
DraftDoc treadledFixture() => DraftDoc(
      name: 'Twill',
      shafts: 4,
      treadles: 4,
      shed: Shed.sinking,
      unit: MeasureUnit.centimeters,
      threading: const [
        [1],
        [2],
        [3],
        [4],
      ],
      drive: DraftTreadled(
        tieup: const [
          [1, 2],
          [2, 3],
          [3, 4],
          [4, 1],
        ],
        treadling: const [
          [1],
          [2],
          [3],
          [4],
        ],
      ),
      palette: const [
        DraftColor(r: 255, g: 255, b: 255),
        DraftColor(r: 0, g: 0, b: 0),
        DraftColor(r: 10, g: 128, b: 250),
      ],
      warpColors: const [0, 1, 2, 0],
      weftColors: const [2, 1, 0, 1],
      notes: 'round-trip me',
    );

/// A liftplan fixture (the other drive arm).
DraftDoc liftplanFixture() => DraftDoc(
      name: 'lp',
      shafts: 3,
      treadles: 0,
      shed: Shed.rising,
      unit: MeasureUnit.inches,
      threading: const [
        [1],
        [2],
        [3],
      ],
      drive: DraftLiftplan(liftplan: const [
        [1, 2],
        [3],
        [2],
      ]),
      palette: const [DraftColor(r: 1, g: 2, b: 3)],
      warpColors: const [0, 0, 0],
      weftColors: const [0, 0, 0],
      notes: '',
    );

void main() {
  final repo = DraftRepository();

  group('DraftDoc <-> DraftDto round-trip', () {
    test('a treadled draft round-trips to an identical DraftDoc', () {
      final d = treadledFixture();
      expect(repo.fromDto(repo.toDto(d)), equals(d));
    });

    test('a liftplan draft round-trips to an identical DraftDoc', () {
      final d = liftplanFixture();
      expect(repo.fromDto(repo.toDto(d)), equals(d));
    });

    test('preserves the drive variant', () {
      expect(repo.fromDto(repo.toDto(treadledFixture())).drive, isA<DraftTreadled>());
      expect(repo.fromDto(repo.toDto(liftplanFixture())).drive, isA<DraftLiftplan>());
    });

    test('preserves shed and unit enums both directions', () {
      final back = repo.fromDto(repo.toDto(treadledFixture()));
      expect(back.shed, equals(Shed.sinking));
      expect(back.unit, equals(MeasureUnit.centimeters));
      final back2 = repo.fromDto(repo.toDto(liftplanFixture()));
      expect(back2.shed, equals(Shed.rising));
      expect(back2.unit, equals(MeasureUnit.inches));
    });

    test('preserves multi-shaft tie-up rows and color indices', () {
      final d = treadledFixture();
      final back = repo.fromDto(repo.toDto(d));
      expect((back.drive as DraftTreadled).tieup, equals([
        [1, 2],
        [2, 3],
        [3, 4],
        [4, 1],
      ]));
      expect(back.warpColors, equals([0, 1, 2, 0]));
      expect(back.weftColors, equals([2, 1, 0, 1]));
    });

    test('retained unmodeled sections round-trip through the mapping (cross-FFI passthrough)', () {
      final d = treadledFixture().copyWith(retained: [
        RetainedSection(
            'WARP THICKNESS', const [RetainedEntry('1', '10'), RetainedEntry('2', '10')]),
        RetainedSection('ACME VENDOR', const [RetainedEntry('Foo', 'Bar')]),
      ]);
      final back = repo.fromDto(repo.toDto(d));
      expect(back, equals(d), reason: 'retained sections survive toDto -> fromDto');
      expect(back.retained.map((s) => s.name), ['WARP THICKNESS', 'ACME VENDOR']);
      expect(back.retained[0].entries, equals(d.retained[0].entries));
    });
  });

  group('retained deep equality', () {
    test('retained participates in DraftDoc deep ==/hashCode', () {
      final base = treadledFixture();
      final a = base.copyWith(retained: [
        RetainedSection('X', const [RetainedEntry('a', 'b')]),
      ]);
      // DISTINCT instances, equal content -> deep-equal docs (the undo-snapshot contract).
      final b = base.copyWith(retained: [
        RetainedSection('X', const [RetainedEntry('a', 'b')]),
      ]);
      expect(a == base, isFalse, reason: 'a retained section makes it differ from the bare doc');
      expect(a == b, isTrue, reason: 'equal retained content -> equal docs');
      expect(a.hashCode, b.hashCode);
      // A differing entry value breaks equality.
      final c = base.copyWith(retained: [
        RetainedSection('X', const [RetainedEntry('a', 'DIFFERENT')]),
      ]);
      expect(a == c, isFalse);
    });
  });

  group('toDto color-channel clamping (wire is u8)', () {
    test('clamps out-of-range channels to 0..255 instead of letting FFI truncate mod 256', () {
      final d = treadledFixture().copyWith(palette: const [
        DraftColor(r: 300, g: -5, b: 128), // 300 -> 255, -5 -> 0, 128 stays
        DraftColor(r: 256, g: 0, b: 255), // 256 -> 255 (NOT 0 from mod-256 truncation)
      ]);
      final dto = repo.toDto(d);
      expect(dto.palette[0].r, equals(255));
      expect(dto.palette[0].g, equals(0));
      expect(dto.palette[0].b, equals(128));
      expect(dto.palette[1].r, equals(255));
      expect(dto.palette[1].g, equals(0));
      expect(dto.palette[1].b, equals(255));
    });

    test('in-range channels are untouched (round-trip identity)', () {
      final d = treadledFixture(); // all channels already 0..255
      expect(repo.fromDto(repo.toDto(d)).palette, equals(d.palette));
    });
  });

  group('toDto wire-range guards (ids/indices THROW, not truncate)', () {
    test('throws RangeError on a shaft id beyond u16 (would truncate mod 65536)', () {
      final d = treadledFixture().copyWith(threading: [
        [70000],
      ]);
      expect(() => repo.toDto(d), throwsRangeError);
    });

    test('throws RangeError on a negative id (would wrap to a large positive)', () {
      final d = treadledFixture().copyWith(threading: [
        [-1],
      ]);
      expect(() => repo.toDto(d), throwsRangeError);
    });

    test('throws RangeError on a color index beyond u32', () {
      final d = treadledFixture().copyWith(warpColors: [0, 1, 2, 0x100000000]); // 2^32
      expect(() => repo.toDto(d), throwsRangeError);
    });

    test('an in-range but DANGLING id passes toDto (validate() owns it, not the mapper)', () {
      // Shaft 99 of a 4-shaft draft is semantically dangling but a clean u16. The mapper must
      // NOT throw on it; the engine validator reports it instead.
      final d = treadledFixture().copyWith(threading: [
        [99],
        [1],
        [2],
        [3],
      ]);
      expect(() => repo.toDto(d), returnsNormally);
    });
  });

  group('saveDto dual-path (resolveSaveWif)', () {
    test('the verbatim path returns sourceWif unchanged and never calls FFI writeWif', () async {
      // Runs on host: the `sourceWif ?? ...` short-circuits before the native writeWif. If the
      // branch were inverted, this would invoke writeWif with no RustLib and throw.
      final wif = await repo.resolveSaveWif(treadledFixture(), 'ORIGINAL WIF TEXT');
      expect(wif, equals('ORIGINAL WIF TEXT'));
    });
  });
}
